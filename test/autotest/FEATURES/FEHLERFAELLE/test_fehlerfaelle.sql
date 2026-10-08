-- =====================================================================
-- LILAM Test: FEATURES / FEHLERFAELLE
--
-- Prueft, dass Stoerungen im Decoupled-Mode die Anwendung nicht beeintraechtigen:
-- keine Exception, keine langen Wartezeiten, keine verwaisten Prozesse.
--
--   F1  SERVER_NEW_PROCESS ohne aktiven Server      -> negative ID, keine Exception
--   F2  Alle API-Aufrufe mit negativer ID           -> still, ohne Dispatcher
--   F3  Alle API-Aufrufe mit negativer ID           -> still und schnell, mit Standard-Dispatcher
--   F4  Veraltete ID nach CLOSE_PROCESS (Dispatcher) -> still und schnell, keine weiteren Daten
--   F5  Takt-Handshake ueber den Dispatcher         -> kein Warten auf Timeout
--   F6  Verfallene NEW_PROCESS-Anfrage (direkt per Pipe)    -> Server legt keinen Prozess an
--
-- Hinweis: Das Skript setzt in der eigenen Session einen Dispatcher und setzt am Ende
-- den Package-Zustand zurueck (DBMS_SESSION.MODIFY_PACKAGE_STATE).
--
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- =====================================================================
set serveroutput on size unlimited

declare
  c_neg     constant number := lilam.NUM_ERR_PROCESS_TIMEOUT;
  l_run     number;
  l_t0      timestamp;
  l_pid     number;
  l_cnt     number;
  l_int0    number;
  l_ms      number;
  l_exc     pls_integer;
  l_info    varchar2(4000);

  -- Alle prozessbezogenen API-Aufrufe; liefert die Anzahl der Ausnahmen
  function call_all(p_pid number, p_detail out varchar2) return pls_integer is
    n pls_integer := 0; r lilam.t_process_rec; v varchar2(4000); x number; ts timestamp;
    procedure e(p varchar2) is begin n := n + 1; p_detail := substr(p_detail || p || ': ' || sqlerrm || '; ', 1, 3000); end;
  begin
    begin lilam.info(p_pid, 'x');                 exception when others then e('INFO'); end;
    begin lilam.debug(p_pid, 'x');                exception when others then e('DEBUG'); end;
    begin lilam.warn(p_pid, 'x');                 exception when others then e('WARN'); end;
    begin lilam.error(p_pid, 'x');                exception when others then e('ERROR'); end;
    begin lilam.mark_event(p_pid, 'E');           exception when others then e('MARK_EVENT'); end;
    begin lilam.trace_start(p_pid, 'T');          exception when others then e('TRACE_START'); end;
    begin lilam.trace_stop(p_pid, 'T');           exception when others then e('TRACE_STOP'); end;
    begin lilam.set_process_status(p_pid, 1, 'x'); exception when others then e('SET_PROCESS_STATUS'); end;
    begin lilam.set_proc_steps_todo(p_pid, 5);    exception when others then e('SET_PROC_STEPS_TODO'); end;
    begin lilam.set_proc_steps_done(p_pid, 5);    exception when others then e('SET_PROC_STEPS_DONE'); end;
    begin lilam.proc_step_done(p_pid);            exception when others then e('PROC_STEP_DONE'); end;
    begin lilam.set_proc_immortal(p_pid, 1);      exception when others then e('SET_PROC_IMMORTAL'); end;
    begin x := lilam.get_proc_steps_done(p_pid);  exception when others then e('GET_PROC_STEPS_DONE'); end;
    begin x := lilam.get_proc_steps_todo(p_pid);  exception when others then e('GET_PROC_STEPS_TODO'); end;
    begin ts := lilam.get_process_start(p_pid);   exception when others then e('GET_PROCESS_START'); end;
    begin ts := lilam.get_process_end(p_pid);     exception when others then e('GET_PROCESS_END'); end;
    begin x := lilam.get_process_status(p_pid);   exception when others then e('GET_PROCESS_STATUS'); end;
    begin v := lilam.get_process_info(p_pid);     exception when others then e('GET_PROCESS_INFO'); end;
    begin r := lilam.get_process_data(p_pid);     exception when others then e('GET_PROCESS_DATA'); end;
    begin v := lilam.get_process_data_json(p_pid); exception when others then e('GET_PROCESS_DATA_JSON'); end;
    begin x := lilam.get_counter_warn(p_pid);     exception when others then e('GET_COUNTER_WARN'); end;
    begin x := lilam.get_counter_error(p_pid);    exception when others then e('GET_COUNTER_ERROR'); end;
    begin x := lilam.get_metric_avg_duration(p_pid, 'T'); exception when others then e('GET_METRIC_AVG_DURATION'); end;
    begin x := lilam.get_metric_steps(p_pid, 'T'); exception when others then e('GET_METRIC_STEPS'); end;
    begin v := lilam.get_server_pipe(p_pid);      exception when others then e('GET_SERVER_PIPE'); end;
    begin lilam.close_process(p_pid, 'x', 1);     exception when others then e('CLOSE_PROCESS'); end;
    return n;
  end;

  function internal_new return number is c number;
  begin
    select count(*) into c from user_tables where table_name = 'LILAM_LOG_INTERNAL';
    if c = 0 then return 0; end if;
    execute immediate 'select count(*) from lilam_log_internal' into c;
    return c - l_int0;
  end;
begin
  l_run := lt.begin_run('FEHLERFAELLE', 'SERVER+DISPATCHER');
  lt.stop_all_servers;
  l_int0 := 0; l_int0 := internal_new;

  -- F1: kein Server aktiv
  l_t0 := systimestamp;
  begin
    l_pid := lilam.server_new_process(p_processName => 'LT_' || l_run || '_F1', p_groupName => 'LT_KEIN_SERVER');
    lt.check_that(l_run, 'F1 SERVER_NEW_PROCESS ohne Server: negative ID, keine Exception', l_pid < 0, 'ID ' || l_pid);
  exception when others then
    lt.check_that(l_run, 'F1 SERVER_NEW_PROCESS ohne Server: negative ID, keine Exception', false, sqlerrm);
  end;
  lt.metric(l_run, 'f1_new_session_ms', lt.ms_since(l_t0), 'ms');

  -- F2: negative ID ohne Dispatcher
  l_info := null; l_t0 := systimestamp;
  l_exc := call_all(c_neg, l_info);
  l_ms := lt.ms_since(l_t0);
  lt.check_that(l_run, 'F2 26 API-Aufrufe mit negativer ID ohne Exception (ohne Dispatcher)', l_exc = 0, l_exc || ' Ausnahmen ' || l_info);
  lt.metric(l_run, 'f2_26_calls_ms', l_ms, 'ms');

  -- Server und Dispatcher starten, Standard-Dispatcher setzen (wie in APEX)
  lt.start_server('LT_S1'); lt.start_server('LT_S2'); lt.start_server('LT_DISP', 1);
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2', 'LT_DISP'));
  lilam.set_dispatcher_pipe('LT_DISP');

  -- F3: negative ID mit Dispatcher
  l_info := null; l_t0 := systimestamp;
  l_exc := call_all(c_neg, l_info);
  l_ms := lt.ms_since(l_t0);
  lt.check_that(l_run, 'F3 26 API-Aufrufe mit negativer ID ohne Exception (mit Dispatcher)', l_exc = 0, l_exc || ' Ausnahmen ' || l_info);
  lt.check_that(l_run, 'F3 ... und ohne Wartezeit (< 500 ms gesamt)', l_ms < 500, round(l_ms) || ' ms');
  lt.metric(l_run, 'f3_26_calls_ms', l_ms, 'ms');

  -- F4: veraltete ID nach CLOSE_PROCESS
  l_pid := lilam.server_new_process(p_processName => 'LT_' || l_run || '_F4', p_groupName => 'LT', p_logLevel => lilam.logLevelInfo);
  lilam.info(l_pid, 'vor close');
  lilam.close_process(l_pid);
  l_t0 := systimestamp;
  for i in 1 .. 20 loop
    lilam.info(l_pid, 'nach close ' || i);
    lilam.mark_event(l_pid, 'NACH_CLOSE');
  end loop;
  l_ms := lt.ms_since(l_t0);
  lt.check_that(l_run, 'F4 40 Aufrufe mit veralteter ID ohne Wartezeit (< 1000 ms gesamt)', l_ms < 1000, round(l_ms) || ' ms');
  lt.metric(l_run, 'f4_40_calls_ms', l_ms, 'ms');
  dbms_session.sleep(2);
  select count(*) into l_cnt from lilam_log where process_id = l_pid;
  lt.check_that(l_run, 'F4 keine Daten nach CLOSE_PROCESS gespeichert', l_cnt = 1, l_cnt || ' Logs (soll 1)');

  -- F5: Takt-Handshake ueber den Dispatcher (2.500 Nachrichten in < 1 s loesen bei Leistungsstufe MID
  --     = 1.500 mindestens einen Handshake aus)
  l_pid := lilam.server_new_process(p_processName => 'LT_' || l_run || '_F5', p_groupName => 'LT', p_logLevel => lilam.logLevelInfo);
  l_t0 := systimestamp;
  for i in 1 .. 2500 loop lilam.info(l_pid, 'last ' || i); end loop;
  l_ms := lt.ms_since(l_t0);
  lilam.close_process(l_pid);
  lt.check_that(l_run, 'F5 Handshake ueber Dispatcher ohne Timeout (2.500 INFO < 5 s)', l_ms < 5000, round(l_ms) || ' ms');
  lt.metric(l_run, 'f5_2500_info_ms', l_ms, 'ms');
  l_ms  := lt.wait_count('LT_' || l_run || '_F5', 'LOG', 2500, 30);   -- liefert Wartezeit in ms (-1 = Timeout)
  l_cnt := lt.count_lilam('LT_' || l_run || '_F5', 'LOG');
  lt.check_that(l_run, 'F5 alle 2.500 Logs angekommen', l_cnt = 2500, l_cnt);

  -- F6: verfallene NEW_PROCESS-Anfrage direkt an einen Worker
  declare
    ch varchar2(50) := 'LT_F6_' || sys_context('USERENV', 'SID');
    st pls_integer; m varchar2(4000);
  begin
    dbms_pipe.reset_buffer;
    dbms_pipe.pack_message('{"header":{"msg_type":"API_CALL","request":"NEW_SESSION","response":"' || ch
       || '"},"payload":{"process_name":"LT_' || l_run || '_F6","group_name":"LT","expires_utc":"'
       || to_char(sys_extract_utc(systimestamp) - interval '1' second, 'YYYY-MM-DD"T"HH24:MI:SS.FF6') || '"}}');
    st := dbms_pipe.send_message('LT_S1', timeout => 2);
    st := dbms_pipe.receive_message(ch, timeout => 2);
    lt.check_that(l_run, 'F6 verfallene NEW_PROCESS-Anfrage: keine Antwort an den Client', st = 1, 'Status ' || st);
    st := dbms_pipe.remove_pipe(ch);
  end;
  select count(*) into l_cnt from lilam_proc where process_name = 'LT_' || l_run || '_F6';
  lt.check_that(l_run, 'F6 verfallene NEW_PROCESS-Anfrage: kein Prozess angelegt', l_cnt = 0, l_cnt);

  lt.stop_all_servers;

  -- Erwartete interne Eintraege: F1 (Verbindungsfehler, waitForResponse + SERVER_NEW_PROCESS_JSON)
  -- und F6 (doRemote_newProcess / EXPIRED); sonst nichts
  execute immediate 'select count(*) from lilam_log_internal where log_timestamp >= :1
                       and module_name not in (''waitForResponse'', ''SERVER_NEW_PROCESS_JSON'', ''doRemote_newProcess'')'
     into l_cnt using lt.run_started(l_run);
  lt.check_that(l_run, 'Keine unerwarteten internen Protokolleintraege', l_cnt = 0, l_cnt);
  execute immediate 'select count(*) from lilam_log_internal where log_timestamp >= :1
                       and module_name = ''doRemote_newProcess'' and log_operation = ''EXPIRED'''
     into l_cnt using lt.run_started(l_run);
  lt.check_that(l_run, 'F6 verfallene NEW_PROCESS-Anfrage intern protokolliert', l_cnt = 1, l_cnt);

  lt.end_run(l_run);

  -- Package-Zustand (Dispatcher-Konfiguration) dieser Session zuruecksetzen
  dbms_session.modify_package_state(dbms_session.reinitialize);
exception
  when others then
    dbms_output.put_line('ABBRUCH: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
    lt.stop_all_servers;
    raise;
end;
/
