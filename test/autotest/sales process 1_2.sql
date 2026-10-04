/*
	Sales Process 1 und 2
*/
set serveroutput on;
declare
    l_procIdSales_1 number;
    l_procIdSales_2 number;
    l_toggle number := 1;
begin    
    loop
        l_procIdSales_1 := lilam.server_new_session('SALES_PROC_1', 'SALES_GROUP', lilam.logLevelDebug, 60000, 999, 'REGISTRY_TEST');
        l_procIdSales_2 := lilam.server_new_session('SALES_PROC_2', 'SALES_GROUP', lilam.logLevelDebug, 60000, 999, 'REGISTRY_TEST');
        for i in 1..10000 loop
            lilam.info(l_procIdSales_1, 'SALES_PROC_1 Logging');
            lilam.proc_step_done(l_procIdSales_1);
            lilam.info(l_procIdSales_2, 'SALES_PROC_2 Logging');
            lilam.proc_step_done(l_procIdSales_2);
            
            lilam.mark_event(l_procIdSales_1, 'SALES_PROC_1 Mark Event', 'Event Context');
            lilam.proc_step_done(l_procIdSales_1);
            lilam.trace_start(l_procIdSales_1, 'SALES_PROC_1 Trace mit Context', 'Trace Context');
            lilam.proc_step_done(l_procIdSales_1);
            lilam.trace_start(l_procIdSales_1, 'SALES_PROC_1 Trace ohne Context');
            lilam.proc_step_done(l_procIdSales_1);
            
            lilam.mark_event(l_procIdSales_2, 'SALES_PROC_2 Mark Event', 'Event Context');
            lilam.proc_step_done(l_procIdSales_2);
            lilam.trace_start(l_procIdSales_2, 'SALES_PROC_2 Trace mit Context', 'Trace Context');
            lilam.proc_step_done(l_procIdSales_2);
            lilam.trace_start(l_procIdSales_2, 'SALES_PROC_2 Trace ohne Context');
            lilam.proc_step_done(l_procIdSales_2);
            
            lilam.trace_stop(l_procIdSales_1, 'SALES_PROC_1 Trace mit Context', 'Trace Context');
            lilam.proc_step_done(l_procIdSales_1);
            lilam.trace_stop(l_procIdSales_1, 'SALES_PROC_1 Trace ohne Context');
            lilam.proc_step_done(l_procIdSales_1);
            lilam.trace_stop(l_procIdSales_2, 'SALES_PROC_2 Trace mit Context', 'Trace Context');
            lilam.proc_step_done(l_procIdSales_2);
            lilam.trace_stop(l_procIdSales_2, 'SALES_PROC_2 Trace ohne Context');
            lilam.proc_step_done(l_procIdSales_2);
        end loop;    
        lilam.close_session(l_procIdSales_1);
        lilam.close_session(l_procIdSales_2);
        dbms_session.sleep(300);
    end loop;
    

end;
/