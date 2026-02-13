-- Requires high end environment
-- Password will be needed later for shutdown
SET SERVEROUTPUT ON;
DECLARE
    v_pipe_name VARCHAR2(100);
    v_processId number;
BEGIN
    v_pipe_name := LILAM.CREATE_SERVER('<password>');
    DBMS_OUTPUT.PUT_LINE('Server gestartet auf Pipe: ' || v_pipe_name);
END;

-- Lesser powerfull environments (e.g. Test-PC)
-- Password will be needed later for shutdown
exec lilam.start_server('LILAM_P3', '<password>');
