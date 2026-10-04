-- =====================================================================
-- Aufraeumen nach Tests
--   1. Alle Test-Server und Test-Jobs stoppen
--   2. Optional: LILAM-Daten aller Testprozesse (Prozessnamen LT_*) loeschen
-- Die Testergebnisse in LT_RUN / LT_CHECK / LT_METRIC bleiben erhalten.
-- =====================================================================
set serveroutput on size unlimited

begin
  lt.stop_all_servers;
  for j in (select job_name from user_scheduler_jobs where job_name like 'LT\_%' escape '\') loop
    begin dbms_scheduler.stop_job(j.job_name); exception when others then null; end;
    dbms_output.put_line('Job gestoppt: ' || j.job_name);
  end loop;
end;
/

-- LILAM-Daten der Testprozesse loeschen (bei Bedarf einkommentieren)
-- delete from lilam_log  where process_id in (select id from lilam_proc where process_name like 'LT\_%' escape '\');
-- delete from lilam_mon  where process_id in (select id from lilam_proc where process_name like 'LT\_%' escape '\');
-- delete from lilam_process_route where process_id in (select id from lilam_proc where process_name like 'LT\_%' escape '\');
-- delete from lilam_baselines where scope_id in (select scope_id from lilam_scopes where scope_name like 'LT\_%' escape '\');
-- delete from lilam_scopes where scope_name like 'LT\_%' escape '\';
-- delete from lilam_proc where process_name like 'LT\_%' escape '\';
-- commit;
