# LILAM Tests

Wiederholbare Tests für LILAM. Jeder Test prüft sich selbst und endet mit **BESTANDEN** oder **NICHT BESTANDEN**.
Alle Ergebnisse landen in den Tabellen `LT_RUN`, `LT_CHECK` und `LT_METRIC` des Testschemas.

## Struktur

```
_COMMON/                    Testbasis (einmalig installieren)
  00_grants_als_sys.sql       optionale Leserechte für Speicher-Messwerte (als SYS)
  01_install_testbasis.sql    Tabellen LT_* und Package LT
  02_aufraeumen.sql           stoppt alle Test-Server und -Jobs
  03_ergebnisse.sql           Übersicht der Testläufe

INSESSION/                  LILAM als Bibliothek in der Session der Anwendung
  LASTTEST/  MASSENTEST/  PARALLELBETRIEB/  PROZESSZYKLEN/  DAUERTEST/

DECOUPLED/
  SERVER/                   Client direkt am LILAM-Server (ohne Dispatcher)
    LASTTEST/  MASSENTEST/  PARALLELBETRIEB/  PROZESSZYKLEN/  DAUERTEST/  WAKEUP/
  DISPATCHER/               Client über den Dispatcher (z.B. APEX mit Connection Pool)
    LASTTEST/  MASSENTEST/  PARALLELBETRIEB/  PROZESSZYKLEN/  DAUERTEST/  WAKEUP/

FEATURES/                   Funktionstests einzelner Merkmale (modusübergreifend)
  BASELINE_SCOPE/  LOGTEXT_GRENZEN/  DISPATCHER_APEX/  FEHLERFAELLE/
```

Jeder Testordner enthält das Skript `test_*.sql` und einen Ordner `results/` für die Auswertungen.

## Testarten

| Test | Inhalt | Standard-Umfang |
|---|---|---|
| LASTTEST | ein Client, ein Prozess, sehr viele API-Aufrufe; Durchsatz und Dauer je Aufruf | 5.000 Operationen = 25.000 Aufrufe |
| MASSENTEST | ein Client öffnet viele Prozesse gleichzeitig und bedient sie reihum | 200 Prozesse × 20 Operationen |
| PARALLELBETRIEB | viele Client-Jobs gleichzeitig, in vier Varianten: A gleicher Prozessname (gemeinsame Baseline), B eigene Namen (getrennte Baselines), C eigene Namen mit gemeinsamem `p_baselineScope`, D Scope `#NONE` (keine Baseline) | je Variante 10 Clients (Insession 8) × 2 Prozesse × 200 Operationen |
| PROZESSZYKLEN | viele Prozesse mit vollem Lebenszyklus parallel starten, bearbeiten und beenden (je Client 3 gleichzeitig offen); Status-Updates, Rueckleseprobe, Endzustand jedes Prozesses in `_PROC`, Verteilung auf die Worker | 10 Clients (Insession 8) × 30 Prozesse × 20 Operationen |
| DAUERTEST | Prozesszyklen mit zufälligen Pausen (oft > 15 s) über viele Stunden | 3 Clients, 10 Stunden |
| WAKEUP | Aufrufe nach Ruhephasen des Servers von 5, 16, 30 und 65 s | nur DECOUPLED |
| FEATURES/BASELINE_SCOPE | prozessübergreifende Baseline: Default-Scope, `#NONE`, frei gewählter gemeinsamer Scope; INSESSION und SERVER | je Modus 7 kurze Prozesse |
| FEATURES/LOGTEXT_GRENZEN | Kürzung langer Logtexte (1.500–5.000 Zeichen, Umlaute); INSESSION und SERVER | 9 Texte je Modus |
| FEATURES/DISPATCHER_APEX | APEX/AJAX mit Connection Pool: jeder Request ein eigener Job mit leerem PGA, Trace über zwei Requests, parallele Requests, Request ohne Dispatcher, veraltete ID nach CLOSE | 13 Requests |
| FEATURES/FEHLERFAELLE | Störungen ohne Wirkung auf die Anwendung: kein Server, negative/veraltete ID, Handshake über Dispatcher, verfallene NEW_SESSION | 6 Fälle |

Eine Operation besteht aus fünf API-Aufrufen: `INFO`, `TRACE_START`, `TRACE_STOP`, `MARK_EVENT`, `PROC_STEP_DONE`.
Die Standard-Prüfung kontrolliert danach Vollständigkeit (Logs, Traces, Events, Steps), geschlossene Prozesse,
die Zählung der Baseline, übrig gebliebene Routen sowie Fehler in Client-Jobs und in `LILAM_LOG_INTERNAL`.

## Ablauf

1. LILAM installieren (`lilam.pks`, `lilam.pkb`).
2. `_COMMON/01_install_testbasis.sql` ausführen (optional vorher `00_grants_als_sys.sql` als SYS).
3. Gewünschten Test ausführen, z.B. `@DECOUPLED/SERVER/PARALLELBETRIEB/test_parallelbetrieb.sql`.
4. Ergebnis steht am Ende der Ausgabe; Übersicht aller Läufe mit `_COMMON/03_ergebnisse.sql`.

Dauertests bestehen aus zwei Skripten: `test_dauertest_start.sql` startet Server und Clients und kehrt sofort zurück,
`test_dauertest_auswertung.sql` wird nach Ablauf der Laufzeit ausgeführt.

## Voraussetzungen

- Mindestens 10 parallele Scheduler-Jobs: `job_queue_processes` im **CDB-Root** ≥ 10 (empfohlen 20).
- Oracle 18c oder neuer (`dbms_session.sleep`).
- Testprozesse heißen `LT_<run_id>_...`, Test-Server `LT_S1`, `LT_S2`, `LT_DISP` (Gruppe `LT`).
  Alle Test-Server starten mit der Leistungsstufe `C_SERVER_PERF_MID` (1.500 Nachrichten/s je Prozess).
  So stören sich Testläufe nicht und lassen sich gezielt aufräumen.
- Die Umfänge sind auf ein Notebook mit Oracle Free abgestimmt und lassen sich im `declare`-Block jedes Skripts anpassen.

## Geplant

- **BELASTUNGSTEST**: LILAM gezielt an die Grenzen führen (steigende Last bis zum Einbruch bzw. Fehler),
  in allen Modi. Ziel: Verhalten an der Grenze prüfen (keine Datenverluste ohne Protokoll, keine Auswirkung
  auf die Anwendung, saubere Erholung nach Lastende). Bekannte Grenze aus PARALLELBETRIEB run_id 27–30:
  DBMS_PIPE fällt bei mehreren gleichzeitigen Sendern auf ca. 2.800 Nachrichten/s je Pipe.
