CREATE OR REPLACE PACKAGE BODY LILAM_CONSUMER AS

    FUNCTION readJsonRule(p_alert_rec t_alert_rec) RETURN t_json_rec
    as
        l_json_rec t_json_rec;
    begin
        -- Regel-Details aus LILAM_RULES extrahieren
        SELECT jt.id, jt.trigger_type, jt.action, jt.condition_operator,
            jt.condition_value, jt.alert_handler, jt.alert_severity, jt.alert_throttle
        INTO  l_json_rec.id, l_json_rec.trigger_type, l_json_rec.action, l_json_rec.condition_operator,
            l_json_rec.condition_value, l_json_rec.alert_handler, l_json_rec.alert_severity, l_json_rec.alert_throttle
        FROM LILAM_RULES lr,
             JSON_TABLE(lr.rule_set, '$.rules[*]'
                COLUMNS (
                    id                  varchar2 PATH '$.id',
                    trigger_type        varchar2 PATH '$.trigger_type',
                    action              varchar2 PATH '$.action',
                    condition_operator  varchar2 PATH '$.condition.operator',
                    condition_value     varchar2 PATH '$.condition.value',
                    alert_handler       varchar2 PATH '$.alert.handler',
                    alert_severity      varchar2 PATH '$.alert.severity',
                    alert_throttle      number   PATH '$.alert.throttle'
                )
             ) jt
        WHERE lr.set_name = p_alert_rec.rule_set_name
          AND lr.version  = p_alert_rec.rule_set_version
          AND jt.id      = p_alert_rec.rule_id;

        return l_json_rec;
    end;
    
    FUNCTION readProcessData(p_processId NUMBER, p_action VARCHAR2, p_actionCount PLS_INTEGER, p_procTabName VARCHAR2, p_monitorTabName VARCHAR2) RETURN t_lilam_rec
    as
        l_lilam_rec t_lilam_rec;
    begin
        -- Da die Tabellennamen variabel sind, nutzen wir EXECUTE IMMEDIATE
        EXECUTE IMMEDIATE 
            'SELECT master.id, master.process_name, master.status,
                master.info, master.process_start, master.process_end,
                master.proc_steps_todo, master.proc_steps_done, monitor.mon_type,
                monitor.action, monitor.context,monitor.start_time, monitor.stop_time,
                monitor.action_count, monitor.used_millis, monitor.avg_millis
             FROM ' || p_procTabName || ' master
             LEFT JOIN ' || p_monitorTabName || ' monitor
                ON master.id = monitor.process_id
                AND monitor.action = :1
                AND monitor.action_count = :2
             WHERE master.id = :3'
        INTO l_lilam_rec.processId, l_lilam_rec.processName, l_lilam_rec.status,
            l_lilam_rec.info, l_lilam_rec.processStart, l_lilam_rec.processEnd,
            l_lilam_rec.stepsTodo, l_lilam_rec.stepsDone,
            l_lilam_rec.monitorType, l_lilam_rec.actionName, l_lilam_rec.contextName,
            l_lilam_rec.actionStart, l_lilam_rec.actionStop, l_lilam_rec.actionCount,
            l_lilam_rec.usedMillis,l_lilam_rec.avgMillis      
        USING p_action, p_actionCount, p_processId;
        
        return l_lilam_rec;
    end;
    
    PROCEDURE updateAlert(p_alertId NUMBER)
    as
        sqlStmt VARCHAR2(400);
    begin
        UPDATE LILAM_ALERTS SET status = 'PROCESSED', processed_at = systimestamp WHERE alert_id = p_alertId;
        
        EXCEPTION
            WHEN OTHERS THEN
            declare
                v_err_msg CLOB := SUBSTR(SQLERRM, 1, 2000); 
            begin
                ROLLBACK;
                sqlStmt := '
                UPDATE :1 
                SET status = ''ERROR'', 
                    -- Jetzt die Variable statt der Funktion nutzen
                    error_message = v_err_msg,
                    processed_at = SYSTIMESTAMP -- Hilfreich für das Debugging
                WHERE alert_id = p_alertId';
                EXECUTE IMMEDIATE sqlStmt
                USING LILAM.C_LILAM_ALERTS;
                COMMIT;
            end;
    end;
    
    FUNCTION get_ms_diff(p_start timestamp, p_end timestamp) RETURN NUMBER AS
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

END LILAM_CONSUMER;
