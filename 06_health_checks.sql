USE DATABASE DLA_SEMANTIC;
USE SCHEMA TENANT_ID_ADMIN;

-- This view should return zero rows. It checks control-plane invariants without
-- reading or changing application data.
CREATE OR REPLACE VIEW V_TOOLKIT_INVARIANT_VIOLATIONS AS
SELECT
    'DUPLICATE_DYNAMIC_TABLE_CATALOG_KEY' AS violation_type,
    object_fqn AS subject,
    COUNT(*)::VARCHAR AS details
FROM DYNAMIC_TABLE_CATALOG
GROUP BY object_fqn
HAVING COUNT(*) > 1

UNION ALL

SELECT
    'DUPLICATE_ACTIVE_MANIFEST',
    object_fqn || '|' || strategy,
    COUNT(*)::VARCHAR
FROM MIGRATION_MANIFEST
WHERE status NOT IN ('FAILED', 'ROLLED_BACK')
GROUP BY object_fqn, strategy
HAVING COUNT(*) > 1

UNION ALL

SELECT
    'APPROVED_WITHOUT_REQUIRED_REVIEW',
    migration_id,
    'forward=' || IFF(proposed_ddl IS NULL, 'missing', 'present') ||
    ', rollback=' || IFF(rollback_ddl IS NULL, 'missing', 'present') ||
    ', security=' || IFF(security_reviewed_at IS NULL, 'missing', 'present')
FROM MIGRATION_MANIFEST
WHERE status = 'APPROVED'
  AND (proposed_ddl IS NULL OR rollback_ddl IS NULL OR security_reviewed_at IS NULL)

UNION ALL

SELECT
    'APPLIED_WITHOUT_DDL_SNAPSHOT',
    migration_id,
    status
FROM MIGRATION_MANIFEST
WHERE status IN ('APPLIED', 'VALIDATED', 'VALIDATION_FAILED', 'ROLLBACK_APPROVED')
  AND applied_ddl IS NULL

UNION ALL

SELECT
    'INDETERMINATE_MIGRATION_STATE',
    migration_id,
    status || COALESCE(': ' || last_error, '')
FROM MIGRATION_MANIFEST
WHERE status IN ('APPLYING', 'APPLIED_UNVERIFIED', 'ROLLING_BACK', 'ROLLED_BACK_UNVERIFIED')

UNION ALL

SELECT
    'STALE_RUNNING_RUN',
    run_id,
    run_type || ' started ' || started_at::VARCHAR
FROM RUN_LOG
WHERE status = 'RUNNING'
  AND started_at < DATEADD('hour', -6, CURRENT_TIMESTAMP())

UNION ALL

SELECT
    'AMBIGUOUS_TENANT_ID_COLUMNS',
    object_fqn,
    ARRAY_TO_STRING(candidate_columns, ', ')
FROM V_TENANT_ID_COLUMN_AMBIGUITY;

SELECT *
FROM V_TOOLKIT_INVARIANT_VIOLATIONS
ORDER BY violation_type, subject;
