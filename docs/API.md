# LILAM API Reference
### Version: 1.7

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
- [Appendix](#appendix)
  - [Parameter Requirements](#parameter-requirements)
  - [Log Levels](#log-levels)
  - [Record Type t_session_init](#record-type-t_session_init)
  - [Record Type t_process_rec](#record-type-t_process_rec)
  - [JSON API Interface](#json-api-interface)

</details>

> [!TIP]
> This document is the LILAM API reference. If you are new to LILAM, start with [architecture and concepts.md](architecture%20and%20concepts.md) for the underlying concepts. The examples in the `demo` folder show how the API can be integrated into applications.

---

## Quick Start

### In-Session Mode

Use in-session mode when logging and monitoring should be handled directly within the current database session.

The following example initializes LILAM, writes a log entry, and records two occurrences of an event. With the default table prefix, LILAM uses these tables:

- `LILAM_PROC` for process data
- `LILAM_LOG` for log entries
- `LILAM_MON` for events and transaction metrics

```sql
DECLARE
  l_processId   NUMBER;
  l_sessionInit t_session_init;
BEGIN
  -- 1. Configure the session
  l_sessionInit.processName := 'MY_FIRST_SYNC';
  l_sessionInit.logLevel    := logLevelInfo; -- default: logLevelMonitor

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
> LILAM uses autonomous transactions. Logging and monitoring data is therefore persisted independently of the caller's main transaction, including when that transaction is rolled back.

### Decoupled Server Mode

Use decoupled mode when clients should send logging and monitoring data to a LILAM server.

A server is identified by its pipe name and can optionally belong to a group. A client can connect either to an available server or restrict server selection to a specific group.

#### Step 1: Start the server

Start the server in a dedicated database session. `START_SERVER` blocks that session while the server is running. In production, `CREATE_SERVER` can be used to start a server through `DBMS_SCHEDULER`.

```sql
BEGIN
  lilam.start_server(
    'MY_FIRST_LILAM_SERVER',
    NULL,
    'SECURE PASSWORD'
  );
END;
/
```

#### Step 2: Run a client

```sql
DECLARE
  l_processId NUMBER;
BEGIN
  -- Connect to an available server
  l_processId := lilam.server_new_session(
    'DECOUPLED_SYNC',
    lilam.logLevelInfo,
    0,
    100,
    'LILAM'
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

#### Step 3: Shut down the server

A client must first establish a server session. The server pipe associated with that session can then be obtained with `GET_SERVER_PIPE` and passed to `SERVER_SHUTDOWN`.

```sql
DECLARE
  l_processId NUMBER;
  l_serverPipe VARCHAR2(100);
BEGIN
  l_processId := lilam.server_new_session(
    'SHUT DOWN SERVER',
    lilam.logLevelInfo,
    0,
    100,
    'LILAM'
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

Use `SET_PROC_STEPS_TODO`, `PROC_STEP_DONE`, and `SET_PROC_STEPS_DONE` to describe the overall progress of a process.

Use `MARK_EVENT`, `TRACE_START`, and `TRACE_STOP` to record measurable activities within that process. The number of process steps does not have to correspond to the number of metric events or traces.

### Events vs. Traces

A simple rule of thumb:

- **Something happened:** use `MARK_EVENT`.
- **Something started and later finished:** use `TRACE_START` and `TRACE_STOP`.

A metric is identified by the combination of `p_actionName` and `p_contextName`. If a trace is started with a context, it must be stopped using the same action and context.

---

## Functions and Procedures

### Parameter Requirements

The following markers are used in parameter descriptions:

- **M**: Mandatory
- **O**: Optional
- **N**: Nullable
- **D**: Has a default value

---

## Session Handling

Session handling controls the lifecycle of a LILAM process.

| API | Purpose |
| --- | --- |
| `NEW_SESSION` | Starts an in-session LILAM process |
| `SERVER_NEW_SESSION` | Starts a process connected to a LILAM server |
| `CLOSE_SESSION` | Finalizes a process and flushes buffered data |
| `FINAL_RESCUE` | Persists cached data after abnormal process termination |

### Function NEW_SESSION / SERVER_NEW_SESSION

Both functions start a LILAM process and return its process ID. That ID is required by subsequent API calls.

#### Which variant should I use?

- Use the `t_session_init` variant when you want initialization settings collected in a readable record.
- Use a short `NEW_SESSION` overload when only a few settings are required.
- Use `SERVER_NEW_SESSION` for decoupled operation.
- Use the group overload of `SERVER_NEW_SESSION` when server selection should be restricted to a specific group.

#### NEW_SESSION: Basic Mode

```sql
FUNCTION NEW_SESSION(
  p_processName   VARCHAR2,
  p_logLevel      PLS_INTEGER DEFAULT logLevelMonitor,
  p_tabNameMaster VARCHAR2 DEFAULT 'LILAM'
) RETURN NUMBER
```

#### NEW_SESSION: Retention Mode

```sql
FUNCTION NEW_SESSION(
  p_processName   VARCHAR2,
  p_logLevel      PLS_INTEGER,
  p_daysToKeep    PLS_INTEGER,
  p_tabNameMaster VARCHAR2 DEFAULT 'LILAM'
) RETURN NUMBER
```

#### NEW_SESSION: Full Progress Mode

```sql
FUNCTION NEW_SESSION(
  p_processName   VARCHAR2,
  p_logLevel      PLS_INTEGER,
  p_procStepsToDo PLS_INTEGER,
  p_daysToKeep    PLS_INTEGER,
  p_tabNameMaster VARCHAR2 DEFAULT 'LILAM'
) RETURN NUMBER
```

#### NEW_SESSION: Record-Based Initialization

```sql
FUNCTION NEW_SESSION(
  p_session_init t_session_init
) RETURN NUMBER
```

#### SERVER_NEW_SESSION: Any Available Server

```sql
FUNCTION SERVER_NEW_SESSION(
  p_processName   VARCHAR2,
  p_logLevel      PLS_INTEGER,
  p_procStepsToDo PLS_INTEGER,
  p_daysToKeep    PLS_INTEGER,
  p_tabNameMaster VARCHAR2
) RETURN NUMBER
```

#### SERVER_NEW_SESSION: Server from a Specific Group

```sql
FUNCTION SERVER_NEW_SESSION(
  p_processName   VARCHAR2,
  p_groupName     VARCHAR2,
  p_logLevel      PLS_INTEGER,
  p_procStepsToDo PLS_INTEGER,
  p_daysToKeep    PLS_INTEGER,
  p_tabNameMaster VARCHAR2
) RETURN NUMBER
```

#### Parameters

| Parameter | JSON | Description |
| --- | --- | --- |
| `p_processName` | `process_name` | Name used to identify the process |
| `p_groupName` | `group_name` | Restricts server selection to the specified group |
| `p_logLevel` | `log_level` | Controls logging detail |
| `p_procStepsToDo` | `steps_todo` | Planned number of process steps |
| `p_daysToKeep` | `days_to_keep` | Maximum age of matching process data before cleanup |
| `p_tabNameMaster` | `tab_name_master` | Prefix used for the PROC, LOG, and MON table names |

**Returns:** `NUMBER`, the process ID.

### Procedure CLOSE_SESSION

Finalizes a LILAM process. Depending on the overload, final process information, progress, and status can be supplied.

> [!IMPORTANT]
> Always call `CLOSE_SESSION` when processing ends. LILAM buffers data for performance, and `CLOSE_SESSION` ensures remaining buffered data is persisted. It should therefore also be called from final exception handling.

```sql
PROCEDURE CLOSE_SESSION(
  p_processId NUMBER
)
```

```sql
PROCEDURE CLOSE_SESSION(
  p_processId   NUMBER,
  p_processInfo VARCHAR2,
  p_status      PLS_INTEGER
)
```

```sql
PROCEDURE CLOSE_SESSION(
  p_processId      NUMBER,
  p_procStepsDone  NUMBER,
  p_processInfo    VARCHAR2,
  p_processStatus  PLS_INTEGER
)
```

```sql
PROCEDURE CLOSE_SESSION(
  p_processId      NUMBER,
  p_procStepsToDo  NUMBER,
  p_procStepsDone  NUMBER,
  p_processInfo    VARCHAR2,
  p_processStatus  PLS_INTEGER
)
```

Example exception handling:

```sql
EXCEPTION
  WHEN OTHERS THEN
    lilam.close_session(
      p_processId   => l_proc_id,
      p_processInfo => SQLERRM,
      p_status      => -1
    );
    RAISE;
```

### Procedure FINAL_RESCUE

LILAM caches logging, monitoring, and process entries for performance. `FINAL_RESCUE` persists all currently cached data in the current database session.

```sql
BEGIN
  lilam.final_rescue;
END;
/
```

> [!IMPORTANT]
> `FINAL_RESCUE` must be called from the database session in which the affected processes originated.

---

## Process Control

Process-control APIs manage overall process progress and status.

| API | Purpose |
| --- | --- |
| `SET_PROCESS_STATUS` | Updates process status and optional information |
| `SET_PROC_STEPS_TODO` | Sets the planned number of process steps |
| `PROC_STEP_DONE` | Increments completed process steps |
| `SET_PROC_STEPS_DONE` | Sets completed process steps explicitly |
| `GET_PROC_STEPS_DONE` | Returns completed process steps |
| `GET_PROC_STEPS_TODO` | Returns planned process steps |
| `GET_PROCESS_START` | Returns process start time |
| `GET_PROCESS_END` | Returns process end time |
| `GET_PROCESS_STATUS` | Returns process status |
| `GET_PROCESS_INFO` | Returns process information |
| `GET_PROCESS_DATA` | Returns all process data as one record |

> [!NOTE]
> Whenever process data is changed, the process record's `lastUpdate` value is updated implicitly.

### Procedure SET_PROCESS_STATUS

Updates the application-defined numerical process status and, optionally, process information. LILAM does not assign application-specific meaning to the status value.

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

Explicitly sets the number of completed process steps. This overwrites progress previously accumulated through `PROC_STEP_DONE`.

```sql
PROCEDURE SET_PROC_STEPS_DONE(
  p_processId     NUMBER,
  p_procStepsDone NUMBER
)
```

### Function GET_PROC_STEPS_DONE

```sql
FUNCTION GET_PROC_STEPS_DONE(
  p_processId NUMBER
) RETURN PLS_INTEGER
```

Returns the number of completed process steps.

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

Returns the timestamp at which the process was started by `NEW_SESSION` or `SERVER_NEW_SESSION`.

### Function GET_PROCESS_END

```sql
FUNCTION GET_PROCESS_END(
  p_processId NUMBER
) RETURN TIMESTAMP
```

Returns the timestamp at which the process was finalized by `CLOSE_SESSION`.

### Function GET_PROCESS_STATUS

```sql
FUNCTION GET_PROCESS_STATUS(
  p_processId NUMBER
) RETURN PLS_INTEGER
```

Returns the current application-defined numerical process status.

### Function GET_PROCESS_INFO

```sql
FUNCTION GET_PROCESS_INFO(
  p_processId NUMBER
) RETURN VARCHAR2
```

Returns the information text stored with the process.

### Function GET_PROCESS_DATA

Use this function when several process properties are required at once. It avoids multiple individual getter calls and returns a complete `t_process_rec` record.

```sql
FUNCTION GET_PROCESS_DATA(
  p_processId NUMBER
) RETURN t_process_rec
```

> [!NOTE]
> `GET_PROCESS_DATA` is also the documented way to retrieve the process name and `tabNameMaster` together with the other process attributes. The process table name is derived from the master table name by appending `_PROC`.

---

## Logging

Logging APIs write messages to the LILAM log according to the active log level.

| API | Severity |
| --- | --- |
| `ERROR` | ERROR |
| `WARN` | WARN |
| `INFO` | INFO |
| `DEBUG` | DEBUG |

All logging procedures use the same signature pattern:

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
- `p_logText` contains the message.

`ERROR` has the highest priority and is always stored unless logging is completely disabled with `logLevelSilent`.

When `logLevelDebug` is active, caught LILAM exceptions are re-thrown rather than silently absorbed.

See [Log Levels](#log-levels) for the complete mapping.

---

## Metrics

Metrics record events and logical transactions within a process.

> [!IMPORTANT]
> `p_actionName` and `p_contextName` together identify a metric. A trace started with a context must be stopped with the same action and context.

### Procedure MARK_EVENT

Use `MARK_EVENT` for a discrete occurrence at a point in the process.

For repeated markers sharing an action and context, LILAM tracks elapsed time, occurrence count, average duration, and significant timing deviations.

```sql
PROCEDURE MARK_EVENT(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL,
  p_timestamp   TIMESTAMP DEFAULT NULL
)
```

### Procedure TRACE_START

Starts a timed logical transaction.

```sql
PROCEDURE TRACE_START(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL,
  p_timestamp   TIMESTAMP DEFAULT NULL
)
```

### Procedure TRACE_STOP

Stops a matching logical transaction.

```sql
PROCEDURE TRACE_STOP(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL,
  p_timestamp   TIMESTAMP DEFAULT NULL
)
```

> [!IMPORTANT]
> Open traces are checked when the session closes. A trace that remains open is recorded as a warning. Call `CLOSE_SESSION` from final exception handling so that this validation can take place.

### Function GET_METRIC_AVG_DURATION

Returns the average duration for the specified metric.

```sql
FUNCTION GET_METRIC_AVG_DURATION(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL
) RETURN NUMBER
```

### Function GET_METRIC_STEPS

Returns the occurrence count for the specified metric.

```sql
FUNCTION GET_METRIC_STEPS(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL
) RETURN NUMBER
```

---

## Server Control

In decoupled mode, a LILAM server receives client requests and handles logging and monitoring centrally. Servers are identified by their pipe names and may optionally be assigned to groups.

> [!IMPORTANT]
> Server pipe names must be unique within the database instance.

| API | Purpose |
| --- | --- |
| `START_SERVER` | Starts a LILAM server in the current session |
| `CREATE_SERVER` | Starts a LILAM server through `DBMS_SCHEDULER` |
| `SERVER_SHUTDOWN` | Stops a server |
| `GET_SERVER_PIPE` | Returns the server pipe of a connected client |
| `SERVER_UPDATE_RULES` | Applies an updated rule set |

### Procedure START_SERVER

Starts a LILAM server. The password is required again when the server is shut down.

```sql
PROCEDURE START_SERVER(
  p_pipeName  VARCHAR2,
  p_groupName VARCHAR2,
  p_password  VARCHAR2
)
```

### Function CREATE_SERVER

Starts a LILAM server through `DBMS_SCHEDULER` and returns server information as `VARCHAR2`.

```sql
FUNCTION CREATE_SERVER(
  p_pipeName  VARCHAR2,
  p_groupName VARCHAR2,
  p_password  VARCHAR2
) RETURN VARCHAR2
```

### Procedure SERVER_SHUTDOWN

The client must already be connected to the server. The process ID, server pipe, and shutdown password are required.

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

Rules are stored as JSON objects in `LILAM_RULES`. After a rule set has been inserted or modified, call `SERVER_UPDATE_RULES` through an active server connection to apply it.

```sql
PROCEDURE SERVER_UPDATE_RULES(
  p_processId      NUMBER,
  p_ruleSetName    VARCHAR2,
  p_ruleSetVersion PLS_INTEGER
)
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
| `logLevelMonitor` | 3 | Enables monitoring features |
| `logLevelInfo` | 4 | INFO, WARN, and ERROR |
| `logLevelDebug` | 8 | DEBUG, INFO, WARN, and ERROR |

```sql
logLevelSilent  CONSTANT PLS_INTEGER := 0;
logLevelError   CONSTANT PLS_INTEGER := 1;
logLevelWarn    CONSTANT PLS_INTEGER := 2;
logLevelMonitor CONSTANT PLS_INTEGER := 3;
logLevelInfo    CONSTANT PLS_INTEGER := 4;
logLevelDebug   CONSTANT PLS_INTEGER := 8;
```

### Record Type t_session_init

Use `t_session_init` to collect initialization settings before calling the record-based `NEW_SESSION` overload.

```sql
TYPE t_session_init IS RECORD (
  processName   VARCHAR2(100),
  logLevel      PLS_INTEGER := logLevelMonitor,
  stepsToDo     PLS_INTEGER,
  daysToKeep    PLS_INTEGER := 100,
  procImmortal  PLS_INTEGER := 0,
  tabNameMaster VARCHAR2(100) DEFAULT 'LILAM'
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

### JSON API Interface

LILAM JSON requests use a header and a parameter object. The `version` and `client_id` header fields are currently not used.

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
    "tab_name_master": "GATES"
  }
}
```
