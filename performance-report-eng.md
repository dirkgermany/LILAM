# LILAM Performance Report

**As of:** 13 October 2026, branch `fallback` (with failover, code state f6dcd44)
**Basis:**
- Performance test (run 2344)
- Comparison with OraOpenSource Logger 3.1.1
- CPU measurement of the failover code

The measurement scripts are located under `test/autotest/PERFORMANCE/`.

This report replaces the earlier stress test report (4 million calls, Oracle 21c Free). The earlier report is preserved in the Git history.

## At a Glance

- **A LILAM call costs the application 25 to 100 µs (median)**, in both operating modes. Under normal load everything is in the database a few tenths of a second up to about 2 s after the last call; with the servers overloaded it can take longer.
- **In normal operation LILAM is more than an order of magnitude faster than a logging tool that commits every entry immediately.**
  - OraOpenSource Logger 3.1.1 needed 1.4 ms (median) for the same INFO entry.
  - LILAM needed 26 µs (INSESSION) or 50 µs (DECOUPLED).
  - The two systems follow different goals: Logger guarantees every entry when the call returns, LILAM buffers or decouples.
- **Stability:** No entry was lost in any of the 13 variants of the performance test. Under continuous fire with more load than the servers can process, however, **single calls can wait for up to 10 s**. This is open (see "Stability under Overload").
- **The failover costs computing time:** server +10 %, client +11 % CPU per message compared with the state without failover.

## Environment

| | |
|---|---|
| Machine | Fujitsu Lifebook A357, Windows 11 Home; Intel Core i5-7200U (2 cores, 4 logical processors), 16 GB RAM, SSD |
| Database | Oracle AI Database 26ai Free 23.26.0.0.0 in a VirtualBox VM (Oracle Linux 8.10) |
| Limit of the Free edition | at most **2 CPU threads** for all sessions: applications (clients), LILAM servers and the measurement share them |
| LILAM server | Performance level MID (1,500 messages/s per process; above that the client slows down briefly) |

The absolute numbers apply only to this small environment, and they vary widely: identical code delivered up to twice as much between two runs of the same test (e.g. 17,417 and 36,037 operations in LASTSPITZE). What is meaningful are the ratios between variants measured directly after each other. On a database server with more CPU threads and fast redo storage all values can be expected to be considerably better, above all the throughput of the servers.

## What a Call Costs the Application

Performance test (`test/autotest/PERFORMANCE/test_performance.sql`, run 2344, total runtime 21:21 min):
- Each client is a database session of its own and calls LILAM in a realistic mix. Per 100 calls these are 44 INFO, 4 WARN, 1 ERROR, 10 TRACE_START, 10 TRACE_STOP, 15 MARK_EVENT, 10 PROC_STEP_DONE and 6 SET_PROCESS_STATUS.
- Every call is measured individually.
- "Continuous fire": the clients call without a pause.
- "With pauses": a 100 ms pause after every 20 calls, like an application that does other work in between.

| Variant | Clients × calls | Calls/s (application) | Call median | Call 99 % | Call maximum | everything stored after |
|---|---|---|---|---|---|---|
| INSESSION, continuous fire | 3 × 100,000 | 10,563 | 50 µs | 5 ms | 300 ms | 30 s |
| INSESSION, with pauses | 3 × 25,000 | 518 | 50 µs | 6 ms | 400 ms | 146 s |
| DECOUPLED 1 server, continuous fire | 3 × 100,000 | 2,582 | 80 µs | 5 ms | **10,000 ms** | 117 s |
| DECOUPLED 2 servers, continuous fire | 3 × 100,000 | 2,230 | 80 µs | 7 ms | **10,000 ms** | 136 s |
| DECOUPLED 3 servers, continuous fire | 3 × 100,000 | 2,730 | 70 µs | 4 ms | **6,600 ms** | 112 s |
| DECOUPLED 1 server, with pauses | 3 × 25,000 | 525 | 100 µs | 6 ms | 300 ms | 144 s |
| DECOUPLED 2 servers, with pauses | 3 × 25,000 | 545 | 90 µs | 3 ms | 49 ms | 138 s |
| DECOUPLED 3 servers, with pauses | 3 × 25,000 | 540 | 90 µs | 3 ms | 92 ms | 139 s |
| DECOUPLED 2 servers, continuous fire, 100 logoffs/logons | 3 × 100,000 | 4,511 | 80 µs | 4 ms | 2,400 ms | 68 s |

"Everything stored after" counts from the first call. After the **last** call it took at most 2.4 s in these variants, under load with pauses at most 1.1 s.

**Individual call types** (median):
- INFO 50 µs (INSESSION) or 90–120 µs (DECOUPLED)
- TRACE_START/STOP, MARK_EVENT, PROC_STEP_DONE, SET_PROCESS_STATUS 30–90 µs
- ERROR 6–9 ms INSESSION. ERROR is written immediately with a commit (sync level), DECOUPLED about 2 ms.
- NEW_PROCESS mostly 15–70 ms, individually up to 200 ms (registration with the server or creation of the table rows)
- CLOSE_PROCESS DECOUPLED 40–110 µs. It no longer waits for the server; previously up to a good 1 s.

### Rules

5 clients × 10,000 calls, continuous fire, rule set with 13 rules that match the call mix:

| Variant | Calls/s | Call median | Call 99 % |
|---|---|---|---|
| INSESSION without rules | 14,286 | 50 µs | 4 ms |
| INSESSION with rules | 12,500 | 70 µs | 4 ms |
| DECOUPLED, 2 servers, without rules | 2,092 | 2 ms | 14 ms |
| DECOUPLED, 2 servers, with rules | 2,058 | 3 ms | 14 ms |

Rules cost about 20 µs per call in INSESSION. In DECOUPLED mode the server checks the rules; no difference was measurable there.

With 5 clients on 2 servers, the clients slow down under continuous fire (median 2–3 ms) because the servers cannot work off the load any faster. After the last call the servers still needed 11–13 s until everything was written (everything stored after 36–37 s).

## Comparison with OraOpenSource Logger

**Question:** With all its mechanisms (buffers, messages, ring buffer, failover, rules), is LILAM faster in normal operation than a widely used logging tool at all?

**Measurement:** `test/autotest/PERFORMANCE/2026-10-13_vergleich_logger_a_lilam.sql` and `..._b_logger.sql`.
- One session writes 10,000 entries of level INFO with 120 characters of text.
- The duration of every call is measured.
- Three rounds, LILAM and Logger alternating. The median of the rounds is given.
- Logger 3.1.1 (last release 2017) ran in a schema of its own with the settings after installation (level DEBUG). The application calls it statically.

| Variant | Call median | Call 99 % | Mean | stored after the last call |
|---|---|---|---|---|
| LILAM INSESSION, buffered (default) | **26 µs** | 191 µs | 43 µs | 0.6 s |
| LILAM DECOUPLED, 1 server, buffered (default) | **50 µs** | 1.3 ms | 255 µs | 0.3 s |
| Pattern "insert + commit per entry" without a framework | 113 µs | 4.5 ms | 426 µs | immediately |
| **Logger 3.1.1** `logger.log_info` | **1,355 µs** | 6.7 ms | 1,777 µs | immediately |

**Result:**
- In normal operation LILAM is about **50 times (INSESSION) or 27 times (DECOUPLED) faster per call than Logger**, in each case by median.
- Logger is also considerably slower than a bare "insert + commit" (113 µs). Its cost therefore comes not only from the commit but from what it additionally captures and checks per entry: call stack, context, settings.

**Assessment:**
- The systems give different guarantees. Logger has committed the entry when the call returns; the application bears the cost of that.
- LILAM buffers (INSESSION) or sends the entry off and keeps working (DECOUPLED).
  - Buffered data is lost if the session or the server crashes, unless it was committed before.
  - With the failover, another worker takes over in DECOUPLED mode; the client repeats from its ring buffer.
  - Entries up to the sync level (default: ERROR) are committed immediately by LILAM as well.
- The mean of LILAM DECOUPLED (255 µs) is well above the median. Single calls wait when the client slows down briefly because of the performance level.

## Stability under Overload

- **Completeness:** In all 13 variants of the performance test all logs, traces, events and process closures arrived.
- **Long single calls under continuous fire:** If several clients send without a pause more than the servers can work off, a single call in rare cases waits very long. This was measured in the continuous fire variants:
  - up to **10 s** if the client waits for the release by the overloaded server (slowdown according to the performance level)
  - up to **5 s** if the ring buffer of the client is full (20,000 messages not yet confirmed) and the client asks the server for the watermark
- **Ring buffer full:** In run 2344 this occurred in the variant "2 servers, continuous fire" for all three clients. The client then gives up the oldest messages in the ring buffer and records this in `LILAM_LOG_INTERNAL`. The messages themselves arrive; only with a simultaneous server failure could they not be repeated.
- Under load with pauses there were no such waiting times: longest single call 49–300 ms.

These waiting times are known and scheduled for revision (findings A1, A2 and F4 in the list of findings on the failover). Stability takes priority over throughput.

## Cost of the Failover

The failover (ring buffer in the client, sequence numbers and watermarks in the server) was measured against the state without failover (`main`).
- Measurement: CPU time of the sessions from `v$sesstat`, 50,000 calls each, 3 alternating rounds, median.
- Script: `2026-10-13_cpu_je_meldung.sql`

| State | Server CPU per message | Client CPU per call |
|---|---|---|
| without failover (`main`) | 136 µs | 61 µs |
| with failover, first version | 171 µs (+26 %) | 70 µs (+16 %) |
| with failover, optimized (current state) | 150 µs (+10 %) | 67 µs (+11 %) |

The optimization consisted mainly of reading the header of a message without `JSON_VALUE`. It was measured with the hierarchical profiler; report: `test/autotest/PERFORMANCE/results/2026-10-13_hprof_failover.md`.

A large part of the server's working time still goes into reading the message payload with `JSON_VALUE`; this also applies without failover. This is where the greatest remaining potential lies.

## Measure It Yourself

```sql
-- Performance test (approx. 22 min, run on its own only)
@test/autotest/_COMMON/01_install_testbasis.sql
@test/autotest/_COMMON/04_install_belastung.sql
@test/autotest/_COMMON/05_install_performance.sql
@test/autotest/PERFORMANCE/test_performance.sql

-- Comparison with Logger: install Logger 3.1.1 in a schema of its own, grant EXECUTE to the LILAM schema,
-- then run part A and part B alternately (see the header of the scripts)
@test/autotest/PERFORMANCE/2026-10-13_vergleich_logger_a_lilam.sql
@test/autotest/PERFORMANCE/2026-10-13_vergleich_logger_b_logger.sql
```

Run the measurements on their own only: other load in the database distorts the numbers.
