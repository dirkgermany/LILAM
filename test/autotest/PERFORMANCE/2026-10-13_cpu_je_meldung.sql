-- =====================================================================
-- LILAM Diagnose: PERFORMANCE / CPU-Zeit je Meldung in Client und Server (Befund F3, befunde fallback)
--
-- Der Durchsatz (LASTTEST, LASTSPITZE) streut auf dieser Umgebung so stark, dass Unterschiede von 10-20 %
-- in Wanduhrzeit kaum messbar sind. Dieses Skript misst stattdessen die CPU-Zeit der Sessions
-- (v$sesstat / v$mystat, 'CPU used by this session', Hundertstelsekunden), ohne Profiler:
--   Server: die Session von LT_S1 (module 'LILAM_SERVER LT_S1'), vom Start der Last bis alles geschrieben ist
--   Client: diese Session, fuer die Aufrufe selbst
-- Last wie LASTTEST SERVER: 1 Prozess, c_ops x (info, trace_start, trace_stop, mark_event, proc_step_done).
-- Ergebnis je Lauf in LT_DIAG_CPU; Stand automatisch: MAIN, FALLBACK (vor V1-V5) bzw. OPT (mit headerValue).
-- Voraussetzungen: LILAM installiert, _COMMON/01_install_testbasis.sql, SELECT auf v$sesstat, v$mystat, v$statname
-- =====================================================================
set serveroutput on size unlimited

declare
  l_cnt number;
begin
  select count(*) into l_cnt from user_tables where table_name = 'LT_DIAG_CPU';
  if l_cnt = 0 then
    execute immediate 'create table lt_diag_cpu (stand varchar2(20), ts timestamp default systimestamp, calls number,
                         srv_cpu_cs number, cli_cpu_cs number, client_ms number)';
  end if;
end;
/

declare
  c_ops   constant pls_integer := 10000;
  l_stand varchar2(20);
  l_cnt   number;
  l_pid   number;
  l_sid   number;
  l_s0    number;
  l_s1    number;
  l_c0    number;
  l_c1    number;
  l_t0    timestamp;
  l_ms    number;

  function srv_cpu return number is r number;
  begin
    execute immediate q'[select st.value from v$sesstat st join v$statname n on n.statistic# = st.statistic#
                          where n.name = 'CPU used by this session' and st.sid = :1]' into r using l_sid;
    return r;
  end;
  function my_cpu return number is r number;
  begin
    execute immediate q'[select st.value from v$mystat st join v$statname n on n.statistic# = st.statistic#
                          where n.name = 'CPU used by this session']' into r;
    return r;
  end;
begin
  select count(*) into l_cnt from user_source
   where name = 'LILAM' and type = 'PACKAGE BODY' and upper(text) like '%FUNCTION HEADERVALUE%';
  if l_cnt > 0 then
    l_stand := 'OPT';
  else
    select count(*) into l_cnt from user_source
     where name = 'LILAM' and type = 'PACKAGE BODY' and upper(text) like '%PROCEDURE CHECKCLOSING%';
    l_stand := case when l_cnt > 0 then 'FALLBACK' else 'MAIN' end;
  end if;

  lt.stop_all_servers;
  lt.start_server('LT_S1');
  lt.wait_servers_ready(sys.odcivarchar2list('LT_S1'));
  execute immediate q'[select sid from v$session where module = 'LILAM_SERVER LT_S1']' into l_sid;

  -- Aufwaermen (Cursor, Tabellenpruefung), nicht gemessen
  l_pid := lilam.server_new_process('LT_CPU_W_' || l_stand, lt.c_group, lilam.logLevelInfo);
  for o in 1 .. 500 loop lilam.info(l_pid, 'w' || o); end loop;
  lilam.close_process(l_pid);
  l_cnt := lt.wait_count('LT_CPU_W_' || l_stand, 'LOG', 500, 60);
  dbms_session.sleep(2);

  l_s0 := srv_cpu; l_c0 := my_cpu; l_t0 := systimestamp;
  l_pid := lilam.server_new_process('LT_CPU_' || l_stand, lt.c_group, lilam.logLevelInfo);
  for o in 1 .. c_ops loop
    lilam.info(l_pid, 'c0 op ' || o);
    lilam.trace_start(l_pid, 'LT_ACTION');
    lilam.trace_stop(l_pid, 'LT_ACTION');
    lilam.mark_event(l_pid, 'LT_EVENT');
    lilam.proc_step_done(l_pid);
  end loop;
  lilam.close_process(l_pid);
  l_c1 := my_cpu; l_ms := lt.ms_since(l_t0);
  l_cnt := lt.wait_count('LT_CPU_' || l_stand, 'LOG', c_ops, 120);
  -- bis process_end geschrieben ist (CLOSE als letzte Meldung)
  for i in 1 .. 60 loop
    select count(*) into l_cnt from lilam_proc where id = l_pid and process_end is not null;
    exit when l_cnt = 1;
    dbms_session.sleep(0.25);
  end loop;
  l_s1 := srv_cpu;

  insert into lt_diag_cpu (stand, calls, srv_cpu_cs, cli_cpu_cs, client_ms) values (l_stand, c_ops * 5, l_s1 - l_s0, l_c1 - l_c0, l_ms);
  commit;
  dbms_output.put_line(l_stand || ': Server ' || (l_s1 - l_s0) * 10 || ' ms CPU, Client ' || (l_c1 - l_c0) * 10
                       || ' ms CPU, Client ' || round(l_ms) || ' ms Wanduhr fuer ' || c_ops * 5 || ' Aufrufe');
  lt.stop_all_servers;
exception
  when others then
    dbms_output.put_line('ABBRUCH: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
    lt.stop_all_servers;
end;
/

-- Auswertung: CPU je Meldung (Mikrosekunden), Median je Stand
select stand, count(*) laeufe,
       round(median(srv_cpu_cs * 10000 / calls), 1) srv_us_je_meldung,
       round(median(cli_cpu_cs * 10000 / calls), 1) cli_us_je_aufruf,
       round(median(client_ms)) client_ms
  from lt_diag_cpu group by stand order by stand;
