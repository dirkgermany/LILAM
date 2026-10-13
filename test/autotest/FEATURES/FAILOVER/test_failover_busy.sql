-- =====================================================================
-- LILAM Test: FEATURES / FAILOVER (FAILOVER_BUSY)
--
-- Befund F1 (befunde fallback): Ein Server, der nur beschaeftigt ist, schreibt laenger keinen Heartbeat.
-- Frueher galt er nach 5 s als ausgefallen; ein zweiter Worker uebernahm seine Prozesse, und beide
-- schrieben dieselben Daten (SPEICHER run 2192: Logs doppelt). Jetzt gilt ein Server erst als ausgefallen,
-- wenn sein Heartbeat alt ist UND sein Scheduler-Job nicht mehr laeuft (isServerAlive).
--
--   Ablauf (Modus SERVER, ohne Dispatcher):
--   1. Nur LT_S1 laeuft; P1 (offen bleibend) und P2 (wird geschlossen) entstehen dort. Danach startet LT_S2.
--   2. Ein Job sperrt die Registry-Zeile von LT_S1 fuer c_block_s Sekunden. LT_S1 bleibt in seiner
--      Hauswirtschaft haengen (updateServerRegistry), sein Heartbeat altert, sein Job laeuft weiter.
--   3. Waehrend der Sperre: Logs und Events in P1 und P2, CLOSE_PROCESS(P2), weitere Logs in P1
--      bis zum Ende der Sperre (spaetere Aufrufe loesen die Stockungspruefung bzw. checkClosing aus).
--   4. Nach der Sperre: CLOSE_PROCESS(P1), warten, bis beide Prozesse geschlossen sind.
--
--   Erwartet: kein Failover (kein Eintrag FAILOVER, beide Prozesse bleiben auf LT_S1), alle Logs genau
--   einmal, Events lueckenlos, beide Prozesse geschlossen, keine Routen und Wasserstaende uebrig,
--   der Heartbeat von LT_S1 war waehrend der Sperre tatsaechlich aelter als 15 s (sonst prueft der Test nichts).
--
-- Voraussetzungen: LILAM installiert (Branch fallback), _COMMON/01_install_testbasis.sql
-- =====================================================================
set serveroutput on size unlimited

declare
  c_name     constant varchar2(30) := 'LT_FO_BUSY';
  c_block_s  constant pls_integer := 22;    -- Sperre: laenger als C_CLOSING_HEARTBEAT_AGE_SEC (15 s)
  l_run      number;
  l_p1       number;
  l_p2       number;
  l_t0       timestamp;
  l_ts0      timestamp;
  l_n        number;
  l_d        number;
  l_mx       number;
  l_age_max  number := 0;
  l_age      number;
  l_no1      pls_integer := 0;
  l_no2      pls_integer := 0;
  l_ev       pls_integer := 0;
  l_txt      varchar2(4000);

  function q(p_sql varchar2, p_id number) return number is r number;
  begin
    execute immediate p_sql into r using p_id;
    return r;
  exception when others then return -1;
  end;

  -- Heartbeat-Alter von LT_S1 in Sekunden (Registry, konsistentes Lesen trotz Sperre)
  function hb_age return number is r number;
  begin
    select extract(day from (systimestamp - last_activity)) * 86400 + extract(hour from (systimestamp - last_activity)) * 3600
         + extract(minute from (systimestamp - last_activity)) * 60 + extract(second from (systimestamp - last_activity))
      into r from lilam_server_registry where upper(pipe_name) = 'LT_S1';
    return r;
  exception when others then return null;
  end;
begin
  l_run := lt.begin_run('FAILOVER_BUSY', 'SERVER', 'block=' || c_block_s || 's');
  l_ts0 := systimestamp;
  lt.stop_all_servers;

  -- 1. P1 und P2 auf LT_S1, danach LT_S2
  lt.start_server('LT_S1');
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1'));
  l_p1 := lilam.server_new_process(c_name || '_1', lt.c_group, p_logLevel => lilam.logLevelInfo);
  l_p2 := lilam.server_new_process(c_name || '_2', lt.c_group, p_logLevel => lilam.logLevelInfo);
  lt.check_that(l_run, 'P1 und P2 auf LT_S1 angelegt',
                upper(lilam.get_server_pipe(l_p1)) = 'LT_S1' and upper(lilam.get_server_pipe(l_p2)) = 'LT_S1',
                'P1 ' || l_p1 || ', P2 ' || l_p2);
  lt.start_server('LT_S2');
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2'));

  -- 2. LT_S1 blockieren: ein Job sperrt dessen Registry-Zeile (Name ohne Praefix LT_, damit
  --    lt.stop_all_servers ihn nicht vorzeitig beendet)
  dbms_scheduler.create_job(
    job_name   => 'FO_BUSY_LOCK',
    job_type   => 'PLSQL_BLOCK',
    job_action => 'declare l_x varchar2(100); begin
                     select pipe_name into l_x from lilam_server_registry where upper(pipe_name) = ''LT_S1'' for update;
                     dbms_session.sleep(' || c_block_s || ');
                     rollback;
                   end;',
    enabled    => true,
    auto_drop  => true);
  dbms_session.sleep(1);

  -- 3. Waehrend der Sperre
  l_t0 := systimestamp;
  for i in 1 .. 20 loop
    l_no1 := l_no1 + 1; lilam.info(l_p1, 'FB1#' || lpad(l_no1, 5, '0'));
    l_no2 := l_no2 + 1; lilam.info(l_p2, 'FB2#' || lpad(l_no2, 5, '0'));
    if mod(i, 5) = 0 then l_ev := l_ev + 1; lilam.mark_event(l_p1, 'FB_EV'); end if;
  end loop;
  lilam.close_process(l_p2, 'FB2 Ende', 1);
  while lt.ms_since(l_t0) < (c_block_s + 2) * 1000 loop
    l_no1 := l_no1 + 1; lilam.info(l_p1, 'FB1#' || lpad(l_no1, 5, '0'));
    if mod(l_no1, 5) = 0 then l_ev := l_ev + 1; lilam.mark_event(l_p1, 'FB_EV'); end if;
    l_age := hb_age;
    if l_age > l_age_max then l_age_max := l_age; end if;
    dbms_session.sleep(0.5);
  end loop;
  lt.metric(l_run, 'heartbeat_age_max_s', round(l_age_max, 1), 's');
  lt.check_that(l_run, 'Heartbeat von LT_S1 waehrend der Sperre aelter als 15 s', l_age_max > 15, round(l_age_max, 1) || ' s');

  -- 4. Nach der Sperre
  lilam.close_process(l_p1, 'FB1 Ende', 1);
  l_t0 := systimestamp;
  loop
    exit when (q('select count(*) from lilam_proc where id = :1 and process_end is not null', l_p1) = 1
               and q('select count(*) from lilam_proc where id = :1 and process_end is not null', l_p2) = 1
               and q('select count(*) from lilam_log where process_id = :1 and info like ''FB1#%''', l_p1) >= l_no1)
              or lt.ms_since(l_t0) > 30000;
    dbms_session.sleep(0.25);
  end loop;

  -- Pruefungen
  select count(*), max(error_message) into l_n, l_txt from lilam_log_internal
   where log_timestamp >= l_ts0 and log_operation = 'FAILOVER';
  lt.check_that(l_run, 'Kein Failover', l_n = 0, l_n || ' Eintraege ' || substr(l_txt, 1, 800));

  l_n := q('select count(*) from lilam_log where process_id = :1 and info like ''FB1#%''', l_p1);
  l_d := q('select count(distinct info) from lilam_log where process_id = :1 and info like ''FB1#%''', l_p1);
  lt.check_that(l_run, 'P1 alle Logs genau einmal', l_d = l_no1 and l_n = l_d, 'erwartet ' || l_no1 || ', Zeilen ' || l_n || ', verschieden ' || l_d);
  l_n := q('select count(*) from lilam_log where process_id = :1 and info like ''FB2#%''', l_p2);
  l_d := q('select count(distinct info) from lilam_log where process_id = :1 and info like ''FB2#%''', l_p2);
  lt.check_that(l_run, 'P2 alle Logs genau einmal', l_d = l_no2 and l_n = l_d, 'erwartet ' || l_no2 || ', Zeilen ' || l_n || ', verschieden ' || l_d);

  l_n  := q('select count(*) from lilam_mon where process_id = :1 and action = ''FB_EV'' and mon_type = 0', l_p1);
  l_mx := q('select max(action_count) from lilam_mon where process_id = :1 and action = ''FB_EV'' and mon_type = 0', l_p1);
  lt.check_that(l_run, 'P1 Events vollstaendig, lueckenlos, ohne Dubletten', l_n = l_ev and l_mx = l_ev,
                'erwartet ' || l_ev || ', Zeilen ' || l_n || ', max ' || l_mx);

  l_n := q('select count(*) from lilam_proc where id = :1 and process_end is not null and info = ''FB1 Ende'' and status = 1', l_p1);
  lt.check_that(l_run, 'P1 geschlossen mit Info und Status', l_n = 1);
  l_n := q('select count(*) from lilam_proc where id = :1 and process_end is not null and info = ''FB2 Ende'' and status = 1', l_p2);
  lt.check_that(l_run, 'P2 geschlossen mit Info und Status', l_n = 1);

  l_n := q('select count(*) from lilam_process_route where process_id = :1', l_p1) + q('select count(*) from lilam_process_route where process_id = :1', l_p2)
       + q('select count(*) from lilam_watermark where process_id = :1', l_p1) + q('select count(*) from lilam_watermark where process_id = :1', l_p2);
  lt.check_that(l_run, 'Keine Routen und Wasserstaende uebrig', l_n = 0, l_n || ' Zeilen');

  lt.metric(l_run, 'logs_p1', l_no1, 'rows');
  lt.metric(l_run, 'internal_errors', lt.internal_errors_since(l_ts0), 'rows');
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
select check_name, ok, detail from lt_check where run_id = (select max(run_id) from lt_run where test_name = 'FAILOVER_BUSY') order by check_no;
select error_code, log_operation, module_name, substr(error_message, 1, 300) msg
  from lilam_log_internal
 where log_timestamp >= (select started from lt_run where run_id = (select max(run_id) from lt_run where test_name = 'FAILOVER_BUSY'))
 order by log_timestamp;
