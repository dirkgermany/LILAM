# LILAM_GRAFANA – Beispiel-Consumer für Grafana

Reicht LILAM-Alerts als **Grafana-Annotationen** weiter. Gebaut für das U-Bahn-Beispiel aus
`docs/architecture and concepts.md` (Rule Set `SUBWAY_PROD`, Regel `R-001`, Kanal `LILAM_ALERT_MAIL_LOG`, Gruppe `SUBWAY`),
aber über Kanal und Gruppe für jedes Rule Set nutzbar.

## Ablauf

1. Der Consumer registriert sich mit `DBMS_ALERT` auf den Kanal (das `alert.handler` der Regel) und auf `LILAM_GRAFANA_STOP`.
2. Beim Start, nach jedem Signal und spätestens nach `p_waitSeconds` holt er alle `PENDING`-Alerts des Kanals **und der Gruppe**
   aus `LILAM_ALERTS` (wie `LILAM_MAILER`: IDs lesen, je Alert sperren mit `SKIP LOCKED`, je Alert ein Commit).
3. Je Alert baut er eine Annotation (`BUILD_ANNOTATION`) und schickt sie an `POST <url>/api/annotations`.
   Ohne URL verlässt nichts die Datenbank: Die Anfrage landet nur in `LILAM_GRAFANA_OUTBOX` (`SEND_STATUS = SIMULATED`), dem
   „imaginären Grafana-Dienst“.
4. Erfolg: Alert `PROCESSED`. Fehler (HTTP ≠ 2xx, Netz, ACL): Alert `ERROR` mit Meldung, Outbox-Zeile `FAILED`; der Consumer läuft weiter.

## Annotation

```json
{
  "dashboardUID": "<optional>",
  "time": 1791358800000,
  "timeEnd": 1791359101000,
  "tags": ["lilam", "group:SUBWAY", "rule_set:SUBWAY_PROD v5", "rule:R-001", "severity:CRITICAL",
           "action:STATION_EXIT", "context:Moulin Rouge"],
  "text": "LILAM R-001 (CRITICAL): STATION_EXIT Moulin Rouge, 301000 ms - Line 1 (process 4711, alert 12)"
}
```

`time`/`timeEnd` sind Start und Ende der Ausfahrt aus der Monitor-Tabelle (eine Region im Dashboard). Ist der Monitor-Eintrag
noch nicht geschrieben (der Server puffert bis ca. 1,5 s), wird `time` der Zeitpunkt des Alerts und die Dauer fehlt im Text.

## Installation und Start

```sql
@consumer/lilam_grafana/install_lilam_grafana.sql

-- imaginärer Grafana-Dienst (nur Outbox), als Job:
exec lilam_grafana.start_job(p_groupName => 'SUBWAY')

-- echtes Grafana, z. B. in einem eigenen Job; das Token nicht in die job_action schreiben,
-- sondern z. B. aus einem Wallet/Credential lesen:
exec lilam_grafana.run(p_groupName => 'SUBWAY', p_url => 'https://grafana.example.org', p_token => :token, p_dashboardUid => 'ubahn')

exec lilam_grafana.stop
```

Für echten HTTP-Versand braucht das Schema `EXECUTE` auf `UTL_HTTP` und eine Netzwerk-ACL für den Grafana-Host
(`DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE`), bei HTTPS zusätzlich ein Wallet (`UTL_HTTP.SET_WALLET`).

## Hinweise

- `LILAM_ALERTS` hat je Alert **einen** Status. Ein Kanal/Gruppe-Paar darf nur ein Consumer bearbeiten. Läuft zusätzlich
  `LILAM_MAILER` auf `LILAM_ALERT_MAIL_LOG`, nimmt er die U-Bahn-Alerts ebenfalls (und umgekehrt). Für Mail **und** Grafana
  zwei Regeln mit verschiedenen Handlern anlegen.
- Alerts anderer Gruppen auf demselben Kanal bleiben unberührt.
- Test: `test/autotest/FEATURES/REGELN/2026-10-07_grafana_consumer_test.sql` (nach `2026-10-07_ubahn_simulation.sql`).
