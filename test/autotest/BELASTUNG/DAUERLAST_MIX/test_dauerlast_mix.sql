-- =====================================================================
-- LILAM Belastungstest: DAUERLAST_MIX
--
-- Frage: Was passiert unter Dauerlast mit Updates auf Prozesse, Ereignisse, Traces und Logs,
--        wenn ERROR (wird decoupled zusaetzlich direkt geschrieben) einen wachsenden Anteil hat?
--
-- Realistischer Betrieb: 500 ruhende, lang laufende Anwendungsprozesse sind offen; 8 Clients arbeiten
-- dauerhaft mit je 150 Aufrufen/s und beenden alle 500 Aufrufe ihren Prozess (CLOSE_SESSION, NEW_SESSION),
-- wie orchestrierte kurze Jobs. Vier Stufen zu je 5 min mit 0, 1, 5 und 20 % ERROR.
-- Gemessen: Dauer eines ERROR-Aufrufs gegenueber anderen Aufrufen, Commits/s und Redo, Rueckstau,
-- Sichtbarkeitsverzug, Server-PGA ueber die Zeit, CLOSE/NEW_SESSION unter Last.
-- Erst SERVER (2 Worker), dann DISPATCHER (2 Worker); jeder Modus ein eigener Lauf.
--
-- p_rate auf ca. 60 % der in KAPAZITAET_SERVER bzw. SKALIERUNG gemessenen Grenze setzen:
-- Dauerlast soll tragfaehig sein, sonst misst der Test nur die Ueberlast.
--
-- Laufzeit: je Modus ca. 22 min, insgesamt ca. 45 min
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run    number;
  l_rate   number := 150;     -- Aufrufe/s je Client
  l_stages varchar2(200);
begin
  l_stages := '8x' || l_rate || 'e0,8x' || l_rate || 'e1,8x' || l_rate || 'e5,8x' || l_rate || 'e20';
  for m in (select column_value md from table(sys.odcivarchar2list(lt.c_server, lt.c_dispatcher))) loop
    l_run := ltb.t_stufen(
               p_test       => 'BELASTUNG_DAUERLAST_MIX',
               p_mode       => m.md,
               p_workers    => 2,
               p_stages     => l_stages,
               p_stage_sec  => 300,
               p_proc_ops   => 500,
               p_open_procs => 500,
               p_stop_after => 0);       -- alle Stufen laufen, auch nach UEBERLAST
  end loop;
end;
/
