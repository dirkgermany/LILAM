# LILAM API-Referenz
### Version: 2.0

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
| `FINAL_RESCUE` | Persistiert zwischengespeicherte Daten nach abnormalen Prozessabbrüchen |

### Function NEW_SESSION / SERVER_NEW_SESSION

Beide Funktionen starten einen LILAM Prozess und liefern dessen Process ID zurück. Diese ID wird für alle nachfolgenden API-Aufrufe benötigt.

- `NEW_SESSION` startet den Prozess im In-Session-Modus.
- `SERVER_NEW_SESSION` startet den Prozess im entkoppelten Modus über einen LILAM Server. Die Parameter sind dieselben, ergänzt um `p_groupName` an zweiter Stelle.
- Alternativ lassen sich alle Einstellungen in einem Record [`t_session_init`](#record-typ-t_session_init) zusammenfassen (nur `NEW_SESSION`).

Jeder Parameter steht immer an derselben Position. Alle Parameter außer `p_processName` besitzen einen Default und können daher weggelassen oder per Namen übergeben werden.

```sql
FUNCTION NEW_SESSION(
  p_processName   VARCHAR2,
  p_logLevel      PLS_INTEGER DEFAULT logLevelMonitor,
  p_procStepsToDo PLS_INTEGER DEFAULT NULL,
  p_daysToKeep    PLS_INTEGER DEFAULT NULL,
  p_tabNameMaster VARCHAR2    DEFAULT 'LILAM',
  p_baselineScope VARCHAR2    DEFAULT NULL
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
  p_baselineScope VARCHAR2    DEFAULT NULL
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
| `p_groupName` | `group_name` | `NULL` | Nur `SERVER_NEW_SESSION`: beschränkt die Serverauswahl auf die angegebene Gruppe; `NULL` = beliebiger verfügbarer Server |
| `p_logLevel` | `log_level` | `logLevelMonitor` | Detaillierungsgrad des Loggings, siehe [Log-Level](#log-level) |
| `p_procStepsToDo` | `steps_todo` | `NULL` | Geplante Anzahl der Prozessschritte |
| `p_daysToKeep` | `days_to_keep` | `NULL` | `NULL` = keine automatische Bereinigung. Sonst werden beim Start abgeschlossene Prozesse gleichen Namens, die älter als die angegebene Anzahl Tage sind, samt Logs und Metriken gelöscht (außer Prozesse mit `procImmortal = 1`) |
| `p_tabNameMaster` | `tabname_master` | `'LILAM'` | Präfix für die PROC-, LOG- und MON-Tabellen |
| `p_baselineScope` | `baseline_scope` | `NULL` | Bezugsrahmen für die Durchschnittswerte (EWMA) von Traces und Events: `NULL` = Prozessname, d.h. gemeinsam über alle Prozesse mit diesem Namen; `'#NONE'` = nur innerhalb des einzelnen Prozesses; sonst ein frei gewählter Name, der auch von mehreren Anwendungen geteilt werden kann |

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

#### Beispiele

```sql
-- nur der Name, alle übrigen Werte per Default
l_processId := lilam.new_session('IMPORT_CUSTOMERS');

-- Log-Level INFO und 500 geplante Schritte
l_processId := lilam.new_session('IMPORT_CUSTOMERS', lilam.logLevelInfo, 500);

-- einzelne Parameter per Namen
l_processId := lilam.new_session('IMPORT_CUSTOMERS', p_daysToKeep => 30);
l_processId := lilam.new_session('IMPORT_CUSTOMERS', p_baselineScope => '#NONE');

-- entkoppelt: beliebiger verfügbarer Server bzw. Server der Gruppe BATCH
l_processId := lilam.server_new_session('IMPORT_CUSTOMERS');
l_processId := lilam.server_new_session('IMPORT_CUSTOMERS', 'BATCH', lilam.logLevelInfo);
```

### Procedure CLOSE_SESSION

Beendet einen LILAM Prozess. Optional können abschließende Prozessinformationen, Status und Fortschritt übergeben werden.

> [!IMPORTANT]
> Rufe `CLOSE_SESSION` immer auf, wenn ein Prozess endet. LILAM puffert Daten aus Performancegründen. `CLOSE_SESSION` stellt sicher, dass noch vorhandene gepufferte Daten persistiert werden.
>
> Daher sollte `CLOSE_SESSION` auch Bestandteil der abschließenden Exception-Behandlung sein.

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
- `p_logText` enthält die Meldung. Längere Texte werden auf 1.900 Zeichen gekürzt (bei Mehrbyte-Zeichen wie Umlauten ggf. weniger, maximal 2.000 Bytes).

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
> Server-Pipe-Namen müssen innerhalb der Datenbankinstanz eindeutig sein. Jeder Server legt zusätzlich eine Steuer-Pipe mit der Endung `_CTL` an (z.B. `LILAM_SRV1_CTL` zu `LILAM_SRV1`); auch diese Namen dürfen nicht anderweitig verwendet werden.

Ein Server nutzt zwei Pipes:

- **Daten-Pipe** (`<Pipe-Name>`): alle Logs, Traces, Events, Status und Abfragen in der Reihenfolge ihres Eintreffens.
- **Steuer-Pipe** (`<Pipe-Name>_CTL`): nur das Anlegen neuer Prozesse (`SERVER_NEW_SESSION`). Der Server fragt sie vor jeder Datennachricht ab, ohne zu warten. Dadurch muss das Anlegen eines Prozesses auch unter hoher Last nicht hinter den Nachrichten anderer Anwendungen warten. Ein kurzer Weckruf in die Daten-Pipe sorgt dafür, dass auch ein untätiger Server die Anfrage sofort bemerkt.

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

### Function GET_SERVER_PIPE
Liefert die Server-Pipe, die mit dem verbundenen Client-Prozess verknüpft ist.

```sql
FUNCTION GET_SERVER_PIPE(
  p_processId NUMBER
) RETURN VARCHAR2
```

### Procedure SERVER_UPDATE_RULES
Rules werden als JSON-Objekte in `LILAM_RULES` gespeichert. Ein Rule Set gilt für alle Server einer Gruppe.

```sql
PROCEDURE SERVER_UPDATE_RULES(
  p_groupName      VARCHAR2,
  p_ruleSetName    VARCHAR2,
  p_ruleSetVersion PLS_INTEGER
)
```

Ablauf:
1. Das Rule Set wird in der aufrufenden Session vollständig geprüft. Fehlt es, ist eine Regel ungültig oder hat die Gruppe keinen Server, endet der Aufruf mit der Exception `NUM_ERR_RULE_SET` (-20130) und einer Begründung; es ändert sich nichts.
2. Name und Version werden für alle Server der Gruppe in `LILAM_SERVER_REGISTRY` eingetragen (Dispatcher ausgenommen).
3. Laufende Server erhalten die Anweisung direkt in ihre Pipe, also auch ohne laufenden Prozess und am Dispatcher vorbei. Gestoppte Server laden das Rule Set beim nächsten Start.

Ein neu registrierter Server übernimmt beim Start das Rule Set seiner Gruppe. Lädt ein Server ein Rule Set beim Start oder Neuladen nicht (z. B. weil es inzwischen geändert wurde), behält er die bisherigen Regeln und protokolliert den Grund in `LILAM_LOG_INTERNAL` und im Log des Serverprozesses.

```sql
exec LILAM.SERVER_UPDATE_RULES('METRO', 'METRO_RULES', 2);
```

Regeln wirken nur in Servern, nicht im INSESSION-Modus. Aufbau der Rule Sets und Operatoren: [Rules Engine](../rules/README.md).

## Dispatcher-Modus
Ein mit p_isDispatcher => 1 gestarteter Server (Dispatcher) verarbeitet keine Anfragen selbst, sondern leitet sie unverändert an einen passenden Server weiter.

Für NEW_SESSION/SERVER_NEW_SESSION wählt der Dispatcher dabei denselben lastbasierten Mechanismus wie die reguläre Serverauswahl und reicht die Anfrage an die Steuer-Pipe des gewählten Servers weiter;
für alle anderen Anfragen ermittelt er anhand der bereits vergebenen process_id den Server, der für den Prozess der Anwendung zuständig ist und leitet dorthin weiter.

Die Antwort des zuständigen Servers geht direkt an den Client zurück, nicht über den Dispatcher.

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
| Parameter | Typ | Besdeutung |
| p_pipeName | varchar2 | Pipe-Name des Dispatchers |
| p_groupName | varchar2 | Optionale Kennung, falls mehrere Dispatcher parallel genutzt werden. Automatisches Reconnect (siehe unten) verwendet ausschließlich die Standardkennung 'DEFAULT_DISPATCHER' |
| p_processId | number | Optional. Ist bereits eine process_id bekannt, stellt LILAM die Verbindung zu dieser sofort wieder her (siehe „Vorwärmen"), statt erst beim nächsten API-Aufruf |

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
  baselineScope VARCHAR2(100)                   -- NULL = Prozessname, '#NONE' = nur pro Prozess
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
    "tabname_master": "GATES"
  }
}
```
