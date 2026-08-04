USE DATABASE DLA_SEMANTIC;
USE SCHEMA TENANT_ID_ADMIN;

CREATE OR REPLACE PROCEDURE VALIDATE_MIGRATION(MIGRATION_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_count NUMBER;
    v_fqn VARCHAR;
    v_db VARCHAR;
    v_schema VARCHAR;
    v_name VARCHAR;
    v_quoted_fqn VARCHAR;
    v_column_name VARCHAR;
    v_column_identifier VARCHAR;
    v_sql VARCHAR;
    v_collation VARCHAR;
    v_noncanonical NUMBER;
    v_collisions NUMBER;
    v_refresh_mode VARCHAR;
    v_scheduling_state VARCHAR;
    v_data_timestamp TIMESTAMP_LTZ;
    v_pass BOOLEAN;
    v_query_id VARCHAR;
BEGIN
    SELECT COUNT(*), MAX(m.object_fqn), MAX(d.database_name), MAX(d.schema_name),
           MAX(d.object_name), MAX(c.column_name)
      INTO :v_count, :v_fqn, :v_db, :v_schema, :v_name, :v_column_name
    FROM MIGRATION_MANIFEST m
    JOIN DYNAMIC_TABLE_CATALOG d ON d.object_fqn = m.object_fqn
    JOIN (
        SELECT *
        FROM TENANT_ID_COLUMN_CATALOG
        QUALIFY COUNT(*) OVER (PARTITION BY object_fqn) = 1
            AND ROW_NUMBER() OVER (
            PARTITION BY object_fqn
            ORDER BY IFF(column_name = 'TENANT_ID', 0, 1), ordinal_position
        ) = 1
    ) c ON c.object_fqn = m.object_fqn
    WHERE m.migration_id = :MIGRATION_ID
      AND m.status IN ('APPLIED', 'VALIDATION_FAILED');

    IF (v_count <> 1) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Migration must be APPLIED or VALIDATION_FAILED and present in the current catalog');
    END IF;

    v_quoted_fqn := '"' || REPLACE(v_db, '"', '""') || '"."' ||
                    REPLACE(v_schema, '"', '""') || '"."' ||
                    REPLACE(v_name, '"', '""') || '"';
    v_column_identifier := '"' || REPLACE(v_column_name, '"', '""') || '"';
    v_sql :=
        'WITH base AS (SELECT ' || v_column_identifier || '::VARCHAR tenant_id FROM ' ||
        v_quoted_fqn || '),' ||
        ' collisions AS (SELECT COUNT(*) n FROM (' ||
        '  SELECT UPPER(TRIM(tenant_id)) k FROM base WHERE tenant_id IS NOT NULL' ||
        '  GROUP BY k' ||
        '  HAVING COUNT(DISTINCT COLLATE(tenant_id, ''utf8'')) > 1))' ||
        ' SELECT (SELECT COALESCE(MAX(c), '''') FROM (' ||
        '   SELECT COLLATION(' || v_column_identifier || ') c FROM ' ||
        v_quoted_fqn || ' LIMIT 1)),' ||
        ' COUNT_IF(tenant_id IS NOT NULL AND' ||
        '   COLLATE(tenant_id, ''utf8'') <>' ||
        '   COLLATE(UPPER(TRIM(tenant_id)), ''utf8'')),' ||
        ' (SELECT n FROM collisions) FROM base';
    EXECUTE IMMEDIATE :v_sql;
    v_query_id := SQLID;
    SELECT $1::VARCHAR, $2::NUMBER, $3::NUMBER
      INTO :v_collation, :v_noncanonical, :v_collisions
    FROM TABLE(RESULT_SCAN(:v_query_id));

    SELECT configured_refresh_mode, scheduling_state, current_data_timestamp
      INTO :v_refresh_mode, :v_scheduling_state, :v_data_timestamp
    FROM DYNAMIC_TABLE_CATALOG
    WHERE object_fqn = :v_fqn;

    -- Require case-insensitive comparison semantics. Uppercase data alone is
    -- not sufficient. Collision counts remain security-review evidence.
    v_pass := REGEXP_LIKE(COALESCE(v_collation, ''),
                          '(^|-)(upper|lower|ci)(-|$)', 'i')
              AND COALESCE(v_scheduling_state, 'UNKNOWN') NOT ILIKE '%SUSPEND%'
              AND v_data_timestamp IS NOT NULL;

    UPDATE MIGRATION_MANIFEST
    SET status = IFF(:v_pass, 'VALIDATED', 'VALIDATION_FAILED'),
        validated_at = CURRENT_TIMESTAMP(),
        last_error = IFF(:v_pass, NULL,
            'Post-migration validation failed; inspect returned metrics')
    WHERE migration_id = :MIGRATION_ID;

    INSERT INTO MIGRATION_AUDIT
    VALUES (UUID_STRING(), :MIGRATION_ID, 'VALIDATE', IFF(:v_pass, 'SUCCEEDED', 'FAILED'),
            CURRENT_USER(), CURRENT_TIMESTAMP(), NULL,
            OBJECT_CONSTRUCT('collation', NULLIF(:v_collation, ''),
                             'noncanonical_rows', :v_noncanonical,
                             'collision_groups', :v_collisions,
                             'refresh_mode', :v_refresh_mode,
                             'scheduling_state', :v_scheduling_state,
                             'data_timestamp', :v_data_timestamp));

    RETURN OBJECT_CONSTRUCT('status', IFF(v_pass, 'VALIDATED', 'VALIDATION_FAILED'),
                            'migration_id', MIGRATION_ID,
                            'object_fqn', v_fqn,
                            'collation', NULLIF(v_collation, ''),
                            'noncanonical_rows', v_noncanonical,
                            'collision_groups', v_collisions,
                            'refresh_mode', v_refresh_mode,
                            'scheduling_state', v_scheduling_state,
                            'data_timestamp', v_data_timestamp);
EXCEPTION
    WHEN OTHER THEN
        UPDATE MIGRATION_MANIFEST
        SET status = 'VALIDATION_FAILED', validated_at = CURRENT_TIMESTAMP(),
            last_error = :SQLERRM
        WHERE migration_id = :MIGRATION_ID;
        INSERT INTO MIGRATION_AUDIT
        VALUES (UUID_STRING(), :MIGRATION_ID, 'VALIDATE', 'FAILED', CURRENT_USER(),
                CURRENT_TIMESTAMP(), NULL, OBJECT_CONSTRUCT('error', :SQLERRM));
        RAISE;
END;
$$;

CREATE OR REPLACE VIEW V_MIGRATION_READINESS AS
SELECT
    m.migration_id,
    m.object_fqn,
    m.status,
    m.strategy,
    m.risk_score,
    m.risk_reasons,
    m.upstream_count,
    m.downstream_count,
    m.security_review_required,
    r.configured_refresh_mode,
    r.observed_collation,
    r.definition_class,
    r.invalid_guid_rows,
    r.noncanonical_rows,
    r.collision_groups,
    r.policy_reference_count,
    r.row_access_policy_count,
    r.tenant_security_policy_count,
    r.full_refreshes_30d,
    r.reinitializations_30d,
    r.failed_refreshes_30d,
    m.change_reference,
    m.security_reviewed_by,
    m.security_reviewed_at,
    m.generated_at,
    m.applied_at,
    m.validated_at,
    m.last_error
FROM MIGRATION_MANIFEST m
LEFT JOIN V_TENANT_ID_RISK r USING (object_fqn);

CREATE OR REPLACE VIEW V_MIGRATION_SUMMARY AS
SELECT
    status,
    COUNT(*) AS object_count,
    MIN(risk_score) AS minimum_risk_score,
    ROUND(AVG(risk_score), 2) AS average_risk_score,
    MAX(risk_score) AS maximum_risk_score,
    SUM(downstream_count) AS downstream_relationships
FROM MIGRATION_MANIFEST
GROUP BY status;

CREATE OR REPLACE VIEW V_TENANT_ID_DIRECT_DEPENDENCIES AS
SELECT DISTINCT
    d.upstream_fqn,
    d.upstream_domain,
    d.downstream_fqn,
    d.downstream_domain,
    d.dependency_type,
    IFF(u.object_fqn IS NOT NULL, TRUE, FALSE) AS upstream_has_tenant_id,
    IFF(v.object_fqn IS NOT NULL, TRUE, FALSE) AS downstream_has_tenant_id,
    d.discovered_at
FROM DEPENDENCY_CATALOG d
LEFT JOIN TENANT_ID_COLUMN_CATALOG u ON u.object_fqn = d.upstream_fqn
LEFT JOIN TENANT_ID_COLUMN_CATALOG v ON v.object_fqn = d.downstream_fqn
WHERE u.object_fqn IS NOT NULL OR v.object_fqn IS NOT NULL;

-- End-to-end downstream impact paths. Keeping all dependency edges during
-- discovery is what allows BASE TABLE -> VIEW -> VIEW -> DYNAMIC TABLE paths.
CREATE OR REPLACE VIEW V_TENANT_ID_DOWNSTREAM_PATHS AS
WITH RECURSIVE paths (
    root_fqn, current_fqn, current_domain, dependency_depth, dependency_path
) AS (
    SELECT DISTINCT
        c.object_fqn,
        d.downstream_fqn,
        d.downstream_domain,
        1,
        c.object_fqn || ' -> ' || d.downstream_fqn
    FROM TENANT_ID_COLUMN_CATALOG c
    JOIN DEPENDENCY_CATALOG d ON d.upstream_fqn = c.object_fqn

    UNION ALL

    SELECT
        p.root_fqn,
        d.downstream_fqn,
        d.downstream_domain,
        p.dependency_depth + 1,
        p.dependency_path || ' -> ' || d.downstream_fqn
    FROM paths p
    JOIN DEPENDENCY_CATALOG d ON d.upstream_fqn = p.current_fqn
    WHERE p.dependency_depth < 50
      AND POSITION(' -> ' || d.downstream_fqn || ' -> '
                   IN ' -> ' || p.dependency_path || ' -> ') = 0
)
SELECT * FROM paths;
