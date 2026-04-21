/*
==============================================================================
SQL Server User Activity Audit - SELECT Direct from XEL Files
==============================================================================
Purpose:  Read login/logout events straight from Extended Events .xel files.

Usage:    Run STEP 0 first to check file count/sizes.
          For recent data use STEP A (reads only the live file - fast).
          For historical data use STEP B (targeted file list - controlled cost).

Requires: VIEW SERVER STATE
          xp_cmdshell enabled for STEP 0 file listing (or check via Explorer)
==============================================================================
*/

/* ============================================================
   STEP 0 - DIAGNOSTIC: how many .xel files exist and how big?
   Run this first so you know what you're dealing with.
   ============================================================
EXEC xp_cmdshell 'dir /s /a-d "D:\SQLXE\UserActivityAudit*.xel" | find /i ".xel"';
*/

/* ============================================================
   STEP A - FAST: read only the currently active XEL file.
   The live session target holds only the latest rollover file.
   Safe to run at any time; returns recent events in seconds.
   ============================================================
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
    CASE
        WHEN x.xd.value('(event/@name)[1]', 'varchar(60)') = 'login'
        THEN TRY_CAST(x.xd.value('(event/data[@name="success"]/value)[1]', 'varchar(5)') AS bit)
        ELSE NULL
    END                                                                                    AS is_success,
    t.target_data_filename                                                                 AS xe_file_name
FROM (
    -- Resolve the exact path of the current live .xel file from the session metadata.
    -- No wildcard = no scanning of old files.
    SELECT CAST(st.target_data AS xml)
            .value('(EventFileTarget/File/@name)[1]', 'nvarchar(260)') AS target_data_filename
    FROM sys.dm_xe_sessions        AS s
    JOIN sys.dm_xe_session_targets AS st ON st.event_session_address = s.address
    WHERE s.name  = 'UserActivityAudit'   -- match your XE session name exactly
      AND st.name = 'event_file'
) AS t
CROSS APPLY sys.fn_xe_file_target_read_file(t.target_data_filename, NULL, NULL, NULL) AS f
CROSS APPLY (SELECT TRY_CAST(f.event_data AS xml)) AS x(xd)
WHERE x.xd IS NOT NULL
ORDER BY
    x.xd.value('(event/@timestamp)[1]', 'datetime2(3)') DESC;
*/

/* ============================================================
   STEP B - HISTORICAL: read a specific set of files only.
   Replace the filenames below with the files you actually need
   (identified from STEP 0 output).  Never use the wildcard
   against a large archive - it reads every file unconditionally.
   ============================================================ */

-- ── Time window ───────────────────────────────────────────────────────────
DECLARE @start_time datetime2(3) = DATEADD(day, -1, SYSUTCDATETIME());
DECLARE @end_time   datetime2(3) = SYSUTCDATETIME();

IF OBJECT_ID('tempdb..#xe_events') IS NOT NULL DROP TABLE #xe_events;

-- Replace the single filename below with each file you want to include.
-- Add more UNION ALL blocks for additional files as needed.
-- Using explicit filenames avoids scanning the entire archive.
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
    -- !! Replace with the specific file(s) covering your time window !!
    SELECT event_data, file_name, timestamp_utc
    FROM sys.fn_xe_file_target_read_file(N'D:\SQLXE\UserActivityAudit_0_133900000000000000.xel', NULL, NULL, NULL)
    -- UNION ALL
    -- SELECT event_data, file_name, timestamp_utc
    -- FROM sys.fn_xe_file_target_read_file(N'D:\SQLXE\UserActivityAudit_0_133890000000000000.xel', NULL, NULL, NULL)
) AS f
CROSS APPLY (SELECT TRY_CAST(f.event_data AS xml)) AS x(xd)
WHERE x.xd IS NOT NULL
  -- timestamp_utc is microseconds since Unix epoch; filter before XML parsing
  AND f.timestamp_utc >= DATEDIFF_BIG(MICROSECOND, '1970-01-01', @start_time)
  AND f.timestamp_utc <  DATEDIFF_BIG(MICROSECOND, '1970-01-01', @end_time);

CREATE CLUSTERED INDEX cx_xe_events_time ON #xe_events (event_time_utc DESC);

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
ORDER BY event_time_utc DESC;

DROP TABLE #xe_events;
GO
