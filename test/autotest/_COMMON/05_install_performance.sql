-- =====================================================================
-- LILAM Performance-Test: Tabellen LTP_* und Package LTP
-- Ausfuehren als Testschema (z.B. LILAM_TEST), nach 01_install_testbasis.sql (Package LT)
-- und 04_install_belastung.sql (Package LTB: Beobachter-Job und Tabellen LTB_STAGE, LTB_PROGRESS, LTB_SAMPLE).
-- Mehrfach ausfuehrbar (Tabellen bleiben erhalten, Package wird ersetzt).
--
-- LTP_VARIANT  eine Variante eines Laufs mit allen Kennzahlen
-- LTP_HIST     Verteilung der Aufrufdauer je Variante, Client und Aufrufart (Klassen, siehe bucket_hi)
--
-- Konzept und Varianten: PERFORMANCE/README.md
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
  ddl('LTP_VARIANT', 'create table ltp_variant (
      run_id          number not null,
      var_no          number not null,
      teil            number,            -- 1 ohne Regeln, 2 Gegenueberstellung mit Regeln
      name            varchar2(100),
      mode_name       varchar2(20),
      servers         number,
      clients         number,
      calls_client    number,            -- Aufrufe je Client
      pause_every     number,            -- Pause nach je n Aufrufen (0 = Dauerfeuer)
      pause_ms        number,
      cycles          number,            -- CLOSE_PROCESS + NEW_PROCESS waehrend der Last (alle Clients zusammen)
      rules           number(1),         -- 1 = Rule Set aktiv
      started         timestamp(6),      -- gemeinsamer Startzeitpunkt der Clients
      load_end        timestamp(6),      -- letzter Client fertig
      done_ts         timestamp(6),      -- alles persistiert
      load_s          number,            -- Dauer der Last aus Sicht der Anwendung
      total_s         number,            -- Start bis alles persistiert
      drain_ms        number,            -- nach Lastende bis alles persistiert
      calls_total     number,
      logs_total      number,
      client_cps      number,            -- Aufrufe/s aus Sicht der Anwendung
      end2end_cps     number,            -- Aufrufe/s bis alles persistiert
      lag_max_ms      number,            -- Sichtbarkeitsverzug der Probe-Logs (nur decoupled)
      lag_avg_ms      number,
      backlog_max     number,            -- Rueckstau Logs (gesendet - persistiert)
      cpu_avg_pct     number,
      cpu_max_pct     number,
      pga_max_kb      number,            -- Summe PGA der Server
      worker_rate_max number,
      ns_count        number,
      ns_fail         number,
      missing_log     number,
      missing_mon     number,
      missing_direct  number,
      int_errors      number,
      job_errors      number,
      verdict         varchar2(20),      -- OK / FEHLER
      reasons         varchar2(1000),
      constraint ltp_variant_pk primary key (run_id, var_no))');
  ddl('LTP_HIST', 'create table ltp_hist (
      run_id     number not null,
      var_no     number not null,
      client_no  number not null,
      call_type  number not null,       -- 1 INFO/WARN, 2 ERROR, 3 TRACE_START, 4 TRACE_STOP, 5 MARK_EVENT,
                                         -- 6 PROC_STEP_DONE, 7 SET_PROCESS_STATUS, 8 NEW_PROCESS, 9 CLOSE_PROCESS
      bucket     number not null,
      cnt        number not null)');
end;
/

create or replace package ltp authid definer as
    -- =================================================================
    -- Performance-Test: feste Varianten mit fester Aufrufzahl je Client.
    -- Gemessen wird, wie lange die Anwendung je Aufruf wartet (Verteilung je Aufrufart),
    -- wie viele Aufrufe/s die Anwendung schafft und wann alles in der Datenbank steht.
    --
    -- Teil 1 (ohne Regeln), p_clients Clients:
    --   1  INSESSION, Dauerfeuer              p_calls je Client
    --   2  INSESSION, mit Pausen              p_calls_pause je Client, p_pause_ms nach je p_pause_every Aufrufen
    --   3-5  SERVER 1/2/3 Server, Dauerfeuer
    --   6-8  SERVER 1/2/3 Server, mit Pausen
    --   9  SERVER 2 Server, Dauerfeuer mit p_cycles Ab- und Anmeldungen (CLOSE_PROCESS + NEW_PROCESS),
    --      verteilt auf alle Clients; die uebrigen senden waehrenddessen weiter
    -- Teil 2 (Gegenueberstellung Regeln), p_rule_clients Clients mit je p_rule_calls Aufrufen, Dauerfeuer:
    --   10 INSESSION ohne Regeln, 11 INSESSION mit Regeln, 12 SERVER 2 Server ohne Regeln, 13 mit Regeln
    --
    -- p_variants: NULL = alle, sonst Liste der Nummern, z.B. '1,3,10,11'
    --
    -- Aufrufmix je 100 Aufrufe wie in den Belastungstests (LTB): 4 WARN, 1 ERROR, 44 INFO,
    --   10 TRACE_START + 10 TRACE_STOP, 15 MARK_EVENT, 10 PROC_STEP_DONE, 6 SET_PROCESS_STATUS
    -- Server mit Leistungsstufe MID (Standard), wie sie Anwender bekommen.
    -- =================================================================
    function t_performance(
        p_variants     varchar2 default null,
        p_clients      number   default 3,
        p_calls        number   default 100000,
        p_calls_pause  number   default 25000,
        p_pause_every  number   default 20,
        p_pause_ms     number   default 100,
        p_cycles       number   default 100,
        p_rule_clients number   default 5,
        p_rule_calls   number   default 10000,
        p_text_len     number   default 120,
        p_drain_max    number   default 300) return number;

    -- Bericht als Markdown (Umgebung, Varianten, Aufrufdauer, Regeln, Pruefungen)
    procedure bericht(p_run_id number);

    -- Client-Job (nur intern)
    procedure client(p_run number, p_var number, p_client number, p_mode varchar2, p_prefix varchar2,
                     p_start varchar2, p_calls number, p_pause_every number, p_pause_ms number,
                     p_cycles number, p_group varchar2, p_text_len number);
end ltp;
/

create or replace package body ltp as

    c_ts_fmt    constant varchar2(30) := 'YYYY-MM-DD HH24:MI:SS.FF6';
    c_set       constant varchar2(30) := 'LT_PERF';        -- Rule Set der Variante "mit Regeln"
    c_is_group  constant varchar2(30) := 'LT_PERF';        -- Gruppe der INSESSION-Prozesse in Teil 2
    c_handler   constant varchar2(30) := 'LT_PERF_ALERT';
    c_types     constant pls_integer := 9;

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

    function us_diff(p_t0 timestamp, p_t1 timestamp) return number is
        l_d interval day(9) to second(6) := p_t1 - p_t0;
    begin
        return extract(day from l_d) * 86400000000 + extract(hour from l_d) * 3600000000
             + extract(minute from l_d) * 60000000 + extract(second from l_d) * 1000000;
    end;

    -- Klassen der Aufrufdauer: bis 1 ms in 10-us-Schritten, bis 100 ms in 1-ms-Schritten, darueber in 100-ms-Schritten
    function bucket(p_us number) return pls_integer is
    begin
        if p_us < 1000 then return trunc(p_us / 10);
        elsif p_us < 100000 then return 100 + trunc(p_us / 1000);
        else return 200 + least(trunc(p_us / 100000), 99);
        end if;
    end;

    -- Obergrenze einer Klasse in us
    function bucket_hi(p_b number) return number is
    begin
        return case when p_b < 100 then (p_b + 1) * 10
                    when p_b < 200 then (p_b - 99) * 1000
                    else (p_b - 199) * 100000 end;
    end;

    function type_name(p_t number) return varchar2 is
    begin
        return case p_t when 1 then 'INFO/WARN' when 2 then 'ERROR' when 3 then 'TRACE_START' when 4 then 'TRACE_STOP'
                        when 5 then 'MARK_EVENT' when 6 then 'PROC_STEP_DONE' when 7 then 'SET_PROCESS_STATUS'
                        when 8 then 'NEW_PROCESS' when 9 then 'CLOSE_PROCESS' end;
    end;

    function list_has(p_list varchar2, p_no number) return boolean is
    begin
        return p_list is null or instr(',' || replace(p_list, ' ') || ',', ',' || p_no || ',') > 0;
    end;

    -- Zaehlen in den LILAM-Tabellen ueber den Namenspraefix (wie LTB):
    --   LOGSRV ohne die vom Client direkt geschriebenen ERROR (NO = -1), LOGDIRECT nur diese
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
            when 'PROC_CLOSED' then 'select count(*) from lilam_proc where process_name like :1 escape ''\'' and process_end is not null'
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
        when others then return 0;
    end;

    function osstat(p_name varchar2) return number is
        l_n number;
    begin
        execute immediate 'select value from v$osstat where stat_name = :1' into l_n using p_name;
        return l_n;
    exception when others then return null;
    end;

    ----------------------------------------------------------------------
    -- Regeln: ein Rule Set, das zum Aufrufmix passt. Die meisten Regeln werden bei jedem passenden Signal
    -- geprueft, schlagen aber nicht an; eine Regel meldet jeden ERROR (gedrosselt), wie es ein Betrieb einrichten wuerde.
    ----------------------------------------------------------------------
    function mk_rule(p_id varchar2, p_trig varchar2, p_action varchar2, p_op varchar2, p_val varchar2, p_thr number default 3600)
        return varchar2 is
    begin
        return '{"id":"' || p_id || '","trigger_type":"' || p_trig || '","action":"' || p_action
            || '","condition":{"operator":"' || p_op || '","value":"' || p_val
            || '"},"alert":{"handler":"' || c_handler || '","severity":"WARN","throttle_seconds":' || p_thr || '}}';
    end;

    function rule_set(p_prefix varchar2, p_clients number) return clob is
        l clob;
    begin
        l := mk_rule('E1', 'MARK_EVENT', 'LTB_EVENT', 'MAX_OCCURRENCE', '999999999')
          || ',' || mk_rule('E2', 'MARK_EVENT', 'LTB_EVENT', 'MAX_GAP_SECONDS', '999999')
          || ',' || mk_rule('E3', 'MARK_EVENT', 'LTB_EVENT', 'PRECEDED_BY_WITHIN_SECS', 'LTB_EVENT|999999')
          || ',' || mk_rule('T1', 'TRACE_STOP', 'LTB_TRACE', 'MAX_DURATION_MS', '999999999')
          || ',' || mk_rule('T2', 'TRACE_STOP', 'LTB_TRACE', 'AVG_DEVIATION_PCT', '100000|3|0.1')
          || ',' || mk_rule('T3', 'TRACE_START', 'LTB_TRACE', 'MAX_GAP_SECONDS', '999999')
          || ',' || mk_rule('L1', 'LOGGING', 'LOGGING', 'SEVERITY', 'ERROR', 60)
          || ',' || mk_rule('L2', 'LOGGING', 'LOGGING', 'SEVERITY', 'MONITOR');
        for c in 1 .. p_clients loop
            l := l || ',' || mk_rule('P' || c, 'PROCESS_UPDATE', p_prefix || '_C' || c, 'STATUS_EQUALS', '999');
        end loop;
        return '{"header":{"rule_set":"' || c_set || '"},"rules":[' || l || ']}';
    end;

    procedure activate_rules(p_group varchar2, p_prefix varchar2, p_clients number) is
    begin
        execute immediate 'delete from lilam_rules where upper(group_name) = upper(:1) and set_name = :2' using p_group, c_set;
        execute immediate 'insert into lilam_rules(group_name, set_name, version, is_active, created, author, rule_set)
                           values (:1, :2, 1, 0, systimestamp, ''LTP'', :3)' using p_group, c_set, rule_set(p_prefix, p_clients);
        commit;
        lilam.server_update_rules(p_group, c_set, 1);
    end;

    procedure reset_rules is
    begin
        execute immediate 'delete from lilam_rules where set_name = :1' using c_set;
        execute immediate 'update lilam_rules set is_active = 0 where upper(group_name) in (:1, :2) and is_active = 1'
            using lt.c_group, c_is_group;
        commit;
    end;

    ----------------------------------------------------------------------
    -- Client-Job: p_calls Aufrufe im festen Mix, so schnell wie moeglich oder mit Pausen.
    -- Jeder Aufruf wird einzeln gemessen und in Klassen gezaehlt (LTP_HIST).
    -- Zwischenstand jede Sekunde in LTB_PROGRESS (fuer den Beobachter-Job aus LTB).
    ----------------------------------------------------------------------
    procedure client(p_run number, p_var number, p_client number, p_mode varchar2, p_prefix varchar2,
                     p_start varchar2, p_calls number, p_pause_every number, p_pause_ms number,
                     p_cycles number, p_group varchar2, p_text_len number)
    is
        l_start   timestamp := s2ts(p_start);
        l_name    varchar2(100) := p_prefix || '_C' || p_client;
        l_pad     varchar2(4000) := rpad(' ', greatest(nvl(p_text_len, 120) - 30, 0), 'x');
        l_pid     number;
        l_k       pls_integer := 0;
        l_r       pls_integer;
        l_t0      timestamp;
        l_now     timestamp;
        l_last_pr timestamp;
        l_since_pause pls_integer := 0;
        l_cycle_every number := case when p_cycles > 0 then floor(p_calls / (p_cycles + 1)) end;
        l_next_cycle  number := case when p_cycles > 0 then floor(p_calls / (p_cycles + 1)) end;
        l_cycles  pls_integer := 0;
        l_delay   number;
        l_h       t_num_tab;            -- Schluessel: Aufrufart * 1000 + Klasse
        l_key     pls_integer;
        c_calls number := 0; c_logs number := 0; c_errs number := 0; c_traces number := 0; c_events number := 0;
        c_steps number := 0; c_stati number := 0;
        c_ns number := 0; c_nssum number := 0; c_nsmax number := 0; c_nsfail number := 0;
        c_cl number := 0; c_clsum number := 0; c_clmax number := 0;

        procedure progress(p_done number) is
            pragma autonomous_transaction;
        begin
            update ltb_progress set ts = systimestamp, done = p_done, calls = c_calls, logs = c_logs, errs = c_errs,
                   traces = c_traces, events = c_events, steps = c_steps, stati = c_stati,
                   ns_cnt = c_ns, ns_sum_ms = c_nssum, ns_max_ms = c_nsmax, ns_fail = c_nsfail,
                   cl_cnt = c_cl, cl_sum_ms = c_clsum, cl_max_ms = c_clmax, start_delay_ms = l_delay
             where run_id = p_run and stage_no = p_var and client_no = p_client;
            if sql%rowcount = 0 then
                insert into ltb_progress(run_id, stage_no, client_no, ts, done, start_delay_ms)
                values (p_run, p_var, p_client, systimestamp, p_done, l_delay);
            end if;
            commit;
        end;

        procedure timed(p_type pls_integer, p_us number) is
        begin
            l_key := p_type * 1000 + bucket(p_us);
            if l_h.exists(l_key) then l_h(l_key) := l_h(l_key) + 1; else l_h(l_key) := 1; end if;
        end;

        procedure open_proc is
            l_us number;
        begin
            l_t0 := systimestamp;
            if p_mode = lt.c_insession then
                l_pid := lilam.new_process(p_processName => l_name, p_logLevel => lilam.logLevelInfo, p_groupName => p_group);
            else
                l_pid := lilam.server_new_process(l_name, lt.c_group, lilam.logLevelInfo);
            end if;
            l_us := us_diff(l_t0, systimestamp);
            timed(8, l_us);
            c_ns := c_ns + 1;
            c_nssum := c_nssum + l_us / 1000;
            c_nsmax := greatest(c_nsmax, l_us / 1000);
            if l_pid < 0 then c_nsfail := c_nsfail + 1; end if;
        end;

        procedure close_proc is
            l_us number;
        begin
            l_t0 := systimestamp;
            lilam.close_process(l_pid, 'LTP fertig', 2);
            l_us := us_diff(l_t0, systimestamp);
            timed(9, l_us);
            c_cl := c_cl + 1;
            c_clsum := c_clsum + l_us / 1000;
            c_clmax := greatest(c_clmax, l_us / 1000);
        end;

        -- eine Operation; Mix wie LTB.client mit 1 % ERROR (Zyklus von 90 Operationen = 100 Aufrufe)
        procedure one_op is
        begin
            l_k := l_k + 1;
            l_r := mod(l_k * 37, 90);
            l_t0 := systimestamp;
            if l_r < 4 then
                lilam.warn(l_pid, 'LTP warn c' || p_client || ' op ' || l_k || l_pad);
                timed(1, us_diff(l_t0, systimestamp));
                c_logs := c_logs + 1; c_calls := c_calls + 1;
            elsif l_r < 5 then
                -- realistisch: ERROR im Exception-Handler, mit Fehlerstack
                begin
                    raise_application_error(-20999, 'LTP simulierter Fehler op ' || l_k);
                exception
                    when others then
                        l_t0 := systimestamp;
                        lilam.error(l_pid, 'LTP error c' || p_client || ' op ' || l_k || l_pad);
                end;
                timed(2, us_diff(l_t0, systimestamp));
                c_logs := c_logs + 1; c_errs := c_errs + 1; c_calls := c_calls + 1;
            elsif l_r < 49 then
                lilam.info(l_pid, 'LTP info c' || p_client || ' op ' || l_k || l_pad);
                timed(1, us_diff(l_t0, systimestamp));
                c_logs := c_logs + 1; c_calls := c_calls + 1;
            elsif l_r < 59 then
                lilam.trace_start(l_pid, 'LTB_TRACE');
                l_now := systimestamp;
                timed(3, us_diff(l_t0, l_now));
                lilam.trace_stop(l_pid, 'LTB_TRACE');
                timed(4, us_diff(l_now, systimestamp));
                c_traces := c_traces + 1; c_calls := c_calls + 2;
            elsif l_r < 74 then
                lilam.mark_event(l_pid, 'LTB_EVENT', 'K' || mod(l_k, 5));
                timed(5, us_diff(l_t0, systimestamp));
                c_events := c_events + 1; c_calls := c_calls + 1;
            elsif l_r < 84 then
                lilam.proc_step_done(l_pid);
                timed(6, us_diff(l_t0, systimestamp));
                c_steps := c_steps + 1; c_calls := c_calls + 1;
            else
                lilam.set_process_status(l_pid, mod(l_k, 5) + 1, 'LTP Status ' || l_k);
                timed(7, us_diff(l_t0, systimestamp));
                c_stati := c_stati + 1; c_calls := c_calls + 1;
            end if;
            l_since_pause := l_since_pause + case when l_r between 49 and 58 then 2 else 1 end;
        end;

        procedure save_hist is
            pragma autonomous_transaction;
            l_i pls_integer := l_h.first;
        begin
            delete from ltp_hist where run_id = p_run and var_no = p_var and client_no = p_client;
            while l_i is not null loop
                insert into ltp_hist(run_id, var_no, client_no, call_type, bucket, cnt)
                values (p_run, p_var, p_client, trunc(l_i / 1000), mod(l_i, 1000), l_h(l_i));
                l_i := l_h.next(l_i);
            end loop;
            commit;
        end;
    begin
        progress(0);
        -- gemeinsamer Startzeitpunkt aller Clients der Variante (Prozess oeffnen gehoert zur Last)
        l_now := systimestamp;
        if l_now < l_start then
            dbms_session.sleep(us_diff(l_now, l_start) / 1000000);
            l_delay := 0;
        else
            l_delay := round(us_diff(l_start, l_now) / 1000);
        end if;
        open_proc;
        l_last_pr := systimestamp;
        while c_calls < p_calls loop
            one_op;
            -- Ab- und Anmelden waehrend der Last
            if l_cycles < nvl(p_cycles, 0) and c_calls >= l_next_cycle then
                close_proc;
                open_proc;
                l_cycles := l_cycles + 1;
                l_next_cycle := l_next_cycle + l_cycle_every;
            end if;
            if p_pause_every > 0 and l_since_pause >= p_pause_every then
                dbms_session.sleep(p_pause_ms / 1000);
                l_since_pause := 0;
            end if;
            if mod(l_k, 100) = 0 and us_diff(l_last_pr, systimestamp) >= 1000000 then
                progress(0);
                l_last_pr := systimestamp;
            end if;
        end loop;
        close_proc;
        save_hist;
        progress(1);
    exception
        when others then
            lt.joblog(p_run, p_client, 'ERROR', 'Variante ' || p_var || ': ' || sqlerrm || ' | ' || dbms_utility.format_error_backtrace);
            begin save_hist; exception when others then null; end;
            begin progress(1); exception when others then null; end;
    end;

    ----------------------------------------------------------------------
    -- Server starten wie LTB: p_servers Worker mit Leistungsstufe MID
    ----------------------------------------------------------------------
    procedure setup_servers(p_servers pls_integer) is
        l_list sys.odcivarchar2list := sys.odcivarchar2list();
    begin
        for i in 1 .. p_servers loop
            lt.start_server('LT_S' || i);
            l_list.extend; l_list(l_list.count) := 'LT_S' || i;
        end loop;
        lt.wait_servers_ready(l_list);
    end;

    procedure set_phase(p_run number, p_var number, p_phase varchar2) is
        pragma autonomous_transaction;
    begin
        update ltb_stage set phase = p_phase where run_id = p_run and stage_no = p_var;
        commit;
    end;

    ----------------------------------------------------------------------
    -- Eine Variante: Server starten, Clients und Beobachter starten, auf das Ende warten,
    -- Vollstaendigkeit abwarten (Drain), Kennzahlen speichern, Daten loeschen, Server stoppen
    ----------------------------------------------------------------------
    procedure run_variant(p_run number, p_var number, p_teil number, p_name varchar2, p_mode varchar2,
                          p_servers number, p_clients number, p_calls number, p_pause_every number,
                          p_pause_ms number, p_cycles number, p_rules boolean, p_text_len number, p_drain_max number)
    is
        l_v       ltp_variant%rowtype;
        l_prefix  varchar2(60) := 'LT_' || p_run || '_V' || p_var;
        l_start   timestamp;
        l_t0      timestamp;
        l_int0    number;
        l_group   varchar2(30);
        l_quota   number;
        l_errs    number; l_traces number; l_events number; l_nsfail number;
        l_reasons varchar2(1000);
        l_done    boolean;
        l_n       number;

        procedure reason(p_text varchar2) is
        begin
            l_reasons := l_reasons || case when l_reasons is not null then '; ' end || p_text;
        end;
    begin
        dbms_output.put_line('  Variante ' || p_var || ': ' || p_name);
        if p_mode = lt.c_server then
            setup_servers(p_servers);
        end if;
        if p_rules then
            l_group := case when p_mode = lt.c_insession then c_is_group else lt.c_group end;
            activate_rules(l_group, l_prefix, p_clients);
            dbms_session.sleep(1);   -- Server laden das Rule Set nach UPDATE_RULE
        elsif p_teil = 2 and p_mode = lt.c_insession then
            l_group := c_is_group;   -- gleiche Gruppe wie "mit Regeln", nur ohne aktives Rule Set
        end if;

        l_int0  := internal_errors;
        l_start := systimestamp + numtodsinterval(3 + 0.2 * p_clients, 'SECOND');
        delete from ltb_progress where run_id = p_run and stage_no = p_var;
        delete from ltb_sample where run_id = p_run and stage_no = p_var;
        delete from ltb_stage where run_id = p_run and stage_no = p_var;
        delete from ltp_hist where run_id = p_run and var_no = p_var;
        insert into ltb_stage(run_id, stage_no, spec, phase, clients, started)
        values (p_run, p_var, substr(p_name, 1, 100), 'RUN', p_clients, l_start);
        commit;

        lt.run_job('LT_CFO' || p_run || '_' || p_var,
          'begin ltb.observer(' || p_run || ', ' || p_var || ', ''' || p_mode || ''', ''' || l_prefix || ''', '''
          || ts2s(l_start) || ''', ''' || ts2s(l_start + numtodsinterval(7200, 'SECOND')) || '''); end;');
        for c in 1 .. p_clients loop
            -- Ab- und Anmeldungen gleichmaessig auf die Clients verteilen
            l_quota := floor(nvl(p_cycles, 0) / p_clients) + case when c <= mod(nvl(p_cycles, 0), p_clients) then 1 else 0 end;
            lt.run_job('LT_CF' || p_run || '_' || p_var || '_' || c,
              'begin ltp.client(' || p_run || ', ' || p_var || ', ' || c || ', ''' || p_mode || ''', ''' || l_prefix || ''', '''
              || ts2s(l_start) || ''', ' || p_calls || ', ' || p_pause_every || ', ' || p_pause_ms || ', ' || l_quota || ', '
              || case when l_group is null then 'null' else '''' || l_group || '''' end || ', ' || p_text_len || '); end;');
        end loop;

        if not lt.wait_jobs('LT_CF' || p_run || '_' || p_var || '_', 7200) then
            reason('Client-Jobs nicht beendet');
        end if;
        set_phase(p_run, p_var, 'DRAIN');

        l_v.run_id := p_run; l_v.var_no := p_var; l_v.teil := p_teil; l_v.name := p_name; l_v.mode_name := p_mode;
        l_v.servers := p_servers; l_v.clients := p_clients; l_v.calls_client := p_calls; l_v.pause_every := p_pause_every;
        l_v.pause_ms := p_pause_ms; l_v.cycles := p_cycles; l_v.rules := case when p_rules then 1 else 0 end;
        l_v.started := l_start;

        select nvl(sum(calls), 0), nvl(sum(logs), 0), nvl(sum(errs), 0), nvl(sum(traces), 0), nvl(sum(events), 0),
               nvl(sum(ns_cnt), 0), nvl(sum(ns_fail), 0), max(ts)
          into l_v.calls_total, l_v.logs_total, l_errs, l_traces, l_events, l_v.ns_count, l_nsfail, l_v.load_end
          from ltb_progress where run_id = p_run and stage_no = p_var;
        l_v.ns_fail := l_nsfail;

        -- Drain: warten, bis alle Logs, Traces, Events und geschlossenen Prozesse in der Datenbank stehen
        l_t0 := systimestamp;
        loop
            exit when cnt(l_prefix || '_C', 'LOGSRV') >= l_v.logs_total and cnt(l_prefix || '_C', 'TRACE') >= l_traces
                      and cnt(l_prefix || '_C', 'EVENT') >= l_events
                      and cnt(l_prefix || '_C', 'PROC_CLOSED') >= l_v.ns_count - l_nsfail;
            exit when us_diff(l_t0, systimestamp) > p_drain_max * 1000000;
            dbms_session.sleep(0.1);
        end loop;
        l_v.done_ts  := systimestamp;
        l_v.drain_ms := greatest(round(us_diff(l_v.load_end, l_v.done_ts) / 1000), 0);
        l_v.load_s   := round(us_diff(l_start, l_v.load_end) / 1000000, 1);
        l_v.total_s  := round(us_diff(l_start, l_v.done_ts) / 1000000, 1);
        l_v.client_cps  := round(l_v.calls_total / nullif(l_v.load_s, 0));
        l_v.end2end_cps := round(l_v.calls_total / nullif(l_v.total_s, 0));

        l_v.missing_log    := greatest(l_v.logs_total - cnt(l_prefix || '_C', 'LOGSRV'), 0);
        l_v.missing_mon    := greatest(l_traces - cnt(l_prefix || '_C', 'TRACE'), 0) + greatest(l_events - cnt(l_prefix || '_C', 'EVENT'), 0);
        l_v.missing_direct := case when p_mode = lt.c_insession then 0
                                   else greatest(l_errs - cnt(l_prefix || '_C', 'LOGDIRECT'), 0) end;
        l_v.int_errors := internal_errors - l_int0;
        select count(*) into l_v.job_errors from lt_joblog
         where run_id = p_run and phase = 'ERROR' and info like 'Variante ' || p_var || ':%';

        -- Beobachter beenden, dann Messpunkte der Lastphase auswerten
        set_phase(p_run, p_var, 'DONE');
        l_done := lt.wait_jobs('LT_CFO' || p_run || '_' || p_var, 30);
        select max(lag_ms), round(avg(lag_ms)), max(backlog), round(avg(cpu_pct), 1), max(cpu_pct), max(pga_kb), max(worker_rate)
          into l_v.lag_max_ms, l_v.lag_avg_ms, l_v.backlog_max, l_v.cpu_avg_pct, l_v.cpu_max_pct, l_v.pga_max_kb, l_v.worker_rate_max
          from ltb_sample where run_id = p_run and stage_no = p_var and phase = 'RUN';
        select greatest(nvl(l_v.lag_max_ms, 0), nvl(max(lag_ms), 0)) into l_v.lag_max_ms
          from ltb_sample where run_id = p_run and stage_no = p_var;
        if p_mode = lt.c_insession then l_v.lag_max_ms := null; l_v.lag_avg_ms := null; end if;

        if l_v.calls_total < p_clients * p_calls then reason('nur ' || l_v.calls_total || ' Aufrufe'); end if;
        if l_nsfail > 0 then reason(l_nsfail || ' NEW_PROCESS ohne Prozess'); end if;
        if l_v.missing_log + l_v.missing_mon + l_v.missing_direct > 0 then
            reason('fehlend nach ' || p_drain_max || ' s: ' || l_v.missing_log || ' Logs, ' || l_v.missing_mon || ' Monitor, '
                   || l_v.missing_direct || ' direkte ERROR');
        end if;
        if l_v.int_errors > 0 then reason(l_v.int_errors || ' interne Fehler'); end if;
        if l_v.job_errors > 0 then reason(l_v.job_errors || ' Fehler in Client-Jobs'); end if;
        l_v.verdict := case when l_reasons is null then 'OK' else 'FEHLER' end;
        l_v.reasons := l_reasons;

        delete from ltp_variant where run_id = p_run and var_no = p_var;
        insert into ltp_variant values l_v;
        commit;

        lt.check_that(p_run, 'V' || p_var || ' ' || p_name || ': vollstaendig, ohne Fehler', l_reasons is null,
                      nvl(l_reasons, l_v.calls_total || ' Aufrufe, Drain ' || l_v.drain_ms || ' ms'));
        dbms_output.put_line('    ' || l_v.verdict || '  ' || l_v.calls_total || ' Aufrufe in ' || l_v.load_s || ' s = '
                             || l_v.client_cps || '/s, alles persistiert nach ' || l_v.total_s || ' s (Drain ' || l_v.drain_ms
                             || ' ms), CPU Ø ' || l_v.cpu_avg_pct || ' %' || case when l_reasons is not null then ', ' || l_reasons end);

        -- Mit Regeln: Alerts der ERROR-Regel L1 zeigen, dass die Regeln tatsaechlich geprueft wurden
        if p_rules then
            execute immediate 'select count(*) from lilam_alerts where rule_set_name = :1 and process_name like :2 escape ''\'''
               into l_n using c_set, replace(l_prefix, '_', '\_') || '%';
            lt.metric(p_run, 'alerts_v' || p_var, l_n, 'Alerts');
            lt.check_that(p_run, 'V' || p_var || ' ' || p_name || ': Regel-Alerts erzeugt', l_n > 0, l_n || ' Alerts');
            execute immediate 'delete from lilam_alerts where rule_set_name = :1 and process_name like :2 escape ''\'''
               using c_set, replace(l_prefix, '_', '\_') || '%';
            commit;
            reset_rules;
        end if;
        if p_mode = lt.c_server then lt.stop_all_servers; end if;
        lt.purge_prefix(l_prefix);
        commit;
    exception
        when others then
            rollback;
            lt.check_that(p_run, 'V' || p_var || ' ' || p_name || ': ohne Abbruch', false,
                          substr(sqlerrm || ' ' || dbms_utility.format_error_backtrace, 1, 900));
            begin set_phase(p_run, p_var, 'DONE'); exception when others then null; end;
            begin reset_rules; exception when others then null; end;
            if p_mode = lt.c_server then lt.stop_all_servers; end if;
            commit;
    end;

    ----------------------------------------------------------------------
    -- Umgebung festhalten (fuer den Bericht)
    ----------------------------------------------------------------------
    procedure record_env(p_run number) is
        l_s varchar2(4000);
    begin
        begin
            execute immediate 'select banner_full from v$version where rownum = 1' into l_s;
        exception when others then
            begin execute immediate 'select banner from v$version where rownum = 1' into l_s;
            exception when others then l_s := null; end;
        end;
        lt.joblog(p_run, 0, 'UMGEBUNG', 'Datenbank: ' || replace(l_s, chr(10), ' '));
        begin
            execute immediate 'select value from v$parameter where name = ''cpu_count''' into l_s;
            lt.metric(p_run, 'cpu_count', to_number(l_s), 'Threads');
        exception when others then null;
        end;
        begin
            execute immediate 'select value from v$parameter where name = ''job_queue_processes''' into l_s;
            lt.metric(p_run, 'job_queue_processes', to_number(l_s), 'Jobs');
        exception when others then null;
        end;
        lt.metric(p_run, 'os_num_cpus', osstat('NUM_CPUS'), 'Threads');
        lt.metric(p_run, 'os_num_cpu_cores', osstat('NUM_CPU_CORES'), 'Kerne');
        lt.metric(p_run, 'os_physical_memory_gb', round(osstat('PHYSICAL_MEMORY_BYTES') / 1024 / 1024 / 1024, 1), 'GB');
        begin
            execute immediate 'select platform_name from v$database' into l_s;
            lt.joblog(p_run, 0, 'UMGEBUNG', 'Plattform: ' || l_s);
        exception when others then null;
        end;
    end;

    ----------------------------------------------------------------------
    function t_performance(
        p_variants     varchar2 default null,
        p_clients      number   default 3,
        p_calls        number   default 100000,
        p_calls_pause  number   default 25000,
        p_pause_every  number   default 20,
        p_pause_ms     number   default 100,
        p_cycles       number   default 100,
        p_rule_clients number   default 5,
        p_rule_calls   number   default 10000,
        p_text_len     number   default 120,
        p_drain_max    number   default 300) return number
    is
        l_run number;
        l_n   number;

        procedure v(p_no number, p_teil number, p_name varchar2, p_mode varchar2, p_servers number, p_clients_v number,
                    p_calls_v number, p_pause boolean, p_cycles_v number, p_rules boolean) is
        begin
            if list_has(p_variants, p_no) then
                run_variant(l_run, p_no, p_teil, p_name, p_mode, p_servers, p_clients_v, p_calls_v,
                            case when p_pause then p_pause_every else 0 end, case when p_pause then p_pause_ms else 0 end,
                            p_cycles_v, p_rules, p_text_len, p_drain_max);
            end if;
        end;
    begin
        l_run := lt.begin_run('PERFORMANCE', 'INSESSION+SERVER',
                   'variants=' || nvl(p_variants, 'alle') || ' clients=' || p_clients || ' calls=' || p_calls
                   || ' calls_pause=' || p_calls_pause || ' pause=' || p_pause_ms || 'ms/' || p_pause_every || ' cycles=' || p_cycles
                   || ' rule_clients=' || p_rule_clients || ' rule_calls=' || p_rule_calls || ' text_len=' || p_text_len
                   || ' perf=MID');
        dbms_output.put_line('=== PERFORMANCE run_id=' || l_run);
        lt.stop_all_servers;
        reset_rules;
        record_env(l_run);

        v(1,  1, 'INSESSION, Dauerfeuer',                  lt.c_insession, 0, p_clients, p_calls,       false, 0,        false);
        v(2,  1, 'INSESSION, mit Pausen',                  lt.c_insession, 0, p_clients, p_calls_pause, true,  0,        false);
        v(3,  1, 'DECOUPLED 1 Server, Dauerfeuer',         lt.c_server,    1, p_clients, p_calls,       false, 0,        false);
        v(4,  1, 'DECOUPLED 2 Server, Dauerfeuer',         lt.c_server,    2, p_clients, p_calls,       false, 0,        false);
        v(5,  1, 'DECOUPLED 3 Server, Dauerfeuer',         lt.c_server,    3, p_clients, p_calls,       false, 0,        false);
        v(6,  1, 'DECOUPLED 1 Server, mit Pausen',         lt.c_server,    1, p_clients, p_calls_pause, true,  0,        false);
        v(7,  1, 'DECOUPLED 2 Server, mit Pausen',         lt.c_server,    2, p_clients, p_calls_pause, true,  0,        false);
        v(8,  1, 'DECOUPLED 3 Server, mit Pausen',         lt.c_server,    3, p_clients, p_calls_pause, true,  0,        false);
        v(9,  1, 'DECOUPLED 2 Server, Ab-/Anmelden',       lt.c_server,    2, p_clients, p_calls,       false, p_cycles, false);
        v(10, 2, 'INSESSION ohne Regeln',                  lt.c_insession, 0, p_rule_clients, p_rule_calls, false, 0,    false);
        v(11, 2, 'INSESSION mit Regeln',                   lt.c_insession, 0, p_rule_clients, p_rule_calls, false, 0,    true);
        v(12, 2, 'DECOUPLED 2 Server ohne Regeln',         lt.c_server,    2, p_rule_clients, p_rule_calls, false, 0,    false);
        v(13, 2, 'DECOUPLED 2 Server mit Regeln',          lt.c_server,    2, p_rule_clients, p_rule_calls, false, 0,    true);

        select count(*) into l_n from lt_joblog where run_id = l_run and phase = 'ERROR';
        lt.check_that(l_run, 'Keine Fehler in den Client-Jobs', l_n = 0, l_n || ' Fehler');
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
            begin reset_rules; exception when others then null; end;
            lt.stop_all_servers;
            raise;
    end;

    ----------------------------------------------------------------------
    -- Bericht
    ----------------------------------------------------------------------
    procedure bericht(p_run_id number) is
        l_r   lt_run%rowtype;
        l_dur number;

        procedure p(p_line varchar2) is
        begin
            dbms_output.put_line(p_line);
        end;

        function f(p_n number) return varchar2 is
        begin
            return case when p_n is null then '-'
                        else rtrim(to_char(p_n, 'FM999G999G999G990D9', 'NLS_NUMERIC_CHARACTERS='',.'''), ',') end;
        end;

        -- Perzentil der Aufrufdauer in us (Obergrenze der Klasse), NULL ohne Messwerte
        function pct(p_var number, p_type number, p_q number) return number is
            l_b number;
        begin
            select min(bucket) into l_b from (
                select bucket, sum(cnt) over (order by bucket) cum, sum(cnt) over () tot
                  from (select bucket, sum(cnt) cnt from ltp_hist
                         where run_id = p_run_id and var_no = p_var
                           and (call_type = p_type or (p_type = 0 and call_type between 1 and 7))
                         group by bucket))
             where cum >= p_q * tot;
            return case when l_b is not null then bucket_hi(l_b) end;
        end;

        function hmax(p_var number, p_type number) return number is
            l_b number;
        begin
            select max(bucket) into l_b from ltp_hist
             where run_id = p_run_id and var_no = p_var and (call_type = p_type or (p_type = 0 and call_type between 1 and 7));
            return case when l_b is not null then bucket_hi(l_b) end;
        end;

        function us(p_n number) return varchar2 is
        begin
            return case when p_n is null then '-' when p_n >= 1000 then f(round(p_n / 1000, 1)) || ' ms' else f(p_n) || ' µs' end;
        end;

        function met(p_name varchar2) return number is
            l number;
        begin
            select max(value) into l from lt_metric where run_id = p_run_id and metric = p_name;
            return l;
        end;
    begin
        select * into l_r from lt_run where run_id = p_run_id;
        l_dur := round((cast(nvl(l_r.ended, systimestamp) as date) - cast(l_r.started as date)) * 86400);
        p(' ');
        p('## PERFORMANCE, run ' || p_run_id);
        p(' ');
        p('- Parameter: `' || l_r.params || '`');
        p('- Ergebnis: ' || l_r.status || ', Gesamtlaufzeit ' || l_dur || ' s ('
          || to_char(trunc(l_dur / 3600), 'FM00') || ':' || to_char(trunc(mod(l_dur, 3600) / 60), 'FM00') || ':'
          || to_char(mod(l_dur, 60), 'FM00') || ')');
        p(' ');
        p('### Umgebung');
        p(' ');
        for j in (select info from lt_joblog where run_id = p_run_id and phase = 'UMGEBUNG' order by ts) loop
            p('- ' || j.info);
        end loop;
        p('- CPU-Threads fuer Oracle (cpu_count): ' || f(met('cpu_count')) || ', Threads/Kerne laut Betriebssystem der VM: '
          || f(met('os_num_cpus')) || ' / ' || f(met('os_num_cpu_cores')) || ', RAM der VM: ' || f(met('os_physical_memory_gb')) || ' GB');
        p('- job_queue_processes: ' || f(met('job_queue_processes')));

        for t in 1 .. 2 loop
            p(' ');
            p(case t when 1 then '### Teil 1: ohne Regeln' else '### Teil 2: Regeln im Vergleich' end);
            p(' ');
            p('| Nr. | Variante | Clients × Aufrufe | Pausen | Last (s) | Aufrufe/s Anwendung | alles gespeichert nach (s) | Aufrufe/s bis gespeichert | Drain (s) | Aufruf Median | Aufruf 99 % | Aufruf max | Verzug max (s) | CPU Ø / max % | Ergebnis |');
            p('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|');
            for v in (select * from ltp_variant where run_id = p_run_id and teil = t order by var_no) loop
                p('| ' || v.var_no || ' | ' || v.name || ' | ' || v.clients || ' × ' || f(v.calls_client) || ' | '
                  || case when v.pause_every > 0 then v.pause_ms || ' ms je ' || v.pause_every else '-' end || ' | '
                  || f(v.load_s) || ' | ' || f(v.client_cps) || ' | ' || f(v.total_s) || ' | ' || f(v.end2end_cps) || ' | '
                  || f(round(v.drain_ms / 1000, 1)) || ' | ' || us(pct(v.var_no, 0, 0.5)) || ' | ' || us(pct(v.var_no, 0, 0.99)) || ' | '
                  || us(hmax(v.var_no, 0)) || ' | ' || f(round(v.lag_max_ms / 1000, 1)) || ' | '
                  || f(v.cpu_avg_pct) || ' / ' || f(v.cpu_max_pct) || ' | ' || v.verdict
                  || case when v.reasons is not null then ': ' || v.reasons end || ' |');
            end loop;
        end loop;

        p(' ');
        p('### Aufrufdauer je Aufrufart (Median / 99 % / Maximum)');
        p(' ');
        p('Klassen: bis 1 ms auf 10 µs genau, bis 100 ms auf 1 ms, darueber auf 100 ms (angegeben ist die Obergrenze der Klasse).');
        p(' ');
        p('| Nr. | Variante | INFO/WARN | ERROR | TRACE_START | TRACE_STOP | MARK_EVENT | PROC_STEP_DONE | SET_PROCESS_STATUS | NEW_PROCESS | CLOSE_PROCESS |');
        p('|---|---|---|---|---|---|---|---|---|---|---|');
        for v in (select * from ltp_variant where run_id = p_run_id order by var_no) loop
            declare
                l_line varchar2(4000) := '| ' || v.var_no || ' | ' || v.name || ' |';
            begin
                for ty in 1 .. c_types loop
                    l_line := l_line || ' ' || us(pct(v.var_no, ty, 0.5)) || ' / ' || us(pct(v.var_no, ty, 0.99)) || ' / '
                              || us(hmax(v.var_no, ty)) || ' |';
                end loop;
                p(l_line);
            end;
        end loop;

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

end ltp;
/

show errors package ltp
show errors package body ltp
