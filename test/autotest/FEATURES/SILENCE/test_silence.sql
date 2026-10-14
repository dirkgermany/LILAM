-- =====================================================================
-- LILAM Test: FEATURES / SILENCE
--
-- Prueft Schweige-Regeln (TIME_MAX_SILENCE_SECONDS): "seit X Sekunden kein Signal".
-- Ziele ueber trigger_type: PROCESS_START (kein Start), MARK_EVENT/TRACE_START (Reihe),
-- PROCESS_UPDATE (laufender Prozess schweigt). Zeitfenster (windows/time_zone).
-- Testfaelle 1-10 aus 03_lilam_ausbleib_erkennung.md (SPM), dazu Fenster und Validierung.
--
--   VALIDIERUNG (CHECK_RULE_SET):
--   V1-V9 unzulaessige Trigger, Werte, Context, Fenster; gueltiges Rule Set mit Fenstern
--   INSESSION (Gruppe LT_SI_IS, Pruefung ueber LILAM.CHECK_SILENCE, auch als Job):
--   I1  direkt nach Aktivierung kein Alert (Ziele ohne Signal zaehlen ab Aktivierung)       [Fall 5]
--   I2  regelmaessiger Start: kein Alert                                                   [Fall 1]
--   I3  Reihe mit Context: SAP schweigt => Alert, SIE nicht                                 [Fall 4]
--   I4  Trace-Reihe ohne Context: wechselnde Contexts halten sie am Leben
--   I5  Reihe ohne jedes Signal: Alert nach der Schweigezeit ab Aktivierung                [Fall 5]
--   I6  haengender Prozess: Alert mit process_id; nach CLOSE kein Eintrag mehr
--   I7  zwei Pruefjobs gleichzeitig: je Ziel genau ein Alert                              [Faelle 2, 6]
--   I8  Wiederholung nach throttle_seconds in anderer Session                              [Fall 3]
--   I9  Start bleibt aus: genau ein Alert, process_id NULL, process_name = Action        [Fall 2]
--   I10 Fenster: geschlossen kein Alert, offen Alert, frisch geoeffnet zaehlt ab Oeffnung [Fall 9]
--   I11 Rule Set geaendert: Eintraege entfernter Regeln geloescht, keine neuen Alerts    [Fall 8]
--   SERVER (Worker LT_S1, LT_S2, Gruppe LT):
--   S1  Housekeeping erkennt fehlenden Start und schweigende Reihe                        [Fall 7]
--   S2  zusaetzliche Pruefer (Session, Job): kein doppelter Alert                         [Fall 7]
--   S3  Neustart beider Worker: "zuletzt gesehen" bleibt, kein neuer Alert, neuer Start zaehlt [Fall 10]
--   ALLE:
--   A1  keine internen LILAM-Fehler
--
-- Der Test startet und stoppt seine Server selbst. Nur einzeln (aendert das Rule Set der Gruppe LT).
-- Laufzeit ca. 1,5-2 min.
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
-- Ergebnisse:      LT_RUN / LT_CHECK  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- =====================================================================
set serveroutput on size unlimited

declare
  c_set     constant varchar2(30) := 'LT_SILENCE';
  c_handler constant varchar2(30) := 'LT_SI_ALERT';
  c_is_grp  constant varchar2(30) := 'LT_SI_IS';
  l_run     number;
  l_mode    varchar2(20);
  l_t0      timestamp(6);
  l_err     number;
  -- Actions je Lauf (eigene Eintraege in LILAM_ALERT_STATE)
  a_start   varchar2(60);
  a_price   varchar2(60);
  a_trace   varchar2(60);
  a_run     varchar2(60);
  a_never   varchar2(60);
  a_wc      varchar2(60);
  a_wo      varchar2(60);
  a_wf      varchar2(60);
  a_nowin   varchar2(60);
  a_help    varchar2(60);
  s_start   varchar2(60);
  s_price   varchar2(60);

  function q(p_sql varchar2, p_b1 varchar2 default null, p_b2 varchar2 default null, p_b3 varchar2 default null) return number is
    r number;
  begin
    if p_b3 is not null then
      execute immediate p_sql into r using p_b1, p_b2, p_b3;
    elsif p_b2 is not null then
      execute immediate p_sql into r using p_b1, p_b2;
    else
      execute immediate p_sql into r using p_b1;
    end if;
    return r;
  exception when others then return -999;
  end;

  procedure chk(p_name varchar2, p_ok boolean, p_detail varchar2 default null) is
  begin
    lt.check_that(l_run, l_mode || ' ' || p_name, nvl(p_ok, false), p_detail);
  end;

  -- Alerts einer Regel (seit Testbeginn) in einer Gruppe
  function alerts(p_group varchar2, p_rule varchar2) return number is
    l_n number;
  begin
    execute immediate 'select count(*) from lilam_alerts where upper(group_name) = upper(:1) and rule_id = :2 and created_at >= :3'
      into l_n using p_group, p_rule, l_t0;
    return l_n;
  end;

  function wait_alerts(p_group varchar2, p_rule varchar2, p_expected number, p_max_s number) return number is
    l_w number := 0;
    l_n number;
  begin
    loop
      l_n := alerts(p_group, p_rule);
      exit when l_n >= p_expected or l_w >= p_max_s;
      dbms_session.sleep(0.5); l_w := l_w + 0.5;
    end loop;
    return l_n;
  end;

  -- Eintraege "zuletzt gesehen" (alle Arten ausser LOCK) einer Gruppe
  function seen_rows(p_group varchar2, p_kind varchar2 default null) return number is
    l_n number;
  begin
    execute immediate 'select count(*) from lilam_alert_state where group_name = upper(:1) and state_kind != ''LOCK''
                         and (:2 is null or state_kind = :3)'
      into l_n using p_group, p_kind, p_kind;
    return l_n;
  end;

  function seen_ts(p_group varchar2, p_kind varchar2, p_key varchar2) return timestamp is
    l_ts timestamp;
  begin
    execute immediate 'select max(ts_utc) from lilam_alert_state where group_name = upper(:1) and state_kind = :2 and state_key = :3'
      into l_ts using p_group, p_kind, p_key;
    return l_ts;
  end;

  function r(p_id varchar2, p_trig varchar2, p_action varchar2, p_ctx varchar2, p_secs number, p_throttle number,
             p_windows varchar2 default null) return varchar2 is
  begin
    return '{"id":"' || p_id || '","trigger_type":"' || p_trig || '","action":"' || p_action || '"'
        || case when p_ctx is not null then ',"context":"' || p_ctx || '"' end
        || ',"condition":{"operator":"TIME_MAX_SILENCE_SECONDS","value":"' || p_secs || '"}'
        || case when p_windows is not null then ',"windows":' || p_windows || ',"time_zone":"UTC"' end
        || ',"alert":{"handler":"' || c_handler || '","severity":"WARN","throttle_seconds":' || p_throttle || '}}';
  end;

  procedure put_rules(p_group varchar2, p_version number, p_rules varchar2) is
  begin
    execute immediate 'delete from lilam_rules where set_name = :1 and upper(group_name) = upper(:2) and version = :3'
      using c_set, p_group, p_version;
    execute immediate 'insert into lilam_rules(group_name, set_name, version, is_active, created, author, rule_set)
                       values (:1, :2, :3, 0, systimestamp, ''LT'', :4)'
      using p_group, c_set, p_version,
            to_clob('{"header":{"rule_set":"' || c_set || '","rule_set_version":' || p_version || '},"rules":[' || p_rules || ']}');
    commit;
    lilam.server_update_rules(p_group, c_set, p_version);
  end;

  -- Pruefung in einer fremden Session (Job); p_jobs gleichzeitige Pruefer
  procedure check_jobs(p_group varchar2, p_jobs number, p_tag varchar2) is
    l_ok boolean;
  begin
    for i in 1 .. p_jobs loop
      lt.run_job('LT_SI_' || p_tag || '_' || i || '_' || l_run, 'begin lilam.check_silence(''' || p_group || '''); end;');
    end loop;
    l_ok := lt.wait_jobs('LT_SI_' || p_tag || '_', 30);
    chk(p_tag || ' Pruefjobs beendet', l_ok);
  end;

  -- ein Takt Signale: SIE und Trace (wechselnder Context) halten ihre Reihen am Leben, optional ein Start
  procedure signal_round(p_help number, p_n number, p_with_start boolean) is
    l_p number;
  begin
    lilam.mark_event(p_help, a_price, 'SIE');
    lilam.trace_start(p_help, a_trace, 'X' || mod(p_n, 2));
    lilam.trace_stop(p_help, a_trace, 'X' || mod(p_n, 2));
    if p_with_start then
      l_p := lilam.new_process(p_processName => a_start, p_logLevel => lilam.logLevelInfo, p_groupName => c_is_grp);
      lilam.close_process(l_p);
    end if;
    lilam.flush;
  end;

  procedure validation is
    l_msg varchar2(1000);
    function bad(p_rule varchar2) return boolean is
      l_msg varchar2(1000);
    begin
      l_msg := lilam.check_rule_set('{"rules":[' || p_rule || ']}');
      return l_msg is not null;
    end;
  begin
    l_mode := 'VALIDIERUNG';
    chk('V1 Trigger TRACE_STOP abgelehnt', bad(r('X', 'TRACE_STOP', 'A', null, 5, 0)));
    chk('V2 Wert 0 abgelehnt', bad(r('X', 'MARK_EVENT', 'A', null, 0, 0)));
    chk('V3 Context bei PROCESS_START abgelehnt', bad(r('X', 'PROCESS_START', 'A', 'C', 5, 0)));
    chk('V4 Fenster bei anderem Operator abgelehnt',
        bad('{"id":"X","trigger_type":"MARK_EVENT","action":"A","condition":{"operator":"VAL_MAX","value":"1"},'
         || '"windows":[{"days":"MON-FRI","from":"09:00","to":"17:00"}],"time_zone":"UTC","alert":{"handler":"H"}}'));
    chk('V5 Fenster ohne time_zone abgelehnt',
        bad(replace(r('X', 'MARK_EVENT', 'A', null, 5, 0, '[{"days":"MON-FRI","from":"09:00","to":"17:00"}]'), ',"time_zone":"UTC"', '')));
    chk('V6 unbekannte Zeitzone abgelehnt',
        bad(replace(r('X', 'MARK_EVENT', 'A', null, 5, 0, '[{"days":"MON-FRI","from":"09:00","to":"17:00"}]'), '"UTC"', '"Mars/Olympus"')));
    chk('V7 ungueltige Tage abgelehnt', bad(r('X', 'MARK_EVENT', 'A', null, 5, 0, '[{"days":"MO-FR","from":"09:00","to":"17:00"}]')));
    chk('V8 from = to abgelehnt', bad(r('X', 'MARK_EVENT', 'A', null, 5, 0, '[{"days":"MON","from":"09:00","to":"09:00"}]')));
    chk('V8 Uhrzeit 25:00 abgelehnt', bad(r('X', 'MARK_EVENT', 'A', null, 5, 0, '[{"days":"MON","from":"25:00","to":"26:00"}]')));
    chk('V8 unbekannter Schluessel im Fenster abgelehnt', bad(r('X', 'MARK_EVENT', 'A', null, 5, 0, '[{"day":"MON","from":"09:00","to":"10:00"}]')));
    l_msg := lilam.check_rule_set('{"rules":['
          || replace(r('X', 'MARK_EVENT', 'A', 'C', 5, 0,
                       '[{"days":"MON-THU","from":"09:00","to":"13:00"},{"days":"MON-THU","from":"15:00","to":"19:00"},'
                    || '{"days":"FRI-MON","from":"22:00","to":"06:00"},{"days":"SAT,SUN","from":"00:00","to":"24:00"}]'),
                     '"UTC"', '"Europe/Berlin"')
          || ',' || r('Y', 'PROCESS_UPDATE', 'P', null, 600, 0) || ',' || r('Z', 'TRACE_START', 'T', null, 60, 0) || ']}');
    chk('V9 gueltiges Rule Set mit mehreren Fenstern', l_msg is null, l_msg);
  end;

  procedure run_insession is
    l_help  number;
    l_run_p number;
    l_n     number;
    l_now   timestamp := sys_extract_utc(systimestamp);
    l_open  varchar2(200);
    l_fresh varchar2(200);
    l_close varchar2(200);
    l_cnt   number;
    l_pname varchar2(100);
    l_pid   number;
  begin
    l_mode := lt.c_insession;
    -- Fenster in UTC: offen den ganzen Tag; frisch geoeffnet seit der aktuellen Minute; geschlossen (in 2 h)
    l_open  := '[{"days":"MON-SUN","from":"00:00","to":"24:00"}]';
    l_fresh := '[{"days":"MON-SUN","from":"' || to_char(l_now, 'HH24:MI') || '","to":"' || to_char(l_now + interval '60' minute, 'HH24:MI') || '"}]';
    l_close := '[{"days":"MON-SUN","from":"' || to_char(l_now + interval '120' minute, 'HH24:MI') || '","to":"' || to_char(l_now + interval '180' minute, 'HH24:MI') || '"}]';

    put_rules(c_is_grp, 1,
         r('I-START', 'PROCESS_START',  a_start, null,  3, 300) || ','
      || r('I-SAP',   'MARK_EVENT',     a_price, 'SAP', 3, 4)   || ','
      || r('I-SIE',   'MARK_EVENT',     a_price, 'SIE', 3, 300) || ','
      || r('I-TRACE', 'TRACE_START',    a_trace, null,  3, 300) || ','
      || r('I-RUN',   'PROCESS_UPDATE', a_run,   null,  3, 300) || ','
      || r('I-NEVER', 'MARK_EVENT',     a_never, null,  4, 300) || ','
      || r('I-WC',    'MARK_EVENT',     a_wc,    null,  1, 300, l_close) || ','
      || r('I-WO',    'MARK_EVENT',     a_wo,    null,  2, 300, l_open)  || ','
      || r('I-WF',    'MARK_EVENT',     a_wf,    null,  120, 300, l_fresh) || ','
      || r('I-NOWIN', 'MARK_EVENT',     a_nowin, null,  120, 300));

    -- I1: erste Pruefung legt die Ziele an, die zweite direkt danach loest nichts aus
    lilam.check_silence(c_is_grp);
    l_cnt := seen_rows(c_is_grp);
    chk('I1 Ziele bei Aktivierung angelegt (9 ohne RUN)', l_cnt = 9, l_cnt);
    lilam.check_silence(c_is_grp);
    l_n := 0;
    for c in (select rule_id from lilam_alerts where upper(group_name) = upper(c_is_grp) and created_at >= l_t0) loop
      l_n := l_n + 1;
    end loop;
    chk('I1 direkt nach Aktivierung kein Alert', l_n = 0, l_n);

    -- Fenster: "frisch" und "ohne Fenster" so stellen, als waere das letzte Signal 1 h alt
    execute immediate 'update lilam_alert_state set ts_utc = ts_utc - interval ''1'' hour
                        where group_name = upper(:1) and state_kind = ''EVENT'' and state_key in (:2, :3)'
      using c_is_grp, a_wf || '|', a_nowin || '|';
    commit;

    -- haengender Prozess und Hilfsprozess fuer die Signale
    l_run_p := lilam.new_process(p_processName => a_run, p_logLevel => lilam.logLevelInfo, p_groupName => c_is_grp);
    l_help  := lilam.new_process(p_processName => a_help, p_logLevel => lilam.logLevelInfo, p_groupName => c_is_grp);
    lilam.mark_event(l_help, a_price, 'SAP');    -- SAP sendet nur einmal
    for i in 1 .. 5 loop
      signal_round(l_help, i, true);
      dbms_session.sleep(1);
    end loop;
    signal_round(l_help, 6, true);
    chk('I6 Eintrag fuer laufenden Prozess vorhanden', seen_rows(c_is_grp, 'RUN') = 1, seen_rows(c_is_grp, 'RUN'));

    -- I7: zwei Pruefer gleichzeitig in fremden Sessions
    check_jobs(c_is_grp, 2, 'I7');
    l_n := alerts(c_is_grp, 'I-START'); chk('I2 regelmaessiger Start: kein Alert', l_n = 0, l_n);
    l_n := alerts(c_is_grp, 'I-SAP');   chk('I3/I7 SAP schweigt: genau 1 Alert', l_n = 1, l_n);
    l_n := alerts(c_is_grp, 'I-SIE');   chk('I3 SIE sendet: kein Alert', l_n = 0, l_n);
    l_n := alerts(c_is_grp, 'I-TRACE'); chk('I4 Trace mit wechselndem Context: kein Alert', l_n = 0, l_n);
    l_n := alerts(c_is_grp, 'I-NEVER'); chk('I5/I7 nie gesendet: genau 1 Alert ab Aktivierung', l_n = 1, l_n);
    l_n := alerts(c_is_grp, 'I-RUN');   chk('I6/I7 haengender Prozess: genau 1 Alert', l_n = 1, l_n);
    l_pid := q('select max(process_id) from lilam_alerts where rule_id = ''I-RUN'' and upper(group_name) = upper(:1)', c_is_grp);
    chk('I6 Alert traegt die process_id', l_pid = l_run_p, l_pid || ' / ' || l_run_p);
    l_n := alerts(c_is_grp, 'I-WC');    chk('I10 Fenster geschlossen: kein Alert', l_n = 0, l_n);
    l_n := alerts(c_is_grp, 'I-WO');    chk('I10 Fenster offen: 1 Alert', l_n = 1, l_n);
    l_n := alerts(c_is_grp, 'I-WF');    chk('I10 Fenster frisch geoeffnet: zaehlt ab Oeffnung, kein Alert', l_n = 0, l_n);
    l_n := alerts(c_is_grp, 'I-NOWIN'); chk('I10 Gegenprobe ohne Fenster: 1 Alert', l_n = 1, l_n);

    -- I6: nach CLOSE kein Eintrag mehr
    lilam.close_process(l_run_p);
    l_cnt := seen_rows(c_is_grp, 'RUN');
    chk('I6 nach CLOSE kein Eintrag fuer den Prozess', l_cnt = 0, l_cnt);

    -- I8/I9: Starts bleiben aus, SIE und Trace laufen weiter; nach Ablauf der Sperre von SAP (4 s) neue Pruefung
    for i in 1 .. 5 loop
      signal_round(l_help, i, false);
      dbms_session.sleep(1);
    end loop;
    check_jobs(c_is_grp, 1, 'I8');
    l_n := alerts(c_is_grp, 'I-SAP');   chk('I8 Wiederholung nach throttle_seconds: 2 Alerts', l_n = 2, l_n);
    l_n := alerts(c_is_grp, 'I-SIE');   chk('I8 SIE weiter ohne Alert', l_n = 0, l_n);
    l_n := alerts(c_is_grp, 'I-NEVER'); chk('I8 Sperre 300 s: weiter 1 Alert', l_n = 1, l_n);
    l_n := alerts(c_is_grp, 'I-RUN');   chk('I8 beendeter Prozess: weiter 1 Alert', l_n = 1, l_n);
    l_n := alerts(c_is_grp, 'I-START'); chk('I9 Start bleibt aus: genau 1 Alert', l_n = 1, l_n);
    execute immediate 'select max(process_name), count(process_id) from lilam_alerts
                        where rule_id = ''I-START'' and upper(group_name) = upper(:1) and created_at >= :2'
      into l_pname, l_cnt using c_is_grp, l_t0;
    chk('I9 Alert ohne Prozess: process_id NULL, process_name = Action', l_cnt = 0 and l_pname = a_start, l_pname || ' / ' || l_cnt);

    -- I11: neues Rule Set nur mit I-START
    put_rules(c_is_grp, 2, r('I-START', 'PROCESS_START', a_start, null, 3, 300));
    check_jobs(c_is_grp, 1, 'I11');
    l_cnt := seen_rows(c_is_grp);
    chk('I11 Eintraege entfernter Regeln geloescht (1 bleibt)', l_cnt = 1, l_cnt);
    l_n := alerts(c_is_grp, 'I-SAP') + alerts(c_is_grp, 'I-WO') + alerts(c_is_grp, 'I-NOWIN');
    chk('I11 keine neuen Alerts entfernter Regeln', l_n = 4, l_n);

    lilam.close_process(l_help);
  end;

  procedure run_server is
    l_p     number;
    l_n     number;
    l_ok    boolean;
    l_ts1   timestamp;
    l_ts2   timestamp;
  begin
    l_mode := lt.c_server;
    put_rules(lt.c_group, 1,
         r('S-START', 'PROCESS_START', s_start, null,  4, 300) || ','
      || r('S-SAP',   'MARK_EVENT',    s_price, 'SAP', 4, 300));
    dbms_session.sleep(1);

    l_p := lilam.server_new_process(p_processName => s_start, p_groupName => lt.c_group, p_logLevel => lilam.logLevelInfo);
    lilam.mark_event(l_p, s_price, 'SAP');
    lt.close_wait(l_p);

    -- S1: nur das Housekeeping der Worker prueft (alle 10 s)
    l_n := wait_alerts(lt.c_group, 'S-START', 1, 40);
    chk('S1 Housekeeping: fehlender Start erkannt', l_n = 1, l_n);
    l_n := wait_alerts(lt.c_group, 'S-SAP', 1, 15);
    chk('S1 Housekeeping: schweigende Reihe erkannt', l_n = 1, l_n);
    l_n := q('select count(*) from lilam_alerts where rule_id = ''S-START'' and upper(group_name) = upper(:1) and process_id is null', lt.c_group);
    chk('S1 Alert ohne Prozess (process_id NULL)', l_n >= 1, l_n);

    -- S2: weitere Pruefer
    lilam.check_silence(lt.c_group);
    check_jobs(lt.c_group, 2, 'S2');
    dbms_session.sleep(1);
    l_n := alerts(lt.c_group, 'S-START') + alerts(lt.c_group, 'S-SAP');
    chk('S2 zusaetzliche Pruefer: kein doppelter Alert', l_n = 2, l_n);

    -- S3: Neustart beider Worker
    l_ts1 := seen_ts(lt.c_group, 'START', s_start);
    l_ok := lt.stop_server('LT_S1');
    l_ok := lt.stop_server('LT_S2') and l_ok;
    chk('S3 Worker gestoppt', l_ok);
    lt.start_server('LT_S1');
    lt.start_server('LT_S2');
    lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2'));
    dbms_session.sleep(12);   -- mindestens eine Pruefung nach dem Neustart
    l_ts2 := seen_ts(lt.c_group, 'START', s_start);
    chk('S3 "zuletzt gesehen" bleibt nach Neustart erhalten', l_ts1 is not null and l_ts2 = l_ts1,
        to_char(l_ts1, 'HH24:MI:SS.FF3') || ' / ' || to_char(l_ts2, 'HH24:MI:SS.FF3'));
    l_n := alerts(lt.c_group, 'S-START');
    chk('S3 nach Neustart kein neuer Alert (Sperre)', l_n = 1, l_n);
    l_p := lilam.server_new_process(p_processName => s_start, p_groupName => lt.c_group, p_logLevel => lilam.logLevelInfo);
    lt.close_wait(l_p);
    for i in 1 .. 20 loop
      l_ts2 := seen_ts(lt.c_group, 'START', s_start);
      exit when l_ts2 > l_ts1;
      dbms_session.sleep(0.5);
    end loop;
    chk('S3 neuer Start nach Neustart erneuert "zuletzt gesehen"', l_ts2 > l_ts1,
        to_char(l_ts1, 'HH24:MI:SS.FF3') || ' / ' || to_char(l_ts2, 'HH24:MI:SS.FF3'));
  end;
begin
  l_run := lt.begin_run('SILENCE', 'INSESSION+SERVER');
  l_t0  := systimestamp;
  a_start := 'SI_POLL_'  || l_run;
  a_price := 'SI_PRICE_' || l_run;
  a_trace := 'SI_TRACE_' || l_run;
  a_run   := 'SI_RUN_'   || l_run;
  a_never := 'SI_NEVER_' || l_run;
  a_wc    := 'SI_WC_'    || l_run;
  a_wo    := 'SI_WO_'    || l_run;
  a_wf    := 'SI_WF_'    || l_run;
  a_nowin := 'SI_NOWIN_' || l_run;
  a_help  := 'SI_HELP_'  || l_run;
  s_start := 'SV_POLL_'  || l_run;
  s_price := 'SV_PRICE_' || l_run;
  lt.stop_all_servers;

  validation;
  run_insession;

  lt.start_server('LT_S1');
  lt.start_server('LT_S2');
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2'));
  run_server;
  lt.stop_all_servers;

  l_mode := 'ALLE';
  l_err := lt.internal_errors_since(l_t0);
  chk('A1 keine internen LILAM-Fehler', l_err = 0, l_err);

  -- Testgruppen ohne aktives Rule Set und ohne Zustand zuruecklassen
  execute immediate 'delete from lilam_rules where set_name = :1' using c_set;
  execute immediate 'delete from lilam_alert_state where group_name in (upper(:1), upper(:2))' using c_is_grp, lt.c_group;
  commit;
  lt.end_run(l_run);
exception
  when others then
    dbms_output.put_line('ABBRUCH: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
    lt.check_that(l_run, 'Abbruch', false, substr(sqlerrm || ' ' || dbms_utility.format_error_backtrace, 1, 1000));
    lt.stop_all_servers;
    lt.end_run(l_run);
end;
/
