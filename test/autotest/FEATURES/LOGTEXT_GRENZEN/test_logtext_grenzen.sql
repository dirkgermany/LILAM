-- =====================================================================
-- LILAM Test: FEATURES / LOGTEXT_GRENZEN
--
-- Logtexte werden pauschal auf 1900 Zeichen gekuerzt (Spalte INFO: 2000 Bytes).
-- Je Laenge 1500 .. 5000 (500er-Schritte) und ein Text aus 2500 Umlauten wird in beiden Modi
-- (INSESSION, SERVER) geloggt, umrahmt von zwei Marker-Zeilen.
-- Geprueft wird: Text kommt (gekuerzt) an, Bytes <= 2000, Marker bleiben erhalten.
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
  l_run := lt.t_logtext;
end;
/
