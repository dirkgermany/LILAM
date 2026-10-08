-- =====================================================================
-- LILAM Test: FEATURES / SERVERAUSWAHL
--
-- Worker und Dispatcher laufen in derselben Gruppe. Ein Dispatcher ist in der Registry
-- gekennzeichnet (IS_DISPATCHER = 1) und darf nie als Ziel der Serverauswahl gewaehlt werden.
--
--   S1  Registry: LT_DISP ist als Dispatcher gekennzeichnet, LT_S1/LT_S2 nicht
--   S2  Client A ohne Dispatcher-Einstellung: 20 Prozesse, GET_SERVER_PIPE nie LT_DISP
--   S3  Client A: Last verteilt, jeder Worker erhaelt mindestens 30 % der Prozesse
--   S4  Client B mit Dispatcher: 20 Prozesse, Client sendet an LT_DISP
--   S5  Client B: jeder Prozess liegt auf einem Worker (Route nie LT_DISP), jeder Worker mind. 30 %
--   S6  alle 40 Prozesse geschlossen, keine Routen uebrig, keine Fehler
--
-- Jeder Client laeuft als eigener Job (frische Session).
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- =====================================================================
set serveroutput on size unlimited

declare
  c_procs  constant pls_integer := 20;
  l_run    number;
  l_prefix varchar2(60);
  l_n      number;
  l_ok     boolean;

  function client_block(p_tag varchar2, p_dispatcher boolean) return varchar2 is
  begin
    return 'declare l_pid number; l_route varchar2(100); begin '
      || case when p_dispatcher then 'lilam.set_dispatcher_pipe(''' || lt.c_disp_pipe || '''); ' end
      || 'for i in 1 .. ' || c_procs || ' loop '
      || '  l_pid := lilam.server_new_process(p_processName => ''' || l_prefix || '_' || p_tag || ''', '
      || '                                    p_groupName => ''' || lt.c_group || ''', p_logLevel => lilam.logLevelInfo); '
      || '  lt.joblog(' || l_run || ', i, ''PIPE_' || p_tag || ''', lilam.get_server_pipe(l_pid)); '
      || '  begin select pipe_name into l_route from lilam_process_route where process_id = l_pid; '
      || '  exception when no_data_found then l_route := ''(keine)''; end; '
      || '  lt.joblog(' || l_run || ', i, ''ROUTE_' || p_tag || ''', l_route); '
      || '  lilam.info(l_pid, ''' || p_tag || ' '' || i); '
      || '  lilam.close_process(l_pid); '
      || 'end loop; '
      || 'exception when others then lt.joblog(' || l_run || ', 0, ''ERROR'', sqlerrm || '' | '' || dbms_utility.format_error_backtrace); '
      || 'end;';
  end;

  function cnt(p_phase varchar2, p_cond varchar2) return number is
    l_c number;
  begin
    execute immediate 'select count(*) from lt_joblog where run_id = :1 and phase = :2 and ' || p_cond
      into l_c using l_run, p_phase;
    return l_c;
  end;

  function dist(p_phase varchar2) return varchar2 is
    l_d varchar2(400);
  begin
    select listagg(info || '=' || n, ', ') within group (order by info) into l_d
      from (select info, count(*) n from lt_joblog where run_id = l_run and phase = p_phase group by info);
    return l_d;
  end;
begin
  l_run := lt.begin_run('SERVERAUSWAHL', 'SERVER+DISPATCHER', 'processes=' || c_procs || ' je Client');
  l_prefix := 'LT_' || l_run || '_SEL';
  lt.start_server('LT_S1'); lt.start_server('LT_S2'); lt.start_server(lt.c_disp_pipe, 1);
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2', lt.c_disp_pipe));

  -- S1: Kennzeichnung in der Registry
  execute immediate 'select count(*) from lilam_server_registry
                      where (pipe_name = :1 and is_dispatcher = 1) or (pipe_name in (''LT_S1'', ''LT_S2'') and nvl(is_dispatcher, 0) = 0)'
    into l_n using lt.c_disp_pipe;
  lt.check_that(l_run, 'S1 Registry: LT_DISP als Dispatcher, LT_S1/LT_S2 als Worker gekennzeichnet', l_n = 3, l_n || '/3');

  -- Client A ohne, danach Client B mit Dispatcher-Einstellung
  lt.run_job('LT_C' || l_run || '_A', client_block('A', false));
  l_ok := lt.wait_jobs('LT_C' || l_run || '_A', 120);
  lt.run_job('LT_C' || l_run || '_B', client_block('B', true));
  l_ok := lt.wait_jobs('LT_C' || l_run || '_B', 120);

  -- S2/S3: Client A
  l_n := cnt('PIPE_A', 'info = ''' || lt.c_disp_pipe || '''');
  lt.check_that(l_run, 'S2 Client ohne Dispatcher: nie LT_DISP als Server', l_n = 0 and cnt('PIPE_A', '1=1') = c_procs,
                dist('PIPE_A'));
  l_n := least(cnt('PIPE_A', 'info = ''LT_S1'''), cnt('PIPE_A', 'info = ''LT_S2'''));
  lt.check_that(l_run, 'S3 Client ohne Dispatcher: jeder Worker mind. 30 %', l_n >= 0.3 * c_procs, dist('PIPE_A'));

  -- S4/S5: Client B
  l_n := cnt('PIPE_B', 'info = ''' || lt.c_disp_pipe || '''');
  lt.check_that(l_run, 'S4 Client mit Dispatcher sendet an LT_DISP', l_n = c_procs, dist('PIPE_B'));
  l_n := cnt('ROUTE_B', 'info in (''LT_S1'', ''LT_S2'')');
  lt.check_that(l_run, 'S5 Client mit Dispatcher: jeder Prozess auf einem Worker', l_n = c_procs, dist('ROUTE_B'));
  l_n := least(cnt('ROUTE_B', 'info = ''LT_S1'''), cnt('ROUTE_B', 'info = ''LT_S2'''));
  lt.check_that(l_run, 'S5 Client mit Dispatcher: jeder Worker mind. 30 %', l_n >= 0.3 * c_procs, dist('ROUTE_B'));

  -- S6: Abschluss
  l_n := lt.wait_count(l_prefix, 'PROC_CLOSED', 2 * c_procs, 30);
  l_n := lt.count_lilam(l_prefix, 'PROC_CLOSED');
  lt.check_that(l_run, 'S6 Alle Prozesse geschlossen', l_n = 2 * c_procs, l_n || '/' || (2 * c_procs));
  l_n := lt.wait_count(l_prefix, 'LOG', 2 * c_procs, 30);
  l_n := lt.count_lilam(l_prefix, 'LOG');
  lt.check_that(l_run, 'S6 Alle Logs angekommen', l_n = 2 * c_procs, l_n || '/' || (2 * c_procs));
  l_n := lt.count_lilam(l_prefix, 'ROUTES');
  lt.check_that(l_run, 'S6 Keine Prozess-Routen uebrig', l_n = 0, 'ist ' || l_n);
  select count(*) into l_n from lt_joblog where run_id = l_run and phase = 'ERROR';
  lt.check_that(l_run, 'S6 Keine Fehler in den Client-Jobs', l_n = 0, l_n || ' Fehler');
  l_n := lt.internal_errors_since(lt.run_started(l_run));
  lt.check_that(l_run, 'S6 Keine internen LILAM-Fehler', l_n = 0, l_n || ' Eintraege');

  lt.stop_all_servers;
  lt.end_run(l_run);
exception
  when others then
    dbms_output.put_line('ABBRUCH: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
    lt.stop_all_servers;
    raise;
end;
/
