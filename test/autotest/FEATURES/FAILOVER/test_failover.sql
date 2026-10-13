-- =====================================================================
-- LILAM Test: FEATURES / FAILOVER
--
-- Ein Worker faellt aus, ein zweiter Worker derselben Gruppe uebernimmt seinen Prozess
-- (ADOPT_PROCESS); der Client wiederholt aus dem Ringpuffer, was nicht committet war.
--
--   Ablauf (Modus SERVER, ohne Dispatcher):
--   1. Nur LT_S1 laeuft; der Prozess entsteht dort. Danach startet LT_S2.
--   2. Phase 1: Logs, Events, ein abgeschlossener und ein offener Trace (FO_OPEN).
--   3. Phase 2: weitere Logs und Events, sofort danach wird LT_S1 per STOP_JOB abgebrochen
--      (ohne Drain, gepufferte Daten des Servers gehen verloren).
--   4. Phase 3: weitere Logs und Events ueber ca. 10 s (der Heartbeat gilt erst nach 5 s als veraltet),
--      TRACE_STOP fuer FO_OPEN, CLOSE_PROCESS.
--
--   Erwartet: alle Logs genau einmal, Events lueckenlos nummeriert ohne Dubletten, der offene Trace
--   ist mit Dauer geschrieben, Prozess geschlossen, Uebernahme in LILAM_LOG_INTERNAL, keine Route und
--   keine Wasserstaende mehr nach CLOSE_PROCESS.
--
-- Voraussetzungen: LILAM installiert (Branch fallback), _COMMON/01_install_testbasis.sql
-- =====================================================================
set serveroutput on size unlimited

declare
  c_name    constant varchar2(30) := 'LT_FO_SERVER';
  c_n1      constant pls_integer := 300;   -- Logs Phase 1
  c_n2      constant pls_integer := 300;   -- Logs Phase 2 (vor dem Abbruch)
  c_n3      constant pls_integer := 300;   -- Logs Phase 3 (nach dem Abbruch)
  c_ev      constant pls_integer := 20;    -- Events je Phase
  l_run     number;
  l_pid     number;
  l_t0      timestamp;
  l_ts_kill timestamp;
  l_n       number;
  l_d       number;
  l_mx      number;
  l_txt     varchar2(4000);
  l_no      pls_integer := 0;
  l_ev      pls_integer := 0;

  procedure logs(p_cnt pls_integer, p_sleep_every pls_integer default 0) is
  begin
    for i in 1 .. p_cnt loop
      l_no := l_no + 1;
      lilam.info(l_pid, 'FO#' || lpad(l_no, 5, '0'));
      if mod(i, 15) = 0 then
        l_ev := l_ev + 1;
        lilam.mark_event(l_pid, 'FO_EV');
      end if;
      if p_sleep_every > 0 and mod(i, p_sleep_every) = 0 then
        dbms_session.sleep(0.1);
      end if;
    end loop;
  end;

  function q(p_sql varchar2) return number is r number;
  begin
    execute immediate p_sql into r using l_pid;
    return r;
  exception when others then return -1;
  end;
begin
  l_run := lt.begin_run('FAILOVER', 'SERVER', 'n1=' || c_n1 || ',n2=' || c_n2 || ',n3=' || c_n3);
  lt.stop_all_servers;

  -- 1. Prozess auf LT_S1, danach LT_S2
  lt.start_server('LT_S1');
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1'));
  l_pid := lilam.server_new_process(c_name, lt.c_group, p_logLevel => lilam.logLevelInfo);
  dbms_output.put_line('Prozess ' || l_pid || ' auf ' || lilam.get_server_pipe(l_pid));
  lt.check_that(l_run, 'Prozess auf LT_S1 angelegt', l_pid > 0 and upper(lilam.get_server_pipe(l_pid)) = 'LT_S1', 'pid=' || l_pid);
  lt.start_server('LT_S2');
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2'));

  -- 2. Phase 1
  lilam.trace_start(l_pid, 'FO_DONE');
  logs(c_n1);
  lilam.trace_stop(l_pid, 'FO_DONE');
  lilam.trace_start(l_pid, 'FO_OPEN');
  dbms_session.sleep(2);   -- Phase 1 ist geschrieben (Leerlauf-Flush)

  -- 3. Phase 2 und Abbruch von LT_S1
  logs(c_n2);
  l_ts_kill := systimestamp;
  dbms_scheduler.stop_job('LT_S1');
  dbms_output.put_line('LT_S1 abgebrochen nach ' || l_no || ' Logs; geschrieben bis dahin: '
                       || q('select count(*) from lilam_log where process_id = :1 and info like ''FO#%'''));

  -- 4. Phase 3: der Client merkt den Ausfall am stockenden Wasserstand
  l_t0 := systimestamp;
  logs(c_n3, 3);
  lilam.trace_stop(l_pid, 'FO_OPEN');
  lt.metric(l_run, 'client_phase3_ms', lt.ms_since(l_t0), 'ms');
  dbms_output.put_line('Phase 3 in ' || lt.ms_since(l_t0) || ' ms, Server jetzt ' || lilam.get_server_pipe(l_pid));
  lt.check_that(l_run, 'Uebernahme waehrend Phase 3', upper(lilam.get_server_pipe(l_pid)) = 'LT_S2', lilam.get_server_pipe(l_pid));
  lilam.close_process(l_pid, 'FO Ende', 1);

  -- Warten, bis alles geschrieben ist
  l_t0 := systimestamp;
  loop
    l_n := q('select count(*) from lilam_log where process_id = :1 and info like ''FO#%''');
    exit when (l_n >= l_no and q('select count(*) from lilam_proc where id = :1 and process_end is not null') = 1)
              or lt.ms_since(l_t0) > 20000;
    dbms_session.sleep(0.25);
  end loop;

  -- Pruefungen
  l_n := q('select count(*) from lilam_log where process_id = :1 and info like ''FO#%''');
  l_d := q('select count(distinct info) from lilam_log where process_id = :1 and info like ''FO#%''');
  lt.check_that(l_run, 'Alle Logs geschrieben', l_d = l_no, 'erwartet ' || l_no || ', verschieden ' || l_d);
  lt.check_that(l_run, 'Keine doppelten Logs', l_n = l_d, 'Zeilen ' || l_n || ', verschieden ' || l_d);
  l_n := q('select count(*) from (select no from lilam_log where process_id = :1 group by no having count(*) > 1)');
  lt.check_that(l_run, 'Lognummern eindeutig', l_n = 0, l_n || ' doppelte Nummern');

  l_n  := q('select count(*) from lilam_mon where process_id = :1 and action = ''FO_EV'' and mon_type = 0');
  l_d  := q('select count(distinct action_count) from lilam_mon where process_id = :1 and action = ''FO_EV'' and mon_type = 0');
  l_mx := q('select max(action_count) from lilam_mon where process_id = :1 and action = ''FO_EV'' and mon_type = 0');
  lt.check_that(l_run, 'Events vollstaendig, lueckenlos, ohne Dubletten', l_n = l_ev and l_d = l_ev and l_mx = l_ev,
                'erwartet ' || l_ev || ', Zeilen ' || l_n || ', verschieden ' || l_d || ', max ' || l_mx);

  l_n := q('select count(*) from lilam_mon where process_id = :1 and action = ''FO_DONE'' and mon_type = 1');
  lt.check_that(l_run, 'Abgeschlossener Trace genau einmal', l_n = 1, l_n || ' Zeilen');
  l_n := q('select count(*) from lilam_mon where process_id = :1 and action = ''FO_OPEN'' and mon_type = 1 and used_millis > 0');
  lt.check_that(l_run, 'Offener Trace nach Uebernahme geschrieben', l_n = 1, l_n || ' Zeilen');

  l_n := q('select count(*) from lilam_proc where id = :1 and process_end is not null');
  lt.check_that(l_run, 'Prozess geschlossen', l_n = 1);

  select count(*), max(error_message) into l_n, l_txt from lilam_log_internal
   where log_timestamp >= l_ts_kill and log_operation = 'FAILOVER' and error_message like '%' || l_pid || '%';
  lt.check_that(l_run, 'Uebernahme protokolliert', l_n >= 1, substr(l_txt, 1, 900));

  l_n := q('select count(*) from lilam_process_route where process_id = :1');
  lt.check_that(l_run, 'Keine Route nach CLOSE_PROCESS', l_n = 0, l_n || ' Zeilen');
  l_n := q('select count(*) from lilam_watermark where process_id = :1');
  lt.check_that(l_run, 'Keine Wasserstaende nach CLOSE_PROCESS', l_n = 0, l_n || ' Zeilen');

  lt.metric(l_run, 'logs_total', l_no, 'rows');
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
select check_name, ok, detail from lt_check where run_id = (select max(run_id) from lt_run where test_name = 'FAILOVER') order by check_no;
select error_code, log_operation, module_name, substr(error_message, 1, 300) msg
  from lilam_log_internal
 where log_timestamp >= (select started from lt_run where run_id = (select max(run_id) from lt_run where test_name = 'FAILOVER'))
 order by log_timestamp;
