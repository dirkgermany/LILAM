create or replace PACKAGE BODY LILAM
AS
    /*
     * LILAM
     * Dual-licensed under GPLv3 or Commercial License.
     * See LICENSE or LICENSE_ENTERPRISE for details.
     */

    ---------------------------------------------------------------
    -- Tuning Parameter for development
    ---------------------------------------------------------------

    -- Dedicated to SERVER_LOOP
    C_SERVER_SYNC_INTERVAL_MS          CONSTANT PLS_INTEGER := 500;
    C_SERVER_HEARTBEAT_INTERVAL_MS     CONSTANT PLS_INTEGER := 60000;
    C_SERVER_MAX_LOOPS_IN_TIME_NO      CONSTANT PLS_INTEGER := 10000; -- 1000
    C_SERVER_TIMEOUT_WAIT_FOR_MSG_SEC  CONSTANT NUMBER      := 0.2; -- Timeout in seconds when waiting for a message
    C_SERVER_TIMEOUT_MAX_WAIT_SEC      CONSTANT NUMBER      := 5;
    C_MAX_SERVER_PIPE_SIZE             CONSTANT PLS_INTEGER := 16777216; --  16777216, 67108864
    
    C_MAX_REGISTRY_HEARTBEAT_AGE_SEC   CONSTANT PLS_INTEGER  := 15;  --  Server HEARTBEAT in Registry mustn't be older

    -- Dedicated to Client
    -- Client throttling: the limit per process comes from the server (p_perfServer, see C_SERVER_PERF_*)
    C_THROTTLE_INTERVAL_NO             CONSTANT PLS_INTEGER := 1000; -- Time window in ms for the limit

    -- Max Dirty Buffers and 
    C_FLUSH_MILLIS_THRESHOLD_MS        CONSTANT PLS_INTEGER := 1500;  -- 1500 Max. Millis until flush
    C_FLUSH_LOG_THRESHOLD_NO           CONSTANT PLS_INTEGER := 50000; -- 50000 Max. number of dirty buffered logs until flush
    C_FLUSH_MONITOR_THRESHOLD_NO       CONSTANT PLS_INTEGER := 50000; -- 50000 Max. number of dirty buffered metrics until flush
    C_SYNC_ALL_INTERVAL_MS             CONSTANT PLS_INTEGER := 500;   -- SYNC_ALL_DIRTY (without force) at most every n ms

    -- INSESSION: check for a changed active rule set of the group at most every n ms
    -- (triggered by API calls; servers are notified via SERVER_UPDATE_RULES)
    C_RULES_CHECK_INTERVAL_MS          CONSTANT PLS_INTEGER := 15000;

    ---------------------------------------------------------------
    -- Placeholders for tables
    ---------------------------------------------------------------
    C_PARAM_MASTER_TABLE            CONSTANT varchar2(20) := 'PH_MASTER_TABLE';
    C_PARAM_LOG_TABLE               CONSTANT varchar2(20) := 'PH_LOG_TABLE';
    C_PARAM_MON_TABLE               CONSTANT varchar2(20) := 'PH_MON_TABLE';
    C_LILAM_SERVER_REGISTRY         CONSTANT VARCHAR2(50) := 'LILAM_SERVER_REGISTRY';
    C_LILAM_LOG_TABLE               CONSTANT VARCHAR2(20) := 'LILAM_LOG_INTERNAL';
    C_LILAM_PROCESS_ROUTE           CONSTANT VARCHAR2(50) := 'LILAM_PROCESS_ROUTE';
    C_LILAM_SCOPES_TABLE            CONSTANT VARCHAR2(30) := 'LILAM_SCOPES';
    C_LILAM_BASELINES_TABLE         CONSTANT VARCHAR2(30) := 'LILAM_BASELINES';

    ---------------------------------------------------------------
    -- Other general Parameters
    ---------------------------------------------------------------
    C_TIMEOUT_NEW_SESSION_SEC           CONSTANT NUMBER      := 3.0;  -- NEW_SESSION max. time waiting for server response
    C_METRIC_ALERT_FACTOR_SEC           CONSTANT NUMBER      := 2.0;   -- Max. outlier in the duration of a processing step
    C_MAX_LOG_TEXT_LEN                  CONSTANT PLS_INTEGER := 1900;  -- Log texts are always truncated to this length (column INFO: 2000)

    -- Baseline scopes (cross-process averages)
    -- t_session_init.baselineScope:  NULL    => scope = process name (default)
    --                                '#NONE' => no scope, average per process only
    --                                else    => freely chosen scope name
    C_SCOPE_NONE                        CONSTANT VARCHAR2(20) := '#NONE';
    C_SCOPE_RESERVED_PREFIX             CONSTANT VARCHAR2(1)  := '#';      -- '#...' is reserved for LILAM
    C_BASELINE_NULL_CONTEXT             CONSTANT VARCHAR2(1)  := '-';      -- Replacement for NULL context in the PK
    C_BASELINE_SYNC_INTERVAL_MS         CONSTANT PLS_INTEGER  := 1500;     -- Sync PGA <-> LILAM_BASELINES
    C_BASELINE_IDLE_EVICT_SEC           CONSTANT PLS_INTEGER  := 900;      -- Remove unused baselines from the PGA

    -- Pipe handling
    C_PIPE_ID_PENDING               CONSTANT BINARY_INTEGER := -1; 
    -- Control pipe per server/dispatcher: <PIPE>_CTL. Receives NEW_SESSION so that creating a process
    -- does not have to wait behind the data messages of the data pipe (replaces the old, unused '_INTERLEAVE').
    C_CTL_PIPE_SUFFIX               CONSTANT VARCHAR2(20)   := '_CTL';
    C_MAX_CTL_PIPE_SIZE             CONSTANT PLS_INTEGER    := 1048576;

    ---------------------------------------------------------------
    -- Kind of Monitor Entries
    ---------------------------------------------------------------
    C_MON_TYPE_EVENT                CONSTANT PLS_INTEGER := 0; -- Simple event, no stop-time
    C_MON_TYPE_TRACE                CONSTANT PLS_INTEGER := 1; -- Transaction with start and stop
    C_MON_TYPE_LOG                  CONSTANT PLS_INTEGER := 2; -- Placeholder without sense

    ---------------------------------------------------------------
    -- Sessions
    ---------------------------------------------------------------
    -- Record representing the internal session
    -- Per started process one session
    TYPE t_session_rec IS RECORD (
        process_id          NUMBER(19,0),
        serial_no           PLS_INTEGER := 0,
        log_level           PLS_INTEGER := 0,
        monitoring          PLS_INTEGER := 0,
        last_monitor_flush  TIMESTAMP, -- Time of the last monitor flush
        last_log_flush      TIMESTAMP(6), -- Time of the last log flush
        monitor_dirty_count PLS_INTEGER := 0,  -- monitor entries per process counter
        log_dirty_count     PLS_INTEGER := 0,  -- Logs per process counter
        process_is_dirty    BOOLEAN,
        last_process_flush  TIMESTAMP(6),
        last_sync_check     TIMESTAMP(6),
        group_name          VARCHAR2(50),  -- Group as specified (server: server group), for alerts
        rule_group          VARCHAR2(50),  -- upper(group_name): key of the rules; NULL = no rules
        tabName_master      VARCHAR2(100),
        scope_id            NUMBER(19,0),  -- NULL = no cross-process scope
        sync_level          PLS_INTEGER := 1  -- logLevelError: entries up to this level are written synchronously
    );

    -- Table for several processes
    TYPE t_session_tab IS TABLE OF t_session_rec;
    g_sessionList t_session_tab := null;

    -- Indexes for lists
    TYPE t_idx IS TABLE OF PLS_INTEGER INDEX BY BINARY_INTEGER;
    v_indexSession t_idx;

    -- Private list in memory (PGA)
    -- Index is the session ID, value is arbitrary (here Boolean)
    TYPE t_remote_sessions IS TABLE OF BOOLEAN INDEX BY BINARY_INTEGER;
    g_remote_sessions t_remote_sessions;
    -- Client side: what the server reported for a remote process (NEW_SESSION/RECONNECT).
    -- Needed to write entries up to sync_level directly, without waiting for the server.
    TYPE t_remote_sync_rec IS RECORD (
        log_level       PLS_INTEGER,
        sync_level      PLS_INTEGER
    );
    TYPE t_remote_sync_tab IS TABLE OF t_remote_sync_rec INDEX BY BINARY_INTEGER;
    g_remote_sync t_remote_sync_tab;
    C_NO_DIRECT_WRITE CONSTANT PLS_INTEGER := -1;  -- Column NO of log entries written directly by the client
    -- Master table of directly written entries: always LILAM (=> LILAM_LOG) in the schema of the calling
    -- LILAM installation, independent of the work table and of the schema the server runs in.
    C_DIRECT_WRITE_MASTER CONSTANT VARCHAR2(10) := 'LILAM';
    -- IDs for which a reconnect via the dispatcher failed, with the time of the next allowed
    -- attempt. Prevents every call with an unknown ID from querying the dispatcher synchronously again.
    TYPE t_unknown_pids IS TABLE OF TIMESTAMP INDEX BY BINARY_INTEGER;
    g_unknown_pids t_unknown_pids;

    TYPE t_throttle_stat IS RECORD (
        msg_count  PLS_INTEGER := 0,
        last_check TIMESTAMP    := SYSTIMESTAMP,
        msg_limit  PLS_INTEGER := 1500  -- Messages per time window; 0 = no throttling (value from the server)
    );
    TYPE t_throttle_tab IS TABLE OF t_throttle_stat INDEX BY BINARY_INTEGER;
    g_local_throttle_cache t_throttle_tab;

    ---------------------------------------------------------------
    -- Common type for monitoring and process
    ---------------------------------------------------------------
    TYPE t_eval_context_rec IS RECORD (
        -- common data
        process_id    NUMBER(19,0),
        action_name   VARCHAR2(100),
        context_name  VARCHAR2(100),
        start_time    TIMESTAMP(6),
        stop_time     TIMESTAMP(6),
        -- Monitoring fields
        used_time     NUMBER,
        action_count  PLS_INTEGER,
        avg_time      NUMBER,         -- Reference average BEFORE this measurement (NULL during warm-up)
        -- Process-specific fields
        process_end   TIMESTAMP,
        last_update   TIMESTAMP,
        steps_todo    PLS_INTEGER,
        steps_done    PLS_INTEGER,
        status        PLS_INTEGER,
        info          VARCHAR2(4000)
    );

    ---------------------------------------------------------------
    -- Processes
    ---------------------------------------------------------------
    TYPE t_process_cache_map IS TABLE OF t_process_rec INDEX BY PLS_INTEGER;
    g_process_cache t_process_cache_map;

    ---------------------------------------------------------------
    -- Monitoring
    ---------------------------------------------------------------
    TYPE t_monitor_buffer_rec IS RECORD (
        process_id      NUMBER(19,0),
        action_name     VARCHAR2(100),
        context_name    VARCHAR2(100),
        monitor_type    PLS_INTEGER,
        avg_action_time NUMBER,             -- Renamed
        start_time      TIMESTAMP(6),          -- Start time of the action
        stop_time       TIMESTAMP(6),          -- Stop time of the action
        used_time       NUMBER,             -- Duration of the last execution (in sec.)
        action_count   PLS_INTEGER := 0,   -- Work step of an action / transaction (per process)
        baseline_avg    NUMBER              -- Average BEFORE this measurement, reference for rules (not persisted)
    );
    TYPE t_monitor_history_tab IS TABLE OF t_monitor_buffer_rec;    
    TYPE t_monitor_map IS TABLE OF t_monitor_history_tab INDEX BY VARCHAR2(200);
    g_monitor_groups t_monitor_map;
    TYPE t_monitor_shadow_map IS TABLE OF t_monitor_buffer_rec INDEX BY VARCHAR2(200);
    g_monitor_shadows t_monitor_shadow_map;
    g_monitor_averages t_monitor_shadow_map;

    -- Cross-process baselines (scope)
    -- avg_ms/action_count: current state in the PGA
    -- base_avg/base_count: state at the last load/sync with LILAM_BASELINES (for delta merge)
    TYPE t_baseline_rec IS RECORD (
        scope_id        NUMBER(19,0),
        action_name     VARCHAR2(100),
        context_name    VARCHAR2(100),
        avg_ms          NUMBER,
        action_count    NUMBER := 0,
        base_avg        NUMBER,
        base_count      NUMBER := 0,
        in_db           BOOLEAN := FALSE,
        dirty           BOOLEAN := FALSE,
        last_touch_cs   NUMBER          -- last use (DBMS_UTILITY.GET_TIME), for eviction
    );
    TYPE t_baseline_map IS TABLE OF t_baseline_rec INDEX BY VARCHAR2(250);
    g_baselines t_baseline_map;
    g_last_baseline_sync TIMESTAMP(6);

    -- Cache scope name -> scope ID
    TYPE t_scope_id_map IS TABLE OF NUMBER INDEX BY VARCHAR2(100);
    g_scope_ids t_scope_id_map;

    -- Master tables whose tables have already been checked/created in this session
    TYPE t_checked_masters IS TABLE OF BOOLEAN INDEX BY VARCHAR2(100);
    g_checked_masters t_checked_masters;
    -- PERFORMANCE: result of DBMS_ASSERT.SQL_OBJECT_NAME per table name (otherwise costs approx. 0.4 ms per flush)
    TYPE t_safe_tables IS TABLE OF VARCHAR2(150) INDEX BY VARCHAR2(150);
    g_safe_tables t_safe_tables;

    -- Last event or trace per process (predecessor for PRECEDED_BY); logs do not count
    TYPE t_action_history_rec IS RECORD (
        action_name  VARCHAR2(100),
        context_name VARCHAR2(100),
        stop_time    TIMESTAMP
    );
    TYPE t_last_action_map IS TABLE OF t_action_history_rec INDEX BY PLS_INTEGER; 
    g_last_action_per_process t_last_action_map;

    ---------------------------------------------------------------
    -- Logging
    ---------------------------------------------------------------
    TYPE t_log_buffer_rec IS RECORD (
        process_id      NUMBER(19,0),
        log_level       PLS_INTEGER,
        log_text        VARCHAR2(4000),
        log_time        TIMESTAMP(6),
        serial_no       PLS_INTEGER,
        caller          VARCHAR2(200),
        err_stack       VARCHAR2(4000),
        err_backtrace   VARCHAR2(4000),
        err_callstack   VARCHAR2(4000)
    );

    -- The list for bulk storage
    -- The flat list of log entries
    TYPE t_log_history_tab IS TABLE OF t_log_buffer_rec;

    -- The main object for logs: 
    -- Key is the process_id (converted to a string for the map)
    TYPE t_log_map IS TABLE OF t_log_history_tab INDEX BY VARCHAR2(100);
    g_log_groups t_log_map;

    TYPE t_dirty_queue IS TABLE OF BOOLEAN INDEX BY BINARY_INTEGER;
    g_dirty_queue t_dirty_queue;

    -- Time precision
    TYPE t_timestamp_list_t IS TABLE OF TIMESTAMP(6);

    -- PERFORMANCE: collection buffer for the bundled flush in SYNC_ALL_DIRTY (see flushBatch)
    TYPE t_log_batch_rec IS RECORD (
        pids       sys.odcinumberlist   := sys.odcinumberlist(),
        seqs       sys.odcinumberlist   := sys.odcinumberlist(),
        levels     sys.odcinumberlist   := sys.odcinumberlist(),
        levelsC    sys.odcivarchar2list := sys.odcivarchar2list(),
        texts      sys.odcivarchar2list := sys.odcivarchar2list(),
        times      t_timestamp_list_t   := t_timestamp_list_t(),
        callers    sys.odcivarchar2list := sys.odcivarchar2list(),
        stacks     sys.odcivarchar2list := sys.odcivarchar2list(),
        backtraces sys.odcivarchar2list := sys.odcivarchar2list(),
        callstacks sys.odcivarchar2list := sys.odcivarchar2list()
    );
    TYPE t_log_batches IS TABLE OF t_log_batch_rec INDEX BY VARCHAR2(150);

    TYPE t_mon_batch_rec IS RECORD (
        pids         sys.odcinumberlist   := sys.odcinumberlist(),
        actions      sys.odcivarchar2list := sys.odcivarchar2list(),
        contexts     sys.odcivarchar2list := sys.odcivarchar2list(),
        mon_types    sys.odcinumberlist   := sys.odcinumberlist(),
        action_count sys.odcinumberlist   := sys.odcinumberlist(),
        used         sys.odcinumberlist   := sys.odcinumberlist(),
        avgs         sys.odcinumberlist   := sys.odcinumberlist(),
        timesStart   t_timestamp_list_t   := t_timestamp_list_t(),
        timesStop    t_timestamp_list_t   := t_timestamp_list_t()
    );
    TYPE t_mon_batches IS TABLE OF t_mon_batch_rec INDEX BY VARCHAR2(150);

    TYPE t_proc_batch_rec IS RECORD (
        ids        sys.odcinumberlist   := sys.odcinumberlist(),
        status     sys.odcinumberlist   := sys.odcinumberlist(),
        procEnd    t_timestamp_list_t   := t_timestamp_list_t(),
        stepsTodo  sys.odcinumberlist   := sys.odcinumberlist(),
        stepsDone  sys.odcinumberlist   := sys.odcinumberlist(),
        info       sys.odcivarchar2list := sys.odcivarchar2list(),
        immortal   sys.odcinumberlist   := sys.odcinumberlist()
    );
    TYPE t_proc_batches IS TABLE OF t_proc_batch_rec INDEX BY VARCHAR2(150);  -- Key: master table

    g_batch_mode    BOOLEAN := FALSE;
    g_log_batches   t_log_batches;
    g_mon_batches   t_mon_batches;
    g_proc_batches  t_proc_batches;


    ---------------------------------------------------------------
    -- Rules
    ---------------------------------------------------------------
    -- Type definition for the rule details (from the JSON)
    TYPE t_rule_rec IS RECORD (
        rule_id             VARCHAR2(50),
        trigger_type        VARCHAR2(50),  -- TRACE_STOP, MARK_EVENT
        target_action       VARCHAR2(100),
        target_context      VARCHAR2(100),
        condition_metric    VARCHAR2(50),
        condition_operator  VARCHAR2(50),  -- MAX_DURATION_MS, PRECEDED_BY, etc.
        condition_value     VARCHAR2(250),
        alert_handler       VARCHAR2(30),  -- Name of the DBMS_ALERT signal (max. 30 characters)
        alert_severity      VARCHAR2(30),
        throttle_seconds    NUMBER,        -- Wait until the next alert
        -- PERFORMANCE: values prepared at load time (no conversion per signal)
        cond_num            NUMBER,        -- Numeric value (NLS-independent), e.g. limit in ms
        cond_action         VARCHAR2(100), -- PRECEDED_BY*: expected predecessor action
        cond_context        VARCHAR2(100), -- PRECEDED_BY*: expected context (NULL = any)
        cond_upper          VARCHAR2(100)  -- SEVERITY, INFO_CONTAINS: value in upper case
    );
    TYPE t_rule_list IS TABLE OF t_rule_rec;
    TYPE t_rule_map IS TABLE OF t_rule_list INDEX BY VARCHAR2(300);

    -- Rules of all loaded groups. Key: GROUP|ACTION or GROUP|ACTION|CONTEXT
    -- (GROUP = rule_group of the session). Server: only its own group; INSESSION: every group
    -- that was specified with NEW_SESSION in this DB session.
    g_rules_by_context t_rule_map;
    g_rules_by_action  t_rule_map;

    -- State per group (key: rule_group)
    TYPE t_rule_group_rec IS RECORD (
        set_name     VARCHAR2(30),      -- loaded rule set (for alerts); NULL = no rules
        set_version  NUMBER := 0,
        seen_name    VARCHAR2(30),      -- last seen active rule set, even if rejected
        seen_version NUMBER,            -- (a rejected set is not parsed again on every check)
        last_check_cs NUMBER            -- INSESSION: last check for a changed active rule set (DBMS_UTILITY.GET_TIME)
    );
    TYPE t_rule_group_map IS TABLE OF t_rule_group_rec INDEX BY VARCHAR2(50);
    g_rule_groups t_rule_group_map;

    TYPE t_avg_params IS RECORD (
        alpha    NUMBER := 0.1,
        warmup   PLS_INTEGER := 100
    );
    -- Key as for the rules with group; 'DEFAULT' applies to all
    TYPE t_avg_params_map IS TABLE OF t_avg_params INDEX BY VARCHAR2(300);
    g_avg_params t_avg_params_map;

    TYPE t_alert_history IS TABLE OF TIMESTAMP INDEX BY VARCHAR2(250);
    g_alert_history t_alert_history;

    ----------
    -- TRIGGER
    ----------
    -- Process
    C_PROCESS_START    CONSTANT VARCHAR2(20) := 'PROCESS_START';
    C_PROCESS_UPDATE   CONSTANT VARCHAR2(20) := 'PROCESS_UPDATE';
    C_PROCESS_STOP     CONSTANT VARCHAR2(20) := 'PROCESS_STOP';

    -- ACTIONS and TRANSACTIONS
    C_MARK_EVENT       CONSTANT VARCHAR2(20) := 'MARK_EVENT';
    C_TRACE_START      CONSTANT VARCHAR2(20) := 'TRACE_START';
    C_TRACE_STOP       CONSTANT VARCHAR2(20) := 'TRACE_STOP';
    
    -- Logging
    C_LOGGING          CONSTANT VARCHAR2(20) := 'LOGGING';

    ---------------------------------------------------------------
    -- Automated load balancing
    ---------------------------------------------------------------

    -- Table of the clients and the pipes they use
    TYPE t_client_pipe IS TABLE OF VARCHAR2(128) INDEX BY BINARY_INTEGER;
    g_client_pipes t_client_pipe;
    g_dispatch_route_cache t_client_pipe;
    
    TYPE t_dispatcher_map IS TABLE OF VARCHAR2(50) INDEX BY VARCHAR2(50);
    g_dispatcher_config t_dispatcher_map;

    ---------------------------------------------------------------
    -- General Variables
    ---------------------------------------------------------------
    -- Exclusive SessionId for Logging internal Errors or Warnings
    g_lilamSessionId                    NUMBER := -1; -- -1 as Flag for not initialized
    
    -- Counters of ERROR and WARN calls per process (in the session that makes the calls)
    TYPE t_log_counter_rec IS RECORD (
        errors   PLS_INTEGER := 0,
        warnings PLS_INTEGER := 0
    );
    TYPE t_log_counter_map IS TABLE OF t_log_counter_rec INDEX BY PLS_INTEGER;
    g_log_counters                      t_log_counter_map;

    -- ALERT Registration
    g_isAlertRegistered                 BOOLEAN := false;

    TYPE code_map_t IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(30);
    g_response_codes code_map_t;

    g_serverPipeName                    VARCHAR2(50)            := NULL;
    g_serverProcessId                   PLS_INTEGER             := -1;
    g_serverGroupName                   VARCHAR2(50)            := NULL;
    g_shutdownPassword                  varchar2(50);
    g_serverIsDispatcher                BOOLEAN                 := FALSE;

    g_server_perf                       PLS_INTEGER             := C_SERVER_PERF_MID;  -- Performance level of this server (p_perfServer)
    g_last_sync_all_cs                  NUMBER                  := NULL;   -- last run of SYNC_ALL_DIRTY (DBMS_UTILITY.GET_TIME)
    g_last_check_time                   TIMESTAMP               := SYSTIMESTAMP;

    -- Latencies between event generation and persistance in DB
    g_firstLogTimeStamp                 TIMESTAMP               := NULL;
    g_oldestLogTimeStamp                TIMESTAMP               := NULL;
    g_avgLatencyLogs                    NUMBER                  := 0;
    g_maxLatencyLogs                    NUMBER                  := 0;
    g_logLatencyCounter                 NUMBER                  := 0;

    g_firstMonTimeStamp                 TIMESTAMP               := NULL;
    g_oldestMonTimeStamp                TIMESTAMP               := NULL;
    g_avgLatencyMon                     NUMBER                  := 0;
    g_maxLatencyMon                     NUMBER                  := 0;
    g_monLatencyCounter                 NUMBER                  := 0;
    ---------------------------------------------------------------
    -- Functions and Procedures
    ---------------------------------------------------------------
    function getSessionRecord(p_processId number) return t_session_rec;
    procedure sync_log(p_processId number, p_force boolean default false);
    procedure sync_monitor(p_processId number, p_force boolean default false);
    procedure sync_process(p_processId number, p_force boolean default false);
    procedure flushMonitor(p_processId number);
    procedure flushBatch;
    procedure touchServerRegistry;
    function getServerPipeAvailable(p_groupName varchar2) return varchar2;
    procedure createInternalLogTable;
    FUNCTION SERVER_LINK(p_processId NUMBER, p_pipeName varchar2) RETURN NUMBER;
    procedure refreshGroupRules(p_group varchar2, p_force boolean);
    ------------------------------------------------------------------------
    
    ---------------------------------------------------------------
    -- Fallback Logging
    ---------------------------------------------------------------
    PROCEDURE logLilamErr(p_errCode varchar2, p_errMessage varchar2, p_moduleName varchar2 default 'UNKNOWN', p_logOperation varchar2 default 'UNKNONW')
    AS
        pragma autonomous_transaction;
        l_stmt varchar2(4000);
    BEGIN
        createInternalLogTable;
        l_stmt := '
            insert into ' || C_LILAM_LOG_TABLE || '
            (
                error_code,
                error_message,
                error_stack,
                error_backtrace,
                call_stack,
                module_name,
                log_operation
            )
            values
            (
                :1, :2, :3, :4, :5, :6, :7
            )';
    
        execute immediate l_stmt using
                coalesce(p_errCode, sqlcode),
                substr(coalesce(p_errMessage, sqlerrm), 1, 4000),
                substr(dbms_utility.format_error_stack,     1, 4000),
                substr(dbms_utility.format_error_backtrace, 1, 4000),
                substr(dbms_utility.format_call_stack,      1, 4000),
                substr(p_moduleName,   1, 200),
                substr(p_logOperation, 1, 200);                
                
        commit;            
            
    EXCEPTION
        when others then
        begin
            dbms_output.enable();
            dbms_output.put_line('LILAM INTERNAL ERROR in Procedure logLilamErr: ' || substr(sqlErrM, 1, 1000));
        end;
    END;

    ------------------------------------------------------------------------


    ---------------------------------------------------------------
    -- Unify response codes consistently
    ---------------------------------------------------------------
    PROCEDURE initialize_map IS
    BEGIN
        if g_response_codes.COUNT = 0 THEN
            g_response_codes(TXT_ACK_SHUTDOWN)    := NUM_ACK_SHUTDOWN;
            g_response_codes(TXT_ACK_OK)          := NUM_ACK_OK;
            g_response_codes(TXT_ACK_DECLINE)     := NUM_ACK_DECLINE;
            g_response_codes(TXT_PING_ECHO)       := NUM_PING_ECHO;
            g_response_codes(TXT_SERVER_INFO)     := NUM_SERVER_INFO;
            g_response_codes(TXT_DATA_ANSWER)     := NUM_DATA_ANSWER;
            g_response_codes(TXT_ERR_NO_SERVER)   := NUM_ERR_NO_SERVER;
            g_response_codes(TXT_ERR_ILLEGAL_REQ) := NUM_ERR_ILLEGAL_REQ;
            g_response_codes(TXT_ERR_UNKNOWN)     := NUM_ERR_UNKNOWN;
            g_response_codes(TXT_ACK_SERVER_PROC) := NUM_ACK_SERVER_PROC;
            g_response_codes(TXT_ERR_SERVER_PROC) := NUM_ERR_SERVER_PROC;
        end if ;
    END initialize_map;

    --------------------------------------------------------------------------
    
    function logLevelToEnum(p_level number) return varchar2
    as
    begin
        case p_level
            when logLevelSilent     then return 'SILENT';
            when logLevelError       then return 'ERROR';
            when logLevelWarn        then return 'WARN';
            when logLevelMonitor     then return 'MONITOR';
            when logLevelInfo        then return 'INFO';
            when logLevelDebug       then return 'DEBUG';
        end case;
    end;

    --------------------------------------------------------------------------

    FUNCTION get_serverCode(p_txt VARCHAR2) RETURN PLS_INTEGER IS
    BEGIN
        initialize_map; -- Ensures that the map is filled

        if g_response_codes.EXISTS(p_txt) THEN
            RETURN g_response_codes(p_txt);
        ELSE
            RETURN -1; -- Or raise an exception
        end if ;
    END;

    ---------------------------------------------------------------
    -- Normalize performance level: NULL or < 0 = MID (default), 0 = no throttling, otherwise the value itself
    ---------------------------------------------------------------
    FUNCTION normPerf(p_perf PLS_INTEGER) RETURN PLS_INTEGER IS
    BEGIN
        IF p_perf IS NULL OR p_perf < 0 THEN
            RETURN C_SERVER_PERF_MID;
        END IF;
        RETURN p_perf;
    END;

    ---------------------------------------------------------------
    -- Set the throttling limit for a process (value from the server's response
    -- to NEW_SESSION or RECONNECT_PROCESS). Replaces SET_HIGH_PERFORMANCE / g_is_high_perf.
    ---------------------------------------------------------------
    PROCEDURE setPerfLimit(p_processId NUMBER, p_perf PLS_INTEGER) IS
        l_rec t_throttle_stat;
    BEGIN
        IF g_local_throttle_cache.EXISTS(p_processId) THEN
            g_local_throttle_cache(p_processId).msg_limit := normPerf(p_perf);
        ELSE
            l_rec.msg_limit := normPerf(p_perf);
            g_local_throttle_cache(p_processId) := l_rec;
        END IF;
    END;

    ---------------------------------------------------------------
    -- Detect whether a process runs on a server
    ---------------------------------------------------------------
    FUNCTION is_remote(p_processId IN NUMBER) RETURN BOOLEAN IS
        l_dispatcherPipe varchar2(80);
        l_result         number;
    BEGIN
        IF g_remote_sessions.EXISTS(p_processId) THEN
            RETURN TRUE;
        END IF;
    
        IF v_indexSession.EXISTS(p_processId) THEN
            RETURN FALSE; -- real local in-session process
        END IF;

        -- Invalid ID (e.g. NUM_ERR_SESSION_TIMEOUT from SERVER_NEW_SESSION): never a reconnect attempt
        IF p_processId IS NULL OR p_processId <= 0 THEN
            RETURN FALSE;
        END IF;
    
        -- Known neither locally nor as remote: automatic reconnect attempt,
        -- but only if a dispatcher has been configured
        IF NOT g_dispatcher_config.EXISTS('DEFAULT_DISPATCHER') THEN
            RETURN FALSE;
        END IF;

        -- Reconnect for this ID failed recently: do not query synchronously again
        -- (otherwise every call with an outdated ID waits for the dispatcher)
        IF g_unknown_pids.EXISTS(p_processId) THEN
            IF g_unknown_pids(p_processId) > systimestamp THEN
                RETURN FALSE;
            END IF;
            g_unknown_pids.DELETE(p_processId);
        END IF;
    
        l_dispatcherPipe := g_dispatcher_config('DEFAULT_DISPATCHER');
        l_result := SERVER_LINK(p_processId, l_dispatcherPipe);
        IF l_result = p_processId THEN
            RETURN TRUE;
        END IF;

        -- Server does not know the process (final): remember for this session.
        -- No server reachable / timeout (temporary): retry only after 10 s.
        g_unknown_pids(p_processId) := CASE WHEN l_result = NUM_ERR_SERVER_PROC
                                            THEN systimestamp + INTERVAL '1' DAY
                                            ELSE systimestamp + INTERVAL '10' SECOND END;
        RETURN FALSE;
    
    EXCEPTION
        WHEN OTHERS THEN
            logLilamErr(sqlCode, sqlErrM, 'is_remote');
            RETURN FALSE;
    END is_remote;
    
    ------------------------------------------------------------------------

    function jsonObject(p_jsonString varchar2, p_path varchar2) return varchar2
    as
    begin
            return JSON_QUERY(p_jsonString, '$.' || p_path);
    end;

    --------------------------------------------------------------------------

    function jsonString(p_json_doc varchar2, jsonPath varchar2) return varchar2
    as
    begin
        return JSON_VALUE(p_json_doc, '$.' || jsonPath);
    end;

    --------------------------------------------------------------------------

    function jsonNumber(p_json_doc varchar2, jsonPath varchar2) return number
    as
    begin
        return JSON_VALUE(p_json_doc, '$.' || jsonPath returning NUMBER);
    exception 
        when others then
        logLilamErr(sqlCode, sqlErrM, 'jsonNumber', 'JSON_VALUE');
        return null;
    end;

    --------------------------------------------------------------------------

    function extractFromJsonObjTime(p_obj JSON_OBJECT_T, p_key VARCHAR2) RETURN TIMESTAMP
    as
    BEGIN
        RETURN TO_TIMESTAMP(p_obj.get_string(p_key), 'YYYY-MM-DD"T"HH24:MI:SS.FF');
    EXCEPTION 
        WHEN OTHERS THEN
        logLilamErr(sqlCode, sqlErrM, 'extractFromJsonObjTime', 'RETURN TO_TIMESTAMP');
        return null;
    END;

    --------------------------------------------------------------------------

    function jsonTime(p_json_doc varchar2, jsonPath varchar2) return TIMESTAMP
    as
    begin
        return JSON_VALUE(p_json_doc, '$.' || jsonPath returning TIMESTAMP);
    exception 
        when others then
        logLilamErr(sqlCode, sqlErrM, 'jsonTime', 'JSON_VALUE');
        return null;
    end;

    ------------------------------------------------------------------------

    function jsonPutPrep(p_jsonString varchar2) return varchar2
    as
        l_str JSON_OBJ_LILAM;  -- previously varchar2(1000): longer messages (e.g. log texts) were silently lost
    begin
        l_str := p_jsonString;
        if trim(l_str) is null then
            return null;
        end if;
        l_str := trim(l_str);
        if substr(l_str, 1,1) =  '{' then
            l_str := substr(l_str, 2);
            l_str := substr(l_str, 1, length(l_str)-1);
        end if;
        if length(l_str) > 0 then
            l_str := l_str || ', ';
        end if;
        return l_str;
    end;

    ------------------------------------------------------------------------

    procedure jsonPut(p_jsonString in out JSON_OBJ_LILAM, jsonKey in varchar2, valueStr in varchar2)
    -- Attention! The IF constructs are not pretty but considerably faster than CASE
    -- Working with a boolean value at the beginning also makes the logic much slower
    as
        l_str   JSON_OBJ_LILAM;
        l_value JSON_OBJ_LILAM := trim(valueStr);
    begin
        if valueStr is null or trim(valueStr) = '' then return; end if;

        if substr(l_value,1,1) != '{' and substr(l_value, -1) != '}' then
            -- Escape!
            l_value := REPLACE(l_value, '\', '\\'); -- backslash FIRST
            l_value := REPLACE(l_value, '"', '\"'); -- THEN quotation marks
            -- Optional: line breaks (JSON does not allow real line breaks in strings)
            l_value := REPLACE(l_value, CHR(10), '\n');
            l_value := REPLACE(l_value, CHR(13), '\r');
        end if;

        -- The result is always a complete JSON object, even on the first jsonPut
        -- (previously an empty p_jsonString with an object value produced only a fragment without braces)
        l_str := jsonPutPrep(p_jsonString);
        l_str := '{' || l_str || '"' || trim(jsonKey) || '":';
        if substr(l_value, 1, 1) != '{' then
            l_str := l_str || '"';
        end if;
        l_str := l_str || l_value; 
        if SUBSTR(l_value, -1) != '}' then
            l_str := l_str || '"}';
        else
            l_str := l_str || '}';
        end if;
        p_jsonString := l_str;
    end;

    -------------------------------------------------------------------------------------

    procedure jsonPut(p_jsonString in out varchar2, jsonKey varchar2, valueNum Number)
    as
        l_str JSON_OBJ_LILAM;
    begin
        if valueNum is null then return; end if;

        l_str := jsonPutPrep(p_jsonString);
        if p_jsonString is null and substr(valueNum, 1,1) = '{' and substr(valueNum, -1) = '}' then
            l_str := '"' || jsonKey || '": ' || valueNum;    
        else 
            l_str := '{' || l_str || '"' || trim(jsonKey) || '":';
            l_str := l_str || valueNum || '}'; 
        end if;
        p_jsonString := l_str;
    end;

    -------------------------------------------------------------------------------------

    procedure jsonPut(p_jsonString in out JSON_OBJ_LILAM, jsonKey varchar2, valueTS timestamp)
    as
    begin
        jsonPut(p_jsonString, jsonKey, TO_CHAR(valueTS, 'YYYY-MM-DD"T"HH24:MI:SS.FF6'));
    end;

    --------------------------------------------------------------------------
    -- PERFORMANCE: building blocks for the direct concatenation of JSON messages
    --
    -- jsonPut parses the object built so far on every call and copies it
    -- again. With 8-10 fields per message this was the largest cost block
    -- on the client side in decoupled mode (HPROF: 39 % for INFO, 47 % for MARK_EVENT).
    -- In the frequently used paths (logs, traces, events, steps, status)
    -- the message is therefore concatenated in ONE expression:
    --
    --     '{"process_id":' || jNum(p_processId) || jStr('action_name', p_actionName) || ... || '}'
    --
    -- Each building block returns ',"key":value' or - for NULL - an empty string.
    -- The first field is therefore always written without a building block and without a comma.
    -- The rarely used paths (server responses, administration) still
    -- use jsonPut.
    --------------------------------------------------------------------------

    -- Escape a text value for JSON (same rules as jsonPut, plus tab)
    function jEsc(p_value varchar2) return varchar2
    as
    begin
        return replace(replace(replace(replace(replace(p_value,
                   '\', '\\'),          -- backslash FIRST
                   '"', '\"'),
                   chr(10), '\n'),
                   chr(13), '\r'),
                   chr(9), '\t');
    end;

    -- Number independent of NLS_NUMERIC_CHARACTERS (always decimal point, leading 0)
    function jNum(p_value number) return varchar2
    as
        l_str varchar2(64);
    begin
        if p_value = trunc(p_value) then
            return to_char(p_value);       -- Integer: NLS does not matter (normal case)
        end if;
        l_str := to_char(p_value, 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,''');
        if substr(l_str, 1, 1) = '.' then
            l_str := '0' || l_str;
        elsif substr(l_str, 1, 2) = '-.' then
            l_str := '-0' || substr(l_str, 2);
        end if;
        return l_str;
    end;

    -- ',"key":"text"' or '' for NULL
    function jStr(p_key varchar2, p_value varchar2) return varchar2
    as
    begin
        if p_value is null then return null; end if;
        return ',"' || p_key || '":"' || jEsc(p_value) || '"';
    end;

    -- ',"key":number' or '' for NULL
    function jNum(p_key varchar2, p_value number) return varchar2
    as
    begin
        if p_value is null then return null; end if;
        return ',"' || p_key || '":' || jNum(p_value);
    end;

    -- ',"key":"YYYY-MM-DDTHH24:MI:SS.FF6"' or '' for NULL
    function jTs(p_key varchar2, p_value timestamp) return varchar2
    as
    begin
        if p_value is null then return null; end if;
        return ',"' || p_key || '":"' || to_char(p_value, 'YYYY-MM-DD"T"HH24:MI:SS.FF6') || '"';
    end;

    --------------------------------------------------------------------------
    -- PERFORMANCE: check the table name via DBMS_ASSERT only once per session.
    -- DBMS_ASSERT.SQL_OBJECT_NAME resolves the name in the data dictionary and cost
    -- 0.4 ms per call in the server profile (8 % of the server time in the mass test).
    -- The cache is cleared together with g_checked_masters (e.g. on ORA-00942).
    --------------------------------------------------------------------------
    function safeTableName(p_table varchar2) return varchar2
    as
    begin
        if not g_safe_tables.EXISTS(p_table) then
            g_safe_tables(p_table) := DBMS_ASSERT.SQL_OBJECT_NAME(p_table);
        end if;
        return g_safe_tables(p_table);
    end;

    --------------------------------------------------------------------------
    -- Millis between two timestamps
    --------------------------------------------------------------------------
    function get_ms_diff(p_start timestamp, p_end timestamp) return number is
        -- STABILITY: day(9) instead of day(0), otherwise ORA-01873 from a difference of one day (e.g. RUNTIME_EXCEEDED)
        v_diff interval day(9) to second(3); -- Limit precision to ms
    begin
        v_diff := p_end - p_start;
        -- We extract only the seconds including the fractional part (ms)
        -- and add the minutes/hours/days as multiples of seconds
        return (extract(day from v_diff) * 86400000)
             + (extract(hour from v_diff) * 3600000)
             + (extract(minute from v_diff) * 60000)
             + (extract(second from v_diff) * 1000);
    end;   

    --------------------------------------------------------------------------
    -- Calc Timestamp as key for requests 
    --------------------------------------------------------------------------
    function getClientPipe return varchar2
    as
    begin

    return 'LILAM->' || SYS_CONTEXT('USERENV', 'SID') || '-' || TO_CHAR(
        (EXTRACT(DAY FROM (sys_extract_utc(SYSTIMESTAMP) - TO_TIMESTAMP('1970-01-01', 'YYYY-MM-DD'))) * 86400000) + 
        TO_NUMBER(TO_CHAR(sys_extract_utc(SYSTIMESTAMP), 'SSSSSFF3')),
        'FM999999999999999'
    );
    end;

    --------------------------------------------------------------------------
    -- Name of the control pipe for a server/dispatcher pipe (by convention only, no administration)
    --------------------------------------------------------------------------
    function ctlPipe(p_pipeName varchar2) return varchar2
    as
    begin
        return upper(p_pipeName) || C_CTL_PIPE_SUFFIX;
    end;

    --------------------------------------------------------------------------
    -- Wake-up call into the data pipe: an idle server waits blocking on its data pipe
    -- (up to C_SERVER_TIMEOUT_MAX_WAIT_SEC) and would otherwise notice a message in the control pipe only
    -- after this wait time has expired. SERVER_PING has no further effect in the server.
    --------------------------------------------------------------------------
    procedure sendPing(p_pipeName varchar2)
    as
        l_status PLS_INTEGER;
    begin
        DBMS_PIPE.RESET_BUFFER;
        DBMS_PIPE.PACK_MESSAGE('{"header":{"msg_type":"API_CALL","request":"SERVER_PING"}}');
        l_status := DBMS_PIPE.SEND_MESSAGE(p_pipeName, timeout => 0);
    exception
        when others then
            DBMS_PIPE.RESET_BUFFER;   -- The wake-up call is only an aid, errors are not critical
    end;

    --------------------------------------------------------------------------
    -- Look for free Server-Pipe 
    --------------------------------------------------------------------------
    function getServerPipeForSession(p_processId number, p_groupName varchar2) return varchar2
    as
        l_serverPipe varchar2(50);
        l_key        BINARY_INTEGER;
    begin
        l_key := coalesce(p_processId, C_PIPE_ID_PENDING);
        -- 1. Cache check (PGA)
        IF g_client_pipes.EXISTS(p_processId) THEN
            RETURN g_client_pipes(p_processId);
        END IF;
    
        -- 2. Dispatcher takes precedence over the registry search, if configured
        IF g_dispatcher_config.EXISTS('DEFAULT_DISPATCHER') THEN
            l_serverPipe := g_dispatcher_config('DEFAULT_DISPATCHER');
        ELSE
            l_serverPipe := getServerPipeAvailable(p_groupName);
        END IF;
    
        if l_serverPipe is null then 
            RAISE_APPLICATION_ERROR(NUM_ERR_NO_SERVER, 'LILAM: Keinen aktiven Server gefunden.');
        end if;
        
        g_client_pipes(l_key) := l_serverPipe;
        return g_client_pipes(l_key);
    
    end;

    --------------------------------------------------------------------------
    -- Helper function (internal): creates the uniform key for the index
    --------------------------------------------------------------------------
    FUNCTION buildMonitorKey(p_processId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2) RETURN VARCHAR2 AS
    BEGIN
        -- Format: "0000000000000000180|MY_ACTION|MY_CONTEXT"
        -- LPAD ensures a fixed length, which speeds up filtering enormously
        RETURN LPAD(p_processId, 20, '0') || '|' || p_actionName || '|' || p_contextName;
    END;

    --------------------------------------------------------------------------
    -- Baseline scopes: cross-process averages
    --------------------------------------------------------------------------
    -- Key for g_baselines; same format as buildMonitorKey, but with scope_id
    FUNCTION buildBaselineKey(p_scopeId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2) RETURN VARCHAR2 AS
    BEGIN
        RETURN LPAD(p_scopeId, 20, '0') || '|' || p_actionName || '|' || p_contextName;
    END;

    --------------------------------------------------------------------------

    FUNCTION getScopeId(p_processId NUMBER) RETURN NUMBER AS
    BEGIN
        IF v_indexSession.EXISTS(p_processId) THEN
            RETURN g_sessionList(v_indexSession(p_processId)).scope_id;
        END IF;
        RETURN NULL;
    END;

    --------------------------------------------------------------------------

    PROCEDURE setScopeId(p_processId NUMBER, p_scopeId NUMBER) AS
    BEGIN
        IF v_indexSession.EXISTS(p_processId) THEN
            g_sessionList(v_indexSession(p_processId)).scope_id := p_scopeId;
        END IF;
    END;

    --------------------------------------------------------------------------
    -- Determines the scope name from t_session_init.baselineScope
    --   NULL    => process name
    --   '#NONE' => no scope (NULL)
    --   '#...'  => unknown reserved value: log it, use the process name
    --   else    => the specified name
    --------------------------------------------------------------------------
    FUNCTION resolveScopeName(p_processName VARCHAR2, p_baselineScope VARCHAR2) RETURN VARCHAR2
    AS
        l_scope VARCHAR2(100) := upper(trim(p_baselineScope));
    BEGIN
        IF l_scope IS NULL THEN
            RETURN upper(trim(p_processName));
        END IF;

        IF l_scope = C_SCOPE_NONE THEN
            RETURN NULL;
        END IF;

        IF substr(l_scope, 1, 1) = C_SCOPE_RESERVED_PREFIX THEN
            logLilamErr('-20030', 'Unknown reserved baseline scope ''' || l_scope || '''; using process name instead', 'resolveScopeName');
            RETURN upper(trim(p_processName));
        END IF;

        RETURN l_scope;
    EXCEPTION
        WHEN OTHERS THEN
            logLilamErr(sqlCode, sqlErrM, 'resolveScopeName');
            RETURN NULL;
    END;

    --------------------------------------------------------------------------
    -- Returns the scope_id for the name; creates the scope if necessary.
    -- Error => NULL (the session then works process-locally as before)
    --------------------------------------------------------------------------
    FUNCTION getOrCreateScopeId(p_scopeName VARCHAR2) RETURN NUMBER
    AS
        pragma autonomous_transaction;
        l_scopeId NUMBER;
        l_select  CONSTANT VARCHAR2(200) := 'select scope_id from ' || C_LILAM_SCOPES_TABLE || ' where scope_name = :1';
    BEGIN
        IF p_scopeName IS NULL THEN
            RETURN NULL;
        END IF;

        IF g_scope_ids.EXISTS(p_scopeName) THEN
            RETURN g_scope_ids(p_scopeName);
        END IF;

        BEGIN
            EXECUTE IMMEDIATE l_select INTO l_scopeId USING p_scopeName;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                BEGIN
                    EXECUTE IMMEDIATE 'insert into ' || C_LILAM_SCOPES_TABLE || ' (scope_name) values (:1) returning scope_id into :2'
                        USING p_scopeName RETURNING INTO l_scopeId;
                    COMMIT;
                EXCEPTION
                    WHEN DUP_VAL_ON_INDEX THEN
                        -- created in parallel by another session
                        ROLLBACK;
                        EXECUTE IMMEDIATE l_select INTO l_scopeId USING p_scopeName;
                END;
        END;

        g_scope_ids(p_scopeName) := l_scopeId;
        RETURN l_scopeId;

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            logLilamErr(sqlCode, sqlErrM, 'getOrCreateScopeId', p_scopeName);
            RETURN NULL;
    END;

    --------------------------------------------------------------------------
    -- Ensures that the baseline is in the PGA (lazy load, one PK access
    -- per scope/action/context). Errors are passed on to the caller.
    --------------------------------------------------------------------------
    PROCEDURE ensureBaseline(p_key VARCHAR2, p_scopeId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2)
    AS
        l_rec t_baseline_rec;
    BEGIN
        IF g_baselines.EXISTS(p_key) THEN
            RETURN;
        END IF;

        l_rec.scope_id     := p_scopeId;
        l_rec.action_name  := p_actionName;
        l_rec.context_name := p_contextName;

        BEGIN
            EXECUTE IMMEDIATE
                'select avg_ms, action_count from ' || C_LILAM_BASELINES_TABLE ||
                ' where scope_id = :1 and action_name = :2 and context_name = :3'
                INTO l_rec.avg_ms, l_rec.action_count
                USING p_scopeId, p_actionName, nvl(p_contextName, C_BASELINE_NULL_CONTEXT);
            l_rec.in_db := TRUE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                l_rec.avg_ms := NULL;
                l_rec.action_count := 0;
                l_rec.in_db := FALSE;
        END;

        l_rec.action_count := nvl(l_rec.action_count, 0);
        l_rec.base_avg     := l_rec.avg_ms;
        l_rec.base_count   := l_rec.action_count;
        l_rec.dirty        := FALSE;
        l_rec.last_touch_cs := dbms_utility.get_time;

        g_baselines(p_key) := l_rec;
    END;

    --------------------------------------------------------------------------
    -- Check if a single step needs more time than average over all steps per action
    --------------------------------------------------------------------------
    function validateDurationInAverage(p_monitor_rec t_monitor_buffer_rec, p_metricFactor number) return BOOLEAN
    as
    begin
        -- If there is no trend yet (initial start / warm-up), we cannot validate anything.
        if p_monitor_rec.avg_action_time is null or p_monitor_rec.avg_action_time = 0 
           or p_monitor_rec.used_time is null or p_metricFactor is null then
            return TRUE; 
        end if;

        -- Comparison against the existing trend
        -- Since p_old_ewma follows the trend during warm-up, 
        -- the 10% (or X%) threshold only applies once the EWMA has stabilized.
        if p_monitor_rec.used_time > p_monitor_rec.avg_action_time * (1 + p_metricFactor / 100) then
            return FALSE;
        end if;

        return TRUE;
    end;

    --------------------------------------------------------------------------

    -- Returns the n-th value from 'a|b|c' (e.g. AVG_DEVIATION_PCT: 'pct|warmup|alpha').
    -- Missing or invalid values => NULL (callers set defaults)
    FUNCTION extractRuleValue(p_param VARCHAR2, p_position PLS_INTEGER) return number
    AS
        l_val VARCHAR2(50);
    BEGIN
        l_val := TRIM(REGEXP_SUBSTR(p_param, '[^|]+', 1, p_position));
        if l_val is null then
            return null;
        end if;
        return to_number(l_val, '999999999999D9999999999', 'NLS_NUMERIC_CHARACTERS = ''. ''');
    EXCEPTION
        WHEN VALUE_ERROR OR INVALID_NUMBER THEN
            logLilamErr(sqlCode, 'Invalid rule value ''' || p_param || ''' at position ' || p_position, 'extractRuleValue');
            return null;
    END;

    -------------------------------------------------------
    -- Generate Action/Context - Key verifying Server Rules 
    -------------------------------------------------------
    FUNCTION buildRuleKey(p_action VARCHAR2, p_context VARCHAR2 := NULL) RETURN VARCHAR2 IS
    BEGIN
        IF p_context IS NOT NULL THEN
            RETURN p_action || '|' || p_context;
        ELSE
            RETURN p_action;
        END IF;
    END;

    ------------------------------------------------------------
    -- Write and signal the alert (own transaction, write-then-signal).
    -- TRUE if the alert was written.
    ------------------------------------------------------------
    FUNCTION persist_alert(p_rule t_rule_rec, p_rec t_monitor_buffer_rec) RETURN BOOLEAN IS
        pragma autonomous_transaction;
        v_idx_session   PLS_INTEGER;
        v_channel_name  VARCHAR2(30); -- max. length of Alert-Name
        v_payload       VARCHAR2(1000);
        v_sqlStmt       VARCHAR2(2000);
        v_alert_id      NUMBER;
        v_group         t_rule_group_rec;
    BEGIN
        v_idx_session := v_indexSession(p_rec.process_id);
        v_group       := g_rule_groups(g_sessionList(v_idx_session).rule_group);

        v_sqlStmt := '
        INSERT INTO ' || C_LILAM_ALERTS_TABLE || '(
            process_id, process_name, action_name, master_table_name, monitor_table_name, logging_table_name, context_name, action_count, 
            rule_set_name, rule_id, rule_set_version, alert_severity, handler_type, group_name
        ) VALUES (
            :1, :2, :3, :4, :5, :6, :7, :8, :9, :10, :11, :12, :13, :14
        ) RETURNING alert_id into :15';

        EXECUTE IMMEDIATE v_sqlStmt
        USING p_rec.process_id, g_process_cache(p_rec.process_id).processName, p_rec.action_Name, 
        g_sessionList(v_idx_session).tabName_master || C_SUFFIX_PROC_TABLE, g_sessionList(v_idx_session).tabName_master || C_SUFFIX_MON_TABLE,
        g_sessionList(v_idx_session).tabName_master || C_SUFFIX_LOG_TABLE, 
        p_rec.context_name, p_rec.action_count, v_group.set_name, p_rule.rule_id, v_group.set_version,
        p_rule.alert_severity, p_rule.alert_handler, g_sessionList(v_idx_session).group_name
        RETURNING INTO v_alert_id;

        v_payload := JSON_OBJECT(
            'alert_id'         VALUE v_alert_id,
            'process_id'       VALUE p_rec.process_id,
            'tab_name_process' VALUE g_sessionList(v_idx_session).tabName_master || C_SUFFIX_PROC_TABLE,
            'tab_name_monitor' VALUE g_sessionList(v_idx_session).tabName_master || C_SUFFIX_MON_TABLE,
            'tab_name_logging' VALUE g_sessionList(v_idx_session).tabName_master || C_SUFFIX_LOG_TABLE,
            'action_name'      VALUE p_rec.action_name,
            'context_name'     VALUE p_rec.context_name,
            'action_count'     VALUE p_rec.action_count,
            'group_name'       VALUE g_sessionList(v_idx_session).group_name,
            'rule_set_name'    VALUE v_group.set_name,
            'rule_id'          VALUE p_rule.rule_id,
            'rule_set_version' VALUE v_group.set_version,
            'alert_severity'   VALUE p_rule.alert_severity,
            'timestamp'        VALUE TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF6')
        );

        -- p_rule.alert_handler would be e.g. 'MAIL', 'REST', 'PROCESS' here
        v_channel_name := p_rule.alert_handler;
        dbms_alert.signal(v_channel_name, v_payload);
        COMMIT; -- !!!
        RETURN TRUE;

    exception
        when others then
        -- STABILITY: end the autonomous transaction, otherwise ORA-06519 on exit
        logLilamErr(sqlCode, sqlErrM, 'fire_alert', 'rule ' || p_rule.rule_id);
        rollback;
        RETURN FALSE;
    END;

    ------------------------------------------------------------
    -- Alert taking throttling into account (throttle_seconds).
    -- PERFORMANCE: throttling is checked here without an autonomous transaction;
    -- only an alert that is actually raised opens one.
    ------------------------------------------------------------
    PROCEDURE fire_alert(p_rule t_rule_rec, p_rec t_monitor_buffer_rec) IS
        v_throttle_sec  NUMBER := coalesce(p_rule.throttle_seconds, 0);
        v_scope_id      NUMBER;
        v_history_key   VARCHAR2(250);
    BEGIN
        IF v_throttle_sec <= 0 THEN
            -- without throttling no memory is needed
            IF persist_alert(p_rule, p_rec) THEN NULL; END IF;
            RETURN;
        END IF;

        -- Throttle per scope (if any), so that restarts do not lift the lock period.
        -- Group first: rule IDs are only unique per rule set (see also installGroupRules)
        v_scope_id    := getScopeId(p_rec.process_id);
        v_history_key := g_sessionList(v_indexSession(p_rec.process_id)).rule_group || '|'
                         || CASE WHEN v_scope_id IS NOT NULL THEN 'S' || v_scope_id ELSE 'P' || p_rec.process_id END
                         || '|' || p_rule.rule_id || '|' || p_rec.action_name;

        -- Lock period since the last alert has not yet expired -> do nothing
        IF g_alert_history.EXISTS(v_history_key)
           AND g_alert_history(v_history_key) + numtodsinterval(v_throttle_sec, 'SECOND') > SYSTIMESTAMP THEN
            RETURN;
        END IF;

        IF persist_alert(p_rule, p_rec) THEN
            g_alert_history(v_history_key) := SYSTIMESTAMP;
        END IF;
    exception
        when others then
        logLilamErr(sqlCode, sqlErrM, 'fire_alert', 'rule ' || p_rule.rule_id);
    END;
    
    ------------------------------------------------------------
    -- Match rules against an incoming event/trace
    -- Combined version for monitoring and process
    ------------------------------------------------------------  
    PROCEDURE evaluateRules_internal(p_ctx t_eval_context_rec, p_trigger VARCHAR2, p_check_context BOOLEAN)
    AS
        v_key       VARCHAR2(200);
        fire        BOOLEAN := FALSE;
        l_diff_ms   NUMBER := 0;
        p_monRec    t_monitor_buffer_rec; -- Helper variable for fire_alert
        l_group     VARCHAR2(50);

        -- Does the last predecessor (event/trace) of the process match the rule?
        -- cond_context NULL: any context of the expected action is allowed.
        FUNCTION predecessorMatches(p_rule t_rule_rec) RETURN BOOLEAN IS
        BEGIN
            RETURN NVL(g_last_action_per_process(p_ctx.process_id).action_name = p_rule.cond_action
               AND (p_rule.cond_context IS NULL
                    OR g_last_action_per_process(p_ctx.process_id).context_name = p_rule.cond_context), FALSE);
        END;

        PROCEDURE apply_rule_list(p_list t_rule_list) IS
        BEGIN
            IF p_list IS NULL OR p_list.COUNT = 0 THEN RETURN; END IF;

            FOR i IN 1 .. p_list.COUNT LOOP
                fire := FALSE;

                -- Trigger and operator were checked at load time and stored in upper case
                IF p_list(i).trigger_type = p_trigger THEN
                  -- STABILITY: an error in one rule must not prevent the other rules
                  BEGIN
                    CASE p_list(i).condition_operator
                        -- =====================================================
                        -- LOGGING OPERATORS
                        -- =====================================================
                        WHEN 'SEVERITY' THEN
                            fire := p_list(i).cond_upper = upper(p_ctx.context_name);

                        -- =====================================================
                        -- COMMON OPERATORS
                        -- =====================================================
                        WHEN 'ON_START' THEN fire := TRUE;
                        WHEN 'ON_STOP'  THEN fire := TRUE;
                        WHEN 'ON_UPDATE' THEN fire := TRUE;
                        WHEN 'ON_EVENT' THEN fire := TRUE;

                        WHEN 'MAX_OCCURRENCE' THEN
                            -- Process: completed steps; monitor: n-th execution of the action in the process
                            IF p_ctx.action_count IS NULL THEN
                                fire := p_ctx.steps_done > p_list(i).cond_num;
                            ELSE
                                fire := p_ctx.action_count > p_list(i).cond_num;
                            END IF;

                        WHEN 'PRECEDED_BY' THEN
                            fire := NOT (g_last_action_per_process.EXISTS(p_ctx.process_id) AND predecessorMatches(p_list(i)));

                        WHEN 'PRECEDED_BY_WITHIN_SECS' THEN
                            IF g_last_action_per_process.EXISTS(p_ctx.process_id) AND predecessorMatches(p_list(i)) THEN
                                l_diff_ms := get_ms_diff(g_last_action_per_process(p_ctx.process_id).stop_time, p_ctx.start_time);
                                fire := l_diff_ms / 1000 > p_list(i).cond_num;
                            ELSE
                                fire := TRUE;
                            END IF;

                        -- =====================================================
                        -- MONITOR-ONLY OPERATORS
                        -- =====================================================
                        WHEN 'AVG_DEVIATION_PCT' THEN
                            -- Compare the current duration with the average BEFORE this measurement.
                            -- avg_time is NULL during warm-up => no evaluation.
                            p_monRec.start_time      := p_ctx.start_time;
                            p_monRec.stop_time       := p_ctx.stop_time;
                            p_monRec.used_time       := p_ctx.used_time;
                            p_monRec.avg_action_time := p_ctx.avg_time;
                            fire := NOT validateDurationInAverage(p_monRec, p_list(i).cond_num);

                        WHEN 'MAX_DURATION_MS' THEN
                            fire := p_ctx.used_time > p_list(i).cond_num;

                        WHEN 'MAX_GAP_SECONDS' THEN
                            -- Events: distance to the previous event; traces (TRACE_START): distance to the end of the previous trace
                            v_key := buildMonitorKey(p_ctx.process_id, p_ctx.action_name, p_ctx.context_name);
                            IF p_trigger = C_MARK_EVENT AND g_monitor_shadows.EXISTS(v_key) THEN
                                l_diff_ms := get_ms_diff(g_monitor_shadows(v_key).start_time, p_ctx.start_time);
                                fire := l_diff_ms / 1000 > p_list(i).cond_num;
                            ELSIF p_trigger = C_TRACE_START AND g_monitor_averages.EXISTS(v_key) THEN
                                l_diff_ms := get_ms_diff(g_monitor_averages(v_key).stop_time, p_ctx.start_time);
                                fire := l_diff_ms / 1000 > p_list(i).cond_num;
                            END IF;

                        -- =====================================================
                        -- PROCESS-ONLY OPERATORS
                        -- =====================================================
                        WHEN 'RUNTIME_EXCEEDED' THEN
                            -- running process; checked only when a signal arrives
                            fire := p_ctx.process_end IS NULL
                                AND get_ms_diff(p_ctx.start_time, systimestamp) > p_list(i).cond_num;

                        WHEN 'MAX_RUNTIME_EXCEEDED' THEN
                            fire := p_ctx.process_end IS NOT NULL
                                AND get_ms_diff(p_ctx.start_time, p_ctx.process_end) > p_list(i).cond_num;

                        WHEN 'STEPS_LEFT_HIGH' THEN
                            fire := p_ctx.steps_todo - coalesce(p_ctx.steps_done, 0) > p_list(i).cond_num;

                        WHEN 'SUCCESS_RATE_LOW' THEN
                            fire := coalesce(p_ctx.steps_todo, 0) > 0
                                AND coalesce(p_ctx.steps_done, 0) / p_ctx.steps_todo * 100 < p_list(i).cond_num;

                        WHEN 'STATUS_EQUALS' THEN
                            fire := coalesce(p_ctx.status, -1) = p_list(i).cond_num;

                        WHEN 'INFO_CONTAINS' THEN
                            fire := instr(upper(p_ctx.info), p_list(i).cond_upper) > 0;

                        ELSE
                            NULL; -- loading rejects unknown operators
                    END CASE;

                    -- If the rule fires, we map the data back for the alerting system
                    -- (fire can be NULL for NULL comparisons => no alert)
                    IF fire THEN
                        p_monRec.process_id   := p_ctx.process_id;
                        p_monRec.action_name  := p_ctx.action_name;
                        p_monRec.context_name := p_ctx.context_name;
                        p_monRec.action_count := coalesce(p_ctx.action_count, p_ctx.steps_done, 0);
                        p_monRec.start_time   := p_ctx.start_time;
                        p_monRec.stop_time    := p_ctx.stop_time;
                        p_monRec.used_time    := p_ctx.used_time;
                        fire_alert(p_list(i), p_monRec);
                    END IF;
                  EXCEPTION
                    WHEN OTHERS THEN
                        logLilamErr(sqlCode, sqlErrM, 'evaluateRules_internal', 'rule ' || p_list(i).rule_id);
                  END;
                END IF;
            END LOOP;
        END;

    BEGIN
        -- Rules of the process's group; no group, no rules (PERFORMANCE: return immediately)
        IF NOT v_indexSession.EXISTS(p_ctx.process_id) THEN
            RETURN;
        END IF;
        l_group := g_sessionList(v_indexSession(p_ctx.process_id)).rule_group;
        IF l_group IS NULL THEN
            RETURN;
        END IF;

        -- INSESSION: check for a changed active rule set at most every C_RULES_CHECK_INTERVAL_MS
        -- (servers receive changes via SERVER_UPDATE_RULES).
        -- PERFORMANCE: DBMS_UTILITY.GET_TIME instead of SYSTIMESTAMP and interval arithmetic (measured < 1 µs instead of approx. 10–25 µs).
        -- ABS: on overflow of GET_TIME there is at most one additional check.
        IF g_serverPipeName IS NULL
           AND (NOT g_rule_groups.EXISTS(l_group)
                OR abs(dbms_utility.get_time - g_rule_groups(l_group).last_check_cs) >= C_RULES_CHECK_INTERVAL_MS / 10) THEN
            refreshGroupRules(l_group, p_force => FALSE);
        END IF;

        -- 1. Context rules (relevant for monitors only)
        IF p_check_context AND p_ctx.context_name IS NOT NULL
           AND g_rules_by_context.EXISTS(l_group || '|' || p_ctx.action_name || '|' || p_ctx.context_name) THEN
            apply_rule_list(g_rules_by_context(l_group || '|' || p_ctx.action_name || '|' || p_ctx.context_name));
        END IF;

        -- 2. General action/process rules (apply additionally, for all contexts)
        IF g_rules_by_action.EXISTS(l_group || '|' || p_ctx.action_name) THEN
            apply_rule_list(g_rules_by_action(l_group || '|' || p_ctx.action_name));
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
        logLilamErr(sqlCode, sqlErrM, 'evaluateRules_internal');

    END evaluateRules_internal;

    -- Helper function for mapping monitor data
    FUNCTION mapMonitorRecToContextRec(p_monitorRec t_monitor_buffer_rec) return t_eval_context_rec
    AS
        l_ctx t_eval_context_rec;
    BEGIN
        l_ctx.process_id   := p_monitorRec.process_id;
        l_ctx.action_name  := p_monitorRec.action_name;
        l_ctx.context_name := p_monitorRec.context_name;
        l_ctx.start_time   := p_monitorRec.start_time;
        l_ctx.stop_time    := p_monitorRec.stop_time;
        l_ctx.used_time    := p_monitorRec.used_time;
        l_ctx.action_count := p_monitorRec.action_count;
        l_ctx.avg_time     := p_monitorRec.baseline_avg;
        return l_ctx;
    END;


    -- Helper function for mapping process data
    FUNCTION mapProcessRecToContextRec(p_processRec t_process_rec) return t_eval_context_rec
    AS
        l_ctx t_eval_context_rec;
    BEGIN
        l_ctx.process_id   := p_processRec.id;
        l_ctx.action_name  := p_processRec.processName;
        l_ctx.context_name := NULL;
        l_ctx.start_time   := p_processRec.processStart;
        l_ctx.process_end  := p_processRec.processEnd;
        l_ctx.last_update  := p_processRec.lastUpdate;
        l_ctx.steps_todo   := p_processRec.stepsTodo;
        l_ctx.steps_done   := p_processRec.stepsDone;
        l_ctx.status       := p_processRec.status;
        l_ctx.info         := p_processRec.info;
        l_ctx.action_count := NULL;

        return l_ctx;
    END;
    
    
    -- Method used for mapping to the central evaluate method
    PROCEDURE evaluateRules(p_monitorRec t_monitor_buffer_rec, p_trigger VARCHAR2)
    AS
    BEGIN
        evaluateRules_internal(mapMonitorRecToContextRec(p_monitorRec), p_trigger, p_check_context => TRUE);
        -- Remember the predecessor for PRECEDED_BY: only events and traces, no logs
        IF p_trigger != C_LOGGING THEN
            g_last_action_per_process(p_monitorRec.process_id).action_name  := p_monitorRec.action_name;
            g_last_action_per_process(p_monitorRec.process_id).context_name := p_monitorRec.context_name;
            g_last_action_per_process(p_monitorRec.process_id).stop_time    := coalesce(p_monitorRec.stop_time, p_monitorRec.start_time);
        END IF;

    EXCEPTION
    WHEN OTHERS THEN
        logLilamErr(sqlCode, sqlErrM, 'evaluateRules'); 

    END evaluateRules;

    -- Method used for mapping to the central evaluate method
    PROCEDURE evaluateRules(p_processRec t_process_rec, p_trigger VARCHAR2)
    AS
    BEGIN
        evaluateRules_internal(mapProcessRecToContextRec(p_processRec), p_trigger, p_check_context => FALSE);
    END evaluateRules;

    --------------------------------------------------------------------------
    -- Avoid throttling 
    --------------------------------------------------------------------------
    function waitForResponse(
        p_processId   in number,
        p_request       in varchar2, -- Needed for assignment/branching in the server
        p_payload       IN varchar2, 
        p_timeoutSec    IN PLS_INTEGER
    ) return varchar2
    as
        l_msgReceive    JSON_OBJ_LILAM;
        l_status        PLS_INTEGER;
        l_statusReceive PLS_INTEGER;
        l_clientChannel varchar2(50);
        l_groupName     varchar2(50);
        l_serverPipe    varchar2(100);
        l_slotIdx PLS_INTEGER;

        l_jsonHeader    JSON_OBJ_LILAM;
        l_jsonPayload   JSON_OBJ_LILAM;
        l_jsonMain      JSON_OBJ_LILAM;
    begin
        l_clientChannel := getClientPipe;
        l_groupName := jsonString(p_payload, 'group_name');

        jsonPut(l_jsonHeader, 'msg_type', 'API_CALL');
        jsonPut(l_jsonHeader, 'request', p_request);
        jsonPut(l_jsonHeader, 'response', l_clientChannel);

        l_jsonPayload := p_payLoad;
        jsonPut(l_jsonMain, 'header', l_jsonHeader);
        jsonPut(l_jsonMain, 'payload', l_jsonPayload);

        l_serverPipe := getServerPipeForSession(p_processId, l_groupName);

        DBMS_PIPE.PACK_MESSAGE(l_jsonMain);
        if p_request = 'NEW_SESSION' then
            -- NEW_SESSION via the control pipe: overtakes the data messages of other clients in the
            -- data pipe (previously regularly > 3 s wait time and timeout under load).
            l_status := DBMS_PIPE.SEND_MESSAGE(ctlPipe(l_serverPipe), timeout => 3);
            sendPing(l_serverPipe);
        else
            l_status := DBMS_PIPE.SEND_MESSAGE(l_serverPipe, timeout => 3);
        end if;
        l_statusReceive := DBMS_PIPE.RECEIVE_MESSAGE(l_clientChannel, timeout => p_timeoutSec);
        if l_statusReceive = 0 THEN
            DBMS_PIPE.UNPACK_MESSAGE(l_msgReceive);
        end if ;

        DBMS_PIPE.PURGE(l_clientChannel);
        l_status := DBMS_PIPE.REMOVE_PIPE(l_clientChannel);

        if l_statusReceive = 1 THEN RETURN 'TIMEOUT'; end if ;
        return l_msgReceive;

    exception
        when others then
        logLilamErr(sqlCode, sqlErrM, 'waitForResponse');
        begin
            l_status := DBMS_PIPE.REMOVE_PIPE(l_clientChannel);
            return 'ERROR: ' || TXT_COMM_ERR;
        exception
            when others then
            logLilamErr(sqlCode, sqlErrM, 'waitForResponse', 'DBMS_PIPE.REMOVE_PIPE');
            return 'ERROR: ' || TXT_COMM_ERR;
        end;
    end;

    ---------------------------------------------------------------
    -- Mark active servers
    ---------------------------------------------------------------
    function isServerPipeActive(p_pipeName varchar2) return boolean
    as
        l_counter PLS_INTEGER;
        l_sqlStmt varchar2(200);
    begin
        l_sqlStmt := '
            SELECT count(*) FROM ' || C_LILAM_SERVER_REGISTRY || ' 
            WHERE is_active = 1
            AND last_activity > SYSTIMESTAMP - INTERVAL ''' ||C_MAX_REGISTRY_HEARTBEAT_AGE_SEC || ''' SECOND
            AND upper(pipe_name) = :1';

        execute immediate l_sqlStmt into l_counter using upper(p_pipeName);
        if l_counter >= 1 then return TRUE; end if;
        if l_counter = 0  then return FALSE; end if;
        
    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'isServerPipeActive', 'EXECUTE IMMEDIATE');
            return false;
    end;

    ---------------------------------------------------------------

    function getServerPipeAvailable(p_groupName varchar2) return varchar2
    as
        l_clientChannel  varchar2(50);
        l_sqlStmt   varchar2(1000);
        l_serverPipeName varchar2(50);
    begin
        l_clientChannel := getClientPipe;

        l_sqlStmt := '
        SELECT pipe_name 
        FROM ' || C_LILAM_SERVER_REGISTRY || ' 
        WHERE is_active = 1 
          AND last_activity > SYSTIMESTAMP - INTERVAL ''' || C_MAX_REGISTRY_HEARTBEAT_AGE_SEC || ''' SECOND ';

        if p_groupName is not null then
            l_sqlStmt := l_sqlStmt || ' AND upper(group_name) = ''' || upper(p_groupName) || '''';
        end if;

        -- Order of selection: fewest messages in the last interval, then fewest open processes,
        -- on a tie the server idle for the longest time (oldest registry entry; a busy
        -- server updates its entry more often, an idle one less often)
        -- Dispatchers are never the target of server selection: neither for clients without a dispatcher setting
        -- (otherwise an unnecessary detour via the dispatcher) nor for a dispatcher itself when choosing
        -- a worker (it would otherwise send the message to itself endlessly)
        l_sqlStmt := l_sqlStmt || ' AND nvl(is_dispatcher, 0) = 0';

        l_sqlStmt := l_sqlStmt || '
        ORDER BY processing ASC, current_processes ASC, last_activity ASC 
        FETCH FIRST 1 ROW ONLY';

        execute immediate l_sqlStmt into l_serverPipeName;
        return l_serverPipeName;

    exception
        when NO_DATA_FOUND then
            return null;
        when others then
            logLilamErr(sqlCode, sqlErrM, 'getServerPipeAvailable', 'EXECUTE IMMEDIATE');
            return null;
    end;
    
    ---------------------------------------------------------------

    procedure send_sync_signal(p_processId number)
    as
        l_response varchar2(1000);
    begin
        -- process_id in the payload: a dispatcher needs it to forward the request to the worker of the process.
        -- Previously ('{}') the dispatcher discarded the request, and the client waited
        -- for the full timeout every time (load test via dispatcher: 5.3 ms instead of 0.2 ms per call).
        l_response := waitForResponse(p_processId, 'UNFREEZE_REQUEST', '{"process_id":' || jNum(p_processId) || '}', 10);

    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'send_sync_signal', 'waitForResponse');
    end;

    --------------------------------------------------------------------------
    -- Hit the brakes when the client sends too fast
    --------------------------------------------------------------------------
    PROCEDURE stabilizeInLowPerfEnvironments(p_processId number)
    IS
        -- PERFORMANCE: SYSTIMESTAMP is only read when the time is needed
        -- (on the first call and every msg_limit messages), not on every call
        l_now TIMESTAMP;
        l_new_throttle t_throttle_stat;
    BEGIN
        -- Process without a value from the server (should not happen): default C_SERVER_PERF_MID
        if NOT g_local_throttle_cache.EXISTS(p_processId) THEN
            l_new_throttle.msg_limit := C_SERVER_PERF_MID;
            g_local_throttle_cache(p_processId) := l_new_throttle;
        end if ;

        -- 0 = no throttling (server started with p_perfServer => 0)
        if g_local_throttle_cache(p_processId).msg_limit > 0 THEN 
            -- Increment counter
            g_local_throttle_cache(p_processId).msg_count := g_local_throttle_cache(p_processId).msg_count + 1;

            -- Limit of the time window reached?
            if g_local_throttle_cache(p_processId).msg_count >= g_local_throttle_cache(p_processId).msg_limit THEN        
                l_now := SYSTIMESTAMP;
                -- If messages were fired too fast
                if get_ms_diff(g_local_throttle_cache(p_processId).last_check, l_now) < C_THROTTLE_INTERVAL_NO THEN
                    -- Force synchronization (wait for the server response)
                    -- This gives the remote server the necessary "breathing space"
                    send_sync_signal(p_processId);
                end if ;

                -- Reset for the next window
                g_local_throttle_cache(p_processId).msg_count := 0;
                g_local_throttle_cache(p_processId).last_check := l_now;
            end if ;
        end if ;
    END;

    --------------------------------------------------------------------------
    -- Message to server, fire & forget
    --------------------------------------------------------------------------
    procedure sendNoWait(
        p_processId     in number,
        p_request       in varchar2, -- Needed for assignment/branching in the server
        p_payload       IN varchar2, 
        p_timeoutSec    IN PLS_INTEGER
    )
    as        
        l_pipeName      VARCHAR2(100);
        l_status        PLS_INTEGER;
        l_jsonMain      JSON_OBJ_LILAM;   -- (unused variables l_now/l_retryInterval removed: saved one SYSTIMESTAMP per call)
    begin
        stabilizeInLowPerfEnvironments(p_processId);

        -- PERFORMANCE: concatenate the message in one step instead of via jsonPut (see jStr/jNum/jTs).
        -- p_request is always an internal constant and does not need to be escaped.
        l_jsonMain := '{"header":{"msg_type":"API_CALL","request":"' || p_request || '"}'
                   || case when p_payload is not null then ',"payload":' || p_payload end
                   || '}';

        l_pipeName := getServerPipeForSession(p_processId, null);
        DBMS_PIPE.PACK_MESSAGE(l_jsonMain);
        for i in 1 .. 3 loop
            l_status := DBMS_PIPE.SEND_MESSAGE(l_pipeName, timeout => p_timeoutSec);
            if l_status = 0 THEN
                exit;
            end if ;
            if l_status = 2 then
                DBMS_PIPE.RESET_BUFFER;
                DBMS_PIPE.PACK_MESSAGE(l_jsonMain);   -- previously l_msg (never filled): the retry sent an empty message
            end if;
            dbms_session.sleep(0.3);
        end loop;

        if l_status != 0 AND p_processId != g_serverProcessId then
            -- Re-registration with an alternative server
            DBMS_PIPE.RESET_BUFFER;
            RAISE_APPLICATION_ERROR(-20006, 'LILAM: Client kann keine Nachrichten an Server senden:  ' || sqlErrM);
        end if;

    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'sendNoWait');
    end;

    --------------------------------------------------------------------------    
    -- global exception handling
    function should_raise_error(p_processId number) return boolean
    as
    begin
        -- The logic is encapsulated centrally here
        if p_processId is not null and v_indexSession.EXISTS(p_processId) 
           and g_sessionList(v_indexSession(p_processId)).log_level >= logLevelDebug 
        then
            return true;
        end if ;
        return false;
    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'should_raise_error');
            error(p_processId, 'Check "should raise error" failed: ' || sqlErrM);
            return false;
    end;  

    --------------------------------------------------------------------------

    -- run execute immediate with exception handling
    procedure run_sql(p_sqlStmt varchar2)
    as
    begin
        execute immediate p_sqlStmt;

    exception
        when OTHERS then
            logLilamErr(sqlCode, sqlErrM, 'run_sql', 'EXECUTE IMMEDIATE');
    end;

    --------------------------------------------------------------------------

    -- Checks if a database sequence exists
    function objectExists(p_objectName varchar2, p_objectType varchar2) return boolean
    as
        sqlStatement varchar2(200);
        objectCount number;
    begin
        sqlStatement := '
        select count(*)
        from user_objects
        where upper(object_name) = upper(:PH_OBJECT_NAME)
        and   upper(object_type) = upper(:PH_OBJECT_TYPE)';

        execute immediate sqlStatement into objectCount using upper(p_objectName), upper(p_objectType);

        if objectCount > 0 then
            return true;
        else
            return false;
        end if ;
        
    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'objectExists');
            return false;
    end;

    --------------------------------------------------------------------------

    function replaceNameTable(p_sqlStatement varchar2, p_placeHolder varchar2, p_tableSuffix varchar2, p_tableName varchar2) return varchar2
    as
    begin
        return replace(p_sqlStatement, p_placeHolder, p_tableName || p_tableSuffix);
    end;
    
    --------------------------------------------------------------------------

    procedure createDispatchTable
    as
        l_sql varchar2(1000);
    begin
        if not objectExists(C_LILAM_PROCESS_ROUTE, 'TABLE') then
            l_sql := '
                CREATE TABLE ' || C_LILAM_PROCESS_ROUTE || '(
                    process_id  NUMBER(19,0) PRIMARY KEY,
                    pipe_name   VARCHAR2(50) NOT NULL,
                    created     TIMESTAMP(6) DEFAULT SYSTIMESTAMP
                )';
            execute immediate l_sql;
        end if;
    EXCEPTION
        WHEN OTHERS THEN
            dbms_output.enable(10000);
            dbms_output.put_line('LILAM INTERNAL ERROR in Procedure createDispatchTable: ' || substr(sqlErrM, 1, 1000) || chr(13) || chr(10) || l_sql);
    end;

    --------------------------------------------------------------------------

    procedure createInternalLogTable
    as
        l_sql varchar2(1000);
    begin
        if not objectExists(C_LILAM_LOG_TABLE, 'TABLE') then
            l_sql := '
                create table ' || C_LILAM_LOG_TABLE || '(
                    id              number generated always as identity,
                    log_timestamp   timestamp(6) default systimestamp not null,            
                    error_code      number,
                    error_message   varchar2(4000),
                    error_stack     varchar2(4000),
                    error_backtrace varchar2(4000),
                    call_stack      varchar2(4000),
                    module_name     varchar2(200),
                    log_operation   varchar2(200)
                )';
            execute immediate l_sql;
        end if;
        
    EXCEPTION
        WHEN OTHERS THEN
            dbms_output.enable(10000);
            dbms_output.put_line('LILAM INTERNAL ERROR in Procedure createInternalLogTable: ' || substr(sqlErrM, 1, 1000) || chr(13) || chr(10) || l_sql);
    end;

    -- Creates LOG tables and the sequence for the process IDs if tables or sequence don't exist
    -- For naming rules of the tables see package description
    --------------------------------------------------------------------------
    -- Creates an index if it does not exist yet
    --------------------------------------------------------------------------
    procedure createIndexIfMissing(p_indexName varchar2, p_tableName varchar2, p_columns varchar2)
    as
        l_indexName varchar2(128) := upper(trim(p_indexName));
    begin
        if not objectExists(l_indexName, 'INDEX') then
            run_sql('CREATE INDEX ' || l_indexName || ' ON ' || upper(trim(p_tableName)) || ' (' || p_columns || ')');
        end if;
    end;

    --------------------------------------------------------------------------

    procedure createLogTables(p_TabNameMaster varchar2)
    as
        sqlStmt varchar2(4000);
        l_master constant varchar2(100) := upper(trim(p_TabNameMaster));
        l_regCols number;
    begin
        -- Check only once per session and master table (saves about a dozen dictionary queries per NEW_SESSION)
        if g_checked_masters.EXISTS(l_master) then
            return;
        end if;

        if not objectExists('SEQ_LILAM_LOG', 'SEQUENCE') then
            sqlStmt := 'CREATE SEQUENCE SEQ_LILAM_LOG MINVALUE 0 MAXVALUE 9999999999999999999999999999 INCREMENT BY 1 START WITH 1 CACHE 10 NOORDER  NOCYCLE  NOKEEP  NOSCALE  GLOBAL';
            execute immediate sqlStmt;
        end if ;

        if not objectExists(p_TabNameMaster || C_SUFFIX_PROC_TABLE, 'TABLE') then
            -- Master table
            sqlStmt := '
            create table ' || C_PARAM_MASTER_TABLE || ' ( 
                id               NUMBER(19,0),
                process_name     VARCHAR2(100),
                log_level        NUMBER,
                process_start    TIMESTAMP(6) DEFAULT SYSTIMESTAMP,
                process_end      TIMESTAMP(6),
                last_update      TIMESTAMP(6),
                steps_todo       NUMBER,
                steps_done       NUMBER,
                status           NUMBER(2,0),
                info             VARCHAR2(2000),
                process_immortal NUMBER(1,0) DEFAULT 0,
                server_pipe      VARCHAR2(100),
                tab_name_master  VARCHAR2(100),
                scope_name       VARCHAR2(100)
            )';
            sqlStmt := replaceNameTable(sqlStmt, C_PARAM_MASTER_TABLE, C_SUFFIX_PROC_TABLE, p_TabNameMaster);
            run_sql(sqlStmt);
        end if ;

        if not objectExists(p_TabNameMaster || C_SUFFIX_LOG_TABLE, 'TABLE') then
            -- Details table
            sqlStmt := '
            create table ' || C_PARAM_LOG_TABLE || ' (
                "PROCESS_ID"        number(19,0),
                "NO"                number(19,0),
                "INFO"              varchar2(2000),
                "LOG_LEVEL"         number,
                "LOG_LEVEL_C"       varchar2(10),
                "SESSION_TIME"      timestamp(6) DEFAULT SYSTIMESTAMP,
                "SESSION_USER"      varchar2(50),
                "HOST_NAME"         varchar2(50),
                "CALLER"            varchar2(255),
                "ERR_STACK"         varchar2(4000),
                "ERR_BACKTRACE"     varchar2(4000),
                "ERR_CALLSTACK"     varchar2(4000)
            )';
            sqlStmt := replaceNameTable(sqlStmt, C_PARAM_LOG_TABLE, C_SUFFIX_LOG_TABLE, p_TabNameMaster);
            run_sql(sqlStmt);
        end if ;

        if not objectExists(p_TabNameMaster || C_SUFFIX_MON_TABLE, 'TABLE') then
            -- Details table
            sqlStmt := '
            create table ' || C_PARAM_MON_TABLE || ' (
                "PROCESS_ID"    number(19,0),
                "MON_TYPE"      number DEFAULT 0,
                "START_TIME"    timestamp(6)  DEFAULT SYSTIMESTAMP,
                "STOP_TIME"     timestamp(6),
                "SESSION_USER"  varchar2(50),
                "HOST_NAME"     varchar2(50),
                "ACTION"        VARCHAR2(100),
                "CONTEXT"  VARCHAR2(100),
                "USED_MILLIS"   NUMBER(19,0), -- Millis as a number for easy evaluation
                "AVG_MILLIS"    NUMBER(19,0),
                "ACTION_COUNT"    NUMBER(19,0)
            )';
            sqlStmt := replaceNameTable(sqlStmt, C_PARAM_MON_TABLE, C_SUFFIX_MON_TABLE, p_TabNameMaster);
            run_sql(sqlStmt);
        end if ;

        if not objectExists(C_LILAM_SERVER_REGISTRY, 'TABLE') then
            sqlStmt := '
            CREATE TABLE ' || C_LILAM_SERVER_REGISTRY || ' (
                pipe_name      VARCHAR2(50) PRIMARY KEY,
                group_name     VARCHAR2(50),
                last_activity  TIMESTAMP(3),
                current_processes   NUMBER,
                is_active      NUMBER(1),
                status         VARCHAR2(20),
                processing     NUMBER,
                avg_log_lat    NUMBER DEFAULT 0,
                max_log_lat    NUMBER DEFAULT 0,
                avg_mon_lat    NUMBER DEFAULT 0,
                max_mon_lat    NUMBER DEFAULT 0,
                is_dispatcher  NUMBER(1) DEFAULT 0
            )';
            run_sql(sqlStmt);
        else
            -- Extend an existing registry with the dispatcher flag
            select count(*) into l_regCols from user_tab_columns
             where table_name = upper(C_LILAM_SERVER_REGISTRY) and column_name = 'IS_DISPATCHER';
            if l_regCols = 0 then
                run_sql('ALTER TABLE ' || C_LILAM_SERVER_REGISTRY || ' ADD is_dispatcher NUMBER(1) DEFAULT 0');
            end if;
        end if;

        if not objectExists(C_LILAM_RULES_TABLE, 'TABLE') then
            sqlStmt := '
            CREATE TABLE ' || C_LILAM_RULES_TABLE || ' (
                rule_set       CLOB CONSTRAINT ensure_json_rules CHECK (rule_set IS JSON),
                group_name     VARCHAR2(50),
                set_name       VARCHAR2(30),
                version        NUMBER,
                is_active      NUMBER(1) DEFAULT 0,
                created        TIMESTAMP,
                author         VARCHAR2(50)
            )';
            run_sql(sqlStmt);
        else
            -- Existing table: rule sets apply per server group, one per group is active
            select count(*) into l_regCols from user_tab_columns
             where table_name = upper(C_LILAM_RULES_TABLE) and column_name = 'GROUP_NAME';
            if l_regCols = 0 then
                run_sql('ALTER TABLE ' || C_LILAM_RULES_TABLE || ' ADD (group_name VARCHAR2(50), is_active NUMBER(1) DEFAULT 0)');
            end if;
        end if;


        if not objectExists(C_LILAM_ALERTS_TABLE, 'TABLE') then
            sqlStmt := '
            CREATE TABLE ' || C_LILAM_ALERTS_TABLE || ' (
                alert_id           NUMBER GENERATED BY DEFAULT AS IDENTITY,
                process_id         NUMBER(19,0) NOT NULL,
                process_name       VARCHAR2(50),
                master_table_name  VARCHAR2(50), 
                monitor_table_name VARCHAR2(50), 
                logging_table_name VARCHAR2(50), 
                action_name        VARCHAR2(100) NOT NULL,
                context_name       VARCHAR2(100),
                group_name         VARCHAR2(100),
                action_count       NUMBER NOT NULL,
                rule_set_name      VARCHAR2(50),
                rule_id            VARCHAR2(50) NOT NULL,
                rule_set_version   NUMBER NOT NULL,
                alert_severity     VARCHAR2(30),
                handler_type       VARCHAR2(50),              
                status             VARCHAR2(50) DEFAULT ''PENDING'',
                error_message      CLOB,
                created_at         TIMESTAMP DEFAULT SYSTIMESTAMP,
                processed_at       TIMESTAMP,

                CONSTRAINT pk_lila_alerts PRIMARY KEY (alert_id)
            )';
            run_sql(sqlStmt);
        end if;

        -- Baseline scopes: fixed identity of an application across processes
        if not objectExists(C_LILAM_SCOPES_TABLE, 'TABLE') then
            sqlStmt := '
            CREATE TABLE ' || C_LILAM_SCOPES_TABLE || ' (
                scope_id    NUMBER GENERATED BY DEFAULT AS IDENTITY,
                scope_name  VARCHAR2(100) NOT NULL,
                created     TIMESTAMP DEFAULT SYSTIMESTAMP,
                CONSTRAINT pk_lilam_scopes PRIMARY KEY (scope_id),
                CONSTRAINT uq_lilam_scope_name UNIQUE (scope_name)
            )';
            run_sql(sqlStmt);
        end if;

        -- Baselines: current average per scope/action/context (no history, that is in _MON)
        if not objectExists(C_LILAM_BASELINES_TABLE, 'TABLE') then
            sqlStmt := '
            CREATE TABLE ' || C_LILAM_BASELINES_TABLE || ' (
                scope_id      NUMBER(19,0)  NOT NULL,
                action_name   VARCHAR2(100) NOT NULL,
                context_name  VARCHAR2(100) DEFAULT ''' || C_BASELINE_NULL_CONTEXT || ''' NOT NULL,
                avg_ms        NUMBER,
                action_count  NUMBER(19,0)  DEFAULT 0 NOT NULL,
                last_update   TIMESTAMP(6),
                CONSTRAINT pk_lilam_baselines PRIMARY KEY (scope_id, action_name, context_name)
            ) ORGANIZATION INDEX';
            run_sql(sqlStmt);
        end if;

        -- Indexes of the master tables: names are derived from the master name,
        -- so that each master table (LILAM, LILAM_SERVER, custom names) gets its own indexes
        createIndexIfMissing(p_TabNameMaster || C_SUFFIX_PROC_TABLE || '_IX_ID',      p_TabNameMaster || C_SUFFIX_PROC_TABLE, 'id');
        createIndexIfMissing(p_TabNameMaster || C_SUFFIX_PROC_TABLE || '_IX_CLEANUP', p_TabNameMaster || C_SUFFIX_PROC_TABLE, 'process_name, process_end');
        createIndexIfMissing(p_TabNameMaster || C_SUFFIX_LOG_TABLE  || '_IX_PID',     p_TabNameMaster || C_SUFFIX_LOG_TABLE,  'process_id');
        createIndexIfMissing(p_TabNameMaster || C_SUFFIX_LOG_TABLE  || '_IX_INFO',    p_TabNameMaster || C_SUFFIX_LOG_TABLE,  'info');
        createIndexIfMissing(p_TabNameMaster || C_SUFFIX_MON_TABLE  || '_IX_PID',     p_TabNameMaster || C_SUFFIX_MON_TABLE,  'process_id');

       if not objectExists('idx_lilam_registry_group', 'INDEX') then
            sqlStmt := '
            CREATE INDEX idx_lilam_registry_group 
            ON C_LILAM_SERVER_REGISTRY (group_name, is_active, current_processes)';
            sqlStmt := replace(sqlStmt, 'C_LILAM_SERVER_REGISTRY', C_LILAM_SERVER_REGISTRY);
            run_sql(sqlStmt);
        end if ;

        -- Rule sets: unique per group/name/version; at most one active per group
        if not objectExists('idx_lilam_rules_grp', 'INDEX') then
            run_sql('CREATE UNIQUE INDEX idx_lilam_rules_grp ON ' || C_LILAM_RULES_TABLE || ' (group_name, set_name, version)');
        end if ;
        if not objectExists('idx_lilam_rules_active', 'INDEX') then
            run_sql('CREATE UNIQUE INDEX idx_lilam_rules_active ON ' || C_LILAM_RULES_TABLE
                    || ' (CASE WHEN is_active = 1 THEN upper(group_name) END)');
        end if ;

        g_checked_masters(l_master) := TRUE;

    exception      
        when others then
            logLilamErr(sqlCode, sqlErrM, 'createLogTables');
     end;

    --------------------------------------------------------------------------
    -- Deletes log entries based on their age (in days) and the process name.
    -- Matching of process name is not case sensitive.
    -- Doesn't work if the Master-Tablename of the process changed in the meantime.
    procedure deleteOldLogs(p_processId number, p_processName varchar2, p_daysToKeep number)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
        t_rc SYS_REFCURSOR;
        sessionRec t_session_rec;
        processIdToDelete number(19,0);
    begin
        
        if p_daysToKeep is null then
            return;
        end if ;
        
        -- 1. find an active session by ID; it contains the name
        --    of the master table
        -- 2. replace the name of the master table in the prepared SQL
        -- 3. find all outdated IDs in the master table
        -- 4. delete the data from the log, monitor and master tables in a loop

        -- 1.
        sessionRec := getSessionRecord(p_processId);
        if sessionRec.process_id is null then
            return; 
        end if ;

        -- basic sql for iteration through (old) sessions
        sqlStatement := '
        select id from ' || C_PARAM_MASTER_TABLE || '
        where process_end <= sysdate - :PH_DAYS_TO_KEEP
        and upper(process_name) = upper(:PH_PROCESS_NAME)
        and process_immortal = 0';
        
        -- 2.
        sqlStatement := replaceNameTable(sqlStatement, C_PARAM_MASTER_TABLE, C_SUFFIX_PROC_TABLE, sessionRec.tabName_master);

        -- 3., 4.
        -- for all process IDs
        open t_rc for sqlStatement using p_daysToKeep, p_processName;
        loop
            fetch t_rc into processIdToDelete;
            EXIT WHEN t_rc%NOTFOUND;

            -- delete Logs and Monitor-entries first (integrity)
            sqlStatement := 'delete from ' || C_PARAM_LOG_TABLE || ' where process_id = :1';
            sqlStatement := replaceNameTable(sqlStatement, C_PARAM_LOG_TABLE, C_SUFFIX_LOG_TABLE, sessionRec.tabName_master);
            execute immediate sqlStatement USING processIdToDelete;

            sqlStatement := 'delete from ' || C_PARAM_MON_TABLE || ' where process_id = :1';
            sqlStatement := replaceNameTable(sqlStatement, C_PARAM_MON_TABLE, C_SUFFIX_MON_TABLE, sessionRec.tabName_master);
            execute immediate sqlStatement USING processIdToDelete;

            -- delete master
            sqlStatement := 'delete from ' || C_PARAM_MASTER_TABLE || ' where id = :1';
            sqlStatement := replaceNameTable(sqlStatement, C_PARAM_MASTER_TABLE, C_SUFFIX_PROC_TABLE, sessionRec.tabName_master);
            execute immediate sqlStatement USING processIdToDelete;
        end loop;
        close t_rc;
        commit;

    exception
        when others then
        begin
            if t_rc%isopen then 
                close t_rc;
            end if ;
            rollback; -- End the transaction in the error case as well
        exception
            when others then
            logLilamErr(sqlCode, sqlErrM, 'deleteOldLogs', 'close t_rc');
        end;            
        logLilamErr(sqlCode, sqlErrM, 'deleteOldLogs');

    end;

    --------------------------------------------------------------------------

    function readProcessRecord(p_processId number) return t_process_rec
    as
        sessionRec t_session_rec;
        processRec t_process_rec;
        sqlStatement varchar2(1000);
    begin
        sqlStatement := '
        select
            id,
            process_name,
            log_level,
            process_start,
            process_end,
            last_update,
            steps_todo,
            steps_done,
            status,
            info,
            process_immortal,
            tab_name_master
        from ' || C_PARAM_MASTER_TABLE || '
        where id = :PH_PROCESS_ID';

        sessionRec := getSessionRecord(p_processId);
        if sessionRec.process_id is not null then
            sqlStatement := replaceNameTable(sqlStatement, C_PARAM_MASTER_TABLE, C_SUFFIX_PROC_TABLE, sessionRec.tabname_Master);
            execute immediate sqlStatement into processRec USING p_processId;
        end if ;
        return processRec;

    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'readProcessRecord');
            if should_raise_error(p_processId) then
                error(p_processId, 'Reading process record failed: ' || sqlErrM);
            end if ;
            return null;
    end;

    --------------------------------------------------------------------------
    -- Flush monitor data to detail table
    --------------------------------------------------------------------------
    --------------------------------------------------------------------------
    -- PERFORMANCE: bundled flush in SYNC_ALL_DIRTY
    --
    -- Previously SYNC_ALL_DIRTY wrote each due process individually: per table (_LOG, _MON, _PROC)
    -- a separate autonomous transaction with its own commit. With 200 open processes that meant
    -- up to 600 writes and 600 commits per run; meanwhile the server read
    -- no messages from the pipe.
    --
    -- Now: g_batch_mode is set during SYNC_ALL_DIRTY. persist_log_data,
    -- persist_monitor_data and persist_process_record then do not write themselves but
    -- append their rows to a collection buffer per target table. At the end of the run flushBatch writes
    -- everything with one FORALL per table and ONE commit.
    --
    -- What is written and when remains unchanged (same due check per process).
    -- CLOSE_SESSION still writes immediately and only its own process (no batch mode).
    --------------------------------------------------------------------------
    -- (types and collection buffers see declaration section: t_log_batch_rec, g_batch_mode ...)

    procedure appendLogBatch(
        p_processId number, p_target_table varchar2,
        p_seqs sys.odcinumberlist, p_levels sys.odcinumberlist, p_levelsC sys.odcivarchar2list,
        p_texts sys.odcivarchar2list, p_times t_timestamp_list_t, p_callers sys.odcivarchar2list,
        p_stacks sys.odcivarchar2list, p_backtraces sys.odcivarchar2list, p_callstacks sys.odcivarchar2list)
    as
        l_n     pls_integer;
        l_empty t_log_batch_rec;   -- Record with empty lists (defaults)
    begin
        if not g_log_batches.EXISTS(p_target_table) then
            g_log_batches(p_target_table) := l_empty;
        end if;
        l_n := g_log_batches(p_target_table).pids.COUNT;
        g_log_batches(p_target_table).pids.EXTEND(p_levels.COUNT);
        g_log_batches(p_target_table).seqs.EXTEND(p_levels.COUNT);
        g_log_batches(p_target_table).levels.EXTEND(p_levels.COUNT);
        g_log_batches(p_target_table).levelsC.EXTEND(p_levels.COUNT);
        g_log_batches(p_target_table).texts.EXTEND(p_levels.COUNT);
        g_log_batches(p_target_table).times.EXTEND(p_levels.COUNT);
        g_log_batches(p_target_table).callers.EXTEND(p_levels.COUNT);
        g_log_batches(p_target_table).stacks.EXTEND(p_levels.COUNT);
        g_log_batches(p_target_table).backtraces.EXTEND(p_levels.COUNT);
        g_log_batches(p_target_table).callstacks.EXTEND(p_levels.COUNT);
        for i in 1 .. p_levels.COUNT loop
            g_log_batches(p_target_table).pids(l_n + i)       := p_processId;
            g_log_batches(p_target_table).seqs(l_n + i)       := p_seqs(i);
            g_log_batches(p_target_table).levels(l_n + i)     := p_levels(i);
            g_log_batches(p_target_table).levelsC(l_n + i)    := p_levelsC(i);
            g_log_batches(p_target_table).texts(l_n + i)      := p_texts(i);
            g_log_batches(p_target_table).times(l_n + i)      := p_times(i);
            g_log_batches(p_target_table).callers(l_n + i)    := p_callers(i);
            g_log_batches(p_target_table).stacks(l_n + i)     := p_stacks(i);
            g_log_batches(p_target_table).backtraces(l_n + i) := p_backtraces(i);
            g_log_batches(p_target_table).callstacks(l_n + i) := p_callstacks(i);
        end loop;
    end;

    procedure appendMonBatch(
        p_processId number, p_target_table varchar2,
        p_actions sys.odcivarchar2list, p_contexts sys.odcivarchar2list, p_mon_types sys.odcinumberlist,
        p_action_count sys.odcinumberlist, p_used sys.odcinumberlist, p_avgs sys.odcinumberlist,
        p_timesStart t_timestamp_list_t, p_timesStop t_timestamp_list_t)
    as
        l_n     pls_integer;
        l_empty t_mon_batch_rec;
    begin
        if not g_mon_batches.EXISTS(p_target_table) then
            g_mon_batches(p_target_table) := l_empty;
        end if;
        l_n := g_mon_batches(p_target_table).pids.COUNT;
        g_mon_batches(p_target_table).pids.EXTEND(p_actions.COUNT);
        g_mon_batches(p_target_table).actions.EXTEND(p_actions.COUNT);
        g_mon_batches(p_target_table).contexts.EXTEND(p_actions.COUNT);
        g_mon_batches(p_target_table).mon_types.EXTEND(p_actions.COUNT);
        g_mon_batches(p_target_table).action_count.EXTEND(p_actions.COUNT);
        g_mon_batches(p_target_table).used.EXTEND(p_actions.COUNT);
        g_mon_batches(p_target_table).avgs.EXTEND(p_actions.COUNT);
        g_mon_batches(p_target_table).timesStart.EXTEND(p_actions.COUNT);
        g_mon_batches(p_target_table).timesStop.EXTEND(p_actions.COUNT);
        for i in 1 .. p_actions.COUNT loop
            g_mon_batches(p_target_table).pids(l_n + i)         := p_processId;
            g_mon_batches(p_target_table).actions(l_n + i)      := p_actions(i);
            g_mon_batches(p_target_table).contexts(l_n + i)     := p_contexts(i);
            g_mon_batches(p_target_table).mon_types(l_n + i)    := p_mon_types(i);
            g_mon_batches(p_target_table).action_count(l_n + i) := p_action_count(i);
            g_mon_batches(p_target_table).used(l_n + i)         := p_used(i);
            g_mon_batches(p_target_table).avgs(l_n + i)         := p_avgs(i);
            g_mon_batches(p_target_table).timesStart(l_n + i)   := p_timesStart(i);
            g_mon_batches(p_target_table).timesStop(l_n + i)    := p_timesStop(i);
        end loop;
    end;

    procedure appendProcBatch(p_process_rec t_process_rec)
    as
        l_key   varchar2(150) := p_process_rec.tabNameMaster;
        l_n     pls_integer;
        l_empty t_proc_batch_rec;
    begin
        if not g_proc_batches.EXISTS(l_key) then
            g_proc_batches(l_key) := l_empty;
        end if;
        g_proc_batches(l_key).ids.EXTEND;       l_n := g_proc_batches(l_key).ids.COUNT;
        g_proc_batches(l_key).status.EXTEND;    g_proc_batches(l_key).procEnd.EXTEND;
        g_proc_batches(l_key).stepsTodo.EXTEND; g_proc_batches(l_key).stepsDone.EXTEND;
        g_proc_batches(l_key).info.EXTEND;      g_proc_batches(l_key).immortal.EXTEND;
        g_proc_batches(l_key).ids(l_n)       := p_process_rec.id;
        g_proc_batches(l_key).status(l_n)    := p_process_rec.status;
        g_proc_batches(l_key).procEnd(l_n)   := p_process_rec.processEnd;
        g_proc_batches(l_key).stepsTodo(l_n) := p_process_rec.stepsTodo;
        g_proc_batches(l_key).stepsDone(l_n) := p_process_rec.stepsDone;
        g_proc_batches(l_key).info(l_n)      := p_process_rec.info;
        g_proc_batches(l_key).immortal(l_n)  := p_process_rec.procImmortal;
    end;

    --------------------------------------------------------------------------
    -- STABILITY: bulk writing without FORALL ... SAVE EXCEPTIONS
    -- In Oracle, dynamic FORALL with SAVE EXCEPTIONS does not release PGA on each call
    -- (approx. 40 bytes per row, measured on 23.26; see test FEATURES/SPEICHER). On a server
    -- that runs for days, memory therefore grows without limit.
    -- Therefore: in the normal case one FORALL without SAVE EXCEPTIONS (equally fast). If a row fails,
    -- the FORALL aborts; the statement is rolled back (rollback of the autonomous transaction
    -- or to the savepoint in flushBatch) and the same rows are written individually
    -- (only in the error case). Faulty rows are, as before,
    -- skipped and logged, the others are kept.
    --------------------------------------------------------------------------
    -- Logs the error of a single row in the fallback.
    -- TRUE = abort the fallback (table missing, every further row would fail as well)
    function rowFailed(p_code number, p_msg varchar2, p_module varchar2, p_row pls_integer) return boolean
    is
    begin
        if p_code = -942 then
            -- Table missing: check and create again on the next NEW_SESSION
            g_checked_masters.DELETE; g_safe_tables.DELETE;
            logLilamErr(p_code, p_msg, p_module);
            return true;
        end if;
        logLilamErr(p_code, p_msg, p_module, 'row ' || p_row || ' skipped');
        return false;
    end;

    --------------------------------------------------------------------------

    procedure persist_log_data(
        p_processId    number,
        p_target_table varchar2,
        p_seqs         sys.odcinumberlist,
        p_levels       sys.odcinumberlist,
        p_levelsC      sys.odcivarchar2list,
        p_texts        sys.odcivarchar2list,
        p_times        t_timestamp_list_t,
        p_callers      sys.odcivarchar2list,
        p_stacks       sys.odcivarchar2list,
        p_backtraces   sys.odcivarchar2list,
        p_callstacks   sys.odcivarchar2list
    )
    as
        pragma autonomous_transaction;
        v_safe_table varchar2(150);
        v_stmt       varchar2(1000);
        v_user       varchar2(128);
        v_host       varchar2(128);
    begin
        -- PERFORMANCE: in the bundled flush only collect, flushBatch writes (see g_batch_mode)
        if g_batch_mode then
            if p_levels.count > 0 then
                appendLogBatch(p_processId, p_target_table, p_seqs, p_levels, p_levelsC, p_texts, p_times,
                               p_callers, p_stacks, p_backtraces, p_callstacks);
            end if;
            return;
        end if;

        if p_levels.count > 0 then            
            -- Security: validate the table name
            v_safe_table := safeTableName(p_target_table);
            v_user := SYS_CONTEXT('USERENV','SESSION_USER');
            v_host := SYS_CONTEXT('USERENV','HOST');
            v_stmt := 'insert into ' || v_safe_table || '
                    (PROCESS_ID, LOG_LEVEL, LOG_LEVEL_C, INFO, SESSION_TIME, NO, CALLER, ERR_STACK, ERR_BACKTRACE, ERR_CALLSTACK, SESSION_USER, HOST_NAME)
                    values (:1, :2, :3, :4, :5, :6, :7, :8, :9, :10, :11, :12)';
            begin
                -- Bulk insert over all collected log entries (STABILITY: without SAVE EXCEPTIONS, see rowFailed)
                forall i in 1 .. p_levels.count
                    execute immediate v_stmt
                    USING p_processId, p_levels(i), p_levelsC(i), p_texts(i), p_times(i), p_seqs(i), p_callers(i), p_stacks(i),
                          p_backtraces(i), p_callstacks(i), v_user, v_host;
            exception
                when others then
                    -- Fallback: write individually, skip faulty rows
                    rollback;
                    for i in 1 .. p_levels.count loop
                        begin
                            execute immediate v_stmt
                            USING p_processId, p_levels(i), p_levelsC(i), p_texts(i), p_times(i), p_seqs(i), p_callers(i), p_stacks(i),
                                  p_backtraces(i), p_callstacks(i), v_user, v_host;
                        exception
                            when others then
                                exit when rowFailed(sqlcode, sqlerrm, 'persist_log_data', i);
                        end;
                    end loop;
            end;
            commit;
        end if;

    exception
        when others then
            rollback;
            -- Table missing: check and create again on the next NEW_SESSION
            if sqlcode = -942 then g_checked_masters.DELETE; g_safe_tables.DELETE; end if;
            logLilamErr(sqlCode, sqlErrM, 'persist_log_data');

    end;

    --------------------------------------------------------------------------

    -- initializes writing to table
    -- decouples internal memory from autonomous transaction
    procedure flushLogs(p_processId number)
    as
        v_key          constant varchar2(100) := to_char(p_processId);
        v_targetTable  varchar2(150);
        v_idx_session  pls_integer;

        -- Bulk lists for the data transfer (schema-level types)
        v_levels       sys.odcinumberlist   := sys.odcinumberlist();
        v_levelsC      sys.odcivarchar2list := sys.odcivarchar2List();
        v_texts        sys.odcivarchar2list := sys.odcivarchar2list();
        v_times        t_timestamp_list_t   := t_timestamp_list_t(); 
        v_seqs         sys.odcinumberlist   := sys.odcinumberlist();
        v_callers      sys.odcivarchar2list := sys.odcivarchar2List();
        v_stacks       sys.odcivarchar2list := sys.odcivarchar2list();
        v_backtraces   sys.odcivarchar2list := sys.odcivarchar2list();
        v_callstacks   sys.odcivarchar2list := sys.odcivarchar2list();

        v_latency      number;
    begin
        -- 1. Check whether there is data for this process in the cache
        if not g_log_groups.EXISTS(v_key) or g_log_groups(v_key).COUNT = 0 then
            return;
        end if ;

        -- calc latency
        v_latency  := get_ms_diff(g_firstLogTimeStamp, systimestamp);
        g_avgLatencyLogs := round((g_avgLatencyLogs + v_latency) / g_logLatencyCounter, 2);
        if v_latency > g_maxLatencyLogs then g_maxLatencyLogs := v_latency; end if;

        -- 2. Determine the target table from the session list
        v_idx_session := v_indexSession(p_processId);
        v_targetTable := g_sessionList(v_idx_session).tabName_master || C_SUFFIX_LOG_TABLE;

        -- 3. Collect data from the hierarchical map into flat lists
        for i in 1 .. g_log_groups(v_key).COUNT loop
            v_levels.EXTEND;     v_levels(v_levels.LAST)     := g_log_groups(v_key)(i).log_level;
            v_levelsC.EXTEND;    v_levelsC(v_levelsC.LAST)   := logLevelToEnum(g_log_groups(v_key)(i).log_level);
            v_texts.EXTEND;      v_texts(v_texts.LAST)       := substrb(g_log_groups(v_key)(i).log_text, 1, 4000);
            v_times.EXTEND;      v_times(v_times.LAST)       := g_log_groups(v_key)(i).log_time;
            v_seqs.EXTEND;       v_seqs(v_seqs.LAST)         := g_log_groups(v_key)(i).serial_no;

            v_callers.EXTEND;     v_callers(v_callers.LAST)     := substrb(g_log_groups(v_key)(i).caller, 1, 200);
            -- Error stacks (limited to 4000 bytes for sys.odcivarchar2list)
            v_stacks.EXTEND;     v_stacks(v_stacks.LAST)     := substrb(g_log_groups(v_key)(i).err_stack, 1, 4000);
            v_backtraces.EXTEND; v_backtraces(v_backtraces.LAST) := substrb(g_log_groups(v_key)(i).err_backtrace, 1, 4000);
            v_callstacks.EXTEND; v_callstacks(v_callstacks.LAST) := substrb(g_log_groups(v_key)(i).err_callstack, 1, 4000);
        end loop;

        -- 4. Hand over to the autonomous bulk persistence
        persist_log_data(
            p_processId    => p_processId,
            p_target_table => v_targetTable,
            p_levels       => v_levels,
            p_levelsC      => v_levelsC,
            p_texts        => v_texts,
            p_times        => v_times,
            p_callers      => v_callers,
            p_seqs         => v_seqs,
            p_stacks       => v_stacks,
            p_backtraces   => v_backtraces,
            p_callstacks   => v_callstacks
        );

        -- 5. Clear the cache for this process
        g_log_groups(v_key).DELETE;

    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'flushLogs');

    end;

    --------------------------------------------------------------------------

    procedure write_to_log_buffer(
        p_processId number, 
        p_level number,
        p_text varchar2,
        p_logTime timestamp,
        p_caller varchar2,
        p_errStack varchar2,
        p_errBacktrace varchar2,
        p_errCallstack varchar2
    ) 
    is
        v_idx PLS_INTEGER;
        v_key varchar2(100) := to_char(p_processId);
        v_new_log t_log_buffer_rec;
    begin
        -- if there is no old value, this one will be the oldest when flush will be done
        if g_firstLogTimeStamp is null then 
            g_logLatencyCounter := g_logLatencyCounter + 1;
            g_firstLogTimeStamp := p_logTime;
        end if;

        v_idx := v_indexSession(p_processId);
        g_sessionList(v_idx).serial_no := coalesce(g_sessionList(v_idx).serial_no, 0) + 1;
        v_new_log.serial_no := g_sessionList(v_idx).serial_no;

        -- 1. Initialize the group
        if not g_log_groups.EXISTS(v_key) then
            g_log_groups(v_key) := t_log_history_tab();
        end if ;

        -- 2. Fill the record
        v_new_log.process_id    := p_processId; -- Now available
        v_new_log.log_level     := p_level;
        v_new_log.log_text      := p_text;
        v_new_log.log_time      := p_logTime;
        v_new_log.serial_no     := g_sessionList(v_indexSession(p_processId)).serial_no;
        v_new_log.caller        := p_caller;
        v_new_log.err_stack     := p_errStack;
        v_new_log.err_backtrace := p_errBacktrace;
        v_new_log.err_callstack := p_errCallstack;

        -- 3. Append to the cache
        g_log_groups(v_key).EXTEND;
        g_log_groups(v_key)(g_log_groups(v_key).LAST) := v_new_log;

        g_sessionList(v_idx).log_dirty_count := coalesce(g_sessionList(v_idx).log_dirty_count, 0) + 1;
        -- Put the ID into the dirty queue
        g_dirty_queue(p_processId) := TRUE;
    end;


    /*
        Methods dedicated to the g_monitorList
    */
    --------------------------------------------------------------------------
    -- Write monitor data to detail table
    --------------------------------------------------------------------------
    procedure persist_monitor_data(
        p_processId    number,
        p_target_table varchar2,
        p_actions      sys.odcivarchar2list,
        p_contexts     sys.odcivarchar2list,
        p_mon_types    sys.odcinumberlist,
        p_action_count sys.odcinumberlist,
        p_used         sys.odcinumberlist,
        p_avgs         sys.odcinumberlist,
        p_timesStart   t_timestamp_list_t,
        p_timesStop    t_timestamp_list_t
    )
    as
        pragma autonomous_transaction;
        v_user varchar2(128) := SYS_CONTEXT('USERENV','SESSION_USER');
        v_host varchar2(128) := SYS_CONTEXT('USERENV','HOST');
        v_safe_table varchar2(150);
        v_stmt       varchar2(1000);
    begin
        -- PERFORMANCE: in the bundled flush only collect, flushBatch writes (see g_batch_mode)
        if g_batch_mode then
            if p_actions.count > 0 then
                appendMonBatch(p_processId, p_target_table, p_actions, p_contexts, p_mon_types,
                               p_action_count, p_used, p_avgs, p_timesStart, p_timesStop);
            end if;
            return;
        end if;

        if p_actions.count > 0 then
            -- Security: validate the table name
            v_safe_table := safeTableName(p_target_table);
            v_stmt := 'insert into ' || v_safe_table || '
                (PROCESS_ID, ACTION, CONTEXT, MON_TYPE, ACTION_COUNT, USED_MILLIS, AVG_MILLIS, START_TIME, STOP_TIME, SESSION_USER, HOST_NAME)
                values (:1, :2, :3, :4, :5, :6, :7, :8, :9, :10, :11)';
            begin
                -- STABILITY: without SAVE EXCEPTIONS, see rowFailed
                forall i in 1 .. p_actions.count
                    execute immediate v_stmt
                    using p_processId, p_actions(i), p_contexts(i), p_mon_types(i), p_action_count(i), p_used(i), p_avgs(i), p_timesStart(i),
                          p_timesStop(i), v_user, v_host;
            exception
                when others then
                    -- Fallback: write individually, skip faulty rows
                    rollback;
                    for i in 1 .. p_actions.count loop
                        begin
                            execute immediate v_stmt
                            using p_processId, p_actions(i), p_contexts(i), p_mon_types(i), p_action_count(i), p_used(i), p_avgs(i), p_timesStart(i),
                                  p_timesStop(i), v_user, v_host;
                        exception
                            when others then
                                exit when rowFailed(sqlcode, sqlerrm, 'persist_monitor_data', i);
                        end;
                    end loop;
            end;
            commit;
        end if ;
    exception
        when others then
            rollback;
            -- Table missing: check and create again on the next NEW_SESSION
            if sqlcode = -942 then g_checked_masters.DELETE; g_safe_tables.DELETE; end if;
            logLilamErr(sqlCode, sqlErrM, 'persist_monitor_data');

    end;

    --------------------------------------------------------------------
    -- Sync the baselines (PGA) with LILAM_BASELINES via delta merge:
    -- Each session writes only its own change since the last
    -- sync (avg - base_avg, count - base_count) and then takes over
    -- the overall state from the DB. One writer => exact EWMA,
    -- several parallel writers => good approximation without lost updates.
    -- Unused, clean entries are removed from the PGA.
    --------------------------------------------------------------------
    PROCEDURE syncBaselines(p_force BOOLEAN DEFAULT FALSE)
    AS
        pragma autonomous_transaction;
        l_now        CONSTANT TIMESTAMP(6) := SYSTIMESTAMP;
        l_now_cs     CONSTANT NUMBER       := dbms_utility.get_time;
        l_key        VARCHAR2(250);
        l_next       VARCHAR2(250);
        l_dbKey      VARCHAR2(250);
        l_rec        t_baseline_rec;
        l_dbAvg      NUMBER;
        l_dbCnt      NUMBER;

        -- Delta updates for entries that exist in the DB
        l_upd_keys   sys.odcivarchar2list := sys.odcivarchar2list();
        l_upd_scope  sys.odcinumberlist   := sys.odcinumberlist();
        l_upd_action sys.odcivarchar2list := sys.odcivarchar2list();
        l_upd_ctx    sys.odcivarchar2list := sys.odcivarchar2list();
        l_upd_dAvg   sys.odcinumberlist   := sys.odcinumberlist();
        l_upd_dCnt   sys.odcinumberlist   := sys.odcinumberlist();
        l_upd_avg    sys.odcinumberlist   := sys.odcinumberlist();

        -- Return the new DB values
        l_ret_scope  sys.odcinumberlist   := sys.odcinumberlist();
        l_ret_action sys.odcivarchar2list := sys.odcivarchar2list();
        l_ret_ctx    sys.odcivarchar2list := sys.odcivarchar2list();
        l_ret_avg    sys.odcinumberlist   := sys.odcinumberlist();
        l_ret_cnt    sys.odcinumberlist   := sys.odcinumberlist();

        -- New entries (or entries no longer present in the DB)
        l_ins_keys   sys.odcivarchar2list := sys.odcivarchar2list();
        l_ins_avg    sys.odcinumberlist   := sys.odcinumberlist();
        l_ins_cnt    sys.odcinumberlist   := sys.odcinumberlist();

        TYPE t_key_lookup IS TABLE OF VARCHAR2(250) INDEX BY VARCHAR2(250);
        l_lookup     t_key_lookup;

        FUNCTION dbKey(p_scopeId NUMBER, p_action VARCHAR2, p_dbContext VARCHAR2) RETURN VARCHAR2 IS
        BEGIN
            RETURN p_scopeId || '|' || p_action || '|' || p_dbContext;
        END;

        PROCEDURE takeOver(p_key VARCHAR2, p_avg NUMBER, p_cnt NUMBER) IS
        BEGIN
            g_baselines(p_key).avg_ms       := p_avg;
            g_baselines(p_key).base_avg     := p_avg;
            g_baselines(p_key).action_count := p_cnt;
            g_baselines(p_key).base_count   := p_cnt;
            g_baselines(p_key).in_db        := TRUE;
            g_baselines(p_key).dirty        := FALSE;
        END;
    BEGIN
        IF g_baselines.COUNT = 0 THEN
            RETURN;
        END IF;

        IF NOT p_force AND g_last_baseline_sync IS NOT NULL
           AND get_ms_diff(g_last_baseline_sync, l_now) < C_BASELINE_SYNC_INTERVAL_MS THEN
            RETURN;
        END IF;
        g_last_baseline_sync := l_now;

        -- 1. Collect dirty entries, remove unused clean entries
        l_key := g_baselines.FIRST;
        WHILE l_key IS NOT NULL LOOP
            l_next := g_baselines.NEXT(l_key);
            l_rec  := g_baselines(l_key);

            IF l_rec.dirty THEN
                IF l_rec.in_db AND l_rec.base_avg IS NOT NULL THEN
                    l_upd_keys.EXTEND;   l_upd_keys(l_upd_keys.LAST)     := l_key;
                    l_upd_scope.EXTEND;  l_upd_scope(l_upd_scope.LAST)   := l_rec.scope_id;
                    l_upd_action.EXTEND; l_upd_action(l_upd_action.LAST) := l_rec.action_name;
                    l_upd_ctx.EXTEND;    l_upd_ctx(l_upd_ctx.LAST)       := nvl(l_rec.context_name, C_BASELINE_NULL_CONTEXT);
                    l_upd_dAvg.EXTEND;   l_upd_dAvg(l_upd_dAvg.LAST)     := l_rec.avg_ms - l_rec.base_avg;
                    l_upd_dCnt.EXTEND;   l_upd_dCnt(l_upd_dCnt.LAST)     := l_rec.action_count - l_rec.base_count;
                    l_upd_avg.EXTEND;    l_upd_avg(l_upd_avg.LAST)       := l_rec.avg_ms;
                    l_lookup(dbKey(l_rec.scope_id, l_rec.action_name, nvl(l_rec.context_name, C_BASELINE_NULL_CONTEXT))) := l_key;
                ELSE
                    l_ins_keys.EXTEND;   l_ins_keys(l_ins_keys.LAST)     := l_key;
                END IF;
            ELSIF l_rec.last_touch_cs IS NULL
               OR abs(l_now_cs - l_rec.last_touch_cs) / 100 > C_BASELINE_IDLE_EVICT_SEC THEN
                g_baselines.DELETE(l_key);
            END IF;

            l_key := l_next;
        END LOOP;

        IF l_upd_keys.COUNT = 0 AND l_ins_keys.COUNT = 0 THEN
            RETURN;
        END IF;

        -- 2. Delta merge as bulk update
        --    A negative result (extremely opposing parallel writers) is replaced by the own value.
        IF l_upd_keys.COUNT > 0 THEN
            FORALL i IN 1 .. l_upd_keys.COUNT
                EXECUTE IMMEDIATE
                   'update ' || C_LILAM_BASELINES_TABLE || '
                       set avg_ms       = CASE WHEN avg_ms + :1 > 0 THEN avg_ms + :2 ELSE :3 END,
                           action_count = action_count + :4,
                           last_update  = SYSTIMESTAMP
                     where scope_id = :5 and action_name = :6 and context_name = :7
                    returning scope_id, action_name, context_name, avg_ms, action_count into :8, :9, :10, :11, :12'
                USING l_upd_dAvg(i), l_upd_dAvg(i), l_upd_avg(i), l_upd_dCnt(i), l_upd_scope(i), l_upd_action(i), l_upd_ctx(i)
                RETURNING BULK COLLECT INTO l_ret_scope, l_ret_action, l_ret_ctx, l_ret_avg, l_ret_cnt;

            -- No longer present in the DB (e.g. deleted manually) => create again
            FOR i IN 1 .. l_upd_keys.COUNT LOOP
                IF SQL%BULK_ROWCOUNT(i) = 0 THEN
                    l_ins_keys.EXTEND; l_ins_keys(l_ins_keys.LAST) := l_upd_keys(i);
                END IF;
            END LOOP;
        END IF;

        -- 3. Create new entries; if another session creates them in parallel, a weighted average is used
        FOR i IN 1 .. l_ins_keys.COUNT LOOP
            l_rec := g_baselines(l_ins_keys(i));
            BEGIN
                EXECUTE IMMEDIATE
                    'insert into ' || C_LILAM_BASELINES_TABLE ||
                    ' (scope_id, action_name, context_name, avg_ms, action_count, last_update) values (:1, :2, :3, :4, :5, SYSTIMESTAMP)'
                    USING l_rec.scope_id, l_rec.action_name, nvl(l_rec.context_name, C_BASELINE_NULL_CONTEXT),
                          l_rec.avg_ms, l_rec.action_count - l_rec.base_count;
                l_dbAvg := l_rec.avg_ms;
                l_dbCnt := l_rec.action_count - l_rec.base_count;
            EXCEPTION
                WHEN DUP_VAL_ON_INDEX THEN
                    EXECUTE IMMEDIATE
                       'update ' || C_LILAM_BASELINES_TABLE || '
                           set avg_ms       = (nvl(avg_ms, 0) * action_count + :1 * :2) / nullif(action_count + :3, 0),
                               action_count = action_count + :4,
                               last_update  = SYSTIMESTAMP
                         where scope_id = :5 and action_name = :6 and context_name = :7
                        returning avg_ms, action_count into :8, :9'
                        USING l_rec.avg_ms, l_rec.action_count - l_rec.base_count, l_rec.action_count - l_rec.base_count,
                              l_rec.action_count - l_rec.base_count,
                              l_rec.scope_id, l_rec.action_name, nvl(l_rec.context_name, C_BASELINE_NULL_CONTEXT)
                        RETURNING INTO l_dbAvg, l_dbCnt;
            END;
            -- Remember values; they are taken over only after a successful commit
            l_ins_avg.EXTEND; l_ins_avg(l_ins_avg.LAST) := l_dbAvg;
            l_ins_cnt.EXTEND; l_ins_cnt(l_ins_cnt.LAST) := l_dbCnt;
        END LOOP;

        COMMIT;

        -- 4. Take over the overall state from the DB (new base for the next delta)
        FOR i IN 1 .. l_ret_scope.COUNT LOOP
            l_dbKey := dbKey(l_ret_scope(i), l_ret_action(i), l_ret_ctx(i));
            IF l_lookup.EXISTS(l_dbKey) THEN
                takeOver(l_lookup(l_dbKey), l_ret_avg(i), l_ret_cnt(i));
            END IF;
        END LOOP;

        FOR i IN 1 .. l_ins_keys.COUNT LOOP
            takeOver(l_ins_keys(i), l_ins_avg(i), l_ins_cnt(i));
        END LOOP;

    EXCEPTION
        WHEN OTHERS THEN
            -- Entries stay dirty, the delta is written again on the next sync
            ROLLBACK;
            logLilamErr(sqlCode, sqlErrM, 'syncBaselines');
    END;

    --------------------------------------------------------------------
    -- Write all dirty entries for all sessions
    --------------------------------------------------------------------
    PROCEDURE SYNC_ALL_DIRTY(p_force BOOLEAN DEFAULT FALSE, p_isShutdown BOOLEAN DEFAULT FALSE) 
    IS
        v_id      BINARY_INTEGER;
        v_next_id BINARY_INTEGER;
        v_idx     PLS_INTEGER;
        -- PERFORMANCE: GET_TIME (1/100 s) instead of SYSTIMESTAMP and get_ms_diff: runs on every log call
        v_now_cs  CONSTANT NUMBER := dbms_utility.get_time;
    BEGIN
        -- ======================================================================
        -- PART 0: TIME LOCK
        -- Without force, at most one run over all processes every C_SYNC_ALL_INTERVAL_MS.
        -- This way e.g. each INFO costs only one time comparison, regardless of
        -- the number of open processes. The flush thresholds (time/amount) remain unchanged.
        -- ABS: on overflow of GET_TIME there is at most one additional run.
        -- ======================================================================
        if NOT p_force AND NOT p_isShutdown
           AND g_last_sync_all_cs IS NOT NULL
           AND abs(v_now_cs - g_last_sync_all_cs) * 10 < C_SYNC_ALL_INTERVAL_MS
        then
            return;
        end if;
        g_last_sync_all_cs := v_now_cs;

        -- ======================================================================
        -- PART 1: PROCESSING THE DIRTY LIST (queue)
        -- PERFORMANCE: in batch mode persist_* only collect; flushBatch then writes
        -- all due processes together (one FORALL per table, one commit).
        -- ======================================================================
        g_batch_mode := TRUE;
        v_id := g_dirty_queue.FIRST;

        WHILE v_id IS NOT NULL LOOP
            v_next_id := g_dirty_queue.NEXT(v_id);

            if v_indexSession.EXISTS(v_id) THEN
                v_idx := v_indexSession(v_id);

                -- Timestamp check (cooldown logic)
                -- On force or shutdown we ignore the wait time
                if NOT p_force AND NOT p_isShutdown
                   AND g_sessionList(v_idx).last_sync_check IS NOT NULL 
                   AND (SYSTIMESTAMP - g_sessionList(v_idx).last_sync_check) < INTERVAL '1' SECOND 
                THEN
                    NULL; 
                ELSE
                    -- Synchronization (p_isShutdown is passed through)
                    sync_log(v_id, p_force);
                    sync_monitor(v_id, p_force);
                    sync_process(v_id, p_force);
                    g_sessionList(v_idx).last_sync_check := SYSTIMESTAMP;

                    -- Check: is the session "clean" now?
                    if p_force OR p_isShutdown OR (
                           coalesce(g_sessionList(v_idx).log_dirty_count, 0) = 0 
                       AND coalesce(g_sessionList(v_idx).monitor_dirty_count, 0) = 0
                       AND NOT g_sessionList(v_idx).process_is_dirty
                    ) THEN
                        g_dirty_queue.DELETE(v_id);
                        g_sessionList(v_idx).last_sync_check := NULL;
                    end if ;
                end if ;
            ELSE
                g_dirty_queue.DELETE(v_id);
            end if ;

            v_id := v_next_id;
        END LOOP;

        g_batch_mode := FALSE;
        flushBatch;

        -- ======================================================================
        -- PART 2: MASTER CLEANUP ON SHUTDOWN
        -- Here we clear the RAM remnants (round robin) of all known sessions
        -- ======================================================================
        if p_isShutdown THEN
            v_id := v_indexSession.FIRST;
            WHILE v_id IS NOT NULL LOOP
                -- Call flushMonitor directly to delete is_flushed=1 entries.
                -- Since p_isShutdown = TRUE, g_monitor_groups.DELETE(v_key) applies there.
                flushMonitor(v_id);

                v_id := v_indexSession.NEXT(v_id);
            END LOOP;
        end if ;

        -- ======================================================================
        -- PART 3: CROSS-PROCESS BASELINES (time-controlled or forced)
        -- ======================================================================
        syncBaselines(p_force OR p_isShutdown);

    EXCEPTION
        WHEN OTHERS THEN
            -- Batch mode must never stay active, otherwise later single flushes would only be collected too
            g_batch_mode := FALSE;
            logLilamErr(sqlCode, sqlErrM, 'SYNC_ALL_DIRTY');
            flushBatch;
    END SYNC_ALL_DIRTY;


    --------------------------------------------------------------------------
    -- Write monitor data to detail table
    --------------------------------------------------------------------------
    procedure flushMonitor(p_processId number)
    as
        v_id_prefix   constant varchar2(50) := LPAD(p_processId, 20, '0') || '|';
        v_group_key   varchar2(100);
        v_idx_session pls_integer;
        v_targetTable varchar2(150);
        v_keep_rec    t_monitor_buffer_rec;

        v_actions     sys.odcivarchar2list := sys.odcivarchar2list();
        v_contexts    sys.odcivarchar2list := sys.odcivarchar2list();
        v_mon_types   sys.odcinumberlist   := sys.odcinumberlist();
        v_action_count  sys.odcinumberlist := sys.odcinumberlist();
        v_used        sys.odcinumberlist   := sys.odcinumberlist();
        v_avgs        sys.odcinumberlist   := sys.odcinumberlist();
        v_timesStart  t_timestamp_list_t   := t_timestamp_list_t();
        v_timesStop   t_timestamp_list_t   := t_timestamp_list_t();

        v_latency     number := 0;
    begin
        v_idx_session := v_indexSession(p_processId);
        v_targetTable := g_sessionList(v_idx_session).tabName_master || C_SUFFIX_MON_TABLE;

        -- PERFORMANCE: the keys are sorted ("<process_id 20 digits>|action|context").
        -- Instead of iterating over all buffers of all processes and filtering via LIKE (quadratic
        -- effort with many open processes), start directly at the first key of this process
        -- and stop as soon as the prefix no longer matches.
        v_group_key := g_monitor_groups.NEXT(v_id_prefix);
        if v_group_key is not null and substr(v_group_key, 1, length(v_id_prefix)) != v_id_prefix then
            v_group_key := null;
        end if;

        if v_group_key is not null then
            -- calculate latency of oldest monitor entry until persistance
            v_latency  := get_ms_diff(g_firstMonTimeStamp, systimestamp);
            g_avgLatencyMon := round((g_avgLatencyMon + v_latency) / nvl(nullif(g_monLatencyCounter, 0), 1), 2);
            if v_latency > g_maxLatencyMon then g_maxLatencyMon := v_latency; end if;        
        end if;

        while v_group_key is not null loop     
            -- End of the keys of this process reached
            exit when substr(v_group_key, 1, length(v_id_prefix)) != v_id_prefix;
                -- 1. Collect everything that is currently in the bucket
                    for i in 1 .. g_monitor_groups(v_group_key).COUNT loop
                        v_actions.extend;      v_actions(v_actions.last)          := g_monitor_groups(v_group_key)(i).action_name;
                        v_contexts.extend;     v_contexts(v_contexts.last)        := g_monitor_groups(v_group_key)(i).context_name;
                        v_mon_types.extend;    v_mon_types(v_mon_types.last)      := g_monitor_groups(v_group_key)(i).monitor_type;
                        v_action_count.extend; v_action_count(v_action_count.last):= g_monitor_groups(v_group_key)(i).action_count;
                        v_used.extend;         v_used(v_used.last)                := g_monitor_groups(v_group_key)(i).used_time;
                        v_avgs.extend;         v_avgs(v_avgs.last)                := g_monitor_groups(v_group_key)(i).avg_action_time;
                        v_timesStart.extend;   v_timesStart(v_timesStart.last)    := g_monitor_groups(v_group_key)(i).start_time;
                        v_timesStop.extend;    v_timesStop(v_timesStop.last)      := g_monitor_groups(v_group_key)(i).stop_time;
                    end loop;

                -- 3. Radical clean-up in RAM (SGA/PGA hygiene)
                g_monitor_groups(v_group_key).DELETE;

            v_group_key := g_monitor_groups.NEXT(v_group_key);
        end loop;

        -- 5. Persist
        if v_actions.COUNT > 0 then
            persist_monitor_data(
                p_processId    => p_processId,
                p_target_table => v_targetTable,
                p_actions      => v_actions,
                p_contexts     => v_contexts,
                p_mon_types    => v_mon_types,
                p_action_count   => v_action_count,
                p_used         => v_used,
                p_avgs         => v_avgs,

                p_timesStart   => v_timesStart,
                p_timesStop    => v_timesStop
            );
            g_sessionList(v_idx_session).monitor_dirty_count := 0;
        end if ;

    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'flushMonitor'); 
            if should_raise_error(p_processId) then
                error(p_processId, 'Could not flush monitor data: ' || sqlErrM);
            end if ;
    end flushMonitor;

    --------------------------------------------------------------------------

    procedure sync_monitor(p_processId number, p_force boolean default false)
    as        
        v_idx varchar2(100);
        v_ms_since_flush NUMBER;
        v_now constant timestamp := systimestamp;

    begin
        -- 1. Get the index of the session
        if not v_indexSession.EXISTS(p_processId) then
            return;
        end if ;
        v_idx := v_indexSession(p_processId);

        -- If it has never been flushed (start), we set the difference high
        if g_sessionList(v_idx).last_monitor_flush is null then
            v_ms_since_flush := C_FLUSH_MILLIS_THRESHOLD_MS + 1;
        else
            v_ms_since_flush := get_ms_diff(g_sessionList(v_idx).last_monitor_flush, v_now);
        end if ;
        -- 4. The "smart" flush condition: amount OR time OR force
        if p_force 
           or g_sessionList(v_idx).monitor_dirty_count >= C_FLUSH_MONITOR_THRESHOLD_NO 
           or v_ms_since_flush >= C_FLUSH_MILLIS_THRESHOLD_MS
        then        
            flushMonitor(p_processId);
            g_firstMonTimeStamp := null;

            -- Reset the process-specific control data
            g_sessionList(v_idx).monitor_dirty_count := 0;
            g_sessionList(v_idx).last_monitor_flush  := v_now;
        end if ;

    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'sync_monitor'); 
            if should_raise_error(p_processId) then
                error(p_processId, 'Could not synchronize monitor data: ' || sqlErrM);
            end if ;
    end;

    --------------------------------------------------------------------------
    -- Arithmetic mean (used in the warm-up phase)
    --------------------------------------------------------------------------
    function calculate_avg(
        p_old_avg    number,
        p_curr_count pls_integer,
        p_new_value  number
    ) return number 
    is
    begin
        -- First measurement: the average is the value itself
        if p_old_avg is null or p_curr_count <= 1 then
            return p_new_value;
        end if ;

        -- Formula: ((avg_old * (n-1)) + value_new) / n
        return ((p_old_avg * (p_curr_count - 1)) + p_new_value) / p_curr_count;
    end;

    --------------------------------------------------------------------------
    -- Calculation average time used
    --------------------------------------------------------------------------
    function calculate_ewma(
        p_old_avg    number,      -- The previous average
        p_curr_count pls_integer, -- Running counter including the current measurement
        p_new_value  number,      -- Currently measured duration (ms)
        p_warmup     pls_integer default 100, -- Threshold for smoothing
        p_alpha      number      default 0.1  -- Weighting (0.1 = 10% new, 90% old)
    ) return number is
    begin
        -- Case 1: initialization (the very first record)
        if p_old_avg is null or p_old_avg = 0 or p_curr_count <= 1 then
            return p_new_value;
        end if;

        -- Case 2: warm-up phase
        -- Arithmetic mean until there is enough data for stable smoothing.
        -- This way a usable average is available during warm-up as well.
        if p_curr_count <= coalesce(p_warmup, 0) then
            return calculate_avg(p_old_avg, p_curr_count, p_new_value);
        end if;

        -- Case 3: EWMA
        -- Formula: old + alpha * (new - old)
        return p_old_avg + coalesce(p_alpha, 0.1) * (p_new_value - p_old_avg);
    end;

    --------------------------------------------------------------------------
    -- Start Tracing remote
    --------------------------------------------------------------------------    
    procedure startTraceRemote(p_processId number, p_actionName varchar2, p_contextName varchar2, p_timestamp timestamp default systimestamp)
    as
        l_payload JSON_OBJ_LILAM; -- Buffer for the JSON string
    begin
        -- PERFORMANCE: concatenate the message directly instead of via jsonPut (see jStr/jNum/jTs)
        l_payload := '{"process_id":' || jNum(p_processId)
                  || jStr('action_name',  p_actionName)
                  || jStr('context_name', p_contextName)
                  || jTs ('timestamp',    p_timestamp) || '}';

        sendNoWait(p_processId, 'START_TRACE', l_payload, 0.5);

    EXCEPTION
        WHEN OTHERS THEN
            logLilamErr(sqlCode, sqlErrM, 'startTraceRemote'); 
    end;

    --------------------------------------------------------------------------
    -- Creating and adding/updating a trace entry in the monitor list
    --------------------------------------------------------------------------    
    procedure insertTraceMonitorRemote(p_processId number, p_actionName varchar2, p_contextName varchar2, p_timestamp timestamp default systimestamp)
    as
        l_payload JSON_OBJ_LILAM; -- Buffer for the JSON string
    begin
        -- Since this runs via the PIPE and it is therefore not guaranteed that the time
        -- is still 'in time' when insertMonitor is called later in the server,
        -- the time must be set by the client at the time of the call.
        -- Creating the JSON object
        -- PERFORMANCE: concatenate the message directly instead of via jsonPut (see jStr/jNum/jTs)
        l_payload := '{"process_id":' || jNum(p_processId)
                  || jStr('action_name',  p_actionName)
                  || jStr('context_name', p_contextName)
                  || jTs ('timestamp',    p_timestamp) || '}';

        sendNoWait(p_processId, 'STOP_TRACE', l_payload, 0.5);

    EXCEPTION
        WHEN OTHERS THEN
            logLilamErr(sqlCode, sqlErrM, 'insertTraceMonitorRemote'); 
    end;

    --------------------------------------------------------------------------

    --------------------------------------------------------------------------
    -- Creating and adding/updating a record in the monitor list
    --------------------------------------------------------------------------    
    procedure insertEventMonitorRemote(p_processId number, p_actionName varchar2, p_contextName varchar2, p_timestamp timestamp)
    as
        l_payload JSON_OBJ_LILAM; -- Buffer for the JSON string
    begin
        if p_timestamp is null then raise_application_error(-2005, 'Event ohne Zeitangabe'); end if;

        -- Since this runs via the PIPE and it is therefore not guaranteed that the time
        -- is still 'in time' when insertMonitor is called later in the server,
        -- the time must be set by the client at the time of the call.
        -- Creating the JSON object
        -- PERFORMANCE: concatenate the message directly instead of via jsonPut (see jStr/jNum/jTs)
        l_payload := '{"process_id":' || jNum(p_processId)
                  || jStr('action_name',  p_actionName)
                  || jStr('context_name', p_contextName)
                  || jTs ('timestamp',    p_timestamp) || '}';

        sendNoWait(p_processId, C_MARK_EVENT, l_payload, 0.5);

    EXCEPTION
        WHEN OTHERS THEN
            logLilamErr(sqlCode, sqlErrM, 'insertEventMonitorRemote'); 
 
    end;

    --------------------------------------------------------------------------

    -- Baseline parameters from AVG_DEVIATION_PCT rules of the process's group, otherwise DEFAULT
    function findAvgRule(p_processId number, p_action varchar2, p_context varchar2) return t_avg_params
    as
        l_group   varchar2(50);
        l_ruleKey varchar2(300);
    begin
        if v_indexSession.EXISTS(p_processId) then
            l_group := g_sessionList(v_indexSession(p_processId)).rule_group;
        end if;
        if l_group is not null then
            l_ruleKey := l_group || '|' || p_action;
            IF g_avg_params.EXISTS(l_ruleKey || '|' || p_context) THEN
                return g_avg_params(l_ruleKey || '|' || p_context);
            ELSIF g_avg_params.EXISTS(l_ruleKey) THEN
                return g_avg_params(l_ruleKey);
            end if;
        end if;
        return g_avg_params('DEFAULT');
    end;

    --------------------------------------------------------------------------
    -- Calculates the average (avg_action_time) and the rule reference (baseline_avg)
    -- for a new measurement in p_rec (used_time must be set).
    -- With scope:  cross-process baseline (g_baselines)
    -- Without scope or on errors: process-local as before
    -- baseline_avg is the average BEFORE the measurement; NULL during warm-up,
    -- so that AVG_DEVIATION_PCT only applies once the baseline is stable.
    --------------------------------------------------------------------------
    procedure applyBaseline(
        p_processId   number,
        p_prevAvg     number,        -- process-local average before the measurement
        p_prevCount   pls_integer,   -- process-local number of measurements before this one
        p_rec         in out nocopy t_monitor_buffer_rec
    )
    as
        l_params  t_avg_params;
        l_scopeId number;
        l_key     varchar2(250);
        l_oldAvg  number;
        l_oldCnt  number;
    begin
        l_params  := findAvgRule(p_processId, p_rec.action_name, p_rec.context_name);
        l_scopeId := getScopeId(p_processId);

        if l_scopeId is not null then
            begin
                l_key := buildBaselineKey(l_scopeId, p_rec.action_name, p_rec.context_name);
                ensureBaseline(l_key, l_scopeId, p_rec.action_name, p_rec.context_name);

                l_oldAvg := g_baselines(l_key).avg_ms;
                l_oldCnt := g_baselines(l_key).action_count;

                g_baselines(l_key).action_count := l_oldCnt + 1;
                g_baselines(l_key).avg_ms       := calculate_ewma(l_oldAvg, l_oldCnt + 1, p_rec.used_time, l_params.warmup, l_params.alpha);
                g_baselines(l_key).dirty        := TRUE;
                g_baselines(l_key).last_touch_cs := dbms_utility.get_time;  -- PERFORMANCE: per trace/event, therefore no SYSTIMESTAMP

                p_rec.avg_action_time := g_baselines(l_key).avg_ms;
                p_rec.baseline_avg    := CASE WHEN l_oldCnt >= coalesce(l_params.warmup, 0) THEN l_oldAvg END;
                return;
            exception
                when others then
                    -- Switch off the scope for this session and continue process-locally
                    logLilamErr(sqlCode, sqlErrM, 'applyBaseline', 'scope_id=' || l_scopeId || '; scope disabled for process ' || p_processId);
                    setScopeId(p_processId, null);
            end;
        end if;

        p_rec.avg_action_time := calculate_ewma(p_prevAvg, p_prevCount + 1, p_rec.used_time, l_params.warmup, l_params.alpha);
        p_rec.baseline_avg    := CASE WHEN p_prevCount >= coalesce(l_params.warmup, 0) THEN p_prevAvg END;
    end;

    --------------------------------------------------------------------------

    procedure writeEventToMonitorBuffer (p_processId number, p_actionName varchar2, p_contextName varchar2, p_timestamp timestamp)
    as
        -- Key prefix should ideally contain p_processId for faster flush access
        v_key        constant varchar2(200) := buildMonitorKey(p_processId, p_actionName, p_contextName);
        l_new_idx    PLS_INTEGER;
        v_idx        PLS_INTEGER;
        l_prev       t_monitor_buffer_rec; 
        l_rec        t_monitor_buffer_rec;
    begin
        if is_remote(p_processId) then
            insertEventMonitorRemote(p_processId, p_actionName, p_contextName, p_timestamp);
            return;
        end if ;

        -- Unknown process (neither local nor reachable via dispatcher): ignore silently
        if not v_indexSession.EXISTS(p_processId) then
            return;
        end if;

        -- this event will be the oldest when flush happens
        if g_firstMonTimeStamp is null then 
            g_monLatencyCounter := g_monLatencyCounter + 1;
            g_firstMonTimeStamp := p_timestamp; 
        end if;

        -- 0. Monitoring check (log level check)
        if v_indexSession.EXISTS(p_processId) and 
           logLevelMonitor > g_sessionList(v_indexSession(p_processId)).log_level then
            return;
        end if ;

        l_rec.process_id   := p_processId;
        l_rec.action_name  := p_actionName;
        l_rec.context_name := p_contextName;
        l_rec.monitor_type := C_MON_TYPE_EVENT;
        l_rec.start_time   := coalesce(p_timestamp, systimestamp);

        -- The next values depend on whether there is a predecessor
        -- The distance to the previous event (within the process) is measured.
        if g_monitor_shadows.EXISTS(v_key) then            -- There is a predecessor
            l_prev := g_monitor_shadows(v_key);
            l_rec.action_count := l_prev.action_count + 1;
            l_rec.used_time    := get_ms_diff(l_prev.start_time, l_rec.start_time);

            -- Number of measured distances before this one = action_count of the predecessor - 1
            applyBaseline(
                p_processId => p_processId,
                p_prevAvg   => CASE WHEN l_prev.action_count > 1 THEN l_prev.avg_action_time END,
                p_prevCount => l_prev.action_count - 1,
                p_rec       => l_rec
            );
        ELSE
            -- First entry of the session/action
            l_rec.action_count    := 1;
            l_rec.used_time       := 0; -- First marker has no duration
            l_rec.avg_action_time := 0;
            l_rec.baseline_avg    := NULL;
        end if ;

        if NOT g_monitor_groups.EXISTS(v_key) THEN
            g_monitor_groups(v_key) := t_monitor_history_tab();
        end if ;
        g_monitor_groups(v_key).EXTEND;
        l_new_idx := g_monitor_groups(v_key).LAST;
        g_monitor_groups(v_key)(l_new_idx) := l_rec;

        -- check the rules before overwriting the shadow entry
        evaluateRules(g_monitor_groups(v_key)(l_new_idx), C_MARK_EVENT);
        g_monitor_shadows(v_key) := g_monitor_groups(v_key)(g_monitor_groups(v_key).LAST);         

        v_idx := v_indexSession(p_processId);
        g_sessionList(v_idx).monitor_dirty_count := coalesce(g_sessionList(v_idx).monitor_dirty_count, 0) + 1;
        g_dirty_queue(p_processId) := TRUE; 

    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'writeEventToMonitorBuffer'); 
            if should_raise_error(p_processId) then
                error(p_processId, 'Could not buffer event data: ' || sqlErrM);
            end if ;
    end;

    --------------------------------------------------------------------------

    procedure startTrace (p_processId number, p_actionName varchar2, p_contextName varchar2, p_timestamp timestamp)
    as
        v_key constant varchar2(200) := buildMonitorKey(p_processId, p_actionName, p_contextName);
        v_dummyMonRec   t_monitor_buffer_rec;
    begin
        if is_remote(p_processId) then
            startTraceRemote(p_processId, p_actionName, p_contextName, p_timestamp);
            return;
        end if ;

        -- Unknown process (neither local nor reachable via dispatcher): ignore silently
        if not v_indexSession.EXISTS(p_processId) then
            return;
        end if;

        -- Dummy for the rules only
        v_dummyMonRec.process_id := p_processId;
        v_dummyMonRec.start_time := coalesce(p_timestamp, systimestamp);
        v_dummyMonRec.stop_time := null;
        v_dummyMonRec.monitor_type := C_MON_TYPE_TRACE;
        v_dummyMonRec.action_name := p_actionName;
        v_dummyMonRec.context_name := p_contextName;

        evaluateRules(v_dummyMonRec, C_TRACE_START);
        g_monitor_shadows(v_key) := v_dummyMonRec;
        
    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'startTrace'); 
    end;

    --------------------------------------------------------------------------

    procedure writeTraceToMonitorBuffer (p_processId number, p_actionName varchar2, p_contextName varchar2, p_timestamp timestamp)
    as
        -- Key prefix should ideally contain p_processId for faster flush access
        v_key        constant varchar2(200) := buildMonitorKey(p_processId, p_actionName, p_contextName);
        v_used_time  number := 0;
        v_new_avg    number := 0;
        v_new_rec    t_monitor_buffer_rec;
        v_first_idx  PLS_INTEGER;
        l_new_idx    PLS_INTEGER;
        v_idx        PLS_INTEGER;
        l_prevAvg    number;
        l_prevCnt    PLS_INTEGER;
    begin
        if is_remote(p_processId) then
            insertTraceMonitorRemote(p_processId, p_actionName, p_contextName, p_timestamp);
            return;
        end if ;

        -- Unknown process (neither local nor reachable via dispatcher): ignore silently
        if not v_indexSession.EXISTS(p_processId) then
            return;
        end if;

        -- this will be the oldest entry when flush happens
        if g_firstMonTimeStamp is null then g_firstMonTimeStamp := p_timestamp; end if;

        if v_indexSession.EXISTS(p_processId) and 
           logLevelMonitor > g_sessionList(v_indexSession(p_processId)).log_level then
            return;
        end if ;

        -- check if open transaction exists
        if NOT g_monitor_shadows.EXISTS(v_key) then
            return;
        end if;

        v_new_rec           := g_monitor_shadows(v_key);
        v_new_rec.stop_time := coalesce(p_timestamp, systimestamp);
        v_new_rec.used_time := get_ms_diff(v_new_rec.start_time, v_new_rec.stop_time);

        -- action_count stays process-local (n-th execution in the process; _MON and MAX_OCCURRENCE)
        IF g_monitor_averages.EXISTS(v_key) THEN
            l_prevAvg := g_monitor_averages(v_key).avg_action_time;
            l_prevCnt := g_monitor_averages(v_key).action_count;
        ELSE
            l_prevAvg := NULL;
            l_prevCnt := 0;
        END IF;
        v_new_rec.action_count := l_prevCnt + 1;

        -- Average: cross-process (scope) or process-local
        applyBaseline(p_processId, l_prevAvg, l_prevCnt, v_new_rec);

        -- Update the memory for the next run
        g_monitor_averages(v_key) := v_new_rec;

        if NOT g_monitor_groups.EXISTS(v_key) THEN
            g_monitor_groups(v_key) := t_monitor_history_tab();
        end if ;
        g_monitor_groups(v_key).EXTEND;
        g_monitor_groups(v_key)(g_monitor_groups(v_key).LAST) := v_new_rec;

        -- Pass the event on to the rule check
        evaluateRules(v_new_rec, C_TRACE_STOP);
        g_monitor_shadows.delete(v_key);

        v_idx := v_indexSession(p_processId);            
        g_sessionList(v_idx).monitor_dirty_count := coalesce(g_sessionList(v_idx).monitor_dirty_count, 0) + 1;
        g_dirty_queue(p_processId) := TRUE; 

    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'writeTraceToMonitorBuffer'); 
            if should_raise_error(p_processId) then
                error(p_processId, 'Could not buffer trace data: ' || sqlErrM);
            end if ;
    end;

    --------------------------------------------------------------------------
    -- Removing a record from monitor list
    --------------------------------------------------------------------------
    procedure removeMonitor(p_processId number, p_actionName varchar2, p_contextName varchar2)
    as
        v_key constant varchar2(200) := buildMonitorKey(p_processId, p_actionName, p_contextName);
    begin
        -- 1. Delete history
        if g_monitor_groups.EXISTS(v_key) then
            g_monitor_groups.DELETE(v_key);
        end if ;
    end;

    --------------------------------------------------------------------------
    -- Removing a record from monitor list
    --------------------------------------------------------------------------
    function getLastMonitorEntry(p_processId number, p_actionName varchar2, p_contextName varchar2) return t_monitor_buffer_rec
    as
        v_key    constant varchar2(200) := buildMonitorKey(p_processId, p_actionName, p_contextName);
        v_empty  t_monitor_buffer_rec; -- Initially empty record as fallback
    begin
        -- 1. Check whether the group (action) exists in the cache
        if g_monitor_groups.EXISTS(v_key) then
            -- 2. Check whether the history list has entries
            if g_monitor_groups(v_key).COUNT > 0 then
                -- Return the last entry (LAST) of the nested list
                return g_monitor_groups(v_key)(g_monitor_groups(v_key).LAST);
            end if ;
        end if ;

        -- If nothing was found, an empty record is returned
        return v_empty;

    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'getLastMonitorEntry'); 
            if should_raise_error(p_processId) then
                error(p_processId, 'Could not search or read last monitor entry: ' || sqlErrM);
            end if ;
            return v_empty;
    end;

    ----------------------------------------------------------------------

    function hasMonitorEntry(p_processId number, p_actionName varchar2, p_contextName varchar2) return boolean
    is
        v_key constant varchar2(200) := buildMonitorKey(p_processId, p_actionName, p_contextName);
    begin
        if not g_monitor_groups.EXISTS(v_key) then
            return false;
        end if ;
        return (g_monitor_groups(v_key).COUNT > 0);

    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'hasMonitorEntry'); 
            if should_raise_error(p_processId) then
                error(p_processId, 'Checking "monitor entry exists" failed: ' || sqlErrM);
            end if ;
            return false;
    end;

    --------------------------------------------------------------------------
    -- Monitoring a step
    --------------------------------------------------------------------------
    PROCEDURE MARK_EVENT(p_processId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2 default NULL, p_timestamp timestamp default NULL)
    as
        l_timestamp TIMESTAMP(6);
    begin
        l_timestamp := coalesce(p_timestamp, SYSTIMESTAMP);
        writeEventToMonitorBuffer (p_processId, p_actionName, p_contextName, l_timestamp);     
    end;
    --------------------------------------------------------------------------


    --------------------------------------------------------------------------
    -- Monitoring a transaction
    --------------------------------------------------------------------------
    PROCEDURE TRACE_START(p_processId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2 default null, p_timestamp timestamp default NULL)
    as
        l_timestamp TIMESTAMP(6);
    begin
        l_timestamp := coalesce(p_timestamp, SYSTIMESTAMP);
        startTrace (p_processId, p_actionName, p_contextName, l_timestamp);     
    end;
    --------------------------------------------------------------------------

    PROCEDURE TRACE_STOP(p_processId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2 default null, p_timestamp TIMESTAMP DEFAULT NULL)
    as
        l_timestamp TIMESTAMP(6);
    begin
        l_timestamp := coalesce(p_timestamp, SYSTIMESTAMP);
        writeTraceToMonitorBuffer(p_processId, p_actionName, p_contextName, l_timestamp);
    end;

    --------------------------------------------------------------------------

    function getLastMonitorEntryRemote(p_processId number, p_actionName varchar2, p_contextName varchar2) return t_monitor_buffer_rec
    as
        l_response varchar2(1000);
        l_payload  varchar2(1000);
        v_rec t_monitor_buffer_rec;
    begin
        select json_object(
            'process_id'   value p_processId,
            'action_name'  value p_actionName,
            'context_name' value p_contextName
            returning varchar2
        )
        into l_payload from dual;  
        l_response := waitForResponse(p_processId, 'GET_MONITOR_LAST_ENTRY', l_payload, 5);

        if l_response not in ('TIMEOUT', 'THROTTLED') AND l_response not like 'ERROR%' THEN
            l_payload := JSON_QUERY(l_response, '$.payload');
            v_rec.action_count  := jsonNumber(l_payload, 'action_count');
            v_rec.used_time  := jsonNumber(l_payload, 'used_time');
            v_rec.start_time  := jsonTime(l_payload, 'start_time');
            v_rec.stop_time  := jsonTime(l_payload, 'stop_time');
            v_rec.avg_action_time  := jsonNumber(l_payload, 'avg_action_time');
        end if;
        return v_rec;
    end;

    --------------------------------------------------------------------------

    FUNCTION GET_METRIC_AVG_DURATION(p_processId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2) return NUMBER
    as
        v_rec t_monitor_buffer_rec;
    begin
        if is_remote(p_processId) then
            v_rec := getLastMonitorEntryRemote(p_processId, p_actionName, p_contextName);
            return v_rec.avg_action_time;
        end if ;

        v_rec := getLastMonitorEntry(p_processId, p_actionName, p_contextName);
        RETURN coalesce(v_rec.avg_action_time, 0);
    end;

    --------------------------------------------------------------------------

    FUNCTION GET_METRIC_STEPS(p_processId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2) return NUMBER
    as
        v_rec t_monitor_buffer_rec;
    begin
        if is_remote(p_processId) then
            v_rec := getLastMonitorEntryRemote(p_processId, p_actionName, p_contextName);
            return v_rec.action_count;
        end if ;

        v_rec := getLastMonitorEntry(p_processId, p_actionName, p_contextName);
        RETURN coalesce(v_rec.action_count, 0);
    end;

    --------------------------------------------------------------------------
    /*
        Methods dedicated to config
    */

    --------------------------------------------------------------------------


    /*
        Methods dedicated to the g_sessionList
    */

    -- Delivers a record of the internal list which belongs to the process id
    -- Return value is NULL BUT! datatype RECORD cannot be validated by IS NULL.
    -- RECORDs are always initialized.
    -- So you have to check by something like
    -- if getSessionRecord(my_id).process_id IS NULL ...
    function getSessionRecord(p_processId number) return t_session_rec
    as
        listIndex number;
    begin
        if not v_indexSession.EXISTS(p_processId) THEN        
            return null;
        else
            listIndex := v_indexSession(p_processId);
            return g_sessionList(listIndex);
        end if ;

    end;

    --------------------------------------------------------------------------

    -- Set values of a stored record in the internal process list by a given record
    procedure updateSessionRecord(p_sessionRecord t_session_rec)
    as
        listIndex number;
    begin
        listIndex := v_indexSession(p_sessionRecord.process_id);
        g_sessionList(listIndex) := p_sessionRecord;
    end;

    --------------------------------------------------------------------------

    -- Creating and adding a new record to the process list
    -- and persist to config table
    procedure insertSession (p_tabName varchar2, p_processId number, p_logLevel PLS_INTEGER)
    as
        v_new_idx PLS_INTEGER;
    begin
        if g_sessionList is null then
                g_sessionList := t_session_tab(); 
        end if ;

        if getSessionRecord(p_processId).process_id is null then
            -- new record
            g_sessionList.extend;
            v_new_idx := g_sessionList.last;
        else
            v_new_idx := v_indexSession(p_processId);
        end if ;

        g_sessionList(v_new_idx).process_id         := p_processId;
        g_sessionList(v_new_idx).log_level          := p_logLevel;
        g_sessionList(v_new_idx).tabName_master     := p_tabName;
            -- Timestamp for flushing   
        g_sessionList(v_new_idx).last_monitor_flush := systimestamp;
        g_sessionList(v_new_idx).last_log_flush     := systimestamp;
        g_sessionList(v_new_idx).monitor_dirty_count := 0;
        g_sessionList(v_new_idx).log_dirty_count := 0;

        v_indexSession(p_processId) := v_new_idx;

    end;

    --------------------------------------------------------------------------

    -- Updates the status of a log entry in the main log table.
    procedure persist_process_record(p_process_rec t_process_rec)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(1000);
    begin
        -- PERFORMANCE: in the bundled flush only collect, flushBatch writes (see g_batch_mode)
        if g_batch_mode then
            appendProcBatch(p_process_rec);
            return;
        end if;

        sqlStatement := '
        update ' || C_PARAM_MASTER_TABLE || '
        set status           = :PH_STATUS,
            last_update      = systimestamp,
            process_end      = :PH_PROCESS_END,
            steps_todo  = :PH_steps_todo,
            steps_done  = :PH_steps_done,
            info             = :PH_INFO,
            process_immortal = :PH_IMMORTAL
        where id = :PH_PROCESS_ID';  

        sqlStatement := replaceNameTable(sqlStatement, C_PARAM_MASTER_TABLE, C_SUFFIX_PROC_TABLE, p_process_rec.tabNameMaster);
        execute immediate sqlStatement
        USING   p_process_rec.status, 
                p_process_rec.processEnd,
                p_process_rec.stepsTodo,
                p_process_rec.stepsDone,
                p_process_rec.info,
                p_process_rec.procImmortal,
                p_process_rec.id;

        commit;

    exception
        when others then
            rollback; -- end the transaction in the error case
            logLilamErr(sqlCode, sqlErrM, 'persist_process_record', 'EXECUTE IMMEDIATE');
            
    end;

    --------------------------------------------------------------------------
    -- PERFORMANCE: writes the rows of all processes collected in SYNC_ALL_DIRTY.
    -- One FORALL per target table, ONE commit for everything together (autonomous transaction).
    -- STABILITY: without SAVE EXCEPTIONS (see rowFailed). If a FORALL fails, only this
    -- statement is rolled back to its savepoint and its rows are written individually;
    -- faulty rows are logged and skipped, the others are kept.
    -- The other tables are not affected by this.
    --------------------------------------------------------------------------
    procedure flushBatch
    as
        pragma autonomous_transaction;
        v_user  constant varchar2(128) := SYS_CONTEXT('USERENV','SESSION_USER');
        v_host  constant varchar2(128) := SYS_CONTEXT('USERENV','HOST');
        v_key   varchar2(150);
        v_table varchar2(150);
        v_stmt  varchar2(1000);

        procedure handleErr(p_code number, p_msg varchar2, p_module varchar2) is
        begin
            if p_code = -942 then g_checked_masters.DELETE; g_safe_tables.DELETE; end if;
            logLilamErr(p_code, p_msg, p_module);
        end;
    begin
        -- Logs
        v_key := g_log_batches.FIRST;
        while v_key is not null loop
            begin
                v_table := safeTableName(v_key);
                v_stmt := 'insert into ' || v_table || '
                        (PROCESS_ID, LOG_LEVEL, LOG_LEVEL_C, INFO, SESSION_TIME, NO, CALLER, ERR_STACK, ERR_BACKTRACE, ERR_CALLSTACK, SESSION_USER, HOST_NAME)
                        values (:1, :2, :3, :4, :5, :6, :7, :8, :9, :10, :11, :12)';
                savepoint sp_flush_log;
                begin
                    forall i in 1 .. g_log_batches(v_key).pids.COUNT
                        execute immediate v_stmt
                        USING g_log_batches(v_key).pids(i), g_log_batches(v_key).levels(i), g_log_batches(v_key).levelsC(i),
                              g_log_batches(v_key).texts(i), g_log_batches(v_key).times(i), g_log_batches(v_key).seqs(i),
                              g_log_batches(v_key).callers(i), g_log_batches(v_key).stacks(i), g_log_batches(v_key).backtraces(i),
                              g_log_batches(v_key).callstacks(i), v_user, v_host;
                exception
                    when others then
                        -- Fallback: write individually, skip faulty rows
                        rollback to savepoint sp_flush_log;
                        for i in 1 .. g_log_batches(v_key).pids.COUNT loop
                            begin
                                execute immediate v_stmt
                                USING g_log_batches(v_key).pids(i), g_log_batches(v_key).levels(i), g_log_batches(v_key).levelsC(i),
                                      g_log_batches(v_key).texts(i), g_log_batches(v_key).times(i), g_log_batches(v_key).seqs(i),
                                      g_log_batches(v_key).callers(i), g_log_batches(v_key).stacks(i), g_log_batches(v_key).backtraces(i),
                                      g_log_batches(v_key).callstacks(i), v_user, v_host;
                            exception
                                when others then
                                    exit when rowFailed(sqlcode, sqlerrm, 'flushBatch/LOG', i);
                            end;
                        end loop;
                end;
            exception
                when others then handleErr(sqlcode, sqlerrm, 'flushBatch/LOG');
            end;
            v_key := g_log_batches.NEXT(v_key);
        end loop;

        -- Monitor
        v_key := g_mon_batches.FIRST;
        while v_key is not null loop
            begin
                v_table := safeTableName(v_key);
                v_stmt := 'insert into ' || v_table || '
                        (PROCESS_ID, ACTION, CONTEXT, MON_TYPE, ACTION_COUNT, USED_MILLIS, AVG_MILLIS, START_TIME, STOP_TIME, SESSION_USER, HOST_NAME)
                        values (:1, :2, :3, :4, :5, :6, :7, :8, :9, :10, :11)';
                savepoint sp_flush_mon;
                begin
                    forall i in 1 .. g_mon_batches(v_key).pids.COUNT
                        execute immediate v_stmt
                        USING g_mon_batches(v_key).pids(i), g_mon_batches(v_key).actions(i), g_mon_batches(v_key).contexts(i),
                              g_mon_batches(v_key).mon_types(i), g_mon_batches(v_key).action_count(i), g_mon_batches(v_key).used(i),
                              g_mon_batches(v_key).avgs(i), g_mon_batches(v_key).timesStart(i), g_mon_batches(v_key).timesStop(i),
                              v_user, v_host;
                exception
                    when others then
                        -- Fallback: write individually, skip faulty rows
                        rollback to savepoint sp_flush_mon;
                        for i in 1 .. g_mon_batches(v_key).pids.COUNT loop
                            begin
                                execute immediate v_stmt
                                USING g_mon_batches(v_key).pids(i), g_mon_batches(v_key).actions(i), g_mon_batches(v_key).contexts(i),
                                      g_mon_batches(v_key).mon_types(i), g_mon_batches(v_key).action_count(i), g_mon_batches(v_key).used(i),
                                      g_mon_batches(v_key).avgs(i), g_mon_batches(v_key).timesStart(i), g_mon_batches(v_key).timesStop(i),
                                      v_user, v_host;
                            exception
                                when others then
                                    exit when rowFailed(sqlcode, sqlerrm, 'flushBatch/MON', i);
                            end;
                        end loop;
                end;
            exception
                when others then handleErr(sqlcode, sqlerrm, 'flushBatch/MON');
            end;
            v_key := g_mon_batches.NEXT(v_key);
        end loop;

        -- Process records (_PROC)
        v_key := g_proc_batches.FIRST;
        while v_key is not null loop
            begin
                v_stmt := '
                update ' || C_PARAM_MASTER_TABLE || '
                set status           = :1,
                    last_update      = systimestamp,
                    process_end      = :2,
                    steps_todo       = :3,
                    steps_done       = :4,
                    info             = :5,
                    process_immortal = :6
                where id = :7';
                v_stmt := replaceNameTable(v_stmt, C_PARAM_MASTER_TABLE, C_SUFFIX_PROC_TABLE, v_key);
                savepoint sp_flush_proc;
                begin
                    forall i in 1 .. g_proc_batches(v_key).ids.COUNT
                        execute immediate v_stmt
                        USING g_proc_batches(v_key).status(i), g_proc_batches(v_key).procEnd(i), g_proc_batches(v_key).stepsTodo(i),
                              g_proc_batches(v_key).stepsDone(i), g_proc_batches(v_key).info(i), g_proc_batches(v_key).immortal(i),
                              g_proc_batches(v_key).ids(i);
                exception
                    when others then
                        -- Fallback: write individually, skip faulty rows
                        rollback to savepoint sp_flush_proc;
                        for i in 1 .. g_proc_batches(v_key).ids.COUNT loop
                            begin
                                execute immediate v_stmt
                                USING g_proc_batches(v_key).status(i), g_proc_batches(v_key).procEnd(i), g_proc_batches(v_key).stepsTodo(i),
                                      g_proc_batches(v_key).stepsDone(i), g_proc_batches(v_key).info(i), g_proc_batches(v_key).immortal(i),
                                      g_proc_batches(v_key).ids(i);
                            exception
                                when others then
                                    exit when rowFailed(sqlcode, sqlerrm, 'flushBatch/PROC', i);
                            end;
                        end loop;
                end;
            exception
                when others then handleErr(sqlcode, sqlerrm, 'flushBatch/PROC');
            end;
            v_key := g_proc_batches.NEXT(v_key);
        end loop;

        commit;
        g_log_batches.DELETE;
        g_mon_batches.DELETE;
        g_proc_batches.DELETE;

    exception
        when others then
            rollback;
            g_log_batches.DELETE;
            g_mon_batches.DELETE;
            g_proc_batches.DELETE;
            logLilamErr(sqlCode, sqlErrM, 'flushBatch');
    end;

    -------------------------------------------------------------------
    -- Ends an earlier started logging session by the process ID.
    -- Important! Ignores if the process doesn't exist! No exception is thrown!
    procedure persist_close_session(p_processId number, p_tableName varchar2, p_procStepsToDo number, p_procStepsDone number, p_processInfo varchar2, p_status PLS_INTEGER)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(1000);
        sqlCursor number := null;
        updateCount number;
    begin
        sqlStatement := '
        update ' || C_PARAM_MASTER_TABLE || '
        set process_end = systimestamp,
            last_update = systimestamp';

        if p_procStepsDone is not null then
            sqlStatement := sqlStatement || ', steps_done = :PH_steps_done';
        end if ;
        if p_procStepsToDo is not null then
            sqlStatement := sqlStatement || ', steps_todo = :PH_STEPS_TO_DO';
        end if ;
        if p_processInfo is not null then
            sqlStatement := sqlStatement || ', info = :PH_PROCESS_INFO';
        end if ;     
        if p_status is not null then
            sqlStatement := sqlStatement || ', status = :PH_STATUS';
        end if ;     

        sqlStatement := sqlStatement || ' where id = :PH_PROCESS_ID'; 
        sqlStatement := replaceNameTable(sqlStatement, C_PARAM_MASTER_TABLE, C_SUFFIX_PROC_TABLE, p_tableName);

        -- due to the variable number of parameters using dbms_sql
        sqlCursor := DBMS_SQL.OPEN_CURSOR;
        DBMS_SQL.PARSE(sqlCursor, sqlStatement, DBMS_SQL.NATIVE);
        DBMS_SQL.BIND_VARIABLE(sqlCursor, ':PH_PROCESS_ID', p_processId);

        if p_procStepsDone is not null then
            DBMS_SQL.BIND_VARIABLE(sqlCursor, ':PH_steps_done', p_procStepsDone);
        end if ;
        if p_procStepsToDo is not null then
            DBMS_SQL.BIND_VARIABLE(sqlCursor, ':PH_STEPS_TO_DO', p_procStepsToDo);
        end if ;
        if p_processInfo is not null then
            DBMS_SQL.BIND_VARIABLE(sqlCursor, ':PH_PROCESS_INFO', p_processInfo);
        end if ;     
        if p_status is not null then
            DBMS_SQL.BIND_VARIABLE(sqlCursor, ':PH_STATUS', p_status);
        end if ;     

        updateCount := DBMS_SQL.EXECUTE(sqlCursor);
        DBMS_SQL.CLOSE_CURSOR(sqlCursor);

        commit;

    EXCEPTION
        WHEN OTHERS THEN
            logLilamErr(sqlCode, sqlErrM, 'persist_close_session');
            begin
                if DBMS_SQL.IS_OPEN(sqlCursor) THEN
                    DBMS_SQL.CLOSE_CURSOR(sqlCursor);
                end if ;
            exception
                when others then
                sqlCursor := null;
            end;
            rollback;
            if should_raise_error(p_processId) then
                error(p_processId, 'Could not persist process data while closing session: ' || sqlErrM);
            end if ;
    END;

    --------------------------------------------------------------------------

    procedure persist_new_session(p_processId NUMBER, p_processName VARCHAR2, p_logLevel PLS_INTEGER, p_procStepsToDo PLS_INTEGER, p_daysToKeep PLS_INTEGER, p_procImmortal PLS_INTEGER, p_tabNameMaster VARCHAR2, p_scopeName VARCHAR2)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(2000);
    begin
        sqlStatement := '
        insert into ' || C_PARAM_MASTER_TABLE || ' (
            id,
            process_name,
            process_start,
            last_update,
            process_end,
            steps_todo,
            steps_done,
            status,
            log_level,
            info,
            process_immortal,
            server_pipe,
            tab_name_master,
            scope_name
        )
        values (
            :PH_PROCESS_ID, 
            :PH_PROCESS_NAME, 
            systimestamp,
            systimestamp,
            null,
            :PH_STEPS_TO_DO, 
            null,
            null,
            :PH_LOG_LEVEL,
            ''START'',
            :PH_IMMORTAL,
            :PH_PIPE,
            :PH_TABNAME_MASTER,
            :PH_SCOPE_NAME
        )';
        sqlStatement := replaceNameTable(sqlStatement, C_PARAM_MASTER_TABLE, C_SUFFIX_PROC_TABLE, p_TabNameMaster);
        execute immediate sqlStatement USING p_processId, p_processName, p_procStepsToDo, p_logLevel, p_procImmortal, g_serverPipeName, upper(p_tabNameMaster), p_scopeName;     
        commit;

    exception
        when others then
            rollback; -- End the transaction in the error case as well
            -- Table missing: check and create again on the next NEW_SESSION
            if sqlcode = -942 then g_checked_masters.DELETE; g_safe_tables.DELETE; end if;
            logLilamErr(sqlCode, sqlErrM, 'persist_new_session'); 
            
    end;

    --------------------------------------------------------------------------

    procedure sync_process(p_processId number, p_force boolean default false)
    as
        v_idx            PLS_INTEGER;
        v_now            constant timestamp := systimestamp;
        v_ms_since_flush number;
    begin
        -- 1. Ensure that the session is known in the server/standalone
        if not v_indexSession.EXISTS(p_processId) then
            return;
        end if ;

        v_idx := v_indexSession(p_processId);

        -- 2. Calculate the time since the last master update
        if g_sessionList(v_idx).last_process_flush is null then
            v_ms_since_flush := C_FLUSH_MILLIS_THRESHOLD_MS + 1;
        else
            v_ms_since_flush := get_ms_diff(g_sessionList(v_idx).last_process_flush, v_now);
        end if ;

        -- 3. The "smart" flush condition
        -- We only flush if FORCE (e.g. end of session), the time threshold is reached
        -- OR if this specific process has been marked as "dirty".
        if p_force 
           or (g_sessionList(v_idx).process_is_dirty AND v_ms_since_flush >= C_FLUSH_MILLIS_THRESHOLD_MS)
           or (p_force = false AND v_ms_since_flush >= (C_FLUSH_MILLIS_THRESHOLD_MS * 10)) -- Safety Sync
        then
            -- Only write if there really are changes in the cache
            if g_process_cache.EXISTS(p_processId) then
                persist_process_record(g_process_cache(p_processId));            

                -- Reset the process-specific control data
                g_sessionList(v_idx).process_is_dirty   := FALSE;
                g_sessionList(v_idx).last_process_flush := v_now;
            end if ;
        end if ;

    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'sync_process'); 
            if should_raise_error(p_processId) then
                error(p_processId, 'Could not synchronize process data: ' || sqlErrM);
            end if ;
    end;    

    ---

    procedure checkLogsBuffer(p_processId number, p_comment varchar2)
    as
        v_idx            pls_integer;
    begin
        if not v_indexSession.EXISTS(p_processId) then
            return;
        end if ;
        v_idx := v_indexSession(p_processId);
        DEBUG(g_serverProcessId, 'Check SESSION_CLOSE (' || p_comment || ') für processId ' || g_sessionList(v_idx).process_id || '. log_dirty_count = ' || g_sessionList(v_idx).log_dirty_count);
    end;

    --------------------------------------------------------------------------

    /*
        Public functions and procedures
    */
    procedure sync_log(p_processId number, p_force boolean default false)
    is
        v_idx            pls_integer;
        v_now            constant timestamp := systimestamp;
        v_ms_since_flush number;
    begin
        -- 1. Get the index of the session
        if not v_indexSession.EXISTS(p_processId) then
            return;
        end if ;
        v_idx := v_indexSession(p_processId);
        g_sessionList(v_idx).log_dirty_count := coalesce(g_sessionList(v_idx).log_dirty_count, 0) + 1;
        g_dirty_queue(p_processId) := TRUE;

        -- (get_ms_diff is the optimized function)
        if g_sessionList(v_idx).last_log_flush is null then
            v_ms_since_flush := C_FLUSH_MILLIS_THRESHOLD_MS + 1;
        else
            v_ms_since_flush := get_ms_diff(g_sessionList(v_idx).last_log_flush, v_now);
        end if ;
        -- 4. Flush condition: amount OR time OR force
        if p_force 
           or g_sessionList(v_idx).log_dirty_count >= C_FLUSH_LOG_THRESHOLD_NO 
           or v_ms_since_flush >= C_FLUSH_MILLIS_THRESHOLD_MS
        then            
            -- Write all buffered logs of this process to the DB
            flushLogs(p_processId);
            g_firstLogTimeStamp := null;

            -- Reset the control data for this process
            g_sessionList(v_idx).log_dirty_count := 0;
            g_sessionList(v_idx).last_log_flush  := v_now;
        end if ;

    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'sync_log'); 

    end;

    --------------------------------------------------------------------------

    procedure close_sessionRemote(p_processId number, p_procStepsToDo PLS_INTEGER, p_procStepsDone PLS_INTEGER, p_processInfo varchar2, p_processStatus PLS_INTEGER)
    as
        l_payload JSON_OBJ_LILAM; -- Buffer for the JSON string
        l_serverMsg varchar2(100);
        l_response  varchar2(1000);
    begin
        -- Creating the JSON object
        -- PERFORMANCE: concatenate the message directly instead of via jsonPut (see jStr/jNum/jTs)
        l_payload := '{"process_id":' || jNum(p_processId)
                  || jNum('steps_todo',     p_procStepsToDo)
                  || jNum('steps_done',     p_procStepsDone)
                  || jStr('process_info',   p_processInfo)
                  || jNum('process_status', p_processStatus) || '}';

        l_response := waitForResponse(p_processId, 'CLOSE_SESSION', l_payload, 1);

        if l_response in ('TIMEOUT', 'THROTTLED') or
           l_response like 'ERROR%' then
           l_serverMsg := 'close_sessionRemote: ' || l_response;
        else
            l_serverMsg := jsonString(l_response, 'payload.server_message');
        end if ;        

    EXCEPTION
        WHEN OTHERS THEN
            logLilamErr(sqlCode, sqlErrM, 'close_sessionRemote'); 

    end;

    --------------------------------------------------------------------------

    procedure procStepDoneRemote(p_processId number, p_timestamp TIMESTAMP)
    as
        l_payload JSON_OBJ_LILAM; -- Buffer for the JSON string
        l_serverMsg varchar2(100);
    begin
        -- Creating the JSON object
        -- PERFORMANCE: concatenate the message directly instead of via jsonPut (see jStr/jNum/jTs)
        l_payload := '{"process_id":' || jNum(p_processId)
                  || jTs('timestamp', p_timestamp) || '}';

        sendNoWait(p_processId, 'PROC_STEP_DONE', l_payload, 0.5);
    end;
    --------------------------------------------------------------------------

    procedure setAnyStatusRemote(p_processId number, p_status pls_integer, p_processInfo varchar2, p_procStepsToDo pls_integer, p_procStepsDone pls_integer, p_immortal pls_integer, p_timestamp TIMESTAMP)
    as
        l_payload JSON_OBJ_LILAM; -- Buffer for the JSON string
    begin
        -- PERFORMANCE: concatenate the message directly instead of via jsonPut (see jStr/jNum/jTs)
        l_payload := '{"process_id":' || jNum(p_processId)
                  || jNum('steps_todo',       p_procStepsToDo)
                  || jNum('steps_done',       p_procStepsDone)
                  || jStr('process_info',     p_processInfo)
                  || jNum('process_status',   p_status)
                  || jNum('process_immortal', p_immortal)
                  || jTs ('timestamp',        p_timestamp) || '}';

        sendNoWait(p_processId, 'SET_ANY_STATUS', l_payload, 0.5);
    end;

    --------------------------------------------------------------------------

    -- Client side (decoupled): writes one log entry directly in an autonomous transaction,
    -- without the server. Used for entries up to the sync level of the process, so that they are
    -- stored when the call returns, even if the server or its pipe fails afterwards.
    -- Target is always LILAM_LOG of this installation (created if missing), not the work table:
    -- the work table may live in the server's schema, out of reach of the client.
    -- NO is C_NO_DIRECT_WRITE (-1): the running number is assigned by the server only.
    -- Returns FALSE if the entry could not be written; the caller then sends it via the pipe.
    function writeLogDirect(p_processId number, p_level number, p_logText varchar2,
                            p_caller varchar2, p_errStack varchar2, p_errBacktrace varchar2, p_errCallstack varchar2,
                            p_timestamp TIMESTAMP) return boolean
    as
        pragma autonomous_transaction;
    begin
        createLogTables(C_DIRECT_WRITE_MASTER);   -- checked only once per session
        execute immediate 'insert into ' || safeTableName(C_DIRECT_WRITE_MASTER || C_SUFFIX_LOG_TABLE) || '
                (PROCESS_ID, LOG_LEVEL, LOG_LEVEL_C, INFO, SESSION_TIME, NO, CALLER, ERR_STACK, ERR_BACKTRACE, ERR_CALLSTACK, SESSION_USER, HOST_NAME)
                values (:1, :2, :3, :4, :5, :6, :7, :8, :9, :10, :11, :12)'
        using p_processId, p_level, logLevelToEnum(p_level), substrb(p_logText, 1, 2000), p_timestamp, C_NO_DIRECT_WRITE,
              substrb(p_caller, 1, 255), substrb(p_errStack, 1, 4000), substrb(p_errBacktrace, 1, 4000), substrb(p_errCallstack, 1, 4000),
              SYS_CONTEXT('USERENV','SESSION_USER'), SYS_CONTEXT('USERENV','HOST');
        commit;
        return true;
    exception
        when others then
            rollback;
            if sqlcode = -942 then g_checked_masters.DELETE; g_safe_tables.DELETE; end if;
            logLilamErr(sqlCode, sqlErrM, 'writeLogDirect');
            return false;
    end;

    --------------------------------------------------------------------------

    -- p_persisted: the client has already written the entry (writeLogDirect); the server must not
    -- write it again, but still evaluates the rules and the synchronous flush.
    procedure log_anyRemote(p_processId number, p_level number, p_logText varchar2, p_caller varchar2, p_errStack varchar2, p_errBacktrace varchar2, p_errCallstack varchar2, p_timestamp TIMESTAMP,
                            p_persisted boolean default false)
    as
        l_payload JSON_OBJ_LILAM; -- Buffer for the JSON string
    begin
        -- PERFORMANCE: concatenate the message directly instead of via jsonPut (see jStr/jNum/jTs)
        l_payload := '{"process_id":' || jNum(p_processId)
                  || jNum('level',         p_level)
                  || jStr('log_text',      p_logText)
                  || jStr('caller',        p_caller)
                  || jStr('err_stack',     p_errStack)
                  || jStr('err_backtr',    p_errBacktrace)
                  || jStr('err_callstack', p_errCallstack)
                  || jTs ('timestamp',     p_timestamp)
                  || case when p_persisted then ',"persisted":1' end || '}';

        sendNoWait(p_processId, 'LOG_ANY', l_payload, 0.5);

    EXCEPTION
        WHEN OTHERS THEN
            logLilamErr(sqlCode, sqlErrM, 'log_anyRemote'); 

    end;

    --------------------------------------------------------------------------

    -- encapsulates writing to the log buffer and synchronization of the buffer
    procedure log_any(
        p_processId number, 
        p_level number,
        p_logText varchar2,
        p_caller varchar2,
        p_errStack varchar2,
        p_errBacktrace varchar2,
        p_errCallstack varchar2,
        p_timestamp TIMESTAMP DEFAULT systimestamp,
        p_persisted boolean DEFAULT false  -- Server: entry already written by the client (writeLogDirect)
    )
    as
        l_syncLevel   PLS_INTEGER := logLevelError;
        l_persisted   BOOLEAN := FALSE;
        l_packageName VARCHAR2(128);
        l_aimDepth    PLS_INTEGER := NULL;
        l_maxDepth    PLS_INTEGER;
        l_module      VARCHAR2(255) := p_caller;
        v_dummyMonRec   t_monitor_buffer_rec;
        v_stack_unit  UTL_CALL_STACK.unit_qualified_name;        
        l_logText     VARCHAR2(8000);
    begin
        -- Truncate in general: applies to in-session and decoupled (before sending via the pipe).
        -- Additionally limit to the 2000 bytes of column INFO (multi-byte characters, e.g. umlauts)
        l_logText := substr(p_logText, 1, C_MAX_LOG_TEXT_LEN);
        while lengthb(l_logText) > 2000 loop
            l_logText := substr(l_logText, 1, length(l_logText) - 50);
        end loop;

        -- lookup in stack - who called me?
        if l_module is null then
            -- The name of LILAM could theoretically change
            l_packageName := $$PLSQL_UNIT; 
            
            -- Determine the maximum depth of the current call
            l_maxDepth := UTL_CALL_STACK.dynamic_depth;
            -- looks for first unit with other name
            -- Loop starts with 3 due to performance
            FOR i IN 3 .. l_maxDepth LOOP
                v_stack_unit := UTL_CALL_STACK.subprogram(i);
                IF upper(v_stack_unit(1)) != upper(l_packageName) and upper(v_stack_unit(1)) != '__ANONYMOUS_BLOCK' THEN
                    l_aimDepth := i;
                    EXIT;
                END IF;
            END LOOP;
            
            if l_aimDepth IS NOT NULL then    
               -- Read the fully qualified name of the real caller
               l_module := UTL_CALL_STACK.concatenate_subprogram (
                              UTL_CALL_STACK.subprogram(l_aimDepth)
                          );
            else
                l_module := 'EXTERNAL_CLIENT (' || SYS_CONTEXT('USERENV', 'CLIENT_PROGRAM_NAME') || ')';
            end if;
        
        end if;
            
        if is_remote(p_processId) then
            -- Entries up to the sync level: the client writes them itself, so that they are stored
            -- when the call returns. The server is informed anyway (rules, flush of its buffer).
            if g_remote_sync.EXISTS(p_processId)
               and p_level <= g_remote_sync(p_processId).sync_level
               and p_level <= g_remote_sync(p_processId).log_level then
                l_persisted := writeLogDirect(p_processId, p_level, l_logText,
                                              l_module, p_errStack, p_errBacktrace, p_errCallstack, p_timestamp);
            end if;
            log_anyRemote(p_processId, p_level, l_logText, l_module, p_errStack, p_errBacktrace, p_errCallstack, p_timestamp, l_persisted);
            return;
        end if ;

        if v_indexSession.EXISTS(p_processId) then
            l_syncLevel := g_sessionList(v_indexSession(p_processId)).sync_level;
        end if;

        -- Continue here only if not remote
        if not p_persisted and v_indexSession.EXISTS(p_processId) and p_level <= g_sessionList(v_indexSession(p_processId)).log_level then
            write_to_log_buffer(
                p_processId, 
                p_level,
                l_logText,
                p_timestamp,
                l_module,
                p_errStack,
                p_errBacktrace,
                p_errCallstack
            );
        end if ;
        
        -- raise alert (only for known processes; fire_alert needs the session data)
        if v_indexSession.EXISTS(p_processId)
           and g_rules_by_action.EXISTS(g_sessionList(v_indexSession(p_processId)).rule_group || '|' || C_LOGGING) then
            v_dummyMonRec.process_id := p_processId;
            v_dummyMonRec.start_time := coalesce(p_timestamp, systimestamp);
            v_dummyMonRec.stop_time := null;
            v_dummyMonRec.monitor_type := C_MON_TYPE_LOG;
            v_dummyMonRec.action_name := C_LOGGING;
            v_dummyMonRec.context_name := logLevelToEnum(p_level);
            evaluateRules(v_dummyMonRec, C_LOGGING);
        end if;

        -- Entries up to the sync level of the process (default: ERROR) must be written immediately,
        -- together with everything buffered before them
        if p_level <= l_syncLevel then
            SYNC_ALL_DIRTY(true);
        else
            SYNC_ALL_DIRTY();
        end if;

    exception
        when others then
        logLilamErr(sqlCode, sqlErrM, 'log_any'); 
    end;

    --------------------------------------------------------------------------

    /*
        Public functions and procedures
    */

    -- Used by external Procedure to write a new log entry with log level DEBUG
    -- Details are adjusted to the debug level
    procedure DEBUG(p_processId number, p_logText varchar2)
    as
    begin
        log_any(
                p_processId, 
                logLevelDebug,
                p_logText,
                null,
                null,
                null,
                DBMS_UTILITY.FORMAT_CALL_STACK,
                systimestamp
            );
    end;

    --------------------------------------------------------------------------

    -- Used by external Procedure to write a new log entry with log level INFO
    -- Details are adjusted to the info level
    procedure INFO(p_processId number, p_logText varchar2)
    as
    begin
        log_any(
            p_processId, 
            logLevelInfo,
            p_logText,
            null,
            null,
            null,
            null,
            systimestamp
        );
    end;

    --------------------------------------------------------------------------

    -- Counts an ERROR or WARN call for the process (GET_COUNTER_ERROR/GET_COUNTER_WARN)
    procedure countLog(p_processId number, p_isError boolean)
    as
        l_new t_log_counter_rec;
    begin
        if not g_log_counters.EXISTS(p_processId) then
            g_log_counters(p_processId) := l_new;
        end if;
        if p_isError then
            g_log_counters(p_processId).errors := g_log_counters(p_processId).errors + 1;
        else
            g_log_counters(p_processId).warnings := g_log_counters(p_processId).warnings + 1;
        end if;
    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'countLog');
    end;

    --------------------------------------------------------------------------

    -- Used by external Procedure to write a new log entry with log level ERROR
    -- Details are adjusted to the error level
    procedure ERROR(p_processId number, p_logText varchar2)
    as
    begin
        if p_processId > 0 then
            countLog(p_processId, TRUE);
        end if;
        log_any(
            p_processId, 
            logLevelError,
            p_logText,
            null,
            DBMS_UTILITY.FORMAT_ERROR_STACK,
            DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
            DBMS_UTILITY.FORMAT_CALL_STACK,
            SYSTIMESTAMP
        );
    end;

    --------------------------------------------------------------------------

    -- Number of WARN calls for the process in this session; 0 for unknown or closed processes
    FUNCTION GET_COUNTER_WARN(p_processId NUMBER) return PLS_INTEGER
    as
    begin
        if p_processId > 0 and g_log_counters.EXISTS(p_processId) then
            return g_log_counters(p_processId).warnings;
        end if;
        return 0;
    end;

    --------------------------------------------------------------------------

    -- Number of ERROR calls for the process in this session; 0 for unknown or closed processes
    FUNCTION GET_COUNTER_ERROR(p_processId NUMBER) return PLS_INTEGER
    as
    begin
        if p_processId > 0 and g_log_counters.EXISTS(p_processId) then
            return g_log_counters(p_processId).errors;
        end if;
        return 0;
    end;
    
    --------------------------------------------------------------------------

    -- Used by external Procedure to write a new log entry with log level WARN
    -- Details are adjusted to the warn level
    procedure WARN(p_processId number, p_logText varchar2)
    as
    begin
        if p_processId > 0 then
            countLog(p_processId, FALSE);
        end if;
        log_any(
            p_processId, 
            logLevelWarn,
            p_logText,
            null,
            DBMS_UTILITY.FORMAT_ERROR_STACK,
            DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
            DBMS_UTILITY.FORMAT_CALL_STACK,
            SYSTIMESTAMP
        );
    end;

    --------------------------------------------------------------------------

    procedure setAnyStatus(p_processId number, p_status PLS_INTEGER, p_processInfo varchar2, p_procStepsToDo number, p_procStepsDone number, p_procImmortal PLS_INTEGER, p_timestamp TIMESTAMP)
    as
    begin

        if is_remote(p_processId) then
            setAnyStatusRemote(p_processId, p_status, p_processInfo, p_procStepsToDo, p_procStepsDone, p_procImmortal, p_timestamp);
            return;
        end if ;

       if v_indexSession.EXISTS(p_processId) then
            if p_status         is not null then g_process_cache(p_processId).status := p_status; end if ;
            if p_processInfo    is not null then g_process_cache(p_processId).info := p_processInfo; end if ;
            if p_procStepsToDo  is not null then g_process_cache(p_processId).stepsTodo := p_procStepsToDo; end if ;
            if p_procStepsDone  is not null then g_process_cache(p_processId).stepsDone := p_procStepsDone; end if ;
            if p_procImmortal   is not null then g_process_cache(p_processId).procImmortal := p_procImmortal; end if;

            g_sessionList(v_indexSession(p_processId)).process_is_dirty := TRUE;
            g_dirty_queue(p_processId) := TRUE; -- So that SYNC_ALL_DIRTY sees the session

            evaluateRules(g_process_cache(p_processId), C_PROCESS_UPDATE);                
        end if ;

    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'setAnyStatus'); 
            if should_raise_error(p_processId) then
                error(p_processId, 'Could not set process status: ' || sqlErrM);
            end if ;
    end;

    --------------------------------------------------------------------------

    procedure SET_PROCESS_STATUS(p_processId number, p_status PLS_INTEGER, p_processInfo varchar2 DEFAULT NULL)
    as
    begin
        setAnyStatus(p_processId, p_status, p_processInfo, null, null, null, SYSTIMESTAMP);
    end;

    --------------------------------------------------------------------------

     procedure SET_PROC_STEPS_TODO(p_processId number, p_procStepsToDo number)
     as
     begin
        setAnyStatus(p_processId, null, null, p_procStepsToDo, null, null, SYSTIMESTAMP);
     end;

    --------------------------------------------------------------------------

    procedure SET_PROC_STEPS_DONE(p_processId number, p_procStepsDone number)
    as
    begin
        setAnyStatus(p_processId, null, null, null, p_procStepsDone, null, SYSTIMESTAMP);   
    end;

    procedure SET_PROC_IMMORTAL(p_processId number, p_immortal number)
    as
    begin
        setAnyStatus(p_processId, null, null, null, null, p_immortal, SYSTIMESTAMP);
    end;

    --------------------------------------------------------------------------

    procedure PROC_STEP_DONE(p_processId number)
    as
        sqlStatement varchar2(500);
        l_steps number;
    begin
        if is_remote(p_processId) then
            procStepDoneRemote(p_processId, SYSTIMESTAMP);
            return;
        end if ;

       if v_indexSession.EXISTS(p_processId) then
            l_steps := coalesce(g_process_cache(p_processId).stepsDone, 0) +1;                
            setAnyStatus(p_processId, null, null, null, l_steps, null, SYSTIMESTAMP);   
        end if;
    end;

    --------------------------------------------------------------------------

    function getProcessDataRemote(p_processId number) return t_process_rec
    as
        l_payload JSON_OBJ_LILAM; -- Buffer for the JSON string
        l_response varchar2(20000);
        l_process_rec t_process_rec;
    begin
        -- Creating the JSON object
        select json_object(
            'process_id'   value p_processId
            returning varchar2
        )
        into l_payload from dual;            
        l_response := waitForResponse(p_processId, 'GET_PROCESS_DATA', l_payload, 5);

        if l_response in ('TIMEOUT', 'THROTTLED') or
            l_response like 'ERROR%' then
            return NULL;
        else                
            l_payload := JSON_QUERY(l_response, '$.payload');
            l_process_rec.id                := jsonString(l_payload, 'process_id');
            l_process_rec.processName      := jsonString(l_payload, 'process_name');
            l_process_rec.logLevel         := jsonNumber(l_payload, 'log_level');
            l_process_rec.processStart     := jsonTime(l_payload, 'process_start');
            l_process_rec.processEnd       := jsonTime(l_payload, 'process_end');
            l_process_rec.lastUpdate       := jsonTime(l_payload, 'last_update');
            l_process_rec.info              := jsonString(l_payload, 'process_info');
            l_process_rec.status            := jsonNumber(l_payload, 'process_status');
            l_process_rec.stepsTodo   := jsonNumber(l_payload, 'steps_todo');
            l_process_rec.stepsDone   := jsonNumber(l_payload, 'steps_done');
            l_process_rec.tabNameMaster   := jsonString(l_payload, 'tabname_master');            
        end if ; 

        return l_process_rec;
    end;

    --------------------------------------------------------------------------

    FUNCTION GET_PROCESS_DATA_JSON(p_processId NUMBER) return varchar2
    as
        l_payload       JSON_OBJ_LILAM;
        l_process_rec   t_process_rec;    
    begin   
        l_process_rec := GET_PROCESS_DATA(p_processId); 
        jsonPut(l_payload, 'process_id', l_process_rec.id);
        jsonPut(l_payload, 'process_name', l_process_rec.processName);
        jsonPut(l_payload, 'log_level', l_process_rec.logLevel);
        jsonPut(l_payload, 'process_start', l_process_rec.processStart);
        jsonPut(l_payload, 'process_end', l_process_rec.processEnd);
        jsonPut(l_payload, 'last_update', l_process_rec.lastUpdate);
        jsonPut(l_payload, 'process_info', l_process_rec.info); 
        jsonPut(l_payload, 'process_status', l_process_rec.status); 
        jsonPut(l_payload, 'steps_todo', l_process_rec.stepsTodo); 
        jsonPut(l_payload, 'steps_done', l_process_rec.stepsDone); 
        jsonPut(l_payload, 'tabname_master', l_process_rec.tabNameMaster);
        
        return l_payload;   
    end;

    --------------------------------------------------------------------------

    FUNCTION GET_PROCESS_DATA(p_processId NUMBER) return t_process_rec
    as
        l_proc_rec t_process_rec;
    begin
        if is_remote(p_processId) then
            return getProcessDataRemote(p_processId);
        end if ;

        if v_indexSession.EXISTS(p_processId) then
            return g_process_cache(p_processId);
        else return null;
        end if ;
    end;

    --------------------------------------------------------------------------

    FUNCTION GET_PROC_STEPS_DONE(p_processId NUMBER) return PLS_INTEGER
    as
    begin
        return get_process_data(p_processId).stepsDone;
    end;

    --------------------------------------------------------------------------

    FUNCTION GET_PROC_STEPS_TODO(p_processId NUMBER) return PLS_INTEGER
    as
    begin
        return get_process_data(p_processId).stepsTodo;
    end;

    --------------------------------------------------------------------------

    function GET_PROCESS_START(p_processId NUMBER) return timestamp
    as
    begin
        return get_process_data(p_processId).processStart;
    end;

    --------------------------------------------------------------------------

    function GET_PROCESS_END(p_processId NUMBER) return timestamp
    as
    begin
        return get_process_data(p_processId).processEnd;
    end;

    --------------------------------------------------------------------------

    function GET_PROCESS_STATUS(p_processId number) return PLS_INTEGER
    as 
    begin
        return get_process_data(p_processId).status;
    end;

    --------------------------------------------------------------------------

    function GET_PROCESS_INFO(p_processId number) return varchar2
    as 
    begin
        return get_process_data(p_processId).info;
    end;

    --------------------------------------------------------------------------

    procedure clearServerData
    as
    begin
        -- save open baseline deltas (own error handling)
        syncBaselines(TRUE);
        g_baselines.DELETE;
        g_scope_ids.DELETE;
        g_checked_masters.DELETE;
        g_safe_tables.DELETE;
        g_last_baseline_sync := NULL;

        g_monitor_groups.delete;
        g_log_groups.delete;
        g_dirty_queue.delete;
        v_indexSession.delete;
        if not g_sessionList is null then
            g_sessionList.delete;
        end if;
        g_remote_sessions.DELETE;
        g_remote_sync.DELETE;
        g_process_cache.DELETE;
        g_monitor_shadows.DELETE;
        g_local_throttle_cache.DELETE;    
        g_alert_history.DELETE;
        g_rules_by_context.DELETE;
        g_rules_by_action.DELETE;
        g_rule_groups.DELETE;

    exception
        when others then
        logLilamErr(sqlCode, sqlErrM, 'clearServerData', 'deletion of memory data'); 
        
    end;

    --------------------------------------------------------------------------

    --------------------------------------------------------------------------
    -- Write open traces of a process as a warning to the log (before the last flush in CLOSE_SESSION)
    --------------------------------------------------------------------------
    PROCEDURE warnOpenTraces(p_processId NUMBER)
    IS
        v_search_prefix CONSTANT VARCHAR2(50) := LPAD(p_processId, 20, '0') || '|';
        v_key           VARCHAR2(250);
    BEGIN
        IF NOT v_indexSession.EXISTS(p_processId)
           OR logLevelWarn > g_sessionList(v_indexSession(p_processId)).log_level THEN
            RETURN;
        END IF;

        -- PERFORMANCE: start directly at the first key of this process (keys are sorted)
        v_key := g_monitor_shadows.NEXT(v_search_prefix);
        WHILE v_key IS NOT NULL LOOP
            EXIT WHEN SUBSTR(v_key, 1, LENGTH(v_search_prefix)) != v_search_prefix;
            -- Events also leave a shadow (distance to the previous event); only traces are open
            IF g_monitor_shadows(v_key).monitor_type = C_MON_TYPE_TRACE THEN
                write_to_log_buffer(
                    p_processId,
                    logLevelWarn,
                    'OPEN TRACE (not stopped before CLOSE_SESSION): Action=>' || g_monitor_shadows(v_key).action_name
                        || '; Context=>' || g_monitor_shadows(v_key).context_name
                        || '; Start=>' || to_char(g_monitor_shadows(v_key).start_time, 'YYYY-MM-DD HH24:MI:SS.FF3'),
                    systimestamp,
                    'LILAM',
                    null,
                    null,
                    null
                );
            END IF;
            v_key := g_monitor_shadows.NEXT(v_key);
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            logLilamErr(sqlCode, sqlErrM, 'warnOpenTraces');
    END;

    --------------------------------------------------------------------------

    PROCEDURE clearAllSessionData(p_processId NUMBER)
    IS
        v_idx           PLS_INTEGER;
        v_search_prefix CONSTANT VARCHAR2(50) := LPAD(p_processId, 20, '0') || '|';
        v_key           VARCHAR2(250);
        v_next_key      VARCHAR2(250);
    BEGIN

        -- A) CLEAR MONITOR DATA & CACHES
        -- We use the safe loop (save before delete)
        -- PERFORMANCE: start directly at the first key of this process (keys are sorted)
        v_key := g_monitor_groups.NEXT(v_search_prefix);
        WHILE v_key IS NOT NULL LOOP
            EXIT WHEN SUBSTR(v_key, 1, LENGTH(v_search_prefix)) != v_search_prefix;
            v_next_key := g_monitor_groups.NEXT(v_key);
            -- Delete history
            g_monitor_groups.DELETE(v_key);
            v_key := v_next_key;
        END LOOP;

        -- B) CLEAR LOG GROUPS
        -- Since g_log_groups also uses the ID as key (string):
        if g_log_groups.EXISTS(TO_CHAR(p_processId)) THEN
            g_log_groups.DELETE(TO_CHAR(p_processId));
        end if;

        -- C) CLEAR DIRTY QUEUE
        if g_dirty_queue.EXISTS(p_processId) THEN
            g_dirty_queue.DELETE(p_processId);
        end if;

        -- D) CLEAR SESSION METADATA (MASTER LIST)
        if v_indexSession.EXISTS(p_processId) THEN
            v_idx := v_indexSession(p_processId);
            g_sessionList.DELETE(v_idx);     -- Entry in the nested table (slot becomes empty)
            v_indexSession.DELETE(p_processId); -- Delete the pointer
        end if;

        -- E) CLEAR PROCESS CACHE
        if g_process_cache.EXISTS(p_processId) THEN
            g_process_cache.DELETE(p_processId);
        end if ;

        -- F) Delete monitor shadows
            -- We start at the beginning of the shadow map
        v_key := g_monitor_shadows.FIRST;   
        WHILE v_key IS NOT NULL LOOP
            EXIT WHEN SUBSTR(v_key, 1, 20) > LPAD(p_processId, 20, '0');
            if v_key LIKE v_search_prefix || '%' THEN
                g_monitor_shadows.DELETE(v_key);
            end if ;            
            -- Jump to the next key
            v_key := g_monitor_shadows.NEXT(v_key);
        END LOOP;

        -- G) Delete averages
        v_key := g_monitor_averages.FIRST;
        WHILE v_key IS NOT NULL LOOP
            EXIT WHEN SUBSTR(v_key, 1, 20) > LPAD(p_processId, 20, '0');
            if v_key LIKE v_search_prefix || '%' THEN
                g_monitor_averages.DELETE(v_key);
            end if ;            
            v_key := g_monitor_averages.NEXT(v_key);
        END LOOP;

        -- H) Reset the list of active servers
        g_client_pipes.DELETE(p_processId);

        -- I) Memory of sent messages and elapsed time for this process
        g_local_throttle_cache.DELETE(p_processId);

        -- J) Delete stored predecessor actions
            IF g_last_action_per_process.EXISTS(p_processId) THEN
                g_last_action_per_process.DELETE(p_processId);
            END IF;

        -- K) Counters for ERROR/WARN
        g_log_counters.DELETE(p_processId);

    EXCEPTION
        WHEN OTHERS THEN
        logLilamErr(sqlCode, sqlErrM, 'clearAllSessionData'); 

    END;

    --------------------------------------------------------------------------

    -- Ends an earlier started logging session by the process ID.
    -- Important! Ignores if the process doesn't exist! No exception is thrown!
    procedure CLOSE_SESSION(
        p_processId     NUMBER,
        p_processInfo   VARCHAR2    DEFAULT NULL,
        p_processStatus PLS_INTEGER DEFAULT NULL,
        p_procStepsDone PLS_INTEGER DEFAULT NULL,
        p_procStepsToDo PLS_INTEGER DEFAULT NULL)
    as
        v_idx PLS_INTEGER;
    begin
        if is_remote(p_processId) then
            close_sessionRemote(p_processId, p_procStepsToDo, p_procStepsDone, p_processInfo, p_processStatus);
            g_remote_sessions.delete(p_processId);
            g_remote_sync.delete(p_processId);
            g_log_counters.delete(p_processId);
            g_client_pipes.delete(p_processId);
            g_local_throttle_cache.delete(p_processId);
            return;
        end if ;

        -- Continue here only for a local processId
        if v_indexSession.EXISTS(p_processId) then
            -- report open traces while buffers and shadows still exist
            warnOpenTraces(p_processId);
            -- Write only the buffers of this process (not those of all open processes)
            sync_log(p_processId, true);
            sync_monitor(p_processId, true);
            sync_process(p_processId, true);
            syncBaselines(true);

            g_process_cache(p_processId).processEnd := systimestamp;
            -- Take over the final values before the rule check (PROCESS_STOP sees the final state)
            if p_procStepsDone is not null then g_process_cache(p_processId).stepsDone := p_procStepsDone; end if;
            if p_procStepsToDo is not null then g_process_cache(p_processId).stepsTodo := p_procStepsToDo; end if;
            if p_processInfo   is not null then g_process_cache(p_processId).info      := p_processInfo;   end if;
            if p_processStatus is not null then g_process_cache(p_processId).status    := p_processStatus; end if;

            evaluateRules(g_process_cache(p_processId), C_PROCESS_STOP);

            v_idx := v_indexSession(p_processId);
            persist_close_session(p_processId,  g_sessionList(v_idx).tabName_master, p_procStepsToDo, p_procStepsDone, p_processInfo, p_processStatus);
            checkLogsBuffer(p_processId, 'vor clearAllSessionData');
            clearAllSessionData(p_processId);
            checkLogsBuffer(p_processId, 'nach clearAllSessionData');

        end if ;
    end;
    
    --------------------------------------------------------------------------

    FUNCTION NEW_SESSION(p_session_init t_session_init) RETURN NUMBER
    as
        p_processId number(19,0);   
        v_new_rec t_process_rec;
        l_session_init t_session_init := p_session_init;
        l_scopeName VARCHAR2(100);
        l_scopeId   NUMBER;
        v_idx       PLS_INTEGER;
    begin

        -- empty master table (e.g. from JSON without tabname_master) => default
        l_session_init.tabNameMaster := nvl(trim(l_session_init.tabNameMaster), 'LILAM');
        createLogTables(l_session_init.tabNameMaster);

        -- New Process ID by Sequence
        execute immediate 'select seq_lilam_log.nextVal from dual' into p_processId;
        
        -- default LogLevel logLevelMonitor
        if l_session_init.logLevel is null then l_session_init.logLevel := logLevelMonitor; end if;
        
        -- persist to session internal table
        insertSession (l_session_init.tabNameMaster, p_processId, l_session_init.logLevel);

        -- Group for the rules: in the server the server group (dispatcher: no rules),
        -- INSESSION the specified group (NULL = no rules). The rule set of the group is loaded by
        -- the first rule check (PROCESS_START below), afterwards at most every C_RULES_CHECK_INTERVAL_MS.
        v_idx := v_indexSession(p_processId);
        if g_serverPipeName is not null then
            if not g_serverIsDispatcher then
                g_sessionList(v_idx).group_name := trim(g_serverGroupName);
            end if;
        else
            g_sessionList(v_idx).group_name := trim(l_session_init.groupName);
        end if;
        g_sessionList(v_idx).rule_group := upper(g_sessionList(v_idx).group_name);
        g_sessionList(v_idx).sync_level := nvl(l_session_init.syncLevel, logLevelError);

        deleteOldLogs(p_processId, upper(trim(l_session_init.processName)), l_session_init.daysToKeep);

        -- Baseline scope (default: process name); on errors NULL => process-local
        l_scopeName := resolveScopeName(l_session_init.processName, l_session_init.baselineScope);
        l_scopeId   := getOrCreateScopeId(l_scopeName);
        setScopeId(p_processId, l_scopeId);
        if l_scopeId is null then l_scopeName := null; end if;

        persist_new_session(p_processId, l_session_init.processName, l_session_init.logLevel,  
            l_session_init.stepsToDo, l_session_init.daysToKeep, l_session_init.procImmortal, l_session_init.tabNameMaster, l_scopeName);

        -- copy new details data to memory
        v_new_rec.id             := p_processId;
        v_new_rec.tabNameMaster  := l_session_init.tabNameMaster;
        v_new_rec.processName    := l_session_init.processName;
        v_new_rec.processStart   := systimestamp;
        v_new_rec.processEnd     := null;
        v_new_rec.lastUpdate     := null;
        v_new_rec.stepsTodo      := l_session_init.stepsToDo;
        v_new_rec.stepsDone      := 0;
        v_new_rec.status         := 0;
        v_new_rec.info           := 'START';

        g_process_cache(p_processId) := v_new_rec;
        evaluateRules(g_process_cache(p_processId), C_PROCESS_START);

        return p_processId;
    end;


    -- Opens/starts a new logging session.
    -- The returned process id must be stored within the calling procedure because it is the reference
    -- which is recommended for all following actions (e.g. CLOSE_SESSION, DEBUG, SET_PROCESS_STATUS).
    FUNCTION NEW_SESSION(
        p_processName   VARCHAR2,
        p_logLevel      PLS_INTEGER DEFAULT logLevelMonitor,
        p_procStepsToDo PLS_INTEGER DEFAULT NULL,
        p_daysToKeep    PLS_INTEGER DEFAULT NULL,
        p_tabNameMaster VARCHAR2    DEFAULT 'LILAM',
        p_baselineScope VARCHAR2    DEFAULT NULL,
        p_groupName     VARCHAR2    DEFAULT NULL,
        p_syncLevel     PLS_INTEGER DEFAULT logLevelError) RETURN NUMBER
    as
        l_session_init t_session_init;
    begin
        l_session_init.syncLevel     := p_syncLevel;
        l_session_init.processName   := p_processName;
        l_session_init.logLevel      := p_logLevel;
        l_session_init.stepsToDo     := p_procStepsToDo;
        l_session_init.daysToKeep    := p_daysToKeep;
        l_session_init.tabNameMaster := p_tabNameMaster;
        l_session_init.baselineScope := p_baselineScope;
        l_session_init.groupName     := p_groupName;
        return new_session(l_session_init);
    end;

    --------------------------------------------------------------------------
    
    PROCEDURE SET_DISPATCHER_PIPE(p_pipeName varchar2, p_groupName varchar2 DEFAULT 'DEFAULT_DISPATCHER', p_processId number DEFAULT null)
    AS
        l_result number;
    BEGIN
        g_dispatcher_config(nvl(upper(p_groupName), 'DEFAULT_DISPATCHER')) := p_pipeName;
    
        -- Pre-warm only if a process_id was passed
        if p_processId is not null then
            l_result := SERVER_LINK(p_processId, p_pipeName);
            -- deliberately no raise here: SERVER_LINK (function) catches everything itself
            -- and logs via logLilamErr; if pre-warming fails, the automatic fallback in is_remote()
            -- applies on the next real API call anyway
        end if;
    END;

    --------------------------------------------------------------------------

    function extractClientChannel(p_json_doc varchar2) return varchar2
    as
    begin
        return JSON_VALUE(p_json_doc, '$.header.response');
    end;        

    --------------------------------------------------------------------------

    function extractClientRequest(p_json_doc varchar2) return varchar2
    as
    begin
        return JSON_VALUE(p_json_doc, '$.header.request');
    end;

    --------------------------------------------------------------------------

    procedure doRemote_startTrace(p_message varchar2)
    as
        l_processId number;
        l_actionName varchar2(100);
        l_contextName varchar2(100);
        l_timestamp timestamp;
        l_monType pls_integer;
        l_payload JSON_OBJ_LILAM;
    begin
        l_payload := JSON_QUERY(p_message, '$.payload');
        l_processId := jsonNumber(l_payload, 'process_id');
        l_actionName := jsonString(l_payload, 'action_name');
        l_contextName := jsonString(l_payload, 'context_name');
        l_timestamp := jsonTime(l_payload, 'timestamp');
        l_monType := jsonNumber(l_payload, 'monitor_type');

        startTrace(l_processId, l_actionName, l_contextName, l_timestamp);
    end;

    --------------------------------------------------------------------------

    procedure doRemote_stopTrace(p_message varchar2)
    as
        l_processId number;
        l_actionName varchar2(100);
        l_contextName varchar2(100);
        l_timestamp timestamp;
        l_monType pls_integer;
        l_payload JSON_OBJ_LILAM;
    begin
        l_payload := JSON_QUERY(p_message, '$.payload');
        l_processId := jsonNumber(l_payload, 'process_id');
        l_actionName := jsonString(l_payload, 'action_name');
        l_contextName := jsonString(l_payload, 'context_name');
        l_timestamp := jsonTime(l_payload, 'timestamp');
        l_monType := jsonNumber(l_payload, 'monitor_type');

        writeTraceToMonitorBuffer(l_processId, l_actionName, l_contextName, l_timestamp);
    end;


    --------------------------------------------------------------------------

    procedure doRemote_markEvent(p_message varchar2)
    as
        l_processId number;
        l_actionName varchar2(100);
        l_contextName varchar2(100);
        l_timestamp timestamp;
        l_monType pls_integer;
        l_payload JSON_OBJ_LILAM;
    begin
        l_payload := JSON_QUERY(p_message, '$.payload');
        l_processId := jsonNumber(l_payload, 'process_id');
        l_actionName := jsonString(l_payload, 'action_name');
        l_contextName := jsonString(l_payload, 'context_name');
        l_timestamp := jsonTime(l_payload, 'timestamp');
        l_monType := jsonNumber(l_payload, 'monitor_type');

        writeEventToMonitorBuffer(l_processId, l_actionName, l_contextName, l_timestamp);
    end;

    --------------------------------------------------------------------------

    procedure doRemote_setAnyStatus(p_message varchar2)
    as
        l_processId     NUMBER;
        l_status        PLS_INTEGER;
        l_processInfo   VARCHAR2(2000);
        l_stepsToDo     PLS_INTEGER;
        l_procStepsDone PLS_INTEGER;
        l_immortal      PLS_INTEGER;
        l_payload JSON_OBJ_LILAM;
        l_timestamp     TIMESTAMP(6);
    begin
        l_payload := JSON_QUERY(p_message, '$.payload');
        l_processId     := jsonNumber(l_payload, 'process_id');
        l_status        := jsonNumber(l_payload, 'process_status');
        l_processInfo   := jsonString(l_payload, 'process_info');
        l_stepsToDo     := jsonNumber(l_payload, 'steps_todo');
        l_procStepsDone := jsonNumber(l_payload, 'steps_done');
        l_immortal      := jsonNumber(l_payload, 'process_immortal');
        l_timestamp     := jsonTime(l_payload, 'timestamp');

        setAnyStatus(l_processId, l_status, l_processInfo, l_stepsToDo, l_procStepsDone, l_immortal, l_timestamp);
    end;
    --------------------------------------------------------------------------

    procedure doRemote_procStepDone(p_message varchar2)
    as
        l_processId     NUMBER;
        l_payload JSON_OBJ_LILAM;
    begin
        l_payload := JSON_QUERY(p_message, '$.payload');
        l_processId  := jsonNumber(l_payload, 'process_id');

        PROC_STEP_DONE(l_processId);
    end;

    --------------------------------------------------------------------------

    procedure doRemote_reconnectProcess(p_clientChannel varchar2, p_message JSON_OBJ_LILAM)
    as
        l_status        PLS_INTEGER;
        l_processId     NUMBER;
        l_header        JSON_OBJ_LILAM;
        l_payload       JSON_OBJ_LILAM;
        l_response      JSON_OBJ_LILAM;
        l_msg           JSON_OBJ_LILAM;
    begin
        l_payload       := JSON_QUERY(p_message, '$.payload');
        l_processId     := jsonNumber(l_payload, 'process_id');

        if v_indexSession.EXISTS(l_processId) then
            jsonPut(l_response, 'server_code', get_serverCode(TXT_ACK_SERVER_PROC));
            jsonPut(l_response, 'process_id', l_processId);
            jsonPut(l_response, 'perf', g_server_perf);   -- Performance level for client throttling
            -- Data for the client's direct writing up to sync_level (see setRemoteSync)
            jsonPut(l_response, 'log_level',      g_sessionList(v_indexSession(l_processId)).log_level);
            jsonPut(l_response, 'sync_level',     g_sessionList(v_indexSession(l_processId)).sync_level);
        else
            jsonPut(l_response, 'server_code', get_serverCode(TXT_ERR_SERVER_PROC));
        end if;

        jsonPut(l_header, 'msg_type', 'SERVER_RESPONSE');
        jsonPut(l_header, 'msg_name', 'RECONNECT_PROCESS_RESP');
        jsonPut(l_msg, 'header', l_header);
        jsonPut(l_msg, 'payload', l_response);

        DBMS_PIPE.RESET_BUFFER;
        DBMS_PIPE.PACK_MESSAGE(l_msg);        
        l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 1);

    end;

    --------------------------------------------------------------------------

    procedure doRemote_logAny(p_message varchar2)
    as
        l_processId number;
        l_level number;
        l_logText varchar2(4000);
        l_caller varchar2(255);
        l_errStack varchar2(4000);
        l_errBacktrace varchar2(4000);
        l_errCallstack varchar2(4000);
        l_payload JSON_OBJ_LILAM;
        l_timestamp TIMESTAMP(6);
    begin
        l_payload       := JSON_QUERY(p_message, '$.payload');
        l_processId     := jsonNumber(l_payload, 'process_id');
        l_level         := jsonNumber(l_payload, 'level');
        l_logText       := jsonString(l_payload, 'log_text');
        l_caller        := jsonString(l_payload, 'caller');
        l_errStack      := jsonString(l_payload, 'err_stack');
        l_errBacktrace  := jsonString(l_payload, 'err_backtr');
        l_errCallstack  := jsonString(l_payload, 'err_callstack');
        l_timestamp     := jsonTime(l_payload, 'timestamp');

        log_any(l_processId, l_level, l_logText, l_caller, l_errStack, l_errBacktrace, l_errCallstack, l_timestamp,
                nvl(jsonNumber(l_payload, 'persisted'), 0) = 1);
    end;

    --------------------------------------------------------------------------
    
    procedure unregisterProcessRoute(p_processId number)
    as
        pragma autonomous_transaction;
    begin
        execute immediate 'delete from ' || C_LILAM_PROCESS_ROUTE || ' where process_id = :1'
        using p_processId;
        commit;
    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'unregisterProcessRoute');
    end;

    --------------------------------------------------------------------------

    procedure doRemote_closeSession(p_clientChannel varchar2, p_message VARCHAR2)
    as
        l_processId     number; 
        l_procStepsToDo PLS_INTEGER; 
        l_procStepsDone PLS_INTEGER; 
        l_processInfo   varchar2(2000);
        l_status        PLS_INTEGER;
        l_payload       JSON_OBJ_LILAM;
    begin
        l_payload     := JSON_QUERY(p_message, '$.payload');
        l_processId   := jsonString(l_payload, 'process_id');
        l_procStepsToDo   := jsonNumber(l_payload, 'steps_todo');
        l_procStepsDone   := jsonNumber(l_payload, 'steps_done');
        l_processInfo := jsonString(l_payload, 'process_info');
        l_status      := jsonNumber(l_payload, 'process_status');

        checkLogsBuffer(l_processId, 'vor CLOSE_SESSION');

        CLOSE_SESSION(p_processId => l_processId, p_processInfo => l_processInfo, p_processStatus => l_status,
                      p_procStepsDone => l_procStepsDone, p_procStepsToDo => l_procStepsToDo);
        unregisterProcessRoute(l_processId); 

        DBMS_PIPE.RESET_BUFFER;
        DBMS_PIPE.PACK_MESSAGE('{"process_id":' || l_processId || '}');        
        l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 1);

    end;    

    -------------------------------------------------------------------------- 

    procedure doRemote_pingEcho(p_clientChannel varchar2, p_message VARCHAR2)
    as
        l_status        PLS_INTEGER;
        l_header        JSON_OBJ_LILAM;
        l_meta          JSON_OBJ_LILAM;
        l_payload       JSON_OBJ_LILAM;
        l_msg           JSON_OBJ_LILAM;
    begin
        jsonPut(l_header, 'msg_type', 'SERVER_RESPONSE');
        jsonPut(l_header, 'msg_name', 'PING_ECHO');
        jsonPut(l_meta, 'server_version', LILAM_VERSION);
        jsonPut(l_payload, 'server_message', TXT_PING_ECHO);
        jsonPut(l_payload, 'server_code', get_serverCode(TXT_PING_ECHO));

        jsonPut(l_msg, 'header', l_header);
        jsonPut(l_msg, 'meta', l_meta);
        jsonPut(l_msg, 'payload', l_payload);

        DBMS_PIPE.RESET_BUFFER;
        DBMS_PIPE.PACK_MESSAGE(l_msg);        
        l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 0);

    exception
        when others then
        logLilamErr(sqlCode, sqlErrM, 'doRemote_pingEcho'); 
    end; 

    -------------------------------------------------------------------------- 

    procedure doRemote_getMonitorLastEntry(p_clientChannel varchar2, l_message varchar2)
    as 
        l_payload JSON_OBJ_LILAM;
        l_header JSON_OBJ_LILAM;
        l_meta   JSON_OBJ_LILAM;
        l_msg    JSON_OBJ_LILAM;
        l_processId number;
        v_rec t_monitor_buffer_rec;
        l_status PLS_INTEGER;
        l_actionName varchar2(50);
        l_contextName varchar2(50);

    begin
        l_processId := jsonNumber(l_message, 'payload.process_id');
        l_actionName := jsonString(l_message, 'payload.action_name');
        l_contextName := jsonString(l_message, 'payload.context_name');

        v_rec := getLastMonitorEntry(l_processId, l_actionName, l_contextName);

        jsonPut(l_payload, 'process_id', v_rec.process_id);
        jsonPut(l_payload, 'action_name', v_rec.action_name);
        jsonPut(l_payload, 'action_count', v_rec.action_count);
        jsonPut(l_payload, 'used_time', v_rec.used_time);
        jsonPut(l_payload, 'start_time', v_rec.start_time);
        jsonPut(l_payload, 'stop_time', v_rec.stop_time);
        jsonPut(l_payload, 'avg_action_time', v_rec.avg_action_time); 

        jsonPut(l_header, 'msg_type', 'SERVER_RESPONSE');
        jsonPut(l_header, 'msg_name', 'LAST_MONITOR_ENTRY');

        jsonPut(l_meta, 'server_version', LILAM_VERSION);
        jsonPut(l_meta, 'server_message', TXT_DATA_ANSWER);
        jsonPut(l_meta, 'server_code', get_serverCode(TXT_DATA_ANSWER));

        jsonPut(l_msg, 'header', l_header);
        jsonPut(l_msg, 'meta', l_meta);
        jsonPut(l_msg, 'payload', l_payload);

        -- no payload, client waits only for unfreezing
        DBMS_PIPE.RESET_BUFFER; -- Empty the buffer
        DBMS_PIPE.PACK_MESSAGE(l_msg);        
        l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 0);

    exception
        when others then
        logLilamErr(sqlCode, sqlErrM, 'doRemote_getMonitorLastEntry'); 
    
    end;    

    -------------------------------------------------------------------------- 

    procedure doRemote_getProcessData(p_clientChannel varchar2, l_message varchar2)
    as
        l_processId     number;
        l_status        PLS_INTEGER;
        l_payload       JSON_OBJ_LILAM;
        l_header        JSON_OBJ_LILAM;
        l_meta          JSON_OBJ_LILAM;
        l_msg           JSON_OBJ_LILAM;
        l_process_rec   t_process_rec;
    begin
        l_processId := jsonNumber(l_message, 'payload.process_id');
        l_process_rec := GET_PROCESS_DATA(l_processId); 
        jsonPut(l_payload, 'process_id', l_process_rec.id);
        jsonPut(l_payload, 'process_name', l_process_rec.processName);
        jsonPut(l_payload, 'log_level', l_process_rec.logLevel);
        jsonPut(l_payload, 'process_start', l_process_rec.processStart);
        jsonPut(l_payload, 'process_end', l_process_rec.processEnd);
        jsonPut(l_payload, 'last_update', l_process_rec.lastUpdate);
        jsonPut(l_payload, 'process_info', l_process_rec.info); 
        jsonPut(l_payload, 'process_status', l_process_rec.status); 
        jsonPut(l_payload, 'steps_todo', l_process_rec.stepsTodo); 
        jsonPut(l_payload, 'steps_done', l_process_rec.stepsDone); 
        jsonPut(l_payload, 'tabname_master', l_process_rec.tabNameMaster);

        jsonPut(l_header, 'msg_type', 'SERVER_RESPONSE');
        jsonPut(l_header, 'msg_name', 'PROCESS_DATA');
        jsonPut(l_meta, 'server_version', LILAM_VERSION);
        jsonPut(l_meta, 'server_message', TXT_DATA_ANSWER);
        jsonPut(l_meta, 'server_code', get_serverCode(TXT_DATA_ANSWER));

        jsonPut(l_msg, 'header', l_header);
        jsonPut(l_msg, 'meta', l_meta);
        jsonPut(l_msg, 'payload', l_payload);

        -- no payload, client waits only for unfreezing
        DBMS_PIPE.RESET_BUFFER; -- Empty the buffer
        DBMS_PIPE.PACK_MESSAGE(l_msg);        
        l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 0);

    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'doRemote_getProcessData'); 
            error(l_processId, 'Could not send process data to client: ' || sqlErrM);
    end;    

    -------------------------------------------------------------------------- 

    procedure doRemote_unfreezeClient(p_clientChannel varchar2, p_message VARCHAR2, p_shutdown BOOLEAN DEFAULT FALSE)
    as
        l_payload JSON_OBJ_LILAM;
        l_status  PLS_INTEGER;
        l_header  JSON_OBJ_LILAM;
        l_meta    JSON_OBJ_LILAM;
        l_msg     JSON_OBJ_LILAM;
    begin
        jsonPut(l_header, 'msg_type', 'SERVER_RESPONSE');
        jsonPut(l_header, 'msg_name', 'UNFREEZE_CLIENT');
        jsonPut(l_meta, 'server_version', LILAM_VERSION);
        if p_shutdown then
            jsonPut(l_payload, 'server_message', TXT_ACK_SHUTDOWN);
            jsonPut(l_payload, 'server_code', get_serverCode(TXT_ACK_SHUTDOWN));
        else
            jsonPut(l_payload, 'server_message', TXT_ACK_OK);
            jsonPut(l_payload, 'server_code', get_serverCode(TXT_ACK_OK));
        end if;
        jsonPut(l_msg, 'header', l_header);
        jsonPut(l_msg, 'meta', l_meta);
        jsonPut(l_msg, 'payload', l_payload);

        -- no payload, client waits only for unfreezing
        DBMS_PIPE.RESET_BUFFER; -- Empty the buffer
        DBMS_PIPE.PACK_MESSAGE(l_msg);        
        l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 0);

    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'doRemote_unfreezeClient'); 
            error(p_clientChannel, 'Could not send unlock signal to client: ' || sqlErrM);
    end;    

    --------------------------------------------------------------------------
    
    procedure registerProcessRoute(p_processId number, p_pipeName varchar2)
    as
        pragma autonomous_transaction;
    begin
        createDispatchTable;
        execute immediate 'insert into ' || C_LILAM_PROCESS_ROUTE || '(process_id, pipe_name) values (:1, :2)'
        using p_processId, p_pipeName;
        commit;
    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'registerProcessRoute');
    end;

    --------------------------------------------------------------------------

    procedure doRemote_newSession(p_clientChannel varchar2, p_message VARCHAR2)
    as
        l_processId number;
        l_payload JSON_OBJ_LILAM;
        l_session_init t_session_init;
        l_status PLS_INTEGER;
    begin
        l_payload := JSON_QUERY(p_message, '$.payload');

        -- Check the client's expiry time (with a 500 ms safety margin). If it has passed, the
        -- client has already given up: no process, no route, no response (the return channel
        -- no longer exists; a response would only create an orphaned pipe there).
        if jsonTime(l_payload, 'expires_utc') - INTERVAL '0.5' SECOND < sys_extract_utc(systimestamp) then
            logLilamErr(NUM_ERR_SESSION_TIMEOUT, 'NEW_SESSION verworfen, Client wartet nicht mehr: '
                        || jsonString(l_payload, 'process_name'), 'doRemote_newSession', 'EXPIRED');
            return;
        end if;

        l_session_init.processName := jsonString(l_payload, 'process_name');
        l_session_init.logLevel    := jsonNumber(l_payload, 'log_level');
        l_session_init.stepsToDo   := jsonNumber(l_payload, 'steps_todo');
        l_session_init.daysToKeep  := jsonNumber(l_payload, 'days_to_keep');
        l_session_init.tabNameMaster := jsonString(l_payload, 'tabname_master');
        l_session_init.baselineScope := jsonString(l_payload, 'baseline_scope');
        l_session_init.syncLevel     := nvl(jsonNumber(l_payload, 'sync_level'), logLevelError);

        l_processId := NEW_SESSION(l_session_init);
        registerProcessRoute(l_processId, g_serverPipeName); 
        touchServerRegistry;   -- Keep the registry up to date immediately (load balancing with fast NEW_SESSION)

        DBMS_PIPE.RESET_BUFFER;
        -- perf: performance level of this server; the client adjusts its throttling accordingly
        -- log_level/sync_level: the client writes entries up to sync_level itself (see setRemoteSync)
        DBMS_PIPE.PACK_MESSAGE('{"process_id":' || l_processId || ',"perf":' || g_server_perf
                               || jNum('log_level',      g_sessionList(v_indexSession(l_processId)).log_level)
                               || jNum('sync_level',     g_sessionList(v_indexSession(l_processId)).sync_level) || '}');
        l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 1);
    end;    


    -------------------------------------------------------------------------- 

    procedure SERVER_SHUTDOWN(p_processId number, p_pipeName varchar2, p_password varchar2)
    as
        l_response JSON_OBJ_LILAM;
        l_message  JSON_OBJ_LILAM;
        l_payload  JSON_OBJ_LILAM;
        l_serverCode PLS_INTEGER;
        l_slotIdx    PLS_INTEGER;
    begin
        jsonPut(l_message, 'pipe_name', p_pipeName);
        jsonPut(l_message, 'shutdown_password', p_password);
        l_response := waitForResponse(
            p_processId     => p_processId,
            p_request       => 'SERVER_SHUTDOWN',
            p_payload       => l_message,
            p_timeoutSec    => 5
        );
        l_payload := JSON_QUERY(l_response, '$.payload');
        l_serverCode := jsonNumber(l_payload, 'server_code');

        if l_serverCode = NUM_ACK_SHUTDOWN then
            null;
        end if ;

    EXCEPTION
        WHEN OTHERS THEN
        logLilamErr(sqlCode, sqlErrM, 'SERVER_SHUTDOWN'); 

    end;

    -------------------------------------------------------------------------- 

    FUNCTION GET_SERVER_PIPE(p_processId NUMBER) RETURN VARCHAR2
    as
    begin
        -- Invalid ID (e.g. NUM_ERR_SESSION_TIMEOUT from SERVER_NEW_SESSION): no server, no exception
        if p_processId is null or p_processId < 0 then
            return null;
        end if;
        return getServerPipeForSession(p_processId, null);
    end;

    --------------------------------------------------------------------------

    FUNCTION SERVER_NEW_SESSION(
        p_processName   VARCHAR2,
        p_groupName     VARCHAR2    DEFAULT NULL,
        p_logLevel      PLS_INTEGER DEFAULT logLevelMonitor,
        p_procStepsToDo PLS_INTEGER DEFAULT NULL,
        p_daysToKeep    PLS_INTEGER DEFAULT NULL,
        p_tabNameMaster VARCHAR2    DEFAULT 'LILAM',
        p_baselineScope VARCHAR2    DEFAULT NULL,
        p_syncLevel     PLS_INTEGER DEFAULT logLevelError) RETURN NUMBER
    as
        l_payload JSON_OBJ_LILAM;
    begin
        jsonPut(l_payload, 'process_name',   p_processName);
        jsonPut(l_payload, 'group_name',     p_groupName);
        jsonPut(l_payload, 'log_level',      p_logLevel);
        jsonPut(l_payload, 'steps_todo',     p_procStepsToDo);
        jsonPut(l_payload, 'days_to_keep',   p_daysToKeep);
        jsonPut(l_payload, 'tabname_master', p_tabNameMaster);
        jsonPut(l_payload, 'baseline_scope', p_baselineScope);
        jsonPut(l_payload, 'sync_level',     p_syncLevel);

        return server_new_session_json(l_payload);
    end;

    --------------------------------------------------------------------------

    -- Client side: remember log level and sync level that the server reported for the process.
    -- Without these values (e.g. older server) the client sends everything via the pipe as before.
    procedure setRemoteSync(p_processId number, p_json varchar2)
    as
        l_rec t_remote_sync_rec;
    begin
        l_rec.log_level      := jsonNumber(p_json, 'log_level');
        l_rec.sync_level     := jsonNumber(p_json, 'sync_level');
        if l_rec.log_level is null or l_rec.sync_level is null then
            g_remote_sync.DELETE(p_processId);
        else
            g_remote_sync(p_processId) := l_rec;
        end if;
    exception
        when others then
            g_remote_sync.DELETE(p_processId);
            logLilamErr(sqlCode, sqlErrM, 'setRemoteSync');
    end;

    --------------------------------------------------------------------------

    FUNCTION SERVER_NEW_SESSION_JSON(p_jsonObject JSON_OBJ_LILAM) RETURN NUMBER
    as
        l_ProcessId number(19,0) := -500;   
        l_response  varchar2(100);        
        l_payload   JSON_OBJ_LILAM := p_jsonObject;
    begin                        
        -- Expiry time: until then the client waits for the response. If the server only gets to the
        -- message afterwards (e.g. full pipe), it does not create a process (see doRemote_newSession).
        -- This way no orphaned, never closed processes are created.
        -- In UTC, since client and server sessions can have different time zones.
        jsonPut(l_payload, 'expires_utc', sys_extract_utc(systimestamp) + numtodsinterval(C_TIMEOUT_NEW_SESSION_SEC, 'SECOND'));

        -- first check which servers are available
        l_response := waitForResponse(null, 'NEW_SESSION', l_payload, C_TIMEOUT_NEW_SESSION_SEC);

        CASE
            WHEN l_response = 'TIMEOUT' THEN
                l_ProcessId := NUM_ERR_SESSION_TIMEOUT;
            WHEN l_response = 'THROTTLED' THEN
                l_ProcessId := NUM_ERR_SESSION_THROTTLED;
            WHEN l_response LIKE 'ERROR%' THEN
                l_ProcessId := NUM_COMM_ERR;
            else
            -- Success: parse JSON
            l_ProcessId := nvl(jsonNumber(l_response, 'process_id'), NUM_COMM_ERR);
        end case;
        
        -- No process created: no exception to the application (philosophy: no impact).
        -- The application receives the negative ID (constants NUM_ERR_SESSION_* in the specification);
        -- all further API calls with this ID are silently ignored. Logged in LILAM_LOG_INTERNAL.
        if l_ProcessId < 0 then
            g_client_pipes.DELETE(C_PIPE_ID_PENDING);
            logLilamErr(l_ProcessId, 'Could not establish connection to LILAM-Server: ' || l_response,
                        'SERVER_NEW_SESSION_JSON', 'NEW_SESSION');
            return l_ProcessId;
        end if;
        
        -- Register only valid IDs
        if l_ProcessId > 0 THEN
            g_client_pipes(l_ProcessId) := g_client_pipes(C_PIPE_ID_PENDING);
            g_client_pipes.DELETE(C_PIPE_ID_PENDING);
            g_remote_sessions(l_ProcessId) := TRUE; -- add to the list of remote sessions
            -- Throttling according to the server's performance level (if the value is missing: C_SERVER_PERF_MID)
            setPerfLimit(l_ProcessId, jsonNumber(l_response, 'perf'));
            setRemoteSync(l_ProcessId, l_response);
        end if ;
        RETURN l_ProcessId;
    end;

    --------------------------------------------------------------------------

    FUNCTION reconnectRemote(p_processId number, p_pipeName varchar2) RETURN NUMBER
    AS
        l_payload     JSON_OBJ_LILAM;
        l_response    JSON_OBJ_LILAM;
        l_serverCode  NUMBER;
    BEGIN
        jsonPut(l_payload,'process_id', p_processId);

        l_response := waitForResponse(
            p_processId     => p_processId,
            p_request       => 'RECONNECT_PROCESS',
            p_payload       => l_payload,
            p_timeoutSec    => 5
        );
        l_response := trim(l_response);
        if upper(l_response) in ('TIMEOUT', 'THROTTLED') or
            upper(l_response) like 'ERROR%' then
            return NUM_ERR_PIPE_SERVER;
        end if;
            
        l_payload := JSON_QUERY(l_response, '$.payload');
        l_serverCode := jsonNumber(l_payload, 'server_code');

        if l_serverCode = NUM_ACK_SERVER_PROC then
            -- Throttling according to the server's performance level (also in every new APEX session)
            setPerfLimit(p_processId, jsonNumber(l_payload, 'perf'));
            setRemoteSync(p_processId, l_payload);
            return jsonNumber(l_payload, 'process_id');
        else
            return NUM_ERR_SERVER_PROC;
        end if ;

    EXCEPTION
        WHEN OTHERS THEN
        logLilamErr(sqlCode, sqlErrM, 'reconnectRemote'); 
        return NUM_ERR_PIPE_SERVER;

    END;

    --------------------------------------------------------------------------

    /*
      Ensure as quickly as possible that the connection exists, or
      restore it if necessary.
      1. If process and pipe are known: return p_processId
      2. If the pipe is not available (REGISTRY): return NUM_ERR_PIPE_SERVER
      3. Ask the server
         a) if it does not know the process: return NUM_ERR_SERVER_PROC
         b) if known: return p_processId
    */
    FUNCTION SERVER_LINK(p_processId NUMBER, p_pipeName varchar2) RETURN NUMBER
    AS
        l_respProcId number;
    BEGIN
        -- if everything is known, no further action is necessary
        if g_remote_sessions.EXISTS(p_processId)
           and g_client_pipes.EXISTS(p_processId)
           and g_client_pipes(p_processId) = p_pipeName then
            return p_processId;
        end if;

        -- optimistically fill the associative arrays
        -- this simplifies the test call to the server
        g_remote_sessions(p_processId) := TRUE;
        g_client_pipes(p_processId)    := p_pipeName;

        -- if the server PIPE is not active, abort immediately
        if not isServerPipeActive(p_pipeName) then
            g_remote_sessions.DELETE(p_processId);
            g_client_pipes.DELETE(p_processId);
            return NUM_ERR_PIPE_SERVER;
        end if;

        -- Ask the server via the PIPE whether it knows the PROCESS_ID
        l_respProcId := reconnectRemote(p_processId, p_pipeName);
        if nvl(l_respProcId, NUM_ERR_SERVER_PROC) != p_processId then
            g_remote_sessions.DELETE(p_processId);
            g_client_pipes.DELETE(p_processId);
        end if;
        return l_respProcId;

    EXCEPTION
        WHEN OTHERS THEN
        logLilamErr(sqlCode, sqlErrM, 'SERVER_LINK'); 
        return NUM_ERR_PIPE_SERVER;

    END;

    --------------------------------------------------------------------------
    
    PROCEDURE SERVER_LINK(p_processId NUMBER, p_pipeName varchar2)
    AS
        l_respProcId number;
    BEGIN
        -- if everything is known, no further action is necessary
        if g_remote_sessions.EXISTS(p_processId)
           and g_client_pipes.EXISTS(p_processId)
           and g_client_pipes(p_processId) = p_pipeName then
           return;
        end if;

        -- optimistically fill the associative arrays
        -- this simplifies the test call to the server
        g_remote_sessions(p_processId) := TRUE;
        g_client_pipes(p_processId)    := p_pipeName;

        -- if the server PIPE is not active, abort immediately
        if not isServerPipeActive(p_pipeName) then
            g_remote_sessions.DELETE(p_processId);
            g_client_pipes.DELETE(p_processId);
            RAISE_APPLICATION_ERROR(
                num => -20020,
                msg => 'NUM_ERR_PIPE_SERVER: Kommunikation mit LILAM-SERVER ' ||
                       'ist fehlgeschlagen.'
            );
        end if;

        -- Ask the server via the PIPE whether it knows the PROCESS_ID
        l_respProcId := reconnectRemote(p_processId, p_pipeName);
        if nvl(l_respProcId, NUM_ERR_SERVER_PROC) != p_processId then
            g_remote_sessions.DELETE(p_processId);
            g_client_pipes.DELETE(p_processId);
            
            RAISE_APPLICATION_ERROR(
                num => -20021,
                msg => 'NUM_ERR_SERVER_PROC: Der Sitzungskontext zum LILAM-SERVER ' ||
                       'konnte nicht hergestellt oder verifiziert werden.'
            );
        end if;

    EXCEPTION
        WHEN OTHERS THEN
        logLilamErr(sqlCode, sqlErrM, 'SERVER_LINK'); 

    END;

    PROCEDURE DUMP_BUFFER_STATS AS
        v_key VARCHAR2(100);
        v_log_total NUMBER := 0;
        v_mon_total NUMBER := 0;
    BEGIN
    dbms_output.enable();

        -- 1. Count logs
        v_key := g_log_groups.FIRST;
        WHILE v_key IS NOT NULL LOOP
            v_log_total := v_log_total + g_log_groups(v_key).COUNT;
            v_key := g_log_groups.NEXT(v_key);
        END LOOP;

        -- 2. Count monitors
        v_key := g_monitor_groups.FIRST;
        WHILE v_key IS NOT NULL LOOP
            DBMS_OUTPUT.PUT_LINE('Gefundener Key im Speicher: "' || v_key || '"');
            v_mon_total := v_mon_total + g_monitor_groups(v_key).COUNT;
            v_key := g_monitor_groups.NEXT(v_key);
        END LOOP;

        DBMS_OUTPUT.PUT_LINE('--- LILAM BUFFER DIAGNOSE ---');
        DBMS_OUTPUT.PUT_LINE('Sessions in Queue: ' || g_dirty_queue.COUNT);
        DBMS_OUTPUT.PUT_LINE('Gepufferte Logs:   ' || v_log_total);
        DBMS_OUTPUT.PUT_LINE('Gepufferte Monit.: ' || v_mon_total);
        DBMS_OUTPUT.PUT_LINE('Master-Cache:      ' || g_process_cache.COUNT);
    END;

    --------------------------------------------------------------------------

    function handleServerShutdown(p_clientChannel varchar2, p_message varchar2) return boolean
    as
        l_status    PLS_INTEGER;
        l_password  varchar2(50);
        l_msgObj   JSON_OBJ_LILAM; 
        l_header    JSON_OBJ_LILAM;
        l_meta      JSON_OBJ_LILAM;
        l_payload   JSON_OBJ_LILAM;
        l_msg       JSON_OBJ_LILAM;
    begin

        l_msgObj     := JSON_QUERY(p_message, '$.payload');
        l_password   := jsonString(l_msgObj, 'shutdown_password');

        jsonPut(l_header, 'msg_type', 'SERVER_RESPONSE');
        jsonPut(l_header, 'msg_name', 'SERVER_SHUTDOWN');
        jsonPut(l_meta, 'server_version', LILAM_VERSION);

        if l_password = g_shutdownPassword then
            jsonPut(l_payload, 'server_message', TXT_ACK_SHUTDOWN);
            jsonPut(l_payload, 'server_code', get_serverCode(TXT_ACK_SHUTDOWN));
        else
            jsonPut(l_payload, 'server_message', TXT_ACK_DECLINE);
            jsonPut(l_payload, 'server_code', get_serverCode(TXT_ACK_DECLINE));
        end if ;
        jsonPut(l_msg, 'header', l_header);
        jsonPut(l_msg, 'meta', l_meta);
        jsonPut(l_msg, 'payload', l_payload);

        DBMS_PIPE.RESET_BUFFER;
        DBMS_PIPE.PACK_MESSAGE(l_msg);        
        l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 1);

        return l_password = g_shutdownPassword;
    end;

    --------------------------------------------------------------------------

    function isServerPipeRegistered(p_pipeName varchar2) return BOOLEAN
    as
        l_exists INTEGER;
        l_sqlStmt varchar2(200);
    begin
        l_sqlStmt := '
        SELECT COUNT(*)
        FROM ' || C_LILAM_SERVER_REGISTRY || '
        WHERE upper(pipe_name) = ''' || upper(p_pipeName) || '''
        AND rownum = 1'; -- Bricht nach dem ersten Treffer ab
        execute immediate l_sqlStmt into l_exists;

        IF l_exists > 0 THEN
            -- Server exists
            return true;
        END IF;
        return false;
    end;

    --------------------------------------------------------------------------

    procedure registerServerPipe
    as
        pragma autonomous_transaction; 
        l_sqlStmt varchar2(1500);
    begin
        if isServerPipeRegistered(g_serverPipeName) then
            -- update existing entry
            l_sqlStmt := '
            update ' || C_LILAM_SERVER_REGISTRY || ' 
            set last_activity = systimestamp,
                is_active = 1,
                group_name = :1,
                current_processes = 0,
                is_dispatcher = :2
            where upper(pipe_name) = :3';            
            execute immediate l_sqlStmt using g_serverGroupName, case when g_serverIsDispatcher then 1 else 0 end,
                                              upper(g_serverPipeName);
        else
                -- new entry, server was not registered yet
            l_sqlStmt := '
            insert into ' || C_LILAM_SERVER_REGISTRY || ' (
                pipe_name,
                group_name,
                last_activity,
                is_active,
                current_processes,
                avg_log_lat,
                max_log_lat,
                avg_mon_lat,
                max_mon_lat,
                is_dispatcher
            ) values (
                :1,
                :2,
                SYSTIMESTAMP,
                1,
                0,
                0,
                0,
                0,
                0,
                :3
            )';
            execute immediate l_sqlStmt using g_serverPipeName, g_serverGroupName, case when g_serverIsDispatcher then 1 else 0 end;
        end if;
        commit;

    exception
        when others then
            rollback;
            logLilamErr(sqlCode, sqlErrM, 'registerServerPipe', 'EXECUTE IMMEDIATE'); 
    end;

    --------------------------------------------------------------------------
    
    function resolveDispatchTarget(p_processId number) return varchar2
    as
        l_pipe varchar2(50);
        l_sql varchar2(200);
    begin
        if g_dispatch_route_cache.EXISTS(p_processId) then
            return g_dispatch_route_cache(p_processId);
        end if;
        
        l_sql := 'select pipe_name from ' || C_LILAM_PROCESS_ROUTE || ' where process_id = :1';
        execute immediate l_sql into l_pipe using p_processId;
    
        g_dispatch_route_cache(p_processId) := l_pipe;
        return l_pipe;
    exception
        when NO_DATA_FOUND then return null;
    end;
    
    --------------------------------------------------------------------------

    --------------------------------------------------------------------------
    -- Number from the n-th part of 'a|b|c', NLS-independent ('.' as decimal separator).
    -- Invalid or missing => NULL (without error log; the caller reports)
    --------------------------------------------------------------------------
    FUNCTION ruleNumber(p_value VARCHAR2, p_position PLS_INTEGER := 1) RETURN NUMBER
    AS
        l_val  VARCHAR2(100) := TRIM(REGEXP_SUBSTR(p_value, '[^|]+', 1, p_position));
        l_sign NUMBER := 1;
    BEGIN
        IF l_val IS NULL THEN
            RETURN NULL;
        END IF;
        IF substr(l_val, 1, 1) = '-' THEN
            l_sign := -1;
            l_val  := substr(l_val, 2);
        END IF;
        RETURN l_sign * to_number(l_val, '999999999999D9999999999', 'NLS_NUMERIC_CHARACTERS = ''. ''');
    EXCEPTION
        WHEN VALUE_ERROR OR INVALID_NUMBER THEN
            RETURN NULL;
    END;

    --------------------------------------------------------------------------
    -- Checks a rule set and prepares it. Returns NULL if it is valid, otherwise the error message.
    -- The rules end up in the OUT parameters; the loaded rules of the server remain untouched.
    --------------------------------------------------------------------------
    FUNCTION parseRuleSet(p_ruleSet CLOB, p_byCtx OUT NOCOPY t_rule_map, p_byAction OUT NOCOPY t_rule_map,
                          p_avg OUT NOCOPY t_avg_params_map) RETURN VARCHAR2
    IS
        TYPE t_seen_map IS TABLE OF BOOLEAN INDEX BY VARCHAR2(50);
        l_seen   t_seen_map;
        l_hasArr PLS_INTEGER;
        l_no     PLS_INTEGER := 0;
        l_parts  PLS_INTEGER;
        l_rule   t_rule_rec;
        l_empty  t_rule_rec;
        l_key    VARCHAR2(250);
        l_trig   VARCHAR2(4000);
        l_op     VARCHAR2(4000);
        l_ok     BOOLEAN;

        FUNCTION fail(p_msg VARCHAR2) RETURN VARCHAR2 IS
        BEGIN
            RETURN substr('rule #' || l_no || ' (id ' || coalesce(l_rule.rule_id, '?') || '): ' || p_msg, 1, 1000);
        END;
    BEGIN
        SELECT count(*) INTO l_hasArr FROM dual WHERE JSON_EXISTS(p_ruleSet, '$.rules');
        IF l_hasArr = 0 THEN
            RETURN 'array "rules" missing';
        END IF;

        FOR r IN (
            SELECT *
            FROM JSON_TABLE(p_ruleSet, '$.rules[*]'
                COLUMNS (
                    rule_id      VARCHAR2(4000) PATH '$.id',
                    trigger_t    VARCHAR2(4000) PATH '$.trigger_type',
                    action       VARCHAR2(4000) PATH '$.action',
                    context      VARCHAR2(4000) PATH '$.context',
                    metric       VARCHAR2(4000) PATH '$.condition.metric',
                    operator     VARCHAR2(4000) PATH '$.condition.operator',
                    value        VARCHAR2(4000) PATH '$.condition.value',
                    handler      VARCHAR2(4000) PATH '$.alert.handler',
                    severity     VARCHAR2(4000) PATH '$.alert.severity',
                    throttle_sec VARCHAR2(4000) PATH '$.alert.throttle_seconds'
                )
            )
        ) LOOP
            l_no   := l_no + 1;
            l_rule := l_empty;
            l_trig := upper(trim(r.trigger_t));
            l_op   := upper(trim(r.operator));

            -- Mandatory fields and lengths
            IF r.rule_id IS NULL OR length(r.rule_id) > 50 THEN
                RETURN fail('"id" missing or longer than 50');
            END IF;
            l_rule.rule_id := r.rule_id;
            IF l_seen.EXISTS(r.rule_id) THEN
                RETURN fail('"id" not unique');
            END IF;
            l_seen(r.rule_id) := TRUE;

            IF l_trig IS NULL OR l_trig NOT IN (C_PROCESS_START, C_PROCESS_UPDATE, C_PROCESS_STOP,
                                                C_MARK_EVENT, C_TRACE_START, C_TRACE_STOP, C_LOGGING) THEN
                RETURN fail('unknown "trigger_type" ' || r.trigger_t);
            END IF;

            -- LOGGING rules are always attached to the action LOGGING ("action" may be missing)
            IF l_trig = C_LOGGING THEN
                IF r.action IS NOT NULL AND upper(r.action) != C_LOGGING THEN
                    RETURN fail('"action" of a LOGGING rule must be empty or LOGGING');
                END IF;
                l_rule.target_action := C_LOGGING;
            ELSE
                IF r.action IS NULL OR length(r.action) > 100 THEN
                    RETURN fail('"action" missing or longer than 100');
                END IF;
                l_rule.target_action := r.action;
            END IF;
            IF length(r.context) > 100 THEN
                RETURN fail('"context" longer than 100');
            END IF;
            IF r.handler IS NULL OR length(r.handler) > 30 THEN
                RETURN fail('"alert.handler" missing or longer than 30 (DBMS_ALERT name)');
            END IF;
            IF length(r.severity) > 30 THEN
                RETURN fail('"alert.severity" longer than 30');
            END IF;
            IF length(r.value) > 250 OR length(r.metric) > 50 THEN
                RETURN fail('"condition.value" longer than 250 or "condition.metric" longer than 50');
            END IF;
            IF r.throttle_sec IS NOT NULL AND (ruleNumber(r.throttle_sec) IS NULL OR ruleNumber(r.throttle_sec) < 0) THEN
                RETURN fail('"alert.throttle_seconds" is not a number >= 0');
            END IF;

            l_rule.trigger_type       := l_trig;
            l_rule.target_context     := r.context;
            l_rule.condition_metric   := r.metric;
            l_rule.condition_operator := l_op;
            l_rule.condition_value    := r.value;
            l_rule.alert_handler      := r.handler;
            l_rule.alert_severity     := r.severity;
            l_rule.throttle_seconds   := ruleNumber(r.throttle_sec);

            -- Operator: allowed triggers
            l_ok := CASE
                WHEN l_op IN ('ON_START', 'ON_STOP', 'ON_EVENT', 'ON_UPDATE') THEN l_trig != C_LOGGING
                WHEN l_op = 'SEVERITY' THEN l_trig = C_LOGGING
                WHEN l_op IN ('MAX_DURATION_MS', 'AVG_DEVIATION_PCT') THEN l_trig IN (C_MARK_EVENT, C_TRACE_STOP)
                WHEN l_op = 'MAX_GAP_SECONDS' THEN l_trig IN (C_MARK_EVENT, C_TRACE_START)
                WHEN l_op = 'MAX_OCCURRENCE' THEN l_trig IN (C_MARK_EVENT, C_TRACE_STOP, C_PROCESS_UPDATE, C_PROCESS_STOP)
                WHEN l_op IN ('PRECEDED_BY', 'PRECEDED_BY_WITHIN_SECS') THEN
                     l_trig IN (C_MARK_EVENT, C_TRACE_START, C_TRACE_STOP, C_PROCESS_UPDATE, C_PROCESS_STOP)
                WHEN l_op = 'RUNTIME_EXCEEDED' THEN l_trig = C_PROCESS_UPDATE
                WHEN l_op = 'MAX_RUNTIME_EXCEEDED' THEN l_trig = C_PROCESS_STOP
                WHEN l_op IN ('STEPS_LEFT_HIGH', 'SUCCESS_RATE_LOW', 'STATUS_EQUALS', 'INFO_CONTAINS') THEN
                     l_trig IN (C_PROCESS_START, C_PROCESS_UPDATE, C_PROCESS_STOP)
                ELSE NULL
            END;
            IF l_ok IS NULL THEN
                RETURN fail('unknown "condition.operator" ' || r.operator);
            ELSIF NOT l_ok THEN
                RETURN fail('operator ' || l_op || ' not allowed for trigger ' || l_trig);
            END IF;

            -- Check and prepare the value
            CASE
                WHEN l_op IN ('ON_START', 'ON_STOP', 'ON_EVENT', 'ON_UPDATE') THEN
                    NULL;
                WHEN l_op = 'SEVERITY' THEN
                    l_rule.cond_upper := upper(trim(r.value));
                    IF l_rule.cond_upper IS NULL OR l_rule.cond_upper NOT IN ('ERROR', 'WARN', 'MONITOR', 'INFO', 'DEBUG') THEN
                        RETURN fail('SEVERITY needs ERROR, WARN, MONITOR, INFO or DEBUG');
                    END IF;
                WHEN l_op = 'INFO_CONTAINS' THEN
                    l_rule.cond_upper := upper(r.value);
                    IF l_rule.cond_upper IS NULL OR length(l_rule.cond_upper) > 100 THEN
                        RETURN fail('INFO_CONTAINS needs a text (max. 100)');
                    END IF;
                WHEN l_op IN ('PRECEDED_BY', 'PRECEDED_BY_WITHIN_SECS') THEN
                    -- PRECEDED_BY: ACTION[|CONTEXT]; PRECEDED_BY_WITHIN_SECS: ACTION[|CONTEXT]|SECONDS
                    l_parts := CASE WHEN r.value IS NULL THEN 0 ELSE regexp_count(r.value, '\|') + 1 END;
                    IF l_op = 'PRECEDED_BY_WITHIN_SECS' THEN
                        l_rule.cond_num := ruleNumber(r.value, l_parts);
                        l_parts := l_parts - 1;
                        IF l_rule.cond_num IS NULL OR l_rule.cond_num < 0 THEN
                            RETURN fail('PRECEDED_BY_WITHIN_SECS needs ACTION[|CONTEXT]|SECONDS');
                        END IF;
                    END IF;
                    IF l_parts NOT IN (1, 2) THEN
                        RETURN fail(l_op || ' needs ACTION or ACTION|CONTEXT');
                    END IF;
                    l_rule.cond_action := trim(regexp_substr(r.value, '[^|]+', 1, 1));
                    IF l_parts = 2 THEN
                        l_rule.cond_context := trim(regexp_substr(r.value, '[^|]+', 1, 2));
                    END IF;
                    IF l_rule.cond_action IS NULL THEN
                        RETURN fail(l_op || ' needs ACTION or ACTION|CONTEXT');
                    END IF;
                ELSE
                    -- all other operators: number (AVG_DEVIATION_PCT: 'pct|warmup|alpha')
                    l_rule.cond_num := ruleNumber(r.value, 1);
                    IF l_rule.cond_num IS NULL THEN
                        RETURN fail(l_op || ' needs a number (decimal point ".")');
                    END IF;
                    IF l_op = 'AVG_DEVIATION_PCT' AND (
                           (regexp_substr(r.value, '[^|]+', 1, 2) IS NOT NULL AND ruleNumber(r.value, 2) IS NULL)
                        OR (regexp_substr(r.value, '[^|]+', 1, 3) IS NOT NULL AND ruleNumber(r.value, 3) IS NULL)) THEN
                        RETURN fail('AVG_DEVIATION_PCT needs PCT[|WARMUP[|ALPHA]]');
                    END IF;
            END CASE;

            -- Classify: context rule or general action rule
            IF l_rule.target_context IS NOT NULL THEN
                l_key := l_rule.target_action || '|' || l_rule.target_context;
                IF NOT p_byCtx.EXISTS(l_key) THEN
                    p_byCtx(l_key) := t_rule_list();
                END IF;
                p_byCtx(l_key).EXTEND;
                p_byCtx(l_key)(p_byCtx(l_key).LAST) := l_rule;
            ELSE
                l_key := l_rule.target_action;
                IF NOT p_byAction.EXISTS(l_key) THEN
                    p_byAction(l_key) := t_rule_list();
                END IF;
                p_byAction(l_key).EXTEND;
                p_byAction(l_key)(p_byAction(l_key).LAST) := l_rule;
            END IF;

            IF l_op = 'AVG_DEVIATION_PCT' THEN
                -- 'pct|warmup|alpha'; missing values => default
                p_avg(l_key).warmup := coalesce(ruleNumber(r.value, 2), g_avg_params('DEFAULT').warmup);
                p_avg(l_key).alpha  := coalesce(ruleNumber(r.value, 3), g_avg_params('DEFAULT').alpha);
            END IF;
        END LOOP;

        RETURN NULL;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN substr('rule #' || l_no || ': ' || sqlErrM, 1, 1000);
    END;

    --------------------------------------------------------------------------
    -- Remove the rules of a group from the global maps (key GROUP|...).
    -- The maps are small and this only happens at load time, hence one pass over all keys.
    -- STABILITY: independent of the sort order of the keys (NLS_SORT).
    --------------------------------------------------------------------------
    procedure removeGroupRules(p_group varchar2)
    as
        l_prefix VARCHAR2(51) := p_group || '|';
        l_len    PLS_INTEGER  := length(p_group) + 1;
        l_key    VARCHAR2(300);
        l_next   VARCHAR2(300);
    begin
        l_key := g_rules_by_context.FIRST;
        WHILE l_key IS NOT NULL LOOP
            l_next := g_rules_by_context.NEXT(l_key);
            IF substr(l_key, 1, l_len) = l_prefix THEN g_rules_by_context.DELETE(l_key); END IF;
            l_key := l_next;
        END LOOP;

        l_key := g_rules_by_action.FIRST;
        WHILE l_key IS NOT NULL LOOP
            l_next := g_rules_by_action.NEXT(l_key);
            IF substr(l_key, 1, l_len) = l_prefix THEN g_rules_by_action.DELETE(l_key); END IF;
            l_key := l_next;
        END LOOP;

        l_key := g_avg_params.FIRST;
        WHILE l_key IS NOT NULL LOOP
            l_next := g_avg_params.NEXT(l_key);
            IF substr(l_key, 1, l_len) = l_prefix THEN g_avg_params.DELETE(l_key); END IF;
            l_key := l_next;
        END LOOP;

        -- Throttling starts over with the new rule set
        l_key := g_alert_history.FIRST;
        WHILE l_key IS NOT NULL LOOP
            l_next := g_alert_history.NEXT(l_key);
            IF substr(l_key, 1, l_len) = l_prefix THEN g_alert_history.DELETE(l_key); END IF;
            l_key := l_next;
        END LOOP;
    end;

    --------------------------------------------------------------------------
    -- Take over a checked rule set for a group (replaces the previous rules of the group)
    --------------------------------------------------------------------------
    procedure installGroupRules(p_group varchar2, p_byCtx t_rule_map, p_byAction t_rule_map,
                                p_avg t_avg_params_map, p_ruleSetName varchar2, p_ruleSetVersion number)
    as
        l_key VARCHAR2(300);
    begin
        removeGroupRules(p_group);

        l_key := p_byCtx.FIRST;
        WHILE l_key IS NOT NULL LOOP
            g_rules_by_context(p_group || '|' || l_key) := p_byCtx(l_key);
            l_key := p_byCtx.NEXT(l_key);
        END LOOP;

        l_key := p_byAction.FIRST;
        WHILE l_key IS NOT NULL LOOP
            g_rules_by_action(p_group || '|' || l_key) := p_byAction(l_key);
            l_key := p_byAction.NEXT(l_key);
        END LOOP;

        l_key := p_avg.FIRST;
        WHILE l_key IS NOT NULL LOOP
            g_avg_params(p_group || '|' || l_key) := p_avg(l_key);
            l_key := p_avg.NEXT(l_key);
        END LOOP;

        -- Name/version as in LILAM_RULES (SET_NAME/VERSION); the consumer finds the rule through it
        g_rule_groups(p_group).set_name    := p_ruleSetName;
        g_rule_groups(p_group).set_version := p_ruleSetVersion;
    end;

    --------------------------------------------------------------------------
    -- Load the active rule set of a group from LILAM_RULES if it has changed.
    -- p_force: always reload (server start, UPDATE_RULE).
    -- Without an active rule set the group has no rules. STABILITY: an invalid rule set is
    -- rejected completely (logged once per version), the previous rules then remain active.
    -- Errors never reach the caller.
    --------------------------------------------------------------------------
    procedure refreshGroupRules(p_group varchar2, p_force boolean)
    as
        l_ruleSet  CLOB;
        l_name     VARCHAR2(30);
        l_version  NUMBER;
        l_byCtx    t_rule_map;
        l_byAction t_rule_map;
        l_avg      t_avg_params_map;
        l_err      VARCHAR2(1000);
        l_new      t_rule_group_rec;
    begin
        IF p_group IS NULL THEN
            RETURN;
        END IF;

        -- STABILITY: set the check time first, so that even on errors
        -- at most one check per interval takes place
        IF NOT g_rule_groups.EXISTS(p_group) THEN
            g_rule_groups(p_group) := l_new;
        END IF;
        g_rule_groups(p_group).last_check_cs := dbms_utility.get_time;

        -- PERFORMANCE: the expression matches the unique index idx_lilam_rules_active.
        -- The CLOB comes only as a locator and is read only for a new version.
        BEGIN
            EXECUTE IMMEDIATE 'SELECT rule_set, set_name, version FROM ' || C_LILAM_RULES_TABLE || '
                                WHERE CASE WHEN is_active = 1 THEN upper(group_name) END = :1'
                INTO l_ruleSet, l_name, l_version USING p_group;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                -- no active rule set for the group: no rules
                IF p_force OR g_rule_groups(p_group).set_name IS NOT NULL THEN
                    removeGroupRules(p_group);
                END IF;
                g_rule_groups(p_group).set_name     := NULL;
                g_rule_groups(p_group).set_version  := 0;
                g_rule_groups(p_group).seen_name    := NULL;
                g_rule_groups(p_group).seen_version := NULL;
                RETURN;
        END;

        -- unchanged (also an already rejected rule set): nothing to do
        IF NOT p_force
           AND l_name = g_rule_groups(p_group).seen_name AND l_version = g_rule_groups(p_group).seen_version THEN
            RETURN;
        END IF;
        g_rule_groups(p_group).seen_name    := l_name;
        g_rule_groups(p_group).seen_version := l_version;

        l_err := parseRuleSet(l_ruleSet, l_byCtx, l_byAction, l_avg);
        IF l_err IS NOT NULL THEN
            logLilamErr(NUM_ERR_RULE_SET, 'Rule set ' || l_name || ' v' || l_version || ' (group ' || p_group || ') rejected: ' || l_err, 'refreshGroupRules');
            if g_serverPipeName is not null and should_raise_error(g_serverProcessId) then
                error(g_serverProcessId, g_serverPipeName || '=>Rule set ' || l_name || ' v' || l_version || ' rejected: ' || l_err);
            end if;
            RETURN;
        END IF;

        installGroupRules(p_group, l_byCtx, l_byAction, l_avg, l_name, l_version);

    exception
        when others then
            logLilamErr(sqlCode, sqlErrM, 'refreshGroupRules', 'group ' || p_group);
            if g_serverPipeName is not null and should_raise_error(g_serverProcessId) then
                error(g_serverProcessId, g_serverPipeName || '=>Could not load rule set of group ' || p_group || ': ' || sqlErrM);
            end if ;
    END;

    --------------------------------------------------------------------------
    -- Loads the active rule set of the own group from LILAM_RULES (start and UPDATE_RULE).
    --------------------------------------------------------------------------
    procedure loadServerRules
    as
    begin
        -- Dispatchers do not evaluate rules
        if g_serverIsDispatcher then
            return;
        end if;
        refreshGroupRules(upper(trim(g_serverGroupName)), p_force => TRUE);
    END;

    --------------------------------------------------------------------------
    -- Activate a rule set for a server group (autonomous, so that the servers see it immediately)
    --------------------------------------------------------------------------
    procedure activateGroupRules(p_groupName varchar2, p_ruleSetName varchar2, p_ruleSetVersion pls_integer)
    as
        pragma autonomous_transaction;
    begin
        -- two steps: the unique index allows only one active rule set per group
        execute immediate 'UPDATE ' || C_LILAM_RULES_TABLE || ' SET is_active = 0
                            WHERE upper(group_name) = upper(:1) AND is_active = 1'
            using p_groupName;
        execute immediate 'UPDATE ' || C_LILAM_RULES_TABLE || ' SET is_active = 1
                            WHERE upper(group_name) = upper(:1) AND set_name = :2 AND version = :3'
            using p_groupName, p_ruleSetName, p_ruleSetVersion;
        commit;
    exception
        when others then
            rollback;
            raise;
    end;

    --------------------------------------------------------------------------
    -- Activate a rule set for all servers of a group (dispatchers excluded).
    -- The rule set is checked here; an invalid or missing rule set changes nothing.
    -- Running servers receive UPDATE_RULE directly in their pipe (bypassing the dispatcher);
    -- servers that start later load the active rule set of their group themselves.
    --------------------------------------------------------------------------
    PROCEDURE SERVER_UPDATE_RULES(p_groupName VARCHAR2, p_ruleSetName VARCHAR2, p_ruleSetVersion PLS_INTEGER)
    AS
        l_ruleSet  CLOB;
        l_byCtx    t_rule_map;
        l_byAction t_rule_map;
        l_avg      t_avg_params_map;
        l_err      VARCHAR2(1000);
        l_pipes    sys.odcivarchar2list;
        l_status   PLS_INTEGER;
        l_label    VARCHAR2(200) := 'LILAM: rule set ' || p_ruleSetName || ' v' || p_ruleSetVersion || ' (group ' || p_groupName || ')';
    BEGIN
        BEGIN
            EXECUTE IMMEDIATE 'SELECT rule_set FROM ' || C_LILAM_RULES_TABLE || '
                                WHERE upper(group_name) = upper(:1) AND set_name = :2 AND version = :3'
                INTO l_ruleSet USING p_groupName, p_ruleSetName, p_ruleSetVersion;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(NUM_ERR_RULE_SET, l_label || ' not found in ' || C_LILAM_RULES_TABLE);
            WHEN TOO_MANY_ROWS THEN
                RAISE_APPLICATION_ERROR(NUM_ERR_RULE_SET, l_label || ' exists more than once in ' || C_LILAM_RULES_TABLE);
        END;

        l_err := parseRuleSet(l_ruleSet, l_byCtx, l_byAction, l_avg);
        IF l_err IS NOT NULL THEN
            RAISE_APPLICATION_ERROR(NUM_ERR_RULE_SET, l_label || ' rejected: ' || l_err);
        END IF;

        activateGroupRules(p_groupName, p_ruleSetName, p_ruleSetVersion);

        -- notify the running servers of the group; a group without servers is not an error
        EXECUTE IMMEDIATE 'SELECT pipe_name FROM ' || C_LILAM_SERVER_REGISTRY || '
                            WHERE upper(group_name) = upper(:1) AND nvl(is_dispatcher, 0) = 0 AND is_active = 1'
            BULK COLLECT INTO l_pipes USING p_groupName;

        FOR i IN 1 .. l_pipes.COUNT LOOP
            DBMS_PIPE.RESET_BUFFER;
            DBMS_PIPE.PACK_MESSAGE('{"header":{"msg_type":"API_CALL","request":"UPDATE_RULE"}}');
            l_status := DBMS_PIPE.SEND_MESSAGE(l_pipes(i), timeout => 1);
            IF l_status != 0 THEN
                -- the rule set is active: the server loads it at the latest on its next start
                logLilamErr(l_status, l_label || ': pipe ' || l_pipes(i) || ' not reachable', 'SERVER_UPDATE_RULES');
            END IF;
        END LOOP;
    END;

    --------------------------------------------------------------------------

    --------------------------------------------------------------------------
    -- After each NEW_SESSION immediately update open processes and timestamp in the registry.
    -- Otherwise NEW_SESSION calls in quick succession (e.g. 20 in 0.5 s) still see the values of the
    -- last periodic update and all end up at the same server. With the selection
    -- "oldest entry first" the next request thereby goes to another server.
    --------------------------------------------------------------------------
    procedure touchServerRegistry as
        pragma autonomous_transaction;
    begin
        execute immediate 'UPDATE ' || C_LILAM_SERVER_REGISTRY || '
                              SET last_activity = SYSTIMESTAMP, current_processes = :1
                            WHERE upper(pipe_name) = :2'
            using greatest(v_indexSession.COUNT - 1, 0), upper(g_serverPipeName);
        commit;
    exception
        when others then
            rollback;
            logLilamErr(sqlCode, sqlErrM, 'touchServerRegistry');
    end;

    --------------------------------------------------------------------------

    procedure updateServerRegistry(p_ready BOOLEAN, p_eventCounter PLS_INTEGER) as
        pragma autonomous_transaction; 
        l_sqlStmt varchar2(500);
        l_booleanAsInt NUMBER(1) := 1;
        l_status    varchar2(20);
    begin

        case p_ready
            when true then l_booleanAsInt := 1;
            when false then l_booleanAsInt := 0;
        end case;

        case
            when p_eventCounter > 0 then
                if p_ready then
                    l_status := 'PROCESSING';
                    DBMS_APPLICATION_INFO.SET_ACTION('PROCESSING');
                    DBMS_APPLICATION_INFO.SET_CLIENT_INFO('Bulk Load:' || p_eventCounter);
                else
                    l_status := 'SHUTDOWN';
                    DBMS_APPLICATION_INFO.SET_ACTION('SHUTDOWN');
                    DBMS_APPLICATION_INFO.SET_CLIENT_INFO('Time:' || systimestamp);
                end if;

            when p_eventCounter = 0 then
                if p_ready then
                    l_status := 'PENDING';
                    DBMS_APPLICATION_INFO.SET_ACTION('PENDING');
                    DBMS_APPLICATION_INFO.SET_CLIENT_INFO('Time:' || systimestamp);
                else
                    l_status := 'STOPPED';
                    DBMS_APPLICATION_INFO.SET_MODULE(NULL, NULL);
                    DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL);
                end if;

            when p_eventCounter < 0 then
                if p_ready then
                    l_status := 'UNKNOWN';
                    DBMS_APPLICATION_INFO.SET_ACTION('UNKNOWN');
                    DBMS_APPLICATION_INFO.SET_CLIENT_INFO('Time:' || systimestamp);
                else
                    l_status := 'ERROR';
                    DBMS_APPLICATION_INFO.SET_ACTION('ERROR');
                    DBMS_APPLICATION_INFO.SET_CLIENT_INFO('Exception; Server stopped!');
                end if;
        end case;

        l_sqlStmt := '
        UPDATE ' || C_LILAM_SERVER_REGISTRY || '
        SET last_activity = SYSTIMESTAMP, 
            is_active = :1,
            current_processes = :2,  -- Number of open processes (previously column current_load = pipe_size from v$db_pipes, see below)
            status = :3,
            processing = :4,
            avg_log_lat = :5,
            max_log_lat = :6,
            avg_mon_lat = :7,
            max_mon_lat = :8
        WHERE upper(pipe_name) = :9';
        -- CURRENT_PROCESSES = number of open processes of this server (without the server process itself).
        -- Previously: pipe_size from v$db_pipes. That was unsuitable and expensive:
        --   * pipe_size is a high-water mark of the used memory and does not go down after processing
        --   * v$db_pipes searches the entire library cache (approx. 120-190 ms per query, server blocked)
        --   * required an additional grant on V_$DB_PIPES
        execute immediate l_sqlStmt USING l_booleanAsInt, greatest(v_indexSession.COUNT - 1, 0), l_status, p_eventCounter, 
            g_avgLatencyLogs, g_maxLatencyLogs, g_avgLatencyMon, g_maxLatencyMon, upper(g_serverPipeName);
        COMMIT; -- Must be autonomous!

    exception
        when others then
            rollback;
            logLilamErr(sqlCode, sqlErrM, 'updateServerRegistry'); 
            if should_raise_error(g_serverProcessId) then
                error(g_serverProcessId, 'Could not update server registry: ' || sqlErrM);
            end if ;
    END;

    --------------------------------------------------------------------------

    function receiveMessage(l_pipeName IN varchar2, p_cur_timeout IN OUT NUMBER) return varchar2
    as
        l_status    PLS_INTEGER;
        l_message   VARCHAR2(32767);
        c_max_timeout CONSTANT NUMBER := C_SERVER_TIMEOUT_MAX_WAIT_SEC; -- Maximum for eco mode
        c_min_timeout CONSTANT NUMBER := C_SERVER_TIMEOUT_WAIT_FOR_MSG_SEC;
    begin
        l_status := DBMS_PIPE.RECEIVE_MESSAGE(l_pipeName, timeout => p_cur_timeout);

        if l_status = 0 THEN
            p_cur_timeout := C_SERVER_TIMEOUT_WAIT_FOR_MSG_SEC;

            begin   
                DBMS_PIPE.UNPACK_MESSAGE(l_message);
                return l_message;

                EXCEPTION
                    WHEN OTHERS THEN
                        if should_raise_error(g_serverProcessId) then
                            ERROR(g_serverProcessId, g_serverPipeName || '=>Receiving message per pipe; ' || SQLERRM);
                        end if;
                END; 
        else
             p_cur_timeout := LEAST(p_cur_timeout + C_SERVER_TIMEOUT_WAIT_FOR_MSG_SEC, c_max_timeout);
            return null;
        end if;
        
        EXCEPTION
            WHEN OTHERS THEN
            logLilamErr(sqlCode, sqlErrM, 'receiveMessage'); 
            return null;
    end;

    --------------------------------------------------------------------------

    procedure preparePipe(p_pipeName varchar2)
    as
        l_dummyRes PLS_INTEGER;
    begin
        DBMS_PIPE.RESET_BUFFER;
        DBMS_PIPE.PURGE(p_pipeName);
        l_dummyRes := DBMS_PIPE.REMOVE_PIPE(upper(p_pipeName));
        DBMS_PIPE.PURGE(ctlPipe(p_pipeName));
        l_dummyRes := DBMS_PIPE.REMOVE_PIPE(ctlPipe(p_pipeName));
        l_dummyRes := DBMS_PIPE.CREATE_PIPE(pipename => upper(p_pipeName), maxpipesize => C_MAX_SERVER_PIPE_SIZE, private => false);
        -- Control pipe for NEW_SESSION (see C_CTL_PIPE_SUFFIX)
        l_dummyRes := DBMS_PIPE.CREATE_PIPE(pipename => ctlPipe(p_pipeName), maxpipesize => C_MAX_CTL_PIPE_SIZE, private => false);
    end;

    --------------------------------------------------------------------------

    function processRequest(p_request varchar2, p_message varchar2, p_clientChannel varchar2, p_drain BOOLEAN DEFAULT FALSE, p_forceDrain BOOLEAN DEFAULT FALSE) return boolean
    as
        l_targetPipe varchar2(100);
        l_processId  number (19,0);
        l_status PLS_INTEGER;        
    begin
        -- Dispatcher mode: forward everything, process nothing itself
        -- Exception: SERVER_SHUTDOWN is meant for the dispatcher itself (otherwise it cannot be stopped)
        if g_serverIsDispatcher and p_request not in ('SERVER_SHUTDOWN', 'SERVER_PING') then
            if p_request in ('NEW_SESSION', 'SERVER_NEW_SESSION') then
                -- No process_id yet; selection purely load-based
                l_targetPipe := getServerPipeAvailable(g_serverGroupName);
            else
                l_processId := jsonNumber(JSON_QUERY(p_message, '$.payload'), 'process_id');
                l_targetPipe := resolveDispatchTarget(l_processId); -- Cache, otherwise DB fallback
            end if;
    
            if l_targetPipe is null then
                -- No worker available or no route for the process_id.
                -- Answer synchronous requests (with return channel) immediately with an error instead of discarding them:
                -- otherwise the client waits for the full timeout (e.g. reconnect with outdated ID: 5 s per call).
                if p_clientChannel is not null then
                    DBMS_PIPE.RESET_BUFFER;
                    DBMS_PIPE.PACK_MESSAGE('{"header":{"msg_type":"SERVER_RESPONSE","msg_name":"NO_TARGET"},"payload":{"server_code":'
                        || case when p_request in ('NEW_SESSION', 'SERVER_NEW_SESSION') then NUM_ERR_NO_SERVER else NUM_ERR_SERVER_PROC end
                        || ',"server_message":"'
                        || case when p_request in ('NEW_SESSION', 'SERVER_NEW_SESSION') then TXT_ERR_NO_SERVER else TXT_ERR_SERVER_PROC end
                        || '"}}');
                    l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 0);
                end if;
                return false;
            end if;
    
            -- pass on unchanged, including the original client return channel in the header
            DBMS_PIPE.RESET_BUFFER;
            DBMS_PIPE.PACK_MESSAGE(p_message);        
            if p_request in ('NEW_SESSION', 'SERVER_NEW_SESSION') then
                -- NEW_SESSION to the worker's control pipe, then a wake-up call into its data pipe
                l_status := DBMS_PIPE.SEND_MESSAGE(ctlPipe(l_targetPipe), timeout => 1);
                sendPing(l_targetPipe);
            else
                l_status := DBMS_PIPE.SEND_MESSAGE(l_targetPipe, timeout => 1);
                -- STABILITY: remove the route of the finished process from the cache, otherwise
                -- g_dispatch_route_cache grows with every process that ever ran via the dispatcher.
                -- Later messages for this ID fall back to LILAM_PROCESS_ROUTE (resolveDispatchTarget).
                if p_request = 'CLOSE_SESSION' then
                    g_dispatch_route_cache.DELETE(l_processId);
                end if;
            end if;
            return false;
        end if;

        CASE p_request
            WHEN 'SERVER_SHUTDOWN' then
                if handleServerShutdown(p_clientChannel, p_message) then 
                    -- only if a valid password was sent
                    INFO(g_serverProcessId, g_serverPipeName || '=> Shutdown by remote request');
                    return true; -- Stop signal
                end if ;

            WHEN 'UPDATE_RULE' then
                loadServerRules; -- reload the active rule set of the group

            WHEN 'SERVER_PING' then
            null;

            WHEN 'NEW_SESSION' THEN
                if not p_drain then
                    INFO(g_serverProcessId, g_serverPipeName || '=> New remote session ordered');
                    doRemote_newSession(p_clientChannel, p_message);
                end if;

            WHEN 'CLOSE_SESSION' THEN
                INFO(g_serverProcessId, g_serverPipeName || '=> Remote session closed');
                doRemote_closeSession(p_clientChannel, p_message);

            WHEN 'LOG_ANY' then
                doRemote_logAny(p_message);

            WHEN 'SET_ANY_STATUS' then
                doRemote_setAnyStatus(p_message);

            WHEN 'PROC_STEP_DONE' then
                doRemote_procStepDone(p_message);

            WHEN 'RECONNECT_PROCESS' then
                doRemote_reconnectProcess(p_clientChannel, p_message);

            WHEN 'GET_PROCESS_DATA' then
                doRemote_getProcessData(p_clientChannel, p_message);

            WHEN C_MARK_EVENT then
                doRemote_markEvent(p_message);

            WHEN 'START_TRACE' then
                doRemote_startTrace(p_message);

            WHEN 'STOP_TRACE' then
                doRemote_stopTrace(p_message);

            WHEN 'GET_MONITOR_LAST_ENTRY' then
                doRemote_getMonitorLastEntry(p_clientChannel, p_message);

            WHEN 'UNFREEZE_REQUEST' then
                if not p_forceDrain then
                    doRemote_unfreezeClient(p_clientChannel, p_message, p_drain);
                end if;

            ELSE 
                -- Log unknown tag
                warn(g_serverProcessId, g_serverPipeName || '=> Received unknown request: ' || p_request);
        END CASE;

        return false; -- no stop signal
    end;

    --------------------------------------------------------------------------

    procedure START_SERVER(p_pipeName varchar2, p_groupName varchar2, p_password varchar2, p_isDispatcher PLS_INTEGER DEFAULT 0,
                           p_perfServer PLS_INTEGER DEFAULT NULL)
    as
        v_key            VARCHAR2(100); 
        l_clientChannel  varchar2(50);
        l_message        JSON_OBJ_LILAM;
        l_status         PLS_INTEGER;
        l_request        VARCHAR2(500);
        l_dummyRes       PLS_INTEGER;
        l_shutdownSignal BOOLEAN := FALSE;
        l_lastHeartbeat  TIMESTAMP := sysTimestamp;
        l_lastSync       TIMESTAMP := sysTimestamp;  
        l_loopCounter    PLS_INTEGER := 0;
        l_msgCnt         PLS_INTEGER := 0;
        l_serverTimeout  NUMBER := C_SERVER_TIMEOUT_WAIT_FOR_MSG_SEC;
        l_ctlPipe        VARCHAR2(150);
    begin
        g_serverIsDispatcher := CASE nvl(p_isDispatcher, 0) WHEN 1 THEN TRUE ELSE FALSE END;
        g_server_perf := normPerf(p_perfServer);   -- is passed to the clients on NEW_SESSION/RECONNECT
        g_shutdownPassword := p_password;
        g_serverPipeName := p_pipeName;
        g_serverGroupName := p_groupName;
        g_serverProcessId := new_session(p_processName => 'LILAM_SERVER', p_logLevel => logLevelMonitor, p_tabNameMaster => 'LILAM_SERVER');
        SET_PROCESS_STATUS(g_serverProcessId, 1, 'RUNNING');

        registerServerPipe;
        preparePipe(g_serverPipeName);
        l_ctlPipe := ctlPipe(g_serverPipeName);
        loadServerRules;
        updateServerRegistry(TRUE, 0);
        DBMS_APPLICATION_INFO.SET_MODULE(
            module_name => 'LILAM_SERVER ' || g_serverPipeName, 
            action_name => 'STARTUP'
        );

        LOOP
            -- First the control pipe (NEW_SESSION), without waiting. If it is empty, this costs only a few µs.
            LOOP
                l_status := DBMS_PIPE.RECEIVE_MESSAGE(l_ctlPipe, timeout => 0);
                EXIT WHEN l_status != 0;
                -- count as well: PROCESSING in the registry is the first criterion of server selection
                l_msgCnt := l_msgCnt + 1;
                BEGIN
                    DBMS_PIPE.UNPACK_MESSAGE(l_message);
                    l_clientChannel := extractClientChannel(l_message);
                    l_request := extractClientRequest(l_message);
                    l_shutdownSignal := processRequest(l_request, l_message, l_clientChannel);
                EXCEPTION
                    WHEN OTHERS THEN
                        logLilamErr(sqlCode, sqlErrM, 'START_SERVER', 'CTL_PIPE');
                END;
            END LOOP;

            -- Wait for the next message (timeout in seconds)
            l_message := receiveMessage(g_serverPipeName, l_serverTimeout); 
            if l_message is not null THEN
                l_msgCnt := l_msgCnt + 1;
            BEGIN 
                l_clientChannel := extractClientChannel(l_message);
                l_request := extractClientRequest(l_message);
                l_shutdownSignal := processRequest(l_request, l_message, l_clientChannel);
                EXCEPTION
                    WHEN OTHERS THEN
                        -- IMPORTANT: log errors, but do NOT leave the loop!
                        if should_raise_error(g_serverProcessId) then
                            ERROR(g_serverProcessId, g_serverPipeName || '=>Internal START_SERVER; Critical Error while processing command: ' || SQLERRM);
                        end if;
                END; 
            end if;

            if l_message is null or l_loopCounter > C_SERVER_MAX_LOOPS_IN_TIME_NO then
                if get_ms_diff(l_lastSync, sysTimestamp) >= C_SERVER_SYNC_INTERVAL_MS  THEN
                    -- Housekeeping
                    updateServerRegistry(TRUE, l_msgCnt);
                    SYNC_ALL_DIRTY;
                    l_lastSync := sysTimestamp;
                    l_loopCounter := 0;
                    l_msgCnt := 0;
                end if;

                -- Timeout reached. Happens if no signal arrived within an interval.
                if get_ms_diff(l_lastHeartbeat, sysTimestamp) >= C_SERVER_HEARTBEAT_INTERVAL_MS then
                    INFO(g_serverProcessId, g_serverPipeName || 'HEARTBEAT ' || g_serverPipeName);
                    l_lastHeartbeat := sysTimestamp;
                end if ;
            end if ;

            EXIT when l_shutdownSignal;
            l_loopCounter := l_loopCounter + 1;
        END LOOP;
        -- From now on the server is no longer reachable
        updateServerRegistry(FALSE, l_msgCnt);
        SET_PROCESS_STATUS(g_serverProcessId, 0, 'STOPPED');

        -- +++ NEW: DRAIN PHASE +++
        -- We empty the pipe in case messages still arrived during the shutdown.
        LOOP
            l_status := DBMS_PIPE.RECEIVE_MESSAGE(g_serverPipeName, timeout => 0.1);
            EXIT WHEN l_status != 0; -- Pipe is empty (1) or error/interrupt (!=0)

            DBMS_PIPE.UNPACK_MESSAGE(l_message);
            l_clientChannel := extractClientChannel(l_message);
            l_request := extractClientRequest(l_message);

            -- In the drain we only process log data, no new sessions/shutdowns
                l_shutdownSignal := processRequest(l_request, l_message, l_clientChannel, TRUE);

        END LOOP;

        DBMS_OUTPUT.ENABLE();

        -- there could still be dirty buffered entries
        sync_all_dirty(true, true);

        if g_serverProcessId != -1 THEN
            DBMS_OUTPUT.PUT_LINE('Finaler Cleanup für Server-ID: ' || g_serverProcessId);
            clearServerData;
            clearAllSessionData(g_serverProcessId);
        end if ;

        DBMS_PIPE.PURGE(g_serverPipeName); 
        l_dummyRes := DBMS_PIPE.REMOVE_PIPE(g_serverPipeName);
        DBMS_PIPE.PURGE(ctlPipe(g_serverPipeName));
        l_dummyRes := DBMS_PIPE.REMOVE_PIPE(ctlPipe(g_serverPipeName));
        g_remote_sessions.DELETE;

        -- final analysis of the buffer states
        DUMP_BUFFER_STATS;

        close_session(g_serverProcessId);
        updateServerRegistry(FALSE, 0);

    EXCEPTION

    WHEN OTHERS THEN
        logLilamErr(sqlCode, sqlErrM, 'START_SERVER', 'MAIN CODE');
        if should_raise_error(g_serverProcessId) then
            ERROR(g_serverProcessId, g_serverPipeName || '=>Internal START_SERVER; Critical Error: ' || SQLERRM);
        end if;
        
        -- error handling step by step ensuring to close max. number of pipes
        begin
            DBMS_PIPE.PURGE(g_serverPipeName); 
            l_dummyRes := DBMS_PIPE.REMOVE_PIPE(g_serverPipeName);
        exception
            when others then
                logLilamErr(sqlCode, sqlErrM, 'START_SERVER', 'DBMS_PIPE.PURGE');
        end;
        
        begin
            DBMS_PIPE.PURGE(ctlPipe(g_serverPipeName));
            l_dummyRes := DBMS_PIPE.REMOVE_PIPE(ctlPipe(g_serverPipeName));
        exception
            when others then
                logLilamErr(sqlCode, sqlErrM, 'START_SERVER', 'DBMS_PIPE.PURGE');
        end;
        
        -- the next procedures use their own error handling
        clearServerData;
        clearAllSessionData(g_serverProcessId);
        updateServerRegistry(FALSE, -1);

    end;

    --------------------------------------------------------------------------

PROCEDURE CALL_BY_JSON(
    p_callObject  IN  JSON_OBJ_LILAM,
    p_respObject  OUT JSON_OBJ_LILAM
)
AS
    l_InObject      JSON_OBJ_LILAM := p_callObject;
    l_jsonHeaderIn  JSON_OBJ_LILAM;   -- Header from the request
    l_jsonParams    JSON_OBJ_LILAM;   -- Params from the request (now actually filled)
    l_jsonHeader    JSON_OBJ_LILAM;   -- Header of the response
    l_jsonPayload   JSON_OBJ_LILAM;   -- Payload of the response
    l_api_call      VARCHAR2(30);
    l_proc_id       NUMBER;
    p_session_init  t_session_init;
BEGIN
    if not p_callObject IS JSON then
        RAISE_APPLICATION_ERROR(-20005, 'In-Parameter is invalid JSON-Format');
    end if;

    -- Extract header and params from the request
    l_jsonHeaderIn := jsonObject(l_InObject, 'header');
    l_api_call     := jsonString(l_jsonHeaderIn, 'api_call');
    l_jsonParams   := jsonObject(l_InObject, 'params');

    -- Basic response structure; 'status' is deliberately set ONLY ONCE,
    -- either below in the respective branch or in the ELSE fallback
    jsonPut(l_jsonHeader, 'header', l_jsonHeaderIn);
    jsonPut(l_jsonPayload, 'returns', 'NO_VALUE');
    jsonPut(l_jsonPayload, 'value', 'NULL');

    case l_api_call
        when 'SERVER_NEW_SESSION' THEN
            begin
                l_proc_id := SERVER_NEW_SESSION_JSON(l_jsonParams);
                jsonPut(l_jsonHeader, 'status', 'SUCCESS');
                jsonPut(l_jsonPayload, 'returns', 'PROCESS_ID');
                jsonPut(l_jsonPayload, 'value', l_proc_id);

            exception
                when others then
                    logLilamErr(sqlCode, sqlErrM, 'CALL_BY_JSON', 'SERVER_NEW_SESSION');
                    jsonPut(l_jsonHeader, 'status', 'ERROR');
                    jsonPut(l_jsonPayload, 'returns', 'ERR_NO');
                    jsonPut(l_jsonPayload, 'value', SQLCODE);
            end;

        when 'NEW_SESSION' THEN
            p_session_init.processName   := jsonString(l_jsonParams, 'process_name');
            p_session_init.logLevel      := jsonNumber(l_jsonParams, 'log_level');
            p_session_init.stepsToDo     := jsonNumber(l_jsonParams, 'steps_todo');
            p_session_init.daysToKeep    := jsonNumber(l_jsonParams, 'days_to_keep');
            p_session_init.procImmortal  := jsonNumber(l_jsonParams, 'process_immortal');
            p_session_init.tabNameMaster := jsonString(l_jsonParams, 'tabname_master');
            p_session_init.baselineScope := jsonString(l_jsonParams, 'baseline_scope');
            p_session_init.groupName     := jsonString(l_jsonParams, 'group_name');
            p_session_init.syncLevel     := nvl(jsonNumber(l_jsonParams, 'sync_level'), logLevelError);

            l_proc_id := NEW_SESSION(p_session_init);
            jsonPut(l_jsonHeader, 'status', 'SUCCESS');
            jsonPut(l_jsonPayload, 'returns', 'PROCESS_ID');
            jsonPut(l_jsonPayload, 'value', l_proc_id);

        when 'SERVER_SHUTDOWN' then
            SERVER_SHUTDOWN(
                jsonNumber(l_jsonParams, 'process_id'),
                jsonString(l_jsonParams, 'pipe_name'),   -- corrected: was 'process_name'
                jsonString(l_jsonParams, 'password')
            );
            jsonPut(l_jsonHeader, 'status', 'SUCCESS');

        when 'CLOSE_SESSION' THEN
            CLOSE_SESSION(jsonNumber(l_jsonParams, 'process_id'));
            jsonPut(l_jsonHeader, 'status', 'SUCCESS');

        when 'SET_PROCESS_STATUS' THEN
            SET_PROCESS_STATUS(jsonNumber(l_jsonParams, 'process_id'), jsonNumber(l_jsonParams, 'process_status'), jsonString(l_jsonParams, 'process_info'));
            jsonPut(l_jsonHeader, 'status', 'SUCCESS');

        when 'SET_STEP_TODO' THEN
            SET_PROC_STEPS_TODO(jsonNumber(l_jsonParams, 'process_id'), jsonNumber(l_jsonParams, 'steps_todo'));
            jsonPut(l_jsonHeader, 'status', 'SUCCESS');

        when 'SET_STEPS_DONE' THEN
            SET_PROC_STEPS_DONE(jsonNumber(l_jsonParams, 'process_id'), jsonNumber(l_jsonParams, 'steps_done'));
            jsonPut(l_jsonHeader, 'status', 'SUCCESS');

        when 'PROC_STEP_DONE' THEN
            PROC_STEP_DONE(jsonNumber(l_jsonParams, 'process_id'));
            jsonPut(l_jsonHeader, 'status', 'SUCCESS');

        when 'SET_PROC_IMMORTAL' THEN
            SET_PROC_IMMORTAL(jsonNumber(l_jsonParams, 'process_id'), jsonNumber(l_jsonParams, 'process_immortal'));
            jsonPut(l_jsonHeader, 'status', 'SUCCESS');

        when 'INFO' THEN
            INFO(jsonNumber(l_jsonParams, 'process_id'), jsonString(l_jsonParams, 'process_info'));
            jsonPut(l_jsonHeader, 'status', 'SUCCESS');

        when 'DEBUG' THEN
            DEBUG(jsonNumber(l_jsonParams, 'process_id'), jsonString(l_jsonParams, 'process_info'));
            jsonPut(l_jsonHeader, 'status', 'SUCCESS');

        when 'WARN' THEN
            WARN(jsonNumber(l_jsonParams, 'process_id'), jsonString(l_jsonParams, 'process_info'));
            jsonPut(l_jsonHeader, 'status', 'SUCCESS');

        when 'ERROR' THEN
            ERROR(jsonNumber(l_jsonParams, 'process_id'), jsonString(l_jsonParams, 'process_info'));
            jsonPut(l_jsonHeader, 'status', 'SUCCESS');

        when C_MARK_EVENT THEN
            MARK_EVENT(jsonNumber(l_jsonParams, 'process_id'), jsonString(l_jsonParams, 'action_name'), jsonString(l_jsonParams, 'context_name'), jsonTime(l_jsonParams, 'timestamp'));
            jsonPut(l_jsonHeader, 'status', 'SUCCESS');

        when C_TRACE_START THEN
            TRACE_START(jsonNumber(l_jsonParams, 'process_id'), jsonString(l_jsonParams, 'action_name'), jsonString(l_jsonParams, 'context_name'), jsonTime(l_jsonParams, 'timestamp'));
            jsonPut(l_jsonHeader, 'status', 'SUCCESS');

        when C_TRACE_STOP THEN
            TRACE_STOP(jsonNumber(l_jsonParams, 'process_id'), jsonString(l_jsonParams, 'action_name'), jsonString(l_jsonParams, 'context_name'), jsonTime(l_jsonParams, 'timestamp'));
            jsonPut(l_jsonHeader, 'status', 'SUCCESS');

        ELSE
            jsonPut(l_jsonHeader, 'status', 'ERROR');
            jsonPut(l_jsonPayload, 'returns', 'ERR_NO');
            jsonPut(l_jsonPayload, 'value', NUM_ERR_ILLEGAL_REQ);
    END CASE;

    jsonPut(p_respObject, 'header', l_jsonHeader);
    jsonPut(p_respObject, 'payload', l_jsonPayload);

EXCEPTION
    WHEN OTHERS THEN
    logLilamErr(sqlCode, sqlErrM, 'CALL_BY_JSON');
    jsonPut(l_jsonHeader, 'status', 'ERROR');
    jsonPut(l_jsonPayload, 'returns', 'ERR_NO');
    jsonPut(l_jsonPayload, 'value', NUM_ERR_UNKNOWN);
    jsonPut(p_respObject, 'header', l_jsonHeader);
    jsonPut(p_respObject, 'payload', l_jsonPayload);

END;
    PROCEDURE CALL_BY_JSON (
        p_callObject  IN  JSON_OBJECT_T,
        p_respObject  OUT JSON_OBJECT_T
    )
    AS
        l_callObject JSON_OBJ_LILAM;
        l_respObject JSON_OBJ_LILAM;
    BEGIN
        p_respObject := JSON_OBJECT_T();
        l_callObject := p_callObject.to_string();
        CALL_BY_JSON(l_callObject, l_respObject);
        p_respObject := JSON_OBJECT_T.parse(l_respObject);
    END;

    --------------------------------------------------------------------------

    FUNCTION quote_literal(p_text IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        -- Doubles single quotes and encloses the text in single quotes
        RETURN '''' || REPLACE(p_text, '''', '''''') || '''';
    END quote_literal;

    --------------------------------------------------------------------------

    FUNCTION CREATE_SERVER(p_pipeName varchar2, p_groupName varchar2, p_password  varchar2, p_isDispatcher PLS_INTEGER DEFAULT 0,
                           p_perfServer PLS_INTEGER DEFAULT NULL) RETURN VARCHAR2
    AS
        l_slot_idx PLS_INTEGER := 1; -- Example value, should be determined dynamically
        l_action   VARCHAR2(2000); -- Buffer slightly increased for longer strings
    BEGIN
        -- 1. Make sure that no "orphaned" job exists
        -- We specifically catch ORA-27475 (job does not exist)
        BEGIN
            null;
            DBMS_SCHEDULER.DROP_JOB(job_name => p_pipeName, force => TRUE);
        EXCEPTION 
            WHEN OTHERS THEN 
                IF SQLCODE != -27475 THEN RAISE; END IF;
        END;

        -- 2. Assemble the PL/SQL block for the scheduler
        -- Important: p_groupName has been integrated into the action
        l_action := 'BEGIN ' ||
                    '  LILAM.START_SERVER(' ||
                    '    p_pipeName  => ' || quote_literal(p_pipeName)      || ', ' ||
                    '    p_groupName => ' || quote_literal(p_groupName) || ', ' ||
                    '    p_password  => ' || quote_literal(p_password)  || ', ' ||
                    '    p_isDispatcher => ' || quote_literal(p_isDispatcher) || ', ' ||
                    '    p_perfServer => ' || normPerf(p_perfServer) ||
                    '  ); ' ||
                    'END;';

        -- 3. "Fire up" the background process
        DBMS_SCHEDULER.CREATE_JOB (
            job_name   => p_pipeName,
            job_type   => 'PLSQL_BLOCK',
            job_action => l_action,
            enabled    => TRUE,
            auto_drop  => TRUE,
            comments   => 'LILAM Background Worker [' || p_groupName || '] auf Pipe ' || p_pipeName
        );

        RETURN 'LILAM-Server gestartet: Pipe=' || p_pipeName || ' (Gruppe=' || p_groupName || ')';

    EXCEPTION
        WHEN OTHERS THEN
        logLilamErr(sqlCode, sqlErrM, 'CREATE_SERVER'); 
        return 'Internal CREATE_SERVER; job_action = ' || l_action || '; Critical Error while processing command: ' || SQLERRM;

    END;
    
    ------------------------------------------------------------------------

    PROCEDURE FINAL_RESCUE
    as
    begin
        SYNC_ALL_DIRTY(true, true);
    end;

    ------------------------------------------------------------------------

    PROCEDURE IS_ALIVE
    as
        pProcessName number(19,0);
    begin
        pProcessName := new_session('LILAM Life Check', logLevelDebug);
        debug(pProcessName, 'First Message of LILAM');
        close_session(p_processId => pProcessName, p_processInfo => 'OK', p_processStatus => 1, p_procStepsDone => 1, p_procStepsToDo => 1);
    end;

    BEGIN
        g_avg_params('DEFAULT').alpha := 0.1;
        g_avg_params('DEFAULT').warmup := 3; 

END LILAM;

/
