-- =====================================================================
-- LILAM Diagnose: SERVER_NEW_PROCESS-Ausfall aus run 2034 (U-Bahn-Simulation nach SPEICHER)
--
-- Befund run 2034: In derselben Session lief direkt davor FEATURES/SPEICHER. Der frisch gestartete
-- Server UB_S1 (Gruppe SUBWAY) beantwortete kein SERVER_NEW_PROCESS (4 x -20110 nach je 3 s).
-- Ursache (run 2040): lt.t_speicher setzte zuletzt lilam.set_dispatcher_pipe('LT_DISP') fuer die eigene
-- Session und stoppte LT_DISP danach. getServerPipeForSession nahm bei gesetztem DEFAULT_DISPATCHER immer
-- den Dispatcher, auch fuer eine andere Gruppe; set_dispatcher_pipe(NULL) hob die Einstellung nicht auf;
-- p_groupName von SET_DISPATCHER_PIPE wurde nie gelesen.
--
-- Erwartungen nach der Korrektur (getDispatcherForGroup, SET_DISPATCHER_PIPE(NULL)); in Klammern das
-- Ergebnis vor der Korrektur (run 2040):
--   V1 Kontrolle: neuer Server LT_DGS (Gruppe LT_DGY), sofort SERVER_NEW_PROCESS ohne Dispatcher: Erfolg
--   V2 set_dispatcher_pipe('LT_DISP') (gestoppt, Gruppe LT): SERVER_NEW_PROCESS Gruppe LT_DGY geht an
--      LT_DGS (vorher: -20110 nach 3 s, Anfrage in LT_DISP_CTL)
--   V2b dieselbe Session, Gruppe LT (Gruppe des Dispatchers): weiter ueber LT_DISP, also -20110, weil er
--      gestoppt ist; die Anfrage liegt in LT_DISP_CTL
--   V5 set_dispatcher_pipe(NULL) hebt die Einstellung auf: Gruppe LT_DGY erreicht LT_DGS (vorher: -20003)
--   V3 nach Package-Reset: LT_DGS sofort erreichbar (unveraendert)
--   V4 laufender Dispatcher LT_DGD der Gruppe LT_DGX mit Worker LT_DGW: SERVER_NEW_PROCESS Gruppe LT_DGY
--      landet bei LT_DGS (vorher: bei LT_DGW, fremde Gruppe)
--   V4b dieselbe Session, Gruppe LT_DGX: ueber LT_DGD bei LT_DGW (unveraendert)
--   V6 set_dispatcher_pipe('LT_DGD', p_groupName => 'LT_DGX'), Gruppe LT_DGX: ueber LT_DGD bei LT_DGW
--      (vorher: direkt an LT_DGW, gruppenbezogene Einstellung wirkungslos)
-- Ergebnisse in LT_RUN / LT_CHECK / LT_METRIC (Test NEW_SESSION_DIAG). Benoetigt die Testbasis (Package LT).
-- Legt an: Server LT_DGS, LT_DGD, LT_DGW (werden am Ende gestoppt, Registry-Eintraege geloescht).
-- =====================================================================
set serveroutput on size unlimited
variable run number
variable t0 varchar2(40)

-- Start: Run anlegen, Server LT_DGS (Gruppe LT_DGY)
begin
    :run := lt.begin_run('NEW_SESSION_DIAG', 'SERVER+DISPATCHER', 'Dispatcher-Einstellung der Session, nach Korrektur');
    :t0  := to_char(systimestamp, 'YYYY-MM-DD HH24:MI:SS.FF6');
    dbms_pipe.purge('LT_DISP_CTL');
    dbms_output.put_line('    ' || lilam.create_server('LT_DGS', 'LT_DGY', lt.c_pw, 0));
    lt.wait_servers_ready(sys.odcivarchar2list('LT_DGS'));
end;
/

-- V1 Kontrolle
declare
    l_cs  number := dbms_utility.get_time;
    l_pid number;
    l_pipe varchar2(100);
begin
    l_pid := lilam.server_new_process(p_processName => 'LT_' || :run || '_V1', p_groupName => 'LT_DGY');
    lt.metric(:run, 'v1_new_session_ms', (dbms_utility.get_time - l_cs) * 10, 'ms');
    if l_pid > 0 then
        l_pipe := lilam.get_server_pipe(l_pid);
        lilam.close_process(l_pid);
    end if;
    lt.check_that(:run, 'V1 ohne Dispatcher: frischer Server LT_DGS antwortet sofort', l_pid > 0 and l_pipe = 'LT_DGS',
                  'pid ' || l_pid || ', Server ' || l_pipe || ', ' || (dbms_utility.get_time - l_cs) * 10 || ' ms');
end;
/

-- V2 wie run 2034, V2b eigene Gruppe des Dispatchers
declare
    l_cs   number;
    l_pid  number;
    l_ms   number;
    l_pipe varchar2(100);
    l_disp number := 0;
    l_msg  varchar2(4000);
begin
    lilam.set_dispatcher_pipe('LT_DISP');   -- wie lt.t_speicher vor der Korrektur (LT_DISP laeuft nicht)
    l_cs  := dbms_utility.get_time;
    l_pid := lilam.server_new_process(p_processName => 'LT_' || :run || '_V2', p_groupName => 'LT_DGY');
    l_ms  := (dbms_utility.get_time - l_cs) * 10;
    lt.metric(:run, 'v2_new_session_ms', l_ms, 'ms');
    if l_pid > 0 then
        l_pipe := lilam.get_server_pipe(l_pid);
        lilam.close_process(l_pid);
    end if;
    lt.check_that(:run, 'V2 Dispatcher LT_DISP (Gruppe LT), Gruppe LT_DGY: direkt an LT_DGS', l_pid > 0 and l_pipe = 'LT_DGS',
                  'pid ' || l_pid || ', Server ' || l_pipe || ', ' || l_ms || ' ms');

    l_cs  := dbms_utility.get_time;
    l_pid := lilam.server_new_process(p_processName => 'LT_' || :run || '_V2B', p_groupName => 'LT');
    l_ms  := (dbms_utility.get_time - l_cs) * 10;
    lt.metric(:run, 'v2b_new_session_ms', l_ms, 'ms');
    loop
        exit when dbms_pipe.receive_message('LT_DISP_CTL', timeout => 0) != 0;
        l_disp := l_disp + 1;
        dbms_pipe.unpack_message(l_msg);
        dbms_output.put_line('    LT_DISP_CTL: ' || substr(l_msg, 1, 200));
    end loop;
    dbms_pipe.purge('LT_DISP');
    lt.check_that(:run, 'V2b eigene Gruppe LT: weiter ueber LT_DISP (gestoppt: -20110, Anfrage in LT_DISP_CTL)',
                  l_pid = lilam.NUM_ERR_PROCESS_TIMEOUT and l_disp = 1,
                  'pid ' || l_pid || ' nach ' || l_ms || ' ms, Nachrichten in LT_DISP_CTL: ' || l_disp);
end;
/

-- V5 Aufheben per NULL
declare
    l_cs   number := dbms_utility.get_time;
    l_pid  number;
    l_pipe varchar2(100);
begin
    lilam.set_dispatcher_pipe(null);
    l_pid := lilam.server_new_process(p_processName => 'LT_' || :run || '_V5', p_groupName => 'LT_DGY');
    if l_pid > 0 then
        l_pipe := lilam.get_server_pipe(l_pid);
        lilam.close_process(l_pid);
    end if;
    lt.check_that(:run, 'V5 set_dispatcher_pipe(NULL) hebt die Einstellung auf: LT_DGS erreichbar', l_pid > 0 and l_pipe = 'LT_DGS',
                  'pid ' || l_pid || ', Server ' || l_pipe || ', ' || (dbms_utility.get_time - l_cs) * 10 || ' ms');
end;
/

-- Package-Zustand der Session zuruecksetzen (wirkt nach Ende des Aufrufs)
exec dbms_session.modify_package_state(dbms_session.reinitialize)
set serveroutput on size unlimited

-- V3 nach Reset
declare
    l_cs  number := dbms_utility.get_time;
    l_pid number;
    l_pipe varchar2(100);
begin
    l_pid := lilam.server_new_process(p_processName => 'LT_' || :run || '_V3', p_groupName => 'LT_DGY');
    lt.metric(:run, 'v3_new_session_ms', (dbms_utility.get_time - l_cs) * 10, 'ms');
    if l_pid > 0 then
        l_pipe := lilam.get_server_pipe(l_pid);
        lilam.close_process(l_pid);
    end if;
    lt.check_that(:run, 'V3 nach Package-Reset: LT_DGS sofort erreichbar', l_pid > 0 and l_pipe = 'LT_DGS',
                  'pid ' || l_pid || ', Server ' || l_pipe || ', ' || (dbms_utility.get_time - l_cs) * 10 || ' ms');
end;
/

-- V4 laufender Dispatcher einer anderen Gruppe
begin
    dbms_output.put_line('    ' || lilam.create_server('LT_DGW', 'LT_DGX', lt.c_pw, 0));
    dbms_output.put_line('    ' || lilam.create_server('LT_DGD', 'LT_DGX', lt.c_pw, 1));
    lt.wait_servers_ready(sys.odcivarchar2list('LT_DGW', 'LT_DGD'));
end;
/
declare
    -- Server, der den Prozess tatsaechlich fuehrt (LILAM_PROC.SERVER_PIPE, nach CLOSE_PROCESS geschrieben)
    function owner_of(p_pid number) return varchar2 is
        l_srv varchar2(100);
    begin
        for i in 1 .. 20 loop
            select max(server_pipe) into l_srv from lilam_proc where id = p_pid and process_end is not null;
            exit when l_srv is not null;
            dbms_session.sleep(0.25);
        end loop;
        return l_srv;
    end;
    procedure probe(p_check varchar2, p_group varchar2, p_client varchar2, p_owner varchar2) is
        l_pid  number;
        l_pipe varchar2(100);
        l_srv  varchar2(100);
    begin
        l_pid := lilam.server_new_process(p_processName => 'LT_' || :run || '_' || substr(p_check, 1, 3), p_groupName => p_group);
        if l_pid > 0 then
            l_pipe := lilam.get_server_pipe(l_pid);
            lilam.info(l_pid, p_check);
            lilam.close_process(l_pid);
            l_srv := owner_of(l_pid);
        end if;
        lt.check_that(:run, p_check, l_pid > 0 and l_pipe = p_client and l_srv = p_owner,
                      'pid ' || l_pid || ', Client sendet an ' || nvl(l_pipe, '-') || ', LILAM_PROC.SERVER_PIPE ' || nvl(l_srv, '-'));
    end;
begin
    lilam.set_dispatcher_pipe('LT_DGD');
    probe('V4 Dispatcher LT_DGD (Gruppe LT_DGX), Gruppe LT_DGY: direkt bei LT_DGS', 'LT_DGY', 'LT_DGS', 'LT_DGS');
    probe('V4b Gruppe LT_DGX: ueber LT_DGD bei LT_DGW', 'LT_DGX', 'LT_DGD', 'LT_DGW');
end;
/

exec dbms_session.modify_package_state(dbms_session.reinitialize)
set serveroutput on size unlimited

-- V6 Dispatcher nur fuer Gruppe LT_DGX gesetzt
declare
    l_pid  number;
    l_pipe varchar2(100);
    l_srv  varchar2(100);
    l_pid2 number;
    l_pipe2 varchar2(100);
begin
    lilam.set_dispatcher_pipe('LT_DGD', p_groupName => 'LT_DGX');
    l_pid := lilam.server_new_process(p_processName => 'LT_' || :run || '_V6', p_groupName => 'LT_DGX');
    if l_pid > 0 then
        l_pipe := lilam.get_server_pipe(l_pid);
        lilam.close_process(l_pid);
        for i in 1 .. 20 loop
            select max(server_pipe) into l_srv from lilam_proc where id = l_pid and process_end is not null;
            exit when l_srv is not null;
            dbms_session.sleep(0.25);
        end loop;
    end if;
    -- andere Gruppe in derselben Session: kein Dispatcher
    l_pid2 := lilam.server_new_process(p_processName => 'LT_' || :run || '_V6B', p_groupName => 'LT_DGY');
    if l_pid2 > 0 then
        l_pipe2 := lilam.get_server_pipe(l_pid2);
        lilam.close_process(l_pid2);
    end if;
    lt.check_that(:run, 'V6 set_dispatcher_pipe mit p_groupName LT_DGX: Gruppe LT_DGX ueber LT_DGD bei LT_DGW',
                  l_pid > 0 and l_pipe = 'LT_DGD' and l_srv = 'LT_DGW',
                  'pid ' || l_pid || ', Client sendet an ' || l_pipe || ', LILAM_PROC.SERVER_PIPE ' || nvl(l_srv, '-'));
    lt.check_that(:run, 'V6b dieselbe Session, Gruppe LT_DGY: direkt bei LT_DGS', l_pid2 > 0 and l_pipe2 = 'LT_DGS',
                  'pid ' || l_pid2 || ', Server ' || l_pipe2);
end;
/

exec dbms_session.modify_package_state(dbms_session.reinitialize)
set serveroutput on size unlimited

-- Aufraeumen und Abschluss
declare
    l_ok boolean;
    l_n  number;
begin
    l_ok := lt.stop_server('LT_DGD');
    l_ok := lt.stop_server('LT_DGW');
    l_ok := lt.stop_server('LT_DGS');
    delete from lilam_server_registry where pipe_name in ('LT_DGS', 'LT_DGW', 'LT_DGD') and is_active = 0;
    commit;
    -- erwartet: genau ein Eintrag -20110 aus V2b, sonst nichts
    for r in (select error_code, module_name, count(*) n from lilam_log_internal
               where log_timestamp >= to_timestamp(:t0, 'YYYY-MM-DD HH24:MI:SS.FF6')
               group by error_code, module_name order by 1) loop
        dbms_output.put_line('    LILAM_LOG_INTERNAL: ' || r.error_code || ' ' || r.module_name || ' x' || r.n);
    end loop;
    select count(*) into l_n from lilam_log_internal where log_timestamp >= to_timestamp(:t0, 'YYYY-MM-DD HH24:MI:SS.FF6');
    lt.check_that(:run, 'Interne Fehler: nur der erwartete Timeout aus V2b', l_n = 1, l_n || ' Eintraege');
    lt.end_run(:run);
end;
/
