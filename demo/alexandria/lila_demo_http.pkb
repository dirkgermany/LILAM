create or replace PACKAGE BODY LILA_DEMO_HTTP AS

    /*
      Demonstrates the interaction between http_util_pkg (Alexandria pl/sql Utility Library) and LILA.
      
      1. Open LILA log session
      2. Write LILA log entries
      3. Call external pl/sql http_util_pkg
      4. Update process information
      5. Close session
    */
    procedure getBlobFromUrl
    as
        l_data CLOB;
        l_processId number (19,0);
    begin
        -- open new log session with a session-/process-name and info level
        l_processId := lila.new_session('Demo: http_util_pkg', lila.logLevelInfo, null);
        
        -- 1. valid call
        lila.info(l_processId, '1. Valid call http_util_pkg.get_cob_from_url');
        l_data := http_util_pkg.get_clob_from_url('https://httpbin.org/get');
        -- update process status in table lila_log
        lila.set_process_status(l_processId, 1, l_data);
        lila.info(l_processId, 'First call was successfull :)');
        lila.info(l_processId, 'Data: ' || l_data);
        
        -- 2. invalid call
        lila.info(l_processId, '2. Invalid call http_util_pkg.get_cob_from_url');
        l_data := http_util_pkg.get_clob_from_url('https://something / wrong.com');
        
        -- Because an exception was thrown, the next calls should not be executed
        -- and the process control continous with exception handling.
        lila.set_process_status(l_processId, 1, l_data);
        lila.info(l_processId, 'Call was successfull :)');
        
        -- close session
        lila.close_session(l_processId);
       
    exception
        when others then
        -- LILA-Logging: save error with context
        lila.error(l_processId, 'Fault with second call!' || SQLERRM);
        -- close session
        lila.close_session(
            p_processId   => l_processId,
            p_stepsToDo   => null,
            p_stepsDone   => null,
            p_processInfo => 'Error! Details see table lila_log_details with process_id = ' || l_processId,
            p_status      => 1
        );
        raise;
    end;

END LILA_DEMO_HTTP;
