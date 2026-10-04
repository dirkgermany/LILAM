-- =====================================================================
-- LILAM Test: INSESSION / PARALLELBETRIEB
--
-- Parallelbetrieb: mehrere Client-Jobs arbeiten gleichzeitig, in vier Varianten (je ein eigener Testlauf):
--   A  gleicher Prozessname, Default-Scope       -> 1 gemeinsame Baseline
--   B  eigener Prozessname je Client             -> 1 Baseline je Client, kein Uebersprechen
--   C  eigene Namen, gemeinsamer p_baselineScope -> 1 gemeinsame Baseline
--   D  gleicher Prozessname, Scope '#NONE'      -> keine Baseline-Daten
-- Der Test startet und stoppt seine Server selbst (keine Server).
--
-- Parameter (im Aufruf unten anpassbar):
--   p_variants   auszufuehrende Varianten (Default 'ABCD')
--   p_clients    parallele Clients je Variante (Default 8)
--   p_processes  Prozesse je Client (Default 2)
--   p_ops        Operationen je Prozess (Default 200)
--
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- Die Testlogik steht im Package LT (_COMMON/01_install_testbasis.sql).
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  l_run := lt.t_parallel(
             p_mode      => lt.c_insession,
             p_variants  => 'ABCD',
             p_clients   => 8,
             p_processes => 2,
             p_ops       => 200);
end;
/
