-- =====================================================================
-- Optionale Leserechte fuer Speicher-Messwerte in Dauertests
-- Ausfuehren als SYS in der PDB (z.B. FREEPDB1).
-- Ohne diese Grants laufen alle Tests, nur die PGA-Werte bleiben leer.
-- Direkte Grants sind noetig, weil Rollen in PL/SQL-Packages nicht wirken.
-- =====================================================================
alter session set container = FREEPDB1;

grant select on sys.v_$mystat   to lilam_test;
grant select on sys.v_$statname to lilam_test;
grant select on sys.v_$session  to lilam_test;
grant select on sys.v_$process  to lilam_test;

-- Mindestens 10 parallele Jobs werden gebraucht (Wert gilt im CDB-Root!):
--   alter session set container = CDB$ROOT;
--   alter system set job_queue_processes = 20 scope = both;
