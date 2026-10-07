create or replace PACKAGE BODY LILAM_MAILER AS

    SUBTYPE t_alert_rec IS LILAM_CONSUMER.t_alert_rec;
    SUBTYPE t_lilam_rec IS LILAM_CONSUMER.t_lilam_rec;
    SUBTYPE t_json_rec  IS LILAM_CONSUMER.t_json_rec;

    -------------------------------------------------------------------------

    PROCEDURE send_mail_via_relay(p_subject VARCHAR2, p_body VARCHAR2, p_recipient VARCHAR2) IS
        l_conn  utl_smtp.connection;
        l_offset     NUMBER := 1;
        l_chunk_size NUMBER := 1500; -- Stays safely below the SMTP limit
        l_body_len   NUMBER := DBMS_LOB.GETLENGTH(p_body);
    BEGIN
        -- 1. Connection to the local Postfix (without wallet!)
        l_conn := utl_smtp.open_connection('localhost', 25);
        utl_smtp.helo(l_conn, 'localhost');
        
        -- 2. Sender and recipient (Strato needs a valid sender address)
        utl_smtp.mail(l_conn, 'dirk@dirk-goldbach.de');
        utl_smtp.rcpt(l_conn, p_recipient);
        
        -- 3. The mail data (header)
        utl_smtp.open_data(l_conn);

        utl_smtp.write_data(l_conn, 'From: LILAM Engine <dirk@dirk-goldbach.de>' || utl_tcp.crlf);
        utl_smtp.write_data(l_conn, 'To: ' || p_recipient || utl_tcp.crlf);
        utl_smtp.write_data(l_conn, 'Subject: ' || p_subject || utl_tcp.crlf);
        
        -- 4. THE CRUCIAL PART: MIME version and HTML content type
        utl_smtp.write_data(l_conn, 'MIME-Version: 1.0' || utl_tcp.crlf);
        utl_smtp.write_data(l_conn, 'Content-Type: text/html; charset=UTF-8' || utl_tcp.crlf);
        utl_smtp.write_data(l_conn, utl_tcp.crlf);
        
        -- 5. The CLOB splitter (so that lines are no longer torn apart)
        WHILE l_offset <= l_body_len LOOP
            utl_smtp.write_data(l_conn, DBMS_LOB.SUBSTR(p_body, l_chunk_size, l_offset));
            l_offset := l_offset + l_chunk_size;
        END LOOP;

        utl_smtp.close_data(l_conn);
        utl_smtp.quit(l_conn);
    END;
            
    -------------------------------------------------------------------------
    
    function prepareMailBodyHtml(l_lilam_rec LILAM_CONSUMER.t_lilam_rec, p_alertRec LILAM_CONSUMER.t_alert_rec, p_json_rec  LILAM_CONSUMER.t_json_rec) return CLOB
    as
        v_color varchar2(20);
        v_html clob;
    begin
    
        v_color := CASE p_alertRec.alert_severity 
                      WHEN 'CRITICAL' THEN '#e74c3c' -- Red
                      WHEN 'WARN'     THEN '#f39c12' -- Orange
                      ELSE                 '#3498db' -- Blue
                   END;                   
        
        v_html := '<html><body style="font-family: Arial, sans-serif; color: #333; line-height: 1.5;">' || utl_tcp.crlf ||
                  -- HEADER
                  '<div style="background-color: ' || v_color || '; color: white; padding: 15px; font-size: 20px; font-weight: bold;">' ||
                  'LILAM Alert: ' || p_alertRec.rule_id || ' (' || p_alertRec.alert_severity || ')</div>' || utl_tcp.crlf ||
                  
                  -- 1. BLOCK: RULE (JSON)
                  '<h3 style="color: ' || v_color || ';">Regel-Details</h3>' ||
                  '<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">' ||
                  '<tr><td style="width: 200px; font-weight: bold; border-bottom: 1px solid #ddd; padding: 8px;">Trigger / Action:</td>' ||
                  '<td style="border-bottom: 1px solid #ddd; padding: 8px;">' || p_json_rec.trigger_type || ' / ' || p_json_rec.action || '</td></tr>' ||
                  '<tr><td style="font-weight: bold; border-bottom: 1px solid #ddd; padding: 8px;">Bedingung:</td>' ||
                  '<td style="border-bottom: 1px solid #ddd; padding: 8px;">' || p_json_rec.condition_operator || ' (' || p_json_rec.condition_value || ')</td></tr>' ||
                  '</table>' ||
        
                  -- 2. BLOCK: PROCESS (MASTER)
                  '<h3 style="color: ' || v_color || ';">Prozess-Status</h3>' ||
                  '<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">' ||
                  '<tr><td style="width: 200px; font-weight: bold; border-bottom: 1px solid #ddd; padding: 8px;">Prozess Name (ID):</td>' ||
                  '<td style="border-bottom: 1px solid #ddd; padding: 8px;">' || l_lilam_rec.processName || ' (' || l_lilam_rec.processId || ')</td></tr>' ||
                  '<tr><td style="font-weight: bold; border-bottom: 1px solid #ddd; padding: 8px;">Fortschritt / Status:</td>' ||
                  '<td style="border-bottom: 1px solid #ddd; padding: 8px;">' || l_lilam_rec.stepsDone || ' von ' || l_lilam_rec.stepsTodo || ' erledigt (Status: ' || l_lilam_rec.status || ')</td></tr>' ||
                  '<tr><td style="font-weight: bold; border-bottom: 1px solid #ddd; padding: 8px;">Info:</td>' ||
                  '<td style="border-bottom: 1px solid #ddd; padding: 8px;">' || NVL(l_lilam_rec.info, '-') || '</td></tr>' || utl_tcp.crlf ||
                  '</table>';
        
        -- 3. BLOCK: MONITORING (only if present via LEFT JOIN)
        IF l_lilam_rec.actionName IS NOT NULL THEN
            v_html := v_html || 
                  '<h3 style="color: ' || v_color || ';">Monitoring / Performance</h3>' ||
                  '<table style="width: 100%; border-collapse: collapse; background-color: #f9f9f9;">' ||
                  '<tr><td style="width: 200px; font-weight: bold; border-bottom: 1px solid #ddd; padding: 8px;">Aktion / Kontext:</td>' ||
                  '<td style="border-bottom: 1px solid #ddd; padding: 8px;">' || l_lilam_rec.actionName || ' | ' || NVL(l_lilam_rec.contextName, 'None') || '</td></tr>' ||
                  '<tr><td style="font-weight: bold; border-bottom: 1px solid #ddd; padding: 8px;">Dauer (Ist / Schnitt):</td>' ||
                  '<td style="border-bottom: 1px solid #ddd; padding: 8px;"><b>' || l_lilam_rec.usedMillis || ' ms</b> (Schnitt: ' || l_lilam_rec.avgMillis || ' ms)</td></tr>' ||
                  '<tr><td style="font-weight: bold; border-bottom: 1px solid #ddd; padding: 8px;">Zeitpunkt:</td>' ||
                  '<td style="border-bottom: 1px solid #ddd; padding: 8px;">' || TO_CHAR(l_lilam_rec.actionStart, 'HH24:MI:SS.FF3') || '</td></tr>' ||
                  '</table>';
        END IF;
        
        v_html := v_html || '<p style="font-size: 10px; color: #999; margin-top: 30px;">LILAM Engine Alert ID: ' || p_alertRec.alert_id || '</p></body></html>';
        return v_html;

    end;

    -------------------------------------------------------------------------

    FUNCTION prepareMailBodyPlain(l_lilam_rec LILAM_CONSUMER.t_lilam_rec, p_alertRec LILAM_CONSUMER.t_alert_rec, l_json_rec  LILAM_CONSUMER.t_json_rec) return CLOB
    as
        l_body CLOB;
        l_duration pls_integer;
    begin
        if l_lilam_rec.actionName is null then
            l_duration := LILAM_CONSUMER.get_ms_diff(l_lilam_rec.processStart, l_lilam_rec.processEnd);
        else
            l_duration := l_lilam_rec.usedMillis;
        end if;

        -- Assemble the mail body (example)
        l_body := 'LILAM ALERT REPORT' || CHR(10) ||
                       '-------------------' || CHR(10) ||
                       'Alert ID: ' || p_alertRec.alert_id || CHR(10) ||
                       'Rule:     ' || p_alertRec.rule_id  || ' (' || l_json_rec.condition_operator || ')' || CHR(10) ||
                       'Details:  ' || l_lilam_rec.info || CHR(10) ||
                       'Dauer:    ' || l_duration || ' ms';
                       
        return l_body;
    end;
        
    -------------------------------------------------------------------------
    -- Set an alert to ERROR (call after ROLLBACK) so that it is not retried forever
    -------------------------------------------------------------------------
    PROCEDURE markError(p_alertId NUMBER, p_msg VARCHAR2) IS
    BEGIN
        UPDATE LILAM_ALERTS
           SET status = 'ERROR',
               error_message = p_msg,
               processed_at = SYSTIMESTAMP
         WHERE alert_id = p_alertId;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            DBMS_OUTPUT.PUT_LINE('LILAM Mailer: could not set alert ' || p_alertId || ' to ERROR: ' || SQLERRM);
    END;

    -------------------------------------------------------------------------
    -- Process all pending mail alerts.
    -- STABILITY: read the IDs first, then lock and commit each alert on its own
    -- (a COMMIT inside a FOR UPDATE loop raises ORA-01002 on the next fetch).
    -------------------------------------------------------------------------
    PROCEDURE processPending IS
        TYPE t_id_list IS TABLE OF LILAM_ALERTS.alert_id%TYPE;
        CURSOR c_lock(p_alertId NUMBER) IS
            SELECT * FROM LILAM_ALERTS
             WHERE alert_id = p_alertId AND status = 'PENDING'
               FOR UPDATE SKIP LOCKED;

        l_ids         t_id_list;
        rec           c_lock%ROWTYPE;
        l_found       BOOLEAN;
        v_mail_body   CLOB;
        l_alert_rec   t_alert_rec;
        l_json_rec    t_json_rec;
        l_lilam_rec   t_lilam_rec;
    BEGIN
        SELECT alert_id BULK COLLECT INTO l_ids
          FROM LILAM_ALERTS
         WHERE handler_type = C_ALERT_MAIL_LOG AND status = 'PENDING'
         ORDER BY alert_id;

        FOR i IN 1 .. l_ids.COUNT LOOP
            BEGIN -- Protective capsule for the single alert
                -- Lock; locked by another mailer or already processed => skip
                OPEN c_lock(l_ids(i));
                FETCH c_lock INTO rec;
                l_found := c_lock%FOUND;
                CLOSE c_lock;

                IF l_found THEN
                    -- 1. Mapping
                    l_alert_rec.alert_id            := rec.alert_id;
                    l_alert_rec.process_id          := rec.process_id;
                    l_alert_rec.master_table_name   := rec.master_table_name;
                    l_alert_rec.monitor_table_name  := rec.monitor_table_name;
                    l_alert_rec.action_name         := rec.action_name;
                    l_alert_rec.context_name        := rec.context_name;
                    l_alert_rec.action_count        := rec.action_count;
                    l_alert_rec.group_name          := rec.group_name;
                    l_alert_rec.rule_set_name       := rec.rule_set_name;
                    l_alert_rec.rule_id             := rec.rule_id;
                    l_alert_rec.rule_set_version    := rec.rule_set_version;
                    l_alert_rec.alert_severity      := rec.alert_severity;

                    -- 2. Load data
                    l_json_rec := LILAM_CONSUMER.readJsonRule(l_alert_rec);
                    l_lilam_rec := LILAM_CONSUMER.readProcessData(l_alert_rec.process_id, l_alert_rec.action_name, l_alert_rec.action_count, l_alert_rec.master_table_name, l_alert_rec.monitor_table_name, l_alert_rec.context_name);

                    -- 3. Build body & send
                    v_mail_body := prepareMailBodyHtml(l_lilam_rec, l_alert_rec, l_json_rec);
                    send_mail_via_relay('LILAM-ALERT: ' || l_alert_rec.rule_id, v_mail_body, 'dirk@dirk-goldbach.de');

                    -- 4. Set status to PROCESSED
                    LILAM_CONSUMER.updateAlert(rec.alert_id);

                    COMMIT; -- A single commit per mail is safe here
                    DBMS_SESSION.SLEEP(1); -- Somewhat less aggressive than 10s?
                END IF;

            EXCEPTION WHEN OTHERS THEN
                DECLARE
                    v_err_msg VARCHAR2(2000) := SUBSTR(SQLERRM, 1, 2000);
                BEGIN
                    IF c_lock%ISOPEN THEN CLOSE c_lock; END IF;
                    ROLLBACK; -- Release the lock
                    -- STABILITY: set the alert to ERROR, otherwise it is retried on every run
                    markError(l_ids(i), v_err_msg);
                END;
            END;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            -- STABILITY: an error while reading the list does not stop the mailer
            ROLLBACK;
            DBMS_OUTPUT.PUT_LINE('LILAM Mailer: ' || SQLERRM);
    END;

    -------------------------------------------------------------------------

    PROCEDURE runMailer IS
        v_msg_payload varchar2(4000);
        v_status    pls_integer;
    BEGIN
        DBMS_ALERT.REMOVE(C_ALERT_MAIL_LOG);
        DBMS_ALERT.REGISTER(C_ALERT_MAIL_LOG);
        DBMS_OUTPUT.PUT_LINE('LILAM Mail-Log Consumer gestartet...');

        LOOP
            -- STABILITY: process pending alerts at start, after every signal and after the timeout
            -- (DBMS_ALERT may merge signals; alerts written while the mailer was down)
            processPending;
            COMMIT; -- Refresh the snapshot for the next run
            DBMS_ALERT.WAITONE(C_ALERT_MAIL_LOG, v_msg_payload, v_status, 60);
        END LOOP;
    END;

END LILAM_MAILER;
