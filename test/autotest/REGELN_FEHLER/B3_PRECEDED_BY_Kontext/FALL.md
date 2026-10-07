# B3: PRECEDED_BY mit Kontext schlägt fälschlich an

- **Projekt:** REGELN_FEHLER (Kontext: `../PROJEKT_KONTEXT.md`)
- **Quelle:** Analyse `FEATURES\REGELN\results\2026-10-04_regeln_analyse.md`, Kurzfassung B3, Abschnitt 8 (Gruppe Vorgänger)
- **Schwere:** mittel (Fehlalarm)
- **Status:** geprüft 06.10.2026: behoben in fe863f1; Vorschlag: schließen

## Befund (laut Analyse vom 04.10.2026)

`PRECEDED_BY` mit Kontext des Vorgängers schlägt fälschlich an, weil `full_key` kein `|` enthält.

## Belegt durch

Probe R04.

## Wirkung

Fehlalarm bei richtigem Vorgänger mit Kontext.

## Ansatz laut Analyse (zu prüfen, Dirk entscheidet)

Vergleichsschlüssel mit Trennzeichen bilden wie beim gespeicherten Vorgänger. Testfälle: Kontext-genaue Vorgabe `A|C1` (0 Alerts bei A/C1, 1 bei A/C2). Zusammen mit B4 und der Vorgängerlogik (Grundsatzfrage 3) betrachten.

## Schritte

- [x] 1. Befund gegen aktuellen Code prüfen; Ergebnis unten protokollieren
- [x] 2. Vorschlag Dirk vorlegen
- [ ] 3. Freigabe durch Dirk
- [ ] 4. Umsetzung im Klon (Branch `claude`), Test erweitern; testen nur auf Dirks Anweisung
- [ ] 5. Doku angleichen
- [ ] 6. Bericht in `FEATURES\REGELN\results\`, Commit nach Freigabe, Pull Request durch Dirk

## Protokoll

_(Datum, Schritt, Ergebnis; neueste zuletzt.)_

**06.10.2026, Schritt 1 (geprüft, zusammen mit B4): behoben in fe863f1.**
- Laden (`lilam.pkb` ~6112): Der Wert `ACTION[|CONTEXT]` wird beim Laden in `cond_action` und `cond_context` zerlegt (`PRECEDED_BY_WITHIN_SECS`: der letzte Teil sind die Sekunden). Einen zusammengesetzten `full_key` gibt es nicht mehr.
- Auswertung (`predecessorMatches`, ~1260): Die Aktion muss gleich sein, der Kontext nur, wenn die Regel einen nennt (`cond_context IS NULL` = beliebiger Kontext). Der Vorgänger liegt getrennt als `action_name`/`context_name` je Prozess vor (`g_last_action_per_process`).
- Test `lt.t_regeln`, Lauf **1569** (06.10.2026, SERVER, PASSED): **VG-02** (`RG_A|C1`: A/C1 → 0, A/C2 → 1; erhalten 1) grün. Mit dem alten Fehler wären es 2 Alerts gewesen. VG-01 (Kontext des Vorgängers egal), VG-03 (WITHIN_SECS) und VG-04 (TRACE_START) ebenfalls grün; keine weiteren internen Fehler.
- Doku: `rules/README.md` (Tabelle, Fußnote 4) und `architecture and concepts.md` (Z. 245–251) beschreiben `ACTION[|CONTEXT]` und „ohne Kontext = beliebig“ wie der Code; `API_DE.md` verweist auf `rules/README.md`. Aus B3 ist an der Doku nichts zu ändern.
- Rest (gehört nicht zu B3; Hinweis an C2 eingetragen): Leere Teile werden still umgedeutet statt abgelehnt, z. B. `|C1` → Aktion `C1`, beliebiger Kontext; `A|` → Aktion `A`, beliebiger Kontext. Ursache: `regexp_substr(…, '[^|]+')` überspringt leere Teile.

**Vorschlag an Dirk:** B3 als erledigt schließen (wie B1/B2); keine Codeänderung nötig.

**Nächster Schritt:** Dirk entscheidet, ob B3 geschlossen wird.
