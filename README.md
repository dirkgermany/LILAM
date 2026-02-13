# LILAM - LILAM Is Logging And Monitoring


[![Release](https://img.shields.io/github/v/release/dirkgermany/LILAM-Logging)](https://github.com/dirkgermany/LILAM-Logging/releases/latest)
[![Status](https://img.shields.io/badge/Status-Production--Ready-brightgreen)](https://github.com/dirkgermany/LILAM-Logging)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![License: Enterprise](https://img.shields.io/badge/License-Enterprise-brightgreen.svg)](LICENSE_ENTERPRISE.md)
[![Größe](https://img.shields.io/github/repo-size/dirkgermany/LILAM-Logging)](https://https://github.com/dirkgermany/LILAM-Logging)
[![Sponsor](https://img.shields.io/badge/Sponsor-LILAM-purple?style=flat-square&logo=github-sponsors)](https://github.com/sponsors/dirkgermany)


<p align="center">
  <img src="images/lilam-logging.svg" alt="Lila Logger Logo" width="300">
</p>

LILAM is a lightweight logging and monitoring framework designed for Oracle PL/SQL applications. It provides a fast, concurrent way to track processes. Its simple API allows for seamless integration into existing applications with minimal overhead.

LILAM utilizes autonomous transactions to ensure that all log entries are persisted, even if the main process performs a rollback.

LILAM is developed by a developer who hates over-engineered tools. Focus: 5 minutes to integrate, 100% visibility.

## Content
- [Key features](#key-features)
- [Fast integration](#fast-integration)
- [Advantages](#advantages)
- [Logging](#logging)
  - [How to log](#how-to-log)
- [Monitoring](#monitoring)
  - [How to monitor](#how-to-monitor)
- [Performance benchmark](#performance-benchmark)
- [Roadmap](#roadmap)
- [License](#license)


## Key features
1. **Lightweight:** One Package, three Tables, one Sequence. That's it!
2. **Concurrent Logging:** Supports multiple, simultaneous log entries from the same or different sessions without blocking
3. **Monitoring:** You have the option to observe your applications via SQL or via the API
4. **Hybrid Execution:** Run LILAM **in-session** or offload processing to a dedicated LILAM-Server (**decoupled**).
5. **Data Integrity:** Uses autonomous transactions to guarantee log persistence regardless of the main transaction's outcome
6. **Smart Context Capture:** Automatically records ERR_STACK,  ERR_BACKTRACE, and ERR_CALLSTACK based on log level—deep insights with zero manual effort
7. **Optional self-cleaning:** Automatically purges expired logs per application during session start—no background jobs or schedulers required
8. **Future Ready:** Built for the latest Oracle 26ai (2026), and fully tested with existing 19c environment
9. **Small Footprint:**  ~3k lines of logical PL/SQL code ensures simple quality and security control, fast compilation, zero bloat and minimal Shared Pool utilization (reducing memory pressure and fragmentation)

---

## Architecture at a Glance

![LILAM Architektur](./images/LILAM%20Application%20Context.svg)

---
## Fast integration
* Setting up LILAM means creating a package by copy&paste (refer [documentation file "setup.md"](docs/setup.md))
* Only a few API calls are necessary for the complete logging of a process (refer [documentation file "API.md"](docs/API.md))
* Analysing or monitoring your process requires simple sql statements or API requests

>LILAM comes ready to test right out of the box, so no custom implementation or coding is required to see the framework in action immediately after setup.
>Also please have a look to the sample applications 'learn_lilam': https://github.com/dirkgermany/LILAM-Logging/tree/main/demo/first_steps.

---

## Advantages
The following points complement the **Key Features** and provide a deeper insight into the architectural decisions and technical innovations of LILAM.

### Direct Mode & Server Mode
LILAM introduces a high-performance Server-Client architecture using **Oracle Pipes**. This allows for asynchronous log processing and cross-session monitoring
* **Hybrid Execution:** Combine direct API calls within your session with decoupled processing via dedicated LILAM servers. Choose the optimal execution path for each log level or event type in real-time
* **Smart Load Balancing:** Clients automatically discover available servers via Round-Robin
* **Auto-Synchronization:** Servers dynamically claim communication pipes, ensuring a zero-config setup
* **Congestion Control (Throttling):** Optional protection layer that pauses hyperactive clients to ensure server stability during high-load peaks

#### How it works
LILAM offers two execution models that can be used interchangeably:
1. **In-Session Mode (Direct):** Initiated by `lilam.new_session`. Log calls are executed immediately within your current database session. This is ideal for straightforward debugging and ensuring logs are persisted synchronously.
2. **Decoupled Mode (Server-based):**
   * **Server Side:** Launch one or more LILAM-Servers using `lilam.start_server('SERVER_NAME');`. These background processes register under a custom name and monitor for incoming commands. You can scale by running multiple servers for the same name or use different names for logical separation.
   * **Client Side:** Register via `lilam.server_new_session('SERVER_NAME');`. LILAM automatically identifies and connects to the specified available server.
   * **Execution:** Log calls are serialized into a pipe and processed by the background server, minimizing the impact on your transaction time.
  
> [!IMPORTANT]
> **Unified API:** Regardless of the chosen mode, the logging API remains **identical**. You use the same `lilam.log(...)` calls throughout your application.
> The only difference is the initial setup (`lilam.new_session` for  vs. `lilam.server_new_session` for Decoupled mode).

### Performance & Safety
LILAM prioritizes the stability of your application. It uses a Hybrid Model to balance speed and system integrity:
* Standard: Fire-and-Forget
* Logs, metrics, and status updates are handled via Fire-and-Forget to minimize overhead. Zero latency for your business logic.
* Active Throttling
* As an optional safeguard, LILAM rate-limits hyperactive clients during load peaks to prevent pipe flooding until the bottleneck is cleared.

### Technology
#### Autonomous Persistence
LILAM strictly utilizes `PRAGMA AUTONOMOUS_TRANSACTION`. This guarantees that log entries and monitoring data are permanently stored in the database, even if the calling main transaction performs a `ROLLBACK` due to an error. This ensures the root cause remains available for post-mortem analysis.

#### Deep Context Insights
By leveraging the `UTL_CALL_STACK`, LILAM automatically captures the exact program execution path. Instead of just logging a generic error, it documents the entire call chain, significantly accelerating the debugging process in complex, nested PL/SQL environments.

#### High-Performance Buffering
To minimize the impact on the main application’s overhead, LILAM features an internal buffering system. Log writing is processed efficiently, offering a decisive performance advantage over simple, row-by-row logging methods, especially in high-load production environments.

#### Robust & Non-Invasive (Silent Mode)
LILAM is designed to be "invisible." The framework ensures that an internal error during the logging process (e.g., table space issues or configuration errors) doesn't crash the calling application logic. Exceptions within LILAM are caught and handled internally, prioritizing the stability of your business transaction over the logging activity itself.

#### Built-in Extensibility (Adapters)
LILAMs decoupled architecture is designed for seamless integration with modern monitoring stacks. Its structured data format allows for the easy creation of adapters:
*   **Oracle APEX:** Use native SQL queries to power APEX Charts and Dashboards for real-time application monitoring.
*   **Grafana:** Connect LILAM via **ORDS (Oracle REST Data Services)** to visualize performance trends and system health in Grafana dashboards.
*   **Custom Adapters:** The relational core can be extended for any REST-based or SQL-based reporting tool without modifying the core logging engine.

### High-Efficiency Monitoring

#### Real-Time and Granular Action Tracking
LILAM is more than just a logging tool. Using the `MARK_STEP` functionality, named actions can be monitored independently. The framework automatically tracks metrics **per action**:
* **Independent Statistics:** Monitor multiple activities (e.g., XML_PARSING, FILE_UPLOAD) simultaneously.
* **Step Duration:** Precise execution time for a specific action's segment.
* **Average Duration:** Historical benchmarks to detect performance degradation per action.
* **Zero Client Overhead:** Calculations are processed within the session or offloaded to the server, depending on the chosen mode.

#### Intelligent Metric Calculation
Instead of performing expensive aggregations across millions of log records for every query, LILAM uses an intelligent calculation mechanism. Metrics are updated incrementally, ensuring that monitoring dashboards (e.g., in Grafana, APEX, or Oracle Jet) remain highly responsive even with massive datasets.

### Core Strengths

#### Scalability & Cloud Readiness
By avoiding file system dependencies (`UTL_FILE`) and focusing on native database features, LILAM is 100% compatible with **Oracle Autonomous Database** and optimized for scalable cloud infrastructures.

#### Developer Experience (DX)
LILAM promotes a standardized error-handling and monitoring culture within development teams. Its easy-to-use API allows for a "zero-config" start, enabling developers to implement professional observability in just a few minutes. No excessive DBA grants or infrastructure overhead required — just provide standard PL/SQL permissions, deploy the package, and start logging immediately.

---
## Demo
Execute the following statement in the SQL editor (optionally activate dbms-output for your session beforehand):
```sql
exec lilam.is_alive;
select * from lilam_log;
```
If you have activated dbms output, you will receive an additional message there.

---
## Logging
LILAM persists different information about your processes.
For simplicity, all logs are stored in two tables.

1. The master table contains data about the process itself (the live-dashboard). Always exactly one record per process. This table frees you from complex queries such as “group by,” “max(timestamp),” etc., which you would otherwise have to run on thousands or millions of rows to see the current status of your process.
2. The table with typical detailed log information (the process-history). This second table enables rapid monitoring because the constantly growing number of entries has no impact on the master table.

***Process information***
* Process name
* Process ID
* Timestamps process_start
* Timestamp process_end
* Timestamp last_update (at end of your process identical with timestamp of process_end)
* Steps todo and steps done
* Any info
* (Last) status

***Detailed information***
* Process ID
* Serial number
* Any info
* Log level
* Session time
* Session user
* Host name
* Error stack (when exception was thrown)
* Error backtrace (depends to log level)
* Call stack (depends to log level)

### How to log
A code snippet:
```sql
procedure MY_DEMO_PROC
as
  -- process ID related to your logging process
  l_processId number(19,0);

begin
  -- begin a new logging session ( Mode)
  -- use lilam.server_new_session('NAME', ...) for Decoupled Mode
  -- the last parameter refers to killing log entries which are older than the given number of days
  -- if this param is NULL, no log entry will be deleted
  l_processId := lilam.new_session('my application', lilam.logLevelDebug, 30);

  -- write log entries whenever you want
  lilam.info(l_processId, 'Start');
  lilam.debug(l_processId, 'Function A');
  lilam.info(l_processId, 'Something happened');

  -- create monitor markers
  lilam.mark_step(l_processId, 'MY_ACTION');
  dbms_session.sleep(1); -- wait a second
  lilam.mark_step(l_processId, 'MY_ACTION');

  -- also you can change the status during your process runs
  lilam.set_process_status(lProcessId, 1, 'DONE');

  -- last but not least end the logging session
  -- optional you can set the numbers of steps to do and steps done 
  lilam.close_session(lProcessId, 100, 99, 'DONE', 1);

end MY_DEMO_PROC;

```
---
## Monitoring
Monitor your processes according to your requirements:
* Real-time Progress: Query the master table for a single-row snapshot of any running process (steps_todo, steps_done, status, timestamps).
* Deep Dive (Details): Query the detail table for the full chronological history and error stack of a process.
* API Access: Use the built-in getter functions to retrieve status and progress directly within your PL/SQL logic or UI components.

### How to monitor
Three options:

#### Real-time Progress
**Live-dashboard data**
```sql
SELECT id, status, last_update, ... FROM lilam_log WHERE process_name = ... (provides the current status of the process)
```

>| ID | PROCESS_NAME   | PROCESS_START         | PROCESS_END           | LAST_UPDATE           | STEPS_TO_DO | STEPS_DONE | STATUS | INFO
>| -- | ---------------| --------------------- | --------------------- | --------------------- | ----------- | ---------- | ------ | ------
>| 1  | my application | 12.01.26 18:17:51,... | 12.01.26 18:18:53,... | 12.01.26 18:18:53,... | 100         | 99         | 2      | ERROR



#### Deep Dive
**Historical data**
```sql
SELECT * FROM lilam_log_detail WHERE process_id = ...
```

The monitoring table consists of two parts: the 'left' one is dedicated to logging, the 'right' one is dedicated to monitoring.

**Logging data**

>| PROCESS_ID | NO | INFO               | LOG_LEVEL | SESSION_TIME    | SESSION_USER | HOST_NAME | ERR_STACK        | ERR_BACKTRACE    | ERR_CALLSTACK    | MONITORING
>| ---------- | -- | --------------     | --------- | --------------- | ------------ | --------- | ---------------- | ---------------- | ---------------- | ------------
>| 1          | 1  | Start              | INFO      | 13.01.26 10:... | SCOTT        | SERVER1   | NULL             | NULL             | NULL             | 0
>| 1          | 2  | Function A         | DEBUG     | 13.01.26 11:... | SCOTT        | SERVER1   | NULL             | NULL             | "--- PL/SQL ..." | 0
>| 1          | 3  | Something happened | ERROR     | 13.01.26 12:... | SCOTT        | SERVER1   | "--- PL/SQL ..." | "--- PL/SQL ..." | "--- PL/SQL ..." | 0

**Monitoring data**

>| PROCESS_ID | ... | ... | MONITORING | MON_ACTION | MON_STEPS_DONE | MON_USED_MILLIS | MON_AVG_MILLIS
>| ---------- | --- | --- | ---------- | ---------- | -------------- | --------------- | ---------------
>| 1          | ... | ... | 1          | MY_ACTION  | 1              | NULL            | NULL
>| 1          | ... | ... | 1          | MY_ACTION  | 2              | 1000            | 1000

---
## API
The API provides all process data which belongs to the process_id (see [Logging](#logging)).
```sql
...
lProcessStatus := lilam.get_process_status(p_processId);
lProcessInfo := lilam.get_process_info(p_processId);
lStepsDone := lilam.get_steps_done(p_processId);
...
return 'ID = ' || id || '; Status: ' || lProcessStatus || '; Info: ' || lProcessInfo || '; Steps completed: ' || lStepsDone;
```
```sql
SELECT my_app.getStatus(1) proc_status FROM dual;
> ID = 1; Status: OK; Info: 'just working'; Steps completed: 42
```
---
## Performance Benchmark
LILAM is designed for high-concurrency environments. The following results were achieved on standard **Consumer Hardware** (Fujitsu LIFEBOOK A-Series) running an **Oracle Database inside VirtualBox**. This demonstrates the massive efficiency of the Pipe-to-Bulk architecture, even when facing significant virtualization overhead (I/O emulation and CPU scheduling):
*   **Total Messages:** 9,000,000 (Logs, Metrics, and Status Updates)
*   **Clients:** 3 parallel sessions (3M messages each)
*   **LILAM-Servers:** 2 active instances
*   **Total Duration:** ~45 minutes
*   **Peak Throughput:** ~3,300 - 5,000 messages per second

| Configuration | Throughput | Status |
| :--- | :--- | :--- |
| **Exclusive Server (1 Client)** | ~1.6k msg/s | Finished in 30m |
| **Shared Server (2 Clients)** | ~2.2k msg/s | Finished in 45m |

> **Key Takeaway:** Even on mobile hardware, LILAM handles millions of records without blocking the application sessions. On enterprise-grade server hardware with NVMe storage, throughput is expected to scale significantly higher.

---
## Roadmap
- [ ] **Automatic Fallback:**
    * switch to the next available server or
    * graceful degradation from Decoupled to  mode
- [ ] **Process Resumption:**
    * Reconnect to aborted processes via `process_id`
- [ ] **Non-destructive Recovery:** Mark log entries as "superseded" after a re-entry point instead of deleting them, preserving a full audit trail of all attempts
- [ ] **Adaptive Batching:** Dynamically adjust buffer sizes and flush intervals based on server load to ensure near real-time visibility during low traffic and maximum throughput during peaks
- [ ] **Zombie Session Handling:** Detect inactive clients, release allocated memory, and update process statuses automatically
- [ ] **Singleton Server Enforcement:** Prevent multiple servers from registering under the same name to ensure message integrity and avoid process contention
- [ ] **Resilient Load Balancing:** LILAM uses V$DB_PIPES for precision routing. If access is restricted, it seamlessly falls back to registry-based balancing or round-robin to ensure continuous operation.
- [ ] **Background Server Processing:** Start LILAM servers as jobs to avoid blocking sessions
- [ ] **Advanced Metric Visualization:**
    * Provide a pre-built Oracle APEX Dashboard to monitor real-time throughput and system health
    * Integration of Time-Series Charts to visualize metric trends and threshold violations over time
    * Support for Grafana via SQL-Plugin, enabling LILAM to be part of a centralized enterprise monitoring stack
- [ ] **Dynamic Configuration]:** Change server configuration during runtime
- [ ] **Event-Driven Orchestration:**
    * Trigger automated **Actions** based on defined metric thresholds or event types
    * Enable seamless **Process Chaining**, where the completion or state of one action triggers subsequent logic
- [ ] **Smart Alerting Logic:** Refine anomaly detection to distinguish between insignificant micro-variations (e.g., millisecond jitter) and actual performance regressions using configurable noise floors
- [ ] **Elastic Resource Management:**
    * Automatically scale LILAM-Server instances based on real-time pipe throughput
    * Ensure Graceful Shutdown of redundant instances to free up CPU and SGA without data loss
- [ ] **List active Sessions:** Retrieves a list of all active sessions, pipes and so on
- [ ] **JSon Signatures:** Offering API-calls with JSon Objects as input parameters


## License
This project is dual-licensed:
- For **Open Source** use: [GPLv3](LICENSE)
- For **Commercial** use (internal production or software embedding): [LILAM Enterprise License](LICENSE_ENTERPRISE.md)

*If you wish to use LILAM in a proprietary environment without the GPL "copyleft" obligations, please contact me for a commercial license.*


---
### Support the Project 💜
Do you find **LILAM** useful? Consider sponsoring the project to support its ongoing development and long-term maintenance.

[![Beer](https://img.shields.io/badge/Buy%20me%20a%20beer-LILAM-purple?style=for-the-badge&logo=buy-me-a-coffee)](https://github.com/sponsors/dirkgermany)


