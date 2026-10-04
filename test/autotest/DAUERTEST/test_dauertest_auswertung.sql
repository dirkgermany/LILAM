-- =====================================================================
-- LILAM Test: DAUERTEST ueber alle Modi (Auswertung)
--
-- Dauertest, Teil 2: Auswertung des letzten Dauertests ueber alle Modi (nach Ablauf der Laufzeit).
-- Zeigt je Teiltest und Modus Anzahl, bestandene Laeufe und die Dauer im ersten und letzten Drittel.
-- Prueft: alle Teiltests bestanden, keine Verlangsamung im Laufe der Zeit, Hintergrund-Clients vollstaendig,
-- Server-PGA stabil (mit Grants aus _COMMON/00_grants_als_sys.sql). Stoppt anschliessend die Server.
--
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- Die Testlogik steht im Package LT (_COMMON/01_install_testbasis.sql).
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  select max(run_id) into l_run from lt_run where test_name = 'DAUERTEST' and mode_name = 'INSESSION,SERVER,DISPATCHER';
  lt.dauertest_auswertung(l_run);
end;
/
