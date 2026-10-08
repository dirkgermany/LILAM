-- =====================================================================
-- LILAM Belastungstest: DISPATCHER_ENGPASS
--
-- Frage: Wann wird der Dispatcher zum Flaschenhals (viele Aufrufe, viele Prozesse, viele Prozesswechsel)?
--
-- Teil A  viele Aufrufe: gleiche Laststufen mit 2 Workern direkt (SERVER) und ueber den Dispatcher.
--         Wo DISPATCHER UEBERLAST meldet und SERVER noch OK, ist der Dispatcher der Engpass.
-- Teil B  viele Prozesse: wie Teil A ueber den Dispatcher, aber mit 3.000 offenen, ruhenden Prozessen
--         (Routen-Tabelle, Routen-Cache im Dispatcher, current_processes der Worker).
-- Teil C  viele Prozesswechsel: jeder Client beendet nach 20 Aufrufen seinen Prozess und oeffnet einen neuen
--         (APEX/ORDS ohne Reconnect: ein Prozess je Request). NEW_PROCESS laeuft ueber die Steuer-Pipe des
--         Dispatchers, jeder neue Prozess kostet im Dispatcher ein SELECT auf LILAM_PROCESS_ROUTE.
-- Reconnects aus frischen Sessions (APEX mit Session State) prueft APEX_STURM.
--
-- Laufzeit: Teil A ca. 12 min, Teil B ca. 7 min, Teil C ca. 6 min
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run    number;
  c_stages constant varchar2(200) := '4x250,8x250,12x250,16x250,16x400,16x600,16x900';
begin
  -- Teil A: Durchsatz direkt gegen ueber Dispatcher (je ein Teillauf)
  l_run := ltb.t_skalierung(
             p_modes     => 'SERVER,DISPATCHER',
             p_workers   => '2',
             p_stages    => c_stages,
             p_stage_sec => 45,
             p_test      => 'BELASTUNG_DISPATCHER_ENGPASS_A');

  -- Teil B: viele offene Prozesse
  l_run := ltb.t_stufen(
             p_test       => 'BELASTUNG_DISPATCHER_ENGPASS_B',
             p_mode       => lt.c_dispatcher,
             p_workers    => 2,
             p_stages     => c_stages,
             p_stage_sec  => 45,
             p_open_procs => 3000);

  -- Teil C: viele Prozesswechsel (NEW_PROCESS/CLOSE_PROCESS alle 20 Aufrufe)
  l_run := ltb.t_stufen(
             p_test       => 'BELASTUNG_DISPATCHER_ENGPASS_C',
             p_mode       => lt.c_dispatcher,
             p_workers    => 2,
             p_stages     => '4x100p20,8x100p20,12x100p20,16x100p20,16x200p20,16x400p20',
             p_stage_sec  => 45);
end;
/
