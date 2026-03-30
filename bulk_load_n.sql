USE [FacetsReport];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO


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

/* Progress table (required when target has no PK/CI during load) */
IF OBJECT_ID(N'dbo.BulkCopy_Progress', N'U') IS NULL
BEGIN
    IF EXISTS (SELECT 1 FROM dbo.TBL1)
    BEGIN
        RAISERROR('Target has rows but no progress table. Create a fresh load target or seed progress manually.', 16, 1);
        RETURN;
    END;

    CREATE TABLE dbo.BulkCopy_Progress
    (
        Id          int       NOT NULL
            CONSTRAINT PK_BulkCopy_Progress PRIMARY KEY
            CONSTRAINT CK_BulkCopy_Progress_Id CHECK (Id = 1),
        LastTicket  char(36)  NOT NULL,
        LastIO      char(1)   NOT NULL,
        LastSeq     int       NOT NULL,
        BatchNo     int       NOT NULL,
        TotalRows   bigint    NOT NULL,
        UpdatedAt   datetime  NOT NULL
    );

    INSERT INTO dbo.BulkCopy_Progress
    (Id, LastTicket, LastIO, LastSeq, BatchNo, TotalRows, UpdatedAt)
    VALUES
    (1, '', '', -2147483648, 0, 0, GETDATE());
END;
GO

DECLARE
    /* Performance knobs */
    @BatchSize            int          = 250000,   -- increase to 500000 if stable
    @EnableLogThrottle    bit          = 1,        -- keep safety
    @CheckLogEveryBatches int          = 5,        -- don't check every batch
    @PauseLogPct          decimal(5,1) = 90.0,     -- far less aggressive
    @ResumeLogPct         decimal(5,1) = 80.0,
    @ThrottlePollDelay    char(8)      = '00:00:05',

    /* State */
    @Rows                 int,
    @BatchNo              int,
    @TotalRows            bigint,
    @LastTicket           char(36),
    @LastIO               char(1),
    @LastSeq              int,
    @BatchLastTicket      char(36),
    @BatchLastIO          char(1),
    @BatchLastSeq         int,
    @LogPct               decimal(5,1),
    @BatchStart           datetime,
    @StartTime            datetime = GETDATE(),
    @msg                  nvarchar(4000);

SELECT
    @LastTicket = LastTicket,
    @LastIO     = LastIO,
    @LastSeq    = LastSeq,
    @BatchNo    = BatchNo,
    @TotalRows  = TotalRows
FROM dbo.BulkCopy_Progress
WHERE Id = 1;

SET @msg = CONCAT(
    'Resuming at batch=', @BatchNo,
    '; loaded=', @TotalRows,
    '; after key=', RTRIM(@LastTicket), '/', @LastIO, '/', @LastSeq,
    '; batchSize=', @BatchSize
);
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

IF OBJECT_ID('tempdb..#BatchKeys') IS NOT NULL
    DROP TABLE #BatchKeys;

CREATE TABLE #BatchKeys
(
    PITM_TICKET_NO char(36) NOT NULL,
    PDAT_IO_TYPE   char(1)  NOT NULL,
    PDAT_SEQ       int      NOT NULL,
    PRIMARY KEY CLUSTERED
    (
        PITM_TICKET_NO,
        PDAT_IO_TYPE,
        PDAT_SEQ
    )
);

WHILE 1 = 1
BEGIN
    /* Check log pressure only periodically (reduces overhead) */
    IF @EnableLogThrottle = 1 AND (@BatchNo % @CheckLogEveryBatches = 0)
    BEGIN
        SELECT @LogPct = used_log_space_in_percent
        FROM sys.dm_db_log_space_usage;

        WHILE @LogPct >= @PauseLogPct
        BEGIN
            SET @msg = CONCAT('Throttle pause: log=', @LogPct, '%. Waiting for < ', @ResumeLogPct, '%.');
            RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

            WAITFOR DELAY @ThrottlePollDelay;

            SELECT @LogPct = used_log_space_in_percent
            FROM sys.dm_db_log_space_usage;
        END;
    END;

    TRUNCATE TABLE #BatchKeys;
    SET @BatchStart = GETDATE();

    BEGIN TRAN;

        INSERT INTO dbo.TBL1 WITH (TABLOCK)
        (
            PITM_TICKET_NO,
            PDAT_IO_TYPE,
            PDAT_SEQ,
            PDAT_VALUE
        )
        OUTPUT
            inserted.PITM_TICKET_NO,
            inserted.PDAT_IO_TYPE,
            inserted.PDAT_SEQ
        INTO #BatchKeys
        (
            PITM_TICKET_NO,
            PDAT_IO_TYPE,
            PDAT_SEQ
        )
        SELECT TOP (@BatchSize)
            s.PITM_TICKET_NO,
            s.PDAT_IO_TYPE,
            s.PDAT_SEQ,
            s.PDAT_VALUE
        FROM [MountedDB].dbo.TBL1 AS s WITH (NOLOCK)
        WHERE
               s.PITM_TICKET_NO > @LastTicket
            OR (s.PITM_TICKET_NO = @LastTicket AND s.PDAT_IO_TYPE > @LastIO)
            OR (s.PITM_TICKET_NO = @LastTicket AND s.PDAT_IO_TYPE = @LastIO AND s.PDAT_SEQ > @LastSeq)
        ORDER BY
            s.PITM_TICKET_NO,
            s.PDAT_IO_TYPE,
            s.PDAT_SEQ
        OPTION (RECOMPILE);

        SET @Rows = @@ROWCOUNT;

        IF @Rows = 0
        BEGIN
            ROLLBACK TRAN;
            BREAK;
        END;

        SELECT TOP (1)
            @BatchLastTicket = PITM_TICKET_NO,
            @BatchLastIO     = PDAT_IO_TYPE,
            @BatchLastSeq    = PDAT_SEQ
        FROM #BatchKeys
        ORDER BY
            PITM_TICKET_NO DESC,
            PDAT_IO_TYPE DESC,
            PDAT_SEQ DESC;

        SET @BatchNo   = @BatchNo + 1;
        SET @TotalRows = @TotalRows + @Rows;

        UPDATE dbo.BulkCopy_Progress
        SET
            LastTicket = @BatchLastTicket,
            LastIO     = @BatchLastIO,
            LastSeq    = @BatchLastSeq,
            BatchNo    = @BatchNo,
            TotalRows  = @TotalRows,
            UpdatedAt  = GETDATE()
        WHERE Id = 1;

    COMMIT TRAN;

    SET @LastTicket = @BatchLastTicket;
    SET @LastIO     = @BatchLastIO;
    SET @LastSeq    = @BatchLastSeq;

    SET @msg = CONCAT(
        'Batch=', @BatchNo,
        '; rows=', @Rows,
        '; total=', @TotalRows,
        '; last=', RTRIM(@LastTicket), '/', @LastIO, '/', @LastSeq,
        '; ms=', DATEDIFF(MILLISECOND, @BatchStart, GETDATE()),
        '; rows/sec=', CAST(@TotalRows * 1.0 / NULLIF(DATEDIFF(SECOND, @StartTime, GETDATE()), 0) AS int)
    );
    RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
END;

RAISERROR('Load finished.', 0, 1) WITH NOWAIT;
GO