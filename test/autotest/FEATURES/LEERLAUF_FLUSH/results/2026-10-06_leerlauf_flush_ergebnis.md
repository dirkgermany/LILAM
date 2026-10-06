# Leerlauf-Flush: Daten nach einer Pause sofort sichtbar (run 1915–1931)

**Kernergebnis in einfachen Worten:** Kommt eine AJAX-Seite nach einer Pause wieder und schreibt etwas über den Dispatcher, steht der Eintrag jetzt nach wenigen Millisekunden in der Tabelle, vorher nach etwa 3 s. Die Seite selbst wartet nicht länger als vorher; Reconnect, Anlegen und Schließen von Prozessen sind sogar schneller geworden. Alle Regressionstests sind grün. Ein Dauertest wurde nicht gestartet.

- **Datum:** 06.10.2026
- **Freigabe:** Punkte 1–3 sowie Schutzregeln A und B, Leerlauf-Flush beschränkt auf Logs, Metriken und Prozessdaten
- **Umgebung:** Oracle 23.26 Free (Notebook), Schema LILAM_TEST

## Ursache (Diagnose run 1915 und 1916)

| Messung | Ablauf | INFO sichtbar nach |
|---|---|---|
| run 1915 (5×) | Prozess über den Dispatcher anlegen, 5 s Ruhe, INFO aus **neuer** Session (mit Reconnect) | 3.009 / 3.012 / 3.246 / 3.031 / 3.012 ms |
| run 1916 (3×) | wie oben, INFO aus **derselben** Session (ohne Reconnect) | 3,9 / 14,1 / 5,8 ms |

Housekeeping des Workers lief bei 0 s (Aufwachen durch den Reconnect), bei +1 s und bei +3 s. Das sind die Eco-Stufen 1 s und 2 s. Bei +1 s wurde das INFO noch nicht geschrieben. Dafür gab es zwei Gründe:

1. Jeder Prozess schreibt frühestens 1,5 s nach seinem letzten Schreibvorgang (`C_FLUSH_MILLIS_THRESHOLD_MS`). `sync_log` zählte aber jeden eigenen Aufruf als neuen Eintrag und setzte den Zeitpunkt „zuletzt geschrieben“ auch dann neu, wenn es nichts zu schreiben gab (leerer Flush beim Housekeeping des Reconnects).
2. Der Server schrieb nur beim Housekeeping, im Leerlauf also erst beim nächsten Aufwachen nach der Eco-Stufe.

## Umgesetzt (`source/package/lilam.pkb`)

1. **Leerlauf-Flush:** Ist die Pipe leer und hält der Worker ungeschriebene Daten (`g_dirty_queue`), schreibt er sie sofort mit `SYNC_ALL_DIRTY(p_force => TRUE, p_withBaselines => FALSE)`.
   - **Schutzregel A:** nur auf Workern, nie auf einem Dispatcher (`g_serverIsDispatcher`).
   - **Schutzregel B:** höchstens alle 200 ms (`C_SERVER_IDLE_FLUSH_MS`).
   - **Beschränkung:** nur Logs, Metriken und Prozessdaten. Die Baselines bleiben bei ihrem Takt (neuer Parameter `p_withBaselines` in `SYNC_ALL_DIRTY`).
   - Ein Lauf ohne Baselines setzt die 500-ms-Zeitsperre von `SYNC_ALL_DIRTY` nicht. Sonst würden häufige Leerlauf-Flushes das reguläre Housekeeping und damit den Baseline-Abgleich dauerhaft ausbremsen.
2. **`sync_log` und `sync_monitor`:** Ist nichts gepuffert, kehren sie ohne Schreibvorgang zurück, und der Zeitpunkt „zuletzt geschrieben“ bleibt unverändert. `sync_log` zählt seine eigenen Aufrufe nicht mehr als Einträge. Die Puffer werden nur in `write_to_log_buffer`, `writeEventToMonitorBuffer` und `writeTraceToMonitorBuffer` gefüllt, und genau dort steigen die Zähler; die Zähler sind damit verlässlich.
3. **Test WAKEUP** (`_COMMON/01_install_testbasis.sql`): `wake_call` misst die Sichtbarkeit des INFO ab dem Ende des Aufrufs (`wake_visible_ms_<n>s`). `t_wakeup` prüft zusätzlich: höchstens 1 s.

## Ungünstigster Fall (run 1917 alter Stand gegen run 1918 neuer Stand)

Skript `2026-10-06_idle_flush_lastfall.sql`: **ein** Worker plus Dispatcher. Client A schickt in der Lastphase alle 210 ms ein INFO, sodass der Leerlauf-Flush laufend greift. Client B misst in frischen Sessions je 20×.

| Messung | alter Stand (1917) Median / P90 / Max | neuer Stand (1918) Median / P90 / Max |
|---|---|---|
| Reconnect + INFO, ohne Last | 8,9 / 25,9 / 47,8 ms | 6,0 / 13,3 / 92,0 ms |
| Reconnect + INFO, mit Last | 4,4 / 8,5 / 11,2 ms | 3,6 / 6,3 / 6,9 ms |
| NEW_SESSION, ohne Last | 42,7 / 117,3 / 131,0 ms | 10,3 / 27,6 / 52,6 ms |
| NEW_SESSION, mit Last | 38,9 / 98,7 / 167,5 ms | 11,5 / 16,9 / 22,2 ms |
| CLOSE_SESSION, ohne Last | 46,9 / 137,3 / 194,5 ms | 9,3 / 16,8 / 33,6 ms |
| CLOSE_SESSION, mit Last | 73,7 / 163,2 / 215,7 ms | 10,7 / 21,1 / 26,9 ms |
| INFO sichtbar, ohne Last | 1.424,7 / 2.524,1 / 2.749,1 ms | 31,3 / 331,2 / 370,7 ms |
| INFO sichtbar, mit Last | 1.409,3 / 2.144,6 / 2.466,0 ms | 99,9 / 173,2 / 193,9 ms |

**Bewertung:** Synchrone Aufrufe werden durch den Leerlauf-Flush nicht langsamer. Ein einzelner Ausreißer (Reconnect ohne Last, 92 ms) liegt in der Größenordnung früherer Ausreißer. NEW_SESSION und CLOSE_SESSION sind deutlich schneller, vermutlich weil der Worker nach dem Schreiben seltener in längere Eco-Wartezeiten fällt. Die Sichtbarkeit sinkt von 1,4 s (Median) auf 31–100 ms; der höchste Wert liegt unter 0,4 s.

## Regression (run 1919–1931, alle bestanden)

| Run | Test | Ergebnis | Gesamtlaufzeit |
|---|---|---|---|
| 1919 | DECOUPLED/SERVER/WAKEUP (mit neuer Sichtbarkeitsprüfung) | OK 16/16 | 118,7 s |
| 1920 | DECOUPLED/DISPATCHER/WAKEUP (mit neuer Sichtbarkeitsprüfung) | OK 16/16 | 127,3 s |
| 1921 | DECOUPLED/SERVER/LASTTEST | OK 10/10 | 6,3 s |
| 1922 | DECOUPLED/SERVER/PROZESSZYKLEN | OK 12/12 | 14,7 s |
| 1923 | DECOUPLED/SERVER/LASTSPITZE | OK 11/11 | 43,2 s |
| 1924 | DECOUPLED/DISPATCHER/LASTTEST | OK 10/10 | 9,1 s |
| 1925 | DECOUPLED/DISPATCHER/PROZESSZYKLEN | OK 12/12 | 17,3 s |
| 1926 | DECOUPLED/DISPATCHER/LASTSPITZE | OK 11/11 | 48,9 s |
| 1927 | FEATURES/SERVERAUSWAHL | OK 11/11, A und B streng 10:10 | 7,2 s |
| 1928 | FEATURES/BASELINE_SCOPE (Baseline-Abgleich weiterhin korrekt) | OK 19/19 | 10,1 s |
| 1929 | FEATURES/RUECKSCHREIBUNG | OK 21/21 | 41,2 s |
| 1930 | FEATURES/DISPATCHER_APEX | OK 17/17 | 17,4 s |
| 1931 | FEATURES/FEHLERFAELLE | OK 12/12 | 9,7 s |

Interne LILAM-Fehler gab es nur die drei, die FEHLERFAELLE absichtlich auslöst (ID 66–68).

### WAKEUP: Sichtbarkeit nach 5 / 16 / 30 / 65 s Ruhe

| Modus | vorher (run 1906 / 1910): bis zur Persistenz | jetzt: INFO sichtbar ab Ende des Aufrufs (`wake_visible_ms`) | jetzt: Dauer des Aufrufs (`wake_call_ms`) |
|---|---|---|---|
| SERVER | 8 / 8 / 5 / 5 ms | 3,9 / 12,8 / 11,4 / 12,0 ms | 1,6 / 2,1 / 0,8 / 0,4 ms |
| DISPATCHER | **2.082 / 265 / 2.081 / 2.076 ms** | **13,3 / 12,1 / 0,6 / 11,5 ms** | 8,9 / 8,3 / 5,0 / 4,2 ms |

### Weitere Messwerte (run 1904–1914 gegen 1919–1931)

| Test | Messwert | vorher | nachher | Einordnung |
|---|---|---:|---:|---|
| LASTTEST SERVER | µs je Aufruf | 272 | 133 | Streubereich (95–437) |
| LASTTEST DISPATCHER | µs je Aufruf | 136 | 143 | Streubereich (123–398) |
| LASTSPITZE SERVER | Durchsatz | 7.743 /s | 6.475 /s | Streubereich (vor der Korrektur der Serverauswahl 6.299 /s) |
| LASTSPITZE DISPATCHER | Drain LOG | 3.261 ms | 8.463 ms | Streubereich (bisher 1,5–10.981 ms, Median 2.932 ms) |
| PROZESSZYKLEN SERVER | NEW / CLOSE ms | 35,6 / 80,0 | 15,8 / 40,7 | besser |
| PROZESSZYKLEN DISPATCHER | NEW / CLOSE ms | 19,7 / 34,9 | 22,1 / 50,8 | Streubereich (CLOSE bisher 8,5–109,5 ms, Median 15) |
| DISPATCHER_APEX | veraltete ID | 104 ms | 106 ms | unverändert |

## Aufräumen

Die LILAM-Daten der Diagnoseläufe 1915 und 1916 sind gelöscht. Die Läufe 1917 und 1918 haben eigene Prozessnamen (`LT_1917_…`, `LT_1918_…`) und bleiben wie andere Einzeltests stehen. Die Server sind gestoppt. Für den Vergleich 1917 war vorübergehend der Body aus `main` eingespielt; danach wurde der neue Body kompiliert (VALID, keine Fehler).
