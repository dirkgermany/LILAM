-- =====================================================================
-- LILAM Belastungstests: Tabellen LTB_* und Package LTB
-- Ausfuehren als Testschema (z.B. LILAM_TEST), nach 01_install_testbasis.sql (nutzt Package LT).
-- Mehrfach ausfuehrbar (Tabellen bleiben erhalten, Package wird ersetzt).
--
-- LTB_STAGE     eine Laststufe eines Laufs mit allen Kennzahlen und der Bewertung
-- LTB_PROGRESS  Zwischenstand je Client-Job (wird jede Sekunde ueberschrieben)
-- LTB_SAMPLE    Messpunkte des Beobachter-Jobs (Rueckstau, Verzug, Raten, CPU, Commits)
-- LTB_REQ       ein simulierter APEX-Request (Szenario APEX_STURM)
--
-- Konzept und Szenarien: BELASTUNG/README.md
-- Optionale Leserechte fuer CPU/Commits/Redo: BELASTUNG/00_grants_belastung_als_sys.sql
-- =====================================================================
set serveroutput on size unlimited

declare
  procedure ddl(p_name varchar2, p_sql varchar2) is
    l_cnt number;
  begin
    select count(*) into l_cnt from user_tables where table_name = p_name;
    if l_cnt = 0 then execute immediate p_sql; dbms_output.put_line('angelegt: ' || p_name); end if;
  end;
begin
  ddl('LTB_STAGE', 'create table ltb_stage (
      run_id          number not null,
      stage_no        number not null,
      spec            varchar2(100),
      phase           varchar2(10),      -- RUN, DRAIN, DONE
      clients         number,
      rate            number,            -- API-Aufrufe/s je Client (Angebot)
      err_pct         number,            -- Anteil ERROR an den Aufrufen in %
      procs           number,            -- gleichzeitig offene Prozesse je Client
      proc_ops        number,            -- Aufrufe je Prozess bis CLOSE/NEW (0 = ein Prozess je Stufe)
      started         timestamp(6),
      ended           timestamp(6),
      offered_cps     number,            -- angebotene Aufrufe/s gesamt
      achieved_cps    number,            -- tatsaechlich gesendete Aufrufe/s gesamt
      persisted_lps   number,            -- persistierte Logs/s waehrend der Stufe (Serverpfad)
      calls_total     number,
      logs_total      number,
      backlog_max     number,            -- Rueckstau Logs (gesendet - persistiert)
      backlog_end     number,
      backlog_slope   number,            -- Steigung des Rueckstaus in der 2. Haelfte (Logs/s)
      lag_max_ms      number,            -- max. Sichtbarkeitsverzug der Probe-Logs
      lag_avg_ms      number,
      call_avg_us     number,            -- mittlere Dauer je Aufruf ohne ERROR und NEW_SESSION
      call_max_ms     number,
      calls_gt100ms   number,            -- Aufrufe > 100 ms ohne ERROR und CLOSE_SESSION (LILAM bremst die Anwendung)
      err_avg_us      number,            -- mittlere Dauer eines ERROR-Aufrufs (inkl. Direktschreiben)
      err_max_ms      number,
      ns_count        number,            -- NEW_SESSION-Aufrufe
      ns_avg_ms       number,
      ns_max_ms       number,
      ns_fail         number,            -- NEW_SESSION mit negativer ID
      cl_avg_ms       number,            -- CLOSE_SESSION (wartet decoupled auf die Antwort des Servers, max. 1 s)
      cl_max_ms       number,
      cl_timeouts     number,            -- CLOSE_SESSION mit >= 1 s (Antwort des Servers nicht abgewartet)
      drain_ms        number,            -- Zeit nach Lastende bis alles persistiert ist
      missing_log     number,
      missing_mon     number,
      missing_direct  number,
      int_errors      number,            -- neue Eintraege in LILAM_LOG_INTERNAL
      job_errors      number,
      cpu_max_pct     number,
      cpu_avg_pct     number,
      commits_max_ps  number,
      redo_max_kbps   number,
      pga_max_kb      number,
      worker_rate_max number,            -- Summe msg_rate der Worker (Registry)
      disp_rate_max   number,            -- msg_rate des Dispatchers (Registry)
      start_delay_ms  number,            -- max. Verspaetung eines Client-Jobs gegenueber dem Startzeitpunkt
      verdict         varchar2(20),      -- OK / UEBERLAST
      reasons         varchar2(1000),
      constraint ltb_stage_pk primary key (run_id, stage_no))');
  ddl('LTB_PROGRESS', 'create table ltb_progress (
      run_id     number not null,
      stage_no   number not null,
      client_no  number not null,
      ts         timestamp(6),
      done       number(1) default 0,
      calls      number default 0,
      logs       number default 0,
      errs       number default 0,
      traces     number default 0,
      events     number default 0,
      steps      number default 0,
      stati      number default 0,
      t_cnt      number default 0,
      t_sum_us   number default 0,
      t_max_us   number default 0,
      gt10       number default 0,
      gt100      number default 0,
      gt1000     number default 0,
      e_sum_us   number default 0,
      e_max_us   number default 0,
      ns_cnt     number default 0,
      ns_sum_ms  number default 0,
      ns_max_ms  number default 0,
      ns_fail    number default 0,
      cl_cnt     number default 0,
      cl_sum_ms  number default 0,
      cl_max_ms  number default 0,
      cl_to      number default 0,
      start_delay_ms number,
      constraint ltb_progress_pk primary key (run_id, stage_no, client_no))');
  ddl('LTB_SAMPLE', 'create table ltb_sample (
      run_id       number not null,
      stage_no     number not null,
      ts           timestamp(6) default systimestamp,
      sec          number,             -- Sekunden seit Stufenbeginn
      phase        varchar2(10),
      sent_logs    number,
      pers_logs    number,
      backlog      number,
      lag_ms       number,
      worker_rate  number,
      disp_rate    number,
      open_procs   number,
      pga_kb       number,
      cpu_pct      number,
      commits_ps   number,
      redo_kbps    number,
      int_errors   number)');
  ddl('LTB_REQ', 'create table ltb_req (
      run_id     number not null,
      stage_no   number not null,
      req_no     number not null,
      sched_ts   timestamp(6),
      start_ts   timestamp(6),
      first_ms   number,                 -- erster Aufruf (Reconnect ueber den Dispatcher)
      total_ms   number,
      calls      number,
      logs       number,
      traces     number,
      events     number,
      err        varchar2(1000))');
end;
/

create or replace package ltb authid definer as
    -- =================================================================
    -- Stufenlast: Laststufen nacheinander, jede Stufe mit eigenen Client-Jobs
    -- und einem Beobachter-Job. Bewertung je Stufe: OK oder UEBERLAST (mit Gruenden).
    --
    -- p_stages: Stufen durch Komma getrennt, je Stufe
    --     <clients>x<rate>[e<err%>][n<procs>][p<ops je Prozess>]
    --   clients  gleichzeitige Client-Sessions (Scheduler-Jobs)
    --   rate     API-Aufrufe je Sekunde und Client (gleichmaessig verteilt, offene Schleife)
    --   e        Anteil ERROR in % der Aufrufe (0..45), sonst p_err_pct
    --   n        gleichzeitig offene Prozesse je Client, sonst p_procs
    --   p        Aufrufe je Prozess, danach CLOSE_SESSION und NEW_SESSION (0 = kein Wechsel), sonst p_proc_ops
    --   Beispiel: '2x200,4x200,8x200e5,8x200p50,16x50n20'
    --
    -- Aufrufmix je 100 Aufrufe: 4 WARN, e ERROR, 45-e INFO, 10 TRACE_START + 10 TRACE_STOP,
    --   15 MARK_EVENT, 10 PROC_STEP_DONE, 6 SET_PROCESS_STATUS
    -- =================================================================
    function t_stufen(
        p_test        varchar2,
        p_mode        varchar2,
        p_stages      varchar2,
        p_workers     pls_integer default 1,
        p_stage_sec   number  default 60,
        p_err_pct     number  default 1,
        p_procs       number  default 1,
        p_proc_ops    number  default 0,
        p_text_len    number  default 120,
        p_open_procs  number  default 0,       -- zusaetzlich offene, ruhende Prozesse waehrend des ganzen Laufs
        p_stop_after  number  default 2,       -- Abbruch nach n Stufen UEBERLAST in Folge (0 = nie)
        p_max_lag_ms  number  default 5000,    -- Grenze Sichtbarkeitsverzug fuer OK
        p_max_err_ms  number  default 500,     -- Grenze fuer einen ERROR-Aufruf (Direktschreiben mit Commit)
        p_drain_max   number  default 120,     -- max. Wartezeit in s nach Lastende
        p_keep_data   boolean default false,   -- FALSE: LILAM-Daten jeder Stufe nach der Auswertung loeschen
        p_manage      boolean default true,
        p_parent      number  default null,
        p_max_slow_pct number default 0.1) return number;  -- zulaessiger Anteil normaler Aufrufe > 100 ms in % (Ausreisser)

    -- Dieselben Stufen fuer jede Kombination aus Modus und Worker-Anzahl (je ein Teillauf mit PARENT_RUN_ID)
    function t_skalierung(
        p_modes       varchar2 default 'SERVER,DISPATCHER',
        p_workers     varchar2 default '1,2,3',
        p_stages      varchar2 default '2x250,4x250,8x250,12x250,16x250,16x400,16x600',
        p_stage_sec   number   default 45,
        p_err_pct     number   default 1,
        p_proc_ops    number   default 0,
        p_open_procs  number   default 0,
        p_test        varchar2 default 'BELASTUNG_SKALIERUNG') return number;

    -- APEX/ORDS: jeder Request ein eigener Job (leeres PGA) mit Reconnect ueber den Dispatcher
    --   p_stages: Requests je Sekunde je Stufe, z.B. '2,5,10,15'
    function t_apex(
        p_stages      varchar2 default '2,5,10,15',
        p_stage_sec   number   default 60,
        p_calls       number   default 13,
        p_procs       number   default 50,
        p_workers     pls_integer default 2,
        p_drain_max   number   default 120,
        p_manage      boolean  default true) return number;

    -- Auswertung als Markdown (Tabellen fuer den Bericht im results-Ordner)
    procedure bericht(p_run_id number);

    -- Jobs (nur intern)
    procedure client(p_run number, p_stage number, p_client number, p_mode varchar2, p_prefix varchar2,
                     p_start varchar2, p_end varchar2, p_rate number, p_err number, p_procs number,
                     p_proc_ops number, p_text_len number);
    procedure observer(p_run number, p_stage number, p_mode varchar2, p_prefix varchar2, p_start varchar2,
                       p_max_end varchar2);
    procedure apex_request(p_run number, p_stage number, p_req number, p_pid number, p_calls number, p_sched varchar2);
end ltb;
/

create or replace package body ltb as

    c_ts_fmt   constant varchar2(30) := 'YYYY-MM-DD HH24:MI:SS.FF6';
    c_sample_s constant number := 2;      -- Messpunkt des Beobachters alle n s
    c_probe_s  constant number := 1;      -- Probe-Log des Beobachters alle n s
    c_call_hard_ms constant number := 1000;  -- ein normaler Aufruf darueber macht die Stufe immer zur UEBERLAST

    type t_num_tab is table of number index by pls_integer;

    ----------------------------------------------------------------------
    -- Hilfen
    ----------------------------------------------------------------------
    function ts2s(p_ts timestamp) return varchar2 is
    begin
        return to_char(p_ts, c_ts_fmt);
    end;

    function s2ts(p_s varchar2) return timestamp is
    begin
        return to_timestamp(p_s, c_ts_fmt);
    end;

    -- Mikrosekunden zwischen zwei Zeitpunkten (fuer kurze Abstaende)
    function us_diff(p_t0 timestamp, p_t1 timestamp) return number is
        l_d interval day(9) to second(6) := p_t1 - p_t0;
    begin
        return extract(day from l_d) * 86400000000 + extract(hour from l_d) * 3600000000
             + extract(minute from l_d) * 60000000 + extract(second from l_d) * 1000000;
    end;

    function spec_num(p_spec varchar2, p_key varchar2, p_default number) return number is
        l_v varchar2(20);
    begin
        if p_key = 'c' then
            l_v := regexp_substr(p_spec, '^\s*(\d+)x', 1, 1, null, 1);
        else
            l_v := regexp_substr(p_spec, p_key || '(\d+)', 1, 1, null, 1);
        end if;
        return nvl(to_number(l_v), p_default);
    end;

    function list_item(p_list varchar2, p_i pls_integer) return varchar2 is
    begin
        return trim(regexp_substr(p_list, '[^,]+', 1, p_i));
    end;

    function list_count(p_list varchar2) return pls_integer is
    begin
        return nvl(regexp_count(p_list, '[^,]+'), 0);
    end;

    -- Prozess oeffnen wie in den LT-Tests (Log-Level INFO, ERROR synchron)
    function open_proc(p_mode varchar2, p_name varchar2) return number is
    begin
        if p_mode = lt.c_insession then
            return lilam.new_session(p_name, lilam.logLevelInfo);
        end if;
        if p_mode = lt.c_dispatcher then
            lilam.set_dispatcher_pipe(lt.c_disp_pipe);
        end if;
        return lilam.server_new_session(p_name, lt.c_group, lilam.logLevelInfo);
    end;

    -- Zaehlen in den LILAM-Tabellen ueber den Namenspraefix der Prozesse
    --   LOGSRV: Logs ueber den Server (bzw. INSESSION alle), LOGDIRECT: vom Client direkt geschriebene ERROR (NO = -1)
    function cnt(p_prefix varchar2, p_what varchar2) return number is
        l_sql varchar2(1000);
        l_n   number;
        l_p   varchar2(200) := replace(p_prefix, '_', '\_') || '%';
    begin
        l_sql := case upper(p_what)
            when 'LOGSRV'      then 'select count(*) from lilam_log l join lilam_proc p on p.id = l.process_id where p.process_name like :1 escape ''\'' and nvl(l.no, 0) != -1'
            when 'LOGDIRECT'   then 'select count(*) from lilam_log l join lilam_proc p on p.id = l.process_id where p.process_name like :1 escape ''\'' and l.no = -1'
            when 'TRACE'       then 'select count(*) from lilam_mon m join lilam_proc p on p.id = m.process_id where p.process_name like :1 escape ''\'' and m.mon_type = 1'
            when 'EVENT'       then 'select count(*) from lilam_mon m join lilam_proc p on p.id = m.process_id where p.process_name like :1 escape ''\'' and m.mon_type = 0'
            when 'STEPS'       then 'select nvl(sum(steps_done), 0) from lilam_proc where process_name like :1 escape ''\'''
            when 'PROC'        then 'select count(*) from lilam_proc where process_name like :1 escape ''\'''
            when 'PROC_CLOSED' then 'select count(*) from lilam_proc where process_name like :1 escape ''\'' and process_end is not null'
            when 'ROUTES'      then 'select count(*) from lilam_process_route r join lilam_proc p on p.id = r.process_id where p.process_name like :1 escape ''\'''
        end;
        execute immediate l_sql into l_n using l_p;
        return l_n;
    exception
        when others then return -1;
    end;

    function internal_errors return number is
        l_n number;
    begin
        execute immediate 'select count(*) from lilam_log_internal' into l_n;
        return l_n;
    exception
        when others then return 0;   -- Tabelle existiert erst nach dem ersten internen Fehler
    end;

    -- Kumulierte Systemwerte; NULL ohne Grants (siehe BELASTUNG/00_grants_belastung_als_sys.sql)
    function sysstat(p_name varchar2) return number is
        l_n number;
    begin
        execute immediate 'select value from v$sysstat where name = :1' into l_n using p_name;
        return l_n;
    exception when others then return null;
    end;

    function osstat(p_name varchar2) return number is
        l_n number;
    begin
        execute immediate 'select value from v$osstat where stat_name = :1' into l_n using p_name;
        return l_n;
    exception when others then return null;
    end;

    -- Server starten wie lt.setup_servers: p_workers Worker, im Modus DISPATCHER zusaetzlich der Dispatcher
    procedure setup_servers(p_mode varchar2, p_workers pls_integer) is
        l_list sys.odcivarchar2list := sys.odcivarchar2list();
    begin
        if p_mode = lt.c_insession then return; end if;
        for i in 1 .. p_workers loop
            lt.start_server('LT_S' || i);
            l_list.extend; l_list(l_list.count) := 'LT_S' || i;
        end loop;
        if p_mode = lt.c_dispatcher then
            lt.start_server(lt.c_disp_pipe, 1);
            l_list.extend; l_list(l_list.count) := lt.c_disp_pipe;
        end if;
        lt.wait_servers_ready(l_list);
    end;

    procedure set_phase(p_run number, p_stage number, p_phase varchar2) is
        pragma autonomous_transaction;
    begin
        update ltb_stage set phase = p_phase where run_id = p_run and stage_no = p_stage;
        commit;
    end;

    ----------------------------------------------------------------------
    -- Client-Job: sendet gleichmaessig p_rate Aufrufe/s bis p_end (offene Schleife:
    -- wird ein Aufruf gebremst, holt der Client danach auf, wie eine Anwendung mit Arbeitsvorrat)
    ----------------------------------------------------------------------
    procedure client(p_run number, p_stage number, p_client number, p_mode varchar2, p_prefix varchar2,
                     p_start varchar2, p_end varchar2, p_rate number, p_err number, p_procs number,
                     p_proc_ops number, p_text_len number)
    is
        l_start   timestamp := s2ts(p_start);
        l_end     timestamp := s2ts(p_end);
        l_name    varchar2(100) := p_prefix || '_C' || p_client;
        l_pad     varchar2(4000) := rpad(' ', greatest(nvl(p_text_len, 120) - 30, 0), 'x');
        l_pids    t_num_tab;
        l_pops    t_num_tab;            -- Aufrufe je Prozess-Slot seit NEW_SESSION
        l_k       pls_integer := 0;     -- Operationszaehler
        l_slot    pls_integer;
        l_r       pls_integer;
        l_due     number;
        l_now     timestamp;
        l_t0      timestamp;
        l_dt      number;
        l_last_pr timestamp;
        -- Zaehler
        c_calls number := 0; c_logs number := 0; c_errs number := 0; c_traces number := 0; c_events number := 0;
        c_steps number := 0; c_stati number := 0; c_tcnt number := 0; c_tsum number := 0; c_tmax number := 0;
        c_gt10 number := 0; c_gt100 number := 0; c_gt1000 number := 0; c_esum number := 0; c_emax number := 0;
        c_ns number := 0; c_nssum number := 0; c_nsmax number := 0; c_nsfail number := 0; c_cl number := 0; c_clsum number := 0;
        c_clmax number := 0; c_clto number := 0;
        l_delay number;

        procedure progress(p_done number) is
            pragma autonomous_transaction;
        begin
            update ltb_progress set ts = systimestamp, done = p_done, calls = c_calls, logs = c_logs, errs = c_errs,
                   traces = c_traces, events = c_events, steps = c_steps, stati = c_stati, t_cnt = c_tcnt,
                   t_sum_us = c_tsum, t_max_us = c_tmax, gt10 = c_gt10, gt100 = c_gt100, gt1000 = c_gt1000,
                   e_sum_us = c_esum, e_max_us = c_emax, ns_cnt = c_ns, ns_sum_ms = c_nssum, ns_max_ms = c_nsmax,
                   ns_fail = c_nsfail, cl_cnt = c_cl, cl_sum_ms = c_clsum, cl_max_ms = c_clmax, cl_to = c_clto, start_delay_ms = l_delay
             where run_id = p_run and stage_no = p_stage and client_no = p_client;
            if sql%rowcount = 0 then
                insert into ltb_progress(run_id, stage_no, client_no, ts, done, start_delay_ms)
                values (p_run, p_stage, p_client, systimestamp, p_done, l_delay);
            end if;
            commit;
        end;

        procedure timed(p_us number) is
        begin
            c_tcnt := c_tcnt + 1;
            c_tsum := c_tsum + p_us;
            if p_us > c_tmax then c_tmax := p_us; end if;
            if p_us > 10000 then c_gt10 := c_gt10 + 1; end if;
            if p_us > 100000 then c_gt100 := c_gt100 + 1; end if;
            if p_us > 1000000 then c_gt1000 := c_gt1000 + 1; end if;
        end;

        procedure open_slot(p_slot pls_integer) is
            l_ms number;
        begin
            l_t0 := systimestamp;
            l_pids(p_slot) := open_proc(p_mode, l_name);
            l_ms := us_diff(l_t0, systimestamp) / 1000;
            c_ns := c_ns + 1;
            c_nssum := c_nssum + l_ms;
            if l_ms > c_nsmax then c_nsmax := l_ms; end if;
            if l_pids(p_slot) < 0 then c_nsfail := c_nsfail + 1; end if;
            l_pops(p_slot) := 0;
        end;

        procedure close_slot(p_slot pls_integer) is
            l_ms number;
        begin
            l_t0 := systimestamp;
            lilam.close_session(l_pids(p_slot), 'LTB fertig', 2);
            l_ms := us_diff(l_t0, systimestamp) / 1000;
            c_cl := c_cl + 1;
            c_clsum := c_clsum + l_ms;
            if l_ms > c_clmax then c_clmax := l_ms; end if;
            -- der Client wartet hoechstens 1 s auf die Antwort des Servers (close_sessionRemote)
            if l_ms >= 990 then c_clto := c_clto + 1; end if;
        end;

        -- eine Operation; der Mix ergibt sich aus der Position im Zyklus von 90 Operationen (= 100 Aufrufe)
        procedure one_op is
            l_pid number;
        begin
            l_k := l_k + 1;
            l_slot := mod(l_k, p_procs) + 1;
            if p_proc_ops > 0 and l_pops(l_slot) >= p_proc_ops then
                close_slot(l_slot);
                open_slot(l_slot);
            end if;
            l_pid := l_pids(l_slot);
            -- 37 ist teilerfremd zu 90: die Arten verteilen sich gleichmaessig ueber den Zyklus
            l_r := mod(l_k * 37, 90);
            l_t0 := systimestamp;
            if l_r < 4 then
                lilam.warn(l_pid, 'LTB warn c' || p_client || ' op ' || l_k || l_pad);
                c_logs := c_logs + 1; c_calls := c_calls + 1;
                timed(us_diff(l_t0, systimestamp));
            elsif l_r < 4 + p_err then
                -- realistisch: ERROR im Exception-Handler, mit Fehlerstack
                begin
                    raise_application_error(-20999, 'LTB simulierter Fehler op ' || l_k);
                exception
                    when others then
                        l_t0 := systimestamp;
                        lilam.error(l_pid, 'LTB error c' || p_client || ' op ' || l_k || l_pad);
                end;
                l_dt := us_diff(l_t0, systimestamp);
                c_logs := c_logs + 1; c_errs := c_errs + 1; c_calls := c_calls + 1;
                c_esum := c_esum + l_dt;
                if l_dt > c_emax then c_emax := l_dt; end if;
            elsif l_r < 49 then
                lilam.info(l_pid, 'LTB info c' || p_client || ' op ' || l_k || l_pad);
                c_logs := c_logs + 1; c_calls := c_calls + 1;
                timed(us_diff(l_t0, systimestamp));
            elsif l_r < 59 then
                lilam.trace_start(l_pid, 'LTB_TRACE');
                lilam.trace_stop(l_pid, 'LTB_TRACE');
                c_traces := c_traces + 1; c_calls := c_calls + 2;
                l_dt := us_diff(l_t0, systimestamp) / 2;
                timed(l_dt); timed(l_dt);
            elsif l_r < 74 then
                lilam.mark_event(l_pid, 'LTB_EVENT', 'K' || mod(l_k, 5));
                c_events := c_events + 1; c_calls := c_calls + 1;
                timed(us_diff(l_t0, systimestamp));
            elsif l_r < 84 then
                lilam.proc_step_done(l_pid);
                c_steps := c_steps + 1; c_calls := c_calls + 1;
                timed(us_diff(l_t0, systimestamp));
            else
                lilam.set_process_status(l_pid, mod(l_k, 5) + 1, 'LTB Status ' || l_k);
                c_stati := c_stati + 1; c_calls := c_calls + 1;
                timed(us_diff(l_t0, systimestamp));
            end if;
            l_pops(l_slot) := l_pops(l_slot) + 1;
        end;
    begin
        progress(0);
        -- gemeinsamer Startzeitpunkt aller Clients der Stufe (Prozesse oeffnen gehoert zur Last)
        l_now := systimestamp;
        if l_now < l_start then
            dbms_session.sleep(us_diff(l_now, l_start) / 1000000);
            l_delay := 0;
        else
            l_delay := round(us_diff(l_start, l_now) / 1000);
        end if;
        for s in 1 .. p_procs loop
            open_slot(s);
        end loop;
        l_last_pr := systimestamp;
        loop
            l_now := systimestamp;
            exit when l_now >= l_end;
            l_due := floor(p_rate * us_diff(l_start, l_now) / 1000000) - c_calls;
            if l_due <= 0 then
                dbms_session.sleep(0.01);
            else
                for i in 1 .. least(l_due, 200) loop
                    one_op;
                end loop;
            end if;
            if us_diff(l_last_pr, systimestamp) >= 1000000 then
                progress(0);
                l_last_pr := systimestamp;
            end if;
        end loop;
        for s in 1 .. p_procs loop
            close_slot(s);
        end loop;
        progress(1);
    exception
        when others then
            lt.joblog(p_run, p_client, 'ERROR', 'Stufe ' || p_stage || ': ' || sqlerrm || ' | ' || dbms_utility.format_error_backtrace);
            begin progress(1); exception when others then null; end;
    end;

    ----------------------------------------------------------------------
    -- Beobachter-Job: Messpunkte alle c_sample_s s; daneben jede c_probe_s s ein Probe-Log
    -- ueber einen eigenen Prozess, dessen Sichtbarkeit in LILAM_LOG gemessen wird (Ende-zu-Ende-Verzug).
    -- Laeuft, bis die Stufe die Phase DONE erreicht (oder bis p_max_end).
    ----------------------------------------------------------------------
    procedure observer(p_run number, p_stage number, p_mode varchar2, p_prefix varchar2, p_start varchar2,
                       p_max_end varchar2)
    is
        l_start     timestamp := s2ts(p_start);
        l_max_end   timestamp := s2ts(p_max_end);
        l_pid       number;
        l_probe_ts  t_num_tab;         -- Sendezeit je Probe (Sekunden seit Stufenbeginn)
        l_sent      pls_integer := 0;
        l_seen      pls_integer := 0;
        l_vis       number;
        l_lag_max   number;            -- max. Verzug der seit dem letzten Messpunkt sichtbar gewordenen Proben
        l_last_smp  timestamp;
        l_last_prb  timestamp;
        l_phase     varchar2(10);
        l_now       timestamp;
        l_sec       number;
        l_sent_logs number;
        l_pers      number;
        l_wrate     number; l_drate number; l_open number;
        l_busy0 number; l_idle0 number; l_com0 number; l_redo0 number; l_t0 timestamp;
        l_busy1 number; l_idle1 number; l_com1 number; l_redo1 number;
        l_cpu number; l_cps number; l_rps number; l_dts number;
        l_int0 number := internal_errors;
        l_ie number; l_pga number;
        l_probe     boolean := p_mode != lt.c_insession;

        function probe_count return number is
            l_n number;
        begin
            execute immediate 'select count(*) from lilam_log where process_id = :1 and nvl(no, 0) != -1' into l_n using l_pid;
            return l_n;
        exception when others then return l_seen;
        end;

        procedure sample is
            pragma autonomous_transaction;
        begin
            l_now := systimestamp;
            l_sec := round(us_diff(l_start, l_now) / 1000000, 1);
            select nvl(sum(logs), 0) into l_sent_logs from ltb_progress where run_id = p_run and stage_no = p_stage;
            l_pers := cnt(p_prefix || '_C', 'LOGSRV');
            begin
                execute immediate 'select sum(case when nvl(is_dispatcher, 0) = 0 and rate_ts > systimestamp - interval ''3'' second then msg_rate end),
                                          max(case when nvl(is_dispatcher, 0) = 1 and rate_ts > systimestamp - interval ''3'' second then msg_rate end),
                                          sum(case when nvl(is_dispatcher, 0) = 0 then current_processes end)
                                     from lilam_server_registry where is_active = 1 and upper(group_name) = :1'
                   into l_wrate, l_drate, l_open using lt.c_group;
            exception when others then null;
            end;
            l_busy1 := osstat('BUSY_TIME'); l_idle1 := osstat('IDLE_TIME');
            l_com1 := sysstat('user commits'); l_redo1 := sysstat('redo size');
            l_dts := us_diff(l_t0, l_now) / 1000000;
            l_cpu := case when l_busy0 is not null and (l_busy1 - l_busy0) + (l_idle1 - l_idle0) > 0
                          then round(100 * (l_busy1 - l_busy0) / ((l_busy1 - l_busy0) + (l_idle1 - l_idle0)), 1) end;
            l_cps := case when l_com0 is not null and l_dts > 0 then round((l_com1 - l_com0) / l_dts, 1) end;
            l_rps := case when l_redo0 is not null and l_dts > 0 then round((l_redo1 - l_redo0) / 1024 / l_dts, 1) end;
            l_busy0 := l_busy1; l_idle0 := l_idle1; l_com0 := l_com1; l_redo0 := l_redo1; l_t0 := l_now;
            l_ie := internal_errors - l_int0;
            l_pga := lt.server_pga_kb;
            -- Offene Probe: ihr Alter ist eine untere Grenze des Verzugs
            if l_probe and l_seen < l_sent then
                l_lag_max := greatest(nvl(l_lag_max, 0), round((l_sec - l_probe_ts(l_seen + 1)) * 1000));
            end if;
            insert into ltb_sample(run_id, stage_no, ts, sec, phase, sent_logs, pers_logs, backlog, lag_ms, worker_rate,
                                   disp_rate, open_procs, pga_kb, cpu_pct, commits_ps, redo_kbps, int_errors)
            values (p_run, p_stage, l_now, l_sec, l_phase, l_sent_logs, l_pers, greatest(l_sent_logs - l_pers, 0), l_lag_max,
                    l_wrate, l_drate, l_open, l_pga, l_cpu, l_cps, l_rps, l_ie);
            commit;
            l_lag_max := null;
        end;
    begin
        l_busy0 := osstat('BUSY_TIME'); l_idle0 := osstat('IDLE_TIME');
        l_com0 := sysstat('user commits'); l_redo0 := sysstat('redo size'); l_t0 := systimestamp;
        if l_probe then
            l_pid := open_proc(p_mode, p_prefix || '_OBS');
            if l_pid < 0 then l_probe := false; end if;
        end if;
        l_last_smp := systimestamp;
        l_last_prb := systimestamp - interval '10' second;
        loop
            l_now := systimestamp;
            select max(phase) into l_phase from ltb_stage where run_id = p_run and stage_no = p_stage;
            exit when l_phase = 'DONE' or l_now > l_max_end;
            if l_probe then
                -- neue Probe senden
                if us_diff(l_last_prb, l_now) >= c_probe_s * 1000000 then
                    l_sent := l_sent + 1;
                    l_probe_ts(l_sent) := us_diff(l_start, systimestamp) / 1000000;
                    lilam.info(l_pid, 'LTB probe ' || l_sent);
                    l_last_prb := l_now;
                end if;
                -- sichtbar gewordene Proben (Reihenfolge je Prozess bleibt erhalten)
                if l_seen < l_sent then
                    l_vis := least(probe_count, l_sent);
                    while l_seen < l_vis loop
                        l_seen := l_seen + 1;
                        l_lag_max := greatest(nvl(l_lag_max, 0),
                                              round((us_diff(l_start, systimestamp) / 1000000 - l_probe_ts(l_seen)) * 1000));
                    end loop;
                end if;
            end if;
            if us_diff(l_last_smp, systimestamp) >= c_sample_s * 1000000 then
                sample;
                l_last_smp := systimestamp;
            end if;
            dbms_session.sleep(0.1);
        end loop;
        sample;
        if l_probe then lilam.close_session(l_pid); end if;
    exception
        when others then
            lt.joblog(p_run, 0, 'ERROR', 'Beobachter Stufe ' || p_stage || ': ' || sqlerrm || ' | ' || dbms_utility.format_error_backtrace);
    end;

    ----------------------------------------------------------------------
    -- Auswertung einer Stufe nach Lastende: Drain abwarten, Vollstaendigkeit, Kennzahlen, Bewertung
    ----------------------------------------------------------------------
    procedure evaluate_stage(p_run number, p_stage number, p_mode varchar2, p_prefix varchar2,
                             p_stage_sec number, p_max_lag_ms number, p_max_err_ms number, p_drain_max number, p_int0 number,
                             p_max_slow_pct number) is
        pragma autonomous_transaction;
        l_st      ltb_stage%rowtype;
        l_logs    number; l_errs number; l_traces number; l_events number; l_steps number; l_calls number;
        l_tcnt    number; l_tsum number; l_tmax number; l_gt100 number; l_esum number; l_emax number;
        l_ns      number; l_nssum number; l_nsmax number; l_nsfail number; l_cl number; l_clsum number; l_delay number;
        l_clmax   number; l_clto number;
        l_t0      timestamp := systimestamp;
        l_pers    number;
        l_direct  number;
        l_reasons varchar2(1000);
        l_p       varchar2(100) := p_prefix || '_C';
        l_elapsed number;
        l_half    number;

        procedure reason(p_text varchar2) is
        begin
            l_reasons := l_reasons || case when l_reasons is not null then '; ' end || p_text;
        end;
    begin
        select * into l_st from ltb_stage where run_id = p_run and stage_no = p_stage;
        select nvl(sum(calls), 0), nvl(sum(logs), 0), nvl(sum(errs), 0), nvl(sum(traces), 0), nvl(sum(events), 0),
               nvl(sum(steps), 0), nvl(sum(t_cnt), 0), nvl(sum(t_sum_us), 0), nvl(max(t_max_us), 0), nvl(sum(gt100), 0),
               nvl(sum(e_sum_us), 0), nvl(max(e_max_us), 0), nvl(sum(ns_cnt), 0), nvl(sum(ns_sum_ms), 0),
               nvl(max(ns_max_ms), 0), nvl(sum(ns_fail), 0), nvl(sum(cl_cnt), 0), nvl(sum(cl_sum_ms), 0), max(start_delay_ms),
               nvl(max(cl_max_ms), 0), nvl(sum(cl_to), 0)
          into l_calls, l_logs, l_errs, l_traces, l_events, l_steps, l_tcnt, l_tsum, l_tmax, l_gt100,
               l_esum, l_emax, l_ns, l_nssum, l_nsmax, l_nsfail, l_cl, l_clsum, l_delay, l_clmax, l_clto
          from ltb_progress where run_id = p_run and stage_no = p_stage;

        -- Drain: warten, bis alle Logs, Traces und Events persistiert sind
        loop
            l_pers := cnt(l_p, 'LOGSRV');
            exit when l_pers >= l_logs and cnt(l_p, 'TRACE') >= l_traces and cnt(l_p, 'EVENT') >= l_events
                      and cnt(l_p, 'PROC_CLOSED') >= l_ns - l_nsfail;
            exit when us_diff(l_t0, systimestamp) > p_drain_max * 1000000;
            dbms_session.sleep(0.25);
        end loop;
        l_st.drain_ms := round(us_diff(l_t0, systimestamp) / 1000);

        l_st.calls_total   := l_calls;
        l_st.logs_total    := l_logs;
        l_elapsed          := p_stage_sec;
        l_st.offered_cps   := l_st.clients * l_st.rate;
        l_st.achieved_cps  := round(l_calls / l_elapsed);
        l_st.missing_log   := greatest(l_logs - cnt(l_p, 'LOGSRV'), 0);
        l_st.missing_mon   := greatest(l_traces - cnt(l_p, 'TRACE'), 0) + greatest(l_events - cnt(l_p, 'EVENT'), 0);
        l_direct           := case when p_mode = lt.c_insession then 0 else l_errs end;
        l_st.missing_direct := greatest(l_direct - cnt(l_p, 'LOGDIRECT'), 0);
        l_st.call_avg_us   := case when l_tcnt > 0 then round(l_tsum / l_tcnt, 1) end;
        l_st.call_max_ms   := round(l_tmax / 1000, 1);
        l_st.calls_gt100ms := l_gt100;
        l_st.err_avg_us    := case when l_errs > 0 then round(l_esum / l_errs, 1) end;
        l_st.err_max_ms    := round(l_emax / 1000, 1);
        l_st.ns_count      := l_ns;
        l_st.ns_avg_ms     := case when l_ns > 0 then round(l_nssum / l_ns, 1) end;
        l_st.ns_max_ms     := round(l_nsmax, 1);
        l_st.ns_fail       := l_nsfail;
        l_st.cl_avg_ms     := case when l_cl > 0 then round(l_clsum / l_cl, 1) end;
        l_st.cl_max_ms     := round(l_clmax, 1);
        l_st.cl_timeouts   := l_clto;
        l_st.start_delay_ms := l_delay;
        l_st.int_errors    := internal_errors - p_int0;
        select count(*) into l_st.job_errors from lt_joblog
         where run_id = p_run and phase = 'ERROR' and info like 'Stufe ' || p_stage || ':%';

        -- Kennzahlen aus den Messpunkten der Lastphase
        select max(backlog), max(lag_ms), round(avg(lag_ms)), max(cpu_pct), round(avg(cpu_pct), 1), max(commits_ps),
               max(redo_kbps), max(pga_kb), max(worker_rate), max(disp_rate)
          into l_st.backlog_max, l_st.lag_max_ms, l_st.lag_avg_ms, l_st.cpu_max_pct, l_st.cpu_avg_pct, l_st.commits_max_ps,
               l_st.redo_max_kbps, l_st.pga_max_kb, l_st.worker_rate_max, l_st.disp_rate_max
          from ltb_sample where run_id = p_run and stage_no = p_stage and phase = 'RUN';
        -- Verzug auch aus der Drain-Phase (Proben, die erst nach Lastende sichtbar werden)
        select greatest(nvl(l_st.lag_max_ms, 0), nvl(max(lag_ms), 0)) into l_st.lag_max_ms
          from ltb_sample where run_id = p_run and stage_no = p_stage;
        select max(backlog) keep (dense_rank last order by sec) into l_st.backlog_end
          from ltb_sample where run_id = p_run and stage_no = p_stage and phase = 'RUN';
        l_half := p_stage_sec / 2;
        select round(regr_slope(backlog, sec), 1) into l_st.backlog_slope
          from ltb_sample where run_id = p_run and stage_no = p_stage and phase = 'RUN' and sec >= l_half;
        select round((max(pers_logs) - min(pers_logs)) / nullif(max(sec) - min(sec), 0))
          into l_st.persisted_lps
          from ltb_sample where run_id = p_run and stage_no = p_stage and phase = 'RUN';

        -- Bewertung: OK nur, wenn die Anwendung unbeeintraechtigt ist und LILAM mithaelt
        if l_st.achieved_cps < 0.95 * l_st.offered_cps then
            reason('Clients gebremst (' || l_st.achieved_cps || '/' || l_st.offered_cps || ' Aufrufe/s)');
        end if;
        -- Einzelne Ausreisser (z. B. ein Log-Switch) machen eine Stufe nicht zur Ueberlast: erst ab einem Anteil von
        -- p_max_slow_pct % der normalen Aufrufe. Ein einzelner Aufruf ueber 1 s zaehlt immer (Anwendung spuerbar blockiert).
        if l_gt100 > p_max_slow_pct / 100 * l_tcnt then
            reason(l_gt100 || ' Aufrufe > 100 ms (' || round(100 * l_gt100 / greatest(l_tcnt, 1), 2) || ' %)');
        end if;
        if l_tmax / 1000 > c_call_hard_ms then reason('Aufruf bis ' || round(l_tmax / 1000) || ' ms'); end if;
        if l_emax / 1000 > p_max_err_ms then reason('ERROR bis ' || round(l_emax / 1000) || ' ms'); end if;
        if l_clto > 0 then reason(l_clto || ' CLOSE_SESSION ohne Antwort in 1 s'); end if;
        if nvl(l_st.backlog_slope, 0) > 0.05 * l_st.offered_cps * l_logs / greatest(l_calls, 1)
           and nvl(l_st.backlog_end, 0) > l_st.offered_cps * l_logs / greatest(l_calls, 1) then
            reason('Rueckstau waechst (' || l_st.backlog_slope || ' Logs/s, Ende ' || l_st.backlog_end || ')');
        end if;
        if nvl(l_st.lag_max_ms, 0) > p_max_lag_ms then reason('Verzug ' || round(l_st.lag_max_ms / 1000, 1) || ' s'); end if;
        if l_nsfail > 0 then reason(l_nsfail || ' NEW_SESSION ohne Prozess'); end if;
        if l_st.missing_log + l_st.missing_mon + l_st.missing_direct > 0 then
            reason('fehlend nach ' || p_drain_max || ' s: ' || l_st.missing_log || ' Logs, ' || l_st.missing_mon || ' Monitor, '
                   || l_st.missing_direct || ' direkte ERROR');
        end if;
        if l_st.int_errors > 0 then reason(l_st.int_errors || ' interne Fehler'); end if;
        if l_st.job_errors > 0 then reason(l_st.job_errors || ' Fehler in Client-Jobs'); end if;
        l_st.verdict := case when l_reasons is null then 'OK' else 'UEBERLAST' end;
        l_st.reasons := l_reasons;
        l_st.ended   := systimestamp;
        l_st.phase   := 'DONE';

        update ltb_stage set row = l_st where run_id = p_run and stage_no = p_stage;
        commit;
    end;

    ----------------------------------------------------------------------
    procedure print_stage(p_run number, p_stage number) is
    begin
        for s in (select * from ltb_stage where run_id = p_run and stage_no = p_stage) loop
            dbms_output.put_line('    Stufe ' || s.stage_no || ' [' || s.spec || ']: ' || s.verdict
                || '  Angebot ' || s.offered_cps || '/s, erreicht ' || s.achieved_cps || '/s, persistiert ' || s.persisted_lps
                || ' Logs/s, Rueckstau max ' || s.backlog_max || ', Verzug max ' || s.lag_max_ms || ' ms, Aufruf '
                || s.call_avg_us || ' us (max ' || s.call_max_ms || ' ms), ERROR ' || s.err_avg_us || ' us, NEW_SESSION '
                || s.ns_avg_ms || ' ms (max ' || s.ns_max_ms || '), CPU max ' || s.cpu_max_pct || ' %, Drain ' || s.drain_ms || ' ms'
                || case when s.reasons is not null then chr(10) || '      Gruende: ' || s.reasons end);
        end loop;
    end;

    ----------------------------------------------------------------------
    -- Stufenlast
    ----------------------------------------------------------------------
    function t_stufen(
        p_test        varchar2,
        p_mode        varchar2,
        p_stages      varchar2,
        p_workers     pls_integer default 1,
        p_stage_sec   number  default 60,
        p_err_pct     number  default 1,
        p_procs       number  default 1,
        p_proc_ops    number  default 0,
        p_text_len    number  default 120,
        p_open_procs  number  default 0,
        p_stop_after  number  default 2,
        p_max_lag_ms  number  default 5000,
        p_max_err_ms  number  default 500,
        p_drain_max   number  default 120,
        p_keep_data   boolean default false,
        p_manage      boolean default true,
        p_parent      number  default null,
        p_max_slow_pct number default 0.1) return number
    is
        l_run      number;
        l_spec     varchar2(100);
        l_clients  number; l_rate number; l_err number; l_procs number; l_pops number;
        l_prefix   varchar2(60);
        l_start    timestamp;
        l_end      timestamp;
        l_int0     number;
        l_fails    pls_integer := 0;
        l_bg       t_num_tab;
        l_bg_name  varchar2(60);
        l_n        number;
        l_ok_cps   number := 0;
        l_verdict  varchar2(20);
        l_errs     number := 0;
        l_ms       number;
        l_done     boolean;
    begin
        l_run := lt.begin_run(p_test, p_mode,
                   'stages=' || p_stages || ' workers=' || p_workers || ' stage_sec=' || p_stage_sec || ' err_pct=' || p_err_pct
                   || ' procs=' || p_procs || ' proc_ops=' || p_proc_ops || ' text_len=' || p_text_len
                   || ' open_procs=' || p_open_procs || ' drain_max=' || p_drain_max || ' max_slow_pct=' || p_max_slow_pct, p_parent);
        if p_manage then setup_servers(p_mode, p_workers); end if;

        -- Ruhende Prozesse (z.B. viele lang laufende Anwendungen): oeffnen und bis zum Ende offen halten
        l_bg_name := 'LT_' || l_run || '_RUHE';
        if p_open_procs > 0 then
            l_start := systimestamp;
            for i in 1 .. p_open_procs loop
                l_bg(i) := open_proc(p_mode, l_bg_name);
            end loop;
            lt.metric(l_run, 'ruhende_prozesse_oeffnen_ms', lt.ms_since(l_start), 'ms');
            l_n := 0;
            for i in 1 .. p_open_procs loop
                if l_bg(i) < 0 then l_n := l_n + 1; end if;
            end loop;
            lt.check_that(l_run, p_open_procs || ' ruhende Prozesse geoeffnet', l_n = 0, l_n || ' ohne Prozess');
        end if;

        for st in 1 .. list_count(p_stages) loop
            l_spec    := list_item(p_stages, st);
            l_clients := spec_num(l_spec, 'c', 1);
            l_rate    := spec_num(l_spec, 'x', 100);
            l_err     := least(spec_num(l_spec, 'e', p_err_pct), 45);
            l_procs   := greatest(spec_num(l_spec, 'n', p_procs), 1);
            l_pops    := spec_num(l_spec, 'p', p_proc_ops);
            l_prefix  := 'LT_' || l_run || '_S' || st;
            l_int0    := internal_errors;
            -- Vorlauf fuer den Start der Jobs: 3 s + 0,2 s je Client
            l_start   := systimestamp + numtodsinterval(3 + 0.2 * l_clients, 'SECOND');
            l_end     := l_start + numtodsinterval(p_stage_sec, 'SECOND');

            delete from ltb_progress where run_id = l_run and stage_no = st;
            insert into ltb_stage(run_id, stage_no, spec, phase, clients, rate, err_pct, procs, proc_ops, started)
            values (l_run, st, l_spec, 'RUN', l_clients, l_rate, l_err, l_procs, l_pops, l_start);
            commit;

            lt.run_job('LT_CO' || l_run || '_' || st,
              'begin ltb.observer(' || l_run || ', ' || st || ', ''' || p_mode || ''', ''' || l_prefix || ''', '''
              || ts2s(l_start) || ''', ''' || ts2s(l_end + numtodsinterval(p_drain_max + 60, 'SECOND')) || '''); end;');
            for c in 1 .. l_clients loop
                lt.run_job('LT_C' || l_run || '_' || st || '_' || c,
                  'begin ltb.client(' || l_run || ', ' || st || ', ' || c || ', ''' || p_mode || ''', ''' || l_prefix || ''', '''
                  || ts2s(l_start) || ''', ''' || ts2s(l_end) || ''', ' || l_rate || ', ' || l_err || ', ' || l_procs || ', '
                  || l_pops || ', ' || p_text_len || '); end;');
            end loop;

            if not lt.wait_jobs('LT_C' || l_run || '_' || st || '_', p_stage_sec + 300) then
                lt.check_that(l_run, 'Stufe ' || st || ': Client-Jobs beendet', false, 'Zeitueberschreitung');
            end if;
            set_phase(l_run, st, 'DRAIN');
            evaluate_stage(l_run, st, p_mode, l_prefix, p_stage_sec, p_max_lag_ms, p_max_err_ms, p_drain_max, l_int0,
                           p_max_slow_pct);
            l_done := lt.wait_jobs('LT_CO' || l_run || '_' || st, 30);  -- Beobachter endet mit Phase DONE
            print_stage(l_run, st);

            select verdict, missing_log + missing_mon + missing_direct into l_verdict, l_n
              from ltb_stage where run_id = l_run and stage_no = st;
            -- Verlust ohne Protokoll waere ein echter Fehler (Philosophie: Verluste nur mit Eintrag in LILAM_LOG_INTERNAL)
            select int_errors into l_ms from ltb_stage where run_id = l_run and stage_no = st;
            lt.check_that(l_run, 'Stufe ' || st || ': kein Datenverlust ohne internen Eintrag',
                          l_n = 0 or l_ms > 0, l_n || ' fehlend, ' || l_ms || ' interne Eintraege');
            if l_verdict = 'OK' then
                l_fails := 0;
                select greatest(l_ok_cps, achieved_cps) into l_ok_cps from ltb_stage where run_id = l_run and stage_no = st;
            else
                l_fails := l_fails + 1;
            end if;

            if not p_keep_data then lt.purge_prefix(l_prefix); end if;
            exit when p_stop_after > 0 and l_fails >= p_stop_after;
        end loop;

        lt.metric(l_run, 'max_tragfaehig_aufrufe_s', l_ok_cps, 'calls/s');

        -- Ruhende Prozesse schliessen
        if p_open_procs > 0 then
            for i in 1 .. p_open_procs loop
                if l_bg(i) > 0 then lilam.close_session(l_bg(i)); end if;
            end loop;
            l_n := lt.wait_count(l_bg_name, 'PROC_CLOSED', p_open_procs, 120);
            lt.check_that(l_run, 'Ruhende Prozesse geschlossen', l_n >= 0, l_n || ' ms');
            if not p_keep_data then lt.purge_prefix(l_bg_name); end if;
        end if;

        -- Erholung: ein neuer Prozess arbeitet nach der Last wieder normal
        lt.run_job('LT_CP' || l_run, 'begin lt.probe(' || l_run || ', ''' || p_mode || ''', ''LT_' || l_run || '_PROBE'', 100); end;');
        lt.check_that(l_run, 'Probe nach der Last beendet', lt.wait_jobs('LT_CP' || l_run, 120));
        select max(value) into l_ms from lt_metric where run_id = l_run and metric = 'probe_ms';
        lt.check_that(l_run, 'Probe: neuer Prozess mit 100 Operationen < 3 s', nvl(l_ms, 99999) < 3000, l_ms || ' ms');
        if p_mode != lt.c_insession then
            l_ms := lt.wait_count('LT_' || l_run || '_PROBE', 'LOG', 100, 30);
            lt.check_that(l_run, 'Probe: Daten innerhalb 30 s persistiert', l_ms >= 0, l_ms || ' ms');
        end if;
        if not p_keep_data then lt.purge_prefix('LT_' || l_run || '_PROBE'); end if;

        select count(*) into l_errs from lt_joblog where run_id = l_run and phase = 'ERROR';
        lt.check_that(l_run, 'Keine Fehler in den Client-Jobs', l_errs = 0, l_errs || ' Fehler');
        if p_mode != lt.c_insession then
            select count(*) into l_n from lilam_server_registry
             where is_active = 1 and upper(group_name) = lt.c_group and last_activity > systimestamp - interval '15' second;
            lt.check_that(l_run, 'Alle Server laufen nach der Last', l_n >= p_workers, l_n || ' aktiv');
        end if;

        if p_manage then lt.stop_all_servers; end if;
        lt.end_run(l_run);
        bericht(l_run);
        return l_run;
    exception
        when others then
            dbms_output.put_line('ABBRUCH: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
            if l_run is not null then
                lt.check_that(l_run, 'Testablauf ohne Abbruch', false, substr(sqlerrm || ' ' || dbms_utility.format_error_backtrace, 1, 900));
                lt.end_run(l_run);
            end if;
            if p_manage then lt.stop_all_servers; end if;
            raise;
    end;

    ----------------------------------------------------------------------
    function t_skalierung(
        p_modes       varchar2 default 'SERVER,DISPATCHER',
        p_workers     varchar2 default '1,2,3',
        p_stages      varchar2 default '2x250,4x250,8x250,12x250,16x250,16x400,16x600',
        p_stage_sec   number   default 45,
        p_err_pct     number   default 1,
        p_proc_ops    number   default 0,
        p_open_procs  number   default 0,
        p_test        varchar2 default 'BELASTUNG_SKALIERUNG') return number
    is
        l_run   number;
        l_child number;
        l_mode  varchar2(30);
        l_w     pls_integer;
        l_status varchar2(10);
    begin
        l_run := lt.begin_run(p_test, p_modes, 'workers=' || p_workers || ' stages=' || p_stages || ' stage_sec=' || p_stage_sec
                              || ' err_pct=' || p_err_pct || ' proc_ops=' || p_proc_ops || ' open_procs=' || p_open_procs);
        for m in 1 .. list_count(p_modes) loop
            l_mode := upper(list_item(p_modes, m));
            for w in 1 .. list_count(p_workers) loop
                l_w := to_number(list_item(p_workers, w));
                -- DISPATCHER braucht mindestens 2 Worker (lt.setup_servers)
                continue when l_mode = lt.c_dispatcher and l_w < 2;
                begin
                    l_child := t_stufen(p_test || '_' || l_mode || '_W' || l_w, l_mode, p_stages, l_w, p_stage_sec, p_err_pct,
                                        1, p_proc_ops, 120, p_open_procs, 2, 5000, 500, 120, false, true, l_run);
                    select status into l_status from lt_run where run_id = l_child;
                    lt.check_that(l_run, l_mode || ' mit ' || l_w || ' Worker: Teillauf ' || l_child, l_status = 'PASSED', l_status);
                exception
                    when others then
                        lt.check_that(l_run, l_mode || ' mit ' || l_w || ' Worker: Teillauf ohne Abbruch', false, substr(sqlerrm, 1, 900));
                end;
            end loop;
        end loop;
        lt.end_run(l_run);
        bericht(l_run);
        return l_run;
    end;

    ----------------------------------------------------------------------
    -- APEX-Sturm
    ----------------------------------------------------------------------
    procedure apex_request(p_run number, p_stage number, p_req number, p_pid number, p_calls number, p_sched varchar2) is
        pragma autonomous_transaction;
        l_t0     timestamp := systimestamp;
        l_first  number;
        l_calls  number := 0; l_logs number := 0; l_traces number := 0; l_events number := 0;
        l_err    varchar2(1000);
        l_sched  timestamp := s2ts(p_sched);
        l_total  number;
    begin
        -- wie eine APEX-Seite: Dispatcher setzen, mit der ID aus dem Session State weiterarbeiten
        lilam.set_dispatcher_pipe(lt.c_disp_pipe);
        lilam.info(p_pid, 'LTB apex req ' || p_req || ' Beginn');   -- loest den Reconnect aus
        l_first := us_diff(l_t0, systimestamp) / 1000;
        l_calls := 1; l_logs := 1;
        while l_calls + 4 <= p_calls loop
            lilam.trace_start(p_pid, 'LTB_APEX', 'P' || mod(p_req, 7));
            lilam.mark_event(p_pid, 'LTB_APEX_EVT');
            lilam.info(p_pid, 'LTB apex req ' || p_req || ' Schritt ' || l_calls);
            lilam.trace_stop(p_pid, 'LTB_APEX', 'P' || mod(p_req, 7));
            l_calls := l_calls + 4; l_logs := l_logs + 1; l_traces := l_traces + 1; l_events := l_events + 1;
        end loop;
        l_total := round(us_diff(l_t0, systimestamp) / 1000, 2);
        insert into ltb_req(run_id, stage_no, req_no, sched_ts, start_ts, first_ms, total_ms, calls, logs, traces, events, err)
        values (p_run, p_stage, p_req, l_sched, l_t0, round(l_first, 2), l_total,
                l_calls, l_logs, l_traces, l_events, null);
        commit;
    exception
        when others then
            l_err := substr(sqlerrm || ' | ' || dbms_utility.format_error_backtrace, 1, 1000);
            insert into ltb_req(run_id, stage_no, req_no, sched_ts, start_ts, err)
            values (p_run, p_stage, p_req, l_sched, l_t0, l_err);
            commit;
    end;

    function t_apex(
        p_stages      varchar2 default '2,5,10,15',
        p_stage_sec   number   default 60,
        p_calls       number   default 13,
        p_procs       number   default 50,
        p_workers     pls_integer default 2,
        p_drain_max   number   default 120,
        p_manage      boolean  default true) return number
    is
        l_run     number;
        l_prefix  varchar2(60);
        l_pids    t_num_tab;
        l_rps     number;
        l_start   timestamp;
        l_next    timestamp;
        l_end     timestamp;
        l_req     number := 0;
        l_logs    number; l_traces number; l_events number;
        l_t0      timestamp;
        l_n       number;
        l_int0    number;
        l_fails   pls_integer := 0;
        l_done    boolean;
        l_pl number; l_pt number; l_pe number; l_ie number; l_ms number;
        l_obs     varchar2(60);
    begin
        l_run := lt.begin_run('BELASTUNG_APEX_STURM', lt.c_dispatcher,
                   'stages=' || p_stages || ' req/s, stage_sec=' || p_stage_sec || ' calls=' || p_calls || ' procs=' || p_procs
                   || ' workers=' || p_workers);
        l_prefix := 'LT_' || l_run || '_APEX';
        l_obs    := 'LT_' || l_run || '_OBS_S';
        if p_manage then setup_servers(lt.c_dispatcher, greatest(p_workers, 2)); end if;

        -- APEX-Sitzungen: je eine Prozess-ID im Session State, ueber den Dispatcher angelegt
        for i in 1 .. p_procs loop
            l_pids(i) := open_proc(lt.c_dispatcher, l_prefix);
        end loop;
        l_n := 0;
        for i in 1 .. p_procs loop
            if l_pids(i) < 0 then l_n := l_n + 1; end if;
        end loop;
        lt.check_that(l_run, p_procs || ' APEX-Prozesse angelegt', l_n = 0, l_n || ' ohne Prozess');

        for st in 1 .. list_count(p_stages) loop
            l_rps   := to_number(list_item(p_stages, st));
            l_int0  := internal_errors;
            l_start := systimestamp + interval '2' second;
            l_end   := l_start + numtodsinterval(p_stage_sec, 'SECOND');
            insert into ltb_stage(run_id, stage_no, spec, phase, clients, rate, started)
            values (l_run, st, l_rps || ' req/s', 'RUN', null, l_rps, l_start);
            commit;
            lt.run_job('LT_CO' || l_run || '_' || st,
              'begin ltb.observer(' || l_run || ', ' || st || ', ''' || lt.c_dispatcher || ''', ''' || l_obs || st
              || ''', ''' || ts2s(l_start) || ''', ''' || ts2s(l_end + numtodsinterval(p_drain_max + 60, 'SECOND')) || '''); end;');
            -- Requests im festen Takt starten
            l_next := l_start;
            loop
                exit when l_next >= l_end;
                if systimestamp < l_next then
                    dbms_session.sleep(greatest(us_diff(systimestamp, l_next) / 1000000, 0));
                end if;
                l_req := l_req + 1;
                lt.run_job('LT_CR' || l_run || '_' || l_req,
                  'begin ltb.apex_request(' || l_run || ', ' || st || ', ' || l_req || ', ' || l_pids(mod(l_req, p_procs) + 1)
                  || ', ' || p_calls || ', ''' || ts2s(l_next) || '''); end;');
                l_next := l_next + numtodsinterval(1 / l_rps, 'SECOND');
            end loop;
            if not lt.wait_jobs('LT_CR' || l_run || '_', p_drain_max + 300) then
                lt.check_that(l_run, 'Stufe ' || st || ': Request-Jobs beendet', false, 'Zeitueberschreitung');
            end if;
            set_phase(l_run, st, 'DRAIN');

            -- Vollstaendigkeit: kumuliert ueber alle bisherigen Requests
            select nvl(sum(logs), 0), nvl(sum(traces), 0), nvl(sum(events), 0) into l_logs, l_traces, l_events
              from ltb_req where run_id = l_run;
            l_t0 := systimestamp;
            loop
                exit when cnt(l_prefix, 'LOGSRV') >= l_logs and cnt(l_prefix, 'TRACE') >= l_traces and cnt(l_prefix, 'EVENT') >= l_events;
                exit when us_diff(l_t0, systimestamp) > p_drain_max * 1000000;
                dbms_session.sleep(0.25);
            end loop;

            l_pl := cnt(l_prefix, 'LOGSRV'); l_pt := cnt(l_prefix, 'TRACE'); l_pe := cnt(l_prefix, 'EVENT');
            l_ie := internal_errors - l_int0;
            l_ms := round(us_diff(l_t0, systimestamp) / 1000);
            update ltb_stage s set
                   phase = 'DONE', ended = systimestamp,
                   drain_ms = l_ms,
                   offered_cps = l_rps * p_calls,
                   (calls_total, achieved_cps, ns_count, ns_avg_ms, ns_max_ms, call_avg_us, call_max_ms, start_delay_ms, job_errors) =
                       (select sum(calls), round(sum(calls) / p_stage_sec), count(*), round(avg(first_ms), 1),
                               round(max(first_ms), 1), round(avg(total_ms) * 1000), round(max(total_ms), 1),
                               round(max(extract(second from (start_ts - sched_ts)) * 1000 + extract(minute from (start_ts - sched_ts)) * 60000)),
                               count(err)
                          from ltb_req r where r.run_id = l_run and r.stage_no = st),
                   missing_log = greatest(l_logs - l_pl, 0),
                   missing_mon = greatest(l_traces - l_pt, 0) + greatest(l_events - l_pe, 0),
                   int_errors = l_ie
             where run_id = l_run and stage_no = st;
            commit;
            -- Kennzahlen aus den Messpunkten; Bewertung: Request < 1 s, keine Fehler, nichts fehlt
            update ltb_stage s set
                   (lag_max_ms, cpu_max_pct, cpu_avg_pct, commits_max_ps, pga_max_kb, worker_rate_max, disp_rate_max) =
                       (select max(lag_ms), max(cpu_pct), round(avg(cpu_pct), 1), max(commits_ps), max(pga_kb), max(worker_rate), max(disp_rate)
                          from ltb_sample m where m.run_id = l_run and m.stage_no = st)
             where run_id = l_run and stage_no = st;
            update ltb_stage s set
                   verdict = case when nvl(call_max_ms, 0) <= 1000 and nvl(job_errors, 0) = 0 and missing_log + missing_mon = 0
                                       and nvl(int_errors, 0) = 0 and nvl(lag_max_ms, 0) <= 5000 then 'OK' else 'UEBERLAST' end,
                   reasons = rtrim(
                          case when nvl(call_max_ms, 0) > 1000 then 'Request > 1 s (max ' || call_max_ms || ' ms); ' end
                       || case when nvl(job_errors, 0) > 0 then job_errors || ' Request-Fehler; ' end
                       || case when missing_log + missing_mon > 0 then 'fehlend: ' || missing_log || ' Logs, ' || missing_mon || ' Monitor; ' end
                       || case when nvl(int_errors, 0) > 0 then int_errors || ' interne Fehler; ' end
                       || case when nvl(lag_max_ms, 0) > 5000 then 'Verzug ' || round(lag_max_ms / 1000, 1) || ' s; ' end, '; ')
             where run_id = l_run and stage_no = st;
            commit;
            l_done := lt.wait_jobs('LT_CO' || l_run || '_' || st, 30);
            print_stage(l_run, st);
            select case when verdict = 'OK' then 0 else 1 end into l_n from ltb_stage where run_id = l_run and stage_no = st;
            l_fails := case when l_n = 0 then 0 else l_fails + 1 end;
            exit when l_fails >= 2;
        end loop;

        for i in 1 .. p_procs loop
            if l_pids(i) > 0 then lilam.close_session(l_pids(i)); end if;
        end loop;
        l_n := lt.wait_count(l_prefix, 'PROC_CLOSED', p_procs, 60);
        lt.check_that(l_run, 'APEX-Prozesse geschlossen', l_n >= 0, l_n || ' ms');
        l_n := cnt(l_prefix, 'ROUTES');
        lt.check_that(l_run, 'Keine Prozess-Routen uebrig', l_n = 0, 'ist ' || l_n);
        select count(*) into l_n from ltb_req where run_id = l_run and err is not null;
        lt.check_that(l_run, 'Keine Fehler in den Requests', l_n = 0, l_n || ' Fehler');
        lt.purge_prefix(l_prefix);
        lt.purge_prefix('LT_' || l_run || '_OBS');

        if p_manage then lt.stop_all_servers; end if;
        lt.end_run(l_run);
        bericht(l_run);
        return l_run;
    exception
        when others then
            dbms_output.put_line('ABBRUCH: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
            if l_run is not null then
                lt.check_that(l_run, 'Testablauf ohne Abbruch', false, substr(sqlerrm || ' ' || dbms_utility.format_error_backtrace, 1, 900));
                lt.end_run(l_run);
            end if;
            if p_manage then lt.stop_all_servers; end if;
            raise;
    end;

    ----------------------------------------------------------------------
    -- Bericht (Markdown). Bei Laeufen mit Teillaeufen (SKALIERUNG) eine Vergleichstabelle.
    ----------------------------------------------------------------------
    procedure bericht(p_run_id number) is
        l_r   lt_run%rowtype;
        l_dur number;
        l_max number;

        procedure p(p_line varchar2) is
        begin
            dbms_output.put_line(p_line);
        end;

        function f(p_n number) return varchar2 is
        begin
            return case when p_n is null then '-'
                        else rtrim(to_char(p_n, 'FM999G999G999G990D9', 'NLS_NUMERIC_CHARACTERS='',.'''), ',') end;
        end;
    begin
        select * into l_r from lt_run where run_id = p_run_id;
        l_dur := round((cast(nvl(l_r.ended, systimestamp) as date) - cast(l_r.started as date)) * 86400);
        p(' ');
        p('## ' || l_r.test_name || ' (' || l_r.mode_name || '), run ' || p_run_id);
        p(' ');
        p('- Parameter: `' || l_r.params || '`');
        p('- Ergebnis: ' || l_r.status || ', Gesamtlaufzeit ' || l_dur || ' s ('
          || to_char(trunc(l_dur / 3600), 'FM00') || ':' || to_char(trunc(mod(l_dur, 3600) / 60), 'FM00') || ':'
          || to_char(mod(l_dur, 60), 'FM00') || ')');

        -- Vergleich der Teillaeufe
        for c in (select count(*) n from lt_run where parent_run_id = p_run_id) loop
            if c.n > 0 then
                p(' ');
                p('| Teillauf | Modus | Parameter | max. tragfaehig (Aufrufe/s) | erste Ueberlast-Stufe | Grund |');
                p('|---|---|---|---|---|---|');
                for k in (select r.run_id, r.test_name, r.mode_name, r.params,
                                 (select max(achieved_cps) from ltb_stage s where s.run_id = r.run_id and s.verdict = 'OK') ok_cps,
                                 (select min(spec) keep (dense_rank first order by stage_no) from ltb_stage s
                                   where s.run_id = r.run_id and s.verdict != 'OK') fail_spec,
                                 (select min(reasons) keep (dense_rank first order by stage_no) from ltb_stage s
                                   where s.run_id = r.run_id and s.verdict != 'OK') fail_reason
                            from lt_run r where r.parent_run_id = p_run_id order by r.run_id) loop
                    p('| ' || k.run_id || ' | ' || k.mode_name || ' | ' || regexp_substr(k.params, 'workers=\d+') || ' | '
                      || f(k.ok_cps) || ' | ' || nvl(k.fail_spec, '-') || ' | ' || nvl(k.fail_reason, '-') || ' |');
                end loop;
            end if;
        end loop;

        -- Stufen
        for c in (select count(*) n from ltb_stage where run_id = p_run_id) loop
            if c.n > 0 and l_r.test_name = 'BELASTUNG_APEX_STURM' then
                p(' ');
                p('| Stufe | Requests/s | Aufrufe/s | Request Ø ms | Request max ms | Reconnect Ø/max ms | Startverzug max ms (Scheduler) | Verzug max ms | Drain ms | CPU max % | Worker-/Disp.-Rate | Bewertung |');
                p('|---|---|---|---|---|---|---|---|---|---|---|---|');
                for s in (select * from ltb_stage where run_id = p_run_id order by stage_no) loop
                    p('| ' || s.stage_no || ' | ' || f(s.rate) || ' | ' || f(s.achieved_cps) || ' | ' || f(round(s.call_avg_us / 1000, 1)) || ' | '
                      || f(s.call_max_ms) || ' | ' || f(s.ns_avg_ms) || ' / ' || f(s.ns_max_ms) || ' | ' || f(s.start_delay_ms) || ' | '
                      || f(s.lag_max_ms) || ' | ' || f(s.drain_ms) || ' | ' || f(s.cpu_max_pct) || ' | '
                      || f(s.worker_rate_max) || ' / ' || f(s.disp_rate_max)
                      || ' | ' || s.verdict || case when s.reasons is not null then ': ' || s.reasons end || ' |');
                end loop;
            elsif c.n > 0 then
                p(' ');
                p('| Stufe | Spez. | Angebot/s | erreicht/s | pers. Logs/s | Rueckstau max/Ende | Verzug max ms | Aufruf Ø µs | Aufruf max ms | ERROR Ø µs / max ms | NEW_SESSION Ø/max ms (Fehler) | CLOSE Ø/max ms (Timeout) | Drain ms | CPU max % | Commits/s max | Worker-/Disp.-Rate | Bewertung |');
                p('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|');
                for s in (select * from ltb_stage where run_id = p_run_id order by stage_no) loop
                    p('| ' || s.stage_no || ' | ' || s.spec || ' | ' || f(s.offered_cps) || ' | ' || f(s.achieved_cps) || ' | '
                      || f(s.persisted_lps) || ' | ' || f(s.backlog_max) || ' / ' || f(s.backlog_end) || ' | ' || f(s.lag_max_ms) || ' | '
                      || f(s.call_avg_us) || ' | ' || f(s.call_max_ms) || ' | ' || f(s.err_avg_us) || ' / ' || f(s.err_max_ms) || ' | '
                      || f(s.ns_avg_ms) || ' / ' || f(s.ns_max_ms) || ' (' || nvl(s.ns_fail, 0) || ') | '
                      || f(s.cl_avg_ms) || ' / ' || f(s.cl_max_ms) || ' (' || nvl(s.cl_timeouts, 0) || ') | ' || f(s.drain_ms) || ' | '
                      || f(s.cpu_max_pct) || ' | ' || f(s.commits_max_ps) || ' | ' || f(s.worker_rate_max) || ' / ' || f(s.disp_rate_max)
                      || ' | ' || s.verdict || case when s.reasons is not null then ': ' || s.reasons end || ' |');
                end loop;

                -- Hochrechnung: wie viele Clients eines Lastprofils traegt diese Konfiguration?
                select max(achieved_cps) into l_max from ltb_stage where run_id = p_run_id and verdict = 'OK';
                if l_max > 0 and l_r.test_name != 'BELASTUNG_APEX_STURM' then
                    p(' ');
                    p('Hochrechnung aus der hoechsten tragfaehigen Stufe (' || f(l_max) || ' Aufrufe/s), gilt nur fuer diese Hardware:');
                    p(' ');
                    p('| Lastprofil je Client | Aufrufe/s je Client | Clients gleichzeitig |');
                    p('|---|---|---|');
                    p('| Nachtbatch, intensiv protokolliert | 200 | ' || f(floor(l_max / 200)) || ' |');
                    p('| Sachbearbeitung / Dunkelverarbeitung | 20 | ' || f(floor(l_max / 20)) || ' |');
                    p('| Hintergrundjob, sparsam protokolliert | 2 | ' || f(floor(l_max / 2)) || ' |');
                end if;
            end if;
        end loop;

        -- Pruefungen
        p(' ');
        p('| Pruefung | Ergebnis | Detail |');
        p('|---|---|---|');
        for c in (select * from lt_check where run_id = p_run_id order by check_no) loop
            p('| ' || c.check_name || ' | ' || case when c.ok = 1 then 'OK' else 'FEHLER' end || ' | ' || c.detail || ' |');
        end loop;
    exception
        when no_data_found then
            p('Lauf ' || p_run_id || ' nicht gefunden');
    end;

end ltb;
/

show errors package ltb
show errors package body ltb
