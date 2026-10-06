-- =====================================================================
-- LILAM Diagnose: SERVERAUSWAHL - gezielte Provokation des Ungleichgewichts (V0-V7)
-- Plan: 2026-10-06_serverauswahl_provokation.md (Ordner LILAM)
--
-- Hypothese H1: Das erste Kriterium der Serverauswahl (PROCESSING) wird nur im Housekeeping eines
-- untaetigen Servers geschrieben. Ein beschaeftigter Server behaelt seinen alten (kleinen) Wert und
-- bekommt dann jede weitere NEW_SESSION.
--
-- Nutzt nur die bestehende API (lilam.*, lt.*). Legt eigene Diagnoseobjekte an:
--   LT_DIAG_SEL               je NEW_SESSION: Zeit, gewaehlter Worker, Registry-Snapshot davor
--   lt_diag_sel_burst         ein Burst (laeuft als Client-Job = frische Session)
--   lt_diag_sel_driver        Versuchsmatrix V0-V7 (laeuft als Job LT_CDIAG_DRV)
-- Start:   dieses Skript ausfuehren; es kehrt sofort zurueck (run_id in LT_RUN, Test SERVERAUSWAHL_DIAG)
-- Ende:    LT_RUN.STATUS <> 'RUNNING'; Auswertung mit den Abfragen am Ende dieser Datei
-- =====================================================================
set serveroutput on size unlimited

begin
  begin execute immediate 'drop table lt_diag_sel purge'; exception when others then null; end;
  execute immediate 'create table lt_diag_sel (
      run_id    number,
      variant   varchar2(10),
      param     varchar2(30),
      rep       number,
      burst     varchar2(1),
      i         number,          -- 1..n = NEW_SESSION, 0 = vor dem Burst, 99 = nach dem Burst
      t_ms      number,          -- Zeit seit Burst-Beginn vor NEW_SESSION
      dur_ms    number,          -- Dauer NEW_SESSION
      pipe      varchar2(30),    -- gewaehlter Worker (direkt: GET_SERVER_PIPE, Dispatcher: Route)
      s1_proc   number, s1_cur number, s1_stat varchar2(20), s1_age_ms number,
      s2_proc   number, s2_cur number, s2_stat varchar2(20), s2_age_ms number,
      note      varchar2(400),
      ts        timestamp(6) default systimestamp)';
end;
/

create or replace procedure lt_diag_sel_burst(
    p_run        number,
    p_variant    varchar2,
    p_param      varchar2,
    p_rep        number,
    p_burst      varchar2 default 'A',
    p_disp       number   default 0,    -- 1: ueber den Dispatcher LT_DISP
    p_n          number   default 20,
    p_gap_after  number   default 0,    -- Pause nach Prozess Nr. ...
    p_gap_s      number   default 0,    -- ... in Sekunden
    p_delay_ms   number   default 0,    -- feste Wartezeit je Iteration
    p_close      number   default 1,    -- 0: Prozesse erst nach dem Burst schliessen
    p_snap       number   default 1,    -- Registry-Snapshot vor jeder NEW_SESSION
    p_mimic      number   default 0,    -- 1: wie der Originaltest (2x lt.joblog mit Commit je Iteration)
    p_preload_k  number   default 0)    -- Vorlast: k INFOs auf einen Worker, warten bis dessen PROCESSING > 0
as
    type t_rows is table of lt_diag_sel%rowtype index by pls_integer;
    type t_pids is table of number index by pls_integer;
    l_rows   t_rows;
    l_pids   t_pids;
    l_prefix varchar2(60) := 'LT_' || p_run || '_DS';
    l_t0     timestamp;
    l_tb     timestamp;
    l_pid    number;
    l_pipe   varchar2(30);
    l_note   varchar2(400);
    l_waited number;
    l_p1     number;
    l_p2     number;

    procedure snap(r in out lt_diag_sel%rowtype) is
    begin
        select max(case when pipe_name = 'LT_S1' then processing end),
               max(case when pipe_name = 'LT_S1' then current_processes end),
               max(case when pipe_name = 'LT_S1' then status end),
               max(case when pipe_name = 'LT_S1' then lt.ms_since(last_activity) end),
               max(case when pipe_name = 'LT_S2' then processing end),
               max(case when pipe_name = 'LT_S2' then current_processes end),
               max(case when pipe_name = 'LT_S2' then status end),
               max(case when pipe_name = 'LT_S2' then lt.ms_since(last_activity) end)
          into r.s1_proc, r.s1_cur, r.s1_stat, r.s1_age_ms, r.s2_proc, r.s2_cur, r.s2_stat, r.s2_age_ms
          from lilam_server_registry where pipe_name in ('LT_S1', 'LT_S2');
    end;

    procedure add_row(p_i number, p_t number, p_dur number, p_pipe varchar2, p_snapit boolean, p_note varchar2 default null) is
        r lt_diag_sel%rowtype;
    begin
        r.run_id := p_run; r.variant := p_variant; r.param := p_param; r.rep := p_rep; r.burst := p_burst;
        r.i := p_i; r.t_ms := p_t; r.dur_ms := p_dur; r.pipe := p_pipe; r.note := p_note; r.ts := systimestamp;
        if p_snapit then snap(r); end if;
        l_rows(l_rows.count + 1) := r;
    end;
begin
    -- Vorlast auf einem Worker (direkt), dann warten, bis dessen Housekeeping PROCESSING > 0 schreibt
    if p_preload_k > 0 then
        l_pid := lilam.server_new_session(p_processName => l_prefix || '_PRE', p_groupName => lt.c_group,
                                          p_logLevel => lilam.logLevelInfo);
        l_pipe := lilam.get_server_pipe(l_pid);
        for j in 1 .. p_preload_k loop lilam.info(l_pid, 'preload ' || j); end loop;
        lilam.close_session(l_pid);
        l_waited := 0;
        loop
            select max(case when pipe_name = 'LT_S1' then processing end),
                   max(case when pipe_name = 'LT_S2' then processing end)
              into l_p1, l_p2 from lilam_server_registry where pipe_name in ('LT_S1', 'LT_S2');
            exit when (l_pipe = 'LT_S1' and l_p1 > 0) or (l_pipe = 'LT_S2' and l_p2 > 0) or l_waited >= 3000;
            dbms_session.sleep(0.02); l_waited := l_waited + 20;
        end loop;
        l_note := 'PRE ' || l_pipe || ' k=' || p_preload_k || ' wait_ms=' || l_waited;
    end if;

    if p_disp = 1 then lilam.set_dispatcher_pipe(lt.c_disp_pipe); end if;

    add_row(0, 0, null, null, true, l_note);
    l_t0 := systimestamp;
    for i in 1 .. p_n loop
        <<r_block>>
        declare
            r lt_diag_sel%rowtype;
            l_route varchar2(100);
        begin
            r.run_id := p_run; r.variant := p_variant; r.param := p_param; r.rep := p_rep; r.burst := p_burst; r.i := i; r.ts := systimestamp;
            if p_snap = 1 then snap(r); end if;
            r.t_ms := lt.ms_since(l_t0);
            l_tb := systimestamp;
            l_pid := lilam.server_new_session(p_processName => l_prefix || '_' || p_variant, p_groupName => lt.c_group,
                                              p_logLevel => lilam.logLevelInfo);
            r.dur_ms := lt.ms_since(l_tb);
            if p_disp = 1 then
                begin select pipe_name into l_route from lilam_process_route where process_id = l_pid;
                exception when no_data_found then l_route := '(keine)'; end;
                r.pipe := l_route;
            else
                r.pipe := lilam.get_server_pipe(l_pid);
            end if;
            if p_mimic = 1 then
                lt.joblog(p_run, i, 'PIPE_' || p_burst, lilam.get_server_pipe(l_pid));
                lt.joblog(p_run, i, 'ROUTE_' || p_burst, r.pipe);
            end if;
            l_rows(l_rows.count + 1) := r;
            lilam.info(l_pid, p_variant || ' ' || i);
            if p_close = 1 then
                lilam.close_session(l_pid);
            else
                l_pids(l_pids.count + 1) := l_pid;
            end if;
        end r_block;
        if i = p_gap_after and p_gap_s > 0 then dbms_session.sleep(p_gap_s); end if;
        if p_delay_ms > 0 then dbms_session.sleep(p_delay_ms / 1000); end if;
    end loop;
    add_row(99, lt.ms_since(l_t0), null, null, true);

    for j in 1 .. l_pids.count loop lilam.close_session(l_pids(j)); end loop;

    forall j in 1 .. l_rows.count insert into lt_diag_sel values l_rows(j);
    commit;
exception
    when others then
        lt.joblog(p_run, p_rep, 'ERROR', p_variant || '/' || p_param || ': ' || sqlerrm || ' | ' || dbms_utility.format_error_backtrace);
        forall j in 1 .. l_rows.count insert into lt_diag_sel values l_rows(j);
        commit;
end;
/

create or replace procedure lt_diag_sel_driver(p_run number) as
    l_seq  pls_integer := 0;
    l_ok   boolean;
    c_rest constant number := 2;

    procedure job(p_block varchar2) is
        l_name varchar2(60);
    begin
        l_seq := l_seq + 1;
        l_name := 'LT_CDS_' || p_run || '_' || l_seq;
        lt.run_job(l_name, p_block);
        l_ok := lt.wait_jobs(l_name, 180);
        if not l_ok then lt.joblog(p_run, l_seq, 'ERROR', 'Job ' || l_name || ' nicht beendet'); end if;
    end;

    function call(p_variant varchar2, p_param varchar2, p_rep number, p_args varchar2) return varchar2 is
    begin
        return 'lt_diag_sel_burst(p_run => ' || p_run || ', p_variant => ''' || p_variant || ''', p_param => '''
               || p_param || ''', p_rep => ' || p_rep || case when p_args is not null then ', ' || p_args end || ');';
    end;

    procedure start_servers(p_disp boolean) is
        l_list sys.odcivarchar2list := sys.odcivarchar2list('LT_S1', 'LT_S2');
    begin
        lt.start_server('LT_S1'); lt.start_server('LT_S2');
        if p_disp then lt.start_server(lt.c_disp_pipe, 1); l_list.extend; l_list(3) := lt.c_disp_pipe; end if;
        lt.wait_servers_ready(l_list);
    end;
begin
    lt.stop_all_servers;
    start_servers(true);
    dbms_session.sleep(3);

    -- V4 asymmetrische Vorlast (deterministischer Ausloeser)
    for k in (select column_value v from table(sys.odcinumberlist(0, 5, 50))) loop
        for r in 1 .. 10 loop
            dbms_session.sleep(c_rest);
            job('begin ' || call('V4', 'k=' || k.v, r, 'p_preload_k => ' || k.v) || ' end;');
        end loop;
    end loop;

    -- V1 (direkt) / V2 (Dispatcher): Luecke nach Prozess 5
    for d in 0 .. 1 loop
        for g in (select column_value v from table(sys.odcinumberlist(0, 0.1, 0.3, 0.5, 0.8, 1.5))) loop
            for r in 1 .. 10 loop
                dbms_session.sleep(c_rest);
                job('begin ' || call(case d when 0 then 'V1' else 'V2' end, 'p=' || to_char(g.v, 'FM0.0'), r,
                                     'p_disp => ' || d || ', p_gap_after => 5, p_gap_s => ' || to_char(g.v, 'FM0.0', 'NLS_NUMERIC_CHARACTERS=''.,''')) || ' end;');
            end loop;
        end loop;
    end loop;

    -- V3 Abstand zwischen Burst A (direkt) und Burst B (Dispatcher), eine Session
    for g in (select column_value v from table(sys.odcinumberlist(0.2, 0.4, 0.6, 0.8, 1.0, 1.5, 3.0))) loop
        for r in 1 .. 10 loop
            dbms_session.sleep(c_rest);
            job('begin ' || call('V3', 'pause=' || to_char(g.v, 'FM0.0'), r, 'p_burst => ''A''')
                || ' dbms_session.sleep(' || to_char(g.v, 'FM0.0', 'NLS_NUMERIC_CHARACTERS=''.,''') || '); '
                || call('V3', 'pause=' || to_char(g.v, 'FM0.0'), r, 'p_burst => ''B'', p_disp => 1') || ' end;');
        end loop;
    end loop;

    -- V0 Nachbau des Originaltests (zwei Jobs, joblog wie im Test), mit und ohne Snapshot
    for s in 0 .. 1 loop
        for r in 1 .. 10 loop
            dbms_session.sleep(c_rest);
            job('begin ' || call('V0', 'snap=' || (1 - s), r, 'p_burst => ''A'', p_mimic => 1, p_snap => ' || (1 - s)) || ' end;');
            job('begin ' || call('V0', 'snap=' || (1 - s), r, 'p_burst => ''B'', p_disp => 1, p_mimic => 1, p_snap => ' || (1 - s)) || ' end;');
        end loop;
    end loop;

    -- V5 feste Wartezeit je Iteration
    for d in (select column_value v from table(sys.odcinumberlist(0, 50, 150, 250, 600))) loop
        for r in 1 .. 5 loop
            dbms_session.sleep(c_rest);
            job('begin ' || call('V5', 'd=' || d.v, r, 'p_delay_ms => ' || d.v) || ' end;');
        end loop;
    end loop;

    -- V6 Vorlast k=50, Prozesse bleiben bis zum Ende des Bursts offen
    for r in 1 .. 5 loop
        dbms_session.sleep(c_rest);
        job('begin ' || call('V6', 'k=50 offen', r, 'p_preload_k => 50, p_close => 0') || ' end;');
    end loop;

    -- V7 frisch gestartete Server, Burst x s nach wait_servers_ready
    for x in (select column_value v from table(sys.odcinumberlist(0, 0.3, 1, 3))) loop
        for r in 1 .. 5 loop
            lt.stop_all_servers;
            start_servers(false);
            dbms_session.sleep(x.v);
            job('begin ' || call('V7', 'x=' || to_char(x.v, 'FM0.0'), r, null) || ' end;');
        end loop;
    end loop;

    lt.stop_all_servers;
    lt.end_run(p_run);
exception
    when others then
        lt.joblog(p_run, 0, 'ERROR', 'driver: ' || sqlerrm || ' | ' || dbms_utility.format_error_backtrace);
        lt.stop_all_servers;
        lt.end_run(p_run);
end;
/

show errors procedure lt_diag_sel_burst
show errors procedure lt_diag_sel_driver

declare
  l_run number;
begin
  l_run := lt.begin_run('SERVERAUSWAHL_DIAG', 'SERVER+DISPATCHER', 'V0-V7 laut Plan 2026-10-06');
  lt.run_job('LT_CDIAG_DRV', 'begin lt_diag_sel_driver(' || l_run || '); end;');
  dbms_output.put_line('Diagnose gestartet, run_id=' || l_run);
end;
/

-- =====================================================================
-- Auswertung (nach Ende des Laufs, :run = run_id)
-- =====================================================================
-- Je Wiederholung: Verteilung, laengste Serie, einseitig?
--   with b as (select run_id, variant, param, rep, burst, i, pipe,
--                     row_number() over (partition by run_id, variant, param, rep, burst order by i)
--                   - row_number() over (partition by run_id, variant, param, rep, burst, pipe order by i) grp
--                from lt_diag_sel where run_id = :run and i between 1 and 98)
--   select variant, param, rep, burst,
--          sum(case when pipe = 'LT_S1' then 1 end) s1, sum(case when pipe = 'LT_S2' then 1 end) s2,
--          max(cnt) max_serie
--     from (select b.*, count(*) over (partition by variant, param, rep, burst, pipe, grp) cnt from b)
--    group by variant, param, rep, burst order by 1, 2, 3, 4;
