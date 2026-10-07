# SERVER_NEW_SESSION-Ausfall aus run 2034, Analyse run 2040 und Korrektur run 2041

**Datum:** 07.10.2026, Analyse 13:48:47–13:49:00 Uhr, Korrektur und Nachweis ab 20:31 Uhr
**Anlass:** Dirks Auftrag, den Ausfall der U-Bahn-Simulation im Gesamtlauf (run 2034, Bericht `_COMMON/results/2026-10-07_run2000-2039.md`, Befund 1) gezielt nachzustellen
**LILAM-Stand:** Branch `claude`, HEAD 157615f (Package wie 780150e); Analyse ohne Codeänderung, Korrektur siehe unten
**Skript:** `FEATURES/REGELN/2026-10-07_new_session_ausfall_diag.sql` (Diagnose, kein Autotest). Das Skript enthält inzwischen die Erwartungen **nach** der Korrektur (run 2041); die Tabelle „Belege“ gibt das Ergebnis vor der Korrektur (run 2040) wieder.

## Ergebnis

| Run | Diagnose | Ergebnis | OK | FEHLER | Laufzeit |
|---|---|---|---|---|---|
| 2040 | NEW_SESSION_DIAG, V1–V6, vor der Korrektur | OK (alle Hypothesen-Prüfungen wie erwartet) | 8 | 0 | 12,6 s (Wanduhr 13 s) |
| 2041 | NEW_SESSION_DIAG, V1–V6, nach der Korrektur | OK (siehe „Nachweis nach der Korrektur“) | 10 | 0 | 9,8 s |

**Reproduzierbar: ja, deterministisch.** Ursache ist kein Fehler des neuen Servers, sondern die Dispatcher-Einstellung der Client-Session: Der Test SPEICHER setzt am Ende `lilam.set_dispatcher_pipe('LT_DISP')` für die eigene Session (`lt.t_speicher` → `run_mem(c_dispatcher, 'DP')`, `_COMMON/01_install_testbasis.sql`, Zeile 1806 „zuletzt: setzt den Dispatcher fuer diese Session“) und stoppt `LT_DISP` danach. Die U-Bahn-Simulation lief in derselben Session. `getServerPipeForSession` (`lilam.pkb`, Zeile 931) nimmt bei gesetztem `DEFAULT_DISPATCHER` immer den Dispatcher, auch wenn `SERVER_NEW_SESSION` eine andere Gruppe (`SUBWAY`) nennt. Die Anfragen gingen also an `LT_DISP_CTL` eines gestoppten Dispatchers, nicht an `UB_S1`.

## Belege

| Variante | Ablauf | Ergebnis |
|---|---|---|
| V1 | frischer Server `LT_DGS` (Gruppe `LT_DGY`), sofort `SERVER_NEW_SESSION`, ohne Dispatcher-Einstellung | Erfolg nach 20–30 ms, Server `LT_DGS` |
| V2 | wie run 2034: `set_dispatcher_pipe('LT_DISP')` (gestoppt), 2 × `SERVER_NEW_SESSION` Gruppe `LT_DGY` | beide −20110 nach 3.010 ms, kein Prozess bei `LT_DGS` |
| V2 | Inhalt von `LT_DISP_CTL` danach | 6 ungelesene `NEW_SESSION`: die 2 aus V2 **und die 4 aus run 2034** („Line 1 Normal SERVER“, „Line 1 SERVER“, „Line 1 Train 2 SERVER“, „Line 1 SERVER“; `group_name` SUBWAY, Rückkanal der Session 221) |
| V5 | `set_dispatcher_pipe(NULL)` | hebt die Einstellung nicht auf: `SERVER_NEW_SESSION` liefert sofort −20003 (`NUM_COMM_ERR`; intern −20001 „kein aktiver Server“, weil der Dispatcher-Eintrag leer ist) |
| V3 | nach `dbms_session.modify_package_state(reinitialize)` | `LT_DGS` wieder sofort erreichbar (10–30 ms) |
| V4 | laufender Dispatcher `LT_DGD` der Gruppe `LT_DGX` mit Worker `LT_DGW`; `set_dispatcher_pipe('LT_DGD')`, `SERVER_NEW_SESSION` Gruppe `LT_DGY` | Prozess angelegt, aber bei `LT_DGW` (**fremde Gruppe**, `LILAM_PROC.SERVER_PIPE`) |
| V6 | `set_dispatcher_pipe('LT_DGD', p_groupName => 'LT_DGX')`, `SERVER_NEW_SESSION` Gruppe `LT_DGX` | Client geht direkt an `LT_DGW`, nicht über den Dispatcher: die gruppenbezogene Einstellung wirkt nicht |

`LILAM_LOG_INTERNAL` während run 2040: 2 × −20110 (V2), 1 × −20003 und 1 × −20001 `waitForResponse` (V5); sonst nichts.

Die übrigen Hypothesen sind damit ausgeschlossen: Ein frisch gestarteter Server liest seine Steuer-Pipe sofort (V1, V3), Anfragen wurden nicht als verfallen verworfen (sie erreichten `UB_S1` nie), Reste alter Pipes spielen für den neuen Server keine Rolle (`preparePipe` leert beim Start Daten- und Steuer-Pipe). Die Wiederholungen 2036 und 2038 bestanden, weil sie in einer anderen Datenbank-Session ohne Dispatcher-Einstellung liefen.

## Bewertung

- **Testablauf:** Der Ausfall in 2034 ist ein Folgeeffekt der Testreihenfolge (SPEICHER hinterlässt `DEFAULT_DISPATCHER` in der Session). Run 1995 vom Vormittag lief offenbar in einer Session ohne diese Einstellung (nicht nachgeprüft).
- **Produktion (relevant):** Dasselbe trifft jede Anwendung, die in einer Pool-Session `SET_DISPATCHER_PIPE` aufgerufen hat und später in derselben physischen Session einen Prozess einer anderen Gruppe anlegen will:
  1. Die Gruppe in `SERVER_NEW_SESSION` wird ignoriert; der Prozess landet bei einem Worker der Gruppe des Dispatchers (V4). Er läuft dort mit dem Rule Set und den Baselines der falschen Gruppe.
  2. Ist der Dispatcher gestoppt, scheitert jedes `SERVER_NEW_SESSION` der Session mit 3 s Wartezeit (V2), obwohl Server der gewünschten Gruppe laufen.
  3. Die Einstellung lässt sich nicht zurücknehmen (V5); nur ein Package-Reset hilft.
  4. `p_groupName` von `SET_DISPATCHER_PIPE` wird nur gespeichert, aber nirgends gelesen (V6). Die Doku (API_DE.md, „Optionale Kennung, falls mehrere Dispatcher parallel genutzt werden“) lässt mehr erwarten.

## Vorschlag (Stand 13:49)

1. **Test:** `lt.t_speicher` am Ende die Dispatcher-Einstellung der Session aufheben lassen (z. B. per `dbms_session.modify_package_state` im Skript `test_speicher.sql` nach dem Lauf, oder SPEICHER-DP in einem Job ausführen). Damit wären Gesamtläufe in einer Session unabhängig von der Reihenfolge.
2. **Produkt, klein:** In `getServerPipeForSession` den Dispatcher der angefragten Gruppe nehmen: zuerst `g_dispatcher_config(upper(p_groupName))`, dann `DEFAULT_DISPATCHER`. Damit wirkt `p_groupName` von `SET_DISPATCHER_PIPE` wie dokumentiert.
3. **Produkt, offen zur Entscheidung:** Was gilt, wenn ein `DEFAULT_DISPATCHER` gesetzt ist, `SERVER_NEW_SESSION` aber eine Gruppe nennt, die der Dispatcher nicht bedient? Möglichkeiten: (a) wie bisher den Dispatcher nehmen, aber im Dispatcher nach der Gruppe der Anfrage statt der eigenen Gruppe wählen; (b) den Dispatcher nur für die eigene Gruppe bzw. ohne Gruppenangabe nutzen, sonst die Registry. (b) ist näher an der Doku; (a) erhält das Routing über den Dispatcher.
4. **Produkt, klein:** `SET_DISPATCHER_PIPE(NULL)` als „Einstellung aufheben“ behandeln (`g_dispatcher_config.DELETE`), in der Doku nennen.

## Korrektur (von Dirk am 07.10.2026, 18:28 freigegeben: Variante (b) „Registry“)

1. **`lilam.pkb`, neue Funktion `getDispatcherForGroup`**, aufgerufen von `getServerPipeForSession` vor der Registry-Suche:
   - Ist für die angefragte Gruppe ein Dispatcher gesetzt (`SET_DISPATCHER_PIPE(..., p_groupName => <Gruppe>)`), gilt dieser.
   - Sonst gilt der `DEFAULT_DISPATCHER` nur, wenn keine Gruppe angefragt ist oder seine Gruppe laut `LILAM_SERVER_REGISTRY` der angefragten entspricht (ohne Beachtung von Groß-/Kleinschreibung).
   - Ist die Gruppe des Dispatchers unbekannt (kein Registry-Eintrag), bleibt es beim bisherigen Verhalten (Dispatcher).
   - Andere Gruppen wählen ihren Server wie ohne Dispatcher über die Registry (`getServerPipeAvailable`).
2. **`SET_DISPATCHER_PIPE(NULL)`** löscht den Eintrag der angegebenen Kennung (Standard `DEFAULT_DISPATCHER`).
3. **Test:** `lt.t_speicher` ruft nach dem DISPATCHER-Teil `lilam.set_dispatcher_pipe(null)` auf.
4. **Doku:** `docs/API.md` und `docs/API_DE.md`, Abschnitt `SET_DISPATCHER_PIPE` (Gruppenbezug, `NULL` hebt auf); Kurzkommentar im Spec.

**Warum die Gruppe aus der Registry:** Bestehende Aufrufe übergeben `p_groupName` nicht (auch die Doku-Beispiele, z. B. APEX „Before Header“). Die Registry kennt die Gruppe jedes Dispatchers ohnehin (`CREATE_SERVER`/`START_SERVER`), sie gilt auch für einen gestoppten Dispatcher weiter (Zeile bleibt mit `is_active = 0`), und sie kann nicht durch eine falsche Angabe des Aufrufers verfälscht werden. Die Abfrage läuft nur bei `NEW_SESSION` mit Gruppenangabe und gesetztem Standard-Dispatcher (ein Zugriff über `pipe_name`); weitere Aufrufe eines Prozesses nutzen wie bisher den Pipe-Cache. Die gruppenbezogene Kennung (`p_groupName`) wird zusätzlich ausgewertet, weil die Doku sie für „mehrere Dispatcher parallel“ beschreibt und sie bisher wirkungslos war.

**Nicht geändert:** Der automatische Reconnect (`is_remote`) nutzt weiter nur `DEFAULT_DISPATCHER`; Prozess-IDs sind gruppenübergreifend eindeutig, der Dispatcher findet den Server über `LILAM_PROCESS_ROUTE`.

## Nachweis nach der Korrektur (run 2041)

Diagnoseskript mit den neuen Erwartungen: **10 OK, 0 FEHLER, 9,8 s**.

| Variante | vorher (run 2040) | nachher (run 2041) |
|---|---|---|
| V2 `LT_DISP` gesetzt (gestoppt, Gruppe LT), Gruppe `LT_DGY` | −20110 nach 3 s | direkt `LT_DGS`, 30 ms |
| V2b dieselbe Session, Gruppe LT (Gruppe des Dispatchers) | – | weiter über `LT_DISP`: −20110 nach 3 s, Anfrage in `LT_DISP_CTL` (gewolltes Verhalten bei gestopptem Dispatcher) |
| V5 `set_dispatcher_pipe(NULL)`, dann Gruppe `LT_DGY` | −20003 | `LT_DGS`, 40 ms |
| V4 Dispatcher `LT_DGD` (Gruppe `LT_DGX`), Gruppe `LT_DGY` | Prozess bei `LT_DGW` (fremde Gruppe) | direkt bei `LT_DGS` |
| V4b dieselbe Session, Gruppe `LT_DGX` | – | über `LT_DGD` bei `LT_DGW` |
| V6 Dispatcher nur für Gruppe `LT_DGX` gesetzt | direkt `LT_DGW` (Einstellung wirkungslos) | über `LT_DGD` bei `LT_DGW`; Gruppe `LT_DGY` derselben Session direkt bei `LT_DGS` (V6b) |
| V1, V3 Kontrolle | 20–30 ms | 10–50 ms |

`LILAM_LOG_INTERNAL`: nur der erwartete Timeout aus V2b.

Danach DECOUPLED/DISPATCHER und alle FEATURES, dabei SPEICHER, U-Bahn-Simulation und Grafana-Consumer **in derselben Session nacheinander** wie in run 2034: U-Bahn 17/17 (run 2060), Grafana 7/7 (run 2061). Bericht `_COMMON/results/2026-10-07_run2041-2062.md`.

## Aufräumen

Server `LT_DGS`, `LT_DGW`, `LT_DGD` gestoppt und ihre Registry-Einträge gelöscht (run 2040 und 2041); die ungelesenen Nachrichten in `LT_DISP_CTL` sind entfernt. Keine Scheduler-Jobs, kein aktiver Server, Rule Set `SUBWAY:SUBWAY_PROD` v5 aktiv.
