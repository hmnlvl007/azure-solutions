-- ═══════════════════════════════════════════════════════════════════════
-- STEP 1: Process Upload — Preview comparison BEFORE applying
--
-- Users call this after loading data into ZipCodes_Staging.
-- It does NOT change the main table — just shows what WOULD change.
-- NOTE: When applied, the main table is FULLY replaced (truncated
-- and reloaded) with the staging data. The comparison below shows
-- what the differences are between current and new data.
-- ═══════════════════════════════════════════════════════════════════════

USE [YourDatabase]
GO

CREATE OR ALTER PROCEDURE dbo.usp_ZipCode_ProcessUpload
    @UploadedBy NVARCHAR(128) = NULL,
    @Notes      NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Default to current user
    IF @UploadedBy IS NULL
        SET @UploadedBy = SUSER_SNAME();

    -- ── Validate staging table has data ──────────────────────────────
    DECLARE @stagingCount INT, @currentCount INT;
    SELECT @stagingCount = COUNT(*) FROM dbo.ZipCodes_Staging;
    SELECT @currentCount = COUNT(*) FROM dbo.ZipCodes;

    IF @stagingCount = 0
    BEGIN
        RAISERROR('Staging table is empty. Please load your Excel data into dbo.ZipCodes_Staging first.', 16, 1);
        RETURN;
    END

    -- ── Check for duplicates in staging ──────────────────────────────
    DECLARE @dupeCount INT;
    SELECT @dupeCount = COUNT(*) - COUNT(DISTINCT ZipCode)
    FROM dbo.ZipCodes_Staging
    WHERE ZipCode IS NOT NULL;

    IF @dupeCount > 0
    BEGIN
        PRINT '⚠ WARNING: Staging table contains ' + CAST(@dupeCount AS VARCHAR(10)) + ' duplicate zip codes.';
        PRINT '  Duplicates:';
        SELECT ZipCode, COUNT(*) AS Occurrences
        FROM dbo.ZipCodes_Staging
        WHERE ZipCode IS NOT NULL
        GROUP BY ZipCode
        HAVING COUNT(*) > 1
        ORDER BY COUNT(*) DESC;
    END

    -- ── Check for NULLs in key column ────────────────────────────────
    DECLARE @nullCount INT;
    SELECT @nullCount = COUNT(*) FROM dbo.ZipCodes_Staging WHERE ZipCode IS NULL;
    IF @nullCount > 0
    BEGIN
        PRINT '⚠ WARNING: Staging table contains ' + CAST(@nullCount AS VARCHAR(10)) + ' rows with NULL zip codes. These will be ignored.';
    END

    -- ── Perform comparison ───────────────────────────────────────────
    -- NEW rows: in staging but not in current
    DECLARE @newRows INT, @deletedRows INT, @modifiedRows INT, @unchangedRows INT;

    SELECT @newRows = COUNT(*)
    FROM dbo.ZipCodes_Staging s
    LEFT JOIN dbo.ZipCodes c ON s.ZipCode = c.ZipCode
    WHERE c.ZipCode IS NULL
      AND s.ZipCode IS NOT NULL;

    -- DELETED rows: in current but not in staging
    SELECT @deletedRows = COUNT(*)
    FROM dbo.ZipCodes c
    LEFT JOIN dbo.ZipCodes_Staging s ON c.ZipCode = s.ZipCode
    WHERE s.ZipCode IS NULL;

    -- MODIFIED rows: exist in both but values differ
    SELECT @modifiedRows = COUNT(*)
    FROM dbo.ZipCodes c
    INNER JOIN dbo.ZipCodes_Staging s ON c.ZipCode = s.ZipCode
    WHERE ISNULL(c.City, '')     != ISNULL(s.City, '')
       OR ISNULL(c.State, '')    != ISNULL(s.State, '')
       OR ISNULL(c.County, '')   != ISNULL(s.County, '')
       OR ISNULL(c.TimeZone, '') != ISNULL(s.TimeZone, '')
       OR ISNULL(c.AreaCode, '') != ISNULL(s.AreaCode, '');

    -- UNCHANGED rows: exist in both with same values
    SELECT @unchangedRows = COUNT(*)
    FROM dbo.ZipCodes c
    INNER JOIN dbo.ZipCodes_Staging s ON c.ZipCode = s.ZipCode
    WHERE ISNULL(c.City, '')     = ISNULL(s.City, '')
      AND ISNULL(c.State, '')    = ISNULL(s.State, '')
      AND ISNULL(c.County, '')   = ISNULL(s.County, '')
      AND ISNULL(c.TimeZone, '') = ISNULL(s.TimeZone, '')
      AND ISNULL(c.AreaCode, '') = ISNULL(s.AreaCode, '');

    -- ── Create batch record ─────────────────────────────────────────
    DECLARE @batchId INT;

    INSERT INTO dbo.ZipCodes_UploadLog 
        (UploadedBy, StagingRowCount, CurrentRowCount, NewRows, DeletedRows, ModifiedRows, UnchangedRows, Status, Notes)
    VALUES 
        (@UploadedBy, @stagingCount, @currentCount, @newRows, @deletedRows, @modifiedRows, @unchangedRows, 'PREVIEWED', @Notes);

    SET @batchId = SCOPE_IDENTITY();

    -- ── Print summary ────────────────────────────────────────────────
    PRINT '═══════════════════════════════════════════════════════════';
    PRINT '  ZIP CODE UPLOAD — COMPARISON PREVIEW';
    PRINT '═══════════════════════════════════════════════════════════';
    PRINT '  Batch ID:        ' + CAST(@batchId AS VARCHAR(10));
    PRINT '  Uploaded by:     ' + @UploadedBy;
    PRINT '  Current rows:    ' + CAST(@currentCount AS VARCHAR(10));
    PRINT '  Staged rows:     ' + CAST(@stagingCount AS VARCHAR(10));
    PRINT '  ─────────────────────────────────────────────────────────';
    PRINT '  NEW (to add):    ' + CAST(@newRows AS VARCHAR(10));
    PRINT '  DELETED (to remove): ' + CAST(@deletedRows AS VARCHAR(10));
    PRINT '  MODIFIED (changed):  ' + CAST(@modifiedRows AS VARCHAR(10));
    PRINT '  UNCHANGED:       ' + CAST(@unchangedRows AS VARCHAR(10));
    PRINT '═══════════════════════════════════════════════════════════';
    PRINT '';

    IF @newRows + @deletedRows + @modifiedRows = 0
    BEGIN
        PRINT '✓ No changes detected. Staging data matches current data.';
        PRINT '  No action needed.';
        UPDATE dbo.ZipCodes_UploadLog SET Status = 'NO_CHANGES' WHERE BatchId = @batchId;
        RETURN;
    END

    -- ── Show detail: NEW rows ────────────────────────────────────────
    IF @newRows > 0
    BEGIN
        PRINT '── NEW ZIP CODES (will be ADDED) ──────────────────────';
        SELECT 'NEW' AS ChangeType, s.ZipCode, s.City, s.State, s.County, s.TimeZone, s.AreaCode
        FROM dbo.ZipCodes_Staging s
        LEFT JOIN dbo.ZipCodes c ON s.ZipCode = c.ZipCode
        WHERE c.ZipCode IS NULL AND s.ZipCode IS NOT NULL
        ORDER BY s.ZipCode;
    END

    -- ── Show detail: DELETED rows ────────────────────────────────────
    IF @deletedRows > 0
    BEGIN
        PRINT '── DELETED ZIP CODES (will be REMOVED) ────────────────';
        SELECT 'DELETED' AS ChangeType, c.ZipCode, c.City, c.State, c.County, c.TimeZone, c.AreaCode
        FROM dbo.ZipCodes c
        LEFT JOIN dbo.ZipCodes_Staging s ON c.ZipCode = s.ZipCode
        WHERE s.ZipCode IS NULL
        ORDER BY c.ZipCode;
    END

    -- ── Show detail: MODIFIED rows (side-by-side) ────────────────────
    IF @modifiedRows > 0
    BEGIN
        PRINT '── MODIFIED ZIP CODES (values changed) ────────────────';
        SELECT 
            'MODIFIED' AS ChangeType,
            c.ZipCode,
            -- Current values
            c.City      AS [Current_City],
            s.City      AS [New_City],
            c.State     AS [Current_State],
            s.State     AS [New_State],
            c.County    AS [Current_County],
            s.County    AS [New_County],
            c.TimeZone  AS [Current_TimeZone],
            s.TimeZone  AS [New_TimeZone],
            c.AreaCode  AS [Current_AreaCode],
            s.AreaCode  AS [New_AreaCode]
        FROM dbo.ZipCodes c
        INNER JOIN dbo.ZipCodes_Staging s ON c.ZipCode = s.ZipCode
        WHERE ISNULL(c.City, '')     != ISNULL(s.City, '')
           OR ISNULL(c.State, '')    != ISNULL(s.State, '')
           OR ISNULL(c.County, '')   != ISNULL(s.County, '')
           OR ISNULL(c.TimeZone, '') != ISNULL(s.TimeZone, '')
           OR ISNULL(c.AreaCode, '') != ISNULL(s.AreaCode, '')
        ORDER BY c.ZipCode;
    END

    -- ── Instructions ────────────────────────────────────────────────
    PRINT '';
    PRINT '═══════════════════════════════════════════════════════════';
    PRINT '  NEXT STEPS:';
    PRINT '  • To APPLY (table will be cleared and reloaded):';
    PRINT '      EXEC dbo.usp_ZipCode_ApplyUpload @BatchId = ' + CAST(@batchId AS VARCHAR(10));
    PRINT '';
    PRINT '  • To CANCEL and discard:';
    PRINT '      EXEC dbo.usp_ZipCode_RollbackUpload @BatchId = ' + CAST(@batchId AS VARCHAR(10));
    PRINT '═══════════════════════════════════════════════════════════';

    -- Return batch ID for programmatic use
    SELECT @batchId AS BatchId, @newRows AS NewRows, @deletedRows AS DeletedRows, 
           @modifiedRows AS ModifiedRows, @unchangedRows AS UnchangedRows;
END
GO

PRINT '✓ usp_ZipCode_ProcessUpload created.'
GO
