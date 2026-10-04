-- =============================================================================
-- LILAM: Deinstallation
--
-- Aufruf (SQL*Plus / SQLcl), im Schema angemeldet, in dem LILAM installiert ist:
--   @<Pfad>/source/uninstall.sql
--
-- Standard: Server stoppen und das Package entfernen. Alle Tabellen und Daten
-- bleiben erhalten, eine spätere Neuinstallation arbeitet mit ihnen weiter.
--
-- Mit LILAM_DROP_DATA = 'J' werden zusätzlich ALLE LILAM-Tabellen samt Daten
-- und die Sequenz gelöscht. Das lässt sich nicht rückgängig machen.
-- =============================================================================

define LILAM_DROP_DATA = 'N'

set serveroutput on
set feedback off
set verify off

prompt
prompt === LILAM: Server stoppen ===
-- Server, die mit CREATE_SERVER gestartet wurden, laufen als Scheduler-Job mit
-- dem Pipe-Namen als Job-Namen. Server, die mit START_SERVER in einer eigenen
-- Session laufen, kann dieses Skript nicht beenden; sie mit SERVER_SHUTDOWN
-- stoppen oder die Session beenden, sonst blockieren sie das Löschen des Packages.
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

    -- 1. Jobs anhalten
    for i in 1 .. l_jobs.count loop
        begin
            dbms_scheduler.stop_job(job_name => l_jobs(i), force => false);
        exception
            when others then
                null; -- Job läuft nicht (mehr)
        end;
    end loop;

    -- 2. auf das Ende der Jobs warten (höchstens 30 s)
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

    -- 3. Jobs entfernen
    for i in 1 .. l_jobs.count loop
        begin
            dbms_scheduler.drop_job(job_name => l_jobs(i), force => false);
            dbms_output.put_line('Server-Job entfernt: ' || l_jobs(i));
        exception
            when others then
                null; -- auto_drop: Job ist mit seinem Ende bereits verschwunden
        end;
    end loop;

    if l_running > 0 then
        dbms_output.put_line('Achtung: ' || l_running || ' Server-Job(s) laufen noch.');
    end if;

    -- 4. Daten- und Steuer-Pipes entfernen. Dynamisch, damit der Block auch ohne
    --    Recht auf DBMS_PIPE (reine In-Session-Installation) übersetzt wird.
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

    -- Anwendungstabellen <Präfix>_PROC/_LOG/_MON: erkannt an der Prozesstabelle
    -- mit den LILAM-Spalten TAB_NAME_MASTER und SERVER_PIPE
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

    -- feste Tabellen
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
