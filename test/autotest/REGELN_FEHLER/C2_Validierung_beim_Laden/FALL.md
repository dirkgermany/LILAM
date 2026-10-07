# C2: Keine inhaltliche Validierung beim Laden

- **Projekt:** REGELN_FEHLER (Kontext: `../PROJEKT_KONTEXT.md`)
- **Quelle:** Analyse `FEATURES\REGELN\results\2026-10-04_regeln_analyse.md`, Abschnitte 1, 4 und 7 Punkt 2
- **Schwere:** mittel
- **Status:** umgesetzt 06.10.2026 (Teil 1 de1c724, Teil 2 bf2ae37 auf `claude`; Tests am Projektende)

## Befund (laut Analyse vom 04.10.2026)

In der Datenbank prüft nur `CHECK (rule_set IS JSON)`. Es gibt keine Prüfung von Trigger, Operator, Wertformat, Pflichtfeldern (`id`, `handler`) und Feldlängen (Handler ≤ 30 Zeichen). Unbekannte Trigger schlagen still nie an, unbekannte Operatoren erzeugen B1 zur Laufzeit, falsch geschriebene Schlüssel (`throttle`) werden still zu NULL. Keine Rückmeldung an den Aufrufer. `LILAM_RULES` hat weder Primärschlüssel noch Unique-Index (Doku: `SET_NAME` ist PK); doppelte Versionen führen zu TOO_MANY_ROWS.

## Belegt durch

Code, Probe D.

## Wirkung

Fehler zeigen sich erst zur Laufzeit oder gar nicht.

## Ansatz laut Analyse (zu prüfen, Dirk entscheidet)

Validierung beim Laden (zusammen mit B5, atomar), Unique-Index auf `SET_NAME, VERSION`, klare Fehlermeldung; die Strenge (ganzes Rule Set oder einzelne Regeln ablehnen) legt Dirk fest (Grundsatzfrage 6).

## Schritte

- [x] 1. Aktuellen Stand prüfen (SERVER- und Gruppenpfad); Ergebnis unten protokollieren
- [x] 2. Vorschlag Dirk vorlegen
- [x] 3. Freigabe durch Dirk
- [x] 4. Umsetzung im Klon (Branch `claude`) inkl. Install-Skript für den Index; Test erweitern; testen nur auf Dirks Anweisung
- [x] 5. Doku angleichen
- [ ] 6. Bericht, Commit nach Freigabe, Pull Request durch Dirk

## Protokoll

_(Datum, Schritt, Ergebnis; neueste zuletzt.)_

**06.10.2026 (Hinweis aus B3):** `PRECEDED_BY*`-Werte mit leeren Teilen werden beim Laden nicht abgelehnt, sondern umgedeutet: `|C1` → Aktion `C1`, beliebiger Kontext; `A|` → Aktion `A`, beliebiger Kontext (`regexp_substr(…, '[^|]+')` überspringt leere Teile; `lilam.pkb` ~6112). Vorschlag: leere Teile als Fehler melden.

**06.10.2026 (Hinweis aus B5):** `parseRuleSet` liest alle Felder als `VARCHAR2(4000)` mit Standard `NULL ON ERROR`. Ein optionales Feld (z. B. `context`, `metric`, `alert.severity`) mit mehr als 4000 Zeichen wird still NULL statt abgelehnt (Pflichtfelder fallen dann als „missing“ auf). Gering; ggf. `ERROR ON ERROR` oder Längenprüfung über `JSON_VALUE … RETURNING CLOB`.

**06.10.2026, Schritt 1 (Prüfung gegen Branch `claude`):** Großteils **behoben in fe863f1**: `parseRuleSet` prüft Pflichtfelder, Längen, eindeutige `id`, Trigger, Operator, Operator passend zum Trigger und Werteformat; `SERVER_UPDATE_RULES` wirft -20130 mit Grund (nur der erste Fehler); ganzes Rule Set wird abgelehnt. In der DB (`LILAM_TEST`) bestehen `IDX_LILAM_RULES_GRP (group_name, set_name, version)` und `IDX_LILAM_RULES_ACTIVE`; kein PK, kein NOT NULL, kein Check auf `is_active`. Offen waren: leere Teile in `|`-Werten werden umgedeutet (`|C1` ⇒ Aktion C1, `A|` ⇒ beliebiger Kontext, `20||0.3` ⇒ Warmup 0.3, `|5` ⇒ 5); optionale Felder mit falschem Typ oder > 4000 Zeichen still NULL (`context` ⇒ Regel gilt für alle Kontexte); unbekannte Schlüssel ignoriert; `ruleNumber` mit `VARCHAR2(100)` ⇒ ORA-06502 statt klarer Meldung; Unique-Index unterscheidet Groß-/Kleinschreibung der Gruppe, alle Zugriffe nicht. Details: Projektordner `befunde/C2/C2_Pruefung_und_Vorschlag.md`.

**06.10.2026, Schritt 2/3:** Vorschlag V1–V6 vorgelegt; Dirk: „Setze Deine Arbeit fort, wie von Dir empfohlen“. Widerspruch zu G6 = A (keine Verschärfung bei unbekannten Schlüsseln und Feldern > 4000): V2 (Typ/Länge), V3 (unbekannte Schlüssel) und V6 (`CHECK_RULE_SET`) zurückgestellt, Rückfrage an Dirk offen.

**06.10.2026, Schritt 4/5, Teil 1 umgesetzt (Klon, Branch `claude`, auf ec71648; nicht committet, nicht kompiliert, nicht getestet):**
- `lilam.pkb`: `parseRuleSet` lehnt leere oder leere-Leerzeichen-Teile in `PRECEDED_BY*`, `AVG_DEVIATION_PCT` und den Zahl-Operatoren ab; Zahl-Operatoren (außer `AVG_DEVIATION_PCT`, max. 3 Teile) dürfen kein `|` enthalten. `ruleNumber`: `l_val VARCHAR2(4000)`. Neue Tabelle `LILAM_RULES`: `group_name`, `set_name`, `version` NOT NULL, `version` ganzzahlig, `is_active` NOT NULL in (0, 1); bestehende Tabellen bekommen dieselben Constraints mit `ENABLE NOVALIDATE` (einmalig, erkannt an `LILAM_RULES_CHK_ACTIVE`). Unique-Index neu `idx_lilam_rules_set (upper(group_name), set_name, version)`; der alte `idx_lilam_rules_grp` wird erst gelöscht, wenn der neue existiert. Hilfsprozedur `run_ddl` (Parallelstart mehrerer Server).
- Test (`_COMMON\01_install_testbasis.sql`): Versionen 7 (`|C1`), 8 (`20||0.3`), 10 (`|5`) ungültig, L3 erwartet jetzt 8 Ablehnungen; neu L3d (Gruppe `lt` neben `LT` ⇒ `DUP_VAL_ON_INDEX`). `FEATURES\REGELN\test_regeln.sql`: Kopfkommentar.
- Doku: `rules\README.md` (Validation, Tabelle), `architecture and concepts.md` (Validierung, Tabelle), `API_DE.md` (SERVER_UPDATE_RULES; CRLF erhalten).
- Kein zusätzlicher Primärschlüssel (Unique-Index erfüllt den Zweck).

**06.10.2026, Commit Teil 1:** de1c724 auf `claude` (Dirks Ja 23:03).

**06.10.2026, Grundsatzfrage 6:** Dirk entscheidet **C+** (statt A): unbekannte Schlüssel und Felder über 4000 ablehnen, `CHECK_RULE_SET` ergänzen.

**06.10.2026, Teil 2 umgesetzt, Commit bf2ae37 (nicht kompiliert, nicht getestet):**
- `lilam.pkb` `parseRuleSet`: Rule Set wird zusätzlich mit `JSON_OBJECT_T` gelesen; `rules` muss ein Array sein; je Regel nur die Schlüssel `id, trigger_type, action, context, condition, alert`, in `condition` nur `operator, value, metric`, in `alert` nur `handler, severity, throttle_seconds` (Schlüssel mit `_` erlaubt, Header ungeprüft); `condition`/`alert` müssen Objekte sein; ein Feld, das vorhanden ist, das `JSON_TABLE` aber als NULL liest (Objekt, Array, Text > 4000; `""` und `null` gelten als fehlend), wird abgelehnt.
- Neue öffentliche Funktion `CHECK_RULE_SET(p_ruleSet CLOB) RETURN VARCHAR2` (`lilam.pks`/`lilam.pkb`): gleiche Prüfung ohne Speichern/Aktivieren, NULL = gültig, wirft nie.
- Test: Versionen 11 (`contxt`), 12 (`context` als Objekt) in L3 (jetzt 10 Ablehnungen); neu L3e (`CHECK_RULE_SET`: gültig, unbekannter Schlüssel, kein JSON).
- Doku: `rules\README.md`, `architecture and concepts.md`, `API_DE.md` (neuer Abschnitt `CHECK_RULE_SET`, Übersichtstabelle).

**Nächster Schritt:** Keiner im Fall. Tests laufen gesammelt am Projektende (Dirk); danach Bericht in `FEATURES\REGELN\results\`, Pull Request durch Dirk.
