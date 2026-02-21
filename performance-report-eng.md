# 📊 LILAM Status Quo: Performance & Stress-Test Report

## 1. Hardware Specifications (Host)
*   **Model:** Fujitsu Lifebook A 357
*   **Processor (CPU):** Intel Core i5-7200U: 2.5GHz-2701 MHz (2 Cores / 4 Logical Processors)
*   **Memory (RAM):** 16 GB
*   **Storage:** 477 GB SSD (Base for High-Speed I/O)

## 2. Software Stack Setup
*   **Host OS:** Windows 11 Home
*   **Virtualization:** Oracle VM VirtualBox 7.2.4
*   **Guest OS:** Oracle Linux Server 8.10
*   **Database:** **Oracle Database 23ai Free Release 23.0.0.0.0 (v23.26)**

## 3. Database Resources & Limits (Status Quo)
*   **Instance RAM Total Limit:** **2.0 GB (Hard limit of Free License)**
*   **SGA (System Global Area):** 1,529.00 MB (Optimized for buffer caching)
*   **PGA (Available Balance):** approx. 519.00 MB (Shared memory for all sessions)
*   **vCPU Assignment:** 3 Cores (Assigned in VirtualBox)
*   **CPU Usage:** Database uses max. 2 threads (License-related bottleneck)

## 4. Resource Efficiency of the Worker Architecture
The analysis of resource consumption during the high-load phase demonstrates the scalability of the chosen architecture:

*   **SGA Usage (Pipe):** Memory usage within the SGA remained minimal despite massive data streams. This proves that the worker processes clear the pipes almost without delay, as long as no I/O blocks occur.
*   **PGA Efficiency (Memory):** By using `FORALL` (bulk processing), the memory consumption per session was kept consistently low. No memory leaks occurred even with 4 million records.
*   **CPU Profile:** The CPU load was primarily caused by context switching between PL/SQL and SQL as well as index maintenance (Pair 2). The rule evaluation itself (7 rules via associative array) generated no measurable CPU overhead.
*   **I/O Behavior (Redo):** The worker process transforms high logical throughput into massive physical I/O (approx. 4.5 GB of redo data). Persistence efficiency depends directly on the commit batch size (3x gain with 1000-record batches).

## 5. Throughput & Test Scenario
Scenario Objectives:
1. Determine latencies between log timestamp and physical commit in LILAM.
2. Measure performance during sequential write operations and parallel API events.
3. Validate data consistency under extreme Mixed Workload.

### Test Pair Setup
*   **Pair 1 (High Performance):** 1 Producer + 1 Worker. Loop with **4,000,000 calls**. 
    *   *Action:* API call + bulk writing to 3 tables (`REMOTE_LOG`, `REMOTE_LOG_MON`, `LILAM_ALERTS`).
*   **Pair 2 (Latency Measurement):** 1 Producer + 1 Worker. **100,000 calls**.
    *   *Action:* API call + writing to 2 tables + **single-row inserts** into `LATENZ_TEST` (indexed).


| Pair | Mode | Throughput (EPS) | Status |
| :--- | :--- | :--- | :--- |
| **Pair 1 (Bulk)** | `FORALL` | **~1,300 - 1,900** | Stable over 4M records |
| **Pair 2 (Latency)** | `Row-by-Row` | **~460 - 800** | Drop at ~450k (I/O saturation) |

## 6. Latency Visualization (Real-Time Capability)
Comparison of timestamps (Producer vs. Engine Entry).


| Metric | Value (Clean Run 100k) | Value (Heavy Load 4M) |
| :--- | :--- | :--- |
| **Average (Avg)** | **4.14 ms** | ~47,000 ms (Congestion phase) |
| **Maximum (Max)** | 2,037.96 ms | > 60,000 ms |
| **Jitter (StdDev)** | 510.19 | Extremely high (CPU saturation) |

### 📊 System Metrics (Post-Mortem Analysis)
Cumulative statistics of the Oracle instance after completion of the test series.

#### A. Resource Saturation (Wait Events)


| Event Name | Total Waits | Total Time (Sec.) | Cause |
| :--- | :--- | :--- | :--- |
| `library cache: mutex X` | 282,799 | **1,065.85** | CPU thread limit (23ai Free) |
| `library cache pin` | 602,926 | **488.94** | Concurrent PL/SQL access |
| `resmgr:cpu quantum` | 4,256 | **623.81** | Throttling by Resource Manager |
| `log file sync` | 116 | 2.48 | SSD acknowledgment (Commit) |

#### B. Data Throughput (I/O Statistics)


| Metric | Value |
| :--- | :--- |
| **Redo Size** | **4,499.18 MB** |
| **Physical Writes** | 99.10 MB |
| **Physical Reads** | 717.18 MB |

#### C. Latency Distribution (Mixed Workload Analysis)


| Latency Class | Share (%) | Evaluation |
| :--- | :--- | :--- |
| **< 5 ms (Real-Time)** | **52.04 %** | System baseline speed |
| **5 - 100 ms (Good)** | 12.52 % | Minor resource conflicts |
| **> 100 ms (Delayed)** | 35.44 % | Hardware saturation (I/O & threads) |

---
**Summary Evaluation:**
The metrics confirm **100% utilization of the Oracle Free Edition**. In particular, the high values in the `library cache` area clarify that the software architecture (LILAM) reached the physical management limits of the database instance. The system remained consistent at all times despite this massive saturation.

The LILAM engine demonstrates high algorithmic efficiency. Validation tests with and without an active rule set (7 rules via associative array) showed identical throughput rates. This proves that the logical processing layer generates negligible overhead compared to the physical I/O throughput of the hardware.
