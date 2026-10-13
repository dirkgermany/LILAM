# LILAM Performance-Bericht

**Stand:** 13.10.2026, Branch `fallback` (mit Failover, Code-Stand f6dcd44)
**Grundlage:**
- Performance-Test (run 2344)
- Vergleich mit OraOpenSource Logger 3.1.1
- CPU-Messung des Failover-Codes

Die Messskripte stehen unter `test/autotest/PERFORMANCE/`.

Dieser Bericht ersetzt den früheren Stresstest-Bericht (4 Mio. Aufrufe, Oracle 21c Free). Der frühere Bericht ist in der Git-Historie erhalten.

## Auf einen Blick

- **Ein LILAM-Aufruf kostet die Anwendung im Median 25 bis 100 µs**, in beiden Betriebsarten. Bei normaler Last steht alles wenige Zehntelsekunden bis etwa 2 s nach dem letzten Aufruf in der Datenbank, bei Überlast der Server auch später.
- **LILAM ist im Normalbetrieb um mehr als eine Größenordnung schneller als ein Logging-Werkzeug, das jeden Eintrag sofort festschreibt.**
  - OraOpenSource Logger 3.1.1 brauchte für denselben INFO-Eintrag im Median 1,4 ms.
  - LILAM brauchte 26 µs (INSESSION) bzw. 50 µs (DECOUPLED).
  - Beide Systeme verfolgen verschiedene Ziele: Logger garantiert jeden Eintrag bei der Rückkehr des Aufrufs, LILAM puffert bzw. entkoppelt.
- **Stabilität:** In allen 13 Varianten des Performance-Tests ist kein Eintrag verloren gegangen. Unter Dauerfeuer mit mehr Last, als die Server verarbeiten, können aber **einzelne Aufrufe bis zu 10 s warten**. Das ist offen (siehe „Stabilität unter Überlast“).
- **Der Failover kostet Rechenzeit:** Server +10 %, Client +11 % CPU je Meldung gegenüber dem Stand ohne Failover.

## Umgebung

| | |
|---|---|
| Rechner | Fujitsu Lifebook A357, Windows 11 Home; Intel Core i5-7200U (2 Kerne, 4 logische Prozessoren), 16 GB RAM, SSD |
| Datenbank | Oracle AI Database 26ai Free 23.26.0.0.0 in einer VirtualBox-VM (Oracle Linux 8.10) |
| Grenze der Free-Edition | höchstens **2 CPU-Threads** für alle Sessions: Anwendungen (Clients), LILAM-Server und Messung teilen sie sich |
| LILAM-Server | Leistungsstufe MID (1.500 Nachrichten/s je Prozess; darüber bremst der Client kurz ab) |

Die absoluten Zahlen gelten nur für diese kleine Umgebung, und sie streuen stark: Gleicher Code lieferte im selben Test zwischen zwei Läufen bis zum Doppelten (z. B. 17.417 und 36.037 Operationen in LASTSPITZE). Aussagekräftig sind die Verhältnisse zwischen Varianten, die unmittelbar nacheinander gemessen wurden. Auf einem Datenbankserver mit mehr CPU-Threads und schnellem Redo-Speicher sind alle Werte deutlich besser zu erwarten, vor allem der Durchsatz der Server.

## Was ein Aufruf die Anwendung kostet

Performance-Test (`test/autotest/PERFORMANCE/test_performance.sql`, run 2344, Gesamtlaufzeit 21:21 min):
- Jeder Client ist eine eigene Datenbank-Session und ruft LILAM in einem realistischen Mix auf. Je 100 Aufrufe sind das 44 INFO, 4 WARN, 1 ERROR, 10 TRACE_START, 10 TRACE_STOP, 15 MARK_EVENT, 10 PROC_STEP_DONE und 6 SET_PROCESS_STATUS.
- Jeder Aufruf wird einzeln gemessen.
- „Dauerfeuer“: Die Clients rufen ohne Pause auf.
- „Mit Pausen“: 100 ms Pause nach je 20 Aufrufen, wie in einer Anwendung, die zwischendurch arbeitet.

| Variante | Clients × Aufrufe | Aufrufe/s (Anwendung) | Aufruf Median | Aufruf 99 % | Aufruf Maximum | alles gespeichert nach |
|---|---|---|---|---|---|---|
| INSESSION, Dauerfeuer | 3 × 100.000 | 10.563 | 50 µs | 5 ms | 300 ms | 30 s |
| INSESSION, mit Pausen | 3 × 25.000 | 518 | 50 µs | 6 ms | 400 ms | 146 s |
| DECOUPLED 1 Server, Dauerfeuer | 3 × 100.000 | 2.582 | 80 µs | 5 ms | **10.000 ms** | 117 s |
| DECOUPLED 2 Server, Dauerfeuer | 3 × 100.000 | 2.230 | 80 µs | 7 ms | **10.000 ms** | 136 s |
| DECOUPLED 3 Server, Dauerfeuer | 3 × 100.000 | 2.730 | 70 µs | 4 ms | **6.600 ms** | 112 s |
| DECOUPLED 1 Server, mit Pausen | 3 × 25.000 | 525 | 100 µs | 6 ms | 300 ms | 144 s |
| DECOUPLED 2 Server, mit Pausen | 3 × 25.000 | 545 | 90 µs | 3 ms | 49 ms | 138 s |
| DECOUPLED 3 Server, mit Pausen | 3 × 25.000 | 540 | 90 µs | 3 ms | 92 ms | 139 s |
| DECOUPLED 2 Server, Dauerfeuer, 100 Ab-/Anmeldungen | 3 × 100.000 | 4.511 | 80 µs | 4 ms | 2.400 ms | 68 s |

„Alles gespeichert nach“ zählt ab dem ersten Aufruf. Nach dem **letzten** Aufruf dauerte es in diesen Varianten höchstens 2,4 s, bei Last mit Pausen höchstens 1,1 s.

**Einzelne Aufrufarten** (Median):
- INFO 50 µs (INSESSION) bzw. 90–120 µs (DECOUPLED)
- TRACE_START/STOP, MARK_EVENT, PROC_STEP_DONE, SET_PROCESS_STATUS 30–90 µs
- ERROR 6–9 ms INSESSION. ERROR wird sofort mit Commit geschrieben (Sync-Level), DECOUPLED etwa 2 ms.
- NEW_PROCESS meist 15–70 ms, einzeln bis 200 ms (Anmeldung beim Server bzw. Anlage der Tabellen-Zeilen)
- CLOSE_PROCESS DECOUPLED 40–110 µs. Es wartet nicht mehr auf den Server; früher bis gut 1 s.

### Regeln

5 Clients × 10.000 Aufrufe, Dauerfeuer, Rule Set mit 13 Regeln, die zum Aufrufmix passen:

| Variante | Aufrufe/s | Aufruf Median | Aufruf 99 % |
|---|---|---|---|
| INSESSION ohne Regeln | 14.286 | 50 µs | 4 ms |
| INSESSION mit Regeln | 12.500 | 70 µs | 4 ms |
| DECOUPLED, 2 Server, ohne Regeln | 2.092 | 2 ms | 14 ms |
| DECOUPLED, 2 Server, mit Regeln | 2.058 | 3 ms | 14 ms |

Regeln kosten INSESSION etwa 20 µs je Aufruf. Im DECOUPLED-Modus prüft der Server die Regeln; dort war kein Unterschied messbar.

Mit 5 Clients auf 2 Servern bremsen die Clients unter Dauerfeuer ab (Median 2–3 ms), weil die Server die Last nicht schneller abarbeiten. Nach dem letzten Aufruf brauchten die Server noch 11–13 s, bis alles geschrieben war (alles gespeichert nach 36–37 s).

## Vergleich mit OraOpenSource Logger

**Frage:** Ist LILAM mit all seinen Mechanismen (Puffer, Nachrichten, Ringpuffer, Failover, Regeln) im Normalbetrieb überhaupt schneller als ein verbreitetes Logging-Werkzeug?

**Messung:** `test/autotest/PERFORMANCE/2026-10-13_vergleich_logger_a_lilam.sql` und `..._b_logger.sql`.
- Eine Session schreibt 10.000 Einträge der Stufe INFO mit 120 Zeichen Text.
- Gemessen ist die Dauer jedes Aufrufs.
- Drei Runden, LILAM und Logger abwechselnd. Angegeben ist der Median der Runden.
- Logger 3.1.1 (letzter Stand 2017) lief in einem eigenen Schema mit den Einstellungen nach der Installation (Stufe DEBUG). Die Anwendung ruft ihn statisch auf.

| Variante | Aufruf Median | Aufruf 99 % | Mittel | gespeichert nach dem letzten Aufruf |
|---|---|---|---|---|
| LILAM INSESSION, gepuffert (Standard) | **26 µs** | 191 µs | 43 µs | 0,6 s |
| LILAM DECOUPLED, 1 Server, gepuffert (Standard) | **50 µs** | 1,3 ms | 255 µs | 0,3 s |
| Muster „Insert + Commit je Eintrag“ ohne Framework | 113 µs | 4,5 ms | 426 µs | sofort |
| **Logger 3.1.1** `logger.log_info` | **1.355 µs** | 6,7 ms | 1.777 µs | sofort |

**Ergebnis:**
- Im Normalbetrieb ist LILAM je Aufruf etwa **50-mal (INSESSION) bzw. 27-mal (DECOUPLED) schneller als Logger**, jeweils im Median.
- Logger ist auch deutlich langsamer als ein nacktes „Insert + Commit“ (113 µs). Seine Kosten kommen also nicht nur vom Commit, sondern aus dem, was er je Eintrag zusätzlich erfasst und prüft: Aufrufstapel, Kontext, Einstellungen.

**Einordnung:**
- Die Systeme geben unterschiedliche Garantien. Logger hat den Eintrag festgeschrieben, wenn der Aufruf zurückkehrt; die Anwendung trägt dafür die Kosten.
- LILAM puffert (INSESSION) bzw. schickt den Eintrag ab und arbeitet weiter (DECOUPLED).
  - Gepuffertes geht bei einem Absturz der Session bzw. des Servers verloren, sofern es nicht vorher festgeschrieben wurde.
  - Mit dem Failover übernimmt im DECOUPLED-Modus ein anderer Worker; der Client wiederholt aus seinem Ringpuffer.
  - Einträge bis zum Sync-Level (Standard: ERROR) schreibt auch LILAM sofort fest.
- Der Mittelwert bei LILAM DECOUPLED (255 µs) liegt deutlich über dem Median. Einzelne Aufrufe warten, wenn der Client wegen der Leistungsstufe kurz abbremst.

## Stabilität unter Überlast

- **Vollständigkeit:** In allen 13 Varianten des Performance-Tests kamen alle Logs, Traces, Ereignisse und Prozessabschlüsse an.
- **Lange Einzelaufrufe unter Dauerfeuer:** Wenn mehrere Clients ohne Pause mehr senden, als die Server abarbeiten, wartet ein einzelner Aufruf in seltenen Fällen sehr lange. Gemessen wurde das in den Varianten mit Dauerfeuer:
  - bis **10 s**, wenn der Client auf die Freigabe durch den überlasteten Server wartet (Abbremsen nach der Leistungsstufe)
  - bis **5 s**, wenn der Ringpuffer des Clients voll ist (20.000 noch nicht bestätigte Meldungen) und der Client den Server nach dem Wasserstand fragt
- **Ringpuffer voll:** Das trat in run 2344 bei Variante „2 Server, Dauerfeuer“ für alle drei Clients ein. Der Client gibt dann die ältesten Meldungen aus dem Ringpuffer auf und vermerkt das in `LILAM_LOG_INTERNAL`. Die Meldungen selbst kommen an; nur bei einem gleichzeitigen Serverausfall könnten sie nicht wiederholt werden.
- Bei Last mit Pausen gab es solche Wartezeiten nicht: höchster Einzelaufruf 49–300 ms.

Diese Wartezeiten sind bekannt und für die Überarbeitung vorgesehen (Befunde A1, A2 und F4 in der Befundliste zum Failover). Stabilität geht dabei vor Durchsatz.

## Kosten des Failovers

Der Failover (Ringpuffer im Client, Laufnummern und Wasserstände im Server) wurde gegen den Stand ohne Failover (`main`) gemessen.
- Messung: CPU-Zeit der Sessions aus `v$sesstat`, je 50.000 Aufrufe, 3 Runden im Wechsel, Median.
- Skript: `2026-10-13_cpu_je_meldung.sql`

| Stand | Server-CPU je Meldung | Client-CPU je Aufruf |
|---|---|---|
| ohne Failover (`main`) | 136 µs | 61 µs |
| mit Failover, erste Fassung | 171 µs (+26 %) | 70 µs (+16 %) |
| mit Failover, optimiert (aktueller Stand) | 150 µs (+10 %) | 67 µs (+11 %) |

Die Optimierung bestand vor allem darin, den Header einer Nachricht ohne `JSON_VALUE` zu lesen. Gemessen wurde mit dem hierarchischen Profiler; Bericht: `test/autotest/PERFORMANCE/results/2026-10-13_hprof_failover.md`.

Die Arbeitszeit des Servers geht weiterhin zu einem großen Teil in das Lesen der Nachrichten-Payload mit `JSON_VALUE`; das gilt auch ohne Failover. Hier liegt das größte verbleibende Potenzial.

## Selbst messen

```sql
-- Performance-Test (ca. 22 min, nur einzeln ausführen)
@test/autotest/_COMMON/01_install_testbasis.sql
@test/autotest/_COMMON/04_install_belastung.sql
@test/autotest/_COMMON/05_install_performance.sql
@test/autotest/PERFORMANCE/test_performance.sql

-- Vergleich mit Logger: Logger 3.1.1 in einem eigenen Schema installieren, EXECUTE an das LILAM-Schema,
-- dann Teil A und Teil B abwechselnd (siehe Kopf der Skripte)
@test/autotest/PERFORMANCE/2026-10-13_vergleich_logger_a_lilam.sql
@test/autotest/PERFORMANCE/2026-10-13_vergleich_logger_b_logger.sql
```

Für die Messungen nur einzeln ausführen: Andere Last in der Datenbank verfälscht die Zahlen.
