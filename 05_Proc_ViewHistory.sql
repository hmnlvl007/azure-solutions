-- ═══════════════════════════════════════════════════════════════════════
-- STEP 4: View Upload History — Lets users check past uploads
-- ═══════════════════════════════════════════════════════════════════════

USE [YourDatabase]
GO

-- View recent upload batches
CREATE OR ALTER PROCEDURE dbo.usp_ZipCode_ViewHistory
    @TopN INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (@TopN)
        BatchId,
        UploadedBy,
        UploadDate,
        StagingRowCount,
        CurrentRowCount,
        NewRows,
        DeletedRows,
        ModifiedRows,
        UnchangedRows,
        Status,
        AppliedDate,
        AppliedBy,
        Notes
    FROM dbo.ZipCodes_UploadLog
    ORDER BY BatchId DESC;
END
GO

-- View detailed changes for a specific batch
CREATE OR ALTER PROCEDURE dbo.usp_ZipCode_ViewBatchDetails
    @BatchId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Batch summary
    SELECT BatchId, UploadedBy, UploadDate, StagingRowCount, CurrentRowCount,
           NewRows, DeletedRows, ModifiedRows, UnchangedRows,
           Status, AppliedDate, AppliedBy, Notes
    FROM dbo.ZipCodes_UploadLog
    WHERE BatchId = @BatchId;

    -- Rows that were DELETED by this batch (existed before, not in uploaded file)
    PRINT '';
    PRINT '── Rows DELETED in Batch ' + CAST(@BatchId AS VARCHAR(10))
        + ' (were in table, missing from uploaded file) ──';

    SELECT
        ZipCode, City, State, County, TimeZone, AreaCode,
        RecordedAt AS DeletedAt
    FROM dbo.ZipCodes_History
    WHERE BatchId = @BatchId
      AND ChangeType = 'DELETED'
    ORDER BY ZipCode;

    -- Full previous snapshot (all rows before the upload was applied)
    PRINT '';
    PRINT '── Full snapshot BEFORE Batch ' + CAST(@BatchId AS VARCHAR(10)) + ' was applied ──';

    SELECT
        ZipCode, City, State, County, TimeZone, AreaCode,
        RecordedAt AS SnapshotAt
    FROM dbo.ZipCodes_History
    WHERE BatchId = @BatchId
      AND ChangeType = 'PREVIOUS'
    ORDER BY ZipCode;
END
GO

PRINT '✓ History procedures created.'
GO
