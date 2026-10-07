create or replace PACKAGE LILAM AS
    /* Complete Doc and last version see https://github.com/dirkgermany/LILA/docs */
    LILAM_VERSION constant varchar2(20) := 'v2.0';

    -- =====================================
    -- JSON as VARCHAR2 for max. performance
    -- =====================================
    SUBTYPE JSON_OBJ_LILAM IS VARCHAR2(8000);

    -- =========
    -- Log Level
    -- =========
    -- Configure logging rules using the constants below
    logLevelSilent      CONSTANT PLS_INTEGER := 0; -- SILENT
    logLevelError       CONSTANT PLS_INTEGER := 1; -- ERROR
    logLevelWarn        CONSTANT PLS_INTEGER := 2; -- WARN
    logLevelMonitor     CONSTANT PLS_INTEGER := 3; -- MONITOR
    logLevelInfo        CONSTANT PLS_INTEGER := 4; -- INFO
    logLevelDebug       CONSTANT PLS_INTEGER := 8; -- DEBUG

    -- ==================
    -- Codes and Messages
    -- ==================
    TXT_ACK_OK          CONSTANT VARCHAR2(30) := 'SERVER_ACK_OK';
    NUM_ACK_OK          CONSTANT PLS_INTEGER  := 1000;
    TXT_ACK_DECLINE     CONSTANT VARCHAR2(30) := 'SERVER_ACK_DECLINE';
    NUM_ACK_DECLINE     CONSTANT PLS_INTEGER  := 1001;
    TXT_ERR_NO_SERVER   CONSTANT VARCHAR2(30) := 'NO SERVER FOUND';
    NUM_ERR_NO_SERVER   CONSTANT PLS_INTEGER  := -20001;
    TXT_ERR_UNKNOWN     CONSTANT VARCHAR2(30) := 'UNKNOWN_ERROR';
    NUM_ERR_UNKNOWN     CONSTANT PLS_INTEGER  := -20002;
    TXT_COMM_ERR        CONSTANT VARCHAR2(30) := 'INTERNAL COMMUNICATION ERROR';
    NUM_COMM_ERR        CONSTANT PLS_INTEGER  := -20003;
    TXT_ERR_ILLEGAL_REQ CONSTANT VARCHAR2(30) := 'ILLEGAL_REQUEST';
    NUM_ERR_ILLEGAL_REQ CONSTANT PLS_INTEGER  := -20010;
    TXT_ACK_SHUTDOWN    CONSTANT VARCHAR2(30) := 'SERVER_ACK_SHUTDOWN';
    NUM_ACK_SHUTDOWN    CONSTANT PLS_INTEGER  := 1010;
    TXT_PING_ECHO       CONSTANT VARCHAR2(30) := 'PING_ECHO';
    NUM_PING_ECHO       CONSTANT PLS_INTEGER  := 100;
    TXT_SERVER_INFO     CONSTANT VARCHAR2(30) := 'SERVER_INFO';
    NUM_SERVER_INFO     CONSTANT PLS_INTEGER  := 101;
    TXT_DATA_ANSWER     CONSTANT VARCHAR2(30) := 'SERVER_DATA_ANSWER';
    NUM_DATA_ANSWER     CONSTANT VARCHAR2(30) := 102;
    TXT_ERR_PIPE_SERVER CONSTANT VARCHAR2(30) := 'SERVER_AT_PIPE_INVALID';
    NUM_ERR_PIPE_SERVER CONSTANT PLS_INTEGER  := -20020;
    TXT_ACK_SERVER_PROC CONSTANT VARCHAR2(30) := 'PROCESS_AT_SERVER_VALID';
    NUM_ACK_SERVER_PROC CONSTANT PLS_INTEGER  := 220;
    TXT_ERR_SERVER_PROC CONSTANT VARCHAR2(30) := 'PROCESS_AT_SERVER_INVALID';
    NUM_ERR_SERVER_PROC CONSTANT PLS_INTEGER  := -20021;
    -- Return values of SERVER_NEW_SESSION / SERVER_NEW_SESSION_JSON if no process could be created.
    -- No exception is raised; all further API calls with this ID are silently ignored.
    TXT_ERR_SESSION_TIMEOUT   CONSTANT VARCHAR2(30) := 'SESSION_TIMEOUT';
    NUM_ERR_SESSION_TIMEOUT   CONSTANT PLS_INTEGER  := -20110;  -- Server did not respond in time
    TXT_ERR_SESSION_THROTTLED CONSTANT VARCHAR2(30) := 'SESSION_THROTTLED';
    NUM_ERR_SESSION_THROTTLED CONSTANT PLS_INTEGER  := -20120;  -- Server rejected (overload)
    -- SERVER_UPDATE_RULES: rule set is missing for the group or is invalid (exception with reason)
    TXT_ERR_RULE_SET          CONSTANT VARCHAR2(30) := 'RULE_SET_REJECTED';
    NUM_ERR_RULE_SET          CONSTANT PLS_INTEGER  := -20130;
    -- Communication error during creation: NUM_COMM_ERR (-20003)

    -- Performance levels of a LILAM server (parameter p_perfServer of CREATE_SERVER/START_SERVER).
    -- Value = messages per second and process that a client may send without coordinating with the server.
    -- Any other values are allowed; 0 = no throttling; NULL or < 0 = C_SERVER_PERF_MID (default).
    C_SERVER_PERF_LOW   CONSTANT PLS_INTEGER  := 500;
    C_SERVER_PERF_MID   CONSTANT PLS_INTEGER  := 1500;
    C_SERVER_PERF_HIGH  CONSTANT PLS_INTEGER  := 2500;

    -- SUFFIXES of the three main tables
    C_SUFFIX_PROC_TABLE  CONSTANT varchar2(6)  := '_PROC'; -- Process
    C_SUFFIX_LOG_TABLE   CONSTANT varchar2(6)  := '_LOG';  -- Logging
    C_SUFFIX_MON_TABLE   CONSTANT varchar2(6)  := '_MON';  -- Monitoring
    C_LILAM_RULES_TABLE  CONSTANT VARCHAR2(16) := 'LILAM_RULES';
    C_LILAM_ALERTS_TABLE CONSTANT VARCHAR2(16) := 'LILAM_ALERTS';

    -- ================================
    -- Record representing process data
    -- ================================
    TYPE t_process_rec IS RECORD (
        id             NUMBER(19,0),
        processName    VARCHAR2(100),
        logLevel       PLS_INTEGER,
        processStart   TIMESTAMP,
        processEnd     TIMESTAMP,
        lastUpdate     TIMESTAMP,
        stepsTodo      PLS_INTEGER,
        stepsDone      PLS_INTEGER,
        status         PLS_INTEGER,
        info           VARCHAR2(4000),
        procImmortal   PLS_INTEGER := 0,
        tabNameMaster  VARCHAR2(100)
    );

    -- ================================
    -- Record representing session data
    -- ================================
    TYPE t_session_init IS RECORD (
        processName     VARCHAR2(100),
        logLevel        PLS_INTEGER := logLevelMonitor,
        stepsToDo       PLS_INTEGER,
        daysToKeep      PLS_INTEGER,    -- NULL = no automatic deletion of old process data
        procImmortal    PLS_INTEGER := 0,
        tabNameMaster   VARCHAR2(100) DEFAULT 'LILAM',
        baselineScope   VARCHAR2(100),  -- NULL = process name (cross-process), '#NONE' = per process only
        groupName       VARCHAR2(50),   -- INSESSION: group for the active rule set from LILAM_RULES; NULL = no rules
        syncLevel       PLS_INTEGER := logLevelError  -- Entries up to this level are written synchronously (logLevelSilent = none)
    );

    -- ==============================
    -- Structure of table LILAM_ALERTS
    -- ==============================
    TYPE t_alert_rec IS RECORD (
        alert_id            NUMBER,
        process_id          NUMBER,
        master_table_name   VARCHAR2(50),
        monitor_table_name  VARCHAR2(50),
        action_name         VARCHAR2(50),
        context_name        VARCHAR2(50),
        action_count        PLS_INTEGER,
        rule_set_name       VARCHAR2(50),
        rule_id             VARCHAR2(50),
        rule_set_version    PLS_INTEGER,
        alert_severity      VARCHAR2(50)
    );

    -- ==============================
    -- Alerts for activating consumer
    -- ==============================
    C_ALERT_MAIL_LOG CONSTANT VARCHAR2(30) := 'LILAM_ALERT_MAIL_LOG';


    ------------------------------
    -- Life cycle of a log session
    ------------------------------
    FUNCTION  NEW_SESSION(p_session_init t_session_init) RETURN NUMBER;
    FUNCTION  NEW_SESSION(
        p_processName   VARCHAR2,
        p_logLevel      PLS_INTEGER DEFAULT logLevelMonitor,
        p_procStepsToDo PLS_INTEGER DEFAULT NULL,
        p_daysToKeep    PLS_INTEGER DEFAULT NULL,
        p_tabNameMaster VARCHAR2    DEFAULT 'LILAM',
        p_baselineScope VARCHAR2    DEFAULT NULL,
        p_groupName     VARCHAR2    DEFAULT NULL,
        p_syncLevel     PLS_INTEGER DEFAULT logLevelError) RETURN NUMBER;

    FUNCTION  SERVER_NEW_SESSION(
        p_processName   VARCHAR2,
        p_groupName     VARCHAR2    DEFAULT NULL,
        p_logLevel      PLS_INTEGER DEFAULT logLevelMonitor,
        p_procStepsToDo PLS_INTEGER DEFAULT NULL,
        p_daysToKeep    PLS_INTEGER DEFAULT NULL,
        p_tabNameMaster VARCHAR2    DEFAULT 'LILAM',
        p_baselineScope VARCHAR2    DEFAULT NULL,
        p_syncLevel     PLS_INTEGER DEFAULT logLevelError) RETURN NUMBER;
    FUNCTION  SERVER_NEW_SESSION_JSON(p_jsonObject JSON_OBJ_LILAM) RETURN NUMBER;

    PROCEDURE CLOSE_SESSION(
        p_processId     NUMBER,
        p_processInfo   VARCHAR2    DEFAULT NULL,
        p_processStatus PLS_INTEGER DEFAULT NULL,
        p_procStepsDone PLS_INTEGER DEFAULT NULL,
        p_procStepsToDo PLS_INTEGER DEFAULT NULL);

    ---------------------------------
    -- Update the status of a process
    ---------------------------------
    PROCEDURE SET_PROCESS_STATUS(p_processId NUMBER, p_status PLS_INTEGER, p_processInfo VARCHAR2 DEFAULT NULL);
    PROCEDURE SET_PROC_STEPS_TODO(p_processId NUMBER, p_procStepsToDo NUMBER);
    PROCEDURE SET_PROC_STEPS_DONE(p_processId NUMBER, p_procStepsDone NUMBER);
    PROCEDURE PROC_STEP_DONE(p_processId NUMBER);
    PROCEDURE SET_PROC_IMMORTAL(p_processId NUMBER, p_immortal NUMBER);

    -------------------------------
    -- Request process informations
    -------------------------------
    FUNCTION  GET_PROC_STEPS_DONE(p_processId NUMBER) RETURN PLS_INTEGER;
    FUNCTION  GET_PROC_STEPS_TODO(p_processId NUMBER) RETURN PLS_INTEGER;
    FUNCTION  GET_PROCESS_START(p_processId NUMBER) RETURN TIMESTAMP;
    FUNCTION  GET_PROCESS_END(p_processId NUMBER) RETURN TIMESTAMP;
    FUNCTION  GET_PROCESS_STATUS(p_processId NUMBER) RETURN PLS_INTEGER;
    FUNCTION  GET_PROCESS_INFO(p_processId NUMBER) RETURN VARCHAR2;
    FUNCTION  GET_PROCESS_DATA(p_processId NUMBER) RETURN t_process_rec;
    FUNCTION  GET_PROCESS_DATA_JSON(p_processId NUMBER) return varchar2;
    FUNCTION  GET_COUNTER_WARN(p_processId NUMBER) return PLS_INTEGER;
    FUNCTION  GET_COUNTER_ERROR(p_processId NUMBER) return PLS_INTEGER;

    ------------------
    -- Logging details
    ------------------
    PROCEDURE INFO(p_processId NUMBER, p_logText VARCHAR2);
    PROCEDURE DEBUG(p_processId NUMBER, p_logText VARCHAR2);
    PROCEDURE WARN(p_processId NUMBER, p_logText VARCHAR2);
    PROCEDURE ERROR(p_processId NUMBER, p_logText VARCHAR2);

    -------------
    -- Monitoring
    -------------
    PROCEDURE MARK_EVENT(p_processId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2 default null, p_timestamp TIMESTAMP DEFAULT NULL);
    PROCEDURE TRACE_START(p_processId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2 default null, p_timestamp TIMESTAMP DEFAULT NULL);
    PROCEDURE TRACE_STOP(p_processId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2 default null, p_timestamp TIMESTAMP DEFAULT NULL);
    FUNCTION  GET_METRIC_AVG_DURATION(p_processId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2 default null) return NUMBER;
    FUNCTION  GET_METRIC_STEPS(p_processId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2 default null) return NUMBER;

    -----------------
    -- Server control
    -----------------
    FUNCTION  CREATE_SERVER(p_pipeName varchar2, p_groupName varchar2, p_password varchar2, p_isDispatcher PLS_INTEGER DEFAULT 0,
                            p_perfServer PLS_INTEGER DEFAULT NULL) RETURN VARCHAR2;
    PROCEDURE START_SERVER(p_pipeName varchar2, p_groupName varchar2, p_password varchar2, p_isDispatcher PLS_INTEGER DEFAULT 0,
                           p_perfServer PLS_INTEGER DEFAULT NULL);
    PROCEDURE SERVER_SHUTDOWN(p_processId number, p_pipeName varchar2, p_password varchar2);
    FUNCTION  GET_SERVER_PIPE(p_processId NUMBER) RETURN VARCHAR2;
    -- Activate a rule set for all servers of the group (dispatchers excluded); error => exception NUM_ERR_RULE_SET
    PROCEDURE SERVER_UPDATE_RULES(p_groupName VARCHAR2, p_ruleSetName VARCHAR2, p_ruleSetVersion PLS_INTEGER);
    -- Check a rule set without storing or activating it: NULL = valid, otherwise the reason (never raises)
    FUNCTION CHECK_RULE_SET(p_ruleSet CLOB) RETURN VARCHAR2;
    -- Dispatcher of this session. Default: used for NEW_SESSION without group or of the dispatcher's group (registry),
    -- other groups go to their own servers; p_groupName = group: only for NEW_SESSION of this group; p_pipeName NULL removes it
    PROCEDURE SET_DISPATCHER_PIPE(p_pipeName varchar2, p_groupName varchar2 DEFAULT 'DEFAULT_DISPATCHER', p_processId number DEFAULT null);


    PROCEDURE CALL_BY_JSON(p_callObject  IN  JSON_OBJECT_T, p_respObject  OUT JSON_OBJECT_T);
    PROCEDURE CALL_BY_JSON(p_callObject  IN  JSON_OBJ_LILAM, p_respObject  OUT JSON_OBJ_LILAM);

    ---------
    -- Flush
    ---------
    -- Writes all buffered data of this database session immediately; the processes stay open
    PROCEDURE FLUSH;

    ----------
    -- Testing
    ----------
    -- Check if LILAM works
    PROCEDURE IS_ALIVE;

END LILAM;

/
