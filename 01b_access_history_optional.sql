-- OPTIONAL: requires Enterprise Edition or higher and access to
-- SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY.
USE DATABASE DLA_SEMANTIC;
USE SCHEMA TENANT_ID_ADMIN;

CREATE OR REPLACE PROCEDURE REFRESH_OBSERVED_TENANT_ID_ACCESS()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_observed_count NUMBER;
BEGIN
    CREATE OR REPLACE TEMP TABLE TMP_OBSERVED_TENANT_ID_ACCESS AS
    WITH accessed_columns AS (
        SELECT
            obj.value:objectName::VARCHAR AS object_fqn,
            obj.value:objectDomain::VARCHAR AS object_domain,
            'DIRECT_OBJECT' AS lineage_level,
            ah.query_id,
            ah.user_name,
            ah.query_start_time,
            col.value:columnName::VARCHAR AS column_name
        FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
             LATERAL FLATTEN(INPUT => ah.direct_objects_accessed) obj,
             LATERAL FLATTEN(INPUT => obj.value:columns, OUTER => TRUE) col
        WHERE ah.query_start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())

        UNION ALL

        SELECT
            obj.value:objectName::VARCHAR,
            obj.value:objectDomain::VARCHAR,
            'BASE_OBJECT',
            ah.query_id,
            ah.user_name,
            ah.query_start_time,
            col.value:columnName::VARCHAR
        FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
             LATERAL FLATTEN(INPUT => ah.base_objects_accessed) obj,
             LATERAL FLATTEN(INPUT => obj.value:columns, OUTER => TRUE) col
        WHERE ah.query_start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    )
    SELECT
        object_fqn,
        object_domain,
        lineage_level,
        COUNT(DISTINCT query_id) AS query_count,
        COUNT(DISTINCT user_name) AS distinct_users,
        MIN(query_start_time) AS first_accessed_at,
        MAX(query_start_time) AS last_accessed_at,
        CURRENT_TIMESTAMP() AS refreshed_at
    FROM accessed_columns
    WHERE UPPER(column_name) = 'TENANT_ID'
    GROUP BY object_fqn, object_domain, lineage_level;

    BEGIN TRANSACTION;
    DELETE FROM OBSERVED_TENANT_ID_ACCESS_30D;
    INSERT INTO OBSERVED_TENANT_ID_ACCESS_30D (
        object_fqn, object_domain, lineage_level, query_count, distinct_users,
        first_accessed_at, last_accessed_at, refreshed_at
    )
    SELECT object_fqn, object_domain, lineage_level, query_count,
           distinct_users, first_accessed_at, last_accessed_at, refreshed_at
    FROM TMP_OBSERVED_TENANT_ID_ACCESS;
    COMMIT;

    SELECT COUNT(*) INTO :v_observed_count
    FROM OBSERVED_TENANT_ID_ACCESS_30D;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCEEDED',
        'observed_objects', v_observed_count,
        'refreshed_at', CURRENT_TIMESTAMP()
    );
END;
$$;

-- Explicit execution step:
-- CALL REFRESH_OBSERVED_TENANT_ID_ACCESS();
