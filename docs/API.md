# LILA API
<details>
<summary>Content</summary>

- [Functions and Procedures](#functions-and-procedures)
  - [Session related Functions and Procedures](#session-related-functions-and-procedures)
    - [Function NEW_SESSION](#function-new_session)
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

    
## Functions and Procedures

### List of Functions and Procedures

| Name               | Type      | Description                         | Scope
| ------------------ | --------- | ----------------------------------- | -------
| [`NEW_SESSION`](#function-new_session) | Function  | Opens a new log session; **Mandatory** | Log Session
| [`CLOSE_SESSION`](#procedure-close_session) | Procedure | Ends a log session; **Mandatory** | Log Session
| [`SET_PROCESS_STATUS`](#procedure-set_process_status) | Procedure | Sets the state of the log status | Log Session
| [`SET_STEPS_TODO`](#procedure-set_steps_todo) | Procedure | Sets the required number of actions | Log Session
| [`SET_STEPS_DONE`](#procedure-set_steps_todo) | Procedure | Sets the number of completed actions | Log Session
| [`STEP_DONE`](#procedure-step_done) | Procedure | Increments the counter of completed steps | Log Session
| [`INFO`](#general-logging-procedures) | Procedure | Writes INFO log entry               | Detail Logging
| [`DEBUG`](#general-logging-procedures) | Procedure | Writes DEBUG log entry              | Detail Logging
| [`WARN`](#general-logging-procedures) | Procedure | Writes WARN log entry               | Detail Logging
| [`ERROR`](#general-logging-procedures) | Procedure | Writes ERROR log entry              | Detail Logging
| [`LOG_DETAIL`](#procedure-log_detail) | Procedure | Writes log entry with any log level | Detail Logging
| [`PROCEDURE IS_ALIVE`](#procedure-is-alive) | Procedure | Excecutes a very simple logging session | Test


### Shortcuts for parameter requirement
* <a id="M"> **M**andatory</a>
* <a id="O"> **O**ptional</a>
* <a id="N"> **N**ullable</a>

### Session related Functions and Procedures
Whenever the record in the *master table* is changed, the value of the field last_update will be updated.
This mechanism is supports the monitoring features.

#### Function NEW_SESSION
The NEW_SESSION function starts the logging session for a process. This procedure must be called first. Calls to the API without a prior NEW_SESSION do not make sense or can (theoretically) lead to undefined states.
Various function signatures are available for different scenarios. For the NEW_SESSION call exists a dedicated Type:

##### Record Type for init
TYPE t_session_init IS RECORD (
    processName VARCHAR2(100),
    logLevel PLS_INTEGER,
    stepsToDo PLS_INTEGER,
    daysToKeep PLS_INTEGER,
    tabNameMaster VARCHAR2(100) DEFAULT 'LILA_LOG'
);

\
*Option 1*
| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processName | VARCHAR2| freely selectable name for identifying the process; is written to *master table* | [`M`](#m)
| p_logLevel | NUMBER | determines the level of detail in *detail table* (see above) | [`M`](#m)
| p_TabNameMaster | VARCHAR2 | optional prefix of the LOG table names (see above) | [`O`](#o)

\
*Option 2*
| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processName | VARCHAR2| freely selectable name for identifying the process; is written to *master table* | [`M`](#m)
| p_logLevel | NUMBER | determines the level of detail in *detail table* (see above) | [`M`](#m)
| p_daysToKeep | NUMBER | max. age of entries in days; if not NULL, all entries older than p_daysToKeep and whose process name = p_processName (not case sensitive) are deleted | [`N`](#n)
| p_TabNameMaster | VARCHAR2 | optional prefix of the LOG table names (see above) | [`O`](#o)

\
*Option 3*
| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processName | VARCHAR2| freely selectable name for identifying the process; is written to *master table* | [`M`](#m)
| p_logLevel | NUMBER | determines the level of detail in *detail table* (see above) | [`M`](#m)
| p_stepsToDo | NUMBER | defines how many steps must be done during the process | [`M`](#m)
| p_daysToKeep | NUMBER | max. age of entries in days; if not NULL, all entries older than p_daysToKeep and whose process name = p_processName (not case sensitive) are deleted | [`N`](#n)
| p_TabNameMaster | VARCHAR2 | optional prefix of the LOG table names (see above) | [`O`](#o)

**Returns**
Type: NUMBER
Description: The new process ID; this ID is required for subsequent calls in order to be able to assign the LOG calls to the process

**Syntax and Examples**
```sql
-- Syntax
---------
FUNCTION NEW_SESSION(p_processName VARCHAR2, p_logLevel NUMBER, p_TabNameMaster VARCHAR2 DEFAULT 'LILA_LOG')
FUNCTION NEW_SESSION(p_processName VARCHAR2, p_logLevel NUMBER, p_daysToKeep NUMBER, p_TabNameMaster VARCHAR2 DEFAULT 'LILA_LOG')
FUNCTION NEW_SESSION(p_processName VARCHAR2, p_logLevel NUMBER, p_stepsToDo NUMBER, p_daysToKeep NUMBER, p_TabNameMaster VARCHAR2 DEFAULT 'LILA_LOG')

-- Usage
--------
-- Option 1
-- No deletion of old entries, log table name is 'LILA_LOG'
gProcessId := lila.new_session('my application', lila.logLevelWarn);
-- nearly the same but log table name is 'MY_LOG_TABLE'
gProcessId := lila.new_session('my application', lila.logLevelWarn, 'MY_LOG_TABLE');

-- Option 2
-- keep entries which are not older than 30 days
gProcessId := lila.new_session('my application', lila.logLevelWarn, 30);
-- use another log table name
gProcessId := lila.new_session('my application', lila.logLevelWarn, 30, 'MY_LOG_TABLE');

-- Option 3
-- with 100 steps to do and 30 days keeping old entries
gProcessId := lila.new_session('my application', lila.logLevelWarn, 100, 30);
-- the same but dedicated log table
gProcessId := lila.new_session('my application', lila.logLevelWarn, 100, 30, 'MY_LOG_TABLE');
```

#### Procedure CLOSE_SESSION
Ends a logging session with optional final informations. Four function signatures are available for different scenarios.
* Option 1 is a simple close without any additional information about the process.
* Option 2-4 allows adding various informations to the ending process.

**Persistence & Error Handling**

Since LILA utilizes high-performance buffering, calling CLOSE_SESSION is essential to ensure that all remaining data is flushed and securely written to the database. To prevent data loss during an unexpected application crash, ensure that CLOSE_SESSION is part of your exception handling:
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

*Option 1*
| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)

\
*Option 2*
| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_processInfo | VARCHAR2 | Final information about the process (e.g., a readable status) | [`N`](#n)
| p_status | NUMBER | Final status of the process (freely selected by the calling package) | [`N`](#n)

\
*Option 3*
| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_stepsDone | NUMBER | Number of work steps that were actually processed. This value must be managed by the calling package | [`N`](#n)
| p_processInfo | VARCHAR2 | Final information about the process (e.g., a readable status) | [`N`](#n)
| p_status | NUMBER | Final status of the process (freely selected by the calling package) | [`N`](#n)

\
*Option 4*
| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_stepsToDo | NUMBER | Number of work steps that would have been necessary for complete processing. This value must be managed by the calling package | [`N`](#n)
| p_stepsDone | NUMBER | Number of work steps that were actually processed. This value must be managed by the calling package | [`N`](#n)
| p_processInfo | VARCHAR2 | Final information about the process (e.g., a readable status) | [`N`](#n)
| p_status | NUMBER | Final status of the process (freely selected by the calling package) | [`N`](#n)

\
**Syntax and Examples**
```sql
-- Syntax
---------
-- Option 1
PROCEDURE CLOSE_SESSION(p_processId NUMBER)
-- Option 2
PROCEDURE CLOSE_SESSION(p_processId NUMBER, p_processInfo VARCHAR2, p_status NUMBER)
-- Option 3
PROCEDURE CLOSE_SESSION(p_processId NUMBER, p_stepsDone NUMBER, p_processInfo VARCHAR2, p_status NUMBER)
-- Option 4
PROCEDURE CLOSE_SESSION(p_processId NUMBER, p_stepsToDo NUMBER, p_stepsDone NUMBER, p_processInfo VARCHAR2, p_status NUMBER)


-- Usage
--------
-- assuming that gProcessId is the global stored process ID

-- Option 1
-- close without any information (e.g. when be set with SET_PROCESS_STATUS before)
lila.close_session(gProcessId);

\
-- Option 2
-- close with information about process status
lila.close_session(gProcessId, 'Success', 1);

\
-- Option 3
-- close includes number of steps done
lila.close_session(gProcessId, 99, 'Problem', 2);

\
-- Option 4
-- close with additional informations about steps to do and steps done
lila.close_session(gProcessId, 100, 99, 'Problem', 2);
```


#### Procedure SET_PROCESS_STATUS
Updates the status of a process.

As mentioned at the beginning, there is only one entry in the *master table* for a logging session and the corresponding process.
The status of the process can be set using the following two variants:

*Option 1 without info as text*
| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_status | NUMBER | Current status of the process (freely selected by the calling package) | [`M`](#m)

*Option 2 with additional info as text*
| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_status | NUMBER | Current status of the process (freely selected by the calling package) | [`M`](#m)
| p_processInfo | VARCHAR2 | Current information about the process (e.g., a readable status) | [`M`](#m)

**Syntax and Examples**
```sql
-- Syntax
---------
-- Option 1
PROCEDURE SET_PROCESS_STATUS(p_processId NUMBER, p_status NUMBER)
-- Option 2
PROCEDURE SET_PROCESS_STATUS(p_processId NUMBER, p_status NUMBER, p_processInfo VARCHAR2)

-- Usage
--------
-- assuming that gProcessId is the global stored process ID

-- updating only by a status represented by a number
lila.set_process_status(gProcessId, 1);
-- updating by using an additional information
lila.set_process_status(gProcessId, 1, 'OK');
```

#### Procedure SET_STEPS_TODO
Updates the number of required steps during the process in the log entry of the *master table*.

| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_stepsToDo | NUMBER | defines how many steps must be done during the process | [`M`](#m)

**Syntax and Examples**
```sql
-- Syntax
---------
PROCEDURE SET_STEPS_TODO(p_processId NUMBER, p_stepsToDo NUMBER)

-- Usage
--------
-- assuming that gProcessId is the global stored process ID

-- updating only by a status represented by a number
lila.set_steps_todo(gProcessId, 100);
```

#### Procedure SET_STEPS_DONE
Updates the number of completed steps during the process in the log entry of the *master table*.

| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_stepsDone | NUMBER | shows how many steps of the process are already completed | [`M`](#m)

**Syntax and Examples**
```sql
-- Syntax
---------
PROCEDURE SET_STEPS_DONE(p_processId NUMBER, p_stepsDone NUMBER)

-- Usage
--------
-- assuming that gProcessId is the global stored process ID

-- updating only by a status represented by a number
lila.set_steps_done(gProcessId, 99);
```

#### Procedure STEP_DONE
Increments the number of already completed steps in the log entry of the *master table*.

| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)

**Syntax and Examples**
```sql
-- Syntax
---------
PROCEDURE STEP_DONE(p_processId NUMBER)

-- Usage
--------
-- assuming that gProcessId is the global stored process ID

-- something like a trigger
lila.step_done(gProcessId);
```

### Write Logs related Procedures
#### General Logging Procedures
The detailed log entries in *detail table* are written using various procedures.
Depending on the log level corresponding to the desired entry, the appropriate procedure is called.

The procedures have the same signatures and differ only in their names.
Their descriptions are therefore summarized below.

* Procedure ERROR: details are written if the debug level is one of
  - logLevelError
  - logLevelWarn
  - logLevelInfo
  - logLevelDebug
* Procedure WARN: details are written if the debug level is one of
  - logLevelWarn
  - logLevelInfo
  - logLevelDebug
* Procedure INFO: details are written if the debug level is one of
  - logLevelInfo
  - logLevelDebug
* Procedure DEBUG: details are written if the debug level is one of
  - logLevelDebug

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
