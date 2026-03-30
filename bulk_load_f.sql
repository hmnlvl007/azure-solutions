USE [db1];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ARITHABORT ON;
GO

/*====================================================================
  FAST RESUMABLE LOAD (NO THROTTLE)
  - Source is static
  - Source PK/CI: (PITM_TICKET_NO, PDAT_IO_TYPE, PDAT_SEQ)
  - Target remains HEAP during load
  - FULL recovery model
  - Progress is atomic per batch (safe restart)
====================================================================*/

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

/* Single-row progress table */
IF OBJECT_ID(N'dbo.BulkCopy_Progress', N'U') IS NULL
BEGIN
    IF EXISTS (SELECT 1 FROM dbo.TBL1)
    BEGIN
        RAISERROR('Target has rows but progress table does not exist. Start with empty target or seed progress first.', 16, 1);
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
    @BatchSize         int = 200000,  -- tuned down from very large batches for steadier commits/progress
    @PrintEveryBatches int = 1,       -- set to 5 to reduce output overhead
    @Rows              int,
    @BatchNo           int,
    @TotalRows         bigint,
    @LastTicket        char(36),
    @LastIO            char(1),
    @LastSeq           int,
    @NextTicket        char(36),
    @NextIO            char(1),
    @NextSeq           int,
    @StartTime         datetime2(3) = SYSDATETIME(),
    @BatchStart        datetime2(3),
    @msg               nvarchar(4000);

SELECT
    @LastTicket = LastTicket,
    @LastIO     = LastIO,
    @LastSeq    = LastSeq,
    @BatchNo    = BatchNo,
    @TotalRows  = TotalRows
FROM dbo.BulkCopy_Progress
WHERE Id = 1;

SET @msg = CONCAT(
    'Resume: batch=', @BatchNo,
    '; totalRows=', @TotalRows,
    '; lastKey=', RTRIM(@LastTicket), '/', @LastIO, '/', @LastSeq,
    '; batchSize=', @BatchSize,
    '; MAXDOP=8'
);
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

WHILE 1 = 1
BEGIN
    /* 1) Compute upper boundary key for next batch */
    SET @NextTicket = NULL;
    SET @NextIO     = NULL;
    SET @NextSeq    = NULL;

    SELECT TOP (1)
        @NextTicket = b.PITM_TICKET_NO,
        @NextIO     = b.PDAT_IO_TYPE,
        @NextSeq    = b.PDAT_SEQ
    FROM
    (
        SELECT TOP (@BatchSize)
            s.PITM_TICKET_NO,
            s.PDAT_IO_TYPE,
            s.PDAT_SEQ
        FROM [MountedDB].dbo.TBL1 AS s
        WHERE
               s.PITM_TICKET_NO > @LastTicket
            OR (s.PITM_TICKET_NO = @LastTicket AND s.PDAT_IO_TYPE > @LastIO)
            OR (s.PITM_TICKET_NO = @LastTicket AND s.PDAT_IO_TYPE = @LastIO AND s.PDAT_SEQ > @LastSeq)
        ORDER BY
            s.PITM_TICKET_NO,
            s.PDAT_IO_TYPE,
            s.PDAT_SEQ
    ) AS b
    ORDER BY
        b.PITM_TICKET_NO DESC,
        b.PDAT_IO_TYPE DESC,
        b.PDAT_SEQ DESC
    OPTION (RECOMPILE, MAXDOP 8);

    IF @NextTicket IS NULL
        BREAK;

    SET @BatchStart = SYSDATETIME();

    BEGIN TRAN;

        /* 2) Insert exact range: (LastKey, NextKey] */
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
        FROM [MountedDB].dbo.TBL1 AS s
        WHERE
            (
                   s.PITM_TICKET_NO > @LastTicket
                OR (s.PITM_TICKET_NO = @LastTicket AND s.PDAT_IO_TYPE > @LastIO)
                OR (s.PITM_TICKET_NO = @LastTicket AND s.PDAT_IO_TYPE = @LastIO AND s.PDAT_SEQ > @LastSeq)
            )
            AND
            (
                   s.PITM_TICKET_NO < @NextTicket
                OR (s.PITM_TICKET_NO = @NextTicket AND s.PDAT_IO_TYPE < @NextIO)
                OR (s.PITM_TICKET_NO = @NextTicket AND s.PDAT_IO_TYPE = @NextIO AND s.PDAT_SEQ <= @NextSeq)
            )
        OPTION (RECOMPILE, MAXDOP 8);

        SET @Rows = @@ROWCOUNT;

        IF @Rows <= 0
        BEGIN
            ROLLBACK TRAN;
            RAISERROR('Unexpected zero-row batch for computed boundary.', 16, 1);
            RETURN;
        END;

        SET @BatchNo   = @BatchNo + 1;
        SET @TotalRows = @TotalRows + @Rows;

        /* Atomic progress update in same transaction */
        UPDATE dbo.BulkCopy_Progress
        SET
            LastTicket = @NextTicket,
            LastIO     = @NextIO,
            LastSeq    = @NextSeq,
            BatchNo    = @BatchNo,
            TotalRows  = @TotalRows,
            UpdatedAt  = GETDATE()
        WHERE Id = 1;

    COMMIT TRAN;

    SET @LastTicket = @NextTicket;
    SET @LastIO     = @NextIO;
    SET @LastSeq    = @NextSeq;

    IF (@BatchNo % @PrintEveryBatches = 0)
    BEGIN
        SET @msg = CONCAT(
            'Batch=', @BatchNo,
            '; rows=', @Rows,
            '; total=', @TotalRows,
            '; batchSec=', DATEDIFF(SECOND, @BatchStart, SYSDATETIME()),
            '; avgRowsPerSec=', CAST(@TotalRows * 1.0 / NULLIF(DATEDIFF(SECOND, @StartTime, SYSDATETIME()), 0) AS int)
        );
        RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
    END
END

SET @msg = CONCAT(
    'FINISHED; batches=', @BatchNo,
    '; totalRows=', @TotalRows,
    '; elapsedMin=', DATEDIFF(MINUTE, @StartTime, SYSDATETIME())
);
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
GO