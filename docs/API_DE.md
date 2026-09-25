# LILAM API-Referenz
### Version: 1.7

---

<details>
<summary>📖 <b>Inhalt</b></summary>

- #schnellstart
  - #in-session-modus
  - [Entkoppelter Server-modus
- #grundkonzepte
  - [Prozessfortschritt vs. Metriken](#prozessfortschritt-vs-metrikenen-und-prozeduren
  - [Session-Verwaltung](#session-sssteuerung
  - [Logging](#logging)
  - #metriken
  - #serversteuerung
- #anhang
  - #parameterkennzeichnung
  - [Log-Level](#log-level)
  - [Record-typ-t_session_init
  - #record-typ-t_process_rec
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
  l_sessionInit t_session_init;
BEGIN
  -- 1. Configure the session
  l_sessionInit.processName := 'MY_FIRST_SYNC';
  l_sessionInit.logLevel    := logLevelInfo; -- default: logLevelMonitor

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
    'MY_FIRST_LILAM_SERVER',
    NULL,
    'SECURE PASSWORD'
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
    'DECOUPLED_SYNC',
    lilam.logLevelInfo,
    0,
    100,
    'LILAM'
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
    'SHUT DOWN SERVER',
    lilam.logLevelInfo,
    0,
    100,
    'LILAM'
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
| `FINAL_RESCUE` | Persistiert zwischengespeicherte Daten nach abnormalen Prozessabbrüchen |

### Function NEW_SESSION / SERVER_NEW_SESSION

Beide Funktionen starten einen LILAM Prozess und liefern dessen Process ID zurück. Diese ID wird für nachfolgende API-Aufrufe benötigt.

#### Welche Variante sollte ich verwenden?

- Verwende die `t_session_init`-Variante, wenn Du die Initialisierungsparameter übersichtlich in einem Record zusammenfassen möchtest.
- Verwende einen kurzen `NEW_SESSION`-Overload, wenn nur wenige Einstellungen erforderlich sind.
- Verwende `SERVER_NEW_SESSION` für den entkoppelten Betrieb.
- Verwende den `SERVER_NEW_SESSION`-Overload mit `p_groupName`, wenn die Serverauswahl auf eine bestimmte Gruppe eingeschränkt werden soll.

#### NEW_SESSION: Basic Mode

```sql
FUNCTION NEW_SESSION(
  p_processName   VARCHAR2,
  p_logLevel      PLS_INTEGER DEFAULT logLevelMonitor,
  p_tabNameMaster VARCHAR2 DEFAULT 'LILAM'
) RETURN NUMBER
```

#### NEW_SESSION: Retention Mode

```sql
FUNCTION NEW_SESSION(
  p_processName   VARCHAR2,
  p_logLevel      PLS_INTEGER,
  p_daysToKeep    PLS_INTEGER,
  p_tabNameMaster VARCHAR2 DEFAULT 'LILAM'
) RETURN NUMBER
```

#### NEW_SESSION: Full Progress Mode

```sql
FUNCTION NEW_SESSION(
  p_processName   VARCHAR2,
  p_logLevel      PLS_INTEGER,
  p_procStepsToDo PLS_INTEGER,
  p_daysToKeep    PLS_INTEGER,
  p_tabNameMaster VARCHAR2 DEFAULT 'LILAM'
) RETURN NUMBER
```

#### NEW_SESSION: Initialisierung über einen Record

```sql
FUNCTION NEW_SESSION(
  p_session_init t_session_init
) RETURN NUMBER
```

#### SERVER_NEW_SESSION: Beliebiger verfügbarer Server

```sql
FUNCTION SERVER_NEW_SESSION(
  p_processName   VARCHAR2,
  p_logLevel      PLS_INTEGER,
  p_procStepsToDo PLS_INTEGER,
  p_daysToKeep    PLS_INTEGER,
  p_tabNameMaster VARCHAR2
) RETURN NUMBER
```

#### SERVER_NEW_SESSION: Server aus einer bestimmten Gruppe

```sql
FUNCTION SERVER_NEW_SESSION(
  p_processName   VARCHAR2,
  p_groupName     VARCHAR2,
  p_logLevel      PLS_INTEGER,
  p_procStepsToDo PLS_INTEGER,
  p_daysToKeep    PLS_INTEGER,
  p_tabNameMaster VARCHAR2
) RETURN NUMBER
```

#### Parameter

| Parameter | JSON | Beschreibung |
| --- | --- | --- |
| `p_processName` | `process_name` | Name zur Identifikation des Prozesses |
| `p_groupName` | `group_name` | Beschränkt die Serverauswahl auf die angegebene Gruppe |
| `p_logLevel` | `log_level` | Legt den Detaillierungsgrad des Loggings fest |
| `p_procStepsToDo` | `steps_todo` | Geplante Anzahl der Prozessschritte |
| `p_daysToKeep` | `days_to_keep` | Maximales Alter passender Prozessdaten vor einer Bereinigung |
| `p_tabNameMaster` | `tab_name_master` | Präfix für die PROC-, LOG- und MON-Tabellen |

**Rückgabewert:** `NUMBER`, die Process ID.

### Procedure CLOSE_SESSION

Beendet einen LILAM Prozess. Abhängig vom verwendeten Overload können abschließende Prozessinformationen, Prozessfortschritt und Status übergeben werden.

> [!IMPORTANT]
> Rufe `CLOSE_SESSION` immer auf, wenn ein Prozess endet. LILAM puffert Daten aus Performancegründen. `CLOSE_SESSION` stellt sicher, dass noch vorhandene gepufferte Daten persistiert werden.
>
> Daher sollte `CLOSE_SESSION` auch Bestandteil der abschließenden Exception-Behandlung sein.

```sql
PROCEDURE CLOSE_SESSION(
  p_processId NUMBER
)
```

```sql
PROCEDURE CLOSE_SESSION(
  p_processId   NUMBER,
  p_processInfo VARCHAR2,
  p_status      PLS_INTEGER
)
```

```sql
PROCEDURE CLOSE_SESSION(
  p_processId      NUMBER,
  p_procStepsDone  NUMBER,
  p_processInfo    VARCHAR2,
  p_processStatus  PLS_INTEGER
)
```

```sql
PROCEDURE CLOSE_SESSION(
  p_processId      NUMBER,
  p_procStepsToDo  NUMBER,
  p_procStepsDone  NUMBER,
  p_processInfo    VARCHAR2,
  p_processStatus  PLS_INTEGER
)
```

Beispiel für die Exception-Behandlung:

```sql
EXCEPTION
  WHEN OTHERS THEN
    lilam.close_session(
      p_processId   => l_proc_id,
      p_processInfo => SQLERRM,
      p_status      => -1
    );
    RAISE;
```

### Procedure FINAL_RESCUE

LILAM speichert Logging-, Monitoring- und Prozessdaten aus Performancegründen teilweise zwischen.

`FINAL_RESCUE` persistiert alle aktuell zwischengespeicherten Daten der aktuellen Datenbanksession.

```sql
BEGIN
  lilam.final_rescue;
END;
/
```

> [!IMPORTANT]
> `FINAL_RESCUE` muss aus der Datenbanksession heraus aufgerufen werden, in der die betroffenen Prozesse ausgeführt wurden.

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
| `GET_PROCESS_DATA` | Liefert sämtliche Prozessdaten in einem Record |

> [!NOTE]
> Bei Änderungen an Prozessdaten wird der Wert `lastUpdate` des Prozessdatensatzes implizit aktualisiert.

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
- `p_logText` enthält die Meldung.

`ERROR` besitzt die höchste Priorität und wird immer gespeichert, sofern das Logging nicht vollständig mit `logLevelSilent` deaktiviert wurde.

Ist `logLevelDebug` aktiv, werden von LILAM abgefangene Exceptions erneut ausgelöst, anstatt sie still zu behandeln.

Die vollständige Zuordnung findest Du unter [Log-Level](#log-level).

---

## Metriken

Metriken erfassen Events und logische Transaktionen innerhalb eines Prozesses.

> [!IMPORTANT]
> `p_actionName` und `p_contextName` bilden gemeinsam die Identifikation einer Metrik.
>
> Ein mit einem Context gestarteter Trace muss mit derselben Kombination aus Action und Context beendet werden.

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
> Server-Pipe-Namen müssen innerhalb der Datenbankinstanz eindeutig sein.

| API | Zweck |
| --- | --- |
| `START_SERVER` | Startet einen LILAM Server in der aktuellen Session |
| `CREATE_SERVER` | Startet einen LILAM Server über `DBMS_SCHEDULER` |
| `SERVER_SHUTDOWN` | Beendet einen Server |
| `GET_SERVER_PIPE` | Liefert die Server-Pipe eines verbundenen Clients |
| `SERVER_UPDATE_RULES` | Aktiviert ein aktualisiertes Rule Set |

### Procedure START_SERVER

Startet einen LILAM Server.

Das Passwort muss beim späteren Herunterfahren des Servers erneut angegeben werden.

```sql
PROCEDURE START_SERVER(
  p_pipeName  VARCHAR2,
  p_groupName VARCHAR2,
  p_password  VARCHAR2
)
```

### Function CREATE_SERVER

Startet einen LILAM Server über `DBMS_SCHEDULER` und liefert Serverinformationen als `VARCHAR2` zurück.

```sql
FUNCTION CREATE_SERVER(
  p_pipeName  VARCHAR2,
  p_groupName VARCHAR2,
  p_password  VARCHAR2
) RETURN VARCHAR2
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

### Function GET_SERVER_PIPE

Liefert die Server-Pipe, die mit dem verbundenen Client-Prozess verknüpft ist.

```sql
FUNCTION GET_SERVER_PIPE(
  p_processId NUMBER
) RETURN VARCHAR2
```

### Procedure SERVER_UPDATE_RULES

Rules werden als JSON-Objekte in `LILAM_RULES` gespeichert.

Nachdem ein Rule Set eingefügt oder geändert wurde, kann `SERVER_UPDATE_RULES` über eine aktive Serververbindung aufgerufen werden, um das aktualisierte Rule Set anzuwenden.

```sql
PROCEDURE SERVER_UPDATE_RULES(
  p_processId      NUMBER,
  p_ruleSetName    VARCHAR2,
  p_ruleSetVersion PLS_INTEGER
)
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
  daysToKeep    PLS_INTEGER := 100,
  procImmortal  PLS_INTEGER := 0,
  tabNameMaster VARCHAR2(100) DEFAULT 'LILAM'
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

### JSON API Interface

LILAM JSON Requests bestehen grundsätzlich aus einem Header und einem Parameterobjekt.

Die Header-Parameter `version` und `client_id` werden derzeit nicht verwendet.

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
    "tab_name_master": "GATES"
  }
}
```