USE [FacetsReport];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ARITHABORT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED; -- source is static/mounted copy
GO

/* ULTRA-FAST ONE-SHOT LOAD (target must be heap + empty) */

IF OBJECT_ID(N'dbo.TBL1', N'U') IS NULL
BEGIN
    RAISERROR('Target table missing.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[MountedDB].dbo.TBL1', N'U') IS NULL
BEGIN
    RAISERROR('Source table missing.', 16, 1);
    RETURN;
END;

/* Safety: this mode expects empty target */
IF EXISTS (SELECT 1 FROM dbo.TBL1)
BEGIN
    RAISERROR('Target is not empty. Truncate it first or use resumable script.', 16, 1);
    RETURN;
END;

DECLARE @t0 datetime2(3) = SYSDATETIME();
DECLARE @rows bigint;

RAISERROR('Starting ultra-fast one-shot insert...', 0, 1) WITH NOWAIT;

/* No batching, no waits, no progress writes, no ORDER BY */
INSERT INTO dbo.TBL1 WITH (TABLOCK)
(
    PITM_TICKET_NO,
    PDAT_IO_TYPE,
    PDAT_SEQ,
    PDAT_VALUE
)
SELECT
    s.PITM_TICKET_NO,
    s.PDAT_IO_TYPE,
    s.PDAT_SEQ,
    s.PDAT_VALUE
FROM [MountedDB].dbo.TBL1 AS s WITH (NOLOCK)
OPTION (MAXDOP 0);

SET @rows = @@ROWCOUNT;

RAISERROR(
    'Completed. Rows=%I64d, elapsed_sec=%d',
    0, 1,
    @rows,
    DATEDIFF(SECOND, @t0, SYSDATETIME())
) WITH NOWAIT;
GO