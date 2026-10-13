-- =====================================================================
-- LILAM Diagnose: PERFORMANCE / Vergleich mit OraOpenSource Logger 3.1.1, Teil A: LILAM (13.10.2026)
--
-- Gleiche Last wie Teil B (2026-10-13_vergleich_logger_b_logger.sql, Schema LOGGER_TEST):
-- 1 Session, c_calls Log-Einträge der Stufe INFO mit 120 Zeichen Text, c_rounds Runden.
-- Gemessen je Aufruf (Wanduhr, SYSTIMESTAMP vor/nach dem Aufruf): Median, 99 %, Mittel; dazu die CPU-Zeit
-- der Session (v$mystat) und die Zeit vom letzten Aufruf, bis alle Einträge in der Tabelle stehen.
--
--   A1  LILAM INSESSION, gepuffert (Sync-Level ERROR, Standard)
--   A3  LILAM DECOUPLED, 1 Server, gepuffert (Fire & Forget, mit Ringpuffer und Failover)
--   A4  Muster "Commit je Eintrag" ohne Framework: Insert + Commit in autonomer Transaktion
--       (Untergrenze für jedes Werkzeug, das jeden Eintrag sofort festschreibt)
--
-- In LILAM_TEST ausführen. Voraussetzungen: LILAM, _COMMON/01_install_testbasis.sql, SELECT auf v$mystat/v$statname.
-- Eine Runde je Aufruf; die Rundennummer zählt in LT_VGL weiter. Für gleiche Bedingungen Teil A und Teil B
-- abwechselnd aufrufen (vorher einmal: delete from lt_vgl). Auswertung am Ende.
-- LILAM schreibt bewusst gepuffert (Standard): verglichen wird der Normalbetrieb, nicht die Garantie je Eintrag.
-- =====================================================================
set serveroutput on size unlimited

declare
  l_cnt number;
begin
  select count(*) into l_cnt from user_tables where table_name = 'LT_VGL';
  if l_cnt = 0 then
    execute immediate 'create table lt_vgl (variante varchar2(60), runde number, ts timestamp default systimestamp,
                         calls number, median_us number, p99_us number, mittel_us number, cpu_ms number, gespeichert_ms number)';
  end if;
  select count(*) into l_cnt from user_tables where table_name = 'LT_VGL_COMMIT';
  if l_cnt = 0 then
    execute immediate 'create table lt_vgl_commit (id number, ts timestamp, txt varchar2(4000))';
  end if;
end;
/

declare
  c_calls  constant pls_integer := 10000;
  l_round  number;
  c_text   constant varchar2(120) := rpad('Vergleichsmessung LILAM / Logger: Eintrag der Stufe INFO mit 120 Zeichen Text ', 120, 'x');
  l_dur    sys.odcinumberlist := sys.odcinumberlist();   -- Schema-Typ: TABLE() in SQL verlangt ihn

  function my_cpu_ms return number is r number;
  begin
    execute immediate q'[select st.value from v$mystat st join v$statname n on n.statistic# = st.statistic#
                          where n.name = 'CPU used by this session']' into r;
    return r * 10;
  end;

  function us(p_t0 timestamp, p_t1 timestamp) return number is
    d interval day to second := p_t1 - p_t0;
  begin
    return ((extract(hour from d) * 60 + extract(minute from d)) * 60 + extract(second from d)) * 1e6;
  end;

  procedure store(p_var varchar2, p_round number, p_cpu_ms number, p_saved_ms number) is
    l_med number; l_p99 number; l_avg number;
  begin
    select median(column_value), percentile_disc(0.99) within group (order by column_value), avg(column_value)
      into l_med, l_p99, l_avg from table(l_dur);
    execute immediate 'insert into lt_vgl (variante, runde, calls, median_us, p99_us, mittel_us, cpu_ms, gespeichert_ms)
                       values (:1, :2, :3, :4, :5, :6, :7, :8)'
      using p_var, p_round, l_dur.count, round(l_med, 1), round(l_p99, 1), round(l_avg, 1), p_cpu_ms, round(p_saved_ms);
    commit;
    dbms_output.put_line(rpad(p_var, 50) || ' Runde ' || p_round || ': Median ' || round(l_med) || ' us, 99 % '
                         || round(l_p99) || ' us, Mittel ' || round(l_avg) || ' us, CPU ' || p_cpu_ms || ' ms'
                         || case when p_saved_ms is not null then ', gespeichert ' || round(p_saved_ms) || ' ms nach dem letzten Aufruf' end);
  end;

  -- Muster "Commit je Eintrag": wie ein Framework, das jeden Eintrag sofort festschreibt
  procedure commit_je_eintrag(p_id number, p_txt varchar2) is
    pragma autonomous_transaction;
  begin
    execute immediate 'insert into lt_vgl_commit (id, ts, txt) values (:1, systimestamp, :2)' using p_id, p_txt;
    commit;
  end;

  procedure lilam_runde(p_var varchar2, p_round number, p_decoupled boolean, p_sync pls_integer) is
    l_pid number; l_t0 timestamp; l_t1 timestamp; l_c0 number; l_end timestamp; l_n number;
  begin
    l_dur.delete; l_dur.extend(c_calls);
    if p_decoupled then
      l_pid := lilam.server_new_process('LT_VGL_' || p_round, lt.c_group, lilam.logLevelInfo, p_syncLevel => p_sync);
    else
      l_pid := lilam.new_process('LT_VGL_' || p_round, lilam.logLevelInfo, p_syncLevel => p_sync);
    end if;
    l_c0 := my_cpu_ms;
    for i in 1 .. c_calls loop
      l_t0 := systimestamp;
      lilam.info(l_pid, c_text);
      l_t1 := systimestamp;
      l_dur(i) := us(l_t0, l_t1);
    end loop;
    l_c0 := my_cpu_ms - l_c0;
    l_end := systimestamp;
    lilam.close_process(l_pid);
    for w in 1 .. 600 loop
      select count(*) into l_n from lilam_log where process_id = l_pid;
      exit when l_n >= c_calls;
      dbms_session.sleep(0.1);
    end loop;
    store(p_var, p_round, l_c0, us(l_end, systimestamp) / 1000);
  end;

  procedure muster_runde(p_round number) is
    l_t0 timestamp; l_t1 timestamp; l_c0 number;
  begin
    l_dur.delete; l_dur.extend(c_calls);
    l_c0 := my_cpu_ms;
    for i in 1 .. c_calls loop
      l_t0 := systimestamp;
      commit_je_eintrag(i, c_text);
      l_t1 := systimestamp;
      l_dur(i) := us(l_t0, l_t1);
    end loop;
    store('A4 Muster Commit je Eintrag (ohne Framework)', p_round, my_cpu_ms - l_c0, 0);
  end;
begin
  execute immediate 'select nvl(max(runde), 0) + 1 from lt_vgl where variante like ''A%''' into l_round;
  declare r number := l_round; begin
    lilam_runde('A1 LILAM INSESSION gepuffert', r, false, lilam.logLevelError);
    lt.stop_all_servers;
    lt.start_server('LT_S1');
    lt.wait_servers_ready(sys.odcivarchar2list('LT_S1'));
    lilam_runde('A3 LILAM DECOUPLED 1 Server gepuffert', r, true, lilam.logLevelError);
    lt.stop_all_servers;
    muster_runde(r);
  end;
end;
/

-- Auswertung: Median über die Runden
select variante, count(*) runden, round(median(median_us)) median_us, round(median(p99_us)) p99_us,
       round(median(mittel_us)) mittel_us, round(median(cpu_ms * 1000 / calls)) cpu_us_je_aufruf,
       round(median(gespeichert_ms)) gespeichert_ms
  from lt_vgl group by variante order by variante;
