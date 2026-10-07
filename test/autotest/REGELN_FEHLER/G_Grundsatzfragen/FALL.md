# G: Grundsatzfragen (nur Dirk entscheidet)

- **Projekt:** REGELN_FEHLER (Kontext: `../PROJEKT_KONTEXT.md`)
- **Quelle:** Analyse `FEATURES\REGELN\results\2026-10-04_regeln_analyse.md`, Fazit und Abschnitt 7
- **Status:** erledigt (alle Grundsatzfragen entschieden, 07.10.2026)

Diese Entscheidungen bestimmen, wie mehrere Fälle gelöst werden. Claude legt je Frage Optionen mit Begründung vor; Dirk entscheidet, das Ergebnis wird hier festgehalten.

| Nr | Frage | Betrifft | Entscheidung |
|---|---|---|---|
| 1 | Regeln auch im INSESSION-Modus? (inzwischen umgesetzt, PR #13) | B6 | **entschieden 07.10.2026: A, wie umgesetzt** |
| 2 | Rule Set global oder je Server? (README: „Different worker instances can run different versions“) | B7, C4 | **entschieden 04.10.2026: je Servergruppe** (siehe Protokoll) |
| 3 | `PRECEDED_BY`: über alle Signale oder nur über Events und Traces? Logs als Vorgänger? | B3, B4, C4 | **entschieden 04.10.2026 (vorläufig): nur Events und Traces**, keine Logs |
| 4 | Kontext-Regel zusätzlich zur Action-Regel oder statt ihr? | C1 | **entschieden 07.10.2026: A, zusätzlich** |
| 5 | Zeitgesteuerte Prüfung für ausbleibende Signale („B folgt A nicht“, hängender Prozess)? | C4 | **entschieden 07.10.2026: A, nein** |
| 6 | Wie streng soll die Validierung beim Laden sein (ganzes Rule Set oder einzelne Regeln ablehnen)? | B5, C2 | **entschieden 06.10.2026: C+** (siehe Protokoll) |

## Protokoll

_(Datum, Entscheidung, Begründung.)_

- **04.10.2026 (Thread „Regeln und Validierung“, nachgetragen am 06.10.2026 aus Claudes Notizen):**
  - Frage 3: `PRECEDED_BY` / `PRECEDED_BY_WITHIN_SECS` berücksichtigen vorläufig nur Events und Traces als Vorgänger, keine Logs. Vorgemerkt für später: Regeln, die auf konkrete Logs reagieren (z. B. INFO mit bestimmtem Text).
  - Frage 2: Rule Sets gelten je Servergruppe. `SERVER_UPDATE_RULES(p_groupName, p_ruleSetName, p_ruleSetVersion)`, alte Signatur mit `p_processId` entfernt (Commit de1c57e). Rule Sets je Gruppe in `LILAM_RULES` (`GROUP_NAME`, `IS_ACTIVE`; mehrere Einträge je Rule Set für verschiedene Gruppen erwünscht), Rule-Spalten aus der Registry entfernt (Commit fe4c21e). Eine Gruppe ohne Server ist kein Fehler.
  - Beide Commits liegen **nach** dem Analysestand d2bf421.
- **06.10.2026:** Dirk bestätigt Frage 2 (je Servergruppe; „wird sich in den Testläufen bestätigen oder nicht“) und Frage 3 (nur Events und Traces als Vorgänger).
- **07.10.2026 (Dirk), Frage 5: A.** Keine zeitgesteuerte Prüfung. Die Grenze bleibt so dokumentiert (`rules\README.md` ~131, `architecture and concepts.md` ~251). Folge für C4 a: kein Umbau, nur Doku-Stand bestätigen.
- **07.10.2026 (Dirk), Frage 6: A.** Ein ungültiges Rule Set wird weiter als Ganzes abgelehnt, wie seit fe863f1. Die Verschärfungen aus Option C sind nicht beschlossen: falsch geschriebene Schlüssel und optionale Felder über 4000 Zeichen bleiben still. Folge für C2: kein Umbau an der Strenge.
- **07.10.2026 (Dirk), Frage 1: A.** Regeln im INSESSION-Modus bleiben wie umgesetzt (PR #13, Opt-in über die Gruppe). Folge für B6: keine Codeänderung, nur noch die Testergänzung für INSESSION in REGELN/REGELN_LAST.
- **07.10.2026 (Dirk), Frage 4: A.** Kontext-Regeln wirken zusätzlich zu den Action-Regeln, wie im Code. Folge für C1: Code bleibt, `API_DE.md` bekommt den fehlenden Satz (`rules\README.md` und `architecture and concepts.md` beschreiben es bereits).
- Damit sind alle Grundsatzfragen 1 bis 6 entschieden. Grundlage für die Fragen 1, 4 und 5 war die Vorlage `befunde/G_entscheidungsvorlage.md` im Projektordner (jeweils Option A).
- **06.10.2026 (Dirk, Thread C2):** Frage 6: **C+** statt A. Ein ungültiges Rule Set wird weiter als Ganzes abgelehnt; zusätzlich werden unbekannte Schlüssel (außer `_...`) und Felder, die Objekte, Arrays oder Texte über 4000 Zeichen sind, abgelehnt; neue Prüffunktion `CHECK_RULE_SET`. Umgesetzt in C2.
