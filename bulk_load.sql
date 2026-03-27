USE [DB];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO


/*---------------------------
  Safety checks
---------------------------*/
IF OBJECT_ID(N'dbo.TBL1', N'U') IS NULL
BEGIN
    RAISERROR('Target table dbo.TBL1 does not exist.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[MountedDB].dbo.TBL1', N'U') IS NULL
BEGIN
    RAISERROR('Source table [MountedDB].dbo.TBL1 does not exist.', 16, 1);
    RETURN;
END;

/*---------------------------
  Parameters
  Conservative defaults for FULL model with 15-min log backups
---------------------------*/
DECLARE
    @BatchSize        int            = 5000,   -- start conservative
    @PauseLogPct      decimal(5,1)   = 50.0,   -- stop loading above this
    @ResumeLogPct     decimal(5,1)   = 20.0,   -- resume after backup clears log
    @PollDelay        char(8)        = '00:00:15',
    @BatchDelay       char(8)        = '00:00:02';   -- gentle throttle between batches

DECLARE
    @Rows             int,
    @BatchNo          int,
    @TotalRows        bigint,
    @LastTicket       char(36),
    @LastIO           char(1),
    @LastSeq          int,
    @BatchLastTicket  char(36),
    @BatchLastIO      char(1),
    @BatchLastSeq     int,
    @LogPct           decimal(5,1),
    @StartTime        datetime,
    @BatchStart       datetime,
    @msg              nvarchar(4000),
    @SourceRowsMeta   bigint,
    @TargetRows       bigint;

/*---------------------------
  Progress table
  This is required because target has no CI/PK during load
---------------------------*/
IF OBJECT_ID(N'dbo.BulkCopy_Progress', N'U') IS NULL
BEGIN
    IF EXISTS (SELECT 1 FROM dbo.TBL1)
    BEGIN
        RAISERROR(
            'Target heap already has rows, but dbo.BulkCopy_Progress does not exist. ' +
            'For correctness, start with an empty target or create a new load plan.',
            16, 1
        );
        RETURN;
    END;

    CREATE TABLE dbo.BulkCopy_Progress
    (
        Id          int        NOT NULL
            CONSTRAINT PK_BulkCopy_Progress PRIMARY KEY
            CONSTRAINT CK_BulkCopy_Progress_Id CHECK (Id = 1),
        LastTicket  char(36)   NOT NULL,
        LastIO      char(1)    NOT NULL,
        LastSeq     int        NOT NULL,
        BatchNo     int        NOT NULL,
        TotalRows   bigint     NOT NULL,
        UpdatedAt   datetime   NOT NULL
    );

    INSERT INTO dbo.BulkCopy_Progress
    (
        Id, LastTicket, LastIO, LastSeq, BatchNo, TotalRows, UpdatedAt
    )
    VALUES
    (
        1, '', '', -2147483648, 0, 0, GETDATE()
    );
END;

/*---------------------------
  Read resume point
---------------------------*/
SELECT
    @LastTicket = LastTicket,
    @LastIO     = LastIO,
    @LastSeq    = LastSeq,
    @BatchNo    = BatchNo,
    @TotalRows  = TotalRows
FROM dbo.BulkCopy_Progress
WHERE Id = 1;

SET @StartTime = GETDATE();

SET @msg = CONCAT(
    'Starting/resuming. BatchSize=', @BatchSize,
    '; LastKey=', RTRIM(@LastTicket), '/', @LastIO, '/', @LastSeq,
    '; AlreadyLoaded=', @TotalRows
);
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

/*---------------------------
  Metadata source row count for rough progress only
---------------------------*/
SELECT @SourceRowsMeta = SUM(p.rows)
FROM [MountedDB].sys.partitions AS p
INNER JOIN [MountedDB].sys.tables AS t
    ON p.object_id = t.object_id
INNER JOIN [MountedDB].sys.schemas AS s
    ON t.schema_id = s.schema_id
WHERE s.name = N'dbo'
  AND t.name = N'TBL1'
  AND p.index_id IN (0, 1);

SET @msg = CONCAT('Source metadata row count = ', COALESCE(CONVERT(varchar(30), @SourceRowsMeta), 'NULL'));
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

/*---------------------------
  Temp table to capture actual inserted keys for each batch
---------------------------*/
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

/*---------------------------
  Main loop
---------------------------*/
WHILE 1 = 1
BEGIN
    /* throttle based on actual log usage */
    SELECT @LogPct = used_log_space_in_percent
    FROM sys.dm_db_log_space_usage;

    WHILE @LogPct >= @PauseLogPct
    BEGIN
        SET @msg = CONCAT(
            'PAUSE: log used = ', @LogPct,
            '%; waiting until below ', @ResumeLogPct, '%.'
        );
        RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

        WAITFOR DELAY @PollDelay;

        SELECT @LogPct = used_log_space_in_percent
        FROM sys.dm_db_log_space_usage;
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
        FROM [MountedDB].dbo.TBL1 AS s
        WHERE
               s.PITM_TICKET_NO > @LastTicket
            OR (s.PITM_TICKET_NO = @LastTicket AND s.PDAT_IO_TYPE > @LastIO)
            OR (s.PITM_TICKET_NO = @LastTicket AND s.PDAT_IO_TYPE = @LastIO AND s.PDAT_SEQ > @LastSeq)
        ORDER BY
            s.PITM_TICKET_NO,
            s.PDAT_IO_TYPE,
            s.PDAT_SEQ;

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

    SELECT @LogPct = used_log_space_in_percent
    FROM sys.dm_db_log_space_usage;

    SET @msg = CONCAT(
        'Batch ', @BatchNo,
        '; Rows=', @Rows,
        '; Total=', @TotalRows,
        '; LastKey=', RTRIM(@LastTicket), '/', @LastIO, '/', @LastSeq,
        '; Log=', @LogPct, '%',
        '; BatchMs=', DATEDIFF(MILLISECOND, @BatchStart, GETDATE())
    );

    IF @SourceRowsMeta IS NOT NULL AND @SourceRowsMeta > 0
    BEGIN
        SET @msg = CONCAT(
            @msg,
            '; ApproxPct=',
            CONVERT(decimal(9,2), @TotalRows * 100.0 / @SourceRowsMeta),
            '%'
        );
    END;

    RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

    WAITFOR DELAY @BatchDelay;
END;

/*---------------------------
  Validation
---------------------------*/
SELECT @TargetRows = COUNT_BIG(*)
FROM dbo.TBL1;

SET @msg = CONCAT(
    'Load finished. ProgressRows=', @TotalRows,
    '; TargetCount=', @TargetRows,
    '; SourceMetaCount=', COALESCE(CONVERT(varchar(30), @SourceRowsMeta), 'NULL')
);
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

IF @TargetRows <> @TotalRows
BEGIN
    RAISERROR('Validation failed: target row count does not match progress table.', 16, 1);
    RETURN;
END;

RAISERROR('Load complete. Target heap is loaded. Create clustered PK/index only after this point.', 0, 1) WITH NOWAIT;
GO