-- =====================================================================
-- LILAM Test: FEATURES / RUECKSTAU (PIPE_VOLL)
--
-- Befund A2 (befunde fallback): Bei voller Server-Pipe wartete frueher jeder Aufruf rund 4 s
-- (3 Versuche mit je 1 s plus 0,3 s Pause), und eine gescheiterte Meldung ging verloren (A3).
-- Jetzt: ein Versuch; scheitert er, haelt der Client diese und alle folgenden Meldungen des Prozesses
-- 1 s im Ringpuffer zurueck und sendet sie danach in ihrer Reihenfolge ohne Warten nach.
--
--   Ablauf (Modus SERVER, ein Server, ohne Dispatcher):
--   1. LT_S1 laeuft. c_clients Client-Jobs (PV_CLIENT_n, je eine eigene DB-Session) legen je einen
--      Prozess an und warten auf einen gemeinsamen Startzeitpunkt.
--   2. Ein Job sperrt die Registry-Zeile von LT_S1 fuer c_block_s Sekunden. LT_S1 bleibt in seiner
--      Hauswirtschaft haengen und liest seine Pipe nicht mehr; sein Scheduler-Job laeuft weiter
--      (kein Failover, siehe FAILOVER_BUSY).
--   3. Ab dem Startzeitpunkt senden alle Clients gleichzeitig je c_big grosse Meldungen (ca. 2 KB) in dieselbe
--      Pipe (16 MB), danach bis zum Ende der Sperre plus c_after_s Sekunden alle 100 ms eine kleine Meldung,
--      dann CLOSE_PROCESS. Jeder Client misst die laengste Aufrufdauer.
--   4. Der Test wartet, bis alle Logs geschrieben und alle Prozesse geschlossen sind.
--
--   Erwartet: Die Pipe war voll (Eintrag holdBack), alle Logs genau einmal und in der gesendeten Reihenfolge,
--   Prozesse geschlossen, kein RING_FULL, kein FAILOVER, keine anderen internen Fehler als BACKPRESSURE,
--   kein Aufruf laenger als 2 s (frueher rund 4 s je Aufruf bei voller Pipe).
--
-- Laufzeit: ca. 1 min. Legt die Prozedur PV_CLIENT und die Tabelle PV_CLIENT_RES an (Hilfsobjekte des Tests).
-- Voraussetzungen: LILAM installiert (Branch fallback), _COMMON/01_install_testbasis.sql
-- =====================================================================
set serveroutput on size unlimited
declare
  l_n number;
begin
  -- Tabelle (neu) anlegen; eine aeltere Fassung ohne die Spalten der Aufrufdauern wird ersetzt
  select count(*) into l_n from user_tab_columns where table_name = 'PV_CLIENT_RES' and column_name = 'SLOW_CALLS';
  if l_n = 0 then
    begin execute immediate 'drop table pv_client_res'; exception when others then null; end;
    execute immediate 'create table pv_client_res (
                         run_id     number,
                         client_no  number,
                         process_id number,
                         sent       number,
                         max_ms     number,            -- laengster Aufruf insgesamt
                         max_big    number,            -- laengster Aufruf mit grosser Meldung
                         max_small  number,            -- laengster Aufruf mit kleiner Meldung
                         close_ms   number,            -- Dauer von CLOSE_PROCESS
                         n_slow     number,            -- Aufrufe ueber 1 s
                         slow_calls varchar2(2000),    -- die ersten langsamen Aufrufe: Nummer:ms@Uhrzeit
                         status     varchar2(20),
                         err        varchar2(2000))';
  end if;
end;
/

-- Ein Client: eigener Prozess, wartet auf p_start, sendet dann p_big grosse und bis p_end kleine Meldungen
create or replace procedure pv_client(p_run number, p_client number, p_start timestamp, p_end timestamp, p_big number)
as
  l_pid    number;
  l_no     pls_integer := 0;
  l_max_b  number := 0;
  l_max_s  number := 0;
  l_close  number := 0;
  l_slow   pls_integer := 0;
  l_slows  varchar2(2000);
  l_t      number;
  l_ms     number;
  l_fill   varchar2(1900) := rpad('x', 1890, 'x');
  l_err    varchar2(2000);

  procedure send(p_text varchar2, p_big boolean) is
  begin
    l_no := l_no + 1;
    l_t := dbms_utility.get_time;
    lilam.info(l_pid, 'PV#' || lpad(l_no, 6, '0') || ' ' || p_text);
    l_ms := (dbms_utility.get_time - l_t) * 10;
    if p_big then l_max_b := greatest(l_max_b, l_ms); else l_max_s := greatest(l_max_s, l_ms); end if;
    if l_ms > 1000 then
      l_slow := l_slow + 1;
      if l_slow <= 10 then
        l_slows := l_slows || l_no || ':' || l_ms || '@' || to_char(systimestamp, 'HH24:MI:SS.FF2') || ' ';
      end if;
    end if;
  end;

  procedure save(p_status varchar2) is
  begin
    update pv_client_res set sent = l_no, max_ms = greatest(l_max_b, l_max_s, l_close), max_big = l_max_b,
           max_small = l_max_s, close_ms = l_close, n_slow = l_slow, slow_calls = l_slows, status = p_status, err = l_err
     where run_id = p_run and client_no = p_client;
    commit;
  end;
begin
  l_pid := lilam.server_new_process('LT_PV_' || p_client, 'LT', p_logLevel => lilam.logLevelInfo);
  insert into pv_client_res (run_id, client_no, process_id, sent, max_ms, status)
  values (p_run, p_client, l_pid, 0, 0, 'READY');
  commit;

  while systimestamp < p_start loop
    dbms_session.sleep(0.05);
  end loop;

  for i in 1 .. p_big loop
    send(l_fill, true);
  end loop;
  while systimestamp < p_end loop
    send('klein', false);
    dbms_session.sleep(0.1);
  end loop;

  l_t := dbms_utility.get_time;
  lilam.close_process(l_pid, 'PV Ende', 1);
  l_close := (dbms_utility.get_time - l_t) * 10;
  save('DONE');
exception
  when others then
    l_err := substr(sqlerrm || ' ' || dbms_utility.format_error_backtrace, 1, 2000);
    rollback;
    save('ERROR');
end;
/

declare
  c_clients  constant pls_integer := 3;
  c_big      constant pls_integer := 4000;   -- je Client; 3 x 4.000 x 2 KB = 24 MB > 16 MB Pipe
  c_block_s  constant pls_integer := 25;     -- Sperre von LT_S1
  c_after_s  constant pls_integer := 10;     -- kleine Meldungen nach dem Ende der Sperre
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
  l_sent_all number := 0;
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
begin
  l_run := lt.begin_run('PIPE_VOLL', 'SERVER', 'clients=' || c_clients || ',big=' || c_big || ',block=' || c_block_s || 's');
  l_ts0 := systimestamp;
  lt.stop_all_servers;
  lt.start_server('LT_S1');
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1'));

  -- 1. Client-Jobs (Namen ohne Praefix LT_, damit lt.stop_all_servers sie nicht beendet)
  l_start := systimestamp + numtodsinterval(10, 'SECOND');
  l_end   := l_start + numtodsinterval(c_block_s + c_after_s, 'SECOND');
  for c in 1 .. c_clients loop
    dbms_scheduler.create_job(
      job_name   => 'PV_CLIENT_' || c,
      job_type   => 'PLSQL_BLOCK',
      job_action => 'begin pv_client(' || l_run || ', ' || c || ', ' || ts_lit(l_start) || ', ' || ts_lit(l_end)
                    || ', ' || c_big || '); end;',
      enabled    => true,
      auto_drop  => true);
  end loop;
  l_t0 := systimestamp;
  loop
    select count(*) into l_n from pv_client_res where run_id = l_run and status in ('READY', 'DONE');
    exit when l_n = c_clients or lt.ms_since(l_t0) > 8000;
    dbms_session.sleep(0.2);
  end loop;
  lt.check_that(l_run, 'Alle Clients bereit vor dem Start', l_n = c_clients and systimestamp < l_start - numtodsinterval(1, 'SECOND'),
                l_n || ' von ' || c_clients);
  if l_n < c_clients then
    raise_application_error(-20000, 'Clients nicht bereit (Job-Fehler siehe user_scheduler_job_run_details, PV_CLIENT_%)');
  end if;

  -- 2. LT_S1 anhalten: Registry-Zeile sperren (bis Startzeitpunkt + c_block_s)
  dbms_scheduler.create_job(
    job_name   => 'PV_LOCK',
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

  -- 3. Clients laufen; warten, bis alle fertig sind
  l_t0 := systimestamp;
  loop
    select count(*) into l_n from pv_client_res where run_id = l_run and status in ('DONE', 'ERROR');
    exit when l_n = c_clients or lt.ms_since(l_t0) > (c_block_s + c_after_s + 60) * 1000;
    dbms_session.sleep(0.5);
  end loop;
  select count(*), max(err) into l_n, l_txt from pv_client_res where run_id = l_run and status = 'DONE';
  lt.check_that(l_run, 'Alle Clients ohne Fehler beendet', l_n = c_clients, l_n || ' von ' || c_clients || ' ' || substr(l_txt, 1, 800));

  -- 4. Warten, bis alles geschrieben und geschlossen ist
  l_t0 := systimestamp;
  loop
    l_ok_all := true;
    for r in (select process_id, sent from pv_client_res where run_id = l_run) loop
      if q('select count(*) from lilam_log where process_id = :1 and info like ''PV#%''', r.process_id) < r.sent
         or q('select count(*) from lilam_proc where id = :1 and process_end is not null', r.process_id) < 1 then
        l_ok_all := false;
      end if;
    end loop;
    exit when l_ok_all or lt.ms_since(l_t0) > 60000;
    dbms_session.sleep(0.5);
  end loop;
  lt.metric(l_run, 'wait_after_clients_ms', round(lt.ms_since(l_t0)), 'ms');

  -- Pruefungen
  select count(*) into l_n from lilam_log_internal
   where log_timestamp >= l_ts0 and module_name = 'holdBack' and log_operation = 'BACKPRESSURE';
  lt.check_that(l_run, 'Pipe war voll (holdBack protokolliert)', l_n >= 1, l_n || ' Prozesse');

  for r in (select client_no, process_id, sent, max_ms from pv_client_res where run_id = l_run order by client_no) loop
    l_sent_all := l_sent_all + r.sent;
    l_max_ms   := greatest(l_max_ms, r.max_ms);
    l_n := q('select count(*) from lilam_log where process_id = :1 and info like ''PV#%''', r.process_id);
    l_d := q('select count(distinct substr(info, 1, 9)) from lilam_log where process_id = :1 and info like ''PV#%''', r.process_id);
    lt.check_that(l_run, 'Client ' || r.client_no || ': alle Logs genau einmal', l_n = r.sent and l_d = r.sent,
                  'gesendet ' || r.sent || ', Zeilen ' || l_n || ', verschieden ' || l_d);
    -- Reihenfolge: die laufende Nummer im Text steigt mit der Lognummer NO des Servers
    l_inv := q('select count(*) from (select to_number(substr(info, 4, 6)) k,
                                             lag(to_number(substr(info, 4, 6))) over (order by no) pk
                                        from lilam_log where process_id = :1 and info like ''PV#%'')
                 where k < pk', r.process_id);
    lt.check_that(l_run, 'Client ' || r.client_no || ': Reihenfolge erhalten', l_inv = 0, l_inv || ' Vertauschungen');
    l_n := q('select count(*) from lilam_proc where id = :1 and process_end is not null and info = ''PV Ende'' and status = 1', r.process_id);
    lt.check_that(l_run, 'Client ' || r.client_no || ': Prozess geschlossen', l_n = 1, 'pid ' || r.process_id);
    lt.metric(l_run, 'max_call_ms', r.max_ms, 'ms', r.client_no);
  end loop;
  lt.check_that(l_run, 'Kein Aufruf laenger als 2 s', l_max_ms <= 2000, 'max ' || l_max_ms || ' ms');

  select count(*), max(substr(error_message, 1, 300)) into l_n, l_txt from lilam_log_internal
   where log_timestamp >= l_ts0 and log_operation in ('RING_FULL', 'FAILOVER', 'PIPE_FULL', 'SERVER_FAILED');
  lt.check_that(l_run, 'Kein RING_FULL, FAILOVER, PIPE_FULL, SERVER_FAILED', l_n = 0, l_n || ' ' || l_txt);
  select count(*), max(module_name || ': ' || substr(error_message, 1, 300)) into l_n, l_txt from lilam_log_internal
   where log_timestamp >= l_ts0 and nvl(log_operation, '-') != 'BACKPRESSURE';
  lt.check_that(l_run, 'Keine anderen internen Fehler', l_n = 0, l_n || ' ' || l_txt);

  l_n := 0;
  for r in (select process_id from pv_client_res where run_id = l_run) loop
    l_n := l_n + q('select count(*) from lilam_process_route where process_id = :1', r.process_id)
               + q('select count(*) from lilam_watermark where process_id = :1', r.process_id);
  end loop;
  lt.check_that(l_run, 'Keine Routen und Wasserstaende uebrig', l_n = 0, l_n || ' Zeilen');

  lt.metric(l_run, 'logs_total', l_sent_all, 'rows');
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
select check_name, ok, detail from lt_check where run_id = (select max(run_id) from lt_run where test_name = 'PIPE_VOLL') order by check_no;
select client_no, process_id, sent, max_big, max_small, close_ms, n_slow, slow_calls, status from pv_client_res where run_id = (select max(run_id) from lt_run where test_name = 'PIPE_VOLL') order by client_no;
select to_char(log_timestamp, 'HH24:MI:SS.FF2') t, log_operation, module_name, substr(error_message, 1, 250) msg
  from lilam_log_internal
 where log_timestamp >= (select started from lt_run where run_id = (select max(run_id) from lt_run where test_name = 'PIPE_VOLL'))
 order by log_timestamp;
