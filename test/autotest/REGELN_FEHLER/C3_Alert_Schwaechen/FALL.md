# C3: Schwächen beim Auslösen von Alerts und im Consumer

- **Projekt:** REGELN_FEHLER (Kontext: `../PROJEKT_KONTEXT.md`)
- **Quelle:** Analyse `FEATURES\REGELN\results\2026-10-04_regeln_analyse.md`, Abschnitt 6 (Schwächen)
- **Schwere:** mittel
- **Status:** Umsetzung (V2, V4 committet 35ae13d; V3, V6 umgesetzt, nicht committet; V5 wartet auf `lilam.pkb`-Sperre)

## Befund (laut Analyse vom 04.10.2026)

1. Fehlt der Handler oder ist er länger als 30 Zeichen, scheitert `DBMS_ALERT.SIGNAL` **nach** dem Insert; die Ausnahme verlässt die autonome Transaktion ohne Rollback (ORA-06519). Der Alert geht verloren, die restlichen Regeln werden übersprungen (aus dem Code abgeleitet, nicht gemessen).
2. Fehlende `id` verletzt `RULE_ID NOT NULL`, Folge wie oben.
3. `MAX_DURATION_MS`, `MAX_GAP_SECONDS`, `STATUS_EQUALS` u. a. wandeln den Wert ohne Formatmaske (`to_number`); `1.5` scheitert unter deutschen NLS-Einstellungen (Vermutung; `extractRuleValue` macht es richtig).
4. Ein Log zu einer unbekannten `process_id` läuft trotzdem durch die LOGGING-Regeln; schlägt eine an, scheitert `fire_alert` an `v_indexSession`.
5. `g_alert_history` wächst bei Prozessen ohne Scope (`#NONE`) mit jeder `process_id` und wird nur beim Neuladen der Regeln geleert.
6. Consumer: `LILAM_CONSUMER.pkb` verweist auf `LILAM.C_LILAM_ALERTS` (im Spec: `C_LILAM_ALERTS_TABLE`) und lässt sich so nicht kompilieren; er liest `$.alert.throttle`. Consumer und Mailer sind in LILAM_TEST nicht installiert; das Signal wurde nicht empfangen und geprüft.
7. Mailer: `LILAM_MAILER` sucht Alerts mit `handler_type = 'MAIL_LOG'`, lauscht aber auf `LILAM_ALERT_MAIL_LOG`; Handler-Namen vereinheitlichen.

## Belegt durch

Code; nur Teile gemessen (siehe Analyse).

## Wirkung

Verlorene Alerts, übersprungene Regeln, nicht lauffähiger Consumer.

## Ansatz laut Analyse (zu prüfen, Dirk entscheidet)

Robustheit in `fire_alert` (Prüfung vor dem Insert bzw. Rollback), `extractRuleValue` überall nutzen, Konstantennamen und Handler-Namen vereinheitlichen; Consumer und Mailer in der Testumgebung installieren und mit einem Test prüfen. Punkte einzeln als Teilfälle behandeln, sobald Dirk sie freigibt.

## Schritte

- [x] 1. Jeden Punkt gegen den aktuellen Code prüfen (ggf. Messung mit Diagnoseskript); Ergebnis unten protokollieren
- [x] 2. Vorschlag Dirk vorlegen
- [ ] 3. Freigabe durch Dirk
- [ ] 4. Umsetzung im Klon (Branch `claude`), Test erweitern; testen nur auf Dirks Anweisung
- [ ] 5. Doku angleichen
- [ ] 6. Bericht, Commit nach Freigabe, Pull Request durch Dirk

## Protokoll

_(Datum, Schritt, Ergebnis; neueste zuletzt.)_

- **06.10.2026, Schritt 1:** Gegen den aktuellen Code (Branch `claude`) geprüft. Punkte 1–4 und 6 (Kompilierfehler, `throttle_seconds`) erledigt; Punkt 5 (`g_alert_history` ohne Scope wird in `clearAllSessionData` nicht gelöscht) und Punkt 7 (Mailer lauscht auf `LILAM_ALERT_MAIL_LOG`, sucht `handler_type = 'MAIL_LOG'`) offen. Neu: N1 Mailer `COMMIT` in `FOR UPDATE`-Schleife → ORA-01002 ab der 2. Mail; N2 fehlerhafte Alerts bleiben `PENDING`, keine Verarbeitung nach Timeout/Start; N3 Consumer `readProcessData` liest `proc_steps_todo/_done` statt `steps_todo/_done` (ORA-00904), Join ohne Kontext; N4 `LILAM_ALERTS.PROCESS_NAME` VARCHAR2(50) < Prozessname 100, Consumer-Typen zu eng; N5 `consumer\README.md` falsch (Konstante, `ALERT_ID`, fehlende Felder). Details und Vorschlag V1–V6: `C3_pruefung.md` in diesem Ordner.
- **06.10.2026, Schritt 2/3 (teilweise):** Dirk entscheidet V1: Handler einheitlich `LILAM_ALERT_MAIL_LOG`. Nächster Schritt: Freigabe von V2–V6 durch Dirk (V4 und V5 ändern `lilam.pkb`, vorher Freigabe des Koordinators).
- **06.10.2026 (Hinweis aus C4):** `LILAM_CONSUMER.get_ms_diff` nutzt `interval day(0) to second(3)` (ORA-01873 ab einem Tag; im Package auf `day(9)` korrigiert). Im Consumer wird die Funktion derzeit nicht aufgerufen.
- **06.10.2026, Schritt 3/4:** Dirk gibt V2 (Mailer robust) und V4 (`LILAM_ALERTS.PROCESS_NAME` auf 100) frei. V2 umgesetzt in `consumer\lilam_mailer\LILAM_MAILER.pkb` (neu `markError`, `processPending`: IDs per BULK COLLECT, Einzelsperre `FOR UPDATE SKIP LOCKED`, Fehler → Status ERROR; Suche über `C_ALERT_MAIL_LOG` statt `'MAIL_LOG'` (V1); Verarbeitung auch beim Start und nach Timeout). Nicht kompiliert, nicht getestet, noch nicht committet. V4 wartet auf die `lilam.pkb`-Sperre.
- **06.10.2026, Schritt 4:** V4 umgesetzt in `lilam.pkb` (CREATE TABLE `PROCESS_NAME` VARCHAR2(100), bestehende Tabellen per `ALTER TABLE … MODIFY`). Nicht kompiliert, nicht getestet.
- **07.10.2026, Schritt 6 (teilweise):** V2 und V4 committet (35ae13d) und nach origin/claude gepusht. Offen: V3, V5, V6; Kompilieren/Test nur auf Dirks Anweisung.
- **07.10.2026, Schritt 4:** Dirk gibt V3, V5 und V6 frei. V3 (Consumer: Spalten `steps_todo/_done`, Kontext im Join, neuer Parameter `p_context`, Typen auf 100/250; Mailer übergibt den Kontext) und V6 (`consumer\README.md`) umgesetzt. Die Zeile `HANDLER_TYPE` im README hatte schon die neue Bedeutung (C1) und blieb unverändert. Nicht kompiliert, nicht getestet, nicht committet. V5 wartet auf die `lilam.pkb`-Sperre.
