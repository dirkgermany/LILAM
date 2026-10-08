create or replace PACKAGE BODY LILAM_DEMO_HTTP AS

    /*
      Demonstrates the interaction between http_util_pkg (Alexandria pl/sql Utility Library) and LILAM.
      
      1. Start LILAM process
      2. Write LILAM log entries
      3. Call external pl/sql http_util_pkg
      4. Update process information
      5. Close process
    */
    procedure getBlobFromUrl
    as
        l_data CLOB;
        l_processId number (19,0);
    begin
        -- start a new process with a process name and info level
        l_processId := lilam.new_process('Demo: http_util_pkg', lilam.logLevelInfo);
        
        -- 1. valid call
        lilam.info(l_processId, '1. Valid call http_util_pkg.get_cob_from_url');
        l_data := http_util_pkg.get_clob_from_url('https://httpbin.org/get');
        -- update process status in table lilam_proc
        lilam.set_process_status(l_processId, 1, l_data);
        lilam.info(l_processId, 'First call was successfull :)');
        lilam.info(l_processId, 'Data: ' || l_data);
        
        -- 2. invalid call
        lilam.info(l_processId, '2. Invalid call http_util_pkg.get_cob_from_url');
        l_data := http_util_pkg.get_clob_from_url('https://something / wrong.com');
        
        -- Because an exception was thrown, the next calls should not be executed
        -- and the process control continous with exception handling.
        lilam.set_process_status(l_processId, 1, l_data);
        lilam.info(l_processId, 'Call was successfull :)');
        
        -- close process
        lilam.close_process(l_processId);
       
    exception
        when others then
        -- LILAM: save error with context
        lilam.error(l_processId, 'Fault with second call!' || SQLERRM);
        -- close process
        lilam.close_process(
            p_processId     => l_processId,
            p_processInfo   => 'Error! Details see table lilam_log with process_id = ' || l_processId,
            p_processStatus => 1
        );
        raise;
    end;

END LILAM_DEMO_HTTP;
