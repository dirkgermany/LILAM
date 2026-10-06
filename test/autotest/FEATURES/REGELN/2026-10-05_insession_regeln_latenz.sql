-- Latenz INSESSION, Mediane aus 5 Runden
set serveroutput on
declare
    SUBTYPE t_num IS sys.odcinumberlist;
    N   constant pls_integer := 5000;
    NA  constant pls_integer := 200;
    R   constant pls_integer := 10;
    v_a t_num := sys.odcinumberlist(); v_b t_num := sys.odcinumberlist(); v_c t_num := sys.odcinumberlist(); v_d t_num := sys.odcinumberlist();
    v_s0 t_num := sys.odcinumberlist(); v_s1 t_num := sys.odcinumberlist(); v_a2 t_num := sys.odcinumberlist();
    l_json clob;
    l_t0 timestamp;
    l_p  number;
    l_alerts0 number;
    l_alerts1 number;
    function us(p_from timestamp) return number is
        l_d interval day to second := systimestamp - p_from;
    begin
        return extract(second from l_d) * 1e6 + extract(minute from l_d) * 60e6;
    end;
    function med(p t_num) return number is
        l_m number;
    begin
        select median(column_value) into l_m from table(p);
        return round(l_m, 1);
    end;
    function run(p_group varchar2, p_action varchar2, p_n pls_integer) return number is
        l_p number; l_s timestamp; l_r number;
    begin
        l_p := lilam.new_session('LT_INS_LAT', p_baselineScope => '#NONE', p_groupName => p_group);
        lilam.trace_start(l_p, p_action); lilam.trace_stop(l_p, p_action);
        l_s := systimestamp;
        for i in 1 .. p_n loop
            lilam.trace_start(l_p, p_action);
            lilam.trace_stop(l_p, p_action);
        end loop;
        l_r := us(l_s) / p_n;
        lilam.close_session(l_p);
        return l_r;
    end;
    procedure add(p in out t_num, v number) is begin p.extend; p(p.last) := v; end;
begin
    -- F1 schlägt bei jedem TRACE_STOP an (Dauer > -1 ms)
    l_json := '{"rules":[';
    for i in 1 .. 50 loop
        l_json := l_json || '{"id":"O' || i || '","trigger_type":"TRACE_STOP","action":"OTHER_' || i
               || '","condition":{"operator":"MAX_DURATION_MS","value":"1"},"alert":{"handler":"LT_INS_ALERT"}},';
    end loop;
    l_json := l_json
        || '{"id":"M1","trigger_type":"TRACE_STOP","action":"STEP_P","condition":{"operator":"MAX_DURATION_MS","value":"1000000000"},"alert":{"handler":"LT_INS_ALERT"}},'
        || '{"id":"F1","trigger_type":"TRACE_STOP","action":"STEP_F","condition":{"operator":"MAX_DURATION_MS","value":"-1"},"alert":{"handler":"LT_INS_ALERT"}}]}';
    delete from lilam_rules where group_name in ('LT_INS_P', 'LT_INS_Q');
    insert into lilam_rules (group_name, set_name, version, created, author, rule_set, is_active)
    values ('LT_INS_P', 'LT_INS_PERF', 2, systimestamp, 'Claude', l_json, 0);
    insert into lilam_rules (group_name, set_name, version, created, author, rule_set, is_active)
    values ('LT_INS_Q', 'LT_INS_PERF', 1, systimestamp, 'Claude', l_json, 0);
    commit;
    lilam.server_update_rules('LT_INS_P', 'LT_INS_PERF', 2);
    lilam.server_update_rules('LT_INS_Q', 'LT_INS_PERF', 1);

    -- erstes Laden einer neuen Gruppe (LT_INS_Q) in dieser DB-Session
    l_t0 := systimestamp;
    l_p  := lilam.new_session('LT_INS_LOAD', p_baselineScope => '#NONE', p_groupName => 'LT_INS_Q');
    dbms_output.put_line('NEW_SESSION mit erstem Laden (52 Regeln): ' || round(us(l_t0)) || ' us');
    lilam.close_session(l_p);

    -- NEW_SESSION ohne/mit (geladener) Gruppe, je 20 abwechselnd
    for i in 1 .. 20 loop
        l_t0 := systimestamp;
        l_p  := lilam.new_session('LT_INS_LOAD', p_baselineScope => '#NONE');
        add(v_s0, us(l_t0));
        lilam.close_session(l_p);
        l_t0 := systimestamp;
        l_p  := lilam.new_session('LT_INS_LOAD', p_baselineScope => '#NONE', p_groupName => 'LT_INS_Q');
        add(v_s1, us(l_t0));
        lilam.close_session(l_p);
    end loop;
    dbms_output.put_line('NEW_SESSION Median: ohne Gruppe ' || med(v_s0) || ' us | mit geladener Gruppe ' || med(v_s1) || ' us');

    select count(*) into l_alerts0 from lilam_alerts where group_name = 'LT_INS_P' and rule_id = 'F1';
    for i_r in 1 .. R loop
        add(v_a, run(null, 'STEP_P', N));
        add(v_b, run('LT_INS_P', 'STEP_X', N));
        add(v_c, run('LT_INS_P', 'STEP_P', N));
        add(v_a2, run(null, 'STEP_P', N));
    end loop;
    select count(*) into l_alerts1 from lilam_alerts where group_name = 'LT_INS_P' and rule_id = 'F1';

    dbms_output.put_line('je TRACE_START+TRACE_STOP, Median aus ' || R || ' Runden:');
    dbms_output.put_line('  ohne Gruppe:                      ' || med(v_a) || ' us');
    dbms_output.put_line('  Gruppe, Action ohne Regel:        ' || med(v_b) || ' us');
    dbms_output.put_line('  Gruppe, Regel ohne Treffer:       ' || med(v_c) || ' us');
    dbms_output.put_line('  ohne Gruppe (2. Messung je Runde): ' || med(v_a2) || ' us');

    update lilam_rules set is_active = 0 where group_name in ('LT_INS_P', 'LT_INS_Q');
    commit;
end;
/
