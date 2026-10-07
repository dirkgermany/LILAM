# Projekt REGELN_FEHLER: Fehler in der Regel-Engine beheben

**Angelegt:** 06.10.2026 auf Dirks Anweisung.
**Zweck dieser Datei:** Startpunkt für ein neues Kontext-Fenster. Sie enthält alles, was Claude für die Arbeit an einem Fall braucht; `CLAUDE_ANWEISUNGEN.md` muss dafür **nicht** gelesen werden (Abschnitt 7 fasst die Regeln zusammen).
**Pflege:** Claude hält diese Datei und die Statustabelle (Abschnitt 5) nach jedem Arbeitsschritt aktuell. Anweisungen von Dirk zu diesem Projekt kommen in Abschnitt 8.

---

## 0. Ein Fall je Kontextfenster (Dirks Vorgabe, 06.10.2026)

Jeder Fall wird in einem eigenen, frischen Fenster bearbeitet, damit der Kontext kurz und die Kosten niedrig bleiben.

**Start eines Fall-Fensters** (Sitzungsverzeichnis `C:\Users\dirk\Documents\LILAM`):

> Lies `lilam\test\autotest\REGELN_FEHLER\PROJEKT_KONTEXT.md` und bearbeite Fall **B1**.

**Was Claude dann liest, und nur das:**
1. diese Datei;
2. `<Fallordner>\FALL.md` des genannten Falls (bei gemeinsam angegangenen Fällen beide, z. B. B1 und B2);
3. `G_Grundsatzfragen\FALL.md`, falls der Fall von einer Grundsatzfrage abhängt;
4. aus der Analyse nur die Abschnitte, die `FALL.md` unter „Quelle“ nennt; aus dem Code nur die betroffenen Stellen (per Suche, nicht ganze Dateien lesen; `lilam.pkb` ist groß).

**Was ein Fall-Fenster schreibt:**
- Ergebnisse, Vorschläge und Entscheidungen in `FALL.md` des Falls (Protokoll, Schritte abhaken); Arbeitsdateien in dessen Ordner.
- In dieser Datei nur die **eigene Zeile** der Statustabelle (Abschnitt 5). Erkenntnisse, die andere Fälle betreffen, als kurzen Hinweis ins Protokoll des anderen Falls schreiben.
- Entscheidet Dirk eine Grundsatzfrage, in `G_Grundsatzfragen\FALL.md` und Abschnitt 6 eintragen.
- Ist der Fall abgeschlossen oder pausiert, steht in `FALL.md` der nächste Schritt, sodass ein späteres Fenster ohne Vorwissen weitermachen kann.

**Parallel arbeitende Fenster:** Mehrere Fall-Fenster gleichzeitig sind möglich, solange sie verschiedene Dateien ändern. `lilam.pkb`, die Doku und Commits auf `claude` aber nur aus **einem** Fenster zur Zeit; vor dem Ändern einer gemeinsamen Datei neu einlesen (Dirk oder ein anderes Fenster kann sie geändert haben).

## 1. Übergeordnete Aufgabe

Die Analyse `lilam\test\autotest\FEATURES\REGELN\results\2026-10-04_regeln_analyse.md` (04.10.2026, LILAM-Stand d2bf421) listet mehrere, zum Teil schwerwiegende Fehler und Lücken der Regel-Engine (Rules Engine) von LILAM auf. Dieses Projekt arbeitet sie **Fall für Fall** ab:

1. Fall gegen den **aktuellen** Code prüfen (die Analyse ist älter; einiges kann inzwischen behoben sein, z. B. INSESSION-Regeln seit PR #13).
   **Wichtig:** Commit **fe863f1** (04.10.2026 20:51, „Regeln: Auswertung und Laden korrigiert, Consumer repariert, Test FEATURES/REGELN“) kam *nach* der Analyse und behebt laut Meldung: CASE mit ELSE und Fehler je Regel (B1, B2), `PRECEDED_BY*` mit getrenntem Kontext und nur Events/Traces als Vorgänger (B3, B4), Prüfung beim Laden und nur vollständige Übernahme, Registry erst nach erfolgreichem Laden (B5, C2), NLS-unabhängige Werte, `MAX_GAP_SECONDS`/`MAX_OCCURRENCE`/`RUNTIME_EXCEEDED` wie dokumentiert (C1), `fire_alert` mit Rollback, Consumer repariert (C3). Jeden Fall daher zuerst mit `git show fe863f1` und dem Test `lt.t_regeln` abgleichen. B1 und B2 sind so bereits bestätigt.
2. Vorschlag mit Begründung und Alternativen vorlegen, **Dirk entscheidet**.
3. Nach Freigabe umsetzen, testen (nur auf Dirks Anweisung), Doku angleichen, Ergebnis im Fallordner festhalten.

Priorität laut Analyse (Fazit): zuerst B1/B2, dann B3/B4 und B5, danach Test und Doku angleichen. Reihenfolge verbindlich mit Dirk abstimmen.

## 2. Pfade

| Was | Pfad |
|---|---|
| Projektordner (dieser Ordner, im Klon, Branch `claude`) | `C:\Users\dirk\Documents\LILAM\lilam\test\autotest\REGELN_FEHLER\` |
| Klon (Branch `claude`, Arbeitsstand) | `C:\Users\dirk\Documents\LILAM\lilam\` |
| Allgemeine Anweisungen und Stand (nur bei Bedarf) | `C:\Users\dirk\Documents\LILAM\CLAUDE_ANWEISUNGEN.md` (außerhalb von Git) |
| Package (Spec / Body) | `lilam\source\package\lilam.pks` / `lilam.pkb` |
| Rule-Sets, Beispiele | `lilam\rules\` (`README.md`, `metro_rule_set_v1.json`) |
| Consumer / Mailer | `lilam\consumer\` (`lilam_consumer`, `lilam_mailer`, `README.md`) |
| Doku | `lilam\docs\` (`API_DE.md` ist der Master, CRLF; `API.md`; `architecture and concepts.md`) |
| Analyse (Ausgangspunkt) | `lilam\test\autotest\FEATURES\REGELN\results\2026-10-04_regeln_analyse.md` |
| Diagnoseskripte Regeln | `lilam\test\autotest\FEATURES\REGELN\` (`2026-10-04_regeln_probe.sql`, `…_regeln_perf.sql`, `2026-10-05_insession_regeln_*.sql`) |
| Autotest Regeln | `lilam\test\autotest\FEATURES\REGELN\test_regeln.sql` (Logik: Package `LT`, `lt.t_regeln`); Leistung: `FEATURES\REGELN_LAST\` (`lt.t_regeln_last`) |
| Weitere Berichte | `FEATURES\REGELN\results\` (u. a. `2026-10-05_run721-722.md` INSESSION-Regeln, `2026-10-05_systimestamp_analyse.md`) |
| Testbasis (Package `LT`) | `lilam\test\autotest\_COMMON\01_install_testbasis.sql`; Übersicht `test\autotest\README.md` |

Der Projektordner liegt seit 07.10.2026 vorläufig im Klon unter `test\autotest\REGELN_FEHLER\` und wird mit auf `claude` committet (Entscheidung Dirk). Was dauerhaft ins Repository gehört (Codeänderungen, Tests, Doku, Berichte), wird im Klon geändert und auf `claude` committet (siehe `CLAUDE_ANWEISUNGEN.md`, Regel 4). Berichte zu Testläufen kommen in `FEATURES\REGELN\results\` bzw. `REGELN_LAST\results\` (Format `JJJJ-MM-TT_run<n>[-<m>].md`, mit Gesamtlaufzeit).

## 3. Datenbank

- **Oracle 23.26 Free**, PDB `FREEPDB1`, Schema **`LILAM_TEST`**, 2 CPU-Threads, `job_queue_processes = 20`.
- Zugriff über die gespeicherte SQLcl-Verbindung **`lilam_test`** (SQLcl-MCP: `connect`, `sql_run`, `sqlcl_run`). Keine Passwörter in Dateien oder Chat.
- Lange Läufe mit `execution_type = ASYNCHRONOUS` und `request_status`; Wartezeiten nacheinander. `@skript.sql` über `sqlcl_run` liefert `dbms_output`; anonyme Blöcke über `sql_run` (asynchron) nicht.
- Kompilieren: `@C:\Users\dirk\Documents\LILAM\lilam\source\package\lilam.pkb` über `sqlcl_run` (vorher Server stoppen: `lt.stop_all_servers`, sonst Library-Cache-Pin). Testbasis: `@…\test\autotest\_COMMON\01_install_testbasis.sql`.
- **Relevante Objekte:**
  - Tabellen: `LILAM_RULES` (Rule Sets, `RULE_SET IS JSON`; Spalten u. a. `SET_NAME`, `VERSION`, `GROUP_NAME`), `LILAM_ALERTS` (Alert-Zeilen), `LILAM_SERVER_REGISTRY` (u. a. `RULE_SET_NAME`, `SET_IN_USE`), `LILAM_LOG_INTERNAL` (interne Fehler), `LILAM_MON`, `LILAM_LOG`, `LILAM_PROC`, `LILAM_BASELINES`.
  - Testtabellen: `LT_RUN`, `LT_CHECK`, `LT_METRIC`, `LT_JOBLOG`; Server `LT_S1`, `LT_S2`, Dispatcher `LT_DISP`; Ergebnisübersicht `_COMMON\03_ergebnisse.sql`.
  - Rule-Set-Namen der Tests: `LT_REGELN` (Autotest), `LT_RULES` (Probe); Prozesspräfixe `LT_RG_*`, `LT_RP_*`.
- **Altlast aus den Diagnoseläufen vom 04.10.2026:** rund 20.135 Alerts (`LT_RG_*`, `LT_RP_*`) in `LILAM_ALERTS` und ca. 20.050 interne Fehler in `LILAM_LOG_INTERNAL`; vor Messungen den aktuellen Stand lesen, nicht annehmen.
- Das einzige weitere Rule Set in der DB war `BASELINE_TEST` (Handtest).

## 4. Fachlicher Kontext zur Regel-Engine (aus der Analyse; im Code verifizieren)

- Regeln liegen als JSON je Rule Set (`header.rule_set`, `version`, Regelliste). Geladen werden sie aus `LILAM_RULES` per `loadServerRules` / `load_rules_from_json` (Server) bzw. je Gruppe (`refreshGroupRules`, INSESSION, seit 05.10.2026).
- Prüfung in `evaluateRules_internal` (ein `EXCEPTION`-Block um alle Regeln), Alerts über `fire_alert` (Insert in `LILAM_ALERTS`, Commit in autonomer Transaktion, danach `DBMS_ALERT.SIGNAL`). Drosselung `throttle_seconds` je Scope/Regel/Action.
- Trigger (Code): `PROCESS_START`, `PROCESS_UPDATE`, `PROCESS_STOP`, `MARK_EVENT`, `TRACE_START`, `TRACE_STOP`, `LOGGING`.
- `SERVER_UPDATE_RULES` / `updateRulesInRegistry` / `readServerRules`: Aktualisierung über Pipe an *einen* Server.
- Doku verteilt auf `rules\README.md`, `docs\architecture and concepts.md`, `docs\API_DE.md`; sie widerspricht sich und dem Code (Fall C1).
- Wichtig für alle Änderungen: **Stabilität vor Performance vor Lesbarkeit**; ein interner Fehler in LILAM darf die Anwendung nie beeinträchtigen. Code-Kommentare deutsch wie im Bestand; Kennzeichnung `STABILITÄT:` bzw. `PERFORMANCE:`.

## 5. Fälle und Status

Jeder Fall hat einen eigenen Ordner mit `FALL.md` (Befund, Nachweis, Schrittliste, Protokoll). Dort entstehen auch Arbeitsdateien (Prüfskripte, Entwürfe, Vorschläge, Ergebnisse), bevor sie ins Repository wandern.

Status: **offen** = noch nicht gegen den aktuellen Code geprüft; **geprüft** = Befund gegen Code verifiziert; **Vorschlag** = Vorschlag liegt Dirk vor; **freigegeben**; **umgesetzt** (Commit); **getestet**; **erledigt** (Doku, Test, PR).

| Ordner | Fall | Schwere (laut Analyse) | Status |
|---|---|---|---|
| `B1_CASE_ohne_ELSE` | `CASE` ohne `ELSE` in `evaluateRules_internal` ⇒ ORA-06592 je nicht zutreffender `SEVERITY`-Regel / unbekanntem Operator; Server 3–6× langsamer | hoch | **erledigt** 06.10.2026 (behoben in fe863f1, Tests 1569/1570) |
| `B2_Folgeregeln_uebersprungen` | Nach einer `SEVERITY=ERROR`-Regel greift eine nachfolgende Regel (z. B. `WARN`) nie (Folge von B1; ein `EXCEPTION`-Block um alle Regeln) | hoch | **erledigt** 06.10.2026 (behoben in fe863f1, Test LG-01/LG-02) |
| `B3_PRECEDED_BY_Kontext` | `PRECEDED_BY` mit Kontext des Vorgängers schlägt fälschlich an (`full_key` ohne `\|`) | mittel (Fehlalarm) | **erledigt** 07.10.2026 (behoben in fe863f1, Test VG-02, Lauf 1569) |
| `B4_Log_ueberschreibt_Vorgaenger` | Jeder Log-Aufruf überschreibt den „letzten Vorgänger“ (`LOGGING\|<Level>`) | mittel (Fehlalarm) | **erledigt** 07.10.2026 (behoben in fe863f1, Test VG-01, Lauf 1569); Rest in C4 |
| `B5_Laden_nicht_atomar` | Rule Set mit `"action": ""` bricht das Laden ab; Server ohne Regeln, Registry zeigt die neue Version; nicht existierende Version ebenso | hoch | **erledigt** 06.10.2026 (behoben in fe863f1, Lauf 1569); Testergänzung v6/L3c im Klon, noch nicht gelaufen |
| `B6_INSESSION_Regeln` | Regeln wirkten nur im SERVER-Modus. **Inzwischen weitgehend umgesetzt** (Branch `IN-SESSION-Rules`, PR #13, 05.10.2026, Gruppe aus `NEW_SESSION`); Rest: Doku und Abgleich | mittel | **committet** 06.10.2026 (b91a9aa, `claude`, nicht gepusht): Testergänzung REGELN/REGELN_LAST (INSESSION) und Doku-Reste; Testlauf durch Dirk offen; siehe `B6_INSESSION_Regeln\FALL.md` |
| `B7_SERVER_UPDATE_RULES_Ziel` | `SERVER_UPDATE_RULES` erreicht nur einen Server, über Dispatcher keinen; kein Weg ohne laufenden Prozess. **Nach der Analyse umgebaut** (je Servergruppe, de1c57e/fe4c21e) | hoch | **umgesetzt**, gepusht ec71648 07.10.2026 (nicht getestet) |
| `B8_Beispiel_JSON_ungueltig` | `rules\metro_rule_set_v1.json` mit Markdown-Zäunen und `"action": ""`; Komma fehlt in `rules\README.md` (SEQ-003) | niedrig | **erledigt** 07.10.2026 (Regel 11 von Dirk aufgehoben; JSON korrigiert: Zäune entfernt, Handler `LILAM_ALERT_MAIL_LOG`; Commit 716a6e7) |
| `C1_Doku_Abweichungen` | Doku widerspricht dem Code (Operatornamen, Trigger, Kontext-/Action-Regel, `MAX_GAP_SECONDS`, `MAX_OCCURRENCE`, `RUNTIME_EXCEEDED`, `AVG_DEVIATION_PCT`, Drosselung, Handler, Tabellenname) | mittel | **umgesetzt** 07.10.2026 (Commit `df6fe2d`; N1 an C4) |
| `C2_Validierung_beim_Laden` | Keine inhaltliche Prüfung des Rule Sets (Trigger, Operator, Werteformat, Pflichtfelder, Feldlängen) und keine Rückmeldung an den Aufrufer; Tabelle ohne PK/Unique | mittel | **umgesetzt** 06.10.2026 (Teil 1 de1c724, Teil 2 bf2ae37; G6 = C+; Tests am Projektende) |
| `C3_Alert_Schwaechen` | `fire_alert`: fehlender/zu langer Handler (ORA-06519 nach Insert), fehlende `id`, `to_number` ohne Formatmaske (NLS), Log zu unbekannter `process_id`, `g_alert_history` wächst; Consumer kompiliert nicht (`C_LILAM_ALERTS`); Handler-Namen `MAIL_LOG` vs. `LILAM_ALERT_MAIL_LOG` | mittel | Umsetzung (V2, V4 committet 35ae13d; V3, V5, V6 committet 2698909; nicht kompiliert, nicht getestet) |
| `C4_Weitere_Punkte` | `PRECEDED_BY` sieht nur das letzte Signal; ausbleibende Signale nicht erkennbar (keine zeitgesteuerte Prüfung); Regelsatz je Server; `AVG_DEVIATION_PCT` schlägt beim ersten Event an; toter Code `existsNewServerRule`; `g_avg_params` wird nicht geleert; Header-Name vs. `SET_NAME`; ungenutzte Registry-Spalten | niedrig bis mittel | **umgesetzt** 06.10.2026, Commit `11f4d56` auf claude: b–f erledigt; TRACE_STOP-Ablehnung, AVG < 1 ms, Altspalten/-index, LOG_CONTAINS; a bleibt (G5); Testergänzung LC-01/LC-02, AV-02, L3 (Versionen 13, 14) 07.10.2026, Commit `946a538` auf claude; N1 (PRECEDED_BY_WITHIN_SECS bei Prozess-Triggern, Test VG-05) Commit `42e6731` |
| `G_Grundsatzfragen` | Entscheidungen, die nur Dirk trifft (siehe Abschnitt 6) | – | **entschieden** 07.10.2026 (alle Fragen) |

Zusammenhänge: B1 und B2 gemeinsam angehen (eine Ursache: `CASE` ohne `ELSE` plus gemeinsamer `EXCEPTION`-Block). B5, C2 und B7 betreffen alle das Laden bzw. Verteilen der Rule Sets. B3, B4 und C4 (Punkt „letztes Signal“) hängen an derselben Vorgängerlogik. B8 und C1 sind reine Datei- bzw. Doku-Arbeit.

## 6. Grundsatzentscheidungen (nur Dirk)

1. Regeln auch im INSESSION-Modus? **Entschieden 07.10.2026: A, wie umgesetzt** (PR #13, Opt-in über die Gruppe).
2. Rule Set **global** oder **je Server**? **Entschieden 04.10.2026: je Servergruppe** (`SERVER_UPDATE_RULES(p_groupName, …)`, `LILAM_RULES.GROUP_NAME`; umgesetzt de1c57e, fe4c21e).
3. `PRECEDED_BY`: über alle Signale oder nur über Events und Traces? **Entschieden 04.10.2026 (vorläufig): nur Events und Traces**, keine Logs.
4. Wirkt eine Kontext-Regel **zusätzlich** zur Action-Regel oder statt ihr? **Entschieden 07.10.2026: A, zusätzlich** (wie im Code); `API_DE.md` bekommt den fehlenden Satz (C1).
5. Brauchen wir eine zeitgesteuerte Prüfung für ausbleibende Signale? **Entschieden 07.10.2026: A, nein**; Grenze bleibt dokumentiert (C4 a).
6. Wie streng soll die Validierung beim Laden sein? **Entschieden 06.10.2026: C+** (ganzes Rule Set ablehnen; zusätzlich unbekannte Schlüssel und Felder über 4000 Zeichen ablehnen; Prüffunktion `CHECK_RULE_SET`)

## 7. Arbeitsregeln (aus `CLAUDE_ANWEISUNGEN.md`, hier gekürzt)

- Antworten und Berichte auf Deutsch; kurz und klar; Verständnisfragen von Dirk zuerst beantworten.
- **Neue Tests nur auf Dirks Anweisung** (Diagnosemessungen im Rahmen eines erteilten Analyseauftrags sind erlaubt; nach Codeänderungen erst fragen, dann testen). Jeder Ergebnisbericht nennt die Gesamtlaufzeit.
- Vorschläge vor größeren Änderungen vorlegen und erst nach Freigabe umsetzen; Grundsätzliches (Benennung, Standardwerte, API-Umfang) entscheidet Dirk.
- Arbeiten im Klon nur auf Branch `claude` (`.git\HEAD` prüfen); Commit und Push nach `origin/claude` nur nach Dirks Freigabe; `main` ändert Claude nicht. Pull Requests legt Dirk an.
- Zeilenenden der vorhandenen Dateien nicht ändern (`docs\API_DE.md` hat CRLF). Vor dem Überschreiben prüfen, ob Dirk die Datei geändert hat.
- Diagnosen und Berichte gehören in den Merkmalsordner unter `FEATURES` (Berichte in `results\`), **nicht** in einen `_DIAG`-Ordner.
- Doku: `API_DE.md` und `architecture and concepts.md` immer mitpflegen; die englische `API.md` vorläufig ignorieren (Dirk, 04.10.2026).
- `rules\metro_rule_set_v1.json`: Die Sperre vom 04.10.2026 hat Dirk am 07.10.2026 aufgehoben (B8, Datei korrigiert).

## 8. Notizen und Anweisungen von Dirk zu diesem Projekt (von Claude geführt)

**06.10.2026**
1. Projektordner `C:\Users\dirk\Documents\LILAM\REGELN_FEHLER` angelegt, mit dieser Kontextdatei und je einem Ordner pro analysiertem Fall (Abschnitt 5). In den Fallordnern führen Dirk und Claude die Folgeschritte gemeinsam durch.
2. Diese Datei muss alle Informationen enthalten, die Claude für einen Neustart in einem neuen Kontext-Fenster braucht (Pfade, DB-Zugang, Schema, Aufgabe). Bei Änderungen ergänzen.
3. Stand der Analyse zum Anlegen: Die Statusspalte steht überall auf „offen“, weil noch kein Fall gegen den aktuellen Code geprüft wurde.

4. Jeder Fall wird in einem eigenen Kontextfenster bearbeitet, um die Kosten niedrig zu halten (Abschnitt 0). Die Entscheidungen vom 04.10.2026 zu den Grundsatzfragen 2 und 3 sowie zur Doku und zu `metro_rule_set_v1.json` sind nachgetragen; B7 ist dadurch vermutlich weitgehend erledigt.

5. B1 und B2 geprüft und von Dirk als erledigt geschlossen (behoben in fe863f1).

**07.10.2026**
6. B5 von Dirk geschlossen (behoben in fe863f1); Testergänzung Version 6 / L3c im Klon.
7. **Tests laufen erst am Ende**, wenn alle Befunde behoben oder als behoben markiert sind; Dirk startet sie selbst. Fall-Fenster lassen keine Tests laufen und fragen auch nicht danach; Testergänzungen werden nur eingebaut und im Fall protokolliert.
8. Projektordner von `C:\Users\dirk\Documents\LILAM\REGELN_FEHLER` nach `lilam\test\autotest\REGELN_FEHLER` verschoben (Dirk: Protokolle vorläufig im Repository). Verweise in dieser Datei, in `CLAUDE_ANWEISUNGEN.md` und in `test\autotest\README.md` angepasst.

9. B3 und B4 von Dirk geschlossen (behoben in fe863f1).

**Nächster Schritt (Vorschlag):** In einem neuen Fenster B3/B4 (Vorgängerlogik, gemeinsam) gegen den aktuellen Code und fe863f1 prüfen, danach B5.
