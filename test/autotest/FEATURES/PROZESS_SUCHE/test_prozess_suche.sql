-- =====================================================================
-- LILAM Test: FEATURES / PROZESS_SUCHE
--
-- Prueft GET_ACTIVE_PROCESSES und SERVER_CONNECT_PROCESS (2 Worker LT_S1/LT_S2 + Dispatcher LT_DISP).
-- Jeder Request laeuft als eigener Scheduler-Job, also in einer eigenen Session mit leerem PGA
-- (wie ein Request aus dem ORDS-Pool). Die Anwendung verwaltet keine process_id.
--
--   P1  kein Treffer: leere Liste, ohne die Wartezeit auszuschoepfen; ohne Dispatcher ebenfalls leer
--   P2  SERVER_CONNECT_PROCESS legt an; weitere Sessions landen beim selben Prozess (auch in Kleinschreibung)
--   P3  GET_ACTIVE_PROCESSES aus einer dritten Session liefert die ID und verbindet nicht
--   P4  In-Session-Prozess: sichtbar in der eigenen Session, nicht in einer anderen
--   P5  gleicher Name auf beiden Workern: beide IDs sortiert; CONNECT nimmt die niedrigste
--   P6  parallele Requests (3 Runden x 6): genau ein Prozess, alle dieselbe ID, alle Logs darin
--   P7  nach CLOSE_PROCESS: nicht mehr aktiv, CONNECT legt einen neuen Prozess an
--   P8  Worker haengt (Registry-Zeile gesperrt): Teilergebnis, CONNECT liefert Timeout und legt nichts an;
--       danach findet CONNECT den Prozess wieder
--   P9  Worker gestoppt: Prozess in _PROC offen, aber nicht aktiv; CONNECT legt neu an
--   P10 CALL_BY_JSON: beide Aufrufe
--   P11 Fehlerfaelle: Gruppe ohne Dispatcher, kein Name
--   P12 keine Sperren uebrig, keine unerwarteten internen Fehler
--
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql
--                  job_queue_processes (im CDB-Root) >= 10; nur einzeln ausfuehren
-- Ergebnisse:      LT_RUN / LT_CHECK / LT_METRIC  (Uebersicht: _COMMON/03_ergebnisse.sql)
-- Hilfsobjekte:    LT_PS_RESULT, LT_PS_REQUEST, LT_PS_HOLD (werden bei jedem Lauf neu angelegt)
-- =====================================================================
set serveroutput on size unlimited

begin
  begin execute immediate 'drop table lt_ps_result purge'; exception when others then null; end;
  execute immediate 'create table lt_ps_result (
      step varchar2(30), kind varchar2(20), sid number, ms number,
      pid number, ids varchar2(4000), resp varchar2(4000), info varchar2(4000))';
end;
/

create or replace procedure lt_ps_request(
    p_step varchar2,
    p_kind varchar2,
    p_name varchar2,
    p_wait number   default null,
    p_go   varchar2 default null)   -- UTC-Startzeitpunkt YYYYMMDDHH24MISSFF3 fuer gleichzeitigen Start
as
    l_pid  number;
    l_ids  sys.odcinumberlist;
    l_list varchar2(4000);
    l_resp varchar2(8000);
    l_t0   timestamp(6);

    procedure rec(p_info varchar2) is
        pragma autonomous_transaction;
    begin
        insert into lt_ps_result(step, kind, sid, ms, pid, ids, resp, info)
        values (p_step, p_kind, to_number(sys_context('USERENV', 'SID')), lt.ms_since(l_t0), l_pid, l_list, l_resp, p_info);
        commit;
    end;

    procedure list_ids is
    begin
        for i in 1 .. l_ids.count loop
            l_list := l_list || case when i > 1 then ',' end || l_ids(i);
        end loop;
    end;
begin
    if p_go is not null then
        while sys_extract_utc(systimestamp) < to_timestamp(p_go, 'YYYYMMDDHH24MISSFF3') loop
            dbms_session.sleep(0.005);
        end loop;
    end if;
    l_t0 := systimestamp;

    case p_kind
        when 'ACTIVE' then
            lilam.set_dispatcher_pipe(lt.c_disp_pipe);
            l_ids := lilam.get_active_processes(p_name, p_wait);
            list_ids;
        when 'ACTIVE_NODISP' then
            l_ids := lilam.get_active_processes(p_name, p_wait);
            list_ids;
        when 'CONNECT' then
            l_pid := lilam.server_connect_process(p_name, lt.c_group, p_logLevel => lilam.logLevelDebug, p_maxWaitMs => p_wait);
            if l_pid > 0 then
                l_list := lilam.get_server_pipe(l_pid);
                lilam.info(l_pid, p_step || ': connect');
            end if;
        when 'CONNECT_NOGROUP' then
            l_pid := lilam.server_connect_process(p_name, 'LT_KEINE_GRUPPE', p_maxWaitMs => p_wait);
        when 'JSON_ACTIVE' then
            lilam.set_dispatcher_pipe(lt.c_disp_pipe);
            lilam.call_by_json('{"header":{"api_call":"GET_ACTIVE_PROCESSES"},"params":{"process_name":"' || p_name || '"}}', l_resp);
        when 'JSON_CONNECT' then
            lilam.call_by_json('{"header":{"api_call":"SERVER_CONNECT_PROCESS"},"params":{"process_name":"' || p_name
                               || '","group_name":"' || lt.c_group || '","max_wait_ms":2000}}', l_resp);
    end case;
    rec('OK');
exception
    when others then
        rec('ERROR ' || sqlerrm || ' | ' || dbms_utility.format_error_backtrace);
end;
/

-- Haelt die Registry-Zeile eines Workers gesperrt: er bleibt in seinem Housekeeping stehen und liest seine Pipe nicht
create or replace procedure lt_ps_hold(p_pipe varchar2, p_sec number)
as
    l_x varchar2(100);

    procedure rec(p_step varchar2) is
        pragma autonomous_transaction;
    begin
        insert into lt_ps_result(step, kind, info) values (p_step, 'HOLD', 'OK');
        commit;
    end;
begin
    select pipe_name into l_x from lilam_server_registry where upper(pipe_name) = upper(p_pipe) for update;
    rec('HOLD');
    dbms_session.sleep(p_sec);
    rollback;
    rec('HOLDEND');
end;
/

declare
  c_hold_s constant number := 8;   -- deutlich unter C_MAX_REGISTRY_HEARTBEAT_AGE_SEC (15 s)
  l_run    number;
  l_pfx    varchar2(40);
  l_pid    number;
  l_pid2   number;
  l_a      number;
  l_b      number;
  l_cnt    number;
  l_num    number;
  l_txt    varchar2(4000);
  l_pipeA  varchar2(100);
  l_pipeB  varchar2(100);
  l_ids    sys.odcinumberlist;
  l_seq    number := 0;

  procedure run_req(p_step varchar2, p_kind varchar2, p_name varchar2, p_wait number default null, p_go varchar2 default null) is
  begin
    lt.run_job('LT_CPS_' || p_step,   -- Praefix LT_C: Client-Job (wird von stop_all_servers nicht als Server behandelt)
      'begin lt_ps_request(''' || p_step || ''', ''' || p_kind || ''', '
      || case when p_name is null then 'null' else '''' || p_name || '''' end || ', '
      || nvl(to_char(p_wait), 'null') || ', '
      || case when p_go is null then 'null' else '''' || p_go || '''' end || '); end;');
  end;

  procedure wait_for(p_steps sys.odcivarchar2list, p_max_sec number default 30) is
    l_c number; l_waited number := 0;
  begin
    loop
      select count(*) into l_c from lt_ps_result where step in (select column_value from table(p_steps));
      exit when l_c = p_steps.count or l_waited >= p_max_sec;
      dbms_session.sleep(0.2); l_waited := l_waited + 0.2;
    end loop;
  end;

  procedure req(p_step varchar2, p_kind varchar2, p_name varchar2, p_wait number default null) is
  begin
    run_req(p_step, p_kind, p_name, p_wait);
    wait_for(sys.odcivarchar2list(p_step));
  end;

  function r_pid(p_step varchar2) return number is
    l_v number;
  begin
    select max(pid) into l_v from lt_ps_result where step = p_step;
    return l_v;
  end;

  function r_ids(p_step varchar2) return varchar2 is
    l_v varchar2(4000);
  begin
    select max(ids) into l_v from lt_ps_result where step = p_step;
    return l_v;
  end;

  function r_ms(p_step varchar2) return number is
    l_v number;
  begin
    select max(ms) into l_v from lt_ps_result where step = p_step;
    return l_v;
  end;

  function r_resp(p_step varchar2) return varchar2 is
    l_v varchar2(4000);
  begin
    select max(resp) into l_v from lt_ps_result where step = p_step;
    return l_v;
  end;

  function route_of(p_pid number) return varchar2 is
    l_v varchar2(100);
  begin
    select max(pipe_name) into l_v from lilam_process_route where process_id = p_pid;
    return l_v;
  end;

  -- Neuer Prozess auf dem anderen Worker als p_pipe: die Auswahl nimmt den Worker mit den wenigsten
  -- offenen Prozessen, also erst p_pipe mit Fuellprozessen vorn halten
  function open_elsewhere(p_name varchar2, p_pipe varchar2) return number is
    l_own   number;
    l_other number;
    l_fill  number;
  begin
    for i in 1 .. 20 loop
      select count(case when pipe_name = p_pipe then 1 end), count(case when pipe_name != p_pipe then 1 end)
        into l_own, l_other from lilam_process_route;
      exit when l_own > l_other;
      l_fill := lilam.server_new_process(l_pfx || 'FUELL', lt.c_group);
    end loop;
    return lilam.server_new_process(p_name, lt.c_group);
  end;

  function go_at(p_sec number) return varchar2 is
  begin
    return to_char(sys_extract_utc(systimestamp) + numtodsinterval(p_sec, 'SECOND'), 'YYYYMMDDHH24MISSFF3');
  end;
begin
  l_run := lt.begin_run('PROZESS_SUCHE', 'DISPATCHER');
  l_pfx := 'LT_' || l_run || '_';

  lt.start_server('LT_S1'); lt.start_server('LT_S2'); lt.start_server('LT_DISP', 1);
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2', 'LT_DISP'));
  lilam.set_dispatcher_pipe(lt.c_disp_pipe);

  -- P1 kein Treffer
  req('A1', 'ACTIVE', l_pfx || 'LEER');
  lt.check_that(l_run, 'P1 kein Treffer: leere Liste', r_ids('A1') is null, r_ids('A1'));
  lt.check_that(l_run, 'P1 kein Treffer: Wartezeit nicht ausgeschoepft (< 1.000 ms)', r_ms('A1') < 1000, r_ms('A1') || ' ms');
  lt.metric(l_run, 'active_leer_ms', r_ms('A1'), 'ms');
  req('A2', 'ACTIVE_NODISP', l_pfx || 'LEER');
  lt.check_that(l_run, 'P1 ohne Dispatcher: leere Liste, ohne Wartezeit (< 200 ms)', r_ids('A2') is null and r_ms('A2') < 200, r_ms('A2') || ' ms');

  -- P2 anlegen und wiederfinden
  req('C1', 'CONNECT', l_pfx || 'EINS');
  l_pid := r_pid('C1');
  lt.check_that(l_run, 'P2 CONNECT legt den Prozess an', nvl(l_pid, -1) > 0, 'pid ' || l_pid);
  lt.check_that(l_run, 'P2 Route vorhanden', route_of(l_pid) is not null, route_of(l_pid));
  lt.metric(l_run, 'connect_anlegen_ms', r_ms('C1'), 'ms');

  req('C2', 'CONNECT', l_pfx || 'EINS');
  req('C3', 'CONNECT', lower(l_pfx || 'EINS'));
  lt.check_that(l_run, 'P2 zweite Session: dieselbe ID', r_pid('C2') = l_pid, r_pid('C2'));
  lt.check_that(l_run, 'P2 Kleinschreibung: dieselbe ID', r_pid('C3') = l_pid, r_pid('C3'));
  lt.metric(l_run, 'connect_treffer_ms', r_ms('C2'), 'ms');
  select count(distinct sid) into l_cnt from lt_ps_result where step in ('C1', 'C2', 'C3');
  lt.check_that(l_run, 'P2 mehrere Sessions', l_cnt > 1, l_cnt || ' Sessions');
  l_num := lt.wait_count(l_pfx || 'EINS', 'LOG', 3, 10);
  l_cnt := lt.count_lilam(l_pfx || 'EINS', 'LOG');
  lt.check_that(l_run, 'P2 Logs aller drei Sessions im selben Prozess', l_cnt = 3, l_cnt);
  lt.check_that(l_run, 'P2 kein zweiter Prozess', lt.count_lilam(l_pfx || 'EINS', 'PROC') = 1, lt.count_lilam(l_pfx || 'EINS', 'PROC'));

  -- P3 nur lesen
  req('A3', 'ACTIVE', l_pfx || 'EINS');
  lt.check_that(l_run, 'P3 GET_ACTIVE_PROCESSES liefert die ID', r_ids('A3') = to_char(l_pid), r_ids('A3'));
  lt.metric(l_run, 'active_treffer_ms', r_ms('A3'), 'ms');

  -- P4 In-Session
  l_a := lilam.new_process(l_pfx || 'INS');
  l_ids := lilam.get_active_processes(l_pfx || 'INS');
  lt.check_that(l_run, 'P4 In-Session: eigene Session sieht den Prozess', l_ids.count = 1 and l_ids(1) = l_a, l_ids.count);
  req('A4', 'ACTIVE', l_pfx || 'INS');
  lt.check_that(l_run, 'P4 In-Session: andere Session sieht ihn nicht', r_ids('A4') is null, r_ids('A4'));
  lilam.close_process(l_a);

  -- P5 gleicher Name auf beiden Workern
  l_a := lilam.server_new_process(l_pfx || 'ZWEI', lt.c_group);
  l_b := open_elsewhere(l_pfx || 'ZWEI', route_of(l_a));
  lt.check_that(l_run, 'P5 Prozesse auf verschiedenen Workern', route_of(l_a) != route_of(l_b), route_of(l_a) || ' / ' || route_of(l_b));
  req('A5', 'ACTIVE', l_pfx || 'ZWEI');
  lt.check_that(l_run, 'P5 beide IDs aufsteigend', r_ids('A5') = least(l_a, l_b) || ',' || greatest(l_a, l_b), r_ids('A5'));
  req('C5', 'CONNECT', l_pfx || 'ZWEI');
  lt.check_that(l_run, 'P5 CONNECT nimmt die niedrigste ID', r_pid('C5') = least(l_a, l_b), r_pid('C5'));

  -- P6 parallele Requests
  for r in 1 .. 3 loop
    declare
      l_go    varchar2(30) := go_at(3);
      l_steps sys.odcivarchar2list := sys.odcivarchar2list();
      l_name  varchar2(50) := l_pfx || 'PAR' || r;
    begin
      for j in 1 .. 6 loop
        l_steps.extend;
        l_steps(j) := 'P' || r || '_' || j;
        run_req(l_steps(j), 'CONNECT', l_name, null, l_go);
      end loop;
      wait_for(l_steps);
      select count(distinct pid), min(pid), count(*), max(ms)
        into l_cnt, l_pid2, l_seq, l_num
        from lt_ps_result where step in (select column_value from table(l_steps));
      lt.check_that(l_run, 'P6 Runde ' || r || ': alle sechs Requests dieselbe ID', l_cnt = 1 and l_seq = 6 and l_pid2 > 0,
                    l_cnt || ' IDs, ' || l_seq || ' Antworten, min ' || l_pid2);
      lt.metric(l_run, 'connect_parallel_max_ms', l_num, 'ms', r);
      l_cnt := lt.count_lilam(l_name, 'PROC');
      lt.check_that(l_run, 'P6 Runde ' || r || ': genau ein Prozess', l_cnt = 1, l_cnt);
      l_num := lt.wait_count(l_name, 'LOG', 6, 10);
      l_cnt := lt.count_lilam(l_name, 'LOG');
      lt.check_that(l_run, 'P6 Runde ' || r || ': alle sechs Logs im Prozess', l_cnt = 6, l_cnt);
    end;
  end loop;

  -- P7 nach CLOSE_PROCESS
  lt.close_wait(l_pid, 'geschlossen vom Test');
  req('A7', 'ACTIVE', l_pfx || 'EINS');
  lt.check_that(l_run, 'P7 geschlossener Prozess nicht mehr aktiv', r_ids('A7') is null, r_ids('A7'));
  req('C7', 'CONNECT', l_pfx || 'EINS');
  lt.check_that(l_run, 'P7 CONNECT legt neu an', nvl(r_pid('C7'), -1) > 0 and r_pid('C7') != l_pid, r_pid('C7'));

  -- P8 Worker haengt
  l_a := lilam.server_new_process(l_pfx || 'HAENGT', lt.c_group);
  l_pipeA := route_of(l_a);
  l_b := open_elsewhere(l_pfx || 'FREI', l_pipeA);
  l_pipeB := route_of(l_b);
  lt.check_that(l_run, 'P8 Vorbereitung: Prozesse auf verschiedenen Workern', l_pipeA != l_pipeB, l_pipeA || ' / ' || l_pipeB);
  req('W0', 'ACTIVE', l_pfx || 'HAENGT');   -- frischer Heartbeat vor dem Sperren
  lt.run_job('LT_CPS_HOLD', 'begin lt_ps_hold(''' || l_pipeA || ''', ' || c_hold_s || '); end;');
  wait_for(sys.odcivarchar2list('HOLD'));
  req('W1', 'ACTIVE', l_pfx || 'HAENGT', 500);   -- weckt den Worker, er bleibt im Housekeeping stehen
  dbms_session.sleep(1);
  run_req('H1', 'ACTIVE', l_pfx || 'HAENGT', 500);
  run_req('H2', 'ACTIVE', l_pfx || 'FREI', 500);
  run_req('H3', 'CONNECT', l_pfx || 'NEU', 500);
  run_req('H4', 'CONNECT', l_pfx || 'HAENGT', 500);
  wait_for(sys.odcivarchar2list('H1', 'H2', 'H3', 'H4'));
  lt.check_that(l_run, 'P8 Prozess des haengenden Workers fehlt in der Liste', r_ids('H1') is null, r_ids('H1'));
  lt.check_that(l_run, 'P8 Wartezeit eingehalten (500 bis 1.000 ms)', r_ms('H1') between 500 and 1000, r_ms('H1') || ' ms');
  lt.metric(l_run, 'active_timeout_ms', r_ms('H1'), 'ms');
  lt.check_that(l_run, 'P8 Prozess des anderen Workers als Teilergebnis', r_ids('H2') = to_char(l_b), r_ids('H2'));
  lt.check_that(l_run, 'P8 CONNECT ohne Treffer: Timeout statt Anlegen', r_pid('H3') = lilam.NUM_ERR_PROCESS_TIMEOUT, r_pid('H3'));
  lt.check_that(l_run, 'P8 CONNECT: Timeout auch fuer den vorhandenen Prozess', r_pid('H4') = lilam.NUM_ERR_PROCESS_TIMEOUT, r_pid('H4'));
  wait_for(sys.odcivarchar2list('HOLDEND'), c_hold_s + 10);
  dbms_session.sleep(1);
  lt.check_that(l_run, 'P8 kein Prozess angelegt', lt.count_lilam(l_pfx || 'NEU', 'PROC') = 0, lt.count_lilam(l_pfx || 'NEU', 'PROC'));
  lt.check_that(l_run, 'P8 keine Dublette', lt.count_lilam(l_pfx || 'HAENGT', 'PROC') = 1, lt.count_lilam(l_pfx || 'HAENGT', 'PROC'));
  req('H5', 'CONNECT', l_pfx || 'HAENGT');
  lt.check_that(l_run, 'P8 nach dem Haenger: CONNECT findet den Prozess wieder', r_pid('H5') = l_a, r_pid('H5'));

  -- P9 Worker gestoppt
  lt.check_that(l_run, 'P9 Worker gestoppt', lt.stop_server(l_pipeB), l_pipeB);
  req('A9', 'ACTIVE', l_pfx || 'FREI');
  lt.check_that(l_run, 'P9 Prozess des gestoppten Workers nicht aktiv', r_ids('A9') is null, r_ids('A9'));
  select count(*) into l_cnt from lilam_proc where id = l_b and process_end is null;
  lt.check_that(l_run, 'P9 Prozess in _PROC weiter offen', l_cnt = 1, l_cnt);
  req('C9', 'CONNECT', l_pfx || 'FREI');
  lt.check_that(l_run, 'P9 CONNECT legt neu an', nvl(r_pid('C9'), -1) > 0 and r_pid('C9') != l_b, r_pid('C9'));
  lt.check_that(l_run, 'P9 neuer Prozess auf dem verbliebenen Worker', route_of(r_pid('C9')) = l_pipeA, route_of(r_pid('C9')));

  -- P10 CALL_BY_JSON
  req('J1', 'JSON_CONNECT', l_pfx || 'JSON');
  l_pid2 := to_number(json_value(r_resp('J1'), '$.payload.value'));
  lt.check_that(l_run, 'P10 JSON SERVER_CONNECT_PROCESS: ID', nvl(l_pid2, -1) > 0, r_resp('J1'));
  req('J2', 'JSON_ACTIVE', l_pfx || 'JSON');
  l_txt := json_query(r_resp('J2'), '$.payload.value');
  lt.check_that(l_run, 'P10 JSON GET_ACTIVE_PROCESSES: Array mit der ID', l_txt = '[' || l_pid2 || ']', r_resp('J2'));
  lt.check_that(l_run, 'P10 JSON GET_ACTIVE_PROCESSES: returns', json_value(r_resp('J2'), '$.payload.returns') = 'PROCESS_IDS', r_resp('J2'));

  -- P11 Fehlerfaelle
  req('E1', 'CONNECT_NOGROUP', l_pfx || 'FEHLER');
  lt.check_that(l_run, 'P11 Gruppe ohne Dispatcher: NUM_ERR_NO_SERVER', r_pid('E1') = lilam.NUM_ERR_NO_SERVER, r_pid('E1'));
  lt.check_that(l_run, 'P11 Gruppe ohne Dispatcher: ohne Wartezeit (< 500 ms)', r_ms('E1') < 500, r_ms('E1') || ' ms');
  req('E2', 'CONNECT', null);
  lt.check_that(l_run, 'P11 kein Name: NUM_ERR_ILLEGAL_REQ', r_pid('E2') = lilam.NUM_ERR_ILLEGAL_REQ, r_pid('E2'));

  -- P12 Abschluss
  select count(*) into l_cnt from lt_ps_result where info != 'OK';
  lt.check_that(l_run, 'P12 alle Requests ohne Exception', l_cnt = 0, l_cnt || ' mit Fehler');
  select count(*) into l_cnt from lilam_alert_state where state_key like 'CONNECT|%';
  lt.check_that(l_run, 'P12 keine Sperre uebrig', l_cnt = 0, l_cnt);

  lt.stop_all_servers;

  select count(*) into l_cnt from lilam_server_registry
   where pipe_name in ('LT_S1', 'LT_S2', 'LT_DISP') and is_active = 1;
  lt.check_that(l_run, 'P12 alle Server inkl. Dispatcher gestoppt', l_cnt = 0, l_cnt || ' noch aktiv');

  -- INCOMPLETE/WAIT und die fehlende Gruppe erzeugt der Test selbst
  execute immediate 'select count(*), max(substr(module_name || '': '' || error_message, 1, 300)) from lilam_log_internal
                      where log_timestamp >= :1
                        and nvl(log_operation, ''-'') not in (''BACKPRESSURE'', ''GAP'', ''INCOMPLETE'', ''WAIT'')
                        and not (module_name = ''SERVER_CONNECT_PROCESS'' and error_message like ''No active dispatcher%'')'
    into l_cnt, l_txt using lt.run_started(l_run);
  lt.check_that(l_run, 'P12 keine unerwarteten internen Fehler', l_cnt = 0, l_cnt || ' ' || l_txt);
  lt.end_run(l_run);
exception
  when others then
    dbms_output.put_line('ABBRUCH: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
    lt.stop_all_servers;
    raise;
end;
/
