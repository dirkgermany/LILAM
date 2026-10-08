-- =====================================================================
-- LILAM Belastungstest: BATCHSTART
--
-- Szenario: Nachtverarbeitung um 02:00. Der Orchestrator startet alle Ketten gleichzeitig; jede Kette
-- oeffnet sofort mehrere Prozesse (Teilschritte) und arbeitet dann gleichmaessig.
-- Alle Clients einer Stufe starten zum selben Zeitpunkt und oeffnen n Prozesse ohne Pause:
--   8 Clients x 10, 16 x 20, 16 x 50 Prozesse (bis 800 NEW_PROCESS in wenigen Sekunden).
-- Gemessen: Dauer von NEW_PROCESS (max), NEW_PROCESS ohne Prozess (Timeout 3 s, -20110),
-- Verteilung auf die Worker, Erholung danach. Erst SERVER, dann DISPATCHER (je 2 Worker).
--
-- Laufzeit: je Modus ca. 2 min
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  for m in (select column_value md from table(sys.odcivarchar2list(lt.c_server, lt.c_dispatcher))) loop
    l_run := ltb.t_stufen(
               p_test       => 'BELASTUNG_BATCHSTART',
               p_mode       => m.md,
               p_workers    => 2,
               p_stages     => '8x100n10,16x100n20,16x100n50',
               p_stage_sec  => 30,
               p_stop_after => 0);
  end loop;
end;
/
