-- =====================================================================
-- LILAM Test: DECOUPLED / DISPATCHER / LASTSPITZE
--
-- Lastspitze: p_clients senden p_seconds lang ohne Pause so schnell wie moeglich.
-- Danach muss LILAM sich vollstaendig erholen: alle Daten kommen an, alle Prozesse sind geschlossen,
-- keine Routen bleiben uebrig, und ein neuer Prozess arbeitet wieder normal (Probe mit 100 Operationen).
-- Der Test startet und stoppt seine Server selbst (Worker LT_S1, LT_S2 und Dispatcher LT_DISP).
--
-- Parameter (im Aufruf unten anpassbar):
--   p_clients   gleichzeitig sendende Clients (Default 6)
--   p_seconds   Dauer der Spitze in s (Default 30)
--   p_max_wait  max. Wartezeit in s auf vollstaendige Daten (Default 300)
--
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- Die Testlogik steht im Package LT (_COMMON/01_install_testbasis.sql).
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  l_run := lt.t_lastspitze(
             p_mode     => lt.c_dispatcher,
             p_clients  => 6,
             p_seconds  => 30,
             p_max_wait => 300);
end;
/
