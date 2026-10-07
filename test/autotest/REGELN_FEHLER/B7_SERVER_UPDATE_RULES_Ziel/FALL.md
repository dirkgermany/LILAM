# B7: SERVER_UPDATE_RULES erreicht nur einen Server

- **Projekt:** REGELN_FEHLER (Kontext: `../PROJEKT_KONTEXT.md`)
- **Quelle:** Analyse `FEATURES\REGELN\results\2026-10-04_regeln_analyse.md`, Kurzfassung B7, Abschnitt 1
- **Schwere:** hoch
- **Status:** umgesetzt, gepusht ec71648 07.10.2026 (nicht getestet)

## Befund (laut Analyse vom 04.10.2026)

`SERVER_UPDATE_RULES(p_processId, ...)` sendet über `sendNoWait` an den Server, den die aufrufende Session für diese `process_id` kennt. Ruft ein Administrator die Prozedur aus einer anderen Session auf (Beispiel in `rules\README.md`), wählt `getServerPipeForSession` irgendeinen freien Server. Mit Dispatcher geht die Nachricht an den Dispatcher; dort fehlt `process_id` in der Payload, die Nachricht wird ohne Rückmeldung verworfen. Es gibt keinen Weg, alle Server (oder einen per Pipe-Namen) zu aktualisieren, und keinen Weg ohne laufenden Prozess. Im Mehrserver-Betrieb hat jeder Server sein eigenes Rule Set.

## Belegt durch

Code; Test-Idee L6 (Update aus fremder Session und über Dispatcher).

## Wirkung

Regeln uneinheitlich bzw. stillschweigend nicht geladen.

## Ansatz laut Analyse (zu prüfen, Dirk entscheidet)

Abhängig von Grundsatzfrage 2 (`../G_Grundsatzfragen`, global oder je Server): Update je Pipe-Name oder an alle Server der Gruppe, Rückmeldung an den Aufrufer. Beachten: API-Umfang entscheidet Dirk.

## Schritte

- [x] 1. Befund gegen aktuellen Code prüfen; Ergebnis unten protokollieren
- [x] 2. Vorschlag Dirk vorlegen (nach Grundsatzfrage 2) (07.10.2026, Vorschlag A/B/C)
- [x] 3. Freigabe durch Dirk (07.10.2026, Variante A)
- [x] 4. Umsetzung im Klon (Branch `claude`), Test erweitern (Laden L6); testen nur auf Dirks Anweisung (07.10.2026)
- [x] 5. Doku angleichen (07.10.2026)
- [ ] 6. Bericht in `FEATURES\REGELN\results\`, Commit nach Freigabe, Pull Request durch Dirk

## Protokoll

_(Datum, Schritt, Ergebnis; neueste zuletzt.)_

- 06.10.2026: Hinweis nachgetragen: Nach dem Analysestand d2bf421 wurde `SERVER_UPDATE_RULES` umgebaut, jetzt `SERVER_UPDATE_RULES(p_groupName, p_ruleSetName, p_ruleSetVersion)` (`lilam.pks`, Zeile 213; Commit de1c57e), Rule Sets je Gruppe in `LILAM_RULES` (fe4c21e). Zu prüfen: Erreicht das Update alle Server der Gruppe, auch über Dispatcher, mit Rückmeldung an den Aufrufer?
- 07.10.2026: Schritt 1 geprüft (Branch claude). Befund behoben: SERVER_UPDATE_RULES(gruppe, name, version) prüft das Rule Set (Fehler: Exception -20130, nichts ändert sich), aktiviert es autonom und schickt UPDATE_RULE aus jeder Session ohne process_id direkt in die Daten-Pipes aller aktiven Nicht-Dispatcher der Gruppe aus LILAM_SERVER_REGISTRY, also am Dispatcher vorbei (lilam.pkb 6365–6409). Dispatcher und Worker teilen die Gruppe; Server laden bei UPDATE_RULE und beim Start das aktive Rule Set (6328, 6634, START_SERVER 6716–6723, kein Startfenster). INSESSION prüft alle 15 s selbst. Doku (API_DE 883 ff., architecture 188/194/411/592, rules\README 99/156/162) stimmt.
  Restpunkte: (1) Scheitert SEND_MESSAGE (Pipe voll, 1 s), wird nur in LILAM_LOG_INTERNAL protokolliert; Server prüfen nicht selbst nach (15-s-Prüfung nur bei g_serverPipeName IS NULL) und bleiben bis zum Neustart auf dem alten Rule Set. (2) Keine Rückmeldung, welche Server geladen haben. (3) Kein Heartbeat-Filter (tote Registry-Einträge, harmlos, ggf. 1 s Wartezeit). (4) Test L6 fehlt; L1/L4 prüfen nicht deterministisch jeden Server, kein Dispatcher-Lauf.
  Vorschlag: A (empfohlen) Server rufen im Housekeeping höchstens alle C_RULES_CHECK_INTERVAL_MS refreshGroupRules(gruppe, FALSE) auf; UPDATE_RULE bleibt sofortiger Anstoß; keine API-Änderung. B Server tragen geladenes Rule Set in die Registry ein (Rückmeldung; berührt C4 g). C Heartbeat-Filter (mit A unnötig). Nicht empfohlen: Exception/Rückgabewert bei unerreichbarer Pipe. L6 (nur einbauen): DISPATCHER-Modus, Update aus der Testsession, Prozesse über LT_DISP; mit B je Worker Version prüfen, mit A Fall ohne UPDATE_RULE-Nachricht (≤ 16 s).
  Nächster Schritt: Dirk entscheidet A/B/C; Umsetzung in lilam.pkb und Doku erst nach Freigabe und Abstimmung mit parallelen Threads.
- 07.10.2026: Schritt 3: Dirk entscheidet A: Server prüfen wie INSESSION alle 15 s selbst nach; behebt Restpunkt (1), keine API-Änderung. B und C entfallen vorerst. Nächster Schritt: Umsetzung in lilam.pkb (Branch claude) nach Abstimmung mit parallelen Threads, Test L6 einbauen (testen nur auf Dirks Anweisung).
- 07.10.2026: Schritte 4 und 5 umgesetzt im Klon (Branch claude, Basis b91a9aa; nicht committet, nicht getestet). lilam.pkb: neue Prozedur checkServerRules (nach loadServerRules; Dispatcher und Server ohne Gruppe ausgenommen; höchstens alle C_RULES_CHECK_INTERVAL_MS refreshGroupRules(gruppe, p_force => FALSE)), Aufruf im Housekeeping von START_SERVER nach SYNC_ALL_DIRTY; Kommentare angepasst (C_RULES_CHECK_INTERVAL_MS, last_check_cs, INSESSION-Prüfung, refreshGroupRules, SERVER_UPDATE_RULES). Doku: API_DE.md Ablauf Punkt 3 von SERVER_UPDATE_RULES (Server prüfen alle 15 s selbst, verpasste Anweisung spätestens nach etwa 20 s nachgeholt), architecture and concepts.md Z. 194. Test: L6 in 01_install_testbasis.sql (t_regeln nach L4: Version 1 nur in der Tabelle aktivieren, 21 s warten, 4 Prozesse, 4 Alerts L-01 erwartet; Laufzeit +21 s); Testbeschreibungen in test_regeln.sql (Kopfkommentar) und test\autotest\README.md (L6, ca. 2,5 min).
  Nächster Schritt: Commit/Push nach Dirks Freigabe, Tests am Ende durch Dirk.
- 07.10.2026: Schritt 6 teilweise: Commit ec71648 auf claude gepusht (Freigabe Dirk; mit b91a9aa, origin/claude = HEAD). Offen: Testlauf durch Dirk, Bericht in `FEATURES\REGELN\results\`, Pull Request durch Dirk.
