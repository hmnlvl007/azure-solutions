/*
==============================================================================
SQL Server User Activity Audit - SELECT Direct from XEL Files
==============================================================================
Purpose:  Read login/logout events straight from Extended Events .xel files.
          Uses a #temp table to force a single XML-shred pass over the .xel
          files; CTEs are inlined by the optimizer and cause repeated parsing.

Usage:    Change the file path in fn_xe_file_target_read_file if needed.
          Add WHERE clauses on the final SELECT to filter by user, date, etc.
          Narrow @start_time / @end_time to limit how many .xel files are read.

Requires: VIEW SERVER STATE
==============================================================================
*/

-- ── 1. Scope the time window you care about ──────────────────────────────
--    Narrow this window as much as possible - it is the primary cost driver.
DECLARE @start_time datetime2(3) = DATEADD(day, -7, SYSUTCDATETIME());
DECLARE @end_time   datetime2(3) = SYSUTCDATETIME();

-- ── 2. Shred XML exactly once and park results in a temp table ────────────
--    KEY: filter on timestamp_utc (a native bigint column on the TVF, SQL 2019+)
--    BEFORE casting event_data to xml.  This skips XML parsing entirely for
--    rows outside the window, which is where virtually all the time was spent.
IF OBJECT_ID('tempdb..#xe_events') IS NOT NULL DROP TABLE #xe_events;

SELECT
    x.xd.value('(event/@timestamp)[1]',                                  'datetime2(3)')  AS event_time_utc,
    x.xd.value('(event/@name)[1]',                                       'varchar(60)')   AS event_name,
    @@SERVERNAME                                                                           AS server_instance_name,
    x.xd.value('(event/action[@name="database_name"]/value)[1]',         'sysname')       AS database_name,
    x.xd.value('(event/action[@name="server_principal_name"]/value)[1]', 'sysname')       AS server_principal_name,
    x.xd.value('(event/action[@name="client_app_name"]/value)[1]',       'nvarchar(128)') AS client_app_name,
    x.xd.value('(event/action[@name="client_hostname"]/value)[1]',       'nvarchar(128)') AS client_hostname,
    x.xd.value('(event/data[@name="client_ip"]/value)[1]',               'varchar(48)')   AS client_ip_address,
    x.xd.value('(event/action[@name="session_id"]/value)[1]',            'int')           AS session_id,
    x.xd.value('(event/data[@name="success"]/value)[1]',                 'varchar(5)')    AS success_raw,
    f.file_name                                                                            AS xe_file_name
INTO #xe_events
FROM (
    -- Pre-filter rows by the cheap timestamp_utc bigint column BEFORE XML parsing.
    -- timestamp_utc is microseconds since Unix epoch (UTC); convert our window to match.
    SELECT f2.event_data, f2.file_name
    FROM sys.fn_xe_file_target_read_file(N'D:\SQLXE\UserActivityAudit*.xel', NULL, NULL, NULL) AS f2
    WHERE f2.timestamp_utc >= DATEDIFF_BIG(MICROSECOND, '1970-01-01', @start_time)
      AND f2.timestamp_utc <  DATEDIFF_BIG(MICROSECOND, '1970-01-01', @end_time)
) AS f
CROSS APPLY (SELECT TRY_CAST(f.event_data AS xml)) AS x(xd)
WHERE x.xd IS NOT NULL;  -- discard any rows where CAST failed (corrupt/truncated events)

-- ── 3. Index the temp table before sorting ────────────────────────────────
CREATE CLUSTERED INDEX cx_xe_events_time ON #xe_events (event_time_utc DESC);

-- ── 4. Final SELECT - all columns are plain reads; no XML work here ───────
SELECT
    event_time_utc,
    event_name,
    server_instance_name,
    database_name,
    server_principal_name,
    client_app_name,
    client_hostname,
    client_ip_address,
    session_id,
    CASE
        WHEN event_name = 'login'
        THEN TRY_CAST(success_raw AS bit)
        ELSE NULL
    END          AS is_success,
    xe_file_name
FROM #xe_events
WHERE event_time_utc >= @start_time
  AND event_time_utc <  @end_time
ORDER BY
    event_time_utc DESC;

DROP TABLE #xe_events;
GO
