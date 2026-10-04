# Analyse: Speicherwachstum der LILAM-Server (aus Dauertest run 103)

**Datum:** 04.10.2026

**Befund im Dauertest:** Die Server-PGA (Summe LT_S1, LT_S2, LT_DISP) wuchs in 4 h linear von ~25 MB auf ~95 MB.

## Ergebnis

Ursache ist das Oracle-Konstrukt **`FORALL … EXECUTE IMMEDIATE … SAVE EXCEPTIONS`** (dynamisches SQL mit SAVE EXCEPTIONS). Bei jedem Aufruf bleibt PGA belegt, ungefähr proportional zur Zeilenzahl. Die LILAM-Logik selbst ist nicht die Ursache: Alle globalen Collections werden korrekt geleert.

Das Konstrukt steckt an 5 Stellen im Package-Body:

| Stelle | Zeile (lilam.pkb) | Weg |
|---|---:|---|
| `persist_log_data` | 2266 | INSESSION und Server ohne Batch |
| `persist_monitor_data` | 2459 | INSESSION und Server ohne Batch |
| `flushBatch`, LOG | 3577 | Server (SYNC_ALL_DIRTY) |
| `flushBatch`, MON | 3597 | Server (SYNC_ALL_DIRTY) |
| `flushBatch`, PROC | 3627 | Server (SYNC_ALL_DIRTY) |

## Messungen

Alle Messungen liefen in einer Session über `v$process.pga_used_mem`. Jede Messung hatte eine eigene Aufwärmrunde, gemessen wurden danach 1.000 bis 2.000 Durchläufe.

### 1. LILAM INSESSION, 6 × 1.000 Prozesse (je 4 × info/trace/event/step)

Die PGA wuchs linear um ~650 Byte je Prozess, von 2,2 MB auf 6,8 MB.

### 2. Collection-Zähler (Diagnose-Kopie LILAM_DIAG mit MEM_STATS)

Nach jeder Runde waren alle globalen Collections leer oder konstant:

- `g_sessionList`, `v_indexSession` und die Monitor-, Log-, Shadow- und Average-Maps: leer
- Dirty-Queue, Throttle-Cache, Batch-Puffer und Route-Cache: leer
- `g_baselines` = 2, `g_scope_ids` = 1 (gewollt)

Das Wachstum liegt also nicht in LILAM-Collections.

### 3. Cursor und temporäre LOBs

- `opened cursors current` blieb konstant bei 3.
- `v$temporary_lobs` blieb bei 0.

### 4. Eingrenzung nach API

| Aufruf je Prozess | Byte je Prozess |
|---|---:|
| nur NEW/CLOSE | ~0 |
| 10 × info | 560 |
| 10 × trace | 560 |
| 10 × event | 491 |
| 10 × proc_step_done | 0 |

### 5. Insert abgeschaltet (`persist_log_data` kehrt sofort zurück)

| Variante | Byte je Prozess |
|---|---:|
| mit Insert | 493 bzw. 560 |
| ohne Insert | 0 |

### 6. Isoliert ohne LILAM

Getestet wurden das Insert-Muster von `persist_log_data` und eine leere Kopie von LILAM_LOG. Die Indizes spielen keine Rolle.

| Variante (10 Zeilen je Aufruf) | Byte je Aufruf |
|---|---:|
| dynamisch + SAVE EXCEPTIONS | 393–570 |
| dynamisch ohne SAVE EXCEPTIONS | 0 |
| statisch + SAVE EXCEPTIONS | 0 |
| ohne SYS_CONTEXT bzw. ohne Timestamp-Liste | unverändert ~520 |

| dynamisch + SAVE EXCEPTIONS | Byte je Aufruf |
|---|---:|
| 1 Zeile | 128 |
| 10 Zeilen | 570 |
| 100 Zeilen | 4.013 |
| nicht autonom, 10 Zeilen | 393 |

Ergebnis: ~40 Byte je Zeile plus Grundbetrag, unabhängig von autonomer Transaktion, Tabelle und Index.

### 7. Gegenprobe in LILAM_DIAG ohne SAVE EXCEPTIONS (alle 5 Stellen)

| Aufruf je Prozess | Byte je Prozess |
|---|---:|
| 10 × info | 37 (Rauschen) |
| 10 × trace | 0 |
| 10 × event | 0 |
| 4 × alles, zweimal gemessen | 0 und 0 |

Die Größenordnung passt zum Dauertest. Die Server haben in 4 h mehrere Millionen Zeilen geschrieben (allein jede LASTSPITZE bringt ~105.000 Zeilen), das ergibt ~70 MB.

## Zweiter, kleinerer Fund (Code-Analyse, nicht gemessen)

`g_dispatch_route_cache` im Dispatcher (`resolveDispatchTarget`) wird nie bereinigt. Jeder Prozess, der je über den Dispatcher lief, bleibt mit einem Eintrag (process_id → Pipe-Name) im Speicher. Bei vielen kurzen Prozessen wächst der Dispatcher dadurch dauerhaft, wenn auch deutlich langsamer.

## Lösungsvorschlag (noch nicht umgesetzt)

1. **SAVE EXCEPTIONS entfernen.** Im Normalfall läuft ein einfaches `FORALL … EXECUTE IMMEDIATE` (gleich schnell). Nur im Fehlerfall folgen `ROLLBACK` und dieselben Zeilen einzeln, jede mit eigenem Exception-Handler. Fehlerhafte Zeilen werden wie bisher übersprungen und in LILAM_LOG_INTERNAL protokolliert, die guten bleiben erhalten. Die Semantik ist also unverändert, und der Fehlerpfad ist selten.
2. **Dispatcher:** Den Eintrag in `g_dispatch_route_cache` nach dem Weiterleiten von `CLOSE_SESSION` löschen.
3. **Test:** Einen kurzen Speichertest (`FEATURES/SPEICHER`) aufnehmen, der in einer Session 1.000 Prozesse öffnet und schließt und das PGA-Wachstum je Prozess prüft. So fällt eine Regression sofort auf und nicht erst nach Stunden.

## Aufräumen

- Das Diagnose-Package `LILAM_DIAG` ist wieder gelöscht. Seine Quellen liegen unter `Test\_DIAG\`.
- Testtabellen `LT_MEM_*` sind gelöscht.
- Einträge mit den Prozessnamen `LT_MEM_*` aus den Messungen stehen noch in den LILAM-Tabellen.
