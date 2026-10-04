# Regeln und ihre Validierung: Analyse

**Datum:** 04.10.2026
**LILAM-Stand:** Branch `claude` (d2bf421), Package `LILAM` in der Datenbank = `source/package/lilam.pkb`
**Anlass:** Dirks 8 Fragen zu Regeln und Validierung
**Grundlage:** Code-Analyse von `lilam.pkb`, Doku (`rules/README.md`, `rules/metro_rule_set_v1.json`, `docs/architecture and concepts.md`, `docs/API_DE.md`, `consumer/`) und zwei Diagnoseläufe:

| Lauf | Skript | Inhalt | Ergebnis | Gesamtlaufzeit |
|---|---|---|---|---|
| Probe | `_DIAG/2026-10-04_regeln_probe.sql` | 15 Prüfregeln, 5 Phasen (Laden per API, Neustart, fehlerhaftes Rule Set, INSESSION) | 6 Abweichungen von Doku bzw. Erwartung | ca. 30 s |
| Leistung | `_DIAG/2026-10-04_regeln_perf.sql` | 9 Regelvarianten × 2 Durchgänge, je 10.000 Signale an LT_S1 (ohne Drosselung) | siehe Punkt 5 | ca. 5 min 15 s |

Beide Skripte stoppen ihren Server, setzen die Registry von LT_S1 zurück und löschen ihre Rule Sets wieder. In `LILAM_ALERTS` bleiben 20.135 Alerts der Prozesse `LT_RG_*` und `LT_RP_*`, in `LILAM_LOG_INTERNAL` rund 20.050 interne Fehler aus den Läufen (siehe Befund B2).

---

## Kurzfassung

Die Regeln funktionieren im Grundsatz (Laden, Neustart, Trigger, Alert-Zeile, Drosselung), haben aber mehrere echte Fehler. Die schwersten:

| Nr | Befund | Belegt durch | Wirkung |
|---|---|---|---|
| B1 | `CASE` ohne `ELSE` in `evaluateRules_internal`: Jede nicht zutreffende `SEVERITY`-Regel und jeder unbekannte Operator wirft ORA-06592 | Probe A–D, Leistung L_SEV (10.003 interne Fehler bei 10.000 INFO-Logs) | interner Fehler je Signal, Rest der Regelliste wird übersprungen, Server 3–6× langsamer |
| B2 | Mit einer `SEVERITY=ERROR`-Regel greift eine zweite Regel (z. B. `WARN`) nie, wenn sie hinter der ersten steht | Code (Folge von B1) | Alerts fehlen |
| B3 | `PRECEDED_BY` mit Kontext des Vorgängers schlägt fälschlich an (`full_key` ohne `|`) | Probe R04 | Fehlalarm |
| B4 | Jeder Log-Aufruf überschreibt den „letzten Vorgänger“ (`LOGGING|<Level>`) | Probe R06 | Fehlalarm bei `PRECEDED_BY` |
| B5 | Rule Set mit `"action": ""` (wie Beispiel SEQ-009) bricht das Laden ab; danach hat der Server **keine** Regeln, die Registry zeigt aber die neue Version | Probe D | alle Regeln weg |
| B6 | Regeln wirken nur im SERVER-Modus; INSESSION lädt nie Regeln | Probe E, Code (`loadServerRules` nur in `START_SERVER`) | in der Doku nicht erwähnt |
| B7 | `SERVER_UPDATE_RULES` erreicht nur einen Server und über einen Dispatcher gar keinen | Code | Regeln uneinheitlich bzw. stillschweigend nicht geladen |
| B8 | Beispiel-JSON ungültig: `metro_rule_set_v1.json` enthält Markdown-Zäune, Beispiel in `rules/README.md` fehlt ein Komma | Prüfung | nicht ladbar |

---

## 1. Laden der Regeln (API und Neustart)

**Funktioniert:**
- `SERVER_UPDATE_RULES` lädt das Rule Set und trägt es in `LILAM_SERVER_REGISTRY` ein (`RULE_SET_NAME`, `SET_IN_USE`). Probe A: Registry `LT_RULES v1`, Regeln greifen.
- Nach einem Neustart lädt der Server das Rule Set aus der Registry (`loadServerRules`). Probe C: `R09C` (PROCESS_START) und `R12` (MARK_EVENT) schlugen an.

**Fehler und Schwächen:**
- **B5 Laden ist nicht atomar.** `load_rules_from_json` löscht zuerst alle Regeln und füllt sie dann. Eine fehlerhafte Regel (leere `action` ⇒ Schlüssel NULL, ORA-06502) bricht ab; alles danach fehlt, der Header (Name/Version) wird nicht gesetzt. Die Registry wurde vorher schon auf die neue Version gesetzt (`updateRulesInRegistry` vor `readServerRules`). Folge: Server ohne Regeln, Registry zeigt v2, nach Neustart wieder Fehler. Dasselbe passiert, wenn die Version nicht existiert (Registry zeigt sie trotzdem).
- **B7 Zielserver.** `SERVER_UPDATE_RULES(p_processId, …)` sendet über `sendNoWait` an den Server, den die **aufrufende Session** für diese `process_id` kennt. Ruft ein Administrator die Prozedur aus einer anderen Session auf (wie im Beispiel in `rules/README.md`), wählt `getServerPipeForSession` irgendeinen freien Server. Mit Dispatcher-Konfiguration geht die Nachricht an den Dispatcher; dort fehlt `process_id` in der Payload, die Nachricht wird ohne Rückmeldung verworfen. Es gibt keinen Weg, alle Server (oder einen Server per Pipe-Namen) zu aktualisieren, und keinen Weg ohne laufenden Prozess.
- Im Mehrserver-Betrieb hat jeder Server sein eigenes Rule Set. Welche Regeln für einen Prozess gelten, hängt davon ab, welchem Server die Lastverteilung ihn zugeteilt hat.
- `existsNewServerRule` ist toter Code und fragt die nicht existierende Spalte `RULE_VERSION` ab.
- `g_avg_params` (Warm-up/Alpha je Regel) wird beim Neuladen nicht geleert; Werte entfernter Regeln bleiben wirksam.
- `LILAM_RULES` hat weder Primärschlüssel noch Unique-Index (Doku: `SET_NAME` ist PK). Doppelte Versionen führen zu TOO_MANY_ROWS.
- Der Header-Name (`header.rule_set`) und der Tabellenname (`SET_NAME`) sind unabhängig. LILAM schreibt den Header-Namen in den Alert, der Consumer sucht damit in `SET_NAME`. Weichen sie ab, findet der Consumer die Regel nicht.

## 2. Wird bei jeder Aktion geprüft?

| Aktion | Trigger | geprüft? | Bemerkung |
|---|---|---|---|
| neue Session | PROCESS_START | ja | Probe B/C |
| Status, Steps, Info | PROCESS_UPDATE | ja | Probe R07 |
| `PROC_STEP_DONE` | PROCESS_UPDATE | ja | über `setAnyStatus` (Code) |
| Session schließen | PROCESS_STOP | ja | Probe R08 |
| `MARK_EVENT` | MARK_EVENT | ja | nur wenn der Log-Level der Session Monitor zulässt |
| `TRACE_START` / `TRACE_STOP` | TRACE_START / TRACE_STOP | ja | Probe R01 |
| Logs | LOGGING | ja, **auch** wenn der Log-Level den Eintrag verwirft und auch für die internen INFO-Logs des Servers selbst | Folge siehe B1 |
| INSESSION-Modus | alle | **nein** (B6) | Regeln werden nur von Servern geladen |

Die eigenen Logs des Servers (z. B. „New remote session ordered“) laufen durch die LOGGING-Regeln. Mit einer `SEVERITY`-Regel erzeugt jede neue Session daher interne Fehler (Probe B: 4, ohne einen einzigen Client-Log).

## 3. Entspricht die Validierung der Doku?

Die Doku ist auf drei Stellen verteilt und widerspricht sich und dem Code:

| Thema | Doku | Code |
|---|---|---|
| Operator mit Zeitlimit | `PRECEDED_BY_WITHIN_MS`, Wert „name and context and milliseconds“ (`rules/README.md`) | `PRECEDED_BY_WITHIN_SECS`, Wert `ACTION|Sekunden`; der dokumentierte Name löst B1 aus (Probe R10) |
| Kontext- vs. Action-Regel | „falls keine Kontext-Regel, dann Action-Regel“ (architecture) | **beide** Listen werden geprüft |
| Trigger | `PROCESS_END` (architecture), `LOGGING` fehlt dort | `PROCESS_STOP`, `LOGGING` |
| `MAX_GAP_SECONDS` | Event **und** Transaction | wirkt nur bei MARK_EVENT; bei TRACE_START gibt es keinen Schatten mehr, bei TRACE_STOP ist der Abstand 0 (Probe R13: kein Alert) |
| `MAX_OCCURRENCE` | „consecutive signals“ bzw. Prozess: `STEPS_DONE > value` | `action_count` im Prozess (nicht aufeinanderfolgend); Prozess: `STEPS_TODO − STEPS_DONE > value` |
| `RUNTIME_EXCEEDED` | `SYSTIMESTAMP − PROCESS_START > value` | `SYSTIMESTAMP − LAST_UPDATE`; wird nur bei einem Signal geprüft, also nie für einen hängenden Prozess |
| `AVG_DEVIATION_PCT` | scope „all“, Warm-up-Standard 100 | nur Monitor; Standard-Warm-up 3 (`g_avg_params('DEFAULT')`) |
| Prozess-Operatoren | in `rules/README.md` fehlen `RUNTIME_EXCEEDED`, `MAX_RUNTIME_EXCEEDED`, `STEPS_LEFT_HIGH`, `SUCCESS_RATE_LOW`, `STATUS_EQUALS`, `INFO_CONTAINS` | vorhanden |
| Drosselung | Tabelle: `throttle` | `throttle_seconds`; der Consumer liest wieder `throttle` |
| Handler | Beispiel `MAIL_LOG` | der Mail-Consumer hört auf `LILAM_ALERT_MAIL_LOG`; Beispielregeln erreichen ihn nie |
| „Event B muss A innerhalb X folgen“ | `rules/README.md` (Hinweis) | nur prüfbar, wenn B eintrifft; ein **ausbleibendes** B erkennt LILAM nicht (keine zeitgesteuerte Prüfung) |
| Beispiel in architecture | `RUNTIME_EXCEEDED` mit Trigger `TRACE_STOP` | Prozess-Operator auf Monitor-Trigger: schlägt nie an |
| Tabellenname | `LILA_RULES` (architecture) | `LILAM_RULES` |

## 4. Ist die JSON-Struktur valide?

- `rules/metro_rule_set_v1.json` ist **kein** JSON: die Datei beginnt mit ```` ```json ```` und endet mit ```` ``` ````. Ohne die Zäune ist der Inhalt gültig, enthält aber `"action": ""` (SEQ-009, siehe B5) und Handler `MAIL_LOG`.
- `rules/README.md`, Beispiel SEQ-003: Komma nach `"context": "SECTION_400_001"` fehlt; außerdem `PRECEDED_BY_WITHIN_SECS` im Beispiel, aber `_MS` in der Tabelle.
- `docs/architecture and concepts.md`: syntaktisch gültig, inhaltlich falsch (siehe Punkt 3).
- In der Datenbank prüft nur `CHECK (rule_set IS JSON)`. Es gibt keine inhaltliche Prüfung beim Laden: unbekannte Trigger schlagen still nie an, unbekannte Operatoren erzeugen B1 zur Laufzeit, falsch geschriebene Schlüssel (`throttle`) werden still zu NULL. Werte länger als die `JSON_TABLE`-Spalten (z. B. `action` > 50 Zeichen) werden durch `NULL ON ERROR` still zu NULL und lösen B5 aus.

## 5. Beeinträchtigt die Prüfung die Leistung?

Messung: 10.000 Signale je Variante an einen Server (ohne Drosselung), Zeit vom ersten Senden bis alle Zeilen in `LILAM_MON` bzw. `LILAM_LOG` stehen. Die Zeit enthält die Flush-Verzögerung (bis 1,8 s) und streut auf der Free-Edition (2 CPU-Threads) stark; Aussagen nur über deutliche Unterschiede.

| Variante | Lauf 1 ms | Lauf 2 ms | Alerts | interne Fehler |
|---|---|---|---|---|
| E_NONE: keine Regeln | 5.558 | 3.257 | 0 | 0 |
| E_OTHER50: 50 Regeln auf andere Actions | 5.202 | 2.190 | 0 | 0 |
| E_MATCH1: 1 passende Regel | 3.770 | 3.911 | 0 | 0 |
| E_MATCH20: 20 passende Regeln | 5.378 | 7.412 | 10 | 0 |
| E_MATCH100: 100 passende Regeln | 12.886 | 10.203 | 51 | 0 |
| E_FIRE0: jedes Event ein Alert (throttle 0) | 77.798 | 40.850 | 10.000 | 0 |
| E_FIRE60: wie FIRE0, throttle 60 | 2.283 | 2.244 | 1 | 0 |
| L_NONE: 10.000 INFO-Logs, keine Regeln | 6.825 | 4.378 | 0 | 0 |
| L_SEV: 10.000 INFO-Logs, Regel `SEVERITY=ERROR` | 17.200 | 40.420 | 0 | 10.003 |

**Ergebnis:**
- **Anzahl der Regeln insgesamt:** kein messbarer Einfluss. Regeln auf andere Actions kosten nur einen Map-Lookup.
- **Anzahl passender Regeln je Action:** linear. 100 passende Regeln verlangsamen den Server etwa um den Faktor 2–3 (≈ 6 µs je Regel und Signal). Bis ca. 20 Regeln je Action liegt der Effekt im Rauschen.
- **Typ der Regel:** die Bewertung selbst ist billig; teuer ist das **Anschlagen**. Ein Alert kostet 4–8 ms (Insert, Commit in autonomer Transaktion, `DBMS_ALERT.SIGNAL`), also Faktor 10–20. Die Drosselung (`throttle_seconds`) hebt das fast vollständig auf.
- **B1 kostet am meisten:** Eine `SEVERITY`-Regel macht jeden nicht passenden Log zum internen Fehler mit Insert in `LILAM_LOG_INTERNAL` (Faktor 3–6).
- Nebenbefund: `AVG_DEVIATION_PCT` mit 100.000 % schlug beim ersten Event an (je 1 Alert pro Regel, danach gedrosselt). Vermutung: Bei Abständen nahe 0 ms ist der EWMA nach dem kurzen Warm-up (3) praktisch 0, jede Messung > 0 ist dann eine „Abweichung“.

## 6. Reaktion auf Regelverstöße

**Funktioniert:** Alert-Zeile in `LILAM_ALERTS` mit Prozess, Action, Kontext, Rule-ID, Rule-Set-Name/-Version, Severity, Handler und Status `PENDING`; Drosselung je Scope/Regel/Action (Probe R12: 2 Events, 1 Alert); Write-then-Signal mit Commit.

**Schwächen:**
- Fehlt der Handler oder ist er länger als 30 Zeichen, scheitert `DBMS_ALERT.SIGNAL` **nach** dem Insert; die Ausnahme verlässt die autonome Transaktion ohne Rollback (ORA-06519). Der Alert geht verloren, und die restlichen Regeln der Liste werden übersprungen. (aus dem Code abgeleitet, nicht gemessen)
- Fehlende `id` ⇒ `RULE_ID NOT NULL` verletzt ⇒ wie oben.
- `MAX_DURATION_MS`, `MAX_GAP_SECONDS`, `STATUS_EQUALS` u. a. wandeln den Wert ohne Formatmaske (`to_number`); `1.5` scheitert unter deutschen NLS-Einstellungen. (Vermutung, nicht gemessen; `extractRuleValue` macht es richtig)
- Ein Log zu einer unbekannten `process_id` läuft trotzdem durch die LOGGING-Regeln; schlägt eine an, scheitert `fire_alert` an `v_indexSession`.
- `g_alert_history` wächst bei Prozessen ohne Scope (`#NONE`) mit jeder `process_id` und wird nur beim Neuladen der Regeln geleert.
- Consumer: `LILAM_CONSUMER.pkb` verweist auf `LILAM.C_LILAM_ALERTS` (im Spec heißt die Konstante `C_LILAM_ALERTS_TABLE`) und lässt sich so nicht kompilieren; er liest `$.alert.throttle`. Weder Consumer noch Mailer sind in LILAM_TEST installiert; das Signal selbst habe ich nicht empfangen und geprüft.

## 7. Weitere Punkte

1. Fehler in einer Regel brechen die ganze Liste ab (ein `EXCEPTION`-Block um alle Regeln). Besser je Regel abfangen.
2. Keine Prüfung des Rule Sets beim Laden (Trigger, Operator, Wertformat, Pflichtfelder) und keine Rückmeldung an den Aufrufer.
3. Kein zeitgesteuertes Prüfen: „Nachfolger bleibt aus“, „Prozess hängt“ (`RUNTIME_EXCEEDED`) und offene Traces sind nicht erkennbar. Der Purge offener Traces hat nur einen Kommentar „HIER: Alert-Logik einbauen“.
4. `PRECEDED_BY` sieht nur das letzte Signal des Prozesses, über alle Actions hinweg, einschließlich TRACE_STOP der eigenen Action und Logs. Das ist sehr streng und nirgends beschrieben.
5. Regelsatz je Server statt global: Entscheidung nötig, ob das so bleiben soll (README wirbt damit: „Different worker instances can run different versions“).
6. Es gibt keinen einzigen automatischen Test für Regeln; das einzige Rule Set in der Datenbank (`BASELINE_TEST`) gehört zu einem Handtest.

## 8. Testvorschlag: FEATURES/REGELN

Neuer Test im Package `LT` (`t_regeln`), Wrapper `FEATURES/REGELN/test_regeln.sql`, Server LT_S1 (für R-L6 zusätzlich LT_S2 und LT_DISP). Ein eigenes Rule Set `LT_REGELN` mit deutlich mehr Regeln als im Repository, abgelegt als gültige Datei `FEATURES/REGELN/lt_regeln_v1.json` und vom Test in `LILAM_RULES` eingespielt. Jede Prüfung zählt Alerts je `rule_id` und interne Fehler. Läuft im SERVER-Modus; für INSESSION nur die Prüfung „keine Regeln“ (bzw. die künftige Soll-Funktion). Laufzeit geschätzt unter 30 s ohne Leistungsteil.

**Regeln und Prüfungen** (erwartetes Ergebnis laut Doku; heute scheiternde Prüfungen markiert ✗):

| Gruppe | Regel / Szenario | erwartet |
|---|---|---|
| Vorgänger | `PRECEDED_BY`: richtiger Vorgänger ohne Kontext | 0 Alerts |
| | richtiger Vorgänger **mit** Kontext ✗ (B3) | 0 |
| | falscher Vorgänger | 1 |
| | kein Vorgänger (erstes Signal) | 1 |
| | Log zwischen Vorgänger und Signal ✗ (B4) | 0 |
| | Kontext-genaue Vorgabe `A|C1` | 0 bei A/C1, 1 bei A/C2 |
| Vorgänger mit Zeit | `PRECEDED_BY_WITHIN_SECS`: rechtzeitig / zu spät / falscher Vorgänger | 0 / 1 / 1 |
| Nachfolger | „B folgt A innerhalb X“ als Paar `PRECEDED_BY_WITHIN_SECS` auf B | B rechtzeitig 0, B zu spät 1; **B bleibt aus ✗** (nicht unterstützt, Punkt 7.3) |
| Abstand | `MAX_GAP_SECONDS` bei MARK_EVENT (unter/über Grenze) | 0 / 1 |
| | `MAX_GAP_SECONDS` bei TRACE_START ✗ | 1 |
| Dauer | `MAX_DURATION_MS` bei TRACE_STOP und MARK_EVENT | 0 / 1 |
| Häufigkeit | `MAX_OCCURRENCE` 3 bei 5 Events | ab dem 4. Event je 1 (throttle 0) |
| Abweichung | `AVG_DEVIATION_PCT 50|5|0.5`: 5 Warm-up-Traces 100 ms, dann 120 ms und 300 ms | 0 / 1 |
| Prozess | `STATUS_EQUALS`, `INFO_CONTAINS`, `STEPS_LEFT_HIGH`, `SUCCESS_RATE_LOW`, `MAX_RUNTIME_EXCEEDED`, `ON_START`, `ON_UPDATE` | je 1 |
| Log | `SEVERITY=ERROR` und `SEVERITY=WARN` hintereinander; je 1 ERROR, WARN, 10 INFO | ERROR 1, WARN 1 ✗ (B2), 0 interne Fehler ✗ (B1) |
| Kontext vs. Action | Kontext-Regel und Action-Regel auf dieselbe Action | Soll klären (Doku: nur Kontext-Regel) |
| Trigger-Filter | Regel mit falschem Trigger | 0 |
| Drosselung | `ON_EVENT` throttle 2 s: 3 Events, 2,5 s Pause, 1 Event | 2 |
| Alert-Inhalt | Spalten der Alert-Zeile; Test-Session registriert sich mit `DBMS_ALERT.REGISTER` und prüft Payload (`alert_id` = Zeile) | stimmt |
| Laden L1 | `SERVER_UPDATE_RULES`, Registry-Eintrag | Name/Version in Registry |
| Laden L2 | Neustart des Servers | Regeln wirken ohne Update |
| Laden L3 | Wechsel v1 → v2 | nur v2-Regeln wirken, Drosselung zurückgesetzt |
| Laden L4 | ungültiges Rule Set (leere `action`) ✗ (B5) | alte Regeln bleiben, Registry unverändert, Fehler gemeldet |
| Laden L5 | nicht existierende Version ✗ | Registry unverändert |
| Laden L6 | Update aus fremder Session und über Dispatcher ✗ (B7) | Zielserver lädt die Regeln |
| Robustheit | unbekannter Operator, fehlender Handler, Wert `1.5` | kein Abbruch der übrigen Regeln, je höchstens 1 interner Fehler |
| Gesamt | keine internen Fehler außer den erwarteten | 0 |

**Leistungsteil (getrennt, `t_regeln_last`)**: die Varianten aus Punkt 5 als Metriken, mit Grenzwerten relativ zu E_NONE (z. B. E_OTHER50 ≤ 1,5×, E_MATCH20 ≤ 2×, L_SEV ≤ 1,5×). Wegen der Streuung im Median aus mindestens 3 Läufen.

---

## Fazit

Laden, Neustart und das Erzeugen von Alerts funktionieren im Normalfall. Sechs Befunde sind echte Fehler (B1–B5, B7), B1 kostet zusätzlich deutlich Leistung. Die Doku beschreibt teils andere Operatoren und Werte als der Code; die Beispiel-JSONs sind nicht ladbar. Es fehlt jeder automatische Test. Vorschlag: zuerst B1/B2 (eine Zeile `ELSE NULL` plus Ausnahme je Regel), B3/B4 und B5 korrigieren, dann den Test FEATURES/REGELN anlegen und die Doku angleichen. Offene Grundsatzfragen für Dirk: Regeln auch im INSESSION-Modus? Rule Set global oder je Server? `PRECEDED_BY` über alle Signale oder nur über Events/Traces?
