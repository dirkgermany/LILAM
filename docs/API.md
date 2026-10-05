# LILAM API Reference
### Version: 2.0

---

<details>
<summary>📖 <b>Content</b></summary>

- [Quick Start](#quick-start)
  - [In-Session Mode](#in-session-mode)
  - [Decoupled Server Mode](#decoupled-server-mode)
- [Core Concepts](#core-concepts)
  - [Process Progress vs. Metrics](#process-progress-vs-metrics)
  - [Events vs. Traces](#events-vs-traces)
- [Functions and Procedures](#functions-and-procedures)
  - [Session Handling](#session-handling)
  - [Process Control](#process-control)
  - [Logging](#logging)
  - [Metrics](#metrics)
  - [Server Control](#server-control)
  - [Dispatcher Mode](#dispatcher-mode)
- [Appendix](#appendix)
  - [Parameter Requirements](#parameter-requirements-1)
  - [Log Levels](#log-levels)
  - [Record Type t_session_init](#record-type-t_session_init)
  - [Record Type t_process_rec](#record-type-t_process_rec)
  - [Procedure IS_ALIVE](#procedure-is_alive)
  - [JSON API Interface](#json-api-interface)

</details>

> [!TIP]
> This document is the LILAM API reference. If you are new to LILAM, start with [architecture and concepts.md](architecture%20and%20concepts.md) for the underlying concepts. The examples in the `demo` folder show how the LILAM API can be integrated into applications.

---

## Quick Start

### In-Session Mode

Use in-session mode when logging and monitoring should be handled directly within the current database session.

The following example initializes LILAM, writes a log entry and records two occurrences of an event. With the default table prefix, LILAM uses these tables:

- `LILAM_PROC` for process data
- `LILAM_LOG` for log entries
- `LILAM_MON` for events and transaction metrics

```sql
DECLARE
  l_processId   NUMBER;
  l_sessionInit lilam.t_session_init;
BEGIN
  -- 1. Configure the session
  l_sessionInit.processName := 'MY_FIRST_SYNC';
  l_sessionInit.logLevel    := lilam.logLevelInfo; -- default: logLevelMonitor

  -- 2. Initialize LILAM
  l_processId := lilam.new_session(
    p_session_init => l_sessionInit
  );

  -- 3. Write a log entry
  lilam.info(
    p_processId => l_processId,
    p_logText   => 'LILAM is up and running!'
  );

  -- 4. Record an event twice
  lilam.mark_event(
    p_processId  => l_processId,
    p_actionName => 'DATA_LOAD'
  );

  dbms_session.sleep(1);

  lilam.mark_event(
    p_processId  => l_processId,
    p_actionName => 'DATA_LOAD'
  );

  -- 5. Finalize the session
  lilam.close_session(l_processId);
END;
/
```

> [!NOTE]
> LILAM uses autonomous transactions. Logging and monitoring data is therefore persisted independently of the calling application's main transaction, even if that transaction is rolled back.

### Decoupled Server Mode

Use decoupled mode when clients should send their logging and monitoring data to a LILAM server.

A server is identified by its pipe name and can optionally belong to a group. A client can either connect to any available server or restrict the server selection to a specific group.

#### Step 1: Start the Server

Start the server in a separate database session. `START_SERVER` blocks this session as long as the server is running. In production, `CREATE_SERVER` starts a server via `DBMS_SCHEDULER`.

```sql
BEGIN
  lilam.start_server(
    p_pipeName  => 'MY_FIRST_LILAM_SERVER',
    p_groupName => NULL,
    p_password  => 'SECURE PASSWORD'
  );
END;
/
```

#### Step 2: Run the Client

```sql
DECLARE
  l_processId NUMBER;
BEGIN
  -- Connect to an available server
  l_processId := lilam.server_new_session(
    p_processName => 'DECOUPLED_SYNC',
    p_logLevel    => lilam.logLevelInfo
  );

  lilam.info(
    p_processId => l_processId,
    p_logText   => 'LILAM initialized'
  );

  -- Discrete event
  lilam.mark_event(
    p_processId  => l_processId,
    p_actionName => 'DATA_LOAD'
  );

  -- Timed transaction
  lilam.trace_start(
    p_processId  => l_processId,
    p_actionName => 'NEXT_STATION'
  );

  dbms_session.sleep(1);

  lilam.trace_stop(
    p_processId  => l_processId,
    p_actionName => 'NEXT_STATION'
  );

  lilam.proc_step_done(p_processId => l_processId);

  -- Flush remaining buffered data
  lilam.close_session(l_processId);
END;
/
```

#### Step 3: Shut Down the Server

A client first has to connect to the server. The server pipe can then be determined with `GET_SERVER_PIPE` and passed to `SERVER_SHUTDOWN`.

```sql
DECLARE
  l_processId NUMBER;
  l_serverPipe VARCHAR2(100);
BEGIN
  l_processId := lilam.server_new_session(
    p_processName => 'SHUT DOWN SERVER',
    p_logLevel    => lilam.logLevelInfo
  );

  l_serverPipe := lilam.get_server_pipe(l_processId);

  lilam.server_shutdown(
    l_processId,
    l_serverPipe,
    'SECURE PASSWORD'
  );

  lilam.close_session(l_processId);
END;
/
```

---

## Core Concepts

### Process Progress vs. Metrics

> [!IMPORTANT]
> Process progress and metrics are independent concepts.

Use `SET_PROC_STEPS_TODO`, `PROC_STEP_DONE` and `SET_PROC_STEPS_DONE` to represent the overall progress of a process.

Use `MARK_EVENT`, `TRACE_START` and `TRACE_STOP` to record measurable activities within that process.

The number of process steps therefore does not have to match the number of metric events or traces.

### Events vs. Traces

A simple rule of thumb:

- **Something happened:** use `MARK_EVENT`.
- **Something starts and ends later:** use `TRACE_START` and `TRACE_STOP`.

A metric is identified by the combination of `p_actionName` and `p_contextName`.

If a trace is started with a context, it must be stopped with the same combination of action and context.

---

## Functions and Procedures

### Parameter Requirements

The following markers are used for parameters:

- **M**: Mandatory
- **O**: Optional
- **N**: Nullable
- **D**: Default value

---

## Session Handling

Session handling controls the life cycle of a LILAM process.

| API | Purpose |
| --- | --- |
| `NEW_SESSION` | Starts a LILAM process in in-session mode |
| `SERVER_NEW_SESSION` | Starts a process connected to a LILAM server |
| `CLOSE_SESSION` | Ends a process and writes buffered data |
| `FINAL_RESCUE` | Persists buffered data after abnormal process terminations |

### Function NEW_SESSION / SERVER_NEW_SESSION

Both functions start a LILAM process and return its process ID. This ID is required for all subsequent API calls.

- `NEW_SESSION` starts the process in in-session mode.
- `SERVER_NEW_SESSION` starts the process in decoupled mode via a LILAM server. The parameters are the same, with `p_groupName` added in second position.
- Alternatively, all settings can be combined in a [`t_session_init`](#record-type-t_session_init) record (`NEW_SESSION` only).

Each parameter always has the same position. All parameters except `p_processName` have a default and can therefore be omitted or passed by name.

```sql
FUNCTION NEW_SESSION(
  p_processName   VARCHAR2,
  p_logLevel      PLS_INTEGER DEFAULT logLevelMonitor,
  p_procStepsToDo PLS_INTEGER DEFAULT NULL,
  p_daysToKeep    PLS_INTEGER DEFAULT NULL,
  p_tabNameMaster VARCHAR2    DEFAULT 'LILAM',
  p_baselineScope VARCHAR2    DEFAULT NULL
) RETURN NUMBER
```

```sql
FUNCTION NEW_SESSION(
  p_session_init t_session_init
) RETURN NUMBER
```

```sql
FUNCTION SERVER_NEW_SESSION(
  p_processName   VARCHAR2,
  p_groupName     VARCHAR2    DEFAULT NULL,
  p_logLevel      PLS_INTEGER DEFAULT logLevelMonitor,
  p_procStepsToDo PLS_INTEGER DEFAULT NULL,
  p_daysToKeep    PLS_INTEGER DEFAULT NULL,
  p_tabNameMaster VARCHAR2    DEFAULT 'LILAM',
  p_baselineScope VARCHAR2    DEFAULT NULL
) RETURN NUMBER
```

```sql
FUNCTION SERVER_NEW_SESSION_JSON(
  p_jsonObject VARCHAR2
) RETURN NUMBER
```

`SERVER_NEW_SESSION_JSON` accepts the same parameters as a JSON object (keys see table).

#### Parameters

| Parameter | JSON | Default | Description |
| --- | --- | --- | --- |
| `p_processName` | `process_name` | – | Name identifying the process |
| `p_groupName` | `group_name` | `NULL` | `SERVER_NEW_SESSION` only: restricts the server selection to the given group; `NULL` = any available server |
| `p_logLevel` | `log_level` | `logLevelMonitor` | Level of detail, see [Log Levels](#log-levels) |
| `p_procStepsToDo` | `steps_todo` | `NULL` | Planned number of process steps |
| `p_daysToKeep` | `days_to_keep` | `NULL` | `NULL` = no automatic cleanup. Otherwise, completed processes of the same name older than the given number of days are deleted at startup, including their logs and metrics (except processes with `procImmortal = 1`) |
| `p_tabNameMaster` | `tabname_master` | `'LILAM'` | Prefix of the PROC, LOG and MON tables |
| `p_baselineScope` | `baseline_scope` | `NULL` | Scope of the averages (EWMA) of traces and events: `NULL` = process name, i.e. shared by all processes with this name; `'#NONE'` = only within the individual process; otherwise a freely chosen name that can also be shared by several applications |

**Return value:** `NUMBER`, the process ID.

If `SERVER_NEW_SESSION` cannot create a process, it raises **no exception** but returns a negative value. All further API calls with this ID are ignored without error; the application keeps running, only without logging and monitoring for this process. The cause is logged in `LILAM_LOG_INTERNAL`.

| Constant | Value | Meaning |
| --- | --- | --- |
| `NUM_ERR_SESSION_TIMEOUT` | -20110 | The server did not answer in time |
| `NUM_ERR_SESSION_THROTTLED` | -20120 | The server rejected the request (overload) |
| `NUM_COMM_ERR` | -20003 | Communication error, e.g. no active server found |

```sql
l_processId := lilam.server_new_session('IMPORT_CUSTOMERS', 'BATCH');
if l_processId < 0 then
  -- optional: own reaction, e.g. notify operations
  null;   -- l_processId = lilam.NUM_ERR_SESSION_TIMEOUT, ...
end if;
```

> [!NOTE]
> If the client waits for the answer in vain, the server will not create the process later either. The client passes an expiry time; if the request reaches the server only after that, it is discarded. This avoids orphaned processes that are never closed.

> [!NOTE]
> Thanks to the baseline scope, even an application that is restarted frequently builds a stable reference for its run times. The averages are stored in the tables `LILAM_SCOPES` and `LILAM_BASELINES`.

#### Examples

```sql
-- name only, all other values by default
l_processId := lilam.new_session('IMPORT_CUSTOMERS');

-- log level INFO and 500 planned steps
l_processId := lilam.new_session('IMPORT_CUSTOMERS', lilam.logLevelInfo, 500);

-- single parameters by name
l_processId := lilam.new_session('IMPORT_CUSTOMERS', p_daysToKeep => 30);
l_processId := lilam.new_session('IMPORT_CUSTOMERS', p_baselineScope => '#NONE');

-- decoupled: any available server or a server of the group BATCH
l_processId := lilam.server_new_session('IMPORT_CUSTOMERS');
l_processId := lilam.server_new_session('IMPORT_CUSTOMERS', 'BATCH', lilam.logLevelInfo);
```

### Procedure CLOSE_SESSION

Ends a LILAM process. Optionally, final process information, status and progress can be passed.

> [!IMPORTANT]
> Always call `CLOSE_SESSION` when a process ends. LILAM buffers data for performance reasons. `CLOSE_SESSION` makes sure that remaining buffered data is persisted.
>
> `CLOSE_SESSION` should therefore also be part of the final exception handling.

```sql
PROCEDURE CLOSE_SESSION(
  p_processId     NUMBER,
  p_processInfo   VARCHAR2    DEFAULT NULL,
  p_processStatus PLS_INTEGER DEFAULT NULL,
  p_procStepsDone PLS_INTEGER DEFAULT NULL,
  p_procStepsToDo PLS_INTEGER DEFAULT NULL
)
```

| Parameter | Description |
| --- | --- |
| `p_processId` | Process ID from `NEW_SESSION` or `SERVER_NEW_SESSION` |
| `p_processInfo` | Final information about the process |
| `p_processStatus` | Final status |
| `p_procStepsDone` | Number of completed steps |
| `p_procStepsToDo` | Number of planned steps |

Parameters left `NULL` do not change the current value of the process.

```sql
lilam.close_session(l_processId);
lilam.close_session(l_processId, 'Import finished', 1);
lilam.close_session(l_processId, 'Import finished', 1, 500);
```

Example for exception handling:

```sql
EXCEPTION
  WHEN OTHERS THEN
    lilam.close_session(
      p_processId     => l_proc_id,
      p_processInfo   => SQLERRM,
      p_processStatus => -1
    );
    RAISE;
```

### Procedure FINAL_RESCUE

For performance reasons, LILAM partly buffers logging, monitoring and process data.

`FINAL_RESCUE` persists all data currently buffered in the current database session.

```sql
BEGIN
  lilam.final_rescue;
END;
/
```

> [!IMPORTANT]
> `FINAL_RESCUE` must be called from the database session in which the affected processes were executed.

---

## Process Control

The process control APIs manage the overall progress and status of a process.

| API | Purpose |
| --- | --- |
| `SET_PROCESS_STATUS` | Updates the process status and optional process information |
| `SET_PROC_STEPS_TODO` | Sets the planned number of process steps |
| `PROC_STEP_DONE` | Increments the number of completed process steps |
| `SET_PROC_STEPS_DONE` | Sets the number of completed process steps explicitly |
| `GET_PROC_STEPS_DONE` | Returns the number of completed process steps |
| `GET_PROC_STEPS_TODO` | Returns the planned number of process steps |
| `GET_PROCESS_START` | Returns the start time of the process |
| `GET_PROCESS_END` | Returns the end time of the process |
| `GET_PROCESS_STATUS` | Returns the process status |
| `GET_PROCESS_INFO` | Returns the process information |
| `SET_PROC_IMMORTAL` | Protects a process from automatic cleanup |
| `GET_PROCESS_DATA` | Returns all process data in a record |
| `GET_PROCESS_DATA_JSON` | Returns all process data as JSON |

> [!NOTE]
> Changes to process data implicitly update the `lastUpdate` value of the process record.

### Procedure SET_PROCESS_STATUS

Updates the application-specific numeric process status and optionally the process information.

The meaning of the status value is not defined by LILAM but by the calling application.

```sql
PROCEDURE SET_PROCESS_STATUS(
  p_processId   NUMBER,
  p_status      PLS_INTEGER,
  p_processInfo VARCHAR2 DEFAULT NULL
)
```

### Procedure SET_PROC_STEPS_TODO

Sets the planned number of steps for the overall process.

```sql
PROCEDURE SET_PROC_STEPS_TODO(
  p_processId     NUMBER,
  p_procStepsToDo NUMBER
)
```

### Procedure PROC_STEP_DONE

Increments the number of completed process steps.

```sql
PROCEDURE PROC_STEP_DONE(
  p_processId NUMBER
)
```

### Procedure SET_PROC_STEPS_DONE

Sets the number of completed process steps explicitly.

A call overwrites a progress value previously built up with `PROC_STEP_DONE`.

```sql
PROCEDURE SET_PROC_STEPS_DONE(
  p_processId     NUMBER,
  p_procStepsDone NUMBER
)
```

### Procedure SET_PROC_IMMORTAL

Marks a process to be kept permanently (`1`) or removes the mark (`0`). Processes with `procImmortal = 1` are not deleted by the automatic cleanup via `p_daysToKeep`. The value can also be set at startup via `t_session_init.procImmortal`.

```sql
PROCEDURE SET_PROC_IMMORTAL(
  p_processId NUMBER,
  p_immortal  NUMBER
)
```

### Function GET_PROC_STEPS_DONE

```sql
FUNCTION GET_PROC_STEPS_DONE(
  p_processId NUMBER
) RETURN PLS_INTEGER
```

Returns the number of process steps already completed.

### Function GET_PROC_STEPS_TODO

```sql
FUNCTION GET_PROC_STEPS_TODO(
  p_processId NUMBER
) RETURN PLS_INTEGER
```

Returns the planned number of process steps.

### Function GET_PROCESS_START

```sql
FUNCTION GET_PROCESS_START(
  p_processId NUMBER
) RETURN TIMESTAMP
```

Returns the time at which the process was started by `NEW_SESSION` or `SERVER_NEW_SESSION`.

### Function GET_PROCESS_END

```sql
FUNCTION GET_PROCESS_END(
  p_processId NUMBER
) RETURN TIMESTAMP
```

Returns the time at which the process was ended by `CLOSE_SESSION`.

### Function GET_PROCESS_STATUS

```sql
FUNCTION GET_PROCESS_STATUS(
  p_processId NUMBER
) RETURN PLS_INTEGER
```

Returns the current application-specific numeric process status.

### Function GET_PROCESS_INFO

```sql
FUNCTION GET_PROCESS_INFO(
  p_processId NUMBER
) RETURN VARCHAR2
```

Returns the information text stored with the process.

### Function GET_PROCESS_DATA
Use this function when several properties of a process are needed at the same time.

This avoids several individual getter calls. The function returns a complete `t_process_rec` record.

```sql
FUNCTION GET_PROCESS_DATA(
  p_processId NUMBER
) RETURN t_process_rec
```

> [!NOTE]
> `GET_PROCESS_DATA` is also the documented way to retrieve the process name and `tabNameMaster` together with the other process attributes.
>
> The name of the process table is derived from the master table name by appending `_PROC`.

### Function GET_PROCESS_DATA_JSON

Returns the same data as `GET_PROCESS_DATA` as a JSON object with the keys `process_id`, `process_name`, `log_level`, `process_start`, `process_end`, `last_update`, `process_info`, `process_status`, `steps_todo`, `steps_done` and `tabname_master`.

```sql
FUNCTION GET_PROCESS_DATA_JSON(
  p_processId NUMBER
) RETURN VARCHAR2
```

---

## Logging
The logging APIs write messages to the LILAM log according to the active log level.

| API | Severity |
| --- | --- |
| `ERROR` | ERROR |
| `WARN` | WARN |
| `INFO` | INFO |
| `DEBUG` | DEBUG |

All logging procedures follow the same signature pattern:

```sql
PROCEDURE ERROR(
  p_processId NUMBER,
  p_logText   VARCHAR2
)

PROCEDURE WARN(
  p_processId NUMBER,
  p_logText   VARCHAR2
)

PROCEDURE INFO(
  p_processId NUMBER,
  p_logText   VARCHAR2
)

PROCEDURE DEBUG(
  p_processId NUMBER,
  p_logText   VARCHAR2
)
```

- `p_processId` identifies the process.
- `p_logText` contains the message. Longer texts are truncated to 1,900 characters (with multibyte characters such as umlauts possibly fewer, at most 2,000 bytes).

`ERROR` has the highest priority and is always stored unless logging has been switched off completely with `logLevelSilent`.

> [!IMPORTANT]
> **When an entry is in the table depends on the level and the mode.**
> - **In-Session:** `ERROR` is written and committed in an autonomous transaction before the call returns. LILAM also writes all other buffered data of the database session. `WARN`, `INFO` and `DEBUG` stay in the buffer for up to about 1.5 seconds, longer if the session does not call LILAM again.
> - **Decoupled:** `ERROR` also returns immediately. The server writes the message as soon as it reads it from the pipe (measured: 20–30 ms). If the LILAM server or the instance fails before that, the entry is lost.
> - If a session ends without `CLOSE_SESSION` or `FINAL_RESCUE`, the buffered entries are lost. Therefore call `CLOSE_SESSION` in the central exception handler.
>
> Details, measurements and failure scenarios are in [Architecture and Concepts](architecture%20and%20concepts.md#when-is-a-log-entry-stored-write-latency-per-level).

LILAM always handles internal errors silently and logs them in `LILAM_LOG_INTERNAL`; the application never receives an exception. If `logLevelDebug` is active, LILAM additionally writes such errors as `ERROR` to the log of the affected process.

The complete mapping can be found under [Log Levels](#log-levels).

### Function GET_COUNTER_WARN / GET_COUNTER_ERROR

```sql
FUNCTION GET_COUNTER_WARN(
  p_processId NUMBER
) RETURN PLS_INTEGER

FUNCTION GET_COUNTER_ERROR(
  p_processId NUMBER
) RETURN PLS_INTEGER
```

Return the number of calls of `WARN` and `ERROR` for the process since it was started.

> [!NOTE]
> Counting takes place in the database session that calls `WARN` or `ERROR` (in decoupled mode, i.e. on the client). For unknown or already closed processes, both functions return 0.

---

## Metrics

Metrics record events and logical transactions within a process.

> [!IMPORTANT]
> `p_actionName` and `p_contextName` together identify a metric.
>
> A trace started with a context must be stopped with the same combination of action and context.

### Procedure MARK_EVENT

Use `MARK_EVENT` for a single event at a specific point in time within the process flow.

For repeated markers with the same action and context, LILAM tracks the time interval, the number of occurrences, the average duration and significant deviations in time.

```sql
PROCEDURE MARK_EVENT(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL,
  p_timestamp   TIMESTAMP DEFAULT NULL
)
```

### Procedure TRACE_START

Starts a logical transaction whose duration is measured.

```sql
PROCEDURE TRACE_START(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL,
  p_timestamp   TIMESTAMP DEFAULT NULL
)
```

### Procedure TRACE_STOP

Ends the corresponding logical transaction.

```sql
PROCEDURE TRACE_STOP(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL,
  p_timestamp   TIMESTAMP DEFAULT NULL
)
```

> [!IMPORTANT]
> When the session ends, open traces are checked. A trace that was not completed is logged as a warning.
>
> Therefore also call `CLOSE_SESSION` in the final exception handling so that this check can take place.

### Function GET_METRIC_AVG_DURATION

Returns the average duration for the given metric.

```sql
FUNCTION GET_METRIC_AVG_DURATION(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL
) RETURN NUMBER
```

### Function GET_METRIC_STEPS
Returns the number of occurrences of the given metric.

```sql
FUNCTION GET_METRIC_STEPS(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL
) RETURN NUMBER
```

---

## Server Control
In decoupled mode, a LILAM server receives client requests and handles logging and monitoring centrally.

Servers are identified by their pipe names and can optionally be assigned to groups.

> [!IMPORTANT]
> Server pipe names must be unique within the database instance. Each server additionally creates a control pipe with the suffix `_CTL` (e.g. `LILAM_SRV1_CTL` for `LILAM_SRV1`); these names must not be used otherwise either.

A server uses two pipes:

- **Data pipe** (`<pipe name>`): all logs, traces, events, status changes and queries in the order of their arrival.
- **Control pipe** (`<pipe name>_CTL`): only the creation of new processes (`SERVER_NEW_SESSION`). The server checks it before every data message without waiting. Creating a process therefore does not have to wait behind the messages of other applications, even under high load. A short wake-up call into the data pipe makes sure that an idle server notices the request immediately.

| API | Purpose |
| --- | --- |
| `START_SERVER` | Starts a LILAM server in the current session |
| `CREATE_SERVER` | Starts a LILAM server via `DBMS_SCHEDULER` |
| `SERVER_SHUTDOWN` | Shuts down a server |
| `GET_SERVER_PIPE` | Returns the server pipe of a connected client |
| `SERVER_UPDATE_RULES` | Activates a rule set for a server group |
| `SET_DISPATCHER_PIPE` | Configures a dispatcher for automatic routing and reconnect |

### Procedure START_SERVER
Starts a LILAM server.

The password has to be given again when the server is shut down later.

```sql
PROCEDURE START_SERVER(
  p_pipeName     VARCHAR2,
  p_groupName    VARCHAR2,
  p_password     VARCHAR2,
  p_isDispatcher PLS_INTEGER DEFAULT 0,
  p_perfServer   PLS_INTEGER DEFAULT NULL
)
```

#### Parameters
| Parameter | Type | Meaning |
| --------- | --- | --------- |
| p_pipeName | varchar2 | Unique pipe name of the server |
| p_groupName | varchar2 | Optional group for server selection |
| p_password | varchar2 | Password required again for SERVER_SHUTDOWN |
| p_isDispatcher | pls_integer | 1 starts the server in dispatcher mode (see Dispatcher Mode), 0 (default) starts a regular server |
| p_perfServer | pls_integer | Performance level of the server, see [Performance Level](#performance-level-p_perfserver). `NULL` (default) = `C_SERVER_PERF_MID` |

#### Performance Level (p_perfServer)
To keep a client from flooding the server with messages, the client briefly synchronizes with the server after a certain number of messages per process and second and waits until the server has caught up. `p_perfServer` sets this limit. The server passes it to the client with `SERVER_NEW_SESSION` (and on automatic reconnect); no extra call is needed in the application.

| Constant | Value | Use |
| --- | --- | --- |
| `C_SERVER_PERF_LOW` | 500 | Less powerful environments |
| `C_SERVER_PERF_MID` | 1500 | Default; typical servers |
| `C_SERVER_PERF_HIGH` | 2500 | Powerful servers |

Any other value is allowed. `0` disables the synchronization; `NULL` or negative values count as `C_SERVER_PERF_MID`.

> [!NOTE]
> The limit applies per process. If many applications send to the same server at the same time, its total throughput is lower than the sum of the individual values; then rather choose `C_SERVER_PERF_LOW` or `C_SERVER_PERF_MID`, or start further servers of the same group.

### Function CREATE_SERVER
Starts a LILAM server via `DBMS_SCHEDULER` and returns server information as `VARCHAR2`.

```sql
FUNCTION CREATE_SERVER(
  p_pipeName     VARCHAR2,
  p_groupName    VARCHAR2,
  p_password     VARCHAR2,
  p_isDispatcher PLS_INTEGER DEFAULT 0,
  p_perfServer   PLS_INTEGER DEFAULT NULL
) RETURN VARCHAR2
```
Parameters identical to START_SERVER.

```sql
-- Example: server of the group BATCH with medium performance level
dbms_output.put_line(lilam.create_server('LILAM_SRV1', 'BATCH', 'secret', p_perfServer => lilam.C_SERVER_PERF_MID));
```

### Procedure SERVER_SHUTDOWN
The client must already be connected to the server.

Shutting down requires the process ID, the server pipe and the password given at server start.

```sql
PROCEDURE SERVER_SHUTDOWN(
  p_processId NUMBER,
  p_pipeName  VARCHAR2,
  p_password  VARCHAR2
)
```

### Function GET_SERVER_PIPE
Returns the server pipe associated with the connected client process.

```sql
FUNCTION GET_SERVER_PIPE(
  p_processId NUMBER
) RETURN VARCHAR2
```

### Procedure SERVER_UPDATE_RULES
Rule sets are stored as JSON objects in `LILAM_RULES`, each for a server group (`GROUP_NAME`, name, version). The same rule set can be stored for several groups. Exactly one rule set per group is active (`IS_ACTIVE = 1`); it applies to all servers of the group.

```sql
PROCEDURE SERVER_UPDATE_RULES(
  p_groupName      VARCHAR2,
  p_ruleSetName    VARCHAR2,
  p_ruleSetVersion PLS_INTEGER
)
```

Steps:
1. The rule set of the group is checked completely in the calling session. If it is missing for the group or a rule is invalid, the call ends with the exception `NUM_ERR_RULE_SET` (-20130) and a reason; nothing is changed.
2. The rule set becomes active for the group, the previously active one inactive.
3. Running servers of the group receive the instruction to reload directly in their pipe, so no running process is needed and the dispatcher is bypassed. Dispatchers do not evaluate rules.

A group without running servers is not an error: every server loads the active rule set of its group at startup, including a newly added one. If a server rejects a rule set at startup (e.g. because it was changed directly in the table in the meantime), it keeps its previous rules (at startup: none) and logs the reason to `LILAM_LOG_INTERNAL` and to the log of the server process.

```sql
INSERT INTO LILAM_RULES (group_name, set_name, version, created, author, rule_set)
VALUES ('METRO', 'METRO_RULES', 2, systimestamp, 'Dirk', '{"rules":[ ... ]}');

exec LILAM.SERVER_UPDATE_RULES('METRO', 'METRO_RULES', 2);
```

Rules are evaluated by servers only, not in in-session mode. Structure of rule sets and operators: [Rules Engine](../rules/README.md).

## Dispatcher Mode
A server started with p_isDispatcher => 1 (dispatcher) does not process requests itself but forwards them unchanged to a suitable server.

For NEW_SESSION/SERVER_NEW_SESSION, the dispatcher uses the same load-based mechanism as the regular server selection and forwards the request to the control pipe of the selected server;
for all other requests, it determines the server responsible for the application's process from the already assigned process_id and forwards the request there.

The answer of the responsible server goes directly back to the client, not via the dispatcher.

A dispatcher is marked in the server registry (`IS_DISPATCHER = 1`) and is never chosen as a target of the server selection. Workers and dispatchers can therefore run in the same group: clients without dispatcher configuration always get a worker directly.

> [!TIP]
> A dispatcher is mainly relevant for applications that do not keep their physical database connection permanently – typically Oracle APEX applications with connection pooling.
> A follow-up page may then run in a different physical session than the page that originally started the process.
> A configured dispatcher allows LILAM to restore the connection to the responsible worker automatically in this case, without the application having to control this itself.

Applications with a permanent database session (classic in-session or decoupled operation without connection pooling) do not need a dispatcher.

### Automatic Reconnect
If a dispatcher is configured, LILAM automatically and transparently tries to restore a connection via the dispatcher for every API call with a process_id unknown to the current physical session.
If this fails (no dispatcher configured, dispatcher not reachable, or the process no longer exists), the call behaves like any other call with an unknown process_id: it is ignored without an error message.

The following applies:

- No reconnect is attempted for negative process_ids (e.g. `NUM_ERR_SESSION_TIMEOUT`).
- If the dispatcher finds no responsible server, it answers immediately with an error; the application does not wait.
- A failed reconnect is remembered for the physical session: if the server does not know the process (e.g. after `CLOSE_SESSION`), further calls with this process_id are ignored without a new request. For temporary disturbances (dispatcher not reachable), the next attempt is made after 10 seconds at the earliest.

### Prewarming
The automatic reconnect attempt costs a one-time pipe round trip. Without prewarming, the first API call after a session change carries this additional latency.
If p_processId is passed, this round trip already takes place when SET_DISPATCHER_PIPE is called – typically while the page is rendered, before the application reacts.

### Procedure SET_DISPATCHER_PIPE
Tells LILAM via which pipe a dispatcher can be reached. This information is kept exclusively in the memory of the current physical database session.

> [!IMPORTANT]
> Since the configuration only applies to the current physical session, SET_DISPATCHER_PIPE must be called again for every new connection – with connection pooling potentially on every page, not just once on the first page call.


```sql
PROCEDURE SET_DISPATCHER_PIPE(
  p_pipeName  VARCHAR2,
  p_groupName VARCHAR2 DEFAULT 'DEFAULT_DISPATCHER',
  p_processId NUMBER   DEFAULT NULL
)
```

#### Parameters
| Parameter | Type | Meaning |
| --------- | --- | --------- |
| p_pipeName | varchar2 | Pipe name of the dispatcher |
| p_groupName | varchar2 | Optional identifier if several dispatchers are used in parallel. [Automatic Reconnect](#automatic-reconnect) only uses the default identifier 'DEFAULT_DISPATCHER' |
| p_processId | number | Optional. If a process_id is already known, LILAM restores the connection to it immediately (see [Prewarming](#prewarming)) instead of at the next API call |

```sql
-- Example: APEX "Before Header" process
BEGIN
  lilam.set_dispatcher_pipe(
    p_pipeName  => 'LILAM_DISPATCHER_SALES',
    p_processId => :G_LILAM_PROCESS_ID  -- NULL on the very first page call
  );
END;
/
```
---

## Appendix

### Parameter Requirements

| Marker | Meaning |
| --- | --- |
| M | Mandatory |
| O | Optional |
| N | Nullable |
| D | Default value |

### Log Levels

The active log level determines which log messages are written.

| Level | Value | Behavior |
| --- | ---: | --- |
| `logLevelSilent` | 0 | No log details |
| `logLevelError` | 1 | ERROR |
| `logLevelWarn` | 2 | WARN and ERROR |
| `logLevelMonitor` | 3 | Enables the monitoring functions |
| `logLevelInfo` | 4 | INFO, WARN and ERROR |
| `logLevelDebug` | 8 | DEBUG, INFO, WARN and ERROR |

```sql
logLevelSilent  CONSTANT PLS_INTEGER := 0;
logLevelError   CONSTANT PLS_INTEGER := 1;
logLevelWarn    CONSTANT PLS_INTEGER := 2;
logLevelMonitor CONSTANT PLS_INTEGER := 3;
logLevelInfo    CONSTANT PLS_INTEGER := 4;
logLevelDebug   CONSTANT PLS_INTEGER := 8;
```

### Record Type t_session_init

Use `t_session_init` to combine the initialization settings and pass them to the record-based `NEW_SESSION` overload.

```sql
TYPE t_session_init IS RECORD (
  processName   VARCHAR2(100),
  logLevel      PLS_INTEGER := logLevelMonitor,
  stepsToDo     PLS_INTEGER,
  daysToKeep    PLS_INTEGER,                    -- NULL = no automatic cleanup
  procImmortal  PLS_INTEGER := 0,
  tabNameMaster VARCHAR2(100) DEFAULT 'LILAM',
  baselineScope VARCHAR2(100)                   -- NULL = process name, '#NONE' = per process only
);
```

### Record Type t_process_rec

`t_process_rec` contains the process data returned by `GET_PROCESS_DATA`.

```sql
TYPE t_process_rec IS RECORD (
  id            NUMBER(19,0),
  processName   VARCHAR2(100),
  logLevel      PLS_INTEGER,
  processStart  TIMESTAMP,
  processEnd    TIMESTAMP,
  lastUpdate    TIMESTAMP,
  stepsTodo     PLS_INTEGER,
  stepsDone     PLS_INTEGER,
  status        PLS_INTEGER,
  info          VARCHAR2(4000),
  procImmortal  PLS_INTEGER := 0,
  tabNameMaster VARCHAR2(100)
);
```

### Procedure IS_ALIVE

Simple function test after installation: creates the process `LILAM Life Check` in in-session mode, writes a DEBUG entry and closes the process. On the first call LILAM creates its tables; missing privileges therefore show up immediately (entries in `LILAM_LOG_INTERNAL`).

```sql
exec lilam.is_alive;
```

### JSON API Interface

With `CALL_BY_JSON`, the most important API calls can be passed as JSON, e.g. from applications that create JSON more easily than PL/SQL calls.

```sql
PROCEDURE CALL_BY_JSON(
  p_callObject IN  VARCHAR2,      -- JSON_OBJ_LILAM
  p_respObject OUT VARCHAR2
)

PROCEDURE CALL_BY_JSON(
  p_callObject IN  JSON_OBJECT_T,
  p_respObject OUT JSON_OBJECT_T
)
```

LILAM JSON requests consist of a header and a parameter object. The header contains the call in `api_call`; the header parameters `version` and `client_id` are currently not used.

| `api_call` | corresponds to | Parameters (`params`) |
| --- | --- | --- |
| `NEW_SESSION` | `NEW_SESSION` (record) | `process_name`, `log_level`, `steps_todo`, `days_to_keep`, `process_immortal`, `tabname_master`, `baseline_scope` |
| `SERVER_NEW_SESSION` | `SERVER_NEW_SESSION_JSON` | as `SERVER_NEW_SESSION`, see table there |
| `CLOSE_SESSION` | `CLOSE_SESSION` | `process_id` |
| `SET_PROCESS_STATUS` | `SET_PROCESS_STATUS` | `process_id`, `process_status`, `process_info` |
| `SET_STEP_TODO` | `SET_PROC_STEPS_TODO` | `process_id`, `steps_todo` |
| `SET_STEPS_DONE` | `SET_PROC_STEPS_DONE` | `process_id`, `steps_done` |
| `PROC_STEP_DONE` | `PROC_STEP_DONE` | `process_id` |
| `SET_PROC_IMMORTAL` | `SET_PROC_IMMORTAL` | `process_id`, `process_immortal` |
| `INFO`, `DEBUG`, `WARN`, `ERROR` | Logging | `process_id`, `process_info` (log text) |
| `MARK_EVENT`, `TRACE_START`, `TRACE_STOP` | Metrics | `process_id`, `action_name`, `context_name`, `timestamp` |
| `SERVER_SHUTDOWN` | `SERVER_SHUTDOWN` | `process_id`, `pipe_name`, `password` |

The answer contains the header of the request, `status` (`SUCCESS` or `ERROR`) and a `payload` with `returns` and `value`, e.g. `"returns": "PROCESS_ID", "value": 4711`. For an unknown `api_call`, `value` is `NUM_ERR_ILLEGAL_REQ` (-20010). If `p_callObject` is not valid JSON, the call ends with the exception -20005.

Example for `SERVER_NEW_SESSION`:

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
    "tabname_master": "GATES"
  }
}
```
