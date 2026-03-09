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
5. [Migration Path](#migration-path)
6. [Other Databases on the Reporting Server](#other-databases-on-the-reporting-server)

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
