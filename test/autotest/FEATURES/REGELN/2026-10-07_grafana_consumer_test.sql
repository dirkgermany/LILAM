-- =====================================================================
-- LILAM Diagnose: Grafana-Consumer fuer das U-Bahn-Beispiel
--
-- Voraussetzung: 2026-10-07_ubahn_simulation.sql ist gelaufen (Rule Set SUBWAY_PROD v5 aktiv fuer
-- Gruppe SUBWAY, PENDING-Alerts aus der Simulation), consumer/lilam_grafana installiert.
--
--   G1  Consumer startet als Job (ohne URL = imaginaerer Grafana-Dienst) und uebernimmt die beim Start
--       schon wartenden U-Bahn-Alerts (PENDING -> PROCESSED, je eine Zeile in LILAM_GRAFANA_OUTBOX)
--   G2  neuer Alert R-001 (Zug INSESSION, Moulin Rouge 320 s): Consumer reagiert auf das Signal (<= 3 s)
--   G3  Annotation: gueltiges JSON, time/timeEnd = Start/Ende der Ausfahrt (Dauer 320.000 ms),
--       Tags lilam, group:SUBWAY, rule:R-001, severity:CRITICAL, context:Moulin Rouge; Text nennt die Dauer
--   G4  Alerts anderer Gruppen auf demselben Kanal bleiben unberuehrt (PENDING)
--   G5  Grafana nicht erreichbar (URL auf geschlossenen Port): Alert -> ERROR mit Meldung, Outbox FAILED,
--       PROCESS_PENDING wirft keine Exception
--   G6  STOP beendet den Consumer-Job
--   G7  keine neuen internen LILAM-Fehler
-- Ergebnisse in LT_RUN / LT_CHECK (Test GRAFANA_CONSUMER).
-- =====================================================================
set serveroutput on size unlimited

declare
    c_channel constant varchar2(30) := 'LILAM_ALERT_MAIL_LOG';
    c_job     constant varchar2(30) := 'LILAM_GRAFANA_SUBWAY';
    l_run     number;
    l_start   timestamp := systimestamp;
    l_n       number;
    l_pending number;
    l_pid     number;
    l_t       timestamp := systimestamp - interval '1' hour;
    l_aid     number;
    l_fake1   number;
    l_fake2   number;
    l_body    clob;
    l_sent    timestamp;
    l_ms      number;
    l_tags    varchar2(4000);
    l_x       pls_integer;

    function fake_alert(p_group varchar2) return number is
        l_id number;
    begin
        insert into lilam_alerts (process_id, process_name, master_table_name, monitor_table_name, logging_table_name,
                                  action_name, context_name, group_name, action_count, rule_set_name, rule_id,
                                  rule_set_version, alert_severity, handler_type)
        values (-1, 'GRAFANA_TEST', 'LILAM_PROC', 'LILAM_MON', 'LILAM_LOG', 'STATION_EXIT', 'Moulin Rouge', p_group,
                1, 'SUBWAY_PROD', 'R-001', 5, 'CRITICAL', c_channel)
        returning alert_id into l_id;
        commit;
        return l_id;
    end;
begin
    l_run := lt.begin_run('GRAFANA_CONSUMER', 'INSESSION', 'Kanal LILAM_ALERT_MAIL_LOG, Gruppe SUBWAY, ohne URL');

    l_fake1 := fake_alert('OTHER_LINE');   -- G4
    select count(*) into l_pending from lilam_alerts
     where handler_type = c_channel and upper(group_name) = 'SUBWAY' and status = 'PENDING';

    -- G1
    lilam_grafana.start_job(p_maxSeconds => 120);
    for i in 1 .. 30 loop
        select count(*) into l_n from lilam_alerts
         where handler_type = c_channel and upper(group_name) = 'SUBWAY' and status = 'PENDING';
        exit when l_n = 0;
        dbms_session.sleep(0.5);
    end loop;
    select count(*) into l_x from lilam_grafana_outbox where created_at >= l_start and send_status = 'SIMULATED';
    lt.check_that(l_run, 'G1 wartende U-Bahn-Alerts beim Start uebernommen', l_pending > 0 and l_n = 0 and l_x = l_pending,
                  'vorher PENDING: ' || l_pending || ', danach: ' || l_n || ', Outbox SIMULATED: ' || l_x);

    -- G2 neuer Alert
    dbms_session.sleep(1); -- Consumer wartet wieder auf das Signal
    l_pid := lilam.new_process(p_processName => 'Line 1 Grafana', p_groupName => 'SUBWAY');
    lilam.trace_start(l_pid, 'STATION_EXIT', 'Moulin Rouge', l_t);
    l_sent := systimestamp;
    lilam.trace_stop(l_pid, 'STATION_EXIT', 'Moulin Rouge', l_t + interval '320' second);
    lilam.close_process(l_pid);
    begin
        select alert_id into l_aid from lilam_alerts where process_id = l_pid;
    exception when no_data_found then l_aid := null;
    end;
    for i in 1 .. 60 loop
        select count(*) into l_n from lilam_grafana_outbox where alert_id = l_aid;
        exit when l_n > 0;
        dbms_session.sleep(0.1);
    end loop;
    l_ms := lt.ms_since(l_sent);
    lt.check_that(l_run, 'G2 neuer Alert per Signal weitergereicht (<= 3 s)', l_aid is not null and l_n = 1 and l_ms <= 3000,
                  'alert_id ' || l_aid || ', Outbox-Zeilen: ' || l_n || ', nach ' || round(l_ms) || ' ms');
    lt.metric(l_run, 'Signal bis Outbox', l_ms, 'ms');

    -- G3 Inhalt
    begin
        select request_body into l_body from lilam_grafana_outbox where alert_id = l_aid fetch first 1 rows only;
        select listagg(value, ',') within group (order by value) into l_tags
          from json_table(l_body, '$.tags[*]' columns (value varchar2(200) path '$'));
        lt.check_that(l_run, 'G3 Annotation vollstaendig',
                 json_value(l_body, '$.timeEnd' returning number) - json_value(l_body, '$.time' returning number) = 320000
             and instr(l_tags, 'group:SUBWAY') > 0 and instr(l_tags, 'rule:R-001') > 0
             and instr(l_tags, 'severity:CRITICAL') > 0 and instr(l_tags, 'context:Moulin Rouge') > 0
             and instr(json_value(l_body, '$.text'), '320000 ms') > 0,
             substr(dbms_lob.substr(l_body, 900, 1), 1, 900));
    exception when others then
        lt.check_that(l_run, 'G3 Annotation vollstaendig', false, sqlerrm);
    end;

    -- G4
    select count(*) into l_n from lilam_alerts where alert_id = l_fake1 and status = 'PENDING';
    lt.check_that(l_run, 'G4 Alert anderer Gruppe bleibt PENDING', l_n = 1, 'PENDING: ' || l_n);

    -- G5 Grafana nicht erreichbar (eigene Gruppe, damit der laufende Job sie nicht nimmt)
    l_fake2 := fake_alert('SUBWAY_HTTPTEST');
    begin
        l_x := lilam_grafana.process_pending(p_groupName => 'SUBWAY_HTTPTEST', p_url => 'http://127.0.0.1:9');
        select count(*) into l_n from lilam_alerts where alert_id = l_fake2 and status = 'ERROR' and error_message is not null;
        select count(*) into l_x from lilam_grafana_outbox where alert_id = l_fake2 and send_status = 'FAILED';
        select substr(error_message, 1, 300) into l_tags from lilam_alerts where alert_id = l_fake2;
        lt.check_that(l_run, 'G5 Grafana nicht erreichbar: Alert ERROR, keine Exception', l_n = 1 and l_x = 1, l_tags);
    exception when others then
        lt.check_that(l_run, 'G5 Grafana nicht erreichbar: Alert ERROR, keine Exception', false, sqlerrm);
    end;

    -- G6
    lilam_grafana.stop;
    for i in 1 .. 20 loop
        select count(*) into l_n from user_scheduler_jobs where job_name = c_job;
        exit when l_n = 0;
        dbms_session.sleep(0.5);
    end loop;
    lt.check_that(l_run, 'G6 STOP beendet den Consumer', l_n = 0, 'Job noch vorhanden: ' || l_n);

    -- G7
    l_n := lt.internal_errors_since(l_start);
    lt.check_that(l_run, 'G7 keine neuen internen LILAM-Fehler', l_n = 0, 'neu: ' || l_n);

    -- Hilfszeilen entfernen
    delete from lilam_grafana_outbox where alert_id in (l_fake1, l_fake2);
    delete from lilam_alerts where alert_id in (l_fake1, l_fake2);
    commit;

    lt.end_run(l_run);
end;
/
