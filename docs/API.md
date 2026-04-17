# LILAM API Reference

<details>
<summary>📖<b>Content</b></summary>

- [Quick Start](#quick-start)
- [Functions and Procedures](#functions-and-procedures)
  - [Session handling](#session-handling)
    - [Function NEW_SESSION](#function-new_session--server_new_session)
    - [Procedure CLOSE_SESSION](#procedure-close_session)
    - [Procedure SET_PROCESS_STATUS](#procedure-set_process_status)
    - [Procedure SET_STEPS_TODO](#procedure-set_steps_todo)
    - [Procedure SET_STEPS_DONE](#procedure-set_steps_done)
    - [Procedure STEP_DONE](#procedure-step_done)
    - [Procedure FINAL_RESCUE](#procedure-final_rescue)
  - [Process control](#process-control)
    - [SET_PROCESS_STATUS](#procedure-set_process_status)
    - [SET_STEPS_TODO](#procedure-set_steps_todo)
    - [STEP_DONE](#procedure-step_done)
    - [SET_STEPS_DONE](#procedure-set_steps_todo)
    - [GET_PROC_STEPS_DONE](fFunction-get_proc_steps_done)
    - [GET_PROC_STEPS_TODO](fFunction-get_proc_steps_done)
    - [GET_PROCESS_START](#function-get_process_start)
    - [GET_PROCESS_END](#function-get_process_end)
    - [GET_PROCESS_STATUS](#function-get_process_status)
    - [GET_PROCESS_INFO](#function-get_process_info)
    - [GET_PROCESS_DATA](#function-get_process_data)
  - [Logging](#logging)
    - [ERROR](#procedure-error)
    - [WARN](#procedure-warn)
    - [INFO](#procedure-error)
    - [DEBUG](#procedure-debug)
  - [Metrics](#metrics)
    - [MARK_STEP](#procedure-mark_step)
    - [GET_METRIC_AVG_DURATION](#function-get_metric_avg_duration)
    - [GET_METRIC_STEPS](#function-get_metric_steps)
  - [Server control](#server-control)
    - [START_SERVER](#procedure-start_server)
    - [SERVER_SHUTDOWN](#procedure-server_shutdown)
    - [GET_SERVER_PIPE](#function-get_server_pipe)
    - [SERVER_UPDATE_RULES](#procedure-server_update_rules)
  - [Appendix](#appendix)
    - [Log Level](#log-level)
        - [Declaration of Log Levels](#declaration-of-log-levels)
    - [JSON API Interface](#json-api-interface)
    - [Record Type t_session_init](#record-type-t_session_init)
    - [Record Type t_process_rec](#record-type-t_process_rec)

</details>


> [!TIP]
> This document serves as the LILAM API reference, providing a straightforward description of the programming interface.
> For those new to LILAM, I recommend starting with the document [architecture and concepts.md](architecture%20and%20concepts.md), which (hopefully) provides a fundamental understanding of how LILAM works. Furthermore, the demos and examples in the #demo folder demonstrate how easily the LILAM API can be integrated.

---
## Quick Start
### In-Session Mode
The following example shows the simplest way to initialize a session and log a message. 
LILAM uses reasonable defaults, so you only need to provide a process name and the logLevel setting.
After your application ends there should be three tables:
* LILAM_PROC (the process data table)
* LILAM_LOG (table with logging data)
* LILAM_MON (table with events and transaction metrics)


```sql
DECLARE
  l_processId    NUMBER;
  l_sessionInit  t_session_init;
BEGIN
  -- 1. Setup minimal configuration
  l_sessionInit.processName := 'MY_FIRST_SYNC';
  l_sessionInit.logLevel    := logLevelInfo;     -- default is logLevelMonitorr
  
  -- 2. Initialize the session
  l_processId := lilam.new_session(p_sessionInit => l_sessionInit);
  
  -- 3. Start logging
  lilam.info(p_processId => l_processId, p_info => 'LILAM is up and running!');
  
  -- 4. Mark a work step
  lilam.mark_event(p_processId => l_processId, p_actionName => 'DATA_LOAD');
  dbms_session.sleep(1);
  lilam.mark_event(p_processId => l_processId, p_actionName => 'DATA_LOAD');
  
  -- Missing a COMMIT? 
  -- Don't worry: LILAM uses AUTONOMOUS TRANSACTIONS.
  -- This ensures that logs are stored immediately and independently 
  -- from your main transaction (even if you ROLLBACK).
END;
/
```

### Decoupled (Server) Mode

**Step 1: Start the server (Session A)**

To use the decoupled mode, you first need to start a LILAM server. For this example, use a dedicated database session (e.g., a second instance of SQL Developer), as the server will block the session while it is running. In production environments, the server is typically started as a background process via `DBMS_JOB` or `DBMS_SCHEDULE` to avoid session blocking.

By default, the client automatically identifies and connects to the server with the lowest current load. This means the client does not need to know specific server names in advance.
Additionally, it is possible to explicitly connect a client to a server assigned to a specific group. In this case, the system also automatically selects the server with the lowest current workload within that group.

Start the server with 

```sql
BEGIN
  lilam.start_server('MY_FIRST_LILAM_SERVER', 'SECURE PASSWORD');
END;
/
```

**Step 2: Execute the client code (Session B)**

In a separate session, execute the following block. Note that `SERVER_NEW_SESSION` automatically connects to your active server.

```sql
DECLARE
  l_processId    NUMBER;
  l_sessionInit  t_session_init;
BEGIN
  -- 1. Setup minimal configuration
  l_sessionInit.processName := 'DECOUPLED_SYNC';
  l_sessionInit.logLevel    := logLevelInfo;     -- default is logLevelMonitorr
  
  -- 2. Initialize the session
  -- Use SERVER_NEW_SESSION to connect to a central LILAM management server.
  -- In this mode, LILAM acts as a transparent relay: the local framework 
  -- handles all communication with the central server in the background, 
  -- offloading the actual logging and monitoring
  l_processId := lilam.server_new_session(p_sessionInit => l_sessionInit);
  
  -- 3. Start logging
  lilam.info(p_processId => l_processId, p_info => 'LILAM is up and running!');
  
  -- 4. Mark a work step and trace a business transaction
  lilam.mark_event(p_processId => l_processId, p_actionName => 'DATA_LOAD'); -- simple event
  lilam.trace_start(p_processId => l_processId, p_actionName => 'NEXT_STATION'); -- begins a transaction
  dbms_session.sleep(1);
  lilam.mark_event(p_processId => l_processId, p_actionName => 'DATA_LOAD');
  lilam.trace_stop(p_processId => l_processId, p_actionName => 'TRACK_SECTION'); -- ends the transaction

  -- 5. Update Process Status
  lilam.step_done(p_processId => l_processId); -- increments process step counter

  -- 5. Shutdown the server
  lilam.server_shutdown(p_processId => l_processId, p_password => 'SECURE PASSWORD');

END;
/
```

---
## Functions and Procedures
Parameters for procedures and functions can be mandatory, nullable, or optional and some can have default values.In the overview tables, they are marked as follows:

### Shortcuts for parameter requirement
* <a id="M"> ***M***andatory</a>
* <a id="O"> ***O***ptional</a>
* <a id="N"> ***N***ullable</a>
* <a id="D"> ***D***efault</a>

The functions and procedures are organized into the following five groups:
* Session Handling
* Process Control
* Logging
* Metrics
* Server Control

---
### Session Handling

| Name               | Type      | Description                         | Scope
| ------------------ | --------- | ----------------------------------- | ---------
| [NEW_SESSION](#function-new_session--server_new_session) | Function  | Opens a new log session | Session control
| [SERVER_NEW_SESSION](#function-new_session--server_new_session) | Function  | Opens a new decoupled session | Session control
| [CLOSE_SESSION](#procedure-close_session) | Procedure | Ends a log session | Session control

> [!NOTE]
> All API calls are the same, independent of whether LILAM is used 'locally' or in a 'decoupled' manner. One exception is the function `SERVER_NEW_SESSION`, which initializes the LILAM package to function as a dedicated client, managing the communication with the LILAM server seamlessly.
> **The parameters and return value of `SERVER_NEW_SESSION` are nearly identical to those of `NEW_SESSION`.** However, `SERVER_NEW_SESSION` includes an additional parameter to specify a target server. This ensures that the client connects to a specific server instance (e.g., for department-specific or multi-tenant tasks) rather than simply choosing the one with the lowest load.

#### Function NEW_SESSION / SERVER_NEW_SESSION
The `NEW_SESSION` resp. `SERVER_NEW_SESSION` function starts the logging session for a process. This procedure must be called first. Calls to the API without a prior `NEW_SESSION` do not make sense or can (theoretically) lead to undefined states.
`NEW_SESSION` and `SERVER_NEW_SESSION` are overloaded so various signatures are available.

**Signatures**

To accommodate different logging requirements, the following variants are available:

<details>
  <summary><b>1. Basic Mode</b> (Standard initialization)</summary>
  
 ```sql
  FUNCTION NEW_SESSION(
    p_processName   VARCHAR2,
    p_groupName     VARCHAR2,
    p_logLevel      PLS_INTEGER, 
    p_TabNameMaster VARCHAR2 DEFAULT 'LILAM_LOG'
  )
 ```
</details>

<details>
  <summary><b>2. Retention Mode</b> (With automated cleanup)</summary>

```sql
FUNCTION NEW_SESSION(
  p_processName   VARCHAR2, 
  p_groupName     VARCHAR2,
  p_logLevel      PLS_INTEGER, 
  p_daysToKeep    PLS_INTEGER, 
  p_TabNameMaster VARCHAR2 DEFAULT 'LILAM_LOG'
)
 ```
</details>

<details>
  <summary><b>3. Full Progress Mode</b> (With progress tracking)</summary>

```sql
FUNCTION NEW_SESSION(
  p_processName   VARCHAR2, 
  p_groupName     VARCHAR2,
  p_logLevel      PLS_INTEGER, 
  p_stepsToDo     PLS_INTEGER, 
  p_daysToKeep    PLS_INTEGER, 
  p_TabNameMaster VARCHAR2 DEFAULT 'LILAM_LOG'
)
 ```
</details>

<details>
  <summary><b>4. Connecting to selected server</b> (With progress tracking)</summary>

```sql
FUNCTION SERVER_NEW_SESSION(
  p_processName   VARCHAR2, 
  p_groupName     VARCHAR2,
  p_logLevel      PLS_INTEGER, 
  p_stepsToDo     PLS_INTEGER, 
  p_daysToKeep    PLS_INTEGER, 
  p_serverName    VARCHAR2,
  p_TabNameMaster VARCHAR2 DEFAULT 'LILAM_LOG'
)
 ```
</details>

<details>
  <summary><b>5. using a data-structure (record)</b> (Standard initialization)</summary>
  
  This variant uses the dedicated [`t_session_init` record](#record-type-t_session_init) for initializing the new session.
  
 ```sql
  FUNCTION NEW_SESSION(
    p_session_init t_session_init
  )
 ```
</details>

**Parameters**

| Parameter | Type | JSON | Description | Required
| --------- | ---- | --- | ----------- | -------
| p_processName | VARCHAR2| process_name | freely selectable name for identifying the process; is written to *master table* | [`M`](#m)
| p_groupName | VARCHAR2| group_name | used to get a dedicated server for the group | [`N`](#n)
| p_logLevel | PLS_INTEGER | log_level | determines the level of detail in *detail table* (see above) | [`M`](#m)
| p_stepsToDo | PLS_INTEGER | steps_todo | defines how many steps must be done during the process | [`O`](#o)
| p_daysToKeep | PLS_INTEGER | days_to_keep | max. age of entries in days; if not NULL, all entries older than p_daysToKeep and whose process name = p_processName (not case sensitive) are deleted | [`O`](#o)
| p_serverName | VARCHAR2 | server_name | Used for server affinity / multi-tenancy| [`O`](od)
| p_TabNameMaster | VARCHAR2 | tab_name_master | optional prefix of the PROC, LOG AND MON table names (see above) | [`D`](#d)

**Returns**
* Type: NUMBER
* Description: The new process ID; this ID is required for subsequent calls in order to be able to assign the LOG calls to the process

**Example**
```sql
DECLARE
  v_processId NUMBER;
BEGIN
  -- Using the "Retention" variant
  v_processId := NEW_SESSION('DATA_IMPORT', 2, 30);
END;
```

#### Procedure CLOSE_SESSION
Ends a logging session with optional final informations. Four function signatures are available for different scenarios.

**Signatures**

<details>
  <summary><b>1. No information about process</b> (Standard)</summary>
  
 ```sql
  PROCEDURE CLOSE_SESSION(
    p_processId     NUMBER
  )
 ```
</details>

<details>
  <summary><b>2. Update process info and process status</b> (Standard)</summary>
  
 ```sql
  PROCEDURE CLOSE_SESSION(
    p_processId     NUMBER,
    p_processInfo   VARCHAR2,
    p_processStatus PLS_INTEGER
  )
 ```
</details>

<details>
  <summary><b>3. Update process info and metric results</b> (Standard)</summary>
  
 ```sql
  PROCEDURE CLOSE_SESSION(
    p_processId     NUMBER,
    p_stepsDone     PLS_INTEGER,
    p_processInfo   VARCHAR2,
    p_processStatus PLS_INTEGER
  )
 ```
</details>

<details>
  <summary><b>4. Update complete process data and complete metric data</b> (Standard)</summary>
  
 ```sql
  PROCEDURE CLOSE_SESSION(
    p_processId     NUMBER,
    p_stepsToDo     PLS_INTEGER,
    p_stepsDone     PLS_INTEGER,
    p_processInfo   VARCHAR2,
    p_processStatus PLS_INTEGER
  )
 ```
</details>

**Parameters**

| Parameter | Type | JSON | Description | Required
| --------- | ---- | --- | ----------- | -------
| p_processId | NUMBER | process_id | ID of the process to which the session applies | [`M`](#m)
| p_stepsToDo | PLS_INTEGER | steps_todo | Number of work steps that would have been necessary for complete processing. This value must be managed by the calling package | [`N`](#n)
| p_stepsDone | PLS_INTEGER | steps_done | Number of work steps that were actually processed. This value must be managed by the calling package | [`N`](#n)
| p_processInfo | VARCHAR2 | process_info | Final information about the process (e.g., a readable status) | [`N`](#n)
| p_status | PLS_INTEGER | status | Final status of the process (freely selected by the calling package) | [`N`](#n)

> [!IMPORTANT]
> Since LILAM utilizes high-performance buffering, calling `CLOSE_SESSION` is essential to ensure that all remaining data is flushed and securely written to the database. To prevent data loss during an unexpected application crash, ensure that CLOSE_SESSION is part of your exception handling:
  
```sql
EXCEPTION WHEN OTHERS THEN
    -- Flushes buffered data and logs the error state before terminating
    lilam.close_session(
        p_process_id  => l_proc_id, 
        p_status      => -1,          -- Your custom error status code here
        p_processInfo => SQLERRM      -- Captures the Oracle error message
    );
    RAISE;
```

#### Procedure FINAL_RESCUE
For performance reasons, LILAM caches entries for logs, monitoring, and processes. This is possible because LILAM manages its memory and transactions independently of the calling package. To ensure that entries are written securely, a final [`CLOSE_SESSION`](#procedure-close_session) is required at the end of the process. Therefore, CLOSE_SESSION should also be called within the final exception handling of procedures or functions before the calling process terminates unexpectedly due to a fatal error.

Should one or even multiple abnormal process terminations occur, LILAM's non-persisted data can be written by calling the 'FINAL_RESCUE' procedure.
```sql
exec lilam.final_rescue;
```
Alternatively
```sql
BEGIN
  lilam.final_rescue;
END;
/
```
This call triggers the persistence of all currently cached data.
> [!IMPORTANT]
> Successful execution depends on calling the procedure from the specific session in which the crashed processes originated.

[↑ Back to Top](#lilam-api-reference)

---
### Process Control
Documents the lifecycle of a process.

| Name               | Type      | Description                         | Scope
| ------------------ | --------- | ----------------------------------- | -------
| [`SET_PROCESS_STATUS`](#procedure-set_process_status) | Procedure | Sets the state of the log status | Process
| [`SET_PROC_STEPS_TODO`](#procedure-set_steps_todo) | Procedure | Sets the required number of actions | Process
| [`STEP_DONE`](#procedure-step_done) | Procedure | Increments the counter of completed steps | Process
| [`SET_PROC_STEPS_DONE`](#procedure-set_steps_todo) | Procedure | Sets the number of completed actions | Process
| [`GET_PROC_STEPS_DONE`](fFunction-get_proc_steps_done) | FUNCTION | Returns number of already finished steps | Process
| [`GET_PROC_STEPS_TODO`](fFunction-get_proc_steps_done) | FUNCTION | Returns number of steps to do | Process
| [`GET_PROCESS_START`](#function-get_process_start) | FUNCTION | Returns time of process start | Process
| [`GET_PROCESS_END`](#function-get_process_end) | FUNCTION | Returns time of process end (if finished) | Process
| [`GET_PROCESS_STATUS`](#function-get_process_status) | FUNCTION | Returns the process state | Process
| [`GET_PROCESS_INFO`](#function-get_process_info) | FUNCTION | Returns info text about process | Process
| [`GET_PROCESS_DATA`](#function-get_process_data) | FUNCTION | Returns all process data as a record (see below) | Process 

**Procedures (Setter)**
  
#### Procedure SET_PROCESS_STATUS
The process status provides information about the overall state of the process. This integer value is not evaluated by LILAM; its meaning depends entirely on the specific application scenario.

 ```sql
  PROCEDURE SET_PROCESS_STATUS(
    p_processId     NUMBER,
    p_processStatus PLS_INTEGER
  )
 ```

#### Procedure SET_STEPS_TODO
This value specifies the planned number of work steps for the entire process. There is no correlation between this value and the actual number of actions recorded within the metrics.

 ```sql
  PROCEDURE SET_STEPS_TODO(
    p_processId     NUMBER,
    p_stepsToDo     PLS_INTEGER
  )

 ```

#### Procedure STEP_DONE
Increments the number of completed steps (progress). This simplifies the management of this value within the application.

 ```sql
  PROCEDURE STEP_DONE(
    p_processId     NUMBER
  )
 ```

#### Procedure SET_PROC_STEPS_DONE
Sets the total number of completed steps. Note: Calling this procedure overwrites any progress previously calculated via `STEP_DONE`.

 ```sql
  PROCEDURE SET_PROC_STEPS_DONE(
    p_processId     NUMBER,
    p_stepsDone     PLS_INTEGER
  )
 ```

> [!NOTE]
> Whenever a record in the master table is changed, the `last_update field` is updated implicitly. This mechanism is designed to support the monitoring features.

**Parameters**

| Parameter | Type | JSON | Description | Required
| --------- | ---- | --- | ----------- | -------
| p_processId | NUMBER | process_id | ID of the process to which the session applies | [`M`](#m)
| p_processStatus | PLS_INTEGER | process_status | information about the overall state of the process | [`O`](#o)
| p_stepsToDo | PLS_INTEGER | steps_todo | Number of work steps that would have been necessary for complete processing. This value must be managed by the calling package | [`N`](#n)
| p_stepsDone | PLS_INTEGER | steps_done | Number of work steps that were actually processed. This value must be managed by the calling package | [`N`](#n)
| p_processInfo | VARCHAR2 | process_info | Final information about the process (e.g., a readable status) | [`N`](#n)
| p_status | PLS_INTEGER | status | Final status of the process (freely selected by the calling package) | [`N`](#n)

**Functions (Getter)**

#### Function GET_PROC_STEPS_DONE
Retrieves the number of processed steps.

 ```sql
  FUNCTION GET_PROC_STEPS_DONE(
    p_processId     NUMBER
  )
 ```

**Returns**
* Type: PLS_INTEGER
* Description: Number of already processed steps (progress)

#### Function GET_PROC_STEPS_TODO
Retrieves the number of planned process steps. This value has nothing to do with metric actions.

 ```sql
  FUNCTION GET_PROC_STEPS_TODO(
    p_processId     NUMBER
  )
 ```

**Returns**
* Type: PLS_INTEGER
* Description: Number of planned steps

#### Function GET_PROCESS_START
Retrieves the time when the process was started with `NEW_SESSION`.

 ```sql
  FUNCTION GET_PROCESS_START(
    p_processId     NUMBER
  )
 ```

**Returns**
* Type: TIMESTAMP
* Description: This value cannot be changed by the API


#### Function GET_PROCESS_END
Retrieves the time when the process was finalized by `CLOSE_SESSION`.

 ```sql
  FUNCTION GET_PROCESS_END(
    p_processId     NUMBER
  )
 ```

**Returns**
* Type: TIMESTAMP
* Description: This value cannot be changed by the API

#### Function GET_PROCESS_STATUS
Reads the numerical status of a process. The status values are not part of the LILAM specification.

 ```sql
  FUNCTION GET_PROCESS_STATUS(
    p_processId     NUMBER
  )
 ```

**Returns**
* Type: Reord Type t_process_rec
* Description: Stores all known data of a process


#### Function GET_PROCESS_INFO
Reads the INFO-Text which is part of the process record. Likewise flexible and contingent on the specific application requirements. 

 ```sql
  FUNCTION GET_PROCESS_INFO(
    p_processId     NUMBER
  )
 ```

**Returns**
* Type: VARCHAR2
* Description: Any info text. 

#### Function GET_PROCESS_DATA
> [!NOTE]
> Every query for process data has an impact—albeit minor—on the overall system performance.
> If such queries occur only sporadically or if only a few attributes are needed (e.g., the number of completed process steps), this impact is negligible. However, if queries are called frequently and several of the functions mentioned above are used (e.g., `GET_PROCESS_INFO`, `GET_PROCESS_STATUS`, `GET_PROC_STEPS_DONE`, ...), it is recommended to request this information collectively.
> For this purpose, the function `GET_PROCESS_DATA` provides a record containing all relevant process data 'in one go': [#t_process_rec](#record-type-t_process_rec). This record serves as the exclusive way to retrieve the process name and the tab_name_master attribute. Following LILAMs naming convention, the detail table's name is deterministic: it always uses the master table's name as a prefix, followed by the suffix `_DETAIL`.

 ```sql
  FUNCTION GET_PROCESS_DATA(
    p_processId     NUMBER
  )
 ```

**Returns**
* Type: t_process_rec
* Description: Returns a record of type [`t_process_rec`](#record-type-t-process-rec) containing a complete snapshot of all process data in a single call. 

[↑ Back to Top](#lilam-api-reference)

---
### Logging
Likely the most intuitive methods for a developer...
In this regard, please also refer to the table [# Log Level](#log-level) in the appendix. It provides details on which severity levels are considered—and thus logged—at each activated log level.
For convenience, the configurable log levels are also declared as constants within the LILAM package. You can find them in the appendix under [# Declaration of Log Levels](#declaration-of-log-levels).

| Name               | Type      | Description                         | Scope
| ------------------ | --------- | ----------------------------------- | -------
| [`ERROR`](#procedure-error) | Procedure | Writes ERROR log entry | Logging
| [`WARN`](#procedure-warn) | Procedure | Writes WARN log entry  | Logging
| [`INFO`](#procedure-error) | Procedure | Writes INFO log entry  | Logging
| [`DEBUG`](#procedure-debug) | Procedure | Writes DEBUG log entry  | Logging

#### Procedure ERROR
Writes a log entry with severity ERROR. This is the lowest numerical value (highest priority). Independent of the activated log level, ERROR messages are always stored.

 ```sql
  PROCEDURE ERROR(
    p_processId     NUMBER,
    p_logText       VARCHAR2
  )
 ```

#### Procedure WARN
Writes Log with severity WARN.

 ```sql
  PROCEDURE WARN(
    p_processId     NUMBER,
    p_logText       VARCHAR2
  )
 ```

#### Procedure INFO
Writes Log with severity INFO.

 ```sql
  PROCEDURE INFO(
    p_processId     NUMBER,
    p_logText       VARCHAR2
  )
 ```
#### Procedure DEBUG
Writes a log entry with severity DEBUG. By default, LILAM operates 'silently,' meaning it does not raise exceptions to avoid disrupting the main process. However, when log level DEBUG is activated, caught exceptions will be re-thrown.

 ```sql
  PROCEDURE DEBUG(
    p_processId     NUMBER,
    p_logText       VARCHAR2
  )
 ```

**Parameters**

| Parameter | Type | API | Description | Required
| --------- | ---- | --- | ----------- | -------
| p_processId | NUMBER | process_id | ID of the process to which the session applies | [`M`](#m)
| p_logText   | VARCHAR2 | log_text | the log text | [`M`](#m)

[↑ Back to Top](#lilam-api-reference)

---
### Metrics
Metrics are quantifiable data points used to track the health and performance of a process. In LILAM, they document progress through two types of measurements:
1. Events: Discrete occurrences at a specific point in time.
2. Logical Transactions: Time-based segments (Traces) with a defined start and end.

**Identification of Metrics:**
The combination of p_actionName and p_contextName forms a unique identifier for a metric. Although p_contextName is optional, it must be provided consistently to match a specific trace.

> [!Important]: 'TRACK_SEGMENT' is not the same as 'TRACK_SEGMENT' + 'Moulin Rouge'. If a trace is started with a context, it must be stopped with that same context.

**Session Safety & Cleanup:**
To ensure data integrity, LILAM monitors the state of all traces. Any trace that remains "open" (not closed via trace_stop) when the session ends will be automatically logged with a WARN status. This allows developers to easily identify incomplete business transactions or logic errors.

    

| Name               | Type      | Description                         | Scope
| ------------------ | --------- | ----------------------------------- | -------
| [`MARK_EVENT`](#procedure-mark_event) | Procedure | Sets a metric action | Metrics
| [`TRACE_START`](#procedure-trace_start) | Procedure | Begins a business transaction | Metrics
| [`TRACE_STOP`](#procedure-trace_stop) | Procedure | Ends a business transaction | Metrics
| [`GET_METRIC_AVG_DURATION`](#function-get_metric_avg_duration) | Function | Returns average action time | Metrics
| [`GET_METRIC_STEPS`](#function-get_metric_steps) | Function | Returns the counter of action steps | Metrics


**Procedures (Setter)**


#### Procedure MARK_EVENT
Reports a completed work step, which typically represents an intermediate stage in the process lifecycle. For this reason, markers must not be confused with the actual process steps.
The MARK_STEP procedure reports a completed work step. Markers are distinguished by the `p_actionName` parameter. A process can contain any number of action names, enabling highly granular monitoring.
With every marker report, LILAM calculates:
* the time elapsed for this marker since the last report (except, of course, for the very first report of this action name),
* the total number of reports for this marker to date (simple increment),
* the average time consumed for all markers sharing the same `p_actionName`, and
* whether the time span between markers deviates significantly from the average.

 ```sql
  PROCEDURE MARK_EVENT(
    p_processId     NUMBER,
    p_actionName    VARCHAR2,
    p_contextName  VARCHAR2,
    p_timestamp     TIMESTAMP DEFAULT NULL
  )
 ```


#### Procedure TRACE_START
Starts a transaction trace. Traces represent a work step with a defined start and end. All traces must be completed with an end timestamp before the session closes. If any traces remain open at the end of a session, LILAM will automatically generate a warning in the Log Table.
LILAM measures the duration of each trace, maintains a moving average, and reports significant deviations as WARN entries in the Log Table.

 ```sql
  PROCEDURE TRACE_START
    p_processId     NUMBER,
    p_actionName    VARCHAR2,
    p_contextName  VARCHAR2,
    p_timestamp     TIMESTAMP DEFAULT NULL
  )
 ```

#### Procedure TRACE_STOP
Stops a transaction trace. The `p_action_name` and `p_context_name` must match the corresponding open trace. 

> [!Important]
> To ensure all open traces are validated and persisted, always call CLOSE_SESSION within your exception handler.
> This guarantees that even in the event of a failure, "dangling" traces are identified and recorded in the Log Table.

 ```sql
  PROCEDURE TRACE_START
    p_processId     NUMBER,
    p_actionName    VARCHAR2,
    p_contextName  VARCHAR2,
    p_timestamp     TIMESTAMP DEFAULT NULL
  )
 ```

**Functions (Getter)**

#### Function GET_METRIC_AVG_DURATION
Returns the average duration of markers, aggregated by their respective action names.

 ```sql
  FUNCTION GET_METRIC_AVG_DURATION(
    p_processId     NUMBER,
    p_actionName    VARCHAR2
  )
 ```

#### Function GET_METRIC_STEPS
Returns the number of markers, grouped by their respective action names.

 ```sql
  FUNCTION GET_METRIC_STEPS(
    p_processId     NUMBER,
    p_actionName    VARCHAR2
  )
 ```

**Parameters**

| Parameter | Type | JSON | Description | Required
| --------- | ---- | --- | ----------- | -------
| p_processId | NUMBER | process_id | ID of the process to which the session applies | [`M`](#m)
| p_actionName | VARCHAR2 | action_name | identifier of the action | [`M`](#m)
| p_contextName | VARCHAR2 | context_name | differentiates recurring actions within a session | [`M`](#m)


[↑ Back to Top](#lilam-api-reference)

---
### Server Control
In server mode, LILAM acts as a central service provider to deliver several key advantages:
* Centralized Logging & Monitoring: Consolidates all log data and metrics into a single, unified oversight layer.
* Targeted Orchestration: Manages jobs and data specifically tailored to horizontal or vertical organizational units (e.g., department-specific or multi-tenant environments).
* Asynchronous Decoupling: Decouples clients from synchronous database operations to improve application responsiveness and stability.
* Efficient Load Balancing: Optimizes resource distribution across the infrastructure to ensure high performance.
* Future-Proof Extensibility: Built-in foundation for upcoming features such as automated process chains, active messaging, and real-time alerting.

> [!IMPORTANT]
> A server is identified by its unique name, which also serves as the identifier for the underlying Oracle Pipe (`DBMS_PIPE`) used for communication. Therefore, server names must be unique within the database instance to prevent naming conflicts.

| Name               | Type      | Description                         | Scope
| ------------------ | --------- | ----------------------------------- | -------
| [`START_SERVER`](#procedure-start_server) | Procedure | Starts a LILAM-Server | Server control
| [`SERVER_SHUTDOWN`](#procedure-server_shutdown) | Procedure | Stops a LILAM-Server | Server control
| [`GET_SERVER_PIPE`](#function-get_server_pipe) | Function | Returns the servers communication pipe (`DBMS_PIPE`) | Server control

#### Function START_SERVER
Starts the LILAM server using a specific server (pipe) name. A password is required, which must be provided again when calling SERVER_SHUTDOWN. This security measure ensures that the shutdown cannot be triggered by unauthorized clients.

 ```sql
  Procedure START_SERVER(
    p_pipeName      VARCHAR2,
    p_groupName     VARCHAR2,
    p_password      VARCHAR2
  )
 ```

#### Procedure SERVER_SHUTDOWN
Shutting down a server requires that the executing client has previously logged into the server and knows the password provided during `SERVER_START`. The `p_processId` received by the client upon login must be used in this call.
The parameter p_pipeName is used by the server to secure that really he is addressed.

 ```sql
  FUNCTION SERVER_SHUTDOWN(
    p_processId     NUMBER,
    p_pipeName      VARCHAR2,
    p_password      VARCHAR2
  )
 ```

#### Function GET_SERVER_PIPE
Retrieves the server name (which also serves as the pipe name). Similar to SERVER_SHUTDOWN, the client must first connect to the server. The p_processId returned upon connection is then required for subsequent calls.

 ```sql
  FUNCTION GET_SERVER_PIPE(
    p_processId     NUMBER,
  )
 ```

#### PROCEDURE SERVER_UPDATE_RULES
The **LILAM Server** responds to signals based on predefined conditions. Supported events include process changes, marker events, and traced transactions. Rules are defined as JSON objects and persisted in the `LILAM_RULES` table.

The rule set can be updated dynamically using the `SERVER_UPDATE_RULES` procedure. After storing a new or modified rule set in `LILAM_RULES`, call this procedure to apply the changes.

Note that an active server connection (`NEW_SESSION`) is required. Upon execution, the server implements the new rule set and logs the rule set name and version to the `LILAM_SERVER__REGISTRY`.

 ```sql
  FUNCTION SERVER_UPDATE_RULES(
    p_processId      NUMBER,
    p_ruleSetName    VARCHAR2,
    p_ruleSetVersion PLS_INTEGER
  )
 ```

**Parameters**

| Parameter | Type | JSON | Description | Required
| --------- | ---- | --- | ----------- | -------
| p_processId | NUMBER | process_id | ID of the process to which the session applies | [`M`](#m)
| p_pipeName | VARCHAR2 | pipe_name | pipe name supported by server; no spaces allowed | [`M`](#m)
| p_password | VARCHAR2 | password | security for shutdown; | [`M`](#m)
| p_serverName | VARCHAR2 | server_name | servers identity; no spaces allowed | [`M`](#m)
| p_groupName | VARCHAR2 | group_name | group which server is dedicated to; no spaces allowed | [`N`](#n)
| p_ruleSetName | VARCHAR2 | rule_set_name | rules are organized within sets (see [architecture and concepts.md](./architecture%20and%20concepts.md)) | [`M`](#m)
| p_ruleSetVersion | PLS_INTEGER | rule_set_version | version of ruleset | [`M`](#m)

[↑ Back to Top](#lilam-api-reference)

---
## Appendix
### Log Level
Depending on the selected log level, additional information is written to the *detail table*.
        
To do this, the selected log level must be >= the level implied in the logging call.
* logLevelSilent  -> No details are written to the *detail table*
* logLevelError   -> Calls to the ERROR() procedure are taken into account
* logLevelWarn    -> Calls to the WARN() and ERROR() procedures are taken into account
* logLevelMonitor -> Must be set for using the monitoring features;
* logLevelInfo    -> Calls to the INFO(), WARN(), and ERROR() procedures are taken into account
* logLevelDebug   -> Calls to the DEBUG(), INFO(), WARN(), and ERROR() procedures are taken into account

If you want to suppress any logging, set logLevelSilent as active log level.

#### Declaration of Log Levels
To simplify usage and improve code readability, constants for the log levels are declared in the specification (lilam.pks).

```sql
logLevelSilent  constant PLS_INTEGER := 0;
logLevelError   constant PLS_INTEGER := 1;
logLevelWarn    constant PLS_INTEGER := 2;
logLevelMonitor constant PLS_INTEGER := 3;
logLevelInfo    constant PLS_INTEGER := 4;
logLevelDebug   constant PLS_INTEGER := 8;
```

### Record Type t_session_init
```sql
TYPE t_session_init IS RECORD (
    processName VARCHAR2(100),
    logLevel PLS_INTEGER := logLevelMonitor,
    stepsToDo PLS_INTEGER,
    daysToKeep PLS_INTEGER,
    procImmortal PLS_INTEGER,
    tabNameMaster VARCHAR2(100) DEFAULT 'LILAM_LOG'
);
```

### Record Type t_process_rec
Useful for getting a complete set of all process data. Using this record avoids multiple individual API calls.

```sql
TYPE t_process_rec IS RECORD (
    id                  NUMBER(19,0),
    process_name        VARCHAR2(100),
    log_level           PLS_INTEGER,
    process_start       TIMESTAMP,
    process_end         TIMESTAMP,
    process_last_update TIMESTAMP,
    proc_steps_todo     PLS_INTEGER,
    proc_steps_done     PLS_INTEGER,
    status              PLS_INTEGER,
    info                VARCHAR2(4000),
    tab_name_master     VARCHAR2(100)
);

```

### JSON API Interface
The JSON objects follow a fundamental structure.
> The header parameters version and client_id are currently not in use

For example, the JSON for calling the SERVER_NEW_SESSION API looks like this:

```json
{
  "header": {
    "version": "v1.x.x",
    "client_id": "GATE_15",
    "api_call": "SERVER_NEW_SESSION"
  },
  "params": {
    "process_name": "Your Process Name",
    "log_level": 3,
    "steps_todo": 100,
    "days_to_keep": 20,
    "tab_name_master": "GATES"
  }
}
```
