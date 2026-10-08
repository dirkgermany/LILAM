# LILAM Performance-Test

Wie viel Zeit kostet LILAM eine Anwendung, und wie schnell landen die Daten in der Datenbank?
Dieser Test misst das für beide Betriebsarten von LILAM, mit realistisch gemischten Aufrufen,
ohne und mit Regeln. Alle Zahlen stammen aus dem Lauf vom 08.10.2026 (run 2118).

## Worum es geht

LILAM protokolliert und überwacht PL/SQL-Anwendungen. Eine Anwendung ruft dafür LILAM auf,
z. B. `INFO` für eine Logzeile, `TRACE_START`/`TRACE_STOP` für eine Zeitmessung, `MARK_EVENT` für
ein Ereignis oder `SET_PROCESS_STATUS` für den Status ihres Prozesses. LILAM kann auf zwei Arten arbeiten:

| Betriebsart | Wie es funktioniert | Wofür |
|---|---|---|
| **INSESSION** | LILAM läuft in der Datenbank-Session der Anwendung und schreibt selbst. | einfach, keine weiteren Prozesse |
| **DECOUPLED** | Die Anwendung schickt jeden Aufruf als Nachricht an einen oder mehrere LILAM-Server (eigene Hintergrundprozesse), die das Schreiben übernehmen. Die Anwendung wartet nicht auf das Schreiben. | Anwendung möglichst wenig bremsen, viele Anwendungen gleichzeitig |

Für einen Leser wichtig sind drei Fragen:

1. **Wie lange wartet die Anwendung auf einen LILAM-Aufruf?** (Aufrufdauer: Median und 99 %)
2. **Wie viele Aufrufe pro Sekunde schafft die Anwendung?** (Durchsatz aus Sicht der Anwendung)
3. **Wann steht alles in der Datenbank?** (Zeit bis alles gespeichert ist; im DECOUPLED-Modus kann das nach dem letzten Aufruf noch dauern)

Der Test prüft zusätzlich, dass **nichts verloren geht**: Nach jeder Variante werden alle Logs, Traces,
Ereignisse und geschlossenen Prozesse gezählt und mit den gesendeten verglichen.

## Umgebung

| | |
|---|---|
| Rechner | Fujitsu Lifebook A357 mit Windows 11 Home; Intel Core i5-7200U (2,5 GHz, 2 Kerne, 4 logische Prozessoren), 16 GB RAM |
| Datenbank | Oracle AI Database 26ai Free 23.26.0.0.0 in einer VM (3 CPU-Threads, 9,2 GB RAM laut VM) |
| Grenze der Free-Edition | Oracle Free nutzt höchstens **2 CPU-Threads**. Anwendungen (Clients), LILAM-Server und Messung teilen sich diese. |
| LILAM-Server | Leistungsstufe MID (Standard: 1.500 Nachrichten/s je Prozess, darüber bremst der Client kurz ab) |

*Anmerkung:* Die absoluten Zahlen gelten nur für diese kleine Umgebung. Übertragbar sind die
Verhältnisse: INSESSION gegen DECOUPLED, 1 gegen 2 gegen 3 Server, mit gegen ohne Regeln.

## Was genau gemessen wird

- Jeder Client ist eine eigene Datenbank-Session (Scheduler-Job) und ruft LILAM in einem festen Mix auf.
  Je 100 Aufrufe: 44 INFO, 4 WARN, 1 ERROR (im Exception-Handler, mit Fehlerstack), 10 TRACE_START,
  10 TRACE_STOP, 15 MARK_EVENT, 10 PROC_STEP_DONE, 6 SET_PROCESS_STATUS. Logtexte sind 120 Zeichen lang.
- **Dauerfeuer:** Die Clients rufen so schnell auf, wie sie können.
- **Mit Pausen:** Nach je 20 Aufrufen 100 ms Pause. Das entspricht einer Anwendung, die zwischendurch arbeitet;
  der Durchsatz ist dann durch die Pausen begrenzt (höchstens ca. 600 Aufrufe/s für 3 Clients).
- **Ab- und Anmelden:** Während die Clients feuern, schließen sie zusammen 100-mal ihren Prozess
  (`CLOSE_PROCESS`) und melden einen neuen an (`SERVER_NEW_PROCESS`).
- Jeder Aufruf wird einzeln gemessen. Die Messung selbst kostet wenige Mikrosekunden und ist in den Werten enthalten.

## Ergebnisse

Alle 13 Varianten bestanden: **keine Daten verloren, keine Fehler.** Gesamtlaufzeit des Tests 21:43 min.

### Teil 1: ohne Regeln (3 Clients)

| Variante | Aufrufe | Aufrufe/s (Anwendung) | Aufrufdauer Median | Aufrufdauer 99 % | alles gespeichert nach | davon nach dem letzten Aufruf |
|---|---|---|---|---|---|---|
| INSESSION, Dauerfeuer | 3 × 100.000 | **10.753** | 50 µs | 5 ms | 28 s | 0,4 s |
| DECOUPLED, 1 Server, Dauerfeuer | 3 × 100.000 | 1.287 | 660 µs | 31 ms | 242 s | 9 s |
| DECOUPLED, 2 Server, Dauerfeuer | 3 × 100.000 | 3.086 | 70 µs | 3 ms | 98 s | 1 s |
| DECOUPLED, 3 Server, Dauerfeuer | 3 × 100.000 | **4.934** | 60 µs | 2 ms | 61 s | 0,4 s |
| DECOUPLED, 2 Server, Dauerfeuer mit 100 Ab-/Anmeldungen | 3 × 100.000 | 5.629 | 60 µs | 2 ms | 54 s | 0,9 s |
| INSESSION, mit Pausen | 3 × 25.000 | 565 | 40 µs | 5 ms | 133 s | 0,3 s |
| DECOUPLED, 1 Server, mit Pausen | 3 × 25.000 | 582 | 80 µs | 3 ms | 129 s | 0,1 s |
| DECOUPLED, 2 Server, mit Pausen | 3 × 25.000 | 567 | 80 µs | 4 ms | 133 s | 1 s |
| DECOUPLED, 3 Server, mit Pausen | 3 × 25.000 | 580 | 80 µs | 2 ms | 130 s | 0,7 s |

### Teil 2: Regeln im Vergleich (5 Clients × 10.000 Aufrufe, Dauerfeuer)

Das Rule Set hat 13 Regeln, die zum Aufrufmix passen (auf Ereignisse, Traces, Logs und Prozess-Updates).
Die meisten werden bei jedem passenden Aufruf geprüft, schlagen aber nicht an; eine meldet ERROR (gedrosselt).

| Variante | Aufrufe/s (Anwendung) | Aufrufdauer Median | Aufrufdauer 99 % | alles gespeichert nach |
|---|---|---|---|---|
| INSESSION ohne Regeln | 15.152 | 50 µs | 4 ms | 4,2 s |
| INSESSION mit Regeln | 8.929 | 70 µs | 5 ms | 6,2 s |
| DECOUPLED, 2 Server, ohne Regeln | 1.259 | 3 ms | 19 ms | 68 s |
| DECOUPLED, 2 Server, mit Regeln | 1.279 | 3 ms | 23 ms | 57 s |

### Was die Zahlen bedeuten

- **Im Normalbetrieb kostet ein LILAM-Aufruf die Anwendung 40 bis 100 µs** (Median), in beiden Betriebsarten,
  und alles steht spätestens etwa 1 s nach dem letzten Aufruf in der Datenbank. Bei normaler Last reicht ein Server.
- **INSESSION ist bei Dauerfeuer am schnellsten** (über 10.000 Aufrufe/s mit 3 Clients), weil keine Nachrichten
  verschickt werden. Die Anwendung trägt dafür die Schreibarbeit selbst; ein ERROR kostet sie rund 10 ms
  (wird sofort mit Commit geschrieben).
- **DECOUPLED skaliert mit der Zahl der Server:** 1 Server 1.287, 2 Server 3.086, 3 Server 4.934 Aufrufe/s.
  Mit nur einem Server staut sich unter Dauerfeuer viel auf: Die Daten stehen bis zu 96 s später in der Datenbank.
- **Regeln** kosten INSESSION etwa 40 % Durchsatz (Median 50 → 70 µs je Aufruf). Im DECOUPLED-Modus war kein
  Unterschied messbar: Dort begrenzen Nachrichtenweg und CPU, nicht die Regelprüfung.
- **Abmelden** (`CLOSE_PROCESS`) wartet im DECOUPLED-Modus auf die Bestätigung des Servers. Unter Dauerfeuer steht diese
  Nachricht hinter allen anderen; die Anwendung wartet dann bis gut 1 s. Bei normaler Last dauert es 10 bis 20 ms.
  Anmelden (`NEW_PROCESS`) dauert 10 bis 50 ms.

Einzelwerte je Aufrufart (INFO, ERROR, TRACE, …) und alle Messgrößen stehen im ausführlichen Bericht
[`results/2026-10-08_run2117-2118.md`](results/2026-10-08_run2117-2118.md).

## Selbst ausführen

```sql
@_COMMON/01_install_testbasis.sql
@_COMMON/04_install_belastung.sql
@_COMMON/05_install_performance.sql
@PERFORMANCE/test_performance.sql
```

Optional vorher als SYS `BELASTUNG/00_grants_belastung_als_sys.sql` (CPU-Werte). Laufzeit ca. 22 min.
Einzelne Varianten über `p_variants`, z. B. `'1,3,10,11'`; Umfang über `p_clients`, `p_calls`,
`p_calls_pause`, `p_rule_clients`, `p_rule_calls`. Bericht erneut ausgeben: `exec ltp.bericht(<run_id>)`.
Nur einzeln ausführen: Der Test stoppt alle Test-Server, setzt kurzzeitig ein Rule Set für die Gruppe `LT`
und reagiert empfindlich auf andere Last.

## Varianten

| Nr. | Variante | Clients × Aufrufe | Server |
|---|---|---|---|
| 1 | INSESSION, Dauerfeuer | 3 × 100.000 | – |
| 2 | INSESSION, mit Pausen (100 ms nach je 20 Aufrufen) | 3 × 25.000 | – |
| 3–5 | DECOUPLED, Dauerfeuer | 3 × 100.000 | 1 / 2 / 3 |
| 6–8 | DECOUPLED, mit Pausen | 3 × 25.000 | 1 / 2 / 3 |
| 9 | DECOUPLED, Dauerfeuer mit 100 Ab- und Anmeldungen | 3 × 100.000 | 2 |
| 10–11 | INSESSION ohne / mit Regeln | 5 × 10.000 | – |
| 12–13 | DECOUPLED ohne / mit Regeln | 5 × 10.000 | 2 |
