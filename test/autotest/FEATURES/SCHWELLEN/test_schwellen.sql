-- =====================================================================
-- LILAM Test: FEATURES / SCHWELLEN
--
-- Prueft die Schwellen mit Zustand (VAL_CROSS_ABOVE, VAL_CROSS_BELOW, Wert schwelle[|rueckkehr]):
-- genau ein Alert je Ueberqueren, still wieder scharf nach der Rueckkehr, Zustand in
-- LILAM_ALERT_STATE (Art CROSS). Nummern T1-T18 = Testfaelle aus 04_lilam_schwellen_zustand.md.
--
--   INSESSION:
--   T14 Schreiben des Alerts scheitert (Constraint): Regel bleibt scharf, der naechste Wert meldet
--   T1  weitere Werte jenseits: kein Alert, auch nach Ablauf von throttle_seconds
--   T2  erster Wert jenseits: Alert (in T1 enthalten)
--   T3  Rueckkehr still, erneutes Ueberschreiten: zweiter Alert
--   T4  Hysterese 185|180: Pendeln 184/186 ein Alert, unter 180 und wieder darueber der zweite
--   T5  Grenzfaelle: gleich Schwelle loest nicht aus, gleich Rueckkehr macht scharf
--   T6  VAL_CROSS_BELOW entsprechend
--   T7  Reihen getrennt (Context)
--   T8  neuer Prozess und neue Session: Zustand bleibt
--   T9  CHECK_SILENCE zwischen zwei Werten: Zustand bleibt
--   T15 Ueberqueren waehrend der Sperrfrist: kein Alert, bleibt scharf, meldet nach Ablauf
--   T16 ohne Scope: Zustand je Prozess, Zeile beim Schliessen geloescht
--   T17 MARK_EVENT ohne Wert: keine Auswertung, Zustand unveraendert
--   T18 CHECK_RULE_SET: ungueltige Werte und Trigger abgelehnt, gueltige angenommen
--   T12 RESET_BASELINE: Zustand geloescht (alle Gruppen, | im Namen), andere Reihen bleiben
--   T13 vier Sessions gleichzeitig: je Reihe genau ein Alert
--   T10 Schwelle der Regel geaendert: Zustand zurueckgesetzt
--   T11 neue Version, Schwelle dieser Regel gleich: Zustand bleibt
--   A1  Regel entfernt oder umgezogen: Zeile weg (SERVER_UPDATE_RULES)
--   A2  haengengebliebene Zeile ohne Scope nach 30 Tagen weg, mit Scope bleibt
--   SERVER (Worker LT_S1, LT_S2):
--   X1  zwei Worker, ein Scope: ein Alert
--   X2  Pruefung im Server (10 s) und Neustart beider Worker: Zustand bleibt
--   X3  Failover: wiederholte Rueckkehr und Ueberqueren, der Zustand stimmt, kein zweiter Alert
--   ALLE:
--   X4  keine internen LILAM-Fehler
--
-- Der Test startet und stoppt seine Server selbst. Nur einzeln (aendert das Rule Set der Gruppe LT).
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- =====================================================================
set serveroutput on size unlimited

declare
  c_set     constant varchar2(30) := 'LT_SCHWELLEN';
  c_handler constant varchar2(30) := 'LT_SW_ALERT';
  c_is_grp  constant varchar2(30) := 'LT_SW_IS';
  l_run     number;
  l_p       varchar2(60);      -- Prozess-Praefix je Modus, z. B. LT_2450_IS
  l_mode    varchar2(20);
  l_t0      timestamp(6);
  l_err     number;
  l_jobs    pls_integer := 0;

  procedure chk(p_name varchar2, p_ok boolean, p_detail varchar2 default null) is
  begin
    lt.check_that(l_run, l_mode || ' ' || p_name, nvl(p_ok, false), p_detail);
  end;

  -- Alerts einer Regel und eines Contexts fuer alle Prozesse mit Namenspraefix
  function alerts(p_prefix varchar2, p_rule varchar2, p_ctx varchar2) return number is
    r number;
  begin
    execute immediate 'select count(*) from lilam_alerts where process_name like :1 escape ''\'' and rule_id = :2
                         and nvl(context_name, ''-'') = nvl(:3, ''-'')'
      into r using replace(p_prefix, '_', '\_') || '%', p_rule, p_ctx;
    return r;
  end;

  -- Server schreiben Alerts asynchron: warten, bis mindestens p_expected da sind
  function wait_alerts(p_prefix varchar2, p_rule varchar2, p_ctx varchar2, p_expected number, p_max_s number default 10) return number is
    l_w number := 0;
    l_n number;
  begin
    loop
      l_n := alerts(p_prefix, p_rule, p_ctx);
      exit when l_n >= p_expected or l_w >= p_max_s;
      dbms_session.sleep(0.1); l_w := l_w + 0.1;
    end loop;
    return l_n;
  end;

  -- Zustandszeilen einer Regel und eines Contexts (alle Gruppen)
  function states(p_rule varchar2, p_action varchar2, p_ctx varchar2) return number is
    r number;
  begin
    execute immediate 'select count(*) from lilam_alert_state where state_kind = ''CROSS'' and rule_id = :1
                         and action_name = :2 and nvl(context_name, ''-'') = nvl(:3, ''-'')'
      into r using p_rule, p_action, p_ctx;
    return r;
  end;

  function scope_id(p_scope varchar2) return number is
    r number;
  begin
    execute immediate 'select max(scope_id) from lilam_scopes where scope_name = upper(:1)' into r using p_scope;
    return r;
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

  -- ein Wert aus einer frischen Session (INSESSION): laedt immer das aktive Rule Set
  procedure job_mark(p_scope varchar2, p_action varchar2, p_ctx varchar2, p_value number) is
    l_ok boolean;
  begin
    l_jobs := l_jobs + 1;
    lt.run_job('LT_SW_J' || l_run || '_' || l_jobs,
               'declare p number; begin p := lilam.new_process(p_processName => ''' || l_p || '_J'', p_logLevel => lilam.logLevelInfo,'
            || ' p_baselineScope => ''' || p_scope || ''', p_groupName => ''' || c_is_grp || ''');'
            || ' lilam.mark_event(p, ''' || p_action || ''', ''' || p_ctx || ''', ' || p_value || ');'
            || ' lilam.close_process(p); end;');
    l_ok := lt.wait_jobs('LT_SW_J' || l_run || '_' || l_jobs, 30);
    chk('Job ' || l_jobs || ' beendet', l_ok);
  end;

  function r(p_id varchar2, p_action varchar2, p_op varchar2, p_value varchar2, p_throttle number default 0) return varchar2 is
  begin
    return '{"id":"' || p_id || '","trigger_type":"MARK_EVENT","action":"' || p_action || '"'
        || ',"condition":{"operator":"' || p_op || '","value":"' || p_value || '"}'
        || ',"alert":{"handler":"' || c_handler || '","severity":"WARN","throttle_seconds":' || p_throttle || '}}';
  end;

  function rule_set(p_version number, p_rules varchar2) return clob is
  begin
    return to_clob('{"header":{"rule_set":"' || c_set || '","rule_set_version":' || p_version || '},"rules":[' || p_rules || ']}');
  end;

  function base_rules return varchar2 is
  begin
    return r('C-UP', 'SW_A', 'VAL_CROSS_ABOVE', '100')
        || ',' || r('C-HY', 'SW_H', 'VAL_CROSS_ABOVE', '185|180')
        || ',' || r('C-LO', 'SW_L', 'VAL_CROSS_BELOW', '160|165')
        || ',' || r('C-TH', 'SW_T', 'VAL_CROSS_ABOVE', '100', 2)
        || ',' || r('C-F',  'SW_F', 'VAL_CROSS_ABOVE', '100')
        || ',' || r('C-N',  'SW_N', 'VAL_CROSS_ABOVE', '100')
        || ',' || r('C-P',  'SW_P', 'VAL_CROSS_ABOVE', '100')
        || ',' || r('C-RM', 'SW_R', 'VAL_CROSS_ABOVE', '100')
        || ',' || r('C-MV', 'SW_M', 'VAL_CROSS_ABOVE', '100');
  end;

  procedure put_rules(p_group varchar2, p_version number, p_rules varchar2) is
  begin
    execute immediate 'insert into lilam_rules(group_name, set_name, version, is_active, created, author, rule_set)
                       values (:1, :2, :3, 0, systimestamp, ''LT'', :4)'
      using p_group, c_set, p_version, rule_set(p_version, p_rules);
    commit;
    lilam.server_update_rules(p_group, c_set, p_version);
    dbms_session.sleep(1);
  end;

  procedure run_insession is
    l_scope varchar2(80);
    l_sid   number;
    l_pid   number;
    l_pid2  number;
    l_pid3  number;
    l_n     number;
    l_ok    boolean;
    l_grp   varchar2(30) := upper(c_is_grp);
    l_txt   varchar2(1000);
    l_start varchar2(40);

    procedure bad(p_label varchar2, p_rule varchar2) is
    begin
      l_txt := lilam.check_rule_set(rule_set(1, p_rule));
      chk('T18 abgelehnt: ' || p_label, l_txt is not null, l_txt);
    end;
    procedure good(p_label varchar2, p_rule varchar2) is
    begin
      l_txt := lilam.check_rule_set(rule_set(1, p_rule));
      chk('T18 angenommen: ' || p_label, l_txt is null, l_txt);
    end;
  begin
    l_mode  := lt.c_insession;
    l_p     := 'LT_' || l_run || '_IS';
    l_scope := l_p || '_SC';
    l_pid   := newp('_A', l_scope);
    l_sid   := scope_id(l_scope);

    -- T14: Constraint laesst das Schreiben des Alerts scheitern
    execute immediate 'alter table lilam_alerts add constraint lt_sw_alert_fail check (rule_id != ''C-F'') enable novalidate';
    lilam.mark_event(l_pid, 'SW_F', 'X', 150);
    execute immediate 'alter table lilam_alerts drop constraint lt_sw_alert_fail';
    l_n := alerts(l_p, 'C-F', 'X');
    chk('T14 Schreiben scheitert: kein Alert', l_n = 0, l_n);
    l_n := states('C-F', 'SW_F', 'X');
    chk('T14 Zustand zurueckgerollt', l_n = 0, l_n);
    lilam.mark_event(l_pid, 'SW_F', 'X', 150);
    l_n := alerts(l_p, 'C-F', 'X');
    chk('T14 naechster Wert meldet', l_n = 1, l_n);
    l_n := states('C-F', 'SW_F', 'X');
    chk('T14 Zustand gesetzt', l_n = 1, l_n);
    l_t0 := systimestamp;   -- der Fehler aus T14 ist erwartet

    -- T1/T2
    lilam.mark_event(l_pid, 'SW_T', 'T1', 150);
    lilam.mark_event(l_pid, 'SW_T', 'T1', 160);
    l_n := alerts(l_p, 'C-TH', 'T1');
    chk('T1/T2 erster Wert jenseits: genau 1 Alert', l_n = 1, l_n);
    dbms_session.sleep(2.5);
    lilam.mark_event(l_pid, 'SW_T', 'T1', 170);
    l_n := alerts(l_p, 'C-TH', 'T1');
    chk('T1 nach Ablauf von throttle_seconds: weiter 1 Alert', l_n = 1, l_n);

    -- T3
    lilam.mark_event(l_pid, 'SW_A', 'T3', 150);
    lilam.mark_event(l_pid, 'SW_A', 'T3', 90);
    l_n := alerts(l_p, 'C-UP', 'T3');
    chk('T3 Rueckkehr ohne Alert', l_n = 1, l_n);
    l_n := states('C-UP', 'SW_A', 'T3');
    chk('T3 Rueckkehr loescht den Zustand', l_n = 0, l_n);
    lilam.mark_event(l_pid, 'SW_A', 'T3', 150);
    l_n := alerts(l_p, 'C-UP', 'T3');
    chk('T3 erneutes Ueberschreiten: 2 Alerts', l_n = 2, l_n);

    -- T4
    for i in 1 .. 3 loop
      lilam.mark_event(l_pid, 'SW_H', 'T4', 186);
      lilam.mark_event(l_pid, 'SW_H', 'T4', 184);
    end loop;
    l_n := alerts(l_p, 'C-HY', 'T4');
    chk('T4 Pendeln 184/186: 1 Alert', l_n = 1, l_n);
    lilam.mark_event(l_pid, 'SW_H', 'T4', 179);
    lilam.mark_event(l_pid, 'SW_H', 'T4', 186);
    l_n := alerts(l_p, 'C-HY', 'T4');
    chk('T4 unter 180 und wieder ueber 185: 2 Alerts', l_n = 2, l_n);

    -- T5
    lilam.mark_event(l_pid, 'SW_A', 'T5', 100);
    l_n := alerts(l_p, 'C-UP', 'T5');
    chk('T5 Wert gleich Schwelle loest nicht aus', l_n = 0, l_n);
    lilam.mark_event(l_pid, 'SW_A', 'T5', 100.01);
    lilam.mark_event(l_pid, 'SW_A', 'T5', 100);
    lilam.mark_event(l_pid, 'SW_A', 'T5', 100.01);
    l_n := alerts(l_p, 'C-UP', 'T5');
    chk('T5 ohne Rueckkehrgrenze macht Wert gleich Schwelle scharf', l_n = 2, l_n);
    lilam.mark_event(l_pid, 'SW_H', 'T5', 186);
    lilam.mark_event(l_pid, 'SW_H', 'T5', 180.01);
    lilam.mark_event(l_pid, 'SW_H', 'T5', 186);
    l_n := alerts(l_p, 'C-HY', 'T5');
    chk('T5 knapp ueber der Rueckkehrgrenze: nicht scharf', l_n = 1, l_n);
    lilam.mark_event(l_pid, 'SW_H', 'T5', 180);
    lilam.mark_event(l_pid, 'SW_H', 'T5', 186);
    l_n := alerts(l_p, 'C-HY', 'T5');
    chk('T5 Wert gleich Rueckkehrgrenze macht scharf', l_n = 2, l_n);

    -- T6
    lilam.mark_event(l_pid, 'SW_L', 'T6', 160);
    l_n := alerts(l_p, 'C-LO', 'T6');
    chk('T6 BELOW: gleich Schwelle loest nicht aus', l_n = 0, l_n);
    lilam.mark_event(l_pid, 'SW_L', 'T6', 159);
    lilam.mark_event(l_pid, 'SW_L', 'T6', 164);
    lilam.mark_event(l_pid, 'SW_L', 'T6', 159);
    l_n := alerts(l_p, 'C-LO', 'T6');
    chk('T6 BELOW: Pendeln 159/164: 1 Alert', l_n = 1, l_n);
    lilam.mark_event(l_pid, 'SW_L', 'T6', 165);
    lilam.mark_event(l_pid, 'SW_L', 'T6', 159);
    l_n := alerts(l_p, 'C-LO', 'T6');
    chk('T6 BELOW: Rueckkehr bei 165, dann 2 Alerts', l_n = 2, l_n);

    -- T7
    lilam.mark_event(l_pid, 'SW_A', 'SAP', 150);
    l_n := states('C-UP', 'SW_A', 'SIE');
    chk('T7 SIE ohne Zustand', l_n = 0, l_n);
    lilam.mark_event(l_pid, 'SW_A', 'SIE', 150);
    l_n := alerts(l_p, 'C-UP', 'SIE');
    chk('T7 SIE meldet trotz SAP', l_n = 1, l_n);

    -- T8
    l_pid2 := newp('_B', l_scope);
    lilam.mark_event(l_pid2, 'SW_A', 'SAP', 150);
    lt.close_wait(l_pid2);
    l_n := alerts(l_p, 'C-UP', 'SAP');
    chk('T8 neuer Prozess im Scope: kein neuer Alert', l_n = 1, l_n);
    job_mark(l_scope, 'SW_A', 'SAP', 150);
    l_n := alerts(l_p, 'C-UP', 'SAP');
    chk('T8 neue Session: kein neuer Alert', l_n = 1, l_n);
    job_mark(l_scope, 'SW_A', 'SAP', 90);
    lilam.mark_event(l_pid, 'SW_A', 'SAP', 150);
    l_n := alerts(l_p, 'C-UP', 'SAP');
    chk('T8 Rueckkehr in anderer Session wirkt hier: 2 Alerts', l_n = 2, l_n);

    -- T9
    lilam.check_silence(c_is_grp);
    l_n := states('C-UP', 'SW_A', 'SAP');
    chk('T9 CHECK_SILENCE laesst den Zustand stehen', l_n = 1, l_n);
    lilam.mark_event(l_pid, 'SW_A', 'SAP', 150);
    l_n := alerts(l_p, 'C-UP', 'SAP');
    chk('T9 kein erneuter Alert', l_n = 2, l_n);

    -- T15
    lilam.mark_event(l_pid, 'SW_T', 'T15', 150);
    lilam.mark_event(l_pid, 'SW_T', 'T15', 90);
    lilam.mark_event(l_pid, 'SW_T', 'T15', 150);
    l_n := alerts(l_p, 'C-TH', 'T15');
    chk('T15 Ueberqueren in der Sperrfrist: kein Alert', l_n = 1, l_n);
    l_n := states('C-TH', 'SW_T', 'T15');
    chk('T15 Regel bleibt scharf (kein Zustand)', l_n = 0, l_n);
    dbms_session.sleep(2.5);
    lilam.mark_event(l_pid, 'SW_T', 'T15', 150);
    l_n := alerts(l_p, 'C-TH', 'T15');
    chk('T15 nach Ablauf meldet der naechste Wert', l_n = 2, l_n);

    -- T16
    l_pid2 := newp('_N', '#NONE');
    lilam.mark_event(l_pid2, 'SW_A', 'T16', 150);
    lilam.mark_event(l_pid2, 'SW_A', 'T16', 150);
    l_n := alerts(l_p || '_N', 'C-UP', 'T16');
    chk('T16 ohne Scope: 1 Alert im Prozess', l_n = 1, l_n);
    execute immediate 'select count(*) from lilam_alert_state where group_name = :1 and state_kind = ''CROSS'' and state_key like :2'
      into l_n using l_grp, 'P' || l_pid2 || '|C-UP|%';
    chk('T16 Zustand mit P<process_id>', l_n = 1, l_n);
    l_pid3 := newp('_N', '#NONE');
    lilam.mark_event(l_pid3, 'SW_A', 'T16', 150);
    l_n := alerts(l_p || '_N', 'C-UP', 'T16');
    chk('T16 naechster Prozess meldet erneut', l_n = 2, l_n);
    lt.close_wait(l_pid2);
    l_n := states('C-UP', 'SW_A', 'T16');
    chk('T16 Schliessen loescht nur die eigene Zeile', l_n = 1, l_n);
    lt.close_wait(l_pid3);
    l_n := states('C-UP', 'SW_A', 'T16');
    chk('T16 beide Zeilen weg', l_n = 0, l_n);

    -- T17
    lilam.mark_event(l_pid, 'SW_A', 'T17');
    l_n := alerts(l_p, 'C-UP', 'T17');
    chk('T17 ohne Wert: kein Alert', l_n = 0, l_n);
    lilam.mark_event(l_pid, 'SW_A', 'T17', 150);
    lilam.mark_event(l_pid, 'SW_A', 'T17');
    l_n := states('C-UP', 'SW_A', 'T17');
    chk('T17 ohne Wert: Zustand unveraendert', l_n = 1, l_n);

    -- T18
    bad('185|190 bei ABOVE', r('V', 'A', 'VAL_CROSS_ABOVE', '185|190'));
    bad('160|150 bei BELOW', r('V', 'A', 'VAL_CROSS_BELOW', '160|150'));
    bad('185|',              r('V', 'A', 'VAL_CROSS_ABOVE', '185|'));
    bad('|185',              r('V', 'A', 'VAL_CROSS_ABOVE', '|185'));
    bad('leer',              r('V', 'A', 'VAL_CROSS_ABOVE', ''));
    bad('abc',               r('V', 'A', 'VAL_CROSS_ABOVE', 'abc'));
    bad('185|abc',           r('V', 'A', 'VAL_CROSS_BELOW', '185|abc'));
    bad('drei Teile',        r('V', 'A', 'VAL_CROSS_ABOVE', '185|180|170'));
    bad('Trigger TRACE_STOP', replace(r('V', 'A', 'VAL_CROSS_ABOVE', '185'), 'MARK_EVENT', 'TRACE_STOP'));
    bad('Trigger PROCESS_STOP', replace(r('V', 'A', 'VAL_CROSS_BELOW', '185'), 'MARK_EVENT', 'PROCESS_STOP'));
    good('185',              r('V', 'A', 'VAL_CROSS_ABOVE', '185'));
    good('185|185',          r('V', 'A', 'VAL_CROSS_ABOVE', '185|185'));
    good('185.5|180.25',     r('V', 'A', 'VAL_CROSS_ABOVE', '185.5|180.25'));
    good('-5|-2',            r('V', 'A', 'VAL_CROSS_BELOW', '-5|-2'));

    -- T12: | im Namen, zweite Gruppe, andere Reihen
    lilam.mark_event(l_pid, 'SW_P', 'A|B', 150);
    lilam.mark_event(l_pid, 'SW_P', 'C', 150);
    lilam.mark_event(l_pid, 'SW_P', null, 150);
    execute immediate 'insert into lilam_alert_state(group_name, state_kind, state_key, ts_utc, rule_id, scope_id, action_name, context_name,
                                                     cond_operator, cond_threshold, cond_rearm)
                       values (''LT_SW_OTHER'', ''CROSS'', :1, sys_extract_utc(systimestamp), ''X'', :2, ''SW_P'', ''A|B'', ''VAL_CROSS_ABOVE'', 1, 1)'
      using 'S' || l_sid || '|X|SW_P|A|B', l_sid;
    commit;
    lilam.reset_baseline(l_scope, 'SW_P', 'A|B');
    l_n := states('C-P', 'SW_P', 'A|B');
    chk('T12 Zustand geloescht (| im Context)', l_n = 0, l_n);
    l_n := states('X', 'SW_P', 'A|B');
    chk('T12 auch die Zeile der anderen Gruppe', l_n = 0, l_n);
    l_n := states('C-P', 'SW_P', 'C');
    chk('T12 anderer Context bleibt', l_n = 1, l_n);
    l_n := states('C-P', 'SW_P', null);
    chk('T12 Reihe ohne Context bleibt', l_n = 1, l_n);
    lilam.mark_event(l_pid, 'SW_P', 'A|B', 150);
    l_n := alerts(l_p, 'C-P', 'A|B');
    chk('T12 naechster Wert jenseits meldet', l_n = 2, l_n);
    lilam.reset_baseline(l_scope, 'SW_P', null);
    l_n := states('C-P', 'SW_P', null);
    chk('T12 Context NULL: Reihe ohne Context geloescht', l_n = 0, l_n);
    l_n := states('C-P', 'SW_P', 'C');
    chk('T12 Context NULL: Context C bleibt', l_n = 1, l_n);

    -- T13: vier Sessions, gemeinsamer Start
    select to_char(sys_extract_utc(systimestamp) + interval '3' second, 'YYYY-MM-DD HH24:MI:SS.FF3') into l_start from dual;
    for j in 1 .. 4 loop
      lt.run_job('LT_SW_N' || l_run || '_' || j,
                 'declare p number; t timestamp := to_timestamp(''' || l_start || ''', ''YYYY-MM-DD HH24:MI:SS.FF3''); begin'
              || ' p := lilam.new_process(p_processName => ''' || l_p || '_C'', p_logLevel => lilam.logLevelInfo,'
              || ' p_baselineScope => ''' || l_scope || ''', p_groupName => ''' || c_is_grp || ''');'
              || ' lilam.mark_event(p, ''SW_N'', ''WARM'', 1);'
              || ' while sys_extract_utc(systimestamp) < t loop dbms_session.sleep(0.005); end loop;'
              || ' for i in 1 .. 50 loop lilam.mark_event(p, ''SW_N'', ''C'' || i, 150); end loop;'
              || ' lilam.close_process(p); end;');
    end loop;
    l_ok := lt.wait_jobs('LT_SW_N' || l_run, 60);
    chk('T13 Jobs beendet', l_ok);
    execute immediate 'select count(*), count(distinct context_name) from lilam_alerts
                        where process_name = :1 and rule_id = ''C-N''' into l_n, l_err using l_p || '_C';
    chk('T13 vier Sessions: je Reihe genau ein Alert (50)', l_n = 50 and l_err = 50, l_n || ' Alerts, ' || l_err || ' Reihen');

    -- T10/T11: Regelaenderung; Werte aus frischen Sessions, weil diese Session Regeln zwischenspeichert
    job_mark(l_scope, 'SW_R', 'K', 150);
    job_mark(l_scope, 'SW_M', 'K', 150);
    job_mark(l_scope, 'SW_H', 'T10', 186);
    l_n := alerts(l_p, 'C-HY', 'T10');
    chk('T10 Vorbereitung: 1 Alert', l_n = 1, l_n);
    put_rules(c_is_grp, 2, replace(base_rules, '185|180', '185|181'));
    job_mark(l_scope, 'SW_H', 'T10', 186);
    l_n := alerts(l_p, 'C-HY', 'T10');
    chk('T10 Rueckkehrgrenze geaendert: naechster Wert meldet', l_n = 2, l_n);
    put_rules(c_is_grp, 3, replace(base_rules, '185|180', '184|181'));
    job_mark(l_scope, 'SW_H', 'T10', 186);
    l_n := alerts(l_p, 'C-HY', 'T10');
    chk('T10 Schwelle geaendert: naechster Wert meldet', l_n = 3, l_n);
    job_mark(l_scope, 'SW_A', 'SAP', 150);
    l_n := alerts(l_p, 'C-UP', 'SAP');
    chk('T11 Regel unveraendert ueber zwei Versionen: kein Alert', l_n = 2, l_n);
    l_n := states('C-UP', 'SW_A', 'SAP');
    chk('T11 Zustand bleibt', l_n = 1, l_n);
    put_rules(c_is_grp, 4, replace(replace(base_rules, '185|180', '184|181'), '"C-UP","trigger_type":"MARK_EVENT","action":"SW_A","condition":{"operator":"VAL_CROSS_ABOVE"',
                                                                             '"C-UP","trigger_type":"MARK_EVENT","action":"SW_A","condition":{"operator":"VAL_CROSS_BELOW"'));
    job_mark(l_scope, 'SW_A', 'SAP', 50);
    l_n := alerts(l_p, 'C-UP', 'SAP');
    chk('T10 Operator gewechselt, gleiche Schwelle: meldet', l_n = 3, l_n);

    -- A1
    put_rules(c_is_grp, 5, replace(replace(replace(base_rules, ',' || r('C-RM', 'SW_R', 'VAL_CROSS_ABOVE', '100'), ''), '"SW_M"', '"SW_M2"'), '185|180', '184|181'));
    l_n := states('C-RM', 'SW_R', 'K');
    chk('A1 entfernte Regel: Zeile weg', l_n = 0, l_n);
    l_n := states('C-MV', 'SW_M', 'K');
    chk('A1 Regel auf andere Action umgezogen: Zeile weg', l_n = 0, l_n);
    l_n := states('C-HY', 'SW_H', 'T10');
    chk('A1 bestehende Regel: Zeile bleibt', l_n = 1, l_n);

    -- A2: Prozess ohne CLOSE
    execute immediate 'insert into lilam_alert_state(group_name, state_kind, state_key, ts_utc, rule_id, scope_id, action_name, cond_operator, cond_threshold, cond_rearm)
                       values (:1, ''CROSS'', ''P0|OLD|A2'', sys_extract_utc(systimestamp) - interval ''31'' day, ''A2-P'', null, ''SW_A2'', ''VAL_CROSS_ABOVE'', 1, 1)' using l_grp;
    execute immediate 'insert into lilam_alert_state(group_name, state_kind, state_key, ts_utc, rule_id, scope_id, action_name, cond_operator, cond_threshold, cond_rearm)
                       values (:1, ''CROSS'', ''P0|NEW|A2'', sys_extract_utc(systimestamp) - interval ''29'' day, ''A2-N'', null, ''SW_A2'', ''VAL_CROSS_ABOVE'', 1, 1)' using l_grp;
    execute immediate 'insert into lilam_alert_state(group_name, state_kind, state_key, ts_utc, rule_id, scope_id, action_name, cond_operator, cond_threshold, cond_rearm)
                       values (:1, ''CROSS'', ''S0|OLD|A2'', sys_extract_utc(systimestamp) - interval ''31'' day, ''A2-S'', 0, ''SW_A2'', ''VAL_CROSS_ABOVE'', 1, 1)' using l_grp;
    commit;
    job_mark(l_scope, 'SW_T', 'A2', 150);   -- Aufraeumen: Treffer in frischer Session
    l_n := states('A2-P', 'SW_A2', null);
    chk('A2 ohne Scope nach 31 Tagen geloescht', l_n = 0, l_n);
    l_n := states('A2-N', 'SW_A2', null);
    chk('A2 ohne Scope nach 29 Tagen bleibt', l_n = 1, l_n);
    l_n := states('A2-S', 'SW_A2', null);
    chk('A2 mit Scope bleibt', l_n = 1, l_n);
    execute immediate 'delete from lilam_alert_state where action_name = ''SW_A2''';
    commit;

    lt.close_wait(l_pid);
  end;

  procedure run_server is
    l_scope varchar2(80);
    l_pidA  number;
    l_pidB  number;
    l_n     number;
    l_ok    boolean;
    l_pipeA varchar2(50);
    l_pipeB varchar2(50);
    l_t     timestamp;
  begin
    l_mode  := lt.c_server;
    l_p     := 'LT_' || l_run || '_SV';
    l_scope := l_p || '_SC';

    -- X1
    l_pidA := newp('_SA', l_scope);
    l_pidB := newp('_SB', l_scope);
    dbms_session.sleep(0.5);
    execute immediate 'select max(pipe_name) from lilam_process_route where process_id = :1' into l_pipeA using l_pidA;
    execute immediate 'select max(pipe_name) from lilam_process_route where process_id = :1' into l_pipeB using l_pidB;
    chk('X1 Voraussetzung: Prozesse auf verschiedenen Workern', l_pipeA != l_pipeB, l_pipeA || ' / ' || l_pipeB);
    lilam.mark_event(l_pidA, 'SW_A', 'X1', 150);
    l_n := wait_alerts(l_p || '_S', 'C-UP', 'X1', 1);
    chk('X1 erster Worker: 1 Alert', l_n = 1, l_n);
    lilam.mark_event(l_pidB, 'SW_A', 'X1', 150);
    lilam.mark_event(l_pidB, 'SW_A', 'X1B', 150);
    l_n := wait_alerts(l_p || '_S', 'C-UP', 'X1B', 1);
    chk('X1 anderer Worker: X1B meldet (Gegenprobe)', l_n = 1, l_n);
    l_n := alerts(l_p || '_S', 'C-UP', 'X1');
    chk('X1 anderer Worker: X1 kein zweiter Alert', l_n = 1, l_n);

    -- X2
    dbms_session.sleep(11);   -- mindestens ein Lauf der Schweigepruefung im Server
    l_n := states('C-UP', 'SW_A', 'X1');
    chk('X2 Pruefung im Server laesst den Zustand stehen', l_n = 1, l_n);
    lt.close_wait(l_pidA);
    lt.close_wait(l_pidB);
    l_ok := lt.stop_server('LT_S1');
    l_ok := lt.stop_server('LT_S2') and l_ok;
    chk('X2 Worker gestoppt', l_ok);
    lt.start_server('LT_S1');
    lt.wait_servers_ready(sys.odcivarchar2list('LT_S1'));
    l_pidA := newp('_SD', l_scope);
    chk('X3 Voraussetzung: Prozess auf LT_S1', upper(lilam.get_server_pipe(l_pidA)) = 'LT_S1', lilam.get_server_pipe(l_pidA));
    lilam.mark_event(l_pidA, 'SW_A', 'X1', 150);
    lilam.mark_event(l_pidA, 'SW_A', 'X2', 150);
    l_n := wait_alerts(l_p || '_S', 'C-UP', 'X2', 1);
    chk('X2 nach Neustart: X2 meldet (Gegenprobe)', l_n = 1, l_n);
    l_n := alerts(l_p || '_S', 'C-UP', 'X1');
    chk('X2 nach Neustart: X1 kein neuer Alert', l_n = 1, l_n);

    -- X3: Rueckkehr und Ueberqueren liegen im Ringpuffer, wenn LT_S1 abbricht
    lt.start_server('LT_S2');
    lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2'));
    dbms_session.sleep(2);
    -- Logs halten die Pipe voll, sonst schreibt der Worker im Leerlauf sofort; so bleiben die Werte ungeschrieben
    lilam.mark_event(l_pidA, 'SW_A', 'X3', 50);
    for i in 1 .. 200 loop lilam.info(l_pidA, 'X3 vor ' || i); end loop;
    lilam.mark_event(l_pidA, 'SW_A', 'X3', 150);
    lilam.mark_event(l_pidA, 'SW_A', 'X3', 50);
    lilam.mark_event(l_pidA, 'SW_A', 'X3', 150);
    for i in 1 .. 20000 loop
      lilam.info(l_pidA, 'X3 nach ' || i);
      if mod(i, 20) = 0 then
        l_n := alerts(l_p || '_S', 'C-UP', 'X3');
        exit when l_n >= 2;
      end if;
    end loop;
    chk('X3 vor dem Abbruch: 2 Alerts', l_n = 2, l_n);
    l_err := lt.internal_errors_since(l_t0);   -- der Failover protokolliert selbst
    l_t := systimestamp;
    dbms_scheduler.stop_job('LT_S1');
    execute immediate 'select count(*) from lilam_mon where process_id = :1 and action = ''SW_A'' and context = ''X3''' into l_n using l_pidA;
    chk('X3 Voraussetzung: Werte beim Abbruch nicht committet', l_n < 4, l_n);
    -- der Client merkt den Ausfall am stockenden Wasserstand
    for i in 1 .. 60 loop
      lilam.info(l_pidA, 'X3 ' || i);
      exit when upper(lilam.get_server_pipe(l_pidA)) = 'LT_S2' and i > 5;
      dbms_session.sleep(0.5);
    end loop;
    chk('X3 Uebernahme durch LT_S2', upper(lilam.get_server_pipe(l_pidA)) = 'LT_S2', lilam.get_server_pipe(l_pidA));
    dbms_session.sleep(2);
    execute immediate 'select count(*), max(to_number(regexp_substr(error_message, ''(\d+) messages repeated'', 1, 1, null, 1)))
                         from lilam_log_internal
                        where log_timestamp >= :1 and log_operation = ''FAILOVER'' and error_message like ''%'' || :2 || ''%'''
      into l_n, l_pipeB using l_t, l_pidA;
    dbms_output.put_line('Failover: ' || l_n || ' Meldung(en), wiederholt ' || l_pipeB);
    chk('X3 Nachrichten wiederholt', to_number(l_pipeB) >= 3, l_pipeB);
    l_n := alerts(l_p || '_S', 'C-UP', 'X3');
    chk('X3 nach der Wiederholung: weiter 2 Alerts', l_n = 2, l_n);
    l_n := states('C-UP', 'SW_A', 'X3');
    chk('X3 Zustand wiederhergestellt', l_n = 1, l_n);
    lilam.mark_event(l_pidA, 'SW_A', 'X3', 150);
    lilam.mark_event(l_pidA, 'SW_A', 'X3B', 150);
    l_n := wait_alerts(l_p || '_S', 'C-UP', 'X3B', 1);
    chk('X3 danach: X3B meldet (Gegenprobe)', l_n = 1, l_n);
    l_n := alerts(l_p || '_S', 'C-UP', 'X3');
    chk('X3 danach: kein dritter Alert', l_n = 2, l_n);
    lt.close_wait(l_pidA);
  end;
begin
  l_run := lt.begin_run('SCHWELLEN', 'INSESSION+SERVER');
  l_t0  := systimestamp;
  lt.stop_all_servers;
  execute immediate 'delete from lilam_rules where set_name = :1' using c_set;
  execute immediate 'delete from lilam_alert_state where state_kind = ''CROSS''';
  commit;
  put_rules(c_is_grp, 1, base_rules);
  put_rules(lt.c_group, 1, base_rules);

  run_insession;

  lt.start_server('LT_S1');
  lt.start_server('LT_S2');
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2'));
  lilam.server_update_rules(lt.c_group, c_set, 1);
  dbms_session.sleep(1);
  run_server;
  lt.stop_all_servers;

  l_mode := 'ALLE';
  chk('X4 keine internen LILAM-Fehler', l_err = 0, l_err);

  -- Testgruppen ohne aktives Rule Set zuruecklassen
  execute immediate 'delete from lilam_rules where set_name = :1' using c_set;
  execute immediate 'delete from lilam_alert_state where state_kind = ''CROSS''';
  commit;
  lt.end_run(l_run);
exception
  when others then
    dbms_output.put_line('ABBRUCH: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
    lt.check_that(l_run, 'Abbruch', false, substr(sqlerrm || ' ' || dbms_utility.format_error_backtrace, 1, 1000));
    begin execute immediate 'alter table lilam_alerts drop constraint lt_sw_alert_fail'; exception when others then null; end;
    lt.stop_all_servers;
    lt.end_run(l_run);
end;
/
