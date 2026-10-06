-- =====================================================================
-- LILAM Test: FEATURES / REGELN_LAST
--
-- Misst die Kosten der Regelpruefung im Server und INSESSION je Signaltyp:
--   EVENT (MARK_EVENT), TRACE (TRACE_START/TRACE_STOP), LOG (INFO), STEP (PROC_STEP_DONE)
-- je mit den Varianten
--   NONE      kein Regel
--   OTHER50   50 Regeln auf andere Actions
--   MATCH20   20 passende Regeln mit gemischten Operatoren, die nicht anschlagen
--   FIRE_THR  1 Regel, die immer anschlaegt, gedrosselt (throttle 3600 s)
--   FIRE_ALL  1 Regel, die immer anschlaegt, ungedrosselt (jedes Signal ein Alert)
-- Gemessen wird die Verarbeitungszeit des Servers je Signal: vom ersten Signal bis zur Antwort einer
-- abschliessenden synchronen Abfrage (GET_PROC_STEPS_DONE). Die Flush-Verzoegerung zaehlt so nicht mit.
-- INSESSION wird die Aufrufzeit in der Session gemessen (eigene Gruppe je Messung, Metriken is_*, Pruefungen "IS").
-- Server LT_S1 ohne Drosselung (p_perfServer 0). Je Variante p_reps Laeufe, bewertet wird der Median.
-- Pruefungen (Median relativ zu NONE, Unterschiede < 100 us gelten als gleich):
--   OTHER50 und FIRE_THR hoechstens 1,5 x, MATCH20 hoechstens 2 x; FIRE_ALL: ein Alert je Signal (Kosten nur gemessen),
--   je Modus
-- Nur einzeln ausfuehren (aendert das Rule Set der Gruppe LT, Messung empfindlich gegen Hintergrundlast).
--
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  l_run := lt.t_regeln_last(p_n => 2000, p_n_fire => 200, p_reps => 5);
end;
/
