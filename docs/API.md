# LILA API

<details>
<summary>📖<b>Content</summary>b></summary>

- [Functions and Procedures](#functions-and-procedures)
  - [Session related Functions and Procedures](#session-related-functions-and-procedures)
    - [Function NEW_SESSION](#function-new_session--server_new_session)
    - [Procedure CLOSE_SESSION](#procedure-close_session)
    - [Procedure SET_PROCESS_STATUS](#procedure-set_process_status)
    - [Procedure SET_STEPS_TODO](#procedure-set_steps_todo)
    - [Procedure SET_STEPS_DONE](#procedure-set_steps_done)
    - [Procedure STEP_DONE](#procedure-step_done)
  - [Write Logs related Procedures](#write-logs-related-procedures)
    - [General Logging Procedures](#general-logging-procedures)
    - [Procedure LOG_DETAIL](#procedure-log_detail)
  - [Appendix](#appendix)
    - [Log Level](#log-level)
        - [Declaration of Log Levels](#declaration-of-log-levels)

</details>


> [!TIP]
> This document serves as the LILA API reference, providing a straightforward description of the programming interface. For those new to LILA, I recommend starting with the document ["architecture and concepts.md"](docs/architecture-and-concepts.md), which (hopefully) provides a fundamental understanding of how LILA works. Furthermore, the demos and examples in the #demo folder demonstrate how easily the LILA API can be integrated.

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

All API calls are the same, independent of whether LILA is used 'locally' or in a 'decoupled' manner. One exception is the function `SERVER_NEW_SESSION`, which initializes the LILA package to function as a dedicated client, managing the communication with the LILA server seamlessly. **The parameters and return value of `SERVER_NEW_SESSION` are identical to those of `NEW_SESSION`.**


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
    p_logLevel      PLS_INTEGER, 
    p_TabNameMaster VARCHAR2 DEFAULT 'LILA_LOG'
  )
 ```
</details>

<details>
  <summary><b>2. Retention Mode</b> (With automated cleanup)</summary>

```sql
FUNCTION NEW_SESSION(
  p_processName   VARCHAR2, 
  p_logLevel      PLS_INTEGER, 
  p_daysToKeep    PLS_INTEGER, 
  p_TabNameMaster VARCHAR2 DEFAULT 'LILA_LOG'
)
 ```
</details>

<details>
  <summary><b>3. Full Progress Mode</b> (With progress tracking)</summary>

```sql
FUNCTION NEW_SESSION(
  p_processName   VARCHAR2, 
  p_logLevel      PLS_INTEGER, 
  p_stepsToDo     PLS_INTEGER, 
  p_daysToKeep    PLS_INTEGER, 
  p_TabNameMaster VARCHAR2 DEFAULT 'LILA_LOG'
)
 ```
</details>

**Parameters**

| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processName | VARCHAR2| freely selectable name for identifying the process; is written to *master table* | [`M`](#m)
| p_logLevel | PLS_INTEGER | determines the level of detail in *detail table* (see above) | [`M`](#m)
| p_stepsToDo | PLS_INTEGER | defines how many steps must be done during the process | [`O`](#o)
| p_daysToKeep | PLS_INTEGER | max. age of entries in days; if not NULL, all entries older than p_daysToKeep and whose process name = p_processName (not case sensitive) are deleted | [`O`](#o)
| p_TabNameMaster | VARCHAR2 | optional prefix of the LOG table names (see above) | [`D`](#d)

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

| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_stepsToDo | PLS_INTEGER | Number of work steps that would have been necessary for complete processing. This value must be managed by the calling package | [`N`](#n)
| p_stepsDone | PLS_INTEGER | Number of work steps that were actually processed. This value must be managed by the calling package | [`N`](#n)
| p_processInfo | VARCHAR2 | Final information about the process (e.g., a readable status) | [`N`](#n)
| p_status | PLS_INTEGER | Final status of the process (freely selected by the calling package) | [`N`](#n)


> [!IMPORTANT]
> Since LILA utilizes high-performance buffering, calling `CLOSE_SESSION` is essential to ensure that all remaining data is flushed and securely written to the database. To prevent data loss during an unexpected application crash, ensure that CLOSE_SESSION is part of your exception handling:
  
```sql
EXCEPTION WHEN OTHERS THEN
    -- Flushes buffered data and logs the error state before terminating
    lila.close_session(
        p_process_id  => l_proc_id, 
        p_status      => -1,          -- Your custom error status code here
        p_processInfo => SQLERRM      -- Captures the Oracle error message
    );
    RAISE;
```

---
### Process Control
Documents the lifecycle of a process.

| Name               | Type      | Description                         | Scope
| ------------------ | --------- | ----------------------------------- | -------
| [`SET_PROCESS_STATUS`](#procedure-set_process_status) | Procedure | Sets the state of the log status | Process
| [`SET_STEPS_TODO`](#procedure-set_steps_todo) | Procedure | Sets the required number of actions | Process
| [`STEP_DONE`](#procedure-step_done) | Procedure | Increments the counter of completed steps | Process
| [`SET_STEPS_DONE`](#procedure-set_steps_todo) | Procedure | Sets the number of completed actions | Process
| [`GET_PROC_STEPS_DONE`](fFunction-get_proc_steps_done) | FUNCTION | Returns number of already finished steps | Process
| [`GET_PROC_STEPS_TODO`](fFunction-get_proc_steps_done) | FUNCTION | Returns number of steps to do
| [`GET_PROCESS_START`](#function-get_process_start) | FUNCTION | Returns time of process start
| [`GET_PROCESS_END`](#function-get_process_end) | FUNCTION | Returns time of process end (if finished)
| [`GET_PROCESS_STATUS`](#function-get_process_status) | FUNCTION | Returns the process state
| [`GET_PROCESS_INFO`](#function-get_process_info) | FUNCTION | Returns info text about process
| [`GET_PROCESS_DATA`](#function-get_process_data) | FUNCTION | Returns all process data as a record (see below) 

**Procedures (Setter)**
  
#### Procedure SET_PROCESS_STATUS
The process status provides information about the overall state of the process. This integer value is not evaluated by LILA; its meaning depends entirely on the specific application scenario.

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
  PROCEDURE SET_STEPS_DONE(
    p_processId     NUMBER
  )
 ```

#### Procedure SET_STEPS_DONE
Sets the total number of completed steps. Note: Calling this procedure overwrites any progress previously calculated via `STEP_DONE`.

 ```sql
  PROCEDURE SET_STEPS_DONE(
    p_processId     NUMBER,
    p_stepsDone     PLS_INTEGER
  )
 ```

> [!NOTE]
> Whenever a record in the master table is changed, the `last_update field` is updated implicitly. This mechanism is designed to support the monitoring features.

**Parameters**

| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_processStatus | PLS_INTEGER | information about the overall state of the process | [`O`](#o)
| p_stepsToDo | PLS_INTEGER | Number of work steps that would have been necessary for complete processing. This value must be managed by the calling package | [`N`](#n)
| p_stepsDone | PLS_INTEGER | Number of work steps that were actually processed. This value must be managed by the calling package | [`N`](#n)
| p_processInfo | VARCHAR2 | Final information about the process (e.g., a readable status) | [`N`](#n)
| p_status | PLS_INTEGER | Final status of the process (freely selected by the calling package) | [`N`](#n)

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
Reads the numerical status of a process. The status values are not part of the LILA specification.

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
> For this purpose, the function `GET_PROCESS_DATA` provides a record containing all relevant process data 'in one go'. This record serves as the exclusive way to retrieve the process name and the tab_name_master attribute. Following LILA's naming convention, the detail table's name is deterministic: it always uses the master table's name as a prefix, followed by the suffix `_DETAIL`.

 ```sql
  FUNCTION GET_PROCESS_DATA(
    p_processId     NUMBER
  )
 ```

**Returns**
* Type: t_process_rec
* Description: Record type containing all essential process metrics. 


#### Record Type `t_process_rec`
Usefull for getting a complete set of all process data. Using this record avoids multiple individual API calls.

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
---
### Logging
Likely the most intuitive methods for a developer...
In this regard, please also refer to the table [# Log Level](#log-level) in the appendix. It provides details on which severity levels are considered—and thus logged—at each activated log level.
For convenience, the configurable log levels are also declared as constants within the LILA package. You can find them in the appendix under [# Declaration of Log Levels](#declaration-of-log-levels).

| Name               | Type      | Description                         | Scope
| ------------------ | --------- | ----------------------------------- | -------
| [`INFO`](#general-logging-procedures) | Procedure | Writes INFO log entry  | Detail Logging
| [`DEBUG`](#general-logging-procedures) | Procedure | Writes DEBUG log entry  | Detail Logging
| [`WARN`](#general-logging-procedures) | Procedure | Writes WARN log entry  | Detail Logging
| [`ERROR`](#general-logging-procedures) | Procedure | Writes ERROR log entry | Detail Logging

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
Writes a log entry with severity DEBUG. By default, LILA operates 'silently,' meaning it does not raise exceptions to avoid disrupting the main process. However, when log level DEBUG is activated, caught exceptions will be re-thrown.

 ```sql
  PROCEDURE LOG(
    p_processId     NUMBER,
    p_logText       VARCHAR2
  )
 ```


**Parameters**


---
### Metrics
#### Setting Values
#### Querying Values

---
### Server Control

| [`PROCEDURE IS_ALIVE`](#procedure-is-alive) | Procedure | Excecutes a very simple logging session | Test



### Write Logs related Procedures
#### General Logging Procedures
The detailed log entries in *detail table* are written using various procedures.
Depending on the log level corresponding to the desired entry, the appropriate procedure is called.

The procedures have the same signatures and differ only in their names.
Their descriptions are therefore summarized below.


| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_stepInfo | VARCHAR2 | Free text with information about the process | [`M`](#m)

**Syntax and Examples**
```sql
-- Syntax
---------
PROCEDURE ERROR(p_processId NUMBER, p_stepInfo VARCHAR2)
PROCEDURE WARN(p_processId NUMBER, p_stepInfo VARCHAR2)
PROCEDURE INFO(p_processId NUMBER, p_stepInfo VARCHAR2)
PROCEDURE DEBUG(p_processId NUMBER, p_stepInfo VARCHAR2)

-- Usage
--------
-- assuming that gProcessId is the global stored process ID

-- write an error
lila.error(gProcessId, 'Something happened');
-- write a debug information
lila.debug(gProcessId, 'Function was called');
```

#### Procedure LOG_DETAIL
Writes a LOG entry, regardless of the currently set LOG level.

| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_stepInfo | VARCHAR2 | Free text with information about the process | [`M`](#m)
| p_logLevel | NUMBER | This log level is written into the detail table | [`M`](#m)

**Syntax and Examples**
```sql
-- Syntax
---------
PROCEDURE LOG_DETAIL(p_processId NUMBER, p_stepInfo VARCHAR2, p_logLevel NUMBER);

-- Usage
--------
-- assuming that gProcessId is the global stored process ID

-- write a log record
lila.log_detail(gProcessId, 'I ignore the log level');
```
### Testing
Independent to other Packages you can check if LILA works in general.

#### Procedure IS_ALIVE
Creates one entry in the *master table* and one in the *detail table*.

This procedure needs no parameters.
```sql
-- execute the following statement in sql window
execute lila.is_alive;
-- check data and note the process_id
select * from lila_log where process_name = 'LILA Life Check';
-- check details using the process_id
select * from lila_log_detail where process_id = <process id>;
```

## Appendix
### Log Level
Depending on the selected log level, additional information is written to the *detail table*.
        
To do this, the selected log level must be >= the level implied in the logging call.
* logLevelSilent -> No details are written to the *detail table*
* logLevelError  -> Calls to the ERROR() procedure are taken into account
* logLevelWarn   -> Calls to the WARN() and ERROR() procedures are taken into account
* logLevelInfo   -> Calls to the INFO(), WARN(), and ERROR() procedures are taken into account
* logLevelDebug  -> Calls to the DEBUG(), INFO(), WARN(), and ERROR() procedures are taken into account

If you want to suppress any logging, set logLevelSilent as active log level.

#### Declaration of Log Levels
To simplify usage and improve code readability, constants for the log levels are declared in the specification (lila.pks).

```sql
logLevelSilent  constant number := 0;
logLevelError   constant number := 1;
logLevelWarn    constant number := 2;
logLevelInfo    constant number := 4;
logLevelDebug   constant number := 8;
```

### Record Type for init
TYPE t_session_init IS RECORD (
    processName VARCHAR2(100),
    logLevel PLS_INTEGER,
    stepsToDo PLS_INTEGER,
    daysToKeep PLS_INTEGER,
    tabNameMaster VARCHAR2(100) DEFAULT 'LILA_LOG'
);
