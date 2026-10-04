-- =====================================================================
-- Uebersicht der Testlaeufe und ihrer Ergebnisse
-- =====================================================================
set linesize 200 pagesize 100

-- Letzte Laeufe
select r.run_id, r.test_name, r.mode_name, r.status,
       to_char(r.started, 'DD.MM. HH24:MI:SS') as gestartet,
       round((cast(r.ended as date) - cast(r.started as date)) * 86400) as dauer_s,
       (select count(*) from lt_check c where c.run_id = r.run_id and c.ok = 1) as ok,
       (select count(*) from lt_check c where c.run_id = r.run_id and c.ok = 0) as fehler
  from lt_run r
 order by r.run_id desc
 fetch first 30 rows only;

-- Fehlgeschlagene Pruefungen
select c.run_id, r.test_name, r.mode_name, c.check_name, c.detail
  from lt_check c join lt_run r on r.run_id = c.run_id
 where c.ok = 0
 order by c.run_id desc, c.check_no;

-- Fehler aus Client-Jobs
select run_id, client_no, phase, substr(info, 1, 150) as info, to_char(ts, 'DD.MM. HH24:MI:SS') as zeit
  from lt_joblog
 where phase = 'ERROR'
 order by ts desc
 fetch first 30 rows only;
