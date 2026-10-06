# SERVERAUSWAHL: Korrektur und Nachweis (run 1882–1914)

**Kernergebnis in einfachen Worten:** Neue Prozesse verteilen sich jetzt gleichmäßig auf die Server, auch wenn sie schnell nacheinander kommen. Die Fälle, die vorher immer schiefgingen (bis 0:20), ergeben jetzt durchgehend 10:10. Alle anderen Server- und Dispatcher-Tests sind weiterhin grün. Ein Dauertest wurde nicht gestartet (nur auf ausdrückliche Anforderung).

- **Datum:** 06.10.2026
- **Grundlage:** Diagnose `2026-10-06_serverauswahl_provokation_ergebnis.md` (run 1881) und Freigabe der Punkte 1–3
- **Umgebung:** Oracle 23.26 Free (Notebook), Schema LILAM_TEST

## Umgesetzt (`source/package/lilam.pkb`)

1. **Serverauswahl** (`getServerPipeAvailable`, gilt für Client und Dispatcher):
   - Reihenfolge: `current_processes` ASC, dann Nachrichtenrate ASC, dann `last_activity` ASC.
   - Die Rate kommt aus den neuen Registry-Spalten `MSG_RATE` (Nachrichten je Sekunde im letzten Housekeeping-Fenster) und `RATE_TS` (Zeitstempel). Ein Wert, der älter als 1,5 s ist (`C_SELECT_RATE_MAX_AGE_MS`), zählt als 0.
   - Verglichen wird in Stufen zu 100 Nachrichten/s (`C_SELECT_RATE_BUCKET`).
   - Bei Gleichstand von offenen Prozessen und Raten-Stufe wählt der Aufrufer nicht wieder den zuletzt gewählten Server (`g_lastSelectedPipe`, Round Robin je Datenbanksession).
   - `PROCESSING` wird weiter geschrieben, aber nur noch für das Monitoring.
2. **Eco-Modus und Housekeeping** (`receiveMessage`, `START_SERVER`):
   - Ganzzahlige Stufen 0 → 1 → 2 → 5 s (`C_SERVER_ECO_STEP1_SEC`, `C_SERVER_ECO_STEP2_SEC`, `C_SERVER_TIMEOUT_MAX_WAIT_SEC`). An `DBMS_PIPE` werden keine Bruchteile mehr übergeben, die Konstante `0.2` entfällt.
   - Housekeeping ist zeitgesteuert: alle 500 ms nach jeder Schleifenrunde, auch während Nachrichten eintreffen; im Leerlauf beim nächsten Aufwachen. Die Zeitmessung läuft mit `DBMS_UTILITY.GET_TIME`.
   - Die Schleifenzähler-Logik (`C_SERVER_MAX_LOOPS_IN_TIME_NO`) ist entfallen.
3. **Drain-Phase:** Nach dem Abmelden aus der Registry leert der Server die Pipe mit `timeout => 1`, bis sie 1 s leer bleibt, höchstens etwa 5 s (`C_SERVER_DRAIN_IDLE_SEC`, `C_SERVER_DRAIN_MAX_MS`).
4. **`sendNoWait`:** Die Aufrufer übergeben `C_SEND_TIMEOUT_SEC = 1` statt `0.5`. Wirksam waren schon vorher 1 s, das ist jetzt bewusst so festgelegt.

### Zusätzlich angepasst (beim Testen gefunden)

- **Migration bei gleichzeitigem Serverstart:** Die neuen Spalten werden beim Start per `ALTER TABLE … ADD` ergänzt. Starten zwei Server gleichzeitig, bekommt der zweite ORA-01430 („Spalte existiert bereits“), siehe run 1882 (2 interne Fehler). Die neue Hilfsprozedur `add_columns` ignoriert genau diesen Fehler. Sie gilt auch für das ältere `IS_DISPATCHER`.
- **`current_processes` auch nach CLOSE_SESSION aktualisieren:** In der ersten Serie war run 1890 über den Dispatcher 6:14 (`12121212121222222222`). Die Ursache: Nach einem Close sank `current_processes` erst beim nächsten Housekeeping. Ein gerade untätiger Server, der im Eco-Modus 1–2 s schläft, behielt seine veraltete 1, und der beschäftigte gewann einseitig. Jetzt ruft `doRemote_closeSession` vor der Antwort an den Client `touchServerRegistry` auf.

### Bewusste Umsetzungsentscheidung

Die Rate wird in Stufen zu 100 Nachrichten/s verglichen, nicht exakt. Sonst entschiede schon ein Unterschied von 24 zu 30 Nachrichten/s bis zu 500 ms lang jede Wahl, also wieder einseitige Serien. Unter echter Last (Tausende Nachrichten/s) unterscheiden sich die Stufen, und die Rate verteilt dann nach Last.

## Ergebnisse

### SERVERAUSWAHL 10× hintereinander

| Serie | Runs | Ergebnis | Verteilung A (direkt) / B (Dispatcher) |
|---|---|---|---|
| 1. Serie (ohne Close-Touch) | 1883–1892 | 10/10 bestanden | A immer 10:10; B 9× 10:10 bzw. 11:9, **1× 6:14** (1890) |
| 2. Serie (endgültiger Stand) | 1893–1902 | **10/10 bestanden** | **A und B in allen 20 Bursts streng abwechselnd 10:10** |

Lauf 1882 (Migration) bestand 10:10, meldete aber 2 interne Fehler ORA-01430; danach behoben, siehe oben.

### Gegenprobe der früher zu 100 % einseitigen Zellen (run 1903 gegen 1881)

Gleiches Diagnoseverfahren (`lt_diag_sel_burst`), Skript `2026-10-06_serverauswahl_gegenprobe.sql`.

| Zelle | run 1881 (vorher): einseitig | Verteilungen vorher | run 1903 (nachher): einseitig | längste Serie nachher |
|---|---:|---|---:|---:|
| V1 Lücke 0,5 s (direkt) | 10/10 | 16:4 5:15 4:16 17:3 … | **0/10** (10× 10:10) | 1 |
| V1 Lücke 0,8 s | 10/10 | 16:4 15:5 15:5 … | **0/10** | 1 |
| V1 Lücke 1,5 s | 10/10 | 16:4 4:16 16:4 … | **0/10** | 1 |
| V2 Lücke 0,5 s (Dispatcher) | 10/10 | 17:3 16:4 … | **0/10** | 1 |
| V2 Lücke 0,8 s | 10/10 | 5:15 5:15 … | **0/10** | 1 |
| V2 Lücke 1,5 s | 10/10 | 4:16 16:4 … | **0/10** | 1 |
| V3 Burst A, 1,5 s Pause | 6/10 | 5:15 1:19 19:1 … | **0/10** | 1 |
| V3 Burst B (Dispatcher) nach 1,5 s | 10/10 | 0:20 ×8, 20:0 ×2 | **0/10** | 1 |
| V7 Burst 1 s nach Serverstart | 5/5 | 17:3 4:16 3:17 16:4 1:19 | **0/5** (5× 10:10) | 1 |

**85 von 85 Bursts genau 10:10, längste Serie 1** (streng abwechselnd). Keine Fehler in den Jobs, keine internen Fehler. Laufzeit 10:56:55–11:02:10 (5:15 min).

### Regression (alle bestanden)

| Run | Test | Ergebnis | Gesamtlaufzeit |
|---|---|---|---|
| 1904 | DECOUPLED/SERVER/LASTTEST | OK 10/10 | 9,2 s |
| 1905 | DECOUPLED/SERVER/PROZESSZYKLEN | OK 12/12 | 24,0 s |
| 1906 | DECOUPLED/SERVER/WAKEUP | OK 12/12 | 117,8 s |
| 1907 | DECOUPLED/SERVER/LASTSPITZE | OK 11/11 | 42,4 s |
| 1908 | DECOUPLED/DISPATCHER/LASTTEST | OK 10/10 | 9,2 s |
| 1909 | DECOUPLED/DISPATCHER/PROZESSZYKLEN | OK 12/12 | 16,7 s |
| 1910 | DECOUPLED/DISPATCHER/WAKEUP | OK 12/12 | 133,2 s |
| 1911 | DECOUPLED/DISPATCHER/LASTSPITZE | OK 11/11 | 44,2 s |
| 1912 | FEATURES/DISPATCHER_APEX | OK 17/17 | 17,4 s |
| 1913 | FEATURES/RUECKSCHREIBUNG | OK 21/21 | 43,2 s |
| 1914 | FEATURES/FEHLERFAELLE | OK 12/12 | 9,7 s |

Interne LILAM-Fehler gab es nur dort, wo sie erwartet sind: ID 61–62 sind die beiden ORA-01430 aus 1882 (vor der Korrektur der Migration). ID 63–65 hat FEHLERFAELLE (1914) absichtlich ausgelöst (kein Server, verfallenes NEW_SESSION), wie schon bei früheren Läufen (ID 48–50). Alle übrigen Läufe meldeten 0 interne Fehler.

### Messwerte im Vergleich zur Komplettsuite vor der Änderung (run 1545–1565)

| Test | Messwert | vorher | nachher | Einordnung |
|---|---|---:|---:|---|
| WAKEUP SERVER | Persistenz nach 5 / 16 / 30 / 65 s Ruhe | 1.440 / 114 / 51 / 39 ms | **8 / 8 / 5 / 5 ms** | besser: Housekeeping läuft beim Aufwachen sofort |
| WAKEUP DISPATCHER | Persistenz nach 5 / 16 / 30 / 65 s Ruhe | 1.395 / 1.134 / 1.372 / 1.321 ms | 2.082 / 265 / 2.081 / 2.076 ms | etwa 0,7 s langsamer, siehe Beobachtung |
| LASTSPITZE SERVER | Durchsatz / Drain LOG | 6.299 /s / 5.128 ms | 7.743 /s / 3.477 ms | besser |
| LASTSPITZE DISPATCHER | Durchsatz / Drain LOG | 2.486 /s / 10.981 ms | 2.419 /s / 3.261 ms | Drain deutlich kürzer |
| LASTTEST SERVER | µs je Aufruf | 171 | 272 | im bisherigen Streubereich (95–437 µs, Median 134) |
| LASTTEST DISPATCHER | µs je Aufruf | 254 | 136 | im bisherigen Streubereich (123–398 µs, Median 156) |
| DISPATCHER_APEX | veraltete ID ohne Wartezeit | 105 ms | 104 ms | unverändert |

**Beobachtung WAKEUP DISPATCHER:** Nach einer Ruhephase stehen die Daten über den Dispatcher etwa 2,1 s später in der Tabelle, vorher 1,1–1,4 s. Das liegt im Rahmen des Tests (Grenze 30 s), hängt aber mit den Eco-Stufen zusammen. Vermutlich fällt das Housekeeping des Workers nach dem Aufwachen in die 2-s-Stufe. Das gehört in die vereinbarte Diskussion zum Eco-Modus und ist hier nicht weiter untersucht.

## Aufräumen

Die LILAM-Daten der Gegenprobe sind gelöscht (`lt.purge_prefix('LT_1903_')`), die Server gestoppt. Die Messdaten liegen in `LT_DIAG_SEL` (run 1881 und 1903). Die Testdaten der Regressionsläufe bleiben wie bei den übrigen Einzeltests stehen.
