-- =====================================================================
-- LILAM Diagnose: FEATURES / REGELN / U-Bahn-Beispiel
--
-- Simuliert das U-Bahn-Beispiel aus docs/architecture and concepts.md (Abschnitt "JSON Structure"):
-- Rule Set SUBWAY_PROD, Version 5, "Performance rules for Line 1", Regel R-001:
--   TRACE_STOP der Aktion STATION_EXIT im Kontext "Moulin Rouge" dauert laenger als 300.000 ms
--   => Alert CRITICAL ueber den Kanal LILAM_ALERT_MAIL_LOG, Drosselung 900 s.
--
-- Die Fahrzeiten werden ueber p_timestamp von TRACE_START/TRACE_STOP vorgegeben (Zeitbasis 2 h
-- in der Vergangenheit), damit ein Lauf keine 5 Minuten je Ausfahrt warten muss. Die Drosselung
-- rechnet dagegen mit der echten Uhrzeit (SYSTIMESTAMP); innerhalb eines Laufs gilt sie also.
--
-- Je Modus (SERVER mit eigenem Server UB_S1 der Gruppe SUBWAY, INSESSION mit p_groupName => 'SUBWAY'):
--   U0  Beispiel-JSON aus der Doku ist gueltig (CHECK_RULE_SET), SERVER_UPDATE_RULES aktiviert es
--   U1  normale Fahrt ueber 4 Stationen (je 40 s Ausfahrt): kein Alert
--   U2  Ausfahrt Moulin Rouge genau 300.000 ms: kein Alert (Bedingung ist "groesser als")
--   U3  Ausfahrt Moulin Rouge 301.000 ms: genau ein Alert R-001 mit allen Feldern
--   U4  zweite Verspaetung in Moulin Rouge im selben Zug (400 s) innerhalb von 900 s: gedrosselt
--   U5  Ausfahrt Bastille 600 s: kein Alert (Kontext-Regel gilt nur fuer Moulin Rouge)
--   U6  anderer Zug (anderer Prozessname = eigener Baseline-Scope), Moulin Rouge 350 s: eigener Alert
--   U7  dritter Zug mit demselben Prozessnamen wie U3 (gleicher Scope): gedrosselt (Drosselung je Scope)
--   U8  DBMS_ALERT-Signal LILAM_ALERT_MAIL_LOG kommt bei einem wartenden Listener (Job) an,
--       Payload ist JSON mit rule_id R-001 und group_name SUBWAY
--   U9  LILAM_MON enthaelt die Ausfahrt mit 301.000 ms Dauer
--   U10 keine neuen internen LILAM-Fehler
--
-- Ergebnisse in LT_RUN / LT_CHECK / LT_JOBLOG (Test UBAHN_SIMULATION). Benoetigt die Testbasis (Package LT).
-- Legt an bzw. aendert: LILAM_RULES (Gruppe SUBWAY), Server UB_S1 (wird am Ende gestoppt).
-- Die Alerts bleiben mit STATUS = PENDING stehen; der Grafana-Consumer (consumer/lilam_grafana) kann sie abholen.
-- =====================================================================
set serveroutput on size unlimited

declare
    c_group    constant varchar2(20) := 'SUBWAY';
    c_set      constant varchar2(30) := 'SUBWAY_PROD';
    c_ver      constant pls_integer  := 5;
    c_pipe     constant varchar2(20) := 'UB_S1';
    c_pw       constant varchar2(20) := 'UbSimPw';
    c_channel  constant varchar2(30) := 'LILAM_ALERT_MAIL_LOG';

    -- Rule Set wortgleich aus docs/architecture and concepts.md
    c_json constant varchar2(4000) := q'~{
  "header": {
    "rule_set": "SUBWAY_PROD",
    "rule_set_version": 5,
    "description": "Performance rules for Line 1"
  },
  "rules": [
    {
      "id": "R-001",
      "trigger_type": "TRACE_STOP",
      "action": "STATION_EXIT",
      "context": "Moulin Rouge",
      "condition": {
        "operator": "MAX_DURATION_MS",
        "value": "300000"
      },
      "alert": {
        "handler": "LILAM_ALERT_MAIL_LOG",
        "severity": "CRITICAL",
        "throttle_seconds": 900
      }
    }
  ]
}~';

    l_run      number;
    l_start    timestamp := systimestamp;
    l_msg      varchar2(4000);
    l_cnt      number;

    -- Fahrt: eine Ausfahrt mit vorgegebener Dauer; t = laufende Simulationszeit
    procedure station_exit(p_pid number, p_station varchar2, p_ms number, p_t in out timestamp) is
    begin
        lilam.trace_start(p_pid, 'STATION_EXIT', p_station, p_t);
        p_t := p_t + numtodsinterval(p_ms / 1000, 'SECOND');
        lilam.trace_stop(p_pid, 'STATION_EXIT', p_station, p_t);
        p_t := p_t + interval '90' second; -- Fahrt zur naechsten Station
    end;

    function new_train(p_mode varchar2, p_name varchar2) return number is
    begin
        if p_mode = lt.c_server then
            return lilam.server_new_process(p_processName => p_name, p_groupName => c_group);
        end if;
        return lilam.new_process(p_processName => p_name, p_groupName => c_group);
    end;

    -- Alerts eines Prozesses (Server schreibt asynchron: bis p_max_sec warten)
    function alerts_of(p_pid number, p_expected number, p_max_sec number default 10) return number is
        l_n number; l_w number := 0;
    begin
        loop
            select count(*) into l_n from lilam_alerts where process_id = p_pid;
            exit when l_n >= p_expected or l_w >= p_max_sec;
            dbms_session.sleep(0.5); l_w := l_w + 0.5;
        end loop;
        return l_n;
    end;

    procedure stop_ub_server is
        l_chan varchar2(60) := 'UB_SHUT_' || sys_context('USERENV', 'SID');
        l_st   pls_integer;
        l_w    number := 0;
    begin
        dbms_pipe.reset_buffer;
        dbms_pipe.pack_message('{"header":{"msg_type":"API_CALL","request":"SERVER_SHUTDOWN","response":"' || l_chan
                               || '"},"payload":{"pipe_name":"' || c_pipe || '","shutdown_password":"' || c_pw || '"}}');
        l_st := dbms_pipe.send_message(c_pipe, timeout => 2);
        l_st := dbms_pipe.receive_message(l_chan, timeout => 10);
        l_st := dbms_pipe.remove_pipe(l_chan);
        loop
            select count(*) into l_cnt from user_scheduler_jobs where job_name = c_pipe;
            exit when l_cnt = 0 or l_w >= 15;
            dbms_session.sleep(0.5); l_w := l_w + 0.5;
        end loop;
        if l_cnt > 0 then
            begin dbms_scheduler.stop_job(c_pipe, force => true); exception when others then null; end;
        end if;
    end;

    procedure scenario(p_mode varchar2) is
        p       varchar2(3) := case p_mode when lt.c_server then 'S-' else 'I-' end;
        l_t     timestamp := systimestamp - interval '2' hour;
        l_a     number; l_b number; l_c number; l_d number; l_e number;
        l_n     number;
        l_rec   lilam_alerts%rowtype;
        l_used  number;
        l_sig   number;
        l_pay   varchar2(4000);
        l_job   varchar2(30) := 'UB_LISTEN_' || substr(p_mode, 1, 1);
    begin
        -- Listener-Job fuer das DBMS_ALERT-Signal (U8): wartet bis 60 s, schreibt jede Nachricht nach LT_JOBLOG
        lt.run_job(l_job,
            'declare l_msg varchar2(4000); l_st integer; l_end timestamp := systimestamp + interval ''60'' second;
             begin
               dbms_alert.register(''' || c_channel || ''');
               lt.joblog(' || l_run || ', 0, ''LISTEN_READY'', ''' || p_mode || ''');
               loop
                 dbms_alert.waitone(''' || c_channel || ''', l_msg, l_st, 5);
                 if l_st = 0 then lt.joblog(' || l_run || ', 0, ''SIGNAL_' || substr(p_mode, 1, 1) || ''', l_msg); end if;
                 exit when systimestamp > l_end;
               end loop;
               dbms_alert.remove(''' || c_channel || ''');
             end;');
        for i in 1 .. 20 loop
            select count(*) into l_n from lt_joblog where run_id = l_run and phase = 'LISTEN_READY' and info = p_mode;
            exit when l_n > 0;
            dbms_session.sleep(0.5);
        end loop;

        -- U1 normale Fahrt
        l_a := new_train(p_mode, 'Line 1 Normal ' || p_mode);
        station_exit(l_a, 'Concorde', 40000, l_t);
        station_exit(l_a, 'Moulin Rouge', 40000, l_t);
        station_exit(l_a, 'Bastille', 40000, l_t);
        station_exit(l_a, 'Nation', 40000, l_t);

        -- U2-U5 Zug mit Verspaetungen
        l_b := new_train(p_mode, 'Line 1 ' || p_mode);
        station_exit(l_b, 'Moulin Rouge', 300000, l_t);   -- U2 Grenze
        station_exit(l_b, 'Moulin Rouge', 301000, l_t);   -- U3 Alert
        station_exit(l_b, 'Moulin Rouge', 400000, l_t);   -- U4 gedrosselt
        station_exit(l_b, 'Bastille', 600000, l_t);       -- U5 anderer Kontext

        -- U6 anderer Zug (eigener Scope)
        l_c := new_train(p_mode, 'Line 1 Train 2 ' || p_mode);
        station_exit(l_c, 'Moulin Rouge', 350000, l_t);

        -- U7 dritter Zug, gleicher Prozessname wie U3 (gleicher Scope)
        l_d := new_train(p_mode, 'Line 1 ' || p_mode);
        station_exit(l_d, 'Moulin Rouge', 500000, l_t);

        -- Signal abwarten (Server: asynchron)
        l_n := alerts_of(l_b, 1);
        l_n := alerts_of(l_c, 1);

        lt.check_that(l_run, p || 'U1 normale Fahrt ohne Alert', alerts_of(l_a, 1, 3) = 0,
                      'Alerts: ' || alerts_of(l_a, 1, 0));

        select count(*) into l_n from lilam_alerts where process_id = l_b;
        lt.check_that(l_run, p || 'U2-U5 Zug mit Verspaetungen: genau 1 Alert', l_n = 1,
                      'Alerts: ' || l_n || ' (erwartet 1: 300 s kein Alert, 301 s Alert, 400 s gedrosselt, Bastille ohne Regel)');

        begin
            select * into l_rec from lilam_alerts where process_id = l_b and rownum = 1;
            lt.check_that(l_run, p || 'U3 Alert-Zeile R-001 vollstaendig',
                   l_rec.rule_id = 'R-001' and l_rec.alert_severity = 'CRITICAL' and l_rec.handler_type = c_channel
               and l_rec.action_name = 'STATION_EXIT' and l_rec.context_name = 'Moulin Rouge'
               and l_rec.rule_set_name = c_set and l_rec.rule_set_version = c_ver
               and upper(l_rec.group_name) = c_group and l_rec.status = 'PENDING' and l_rec.action_count = 2,
               l_rec.rule_id || ' ' || l_rec.alert_severity || ' ' || l_rec.handler_type || ' ' || l_rec.action_name
               || '|' || l_rec.context_name || ' ' || l_rec.rule_set_name || ' v' || l_rec.rule_set_version
               || ' Gruppe ' || l_rec.group_name || ' ' || l_rec.status || ' action_count ' || l_rec.action_count);
        exception when no_data_found then
            lt.check_that(l_run, p || 'U3 Alert-Zeile R-001 vollstaendig', false, 'keine Alert-Zeile');
        end;

        select count(*) into l_n from lilam_alerts where process_id = l_c;
        lt.check_that(l_run, p || 'U6 anderer Zug: eigener Alert', l_n = 1, 'Alerts: ' || l_n);

        select count(*) into l_n from lilam_alerts where process_id = l_d;
        lt.check_that(l_run, p || 'U7 gleicher Prozessname: gedrosselt (Scope)', l_n = 0, 'Alerts: ' || l_n);

        lilam.close_process(l_a); lilam.close_process(l_b); lilam.close_process(l_c); lilam.close_process(l_d);

        -- U8 Signal
        for i in 1 .. 20 loop
            select count(*) into l_sig from lt_joblog where run_id = l_run and phase = 'SIGNAL_' || substr(p_mode, 1, 1);
            exit when l_sig > 0;
            dbms_session.sleep(0.5);
        end loop;
        l_pay := null;
        for r in (select info from lt_joblog where run_id = l_run and phase = 'SIGNAL_' || substr(p_mode, 1, 1) order by ts desc) loop
            l_pay := r.info; exit;
        end loop;
        lt.check_that(l_run, p || 'U8 DBMS_ALERT-Signal mit JSON-Payload empfangen',
                      l_sig > 0 and json_value(l_pay, '$.rule_id') = 'R-001' and upper(json_value(l_pay, '$.group_name')) = c_group,
                      'Signale: ' || l_sig || ', letzte Payload: ' || substr(l_pay, 1, 400));

        -- U9 Monitor-Zeile mit Dauer (nach CLOSE_PROCESS geschrieben)
        for i in 1 .. 20 loop
            execute immediate 'select max(used_millis) from lilam_mon where process_id = :1 and action = ''STATION_EXIT''
                                 and context = ''Moulin Rouge'' and action_count = 2' into l_used using l_b;
            exit when l_used is not null;
            dbms_session.sleep(0.5);
        end loop;
        lt.check_that(l_run, p || 'U9 LILAM_MON: Ausfahrt mit 301.000 ms', round(l_used) = 301000, 'used_millis: ' || l_used);
    end;
begin
    l_run := lt.begin_run('UBAHN_SIMULATION', 'SERVER+INSESSION', 'Rule Set SUBWAY_PROD v5 aus der Doku');

    -- U0 Rule Set
    l_msg := lilam.check_rule_set(c_json);
    lt.check_that(l_run, 'U0 Beispiel-JSON der Doku gueltig (CHECK_RULE_SET)', l_msg is null, l_msg);

    delete from lilam_rules where upper(group_name) = c_group;
    insert into lilam_rules (group_name, set_name, version, created, author, rule_set)
    values (c_group, c_set, c_ver, systimestamp, 'UBAHN_SIMULATION', c_json);
    commit;
    begin
        lilam.server_update_rules(c_group, c_set, c_ver);
        select count(*) into l_cnt from lilam_rules where upper(group_name) = c_group and is_active = 1 and version = c_ver;
        lt.check_that(l_run, 'U0 SERVER_UPDATE_RULES aktiviert SUBWAY_PROD v5', l_cnt = 1, 'aktiv: ' || l_cnt);
    exception when others then
        lt.check_that(l_run, 'U0 SERVER_UPDATE_RULES aktiviert SUBWAY_PROD v5', false, sqlerrm);
    end;

    -- SERVER
    l_msg := lilam.create_server(c_pipe, c_group, c_pw, 0);
    dbms_output.put_line('    ' || l_msg);
    lt.wait_servers_ready(sys.odcivarchar2list(c_pipe));
    scenario(lt.c_server);
    stop_ub_server;

    -- INSESSION
    scenario(lt.c_insession);

    -- U10
    l_cnt := lt.internal_errors_since(l_start);
    lt.check_that(l_run, 'U10 keine neuen internen LILAM-Fehler', l_cnt = 0, 'neu in LILAM_LOG_INTERNAL: ' || l_cnt);

    lt.end_run(l_run);
end;
/
