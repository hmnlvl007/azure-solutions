USE DATABASE DLA_SEMANTIC;
USE SCHEMA TENANT_ID_ADMIN;

CREATE OR REPLACE PROCEDURE ANALYZE_TENANT_ID(
    ANALYSIS_MODE VARCHAR,
    DATABASE_FILTER VARCHAR,
    SCHEMA_FILTER VARCHAR,
    MAX_OBJECTS NUMBER
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_run_id VARCHAR DEFAULT UUID_STRING();
    v_mode VARCHAR DEFAULT UPPER(ANALYSIS_MODE);
    v_limit NUMBER DEFAULT COALESCE(MAX_OBJECTS, 10000);
    v_processed NUMBER DEFAULT 0;
    v_succeeded NUMBER DEFAULT 0;
    v_failed NUMBER DEFAULT 0;
    v_fqn VARCHAR;
    v_column_identifier VARCHAR;
    v_sql VARCHAR;
    v_collation VARCHAR;
    v_total NUMBER;
    v_nulls NUMBER;
    v_invalid NUMBER;
    v_noncanonical NUMBER;
    v_collisions NUMBER;
    v_definition_class VARCHAR;
    v_query_id VARCHAR;
    candidate_cursor CURSOR FOR
        SELECT c.object_fqn, c.database_name, c.schema_name, c.object_name,
               c.column_name,
               d.definition_text
        FROM (
            SELECT *, COUNT(*) OVER (PARTITION BY object_fqn) AS candidate_column_count
            FROM TENANT_ID_COLUMN_CATALOG
            QUALIFY candidate_column_count = 1
                AND ROW_NUMBER() OVER (
                PARTITION BY object_fqn
                ORDER BY IFF(column_name = 'TENANT_ID', 0, 1), ordinal_position
            ) = 1
        ) c
        JOIN DYNAMIC_TABLE_CATALOG d USING (object_fqn)
        ORDER BY c.database_name, c.schema_name, c.object_name;
BEGIN
    IF (v_mode NOT IN ('QUICK', 'FULL')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'ANALYSIS_MODE must be QUICK or FULL');
    END IF;
    IF (v_limit < 1 OR v_limit > 10000) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'MAX_OBJECTS must be between 1 and 10000');
    END IF;

    INSERT INTO RUN_LOG (
        run_id, run_type, started_at, completed_at, status, initiated_by, details
    ) VALUES (
        :v_run_id, 'ANALYSIS_' || :v_mode, CURRENT_TIMESTAMP(), NULL,
        'RUNNING', CURRENT_USER(), NULL
    );

    FOR rec IN candidate_cursor DO
        IF (DATABASE_FILTER IS NOT NULL AND rec.database_name <> DATABASE_FILTER) THEN
            CONTINUE;
        END IF;
        IF (SCHEMA_FILTER IS NOT NULL AND rec.schema_name <> SCHEMA_FILTER) THEN
            CONTINUE;
        END IF;
        IF (v_processed >= v_limit) THEN
            BREAK;
        END IF;
        v_processed := v_processed + 1;
        v_fqn := '"' || REPLACE(rec.database_name, '"', '""') || '"."' ||
                 REPLACE(rec.schema_name, '"', '""') || '"."' ||
                 REPLACE(rec.object_name, '"', '""') || '"';
        v_column_identifier := '"' || REPLACE(rec.column_name, '"', '""') || '"';

        v_definition_class := CASE
            WHEN REGEXP_LIKE(rec.definition_text, 'UPPER\\s*\\(\\s*(TRIM\\s*\\()?[^)]*TENANT_ID', 'i')
                THEN 'NORMALIZED_ONLY'
            WHEN REGEXP_LIKE(rec.definition_text, 'COLLATE\\s+''upper''[^,]*AS\\s+TENANT_ID|TENANT_ID[^,]*COLLATE\\s+''upper''', 'i')
                THEN 'ALREADY_UPPER_COLLATION'
            WHEN REGEXP_LIKE(rec.definition_text, 'COLLATE\\s+''[^'']*ci[^'']*''[^,]*AS\\s+TENANT_ID|TENANT_ID[^,]*COLLATE\\s+''[^'']*ci[^'']*''', 'i')
                THEN 'CI_COLLATION'
            WHEN REGEXP_LIKE(rec.definition_text, 'SELECT\\s+[^;]*\\*', 'i')
                THEN 'SELECT_STAR_REVIEW'
            ELSE 'UNPROTECTED_OR_COMPLEX'
        END;

        BEGIN
            IF (v_mode = 'QUICK') THEN
                v_sql := 'SELECT COALESCE(MAX(c), '''') FROM (' ||
                         'SELECT COLLATION(' || v_column_identifier || ') c FROM ' ||
                         v_fqn || ' LIMIT 1)';
                EXECUTE IMMEDIATE :v_sql;
                v_query_id := SQLID;
                SELECT $1::VARCHAR INTO :v_collation
                FROM TABLE(RESULT_SCAN(:v_query_id));
                v_total := NULL;
                v_nulls := NULL;
                v_invalid := NULL;
                v_noncanonical := NULL;
                v_collisions := NULL;
            ELSE
                v_sql :=
                    'WITH base AS (' ||
                    ' SELECT ' || v_column_identifier || '::VARCHAR AS tenant_id FROM ' || v_fqn ||
                    '), stats AS (' ||
                    ' SELECT COUNT(*) total_rows,' ||
                    ' COUNT_IF(tenant_id IS NULL) null_rows,' ||
                    ' COUNT_IF(tenant_id IS NOT NULL AND NOT REGEXP_LIKE(TRIM(tenant_id),' ||
                    ' ''^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'')) invalid_rows,' ||
                    ' COUNT_IF(tenant_id IS NOT NULL AND' ||
                    '   COLLATE(tenant_id, ''utf8'') <>' ||
                    '   COLLATE(UPPER(TRIM(tenant_id)), ''utf8'')) noncanonical_rows' ||
                    ' FROM base), collisions AS (' ||
                    ' SELECT COUNT(*) collision_groups FROM (' ||
                    '  SELECT UPPER(TRIM(tenant_id)) canonical_id' ||
                    '  FROM base WHERE tenant_id IS NOT NULL' ||
                    '  GROUP BY canonical_id' ||
                    '  HAVING COUNT(DISTINCT COLLATE(tenant_id, ''utf8'')) > 1' ||
                    ' ))' ||
                    ' SELECT (SELECT COALESCE(MAX(c), '''') FROM (' ||
                    '   SELECT COLLATION(' || v_column_identifier || ') c FROM ' ||
                    v_fqn || ' LIMIT 1)),' ||
                    ' total_rows, null_rows, invalid_rows, noncanonical_rows, collision_groups' ||
                    ' FROM stats CROSS JOIN collisions';
                EXECUTE IMMEDIATE :v_sql;
                v_query_id := SQLID;
                SELECT $1::VARCHAR, $2::NUMBER, $3::NUMBER, $4::NUMBER, $5::NUMBER, $6::NUMBER
                  INTO :v_collation, :v_total, :v_nulls, :v_invalid, :v_noncanonical, :v_collisions
                FROM TABLE(RESULT_SCAN(:v_query_id));
            END IF;

            INSERT INTO TENANT_ID_ANALYSIS (
                analysis_id, run_id, object_fqn, analysis_mode,
                observed_collation, definition_class, total_rows, null_rows,
                invalid_guid_rows, noncanonical_rows, collision_groups,
                analysis_status, error_message, analyzed_at
            ) VALUES (
                UUID_STRING(), :v_run_id, rec.object_fqn, :v_mode, NULLIF(:v_collation, ''),
                :v_definition_class, :v_total, :v_nulls, :v_invalid,
                :v_noncanonical, :v_collisions, 'SUCCEEDED', NULL, CURRENT_TIMESTAMP()
            );
            v_succeeded := v_succeeded + 1;
        EXCEPTION
            WHEN OTHER THEN
                INSERT INTO TENANT_ID_ANALYSIS (
                    analysis_id, run_id, object_fqn, analysis_mode,
                    observed_collation, definition_class, total_rows, null_rows,
                    invalid_guid_rows, noncanonical_rows, collision_groups,
                    analysis_status, error_message, analyzed_at
                ) VALUES (
                    UUID_STRING(), :v_run_id, rec.object_fqn, :v_mode, NULL,
                    :v_definition_class, NULL, NULL, NULL, NULL, NULL,
                    'FAILED', :SQLERRM, CURRENT_TIMESTAMP()
                );
                v_failed := v_failed + 1;
        END;
    END FOR;

    UPDATE RUN_LOG
    SET completed_at = CURRENT_TIMESTAMP(),
        status = IFF(:v_failed = 0, 'SUCCEEDED', 'SUCCEEDED_WITH_ERRORS'),
        details = OBJECT_CONSTRUCT('processed', :v_processed,
                                   'succeeded', :v_succeeded,
                                   'failed', :v_failed)
    WHERE run_id = :v_run_id;

    RETURN OBJECT_CONSTRUCT('run_id', v_run_id, 'mode', v_mode,
                            'status', IFF(v_failed = 0, 'SUCCEEDED', 'SUCCEEDED_WITH_ERRORS'),
                            'processed', v_processed,
                            'succeeded', v_succeeded, 'failed', v_failed);
EXCEPTION
    WHEN OTHER THEN
        UPDATE RUN_LOG
        SET completed_at = CURRENT_TIMESTAMP(), status = 'FAILED',
            details = OBJECT_CONSTRUCT('error', :SQLERRM,
                                       'processed', :v_processed,
                                       'succeeded', :v_succeeded,
                                       'failed', :v_failed)
        WHERE run_id = :v_run_id;
        RAISE;
END;
$$;

-- Explicit execution step. Start with a small scope before increasing the cap:
-- CALL ANALYZE_TENANT_ID('QUICK', 'DLA_SEMANTIC', NULL, 100);
-- FULL mode is deliberately never called automatically.
