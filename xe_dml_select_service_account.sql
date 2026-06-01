/*
==============================================================================
XE Session - DML + SELECT Capture for a Single Service Account
==============================================================================
Purpose:  Capture INSERT, UPDATE, DELETE, and SELECT statements executed by
          one specific service account login.

Sections:
  STEP 0 - Set the target service account and file path variables.
  STEP 1 - Create the XE session (run once; stops/drops first if it exists).
  STEP 2 - Start / Stop the session.
  STEP 3 - Read captured events from the .xel file (fast, live file only).
  STEP 4 - Read captured events with a time-window filter (historical).
  STEP 5 - Drop the session when no longer needed.

Requires: ALTER ANY EVENT SESSION
          VIEW SERVER STATE (to read DMVs and fn_xe_file_target_read_file)

Notes:
  - Uses sql_statement_completed so each individual statement is captured,
    not just the batch boundary.
  - The session predicate filters events server-side so only rows for the
    target login reach the file; overhead on other connections is negligible.
  - Adjust @xe_file_path to a directory that SQL Server service account can
    write to.  The directory must already exist.
  - max_file_size = 50 MB, max_rollover_files = 10 (change as needed).
==============================================================================
*/

-- ============================================================
-- STEP 0 - Configuration: set these two values before running
--          any other step.
-- ============================================================

-- Service account login to monitor (use DOMAIN\login or just login name):
DECLARE @target_login  sysname       = N'DOMAIN\svc_accountname';   -- ← CHANGE ME

-- Folder path for the .xel files (trailing backslash required):
DECLARE @xe_file_path  nvarchar(260) = N'D:\SQLXE\DML_SvcAccount';  -- ← CHANGE ME
-- SQL Server appends _0_<timestamp>.xel automatically; do not include extension.

-- ============================================================
-- STEP 1 - Create the XE session.
--          Idempotent: drops and recreates if it already exists.
-- ============================================================

IF EXISTS (
    SELECT 1
    FROM   sys.server_event_sessions
    WHERE  name = N'XE_DML_ServiceAccount'
)
BEGIN
    -- Stop the session if it is currently running before dropping.
    IF EXISTS (
        SELECT 1
        FROM   sys.dm_xe_sessions
        WHERE  name = N'XE_DML_ServiceAccount'
    )
        ALTER EVENT SESSION [XE_DML_ServiceAccount] ON SERVER STATE = STOP;

    DROP EVENT SESSION [XE_DML_ServiceAccount] ON SERVER;
END;
GO

/*
  NOTE: Variables from STEP 0 do not survive the GO batch boundary.
  Edit the three literal values marked ← CHANGE ME inside this CREATE
  statement to match what you set in STEP 0.
*/

CREATE EVENT SESSION [XE_DML_ServiceAccount] ON SERVER

    -- Capture every individual SQL statement that completes.
    -- The predicate filters server-side: only the target login passes through.
    ADD EVENT sqlserver.sql_statement_completed (
        ACTION (
            sqlserver.server_principal_name,   -- login name
            sqlserver.database_name,
            sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.session_id,
            sqlserver.sql_text,                -- full batch text (context)
            sqlserver.transaction_id
        )
        WHERE (
            -- Filter to the target service account (case-insensitive on most servers).
            sqlserver.server_principal_name = N'DOMAIN\svc_accountname'  -- ← CHANGE ME (same as @target_login)

            -- Restrict to DML and SELECT keywords in the statement text.
            -- sql_statement_completed exposes the statement as the "statement" data field.
            AND (
                    sqlserver.like_i_sql_unicode_string(N'%INSERT%')
                 OR sqlserver.like_i_sql_unicode_string(N'%UPDATE%')
                 OR sqlserver.like_i_sql_unicode_string(N'%DELETE%')
                 OR sqlserver.like_i_sql_unicode_string(N'%SELECT%')
            )
        )
    ),

    -- Also capture RPC calls (sp_executesql, ODBC parameterised queries, etc.)
    -- which bypass sql_statement_completed in some driver configurations.
    ADD EVENT sqlserver.rpc_completed (
        ACTION (
            sqlserver.server_principal_name,
            sqlserver.database_name,
            sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.session_id,
            sqlserver.sql_text,
            sqlserver.transaction_id
        )
        WHERE (
            sqlserver.server_principal_name = N'DOMAIN\svc_accountname'  -- ← CHANGE ME
            AND (
                    sqlserver.like_i_sql_unicode_string(N'%INSERT%')
                 OR sqlserver.like_i_sql_unicode_string(N'%UPDATE%')
                 OR sqlserver.like_i_sql_unicode_string(N'%DELETE%')
                 OR sqlserver.like_i_sql_unicode_string(N'%SELECT%')
            )
        )
    )

    ADD TARGET package0.event_file (
        SET filename            = N'D:\SQLXE\DML_SvcAccount',          -- ← CHANGE ME (same as @xe_file_path)
            max_file_size       = 50,    -- MB per file
            max_rollover_files  = 10     -- keep last 10 files (500 MB cap)
    )

    WITH (
        MAX_MEMORY            = 8192 KB,
        EVENT_RETENTION_MODE  = ALLOW_SINGLE_EVENT_LOSS,
        MAX_DISPATCH_LATENCY  = 5 SECONDS,
        STARTUP_STATE         = OFF     -- set to ON to auto-start after service restart
    );
GO

-- ============================================================
-- STEP 2 - Start / Stop the session (run the block you need).
-- ============================================================

-- Start:
ALTER EVENT SESSION [XE_DML_ServiceAccount] ON SERVER STATE = START;
GO

-- Stop (comment out START above and uncomment this when done collecting):
-- ALTER EVENT SESSION [XE_DML_ServiceAccount] ON SERVER STATE = STOP;
-- GO

-- ============================================================
-- STEP 3 - FAST READ: live file only (most recent events).
--   1. Run STEP 0 query below to get the current live file path.
--   2. Paste it into @live_file.
--   3. Highlight and run this block.
-- ============================================================

-- Find the live file path:
SELECT
    s.name                                                                AS session_name,
    CAST(st.target_data AS xml)
        .value('(EventFileTarget/File/@name)[1]', 'nvarchar(260)')       AS live_file_path
FROM sys.dm_xe_sessions        AS s
JOIN sys.dm_xe_session_targets AS st ON st.event_session_address = s.address
WHERE s.name  = N'XE_DML_ServiceAccount'
  AND st.name = N'event_file';
GO

-- Paste the live_file_path value from the query above:
DECLARE @live_file nvarchar(260) = N'D:\SQLXE\DML_SvcAccount_0_REPLACE.xel';  -- ← CHANGE ME

SELECT
    x.xd.value('(event/@timestamp)[1]',                                    'datetime2(3)')   AS event_time_utc,
    x.xd.value('(event/@name)[1]',                                         'varchar(60)')    AS event_name,
    @@SERVERNAME                                                                              AS server_name,
    x.xd.value('(event/action[@name="database_name"]/value)[1]',           'sysname')        AS database_name,
    x.xd.value('(event/action[@name="server_principal_name"]/value)[1]',   'sysname')        AS login_name,
    x.xd.value('(event/action[@name="client_app_name"]/value)[1]',         'nvarchar(128)')  AS client_app,
    x.xd.value('(event/action[@name="client_hostname"]/value)[1]',         'nvarchar(128)')  AS client_host,
    x.xd.value('(event/action[@name="session_id"]/value)[1]',              'int')            AS session_id,
    x.xd.value('(event/action[@name="transaction_id"]/value)[1]',          'bigint')         AS transaction_id,
    -- sql_statement_completed stores the statement in the "statement" data field.
    -- rpc_completed stores it in "statement" as well (procedure call text).
    x.xd.value('(event/data[@name="statement"]/value)[1]',                 'nvarchar(max)')  AS statement_text,
    -- Duration in microseconds (divide by 1000 for ms):
    x.xd.value('(event/data[@name="duration"]/value)[1]',                  'bigint')         AS duration_us,
    x.xd.value('(event/data[@name="logical_reads"]/value)[1]',             'bigint')         AS logical_reads,
    x.xd.value('(event/data[@name="writes"]/value)[1]',                    'bigint')         AS writes,
    x.xd.value('(event/data[@name="row_count"]/value)[1]',                 'bigint')         AS row_count,
    f.file_name                                                                               AS xe_file_name
FROM sys.fn_xe_file_target_read_file(@live_file, NULL, NULL, NULL) AS f
CROSS APPLY (SELECT TRY_CAST(f.event_data AS xml)) AS x(xd)
WHERE x.xd IS NOT NULL
ORDER BY
    x.xd.value('(event/@timestamp)[1]', 'datetime2(3)') DESC;
GO

-- ============================================================
-- STEP 4 - HISTORICAL READ: time-window filter across files.
--   Replace the filename in the FROM clause with a wildcard
--   pattern ONLY after confirming file count via:
--   EXEC xp_cmdshell 'dir /b /o-d "D:\SQLXE\DML_SvcAccount*.xel"';
-- ============================================================

DECLARE @start_time datetime2(3) = DATEADD(hour, -24, SYSUTCDATETIME());
DECLARE @end_time   datetime2(3) = SYSUTCDATETIME();

IF OBJECT_ID('tempdb..#dml_events') IS NOT NULL DROP TABLE #dml_events;

SELECT
    x.xd.value('(event/@timestamp)[1]',                                    'datetime2(3)')   AS event_time_utc,
    x.xd.value('(event/@name)[1]',                                         'varchar(60)')    AS event_name,
    @@SERVERNAME                                                                              AS server_name,
    x.xd.value('(event/action[@name="database_name"]/value)[1]',           'sysname')        AS database_name,
    x.xd.value('(event/action[@name="server_principal_name"]/value)[1]',   'sysname')        AS login_name,
    x.xd.value('(event/action[@name="client_app_name"]/value)[1]',         'nvarchar(128)')  AS client_app,
    x.xd.value('(event/action[@name="client_hostname"]/value)[1]',         'nvarchar(128)')  AS client_host,
    x.xd.value('(event/action[@name="session_id"]/value)[1]',              'int')            AS session_id,
    x.xd.value('(event/action[@name="transaction_id"]/value)[1]',          'bigint')         AS transaction_id,
    x.xd.value('(event/data[@name="statement"]/value)[1]',                 'nvarchar(max)')  AS statement_text,
    x.xd.value('(event/data[@name="duration"]/value)[1]',                  'bigint')         AS duration_us,
    x.xd.value('(event/data[@name="logical_reads"]/value)[1]',             'bigint')         AS logical_reads,
    x.xd.value('(event/data[@name="writes"]/value)[1]',                    'bigint')         AS writes,
    x.xd.value('(event/data[@name="row_count"]/value)[1]',                 'bigint')         AS row_count,
    f.file_name                                                                               AS xe_file_name
INTO #dml_events
FROM (
    -- !! Replace with the specific file(s) or wildcard for your time window !!
    -- Use wildcard only after confirming file count with xp_cmdshell above.
    SELECT event_data, file_name, timestamp_utc
    FROM sys.fn_xe_file_target_read_file(
        N'D:\SQLXE\DML_SvcAccount*.xel',  -- ← CHANGE ME
        NULL, NULL, NULL
    )
    -- UNION ALL
    -- SELECT event_data, file_name, timestamp_utc
    -- FROM sys.fn_xe_file_target_read_file(N'D:\SQLXE\DML_SvcAccount_0_SECOND.xel', NULL, NULL, NULL)
) AS f
CROSS APPLY (SELECT TRY_CAST(f.event_data AS xml)) AS x(xd)
WHERE x.xd IS NOT NULL
  AND f.timestamp_utc >= @start_time
  AND f.timestamp_utc <  @end_time;

CREATE CLUSTERED INDEX cx_dml_events ON #dml_events (event_time_utc DESC);

-- Summary: statement type breakdown
SELECT
    -- Classify the statement type by keyword presence in the text.
    CASE
        WHEN statement_text LIKE '%INSERT%' THEN 'INSERT'
        WHEN statement_text LIKE '%UPDATE%' THEN 'UPDATE'
        WHEN statement_text LIKE '%DELETE%' THEN 'DELETE'
        WHEN statement_text LIKE '%SELECT%' THEN 'SELECT'
        ELSE 'OTHER'
    END                        AS statement_type,
    COUNT(*)                   AS event_count,
    SUM(duration_us) / 1000    AS total_duration_ms,
    SUM(logical_reads)         AS total_logical_reads,
    SUM(writes)                AS total_writes,
    SUM(row_count)             AS total_rows_affected
FROM #dml_events
GROUP BY
    CASE
        WHEN statement_text LIKE '%INSERT%' THEN 'INSERT'
        WHEN statement_text LIKE '%UPDATE%' THEN 'UPDATE'
        WHEN statement_text LIKE '%DELETE%' THEN 'DELETE'
        WHEN statement_text LIKE '%SELECT%' THEN 'SELECT'
        ELSE 'OTHER'
    END
ORDER BY event_count DESC;

-- Detail: all captured events ordered by time
SELECT
    event_time_utc,
    event_name,
    database_name,
    login_name,
    client_app,
    client_host,
    session_id,
    transaction_id,
    duration_us,
    logical_reads,
    writes,
    row_count,
    LEFT(statement_text, 500)  AS statement_preview,   -- truncate for readability
    xe_file_name
FROM #dml_events
ORDER BY event_time_utc DESC;

DROP TABLE #dml_events;
GO

-- ============================================================
-- STEP 5 - Tear down: stop and drop the session when done.
-- ============================================================

-- ALTER EVENT SESSION [XE_DML_ServiceAccount] ON SERVER STATE = STOP;
-- DROP EVENT SESSION  [XE_DML_ServiceAccount] ON SERVER;
-- GO
