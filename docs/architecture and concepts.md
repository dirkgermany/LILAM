# LILAM Architecture and Concepts

<details>
<summary>📖<b>Content</b></summary>

- [Technical Overview](#technical-overview)
- [Terms](#terms)
- [Process](#process)
- [Session](#session)
  - [Session Life Cycle](#session-life-cycle)
- [Logs / Severity](#logs--severity)
- [Log Level](#log-level)
- [Metrics](#metrics)
  - [Discrete Events](#discrete-events)
  - [Transaction Tracing](#transaction-tracing)
  - [Analysis & Outliers](#analysis--outliers)
- [Rule Management & Event Response](#rule-management--event-response)
  - [Trigger and Filter](#trigger-and-filter)
      - [Trigger Types](#trigger-types)
      - [Filtering Mechanism](#filtering-mechanism)
  - [JSON Structure](#json-structure)
- [Operating Modes](#operating-modes)
  - [In-Session](#in-session)
  - [Decoupled](#decoupled)
- [Tables](#tables)
  - [Process Table](#process-table)
  - [Log Table](#log-table)
  - [Monitor Table](#monitor-table)
  - [Registry Table](#registry-table)
  - [Rules Table](#rules-table)
  - [Internal Log Table](#internal-log-table)
- [API](#api)
  - [Session Handling](#session-handling)
  - [Process Control](#process-control)
  - [Logging](#logging)
  - [Metrics](#metrics)
  - [Server Control](#server-control)

</details>


## Technical Overview
LILAM utilizes the core functionalities made available by Oracle through its PL/SQL (from version 12 onwards, tested under 19c and 26 AI). LILAM itself is a PL/SQL script that can be used by other PL/SQL scripts in various modi operandi.

This means LILAM is the opposite of "black magic" or over-the-top engineering. By using less tables, indexes, a sequence, and pipes, LILAM pursues a 100% Zero-Dependency strategy. In fact, due to the communication via pipes, scenarios are conceivable in which LILAM is used in conjunction with non-PL/SQL applications. The security of session, log, and metric data is guaranteed by autonomous transactions. These are sharply separated from data in memory and from the transactions of other applications, ensuring their own COMMIT even if the application had to perform a rollback.

LILAM itself is a package consisting of the usual specification (.pks) and the body (.pkb). The code consists of a few thousand real lines of code; in version 1.3, which already featured most functionalities, it was around 3,000 LOC. The functionalities of the LILAM client and the LILAM server are entirely part of this code.

Installation requires nothing more than copying the code into a suitable DB schema and granting a few permissions. More on this in setup.md.

**Programmatic vs. Declarative:** Whenever possible, I have tried to develop LILAM so that it works without configuration tables, files, or the like. Rather, my goal was for the tool's behavior to be controlled through the API—i.e., programmatically. As a developer, I know how annoying it can be to have to struggle through hours of preparation before finally getting 'down to business.' 

In fact, there are currently no configuration table(s), startup scripts, or similar requirements to use the full scope of LILAM (as of v1.3.0).

---
## Terms
First, some important clarifications of terms within the LILAM context.

---
## Process
LILAM is used to monitor applications that ultimately represent a process of some kind. A process is therefore something that can be mapped or represented with software. Within the meaning of LILAM, the developer determines when a process begins and when it ends. 

A process specifically includes its name, lifecycle information, and planned as well as completed work steps. 

---
## Session
A session represents the lifecycle of a logged process. A process 'lives' within a session. A session is opened once and closed once. For clean, traceable, and consistent process states, the final closing of sessions is indispensable.

### Session Life Cycle
**With the beginning** of a Log Session the one and only log entry is written to the *master table*.
**During** the Session this one log entry can be updated and additional informations can be written to the *detail table*.
**At the end** of a Session the log entry again can be updated.

>**Important Note on Data Persistence:**
>LILAM utilizes high-performance in-memory buffering to minimize database load. Monitoring data and process states are collected in RAM and only persisted to the >database once a threshold (e.g., 100 entries) is reached.
>
>**To guarantee full data integrity, calling CLOSE_SESSION at the end of your process is mandatory.**
>
>If a process terminates abnormally (e.g., due to an uncaught exception) without reaching CLOSE_SESSION, any data remaining in the buffer since the last automatic >flush will be lost. We strongly recommend including CLOSE_SESSION in your application’s central exception handler.

Ultimately, all that is required for a complete life cycle is to call the NEW_SESSION function at the beginning of the session and the CLOSE_SESSION procedure at the end of the session.

The session is more of a technical perspective on the workflows within LILAM, while the process is the view 'to the outside.' I believe these two terms—session and process—can be used almost synonymously in daily LILAM operations. It doesn't really hurt if they are mixed a bit.

---
## Logs / Severity
These are the usual suspects; SILENT, ERROR, WARN, INFO, DEBUG (in order of their weight). Need I say more? 
Ultimately, the developer decides which severity level to assign to an event in their process flow. 
Regarding the logging of process logs, the severity, the timestamp, and the most descriptive detail information possible are important.

---
## Log Level
Depending on the log level, log messages are either processed or ignored. 
LILAM has one exception, the **Metric Level** (logLevelMonitor): In the hierarchy, this level sits at the threshold for reporting directly after WARN and before INFO. This means that if 'only' WARN is activated, metric messages are ignored; if INFO is activated, If INFO is activated, all lower-level messages (like DEBUG and TRACE) are ignored (Operational Insight). 

A different log level can be selected for each process.

---
## Metrics
LILAM captures detailed process steps by measuring their **frequency** and **duration**. A process can contain any number of named actions, each occurring multiple times. 

### Discrete Events
**MARK_EVENT:** Records a point-in-time milestone. LILAM measures the time spans between consecutive occurrences of the same action.

### Transaction Tracing
**TRACE:** Measures the specific duration of a work step from start to finish.

### Analysis & Outliers
For every action, LILAM maintains a **moving average**. This average is recorded with each new entry, allowing for real-time performance tracking. If a trace significantly deviates from this baseline, LILAM evaluates your custom JSON rule-sets to automatically trigger specific **warnings** or **alerts** in the Log Table.

**Example:**
A process monitors actions **'A'** and **'B'**:
*   Action **'A'** is reported several times as a milestone. LILAM tracks the count and the intervals between these events.
*   Action **'B'** is a timed transaction (Trace). LILAM tracks the exact duration of each 'B' execution.
*   **Results:** Totals, time histories, and averages for 'A' and 'B' are managed independently, providing a clear picture of process stability.

---
## Rule Management & Event Response
**Rules** define how LILAM servers react to incoming **signals**, transforming LILAM from a passive monitoring tool into an active **orchestrator**.

Rules are organized into **Rule Sets**, structured as flexible JSON objects. The central table `LILA_RULES` serves as the repository for these configurations, storing each JSON-based rule set alongside a **version stamp**. This versioning allows every LILAM server to track, verify, and synchronize its active logic in real-time.

### Trigger and Filter
LILAM uses a hierarchical **Filtering Mechanism** to react to signals with high efficiency. Each rule is assigned to a specific **Trigger Type**, which defines the event that initiates the evaluation.

#### Trigger Types

**Available Trigger Types:**
*   **`TRACE_START`**: Fired when a time measurement (transaction) begins. Useful for pre-checks or initializing external dependencies.
*   **`TRACE_STOP`**: Fired when a transaction is completed. Ideal for performance monitoring and execution-time analysis.
*   **`MARK_EVENT`**: Reacts to the arrival of a point-in-time milestone (Marker).
*   **`PROCESS_START`**: Triggered by beginning process.
*   **`PROCESS_UPDATE`**: Triggered by status changes or progress reports (e.g., step counters).
*   **`PROCESS_END`**: Triggered by ending a process.

#### Filtering Mechanism
To minimize system overhead, the LILAM server evaluates rules in a two-stage process using high-performance associative arrays in memory, following the principle of **Specific before General**:
1.  **Context Filter (`Action|Context`):** The system first checks for a highly specific rule matching the exact combination of action and context (e.g., `STATION_EXIT` at station `Moulin Rouge`).
2.  **Action Filter (`Action`):** If no context-specific rule is found, the system falls back to searching for a general rule assigned only to the action. This allows for defining global thresholds across all contexts.

Multiple rules can be assigned to the same trigger. LILAM processes these rule lists sequentially, enabling complex chains of reaction.

### Condition & Operator Matrix
The following metrics and operators can be defined within the JSON rule sets to trigger alerts.

#### Process Metrics
**Trigger:** PROCESS_START, PROCESS_UPDATE, PROCESS_STOP
These rules evaluate the global state of a process stored in the Master Table.

| Metric         | Operator Name (JSON)   | Technical Condition                               | Use Case                                       |
| :------------- | :--------------------- | :------------------------------------------------ | :--------------------------------------------- |
| **Runtime**    | `RUNTIME_EXCEEDED`     | `(SYSTIMESTAMP - PROCESS_START) > value`          | Detect hanging or "zombie" processes.          |
| **Runtime**    | `MAX_RUNTIME_EXCEEDED` | `(PROCESS_END - PROCESS_START) > value`           | Process took too much time                     |
| **Progress**   | `STEPS_LEFT_HIGH`      | `(STEPS_TODO - STEPS_DONE) > value`               | Check for unfinished work at process end.      |
| **Efficiency** | `SUCCESS_RATE_LOW`     | `(STEPS_DONE / STEPS_TODO) * 100 < value`         | Monitor batch processing quality.              |
| **Frequency**  | `MAX_OCCURRENCE`       | `STEPS_DONE > value`                              | Flood protection / infinite loop detection.    |
| **Status**     | `STATUS_EQUALS`        | `STATUS = value`                                  | React to specific error status codes.          |
| **Info Text**  | `INFO_CONTAINS`        | `UPPER(INFO) LIKE '%' \|\| UPPER(value) \|\| '%'` | Search for keywords like "FATAL" or "ERROR".   |
| **Dependency** | `PRECEDED_BY`          | `value = <Event name>`                            | Validates predecessor.                         |
| **Dependency** | `PRECEDED_BY_WITHIN_SECS` | `value = <Event name>`                         | Validates predecessor and max. delay. |

#### Action & Context Metrics
**Trigger:** TRACE_START, TRACE_STOP, MARK_EVENT
These rules evaluate granular performance data from the Monitor Table.

| Metric          | Operator Name (JSON)  | Technical Condition                             | Use Case                                      |
| :-------------- | :-------------------- | :---------------------------------------------- | :-------------------------------------------- |
| **Execution**   | `ON_EVENT`            | `Trigger fired`                                 | Trigger an orchestrator as soon as event hits.|
| **Trace Start** | `ON_START`            | `Trigger fired`                                 | Pre-process data or lock resources.           |
| **Trace End**   | `ON_STOP`             | `Trigger fired`                                 | Signal completion to downstream systems.      |
| **Duration**    | `MAX_DURATION_MS`     | `used_time > value`                             | Absolute time limit for a specific action.    |
| **Variance**    | `AVG_DEVIATION_PCT`   | `used_time > (avg_time * (1 + value/100))`      | Relative deviation from moving average.       |
| **Frequency**   | `MAX_OCCURRENCE`      | `action_count > value`                          | Flood protection / infinite loop detection.   |
| **Interval**    | `MAX_GAP_SECONDS`     | `(TIMESTAMP - LAST_TIMESTAMP) > value`          | Detect stall between two consecutive events.  |
| **Dependency**  | `PRECEDED_BY`          | `value = <Event name>`                         | Validates predecessor.                         |
| **Dependency**  | `PRECEDED_BY_WITHIN_SECS` | `value = <Event name>`                      | Validates predecessor and max. delay. |

### JSON Structure
The JSON object is divided into a header for metadata and an array of individual rules. Alert throttling is managed in seconds:

```json
{
  "header": {
    "rule_set": "SUBWAY_PROD",
    "rule_set_version": 5,
    "description": "Performance rules for Line 1"
  },
  "rules": [
    {
      "id": "R-001",
      "trigger_type": "TRACE_STOP",
      "action": "STATION_EXIT",
      "context": "Moulin Rouge",
      "condition": {
        "metric": "RUNTIME",
        "operator": "RUNTIME_EXCEEDED",
        "value": 300
      },
      "alert": {
        "handler": "LOG_AND_MAIL",
        "severity": "CRITICAL",
        "throttle_seconds": 900
      }
    }
  ]
}

```

---
## Operating Modes
LILAM features two operating modes that applications can use. It is possible to address these modes in parallel from within an application—I call this 'hybrid usage.'

### In-Session
This form of integration is likely the standard when it comes to incorporating PL/SQL packages. The 'other' package extends the functional scope of the caller; the program flow is **synchronous**, meaning the control flow leaves the calling package, continues in the called package, and then returns. In In-Session mode, LILAM is exclusively available to the application.

### Decoupled
The opposite of synchronous execution in In-Session mode is the **asynchronous** Decoupled mode.

In this mode, LILAM functions as a **LILAM Server**, which writes status changes, logs, and metrics into the log tables independently of the calling program—the **LILAM Client**. Using 'Fire & Forget' via pipes, the LILAM Client can deliver large amounts of data in a very short time without being slowed down itself.

Two exceptions must be considered here:

1. LILAM Clients that threaten to flood the channel to the LILAM Server due to an excessively high reporting rate are gently and temporarily—and barely noticeably—throttled until the LILAM Server has processed the bulk of the load (Backpressure Management). Mind you, we are talking about magnitudes in the millisecond range. This mechanism can be deactivated via an API call in high-end environments, such as powerful ODAs (default is 'active').

2. Calls that request data packets from the LILAM Server are necessarily synchronous if the application wants to process the response itself afterwards. However, scenarios are also conceivable here in which, for example, LILAM Client 'A' requests a data packet from the LILAM Server on behalf of LILAM Client 'B'. 

This would turn LILAM Client 'A' into a producer, the LILAM Server into a dispatcher, and LILAM Client 'C' into a consumer. **A lightweight message broker pattern**

With the possibility of using several LILAM Servers in parallel and simultaneously allowing individual clients to speak with multiple LILAM Servers (and additionally integrating LILAM as a library), the use of LILAM is conceivable in a wide variety of scenarios. Load balancing, separation of mission-critical and less critical applications, division into departments or teams, multi-tenancy...

---
## Tables
A total of four tables are required for operation and user data, one of which serves solely for the internal synchronization of multiple LILAM servers (more on this later). The detailed structure of these tables is described in the README file of the LILAM project on GitHub.

LILAM uses three tables for storing process, log, and monitoring data. Their names are derived from a common, freely configurable master name (`tabNameMaster`) by appending a fixed suffix.
 
| Purpose | Fixed Suffix | Default Table Name |
| ------------ | ------- | ------------ |
| Process data | `_PROC` | `LILAM_PROC`  |
| Log data     | `_LOG`  | `LILAM_LOG`   |
| Monitoring data | `_MON` | `LILAM_MON` |

For example, if `tabNameMaster` is set to `MY_APPLICATION`, LILAM uses:
 
- `MY_APPLICATION_PROC`
- `MY_APPLICATION_LOG`
- `MY_APPLICATION_MON`
 
> [!IMPORTANT]
> Only the master name is configurable. The suffixes `_PROC`, `_LOG`, and `_MON` are fixed and define the relationship between the three tables.


### Process Table
The process table represents the processes. For each process, exactly one entry exists in this master table. During the lifecycle of a process, this data may change—especially the counter for completed process steps (i.e., the work progress). Additional information includes the currently used log level for this process, the name of the process, the timestamps for process start, last reported update, and completion. Another important piece of data is the Session ID, which is used for management.

#### Table Structure

All Process Tables use the following structure, regardless of the configured table name:

| Column | Data Type | Description |
| --- | --- | --- |
| `ID` | `NUMBER(19)` | Unique Process ID assigned when the process is initialized. It is used to associate logs, metrics, and subsequent API calls with the process. |
| `PROCESS_NAME` | `VARCHAR2(100)` | Application-defined name used to identify the process. |
| `LOG_LEVEL` | `NUMBER` | Active log level for the process. |
| `PROCESS_START` | `TIMESTAMP(6)` | Timestamp at which the process was initialized. |
| `PROCESS_END` | `TIMESTAMP(6)` | Timestamp at which the process was finalized. |
| `LAST_UPDATE` | `TIMESTAMP(6)` | Timestamp of the most recent update to the process record. |
| `STEPS_TODO` | `NUMBER` | Planned number of work steps for the process. This value is managed by the calling application. |
| `STEPS_DONE` | `NUMBER` | Number of completed work steps. This value is managed by the calling application through the Process Control API. |
| `STATUS` | `NUMBER(2)` | Application-defined numerical process status. LILAM does not assign a specific meaning to this value. |
| `INFO` | `VARCHAR2(2000)` | Application-defined information associated with the process. |
| `PROCESS_IMMORTAL` | `NUMBER(1)` | Indicates whether the process is protected from automatic retention cleanup. |
| `TAB_NAME_MASTER` | `VARCHAR2(100)` | Master table name associated with the process and used as the basis for deriving the related LILAM table names. |

The number of planned steps as well as the steps already completed are controlled by the application, either by explicitly setting these values or via an API trigger.

### Log Table
Stores chronological log entries including timestamps, severity levels, and detailed diagnostic information. Each entry is linked to its process through the `PROCESS_ID`.

#### Table Structure

All Log Tables use the following structure, regardless of the configured table name:

| Column | Data Type | Description |
| --- | --- | --- |
| `PROCESS_ID` | `NUMBER(19)` | Identifies the process to which the log entry belongs. |
| `NO` | `NUMBER(19)` | Sequential counter per process. It reflects the order in which the logging procedures were called. |
| `INFO` | `VARCHAR2(2000)` | Contains the actual log message. |
| `LOG_LEVEL` | `VARCHAR2(10)` | Numeric representation of the log severity level. |
| `LOG_LEVEL_C` | `VARCHAR2(10)` | Text representation of the log severity level, such as `ERROR`, `WARN`, `INFO`, or `DEBUG`. |
| `SESSION_TIME` | `TIMESTAMP(6)` | Timestamp at which the log entry was recorded. |
| `SESSION_USER` | `VARCHAR2(50)` | Database session user, determined by `SYS_CONTEXT('USERENV','SESSION_USER')`. |
| `HOST_NAME` | `VARCHAR2(50)` | Client host, determined by `SYS_CONTEXT('USERENV','HOST')`. |
| `CALLER` | `VARCHAR2(255)` | Name of the calling procedure. |
| `ERR_STACK` | `VARCHAR2(4000)` | Error stack information, if available. |
| `ERR_BACKTRACE` | `VARCHAR2(4000)` | Error backtrace information, if available. |
| `ERR_CALLSTACK` | `VARCHAR2(4000)` | Call stack information, if available. |

### Monitor Table
Stores detailed monitoring data for events and traces. Each entry is linked to its process through `PROCESS_ID`.

Events and traces share the same table structure. The `MON_TYPE` column identifies the type of monitoring entry, while `ACTION` and `CONTEXT` identify the monitored activity.

#### Table Structure

| Column | Data Type | Description |
| --- | --- | --- |
| `PROCESS_ID` | `NUMBER(19)` | Identifies the process to which the monitoring entry belongs. |
| `MON_TYPE` | `NUMBER` | Identifies the monitoring type. `0` represents an Event. |
| `START_TIME` | `TIMESTAMP(6)` | Timestamp at which the Event occurred or the Trace started. |
| `STOP_TIME` | `TIMESTAMP(6)` | Timestamp at which the Trace ended. Remains `NULL` for Events. |
| `SESSION_USER` | `VARCHAR2(50)` | Database session user, determined by `SYS_CONTEXT('USERENV','SESSION_USER')`. |
| `HOST_NAME` | `VARCHAR2(50)` | Client host, determined by `SYS_CONTEXT('USERENV','HOST')`. |
| `ACTION` | `VARCHAR2(100)` | Name of the monitored action. |
| `CONTEXT` | `VARCHAR2(100)` | Optional context used to distinguish occurrences of the same action. |
| `USED_MILLIS` | `NUMBER(19)` | Measured duration in milliseconds. |
| `AVG_MILLIS` | `NUMBER(19)` | Moving average duration in milliseconds for the corresponding action and context. |
| `ACTION_COUNT` | `NUMBER(19)` | Number of occurrences recorded for the corresponding action and context. |

### Application-Specific Tables
In the interest of flexibility, it is possible to use dedicated LILAM logging tables for different scenarios, applications, or processes. This also requires no configuration table or similar overhead. The names of the master and detail tables are optionally set during the API call to lilam.new_session or lilam.server_new_session.

But beware! The choice of tables and their names should be well-planned to avoid chaos caused by an excessive number of different LILAM logging tables.

### Registry Table

The `LILAM_SERVER_REGISTRY` table maintains the runtime state of registered LILAM servers. Unlike the process, log, and monitor tables, its name is fixed and is not derived from `tabNameMaster`.

Each active LILAM server registers itself in this table and periodically updates its activity information. Clients use the registry to discover suitable servers and to select a server based on its current load.

If `SERVER_NEW_SESSION` is called with a `p_groupName`, only servers registered for the requested group are considered.

#### Table Structure
> [!NOTE]
> `LAST_ACTIVITY` acts as the server heartbeat. During server discovery, entries older than 15 seconds are not considered available.

| Column | Data Type | Description |
| --- | --- | --- |
| `PIPE_NAME` | `VARCHAR2(50)` | Unique pipe name used to identify and communicate with the LILAM server. |
| `GROUP_NAME` | `VARCHAR2(50)` | Optional group to which the server is assigned. Used to restrict server selection when `p_groupName` is specified. |
| `LAST_ACTIVITY` | `TIMESTAMP(3)` | Timestamp of the server's most recent heartbeat/activity. Used to determine whether the server is still available. |
| `CURRENT_LOAD` | `NUMBER` | Current server load used by clients when selecting an available server. |
| `IS_ACTIVE` | `NUMBER(1)` | Indicates whether the server is marked as active. |
| `STATUS` | `VARCHAR2(20)` | Current status of the server. |
| `PROCESSING` | `NUMBER` | Indicates what the server is currently processing. |
| `RULE_SET_NAME` | `VARCHAR2(30)` | Name of the rule set currently associated with the server. |
| `SET_IN_USE` | `NUMBER` | Version of the rule set currently imported by the server. |

### Rules Table
**Rules** define how LILAM reacts to incoming **signals**. They are organized into **Rule Sets**, which are structured as JSON objects for maximum flexibility.

The central table `LILAM_RULES` acts as the repository for these configurations. Its name is fixed and is not derived from `tabNameMaster`.

Rule Sets are stored as JSON documents and identified by their name and version. This allows different versions of the same Rule Set to be maintained and enables LILAM servers to track which Rule Set and version is currently in use.

#### Table Structure

| Column | Data Type | Description |
| --- | --- | --- |
| `RULE_SET` | `CLOB` | Contains the Rule Set as a JSON document. |
| `SET_NAME` | `VARCHAR2(30)` | Name identifying the Rule Set. |
| `VERSION` | `NUMBER` | Version of the Rule Set. |
| `CREATED` | `TIMESTAMP(6)` | Timestamp at which the Rule Set was created. |
| `AUTHOR` | `VARCHAR2(50)` | Author associated with the Rule Set. |

### Internal Log Table

The `LILAM_LOG_INTERNAL` table provides a dedicated fallback logging mechanism for errors occurring within the LILAM framework itself.

Unlike the process, log, and monitor tables, its name is fixed and must not be changed.

Internal framework errors must not be processed through LILAM's regular logging mechanisms, as this could cause recursive failures or conceal the original error. Therefore, highly specialized internal routines can create this table when required and write diagnostic information directly to it.

> [!IMPORTANT]
> `LILAM_LOG_INTERNAL` is intended exclusively for internal framework errors. Application logging belongs in the regular Log Table associated with the corresponding process.

#### Table Structure

| Column | Data Type | Description |
| --- | --- | --- |
| `ID` | `NUMBER` | Identity-generated unique identifier of the internal log entry. |
| `LOG_TIMESTAMP` | `TIMESTAMP(6)` | Timestamp of the internal error. Defaults to `SYSTIMESTAMP`. |
| `ERROR_CODE` | `NUMBER` | Oracle error code, if available. |
| `ERROR_MESSAGE` | `VARCHAR2(4000)` | Error message associated with the internal failure. |
| `ERROR_STACK` | `VARCHAR2(4000)` | Error stack associated with the failure. |
| `ERROR_BACKTRACE` | `VARCHAR2(4000)` | Error backtrace associated with the failure. |
| `CALL_STACK` | `VARCHAR2(4000)` | Call stack at the point at which the error was recorded. |
| `MODULE_NAME` | `VARCHAR2(200)` | LILAM module in which the error occurred. |
| `LOG_OPERATION` | `VARCHAR2(200)` | Internal operation being performed when the error was recorded. |

---
## API
The LILAM API consists of approximately 35 procedures and functions, some of which are overloaded. Since static polymorphism does not change the outcome of the API calls, I am listing only the names of the procedures and functions below. The API can be divided into five groups. For a more detailed view, see the ["API.md"](API.md).

**API overview:**

### Session Handling
* **NEW_SESSION:** Starts a new session.
* **SERVER_NEW_SESSION:** Starts a new session within a LILAM server.
* **CLOSE_SESSION:** Terminates the lifecycle of the session.

### Process Control
#### Setting Values
* **SET_PROCESS_STATUS:** Sets information regarding the current state of the process.
* **SET_PROC_STEPS_TODO:** Sets the (initial) value of the expected work steps for the process.
* **SET_PROC_STEPS_DONE:** Sets the number of work steps completed (so far).
* **PROC_STEP_DONE:** Increments the counter for completed work steps (Steps Done).

#### Querying Values
* **GET_PROC_STEPS_DONE:** Determines the total number of work steps completed for the process so far.
* **GET_PROC_STEPS_TODO:** Returns the previously set value for expected work steps.
* **GET_PROCESS_START:** Returns the start time of the process.
* **GET_PROCESS_END:** Returns the end time of a process.
* **GET_PROCESS_STATUS:** Returns a value previously set by the developer as needed.
* **GET_PROCESS_INFO:** Provides process information; outside of LILAMs control.
* **GET_PROCESS_DATA:** Returns all process data in a specific structure.
* **GET_PROCESS_DATA_JSON:** Returns all process data in JSON format.

### Logging
* **INFO:** Reports a message with severity 'Info'.
* **DEBUG:** Reports a message with severity 'Debug'.
* **WARN:** Reports a message with severity 'Warn'.
* **ERROR:** Reports a message with severity 'Error'.

### Metrics
#### Setting Values
* **MARK_EVENT:** Documents a completed work step for an action and triggers the sum and time calculations for those actions.
* **TRACE_START:** Initializes a duration measurement for a specific work step (trace) by capturing the start timestamp in the session memory.
* **TRACE_STOP:** Ends the measurement for a specific work step (trace) and persists it to the monitor table.

#### Querying Values
* **GET_METRIC_AVG_DURATION:** Returns the average processing duration for actions with the same name within a process.
* **GET_METRIC_STEPS:** Returns the current number of completed work steps for actions with the same name within a process.

### Server Control
* **START_SERVER:** Starts a LILAM server.
* **CREATE_SERVER:** Starts a LILAM server as a background process (Job).
* **SERVER_SHUTDOWN:** Shuts down a LILAM server.
* **GET_SERVER_PIPE:** Returns the name of the pipe used to communicate with the server.
* **SERVER_UPDATE_RULES:** Implements or changes the used rule set

