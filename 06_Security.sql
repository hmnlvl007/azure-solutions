-- ═══════════════════════════════════════════════════════════════════════
-- STEP 5: Security — Grant users minimal permissions
--
-- Users only need:
--   - INSERT/SELECT/DELETE on staging table (to load their Excel)
--   - EXECUTE on the stored procedures
--   - They CANNOT directly modify the main ZipCodes table
-- ═══════════════════════════════════════════════════════════════════════

USE [YourDatabase]
GO

-- ── Create a database role for zip code uploaders ────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'ZipCodeUploaders')
BEGIN
    CREATE ROLE [ZipCodeUploaders];
    PRINT '✓ Role ZipCodeUploaders created.';
END
GO

-- Staging table: full access (they need to load data here)
GRANT SELECT, INSERT, DELETE ON dbo.ZipCodes_Staging TO [ZipCodeUploaders];

-- Main table: read-only (they can view but not directly modify)
GRANT SELECT ON dbo.ZipCodes TO [ZipCodeUploaders];

-- Procedures: execute (these handle all the logic safely)
GRANT EXECUTE ON dbo.usp_ZipCode_ProcessUpload   TO [ZipCodeUploaders];
GRANT EXECUTE ON dbo.usp_ZipCode_ApplyUpload      TO [ZipCodeUploaders];
GRANT EXECUTE ON dbo.usp_ZipCode_RollbackUpload   TO [ZipCodeUploaders];
GRANT EXECUTE ON dbo.usp_ZipCode_ViewHistory       TO [ZipCodeUploaders];
GRANT EXECUTE ON dbo.usp_ZipCode_ViewBatchDetails  TO [ZipCodeUploaders];

-- History/Log: read-only
GRANT SELECT ON dbo.ZipCodes_UploadLog TO [ZipCodeUploaders];
GRANT SELECT ON dbo.ZipCodes_History   TO [ZipCodeUploaders];

PRINT '✓ Permissions granted to ZipCodeUploaders role.';
PRINT '';
PRINT 'To add a user to this role:';
PRINT '  ALTER ROLE [ZipCodeUploaders] ADD MEMBER [DOMAIN\UserName];';
GO

-- ═══════════════════════════════════════════════════════════════════════
-- Example: Add users to the role
-- ═══════════════════════════════════════════════════════════════════════
-- ALTER ROLE [ZipCodeUploaders] ADD MEMBER [DOMAIN\jsmith];
-- ALTER ROLE [ZipCodeUploaders] ADD MEMBER [DOMAIN\analyst_team];
