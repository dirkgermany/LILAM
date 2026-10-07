# B1: CASE ohne ELSE in evaluateRules_internal

- **Projekt:** REGELN_FEHLER (Kontext: `../PROJEKT_KONTEXT.md`)
- **Quelle:** Analyse `FEATURES\REGELN\results\2026-10-04_regeln_analyse.md`, Kurzfassung B1, Abschnitte 2 und 5
- **Schwere:** hoch
- **Status:** **erledigt** (06.10.2026, von Dirk geschlossen). Behoben in Commit fe863f1 (04.10.2026 20:51, nach der Analyse), durch Tests belegt.

## Befund (laut Analyse vom 04.10.2026)

`CASE` ohne `ELSE` in `evaluateRules_internal`: Jede nicht zutreffende `SEVERITY`-Regel und jeder unbekannte Operator wirft ORA-06592. Auch die eigenen INFO-Logs des Servers laufen durch die LOGGING-Regeln (Probe B: 4 interne Fehler ohne einen einzigen Client-Log). Auch der in der Doku genannte Operator `PRECEDED_BY_WITHIN_MS` löst B1 aus (Probe R10).

## Belegt durch

Probe A–D (`2026-10-04_regeln_probe.sql`), Leistung L_SEV (10.003 interne Fehler bei 10.000 INFO-Logs).

## Wirkung

Ein interner Fehler je Signal, der Rest der Regelliste wird übersprungen, der Server ist 3–6× langsamer (Insert in `LILAM_LOG_INTERNAL` je Log). Verstößt gegen den Grundsatz, dass LILAM die Anwendung nie stört.

## Ansatz laut Analyse (zu prüfen, Dirk entscheidet)

Eine Zeile `ELSE NULL` im `CASE`; Ausnahme je Regel abfangen (siehe B2). Unbekannte Operatoren ggf. schon beim Laden ablehnen (siehe C2). Gemeinsam mit B2 angehen.

## Schritte

- [ ] 1. Befund gegen aktuellen Code und Doku prüfen (ggf. mit Diagnoseskript aus `FEATURES\REGELN\`); Ergebnis unten protokollieren
- [ ] 2. Vorschlag mit Begründung und Alternativen Dirk vorlegen
- [ ] 3. Freigabe durch Dirk
- [ ] 4. Umsetzung im Klon (Branch `claude`), Test erweitern (`lt.t_regeln`); testen nur auf Dirks Anweisung
- [ ] 5. Doku angleichen (`API_DE.md` Master, `API.md`, `rules\README.md`, `architecture and concepts.md`)
- [ ] 6. Bericht in `FEATURES\REGELN\results\`, Commit auf `claude` nach Freigabe, Pull Request durch Dirk

## Protokoll

_(Datum, Schritt, Ergebnis; neueste zuletzt. Arbeitsdateien dieses Falls liegen in diesem Ordner.)_

- **06.10.2026, Schritt 1 (Prüfung gegen Branch `claude`, ff36542):** Befund ist behoben, und zwar schon in **fe863f1** („Regeln: Auswertung und Laden korrigiert …“, 04.10.2026 20:51), also nach dem Analysestand d2bf421. Der Commit behebt laut Meldung auch B2, B3/B4 (Vorgänger), B5 (Laden atomar) und Teile von C1–C3.
  - **Code** (`lilam.pkb`, `evaluateRules_internal`, ca. Zeile 1251–1423):
    - Das `CASE` hat `ELSE NULL` (Zeile 1364). Eine nicht zutreffende `SEVERITY`-Regel ergibt nur `fire := FALSE`, kein ORA-06592.
    - Jede Regel hat einen eigenen `BEGIN … EXCEPTION` in der Schleife (Zeile 1278–1383, Kommentar `STABILITY:`); ein Fehler in einer Regel bricht die folgenden nicht mehr ab (B2).
    - Unbekannte Operatoren und unpassende Trigger lehnt schon das Laden ab (`lilam.pkb` ca. Zeile 6078–6096: „unknown condition.operator“ bzw. „operator … not allowed for trigger …“). `SEVERITY` wird beim Laden auf ERROR/WARN/MONITOR/INFO/DEBUG geprüft und in Großbuchstaben abgelegt.
  - **Doku:** `PRECEDED_BY_WITHIN_MS` kommt in `docs\` und `rules\` nicht mehr vor (nur noch in der alten Probe `2026-10-04_regeln_probe.sql`). Doku: `rules\README.md` Zeile 115, `architecture and concepts.md` Zeile 249.
  - **Tests** (aus `LT_RUN`/`LT_CHECK`): REGELN in jedem Lauf seit 707 bestanden (zuletzt run 1569, 06.10.2026, 39/39); REGELN_LAST zuletzt run 1570, 18/18.
    - LG-01 „SEVERITY ERROR“ und LG-02 „SEVERITY WARN als zweite Log-Regel“: 10 INFO, 1 WARN, 1 ERROR → je genau 1 Alert. Das ist genau die Test-Idee aus B2.
    - „Keine weiteren internen LILAM-Fehler“: 0.
    - REGELN_LAST: LOG mit 20 passenden Regeln ohne Alarm 184,6 µs gegen 151,5 µs ohne Regeln (Grenze 2×); vorher 3–6× langsamer mit einem internen Fehler je Log.
  - **Ergebnis:** Kein Handlungsbedarf im Code. Vorschlag an Dirk: B1 (und B2) als erledigt schließen. Schritte 2–6 entfallen.
  - **Restbeobachtung (kein Fehler, nur zur Kenntnis):** Wirft eine Regel dauerhaft eine Ausnahme, protokolliert der Block je Signal einen internen Fehler. Laut Ladeprüfung ist das nur noch bei Laufzeitfehlern (z. B. Rechenfehler) denkbar; Teil von C3/C4, falls gewünscht.
