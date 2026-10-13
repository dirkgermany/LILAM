# Profil des Failover-Codes mit DBMS_HPROF – Befund F3

**Datum:** 13.10.2026, 13:35–13:50 Uhr

**Anlass:** Befund F3 aus `befunde fallback.md`. `fallback` ist unter Last 16–21 % langsamer als `main` (LASTTEST run 2181–2190, LASTSPITZE run 2261–2278). Die neuen SQL-Anweisungen fallen nur je Prozess an; der Nachteil muss aus der PL/SQL-Arbeit je Meldung kommen.

**LILAM-Stand:** `fallback` 42fb44f gegen `main` 250ee2e (Package identisch mit dem 08.10.).

**Skript:** `PERFORMANCE/2026-10-13_hprof_failover.sql`
- Ein Worker LT_S1, gestartet als Scheduler-Job mit Profiling um `START_SERVER`.
- Ein Client mit Profiling: 1 Prozess, 5.000 × (info, trace_start, trace_stop, mark_event, proc_step_done) = 25.000 Aufrufe, dann CLOSE.
- Je Stand zwei Läufe. HPROF-Runs: `main` 9/10 und 13/14, `fallback` 7/8 und 11/12 (Client/Server).

Alle Zeiten mit Profiler; sie sind höher als ohne Profiler, aber zwischen den Ständen vergleichbar.

## Ergebnis

| | `main` Lauf 1 / 2 | `fallback` Lauf 1 / 2 | Mehrzeit |
|---|---|---|---|
| Client gesamt | 6.117 / 6.442 ms | 7.055 / 7.680 ms | +15 bis +19 % |
| Server Arbeitszeit (gesamt ohne `DBMS_PIPE.RECEIVE_MESSAGE`) | 4.780 / 5.117 ms | 6.126 / 6.987 ms | +28 bis +37 % |

Der Server ist der Engpass, sobald mehrere Clients senden. Deshalb wirkt sich seine Mehrzeit unter Last (LASTSPITZE) stärker aus.

### Server: Mehrkosten von `fallback` je 25.000 Meldungen

| Unterprogramm | Aufrufe | Lauf 1 | Lauf 2 | je Meldung | Ursache |
|---|---|---|---|---|---|
| `NOTEMESSAGESEQ` | 25.019 | 956 ms | 1.220 ms | **38–49 µs** | drei `JSON_VALUE` je Meldung (Laufnummer, Client-ID, Prozess-ID) plus Zugriffe auf `g_watermarks` |
| `BUILDWATERMARKKEY` | 25.001 | 101 ms | 86 ms | 4 µs | `LPAD` und Verkettung je Meldung |
| `PROCESSREQUEST` (eigene Zeit, Mehrzeit) | 25.019 | +35 ms | +74 ms | 2 µs | Aufruf von `noteMessageSeq`, Prüfungen |
| `FENCEBATCHES`, `COLLECTWATERMARKS`, `MERGE` | 40 Flushes | 6 ms | 13 ms | < 1 µs | fallen nicht ins Gewicht |

### Client: Mehrkosten von `fallback` je 25.000 Aufrufe

| Unterprogramm | Lauf 1 | Lauf 2 | je Aufruf | Ursache |
|---|---|---|---|---|
| `KEEPINRING` | 302 ms | 310 ms | 12 µs | Kopie jeder Meldung (bis 8.000 Zeichen) in den Ringpuffer, Zähler, Zeitprüfung |
| `SENDNOWAIT` (eigene Zeit, Mehrzeit) | +181 ms | +156 ms | 7 µs | Header mit Laufnummer und Client-ID zusammenbauen |
| `DBMS_PIPE.SEND_MESSAGE` (Mehrzeit) | +308 ms | +97 ms | 4–12 µs | längere Nachricht (etwa 45 Byte mehr); streut |
| `GETCLIENTID` | 81 ms | 97 ms | 3–4 µs | Funktionsaufruf je Meldung für einen festen Wert |
| `SERVERFAILED` | 79 ms | 95 ms | 3–4 µs | Funktionsaufruf je Meldung, im Normalfall nur `EXISTS` auf leerem Array |
| `RINGMSGTYPE` | 73 ms | 92 ms | 3–4 µs | `CASE` über den Request-Namen je Meldung |
| `TRIMRING` | 94 ms | 38 ms | – | 7–8 Aufrufe, Durchlauf über die bestätigten Einträge |

### Nebenbefund (auch auf `main`): JSON_VALUE in der Nachrichtenverarbeitung des Servers

`jsonString` und `jsonNumber` rufen intern `JSON_VALUE` auf. Der Server liest damit jede Nachricht mehrfach:

| Unterprogramm | Aufrufe | `main` Lauf 1 / 2 | je Aufruf |
|---|---|---|---|
| `JSONSTRING` | 55.006 | 534 / 559 ms | 10 µs |
| `JSONNUMBER` | 45.007 | 490 / 528 ms | 11 µs |
| `EXTRACTCLIENTCHANNEL` | 25.020 | 460 / 497 ms | 19 µs |
| `EXTRACTCLIENTREQUEST` | 25.020 | 284 / 285 ms | 11 µs |

Zusammen sind das rund 1,8 s je 25.000 Meldungen, also etwa 70 µs je Meldung und **35–40 % der Arbeitszeit des Servers** auf `main`.

### Messrauschen

- Das Commit am Ende von `flushBatch` kostete in Lauf 1 von `fallback` 318 ms (9 ms je Commit), in Lauf 2 nur 17 ms. Das Insert in `LILAM_LOG` kostete 331 bzw. 177 ms (`main` 150 bzw. 226 ms).
- Beides schwankt zwischen den Läufen und ist kein Unterschied der Stände.

## Vorschläge

Die Reihenfolge richtet sich nach der Wirkung. Umgesetzt wird erst nach Dirks Freigabe.

| Nr. | Vorschlag | Erwartete Wirkung | Risiko |
|---|---|---|---|
| V1 | `noteMessageSeq`: Laufnummer, Client-ID und Prozess-ID mit `INSTR`/`SUBSTR` aus dem festen Header-Format lesen, das `sendNoWait` selbst erzeugt, statt mit `JSON_VALUE`. | Server -30 bis -45 µs je Meldung, also der größte Teil der Mehrkosten von `fallback` | gering: Format und Reihenfolge bestimmt LILAM selbst; der Header steht vor jedem Anwendungstext |
| V2 | `buildWatermarkKey` je Meldung vermeiden: den Schlüssel der letzten Meldung merken (gleicher Prozess, gleicher Client) | Server -3 µs je Meldung | gering |
| V3 | Client: `g_client_id` direkt verwenden, `serverFailed` nur aufrufen, wenn `g_failed_server.COUNT > 0`, den Typ für den Ringpuffer vom Aufrufer mitgeben statt per `CASE`, `keepInRing` verschlanken | Client -10 bis -15 µs je Aufruf | gering |
| V4 | Kürzere Client-ID (z. B. SID und Startzeit in Basis 36) und damit kürzere Nachrichten | Client einige µs je Aufruf, unsicher (Messwert streut) | gering |
| V5 | **Allgemein, auch für `main`:** die Header-Felder (`msg_type`, `request`, `response`) in `extractClientChannel` und `extractClientRequest` per `INSTR`/`SUBSTR` lesen. Für Payload-Felder mit Anwendungstexten (Escapes, Umlaute) bliebe `JSON_VALUE`. | Server bis etwa -30 µs je Meldung, auch ohne Failover | mittel: betrifft jede Nachricht; braucht die volle Regression |

V1 bis V3 zusammen sollten die Mehrkosten von `fallback` größtenteils aufheben. Mit V5 dürfte der Server schneller werden als `main` heute.

## Umsetzung V1, V2, V3, V5 (13.10.2026, auf Dirks Freigabe)

**Änderungen:**

| Nr. | Umsetzung |
|---|---|
| V5 | Neue Funktion `headerValue(p_message, p_key)` liest ein Header-Feld ohne `JSON_VALUE`. `extractClientChannel` und `extractClientRequest` nutzen sie. Fällt bei jedem anderen Aufbau auf `JSON_VALUE` zurück (Header nicht am Anfang, Wert nicht abgeschlossen). |
| V1 | `noteMessageSeq` liest Laufnummer und Client-ID mit `headerValue` und die Prozess-ID mit der neuen Funktion `payloadProcessId`. Diese erkennt die Prozess-ID nur unmittelbar hinter dem Header, sonst `JSON_VALUE`. |
| V2 | `noteMessageSeq` merkt sich den Wasserstands-Schlüssel der letzten Meldung (`g_wm_last_pid/cid/key`). |
| V3 | `sendNoWait` erhält den Ringpuffer-Typ als Konstante vom Aufrufer (`p_ringType`); die Funktion `ringMsgType` entfällt. Außerdem: `g_client_id` direkt; `serverFailed` nur, wenn `g_failed_server.COUNT > 0`; `keepInRing` weist die Felder direkt im Array-Element zu (eine Kopie der Meldung weniger). |

**Gegenprobe vor den Tests:** Eine wortgleiche Kopie von `headerValue` und `payloadProcessId` wurde gegen `JSON_VALUE` geprüft, an 8 Nachrichten mit 7 Feldern: 56 Vergleiche, keine Abweichung. Geprüft wurden:
- Header von `sendNoWait` und `jsonPut` (mit Leerzeichen)
- wiederholte Meldungen (`rp`, `pin`)
- ein Log-Text mit `}` und `"seq":99`
- ein Header mit Leerzeichen; er fällt auf `JSON_VALUE` zurück

**Regression:** run 2279–2317, 39 Runs, alle bestanden.

**Profil** (HPROF-Run 15–18, je 25.000 Meldungen):

| Messwert | `main` | `fallback` vorher | `fallback` optimiert |
|---|---|---|---|
| Client-Arbeitszeit | 2.395 / 2.624 ms | 3.648 / 3.640 ms | 2.807 / 2.139 ms |
| Server `noteMessageSeq` (eigene Zeit) | – | 956 / 1.220 ms | 242 / 191 ms |
| Server `extractClientChannel` + `extractClientRequest` | 744 / 782 ms | 695 / 911 ms | 54 / 30 ms |
| Server: Header lesen insgesamt (mit `headerValue`, `payloadProcessId`) | 744 / 782 ms | 1.750 / 2.217 ms | 1.100 / 931 ms |

**CPU-Zeit ohne Profiler** (`PERFORMANCE/2026-10-13_cpu_je_meldung.sql`, `v$sesstat`, je 3 Runden zu 50.000 Aufrufen im Wechsel, Median):

| Stand | Server-CPU je Meldung | Client-CPU je Aufruf | Wanduhr Client |
|---|---|---|---|
| `main` | 136 µs | 61 µs | 8.975 ms |
| `fallback` vor V1–V5 (42fb44f) | 171 µs (+26 %) | 70 µs (+16 %) | 10.382 ms (+16 %) |
| `fallback` optimiert | 150 µs (+10 %) | 67 µs (+11 %) | 9.626 ms (+7 %) |

**Durchsatz:** Wechselvergleich run 2318–2335 sowie LASTTEST im Wechsel run 2336–2343. Er streut so stark, dass die Verbesserung darin nicht sicher nachweisbar ist:

| Test | `main` | `fallback` optimiert |
|---|---|---|
| LASTSPITZE SERVER | 27.900 / 37.898 / 23.603 | 20.336 / 46.241 / 23.654 |
| LASTSPITZE DISPATCHER | 12.548 / 12.552 / 11.158 | 7.589 / 10.971 / 11.780 |
| LASTTEST SERVER, 7 Runden (calls/s) | 6.082 / 6.761 / 5.978 / 6.291 / 7.134 / 5.872 / 5.743 | 3.330 / 3.402 / 5.312 / 5.836 / 5.011 / 5.041 / 3.686 |

Die CPU-Messung ist für solche Vergleiche auf dieser Umgebung besser geeignet.

**Was bleibt:** Server etwa +14 µs je Meldung (Laufnummern, Wasserstände, `headerValue`), Client etwa +6 µs je Aufruf (Ringpuffer, längere Nachricht).
- Weiteres Potenzial liegt in der Payload, die der Server auf beiden Ständen weiter mit `JSON_VALUE` liest (`jsonString`, `jsonNumber`, etwa 40 µs je Meldung).
- Das ist kein Failover-Thema und war nicht Teil der Freigabe.

## Fazit

- Der Mehraufwand von `fallback` saß vor allem in `noteMessageSeq` mit drei `JSON_VALUE` je Meldung im Server.
- Nach V1–V3 und V5 ist er auf etwa ein Drittel bis die Hälfte geschrumpft: Server-CPU +10 % statt +26 %, Client-CPU +11 % statt +16 %.
- Im Client kommen kleinere Posten hinzu (Ringpuffer, Header, Hilfsaufrufe).
- Unabhängig vom Failover verbraucht `JSON_VALUE` auch auf `main` 35–40 % der Arbeitszeit des Servers.
