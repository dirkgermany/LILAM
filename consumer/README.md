# LILAM Consumer
The scope of the LILAM framework ends with rule validation. After processing incoming signals and evaluating them against the active rule set, LILAM’s last action is to fire an alert. From this point on, decoupled consumers take over the responsibility for further notification and handling.

## Consumer Responsibilities
Consumers are responsible for routing alerts to a wide variety of destinations, ensuring that critical notifications are immediately visible to stakeholders or available for further downstream analysis. Integration targets include:

* **Email Recipients:** Immediate notification for operational teams.
* **REST Endpoints:** Integration with external observability stacks (e.g., Grafana dashboards, webhooks, Slack/Teams).
* **Downstream LILAM Processes:** Chaining alerts to trigger complex, multi-stage monitoring workflows.

## Activation via DBMS_ALERT
Consumers are activated by `DBMS_ALERT` signals, typically within an event loop. The Oracle `DBMS_ALERT` implementation ensures that waiting for signals consumes **zero CPU time** while idle. The loop is only required to process alerts sequentially as they arrive.

All necessary metadata is transmitted as a JSON payload during the alerting process.

```sql

-- Sample: Waiting for an alert (Email Consumer)
DBMS_ALERT.REGISTER(LILAM_CONSUMER.C_ALERT_MAIL_LOG);
DBMS_OUTPUT.PUT_LINE('LILAM Mail-Log Consumer started...');

LOOP
    COMMIT; -- Required to receive the next alert signal
    
    -- Wait for the specific signal (C_ALERT_MAIL_LOG)
    -- v_msg_payload contains the JSON metadata
    DBMS_ALERT.WAITONE(LILAM_CONSUMER.C_ALERT_MAIL_LOG, v_msg_payload, v_status, 60);
    
    IF v_status = 0 THEN
      -- Incoming ALERT detected - wake up and process!
      -- handle_alert(v_msg_payload);
    END IF;
END LOOP;

```

## JSON Alert Payload
The following metadata is transmitted to the consumer as a JSON object. Since LILAM supports dynamic table structures, the `reference` column explains how the payload maps to the database:

* **PROC** = Tables storing Process Data (e.g., `LILAM_PROC`)
* **MON**  = Tables storing Monitoring/Event Data (e.g., `LILAM_MON`)

| Property | Type | Reference | Description |
| :--- | :--- | :--- | :--- |
| `alert_id` | number | `LILAM_ALERTS.ID` | Unique identifier for the specific alert. |
| `process_id` | number | Process ID | Maps to `PROC.ID` and `MON.PROCESS_ID`. |
| `tab_name_process` | string | Table Name | The specific process table name (e.g., `LILAM_PROC`). |
| `tab_name_monitor` | string | Table Name | The specific monitoring table name (e.g., `LILAM_MON`). |
| `action_name` | string | `MON.ACTION` | The name of the process or the specific action. |
| `context_name` | string | `MON.CONTEXT` | Optional granular detail (e.g., a specific track segment). |
| `action_count` | number | `MON.ACTION_COUNT` | The specific occurrence ID of the triggered event. |
| `rule_set_name` | string | `LILAM_RULES.SET_NAME` | The name of the active rule set. |
| `rule_set_version` | number | `LILAM_RULES.VERSION` | The specific version of the applied rule set. |
| `rule_id` | string | `rules.id` | The unique ID of the triggered rule within the JSON set. |
| `alert_severity` | string | `rules.alert.severity` | Severity level defined in the rule. |
| `timestamp` | string | System | ISO 8601 timestamp (`YYYY-MM-DD"T"HH24:MI:SS.FF6`). |

## Missed Alerts and Reliability
A common concern for Oracle professionals might be that `DBMS_ALERT` signals can be overwritten if they occur in rapid succession, potentially leading to missed notifications. This is technically correct regarding the signal itself.

However, LILAM ensures 100% reliability by persisting the alert metadata in the `LILAM_ALERTS` table **before** the signal is fired. This architecture offers several key advantages:

1. **No Data Loss:** Even if alerts fire in rapid succession, every single event is safely stored in the database.
2. **Batch Processing:** A consumer can process multiple pending alerts from the table even if it was only woken up by a single signal.
3. **Recovery on Restart:** If a consumer is restarted, it can simply query the table for unprocessed alerts, ensuring no notification is lost during downtime.


## Table LILAM_ALERTS
The `LILAM_ALERTS` table acts as the persistent "Source of Truth" for all detected violations. While the JSON payload provides immediate data to the consumer, this table ensures durability and auditability.

| Column | Type | JSON Mapping | Description |
| :--- | :--- | :--- | :--- |
| **ALERT_ID** | `NUMBER` | `alert_id` | Primary Key. Unique identifier for the alert. |
| **PROCESS_ID** | `NUMBER` | `process_id` | Reference to the monitored process. |
| **PROCESS_NAME** | `VARCHAR2` | `action_name`¹ | The high-level name of the process. |
| **MASTER_TABLE_NAME** | `VARCHAR2` | `tab_name_process` | The table storing the process metadata. |
| **MONITOR_TABLE_NAME** | `VARCHAR2` | `tab_name_monitor` | The table storing the specific event data. |
| **ACTION_NAME** | `VARCHAR2` | `action_name`¹ | The specific action/event that triggered the rule. |
| **CONTEXT_NAME** | `VARCHAR2` | `context_name` | Optional granular detail (e.g., Segment ID). |
| **ACTION_COUNT** | `NUMBER` | `action_count` | Exact occurrence count of the action. |
| **RULE_SET_NAME** | `VARCHAR2` | `rule_set_name` | Name of the active rule set. |
| **RULE_ID** | `VARCHAR2` | `rule_id` | The specific rule triggered (from the JSON set). |
| **RULE_SET_VERSION** | `NUMBER` | `rule_set_version`| Version of the rule set used. |
| **ALERT_SEVERITY** | `VARCHAR2` | `alert_severity` | Severity level (e.g., INFO, WARN, CRITICAL). |
| **HANDLER_TYPE** | `VARCHAR2` | - | Intended handler (e.g., MAIL, REST, LOG). |
| **STATUS** | `VARCHAR2` | - | Current state (e.g., PENDING, PROCESSED). |
| **ERROR_MESSAGE** | `VARCHAR2` | - | Capture for errors during alert dispatch. |
| **CREATED_AT** | `TIMESTAMP` | `timestamp` | Audit timestamp when the alert was generated. |
| **PROCESSED_AT** | `TIMESTAMP` | - | Timestamp when the consumer finished handling. |

¹ *Note: In the JSON payload, `action_name` provides context for the trigger, which maps to both the specific action and the parent process name in the database.*

