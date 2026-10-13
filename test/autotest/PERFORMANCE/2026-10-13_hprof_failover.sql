-- =====================================================================
-- LILAM Diagnose: PERFORMANCE / Profil des Failover-Codes (Befund F3, befunde fallback)
--
-- fallback ist unter Last 16-21 % langsamer als main (LASTTEST, LASTSPITZE). Die zusaetzlichen SQL-Anweisungen
-- fallen nur je Prozess an; der Nachteil muss aus der PL/SQL-Arbeit je Meldung kommen. Dieses Skript misst
-- sie mit dem hierarchischen Profiler (DBMS_HPROF), getrennt fuer Client und Server.
--
-- Ablauf (ein Worker, Modus SERVER):
--   1. Worker LT_S1 als eigener Scheduler-Job (Jobname = Pipe, wie CREATE_SERVER) mit Profiling um START_SERVER.
--   2. Client: Profiling in dieser Session; 1 Prozess, c_ops x (info, trace_start, trace_stop, mark_event,
--      proc_step_done), CLOSE_PROCESS; warten, bis alles geschrieben ist.
--   3. Server herunterfahren; der Job beendet sein Profiling und analysiert es (DBMS_HPROF.ANALYZE).
-- Die Auswertungen stehen in DBMSHP_RUNS / DBMSHP_FUNCTION_INFO (run_comment 'F3 <STAND> CLIENT|SERVER').
-- Der Stand wird aus dem Package bestimmt: FALLBACK (Body enthaelt checkClosing) oder MAIN.
--
-- Auswertung: Abfragen am Ende (Eigenzeit je Unterprogramm, Vergleich der Staende).
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql, EXECUTE auf DBMS_HPROF,
--                  Tabellen DBMSHP_* im Schema (dbmshptab.sql)
-- =====================================================================
set serveroutput on size unlimited

declare
  c_ops     constant pls_integer := 5000;
  c_pw      constant varchar2(20) := 'LtTestPw';   -- wie lt.c_pw
  l_tag     varchar2(30);
  l_cnt     number;
  l_trace   number;
  l_runid   number;
  l_pid     number;
  l_t0      timestamp;
  l_ms      number;
  l_ok      boolean;
  l_action  varchar2(2000);
begin
  select count(*) into l_cnt from user_source
   where name = 'LILAM' and type = 'PACKAGE BODY' and upper(text) like '%PROCEDURE CHECKCLOSING%';
  l_tag := case when l_cnt > 0 then 'FALLBACK' else 'MAIN' end;

  lt.stop_all_servers;

  -- 1. Worker mit Profiling (Jobname = Pipe, damit isServerAlive den Job findet)
  l_action := replace(replace(q'[
      declare
        l_trace number;
        l_run   number;
      begin
        l_trace := dbms_hprof.start_profiling(run_comment => 'F3 #TAG# SERVER');
        lilam.start_server(p_pipeName => 'LT_S1', p_groupName => 'LT', p_password => '#PW#',
                           p_isDispatcher => 0, p_perfServer => lilam.C_SERVER_PERF_MID);
        dbms_hprof.stop_profiling;
        l_run := dbms_hprof.analyze(trace_id => l_trace, run_comment => 'F3 #TAG# SERVER');
      end;]', '#TAG#', l_tag), '#PW#', c_pw);
  dbms_scheduler.create_job(job_name => 'LT_S1', job_type => 'PLSQL_BLOCK', job_action => l_action,
                            enabled => true, auto_drop => true);
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1'));

  -- 2. Client mit Profiling
  l_trace := dbms_hprof.start_profiling(run_comment => 'F3 ' || l_tag || ' CLIENT');
  l_t0 := systimestamp;
  l_pid := lilam.server_new_process('LT_F3_' || l_tag, lt.c_group, lilam.logLevelInfo);
  for o in 1 .. c_ops loop
    lilam.info(l_pid, 'c0 op ' || o);
    lilam.trace_start(l_pid, 'LT_ACTION');
    lilam.trace_stop(l_pid, 'LT_ACTION');
    lilam.mark_event(l_pid, 'LT_EVENT');
    lilam.proc_step_done(l_pid);
  end loop;
  lilam.close_process(l_pid);
  l_ms := lt.ms_since(l_t0);
  dbms_hprof.stop_profiling;
  l_runid := dbms_hprof.analyze(trace_id => l_trace, run_comment => 'F3 ' || l_tag || ' CLIENT');
  dbms_output.put_line(l_tag || ' Client: ' || c_ops * 5 || ' Aufrufe in ' || round(l_ms) || ' ms (mit Profiler), HPROF-Run ' || l_runid);

  -- warten, bis alles geschrieben ist
  l_cnt := lt.wait_count('LT_F3_' || l_tag, 'LOG', c_ops, 120);
  dbms_session.sleep(2);

  -- 3. Server herunterfahren; der Job analysiert danach sein Profil (kann dauern)
  l_ok := lt.stop_server('LT_S1');
  for i in 1 .. 240 loop
    select count(*) into l_cnt from dbmshp_runs where run_comment = 'F3 ' || l_tag || ' SERVER'
       and run_timestamp > l_t0;
    exit when l_cnt > 0;
    dbms_session.sleep(0.5);
  end loop;
  dbms_output.put_line(l_tag || ' Server-Profil ' || case when l_cnt > 0 then 'analysiert' else 'FEHLT' end);
exception
  when others then
    dbms_output.put_line('ABBRUCH: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
    begin dbms_hprof.stop_profiling; exception when others then null; end;
    lt.stop_all_servers;
end;
/

-- Auswertung 1: die Laeufe
select runid, run_comment, to_char(run_timestamp, 'HH24:MI:SS') zeit, round(total_elapsed_time / 1000) ms
  from dbmshp_runs where run_comment like 'F3 %' order by runid;

-- Auswertung 2: Eigenzeit je Unterprogramm (ms), MAIN gegen FALLBACK, je Seite
with f as (
  select r.run_comment, f.module, f.function, f.calls, f.function_elapsed_time, f.subtree_elapsed_time
    from dbmshp_runs r join dbmshp_function_info f on f.runid = r.runid
   where r.run_comment like 'F3 %'
     and r.runid in (select max(runid) from dbmshp_runs where run_comment like 'F3 %' group by run_comment))
select seite, modul, funktion,
       max(case when stand = 'MAIN' then calls end) calls_main,
       round(max(case when stand = 'MAIN' then eigen end) / 1000) ms_main,
       max(case when stand = 'FALLBACK' then calls end) calls_fallback,
       round(max(case when stand = 'FALLBACK' then eigen end) / 1000) ms_fallback,
       round((nvl(max(case when stand = 'FALLBACK' then eigen end), 0) - nvl(max(case when stand = 'MAIN' then eigen end), 0)) / 1000) diff_ms
  from (select regexp_substr(run_comment, '(MAIN|FALLBACK)') stand, regexp_substr(run_comment, '(CLIENT|SERVER)') seite,
               module modul, function funktion, calls, function_elapsed_time eigen
          from f)
 group by seite, modul, funktion
having greatest(nvl(max(case when stand = 'MAIN' then eigen end), 0), nvl(max(case when stand = 'FALLBACK' then eigen end), 0)) > 20000
 order by seite, abs(nvl(max(case when stand = 'FALLBACK' then eigen end), 0) - nvl(max(case when stand = 'MAIN' then eigen end), 0)) desc;
