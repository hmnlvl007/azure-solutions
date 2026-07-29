/*
SNOWFLAKE ENVIRONMENT REVIEW TOOLKIT
Run separately in each Snowflake account/region.

Recommended role:
  USE ROLE ACCOUNTADMIN;
or a custom audit role with imported privileges / SNOWFLAKE database roles
needed to read SNOWFLAKE.ACCOUNT_USAGE.

Important:
- ACCOUNT_USAGE data has view-specific latency.
- Most history queries below use the last 30 days; change $DAYS as needed.
- Credit-to-dollar conversion is contract-specific. Scripts report credits unless
  you populate $CREDIT_PRICE.
*/

ALTER SESSION SET TIMEZONE = 'UTC';

SET DAYS = 30;
SET CREDIT_PRICE = 0;  -- Set to your effective $/credit only if appropriate.

/* ============================================================
   0. ACCOUNT / REGION INVENTORY
   ============================================================ */

SELECT
    CURRENT_ORGANIZATION_NAME() AS organization_name,
    CURRENT_ACCOUNT_NAME()      AS account_name,
    CURRENT_REGION()            AS region,
    CURRENT_VERSION()           AS snowflake_version,
    CURRENT_TIMESTAMP()         AS collected_at_utc;

SHOW PARAMETERS IN ACCOUNT;

-- Object inventory by database/schema/type.
SELECT
    table_catalog AS database_name,
    table_schema  AS schema_name,
    table_type,
    COUNT(*)      AS object_count
FROM snowflake.account_usage.tables
WHERE deleted IS NULL
GROUP BY 1,2,3
ORDER BY 1,2,3;

/* ============================================================
   1. WAREHOUSE CONFIGURATION AND UTILIZATION
   ============================================================ */

-- Current warehouse definitions. Review type/generation, size, clusters,
-- scaling policy, auto-suspend, auto-resume, resource monitor, and state.
SHOW WAREHOUSES;

-- Save SHOW output immediately if you want to query its columns:
SELECT *
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "name";

-- Warehouse credits, attributed query credits, and estimated idle credits.
-- Idle is an attribution estimate, not necessarily avoidable one-for-one.
SELECT
    warehouse_name,
    SUM(credits_used_compute) AS compute_credits,
    SUM(credits_used_cloud_services) AS cloud_services_credits,
    SUM(credits_attributed_compute_queries) AS query_attributed_credits,
    GREATEST(
        SUM(credits_used_compute) -
        SUM(credits_attributed_compute_queries),
        0
    ) AS estimated_idle_credits,
    ROUND(
        100 * GREATEST(
            SUM(credits_used_compute) -
            SUM(credits_attributed_compute_queries), 0
        ) / NULLIF(SUM(credits_used_compute), 0),
        2
    ) AS estimated_idle_pct,
    IFF($CREDIT_PRICE > 0,
        ROUND(SUM(credits_used_compute) * $CREDIT_PRICE, 2),
        NULL
    ) AS estimated_compute_cost
FROM snowflake.account_usage.warehouse_metering_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY compute_credits DESC;

-- Daily warehouse trend.
SELECT
    usage_date,
    warehouse_name,
    SUM(compute_credits) AS compute_credits,
    SUM(cloud_services_credits) AS cloud_services_credits
FROM (
    SELECT
        CAST(start_time AS DATE) AS usage_date,
        warehouse_name,
        credits_used_compute AS compute_credits,
        credits_used_cloud_services AS cloud_services_credits
    FROM snowflake.account_usage.warehouse_metering_history
    WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
)
GROUP BY 1,2
ORDER BY 1 DESC, 3 DESC;

-- Warehouse load and queueing in five-minute intervals.
SELECT
    warehouse_name,
    ROUND(AVG(avg_running), 2) AS avg_running,
    ROUND(MAX(avg_running), 2) AS peak_avg_running,
    ROUND(AVG(avg_queued_load), 2) AS avg_queued_for_capacity,
    ROUND(MAX(avg_queued_load), 2) AS peak_queued_for_capacity,
    ROUND(AVG(avg_queued_provisioning), 2) AS avg_queued_provisioning,
    ROUND(AVG(avg_blocked), 2) AS avg_blocked
FROM snowflake.account_usage.warehouse_load_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY peak_queued_for_capacity DESC, peak_avg_running DESC;

-- Query queueing by warehouse.
SELECT
    warehouse_name,
    COUNT(*) AS query_count,
    COUNT_IF(queued_overload_time > 0) AS queued_query_count,
    ROUND(100 * COUNT_IF(queued_overload_time > 0) / NULLIF(COUNT(*),0), 2)
        AS queued_query_pct,
    ROUND(AVG(queued_overload_time) / 1000, 2) AS avg_overload_queue_seconds,
    ROUND(MAX(queued_overload_time) / 1000, 2) AS max_overload_queue_seconds,
    ROUND(AVG(queued_provisioning_time) / 1000, 2)
        AS avg_provisioning_queue_seconds
FROM snowflake.account_usage.query_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
  AND warehouse_name IS NOT NULL
  AND execution_status = 'SUCCESS'
GROUP BY warehouse_name
ORDER BY queued_query_pct DESC;

/* ============================================================
   2. COST / FINOPS
   ============================================================ */

-- Account-level service credit consumption.
SELECT
    service_type,
    SUM(credits_used) AS credits_used,
    SUM(credits_adjustment_cloud_services) AS cloud_services_adjustment,
    SUM(credits_billed) AS credits_billed
FROM snowflake.account_usage.metering_daily_history
WHERE usage_date >= DATEADD('day', -$DAYS, CURRENT_DATE())
GROUP BY service_type
ORDER BY credits_billed DESC;

-- Hourly metering by service type.
SELECT
    DATE_TRUNC('day', start_time) AS usage_day,
    service_type,
    SUM(credits_used) AS credits_used
FROM snowflake.account_usage.metering_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
GROUP BY 1,2
ORDER BY 1 DESC, 3 DESC;

-- Resource monitors.
SELECT
    name,
    credit_quota,
    used_credits,
    remaining_credits,
    frequency,
    start_time,
    end_time,
    warehouses,
    owner
FROM snowflake.account_usage.resource_monitors
WHERE deleted_on IS NULL
ORDER BY name;

-- Resource monitor coverage from current warehouse metadata.
SHOW WAREHOUSES;
SELECT
    "name" AS warehouse_name,
    "resource_monitor" AS resource_monitor,
    "auto_suspend" AS auto_suspend_seconds,
    "auto_resume" AS auto_resume,
    "size" AS warehouse_size,
    "min_cluster_count" AS min_clusters,
    "max_cluster_count" AS max_clusters,
    "scaling_policy" AS scaling_policy
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY warehouse_name;

-- Query-level attributed compute cost.
SELECT
    qah.query_id,
    qh.query_parameterized_hash,
    qh.warehouse_name,
    qh.warehouse_size,
    qh.user_name,
    qh.role_name,
    qh.query_type,
    qh.start_time,
    qh.total_elapsed_time / 1000 AS elapsed_seconds,
    qah.credits_attributed_compute,
    IFF($CREDIT_PRICE > 0,
        ROUND(qah.credits_attributed_compute * $CREDIT_PRICE, 4),
        NULL
    ) AS estimated_cost,
    qh.query_text
FROM snowflake.account_usage.query_attribution_history qah
JOIN snowflake.account_usage.query_history qh
  ON qh.query_id = qah.query_id
WHERE qh.start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
ORDER BY qah.credits_attributed_compute DESC
LIMIT 200;

-- Cost by parameterized query pattern.
SELECT
    qh.query_parameterized_hash,
    qh.query_type,
    COUNT(*) AS runs,
    SUM(qah.credits_attributed_compute) AS attributed_credits,
    ROUND(AVG(qah.credits_attributed_compute), 6) AS avg_credits_per_run,
    ROUND(SUM(qh.execution_time) / 1000 / 3600, 2) AS cumulative_runtime_hours,
    SUM(qh.bytes_scanned) AS bytes_scanned,
    SUM(qh.bytes_spilled_to_local_storage) AS local_spill_bytes,
    SUM(qh.bytes_spilled_to_remote_storage) AS remote_spill_bytes,
    ANY_VALUE(qh.query_text) AS example_sql
FROM snowflake.account_usage.query_history qh
JOIN snowflake.account_usage.query_attribution_history qah
  ON qh.query_id = qah.query_id
WHERE qh.start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
  AND qh.execution_status = 'SUCCESS'
GROUP BY 1,2
ORDER BY attributed_credits DESC
LIMIT 200;

-- Cost by warehouse/user/role.
SELECT
    qh.warehouse_name,
    qh.user_name,
    qh.role_name,
    SUM(qah.credits_attributed_compute) AS attributed_credits,
    COUNT(*) AS runs
FROM snowflake.account_usage.query_history qh
JOIN snowflake.account_usage.query_attribution_history qah
  ON qh.query_id = qah.query_id
WHERE qh.start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
GROUP BY 1,2,3
ORDER BY attributed_credits DESC;

-- Serverless / managed-service spend details.
SELECT 'AUTOMATIC_CLUSTERING' AS service,
       database_name, schema_name, table_name AS object_name,
       SUM(credits_used) AS credits
FROM snowflake.account_usage.automatic_clustering_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
GROUP BY 1,2,3,4
UNION ALL
SELECT 'SEARCH_OPTIMIZATION',
       database_name, schema_name, table_name,
       SUM(credits_used)
FROM snowflake.account_usage.search_optimization_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
GROUP BY 1,2,3,4
UNION ALL
SELECT 'MATERIALIZED_VIEW',
       database_name, schema_name, table_name,
       SUM(credits_used)
FROM snowflake.account_usage.materialized_view_refresh_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
GROUP BY 1,2,3,4
UNION ALL
SELECT 'SNOWPIPE_OR_ICEBERG_AUTO_REFRESH',
       SPLIT_PART(pipe_name, '.', 1),
       SPLIT_PART(pipe_name, '.', 2),
       pipe_name,
       SUM(credits_used)
FROM snowflake.account_usage.pipe_usage_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
GROUP BY 1,2,3,4
ORDER BY credits DESC;

/* ============================================================
   3. QUERY PERFORMANCE
   ============================================================ */

-- High total elapsed time and high execution count by query pattern.
SELECT
    query_parameterized_hash,
    query_type,
    COUNT(*) AS runs,
    ROUND(SUM(total_elapsed_time) / 1000 / 3600, 2) AS total_elapsed_hours,
    ROUND(AVG(total_elapsed_time) / 1000, 2) AS avg_elapsed_seconds,
    ROUND(PERCENTILE_CONT(0.95)
          WITHIN GROUP (ORDER BY total_elapsed_time) / 1000, 2)
          AS p95_elapsed_seconds,
    SUM(bytes_scanned) AS bytes_scanned,
    ANY_VALUE(query_text) AS example_sql
FROM snowflake.account_usage.query_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
  AND execution_status = 'SUCCESS'
  AND query_parameterized_hash IS NOT NULL
GROUP BY 1,2
ORDER BY total_elapsed_hours DESC
LIMIT 200;

-- Spill analysis.
SELECT
    query_id,
    query_parameterized_hash,
    warehouse_name,
    warehouse_size,
    user_name,
    start_time,
    total_elapsed_time / 1000 AS elapsed_seconds,
    bytes_scanned,
    bytes_spilled_to_local_storage,
    bytes_spilled_to_remote_storage,
    query_text
FROM snowflake.account_usage.query_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
  AND (bytes_spilled_to_local_storage > 0
       OR bytes_spilled_to_remote_storage > 0)
ORDER BY bytes_spilled_to_remote_storage DESC,
         bytes_spilled_to_local_storage DESC
LIMIT 200;

-- Large scans returning few rows.
SELECT
    query_id,
    query_parameterized_hash,
    warehouse_name,
    user_name,
    start_time,
    bytes_scanned,
    rows_produced,
    ROUND(bytes_scanned / NULLIF(rows_produced, 0), 2)
        AS bytes_scanned_per_output_row,
    partitions_scanned,
    partitions_total,
    query_text
FROM snowflake.account_usage.query_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
  AND execution_status = 'SUCCESS'
  AND bytes_scanned >= 1024 * 1024 * 1024
ORDER BY bytes_scanned_per_output_row DESC NULLS LAST
LIMIT 200;

-- Query-level partition pruning.
SELECT
    query_id,
    query_parameterized_hash,
    warehouse_name,
    start_time,
    partitions_scanned,
    partitions_total,
    ROUND(
        100 * (1 - partitions_scanned / NULLIF(partitions_total, 0)),
        2
    ) AS query_pruning_pct,
    bytes_scanned,
    query_text
FROM snowflake.account_usage.query_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
  AND partitions_total > 0
ORDER BY query_pruning_pct ASC, partitions_total DESC
LIMIT 200;

-- Table-level pruning effectiveness.
SELECT
    table_catalog,
    table_schema,
    table_name,
    SUM(partitions_scanned) AS partitions_scanned,
    SUM(partitions_pruned) AS partitions_pruned,
    ROUND(
        100 * SUM(partitions_pruned) /
        NULLIF(SUM(partitions_scanned) + SUM(partitions_pruned), 0),
        2
    ) AS pruning_pct
FROM snowflake.account_usage.table_pruning_history
WHERE interval_start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
GROUP BY 1,2,3
HAVING SUM(partitions_scanned) + SUM(partitions_pruned) > 0
ORDER BY pruning_pct ASC, partitions_scanned DESC
LIMIT 200;

-- Compilation-heavy queries.
SELECT
    query_id,
    query_parameterized_hash,
    start_time,
    warehouse_name,
    compilation_time / 1000 AS compilation_seconds,
    execution_time / 1000 AS execution_seconds,
    total_elapsed_time / 1000 AS total_elapsed_seconds,
    ROUND(100 * compilation_time / NULLIF(total_elapsed_time, 0), 2)
        AS compilation_pct,
    query_text
FROM snowflake.account_usage.query_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
  AND execution_status = 'SUCCESS'
ORDER BY compilation_pct DESC, compilation_time DESC
LIMIT 200;

-- Repeated query patterns and average interval between starts.
SELECT
    query_parameterized_hash,
    COUNT(*) AS runs,
    MIN(start_time) AS first_run,
    MAX(start_time) AS last_run,
    ROUND(
        DATEDIFF('second', MIN(start_time), MAX(start_time))
        / NULLIF(COUNT(*) - 1, 0),
        2
    ) AS avg_seconds_between_starts,
    ROUND(AVG(execution_time) / 1000, 2) AS avg_execution_seconds,
    ANY_VALUE(query_text) AS example_sql
FROM snowflake.account_usage.query_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
  AND execution_status = 'SUCCESS'
  AND query_parameterized_hash IS NOT NULL
GROUP BY 1
HAVING COUNT(*) >= 10
ORDER BY runs DESC
LIMIT 200;

-- Failed queries.
SELECT
    error_code,
    error_message,
    query_type,
    warehouse_name,
    user_name,
    COUNT(*) AS failures,
    MAX(start_time) AS last_failure
FROM snowflake.account_usage.query_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
  AND execution_status = 'FAIL'
GROUP BY 1,2,3,4,5
ORDER BY failures DESC;

/* ============================================================
   4. STORAGE
   ============================================================ */

-- Account storage trend.
SELECT
    usage_date,
    storage_bytes,
    stage_bytes,
    failsafe_bytes,
    ROUND(storage_bytes / POWER(1024,4), 2) AS storage_tb,
    ROUND(stage_bytes / POWER(1024,4), 2) AS stage_tb,
    ROUND(failsafe_bytes / POWER(1024,4), 2) AS failsafe_tb
FROM snowflake.account_usage.storage_usage
WHERE usage_date >= DATEADD('day', -$DAYS, CURRENT_DATE())
ORDER BY usage_date;

-- Database storage trend.
SELECT
    usage_date,
    database_name,
    ROUND(average_database_bytes / POWER(1024,4), 2) AS database_tb,
    ROUND(average_failsafe_bytes / POWER(1024,4), 2) AS failsafe_tb
FROM snowflake.account_usage.database_storage_usage_history
WHERE usage_date >= DATEADD('day', -$DAYS, CURRENT_DATE())
ORDER BY usage_date DESC, database_tb DESC;

-- Largest active and dropped tables still consuming storage.
SELECT
    table_catalog,
    table_schema,
    table_name,
    active_bytes,
    time_travel_bytes,
    failsafe_bytes,
    retained_for_clone_bytes,
    ROUND(
        (active_bytes + time_travel_bytes + failsafe_bytes
         + retained_for_clone_bytes) / POWER(1024,3), 2
    ) AS total_billed_gb,
    table_created,
    table_dropped,
    table_entered_failsafe
FROM snowflake.account_usage.table_storage_metrics
ORDER BY total_billed_gb DESC
LIMIT 300;

-- Internal stage storage trend.
SELECT
    usage_date,
    ROUND(stage_bytes / POWER(1024,3), 2) AS stage_gb
FROM snowflake.account_usage.stage_storage_usage_history
WHERE usage_date >= DATEADD('day', -$DAYS, CURRENT_DATE())
ORDER BY usage_date;

-- Detailed internal-stage usage where available.
SELECT
    usage_date,
    catalog_name,
    schema_name,
    entity_name,
    stage_type,
    file_count,
    ROUND(bytes / POWER(1024,3), 2) AS size_gb
FROM snowflake.account_usage.stage_storage_usage_details
WHERE usage_date >= DATEADD('day', -LEAST($DAYS,90), CURRENT_DATE())
ORDER BY size_gb DESC;

/* ============================================================
   5. TABLE ARCHITECTURE AND DML
   ============================================================ */

-- Table inventory. Inspect table_type for BASE TABLE, EXTERNAL TABLE,
-- EVENT TABLE, HYBRID TABLE, ICEBERG TABLE, DYNAMIC TABLE, etc.
SELECT
    table_catalog,
    table_schema,
    table_type,
    COUNT(*) AS table_count,
    SUM(row_count) AS rows,
    SUM(bytes) AS bytes
FROM snowflake.account_usage.tables
WHERE deleted IS NULL
GROUP BY 1,2,3
ORDER BY 1,2,3;

-- Largest/high-change tables.
SELECT
    table_database,
    table_schema,
    table_name,
    SUM(rows_added) AS rows_added,
    SUM(rows_removed) AS rows_removed,
    SUM(rows_updated) AS rows_updated
FROM snowflake.account_usage.table_dml_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
GROUP BY 1,2,3
ORDER BY rows_added + rows_removed + rows_updated DESC
LIMIT 200;

-- Automatic clustering cost relative to table DML.
WITH dml AS (
    SELECT table_id,
           SUM(rows_added + rows_removed + rows_updated) AS changed_rows
    FROM snowflake.account_usage.table_dml_history
    WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
    GROUP BY table_id
),
clustering AS (
    SELECT table_id,
           ANY_VALUE(database_name) AS database_name,
           ANY_VALUE(schema_name) AS schema_name,
           ANY_VALUE(table_name) AS table_name,
           SUM(credits_used) AS clustering_credits,
           SUM(bytes_reclustered) AS bytes_reclustered
    FROM snowflake.account_usage.automatic_clustering_history
    WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
    GROUP BY table_id
)
SELECT
    c.database_name,
    c.schema_name,
    c.table_name,
    d.changed_rows,
    c.bytes_reclustered,
    c.clustering_credits
FROM clustering c
LEFT JOIN dml d USING (table_id)
ORDER BY c.clustering_credits DESC;

/* ============================================================
   6. PIPELINES: TASKS, DYNAMIC TABLES, PIPES/COPY
   ============================================================ */

-- Task failures and long-running task executions.
SELECT
    database_name,
    schema_name,
    name AS task_name,
    state,
    error_code,
    error_message,
    COUNT(*) AS executions,
    MAX(completed_time) AS most_recent_completion,
    ROUND(AVG(DATEDIFF('millisecond', query_start_time, completed_time))/1000,2)
        AS avg_runtime_seconds
FROM snowflake.account_usage.task_history
WHERE scheduled_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
GROUP BY 1,2,3,4,5,6
ORDER BY state <> 'SUCCEEDED' DESC, executions DESC;

-- Dynamic-table refresh failures and latency.
SELECT
    database_name,
    schema_name,
    name AS dynamic_table_name,
    state,
    state_code,
    state_message,
    COUNT(*) AS refresh_count,
    MAX(refresh_end_time) AS latest_refresh,
    ROUND(AVG(DATEDIFF('millisecond',
                       refresh_start_time,
                       refresh_end_time))/1000,2) AS avg_refresh_seconds
FROM snowflake.account_usage.dynamic_table_refresh_history
WHERE refresh_start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
GROUP BY 1,2,3,4,5,6
ORDER BY state <> 'SUCCEEDED' DESC, refresh_count DESC;

-- COPY and Snowpipe load errors.
SELECT
    pipe_name,
    table_catalog_name,
    table_schema_name,
    table_name,
    status,
    first_error_message,
    COUNT(*) AS file_count,
    SUM(row_count) AS rows_parsed,
    SUM(row_parsed) AS rows_loaded,
    MAX(last_load_time) AS latest_load
FROM snowflake.account_usage.copy_history
WHERE last_load_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
GROUP BY 1,2,3,4,5,6
ORDER BY status <> 'Loaded' DESC, file_count DESC;

/* ============================================================
   7. TAGGING, HORIZON, AND POLICY COVERAGE
   ============================================================ */

-- Defined tags.
SELECT
    tag_database,
    tag_schema,
    tag_name,
    allowed_values,
    owner,
    comment
FROM snowflake.account_usage.tags
WHERE deleted IS NULL
ORDER BY 1,2,3;

-- Direct tag assignments. ACCOUNT_USAGE.TAG_REFERENCES excludes inheritance.
SELECT
    tag_database,
    tag_schema,
    tag_name,
    tag_value,
    domain AS object_domain,
    object_database,
    object_schema,
    object_name,
    apply_method
FROM snowflake.account_usage.tag_references
WHERE object_deleted IS NULL
ORDER BY 1,2,3,6,7,8;

-- Tag coverage for active warehouses (direct assignments only).
WITH wh AS (
    SELECT DISTINCT warehouse_name
    FROM snowflake.account_usage.warehouse_metering_history
    WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
),
tagged AS (
    SELECT DISTINCT object_name
    FROM snowflake.account_usage.tag_references
    WHERE domain = 'WAREHOUSE'
      AND object_deleted IS NULL
)
SELECT
    wh.warehouse_name,
    IFF(t.object_name IS NULL, 'UNTAGGED', 'TAGGED') AS tag_status
FROM wh
LEFT JOIN tagged t
  ON UPPER(t.object_name) = UPPER(wh.warehouse_name)
ORDER BY tag_status DESC, warehouse_name;

-- Tag coverage for databases and tables.
WITH objects AS (
    SELECT 'DATABASE' AS object_domain,
           database_name AS object_database,
           NULL AS object_schema,
           database_name AS object_name
    FROM snowflake.account_usage.databases
    WHERE deleted IS NULL
    UNION ALL
    SELECT 'TABLE',
           table_catalog,
           table_schema,
           table_name
    FROM snowflake.account_usage.tables
    WHERE deleted IS NULL
      AND table_type <> 'VIEW'
),
tagged AS (
    SELECT DISTINCT
        domain,
        object_database,
        object_schema,
        object_name
    FROM snowflake.account_usage.tag_references
    WHERE object_deleted IS NULL
)
SELECT
    o.object_domain,
    COUNT(*) AS object_count,
    COUNT_IF(t.object_name IS NOT NULL) AS tagged_count,
    COUNT_IF(t.object_name IS NULL) AS untagged_count,
    ROUND(100 * COUNT_IF(t.object_name IS NOT NULL)
          / NULLIF(COUNT(*),0),2) AS tagged_pct
FROM objects o
LEFT JOIN tagged t
  ON t.domain = o.object_domain
 AND COALESCE(t.object_database,'') = COALESCE(o.object_database,'')
 AND COALESCE(t.object_schema,'') = COALESCE(o.object_schema,'')
 AND t.object_name = o.object_name
GROUP BY o.object_domain
ORDER BY o.object_domain;

-- Policy inventory and references.
SELECT
    policy_kind,
    policy_name,
    policy_db,
    policy_schema,
    ref_entity_domain,
    ref_database_name,
    ref_schema_name,
    ref_entity_name,
    ref_column_name
FROM snowflake.account_usage.policy_references
ORDER BY policy_kind, policy_db, policy_schema, policy_name;

/* ============================================================
   8. SECURITY / ACCESS REVIEW
   ============================================================ */

-- Active users and authentication posture.
SELECT
    name,
    type,
    disabled,
    has_password,
    has_mfa,
    ext_authn_duo,
    default_role,
    default_warehouse,
    last_success_login,
    created_on
FROM snowflake.account_usage.users
WHERE deleted_on IS NULL
ORDER BY disabled, last_success_login NULLS FIRST;

-- Privileged roles granted to users.
SELECT
    role,
    grantee_name AS user_name,
    created_on
FROM snowflake.account_usage.grants_to_users
WHERE deleted_on IS NULL
  AND role IN ('ACCOUNTADMIN','SECURITYADMIN','SYSADMIN','ORGADMIN','USERADMIN')
ORDER BY role, user_name;

-- Direct grants to users (usually review/avoid except deliberate cases).
SELECT
    privilege,
    granted_on,
    name,
    grantee_name,
    grant_option,
    created_on
FROM snowflake.account_usage.grants_to_roles
WHERE deleted_on IS NULL
  AND granted_to = 'USER'
ORDER BY grantee_name, granted_on, name;

-- Ownership and broad privileges.
SELECT
    privilege,
    granted_on,
    name,
    grantee_name,
    grant_option
FROM snowflake.account_usage.grants_to_roles
WHERE deleted_on IS NULL
  AND (
       privilege = 'OWNERSHIP'
       OR privilege IN ('MANAGE GRANTS','CREATE ACCOUNT','MONITOR SECURITY')
      )
ORDER BY privilege, grantee_name, granted_on, name;

-- Failed logins.
SELECT
    user_name,
    reported_client_type,
    error_code,
    error_message,
    COUNT(*) AS failures,
    MIN(event_timestamp) AS first_failure,
    MAX(event_timestamp) AS last_failure
FROM snowflake.account_usage.login_history
WHERE event_timestamp >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
  AND is_success = 'NO'
GROUP BY 1,2,3,4
ORDER BY failures DESC;

-- Authentication methods actually used.
SELECT
    authentication_method,
    COUNT(*) AS sessions,
    COUNT(DISTINCT user_name) AS users
FROM snowflake.account_usage.sessions
WHERE created_on >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
GROUP BY authentication_method
ORDER BY sessions DESC;

-- Network policies.
SELECT *
FROM snowflake.account_usage.network_policies
WHERE deleted IS NULL
ORDER BY name;

/* ============================================================
   9. RELIABILITY, REPLICATION, AND CROSS-REGION TRANSFER
   ============================================================ */

-- Replication/failover groups.
SELECT *
FROM snowflake.account_usage.replication_groups
WHERE deleted IS NULL
ORDER BY group_name;

-- Refresh outcomes and lag.
SELECT
    replication_group_name,
    start_time,
    end_time,
    status,
    error_code,
    error_message,
    total_bytes,
    DATEDIFF('minute', end_time, CURRENT_TIMESTAMP()) AS minutes_since_refresh
FROM snowflake.account_usage.replication_group_refresh_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;

-- Replication usage.
SELECT
    replication_group_name,
    DATE_TRUNC('day', start_time) AS usage_day,
    SUM(credits_used) AS credits_used,
    SUM(bytes_transferred) AS bytes_transferred
FROM snowflake.account_usage.replication_group_usage_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
GROUP BY 1,2
ORDER BY usage_day DESC, replication_group_name;

-- Cross-region / cross-cloud data transfer.
SELECT
    transfer_type,
    source_cloud,
    source_region,
    target_cloud,
    target_region,
    SUM(bytes_transferred) AS bytes_transferred
FROM snowflake.account_usage.data_transfer_history
WHERE start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
GROUP BY 1,2,3,4,5
ORDER BY bytes_transferred DESC;

/* ============================================================
   10. OUTPUT: PRIORITIZATION HELPERS
   ============================================================ */

-- Candidate quick wins: costly patterns with many executions or large scans/spill.
SELECT
    qh.query_parameterized_hash,
    COUNT(*) AS runs,
    SUM(qah.credits_attributed_compute) AS credits,
    ROUND(SUM(qh.execution_time)/1000/3600,2) AS runtime_hours,
    ROUND(SUM(qh.bytes_scanned)/POWER(1024,4),2) AS scanned_tb,
    ROUND(SUM(qh.bytes_spilled_to_remote_storage)/POWER(1024,3),2)
        AS remote_spill_gb,
    ANY_VALUE(qh.query_text) AS example_sql
FROM snowflake.account_usage.query_history qh
JOIN snowflake.account_usage.query_attribution_history qah
  ON qh.query_id = qah.query_id
WHERE qh.start_time >= DATEADD('day', -$DAYS, CURRENT_TIMESTAMP())
  AND qh.execution_status = 'SUCCESS'
GROUP BY 1
QUALIFY ROW_NUMBER() OVER (
    ORDER BY credits DESC, runs DESC, remote_spill_gb DESC
) <= 100;
