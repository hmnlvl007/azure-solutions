USE DATABASE DLA_SEMANTIC;
USE SCHEMA TENANT_ID_ADMIN;

-- Bounded inspection across ordinary tables, views, and Dynamic Tables.
DROP PROCEDURE IF EXISTS INSPECT_TENANT_ID_DEFINITIONS(VARCHAR, VARCHAR, NUMBER);

CREATE OR REPLACE PROCEDURE INSPECT_TENANT_ID_DEFINITIONS(
    DATABASE_FILTER VARCHAR,
    SCHEMA_FILTERS ARRAY,
    OBJECT_TYPE_FILTER VARCHAR,
    MAX_OBJECTS NUMBER
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_run_id VARCHAR DEFAULT UUID_STRING();
    v_limit NUMBER DEFAULT COALESCE(MAX_OBJECTS, 1000);
    v_processed NUMBER DEFAULT 0;
    v_succeeded NUMBER DEFAULT 0;
    v_failed NUMBER DEFAULT 0;
    v_fqn VARCHAR;
    v_column_identifier VARCHAR;
    v_ddl_type VARCHAR;
    v_sql VARCHAR;
    v_query_id VARCHAR;
    v_collation VARCHAR;
    v_definition VARCHAR;
    candidate_cursor CURSOR FOR
        SELECT n.database_name, n.schema_name, n.object_name, n.object_fqn,
               n.object_type, n.is_dynamic, n.column_name,
               IFF(UPPER(COALESCE(v.is_secure::VARCHAR, 'NO')) IN ('YES', 'TRUE'),
                   TRUE, FALSE) AS is_secure
        FROM TENANT_ID_NAME_CATALOG n
        LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.VIEWS v
          ON v.table_catalog = n.database_name
         AND v.table_schema = n.schema_name
         AND v.table_name = n.object_name
         AND v.deleted IS NULL
        WHERE n.match_class = 'APPROVED_VARIANT'
        ORDER BY database_name, schema_name, object_name, ordinal_position;
BEGIN
    IF (v_limit < 1 OR v_limit > 10000) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'MAX_OBJECTS must be between 1 and 10000');
    END IF;

    INSERT INTO RUN_LOG (
        run_id, run_type, started_at, completed_at, status, initiated_by, details
    ) VALUES (
        :v_run_id, 'DEFINITION_INSPECTION', CURRENT_TIMESTAMP(), NULL,
        'RUNNING', CURRENT_USER(), NULL
    );

    FOR rec IN candidate_cursor DO
        IF (DATABASE_FILTER IS NOT NULL
            AND UPPER(rec.database_name) <> UPPER(DATABASE_FILTER)) THEN CONTINUE; END IF;
        IF (SCHEMA_FILTERS IS NOT NULL
            AND NOT ARRAY_CONTAINS(rec.schema_name::VARIANT, SCHEMA_FILTERS)
            AND NOT ARRAY_CONTAINS(UPPER(rec.schema_name)::VARIANT, SCHEMA_FILTERS)) THEN
            CONTINUE;
        END IF;
        v_fqn := '"' || REPLACE(rec.database_name, '"', '""') || '"."' ||
                 REPLACE(rec.schema_name, '"', '""') || '"."' ||
                 REPLACE(rec.object_name, '"', '""') || '"';
        v_column_identifier := '"' || REPLACE(rec.column_name, '"', '""') || '"';
        v_ddl_type := CASE
            WHEN rec.is_dynamic = 'YES' THEN 'DYNAMIC_TABLE'
            WHEN UPPER(COALESCE(rec.object_type, '')) LIKE '%MATERIALIZED%VIEW%' THEN 'MATERIALIZED_VIEW'
            WHEN UPPER(COALESCE(rec.object_type, '')) LIKE '%VIEW%' THEN 'VIEW'
            ELSE 'TABLE'
        END;
        IF (OBJECT_TYPE_FILTER IS NOT NULL
            AND UPPER(OBJECT_TYPE_FILTER) <> 'ALL'
            AND UPPER(OBJECT_TYPE_FILTER) <> v_ddl_type) THEN
            CONTINUE;
        END IF;
        IF (v_processed >= v_limit) THEN BREAK; END IF;
        v_processed := v_processed + 1;

        BEGIN
            -- MAX aggregate returns one row even for an empty object.
            v_sql := 'SELECT COALESCE(MAX(c), '''') FROM (' ||
                     'SELECT COLLATION(' || v_column_identifier || ') c FROM ' ||
                     v_fqn || ' LIMIT 1)';
            EXECUTE IMMEDIATE :v_sql;
            v_query_id := SQLID;
            SELECT $1::VARCHAR INTO :v_collation FROM TABLE(RESULT_SCAN(:v_query_id));

            v_sql := 'SELECT GET_DDL(''' || REPLACE(v_ddl_type, '''', '''''') ||
                     ''', ''' || REPLACE(v_fqn, '''', '''''') || ''')';
            EXECUTE IMMEDIATE :v_sql;
            v_query_id := SQLID;
            SELECT $1::VARCHAR INTO :v_definition FROM TABLE(RESULT_SCAN(:v_query_id));

            INSERT INTO TENANT_ID_DEFINITION_INSPECTION (
                inspection_id, run_id, object_fqn, object_type, is_dynamic, is_secure,
                column_name, effective_collation, ddl_object_type,
                definition_text, definition_has_collate, definition_has_upper,
                definition_has_collation_function, definition_has_lower,
                definition_has_ilike, tenant_expression_has_collate,
                tenant_expression_has_upper, tenant_expression_has_lower, inspection_status,
                error_message, inspected_at
            ) VALUES (
                UUID_STRING(), :v_run_id, rec.object_fqn, rec.object_type,
                rec.is_dynamic, rec.is_secure, rec.column_name, NULLIF(:v_collation, ''),
                :v_ddl_type, :v_definition,
                COALESCE(:v_definition, '') ILIKE '%COLLATE%',
                REGEXP_LIKE(COALESCE(:v_definition, ''), '(^|[^A-Z])UPPER\\s*\\(', 'i'),
                REGEXP_LIKE(COALESCE(:v_definition, ''), '(^|[^A-Z])COLLATION\\s*\\(', 'i'),
                REGEXP_LIKE(COALESCE(:v_definition, ''), '(^|[^A-Z])LOWER\\s*\\(', 'i'),
                COALESCE(:v_definition, '') ILIKE '%ILIKE%',
                REGEXP_LIKE(COALESCE(:v_definition, ''),
                  'COLLATE\\s*\\([^)]*TENANT[ _$-]*ID|TENANT[ _$-]*ID[^,;)]*COLLATE|COLLATE\\s*\\([^)]*\\)\\s+AS\\s+"?TENANT[ _$-]*ID', 'i'),
                REGEXP_LIKE(COALESCE(:v_definition, ''),
                  'UPPER\\s*\\([^)]*TENANT[ _$-]*ID|UPPER\\s*\\([^)]*\\)\\s+AS\\s+"?TENANT[ _$-]*ID', 'i'),
                REGEXP_LIKE(COALESCE(:v_definition, ''),
                  'LOWER\\s*\\([^)]*TENANT[ _$-]*ID|LOWER\\s*\\([^)]*\\)\\s+AS\\s+"?TENANT[ _$-]*ID', 'i'),
                'SUCCEEDED', NULL, CURRENT_TIMESTAMP()
            );
            v_succeeded := v_succeeded + 1;
        EXCEPTION
            WHEN OTHER THEN
                INSERT INTO TENANT_ID_DEFINITION_INSPECTION (
                    inspection_id, run_id, object_fqn, object_type, is_dynamic, is_secure,
                    column_name, effective_collation, ddl_object_type,
                    definition_text, definition_has_collate, definition_has_upper,
                    definition_has_collation_function, definition_has_lower,
                    definition_has_ilike, tenant_expression_has_collate,
                    tenant_expression_has_upper, tenant_expression_has_lower, inspection_status,
                    error_message, inspected_at
                ) VALUES (
                    UUID_STRING(), :v_run_id, rec.object_fqn, rec.object_type,
                    rec.is_dynamic, rec.is_secure, rec.column_name, NULL, :v_ddl_type, NULL,
                    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                    'FAILED', :SQLERRM, CURRENT_TIMESTAMP()
                );
                v_failed := v_failed + 1;
        END;
    END FOR;

    UPDATE RUN_LOG
    SET completed_at = CURRENT_TIMESTAMP(),
        status = IFF(:v_failed = 0, 'SUCCEEDED', 'SUCCEEDED_WITH_ERRORS'),
        details = OBJECT_CONSTRUCT('processed', :v_processed,
                                   'succeeded', :v_succeeded, 'failed', :v_failed)
    WHERE run_id = :v_run_id;

    RETURN OBJECT_CONSTRUCT('run_id', v_run_id,
        'status', IFF(v_failed = 0, 'SUCCEEDED', 'SUCCEEDED_WITH_ERRORS'),
        'processed', v_processed, 'succeeded', v_succeeded, 'failed', v_failed);
EXCEPTION
    WHEN OTHER THEN
        UPDATE RUN_LOG
        SET completed_at = CURRENT_TIMESTAMP(), status = 'FAILED',
            details = OBJECT_CONSTRUCT('error', :SQLERRM, 'processed', :v_processed)
        WHERE run_id = :v_run_id;
        RAISE;
END;
$$;

CREATE OR REPLACE VIEW V_LATEST_TENANT_ID_DEFINITION_INSPECTION AS
SELECT
    inspection_id, run_id, object_fqn, object_type, is_dynamic, is_secure, column_name,
    effective_collation, ddl_object_type, definition_has_collate,
    definition_has_upper, definition_has_collation_function,
    definition_has_lower, definition_has_ilike,
    tenant_expression_has_collate, tenant_expression_has_upper,
    tenant_expression_has_lower,
    inspection_status, error_message, inspected_at, definition_text
FROM TENANT_ID_DEFINITION_INSPECTION
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY object_fqn, column_name ORDER BY inspected_at DESC
) = 1;

CREATE OR REPLACE VIEW V_TENANT_ID_VIEW_DEFINITION_USAGE AS
SELECT
    object_fqn,
    SPLIT_PART(object_fqn, '.', 1) AS database_name,
    SPLIT_PART(object_fqn, '.', 2) AS schema_name,
    CASE
      WHEN UPPER(SPLIT_PART(object_fqn, '.', 2)) = 'RAW' THEN 'RAW'
      WHEN UPPER(SPLIT_PART(object_fqn, '.', 2)) = 'STAGING' THEN 'STAGING'
      WHEN UPPER(SPLIT_PART(object_fqn, '.', 2)) = 'REPORTING' THEN 'REPORTING'
      ELSE 'OTHER'
    END AS architecture_layer,
    ddl_object_type AS view_type,
    is_secure,
    column_name,
    effective_collation,
    tenant_expression_has_collate,
    tenant_expression_has_upper,
    tenant_expression_has_lower,
    CASE
      WHEN tenant_expression_has_collate THEN 'TENANT_COLLATE'
      WHEN tenant_expression_has_upper THEN 'TENANT_UPPER'
      WHEN tenant_expression_has_lower THEN 'TENANT_LOWER'
      ELSE 'NO_TENANT_CASE_OPERATION_DETECTED'
    END AS tenant_case_handling,
    inspection_status,
    error_message,
    inspected_at,
    definition_text
FROM V_LATEST_TENANT_ID_DEFINITION_INSPECTION
WHERE ddl_object_type IN ('VIEW', 'MATERIALIZED_VIEW');

-- Scans every view definition in scope, including views that reference a
-- tenant identifier only in a JOIN/WHERE clause and do not expose it.
CREATE OR REPLACE PROCEDURE SCAN_TENANT_ID_VIEW_DEFINITIONS(
    DATABASE_FILTER VARCHAR, SCHEMA_FILTERS ARRAY
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_run_id VARCHAR DEFAULT UUID_STRING();
    v_count NUMBER;
BEGIN
    INSERT INTO TENANT_ID_VIEW_DEFINITION_SCAN (
        scan_id, run_id, database_name, schema_name, view_name, object_fqn,
        is_secure, view_definition, definition_available,
        references_tenant_identifier, tenant_expression_has_collate,
        tenant_expression_has_upper, tenant_expression_has_lower,
        tenant_expression_has_ilike, scanned_at
    )
    SELECT
        UUID_STRING(), :v_run_id, v.table_catalog, v.table_schema, v.table_name,
        v.table_catalog || '.' || v.table_schema || '.' || v.table_name,
        IFF(UPPER(COALESCE(v.is_secure::VARCHAR, 'NO')) IN ('YES','TRUE'), TRUE, FALSE),
        v.view_definition,
        v.view_definition IS NOT NULL,
        REGEXP_LIKE(COALESCE(v.view_definition, ''), 'TENAN+T?[ _$-]*ID', 'i'),
        REGEXP_LIKE(COALESCE(v.view_definition, ''),
          'COLLATE\\s*\\([^)]*TENAN+T?[ _$-]*ID|TENAN+T?[ _$-]*ID[^,;)]*COLLATE', 'i'),
        REGEXP_LIKE(COALESCE(v.view_definition, ''),
          'UPPER\\s*\\([^)]*TENAN+T?[ _$-]*ID', 'i'),
        REGEXP_LIKE(COALESCE(v.view_definition, ''),
          'LOWER\\s*\\([^)]*TENAN+T?[ _$-]*ID', 'i'),
        REGEXP_LIKE(COALESCE(v.view_definition, ''),
          'ILIKE[^;]*TENAN+T?[ _$-]*ID|TENAN+T?[ _$-]*ID[^;]*ILIKE', 'i'),
        CURRENT_TIMESTAMP()
    FROM SNOWFLAKE.ACCOUNT_USAGE.VIEWS v
    WHERE v.deleted IS NULL
      AND (:DATABASE_FILTER IS NULL OR UPPER(v.table_catalog) = UPPER(:DATABASE_FILTER))
      AND (:SCHEMA_FILTERS IS NULL
           OR ARRAY_CONTAINS(v.table_schema::VARIANT, :SCHEMA_FILTERS)
           OR ARRAY_CONTAINS(UPPER(v.table_schema)::VARIANT, :SCHEMA_FILTERS))
      AND (
        REGEXP_LIKE(COALESCE(v.view_definition, ''), 'TENAN+T?[ _$-]*ID', 'i')
        OR EXISTS (
          SELECT 1
          FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
          WHERE c.deleted IS NULL
            AND c.table_catalog = v.table_catalog
            AND c.table_schema = v.table_schema
            AND c.table_name = v.table_name
            AND REGEXP_REPLACE(UPPER(c.column_name), '[^A-Z0-9]', '') IN ('TENANTID','TENANID')
        )
      );

    SELECT COUNT(*) INTO :v_count
    FROM TENANT_ID_VIEW_DEFINITION_SCAN WHERE run_id = :v_run_id;
    RETURN OBJECT_CONSTRUCT('run_id', v_run_id, 'views_scanned', v_count);
END;
$$;

CREATE OR REPLACE VIEW V_LATEST_TENANT_ID_VIEW_DEFINITION_SCAN AS
SELECT *
FROM TENANT_ID_VIEW_DEFINITION_SCAN
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY object_fqn ORDER BY scanned_at DESC
) = 1;

-- CALL INSPECT_TENANT_ID_DEFINITIONS(
--   'FV_PROD_US_SHARD_I', ARRAY_CONSTRUCT('RAW','STAGING','REPORTING','DATABRIDGE'),
--   'ALL', 5000);
-- CALL SCAN_TENANT_ID_VIEW_DEFINITIONS(
--   'FV_PROD_US_SHARD_I', ARRAY_CONSTRUCT('REPORTING','DATABRIDGE'));
