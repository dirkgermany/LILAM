-- =====================================================================
-- LILAM Test: FEATURES / RUECKSTAU (DISPATCHER_VOLL)
--
-- Befunde C1 und A3 (befunde fallback):
--   C1: Der Dispatcher wartete bei voller Worker-Pipe je Nachricht bis 1 s und wertete das Ergebnis nicht aus.
--       Ein angehaltener Worker hielt damit den Dispatcher fuer alle Clients an; die Nachricht ging verloren.
--   A3: Ging eine Nachricht verloren und kam die naechste durch, zaehlte der Server ueber die Luecke hinweg;
--       der Client entfernte die verlorene Nachricht aus dem Ringpuffer.
-- Jetzt leitet der Dispatcher nach einem Fehlschlag ohne Warten weiter und verwirft, was nicht passt.
-- Der Server erkennt die Luecke, verwirft die folgenden Nachrichten und meldet sie (LILAM_WATERMARK.GAP_FROM);
-- der Client wiederholt ab der Luecke in Reihenfolge.
--
--   Ablauf (Modus DISPATCHER):
--   1. LT_S1 und der Dispatcher LT_DISP laufen. Client-Job A legt ueber den Dispatcher einen Prozess an (auf LT_S1).
--      Danach startet LT_S2, Client-Job B legt seinen Prozess an (auf LT_S2, weniger Prozesse).
--   2. Ein Job sperrt die Registry-Zeile von LT_S1 fuer c_block_s Sekunden: LT_S1 liest seine Pipe nicht.
--   3. Ab dem Startzeitpunkt sendet A c_big grosse Meldungen (2 KB), mehr als in die Pipe von LT_S1 passt (16 MB),
--      danach alle 20 ms eine kleine. B sendet die ganze Zeit alle 20 ms eine kleine Meldung und misst,
--      wie viele seiner Meldungen noch nicht geschrieben sind (Rueckstand).
--      Beide senden bis zum Ende der Sperre plus c_after_s Sekunden und schliessen dann ihren Prozess.
--
--   Erwartet: B wird nicht ausgebremst (Rueckstand < 250 Meldungen, also < 5 s), der Dispatcher hat die volle
--   Pipe protokolliert, der Server eine Luecke erkannt und der Client ab dort wiederholt. Alle Logs von A und B
--   genau einmal und in Reihenfolge, beide Prozesse geschlossen, keine verlorenen Nachrichten (GAP_LOST),
--   kein RING_FULL, FAILOVER, DISPATCH, PIPE_FULL, SERVER_FAILED, kein Aufruf laenger als 2 s.
--
-- Laufzeit: ca. 1,5 min. Legt die Prozedur DV_CLIENT und die Tabelle DV_CLIENT_RES an (Hilfsobjekte des Tests).
-- Voraussetzungen: LILAM installiert (Branch fallback), _COMMON/01_install_testbasis.sql
-- =====================================================================
set serveroutput on size unlimited

declare
  l_n number;
begin
  select count(*) into l_n from user_tables where table_name = 'DV_CLIENT_RES';
  if l_n = 0 then
    execute immediate 'create table dv_client_res (
                         run_id      number,
                         client_no   number,
                         process_id  number,
                         sent        number,
                         max_ms      number,            -- laengster Aufruf
                         max_backlog number,            -- groesster Rueckstand (gesendet, aber nicht geschrieben)
                         status      varchar2(20),
                         err         varchar2(2000))';
  end if;
end;
/

-- Ein Client ueber den Dispatcher: eigener Prozess, wartet auf p_start, sendet dann p_big grosse und bis p_end
-- alle 20 ms kleine Meldungen. p_backlog: alle 50 Meldungen den Rueckstand messen.
create or replace procedure dv_client(p_run number, p_client number, p_disp varchar2, p_start timestamp, p_end timestamp,
                                      p_big number, p_backlog number)
as
  l_pid     number;
  l_no      pls_integer := 0;
  l_max     number := 0;
  l_backlog number := 0;
  l_written number;
  l_t       number;
  l_fill    varchar2(1900) := rpad('x', 1890, 'x');
  l_err     varchar2(2000);

  procedure send(p_text varchar2) is
  begin
    l_no := l_no + 1;
    l_t := dbms_utility.get_time;
    lilam.info(l_pid, 'DV#' || lpad(l_no, 6, '0') || ' ' || p_text);
    l_max := greatest(l_max, (dbms_utility.get_time - l_t) * 10);
    if p_backlog = 1 and mod(l_no, 50) = 0 then
      select count(*) into l_written from lilam_log where process_id = l_pid;
      l_backlog := greatest(l_backlog, l_no - l_written);
    end if;
  end;

  procedure save(p_status varchar2) is
  begin
    update dv_client_res set sent = l_no, max_ms = l_max, max_backlog = l_backlog, status = p_status, err = l_err
     where run_id = p_run and client_no = p_client;
    commit;
  end;
begin
  lilam.set_dispatcher_pipe(p_disp);
  l_pid := lilam.server_new_process('LT_DV_' || p_client, 'LT', p_logLevel => lilam.logLevelInfo);
  insert into dv_client_res (run_id, client_no, process_id, sent, max_ms, max_backlog, status)
  values (p_run, p_client, l_pid, 0, 0, 0, 'READY');
  commit;

  while systimestamp < p_start loop
    dbms_session.sleep(0.05);
  end loop;

  for i in 1 .. p_big loop
    send(l_fill);
  end loop;
  while systimestamp < p_end loop
    send('klein');
    dbms_session.sleep(0.02);
  end loop;

  l_t := dbms_utility.get_time;
  lilam.close_process(l_pid, 'DV Ende', 1);
  l_max := greatest(l_max, (dbms_utility.get_time - l_t) * 10);
  save('DONE');
exception
  when others then
    l_err := substr(sqlerrm || ' ' || dbms_utility.format_error_backtrace, 1, 2000);
    rollback;
    save('ERROR');
end;
/

declare
  c_disp     constant varchar2(30) := 'LT_DISP';
  c_big      constant pls_integer := 9000;   -- Client A: 9.000 x 2 KB = 18 MB > 16 MB Pipe von LT_S1
  c_block_s  constant pls_integer := 25;     -- Sperre von LT_S1
  c_after_s  constant pls_integer := 15;     -- nach dem Ende der Sperre
  l_run      number;
  l_ts0      timestamp;
  l_start    timestamp;
  l_end      timestamp;
  l_t0       timestamp;
  l_n        number;
  l_d        number;
  l_inv      number;
  l_ok_all   boolean;
  l_max_ms   number := 0;
  l_txt      varchar2(4000);

  function q(p_sql varchar2, p_id number) return number is r number;
  begin
    execute immediate p_sql into r using p_id;
    return r;
  exception when others then return -1;
  end;

  function ts_lit(p_ts timestamp) return varchar2 is
  begin
    return 'to_timestamp(''' || to_char(p_ts, 'YYYY-MM-DD HH24:MI:SS.FF6') || ''', ''YYYY-MM-DD HH24:MI:SS.FF6'')';
  end;

  procedure start_client(p_client number, p_big number, p_backlog number) is
  begin
    dbms_scheduler.create_job(
      job_name   => 'DV_CLIENT_' || p_client,
      job_type   => 'PLSQL_BLOCK',
      job_action => 'begin dv_client(' || l_run || ', ' || p_client || ', ''' || c_disp || ''', ' || ts_lit(l_start) || ', '
                    || ts_lit(l_end) || ', ' || p_big || ', ' || p_backlog || '); end;',
      enabled    => true,
      auto_drop  => true);
  end;

  procedure wait_ready(p_cnt number) is
  begin
    l_t0 := systimestamp;
    loop
      select count(*) into l_n from dv_client_res where run_id = l_run and status in ('READY', 'DONE');
      exit when l_n >= p_cnt or lt.ms_since(l_t0) > 8000;
      dbms_session.sleep(0.2);
    end loop;
    if l_n < p_cnt then
      raise_application_error(-20000, 'Client ' || p_cnt || ' nicht bereit (Job-Fehler siehe user_scheduler_job_run_details, DV_CLIENT_%)');
    end if;
  end;

  function client_pid(p_client number) return number is r number;
  begin
    select process_id into r from dv_client_res where run_id = l_run and client_no = p_client;
    return r;
  end;

  function route(p_pid number) return varchar2 is r varchar2(128);
  begin
    select pipe_name into r from lilam_process_route where process_id = p_pid;
    return r;
  exception when others then return null;
  end;
begin
  l_run := lt.begin_run('DISPATCHER_VOLL', 'DISPATCHER', 'big=' || c_big || ',block=' || c_block_s || 's,after=' || c_after_s || 's');
  l_ts0 := systimestamp;
  lt.stop_all_servers;
  lt.start_server('LT_S1');
  lt.start_server(c_disp, 1);
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', c_disp));

  -- 1. Client A auf LT_S1, danach LT_S2 und Client B
  l_start := systimestamp + numtodsinterval(30, 'SECOND');
  l_end   := l_start + numtodsinterval(c_block_s + c_after_s, 'SECOND');
  start_client(1, c_big, 0);
  wait_ready(1);
  lt.start_server('LT_S2');
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2', c_disp));
  start_client(2, 0, 1);
  wait_ready(2);
  lt.check_that(l_run, 'A auf LT_S1, B auf LT_S2 (ueber den Dispatcher)',
                upper(route(client_pid(1))) = 'LT_S1' and upper(route(client_pid(2))) = 'LT_S2'
                and systimestamp < l_start - numtodsinterval(1, 'SECOND'),
                'A ' || route(client_pid(1)) || ', B ' || route(client_pid(2)));

  -- 2. LT_S1 anhalten: Registry-Zeile sperren (bis Startzeitpunkt + c_block_s)
  dbms_scheduler.create_job(
    job_name   => 'DV_LOCK',
    job_type   => 'PLSQL_BLOCK',
    job_action => 'declare l_x varchar2(100); begin
                     select pipe_name into l_x from lilam_server_registry where upper(pipe_name) = ''LT_S1'' for update;
                     while systimestamp < ' || ts_lit(l_start + numtodsinterval(c_block_s, 'SECOND')) || ' loop
                       dbms_session.sleep(0.2);
                     end loop;
                     rollback;
                   end;',
    enabled    => true,
    auto_drop  => true);

  -- 3. Clients laufen; warten, bis beide fertig sind
  l_t0 := systimestamp;
  loop
    select count(*) into l_n from dv_client_res where run_id = l_run and status in ('DONE', 'ERROR');
    exit when l_n = 2 or lt.ms_since(l_t0) > (30 + c_block_s + c_after_s + 60) * 1000;
    dbms_session.sleep(0.5);
  end loop;
  select count(*), max(err) into l_n, l_txt from dv_client_res where run_id = l_run and status = 'DONE';
  lt.check_that(l_run, 'Beide Clients ohne Fehler beendet', l_n = 2, l_n || ' von 2 ' || substr(l_txt, 1, 800));

  -- 4. Warten, bis alles geschrieben und geschlossen ist (der Client wiederholt ab der Luecke)
  l_t0 := systimestamp;
  loop
    l_ok_all := true;
    for r in (select process_id, sent from dv_client_res where run_id = l_run) loop
      if q('select count(*) from lilam_log where process_id = :1 and info like ''DV#%''', r.process_id) < r.sent
         or q('select count(*) from lilam_proc where id = :1 and process_end is not null', r.process_id) < 1 then
        l_ok_all := false;
      end if;
    end loop;
    exit when l_ok_all or lt.ms_since(l_t0) > 60000;
    dbms_session.sleep(0.5);
  end loop;
  lt.metric(l_run, 'wait_after_clients_ms', round(lt.ms_since(l_t0)), 'ms');

  -- Pruefungen
  for r in (select client_no, process_id, sent, max_ms, max_backlog from dv_client_res where run_id = l_run order by client_no) loop
    l_max_ms := greatest(l_max_ms, r.max_ms);
    l_n := q('select count(*) from lilam_log where process_id = :1 and info like ''DV#%''', r.process_id);
    l_d := q('select count(distinct substr(info, 1, 9)) from lilam_log where process_id = :1 and info like ''DV#%''', r.process_id);
    lt.check_that(l_run, 'Client ' || chr(64 + r.client_no) || ': alle Logs genau einmal', l_n = r.sent and l_d = r.sent,
                  'gesendet ' || r.sent || ', Zeilen ' || l_n || ', verschieden ' || l_d);
    l_inv := q('select count(*) from (select to_number(substr(info, 4, 6)) k,
                                             lag(to_number(substr(info, 4, 6))) over (order by no) pk
                                        from lilam_log where process_id = :1 and info like ''DV#%'')
                 where k < pk', r.process_id);
    lt.check_that(l_run, 'Client ' || chr(64 + r.client_no) || ': Reihenfolge erhalten', l_inv = 0, l_inv || ' Vertauschungen');
    l_n := q('select count(*) from lilam_proc where id = :1 and process_end is not null and info = ''DV Ende'' and status = 1', r.process_id);
    lt.check_that(l_run, 'Client ' || chr(64 + r.client_no) || ': Prozess geschlossen', l_n = 1, 'pid ' || r.process_id);
    lt.metric(l_run, 'max_call_ms', r.max_ms, 'ms', r.client_no);
    lt.metric(l_run, 'max_backlog', r.max_backlog, 'msgs', r.client_no);
    if r.client_no = 2 then
      lt.check_that(l_run, 'B nicht ausgebremst (Rueckstand < 250 Meldungen)', r.max_backlog < 250, 'max ' || r.max_backlog);
    end if;
  end loop;
  lt.check_that(l_run, 'Kein Aufruf laenger als 2 s', l_max_ms <= 2000, 'max ' || l_max_ms || ' ms');

  select count(*) into l_n from lilam_log_internal
   where log_timestamp >= l_ts0 and module_name = 'forwardToWorker' and log_operation = 'BACKPRESSURE' and error_message like '%is full%';
  lt.check_that(l_run, 'Dispatcher hat die volle Pipe protokolliert', l_n >= 1, l_n || ' Eintraege');
  select count(*) into l_n from lilam_log_internal
   where log_timestamp >= l_ts0 and module_name = 'checkSeqGap' and log_operation = 'GAP';
  lt.check_that(l_run, 'Server hat eine Luecke erkannt', l_n >= 1, l_n || ' Eintraege');
  select count(*) into l_n from lilam_log_internal
   where log_timestamp >= l_ts0 and module_name = 'resendFromGap' and log_operation = 'GAP';
  lt.check_that(l_run, 'Client hat ab der Luecke wiederholt', l_n >= 1, l_n || ' Eintraege');

  select count(*), max(module_name || ': ' || substr(error_message, 1, 300)) into l_n, l_txt from lilam_log_internal
   where log_timestamp >= l_ts0 and log_operation in ('GAP_LOST', 'RING_FULL', 'FAILOVER', 'DISPATCH', 'PIPE_FULL', 'SERVER_FAILED');
  lt.check_that(l_run, 'Kein GAP_LOST, RING_FULL, FAILOVER, DISPATCH, PIPE_FULL, SERVER_FAILED', l_n = 0, l_n || ' ' || l_txt);
  select count(*), max(module_name || ': ' || substr(error_message, 1, 300)) into l_n, l_txt from lilam_log_internal
   where log_timestamp >= l_ts0 and nvl(log_operation, '-') not in ('BACKPRESSURE', 'GAP');
  lt.check_that(l_run, 'Keine anderen internen Fehler', l_n = 0, l_n || ' ' || l_txt);

  l_n := 0;
  for r in (select process_id from dv_client_res where run_id = l_run) loop
    l_n := l_n + q('select count(*) from lilam_process_route where process_id = :1', r.process_id)
               + q('select count(*) from lilam_watermark where process_id = :1', r.process_id);
  end loop;
  lt.check_that(l_run, 'Keine Routen und Wasserstaende uebrig', l_n = 0, l_n || ' Zeilen');

  lt.metric(l_run, 'internal_entries', lt.internal_errors_since(l_ts0), 'rows');
  lt.stop_all_servers;
  lt.end_run(l_run);
exception
  when others then
    dbms_output.put_line('ABBRUCH: ' || sqlerrm);
    lt.check_that(l_run, 'Testablauf ohne Abbruch', false, substr(sqlerrm || ' ' || dbms_utility.format_error_backtrace, 1, 900));
    lt.end_run(l_run);
    lt.stop_all_servers;
end;
/

-- Ergebnis
select check_name, ok, detail from lt_check where run_id = (select max(run_id) from lt_run where test_name = 'DISPATCHER_VOLL') order by check_no;
select client_no, process_id, sent, max_ms, max_backlog, status from dv_client_res
 where run_id = (select max(run_id) from lt_run where test_name = 'DISPATCHER_VOLL') order by client_no;
select to_char(log_timestamp, 'HH24:MI:SS.FF2') t, log_operation, module_name, substr(error_message, 1, 250) msg
  from lilam_log_internal
 where log_timestamp >= (select started from lt_run where run_id = (select max(run_id) from lt_run where test_name = 'DISPATCHER_VOLL'))
 order by log_timestamp;
