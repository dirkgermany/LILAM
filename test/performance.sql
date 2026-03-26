/*
-- EPS
SELECT 
    COUNT(*) as Anzahl_Jobs,
    SUM(50000) as Gesamt_Events,
    ROUND(AVG(EXTRACT(SECOND FROM run_duration) + EXTRACT(MINUTE FROM run_duration) * 60), 2) as Avg_Dauer_Sek,
    ROUND(SUM(50000) / NULLIF(MAX(EXTRACT(SECOND FROM run_duration) + EXTRACT(MINUTE FROM run_duration) * 60), 0), 2) as Kumulierte_EPS
FROM all_scheduler_job_run_details
WHERE job_name LIKE '%LILAM_STRESS_%'
  AND actual_start_date > TRUNC(SYSDATE);

-- Jobs
SELECT job_name, 
       actual_start_date, 
       run_duration,
       cpu_used
FROM all_scheduler_job_run_details 
WHERE job_name LIKE '%LILAM_STRESS_%'
ORDER BY actual_start_date DESC;

-- Job-History löschen
EXEC DBMS_SCHEDULER.PURGE_LOG(log_history => 0);
*/


DECLARE
    v_job_count  INTEGER := 10; -- Anzahl der parallelen Instanzen
    v_job_name   VARCHAR2(30);
    v_plsql      CLOB;
BEGIN
    -- 1. Vorbereitung: Einmaliges Leeren der Tabellen (Vermeidung von Resource Busy Fehlern)
    EXECUTE IMMEDIATE 'truncate table lilamtest_proc';
    EXECUTE IMMEDIATE 'truncate table lilamtest_log';
    EXECUTE IMMEDIATE 'truncate table lilamtest_mon';
    
    -- 2. Der PL/SQL-Code für die Worker-Jobs (ohne Truncates!)
    v_plsql := '
    DECLARE
        lSessionId NUMBER;
    BEGIN
        lSessionId := lilam.server_new_session(''ParallelJob'', ''testGroup'', lilam.logLevelMonitor, 100, 100, ''lilamtest'');
        FOR i IN 1..10000 LOOP
            lilam.TRACE_START(lSessionId, ''Action '' || i, ''context'');
            lilam.mark_event(lSessionId, ''Event '' || i, ''context'');
            lilam.info(lSessionId, ''Info '' || i);
            lilam.PROC_STEP_DONE(lSessionId);
            lilam.TRACE_STOP(lSessionId, ''Action '' || i, ''context'');
        END LOOP;
        lilam.close_session(lSessionId);
    EXCEPTION
        WHEN OTHERS THEN
            NULL; -- Fehler im Job unterdrücken, um Test nicht zu stoppen
    END;';

    -- 3. Jobs abfeuern
    FOR i IN 1..v_job_count LOOP
        v_job_name := 'LILAM_STRESS_' || i;
        
        -- Falls der Job noch existiert (von einem alten Test), löschen
        BEGIN
            DBMS_SCHEDULER.DROP_JOB(v_job_name, force => TRUE);
        EXCEPTION WHEN OTHERS THEN NULL; END;

        DBMS_SCHEDULER.CREATE_JOB (
            job_name   => v_job_name,
            job_type   => 'PLSQL_BLOCK',
            job_action => v_plsql,
            enabled    => TRUE,
            auto_drop  => TRUE
        );
        
        dbms_session.sleep(1);
    END LOOP;
    
    DBMS_OUTPUT.PUT_LINE(v_job_count || ' Jobs wurden gestartet. Prüfe v$session oder scheduler_job_run_details.');
END;
/
