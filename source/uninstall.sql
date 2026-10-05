-- =============================================================================
-- LILAM: uninstallation
--
-- Call (SQL*Plus / SQLcl), logged on to the schema in which LILAM is installed:
--   @<path>/source/uninstall.sql
--
-- Default: stop the servers and remove the package. All tables and data
-- are kept, a later reinstallation continues to work with them.
--
-- With LILAM_DROP_DATA = 'J', ALL LILAM tables including data
-- and the sequence are dropped as well. This cannot be undone.
-- =============================================================================

define LILAM_DROP_DATA = 'N'

set serveroutput on
set feedback off
set verify off

prompt
prompt === LILAM: Server stoppen ===
-- Servers started with CREATE_SERVER run as scheduler jobs with
-- the pipe name as job name. Servers that run with START_SERVER in their own
-- session cannot be ended by this script; stop them with SERVER_SHUTDOWN
-- or end the session, otherwise they block dropping the package.
declare
    l_registry_exists pls_integer;
    l_running         pls_integer := 0;
    type t_names is table of varchar2(128);
    l_jobs            t_names := t_names();
    l_pipes           t_names := t_names();
begin
    select count(*) into l_registry_exists
    from   user_tables
    where  table_name = 'LILAM_SERVER_REGISTRY';

    if l_registry_exists = 0 then
        dbms_output.put_line('Keine Server-Registry gefunden.');
        return;
    end if;

    execute immediate 'select upper(pipe_name) from lilam_server_registry'
        bulk collect into l_pipes;

    execute immediate
        'select j.job_name
         from   user_scheduler_jobs j
         where  j.job_name in (select upper(r.pipe_name) from lilam_server_registry r)'
        bulk collect into l_jobs;

    if l_jobs.count = 0 then
        dbms_output.put_line('Keine Server-Jobs gefunden.');
    end if;

    -- 1. Stop jobs
    for i in 1 .. l_jobs.count loop
        begin
            dbms_scheduler.stop_job(job_name => l_jobs(i), force => false);
            dbms_output.put_line('Server-Job gestoppt: ' || l_jobs(i));
        exception
            when others then
                null; -- Job is not running (any more)
        end;
    end loop;

    -- 2. wait for the jobs to end (at most 30 s)
    for w in 1 .. 30 loop
        l_running := 0;
        for i in 1 .. l_jobs.count loop
            for r in (select 1 from user_scheduler_running_jobs where job_name = l_jobs(i)) loop
                l_running := l_running + 1;
            end loop;
        end loop;
        exit when l_running = 0;
        dbms_session.sleep(1);
    end loop;

    -- 3. Remove jobs
    for i in 1 .. l_jobs.count loop
        begin
            dbms_scheduler.drop_job(job_name => l_jobs(i), force => false);
            dbms_output.put_line('Server-Job entfernt: ' || l_jobs(i));
        exception
            when others then
                null; -- auto_drop: the job has already disappeared when it ended
        end;
    end loop;

    if l_running > 0 then
        dbms_output.put_line('Achtung: ' || l_running || ' Server-Job(s) laufen noch.');
    end if;

    -- 4. Remove data and control pipes. Dynamic, so that the block also compiles
    --    without the privilege on DBMS_PIPE (pure in-session installation).
    for i in 1 .. l_pipes.count loop
        begin
            execute immediate
                'declare l_dummy pls_integer; begin
                     l_dummy := dbms_pipe.remove_pipe(:1);
                     l_dummy := dbms_pipe.remove_pipe(:1 || ''_CTL'');
                 end;'
                using l_pipes(i);
        exception
            when others then
                null;
        end;
    end loop;
end;
/

prompt
prompt === LILAM: Package entfernen ===
declare
    l_count pls_integer;
begin
    select count(*) into l_count from user_objects where object_name = 'LILAM' and object_type = 'PACKAGE';
    if l_count > 0 then
        execute immediate 'drop package lilam';
        dbms_output.put_line('Package LILAM entfernt.');
    else
        dbms_output.put_line('Package LILAM nicht vorhanden.');
    end if;
end;
/

prompt
prompt === LILAM: Tabellen und Sequenz (nur mit LILAM_DROP_DATA = 'J') ===
declare
    c_drop_data constant boolean := upper('&LILAM_DROP_DATA') in ('J', 'Y');
    type t_names is table of varchar2(128);
    l_tables t_names;

    procedure drop_table(p_name varchar2) is
    begin
        execute immediate 'drop table ' || dbms_assert.enquote_name(p_name, false) || ' purge';
        dbms_output.put_line('Tabelle entfernt: ' || p_name);
    exception
        when others then
            if sqlcode != -942 then
                dbms_output.put_line('Tabelle ' || p_name || ' nicht entfernt: ' || sqlerrm);
            end if;
    end;
begin
    if not c_drop_data then
        dbms_output.put_line('Tabellen und Daten bleiben erhalten (LILAM_DROP_DATA = ''N'').');
        return;
    end if;

    -- Application tables <prefix>_PROC/_LOG/_MON: recognized by the process table
    -- with the LILAM columns TAB_NAME_MASTER and SERVER_PIPE
    select substr(t.table_name, 1, length(t.table_name) - 5)
    bulk collect into l_tables
    from   user_tables t
    where  t.table_name like '%\_PROC' escape '\'
    and    exists (select 1 from user_tab_columns c
                   where  c.table_name = t.table_name and c.column_name = 'TAB_NAME_MASTER')
    and    exists (select 1 from user_tab_columns c
                   where  c.table_name = t.table_name and c.column_name = 'SERVER_PIPE');

    for i in 1 .. l_tables.count loop
        drop_table(l_tables(i) || '_LOG');
        drop_table(l_tables(i) || '_MON');
        drop_table(l_tables(i) || '_PROC');
    end loop;

    -- fixed tables
    drop_table('LILAM_ALERTS');
    drop_table('LILAM_RULES');
    drop_table('LILAM_BASELINES');
    drop_table('LILAM_SCOPES');
    drop_table('LILAM_PROCESS_ROUTE');
    drop_table('LILAM_SERVER_REGISTRY');
    drop_table('LILAM_LOG_INTERNAL');

    begin
        execute immediate 'drop sequence seq_lilam_log';
        dbms_output.put_line('Sequenz SEQ_LILAM_LOG entfernt.');
    exception
        when others then
            if sqlcode != -2289 then
                dbms_output.put_line('Sequenz nicht entfernt: ' || sqlerrm);
            end if;
    end;
end;
/

prompt
prompt LILAM ist deinstalliert.
undefine LILAM_DROP_DATA
