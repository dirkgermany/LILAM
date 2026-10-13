-- =====================================================================
-- LILAM Test: PERFORMANCE
--
-- Misst, was LILAM eine Anwendung kostet und wie schnell es die Daten speichert,
-- INSESSION und DECOUPLED (SERVER mit 1, 2 und 3 Servern), ohne und mit Regeln.
-- Konzept, Varianten und Ergebnisse: PERFORMANCE/README.md
--
-- Teil 1 (ohne Regeln), 3 Clients:
--   1-2  INSESSION: Dauerfeuer (100.000 Aufrufe je Client), mit Pausen (25.000 je Client, 100 ms nach je 20 Aufrufen)
--   3-5  DECOUPLED mit 1/2/3 Servern, Dauerfeuer
--   6-8  DECOUPLED mit 1/2/3 Servern, mit Pausen
--   9    DECOUPLED mit 2 Servern, Dauerfeuer, dabei 100 Ab- und Anmeldungen (CLOSE_PROCESS + NEW_PROCESS)
-- Teil 2 (Regeln im Vergleich), 5 Clients × 10.000 Aufrufe, Dauerfeuer:
--   10-11 INSESSION ohne / mit Regeln, 12-13 DECOUPLED mit 2 Servern ohne / mit Regeln
--
-- Einzelne Varianten: p_variants => '1,3' (NULL = alle).
-- Laufzeit: ca. 30-40 min (alle Varianten)
-- Nur einzeln ausfuehren (stoppt alle Test-Server, aendert das Rule Set der Gruppe LT, Messung empfindlich gegen Hintergrundlast).
--
-- Voraussetzungen: LILAM, _COMMON/01_install_testbasis.sql, _COMMON/04_install_belastung.sql,
--                  _COMMON/05_install_performance.sql; fuer CPU-Werte BELASTUNG/00_grants_belastung_als_sys.sql (als SYS)
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC, LTP_VARIANT, LTP_HIST; Bericht erneut: exec ltp.bericht(<run_id>)
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  l_run := ltp.t_performance(
             p_variants     => null,
             p_clients      => 3,
             p_calls        => 100000,
             p_calls_pause  => 25000,
             p_pause_every  => 20,
             p_pause_ms     => 100,
             p_cycles       => 100,
             p_rule_clients => 5,
             p_rule_calls   => 10000);
end;
/
