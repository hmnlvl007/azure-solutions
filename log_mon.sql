SET NOCOUNT ON;

DECLARE
    @DbName        sysname       = N'DB',
    @IntervalSec   int           = 30,
    @PrevUsedMB    decimal(18,2) = 0,
    @CurrUsedMB    decimal(18,2),
    @CurrSizeMB    decimal(18,2),
    @PctUsed       decimal(5,2),
    @DeltaMB       decimal(18,2),
    @RateMBMin     decimal(18,2),
    @LogReuse      nvarchar(60),
    @msg           nvarchar(4000),
    @StartTime     datetime      = GETDATE();

-- Header
RAISERROR('Time                    | Log Size MB  | Used MB      | Used %%   | Delta MB  | Rate MB/min | Log Reuse Wait', 0, 1) WITH NOWAIT;
RAISERROR('------------------------|--------------|--------------|----------|-----------|-------------|-----------------------------', 0, 1) WITH NOWAIT;

WHILE 1 = 1
BEGIN
    -- Current log size and usage
    SELECT
        @CurrSizeMB = li.cntr_value / 1024.0
    FROM sys.dm_os_performance_counters AS li
    WHERE li.counter_name = 'Log File(s) Size (KB)'
      AND li.instance_name = @DbName;

    SELECT
        @CurrUsedMB = lu.cntr_value / 1024.0
    FROM sys.dm_os_performance_counters AS lu
    WHERE lu.counter_name = 'Log File(s) Used Size (KB)'
      AND lu.instance_name = @DbName;

    SET @PctUsed = CASE WHEN @CurrSizeMB > 0
                        THEN (@CurrUsedMB / @CurrSizeMB) * 100.0
                        ELSE 0 END;

    -- Delta since last poll
    SET @DeltaMB   = @CurrUsedMB - @PrevUsedMB;
    SET @RateMBMin = @DeltaMB * (60.0 / @IntervalSec);

    -- Why can't the log be reused?
    SELECT @LogReuse = d.log_reuse_wait_desc
    FROM sys.databases AS d
    WHERE d.name = @DbName;

    -- Print row
    SET @msg = CONCAT(
        CONVERT(varchar(23), GETDATE(), 121),  ' | ',
        RIGHT(SPACE(12) + FORMAT(@CurrSizeMB, 'N2'), 12),  ' | ',
        RIGHT(SPACE(12) + FORMAT(@CurrUsedMB, 'N2'), 12),  ' | ',
        RIGHT(SPACE(7)  + FORMAT(@PctUsed,    'N1'), 7), '%', ' | ',
        RIGHT(SPACE(9)  + FORMAT(@DeltaMB,    'N2'), 9),  ' | ',
        RIGHT(SPACE(11) + FORMAT(@RateMBMin,  'N2'), 11),  ' | ',
        @LogReuse
    );
    RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

    -- Alert if log is > 85% full
    IF @PctUsed > 85.0
    BEGIN
        RAISERROR('*** WARNING: Log is %.1f%% full — ensure log backups are running! ***',
                  0, 1, @PctUsed) WITH NOWAIT;
    END

    SET @PrevUsedMB = @CurrUsedMB;

    WAITFOR DELAY '00:00:30';   -- poll interval
END