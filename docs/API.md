# LILAM API Reference
### Version: 2.0

---

<details>
<summary>📖 <b>Contents</b></summary>

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
> This document is the LILAM API reference. If you are new to LILAM, it is recommended to read [architecture and concepts.md](architecture%20and%20concepts.md) first to get to know the underlying concepts. The examples in the `demo` folder show how the LILAM API can be integrated into applications.

---

## Quick Start

### In-Session Mode

Use the in-session mode when logging and monitoring are to be executed directly within the current database session.

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
> LILAM uses autonomous transactions. Logging and monitoring data are therefore persisted independently of the main transaction of the calling application. This also applies when the main transaction is rolled back.

### Decoupled Server Mode

Use the decoupled mode when clients are to send their logging and monitoring data to a LILAM server.

A server is identified by its pipe name and can optionally be assigned to a group. A client can either connect to any available server or restrict the server selection to a specific group.

#### Step 1: Start the Server

Start the server in a database session of its own. `START_SERVER` blocks this session as long as the server is running. In production, a server can be started via `DBMS_SCHEDULER` with `CREATE_SERVER`.

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

A client must first establish a connection to the server. The associated server pipe can then be determined with `GET_SERVER_PIPE` and passed to `SERVER_SHUTDOWN`.

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

Use `MARK_EVENT`, `TRACE_START` and `TRACE_STOP` to capture measurable activities within that process.

The number of process steps therefore does not have to match the number of metric events or traces.

### Events vs. Traces

A simple rule of thumb:

- **Something happened:** Use `MARK_EVENT`.
- **Something starts and ends later:** Use `TRACE_START` and `TRACE_STOP`.

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

These terms are deliberately kept in English because they refer directly to the API definition.

---

## Session Handling

Session handling controls the life cycle of a LILAM process.

| API | Purpose |
| --- | --- |
| `NEW_SESSION` | Starts a LILAM process in in-session mode |
| `SERVER_NEW_SESSION` | Starts a process connected to a LILAM server |
| `CLOSE_SESSION` | Ends a process and writes buffered data |
| `FLUSH` | Immediately writes all buffered data of the database session; the processes stay open |

### Function NEW_SESSION / SERVER_NEW_SESSION

Both functions start a LILAM process and return its process ID. This ID is required for all subsequent API calls.

- `NEW_SESSION` starts the process in in-session mode.
- `SERVER_NEW_SESSION` starts the process in decoupled mode via a LILAM server. The parameters are the same; `p_groupName` is in second position here, and in last position for `NEW_SESSION`.
- Alternatively, all settings can be combined in a [`t_session_init`](#record-type-t_session_init) record (`NEW_SESSION` only).

Each parameter is always in the same position. All parameters except `p_processName` have a default and can therefore be omitted or passed by name.

```sql
FUNCTION NEW_SESSION(
  p_processName   VARCHAR2,
  p_logLevel      PLS_INTEGER DEFAULT logLevelMonitor,
  p_procStepsToDo PLS_INTEGER DEFAULT NULL,
  p_daysToKeep    PLS_INTEGER DEFAULT NULL,
  p_tabNameMaster VARCHAR2    DEFAULT 'LILAM',
  p_baselineScope VARCHAR2    DEFAULT NULL,
  p_groupName     VARCHAR2    DEFAULT NULL,
  p_syncLevel     PLS_INTEGER DEFAULT logLevelError
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
  p_baselineScope VARCHAR2    DEFAULT NULL,
  p_syncLevel     PLS_INTEGER DEFAULT logLevelError
) RETURN NUMBER
```

```sql
FUNCTION SERVER_NEW_SESSION_JSON(
  p_jsonObject VARCHAR2
) RETURN NUMBER
```

`SERVER_NEW_SESSION_JSON` accepts the same parameters as a JSON object (see the table for the keys).

#### Parameters

| Parameter | JSON | Default | Description |
| --- | --- | --- | --- |
| `p_processName` | `process_name` | – | Name used to identify the process |
| `p_groupName` | `group_name` | `NULL` | `SERVER_NEW_SESSION`: restricts the server selection to the given group; `NULL` = any available server. `NEW_SESSION`: the process uses the active rule set of this group from `LILAM_RULES` (see [Rules in INSESSION Mode](#rules-in-insession-mode)); `NULL` = no rules |
| `p_logLevel` | `log_level` | `logLevelMonitor` | Level of logging detail, see [Log Levels](#log-levels) |
| `p_procStepsToDo` | `steps_todo` | `NULL` | Planned number of process steps |
| `p_daysToKeep` | `days_to_keep` | `NULL` | `NULL` = no automatic cleanup. Otherwise, at start, completed processes with the same name that are older than the given number of days are deleted together with their logs and metrics (except processes with `procImmortal = 1`) |
| `p_tabNameMaster` | `tabname_master` | `'LILAM'` | Prefix for the PROC, LOG and MON tables |
| `p_baselineScope` | `baseline_scope` | `NULL` | Frame of reference for the average values (EWMA) of traces and events: `NULL` = process name, i.e. shared across all processes with this name; `'#NONE'` = only within the individual process; otherwise a freely chosen name that can also be shared by several applications |
| `p_syncLevel` | `sync_level` | `logLevelError` | Entries up to this level are written synchronously, all others are buffered. `logLevelWarn` also makes `WARN` synchronous, `logLevelSilent` switches synchronous writing off entirely. See [Synchronous Writing](#synchronous-writing-p_synclevel) |

**Return value:** `NUMBER`, the process ID.

If `SERVER_NEW_SESSION` cannot create a process, the function does **not raise an exception** but returns a negative value. All further API calls with this ID are ignored without error; the application keeps running, just without logging and monitoring for this process. The cause is logged in `LILAM_LOG_INTERNAL`.

| Constant | Value | Meaning |
| --- | --- | --- |
| `NUM_ERR_SESSION_TIMEOUT` | -20110 | The server did not respond in time |
| `NUM_ERR_SESSION_THROTTLED` | -20120 | The server rejected the request (overload) |
| `NUM_COMM_ERR` | -20003 | Communication error, e.g. no active server found |

```sql
l_processId := lilam.server_new_session('IMPORT_CUSTOMERS', 'BATCH');
if l_processId < 0 then
  -- optional: custom reaction, e.g. notify operations
  null;   -- l_processId = lilam.NUM_ERR_SESSION_TIMEOUT, ...
end if;
```

> [!NOTE]
> If the client waits for the response in vain, the server will not create the process later either. For this purpose, the client passes an expiry time; if the request reaches the server only after that, it is discarded. This way, no orphaned processes that are never closed are created.

> [!NOTE]
> Thanks to the baseline scope, even an application that is restarted frequently builds up a stable basis for comparing its run times. The average values are stored in the tables `LILAM_SCOPES` and `LILAM_BASELINES`.
> The flow (resolution of the scope, loading and reconciliation with `LILAM_BASELINES`) is shown in a diagram in [architecture and concepts.md](architecture%20and%20concepts.md#baseline-scope).

#### Examples

```sql
-- name only, all other values by default
l_processId := lilam.new_session('IMPORT_CUSTOMERS');

-- log level INFO and 500 planned steps
l_processId := lilam.new_session('IMPORT_CUSTOMERS', lilam.logLevelInfo, 500);

-- individual parameters by name
l_processId := lilam.new_session('IMPORT_CUSTOMERS', p_daysToKeep => 30);
l_processId := lilam.new_session('IMPORT_CUSTOMERS', p_baselineScope => '#NONE');

-- in-session with the rules of group BATCH
l_processId := lilam.new_session('IMPORT_CUSTOMERS', p_groupName => 'BATCH');

-- also write WARN immediately and durably
l_processId := lilam.new_session('IMPORT_CUSTOMERS', p_syncLevel => lilam.logLevelWarn);

-- decoupled: any available server or a server of group BATCH
l_processId := lilam.server_new_session('IMPORT_CUSTOMERS');
l_processId := lilam.server_new_session('IMPORT_CUSTOMERS', 'BATCH', lilam.logLevelInfo);
```

### Procedure CLOSE_SESSION

Ends a LILAM process. Optionally, final process information, status and progress can be passed.

> [!IMPORTANT]
> Always call `CLOSE_SESSION` when a process ends. LILAM buffers data for performance reasons. `CLOSE_SESSION` ensures that any remaining buffered data is persisted.
>
> `CLOSE_SESSION` should therefore also be part of the final exception handling. If the process is to continue after the exception (e.g. an AJAX page keeps working), use [`FLUSH`](#procedure-flush) instead.

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

Parameters that remain `NULL` do not change the existing value of the process.

```sql
lilam.close_session(l_processId);
lilam.close_session(l_processId, 'Import completed', 1);
lilam.close_session(l_processId, 'Import completed', 1, 500);
```

Example of exception handling:

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

### Procedure FLUSH

LILAM buffers logging, monitoring and process data for performance reasons and writes them on a time-controlled basis (see [When are metrics and process data written?](#when-are-metrics-and-process-data-written)).

`FLUSH` immediately writes all buffered data of all open processes of the current database session, including baselines. Unlike `CLOSE_SESSION`, `FLUSH` does not end any process: the processes stay open, open traces keep running, and counters and averages keep counting.

```sql
PROCEDURE FLUSH
```

Typical uses:

- Exception handlers when the process is to continue afterwards (e.g. an AJAX page keeps working). If the process ends, use `CLOSE_SESSION`.
- A long-running in-session process is to be visible from outside immediately before a longer pause without LILAM calls.

```sql
BEGIN
  lilam.flush;
END;
/
```

> [!IMPORTANT]
> `FLUSH` only affects the database session from which it is called. For processes in decoupled mode (server, dispatcher), `FLUSH` has no effect: their buffers reside with the LILAM server, which writes them itself on a time-controlled basis.
>
> A `FLUSH` costs one commit (about 1.5 to 3.5 ms on the test system).

---

## Process Control

The process control APIs manage the overall progress and status of a process.

| API | Purpose |
| --- | --- |
| `SET_PROCESS_STATUS` | Updates the process status and optional process information |
| `SET_PROC_STEPS_TODO` | Sets the planned number of process steps |
| `PROC_STEP_DONE` | Increments the number of completed process steps |
| `SET_PROC_STEPS_DONE` | Explicitly sets the number of completed process steps |
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
> When process data changes, the `lastUpdate` value of the process record is updated implicitly.
>
> Process data is buffered and written on a time-controlled basis, see [When are metrics and process data written?](#when-are-metrics-and-process-data-written).

### Procedure SET_PROCESS_STATUS

Updates the application-specific numeric process status and, optionally, process information.

The meaning of the status value is not predefined by LILAM but determined by the calling application.

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

Explicitly sets the number of completed process steps.

A call overwrites a progress value previously built up with `PROC_STEP_DONE`.

```sql
PROCEDURE SET_PROC_STEPS_DONE(
  p_processId     NUMBER,
  p_procStepsDone NUMBER
)
```

### Procedure SET_PROC_IMMORTAL

Marks a process to be kept permanently (`1`) or removes the marking (`0`). Processes with `procImmortal = 1` are not deleted by the automatic cleanup via `p_daysToKeep`. At start, the value can also be set via `t_session_init.procImmortal`.

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

Returns the point in time at which the process was started by `NEW_SESSION` or `SERVER_NEW_SESSION`.

### Function GET_PROCESS_END

```sql
FUNCTION GET_PROCESS_END(
  p_processId NUMBER
) RETURN TIMESTAMP
```

Returns the point in time at which the process was ended by `CLOSE_SESSION`.

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

This avoids multiple individual getter calls. The function returns a complete `t_process_rec` record.

```sql
FUNCTION GET_PROCESS_DATA(
  p_processId NUMBER
) RETURN t_process_rec
```

> [!NOTE]
> `GET_PROCESS_DATA` is also the documented way to retrieve the process name and `tabNameMaster` together with the other process attributes.
>
> The name of the process table is formed from the master table name by appending `_PROC`.

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
- `p_logText` contains the message. Longer texts are truncated to 1,900 characters (possibly fewer with multi-byte characters such as umlauts, at most 2,000 bytes).

`ERROR` has the highest priority and is always stored, unless logging has been completely disabled with `logLevelSilent`.

When an entry actually appears in the table is described in [Synchronous Writing](#synchronous-writing-p_synclevel).

LILAM always handles internal errors silently and logs them in `LILAM_LOG_INTERNAL`; the application does not receive an exception. If `logLevelDebug` is active, LILAM additionally writes such errors as `ERROR` to the log of the affected process.

The complete mapping can be found under [Log Levels](#log-levels).

### Synchronous Writing (p_syncLevel)

LILAM buffers log entries for performance reasons. Entries up to the **sync level** of the process, however, are written immediately and durably. The sync level is set with `p_syncLevel` when the process is started; the default is `logLevelError`.

| Mode | Entries up to the sync level | All other entries |
| --- | --- | --- |
| In-Session | are committed in an autonomous transaction before the call returns. In doing so, LILAM also writes out all other buffered data of the database session. | remain in the buffer for up to about 1.5 seconds, longer if the session no longer calls LILAM (log calls, `MARK_EVENT`, `TRACE_STOP` and process control trigger the write-back, see [When are metrics and process data written?](#when-are-metrics-and-process-data-written)) |
| Decoupled | go to the server as usual and are written to the working table there. As a **safety net**, the client additionally writes them itself in an autonomous transaction before the call returns, always into **`LILAM_LOG`** in the client's schema (created if needed), with the process ID and the value `-1` in the column `NO`. | go to the server via pipe and are buffered there |

A synchronously written entry thus survives an aborted session and, in decoupled mode, a failure of the LILAM server. Buffered entries are lost if a session ends without `CLOSE_SESSION` or `FLUSH`. Therefore, call `CLOSE_SESSION` in the central exception handler, or `FLUSH` if the process is to continue.

> [!NOTE]
> In decoupled mode, synchronous entries are normally stored twice in the database: in the working table (written by the server) and in `LILAM_LOG` in the client's schema (`NO = -1`). If the LILAM server fails, the entry can still be found in `LILAM_LOG`. `LILAM_LOG` is used because the working table may reside in the server's schema, which the client has no access to.

A synchronous call costs about 1.5 to 3.5 ms instead of around 0.1 ms on the test system, mainly for the commit. Details, measurements and failure scenarios can be found in [Architecture and Concepts](architecture%20and%20concepts.md#when-is-a-log-entry-stored-sync-level).

### Function GET_COUNTER_WARN / GET_COUNTER_ERROR

```sql
FUNCTION GET_COUNTER_WARN(
  p_processId NUMBER
) RETURN PLS_INTEGER

FUNCTION GET_COUNTER_ERROR(
  p_processId NUMBER
) RETURN PLS_INTEGER
```

Return the number of calls of `WARN` or `ERROR`, respectively, for the process since it was started.

> [!NOTE]
> Counting takes place in the database session that calls `WARN` or `ERROR` (i.e. on the client in decoupled mode). For unknown or already closed processes, both functions return 0.

---

## Metrics

Metrics capture events and logical transactions within a process.

> [!IMPORTANT]
> `p_actionName` and `p_contextName` together form the identification of a metric.
>
> A trace started with a context must be stopped with the same combination of action and context.

### When are metrics and process data written?

LILAM also buffers metrics and process data (status, progress). In in-session mode, `MARK_EVENT`, `TRACE_STOP` and the procedures of [process control](#process-control) (`SET_PROCESS_STATUS`, `SET_PROC_STEPS_TODO`, `SET_PROC_STEPS_DONE`, `PROC_STEP_DONE`, `SET_PROC_IMMORTAL`) – like every log call – trigger the time-controlled write-back: data of a process older than about 1.5 seconds is written out, and cross-process baselines (`LILAM_BASELINES`) are likewise written at intervals of about 1.5 seconds. At least 500 ms pass between two check runs of the same database session, so a single call usually costs only a time comparison. `TRACE_START` does not trigger a write-back. This way, even pure monitoring applications that never log get their measurements and progress into the database promptly. Queries via the API (e.g. `GET_PROC_STEPS_DONE`) in the same session read the current state from the buffer anyway. With [`FLUSH`](#procedure-flush) you write the buffer immediately without ending the process.

> [!IMPORTANT]
> There is no timer in in-session mode. Data is only written when the session calls LILAM. Whatever is still in the buffer after the last call stays there until the session calls LILAM again. **Writing is guaranteed only with `CLOSE_SESSION` (process ends) or `FLUSH` (process stays open).**
>
> **AJAX and connection pool (e.g. APEX/ORDS):** An in-session process lives only in the database session that called `NEW_SESSION`. In the pool, the next request usually runs in a different session; there the process ID is unknown, and LILAM silently ignores the calls. A `CLOSE_SESSION` on a final page then does not reach the process, and its buffer remains in the original pool session.
>
> - **One process per request:** `NEW_SESSION` at the beginning and `CLOSE_SESSION` at the end of the same request. Then in-session mode also works in a connection pool.
> - **Processes spanning several requests** (e.g. AJAX pages that only trace or report progress, while only a final page calls `CLOSE_SESSION`): only with the [decoupled server mode](#decoupled-server-mode) together with the [dispatcher](#dispatcher-mode).

### Procedure MARK_EVENT

Use `MARK_EVENT` for a single event at a specific point in time within the process flow.

For repeated markers with the same action and the same context, LILAM tracks the time interval, number of occurrences, average duration and significant timing deviations.

```sql
PROCEDURE MARK_EVENT(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL,
  p_timestamp   TIMESTAMP DEFAULT NULL
)
```

### Procedure TRACE_START

Starts a logical transaction whose duration can be measured.

```sql
PROCEDURE TRACE_START(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL,
  p_timestamp   TIMESTAMP DEFAULT NULL
)
```

### Procedure TRACE_STOP

Ends the associated logical transaction.

```sql
PROCEDURE TRACE_STOP(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL,
  p_timestamp   TIMESTAMP DEFAULT NULL
)
```

> [!IMPORTANT]
> When the session ends, open traces are checked. A trace that has not been completed is logged as a warning.
>
> Therefore, also call `CLOSE_SESSION` in the final exception handling so that this check can take place.

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
> Server pipe names must be unique within the database instance. Each server additionally creates a control pipe with the suffix `_CTL` (e.g. `LILAM_SRV1_CTL` for `LILAM_SRV1`); these names must not be used for anything else either.

A server uses two pipes:

- **Data pipe** (`<pipe name>`): all logs, traces, events, status updates and queries in the order of their arrival.
- **Control pipe** (`<pipe name>_CTL`): only the creation of new processes (`SERVER_NEW_SESSION`). The server polls it before every data message, without waiting. As a result, creating a process does not have to wait behind the messages of other applications, even under high load. A short wake-up call into the data pipe ensures that even an idle server notices the request immediately.

**Server selection:** A client without a dispatcher and a dispatcher choose a server of the group for each new process according to these criteria:

1. fewest open processes (`CURRENT_PROCESSES`; the server updates the value directly after every new and every closed process),
2. lowest message rate (messages per second in the last housekeeping window, in steps of 100 messages/s; a value older than 1.5 s counts as 0),
3. the server that has been inactive the longest.

If the first two criteria are equal, the caller alternates between the servers (round robin per database session). This way, even processes created in quick succession are distributed evenly. Dispatchers are never chosen.

**Server loop and eco mode:** After a message, the server checks the pipe once without waiting. If it is empty, it waits 1 s, then 2 s, then 5 s each time; an incoming message wakes it up immediately. `DBMS_PIPE` only knows whole seconds, hence the integer steps. Housekeeping (registry with message rate, writing the buffers) runs every 500 ms, even while the server is working; when idle, at the next wake-up. If the pipe is empty and a worker still holds unwritten logs, metrics or process data, it writes them immediately (idle flush, at most every 200 ms; never on a dispatcher). After a pause, new entries therefore usually appear in the table after a few to a few hundred milliseconds.

| API | Purpose |
| --- | --- |
| `START_SERVER` | Starts a LILAM server in the current session |
| `CREATE_SERVER` | Starts a LILAM server via `DBMS_SCHEDULER` |
| `SERVER_SHUTDOWN` | Shuts down a server |
| `GET_SERVER_PIPE` | Returns the server pipe of a connected client |
| `SERVER_UPDATE_RULES` | Activates an updated rule set |
| `CHECK_RULE_SET` | Checks a rule set without saving or activating it |
| `SET_DISPATCHER_PIPE` | Configures a dispatcher for automatic routing and reconnect |

### Procedure START_SERVER
Starts a LILAM server.

The password must be specified again when the server is shut down later.

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
| p_password | varchar2 | Password that is required again for SERVER_SHUTDOWN |
| p_isDispatcher | pls_integer | 1 starts the server in dispatcher mode (see Dispatcher Mode), 0 (default) starts a regular server |
| p_perfServer | pls_integer | Performance level of the server, see [Performance Level](#performance-level-p_perfserver). `NULL` (default) = `C_SERVER_PERF_MID` |

#### Performance Level (p_perfServer)
To prevent a client from flooding the server with messages, after a certain number of messages per process and second the client briefly synchronizes with the server and waits until it has caught up. `p_perfServer` sets this limit. The server communicates it to the client at `SERVER_NEW_SESSION` (and at automatic reconnect); no separate call is needed in the application.

| Constant | Value | Use |
| --- | --- | --- |
| `C_SERVER_PERF_LOW` | 500 | less powerful environments |
| `C_SERVER_PERF_MID` | 1500 | default; typical servers |
| `C_SERVER_PERF_HIGH` | 2500 | high-performance servers |

Any other values are possible. `0` switches the synchronization off; `NULL` or negative values are treated as `C_SERVER_PERF_MID`.

> [!NOTE]
> The limit applies per process. If many applications send to the same server at the same time, its total throughput is lower than the sum of the individual values; in that case, rather choose `C_SERVER_PERF_LOW` or `C_SERVER_PERF_MID`, or start additional servers in the same group.

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
-- Example: server of group BATCH with medium performance level
dbms_output.put_line(lilam.create_server('LILAM_SRV1', 'BATCH', 'secret', p_perfServer => lilam.C_SERVER_PERF_MID));
```

### Procedure SERVER_SHUTDOWN
The client must already be connected to the server.

Shutting down requires the process ID, the server pipe and the password specified when the server was started.

```sql
PROCEDURE SERVER_SHUTDOWN(
  p_processId NUMBER,
  p_pipeName  VARCHAR2,
  p_password  VARCHAR2
)
```

During shutdown, the server first deregisters from the registry and is no longer selected from then on. It then still processes the messages that clients have already sent (drain phase): until the pipe stays empty for 1 s, at most about 5 s. After that, it writes all buffers and terminates.

### Function GET_SERVER_PIPE
Returns the server pipe linked to the connected client process.

```sql
FUNCTION GET_SERVER_PIPE(
  p_processId NUMBER
) RETURN VARCHAR2
```

### Function CHECK_RULE_SET
Checks a rule set exactly like `SERVER_UPDATE_RULES` does, without saving or activating it. Returns `NULL` if it is valid, otherwise the reason; the function does not raise an exception.

```sql
FUNCTION CHECK_RULE_SET(
  p_ruleSet CLOB
) RETURN VARCHAR2
```

```sql
SELECT LILAM.CHECK_RULE_SET('{"rules":[ ... ]}') FROM dual;
```

### Procedure SERVER_UPDATE_RULES
Rule sets are stored as JSON objects in `LILAM_RULES`, each for one group (`GROUP_NAME`, name, version). The same rule set can be entered for several groups. Exactly one rule set is active per group (`IS_ACTIVE = 1`); it applies to all servers of the group and to all INSESSION processes started with this group. Group, name and version are mandatory and unique together, the group case-insensitively; the version is an integer, `IS_ACTIVE` is 0 or 1.

```sql
PROCEDURE SERVER_UPDATE_RULES(
  p_groupName      VARCHAR2,
  p_ruleSetName    VARCHAR2,
  p_ruleSetVersion PLS_INTEGER
)
```

Flow:
1. The rule set of the group is fully checked in the calling session. If it is missing for the group or a rule is invalid, the call ends with the exception `NUM_ERR_RULE_SET` (-20130) and a reason; nothing changes. Values consisting of several parts separated by `|` must not contain empty parts (`|C1`, `A|`, `20||0.3` are rejected). Unknown keys of a rule, in `condition` or in `alert` are rejected (except those starting with `_`, e.g. `_comment`), as are fields that are objects, arrays or texts longer than 4000 characters.
2. The rule set becomes active for the group, the previously active one inactive.
3. Running servers of the group receive the reload instruction directly in their pipe, i.e. even without a running process and bypassing the dispatcher. Dispatchers do not evaluate rules. In addition, each server checks itself at most every 15 seconds whether the active rule set of its group has changed; a server that misses the instruction (e.g. full pipe) thus loads the new rule set after about 20 seconds at the latest.
4. INSESSION processes of the group load the new rule set themselves, at the latest with the first API call after 15 seconds (see [Rules in INSESSION Mode](#rules-in-insession-mode)).

A group without running servers is not an error: every server loads the active rule set of its group at start, including a newly added one. If a server rejects a rule set at start (e.g. because it has since been changed directly in the table), it keeps the previous rules (at start: none) and logs the reason in `LILAM_LOG_INTERNAL` and in the log of the server process.

```sql
INSERT INTO LILAM_RULES (group_name, set_name, version, created, author, rule_set)
VALUES ('METRO', 'METRO_RULES', 2, systimestamp, 'Dirk', '{"rules":[ ... ]}');

exec LILAM.SERVER_UPDATE_RULES('METRO', 'METRO_RULES', 2);
```

Structure of the rule sets and operators: [Rules Engine](../rules/README.md). A few points in advance:

- **Context rules:** Rules with a context (`Action|Context`) apply in addition to the rules without a context for the same action; LILAM checks both.
- **Logging rules:** Trigger `LOGGING` supports `SEVERITY` (exactly this level) and `LOG_CONTAINS` with the value `TEXT` or `LEVEL|TEXT`: the log message contains the text (case-insensitive), optionally only for this level. The first part only counts as a level if it is `ERROR`, `WARN`, `MONITOR`, `INFO` or `DEBUG`; otherwise the whole value is the text (max. 100 characters).
- **`PRECEDED_BY`, `PRECEDED_BY_WITHIN_SECS`:** The order is checked when an action starts (`MARK_EVENT`, `TRACE_START`, `PROCESS_UPDATE`, `PROCESS_STOP`). With `TRACE_STOP`, the rule is rejected at load time, because there the predecessor would usually be its own `TRACE_START`.
- **`AVG_DEVIATION_PCT`:** As long as the average is below 1 ms (measurement resolution), no evaluation takes place.
- **No time-based check:** Rules are evaluated when a signal arrives. Missing signals (a hanging process, an event that never comes) are not detected.

### Rules in INSESSION Mode
Processes in INSESSION mode also evaluate rules if `NEW_SESSION` receives a group (`p_groupName` or `t_session_init.groupName`). They then use the same active rule set of the group from `LILAM_RULES` as the servers of this group. Without a group there are no rules.

- **Loading:** The first rule check of a process of the group loads the active rule set into the memory of the database session. Further processes of the same group in this session share it. Different groups in one session are possible and remain separate.
- **Changes:** At most every 15 seconds, LILAM checks on an API call whether the name or version of the group's active rule set has changed, and then reloads it. `SERVER_UPDATE_RULES` therefore also takes effect here, at the latest with the first API call after 15 seconds. If a rule set is changed directly in the table without its name or version changing, a running session does not notice.
- **Invalid rule set:** It is rejected and logged once per version in `LILAM_LOG_INTERNAL`; the previous rules remain active. The application does not notice any of this.
- **Alerts:** A triggered alert is written immediately and synchronously (`LILAM_ALERTS` and `DBMS_ALERT` signal, own transaction). This costs the application one commit per alert; `throttle_seconds` limits the frequency. `GROUP_NAME` in the alert is the group from `NEW_SESSION`.
- **Memory per session:** Throttling (`throttle_seconds`) and the predecessor for `PRECEDED_BY` apply per database session. With a connection pool (e.g. APEX), the same alert can therefore be triggered once per pool connection.
- **Baseline parameters:** `warmup` and `alpha` from `AVG_DEVIATION_PCT` rules also apply to the average values of the process, just as in the server.

```sql
l_processId := lilam.new_session('IMPORT_CUSTOMERS', p_groupName => 'METRO');
```

## Dispatcher Mode
A server started with p_isDispatcher => 1 (dispatcher) does not process any requests itself, but forwards them unchanged to a suitable server.

For NEW_SESSION/SERVER_NEW_SESSION, the dispatcher uses the same load-based mechanism as the regular server selection and passes the request on to the control pipe of the selected server;
for all other requests, it uses the already assigned process_id to determine the server responsible for the application's process and forwards the request there.

The response of the responsible server goes directly back to the client, not via the dispatcher. A sequence diagram of the flow can be found in [architecture and concepts.md](architecture%20and%20concepts.md#dispatcher-flow).

A dispatcher is marked in the server registry (`IS_DISPATCHER = 1`) and is never chosen as a target during server selection. Workers and dispatchers can therefore run in the same group: clients without a dispatcher configuration always get a worker directly.

> [!TIP]
> A dispatcher is mainly relevant for applications that do not keep their physical database connection throughout – typically Oracle APEX applications with connection pooling.
> In that case, a subsequent page may run in a different physical session than the page that originally started the process.
> A configured dispatcher enables LILAM to restore the connection to the responsible worker automatically in this case, without the application having to control this itself.

For applications with a continuous database session (classic in-session or decoupled operation without connection pooling), no dispatcher is required.

### Automatic Reconnect
If a dispatcher is configured, LILAM automatically and transparently tries to re-establish a connection via the dispatcher on every API call with a process_id that is unknown to the current physical session.
If this fails (no dispatcher configured, dispatcher not reachable, or the process no longer exists), the call behaves like any other call with an unknown process_id: it is ignored without an error message.

The following applies:

- No reconnect is attempted for negative process_ids (e.g. `NUM_ERR_SESSION_TIMEOUT`).
- If the dispatcher does not find a responsible server, it responds immediately with an error; the application does not wait.
- A failed reconnect is remembered for the physical session: if the server does not know the process (e.g. after `CLOSE_SESSION`), further calls with this process_id are ignored without a new request. In case of temporary disruptions (dispatcher not reachable), the next attempt is made after 10 seconds at the earliest.

### Prewarming
The automatic reconnect attempt costs a one-time pipe round trip. Without prewarming, the first API call after a session change bears this additional latency.
If p_processId is passed, this round trip already takes place when SET_DISPATCHER_PIPE is called – typically during page rendering, before the application responds.

### Procedure SET_DISPATCHER_PIPE
Tells LILAM via which pipe a dispatcher can be reached. This information is held exclusively in the memory of the current physical database session.

> [!IMPORTANT]
> Since the configuration only applies to the current physical session, SET_DISPATCHER_PIPE must be called again every time a new connection is established – with connection pooling, potentially on every page, not just once on the first page call.


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
| p_groupName | varchar2 | Optional identifier in case several dispatchers are used in parallel. [Automatic Reconnect](#automatic-reconnect) uses only the default identifier 'DEFAULT_DISPATCHER' |
| p_processId | number | Optional. If a process_id is already known, LILAM restores the connection to it immediately (see [Prewarming](#prewarming)) instead of only at the next API call |

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

Use `t_session_init` to combine the initialization settings and then pass them to the record-based `NEW_SESSION` overload.

```sql
TYPE t_session_init IS RECORD (
  processName   VARCHAR2(100),
  logLevel      PLS_INTEGER := logLevelMonitor,
  stepsToDo     PLS_INTEGER,
  daysToKeep    PLS_INTEGER,                    -- NULL = no automatic cleanup
  procImmortal  PLS_INTEGER := 0,
  tabNameMaster VARCHAR2(100) DEFAULT 'LILAM',
  baselineScope VARCHAR2(100),                  -- NULL = process name, '#NONE' = per process only
  groupName     VARCHAR2(50),                   -- group for the active rule set; NULL = no rules
  syncLevel     PLS_INTEGER := logLevelError    -- write synchronously up to this level
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

Simple functional test after installation: creates the process `LILAM Life Check` in in-session mode, writes a DEBUG entry and closes the process. On the first call, LILAM creates its tables; missing privileges are thus noticed immediately (entries in `LILAM_LOG_INTERNAL`).

```sql
exec lilam.is_alive;
```

### JSON API Interface

`CALL_BY_JSON` allows the most important API calls to be passed as JSON, e.g. from applications that can generate JSON more easily than PL/SQL calls.

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
| `NEW_SESSION` | `NEW_SESSION` (record) | `process_name`, `log_level`, `steps_todo`, `days_to_keep`, `process_immortal`, `tabname_master`, `baseline_scope`, `group_name` |
| `SERVER_NEW_SESSION` | `SERVER_NEW_SESSION_JSON` | as for `SERVER_NEW_SESSION`, see the table there |
| `CLOSE_SESSION` | `CLOSE_SESSION` | `process_id` |
| `FLUSH` | `FLUSH` | none |
| `SET_PROCESS_STATUS` | `SET_PROCESS_STATUS` | `process_id`, `process_status`, `process_info` |
| `SET_STEP_TODO` | `SET_PROC_STEPS_TODO` | `process_id`, `steps_todo` |
| `SET_STEPS_DONE` | `SET_PROC_STEPS_DONE` | `process_id`, `steps_done` |
| `PROC_STEP_DONE` | `PROC_STEP_DONE` | `process_id` |
| `SET_PROC_IMMORTAL` | `SET_PROC_IMMORTAL` | `process_id`, `process_immortal` |
| `INFO`, `DEBUG`, `WARN`, `ERROR` | Logging | `process_id`, `process_info` (log text) |
| `MARK_EVENT`, `TRACE_START`, `TRACE_STOP` | Metrics | `process_id`, `action_name`, `context_name`, `timestamp` |
| `SERVER_SHUTDOWN` | `SERVER_SHUTDOWN` | `process_id`, `pipe_name`, `password` |

The response contains the header of the request, `status` (`SUCCESS` or `ERROR`) and a `payload` with `returns` and `value`, e.g. `"returns": "PROCESS_ID", "value": 4711`. For an unknown `api_call`, `value` = `NUM_ERR_ILLEGAL_REQ` (-20010). If `p_callObject` is not valid JSON, the call ends with the exception -20005.

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
