<#
.SYNOPSIS
    Queries all SQL Server CMS registered servers to discover Availability Groups 
    and Replication configurations, then generates a detailed HTML report.

.DESCRIPTION
    Connects to a Central Management Server (CMS), enumerates all registered servers,
    and collects:
      - SQL Server version and edition
      - Availability Group details (replicas, databases, listeners, sync state)
      - Replication details (publishers, subscribers, publications, articles, schedules)
      - Change Data Capture (CDC) details (enabled databases, tracked tables, capture/cleanup jobs)
    Outputs a consolidated HTML report grouped by configuration type.

.PARAMETER CMSServer
    The name of the Central Management Server instance.
    Mutually exclusive with ExcelFilePath.

.PARAMETER ExcelFilePath
    Path to an Excel file (.xlsx) containing a list of server names.
    The file must have a column named 'ServerName' (or specify via -ServerColumn).
    Mutually exclusive with CMSServer.

.PARAMETER SheetName
    The worksheet name to read from the Excel file. Defaults to the first sheet.

.PARAMETER ServerColumn
    The column header in the Excel file that contains server names. Defaults to 'ServerName'.

.PARAMETER OutputPath
    Path for the HTML report file. Defaults to current directory.

.PARAMETER IncludeAllServers
    If set, includes servers with no AG or Replication in a separate section.

.EXAMPLE
    .\Get-CMSServerReport.ps1 -CMSServer "MyCMSServer" -OutputPath "C:\Reports"

.EXAMPLE
    .\Get-CMSServerReport.ps1 -ExcelFilePath "C:\Servers\ServerList.xlsx" -OutputPath "C:\Reports"

.EXAMPLE
    .\Get-CMSServerReport.ps1 -ExcelFilePath "C:\Servers\ServerList.xlsx" -SheetName "Production" -ServerColumn "SQLInstance"
#>

[CmdletBinding(DefaultParameterSetName = 'CMS')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'CMS')]
    [string]$CMSServer,

    [Parameter(Mandatory = $true, ParameterSetName = 'Excel')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ExcelFilePath,

    [Parameter(Mandatory = $false, ParameterSetName = 'Excel')]
    [string]$SheetName,

    [Parameter(Mandatory = $false, ParameterSetName = 'Excel')]
    [string]$ServerColumn = 'ServerName',

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Get-Location).Path,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeAllServers
)

#Requires -Modules SqlServer

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Execute a query against a server with error handling
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-SqlQuerySafe {
    param(
        [string]$ServerInstance,
        [string]$Query,
        [string]$Database = "master",
        [int]$QueryTimeout = 30
    )
    try {
        Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database `
                      -Query $Query -QueryTimeout $QueryTimeout `
                      -TrustServerCertificate -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to query [$ServerInstance]: $_"
        return $null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Get all registered servers from CMS
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  SQL Server – Availability Group & Replication Report         " -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if ($PSCmdlet.ParameterSetName -eq 'Excel') {
    # ── Load servers from Excel file ──────────────────────────────────
    Write-Host "Reading server list from Excel: $ExcelFilePath ..." -ForegroundColor Yellow

    # Ensure ImportExcel module is available
    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        Write-Error "The ImportExcel module is required for Excel input. Install it with: Install-Module ImportExcel -Scope CurrentUser"
        exit 1
    }
    Import-Module ImportExcel -ErrorAction Stop

    $importParams = @{ Path = $ExcelFilePath }
    if ($SheetName) { $importParams['WorksheetName'] = $SheetName }

    try {
        $excelData = Import-Excel @importParams -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to read Excel file [$ExcelFilePath]: $_"
        exit 1
    }

    if ($ServerColumn -notin ($excelData[0].PSObject.Properties.Name)) {
        Write-Error "Column '$ServerColumn' not found in the Excel file. Available columns: $($excelData[0].PSObject.Properties.Name -join ', ')"
        exit 1
    }

    $registeredServers = $excelData | ForEach-Object { $_.$ServerColumn } |
                         Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                         Sort-Object -Unique

    $serverSource = "Excel file: $ExcelFilePath"
}
else {
    # ── Load servers from CMS ───────────────────────────────────────
    Write-Host "Connecting to CMS: $CMSServer ..." -ForegroundColor Yellow

    try {
        $registeredServers = Get-DbaCmsRegServer -SqlInstance $CMSServer -ErrorAction Stop |
                             Select-Object -ExpandProperty ServerName -Unique
    }
    catch {
        # Fallback: use the SqlServer module approach
        Write-Host "  dbatools not available, trying SqlServer module..." -ForegroundColor DarkYellow
        try {
            $provider = Get-ChildItem "SQLSERVER:\SQLRegistration\Central Management Server Group\$CMSServer" -Recurse -ErrorAction Stop |
                        Where-Object { $_.GetType().Name -eq 'RegisteredServer' }
            $registeredServers = $provider | ForEach-Object { $_.ServerName } | Sort-Object -Unique
        }
        catch {
            Write-Error "Could not retrieve registered servers from CMS [$CMSServer]. Ensure dbatools or SqlServer module is installed. Error: $_"
            exit 1
        }
    }

    $serverSource = "CMS: $CMSServer"
}

if (-not $registeredServers -or $registeredServers.Count -eq 0) {
    Write-Error "No servers found from $serverSource."
    exit 1
}

Write-Host "  Found $($registeredServers.Count) server(s) from $serverSource." -ForegroundColor Green
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# 2. Collect data from each server
# ─────────────────────────────────────────────────────────────────────────────

$allServerInfo       = @()
$allAGDetails        = @()
$allAGDatabases      = @()
$allAGListeners      = @()
$allPublications     = @()
$allArticles         = @()
$allSubscriptions    = @()
$allDistributors     = @()
$allReplSchedules    = @()
$allCDCDatabases     = @()
$allCDCTables        = @()
$allCDCJobs          = @()

$serverCount = 0

foreach ($server in $registeredServers) {
    $serverCount++
    Write-Host "[$serverCount/$($registeredServers.Count)] Querying $server ..." -ForegroundColor White

    # ── Server version & edition ──────────────────────────────────────────
    $versionQuery = @"
SELECT 
    SERVERPROPERTY('ServerName')        AS ServerName,
    SERVERPROPERTY('ProductVersion')    AS ProductVersion,
    SERVERPROPERTY('ProductLevel')      AS ProductLevel,
    SERVERPROPERTY('ProductMajorVersion') AS MajorVersion,
    SERVERPROPERTY('Edition')           AS Edition,
    SERVERPROPERTY('EngineEdition')     AS EngineEdition,
    SERVERPROPERTY('ProductUpdateLevel') AS UpdateLevel,
    SERVERPROPERTY('ProductUpdateReference') AS KBArticle,
    SERVERPROPERTY('MachineName')       AS MachineName,
    SERVERPROPERTY('IsClustered')       AS IsClustered,
    SERVERPROPERTY('IsHadrEnabled')     AS IsHadrEnabled,
    @@VERSION                           AS FullVersion
"@
    $verInfo = Invoke-SqlQuerySafe -ServerInstance $server -Query $versionQuery
    if (-not $verInfo) {
        Write-Warning "  Skipping $server (unreachable)."
        $allServerInfo += [PSCustomObject]@{
            ServerName     = $server
            ProductVersion = "UNREACHABLE"
            Edition        = "N/A"
            ProductLevel   = "N/A"
            UpdateLevel    = "N/A"
            IsClustered    = "N/A"
            IsHadrEnabled  = "N/A"
            HasAG          = $false
            HasReplication = $false
            HasCDC         = $false
        }
        continue
    }

    # ── Availability Groups ───────────────────────────────────────────────
    $hasAG = $false
    if ($verInfo.IsHadrEnabled -eq 1) {
        $agQuery = @"
SELECT 
    ag.name                          AS AGName,
    ag.group_id                      AS AGGroupId,
    ags.primary_replica              AS PrimaryReplica,
    ags.synchronization_health_desc  AS AGSyncHealth,
    ags.operational_state_desc       AS AGOperationalState,
    ar.replica_server_name           AS ReplicaServer,
    ar.availability_mode_desc        AS AvailabilityMode,
    ar.failover_mode_desc            AS FailoverMode,
    ar.endpoint_url                  AS EndpointUrl,
    ar.secondary_role_allow_connections_desc AS SecondaryConnections,
    ar.seeding_mode_desc             AS SeedingMode,
    ars.role_desc                    AS ReplicaRole,
    ars.connected_state_desc         AS ConnectedState,
    ars.synchronization_health_desc  AS ReplicaSyncHealth,
    ars.operational_state_desc       AS ReplicaOperationalState,
    ars.last_connect_error_description AS LastConnectError
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_group_states ags 
    ON ag.group_id = ags.group_id
JOIN sys.availability_replicas ar 
    ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars 
    ON ar.replica_id = ars.replica_id
ORDER BY ag.name, ar.replica_server_name
"@
        $agData = Invoke-SqlQuerySafe -ServerInstance $server -Query $agQuery
        if ($agData) {
            $hasAG = $true
            foreach ($row in $agData) {
                $allAGDetails += [PSCustomObject]@{
                    SourceServer        = $server
                    AGName              = $row.AGName
                    PrimaryReplica      = $row.PrimaryReplica
                    AGSyncHealth        = $row.AGSyncHealth
                    AGOperationalState  = $row.AGOperationalState
                    ReplicaServer       = $row.ReplicaServer
                    AvailabilityMode    = $row.AvailabilityMode
                    FailoverMode        = $row.FailoverMode
                    EndpointUrl         = $row.EndpointUrl
                    SecondaryConnections= $row.SecondaryConnections
                    SeedingMode         = $row.SeedingMode
                    ReplicaRole         = $row.ReplicaRole
                    ConnectedState      = $row.ConnectedState
                    ReplicaSyncHealth   = $row.ReplicaSyncHealth
                    ReplicaOpState      = $row.ReplicaOperationalState
                    LastConnectError    = $row.LastConnectError
                }
            }
        }

        # AG Databases
        $agDbQuery = @"
SELECT 
    ag.name                          AS AGName,
    d.name                           AS DatabaseName,
    drs.synchronization_state_desc   AS SyncState,
    drs.synchronization_health_desc  AS SyncHealth,
    drs.is_suspended                 AS IsSuspended,
    drs.suspend_reason_desc          AS SuspendReason,
    drs.log_send_queue_size          AS LogSendQueueKB,
    drs.redo_queue_size              AS RedoQueueKB,
    drs.last_hardened_lsn            AS LastHardenedLSN,
    drs.last_redone_time             AS LastRedoneTime,
    drs.last_sent_time               AS LastSentTime,
    ar.replica_server_name           AS ReplicaServer
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar 
    ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_database_replica_states drs 
    ON ar.replica_id = drs.replica_id
LEFT JOIN sys.databases d 
    ON drs.database_id = d.database_id
ORDER BY ag.name, d.name
"@
        $agDbData = Invoke-SqlQuerySafe -ServerInstance $server -Query $agDbQuery
        if ($agDbData) {
            foreach ($row in $agDbData) {
                $allAGDatabases += [PSCustomObject]@{
                    SourceServer    = $server
                    AGName          = $row.AGName
                    DatabaseName    = $row.DatabaseName
                    ReplicaServer   = $row.ReplicaServer
                    SyncState       = $row.SyncState
                    SyncHealth      = $row.SyncHealth
                    IsSuspended     = $row.IsSuspended
                    SuspendReason   = $row.SuspendReason
                    LogSendQueueKB  = $row.LogSendQueueKB
                    RedoQueueKB     = $row.RedoQueueKB
                    LastSentTime    = $row.LastSentTime
                    LastRedoneTime  = $row.LastRedoneTime
                }
            }
        }

        # AG Listeners
        $listenerQuery = @"
SELECT 
    ag.name                          AS AGName,
    agl.dns_name                     AS ListenerDNS,
    agl.port                         AS ListenerPort,
    agl.ip_configuration_string_from_cluster AS IPConfig,
    lip.ip_address                   AS IPAddress,
    lip.ip_subnet_mask               AS SubnetMask,
    lip.state_desc                   AS IPState
FROM sys.availability_groups ag
JOIN sys.availability_group_listeners agl 
    ON ag.group_id = agl.group_id
LEFT JOIN sys.availability_group_listener_ip_addresses lip 
    ON agl.listener_id = lip.listener_id
ORDER BY ag.name
"@
        $listenerData = Invoke-SqlQuerySafe -ServerInstance $server -Query $listenerQuery
        if ($listenerData) {
            foreach ($row in $listenerData) {
                $allAGListeners += [PSCustomObject]@{
                    SourceServer  = $server
                    AGName        = $row.AGName
                    ListenerDNS   = $row.ListenerDNS
                    ListenerPort  = $row.ListenerPort
                    IPAddress     = $row.IPAddress
                    SubnetMask    = $row.SubnetMask
                    IPState       = $row.IPState
                }
            }
        }
    }

    # ── Replication ───────────────────────────────────────────────────────
    $hasRepl = $false

    # Check if this server is a distributor
    $distQuery = @"
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'distribution')
BEGIN
    SELECT 
        SERVERPROPERTY('ServerName') AS DistributorServer,
        d.name AS DistributionDB,
        d.state_desc AS DBState
    FROM sys.databases d
    WHERE d.name LIKE 'distribution%'
END
"@
    $distData = Invoke-SqlQuerySafe -ServerInstance $server -Query $distQuery
    if ($distData) {
        foreach ($row in $distData) {
            $allDistributors += [PSCustomObject]@{
                ServerName      = $server
                DistributionDB  = $row.DistributionDB
                DBState         = $row.DBState
            }
        }
    }

    # Get publications (if this server is a publisher)
    $pubQuery = @"
DECLARE @hasRepl INT = 0;
IF EXISTS (
    SELECT 1 FROM sys.databases 
    WHERE is_published = 1 OR is_merge_published = 1 OR is_distributor = 1
)
SET @hasRepl = 1;

IF @hasRepl = 1
BEGIN
    -- Gather publications from each published database
    DECLARE @sql NVARCHAR(MAX) = '';
    SELECT @sql = @sql + '
    USE [' + name + '];
    IF EXISTS (SELECT 1 FROM sys.tables WHERE name = ''syspublications'')
    BEGIN
        SELECT 
            SERVERPROPERTY(''ServerName'')    AS PublisherServer,
            DB_NAME()                         AS PublisherDB,
            p.name                            AS PublicationName,
            p.description                     AS PublicationDesc,
            CASE p.repl_freq 
                WHEN 0 THEN ''Transactional'' 
                WHEN 1 THEN ''Snapshot'' 
                ELSE ''Unknown'' 
            END                               AS ReplicationType,
            CASE p.status 
                WHEN 0 THEN ''Inactive'' 
                WHEN 1 THEN ''Active'' 
                ELSE ''Unknown'' 
            END                               AS PublicationStatus,
            p.immediate_sync                  AS ImmediateSync,
            p.allow_push                      AS AllowPush,
            p.allow_pull                      AS AllowPull,
            p.independent_agent               AS IndependentAgent,
            p.retention                       AS RetentionPeriod
        FROM dbo.syspublications p;
    END
    '
    FROM sys.databases
    WHERE is_published = 1 OR is_merge_published = 1;

    EXEC sp_executesql @sql;
END
"@
    $pubData = Invoke-SqlQuerySafe -ServerInstance $server -Query $pubQuery
    if ($pubData) {
        $hasRepl = $true
        foreach ($row in $pubData) {
            $allPublications += [PSCustomObject]@{
                PublisherServer   = $row.PublisherServer
                PublisherDB       = $row.PublisherDB
                PublicationName   = $row.PublicationName
                PublicationDesc   = $row.PublicationDesc
                ReplicationType   = $row.ReplicationType
                PublicationStatus = $row.PublicationStatus
                ImmediateSync     = $row.ImmediateSync
                AllowPush         = $row.AllowPush
                AllowPull         = $row.AllowPull
                RetentionPeriod   = $row.RetentionPeriod
            }
        }
    }

    # Get articles for each published database
    $articleQuery = @"
DECLARE @sql NVARCHAR(MAX) = '';
SELECT @sql = @sql + '
USE [' + name + '];
IF EXISTS (SELECT 1 FROM sys.tables WHERE name = ''sysarticles'')
BEGIN
    SELECT 
        SERVERPROPERTY(''ServerName'')    AS PublisherServer,
        DB_NAME()                         AS PublisherDB,
        p.name                            AS PublicationName,
        a.name                            AS ArticleName,
        a.dest_table                      AS DestinationTable,
        a.dest_owner                      AS DestinationOwner,
        CASE a.type 
            WHEN 1  THEN ''Log-based''
            WHEN 3  THEN ''Log-based with manual filter''
            WHEN 5  THEN ''Log-based with manual view''
            WHEN 7  THEN ''Log-based with manual filter and view''
            WHEN 8  THEN ''Stored Procedure execution''
            WHEN 24 THEN ''Serializable SP execution''
            WHEN 32 THEN ''Stored Procedure (schema only)''
            WHEN 64 THEN ''View (schema only)''
            WHEN 128 THEN ''Function (schema only)''
            ELSE ''Type '' + CAST(a.type AS VARCHAR(10))
        END                               AS ArticleType
    FROM dbo.sysarticles a
    JOIN dbo.syspublications p ON a.pubid = p.pubid;
END
'
FROM sys.databases
WHERE is_published = 1 OR is_merge_published = 1;

IF LEN(@sql) > 0
    EXEC sp_executesql @sql;
"@
    $artData = Invoke-SqlQuerySafe -ServerInstance $server -Query $articleQuery
    if ($artData) {
        foreach ($row in $artData) {
            $allArticles += [PSCustomObject]@{
                PublisherServer   = $row.PublisherServer
                PublisherDB       = $row.PublisherDB
                PublicationName   = $row.PublicationName
                ArticleName       = $row.ArticleName
                DestinationTable  = $row.DestinationTable
                DestinationOwner  = $row.DestinationOwner
                ArticleType       = $row.ArticleType
            }
        }
    }

    # Get subscriptions
    $subQuery = @"
DECLARE @sql NVARCHAR(MAX) = '';
SELECT @sql = @sql + '
USE [' + name + '];
IF EXISTS (SELECT 1 FROM sys.tables WHERE name = ''syssubscriptions'') 
   AND EXISTS (SELECT 1 FROM sys.tables WHERE name = ''sysarticles'')
BEGIN
    SELECT 
        SERVERPROPERTY(''ServerName'')    AS PublisherServer,
        DB_NAME()                         AS PublisherDB,
        p.name                            AS PublicationName,
        s.srvname                         AS SubscriberServer,
        s.dest_db                         AS SubscriberDB,
        CASE s.subscription_type 
            WHEN 0 THEN ''Push'' 
            WHEN 1 THEN ''Pull'' 
            ELSE ''Unknown'' 
        END                               AS SubscriptionType,
        CASE s.status 
            WHEN 0 THEN ''Inactive'' 
            WHEN 1 THEN ''Subscribed'' 
            WHEN 2 THEN ''Active'' 
            ELSE ''Unknown'' 
        END                               AS SubscriptionStatus,
        s.sync_type                       AS SyncType
    FROM dbo.syssubscriptions s
    JOIN dbo.sysarticles a ON s.artid = a.artid
    JOIN dbo.syspublications p ON a.pubid = p.pubid
    WHERE s.srvname NOT IN (''virtual'', ''(unknown)'')
    GROUP BY p.name, s.srvname, s.dest_db, s.subscription_type, s.status, s.sync_type;
END
'
FROM sys.databases
WHERE is_published = 1 OR is_merge_published = 1;

IF LEN(@sql) > 0
    EXEC sp_executesql @sql;
"@
    $subData = Invoke-SqlQuerySafe -ServerInstance $server -Query $subQuery
    if ($subData) {
        $hasRepl = $true
        foreach ($row in $subData) {
            $allSubscriptions += [PSCustomObject]@{
                PublisherServer    = $row.PublisherServer
                PublisherDB        = $row.PublisherDB
                PublicationName    = $row.PublicationName
                SubscriberServer   = $row.SubscriberServer
                SubscriberDB       = $row.SubscriberDB
                SubscriptionType   = $row.SubscriptionType
                SubscriptionStatus = $row.SubscriptionStatus
            }
        }
    }

    # Get replication agent schedules (from distribution DB if this is the distributor)
    $schedQuery = @"
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'distribution')
BEGIN
    USE distribution;
    SELECT 
        p.publisher_db                   AS PublisherDB,
        pub.publication                  AS PublicationName,
        s.subscriber_db                  AS SubscriberDB,
        ss.name                          AS SubscriberServer,
        da.name                          AS AgentName,
        CASE 
            WHEN sjs.freq_type = 1    THEN 'Once'
            WHEN sjs.freq_type = 4    THEN 'Daily'
            WHEN sjs.freq_type = 8    THEN 'Weekly'
            WHEN sjs.freq_type = 16   THEN 'Monthly'
            WHEN sjs.freq_type = 32   THEN 'Monthly relative'
            WHEN sjs.freq_type = 64   THEN 'SQL Agent start'
            WHEN sjs.freq_type = 128  THEN 'When idle'
            ELSE 'Every ' + CAST(sjs.freq_subday_interval AS VARCHAR(10)) + 
                 CASE sjs.freq_subday_type 
                     WHEN 1 THEN ' (once)'
                     WHEN 2 THEN ' seconds'
                     WHEN 4 THEN ' minutes'
                     WHEN 8 THEN ' hours'
                     ELSE '' 
                 END
        END                              AS ScheduleFrequency,
        sjs.freq_subday_interval         AS FreqInterval,
        CASE sjs.freq_subday_type 
            WHEN 1 THEN 'At specified time'
            WHEN 2 THEN 'Seconds'
            WHEN 4 THEN 'Minutes'
            WHEN 8 THEN 'Hours'
            ELSE 'Unknown'
        END                              AS FreqSubdayType,
        sjs.active_start_time            AS ActiveStartTime,
        sjs.active_end_time              AS ActiveEndTime,
        sj.enabled                       AS JobEnabled
    FROM distribution.dbo.MSdistribution_agents da
    JOIN distribution.dbo.MSpublications pub 
        ON da.publication = pub.publication AND da.publisher_db = pub.publisher_db
    LEFT JOIN distribution.dbo.MSsubscriptions s 
        ON da.id = s.agent_id
    LEFT JOIN master.sys.servers ss 
        ON s.subscriber_id = ss.server_id
    LEFT JOIN distribution.dbo.MSdistribution_agents p 
        ON da.id = p.id
    LEFT JOIN msdb.dbo.sysjobs sj 
        ON da.job_id = sj.job_id
    LEFT JOIN msdb.dbo.sysjobschedules sjsch 
        ON sj.job_id = sjsch.job_id
    LEFT JOIN msdb.dbo.sysschedules sjs 
        ON sjsch.schedule_id = sjs.schedule_id
    WHERE s.subscriber_db IS NOT NULL;
END
"@
    $schedData = Invoke-SqlQuerySafe -ServerInstance $server -Query $schedQuery
    if ($schedData) {
        foreach ($row in $schedData) {
            $allReplSchedules += [PSCustomObject]@{
                DistributorServer  = $server
                PublisherDB        = $row.PublisherDB
                PublicationName    = $row.PublicationName
                SubscriberServer   = $row.SubscriberServer
                SubscriberDB       = $row.SubscriberDB
                AgentName          = $row.AgentName
                ScheduleFrequency  = $row.ScheduleFrequency
                FreqInterval       = $row.FreqInterval
                FreqSubdayType     = $row.FreqSubdayType
                ActiveStartTime    = $row.ActiveStartTime
                ActiveEndTime      = $row.ActiveEndTime
                JobEnabled         = $row.JobEnabled
            }
        }
    }

    # ── Change Data Capture (CDC) ─────────────────────────────────────
    $hasCDC = $false

    # CDC-enabled databases
    $cdcDbQuery = @"
SELECT 
    SERVERPROPERTY('ServerName')  AS ServerName,
    d.name                        AS DatabaseName,
    d.is_cdc_enabled              AS IsCDCEnabled,
    d.create_date                 AS DatabaseCreated,
    d.compatibility_level         AS CompatLevel
FROM sys.databases d
WHERE d.is_cdc_enabled = 1
ORDER BY d.name
"@
    $cdcDbData = Invoke-SqlQuerySafe -ServerInstance $server -Query $cdcDbQuery
    if ($cdcDbData) {
        $hasCDC = $true
        foreach ($row in $cdcDbData) {
            $allCDCDatabases += [PSCustomObject]@{
                ServerName      = $row.ServerName
                DatabaseName    = $row.DatabaseName
                IsCDCEnabled    = $row.IsCDCEnabled
                CompatLevel     = $row.CompatLevel
            }
        }
    }

    # CDC tracked tables and capture instances
    $cdcTableQuery = @"
DECLARE @sql NVARCHAR(MAX) = '';
SELECT @sql = @sql + '
USE [' + name + '];
SELECT 
    SERVERPROPERTY(''ServerName'')     AS ServerName,
    DB_NAME()                          AS DatabaseName,
    ct.capture_instance               AS CaptureInstance,
    SCHEMA_NAME(st.schema_id) + ''.'' + st.name AS SourceTable,
    ct.start_lsn                      AS StartLSN,
    ct.create_date                    AS CaptureCreateDate,
    ct.supports_net_changes           AS SupportsNetChanges,
    ct.has_drop_pending               AS HasDropPending,
    ct.role_name                      AS RoleName,
    ct.index_name                     AS IndexName,
    ct.filegroup_name                 AS FilegroupName,
    COL_COUNT = (SELECT COUNT(*) FROM cdc.captured_columns cc 
                 WHERE cc.object_id = ct.object_id)
FROM cdc.change_tables ct
JOIN sys.tables st ON ct.source_object_id = st.object_id;
'
FROM sys.databases
WHERE is_cdc_enabled = 1;

IF LEN(@sql) > 0
    EXEC sp_executesql @sql;
"@
    $cdcTableData = Invoke-SqlQuerySafe -ServerInstance $server -Query $cdcTableQuery
    if ($cdcTableData) {
        $hasCDC = $true
        foreach ($row in $cdcTableData) {
            $allCDCTables += [PSCustomObject]@{
                ServerName         = $row.ServerName
                DatabaseName       = $row.DatabaseName
                CaptureInstance    = $row.CaptureInstance
                SourceTable        = $row.SourceTable
                CaptureCreated     = $row.CaptureCreateDate
                SupportsNetChanges = $row.SupportsNetChanges
                HasDropPending     = $row.HasDropPending
                RoleName           = $row.RoleName
                IndexName          = $row.IndexName
                FilegroupName      = $row.FilegroupName
                CapturedColumns    = $row.COL_COUNT
            }
        }
    }

    # CDC capture & cleanup jobs
    $cdcJobQuery = @"
DECLARE @sql NVARCHAR(MAX) = '';
SELECT @sql = @sql + '
USE [' + name + '];
SELECT 
    SERVERPROPERTY(''ServerName'')     AS ServerName,
    DB_NAME()                          AS DatabaseName,
    j.job_id                           AS JobId,
    CASE j.job_type 
        WHEN 1 THEN ''Capture'' 
        WHEN 2 THEN ''Cleanup'' 
        ELSE ''Unknown'' 
    END                                AS JobType,
    sj.name                            AS JobName,
    CASE sj.enabled 
        WHEN 1 THEN ''Enabled'' 
        WHEN 0 THEN ''Disabled'' 
    END                                AS JobStatus,
    j.maxtrans                         AS MaxTrans,
    j.maxscans                         AS MaxScans,
    j.continuous                       AS IsContinuous,
    j.pollinginterval                  AS PollingIntervalSec,
    j.retention                        AS RetentionMinutes,
    j.threshold                        AS CleanupThreshold
FROM msdb.dbo.cdc_jobs j
LEFT JOIN msdb.dbo.sysjobs sj ON j.job_id = sj.job_id;
'
FROM sys.databases
WHERE is_cdc_enabled = 1;

IF LEN(@sql) > 0
    EXEC sp_executesql @sql;
"@
    $cdcJobData = Invoke-SqlQuerySafe -ServerInstance $server -Query $cdcJobQuery
    if ($cdcJobData) {
        foreach ($row in $cdcJobData) {
            $allCDCJobs += [PSCustomObject]@{
                ServerName          = $row.ServerName
                DatabaseName        = $row.DatabaseName
                JobType             = $row.JobType
                JobName             = $row.JobName
                JobStatus           = $row.JobStatus
                MaxTrans            = $row.MaxTrans
                MaxScans            = $row.MaxScans
                IsContinuous        = $row.IsContinuous
                PollingIntervalSec  = $row.PollingIntervalSec
                RetentionMinutes    = $row.RetentionMinutes
                CleanupThreshold    = $row.CleanupThreshold
            }
        }
    }

    # Store server info
    $allServerInfo += [PSCustomObject]@{
        ServerName     = $verInfo.ServerName
        ProductVersion = $verInfo.ProductVersion
        Edition        = $verInfo.Edition
        ProductLevel   = $verInfo.ProductLevel
        UpdateLevel    = $verInfo.UpdateLevel
        IsClustered    = $verInfo.IsClustered
        IsHadrEnabled  = $verInfo.IsHadrEnabled
        HasAG          = $hasAG
        HasReplication = $hasRepl
        HasCDC         = $hasCDC
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Generate HTML Report
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Generating report..." -ForegroundColor Yellow

$reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$reportFile = Join-Path $OutputPath "CMS_AG_Replication_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"

function ConvertTo-HtmlTable {
    param(
        [Parameter(Mandatory)]$Data,
        [string]$EmptyMessage = "No data found."
    )
    if (-not $Data -or $Data.Count -eq 0) {
        return "<p class='empty'>$EmptyMessage</p>"
    }
    $props = $Data[0].PSObject.Properties.Name
    $html = "<table><thead><tr>"
    foreach ($p in $props) {
        $html += "<th>$p</th>"
    }
    $html += "</tr></thead><tbody>"
    foreach ($row in $Data) {
        $html += "<tr>"
        foreach ($p in $props) {
            $val = $row.$p
            $class = ""
            # Conditional highlighting
            if ($val -match "UNREACHABLE|Error|Inactive|NOT_HEALTHY|SUSPENDED") { $class = " class='warn'" }
            elseif ($val -match "HEALTHY|Active|SYNCHRONIZED|ONLINE|CONNECTED") { $class = " class='good'" }
            $html += "<td$class>$val</td>"
        }
        $html += "</tr>"
    }
    $html += "</tbody></table>"
    return $html
}

$agServers   = ($allServerInfo | Where-Object { $_.HasAG }).Count
$replServers = ($allServerInfo | Where-Object { $_.HasReplication }).Count
$cdcServers  = ($allServerInfo | Where-Object { $_.HasCDC }).Count

$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>CMS Server Report – AG, Replication & CDC</title>
<style>
    :root { --bg: #1e1e2e; --fg: #cdd6f4; --accent: #89b4fa; --green: #a6e3a1; 
             --red: #f38ba8; --yellow: #f9e2af; --surface: #313244; --border: #45475a; }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; 
           background: var(--bg); color: var(--fg); padding: 20px; line-height: 1.6; }
    h1 { color: var(--accent); border-bottom: 2px solid var(--accent); padding-bottom: 10px; 
         margin-bottom: 20px; font-size: 1.8em; }
    h2 { color: var(--accent); margin: 30px 0 15px 0; font-size: 1.4em; 
         border-left: 4px solid var(--accent); padding-left: 12px; }
    h3 { color: var(--yellow); margin: 20px 0 10px 0; font-size: 1.1em; }
    .summary { display: flex; gap: 20px; flex-wrap: wrap; margin-bottom: 30px; }
    .summary-card { background: var(--surface); border: 1px solid var(--border); 
                    border-radius: 8px; padding: 20px; min-width: 200px; flex: 1; }
    .summary-card .number { font-size: 2em; font-weight: bold; color: var(--accent); }
    .summary-card .label  { font-size: 0.9em; color: var(--fg); opacity: 0.8; }
    table { width: 100%; border-collapse: collapse; margin: 10px 0 25px 0; 
            background: var(--surface); border-radius: 8px; overflow: hidden; font-size: 0.85em; }
    thead { background: #45475a; }
    th { padding: 10px 12px; text-align: left; color: var(--accent); font-weight: 600; 
         border-bottom: 2px solid var(--border); white-space: nowrap; }
    td { padding: 8px 12px; border-bottom: 1px solid var(--border); }
    tr:hover { background: rgba(137, 180, 250, 0.05); }
    .warn { color: var(--red); font-weight: bold; }
    .good { color: var(--green); }
    .empty { color: var(--yellow); font-style: italic; padding: 10px; }
    .section { background: var(--surface); border: 1px solid var(--border); 
               border-radius: 10px; padding: 20px; margin-bottom: 25px; }
    .meta { font-size: 0.85em; color: var(--fg); opacity: 0.6; margin-bottom: 25px; }
    .toc { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; 
           padding: 15px 25px; margin-bottom: 30px; }
    .toc a { color: var(--accent); text-decoration: none; }
    .toc a:hover { text-decoration: underline; }
    .toc ul { list-style: none; padding-left: 0; }
    .toc li { padding: 4px 0; }
    .toc li::before { content: '▸ '; color: var(--accent); }
    @media print { body { background: white; color: black; } 
                   table { font-size: 0.75em; } 
                   .summary-card { border: 1px solid #ccc; } }
</style>
</head>
<body>

<h1>SQL Server CMS – Availability Group, Replication & CDC Report</h1>
<p class="meta">CMS Server: <strong>$CMSServer</strong> &nbsp;|&nbsp; Generated: <strong>$reportDate</strong> &nbsp;|&nbsp; Servers scanned: <strong>$($registeredServers.Count)</strong></p>

<div class="summary">
    <div class="summary-card"><div class="number">$($registeredServers.Count)</div><div class="label">Total Registered Servers</div></div>
    <div class="summary-card"><div class="number">$agServers</div><div class="label">Servers with Availability Groups</div></div>
    <div class="summary-card"><div class="number">$replServers</div><div class="label">Servers with Replication</div></div>
    <div class="summary-card"><div class="number">$($allDistributors.Count)</div><div class="label">Distributor Databases</div></div>
    <div class="summary-card"><div class="number">$cdcServers</div><div class="label">Servers with CDC</div></div>
</div>

<div class="toc">
<strong>Table of Contents</strong>
<ul>
    <li><a href="#versions">1. SQL Server Versions & Editions</a></li>
    <li><a href="#ag-replicas">2. Availability Group – Replicas</a></li>
    <li><a href="#ag-databases">3. Availability Group – Databases</a></li>
    <li><a href="#ag-listeners">4. Availability Group – Listeners</a></li>
    <li><a href="#repl-publications">5. Replication – Publications</a></li>
    <li><a href="#repl-articles">6. Replication – Articles</a></li>
    <li><a href="#repl-subscriptions">7. Replication – Subscriptions</a></li>
    <li><a href="#repl-schedules">8. Replication – Agent Schedules</a></li>
    <li><a href="#repl-distributors">9. Replication – Distributors</a></li>
    <li><a href="#cdc-databases">10. CDC – Enabled Databases</a></li>
    <li><a href="#cdc-tables">11. CDC – Tracked Tables</a></li>
    <li><a href="#cdc-jobs">12. CDC – Capture & Cleanup Jobs</a></li>
</ul>
</div>

<!-- ═══════════════════════════════════════════════════════════════════ -->
<div class="section" id="versions">
<h2>1. SQL Server Versions & Editions</h2>
$(ConvertTo-HtmlTable -Data $allServerInfo -EmptyMessage "No server data collected.")
</div>

<!-- ═══════════════════════════════════════════════════════════════════ -->
<div class="section" id="ag-replicas">
<h2>2. Availability Group – Replicas</h2>
$(ConvertTo-HtmlTable -Data $allAGDetails -EmptyMessage "No Availability Groups found across registered servers.")
</div>

<div class="section" id="ag-databases">
<h2>3. Availability Group – Databases</h2>
$(ConvertTo-HtmlTable -Data $allAGDatabases -EmptyMessage "No AG databases found.")
</div>

<div class="section" id="ag-listeners">
<h2>4. Availability Group – Listeners</h2>
$(ConvertTo-HtmlTable -Data $allAGListeners -EmptyMessage "No AG listeners found.")
</div>

<!-- ═══════════════════════════════════════════════════════════════════ -->
<div class="section" id="repl-publications">
<h2>5. Replication – Publications</h2>
$(ConvertTo-HtmlTable -Data $allPublications -EmptyMessage "No publications found.")
</div>

<div class="section" id="repl-articles">
<h2>6. Replication – Articles</h2>
$(ConvertTo-HtmlTable -Data $allArticles -EmptyMessage "No articles found.")
</div>

<div class="section" id="repl-subscriptions">
<h2>7. Replication – Subscriptions</h2>
$(ConvertTo-HtmlTable -Data $allSubscriptions -EmptyMessage "No subscriptions found.")
</div>

<div class="section" id="repl-schedules">
<h2>8. Replication – Agent Schedules</h2>
$(ConvertTo-HtmlTable -Data $allReplSchedules -EmptyMessage "No replication schedules found. (Schedule data is only available from distributor servers.)")
</div>

<div class="section" id="repl-distributors">
<h2>9. Replication – Distributors</h2>
$(ConvertTo-HtmlTable -Data $allDistributors -EmptyMessage "No distributor databases found.")
</div>

<!-- ═══════════════════════════════════════════════════════════════════ -->
<div class="section" id="cdc-databases">
<h2>10. CDC – Enabled Databases</h2>
$(ConvertTo-HtmlTable -Data $allCDCDatabases -EmptyMessage "No CDC-enabled databases found across registered servers.")
</div>

<div class="section" id="cdc-tables">
<h2>11. CDC – Tracked Tables</h2>
$(ConvertTo-HtmlTable -Data $allCDCTables -EmptyMessage "No CDC-tracked tables found.")
</div>

<div class="section" id="cdc-jobs">
<h2>12. CDC – Capture & Cleanup Jobs</h2>
$(ConvertTo-HtmlTable -Data $allCDCJobs -EmptyMessage "No CDC jobs found.")
</div>

</body>
</html>
"@

$htmlContent | Out-File -FilePath $reportFile -Encoding UTF8
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Report saved to: $reportFile" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""

# Also export CSVs for each section
$csvBase = Join-Path $OutputPath "CMS_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
if ($allServerInfo.Count -gt 0)     { $allServerInfo    | Export-Csv "$($csvBase)_ServerVersions.csv"  -NoTypeInformation }
if ($allAGDetails.Count -gt 0)      { $allAGDetails     | Export-Csv "$($csvBase)_AG_Replicas.csv"     -NoTypeInformation }
if ($allAGDatabases.Count -gt 0)    { $allAGDatabases   | Export-Csv "$($csvBase)_AG_Databases.csv"    -NoTypeInformation }
if ($allAGListeners.Count -gt 0)    { $allAGListeners   | Export-Csv "$($csvBase)_AG_Listeners.csv"    -NoTypeInformation }
if ($allPublications.Count -gt 0)   { $allPublications  | Export-Csv "$($csvBase)_Publications.csv"    -NoTypeInformation }
if ($allArticles.Count -gt 0)       { $allArticles      | Export-Csv "$($csvBase)_Articles.csv"        -NoTypeInformation }
if ($allSubscriptions.Count -gt 0)  { $allSubscriptions | Export-Csv "$($csvBase)_Subscriptions.csv"   -NoTypeInformation }
if ($allReplSchedules.Count -gt 0)  { $allReplSchedules | Export-Csv "$($csvBase)_ReplSchedules.csv"   -NoTypeInformation }
if ($allDistributors.Count -gt 0)   { $allDistributors  | Export-Csv "$($csvBase)_Distributors.csv"    -NoTypeInformation }
if ($allCDCDatabases.Count -gt 0)   { $allCDCDatabases   | Export-Csv "$($csvBase)_CDC_Databases.csv"   -NoTypeInformation }
if ($allCDCTables.Count -gt 0)      { $allCDCTables      | Export-Csv "$($csvBase)_CDC_Tables.csv"      -NoTypeInformation }
if ($allCDCJobs.Count -gt 0)        { $allCDCJobs        | Export-Csv "$($csvBase)_CDC_Jobs.csv"        -NoTypeInformation }

Write-Host "  CSV files exported to: $csvBase*.csv" -ForegroundColor Green
Write-Host ""

# Optionally open the report
if ($Host.Name -eq 'ConsoleHost') {
    Start-Process $reportFile
}
