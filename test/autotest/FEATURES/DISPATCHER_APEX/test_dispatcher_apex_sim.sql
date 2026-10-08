-- =====================================================================
-- LILAM Test: FEATURES / DISPATCHER_APEX
--
-- Simulation APEX/AJAX mit Connection Pool und Dispatcher.
-- Jeder "Request" laeuft als eigener Scheduler-Job, also in einer eigenen Session mit
-- leerem PGA (wie ein Request aus dem ORDS-Pool). Die process_id liegt in LT_SIM_CTX
-- (Ersatz fuer ein APEX Application Item).
--
-- Ablauf (2 Worker LT_S1/LT_S2 + Dispatcher LT_DISP, Gruppe LT):
--   R0      Seitenaufbau: SERVER_NEW_PROCESS ueber den Dispatcher
--   R1/R2   TRACE_START und TRACE_STOP in zwei verschiedenen Requests (1 s Abstand)
--   R3-R8   6 parallele AJAX-Requests (Event, Trace, PROC_STEP_DONE, INFO)
--   RNEG    Request ohne Dispatcher-Konfiguration -> muss still ignoriert werden
--   RLONG   Logtext mit 1.500 Zeichen ueber Dispatcher
--   R9      CLOSE_PROCESS
--   RSTALE  Request mit der veralteten process_id nach CLOSE_PROCESS (mit Dispatcher)
--           -> still ignoriert, ohne Wartezeit, keine weiteren Daten
--
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
--                  job_queue_processes (im CDB-Root) >= 10
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- Hilfsobjekte:    LT_SIM_CTX, LT_SIM_RESULT, LT_SIM_REQUEST (werden bei jedem Lauf neu angelegt)
-- =====================================================================
set serveroutput on size unlimited

begin
  begin execute immediate 'drop table lt_sim_ctx purge';    exception when others then null; end;
  begin execute immediate 'drop table lt_sim_result purge'; exception when others then null; end;
  execute immediate 'create table lt_sim_ctx (ctx_key varchar2(30) primary key, ctx_val number)';
  execute immediate 'create table lt_sim_result (
      step varchar2(20), kind varchar2(20), sid number,
      ts_start timestamp(6), ts_end timestamp(6), pid number, pipe varchar2(100), info varchar2(4000))';
end;
/

create or replace procedure lt_sim_request(
    p_step           varchar2,
    p_kind           varchar2,
    p_use_dispatcher number default 1)
as
    l_run   number;
    l_pid   number;
    l_pipe  varchar2(100);
    l_t0    timestamp(6) := systimestamp;

    procedure rec(p_info varchar2) is
        pragma autonomous_transaction;
    begin
        insert into lt_sim_result(step, kind, sid, ts_start, ts_end, pid, pipe, info)
        values (p_step, p_kind, to_number(sys_context('USERENV','SID')), l_t0, systimestamp, l_pid, l_pipe, p_info);
        commit;
    end;
begin
    select ctx_val into l_run from lt_sim_ctx where ctx_key = 'RUN';
    if p_use_dispatcher = 1 then
        lilam.set_dispatcher_pipe('LT_DISP');            -- in APEX: "Initialization PL/SQL Code"
    end if;

    if p_kind = 'PAGE_LOAD' then
        l_pid := lilam.server_new_process(p_processName => 'LT_' || l_run || '_APEX', p_groupName => 'LT',
                                          p_logLevel => lilam.logLevelDebug);
        merge into lt_sim_ctx c using (select 'PID' k, l_pid v from dual) s
           on (c.ctx_key = s.k)
         when matched then update set c.ctx_val = s.v
         when not matched then insert (ctx_key, ctx_val) values (s.k, s.v);
        commit;
        lilam.info(l_pid, p_step || ': page load');
    else
        select ctx_val into l_pid from lt_sim_ctx where ctx_key = 'PID';
        case p_kind
            when 'TRACE_START' then
                lilam.trace_start(l_pid, 'AJAX_SAVE');
                lilam.info(l_pid, p_step || ': trace_start AJAX_SAVE');
            when 'TRACE_STOP' then
                lilam.trace_stop(l_pid, 'AJAX_SAVE');
                lilam.info(l_pid, p_step || ': trace_stop AJAX_SAVE');
            when 'CLICK' then
                lilam.mark_event(l_pid, 'CLICK', p_step);
                lilam.trace_start(l_pid, 'AJAX_LOAD', p_step);
                dbms_session.sleep(0.1);
                lilam.trace_stop(l_pid, 'AJAX_LOAD', p_step);
                lilam.proc_step_done(l_pid);
                lilam.info(l_pid, p_step || ': click');
            when 'LONGLOG' then
                lilam.info(l_pid, p_step || ': ' || rpad('x', 1500, 'x'));
            when 'CLOSE' then
                lilam.info(l_pid, p_step || ': close');
                lilam.close_process(l_pid, 'closed by ' || p_step, 1);
        end case;
    end if;

    begin
        l_pipe := lilam.get_server_pipe(l_pid);
    exception when others then l_pipe := 'ERR: ' || sqlerrm;
    end;
    rec('OK');
exception
    when others then
        rec('ERROR ' || sqlerrm || ' | ' || dbms_utility.format_error_backtrace);
end;
/

declare
  l_run    number;
  l_pid    number;
  l_cnt    number;
  l_num    number;

  procedure run_req(p_step varchar2, p_kind varchar2, p_disp number default 1) is
  begin
    lt.run_job('LT_CSIM_' || p_step,   -- Praefix LT_C: Client-Job (wird von stop_all_servers nicht als Server behandelt)
      'begin lt_sim_request(''' || p_step || ''', ''' || p_kind || ''', ' || p_disp || '); end;');
  end;

  procedure wait_for(p_steps sys.odcivarchar2list, p_max_sec number default 30) is
    l_c number; l_waited number := 0;
  begin
    loop
      select count(*) into l_c from lt_sim_result where step in (select column_value from table(p_steps));
      exit when l_c = p_steps.count or l_waited >= p_max_sec;
      dbms_session.sleep(0.5); l_waited := l_waited + 0.5;
    end loop;
  end;
begin
  l_run := lt.begin_run('DISPATCHER_APEX', 'DISPATCHER');
  insert into lt_sim_ctx values ('RUN', l_run); commit;

  lt.start_server('LT_S1'); lt.start_server('LT_S2'); lt.start_server('LT_DISP', 1);
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2', 'LT_DISP'));

  run_req('R0', 'PAGE_LOAD');                       wait_for(sys.odcivarchar2list('R0'));
  run_req('R1', 'TRACE_START');                     wait_for(sys.odcivarchar2list('R1'));
  dbms_session.sleep(1);
  run_req('R2', 'TRACE_STOP');                      wait_for(sys.odcivarchar2list('R2'));
  for i in 3 .. 8 loop run_req('R' || i, 'CLICK'); end loop;
  wait_for(sys.odcivarchar2list('R3', 'R4', 'R5', 'R6', 'R7', 'R8'));
  run_req('RNEG', 'CLICK', 0);                      wait_for(sys.odcivarchar2list('RNEG'));
  run_req('RLONG', 'LONGLOG');                      wait_for(sys.odcivarchar2list('RLONG'));
  dbms_session.sleep(2);
  run_req('R9', 'CLOSE');                           wait_for(sys.odcivarchar2list('R9'));
  dbms_session.sleep(2);
  run_req('RSTALE', 'CLICK');                       wait_for(sys.odcivarchar2list('RSTALE'));
  dbms_session.sleep(3);

  -- Auswertung
  select max(pid) into l_pid from lt_sim_result where step = 'R0';

  select count(*) into l_cnt from lt_sim_result where info != 'OK';
  lt.check_that(l_run, 'Alle Requests ohne Exception', l_cnt = 0, l_cnt || ' mit Fehler');

  select count(*) into l_cnt from lt_sim_result;
  lt.check_that(l_run, 'Alle 13 Requests ausgefuehrt', l_cnt = 13, l_cnt);

  lt.check_that(l_run, 'Prozess ueber den Dispatcher angelegt', nvl(l_pid, -1) > 0, 'pid ' || l_pid);

  select count(distinct sid) into l_cnt from lt_sim_result where step in ('R3', 'R4', 'R5', 'R6', 'R7', 'R8');
  lt.check_that(l_run, 'Parallele Requests in mehreren Sessions', l_cnt > 1, l_cnt || ' Sessions');

  select count(*) into l_cnt from lilam_log where process_id = l_pid and info not like 'RNEG%' and info not like 'RSTALE%';
  lt.check_that(l_run, 'Alle Logs angekommen (R0-R9 + RLONG = 11)', l_cnt = 11, l_cnt);

  select count(*) into l_cnt from lilam_log where process_id = l_pid and info like 'RNEG%';
  lt.check_that(l_run, 'Request ohne Dispatcher still ignoriert', l_cnt = 0, l_cnt);

  select count(*) into l_cnt from lilam_log where process_id = l_pid and info like 'RLONG%' and length(info) > 1500;
  lt.check_that(l_run, 'Langer Logtext (1.500 Zeichen) vollstaendig', l_cnt = 1, l_cnt);

  select max(used_millis) into l_num from lilam_mon where process_id = l_pid and action = 'AJAX_SAVE';
  lt.check_that(l_run, 'Trace ueber zwei Requests gepaart (>= 1000 ms)', nvl(l_num, 0) >= 1000, l_num || ' ms');

  select count(*) into l_cnt from lilam_mon where process_id = l_pid and action = 'CLICK';
  lt.check_that(l_run, '6 Events aus parallelen Requests', l_cnt = 6, l_cnt);

  select count(*) into l_cnt from lilam_mon where process_id = l_pid and action = 'AJAX_LOAD';
  lt.check_that(l_run, '6 Traces aus parallelen Requests', l_cnt = 6, l_cnt);

  select steps_done into l_num from lilam_proc where id = l_pid;
  lt.check_that(l_run, 'steps_done = 6', l_num = 6, l_num);

  select count(*) into l_cnt from lilam_proc where id = l_pid and process_end is not null;
  lt.check_that(l_run, 'Prozess geschlossen', l_cnt = 1, l_cnt);

  select count(*) into l_cnt from lilam_process_route where process_id = l_pid;
  lt.check_that(l_run, 'Route nach CLOSE entfernt', l_cnt = 0, l_cnt);

  -- veraltete process_id nach CLOSE_PROCESS
  select count(*) into l_cnt from lilam_log where process_id = l_pid and info like 'RSTALE%';
  lt.check_that(l_run, 'Veraltete ID nach CLOSE: keine weiteren Daten', l_cnt = 0, l_cnt);
  select round(extract(second from (ts_end - ts_start)) * 1000 + extract(minute from (ts_end - ts_start)) * 60000)
    into l_num from lt_sim_result where step = 'RSTALE';
  lt.check_that(l_run, 'Veraltete ID nach CLOSE: Request ohne Wartezeit (< 1.000 ms inkl. 100 ms Pause)', l_num < 1000, l_num || ' ms');
  lt.metric(l_run, 'stale_request_ms', l_num, 'ms');

  lt.stop_all_servers;

  select count(*) into l_cnt from lilam_server_registry
   where pipe_name in ('LT_S1', 'LT_S2', 'LT_DISP') and is_active = 1;
  lt.check_that(l_run, 'Alle Server inkl. Dispatcher gestoppt', l_cnt = 0, l_cnt || ' noch aktiv');

  lt.check_that(l_run, 'Keine internen LILAM-Fehler', lt.internal_errors_since(lt.run_started(l_run)) = 0,
                lt.internal_errors_since(lt.run_started(l_run)));
  lt.end_run(l_run);
exception
  when others then
    dbms_output.put_line('ABBRUCH: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
    lt.stop_all_servers;
    raise;
end;
/
