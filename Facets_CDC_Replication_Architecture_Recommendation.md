# Facets CDC & Replication Architecture Recommendation

**Date:** March 9, 2026  
**Status:** Draft — For Team Discussion  
**Scope:** Reporting replication pipeline redesign  

---

## Table of Contents

1. [Current State](#current-state)
2. [Pain Points](#pain-points)
3. [Options Analysis](#options-analysis)
   - [Option 1: Harden Current Architecture](#option-1-harden-current-architecture)
   - [Option 2: AG with CDC on Primary, Read from Secondary (Recommended)](#option-2-ag-with-cdc-on-primary-read-from-secondary)
   - [Option 3: Direct Log-Based CDC Tool](#option-3-direct-log-based-cdc-tool)
   - [Option 4: CDC on Primary, No AG](#option-4-cdc-on-primary-no-ag)
4. [Recommendation](#recommendation)
5. [CDC Impact on Primary — Honest Assessment](#cdc-impact-on-primary--honest-assessment)
   - [Transaction Log Retention](#1-transaction-log-retention)
   - [Capture Job CPU and I/O](#2-cdc-capture-job-cpu-and-io)
   - [Cleanup Job Impact](#3-cdc-cleanup-job-impact)
   - [1K+ Tables Specifically](#4-impact-on-1k-tables-specifically)
   - [Current State vs. CDC on Primary](#5-comparison-what-you-have-today-vs-cdc-on-primary)
6. [Tuning CDC for a Heavy Workload](#tuning-cdc-for-a-heavy-workload)
7. [Risk Matrix](#risk-matrix)
8. [Migration Path](#migration-path)
9. [Other Databases on the Reporting Server](#other-databases-on-the-reporting-server)

---

## Current State

```
Facets OLTP (Primary, multi-TB)
  │
  ├── Transactional Replication (1K+ tables) ──► Reporting DB (Subscriber)
  │                                                    │
  │                                                    ├── CDC ──► Airbyte ──► Abacus
  │                                                    └── CDC ──► CData Sync ──► Snowflake
  │
Other Source DBs ── Trans Repl ──► Same Reporting Server (other DBs)
```

- Facets OLTP is a multi-terabyte database with 1,000+ tables replicated via
  transactional replication to Reporting on a separate server.
- The reporting server also hosts databases replicated from other source systems
  via transactional replication.
- Reporting has SQL Server CDC enabled. CDC change data feeds two
  downstream consumers:
  - **Airbyte** delivers change data to **Abacus**.
  - **CData Sync** delivers change data to **Snowflake**.
- Management is hesitant to enable CDC directly on the Facets OLTP primary.
- Goals: reduce failures, enable continuous CDC, and simplify new table onboarding.

---

## Pain Points

| Pain Point | Impact |
|---|---|
| CDC on a transactional replication subscriber | Snapshot reinit drops/recreates tables — CDC breaks, capture metadata is lost, downstream consumers stall |
| Schema changes propagated through replication | DDL replication can invalidate CDC capture instances — requires manual re-enable |
| 3-hop latency (OLTP → Repl → CDC → Consumer) | Each hop adds a failure surface and lag |
| Adding new tables | 6-step manual process: add article → snapshot → apply → enable CDC → configure Airbyte → configure CData |
| 1K+ CDC capture instances on subscriber | Heavy log reader contention on a server that is already a replication subscriber for multiple databases |
| "Continuous CDC" goal | CDC cleanup/capture jobs on the subscriber compete with replication distribution agent writes |

---

## Options Analysis

### Option 1: Harden Current Architecture

**Approach:** Keep `OLTP → Trans Repl → Reporting (CDC) → Consumers`.

- Add monitoring and alerting for CDC capture latency and replication agent status
- Script the "add table" workflow to reduce manual error
- Schedule CDC cleanup to avoid log bloat on the subscriber
- Use `sp_cdc_enable_table` with scripted re-enable after any snapshot reinit

**Verdict:** Band-aid. The architecture remains fundamentally fragile. Every
snapshot reinit is a CDC emergency. This is not a path to continuous CDC.

| Pros | Cons |
|---|---|
| No infrastructure changes | Core fragility remains |
| Low immediate effort | Snapshot reinit still breaks CDC |
| Buys time | Operational burden stays high |

---

### Option 2: AG with CDC on Primary, Read from Secondary

**Recommended**

```
Facets OLTP (AG Primary)
  │
  ├── CDC enabled here (capture job reads primary log)
  │
  └── AG sync ──► Readable Secondary
                      │
                      ├── Airbyte reads cdc.* tables ──► Abacus
                      └── CData reads cdc.* tables ──► Snowflake
```

**How it works:**

- CDC capture runs on the **primary** (log reader — similar overhead to the
  transactional replication log reader already running today).
- CDC change tables (`cdc.<schema>_<table>_CT`) are regular user tables — they
  replicate to the secondary via AG automatically.
- Airbyte and CData query the **readable secondary** — zero read impact on
  the primary.
- Transactional replication for Facets is **eliminated entirely**.

**Management concerns addressed:**

| Concern | Answer |
|---|---|
| "CDC on primary adds overhead" | You already have a log reader on primary (trans repl). CDC's log reader replaces it — net overhead is comparable, possibly lower since you eliminate the Distribution DB round-trip |
| "Read queries will hit production" | No — Airbyte/CData target the readable secondary. Primary sees zero query load from consumers |
| "Reduce failures" | Eliminates the fragile CDC-on-subscriber pattern. AG failover preserves CDC metadata automatically |
| "Continuous CDC" | CDC capture runs continuously on primary; change tables are always current on secondary |
| "New tables" | 3-step process: `sp_cdc_enable_table` on primary → configure Airbyte → configure CData. No snapshots, no articles, no distribution agent |

**New table onboarding (simplified):**

```sql
-- Step 1: On primary — one command
EXEC sys.sp_cdc_enable_table
    @source_schema      = 'dbo',
    @source_name        = 'NewTable',
    @role_name          = NULL,
    @supports_net_changes = 1;

-- Step 2: CDC tables auto-sync to secondary via AG
-- Step 3: Add table to Airbyte/CData connector config
```

Compare this to the current 6-step process with snapshot reinit risk.

**AG synchronization mode:**

- Same data center: **synchronous commit** for zero data loss
- Cross-datacenter: **asynchronous commit** with acceptable RPO
- For CDC consumer purposes, asynchronous is fine — Airbyte and CData already
  tolerate seconds of lag

| Pros | Cons |
|---|---|
| Eliminates trans repl + CDC-on-subscriber fragility | Requires AG setup (one-time effort) |
| Consumer reads isolated from primary via secondary | CDC capture runs continuously on primary — new cost during batch windows (see Impact section) |
| CDC metadata survives AG failover | AG requires Enterprise Edition (you already have it) |
| Trivial new table onboarding | CDC change table writes add I/O to primary data disks |
| Continuous CDC by design | |
| Uses technology you already own and license | |

---

### Option 3: Direct Log-Based CDC Tool

Replace both transactional replication and SQL Server CDC with a tool that reads
the Facets OLTP transaction log directly.

```
Facets OLTP ──► Qlik/HVR/GG reads t-log directly ──► Snowflake
                                                   ──► Abacus
```

**Candidates:**

- **Debezium** (open-source) — reads SQL Server transaction log, but still
  requires CDC enabled underneath
- **Qlik Replicate (Attunity)** — reads transaction log directly, no CDC required
- **HVR (Fivetran)** — same direct-log approach
- **Oracle GoldenGate for SQL Server** — if the team already has GG expertise

| Pros | Cons |
|---|---|
| Eliminates CDC, replication, and the middle server entirely | New licensing cost |
| Single hop from source to target | New tool to learn and operate |
| Vendor-supported change capture | Vendor dependency |
| Debezium is open-source | Debezium still requires CDC underneath |

**Verdict:** Technically clean, but introduces procurement, licensing, and a new
operational tool. Worth evaluating if budget exists, but Option 2 solves the
problem with existing technology.

---

### Option 4: CDC on Primary, No AG

Enable CDC on Facets OLTP primary and point Airbyte/CData directly at it.
Drop transactional replication.

| Pros | Cons |
|---|---|
| Simplest architecture, one hop | Consumer queries hit primary |
| Eliminates replication and subscriber | Management already ruled this out |

**Verdict:** Ruled out by management constraint (no consumer reads against primary).

---

## Recommendation

### Option 2 — AG with CDC on Primary, Read from Secondary

**Rationale:**

1. **Eliminates the single biggest failure mode.** CDC-on-subscriber-after-
   snapshot-reinit is the root cause of most downstream breaks today.

2. **Readable secondary isolates consumer workload from production OLTP.**
   Management's concern about query impact is fully addressed — Airbyte and
   CData never touch the primary.

3. **Adding tables becomes trivial.** One stored procedure call replaces a
   multi-step replication article/snapshot/CDC-enable/connector-configure workflow.

4. **You already own the technology.** SQL Server Enterprise includes AG. No new
   licensing.

5. **CDC metadata survives failover.** If the AG fails over, CDC is preserved on
   the new primary. Today, if the replication subscriber goes down, you rebuild
   from scratch.

6. **Delivers on the continuous replication requirement.** CDC capture runs
   continuously on primary — no batch suspension windows, no data lag gaps.
   Change tables flow to the secondary in near-real-time via AG.

**Trade-off acknowledged:** This approach adds a continuous log reader and change
table write I/O to the primary that does not exist today during batch windows
(because transactional replication is currently suspended during batch). This new
cost is analyzed in the CDC Impact section below.

---

## CDC Impact on Primary — Honest Assessment

Enabling CDC on a multi-TB primary with mixed OLTP and nightly batch workloads
is not zero-cost. This section provides an honest breakdown of the real impact
and the mitigations available.

### Important Context: Current Batch Window Behavior

**Today, transactional replication is suspended during the nightly batch window.**
This means the primary currently runs with NO log reader overhead during its
heaviest write period. The log reader restarts after batch completes and catches
up.

**With continuous CDC, there is no suspension.** The capture job runs through the
entire batch window. This is a real, new cost on primary that does not exist
today. However, any continuous replication solution — whether CDC, Qlik, HVR, or
even transactional replication left running — would impose this same continuous
log reader cost. The question is not "is it free" (it is not), but "which
continuous mechanism has the smallest footprint and fewest failure modes."

---

### 1. Transaction Log Retention (Different from Trans Repl)

**What happens:** CDC prevents log truncation on VLFs that the capture job has
not read yet. The transaction log cannot be truncated past the CDC scan LSN.

**How this differs from transactional replication:**

- With trans repl, once the log reader agent processes entries and writes them to
  the Distribution DB, those VLFs are eligible for truncation. The change data
  exits the source database entirely.
- With CDC, the capture job reads the log and writes change rows into
  `cdc.*_CT` change tables **inside the same database**. The log can truncate
  once the capture job has read past those VLFs, but the change data remains in
  the source database as change table rows until the cleanup job removes them.
- **Today, trans repl is suspended during batch**, so the log is free to truncate
  normally (based on backup schedule) during the heaviest write period. With
  continuous CDC, the log will be held open by the capture job during batch.

**Why this matters for Facets:**

- Nightly batch jobs doing bulk INSERTs/UPDATEs/DELETEs across 1K+ tables
  generate enormous log volume.
- If the CDC capture job falls behind during a batch window, the transaction log
  grows unbounded until capture catches up.
- On a multi-TB database with heavy batch writes, this can mean tens to hundreds
  of GB of additional log retention.
- **This is new overhead** compared to today, where the log reader is off during
  batch.

**Real-world scenario:**

```
10:00 PM  - Nightly batch starts, writes 50 GB of log in 2 hours
          - TODAY: trans repl suspended, log truncates normally per backup
          - WITH CDC: capture job scanning continuously
          - Capture falls behind by 30 GB
          - Transaction log cannot truncate those 30 GB
          - Log file grows from 20 GB → 50+ GB
12:00 AM  - Batch finishes, write volume drops
12:45 AM  - CDC capture catches up, log finally truncates
```

**Mitigation:**

- Pre-size the transaction log to accommodate the worst-case batch window (do
  not rely on autogrow)
- Tune `maxtrans` and `maxscans` parameters on the capture job (see Tuning
  section below)
- Place the log file on fast storage with headroom for batch-window growth
- Monitor `sys.dm_cdc_log_scan_sessions` for latency
- Consider separate filegroup for CDC change tables to isolate I/O

---

### 2. CDC Capture Job CPU and I/O

**What happens:** The CDC capture process (`sp_cdc_scan`) reads the transaction
log using `sp_replcmds` (the same internal function as transactional
replication's log reader). It writes change rows into `cdc.*_CT` tables.

**Overhead profile for 1K+ tables:**

| Resource | Impact | Notes |
|---|---|---|
| **CPU** | Low-moderate (2–5% steady state) | Log reading is sequential, not random. Batch windows spike higher |
| **Log read I/O** | Moderate | Sequential reads on log file. Competes with log writer during batch |
| **Data write I/O** | Moderate | Writes into 1K+ `cdc.*_CT` tables. Regular INSERT operations |
| **tempdb** | Low-moderate | Internal versioning during capture |
| **Memory** | Low | Capture process has a small memory footprint |

**During nightly batch:**

- CPU impact can spike to 8–15% as the capture job works through high-volume
  log entries.
- I/O contention increases because the capture job is both reading the log AND
  writing to CDC change tables simultaneously with the batch workload.

**Mitigation:**

- The capture job is a SQL Agent job — its polling interval and batch size are
  tunable.
- During batch windows, capture will lag but catches up after batch completes.
- This lag is acceptable because consumers (Airbyte/CData) are on the readable
  secondary, not querying primary.

---

### 3. CDC Cleanup Job Impact

**What happens:** The CDC cleanup job (`sp_cdc_cleanup_change_tables`) removes
old rows from the 1K+ `cdc.*_CT` tables based on a retention period (default
3 days / 4320 minutes).

**Why this matters:**

- With 1K+ CDC-enabled tables, cleanup iterates through all of them.
- Each cleanup does DELETEs on change tables, generating more log and more I/O.
- If cleanup runs during business hours, it competes with OLTP.

**Mitigation:**

- Schedule cleanup during low-activity windows (early morning, after batch
  completes).
- Tune retention period: shorter retention means less data to clean, but
  Airbyte/CData need enough history to process.
- Set the `@threshold` parameter to limit rows deleted per cleanup cycle.

---

### 4. Impact on 1K+ Tables Specifically

**What happens:** Each `sp_cdc_enable_table` call creates:

- A change table (`cdc.<schema>_<table>_CT`)
- A capture instance entry in `cdc.change_tables`
- Entries in `cdc.captured_columns` per captured column

**With 1K+ tables:**

- The capture job scans the log **once** and routes changes to the appropriate
  change tables — it does NOT scan the log 1K+ times.
- However, the metadata lookup for 1K+ capture instances adds overhead to each
  scan cycle.
- The change tables themselves add approximately 1K+ tables to the database,
  increasing `sys.objects` catalog size.

**This is manageable.** Microsoft has tested CDC with thousands of capture
instances. The log reader is the bottleneck, not the metadata.

---

### 5. Comparison: What You Have Today vs. CDC on Primary

| Factor | Current (Trans Repl — Suspended During Batch) | Continuous CDC on Primary |
|---|---|---|
| Log reading mechanism | `sp_replcmds` | `sp_replcmds` (same internal function) |
| Runs during batch? | **No — suspended** | **Yes — continuous** |
| Log retention during batch | Minimal — log truncates per backup schedule | CDC holds log until capture reads it |
| Write destination | Distribution DB (separate server) | CDC change tables (same database on primary) |
| I/O on primary during batch | Low (log reader is off) | Moderate (log reads + change table writes) |
| Recovery from failure | Snapshot reinit (expensive, breaks downstream CDC) | CDC is self-contained, no reinit needed |
| Article/capture count | 1K+ articles | 1K+ capture instances |
| Data continuity during batch | Gap — no replication during suspension | No gap — continuous capture |

**Key differences:**

1. **Batch window overhead is new.** Today the log reader is off during batch.
   With continuous CDC it is on. This adds log read I/O, change table write I/O,
   and log retention pressure during the heaviest write period. This is the
   primary trade-off for achieving continuous replication.

2. **Change table writes are local, not remote.** With trans repl, change data
   is written to the Distribution DB on a separate server — I/O is offloaded.
   With CDC, change tables live inside the same database on primary. This adds
   write I/O to the primary's data disks that does not exist today.

3. **No data gaps, no reinit.** Today, the batch suspension window means
   downstream consumers see a replication gap nightly. If trans repl breaks, a
   snapshot reinit is required, which destroys downstream CDC. With continuous
   CDC, the data stream never stops and recovery does not require reinit.

**The trade-off is clear:** you accept higher primary overhead during batch
windows in exchange for continuous data flow, no suspension gaps, and no
snapshot-reinit risk. Any continuous solution would impose similar overhead —
this is the cost of eliminating the suspension window.

---

## Tuning CDC for a Heavy Workload

### Capture Job Parameters

```sql
-- View current settings
EXEC sys.sp_cdc_change_job
    @job_type = 'capture';

-- Tune for high-volume workload
EXEC sys.sp_cdc_change_job
    @job_type        = 'capture',
    @maxtrans        = 5000,    -- Max transactions per scan cycle (default 500)
    @maxscans        = 20,      -- Max scan cycles per poll (default 10)
    @pollinginterval = 2;       -- Seconds between polls (default 5)
```

**Recommendations for this workload:**

| Parameter | Default | Recommended | Why |
|---|---|---|---|
| `maxtrans` | 500 | 5000–10000 | Process more transactions per cycle to keep up with batch volume |
| `maxscans` | 10 | 20–50 | Allow more scan cycles before yielding to prevent falling too far behind |
| `pollinginterval` | 5 sec | 1–2 sec | Poll more frequently during steady-state to minimize latency |
| `continuous` | 1 | 1 | Keep capture running continuously (do not stop it) |

### Cleanup Job Parameters

```sql
EXEC sys.sp_cdc_change_job
    @job_type  = 'cleanup',
    @retention = 2880,     -- Minutes to retain (2 days; default 4320 = 3 days)
    @threshold = 10000;    -- Max rows deleted per cleanup cycle
```

### Monitoring Queries

```sql
-- Check capture latency (how far behind is the capture job?)
SELECT
    last_scan_time,
    duration,
    tran_count,
    log_record_count,
    DATEDIFF(SECOND, last_scan_time, GETDATE()) AS seconds_behind
FROM sys.dm_cdc_log_scan_sessions
ORDER BY start_time DESC;

-- Check log reuse wait (is CDC holding the log?)
SELECT
    name,
    log_reuse_wait_desc
FROM sys.databases
WHERE name = 'Facets';
-- If this shows 'REPLICATION', CDC capture is holding the log

-- Check change table sizes (are they growing too large?)
SELECT
    OBJECT_SCHEMA_NAME(object_id) AS schema_name,
    OBJECT_NAME(object_id)        AS table_name,
    SUM(row_count)                AS total_rows
FROM sys.dm_db_partition_stats
WHERE OBJECT_SCHEMA_NAME(object_id) = 'cdc'
GROUP BY object_id
ORDER BY total_rows DESC;
```

---

## Risk Matrix

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Log growth during batch window | **High** | Medium — log disk fills up | Pre-size log file; fast storage; tune `maxtrans`/`maxscans` |
| Capture job falls behind during batch | **High** | Low — consumers are on secondary, lag is tolerable | Tune polling; capture catches up post-batch |
| CDC change table I/O competes with OLTP | **Medium** | Low-medium — change table writes are small INSERTs | Place data files on fast storage; change tables use same filegroup |
| Cleanup job impacts OLTP hours | **Low** | Low — if scheduled correctly | Schedule cleanup at 3–4 AM; tune `@threshold` |
| CDC metadata overhead for 1K+ tables | **Low** | Low — single log scan regardless of table count | No action needed |
| Log truncation delayed by CDC | **Medium** | Medium — affects backup chain timing | Monitor `log_reuse_wait_desc`; alert if stuck |

### Bottom Line

**Is there more overhead on primary than today?** Yes. Be honest about this with
management. Two costs are genuinely new:

1. **Continuous log reader during batch windows.** Today the log reader is
   suspended during batch. With CDC it runs continuously. The transaction log
   will grow larger during batch windows than it does today. Pre-size it and
   monitor it.

2. **CDC change table writes on primary's data disks.** Today, change data is
   written to the Distribution DB on a separate server. With CDC, change tables
   live in the same database. This adds write I/O to the primary that is
   currently offloaded.

**Is this the cost of continuous replication?** Yes — and it applies to any
continuous solution, not just CDC. If transactional replication were left running
during batch instead of suspended, it would also hold the log open and add I/O.
Qlik Replicate, HVR, or Debezium reading the log continuously would have the
same log retention impact.

**Is it manageable?** Yes. Because:

- The AG secondary absorbs all consumer read workload. Primary only does capture
  writes — no Airbyte/CData queries.
- Tuning `maxtrans`/`maxscans`/`pollinginterval` controls how aggressively
  capture runs and how quickly it catches up after batch peaks.
- Capture lag during batch windows is acceptable — downstream consumers are not
  real-time sensitive.
- Pre-sizing the log file and placing change tables on fast storage addresses the
  I/O cost.

**Is the overall architecture better than today?** Yes. Today you have:
- Trans repl with nightly suspension (data gap)
- Distribution DB overhead
- CDC on subscriber (fragile — snapshot reinit destroys it)
- 3-hop pipeline with multiple failure surfaces

With AG + CDC you have:
- One continuous pipeline with no suspension gap
- No Distribution DB to manage
- No snapshot reinit risk
- No CDC-on-subscriber fragility
- Higher primary overhead during batch, but a dramatically simpler and more
  resilient architecture overall

---

## Migration Path

| Phase | Action | Risk |
|---|---|---|
| 1 | Stand up AG between Facets primary and a new secondary (or repurpose the reporting server) | Low — AG setup does not affect existing replication |
| 2 | Enable CDC on primary for a pilot batch (10–20 tables) | Low — CDC is lightweight per table |
| 3 | Point Airbyte/CData at readable secondary's CDC tables for pilot tables | Low — parallel run alongside existing pipeline |
| 4 | Validate data parity between old path (trans repl → CDC) and new path (AG → CDC) | Medium — validation effort |
| 5 | Cut over remaining tables in batches (100–200 at a time) | Medium — coordinate with downstream consumers |
| 6 | Decommission transactional replication for Facets | Low — after validation |
| 7 | Retire Reporting DB (or repurpose as AG secondary) | Low |

---

## Other Databases on the Reporting Server

The other databases replicated to the same reporting server via transactional
replication are **separate** from this change.

- **Leave them on transactional replication** if they work fine and do not use CDC.
- **Migrate them to AG over time** if they also need CDC or have fragility issues.
- **Keep the reporting server** for those databases even after Facets moves to AG.

Facets is the 1K+ table, multi-TB pain point. Fix that first; address the others
incrementally.

---

## References

- [SQL Server CDC Overview](https://docs.microsoft.com/en-us/sql/relational-databases/track-changes/about-change-data-capture-sql-server)
- [Always On Availability Groups](https://docs.microsoft.com/en-us/sql/database-engine/availability-groups/windows/overview-of-always-on-availability-groups-sql-server)
- [CDC Behavior with AG](https://docs.microsoft.com/en-us/sql/database-engine/availability-groups/windows/replicate-track-change-data-capture-always-on-availability)
