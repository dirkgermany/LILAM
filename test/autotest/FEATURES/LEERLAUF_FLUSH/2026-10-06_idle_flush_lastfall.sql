-- =====================================================================
-- LILAM Diagnose: Leerlauf-Flush - ungünstigster Fall fuer synchrone Aufrufe
--
-- Ein Worker (LT_S1) und der Dispatcher (LT_DISP). Client A schickt waehrend der Lastphase alle 210 ms
-- ein INFO, sodass der Leerlauf-Flush des Workers laufend greift. Client B misst in frischen Sessions
-- (je ein Job) die Dauer von Reconnect + INFO, NEW_PROCESS und CLOSE_PROCESS ueber den Dispatcher sowie
-- die Sichtbarkeit seines INFO in LILAM_LOG. Je 20 Messungen ohne Last und mit Last.
-- Nutzt nur die bestehende API (lilam.*, lt.*). Ergebnisse in LT_METRIC (Messwerte mit _noload/_load).
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run  number;
  l_pid  number;
  l_ok   boolean;
  c_n    constant pls_integer := 20;

  procedure measure(p_tag varchar2) is
  begin
    for i in 1 .. c_n loop
      lt.run_job('LT_CIF_' || l_run || '_' || p_tag || '_' || i,
        'declare l_t timestamp; l_new number; l_n number := 0; begin '
        || 'lilam.set_dispatcher_pipe(''' || lt.c_disp_pipe || '''); '
        -- Reconnect + INFO an den bestehenden Prozess (frische Session)
        || 'l_t := systimestamp; lilam.info(' || l_pid || ', ''' || p_tag || ' ' || i || '''); '
        || 'lt.metric(' || l_run || ', ''rc_ms_' || p_tag || ''', lt.ms_since(l_t), ''ms''); '
        -- Sichtbarkeit dieses INFO
        || 'l_t := systimestamp; loop select count(*) into l_n from lilam_log where process_id = ' || l_pid
        || ' and info = ''' || p_tag || ' ' || i || '''; exit when l_n > 0 or lt.ms_since(l_t) > 10000; dbms_session.sleep(0.01); end loop; '
        || 'lt.metric(' || l_run || ', ''vis_ms_' || p_tag || ''', case when l_n > 0 then lt.ms_since(l_t) else -1 end, ''ms''); '
        -- NEW_PROCESS und CLOSE_PROCESS ueber den Dispatcher
        || 'l_t := systimestamp; l_new := lilam.server_new_process(p_processName => ''LT_' || l_run || '_IFN'', p_groupName => '''
        || lt.c_group || ''', p_logLevel => lilam.logLevelInfo); '
        || 'lt.metric(' || l_run || ', ''ns_ms_' || p_tag || ''', lt.ms_since(l_t), ''ms''); '
        || 'l_t := systimestamp; lilam.close_process(l_new); '
        || 'lt.metric(' || l_run || ', ''cs_ms_' || p_tag || ''', lt.ms_since(l_t), ''ms''); '
        || 'exception when others then lt.joblog(' || l_run || ', ' || i || ', ''ERROR'', sqlerrm); end;');
      l_ok := lt.wait_jobs('LT_CIF_' || l_run || '_' || p_tag || '_' || i, 60);
      dbms_session.sleep(0.3);
    end loop;
  end;
begin
  l_run := lt.begin_run('IDLE_FLUSH_LASTFALL', 'DISPATCHER', 'ein Worker; Client A alle 210 ms ein INFO; je 20 Messungen');
  lt.stop_all_servers;
  lt.start_server('LT_S1'); lt.start_server(lt.c_disp_pipe, 1);
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', lt.c_disp_pipe));

  -- Prozess, an den Client B sein INFO schickt (Reconnect aus frischer Session)
  lt.run_job('LT_CIF_' || l_run || '_P',
    'declare l_pid number; begin lilam.set_dispatcher_pipe(''' || lt.c_disp_pipe || '''); '
    || 'l_pid := lilam.server_new_process(p_processName => ''LT_' || l_run || '_IFP'', p_groupName => ''' || lt.c_group
    || ''', p_logLevel => lilam.logLevelInfo); lt.metric(' || l_run || ', ''pid'', l_pid); end;');
  l_ok := lt.wait_jobs('LT_CIF_' || l_run || '_P', 60);
  select max(value) into l_pid from lt_metric where run_id = l_run and metric = 'pid';
  dbms_session.sleep(2);

  -- Phase 1: ohne Last
  measure('noload');

  -- Phase 2: Client A erzeugt Dauer-Leerlauf-Flushes (60 s lang alle 210 ms ein INFO, laenger als Phase 2)
  lt.run_job('LT_CIF_' || l_run || '_A',
    'declare l_pid number; l_end timestamp := systimestamp + interval ''60'' second; begin '
    || 'lilam.set_dispatcher_pipe(''' || lt.c_disp_pipe || '''); '
    || 'l_pid := lilam.server_new_process(p_processName => ''LT_' || l_run || '_IFA'', p_groupName => ''' || lt.c_group
    || ''', p_logLevel => lilam.logLevelInfo); '
    || 'while systimestamp < l_end loop lilam.info(l_pid, ''load''); dbms_session.sleep(0.21); '
    || 'end loop; lilam.close_process(l_pid); end;');
  dbms_session.sleep(2);
  measure('load');
  l_ok := lt.wait_jobs('LT_CIF_' || l_run || '_A', 90);

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
