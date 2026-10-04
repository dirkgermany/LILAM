set serveroutput on;
declare
    l_serverResp varchar2(100);
begin
    execute immediate 'truncate table lilam_log_internal';
    execute immediate 'truncate table lilam_log';
    execute immediate 'truncate table lilam_mon';
    execute immediate 'truncate table lilam_proc';
--    execute immediate 'truncate table lilam_server_log';
--    execute immediate 'truncate table lilam_server_mon';
--    execute immediate 'truncate table lilam_server_proc';
--    execute immediate 'truncate table lilam_server_registry';
    execute immediate 'truncate table registry_test_log';
    execute immediate 'truncate table registry_test_mon';
    execute immediate 'truncate table registry_test_proc';
    
    l_serverResp := lilam.create_server('LILAM_JOB', null, 'password');
    dbms_output.put_line(l_serverResp);
    lilam.start_server('LILAM_PROC', 'SALES_GROUP', 'password');
end;
/