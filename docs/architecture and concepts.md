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
