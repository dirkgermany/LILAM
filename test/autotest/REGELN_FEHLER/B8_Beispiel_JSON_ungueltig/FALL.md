# B8: Beispiel-JSON ungültig

- **Projekt:** REGELN_FEHLER (Kontext: `../PROJEKT_KONTEXT.md`)
- **Quelle:** Analyse `FEATURES\REGELN\results\2026-10-04_regeln_analyse.md`, Kurzfassung B8, Abschnitt 4
- **Schwere:** niedrig
- **Status:** erledigt 07.10.2026 (Regel 11 aufgehoben; Datei korrigiert und committet)

## Befund (laut Analyse vom 04.10.2026)

- `rules\metro_rule_set_v1.json` ist kein JSON: Die Datei beginnt mit einem Markdown-Zaun (json) und endet mit einem Zaun. Ohne Zäune ist der Inhalt gültig, enthält aber `"action": ""` (SEQ-009, siehe B5) und den Handler `MAIL_LOG`.
- `rules\README.md`, Beispiel SEQ-003: Das Komma nach `"context": "SECTION_400_001"` fehlt; außerdem steht `PRECEDED_BY_WITHIN_SECS` im Beispiel, in der Tabelle aber `_MS`.

## Belegt durch

Prüfung der Dateien.

## Wirkung

Beispiele sind nicht ladbar; der Einstieg für Anwender scheitert.

## Ansatz (zu prüfen, Dirk entscheidet)

Gültige Beispiel-Rule-Sets anlegen (unabhängig von den Tests), Fehler in `rules\README.md` beheben; die Namen müssen zu Operatoren und Handlern im Code passen (siehe C1, C3). Derselbe Auftrag steht in `lilam\CLAUDE_ANWEISUNGEN.md`, Abschnitt 5, Punkt 5 („Beispiel-Rule-Sets“).

## Schritte

- [x] 1. Dateien prüfen (JSON-Validierung); Ergebnis unten protokollieren
- [x] 2. Vorschlag Dirk vorlegen (Umfang der Beispiel-Rule-Sets)
- [x] 3. Entscheidung Dirk: A, ruhen lassen
- [x] 4. Umsetzung im Klon (Branch `claude`); Ladetest nur auf Dirks Anweisung
- [x] 5. `rules\README.md` und Doku angleichen (nicht nötig, README bereits korrekt)
- [x] 6. Commit nach Freigabe (Pull Request durch Dirk)

## Protokoll

_(Datum, Schritt, Ergebnis; neueste zuletzt.)_

**06.10.2026, Schritt 1 (Prüfung, Klon auf Branch `claude`, Stand nach 'Move _DIAG scripts…'):**
- `rules\README.md`: **bereits behoben.** SEQ-003 hat das Komma nach `"context"`, nutzt `MAX_DURATION_MS` und den Handler `LILAM_ALERT_MAIL_LOG`. Die Operatortabelle nennt `PRECEDED_BY_WITHIN_SECS`, wie der Code (`lilam.pkb` ~1305, ~6084). Kein Handlungsbedarf.
- `rules\metro_rule_set_v1.json`: weiterhin **kein gültiges JSON** (Zeile 1–2 und letzte Zeile: Markdown-Zaun ```` ```json ```` / ```` ``` ````). Ohne Zäune ist die Datei gültiges JSON (geprüft mit `json.tool`).
- `"action": ""` bei SEQ-009 (LOGGING) ist **kein Fehler mehr**: Die Prüfung beim Laden (`lilam.pkb` ~6040) erlaubt bei LOGGING-Regeln leere oder fehlende `action`. Alle Operatoren und Trigger der Datei passen zur Prüfung (~6079ff.).
- Handler `MAIL_LOG` (alle neun Regeln): passt nicht zum Mailer. `LILAM_MAILER.C_ALERT_MAIL_LOG = 'LILAM_ALERT_MAIL_LOG'` (Signalname), der Mailer filtert aber `handler_type = 'MAIL_LOG'` (`LILAM_MAILER.pkb` 155, 160). Welcher Name gilt, klärt C3 (dort bereits als Befund geführt).

**06.10.2026, Schritt 2 (Vorschlag an Dirk):**
- **A (empfohlen): JSON-Datei jetzt nicht ändern** (Regel 11). B8 ruht, bis Beispiel-Rule-Sets unabhängig von den Tests angelegt werden; dann wird `metro_rule_set_v1.json` durch eine gültige Datei mit dem in C3 festgelegten Handlernamen ersetzt. Grund: Die Regel gilt, und der Handlername hängt an C3.
- **B: Minimalkorrektur jetzt** (nur nach Aufhebung von Regel 11): beide Zäune entfernen; Handler erst nach C3 angleichen. Zwei Zeilen, Datei wird ladbar.
- **C: Beispiel-Rule-Sets jetzt neu anlegen** (z. B. `rules\examples\`), `metro_rule_set_v1.json` ersetzen. Größerer Umfang; Namen hängen an C1 und C3.
- README und Doku: nichts zu tun.

**06.10.2026, Schritt 3:** Dirk entscheidet **A**: Datei bleibt unverändert, B8 ruht.

**Nächster Schritt:** Wieder aufnehmen, wenn C3 den Handlernamen festgelegt hat und Beispiel-Rule-Sets unabhängig von den Tests angelegt werden; dann `metro_rule_set_v1.json` durch gültiges JSON ersetzen.

- **06.10.2026 (Hinweis aus C3):** Dirk hat den Handlernamen festgelegt: `LILAM_ALERT_MAIL_LOG`. `metro_rule_set_v1.json` nutzt noch `MAIL_LOG` (bleibt laut Regel 11 vorerst unverändert).

**07.10.2026, Wiederaufnahme nach C3:** Handler laut C3 `LILAM_ALERT_MAIL_LOG`. Abgleich mit der verschärften Ladeprüfung aus C2 (unbekannte Schlüssel, leere `|`-Teile): Die Datei ohne Zäune besteht sie (`_comment` wird übergangen, alle Schlüssel bekannt). Kein Test nutzt die Datei.

**07.10.2026, Entscheidung Dirk:** Regel 11 aufgehoben, Datei jetzt korrigieren. Umgesetzt: Markdown-Zäune entfernt, `MAIL_LOG` → `LILAM_ALERT_MAIL_LOG` (9 Regeln); sonst unverändert (LF). `rules\README.md` nicht geändert (C1 bearbeitet dort einen Absatz). Nicht in die DB geladen (Tests am Ende durch Dirk). Commit 716a6e7, gepusht nach origin/claude.

**Nächster Schritt:** keiner; Pull Request legt Dirk an.
