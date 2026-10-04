/*
	Sales Process 3 und 4
*/
set serveroutput on;
declare
    l_procIdSales_3 number;
    l_procIdSales_4 number;
begin    
    loop
		l_procIdSales_3 := lilam.server_new_session('SALES_PROC_3', 'SALES_GROUP', lilam.logLevelDebug, 60000, 999, 'REGISTRY_TEST');
		l_procIdSales_4 := lilam.server_new_session('SALES_PROC_4', 'SALES_GROUP', lilam.logLevelDebug, 60000, 999, 'REGISTRY_TEST');
		
		for i in 1..10000 loop
            
            lilam.info(l_procIdSales_3, 'SALES_PROC_3 Logging');
            lilam.proc_step_done(l_procIdSales_3);
            lilam.info(l_procIdSales_4, 'SALES_PROC_4 Logging');
            lilam.proc_step_done(l_procIdSales_4);
            
            lilam.mark_event(l_procIdSales_3, 'SALES_PROC_3 Mark Event', 'Event Context');
            lilam.proc_step_done(l_procIdSales_3);
            lilam.trace_start(l_procIdSales_3, 'SALES_PROC_3 Trace mit Context', 'Trace Context');
            lilam.proc_step_done(l_procIdSales_3);
            lilam.trace_start(l_procIdSales_3, 'SALES_PROC_3 Trace ohne Context');
            lilam.proc_step_done(l_procIdSales_3);
            
            lilam.mark_event(l_procIdSales_4, 'SALES_PROC_4 Mark Event', 'Event Context');
            lilam.proc_step_done(l_procIdSales_4);
            lilam.trace_start(l_procIdSales_4, 'SALES_PROC_4 Trace mit Context', 'Trace Context');
            lilam.proc_step_done(l_procIdSales_4);
            lilam.trace_start(l_procIdSales_4, 'SALES_PROC_4 Trace ohne Context');
            lilam.proc_step_done(l_procIdSales_4);
            
            lilam.trace_stop(l_procIdSales_3, 'SALES_PROC_3 Trace mit Context', 'Trace Context');
            lilam.proc_step_done(l_procIdSales_3);
            lilam.trace_stop(l_procIdSales_3, 'SALES_PROC_3 Trace ohne Context');
            lilam.proc_step_done(l_procIdSales_3);
            lilam.trace_stop(l_procIdSales_4, 'SALES_PROC_4 Trace mit Context', 'Trace Context');
            lilam.proc_step_done(l_procIdSales_4);
            lilam.trace_stop(l_procIdSales_4, 'SALES_PROC_4 Trace ohne Context');
            lilam.proc_step_done(l_procIdSales_4);            

        end loop;        
		lilam.close_session(l_procIdSales_3);
		lilam.close_session(l_procIdSales_4);
        dbms_session.sleep(240);
	end loop;
    
end;
/