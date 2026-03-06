-- ═══════════════════════════════════════════════════════════════════════
-- STEP 2: Apply Upload — Replaces the entire table (after user confirms)
--
-- Workflow: Backs up all current rows to history as PREVIOUS (for rollback)
-- → records rows not present in the uploaded file as DELETED (for audit)
-- → DELETEs the main table → INSERTs all rows from staging. This is a
-- full replacement — the main table is cleared and reloaded every time.
-- Full history is recorded for rollback capability.
-- ═══════════════════════════════════════════════════════════════════════

USE [YourDatabase]
GO

CREATE OR ALTER PROCEDURE dbo.usp_ZipCode_ApplyUpload
    @BatchId    INT,
    @AppliedBy  NVARCHAR(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @AppliedBy IS NULL
        SET @AppliedBy = SUSER_SNAME();

    -- ── Validate batch ──────────────────────────────────────────────
    DECLARE @status VARCHAR(20), @uploadedBy NVARCHAR(128);
    SELECT @status = Status, @uploadedBy = UploadedBy
    FROM dbo.ZipCodes_UploadLog
    WHERE BatchId = @BatchId;

    IF @status IS NULL
    BEGIN
        RAISERROR('Batch ID %d not found.', 16, 1, @BatchId);
        RETURN;
    END

    IF @status NOT IN ('PREVIEWED', 'PENDING')
    BEGIN
        RAISERROR('Batch %d has status "%s" — can only apply PREVIEWED or PENDING batches.', 16, 1, @BatchId, @status);
        RETURN;
    END

    -- ── Verify staging still has data ────────────────────────────────
    IF NOT EXISTS (SELECT 1 FROM dbo.ZipCodes_Staging)
    BEGIN
        RAISERROR('Staging table is empty. Cannot apply batch %d.', 16, 1, @BatchId);
        RETURN;
    END

    -- ── Apply changes in a transaction ──────────────────────────────
    BEGIN TRANSACTION;

    BEGIN TRY
        -- ── Snapshot: Save ALL current rows to history for rollback ─
        INSERT INTO dbo.ZipCodes_History 
            (BatchId, ChangeType, ZipCode, City, State, County, TimeZone, AreaCode)
        SELECT @BatchId, 'PREVIOUS', c.ZipCode, c.City, c.State, c.County, c.TimeZone, c.AreaCode
        FROM dbo.ZipCodes c;

        DECLARE @previousCount INT = @@ROWCOUNT;

        -- ── Record rows being DELETED (in current table but not in the uploaded file)
        INSERT INTO dbo.ZipCodes_History 
            (BatchId, ChangeType, ZipCode, City, State, County, TimeZone, AreaCode)
        SELECT @BatchId, 'DELETED', c.ZipCode, c.City, c.State, c.County, c.TimeZone, c.AreaCode
        FROM dbo.ZipCodes c
        LEFT JOIN dbo.ZipCodes_Staging s ON c.ZipCode = s.ZipCode
        WHERE s.ZipCode IS NULL;

        DECLARE @deletedCount INT = @@ROWCOUNT;

        -- ── Clear the main table completely ──────────────────────────
        DELETE FROM dbo.ZipCodes;

        -- ── Load all rows from staging into the main table ──────────
        INSERT INTO dbo.ZipCodes (ZipCode, City, State, County, TimeZone, AreaCode)
        SELECT ZipCode, City, State, County, TimeZone, AreaCode
        FROM dbo.ZipCodes_Staging
        WHERE ZipCode IS NOT NULL;

        -- ── Update batch log ────────────────────────────────────────
        UPDATE dbo.ZipCodes_UploadLog
        SET Status      = 'APPLIED',
            AppliedDate = SYSDATETIME(),
            AppliedBy   = @AppliedBy,
            DeletedRows = @deletedCount
        WHERE BatchId = @BatchId;

        -- ── Clear staging table ─────────────────────────────────────
        TRUNCATE TABLE dbo.ZipCodes_Staging;

        COMMIT TRANSACTION;

        -- ── Success message ─────────────────────────────────────────
        DECLARE @newCount INT;
        SELECT @newCount = COUNT(*) FROM dbo.ZipCodes;

        PRINT '═══════════════════════════════════════════════════════════';
        PRINT '  ✓ BATCH ' + CAST(@BatchId AS VARCHAR(10)) + ' APPLIED SUCCESSFULLY';
        PRINT '  Applied by: ' + @AppliedBy;
        PRINT '  Previous rows backed up to history: ' + CAST(@previousCount AS VARCHAR(10));
        PRINT '  Rows removed (not in uploaded file): ' + CAST(@deletedCount AS VARCHAR(10));
        PRINT '  Rows in table now: ' + CAST(@newCount AS VARCHAR(10));
        PRINT '';
        PRINT '  To UNDO this change:';
        PRINT '    EXEC dbo.usp_ZipCode_RollbackUpload @BatchId = ' + CAST(@BatchId AS VARCHAR(10));
        PRINT '═══════════════════════════════════════════════════════════';

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        DECLARE @errMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @errSev INT = ERROR_SEVERITY();

        UPDATE dbo.ZipCodes_UploadLog
        SET Status = 'ERROR', Notes = LEFT(@errMsg, 500)
        WHERE BatchId = @BatchId;

        RAISERROR('Apply failed for batch %d: %s', 16, 1, @BatchId, @errMsg);
    END CATCH
END
GO

PRINT '✓ usp_ZipCode_ApplyUpload created.'
GO
