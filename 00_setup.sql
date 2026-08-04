-- Run once. Change the database/schema here and in the remaining scripts if
-- DLA_SEMANTIC is not the desired control database.
USE DATABASE DLA_SEMANTIC;
CREATE SCHEMA IF NOT EXISTS TENANT_ID_ADMIN;
USE SCHEMA TENANT_ID_ADMIN;

CREATE TABLE IF NOT EXISTS RUN_LOG (
    run_id              VARCHAR NOT NULL,
    run_type            VARCHAR NOT NULL,
    started_at          TIMESTAMP_LTZ NOT NULL,
    completed_at        TIMESTAMP_LTZ,
    status              VARCHAR NOT NULL,
    initiated_by        VARCHAR NOT NULL,
    details             VARIANT
);

CREATE TABLE IF NOT EXISTS DYNAMIC_TABLE_CATALOG (
    object_fqn                  VARCHAR NOT NULL,
    database_name               VARCHAR NOT NULL,
    schema_name                 VARCHAR NOT NULL,
    object_name                 VARCHAR NOT NULL,
    owner_role                  VARCHAR,
    created_on                  TIMESTAMP_LTZ,
    configured_target_lag       VARCHAR,
    configured_refresh_mode     VARCHAR,
    refresh_mode_reason         VARCHAR,
    warehouse_name              VARCHAR,
    scheduler                   VARCHAR,
    scheduling_state            VARCHAR,
    definition_text             VARCHAR,
    current_data_timestamp      TIMESTAMP_LTZ,
    current_rows                NUMBER,
    current_bytes               NUMBER,
    discovered_at               TIMESTAMP_LTZ NOT NULL,
    CONSTRAINT PK_DT_CATALOG PRIMARY KEY (object_fqn) NOT ENFORCED
);

-- Upgrade an existing control schema created by an earlier toolkit version.
ALTER TABLE DYNAMIC_TABLE_CATALOG ADD COLUMN IF NOT EXISTS scheduler VARCHAR;

CREATE TABLE IF NOT EXISTS TENANT_ID_COLUMN_CATALOG (
    object_fqn              VARCHAR NOT NULL,
    database_name           VARCHAR NOT NULL,
    schema_name             VARCHAR NOT NULL,
    object_name             VARCHAR NOT NULL,
    object_type             VARCHAR,
    is_dynamic              VARCHAR,
    column_name             VARCHAR NOT NULL,
    ordinal_position        NUMBER,
    data_type               VARCHAR,
    character_maximum_length NUMBER,
    is_nullable             VARCHAR,
    discovered_at           TIMESTAMP_LTZ NOT NULL,
    CONSTRAINT PK_TENANT_COLUMN PRIMARY KEY (object_fqn, column_name) NOT ENFORCED
);

-- Broader naming investigation. APPROVED_VARIANT means the identifier becomes
-- TENANTID after removing separators and folding case. Near matches are kept
-- for review but are not fed automatically into analysis or migration.
CREATE TABLE IF NOT EXISTS TENANT_ID_NAME_CATALOG (
    object_fqn              VARCHAR NOT NULL,
    database_name           VARCHAR NOT NULL,
    schema_name             VARCHAR NOT NULL,
    object_name             VARCHAR NOT NULL,
    object_type             VARCHAR,
    is_dynamic              VARCHAR,
    column_name             VARCHAR NOT NULL,
    normalized_column_name  VARCHAR NOT NULL,
    edit_distance           NUMBER NOT NULL,
    match_class             VARCHAR NOT NULL,
    ordinal_position        NUMBER,
    data_type               VARCHAR,
    discovered_at           TIMESTAMP_LTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS TENANT_ID_DEFINITION_INSPECTION (
    inspection_id VARCHAR NOT NULL, run_id VARCHAR NOT NULL,
    object_fqn VARCHAR NOT NULL, object_type VARCHAR, is_dynamic VARCHAR,
    is_secure BOOLEAN, column_name VARCHAR NOT NULL, effective_collation VARCHAR,
    ddl_object_type VARCHAR, definition_text VARCHAR,
    definition_has_collate BOOLEAN, definition_has_upper BOOLEAN,
    definition_has_collation_function BOOLEAN,
    definition_has_lower BOOLEAN, definition_has_ilike BOOLEAN,
    tenant_expression_has_collate BOOLEAN,
    tenant_expression_has_upper BOOLEAN,
    tenant_expression_has_lower BOOLEAN,
    inspection_status VARCHAR NOT NULL, error_message VARCHAR,
    inspected_at TIMESTAMP_LTZ NOT NULL,
    CONSTRAINT PK_TENANT_DEFINITION_INSPECTION PRIMARY KEY (inspection_id) NOT ENFORCED
);
ALTER TABLE TENANT_ID_DEFINITION_INSPECTION
    ADD COLUMN IF NOT EXISTS definition_has_collation_function BOOLEAN;
ALTER TABLE TENANT_ID_DEFINITION_INSPECTION ADD COLUMN IF NOT EXISTS is_secure BOOLEAN;
ALTER TABLE TENANT_ID_DEFINITION_INSPECTION ADD COLUMN IF NOT EXISTS tenant_expression_has_collate BOOLEAN;
ALTER TABLE TENANT_ID_DEFINITION_INSPECTION ADD COLUMN IF NOT EXISTS tenant_expression_has_upper BOOLEAN;
ALTER TABLE TENANT_ID_DEFINITION_INSPECTION ADD COLUMN IF NOT EXISTS tenant_expression_has_lower BOOLEAN;

CREATE TABLE IF NOT EXISTS TENANT_ID_VIEW_DEFINITION_SCAN (
    scan_id VARCHAR NOT NULL, run_id VARCHAR NOT NULL,
    database_name VARCHAR NOT NULL, schema_name VARCHAR NOT NULL,
    view_name VARCHAR NOT NULL, object_fqn VARCHAR NOT NULL,
    is_secure BOOLEAN, view_definition VARCHAR,
    definition_available BOOLEAN NOT NULL,
    references_tenant_identifier BOOLEAN NOT NULL,
    tenant_expression_has_collate BOOLEAN NOT NULL,
    tenant_expression_has_upper BOOLEAN NOT NULL,
    tenant_expression_has_lower BOOLEAN NOT NULL,
    tenant_expression_has_ilike BOOLEAN NOT NULL,
    scanned_at TIMESTAMP_LTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS TENANT_ID_COLUMN_LINEAGE (
    lineage_id VARCHAR NOT NULL, run_id VARCHAR NOT NULL,
    root_dynamic_table_fqn VARCHAR NOT NULL,
    root_column_name VARCHAR NOT NULL,
    direction VARCHAR NOT NULL,
    source_object_database VARCHAR, source_object_schema VARCHAR,
    source_object_name VARCHAR, source_object_domain VARCHAR,
    source_column_name VARCHAR, source_status VARCHAR,
    target_object_database VARCHAR, target_object_schema VARCHAR,
    target_object_name VARCHAR, target_object_domain VARCHAR,
    target_column_name VARCHAR, target_status VARCHAR,
    distance NUMBER, process VARIANT, collected_at TIMESTAMP_LTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS TENANT_ID_COLUMN_LINEAGE_ERRORS (
    error_id VARCHAR NOT NULL, run_id VARCHAR NOT NULL,
    root_dynamic_table_fqn VARCHAR NOT NULL,
    root_column_name VARCHAR NOT NULL, direction VARCHAR NOT NULL,
    error_message VARCHAR NOT NULL, occurred_at TIMESTAMP_LTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS DEPENDENCY_CATALOG (
    upstream_fqn            VARCHAR NOT NULL,
    upstream_domain         VARCHAR,
    downstream_fqn          VARCHAR NOT NULL,
    downstream_domain       VARCHAR,
    dependency_type         VARCHAR,
    discovered_at           TIMESTAMP_LTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS POLICY_REFERENCE_CATALOG (
    object_fqn              VARCHAR NOT NULL,
    object_domain           VARCHAR,
    column_name             VARCHAR,
    policy_fqn              VARCHAR NOT NULL,
    policy_kind             VARCHAR,
    policy_status           VARCHAR,
    discovered_at           TIMESTAMP_LTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS OBSERVED_TENANT_ID_ACCESS_30D (
    object_fqn              VARCHAR NOT NULL,
    object_domain           VARCHAR,
    lineage_level           VARCHAR NOT NULL,
    query_count             NUMBER NOT NULL,
    distinct_users          NUMBER,
    first_accessed_at       TIMESTAMP_LTZ,
    last_accessed_at        TIMESTAMP_LTZ,
    refreshed_at            TIMESTAMP_LTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS REFRESH_HEALTH_30D (
    object_fqn                      VARCHAR NOT NULL,
    total_refreshes                 NUMBER,
    incremental_refreshes           NUMBER,
    full_refreshes                  NUMBER,
    reinitializations               NUMBER,
    failed_refreshes                NUMBER,
    upstream_failed_refreshes       NUMBER,
    target_lag_misses               NUMBER,
    avg_refresh_duration_sec        NUMBER(38,2),
    p95_refresh_duration_sec        NUMBER(38,2),
    avg_actual_lag_sec              NUMBER(38,2),
    p95_actual_lag_sec              NUMBER(38,2),
    latest_refresh_end_time         TIMESTAMP_LTZ,
    assessed_at                     TIMESTAMP_LTZ NOT NULL,
    CONSTRAINT PK_REFRESH_HEALTH PRIMARY KEY (object_fqn) NOT ENFORCED
);

CREATE TABLE IF NOT EXISTS TENANT_ID_ANALYSIS (
    analysis_id                 VARCHAR NOT NULL,
    run_id                      VARCHAR NOT NULL,
    object_fqn                  VARCHAR NOT NULL,
    analysis_mode               VARCHAR NOT NULL,
    observed_collation          VARCHAR,
    definition_class           VARCHAR,
    total_rows                  NUMBER,
    null_rows                   NUMBER,
    invalid_guid_rows           NUMBER,
    noncanonical_rows           NUMBER,
    collision_groups           NUMBER,
    analysis_status             VARCHAR NOT NULL,
    error_message               VARCHAR,
    analyzed_at                 TIMESTAMP_LTZ NOT NULL,
    CONSTRAINT PK_TENANT_ANALYSIS PRIMARY KEY (analysis_id) NOT ENFORCED
);

CREATE TABLE IF NOT EXISTS MIGRATION_MANIFEST (
    migration_id               VARCHAR NOT NULL,
    object_fqn                  VARCHAR NOT NULL,
    strategy                    VARCHAR NOT NULL,
    risk_score                  NUMBER NOT NULL,
    risk_reasons                ARRAY,
    upstream_count              NUMBER,
    downstream_count            NUMBER,
    security_review_required    BOOLEAN NOT NULL DEFAULT TRUE,
    original_ddl                VARCHAR,
    proposed_ddl                VARCHAR,
    change_reference            VARCHAR,
    status                      VARCHAR NOT NULL,
    generated_at                TIMESTAMP_LTZ NOT NULL,
    reviewed_by                 VARCHAR,
    reviewed_at                 TIMESTAMP_LTZ,
    security_reviewed_by        VARCHAR,
    security_reviewed_at        TIMESTAMP_LTZ,
    approved_by                 VARCHAR,
    approved_at                 TIMESTAMP_LTZ,
    applied_by                  VARCHAR,
    applied_at                  TIMESTAMP_LTZ,
    applied_ddl                 VARCHAR,
    validated_at                TIMESTAMP_LTZ,
    rollback_ddl                VARCHAR,
    rolled_back_by              VARCHAR,
    rolled_back_at              TIMESTAMP_LTZ,
    last_error                  VARCHAR,
    CONSTRAINT PK_MIGRATION_MANIFEST PRIMARY KEY (migration_id) NOT ENFORCED
);

-- Upgrade-safe additions for environments that installed an earlier revision.
ALTER TABLE MIGRATION_MANIFEST ADD COLUMN IF NOT EXISTS security_reviewed_by VARCHAR;
ALTER TABLE MIGRATION_MANIFEST ADD COLUMN IF NOT EXISTS security_reviewed_at TIMESTAMP_LTZ;
ALTER TABLE MIGRATION_MANIFEST ADD COLUMN IF NOT EXISTS applied_ddl VARCHAR;

CREATE TABLE IF NOT EXISTS MIGRATION_AUDIT (
    event_id                VARCHAR NOT NULL,
    migration_id            VARCHAR NOT NULL,
    event_type              VARCHAR NOT NULL,
    event_status            VARCHAR NOT NULL,
    actor                   VARCHAR NOT NULL,
    event_at                TIMESTAMP_LTZ NOT NULL,
    executed_sql            VARCHAR,
    details                 VARIANT
);
