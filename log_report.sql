SET NOCOUNT ON;

USE [FacetsReport];

SELECT
    DB_NAME()                                               AS [Database],

    -- Actual log file size on disk
    CAST(SUM(df.size) * 8.0 / 1024 AS decimal(18,2))       AS [Log File Size MB],

    -- Used space from the DMV (authoritative)
    CAST(lu.used_log_space_in_bytes / 1048576.0
         AS decimal(18,2))                                  AS [Used MB],

    -- Free
    CAST(SUM(df.size) * 8.0 / 1024
         - lu.used_log_space_in_bytes / 1048576.0
         AS decimal(18,2))                                  AS [Free MB],

    -- Percent used
    CAST(lu.used_log_space_in_percent AS decimal(5,1))      AS [Used %],

    -- Why can't log be reused
    d.log_reuse_wait_desc                                   AS [Log Reuse Wait],

    -- Recovery model
    d.recovery_model_desc                                   AS [Recovery Model],

    -- Autogrowth (first log file)
    CASE
        WHEN fg.is_percent_growth = 1
            THEN CONCAT(fg.growth, '%')
        WHEN fg.growth = 0
            THEN 'DISABLED!'
        ELSE CONCAT(CAST(fg.growth AS bigint) * 8 / 1024, ' MB')
    END                                                     AS [Autogrowth],

    -- Max size
    CASE
        WHEN fg.max_size = -1        THEN 'Unlimited'
        WHEN fg.max_size = 268435456 THEN '2 TB'
        ELSE CAST(CAST(fg.max_size AS bigint) * 8 / 1024 AS varchar(20)) + ' MB'
    END                                                     AS [Max Size MB],

    -- VLF count (high = bad performance)
    vlf.vlf_count                                           AS [VLF Count]

FROM sys.dm_db_log_space_usage AS lu

CROSS JOIN sys.databases AS d

CROSS JOIN (
    SELECT
        COUNT(*) AS vlf_count
    FROM sys.dm_db_log_info(DB_ID())
) AS vlf

CROSS APPLY (
    SELECT TOP (1)
        f.is_percent_growth,
        f.growth,
        f.max_size
    FROM sys.database_files AS f
    WHERE f.type = 1
    ORDER BY f.file_id
) AS fg

CROSS JOIN sys.database_files AS df

WHERE d.database_id = DB_ID()
  AND df.type = 1    -- log files only

GROUP BY
    lu.used_log_space_in_bytes,
    lu.used_log_space_in_percent,
    d.log_reuse_wait_desc,
    d.recovery_model_desc,
    fg.is_percent_growth,
    fg.growth,
    fg.max_size,
    vlf.vlf_count;