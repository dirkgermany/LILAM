-- =============================================================================
-- LILAM: installation
--
-- Call (SQL*Plus / SQLcl), logged on to the target schema:
--   @<path>/source/install.sql
--
-- Prerequisite: grants according to docs/setup.md
--   In-Session:  CREATE SESSION, CREATE TABLE, CREATE SEQUENCE
--   Decoupled:   additionally EXECUTE ON DBMS_PIPE, EXECUTE ON DBMS_ALERT, CREATE JOB
--
-- Steps:
--   1. Compile package spec and body
--   2. Check the status of the objects, recompile dependent invalid objects
--   3. Life check (LILAM.IS_ALIVE): on the first call creates the default tables
--      LILAM_PROC/_LOG/_MON as well as the fixed tables and the sequence and
--      writes a test process 'LILAM Life Check'. Missing privileges thus show up
--      immediately.
-- =============================================================================

set serveroutput on
set feedback off
whenever sqlerror exit failure

prompt
prompt === LILAM: Package kompilieren ===
@@package/lilam.pks
@@package/lilam.pkb

prompt
prompt === LILAM: Status der Objekte ===
column object_name format a20
column object_type format a15
column status      format a10
select object_name, object_type, status
from   user_objects
where  object_name = 'LILAM'
order  by object_type;

-- aborts the script if LILAM is not valid (whenever sqlerror exit)
declare
    l_invalid pls_integer;
begin
    select count(*) into l_invalid
    from   user_objects
    where  object_name = 'LILAM'
    and    status <> 'VALID';

    if l_invalid > 0 then
        raise_application_error(-20000, 'LILAM ist nicht gültig, siehe "show errors package body lilam".');
    end if;
end;
/

whenever sqlerror continue

-- Objects that depend on LILAM (e.g. the application's own packages) become
-- invalid on a reinstallation. Recompile invalid objects of the schema.
exec dbms_utility.compile_schema(schema => user, compile_all => false)

prompt
prompt === LILAM: Life Check ===
variable l_start varchar2(40)
exec :l_start := to_char(systimestamp, 'YYYY-MM-DD HH24:MI:SS.FF6')
exec lilam.is_alive

column process_name format a20
column info         format a10
select id, process_name, status, info
from   lilam_proc
where  process_name = 'LILAM Life Check'
order  by id desc
fetch  first 1 rows only;

-- new entries in LILAM_LOG_INTERNAL since the life check (e.g. missing privileges)
declare
    l_errors pls_integer;
begin
    execute immediate
        'select count(*) from lilam_log_internal
         where  log_timestamp >= to_timestamp(:1, ''YYYY-MM-DD HH24:MI:SS.FF6'')'
        into l_errors using :l_start;
    if l_errors > 0 then
        dbms_output.put_line('Achtung: LILAM_LOG_INTERNAL enthält ' || l_errors || ' neue Einträge, siehe Tabelle.');
    else
        dbms_output.put_line('Keine internen Fehler.');
    end if;
exception
    when others then
        dbms_output.put_line('Keine internen Fehler.'); -- The table is only created with the first internal error
end;
/

exec dbms_output.put_line('LILAM ' || lilam.lilam_version || ' ist installiert.')
