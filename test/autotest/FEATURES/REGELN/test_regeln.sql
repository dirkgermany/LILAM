-- =====================================================================
-- LILAM Test: FEATURES / REGELN
--
-- Prueft die Rules Engine im SERVER- und INSESSION-Modus mit einem eigenen Rule Set LT_REGELN (Versionen 1-8, 10-14):
--   L1     SERVER_UPDATE_RULES fuer die Gruppe LT (LT_S1 und LT_S2): aktives Rule Set in LILAM_RULES
--   VG     Vorgaenger: PRECEDED_BY (mit/ohne Kontext), PRECEDED_BY_WITHIN_SECS, bei Events, TRACE_START und PROCESS_UPDATE (VG-05);
--          Logs zaehlen nicht als Vorgaenger
--   NF     Nachfolger "B folgt A innerhalb 1 s" (ein ganz ausbleibendes B erkennt LILAM nicht)
--   GP/DU/OC/AV  MAX_GAP_SECONDS (Events, TRACE_START, Dezimalwert), MAX_DURATION_MS, MAX_OCCURRENCE,
--          AVG_DEVIATION_PCT nach Warm-up; AV-02 Durchschnitt unter 1 ms wird nicht ausgewertet (feste Zeitstempel)
--   PR     Prozess-Regeln: ON_START, STATUS_EQUALS, INFO_CONTAINS, MAX_OCCURRENCE, STEPS_LEFT_HIGH,
--          SUCCESS_RATE_LOW (Endstand aus CLOSE_SESSION), RUNTIME_EXCEEDED, MAX_RUNTIME_EXCEEDED
--   LG     zwei SEVERITY-Regeln, viele nicht passende Logs
--   LC     LOG_CONTAINS ohne Level (LC-01) und mit Level ERROR|TEXT (LC-02)
--   KX/TF/TH  Kontext- und Action-Regel, Trigger-Filter, Drosselung
--   A1/A2  Alert-Zeile in LILAM_ALERTS und DBMS_ALERT-Signal
--   L2-L4  Neustart, neuer Server laedt das Rule Set der Gruppe (LT_S3), Gruppe ohne Server, Ablehnung ungueltiger/fehlender
--          Rule Sets durch die API (NUM_ERR_RULE_SET, u.a. leere "action", PRECEDED_BY bei TRACE_STOP, LOG_CONTAINS ohne Text), durch laufende Server bei UPDATE_RULE
--          (bisherige Regeln bleiben aktiv, L3c) und durch den Server beim Start, Versionswechsel
--   L6     Server laden ein geaendertes Rule Set auch ohne UPDATE_RULE-Nachricht (eigene Pruefung alle 15 s, B7)
--   IS     die Szenarien VG bis TH zusaetzlich INSESSION (Pruefungen mit Praefix "IS", eigene Gruppe je Lauf, klein
--          geschrieben), dazu IS-01 ohne Gruppe keine Regeln, IS-02 GROUP_NAME im Alert wie angegeben, IS-03 Versionswechsel
--          per SERVER_UPDATE_RULES erst nach der 15-s-Pruefung, IS-04 ungueltiges Rule Set abgelehnt (einmal protokolliert),
--          IS-05 kein aktives Rule Set (IS-03 bis IS-05 warten je 16 s)
--   zuletzt: keine weiteren internen LILAM-Fehler
-- Der Test startet und stoppt seine Server selbst (LT_S1, LT_S2, kurz LT_S3) und setzt das Rule Set der Gruppe LT danach zurueck.
-- Nur einzeln ausfuehren, nicht parallel zu anderen Tests (aendert das Rule Set der Gruppe LT).
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
