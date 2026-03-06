-- ═══════════════════════════════════════════════════════════════════════
-- STEP 3: Rollback — Undo an applied upload using history
-- ═══════════════════════════════════════════════════════════════════════

USE [YourDatabase]
GO

CREATE OR ALTER PROCEDURE dbo.usp_ZipCode_RollbackUpload
    @BatchId    INT,
    @RolledBackBy NVARCHAR(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @RolledBackBy IS NULL
        SET @RolledBackBy = SUSER_SNAME();

    -- ── Validate batch ──────────────────────────────────────────────
    DECLARE @status VARCHAR(20);
    SELECT @status = Status FROM dbo.ZipCodes_UploadLog WHERE BatchId = @BatchId;

    IF @status IS NULL
    BEGIN
        RAISERROR('Batch ID %d not found.', 16, 1, @BatchId);
        RETURN;
    END

    IF @status = 'PREVIEWED'
    BEGIN
        -- Just cancel the preview, clear staging
        UPDATE dbo.ZipCodes_UploadLog SET Status = 'CANCELLED', AppliedBy = @RolledBackBy, AppliedDate = SYSDATETIME() WHERE BatchId = @BatchId;
        TRUNCATE TABLE dbo.ZipCodes_Staging;
        PRINT '✓ Batch ' + CAST(@BatchId AS VARCHAR(10)) + ' cancelled. Staging table cleared.';
        RETURN;
    END

    IF @status != 'APPLIED'
    BEGIN
        RAISERROR('Batch %d has status "%s" — can only roll back APPLIED batches.', 16, 1, @BatchId, @status);
        RETURN;
    END

    -- ── Check this is the most recent applied batch ─────────────────
    DECLARE @latestApplied INT;
    SELECT TOP 1 @latestApplied = BatchId 
    FROM dbo.ZipCodes_UploadLog 
    WHERE Status = 'APPLIED' 
    ORDER BY AppliedDate DESC;

    IF @latestApplied != @BatchId
    BEGIN
        PRINT '⚠ WARNING: Batch ' + CAST(@BatchId AS VARCHAR(10)) + ' is not the most recent applied batch.';
        PRINT '  Most recent is batch ' + CAST(@latestApplied AS VARCHAR(10)) + '.';
        PRINT '  Rolling back out of order may produce unexpected results.';
        PRINT '  Proceeding anyway...';
    END

    -- ── Rollback: restore from the PREVIOUS snapshot in history ─────
    -- Since apply does a full clear+reload, rollback also does a full
    -- clear and restores the snapshot saved before that batch was applied.
    BEGIN TRANSACTION;

    BEGIN TRY
        -- Verify we have a snapshot for this batch
        IF NOT EXISTS (SELECT 1 FROM dbo.ZipCodes_History WHERE BatchId = @BatchId AND ChangeType = 'PREVIOUS')
        BEGIN
            RAISERROR('No snapshot found in history for batch %d. Cannot rollback.', 16, 1, @BatchId);
            RETURN;
        END

        -- Clear the main table
        DELETE FROM dbo.ZipCodes;

        -- Restore all rows from the snapshot taken before this batch was applied
        INSERT INTO dbo.ZipCodes (ZipCode, City, State, County, TimeZone, AreaCode)
        SELECT ZipCode, City, State, County, TimeZone, AreaCode
        FROM dbo.ZipCodes_History
        WHERE BatchId = @BatchId AND ChangeType = 'PREVIOUS';

        -- Update batch status
        UPDATE dbo.ZipCodes_UploadLog
        SET Status = 'ROLLED_BACK',
            AppliedBy = @RolledBackBy,
            Notes = ISNULL(Notes, '') + ' | Rolled back at ' + CONVERT(VARCHAR(30), SYSDATETIME(), 121)
        WHERE BatchId = @BatchId;

        COMMIT TRANSACTION;

        DECLARE @rowCount INT;
        SELECT @rowCount = COUNT(*) FROM dbo.ZipCodes;

        PRINT '═══════════════════════════════════════════════════════════';
        PRINT '  ✓ BATCH ' + CAST(@BatchId AS VARCHAR(10)) + ' ROLLED BACK SUCCESSFULLY';
        PRINT '  Rolled back by: ' + @RolledBackBy;
        PRINT '  Rows in table now: ' + CAST(@rowCount AS VARCHAR(10));
        PRINT '═══════════════════════════════════════════════════════════';

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @errMsg NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR('Rollback failed for batch %d: %s', 16, 1, @BatchId, @errMsg);
    END CATCH
END
GO

PRINT '✓ usp_ZipCode_RollbackUpload created.'
GO
