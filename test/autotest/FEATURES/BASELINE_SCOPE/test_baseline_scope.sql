-- =====================================================================
-- LILAM Test: FEATURES / BASELINE_SCOPE
--
-- Prueft den prozessuebergreifenden Durchschnitt (EWMA) ueber p_baselineScope, im INSESSION- und SERVER-Modus:
--   B1  Default-Scope (= Prozessname): 3 Neustarts mit je 2 Traces -> 1 Scope, 6 Messungen, Mittel ca. 200 ms
--   B2  ACTION_COUNT in _MON zaehlt je Prozess (1, 2), nicht ueber den Scope
--   B3  _MON.AVG_MILLIS des letzten Prozesses = Baseline des Scopes (+-1 ms; mit mehreren Servern 20 % Toleranz)
--   B4  Scope '#NONE': Baseline unveraendert, kein Scope '#NONE'
--   B5  frei gewaehlter Scope: zwei Prozessnamen teilen eine Baseline, keine eigenen Scopes
--   B6  keine internen LILAM-Fehler
-- Der Test startet und stoppt seinen Server selbst (LT_S1).
--
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- Die Testlogik steht im Package LT (_COMMON/01_install_testbasis.sql).
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  l_run := lt.t_baseline_scope;
end;
/
