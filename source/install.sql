-- =============================================================================
-- LILAM: Installation
--
-- Aufruf (SQL*Plus / SQLcl), im Zielschema angemeldet:
--   @<Pfad>/source/install.sql
--
-- Voraussetzung: Grants laut docs/setup.md
--   In-Session:  CREATE SESSION, CREATE TABLE, CREATE SEQUENCE
--   Entkoppelt:  zusätzlich EXECUTE ON DBMS_PIPE, EXECUTE ON DBMS_ALERT, CREATE JOB
--
-- Ablauf:
--   1. Package-Spec und -Body kompilieren
--   2. Status der Objekte prüfen
--   3. Life Check (LILAM.IS_ALIVE): legt beim ersten Aufruf die Standardtabellen
--      LILAM_PROC/_LOG/_MON sowie die festen Tabellen und die Sequenz an und
--      schreibt einen Testprozess 'LILAM Life Check'. Fehlende Rechte fallen so
--      sofort auf.
-- =============================================================================

set serveroutput on
set feedback off
whenever sqlerror exit failure

prompt
prompt === LILAM: Package kompilieren ===
@@package/lilam.pks
@@package/lilam.pkb

whenever sqlerror continue

prompt
prompt === LILAM: Status der Objekte ===
column object_name format a20
column object_type format a15
column status      format a10
select object_name, object_type, status
from   user_objects
where  object_name = 'LILAM'
order  by object_type;

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

prompt
prompt === LILAM: Life Check ===
exec lilam.is_alive

column process_name format a20
column info         format a10
select id, process_name, status, info
from   lilam_proc
where  process_name = 'LILAM Life Check'
order  by id desc
fetch  first 1 rows only;

declare
    l_errors pls_integer;
begin
    select count(*) into l_errors from lilam_log_internal;
    if l_errors > 0 then
        dbms_output.put_line('Hinweis: LILAM_LOG_INTERNAL enthält ' || l_errors || ' Einträge (z.B. fehlende Rechte).');
    end if;
exception
    when others then
        null; -- Tabelle existiert erst nach dem ersten internen Fehler
end;
/

prompt
exec dbms_output.put_line('LILAM ' || lilam.lilam_version || ' ist installiert.')
