# SERVERAUSWAHL: Provokation des Ungleichgewichts – Ergebnis (run 1881)

- **Datum:** 06.10.2026, 10:12:30–10:31:38 (Gesamtlaufzeit 19:08 min)
- **LILAM-Stand:** Branch `claude`, e0c11f6; keine Änderung an `lilam.pks`/`.pkb`, an der Testbasis oder an bestehenden Tests
- **Skript:** `test/autotest/_DIAG/2026-10-06_serverauswahl_provokation.sql`. Es legt eigene Diagnoseobjekte an: Tabelle `LT_DIAG_SEL`, Prozeduren `lt_diag_sel_burst` und `lt_diag_sel_driver`. Die Steuerung lief als Job `LT_CDIAG_DRV`, jeder Burst als eigener Client-Job (frische Session).
- **Plan:** `2026-10-06_serverauswahl_provokation.md` (V0–V7, V8 nicht freigegeben)
- **Umfang:** 290 Wiederholungen bzw. 360 Bursts mit 7.200 `SERVER_NEW_SESSION`. Vor jedem Aufruf wurde ein Registry-Snapshot von LT_S1 und LT_S2 genommen (außer V0 mit `snap=0`). Es gab keine Fehler in den Jobs, keine internen LILAM-Fehler und keine offenen Prozesse. Die LILAM-Daten sind gelöscht (`lt.purge_prefix`); die Messdaten liegen weiter in `LT_DIAG_SEL` (run_id 1881).
- **Einseitig** heißt: ein Server unter 30 % (weniger als 6 von 20) oder mindestens 8 aufeinanderfolgende Prozesse beim selben Server.

## Kernergebnis

**Die Serverwahl folgt exakt dem Registry-Stand, und lange einseitige Serien entstehen ausschließlich über `processing`.**

| Prüfung | Ergebnis |
|---|---|
| Aufrufe, deren gewählter Server der Sortierregel `processing ASC, current_processes ASC, last_activity ASC` auf dem Snapshot unmittelbar davor entspricht | **7.192 von 7.200 (99,9 %)** |
| davon entschieden durch `processing` / `current_processes` / `last_activity` | 3.590 / 164 / 3.446 |
| Aufrufe **innerhalb einseitiger Serien (≥ 8)**, die `processing` entschieden hat | **2.821 von 2.833 (99,6 %)** |
| Aufrufe beim **Abwechseln** (Serie 1–2), die `last_activity` entschieden hat (Touch nach NEW_SESSION) | 3.432 von 3.896 (88 %) |

H1 ist damit **im Kern bestätigt**. Sobald die beiden Server unterschiedliche `processing`-Werte in der Registry haben, gewinnt der Server mit dem kleineren Wert jede Wahl. Das geht so lange, bis er selbst neu schreibt. Der Touch nach NEW_SESSION wirkt nur bei Gleichstand.

Zwei Annahmen des Plans waren aber **falsch**. Sie präzisieren den Mechanismus:

1. **Housekeeping kommt nicht erst nach 0,2 s Leerlauf.** `DBMS_PIPE.RECEIVE_MESSAGE` hat den Parameter `TIMEOUT INTEGER` (PLS_TYPE laut `ALL_ARGUMENTS`). `C_SERVER_TIMEOUT_WAIT_FOR_MSG_SEC = 0.2` wird deshalb zu **0** (siehe Abschnitt „Pipe-Timeouts“). Ein aktiver Server macht damit sein Housekeeping beim ersten Blick auf eine leere Pipe, sobald seit dem letzten 500 ms vergangen sind (`lilam.pkb:6650–6657`). Das ist oft schon wenige Millisekunden nach seiner ersten Nachricht.
2. **`processing` misst keine Last, sondern ein zufälliges Zeitfenster.** Der Wert ist die Anzahl der Nachrichten seit dem letzten Housekeeping dieses Servers. Weil das Housekeeping direkt nach den ersten Nachrichten kommt, steht dort meist **2** (Ping + NEW_SESSION). Bei einem anderen Takt sind es 8, 14, 18 oder 24, die Fenster sind zwischen den Servern nicht abgestimmt. Ein Unterschied wie 2 gegen 8 entscheidet dann bis zu 500 ms lang **jede** Wahl. Im Leerlauf (Eco-Modus) schreibt ein Server seinen Wert zudem nur noch alle 1 bis 5 s neu, ein veralteter Wert bleibt also lange stehen.

## Ergebnisse je Variante

Verteilung S1:S2 je Wiederholung.

| Var. | Parameter | einseitig | < 30 % | Verteilungen |
|---|---|---:|---:|---|
| V4 Vorlast | k=0 | 2/10 | 0 | 10:10 ×8, 6:14, 13:7 |
| | k=5 | 4/10 | 4 | 0:20, 20:0, 2:18, 20:0, sonst 10:10 |
| | k=50 | **0/10** | 0 | 10:10 ×10 |
| V1 Lücke (direkt) | p=0,0 s | 1/10 | 1 | 17:3, sonst 10:10 |
| | p=0,1 s | 0/10 | 0 | 10:10 ×10 |
| | p=0,3 s | **8/10** | 4 | 10:10 12:8 16:4 13:7 16:4 9:11 12:8 4:16 15:5 12:8 |
| | p=0,5 s | **10/10** | 10 | 16:4 5:15 4:16 17:3 16:4 5:15 4:16 17:3 16:4 16:4 |
| | p=0,8 s | **10/10** | 9 | 16:4 15:5 15:5 15:5 14:6 15:5 15:5 15:5 16:4 15:5 |
| | p=1,5 s | **10/10** | 10 | 16:4 4:16 16:4 4:16 16:4 4:16 17:3 4:16 16:4 3:17 |
| V2 Lücke (Dispatcher) | p=0,0 s | 1/10 | 1 | 1:19, sonst 10:10 |
| | p=0,1 s | 0/10 | 0 | 10:10 ×10 |
| | p=0,3 s | 4/10 | 2 | 4:16 8:12 4:16 9:11, sonst 10:10 |
| | p=0,5 s | **10/10** | 10 | 16:4 / 17:3 |
| | p=0,8 s | **10/10** | 10 | 5:15 / 4:16 |
| | p=1,5 s | **10/10** | 10 | abwechselnd 4:16 und 16:4 |
| V3 Burst A, Pause, Burst B (Dispatcher) | 0,2 s | A 10/10, B 10/10 | A 8, B 9 | B: 1:19 19:1 13:7 1:19 19:1 1:19 19:1 15:5 1:19 18:2 |
| | 0,4 s | A 4, B 4 | 2 / 4 | B: 19:1 19:1 1:19 0:20, sonst 10:10 |
| | 0,6 s | A 4, B 6 | 3 / 6 | B: 19:1 4:16 1:19 1:19 4:16 1:19, sonst 10:10 |
| | 0,8 s | A 3, B 7 | 1 / 4 | |
| | 1,0 s | A 4, B 5 | 3 / 5 | B: 20:0 0:20 20:0 0:20 0:20, sonst 10:10 |
| | 1,5 s | A 6, B **10** | 6 / 10 | B: 0:20 ×8, 20:0 ×2 |
| | 3,0 s | A 5, B 8 | 5 / 8 | B: 1:19 3:17 19:1 1:19 1:19 19:1 1:19 19:1 |
| V0 Nachbau (zwei Jobs, joblog) | snap=1 | A 1/10, B 1/10 | 0 / 1 | A 14:6, B 15:5, sonst 10:10 |
| | snap=0 | 0/10, 0/10 | 0 | 10:10 ×20 |
| V5 Wartezeit je Iteration | d = 0 / 50 / 150 / 250 / 600 ms | 0 / 2 / 0 / 0 / 0 (je 5) | 0 | höchstens 7:13 |
| V6 Vorlast k=50, Prozesse offen | | 1/5 | 1 | 19:1, sonst 10:10 |
| V7 frisch gestartete Server | x = 0 s | 0/5 | 0 | 10:10 ×5 |
| | x = 0,3 s | 1/5 | 1 | 18:2 |
| | x = 1 s | **5/5** | 5 | 17:3 4:16 3:17 16:4 1:19 |
| | x = 3 s | 4/5 | 1 | 12:8 13:7 12:8 4:16 10:10 |

### Bewertung gegen die Kriterien des Plans

| Kriterium | Soll | Ist | Bewertung |
|---|---|---|---|
| V4 k>0 einseitig | ≥ 9/10 | k=5: 4/10, k=50: 0/10 | **nicht erfüllt.** Die Annahme von V4 war falsch: Die Vorlast kommt in der Registry nicht an. Der Vorlast-Server schreibt sein Housekeeping direkt nach NEW_SESSION mit `processing = 2`, die k INFOs folgen erst danach (Snapshot V4 k=50: beide Server 2/2 bei Burst-Beginn). Mit gleichem `processing` entscheiden die Nebenkriterien, also wird abgewechselt. Nur wenn das Fenster zufällig die INFOs erfasst (k=5, rep 3: S1 = 8, S2 = 0), kippt es: 0:20. |
| V4 k=0 einseitig | ≤ 1/10 | 2/10 | knapp verfehlt; zufällige Fenster wie bei V1 p=0 |
| V1 p ∈ {0,3; 0,5} einseitig | ≥ 7/10 | 8/10, 10/10 | **erfüllt** |
| V1 p ≤ 0,1 einseitig | ≤ 1/10 | 1/10, 0/10 | **erfüllt** |
| V1 p = 1,5 einseitig | ≤ 1/10 | 10/10 | **nicht erfüllt.** Die Vorhersage „nach langer Pause wieder 0/0“ war falsch. Im Eco-Modus schreibt ein ruhender Server nur noch alle 1 bis 5 s neu (Timeouts 0, 0, 1, 1, …, 5 s), die unterschiedlichen Werte vor der Pause bleiben stehen. |
| Snapshot beim Kippen: Gewinner hat kleineres `processing` | alle einseitigen Fälle | 2.821 von 2.833 Aufrufen in Serien ≥ 8 per `processing` entschieden | **erfüllt** |
| H1 widerlegt, wenn V4 k=50 ≤ 3/10 | – | 0/10 | formal ausgelöst, aber nicht aussagekräftig: Die Vorlast hat `processing` gar nicht verändert (siehe oben). Die Regel wird gegen den direkt gemessenen Snapshot geprüft (99,9 % bzw. 99,6 %), und das bestätigt den Mechanismus. |

Einen vorzeitigen Abbruch von Zellen gab es nicht, alle 290 Wiederholungen liefen vollständig.

## Kipp-Zeitpunkte mit Registry-Snapshot

Snapshot unmittelbar vor dem Aufruf, mit dem die längste einseitige Serie beginnt. `p` = `processing`, `c` = `current_processes`, `a` = Alter von `last_activity` in ms.

| Variante, Wdh. | Kippen bei Prozess | Serie | Gewinner | t (ms) | LT_S1 p / c / a | LT_S2 p / c / a | Erklärung |
|---|---:|---:|---|---:|---|---|---|
| V0 snap=1, rep 1, B | 6 | 15 | LT_S1 | 105 | 2 / 0 / 19 | **24** / 1 / 15 | S2 schrieb ein großes Fenster (24), S1 hat 2 und bekommt den Rest |
| V1 p=0, rep 5 | 5 | 16 | LT_S1 | 84 | 2 / 1 / 77 | **8** / 1 / 15 | ohne Pause: ein Fenster von S2 erfasst 8 Nachrichten |
| V1 p=0,5, rep 1 | 7 | 14 | LT_S1 | 561 | 6 / 1 / 541 | **14** / 1 / 5 | nach der Lücke schreibt S2 frisch 14, S1 steht noch auf 6 |
| V2 p=0,8, rep 1 | 7 | 14 | LT_S2 | 962 | **18** / 1 / 17 | 2 / 1 / 947 | spiegelbildlich, über den Dispatcher |
| V3 0,2 s, rep 1, A | 2 | 19 | LT_S1 | 19 | 0 / 0 / 160 | **2** / 1 / 12 | S1 steht noch auf 0 aus der Ruhe, S2 schrieb 2 |
| V3 1,5 s, rep 1, B | 1 | 20 | LT_S2 | 0 | **18** / 0 / 503 | 2 / 0 / 561 | Wert von S1 aus Burst A (18) ist nach 1,5 s Pause noch nicht erneuert (Eco-Modus) |
| V4 k=5, rep 3 | 1 | 20 | LT_S2 | 0 | **8** / 0 / 21 | 0 / 0 / 518 | das Fenster von S1 erfasste die Vorlast (8) |
| V6 k=50 offen, rep 1 | 1 | 19 | LT_S1 | 1 | 0 / 0 / 317 | **2** / 1 / 25 | S1 gewinnt trotz steigender Zahl offener Prozesse: `current_processes` zählt bei `processing`-Unterschied nicht |
| V7 x=1, rep 1 | 6 | 15 | LT_S1 | 95 | 0 / 1 / 24 | **12** / 0 / 1 | kurz nach dem Start: S2 schreibt 12, S1 steht auf 0 |

## Einordnung der ursprünglichen Fehlschläge

- **Burst B des Originaltests** beginnt 0,4 bis 1,4 s nach Burst A. V3 zeigt für genau diese Pausen 40 bis 100 % einseitige Bursts. Der Grund sind unterschiedlich alte `processing`-Werte aus A, die im Eco-Modus stehen bleiben. Das ist die Hauptursache der roten S5-Prüfungen.
- **Burst A** läuft im Originaltest direkt nach dem Serverstart. V7 zeigt: Startet der Burst sofort (x = 0), ist er stabil. Startet er etwa 1 s nach `wait_servers_ready`, ist er fast immer einseitig. Das erklärt die seltenen roten S3-Prüfungen (779, 1508).
- **V0 (Nachbau)** war mit lange laufenden Servern nur in 2 von 40 Bursts einseitig. Die Fehlerquote hängt also stark vom Registry-Zustand bei Burst-Beginn ab: Serverstart, vorherige Bursts, Phase des Eco-Modus. Der Ablauf des Tests selbst ist dafür weniger entscheidend.
- **Warum erst am 05.10.:** Ungeklärt, V8 war nicht freigegeben. Die Ergebnisse zeigen aber, dass schon kleine Änderungen im Takt (Pausenlängen, Zeitpunkt nach dem Serverstart) die Fehlerquote zwischen 0 und 100 % verschieben.

## Pipe-Timeouts mit Sekundenbruchteilen

`DBMS_PIPE.SEND_MESSAGE` und `DBMS_PIPE.RECEIVE_MESSAGE` erwarten `TIMEOUT` als INTEGER in Sekunden. Oracle rundet Bruchteile beim Aufruf (0,2 und 0,4 werden zu 0, 0,5 bis 1,4 zu 1). Außerdem deklariert LILAM eigene Parameter als `PLS_INTEGER`, was bereits beim Aufruf rundet. Alle Aufrufe in `lilam.pkb`:

| Stelle | Aufruf | beabsichtigt | wirksam | Auswirkung |
|---|---|---|---|---|
| `lilam.pkb:6418` (`receiveMessage`, Server-Loop `:6634`) | `RECEIVE_MESSAGE(…, timeout => p_cur_timeout)`; Startwert `C_SERVER_TIMEOUT_WAIT_FOR_MSG_SEC = 0.2` (`:17`) | 0,2 s warten | **0 s** | Der Server prüft die Pipe ohne zu warten. Housekeeping (`:6650`) kommt beim ersten leeren Blick, sobald 500 ms vergangen sind, also mitten in aktiver Arbeit. Das ist der direkte Auslöser der zufälligen `processing`-Fenster (siehe oben). Für die Latenz ist es unkritisch. |
| ebenda, Eco-Modus | `p_cur_timeout := LEAST(p_cur_timeout + 0.2, C_SERVER_TIMEOUT_MAX_WAIT_SEC = 5)` | Wartezeit wächst in 0,2-s-Schritten: 0,2 · 0,4 · 0,6 · … · 5 s | **0 · 0 · 1 · 1 · 1 · 1 · 1 · 2 · … · 5 s** | Nach zwei sofortigen Leerprüfungen wartet der Server gleich 1 s und dann länger. Housekeeping und Heartbeat eines ruhenden Servers kommen dadurch nur noch alle 1 bis 5 s. Veraltete `processing`-Werte bleiben entsprechend lange stehen (V1 p=1,5; V3 1,5 s). Eine eintreffende Nachricht weckt den Server weiterhin sofort. |
| `lilam.pkb:6677` (Drain-Phase in `START_SERVER` nach dem Shutdown) | `RECEIVE_MESSAGE(g_serverPipeName, timeout => 0.1)` | 0,1 s auf Nachzügler warten | **0 s** | Die Schleife endet beim ersten Moment mit leerer Pipe. Nachrichten, die Clients kurz danach noch senden, verarbeitet der Server nicht mehr. Sie bleiben in der Pipe und gehen mit `preparePipe`/`PURGE` beim nächsten Start verloren, sofern kein anderer Server die Pipe übernimmt. Die Drain-Phase wirkt also nur auf bereits wartende Nachrichten. |
| `lilam.pkb:1685` (`sendNoWait`, Parameter `p_timeoutSec IN PLS_INTEGER`); Aufrufer `:3068`, `:3092`, `:3120`, `:4103`, `:4120`, `:4169` mit `0.5` | `SEND_MESSAGE(l_pipeName, timeout => p_timeoutSec)`, bis zu 3 Versuche mit `sleep(0.3)` | 0,5 s je Versuch, höchstens etwa 2,4 s (3 × 0,5 s + 3 × 0,3 s) | **1 s** je Versuch, höchstens etwa 3,9 s | Wirkt nur bei voller Pipe (Rückstau). Ein Client blockiert dann bis zu 1 s statt 0,5 s je Versuch, insgesamt bis etwa 3,9 s, bevor `sendNoWait` aufgibt (Fehler -20006, intern protokolliert). Im Normalbetrieb ohne Wirkung. |
| `lilam.pkb:1515` (`waitForResponse`, Parameter `p_timeoutSec IN PLS_INTEGER`) | `RECEIVE_MESSAGE(l_clientChannel, timeout => p_timeoutSec)`; Aufrufer mit 10, 5, 1, 5, 5, 5 und `C_TIMEOUT_NEW_SESSION_SEC = 3.0` (`:52`) | ganze Sekunden | unverändert | korrekt. Bei `C_TIMEOUT_NEW_SESSION_SEC` würde ein späterer Bruchteil (z. B. 2,5) ebenfalls gerundet. |
| `lilam.pkb:1510`, `:1513` | `SEND_MESSAGE(…, timeout => 3)` | 3 s | 3 s | korrekt |
| `lilam.pkb:889`, `:5209`, `:5259`, `:5306`, `:5341`, `:6490`, `:6618` | `timeout => 0` | sofort | sofort | korrekt (beabsichtigt) |
| `lilam.pkb:5112`, `:5183`, `:5402`, `:5747`, `:6300`, `:6500`, `:6503` | `timeout => 1` | 1 s | 1 s | korrekt |

## Fazit

- **Ursache bestätigt:** Das erste Auswahlkriterium `processing` ist ein Nachrichtenzähler über ein zufällig liegendes Zeitfenster von höchstens 500 ms, das jeder Server zu einem anderen Zeitpunkt beginnt. Im Eco-Modus wird es nur alle 1 bis 5 s erneuert. Sobald sich die Werte der Server unterscheiden, auch nur 2 gegen 8, geht jede NEW_SESSION an denselben Server, bis dieser neu schreibt. Der Touch nach NEW_SESSION und `current_processes` wirken nur bei Gleichstand.
- **Mitverursacher:** Die Pipe-Timeouts mit Bruchteilen werden auf 0 bzw. 1 s gerundet. Dadurch liegt das Housekeeping mitten in aktiver Arbeit (Timeout 0), und der Eco-Modus springt sofort auf 1 s und mehr.
- **Zuverlässig provozierbar:** V1/V2 mit einer Lücke von 0,5 bis 1,5 s mitten im Burst (100 %), V3 Burst B nach 1,5 s Pause (100 %) und V7 Burst etwa 1 s nach Serverstart (100 %).
- **Nicht umgesetzt:** Lösungen sind wie vereinbart offen. Die Lösungsrichtungen aus dem Plan (Abschnitt 4) bleiben gültig; dazu kommen der Eco-Modus und die Drain-Phase (siehe Abschnitt „Pipe-Timeouts“) als eigene Diskussionspunkte.
