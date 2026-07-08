CREATE OR REPLACE PACKAGE LILAM_CONSUMER AS 

    -- JSON for ALERT data
    TYPE t_json_rec IS RECORD (
        id                  VARCHAR2(30),
        trigger_type        VARCHAR2(30),
        action              VARCHAR2(50),
        condition_operator  VARCHAR2(50),
        condition_value     VARCHAR2(50),
        alert_handler       VARCHAR2(30),
        alert_severity      VARCHAR2(30),
        alert_throttle      PLS_INTEGER
    );
    
    -- Type extends LILAM process type
    -- Collection of Monitoring- and Process-Data
    TYPE t_lilam_rec IS RECORD (
        processId    NUMBER(19,0),
        processName   VARCHAR2(100),
        logLevel      PLS_INTEGER,
        processStart  TIMESTAMP,
        processEnd    TIMESTAMP,
        lastUpdate    TIMESTAMP,
        stepsTodo     PLS_INTEGER,
        stepsDone     PLS_INTEGER,
        status        PLS_INTEGER,
        info          VARCHAR2(4000),
        procImmortal  PLS_INTEGER := 0,
        tabNameMaster VARCHAR2(100),
        monitorType   NUMBER,
        actionName    VARCHAR2(50),
        contextName   VARCHAR2(50),
        actionStart   TIMESTAMP(6),
        actionStop    TIMESTAMP(6),
        actionCount   NUMBER,
        usedMillis    NUMBER,
        avgMillis     NUMBER
    );
    
    -- Structure of Table LILAM_ALERTS
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
        alert_severity      VARCHAR2(30)
    );
    
    FUNCTION readJsonRule(p_alert_rec t_alert_rec) RETURN t_json_rec;
    FUNCTION get_ms_diff(p_start TIMESTAMP, p_end TIMESTAMP) RETURN NUMBER;
    FUNCTION readProcessData(p_processId NUMBER, p_action VARCHAR2, p_actionCount PLS_INTEGER, p_procTabName VARCHAR2, p_monitorTabName VARCHAR2) RETURN t_lilam_rec;
    PROCEDURE updateAlert(p_alertId NUMBER);


END LILAM_CONSUMER;
