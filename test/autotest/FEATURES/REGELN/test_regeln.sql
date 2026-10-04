-- =====================================================================
-- LILAM Test: FEATURES / REGELN
--
-- Prueft die Rules Engine im SERVER-Modus mit einem eigenen Rule Set LT_REGELN (Versionen 1-5):
--   L1     Laden per SERVER_UPDATE_RULES, Eintrag in der Registry
--   VG     Vorgaenger: PRECEDED_BY (mit/ohne Kontext), PRECEDED_BY_WITHIN_SECS, bei Events und TRACE_START;
--          Logs zaehlen nicht als Vorgaenger
--   NF     Nachfolger "B folgt A innerhalb 1 s" (ein ganz ausbleibendes B erkennt LILAM nicht)
--   GP/DU/OC/AV  MAX_GAP_SECONDS (Events, TRACE_START, Dezimalwert), MAX_DURATION_MS, MAX_OCCURRENCE,
--          AVG_DEVIATION_PCT nach Warm-up
--   PR     Prozess-Regeln: ON_START, STATUS_EQUALS, INFO_CONTAINS, MAX_OCCURRENCE, STEPS_LEFT_HIGH,
--          SUCCESS_RATE_LOW (Endstand aus CLOSE_SESSION), RUNTIME_EXCEEDED, MAX_RUNTIME_EXCEEDED
--   LG     zwei SEVERITY-Regeln, viele nicht passende Logs
--   KX/TF/TH  Kontext- und Action-Regel, Trigger-Filter, Drosselung
--   A1/A2  Alert-Zeile in LILAM_ALERTS und DBMS_ALERT-Signal
--   L2-L4  Neustart, ungueltige/fehlende Rule Sets werden abgelehnt, Versionswechsel
--   zuletzt: keine weiteren internen LILAM-Fehler
-- Der Test startet und stoppt seinen Server selbst (LT_S1) und setzt dessen Rule Set danach zurueck.
-- Nur einzeln ausfuehren, nicht parallel zu anderen Tests (aendert das Rule Set von LT_S1).
--
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- Die Testlogik steht im Package LT (_COMMON/01_install_testbasis.sql).
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  l_run := lt.t_regeln;
end;
/
