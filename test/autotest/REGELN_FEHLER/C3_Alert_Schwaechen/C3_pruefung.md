# C3: Prüfung gegen den aktuellen Code und Vorschlag

**Stand:** 06.10.2026, Klon auf Branch `claude` (`.git\HEAD` geprüft), `lilam.pkb` vom 06.10.2026.
Geprüft wurde der Code selbst. `git show fe863f1` konnte ich nicht ausführen, weil ich nur Dateien lesen kann. Es wurden keine Tests ausgeführt.

## 1. Ergebnis je Punkt der Analyse

| Nr | Punkt | Ergebnis | Beleg |
|---|---|---|---|
| 1 | Handler fehlt/zu lang → ORA-06519, Alert verloren | **erledigt** | Prüfung beim Laden (`lilam.pkb` Z. 6055 f.); `persist_alert` (Z. 1153–1208) mit `ROLLBACK` im Handler; Fehler je Regel abgefangen (Z. 1380–1383) |
| 2 | fehlende `id` → `RULE_ID NOT NULL` | **erledigt** | Prüfung beim Laden: Pflicht, max. 50, eindeutig (Z. 6036–6043) |
| 3 | `to_number` ohne Formatmaske | **erledigt** | Werte werden beim Laden in `cond_num` NLS-unabhängig gewandelt (`ruleNumber`, Z. 5956–5968); die Auswertung nutzt nur noch `cond_num` |
| 4 | Log zu unbekannter `process_id` | **erledigt** | LOGGING-Regeln nur für bekannte Prozesse (Z. 4365 f.); `evaluateRules_internal` kehrt ohne Session sofort zurück |
| 5 | `g_alert_history` wächst ohne Scope | **offen** | Schlüssel `GRUPPE\|P<process_id>\|…` (Z. 1229–1231); gelöscht nur in `removeGroupRules` (Z. 6208–6214) und `clearServerData` (Z. 4760), **nicht** in `clearAllSessionData` (Z. 4820–4893) |
| 6 | Consumer kompiliert nicht, liest `throttle` | **erledigt** | Keine Referenz auf `C_LILAM_ALERTS` mehr; liest `$.alert.throttle_seconds`. Neue Fehler siehe N3 |
| 7 | Mailer: `MAIL_LOG` vs. `LILAM_ALERT_MAIL_LOG` | **offen** | Wartet auf `LILAM_ALERT_MAIL_LOG` (`LILAM_MAILER.pks`), sucht aber `handler_type = 'MAIL_LOG'` (`LILAM_MAILER.pkb`, `runMailer`). Da `fire_alert` Kanal **und** `handler_type` aus demselben Handler setzt, findet der Mailer mit keinem der beiden Namen je einen Alert |

## 2. Neue Befunde bei der Prüfung

- **N1 Mailer bricht nach der ersten Mail ab (belegt aus dem Code):** `runMailer` macht `COMMIT` innerhalb einer Cursor-Schleife mit `FOR UPDATE SKIP LOCKED`. Der nächste Fetch scheitert mit ORA-01002. Der Fehler entsteht außerhalb des inneren `BEGIN … EXCEPTION`, also beendet er `runMailer` ganz, sobald mehr als ein Alert ansteht.
- **N2 Mailer: fehlerhafte Alerts bleiben ewig `PENDING`:** Der Fehlerzweig macht nur `ROLLBACK`. Das steht so auch im Kommentar. Jeder weitere Signal-Eingang versucht dieselbe Mail erneut. Außerdem verarbeitet der Mailer anstehende Alerts nur nach einem Signal und nicht nach dem Timeout. Damit widerspricht er der „Recovery on Restart“-Zusage in `consumer\README.md`.
- **N3 Consumer: Spaltennamen falsch, scheitert zur Laufzeit:** `readProcessData` liest `master.proc_steps_todo` und `master.proc_steps_done`, die Prozesstabelle hat aber `steps_todo` und `steps_done` (`lilam.pkb` Z. 1913 f.). Das ergibt ORA-00904. Weil das SQL dynamisch ist, fällt der Fehler erst zur Laufzeit auf. Außerdem fehlt im Join der Kontext: Gibt es dieselbe Action mit gleichem `action_count` in mehreren Kontexten, droht TOO_MANY_ROWS (Vermutung, nicht gemessen).
- **N4 Feldlängen:**
  - `LILAM_ALERTS.PROCESS_NAME` ist `VARCHAR2(50)`, der Prozessname in der Prozesstabelle aber bis 100 Zeichen lang. Bei längeren Namen scheitert der Insert, und der Alert geht verloren. Der Fehler wird in `LILAM_LOG_INTERNAL` protokolliert.
  - Im Consumer sind die Typen zu eng: `t_alert_rec.action_name` und `context_name` (50), `t_lilam_rec.actionName` und `contextName` (50), `t_json_rec.action` (50) und `condition_value` (50, bei Regeln bis 250). Die Folge ist ORA-06502 im Mailer.
- **N5 `consumer\README.md` stimmt nicht:**
  - `LILAM_CONSUMER.C_ALERT_MAIL_LOG` gibt es nicht; die Konstante liegt in `LILAM_MAILER`.
  - Die Spalte heißt `ALERT_ID`, nicht `LILAM_ALERTS.ID`.
  - In der Payload fehlen `tab_name_logging` und `group_name`, in der Tabelle `LOGGING_TABLE_NAME` und `GROUP_NAME`.
  - `ERROR_MESSAGE` ist ein CLOB.
- **N6 (Hinweis, keine Änderung vorgeschlagen):** Im Mailer sind die Absender- und Empfängeradresse sowie `localhost:25` fest eingetragen. Für ein Beispiel ist das in Ordnung, als Konstanten im Spec wäre es übersichtlicher.

## 3. Vorschlag (Dirk entscheidet)

**V1 Handlername (Punkt 7) – entschieden 06.10.2026 von Dirk: `LILAM_ALERT_MAIL_LOG`.** Ein Name für alles, und zwar **`LILAM_ALERT_MAIL_LOG`**. Das ist die vorhandene Konstante `LILAM_MAILER.C_ALERT_MAIL_LOG`, und so steht es schon in `rules\README.md` und `architecture and concepts.md`. Der Präfix verhindert Kollisionen mit fremden `DBMS_ALERT`-Namen. Die Abfrage im Mailer verwendet dann die Konstante statt `'MAIL_LOG'`.
*Alternative:* überall `MAIL_LOG`. Das ist kürzer und passt zum Metro-Beispiel, aber der Name ist ohne Präfix kollisionsanfälliger und widerspricht der Doku.
*Folge für B8:* Das Metro-Beispiel nutzt `MAIL_LOG`, bleibt laut Regel 11 aber vorerst unverändert. Dazu kommt ein Hinweis ins Protokoll von B8.

**V2 Mailer robust (N1, N2):**
- Zuerst die IDs anstehender Alerts mit `BULK COLLECT` lesen.
- Dann jeden Alert einzeln mit `SELECT … FOR UPDATE SKIP LOCKED` sperren, verarbeiten und committen. Damit entfällt ORA-01002.
- Bei einem Fehler: `ROLLBACK`, dann Status `ERROR` mit Meldung setzen (die Logik aus `LILAM_CONSUMER.updateAlert` als eigene Prozedur `markError`) und committen.
- Anstehende Alerts auch nach dem Timeout und beim Start verarbeiten.

*Alternative:* Alerts per `UPDATE … SET status = 'PROCESSING' WHERE status = 'PENDING' AND alert_id = :id` beanspruchen. Das kommt ohne `FOR UPDATE` aus, braucht aber einen neuen Status.

**V3 Consumer (N3, N4):**
- In `readProcessData` die Spaltennamen korrigieren und den Kontext in den Join aufnehmen (NULL-sicher).
- Die Typen auf die Tabellenlängen bringen: Action und Kontext 100, `condition_value` 250.

**V4 `LILAM_ALERTS.PROCESS_NAME` auf 100 (N4):** im `CREATE TABLE` und als `ALTER TABLE … MODIFY` für bestehende Installationen, nach demselben Muster wie bei `GROUP_NAME` (`lilam.pkb` Z. 2015–2019). Diese Änderung betrifft `lilam.pkb`.
*Alternative:* `substr(…, 1, 50)` beim Insert. Das ist billiger, schneidet Namen aber ab.

**V5 `g_alert_history` (Punkt 5):** eine eigene Map für Alerts ohne Scope, `g_alert_history_proc`, nach `process_id`: `TABLE OF t_alert_history INDEX BY PLS_INTEGER`.
- In `clearAllSessionData` genügt dann ein `DELETE(p_processId)`, also O(1).
- `removeGroupRules` löscht die Einträge der Prozesse dieser Gruppe.
- Einträge mit Scope bleiben in `g_alert_history`. Ihre Zahl ist durch die Zahl der Scopes begrenzt.

*Alternative A:* In `clearAllSessionData` die ganze `g_alert_history` nach `|P<id>|` durchsuchen. Das ist einfach, aber O(n) bei jedem Prozessende.
*Alternative B:* Den Schlüssel umbauen, sodass die Prozess-ID vorne steht, und nach Bereichen löschen. Dann passt aber das Löschen per Gruppenpräfix in `removeGroupRules` nicht mehr.

Diese Änderung betrifft `lilam.pkb` (`STABILITÄT:`-Kommentar).

**V6 `consumer\README.md` korrigieren (N5).**

**Tests:** Consumer und Mailer sind in LILAM_TEST nicht installiert. Eine Testergänzung schlage ich erst vor, wenn Dirk das möchte. Für den Mailer müsste man ohne SMTP den Versand durch einen Stub ersetzen.

**Reihenfolge:** V1 bis V3 und V6 betreffen nur `consumer\`. Sie lassen sich ohne `lilam.pkb`-Sperre umsetzen und einzeln committen. V4 und V5 brauchen die Freigabe des Koordinators für `lilam.pkb`.
