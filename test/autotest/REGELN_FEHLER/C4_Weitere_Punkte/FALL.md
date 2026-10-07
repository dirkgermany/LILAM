# C4: Weitere Punkte aus der Analyse

- **Projekt:** REGELN_FEHLER (Kontext: `../PROJEKT_KONTEXT.md`)
- **Quelle:** Analyse `FEATURES\REGELN\results\2026-10-04_regeln_analyse.md`, Abschnitte 1, 5 und 7
- **Schwere:** niedrig bis mittel
- **Status:** umgesetzt 06.10.2026, Commit `11f4d56` auf `claude` (gepusht); Pull Request durch Dirk offen

## Befund (laut Analyse vom 04.10.2026)

- **a)** Ausbleibende Signale („Nachfolger bleibt aus“, „Prozess hängt“, offene Traces beim Purge; dort nur der Kommentar „HIER: Alert-Logik einbauen“) werden nicht erkannt, es gibt keine zeitgesteuerte Prüfung.
- **b)** Regelsatz je Server statt global.
- **c)** `AVG_DEVIATION_PCT` mit 100.000 % schlug beim ersten Event an (Vermutung: EWMA nahe 0 nach dem kurzen Warm-up von 3, jede Messung > 0 ist dann eine „Abweichung“).
- **d)** `existsNewServerRule` ist toter Code und fragt die nicht existierende Spalte `RULE_VERSION` ab.
- **e)** `g_avg_params` (Warm-up/Alpha je Regel) wird beim Neuladen nicht geleert; Werte entfernter Regeln bleiben wirksam.
- **f)** Header-Name (`header.rule_set`) und Tabellenname (`SET_NAME`) sind unabhängig; weichen sie ab, findet der Consumer die Regel nicht.
- **g)** Registry: ungenutzte Spalten `RULE_SET_NAME`, `SET_IN_USE` und alten Index `IDX_LILAM_RULES` (`SET_NAME`, `VERSION`) in bestehenden Installationen entfernen (z. B. in `install.sql`).
- **h)** Reaktion auf bestimmte Logs (z. B. INFO mit bestimmtem Text) vormerken; `PRECEDED_BY` zählt Logs bewusst nicht als Vorgänger.

## Belegt durch

Code; Leistungsmessung (Abschnitt 5 der Analyse).

## Wirkung

Teils Lücken in der Funktion, teils Aufräumarbeiten.

## Ansatz (zu prüfen, Dirk entscheidet)

Einzeln bewerten und in Teilfälle (Unterordner) ausgliedern, sobald Dirk sie freigibt; a, b und h hängen an den Grundsatzfragen (`../G_Grundsatzfragen`).

## Schritte

- [x] 1. Jeden Punkt gegen den aktuellen Code prüfen; Ergebnis unten protokollieren
- [x] 2. Vorschlag Dirk vorlegen
- [x] 3. Freigabe durch Dirk; Teilfälle anlegen
- [x] 4. Umsetzung je Teilfall im Klon (Branch `claude`); testen nur auf Dirks Anweisung
- [x] 5. Doku angleichen
- [ ] 6. Bericht, Commit nach Freigabe, Pull Request durch Dirk (Commit/Push erledigt, PR offen)

## Protokoll

_(Datum, Schritt, Ergebnis; neueste zuletzt.)_

**06.10.2026 (Hinweis aus B4):** Logs zählen seit fe863f1 nicht mehr als Vorgänger (B4). Offen bleibt hier: Der Vorgänger ist das letzte Event bzw. der letzte Trace des Prozesses über alle Actions; `TRACE_START` und `TRACE_STOP` setzen ihn beide. Eine `PRECEDED_BY`-Regel mit Trigger `TRACE_STOP` auf B sieht daher meist das eigene `TRACE_START` von B. Zu entscheiden: so lassen und dokumentieren, oder z. B. die eigene Action nicht als Vorgänger werten bzw. den Vorgänger je Action führen.

**06.10.2026, Schritt 1 (Prüfergebnis):**
- a) offen, hängt an G5. Keine Zeitsteuerung; offene Traces nur als WARN-Log bei `CLOSE_SESSION` (`warnOpenTraces`). Grenze im README beschrieben.
- b) erledigt durch G2 (Regelsatz je Servergruppe).
- c) behoben (Vergleich mit dem Durchschnitt vor der Messung, NULL bis der Warm-up erreicht ist). Rest: Ein Durchschnitt unter 1 ms (Messauflösung) konnte > 100.000 % melden.
- d) erledigt (`existsNewServerRule` und `RULE_VERSION` entfernt).
- e) behoben (`removeGroupRules` löscht `g_avg_params` je Gruppe).
- f) behoben (Name/Version aus `SET_NAME`/`VERSION`, Header nur informativ).
- g) Test-DB schon bereinigt (Abfrage `user_indexes`/`user_tab_columns`); der Code entfernte Altlasten nicht.
- h) offen: für LOGGING nur `SEVERITY`.
- B4-Rest bestätigt: `TRACE_STOP` sieht das eigene `TRACE_START` als Vorgänger; kein Test und kein Beispiel nutzt `PRECEDED_BY*` mit `TRACE_STOP`.

**06.10.2026, Schritt 3 (Entscheidung Dirk):** alle fünf Empfehlungen freigegeben: `TRACE_STOP` bei `PRECEDED_BY*` beim Laden ablehnen; `AVG_DEVIATION_PCT` unter 1 ms nicht auswerten; Altspalten/-index in `createLogTables` entfernen; a so lassen und dokumentieren; neuer Operator `LOG_CONTAINS`.

**06.10.2026, Schritt 4/5 (Umsetzung im Klon, nicht committet, nicht kompiliert):**
- `source/package/lilam.pkb`:
  - `parseRuleSet`: `PRECEDED_BY*` nicht mehr mit `TRACE_STOP`; `LOG_CONTAINS` nur mit `LOGGING`, Wert `TEXT` oder `LEVEL|TEXT` (Level in `cond_context`, Text in `cond_upper`, Länge 1–100 wird vor der Zuweisung geprüft).
  - `validateDurationInAverage`: keine Auswertung bei Durchschnitt < 1 ms.
  - `evaluateRules_internal`: `WHEN 'LOG_CONTAINS'`.
  - `evaluateRules(t_monitor_buffer_rec, …)`: neuer Parameter `p_info VARCHAR2 := NULL` → `l_ctx.info`; Aufruf in `log_any` mit `l_logText`.
  - `createLogTables`: neue Hilfsprozedur `drop_obsolete` (ORA-01418/-00904 still, sonst `logLilamErr`, bricht nie ab); Registry-Spalten `RULE_SET_NAME`/`SET_IN_USE` und Index `IDX_LILAM_RULES` werden entfernt, falls vorhanden.
- Doku: `rules/README.md` (Operator-Tabelle, Fußnote 4), `docs/API_DE.md` (Abschnitt `SERVER_UPDATE_RULES`, Hinweise vorab), `docs/architecture and concepts.md` (Monitor-Tabelle, Logging-Tabelle, Hinweis auf fehlende Zeitsteuerung).
- **Offen:** Testergänzungen (`LOG_CONTAINS` mit und ohne Level, Ablehnung von `PRECEDED_BY` auf `TRACE_STOP`, AVG unter 1 ms) noch nicht eingebaut, weil `01_install_testbasis.sql` parallel von B6 geändert wird. Nächster Schritt: Kompilieren/Test und Commit nach Dirks Freigabe.

**06.10.2026, Schritt 6 (teilweise):** Mit Dirks Freigabe committet und gepusht: `11f4d56` auf `claude` (vorher `main` per Fast-Forward geholt). Im Commit: `lilam.pkb`, `rules/README.md`, `docs/API_DE.md`, `docs/architecture and concepts.md`; die Testdateien von B6 nicht. Offen: Pull Request durch Dirk; Kompilieren/Test und Testergänzungen wie oben.

**07.10.2026, Testergänzung (im Klon, nicht committet):** `test/autotest/_COMMON/01_install_testbasis.sql`, Test `lt.t_regeln` (Rule Set `LT_REGELN`), in SERVER und INSESSION (Schleife wie die übrigen Szenarien); Kopfkommentar in `FEATURES/REGELN/test_regeln.sql` ergänzt.
- **LC-01** (`LOGGING`, `LOG_CONTAINS` `RG_LC_TEXT`, Prozess `_LC`): INFO- und ERROR-Log mit dem Text in gemischter Schreibweise, ein Log ohne Text → erwartet 2.
- **LC-02** (`LOGGING`, `LOG_CONTAINS` `ERROR|RG_LC_LVL`, Prozess `_LC`): INFO-Log mit Text, ERROR-Log mit Text → erwartet 1.
- **AV-02** (`TRACE_STOP`, `AVG_DEVIATION_PCT` `100|3|0.1`, Prozess `_AV0`): vier Traces mit festen Zeitstempeln (`p_timestamp`), Dauern 1, 0, 0, 1 ms → Durchschnitt vor der 4. Messung 1/3 ms, 1 ms wäre +200 % → erwartet 0 (mit dem alten Code 1).
- **L3** um Versionen 13 (`PRECEDED_BY` bei `TRACE_STOP`) und 14 (`LOG_CONTAINS` `ERROR|`, leerer Text) erweitert: erwartet 12 statt 10 Ablehnungen mit `NUM_ERR_RULE_SET`; die folgenden Prüfungen „aktives Rule Set unverändert“ und „Regeln aus Version 1 bleiben aktiv“ gelten auch dafür.
- Alle Regeln mit `throttle_seconds` 0. Neue Prüfungen laufen über `check_that` in die Auswertung ein; vorhandene Fälle unverändert (außer Zähler und Text von L3).
- **Noch nicht gelaufen; Dirk startet die Tests am Ende.** Nächster Schritt: Commit nach Dirks Freigabe.

**07.10.2026, Commit Testergänzung:** Mit Dirks Freigabe committet und gepusht: `946a538` auf `claude` (nur `01_install_testbasis.sql` und `test_regeln.sql`). Tests noch nicht gelaufen. Offen: Pull Request durch Dirk, Testlauf.

- **07.10.2026 (aus C1, N1, Dirk: im Code in C4 reparieren):** `PRECEDED_BY_WITHIN_SECS` bei PROCESS_UPDATE/PROCESS_STOP: der Zeitteil schlägt nie an, weil `evaluateRules_internal` (~1307) das Ende des Vorgängers mit `p_ctx.start_time` = Prozessstart vergleicht. Vorschlag: für Prozess-Trigger SYSTIMESTAMP bzw. `last_update` verwenden.

**07.10.2026, N1 von C1 übernommen:** `PRECEDED_BY_WITHIN_SECS` vergleicht bei `PROCESS_UPDATE`/`PROCESS_STOP` mit dem Prozessstart, der Zeitteil greift nie. Der Entwurf liegt vor (`N1_entwurf.md`): Bezugszeit ist das Signal (`process_end` bzw. der Zeitstempel aus `setAnyStatus`, `SYSTIMESTAMP` nur als Rückfall); Test VG-05 mit Pause 1,3 s (ein fester Zeitstempel 5 s in der Vergangenheit würde den Fehler nicht zeigen). Umsetzung nach der Sperre für `lilam.pkb` (liegt bei C1); Dirks Ja zu Commit und Push liegt vor.

**07.10.2026, N1 umgesetzt:** Nach der Sperrmeldung Entwurf auf `df6fe2d` angewendet (Variante `p_signalTime` aus `setAnyStatus`, `g_process_cache.lastUpdate` unverändert), mit Dirks Freigabe committet und gepusht: `42e6731` auf `claude` (`lilam.pkb`, `01_install_testbasis.sql`, `test_regeln.sql`). Nicht kompiliert, Tests noch nicht gelaufen. Doku-Vorschläge siehe `N1_entwurf.md` (optional, bei C1).
