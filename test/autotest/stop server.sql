set serveroutput on;
declare
    l_procId number;

begin    
    l_procId := lilam.new_process('STOP_SERVER', lilam.logLevelDebug);
    lilam.SERVER_SHUTDOWN(l_procId, 'SALES_PROC_1', 'password');
    lilam.SERVER_SHUTDOWN(l_procId, 'LILAM_JOB', 'password');
    lilam.close_process(l_procId);
end;
/