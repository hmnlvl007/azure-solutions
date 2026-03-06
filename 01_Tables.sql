-- ═══════════════════════════════════════════════════════════════════════
-- Self-Service Zip Code Upload Solution
-- 
-- Pattern: Staging Table + Stored Procedure + Audit Trail
--
-- Workflow for users:
--   1. Load Excel data into the staging table (via SSMS Import Wizard,
--      linked Excel, or a simple app)
--   2. Execute: EXEC dbo.usp_ZipCode_ProcessUpload @UploadedBy = 'username'
--   3. Review the comparison report returned automatically
--   4. If satisfied: EXEC dbo.usp_ZipCode_ApplyUpload @BatchId = <id>
--   5. If not: EXEC dbo.usp_ZipCode_RollbackUpload @BatchId = <id>
--
-- Key design decisions:
--   - TWO-STEP process: preview first, apply second (prevents accidents)
--   - Full audit trail of every upload
--   - Automatic mismatch detection (both directions)
--   - One-click rollback capability
--   - No DBA involvement needed
-- ═══════════════════════════════════════════════════════════════════════

USE [YourDatabase]   -- ← Change to your database name
GO

-- ─────────────────────────────────────────────────────────────────────
-- 1. TABLES
-- ─────────────────────────────────────────────────────────────────────

-- The main zip code table (adjust columns to match your actual table)
-- If this already exists, skip this CREATE
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ZipCodes')
BEGIN
    CREATE TABLE dbo.ZipCodes (
        ZipCode         VARCHAR(10)     NOT NULL,
        City            VARCHAR(100)    NULL,
        State           VARCHAR(2)      NULL,
        County          VARCHAR(100)    NULL,
        TimeZone        VARCHAR(50)     NULL,
        AreaCode        VARCHAR(20)     NULL,
        -- Add your other columns here
        CONSTRAINT PK_ZipCodes PRIMARY KEY (ZipCode)
    );
END
GO

-- Staging table: users load their Excel data here
-- (mirrors the main table structure, no constraints to allow any data in)
IF OBJECT_ID('dbo.ZipCodes_Staging', 'U') IS NOT NULL
    DROP TABLE dbo.ZipCodes_Staging;
GO

CREATE TABLE dbo.ZipCodes_Staging (
    ZipCode         VARCHAR(10)     NULL,
    City            VARCHAR(100)    NULL,
    State           VARCHAR(2)      NULL,
    County          VARCHAR(100)    NULL,
    TimeZone        VARCHAR(50)     NULL,
    AreaCode        VARCHAR(20)     NULL
    -- Match columns to your ZipCodes table (but all nullable for loading)
);
GO

-- Upload batch tracking / audit trail
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ZipCodes_UploadLog')
BEGIN
    CREATE TABLE dbo.ZipCodes_UploadLog (
        BatchId         INT IDENTITY(1,1) PRIMARY KEY,
        UploadedBy      NVARCHAR(128)   NOT NULL,
        UploadDate      DATETIME2       NOT NULL DEFAULT SYSDATETIME(),
        StagingRowCount INT             NULL,
        CurrentRowCount INT             NULL,
        NewRows         INT             NULL,
        DeletedRows     INT             NULL,
        ModifiedRows    INT             NULL,
        UnchangedRows   INT             NULL,
        Status          VARCHAR(20)     NOT NULL DEFAULT 'PENDING',
            -- PENDING → PREVIEWED → APPLIED | ROLLED_BACK | EXPIRED
        AppliedDate     DATETIME2       NULL,
        AppliedBy       NVARCHAR(128)   NULL,
        Notes           NVARCHAR(500)   NULL
    );
END
GO

-- Backup table: holds snapshot before each apply
-- (created dynamically per batch, but we also keep a permanent history)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ZipCodes_History')
BEGIN
    CREATE TABLE dbo.ZipCodes_History (
        HistoryId       BIGINT IDENTITY(1,1) PRIMARY KEY,
        BatchId         INT             NOT NULL,
        ChangeType      VARCHAR(10)     NOT NULL,  -- INSERT, DELETE, UPDATE
        ZipCode         VARCHAR(10)     NULL,
        City            VARCHAR(100)    NULL,
        State           VARCHAR(2)      NULL,
        County          VARCHAR(100)    NULL,
        TimeZone        VARCHAR(50)     NULL,
        AreaCode        VARCHAR(20)     NULL,
        -- For UPDATEs, store the old values too
        Old_City        VARCHAR(100)    NULL,
        Old_State       VARCHAR(2)      NULL,
        Old_County      VARCHAR(100)    NULL,
        Old_TimeZone    VARCHAR(50)     NULL,
        Old_AreaCode    VARCHAR(20)     NULL,
        RecordedAt      DATETIME2       NOT NULL DEFAULT SYSDATETIME()
    );
END
GO

PRINT '✓ Tables created/verified.'
GO
