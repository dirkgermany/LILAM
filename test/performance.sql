set serveroutput on;
declare
    lSessionId number;
    v_diff interval day(0) to second(3); -- Präzision auf ms begrenzen
    p_start timestamp;
    p_end   timestamp;
    lMillis number;
    lEPS number;
begin
--    execute immediate 'truncate table lilam_log';
    execute immediate 'truncate table lilamtest_proc';
    execute immediate 'truncate table lilamtest_log';
    execute immediate 'truncate table lilamtest_mon';
    
    lSessionId := lilam.server_new_session('myProcess', 'testGroup', lilam.logLevelMonitor, 100, 100, 'lilamtest');
    dbms_output.put_line ('sessionId: ' || lSessionId);
    
    p_start := systimestamp;
    for i in 1..10000 loop
        lilam.TRACE_START(lSessionId, 'Action ' || i, 'any context');
        lilam.mark_event(lSessionId, 'Event ' || i, 'any context');
        lilam.info(lSessionId, 'Info ' || i);
        lilam.PROC_STEP_DONE(lSessionId);
        lilam.TRACE_STOP(lSessionId, 'Action ' || i, 'any context');
    end loop;
    p_end := systimestamp;
    
    lilam.close_session(lSessionId);
    
    v_diff := p_end - p_start;
    -- Wir extrahieren nur die Sekunden inklusive der Nachkommastellen (ms)
    -- und addieren die Minuten/Stunden/Tage als Sekunden-Vielfache
    lMillis := (extract(day from v_diff) * 86400000)
         + (extract(hour from v_diff) * 3600000)
         + (extract(minute from v_diff) * 60000)
         + (extract(second from v_diff) * 1000);


    lEPS := (50000/lMillis) * 1000;         
    dbms_output.put_line('Millis: ' || lMillis || '; EPS: ' || lEPS);
end;
