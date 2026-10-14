-- =====================================================================
-- LILAM Test: FEATURES / DROSSELUNG
--
-- Prueft die Drosselung von Alerts (throttle_seconds) mit den Sperren in LILAM_ALERT_STATE (Art LOCK):
-- Sperre je Gruppe, Scope bzw. Prozess, Regel, Action und Context; gueltig ueber Sessions,
-- Server-Worker und Neustarts.
--
--   Regeln (alle MARK_EVENT, VAL_MAX 100, Wert 150 loest aus):
--     D-MAX   Action DR_V, ohne Context, throttle_seconds 300
--     D-SHORT Action DR_S, throttle_seconds 2
--     D-NULL  Action DR_Z, throttle_seconds 0
--
--   INSESSION:
--   D1  Context im Schluessel: SAP zweimal, SIE einmal => je 1 Alert
--   D2  Sperre steht in LILAM_ALERT_STATE (Gruppe, Schluessel S<scope_id>|D-MAX|DR_V|SAP)
--   D3  andere DB-Session (Job), neuer Prozess im selben Scope: SAP und SIE gesperrt, BMW loest aus
--   D4  ohne Scope (#NONE): Sperre je Prozess (P<process_id>), ein zweiter Prozess loest erneut aus
--   D5  Sperrzeit laeuft ab (D-SHORT, 2 s): danach neuer Alert, weiter nur eine Zeile je Schluessel
--   D6  throttle_seconds 0: jeder Treffer ein Alert, keine Sperre in LILAM_ALERT_STATE
--   D7  Housekeeping: der Job (frische Session) loescht abgelaufene Sperren, laufende bleiben
--   SERVER (Worker LT_S1, LT_S2, Dispatcher LT_DISP):
--   S1  zwei Prozesse eines Scopes auf verschiedenen Workern: SAP nur 1 Alert, SIE eigener Alert
--   S2  ohne Scope: Reconnect aus einer anderen Session (Dispatcher) loest nicht erneut aus
--   S3  Neustart beider Worker: neuer Prozess im Scope, SAP gesperrt, VW loest aus
--   ALLE:
--   S4  keine internen LILAM-Fehler
--
-- Der Test startet und stoppt seine Server selbst. Nur einzeln (aendert das Rule Set der Gruppe LT).
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- =====================================================================
set serveroutput on size unlimited

declare
  c_set     constant varchar2(30) := 'LT_DROSSELUNG';
  c_handler constant varchar2(30) := 'LT_DR_ALERT';
  c_is_grp  constant varchar2(30) := 'LT_DR_IS';
  l_run     number;
  l_p       varchar2(60);      -- Prozess-Praefix je Modus, z. B. LT_2420_IS
  l_mode    varchar2(20);
  l_t0      timestamp(6);
  l_err     number;

  function q(p_sql varchar2, p_b1 varchar2 default null, p_b2 varchar2 default null, p_b3 varchar2 default null) return number is
    r number;
  begin
    if p_b3 is not null then
      execute immediate p_sql into r using p_b1, p_b2, p_b3;
    elsif p_b2 is not null then
      execute immediate p_sql into r using p_b1, p_b2;
    else
      execute immediate p_sql into r using p_b1;
    end if;
    return r;
  exception when others then return -999;
  end;

  procedure chk(p_name varchar2, p_ok boolean, p_detail varchar2 default null) is
  begin
    lt.check_that(l_run, l_mode || ' ' || p_name, nvl(p_ok, false), p_detail);
  end;

  -- Alerts einer Regel und eines Contexts fuer alle Prozesse mit Namenspraefix
  function alerts(p_prefix varchar2, p_rule varchar2, p_ctx varchar2) return number is
  begin
    return q('select count(*) from lilam_alerts where process_name like :1 escape ''\'' and rule_id = :2
               and nvl(context_name, ''-'') = nvl(:3, ''-'')', replace(p_prefix, '_', '\_') || '%', p_rule, nvl(p_ctx, '-'));
  end;

  -- Server schreiben Alerts asynchron: warten, bis mindestens p_expected da sind
  function wait_alerts(p_prefix varchar2, p_rule varchar2, p_ctx varchar2, p_expected number, p_max_s number default 10) return number is
    l_w number := 0;
    l_n number;
  begin
    loop
      l_n := alerts(p_prefix, p_rule, p_ctx);
      exit when l_n >= p_expected or l_w >= p_max_s;
      dbms_session.sleep(0.25); l_w := l_w + 0.25;
    end loop;
    return l_n;
  end;

  function scope_id(p_scope varchar2) return number is
  begin
    return q('select max(scope_id) from lilam_scopes where scope_name = upper(:1)', p_scope);
  end;

  -- p_key: GRUPPE|Sperrschluessel
  function locks(p_key varchar2) return number is
    l_n number;
  begin
    execute immediate 'select count(*) from lilam_alert_state where group_name = :1 and state_kind = ''LOCK'' and state_key = :2'
      into l_n using substr(p_key, 1, instr(p_key, '|') - 1), substr(p_key, instr(p_key, '|') + 1);
    return l_n;
  end;

  function newp(p_suffix varchar2, p_scope varchar2 default null) return number is
  begin
    if l_mode = lt.c_insession then
      return lilam.new_process(p_processName => l_p || p_suffix, p_logLevel => lilam.logLevelInfo,
                               p_baselineScope => p_scope, p_groupName => c_is_grp);
    end if;
    return lilam.server_new_process(p_processName => l_p || p_suffix, p_groupName => lt.c_group,
                                    p_logLevel => lilam.logLevelInfo, p_baselineScope => p_scope);
  end;

  function r(p_id varchar2, p_action varchar2, p_throttle number) return varchar2 is
  begin
    return '{"id":"' || p_id || '","trigger_type":"MARK_EVENT","action":"' || p_action || '"'
        || ',"condition":{"operator":"VAL_MAX","value":"100"}'
        || ',"alert":{"handler":"' || c_handler || '","severity":"WARN","throttle_seconds":' || p_throttle || '}}';
  end;

  procedure put_rules(p_group varchar2) is
  begin
    execute immediate 'delete from lilam_rules where set_name = :1 and upper(group_name) = upper(:2)' using c_set, p_group;
    execute immediate 'insert into lilam_rules(group_name, set_name, version, is_active, created, author, rule_set)
                       values (:1, :2, 1, 0, systimestamp, ''LT'', :3)'
      using p_group, c_set,
            to_clob('{"header":{"rule_set":"' || c_set || '","rule_set_version":1},"rules":['
                    || r('D-MAX', 'DR_V', 300) || ',' || r('D-SHORT', 'DR_S', 2) || ',' || r('D-NULL', 'DR_Z', 0) || ']}');
    commit;
    lilam.server_update_rules(p_group, c_set, 1);
    dbms_session.sleep(1);
  end;

  procedure run_insession is
    l_scope varchar2(80);
    l_sid   number;
    l_pid1  number;
    l_pid2  number;
    l_pid3  number;
    l_n     number;
    l_ok    boolean;
    l_grp   varchar2(30) := upper(c_is_grp);
  begin
    l_mode  := lt.c_insession;
    l_p     := 'LT_' || l_run || '_IS';
    l_scope := l_p || '_SC';

    -- D1/D2
    l_pid1 := newp('_SA', l_scope);
    lilam.mark_event(l_pid1, 'DR_V', 'SAP', 150);
    lilam.mark_event(l_pid1, 'DR_V', 'SAP', 150);
    lilam.mark_event(l_pid1, 'DR_V', 'SIE', 150);
    l_n := alerts(l_p || '_S', 'D-MAX', 'SAP');
    chk('D1 SAP zweimal: 1 Alert', l_n = 1, l_n);
    l_n := alerts(l_p || '_S', 'D-MAX', 'SIE');
    chk('D1 SIE nicht durch SAP gesperrt: 1 Alert', l_n = 1, l_n);
    l_sid := scope_id(l_scope);
    l_n := locks(l_grp || '|S' || l_sid || '|D-MAX|DR_V|SAP');
    chk('D2 Sperre in LILAM_ALERT_STATE (Scope, Context SAP)', l_n = 1, l_n);
    l_n := locks(l_grp || '|S' || l_sid || '|D-MAX|DR_V|SIE');
    chk('D2 eigene Sperre fuer Context SIE', l_n = 1, l_n);

    -- D7 vorbereiten: eine abgelaufene und eine laufende Sperre (die Hauptsession hat in D1 schon
    -- aufgeraeumt und raeumt erst nach 60 s wieder auf; der Job in D3 raeumt sofort auf)
    execute immediate 'insert into lilam_alert_state(group_name, state_kind, state_key, ts_utc, hold_seconds) values (''LT_DR_PURGE'', ''LOCK'', :1, sys_extract_utc(systimestamp) - interval ''1'' hour, 1)'
      using l_run || '|OLD';
    execute immediate 'insert into lilam_alert_state(group_name, state_kind, state_key, ts_utc, hold_seconds) values (''LT_DR_PURGE'', ''LOCK'', :1, sys_extract_utc(systimestamp), 3600)'
      using l_run || '|KEEP';
    commit;

    -- D3: andere DB-Session, neuer Prozess im selben Scope
    lt.run_job('LT_DR_IS_' || l_run,
               'declare p number; begin p := lilam.new_process(p_processName => ''' || l_p || '_SB'', p_logLevel => lilam.logLevelInfo,'
            || ' p_baselineScope => ''' || l_scope || ''', p_groupName => ''' || c_is_grp || ''');'
            || ' lilam.mark_event(p, ''DR_V'', ''SAP'', 150);'
            || ' lilam.mark_event(p, ''DR_V'', ''SIE'', 150);'
            || ' lilam.mark_event(p, ''DR_V'', ''BMW'', 150);'
            || ' lilam.close_process(p); end;');
    l_ok := lt.wait_jobs('LT_DR_IS_', 30);
    chk('D3 Job beendet', l_ok);
    l_n := alerts(l_p || '_S', 'D-MAX', 'SAP');
    chk('D3 andere Session: SAP weiter gesperrt (1 Alert)', l_n = 1, l_n);
    l_n := alerts(l_p || '_S', 'D-MAX', 'SIE');
    chk('D3 andere Session: SIE weiter gesperrt (1 Alert)', l_n = 1, l_n);
    l_n := alerts(l_p || '_S', 'D-MAX', 'BMW');
    chk('D3 andere Session: BMW loest aus (Gegenprobe)', l_n = 1, l_n);

    -- D7
    l_n := locks('LT_DR_PURGE|' || l_run || '|OLD');
    chk('D7 abgelaufene Sperre geloescht', l_n = 0, l_n);
    l_n := locks('LT_DR_PURGE|' || l_run || '|KEEP');
    chk('D7 laufende Sperre bleibt', l_n = 1, l_n);
    execute immediate 'delete from lilam_alert_state where group_name = ''LT_DR_PURGE'' and state_key like :1' using l_run || '|%';
    commit;

    -- D4: ohne Scope, Sperre je Prozess
    l_pid2 := newp('_N', '#NONE');
    lilam.mark_event(l_pid2, 'DR_V', 'SAP', 150);
    lilam.mark_event(l_pid2, 'DR_V', 'SAP', 150);
    l_pid3 := newp('_N', '#NONE');
    lilam.mark_event(l_pid3, 'DR_V', 'SAP', 150);
    l_n := alerts(l_p || '_N', 'D-MAX', 'SAP');
    chk('D4 ohne Scope: je Prozess 1 Alert (2 Prozesse => 2)', l_n = 2, l_n);
    l_n := locks(l_grp || '|P' || l_pid2 || '|D-MAX|DR_V|SAP');
    chk('D4 Sperre mit P<process_id> in LILAM_ALERT_STATE', l_n = 1, l_n);

    -- D5: Sperrzeit laeuft ab
    lilam.mark_event(l_pid1, 'DR_S', 'X', 150);
    lilam.mark_event(l_pid1, 'DR_S', 'X', 150);
    l_n := alerts(l_p || '_SA', 'D-SHORT', 'X');
    chk('D5 innerhalb der Sperrzeit: 1 Alert', l_n = 1, l_n);
    dbms_session.sleep(2.5);
    lilam.mark_event(l_pid1, 'DR_S', 'X', 150);
    l_n := alerts(l_p || '_SA', 'D-SHORT', 'X');
    chk('D5 nach Ablauf der Sperrzeit: 2 Alerts', l_n = 2, l_n);
    l_n := locks(l_grp || '|S' || l_sid || '|D-SHORT|DR_S|X');
    chk('D5 weiter genau eine Zeile je Schluessel', l_n = 1, l_n);

    -- D6: ohne Drosselung
    lilam.mark_event(l_pid1, 'DR_Z', 'X', 150);
    lilam.mark_event(l_pid1, 'DR_Z', 'X', 150);
    l_n := alerts(l_p || '_SA', 'D-NULL', 'X');
    chk('D6 throttle_seconds 0: jeder Treffer ein Alert (2)', l_n = 2, l_n);
    l_n := q('select count(*) from lilam_alert_state where state_kind = ''LOCK'' and state_key like :1', '%|D-NULL|%');
    chk('D6 throttle_seconds 0: keine Sperre gespeichert', l_n = 0, l_n);

    lt.close_wait(l_pid1);
    lt.close_wait(l_pid2);
    lt.close_wait(l_pid3);
  end;

  procedure run_server is
    l_scope varchar2(80);
    l_pidA  number;
    l_pidB  number;
    l_pidC  number;
    l_pidD  number;
    l_n     number;
    l_ok    boolean;
    l_pipeA varchar2(50);
    l_pipeB varchar2(50);
  begin
    l_mode  := lt.c_server;
    l_p     := 'LT_' || l_run || '_SV';
    l_scope := l_p || '_SC';

    -- S1: zwei gleichzeitig offene Prozesse eines Scopes; die Serverauswahl verteilt sie auf beide Worker
    l_pidA := newp('_SA', l_scope);
    l_pidB := newp('_SB', l_scope);
    dbms_session.sleep(0.5);
    execute immediate 'select max(pipe_name) from lilam_process_route where process_id = :1' into l_pipeA using l_pidA;
    execute immediate 'select max(pipe_name) from lilam_process_route where process_id = :1' into l_pipeB using l_pidB;
    chk('S1 Voraussetzung: Prozesse auf verschiedenen Workern', l_pipeA != l_pipeB, l_pipeA || ' / ' || l_pipeB);
    lilam.mark_event(l_pidA, 'DR_V', 'SAP', 150);
    l_n := wait_alerts(l_p || '_S', 'D-MAX', 'SAP', 1);
    chk('S1 erster Worker: SAP 1 Alert', l_n = 1, l_n);
    lilam.mark_event(l_pidB, 'DR_V', 'SAP', 150);
    lilam.mark_event(l_pidB, 'DR_V', 'SIE', 150);
    lt.close_wait(l_pidA);
    lt.close_wait(l_pidB);
    l_n := wait_alerts(l_p || '_S', 'D-MAX', 'SIE', 1);
    chk('S1 anderer Worker: SIE loest aus (Gegenprobe)', l_n = 1, l_n);
    l_n := alerts(l_p || '_S', 'D-MAX', 'SAP');
    chk('S1 anderer Worker: SAP gesperrt (weiter 1 Alert)', l_n = 1, l_n);

    -- S2: ohne Scope, Reconnect ueber den Dispatcher aus einer anderen Session
    l_pidC := newp('_N', '#NONE');
    lilam.mark_event(l_pidC, 'DR_V', 'SAP', 150);
    l_n := wait_alerts(l_p || '_N', 'D-MAX', 'SAP', 1);
    chk('S2 ohne Scope: 1 Alert', l_n = 1, l_n);
    lt.run_job('LT_DR_RC_' || l_run,
               'begin lilam.set_dispatcher_pipe(''' || lt.c_disp_pipe || ''');'
            || ' lilam.mark_event(' || l_pidC || ', ''DR_V'', ''SAP'', 150);'
            || ' lilam.mark_event(' || l_pidC || ', ''DR_V'', ''ARAL'', 150);'
            || ' dbms_session.sleep(1); end;');
    l_ok := lt.wait_jobs('LT_DR_RC_', 30);
    chk('S2 Job beendet', l_ok);
    l_n := wait_alerts(l_p || '_N', 'D-MAX', 'ARAL', 1);
    chk('S2 Reconnect: ARAL loest aus (Gegenprobe)', l_n = 1, l_n);
    lt.close_wait(l_pidC);
    l_n := alerts(l_p || '_N', 'D-MAX', 'SAP');
    chk('S2 Reconnect: SAP gesperrt (weiter 1 Alert)', l_n = 1, l_n);

    -- S3: Neustart beider Worker
    l_ok := lt.stop_server('LT_S1');
    l_ok := lt.stop_server('LT_S2') and l_ok;
    chk('S3 Worker gestoppt', l_ok);
    lt.start_server('LT_S1');
    lt.start_server('LT_S2');
    lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2'));
    lilam.server_update_rules(lt.c_group, c_set, 1);
    dbms_session.sleep(1);
    l_pidD := newp('_SD', l_scope);
    lilam.mark_event(l_pidD, 'DR_V', 'SAP', 150);
    lilam.mark_event(l_pidD, 'DR_V', 'VW', 150);
    lt.close_wait(l_pidD);
    l_n := wait_alerts(l_p || '_S', 'D-MAX', 'VW', 1);
    chk('S3 nach Neustart: VW loest aus (Gegenprobe)', l_n = 1, l_n);
    l_n := alerts(l_p || '_S', 'D-MAX', 'SAP');
    chk('S3 nach Neustart: SAP gesperrt (weiter 1 Alert)', l_n = 1, l_n);
  end;
begin
  l_run := lt.begin_run('DROSSELUNG', 'INSESSION+SERVER');
  l_t0  := systimestamp;
  lt.stop_all_servers;
  put_rules(c_is_grp);
  put_rules(lt.c_group);

  run_insession;

  lt.start_server('LT_S1');
  lt.start_server('LT_S2');
  lt.start_server(lt.c_disp_pipe, 1);
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2', lt.c_disp_pipe));
  lilam.server_update_rules(lt.c_group, c_set, 1);
  dbms_session.sleep(1);
  run_server;
  lt.stop_all_servers;

  l_mode := 'ALLE';
  l_err := lt.internal_errors_since(l_t0);
  chk('S4 keine internen LILAM-Fehler', l_err = 0, l_err);

  -- Testgruppen ohne aktives Rule Set zuruecklassen
  execute immediate 'delete from lilam_rules where set_name = :1' using c_set;
  commit;
  lt.end_run(l_run);
exception
  when others then
    dbms_output.put_line('ABBRUCH: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
    lt.check_that(l_run, 'Abbruch', false, substr(sqlerrm || ' ' || dbms_utility.format_error_backtrace, 1, 1000));
    lt.stop_all_servers;
    lt.end_run(l_run);
end;
/
