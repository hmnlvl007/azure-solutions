USE DATABASE DLA_SEMANTIC;
USE SCHEMA TENANT_ID_ADMIN;

-- Dynamic Tables are the roots. Native COLUMN lineage preserves mappings such
-- as RAW.ORG.ID -> STAGING.ORG.TENANTID -> REPORTING.V.TENANT_ID.
CREATE OR REPLACE PROCEDURE COLLECT_DYNAMIC_TABLE_TENANT_LINEAGE(
    DATABASE_FILTER VARCHAR,
    SCHEMA_FILTERS ARRAY,
    LINEAGE_DISTANCE NUMBER,
    MAX_ROOT_COLUMNS NUMBER
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_run_id VARCHAR DEFAULT UUID_STRING();
    v_distance NUMBER DEFAULT COALESCE(LINEAGE_DISTANCE, 5);
    v_limit NUMBER DEFAULT COALESCE(MAX_ROOT_COLUMNS, 1000);
    v_processed NUMBER DEFAULT 0;
    v_succeeded NUMBER DEFAULT 0;
    v_failed NUMBER DEFAULT 0;
    v_column_fqn VARCHAR;
    v_sql VARCHAR;
    v_query_id VARCHAR;
    root_cursor CURSOR FOR
        SELECT n.database_name, n.schema_name, n.object_name, n.object_fqn,
               n.column_name
        FROM TENANT_ID_NAME_CATALOG n
        JOIN DYNAMIC_TABLE_CATALOG d USING (object_fqn)
        WHERE n.match_class = 'APPROVED_VARIANT'
        ORDER BY n.database_name, n.schema_name, n.object_name, n.ordinal_position;
BEGIN
    IF (v_distance < 1 OR v_distance > 5) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'LINEAGE_DISTANCE must be between 1 and 5');
    END IF;
    IF (v_limit < 1 OR v_limit > 10000) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'MAX_ROOT_COLUMNS must be between 1 and 10000');
    END IF;

    INSERT INTO RUN_LOG (
        run_id, run_type, started_at, completed_at, status, initiated_by, details
    ) VALUES (
        :v_run_id, 'COLUMN_LINEAGE', CURRENT_TIMESTAMP(), NULL,
        'RUNNING', CURRENT_USER(), NULL
    );

    FOR rec IN root_cursor DO
        IF (DATABASE_FILTER IS NOT NULL
            AND UPPER(rec.database_name) <> UPPER(DATABASE_FILTER)) THEN CONTINUE; END IF;
        IF (SCHEMA_FILTERS IS NOT NULL
            AND NOT ARRAY_CONTAINS(rec.schema_name::VARIANT, SCHEMA_FILTERS)
            AND NOT ARRAY_CONTAINS(UPPER(rec.schema_name)::VARIANT, SCHEMA_FILTERS)) THEN
            CONTINUE;
        END IF;
        IF (v_processed >= v_limit) THEN BREAK; END IF;
        v_processed := v_processed + 1;

        v_column_fqn := '"' || REPLACE(rec.database_name, '"', '""') || '"."' ||
                        REPLACE(rec.schema_name, '"', '""') || '"."' ||
                        REPLACE(rec.object_name, '"', '""') || '"."' ||
                        REPLACE(rec.column_name, '"', '""') || '"';

        FOR direction_rec IN (
            SELECT column1::VARCHAR AS direction FROM VALUES ('UPSTREAM'), ('DOWNSTREAM')
        ) DO
            BEGIN
                v_sql := 'SELECT * FROM TABLE(SNOWFLAKE.CORE.GET_LINEAGE(''' ||
                         REPLACE(v_column_fqn, '''', '''''') ||
                         ''', ''COLUMN'', ''' || direction_rec.direction || ''', ' ||
                         v_distance::VARCHAR || '))';
                EXECUTE IMMEDIATE :v_sql;
                v_query_id := SQLID;

                INSERT INTO TENANT_ID_COLUMN_LINEAGE (
                    lineage_id, run_id, root_dynamic_table_fqn, root_column_name,
                    direction, source_object_database, source_object_schema,
                    source_object_name, source_object_domain, source_column_name,
                    source_status, target_object_database, target_object_schema,
                    target_object_name, target_object_domain, target_column_name,
                    target_status, distance, process, collected_at
                )
                SELECT
                    UUID_STRING(), :v_run_id, rec.object_fqn, rec.column_name,
                    direction_rec.direction,
                    $1::VARCHAR, $2::VARCHAR, $3::VARCHAR, $4::VARCHAR,
                    $6::VARCHAR, $7::VARCHAR,
                    $8::VARCHAR, $9::VARCHAR, $10::VARCHAR, $11::VARCHAR,
                    $13::VARCHAR, $14::VARCHAR, $15::NUMBER, $16::VARIANT,
                    CURRENT_TIMESTAMP()
                FROM TABLE(RESULT_SCAN(:v_query_id));
                v_succeeded := v_succeeded + 1;
            EXCEPTION
                WHEN OTHER THEN
                    INSERT INTO TENANT_ID_COLUMN_LINEAGE_ERRORS (
                        error_id, run_id, root_dynamic_table_fqn, root_column_name,
                        direction, error_message, occurred_at
                    ) VALUES (
                        UUID_STRING(), :v_run_id, rec.object_fqn, rec.column_name,
                        direction_rec.direction, :SQLERRM, CURRENT_TIMESTAMP()
                    );
                    v_failed := v_failed + 1;
            END;
        END FOR;
    END FOR;

    UPDATE RUN_LOG
    SET completed_at = CURRENT_TIMESTAMP(),
        status = IFF(:v_failed = 0, 'SUCCEEDED', 'SUCCEEDED_WITH_ERRORS'),
        details = OBJECT_CONSTRUCT('root_columns', :v_processed,
                                   'successful_directions', :v_succeeded,
                                   'failed_directions', :v_failed,
                                   'distance', :v_distance)
    WHERE run_id = :v_run_id;

    RETURN OBJECT_CONSTRUCT('run_id', v_run_id,
        'status', IFF(v_failed = 0, 'SUCCEEDED', 'SUCCEEDED_WITH_ERRORS'),
        'root_columns', v_processed, 'successful_directions', v_succeeded,
        'failed_directions', v_failed, 'distance', v_distance);
EXCEPTION
    WHEN OTHER THEN
        UPDATE RUN_LOG
        SET completed_at = CURRENT_TIMESTAMP(), status = 'FAILED',
            details = OBJECT_CONSTRUCT('error', :SQLERRM,
                                       'root_columns', :v_processed,
                                       'successful_directions', :v_succeeded,
                                       'failed_directions', :v_failed)
        WHERE run_id = :v_run_id;
        RAISE;
END;
$$;

CREATE OR REPLACE VIEW V_DYNAMIC_TABLE_TENANT_COLUMN_LINEAGE AS
SELECT
    l.run_id,
    l.root_dynamic_table_fqn,
    l.root_column_name,
    l.direction,
    l.distance,
    l.source_object_database || '.' || l.source_object_schema || '.' ||
      l.source_object_name AS source_object_fqn,
    l.source_column_name,
    st.table_type AS source_object_type,
    st.is_dynamic AS source_is_dynamic,
    l.target_object_database || '.' || l.target_object_schema || '.' ||
      l.target_object_name AS target_object_fqn,
    l.target_column_name,
    tt.table_type AS target_object_type,
    tt.is_dynamic AS target_is_dynamic,
    IFF(UPPER(COALESCE(l.source_column_name, '')) <>
        UPPER(COALESCE(l.target_column_name, '')), TRUE, FALSE) AS column_renamed,
    l.source_status,
    l.target_status,
    l.process,
    l.collected_at
FROM TENANT_ID_COLUMN_LINEAGE l
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TABLES st
  ON st.table_catalog = l.source_object_database
 AND st.table_schema = l.source_object_schema
 AND st.table_name = l.source_object_name
 AND st.deleted IS NULL
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TABLES tt
  ON tt.table_catalog = l.target_object_database
 AND tt.table_schema = l.target_object_schema
 AND tt.table_name = l.target_object_name
 AND tt.deleted IS NULL;

-- CALL COLLECT_DYNAMIC_TABLE_TENANT_LINEAGE(
--   'FV_PROD_US_SHARD_I', ARRAY_CONSTRUCT('STAGING'), 5, 5000);
