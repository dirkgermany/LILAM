create or replace PACKAGE BODY LILAM_MAILER AS

    SUBTYPE t_alert_rec IS LILAM_CONSUMER.t_alert_rec;
    SUBTYPE t_lilam_rec IS LILAM_CONSUMER.t_lilam_rec;
    SUBTYPE t_json_rec  IS LILAM_CONSUMER.t_json_rec;

    -------------------------------------------------------------------------

    PROCEDURE send_mail_via_relay(p_subject VARCHAR2, p_body VARCHAR2, p_recipient VARCHAR2) IS
        l_conn  utl_smtp.connection;
        l_offset     NUMBER := 1;
        l_chunk_size NUMBER := 1500; -- Bleibt sicher unter dem SMTP-Limit
        l_body_len   NUMBER := DBMS_LOB.GETLENGTH(p_body);
    BEGIN
        -- 1. Verbindung zum lokalen Postfix (ohne Wallet!)
        l_conn := utl_smtp.open_connection('localhost', 25);
        utl_smtp.helo(l_conn, 'localhost');
        
        -- 2. Absender und Empfänger (Strato braucht eine valide Absender-Mail)
        utl_smtp.mail(l_conn, 'dirk@dirk-goldbach.de');
        utl_smtp.rcpt(l_conn, p_recipient);
        
        -- 3. Die Mail-Daten (Header)
        utl_smtp.open_data(l_conn);

        utl_smtp.write_data(l_conn, 'From: LILAM Engine <dirk@dirk-goldbach.de>' || utl_tcp.crlf);
        utl_smtp.write_data(l_conn, 'To: ' || p_recipient || utl_tcp.crlf);
        utl_smtp.write_data(l_conn, 'Subject: ' || p_subject || utl_tcp.crlf);
        
        -- 4. DER ENTSCHEIDENDE TEIL: MIME-Version und HTML Content-Type
        utl_smtp.write_data(l_conn, 'MIME-Version: 1.0' || utl_tcp.crlf);
        utl_smtp.write_data(l_conn, 'Content-Type: text/html; charset=UTF-8' || utl_tcp.crlf);
        utl_smtp.write_data(l_conn, utl_tcp.crlf);
        
        -- 5. Der CLOB-Splitter (Damit keine Zeilen mehr zerreißen)
        WHILE l_offset <= l_body_len LOOP
            utl_smtp.write_data(l_conn, DBMS_LOB.SUBSTR(p_body, l_chunk_size, l_offset));
            l_offset := l_offset + l_chunk_size;
        END LOOP;
--        utl_smtp.write_data(l_conn, p_body);

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
                      WHEN 'CRITICAL' THEN '#e74c3c' -- Rot
                      WHEN 'WARN'     THEN '#f39c12' -- Orange
                      ELSE                 '#3498db' -- Blau
                   END;                   
        
        v_html := '<html><body style="font-family: Arial, sans-serif; color: #333; line-height: 1.5;">' || utl_tcp.crlf ||
                  -- HEADER
                  '<div style="background-color: ' || v_color || '; color: white; padding: 15px; font-size: 20px; font-weight: bold;">' ||
                  'LILAM Alert: ' || p_alertRec.rule_id || ' (' || p_alertRec.alert_severity || ')</div>' || utl_tcp.crlf ||
                  
                  -- 1. BLOCK: REGEL (JSON)
                  '<h3 style="color: ' || v_color || ';">Regel-Details</h3>' ||
                  '<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">' ||
                  '<tr><td style="width: 200px; font-weight: bold; border-bottom: 1px solid #ddd; padding: 8px;">Trigger / Action:</td>' ||
                  '<td style="border-bottom: 1px solid #ddd; padding: 8px;">' || p_json_rec.trigger_type || ' / ' || p_json_rec.action || '</td></tr>' ||
                  '<tr><td style="font-weight: bold; border-bottom: 1px solid #ddd; padding: 8px;">Bedingung:</td>' ||
                  '<td style="border-bottom: 1px solid #ddd; padding: 8px;">' || p_json_rec.condition_operator || ' (' || p_json_rec.condition_value || ')</td></tr>' ||
                  '</table>' ||
        
                  -- 2. BLOCK: PROZESS (MASTER)
                  '<h3 style="color: ' || v_color || ';">Prozess-Status</h3>' ||
                  '<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">' ||
                  '<tr><td style="width: 200px; font-weight: bold; border-bottom: 1px solid #ddd; padding: 8px;">Prozess Name (ID):</td>' ||
                  '<td style="border-bottom: 1px solid #ddd; padding: 8px;">' || l_lilam_rec.processName || ' (' || l_lilam_rec.processId || ')</td></tr>' ||
                  '<tr><td style="font-weight: bold; border-bottom: 1px solid #ddd; padding: 8px;">Fortschritt / Status:</td>' ||
                  '<td style="border-bottom: 1px solid #ddd; padding: 8px;">' || l_lilam_rec.stepsDone || ' von ' || l_lilam_rec.stepsTodo || ' erledigt (Status: ' || l_lilam_rec.status || ')</td></tr>' ||
                  '<tr><td style="font-weight: bold; border-bottom: 1px solid #ddd; padding: 8px;">Info:</td>' ||
                  '<td style="border-bottom: 1px solid #ddd; padding: 8px;">' || NVL(l_lilam_rec.info, '-') || '</td></tr>' || utl_tcp.crlf ||
                  '</table>';
        
        -- 3. BLOCK: MONITORING (Nur wenn vorhanden via LEFT JOIN)
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

        -- Mail-Body zusammenstellen (Beispiel)
        l_body := 'LILAM ALERT REPORT' || CHR(10) ||
                       '-------------------' || CHR(10) ||
                       'Alert ID: ' || p_alertRec.alert_id || CHR(10) ||
                       'Rule:     ' || p_alertRec.rule_id  || ' (' || l_json_rec.condition_operator || ')' || CHR(10) ||
                       'Details:  ' || l_lilam_rec.info || CHR(10) ||
                       'Dauer:    ' || l_duration || ' ms';
                       
        return l_body;
    end;
        
    -------------------------------------------------------------------------

    PROCEDURE runMailer IS        
        -- Dynamische Daten
        v_info_text     VARCHAR2(2000);
        v_used_millis   NUMBER;
        v_mail_body     CLOB;
        
        l_alert_rec   t_alert_rec;
        l_json_rec    t_json_rec;
        l_lilam_rec   t_lilam_rec;
        
        v_msg_payload varchar2(4000);
        v_status    pls_integer;
        v_count     pls_integer;

    BEGIN
        DBMS_ALERT.REMOVE(C_ALERT_MAIL_LOG);
        DBMS_ALERT.REGISTER(C_ALERT_MAIL_LOG);
        DBMS_OUTPUT.PUT_LINE('LILAM Mail-Log Consumer gestartet...');
    
        LOOP
            COMMIT; -- Snapshot erneuern für den nächsten Durchgang
            DBMS_ALERT.WAITONE(C_ALERT_MAIL_LOG, v_msg_payload, v_status, 60);
    
            IF v_status = 0 THEN
                -- Kurzer Check auf PENDING Records
                SELECT count(*) INTO v_count FROM LILAM_ALERTS 
                WHERE handler_type = 'MAIL_LOG' AND status = 'PENDING';
    
                IF v_count > 0 THEN
                    FOR rec IN (
                        SELECT * FROM LILAM_ALERTS
                        WHERE handler_type = 'MAIL_LOG' AND status = 'PENDING'
                        FOR UPDATE SKIP LOCKED
                    ) LOOP
                        BEGIN -- Sicherungskapsel für den einzelnen Alert
                            -- 1. Mapping
                            l_alert_rec.alert_id            := rec.alert_id;
                            l_alert_rec.process_id          := rec.process_id; 
                            l_alert_rec.master_table_name   := rec.master_table_name;
                            l_alert_rec.monitor_table_name  := rec.monitor_table_name;
                            l_alert_rec.action_name         := rec.action_name;
                            l_alert_rec.context_name        := rec.context_name;
                            l_alert_rec.action_count        := rec.action_count;
                            l_alert_rec.rule_set_name       := rec.rule_set_name;
                            l_alert_rec.rule_id             := rec.rule_id;
                            l_alert_rec.rule_set_version    := rec.rule_set_version;
                            l_alert_rec.alert_severity      := rec.alert_severity;

                            -- 2. Daten laden
                            l_json_rec := LILAM_CONSUMER.readJsonRule(l_alert_rec);
                            l_lilam_rec := LILAM_CONSUMER.readProcessData(l_alert_rec.process_id, l_alert_rec.action_name, l_alert_rec.action_count, l_alert_rec.master_table_name, l_alert_rec.monitor_table_name);

                            -- 3. Body bauen & Senden
                            v_mail_body := prepareMailBodyHtml(l_lilam_rec, l_alert_rec, l_json_rec);
                            send_mail_via_relay('LILAM-ALERT: ' || l_alert_rec.rule_id, v_mail_body, 'dirk@dirk-goldbach.de');
                            
                            -- 4. Status auf PROCESSED setzen
                            LILAM_CONSUMER.updateAlert(rec.alert_id);
                            
                            COMMIT; -- Einzel-Commit pro Mail ist hier sicher
                            DBMS_SESSION.SLEEP(1); -- Etwas weniger aggressiv als 10s?
                            
                        EXCEPTION WHEN OTHERS THEN
                            ROLLBACK; -- Sperre lösen
                            -- Hier evtl. Status auf 'FAILED' setzen, damit er nicht ewig loopt
--                            LILAM.LOG_ERROR('Mailer failed for Alert ' || rec.alert_id || ': ' || SQLERRM);
                        END;
                    END LOOP;
                END IF;
            END IF;
        END LOOP;
    END;

END LILAM_MAILER;
