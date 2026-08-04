# TENANT_ID migration toolkit

This toolkit inventories Snowflake Dynamic Tables that expose `TENANT_ID`,
measures data and dependency risk, prepares a controlled migration manifest, and
prepares reviewed migration artifacts. Its guarded SQL executor is optional;
production changes should normally be committed and deployed through the same
source-controlled pipeline that owns the Dynamic Table definitions.

The recommended contract for GUID tenant keys is:

```sql
source_tenant_id COLLATE 'upper' AS tenant_id
```

This preserves the stored value but makes compatible comparisons, joins,
grouping, and ordering case-insensitive. Snowflake documents `upper`/`lower`
collations as generally faster than locale-aware `ci`; for hexadecimal GUIDs,
locale rules add no useful semantics. Use `en-ci` only when Unicode English
language collation is an explicit requirement:

```sql
source_tenant_id COLLATE 'en-ci' AS tenant_id
```

`UPPER(TRIM(source_tenant_id))` is normalization, not the comparison contract.
It can be added separately if canonical stored output is also required, but
normalization alone is not considered a completed migration.

Do not set account, database, or schema `DEFAULT_DDL_COLLATION` for this
migration. It does not change existing columns and would affect unrelated new
string columns.

## Files and execution order

1. `00_setup.sql` creates the control schema and persistent control tables.
2. `01_discover.sql` installs account-wide catalog discovery.
3. `01b_access_history_optional.sql` optionally records where `TENANT_ID` was
   accessed in the last 30 days. It requires Enterprise Edition or higher.
4. `02_analyze.sql` installs bounded `QUICK` and `FULL` data analysis.
5. `02a_inspect_definitions.sql` inspects effective collation and DDL evidence
   for tables, views, and Dynamic Tables.
6. `02b_collect_column_lineage.sql` starts from Dynamic Table tenant columns and
   collects native upstream/downstream column lineage, including renames.
7. `03_plan.sql` calculates risk and populates the migration manifest.
8. `04_migrate.sql` installs guarded registration, approval, optional
   application, and rollback procedures.
9. `05_validate.sql` installs validation and reporting views.
10. `06_health_checks.sql` installs read-only control-plane invariant checks.

Run the scripts with a role that can:

- monitor Dynamic Tables;
- read the required `SNOWFLAKE.ACCOUNT_USAGE` views;
- call `GET_DDL` for in-scope objects;
- select from candidates during analysis;
- create objects in the control schema; and
- replace a Dynamic Table only during an approved migration.

Account Usage can lag by several hours. Refresh discovery after the relevant
lag window before treating Account Usage-derived findings as complete.

The lineage key uses `database.schema.object` plus `|`-delimited paths.
Discovery fails closed if a quoted database, schema, or Dynamic Table name
contains `.` or `|`; use hashed array/JSON identity keys before deploying this
toolkit in an account that permits those identifier forms.

`TENANT_ID_COLUMN_CATALOG` includes tables, views, and Dynamic Tables. Analysis
and migration are restricted to objects also present in `DYNAMIC_TABLE_CATALOG`.

## Column-name discovery

Snowflake folds unquoted identifiers to uppercase, while quoted identifiers
retain their exact case. Discovery therefore compares a normalized identifier
formed by uppercasing and removing separators. These are automatically approved
as the same logical spelling:

- `tenant_id`, `TENANT_ID`, and quoted mixed-case variants;
- `tenantid`, `TenantID`, and quoted mixed-case variants.

Near matches such as `TenanID` are written to `TENANT_ID_NAME_CATALOG` with
`match_class = 'SUSPECTED_TYPO'`, but are not migrated automatically. Objects
with multiple approved candidate columns are blocked as ambiguous.

After discovery, review naming before running analysis:

```sql
SELECT *
FROM DLA_SEMANTIC.TENANT_ID_ADMIN.V_TENANT_ID_NAME_INVENTORY
ORDER BY match_class, object_count DESC, column_name;

SELECT *
FROM DLA_SEMANTIC.TENANT_ID_ADMIN.TENANT_ID_NAME_CATALOG
WHERE match_class = 'SUSPECTED_TYPO'
ORDER BY edit_distance, object_fqn, ordinal_position;

SELECT *
FROM DLA_SEMANTIC.TENANT_ID_ADMIN.V_TENANT_ID_COLUMN_AMBIGUITY;

CALL DLA_SEMANTIC.TENANT_ID_ADMIN.INSPECT_TENANT_ID_DEFINITIONS(
  'FV_PROD_US_SHARD_I',
  ARRAY_CONSTRUCT('RAW', 'STAGING', 'REPORTING', 'DATABRIDGE'),
  'ALL',
  5000
);

SELECT
  object_fqn, object_type, is_dynamic, column_name, effective_collation,
  definition_has_collate, definition_has_collation_function,
  definition_has_upper, definition_has_lower, definition_has_ilike,
  inspection_status, error_message
FROM DLA_SEMANTIC.TENANT_ID_ADMIN.V_LATEST_TENANT_ID_DEFINITION_INSPECTION
ORDER BY object_type, object_fqn, column_name;

SELECT
  object_fqn, architecture_layer, view_type, is_secure, column_name,
  effective_collation, tenant_case_handling,
  tenant_expression_has_collate, tenant_expression_has_upper,
  tenant_expression_has_lower
FROM DLA_SEMANTIC.TENANT_ID_ADMIN.V_TENANT_ID_VIEW_DEFINITION_USAGE
ORDER BY architecture_layer, object_fqn, column_name;

-- Scan every view definition, including internal-only tenant joins/filters.
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.SCAN_TENANT_ID_VIEW_DEFINITIONS(
  'FV_PROD_US_SHARD_I',
  ARRAY_CONSTRUCT('REPORTING', 'DATABRIDGE')
);

SELECT
  object_fqn, is_secure, definition_available,
  references_tenant_identifier,
  tenant_expression_has_collate, tenant_expression_has_upper,
  tenant_expression_has_lower, tenant_expression_has_ilike,
  view_definition
FROM DLA_SEMANTIC.TENANT_ID_ADMIN.V_LATEST_TENANT_ID_VIEW_DEFINITION_SCAN
ORDER BY schema_name, view_name;
```

`effective_collation` is the direct result of calling `COLLATION()` on the
exact, quoted column. It is `NULL` for an uncollated column and can also be
`NULL` when an object has no row to probe, so use the retained `definition_text`
as the second source of evidence. The `definition_has_*` fields scan the whole
object DDL and are triage signals; inspect `definition_text` to confirm that a
function belongs to the tenant-column expression rather than another column.

`SCHEMA_FILTERS` accepts an array of stored schema names, normally uppercase.
Pass `NULL` for all schemas in the selected database. `OBJECT_TYPE_FILTER`
accepts `ALL`, `TABLE`, `DYNAMIC_TABLE`, `VIEW`, or `MATERIALIZED_VIEW`.

Useful scoped runs:

```sql
-- RAW base tables only.
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.INSPECT_TENANT_ID_DEFINITIONS(
  'FV_PROD_US_SHARD_I', ARRAY_CONSTRUCT('RAW'), 'TABLE', 5000);

-- STAGING Dynamic Tables only.
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.INSPECT_TENANT_ID_DEFINITIONS(
  'FV_PROD_US_SHARD_I', ARRAY_CONSTRUCT('STAGING'), 'DYNAMIC_TABLE', 5000);

-- REPORTING plus known consumer schemas, regular and secure views.
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.INSPECT_TENANT_ID_DEFINITIONS(
  'FV_PROD_US_SHARD_I',
  ARRAY_CONSTRUCT('REPORTING', 'DATABRIDGE'), 'VIEW', 5000);

-- Every schema in the database, including unknown downstream view schemas.
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.INSPECT_TENANT_ID_DEFINITIONS(
  'FV_PROD_US_SHARD_I', NULL, 'ALL', 10000);

-- All regular and secure view definitions in every schema of the database.
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.SCAN_TENANT_ID_VIEW_DEFINITIONS(
  'FV_PROD_US_SHARD_I', NULL);
```

## Dynamic-Table-rooted column lineage

Object dependencies are not sufficient for renamed columns. The lineage
collector uses native `SNOWFLAKE.CORE.GET_LINEAGE` with domain `COLUMN`, starts
from each approved tenant-like column on a Dynamic Table, and collects both
upstream and downstream edges. This preserves mappings such as:

```text
RAW.ORG.ID -> STAGING.ORG.TENANTID -> REPORTING.SOME_VIEW.TENANT_ID
```

Install `02b_collect_column_lineage.sql`, then run:

```sql
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.COLLECT_DYNAMIC_TABLE_TENANT_LINEAGE(
  'FV_PROD_US_SHARD_I',
  ARRAY_CONSTRUCT('STAGING'),
  5,
  5000
);
```

Use the returned `run_id` to isolate the snapshot:

```sql
SELECT
  root_dynamic_table_fqn,
  root_column_name,
  direction,
  distance,
  source_object_fqn,
  source_column_name,
  source_object_type,
  source_is_dynamic,
  target_object_fqn,
  target_column_name,
  target_object_type,
  target_is_dynamic,
  column_renamed,
  process
FROM DLA_SEMANTIC.TENANT_ID_ADMIN.V_DYNAMIC_TABLE_TENANT_COLUMN_LINEAGE
WHERE run_id = '<run-id-returned-by-procedure>'
ORDER BY root_dynamic_table_fqn, root_column_name, direction, distance,
         source_object_fqn, target_object_fqn;

SELECT *
FROM DLA_SEMANTIC.TENANT_ID_ADMIN.TENANT_ID_COLUMN_LINEAGE_ERRORS
WHERE run_id = '<run-id-returned-by-procedure>';
```

`GET_LINEAGE` requires Enterprise Edition, supports a maximum distance of five,
and returns no rows when Snowflake has no recorded lineage. Missing access is
captured in the error table rather than terminating the full run.

## Safety model

- Catalog snapshots are published atomically.
- Discovery and planning do not change application objects.
- `QUICK` analysis performs one bounded metadata probe per object.
- `FULL` analysis can scan candidate objects and consume warehouse credits.
- Analysis never launches automatically when its procedure is installed.
- Planning never rewrites SQL definitions automatically.
- A migration cannot run unless it has reviewed forward and rollback DDL.
- Security review must be explicitly attested before approval.
- The executor accepts one migration ID, not an account-wide wildcard.
- Replacement and rollback DDL must contain `COPY GRANTS` and `COPY TAGS`.
- Apply and rollback reject source drift detected through `GET_DDL` snapshots.
- Interrupted or post-check failures remain visible as `APPLYING`,
  `APPLIED_UNVERIFIED`, `ROLLING_BACK`, or `ROLLED_BACK_UNVERIFIED`; they are
  never mislabeled as a clean pre-change failure.
- Rollback requires a separate approval operation and dry-run support.
- Discovery enumerates schemas independently, avoiding the unsafe account-wide
  10,000-row `SHOW` limit and duplicate-name pagination problem. It rejects a
  single schema at the limit rather than publishing an ambiguous snapshot.

Restrict direct `UPDATE`, `DELETE`, and `INSERT` privileges on the manifest and
audit tables. Migration operators should normally use the stored procedures;
otherwise they can bypass the workflow states enforced by those procedures.

## Recommended production design

Use the toolkit as a control plane, not as a SQL rewriter:

1. Schedule discovery and `QUICK` analysis; run `FULL` only for approved scopes.
2. Rank lineage roots and security-sensitive objects with `V_TENANT_ID_RISK`.
3. Change the authoritative Dynamic Table SQL in Git/dbt, explicitly projecting
   `source_tenant_id COLLATE 'upper' AS tenant_id` at every required published
   boundary. Do not assume collation survives every intervening expression.
4. Build and validate a canary or replacement object before the production
   cutover. Expect changed base-column collation alone not to alter already
   materialized Dynamic Table column metadata.
5. Store the reviewed forward and rollback DDL in the manifest for evidence.
6. Deploy through CI/CD. Use `APPLY_MIGRATION` only when no external deployment
   system exists, with a narrowly privileged owner role and one migration ID.
7. Refresh discovery, validate comparisons, policies, refresh mode, grants,
   tags, row counts, and case-folding collisions; then promote by waves.

`DEFAULT_DDL_COLLATION` is deliberately excluded: it only supplies the default
for subsequently created string columns in its scope. It does not retrofit
existing Dynamic Tables or make all comparison operations case-insensitive.

The original `GET_DDL` is retained as evidence, but it is not executed directly
for rollback. Build reviewed rollback DDL from that snapshot and explicitly add
`COPY GRANTS` and `COPY TAGS`.

## Typical workflow

```sql
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.REFRESH_TENANT_ID_DISCOVERY();

-- Start with a bounded scope, then increase deliberately.
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.ANALYZE_TENANT_ID(
  'QUICK', 'DLA_SEMANTIC', NULL, 100
);

-- FULL performs data scans. Limit it to a reviewed scope.
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.ANALYZE_TENANT_ID(
  'FULL', 'DLA_SEMANTIC', 'CORE', 25
);

-- Run 03_plan.sql, then review readiness.
SELECT *
FROM DLA_SEMANTIC.TENANT_ID_ADMIN.V_MIGRATION_READINESS
ORDER BY risk_score DESC, object_fqn;

CALL DLA_SEMANTIC.TENANT_ID_ADMIN.REGISTER_MIGRATION_DDL(
  '<migration-id>',
  $$CREATE OR REPLACE DYNAMIC TABLE ... COPY GRANTS COPY TAGS ...$$,
  'change-ticket-id'
);

-- Begin with ORIGINAL_DDL from the manifest, add preservation clauses, and
-- review the result before registration.
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.REGISTER_ROLLBACK_DDL(
  '<migration-id>',
  $$CREATE OR REPLACE DYNAMIC TABLE ... COPY GRANTS COPY TAGS ...$$
);

CALL DLA_SEMANTIC.TENANT_ID_ADMIN.APPROVE_MIGRATION(
  '<migration-id>',
  TRUE -- attests that collision and cross-tenant tests were reviewed
);

CALL DLA_SEMANTIC.TENANT_ID_ADMIN.APPLY_MIGRATION('<migration-id>', TRUE);
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.APPLY_MIGRATION('<migration-id>', FALSE);

-- Wait for initialization, then refresh the SHOW-based catalog and validate.
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.REFRESH_TENANT_ID_DISCOVERY();
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.VALIDATE_MIGRATION('<migration-id>');

-- If rollback is required:
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.APPROVE_ROLLBACK('<migration-id>');
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.ROLLBACK_MIGRATION('<migration-id>', TRUE);
CALL DLA_SEMANTIC.TENANT_ID_ADMIN.ROLLBACK_MIGRATION('<migration-id>', FALSE);

-- This should return no rows.
SELECT *
FROM DLA_SEMANTIC.TENANT_ID_ADMIN.V_TOOLKIT_INVARIANT_VIOLATIONS;
```

Before production rollout, test row-access policies with positive and negative
tenant cases. A case-folding collision in a security mapping is a hard block,
even when ordinary row-count comparisons pass.

`collision_groups` means that more than one stored case representation maps to
the same normalized comparison key. In a fact table this is evidence to review,
not proof of duplicate tenants. In tenant dimensions and security mappings,
combine it with the actual business key and uniqueness rules; the generic
toolkit cannot infer those keys safely.
