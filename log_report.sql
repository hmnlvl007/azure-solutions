SET NOCOUNT ON;

DECLARE @DbName sysname = N'DB';   -- change or set NULL for all DBs

SELECT
    d.name                                        AS [Database],
    FORMAT(li.cntr_value / 1024.0, 'N2')          AS [Log Size MB],
    FORMAT(lu.cntr_value / 1024.0, 'N2')          AS [Used MB],
    FORMAT(lu.cntr_value * 100.0
           / NULLIF(li.cntr_value, 0), 'N1') + '%' AS [Used %],
    FORMAT((li.cntr_value - lu.cntr_value)
           / 1024.0, 'N2')                        AS [Free MB],
    d.log_reuse_wait_desc                          AS [Log Reuse Wait],
    d.recovery_model_desc                          AS [Recovery Model],
    mf.growth_desc                                 AS [Autogrowth],
    FORMAT(mf.max_size_mb, 'N0')                   AS [Max Size MB]
FROM sys.databases AS d
CROSS APPLY (
    SELECT cntr_value
    FROM sys.dm_os_performance_counters
    WHERE counter_name = 'Log File(s) Size (KB)'
      AND instance_name = d.name
) AS li
CROSS APPLY (
    SELECT cntr_value
    FROM sys.dm_os_performance_counters
    WHERE counter_name = 'Log File(s) Used Size (KB)'
      AND instance_name = d.name
) AS lu
CROSS APPLY (
    SELECT
        CASE
            WHEN f.is_percent_growth = 1
                THEN CONCAT(f.growth, '% ')
            ELSE CONCAT(f.growth * 8 / 1024, ' MB ')
        END
        + CASE WHEN f.is_percent_growth = 0 AND f.growth = 0
               THEN '(DISABLED!)' ELSE '' END   AS growth_desc,
        CASE WHEN f.max_size = -1 THEN -1
             ELSE f.max_size * 8 / 1024
        END                                       AS max_size_mb
    FROM sys.master_files AS f
    WHERE f.database_id = d.database_id
      AND f.type = 1   -- LOG
) AS mf
WHERE @DbName IS NULL OR d.name = @DbName
ORDER BY lu.cntr_value * 100.0 / NULLIF(li.cntr_value, 0) DESC;