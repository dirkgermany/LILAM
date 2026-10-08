-- =====================================================================
-- HINWEIS: gehört zur Analyse vom 04.10.2026 (Stand d2bf421, alte Signatur von SERVER_UPDATE_RULES
--          und Rule-Spalten in der Registry). Läuft mit dem aktuellen Code nicht mehr; nur zur Nachvollziehbarkeit.
-- Diagnose: Einfluss der Regelpruefung auf die Server-Leistung (Analyse 04.10.2026)
--
-- Ein Client sendet N Events (bzw. N INFO-Logs) an LT_S1 (ohne Drosselung, p_perfServer 0).
-- Gemessen wird die Zeit vom ersten Senden bis alle N Zeilen in LILAM_MON/LILAM_LOG stehen.
-- Varianten (je ein Rule Set LT_PERF, Version = Variante):
--   1 E_NONE     keine Regeln
--   2 E_OTHER50  50 Regeln auf andere Actions (nur Map-Lookup)
--   3 E_MATCH1   1 passende Regel, schlaegt nicht an (MAX_DURATION_MS)
--   4 E_MATCH20  20 passende Regeln, gemischte Operatoren, schlagen nicht an
--   5 E_MATCH100 100 passende Regeln, gemischte Operatoren, schlagen nicht an
--   6 E_FIRE0    1 Regel ON_EVENT, throttle 0  -> jedes Event ein Alert
--   7 E_FIRE60   1 Regel ON_EVENT, throttle 60 -> 1 Alert, Rest gedrosselt
--   8 L_NONE     N INFO-Logs, keine Regeln
--   9 L_SEV      N INFO-Logs, eine LOGGING-Regel SEVERITY=ERROR
-- =====================================================================
set serveroutput on size unlimited

declare
  c_set   constant varchar2(30) := 'LT_PERF';
  c_n     constant pls_integer  := 10000;
  c_reps  constant pls_integer  := 2;
  type t_names is table of varchar2(20);
  l_names t_names := t_names('E_NONE','E_OTHER50','E_MATCH1','E_MATCH20','E_MATCH100','E_FIRE0','E_FIRE60','L_NONE','L_SEV');
  l_pid   number;
  l_t0    timestamp;
  l_ms    number;
  l_msg   varchar2(4000);
  l_ok    boolean;
  l_int0  timestamp;

  function rule(p_id varchar2, p_trig varchar2, p_action varchar2, p_op varchar2, p_val varchar2, p_thr number default 0) return varchar2 is
  begin
    return '{"id":"' || p_id || '","trigger_type":"' || p_trig || '","action":"' || p_action
        || '","condition":{"operator":"' || p_op || '","value":"' || p_val
        || '"},"alert":{"handler":"LT_PERF_ALERT","severity":"WARN","throttle_seconds":' || p_thr || '}}';
  end;

  -- n passende, nicht anschlagende Regeln mit gemischten Operatoren
  function mixed(p_n pls_integer) return clob is
    l clob; l_op varchar2(30); l_val varchar2(50);
  begin
    for i in 1 .. p_n loop
      case mod(i, 6)
        when 0 then l_op := 'MAX_DURATION_MS';         l_val := '99999999';
        when 1 then l_op := 'MAX_GAP_SECONDS';         l_val := '999';
        when 2 then l_op := 'PRECEDED_BY';             l_val := 'PERF_EV';
        when 3 then l_op := 'PRECEDED_BY_WITHIN_SECS'; l_val := 'PERF_EV|999';
        when 4 then l_op := 'AVG_DEVIATION_PCT';       l_val := '100000|3|0.1';
        else        l_op := 'MAX_OCCURRENCE';          l_val := '99999999';
      end case;
      l := l || case when i > 1 then ',' end || rule('M' || i, 'MARK_EVENT', 'PERF_EV', l_op, l_val, 3600);
    end loop;
    return l;
  end;

  procedure put_set(p_ver pls_integer, p_rules clob) is
  begin
    insert into lilam_rules(set_name, version, created, author, rule_set)
    values (c_set, p_ver, systimestamp, 'claude',
            '{"header":{"rule_set":"' || c_set || '","rule_set_version":' || p_ver || '},"rules":[' || p_rules || ']}');
  end;

  procedure put_rules is
    l clob;
  begin
    delete from lilam_rules where set_name = c_set;
    put_set(1, null);
    for i in 1 .. 50 loop
      l := l || case when i > 1 then ',' end || rule('O' || i, 'MARK_EVENT', 'OTHER_' || i, 'ON_EVENT', '');
    end loop;
    put_set(2, l);
    put_set(3, rule('M1', 'MARK_EVENT', 'PERF_EV', 'MAX_DURATION_MS', '99999999'));
    put_set(4, mixed(20));
    put_set(5, mixed(100));
    put_set(6, rule('F0', 'MARK_EVENT', 'PERF_EV', 'ON_EVENT', '', 0));
    put_set(7, rule('F60', 'MARK_EVENT', 'PERF_EV', 'ON_EVENT', '', 60));
    put_set(8, null);
    put_set(9, rule('S1', 'LOGGING', 'LOGGING', 'SEVERITY', 'ERROR', 0));
    commit;
  end;

  function internal_since(p_ts timestamp) return number is
    l_n number;
  begin
    select count(*) into l_n from lilam_log_internal where log_timestamp >= p_ts;
    return l_n;
  end;

begin
  put_rules;
  lt.stop_all_servers;
  -- ohne Drosselung, damit der Client den Server nicht begrenzt
  l_msg := lilam.create_server('LT_S1', 'LT', 'LtTestPw', 0, p_perfServer => 0);
  dbms_output.put_line('    ' || l_msg);
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1'));

  dbms_output.put_line(rpad('Variante', 12) || rpad('Lauf', 6) || lpad('ms', 9) || lpad('us/Signal', 11) || lpad('Alerts', 8) || lpad('intern', 8));
  for r in 1 .. c_reps loop
    for v in 1 .. l_names.count loop
      declare
        l_prefix varchar2(30) := 'LT_RP_' || l_names(v) || '_' || r;
        l_alerts number;
      begin
        l_pid := lilam.server_new_process(l_prefix, 'LT', lilam.logLevelInfo);
        lilam.server_update_rules(l_pid, c_set, v);
        dbms_session.sleep(1);
        l_int0 := systimestamp;
        l_t0 := systimestamp;
        if l_names(v) like 'L\_%' escape '\' then
          for i in 1 .. c_n loop lilam.info(l_pid, 'perf ' || i); end loop;
          l_ms := lt.wait_count(l_prefix, 'LOG', c_n, 180);
        else
          for i in 1 .. c_n loop lilam.mark_event(l_pid, 'PERF_EV'); end loop;
          l_ms := lt.wait_count(l_prefix, 'EVENT', c_n, 180);
        end if;
        if l_ms >= 0 then l_ms := lt.ms_since(l_t0); end if;
        lilam.close_process(l_pid);
        select count(*) into l_alerts from lilam_alerts where process_name = l_prefix;
        dbms_output.put_line(rpad(l_names(v), 12) || rpad(r, 6) || lpad(round(l_ms), 9)
                             || lpad(case when l_ms > 0 then round(l_ms * 1000 / c_n, 1) end, 11)
                             || lpad(l_alerts, 8) || lpad(internal_since(l_int0), 8));
      end;
      dbms_session.sleep(2);
    end loop;
  end loop;

  lt.stop_all_servers;
  update lilam_server_registry set rule_set_name = null, set_in_use = 0 where pipe_name = 'LT_S1';
  delete from lilam_rules where set_name = c_set;
  commit;
  dbms_output.put_line('Fertig.');
end;
/
