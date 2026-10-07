-- =====================================================================
-- LILAM Test: FEATURES / SPEICHER
--
-- Prueft, dass LILAM keinen Speicher verliert, und den Fallback beim Schreiben:
--   M1  INSESSION: PGA der Session waechst je Prozess hoechstens 100 Byte
--   M2  SERVER:    PGA von Client und Workern je Prozess hoechstens 100 Byte
--   M3  DISPATCHER: PGA von Client, Workern und Dispatcher je Prozess hoechstens 100 Byte
--       Je Modus: 2.000 Prozesse zum Aufwaermen, dann p_procs (Standard 5.000) Prozesse in 5 Bloecken,
--       je Prozess 4 x (info, trace, event, proc_step_done). Nach jedem Block wird die PGA gemessen;
--       bewertet wird der Median der Blockzuwaechse. Einmalige Spruenge des Oracle-Heaps treffen nur
--       einen Block, ein Leck dagegen jeden. Vollstaendigkeit wird mitgeprueft.
--   F1  Fallback (INSESSION und SERVER): von 5 Logs verletzt einer einen Check-Constraint
--       auf LT_SPM_LOG. Erwartet: 4 Zeilen geschrieben, die fehlerhafte uebersprungen,
--       genau ein Eintrag in LILAM_LOG_INTERNAL (ORA-02290, "row n skipped").
--   F2  keine weiteren internen LILAM-Fehler
--
-- Hintergrund: Dynamisches FORALL ... SAVE EXCEPTIONS gab in Oracle bei jedem Aufruf PGA nicht frei
-- (Dauertest run 103: Server-PGA 25 -> 95 MB in 4 h).
--
-- Der Test startet und stoppt seine Server selbst (LT_S1, LT_S2, LT_DISP).
-- Voraussetzungen: LILAM installiert, _COMMON/00_grants_als_sys.sql (v$process, v$session),
--                  _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- Die Testlogik steht im Package LT (_COMMON/01_install_testbasis.sql).
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  l_run := lt.t_speicher(p_procs => 5000);
end;
/
