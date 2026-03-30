USE [db1];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* Drop and recreate progress table cleanly */
IF OBJECT_ID(N'dbo.BulkCopy_Progress', N'U') IS NOT NULL
    DROP TABLE dbo.BulkCopy_Progress;

CREATE TABLE dbo.BulkCopy_Progress
(
    LastTicket  char(36)  NOT NULL,
    LastIO      char(1)   NOT NULL,
    LastSeq     int       NOT NULL,
    BatchNo     int       NOT NULL,
    TotalRows   bigint    NOT NULL,
    UpdatedAt   datetime  NOT NULL
);

INSERT INTO dbo.BulkCopy_Progress
VALUES ('', '', -2147483648, 0, 0, GETDATE());
GO

/* Make sure target is empty for fresh start */
-- TRUNCATE TABLE dbo.TBL1;  -- uncomment if needed
GO

DECLARE
    @BatchSize   int        = 200000,
    @Rows        int        = 1,
    @BatchNo     int        = 0,
    @TotalRows   bigint     = 0,
    @LastTicket  char(36)   = '',
    @LastIO      char(1)    = '',
    @LastSeq     int        = -2147483648,
    @t0          datetime   = GETDATE(),
    @tb          datetime,
    @msg         nvarchar(4000);

/* Read resume point */
SELECT TOP (1)
    @LastTicket = LastTicket,
    @LastIO     = LastIO,
    @LastSeq    = LastSeq,
    @BatchNo    = BatchNo,
    @TotalRows  = TotalRows
FROM dbo.BulkCopy_Progress;

SET @msg = CONCAT('Start: batch=', @BatchNo, '; rows=', @TotalRows);
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

WHILE @Rows > 0
BEGIN
    SET @tb = GETDATE();

    INSERT INTO dbo.TBL1
    (
        PITM_TICKET_NO,
        PDAT_IO_TYPE,
        PDAT_SEQ,
        PDAT_VALUE
    )
    SELECT TOP (@BatchSize)
        s.PITM_TICKET_NO,
        s.PDAT_IO_TYPE,
        s.PDAT_SEQ,
        s.PDAT_VALUE
    FROM [MountedDB].dbo.TBL1 AS s
    WHERE
        (s.PITM_TICKET_NO = @LastTicket AND s.PDAT_IO_TYPE = @LastIO AND s.PDAT_SEQ > @LastSeq)
     OR (s.PITM_TICKET_NO = @LastTicket AND s.PDAT_IO_TYPE > @LastIO)
     OR (s.PITM_TICKET_NO > @LastTicket)
    ORDER BY
        s.PITM_TICKET_NO,
        s.PDAT_IO_TYPE,
        s.PDAT_SEQ;

    SET @Rows = @@ROWCOUNT;

    IF @Rows = 0
        BREAK;

    SET @BatchNo   = @BatchNo + 1;
    SET @TotalRows = @TotalRows + @Rows;

    /* Get last key of what we just inserted by re-reading source
       at exact offset — same plan, same data, already in buffer */
    ;WITH cte AS
    (
        SELECT TOP (@BatchSize)
            s.PITM_TICKET_NO,
            s.PDAT_IO_TYPE,
            s.PDAT_SEQ
        FROM [MountedDB].dbo.TBL1 AS s
        WHERE
            (s.PITM_TICKET_NO = @LastTicket AND s.PDAT_IO_TYPE = @LastIO AND s.PDAT_SEQ > @LastSeq)
         OR (s.PITM_TICKET_NO = @LastTicket AND s.PDAT_IO_TYPE > @LastIO)
         OR (s.PITM_TICKET_NO > @LastTicket)
        ORDER BY
            s.PITM_TICKET_NO,
            s.PDAT_IO_TYPE,
            s.PDAT_SEQ
    )
    SELECT TOP (1)
        @LastTicket = PITM_TICKET_NO,
        @LastIO     = PDAT_IO_TYPE,
        @LastSeq    = PDAT_SEQ
    FROM cte
    ORDER BY
        PITM_TICKET_NO DESC,
        PDAT_IO_TYPE DESC,
        PDAT_SEQ DESC;

    /* Save progress */
    UPDATE dbo.BulkCopy_Progress
    SET LastTicket = @LastTicket,
        LastIO     = @LastIO,
        LastSeq    = @LastSeq,
        BatchNo    = @BatchNo,
        TotalRows  = @TotalRows,
        UpdatedAt  = GETDATE();

    SET @msg = CONCAT(
        'Batch=', @BatchNo,
        ' +', @Rows,
        ' total=', @TotalRows,
        ' sec=', DATEDIFF(SECOND, @tb, GETDATE()),
        ' rps=', CAST(@TotalRows * 1.0 / NULLIF(DATEDIFF(SECOND, @t0, GETDATE()), 0) AS int)
    );
    RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
END

RAISERROR('Done.', 0, 1) WITH NOWAIT;
GO