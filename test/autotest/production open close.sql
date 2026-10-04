/*
	Production Open / Close
*/
set serveroutput on;
declare
    l_procIdProduction number;
	l_counter number := 0;
begin
    
    l_procIdProduction := lilam.server_new_session('PRODUCTION_PROC', lilam.logLevelDebug, 300, 999, 'REGISTRY_TEST');
    
	for i in 1..28800 loop -- 8 Stunden        
        lilam.info(l_procIdProduction, 'PRODUCTION_PROC Logging');
        lilam.proc_step_done(l_procIdProduction);
        
        lilam.mark_event(l_procIdProduction, 'PRODUCTION_PROC Mark Event', 'Event Context');
        lilam.proc_step_done(l_procIdProduction);
        lilam.trace_start(l_procIdProduction, 'PRODUCTION_PROC Trace mit Context', 'Trace Context');
        lilam.proc_step_done(l_procIdProduction);
        lilam.trace_start(l_procIdProduction, 'PRODUCTION_PROC Trace ohne Context');
        lilam.proc_step_done(l_procIdProduction);

        
        lilam.trace_stop(l_procIdProduction, 'PRODUCTION_PROC Trace mit Context', 'Trace Context');
        lilam.proc_step_done(l_procIdProduction);
        lilam.trace_stop(l_procIdProduction, 'PRODUCTION_PROC Trace ohne Context');
        lilam.proc_step_done(l_procIdProduction);
        
		
		l_counter:= l_counter +1;
		if (l_counter = 50) then
			lilam.close_session(l_procIdProduction);

            dbms_session.sleep(300);
			l_procIdProduction := lilam.server_new_session('PRODUCTION_PROC', lilam.logLevelDebug, 300, 999, 'REGISTRY_TEST');
			l_counter := 0;
		end if;
				
    end loop;        
	lilam.close_session(l_procIdProduction);

end;
/