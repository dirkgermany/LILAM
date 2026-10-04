-- =====================================================================
-- Diagnose: Regeln und Alerts (Analyse 04.10.2026, kein Bestandteil der Testsuite)
--
-- Prueft das Verhalten der Rules Engine gegen erwartete Ergebnisse.
-- Phase A: Server LT_S1, Regeln per SERVER_UPDATE_RULES laden, Signale erzeugen
-- Phase B: neuer Prozess auf demselben Server (PROCESS_START mit geladenen Regeln)
-- Phase C: Neustart LT_S1, Regeln muessen aus der Registry nachgeladen werden
-- Phase D: Rule Set v2 mit "action": "" (wie Beispiel SEQ-009 in rules/README.md)
-- Phase E: INSESSION, dieselben Signale
-- Ergebnis: Ausgabe ueber dbms_output; danach Registry und LILAM_RULES zuruecksetzen.
-- =====================================================================
set serveroutput on size unlimited

declare
  c_set  constant varchar2(30) := 'LT_RULES';
  l_t0   timestamp := systimestamp;
  l_pid  number;
  l_ok   boolean;

  procedure put_rules is
  begin
    delete from lilam_rules where set_name = c_set;
    insert into lilam_rules(set_name, version, created, author, rule_set) values (c_set, 1, systimestamp, 'claude', q'~{
  "header": { "rule_set": "LT_RULES", "rule_set_version": 1, "description": "Diagnose Regeln" },
  "rules": [
    { "id": "R01", "trigger_type": "TRACE_STOP", "action": "RA_TRACE",
      "condition": { "operator": "MAX_DURATION_MS", "value": "50" },
      "alert": { "handler": "LT_RULE_ALERT", "severity": "WARN", "throttle_seconds": 0 } },
    { "id": "R04", "trigger_type": "MARK_EVENT", "action": "RA_B",
      "condition": { "operator": "PRECEDED_BY", "value": "RA_A" },
      "alert": { "handler": "LT_RULE_ALERT", "severity": "WARN", "throttle_seconds": 0 } },
    { "id": "R05", "trigger_type": "MARK_EVENT", "action": "RA_B2",
      "condition": { "operator": "PRECEDED_BY", "value": "RA_A2" },
      "alert": { "handler": "LT_RULE_ALERT", "severity": "WARN", "throttle_seconds": 0 } },
    { "id": "R06", "trigger_type": "MARK_EVENT", "action": "RA_B3",
      "condition": { "operator": "PRECEDED_BY", "value": "RA_A3" },
      "alert": { "handler": "LT_RULE_ALERT", "severity": "WARN", "throttle_seconds": 0 } },
    { "id": "R07", "trigger_type": "PROCESS_UPDATE", "action": "LT_RG_A",
      "condition": { "operator": "STATUS_EQUALS", "value": "3" },
      "alert": { "handler": "LT_RULE_ALERT", "severity": "WARN", "throttle_seconds": 0 } },
    { "id": "R08", "trigger_type": "PROCESS_STOP", "action": "LT_RG_A",
      "condition": { "operator": "STEPS_LEFT_HIGH", "value": "1" },
      "alert": { "handler": "LT_RULE_ALERT", "severity": "WARN", "throttle_seconds": 0 } },
    { "id": "R09", "trigger_type": "PROCESS_START", "action": "LT_RG_B",
      "condition": { "operator": "ON_START", "value": "" },
      "alert": { "handler": "LT_RULE_ALERT", "severity": "INFO", "throttle_seconds": 0 } },
    { "id": "R09C", "trigger_type": "PROCESS_START", "action": "LT_RG_C",
      "condition": { "operator": "ON_START", "value": "" },
      "alert": { "handler": "LT_RULE_ALERT", "severity": "INFO", "throttle_seconds": 0 } },
    { "id": "R10", "trigger_type": "MARK_EVENT", "action": "RA_X",
      "condition": { "operator": "PRECEDED_BY_WITHIN_MS", "value": "RA_A|1000" },
      "alert": { "handler": "LT_RULE_ALERT", "severity": "WARN", "throttle_seconds": 0 } },
    { "id": "R11", "trigger_type": "LOGGING", "action": "LOGGING",
      "condition": { "operator": "SEVERITY", "value": "ERROR" },
      "alert": { "handler": "LT_RULE_ALERT", "severity": "ERROR", "throttle_seconds": 0 } },
    { "id": "R12", "trigger_type": "MARK_EVENT", "action": "RA_T",
      "condition": { "operator": "ON_EVENT", "value": "" },
      "alert": { "handler": "LT_RULE_ALERT", "severity": "INFO", "throttle_seconds": 60 } },
    { "id": "R13", "trigger_type": "TRACE_START", "action": "RA_G",
      "condition": { "operator": "MAX_GAP_SECONDS", "value": "1" },
      "alert": { "handler": "LT_RULE_ALERT", "severity": "WARN", "throttle_seconds": 0 } },
    { "id": "R14", "trigger_type": "MARK_EVENT", "action": "RA_W",
      "condition": { "operator": "PRECEDED_BY_WITHIN_SECS", "value": "RA_V|5" },
      "alert": { "handler": "LT_RULE_ALERT", "severity": "WARN", "throttle_seconds": 0 } },
    { "id": "R15", "trigger_type": "MARK_EVENT", "action": "RA_M",
      "condition": { "operator": "MAX_GAP_SECONDS", "value": "1" },
      "alert": { "handler": "LT_RULE_ALERT", "severity": "WARN", "throttle_seconds": 0 } }
  ]
}~');
    insert into lilam_rules(set_name, version, created, author, rule_set) values (c_set, 2, systimestamp, 'claude', q'~{
  "header": { "rule_set": "LT_RULES", "rule_set_version": 2, "description": "Diagnose: leere action wie SEQ-009" },
  "rules": [
    { "id": "V2-1", "trigger_type": "LOGGING", "action": "",
      "condition": { "operator": "SEVERITY", "value": "ERROR" },
      "alert": { "handler": "LT_RULE_ALERT", "severity": "ERROR", "throttle_seconds": 0 } },
    { "id": "V2-2", "trigger_type": "MARK_EVENT", "action": "RA_T2",
      "condition": { "operator": "ON_EVENT", "value": "" },
      "alert": { "handler": "LT_RULE_ALERT", "severity": "INFO", "throttle_seconds": 0 } }
  ]
}~');
    commit;
  end;

  procedure signals(p_pid number) is
  begin
    -- R01: Trace 150 ms > 50 ms -> 1 Alert
    lilam.trace_start(p_pid, 'RA_TRACE'); dbms_session.sleep(0.15); lilam.trace_stop(p_pid, 'RA_TRACE');
    -- R04: Vorgaenger RA_A mit Kontext -> erwartet 0 Alerts
    lilam.mark_event(p_pid, 'RA_A', 'C1'); lilam.mark_event(p_pid, 'RA_B');
    -- R05: Vorgaenger RA_A2 ohne Kontext -> erwartet 0 Alerts (Kontrolle)
    lilam.mark_event(p_pid, 'RA_A2'); lilam.mark_event(p_pid, 'RA_B2');
    -- R06: Vorgaenger RA_A3, dazwischen ein INFO-Log -> erwartet 0 Alerts
    lilam.mark_event(p_pid, 'RA_A3'); lilam.info(p_pid, 'zwischendurch'); lilam.mark_event(p_pid, 'RA_B3');
    -- R07: Status 3 -> 1 Alert
    lilam.set_process_status(p_pid, 3);
    -- R10: dokumentierter Operator PRECEDED_BY_WITHIN_MS (im Code unbekannt)
    lilam.mark_event(p_pid, 'RA_X');
    -- R11: 1 ERROR -> 1 Alert, 3 INFO -> 0 Alerts
    lilam.info(p_pid, 'i1'); lilam.info(p_pid, 'i2'); lilam.info(p_pid, 'i3');
    lilam.error(p_pid, 'Fehler fuer R11');
    -- R12: zweimal ON_EVENT, throttle 60 s -> 1 Alert
    lilam.mark_event(p_pid, 'RA_T'); lilam.mark_event(p_pid, 'RA_T');
    -- R13: zwei Traces mit 1,5 s Abstand, MAX_GAP_SECONDS 1 auf TRACE_START -> laut Doku 1 Alert
    lilam.trace_start(p_pid, 'RA_G'); lilam.trace_stop(p_pid, 'RA_G');
    dbms_session.sleep(1.5);
    lilam.trace_start(p_pid, 'RA_G'); lilam.trace_stop(p_pid, 'RA_G');
    -- R15: zwei Events mit 1,5 s Abstand, MAX_GAP_SECONDS 1 -> 1 Alert
    lilam.mark_event(p_pid, 'RA_M'); dbms_session.sleep(1.5); lilam.mark_event(p_pid, 'RA_M');
    -- R14: RA_V direkt vor RA_W -> 0 Alerts (Kontrolle)
    lilam.mark_event(p_pid, 'RA_V'); lilam.mark_event(p_pid, 'RA_W');
  end;

  procedure report(p_phase varchar2, p_since timestamp) is
  begin
    dbms_output.put_line('--- ' || p_phase);
    for r in (select rule_id, process_name, count(*) n from lilam_alerts
               where created_at >= p_since and process_name like 'LT\_RG\_%' escape '\'
               group by rule_id, process_name order by rule_id) loop
      dbms_output.put_line('    Alert ' || rpad(r.rule_id, 6) || r.process_name || ': ' || r.n);
    end loop;
    for e in (select module_name, substr(error_message, 1, 120) msg, count(*) n from lilam_log_internal
               where log_timestamp >= p_since group by module_name, substr(error_message, 1, 120) order by 3 desc) loop
      dbms_output.put_line('    intern ' || e.n || 'x ' || e.module_name || ': ' || e.msg);
    end loop;
  end;

  procedure wait_s(p number) is begin dbms_session.sleep(p); end;

begin
  put_rules;
  lt.stop_all_servers;
  update lilam_server_registry set rule_set_name = null, set_in_use = 0 where pipe_name = 'LT_S1';
  commit;

  -- Phase A
  l_t0 := systimestamp;
  lt.start_server('LT_S1');
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1'));
  l_pid := lilam.server_new_session('LT_RG_A', 'LT', lilam.logLevelInfo, p_procStepsToDo => 5);
  lilam.server_update_rules(l_pid, c_set, 1);
  wait_s(1);
  signals(l_pid);
  lilam.close_session(l_pid, p_procStepsDone => 2);
  wait_s(3);
  report('A: SERVER, Regeln per SERVER_UPDATE_RULES', l_t0);
  for r in (select rule_set_name, set_in_use from lilam_server_registry where pipe_name = 'LT_S1') loop
    dbms_output.put_line('    Registry LT_S1: ' || r.rule_set_name || ' v' || r.set_in_use);
  end loop;

  -- Phase B: neuer Prozess, Regeln schon im RAM
  l_t0 := systimestamp;
  l_pid := lilam.server_new_session('LT_RG_B', 'LT', lilam.logLevelInfo);
  lilam.close_session(l_pid);
  wait_s(2);
  report('B: PROCESS_START mit geladenen Regeln', l_t0);

  -- Phase C: Neustart, Regeln aus der Registry
  l_t0 := systimestamp;
  l_ok := lt.stop_server('LT_S1');
  lt.start_server('LT_S1');
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1'));
  l_pid := lilam.server_new_session('LT_RG_C', 'LT', lilam.logLevelInfo);
  lilam.mark_event(l_pid, 'RA_T');
  lilam.close_session(l_pid);
  wait_s(2);
  report('C: nach Neustart (erwartet R09C und R12)', l_t0);

  -- Phase D: Rule Set v2 mit leerer action
  l_t0 := systimestamp;
  l_pid := lilam.server_new_session('LT_RG_D', 'LT', lilam.logLevelInfo);
  lilam.server_update_rules(l_pid, c_set, 2);
  wait_s(1);
  lilam.error(l_pid, 'Fehler fuer V2-1');
  lilam.mark_event(l_pid, 'RA_T2');
  lilam.close_session(l_pid);
  wait_s(2);
  report('D: Rule Set v2 mit "action": "" (erwartet V2-1 und V2-2)', l_t0);

  -- Phase E: INSESSION
  l_t0 := systimestamp;
  l_pid := lilam.new_session('LT_RG_E', lilam.logLevelInfo, p_procStepsToDo => 5);
  signals(l_pid);
  lilam.close_session(l_pid, p_procStepsDone => 2);
  report('E: INSESSION', l_t0);

  -- Aufraeumen
  lt.stop_all_servers;
  update lilam_server_registry set rule_set_name = null, set_in_use = 0 where pipe_name = 'LT_S1';
  delete from lilam_rules where set_name = c_set;
  commit;
  dbms_output.put_line('Fertig.');
end;
/
