-- =====================================================================
-- LILAM Test: FEATURES / MESSWERTE
--
-- Prueft MARK_EVENT mit Messwert (p_value): Wert-EWMA, Trennung von Zeit- und Wertreihe,
-- Baseline Scope, Regeln TIME_/VAL_ und Transport im SERVER-Modus.
-- Erwartete EWMA-Werte rechnet der Test unabhaengig nach (Warm-up: arithmetisches Mittel,
-- danach alt + alpha * (neu - alt)).
--
--   Je Modus (INSESSION, SERVER):
--   M1  Werte und EWMA in _MON (Reihe E, Standardparameter warmup 3, alpha 0.1), auch 0 und negativ
--   M2  Zeitreihe unberuehrt: feste Abstaende 1000 ms => USED_MILLIS_EWMA 1000
--   M3  Baseline Scope ueber eine neue Process ID: EWMA laeuft weiter, LILAM_BASELINES val_count/avg_val,
--       action_count zaehlt getrennt (Abstaende)
--   M4  Isolation: anderer Kontext, anderer Scope
--   M5  Event ohne Wert (alter Aufruf mit 3 Parametern): USED_VALUE/USED_VALUE_EWMA NULL, kein val_count
--   M6  Nachkommastellen und Wertebereich (1234567.891234567, 1.5E100, 1.23456789E-7) unveraendert
--   M7  GET_METRIC_AVG_VALUE = nachgerechneter EWMA
--   M8  Regeln: VAL_EWMA_DEVIATION_PCT_UP/_DOWN (Referenz vor der Messung, auch negative Werte),
--       VAL_MIN, VAL_MAX (Grenzen exklusiv), TIME_EWMA_DEVIATION_PCT_DOWN
--   Nur INSESSION:
--   M9  CALL_BY_JSON MARK_EVENT mit "value"
--   M10 ungueltige Regeln werden abgelehnt (VAL_ an TRACE_STOP, leerer Teil, alter Name, kein Wert)
--   Nur SERVER:
--   M11 Reconnect: Werte aus einer anderen DB-Session (Job ueber Dispatcher) zaehlen in derselben Reihe
--   M12 Parallel: 3 Prozesse in einem Scope je 20 Werte 42 => val_count 60, avg_val 42, Reihenfolge je Prozess
--   M13 keine internen LILAM-Fehler (Hinweise BACKPRESSURE/GAP und die Probe aus M14 ausgenommen)
--   M14 eine nicht lesbare Nachricht an den Server wird als BAD_MESSAGE protokolliert
--
-- Der Test startet und stoppt seine Server selbst (LT_S1, Dispatcher LT_DISP).
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- =====================================================================
set serveroutput on size unlimited

declare
  c_set     constant varchar2(30) := 'LT_MESSWERTE';
  c_handler constant varchar2(30) := 'LT_MW_ALERT';
  c_is_grp  constant varchar2(30) := 'LT_MW_IS';
  c_tol     constant number := 1e-9;
  l_run     number;
  l_p       varchar2(60);      -- Prozess-Praefix je Modus, z. B. LT_2400_IS
  l_mode    varchar2(20);
  l_t0      timestamp(6);
  l_err     number;

  type t_vals is table of number;

  -- Erwarteter EWMA (wie calculate_ewma fuer Werte): 1. Wert, Warm-up Mittel, danach EWMA
  function ew(p_vals t_vals, p_warmup pls_integer, p_alpha number) return number is
    l_avg number;
  begin
    for i in 1 .. p_vals.count loop
      if i = 1 then
        l_avg := p_vals(i);
      elsif i <= p_warmup then
        l_avg := (l_avg * (i - 1) + p_vals(i)) / i;
      else
        l_avg := l_avg + p_alpha * (p_vals(i) - l_avg);
      end if;
    end loop;
    return l_avg;
  end;

  function same(a number, b number) return boolean is
  begin
    return (a is null and b is null) or abs(a - b) <= c_tol * greatest(1, abs(b));
  end;

  function q(p_sql varchar2, p_b1 varchar2 default null, p_b2 varchar2 default null) return number is
    r number;
  begin
    if p_b2 is not null then
      execute immediate p_sql into r using p_b1, p_b2;
    else
      execute immediate p_sql into r using p_b1;
    end if;
    return r;
  exception when others then return -999;
  end;

  -- letzter Eintrag einer Reihe in _MON (nach action_count)
  function mon(p_pid number, p_action varchar2, p_ctx varchar2, p_col varchar2) return number is
    r number;
  begin
    execute immediate 'select max(' || p_col || ') keep (dense_rank last order by action_count)
                         from lilam_mon where process_id = :1 and action = :2 and nvl(context, ''-'') = nvl(:3, ''-'') and mon_type = 0'
      into r using p_pid, p_action, p_ctx;
    return r;
  end;

  function base(p_scope varchar2, p_action varchar2, p_ctx varchar2, p_col varchar2) return number is
    r number;
  begin
    execute immediate 'select max(b.' || p_col || ') from lilam_baselines b join lilam_scopes s on s.scope_id = b.scope_id
                        where s.scope_name = upper(:1) and b.action_name = :2 and b.context_name = :3'
      into r using p_scope, p_action, p_ctx;
    return r;
  end;

  procedure wait_base(p_scope varchar2, p_action varchar2, p_ctx varchar2, p_valCount number, p_max_s number default 15) is
    l_w number := 0;
  begin
    if l_mode = lt.c_insession then
      lilam.flush;   -- schreibt auch die Baselines dieser Session
    end if;
    while nvl(base(p_scope, p_action, p_ctx, 'val_count'), 0) < p_valCount and l_w < p_max_s loop
      dbms_session.sleep(0.5); l_w := l_w + 0.5;
    end loop;
  end;

  function alerts(p_proc varchar2, p_rule varchar2) return number is
  begin
    return q('select count(*) from lilam_alerts where process_name = :1 and rule_id = :2', p_proc, p_rule);
  end;

  procedure chk(p_name varchar2, p_ok boolean, p_detail varchar2 default null) is
  begin
    lt.check_that(l_run, l_mode || ' ' || p_name, nvl(p_ok, false), p_detail);
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

  -- eine Regel als JSON
  function r(p_id varchar2, p_trig varchar2, p_action varchar2, p_op varchar2, p_val varchar2, p_ctx varchar2 default null) return varchar2 is
  begin
    return '{"id":"' || p_id || '","trigger_type":"' || p_trig || '","action":"' || p_action || '"'
        || case when p_ctx is not null then ',"context":"' || p_ctx || '"' end
        || ',"condition":{"operator":"' || p_op || '","value":"' || p_val || '"}'
        || ',"alert":{"handler":"' || c_handler || '","severity":"WARN","throttle_seconds":0}}';
  end;

  procedure ins(p_group varchar2, p_ver number, p_rules varchar2) is
  begin
    execute immediate 'insert into lilam_rules(group_name, set_name, version, is_active, created, author, rule_set)
                       values (:1, :2, :3, 0, systimestamp, ''LT'', :4)'
      using p_group, c_set, p_ver,
            to_clob('{"header":{"rule_set":"' || c_set || '","rule_set_version":' || p_ver || '},"rules":[' || p_rules || ']}');
  end;

  procedure put_rules(p_group varchar2) is
    l varchar2(4000);
  begin
    l :=             r('V-UP',  'MARK_EVENT', 'MW_V',   'VAL_EWMA_DEVIATION_PCT_UP',   '20|3|0.5', 'UP');
    l := l || ',' || r('V-DN',  'MARK_EVENT', 'MW_V',   'VAL_EWMA_DEVIATION_PCT_DOWN', '20|3|0.5', 'DN');
    l := l || ',' || r('V-UPX', 'MARK_EVENT', 'MW_V',   'VAL_EWMA_DEVIATION_PCT_UP',   '20|3|0.5', 'DN');
    l := l || ',' || r('V-MIN', 'MARK_EVENT', 'MW_LIM', 'VAL_MIN', '-5');
    l := l || ',' || r('V-MAX', 'MARK_EVENT', 'MW_LIM', 'VAL_MAX', '100.5');
    l := l || ',' || r('T-DN',  'TRACE_STOP', 'MW_T',   'TIME_EWMA_DEVIATION_PCT_DOWN', '50|3|0.5');
    l := l || ',' || r('T-UP',  'TRACE_STOP', 'MW_T',   'TIME_EWMA_DEVIATION_PCT_UP',   '50|3|0.5');
    execute immediate 'delete from lilam_rules where set_name = :1 and upper(group_name) = upper(:2)' using c_set, p_group;
    ins(p_group, 1, l);
    -- ungueltige Versionen (M10)
    ins(p_group, 2, r('X2', 'TRACE_STOP', 'MW_V', 'VAL_MIN', '1'));
    ins(p_group, 3, r('X3', 'MARK_EVENT', 'MW_V', 'VAL_EWMA_DEVIATION_PCT_UP', '20||0.5'));
    ins(p_group, 4, r('X4', 'TRACE_STOP', 'MW_V', 'AVG_DEVIATION_PCT', '20'));
    ins(p_group, 5, r('X5', 'MARK_EVENT', 'MW_V', 'VAL_MAX', 'abc'));
    commit;
    lilam.server_update_rules(p_group, c_set, 1);
    dbms_session.sleep(1);
  end;

  procedure run_mode(p_mode varchar2, p_tag varchar2) is
    l_e1   t_vals := t_vals(80.71, 81.5, 79.25, 0, -3.125, 82);
    l_e2   t_vals := t_vals(83.4, 84.15);
    l_all  t_vals := t_vals(80.71, 81.5, 79.25, 0, -3.125, 82, 83.4, 84.15);
    l_pid1 number;
    l_pid2 number;
    l_pid3 number;
    l_pid4 number;
    l_exp  number;
    l_got  number;
    l_n    number;
    l_ts   timestamp(6) := systimestamp - interval '1' hour;
  begin
    l_mode := p_mode;
    l_p    := 'LT_' || l_run || '_' || p_tag;

    -- M1/M2: Reihe E, feste Abstaende 1000 ms
    l_pid1 := newp('_A');
    for i in 1 .. l_e1.count loop
      lilam.mark_event(l_pid1, 'MW_V', 'E', l_e1(i), l_ts + numtodsinterval(i, 'SECOND'));
    end loop;
    -- M4: anderer Kontext
    lilam.mark_event(l_pid1, 'MW_V', 'E2', 1000);
    lilam.mark_event(l_pid1, 'MW_V', 'E2', 1000);
    -- M5: alter Aufruf ohne Wert
    for i in 1 .. 3 loop
      lilam.mark_event(l_pid1, 'MW_N', 'N');
    end loop;
    -- M6: Nachkommastellen und Wertebereich
    lilam.mark_event(l_pid1, 'MW_P', 'DEC',  1234567.891234567);
    lilam.mark_event(l_pid1, 'MW_P', 'BIG',  1.5E100);
    lilam.mark_event(l_pid1, 'MW_P', 'TINY', 1.23456789E-7);
    -- M8: Regeln
    for v in (select column_value x from table(sys.odcinumberlist(100, 100, 100, 110, 130))) loop
      lilam.mark_event(l_pid1, 'MW_V', 'UP', v.x);
    end loop;
    for v in (select column_value x from table(sys.odcinumberlist(-50, -50, -50, -45, -70))) loop
      lilam.mark_event(l_pid1, 'MW_V', 'DN', v.x);
    end loop;
    for v in (select column_value x from table(sys.odcinumberlist(50, -5.5, 100.6, 100.5, -5))) loop
      lilam.mark_event(l_pid1, 'MW_LIM', null, v.x);
    end loop;
    for v in (select rownum n, column_value d from table(sys.odcinumberlist(200, 200, 200, 50))) loop
      lilam.trace_start(l_pid1, 'MW_T', null, l_ts + numtodsinterval(v.n * 10, 'SECOND'));
      lilam.trace_stop(l_pid1, 'MW_T', null, l_ts + numtodsinterval(v.n * 10 + v.d / 1000, 'SECOND'));
    end loop;
    lt.close_wait(l_pid1);

    -- M3: neue Process ID im selben Scope (Prozessname)
    l_pid2 := newp('_A');
    for i in 1 .. l_e2.count loop
      lilam.mark_event(l_pid2, 'MW_V', 'E', l_e2(i), l_ts + numtodsinterval(100 + i, 'SECOND'));
    end loop;
    -- M7
    l_got := lilam.get_metric_avg_value(l_pid2, 'MW_V', 'E');
    l_exp := ew(l_all, 3, 0.1);
    chk('M7 GET_METRIC_AVG_VALUE = EWMA ueber beide Prozesse', same(l_got, l_exp), l_got || ' / erwartet ' || l_exp);
    lt.close_wait(l_pid2);

    -- M4: anderer Scope, gleicher Prozessname
    l_pid3 := newp('_A', l_p || '_OTHER');
    lilam.mark_event(l_pid3, 'MW_V', 'E', 5);
    lt.close_wait(l_pid3);

    -- Auswertung M1
    chk('M1 USED_VALUE exakt gespeichert (letzter Wert 82)', mon(l_pid1, 'MW_V', 'E', 'used_value') = 82);
    l_n := q('select count(*) from lilam_mon where process_id = :1 and action = ''MW_V'' and context = ''E'' and used_value is not null', l_pid1);
    chk('M1 alle 6 Werte in _MON', l_n = 6, l_n);
    l_exp := ew(l_e1, 3, 0.1);
    l_got := mon(l_pid1, 'MW_V', 'E', 'used_value_ewma');
    chk('M1 USED_VALUE_EWMA = nachgerechnet (warmup 3, alpha 0.1)', same(l_got, l_exp), l_got || ' / erwartet ' || l_exp);
    l_got := q('select used_value_ewma from lilam_mon where process_id = :1 and action = ''MW_V'' and context = ''E'' and action_count = 3', l_pid1);
    chk('M1 Warm-up: EWMA nach 3 Werten = Mittelwert', same(l_got, (80.71 + 81.5 + 79.25) / 3), l_got);
    l_got := q('select used_value_ewma from lilam_mon where process_id = :1 and action = ''MW_V'' and context = ''E'' and action_count = 1', l_pid1);
    chk('M1 erster Wert: EWMA = Wert', same(l_got, 80.71), l_got);

    -- M2
    l_got := mon(l_pid1, 'MW_V', 'E', 'used_millis_ewma');
    chk('M2 USED_MILLIS_EWMA der Wertreihe = 1000 ms (Zeitreihe getrennt)', l_got = 1000, l_got);
    l_got := mon(l_pid1, 'MW_V', 'E', 'used_millis');
    chk('M2 USED_MILLIS = 1000 ms', l_got = 1000, l_got);

    -- M3
    l_exp := ew(l_all, 3, 0.1);
    l_got := mon(l_pid2, 'MW_V', 'E', 'used_value_ewma');
    chk('M3 neue Process ID: EWMA laeuft ueber den Scope weiter', same(l_got, l_exp), l_got || ' / erwartet ' || l_exp);
    wait_base(l_p || '_A', 'MW_V', 'E', 8);
    l_got := base(l_p || '_A', 'MW_V', 'E', 'val_count');
    chk('M3 LILAM_BASELINES val_count = 8', l_got = 8, l_got);
    l_got := base(l_p || '_A', 'MW_V', 'E', 'avg_val');
    chk('M3 LILAM_BASELINES avg_val = nachgerechnet', same(l_got, l_exp), l_got || ' / erwartet ' || l_exp);
    l_got := base(l_p || '_A', 'MW_V', 'E', 'action_count');
    chk('M3 action_count zaehlt nur Abstaende (5 + 1)', l_got = 6, l_got);
    l_got := base(l_p || '_A', 'MW_V', 'E', 'avg_ms');
    chk('M3 avg_ms der Zeitreihe = 1000', l_got = 1000, l_got);

    -- M4
    l_got := mon(l_pid1, 'MW_V', 'E2', 'used_value_ewma');
    chk('M4 anderer Kontext eigene Reihe (1000)', l_got = 1000, l_got);
    l_got := mon(l_pid3, 'MW_V', 'E', 'used_value_ewma');
    chk('M4 anderer Scope beginnt neu (5)', l_got = 5, l_got);
    wait_base(l_p || '_OTHER', 'MW_V', 'E', 1);
    l_got := base(l_p || '_OTHER', 'MW_V', 'E', 'val_count');
    chk('M4 anderer Scope: val_count 1', l_got = 1, l_got);

    -- M5
    l_n := q('select count(*) from lilam_mon where process_id = :1 and action = ''MW_N'' and used_value is null and used_value_ewma is null', l_pid1);
    chk('M5 Events ohne Wert: USED_VALUE und USED_VALUE_EWMA leer', l_n = 3, l_n);
    l_got := base(l_p || '_A', 'MW_N', 'N', 'val_count');
    chk('M5 Events ohne Wert: val_count 0', l_got = 0, l_got);
    l_got := mon(l_pid1, 'MW_N', 'N', 'action_count');
    chk('M5 ACTION_COUNT zaehlt weiter (3)', l_got = 3, l_got);

    -- M6
    chk('M6 1234567.891234567 unveraendert', mon(l_pid1, 'MW_P', 'DEC', 'used_value') = 1234567.891234567,
        mon(l_pid1, 'MW_P', 'DEC', 'used_value'));
    chk('M6 1.5E100 unveraendert', mon(l_pid1, 'MW_P', 'BIG', 'used_value') = 1.5E100);
    chk('M6 1.23456789E-7 unveraendert', mon(l_pid1, 'MW_P', 'TINY', 'used_value') = 1.23456789E-7);

    -- M8: Alerts (Server schreibt asynchron; geschlossen ist der Prozess bereits)
    l_n := alerts(l_p || '_A', 'V-UP');
    chk('M8 VAL_EWMA_DEVIATION_PCT_UP: nur 130 (Referenz 105, Grenze 126)', l_n = 1, l_n);
    l_n := alerts(l_p || '_A', 'V-DN');
    chk('M8 VAL_EWMA_DEVIATION_PCT_DOWN negativ: nur -70 (Referenz -47.5, Grenze -57)', l_n = 1, l_n);
    l_n := alerts(l_p || '_A', 'V-UPX');
    chk('M8 _UP feuert nicht bei fallenden Werten', l_n = 0, l_n);
    l_n := alerts(l_p || '_A', 'V-MIN');
    chk('M8 VAL_MIN -5: nur -5.5', l_n = 1, l_n);
    l_n := alerts(l_p || '_A', 'V-MAX');
    chk('M8 VAL_MAX 100.5: nur 100.6', l_n = 1, l_n);
    l_n := alerts(l_p || '_A', 'T-DN');
    chk('M8 TIME_EWMA_DEVIATION_PCT_DOWN: 50 ms bei Referenz 200 ms', l_n = 1, l_n);
    l_n := alerts(l_p || '_A', 'T-UP');
    chk('M8 TIME_EWMA_DEVIATION_PCT_UP feuert nicht', l_n = 0, l_n);
  end;

  -- M9/M10, nur INSESSION
  procedure run_insession_extra is
    l_pid  number;
    l_resp json_object_t;
    l_got  number;
    procedure rejected(p_ver number, p_text varchar2) is
      l_ok boolean := false;
      l_msg varchar2(1000);
    begin
      begin
        lilam.server_update_rules(c_is_grp, c_set, p_ver);
      exception when others then
        l_ok := true; l_msg := substr(sqlerrm, 1, 300);
      end;
      chk('M10 abgelehnt: ' || p_text, l_ok, l_msg);
    end;
  begin
    l_mode := lt.c_insession;
    l_pid := newp('_J');
    lilam.call_by_json(json_object_t('{"header":{"api_call":"MARK_EVENT"},"params":{"process_id":' || l_pid
                                     || ',"action_name":"MW_J","context_name":"J","value":3.25}}'), l_resp);
    lt.close_wait(l_pid);
    l_got := mon(l_pid, 'MW_J', 'J', 'used_value');
    chk('M9 CALL_BY_JSON MARK_EVENT mit "value"', l_got = 3.25, l_got);

    rejected(2, 'VAL_MIN an TRACE_STOP');
    rejected(3, 'VAL_EWMA_DEVIATION_PCT_UP mit leerem Teil');
    rejected(4, 'alter Operator AVG_DEVIATION_PCT');
    rejected(5, 'VAL_MAX ohne Zahl');
    l_got := q('select version from lilam_rules where upper(group_name) = upper(:1) and is_active = 1', c_is_grp);
    chk('M10 aktive Version bleibt 1', l_got = 1, l_got);
  end;

  -- M11/M12, nur SERVER
  procedure run_server_extra is
    l_pid   number;
    l_vals  t_vals := t_vals(7.5, 8.5, 9.5, 10.5);
    l_exp   number;
    l_got   number;
    l_n     number;
    l_ok    boolean;
    l_scope varchar2(80);
  begin
    l_mode := lt.c_server;
    -- M11: Reconnect ueber den Dispatcher aus einer anderen Session
    l_pid := newp('_RC');
    lilam.mark_event(l_pid, 'MW_V', 'RC', l_vals(1));
    dbms_session.sleep(0.5);
    lt.run_job('LT_MW_RC_' || l_run,
               'begin lilam.set_dispatcher_pipe(''' || lt.c_disp_pipe || ''');'
            || ' lilam.mark_event(' || l_pid || ', ''MW_V'', ''RC'', 8.5);'
            || ' lilam.mark_event(' || l_pid || ', ''MW_V'', ''RC'', 9.5);'
            || ' dbms_session.sleep(1); end;');
    l_ok := lt.wait_jobs('LT_MW_RC_', 30);
    dbms_session.sleep(1);
    lilam.mark_event(l_pid, 'MW_V', 'RC', l_vals(4));
    lt.close_wait(l_pid);
    l_n := q('select count(*) from lilam_mon where process_id = :1 and action = ''MW_V'' and context = ''RC'' and used_value is not null', l_pid);
    chk('M11 Reconnect: alle 4 Werte in derselben Reihe', l_n = 4, l_n);
    l_exp := ew(l_vals, 3, 0.1);
    l_got := mon(l_pid, 'MW_V', 'RC', 'used_value_ewma');
    chk('M11 Reconnect: EWMA ueber alle Sessions', same(l_got, l_exp), l_got || ' / erwartet ' || l_exp);
    l_n := q('select count(distinct action_count) from lilam_mon where process_id = :1 and action = ''MW_V'' and context = ''RC''', l_pid);
    chk('M11 Reconnect: ACTION_COUNT 1..4 ohne Luecke', l_n = 4, l_n);

    -- M12: 3 parallele Prozesse, gemeinsamer Scope
    l_scope := 'LT_' || l_run || '_PAR';
    for j in 1 .. 3 loop
      lt.run_job('LT_MW_PAR_' || l_run || '_' || j,
                 'declare p number; begin p := lilam.server_new_process(p_processName => ''LT_' || l_run || '_PAR_' || j
              || ''', p_groupName => ''' || lt.c_group || ''', p_logLevel => lilam.logLevelInfo, p_baselineScope => ''' || l_scope || ''');'
              || ' for i in 1 .. 20 loop lilam.mark_event(p, ''MW_V'', ''PAR'', 42); end loop;'
              || ' lilam.close_process(p); end;');
    end loop;
    l_ok := lt.wait_jobs('LT_MW_PAR_', 60);
    chk('M12 Jobs beendet', l_ok);
    wait_base(l_scope, 'MW_V', 'PAR', 60, 20);
    l_got := base(l_scope, 'MW_V', 'PAR', 'val_count');
    chk('M12 parallel: val_count 60', l_got = 60, l_got);
    l_got := base(l_scope, 'MW_V', 'PAR', 'avg_val');
    chk('M12 parallel: avg_val 42', same(l_got, 42), l_got);
    l_n := q('select count(*) from (select m.process_id from lilam_mon m join lilam_proc p on p.id = m.process_id
               where p.process_name like :1 escape ''\'' and m.action = ''MW_V'' and m.context = ''PAR'' and m.used_value = 42
               group by m.process_id having count(*) = 20 and count(distinct m.action_count) = 20 and max(m.action_count) = 20)',
             'LT\_' || l_run || '\_PAR\_%');
    chk('M12 parallel: je Prozess 20 Werte, ACTION_COUNT 1..20', l_n = 3, l_n);

    -- M14: nicht lesbare Nachricht (Zahl mit Dezimalkomma wie vor der Korrektur von jNum) wird protokolliert
    dbms_pipe.pack_message('{"header":{"msg_type":"API_CALL","request":"MARK_EVENT"},"payload":{"process_id":1,"action_name":"MW_BAD","value":1,5E+100}}');
    l_n := dbms_pipe.send_message('LT_S1', 1);
    dbms_session.sleep(2);
    execute immediate 'select count(*) from lilam_log_internal where log_timestamp >= :1 and log_operation = ''BAD_MESSAGE''
                         and error_message like ''%MW_BAD%''' into l_n using l_t0;
    chk('M14 nicht lesbare Nachricht in LILAM_LOG_INTERNAL (BAD_MESSAGE)', l_n = 1, l_n);
  end;
begin
  l_run := lt.begin_run('MESSWERTE', 'INSESSION+SERVER');
  l_t0  := systimestamp;
  lt.stop_all_servers;
  put_rules(c_is_grp);
  put_rules(lt.c_group);

  run_mode(lt.c_insession, 'IS');
  run_insession_extra;

  lt.start_server('LT_S1');
  lt.start_server(lt.c_disp_pipe, 1);
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', lt.c_disp_pipe));
  lilam.server_update_rules(lt.c_group, c_set, 1);
  dbms_session.sleep(1);
  run_mode(lt.c_server, 'SV');
  run_server_extra;
  lt.stop_all_servers;

  l_mode := 'ALLE';
  begin
    execute immediate 'select count(*) from lilam_log_internal where log_timestamp >= :1
                         and nvl(log_operation, ''-'') not in (''BACKPRESSURE'', ''GAP'', ''BAD_MESSAGE'')' into l_err using l_t0;
  exception when others then l_err := 0;   -- Tabelle entsteht erst beim ersten internen Fehler
  end;
  chk('M13 keine internen LILAM-Fehler', l_err = 0, l_err);

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
