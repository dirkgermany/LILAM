# B4: Jeder Log überschreibt den letzten Vorgänger

- **Projekt:** REGELN_FEHLER (Kontext: `../PROJEKT_KONTEXT.md`)
- **Quelle:** Analyse `FEATURES\REGELN\results\2026-10-04_regeln_analyse.md`, Kurzfassung B4, Abschnitt 7 Punkt 4
- **Schwere:** mittel (Fehlalarm)
- **Status:** **erledigt** 07.10.2026 (behoben in fe863f1; von Dirk geschlossen; Rest „letztes Signal“ in C4)

## Befund (laut Analyse vom 04.10.2026)

Jeder Log-Aufruf überschreibt den „letzten Vorgänger“ (`LOGGING|<Level>`). `PRECEDED_BY` sieht nur das letzte Signal des Prozesses, über alle Actions hinweg, einschließlich `TRACE_STOP` der eigenen Action und Logs. Das ist sehr streng und nirgends beschrieben.

## Belegt durch

Probe R06.

## Wirkung

Fehlalarm bei `PRECEDED_BY`, sobald zwischen Vorgänger und Signal ein Log liegt.

## Ansatz laut Analyse (zu prüfen, Dirk entscheidet)

Abhängig von Grundsatzfrage 3 (`../G_Grundsatzfragen`): Logs als Vorgänger ausschließen (bewusst, in der Doku beschreiben) oder Vorgänger je Action führen. Hinweis aus `CLAUDE_ANWEISUNGEN.md`: `PRECEDED_BY` zählt Logs bewusst nicht als Vorgänger (Reaktion auf bestimmte Logs wäre ein eigener Operator).

## Schritte

- [x] 1. Befund gegen aktuellen Code prüfen; Ergebnis unten protokollieren
- [x] 2. Vorschlag Dirk vorlegen (nach Grundsatzfrage 3)
- [x] 3. Freigabe durch Dirk: geschlossen 07.10.2026
- [x] 4. Umsetzung im Klon (entfällt, behoben in fe863f1; Test VG-01 vorhanden)
- [x] 5. Doku angleichen (entfällt, Doku entspricht dem Code)
- [x] 6. Bericht entfällt (Lauf 1569); Eintrag committet, Pull Request durch Dirk

## Protokoll

_(Datum, Schritt, Ergebnis; neueste zuletzt.)_

**06.10.2026, Schritt 1 (geprüft, zusammen mit B3): behoben in fe863f1, gemäß Grundsatzfrage 3 (nur Events und Traces).**
- `evaluateRules(p_monitorRec …)` (`lilam.pkb` ~1464): Der Vorgänger wird nach der Regelprüfung nur gesetzt, wenn `p_trigger != C_LOGGING`. Logs überschreiben ihn also nicht mehr. MARK_EVENT, TRACE_START und TRACE_STOP setzen ihn; LOGGING setzt ihn nicht; die Prozess-Trigger laufen über die andere Überladung und ändern ihn ebenfalls nicht.
- Test `lt.t_regeln`, Lauf **1569** (06.10.2026, SERVER, PASSED): **VG-01** enthält `mark_event A; info; mark_event B` → 0 Alerts (zusammen mit „falscher Vorgänger“ → 1; erhalten 1). Mit dem alten Fehler wären es 2 gewesen.
- Doku: `rules/README.md` Fußnote 4 und `architecture and concepts.md` Z. 251 („nur Events und Traces, keine Logs“) entsprechen dem Code.
- Weiter offen, gehört aber zu **C4** („PRECEDED_BY sieht nur das letzte Signal“; Hinweis dort eingetragen): Der Vorgänger ist das letzte Event bzw. der letzte Trace des Prozesses über alle Actions. Eine `PRECEDED_BY`-Regel mit Trigger `TRACE_STOP` auf Action B sieht daher meist das eigene `TRACE_START` von B als Vorgänger und schlägt an. Das betrifft die Semantik, nicht die Log-Behandlung.

**Vorschlag an Dirk:** B4 als erledigt schließen; über „nur letztes Signal / TRACE_STOP sieht eigenes TRACE_START“ in C4 entscheiden.

**07.10.2026, Schritt 3:** Dirk schließt B4 als erledigt (behoben in fe863f1). Keine Codeänderung; der Rest (TRACE_STOP sieht eigenes TRACE_START) wurde in C4 behandelt (N1, Commit 42e6731).

**Nächster Schritt:** keiner.
