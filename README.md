# LILAM - PL/SQL Process Monitoring & Observability Framework

LILAM = "**L**ILAM **I**s **L**ogging **A**nd **M**onitoring"

[![Release](https://img.shields.io/github/v/release/dirkgermany/LILAM)](https://github.com/dirkgermany/LILAM/releases/latest)
[![Status](https://img.shields.io/badge/Status-Production--Ready-brightgreen)](https://github.com/dirkgermany/LILAM)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![License: Enterprise](https://img.shields.io/badge/License-Enterprise-brightgreen.svg)](LICENSE_ENTERPRISE.md)
[![Größe](https://img.shields.io/github/repo-size/dirkgermany/LILAM)](https://https://github.com/dirkgermany/LILAM)
[![Sponsor](https://img.shields.io/badge/Sponsor-LILAM-purple?style=flat-square&logo=github-sponsors)](https://github.com/sponsors/dirkgermany)


<p align="center">
  <img src="images/lilam-logging.svg" alt="Lila Logger Logo" width="300">
</p>

LILAM is a high-performance process monitoring, observability and logging framework for Oracle PL/SQL. It provides deep real-time insights into process metrics and utilizes a dynamic JSON-based rule engine to trigger autonomous responses and coordinate complex workflows.
Its simple API allows for seamless integration into existing applications with minimal overhead.

LILAM utilizes **autonomous transactions** to ensure that process states, log entries, and performance metrics are persisted independently of the main execution flow. This decoupled approach guarantees a complete audit trail and reliable monitoring data, even if the primary business process undergoes a rollback.

LILAM is developed by a developer who hates over-engineered tools. Focus: 5 minutes to integrate, 100% visibility.
```sql
  DECLARE
    l_pid NUMBER;
  BEGIN
    l_pid := lilam.new_process('IMPORT_CUSTOMERS', lilam.logLevelInfo);
    lilam.info(l_pid, 'Import started');
    -- your business logic
    lilam.info(l_pid, 'Import finished');
    lilam.close_process(l_pid);
  END;
  /

  select   no, info, session_time, caller
  from     lilam_log
  order by process_id desc, no;
```

## Content
- [Quick start](#quick-start)
- [Key features](#key-features)
- [Comparison](#comparison)
- [Fast integration](#fast-integration)
- [Advantages](#advantages)
- [Process Tracking & Monitoring](#process-tracking--monitoring)
  - [Rule-based Observability & Orchestration](#rule-based-observability--orchestration)
  - [How To - The Subway Sample](#how-to---the-subway-sample)
- [Data](#data)
  - [Process data](#process-data)
  - [Logging data](#logging-data)
  - [Monitoring data](#monitoring-data)
- [Repository Structure](#repository-structure)
- [Performance Benchmark](#performance-benchmark)
- [License](#license)
- [Roadmap](#roadmap)

## Quick start
1. Execute [grants](docs/setup.md#privileges-of-your-schema-user)
2. Copy & compile [spec](source/package/lilam.pks) and [body](source/package/lilam.pkb)
3. Execute
    ```sql
    DECLARE
      l_pid NUMBER;
    BEGIN
      l_pid := lilam.new_process('MY_PROCESS');
      lilam.warn(l_pid, 'Hello LILAM');
      lilam.close_process(l_pid);
    END;
    /
    ```
4. Query (the tables are created automatically on the first call)
    ```sql
     select * from lilam_proc; -- process status
     select * from lilam_log;  -- log details
     select * from lilam_mon;  -- events and traces
    ```

## Key features
1. **Self-Installing:** One package and one sequence; all tables are created by LILAM itself when they are first needed: three per application (`_PROC`, `_LOG`, `_MON`) plus nine internal tables for rules, alerts, baselines and the server infrastructure (see [Tables](docs/architecture%20and%20concepts.md#tables)). No install scripts, no schedulers required for in-session use
2. **Concurrent Logging:** Supports multiple, simultaneous log entries from the same or different sessions without blocking
3. **Runtime Observability:** Captures and correlates logs, events and business transactions in near real-time, providing deep, fluent performance tracing across application sessions
4. **Rule-Based Orchestration:** Evaluates versioned JSON rule-sets against observability data to automatically trigger alerts or execute decoupled consumers for reactive error-handling and workflow control
5. **Hybrid Execution:** Run LILAM **in-session** or offload processing to a dedicated LILAM-Server (**decoupled**).
6. **Data Integrity:** Uses autonomous transactions to guarantee log persistence regardless of the main transaction's outcome
7. **Smart Context Capture:** Automatically records ERR_STACK,  ERR_BACKTRACE, and ERR_CALLSTACK based on log level—deep insights with zero manual effort
8. **Optional self-cleaning:** Automatically purges expired logs per application during session start—no background jobs or schedulers required
9. **Future Ready:** Built and tested in latest Oracle 26ai (2026) and 19c environment
10. **Self-Contained:** One package without dependencies on other packages or external libraries; it uses only Oracle built-ins such as `DBMS_PIPE`, `DBMS_ALERT` and `DBMS_SCHEDULER`. With server failover, measured values and the rule engine the code has grown to about 7,800 lines of logical PL/SQL code (without blank and comment lines); quality and security reviews still cover a single package

---
## Comparison
While traditional PL/SQL tools focus on logging or low-level tracing, LILAM introduces process-level observability directly inside the database.
It combines process lifecycle tracking, metrics, and rule-based reactions into a unified in-database observability model.

> This table compares different approaches to logging, instrumentation and observability in PL/SQL.
> It highlights conceptual focus areas rather than full feature parity.

### Logging Frameworks

| Capability                          | LILAM | Logger | PIT | log4plsql |
|-------------------------------------|-------|--------|-----|-----------|
| Logging                             | ✅    | ✅     | ✅  | ✅        |
| Log Levels                          | ✅    | ✅     | ✅  | ✅        |
| Error Context (Stack, Backtrace)    | ✅    | ✅     | ✅  | ⚠️        |
| Autonomous Transaction Logging      | ✅    | ✅     | ⚠️  | ✅        |
| Minimal Setup (Package-based)       | ✅    | ✅     | ⚠️  | ❌        |

---

### Instrumentation & Debugging

| Capability                          | LILAM | Console | Custom Instrumentation |
|-------------------------------------|-------|---------|------------------------|
| Logging                             | ✅    | ✅      | ⚠️                     |
| Runtime Instrumentation             | ✅    | ✅      | ✅                     |
| Session / Context Tracking          | ✅    | ⚠️      | ❌                     |
| Performance Insights                | ✅    | ⚠️      | ⚠️                     |
| Centralized Data Model              | ✅    | ❌      | ❌                     |

---

### Native Oracle Tools

| Capability                          | LILAM | DBMS_TRACE / PROFILER |
|-------------------------------------|-------|------------------------|
| Low-level Tracing                   | ⚠️    | ✅                     |
| Profiling                           | ❌    | ✅                     |
| Process Lifecycle                   | ✅    | ❌                     |
| Aggregated Metrics                  | ✅    | ❌                     |
| Real-time Monitoring                | ✅    | ❌                     |
| Developer-friendly API              | ✅    | ❌                     |


---

## Architecture at a Glance

![LILAM Architektur](./images/LILAM%20Application%20Context.svg)

---
## Fast integration
* Setting up LILAM means creating a package and granting privileges (refer [documentation file "setup.md"](docs/setup.md))
* Only a few API calls are necessary for the complete logging of a process (refer [documentation file "API.md"](docs/API.md))
* Analysing or monitoring your process requires simple sql statements or API requests

>LILAM comes ready to test right out of the box, so no custom implementation or coding is required to see the framework in action immediately after setup.
>First code impressions you can find here: [learn_lilam](demo/first_steps/learn_lilam.pkb).

---

## Advantages
The following points complement the **Key Features** and provide a deeper insight into the architectural decisions and technical innovations of LILAM.

### Smart Load Balancing & Execution
LILAM introduces a high-performance Client-Server architecture using **Oracle Pipes**. This allows for asynchronous log processing and cross-session monitoring
* **Hybrid Execution:** Combine direct API calls within your session with decoupled processing via dedicated LILAM servers. Choose the optimal execution path for each log level or event type in real-time
* **Load-Aware Discovery:** Clients automatically identify and connect to the least-loaded server within their group
* **Auto-Synchronization:** Servers dynamically claim communication pipes, ensuring a zero-config setup
* **Backpressure:** If a server falls behind, its clients slow down in short steps until it has caught up. The server's performance level (`p_perfServer`) is not a hard limit: as long as the server keeps up, nothing is slowed down
* **Automatic Failover:** If a server fails, its clients switch to another server of the group and resend the messages the failed server had not yet committed


#### How it works
LILAM offers two execution models that can be used interchangeably:
1. **In-Session Mode (Direct):** Initiated by `lilam.new_process`. LILAM acts as embedded library, Log and Metric calls are executed immediately within your current database session. This is ideal for straightforward debugging and ensuring data is persisted synchronously.
2. **Decoupled Mode (Server-based):**
   In this mode, LILAM decouples the request from the execution. It acts as a proxy within the application session, offloading the heavy lifting to dedicated background worker processes. 
   * **Server Side:** Launch one or more LILAM servers using `lilam.start_server('PIPE_NAME', 'GROUP_NAME', 'PASSWORD');` (or `lilam.create_server(...)` to run them as scheduler jobs). Each server listens on its own pipe and registers under a group name. You can scale by running multiple servers in the same group or use different groups for logical separation.
   * **Client Side:** Register via `lilam.server_new_process('PROCESS_NAME', 'GROUP_NAME');`. LILAM automatically selects an available server of that group (or any available server if no group is given).
   * **Execution:** Log calls are serialized into a pipe and processed by the background server, minimizing the impact on your transaction time.
  
> [!IMPORTANT]
> **Unified API:** Regardless of the chosen mode, the logging API remains **identical**. You use the same `lilam.log(...)` calls throughout your application.
> The only difference is the initial setup (`lilam.new_process` for In-Session mode vs. `lilam.server_new_process` for Decoupled mode).

### Performance & Safety
LILAM prioritizes the stability of your application. It uses a Hybrid Model to balance speed and system integrity:
* Logs, metrics, and status updates are handled via Fire-and-Forget to minimize overhead.
* A client never waits for a reply from the server. Only if the server falls behind does the client slow down briefly (backpressure); if the pipe is full, it holds messages back for up to one second and resends them in order.
* Messages the server has not yet committed stay in the client's ring buffer. If the server fails, the client repeats them on another server of the group (failover).

### Technology
#### Autonomous Persistence
LILAM strictly utilizes `PRAGMA AUTONOMOUS_TRANSACTION`. Synchronous log entries are committed independently of the main transaction, even if the calling application executes a ROLLBACK due to an error. This ensures the root cause remains available for post-mortem analysis.

#### Deep Context Insights
By leveraging the `UTL_CALL_STACK`, LILAM automatically captures the exact program execution path. Instead of just logging a generic error, it documents the entire call chain, significantly accelerating the debugging process in complex, nested PL/SQL environments.

#### High-Performance Buffering
To minimize the impact on the main application’s overhead, LILAM features an internal buffering system. Log writing is processed efficiently, offering a decisive performance advantage over simple, row-by-row logging methods, especially in high-load production environments. The exception are entries up to the sync level (default `ERROR`): they are written immediately, so that the error and everything logged before it are stored (see the note under Performance & Safety).

#### Robust & Non-Invasive (Silent Mode)
LILAM is designed to be "invisible." The framework handles internal errors where possible to reduce the risk of disrupting application logic. Exceptions within LILAM are caught and handled internally.

#### Built-in Extensibility (Adapters)
LILAMs decoupled architecture is designed for seamless integration with modern monitoring stacks. Its structured data format allows for the easy creation of adapters.
*  **Oracle APEX:** Use native SQL queries to power APEX Charts and Dashboards for real-time application monitoring.
*  **Grafana:** Visualize performance trends and system health in Grafana dashboards. Use SQL-based or REST-based adapters to feed data directly into Grafana Dashboards.
*  **Mail Adapter (Example Included):** LILAM comes with a nearly production-ready reference implementation for Advanced Alerting. It demonstrates how to dispatch severity-based HTML emails (e.g., Red for Critical, Orange for Warnings) via local SMTP relays without blocking the main engine.
*  **Webhook & Messaging Hooks:** The adapter architecture is designed to easily plug in notifications for Slack, MS Teams, or Jira by simply implementing a new handler.

### High-Efficiency Monitoring

#### Real-Time and Granular Action Tracking
LILAM is a specialized framework for deep process insights. Using `MARK_EVENT` and `TRACE` functionality, named actions are monitored independently. The framework automatically tracks metrics **per action and context**:

* **Independent Statistics:** Monitor multiple activities (e.g., XML_PARSING, FILE_UPLOAD) simultaneously.
* **Point-in-Time Events:** Track milestones and calculate intervals between recurring steps using `MARK_EVENT`.
* **Measured Values:** Pass a numeric value with `MARK_EVENT` (e.g. a share price: `lilam.mark_event(l_pid, 'SHARE', 'ARAL', 80.71)`). LILAM keeps a separate moving average for the values and checks them with `VAL_` rules (fixed limits and deviations from the trend).
* **Transaction Tracing:** Use `TRACE_START` and `TRACE_STOP` for precise measurement of work blocks, ensuring clear visibility into long-running tasks.
* **Moving Averages & Outliers:** LILAM maintains historical benchmarks to detect performance degradation or unusual execution times (outliers) in real-time.
* **Minimal Client Overhead:** Metric calculations are buffered within the session to minimize database round-trips.

#### Intelligent Metric Calculation
Instead of performing expensive aggregations across millions of monitor records, LILAM uses an incremental calculation mechanism. Metrics like averages and counters are updated on-the-fly. This ensures that monitoring dashboards (e.g., in Grafana, APEX, or Oracle Jet) remain highly responsive even with massive datasets.


### Core Strengths

#### Scalability & Cloud Readiness
By avoiding file system dependencies (`UTL_FILE`) and focusing on native database features, LILAM is suited for scalable cloud infrastructures.

#### Developer Experience (DX)
LILAM promotes a standardized error-handling and monitoring culture within development teams. Its easy-to-use API allows for a "zero-config" start, enabling developers to implement professional observability in just a few minutes. No excessive DBA grants or infrastructure overhead required — just provide standard PL/SQL permissions, deploy the package, and start logging immediately.

---
## Process Tracking & Monitoring
LILAM categorizes data by its intended use to ensure maximum performance for status queries and analysis:
* **Lifecycle & Progress (Master):** One persistent record per process run. It provides real-time answers to: What is currently running? What is the progress (steps done/todo)? What is the overall status?
* **Monitoring & Metrics:** Tracks individual work steps (actions) within a process. This layer captures performance data, including execution duration, iteration counts, and average processing times.
* **Logging (History):** Standard operational trace. Persists log entries with severity levels, timestamps, and technical metadata (error stacks, user context) for debugging purposes.

### Rule-based Observability & Orchestration
LILAM doesn't just log data; it evaluates it. Using versioned JSON Rule-Sets, LILAM monitors process changes and business transactions in real-time.

* **Versioned Logic:** Each server group runs its own rule set and version—perfect for side-by-side testing or phased rollouts in separate groups.
* **Instant Alerts:** Violations trigger immediate alerts, which are processed by independent consumers.
* **System Decoupling:** By separating alert generation from processing, LILAM stays lean and serves as a high-performance orchestrator for downstream application logic.


### Key Benefits:
* No Aggregation Required: Status checks don’t need expensive GROUP BY operations on millions of rows.
* Immediate Transparency: Identify bottlenecks instantly through recorded action metrics.
* Centralized Configuration: Log levels and target tables are managed via the master record.

---
### How To - The Subway Sample
To illustrate how LILAM works, imagine monitoring a subway system:

**Process (TRACK_LINE_4):** The overall mission or service run of a specific line.

**Event (CLOSE_DOOR):** A discrete point in time. We mark this event at a specific station (STATION_ID_400). If a mandatory event did not happen before the next one, LILAM can trigger an alert (PRECEDED_BY).

**Trace/Transaction (TRACK_SECTION):** A time-based segment representing the travel between two points (e.g. SECTION_ID_402). By using trace_start and trace_stop, we automatically measure the travel time (y).

#### Identifier for the ongoing Process 
```sql
  l_processId NUMBER;
```
#### Start the Process and set Process values
```sql
  -- Start the mission as a new process.
  -- This and all other calls return in microseconds, as the LILAM proxy instantly offloads the workload to the asynchronous worker.
  -- Optional group-based isolation: LILAM servers can be assigned to specific groups to ensure strict workload isolation
  l_processId := lilam.server_new_process(p_processName => 'TRACK_LINE_4', p_groupName => 'UNDERGROUND_MONITORING', p_logLevel => lilam.logLevelMonitor);

  -- set number of steps this mission needs to be finished correctly
  -- in our sample there are only two steps: leaving station and arriving station
  lilam.set_proc_steps_todo(p_processId => l_processId, p_procStepsToDo => 2);
  
  -- leave station
  lilam.proc_step_done(p_processId => l_processId); -- increments step-counter into `1`
```

#### Monitor Action (Metric) and Log
```sql
  -- doors must be closed (Event)
  lilam.mark_event(p_processId => l_processId, p_actionName => 'CLOSE_DOOR', p_contextName => 'STATION_ID_400');

  -- log travel start
  lilam.info(p_processId => l_processId, p_logText => 'Line 4 leaving base');
```

#### Track Business Transactions
```sql
  -- travel the segment (trace Transaction by starting and stopping)
  lilam.trace_start(p_processId => l_processId, p_actionName => 'TRACK_SECTION', p_contextName => 'SECTION_ID_402');
  dbms_session.sleep(30); -- the train needed 30 seconds
  lilam.trace_stop(p_processId => l_processId, p_actionName => 'TRACK_SECTION', p_contextName => 'SECTION_ID_402');
```
#### Close the Process
```sql
  -- the mission of line is very! short - only one section; so the mission ends here
  --   !  missed code: lilam.proc_step_done(p_processId => l_processId); -- increments step-counter into `2`
  lilam.info(p_processId => l_processId, p_logText => 'Line 4 is back');
  lilam.close_process(p_processId => l_processId);

  -- the step-counter still is `1`. If there was an implemented rule-set which awaits 2 steps
  -- at the end of mission, LILAM would raise an `ALERT`
```
---
## Data
LILAM stores its data in three tables per application. Their names are derived from `p_tabNameMaster` (default `LILAM`): `LILAM_PROC`, `LILAM_LOG` and `LILAM_MON`. The tables are created automatically on the first API call.
The tables displayed below illustrate core content and, depending on the specific LILAM version, may include additional columns. The complete structure is described in [architecture and concepts](docs/architecture%20and%20concepts.md#tables).

### Process data
One row per process run; provides the current status of the process.
```sql
SELECT id, process_name, process_start, process_end, last_update, steps_todo, steps_done, status, info
FROM   lilam_proc
WHERE  process_name = 'MY_PROCESS';
```

>| ID | PROCESS_NAME | PROCESS_START         | PROCESS_END           | LAST_UPDATE           | STEPS_TODO | STEPS_DONE | STATUS | INFO
>| -- | ------------ | --------------------- | --------------------- | --------------------- | ---------- | ---------- | ------ | ------
>| 1  | MY_PROCESS   | 12.01.26 18:17:51,... | 12.01.26 18:18:53,... | 12.01.26 18:18:53,... | 100        | 99         | 2      | ERROR


### Logging data
```sql
SELECT process_id, no, info, log_level_c, session_time, session_user, host_name, err_stack, err_backtrace, err_callstack
FROM   lilam_log
WHERE  process_id = <id>
ORDER  BY no;
```

>| PROCESS_ID | NO | INFO               | LOG_LEVEL_C | SESSION_TIME    | SESSION_USER | HOST_NAME | ERR_STACK        | ERR_BACKTRACE    | ERR_CALLSTACK    |
>| ---------- | -- | ------------------ | ----------- | --------------- | ------------ | --------- | ---------------- | ---------------- | ---------------- |
>| 1          | 1  | Start              | INFO        | 13.01.26 10:... | SCOTT        | SERVER1   | NULL             | NULL             | NULL             |
>| 1          | 2  | Function A         | DEBUG       | 13.01.26 11:... | SCOTT        | SERVER1   | NULL             | NULL             | "--- PL/SQL ..." |
>| 1          | 3  | Something happened | ERROR       | 13.01.26 12:... | SCOTT        | SERVER1   | "--- PL/SQL ..." | "--- PL/SQL ..." | "--- PL/SQL ..." |

### Monitoring data
Events (`MON_TYPE` = 0) and traces (`MON_TYPE` = 1) share one table. `STOP_TIME` remains `NULL` for events.
```sql
SELECT process_id, mon_type, action, context, start_time, stop_time, used_millis, used_millis_ewma, action_count
FROM   lilam_mon
WHERE  process_id = <id>;
```

>| PROCESS_ID | MON_TYPE | ACTION    | CONTEXT    | START_TIME      | STOP_TIME       | USED_MILLIS | USED_MILLIS_EWMA | ACTION_COUNT |
>| ---------- | -------- | --------- | ---------- | --------------- | --------------- | ----------- | ---------- | ------------ |
>| 1          | 0        | MY_ACTION | MY_CONTEXT | 13.01.26 10:... | NULL            | 402         | 402        | 1            |
>| 1          | 0        | MY_ACTION | MY_CONTEXT | 13.01.26 10:... | NULL            | 510         | 456        | 2            |
>| 1          | 1        | TRANS_ACT | ROUTE_1    | 13.01.26 10:... | 13.01.26 10:... | 490         | 490        | 1            |

---
## Repository Structure
Locations of the core components:

* **[/source/package](/source/package)** – The PL/SQL source code for LILAM as API, Server and Proxy.
* **[/docs](/docs)** – API reference, additional architectural deep-dives and setup guide.
* **[/rules](/rules)** – Detailed documentation about the rules mechanic: [Rules Engine](./rules/README.md) and [JSON example](./rules/metro_rule_set_v1.json).
* **[/consumer](/consumer)** - Basic alert consumer 'template' with a ready-to-use mail-consumer

---
## Performance Benchmark
LILAM was measured on a consumer laptop (Fujitsu LIFEBOOK A357, Intel Core i5-7200U, 16 GB RAM) running **Oracle AI Database 26ai Free** in a VirtualBox VM. The Free edition allows at most **2 CPU threads** for all sessions together (applications, LILAM servers and the measurement), so the absolute numbers are a lower bound; on a database server with more CPU threads and fast redo storage they are expected to be considerably better.

*   **Cost per call:** a LILAM call costs the application **25–100 µs** (median) in both modes.
*   **Comparison:** for the same INFO entry LILAM needed **26 µs** (in-session) or **50 µs** (decoupled), OraOpenSource Logger 3.1.1 needed **1.4 ms** (median). Both follow different goals: Logger commits every entry before the call returns, LILAM buffers or decouples.
*   **Completeness:** no entry was lost in any of the 13 variants of the performance test (up to 3 clients × 100,000 calls, 1–3 servers, in-session and decoupled).
*   **Visibility:** under normal load all data is in the database a few tenths of a second up to about 2 seconds after the last call.

The long single calls under overload described in the report have since been fixed: the client no longer waits for replies from the server.

For details (call types, latency percentiles, cost of the failover) see the full report:
*   [Performance-Bericht (German)](./performance-report-deu.md)
*   The [English report](./performance-report-eng.md) describes an earlier stress test (before failover and measured values).

---
## License
This project is dual-licensed:
- For **Open Source** use: [GPLv3](LICENSE)
- For **Commercial** use (internal production or software embedding): [LILAM Enterprise License](LICENSE_ENTERPRISE.md)

*If you wish to use LILAM in a proprietary environment without the GPL "copyleft" obligations, please contact me for a commercial license.*

---
## Roadmap
- [X] **Automatic Failover:** Clients switch to the next available server of the group and resend messages not yet committed
- [ ] **Graceful Degradation:** Fall back from Decoupled to In-Session mode if no server is available
- [X] **Process Resumption:** Continue an open process via `process_id` from another database session (e.g. APEX/ORDS requests via the dispatcher)
- [X] **Retention:** Process data can be protected from deletion using the 'immortal' flag
- [ ] **Adaptive Batching:** Dynamically adjust buffer sizes and flush intervals based on server load to ensure near real-time visibility during low traffic and maximum throughput during peaks
- [ ] **Zombie Session Handling:** Detect inactive clients, release allocated memory, and update process statuses automatically
- [ ] **Singleton Server Enforcement:** Prevent multiple servers from registering under the same name to ensure message integrity and avoid process contention
- [ ] **Resilient Load Balancing:**
    * Clients perform a reconnect if another server with lower workload is available 
    * Clients perform a reconnect if Server sends 'DRAIN_AND_RECONNECT' or 'RECONNECT'
- [ ] **Dynamic Performance Configuration]:** Change server parameters during runtime
- [X] **Event-Driven Orchestration:**
    * Trigger automated **Actions** based on defined metric thresholds or event types
    * Enable seamless **Process Chaining**, where the completion or state of one action triggers subsequent logic
- [X] **Smart Alerting Logic:** Refine anomaly detection to distinguish between insignificant micro-variations (e.g., millisecond jitter) and actual performance regressions using configurable noise floors
- [ ] **Elastic Resource Management:**
    * Automatically scale LILAM-Server instances based on real-time pipe throughput
    * Ensure Graceful Shutdown of redundant instances to free up CPU and SGA without data loss
- [ ] **List active Sessions:** Retrieves a list of all active sessions, pipes and so on
- [x] **JSon Signatures:** Transport header information into server also as logged values


---
### Support the Project 💜
Do you find **LILAM** useful? Consider sponsoring the project to support its ongoing development and long-term maintenance.

[![Beer](https://img.shields.io/badge/Buy%20me%20a%20beer-LILAM-purple?style=for-the-badge&logo=buy-me-a-coffee)](https://github.com/sponsors/dirkgermany)


