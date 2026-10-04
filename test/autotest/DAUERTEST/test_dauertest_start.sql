-- =====================================================================
-- LILAM Test: DAUERTEST ueber alle Modi (Start)
--
-- Dauertest als Kombination der Tests in allen Modi gleichzeitig (Hybridbetrieb).
-- Teil 1: startet die Server (LT_S1, LT_S2, LT_DISP), Hintergrund-Clients und den Steuer-Job und kehrt sofort zurueck.
-- Der Steuer-Job fuehrt bis zum Ende Teiltests mit verkleinertem Umfang aus: LASTTEST, MASSENTEST, PARALLELBETRIEB
-- (zufaellige Variante), PROZESSZYKLEN, WAKEUP, LASTSPITZE, LOGTEXT_GRENZEN, BASELINE_SCOPE.
-- Jeder Teiltest laeuft als eigener Job (frische Session) und prueft sich selbst; die LILAM-Daten bestandener
-- Teiltests werden danach geloescht (Speicherplatz), die Ergebnisse bleiben in LT_RUN / LT_CHECK / LT_METRIC.
-- Zwischen den Teiltests liegen Pausen: meist 0-10 s, gelegentlich 20 s bis p_pause_max_s (Ruhezustand der Server).
-- Teil 2: test_dauertest_auswertung.sql nach Ablauf der Laufzeit.
--
-- Parameter (im Aufruf unten anpassbar):
--   p_hours        Laufzeit in Stunden (Default 10)
--   p_modes        Komma-Liste aus INSESSION, SERVER, DISPATCHER
--   p_order        'RANDOM' (gewichtet zufaellig) oder 'SEQ' (der Reihe nach)
--   p_bg_clients   Hintergrund-Clients mit Prozesszyklen, reihum auf die Modi verteilt (Default 2)
--   p_pause_max_s  max. Pause zwischen Teiltests in s (Default 120)
--   p_lastspitze   gelegentliche Lastspitze einbauen (Default TRUE)
--
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- Die Testlogik steht im Package LT (_COMMON/01_install_testbasis.sql).
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  l_run := lt.dauertest_start(
             p_hours       => 10,
             p_modes       => 'INSESSION,SERVER,DISPATCHER',
             p_order       => 'RANDOM',
             p_bg_clients  => 3,
             p_pause_max_s => 120,
             p_lastspitze  => true);
end;
/
