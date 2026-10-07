# B2: Folgeregeln werden übersprungen

- **Projekt:** REGELN_FEHLER (Kontext: `../PROJEKT_KONTEXT.md`)
- **Quelle:** Analyse `FEATURES\REGELN\results\2026-10-04_regeln_analyse.md`, Kurzfassung B2, Abschnitt 7 Punkt 1
- **Schwere:** hoch
- **Status:** **erledigt** (06.10.2026, von Dirk geschlossen). Behoben in Commit fe863f1 (04.10.2026), durch Test LG-01/LG-02 belegt. Details im Protokoll von B1.

## Befund (laut Analyse vom 04.10.2026)

Mit einer `SEVERITY=ERROR`-Regel greift eine zweite Regel (z. B. `WARN`) nie, wenn sie hinter der ersten steht. Ein einziger `EXCEPTION`-Block umschließt die ganze Regelliste; ein Fehler in einer Regel bricht alle folgenden ab.

## Belegt durch

Code (Folge von B1). Test-Idee: `SEVERITY=ERROR` und `SEVERITY=WARN` hintereinander; je 1 ERROR, 1 WARN, 10 INFO; erwartet ERROR 1, WARN 1, 0 interne Fehler.

## Wirkung

Alerts fehlen, ohne dass es jemand merkt.

## Ansatz laut Analyse (zu prüfen, Dirk entscheidet)

Fehler je Regel abfangen (eigener Block in der Schleife), zusammen mit B1 beheben.

## Schritte

- [ ] 1. Befund gegen aktuellen Code prüfen; Ergebnis unten protokollieren
- [ ] 2. Vorschlag Dirk vorlegen
- [ ] 3. Freigabe durch Dirk
- [ ] 4. Umsetzung im Klon (Branch `claude`), Test erweitern; testen nur auf Dirks Anweisung
- [ ] 5. Doku angleichen
- [ ] 6. Bericht in `FEATURES\REGELN\results\`, Commit nach Freigabe, Pull Request durch Dirk

## Protokoll

_(Datum, Schritt, Ergebnis; neueste zuletzt.)_

- **06.10.2026 (im Rahmen von B1 geprüft):** Behoben in fe863f1: In `evaluateRules_internal` hat jede Regel ihren eigenen `BEGIN … EXCEPTION`-Block (`lilam.pkb` ca. Zeile 1278–1383). Die Test-Idee oben ist als LG-01/LG-02 in `lt.t_regeln` umgesetzt (10 INFO, 1 WARN, 1 ERROR → je 1 Alert, 0 interne Fehler); zuletzt bestanden in run 1569 (06.10.2026). Vorschlag: zusammen mit B1 schließen.
