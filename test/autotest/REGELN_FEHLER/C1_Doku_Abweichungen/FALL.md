# C1: Doku widerspricht dem Code

- **Projekt:** REGELN_FEHLER (Kontext: `../PROJEKT_KONTEXT.md`)
- **Quelle:** Analyse `FEATURES\REGELN\results\2026-10-04_regeln_analyse.md`, Abschnitt 3 (Tabelle)
- **Schwere:** mittel
- **Status:** umgesetzt und gepusht (07.10.2026), PR durch Dirk

## Befund (laut Analyse vom 04.10.2026)

Die Doku liegt auf drei Stellen verteilt (`rules\README.md`, `docs\architecture and concepts.md`, `docs\API_DE.md`) und widerspricht sich und dem Code:

| Thema | Doku | Code |
|---|---|---|
| Operator mit Zeitlimit | `PRECEDED_BY_WITHIN_MS` | `PRECEDED_BY_WITHIN_SECS`, Wert `ACTION|Sekunden` |
| Kontext- vs. Action-Regel | „falls keine Kontext-Regel, dann Action-Regel“ | beide Listen werden geprüft |
| Trigger | `PROCESS_END`, `LOGGING` fehlt | `PROCESS_STOP`, `LOGGING` |
| `MAX_GAP_SECONDS` | Event und Transaction | nur bei MARK_EVENT; TRACE_STOP Abstand 0 |
| `MAX_OCCURRENCE` | aufeinanderfolgende Signale; Prozess `STEPS_DONE > value` | `action_count` im Prozess; Prozess `STEPS_TODO − STEPS_DONE > value` |
| `RUNTIME_EXCEEDED` | `SYSTIMESTAMP − PROCESS_START` | `SYSTIMESTAMP − LAST_UPDATE`, nur bei einem Signal |
| `AVG_DEVIATION_PCT` | scope „all“, Warm-up 100 | nur Monitor, Warm-up 3 |
| Prozess-Operatoren | in `rules\README.md` fehlen `RUNTIME_EXCEEDED`, `MAX_RUNTIME_EXCEEDED`, `STEPS_LEFT_HIGH`, `SUCCESS_RATE_LOW`, `STATUS_EQUALS`, `INFO_CONTAINS` | vorhanden |
| Drosselung | `throttle` | `throttle_seconds` (Consumer liest `throttle`) |
| Handler | Beispiel `MAIL_LOG` | Mail-Consumer hört auf `LILAM_ALERT_MAIL_LOG` |
| „B folgt A innerhalb X“ | `rules\README.md` | nur prüfbar, wenn B eintrifft |
| Beispiel in architecture | `RUNTIME_EXCEEDED` mit Trigger `TRACE_STOP` | schlägt nie an |
| Tabellenname | `LILA_RULES` | `LILAM_RULES` |

## Belegt durch

Vergleich Doku gegen Code (Abschnitt 3 der Analyse); Probe R10, R13.

## Wirkung

Anwender schreiben Regeln, die nie oder falsch wirken.

## Ansatz (zu prüfen, Dirk entscheidet)

Je Eintrag entscheiden, ob Doku oder Code zu ändern ist (hängt an Grundsatzfragen 3 und 4); danach alle drei Dokumente aus einer Quelle angleichen. `API_DE.md` ist der Master (CRLF beachten). Zeitlich nach den Code-Fällen B1–B7 sinnvoll.

## Schritte

- [x] 1. Jede Zeile gegen den aktuellen Code prüfen (inzwischen Änderungen, z. B. INSESSION-Regeln); Ergebnis unten protokollieren
- [x] 2. Vorschlag Dirk vorlegen (Doku oder Code ändern, je Zeile)
- [x] 3. Freigabe durch Dirk
- [x] 4. Doku ändern (`API_DE.md`, `API.md`, `rules\README.md`, `architecture and concepts.md`)
- [x] 5. Commit nach Freigabe, Pull Request durch Dirk: Commit `df6fe2d` auf `claude` (gepusht); PR durch Dirk

## Protokoll

_(Datum, Schritt, Ergebnis; neueste zuletzt.)_

- **07.10.2026, Schritt 1–2:** Doku gegen Branch claude geprüft. Alle 13 Analysezeilen sind in der Doku behoben und stimmen mit dem Code. Neu: N1 `PRECEDED_BY_WITHIN_SECS` greift bei Prozess-Triggern zeitlich nie (Code, ~1307); N2 MARK_EVENT/TRACE_STOP-Regeln nur ab logLevelMonitor (undokumentiert); N3 README Subway-Satz zu fehlenden Events; N4 consumer\README HANDLER_TYPE; N5 API_DE.md gemischte Zeilenenden; N6 API_DE verweist für Operatoren auf rules\README.md; N7 Filtering Mechanism nur Server. Details: Projektordner befunde/C1/C1_pruefung.md.
- **07.10.2026, Schritt 3–4:** Dirk: G4 = zusätzlich; N1 wird im Code in C4 repariert; N6 so lassen; Doku laut Entwurf freigegeben. Umgesetzt: N2 (rules\README.md, architecture), N3 (README.md), N4 (consumer\README.md), N7 (architecture), G4-Satz als Listenpunkt (API_DE.md). API.md bleibt laut Vorgabe unberührt.
- **07.10.2026, Schritt 5:** Mit Dirks Freigabe committet und gepusht: `df6fe2d` auf `claude` (nur die fünf Doku-Dateien). Pull Request durch Dirk.
