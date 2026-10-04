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
--   2. Status der Objekte prüfen, abhängige ungültige Objekte neu übersetzen
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

prompt
prompt === LILAM: Status der Objekte ===
column object_name format a20
column object_type format a15
column status      format a10
select object_name, object_type, status
from   user_objects
where  object_name = 'LILAM'
order  by object_type;

-- bricht das Skript ab, wenn LILAM nicht gültig ist (whenever sqlerror exit)
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

-- Objekte, die von LILAM abhängen (z.B. eigene Packages der Anwendung), werden
-- bei einer Neuinstallation ungültig. Ungültige Objekte des Schemas neu übersetzen.
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

-- neue Einträge in LILAM_LOG_INTERNAL seit dem Life Check (z.B. fehlende Rechte)
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
        dbms_output.put_line('Keine internen Fehler.'); -- Tabelle entsteht erst mit dem ersten internen Fehler
end;
/

exec dbms_output.put_line('LILAM ' || lilam.lilam_version || ' ist installiert.')
