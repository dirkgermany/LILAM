-- =====================================================================
-- LILAM Test: INSESSION / LASTTEST
--
-- Lasttest: ein Client, ein Prozess, sehr viele API-Aufrufe. Misst Durchsatz und Dauer je Aufruf.
-- Je Operation 5 Aufrufe: INFO, TRACE_START, TRACE_STOP, MARK_EVENT, PROC_STEP_DONE.
-- Der Test startet und stoppt seine Server selbst (keine Server).
--
-- Parameter (im Aufruf unten anpassbar):
--   p_ops       Operationen (Default 5000)
--   p_max_wait  max. Wartezeit in s je Pruefung (Default 300)
--
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- Die Testlogik steht im Package LT (_COMMON/01_install_testbasis.sql).
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  l_run := lt.t_lasttest(
             p_mode     => lt.c_insession,
             p_ops      => 5000,
             p_max_wait => 300);
end;
/
