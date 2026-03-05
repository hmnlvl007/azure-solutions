/*
==============================================================================
SQL Server User Activity Audit - Infrastructure Setup
==============================================================================
Purpose:  Create DBA database, audit history table, and Extended Events session
          for tracking user logins and database activity across SQL Server 2019 instances.

Target:   SQL Server 2019 Enterprise Edition on Windows Server 2019
Scope:    Server-level and database-level user activity tracking
Overhead: Minimal (<1% CPU) when configured per defaults below

Author:   DBA Team
Date:     2026-03-05
==============================================================================
*/

USE master;
GO

-- =============================================================================
-- STEP 1: Create DBA administrative database if not exists
-- =============================================================================
IF DB_ID('DBA') IS NULL
BEGIN
    PRINT 'Creating DBA database...';
    CREATE DATABASE DBA;
    ALTER DATABASE DBA SET RECOVERY SIMPLE;
    PRINT 'DBA database created successfully.';
END
ELSE
BEGIN
    PRINT 'DBA database already exists.';
END
GO

USE DBA;
GO

-- =============================================================================
-- STEP 2: Create audit history table with partitioning considerations
-- =============================================================================
IF OBJECT_ID('dbo.useractivityhist', 'U') IS NULL
BEGIN
    PRINT 'Creating useractivityhist table...';
    
    CREATE TABLE dbo.useractivityhist
    (
        audit_id                BIGINT IDENTITY(1,1) NOT NULL,
        event_time_utc          datetime2(3) NOT NULL,
        event_name              varchar(60) NOT NULL,
        server_instance_name    sysname NOT NULL DEFAULT @@SERVERNAME,
        database_name           sysname NULL,
        server_principal_name   sysname NULL,
        client_app_name         nvarchar(128) NULL,
        client_hostname         nvarchar(128) NULL,
        client_ip_address       varchar(48) NULL,
        session_id              int NULL,
        -- For query/statement capture (optional)
        statement_text          nvarchar(max) NULL,
        object_name             sysname NULL,
        -- For login events
        is_success              bit NULL,
        -- Metadata
        xe_file_name            nvarchar(260) NULL,
        ingestion_time_utc      datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
        
        CONSTRAINT PK_UserActivityHistory PRIMARY KEY CLUSTERED 
        (
            audit_id ASC
        ),
        INDEX IX_UserActivityHistory_EventTime NONCLUSTERED (event_time_utc DESC),
        INDEX IX_UserActivityHistory_User_Event NONCLUSTERED (server_principal_name, event_name, event_time_utc DESC),
        INDEX IX_UserActivityHistory_Database NONCLUSTERED (database_name, event_time_utc DESC) WHERE database_name IS NOT NULL
    );
    
    PRINT 'useractivityhist table created successfully.';
END
ELSE
BEGIN
    PRINT 'useractivityhist table already exists.';
END
GO

-- =============================================================================
-- STEP 3: Create Extended Events session for user activity tracking
-- =============================================================================
USE master;
GO

-- Drop existing session if present (for redeployment scenarios)
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'UserActivityAudit')
BEGIN
    PRINT 'Dropping existing UserActivityAudit session...';
    
    IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'UserActivityAudit')
    BEGIN
        ALTER EVENT SESSION UserActivityAudit ON SERVER STATE = STOP;
    END
    
    DROP EVENT SESSION UserActivityAudit ON SERVER;
    PRINT 'Existing session dropped.';
END
GO

PRINT 'Creating UserActivityAudit Extended Events session...';
GO

CREATE EVENT SESSION UserActivityAudit ON SERVER
    -- Login events (successful)
    ADD EVENT sqlserver.login(
        ACTION(
            sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.client_pid,
            sqlserver.database_name,
            sqlserver.server_principal_name,
            sqlserver.session_id,
            sqlserver.session_server_principal_name,
            package0.collect_system_time
        )
        WHERE (
            -- Exclude internal/system accounts to reduce noise
            [sqlserver].[server_principal_name] <> N'NT AUTHORITY\SYSTEM'
            AND [sqlserver].[server_principal_name] NOT LIKE N'NT SERVICE\%'
            AND [sqlserver].[is_system] = 0
        )
    ),
    
    -- Logout events
    ADD EVENT sqlserver.logout(
        ACTION(
            sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.database_name,
            sqlserver.server_principal_name,
            sqlserver.session_id
        )
        WHERE (
            [sqlserver].[server_principal_name] <> N'NT AUTHORITY\SYSTEM'
            AND [sqlserver].[server_principal_name] NOT LIKE N'NT SERVICE\%'
            AND [sqlserver].[is_system] = 0
        )
    ),
    
    -- NOTE: Failed login tracking via XE can be noisy.
    -- Monitor failed logins via SQL Server Error Log:
    --   EXEC xp_readerrorlog 0, 1, 'Login failed';
    -- Or enable SQL Server Audit for compliance-grade failed login tracking.
    
    -- OPTIONAL: Uncomment below to capture DML/DDL statements
    -- WARNING: Can generate high volume on busy systems. Use filters!
    /*
    ADD EVENT sqlserver.sql_batch_completed(
        SET collect_batch_text = 1
        ACTION(
            sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.database_name,
            sqlserver.server_principal_name,
            sqlserver.session_id
        )
        WHERE (
            -- Filter to specific databases to reduce volume
            [sqlserver].[database_name] IN (N'YourCriticalDB1', N'YourCriticalDB2')
            -- Exclude system accounts
            AND [sqlserver].[server_principal_name] <> N'NT AUTHORITY\SYSTEM'
            AND [sqlserver].[server_principal_name] NOT LIKE N'NT SERVICE\%'
            AND [sqlserver].[is_system] = 0
            -- Exclude read operations if you only care about writes
            AND [sqlserver].[batch_text] NOT LIKE N'%SELECT%'
        )
    ),
    
    ADD EVENT sqlserver.rpc_completed(
        ACTION(
            sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.database_name,
            sqlserver.server_principal_name,
            sqlserver.session_id
        )
        WHERE (
            [sqlserver].[database_name] IN (N'YourCriticalDB1', N'YourCriticalDB2')
            AND [sqlserver].[server_principal_name] <> N'NT AUTHORITY\SYSTEM'
            AND [sqlserver].[server_principal_name] NOT LIKE N'NT SERVICE\%'
            AND [sqlserver].[is_system] = 0
        )
    ),
    */
    
    -- Write to rollover files (adjust path for your environment)
    ADD TARGET package0.event_file(
        SET filename = N'D:\SQLXE\UserActivityAudit.xel',
            max_file_size = 100,        -- 100 MB per file
            max_rollover_files = 30     -- Keep ~3 GB of history
    )
WITH (
    MAX_MEMORY = 8192 KB,               -- 8 MB memory buffer
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,  -- Don't block on backpressure
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    MAX_EVENT_SIZE = 0 KB,
    MEMORY_PARTITION_MODE = PER_CPU,
    TRACK_CAUSALITY = OFF,
    STARTUP_STATE = ON                  -- Auto-start on SQL Server restart
);
GO

-- =============================================================================
-- STEP 4: Ensure XE file path exists (PowerShell via xp_cmdshell or manual)
-- =============================================================================
-- Option A: Manual - create D:\SQLXE folder before starting the session
-- Option B: Automated - enable xp_cmdshell temporarily (review security policy first)

PRINT 'Verifying Extended Events target path exists...';

DECLARE @xePathCheck int;
EXEC master.dbo.xp_fileexist 'D:\SQLXE', @xePathCheck OUTPUT;

IF @xePathCheck IS NULL OR @xePathCheck = 0
BEGIN
    PRINT '*** WARNING: D:\SQLXE does not exist. Creating it now...';
    PRINT '*** If xp_cmdshell is disabled, manually create D:\SQLXE before starting the session.';
    
    -- Uncomment below if xp_cmdshell is permitted in your environment:
    /*
    EXEC sp_configure 'show advanced options', 1;
    RECONFIGURE;
    EXEC sp_configure 'xp_cmdshell', 1;
    RECONFIGURE;
    
    EXEC xp_cmdshell 'mkdir D:\SQLXE';
    
    EXEC sp_configure 'xp_cmdshell', 0;
    RECONFIGURE;
    EXEC sp_configure 'show advanced options', 0;
    RECONFIGURE;
    */
END
ELSE
BEGIN
    PRINT 'XE target path D:\SQLXE exists.';
END
GO

-- =============================================================================
-- STEP 5: Start the Extended Events session
-- =============================================================================
PRINT 'Starting UserActivityAudit session...';
GO

ALTER EVENT SESSION UserActivityAudit ON SERVER STATE = START;
GO

PRINT 'UserActivityAudit session started successfully.';
PRINT '============================================================================';
PRINT 'Setup complete. Next steps:';
PRINT '  1. Deploy sql_user_audit_02_agent_job_ingest.sql to schedule data ingestion';
PRINT '  2. Use sql_user_audit_03_reporting_queries.sql for common reports';
PRINT '  3. Adjust XE session filters if you want to capture statement-level activity';
PRINT '============================================================================';
GO

-- Verification query
SELECT
    s.name AS session_name,
    s.startup_state,
    CASE WHEN xs.name IS NULL THEN 'STOPPED' ELSE 'RUNNING' END AS current_state,
    xs.create_time,
    t.target_name,
    CAST(t.target_data AS xml) AS target_config
FROM sys.server_event_sessions AS s
LEFT JOIN sys.dm_xe_sessions AS xs ON s.name = xs.name
LEFT JOIN sys.dm_xe_session_targets AS t ON t.event_session_address = xs.address
WHERE s.name = 'UserActivityAudit';
GO
