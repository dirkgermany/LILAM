-- =====================================================================
-- LILAM Belastungstest: APEX_STURM
--
-- Frage: Wie viele APEX-/ORDS-Requests je Sekunde traegt der Dispatcher, wenn jeder Request aus einer
--        Pool-Session mit leerem PGA kommt und die Prozess-ID aus dem Session State weiterverwendet?
--
-- 50 Prozesse werden ueber den Dispatcher angelegt (je APEX-Sitzung einer). Danach startet der Test
-- Requests im festen Takt (2, 5, 10, 15 je s), jeder als eigener Scheduler-Job: SET_DISPATCHER_PIPE,
-- erster Aufruf mit Reconnect ueber den Dispatcher, danach Trace, Event und INFO bis 13 Aufrufe.
-- Gemessen: Dauer des Reconnects, Dauer des Requests, Vollstaendigkeit, Raten von Dispatcher und Workern.
-- Grenze der Simulation: Scheduler-Jobs starten nicht beliebig schnell; der Startverzug steht getrennt
-- im Bericht und zaehlt nicht zur Request-Dauer.
--
-- Laufzeit: ca. 6 min
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  l_run := ltb.t_apex(
             p_stages    => '2,5,10,15',
             p_stage_sec => 60,
             p_calls     => 13,
             p_procs     => 50,
             p_workers   => 2);
end;
/
