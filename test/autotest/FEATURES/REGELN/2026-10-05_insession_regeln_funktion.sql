-- Funktionstest: Regeln im INSESSION-Modus (Gruppe LT_INS)
declare
    l_pid    number;
    l_pid0   number;
    l_t0     timestamp := systimestamp;
    procedure rs(p_ver number, p_json clob) is
    begin
        insert into lilam_rules (group_name, set_name, version, created, author, rule_set, is_active)
        values ('LT_INS', 'LT_INS_RULES', p_ver, systimestamp, 'Claude', p_json, 0);
        commit;
    end;
    procedure trace(p_pid number, p_action varchar2) is
    begin
        lilam.trace_start(p_pid, p_action);
        dbms_session.sleep(0.05);
        lilam.trace_stop(p_pid, p_action);
    end;
    procedure mark(p_txt varchar2) is
    begin
        execute immediate 'insert into lt_ins_marks values (:1, systimestamp)' using p_txt; commit;
    end;
begin
    delete from lilam_rules where group_name = 'LT_INS';
    delete from lilam_alerts where group_name = 'LT_INS' or process_name like 'LT_INS%';
    begin execute immediate 'drop table lt_ins_marks'; exception when others then null; end;
    execute immediate 'create table lt_ins_marks (txt varchar2(100), ts timestamp)';
    commit;

    rs(1, '{"rules":[
      {"id":"R1","trigger_type":"TRACE_STOP","action":"STEP_A","condition":{"operator":"MAX_DURATION_MS","value":"10"},"alert":{"handler":"LT_INS_ALERT","severity":"WARN"}},
      {"id":"R2","trigger_type":"LOGGING","condition":{"operator":"SEVERITY","value":"ERROR"},"alert":{"handler":"LT_INS_ALERT","severity":"ERROR"}}]}');
    rs(2, '{"rules":[
      {"id":"R1B","trigger_type":"TRACE_STOP","action":"STEP_A","condition":{"operator":"MAX_DURATION_MS","value":"10"},"alert":{"handler":"LT_INS_ALERT","severity":"WARN"}}]}');
    rs(3, '{"rules":[
      {"id":"BAD","trigger_type":"TRACE_STOP","action":"STEP_A","condition":{"operator":"NO_SUCH_OP","value":"10"},"alert":{"handler":"LT_INS_ALERT"}}]}');
    lilam.server_update_rules('LT_INS', 'LT_INS_RULES', 1);

    -- 1. ohne Gruppe: keine Alerts
    execute immediate 'insert into lt_ins_marks values (''start'', systimestamp)';
    l_pid0 := lilam.new_process('LT_INS_NOGROUP', p_baselineScope => '#NONE');
    trace(l_pid0, 'STEP_A');
    lilam.error(l_pid0, 'Fehler ohne Gruppe');
    lilam.close_process(l_pid0);

    -- 2. mit Gruppe, Rule Set v1: R1 und R2
    mark('v1');
    l_pid := lilam.new_process('LT_INS_GROUP', p_baselineScope => '#NONE', p_groupName => 'lt_ins');
    trace(l_pid, 'STEP_A');
    lilam.error(l_pid, 'Fehler mit Gruppe');

    -- 3. v2 aktivieren: sofort noch v1 (R1), nach 16 s v2 (R1B)
    lilam.server_update_rules('LT_INS', 'LT_INS_RULES', 2);
    mark('v2 aktiviert');
    trace(l_pid, 'STEP_A');
    dbms_session.sleep(16);
    mark('nach 16 s');
    trace(l_pid, 'STEP_A');

    -- 4. ungültiges v3 direkt aktivieren: nach 16 s bleibt v2 (R1B), einmal protokolliert
    update lilam_rules set is_active = 0 where group_name = 'LT_INS' and is_active = 1;
    update lilam_rules set is_active = 1 where group_name = 'LT_INS' and version = 3;
    commit;
    dbms_session.sleep(16);
    mark('v3 ungueltig, nach 16 s');
    trace(l_pid, 'STEP_A');
    dbms_session.sleep(16);
    mark('v3 ungueltig, nach 32 s');
    trace(l_pid, 'STEP_A');

    -- 5. kein aktives Rule Set: nach 16 s keine Regeln
    update lilam_rules set is_active = 0 where group_name = 'LT_INS';
    commit;
    dbms_session.sleep(16);
    mark('kein aktives Set, nach 16 s');
    trace(l_pid, 'STEP_A');
    lilam.close_process(l_pid);
    mark('ende');
end;
/
