# PGA der Worker im Branch fallback – Diagnose zu Befund F2

**Datum:** 13.10.2026, 11:35–12:12 Uhr

**Anlass:** Befund F2 aus `befunde fallback.md`.
- In SPEICHER run 2177 und 2192 wuchs die PGA der Worker im Modus SERVER im Median um 107 bzw. 66 B je Prozess. Auf `main` (run 2114) waren es 0 B; die Grenze liegt bei 100 B.
- Dazu kamen Sprünge um etwa ±33 MB in einzelnen Messblöcken.

**LILAM-Stand:**
- `fallback` 42fb44f (mit B2 und F1)
- zum Vergleich `main` 250ee2e

**Skript:** `FEATURES/SPEICHER/2026-10-13_pga_worker_diag.sql`
- Last wie SPEICHER SV: 2.000 Prozesse zum Aufwärmen, dann 5 Blöcke zu 1.000 Prozessen, je Prozess 4 × (info, trace, event, step).
- Ein Sampler-Job zeichnet alle 0,2 s je Server-Session auf: `v$process` (PGA) und `v$session` (SQL-ID, PL/SQL-Unterprogramm, Wartezustand). Die Daten liegen in `LT_DIAG_PGA`.

## Ergebnis

**Der Failover-Code verliert keinen Speicher.** Die 33-MB-Sprünge sind vorübergehend. Sie treten auch in Client-Sessions auf, also unabhängig vom Failover-Code. Ihre Ursache liegt in Oracle und ließ sich mit den vorhandenen Rechten nicht bestimmen.

| Messung | Stand | Zuwachs je Block (B je Prozess) | Median | Gesamt über 5.000 Prozesse | Sprünge > 4 MB | Laufzeit |
|---|---|---|---|---|---|---|
| 1 Worker | `fallback` | 21, -21, 66, -35, 232 | 21 B | 263 KB | keine | 232 s |
| 1 Worker | `main` | -54, 66, 0, 66, 0 | 0 B | 78 KB | keine | 169 s |
| 2 Worker + Dispatcher (Summe der Worker) | `fallback` | 122, 197, 0, -36, 66 | 66 B | 339 KB | keine | 157 s |
| 2 Worker + Dispatcher (Summe der Worker) | `main` | -7, 12, 184, 12, 66 | 12 B | 294 KB | keine | 169 s |

- Die PGA wächst in Schritten von 64 KB. Bei 1.000 Prozessen je Block ergibt ein Schritt 65 B je Prozess.
- Die Werte je Block bestehen also aus null bis drei solchen Schritten und schwanken zufällig.
- Über alle 5.000 Prozesse liegen `fallback` und `main` mit zwei Workern praktisch gleich (68 gegen 59 B je Prozess).
- Mit einem Worker liegt `fallback` höher. Das stammt aus einem einzigen Block (232 B); die übrigen Blöcke entsprechen `main`.
- `fallback` braucht im Mittel etwa 1 MB mehr PGA je Worker (6,7 gegen 5,6 MB). Der Betrag ist konstant und wächst nicht; vermutlich ist es der zusätzliche Code.

SPEICHER selbst mit dem F1-Stand:

| Run | Bedingung | Ergebnis | SV Worker (Median) | DP Worker (Median) | Sprünge 33 MB |
|---|---|---|---|---|---|
| 2217 | 30 min nach REGELN_LAST | OK 19/19, 374 s | 6 B | 96 B | keine |
| 2219 | direkt nach REGELN_LAST (2218) | OK 19/19, 367 s | 16 B | 66 B | IS-Client +33 MB, DP-Worker +33/-33 MB |

## Die 33-MB-Sprünge

In run 2219 hat der Sampler den Sprung eingefangen. Session LT_S2, Job-Slave J004:

| Zeit | PGA in Benutzung | SQL-ID | Wartezustand |
|---|---|---|---|
| 12:05:01,5 | 6.174 KB | `bwsc6bsr8y89f` | pipe get |
| 12:05:01,7 | **39.208 KB** (+33 MB) | `dy38sj29zz4f6` | **direct path sync** |
| bis 12:05:56 | ~39.100 KB | wechselnd (normaler Betrieb) | pipe get u. a. |
| 12:05:56,5 | 6.206 KB (-33 MB) | `bwsc6bsr8y89f` | buffer busy waits |

**Beobachtungen:**
- `dy38sj29zz4f6` ist eine Anweisung des normalen Betriebs. Sie erscheint ständig, auch in den Läufen ohne Sprung; vermutlich ist es ein INSERT des Flush. Nur in diesem einen Fall wartete sie auf `direct path sync`.
- Derselbe Sprung trat in derselben Zeitspanne in der **Client-Session** des Tests auf (INSESSION, Block 4: +33.720 B je Prozess, danach SV-Client -33.757 B). Diese Session führt keinen Failover-Code aus.
- Bisher kamen die Sprünge nur direkt nach REGELN_LAST vor: run 2177, 2192 und 2219. Ohne diese Vorgeschichte gab es sie in vier Läufen nicht (2217 und die vier Diagnoseläufe).
- Auf `main` lief SPEICHER am 08.10. ebenfalls direkt nach REGELN_LAST (run 2114), ohne Sprung. Das ist eine einzelne Beobachtung, kein Gegenbeweis.

**Widerlegte Vermutung:** neue Extents beim Wachstum geleerter Tabellen. Eine Hilfstabelle (`LT_DIAG_EXT`) ist auf 208 MB mit 17 Extents zu 8 MB gewachsen; die PGA der Session blieb unverändert bei 5.201 KB.

**Text der Anweisung** (von Dirk als SYS ermittelt, 13.10.2026):

`dy38sj29zz4f6` = `update LILAM_PROC set process_end = systimestamp, last_update = systimestamp where id = :PH_PROCESS_ID`

- Das ist das Schließen eines Prozesses in `persist_close_process`, dynamisch über `DBMS_SQL` in einer autonomen Transaktion. Diese Variante kommt ohne Info, Status und Schritte aus.
- Die Prozedur ist identisch mit `main`; der Cursor wird auch im Fehlerfall geschlossen.
- Sie läuft im Server bei jedem CLOSE und INSESSION in der Client-Session. Das erklärt, warum der Sprung in beiden Session-Arten vorkommt.

**Weiter offen:**
- Warum dieses `UPDATE` über den Index auf `ID` einmalig auf `direct path sync` wartet und dabei 33 MB belegt, bleibt ohne `v$sql_plan`, `v$process_memory` und `v$sesstat` offen.
- Auffällig an `LILAM_PROC`:
  - Die Optimizer-Statistiken stammen von vor dem Leeren der Tabellen (`num_rows` 150.914).
  - `ID` hat keinen Primärschlüssel, nur den nicht eindeutigen Index `LILAM_PROC_IX_ID`.
  - Beides ist auf `main` genauso und hat mit dem Failover nichts zu tun.

## Bewertung

- Der Sprung entsteht im `UPDATE` beim Schließen eines Prozesses, einem Codeteil, den `fallback` nicht verändert hat.
- Ein Leck des Failover-Codes liegt nicht vor. Das Wachstum entspricht `main`, und die Sprünge werden nach etwa einer Minute wieder freigegeben.
- Gefährlich wäre ein Sprung nur, wenn er sich in vielen Sessions gleichzeitig ereignet. Er betraf aber jeweils eine Session, und er verschwand wieder.
- Die Prüfung in SPEICHER (Median über 5 Blöcke) fängt einen einzelnen Sprung ab. In run 2177 lag der Median trotzdem knapp über der Grenze (107 B); dort lagen auch die übrigen Blöcke hoch (121, 80, 107).
