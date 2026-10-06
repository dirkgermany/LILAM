# SYSTIMESTAMP in lilam.pkb: wo lässt es sich durch DBMS_UTILITY.GET_TIME ersetzen?

- **Datum:** 05.10.2026, Branch `IN-SESSION-Rules`
- **Anlass:** Bei den INSESSION-Regeln fiel auf, dass Zeitfunktionen je API-Aufruf messbar kosten.
- **Umfang:** 85 Stellen mit `SYSTIMESTAMP`, `CURRENT_TIMESTAMP`, `LOCALTIMESTAMP` oder `SYSDATE` in `source\package\lilam.pkb`.

## 1. Messung

Je 200.000 Aufrufe in PL/SQL, drei Runden, Oracle 23.26 Free (2 CPU-Threads, stark streuend). Skripte: Abschnitt 6.

| Ausdruck | µs je Aufruf |
|---|---:|
| `TIMESTAMP`-Variable `:= SYSTIMESTAMP` | 3–9 |
| `TIMESTAMP` mit `SYSTIMESTAMP` vergleichen (Typmix) | 4–9 |
| `SYSTIMESTAMP - TIMESTAMP` (Intervall) | 6 |
| `get_ms_diff(ts, SYSTIMESTAMP)` | 8–16 |
| `get_ms_diff(ts, ts)` (Intervall und 4× `EXTRACT`) | 3–10 |
| `SYSDATE` / `CURRENT_TIMESTAMP` | 0,5–1 |
| `DBMS_UTILITY.GET_TIME` | 0,4–0,9 |
| Differenz zweier `GET_TIME`-Werte | < 0,1 |

**Korrektur:** Die früher genannten 19 µs für `SYSTIMESTAMP` waren eine einzelne, gestörte Messung (Vergleich mit Typmix). Realistisch sind 3–9 µs; mit `get_ms_diff` kostet eine Zeitprüfung 10–25 µs, mit `GET_TIME` etwa 1 µs.

## 2. Was GET_TIME kann und was nicht

| Eigenschaft | `SYSTIMESTAMP` | `DBMS_UTILITY.GET_TIME` |
|---|---|---|
| Auflösung | µs | 1/100 s (10 ms) |
| Bezug | absolute Zeit (Zeitzone der DB) | beliebiger Startpunkt, nur Differenzen sinnvoll |
| Überlauf | nein | nach ca. 497 Tagen (2³² Hundertstel); mit `abs()` oder `mod()` abfangen |
| Speichern, über Sessions vergleichen | ja | nein (nur innerhalb einer Session; bei RAC je Instanz) |

Ersetzbar sind also nur **Intervallprüfungen innerhalb einer Session** mit Schwellen deutlich über 10 ms. Alles, was gespeichert, angezeigt, über Sessions verglichen oder auf ms genau gemessen wird, muss bei `SYSTIMESTAMP` bleiben.

## 3. Stellen, die bleiben müssen

| Zeilen | Zweck | Grund |
|---|---|---|
| 3443, 3456, 3465 (`MARK_EVENT`, `TRACE_START`, `TRACE_STOP`), 3214, 3280, 3333 | Zeitpunkt des Events/Traces, daraus `used_time` in ms | wird gespeichert, ms-genaue Dauer |
| 4239, 4258, 4300, 4346 (`DEBUG`, `INFO`, `ERROR`, `WARN`), 4131 | Zeitpunkt des Logeintrags | wird gespeichert |
| 4387–4409, 4747, 3816–3817 | Prozessstatus, Prozessende | wird gespeichert |
| 1318 (`RUNTIME_EXCEEDED`) | Laufzeit seit Prozessstart in ms | Vergleich mit gespeichertem Startzeitpunkt; nur bei vorhandener Regel |
| 1166 | Zeitstempel im Alert-Payload | geht an den Consumer |
| 853–854 (`getClientPipe`) | eindeutiger Pipe-Name | ms-genau, eindeutig je Session |
| 5286, 5389 (`expires_utc`) | Verfallszeit für `SERVER_NEW_SESSION` | wird zwischen Client und Server verglichen (UTC) |
| 2408, 2889 | Latenzstatistik beim Flush | Differenz zu gespeicherten Zeitstempeln; nur beim Flush |
| SQL-Texte und DDL-Defaults (1541, 1568, 1777–1993, 2079, 2687–2718, 3618, 3753, 3902, 5663, 5688, 6199, 6260) | Spaltenwerte, Heartbeat-Alter | laufen in SQL, betreffen den PL/SQL-Aufruf nicht |
| 6232–6250 | `SET_CLIENT_INFO` | Anzeige; nur bei Statuswechsel des Servers |

## 4. Kandidaten für GET_TIME

| Zeilen | Zweck | Schwelle | Häufigkeit | Nutzen |
|---|---|---|---|---|
| 2760, 2770–2773 (`SYNC_ALL_DIRTY`, `v_now` und `g_last_sync_all`) | Zeitsperre des Sync | 500 ms | **jeder Log-Aufruf** (`INFO`, `WARN`, `DEBUG`, ...) | **hoch**: ca. 10–25 µs je Log-Aufruf |
| 3160, 1062 (`last_touch` der Baselines), 2591/2668 | Verdrängen unbenutzter Baselines | 900 s | **jeder `TRACE_STOP` und `MARK_EVENT` mit Scope** | **mittel**: ein `SYSTIMESTAMP` je Aufruf |
| 2591, 2642–2646 (`syncBaselines`, `l_now`, `g_last_baseline_sync`) | Abgleich mit `LILAM_BASELINES` | 1500 ms | je Sync-Durchlauf (≤ 2/s) und `CLOSE_SESSION` | gering |
| 2947, 3933, 3996 (`sync_monitor/_process/_log`, `last_*_flush`) und 3592–3593 | Flush-Schwelle | 1500 ms (15 s Sicherheits-Sync) | je fälligem Prozess im Sync, `CLOSE_SESSION` | gering bis mittel (viele offene Prozesse) |
| 2794, 2802 (`last_sync_check`) | Cooldown je Prozess | 1 s | je Prozess in der Dirty-Queue je Sync | gering bis mittel |
| 1636 ff., 122 (`stabilizeInLowPerfEnvironments`) | Drosselung des Clients | 1000 ms | alle `msg_limit` Nachrichten (500–2500) | gering |
| 6470–6543 (Serverschleife) | Housekeeping und Heartbeat | 500 ms / 60 s | nur bei leerer Pipe oder nach 10.000 Schleifen | gering |
| 581–597 (`g_unknown_pids`) | Sperre für erfolglosen Reconnect | 10 s / 1 Tag | nur bei unbekannter ID | sehr gering |
| 1208, 1213 (Alert-Drosselung) | `throttle_seconds` | Sekunden | nur wenn eine Regel anschlägt | sehr gering (Alert kostet ohnehin ms) |
| 1373 ff. (INSESSION-Regelprüfung, neu) | 15 s | – | je Regelprüfung | bereits umgestellt |

Die Genauigkeit reicht überall: Alle Schwellen liegen bei 500 ms oder mehr, GET_TIME misst auf 10 ms. Die Flush- und Sync-Zeitpunkte verschieben sich dadurch um höchstens 10 ms.

## 5. Nebenbefunde

1. **Gemischte Zeitzonen:** `NEW_SESSION` setzt `processStart := current_timestamp` (Zeitzone der Session, Zeile 4818), fast alles andere nutzt `SYSTIMESTAMP` (Zeitzone der Datenbank). Weicht die Session-Zeitzone ab (z. B. APEX, Clients in anderen Zonen), misst `RUNTIME_EXCEEDED` die Laufzeit um den Zonenversatz falsch. Ebenso `last_update = current_timestamp` in den SQL-Texten (3618, 3753, 3902).
2. **`PROC_STEP_DONE` mit `SYSDATE`** (4420, 4426): sekundengenau, alle anderen Statusänderungen sind µs-genau.
3. **`g_last_check_time`** (401) wird nirgends gelesen und kann entfallen.
4. **`get_ms_diff`** selbst kostet 3–10 µs (Intervall und vier `EXTRACT`). Für ms-genaue Dauern ist es nötig; wo nur Schwellen geprüft werden, entfällt es mit GET_TIME ebenfalls.

## 6. Empfehlung

1. **Umsetzen:** `SYNC_ALL_DIRTY` (größter Effekt, jeder Log-Aufruf) und `last_touch` der Baselines (jeder Trace/Event mit Scope). Danach die Flush-Schwellen `sync_*` und `last_sync_check`, weil sie im selben Code liegen.
2. **Nicht anfassen:** alle gespeicherten Zeitpunkte und ms-Dauern (Abschnitt 3).
3. **Gesondert entscheiden:** Nebenbefunde 1 und 2 (Zeitzonen, `SYSDATE`), weil sie gespeicherte Werte ändern.
4. **Messen:** LASTTEST INSESSION vorher/nachher, Log-lastig und Trace-lastig.

Messskripte: `2026-10-05_insession_regeln_latenz.sql` (dieser Ordner); die Mikromessungen standen als anonyme Blöcke in der Sitzung (`SYSTIMESTAMP`, `GET_TIME`, Typmix, `get_ms_diff` je 200.000 Aufrufe).
