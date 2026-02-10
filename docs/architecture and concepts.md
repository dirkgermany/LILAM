# LILA Architecture and Concepts

## Technical Overview
LILA utilizes the core functionalities made available by Oracle through its PL/SQL (from version 12 onwards, tested under 19c and 26 AI). LILA itself is a PL/SQL script that can be used by other PL/SQL scripts in various modi operandi.

This means LILA is the opposite of "black magic" or over-the-top engineering. By using three tables, indexes, a sequence, and pipes, LILA pursues a 100% Zero-Dependency strategy. In fact, due to the communication via pipes, scenarios are conceivable in which LILA is used in conjunction with non-PL/SQL applications. The security of session, log, and metric data is guaranteed by autonomous transactions. These are sharply separated from data in memory and from the transactions of other applications, ensuring their own COMMIT even if the application had to perform a rollback.

LILA itself is a package consisting of the usual specification (.pks) and the body (.pkb). The code consists of a few thousand real lines of code; in version 1.3, which already featured most functionalities, it was around 3,000 LOC. The functionalities of the LILA client and the LILA server are entirely part of this code.

Installation requires nothing more than copying the code into a suitable DB schema and granting a few permissions. More on this in setup.md.

**Programmatic vs. Declarative:** Whenever possible, I have tried to develop LILA so that it works without configuration tables, files, or the like. Rather, my goal was for the tool's behavior to be controlled through the API—i.e., programmatically. As a developer, I know how annoying it can be to have to struggle through hours of preparation before finally getting 'down to business.' 

In fact, there are currently no configuration table(s), startup scripts, or similar requirements to use the full scope of LILA (as of v1.3.0).

# Terms
First, some important clarifications of terms within the LILA context.

## Process
LILA is used to monitor applications that ultimately represent a process of some kind. A process is therefore something that can be mapped or represented with software. Within the meaning of LILA, the developer determines when a process begins and when it ends. 

A process specifically includes its name, lifecycle information, and planned as well as completed work steps. 

## Session
A session represents the lifecycle of a process. A process 'lives' within a session. A session is opened once and closed once. For clean, traceable, and consistent process states, the final closing of sessions is indispensable. 

The session is more of a technical perspective on the workflows within LILA, while the process is the view 'to the outside.' I believe these two terms—session and process—can be used almost synonymously in daily LILA operations. It doesn't really hurt if they are mixed a bit.

## Logs / Severity
These are the usual suspects; SILENT, ERROR, WARN, INFO, DEBUG (in order of their weight). Need I say more? 
Ultimately, the developer decides which severity level to assign to an event in their process flow. 
Regarding the logging of process logs, the severity, the timestamp, and the most descriptive detail information possible are important.

## Log Level
Depending on the log level, log messages are either processed or ignored. 
LILA has one exception, the **Metric Level**: In the hierarchy, this level sits at the threshold for reporting directly after WARN and before INFO. This means that if 'only' WARN is activated, metric messages are ignored; if INFO is activated, all messages except DEBUG are ignored (Operational Insight). 

A different log level can be selected for each process.

## Metrics
Metrics are detailed process steps in terms of count and duration. There can be any number of actions per process. Each action is given a name and can occur multiple times within the process. Every occurrence of an action is logged. In this way, the number and the time spans between the occurrences of actions of the same name can be measured. 
Furthermore, the average time span per action is measured and recorded at the respective last entry.

This might have been explained a bit complicatedly, so here is an example: 
The process knows actions 'A' and 'B'. Action 'A' is reported several times, action 'B' is reported several times. Totals and time histories for 'A' and 'B' are registered separately.

## Operating Modes
LILA features two operating modes that applications can use. It is possible to address these modes in parallel from within an application—I call this 'hybrid usage.'

### Inside
This form of integration is likely the standard when it comes to incorporating PL/SQL packages. The 'other' package extends the functional scope of the caller; the program flow is **synchronous**, meaning the control flow leaves the calling package, continues in the called package, and then returns. In Inside mode, LILA is exclusively available to the application.

### Decoupled
The opposite of synchronous execution in Inside mode is the **asynchronous** Decoupled mode.

In this mode, LILA functions as a **LILA Server**, which writes status changes, logs, and metrics into the log tables independently of the calling program—the **LILA Client**. Using 'Fire & Forget' via pipes, the LILA Client can deliver large amounts of data in a very short time without being slowed down itself.

Two exceptions must be considered here:

1. LILA Clients that threaten to flood the channel to the LILA Server due to an excessively high reporting rate are gently and temporarily—and barely noticeably—throttled until the LILA Server has processed the bulk of the load (Backpressure Management). Mind you, we are talking about magnitudes in the millisecond range. This mechanism can be deactivated via an API call in high-end environments, such as powerful ODAs (default is 'active').

2. Calls that request data packets from the LILA Server are necessarily synchronous if the application wants to process the response itself afterwards. However, scenarios are also conceivable here in which, for example, LILA Client 'A' requests a data packet from the LILA Server on behalf of LILA Client 'B'. 

This would turn LILA Client 'A' into a producer, the LILA Server into a dispatcher, and LILA Client 'C' into a consumer. **A true Message Broker Architecture!**

With the possibility of using several LILA Servers in parallel and simultaneously allowing individual clients to speak with multiple LILA Servers (and additionally integrating LILA as a library), the use of LILA is conceivable in a wide variety of scenarios. Load balancing, separation of mission-critical and less critical applications, division into departments or teams, multi-tenancy...

## Tables
A total of three tables are required for operation and user data, one of which serves solely for the internal synchronization of multiple LILA servers (more on this later). The detailed structure of these tables is described in the README file of the LILA-Logging project on GitHub.

### Master or Process Table
The process table, also known as the master table, represents the processes. For each process, exactly one entry exists in this master table. During the lifecycle of a process, this data may change—especially the counter for completed process steps (i.e., the work progress). Additional information includes the currently used log level for this process, the name of the process, the timestamps for process start, last reported update, and completion. Another important piece of data is the Session ID, which is used for management.

The number of planned steps as well as the steps already completed are controlled by the application, either by explicitly setting these values or via an API trigger.

**The name of the master table can be chosen freely—within the scope of Oracle naming rules.**

### Detail Table
The detail table is where log entries and metrics are found. For each process, any number of logs and metrics can exist. The reference for this data is the Process ID from the master table.

The detail table is divided into two areas. One area contains the log messages with timestamps, severity, info text, user, platform, and—depending on the severity—the call stack and the error call stack (the stacks are automatically determined by LILA; the application developer does not need to worry about this).
> Log entries are created through the corresponding API calls (lila.error, lila.warn, lila.info, lila.debug).

The other area of the detail table contains the metrics. As explained above, metrics within a process are distinguished by their names. The values are calculated by LILA with each new entry.
> Metric entries are generated by the lila.mark_step API call.

The name of the detail table is always based on the name of the master table. It consists of the name of the master table plus an attached _DETAIL suffix.
Meaning: If the master table is named 'LILA_LOGGING', the detail table is named 'LILA_LOGGING_DETAIL'. This dependency cannot and must not be broken.

### Application-Specific Tables
In the interest of flexibility, it is possible to use dedicated LILA logging tables for different scenarios, applications, or processes. This also requires no configuration table or similar overhead. The names of the master and detail tables are optionally set during the API call to lila.new_session or lila.server_new_session.

But beware! The choice of tables and their names should be well-planned to avoid chaos caused by an excessive number of different LILA logging tables.

### Registry Table
The LILA_SERVER_REGISTRY is used for the coordination and assignment of LILA servers. Its name is fixed.

## API
The LILA API consists of approximately 35 procedures and functions, some of which are overloaded. Since static polymorphism does not change the outcome of the API calls, I am listing only the names of the procedures and functions below. The API can be divided into five groups:

### Session Handling
* **NEW_SESSION:** Starts a new session.
* **SERVER_NEW_SESSION:** Starts a new session within a LILA server.
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
* **GET_PROCESS_INFO:** Provides process information; outside of LILA's control.
* **GET_PROCESS_DATA:** Returns all process data in a specific structure.
* **GET_PROCESS_DATA_JSON:** Returns all process data in JSON format.

### Logging
* **INFO:** Reports a message with severity 'Info'.
* **DEBUG:** Reports a message with severity 'Debug'.
* **WARN:** Reports a message with severity 'Warn'.
* **ERROR:** Reports a message with severity 'Error'.

### Metrics
#### Setting Values
* **MARK_STEP:** Documents a completed work step for an action and triggers the sum and time calculations for those actions.

#### Querying Values
* **GET_METRIC_AVG_DURATION:** Returns the average processing duration for actions with the same name within a process.
* **GET_METRIC_STEPS:** Returns the current number of completed work steps for actions with the same name within a process.

### Server Control
* **START_SERVER:** Starts a LILA server.
* **SERVER_SHUTDOWN:** Shuts down a LILA server.
* **GET_SERVER_PIPE:** Returns the name of the pipe used to communicate with the server.

