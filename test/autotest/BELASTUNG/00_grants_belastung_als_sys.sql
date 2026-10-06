-- =====================================================================
-- Optionale Leserechte fuer die Belastungstests (CPU, Commits, Redo)
-- Ausfuehren als SYS in der PDB (z.B. FREEPDB1).
-- Ohne diese Grants laufen alle Belastungstests, nur die Spalten CPU, Commits/s und Redo bleiben leer.
-- Direkte Grants sind noetig, weil Rollen in PL/SQL-Packages nicht wirken.
-- Ergaenzt _COMMON/00_grants_als_sys.sql (PGA-Werte).
-- =====================================================================
alter session set container = FREEPDB1;

grant select on sys.v_$osstat  to lilam_test;   -- BUSY_TIME/IDLE_TIME: CPU-Auslastung des Hosts
grant select on sys.v_$sysstat to lilam_test;   -- user commits, redo size

-- Parallele Jobs: Clients + Worker + Dispatcher + Beobachter muessen gleichzeitig laufen.
-- Die Skripte sind auf job_queue_processes = 20 abgestimmt (hoechstens 16 Clients je Stufe).
-- Fuer mehr Clients (Wert gilt im CDB-Root!):
--   alter session set container = CDB$ROOT;
--   alter system set job_queue_processes = 40 scope = both;
