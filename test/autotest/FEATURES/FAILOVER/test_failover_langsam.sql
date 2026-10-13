-- =====================================================================
-- LILAM Test: FEATURES / FAILOVER (FAILOVER_LANGSAM)
--
-- D5: Ein Client, der selten meldet (1 Meldung/s), muss den Ausfall seines Workers nach wenigen
-- Sekunden bemerken, nicht erst nach 100 Meldungen.
--
--   Ablauf (Modus SERVER, ohne Dispatcher):
--   1. Nur LT_S1 laeuft; der Prozess entsteht dort. Danach startet LT_S2.
--   2. Phase 1: 5 Logs im Abstand von 1 s, dazu 1 Event; 2 s Pause (geschrieben).
--   3. LT_S1 wird per STOP_JOB abgebrochen.
--   4. Phase 2: 1 Log/s, bis der Client auf LT_S2 umgestellt hat (hoechstens 40 s), danach 3 weitere Logs.
--   5. CLOSE_PROCESS.
--
--   Erwartet: Uebernahme spaetestens 12 s nach dem Abbruch (erwartet ca. 6-7 s: 1 s bis zur ersten
--   ungeschriebenen Meldung, 5 s Heartbeat-Grenze, 1 s Leseabstand; vor D5 100-200 s),
--   alle Logs genau einmal, Prozess geschlossen, Uebernahme in LILAM_LOG_INTERNAL.
--
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- =====================================================================
set serveroutput on size unlimited

declare
  c_name      constant varchar2(30) := 'LT_FO_LANGSAM';
  c_n1        constant pls_integer := 5;       -- Logs vor dem Abbruch
  c_n_after   constant pls_integer := 3;       -- Logs nach der Uebernahme
  c_max_s     constant pls_integer := 40;      -- Abbruch der Phase 2
  c_limit_ms  constant pls_integer := 12000;   -- Grenze fuer die Uebernahme
  l_run       number;
  l_pid       number;
  l_t0        timestamp;
  l_ts_kill   timestamp;
  l_takeover  number;
  l_n         number;
  l_d         number;
  l_txt       varchar2(4000);
  l_no        pls_integer := 0;

  procedure log1 is
  begin
    l_no := l_no + 1;
    lilam.info(l_pid, 'FL#' || lpad(l_no, 5, '0'));
  end;

  function q(p_sql varchar2) return number is r number;
  begin
    execute immediate p_sql into r using l_pid;
    return r;
  exception when others then return -1;
  end;
begin
  l_run := lt.begin_run('FAILOVER_LANGSAM', 'SERVER', 'rate=1/s,limit=' || c_limit_ms || 'ms');
  lt.stop_all_servers;

  -- 1. Prozess auf LT_S1, danach LT_S2
  lt.start_server('LT_S1');
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1'));
  l_pid := lilam.server_new_process(c_name, lt.c_group, p_logLevel => lilam.logLevelInfo);
  dbms_output.put_line('Prozess ' || l_pid || ' auf ' || lilam.get_server_pipe(l_pid));
  lt.check_that(l_run, 'Prozess auf LT_S1 angelegt', l_pid > 0 and upper(lilam.get_server_pipe(l_pid)) = 'LT_S1', 'pid=' || l_pid);
  lt.start_server('LT_S2');
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2'));

  -- 2. Phase 1: langsam melden
  for i in 1 .. c_n1 loop
    log1;
    if i = 3 then
      lilam.mark_event(l_pid, 'FL_EV');
    end if;
    dbms_session.sleep(1);
  end loop;
  dbms_session.sleep(2);
  lt.check_that(l_run, 'Phase 1 geschrieben',
                q('select count(*) from lilam_log where process_id = :1 and info like ''FL#%''') = c_n1);

  -- 3. Abbruch von LT_S1
  l_ts_kill := systimestamp;
  dbms_scheduler.stop_job('LT_S1');

  -- 4. Phase 2: 1 Meldung/s bis zur Uebernahme
  loop
    dbms_session.sleep(1);
    log1;
    if upper(lilam.get_server_pipe(l_pid)) = 'LT_S2' then
      l_takeover := lt.ms_since(l_ts_kill);
      exit;
    end if;
    exit when lt.ms_since(l_ts_kill) > c_max_s * 1000;
  end loop;
  dbms_output.put_line('Uebernahme nach ' || nvl(to_char(l_takeover), 'keiner') || ' ms, Logs bis dahin ' || l_no);
  lt.metric(l_run, 'takeover_ms', nvl(l_takeover, -1), 'ms');
  lt.check_that(l_run, 'Uebernahme durch LT_S2', l_takeover is not null, lilam.get_server_pipe(l_pid));
  lt.check_that(l_run, 'Uebernahme hoechstens ' || c_limit_ms || ' ms nach Abbruch', l_takeover <= c_limit_ms,
                nvl(to_char(l_takeover), 'keine') || ' ms');

  for i in 1 .. c_n_after loop
    dbms_session.sleep(1);
    log1;
  end loop;
  lilam.close_process(l_pid, 'FL Ende', 1);

  -- Warten, bis alles geschrieben ist
  l_t0 := systimestamp;
  loop
    l_n := q('select count(*) from lilam_log where process_id = :1 and info like ''FL#%''');
    exit when (l_n >= l_no and q('select count(*) from lilam_proc where id = :1 and process_end is not null') = 1)
              or lt.ms_since(l_t0) > 20000;
    dbms_session.sleep(0.25);
  end loop;

  -- Pruefungen
  l_n := q('select count(*) from lilam_log where process_id = :1 and info like ''FL#%''');
  l_d := q('select count(distinct info) from lilam_log where process_id = :1 and info like ''FL#%''');
  lt.check_that(l_run, 'Alle Logs geschrieben', l_d = l_no, 'erwartet ' || l_no || ', verschieden ' || l_d);
  lt.check_that(l_run, 'Keine doppelten Logs', l_n = l_d, 'Zeilen ' || l_n || ', verschieden ' || l_d);

  l_n := q('select count(*) from lilam_mon where process_id = :1 and action = ''FL_EV'' and mon_type = 0');
  lt.check_that(l_run, 'Event genau einmal', l_n = 1, l_n || ' Zeilen');

  l_n := q('select count(*) from lilam_proc where id = :1 and process_end is not null');
  lt.check_that(l_run, 'Prozess geschlossen', l_n = 1);

  select count(*), max(error_message) into l_n, l_txt from lilam_log_internal
   where log_timestamp >= l_ts_kill and log_operation = 'FAILOVER' and error_message like '%' || l_pid || '%';
  lt.check_that(l_run, 'Uebernahme protokolliert', l_n >= 1, substr(l_txt, 1, 900));

  l_n := q('select count(*) from lilam_process_route where process_id = :1');
  lt.check_that(l_run, 'Keine Route nach CLOSE_PROCESS', l_n = 0, l_n || ' Zeilen');

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
select check_name, ok, detail from lt_check where run_id = (select max(run_id) from lt_run where test_name = 'FAILOVER_LANGSAM') order by check_no;
select error_code, log_operation, module_name, substr(error_message, 1, 300) msg
  from lilam_log_internal
 where log_timestamp >= (select started from lt_run where run_id = (select max(run_id) from lt_run where test_name = 'FAILOVER_LANGSAM'))
 order by log_timestamp;
