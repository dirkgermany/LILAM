-- =====================================================================
-- LILAM Test: DECOUPLED / DISPATCHER / WAKEUP
--
-- Aufrufe nach Ruhephasen des Servers: Ist er noch registriert, kommen Aufrufe und neue Prozesse an,
-- werden die Daten persistiert? Jeder Weck-Aufruf laeuft als eigener Job (frische Session, wie APEX).
-- Der Test startet und stoppt seine Server selbst (Worker LT_S1, LT_S2 und Dispatcher LT_DISP).
--
-- Parameter (im Aufruf unten anpassbar):
--   p_idle  Ruhephasen in Sekunden (Default 5, 16, 30, 65)
--
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- Die Testlogik steht im Package LT (_COMMON/01_install_testbasis.sql).
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  l_run := lt.t_wakeup(
             p_mode => lt.c_dispatcher,
             p_idle => sys.odcinumberlist(5, 16, 30, 65));
end;
/
