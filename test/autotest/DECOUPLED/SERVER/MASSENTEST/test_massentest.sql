-- =====================================================================
-- LILAM Test: DECOUPLED / SERVER / MASSENTEST
--
-- Massentest: ein Client oeffnet viele Prozesse gleichzeitig und bedient sie reihum.
-- Prueft Puffer, Flush und Verwaltung vieler offener Prozesse.
-- Der Test startet und stoppt seine Server selbst (Server LT_S1).
--
-- Parameter (im Aufruf unten anpassbar):
--   p_processes  Prozesse (Default 200)
--   p_ops        Operationen je Prozess (Default 20)
--   p_max_wait   max. Wartezeit in s je Pruefung (Default 300)
--
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- Die Testlogik steht im Package LT (_COMMON/01_install_testbasis.sql).
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  l_run := lt.t_massentest(
             p_mode      => lt.c_server,
             p_processes => 200,
             p_ops       => 20,
             p_max_wait  => 300);
end;
/
