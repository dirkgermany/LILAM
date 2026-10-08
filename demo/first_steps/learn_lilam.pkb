create or replace PACKAGE BODY LEARN_LILAM AS

    /*
        First steps:
        * start a process
        * use dedicated log tables
        * log with level info
        * write status of process
        * close the process
    */
    procedure simple_sample
    as
        l_processId number(19,0);
    begin
        -- use named params for this first time API call
        l_processId := lilam.new_process(
            p_processName   => 'simple sample',
            p_logLevel      => lilam.logLevelInfo,
            p_daysToKeep    => 1,
            p_tabNameMaster => 'learn_lilam'
        );
        lilam.info(l_processId, 'simple sample little step');
        lilam.set_process_status(l_processId, 1, 'Perfect!');
        lilam.close_process(l_processId);
    end;

    -- Shows how an application can be monitored.
    -- For simplicity, this example uses dbms_output. Therefore, please activate the DBMS_OUTPUT window.
    -- Starts without steps, sets steps_todo after starting and increments the completed steps
    -- No detail will be written
    procedure increment_steps_and_monitor
    as
        l_processId number(19,0);
    begin
        dbms_output.enable();
        -- new process
        l_processId := lilam.new_process(
            p_processName => 'cycle with steps',
            p_logLevel    => lilam.logLevelInfo,
            p_daysToKeep  => 1
        );
        dbms_output.put_line('New process ID: ' || l_processId);

        -- Update process/application information (monitoring info)
        -- Alternatively, the number of expected steps could have been specified using the new_process function
        lilam.set_proc_steps_todo(l_processId, 10);
        dbms_output.put_line('Steps To Do: ' || lilam.get_proc_steps_todo(l_processId));

        -- monitor when a work step has been completed
        for i in 1..9 loop
            -- update process status
            lilam.proc_step_done(l_processId);
            dbms_output.put_line('Some step completed: ' || i);
        end loop;

        -- The process data can be read as long as the process is open
        lilam.set_process_status(l_processId, 4, 'Too little');
        dbms_output.put_line('Process Status: ' || lilam.get_process_status(l_processId));
        dbms_output.put_line('Process Info  : ' || lilam.get_process_info(l_processId));
        dbms_output.put_line('Process Start : ' || lilam.get_process_start(l_processId));
        dbms_output.put_line('Steps Done    : ' || lilam.get_proc_steps_done(l_processId));

        lilam.close_process(l_processId);
        dbms_output.put_line('Process finished and closed');
    end;


    -- Starts with a number of steps, ends with a number of steps processed
    -- No detail will be written
    procedure begin_and_end_with_steps
    as
        l_processId number(19,0);
    begin
        l_processId := lilam.new_process('begin and end with steps', lilam.logLevelInfo, 10, 1);
        lilam.close_process(l_processId, 'Too much', 4, 11);
    end;

    -- Call this function within a select statement:
    -- select learn_lilam.print_process_infos from dual;
    function print_process_infos return varchar2
    as
        -- Autonomous transaction: allows LILAM to create its tables even if called from a SELECT
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_processId number(19,0);
        l_result    varchar2(1000);
    begin
        l_processId := lilam.new_process(
            p_processName   => 'print_process_infos',
            p_logLevel      => lilam.logLevelInfo,
            p_procStepsToDo => 41,
            p_daysToKeep    => 1
        );
        lilam.set_proc_steps_done(l_processId, 42);
        lilam.set_process_status(l_processId, 7, 'Response');

        l_result := 'Process Informations: ID = ' || l_processId || '; Status: ' || lilam.get_process_status(l_processId)
                 || '; Info: ' || lilam.get_process_info(l_processId) || '; Steps todo: ' || lilam.get_proc_steps_todo(l_processId)
                 || '; Steps done: ' || lilam.get_proc_steps_done(l_processId) || '; Start: ' || lilam.get_process_start(l_processId);

        lilam.close_process(l_processId);
        commit;
        return l_result;
    end;
END LEARN_LILAM;
