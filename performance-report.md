# 📊 LILAM Performance & Stress-Test Report

## 1. Ausstattung der Hardware (Host)
*   **Modell:** Fujitsu Lifebook A 357
*   **Prozessor (CPU):** Intel Core i5-7200U: 2,5GHz-2701 MHz (2 Kerne / 4 logische Prozessoren)
*   **Arbeitsspeicher (RAM):** 16 GB
*   **Festplatte (Storage):** 477 GB SSD (Basis für High-Speed I/O)

## 2. Setup Software-Stack
*   **Host-OS:** Windows 11 Home
*   **Virtualisierung:** Oracle VM VirtualBox 7.2.4
*   **Gast-OS:** Oracle Linux Server 8.10
*   **Datenbank:** **Oracle AI Database 23.26.0.0.0**

## 3. Datenbank-Limits (Oracle 23 Free)
*   **Instanz-RAM Gesamtlimit:** **2,0 GB (Hard-Limit der Lizenz)**
*   **SGA (System Global Area):** 1.529 MB (Optimiert auf Buffer-Caching)
*   **PGA (verfügbarer Rest):** ca. 519 MB (Gemeinsamer Speicher für alle Sessions)
*   **vCPU:** 3 Kerne (In VirtualBox zugewiesen)
*   **CPU:** Verwendet max. 2 Threads (Engpass bei parallelen Workern)

## 4. Ressourcen-Effizienz der Worker-Architektur
Die Analyse des Ressourcenverbrauchs während der Hochlastphase (bis zu 2.800 EPS Gesamtlast) zeigt die Skalierbarkeit der gewählten Architektur:

*   **SGA-Nutzung (Pipe):** Die Speichernutzung innerhalb der SGA blieb trotz massiver Datenströme minimal. Dies belegt, dass die Worker-Prozesse die Pipes nahezu verzögerungsfrei leeren (Consumer-Geschwindigkeit > Producer-Geschwindigkeit), solange keine I/O-Sperren auftreten.
*   **PGA-Effizienz (Memory):** Durch den Einsatz von `FORALL` (Bulk-Processing) konnte der Arbeitsspeicherverbrauch pro Session konstant niedrig gehalten werden. Auch bei 4 Mio. Datensätzen trat kein Speicherleck auf.
*   **CPU-Profil:** Die CPU-Last wurde primär durch den Kontextwechsel zwischen PL/SQL und SQL sowie die Index-Pflege (Paar 2) verursacht. Die Regelprüfung selbst (7 Regeln via assoziatives Array) erzeugte keinen messbaren CPU-Overhead.
*   **I/O-Verhalten (Redo):** Der Worker-Prozess transformiert hohen logischen Durchsatz in massiven physischen I/O (ca. 4,5 GB Redo-Daten). Die Effizienz der Persistierung hängt hierbei direkt von der Batch-Größe des Commits ab (Faktor 3 Gewinn bei 1000er-Batches).


## 5. Durchsatz & Testszenario
Das Test-Szenario hatte drei Ziele:
1. Ermittlung der Latenzen zwischen Zeitpunkt von Logs, Metriken und Prozessänderungen und dem sicheren Persistieren in die LILAM-Tabellen (commit).
2. Performance eines simulierten Clients, der abwechseln Daten sequentiell in eine Tabelle schreibt und über die API von LILAM Events meldet.
3. Prüfen der Konsistenz (alle Messpunkte müssen am Ende persistiert sein).

Das Szenario simulierte somit eine extreme Mischlast (Mixed Workload).

### Setup des Szenarios
Der Testaufbau bestand aus zwei 'Paaren' von je einem LILAM-Client (Produzent) und einem LILAM-Server (Worker).
Im ersten Paar wurden direkt und ohne Unterbrechung Logs, Metriken und Statusänderungen eines Prozesses gemeldet.
Im zweiten Paar wurden von einem Client Messpunkte an einen Server geschickt, deren Zeitstempel unmittelbar davor in eine Tabelle geschrieben wurden. Gleichzeitig arbeitete dieser Server mit einem geladenen Regelsatz (s. Zusammenfassende Bewertung).

*   **Paar 1 (High Performance):** 1 Produzent + 1 Worker. Loop mit **4.000.000 Aufrufen**. 
    *   *Aktion:* API-Call + Bulk-Schreiben in 3 Tabellen (`REMOTE_LOG`, `REMOTE_LOG_MON`, `LILAM_ALERTS`).
*   **Paar 2 (Latenz-Messung):** 1 Produzent + 1 Worker. **100.000 Aufrufe**.
    *   *Aktion:* API-Call + Schreiben in 2 Tabellen (`REMOTE_LOG`, `REMOTE_LOG_MON`) + **Einzel-Inserts** in `LATENZ_TEST` (indiziert).

### Messergebnisse (Durchsatz)

| Paar | Verarbeitungs-Modus | Durchsatz (EPS) | Status |
| :--- | :--- | :--- | :--- |
| **Paar 1 (Bulk)** | `FORALL` (1000er Batch) | **~1.300 - 1.900** | Stabil über 4 Mio. Datensätze |
| **Paar 2 (Latenz)** | `Row-by-Row` | **~460 - 800** | Einbruch bei ~450k (I/O Sättigung) |

*Hinweis: Der Durchsatz von Paar 2 stieg nach Umstellung auf 1.000er Commits um den **Faktor 3** an.*

## 6. Darstellung der Latenz (Echtzeit-Fähigkeit)
Gemessen durch den Zeitstempel-Vergleich zwischen Producer (`LATENZ_TEST`) und Engine-Eingang (`REMOTE_LOG_MON`).

| Metrik | Wert (Clean Run 100k) | Wert (Dauerlast 4M) |
| :--- | :--- | :--- |
| **Durchschnitt (Avg)** | **4,14 ms** | ~47.000 ms (Stau-Phase) |
| **Maximum (Max)** | 2.037,96 ms | > 60.000 ms |
| **Jitter (StdDev)** | 510,19 | Extrem hoch (CPU Sättigung) |

### Fazit der Latenzmessung
Die LILAM-Engine ist im Kern **hochperformant (4,14 ms Basis-Latenz)**. Die Latenzsteigerung unter Dauerlast ist ein rein physikalischer Effekt: Das Notebook-I/O und das 2-Thread-Limit der 21c Free Edition führen bei Überlastung zur Stau-Bildung in den Pipes. Durch die implementierte **Flusssteuerung (Backpressure/Handshake)** blieb das Gesamtsystem jedoch zu jeder Zeit konsistent und stabil.
Die in 

### 📊 System-Metriken (Post-Mortem Analyse)
Nach Abschluss der Testreihen wurden die kumulierten Statistik-Werte der Oracle-Instanz ausgewertet. Diese spiegeln die Gesamtbelastung der Hardware nach mehreren Durchläufen des Stress-Tests wider.

#### A. Ressourcen-Sättigung (Wait Events)
Die Top-Wartezeiten zeigen die interne Koordination der CPU-Threads bei Hochlast.

| Event Name | Total Waits | Zeit gesamt (Sek.) | Average Wait ms | Ursache |
| :--- | :--- | :--- | :--- | :--- |
| `library cache: mutex X` | 282799 | **1.065,85** | 0,04 | CPU-Thread-Limit (Oracle 21c Free) |
| `library cache pin` | 602926 | **488,94** | 0,01 | Gleichzeitiger Zugriff auf PL/SQL Objekte |
| `resmgr:cpu quantum` | 4256 | 623,81 | 1,47 | Drosselung durch Resource Manager |
| `log file sync` | 116 | 2,48 | 0,21 | Warten auf SSD-Quittierung (Commit) |

#### B. Datendurchsatz (I/O Statistik)
Physische Last, die durch die 5 Millionen Transaktionen auf dem Notebook-Speicher generiert wurde.


| Metrik | Wert (MB) | Beschreibung |
| :--- | :--- | :--- |
| **Redo Size** | 4499,18 MB | Gesamtvolumen der generierten Änderungsprotokolle |
| **Physical Writes** | 99,1 MB | Tatsächlich auf die SSD geschriebene Datenmenge |
| **Physical Reads** | 717,18 MB | Von der SSD gelesene Daten (z.B. für Index-Abgleiche) |

*Analyse:* Ein hohes Redo-Volumen bei gleichzeitig hoher EPS-Rate (2.800+) verdeutlicht die enorme Schreiblast, die das Notebook-I/O bewältigen musste.

#### C. Speicher-Zustand (SGA / Shared Pool)
Zustand des Arbeitsspeichers nach der massiven Befüllung des Library Cache.

| Pool / Name | Wert (MB) | Status |
| :--- | :--- | :--- |
| **Shared Pool Total** | **563,22 MB** | Reserviert für SQL & Pipes |
| **Free Memory** | 136,4 MB | Verbleibende Reserve im Shared Pool |
| **Total SGA** | **1.129,69 MB** | Fest belegter RAM-Block im Notebook |


#### D. Latenz-Verteilung (Analyse Mischlast)
Die statistische Auswertung zeigt die Performance der Engine während eines parallelen Stresstests (1.300 EPS Hintergrundlast).


| Latenz-Klasse             | Anzahl Events | Anteil (%) | Bewertung                     |
| :------------------------- | :------------ | :--------- | :---------------------------- |
| **< 5 ms (Echtzeit)**      | 52.044        | **52,04 %**| System-Basisgeschwindigkeit   |
| **5 - 20 ms (Sehr gut)**   | 1.721         | 1,72 %     | Minimale CPU-Wartezeit        |
| **20 - 100 ms (Gut)**      | 10.802        | 10,80 %    | Leichte Ressourcen-Konflikte  |
| **100 - 500 ms (Verz.)**   | 20.355        | 20,36 %    | 2-Thread Limit (Oracle Free)  |
| **> 500 ms (Stau/I/O)**    | 15.078        | 15,08 %    | SSD / Redo-Log Sättigung      |

**Interpretation der Ergebnisse:**
Trotz massiver künstlicher Überlastung durch ein paralleles Producer-Paar verarbeitet die LILAM-Engine über **52 % aller Ereignisse in echter Echtzeit (< 5 ms)**. 

Die signifikanten Anteile in den höheren Latenz-Klassen (> 100 ms) sind direkt auf die physikalischen Limitierungen der Testumgebung zurückzuführen:
1. **CPU-Flaschenhals:** Das 2-Thread-Limit der Oracle Free Edition erzwingt bei paralleler Last (Mischlast) Wartezeiten im OS-Scheduler.
2. **I/O-Sättigung:** Die Erzeugung von knapp 4,5 GB Redo-Daten führt zu periodischen Schreibpausen der Notebook-SSD (Log File Sync), was die Ausreißer im Bereich > 500 ms erklärt.

*Analyse:* Während im unbelasteten Referenzlauf (Clean Run) über 95% der Events in unter 10ms verarbeitet wurden, belegt der Mischlast-Test, dass selbst bei extremer Hardware-Sättigung der Großteil der Daten verzögerungsfrei persistiert wird. Ausreißer korrelieren hierbei exakt mit den physischen Log-Switches der Datenbank.

---
**Zusammenfassende Bewertung:**
Die Metriken belegen eine **100%ige Auslastung der Oracle Free Edition**. Insbesondere die hohen Werte im Bereich `library cache` verdeutlichen, dass die Software-Architektur (LILAM) die physikalischen Verwaltungsgrenzen der Datenbank-Instanz erreicht hat. Das System blieb trotz dieser massiven Sättigung zu jedem Zeitpunkt konsistent.

Die LILAM-Engine weist eine hohe algorithmische Effizienz auf. Validierungstests mit und ohne aktives Regelset (7 Regeln via Assoziativem Array) zeigten identische Durchsatzraten. Dies belegt, dass die logische Verarbeitungsebene im Vergleich zum physikalischen I/O-Durchsatz der Hardware vernachlässigbar geringen Overhead erzeugt. Das System ist somit für komplexe Regelwerke skalierbar, solange die I/O-Kapazität der Storage-Anbindung gewahrt bleibt.

