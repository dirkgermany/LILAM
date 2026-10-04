-- =====================================================================
-- LILAM Test: INSESSION / DAUERTEST (Start)
--
-- Dauertest als Kombination der Tests, nur in diesem Modus. Teil 1: startet Server, Hintergrund-Clients
-- und den Steuer-Job und kehrt sofort zurueck. Der Steuer-Job fuehrt bis zum Ende Teiltests mit verkleinertem
-- Umfang aus (je als eigener Job), loescht die LILAM-Daten bestandener Teiltests und legt Pausen ein.
-- Teil 2: test_dauertest_auswertung.sql nach Ablauf der Laufzeit.
-- Fuer einen Dauertest ueber alle Modi siehe DAUERTEST/ im Hauptordner.
--
-- Parameter (im Aufruf unten anpassbar):
--   p_hours        Laufzeit in Stunden (Default 10)
--   p_order        'RANDOM' (gewichtet zufaellig) oder 'SEQ' (der Reihe nach)
--   p_bg_clients   Hintergrund-Clients mit Prozesszyklen (Default 2)
--   p_pause_max_s  max. Pause zwischen Teiltests in s (Default 120)
--   p_lastspitze   gelegentliche Lastspitze einbauen (nur decoupled, Default TRUE)
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
             p_modes       => 'INSESSION',
             p_order       => 'RANDOM',
             p_bg_clients  => 2,
             p_pause_max_s => 120,
             p_lastspitze  => false);   -- Lastspitze nur decoupled
end;
/
