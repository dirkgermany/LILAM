-- =====================================================================
-- LILAM Diagnose: WAKEUP DISPATCHER - wann wird ein INFO nach einer Ruhephase sichtbar?
--
-- Je Wiederholung: Prozess ueber den Dispatcher anlegen (Job = frische Session), p_idle Sekunden Ruhe,
-- dann aus einer neuen Session ein INFO an den Prozess (Reconnect ueber den Dispatcher).
-- Die steuernde Session fragt alle 20 ms ab, wann die Zeile in LILAM_LOG steht, und zeichnet den
-- Registry-Stand des zustaendigen Workers auf (RATE_TS = Zeitpunkt des letzten Housekeepings).
-- Nutzt nur die bestehende API. Eigene Objekte: Tabelle LT_DIAG_WK.
-- =====================================================================
set serveroutput on size unlimited

begin
  begin execute immediate 'drop table lt_diag_wk purge'; exception when others then null; end;
  execute immediate 'create table lt_diag_wk (
      run_id   number, rep number, idle_s number,
      t_ms     number,          -- Zeit seit dem Ende des INFO-Aufrufs im Client
      worker   varchar2(30),
      w_rate_ts timestamp(3), w_last_activity timestamp(3), w_status varchar2(20), w_proc number,
      found    number,          -- 1 = INFO steht in LILAM_LOG
      note     varchar2(400),
      ts       timestamp(6) default systimestamp)';
end;
/

declare
  l_run    number;
  l_pid    number;
  l_sent   timestamp;
  l_worker varchar2(30);
  l_found  number;
  l_t      number;
  l_ok     boolean;
  r        lt_diag_wk%rowtype;
  c_reps   constant pls_integer := 5;

  function job_pid(p_run number, p_rep number) return number is
    l_v number;
  begin
    select max(value) into l_v from lt_metric where run_id = p_run and metric = 'wk_pid_' || p_rep;
    return l_v;
  end;
begin
  l_run := lt.begin_run('WAKEUP_DISPATCHER_DIAG', 'DISPATCHER', 'idle 5 s, 5 Wiederholungen');
  lt.stop_all_servers;
  lt.start_server('LT_S1'); lt.start_server('LT_S2'); lt.start_server(lt.c_disp_pipe, 1);
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2', lt.c_disp_pipe));
  dbms_session.sleep(2);

  for rep in 1 .. c_reps loop
    -- Prozess anlegen (frische Session, ueber den Dispatcher)
    lt.run_job('LT_CWK_' || l_run || '_A' || rep,
      'declare l_pid number; begin lilam.set_dispatcher_pipe(''' || lt.c_disp_pipe || '''); '
      || 'l_pid := lilam.server_new_session(p_processName => ''LT_' || l_run || '_WK'', p_groupName => ''' || lt.c_group || ''', '
      || 'p_logLevel => lilam.logLevelInfo); lilam.info(l_pid, ''start''); '
      || 'lt.metric(' || l_run || ', ''wk_pid_' || rep || ''', l_pid); end;');
    l_ok := lt.wait_jobs('LT_CWK_' || l_run || '_A' || rep, 60);
    l_pid := job_pid(l_run, rep);
    select max(pipe_name) into l_worker from lilam_process_route where process_id = l_pid;

    dbms_session.sleep(5);

    -- INFO aus einer neuen Session; der Client schreibt den Zeitpunkt nach dem Aufruf in LT_JOBLOG
    lt.run_job('LT_CWK_' || l_run || '_B' || rep,
      'begin lilam.set_dispatcher_pipe(''' || lt.c_disp_pipe || '''); '
      || 'lilam.info(' || l_pid || ', ''wake ' || rep || '''); '
      || 'lt.joblog(' || l_run || ', ' || rep || ', ''SENT'', ''' || l_pid || '''); end;');

    -- Warten, bis der Client gesendet hat
    l_sent := null;
    for k in 1 .. 500 loop
      select max(ts) into l_sent from lt_joblog where run_id = l_run and client_no = rep and phase = 'SENT';
      exit when l_sent is not null;
      dbms_session.sleep(0.01);
    end loop;

    -- Ab jetzt alle 20 ms: INFO sichtbar? Registry des Workers?
    for k in 1 .. 300 loop
      r := null;
      r.run_id := l_run; r.rep := rep; r.idle_s := 5; r.worker := l_worker; r.ts := systimestamp;
      r.t_ms := lt.ms_since(l_sent);
      select count(*) into r.found from lilam_log where process_id = l_pid and info = 'wake ' || rep;
      select max(rate_ts), max(last_activity), max(status), max(processing)
        into r.w_rate_ts, r.w_last_activity, r.w_status, r.w_proc
        from lilam_server_registry where pipe_name = l_worker;
      insert into lt_diag_wk values r;
      commit;
      exit when r.found > 0 and k > 1;
      dbms_session.sleep(0.02);
    end loop;

    l_ok := lt.wait_jobs('LT_CWK_' || l_run || '_B' || rep, 30);
    lt.run_job('LT_CWK_' || l_run || '_C' || rep,
      'begin lilam.set_dispatcher_pipe(''' || lt.c_disp_pipe || '''); lilam.close_session(' || l_pid || '); end;');
    l_ok := lt.wait_jobs('LT_CWK_' || l_run || '_C' || rep, 30);
    dbms_session.sleep(2);
  end loop;

  lt.stop_all_servers;
  lt.end_run(l_run);
  dbms_output.put_line('run_id=' || l_run);
exception
  when others then
    dbms_output.put_line('ABBRUCH: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
    lt.stop_all_servers;
    raise;
end;
/

-- Auswertung: je Wiederholung Zeitpunkt der Sichtbarkeit und Housekeeping-Zeitpunkte des Workers
--   select rep, min(case when found > 0 then t_ms end) sichtbar_ms,
--          listagg(distinct to_char(w_rate_ts, 'hh24:mi:ss.ff3'), ' ') within group (order by to_char(w_rate_ts, 'hh24:mi:ss.ff3')) hk
--     from lt_diag_wk where run_id = :run group by rep order by rep;
