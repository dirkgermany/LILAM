# N1: PRECEDED_BY_WITHIN_SECS bei Prozess-Triggern (Entwurf)

- **Herkunft:** Fall C1, von Dirk am 07.10.2026 an C4 übergeben („N1: repariere den Code in C4“)
- **Stand:** Entwurf auf Basis `claude` = `716a6e7`; Klon nicht geändert (Sperre für `lilam.pkb` liegt bei C1)
- **Umsetzung:** nach Sperrmeldung des Koordinators; Dirks Ja zu Commit und Push liegt vor

## Befund

`lilam.pkb`, `evaluateRules_internal`, Z. 1312–1318:

```sql
WHEN 'PRECEDED_BY_WITHIN_SECS' THEN
    IF g_last_action_per_process.EXISTS(p_ctx.process_id) AND predecessorMatches(p_list(i)) THEN
        l_diff_ms := get_ms_diff(g_last_action_per_process(p_ctx.process_id).stop_time, p_ctx.start_time);
```

Bei `PROCESS_UPDATE` und `PROCESS_STOP` kommt der Kontext aus `mapProcessRecToContextRec` (Z. 1451 ff.): `start_time` ist dort `processStart`. Der Vorgänger (Event/Trace des Prozesses) liegt immer nach dem Prozessstart, die Differenz ist also negativ. Der Zeitteil kann nie auslösen, es wirkt nur der Teil „falscher Vorgänger“.

Bei `MARK_EVENT` und `TRACE_START` ist `start_time` der Zeitpunkt des Signals. Dort ist der Code richtig und bleibt unverändert.

### Woher kommt die Bezugszeit?

- **`PROCESS_STOP`** (`CLOSE_SESSION`, Z. ~5006): `g_process_cache(p_processId).processEnd := systimestamp` wird **vor** `evaluateRules(..., C_PROCESS_STOP)` gesetzt. → `process_end` ist die Bezugszeit.
- **`PROCESS_UPDATE`** (`setAnyStatus`, Z. 4597–4616): `lastUpdate` wird lokal **nirgends** gesetzt. Es kommt nur aus JSON (Remote-Abfrage, Z. 4712) und wird bei `NEW_SESSION` auf NULL gesetzt (Z. 5081). Die Kette `coalesce(process_end, last_update, systimestamp)` fiele bei `PROCESS_UPDATE` also immer auf `SYSTIMESTAMP` zurück.
  - `setAnyStatus` bekommt aber bereits den Zeitpunkt des Signals als `p_timestamp`. Alle API-Aufrufer übergeben `SYSTIMESTAMP` (Z. 4632–4675). Im Server-Modus kommt der Zeitstempel des Clients per JSON an (`setAnyStatusRemote` → `jTs('timestamp')`, `doRemote_setAnyStatus` Z. 5239). Bisher wird er nicht genutzt.
  - `SYSTIMESTAMP` im Server wäre zudem falsch: Die Verarbeitungsverzögerung der Pipe würde als Abstand mitgezählt. Bei Rückstau könnte die Regel fälschlich auslösen; der Test unten würde dann im SERVER-Modus flackern.

**Entscheidung im Entwurf:** `p_timestamp` aus `setAnyStatus` geht als Bezugszeit in den Kontext (`last_update`), aber nur in den Kontext der Regelprüfung. `g_process_cache.lastUpdate` bleibt unverändert, damit `GET_PROCESS_DATA` sein Verhalten nicht ändert (Feld heute im Cache NULL). `SYSTIMESTAMP` bleibt nur Rückfall (PERFORMANCE: wird nur berechnet, wenn der Vorgänger passt und beide Zeiten fehlen).

> Alternative (nicht gewählt): `g_process_cache(p_processId).lastUpdate := p_timestamp` in `setAnyStatus`. Das wäre einfacher, ändert aber das Ergebnis von `GET_PROCESS_DATA`/`GET_PROCESS_DATA_JSON` (`lastUpdate` heute NULL). Das ist eine eigene Entscheidung (ggf. C1/Dirk).

## Patch `source/package/lilam.pkb`

```diff
@@ evaluateRules_internal, WHEN 'PRECEDED_BY_WITHIN_SECS'
                         WHEN 'PRECEDED_BY_WITHIN_SECS' THEN
                             IF g_last_action_per_process.EXISTS(p_ctx.process_id) AND predecessorMatches(p_list(i)) THEN
-                                l_diff_ms := get_ms_diff(g_last_action_per_process(p_ctx.process_id).stop_time, p_ctx.start_time);
+                                -- For process triggers start_time is the process start; use the time of the signal
+                                -- (PROCESS_STOP: process_end, PROCESS_UPDATE: signal time in last_update).
+                                -- PERFORMANCE: SYSTIMESTAMP only as fallback.
+                                l_diff_ms := get_ms_diff(g_last_action_per_process(p_ctx.process_id).stop_time,
+                                    CASE WHEN p_trigger IN (C_PROCESS_UPDATE, C_PROCESS_STOP)
+                                         THEN coalesce(p_ctx.process_end, p_ctx.last_update, systimestamp)
+                                         ELSE p_ctx.start_time END);
                                 fire := l_diff_ms / 1000 > p_list(i).cond_num;
@@ evaluateRules (process)
-    PROCEDURE evaluateRules(p_processRec t_process_rec, p_trigger VARCHAR2)
+    -- p_signalTime: time of the signal (PROCESS_UPDATE), reference time for PRECEDED_BY_WITHIN_SECS
+    PROCEDURE evaluateRules(p_processRec t_process_rec, p_trigger VARCHAR2, p_signalTime TIMESTAMP := NULL)
     AS
+        l_ctx t_eval_context_rec;
     BEGIN
-        evaluateRules_internal(mapProcessRecToContextRec(p_processRec), p_trigger, p_check_context => FALSE);
+        l_ctx := mapProcessRecToContextRec(p_processRec);
+        l_ctx.last_update := coalesce(p_signalTime, l_ctx.last_update);
+        evaluateRules_internal(l_ctx, p_trigger, p_check_context => FALSE);
     END evaluateRules;
@@ setAnyStatus
-            evaluateRules(g_process_cache(p_processId), C_PROCESS_UPDATE);                
+            evaluateRules(g_process_cache(p_processId), C_PROCESS_UPDATE, p_timestamp);
```

Anmerkungen:
- Die Überladungen bleiben eindeutig (erster Parameter `t_monitor_buffer_rec` bzw. `t_process_rec`). Keine Vorwärtsdeklaration, nicht in der `.pks`.
- Die übrigen Aufrufer (`PROCESS_STOP` Z. 5014, `PROCESS_START` Z. 5088) bleiben ohne dritten Parameter.
- `PRECEDED_BY` ohne Zeit, `RUNTIME_EXCEEDED` (nutzt weiter `systimestamp`) und Event/Trace-Trigger bleiben unverändert.
- Die Zeile 4616 endet heute mit Leerzeichen. Der Anker für die Ersetzung ist `evaluateRules(g_process_cache(p_processId), C_PROCESS_UPDATE);`.

## Test `test/autotest/_COMMON/01_install_testbasis.sql` (`lt.t_regeln`)

**Warum nicht wie vorgeschlagen** (`mark_event RG_A` mit `p_timestamp` 5 s in der Vergangenheit): Der Vorgänger läge dann **vor** dem Prozessstart. Der alte Code rechnet `processStart − (jetzt − 5 s) ≈ +5 s` und löst ebenfalls aus; der Test würde den Fehler nicht zeigen. `NEW_SESSION`/`SET_PROCESS_STATUS` haben keinen Zeitstempel-Parameter. Deterministisch geht es daher nur mit einer echten Pause, im gleichen Muster und mit der gleichen Reserve wie VG-03 und NF-01 (Grenze 1 s, Pause 1,3 s). Mit dem Zeitstempel des Signals aus `setAnyStatus` ist das auch im SERVER-Modus unabhängig von der Verarbeitungsverzögerung.

```diff
@@ put_rules, nach VG-04
             l := l || ',' || r('VG-04', 'TRACE_START', 'RG_T',  'PRECEDED_BY', 'RG_A');
+            l := l || ',' || r('VG-05', 'PROCESS_UPDATE', '#P#_VG5', 'PRECEDED_BY_WITHIN_SECS', 'RG_A|1');
@@ Szenario, nach expect VG-04
         expect('_VG', 'VG-04', 1, 'PRECEDED_BY bei TRACE_START');
+
+        -- PRECEDED_BY_WITHIN_SECS bei PROCESS_UPDATE (C4/N1): Bezugszeit ist das Signal, nicht der Prozessstart
+        l_pid := proc('_VG5');
+        lilam.mark_event(l_pid, 'RG_A'); lilam.set_process_status(l_pid, 1);                          -- 0
+        lilam.mark_event(l_pid, 'RG_A'); dbms_session.sleep(1.3); lilam.set_process_status(l_pid, 1); -- 1: zu spaet
+        lilam.close_session(l_pid);
+        expect('_VG5', 'VG-05', 1, 'PRECEDED_BY_WITHIN_SECS bei PROCESS_UPDATE: Abstand zum Signal');
```

- Erwartung: **1** (alter Code: **0**, beide Abstände negativ). Läuft in SERVER und INSESSION; `#P#_VG5` ergibt dort `l_p || '_VG5'` bzw. `l_p || '_IS_VG5'`, passend zu `proc('_VG5')`.
- `PROCESS_START` und `PROCESS_STOP` lösen VG-05 nicht aus (Trigger nur `PROCESS_UPDATE`). Throttle 0 wie die übrigen Regeln.
- Kopfkommentar `FEATURES/REGELN/test_regeln.sql`, Zeile VG: „…, bei Events, TRACE_START und PROCESS_UPDATE (VG-05);“ ergänzen.

## Doku (nur Vorschlag, C1 pflegt die Doku gerade)

- `rules/README.md`, Zeile `PRECEDED_BY_WITHIN_SECS`: inhaltlich richtig. Optional ergänzen: „… ended more than the given seconds before the signal (for process triggers: the status update or the end of the process, not the process start)“.
- `docs/architecture and concepts.md`, Prozess-Matrix (Z. 235): „like `PRECEDED_BY`, plus maximum delay“ ist richtig. Optional „… between predecessor and the signal“.
- Keine Pflichtänderung.
