-- =====================================================================
-- LILAM Belastungstest: SKALIERUNG
--
-- Frage: Was bringt es, wenn mehrere Server gleichzeitig arbeiten, mit und ohne Dispatcher?
--
-- Dieselben Laststufen fuer jede Kombination aus Modus und Worker-Anzahl:
--   SERVER mit 1, 2 und 3 Workern (Clients waehlen den Worker selbst)
--   DISPATCHER mit 2 und 3 Workern (alle Nachrichten laufen ueber LT_DISP)
-- Jede Kombination ist ein Teillauf (PARENT_RUN_ID). Der Bericht vergleicht die hoechste tragfaehige Stufe.
-- Erwartung aus dem Code (Hypothesen H1/H2 in BELASTUNG/README.md): ohne Dispatcher waechst die Grenze mit den
-- Workern, bis die CPU voll ist; mit Dispatcher bleibt sie bei der Grenze der einen Dispatcher-Pipe stehen.
--
-- Laufzeit: 5 Teillaeufe zu je hoechstens ca. 6 min, insgesamt ca. 30 min
-- Jobs: hoechstens 14 Clients + 3 Worker + Dispatcher + Beobachter = 19 (job_queue_processes = 20)
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  l_run := ltb.t_skalierung(
             p_modes     => 'SERVER,DISPATCHER',
             p_workers   => '1,2,3',
             p_stages    => '4x250,8x250,14x250,14x400,14x600,14x900',
             p_stage_sec => 45,
             p_err_pct   => 1);
end;
/
