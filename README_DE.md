# LILAM - Framework für Prozessüberwachung und Observability in PL/SQL

[English](README.md) | **Deutsch**

LILAM = "**L**ILAM **I**s **L**ogging **A**nd **M**onitoring"

[![Release](https://img.shields.io/github/v/release/dirkgermany/LILAM)](https://github.com/dirkgermany/LILAM/releases/latest)
[![Status](https://img.shields.io/badge/Status-Production--Ready-brightgreen)](https://github.com/dirkgermany/LILAM)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![License: Enterprise](https://img.shields.io/badge/License-Enterprise-brightgreen.svg)](LICENSE_ENTERPRISE.md)
[![Größe](https://img.shields.io/github/repo-size/dirkgermany/LILAM)](https://github.com/dirkgermany/LILAM)
[![Sponsor](https://img.shields.io/badge/Sponsor-LILAM-purple?style=flat-square&logo=github-sponsors)](https://github.com/sponsors/dirkgermany)


<p align="center">
  <img src="images/lilam-logging.svg" alt="Lila Logger Logo" width="300">
</p>

LILAM ist ein leistungsstarkes Framework für Prozessüberwachung, Observability und Logging in Oracle PL/SQL. Es liefert tiefe Einblicke in Prozessmetriken in Echtzeit und nutzt eine dynamische, JSON-basierte Rule Engine, um autonome Reaktionen auszulösen und komplexe Abläufe zu koordinieren.
Dank der einfachen API lässt es sich mit minimalem Aufwand nahtlos in bestehende Anwendungen integrieren.

LILAM nutzt **autonome Transaktionen**, damit Prozesszustände, Log-Einträge und Performance-Metriken unabhängig vom Hauptablauf gespeichert werden. Dieser entkoppelte Ansatz garantiert einen vollständigen Audit-Trail und verlässliche Monitoring-Daten, selbst wenn der eigentliche Geschäftsprozess einen Rollback durchführt.

LILAM wird von einem Entwickler entwickelt, der überladene Werkzeuge hasst. Der Anspruch: 5 Minuten für die Integration, 100 % Transparenz.
```sql
  DECLARE
    l_pid NUMBER;
  BEGIN
    l_pid := lilam.new_process('IMPORT_CUSTOMERS', lilam.logLevelInfo);
    lilam.info(l_pid, 'Import gestartet');
    -- Deine Geschäftslogik
    lilam.info(l_pid, 'Import beendet');
    lilam.close_process(l_pid);
  END;
  /

  select   no, info, session_time, caller
  from     lilam_log
  order by process_id desc, no;
```

## Inhalt
- [Schnellstart](#schnellstart)
- [Wichtigste Merkmale](#wichtigste-merkmale)
- [Vergleich](#vergleich)
- [Schnelle Integration](#schnelle-integration)
- [Vorteile](#vorteile)
- [Prozessverfolgung & Monitoring](#prozessverfolgung--monitoring)
  - [Regelbasierte Observability & Orchestrierung](#regelbasierte-observability--orchestrierung)
  - [How-To: Das U-Bahn-Beispiel](#how-to-das-u-bahn-beispiel)
- [Daten](#daten)
  - [Prozessdaten](#prozessdaten)
  - [Logging-Daten](#logging-daten)
  - [Monitoring-Daten](#monitoring-daten)
- [Repository-Struktur](#repository-struktur)
- [Performance-Benchmark](#performance-benchmark)
- [Lizenz](#lizenz)
- [Roadmap](#roadmap)

## Schnellstart
1. [Berechtigungen](docs/setup.md#privileges-of-your-schema-user) vergeben
2. [Spezifikation](source/package/lilam.pks) und [Body](source/package/lilam.pkb) kopieren und kompilieren
3. Ausführen
    ```sql
    DECLARE
      l_pid NUMBER;
    BEGIN
      l_pid := lilam.new_process('MY_PROCESS');
      lilam.warn(l_pid, 'Hello LILAM');
      lilam.close_process(l_pid);
    END;
    /
    ```
4. Abfragen (die Tabellen werden beim ersten Aufruf automatisch angelegt)
    ```sql
     select * from lilam_proc; -- Prozessstatus
     select * from lilam_log;  -- Log-Details
     select * from lilam_mon;  -- Events und Traces
    ```

## Wichtigste Merkmale
1. **Selbstinstallierend:** Ein Package und eine Sequence; alle Tabellen legt LILAM selbst an, wenn sie erstmals gebraucht werden: drei je Anwendung (`_PROC`, `_LOG`, `_MON`) und dazu neun interne Tabellen für Regeln, Alerts, Baselines und die Server-Infrastruktur (siehe [Tabellen](docs/Architektur%20und%20Konzepte.md#tabellen)). Für die Nutzung im In-Session-Modus sind weder Installationsskripte noch Scheduler nötig
2. **Paralleles Logging:** Unterstützt mehrere gleichzeitige Log-Einträge aus derselben oder aus verschiedenen Sessions, ohne zu blockieren
3. **Observability zur Laufzeit:** Erfasst und verknüpft Logs, Events und Geschäftstransaktionen nahezu in Echtzeit und ermöglicht so ein tiefes, durchgängiges Performance-Tracing über Anwendungssessions hinweg
4. **Regelbasierte Orchestrierung:** Wertet versionierte JSON-Rule-Sets gegen die Observability-Daten aus, um automatisch Alerts auszulösen oder entkoppelte Consumer für reaktive Fehlerbehandlung und Ablaufsteuerung anzustoßen
5. **Hybride Ausführung:** Betreibe LILAM **in der Session** oder lagere die Verarbeitung an einen eigenen LILAM Server aus (**entkoppelt**).
6. **Datenintegrität:** Autonome Transaktionen garantieren die Speicherung der Logs, unabhängig vom Ausgang der Haupttransaktion
7. **Automatische Kontexterfassung:** Erfasst abhängig vom Log-Level automatisch ERR_STACK, ERR_BACKTRACE und ERR_CALLSTACK: tiefe Einblicke ohne manuellen Aufwand
8. **Optionale Selbstbereinigung:** Entfernt beim Prozessstart automatisch abgelaufene Logs je Anwendung, ohne Hintergrundjobs oder Scheduler
9. **Zukunftssicher:** Entwickelt und getestet unter der aktuellen Oracle 26ai (2026) und unter 19c
10. **In sich geschlossen:** Ein Package ohne Abhängigkeiten von anderen Packages oder externen Bibliotheken; es nutzt nur Oracle-Bordmittel wie `DBMS_PIPE`, `DBMS_ALERT` und `DBMS_SCHEDULER`. Mit Server-Failover, Messwerten und Rule Engine ist der Code auf etwa 8.800 logische PL/SQL-Zeilen gewachsen (ohne Leer- und Kommentarzeilen); Qualitäts- und Sicherheitsprüfungen betreffen weiterhin ein einziges Package

---
## Vergleich
Während klassische PL/SQL-Werkzeuge sich auf Logging oder systemnahes Tracing konzentrieren, bringt LILAM Observability auf Prozessebene direkt in die Datenbank.
Es verbindet Verfolgung des Prozess-Lebenszyklus, Metriken und regelbasierte Reaktionen in einem einheitlichen Observability-Modell innerhalb der Datenbank.

> Diese Tabellen vergleichen verschiedene Ansätze für Logging, Instrumentierung und Observability in PL/SQL.
> Sie zeigen konzeptionelle Schwerpunkte, keinen vollständigen Funktionsvergleich.

### Logging-Frameworks

| Fähigkeit                           | LILAM | Logger | PIT | log4plsql |
|-------------------------------------|-------|--------|-----|-----------|
| Logging                             | ✅    | ✅     | ✅  | ✅        |
| Log-Level                           | ✅    | ✅     | ✅  | ✅        |
| Fehlerkontext (Stack, Backtrace)    | ✅    | ✅     | ✅  | ⚠️        |
| Logging in autonomer Transaktion    | ✅    | ✅     | ⚠️  | ✅        |
| Minimales Setup (Package-basiert)   | ✅    | ✅     | ⚠️  | ❌        |

---

### Instrumentierung & Debugging

| Fähigkeit                           | LILAM | Console | Eigene Instrumentierung |
|-------------------------------------|-------|---------|-------------------------|
| Logging                             | ✅    | ✅      | ⚠️                      |
| Instrumentierung zur Laufzeit       | ✅    | ✅      | ✅                      |
| Session-/Kontextverfolgung          | ✅    | ⚠️      | ❌                      |
| Einblicke in die Performance        | ✅    | ⚠️      | ⚠️                      |
| Zentrales Datenmodell               | ✅    | ❌      | ❌                      |

---

### Oracle-Bordmittel

| Fähigkeit                           | LILAM | DBMS_TRACE / PROFILER |
|-------------------------------------|-------|------------------------|
| Systemnahes Tracing                 | ⚠️    | ✅                     |
| Profiling                           | ❌    | ✅                     |
| Prozess-Lebenszyklus                | ✅    | ❌                     |
| Aggregierte Metriken                | ✅    | ❌                     |
| Monitoring in Echtzeit              | ✅    | ❌                     |
| Entwicklerfreundliche API           | ✅    | ❌                     |


---

## Architektur auf einen Blick

![LILAM Architektur](./images/LILAM%20Application%20Context.svg)

---
## Schnelle Integration
* Um LILAM einzurichten, legst Du ein Package an und vergibst Berechtigungen (siehe [Dokumentationsdatei „setup.md“](docs/setup.md), nur auf Englisch)
* Für das vollständige Logging eines Prozesses sind nur wenige API-Aufrufe nötig (siehe [Dokumentationsdatei „API_DE.md“](docs/API_DE.md))
* Für die Analyse oder Überwachung Deines Prozesses genügen einfache SQL-Anweisungen oder API-Abfragen

>LILAM ist sofort testbereit: Um das Framework direkt nach der Einrichtung in Aktion zu sehen, musst Du nichts implementieren oder programmieren.
>Erste Code-Eindrücke findest Du hier: [learn_lilam](demo/first_steps/learn_lilam.pkb).

---

## Vorteile
Die folgenden Punkte ergänzen die **wichtigsten Merkmale** und geben einen tieferen Einblick in die Architekturentscheidungen und technischen Besonderheiten von LILAM.

### Intelligente Lastverteilung & Ausführung
LILAM bringt eine leistungsstarke Client-Server-Architektur auf Basis von **Oracle Pipes** mit. Sie ermöglicht asynchrone Log-Verarbeitung und sessionübergreifendes Monitoring
* **Hybride Ausführung:** Kombiniere direkte API-Aufrufe in Deiner Session mit entkoppelter Verarbeitung über eigene LILAM Server. Wähle in Echtzeit den besten Ausführungsweg für jeden Log-Level oder Event-Typ
* **Lastabhängige Serversuche:** Clients finden automatisch den am wenigsten belasteten Server ihrer Gruppe und verbinden sich mit ihm
* **Automatische Abstimmung:** Server belegen ihre Kommunikations-Pipes dynamisch, ganz ohne Konfiguration
* **Backpressure:** Fällt ein Server zurück, bremsen seine Clients in kurzen Schritten, bis er aufgeholt hat. Die Leistungsstufe des Servers (`p_perfServer`) ist keine harte Grenze: Solange der Server mithält, wird nichts gebremst
* **Automatisches Failover:** Fällt ein Server aus, wechseln seine Clients zu einem anderen Server der Gruppe und senden die Meldungen erneut, die der ausgefallene Server noch nicht committet hatte


#### So funktioniert es
LILAM bietet zwei Ausführungsmodelle, die wahlweise genutzt werden können:
1. **In-Session-Modus (direkt):** Wird mit `lilam.new_process` gestartet. LILAM arbeitet als eingebettete Bibliothek, Log- und Metrik-Aufrufe laufen unmittelbar in Deiner aktuellen Datenbanksession. Das ist ideal für unkompliziertes Debugging und wenn Daten synchron gespeichert werden sollen.
2. **Entkoppelter Modus (serverbasiert):**
   In diesem Modus entkoppelt LILAM die Anfrage von der Ausführung. Es arbeitet als Proxy in der Anwendungssession und lagert die eigentliche Arbeit an eigene Worker-Prozesse im Hintergrund aus.
   * **Serverseite:** Starte einen oder mehrere LILAM Server mit `lilam.start_server('PIPE_NAME', 'GROUP_NAME', 'PASSWORD');` (oder `lilam.create_server(...)`, um sie als Scheduler-Jobs laufen zu lassen). Jeder Server lauscht auf seiner eigenen Pipe und registriert sich unter einem Gruppennamen. Du kannst skalieren, indem Du mehrere Server in derselben Gruppe betreibst, oder verschiedene Gruppen zur logischen Trennung nutzen.
   * **Clientseite:** Melde Dich mit `lilam.server_new_process('PROCESS_NAME', 'GROUP_NAME');` an. LILAM wählt automatisch einen verfügbaren Server dieser Gruppe (oder einen beliebigen verfügbaren Server, wenn keine Gruppe angegeben ist).
   * **Ausführung:** Log-Aufrufe werden serialisiert in eine Pipe geschrieben und vom Server im Hintergrund verarbeitet, was die Laufzeit Deiner Transaktion kaum beeinflusst.
  
> [!IMPORTANT]
> **Einheitliche API:** Unabhängig vom gewählten Modus bleibt die Logging-API **identisch**. Du verwendest in Deiner gesamten Anwendung dieselben `lilam.log(...)`-Aufrufe.
> Der einzige Unterschied ist die anfängliche Einrichtung (`lilam.new_process` für den In-Session-Modus, `lilam.server_new_process` für den entkoppelten Modus).

### Performance & Sicherheit
LILAM stellt die Stabilität Deiner Anwendung an die erste Stelle. Ein hybrides Modell hält die Balance zwischen Geschwindigkeit und Systemintegrität:
* Logs, Metriken und Statusänderungen laufen nach dem Prinzip Fire-and-Forget, um den Aufwand gering zu halten.
* Ein Client wartet nie auf eine Antwort des Servers. Nur wenn der Server zurückfällt, bremst der Client kurz ab (Backpressure); ist die Pipe voll, hält er Meldungen bis zu einer Sekunde zurück und sendet sie der Reihe nach erneut.
* Meldungen, die der Server noch nicht committet hat, bleiben im Ringpuffer des Clients. Fällt der Server aus, wiederholt der Client sie auf einem anderen Server der Gruppe (Failover).

### Technologie
#### Autonome Persistenz
LILAM nutzt konsequent `PRAGMA AUTONOMOUS_TRANSACTION`. Synchrone Log-Einträge werden unabhängig von der Haupttransaktion committet, selbst wenn die aufrufende Anwendung wegen eines Fehlers ein ROLLBACK ausführt. So bleibt die eigentliche Ursache für die nachträgliche Analyse erhalten.

#### Tiefe Einblicke in den Kontext
Über `UTL_CALL_STACK` erfasst LILAM automatisch den genauen Ausführungspfad. Statt nur einen allgemeinen Fehler zu protokollieren, dokumentiert es die gesamte Aufrufkette und beschleunigt so die Fehlersuche in komplexen, verschachtelten PL/SQL-Umgebungen erheblich.

#### Leistungsstarke Pufferung
Damit der Aufwand für die Anwendung gering bleibt, besitzt LILAM eine interne Pufferung. Log-Einträge werden effizient geschrieben, was besonders in hochbelasteten Produktivumgebungen einen entscheidenden Performance-Vorteil gegenüber einfachem zeilenweisem Logging bringt. Die Ausnahme sind Einträge bis zum Sync-Level (Standard `ERROR`): Sie werden sofort geschrieben, sodass der Fehler und alles, was davor geloggt wurde, gespeichert sind (siehe Performance & Sicherheit).

#### Robust und unaufdringlich (Silent Mode)
LILAM ist darauf ausgelegt, „unsichtbar“ zu sein. Das Framework behandelt interne Fehler nach Möglichkeit selbst, um das Risiko einer Störung der Anwendungslogik zu verringern. Exceptions innerhalb von LILAM werden intern abgefangen und behandelt.

#### Eingebaute Erweiterbarkeit (Adapter)
Die entkoppelte Architektur von LILAM ist auf die nahtlose Integration in moderne Monitoring-Stacks ausgelegt. Das strukturierte Datenformat macht es leicht, Adapter zu schreiben.
*  **Oracle APEX:** Nutze native SQL-Abfragen für APEX-Charts und Dashboards zur Überwachung von Anwendungen in Echtzeit.
*  **Grafana:** Stelle Performance-Trends und Systemzustand in Grafana-Dashboards dar. Über SQL- oder REST-basierte Adapter fließen die Daten direkt in die Dashboards.
*  **Mail-Adapter (Beispiel enthalten):** LILAM bringt eine nahezu produktionsreife Referenzimplementierung für erweitertes Alerting mit. Sie zeigt, wie sich HTML-Mails abhängig von der Severity (z. B. Rot für Critical, Orange für Warnungen) über lokale SMTP-Relays versenden lassen, ohne die Hauptverarbeitung zu blockieren.
*  **Webhook- & Messaging-Anbindung:** Die Adapter-Architektur ist darauf ausgelegt, Benachrichtigungen für Slack, MS Teams oder Jira einfach durch einen neuen Handler anzubinden.

### Hocheffizientes Monitoring

#### Detaillierte Verfolgung von Actions in Echtzeit
LILAM ist ein spezialisiertes Framework für tiefe Einblicke in Prozesse. Mit `MARK_EVENT` und den `TRACE`-Funktionen werden benannte Actions unabhängig voneinander überwacht. Das Framework führt Metriken automatisch **je Action und Context**:

* **Unabhängige Statistiken:** Überwache mehrere Aktivitäten (z. B. XML_PARSING, FILE_UPLOAD) gleichzeitig.
* **Events zu einem Zeitpunkt:** Verfolge Meilensteine und berechne mit `MARK_EVENT` die Abstände zwischen wiederkehrenden Schritten.
* **Messwerte:** Übergib mit `MARK_EVENT` einen numerischen Wert (z. B. einen Aktienkurs: `lilam.mark_event(l_pid, 'SHARE', 'ARAL', 80.71)`). LILAM führt für die Werte einen eigenen gleitenden Durchschnitt und prüft sie mit `VAL_`-Regeln (feste Grenzen und Abweichungen vom Verlauf).
* **Transaktions-Tracing:** Miss mit `TRACE_START` und `TRACE_STOP` Arbeitsblöcke präzise und behalte lang laufende Aufgaben im Blick.
* **Gleitende Durchschnitte & Ausreißer:** LILAM führt historische Vergleichswerte, um Performance-Einbrüche oder ungewöhnliche Laufzeiten (Ausreißer) in Echtzeit zu erkennen.
* **Minimaler Aufwand im Client:** Metrikberechnungen werden in der Session gepuffert, um Datenbankzugriffe gering zu halten.

#### Intelligente Metrikberechnung
Statt aufwendiger Aggregationen über Millionen von Monitor-Einträgen nutzt LILAM eine inkrementelle Berechnung. Metriken wie Durchschnitte und Zähler werden laufend aktualisiert. Dadurch bleiben Monitoring-Dashboards (z. B. in Grafana, APEX oder Oracle JET) auch bei sehr großen Datenmengen schnell.


### Kernstärken

#### Skalierbarkeit & Cloud-Tauglichkeit
Da LILAM ohne Dateisystem (`UTL_FILE`) auskommt und auf native Datenbankfunktionen setzt, eignet es sich für skalierbare Cloud-Infrastrukturen.

#### Entwicklererfahrung (DX)
LILAM fördert in Entwicklungsteams eine einheitliche Kultur für Fehlerbehandlung und Monitoring. Die einfache API erlaubt einen Start ohne Konfiguration, sodass Entwickler in wenigen Minuten professionelle Observability einbauen können. Es sind weder umfangreiche DBA-Rechte noch zusätzliche Infrastruktur nötig: Standardrechte für PL/SQL vergeben, Package einspielen und sofort loggen.

---
## Prozessverfolgung & Monitoring
LILAM ordnet Daten nach ihrem Verwendungszweck ein, um Statusabfragen und Analysen so schnell wie möglich zu machen:
* **Lebenszyklus & Fortschritt (Master):** Ein dauerhafter Datensatz je Prozesslauf. Er beantwortet in Echtzeit: Was läuft gerade? Wie weit ist der Fortschritt (Schritte erledigt/geplant)? Wie ist der Gesamtstatus?
* **Monitoring & Metriken:** Verfolgt einzelne Arbeitsschritte (Actions) innerhalb eines Prozesses. Diese Ebene erfasst Performance-Daten wie Ausführungsdauer, Anzahl der Durchläufe und durchschnittliche Verarbeitungszeiten.
* **Logging (Historie):** Das übliche betriebliche Protokoll. Speichert Log-Einträge mit Severity, Zeitstempel und technischen Metadaten (Error Stacks, Benutzerkontext) für die Fehlersuche.

### Regelbasierte Observability & Orchestrierung
LILAM protokolliert Daten nicht nur, es wertet sie auch aus. Mit versionierten JSON-Rule-Sets überwacht LILAM Prozessänderungen und Geschäftstransaktionen in Echtzeit.

* **Versionierte Logik:** Jede Servergruppe nutzt ihr eigenes Rule Set in ihrer eigenen Version, ideal für Paralleltests oder eine schrittweise Einführung in getrennten Gruppen.
* **Sofortige Alerts:** Verstöße lösen unmittelbar Alerts aus, die von unabhängigen Consumern verarbeitet werden.
* **Entkopplung:** Durch die Trennung von Alert-Erzeugung und Verarbeitung bleibt LILAM schlank und dient als leistungsstarker Orchestrator für nachgelagerte Anwendungslogik.


### Die wichtigsten Vorteile:
* Keine Aggregation nötig: Statusabfragen brauchen keine aufwendigen GROUP-BY-Operationen über Millionen von Zeilen.
* Sofortige Transparenz: Engpässe sind über die aufgezeichneten Action-Metriken sofort erkennbar.
* Zentrale Konfiguration: Log-Level und Zieltabellen werden über den Master-Datensatz verwaltet.

---
### How-To: Das U-Bahn-Beispiel
Um zu zeigen, wie LILAM arbeitet, stell Dir die Überwachung eines U-Bahn-Systems vor:

**Prozess (TRACK_LINE_4):** Der gesamte Einsatz bzw. die Fahrt einer bestimmten Linie.

**Event (CLOSE_DOOR):** Ein einzelner Zeitpunkt. Wir markieren dieses Event an einer bestimmten Station (STATION_ID_400). Hat ein Pflicht-Event vor dem nächsten nicht stattgefunden, kann LILAM einen Alert auslösen (PRECEDED_BY).

**Trace/Transaktion (TRACK_SECTION):** Ein zeitlicher Abschnitt, der die Fahrt zwischen zwei Punkten abbildet (z. B. SECTION_ID_402). Mit trace_start und trace_stop messen wir automatisch die Fahrzeit (y).

#### Kennung des laufenden Prozesses
```sql
  l_processId NUMBER;
```
#### Prozess starten und Prozesswerte setzen
```sql
  -- Einsatz als neuen Prozess starten.
  -- Dieser und alle weiteren Aufrufe kehren in Mikrosekunden zurück, weil der LILAM-Proxy die Arbeit sofort an den asynchronen Worker abgibt.
  -- Optionale Trennung über Gruppen: LILAM Server lassen sich bestimmten Gruppen zuordnen, um Arbeitslasten strikt zu trennen
  l_processId := lilam.server_new_process(p_processName => 'TRACK_LINE_4', p_groupName => 'UNDERGROUND_MONITORING', p_logLevel => lilam.logLevelMonitor);

  -- Anzahl der Schritte setzen, die dieser Einsatz für einen korrekten Abschluss braucht
  -- In unserem Beispiel gibt es nur zwei Schritte: Station verlassen und Station erreichen
  lilam.set_proc_steps_todo(p_processId => l_processId, p_procStepsToDo => 2);
  
  -- Station verlassen
  lilam.proc_step_done(p_processId => l_processId); -- erhöht den Schrittzähler auf `1`
```

#### Action überwachen (Metrik) und loggen
```sql
  -- Türen müssen geschlossen sein (Event)
  lilam.mark_event(p_processId => l_processId, p_actionName => 'CLOSE_DOOR', p_contextName => 'STATION_ID_400');

  -- Fahrtbeginn loggen
  lilam.info(p_processId => l_processId, p_logText => 'Linie 4 verlässt das Depot');
```

#### Geschäftstransaktionen verfolgen
```sql
  -- Abschnitt befahren (Transaktion durch Starten und Stoppen messen)
  lilam.trace_start(p_processId => l_processId, p_actionName => 'TRACK_SECTION', p_contextName => 'SECTION_ID_402');
  dbms_session.sleep(30); -- der Zug brauchte 30 Sekunden
  lilam.trace_stop(p_processId => l_processId, p_actionName => 'TRACK_SECTION', p_contextName => 'SECTION_ID_402');
```
#### Prozess schließen
```sql
  -- Der Einsatz der Linie ist sehr(!) kurz, nur ein Abschnitt; er endet also hier
  --   !  fehlender Code: lilam.proc_step_done(p_processId => l_processId); -- erhöht den Schrittzähler auf `2`
  lilam.info(p_processId => l_processId, p_logText => 'Linie 4 ist zurück');
  lilam.close_process(p_processId => l_processId);

  -- Der Schrittzähler steht noch auf `1`. Gäbe es ein Rule Set, das am Ende des Einsatzes
  -- 2 Schritte erwartet, würde LILAM einen `ALERT` auslösen
```
---
## Daten
LILAM speichert seine Daten in drei Tabellen je Anwendung. Ihre Namen werden aus `p_tabNameMaster` abgeleitet (Standard `LILAM`): `LILAM_PROC`, `LILAM_LOG` und `LILAM_MON`. Die Tabellen werden beim ersten API-Aufruf automatisch angelegt.
Die folgenden Darstellungen zeigen die wesentlichen Inhalte; je nach LILAM-Version können weitere Spalten vorhanden sein. Die vollständige Struktur steht in [Architektur und Konzepte](docs/Architektur%20und%20Konzepte.md#tabellen).

### Prozessdaten
Eine Zeile je Prozesslauf; sie liefert den aktuellen Status des Prozesses.
```sql
SELECT id, process_name, process_start, process_end, last_update, steps_todo, steps_done, status, info
FROM   lilam_proc
WHERE  process_name = 'MY_PROCESS';
```

>| ID | PROCESS_NAME | PROCESS_START         | PROCESS_END           | LAST_UPDATE           | STEPS_TODO | STEPS_DONE | STATUS | INFO
>| -- | ------------ | --------------------- | --------------------- | --------------------- | ---------- | ---------- | ------ | ------
>| 1  | MY_PROCESS   | 12.01.26 18:17:51,... | 12.01.26 18:18:53,... | 12.01.26 18:18:53,... | 100        | 99         | 2      | ERROR


### Logging-Daten
```sql
SELECT process_id, no, info, log_level_c, session_time, session_user, host_name, err_stack, err_backtrace, err_callstack
FROM   lilam_log
WHERE  process_id = <id>
ORDER  BY no;
```

>| PROCESS_ID | NO | INFO               | LOG_LEVEL_C | SESSION_TIME    | SESSION_USER | HOST_NAME | ERR_STACK        | ERR_BACKTRACE    | ERR_CALLSTACK    |
>| ---------- | -- | ------------------ | ----------- | --------------- | ------------ | --------- | ---------------- | ---------------- | ---------------- |
>| 1          | 1  | Start              | INFO        | 13.01.26 10:... | SCOTT        | SERVER1   | NULL             | NULL             | NULL             |
>| 1          | 2  | Function A         | DEBUG       | 13.01.26 11:... | SCOTT        | SERVER1   | NULL             | NULL             | "--- PL/SQL ..." |
>| 1          | 3  | Something happened | ERROR       | 13.01.26 12:... | SCOTT        | SERVER1   | "--- PL/SQL ..." | "--- PL/SQL ..." | "--- PL/SQL ..." |

### Monitoring-Daten
Events (`MON_TYPE` = 0) und Traces (`MON_TYPE` = 1) teilen sich eine Tabelle. `STOP_TIME` bleibt bei Events `NULL`.
```sql
SELECT process_id, mon_type, action, context, start_time, stop_time, used_millis, used_millis_ewma, action_count
FROM   lilam_mon
WHERE  process_id = <id>;
```

>| PROCESS_ID | MON_TYPE | ACTION    | CONTEXT    | START_TIME      | STOP_TIME       | USED_MILLIS | USED_MILLIS_EWMA | ACTION_COUNT |
>| ---------- | -------- | --------- | ---------- | --------------- | --------------- | ----------- | ---------- | ------------ |
>| 1          | 0        | MY_ACTION | MY_CONTEXT | 13.01.26 10:... | NULL            | 402         | 402        | 1            |
>| 1          | 0        | MY_ACTION | MY_CONTEXT | 13.01.26 10:... | NULL            | 510         | 456        | 2            |
>| 1          | 1        | TRANS_ACT | ROUTE_1    | 13.01.26 10:... | 13.01.26 10:... | 490         | 490        | 1            |

---
## Repository-Struktur
Wo die Kernkomponenten liegen:

* **[/source/package](/source/package)** – Der PL/SQL-Quellcode von LILAM als API, Server und Proxy.
* **[/docs](/docs)** – API-Referenz, vertiefende Architekturbeschreibungen und Setup-Anleitung.
* **[/rules](/rules)** – Ausführliche Dokumentation der Regelmechanik: [Rules Engine](./rules/README_DE.md) und [JSON-Beispiel](./rules/metro_rule_set_v1.json).
* **[/consumer](/consumer)** – Einfache „Vorlage“ für Alert-Consumer mit einem einsatzbereiten Mail-Consumer

---
## Performance-Benchmark
LILAM wurde auf einem handelsüblichen Notebook (Fujitsu LIFEBOOK A357, Intel Core i5-7200U, 16 GB RAM) mit **Oracle AI Database 26ai Free** in einer VirtualBox-VM gemessen. Die Free-Edition erlaubt höchstens **2 CPU-Threads** für alle Sessions zusammen (Anwendungen, LILAM Server und die Messung). Die absoluten Zahlen sind daher eine Untergrenze; auf einem Datenbankserver mit mehr CPU-Threads und schnellem Redo-Speicher sind deutlich bessere Werte zu erwarten.

*   **Kosten je Aufruf:** Ein LILAM-Aufruf kostet die Anwendung in beiden Modi **25–100 µs** (Median).
*   **Vergleich:** Für denselben INFO-Eintrag brauchte LILAM **26 µs** (In-Session) bzw. **50 µs** (entkoppelt), OraOpenSource Logger 3.1.1 brauchte **1,4 ms** (Median). Beide verfolgen verschiedene Ziele: Logger committet jeden Eintrag, bevor der Aufruf zurückkehrt, LILAM puffert oder entkoppelt.
*   **Vollständigkeit:** In keiner der 13 Varianten des Performance-Tests ging ein Eintrag verloren (bis zu 3 Clients × 100.000 Aufrufe, 1–3 Server, In-Session und entkoppelt).
*   **Sichtbarkeit:** Bei normaler Last stehen alle Daten wenige Zehntelsekunden bis etwa 2 Sekunden nach dem letzten Aufruf in der Datenbank.

Die im Bericht beschriebenen langen Einzelaufrufe unter Überlast sind inzwischen behoben: Der Client wartet nicht mehr auf Antworten des Servers.

Details (Aufrufarten, Latenz-Perzentile, Kosten des Failovers) stehen im vollständigen Bericht:
*   [Performance-Bericht](./performance-report-deu.md)

---
## Lizenz
Dieses Projekt steht unter zwei Lizenzen:
- Für die **Open-Source**-Nutzung: [GPLv3](LICENSE)
- Für die **kommerzielle** Nutzung (interner Produktivbetrieb oder Einbettung in Software): [LILAM Enterprise License](LICENSE_ENTERPRISE.md)

*Möchtest Du LILAM in einer proprietären Umgebung ohne die „Copyleft“-Pflichten der GPL einsetzen, sprich mich bitte wegen einer kommerziellen Lizenz an.*

---
## Roadmap
- [X] **Automatisches Failover:** Clients wechseln zum nächsten verfügbaren Server der Gruppe und senden noch nicht committete Meldungen erneut
- [ ] **Schrittweiser Rückfall:** Vom entkoppelten in den In-Session-Modus wechseln, wenn kein Server verfügbar ist
- [X] **Prozesse fortsetzen:** Einen offenen Prozess über die `process_id` aus einer anderen Datenbanksession fortführen (z. B. APEX/ORDS-Requests über den Dispatcher)
- [X] **Aufbewahrung:** Prozessdaten lassen sich mit dem Kennzeichen „immortal“ vor dem Löschen schützen
- [ ] **Adaptives Batching:** Puffergrößen und Flush-Intervalle abhängig von der Serverlast dynamisch anpassen, um bei geringem Verkehr nahezu Echtzeit-Sichtbarkeit und in Spitzen maximalen Durchsatz zu erreichen
- [ ] **Umgang mit Zombie-Sessions:** Inaktive Clients erkennen, belegten Speicher freigeben und Prozessstatus automatisch aktualisieren
- [ ] **Eindeutige Server erzwingen:** Verhindern, dass sich mehrere Server unter demselben Namen registrieren, um die Integrität der Nachrichten zu sichern und Konflikte zwischen Prozessen zu vermeiden
- [ ] **Robuste Lastverteilung:**
    * Clients verbinden sich neu, wenn ein anderer Server mit geringerer Last verfügbar ist
    * Clients verbinden sich neu, wenn der Server 'DRAIN_AND_RECONNECT' oder 'RECONNECT' sendet
- [ ] **Dynamische Performance-Konfiguration:** Serverparameter zur Laufzeit ändern
- [X] **Ereignisgesteuerte Orchestrierung:**
    * Automatisierte **Aktionen** auf Basis definierter Metrik-Schwellen oder Event-Typen auslösen
    * Nahtlose **Prozessverkettung** ermöglichen, bei der Abschluss oder Zustand einer Aktion nachfolgende Logik auslöst
- [X] **Intelligente Alert-Logik:** Anomalieerkennung verfeinern, um mit konfigurierbaren Rauschgrenzen unbedeutende Mikroschwankungen (z. B. Millisekunden-Jitter) von echten Performance-Rückschritten zu unterscheiden
- [ ] **Elastische Ressourcenverwaltung:**
    * LILAM-Server-Instanzen anhand des Pipe-Durchsatzes in Echtzeit automatisch skalieren
    * Überzählige Instanzen geordnet herunterfahren, um CPU und SGA ohne Datenverlust freizugeben
- [ ] **Aktive Sessions auflisten:** Liste aller aktiven Sessions, Pipes usw. abrufen
- [x] **JSON-Signaturen:** Header-Informationen auch als geloggte Werte in den Server übertragen


---
### Unterstütze das Projekt 💜
Findest Du **LILAM** nützlich? Mit einem Sponsoring unterstützt Du die weitere Entwicklung und die langfristige Pflege des Projekts.

[![Beer](https://img.shields.io/badge/Buy%20me%20a%20beer-LILAM-purple?style=for-the-badge&logo=buy-me-a-coffee)](https://github.com/sponsors/dirkgermany)


