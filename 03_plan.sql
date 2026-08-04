USE DATABASE DLA_SEMANTIC;
USE SCHEMA TENANT_ID_ADMIN;

-- Latest analysis result for each object.
CREATE OR REPLACE VIEW V_LATEST_TENANT_ID_ANALYSIS AS
SELECT *
FROM TENANT_ID_ANALYSIS
QUALIFY ROW_NUMBER() OVER (PARTITION BY object_fqn ORDER BY analyzed_at DESC) = 1;

CREATE OR REPLACE VIEW V_TENANT_ID_RISK AS
WITH RECURSIVE candidate_columns AS (
    SELECT *, COUNT(*) OVER (PARTITION BY object_fqn) AS candidate_column_count
    FROM TENANT_ID_COLUMN_CATALOG
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY object_fqn
        ORDER BY IFF(column_name = 'TENANT_ID', 0, 1), ordinal_position
    ) = 1
), candidate_objects AS (
    SELECT c.object_fqn
    FROM candidate_columns c
    JOIN DYNAMIC_TABLE_CATALOG d USING (object_fqn)
), downstream_paths (root_fqn, current_fqn, visited_path, dependency_depth) AS (
    SELECT c.object_fqn, d.downstream_fqn,
           '|' || c.object_fqn || '|' || d.downstream_fqn || '|', 1
    FROM candidate_objects c
    JOIN DEPENDENCY_CATALOG d ON d.upstream_fqn = c.object_fqn
    UNION ALL
    SELECT p.root_fqn, d.downstream_fqn,
           p.visited_path || d.downstream_fqn || '|', p.dependency_depth + 1
    FROM downstream_paths p
    JOIN DEPENDENCY_CATALOG d ON d.upstream_fqn = p.current_fqn
    WHERE p.dependency_depth < 50
      AND POSITION('|' || d.downstream_fqn || '|' IN p.visited_path) = 0
), upstream_paths (root_fqn, current_fqn, visited_path, dependency_depth) AS (
    SELECT c.object_fqn, d.upstream_fqn,
           '|' || c.object_fqn || '|' || d.upstream_fqn || '|', 1
    FROM candidate_objects c
    JOIN DEPENDENCY_CATALOG d ON d.downstream_fqn = c.object_fqn
    UNION ALL
    SELECT p.root_fqn, d.upstream_fqn,
           p.visited_path || d.upstream_fqn || '|', p.dependency_depth + 1
    FROM upstream_paths p
    JOIN DEPENDENCY_CATALOG d ON d.downstream_fqn = p.current_fqn
    WHERE p.dependency_depth < 50
      AND POSITION('|' || d.upstream_fqn || '|' IN p.visited_path) = 0
), dependency_counts AS (
    SELECT c.object_fqn,
           (SELECT COUNT(DISTINCT u.current_fqn)
              FROM upstream_paths u WHERE u.root_fqn = c.object_fqn) AS upstream_count,
           (SELECT COUNT(DISTINCT d.current_fqn)
              FROM downstream_paths d WHERE d.root_fqn = c.object_fqn) AS downstream_count
    FROM candidate_objects c
), policy_counts AS (
    SELECT object_fqn,
           COUNT(*) AS policy_reference_count,
           COUNT_IF(policy_kind = 'ROW_ACCESS_POLICY') AS row_access_policy_count,
           COUNT_IF(REGEXP_REPLACE(UPPER(COALESCE(column_name, '')),
                                   '[^A-Z0-9]', '') = 'TENANTID'
                    OR UPPER(COALESCE(policy_kind, '')) = 'ROW_ACCESS_POLICY')
             AS tenant_security_policy_count
    FROM POLICY_REFERENCE_CATALOG
    GROUP BY object_fqn
)
SELECT
    c.object_fqn,
    c.database_name,
    c.schema_name,
    c.object_name,
    c.column_name AS tenant_id_column_name,
    c.candidate_column_count,
    d.configured_refresh_mode,
    d.refresh_mode_reason,
    a.analysis_mode,
    a.observed_collation,
    a.definition_class,
    a.invalid_guid_rows,
    a.noncanonical_rows,
    a.collision_groups,
    COALESCE(x.upstream_count, 0) AS upstream_count,
    COALESCE(x.downstream_count, 0) AS downstream_count,
    COALESCE(p.policy_reference_count, 0) AS policy_reference_count,
    COALESCE(p.row_access_policy_count, 0) AS row_access_policy_count,
    COALESCE(p.tenant_security_policy_count, 0) AS tenant_security_policy_count,
    COALESCE(h.full_refreshes, 0) AS full_refreshes_30d,
    COALESCE(h.reinitializations, 0) AS reinitializations_30d,
    COALESCE(h.failed_refreshes, 0) AS failed_refreshes_30d,
    10
      + IFF(COALESCE(a.analysis_status, 'MISSING') <> 'SUCCEEDED', 100, 0)
      + IFF(c.candidate_column_count > 1, 100, 0)
      + IFF(COALESCE(a.collision_groups, 0) > 0, 30, 0)
      + IFF(COALESCE(a.collision_groups, 0) > 0
            AND COALESCE(p.tenant_security_policy_count, 0) > 0, 100, 0)
      + IFF(COALESCE(a.invalid_guid_rows, 0) > 0, 30, 0)
      + IFF(a.definition_class IN ('SELECT_STAR_REVIEW', 'UNPROTECTED_OR_COMPLEX'), 20, 0)
      + LEAST(COALESCE(x.downstream_count, 0), 30)
      + IFF(COALESCE(p.tenant_security_policy_count, 0) > 0, 50, 0)
      + IFF(COALESCE(h.reinitializations, 0) > 0, 10, 0) AS risk_score,
    ARRAY_CONSTRUCT_COMPACT(
      IFF(COALESCE(a.analysis_status, 'MISSING') <> 'SUCCEEDED', 'ANALYSIS_MISSING_OR_FAILED', NULL),
      IFF(c.candidate_column_count > 1, 'AMBIGUOUS_TENANT_ID_COLUMNS', NULL),
      IFF(COALESCE(a.collision_groups, 0) > 0, 'MIXED_CASE_VARIANT_GROUPS', NULL),
      IFF(COALESCE(a.collision_groups, 0) > 0
          AND COALESCE(p.tenant_security_policy_count, 0) > 0,
          'SECURITY_SENSITIVE_VARIANTS', NULL),
      IFF(COALESCE(a.invalid_guid_rows, 0) > 0, 'INVALID_GUIDS', NULL),
      IFF(a.definition_class = 'SELECT_STAR_REVIEW', 'SELECT_STAR', NULL),
      IFF(a.definition_class = 'UNPROTECTED_OR_COMPLEX', 'COMPLEX_DEFINITION', NULL),
      IFF(COALESCE(x.downstream_count, 0) > 20, 'HIGH_DOWNSTREAM_FANOUT', NULL),
      IFF(COALESCE(p.tenant_security_policy_count, 0) > 0, 'SECURITY_POLICY_REVIEW_REQUIRED', NULL),
      IFF(COALESCE(h.reinitializations, 0) > 0, 'RECENT_REINITIALIZATION', NULL)
    ) AS risk_reasons,
    CASE
      WHEN c.candidate_column_count > 1 THEN 'BLOCKED_AMBIGUOUS_COLUMNS'
      WHEN COALESCE(a.analysis_status, 'MISSING') <> 'SUCCEEDED' THEN 'BLOCKED_ANALYSIS'
      WHEN COALESCE(a.collision_groups, 0) > 0
       AND COALESCE(p.tenant_security_policy_count, 0) > 0
        THEN 'BLOCKED_SECURITY_REVIEW'
      WHEN COALESCE(a.invalid_guid_rows, 0) > 0 THEN 'BLOCKED_INVALID_GUIDS'
      WHEN REGEXP_LIKE(COALESCE(a.observed_collation, ''),
                       '(^|-)(upper|lower|ci)(-|$)', 'i')
        THEN 'NO_CHANGE_CASE_INSENSITIVE_COLLATION'
      WHEN a.definition_class = 'SELECT_STAR_REVIEW' THEN 'MANUAL_REVIEW'
      ELSE 'CANDIDATE_ADD_CASE_INSENSITIVE_COLLATION'
    END AS recommendation
FROM candidate_columns c
JOIN DYNAMIC_TABLE_CATALOG d USING (object_fqn)
LEFT JOIN V_LATEST_TENANT_ID_ANALYSIS a USING (object_fqn)
LEFT JOIN dependency_counts x USING (object_fqn)
LEFT JOIN policy_counts p USING (object_fqn)
LEFT JOIN REFRESH_HEALTH_30D h USING (object_fqn);

-- Idempotently create one planning row per object and strategy. The proposed
-- DDL remains NULL until a human or SQL-aware deployment tool reviews GET_DDL.
MERGE INTO MIGRATION_MANIFEST target
USING (
    SELECT
        UUID_STRING() AS migration_id,
        r.object_fqn,
        'CASE_INSENSITIVE_UPPER_COLLATION' AS strategy,
        r.risk_score,
        r.risk_reasons,
        r.upstream_count,
        r.downstream_count,
        TRUE AS security_review_required,
        CASE
          WHEN r.recommendation LIKE 'BLOCKED_%' THEN r.recommendation
          WHEN r.recommendation LIKE 'NO_CHANGE_%' THEN r.recommendation
          WHEN r.recommendation = 'MANUAL_REVIEW' THEN 'MANUAL_REVIEW'
          ELSE 'PLANNED'
        END AS status
    FROM V_TENANT_ID_RISK r
) source
ON target.object_fqn = source.object_fqn
AND target.strategy = source.strategy
AND target.status NOT IN ('ROLLED_BACK', 'FAILED')
WHEN MATCHED THEN UPDATE SET
    risk_score = source.risk_score,
    risk_reasons = source.risk_reasons,
    upstream_count = source.upstream_count,
    downstream_count = source.downstream_count,
    status = CASE
      WHEN source.status LIKE 'BLOCKED_%'
       AND target.status IN ('PLANNED', 'MANUAL_REVIEW', 'DDL_REVIEWED', 'APPROVED')
        THEN source.status
      WHEN target.status IN (
          'PLANNED', 'MANUAL_REVIEW', 'BLOCKED_ANALYSIS',
          'BLOCKED_AMBIGUOUS_COLUMNS',
          'BLOCKED_SECURITY_REVIEW', 'BLOCKED_INVALID_GUIDS',
          'NO_CHANGE_CASE_INSENSITIVE_COLLATION'
      )
        THEN source.status
      ELSE target.status
    END,
    approved_by = IFF(source.status LIKE 'BLOCKED_%', NULL, target.approved_by),
    approved_at = IFF(source.status LIKE 'BLOCKED_%', NULL, target.approved_at),
    security_reviewed_by = IFF(source.status LIKE 'BLOCKED_%', NULL, target.security_reviewed_by),
    security_reviewed_at = IFF(source.status LIKE 'BLOCKED_%', NULL, target.security_reviewed_at)
WHEN NOT MATCHED THEN INSERT (
    migration_id, object_fqn, strategy, risk_score, risk_reasons,
    upstream_count, downstream_count, security_review_required,
    original_ddl, proposed_ddl, change_reference, status, generated_at
) VALUES (
    source.migration_id, source.object_fqn, source.strategy, source.risk_score,
    source.risk_reasons, source.upstream_count, source.downstream_count,
    source.security_review_required, NULL, NULL, NULL, source.status,
    CURRENT_TIMESTAMP()
);
