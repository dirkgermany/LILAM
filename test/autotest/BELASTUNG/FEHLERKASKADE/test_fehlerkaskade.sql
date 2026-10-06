-- =====================================================================
-- LILAM Belastungstest: FEHLERKASKADE
--
-- Szenario: Eine gemeinsame Ressource faellt aus (Tablespace voll, Deadlocks, entfernter Dienst weg).
-- Alle Anwendungen laufen in ihre Exception-Handler und protokollieren ERROR, so schnell sie koennen.
-- ERROR wird decoupled vom Client sofort direkt geschrieben (autonome Transaktion mit Commit) und
-- zusaetzlich ueber die Pipe gesendet: die Anwendung traegt die Kosten des Commits selbst.
-- Stufen mit 45 % ERROR (Maximum des Aufrufmix), steigende Clientzahl und Rate.
-- Gemessen: Dauer eines ERROR-Aufrufs (Ø/max), Commits/s, Redo/s, ob der Serverpfad mithaelt.
-- Erst SERVER, dann INSESSION als Vergleich (dort schreibt ERROR synchron alle Puffer des Prozesses).
--
-- Laufzeit: je Modus hoechstens ca. 4 min
-- =====================================================================
set serveroutput on size unlimited

declare
  l_run number;
begin
  for m in (select column_value md from table(sys.odcivarchar2list(lt.c_server, lt.c_insession))) loop
    l_run := ltb.t_stufen(
               p_test       => 'BELASTUNG_FEHLERKASKADE',
               p_mode       => m.md,
               p_workers    => 2,
               p_stages     => '4x100e45,8x100e45,16x100e45,16x200e45,16x400e45',
               p_stage_sec  => 30);
  end loop;
end;
/
