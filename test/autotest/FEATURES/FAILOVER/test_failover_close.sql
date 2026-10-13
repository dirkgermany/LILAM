-- =====================================================================
-- LILAM Test: FEATURES / FAILOVER (FAILOVER_CLOSE)
--
-- Befund B2 (befunde fallback): Der Worker faellt unmittelbar vor CLOSE_PROCESS aus. Das CLOSE liegt im
-- Ringpuffer des Clients; der Client verwirft den Ringpuffer erst, wenn process_end committet ist.
-- Bei spaeteren Aufrufen derselben Session (hier: Logs eines zweiten Prozesses) erkennt der Client den
-- Ausfall, ein zweiter Worker uebernimmt den geschlossenen Prozess, und der Client wiederholt alles
-- Ungeschriebene einschliesslich CLOSE.
--
--   Ablauf (Modus SERVER, ohne Dispatcher):
--   1. Nur LT_S1 laeuft; Prozess P1 entsteht dort. Danach startet LT_S2, Prozess P2 entsteht dort
--      (Serverauswahl: wenigste offene Prozesse).
--   2. Phase 1: Logs und Events in P1, Leerlauf-Flush abwarten.
--   3. Phase 2: weitere Logs und Events in P1, sofort danach Abbruch von LT_S1 per STOP_JOB
--      (ohne Drain) und sofort CLOSE_PROCESS(P1). Der Heartbeat von LT_S1 ist dabei noch frisch.
--   4. Phase 3: Logs in P2, bis process_end von P1 gesetzt ist (hoechstens 30 s).
--   5. CLOSE_PROCESS(P2) auf dem lebenden LT_S2 (Normalfall der Bestaetigung).
--
--   Erwartet: CLOSE_PROCESS(P1) blockiert nicht; alle Logs von P1 genau einmal, Events lueckenlos ohne
--   Dubletten; P1 geschlossen mit Info und Status aus dem CLOSE; Uebernahme in LILAM_LOG_INTERNAL;
--   keine Route und keine Wasserstaende fuer P1 und P2; P2 vollstaendig und geschlossen.
--
-- Voraussetzungen: LILAM installiert (Branch fallback), _COMMON/01_install_testbasis.sql
-- =====================================================================
set serveroutput on size unlimited

declare
  c_name    constant varchar2(30) := 'LT_FO_CLOSE';
  c_n1      constant pls_integer := 300;   -- Logs P1 Phase 1
  c_n2      constant pls_integer := 300;   -- Logs P1 Phase 2 (vor dem Abbruch)
  l_run     number;
  l_pid     number;
  l_pid2    number;
  l_t0      timestamp;
  l_ts_kill timestamp;
  l_close_ms number;
  l_n       number;
  l_d       number;
  l_mx      number;
  l_txt     varchar2(4000);
  l_no      pls_integer := 0;
  l_ev      pls_integer := 0;
  l_no2     pls_integer := 0;

  procedure logs(p_cnt pls_integer) is
  begin
    for i in 1 .. p_cnt loop
      l_no := l_no + 1;
      lilam.info(l_pid, 'FC#' || lpad(l_no, 5, '0'));
      if mod(i, 15) = 0 then
        l_ev := l_ev + 1;
        lilam.mark_event(l_pid, 'FC_EV');
      end if;
    end loop;
  end;

  function q(p_sql varchar2, p_id number default null) return number is r number;
  begin
    execute immediate p_sql into r using nvl(p_id, l_pid);
    return r;
  exception when others then return -1;
  end;
begin
  l_run := lt.begin_run('FAILOVER_CLOSE', 'SERVER', 'n1=' || c_n1 || ',n2=' || c_n2);
  lt.stop_all_servers;

  -- 1. P1 auf LT_S1, P2 auf LT_S2
  lt.start_server('LT_S1');
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1'));
  l_pid := lilam.server_new_process(c_name, lt.c_group, p_logLevel => lilam.logLevelInfo);
  lt.check_that(l_run, 'P1 auf LT_S1 angelegt', l_pid > 0 and upper(lilam.get_server_pipe(l_pid)) = 'LT_S1', 'pid=' || l_pid);
  lt.start_server('LT_S2');
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2'));
  l_pid2 := lilam.server_new_process(c_name || '_2', lt.c_group, p_logLevel => lilam.logLevelInfo);
  lt.check_that(l_run, 'P2 auf LT_S2 angelegt', l_pid2 > 0 and upper(lilam.get_server_pipe(l_pid2)) = 'LT_S2',
                'pid=' || l_pid2 || ' auf ' || lilam.get_server_pipe(l_pid2));
  dbms_output.put_line('P1 ' || l_pid || ' auf ' || lilam.get_server_pipe(l_pid) || ', P2 ' || l_pid2 || ' auf ' || lilam.get_server_pipe(l_pid2));

  -- 2. Phase 1
  logs(c_n1);
  dbms_session.sleep(2);   -- Phase 1 ist geschrieben (Leerlauf-Flush)

  -- 3. Phase 2, Abbruch von LT_S1, sofort CLOSE_PROCESS
  logs(c_n2);
  l_ts_kill := systimestamp;
  dbms_scheduler.stop_job('LT_S1');
  l_t0 := systimestamp;
  lilam.close_process(l_pid, 'FC Ende', 1);
  l_close_ms := lt.ms_since(l_t0);
  lt.metric(l_run, 'close_p1_ms', l_close_ms, 'ms');
  lt.check_that(l_run, 'CLOSE_PROCESS(P1) blockiert nicht', l_close_ms < 1000, l_close_ms || ' ms');
  dbms_output.put_line('LT_S1 abgebrochen nach ' || l_no || ' Logs; geschrieben bis dahin: '
                       || q('select count(*) from lilam_log where process_id = :1 and info like ''FC#%''')
                       || ', process_end gesetzt: '
                       || q('select count(*) from lilam_proc where id = :1 and process_end is not null'));

  -- 4. Phase 3: spaetere Aufrufe derselben Session pruefen das offene CLOSE von P1
  l_t0 := systimestamp;
  loop
    l_no2 := l_no2 + 1;
    lilam.info(l_pid2, 'FC2#' || lpad(l_no2, 5, '0'));
    exit when q('select count(*) from lilam_proc where id = :1 and process_end is not null') = 1
              or lt.ms_since(l_t0) > 30000;
    dbms_session.sleep(0.2);
  end loop;
  lt.metric(l_run, 'close_p1_confirmed_ms', lt.ms_since(l_t0), 'ms');
  dbms_output.put_line('process_end von P1 nach ' || lt.ms_since(l_t0) || ' ms, ' || l_no2 || ' Logs in P2');

  -- Warten, bis die wiederholten Logs von P1 geschrieben sind (CLOSE schreibt sie vor process_end)
  l_t0 := systimestamp;
  loop
    exit when q('select count(*) from lilam_log where process_id = :1 and info like ''FC#%''') >= l_no
              or lt.ms_since(l_t0) > 5000;
    dbms_session.sleep(0.25);
  end loop;

  -- 5. P2 normal schliessen
  lilam.close_process(l_pid2, 'FC2 Ende', 1);
  l_t0 := systimestamp;
  loop
    exit when q('select count(*) from lilam_proc where id = :1 and process_end is not null', l_pid2) = 1
              or lt.ms_since(l_t0) > 10000;
    dbms_session.sleep(0.25);
  end loop;

  -- Pruefungen P1
  l_n := q('select count(*) from lilam_proc where id = :1 and process_end is not null and info = ''FC Ende'' and status = 1');
  lt.check_that(l_run, 'P1 geschlossen mit Info und Status', l_n = 1);
  l_n := q('select count(*) from lilam_log where process_id = :1 and info like ''FC#%''');
  l_d := q('select count(distinct info) from lilam_log where process_id = :1 and info like ''FC#%''');
  lt.check_that(l_run, 'P1 alle Logs geschrieben', l_d = l_no, 'erwartet ' || l_no || ', verschieden ' || l_d);
  lt.check_that(l_run, 'P1 keine doppelten Logs', l_n = l_d, 'Zeilen ' || l_n || ', verschieden ' || l_d);
  l_n := q('select count(*) from (select no from lilam_log where process_id = :1 group by no having count(*) > 1)');
  lt.check_that(l_run, 'P1 Lognummern eindeutig', l_n = 0, l_n || ' doppelte Nummern');

  l_n  := q('select count(*) from lilam_mon where process_id = :1 and action = ''FC_EV'' and mon_type = 0');
  l_d  := q('select count(distinct action_count) from lilam_mon where process_id = :1 and action = ''FC_EV'' and mon_type = 0');
  l_mx := q('select max(action_count) from lilam_mon where process_id = :1 and action = ''FC_EV'' and mon_type = 0');
  lt.check_that(l_run, 'P1 Events vollstaendig, lueckenlos, ohne Dubletten', l_n = l_ev and l_d = l_ev and l_mx = l_ev,
                'erwartet ' || l_ev || ', Zeilen ' || l_n || ', verschieden ' || l_d || ', max ' || l_mx);

  select count(*), max(error_message) into l_n, l_txt from lilam_log_internal
   where log_timestamp >= l_ts_kill and log_operation = 'FAILOVER' and error_message like '%' || l_pid || '%';
  lt.check_that(l_run, 'Uebernahme von P1 protokolliert', l_n >= 1, substr(l_txt, 1, 900));

  l_n := q('select count(*) from lilam_process_route where process_id = :1');
  lt.check_that(l_run, 'P1 keine Route', l_n = 0, l_n || ' Zeilen');
  l_n := q('select count(*) from lilam_watermark where process_id = :1');
  lt.check_that(l_run, 'P1 keine Wasserstaende', l_n = 0, l_n || ' Zeilen');

  -- Pruefungen P2
  l_n := q('select count(*) from lilam_proc where id = :1 and process_end is not null and info = ''FC2 Ende''', l_pid2);
  lt.check_that(l_run, 'P2 geschlossen', l_n = 1);
  l_d := q('select count(distinct info) from lilam_log where process_id = :1 and info like ''FC2#%''', l_pid2);
  lt.check_that(l_run, 'P2 alle Logs geschrieben', l_d = l_no2, 'erwartet ' || l_no2 || ', verschieden ' || l_d);
  l_n := q('select count(*) from lilam_process_route where process_id = :1', l_pid2)
       + q('select count(*) from lilam_watermark where process_id = :1', l_pid2);
  lt.check_that(l_run, 'P2 keine Route und keine Wasserstaende', l_n = 0, l_n || ' Zeilen');

  lt.metric(l_run, 'logs_p1', l_no, 'rows');
  lt.metric(l_run, 'logs_p2', l_no2, 'rows');
  lt.metric(l_run, 'internal_errors', lt.internal_errors_since(l_ts_kill), 'rows');
  lt.stop_all_servers;
  lt.end_run(l_run);
exception
  when others then
    dbms_output.put_line('ABBRUCH: ' || sqlerrm);
    lt.check_that(l_run, 'Testablauf ohne Abbruch', false, substr(sqlerrm || ' ' || dbms_utility.format_error_backtrace, 1, 900));
    lt.end_run(l_run);
    lt.stop_all_servers;
end;
/

-- Ergebnis
select check_name, ok, detail from lt_check where run_id = (select max(run_id) from lt_run where test_name = 'FAILOVER_CLOSE') order by check_no;
select error_code, log_operation, module_name, substr(error_message, 1, 300) msg
  from lilam_log_internal
 where log_timestamp >= (select started from lt_run where run_id = (select max(run_id) from lt_run where test_name = 'FAILOVER_CLOSE'))
 order by log_timestamp;
