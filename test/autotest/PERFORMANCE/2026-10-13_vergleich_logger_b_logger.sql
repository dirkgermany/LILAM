-- =====================================================================
-- LILAM Diagnose: PERFORMANCE / Vergleich mit OraOpenSource Logger 3.1.1, Teil B: Logger (13.10.2026)
--
-- Gleiche Last und Messung wie Teil A (2026-10-13_vergleich_logger_a_lilam.sql):
-- 1 Session, c_calls Log-Einträge der Stufe INFO mit 120 Zeichen Text, c_rounds Runden.
--
--   B1  logger.log_info, Stufe DEBUG (Standardeinstellungen nach der Installation).
--       Logger schreibt jeden Eintrag sofort in einer autonomen Transaktion mit Commit.
--
-- In LILAM_TEST ausführen. Logger 3.1.1 ist im Schema LOGGER_TEST installiert (logger/install_3.1.1/logger_install.sql)
-- und LILAM_TEST hat EXECUTE auf LOGGER_TEST.LOGGER; der Aufruf ist statisch wie in einer Anwendung.
-- Voraussetzungen: SELECT auf v$mystat und v$statname. Stufe DEBUG ist Logger-Standard nach der Installation.
-- Eine Runde je Aufruf (Rundennummer zählt in LT_VGL weiter), abwechselnd mit Teil A aufrufen. Auswertung am Ende.
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
end;
/

declare
  c_calls  constant pls_integer := 10000;
  l_round  number;
  c_text   constant varchar2(120) := rpad('Vergleichsmessung LILAM / Logger: Eintrag der Stufe INFO mit 120 Zeichen Text ', 120, 'x');
  l_dur    sys.odcinumberlist := sys.odcinumberlist();   -- Schema-Typ: TABLE() in SQL verlangt ihn
  l_t0     timestamp;
  l_t1     timestamp;
  l_c0     number;
  l_med    number;
  l_p99    number;
  l_avg    number;

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
begin
  execute immediate 'select nvl(max(runde), 0) + 1 from lt_vgl where variante like ''B%''' into l_round;
  commit;
  declare r number := l_round; begin
    l_dur.delete; l_dur.extend(c_calls);
    l_c0 := my_cpu_ms;
    for i in 1 .. c_calls loop
      l_t0 := systimestamp;
      logger_test.logger.log_info(c_text, 'LT_VGL');
      l_t1 := systimestamp;
      l_dur(i) := us(l_t0, l_t1);
    end loop;
    l_c0 := my_cpu_ms - l_c0;
    select median(column_value), percentile_disc(0.99) within group (order by column_value), avg(column_value)
      into l_med, l_p99, l_avg from table(l_dur);
    execute immediate 'insert into lt_vgl (variante, runde, calls, median_us, p99_us, mittel_us, cpu_ms, gespeichert_ms)
                       values (:1, :2, :3, :4, :5, :6, :7, 0)'
      using 'B1 Logger 3.1.1 log_info, Stufe DEBUG', r, c_calls, round(l_med, 1), round(l_p99, 1), round(l_avg, 1), l_c0;
    commit;
    dbms_output.put_line('B1 Logger 3.1.1 log_info Runde ' || r || ': Median ' || round(l_med) || ' us, 99 % '
                         || round(l_p99) || ' us, Mittel ' || round(l_avg) || ' us, CPU ' || l_c0 || ' ms');
  end;
end;
/

-- Auswertung: Median über die Runden
select variante, count(*) runden, round(median(median_us)) median_us, round(median(p99_us)) p99_us,
       round(median(mittel_us)) mittel_us, round(median(cpu_ms * 1000 / calls)) cpu_us_je_aufruf
  from lt_vgl group by variante order by variante;
