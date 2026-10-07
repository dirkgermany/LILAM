create or replace PACKAGE BODY LILAM_GRAFANA AS

    SUBTYPE t_alert IS LILAM_ALERTS%ROWTYPE;

    -------------------------------------------------------------------------
    -- Milliseconds since 1970-01-01 UTC (Grafana time format).
    -- LILAM stores TIMESTAMP without time zone in the session time zone of the database.
    -------------------------------------------------------------------------
    FUNCTION epochMs(p_ts TIMESTAMP) RETURN NUMBER IS
        l_utc TIMESTAMP;
        l_d   INTERVAL DAY(9) TO SECOND(3);
    BEGIN
        IF p_ts IS NULL THEN RETURN NULL; END IF;
        l_utc := sys_extract_utc(from_tz(p_ts, sessiontimezone));
        l_d   := l_utc - TIMESTAMP '1970-01-01 00:00:00';
        RETURN extract(day from l_d) * 86400000 + extract(hour from l_d) * 3600000
             + extract(minute from l_d) * 60000 + round(extract(second from l_d) * 1000);
    END;

    -------------------------------------------------------------------------
    -- Monitor entry of the alert (start/stop/duration); NULL values if not (yet) written.
    -- STABILITY: table names come from LILAM_ALERTS and are checked with DBMS_ASSERT.
    -------------------------------------------------------------------------
    PROCEDURE readMonitor(p_alert t_alert, p_start OUT TIMESTAMP, p_stop OUT TIMESTAMP, p_used OUT NUMBER) IS
    BEGIN
        EXECUTE IMMEDIATE
            'SELECT start_time, stop_time, used_millis FROM '
            || dbms_assert.sql_object_name(p_alert.monitor_table_name) || '
              WHERE process_id = :1 AND action = :2 AND action_count = :3
                AND (context = :4 OR (context IS NULL AND :5 IS NULL))
              ORDER BY stop_time DESC NULLS LAST
              FETCH FIRST 1 ROWS ONLY'
        INTO p_start, p_stop, p_used
        USING p_alert.process_id, p_alert.action_name, p_alert.action_count, p_alert.context_name, p_alert.context_name;
    EXCEPTION
        WHEN OTHERS THEN
            -- The server writes monitor data buffered; the alert is sent anyway
            p_start := NULL; p_stop := NULL; p_used := NULL;
    END;

    -------------------------------------------------------------------------

    FUNCTION BUILD_ANNOTATION(p_alertId NUMBER, p_dashboardUid VARCHAR2 DEFAULT NULL) RETURN CLOB IS
        l_alert t_alert;
        l_start TIMESTAMP;
        l_stop  TIMESTAMP;
        l_used  NUMBER;
        l_text  VARCHAR2(4000);
        l_obj   JSON_OBJECT_T := JSON_OBJECT_T();
        l_tags  JSON_ARRAY_T  := JSON_ARRAY_T();
    BEGIN
        SELECT * INTO l_alert FROM LILAM_ALERTS WHERE alert_id = p_alertId;
        readMonitor(l_alert, l_start, l_stop, l_used);

        l_tags.append('lilam');
        l_tags.append('group:'    || l_alert.group_name);
        l_tags.append('rule_set:' || l_alert.rule_set_name || ' v' || l_alert.rule_set_version);
        l_tags.append('rule:'     || l_alert.rule_id);
        l_tags.append('severity:' || l_alert.alert_severity);
        l_tags.append('action:'   || l_alert.action_name);
        IF l_alert.context_name IS NOT NULL THEN
            l_tags.append('context:' || l_alert.context_name);
        END IF;

        l_text := 'LILAM ' || l_alert.rule_id || ' (' || l_alert.alert_severity || '): '
               || l_alert.action_name || nvl2(l_alert.context_name, ' ' || l_alert.context_name, '')
               || nvl2(l_used, ', ' || to_char(round(l_used), 'FM999999999990') || ' ms', '')
               || ' - ' || l_alert.process_name || ' (process ' || l_alert.process_id || ', alert ' || l_alert.alert_id || ')';

        IF p_dashboardUid IS NOT NULL THEN
            l_obj.put('dashboardUID', p_dashboardUid);
        END IF;
        -- Region from start to end of the trace if known, otherwise a point at the alert time
        l_obj.put('time', coalesce(epochMs(l_start), epochMs(l_stop), epochMs(l_alert.created_at)));
        IF l_start IS NOT NULL AND l_stop IS NOT NULL THEN
            l_obj.put('timeEnd', epochMs(l_stop));
        END IF;
        l_obj.put('tags', l_tags);
        l_obj.put('text', l_text);
        RETURN l_obj.to_clob;
    END;

    -------------------------------------------------------------------------
    -- Send one annotation. Returns the HTTP status; raises on transport errors.
    -------------------------------------------------------------------------
    FUNCTION httpPost(p_url VARCHAR2, p_token VARCHAR2, p_body CLOB) RETURN PLS_INTEGER IS
        l_req   utl_http.req;
        l_resp  utl_http.resp;
        l_body  VARCHAR2(32767) := dbms_lob.substr(p_body, 32767, 1);
        l_code  PLS_INTEGER;
    BEGIN
        utl_http.set_transfer_timeout(5); -- STABILITY: a hanging Grafana must not block the consumer for long
        l_req := utl_http.begin_request(rtrim(p_url, '/') || '/api/annotations', 'POST', 'HTTP/1.1');
        utl_http.set_header(l_req, 'Content-Type', 'application/json');
        utl_http.set_header(l_req, 'Content-Length', lengthb(l_body));
        IF p_token IS NOT NULL THEN
            utl_http.set_header(l_req, 'Authorization', 'Bearer ' || p_token);
        END IF;
        utl_http.write_text(l_req, l_body);
        l_resp := utl_http.get_response(l_req);
        l_code := l_resp.status_code;
        utl_http.end_response(l_resp);
        RETURN l_code;
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN utl_http.end_request(l_req); EXCEPTION WHEN OTHERS THEN NULL; END;
            RAISE;
    END;

    -------------------------------------------------------------------------

    PROCEDURE writeOutbox(p_alertId NUMBER, p_url VARCHAR2, p_body CLOB, p_http NUMBER, p_status VARCHAR2, p_err VARCHAR2) IS
    BEGIN
        INSERT INTO lilam_grafana_outbox (alert_id, target_url, request_body, http_status, send_status, error_message)
        VALUES (p_alertId, p_url, p_body, p_http, p_status, substr(p_err, 1, 2000));
    END;

    -------------------------------------------------------------------------

    PROCEDURE markAlert(p_alertId NUMBER, p_status VARCHAR2, p_err VARCHAR2 DEFAULT NULL) IS
    BEGIN
        UPDATE LILAM_ALERTS
           SET status = p_status, error_message = p_err, processed_at = systimestamp
         WHERE alert_id = p_alertId;
    END;

    -------------------------------------------------------------------------
    -- STABILITY: read the IDs first, then lock and commit each alert on its own
    -- (as LILAM_MAILER; a COMMIT inside a FOR UPDATE loop raises ORA-01002).
    -------------------------------------------------------------------------
    FUNCTION PROCESS_PENDING(
        p_channel      VARCHAR2 DEFAULT C_DEFAULT_CHANNEL,
        p_groupName    VARCHAR2 DEFAULT C_DEFAULT_GROUP,
        p_url          VARCHAR2 DEFAULT NULL,
        p_token        VARCHAR2 DEFAULT NULL,
        p_dashboardUid VARCHAR2 DEFAULT NULL) RETURN PLS_INTEGER
    IS
        TYPE t_id_list IS TABLE OF LILAM_ALERTS.alert_id%TYPE;
        CURSOR c_lock(p_alertId NUMBER) IS
            SELECT alert_id FROM LILAM_ALERTS
             WHERE alert_id = p_alertId AND status = 'PENDING'
               FOR UPDATE SKIP LOCKED;
        l_ids   t_id_list;
        l_id    NUMBER;
        l_found BOOLEAN;
        l_body  CLOB;
        l_http  PLS_INTEGER;
        l_done  PLS_INTEGER := 0;
        l_err   VARCHAR2(2000);
    BEGIN
        SELECT alert_id BULK COLLECT INTO l_ids
          FROM LILAM_ALERTS
         WHERE handler_type = p_channel
           AND upper(group_name) = upper(p_groupName)
           AND status = 'PENDING'
         ORDER BY alert_id;

        FOR i IN 1 .. l_ids.COUNT LOOP
            BEGIN
                OPEN c_lock(l_ids(i));
                FETCH c_lock INTO l_id;
                l_found := c_lock%FOUND;
                CLOSE c_lock;

                IF l_found THEN
                    l_body := BUILD_ANNOTATION(l_ids(i), p_dashboardUid);
                    IF p_url IS NULL THEN
                        -- Imaginary Grafana: the request stays in the outbox
                        writeOutbox(l_ids(i), NULL, l_body, NULL, 'SIMULATED', NULL);
                        markAlert(l_ids(i), 'PROCESSED');
                        l_done := l_done + 1;
                    ELSE
                        l_http := httpPost(p_url, p_token, l_body);
                        IF l_http BETWEEN 200 AND 299 THEN
                            writeOutbox(l_ids(i), p_url, l_body, l_http, 'SENT', NULL);
                            markAlert(l_ids(i), 'PROCESSED');
                            l_done := l_done + 1;
                        ELSE
                            writeOutbox(l_ids(i), p_url, l_body, l_http, 'FAILED', 'HTTP ' || l_http);
                            markAlert(l_ids(i), 'ERROR', 'Grafana HTTP ' || l_http);
                        END IF;
                    END IF;
                    COMMIT;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    l_err := substr(sqlerrm, 1, 2000);
                    IF c_lock%ISOPEN THEN CLOSE c_lock; END IF;
                    ROLLBACK;
                    -- STABILITY: set the alert to ERROR, otherwise it is retried on every run
                    BEGIN
                        writeOutbox(l_ids(i), p_url, l_body, NULL, 'FAILED', l_err);
                        markAlert(l_ids(i), 'ERROR', l_err);
                        COMMIT;
                    EXCEPTION WHEN OTHERS THEN ROLLBACK;
                    END;
            END;
            l_body := NULL;
        END LOOP;
        RETURN l_done;
    EXCEPTION
        WHEN OTHERS THEN
            -- STABILITY: an error while reading the list does not stop the consumer
            ROLLBACK;
            dbms_output.put_line('LILAM Grafana: ' || sqlerrm);
            RETURN l_done;
    END;

    -------------------------------------------------------------------------

    PROCEDURE RUN(
        p_channel      VARCHAR2 DEFAULT C_DEFAULT_CHANNEL,
        p_groupName    VARCHAR2 DEFAULT C_DEFAULT_GROUP,
        p_url          VARCHAR2 DEFAULT NULL,
        p_token        VARCHAR2 DEFAULT NULL,
        p_dashboardUid VARCHAR2 DEFAULT NULL,
        p_maxSeconds   NUMBER   DEFAULT NULL,
        p_waitSeconds  NUMBER   DEFAULT 60)
    IS
        l_name   VARCHAR2(30);
        l_msg    VARCHAR2(4000);
        l_status PLS_INTEGER;
        l_n      PLS_INTEGER;
        l_end    TIMESTAMP := CASE WHEN p_maxSeconds IS NOT NULL
                                   THEN systimestamp + numtodsinterval(p_maxSeconds, 'SECOND') END;
        l_wait   NUMBER;
    BEGIN
        dbms_alert.register(p_channel);
        dbms_alert.register(C_STOP_CHANNEL);
        COMMIT;
        dbms_output.put_line('LILAM Grafana consumer started: channel ' || p_channel || ', group ' || p_groupName
                             || CASE WHEN p_url IS NULL THEN ' (simulated Grafana)' ELSE ' -> ' || p_url END);
        LOOP
            -- STABILITY: process pending alerts at start, after every signal and after the timeout
            -- (DBMS_ALERT may merge signals; alerts written while the consumer was down)
            l_n := PROCESS_PENDING(p_channel, p_groupName, p_url, p_token, p_dashboardUid);
            COMMIT; -- required to receive the next signal

            l_wait := p_waitSeconds;
            IF l_end IS NOT NULL THEN
                l_wait := least(l_wait, greatest(0, extract(second from (l_end - systimestamp))
                                                  + 60 * extract(minute from (l_end - systimestamp))
                                                  + 3600 * extract(hour from (l_end - systimestamp))
                                                  + 86400 * extract(day from (l_end - systimestamp))));
            END IF;
            dbms_alert.waitany(l_name, l_msg, l_status, l_wait);
            EXIT WHEN l_status = 0 AND l_name = C_STOP_CHANNEL;
            EXIT WHEN l_end IS NOT NULL AND systimestamp >= l_end;
        END LOOP;
        dbms_alert.remove(p_channel);
        dbms_alert.remove(C_STOP_CHANNEL);
        COMMIT;
        dbms_output.put_line('LILAM Grafana consumer stopped.');
    END;

    -------------------------------------------------------------------------

    PROCEDURE START_JOB(
        p_channel      VARCHAR2 DEFAULT C_DEFAULT_CHANNEL,
        p_groupName    VARCHAR2 DEFAULT C_DEFAULT_GROUP,
        p_url          VARCHAR2 DEFAULT NULL,
        p_maxSeconds   NUMBER   DEFAULT NULL)
    IS
        FUNCTION lit(p VARCHAR2) RETURN VARCHAR2 IS
        BEGIN
            RETURN CASE WHEN p IS NULL THEN 'NULL' ELSE dbms_assert.enquote_literal(replace(p, '''', '''''')) END;
        END;
    BEGIN
        dbms_scheduler.create_job(
            job_name   => substr('LILAM_GRAFANA_' || upper(regexp_replace(p_groupName, '[^A-Za-z0-9_]', '_')), 1, 128),
            job_type   => 'PLSQL_BLOCK',
            job_action => 'BEGIN LILAM_GRAFANA.RUN(p_channel => ' || lit(p_channel) || ', p_groupName => ' || lit(p_groupName)
                          || ', p_url => ' || lit(p_url)
                          || ', p_maxSeconds => ' || nvl(to_char(p_maxSeconds, 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,'''), 'NULL')
                          || '); END;',
            enabled    => TRUE,
            auto_drop  => TRUE);
    END;

    -------------------------------------------------------------------------

    PROCEDURE STOP IS
    BEGIN
        dbms_alert.signal(C_STOP_CHANNEL, 'STOP');
        COMMIT; -- the signal is sent on commit
    END;

END LILAM_GRAFANA;
