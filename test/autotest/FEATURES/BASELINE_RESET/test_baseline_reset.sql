-- =====================================================================
-- LILAM Test: FEATURES / BASELINE_RESET
--
-- Prueft RESET_BASELINE(p_scopeName, p_actionName, p_contextName):
-- Zeit- und Wertreihe einer Baseline (Scope, Action, Context) werden zurueckgesetzt,
-- auch in der PGA anderer Sessions und Server.
--
--   INSESSION:
--   R0  Spalte LILAM_BASELINES.RESET_TS und Index IDX_LILAM_BASELINES_RESET vorhanden (auch nach Migration)
--   R1  Zeile zurueckgesetzt: avg_ms, avg_val NULL, action_count, val_count 0, reset_ts gesetzt
--   R2  nur die Kombination Action + Context: andere Contexts und die Reihe ohne Context bleiben
--   R3  eigene Session: der naechste Wert beginnt neu (USED_VALUE_EWMA = Wert, val_count 1)
--   R4  Context NULL setzt nur die Reihe ohne Context zurueck
--   R5  Scope-Name ohne Beachtung der Gross-/Kleinschreibung
--   R6  unbekannter Scope, Action NULL: kein Fehler, keine Zeile angelegt
--   R7  Warm-up beginnt neu: VAL_EWMA_DEVIATION_PCT_UP loest nach dem Reset nicht aus (Kontrolle ohne Reset: Alert)
--   R8  CALL_BY_JSON RESET_BASELINE
--   R9  andere Session (Job) mit noch nicht abgeglichenen Werten: diese gehen nicht in die Baseline zurueck
--   SERVER (2 Worker):
--   R10 zwei Prozesse im Scope; nach dem Reset beginnen beide Server neu (USED_VALUE_EWMA = Wert)
--   R11 keine internen LILAM-Fehler
--
-- Der Test startet und stoppt seine Server selbst (LT_S1, LT_S2). Nur einzeln ausfuehren.
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- =====================================================================
set serveroutput on size unlimited

declare
  c_set     constant varchar2(30) := 'LT_BASELINE_RESET';
  c_handler constant varchar2(30) := 'LT_BR_ALERT';
  c_is_grp  constant varchar2(30) := 'LT_BR_IS';
  c_tol     constant number := 1e-9;
  l_run     number;
  l_p       varchar2(60);      -- Prozess-Praefix je Modus, z. B. LT_2430_IS
  l_mode    varchar2(20);
  l_t0      timestamp(6);
  l_cnt_dummy number;

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

  -- Spalte der Baseline; Context NULL = Reihe ohne Context ('-'); -1 = keine Zeile
  function base(p_scope varchar2, p_action varchar2, p_ctx varchar2, p_col varchar2) return number is
    r number;
  begin
    execute immediate 'select ' || case when p_col = 'reset_ts' then 'nvl2(max(b.reset_ts), 1, 0)' else 'max(b.' || p_col || ')' end
                   || ', count(*) from lilam_baselines b join lilam_scopes s on s.scope_id = b.scope_id
                        where s.scope_name = upper(:1) and b.action_name = :2 and b.context_name = nvl(:3, ''-'')'
      into r, l_cnt_dummy using p_scope, p_action, p_ctx;
    return case when l_cnt_dummy = 0 then -1 else r end;
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

  -- eine Regel als JSON
  function r(p_id varchar2, p_action varchar2, p_op varchar2, p_val varchar2, p_ctx varchar2) return varchar2 is
  begin
    return '{"id":"' || p_id || '","trigger_type":"MARK_EVENT","action":"' || p_action || '","context":"' || p_ctx || '"'
        || ',"condition":{"operator":"' || p_op || '","value":"' || p_val || '"}'
        || ',"alert":{"handler":"' || c_handler || '","severity":"WARN","throttle_seconds":0}}';
  end;

  procedure put_rules(p_group varchar2) is
  begin
    execute immediate 'delete from lilam_rules where set_name = :1 and upper(group_name) = upper(:2)' using c_set, p_group;
    execute immediate 'insert into lilam_rules(group_name, set_name, version, is_active, created, author, rule_set)
                       values (:1, :2, 1, 0, systimestamp, ''LT'', :3)'
      using p_group, c_set,
            to_clob('{"header":{"rule_set":"' || c_set || '","rule_set_version":1},"rules":['
                    || r('BR-CTL', 'BR_R', 'VAL_EWMA_DEVIATION_PCT_UP', '20|3|0.5', 'CTL') || ','
                    || r('BR-RST', 'BR_R', 'VAL_EWMA_DEVIATION_PCT_UP', '20|3|0.5', 'RST') || ']}');
    commit;
    lilam.server_update_rules(p_group, c_set, 1);
    dbms_session.sleep(1);
  end;

  procedure run_insession is
    l_scope varchar2(60);
    l_pid   number;
    l_got   number;
    l_n     number;
    l_ts    timestamp(6) := systimestamp - interval '1' hour;
    l_req   json_object_t;
    l_resp  json_object_t;
    l_job   varchar2(30);
    l_ok    boolean;
  begin
    l_mode  := lt.c_insession;
    l_p     := 'LT_' || l_run || '_IS';
    l_scope := l_p || '_S';
    l_pid   := lilam.new_process(p_processName => l_p || '_A', p_logLevel => lilam.logLevelInfo,
                                 p_baselineScope => l_scope, p_groupName => c_is_grp);

    -- R0
    l_n := q('select count(*) from user_tab_columns where table_name = ''LILAM_BASELINES'' and column_name = :1', 'RESET_TS');
    chk('R0 Spalte RESET_TS vorhanden', l_n = 1, l_n);
    l_n := q('select count(*) from user_indexes where index_name = :1', 'IDX_LILAM_BASELINES_RESET');
    chk('R0 Index IDX_LILAM_BASELINES_RESET vorhanden', l_n = 1, l_n);

    -- Ausgangslage: je 4 Werte 100 im Abstand von 1 s in C1, C2 und ohne Context
    for i in 1 .. 4 loop
      lilam.mark_event(l_pid, 'BR_V', 'C1', 100, l_ts + numtodsinterval(i, 'SECOND'));
      lilam.mark_event(l_pid, 'BR_V', 'C2', 100, l_ts + numtodsinterval(i, 'SECOND'));
      lilam.mark_event(l_pid, 'BR_V', null, 100, l_ts + numtodsinterval(i, 'SECOND'));
    end loop;
    wait_base(l_scope, 'BR_V', 'C1', 4);
    l_got := base(l_scope, 'BR_V', 'C1', 'val_count');
    chk('vorher: C1 val_count 4', l_got = 4, l_got);
    l_got := base(l_scope, 'BR_V', 'C1', 'avg_ms');
    chk('vorher: C1 avg_ms gesetzt', l_got > 0, l_got);

    -- R1/R2
    lilam.reset_baseline(l_scope, 'BR_V', 'C1');
    chk('R1 avg_val NULL',       base(l_scope, 'BR_V', 'C1', 'avg_val') is null);
    chk('R1 val_count 0',        base(l_scope, 'BR_V', 'C1', 'val_count') = 0);
    chk('R1 avg_ms NULL',        base(l_scope, 'BR_V', 'C1', 'avg_ms') is null);
    chk('R1 action_count 0',     base(l_scope, 'BR_V', 'C1', 'action_count') = 0);
    chk('R1 reset_ts gesetzt',   base(l_scope, 'BR_V', 'C1', 'reset_ts') = 1);
    l_got := base(l_scope, 'BR_V', 'C2', 'val_count');
    chk('R2 anderer Context unveraendert (val_count 4)', l_got = 4, l_got);
    l_got := base(l_scope, 'BR_V', null, 'val_count');
    chk('R2 Reihe ohne Context unveraendert (val_count 4)', l_got = 4, l_got);

    -- R3
    lilam.mark_event(l_pid, 'BR_V', 'C1', 10, l_ts + numtodsinterval(10, 'SECOND'));
    lilam.flush;
    l_got := mon(l_pid, 'BR_V', 'C1', 'used_value_ewma');
    chk('R3 eigene Session: USED_VALUE_EWMA = erster Wert nach Reset (10)', same(l_got, 10), l_got);
    l_got := base(l_scope, 'BR_V', 'C1', 'val_count');
    chk('R3 val_count 1', l_got = 1, l_got);
    l_got := base(l_scope, 'BR_V', 'C1', 'avg_val');
    chk('R3 avg_val 10', same(l_got, 10), l_got);

    -- R4
    lilam.reset_baseline(l_scope, 'BR_V', null);
    l_got := base(l_scope, 'BR_V', null, 'val_count');
    chk('R4 Context NULL: Reihe ohne Context zurueckgesetzt', l_got = 0, l_got);
    l_got := base(l_scope, 'BR_V', 'C2', 'val_count');
    chk('R4 Context NULL: C2 unveraendert', l_got = 4, l_got);
    l_got := base(l_scope, 'BR_V', 'C1', 'val_count');
    chk('R4 Context NULL: C1 unveraendert', l_got = 1, l_got);

    -- R5
    lilam.reset_baseline(lower(l_scope), 'BR_V', 'C2');
    l_got := base(l_scope, 'BR_V', 'C2', 'val_count');
    chk('R5 Scope in Kleinschreibung', l_got = 0, l_got);

    -- R6
    lilam.reset_baseline(l_p || '_UNBEKANNT', 'BR_V', 'C1');
    lilam.reset_baseline(l_scope, null, 'C1');
    lilam.reset_baseline(null, 'BR_V', 'C1');
    l_n := q('select count(*) from lilam_scopes where scope_name = upper(:1)', l_p || '_UNBEKANNT');
    chk('R6 unbekannter Scope wird nicht angelegt', l_n = 0, l_n);
    l_got := base(l_scope, 'BR_V', 'C1', 'val_count');
    chk('R6 Action NULL: C1 unveraendert', l_got = 1, l_got);

    -- R7: Warm-up 3; ohne Reset loest 500 nach 4 x 100 aus
    for i in 1 .. 4 loop
      lilam.mark_event(l_pid, 'BR_R', 'CTL', 100);
      lilam.mark_event(l_pid, 'BR_R', 'RST', 100);
    end loop;
    lilam.reset_baseline(l_scope, 'BR_R', 'RST');
    lilam.mark_event(l_pid, 'BR_R', 'CTL', 500);
    lilam.mark_event(l_pid, 'BR_R', 'RST', 500);

    -- R8
    lilam.mark_event(l_pid, 'BR_V', 'C2', 50);
    lilam.mark_event(l_pid, 'BR_V', 'C2', 50);
    wait_base(l_scope, 'BR_V', 'C2', 2);
    l_req := json_object_t.parse('{"header":{"api_call":"RESET_BASELINE"},"params":{"scope_name":"' || l_scope
                                 || '","action_name":"BR_V","context_name":"C2"}}');
    lilam.call_by_json(l_req, l_resp);
    chk('R8 CALL_BY_JSON Status SUCCESS', l_resp.get_object('header').get_string('status') = 'SUCCESS', l_resp.to_string);
    l_got := base(l_scope, 'BR_V', 'C2', 'val_count');
    chk('R8 CALL_BY_JSON: C2 zurueckgesetzt', l_got = 0, l_got);

    lt.close_wait(l_pid);
    chk('R7 Kontrolle ohne Reset: Alert', alerts(l_p || '_A', 'BR-CTL') = 1, alerts(l_p || '_A', 'BR-CTL'));
    chk('R7 nach Reset: Warm-up, kein Alert', alerts(l_p || '_A', 'BR-RST') = 0, alerts(l_p || '_A', 'BR-RST'));

    -- R9: Job schreibt 3 x 100 (die letzten beiden bleiben ungesichert in seiner PGA, Abgleich alle 1,5 s),
    --     Reset nach ca. 2 s, danach 2 x 7. In die Baseline duerfen nur die Werte nach dem Reset.
    l_job := 'LT_BR_J_' || l_run;
    lt.run_job(l_job,
      'declare p number; begin '
      || 'p := lilam.new_process(p_processName => ''' || l_p || '_J'', p_logLevel => lilam.logLevelInfo, '
      || 'p_baselineScope => ''' || l_scope || '_J'', p_groupName => ''' || c_is_grp || '''); '
      || 'lilam.mark_event(p, ''BR_J'', null, 100); lilam.mark_event(p, ''BR_J'', null, 100); lilam.mark_event(p, ''BR_J'', null, 100); '
      || 'dbms_session.sleep(4); '
      || 'lilam.mark_event(p, ''BR_J'', null, 7); lilam.mark_event(p, ''BR_J'', null, 7); '
      || 'lilam.close_process(p); end;');
    l_n := 0;
    while nvl(base(l_scope || '_J', 'BR_J', null, 'val_count'), -1) < 1 and l_n < 10 loop
      dbms_session.sleep(0.2); l_n := l_n + 0.2;
    end loop;
    dbms_session.sleep(1.5);
    lilam.reset_baseline(l_scope || '_J', 'BR_J', null);
    l_ok := lt.wait_jobs(l_job, 30);
    chk('R9 Job beendet', l_ok);
    l_got := base(l_scope || '_J', 'BR_J', null, 'val_count');
    chk('R9 andere Session: nur Werte nach dem Reset (val_count 1)', l_got = 1, l_got);
    l_got := base(l_scope || '_J', 'BR_J', null, 'avg_val');
    chk('R9 andere Session: avg_val 7', same(l_got, 7), l_got);
  end;

  procedure run_server is
    l_scope varchar2(60);
    l_pid1  number;
    l_pid2  number;
    l_got   number;
  begin
    l_mode  := lt.c_server;
    l_p     := 'LT_' || l_run || '_SV';
    l_scope := l_p || '_S';
    l_pid1  := lilam.server_new_process(p_processName => l_p || '_A', p_groupName => lt.c_group,
                                        p_logLevel => lilam.logLevelInfo, p_baselineScope => l_scope);
    l_pid2  := lilam.server_new_process(p_processName => l_p || '_B', p_groupName => lt.c_group,
                                        p_logLevel => lilam.logLevelInfo, p_baselineScope => l_scope);
    for i in 1 .. 5 loop
      lilam.mark_event(l_pid1, 'BR_V', 'S', 100);
      lilam.mark_event(l_pid2, 'BR_V', 'S', 100);
    end loop;
    wait_base(l_scope, 'BR_V', 'S', 10);
    l_got := base(l_scope, 'BR_V', 'S', 'val_count');
    chk('vorher: val_count 10', l_got = 10, l_got || '; Server ' || lilam.get_server_pipe(l_pid1) || '/' || lilam.get_server_pipe(l_pid2));

    -- R10: Reset aus der Client-Session, die Server haben die Baseline sauber in der PGA
    lilam.reset_baseline(l_scope, 'BR_V', 'S');
    dbms_session.sleep(3);   -- > Abgleich der Server (1,5 s)
    lilam.mark_event(l_pid1, 'BR_V', 'S', 7);
    lilam.mark_event(l_pid2, 'BR_V', 'S', 7);
    lt.close_wait(l_pid1);
    lt.close_wait(l_pid2);
    wait_base(l_scope, 'BR_V', 'S', 2);
    l_got := mon(l_pid1, 'BR_V', 'S', 'used_value_ewma');
    chk('R10 Prozess A: USED_VALUE_EWMA = 7 (neu begonnen)', same(l_got, 7), l_got);
    l_got := mon(l_pid2, 'BR_V', 'S', 'used_value_ewma');
    chk('R10 Prozess B: USED_VALUE_EWMA = 7 (neu begonnen)', same(l_got, 7), l_got);
    l_got := base(l_scope, 'BR_V', 'S', 'val_count');
    chk('R10 val_count 2', l_got = 2, l_got);
    l_got := base(l_scope, 'BR_V', 'S', 'avg_val');
    chk('R10 avg_val 7', same(l_got, 7), l_got);
  end;
begin
  l_run := lt.begin_run('BASELINE_RESET', 'INSESSION+SERVER');
  l_t0  := systimestamp;
  lt.stop_all_servers;
  put_rules(c_is_grp);

  run_insession;

  lt.start_server('LT_S1');
  lt.start_server('LT_S2');
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2'));
  run_server;
  lt.stop_all_servers;

  l_mode := 'ALLE';
  chk('R11 keine internen LILAM-Fehler', lt.internal_errors_since(l_t0) = 0, lt.internal_errors_since(l_t0));

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
