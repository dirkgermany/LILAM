# LILAM Rule Definitions

This folder contains example rule sets for the **Metro Transit Suite**. 
LILAM uses a JSON-based rules engine to evaluate events in real-time.


## Example: [metro_rule_set_v1.json](./metro_rule_set_v1.json)

### Key Rules in this set:
* **SEQ-003 (SLA Check):** Triggers a `WARN` alert if a track section traversal takes longer than 25,000ms.
* **SEQ-008 (Anomaly Detection):** Uses **EWMA** to detect if travel times deviate by more than 20% from the moving average.
* **SEQ-001 (Sequence Validation):** Ensures "Close Door" is followed by "Track Section" within 10 seconds.

## Schema Overview

| Field | Description |
| :--- | :--- |
| `trigger_type` | The event type (`TRACE_START`, `TRACE_STOP`, `MARK_EVENT`, `PROCESS_START`, `PROCESS_STOP`) |
| `operator` | The logic applied (e.g., `MAX_DURATION_MS`, `AVG_DEVIATION_PCT`, `PRECEDED_BY`) |
| `throttle_seconds` | Prevents alert flooding by limiting notifications for the same rule. |
