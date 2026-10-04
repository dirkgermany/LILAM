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
    LASTTEST/  MASSENTEST/  PARALLELBETRIEB/  PROZESSZYKLEN/  DAUERTEST/  WAKEUP/  LASTSPITZE/
  DISPATCHER/               Client über den Dispatcher (z.B. APEX mit Connection Pool)
    LASTTEST/  MASSENTEST/  PARALLELBETRIEB/  PROZESSZYKLEN/  DAUERTEST/  WAKEUP/  LASTSPITZE/

FEATURES/                   Funktionstests einzelner Merkmale (modusübergreifend)
  BASELINE_SCOPE/  LOGTEXT_GRENZEN/  DISPATCHER_APEX/  FEHLERFAELLE/  SERVERAUSWAHL/  SPEICHER/  REGELN/  REGELN_LAST/

DAUERTEST/                  Dauertest über alle Modi gleichzeitig (Kombination der Tests)
```

Jeder Testordner enthält das Skript `test_*.sql` und einen Ordner `results/` für die Auswertungen.

Die Testlogik steht im Package `LT` (`_COMMON/01_install_testbasis.sql`): je Test eine Funktion
(`lt.t_lasttest`, `lt.t_massentest`, `lt.t_parallel`, `lt.t_zyklen`, `lt.t_wakeup`, `lt.t_lastspitze`,
`lt.t_logtext`, `lt.t_baseline_scope`, `lt.t_speicher`, `lt.t_regeln`, `lt.t_regeln_last`). Die Skripte rufen diese Funktionen mit sichtbaren, anpassbaren Parametern auf.
So kann der Dauertest dieselben Tests wiederverwenden. FEHLERFAELLE und DISPATCHER_APEX bleiben eigenständige Skripte
(sie stoppen bewusst Server bzw. legen Hilfstabellen an).

## Testarten

| Test | Inhalt | Standard-Umfang |
|---|---|---|
| LASTTEST | ein Client, ein Prozess, sehr viele API-Aufrufe; Durchsatz und Dauer je Aufruf | 5.000 Operationen = 25.000 Aufrufe |
| MASSENTEST | ein Client öffnet viele Prozesse gleichzeitig und bedient sie reihum | 200 Prozesse × 20 Operationen |
| PARALLELBETRIEB | viele Client-Jobs gleichzeitig, in vier Varianten: A gleicher Prozessname (gemeinsame Baseline), B eigene Namen (getrennte Baselines), C eigene Namen mit gemeinsamem `p_baselineScope`, D Scope `#NONE` (keine Baseline) | je Variante 10 Clients (Insession 8) × 2 Prozesse × 200 Operationen |
| PROZESSZYKLEN | viele Prozesse mit vollem Lebenszyklus parallel starten, bearbeiten und beenden (je Client 3 gleichzeitig offen); Status-Updates, Rueckleseprobe, Endzustand jedes Prozesses in `_PROC`, Verteilung auf die Worker | 10 Clients (Insession 8) × 30 Prozesse × 20 Operationen |
| DAUERTEST | Kombination der Tests über viele Stunden: ein Steuer-Job führt Teiltests mit verkleinertem Umfang aus (gewichtet zufällig oder der Reihe nach), jeder als eigener Job; dazwischen Pausen (oft > 15 s); daneben Hintergrund-Clients mit Prozesszyklen. Die Server laufen durchgehend. Daten bestandener Teiltests werden gelöscht | 10 Stunden; je Modus oder über alle Modi (`DAUERTEST/`) |
| WAKEUP | Aufrufe nach Ruhephasen des Servers von 5, 16, 30 und 65 s | nur DECOUPLED |
| LASTSPITZE | mehrere Clients senden eine Zeit lang ohne Pause; danach Erholung: alle Daten vollständig, Prozesse geschlossen, keine Routen übrig, ein neuer Prozess arbeitet wieder normal | 6 Clients × 30 s, nur DECOUPLED |
| FEATURES/BASELINE_SCOPE | prozessübergreifende Baseline: Default-Scope, `#NONE`, frei gewählter gemeinsamer Scope; INSESSION und SERVER | je Modus 7 kurze Prozesse |
| FEATURES/LOGTEXT_GRENZEN | Kürzung langer Logtexte (1.500–5.000 Zeichen, Umlaute); INSESSION und SERVER | 9 Texte je Modus |
| FEATURES/DISPATCHER_APEX | APEX/AJAX mit Connection Pool: jeder Request ein eigener Job mit leerem PGA, Trace über zwei Requests, parallele Requests, Request ohne Dispatcher, veraltete ID nach CLOSE | 13 Requests |
| FEATURES/FEHLERFAELLE | Störungen ohne Wirkung auf die Anwendung: kein Server, negative/veraltete ID, Handshake über Dispatcher, verfallene NEW_SESSION | 6 Fälle |
| FEATURES/SERVERAUSWAHL | Dispatcher wird nie als Ziel der Serverauswahl gewählt; Last verteilt sich auf die Worker (je Worker mind. 30 %), ohne und mit Dispatcher | 2 Clients × 20 Prozesse |
| FEATURES/SPEICHER | kein Speicherverlust: PGA-Wachstum je Prozess von Session/Client, Workern und Dispatcher (Median aus 5 Messblöcken, max. 100 Byte); Fallback beim Schreiben (fehlerhafte Zeile übersprungen und protokolliert, übrige geschrieben); INSESSION, SERVER, DISPATCHER. Benötigt `00_grants_als_sys.sql` | je Modus 2.000 + 5 × 1.000 Prozesse, ca. 7 min |
| FEATURES/REGELN | Rules Engine im SERVER-Modus mit eigenem Rule Set `LT_REGELN`: Laden per API und nach Neustart, Ablehnung ungültiger Rule Sets, Vorgänger/Nachfolger, Abstand, Dauer, Häufigkeit, Abweichung, Prozess- und Log-Regeln, Kontext-/Action-Regel, Drosselung, Alert-Zeile und Signal. Nur einzeln (ändert das Rule Set der Gruppe LT) | ca. 20 Prozesse, 2–3 Server, ca. 1 min |
| FEATURES/REGELN_LAST | Kosten der Regelprüfung im Server je Signaltyp (Event, Trace, Log, Prozessschritt): keine Regeln, 50 Regeln auf andere Actions, 20 passende Regeln ohne Alarm, eine anschlagende Regel gedrosselt und ungedrosselt; Median aus 3 Läufen, Grenzen relativ zu „keine Regeln“. Nur einzeln | 4 × 5 Varianten × 3 Läufe, ca. 4 min |

Eine Operation besteht aus fünf API-Aufrufen: `INFO`, `TRACE_START`, `TRACE_STOP`, `MARK_EVENT`, `PROC_STEP_DONE`.
Die Standard-Prüfung kontrolliert danach Vollständigkeit (Logs, Traces, Events, Steps), geschlossene Prozesse,
die Zählung der Baseline, übrig gebliebene Routen sowie Fehler in Client-Jobs und in `LILAM_LOG_INTERNAL`.

## Ablauf

1. LILAM installieren (`lilam.pks`, `lilam.pkb`).
2. `_COMMON/01_install_testbasis.sql` ausführen (optional vorher `00_grants_als_sys.sql` als SYS).
3. Gewünschten Test ausführen, z.B. `@DECOUPLED/SERVER/PARALLELBETRIEB/test_parallelbetrieb.sql`.
4. Ergebnis steht am Ende der Ausgabe; Übersicht aller Läufe mit `_COMMON/03_ergebnisse.sql`.

Dauertests bestehen aus zwei Skripten: `test_dauertest_start.sql` startet Server, Hintergrund-Clients und den Steuer-Job
und kehrt sofort zurück, `test_dauertest_auswertung.sql` wird nach Ablauf der Laufzeit ausgeführt. Die Teiltests eines
Dauertests stehen in `LT_RUN` mit `PARENT_RUN_ID` = run_id des Dauertests. Umfang der Teiltests im Dauertest:

| Teiltest | Umfang | Gewicht (RANDOM) |
|---|---|---|
| PROZESSZYKLEN | 4 Clients × 10 Prozesse × 10 Operationen | 4 |
| PARALLELBETRIEB | eine zufällige Variante, 4 Clients × 2 Prozesse × 50 Operationen | 3 |
| LASTTEST | 1.000 Operationen | 2 |
| MASSENTEST | 50 Prozesse × 10 Operationen | 2 |
| WAKEUP | Ruhephasen 5 und 20 s (nur decoupled) | 1 |
| LASTSPITZE | 4 Clients × 20 s (nur decoupled) | 1 |
| LOGTEXT_GRENZEN, BASELINE_SCOPE | vollständig (wenn ein Server läuft) | je 1 |

Im Dauertest über alle Modi laufen Worker und Dispatcher in derselben Gruppe. Clients im SERVER-Modus erhalten
trotzdem immer direkt einen Worker, weil Dispatcher in der Registry gekennzeichnet sind (`IS_DISPATCHER`).

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
