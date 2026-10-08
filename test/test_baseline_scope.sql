-- ============================================================
-- LILAM: Test prozessübergreifende Baseline (Insession-Mode)
-- Voraussetzung: lilam.pks / lilam.pkb kompiliert
-- ============================================================
set serveroutput on

declare
    l_pid number;

    procedure run_app(p_runs pls_integer, p_sleep number) is
    begin
        l_pid := LILAM.NEW_PROCESS('App 1');                -- Scope = 'APP 1' (Default)
        for i in 1 .. p_runs loop
            LILAM.TRACE_START(l_pid, 'TOR 1 BEWEGEN');
            dbms_session.sleep(p_sleep);
            LILAM.TRACE_STOP(l_pid, 'TOR 1 BEWEGEN');
        end loop;
        dbms_output.put_line('pid=' || l_pid || ' avg=' || LILAM.GET_METRIC_AVG_DURATION(l_pid, 'TOR 1 BEWEGEN'));
        LILAM.CLOSE_PROCESS(l_pid);                         -- erzwingt Abgleich mit LILAM_BASELINES
    end;
begin
    -- drei Neustarts mit je zwei Messungen => Baseline zählt 6 Messungen
    run_app(2, 0.2);
    run_app(2, 0.2);
    run_app(2, 0.2);

    -- Gegenprobe: ohne Scope
    declare
        l_init LILAM.t_process_init;
    begin
        l_init.processName   := 'App 1';
        l_init.baselineScope := '#NONE';
        l_pid := LILAM.NEW_PROCESS(l_init);
        LILAM.TRACE_START(l_pid, 'TOR 1 BEWEGEN');
        LILAM.TRACE_STOP(l_pid, 'TOR 1 BEWEGEN');
        LILAM.CLOSE_PROCESS(l_pid);
    end;
end;
/

-- Erwartet: eine Zeile, ACTION_COUNT = 6, AVG_MS ~ 200
select s.scope_name, b.action_name, b.context_name, b.avg_ms, b.action_count, b.last_update
  from lilam_baselines b
  join lilam_scopes s on s.scope_id = b.scope_id
 where s.scope_name = 'APP 1';

-- Erwartet: ACTION_COUNT pro Prozess 1..2 (prozesslokal), AVG_MILLIS = Scope-Baseline
select p.id, p.scope_name, m.action, m.action_count, m.used_millis, m.avg_millis
  from lilam_proc p
  join lilam_mon  m on m.process_id = p.id
 where p.process_name = 'App 1'
 order by p.id, m.start_time;

-- Interne Fehler (die Tabelle wird erst beim ersten internen Fehler angelegt)
declare
    l_cnt number;
begin
    select count(*) into l_cnt from user_tables where table_name = 'LILAM_LOG_INTERNAL';
    if l_cnt > 0 then
        execute immediate 'select count(*) from lilam_log_internal' into l_cnt;
    end if;
    dbms_output.put_line('Interne LILAM-Fehler: ' || l_cnt);
end;
/
