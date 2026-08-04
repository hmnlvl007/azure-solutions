USE DATABASE DLA_SEMANTIC;
USE SCHEMA TENANT_ID_ADMIN;

CREATE OR REPLACE PROCEDURE REGISTER_MIGRATION_DDL(
    MIGRATION_ID VARCHAR,
    PROPOSED_DDL VARCHAR,
    CHANGE_REFERENCE VARCHAR
)
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
    v_getddl_fqn VARCHAR;
    v_original VARCHAR;
    v_ddl_normalized VARCHAR;
    v_after_header VARCHAR;
BEGIN
    SELECT COUNT(*), MAX(m.object_fqn), MAX(c.database_name),
           MAX(c.schema_name), MAX(c.object_name)
      INTO :v_count, :v_fqn, :v_db, :v_schema, :v_name
    FROM MIGRATION_MANIFEST m
    JOIN TENANT_ID_COLUMN_CATALOG c ON c.object_fqn = m.object_fqn
    WHERE m.migration_id = :MIGRATION_ID
      AND m.status IN ('PLANNED', 'DDL_REVIEWED');

    IF (v_count <> 1) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Migration must exist and be PLANNED or DDL_REVIEWED');
    END IF;
    IF (PROPOSED_DDL IS NULL OR
        NOT REGEXP_LIKE(PROPOSED_DDL,
                        '^\\s*CREATE\\s+OR\\s+REPLACE\\s+(TRANSIENT\\s+)?DYNAMIC\\s+TABLE\\s+', 'i')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Only reviewed CREATE OR REPLACE DYNAMIC TABLE DDL is accepted');
    END IF;
    IF (NOT REGEXP_LIKE(PROPOSED_DDL, '(^|\\s)COPY\\s+GRANTS(\\s|$)', 'i')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Replacement DDL must include COPY GRANTS');
    END IF;
    IF (NOT REGEXP_LIKE(PROPOSED_DDL, '(^|\\s)COPY\\s+TAGS(\\s|$)', 'i')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Replacement DDL must include COPY TAGS');
    END IF;
    v_ddl_normalized := TRIM(REPLACE(UPPER(PROPOSED_DDL), '"', ''));
    v_after_header := TRIM(SUBSTR(
        v_ddl_normalized,
        POSITION('DYNAMIC TABLE' IN v_ddl_normalized) + LENGTH('DYNAMIC TABLE')
    ));
    IF (LEFT(v_after_header, LENGTH(v_fqn)) <> UPPER(v_fqn)
        OR SUBSTR(v_after_header, LENGTH(v_fqn) + 1, 1) NOT IN (' ', '(', CHR(10), CHR(13), CHR(9))) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'DDL target does not exactly match the manifest object');
    END IF;

    v_getddl_fqn := '"' || REPLACE(v_db, '"', '""') || '"."' ||
                    REPLACE(v_schema, '"', '""') || '"."' ||
                    REPLACE(v_name, '"', '""') || '"';
    SELECT GET_DDL('DYNAMIC_TABLE', :v_getddl_fqn, TRUE) INTO :v_original;

    UPDATE MIGRATION_MANIFEST
    SET original_ddl = :v_original,
        rollback_ddl = NULL,
        proposed_ddl = :PROPOSED_DDL,
        change_reference = :CHANGE_REFERENCE,
        status = 'DDL_REVIEWED',
        reviewed_by = CURRENT_USER(),
        reviewed_at = CURRENT_TIMESTAMP(),
        last_error = NULL
    WHERE migration_id = :MIGRATION_ID;

    INSERT INTO MIGRATION_AUDIT
    VALUES (UUID_STRING(), :MIGRATION_ID, 'REGISTER_DDL', 'SUCCEEDED', CURRENT_USER(),
            CURRENT_TIMESTAMP(), :PROPOSED_DDL,
            OBJECT_CONSTRUCT('change_reference', :CHANGE_REFERENCE));

    RETURN OBJECT_CONSTRUCT('status', 'DDL_REVIEWED', 'migration_id', MIGRATION_ID,
                            'object_fqn', v_fqn);
END;
$$;

CREATE OR REPLACE PROCEDURE REGISTER_ROLLBACK_DDL(
    MIGRATION_ID VARCHAR,
    ROLLBACK_DDL VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_count NUMBER;
    v_fqn VARCHAR;
    v_ddl_normalized VARCHAR;
    v_after_header VARCHAR;
BEGIN
    SELECT COUNT(*), MAX(object_fqn)
      INTO :v_count, :v_fqn
    FROM MIGRATION_MANIFEST
    WHERE migration_id = :MIGRATION_ID
      AND status = 'DDL_REVIEWED'
      AND original_ddl IS NOT NULL;

    IF (v_count <> 1) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Forward DDL must be registered first');
    END IF;
    IF (ROLLBACK_DDL IS NULL OR
        NOT REGEXP_LIKE(ROLLBACK_DDL,
                        '^\\s*CREATE\\s+OR\\s+REPLACE\\s+(TRANSIENT\\s+)?DYNAMIC\\s+TABLE\\s+', 'i')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Rollback must be CREATE OR REPLACE DYNAMIC TABLE DDL');
    END IF;
    v_ddl_normalized := TRIM(REPLACE(UPPER(ROLLBACK_DDL), '"', ''));
    v_after_header := TRIM(SUBSTR(
        v_ddl_normalized,
        POSITION('DYNAMIC TABLE' IN v_ddl_normalized) + LENGTH('DYNAMIC TABLE')
    ));
    IF (LEFT(v_after_header, LENGTH(v_fqn)) <> UPPER(v_fqn)
        OR SUBSTR(v_after_header, LENGTH(v_fqn) + 1, 1) NOT IN (' ', '(', CHR(10), CHR(13), CHR(9))) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Rollback DDL target does not exactly match the manifest object');
    END IF;
    IF (NOT REGEXP_LIKE(ROLLBACK_DDL, '(^|\\s)COPY\\s+GRANTS(\\s|$)', 'i')
        OR NOT REGEXP_LIKE(ROLLBACK_DDL, '(^|\\s)COPY\\s+TAGS(\\s|$)', 'i')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Rollback DDL must include COPY GRANTS and COPY TAGS');
    END IF;

    UPDATE MIGRATION_MANIFEST
    SET rollback_ddl = :ROLLBACK_DDL, last_error = NULL
    WHERE migration_id = :MIGRATION_ID;

    INSERT INTO MIGRATION_AUDIT
    VALUES (UUID_STRING(), :MIGRATION_ID, 'REGISTER_ROLLBACK_DDL', 'SUCCEEDED',
            CURRENT_USER(), CURRENT_TIMESTAMP(), :ROLLBACK_DDL,
            OBJECT_CONSTRUCT('object_fqn', :v_fqn));

    RETURN OBJECT_CONSTRUCT('status', 'ROLLBACK_DDL_REVIEWED',
                            'migration_id', MIGRATION_ID, 'object_fqn', v_fqn);
END;
$$;

CREATE OR REPLACE PROCEDURE APPROVE_MIGRATION(
    MIGRATION_ID VARCHAR,
    SECURITY_REVIEW_COMPLETED BOOLEAN
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_count NUMBER;
    v_fqn VARCHAR;
BEGIN
    SELECT COUNT(*), MAX(object_fqn)
      INTO :v_count, :v_fqn
    FROM MIGRATION_MANIFEST
    WHERE migration_id = :MIGRATION_ID
      AND status = 'DDL_REVIEWED'
      AND proposed_ddl IS NOT NULL
      AND original_ddl IS NOT NULL
      AND rollback_ddl IS NOT NULL;

    IF (v_count <> 1) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Migration requires reviewed forward and rollback DDL');
    END IF;
    IF (COALESCE(SECURITY_REVIEW_COMPLETED, FALSE) = FALSE) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Explicit security review attestation is required');
    END IF;

    UPDATE MIGRATION_MANIFEST
    SET status = 'APPROVED',
        security_reviewed_by = CURRENT_USER(),
        security_reviewed_at = CURRENT_TIMESTAMP(),
        approved_by = CURRENT_USER(),
        approved_at = CURRENT_TIMESTAMP(),
        last_error = NULL
    WHERE migration_id = :MIGRATION_ID;

    INSERT INTO MIGRATION_AUDIT
    VALUES (UUID_STRING(), :MIGRATION_ID, 'APPROVE', 'SUCCEEDED', CURRENT_USER(),
            CURRENT_TIMESTAMP(), NULL,
            OBJECT_CONSTRUCT('security_review_completed', TRUE));

    RETURN OBJECT_CONSTRUCT('status', 'APPROVED', 'migration_id', MIGRATION_ID,
                            'object_fqn', v_fqn);
END;
$$;

CREATE OR REPLACE PROCEDURE APPLY_MIGRATION(MIGRATION_ID VARCHAR, DRY_RUN BOOLEAN)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_count NUMBER;
    v_fqn VARCHAR;
    v_ddl VARCHAR;
    v_original_ddl VARCHAR;
    v_current_ddl VARCHAR;
    v_applied_ddl VARCHAR;
    v_db VARCHAR;
    v_schema VARCHAR;
    v_name VARCHAR;
    v_getddl_fqn VARCHAR;
    v_ddl_normalized VARCHAR;
    v_after_header VARCHAR;
BEGIN
    SELECT COUNT(*), MAX(m.object_fqn), MAX(m.proposed_ddl), MAX(m.original_ddl),
           MAX(c.database_name), MAX(c.schema_name), MAX(c.object_name)
      INTO :v_count, :v_fqn, :v_ddl, :v_original_ddl,
           :v_db, :v_schema, :v_name
    FROM MIGRATION_MANIFEST m
    JOIN TENANT_ID_COLUMN_CATALOG c ON c.object_fqn = m.object_fqn
    WHERE m.migration_id = :MIGRATION_ID
      AND m.status = 'APPROVED'
      AND m.approved_by IS NOT NULL
      AND m.approved_at IS NOT NULL
      AND m.security_reviewed_at IS NOT NULL;

    IF (v_count <> 1 OR v_ddl IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Exactly one approved migration with reviewed DDL is required');
    END IF;
    v_ddl_normalized := TRIM(REPLACE(UPPER(v_ddl), '"', ''));
    v_after_header := TRIM(SUBSTR(
        v_ddl_normalized,
        POSITION('DYNAMIC TABLE' IN v_ddl_normalized) + LENGTH('DYNAMIC TABLE')
    ));
    IF (NOT REGEXP_LIKE(v_ddl,
                        '^\\s*CREATE\\s+OR\\s+REPLACE\\s+(TRANSIENT\\s+)?DYNAMIC\\s+TABLE\\s+', 'i')
        OR LEFT(v_after_header, LENGTH(v_fqn)) <> UPPER(v_fqn)
        OR SUBSTR(v_after_header, LENGTH(v_fqn) + 1, 1) NOT IN (' ', '(', CHR(10), CHR(13), CHR(9))) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Approved DDL failed execution-time target validation');
    END IF;
    IF (NOT REGEXP_LIKE(v_ddl, '(^|\\s)COPY\\s+GRANTS(\\s|$)', 'i')
        OR NOT REGEXP_LIKE(v_ddl, '(^|\\s)COPY\\s+TAGS(\\s|$)', 'i')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Approved DDL must preserve grants and tags');
    END IF;

    v_getddl_fqn := '"' || REPLACE(v_db, '"', '""') || '"."' ||
                    REPLACE(v_schema, '"', '""') || '"."' ||
                    REPLACE(v_name, '"', '""') || '"';
    SELECT GET_DDL('DYNAMIC_TABLE', :v_getddl_fqn, TRUE) INTO :v_current_ddl;
    IF (v_current_ddl <> v_original_ddl) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Source DDL changed after review; register and approve again');
    END IF;
    IF (DRY_RUN) THEN
        RETURN OBJECT_CONSTRUCT('status', 'DRY_RUN', 'migration_id', MIGRATION_ID,
                                'object_fqn', v_fqn, 'ddl', v_ddl);
    END IF;

    UPDATE MIGRATION_MANIFEST
    SET status = 'APPLYING', last_error = NULL
    WHERE migration_id = :MIGRATION_ID;
    INSERT INTO MIGRATION_AUDIT
    VALUES (UUID_STRING(), :MIGRATION_ID, 'APPLY_START', 'RUNNING', CURRENT_USER(),
            CURRENT_TIMESTAMP(), :v_ddl, OBJECT_CONSTRUCT('object_fqn', :v_fqn));

    BEGIN
        EXECUTE IMMEDIATE :v_ddl;
    EXCEPTION
        WHEN OTHER THEN
            UPDATE MIGRATION_MANIFEST
            SET status = 'FAILED', last_error = :SQLERRM
            WHERE migration_id = :MIGRATION_ID;
            INSERT INTO MIGRATION_AUDIT
            VALUES (UUID_STRING(), :MIGRATION_ID, 'APPLY', 'FAILED', CURRENT_USER(),
                    CURRENT_TIMESTAMP(), :v_ddl, OBJECT_CONSTRUCT('error', :SQLERRM));
            RAISE;
    END;

    -- The replacement succeeded. From this point forward, never report plain
    -- FAILED: the application object has already changed.
    UPDATE MIGRATION_MANIFEST
    SET status = 'APPLIED_UNVERIFIED', applied_by = CURRENT_USER(),
        applied_at = CURRENT_TIMESTAMP(), last_error = NULL
    WHERE migration_id = :MIGRATION_ID;

    BEGIN
        SELECT GET_DDL('DYNAMIC_TABLE', :v_getddl_fqn, TRUE) INTO :v_applied_ddl;
        UPDATE MIGRATION_MANIFEST
        SET status = 'APPLIED', applied_ddl = :v_applied_ddl, last_error = NULL
        WHERE migration_id = :MIGRATION_ID;
        INSERT INTO MIGRATION_AUDIT
        VALUES (UUID_STRING(), :MIGRATION_ID, 'APPLY', 'SUCCEEDED', CURRENT_USER(),
                CURRENT_TIMESTAMP(), :v_ddl, OBJECT_CONSTRUCT('object_fqn', :v_fqn));
    EXCEPTION
        WHEN OTHER THEN
            UPDATE MIGRATION_MANIFEST
            SET status = 'APPLIED_UNVERIFIED', last_error = :SQLERRM
            WHERE migration_id = :MIGRATION_ID;
            INSERT INTO MIGRATION_AUDIT
            VALUES (UUID_STRING(), :MIGRATION_ID, 'APPLY_POSTCHECK', 'FAILED', CURRENT_USER(),
                    CURRENT_TIMESTAMP(), NULL, OBJECT_CONSTRUCT('error', :SQLERRM));
            RETURN OBJECT_CONSTRUCT('status', 'APPLIED_UNVERIFIED',
                                    'migration_id', MIGRATION_ID,
                                    'object_fqn', v_fqn,
                                    'reason', 'Replacement succeeded but post-DDL snapshot failed');
    END;

    RETURN OBJECT_CONSTRUCT('status', 'APPLIED', 'migration_id', MIGRATION_ID,
                            'object_fqn', v_fqn);
END;
$$;

CREATE OR REPLACE PROCEDURE APPROVE_ROLLBACK(MIGRATION_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_count NUMBER;
    v_fqn VARCHAR;
BEGIN
    SELECT COUNT(*), MAX(object_fqn)
      INTO :v_count, :v_fqn
    FROM MIGRATION_MANIFEST
    WHERE migration_id = :MIGRATION_ID
      AND status IN ('APPLIED', 'VALIDATED', 'VALIDATION_FAILED')
      AND rollback_ddl IS NOT NULL
      AND applied_ddl IS NOT NULL;

    IF (v_count <> 1) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'An applied migration with rollback and applied DDL is required');
    END IF;

    UPDATE MIGRATION_MANIFEST
    SET status = 'ROLLBACK_APPROVED', last_error = NULL
    WHERE migration_id = :MIGRATION_ID;

    INSERT INTO MIGRATION_AUDIT
    VALUES (UUID_STRING(), :MIGRATION_ID, 'APPROVE_ROLLBACK', 'SUCCEEDED',
            CURRENT_USER(), CURRENT_TIMESTAMP(), NULL,
            OBJECT_CONSTRUCT('object_fqn', :v_fqn));

    RETURN OBJECT_CONSTRUCT('status', 'ROLLBACK_APPROVED',
                            'migration_id', MIGRATION_ID, 'object_fqn', v_fqn);
END;
$$;

CREATE OR REPLACE PROCEDURE ROLLBACK_MIGRATION(MIGRATION_ID VARCHAR, DRY_RUN BOOLEAN)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_count NUMBER;
    v_fqn VARCHAR;
    v_ddl VARCHAR;
    v_applied_ddl VARCHAR;
    v_current_ddl VARCHAR;
    v_db VARCHAR;
    v_schema VARCHAR;
    v_name VARCHAR;
    v_getddl_fqn VARCHAR;
    v_ddl_normalized VARCHAR;
    v_after_header VARCHAR;
BEGIN
    SELECT COUNT(*), MAX(m.object_fqn), MAX(m.rollback_ddl), MAX(m.applied_ddl),
           MAX(c.database_name), MAX(c.schema_name), MAX(c.object_name)
      INTO :v_count, :v_fqn, :v_ddl, :v_applied_ddl,
           :v_db, :v_schema, :v_name
    FROM MIGRATION_MANIFEST m
    JOIN TENANT_ID_COLUMN_CATALOG c ON c.object_fqn = m.object_fqn
    WHERE m.migration_id = :MIGRATION_ID
      AND m.status = 'ROLLBACK_APPROVED';

    IF (v_count <> 1 OR v_ddl IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Migration must be ROLLBACK_APPROVED and have rollback DDL');
    END IF;

    v_ddl_normalized := TRIM(REPLACE(UPPER(v_ddl), '"', ''));
    v_after_header := TRIM(SUBSTR(
        v_ddl_normalized,
        POSITION('DYNAMIC TABLE' IN v_ddl_normalized) + LENGTH('DYNAMIC TABLE')
    ));
    IF (NOT REGEXP_LIKE(v_ddl,
                        '^\\s*CREATE\\s+OR\\s+REPLACE\\s+(TRANSIENT\\s+)?DYNAMIC\\s+TABLE\\s+', 'i')
        OR LEFT(v_after_header, LENGTH(v_fqn)) <> UPPER(v_fqn)
        OR SUBSTR(v_after_header, LENGTH(v_fqn) + 1, 1) NOT IN (' ', '(', CHR(10), CHR(13), CHR(9))
        OR NOT REGEXP_LIKE(v_ddl, '(^|\\s)COPY\\s+GRANTS(\\s|$)', 'i')
        OR NOT REGEXP_LIKE(v_ddl, '(^|\\s)COPY\\s+TAGS(\\s|$)', 'i')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Rollback DDL failed execution-time safety validation');
    END IF;

    v_getddl_fqn := '"' || REPLACE(v_db, '"', '""') || '"."' ||
                    REPLACE(v_schema, '"', '""') || '"."' ||
                    REPLACE(v_name, '"', '""') || '"';
    SELECT GET_DDL('DYNAMIC_TABLE', :v_getddl_fqn, TRUE) INTO :v_current_ddl;
    IF (v_current_ddl <> v_applied_ddl) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                                'reason', 'Current DDL differs from applied DDL; rollback would overwrite later changes');
    END IF;
    IF (DRY_RUN) THEN
        RETURN OBJECT_CONSTRUCT('status', 'DRY_RUN', 'migration_id', MIGRATION_ID,
                                'object_fqn', v_fqn, 'ddl', v_ddl);
    END IF;

    UPDATE MIGRATION_MANIFEST
    SET status = 'ROLLING_BACK', last_error = NULL
    WHERE migration_id = :MIGRATION_ID;
    INSERT INTO MIGRATION_AUDIT
    VALUES (UUID_STRING(), :MIGRATION_ID, 'ROLLBACK_START', 'RUNNING', CURRENT_USER(),
            CURRENT_TIMESTAMP(), :v_ddl, OBJECT_CONSTRUCT('object_fqn', :v_fqn));

    BEGIN
        EXECUTE IMMEDIATE :v_ddl;
    EXCEPTION
        WHEN OTHER THEN
            UPDATE MIGRATION_MANIFEST
            SET status = 'ROLLBACK_FAILED', last_error = :SQLERRM
            WHERE migration_id = :MIGRATION_ID;
            INSERT INTO MIGRATION_AUDIT
            VALUES (UUID_STRING(), :MIGRATION_ID, 'ROLLBACK', 'FAILED', CURRENT_USER(),
                    CURRENT_TIMESTAMP(), :v_ddl, OBJECT_CONSTRUCT('error', :SQLERRM));
            RAISE;
    END;

    UPDATE MIGRATION_MANIFEST
    SET status = 'ROLLED_BACK_UNVERIFIED', rolled_back_by = CURRENT_USER(),
        rolled_back_at = CURRENT_TIMESTAMP(), last_error = NULL
    WHERE migration_id = :MIGRATION_ID;

    BEGIN
        UPDATE MIGRATION_MANIFEST
        SET status = 'ROLLED_BACK', last_error = NULL
        WHERE migration_id = :MIGRATION_ID;
        INSERT INTO MIGRATION_AUDIT
        VALUES (UUID_STRING(), :MIGRATION_ID, 'ROLLBACK', 'SUCCEEDED', CURRENT_USER(),
                CURRENT_TIMESTAMP(), :v_ddl, OBJECT_CONSTRUCT('object_fqn', :v_fqn));
    EXCEPTION
        WHEN OTHER THEN
            UPDATE MIGRATION_MANIFEST
            SET status = 'ROLLED_BACK_UNVERIFIED', last_error = :SQLERRM
            WHERE migration_id = :MIGRATION_ID;
            RETURN OBJECT_CONSTRUCT('status', 'ROLLED_BACK_UNVERIFIED',
                                    'migration_id', MIGRATION_ID,
                                    'object_fqn', v_fqn,
                                    'reason', 'Rollback DDL succeeded but audit finalization failed');
    END;

    RETURN OBJECT_CONSTRUCT('status', 'ROLLED_BACK', 'migration_id', MIGRATION_ID,
                            'object_fqn', v_fqn);
END;
$$;
