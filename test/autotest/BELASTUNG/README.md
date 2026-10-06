# LILAM Belastungstests

Die Belastungstests führen LILAM gezielt an seine Grenzen. Sie beantworten vier Fragen:

| Frage | Szenario |
|---|---|
| Wie viele Clients trägt ein Serverprozess? | `KAPAZITAET_SERVER` |
| Was bringen mehrere Server, mit und ohne Dispatcher? | `SKALIERUNG` |
| Was passiert unter Dauerlast mit Prozess-Updates, Events, Traces und Logs, gemischt mit ERROR? | `DAUERLAST_MIX`, `FEHLERKASKADE` |
| Wann wird der Dispatcher zum Flaschenhals? | `DISPATCHER_ENGPASS`, `APEX_STURM` |
| Zusätzlich: Was passiert, wenn alle Ketten gleichzeitig starten? | `BATCHSTART` |

Alle Ergebnisse hängen an der Hardware. Die Werte einer Umgebung (z. B. Oracle Free mit 2 CPU-Threads) gelten nur dort. Übertragbar sind die Form der Kurven, die Reihenfolge der Engpässe und das Verhältnis zwischen den Varianten (z. B. Dispatcher gegen direkt).

## Methode

**Laststufen statt Dauerfeuer.** Jede Stufe läuft eine feste Zeit (Standard 60 s) mit einer festen Zahl von Clients. Jeder Client sendet eine feste Rate (Aufrufe/s), gleichmäßig verteilt. Das entspricht einer Anwendung mit Arbeitsvorrat: Wird ein Aufruf gebremst, holt der Client danach auf. Die Stufen steigen, bis LILAM nicht mehr mithält; nach zwei Stufen `UEBERLAST` in Folge endet der Test (`p_stop_after`).

**Stufenangabe:** `<clients>x<rate>[e<err%>][n<prozesse>][p<aufrufe je prozess>]`, Stufen durch Komma getrennt.

| Teil | Bedeutung | Beispiel |
|---|---|---|
| `8x200` | 8 Clients mit je 200 Aufrufen/s | 1.600 Aufrufe/s gesamt |
| `e5` | 5 % der Aufrufe sind ERROR (0–45) | `8x200e5` |
| `n20` | jeder Client öffnet zu Beginn 20 Prozesse und verteilt die Aufrufe | `16x100n20` |
| `p50` | nach 50 Aufrufen schließt der Client den Prozess und öffnet einen neuen | `8x100p50` |

**Aufrufmix** je 100 Aufrufe (realistische Anwendung, Log-Level INFO):

| Aufruf | Anzahl |
|---|---|
| INFO | 45 − ERROR-Anteil |
| WARN | 4 |
| ERROR (im Exception-Handler, mit Fehlerstack) | `e` (Standard 1) |
| TRACE_START + TRACE_STOP | 10 + 10 |
| MARK_EVENT (5 Kontexte) | 15 |
| PROC_STEP_DONE | 10 |
| SET_PROCESS_STATUS | 6 |

Logtexte sind 120 Zeichen lang (`p_text_len`).

**Beobachter-Job.** Neben den Clients läuft je Stufe ein Beobachter:
- Alle 2 s ein Messpunkt in `LTB_SAMPLE`: gesendete und persistierte Logs (Rückstau), Nachrichtenrate der Worker und des Dispatchers aus der Registry, offene Prozesse, Server-PGA, CPU des Hosts, Commits/s, Redo/s, neue interne Fehler.
- Jede Sekunde ein **Probe-Log** über einen eigenen Prozess. Gemessen wird, wann es in `LILAM_LOG` sichtbar ist (Ende-zu-Ende-Verzug, wie ihn ein Monitoring-Dashboard erlebt).

**Bewertung je Stufe.** `OK` nur, wenn alles gilt, sonst `UEBERLAST` mit Gründen:

| Kriterium | Grenze |
|---|---|
| Clients ungebremst | erreicht ≥ 95 % der angebotenen Aufrufe |
| Anwendung unbeeinträchtigt | kein normaler Aufruf > 100 ms (ohne ERROR, NEW_SESSION, CLOSE_SESSION) |
| ERROR | kein ERROR-Aufruf > 500 ms (`p_max_err_ms`; Direktschreiben mit Commit, siehe H6) |
| CLOSE_SESSION | keine Antwort des Servers ausgeblieben (Client wartet 1 s, siehe H5) |
| LILAM hält mit | Rückstau wächst in der zweiten Stufenhälfte nicht dauerhaft |
| Sichtbarkeit | Verzug der Probe-Logs ≤ 5 s (`p_max_lag_ms`) |
| Prozesse | jedes NEW_SESSION liefert eine gültige ID |
| Vollständigkeit | nach Lastende innerhalb `p_drain_max` (120 s) alles persistiert |
| Stabilität | keine neuen Einträge in `LILAM_LOG_INTERNAL`, keine Fehler in den Client-Jobs |

**Prüfungen (BESTANDEN/NICHT BESTANDEN)** betreffen nicht die Kapazität, sondern das Verhalten an der Grenze: kein Datenverlust ohne Eintrag in `LILAM_LOG_INTERNAL`, keine Exceptions in der Anwendung, alle Server laufen nach der Last, und ein neuer Prozess arbeitet danach wieder normal (Probe mit 100 Operationen).

**Kapazitätsangabe.** Die höchste Stufe mit `OK` steht als Metrik `max_tragfaehig_aufrufe_s` in `LT_METRIC`. Der Bericht rechnet sie auf Clients je Lastprofil um (Nachtbatch 200 Aufrufe/s, Sachbearbeitung 20/s, sparsamer Hintergrundjob 2/s).

## Szenarien

| Szenario | Modus, Server | Stufen | Laufzeit ca. |
|---|---|---|---|
| `KAPAZITAET_SERVER` | SERVER, 1 Worker | 1→16 Clients × 200/s, dann 16 × 300…900/s | ≤ 13 min |
| `SKALIERUNG` | SERVER 1/2/3 Worker, DISPATCHER 2/3 Worker | 4→14 Clients × 250/s, dann 14 × 400…900/s | 30 min |
| `DAUERLAST_MIX` | SERVER und DISPATCHER, je 2 Worker | 8 × 150/s mit 0, 1, 5, 20 % ERROR, je 5 min; Prozesswechsel alle 500 Aufrufe; 500 ruhende Prozesse | 45 min |
| `DISPATCHER_ENGPASS` | A: SERVER/DISPATCHER je 2 Worker; B: + 3.000 offene Prozesse; C: Prozesswechsel alle 20 Aufrufe | wie SKALIERUNG bis 16 Clients | 25 min |
| `APEX_STURM` | DISPATCHER, 2 Worker | 2, 5, 10, 15 Requests/s, jeder Request ein Job mit leerem PGA und Reconnect | 6 min |
| `BATCHSTART` | SERVER und DISPATCHER, je 2 Worker | 8 × 10, 16 × 20, 16 × 50 Prozesse gleichzeitig öffnen | 4 min |
| `FEHLERKASKADE` | SERVER (2 Worker) und INSESSION | 45 % ERROR, 4→16 Clients, 100→400/s | 8 min |

Empfohlene Reihenfolge: `KAPAZITAET_SERVER` zuerst. Aus ihrem Ergebnis die Rate in `DAUERLAST_MIX` auf etwa 60 % der Grenze setzen (Variable `l_rate`).

## Hypothesen aus dem Code

Die Tests sollen diese Vermutungen bestätigen oder widerlegen. Zeilen beziehen sich auf `source/package/lilam.pkb` (Stand Branch `claude`, 06.10.2026).

1. **Pipe-Grenze je Server (H1).** Schreiben mehrere Sessions in dieselbe Pipe, fällt `DBMS_PIPE` auf ca. 2.800 Nachrichten/s (PARALLELBETRIEB run 27–30). Ein Worker hat genau eine Datenpipe. Erwartung: Die Grenze eines Servers liegt bei dieser Rate, nicht bei seiner Schreibleistung.
2. **Dispatcher = eine Pipe für alle (H2).** Ist ein Dispatcher gesetzt, schicken Clients jede Nachricht an ihn (`getServerPipeForSession`, Z. 915). Er parst jede Nachricht (`JSON_QUERY`) und sendet sie erneut (`processRequest`, Z. 6548). Erwartung: Mit Dispatcher steigt die Grenze nicht mit der Zahl der Worker; sie liegt eher unter der eines einzelnen direkt angesprochenen Workers, weil jede Nachricht zwei Pipes durchläuft.
3. **Routen-Cache (H3).** Der erste Aufruf jedes Prozesses und jeder Aufruf nach `CLOSE_SESSION` kostet im Dispatcher ein `SELECT` auf `LILAM_PROCESS_ROUTE` (`resolveDispatchTarget`, Z. 5906). Prozesswechsel (Teil C) belasten den Dispatcher daher stärker als reine Aufrufe.
4. **Prozess-Lebenszyklus im Worker (H4).** Je Prozess schreibt der Worker synchron: NEW_SESSION (Prozesszeile), INFO an den Serverprozess, Route (Insert + Commit), Registry (Update + Commit); bei CLOSE_SESSION Persistierung, Route löschen (Commit), Registry (Commit), INFO (Z. 5442, 5232). Während dieser Commits liest der Worker keine Nachrichten.
5. **CLOSE_SESSION wartet (H5).** Der Client wartet bis 1 s auf die Antwort des Servers (`close_sessionRemote`, Z. 4135), und die Nachricht steht in der Datenpipe hinter allen anderen. Bei Rückstau kostet jedes CLOSE_SESSION die Anwendung bis zu 1 s.
6. **ERROR kostet die Anwendung einen Commit (H6).** Decoupled schreibt der Client ERROR sofort selbst (`writeLogDirect`, autonome Transaktion mit Commit, Z. 4314) und sendet es zusätzlich an den Server. Erwartung: ERROR dauert ein Vielfaches eines INFO; bei vielen ERROR wird der Commit-Durchsatz (log file sync) zur Grenze, nicht die Pipe.
7. **Volle Pipe bremst die Anwendung (H7).** `sendNoWait` versucht 3 × mit 1 s Timeout und je 0,3 s Pause (Z. 1697), also bis ca. 3,6 s je Aufruf. Danach geht die Nachricht verloren und steht in `LILAM_LOG_INTERNAL`. Die Pipe fasst 16 MB (`C_MAX_SERVER_PIPE_SIZE`), bei ca. 400–500 Byte je Nachricht rund 35.000 Nachrichten.
8. **NEW_SESSION unter Ansturm (H8).** NEW_SESSION wartet höchstens 3 s (`C_TIMEOUT_NEW_SESSION_SEC`) und liefert sonst −20110. Ohne Dispatcher fragt jeder Client vorher die Registry ab (`getServerPipeAvailable`). Erwartung bei BATCHSTART: lange NEW_SESSION-Zeiten, erst ab sehr vielen gleichzeitigen Starts Fehlschläge.
9. **Index auf INFO (H9).** `LILAM_LOG_IX_INFO` indiziert die Spalte `INFO` (bis 2.000 Byte, Z. 2084). Jeder Log-Insert pflegt diesen Index mit. Kein Testziel, aber ein Kandidat, falls die Schreibleistung der Worker die Grenze ist.

## Voraussetzungen

- LILAM, `_COMMON/01_install_testbasis.sql` und `_COMMON/04_install_belastung.sql` installiert.
- Optional `BELASTUNG/00_grants_belastung_als_sys.sql` als SYS (CPU, Commits, Redo) und `_COMMON/00_grants_als_sys.sql` (PGA).
- `job_queue_processes` ≥ Clients + Worker + Dispatcher + 2. Die Skripte sind auf 20 abgestimmt (höchstens 16 Clients).
- Platz: Jede Stufe erzeugt bis zu einige 100.000 Zeilen. Die Daten jeder Stufe werden nach der Auswertung gelöscht (`p_keep_data => false`); Oracle Free (12 GB) reicht damit.
- **Nicht auf einer produktiven Datenbank ausführen.** Die Tests lasten die Datenbank bewusst voll aus.

## Ausführen und auswerten

```sql
@_COMMON/04_install_belastung.sql
@BELASTUNG/KAPAZITAET_SERVER/test_kapazitaet_server.sql
```

Am Ende druckt jeder Lauf seinen Bericht als Markdown. Erneut ausgeben mit:

```sql
set serveroutput on size unlimited
exec ltb.bericht(<run_id>)
```

Den Bericht als `results/JJJJ-MM-TT_run<n>.md` im Ordner des Szenarios ablegen und um Befunde und Fazit ergänzen. Verlauf einer Stufe (z. B. für Diagramme):

```sql
select sec, phase, sent_logs, pers_logs, backlog, lag_ms, worker_rate, disp_rate, cpu_pct, commits_ps, pga_kb
  from ltb_sample where run_id = <run_id> and stage_no = <stufe> order by ts;
```

Nach einem Abbruch: `@_COMMON/02_aufraeumen.sql` stoppt alle Test-Server und Jobs.

## Tabellen

| Tabelle | Inhalt |
|---|---|
| `LTB_STAGE` | je Stufe alle Kennzahlen und die Bewertung |
| `LTB_SAMPLE` | Messpunkte des Beobachters (alle 2 s) |
| `LTB_PROGRESS` | Zähler je Client-Job (jede Sekunde aktualisiert) |
| `LTB_REQ` | je simuliertem APEX-Request Dauer, Reconnect und Zähler |
