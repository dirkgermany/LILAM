# B5: Laden eines Rule Sets ist nicht atomar

- **Projekt:** REGELN_FEHLER (Kontext: `../PROJEKT_KONTEXT.md`)
- **Quelle:** Analyse `FEATURES\REGELN\results\2026-10-04_regeln_analyse.md`, Kurzfassung B5, Abschnitt 1
- **Schwere:** hoch
- **Status:** erledigt 06.10.2026 (behoben in fe863f1, Lauf 1569; von Dirk geschlossen). Testergänzung Version 6 / L3c im Klon, noch nicht gelaufen

## Befund (laut Analyse vom 04.10.2026)

`load_rules_from_json` löscht zuerst alle Regeln und füllt sie dann. Eine fehlerhafte Regel (z. B. `"action": ""` wie im Beispiel SEQ-009 ⇒ Schlüssel NULL, ORA-06502) bricht ab; alles danach fehlt, der Header (Name/Version) wird nicht gesetzt. Die Registry wurde vorher schon auf die neue Version gesetzt (`updateRulesInRegistry` vor `readServerRules`). Dasselbe bei nicht existierender Version. Werte länger als die `JSON_TABLE`-Spalten (z. B. `action` > 50 Zeichen) werden durch `NULL ON ERROR` still zu NULL und lösen B5 aus.

## Belegt durch

Probe D.

## Wirkung

Server ohne Regeln, Registry zeigt die neue Version, nach einem Neustart wieder derselbe Fehler: alle Regeln weg.

## Ansatz laut Analyse (zu prüfen, Dirk entscheidet)

Erst in eine Hilfsstruktur laden und prüfen, dann austauschen; bei Fehler alte Regeln behalten und Registry unverändert lassen; Fehler melden. Zusammen mit C2 (Validierung) und Grundsatzfrage 6 (Strenge).

## Schritte

- [x] 1. Befund gegen aktuellen Code prüfen (SERVER-Pfad und Gruppenpfad); Ergebnis unten protokollieren
- [x] 2. Vorschlag Dirk vorlegen (06.10.2026: schließen; optional zwei Testergänzungen)
- [x] 3. Freigabe durch Dirk (06.10.2026: schließen; Testergänzungen Version 6 und L3c beauftragt)
- [ ] 4. Umsetzung im Klon (Branch `claude`), Test erweitern (Laden L4, L5); testen nur auf Dirks Anweisung
- [ ] 5. Doku angleichen
- [ ] 6. Bericht in `FEATURES\REGELN\results\`, Commit nach Freigabe, Pull Request durch Dirk

## Protokoll

_(Datum, Schritt, Ergebnis; neueste zuletzt.)_

**06.10.2026, Schritt 1 (Prüfung gegen aktuellen Code, Branch `claude`, Stand ff36542):** Befund **behoben in fe863f1**. Die alten Routinen `load_rules_from_json`, `updateRulesInRegistry`, `readServerRules` gibt es nicht mehr; SERVER- und Gruppenpfad laufen beide über `refreshGroupRules`.

| Punkt der Analyse | Heute (`lilam.pkb`) |
|---|---|
| Erst löschen, dann füllen | `parseRuleSet` (~5978) füllt nur lokale Maps (OUT-Parameter); erst bei Erfolg tauscht `installGroupRules` (~6220) die Regeln der Gruppe aus. Der Austausch arbeitet nur im Speicher (Schlüssel max. 50+1+201 < 300), kann also nicht mittendrin scheitern. |
| Fehlerhafte Regel bricht ab, Rest fehlt | Ganzes Rule Set wird abgelehnt (`refreshGroupRules` ~6307: Log `-20130`, `RETURN` vor `installGroupRules`); die bisherigen Regeln bleiben aktiv. |
| `"action": ""` (SEQ-009) | JSON-Leerstring ⇒ NULL ⇒ `"action" missing or longer than 100` ⇒ Ablehnung (~6047). |
| Werte länger als `JSON_TABLE`-Spalte ⇒ still NULL | Spalten jetzt `VARCHAR2(4000)`, Längen werden ausdrücklich geprüft (id 50, action/context 100, handler 30, severity 30, value 250, metric 50). Werte > 4000 werden NULL und dann als „missing“ abgelehnt (bei optionalen Feldern wie `context` still NULL – Restpunkt für C2, gering). |
| Registry vor dem Laden auf neue Version | Keine Registry-Spalte mehr; maßgeblich ist `LILAM_RULES.IS_ACTIVE`. `SERVER_UPDATE_RULES` (~6365) prüft das Rule Set **vor** `activateGroupRules`; ungültig ⇒ `RAISE_APPLICATION_ERROR(-20130)` an den Aufrufer, nichts wird aktiviert, kein Server benachrichtigt. |
| Nicht existierende Version | `NO_DATA_FOUND` ⇒ `-20130 … not found` (doppelt: `TOO_MANY_ROWS` ⇒ `-20130`). |
| Nach Neustart alle Regeln weg | Aktiv kann über die API nur ein gültiges Rule Set werden. Wird ein ungültiges per Hand aktiviert, lehnt der Server es beim Start ab (Log `-20130`) und hat dann keine Regeln (es gibt keine alten) – gewollt und protokolliert. |

**Testnachweis:** Lauf **1569** (06.10.2026 00:32, `lt.t_regeln`, PASSED): L3 (Versionen 3–5 ungültig und Version 9 fehlend ⇒ 4× `NUM_ERR_RULE_SET`, aktives Rule Set unverändert, Regeln aus v1 wirken weiter), L3a, L3b (Server lehnt ungültiges aktives Rule Set beim Start ab), L4 (Wechsel v1→v2 ersetzt alle Regeln), keine weiteren internen Fehler.

**Lücken im Test (klein):**
1. Der konkrete Fall `"action": ""` ist nicht dabei (Version 3 prüft fehlenden Handler; gleicher Codepfad, andere Bedingung).
2. Nicht geprüft im SERVER-Modus: Ein *laufender* Server erhält `UPDATE_RULE` für ein per Hand aktiviertes ungültiges Rule Set und **behält** seine bisherigen Regeln (Code: `RETURN` vor `installGroupRules`; im INSESSION-Pfad durch Lauf 721/722 belegt, siehe `2026-10-05_run721-722.md`).

**Schritt 2, Vorschlag an Dirk:** B5 schließen (behoben in fe863f1, Lauf 1569). Optional, nur auf Dirks Anweisung: im Test `put_rules` eine Version 6 mit `"action": ""` ergänzen (in L3 mitprüfen) und einen Fall L3c „laufender Server behält Regeln bei ungültigem aktivem Rule Set“. Der Rest (Werte > 4000 bei optionalen Feldern) gehört zu C2.

**06.10.2026, Schritt 3:** Dirk schließt B5 und beauftragt beide Testergänzungen.

**06.10.2026, Schritt 4 (Test erweitert, Klon Branch `claude`, nicht committet, nicht kompiliert, nicht gelaufen):**
- `test\autotest\_COMMON\01_install_testbasis.sql`, `lt.t_regeln`:
  - `put_rules`: Version 6 mit `"action":""` (X6-01, als JSON-Text, weil `r()` eine leere Action weglässt).
  - L3: zusätzlich `rejected(c_group, 6)`; die Prüfung erwartet jetzt **5** Ablehnungen.
  - **L3c** neu (vor L3b, beide Server haben v1): v6 von Hand aktivieren, `UPDATE_RULE` direkt in die Pipes der aktiven Server der Gruppe LT (wie `SERVER_UPDATE_RULES`). Prüfung 1: je Server ein interner Fehler `refreshGroupRules`/-20130 seit Beginn von L3c. Prüfung 2: zwei Prozesse mit `RG_L` ⇒ 2 Alerts L-01 (v1 bleibt aktiv). Danach v1 wieder aktiv.
  - L3b zählt die internen Fehler jetzt ab Beginn von L3b (`l_t`) statt ab Laufbeginn, sonst würden die Fehler aus L3c mitgezählt.
- `FEATURES\REGELN\test_regeln.sql`: Kopfkommentar (Versionen 1–6, L3c).

**Nächster Schritt:** Keiner im Fall. Die Tests laufen gesammelt am Ende des Projekts (Dirk, 07.10.2026); dann Bericht in `FEATURES\REGELN\results\` und Commit auf `claude` nach Freigabe.
