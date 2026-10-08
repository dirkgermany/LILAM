-- =====================================================================
-- LILAM Test: FEATURES / RUECKSCHREIBUNG
--
-- Prueft, dass Daten reiner Monitoring-Prozesse (ohne Log-Aufruf) schon vor CLOSE_PROCESS in den
-- Tabellen stehen. Je Modus (INSESSION, SERVER) vier Prozesse: ein Aufruf, Pause 2 s, ein weiterer Aufruf;
-- danach liest ein Job aus fremder Session den Tabellenstand:
--   R1  nur Traces (TRACE_START/TRACE_STOP): beide Traces in LILAM_MON
--   R2  nur Events (MARK_EVENT): beide Events in LILAM_MON
--   R3  nur Fortschritt (PROC_STEP_DONE, SET_PROCESS_STATUS): STEPS_DONE und STATUS in LILAM_PROC
--   R4  nur Baseline (eigener Scope): beide Messungen in LILAM_BASELINES
--   R5  INSESSION-Gegenprobe: ein Aufruf direkt nach einem schreibenden Aufruf (500-ms-Sperre) bleibt
--       im Puffer - es gibt keinen Timer
--   R6  INSESSION: FLUSH schreibt sofort (auch in der 500-ms-Sperre), der Prozess bleibt offen
--   R7  INSESSION: FLUSH per CALL_BY_JSON; der Prozess zaehlt nach dem FLUSH weiter (ACTION_COUNT)
--   R8  INSESSION: nach CLOSE_PROCESS sind alle Traces geschrieben, der Prozess ist geschlossen
--   R9  keine internen LILAM-Fehler
-- Der Test startet und stoppt seinen Server selbst (LT_S1). Bei Erfolg werden die Testdaten geloescht.
--
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- Die Testlogik steht im Package LT (_COMMON/01_install_testbasis.sql).
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  l_run := lt.t_rueckschreibung;
end;
/
