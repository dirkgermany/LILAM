# B6 – Regeln im INSESSION-Modus: Prüfung und Vorschlag (06.10.2026)

Geprüft im Klon `lilam\` (Branch `claude`), nur lesend. Keine Tests gelaufen.

## 1. Code: erledigt

| Punkt | Stelle (`lilam.pkb`) | Befund |
|---|---|---|
| Gruppe aus `NEW_SESSION` | ~4975–4986 | INSESSION: `group_name := trim(p_groupName)`, `rule_group := upper(...)`; Server: Servergruppe; Dispatcher: keine |
| Laden beim ersten Regelcheck | `evaluateRules_internal` ~1389–1406 | ohne Gruppe sofort `RETURN`; INSESSION prüft höchstens alle `C_RULES_CHECK_INTERVAL_MS` = 15000 (Z. 51) per `GET_TIME` |
| Neu laden nur bei neuem Namen/Version | `refreshGroupRules` ~6257–6322 | indexgestützte Abfrage, ungültiges Set einmal je Version protokolliert (-20130), alte Regeln bleiben; kein aktives Set ⇒ keine Regeln; Fehler erreichen den Aufrufer nie |
| Regeln je Gruppe getrennt | `installGroupRules` | Schlüssel `GROUP\|Action\|Context` |

Kein Fehler gefunden. Beobachtung (kein Handlungsbedarf): `g_rule_groups` einer INSESSION-Session wird nie geleert (eine Zeile je verwendeter Gruppe).

## 2. Doku: weitgehend erledigt, kleine Reste

- `docs\API_DE.md`: vollständig (`p_groupName` Z. 292, `SERVER_UPDATE_RULES` Punkt 4 Z. 898, Abschnitt „Regeln im INSESSION-Modus“ Z. 911–923).
- `docs\architecture and concepts.md`: Abschnitt „Rules in INSESSION Mode“ (Z. 190–196), Diagramm, `LILAM_RULES`-Spalten vorhanden. Rest: Tabellenübersicht Z. 479 „per server group“ → „per group (servers and INSESSION processes)“.
- `rules\README.md`: Hinweis Z. 54 vorhanden. Reste, die nur Server nennen:
  - Z. 136 „for a **server group**“ → „for a **group** (server group or `p_groupName` of `NEW_SESSION`)“
  - Z. 140 `GROUP_NAME` „Server group …“ → wie oben
  - Z. 143 `IS_ACTIVE` „the servers of the group use“ → „servers and INSESSION processes of the group use“
  - Z. 151 „LILAM servers load … at startup“ → Satz zu INSESSION ergänzen (erste Regelprüfung, dann höchstens alle 15 s)
  - Z. 156 `SERVER_UPDATE_RULES` → INSESSION-Prozesse übernehmen es spätestens beim ersten API-Aufruf nach 15 s
- Überschneidung mit C1 (gleiche Dateien): Reihenfolge über den Koordinator.

## 3. Tests: nicht abgedeckt

`lt.t_regeln` und `lt.t_regeln_last` laufen nur im SERVER-Modus. INSESSION bisher nur ad hoc (Bericht `2026-10-05_run721-722.md`).

### Vorschlag REGELN (`lt.t_regeln`)

- Szenarioblöcke VG/NF/MON/PR/LG/KX zusätzlich INSESSION: `proc()` erhält einen Modus; Prozesspräfix `l_p || '_IS'`. Erwartungswerte unverändert.
- **Eigene Gruppe je Lauf** (z. B. `LT_RG_IS_<run>`): Der Session-Cache prüft nur Name und Version; ein zweiter Lauf in derselben DB-Session sähe sonst die Regeln mit dem alten Prozesspräfix (`#P#`).
- Neue Prüfungen: IS-01 ohne Gruppe keine Alerts; IS-02 Gruppe klein geschrieben; IS-03 Versionswechsel sofort alt, nach 16 s neu; IS-04 ungültige Version von Hand aktiviert, alte Regeln bleiben, genau ein -20130; IS-05 kein aktives Set, nach 16 s keine Regeln.
- Laufzeit ca. +60 s (ohne IS-04/IS-05 ca. +35 s).

### Vorschlag REGELN_LAST (`lt.t_regeln_last`)

- Zweite Messreihe INSESSION mit denselben Signaltypen, Varianten und Grenzwerten; je Messung eigene Gruppe (sonst 16 s Wartezeit je Variante). Metriken mit Präfix `is_`.
- Kopfkommentare in `test_regeln.sql`, `test_regeln_last.sql` und `test\autotest\README.md` anpassen.

Tests laufen danach nicht (Dirk startet sie am Ende).

## 4. Grundsatzfrage 1

Empfehlung: **bestätigen, wie umgesetzt** (nur mit Gruppe, Prüfintervall 15 s fest, Alerts synchron). Alternativen: a) Intervall konfigurierbar (API-Erweiterung, nicht empfohlen); b) INSESSION-Regeln zurückbauen (nicht empfohlen).

## 5. Was Dirk entscheiden muss

1. Grundsatzfrage 1 bestätigen.
2. REGELN: voll oder ohne IS-04/IS-05 (Empfehlung: voll).
3. REGELN_LAST mit INSESSION-Messreihe (Empfehlung: ja).
4. Doku-Reste freigeben.
