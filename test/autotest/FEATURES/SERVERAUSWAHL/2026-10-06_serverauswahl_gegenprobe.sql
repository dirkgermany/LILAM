-- =====================================================================
-- LILAM Diagnose: SERVERAUSWAHL - Gegenprobe nach der Korrektur
--
-- Wiederholt die Zellen, die in run 1881 (vor der Korrektur) zu 100 % einseitig waren:
--   V1 / V2  Luecke nach Prozess 5: p = 0,5 / 0,8 / 1,5 s (direkt / ueber den Dispatcher)
--   V3       Burst A direkt, 1,5 s Pause, Burst B ueber den Dispatcher
--   V7       frisch gestartete Server, Burst 1 s nach wait_servers_ready
-- Je Zelle 10 Wiederholungen (V7: 5). Ziel: keine einseitigen Bursts.
--
-- Voraussetzung: 2026-10-06_serverauswahl_provokation.sql wurde einmal ausgefuehrt
-- (Tabelle LT_DIAG_SEL und Prozedur lt_diag_sel_burst existieren).
-- Start: dieses Skript; es kehrt sofort zurueck (Job LT_CDIAG_CHK, Test SERVERAUSWAHL_GEGENPROBE).
-- =====================================================================
set serveroutput on size unlimited

create or replace procedure lt_diag_sel_check(p_run number) as
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

    for d in 0 .. 1 loop
        for g in (select column_value v from table(sys.odcinumberlist(0.5, 0.8, 1.5))) loop
            for r in 1 .. 10 loop
                dbms_session.sleep(c_rest);
                job('begin ' || call(case d when 0 then 'V1' else 'V2' end, 'p=' || to_char(g.v, 'FM0.0'), r,
                                     'p_disp => ' || d || ', p_gap_after => 5, p_gap_s => ' || to_char(g.v, 'FM0.0', 'NLS_NUMERIC_CHARACTERS=''.,''')) || ' end;');
            end loop;
        end loop;
    end loop;

    for r in 1 .. 10 loop
        dbms_session.sleep(c_rest);
        job('begin ' || call('V3', 'pause=1.5', r, 'p_burst => ''A''') || ' dbms_session.sleep(1.5); '
            || call('V3', 'pause=1.5', r, 'p_burst => ''B'', p_disp => 1') || ' end;');
    end loop;

    for r in 1 .. 5 loop
        lt.stop_all_servers;
        start_servers(false);
        dbms_session.sleep(1);
        job('begin ' || call('V7', 'x=1.0', r, null) || ' end;');
    end loop;

    lt.stop_all_servers;
    lt.end_run(p_run);
exception
    when others then
        lt.joblog(p_run, 0, 'ERROR', 'check: ' || sqlerrm || ' | ' || dbms_utility.format_error_backtrace);
        lt.stop_all_servers;
        lt.end_run(p_run);
end;
/

show errors procedure lt_diag_sel_check

declare
  l_run number;
begin
  l_run := lt.begin_run('SERVERAUSWAHL_GEGENPROBE', 'SERVER+DISPATCHER', 'Zellen V1/V2 p=0,5/0,8/1,5, V3 1,5 s, V7 x=1 (Vergleich run 1881)');
  lt.run_job('LT_CDIAG_CHK', 'begin lt_diag_sel_check(' || l_run || '); end;');
  dbms_output.put_line('Gegenprobe gestartet, run_id=' || l_run);
end;
/
