-- =====================================================================
-- LILAM Diagnose: FEATURES / SPEICHER / PGA der Server (Befund F2, befunde fallback)
--
-- SPEICHER run 2177 und 2192 (Branch fallback): PGA der Worker im Modus SERVER waechst im Median
-- 66-107 Byte je Prozess (main run 2114: 0 B), dazu Spruenge um etwa +-33 MB in einzelnen Bloecken.
--
-- Ablauf wie SPEICHER SV: Worker LT_S1, LT_S2 und Dispatcher LT_DISP laufen; 2.000 Prozesse Aufwaermen,
-- dann 5 Bloecke zu 1.000 Prozessen, je Prozess 4 x (info, trace, event, step), nach jedem Block
-- warten, bis alles geschrieben ist, dann 3 s Ruhe.
-- p_workers = 1: nur LT_S1 (erste Messung 13.10.2026), 2: LT_S1, LT_S2 und LT_DISP (wie SPEICHER).
-- Ein Sampler-Job schreibt alle 0,2 s je Server-Session PGA und Zustand nach LT_DIAG_PGA:
--   v$process (pga_used/alloc/freeable/max) und v$session (sql_id, PL/SQL-Unterprogramm, event).
-- Die Lastschleife setzt Marken (kind = 'MARK') nach jedem Block.
-- Der Tag ist der Package-Stand: FALLBACK (Body enthaelt checkClosing) oder MAIN, mit Anzahl Worker.
-- (Substitutionsvariablen wie &TAG ersetzt die SQLcl-MCP-Verbindung nicht.)
-- Voraussetzungen: LILAM installiert, _COMMON/00_grants_als_sys.sql, _COMMON/01_install_testbasis.sql
-- Ergebnis: FEATURES/SPEICHER/results/2026-10-13_pga_worker_diag.md
-- =====================================================================
set serveroutput on size unlimited

declare
  l_cnt number;
begin
  select count(*) into l_cnt from user_tables where table_name = 'LT_DIAG_PGA';
  if l_cnt = 0 then
    execute immediate 'create table lt_diag_pga (
        tag          varchar2(30),
        kind         varchar2(10),          -- SAMPLE | MARK | STOP
        ts           timestamp(6) default systimestamp,
        note         varchar2(200),
        pga_used     number,
        pga_alloc    number,
        pga_free     number,
        pga_max      number,
        sql_id       varchar2(13),
        prev_sql_id  varchar2(13),
        entry_obj    number,
        entry_sub    number,
        plsql_obj    number,
        plsql_sub    number,
        event        varchar2(64),
        action       varchar2(64))';
  end if;
  select count(*) into l_cnt from user_tab_columns where table_name = 'LT_DIAG_PGA' and column_name = 'MODULE';
  if l_cnt = 0 then
    execute immediate 'alter table lt_diag_pga add (module varchar2(64))';
  end if;
end;
/

declare
  c_workers constant pls_integer := 2;      -- 1 oder 2 (siehe Kopf)
  c_warm    constant pls_integer := 2000;
  c_blocks  constant pls_integer := 5;
  c_block   constant pls_integer := 1000;
  c_ops     constant pls_integer := 4;
  l_tag     varchar2(30);
  l_cnt     number;
  l_pid     number;
  l_done    pls_integer := 0;
  l_t0      timestamp := systimestamp;

  procedure mark(p_note varchar2) is
  begin
    execute immediate q'[
      insert into lt_diag_pga (tag, kind, note, module, pga_used, pga_alloc, pga_free, pga_max)
      select :1, 'MARK', :2, s.module, p.pga_used_mem, p.pga_alloc_mem, p.pga_freeable_mem, p.pga_max_mem
        from v$session s join v$process p on p.addr = s.paddr
       where s.module like 'LILAM_SERVER LT_%']' using l_tag, p_note;
    commit;
  end;

  procedure load(p_n pls_integer) is
  begin
    for i in 1 .. p_n loop
      l_pid := lilam.server_new_process('LT_DIAG_PGA_' || l_tag, lt.c_group, lilam.logLevelInfo);
      for o in 1 .. c_ops loop
        lilam.info(l_pid, 'c0 op ' || o);
        lilam.trace_start(l_pid, 'LT_ACTION');
        lilam.trace_stop(l_pid, 'LT_ACTION');
        lilam.mark_event(l_pid, 'LT_EVENT');
        lilam.proc_step_done(l_pid);
      end loop;
      lilam.close_process(l_pid);
    end loop;
    l_done := l_done + p_n;
  end;

  -- wie lt.t_speicher: warten, bis alle Logs geschrieben sind, dann 3 s Ruhe
  procedure settle is
    l_n number;
  begin
    l_n := lt.wait_count('LT_DIAG_PGA_' || l_tag, 'LOG', l_done * c_ops, 60);
    dbms_session.sleep(3);
  end;
begin
  select count(*) into l_cnt from user_source
   where name = 'LILAM' and type = 'PACKAGE BODY' and upper(text) like '%PROCEDURE CHECKCLOSING%';
  l_tag := case when l_cnt > 0 then 'FALLBACK' else 'MAIN' end || '_W' || c_workers;
  execute immediate 'delete from lt_diag_pga where tag = :1' using l_tag;
  commit;

  lt.stop_all_servers;
  lt.start_server('LT_S1');
  if c_workers > 1 then
    lt.start_server('LT_S2');
    lt.start_server(lt.c_disp_pipe, 1);
    lt.wait_servers_ready(sys.odcivarchar2list('LT_S1', 'LT_S2', lt.c_disp_pipe));
  else
    lt.wait_servers_ready(sys.odcivarchar2list('LT_S1'));
  end if;

  -- Sampler: alle 0,2 s, bis eine STOP-Zeile dieses Tags kommt (hoechstens 20 min).
  -- Jobname ohne Praefix LT_: lt.stop_all_servers stoppt alle Jobs LT_%.
  dbms_scheduler.create_job(
    job_name   => 'DIAG_PGA_SAMPLER',
    job_type   => 'PLSQL_BLOCK',
    job_action => replace(q'[
      declare
        l_stop number;
        l_end  timestamp := systimestamp + interval '20' minute;
      begin
        loop
          insert into lt_diag_pga (tag, kind, module, pga_used, pga_alloc, pga_free, pga_max, sql_id, prev_sql_id,
                                   entry_obj, entry_sub, plsql_obj, plsql_sub, event, action)
          select '#TAG#', 'SAMPLE', s.module, p.pga_used_mem, p.pga_alloc_mem, p.pga_freeable_mem, p.pga_max_mem,
                 s.sql_id, s.prev_sql_id, s.plsql_entry_object_id, s.plsql_entry_subprogram_id,
                 s.plsql_object_id, s.plsql_subprogram_id, s.event, s.action
            from v$session s join v$process p on p.addr = s.paddr
           where s.module like 'LILAM_SERVER LT_%';
          commit;
          select count(*) into l_stop from lt_diag_pga where tag = '#TAG#' and kind = 'STOP';
          exit when l_stop > 0 or systimestamp > l_end;
          dbms_session.sleep(0.2);
        end loop;
      end;]', '#TAG#', l_tag),
    enabled    => true,
    auto_drop  => true);

  mark('start');
  load(c_warm);
  settle;
  mark('warm ' || l_done);
  for b in 1 .. c_blocks loop
    load(c_block);
    settle;
    mark('block ' || b || ' ' || l_done);
  end loop;

  execute immediate 'insert into lt_diag_pga (tag, kind, note) values (:1, ''STOP'', :2)'
    using l_tag, 'Ende nach ' || round(lt.ms_since(l_t0)) || ' ms';
  commit;
  dbms_session.sleep(1);
  lt.stop_all_servers;
  dbms_output.put_line('Diagnose ' || l_tag || ' fertig: ' || l_done || ' Prozesse in ' || round(lt.ms_since(l_t0) / 1000) || ' s');
exception
  when others then
    dbms_output.put_line('ABBRUCH: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
    execute immediate 'insert into lt_diag_pga (tag, kind, note) values (:1, ''STOP'', ''Abbruch'')' using l_tag;
    commit;
    lt.stop_all_servers;
end;
/

-- Auswertung 1: PGA je Server an den Marken (Zuwachs je Block in Byte je Prozess)
select tag, module, note, round(pga_used / 1024) used_kb, round(pga_max / 1024) max_kb,
       round((pga_used - lag(pga_used) over (partition by tag, module order by ts)) / 1000) d_b_je_proz
  from lt_diag_pga where kind = 'MARK' order by tag, module, ts;

-- Auswertung 2: Spruenge > 4 MB zwischen zwei Samples derselben Session, mit PL/SQL-Unterprogramm
select tag, module, to_char(ts, 'HH24:MI:SS.FF2') zeit, round(pga_used / 1024) used_kb, round(d / 1024) delta_kb,
       (select o.object_name || '.' || pr.procedure_name from user_procedures pr join user_objects o on o.object_id = pr.object_id
         where pr.object_id = x.plsql_obj and pr.subprogram_id = x.plsql_sub) plsql,
       (select o.object_name || '.' || pr.procedure_name from user_procedures pr join user_objects o on o.object_id = pr.object_id
         where pr.object_id = x.entry_obj and pr.subprogram_id = x.entry_sub) entry,
       sql_id, prev_sql_id, event
  from (select t.*, pga_used - lag(pga_used) over (partition by tag, module order by ts) d
          from lt_diag_pga t where kind = 'SAMPLE') x
 where abs(d) > 4 * 1024 * 1024
 order by tag, ts;
