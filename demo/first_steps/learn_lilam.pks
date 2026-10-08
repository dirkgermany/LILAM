create or replace PACKAGE LEARN_LILAM as 

    -- First steps
    procedure simple_sample;
    -- Start process, close process
    procedure begin_and_end_with_steps;
    -- Start process, increment steps, write number of completed steps to dbms_output, close process
    procedure increment_steps_and_monitor;
    -- Start process with initial data, return data, close process
    -- This function can be used within a select statement:
    -- "select learn_lilam.print_process_infos from dual;"
    function print_process_infos return varchar2;
    
end LEARN_LILAM;
