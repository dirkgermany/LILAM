-- =====================================================================
-- LILAM Belastungstest: KAPAZITAET_SERVER
--
-- Frage: Wie viele Clients traegt ein einzelner Serverprozess?
--
-- Ein Worker (LT_S1), kein Dispatcher. Die Last steigt in Stufen: erst mehr Clients mit je 200 Aufrufen/s,
-- dann mehr Aufrufe je Client. Jede Stufe laeuft p_stage_sec Sekunden mit dem Standard-Aufrufmix
-- (INFO, WARN, 1 % ERROR, TRACE, EVENT, Fortschritt, Status). Nach zwei Stufen UEBERLAST in Folge endet der Test.
-- Ergebnis: die hoechste Stufe mit Bewertung OK (Metrik max_tragfaehig_aufrufe_s) und die Hochrechnung
-- auf Clients je Lastprofil im Bericht.
--
-- Parameter (unten anpassbar):
--   p_stages     Stufen <clients>x<aufrufe je s und client>  (siehe BELASTUNG/README.md)
--   p_stage_sec  Dauer je Stufe in s (Default 60)
--
-- Laufzeit: je Stufe ca. p_stage_sec + 10 s, insgesamt hoechstens ca. 13 min
-- Voraussetzungen: _COMMON/01_install_testbasis.sql, _COMMON/04_install_belastung.sql
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC, LTB_STAGE / LTB_SAMPLE; Bericht mit ltb.bericht(<run_id>)
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  l_run := ltb.t_stufen(
             p_test      => 'BELASTUNG_KAPAZITAET_SERVER',
             p_mode      => lt.c_server,
             p_workers   => 1,
             p_stages    => '1x200,2x200,4x200,6x200,8x200,12x200,16x200,16x300,16x450,16x650,16x900',
             p_stage_sec => 60,
             p_err_pct   => 1);
end;
/
