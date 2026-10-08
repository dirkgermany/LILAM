-- =====================================================================
-- LILAM Test: DECOUPLED / SERVER / PROZESSZYKLEN
--
-- Prozesszyklen: viele Prozesse mit vollstaendigem Lebenszyklus, je Client p_window gleichzeitig offen.
-- Je Prozess: NEW_PROCESS, Status RUNNING/HALF, Operationen, Rueckleseprobe GET_PROC_STEPS_DONE, CLOSE_PROCESS.
-- Geprueft wird der Endzustand jedes Prozesses in _PROC und die Verteilung auf die Worker.
-- Der Test startet und stoppt seine Server selbst (Server LT_S1 und LT_S2).
--
-- Parameter (im Aufruf unten anpassbar):
--   p_clients    parallele Clients (Default 10)
--   p_processes  Prozesse je Client (Default 30)
--   p_ops        Operationen je Prozess (Default 20)
--   p_window     gleichzeitig offene Prozesse je Client (Default 3)
--   p_pause_ms   max. Zufallspause zwischen Operationen (Default 20)
--
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- Die Testlogik steht im Package LT (_COMMON/01_install_testbasis.sql).
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  l_run := lt.t_zyklen(
             p_mode      => lt.c_server,
             p_clients   => 10,
             p_processes => 30,
             p_ops       => 20,
             p_window    => 3,
             p_pause_ms  => 20);
end;
/
