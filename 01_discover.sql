USE DATABASE DLA_SEMANTIC;
USE SCHEMA TENANT_ID_ADMIN;

CREATE OR REPLACE PROCEDURE REFRESH_TENANT_ID_DISCOVERY()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_run_id VARCHAR DEFAULT UUID_STRING();
    v_show_query_id VARCHAR;
    v_schema_show_count NUMBER;
    v_schema_count NUMBER DEFAULT 0;
    v_expected_dynamic_table_count NUMBER;
    v_transaction_started BOOLEAN DEFAULT FALSE;
    v_dynamic_table_count NUMBER;
    v_tenant_column_count NUMBER;
    v_tenant_name_candidate_count NUMBER;
    v_suspected_typo_count NUMBER;
    v_tenant_dynamic_table_count NUMBER;
    v_dependency_count NUMBER;
    v_policy_reference_count NUMBER;
    e_schema_limit EXCEPTION (-20001, 'A schema returned 10,000 Dynamic Tables; inventory would be ambiguous');
    e_incomplete_inventory EXCEPTION (-20002, 'SHOW inventory is smaller than the current ACCOUNT_USAGE inventory');
    e_ambiguous_identity EXCEPTION (-20003, 'Concatenated object names are not unique; quoted identifiers containing dots require an object-key extension');
    e_unsupported_identifier EXCEPTION (-20004, 'Object names containing dot or pipe are unsupported by the lineage-key format');
BEGIN
    INSERT INTO RUN_LOG (
        run_id, run_type, started_at, completed_at, status, initiated_by, details
    ) VALUES (
        :v_run_id, 'DISCOVERY', CURRENT_TIMESTAMP(), NULL, 'RUNNING', CURRENT_USER(), NULL
    );

    SELECT COUNT(*) INTO :v_expected_dynamic_table_count
    FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
    WHERE deleted IS NULL AND is_dynamic = 'YES';

    -- Account-wide SHOW fails above 10,000 rows and its cursor is only an object
    -- name, so it cannot safely paginate duplicate names across schemas. Seed
    -- schemas from ACCOUNT_USAGE and SHOW each schema independently instead.
    CREATE OR REPLACE TEMP TABLE TMP_DT_SHOW (
        object_fqn VARCHAR, database_name VARCHAR, schema_name VARCHAR,
        object_name VARCHAR, owner_role VARCHAR, created_on TIMESTAMP_LTZ,
        configured_target_lag VARCHAR, configured_refresh_mode VARCHAR,
        refresh_mode_reason VARCHAR, warehouse_name VARCHAR, scheduler VARCHAR,
        scheduling_state VARCHAR, definition_text VARCHAR,
        current_data_timestamp TIMESTAMP_LTZ, current_rows NUMBER,
        current_bytes NUMBER
    );

    FOR schema_rec IN (
        SELECT DISTINCT table_catalog AS database_name, table_schema AS schema_name
        FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
        WHERE deleted IS NULL AND is_dynamic = 'YES'
    ) DO
        LET v_show_sql VARCHAR :=
            'SHOW DYNAMIC TABLES IN SCHEMA "' ||
            REPLACE(schema_rec.database_name, '"', '""') || '"."' ||
            REPLACE(schema_rec.schema_name, '"', '""') || '" LIMIT 10000';

        EXECUTE IMMEDIATE :v_show_sql;
        v_show_query_id := SQLID;
        SELECT COUNT(*) INTO :v_schema_show_count
        FROM TABLE(RESULT_SCAN(:v_show_query_id));

        IF (v_schema_show_count >= 10000) THEN
            RAISE e_schema_limit;
        END IF;

        INSERT INTO TMP_DT_SHOW (
            object_fqn, database_name, schema_name, object_name, owner_role,
            created_on, configured_target_lag, configured_refresh_mode,
            refresh_mode_reason, warehouse_name, scheduler, scheduling_state,
            definition_text, current_data_timestamp, current_rows, current_bytes
        )
        SELECT
            "database_name"::VARCHAR || '.' || "schema_name"::VARCHAR || '.' || "name"::VARCHAR,
            "database_name"::VARCHAR, "schema_name"::VARCHAR, "name"::VARCHAR,
            "owner"::VARCHAR, "created_on"::TIMESTAMP_LTZ, "target_lag"::VARCHAR,
            UPPER("refresh_mode"::VARCHAR), "refresh_mode_reason"::VARCHAR,
            "warehouse"::VARCHAR, "scheduler"::VARCHAR, "scheduling_state"::VARCHAR,
            "text"::VARCHAR, "data_timestamp"::TIMESTAMP_LTZ,
            "rows"::NUMBER, "bytes"::NUMBER
        FROM TABLE(RESULT_SCAN(:v_show_query_id));

        v_schema_count := v_schema_count + 1;
    END FOR;

    SELECT COUNT(*) INTO :v_dynamic_table_count FROM TMP_DT_SHOW;
    IF (v_dynamic_table_count < v_expected_dynamic_table_count) THEN
        RAISE e_incomplete_inventory;
    END IF;
    IF (EXISTS(
        SELECT 1 FROM TMP_DT_SHOW GROUP BY object_fqn HAVING COUNT(*) > 1
    )) THEN
        RAISE e_ambiguous_identity;
    END IF;
    IF (EXISTS(
        SELECT 1 FROM TMP_DT_SHOW
        WHERE database_name LIKE '%.%' OR schema_name LIKE '%.%' OR object_name LIKE '%.%'
           OR database_name LIKE '%|%' OR schema_name LIKE '%|%' OR object_name LIKE '%|%'
    )) THEN
        RAISE e_unsupported_identifier;
    END IF;

    -- Inventory exact case/separator variants and plausible misspellings. Only
    -- APPROVED_VARIANT rows flow into the migration catalog automatically.
    CREATE OR REPLACE TEMP TABLE TMP_TENANT_ID_NAMES AS
    WITH named_columns AS (
        SELECT
            c.table_catalog || '.' || c.table_schema || '.' || c.table_name AS object_fqn,
            c.table_catalog AS database_name,
            c.table_schema AS schema_name,
            c.table_name AS object_name,
            t.table_type AS object_type,
            t.is_dynamic AS is_dynamic,
            c.column_name,
            REGEXP_REPLACE(UPPER(c.column_name), '[^A-Z0-9]', '') AS normalized_column_name,
            c.ordinal_position,
            c.data_type
        FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
        LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TABLES t
          ON t.table_catalog = c.table_catalog
         AND t.table_schema = c.table_schema
         AND t.table_name = c.table_name
         AND t.deleted IS NULL
        WHERE c.deleted IS NULL
    )
    SELECT
        object_fqn, database_name, schema_name, object_name, object_type,
        is_dynamic, column_name, normalized_column_name,
        EDITDISTANCE(normalized_column_name, 'TENANTID') AS edit_distance,
        IFF(normalized_column_name = 'TENANTID',
            'APPROVED_VARIANT', 'SUSPECTED_TYPO') AS match_class,
        ordinal_position, data_type, CURRENT_TIMESTAMP() AS discovered_at
    FROM named_columns
    WHERE normalized_column_name = 'TENANTID'
       OR (normalized_column_name LIKE 'TEN%ID'
           AND LENGTH(normalized_column_name) BETWEEN 6 AND 10
           AND EDITDISTANCE(normalized_column_name, 'TENANTID') <= 2);

    CREATE OR REPLACE TEMP TABLE TMP_TENANT_ID_COLUMNS AS
    SELECT
        n.object_fqn,
        n.database_name,
        n.schema_name,
        n.object_name,
        t.table_type AS table_type,
        t.is_dynamic AS is_dynamic,
        c.column_name AS column_name,
        c.ordinal_position AS ordinal_position,
        c.data_type AS data_type,
        c.character_maximum_length AS character_maximum_length,
        c.is_nullable AS is_nullable,
        CURRENT_TIMESTAMP() AS discovered_at
    FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
    JOIN TMP_TENANT_ID_NAMES n
      ON n.database_name = c.table_catalog
     AND n.schema_name = c.table_schema
     AND n.object_name = c.table_name
     AND n.column_name = c.column_name
     AND n.match_class = 'APPROVED_VARIANT'
    LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TABLES t
      ON t.table_catalog = c.table_catalog
     AND t.table_schema = c.table_schema
     AND t.table_name = c.table_name
     AND t.deleted IS NULL
    WHERE c.deleted IS NULL;

    -- Keep every dependency edge. Filtering first to edges touching a Dynamic
    -- Table loses base_table -> view edges earlier in an end-to-end path.
    CREATE OR REPLACE TEMP TABLE TMP_DEPENDENCIES AS
    SELECT DISTINCT
        referenced_database || '.' || referenced_schema || '.' || referenced_object_name AS upstream_fqn,
        referenced_object_domain AS upstream_domain,
        referencing_database || '.' || referencing_schema || '.' || referencing_object_name AS downstream_fqn,
        referencing_object_domain AS downstream_domain,
        dependency_type AS dependency_type,
        CURRENT_TIMESTAMP() AS discovered_at
    FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
    WHERE referenced_database IS NOT NULL
      AND referenced_schema IS NOT NULL
      AND referenced_object_name IS NOT NULL
      AND referencing_database IS NOT NULL
      AND referencing_schema IS NOT NULL
      AND referencing_object_name IS NOT NULL;

    CREATE OR REPLACE TEMP TABLE TMP_POLICY_REFERENCES AS
    SELECT
        ref_database_name || '.' || ref_schema_name || '.' || ref_entity_name AS object_fqn,
        ref_entity_domain AS object_domain,
        ref_column_name AS column_name,
        policy_db || '.' || policy_schema || '.' || policy_name AS policy_fqn,
        policy_kind AS policy_kind,
        policy_status AS policy_status,
        CURRENT_TIMESTAMP() AS discovered_at
    FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
    WHERE ref_database_name IS NOT NULL
      AND ref_schema_name IS NOT NULL
      AND ref_entity_name IS NOT NULL;

    CREATE OR REPLACE TEMP TABLE TMP_REFRESH_HEALTH AS
    SELECT
        database_name || '.' || schema_name || '.' || name AS object_fqn,
        COUNT(*) AS total_refreshes,
        COUNT_IF(UPPER(refresh_action) IN ('INCREMENTAL', 'CUSTOM_INCREMENTAL')) AS incremental_refreshes,
        COUNT_IF(UPPER(refresh_action) = 'FULL') AS full_refreshes,
        COUNT_IF(UPPER(refresh_action) = 'REINITIALIZE') AS reinitializations,
        COUNT_IF(state = 'FAILED') AS failed_refreshes,
        COUNT_IF(state = 'UPSTREAM_FAILED') AS upstream_failed_refreshes,
        COUNT_IF(refresh_end_time > completion_target AND state = 'SUCCEEDED') AS target_lag_misses,
        ROUND(AVG(DATEDIFF('second', refresh_start_time, refresh_end_time)), 2) AS avg_refresh_duration_sec,
        ROUND(APPROX_PERCENTILE(DATEDIFF('second', refresh_start_time, refresh_end_time), 0.95), 2) AS p95_refresh_duration_sec,
        ROUND(AVG(DATEDIFF('second', data_timestamp, refresh_end_time)), 2) AS avg_actual_lag_sec,
        ROUND(APPROX_PERCENTILE(DATEDIFF('second', data_timestamp, refresh_end_time), 0.95), 2) AS p95_actual_lag_sec,
        MAX(refresh_end_time) AS latest_refresh_end_time,
        CURRENT_TIMESTAMP() AS assessed_at
    FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY
    WHERE refresh_start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    GROUP BY database_name, schema_name, name;

    -- Publish all catalog snapshots atomically. A metadata or privilege failure
    -- above leaves the previous successful snapshot intact.
    BEGIN TRANSACTION;
    v_transaction_started := TRUE;

    DELETE FROM DYNAMIC_TABLE_CATALOG;
    INSERT INTO DYNAMIC_TABLE_CATALOG (
        object_fqn, database_name, schema_name, object_name, owner_role,
        created_on, configured_target_lag, configured_refresh_mode,
        refresh_mode_reason, warehouse_name, scheduler, scheduling_state, definition_text,
        current_data_timestamp, current_rows, current_bytes, discovered_at
    )
    SELECT object_fqn, database_name, schema_name, object_name, owner_role,
           created_on, configured_target_lag, configured_refresh_mode,
           refresh_mode_reason, warehouse_name, scheduler, scheduling_state, definition_text,
           current_data_timestamp, current_rows, current_bytes, CURRENT_TIMESTAMP()
    FROM TMP_DT_SHOW;

    DELETE FROM TENANT_ID_COLUMN_CATALOG;
    INSERT INTO TENANT_ID_COLUMN_CATALOG (
        object_fqn, database_name, schema_name, object_name, object_type,
        is_dynamic, column_name, ordinal_position, data_type,
        character_maximum_length, is_nullable, discovered_at
    )
    SELECT object_fqn, database_name, schema_name, object_name, table_type,
           is_dynamic, column_name, ordinal_position, data_type,
           character_maximum_length, is_nullable, discovered_at
    FROM TMP_TENANT_ID_COLUMNS;

    DELETE FROM TENANT_ID_NAME_CATALOG;
    INSERT INTO TENANT_ID_NAME_CATALOG (
        object_fqn, database_name, schema_name, object_name, object_type,
        is_dynamic, column_name, normalized_column_name, edit_distance,
        match_class, ordinal_position, data_type, discovered_at
    )
    SELECT object_fqn, database_name, schema_name, object_name, object_type,
           is_dynamic, column_name, normalized_column_name, edit_distance,
           match_class, ordinal_position, data_type, discovered_at
    FROM TMP_TENANT_ID_NAMES;

    DELETE FROM DEPENDENCY_CATALOG;
    INSERT INTO DEPENDENCY_CATALOG (
        upstream_fqn, upstream_domain, downstream_fqn, downstream_domain,
        dependency_type, discovered_at
    )
    SELECT upstream_fqn, upstream_domain, downstream_fqn, downstream_domain,
           dependency_type, discovered_at
    FROM TMP_DEPENDENCIES;

    DELETE FROM POLICY_REFERENCE_CATALOG;
    INSERT INTO POLICY_REFERENCE_CATALOG (
        object_fqn, object_domain, column_name, policy_fqn, policy_kind,
        policy_status, discovered_at
    )
    SELECT object_fqn, object_domain, column_name, policy_fqn, policy_kind,
           policy_status, discovered_at
    FROM TMP_POLICY_REFERENCES;

    DELETE FROM REFRESH_HEALTH_30D;
    INSERT INTO REFRESH_HEALTH_30D (
        object_fqn, total_refreshes, incremental_refreshes, full_refreshes,
        reinitializations, failed_refreshes, upstream_failed_refreshes,
        target_lag_misses, avg_refresh_duration_sec, p95_refresh_duration_sec,
        avg_actual_lag_sec, p95_actual_lag_sec, latest_refresh_end_time, assessed_at
    )
    SELECT object_fqn, total_refreshes, incremental_refreshes, full_refreshes,
           reinitializations, failed_refreshes, upstream_failed_refreshes,
           target_lag_misses, avg_refresh_duration_sec, p95_refresh_duration_sec,
           avg_actual_lag_sec, p95_actual_lag_sec, latest_refresh_end_time, assessed_at
    FROM TMP_REFRESH_HEALTH;

    COMMIT;
    v_transaction_started := FALSE;

    SELECT COUNT(*) INTO :v_dynamic_table_count FROM DYNAMIC_TABLE_CATALOG;
    SELECT COUNT(*) INTO :v_tenant_column_count FROM TENANT_ID_COLUMN_CATALOG;
    SELECT COUNT(*) INTO :v_tenant_name_candidate_count FROM TENANT_ID_NAME_CATALOG;
    SELECT COUNT(*) INTO :v_suspected_typo_count
    FROM TENANT_ID_NAME_CATALOG WHERE match_class = 'SUSPECTED_TYPO';
    SELECT COUNT(*) INTO :v_tenant_dynamic_table_count
    FROM TENANT_ID_COLUMN_CATALOG c
    JOIN DYNAMIC_TABLE_CATALOG d USING (object_fqn);
    SELECT COUNT(*) INTO :v_dependency_count FROM DEPENDENCY_CATALOG;
    SELECT COUNT(*) INTO :v_policy_reference_count FROM POLICY_REFERENCE_CATALOG;

    UPDATE RUN_LOG
    SET completed_at = CURRENT_TIMESTAMP(),
        status = 'SUCCEEDED',
        details = OBJECT_CONSTRUCT(
            'dynamic_tables', :v_dynamic_table_count,
            'schemas_scanned', :v_schema_count,
            'tenant_id_columns_all_objects', :v_tenant_column_count,
            'tenant_id_name_candidates', :v_tenant_name_candidate_count,
            'suspected_name_typos', :v_suspected_typo_count,
            'tenant_id_dynamic_tables', :v_tenant_dynamic_table_count,
            'dependency_edges', :v_dependency_count,
            'policy_references', :v_policy_reference_count
        )
    WHERE run_id = :v_run_id;

    RETURN OBJECT_CONSTRUCT(
        'run_id', v_run_id,
        'status', 'SUCCEEDED',
        'dynamic_tables', v_dynamic_table_count,
        'schemas_scanned', v_schema_count,
        'tenant_id_columns_all_objects', v_tenant_column_count,
        'tenant_id_name_candidates', v_tenant_name_candidate_count,
        'suspected_name_typos', v_suspected_typo_count,
        'tenant_id_dynamic_tables', v_tenant_dynamic_table_count,
        'dependency_edges', v_dependency_count,
        'policy_references', v_policy_reference_count
    );
EXCEPTION
    WHEN OTHER THEN
        IF (v_transaction_started) THEN
            ROLLBACK;
            v_transaction_started := FALSE;
        END IF;
        UPDATE RUN_LOG
        SET completed_at = CURRENT_TIMESTAMP(),
            status = 'FAILED',
            details = OBJECT_CONSTRUCT('error', :SQLERRM)
        WHERE run_id = :v_run_id;
        RAISE;
END;
$$;

CREATE OR REPLACE VIEW V_TENANT_ID_NAME_INVENTORY AS
SELECT
    column_name,
    normalized_column_name,
    match_class,
    edit_distance,
    COUNT(*) AS object_count,
    COUNT_IF(is_dynamic = 'YES') AS dynamic_table_count,
    ARRAY_AGG(DISTINCT object_type) WITHIN GROUP (ORDER BY object_type) AS object_types
FROM TENANT_ID_NAME_CATALOG
GROUP BY column_name, normalized_column_name, match_class, edit_distance;

CREATE OR REPLACE VIEW V_TENANT_ID_COLUMN_AMBIGUITY AS
SELECT
    object_fqn,
    COUNT(*) AS candidate_column_count,
    ARRAY_AGG(column_name) WITHIN GROUP (ORDER BY ordinal_position) AS candidate_columns
FROM TENANT_ID_COLUMN_CATALOG
GROUP BY object_fqn
HAVING COUNT(*) > 1;

-- Explicit execution step:
-- CALL REFRESH_TENANT_ID_DISCOVERY();
