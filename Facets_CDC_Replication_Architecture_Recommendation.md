# Facets CDC & Replication Architecture Recommendation

**Date:** March 9, 2026  
**Status:** Draft — For Team Discussion  
**Scope:** FacetsReporting replication pipeline redesign  

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
  ├── Transactional Replication (1K+ tables) ──► FacetsReporting DB (Subscriber)
  │                                                    │
  │                                                    ├── CDC ──► Airbyte ──► Abacus
  │                                                    └── CDC ──► CData Sync ──► Snowflake
  │
Other Source DBs ── Trans Repl ──► Same Reporting Server (other DBs)
```

- Facets OLTP is a multi-terabyte database with 1,000+ tables replicated via
  transactional replication to FacetsReporting on a separate server.
- The reporting server also hosts databases replicated from other source systems
  via transactional replication.
- FacetsReporting has SQL Server CDC enabled. CDC change data feeds two
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

**Approach:** Keep `OLTP → Trans Repl → FacetsReporting (CDC) → Consumers`.

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
| Consumer reads isolated from primary via secondary | CDC log reader runs on primary (comparable to existing trans repl log reader) |
| CDC metadata survives AG failover | AG requires Enterprise Edition (you already have it) |
| Trivial new table onboarding | |
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

1. **You already pay the log reader cost on primary.** Transactional replication
   runs a log reader on primary today. CDC's log reader is the same mechanism
   (`sp_replcmds` vs. `sp_cdc_scan` — both read the transaction log). Net
   overhead is comparable, possibly lower since you eliminate the Distribution DB
   round-trip.

2. **Eliminates the single biggest failure mode.** CDC-on-subscriber-after-
   snapshot-reinit is the root cause of most downstream breaks today.

3. **Readable secondary isolates consumer workload from production OLTP.**
   Management's concern about primary impact is fully addressed — Airbyte and
   CData never touch the primary.

4. **Adding tables becomes trivial.** One stored procedure call replaces a
   multi-step replication article/snapshot/CDC-enable/connector-configure workflow.

5. **You already own the technology.** SQL Server Enterprise includes AG. No new
   licensing.

6. **CDC metadata survives failover.** If the AG fails over, CDC is preserved on
   the new primary. Today, if the replication subscriber goes down, you rebuild
   from scratch.

7. **Path to continuous CDC.** CDC capture is always running on primary. Change
   tables flow to the secondary in near-real-time via AG. Consumers read
   continuously. No scheduled batch windows needed.

---

## CDC Impact on Primary — Honest Assessment

Enabling CDC on a multi-TB primary with mixed OLTP and nightly batch workloads
is not zero-cost. This section provides an honest breakdown of the real impact
and the mitigations available.

### 1. Transaction Log Retention

**What happens:** CDC prevents log truncation on VLFs that the capture job has
not read yet. The transaction log cannot be truncated past the CDC scan LSN.

**Why this matters for Facets:**

- Nightly batch jobs doing bulk INSERTs/UPDATEs/DELETEs across 1K+ tables
  generate enormous log volume.
- If the CDC capture job falls behind during a batch window, the transaction log
  grows unbounded until capture catches up.
- On a multi-TB database with heavy batch writes, this can mean tens to hundreds
  of GB of additional log retention.

**Real-world scenario:**

```
10:00 PM  - Nightly batch starts, writes 50 GB of log in 2 hours
          - CDC capture scanning at 500 transactions/poll × 10 polls/sec
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
- Place the log file on fast storage
- Monitor `sys.dm_cdc_log_scan_sessions` for latency

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

| Factor | Current (Trans Repl Log Reader) | CDC Log Reader on Primary |
|---|---|---|
| Log reading mechanism | `sp_replcmds` | `sp_replcmds` (same) |
| Log retention | Log held until Distribution Agent delivers | Log held until CDC capture reads it |
| Write destination | Distribution DB (separate database/server) | CDC change tables (same database) |
| Batch window impact | Log reader can fall behind; log grows | Same behavior |
| Recovery | Reinit subscriber from snapshot | No reinit — CDC is self-contained |
| Article/capture count | 1K+ articles | 1K+ capture instances |

**Key difference:** With transactional replication, the write destination is the
Distribution DB (separate server). With CDC, the change tables are written into
the same database on primary. This means:

- Slightly more I/O on the primary's data disks (change table writes)
- But you eliminate the Distribution DB, Distribution Agent, and network I/O to
  the subscriber
- Net I/O on the primary is comparable — it shifts from network-bound to
  local-disk-bound

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

**Is there impact?** Yes. CDC on a multi-TB primary with nightly batch is not
free. The two real costs are:

1. **Transaction log retention during batch windows** — the log will grow
   larger than it does today during heavy write periods. Pre-size it and
   monitor it.

2. **CDC change table writes** — 1K+ change tables receiving INSERTs on the
   primary's data disks. This is new I/O that currently happens on the
   subscriber.

**Is it manageable?** Yes. Because:

- You are already running a log reader on primary (trans repl). CDC replaces it,
  not adds to it.
- The AG secondary absorbs all consumer read workload. Primary only does capture
  writes.
- Tuning `maxtrans`/`maxscans`/`pollinginterval` lets you control how
  aggressively capture runs.
- Capture lag during batch windows is acceptable — downstream consumers are not
  real-time.

**Is it worse than what you have today?** No. Today you have trans repl log
reader + Distribution DB + subscriber CDC + snapshot reinit risk. The failure
surface is larger. The AG + CDC architecture has a simpler failure profile even
though it moves capture write I/O to the primary.

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
| 7 | Retire FacetsReporting DB (or repurpose as AG secondary) | Low |

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
