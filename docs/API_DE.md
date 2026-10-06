# LILAM API-Referenz
### Version: 2.0

---

<details>
<summary>📖 <b>Inhalt</b></summary>

- [Schnellstart](#schnellstart)
  - [In-Session-Modus](#in-session-modus)
  - [Entkoppelter Server-Modus](#entkoppelter-server-modus)
- [Grundkonzepte](#grundkonzepte)
  - [Prozessfortschritt vs. Metriken](#prozessfortschritt-vs-metriken)
  - [Events vs. Traces](#events-vs-traces)
- [Funktionen und Prozeduren](#funktionen-und-prozeduren)
  - [Session-Verwaltung](#session-verwaltung)
  - [Prozesssteuerung](#prozesssteuerung)
  - [Logging](#logging)
  - [Metriken](#metriken)
  - [Serversteuerung](#serversteuerung)
  - [Dispatcher-Modus](#dispatcher-modus)
- [Anhang](#anhang)
  - [Parameterkennzeichnung](#parameterkennzeichnung-1)
  - [Log-Level](#log-level)
  - [Record-Typ t_session_init](#record-typ-t_session_init)
  - [Record-Typ t_process_rec](#record-typ-t_process_rec)
  - [Procedure IS_ALIVE](#procedure-is_alive)
  - [JSON API Interface](#json-api-interface)

</details>

> [!TIP]
> Dieses Dokument dient als LILAM API-Referenz. Wenn Du neu bei LILAM bist, empfiehlt es sich, zunächst [architecture and concepts.md](architecture%20and%20concepts.md) zu lesen, um die zugrunde liegenden Konzepte kennenzulernen. Die Beispiele im Ordner `demo` zeigen, wie sich die LILAM API in Anwendungen integrieren lässt.

---

## Schnellstart

### In-Session-Modus

Verwende den In-Session-Modus, wenn Logging und Monitoring direkt innerhalb der aktuellen Datenbanksession ausgeführt werden sollen.

Das folgende Beispiel initialisiert LILAM, schreibt einen Log-Eintrag und zeichnet zwei Vorkommen eines Events auf. Mit dem Standard-Tabellenpräfix verwendet LILAM diese Tabellen:

- `LILAM_PROC` für Prozessdaten
- `LILAM_LOG` für Log-Einträge
- `LILAM_MON` für Events und Transaktionsmetriken

```sql
DECLARE
  l_processId   NUMBER;
  l_sessionInit lilam.t_session_init;
BEGIN
  -- 1. Configure the session
  l_sessionInit.processName := 'MY_FIRST_SYNC';
  l_sessionInit.logLevel    := lilam.logLevelInfo; -- default: logLevelMonitor

  -- 2. Initialize LILAM
  l_processId := lilam.new_session(
    p_session_init => l_sessionInit
  );

  -- 3. Write a log entry
  lilam.info(
    p_processId => l_processId,
    p_logText   => 'LILAM is up and running!'
  );

  -- 4. Record an event twice
  lilam.mark_event(
    p_processId  => l_processId,
    p_actionName => 'DATA_LOAD'
  );

  dbms_session.sleep(1);

  lilam.mark_event(
    p_processId  => l_processId,
    p_actionName => 'DATA_LOAD'
  );

  -- 5. Finalize the session
  lilam.close_session(l_processId);
END;
/
```

> [!NOTE]
> LILAM verwendet autonome Transaktionen. Logging- und Monitoring-Daten werden daher unabhängig von der Haupttransaktion der aufrufenden Anwendung persistiert. Dies gilt auch dann, wenn die Haupttransaktion zurückgerollt wird.

### Entkoppelter Server-Modus

Verwende den entkoppelten Modus, wenn Clients ihre Logging- und Monitoring-Daten an einen LILAM Server senden sollen.

Ein Server wird über seinen Pipe-Namen identifiziert und kann optional einer Gruppe zugeordnet sein. Ein Client kann sich entweder mit einem beliebigen verfügbaren Server verbinden oder die Serverauswahl auf eine bestimmte Gruppe beschränken.

#### Schritt 1: Server starten

Starte den Server in einer eigenen Datenbanksession. `START_SERVER` blockiert diese Session, solange der Server läuft. Im produktiven Betrieb kann mit `CREATE_SERVER` ein Server über `DBMS_SCHEDULER` gestartet werden.

```sql
BEGIN
  lilam.start_server(
    p_pipeName  => 'MY_FIRST_LILAM_SERVER',
    p_groupName => NULL,
    p_password  => 'SECURE PASSWORD'
  );
END;
/
```

#### Schritt 2: Client ausführen

```sql
DECLARE
  l_processId NUMBER;
BEGIN
  -- Connect to an available server
  l_processId := lilam.server_new_session(
    p_processName => 'DECOUPLED_SYNC',
    p_logLevel    => lilam.logLevelInfo
  );

  lilam.info(
    p_processId => l_processId,
    p_logText   => 'LILAM initialized'
  );

  -- Discrete event
  lilam.mark_event(
    p_processId  => l_processId,
    p_actionName => 'DATA_LOAD'
  );

  -- Timed transaction
  lilam.trace_start(
    p_processId  => l_processId,
    p_actionName => 'NEXT_STATION'
  );

  dbms_session.sleep(1);

  lilam.trace_stop(
    p_processId  => l_processId,
    p_actionName => 'NEXT_STATION'
  );

  lilam.proc_step_done(p_processId => l_processId);

  -- Flush remaining buffered data
  lilam.close_session(l_processId);
END;
/
```

#### Schritt 3: Server herunterfahren

Ein Client muss zunächst eine Verbindung zum Server herstellen. Anschließend kann die zugehörige Server-Pipe mit `GET_SERVER_PIPE` ermittelt und an `SERVER_SHUTDOWN` übergeben werden.

```sql
DECLARE
  l_processId NUMBER;
  l_serverPipe VARCHAR2(100);
BEGIN
  l_processId := lilam.server_new_session(
    p_processName => 'SHUT DOWN SERVER',
    p_logLevel    => lilam.logLevelInfo
  );

  l_serverPipe := lilam.get_server_pipe(l_processId);

  lilam.server_shutdown(
    l_processId,
    l_serverPipe,
    'SECURE PASSWORD'
  );

  lilam.close_session(l_processId);
END;
/
```

---

## Grundkonzepte

### Prozessfortschritt vs. Metriken

> [!IMPORTANT]
> Prozessfortschritt und Metriken sind voneinander unabhängige Konzepte.

Verwende `SET_PROC_STEPS_TODO`, `PROC_STEP_DONE` und `SET_PROC_STEPS_DONE`, um den Gesamtfortschritt eines Prozesses abzubilden.

Verwende `MARK_EVENT`, `TRACE_START` und `TRACE_STOP`, um messbare Aktivitäten innerhalb dieses Prozesses zu erfassen.

Die Anzahl der Prozessschritte muss daher nicht mit der Anzahl der Metric Events oder Traces übereinstimmen.

### Events vs. Traces

Als einfache Faustregel gilt:

- **Etwas ist passiert:** Verwende `MARK_EVENT`.
- **Etwas beginnt und endet später:** Verwende `TRACE_START` und `TRACE_STOP`.

Eine Metrik wird durch die Kombination aus `p_actionName` und `p_contextName` identifiziert.

Wird ein Trace mit einem Context gestartet, muss er mit derselben Kombination aus Action und Context beendet werden.

---

## Funktionen und Prozeduren

### Parameterkennzeichnung

Für Parameter werden folgende Kennzeichnungen verwendet:

- **M**: Mandatory
- **O**: Optional
- **N**: Nullable
- **D**: Default value

Diese Begriffe bleiben bewusst in Englisch, da sie sich unmittelbar auf die API-Definition beziehen.

---

## Session-Verwaltung

Die Session-Verwaltung steuert den Lebenszyklus eines LILAM Prozesses.

| API | Zweck |
| --- | --- |
| `NEW_SESSION` | Startet einen LILAM Prozess im In-Session-Modus |
| `SERVER_NEW_SESSION` | Startet einen Prozess mit Verbindung zu einem LILAM Server |
| `CLOSE_SESSION` | Beendet einen Prozess und schreibt gepufferte Daten |
| `FLUSH` | Schreibt alle gepufferten Daten der Datenbanksession sofort; die Prozesse bleiben offen |

### Function NEW_SESSION / SERVER_NEW_SESSION

Beide Funktionen starten einen LILAM Prozess und liefern dessen Process ID zurück. Diese ID wird für alle nachfolgenden API-Aufrufe benötigt.

- `NEW_SESSION` startet den Prozess im In-Session-Modus.
- `SERVER_NEW_SESSION` startet den Prozess im entkoppelten Modus über einen LILAM Server. Die Parameter sind dieselben; `p_groupName` steht hier an zweiter Stelle, bei `NEW_SESSION` an letzter.
- Alternativ lassen sich alle Einstellungen in einem Record [`t_session_init`](#record-typ-t_session_init) zusammenfassen (nur `NEW_SESSION`).

Jeder Parameter steht immer an derselben Position. Alle Parameter außer `p_processName` besitzen einen Default und können daher weggelassen oder per Namen übergeben werden.

```sql
FUNCTION NEW_SESSION(
  p_processName   VARCHAR2,
  p_logLevel      PLS_INTEGER DEFAULT logLevelMonitor,
  p_procStepsToDo PLS_INTEGER DEFAULT NULL,
  p_daysToKeep    PLS_INTEGER DEFAULT NULL,
  p_tabNameMaster VARCHAR2    DEFAULT 'LILAM',
  p_baselineScope VARCHAR2    DEFAULT NULL,
  p_groupName     VARCHAR2    DEFAULT NULL,
  p_syncLevel     PLS_INTEGER DEFAULT logLevelError
) RETURN NUMBER
```

```sql
FUNCTION NEW_SESSION(
  p_session_init t_session_init
) RETURN NUMBER
```

```sql
FUNCTION SERVER_NEW_SESSION(
  p_processName   VARCHAR2,
  p_groupName     VARCHAR2    DEFAULT NULL,
  p_logLevel      PLS_INTEGER DEFAULT logLevelMonitor,
  p_procStepsToDo PLS_INTEGER DEFAULT NULL,
  p_daysToKeep    PLS_INTEGER DEFAULT NULL,
  p_tabNameMaster VARCHAR2    DEFAULT 'LILAM',
  p_baselineScope VARCHAR2    DEFAULT NULL,
  p_syncLevel     PLS_INTEGER DEFAULT logLevelError
) RETURN NUMBER
```

```sql
FUNCTION SERVER_NEW_SESSION_JSON(
  p_jsonObject VARCHAR2
) RETURN NUMBER
```

`SERVER_NEW_SESSION_JSON` nimmt dieselben Parameter als JSON-Objekt entgegen (Schlüssel siehe Tabelle).

#### Parameter

| Parameter | JSON | Default | Beschreibung |
| --- | --- | --- | --- |
| `p_processName` | `process_name` | – | Name zur Identifikation des Prozesses |
| `p_groupName` | `group_name` | `NULL` | `SERVER_NEW_SESSION`: beschränkt die Serverauswahl auf die angegebene Gruppe; `NULL` = beliebiger verfügbarer Server. `NEW_SESSION`: Der Prozess nutzt das aktive Rule Set dieser Gruppe aus `LILAM_RULES` (siehe [Regeln im INSESSION-Modus](#regeln-im-insession-modus)); `NULL` = keine Regeln |
| `p_logLevel` | `log_level` | `logLevelMonitor` | Detaillierungsgrad des Loggings, siehe [Log-Level](#log-level) |
| `p_procStepsToDo` | `steps_todo` | `NULL` | Geplante Anzahl der Prozessschritte |
| `p_daysToKeep` | `days_to_keep` | `NULL` | `NULL` = keine automatische Bereinigung. Sonst werden beim Start abgeschlossene Prozesse gleichen Namens, die älter als die angegebene Anzahl Tage sind, samt Logs und Metriken gelöscht (außer Prozesse mit `procImmortal = 1`) |
| `p_tabNameMaster` | `tabname_master` | `'LILAM'` | Präfix für die PROC-, LOG- und MON-Tabellen |
| `p_baselineScope` | `baseline_scope` | `NULL` | Bezugsrahmen für die Durchschnittswerte (EWMA) von Traces und Events: `NULL` = Prozessname, d.h. gemeinsam über alle Prozesse mit diesem Namen; `'#NONE'` = nur innerhalb des einzelnen Prozesses; sonst ein frei gewählter Name, der auch von mehreren Anwendungen geteilt werden kann |
| `p_syncLevel` | `sync_level` | `logLevelError` | Einträge bis zu diesem Level werden synchron geschrieben, alle anderen gepuffert. `logLevelWarn` macht auch `WARN` synchron, `logLevelSilent` schaltet das synchrone Schreiben ganz ab. Siehe [Synchrones Schreiben](#synchrones-schreiben-p_synclevel) |

**Rückgabewert:** `NUMBER`, die Process ID.

Kann `SERVER_NEW_SESSION` keinen Prozess anlegen, wirft die Funktion **keine Exception**, sondern liefert einen negativen Wert. Alle weiteren API-Aufrufe mit dieser ID werden ohne Fehler ignoriert; die Anwendung läuft weiter, nur ohne Logging und Monitoring für diesen Prozess. Die Ursache wird in `LILAM_LOG_INTERNAL` protokolliert.

| Konstante | Wert | Bedeutung |
| --- | --- | --- |
| `NUM_ERR_SESSION_TIMEOUT` | -20110 | Der Server hat nicht rechtzeitig geantwortet |
| `NUM_ERR_SESSION_THROTTLED` | -20120 | Der Server hat die Anfrage abgelehnt (Überlast) |
| `NUM_COMM_ERR` | -20003 | Kommunikationsfehler, z.B. kein aktiver Server gefunden |

```sql
l_processId := lilam.server_new_session('IMPORT_CUSTOMERS', 'BATCH');
if l_processId < 0 then
  -- optional: eigene Reaktion, z.B. Hinweis an den Betrieb
  null;   -- l_processId = lilam.NUM_ERR_SESSION_TIMEOUT, ...
end if;
```

> [!NOTE]
> Wartet der Client vergeblich auf die Antwort, legt der Server den Prozess auch später nicht mehr an. Der Client gibt dazu eine Verfallszeit mit; trifft die Anfrage erst danach beim Server ein, wird sie verworfen. So entstehen keine verwaisten, nie geschlossenen Prozesse.

> [!NOTE]
> Durch den Baseline-Scope baut auch eine Anwendung, die häufig neu gestartet wird, eine stabile Vergleichsbasis für ihre Laufzeiten auf. Die Durchschnittswerte werden in den Tabellen `LILAM_SCOPES` und `LILAM_BASELINES` gespeichert.
> Den Ablauf (Auflösung des Scopes, Laden und Abgleich mit `LILAM_BASELINES`) zeigt ein Diagramm in [architecture and concepts.md](architecture%20and%20concepts.md#baseline-scope).

#### Beispiele

```sql
-- nur der Name, alle übrigen Werte per Default
l_processId := lilam.new_session('IMPORT_CUSTOMERS');

-- Log-Level INFO und 500 geplante Schritte
l_processId := lilam.new_session('IMPORT_CUSTOMERS', lilam.logLevelInfo, 500);

-- einzelne Parameter per Namen
l_processId := lilam.new_session('IMPORT_CUSTOMERS', p_daysToKeep => 30);
l_processId := lilam.new_session('IMPORT_CUSTOMERS', p_baselineScope => '#NONE');

-- In-Session mit den Regeln der Gruppe BATCH
l_processId := lilam.new_session('IMPORT_CUSTOMERS', p_groupName => 'BATCH');

-- auch WARN sofort und dauerhaft schreiben
l_processId := lilam.new_session('IMPORT_CUSTOMERS', p_syncLevel => lilam.logLevelWarn);

-- entkoppelt: beliebiger verfügbarer Server bzw. Server der Gruppe BATCH
l_processId := lilam.server_new_session('IMPORT_CUSTOMERS');
l_processId := lilam.server_new_session('IMPORT_CUSTOMERS', 'BATCH', lilam.logLevelInfo);
```

### Procedure CLOSE_SESSION

Beendet einen LILAM Prozess. Optional können abschließende Prozessinformationen, Status und Fortschritt übergeben werden.

> [!IMPORTANT]
> Rufe `CLOSE_SESSION` immer auf, wenn ein Prozess endet. LILAM puffert Daten aus Performancegründen. `CLOSE_SESSION` stellt sicher, dass noch vorhandene gepufferte Daten persistiert werden.
>
> Daher sollte `CLOSE_SESSION` auch Bestandteil der abschließenden Exception-Behandlung sein. Soll der Prozess nach der Exception weiterlaufen (z. B. eine AJAX-Seite arbeitet weiter), verwende stattdessen [`FLUSH`](#procedure-flush).

```sql
PROCEDURE CLOSE_SESSION(
  p_processId     NUMBER,
  p_processInfo   VARCHAR2    DEFAULT NULL,
  p_processStatus PLS_INTEGER DEFAULT NULL,
  p_procStepsDone PLS_INTEGER DEFAULT NULL,
  p_procStepsToDo PLS_INTEGER DEFAULT NULL
)
```

| Parameter | Beschreibung |
| --- | --- |
| `p_processId` | Process ID aus `NEW_SESSION` bzw. `SERVER_NEW_SESSION` |
| `p_processInfo` | Abschließende Information zum Prozess |
| `p_processStatus` | Abschließender Status |
| `p_procStepsDone` | Anzahl erledigter Schritte |
| `p_procStepsToDo` | Anzahl geplanter Schritte |

Parameter, die `NULL` bleiben, verändern den bisherigen Wert des Prozesses nicht.

```sql
lilam.close_session(l_processId);
lilam.close_session(l_processId, 'Import abgeschlossen', 1);
lilam.close_session(l_processId, 'Import abgeschlossen', 1, 500);
```

Beispiel für die Exception-Behandlung:

```sql
EXCEPTION
  WHEN OTHERS THEN
    lilam.close_session(
      p_processId     => l_proc_id,
      p_processInfo   => SQLERRM,
      p_processStatus => -1
    );
    RAISE;
```

### Procedure FLUSH

LILAM puffert Logging-, Monitoring- und Prozessdaten aus Performancegründen und schreibt sie zeitgesteuert (siehe [Wann werden Metriken und Prozessdaten geschrieben?](#wann-werden-metriken-und-prozessdaten-geschrieben)).

`FLUSH` schreibt sofort alle gepufferten Daten aller offenen Prozesse der aktuellen Datenbanksession, auch Baselines. Anders als `CLOSE_SESSION` beendet `FLUSH` keinen Prozess: Die Prozesse bleiben offen, offene Traces laufen weiter, und Zähler und Durchschnitte zählen weiter.

```sql
PROCEDURE FLUSH
```

Typische Einsätze:

- Exception-Handler, wenn der Prozess danach weiterlaufen soll (z. B. eine AJAX-Seite arbeitet weiter). Endet der Prozess, verwende `CLOSE_SESSION`.
- Ein langer In-Session-Prozess soll vor einer längeren Pause ohne LILAM-Aufrufe sofort von außen sichtbar sein.

```sql
BEGIN
  lilam.flush;
END;
/
```

> [!IMPORTANT]
> `FLUSH` wirkt nur auf die Datenbanksession, aus der es aufgerufen wird. Für Prozesse im entkoppelten Modus (Server, Dispatcher) ist `FLUSH` wirkungslos: Deren Puffer liegen beim LILAM-Server, der sie selbst zeitgesteuert schreibt.
>
> Ein `FLUSH` kostet einen Commit (auf dem Testsystem etwa 1,5 bis 3,5 ms).

---

## Prozesssteuerung

Die APIs zur Prozesssteuerung verwalten den Gesamtfortschritt und Status eines Prozesses.

| API | Zweck |
| --- | --- |
| `SET_PROCESS_STATUS` | Aktualisiert Prozessstatus und optionale Prozessinformation |
| `SET_PROC_STEPS_TODO` | Setzt die geplante Anzahl der Prozessschritte |
| `PROC_STEP_DONE` | Erhöht die Anzahl abgeschlossener Prozessschritte |
| `SET_PROC_STEPS_DONE` | Setzt die Anzahl abgeschlossener Prozessschritte explizit |
| `GET_PROC_STEPS_DONE` | Liefert die Anzahl abgeschlossener Prozessschritte |
| `GET_PROC_STEPS_TODO` | Liefert die geplante Anzahl der Prozessschritte |
| `GET_PROCESS_START` | Liefert die Startzeit des Prozesses |
| `GET_PROCESS_END` | Liefert die Endzeit des Prozesses |
| `GET_PROCESS_STATUS` | Liefert den Prozessstatus |
| `GET_PROCESS_INFO` | Liefert die Prozessinformation |
| `SET_PROC_IMMORTAL` | Schützt einen Prozess vor der automatischen Bereinigung |
| `GET_PROCESS_DATA` | Liefert sämtliche Prozessdaten in einem Record |
| `GET_PROCESS_DATA_JSON` | Liefert sämtliche Prozessdaten als JSON |

> [!NOTE]
> Bei Änderungen an Prozessdaten wird der Wert `lastUpdate` des Prozessdatensatzes implizit aktualisiert.
>
> Prozessdaten werden gepuffert und zeitgesteuert geschrieben, siehe [Wann werden Metriken und Prozessdaten geschrieben?](#wann-werden-metriken-und-prozessdaten-geschrieben).

### Procedure SET_PROCESS_STATUS

Aktualisiert den anwendungsspezifischen numerischen Prozessstatus und optional eine Prozessinformation.

Die Bedeutung des Statuswertes wird nicht von LILAM vorgegeben, sondern von der aufrufenden Anwendung bestimmt.

```sql
PROCEDURE SET_PROCESS_STATUS(
  p_processId   NUMBER,
  p_status      PLS_INTEGER,
  p_processInfo VARCHAR2 DEFAULT NULL
)
```

### Procedure SET_PROC_STEPS_TODO

Setzt die geplante Anzahl von Schritten für den Gesamtprozess.

```sql
PROCEDURE SET_PROC_STEPS_TODO(
  p_processId     NUMBER,
  p_procStepsToDo NUMBER
)
```

### Procedure PROC_STEP_DONE

Erhöht die Anzahl der abgeschlossenen Prozessschritte.

```sql
PROCEDURE PROC_STEP_DONE(
  p_processId NUMBER
)
```

### Procedure SET_PROC_STEPS_DONE

Setzt die Anzahl der abgeschlossenen Prozessschritte explizit.

Ein Aufruf überschreibt einen zuvor mit `PROC_STEP_DONE` aufgebauten Fortschrittswert.

```sql
PROCEDURE SET_PROC_STEPS_DONE(
  p_processId     NUMBER,
  p_procStepsDone NUMBER
)
```

### Procedure SET_PROC_IMMORTAL

Kennzeichnet einen Prozess als dauerhaft aufzubewahren (`1`) oder hebt die Kennzeichnung auf (`0`). Prozesse mit `procImmortal = 1` werden bei der automatischen Bereinigung über `p_daysToKeep` nicht gelöscht. Beim Start lässt sich der Wert auch über `t_session_init.procImmortal` setzen.

```sql
PROCEDURE SET_PROC_IMMORTAL(
  p_processId NUMBER,
  p_immortal  NUMBER
)
```

### Function GET_PROC_STEPS_DONE

```sql
FUNCTION GET_PROC_STEPS_DONE(
  p_processId NUMBER
) RETURN PLS_INTEGER
```

Liefert die Anzahl der bereits abgeschlossenen Prozessschritte.

### Function GET_PROC_STEPS_TODO

```sql
FUNCTION GET_PROC_STEPS_TODO(
  p_processId NUMBER
) RETURN PLS_INTEGER
```

Liefert die geplante Anzahl der Prozessschritte.

### Function GET_PROCESS_START

```sql
FUNCTION GET_PROCESS_START(
  p_processId NUMBER
) RETURN TIMESTAMP
```

Liefert den Zeitpunkt, zu dem der Prozess durch `NEW_SESSION` oder `SERVER_NEW_SESSION` gestartet wurde.

### Function GET_PROCESS_END

```sql
FUNCTION GET_PROCESS_END(
  p_processId NUMBER
) RETURN TIMESTAMP
```

Liefert den Zeitpunkt, zu dem der Prozess durch `CLOSE_SESSION` beendet wurde.

### Function GET_PROCESS_STATUS

```sql
FUNCTION GET_PROCESS_STATUS(
  p_processId NUMBER
) RETURN PLS_INTEGER
```

Liefert den aktuellen anwendungsspezifischen numerischen Prozessstatus.

### Function GET_PROCESS_INFO

```sql
FUNCTION GET_PROCESS_INFO(
  p_processId NUMBER
) RETURN VARCHAR2
```

Liefert den beim Prozess gespeicherten Informationstext.

### Function GET_PROCESS_DATA
Verwende diese Funktion, wenn mehrere Eigenschaften eines Prozesses gleichzeitig benötigt werden.

Dadurch werden mehrere einzelne Getter-Aufrufe vermieden. Die Funktion liefert einen vollständigen `t_process_rec` Record.

```sql
FUNCTION GET_PROCESS_DATA(
  p_processId NUMBER
) RETURN t_process_rec
```

> [!NOTE]
> `GET_PROCESS_DATA` ist außerdem die dokumentierte Möglichkeit, den Process Name und `tabNameMaster` gemeinsam mit den übrigen Prozessattributen abzurufen.
>
> Der Name der Prozesstabelle wird aus dem Master-Tabellennamen gebildet, indem `_PROC` angehängt wird.

### Function GET_PROCESS_DATA_JSON

Liefert dieselben Daten wie `GET_PROCESS_DATA` als JSON-Objekt mit den Schlüsseln `process_id`, `process_name`, `log_level`, `process_start`, `process_end`, `last_update`, `process_info`, `process_status`, `steps_todo`, `steps_done` und `tabname_master`.

```sql
FUNCTION GET_PROCESS_DATA_JSON(
  p_processId NUMBER
) RETURN VARCHAR2
```

---

## Logging
Die Logging APIs schreiben Meldungen entsprechend dem aktiven Log-Level in das LILAM Log.

| API | Severity |
| --- | --- |
| `ERROR` | ERROR |
| `WARN` | WARN |
| `INFO` | INFO |
| `DEBUG` | DEBUG |

Alle Logging-Prozeduren folgen demselben Signaturmuster:

```sql
PROCEDURE ERROR(
  p_processId NUMBER,
  p_logText   VARCHAR2
)

PROCEDURE WARN(
  p_processId NUMBER,
  p_logText   VARCHAR2
)

PROCEDURE INFO(
  p_processId NUMBER,
  p_logText   VARCHAR2
)

PROCEDURE DEBUG(
  p_processId NUMBER,
  p_logText   VARCHAR2
)
```

- `p_processId` identifiziert den Prozess.
- `p_logText` enthält die Meldung. Längere Texte werden auf 1.900 Zeichen gekürzt (bei Mehrbyte-Zeichen wie Umlauten ggf. weniger, maximal 2.000 Bytes).

`ERROR` besitzt die höchste Priorität und wird immer gespeichert, sofern das Logging nicht vollständig mit `logLevelSilent` deaktiviert wurde.

Wann ein Eintrag tatsächlich in der Tabelle steht, beschreibt [Synchrones Schreiben](#synchrones-schreiben-p_synclevel).

Interne Fehler behandelt LILAM grundsätzlich still und protokolliert sie in `LILAM_LOG_INTERNAL`; die Anwendung erhält keine Exception. Ist `logLevelDebug` aktiv, schreibt LILAM solche Fehler zusätzlich als `ERROR` in das Log des betroffenen Prozesses.

Die vollständige Zuordnung findest Du unter [Log-Level](#log-level).

### Synchrones Schreiben (p_syncLevel)

LILAM puffert Log-Einträge aus Performancegründen. Einträge bis zum **Sync-Level** des Prozesses werden dagegen sofort und dauerhaft geschrieben. Der Sync-Level wird mit `p_syncLevel` beim Start des Prozesses festgelegt; Standard ist `logLevelError`.

| Modus | Einträge bis zum Sync-Level | Alle anderen Einträge |
| --- | --- | --- |
| In-Session | werden in einer autonomen Transaktion committet, bevor der Aufruf zurückkehrt. Dabei schreibt LILAM auch alle anderen gepufferten Daten der Datenbanksession weg. | bleiben bis zu etwa 1,5 Sekunden im Puffer, länger, wenn die Session LILAM nicht mehr aufruft (Log-Aufrufe, `MARK_EVENT`, `TRACE_STOP` und die Prozesssteuerung stoßen die Rückschreibung an, siehe [Wann werden Metriken und Prozessdaten geschrieben?](#wann-werden-metriken-und-prozessdaten-geschrieben)) |
| Entkoppelt | gehen wie gewohnt an den Server und werden dort in die Arbeitstabelle geschrieben. Als **doppelter Boden** schreibt der Client sie zusätzlich selbst in einer autonomen Transaktion, bevor der Aufruf zurückkehrt, und zwar immer in **`LILAM_LOG`** im Schema des Clients (wird bei Bedarf angelegt), mit der Prozess-ID und dem Wert `-1` in der Spalte `NO`. | gehen per Pipe an den Server und werden dort gepuffert |

Ein synchron geschriebener Eintrag übersteht damit auch einen Abbruch der Session und im entkoppelten Modus den Ausfall des LILAM-Servers. Gepufferte Einträge sind verloren, wenn eine Session ohne `CLOSE_SESSION` oder `FLUSH` endet. Rufe `CLOSE_SESSION` deshalb im zentralen Exception-Handler auf, oder `FLUSH`, wenn der Prozess weiterlaufen soll.

> [!NOTE]
> Im entkoppelten Modus stehen synchrone Einträge normalerweise zweimal in der Datenbank: in der Arbeitstabelle (vom Server geschrieben) und in `LILAM_LOG` im Schema des Clients (`NO = -1`). Fällt der LILAM-Server aus, findet man den Eintrag weiterhin in `LILAM_LOG`. `LILAM_LOG` wird verwendet, weil die Arbeitstabelle im Schema des Servers liegen kann, auf das der Client keinen Zugriff hat.

Ein synchroner Aufruf kostet auf dem Testsystem etwa 1,5 bis 3,5 ms statt rund 0,1 ms, vor allem für den Commit. Details, Messwerte und Ausfallszenarien stehen in [Architecture and Concepts](architecture%20and%20concepts.md#when-is-a-log-entry-stored-sync-level).

### Function GET_COUNTER_WARN / GET_COUNTER_ERROR

```sql
FUNCTION GET_COUNTER_WARN(
  p_processId NUMBER
) RETURN PLS_INTEGER

FUNCTION GET_COUNTER_ERROR(
  p_processId NUMBER
) RETURN PLS_INTEGER
```

Liefern die Anzahl der Aufrufe von `WARN` bzw. `ERROR` für den Prozess, seit er gestartet wurde.

> [!NOTE]
> Gezählt wird in der Datenbanksession, die `WARN` bzw. `ERROR` aufruft (im entkoppelten Modus also beim Client). Für unbekannte oder bereits geschlossene Prozesse liefern beide Funktionen 0.

---

## Metriken

Metriken erfassen Events und logische Transaktionen innerhalb eines Prozesses.

> [!IMPORTANT]
> `p_actionName` und `p_contextName` bilden gemeinsam die Identifikation einer Metrik.
>
> Ein mit einem Context gestarteter Trace muss mit derselben Kombination aus Action und Context beendet werden.

### Wann werden Metriken und Prozessdaten geschrieben?

Auch Metriken und Prozessdaten (Status, Fortschritt) puffert LILAM. Im In-Session-Modus stoßen `MARK_EVENT`, `TRACE_STOP` und die Prozeduren der [Prozesssteuerung](#prozesssteuerung) (`SET_PROCESS_STATUS`, `SET_PROC_STEPS_TODO`, `SET_PROC_STEPS_DONE`, `PROC_STEP_DONE`, `SET_PROC_IMMORTAL`) – wie jeder Log-Aufruf – die zeitgesteuerte Rückschreibung an: Daten eines Prozesses, die älter als etwa 1,5 Sekunden sind, werden weggeschrieben, prozessübergreifende Baselines (`LILAM_BASELINES`) ebenfalls im Abstand von etwa 1,5 Sekunden. Zwischen zwei Prüfläufen derselben Datenbanksession liegen mindestens 500 ms, sodass ein einzelner Aufruf meist nur einen Zeitvergleich kostet. `TRACE_START` stößt keine Rückschreibung an. Damit landen auch bei reinen Monitoring-Anwendungen, die nie loggen, Messwerte und Fortschritt zeitnah in der Datenbank. Abfragen über die API (z. B. `GET_PROC_STEPS_DONE`) in derselben Session lesen ohnehin den aktuellen Stand aus dem Puffer. Mit [`FLUSH`](#procedure-flush) schreibst Du den Puffer sofort, ohne den Prozess zu beenden.

> [!IMPORTANT]
> Im In-Session-Modus gibt es keinen Timer. Geschrieben wird nur, wenn die Session LILAM aufruft. Was nach dem letzten Aufruf noch im Puffer liegt, bleibt dort, bis die Session LILAM erneut aufruft. **Garantiert geschrieben wird nur mit `CLOSE_SESSION` (Prozess endet) oder `FLUSH` (Prozess bleibt offen).**
>
> **AJAX und Connection-Pool (z. B. APEX/ORDS):** Ein In-Session-Prozess lebt nur in der Datenbanksession, die `NEW_SESSION` aufgerufen hat. Der nächste Request läuft im Pool meist in einer anderen Session; dort ist die Prozess-ID unbekannt, und LILAM ignoriert die Aufrufe still. Ein `CLOSE_SESSION` auf einer abschließenden Seite erreicht den Prozess dann nicht, und dessen Puffer bleibt in der ursprünglichen Pool-Session liegen.
>
> - **Ein Prozess je Request:** `NEW_SESSION` am Anfang und `CLOSE_SESSION` am Ende desselben Requests. Dann funktioniert der In-Session-Modus auch im Connection-Pool.
> - **Prozesse über mehrere Requests** (z. B. AJAX-Seiten, die nur tracen oder Fortschritt melden, während erst eine abschließende Seite `CLOSE_SESSION` aufruft): nur mit dem [entkoppelten Server-Modus](#entkoppelter-server-modus) zusammen mit dem [Dispatcher](#dispatcher-modus).

### Procedure MARK_EVENT

Verwende `MARK_EVENT` für ein einzelnes Ereignis zu einem bestimmten Zeitpunkt innerhalb des Prozessablaufs.

Bei wiederholten Markern mit derselben Action und demselben Context verfolgt LILAM Zeitabstand, Anzahl der Vorkommen, durchschnittliche Dauer und signifikante zeitliche Abweichungen.

```sql
PROCEDURE MARK_EVENT(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL,
  p_timestamp   TIMESTAMP DEFAULT NULL
)
```

### Procedure TRACE_START

Startet eine zeitlich messbare logische Transaktion.

```sql
PROCEDURE TRACE_START(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL,
  p_timestamp   TIMESTAMP DEFAULT NULL
)
```

### Procedure TRACE_STOP

Beendet die zugehörige logische Transaktion.

```sql
PROCEDURE TRACE_STOP(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL,
  p_timestamp   TIMESTAMP DEFAULT NULL
)
```

> [!IMPORTANT]
> Beim Beenden der Session werden offene Traces überprüft. Ein nicht abgeschlossener Trace wird als Warnung protokolliert.
>
> Rufe `CLOSE_SESSION` daher auch in der abschließenden Exception-Behandlung auf, damit diese Überprüfung stattfinden kann.

### Function GET_METRIC_AVG_DURATION

Liefert die durchschnittliche Dauer für die angegebene Metrik.

```sql
FUNCTION GET_METRIC_AVG_DURATION(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL
) RETURN NUMBER
```

### Function GET_METRIC_STEPS
Liefert die Anzahl der Vorkommen der angegebenen Metrik.

```sql
FUNCTION GET_METRIC_STEPS(
  p_processId   NUMBER,
  p_actionName  VARCHAR2,
  p_contextName VARCHAR2 DEFAULT NULL
) RETURN NUMBER
```

---

## Serversteuerung
Im entkoppelten Modus empfängt ein LILAM Server Client-Anfragen und übernimmt Logging und Monitoring zentral.

Server werden durch ihre Pipe-Namen identifiziert und können optional Gruppen zugeordnet werden.

> [!IMPORTANT]
> Server-Pipe-Namen müssen innerhalb der Datenbankinstanz eindeutig sein. Jeder Server legt zusätzlich eine Steuer-Pipe mit der Endung `_CTL` an (z.B. `LILAM_SRV1_CTL` zu `LILAM_SRV1`); auch diese Namen dürfen nicht anderweitig verwendet werden.

Ein Server nutzt zwei Pipes:

- **Daten-Pipe** (`<Pipe-Name>`): alle Logs, Traces, Events, Status und Abfragen in der Reihenfolge ihres Eintreffens.
- **Steuer-Pipe** (`<Pipe-Name>_CTL`): nur das Anlegen neuer Prozesse (`SERVER_NEW_SESSION`). Der Server fragt sie vor jeder Datennachricht ab, ohne zu warten. Dadurch muss das Anlegen eines Prozesses auch unter hoher Last nicht hinter den Nachrichten anderer Anwendungen warten. Ein kurzer Weckruf in die Daten-Pipe sorgt dafür, dass auch ein untätiger Server die Anfrage sofort bemerkt.

**Serverauswahl:** Ein Client ohne Dispatcher und ein Dispatcher wählen für jeden neuen Prozess einen Server der Gruppe nach diesen Kriterien:

1. wenigste offene Prozesse (`CURRENT_PROCESSES`; der Server aktualisiert den Wert direkt nach jedem neuen und jedem geschlossenen Prozess),
2. niedrigste Nachrichtenrate (Nachrichten je Sekunde im letzten Housekeeping-Fenster, in Stufen zu 100 Nachrichten/s; ein Wert, der älter als 1,5 s ist, zählt als 0),
3. der am längsten nicht aktive Server.

Sind die ersten beiden Kriterien gleich, wechselt der Aufrufer zwischen den Servern ab (Round Robin je Datenbanksession). So verteilen sich auch schnell nacheinander angelegte Prozesse gleichmäßig. Dispatcher werden nie gewählt.

**Server-Loop und Eco-Modus:** Nach einer Nachricht prüft der Server die Pipe einmal ohne zu warten. Ist sie leer, wartet er 1 s, dann 2 s, dann jeweils 5 s; eine eintreffende Nachricht weckt ihn sofort. `DBMS_PIPE` kennt nur ganze Sekunden, daher die ganzzahligen Stufen. Housekeeping (Registry mit Nachrichtenrate, Schreiben der Puffer) läuft alle 500 ms, auch während der Server arbeitet; im Leerlauf beim nächsten Aufwachen. Ist die Pipe leer und hält ein Worker noch ungeschriebene Logs, Metriken oder Prozessdaten, schreibt er sie sofort (Leerlauf-Flush, höchstens alle 200 ms; nie auf einem Dispatcher). Nach einer Pause stehen neue Einträge dadurch meist nach wenigen bis einigen hundert Millisekunden in der Tabelle.

| API | Zweck |
| --- | --- |
| `START_SERVER` | Startet einen LILAM Server in der aktuellen Session |
| `CREATE_SERVER` | Startet einen LILAM Server über `DBMS_SCHEDULER` |
| `SERVER_SHUTDOWN` | Beendet einen Server |
| `GET_SERVER_PIPE` | Liefert die Server-Pipe eines verbundenen Clients |
| `SERVER_UPDATE_RULES` | Aktiviert ein aktualisiertes Rule Set |
| `SET_DISPATCHER_PIPE` | Konfiguriert einen Dispatcher für automatisches Routing und Reconnect |

### Procedure START_SERVER
Startet einen LILAM Server.

Das Passwort muss beim späteren Herunterfahren des Servers erneut angegeben werden.

```sql
PROCEDURE START_SERVER(
  p_pipeName     VARCHAR2,
  p_groupName    VARCHAR2,
  p_password     VARCHAR2,
  p_isDispatcher PLS_INTEGER DEFAULT 0,
  p_perfServer   PLS_INTEGER DEFAULT NULL
)
```

#### Parameter
| Parameter | Typ | Bedeutung |
| --------- | --- | --------- |
| p_pipeName | varchar2 | Eindeutiger Pipe-Name des Servers |
| p_groupName | varchar2 | Optionale Gruppe für die Serverauswahl |
| p_password | varchar2 | Passwort, das für SERVER_SHUTDOWN erneut benötigt wird |
| p_isDispatcher | pls_integer | 1 startet den Server im Dispatcher-Modus (siehe Dispatcher-Modus), 0 (Standard) startet einen regulären Server |
| p_perfServer | pls_integer | Leistungsstufe des Servers, siehe [Leistungsstufe](#leistungsstufe-p_perfserver). `NULL` (Standard) = `C_SERVER_PERF_MID` |

#### Leistungsstufe (p_perfServer)
Damit ein Client den Server nicht mit Nachrichten überflutet, stimmt er sich nach einer bestimmten Anzahl Nachrichten je Prozess und Sekunde kurz mit dem Server ab und wartet, bis dieser aufgeholt hat. Diese Grenze legt `p_perfServer` fest. Der Server teilt sie dem Client bei `SERVER_NEW_SESSION` (und beim automatischen Reconnect) mit; in der Anwendung ist dafür kein eigener Aufruf nötig.

| Konstante | Wert | Einsatz |
| --- | --- | --- |
| `C_SERVER_PERF_LOW` | 500 | leistungsschwächere Umgebungen |
| `C_SERVER_PERF_MID` | 1500 | Standard; übliche Server |
| `C_SERVER_PERF_HIGH` | 2500 | leistungsstarke Server |

Beliebige andere Werte sind möglich. `0` schaltet die Abstimmung ab; `NULL` oder negative Werte gelten als `C_SERVER_PERF_MID`.

> [!NOTE]
> Die Grenze gilt je Prozess. Senden viele Anwendungen gleichzeitig an denselben Server, ist dessen Gesamtdurchsatz geringer als die Summe der Einzelwerte; dann eher `C_SERVER_PERF_LOW` oder `C_SERVER_PERF_MID` wählen oder weitere Server derselben Gruppe starten.

### Function CREATE_SERVER
Startet einen LILAM Server über `DBMS_SCHEDULER` und liefert Serverinformationen als `VARCHAR2` zurück.

```sql
FUNCTION CREATE_SERVER(
  p_pipeName     VARCHAR2,
  p_groupName    VARCHAR2,
  p_password     VARCHAR2,
  p_isDispatcher PLS_INTEGER DEFAULT 0,
  p_perfServer   PLS_INTEGER DEFAULT NULL
) RETURN VARCHAR2
```
Parameter identisch zu START_SERVER.

```sql
-- Beispiel: Server der Gruppe BATCH mit mittlerer Leistungsstufe
dbms_output.put_line(lilam.create_server('LILAM_SRV1', 'BATCH', 'geheim', p_perfServer => lilam.C_SERVER_PERF_MID));
```

### Procedure SERVER_SHUTDOWN
Der Client muss bereits mit dem Server verbunden sein.

Zum Herunterfahren werden die Process ID, die Server-Pipe und das beim Serverstart angegebene Passwort benötigt.

```sql
PROCEDURE SERVER_SHUTDOWN(
  p_processId NUMBER,
  p_pipeName  VARCHAR2,
  p_password  VARCHAR2
)
```

Beim Herunterfahren meldet sich der Server zuerst in der Registry ab und wird ab dann nicht mehr gewählt. Anschließend verarbeitet er noch die Nachrichten, die Clients bereits geschickt haben (Drain-Phase): so lange, bis die Pipe 1 s lang leer bleibt, höchstens etwa 5 s. Danach schreibt er alle Puffer und beendet sich.

### Function GET_SERVER_PIPE
Liefert die Server-Pipe, die mit dem verbundenen Client-Prozess verknüpft ist.

```sql
FUNCTION GET_SERVER_PIPE(
  p_processId NUMBER
) RETURN VARCHAR2
```

### Procedure SERVER_UPDATE_RULES
Rule Sets werden als JSON-Objekte in `LILAM_RULES` gespeichert, jeweils für eine Gruppe (`GROUP_NAME`, Name, Version). Dasselbe Rule Set kann für mehrere Gruppen eingetragen sein. Je Gruppe ist genau ein Rule Set aktiv (`IS_ACTIVE = 1`); es gilt für alle Server der Gruppe und für alle INSESSION-Prozesse, die mit dieser Gruppe gestartet wurden.

```sql
PROCEDURE SERVER_UPDATE_RULES(
  p_groupName      VARCHAR2,
  p_ruleSetName    VARCHAR2,
  p_ruleSetVersion PLS_INTEGER
)
```

Ablauf:
1. Das Rule Set der Gruppe wird in der aufrufenden Session vollständig geprüft. Fehlt es für die Gruppe oder ist eine Regel ungültig, endet der Aufruf mit der Exception `NUM_ERR_RULE_SET` (-20130) und einer Begründung; es ändert sich nichts.
2. Das Rule Set wird für die Gruppe aktiv, das bisher aktive inaktiv.
3. Laufende Server der Gruppe erhalten die Anweisung zum Neuladen direkt in ihre Pipe, also auch ohne laufenden Prozess und am Dispatcher vorbei. Dispatcher werten keine Regeln aus.
4. INSESSION-Prozesse der Gruppe laden das neue Rule Set selbst, spätestens beim ersten API-Aufruf nach 15 Sekunden (siehe [Regeln im INSESSION-Modus](#regeln-im-insession-modus)).

Eine Gruppe ohne laufende Server ist kein Fehler: Jeder Server lädt beim Start das aktive Rule Set seiner Gruppe, auch ein neu hinzukommender. Lehnt ein Server ein Rule Set beim Start ab (z. B. weil es inzwischen direkt in der Tabelle geändert wurde), behält er die bisherigen Regeln (beim Start: keine) und protokolliert den Grund in `LILAM_LOG_INTERNAL` und im Log des Serverprozesses.

```sql
INSERT INTO LILAM_RULES (group_name, set_name, version, created, author, rule_set)
VALUES ('METRO', 'METRO_RULES', 2, systimestamp, 'Dirk', '{"rules":[ ... ]}');

exec LILAM.SERVER_UPDATE_RULES('METRO', 'METRO_RULES', 2);
```

Aufbau der Rule Sets und Operatoren: [Rules Engine](../rules/README.md).

### Regeln im INSESSION-Modus
Auch Prozesse im INSESSION-Modus werten Regeln aus, wenn `NEW_SESSION` eine Gruppe erhält (`p_groupName` bzw. `t_session_init.groupName`). Sie nutzen dann dasselbe aktive Rule Set der Gruppe aus `LILAM_RULES` wie die Server dieser Gruppe. Ohne Gruppe gibt es keine Regeln.

- **Laden:** Die erste Regelprüfung eines Prozesses der Gruppe lädt das aktive Rule Set in den Speicher der Datenbank-Session. Weitere Prozesse derselben Gruppe in dieser Session verwenden es mit. Verschiedene Gruppen in einer Session sind möglich und bleiben getrennt.
- **Änderungen:** Höchstens alle 15 Sekunden prüft LILAM bei einem API-Aufruf, ob sich Name oder Version des aktiven Rule Sets der Gruppe geändert haben, und lädt es dann neu. `SERVER_UPDATE_RULES` wirkt also auch hier, spätestens beim ersten API-Aufruf nach 15 Sekunden. Wird ein Rule Set direkt in der Tabelle geändert, ohne dass sich Name oder Version ändern, bemerkt das eine laufende Session nicht.
- **Ungültiges Rule Set:** Es wird abgelehnt und einmal je Version in `LILAM_LOG_INTERNAL` protokolliert; die bisherigen Regeln bleiben aktiv. Die Anwendung bemerkt davon nichts.
- **Alerts:** Ein ausgelöster Alert wird sofort und synchron geschrieben (`LILAM_ALERTS` und `DBMS_ALERT`-Signal, eigene Transaktion). Das kostet die Anwendung pro Alert einen Commit; `throttle_seconds` begrenzt die Häufigkeit. `GROUP_NAME` im Alert ist die Gruppe aus `NEW_SESSION`.
- **Gedächtnis je Session:** Drosselung (`throttle_seconds`) und der Vorgänger für `PRECEDED_BY` gelten je Datenbank-Session. Mit einem Connection-Pool (z. B. APEX) kann derselbe Alert daher je Pool-Verbindung einmal ausgelöst werden.
- **Baseline-Parameter:** `warmup` und `alpha` aus `AVG_DEVIATION_PCT`-Regeln gelten wie im Server auch für die Durchschnittswerte des Prozesses.

```sql
l_processId := lilam.new_session('IMPORT_CUSTOMERS', p_groupName => 'METRO');
```

## Dispatcher-Modus
Ein mit p_isDispatcher => 1 gestarteter Server (Dispatcher) verarbeitet keine Anfragen selbst, sondern leitet sie unverändert an einen passenden Server weiter.

Für NEW_SESSION/SERVER_NEW_SESSION wählt der Dispatcher dabei denselben lastbasierten Mechanismus wie die reguläre Serverauswahl und reicht die Anfrage an die Steuer-Pipe des gewählten Servers weiter;
für alle anderen Anfragen ermittelt er anhand der bereits vergebenen process_id den Server, der für den Prozess der Anwendung zuständig ist und leitet dorthin weiter.

Die Antwort des zuständigen Servers geht direkt an den Client zurück, nicht über den Dispatcher. Ein Sequenzdiagramm des Ablaufs steht in [architecture and concepts.md](architecture%20and%20concepts.md#dispatcher-flow).

Ein Dispatcher ist in der Server-Registry gekennzeichnet (`IS_DISPATCHER = 1`) und wird bei der Serverauswahl nie als Ziel gewählt. Worker und Dispatcher können daher in derselben Gruppe laufen: Clients ohne Dispatcher-Konfiguration erhalten immer direkt einen Worker.

> [!TIP]
> Ein Dispatcher ist vor allem für Anwendungen relevant, die ihre physische Datenbankverbindung nicht durchgehend halten – typischerweise Oracle-APEX-Anwendungen mit Connection Pooling.
> Dabei kann eine Folgeseite in einer anderen physischen Session laufen als die Seite, die den Prozess ursprünglich gestartet hat.
> Ein konfigurierter Dispatcher ermöglicht es LILAM, die Verbindung zum zuständigen Worker in diesem Fall automatisch wiederherzustellen, ohne dass die Anwendung das selbst steuern muss.

Für Anwendungen mit durchgehender Datenbanksession (klassischer In-Session- oder entkoppelter Betrieb ohne Connection Pooling) ist kein Dispatcher erforderlich.

### Automatisches Reconnect
Ist ein Dispatcher konfiguriert, versucht LILAM bei jedem API-Aufruf mit einer process_id, die der aktuellen physischen Session unbekannt ist, automatisch und transparent eine Verbindung über den Dispatcher wiederherzustellen.
Schlägt das fehl (kein Dispatcher konfiguriert, Dispatcher nicht erreichbar, oder der Prozess existiert nicht mehr), verhält sich der Aufruf wie bei jeder anderen unbekannten process_id: Er wird ohne Fehlermeldung ignoriert.

Dabei gilt:

- Für negative process_ids (z.B. `NUM_ERR_SESSION_TIMEOUT`) wird kein Reconnect versucht.
- Findet der Dispatcher keinen zuständigen Server, antwortet er sofort mit einem Fehler; die Anwendung wartet nicht.
- Ein gescheiterter Reconnect wird für die physische Session gemerkt: Kennt der Server den Prozess nicht (z.B. nach `CLOSE_SESSION`), werden weitere Aufrufe mit dieser process_id ohne erneute Anfrage ignoriert. Bei vorübergehenden Störungen (Dispatcher nicht erreichbar) wird der nächste Versuch frühestens nach 10 Sekunden unternommen.

### Vorwärmen
Der automatische Reconnect-Versuch kostet einen einmaligen Pipe-Roundtrip. Ohne Vorwärmen trägt der erste API-Aufruf nach einem Sessionwechsel diese zusätzliche Latenz.
Wird p_processId mitgegeben, findet dieser Roundtrip bereits beim Aufruf von SET_DISPATCHER_PIPE statt – typischerweise im Seitenaufbau, bevor die Anwendung reagiert.

### Procedure SET_DISPATCHER_PIPE
Teilt LILAM mit, über welche Pipe ein Dispatcher erreichbar ist. Diese Information wird ausschließlich im Speicher der aktuellen physischen Datenbanksession gehalten.

> [!IMPORTANT]
> Da die Konfiguration nur für die aktuelle physische Session gilt, muss SET_DISPATCHER_PIPE bei jedem neuen Verbindungsaufbau erneut aufgerufen werden – bei Connection Pooling also potenziell auf jeder Seite, nicht nur einmalig beim ersten Seitenaufruf.


```sql
PROCEDURE SET_DISPATCHER_PIPE(
  p_pipeName  VARCHAR2,
  p_groupName VARCHAR2 DEFAULT 'DEFAULT_DISPATCHER',
  p_processId NUMBER   DEFAULT NULL
)
```

#### Parameter
| Parameter | Typ | Bedeutung |
| --------- | --- | --------- |
| p_pipeName | varchar2 | Pipe-Name des Dispatchers |
| p_groupName | varchar2 | Optionale Kennung, falls mehrere Dispatcher parallel genutzt werden. [Automatisches Reconnect](#automatisches-reconnect) verwendet ausschließlich die Standardkennung 'DEFAULT_DISPATCHER' |
| p_processId | number | Optional. Ist bereits eine process_id bekannt, stellt LILAM die Verbindung zu dieser sofort wieder her (siehe [Vorwärmen](#vorwärmen)), statt erst beim nächsten API-Aufruf |

```sql
-- Beispiel: APEX "Before Header"-Process
BEGIN
  lilam.set_dispatcher_pipe(
    p_pipeName  => 'LILAM_DISPATCHER_SALES',
    p_processId => :G_LILAM_PROCESS_ID  -- NULL beim allerersten Seitenaufruf
  );
END;
/
```
---

## Anhang

### Parameterkennzeichnung

| Kennzeichnung | Bedeutung |
| --- | --- |
| M | Mandatory |
| O | Optional |
| N | Nullable |
| D | Default value |

### Log-Level

Der aktive Log-Level bestimmt, welche Log-Meldungen geschrieben werden.

| Level | Wert | Verhalten |
| --- | ---: | --- |
| `logLevelSilent` | 0 | Keine Log-Details |
| `logLevelError` | 1 | ERROR |
| `logLevelWarn` | 2 | WARN und ERROR |
| `logLevelMonitor` | 3 | Aktiviert die Monitoring-Funktionen |
| `logLevelInfo` | 4 | INFO, WARN und ERROR |
| `logLevelDebug` | 8 | DEBUG, INFO, WARN und ERROR |

```sql
logLevelSilent  CONSTANT PLS_INTEGER := 0;
logLevelError   CONSTANT PLS_INTEGER := 1;
logLevelWarn    CONSTANT PLS_INTEGER := 2;
logLevelMonitor CONSTANT PLS_INTEGER := 3;
logLevelInfo    CONSTANT PLS_INTEGER := 4;
logLevelDebug   CONSTANT PLS_INTEGER := 8;
```

### Record-Typ t_session_init

Verwende `t_session_init`, um die Einstellungen zur Initialisierung zusammenzufassen und anschließend an den Record-basierten `NEW_SESSION`-Overload zu übergeben.

```sql
TYPE t_session_init IS RECORD (
  processName   VARCHAR2(100),
  logLevel      PLS_INTEGER := logLevelMonitor,
  stepsToDo     PLS_INTEGER,
  daysToKeep    PLS_INTEGER,                    -- NULL = keine automatische Bereinigung
  procImmortal  PLS_INTEGER := 0,
  tabNameMaster VARCHAR2(100) DEFAULT 'LILAM',
  baselineScope VARCHAR2(100),                  -- NULL = Prozessname, '#NONE' = nur pro Prozess
  groupName     VARCHAR2(50),                   -- Gruppe für das aktive Rule Set; NULL = keine Regeln
  syncLevel     PLS_INTEGER := logLevelError    -- bis zu diesem Level synchron schreiben
);
```

### Record-Typ t_process_rec

`t_process_rec` enthält die von `GET_PROCESS_DATA` zurückgegebenen Prozessdaten.

```sql
TYPE t_process_rec IS RECORD (
  id            NUMBER(19,0),
  processName   VARCHAR2(100),
  logLevel      PLS_INTEGER,
  processStart  TIMESTAMP,
  processEnd    TIMESTAMP,
  lastUpdate    TIMESTAMP,
  stepsTodo     PLS_INTEGER,
  stepsDone     PLS_INTEGER,
  status        PLS_INTEGER,
  info          VARCHAR2(4000),
  procImmortal  PLS_INTEGER := 0,
  tabNameMaster VARCHAR2(100)
);
```

### Procedure IS_ALIVE

Einfacher Funktionstest nach der Installation: legt im In-Session-Modus den Prozess `LILAM Life Check` an, schreibt einen DEBUG-Eintrag und schließt den Prozess. Beim ersten Aufruf legt LILAM dabei seine Tabellen an; fehlende Rechte fallen so sofort auf (Einträge in `LILAM_LOG_INTERNAL`).

```sql
exec lilam.is_alive;
```

### JSON API Interface

Über `CALL_BY_JSON` lassen sich die wichtigsten API-Aufrufe als JSON übergeben, z. B. aus Anwendungen, die JSON leichter erzeugen als PL/SQL-Aufrufe.

```sql
PROCEDURE CALL_BY_JSON(
  p_callObject IN  VARCHAR2,      -- JSON_OBJ_LILAM
  p_respObject OUT VARCHAR2
)

PROCEDURE CALL_BY_JSON(
  p_callObject IN  JSON_OBJECT_T,
  p_respObject OUT JSON_OBJECT_T
)
```

LILAM JSON Requests bestehen aus einem Header und einem Parameterobjekt. Der Header enthält in `api_call` den Aufruf; die Header-Parameter `version` und `client_id` werden derzeit nicht verwendet.

| `api_call` | entspricht | Parameter (`params`) |
| --- | --- | --- |
| `NEW_SESSION` | `NEW_SESSION` (Record) | `process_name`, `log_level`, `steps_todo`, `days_to_keep`, `process_immortal`, `tabname_master`, `baseline_scope`, `group_name` |
| `SERVER_NEW_SESSION` | `SERVER_NEW_SESSION_JSON` | wie `SERVER_NEW_SESSION`, siehe Tabelle dort |
| `CLOSE_SESSION` | `CLOSE_SESSION` | `process_id` |
| `FLUSH` | `FLUSH` | keine |
| `SET_PROCESS_STATUS` | `SET_PROCESS_STATUS` | `process_id`, `process_status`, `process_info` |
| `SET_STEP_TODO` | `SET_PROC_STEPS_TODO` | `process_id`, `steps_todo` |
| `SET_STEPS_DONE` | `SET_PROC_STEPS_DONE` | `process_id`, `steps_done` |
| `PROC_STEP_DONE` | `PROC_STEP_DONE` | `process_id` |
| `SET_PROC_IMMORTAL` | `SET_PROC_IMMORTAL` | `process_id`, `process_immortal` |
| `INFO`, `DEBUG`, `WARN`, `ERROR` | Logging | `process_id`, `process_info` (Logtext) |
| `MARK_EVENT`, `TRACE_START`, `TRACE_STOP` | Metriken | `process_id`, `action_name`, `context_name`, `timestamp` |
| `SERVER_SHUTDOWN` | `SERVER_SHUTDOWN` | `process_id`, `pipe_name`, `password` |

Die Antwort enthält den Header der Anfrage, `status` (`SUCCESS` oder `ERROR`) und eine `payload` mit `returns` und `value`, z. B. `"returns": "PROCESS_ID", "value": 4711`. Bei einem unbekannten `api_call` ist `value` = `NUM_ERR_ILLEGAL_REQ` (-20010). Ist `p_callObject` kein gültiges JSON, endet der Aufruf mit der Exception -20005.

Beispiel für `SERVER_NEW_SESSION`:

```json
{
  "header": {
    "version": "v1.x.x",
    "client_id": "GATE_15",
    "api_call": "SERVER_NEW_SESSION"
  },
  "params": {
    "process_name": "Your Process Name",
    "log_level": 3,
    "steps_todo": 100,
    "days_to_keep": 20,
    "tabname_master": "GATES"
  }
}
```
