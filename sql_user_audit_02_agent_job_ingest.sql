/*
==============================================================================
SQL Server User Activity Audit - Ingestion Job
==============================================================================
Purpose:  Create SQL Agent job to periodically ingest Extended Events data
          from .xel files into DBA.dbo.UserActivityHistory table.

Schedule: Every 15 minutes (adjustable)
Target:   SQL Server 2019 Enterprise Edition
==============================================================================
*/

USE msdb;
GO

-- Drop existing job if present (for redeployment)
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - Ingest User Activity Audit')
BEGIN
    PRINT 'Dropping existing job...';
    EXEC msdb.dbo.sp_delete_job @job_name = N'DBA - Ingest User Activity Audit';
END
GO

PRINT 'Creating SQL Agent job for audit ingestion...';
GO

DECLARE @ReturnCode INT = 0;
DECLARE @jobId BINARY(16);

-- Create job category if not exists
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories WHERE name = N'DBA Maintenance' AND category_class = 1)
BEGIN
    EXEC msdb.dbo.sp_add_category
        @class = N'JOB',
        @type = N'LOCAL',
        @name = N'DBA Maintenance';
END

-- Create the job
EXEC @ReturnCode = msdb.dbo.sp_add_job
    @job_name = N'DBA - Ingest User Activity Audit',
    @enabled = 1,
    @notify_level_eventlog = 2,
    @notify_level_email = 2,
    @notify_level_page = 0,
    @delete_level = 0,
    @description = N'Ingests Extended Events user activity data from .xel files into DBA.dbo.UserActivityHistory table for historical reporting.',
    @category_name = N'DBA Maintenance',
    @owner_login_name = N'sa',
    @job_id = @jobId OUTPUT;

IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

-- Job step: Ingest XE data
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId,
    @step_name = N'Ingest XE Files to DBA Table',
    @step_id = 1,
    @cmdexec_success_code = 0,
    @on_success_action = 1,
    @on_fail_action = 2,
    @retry_attempts = 0,
    @retry_interval = 0,
    @os_run_priority = 0,
    @subsystem = N'TSQL',
    @command = N'
SET NOCOUNT ON;

DECLARE @XEFilePath nvarchar(260) = N''D:\SQLXE\UserActivityAudit*.xel'';
DECLARE @RowsInserted int = 0;

BEGIN TRY
    -- Use a temp table to deduplicate and stage data
    IF OBJECT_ID(''tempdb..#XEStaging'') IS NOT NULL DROP TABLE #XEStaging;
    
    CREATE TABLE #XEStaging
    (
        event_time_utc       datetime2(3),
        event_name           varchar(60),
        database_name        sysname,
        server_principal_name sysname,
        client_app_name      nvarchar(128),
        client_hostname      nvarchar(128),
        client_ip_address    varchar(48),
        session_id           int,
        statement_text       nvarchar(max),
        object_name          sysname,
        is_success           bit,
        xe_file_name         nvarchar(260)
    );

    -- Read XE files and extract relevant fields
    INSERT INTO #XEStaging
    (
        event_time_utc,
        event_name,
        database_name,
        server_principal_name,
        client_app_name,
        client_hostname,
        client_ip_address,
        session_id,
        statement_text,
        object_name,
        is_success,
        xe_file_name
    )
    SELECT
        event_data.value(''(event/@timestamp)[1]'', ''datetime2(3)'') AS event_time_utc,
        event_data.value(''(event/@name)[1]'', ''varchar(60)'') AS event_name,
        event_data.value(''(event/action[@name="database_name"]/value)[1]'', ''sysname'') AS database_name,
        event_data.value(''(event/action[@name="server_principal_name"]/value)[1]'', ''sysname'') AS server_principal_name,
        event_data.value(''(event/action[@name="client_app_name"]/value)[1]'', ''nvarchar(128)'') AS client_app_name,
        event_data.value(''(event/action[@name="client_hostname"]/value)[1]'', ''nvarchar(128)'') AS client_hostname,
        event_data.value(''(event/data[@name="client_ip"]/value)[1]'', ''varchar(48)'') AS client_ip_address,
        event_data.value(''(event/action[@name="session_id"]/value)[1]'', ''int'') AS session_id,
        COALESCE(
            event_data.value(''(event/data[@name="batch_text"]/value)[1]'', ''nvarchar(max)''),
            event_data.value(''(event/data[@name="statement"]/value)[1]'', ''nvarchar(max)'')
        ) AS statement_text,
        event_data.value(''(event/data[@name="object_name"]/value)[1]'', ''sysname'') AS object_name,
        CASE
            WHEN event_data.value(''(event/@name)[1]'', ''varchar(60)'') = ''login'' THEN 1
            WHEN event_data.value(''(event/@name)[1]'', ''varchar(60)'') = ''errorlog_written'' THEN 0
            ELSE NULL
        END AS is_success,
        event_data.value(''(@name)[1]'', ''nvarchar(260)'') AS xe_file_name
    FROM
    (
        SELECT CAST(event_data AS xml) AS event_data
        FROM sys.fn_xe_file_target_read_file(@XEFilePath, NULL, NULL, NULL)
    ) AS xml_data;

    SET @RowsInserted = @@ROWCOUNT;

    -- Insert only new rows (avoid duplicates based on time/user/event)
    INSERT INTO DBA.dbo.UserActivityHistory
    (
        event_time_utc,
        event_name,
        database_name,
        server_principal_name,
        client_app_name,
        client_hostname,
        client_ip_address,
        session_id,
        statement_text,
        object_name,
        is_success,
        xe_file_name
    )
    SELECT
        s.event_time_utc,
        s.event_name,
        s.database_name,
        s.server_principal_name,
        s.client_app_name,
        s.client_hostname,
        s.client_ip_address,
        s.session_id,
        s.statement_text,
        s.object_name,
        s.is_success,
        s.xe_file_name
    FROM #XEStaging s
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM DBA.dbo.UserActivityHistory h
        WHERE h.event_time_utc = s.event_time_utc
          AND ISNULL(h.server_principal_name, '''') = ISNULL(s.server_principal_name, '''')
          AND h.event_name = s.event_name
          AND ISNULL(h.session_id, 0) = ISNULL(s.session_id, 0)
    );

    PRINT ''Ingested '' + CAST(@RowsInserted AS varchar(10)) + '' new rows into UserActivityHistory.'';

END TRY
BEGIN CATCH
    DECLARE @ErrorMessage nvarchar(4000) = ERROR_MESSAGE();
    DECLARE @ErrorSeverity int = ERROR_SEVERITY();
    DECLARE @ErrorState int = ERROR_STATE();
    
    RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    THROW;
END CATCH;
',
    @database_name = N'master',
    @flags = 4; -- Include step output in job history

IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

-- Create schedule: Every 15 minutes
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule
    @job_id = @jobId,
    @name = N'Every 15 Minutes',
    @enabled = 1,
    @freq_type = 4,             -- Daily
    @freq_interval = 1,         -- Every day
    @freq_subday_type = 4,      -- Minutes
    @freq_subday_interval = 15, -- Every 15 minutes
    @freq_relative_interval = 0,
    @freq_recurrence_factor = 0,
    @active_start_date = 20260305,
    @active_end_date = 99991231,
    @active_start_time = 0,
    @active_end_time = 235959;

IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

-- Assign job to local server
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver
    @job_id = @jobId,
    @server_name = N'(local)';

IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;

COMMIT TRANSACTION;
GOTO EndSave;

QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION;

EndSave:

PRINT 'SQL Agent job created successfully.';
PRINT 'Job: DBA - Ingest User Activity Audit';
PRINT 'Schedule: Every 15 minutes';
GO
