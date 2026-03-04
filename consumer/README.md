# LILAM Consumer
The scope of the LILAM framework ends with rule validation. After processing incoming signals and evaluating them against the active rule set, LILAM’s last action is to fire an alert. From this point on, decoupled consumers take over the responsibility for further notification and handling.

## Consumers Responsibilities
Consumers are responsible for routing alerts to a wide variety of destinations, ensuring that critical notifications are either immediately visible to stakeholders or available for further downstream analysis. Examples of integration targets include:
Email Recipients: Immediate notification for operational teams.
REST Endpoints: Integration with external observability stacks (e.g., Grafana dashboards, webhooks, Slack/Teams).
Downstream LILAM Processes: Chaining alerts to trigger complex, multi-stage monitoring workflows.

## Alerting / Activating
The consumers are 'activated' by `DBMS_ALERT` Signals. Typically expecting such signals is done within endless loops.
The Oracle ALERTING implementation ensures that waiting for signals doesn't cost any processor time. The loop is only needed to repeat processing alert by alert.
Alle benötigten Daten werden bereits mit der Alarmierung in einem JSON-String übermittelt.

```sql
-- waiting for alert - sample EMAIL consumer
DBMS_ALERT.REGISTER(LILAM_CONSUMER.C_ALERT_MAIL_LOG);
DBMS_OUTPUT.PUT_LINE('LILAM Mail-Log Consumer gestartet...');
LOOP
    COMMIT;
    -- C_ALERT_MAIL_LOG is the signal the consumer waits for
    -- v_msg_payload    is the JSON-data container
    DBMS_ALERT.WAITONE(LILAM_CONSUMER.C_ALERT_MAIL_LOG, v_msg_payload, v_status, 60);
    IF v_status = 0 THEN
      -- incoming ALARM detected - wake up!
      -- do anything here
    END IF;
END LOOP;
```
## JSON Alert Data
Diese Daten werden mit dem Alarm an den Consumer per JSON durchgereicht.
The column 'reference' is the reference to database tables. Therefore names of LILAM tables can be various, a short description of the meanings:
* PROC = Table which stores Process Data
* MON  = Table which stores Monitoring Data

| property | type | reference | description
| :-- | :-- | :-- | :--
| alert_id | number | LILAM_ALERTS.ID | unique identifier (table s. below)
| process_id | number |  process id | PROC.ID and MON.PROCESS_ID
| tab_name_process | string | table name | the process table name (e.g. LILAM_PROC)
| tab_name_monitor | string | table name | the monitoring table name (e.g. LILAM_MON)
| action_name | string | MON.ACTION, PROC.PROCESS_NAME | the name of a process, the action name of event or transaction
| context_name | string | MON.CONTEXT | optional more detailed information of an event or transaction
| action_count | number | MON.ACTION_COUNT | the concrete fired event or transaction identified by action_count
| rule_set_name | string | LILAM_RULES.SET_NAME | the name of the rule set
| rule_set_version | number |  LILAM_RULES.VERSION | specific rule set with this version
| rule_id | string | rules.id | JSON object within the rule set which was identified by rule_set_name
| alert_severity | string | rules.alert.severity | JSON parameter as part of the rule
| timestamp | string | system | timestamp in millis ('YYYY-MM-DD"T"HH24:MI:SS.FF6') when LILAM fires the alert

```

JSON

## Missed Alerts
A very first impulse of Oracle professionals could be countering that it is not sure that every single alert will be processed because of alerts can be overwritten. Correct.
Alerting means waking up Consumers. The Consumers themselve know their interests; they can be specialized to actions, contextes, group names, rules and rule sets and so on.
Zusätzlich stehen aber die Daten zum Zeitpunkt der Alarmierung bereits in der Tabelle `LILAM_ALERTS`zur Verfügung. Das hat zwei Vorteile:
1. Kein Verlust von Informationen bei Alarmierung in schneller Folge
2. Verarbeitung von mehreren Alarmen, auch wenn nur ein DBMS_ALERT erfolgte
3. Verarbeitung von Alarmen bei Neustart des Consumers (sofern erwünscht)


## Table LILAM_ALERTS
