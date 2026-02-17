create or replace PACKAGE BODY LILAM AS
    /*
     * LILAM
     * Dual-licensed under GPLv3 or Commercial License.
     * See LICENSE or LICENSE_ENTERPRISE for details.
     */

        ---------------------------------------------------------------
        -- Tuning Parameter for development
        ---------------------------------------------------------------
        
        -- Dedicated to SERVER_LOOP
        C_SEVER_SYNC_INTERVAL           CONSTANT PLS_INTEGER := 500;
        C_SERVER_HEARTBEAT_INTERVAL     CONSTANT PLS_INTEGER := 60000;
        C_SERVER_MAX_LOOPS_IN_TIME      CONSTANT PLS_INTEGER := 10000;
        C_SERVER_TIMEOUT_WAIT_FOR_MSG   CONSTANT NUMBER      := 0.2; -- Timeout nach Sekunden Warten auf Nachricht
        C_MAX_SERVER_PIPE_SIZE          CONSTANT PLS_INTEGER := 16777216; --  16777216, 67108864 

        -- Dedicated to Client
        C_THROTTLE_LIMIT                CONSTANT PLS_INTEGER := 1000; -- Max logs until unfreeze handshake (depends to C_THROTTLE_INTERVAL)
        C_THROTTLE_INTERVAL             CONSTANT PLS_INTEGER := 1000; -- Max logs within this interval
        
        -- general Flush Time-Duration
        C_FLUSH_MILLIS_THRESHOLD        PLS_INTEGER          := 1500;  -- Max. Millis until flush
        C_FLUSH_LOG_THRESHOLD           PLS_INTEGER          := 50000; -- Max. number of dirty buffered logs until flush
        C_FLUSH_MONITOR_THRESHOLD         PLS_INTEGER          := 20000; -- Max. number of dirty buffered metrics until flush
        
        ---------------------------------------------------------------
        -- Placeholders for tables
        ---------------------------------------------------------------
        C_PARAM_MASTER_TABLE            CONSTANT varchar2(50) := 'PH_MASTER_TABLE';
        C_PARAM_LOG_TABLE               CONSTANT varchar2(50) := 'PH_LOG_TABLE';
        C_PARAM_MON_TABLE               CONSTANT varchar2(50) := 'PH_MON_TABLE';
        C_SUFFIX_LOG_TABLE              CONSTANT varchar2(16) := '_LOG';
        C_SUFFIX_MON_TABLE              CONSTANT varchar2(16) := '_MON';
        C_LILAM_SERVER_REGISTRY         CONSTANT VARCHAR2(50) := 'LILAM_SERVER_REGISTRY';
        C_LILAM_RULES                   CONSTANT VARCHAR2(50) := 'LILAM_RULES';
        C_LILAM_ALERTS                  CONSTANT VARCHAR2(50) := 'LILAM_ALERTS';
      
        ---------------------------------------------------------------
        -- Other general Parameters
        ---------------------------------------------------------------
        C_TIMEOUT_NEW_SESSION           CONSTANT NUMBER      := 3.0;  -- NEW_SESSION max. time waiting for server response
        C_METRIC_ALERT_FACTOR           CONSTANT NUMBER      := 2.0;   -- Max. Ausreißer in der Dauer eines Verarbeitungsschrittes
        
        -- Pipe handling
        C_PIPE_ID_PENDING               CONSTANT BINARY_INTEGER := -1; 
        C_INTERLEAVE_PIPE_SUFFIX        CONSTANT VARCHAR2(20)   := '_INTERLEAVE';
        
        ---------------------------------------------------------------
        -- Kind of Monitor Entries
        ---------------------------------------------------------------
        C_MON_TYPE_EVENT                CONSTANT PLS_INTEGER := 0; -- Simple event, no stop-time
        C_MON_TYPE_TRACE                CONSTANT PLS_INTEGER := 1; -- Transaction with start and stop
            
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
            last_monitor_flush    TIMESTAMP, -- Zeitpunkt des letzten Monitor-Flushes
            last_log_flush      TIMESTAMP, -- Zeitpunkt des letzten Log-Flushes
            monitor_dirty_count PLS_INTEGER := 0,  -- monitor entries per process counter
            log_dirty_count     PLS_INTEGER := 0,  -- Logs per process counter
            process_is_dirty    BOOLEAN,
            last_process_flush  TIMESTAMP,
            last_sync_check     TIMESTAMP,
            group_name          VARCHAR2(50),
            tabName_master      VARCHAR2(100)
        );
    
        -- Table for several processes
        TYPE t_session_tab IS TABLE OF t_session_rec;
        g_sessionList t_session_tab := null;
        
        -- Indexes for lists
        TYPE t_idx IS TABLE OF PLS_INTEGER INDEX BY BINARY_INTEGER;
        v_indexSession t_idx;
        
        -- Private Liste im Speicher (PGA)
        -- Index ist die Session-ID, Wert ist beliebig (hier Boolean)
        TYPE t_remote_sessions IS TABLE OF BOOLEAN INDEX BY BINARY_INTEGER;
        g_remote_sessions t_remote_sessions;
        
        TYPE t_throttle_stat IS RECORD (
            msg_count  PLS_INTEGER := 0,
            last_check TIMESTAMP    := SYSTIMESTAMP
        );
        TYPE t_throttle_tab IS TABLE OF t_throttle_stat INDEX BY BINARY_INTEGER;
        g_local_throttle_cache t_throttle_tab;
    
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
            avg_action_time NUMBER,             -- Umbenannt
            start_time      TIMESTAMP,          -- Startzeitpunkt der Aktion
            stop_time       TIMESTAMP,          -- Startzeitpunkt der Aktion
            used_time       NUMBER,             -- Dauer der letzten Ausführung (in Sek.)
            action_count   PLS_INTEGER := 0    -- Arbeitsschritt einer Action / Transaktion
        );
        TYPE t_monitor_history_tab IS TABLE OF t_monitor_buffer_rec;    
        TYPE t_monitor_map IS TABLE OF t_monitor_history_tab INDEX BY VARCHAR2(200);
        g_monitor_groups t_monitor_map;
        TYPE t_monitor_shadow_map IS TABLE OF t_monitor_buffer_rec INDEX BY VARCHAR2(200);
        g_monitor_shadows t_monitor_shadow_map;
        g_monitor_averages t_monitor_shadow_map;
                    
        ---------------------------------------------------------------
        -- Logging
        ---------------------------------------------------------------
        TYPE t_log_buffer_rec IS RECORD (
            process_id      NUMBER(19,0),
            log_level       PLS_INTEGER,
            log_text        VARCHAR2(4000),
            log_time        TIMESTAMP,
            serial_no       PLS_INTEGER,
            err_stack       VARCHAR2(4000),
            err_backtrace   VARCHAR2(4000),
            err_callstack   VARCHAR2(4000)
        );
        
        -- Die Liste für den Bulk-Speicher
        -- Die flache Liste der Log-Einträge
        TYPE t_log_history_tab IS TABLE OF t_log_buffer_rec;
        
        -- Das Haupt-Objekt für Logs: 
        -- Key ist hier die process_id (als String gewandelt für die Map)
        TYPE t_log_map IS TABLE OF t_log_history_tab INDEX BY VARCHAR2(100);
        g_log_groups t_log_map;
    
        TYPE t_dirty_queue IS TABLE OF BOOLEAN INDEX BY BINARY_INTEGER;
        g_dirty_queue t_dirty_queue;
        
        ---------------------------------------------------------------
        -- Rules
        ---------------------------------------------------------------
        -- Typ-Definition für die Regeldetails (aus dem JSON)
        TYPE t_rule_rec IS RECORD (
            rule_id             VARCHAR2(20),
            trigger_type        VARCHAR2(20),  -- TRACE_STOP, MARK_EVENT
            target_action       VARCHAR2(50),
            target_context      VARCHAR2(50),
            condition_metric    VARCHAR2(50),
            condition_operator  VARCHAR2(30),  -- GREATER_THAN_AVG_PERCENT, etc.
            condition_value     VARCHAR2(50),
            alert_handler       VARCHAR2(50),  -- LOG_AND_MAIL, etc.
            alert_severity      VARCHAR2(30),
            throttle_seconds    NUMBER         -- Warten bis zum nächsten Alarm
        );
        TYPE t_rule_list IS TABLE OF t_rule_rec;
        TYPE t_rule_map IS TABLE OF t_rule_list INDEX BY VARCHAR2(250);
        
        g_rules_by_context t_rule_map;
        g_rules_by_action  t_rule_map;
        
        -- Zusätzliche Variable für die aktuell geladene Version
        g_current_rule_set_version NUMBER := 0;
        g_current_rule_set_name    VARCHAR2(30);
        
        TYPE t_alert_history IS TABLE OF TIMESTAMP INDEX BY VARCHAR2(250);
        g_alert_history t_alert_history;
        
        ----------
        -- TRIGGER
        ----------
        -- Process
        C_PROCESS_START    CONSTANT VARCHAR2(20) := 'PROCESS_START';
        C_PROCESS_UPDATE   CONSTANT VARCHAR2(20) := 'PROCESS_UPDATE';
        C_PROCESS_STOP      CONSTANT VARCHAR2(20) := 'PROCESS_STOP';
        
        -- ACTIONS and TRANSACTIONS
        C_MARK_EVENT       CONSTANT VARCHAR2(20) := 'MARK_EVENT';
        C_TRACE_START      CONSTANT VARCHAR2(20) := 'TRACE_START';
        C_TRACE_STOP       CONSTANT VARCHAR2(20) := 'TRACE_STOP';
   
        ---------------------------------------------------------------
        -- Automatisierte Lastverteilung
        ---------------------------------------------------------------
        
        -- Tabelle der Clients und von ihnen verwendeter Pipes
        TYPE t_client_pipe IS TABLE OF VARCHAR2(128) INDEX BY BINARY_INTEGER;
        g_client_pipes t_client_pipe;
    
        ---------------------------------------------------------------
        -- General Variables
        ---------------------------------------------------------------    
        -- ALERT Registration
        g_isAlertRegistered                 BOOLEAN                 := false;
            
        TYPE code_map_t IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(30);
        g_response_codes code_map_t;
        
        g_serverPipeName                    VARCHAR2(50)            := NULL;
        g_serverProcessId                   PLS_INTEGER             := -1;
        g_serverGroupName                   VARCHAR2(50)            := NULL;
        g_shutdownPassword                  varchar2(50);
        
        g_is_high_perf                      BOOLEAN                 := FALSE;
        g_msg_counter                       PLS_INTEGER             := 0;
        g_last_check_time                   TIMESTAMP               := SYSTIMESTAMP;
        
        
        ---------------------------------------------------------------
        -- Functions and Procedures
        ---------------------------------------------------------------
        function getSessionRecord(p_processId number) return t_session_rec;
        function getProcessRecord(p_processId number) return t_process_rec;
        procedure sync_log(p_processId number, p_force boolean default false);
        procedure sync_monitor(p_processId number, p_force boolean default false);
        procedure sync_process(p_processId number, p_force boolean default false);
        function extractFromJsonStr(p_json_doc varchar2, jsonPath varchar2) return varchar2;
        function extractFromJsonNum(p_json_doc varchar2, jsonPath varchar2) return number;
        function extractFromJsonTime(p_json_doc varchar2, jsonPath varchar2) return TIMESTAMP;
        procedure flushMonitor(p_processId number);
        function getServerPipeAvailable(p_groupName varchar2) return varchar2;
        
        ---------------------------------------------------------------
        -- Antwort Codes stabil vereinheitlichen
        ---------------------------------------------------------------
        PROCEDURE initialize_map IS
        BEGIN
            if g_response_codes.COUNT = 0 THEN
                g_response_codes(TXT_ACK_SHUTDOWN) := NUM_ACK_SHUTDOWN;
                g_response_codes(TXT_ACK_OK)       := NUM_ACK_OK;
                g_response_codes(TXT_ACK_DECLINE)  := NUM_ACK_DECLINE;
                g_response_codes(TXT_PING_ECHO)    := NUM_PING_ECHO;
                g_response_codes(TXT_SERVER_INFO)  := NUM_SERVER_INFO;
                g_response_codes(TXT_DATA_ANSWER)  := NUM_DATA_ANSWER;
            end if ;
        END initialize_map;
        
        FUNCTION get_serverCode(p_txt VARCHAR2) RETURN PLS_INTEGER IS
        BEGIN
            initialize_map; -- Stellt sicher, dass die Map befüllt ist
            
            if g_response_codes.EXISTS(p_txt) THEN
                RETURN g_response_codes(p_txt);
            ELSE
                RETURN -1; -- Oder eine Exception werfen
            end if ;
        END;
        
        ---------------------------------------------------------------
        -- Switch von Low-Level auf Highspeed
        ---------------------------------------------------------------
        PROCEDURE SET_HIGH_PERFORMANCE(p_enabled IN BOOLEAN) IS
        BEGIN
            g_is_high_perf := p_enabled;
        END;
        
        ---------------------------------------------------------------
        -- Erkennung ob ein Prozess auf einem Server läuft
        ---------------------------------------------------------------
        -- Interne Prüfung
        FUNCTION is_remote(p_processId IN NUMBER) RETURN BOOLEAN IS
        BEGIN
            RETURN g_remote_sessions.EXISTS(p_processId);
        END is_remote;
    
        --------------------------------------------------------------------------
        -- Millis between two timestamps
        --------------------------------------------------------------------------
        function get_ms_diff(p_start timestamp, p_end timestamp) return number is
            v_diff interval day(0) to second(3); -- Präzision auf ms begrenzen
        begin
            v_diff := p_end - p_start;
            -- Wir extrahieren nur die Sekunden inklusive der Nachkommastellen (ms)
            -- und addieren die Minuten/Stunden/Tage als Sekunden-Vielfache
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
        -- Look for free Server-Pipe 
        --------------------------------------------------------------------------
        function getServerPipeForSession(p_processId number, p_groupName varchar2, p_initialize BOOLEAN default TRUE) return varchar2
        as
            l_serverPipe varchar2(50);
            l_key        BINARY_INTEGER;
        begin
            l_key := NVL(p_processId, C_PIPE_ID_PENDING);
            -- 1. Cache-Check (PGA)
            IF g_client_pipes.EXISTS(p_processId) THEN
                RETURN g_client_pipes(p_processId);
            END IF;
            
            l_serverPipe := getServerPipeAvailable(p_groupName);
            if l_serverPipe is null then 
                RAISE_APPLICATION_ERROR(-20004, 'LILAM: Kein aktiver Server gefunden.');
            end if;
            g_client_pipes(l_key) := l_serverPipe;
            return g_client_pipes(l_key);
    
        end;
        
        --------------------------------------------------------------------------
        -- Hilfsfunktion (intern): Erzeugt den einheitlichen Key für den Index
        --------------------------------------------------------------------------
        FUNCTION buildMonitorKey(p_processId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2) RETURN VARCHAR2 AS
        BEGIN
            -- Format: "0000000000000000180|MEINE_AKTION|MEIN_CONTEXT"
            -- LPAD sorgt für eine feste Länge, was das Filtern extrem beschleunigt
            RETURN LPAD(p_processId, 20, '0') || '|' || p_actionName || '|' || p_contextName;
        END;

        --------------------------------------------------------------------------
        -- Check if a single step needs more time than average over all steps per action
        --------------------------------------------------------------------------
        function validateDurationInAverage(p_monitor_rec t_monitor_buffer_rec, p_metricFactor number) return BOOLEAN
        as
            l_threshold_duration NUMBER;
        begin
            if p_monitor_rec.action_count > 5 THEN 
                
                l_threshold_duration := p_monitor_rec.avg_action_time * (1 + p_metricFactor / 100);            
                if p_monitor_rec.used_time > l_threshold_duration THEN
                    return FALSE;
                end if ;
            end if ;
            return TRUE;
        end;
         
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
        -- Alarmierung aber unter Berücksichtigung, dass Alarme nicht
        -- in kurzer Zeit zu häufig ausgelöst werden dürfen
        -- Hier: Events und Transaktionen
        ------------------------------------------------------------
        PROCEDURE fire_alert(p_rule t_rule_rec, p_rec t_monitor_buffer_rec) IS
            v_history_key   CONSTANT VARCHAR2(250) := p_rule.rule_id || '|' || p_rec.action_name || '|' || p_rec.context_name;
            v_idx_session   PLS_INTEGER;
            v_last_fire     TIMESTAMP;
            v_throttle_sec  NUMBER := nvl(p_rule.throttle_seconds, 0); -- Aus dem JSON
            v_channel_name  VARCHAR2(30); -- max. length of Alert-Name
            v_payload       VARCHAR2(1000);
            v_sqlStmt       VARCHAR2(2000);
            v_alert_id  NUMBER;
        BEGIN
            -- 1. Prüfen, ob wir dieses spezifische Problem schon mal gemeldet haben
            IF g_alert_history.EXISTS(v_history_key) THEN
                v_last_fire := g_alert_history(v_history_key);
                -- Wenn die Sperrzeit noch nicht abgelaufen ist -> Abbruch
                IF (v_last_fire + numtodsinterval(v_throttle_sec, 'SECOND')) > SYSTIMESTAMP THEN
dbms_output.put_line('... war schonmal gefeuert');                
                    RETURN; 
                END IF;
            END IF;
dbms_output.put_line('p_processId: ' || p_rec.process_id);

v_idx_session := v_indexSession(p_rec.process_id);            
dbms_output.put_line('v_procTabName: ' || g_sessionList(v_idx_session).tabName_master);
dbms_output.put_line('v_monTabName:  ' || g_sessionList(v_idx_session).tabName_master || C_SUFFIX_MON_TABLE);
            
            v_sqlStmt := '
            INSERT INTO ' || C_LILAM_ALERTS || '(
                process_id, process_name, action_name, master_table_name, monitor_table_name, context_name, action_count, 
                rule_id, rule_version, alert_severity, handler_type
            ) VALUES (
                :1, :2, :3, :4, :5, :6, :7, :8, :9, :10, :11
            ) RETURNING alert_id into :12';
            

dbms_output.put_line(p_rec.process_id || ', ' || g_process_cache(p_rec.process_id).process_name || ', ' || p_rec.action_name || ', ' || 
            g_sessionList(v_idx_session).tabName_master || ', ' || g_sessionList(v_idx_session).tabName_master || C_SUFFIX_MON_TABLE || ', ' ||  
            p_rec.context_name || ', ' || p_rec.action_count || ', ' || p_rule.rule_id || ', ' || g_current_rule_set_version || ', ' || 
            p_rule.alert_severity || ', ' || p_rule.alert_handler);
            
            EXECUTE IMMEDIATE v_sqlStmt
            USING p_rec.process_id, g_process_cache(p_rec.process_id).process_name, p_rec.action_name,
            g_sessionList(v_idx_session).tabName_master, g_sessionList(v_idx_session).tabName_master || C_SUFFIX_MON_TABLE, 
            p_rec.context_name, p_rec.action_count, p_rule.rule_id, g_current_rule_set_version, p_rule.alert_severity, p_rule.alert_handler
            RETURNING INTO v_alert_id;

            commit;
dbms_output.put_line('V_ALERT_ID: ' || v_alert_id);
            
            v_payload := JSON_OBJECT(
                'alert_id'         VALUE v_alert_id,
                'process_id'       VALUE p_rec.process_id,
                'tab_name_process' VALUE g_sessionList(v_idx_session).tabName_master,
                'tab_name_monitor' VALUE g_sessionList(v_idx_session).tabName_master || C_SUFFIX_MON_TABLE,
                'action_name'      VALUE p_rec.action_name,
                'context_name'     VALUE p_rec.context_name,
                'action_count'     VALUE p_rec.action_count,
                'rule_id'          VALUE p_rule.rule_id,
                'rule_version'     VALUE g_current_rule_set_version,
                'alert_severity'   VALUE p_rule.alert_severity,
                'timestamp'        VALUE TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF')
            );
            
dbms_output.put_line('v_payload: ' || v_payload);
            
            -- p_rule.alert_handler wäre hier z.B. 'MAIL', 'REST', 'PROCESS'
            v_channel_name := 'LILAM_ALERT_' || p_rule.alert_handler;            dbms_alert.signal(v_channel_name, v_payload);

            -- 3. Zeitstempel aktualisieren
            g_alert_history(v_history_key) := SYSTIMESTAMP;
        
        exception
            when others then
                error(g_serverProcessId, g_serverPipeName || '=>Alert konnte nicht ausgelöst werden: ' || sqlErrM);
        END;
        
        ------------------------------------------------------------
        -- Identifizieren von Regeln gegen eintreffendes Event/Trace        
        ------------------------------------------------------------      
        PROCEDURE evaluateRules(p_monitorRec t_monitor_buffer_rec, p_trigger VARCHAR2)
        as
            v_key varchar2(200);
            fire BOOLEAN := FALSE;
            l_diff_ms PLS_INTEGER := 0;
            
            -- Interne Hilfsprozedur, um Redundanz zu vermeiden
            PROCEDURE apply_rule_list(p_list t_rule_list) IS
            BEGIN
                IF p_list IS NULL OR p_list.COUNT = 0 THEN RETURN; END IF;
 dbms_output.enable();
 dbms_output.put_line('.................. trigger: ' || p_trigger || ', p_monitorRec.action_name: ' || p_monitorRec.action_name);
 
                FOR i IN 1 .. p_list.COUNT LOOP
                    fire := FALSE;
dbms_output.put_line(' p_list.trigger_type: ' || p_list(i).trigger_type);
dbms_output.put_line(' p_list.condition_operator: ' || p_list(i).condition_operator);
dbms_output.put_line(' p_list.condition_value: ' || p_list(i).condition_value);
                    -- Nur Regeln für das aktuelle Ereignis prüfen (z.B. TRACE_STOP)
                    IF p_list(i).trigger_type = p_trigger THEN
                    
dbms_output.put_line(' TREFFER ');
                        IF p_list(i).condition_operator IN ('ON_START', 'ON_STOP', 'ON_EVENT') THEN
dbms_output.put_line(' FIRE ');
                            fire := TRUE;
                            CONTINUE; -- Nächste Regel prüfen
                        END IF;
                        
                        CASE p_list(i).condition_operator
                            WHEN 'AVG_DEVIATION_PCT' THEN
                                if not validateDurationInAverage(p_monitorRec, p_list(i).condition_value) then
                                    fire := TRUE;
                                END IF;
        
                            WHEN 'MAX_DURATION_MS' THEN
                                -- Absoluter Schwellwert
dbms_output.put_line(' FIRE ');
dbms_output.put_line(' p_monitorRec.used_time: ' || p_monitorRec.used_time);
                                IF p_monitorRec.used_time > p_list(i).condition_value THEN
                                    fire := TRUE;
                                END IF;
                        
                            WHEN 'MAX_OCCURRENCE' THEN
                                -- Feuert, wenn die Anzahl der Aufrufe überschritten wird
                                IF p_monitorRec.action_count > p_list(i).condition_value THEN
                                    fire := TRUE;
                                END IF;
                                
                                                                
                            WHEN 'MAX_GAP_SECONDS' THEN
                                v_key := buildMonitorKey(p_monitorRec.process_id, p_monitorRec.action_name, p_monitorRec.context_name);
                                IF g_monitor_shadows.EXISTS(v_key) THEN
                                    DECLARE
                                        -- Wir holen den Referenzzeitpunkt des Vorgängers
                                        -- Falls stop_time NULL ist (wie bei deinen Events), nutzen wir die start_time
                                        l_vorganger_zeit TIMESTAMP := nvl(g_monitor_shadows(v_key).stop_time, g_monitor_shadows(v_key).start_time);
                                    BEGIN
                                        -- Lücke = Vom (Ende-)Zeitpunkt des Vorgängers bis zum Start von JETZT
                                        l_diff_ms := get_ms_diff(l_vorganger_zeit, p_monitorRec.start_time);
                                        
                                        IF (l_diff_ms / 1000) > TO_NUMBER(p_list(i).condition_value) THEN
                                            fire := TRUE;
                                        END IF;
                                    END;
                                END IF;
                            
                        END CASE;
                    END IF;
                    
                    if fire then
                        fire_alert(p_list(i), p_monitorRec);
                    end if;
                END LOOP;
            END;
        
        BEGIN
            -- 1. Spezifische Kontext-Regeln prüfen (Key: Action|Context)
            IF g_rules_by_context.EXISTS(p_monitorRec.action_name || '|' || p_monitorRec.context_name) THEN
                apply_rule_list(g_rules_by_context(p_monitorRec.action_name || '|' || p_monitorRec.context_name));
            END IF;
        
            -- 2. Allgemeine Action-Regeln prüfen (Key: Action)
            IF g_rules_by_action.EXISTS(p_monitorRec.action_name) THEN
                apply_rule_list(g_rules_by_action(p_monitorRec.action_name));
            END IF;
        END;

        
        ---------------------------------------------------------------
        -- Identifizieren von Regeln gegen eintreffendes Prozess-Update
        -- Trigger z.B. PROCESS_START
        ---------------------------------------------------------------
        PROCEDURE evaluateRules(p_processRec t_process_rec, p_trigger VARCHAR2)
        as
            fire BOOLEAN := FALSE;
            p_monRec t_monitor_buffer_rec; -- helper to avoid double fire_alert code
            
            -- Interne Hilfsprozedur, um Redundanz zu vermeiden
            PROCEDURE apply_rule_list(p_list t_rule_list) IS
            BEGIN
                IF p_list IS NULL OR p_list.COUNT = 0 THEN RETURN; END IF;
        
                FOR i IN 1 .. p_list.COUNT LOOP
                    fire := FALSE;
                    
                    -- Nur Regeln für das aktuelle Ereignis prüfen (z.B. TRACE_STOP)
                    IF p_list(i).trigger_type = p_trigger THEN
                    
                        IF p_list(i).condition_operator IN ('ON_START', 'ON_STOP', 'ON_UPDATE', 'ON_EVENT') THEN
                            fire := TRUE;
                            CONTINUE; -- Nächste Regel prüfen
                        END IF;
                        
                        CASE p_list(i).condition_operator
                            WHEN 'RUNTIME_EXCEEDED' THEN
                                if p_processRec.process_end is null and 
                                    get_ms_diff(nvl(p_processRec.last_update, systimestamp), systimestamp) >  to_number(p_list(i).condition_value)
                                then
                                    fire := TRUE;
                                end if;
        
                            WHEN 'MAX_RUNTIME_EXCEEDED' THEN
                                if p_processRec.process_end is not null and
                                    get_ms_diff(p_processRec.process_start, p_processRec.process_end) >  to_number(p_list(i).condition_value)
                                then
                                    fire := TRUE;
                                end if;
        
                            WHEN 'STEPS_LEFT_HIGH' THEN
                                if p_processRec.proc_steps_todo - p_processRec.proc_steps_done > (p_list(i).condition_value) then
                                    fire := TRUE;
                                end if;                                
        
                            WHEN 'SUCCESS_RATE_LOW' THEN
                                if nvl(p_processRec.proc_steps_todo, 0) > 0 and (
                                    p_processRec.proc_steps_done / p_processRec.proc_steps_todo * 100 < to_number(p_list(i).condition_value)
                                ) then
                                    fire := TRUE;
                                end if; 
                                
                            WHEN 'MAX_OCCURRENCE' THEN
                                if p_processRec.proc_steps_todo - p_processRec.proc_steps_done > (p_list(i).condition_value) then
                                    fire := TRUE;
                                end if;                                
                            
                            WHEN 'STATUS_EQUALS' THEN
                                if nvl(p_processRec.status, -1) = to_number(p_list(i).condition_value) then
                                    fire := TRUE;
                                end if; 
                                
                            WHEN 'INFO_CONTAINS' THEN
                                if p_processRec.info is not null and
                                    UPPER(p_processRec.info) LIKE '%' || UPPER(p_list(i).condition_value) || '%' then
                                    fire := TRUE;
                                end if;                                     
                        END CASE;
                    END IF;
                    
                    if fire then
                        p_monRec.process_id := p_processRec.id;
                        p_monRec.action_name := p_processRec.process_name;
                        p_monRec.context_name := null;
                        p_monRec.action_count := p_processRec.proc_steps_done;
                        fire_alert(p_list(i), p_monRec);
                    end if;
                        
                END LOOP;
            END;
        
        BEGIN
            -- Prozesse kennen keinen Kontext (Key: Action)
            IF g_rules_by_action.EXISTS(p_processRec.process_name) THEN
                apply_rule_list(g_rules_by_action(p_processRec.process_name));
            END IF;
        END;

        --------------------------------------------------------------------------
        -- Avoid throttling 
        --------------------------------------------------------------------------
        function waitForResponse(
            p_processId   in number,
            p_request       in varchar2, -- Wird für die Zuordnung/Verzweigung im Server benötigt
            p_payload       IN varchar2, 
            p_timeoutSec    IN PLS_INTEGER,
            p_pipeName   in varchar2 default null
        ) return varchar2
        as
            l_msgSend       VARCHAR2(4000);
            l_msgReceive    VARCHAR2(4000);
            l_status        PLS_INTEGER;
            l_statusReceive PLS_INTEGER;
            l_clientChannel varchar2(50);
            l_header        varchar2(200);
            l_meta          varchar2(200);
            l_data          varchar2(1500);
            l_groupName     varchar2(50);
            l_serverPipe    varchar2(100);
            l_slotIdx PLS_INTEGER;
        begin
            l_clientChannel := getClientPipe;
            l_groupName := extractFromJsonStr(p_payload, 'group_name');

            l_header := '"header":{"msg_type":"API_CALL", "request":"' || p_request || '", "response":"' || l_clientChannel ||'"}';
            l_meta  := '"meta":{"param":"value"}';
            l_data  := '"payload":' || p_payLoad;
            l_msgSend := '{' || l_header || ', ' || l_meta || ', ' || l_data || '}';
            l_serverPipe := getServerPipeForSession(p_processId, l_groupName);
            
            DBMS_PIPE.PACK_MESSAGE(l_msgSend);
            l_status := DBMS_PIPE.SEND_MESSAGE(l_serverPipe, timeout => 3);
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
    raise;
                l_status := DBMS_PIPE.REMOVE_PIPE(l_clientChannel);
        end;
        
        ---------------------------------------------------------------
        -- Aktive Server markieren
        ---------------------------------------------------------------
        function isServerPipeActive(p_pipeName varchar2) return boolean
        as
            l_counter PLS_INTEGER;
            l_sqlStmt varchar2(200);
        begin
            l_sqlStmt := 'SELECT count(*) FROM ' || C_LILAM_SERVER_REGISTRY || ' WHERE is_active = 1 and pipe_name = :1';
            execute immediate l_sqlStmt into l_counter using p_pipeName;
            if l_counter >= 1 then return TRUE; end if;
            if l_counter = 0  then return FALSE; end if;
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
              AND last_activity > SYSTIMESTAMP - INTERVAL ''5'' SECOND ';
              
            if p_groupName is not null then
                l_sqlStmt := l_sqlStmt || ' AND upper(group_name) = ''' || upper(p_groupName) || '''';
            end if;
            
            l_sqlStmt := l_sqlStmt || '
            ORDER BY current_load ASC, last_activity DESC 
            FETCH FIRST 1 ROW ONLY';

            execute immediate l_sqlStmt into l_serverPipeName;
            return l_serverPipeName;
            
        exception
            when NO_DATA_FOUND then
                return null;
            when others then
                raise;
        end;
    
        ---------------------------------------------------------------
    
        procedure send_sync_signal(p_processId number)
        as
            l_response varchar2(1000);
        begin
            l_response := waitForResponse(p_processId, 'UNFREEZE_REQUEST', '{}', 10);
    
        exception
            when others then
                raise;
        end;
        
        --------------------------------------------------------------------------
        -- Auf die Bremse treten, wenn Client zu schnell sendet
        --------------------------------------------------------------------------
        PROCEDURE stabilizeInLowPerfEnvironments(p_processId number)
        IS
            l_now TIMESTAMP := SYSTIMESTAMP;
            l_diff_millis PLS_INTEGER;
        BEGIN
            if NOT g_is_high_perf THEN 
                -- In nicht hochperformanten Umgebungen den Client etwas einbremsen
                if NOT g_local_throttle_cache.EXISTS(p_processId) THEN
                    g_local_throttle_cache(p_processId).msg_count := 0;
                    g_local_throttle_cache(p_processId).last_check := l_now;
                end if ;
            
                -- Counter hochzählen
                g_local_throttle_cache(p_processId).msg_count := g_local_throttle_cache(p_processId).msg_count + 1;
            
                -- Check-Intervall erreicht?
                if g_local_throttle_cache(p_processId).msg_count >= C_THROTTLE_LIMIT THEN        
                    -- Wenn zu schnell gefeuert wurde
                    if get_ms_diff(g_local_throttle_cache(p_processId).last_check, l_now) < C_THROTTLE_INTERVAL THEN
                        -- Erzwinge Synchronisation (Warten auf Server-Antwort)
                        -- Das verschafft dem Remote-Server die nötige "Atempause"
                        send_sync_signal(p_processId);
                    end if ;
            
                    -- Reset für das nächste Fenster
                    g_local_throttle_cache(p_processId).msg_count := 0;
                    g_local_throttle_cache(p_processId).last_check := l_now;
                end if ;
            end if ;
        END;
    
        --------------------------------------------------------------------------
        -- Nachricht an Server Fire&Forget
        --------------------------------------------------------------------------
        procedure sendNoWait(
            p_processId     in number,
            p_request       in varchar2, -- Wird für die Zuordnung/Verzweigung im Server benötigt
            p_payload       IN varchar2, 
            p_timeoutSec    IN PLS_INTEGER
        )
        as        
            l_pipeName  VARCHAR2(100);
            l_msg       VARCHAR2(1800);
            l_header    varchar2(140);
            l_meta      varchar2(140);
            l_data      varchar2(1500);
            l_status    PLS_INTEGER;
            l_now           TIMESTAMP := SYSTIMESTAMP;
            l_retryInterval INTERVAL DAY TO SECOND := INTERVAL '30' SECOND;
        begin
            stabilizeInLowPerfEnvironments(p_processId);

            
            l_header := '"header":{"msg_type":"API_CALL", "request":"' || p_request || '"}';
            l_data  := '"payload":' || p_payLoad;
            l_meta  := '"meta":{"param":"value"}';

            l_msg := '{' || l_header || ', ' || l_meta || ', ' || l_data || '}';
            l_pipeName := getServerPipeForSession(p_processId, null);
            DBMS_PIPE.PACK_MESSAGE(l_msg);
            for i in 1 .. 3 loop
                l_status := DBMS_PIPE.SEND_MESSAGE(l_pipeName, timeout => p_timeoutSec);
                if l_status = 0 THEN
                    exit;
                end if ;
                if l_status = 2 then
                    DBMS_PIPE.RESET_BUFFER;
                    DBMS_PIPE.PACK_MESSAGE(l_msg);
                end if;
                dbms_session.sleep(0.3);
            end loop;
            
            if l_status != 0 and p_processId != g_serverProcessId then
                -- ich bin ein Client und kann keine Nachricht in die Pipe schreiben
                -- Neuanmeldung an alternativem Server
                DBMS_PIPE.RESET_BUFFER;
                RAISE_APPLICATION_ERROR(-20006, 'LILAM: Client kann keine Nachrichten an Server senden:  ' || sqlErrM);
            end if;
                        
        exception
            when others then
                raise;
        end;
            
        --------------------------------------------------------------------------    
        -- global exception handling
        function should_raise_error(p_processId number) return boolean
        as
        begin
            -- Die Logik ist hier zentral gekapselt
            if p_processId is not null and v_indexSession.EXISTS(p_processId) 
               and g_sessionList(v_indexSession(p_processId)).log_level >= logLevelDebug 
            then
                return true;
            end if ;
            return false;
        exception
            when others then return false; -- Sicherheit geht vor
        end;  
        
        --------------------------------------------------------------------------
    
        -- run execute immediate with exception handling
        procedure run_sql(p_sqlStmt varchar2)
        as
        begin
            execute immediate p_sqlStmt;
            
        exception
            when OTHERS then
        raise;
     --           null;
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
        end;
    
        --------------------------------------------------------------------------
    
        function replaceNameDetailTable(p_sqlStatement varchar2, p_placeHolder varchar2, p_tableSuffix varchar2, p_tableName varchar2) return varchar2
        as
        begin
            return replace(p_sqlStatement, p_placeHolder, p_tableName || p_tableSuffix);
        end;
        
        --------------------------------------------------------------------------
    
        function replaceNameMasterTable(p_sqlStatement varchar2, p_placeHolder varchar2, p_tableName varchar2) return varchar2
        as
        begin
            return replace(p_sqlStatement, p_placeHolder, p_tableName);
        end;
        
        --------------------------------------------------------------------------
    
        -- Creates LOG tables and the sequence for the process IDs if tables or sequence don't exist
        -- For naming rules of the tables see package description
        procedure createLogTables(p_TabNameMaster varchar2)
        as
            sqlStmt varchar2(4000);
        begin
            if not objectExists('SEQ_LILAM_LOG', 'SEQUENCE') then
                sqlStmt := 'CREATE SEQUENCE SEQ_LILAM_LOG MINVALUE 0 MAXVALUE 9999999999999999999999999999 INCREMENT BY 1 START WITH 1 CACHE 10 NOORDER  NOCYCLE  NOKEEP  NOSCALE  GLOBAL';
                execute immediate sqlStmt;
            end if ;
                    
            if not objectExists(p_TabNameMaster, 'TABLE') then
                -- Master table
                sqlStmt := '
                create table PH_MASTER_TABLE ( 
                    id               NUMBER(19,0),
                    process_name     VARCHAR2(100),
                    log_level        NUMBER,
                    process_start    TIMESTAMP(6),
                    process_end      TIMESTAMP(6),
                    last_update      TIMESTAMP(6),
                    proc_steps_todo  NUMBER,
                    proc_steps_done  NUMBER,
                    status           NUMBER(2,0),
                    info             VARCHAR2(2000),
                    process_immortal NUMBER(1,0) DEFAULT 0,
                    tab_name_master  VARCHAR2(100)
                )';
                sqlStmt := replaceNameMasterTable(sqlStmt, C_PARAM_MASTER_TABLE, p_TabNameMaster);
                run_sql(sqlStmt);
            end if ;
    
            if not objectExists(p_TabNameMaster || C_SUFFIX_LOG_TABLE, 'TABLE') then
                -- Details table
                sqlStmt := '
                create table PH_LOG_TABLE (
                    "PROCESS_ID"        number(19,0),
                    "NO"                number(19,0),
                    "INFO"              varchar2(2000),
                    "LOG_LEVEL"         varchar2(10),
                    "SESSION_TIME"      timestamp  DEFAULT SYSTIMESTAMP,
                    "SESSION_USER"      varchar2(50),
                    "HOST_NAME"         varchar2(50),
                    "ERR_STACK"         varchar2(4000),
                    "ERR_BACKTRACE"     varchar2(4000),
                    "ERR_CALLSTACK"     varchar2(4000)
                )';
                sqlStmt := replaceNameDetailTable(sqlStmt, C_PARAM_LOG_TABLE, C_SUFFIX_LOG_TABLE, p_TabNameMaster);
                run_sql(sqlStmt);
            end if ;
    
            if not objectExists(p_TabNameMaster || C_SUFFIX_MON_TABLE, 'TABLE') then
                -- Details table
                sqlStmt := '
                create table PH_MON_TABLE (
                    "PROCESS_ID"    number(19,0),
                    "MON_TYPE"      number DEFAULT 0,
                    "START_TIME"    timestamp  DEFAULT SYSTIMESTAMP,
                    "STOP_TIME"     timestamp,
                    "SESSION_USER"  varchar2(50),
                    "HOST_NAME"     varchar2(50),
                    "ACTION"        VARCHAR2(100),
                    "CONTEXT"  VARCHAR2(100),
                    "USED_MILLIS"   NUMBER(19,0), -- Millis als Zahl für einfache Auswertung
                    "AVG_MILLIS"    NUMBER(19,0),
                    "ACTION_COUNT"    NUMBER(19,0)
                )';
                sqlStmt := replaceNameDetailTable(sqlStmt, C_PARAM_MON_TABLE, C_SUFFIX_MON_TABLE, p_TabNameMaster);
                run_sql(sqlStmt);
            end if ;
    
            if not objectExists(C_LILAM_SERVER_REGISTRY, 'TABLE') then
                sqlStmt := '
                CREATE TABLE ' || C_LILAM_SERVER_REGISTRY || ' (
                    pipe_name      VARCHAR2(50) PRIMARY KEY,
                    group_name     VARCHAR2(50),
                    last_activity  TIMESTAMP,
                    current_load   NUMBER,
                    is_active      NUMBER(1),
                    status         VARCHAR2(20),
                    processing     NUMBER,
                    rule_set_name  VARCHAR2(30),
                    set_in_use     NUMBER DEFAULT 0
                )';
                run_sql(sqlStmt);
            end if;
            
            if not objectExists(C_LILAM_RULES, 'TABLE') then
                sqlStmt := '
                CREATE TABLE ' || C_LILAM_RULES || ' (
                    rule_set       CLOB CONSTRAINT ensure_json_rules CHECK (rule_set IS JSON),
                    set_name       VARCHAR2(30),
                    version        NUMBER,
                    created        TIMESTAMP,
                    author         VARCHAR2(50)
                )';
                run_sql(sqlStmt);
            end if;
            

            if not objectExists(C_LILAM_ALERTS, 'TABLE') then
                sqlStmt := '
                CREATE TABLE ' || C_LILAM_ALERTS || ' (
                    alert_id           NUMBER GENERATED BY DEFAULT AS IDENTITY,
                    process_id         NUMBER(19,0) NOT NULL,
                    process_name       VARCHAR2(50),
                    master_table_name  VARCHAR2(50), 
                    monitor_table_name VARCHAR2(50), 
                    action_name        VARCHAR2(100) NOT NULL,
                    context_name       VARCHAR2(100),
                    action_count       NUMBER NOT NULL,
                    rule_id            VARCHAR2(20) NOT NULL,
                    rule_version       NUMBER NOT NULL,
                    alert_severity     VARCHAR2(20),
                    handler_type       VARCHAR2(20),              
                    status             VARCHAR2(20) DEFAULT ''PENDING'',
                    error_message      CLOB,
                    created_at         TIMESTAMP DEFAULT SYSTIMESTAMP,
                    processed_at       TIMESTAMP,
                    
                    CONSTRAINT pk_lila_alerts PRIMARY KEY (alert_id)
                )';
                run_sql(sqlStmt);
            end if;
            
            if not objectExists('idx_lilam_main_id', 'INDEX') then
                sqlStmt := '
                CREATE INDEX idx_lilam_main_id
                ON PH_MASTER_TABLE (id)';
                sqlStmt := replaceNameMasterTable(sqlStmt, C_PARAM_MASTER_TABLE, p_TabNameMaster);
                run_sql(sqlStmt);
            end if ;
    
            if not objectExists('idx_lilam_LOG_master', 'INDEX') then
                sqlStmt := '
                CREATE INDEX idx_lilam_LOG_master
                ON PH_LOG_TABLE (process_id)';
                sqlStmt := replaceNameDetailTable(sqlStmt, C_PARAM_LOG_TABLE, C_SUFFIX_LOG_TABLE, p_TabNameMaster);
                run_sql(sqlStmt);
            end if ;
    
            if not objectExists('idx_lilam_mon_master', 'INDEX') then
                sqlStmt := '
                CREATE INDEX idx_lilam_mon_master
                ON PH_MON_TABLE (process_id)';
                sqlStmt := replaceNameDetailTable(sqlStmt, C_PARAM_MON_TABLE, C_SUFFIX_MON_TABLE, p_TabNameMaster);
                run_sql(sqlStmt);
            end if ;
    
            if not objectExists('idx_lilam_LOG_info', 'INDEX') then
                sqlStmt := '
                CREATE INDEX idx_lilam_LOG_info
                ON PH_LOG_TABLE (info)';
                sqlStmt := replaceNameDetailTable(sqlStmt, C_PARAM_LOG_TABLE, C_SUFFIX_LOG_TABLE, p_TabNameMaster);
                run_sql(sqlStmt);
            end if ;
    
           if not objectExists('idx_lilam_cleanup', 'INDEX') then
                sqlStmt := '
                CREATE INDEX idx_lilam_cleanup 
                ON PH_MASTER_TABLE (process_name, process_end)';
                sqlStmt := replaceNameMasterTable(sqlStmt, C_PARAM_MASTER_TABLE, p_TabNameMaster);
                run_sql(sqlStmt);
            end if ;
    
           if not objectExists('idx_lilam_registry_group', 'INDEX') then
                sqlStmt := '
                CREATE INDEX idx_lilam_registry_group 
                ON C_LILAM_SERVER_REGISTRY (group_name, is_active, current_load)';
                sqlStmt := replace(sqlStmt, 'C_LILAM_SERVER_REGISTRY', C_LILAM_SERVER_REGISTRY);
                run_sql(sqlStmt);
            end if ;
    
        exception      
            when others then
                -- creating log files mustn't fail
                RAISE;
         end;
         
        --------------------------------------------------------------------------
        -- Kills log entries depending to their age in days and process name.
        -- Matching of process name is not case sensitive
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
    
            -- find out process IDs
            sqlStatement := '
            select id from PH_MASTER_TABLE
            where process_end <= sysdate - :PH_DAYS_TO_KEEP
            and upper(process_name) = upper(:PH_PROCESS_NAME)
            and process_immortal = 0';
            
            sessionRec := getSessionRecord(p_processId);
            if sessionRec.process_id is null then
                return; 
            end if ;
            
            sqlStatement := replaceNameMasterTable(sqlStatement, C_PARAM_MASTER_TABLE, sessionRec.tabName_master);
    
            -- for all process IDs
            open t_rc for sqlStatement using p_daysToKeep, p_processName;
            loop
                fetch t_rc into processIdToDelete;
                EXIT WHEN t_rc%NOTFOUND;
                
                -- delete Logs and Monitor-entries first (integrity)
                sqlStatement := 'delete from PH_LOG_TABLE where process_id = :1';
                sqlStatement := replaceNameDetailTable(sqlStatement, C_PARAM_LOG_TABLE, C_SUFFIX_LOG_TABLE, sessionRec.tabName_master);
                execute immediate sqlStatement USING processIdToDelete;
        
                sqlStatement := 'delete from PH_MON_TABLE where process_id = :1';
                sqlStatement := replaceNameDetailTable(sqlStatement, C_PARAM_MON_TABLE, C_SUFFIX_MON_TABLE, sessionRec.tabName_master);
                execute immediate sqlStatement USING processIdToDelete;
        
                -- delete master
                sqlStatement := 'delete from PH_MASTER_TABLE where id = :1';
                sqlStatement := replaceNameMasterTable(sqlStatement, C_PARAM_MASTER_TABLE, sessionRec.tabName_master);
                execute immediate sqlStatement USING processIdToDelete;
            end loop;
            close t_rc;
            commit;
    
        exception
            when others then
                if t_rc%isopen then 
                    close t_rc;
                end if ;
                rollback; -- Auch im Fehlerfall die Transaktion beenden
                if should_raise_error(p_processId) then
                    RAISE;
                end if ;
        end;
        
        --------------------------------------------------------------------------
        
        function getProcessRecord(p_processId number) return t_process_rec
        as
        begin
            if g_process_cache(p_processId).id is not null then
                return g_process_cache(p_processId);
            else
                return null;
            end if ;
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
                proc_steps_todo,
                proc_steps_done,
                status,
                info,
                process_immortal,
                tab_name_master
            from PH_MASTER_TABLE
            where id = :PH_PROCESS_ID';
            
            sessionRec := getSessionRecord(p_processId);
            if sessionRec.process_id is not null then
                sqlStatement := replaceNameMasterTable(sqlStatement, C_PARAM_MASTER_TABLE, sessionRec.tabName_master);
                execute immediate sqlStatement into processRec USING p_processId;
            end if ;
            return processRec;
            
        exception
            when others then
                if should_raise_error(p_processId) then
                    RAISE;
                else
                    return null;
                end if ;
        end;
            
        --------------------------------------------------------------------------
        -- Flush monitor data to detail table
        --------------------------------------------------------------------------
        procedure persist_log_data(
            p_processId    number,
            p_target_table varchar2,
            p_seqs         sys.odcinumberlist,
            p_levels       sys.odcinumberlist,
            p_texts        sys.odcivarchar2list,
            p_times        sys.odcidatelist,
            p_stacks       sys.odcivarchar2list,
            p_backtraces   sys.odcivarchar2list,
            p_callstacks   sys.odcivarchar2list
        )    
        as
            pragma autonomous_transaction;
        begin
            -- Bulk-Insert über alle gesammelten Log-Einträge
            forall i in 1 .. p_levels.count
                execute immediate 
                    'insert into ' || p_target_table || ' 
                    (PROCESS_ID, LOG_LEVEL, INFO, SESSION_TIME, NO, ERR_STACK, ERR_BACKTRACE, ERR_CALLSTACK, SESSION_USER, HOST_NAME)
                    values (:1, :2, :3, :4, :5, :6, :7, :8, :9, :10)'
                USING p_processId, p_levels(i), p_texts(i), p_times(i), p_seqs(i), p_stacks(i), p_backtraces(i), p_callstacks(i),
                SYS_CONTEXT('USERENV','SESSION_USER'), SYS_CONTEXT('USERENV','HOST');
            commit;
            
        exception
            when others then
                rollback;
                if should_raise_error(p_processId) then
                    raise;
                end if ;
    
        end;
        
        --------------------------------------------------------------------------
        
        -- initilizes writing to table
        -- decouples internal memory from autonomous transaction
        procedure flushLogs(p_processId number)
        as
            v_key          constant varchar2(100) := to_char(p_processId);
            v_targetTable  varchar2(150);
            v_idx_session  pls_integer;
            
            -- Bulk-Listen für den Datentransfer (Schema-Level Typen)
            v_levels       sys.odcinumberlist   := sys.odcinumberlist();
            v_texts        sys.odcivarchar2list := sys.odcivarchar2list();
            v_times        sys.odcidatelist     := sys.odcidatelist();
            v_seqs         sys.odcinumberlist   := sys.odcinumberlist();
            v_stacks       sys.odcivarchar2list := sys.odcivarchar2list();
            v_backtraces   sys.odcivarchar2list := sys.odcivarchar2list();
            v_callstacks   sys.odcivarchar2list := sys.odcivarchar2list();
        begin
            -- 1. Prüfen, ob Daten für diesen Prozess im Cache sind
            if not g_log_groups.EXISTS(v_key) or g_log_groups(v_key).COUNT = 0 then
                return;
            end if ;
            -- 2. Ziel-Tabelle aus der Session-Liste ermitteln
            v_idx_session := v_indexSession(p_processId);
            v_targetTable := g_sessionList(v_idx_session).tabName_master || C_SUFFIX_LOG_TABLE;
        
            -- 3. Daten aus der hierarchischen Map in flache Listen sammeln
            for i in 1 .. g_log_groups(v_key).COUNT loop
                v_levels.EXTEND;     v_levels(v_levels.LAST)     := g_log_groups(v_key)(i).log_level;
                v_texts.EXTEND;      v_texts(v_texts.LAST)       := substrb(g_log_groups(v_key)(i).log_text, 1, 4000);
                v_times.EXTEND;      v_times(v_times.LAST)       := cast(g_log_groups(v_key)(i).log_time as date);
                v_seqs.EXTEND;       v_seqs(v_seqs.LAST)         := g_log_groups(v_key)(i).serial_no;
                
                -- Error-Stacks (begrenzt auf 4000 Byte für sys.odcivarchar2list)
                v_stacks.EXTEND;     v_stacks(v_stacks.LAST)     := substrb(g_log_groups(v_key)(i).err_stack, 1, 4000);
                v_backtraces.EXTEND; v_backtraces(v_backtraces.LAST) := substrb(g_log_groups(v_key)(i).err_backtrace, 1, 4000);
                v_callstacks.EXTEND; v_callstacks(v_callstacks.LAST) := substrb(g_log_groups(v_key)(i).err_callstack, 1, 4000);
            end loop;
            
            -- 4. Übergabe an die autonome Bulk-Persistierung
            persist_log_data(
                p_processId    => p_processId,
                p_target_table => v_targetTable,
                p_levels       => v_levels,
                p_texts        => v_texts,
                p_times        => v_times,
                p_seqs         => v_seqs,
                p_stacks       => v_stacks,
                p_backtraces   => v_backtraces,
                p_callstacks   => v_callstacks
            );
        
            -- 5. Cache für diesen Prozess leeren
            g_log_groups(v_key).DELETE;
        
        exception
            when others then
                -- Zentrale Fehlerbehandlung nutzen
                if should_raise_error(p_processId) then
                    raise;
                end if ;
        end;
        
        --------------------------------------------------------------------------
        
        procedure write_to_log_buffer(
            p_processId number, 
            p_level number,
            p_text varchar2,
            p_errStack varchar2,
            p_errBacktrace varchar2,
            p_errCallstack varchar2
        ) 
        is
            v_idx PLS_INTEGER;
            v_key varchar2(100) := to_char(p_processId);
            v_new_log t_log_buffer_rec;
        begin
            v_idx := v_indexSession(p_processId);
            g_sessionList(v_idx).serial_no := nvl(g_sessionList(v_idx).serial_no, 0) + 1;
            v_new_log.serial_no := g_sessionList(v_idx).serial_no;
        
            -- 1. Gruppe initialisieren
            if not g_log_groups.EXISTS(v_key) then
                g_log_groups(v_key) := t_log_history_tab();
            end if ;
        
            -- 2. Record befüllen
            v_new_log.process_id    := p_processId; -- Jetzt vorhanden
            v_new_log.log_level     := p_level;
            v_new_log.log_text      := p_text;
            v_new_log.log_time      := systimestamp;
            v_new_log.serial_no     := g_sessionList(v_indexSession(p_processId)).serial_no;
            v_new_log.err_stack     := p_errStack;
            v_new_log.err_backtrace := p_errBacktrace;
            v_new_log.err_callstack := p_errCallstack;
    
            -- 3. In den Cache hängen
            g_log_groups(v_key).EXTEND;
            g_log_groups(v_key)(g_log_groups(v_key).LAST) := v_new_log;
            
            g_sessionList(v_idx).log_dirty_count := nvl(g_sessionList(v_idx).log_dirty_count, 0) + 1;
            -- ID in die Dirty-Queue werfen
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
            p_contexts      sys.odcivarchar2list,
            p_mon_types    sys.odcinumberlist,
            p_action_count   sys.odcinumberlist,
            p_used         sys.odcinumberlist,
            p_avgs         sys.odcinumberlist,
            p_timesStart        sys.odcidatelist,
            p_timesStop        sys.odcidatelist
        )
        as
            pragma autonomous_transaction;
            v_user varchar2(128) := SYS_CONTEXT('USERENV','SESSION_USER');
            v_host varchar2(128) := SYS_CONTEXT('USERENV','HOST');
            v_safe_table varchar2(150);
        begin
            if p_actions.count > 0 then
                -- Sicherheit: Tabellenname validieren
                v_safe_table := DBMS_ASSERT.SQL_OBJECT_NAME(p_target_table);
        
                forall i in 1 .. p_actions.count SAVE EXCEPTIONS
                    execute immediate
                    'insert into ' || v_safe_table || ' 
                    (PROCESS_ID, ACTION, CONTEXT, MON_TYPE, ACTION_COUNT, USED_MILLIS, AVG_MILLIS, START_TIME, STOP_TIME, SESSION_USER, HOST_NAME)
                    values (:1, :2, :3, :4, :5, :6, :7, :8, :9, :10, :11)'
                    using p_processId, p_actions(i), p_contexts(i), p_mon_types(i), p_action_count(i), p_used(i), p_avgs(i), p_timesStart(i),
                          p_timesStop(i), v_user, v_host;
                
                commit;
            end if ;
        exception
            when others then
                rollback;
                -- Fehler-Logging hier sinnvoll, da autonome Transaktion den Fehler sonst "verschluckt"
--                if should_raise_error(p_processId) then
                    raise;
--                end if ;
        end;
        
        --------------------------------------------------------------------
        -- Alle Dirty Einträge für alle Sessions wegschreiben
        --------------------------------------------------------------------
        PROCEDURE SYNC_ALL_DIRTY(p_force BOOLEAN DEFAULT FALSE, p_isShutdown BOOLEAN DEFAULT FALSE) 
        IS
            v_id      BINARY_INTEGER;
            v_next_id BINARY_INTEGER;
            v_idx     PLS_INTEGER;
        BEGIN
            -- ======================================================================
            -- TEIL 1: BEARBEITUNG DER DRECKIGEN LISTE (Queue)
            -- ======================================================================
            v_id := g_dirty_queue.FIRST;
            
            WHILE v_id IS NOT NULL LOOP
                v_next_id := g_dirty_queue.NEXT(v_id);
                
                if v_indexSession.EXISTS(v_id) THEN
                    v_idx := v_indexSession(v_id);
        
                    -- Zeitstempel-Check (Cooldown-Logik)
                    -- Bei Force oder Shutdown ignorieren wir die Wartezeit
                    if NOT p_force AND NOT p_isShutdown
                       AND g_sessionList(v_idx).last_sync_check IS NOT NULL 
                       AND (SYSTIMESTAMP - g_sessionList(v_idx).last_sync_check) < INTERVAL '1' SECOND 
                    THEN
                        NULL; 
                    ELSE
                        -- Synchronisation (p_isShutdown wird durchgereicht)
                        sync_log(v_id, p_force);
                        sync_monitor(v_id, p_force);
                        sync_process(v_id, p_force);
                        g_sessionList(v_idx).last_sync_check := SYSTIMESTAMP;
                        
                        -- Überprüfung: Ist die Session jetzt "sauber"?
                        if p_force OR p_isShutdown OR (
                               nvl(g_sessionList(v_idx).log_dirty_count, 0) = 0 
                           AND nvl(g_sessionList(v_idx).monitor_dirty_count, 0) = 0
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
        
            -- ======================================================================
            -- TEIL 2: MASTER-CLEANUP BEI SHUTDOWN
            -- Hier räumen wir die RAM-Reste (Round-Robin) aller bekannten Sessions weg
            -- ======================================================================
            if p_isShutdown THEN
                v_id := v_indexSession.FIRST;
                WHILE v_id IS NOT NULL LOOP
                    -- flushMonitor direkt aufrufen, um is_flushed=1 Einträge zu löschen.
                    -- Da p_isShutdown = TRUE, greift dort g_monitor_groups.DELETE(v_key).
                    flushMonitor(v_id);
                    
                    v_id := v_indexSession.NEXT(v_id);
                END LOOP;
            end if ;
    
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
            v_mon_types   sys.odcinumberlist  := sys.odcinumberlist();
            v_action_count  sys.odcinumberlist   := sys.odcinumberlist();
            v_used        sys.odcinumberlist   := sys.odcinumberlist();
            v_avgs        sys.odcinumberlist   := sys.odcinumberlist();
            v_timesStart  sys.odcidatelist     := sys.odcidatelist();
            v_timesStop   sys.odcidatelist     := sys.odcidatelist();
        begin
            v_idx_session := v_indexSession(p_processId);
            v_targetTable := g_sessionList(v_idx_session).tabName_master || C_SUFFIX_MON_TABLE;
        
            v_group_key := g_monitor_groups.FIRST;
            while v_group_key is not null loop     
                -- Filter: Gehört dieser "Eimer" zum aktuellen Prozess?
               if v_group_key like v_id_prefix || '%' then  
                    -- 1. Alles einsammeln, was aktuell im Eimer ist
                        for i in 1 .. g_monitor_groups(v_group_key).COUNT loop
                            v_actions.extend;    v_actions(v_actions.last)    := g_monitor_groups(v_group_key)(i).action_name;
                            v_contexts.extend;    v_contexts(v_contexts.last)    := g_monitor_groups(v_group_key)(i).context_name;
                            v_mon_types.extend;  v_mon_types(v_mon_types.last) := g_monitor_groups(v_group_key)(i).monitor_type;
                            v_action_count.extend; v_action_count(v_action_count.last) := g_monitor_groups(v_group_key)(i).action_count;
                            v_used.extend;       v_used(v_used.last)          := g_monitor_groups(v_group_key)(i).used_time;
                            v_avgs.extend;       v_avgs(v_avgs.last)          := g_monitor_groups(v_group_key)(i).avg_action_time;
                            v_timesStart.extend;      v_timesStart(v_timesStart.last) := cast(g_monitor_groups(v_group_key)(i).start_time as date);
                            v_timesStop.extend;      v_timesStop(v_timesStop.last)  := cast(g_monitor_groups(v_group_key)(i).stop_time as date);
                        end loop;
            
                    -- 3. Radikaler Kahlschlag im RAM (SGA/PGA Hygiene)
                    g_monitor_groups(v_group_key).DELETE;
                end if ;
        
                v_group_key := g_monitor_groups.NEXT(v_group_key);
            end loop;
        
            -- 5. Persistieren
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
                if should_raise_error(p_processId) then RAISE; end if ;
        end flushMonitor;
    
        --------------------------------------------------------------------------
    
        procedure sync_monitor(p_processId number, p_force boolean default false)
        as        
            v_idx varchar2(100);
            v_ms_since_flush NUMBER;
            v_now constant timestamp := systimestamp;
    
        begin
            -- 1. Index der Session holen
            if not v_indexSession.EXISTS(p_processId) then
                return;
            end if ;
            v_idx := v_indexSession(p_processId);
    
            -- Falls noch nie geflusht wurde (Start), setzen wir die Differenz hoch
            if g_sessionList(v_idx).last_monitor_flush is null then
                v_ms_since_flush := C_FLUSH_MILLIS_THRESHOLD + 1;
            else
                v_ms_since_flush := get_ms_diff(g_sessionList(v_idx).last_monitor_flush, v_now);
            end if ;
            -- 4. Die "Smarte" Flush-Bedingung: Menge ODER Zeit ODER Force
            if p_force 
               or g_sessionList(v_idx).monitor_dirty_count >= C_FLUSH_MONITOR_THRESHOLD 
               or v_ms_since_flush >= C_FLUSH_MILLIS_THRESHOLD
            then
                flushMonitor(p_processId);
                
                -- Reset der prozessspezifischen Steuerungsdaten
                g_sessionList(v_idx).monitor_dirty_count := 0;
                g_sessionList(v_idx).last_monitor_flush  := v_now;
            end if ;
                    
        exception
            when others then
                -- Sicherheit für das Framework: Fehler im Flush dürfen Applikation nicht stoppen
                if should_raise_error(p_processId) then
                    raise;
                end if ;
        end;
                    
        --------------------------------------------------------------------------
        -- Calculation average time used
        --------------------------------------------------------------------------
        function calculate_avg(
            p_old_avg    number,
            p_curr_count pls_integer,
            p_new_value  number
        ) return number 
        is
            v_meas_count pls_integer;
        begin
            -- Die Anzahl der Intervalle ist die Anzahl der bisherigen Punkte
            v_meas_count := p_curr_count;
        
            -- Erster Messwert: Der Durchschnitt ist der Wert selbst
            if v_meas_count = 1 then
                return p_new_value;
            end if ;
        
            -- Gleitender Durchschnitt über n Intervalle
            -- Formel: ((Schnitt_alt * (n-1)) + Wert_neu) / n
            return ((p_old_avg * (v_meas_count - 1)) + p_new_value) / v_meas_count;
        end;
            
        --------------------------------------------------------------------------
        -- Helper for raising alerts
        --------------------------------------------------------------------------
        procedure raise_alert(
            p_processId number, 
            p_action varchar2,
            p_context_name varchar2,
            p_mon_type PLS_INTEGER,
            p_step PLS_INTEGER,
            p_used_time number,
            p_expected number
        )
        as
            l_msg VARCHAR2(4000);
        begin
            l_msg := 'PERFORMANCE ALERT: Process_ID=>' || p_processId || '; Action=>' || p_action || '; Context=>' || p_context_name || '; Step=>' || p_step || 
                     ' used ' || p_used_time || 'ms (expected: ' || p_expected || 'ms)';
                     
            -- Log to Buffer
            write_to_log_buffer(
                p_processId, 
                logLevelMonitor,
                l_msg,
                null,
                null,
                null
            );
    
        end;
            
        --------------------------------------------------------------------------
        -- Start Tracing remote
        --------------------------------------------------------------------------    
        procedure startTraceRemote(p_processId number, p_actionName varchar2, p_contextName varchar2, p_timestamp timestamp default systimestamp)
        as
            l_payload varchar2(10000); -- Puffer für den JSON-String
        begin
            select json_object(
                'process_id'    value p_processId,
                'action_name'   value p_actionName,
                'context_name'  value p_contextName,
                'timestamp'     value p_timestamp
                returning varchar2
            )
            into l_payload from dual;
            sendNoWait(p_processId, 'START_TRACE', l_payload, 0.5);
                    
        EXCEPTION
            WHEN OTHERS THEN
                if should_raise_error(p_processId) then
                    raise;
                end if ;
        end;
        
        --------------------------------------------------------------------------
        -- Creating and adding/updating a trace entry in the monitor list
        --------------------------------------------------------------------------    
        procedure insertTraceMonitorRemote(p_processId number, p_actionName varchar2, p_contextName varchar2, p_timestamp timestamp default systimestamp)
        as
            l_payload varchar2(10000); -- Puffer für den JSON-String
        begin
            -- Da das über die PIPE läuft und damit nicht gewährleistet ist, dass bei
            -- späterem Aufruf von insertMonitor im Server der Zeitpunkt 'in time' ist,
            -- muss der Zeitpunkt vom Client bei Aufruf gesetzt werden.
            -- Erzeugung des JSON-Objekts
            select json_object(
                'process_id'    value p_processId,
                'action_name'   value p_actionName,
                'context_name'  value p_contextName,
                'timestamp'     value p_timestamp
                returning varchar2
            )
            into l_payload from dual;
            sendNoWait(p_processId, 'STOP_TRACE', l_payload, 0.5);
                    
        EXCEPTION
            WHEN OTHERS THEN
                if should_raise_error(p_processId) then
                    raise;
                end if ;    
        end;
        
        --------------------------------------------------------------------------
 
        --------------------------------------------------------------------------
        -- Creating and adding/updating a record in the monitor list
        --------------------------------------------------------------------------    
        procedure insertEventMonitorRemote(p_processId number, p_actionName varchar2, p_contextName varchar2, p_timestamp timestamp default systimestamp)
        as
            l_payload varchar2(10000); -- Puffer für den JSON-String
        begin
            -- Da das über die PIPE läuft und damit nicht gewährleistet ist, dass bei
            -- späterem Aufruf von insertMonitor im Server der Zeitpunkt 'in time' ist,
            -- muss der Zeitpunkt vom Client bei Aufruf gesetzt werden.
            -- Erzeugung des JSON-Objekts
            select json_object(
                'process_id'    value p_processId,
                'action_name'   value p_actionName,
                'context_name'  value p_contextName,
                'timestamp'     value p_timestamp
                returning varchar2
            )
            into l_payload from dual;
            sendNoWait(p_processId, 'MARK_EVENT', l_payload, 0.5);
                    
        EXCEPTION
            WHEN OTHERS THEN
                if should_raise_error(p_processId) then
                    raise;
                end if ;    
        end;
        
        --------------------------------------------------------------------------
        
        procedure writeEventToMonitorBuffer (p_processId number, p_actionName varchar2, p_contextName varchar2, p_timestamp timestamp)
        as
            -- Key-Präfix sollte idealerweise p_processId enthalten für schnelleren Flush-Zugriff
            v_key        constant varchar2(200) := buildMonitorKey(p_processId, p_actionName, p_contextName);
            l_new_idx    PLS_INTEGER;
            v_idx        PLS_INTEGER;
            l_prev       t_monitor_buffer_rec; 
        begin
            if is_remote(p_processId) then
                insertEventMonitorRemote(p_processId, p_actionName, p_contextName, p_timestamp);
                return;
            end if ;
    
            -- 0. Monitoring-Check (Log-Level Prüfung)
            if v_indexSession.EXISTS(p_processId) and 
               logLevelMonitor > g_sessionList(v_indexSession(p_processId)).log_level then
                return;
            end if ;
        
            if NOT g_monitor_groups.EXISTS(v_key) THEN
                g_monitor_groups(v_key) := t_monitor_history_tab();
            end if ;
            g_monitor_groups(v_key).EXTEND;
            l_new_idx := g_monitor_groups(v_key).LAST;
            
            -- Die nächsten Werte abhängig davon ob es einen Vorgänger gibt
            if g_monitor_shadows.EXISTS(v_key) then            -- Es gibt einen Vorgänger
                l_prev := g_monitor_shadows(v_key);
                g_monitor_groups(v_key)(l_new_idx).action_count   := l_prev.action_count + 1;
                g_monitor_groups(v_key)(l_new_idx).used_time       := get_ms_diff(l_prev.start_time, nvl(p_timestamp, systimestamp));
                g_monitor_groups(v_key)(l_new_idx).avg_action_time := calculate_avg(
                                                                        l_prev.avg_action_time, 
                                                                        g_monitor_groups(v_key)(l_new_idx).action_count, 
                                                                        g_monitor_groups(v_key)(l_new_idx).used_time
                                                                      );
            ELSE
                -- Erster Eintrag der Session/Action
                g_monitor_groups(v_key)(l_new_idx).action_count   := 1;
                g_monitor_groups(v_key)(l_new_idx).used_time       := 0; -- Erster Marker hat keine Dauer
                g_monitor_groups(v_key)(l_new_idx).avg_action_time := 0;
                g_monitor_groups(v_key)(l_new_idx).monitor_type    := C_MON_TYPE_EVENT;
            end if ;
            
dbms_output.enable();
dbms_output.put_line('writeEventToMonitorBuffer -> p_processId: ' || p_processId);

            g_monitor_groups(v_key)(l_new_idx).process_id   := p_processId;
            g_monitor_groups(v_key)(l_new_idx).action_name  := p_actionName;
            g_monitor_groups(v_key)(l_new_idx).context_name := p_contextName;
            g_monitor_groups(v_key)(l_new_idx).monitor_type := C_MON_TYPE_EVENT;
            g_monitor_groups(v_key)(l_new_idx).start_time   := nvl(p_timestamp, systimestamp);
            
            -- vor dem Überschreiben des shadow-Eintrags die Regeln prüfen
            evaluateRules(g_monitor_groups(v_key)(l_new_idx), 'MARK_EVENT ');
            g_monitor_shadows(v_key) := g_monitor_groups(v_key)(g_monitor_groups(v_key).LAST);         
            
            v_idx := v_indexSession(p_processId);
            g_sessionList(v_idx).monitor_dirty_count := nvl(g_sessionList(v_idx).monitor_dirty_count, 0) + 1;
            g_dirty_queue(p_processId) := TRUE; 
            
--            validateDurationInAverage(p_processId, g_monitor_groups(v_key)(l_new_idx));
            SYNC_ALL_DIRTY;
            
        exception
            when others then
                if should_raise_error(p_processId) then
                    RAISE;
                end if ;
        end;
    
        --------------------------------------------------------------------------
        
        procedure startTrace (p_processId number, p_actionName varchar2, p_contextName varchar2, p_timestamp timestamp)
        as
            v_key constant varchar2(200) := buildMonitorKey(p_processId, p_actionName, p_contextName);
            v_idx           PLS_INTEGER;
            v_dummyMonRec   t_monitor_buffer_rec;
        begin
            if is_remote(p_processId) then
                startTraceRemote(p_processId, p_actionName, p_contextName, p_timestamp);
                return;
            end if ;
            
            -- Dummy nur für die Regeln
            v_dummyMonRec.process_id := p_processId;
            v_dummyMonRec.start_time := nvl(p_timestamp, systimestamp);
            v_dummyMonRec.stop_time := null;
            v_dummyMonRec.monitor_type := C_MON_TYPE_TRACE;
            v_dummyMonRec.action_name := p_actionName;
            v_dummyMonRec.context_name := p_contextName;

            if g_monitor_shadows.EXISTS(v_key) THEN
                evaluateRules(v_dummyMonRec, 'TRACE_START');
            end if;
            g_monitor_shadows(v_key) := v_dummyMonRec;
            
            -- Regeln prüfen; der Shadow-Eintrag steht für die neue Transaktion            
            v_idx := v_indexSession(p_processId);
        end;
        
        --------------------------------------------------------------------------

        procedure writeTraceToMonitorBuffer (p_processId number, p_actionName varchar2, p_contextName varchar2, p_timestamp timestamp)
        as
            -- Key-Präfix sollte idealerweise p_processId enthalten für schnelleren Flush-Zugriff
            v_key        constant varchar2(200) := buildMonitorKey(p_processId, p_actionName, p_contextName);
            v_used_time  number := 0;
            v_new_avg    number := 0;
            v_new_rec    t_monitor_buffer_rec;
            v_first_idx  PLS_INTEGER;
            l_new_idx    PLS_INTEGER;
            v_idx        PLS_INTEGER;
        begin
            if is_remote(p_processId) then
                insertTraceMonitorRemote(p_processId, p_actionName, p_contextName, p_timestamp);
                return;
            end if ;
                
            if v_indexSession.EXISTS(p_processId) and 
               logLevelMonitor > g_sessionList(v_indexSession(p_processId)).log_level then
                return;
            end if ;
            
            -- check if open transaction exists
            if NOT g_monitor_shadows.EXISTS(v_key) then
                return;
            end if;
            
            v_new_rec           := g_monitor_shadows(v_key);
            v_new_rec.stop_time := nvl(p_timestamp, systimestamp);
            v_new_rec.used_time := get_ms_diff(v_new_rec.start_time, v_new_rec.stop_time);
            
            IF NOT g_monitor_averages.EXISTS(v_key) THEN
                -- Erster Durchlauf für diese Aktion/Kontext
                v_new_rec.action_count   := 1;
                v_new_rec.avg_action_time := v_new_rec.used_time;
            ELSE
                -- Bestehende Werte aus dem Gedächtnis holen
                v_new_rec.action_count    := g_monitor_averages(v_key).action_count + 1;
                -- Gleitender Durchschnitt berechnen
                -- Formel: ((Alter Schnitt * Alte Anzahl) + Neue Zeit) / Neue Anzahl
                v_new_rec.avg_action_time := 
                    ((g_monitor_averages(v_key).avg_action_time * g_monitor_averages(v_key).action_count) 
                     + v_new_rec.used_time) / v_new_rec.action_count;
            END IF;
            
            -- Gedächtnis für den nächsten Lauf aktualisieren
            g_monitor_averages(v_key) := v_new_rec;

            if NOT g_monitor_groups.EXISTS(v_key) THEN
                g_monitor_groups(v_key) := t_monitor_history_tab();
            end if ;
            g_monitor_groups(v_key).EXTEND;
            g_monitor_groups(v_key)(g_monitor_groups(v_key).LAST) := v_new_rec;
            
            -- Das Event an die Regelprüfung durchreichen
            evaluateRules(v_new_rec, 'TRACE_STOP');
            g_monitor_shadows.delete(v_key);
            g_monitor_averages(v_key) := v_new_rec;
            
            v_idx := v_indexSession(p_processId);            
--            validateDurationInAverage(p_processId, g_monitor_groups(v_key)(l_new_idx));
            g_sessionList(v_idx).monitor_dirty_count := nvl(g_sessionList(v_idx).monitor_dirty_count, 0) + 1;
            g_dirty_queue(p_processId) := TRUE; 
            
            SYNC_ALL_DIRTY;
            
        exception
            when others then
                if should_raise_error(p_processId) then
                    RAISE;
                end if ;
        end;
    
        --------------------------------------------------------------------------
        -- Removing a record from monitor list
        --------------------------------------------------------------------------
        procedure removeMonitor(p_processId number, p_actionName varchar2, p_contextName varchar2)
        as
            v_key constant varchar2(200) := buildMonitorKey(p_processId, p_actionName, p_contextName);
        begin
            -- 1. Historie löschen
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
            v_empty  t_monitor_buffer_rec; -- Initial leerer Record als Fallback
        begin
            -- 1. Prüfen, ob die Gruppe (Action) im Cache existiert
            if g_monitor_groups.EXISTS(v_key) then
                -- 2. Prüfen, ob die Historie-Liste Einträge hat
                if g_monitor_groups(v_key).COUNT > 0 then
                    -- Den letzten Eintrag (LAST) der verschachtelten Liste zurückgeben
                    return g_monitor_groups(v_key)(g_monitor_groups(v_key).LAST);
                end if ;
            end if ;
        
            -- Falls nichts gefunden wurde, wird ein leerer Record zurückgegeben
            return v_empty;
        
        exception
            when others then
                -- Hier nutzen wir deine neue zentrale Fehler-Logik
                if should_raise_error(p_processId) then
                    raise;
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
                if should_raise_error(p_processId) then
                    raise;
                end if ;
                return false;
        end;
        
        --------------------------------------------------------------------------
        -- Monitoring a step
        --------------------------------------------------------------------------
        PROCEDURE MARK_EVENT(p_processId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2, p_timestamp timestamp default NULL)
        as
        begin
            writeEventToMonitorBuffer (p_processId, p_actionName, p_contextName, p_timestamp);     
        end;
        --------------------------------------------------------------------------
        
        
        --------------------------------------------------------------------------
        -- Monitoring a transaction
        --------------------------------------------------------------------------
        PROCEDURE TRACE_START(p_processId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2, p_timestamp timestamp default NULL)
        as
        begin
            startTrace (p_processId, p_actionName, p_contextName, p_timestamp);     
        end;
        --------------------------------------------------------------------------

        PROCEDURE TRACE_STOP(p_processId NUMBER, p_actionName VARCHAR2, p_contextName VARCHAR2, p_timestamp TIMESTAMP DEFAULT NULL)
        as
        begin
            writeTraceToMonitorBuffer(p_processId, p_actionName, p_contextName, p_timestamp);
        end;
        
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
                v_rec.action_count  := extractFromJsonNum(l_payload, 'action_count');
                v_rec.used_time  := extractFromJsonNum(l_payload, 'used_time');
                v_rec.start_time  := extractFromJsonTime(l_payload, 'start_time');
                v_rec.stop_time  := extractFromJsonTime(l_payload, 'stop_time');
                v_rec.avg_action_time  := extractFromJsonNum(l_payload, 'avg_action_time');
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
            RETURN nvl(v_rec.avg_action_time, 0);
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
            RETURN nvl(v_rec.action_count, 0);
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
                -- neuer Datensatz
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
            sqlStatement := '
            update PH_MASTER_TABLE
            set status           = :PH_STATUS,
                last_update      = current_timestamp,
                process_end      = :PH_PROCESS_END,
                proc_steps_todo  = :PH_PROC_STEPS_TODO,
                proc_steps_done  = :PH_PROC_STEPS_DONE,
                info             = :PH_INFO,
                process_immortal = :PH_IMMORTAL
            where id = :PH_PROCESS_ID';  
    
            sqlStatement := replaceNameMasterTable(sqlStatement, C_PARAM_MASTER_TABLE, p_process_rec.tab_name_master);        
            execute immediate sqlStatement
            USING   p_process_rec.status, 
                    p_process_rec.process_end,
                    p_process_rec.proc_steps_todo,
                    p_process_rec.proc_steps_done,
                    p_process_rec.info,
                    p_process_rec.proc_immortal,
                    p_process_rec.id;
            
            commit;
    
        exception
            when others then
                rollback; -- Auch im Fehlerfall die Transaktion beenden
                if should_raise_error(p_process_rec.id) then
                    RAISE;
                end if ;
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
            update PH_MASTER_TABLE
            set process_end = current_timestamp,
                last_update = current_timestamp';
    
            if p_procStepsDone is not null then
                sqlStatement := sqlStatement || ', proc_steps_done = :PH_PROC_STEPS_DONE';
            end if ;
            if p_procStepsToDo is not null then
                sqlStatement := sqlStatement || ', proc_steps_todo = :PH_STEPS_TO_DO';
            end if ;
            if p_processInfo is not null then
                sqlStatement := sqlStatement || ', info = :PH_PROCESS_INFO';
            end if ;     
            if p_status is not null then
                sqlStatement := sqlStatement || ', status = :PH_STATUS';
            end if ;     
            
            sqlStatement := sqlStatement || ' where id = :PH_PROCESS_ID'; 
            sqlStatement := replaceNameMasterTable(sqlStatement, C_PARAM_MASTER_TABLE, p_tableName);
            
            -- due to the variable number of parameters using dbms_sql
            sqlCursor := DBMS_SQL.OPEN_CURSOR;
            DBMS_SQL.PARSE(sqlCursor, sqlStatement, DBMS_SQL.NATIVE);
            DBMS_SQL.BIND_VARIABLE(sqlCursor, ':PH_PROCESS_ID', p_processId);
    
            if p_procStepsDone is not null then
                DBMS_SQL.BIND_VARIABLE(sqlCursor, ':PH_PROC_STEPS_DONE', p_procStepsDone);
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
                if DBMS_SQL.IS_OPEN(sqlCursor) THEN
                    DBMS_SQL.CLOSE_CURSOR(sqlCursor);
                end if ;
                sqlCursor := null;
                rollback;
                if should_raise_error(p_processId) then
                    RAISE;
                end if ;
        end;
    
        --------------------------------------------------------------------------
    
        procedure persist_new_session(p_processId NUMBER, p_processName VARCHAR2, p_logLevel PLS_INTEGER, p_procStepsToDo PLS_INTEGER, p_daysToKeep PLS_INTEGER, p_procImmortal PLS_INTEGER, p_tabNameMaster VARCHAR2)
        as
            pragma autonomous_transaction;
            sqlStatement varchar2(2000);
        begin
            sqlStatement := '
            insert into PH_MASTER_TABLE (
                id,
                process_name,
                process_start,
                last_update,
                process_end,
                proc_steps_todo,
                proc_steps_done,
                status,
                log_level,
                info,
                process_immortal,
                tab_name_master
            )
            values (
                :PH_PROCESS_ID, 
                :PH_PROCESS_NAME, 
                current_timestamp,
                current_timestamp,
                null,
                :PH_STEPS_TO_DO, 
                null,
                null,
                :PH_LOG_LEVEL,
                ''START'',
                :PH_IMMORTAL,
                :PH_TABNAME_MASTER
            )';
            sqlStatement := replaceNameMasterTable(sqlStatement, C_PARAM_MASTER_TABLE, p_TabNameMaster);
            execute immediate sqlStatement USING p_processId, p_processName, p_procStepsToDo, p_logLevel, p_procImmortal, upper(p_tabNameMaster);     
            commit;
        exception
            when others then
                rollback; -- Auch im Fehlerfall die Transaktion beenden
                if should_raise_error(p_processId) then
                    RAISE;
                end if ;
        end;
    
        --------------------------------------------------------------------------
        
        procedure sync_process(p_processId number, p_force boolean default false)
        as
            v_idx            PLS_INTEGER;
            v_now            constant timestamp := systimestamp;
            v_ms_since_flush number;
        begin
            -- 1. Sicherstellen, dass die Session im Server/Standalone bekannt ist
            if not v_indexSession.EXISTS(p_processId) then
                return;
            end if ;
        
            v_idx := v_indexSession(p_processId);
        
            -- 2. Zeit seit dem letzten Master-Update berechnen
            if g_sessionList(v_idx).last_process_flush is null then
                v_ms_since_flush := C_FLUSH_MILLIS_THRESHOLD + 1;
            else
                v_ms_since_flush := get_ms_diff(g_sessionList(v_idx).last_process_flush, v_now);
            end if ;
        
            -- 3. Die "Smarte" Flush-Bedingung
            -- Wir flushen nur, wenn FORCE (z.B. Session-Ende), der Zeit-Threshold erreicht ist
            -- ODER wenn dieser spezifische Prozess als "dirty" markiert wurde.
            if p_force 
               or (g_sessionList(v_idx).process_is_dirty AND v_ms_since_flush >= C_FLUSH_MILLIS_THRESHOLD)
               or (p_force = false AND v_ms_since_flush >= (C_FLUSH_MILLIS_THRESHOLD * 10)) -- Safety Sync
            then
                -- Nur schreiben, wenn es auch wirklich Änderungen im Cache gibt
                if g_process_cache.EXISTS(p_processId) then
                    persist_process_record(g_process_cache(p_processId));            
                    
                    -- Reset der prozessspezifischen Steuerungsdaten
                    g_sessionList(v_idx).process_is_dirty   := FALSE;
                    g_sessionList(v_idx).last_process_flush := v_now;
                end if ;
            end if ;
        
        exception
            when others then
                if should_raise_error(p_processId) then
                    raise;
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
            -- 1. Index der Session holen
            if not v_indexSession.EXISTS(p_processId) then
                return;
            end if ;
            v_idx := v_indexSession(p_processId);
            g_sessionList(v_idx).log_dirty_count := nvl(g_sessionList(v_idx).log_dirty_count, 0) + 1;
            g_dirty_queue(p_processId) := TRUE;
            
            -- (get_ms_diff ist Ihre optimierte Funktion)
            if g_sessionList(v_idx).last_log_flush is null then
                v_ms_since_flush := C_FLUSH_MILLIS_THRESHOLD + 1;
            else
                v_ms_since_flush := get_ms_diff(g_sessionList(v_idx).last_log_flush, v_now);
            end if ;
            -- 4. Flush-Bedingung: Menge ODER Zeit ODER Force
            if p_force 
               or g_sessionList(v_idx).log_dirty_count >= C_FLUSH_LOG_THRESHOLD 
               or v_ms_since_flush >= C_FLUSH_MILLIS_THRESHOLD
            then
                -- Alle gepufferten Logs dieses Prozesses in die DB schreiben
               flushLogs(p_processId);
                
                -- Steuerungsdaten für diesen Prozess zurücksetzen
                g_sessionList(v_idx).log_dirty_count := 0;
                g_sessionList(v_idx).last_log_flush  := v_now;
            end if ;
                    
        exception
            when others then
                -- Sicherheit für das Framework: Fehler im Flush dürfen Applikation nicht stoppen
                if should_raise_error(p_processId) then
                    raise;
                end if ;
        end;
    
        --------------------------------------------------------------------------
        
        procedure close_sessionRemote(p_processId number, p_procStepsToDo number, p_procStepsDone number, p_processInfo varchar2, p_status PLS_INTEGER)
        as
            l_payload varchar2(32767); -- Puffer für den JSON-String
            l_serverMsg varchar2(100);
            l_response PLS_INTEGER;
        begin
            -- Erzeugung des JSON-Objekts
            select json_object(
                'process_id'   value p_processId,
                'proc_steps_todo'   value p_procStepsToDo,
                'proc_steps_done'   value p_procStepsDone,
                'process_info' value p_processInfo,
                'process_status'       value p_status
                returning varchar2
            )
            into l_payload from dual;
            
            l_response := waitForResponse(p_processId, 'CLOSE_SESSION', l_payload, 1);
            
            if l_response in ('TIMEOUT', 'THROTTLED') or
               l_response like 'ERROR%' then
               l_serverMsg := 'close_sessionRemote: ' || l_response;
            else
                l_serverMsg := extractFromJsonStr(l_response, 'payload.server_message');
            end if ;        
                    
        EXCEPTION
            WHEN OTHERS THEN
                if should_raise_error(p_processId) then
                    raise;
                end if ;
        end;
        
        --------------------------------------------------------------------------

        procedure procStepDoneRemote(p_processId number)
        as
            l_payload varchar2(32767); -- Puffer für den JSON-String
            l_serverMsg varchar2(100);
        begin
            -- Erzeugung des JSON-Objekts
            select json_object(
                'process_id'   value p_processId
                returning varchar2
            )
            into l_payload from dual;
            sendNoWait(p_processId, 'PROC_STEP_DONE', l_payload, 0.5);
        end;
        --------------------------------------------------------------------------

        procedure setAnyStatusRemote(p_processId number, p_status pls_integer, p_processInfo varchar2, p_procStepsToDo pls_integer, p_procStepsDone pls_integer, p_immortal pls_integer)
        as
            l_payload varchar2(32767); -- Puffer für den JSON-String
            l_serverMsg varchar2(100);
        begin
            -- Erzeugung des JSON-Objekts
            select json_object(
                'process_id'        value p_processId,
                'proc_steps_todo'   value p_procStepsToDo,
                'proc_steps_done'   value p_procStepsDone,
                'process_info'      value p_processInfo,
                'process_status'    value p_status,
                'process_immortal'  value p_immortal
                returning varchar2
            )
            into l_payload from dual;
            sendNoWait(p_processId, 'SET_ANY_STATUS', l_payload, 0.5);
        end;

    
        --------------------------------------------------------------------------
        
        procedure log_anyRemote(p_processId number, p_level number, p_logText varchar2, p_errStack varchar2, p_errBacktrace varchar2, p_errCallstack varchar2)
        as
            l_payload varchar2(32767); -- Puffer für den JSON-String
        begin
            -- Erzeugung des JSON-Objekts
            select json_object(
                'process_id'    value p_processId,
                'level'         value p_level,
                'log_text'      value p_logText,
                'err_stack'     value p_errStack,
                'err_backtr'    value p_errBacktrace,
                'err_callstack' value p_errCallstack
                returning varchar2
            )
            into l_payload from dual;
            sendNoWait(p_processId, 'LOG_ANY', l_payload, 0.5);
                    
        EXCEPTION
            WHEN OTHERS THEN
                if should_raise_error(p_processId) then
                    raise;
                end if ;
    
        end;
        
        --------------------------------------------------------------------------
    
        -- capsulation writing to log-buffer and synchronization of buffer
        procedure log_any(
            p_processId number, 
            p_level number,
            p_logText varchar2,
            p_errStack varchar2,
            p_errBacktrace varchar2,
            p_errCallstack varchar2
        )
        as
        begin
            if is_remote(p_processId) then
                log_anyRemote(p_processId, p_level, p_logText, p_errStack, p_errBacktrace, p_errCallstack);
                return;
            end if ;
    
            -- Hier nur weiter, wenn nicht remote
            if v_indexSession.EXISTS(p_processId) and p_level <= g_sessionList(v_indexSession(p_processId)).log_level then
                write_to_log_buffer(
                    p_processId, 
                    p_level,
                    p_logText,
                    null,
                    null,
                    DBMS_UTILITY.FORMAT_CALL_STACK
                );
            end if ;
    
            sync_all_dirty;
            
        exception
            when others then
                -- Sicherheit für das Framework: Fehler im Flush dürfen Applikation nicht stoppen
                if should_raise_error(p_processId) then
                    raise;
                end if ;
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
                    DBMS_UTILITY.FORMAT_CALL_STACK
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
                null
            );
        end;
    
        --------------------------------------------------------------------------
    
        -- Used by external Procedure to write a new log entry with log level ERROR
        -- Details are adjusted to the error level
        procedure ERROR(p_processId number, p_logText varchar2)
        as
        begin
            log_any(
                p_processId, 
                logLevelDebug,
                p_logText,
                DBMS_UTILITY.FORMAT_ERROR_STACK,
                DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                DBMS_UTILITY.FORMAT_CALL_STACK
            );
        end;
    
        --------------------------------------------------------------------------
    
        -- Used by external Procedure to write a new log entry with log level WARN
        -- Details are adjusted to the warn level
        procedure WARN(p_processId number, p_logText varchar2)
        as
        begin
            log_any(
                p_processId, 
                logLevelInfo,
                p_logText,
                null,
                null,
                null
            );
        end;
         
        --------------------------------------------------------------------------
        
        procedure setAnyStatus(p_processId number, p_status PLS_INTEGER, p_processInfo varchar2, p_procStepsToDo number, p_procStepsDone number, p_procImmortal PLS_INTEGER)
        as
        begin
        
            if is_remote(p_processId) then
                setAnyStatusRemote(p_processId, p_status, p_processInfo, p_procStepsToDo, p_procStepsDone, p_procImmortal);
                return;
            end if ;
            
           if v_indexSession.EXISTS(p_processId) then
                if p_status         is not null then g_process_cache(p_processId).status := p_status; end if ;
                if p_processInfo    is not null then g_process_cache(p_processId).info := p_processInfo; end if ;
                if p_procStepsToDo  is not null then g_process_cache(p_processId).proc_steps_todo := p_procStepsToDo; end if ;
                if p_procStepsDone  is not null then g_process_cache(p_processId).proc_steps_done := p_procStepsDone; end if ;
                if p_procImmortal   is not null then g_process_cache(p_processId).proc_immortal := p_procImmortal; end if;
    
                g_sessionList(v_indexSession(p_processId)).process_is_dirty := TRUE;
                g_dirty_queue(p_processId) := TRUE; -- Damit SYNC_ALL_DIRTY die Session sieht
                
                evaluateRules(g_process_cache(p_processId), C_PROCESS_UPDATE);
                SYNC_ALL_DIRTY;
                
            end if ;
            
        exception
            when others then
                -- Sicherheit für das Framework: Fehler im Flush dürfen Applikation nicht stoppen
                if should_raise_error(p_processId) then
                    raise;
                end if ;
        end;
    
        --------------------------------------------------------------------------
    
        procedure SET_PROCESS_STATUS(p_processId number, p_status PLS_INTEGER, p_processInfo varchar2)
        as
        begin
            setAnyStatus(p_processId, p_status, p_processInfo, null, null, null);
        end;
    
        --------------------------------------------------------------------------
    
        procedure SET_PROCESS_STATUS(p_processId number, p_status PLS_INTEGER)
        as
        begin
            setAnyStatus(p_processId, p_status, null, null, null, null);
        end;
    
        --------------------------------------------------------------------------
        
         procedure SET_PROC_STEPS_TODO(p_processId number, p_procStepsToDo number)
         as
         begin
            setAnyStatus(p_processId, null, null, p_procStepsToDo, null, null);
         end;
       
        --------------------------------------------------------------------------
     
        procedure SET_PROC_STEPS_DONE(p_processId number, p_procStepsDone number)
        as
        begin
            setAnyStatus(p_processId, null, null, null, p_procStepsDone, null);   
        end;
        
        procedure SET_PROC_IMMORTAL(p_processId number, p_immortal number)
        as
        begin
            setAnyStatus(p_processId, null, null, null, null, p_immortal);
        end;
        
        --------------------------------------------------------------------------
        
        procedure PROC_STEP_DONE(p_processId number)
        as
            sqlStatement varchar2(500);
            l_steps number;
        begin
            if is_remote(p_processId) then
                procStepDoneRemote(p_processId);
                return;
            end if ;

           if v_indexSession.EXISTS(p_processId) then
                l_steps := nvl(g_process_cache(p_processId).proc_steps_done, 0) +1;                
                setAnyStatus(p_processId, null, null, null, l_steps, null);   
            end if;
        end;
        
        --------------------------------------------------------------------------

        function getProcessDataRemote(p_processId number) return t_process_rec
        as
            l_payload varchar2(20000); -- Puffer für den JSON-String
            l_serverMsg varchar2(100);
            l_response varchar2(20000);
            l_process_rec t_process_rec;
        begin
            -- Erzeugung des JSON-Objekts
            select json_object(
                'process_id'   value p_processId
                returning varchar2
            )
            into l_payload from dual;            
            l_response := waitForResponse(p_processId, 'GET_PROCESS_DATA', l_payload, 5);
            
            if l_response in ('TIMEOUT', 'THROTTLED') or
                l_response like 'ERROR%' then
               l_serverMsg := 'Server Response Get_PROCESS_DATA: ' || l_response;
            else                
                l_payload := JSON_QUERY(l_response, '$.payload');
                l_process_rec.id                := extractFromJsonStr(l_payload, 'process_id');
                l_process_rec.process_name      := extractFromJsonStr(l_payload, 'process_name');
                l_process_rec.log_level         := extractFromJsonNum(l_payload, 'log_level');
                l_process_rec.process_start     := extractFromJsonTime(l_payload, 'process_start');
                l_process_rec.process_end       := extractFromJsonTime(l_payload, 'process_end');
                l_process_rec.last_update       := extractFromJsonTime(l_payload, 'last_update');
                l_process_rec.info              := extractFromJsonStr(l_payload, 'process_info');
                l_process_rec.status            := extractFromJsonNum(l_payload, 'process_status');
                l_process_rec.proc_steps_todo   := extractFromJsonNum(l_payload, 'proc_steps_todo');
                l_process_rec.proc_steps_done   := extractFromJsonNum(l_payload, 'proc_steps_done');
                l_process_rec.tab_name_master   := extractFromJsonStr(l_payload, 'tabname_master');            
            end if ; 
            
            return l_process_rec;
        end;
        
        --------------------------------------------------------------------------

        FUNCTION GET_PROCESS_DATA_JSON(p_processId NUMBER) return varchar2
        as
            l_payload varchar2(32767);
        begin
            select json_object(
                'process_id'   value p_processId
                returning varchar2
            )
            into l_payload from dual;    
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
            return get_process_data(p_processId).proc_steps_done;
        end;
    
        --------------------------------------------------------------------------
    
        FUNCTION GET_PROC_STEPS_TODO(p_processId NUMBER) return PLS_INTEGER
        as
        begin
            return get_process_data(p_processId).proc_steps_todo;
        end;
    
        --------------------------------------------------------------------------
        
        function GET_PROCESS_START(p_processId NUMBER) return timestamp
        as
        begin
            return get_process_data(p_processId).process_start;
        end;
        
        --------------------------------------------------------------------------
        
        function GET_PROCESS_END(p_processId NUMBER) return timestamp
        as
        begin
            return get_process_data(p_processId).process_end;
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
            g_monitor_groups.delete;
            g_log_groups.delete;
            g_dirty_queue.delete;
            v_indexSession.delete;
            if not g_sessionList is null then
                g_sessionList.delete;
            end if;
            g_remote_sessions.DELETE;
            g_process_cache.DELETE;
            g_monitor_shadows.DELETE;
            g_local_throttle_cache.DELETE;    
            g_alert_history.DELETE;
            g_rules_by_context.DELETE;
            g_rules_by_action.DELETE;
        end;
    
        --------------------------------------------------------------------------
    
        PROCEDURE clearAllSessionData(p_processId NUMBER) 
        IS
            v_idx           PLS_INTEGER;
            v_search_prefix CONSTANT VARCHAR2(50) := LPAD(p_processId, 20, '0') || '|';
            v_key           VARCHAR2(250);
            v_next_key      VARCHAR2(250);
            v_msg           VARCHAR2(500);
        BEGIN
    
            -- A) MONITOR-DATEN & CACHES RÄUMEN
            -- Wir nutzen den sicheren Loop (Sichern vor Löschen)
            v_key := g_monitor_groups.FIRST;
            WHILE v_key IS NOT NULL LOOP
                EXIT WHEN SUBSTR(v_key, 1, 20) > LPAD(p_processId, 20, '0');
                v_next_key := g_monitor_groups.NEXT(v_key);
                
                if v_key LIKE v_search_prefix || '%' THEN
                    -- Historie löschen
                    g_monitor_groups.DELETE(v_key);
                end if ;
                v_key := v_next_key;
            END LOOP;
        
            -- B) LOG-GRUPPEN RÄUMEN
            -- Da g_log_groups ebenfalls mit der ID als Key (String) arbeitet:
            if g_log_groups.EXISTS(TO_CHAR(p_processId)) THEN
                g_log_groups.DELETE(TO_CHAR(p_processId));
            end if;
    
            -- C) DIRTY QUEUE RÄUMEN
            if g_dirty_queue.EXISTS(p_processId) THEN
                g_dirty_queue.DELETE(p_processId);
            end if;
        
            -- D) SESSION-METADATEN (MASTER-LISTE) RÄUMEN
            if v_indexSession.EXISTS(p_processId) THEN
                v_idx := v_indexSession(p_processId);
                g_sessionList.DELETE(v_idx);     -- Eintrag in der Nested Table (Slot wird leer)
                v_indexSession.DELETE(p_processId); -- Wegweiser löschen
            end if;
        
            -- E) PROZESS CACHE RÄUMEN
            if g_process_cache.EXISTS(p_processId) THEN
                g_process_cache.DELETE(p_processId);
            end if ;
            
            -- F) Monitor Shadows löschen
                -- Wir starten am Anfang der Schatten-Map
            v_key := g_monitor_shadows.FIRST;   
            WHILE v_key IS NOT NULL LOOP
                EXIT WHEN SUBSTR(v_key, 1, 20) > LPAD(p_processId, 20, '0');
                if v_key LIKE v_search_prefix || '%' THEN
                    g_monitor_shadows.DELETE(v_key);
                    -- Optional: DBMS_OUTPUT.PUT_LINE('Shadow gelöscht für: ' || v_key);
                end if ;            
                -- Zum nächsten Key springen
                v_key := g_monitor_shadows.NEXT(v_key);
            END LOOP;
            
            -- G) Durchschnittswerte löschen
            v_key := g_monitor_averages.FIRST;
            WHILE v_key IS NOT NULL LOOP
                EXIT WHEN SUBSTR(v_key, 1, 20) > LPAD(p_processId, 20, '0');
                if v_key LIKE v_search_prefix || '%' THEN
                    g_monitor_averages.DELETE(v_key);
                end if ;            
                v_key := g_monitor_averages.NEXT(v_key);
            END LOOP;

            -- Offene Traces (Shadows) prüfen, bevor sie gelöscht werden
            -- Wenn offen, wird eine Warnung gelogged
            v_key := g_monitor_shadows.FIRST;
            WHILE v_key IS NOT NULL LOOP
                EXIT WHEN SUBSTR(v_key, 1, 20) > LPAD(p_processId, 20, '0');
                
                IF SUBSTR(v_key, 1, 21) = v_search_prefix THEN
                    -- HIER: Alert-Logik einbauen
                    v_msg := 'OPEN TRACE ALERT (Trace purged): Process_ID=>' || p_processId || '; Action=>' || g_monitor_shadows(v_key).action_name ||
                    '; Context=>' || g_monitor_shadows(v_key).context_name || '; Start=>' || g_monitor_shadows(v_key).start_time;                     
                    -- Log to Buffer
                    write_to_log_buffer(
                        p_processId, 
                        logLevelWarn,
                        v_msg,
                        null,
                        null,
                        null
                    );

                    g_monitor_shadows.DELETE(v_key);
                END IF;
                v_key := g_monitor_shadows.NEXT(v_key);
            END LOOP;
            
            -- H) Die Liste der aktiven Server zurücksetzen
            g_client_pipes.DELETE(p_processId);
            
            -- I) Speicher von gesendeten Nachrichten und vergangener Zeit für diesen Prozess
            g_local_throttle_cache.DELETE(p_processId);
        
        EXCEPTION
            WHEN OTHERS THEN
                -- Hier optional Loggen, falls beim Cleanup was schief geht
                RAISE;
        END;
        
        --------------------------------------------------------------------------
        
        PROCEDURE CLOSE_SESSION(p_processId NUMBER, p_processInfo VARCHAR2, p_status PLS_INTEGER)
        as
        begin
            close_session(
                p_processId   => p_processId, 
                p_procStepsToDo   => null, 
                p_procStepsDone   => null, 
                p_processInfo => p_processInfo, 
                p_status      => p_status
            );
        end;
        
        --------------------------------------------------------------------------
    
        PROCEDURE CLOSE_SESSION(p_processId NUMBER, p_procStepsDone NUMBER, p_processInfo VARCHAR2, p_status PLS_INTEGER)
        as
        begin
            close_session(
                p_processId   => p_processId, 
                p_procStepsToDo   => null, 
                p_procStepsDone   => p_procStepsDone, 
                p_processInfo => p_processInfo, 
                p_status      => p_status
            );
        end;
    
        --------------------------------------------------------------------------
        
        -- Ends an earlier started logging session by the process ID.
        -- Important! Ignores if the process doesn't exist! No exception is thrown!
        procedure CLOSE_SESSION(p_processId number)
        as
        begin
            close_session(
                p_processId   => p_processId, 
                p_procStepsToDo   => null, 
                p_procStepsDone   => null, 
                p_processInfo => null, 
                p_status      => null
            );
        end;
    
        --------------------------------------------------------------------------
    
        procedure CLOSE_SESSION(p_processId number, p_procStepsToDo number, p_procStepsDone number, p_processInfo varchar2, p_status PLS_INTEGER)
        as
            v_idx PLS_INTEGER;
        begin
            if is_remote(p_processId) then
                close_sessionRemote(p_processId, p_procStepsToDo, p_procStepsDone, p_processInfo, p_status);
                g_remote_sessions.delete(p_processId);
                return;
            end if ;
    
            -- Hier nur weiter, wenn lokale processId
            if v_indexSession.EXISTS(p_processId) then
                g_dirty_queue(p_processId) := TRUE;
                SYNC_ALL_DIRTY(true);
        
                evaluateRules(g_process_cache(p_processId), C_PROCESS_STOP);
                
                v_idx := v_indexSession(p_processId);
                persist_close_session(p_processId,  g_sessionList(v_idx).tabName_master, p_procStepsToDo, p_procStepsDone, p_processInfo, p_status);
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
        begin
    
           -- if silent log mode don't do anything
            if p_session_init.logLevel > logLevelSilent then
                -- Sicherstellen, dass die LOG-Tabellen existieren
                createLogTables(p_session_init.tab_name_master);
            end if ;
    
            execute immediate 'select seq_lilam_log.nextVal from dual' into p_processId;
            -- persist to session internal table
            insertSession (p_session_init.tab_name_master, p_processId, p_session_init.logLevel);
--            if p_session_init.logLevel > logLevelSilent then -- and p_session_init.daysToKeep is not null then
            deleteOldLogs(p_processId, upper(trim(p_session_init.processName)), p_session_init.daysToKeep);
            persist_new_session(p_processId, p_session_init.processName, p_session_init.logLevel,  
            p_session_init.proc_stepsToDo, p_session_init.daysToKeep, p_session_init.procImmortal, p_session_init.tab_name_master);
--            end if ;
    
            -- copy new details data to memory
            v_new_rec.id              := p_processId;
            v_new_rec.tab_name_master := p_session_init.tab_name_master;
            v_new_rec.process_name    := p_session_init.processName;
            v_new_rec.process_start   := current_timestamp;
            v_new_rec.process_end     := null;
            v_new_rec.last_update     := null;
            v_new_rec.proc_steps_todo := p_session_init.proc_stepsToDo;
            v_new_rec.proc_steps_done := 0;
            v_new_rec.status          := 0;
            v_new_rec.info            := 'START';
            
            g_process_cache(p_processId) := v_new_rec;
            evaluateRules(g_process_cache(p_processId), C_PROCESS_START);

            return p_processId;
    
        end;
    
        
        FUNCTION NEW_SESSION(p_processName VARCHAR2, p_logLevel PLS_INTEGER, p_procStepsToDo NUMBER, p_daysToKeep NUMBER, p_tabNameMaster varchar2 default 'LILAM_LOG') return number
        as
            p_session_init t_session_init;
        begin
        
            p_session_init.processName := p_processName;
            p_session_init.logLevel := p_logLevel;
            p_session_init.daysToKeep := p_daysToKeep;
            p_session_init.proc_stepsToDo := p_procStepsToDo;
            p_session_init.tab_name_master := p_tabNameMaster;
        
            return new_session(p_session_init);
        end;
    
        --------------------------------------------------------------------------
    
        function NEW_SESSION(p_processName varchar2, p_logLevel PLS_INTEGER, p_tabNameMaster varchar2 default 'LILAM_LOG') return number
        as
            p_session_init t_session_init;
        begin
            p_session_init.processName := p_processName;
            p_session_init.logLevel := p_logLevel;
            p_session_init.daysToKeep := null;
            p_session_init.proc_stepsToDo := null;
            p_session_init.tab_name_master := p_tabNameMaster;
        
            return new_session(p_session_init);
        end;
    
    
        -- Opens/starts a new logging session.
        -- The returned process id must be stored within the calling procedure because it is the reference
        -- which is recommended for all following actions (e.g. CLOSE_SESSION, DEBUG, SET_PROCESS_STATUS).
        function NEW_SESSION(p_processName varchar2, p_logLevel PLS_INTEGER, p_daysToKeep number, p_tabNameMaster varchar2 default 'LILAM_LOG') return number
        as
            p_session_init t_session_init;
        begin
            p_session_init.processName := p_processName;
            p_session_init.logLevel := p_logLevel;
            p_session_init.daysToKeep := p_daysToKeep;
            p_session_init.proc_stepsToDo := null;
            p_session_init.tab_name_master := p_tabNameMaster;
        
            return new_session(p_session_init);
        end;
            
        --------------------------------------------------------------------------
            
        function extractFromJsonStr(p_json_doc varchar2, jsonPath varchar2) return varchar2
        as
        begin
            return JSON_VALUE(p_json_doc, '$.' || jsonPath);
        end;
        
        --------------------------------------------------------------------------
        
        function extractFromJsonNum(p_json_doc varchar2, jsonPath varchar2) return number
        as
        begin
            return JSON_VALUE(p_json_doc, '$.' || jsonPath returning NUMBER);
        exception 
            when others then return null; -- Oder Fehlerbehandlung
        end;
        
        --------------------------------------------------------------------------
        
        function extractFromJsonTime(p_json_doc varchar2, jsonPath varchar2) return TIMESTAMP
        as
        begin
            return JSON_VALUE(p_json_doc, '$.' || jsonPath returning TIMESTAMP);
        exception 
            when others then return null; -- Oder Fehlerbehandlung
        end;
       
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
            l_payload varchar2(1600);
        begin
            l_payload := JSON_QUERY(p_message, '$.payload');
            l_processId := extractFromJsonNum(l_payload, 'process_id');
            l_actionName := extractFromJsonStr(l_payload, 'action_name');
            l_contextName := extractFromJsonStr(l_payload, 'context_name');
            l_timestamp := extractFromJsonTime(l_payload, 'timestamp');
            l_monType := extractFromJsonNum(l_payload, 'monitor_type');
            
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
            l_payload varchar2(1600);
        begin
            l_payload := JSON_QUERY(p_message, '$.payload');
            l_processId := extractFromJsonNum(l_payload, 'process_id');
            l_actionName := extractFromJsonStr(l_payload, 'action_name');
            l_contextName := extractFromJsonStr(l_payload, 'context_name');
            l_timestamp := extractFromJsonTime(l_payload, 'timestamp');
            l_monType := extractFromJsonNum(l_payload, 'monitor_type');
            
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
            l_payload varchar2(1600);
        begin
            l_payload := JSON_QUERY(p_message, '$.payload');
            l_processId := extractFromJsonNum(l_payload, 'process_id');
            l_actionName := extractFromJsonStr(l_payload, 'action_name');
            l_contextName := extractFromJsonStr(l_payload, 'context_name');
            l_timestamp := extractFromJsonTime(l_payload, 'timestamp');
            l_monType := extractFromJsonNum(l_payload, 'monitor_type');
            
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
            l_payload varchar2(1600);
        begin
            l_payload := JSON_QUERY(p_message, '$.payload');
            l_processId     := extractFromJsonNum(l_payload, 'process_id');
            l_status        := extractFromJsonNum(l_payload, 'process_status');
            l_processInfo   := extractFromJsonStr(l_payload, 'process_info');
            l_stepsToDo     := extractFromJsonNum(l_payload, 'proc_steps_todo');
            l_procStepsDone := extractFromJsonNum(l_payload, 'proc_steps_done');
            l_immortal      := extractFromJsonNum(l_payload, 'process_immortal');
            
            setAnyStatus(l_processId, l_status, l_processInfo, l_stepsToDo, l_procStepsDone, l_immortal);
        end;
        --------------------------------------------------------------------------

        procedure doRemote_procStepDone(p_message varchar2)
        as
            l_processId     NUMBER;
            l_payload varchar2(1600);
        begin
            l_payload := JSON_QUERY(p_message, '$.payload');
            l_processId  := extractFromJsonNum(l_payload, 'process_id');
            
            PROC_STEP_DONE(l_processId);
        end;
        
        --------------------------------------------------------------------------
            
        procedure doRemote_logAny(p_message varchar2)
        as
            l_processId number;
            l_level number;
            l_logText varchar2(1000);
            l_errStack varchar2(1000);
            l_errBacktrace varchar2(1000);
            l_errCallstack varchar2(1000);
            l_payload varchar2(1600);
        begin
            l_payload := JSON_QUERY(p_message, '$.payload');
            l_processId := extractFromJsonNum(l_payload, 'process_id');
            l_level := extractFromJsonNum(l_payload, 'level');
            l_logText := extractFromJsonStr(l_payload, 'log_text');
            l_errStack := extractFromJsonStr(l_payload, 'err_stack');
            l_errBacktrace := extractFromJsonStr(l_payload, 'err_backtr');
            l_errCallstack := extractFromJsonStr(l_payload, 'err_callstack');
            
            log_any(l_processId, l_level, l_logText, l_errStack, l_errBacktrace, l_errCallstack);
        end;
    
        -------------------------------------------------------------------------- 
        
        procedure doRemote_closeSession(p_clientChannel varchar2, p_message VARCHAR2)
        as
            l_processId   number; 
            l_procStepsToDo   PLS_INTEGER; 
            l_procStepsDone   PLS_INTEGER; 
            l_processInfo varchar2(1000);
            l_status      PLS_INTEGER;
            l_payload varchar2(1600);
            l_header    varchar2(100);
            l_meta      varchar2(100);
            l_data      varchar2(1500);
            l_msg       VARCHAR2(4000);
        begin
            l_payload     := JSON_QUERY(p_message, '$.payload');
            l_processId   := extractFromJsonStr(l_payload, 'process_id');
            l_procStepsToDo   := extractFromJsonStr(l_payload, 'proc_steps_todo');
            l_procStepsDone   := extractFromJsonNum(l_payload, 'proc_steps_done');
            l_processInfo := extractFromJsonNum(l_payload, 'process_info');
            l_status      := extractFromJsonNum(l_payload, 'process_status');
            
            l_header := '"header":{"msg_type":"SERVER_RESPONSE", "msg_name":"CLOSE_SESSION"}';
            l_meta   := '"meta":{"server_version":"' || LILAM_VERSION || '"}';
            l_data   := '"payload":{"server_message":"' || TXT_ACK_OK || '","server_code": ' || get_serverCode(TXT_ACK_OK);
            l_msg := '{' || l_header || ', ' || l_meta || ', ' || l_data || '}';
    
            checkLogsBuffer(l_processId, 'vor CLOSE_SESSION');
    
            CLOSE_SESSION(l_processId, l_procStepsToDo, l_procStepsDone, l_processInfo, l_status);
            
            DBMS_PIPE.RESET_BUFFER; -- Koffer leeren
            DBMS_PIPE.PACK_MESSAGE('{"process_id":' || l_processId || '}');        
            l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 1);
    
        end;    
    
        -------------------------------------------------------------------------- 
            
        procedure doRemote_pingEcho(p_clientChannel varchar2, p_message VARCHAR2)
        as
            l_payload varchar2(1600);
            l_session_init t_session_init;
            l_status PLS_INTEGER;
            l_header varchar2(100);
            l_meta   varchar2(100);
            l_data   varchar2(100);
            l_msg    varchar2(500);
        begin
            l_header := '"header":{"msg_type":"SERVER_RESPONSE", "msg_name":"PING_ECHO"}';
            l_meta   := '"meta":{"server_version":"' || LILAM_VERSION || '"}';
            l_data   := '"payload":{"server_message":"' || TXT_PING_ECHO || '","server_code":' || get_serverCode(TXT_PING_ECHO);
            l_msg := '{' || l_header || ', ' || l_meta || ', ' || l_data || '}';
    
            -- no payload, client waits only for unfreezing
            DBMS_PIPE.RESET_BUFFER; -- Koffer leeren
            DBMS_PIPE.PACK_MESSAGE(l_msg);        
            l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 0);
            
        exception
            when others then
                null;
        end; 
        
        -------------------------------------------------------------------------- 

        procedure doRemote_getMonitorLastEntry(p_clientChannel varchar2, l_message varchar2)
        as 
            l_processId number;
            l_payload varchar2(32767);
            v_rec t_monitor_buffer_rec;
            l_status PLS_INTEGER;
            l_actionName varchar2(50);
            l_contextName varchar2(50);
            l_header varchar2(200);
            l_meta   varchar2(200);
            l_msg    varchar2(2000);
        begin
            l_processId := extractFromJsonNum(l_message, 'payload.process_id');
            l_actionName := extractFromJsonStr(l_message, 'payload.action_name');
            l_contextName := extractFromJsonStr(l_message, 'payload.context_name');
            
            v_rec := getLastMonitorEntry(l_processId, l_actionName, l_contextName);   
            select json_object(
                'process_id'        value v_rec.process_id,
                'action_name'      value v_rec.action_name,
                'action_count'         value v_rec.action_count,
                'used_time'     value v_rec.used_time,
                'start_time'       value v_rec.start_time,
                'stop_time'       value v_rec.stop_time,
                'avg_action_time'       value v_rec.avg_action_time
                returning varchar2
            )
            into l_payload from dual;   
  
            l_header := '"header":{"msg_type":"SERVER_RESPONSE", "msg_name":"LAST_MONITOR_ENTRY"}';
            l_meta   := '"meta":{"server_version":"' || LILAM_VERSION || '", "server_message":"' || TXT_DATA_ANSWER || '","server_code":' || get_serverCode(TXT_DATA_ANSWER) || '}';
            l_payload := '"payload":' || l_payload;
            l_msg := '{' || l_header || ', ' || l_meta || ', ' || l_payload || '}';
             
            -- no payload, client waits only for unfreezing
            DBMS_PIPE.RESET_BUFFER; -- Koffer leeren
            DBMS_PIPE.PACK_MESSAGE(l_msg);        
            l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 0);
            
        exception
            when others then
                dbms_output.enable();
                dbms_output.put_line('Fehler in doRemote_getMonitorLastEntry: ' || sqlErrM);
        end;    

        -------------------------------------------------------------------------- 

        procedure doRemote_getProcessData(p_clientChannel varchar2, l_message varchar2)
        as
            l_processId number;
            l_payload varchar2(32767);
            l_process_rec t_process_rec;
            l_status PLS_INTEGER;
            l_header varchar2(200);
            l_meta   varchar2(200);
            l_msg    varchar2(2000);
        begin
            l_processId := extractFromJsonNum(l_message, 'payload.process_id');
            l_process_rec := GET_PROCESS_DATA(l_processId);   

            select json_object(
                'process_id'        value l_process_rec.id,
                'process_name'      value l_process_rec.process_name,
                'log_level'         value l_process_rec.log_level,
                'process_start'     value l_process_rec.process_start,
                'process_end'       value l_process_rec.process_end,
                'last_update'       value l_process_rec.last_update,
                'process_info'      value l_process_rec.info,
                'process_status'    value l_process_rec.status,
                'proc_steps_todo'   value l_process_rec.proc_steps_todo,
                'proc_steps_done'   value l_process_rec.proc_steps_done,
                'tabname_master'    value l_process_rec.tab_name_master
                returning varchar2
            )
            into l_payload from dual;   
                        
            l_header := '"header":{"msg_type":"SERVER_RESPONSE", "msg_name":"PROCESS_DATA"}';
            l_meta   := '"meta":{"server_version":"' || LILAM_VERSION || '", "server_message":"' || TXT_DATA_ANSWER || '","server_code":' || get_serverCode(TXT_DATA_ANSWER) || '}';
            l_payload := '"payload":' || l_payload;
            l_msg := '{' || l_header || ', ' || l_meta || ', ' || l_payload || '}';
             
            -- no payload, client waits only for unfreezing
            DBMS_PIPE.RESET_BUFFER; -- Koffer leeren
            DBMS_PIPE.PACK_MESSAGE(l_msg);        
            l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 0);
            
        exception
            when others then
                dbms_output.enable();
                dbms_output.put_line('Fehler in doRemote_getProcessData: ' || sqlErrM);
        end;    

        -------------------------------------------------------------------------- 
        
        procedure doRemote_unfreezeClient(p_clientChannel varchar2, p_message VARCHAR2)
        as
            l_payload varchar2(1600);
            l_status PLS_INTEGER;
            l_header varchar2(100);
            l_meta   varchar2(100);
            l_data   varchar2(100);
            l_msg    varchar2(500);
        begin
            l_header := '"header":{"msg_type":"SERVER_RESPONSE", "msg_name":"UNFREEZE_CLIENT"}';
            l_meta   := '"meta":{"server_version":"' || LILAM_VERSION || '"}';
            l_data   := '"payload":{"server_message":"' || TXT_ACK_OK || '","server_code":' || get_serverCode(TXT_ACK_OK);
            l_msg := '{' || l_header || ', ' || l_meta || ', ' || l_data || '}';
    
            -- no payload, client waits only for unfreezing
            DBMS_PIPE.RESET_BUFFER; -- Koffer leeren
            DBMS_PIPE.PACK_MESSAGE(l_msg);        
            l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 0);
            
        exception
            when others then
                dbms_output.enable();
                dbms_output.put_line('Fehler in doRemote_unfreezeClient: ' || sqlErrM);
        end;    
        
        -------------------------------------------------------------------------- 
        
        procedure doRemote_newSession(p_clientChannel varchar2, p_message VARCHAR2)
        as
            l_processId number;
            l_payload varchar2(1600);
            l_session_init t_session_init;
            l_status PLS_INTEGER;
        begin
            l_payload := JSON_QUERY(p_message, '$.payload');
            l_processId := extractFromJsonNum(l_payload, 'process_id');
            l_session_init.processName := extractFromJsonStr(l_payload, 'process_name');
            l_session_init.logLevel    := extractFromJsonNum(l_payload, 'log_level');
            l_session_init.proc_stepsToDo   := extractFromJsonNum(l_payload, 'proc_steps_todo');
            l_session_init.daysToKeep  := extractFromJsonNum(l_payload, 'days_to_keep');
            l_session_init.tab_name_master := extractFromJsonStr(l_payload, 'tabname_master');
    
            l_processId := NEW_SESSION(l_session_init);
            DBMS_PIPE.RESET_BUFFER; -- Koffer leeren
            DBMS_PIPE.PACK_MESSAGE('{"process_id":' || l_processId || '}');        
            l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 1);
        end;    
    
        -------------------------------------------------------------------------- 
    
        procedure SHUTDOWN_ALL_SERVERS
        as
            l_pipeName varchar2(100);
            l_response  varchar2(500);
            l_header varchar2(100);
            l_meta   varchar2(50);
            l_data   varchar2(50);
            l_msg    varchar2(250);
        begin
            l_header := '"header":{"msg_type":"CLIENT_REQUEST", "request":"SERVER_SHUTDOWN"}';
            l_meta   := '"meta":{}';
            l_data   := '"payload":{}';
            
            l_msg := '{' || l_header || ', ' || l_meta || ', ' || l_data || '}';
    
        end;
        
        -------------------------------------------------------------------------- 
        
        PROCEDURE SERVER_UPDATE_RULES(p_processId NUMBER, p_ruleSetName VARCHAR2, p_ruleSetVersion PLS_INTEGER)
        as
            l_message  varchar2(200);
            l_serverCode PLS_INTEGER;
            l_slotIdx    PLS_INTEGER;
        begin
            l_message := '{"rule_set_name":"' || p_ruleSetName || '", "rule_set_version":"' || p_ruleSetVersion || '"}';
            sendNoWait(p_processId, 'UPDATE_RULE', l_message, C_TIMEOUT_NEW_SESSION);               
        end;
        
        -------------------------------------------------------------------------- 

        procedure SERVER_SHUTDOWN(p_processId number, p_pipeName varchar2, p_password varchar2)
        as
            l_response varchar2(1000);
            l_message  varchar2(200);
            l_payload  varchar2(500);
            l_serverCode PLS_INTEGER;
            l_slotIdx    PLS_INTEGER;
        begin
            l_message := '{"pipe_name":"' || p_pipeName || '", "shutdown_password":"' || p_password || '"}';
            l_response := waitForResponse(
                p_processId     => p_processId,
                p_request       => 'SERVER_SHUTDOWN',
                p_payload       => l_message,
                p_timeoutSec    => 5
            );
            l_payload := JSON_QUERY(l_response, '$.payload');
            l_serverCode := extractFromJsonStr(l_payload, 'server_code');
            
            if l_serverCode = NUM_ACK_SHUTDOWN then
                null;
            end if ;
        end;
    
        
        procedure SERVER_SEND_ANY_MSG(p_processId number, p_message varchar2)
        as
            l_response varchar2(1000);
        begin
            l_response := waitForResponse(
                p_processId     => p_processId,
                p_request       => 'ANY_MSG',
                p_payload       => p_message,
                p_timeoutSec    => 5
            );
        end;

        --------------------------------------------------------------------------

        FUNCTION GET_SERVER_PIPE(p_processId NUMBER) RETURN VARCHAR2
        as
        begin
            return getServerPipeForSession(p_processId, null);
        end;

        --------------------------------------------------------------------------
        
        FUNCTION SERVER_NEW_SESSION(p_processName varchar2, p_logLevel PLS_INTEGER, p_procStepsToDo PLS_INTEGER, p_daysToKeep PLS_INTEGER, p_tabNameMaster varchar2) RETURN VARCHAR2
        as
            l_payload    varchar2(1000);
        begin
            l_payload := '{"process_name":"' || p_processName  || '", "log_level":' || p_logLevel || ', "proc_steps_todo":' || 
                            p_procStepsToDo || ', "days_to_keep":' || p_daysToKeep || ', "tabname_master":"' || p_tabNameMaster || '"}';                            
            return server_new_session(l_payload);
        end;

        --------------------------------------------------------------------------
        
        FUNCTION SERVER_NEW_SESSION(p_processName varchar2, p_groupName VARCHAR2, p_logLevel PLS_INTEGER, p_procStepsToDo PLS_INTEGER, p_daysToKeep PLS_INTEGER, p_tabNameMaster varchar2) RETURN VARCHAR2
        as
            l_payload    varchar2(1000);
        begin
            l_payload := '{"process_name":"' || p_processName  || '", "group_name":"' || p_groupName || '", "log_level":' || p_logLevel || ', "proc_steps_todo":' || 
                            p_procStepsToDo || ', "days_to_keep":' || p_daysToKeep || ', "tabname_master":"' || p_tabNameMaster || '"}';                            
            return server_new_session(l_payload);
        end;
        
        --------------------------------------------------------------------------

        FUNCTION SERVER_NEW_SESSION(p_jasonString varchar2) RETURN NUMBER
        as
            l_ProcessId number(19,0) := -500;   
            l_payload   varchar2(1000);
            l_response  varchar2(100);        
        begin                        
            -- zunächst mal schauen, welche Server bereitstehen
            l_response := waitForResponse(null, 'NEW_SESSION', p_jasonString, C_TIMEOUT_NEW_SESSION);
            
            CASE
                WHEN l_response = 'TIMEOUT' THEN
                    l_ProcessId := -110;
                WHEN l_response = 'THROTTLED' THEN
                    l_ProcessId := -120;                
                WHEN l_response LIKE 'ERROR%' THEN
                    l_ProcessId := - 100;
                else
                -- Erfolgsfall: JSON parsen
                l_ProcessId := extractFromJsonNum(l_response, 'process_id');
            end case;
    
            -- Nur valide IDs registrieren
            if l_ProcessId > 0 THEN
                g_client_pipes(l_ProcessId) := g_client_pipes(C_PIPE_ID_PENDING);
                g_client_pipes.DELETE(C_PIPE_ID_PENDING);
                g_remote_sessions(l_ProcessId) := TRUE; -- in die Liste der RemoteSessions eintragen
            end if ;
            RETURN l_ProcessId;
            
        EXCEPTION
            WHEN OTHERS THEN
            raise;
            return -200;
        end;
        --------------------------------------------------------------------------
                
        PROCEDURE DUMP_BUFFER_STATS AS
            v_key VARCHAR2(100);
            v_log_total NUMBER := 0;
            v_mon_total NUMBER := 0;
        BEGIN
        dbms_output.enable();
        
            -- 1. Logs zählen
            v_key := g_log_groups.FIRST;
            WHILE v_key IS NOT NULL LOOP
                v_log_total := v_log_total + g_log_groups(v_key).COUNT;
                v_key := g_log_groups.NEXT(v_key);
            END LOOP;
        
            -- 2. Monitore zählen
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
            l_payload varchar2(500); 
            l_header  varchar2(200);
            l_meta    varchar2(200);
            l_data    varchar2(200);
            l_msg     varchar2(2000);
        begin
        
            l_payload     := JSON_QUERY(p_message, '$.payload');
            l_password   := extractFromJsonStr(l_payload, 'shutdown_password');
            
            l_header := '"header":{"msg_type":"SERVER_RESPONSE", "msg_name":"SERVER_SHUTDOWN"}';
            l_meta   := '"meta":{"server_version":"' || LILAM_VERSION || '"}';
    
            if l_password = g_shutdownPassword then            
                l_data   := '"payload":{"server_message":"' || TXT_ACK_SHUTDOWN || '","server_code": ' || get_serverCode(TXT_ACK_SHUTDOWN);
            else
                l_data   := '"payload":{"server_message":"' || TXT_ACK_DECLINE || '","server_code": ' || get_serverCode(TXT_ACK_DECLINE);
            end if ;
            l_msg := '{' || l_header || ', ' || l_meta || ', ' || l_data || '}';
    
            DBMS_PIPE.RESET_BUFFER;
            DBMS_PIPE.PACK_MESSAGE(l_msg);        
            l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 1);
            
            if l_status = 0 THEN
                dbms_output.put_line('Antwort an Client gesendet.');
            ELSE
                dbms_output.put_line('Fehler beim Senden der Antwort: ' || l_status);
            end if ;
            
            return l_password = g_shutdownPassword;
        end;
        
        --------------------------------------------------------------------------
    
        FUNCTION CREATE_SERVER(p_password varchar2) RETURN VARCHAR2
        as
            l_slot_idx PLS_INTEGER;
            l_job_name VARCHAR2(30);
            l_pipe     VARCHAR2(30);
            l_action   VARCHAR2(1000);
        BEGIN
            -- 1. WICHTIG: Erst schauen, was draußen wirklich los ist!
            -- Aktualisiert g_pipe_pool(i).is_active via Ping/Antwort
            l_job_name := 'LILAM_SRV_SLOT_' || l_slot_idx;
            
                -- 2. Sicherstellen, dass kein "Leichen"-Job existiert
            BEGIN
                DBMS_SCHEDULER.DROP_JOB(l_job_name, force => TRUE);
            EXCEPTION WHEN OTHERS THEN NULL; END;
        
            l_action := q'[BEGIN LILAM.START_SERVER(p_pipeName => ']' 
                        || l_pipe 
                        || q'[', p_password => ']' 
                        || p_password 
                        || q'['); END;]';     
    
            -- 3. Den Hintergrund-Prozess "zünden"
            DBMS_SCHEDULER.CREATE_JOB (
                job_name   => l_job_name,
                job_type   => 'PLSQL_BLOCK',
                -- Hier übergeben wir den Slot-Namen als Parameter an deine START_SERVER Prozedur
                job_action => l_action,
                enabled    => TRUE,
                auto_drop  => TRUE,
                comments   => 'LILAM Background Worker für Pipe ' || l_pipe
            );
                
            RETURN 'LILAM-Server Pipe = ' || l_pipe;
        END;
        
        --------------------------------------------------------------------------
        
        function isServerPipeRegistered(p_pipeName varchar2) return BOOLEAN
        as
            l_exists INTEGER;
            l_sqlStmt varchar2(200);
        begin
            l_sqlStmt := '
            SELECT COUNT(*)
            FROM ' || C_LILAM_SERVER_REGISTRY || '
            WHERE pipe_name = ''' || p_pipeName || '''
            AND rownum = 1'; -- Bricht nach dem ersten Treffer ab
            execute immediate l_sqlStmt into l_exists;
        
            IF l_exists > 0 THEN
                -- Server existiert
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
                    current_load = 0
                where pipe_name = :1';            
                execute immediate l_sqlStmt using g_serverPipeName;
            else
                    -- new entry, server was not registered yet
                l_sqlStmt := '
                insert into ' || C_LILAM_SERVER_REGISTRY || ' (
                    pipe_name,
                    group_name,
                    last_activity,
                    is_active,
                    current_load
                ) values (
                    :1,
                    :2,
                    SYSTIMESTAMP,
                    1,
                    0
                )';
                execute immediate l_sqlStmt using g_serverPipeName, g_serverGroupName;
            end if;
            commit;
        
        exception
            when others then
                raise;
                rollback;
        end;
        
        --------------------------------------------------------------------------
        
        PROCEDURE load_rules_from_json(p_ruleSet CLOB) IS
            pragma autonomous_transaction; 
            l_payload varchar2(1000);
        BEGIN
            -- Zuerst die alten Regeln löschen (Reset)
            g_rules_by_context.DELETE;
            g_rules_by_action.DELETE;
            g_alert_history.DELETE;

            FOR r IN (
                SELECT *
                FROM JSON_TABLE(p_ruleSet, '$.rules[*]'
                    COLUMNS (
                        rule_id      VARCHAR2(20) PATH '$.id',
                        trigger_t    VARCHAR2(20) PATH '$.trigger_type',
                        action       VARCHAR2(50) PATH '$.action',
                        context      VARCHAR2(50) PATH '$.context',
                        metric       VARCHAR2(30) PATH '$.condition.metric',
                        operator     VARCHAR2(30) PATH '$.condition.operator',
                        value        VARCHAR2(50) PATH '$.condition.value',
                        handler      VARCHAR2(50) PATH '$.alert.handler',
                        severity     VARCHAR2(20) PATH '$.alert.severity',
                        throttle_sec NUMBER       PATH '$.alert.throttle_seconds'
                    )
                )
            ) LOOP
                -- Record vorbereiten
                DECLARE
                    l_new_rule t_rule_rec;
                    l_key      VARCHAR2(250);
                BEGIN
                    l_new_rule.rule_id            := r.rule_id;
                    l_new_rule.trigger_type       := r.trigger_t;
                    l_new_rule.target_action      := r.action;
                    l_new_rule.target_context     := r.context;
                    l_new_rule.condition_metric   := r.metric;
                    l_new_rule.condition_operator := r.operator;
                    l_new_rule.condition_value    := r.value;
                    l_new_rule.alert_handler      := r.handler;
                    l_new_rule.alert_severity     := r.severity;
                    l_new_rule.throttle_seconds   := r.throttle_sec;
        
                    -- Entscheidung: Kontext-Regel oder allgemeine Action-Regel?
                    IF r.context IS NOT NULL THEN
                        l_key := r.action || '|' || r.context;
                        IF NOT g_rules_by_context.EXISTS(l_key) THEN
                            g_rules_by_context(l_key) := t_rule_list();
                        END IF;
                        g_rules_by_context(l_key).EXTEND;
                        g_rules_by_context(l_key)(g_rules_by_context(l_key).LAST) := l_new_rule;
                    ELSE
                        l_key := r.action;
                        IF NOT g_rules_by_action.EXISTS(l_key) THEN
                            g_rules_by_action(l_key) := t_rule_list();
                        END IF;
                        g_rules_by_action(l_key).EXTEND;
                        g_rules_by_action(l_key)(g_rules_by_action(l_key).LAST) := l_new_rule;                       
                    END IF;
                END;
            END LOOP;
            
            -- Version aus dem Header extrahieren (optionaler zweiter Schritt)
            l_payload := JSON_QUERY(p_ruleSet, '$.header');
            g_current_rule_set_name := extractFromJsonStr(l_payload, 'rule_set');
            g_current_rule_set_version := extractFromJsonNum(l_payload, 'rule_set_version');
            
            execute immediate 'update ' || C_LILAM_SERVER_REGISTRY || ' set rule_set_name = :1, set_in_use = :2 where pipe_name = :3'
            using g_current_rule_set_name, g_current_rule_set_version, g_serverPipeName;
            commit;
        
        EXCEPTION
            WHEN OTHERS THEN
            raise;
                lilam.error(g_serverProcessId, g_serverPipeName || '=>Failed to parse JSON rules: ' || SQLERRM);
                rollback;
        END;
        
        --------------------------------------------------------------------------

        function existsNewServerRule(p_pipeName varchar2) return boolean
        as
            l_newestVersion PLS_INTEGER;
            l_sqlStmt varchar2(200);
        begin
            l_sqlStmt := 'SELECT rule_version FROM ' || C_LILAM_SERVER_REGISTRY || ' WHERE pipe_name = :1';
            execute immediate l_sqlStmt into l_newestVersion using p_pipeName;
            if nvl(l_newestVersion, 0) > g_current_rule_set_version then 
                return TRUE;
            else
                return FALSE;
            end if;
            
        exception
            when NO_DATA_FOUND then
                return false;
        end;

        --------------------------------------------------------------------------
        
        procedure readServerRules(p_ruleSetName varchar2, p_ruleSetVersion Number)
        as
            l_sqlStmt varchar2(200);
            l_serverRuleSet CLOB;
        begin
            l_sqlStmt := 'SELECT rule_set FROM ' || C_LILAM_RULES || ' where set_name = :1 and version = :2';
            execute immediate l_sqlStmt into l_serverRuleSet using p_ruleSetName, p_ruleSetVersion;
            
            load_rules_from_json(l_serverRuleSet);
            
        exception
            when NO_DATA_FOUND then
                error(g_serverProcessId, g_serverPipeName || '=>Could not find server rule: ' || p_ruleSetName || '; version: ' || p_ruleSetVersion);
            when others then
                raise;
        end;
        
        --------------------------------------------------------------------------

        procedure loadServerRules
        as
            l_sqlStmt varchar2(200);
            l_ruleSetName varchar2(30);
            l_ruleSetVersion PLS_INTEGER;
        begin
            l_sqlStmt := 'SELECT rule_set_name, set_in_use FROM ' || C_LILAM_SERVER_REGISTRY || ' WHERE pipe_name = ''' || g_serverPipeName || '''';
            execute immediate l_sqlStmt into l_ruleSetName,  l_ruleSetVersion;
            if l_ruleSetName is not null then
                readServerRules(l_ruleSetName, l_ruleSetVersion);
            end if;
            
        exception
            when NO_DATA_FOUND then
                null; -- in der Registry smüssen für den Server keine Rules hinterlegt sein
            when others then
                raise;
        end;
        
        --------------------------------------------------------------------------
        
        procedure updateServerRules(l_message varchar2)
        as
            l_payload  VARCHAR2(100);
            l_ruleSetName varchar2(30);
            l_ruleSetVersion PLS_INTEGER;
        begin

            l_payload     := JSON_QUERY(l_message, '$.payload');
            l_ruleSetName := extractFromJsonStr(l_payload, 'rule_set_name');
            l_ruleSetVersion := extractFromJsonNum(l_payload, 'rule_set_version');
            
            readServerRules(l_ruleSetName, l_ruleSetVersion);
        end;
    
        --------------------------------------------------------------------------

        procedure updateServerRegistry(p_ready BOOLEAN, p_eventCounter PLS_INTEGER)
        as
            pragma autonomous_transaction; 
            l_sqlStmt varchar2(500);
            l_booleanAsInt NUMBER(1);
            l_status    varchar2(20);
        begin
            case p_ready
                when true then l_booleanAsInt := 1;
                when false then l_booleanAsInt := 0;
            end case;
            
            case p_eventCounter
                when > 0 then
                    if p_ready then
                        l_status := 'PROCESSING';
                        DBMS_APPLICATION_INFO.SET_ACTION('PROCESSING');
                        DBMS_APPLICATION_INFO.SET_CLIENT_INFO('Bulk Load:' || p_eventCounter);
                    else
                        l_status := 'SHUTDOWN';
                        DBMS_APPLICATION_INFO.SET_ACTION('SHUTDOWN');
                        DBMS_APPLICATION_INFO.SET_CLIENT_INFO('Time:' || systimestamp);
                    end if;
                    
                when 0 then
                    if p_ready then
                        l_status := 'PENDING';
                        DBMS_APPLICATION_INFO.SET_ACTION('PENDING');
                        DBMS_APPLICATION_INFO.SET_CLIENT_INFO('Time:' || systimestamp);
                    else
                        l_status := 'STOPPED';
                        DBMS_APPLICATION_INFO.SET_MODULE(NULL, NULL);
                    end if;
                    
                when -1 then
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
                current_load = (SELECT pipe_size FROM v$db_pipes WHERE name = :2),
                status = :3,
                processing = :4
            WHERE pipe_name = :5';
            execute immediate l_sqlStmt using l_booleanAsInt, g_serverPipeName, l_status, p_ready, g_serverPipeName;
            COMMIT; -- Muss autonom sein!
            
        exception
            when others then
                rollback;
                raise;
        end;
        
        --------------------------------------------------------------------------
        
        function receiveMessage(l_pipeName varchar2) return varchar2
        as
            l_status    PLS_INTEGER;
            l_message   VARCHAR2(32767);
            l_stop_server_exception EXCEPTION;            
        begin
            l_status := DBMS_PIPE.RECEIVE_MESSAGE(l_pipeName, timeout => C_SERVER_TIMEOUT_WAIT_FOR_MSG);
            
            if l_status = 0 THEN
                begin   
                    DBMS_PIPE.UNPACK_MESSAGE(l_message);
                    return l_message;
                    
                    EXCEPTION
                        WHEN l_stop_server_exception THEN
                            -- Diese Exception wird NICHT hier abgefangen, 
                            -- sondern nach außen an den Loop gereicht.
                            RAISE;
                        WHEN OTHERS THEN
                            -- WICHTIG: Fehler loggen, aber die Schleife NICHT verlassen!
                            raise;
                            ERROR(g_serverProcessId, g_serverPipeName || '=>Internal START_SERVER; Critical Error while processing command: ' || SQLERRM);
                    END; 
            else
                return null;
            end if;
        end;
        
        --------------------------------------------------------------------------

        procedure preparePipe(p_pipeName varchar2)
        as
            l_dummyRes PLS_INTEGER;
        begin
            DBMS_PIPE.RESET_BUFFER;
            DBMS_PIPE.PURGE(p_pipeName);
            l_dummyRes := DBMS_PIPE.REMOVE_PIPE(p_pipeName);
            l_dummyRes := DBMS_PIPE.REMOVE_PIPE(p_pipeName || C_INTERLEAVE_PIPE_SUFFIX);
            l_dummyRes := DBMS_PIPE.CREATE_PIPE(pipename => p_pipeName, maxpipesize => C_MAX_SERVER_PIPE_SIZE, private => false);
        end;
            
        --------------------------------------------------------------------------
        
        function processRequest(p_request varchar2, p_message varchar2, p_clientChannel varchar2) return boolean
        as
        begin
            CASE p_request
                WHEN 'SERVER_SHUTDOWN' then
                    if handleServerShutdown(p_clientChannel, p_message) then 
                        -- nur wenn gültiges Passwort geschickt wurde
--                        l_shutdownSignal := TRUE;
                        INFO(g_serverProcessId, g_serverPipeName || '=> Shutdown by remote request');
                        return true; -- Abbruchsignal
                    end if ;
                    
                WHEN 'UPDATE_RULE' then
                    updateServerRules(p_message);
                    
                WHEN 'SERVER_PING' then
                null;
                
                WHEN 'NEW_SESSION' THEN
                    INFO(g_serverProcessId, g_serverPipeName || '=> New remote session ordered');
                    doRemote_newSession(p_clientChannel, p_message);
                    
                WHEN 'CLOSE_SESSION' THEN
                    INFO(g_serverProcessId, g_serverPipeName || '=> Remote session closed');
                    doRemote_closeSession(p_clientChannel, p_message);

                WHEN 'LOG_ANY' then
                    doRemote_logAny(p_message);
                    
                WHEN 'SET_ANY_STATUS' then
                    doRemote_setAnyStatus(p_message);
                    
                WHEN 'PROC_STEP_DONE' then
                    doRemote_procStepDone(p_message);
                    
                WHEN 'GET_PROCESS_DATA' then
                    doRemote_getProcessData(p_clientChannel, p_message);
                    
                WHEN 'MARK_EVENT' then
                    doRemote_markEvent(p_message);
                    
                WHEN 'START_TRACE' then
                    doRemote_startTrace(p_message);
                    
                WHEN 'STOP_TRACE' then
                    doRemote_stopTrace(p_message);
                    
                WHEN 'GET_MONITOR_LAST_ENTRY' then
                    doRemote_getMonitorLastEntry(p_clientChannel, p_message);
                    
                WHEN 'UNFREEZE_REQUEST' then
                    doRemote_unfreezeClient(p_clientChannel, p_message);
                    
                ELSE 
                    -- Unbekanntes Tag loggen
                    warn(g_serverProcessId, g_serverPipeName || '=> Received unknown request: ' || p_request);
            END CASE;

            return false; -- kein Abbruchsignal
        end;
    
        --------------------------------------------------------------------------

        procedure START_SERVER(p_pipeName varchar2, p_groupName varchar2, p_password varchar2)
        as
            v_key            VARCHAR2(100); 
            l_clientChannel  varchar2(50);
            l_message        VARCHAR2(32767);
            l_status         PLS_INTEGER;
            l_request        VARCHAR2(500);
            l_json_doc       VARCHAR2(2000);        
            l_dummyRes       PLS_INTEGER;
            l_shutdownSignal BOOLEAN := FALSE;
            l_stop_server_exception EXCEPTION;            
            l_pipe           VARCHAR2(50) := p_pipeName;
            l_lastHeartbeat  TIMESTAMP := sysTimestamp;
            l_lastSync       TIMESTAMP := sysTimestamp;  
            l_loopCounter    PLS_INTEGER := 0;
            l_msgCnt         PLS_INTEGER := 0;
        begin
            g_shutdownPassword := p_password;
            g_serverPipeName := l_pipe;
            g_serverGroupName := p_groupName;
            g_serverProcessId := new_session('LILAM_REMOTE_SERVER', logLevelDebug);
            registerServerPipe;
            preparePipe(g_serverPipeName);
            loadServerRules;
            updateServerRegistry(TRUE, 0);
            DBMS_APPLICATION_INFO.SET_MODULE(
                module_name => 'LILAM_SERVER ' || g_serverPipeName, 
                action_name => 'STARTUP'
            );

            LOOP
                -- Warten auf die nächste Nachricht (Timeout in Sekunden)
                l_message := receiveMessage(g_serverPipeName);    
                if l_message is not null THEN
                    l_msgCnt := l_msgCnt + 1;
                BEGIN 
                    l_clientChannel := extractClientChannel(l_message);
                    l_request := extractClientRequest(l_message);
                    l_shutdownSignal := processRequest(l_request, l_message, l_clientChannel);
/*
                    CASE l_request
                        WHEN 'SERVER_SHUTDOWN' then
                            if handleServerShutdown(l_clientChannel, l_message) then 
                                -- nur wenn gültiges Passwort geschickt wurde
                                l_shutdownSignal := TRUE;
                                INFO(g_serverProcessId, g_serverPipeName || '=> Shutdown by remote request');
                            end if ;
                            
                        WHEN 'UPDATE_RULE' then
                            updateServerRules(l_message);
                            
                        WHEN 'SERVER_PING' then
                        null;
                        
                        WHEN 'NEW_SESSION' THEN
                            INFO(g_serverProcessId, g_serverPipeName || '=> New remote session ordered');
                            doRemote_newSession(l_clientChannel, l_message);
                            
                        WHEN 'CLOSE_SESSION' THEN
                            INFO(g_serverProcessId, g_serverPipeName || '=> Remote session closed');
                            doRemote_closeSession(l_clientChannel, l_message);
    
                        WHEN 'LOG_ANY' then
                            doRemote_logAny(l_message);
                            
                        WHEN 'SET_ANY_STATUS' then
                            doRemote_setAnyStatus(l_message);
                            
                        WHEN 'PROC_STEP_DONE' then
                            doRemote_procStepDone(l_message);
                            
                        WHEN 'GET_PROCESS_DATA' then
                            doRemote_getProcessData(l_clientChannel, l_message);
                            
                        WHEN 'MARK_EVENT' then
                            doRemote_markEvent(l_message);
                            
                        WHEN 'START_TRACE' then
                            doRemote_startTrace(l_message);
                            
                        WHEN 'STOP_TRACE' then
                            doRemote_stopTrace(l_message);
                            
                        WHEN 'GET_MONITOR_LAST_ENTRY' then
                            doRemote_getMonitorLastEntry(l_clientChannel, l_message);
                            
                        WHEN 'UNFREEZE_REQUEST' then
                            doRemote_unfreezeClient(l_clientChannel, l_message);
                            
                        ELSE 
                            -- Unbekanntes Tag loggen
                            warn(g_serverProcessId, g_serverPipeName || '=> Received unknown request: ' || l_request);
                    END CASE;
*/    
                    EXCEPTION
                        WHEN l_stop_server_exception THEN
                            -- Diese Exception wird NICHT hier abgefangen, 
                            -- sondern nach außen an den Loop gereicht.
                            RAISE;
                            
                        WHEN OTHERS THEN
                            -- WICHTIG: Fehler loggen, aber die Schleife NICHT verlassen!
                            raise;
                            ERROR(g_serverProcessId, g_serverPipeName || '=>Internal START_SERVER; Critical Error while processing command: ' || SQLERRM);
                    END; 
                end if;
                
                if l_message is null or l_loopCounter > C_SERVER_MAX_LOOPS_IN_TIME then
                    if get_ms_diff(l_lastSync, sysTimestamp) >= C_SEVER_SYNC_INTERVAL  THEN
                        -- Housekeeping
                        SYNC_ALL_DIRTY;
                        updateServerRegistry(TRUE, l_msgCnt);
                        l_lastSync := sysTimestamp;
                        l_loopCounter := 0;
                        l_msgCnt := 0;
                    end if;
                    
                    -- Timeout erreicht. Passiert, wenn 10 Sekunden kein Signal kam.
                    if get_ms_diff(l_lastHeartbeat, sysTimestamp) >= C_SERVER_HEARTBEAT_INTERVAL then
                        INFO(g_serverProcessId, g_serverPipeName || 'HEARTBEAT ' || g_serverPipeName);
                        l_lastHeartbeat := sysTimestamp;
                    end if ;
                end if ;
                
                EXIT when l_shutdownSignal;
                l_loopCounter := l_loopCounter + 1;
            END LOOP;
            -- Ab jetzt ist der Server nicht mehr erreichbar
            updateServerRegistry(FALSE, l_msgCnt);
            
            -- +++ NEU: DRAIN-PHASE +++
            -- Wir leeren die Pipe, falls während des Shutdowns noch Nachrichten reinkamen.
            LOOP
                l_status := DBMS_PIPE.RECEIVE_MESSAGE(g_serverPipeName, timeout => 0.1);
                EXIT WHEN l_status != 0; -- Pipe ist leer (1) oder Fehler/Interrupt (!=0)
                
                DBMS_PIPE.UNPACK_MESSAGE(l_message);
                l_clientChannel := extractClientChannel(l_message);
                l_request := extractClientRequest(l_message);
                
                -- Im Drain verarbeiten wir nur noch Log-Daten, keine neuen Sessions/Shutdowns
                if l_request IN ('LOG_ANY', 'MARK_EVENT', 'UNFREEZE_REQUEST') THEN
                    l_shutdownSignal := processRequest(l_request, l_message, l_clientChannel);
/*
                    CASE l_request
                        WHEN 'LOG_ANY' then
                            doRemote_logAny(l_message);
                            
                        WHEN 'MARK_EVENT' then
                            doRemote_markEvent(l_message);
                            
                        WHEN 'UNFREEZE_REQUEST' then
                            doRemote_unfreezeClient(l_clientChannel, l_message);
    
                    END CASE;
*/
                end if ;
            END LOOP;
            
            DBMS_OUTPUT.ENABLE();
            
            -- es könnten noch dirty buffered Einträge existieren
            sync_all_dirty(true, true);
            
            if g_serverProcessId != -1 THEN
                DBMS_OUTPUT.PUT_LINE('Finaler Cleanup für Server-ID: ' || g_serverProcessId);
                clearServerData;
                clearAllSessionData(g_serverProcessId);
            end if ;
    
            DBMS_PIPE.PURGE(g_serverPipeName); 
            l_dummyRes := DBMS_PIPE.REMOVE_PIPE(g_serverPipeName);
            DBMS_PIPE.PURGE(g_serverPipeName || C_INTERLEAVE_PIPE_SUFFIX);
            l_dummyRes := DBMS_PIPE.REMOVE_PIPE(g_serverPipeName || C_INTERLEAVE_PIPE_SUFFIX);
            g_remote_sessions.DELETE;
            
            -- abschließende Analyse der Buffer-Zustände
            DUMP_BUFFER_STATS;
    
            close_session(g_serverProcessId);
            updateServerRegistry(FALSE, 0);
            
        EXCEPTION
        WHEN l_stop_server_exception THEN
            -- Hier landen wir nur, wenn der Server gezielt beendet werden soll
            DBMS_OUTPUT.PUT_LINE('Err: ' || sqlerrm);
            ERROR(g_serverProcessId, g_serverPipeName || '=>Internal START_SERVER; Critical Error while processing command: ' || SQLERRM);
            
            CLOSE_SESSION(g_serverProcessId);
        
        WHEN OTHERS THEN
            DBMS_PIPE.PURGE(g_serverPipeName); 
            l_dummyRes := DBMS_PIPE.REMOVE_PIPE(g_serverPipeName);
            DBMS_PIPE.PURGE(g_serverPipeName || C_INTERLEAVE_PIPE_SUFFIX);
            l_dummyRes := DBMS_PIPE.REMOVE_PIPE(g_serverPipeName || C_INTERLEAVE_PIPE_SUFFIX);
            clearServerData;
            clearAllSessionData(g_serverProcessId);
            updateServerRegistry(FALSE, -1);
            raise;
        end;
    
        ------------------------------------------------------------------------
        
        PROCEDURE IS_ALIVE
        as
            pProcessName number(19,0);
        begin
            pProcessName := new_session('LILAM Life Check', logLevelDebug);
            debug(pProcessName, 'First Message of LILAM');
            close_session(pProcessName, 1, 1, 'OK', 1);
        end;
    
    END LILAM;
