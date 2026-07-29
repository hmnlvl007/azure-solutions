-- SNOWFLAKE CURRENT-STATE CONFIGURATION INVENTORY
-- Performance/query tuning intentionally excluded.
-- Run once per account/region with ACCOUNTADMIN or an audit role that can see
-- account objects and SNOWFLAKE.ACCOUNT_USAGE.
-- SHOW commands return only objects visible to the active role.

ALTER SESSION SET TIMEZONE = 'UTC';
SET HISTORY_DAYS = 90;

-- 00. Collection context
SELECT CURRENT_TIMESTAMP() AS collected_at_utc,
       CURRENT_ORGANIZATION_NAME() AS organization_name,
       CURRENT_ACCOUNT_NAME() AS account_name,
       CURRENT_ACCOUNT() AS account_identifier,
       CURRENT_REGION() AS region,
       CURRENT_VERSION() AS snowflake_version,
       CURRENT_ROLE() AS collection_role,
       CURRENT_USER() AS collection_user,
       CURRENT_WAREHOUSE() AS collection_warehouse;

SHOW PARAMETERS IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "key";

-- 01. Organization/account topology (requires organization-level visibility)
SHOW ORGANIZATION ACCOUNTS;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "organization_name", "account_name";

SHOW REPLICATION ACCOUNTS;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- 02. Databases, schemas, and object inventory
SHOW DATABASES;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

SHOW SCHEMAS IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "name";

SHOW TABLES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW VIEWS IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW MATERIALIZED VIEWS IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW DYNAMIC TABLES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW EXTERNAL TABLES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW ICEBERG TABLES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW HYBRID TABLES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW EVENT TABLES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SELECT table_catalog AS database_name,
       table_schema AS schema_name,
       table_type,
       is_transient,
       COUNT(*) AS object_count,
       SUM(row_count) AS reported_rows,
       SUM(bytes) AS reported_bytes
FROM snowflake.account_usage.tables
WHERE deleted IS NULL
GROUP BY 1,2,3,4
ORDER BY 1,2,3,4;

SELECT * FROM snowflake.account_usage.databases
WHERE deleted IS NULL
ORDER BY database_name;

SELECT * FROM snowflake.account_usage.schemata
WHERE deleted IS NULL
ORDER BY catalog_name, schema_name;

-- 03. Warehouse configuration
SHOW WAREHOUSES;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

SHOW RESOURCE MONITORS;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

SELECT * FROM snowflake.account_usage.resource_monitors
WHERE deleted_on IS NULL
ORDER BY name;

-- 04. Budgets and cost-governance configuration
SHOW SNOWFLAKE.CORE.BUDGET;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

SELECT SYSTEM$SHOW_BUDGETS_IN_ACCOUNT() AS budgets_in_account;

SHOW PARAMETERS LIKE 'BUDGET%' IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "key";

SELECT usage_date,
       service_type,
       credits_used,
       credits_adjustment_cloud_services,
       credits_billed
FROM snowflake.account_usage.metering_daily_history
WHERE usage_date >= DATEADD('day', -$HISTORY_DAYS, CURRENT_DATE())
ORDER BY usage_date DESC, service_type;

SELECT service_type,
       SUM(credits_used) AS credits_used,
       SUM(credits_adjustment_cloud_services) AS cloud_services_adjustment,
       SUM(credits_billed) AS credits_billed
FROM snowflake.account_usage.metering_daily_history
WHERE usage_date >= DATEADD('day', -$HISTORY_DAYS, CURRENT_DATE())
GROUP BY service_type
ORDER BY credits_billed DESC;

-- 05. Storage, retention, fail-safe, and clones
SELECT *
FROM snowflake.account_usage.storage_usage
WHERE usage_date >= DATEADD('day', -$HISTORY_DAYS, CURRENT_DATE())
ORDER BY usage_date DESC;

SELECT *
FROM snowflake.account_usage.database_storage_usage_history
WHERE usage_date >= DATEADD('day', -$HISTORY_DAYS, CURRENT_DATE())
ORDER BY usage_date DESC, database_name;

SELECT table_catalog,
       table_schema,
       table_name,
       table_id,
       clone_group_id,
       is_transient,
       active_bytes,
       time_travel_bytes,
       failsafe_bytes,
       retained_for_clone_bytes,
       table_created,
       table_dropped,
       table_entered_failsafe
FROM snowflake.account_usage.table_storage_metrics
ORDER BY active_bytes + time_travel_bytes + failsafe_bytes
       + retained_for_clone_bytes DESC;

SELECT *
FROM snowflake.account_usage.stage_storage_usage_history
WHERE usage_date >= DATEADD('day', -$HISTORY_DAYS, CURRENT_DATE())
ORDER BY usage_date DESC;

SHOW STAGES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW FILE FORMATS IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

-- 06. Pipelines and data engineering setup
SHOW TASKS IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW STREAMS IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW PIPES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW PROCEDURES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "catalog_name", "schema_name", "name";

SHOW USER FUNCTIONS IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "catalog_name", "schema_name", "name";

SELECT *
FROM TABLE(snowflake.information_schema.dynamic_tables(RESULT_LIMIT => 10000))
ORDER BY database_name, schema_name, name;

SELECT *
FROM TABLE(snowflake.information_schema.dynamic_table_graph_history())
ORDER BY valid_from DESC;

SELECT database_name, schema_name, name, graph_version, state,
       scheduled_time, query_start_time, completed_time,
       error_code, error_message
FROM snowflake.account_usage.task_history
WHERE scheduled_time >= DATEADD('day', -$HISTORY_DAYS, CURRENT_TIMESTAMP())
ORDER BY scheduled_time DESC;

SELECT pipe_name, table_catalog_name, table_schema_name, table_name,
       status, last_load_time, row_count, row_parsed, first_error_message
FROM snowflake.account_usage.copy_history
WHERE last_load_time >= DATEADD('day', -$HISTORY_DAYS, CURRENT_TIMESTAMP())
ORDER BY last_load_time DESC;

-- 07. Integrations and connectivity
SHOW INTEGRATIONS;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "category", "type", "name";

SHOW STORAGE INTEGRATIONS;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

SHOW SECURITY INTEGRATIONS;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "type", "name";

SHOW NOTIFICATION INTEGRATIONS;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "type", "name";

SHOW API INTEGRATIONS;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

SHOW EXTERNAL ACCESS INTEGRATIONS;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

SHOW CATALOG INTEGRATIONS;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

SHOW GIT REPOSITORIES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW NETWORK RULES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

-- For each integration returned above, run:
-- DESC INTEGRATION <integration_name>;

-- 08. Users, roles, and grants
SHOW USERS;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

SHOW ROLES;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

SHOW DATABASE ROLES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "name";

SELECT name, login_name, display_name, type, disabled, has_password,
       has_mfa, ext_authn_duo, default_role, default_secondary_role,
       default_warehouse, last_success_login, expires_at, locked_until_time,
       created_on, owner, comment
FROM snowflake.account_usage.users
WHERE deleted_on IS NULL
ORDER BY name;

SELECT role, grantee_name AS user_name, granted_by, created_on
FROM snowflake.account_usage.grants_to_users
WHERE deleted_on IS NULL
ORDER BY user_name, role;

SELECT *
FROM snowflake.account_usage.grants_to_roles
WHERE deleted_on IS NULL
ORDER BY grantee_name, granted_on, name, privilege;

SELECT *
FROM snowflake.account_usage.grants_to_database_roles
WHERE deleted_on IS NULL
ORDER BY grantee_name, granted_database_role_name;

SELECT role, grantee_name AS user_name, created_on
FROM snowflake.account_usage.grants_to_users
WHERE deleted_on IS NULL
  AND role IN ('ORGADMIN','GLOBALORGADMIN','ACCOUNTADMIN',
               'SECURITYADMIN','USERADMIN','SYSADMIN')
ORDER BY role, user_name;

-- 09. Authentication and network security
SHOW NETWORK POLICIES;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

SELECT * FROM snowflake.account_usage.network_policies
WHERE deleted IS NULL
ORDER BY name;

SELECT *
FROM snowflake.account_usage.network_rule_references
ORDER BY container_name, network_rule_name;

SHOW PARAMETERS LIKE '%MFA%' IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "key";

SHOW PARAMETERS LIKE '%AUTHENTICATION%' IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "key";

SHOW PARAMETERS LIKE '%NETWORK%' IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "key";

SELECT authentication_method,
       client_application_id,
       COUNT(*) AS session_count,
       COUNT(DISTINCT user_name) AS distinct_users,
       MAX(created_on) AS most_recent_session
FROM snowflake.account_usage.sessions
WHERE created_on >= DATEADD('day', -$HISTORY_DAYS, CURRENT_TIMESTAMP())
GROUP BY 1,2
ORDER BY session_count DESC;

SELECT user_name, reported_client_type, error_code, error_message,
       COUNT(*) AS failure_count,
       MIN(event_timestamp) AS first_failure,
       MAX(event_timestamp) AS last_failure
FROM snowflake.account_usage.login_history
WHERE event_timestamp >= DATEADD('day', -$HISTORY_DAYS, CURRENT_TIMESTAMP())
  AND is_success = 'NO'
GROUP BY 1,2,3,4
ORDER BY failure_count DESC;

-- 10. Tags, policies, and Horizon metadata
SHOW TAGS IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SELECT *
FROM snowflake.account_usage.tags
WHERE deleted IS NULL
ORDER BY tag_database, tag_schema, tag_name;

-- Direct assignments only; inherited tags are not included here.
SELECT *
FROM snowflake.account_usage.tag_references
WHERE object_deleted IS NULL
ORDER BY tag_database, tag_schema, tag_name,
         object_database, object_schema, object_name, column_name;

SHOW MASKING POLICIES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW ROW ACCESS POLICIES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW AGGREGATION POLICIES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW PROJECTION POLICIES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW JOIN POLICIES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SELECT *
FROM snowflake.account_usage.policy_references
ORDER BY policy_kind, policy_db, policy_schema, policy_name,
         ref_database_name, ref_schema_name, ref_entity_name;

SELECT table_catalog, table_schema, table_name, column_name,
       ordinal_position, data_type, is_nullable, comment
FROM snowflake.account_usage.columns
WHERE deleted IS NULL
ORDER BY table_catalog, table_schema, table_name, ordinal_position;

SELECT table_catalog, table_schema, table_type,
       COUNT(*) AS object_count,
       COUNT_IF(comment IS NOT NULL AND TRIM(comment) <> '') AS documented_count,
       ROUND(100 * COUNT_IF(comment IS NOT NULL AND TRIM(comment) <> '')
             / NULLIF(COUNT(*), 0), 2) AS documented_pct
FROM snowflake.account_usage.tables
WHERE deleted IS NULL
GROUP BY 1,2,3
ORDER BY 1,2,3;

-- 11. Shares, listings, and Native Apps
SHOW SHARES;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "kind", "name";

SHOW LISTINGS;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

SHOW APPLICATIONS;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

SHOW APPLICATION PACKAGES;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

-- 12. Replication, failover, and regional transfer
SHOW REPLICATION GROUPS;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

SHOW FAILOVER GROUPS;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

SELECT *
FROM snowflake.account_usage.replication_groups
WHERE deleted IS NULL
ORDER BY group_name;

SELECT *
FROM snowflake.account_usage.replication_group_refresh_history
WHERE start_time >= DATEADD('day', -$HISTORY_DAYS, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;

SELECT *
FROM snowflake.account_usage.replication_group_usage_history
WHERE start_time >= DATEADD('day', -$HISTORY_DAYS, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;

SELECT *
FROM snowflake.account_usage.data_transfer_history
WHERE start_time >= DATEADD('day', -$HISTORY_DAYS, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;

-- 13. Snowpark Container Services and developer objects
SHOW PACKAGES;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "language", "package_name", "version";

SHOW COMPUTE POOLS;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "name";

SHOW SERVICES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW IMAGE REPOSITORIES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW NOTEBOOKS IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

-- 14. AI/Cortex and semantic objects
SHOW SEMANTIC VIEWS IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW CORTEX SEARCH SERVICES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SELECT service_type,
       SUM(credits_used) AS credits_used,
       SUM(credits_billed) AS credits_billed
FROM snowflake.account_usage.metering_daily_history
WHERE usage_date >= DATEADD('day', -$HISTORY_DAYS, CURRENT_DATE())
  AND (service_type ILIKE '%CORTEX%'
       OR service_type ILIKE '%AI%'
       OR service_type ILIKE '%SEARCH%'
       OR service_type ILIKE '%ML%')
GROUP BY service_type
ORDER BY credits_billed DESC;

-- 15. Alerts and telemetry configuration
SHOW ALERTS IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW EVENT TABLES IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "database_name", "schema_name", "name";

SHOW PARAMETERS LIKE '%EVENT_TABLE%' IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "key";

SHOW PARAMETERS LIKE '%LOG_LEVEL%' IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "key";

SHOW PARAMETERS LIKE '%TRACE_LEVEL%' IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "key";

SHOW PARAMETERS LIKE '%METRIC_LEVEL%' IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY "key";

-- Manual confirmations still required:
-- business owners/stewards; naming/tagging standards; Terraform/CI-CD source
-- of truth; change/rollback process; RTO/RPO and latest DR test; incident/on-call
-- ownership; contracted credit price; legal retention; AI governance.
