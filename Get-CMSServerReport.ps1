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

.PARAMETER InventoryOnly
    If set, collects and reports only server inventory/configuration details,
    skipping Availability Groups, Replication, and CDC sections for faster execution.

.PARAMETER SkipCertValidation
    If set, uses dbatools insecure/trust-certificate connection options to bypass
    SQL certificate chain validation checks.

.EXAMPLE
    .\Get-CMSServerReport.ps1 -CMSServer "MyCMSServer" -OutputPath "C:\Reports"

.EXAMPLE
    .\Get-CMSServerReport.ps1 -ExcelFilePath "C:\Servers\ServerList.xlsx" -OutputPath "C:\Reports"

.EXAMPLE
    .\Get-CMSServerReport.ps1 -ExcelFilePath "C:\Servers\ServerList.xlsx" -SheetName "Production" -ServerColumn "SQLInstance"

.EXAMPLE
    .\Get-CMSServerReport.ps1 -CMSServer "MyCMSServer" -InventoryOnly -OutputPath "C:\Reports"

.EXAMPLE
    .\Get-CMSServerReport.ps1 -CMSServer "MyCMSServer" -SkipCertValidation -OutputPath "C:\Reports"
    Bypasses SQL Server certificate chain validation.
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
    [switch]$IncludeAllServers,

    [Parameter(Mandatory = $false)]
    [switch]$InventoryOnly,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCertValidation
)

# Ensure dbatools module is available (required)
if (-not (Get-Module -ListAvailable -Name dbatools)) {
    Write-Error "The dbatools module is required. Install it with: Install-Module dbatools -Scope CurrentUser"
    exit 1
}

Import-Module dbatools -ErrorAction Stop

# Optionally configure dbatools to trust SQL Server certificates for this session
if ($SkipCertValidation) {
    try {
        if (Get-Command -Name Set-DbatoolsInsecureConnection -ErrorAction SilentlyContinue) {
            Set-DbatoolsInsecureConnection -SessionOnly | Out-Null
        }
        else {
            Set-DbatoolsConfig -FullName 'sql.connection.trustcert' -Value $true | Out-Null
            Set-DbatoolsConfig -FullName 'sql.connection.encrypt' -Value $false | Out-Null
        }
    }
    catch {
        Write-Warning "Could not set dbatools certificate settings automatically. Proceeding with best effort. Error: $_"
    }
}

$invokeDbaQueryCommand = Get-Command -Name Invoke-DbaQuery -ErrorAction SilentlyContinue
if (-not $invokeDbaQueryCommand) {
    Write-Error "Invoke-DbaQuery was not found in dbatools. Please update/reinstall dbatools."
    exit 1
}

$script:InvokeDbaQuerySupportsTrustServerCertificate = $invokeDbaQueryCommand.Parameters.ContainsKey('TrustServerCertificate')
$script:InvokeDbaQuerySupportsEncryptConnection = $invokeDbaQueryCommand.Parameters.ContainsKey('EncryptConnection')

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
        $queryParams = @{
            SqlInstance   = $ServerInstance
            Database      = $Database
            Query         = $Query
            QueryTimeout  = $QueryTimeout
            EnableException = $true
        }

        if ($SkipCertValidation -and $script:InvokeDbaQuerySupportsTrustServerCertificate) {
            $queryParams['TrustServerCertificate'] = $true
        }
        if ($SkipCertValidation -and $script:InvokeDbaQuerySupportsEncryptConnection) {
            $queryParams['EncryptConnection'] = $false
        }

        Invoke-DbaQuery @queryParams
    }
    catch {
        Write-Warning "Failed to query [$ServerInstance]: $_"
        return $null
    }
}

# Validate OutputPath exists (fail early before any collection work)
if (-not (Test-Path $OutputPath -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $OutputPath -ErrorAction Stop | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Get all registered servers from CMS
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  SQL Server – Inventory / AG / Replication / CDC Report       " -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if ($InventoryOnly) {
    Write-Host "Inventory-only mode enabled: AG, Replication, and CDC collectors will be skipped." -ForegroundColor DarkYellow
    Write-Host ""
}

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

    if (-not $excelData -or $excelData.Count -eq 0) {
        Write-Error "Excel file [$ExcelFilePath] contains no data rows."
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
        $registeredServerCommandName = @('Get-DbaRegisteredServer', 'Get-DbaRegServer', 'Get-DbaCmsRegServer') |
            Where-Object { Get-Command -Name $_ -ErrorAction SilentlyContinue } |
            Select-Object -First 1

        if (-not $registeredServerCommandName) {
            throw "No dbatools CMS command found (Get-DbaRegisteredServer/Get-DbaRegServer/Get-DbaCmsRegServer)."
        }

        $registeredServerCommand = Get-Command -Name $registeredServerCommandName -ErrorAction Stop
        $cmsParams = @{ SqlInstance = $CMSServer; ErrorAction = 'Stop' }
        if ($registeredServerCommand.Parameters.ContainsKey('EnableException')) {
            $cmsParams['EnableException'] = $true
        }
        if ($SkipCertValidation -and $registeredServerCommand.Parameters.ContainsKey('TrustServerCertificate')) {
            $cmsParams['TrustServerCertificate'] = $true
        }
        if ($SkipCertValidation -and $registeredServerCommand.Parameters.ContainsKey('EncryptConnection')) {
            $cmsParams['EncryptConnection'] = $false
        }

        $registeredServers = & $registeredServerCommandName @cmsParams |
                             Select-Object -ExpandProperty ServerName -Unique
    }
    catch {
        Write-Error "Could not retrieve registered servers from CMS [$CMSServer] using dbatools. Error: $_"
        exit 1
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

$allServerInfo       = [System.Collections.Generic.List[PSObject]]::new()
$allAGDetails        = [System.Collections.Generic.List[PSObject]]::new()
$allAGDatabases      = [System.Collections.Generic.List[PSObject]]::new()
$allAGListeners      = [System.Collections.Generic.List[PSObject]]::new()
$allPublications     = [System.Collections.Generic.List[PSObject]]::new()
$allArticles         = [System.Collections.Generic.List[PSObject]]::new()
$allSubscriptions    = [System.Collections.Generic.List[PSObject]]::new()
$allDistributors     = [System.Collections.Generic.List[PSObject]]::new()
$allReplSchedules    = [System.Collections.Generic.List[PSObject]]::new()
$allCDCDatabases     = [System.Collections.Generic.List[PSObject]]::new()
$allCDCTables        = [System.Collections.Generic.List[PSObject]]::new()
$allCDCJobs          = [System.Collections.Generic.List[PSObject]]::new()

$serverCount = 0

foreach ($server in $registeredServers) {
    $serverCount++
    Write-Host "[$serverCount/$($registeredServers.Count)] Querying $server ..." -ForegroundColor White

    $hasAG = $false
    $hasRepl = $false
    $hasCDC = $false

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
    SERVERPROPERTY('Collation')         AS Collation,
    CASE 
        WHEN CONVERT(nvarchar(128), SERVERPROPERTY('Collation')) LIKE '%[_]CS[_]%' THEN 'Case-Sensitive'
        WHEN CONVERT(nvarchar(128), SERVERPROPERTY('Collation')) LIKE '%[_]CI[_]%' THEN 'Case-Insensitive'
        ELSE 'Unknown'
    END                                 AS CaseSensitivity,
    ISNULL(CONVERT(int, FULLTEXTSERVICEPROPERTY('IsFullTextInstalled')), 0) AS IsFullTextInstalled,
    (SELECT COUNT(*) FROM sys.databases) AS TotalDatabaseCount,
    (SELECT COUNT(*) FROM sys.databases WHERE database_id > 4) AS UserDatabaseCount,
    (SELECT COUNT(*) FROM sys.databases WHERE database_id <= 4) AS SystemDatabaseCount,
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'Agent XPs') AS AgentXPsEnabled,
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'Database Mail XPs') AS DatabaseMailEnabled,
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'clr enabled') AS SqlClrEnabled,
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'remote access') AS RemoteAccessAllowed,
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'xp_cmdshell') AS XpCmdShellEnabled,
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'min server memory (MB)') AS MinSqlServerMemoryMB,
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'max server memory (MB)') AS MaxSqlServerMemoryMB,
    CASE 
        WHEN (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'min server memory (MB)') = 0
         AND (SELECT CAST(value_in_use AS bigint) FROM sys.configurations WHERE name = 'max server memory (MB)') >= 2147483647
            THEN 'Dynamic/Default'
        ELSE 'Configured'
    END                                 AS MemoryAllocationType,
    (SELECT local_tcp_port FROM sys.dm_exec_connections WHERE session_id = @@SPID) AS SqlPort,
    (SELECT cpu_count FROM sys.dm_os_sys_info) AS AllocatedCpuCount,
    (SELECT socket_count FROM sys.dm_os_sys_info) AS PhysicalProcessorCount,
    (SELECT TOP 1 windows_release FROM sys.dm_os_windows_info) AS OperatingSystem,
    (SELECT TOP 1 windows_service_pack_level FROM sys.dm_os_windows_info) AS OperatingSystemVersion,
    (SELECT CAST(total_physical_memory_kb / 1048576.0 AS decimal(18,2)) FROM sys.dm_os_sys_memory) AS TotalPhysicalMemoryGB,
    (SELECT CAST(available_physical_memory_kb / 1048576.0 AS decimal(18,2)) FROM sys.dm_os_sys_memory) AS AvailablePhysicalMemoryGB,
    (SELECT CAST(total_page_file_kb / 1048576.0 AS decimal(18,2)) FROM sys.dm_os_sys_memory) AS TotalVirtualMemoryGB,
    (SELECT CAST(available_page_file_kb / 1048576.0 AS decimal(18,2)) FROM sys.dm_os_sys_memory) AS AvailableVirtualMemoryGB,
    (
        SELECT CAST(SUM(v.AvailableBytesGB) AS decimal(18,2))
        FROM (
            SELECT DISTINCT vs.volume_mount_point,
                CAST(vs.available_bytes / 1073741824.0 AS decimal(18,2)) AS AvailableBytesGB
            FROM sys.master_files mf
            CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
        ) v
    )                                   AS FreeSpaceGB,
    @@VERSION                           AS FullVersion
"@
    $verInfo = Invoke-SqlQuerySafe -ServerInstance $server -Query $versionQuery
    if (-not $verInfo) {
        Write-Warning "  Skipping $server (unreachable)."
        [void]$allServerInfo.Add([PSCustomObject]@{
            ServerName                 = $server
            ProductVersion             = "UNREACHABLE"
            ProductLevel               = "N/A"
            MajorVersion               = "N/A"
            Edition                    = "N/A"
            EngineEdition              = "N/A"
            UpdateLevel                = "N/A"
            KBArticle                  = "N/A"
            MachineName                = "N/A"
            IsClustered                = "N/A"
            IsHadrEnabled              = "N/A"
            Collation                  = "N/A"
            CaseSensitivity            = "N/A"
            IsFullTextInstalled        = "N/A"
            TotalDatabaseCount         = "N/A"
            UserDatabaseCount          = "N/A"
            SystemDatabaseCount        = "N/A"
            AgentXPsEnabled            = "N/A"
            DatabaseMailEnabled        = "N/A"
            SqlClrEnabled              = "N/A"
            RemoteAccessAllowed        = "N/A"
            XpCmdShellEnabled          = "N/A"
            MinSqlServerMemoryMB       = "N/A"
            MaxSqlServerMemoryMB       = "N/A"
            MemoryAllocationType       = "N/A"
            SqlPort                    = "N/A"
            AllocatedCpuCount          = "N/A"
            PhysicalProcessorCount     = "N/A"
            OperatingSystem            = "N/A"
            OperatingSystemVersion     = "N/A"
            TotalPhysicalMemoryGB      = "N/A"
            AvailablePhysicalMemoryGB  = "N/A"
            TotalVirtualMemoryGB       = "N/A"
            AvailableVirtualMemoryGB   = "N/A"
            FreeSpaceGB                = "N/A"
            FullVersion                = "N/A"
            HasAG                      = $false
            HasReplication             = $false
            HasCDC                     = $false
        })
        continue
    }

    if (-not $InventoryOnly) {
        # ── Availability Groups ───────────────────────────────────────────────
        if ($verInfo.IsHadrEnabled -eq 1) {
        $agQuery = @"
SELECT 
    ag.name                          AS AGName,
    ags.primary_replica              AS PrimaryReplica,
    ags.synchronization_health_desc  AS AGSyncHealth,
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
                [void]$allAGDetails.Add([PSCustomObject]@{
                    SourceServer        = $server
                    AGName              = $row.AGName
                    PrimaryReplica      = $row.PrimaryReplica
                    AGSyncHealth        = $row.AGSyncHealth
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
                })
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
                [void]$allAGDatabases.Add([PSCustomObject]@{
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
                })
            }
        }

        # AG Listeners
        $listenerQuery = @"
SELECT 
    ag.name                          AS AGName,
    agl.dns_name                     AS ListenerDNS,
    agl.port                         AS ListenerPort,
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
                [void]$allAGListeners.Add([PSCustomObject]@{
                    SourceServer  = $server
                    AGName        = $row.AGName
                    ListenerDNS   = $row.ListenerDNS
                    ListenerPort  = $row.ListenerPort
                    IPAddress     = $row.IPAddress
                    SubnetMask    = $row.SubnetMask
                    IPState       = $row.IPState
                })
            }
        }
        }

        # ── Replication ───────────────────────────────────────────────────────

    # Check if this server is a distributor and find the distribution DB name
    $distQuery = @"
DECLARE @distDb NVARCHAR(256);
BEGIN TRY
    IF EXISTS (SELECT 1 FROM msdb.dbo.MSdistributiondbs)
        SELECT TOP 1 @distDb = name FROM msdb.dbo.MSdistributiondbs ORDER BY name;
END TRY
BEGIN CATCH
    SET @distDb = NULL;
END CATCH

IF @distDb IS NULL AND EXISTS (SELECT 1 FROM sys.databases WHERE name = 'distribution' AND state = 0)
    SET @distDb = 'distribution';

IF @distDb IS NOT NULL AND EXISTS (SELECT 1 FROM sys.databases WHERE name = @distDb AND state = 0)
    SELECT 
        SERVERPROPERTY('ServerName') AS DistributorServer,
        @distDb                      AS DistributionDB
    FROM sys.databases d
    WHERE d.name = @distDb;
"@
    $distData = Invoke-SqlQuerySafe -ServerInstance $server -Query $distQuery
    $distDbName = $null
    if ($distData) {
        $distDbName = $distData[0].DistributionDB
        foreach ($row in $distData) {
            [void]$allDistributors.Add([PSCustomObject]@{
                ServerName     = $server
                DistributionDB = $row.DistributionDB
            })
        }

        # ── Distributor-side: publications from distribution DB ────────────
        $distPubQuery = @"
SELECT DISTINCT
    ISNULL(srv.name, CAST(pub.publisher_id AS VARCHAR(20))) AS PublisherServer,
    pub.publisher_db                  AS PublisherDB,
    pub.publication                   AS PublicationName,
    pub.description                   AS PublicationDesc,
    CASE pub.publication_type
        WHEN 0 THEN 'Transactional'
        WHEN 1 THEN 'Snapshot'
        WHEN 2 THEN 'Merge'
        ELSE 'Unknown'
    END                               AS ReplicationType,
    'Active'                          AS PublicationStatus,
    pub.immediate_sync                AS ImmediateSync,
    pub.allow_push                    AS AllowPush,
    pub.allow_pull                    AS AllowPull,
    pub.retention                     AS RetentionPeriod
FROM [$($distDbName)].dbo.MSpublications pub
LEFT JOIN master.sys.servers srv ON pub.publisher_id = srv.server_id
"@
        $distPubData = Invoke-SqlQuerySafe -ServerInstance $server -Query $distPubQuery
        if ($distPubData) {
            $hasRepl = $true
            foreach ($row in $distPubData) {
                [void]$allPublications.Add([PSCustomObject]@{
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
                })
            }
        }

        # ── Distributor-side: articles from distribution DB ───────────────
        $distArtQuery = @"
SELECT
    ISNULL(srv.name, CAST(a.publisher_id AS VARCHAR(20))) AS PublisherServer,
    a.publisher_db                    AS PublisherDB,
    pub.publication                   AS PublicationName,
    a.article                         AS ArticleName,
    a.destination_object              AS DestinationTable,
    a.destination_owner               AS DestinationOwner,
    'N/A'                             AS ArticleType
FROM [$($distDbName)].dbo.MSarticles a
JOIN [$($distDbName)].dbo.MSpublications pub
    ON a.publisher_id = pub.publisher_id
    AND a.publisher_db = pub.publisher_db
    AND a.publication_id = pub.publication_id
LEFT JOIN master.sys.servers srv ON a.publisher_id = srv.server_id
"@
        $distArtData = Invoke-SqlQuerySafe -ServerInstance $server -Query $distArtQuery
        if ($distArtData) {
            $hasRepl = $true
            foreach ($row in $distArtData) {
                [void]$allArticles.Add([PSCustomObject]@{
                    PublisherServer   = $row.PublisherServer
                    PublisherDB       = $row.PublisherDB
                    PublicationName   = $row.PublicationName
                    ArticleName       = $row.ArticleName
                    DestinationTable  = $row.DestinationTable
                    DestinationOwner  = $row.DestinationOwner
                    ArticleType       = $row.ArticleType
                })
            }
        }

        # ── Distributor-side: subscriptions from distribution DB ──────────
        $distSubQuery = @"
SELECT DISTINCT
    ISNULL(srv_pub.name, CAST(da.publisher_id AS VARCHAR(20))) AS PublisherServer,
    da.publisher_db                   AS PublisherDB,
    da.publication                    AS PublicationName,
    ISNULL(srv_sub.name, CAST(s.subscriber_id AS VARCHAR(20))) AS SubscriberServer,
    s.subscriber_db                   AS SubscriberDB,
    CASE s.subscription_type
        WHEN 0 THEN 'Push'
        WHEN 1 THEN 'Pull'
        ELSE 'Unknown'
    END                               AS SubscriptionType,
    CASE s.status
        WHEN 0 THEN 'Inactive'
        WHEN 1 THEN 'Subscribed'
        WHEN 2 THEN 'Active'
        ELSE 'Unknown'
    END                               AS SubscriptionStatus
FROM [$($distDbName)].dbo.MSdistribution_agents da
JOIN [$($distDbName)].dbo.MSsubscriptions s ON da.id = s.agent_id
LEFT JOIN master.sys.servers srv_pub ON da.publisher_id = srv_pub.server_id
LEFT JOIN master.sys.servers srv_sub ON s.subscriber_id = srv_sub.server_id
WHERE s.subscriber_db IS NOT NULL
"@
        $distSubData = Invoke-SqlQuerySafe -ServerInstance $server -Query $distSubQuery
        if ($distSubData) {
            $hasRepl = $true
            foreach ($row in $distSubData) {
                [void]$allSubscriptions.Add([PSCustomObject]@{
                    PublisherServer    = $row.PublisherServer
                    PublisherDB        = $row.PublisherDB
                    PublicationName    = $row.PublicationName
                    SubscriberServer   = $row.SubscriberServer
                    SubscriberDB       = $row.SubscriberDB
                    SubscriptionType   = $row.SubscriptionType
                    SubscriptionStatus = $row.SubscriptionStatus
                })
            }
        }

        # ── Distributor-side: replication agent schedules ─────────────────
        $schedQuery = @"
SELECT
    da.publisher_db                  AS PublisherDB,
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
        ELSE ISNULL('Every ' + CAST(sjs.freq_subday_interval AS VARCHAR(10)) +
             CASE sjs.freq_subday_type
                 WHEN 2 THEN ' seconds'
                 WHEN 4 THEN ' minutes'
                 WHEN 8 THEN ' hours'
                 ELSE ''
             END, 'Unknown')
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
FROM [$($distDbName)].dbo.MSdistribution_agents da
JOIN [$($distDbName)].dbo.MSpublications pub
    ON da.publisher_id = pub.publisher_id
    AND da.publisher_db = pub.publisher_db
    AND da.publication = pub.publication
LEFT JOIN [$($distDbName)].dbo.MSsubscriptions s
    ON da.id = s.agent_id
LEFT JOIN master.sys.servers ss
    ON s.subscriber_id = ss.server_id
LEFT JOIN msdb.dbo.sysjobs sj
    ON da.job_id = sj.job_id
LEFT JOIN msdb.dbo.sysjobschedules sjsch
    ON sj.job_id = sjsch.job_id
LEFT JOIN msdb.dbo.sysschedules sjs
    ON sjsch.schedule_id = sjs.schedule_id
WHERE s.subscriber_db IS NOT NULL
"@
        $schedData = Invoke-SqlQuerySafe -ServerInstance $server -Query $schedQuery
        if ($schedData) {
            foreach ($row in $schedData) {
                [void]$allReplSchedules.Add([PSCustomObject]@{
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
                })
            }
        }
    }

    # Get publications (if this server is a publisher)
    $pubQuery = @"
DECLARE @hasRepl INT = 0;
IF EXISTS (
    SELECT 1 FROM sys.databases 
    WHERE is_published = 1 OR is_distributor = 1
)
SET @hasRepl = 1;

IF @hasRepl = 1
BEGIN
    CREATE TABLE #pubs (
        PublisherServer NVARCHAR(256), PublisherDB NVARCHAR(256),
        PublicationName NVARCHAR(256), PublicationDesc NVARCHAR(MAX),
        ReplicationType NVARCHAR(50), PublicationStatus NVARCHAR(50),
        ImmediateSync INT, AllowPush INT, AllowPull INT,
        RetentionPeriod INT
    );

    DECLARE @sql NVARCHAR(MAX) = '';
    SELECT @sql = @sql + '
    USE [' + name + '];
    IF EXISTS (SELECT 1 FROM sys.tables WHERE name = ''syspublications'')
        INSERT INTO #pubs
        SELECT 
            SERVERPROPERTY(''ServerName''),
            DB_NAME(),
            p.name,
            p.description,
            CASE p.repl_freq 
                WHEN 0 THEN ''Transactional'' 
                WHEN 1 THEN ''Snapshot'' 
                ELSE ''Unknown'' 
            END,
            CASE p.status 
                WHEN 0 THEN ''Inactive'' 
                WHEN 1 THEN ''Active'' 
                ELSE ''Unknown'' 
            END,
            p.immediate_sync,
            p.allow_push,
            p.allow_pull,
            p.retention
        FROM dbo.syspublications p;
    '
    FROM sys.databases
    WHERE is_published = 1;

    IF LEN(@sql) > 0
        EXEC sp_executesql @sql;

    SELECT PublisherServer, PublisherDB, PublicationName, PublicationDesc,
           ReplicationType, PublicationStatus, ImmediateSync, AllowPush,
           AllowPull, RetentionPeriod
    FROM #pubs;

    DROP TABLE #pubs;
END
"@
    $pubData = Invoke-SqlQuerySafe -ServerInstance $server -Query $pubQuery
    if ($pubData) {
        $hasRepl = $true
        foreach ($row in $pubData) {
            [void]$allPublications.Add([PSCustomObject]@{
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
            })
        }
    }

    # Get articles for each published database
    $articleQuery = @"
CREATE TABLE #arts (
    PublisherServer NVARCHAR(256), PublisherDB NVARCHAR(256),
    PublicationName NVARCHAR(256), ArticleName NVARCHAR(256),
    DestinationTable NVARCHAR(256), DestinationOwner NVARCHAR(256),
    ArticleType NVARCHAR(100)
);

DECLARE @sql NVARCHAR(MAX) = '';
SELECT @sql = @sql + '
USE [' + name + '];
IF EXISTS (SELECT 1 FROM sys.tables WHERE name = ''sysarticles'')
    INSERT INTO #arts
    SELECT 
        SERVERPROPERTY(''ServerName''),
        DB_NAME(),
        p.name,
        a.name,
        a.dest_table,
        a.dest_owner,
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
        END
    FROM dbo.sysarticles a
    JOIN dbo.syspublications p ON a.pubid = p.pubid;
'
FROM sys.databases
WHERE is_published = 1;

IF LEN(@sql) > 0
    EXEC sp_executesql @sql;

SELECT PublisherServer, PublisherDB, PublicationName, ArticleName,
       DestinationTable, DestinationOwner, ArticleType
FROM #arts;

DROP TABLE #arts;
"@
    $artData = Invoke-SqlQuerySafe -ServerInstance $server -Query $articleQuery
    if ($artData) {
        foreach ($row in $artData) {
            [void]$allArticles.Add([PSCustomObject]@{
                PublisherServer   = $row.PublisherServer
                PublisherDB       = $row.PublisherDB
                PublicationName   = $row.PublicationName
                ArticleName       = $row.ArticleName
                DestinationTable  = $row.DestinationTable
                DestinationOwner  = $row.DestinationOwner
                ArticleType       = $row.ArticleType
            })
        }
    }

    # Get subscriptions
    $subQuery = @"
CREATE TABLE #subs (
    PublisherServer NVARCHAR(256), PublisherDB NVARCHAR(256),
    PublicationName NVARCHAR(256), SubscriberServer NVARCHAR(256),
    SubscriberDB NVARCHAR(256), SubscriptionType NVARCHAR(50),
    SubscriptionStatus NVARCHAR(50)
);

DECLARE @sql NVARCHAR(MAX) = '';
SELECT @sql = @sql + '
USE [' + name + '];
IF EXISTS (SELECT 1 FROM sys.tables WHERE name = ''syssubscriptions'') 
   AND EXISTS (SELECT 1 FROM sys.tables WHERE name = ''sysarticles'')
    INSERT INTO #subs
    SELECT DISTINCT
        SERVERPROPERTY(''ServerName''),
        DB_NAME(),
        p.name,
        s.srvname,
        s.dest_db,
        CASE s.subscription_type 
            WHEN 0 THEN ''Push'' 
            WHEN 1 THEN ''Pull'' 
            ELSE ''Unknown'' 
        END,
        CASE s.status 
            WHEN 0 THEN ''Inactive'' 
            WHEN 1 THEN ''Subscribed'' 
            WHEN 2 THEN ''Active'' 
            ELSE ''Unknown'' 
        END
    FROM dbo.syssubscriptions s
    JOIN dbo.sysarticles a ON s.artid = a.artid
    JOIN dbo.syspublications p ON a.pubid = p.pubid
    WHERE s.srvname NOT IN (''virtual'', ''(unknown)'');
'
FROM sys.databases
WHERE is_published = 1;

IF LEN(@sql) > 0
    EXEC sp_executesql @sql;

SELECT PublisherServer, PublisherDB, PublicationName, SubscriberServer,
       SubscriberDB, SubscriptionType, SubscriptionStatus
FROM #subs;

DROP TABLE #subs;
"@
    $subData = Invoke-SqlQuerySafe -ServerInstance $server -Query $subQuery
    if ($subData) {
        $hasRepl = $true
        foreach ($row in $subData) {
            [void]$allSubscriptions.Add([PSCustomObject]@{
                PublisherServer    = $row.PublisherServer
                PublisherDB        = $row.PublisherDB
                PublicationName    = $row.PublicationName
                SubscriberServer   = $row.SubscriberServer
                SubscriberDB       = $row.SubscriberDB
                SubscriptionType   = $row.SubscriptionType
                SubscriptionStatus = $row.SubscriptionStatus
            })
        }
    }

        # ── Change Data Capture (CDC) ─────────────────────────────────────

    # CDC-enabled databases
    $cdcDbQuery = @"
SELECT 
    SERVERPROPERTY('ServerName')  AS ServerName,
    d.name                        AS DatabaseName,
    d.is_cdc_enabled              AS IsCDCEnabled,
    d.compatibility_level         AS CompatLevel
FROM sys.databases d
WHERE d.is_cdc_enabled = 1
ORDER BY d.name
"@
    $cdcDbData = Invoke-SqlQuerySafe -ServerInstance $server -Query $cdcDbQuery
    if ($cdcDbData) {
        $hasCDC = $true
        foreach ($row in $cdcDbData) {
            [void]$allCDCDatabases.Add([PSCustomObject]@{
                ServerName      = $row.ServerName
                DatabaseName    = $row.DatabaseName
                IsCDCEnabled    = $row.IsCDCEnabled
                CompatLevel     = $row.CompatLevel
            })
        }
    }

    # CDC tracked tables and capture instances
    $cdcTableQuery = @"
CREATE TABLE #cdctables (
    ServerName NVARCHAR(256), DatabaseName NVARCHAR(256),
    CaptureInstance NVARCHAR(256), SourceTable NVARCHAR(512),
    CaptureCreateDate DATETIME,
    SupportsNetChanges INT, HasDropPending INT,
    RoleName NVARCHAR(256), IndexName NVARCHAR(256),
    FilegroupName NVARCHAR(256), COL_COUNT INT
);

DECLARE @sql NVARCHAR(MAX) = '';
SELECT @sql = @sql + '
USE [' + name + '];
INSERT INTO #cdctables
SELECT 
    SERVERPROPERTY(''ServerName''),
    DB_NAME(),
    ct.capture_instance,
    SCHEMA_NAME(st.schema_id) + ''.'' + st.name,
    ct.create_date,
    ct.supports_net_changes,
    ct.has_drop_pending,
    ct.role_name,
    ct.index_name,
    ct.filegroup_name,
    (SELECT COUNT(*) FROM cdc.captured_columns cc 
     WHERE cc.object_id = ct.object_id)
FROM cdc.change_tables ct
JOIN sys.tables st ON ct.source_object_id = st.object_id;
'
FROM sys.databases
WHERE is_cdc_enabled = 1;

IF LEN(@sql) > 0
    EXEC sp_executesql @sql;

SELECT ServerName, DatabaseName, CaptureInstance, SourceTable,
       CaptureCreateDate, SupportsNetChanges, HasDropPending,
       RoleName, IndexName, FilegroupName, COL_COUNT
FROM #cdctables;

DROP TABLE #cdctables;
"@
    $cdcTableData = Invoke-SqlQuerySafe -ServerInstance $server -Query $cdcTableQuery
    if ($cdcTableData) {
        $hasCDC = $true
        foreach ($row in $cdcTableData) {
            [void]$allCDCTables.Add([PSCustomObject]@{
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
            })
        }
    }

    # CDC capture & cleanup jobs
    $cdcJobQuery = @"
CREATE TABLE #cdcjobs (
    ServerName NVARCHAR(256), DatabaseName NVARCHAR(256),
    JobType NVARCHAR(50), JobName NVARCHAR(256), JobStatus NVARCHAR(50),
    MaxTrans INT, MaxScans INT, IsContinuous INT,
    PollingIntervalSec INT, RetentionMinutes BIGINT,
    CleanupThreshold BIGINT
);

DECLARE @sql NVARCHAR(MAX) = '';
SELECT @sql = @sql + '
USE [' + name + '];
INSERT INTO #cdcjobs
SELECT 
    SERVERPROPERTY(''ServerName''),
    DB_NAME(),
    CASE LOWER(j.job_type) 
        WHEN ''capture'' THEN ''Capture'' 
        WHEN ''cleanup'' THEN ''Cleanup'' 
        ELSE ''Unknown'' 
    END,
    sj.name,
    CASE sj.enabled 
        WHEN 1 THEN ''Enabled'' 
        WHEN 0 THEN ''Disabled'' 
    END,
    j.maxtrans,
    j.maxscans,
    j.continuous,
    j.pollinginterval,
    j.retention,
    j.threshold
FROM msdb.dbo.cdc_jobs j
LEFT JOIN msdb.dbo.sysjobs sj ON j.job_id = sj.job_id
WHERE j.database_id = DB_ID();
'
FROM sys.databases
WHERE is_cdc_enabled = 1;

IF LEN(@sql) > 0
    EXEC sp_executesql @sql;

SELECT ServerName, DatabaseName, JobType, JobName, JobStatus,
       MaxTrans, MaxScans, IsContinuous, PollingIntervalSec,
       RetentionMinutes, CleanupThreshold
FROM #cdcjobs;

DROP TABLE #cdcjobs;
"@
    $cdcJobData = Invoke-SqlQuerySafe -ServerInstance $server -Query $cdcJobQuery
    if ($cdcJobData) {
        foreach ($row in $cdcJobData) {
            [void]$allCDCJobs.Add([PSCustomObject]@{
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
            })
        }
    }
    }

    # Store server info
    [void]$allServerInfo.Add([PSCustomObject]@{
        ServerName                 = $verInfo.ServerName
        ProductVersion             = $verInfo.ProductVersion
        ProductLevel               = $verInfo.ProductLevel
        MajorVersion               = $verInfo.MajorVersion
        Edition                    = $verInfo.Edition
        EngineEdition              = $verInfo.EngineEdition
        UpdateLevel                = $verInfo.UpdateLevel
        KBArticle                  = $verInfo.KBArticle
        MachineName                = $verInfo.MachineName
        IsClustered                = $verInfo.IsClustered
        IsHadrEnabled              = $verInfo.IsHadrEnabled
        Collation                  = $verInfo.Collation
        CaseSensitivity            = $verInfo.CaseSensitivity
        IsFullTextInstalled        = $verInfo.IsFullTextInstalled
        TotalDatabaseCount         = $verInfo.TotalDatabaseCount
        UserDatabaseCount          = $verInfo.UserDatabaseCount
        SystemDatabaseCount        = $verInfo.SystemDatabaseCount
        AgentXPsEnabled            = $verInfo.AgentXPsEnabled
        DatabaseMailEnabled        = $verInfo.DatabaseMailEnabled
        SqlClrEnabled              = $verInfo.SqlClrEnabled
        RemoteAccessAllowed        = $verInfo.RemoteAccessAllowed
        XpCmdShellEnabled          = $verInfo.XpCmdShellEnabled
        MinSqlServerMemoryMB       = $verInfo.MinSqlServerMemoryMB
        MaxSqlServerMemoryMB       = $verInfo.MaxSqlServerMemoryMB
        MemoryAllocationType       = $verInfo.MemoryAllocationType
        SqlPort                    = $verInfo.SqlPort
        AllocatedCpuCount          = $verInfo.AllocatedCpuCount
        PhysicalProcessorCount     = $verInfo.PhysicalProcessorCount
        OperatingSystem            = $verInfo.OperatingSystem
        OperatingSystemVersion     = $verInfo.OperatingSystemVersion
        TotalPhysicalMemoryGB      = $verInfo.TotalPhysicalMemoryGB
        AvailablePhysicalMemoryGB  = $verInfo.AvailablePhysicalMemoryGB
        TotalVirtualMemoryGB       = $verInfo.TotalVirtualMemoryGB
        AvailableVirtualMemoryGB   = $verInfo.AvailableVirtualMemoryGB
        FreeSpaceGB                = $verInfo.FreeSpaceGB
        FullVersion                = $verInfo.FullVersion
        HasAG                      = $hasAG
        HasReplication             = $hasRepl
        HasCDC                     = $hasCDC
    })
}

# ─────────────────────────────────────────────────────────────────────────────
# 2b. Deduplicate replication data (publisher-side + distributor-side overlap)
# ─────────────────────────────────────────────────────────────────────────────
if (-not $InventoryOnly) {
    Write-Host "Deduplicating replication data..." -ForegroundColor DarkGray

    if ($allPublications.Count -gt 0) {
        $allPublications = $allPublications |
            Sort-Object PublisherServer, PublisherDB, PublicationName -Unique
        Write-Host "  Publications: $($allPublications.Count) unique" -ForegroundColor DarkGray
    }
    if ($allArticles.Count -gt 0) {
        $allArticles = $allArticles |
            Sort-Object PublisherServer, PublisherDB, PublicationName, ArticleName -Unique
        Write-Host "  Articles: $($allArticles.Count) unique" -ForegroundColor DarkGray
    }
    if ($allSubscriptions.Count -gt 0) {
        $allSubscriptions = $allSubscriptions |
            Sort-Object PublisherServer, PublisherDB, PublicationName, SubscriberServer, SubscriberDB -Unique
        Write-Host "  Subscriptions: $($allSubscriptions.Count) unique" -ForegroundColor DarkGray
    }
    if ($allDistributors.Count -gt 0) {
        $allDistributors = $allDistributors |
            Sort-Object ServerName, DistributionDB -Unique
        Write-Host "  Distributors: $($allDistributors.Count) unique" -ForegroundColor DarkGray
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 2c. Build combined replication topology (joined view)
# ─────────────────────────────────────────────────────────────────────────────
$allReplTopology = [System.Collections.Generic.List[PSObject]]::new()
if (-not $InventoryOnly -and $allSubscriptions.Count -gt 0) {
    Write-Host "Building combined replication topology..." -ForegroundColor DarkGray

    # Build lookup hashtables for fast matching
    $pubLookup = @{}
    foreach ($p in $allPublications) {
        $key = "$($p.PublisherServer)|$($p.PublisherDB)|$($p.PublicationName)"
        if (-not $pubLookup.ContainsKey($key)) { $pubLookup[$key] = $p }
    }

    $artCountLookup = @{}
    foreach ($a in $allArticles) {
        $key = "$($a.PublisherServer)|$($a.PublisherDB)|$($a.PublicationName)"
        if ($artCountLookup.ContainsKey($key)) { $artCountLookup[$key]++ } else { $artCountLookup[$key] = 1 }
    }

    $schedLookup = @{}
    foreach ($s in $allReplSchedules) {
        $key = "$($s.PublisherDB)|$($s.PublicationName)|$($s.SubscriberServer)|$($s.SubscriberDB)"
        if (-not $schedLookup.ContainsKey($key)) { $schedLookup[$key] = $s }
    }

    foreach ($sub in $allSubscriptions) {
        $pubKey   = "$($sub.PublisherServer)|$($sub.PublisherDB)|$($sub.PublicationName)"
        $schedKey = "$($sub.PublisherDB)|$($sub.PublicationName)|$($sub.SubscriberServer)|$($sub.SubscriberDB)"

        $pub   = $pubLookup[$pubKey]
        $artCt = if ($artCountLookup.ContainsKey($pubKey)) { $artCountLookup[$pubKey] } else { 0 }
        $sched = $schedLookup[$schedKey]

        # Find distributor for this publisher (from schedule data only)
        $distServer = if ($sched) { $sched.DistributorServer } else { 'Unknown' }

        [void]$allReplTopology.Add([PSCustomObject]@{
            DistributorServer  = $distServer
            PublisherServer    = $sub.PublisherServer
            PublisherDB        = $sub.PublisherDB
            PublicationName    = $sub.PublicationName
            ReplicationType    = if ($pub) { $pub.ReplicationType } else { 'Unknown' }
            PublicationStatus  = if ($pub) { $pub.PublicationStatus } else { 'Unknown' }
            ArticleCount       = $artCt
            SubscriberServer   = $sub.SubscriberServer
            SubscriberDB       = $sub.SubscriberDB
            SubscriptionType   = $sub.SubscriptionType
            SubscriptionStatus = $sub.SubscriptionStatus
            AgentName          = if ($sched) { $sched.AgentName } else { 'N/A' }
            ScheduleFrequency  = if ($sched) { $sched.ScheduleFrequency } else { 'N/A' }
            JobEnabled         = if ($sched) { $sched.JobEnabled } else { 'N/A' }
        })
    }
    Write-Host "  Topology rows: $($allReplTopology.Count)" -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Generate HTML Report
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Generating report..." -ForegroundColor Yellow

$reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$reportSuffix = Get-Date -Format 'yyyyMMdd_HHmmss'
$reportFile = if ($InventoryOnly) {
    Join-Path $OutputPath "CMS_Inventory_Report_$reportSuffix.html"
} else {
    Join-Path $OutputPath "CMS_AG_Replication_Report_$reportSuffix.html"
}

function ConvertTo-HtmlTable {
    param(
        [Parameter(Mandatory)]$Data,
        [string]$EmptyMessage = "No data found."
    )
    if (-not $Data -or $Data.Count -eq 0) {
        return "<p class='empty'>$EmptyMessage</p>"
    }
    $props = $Data[0].PSObject.Properties.Name
    $sb = [System.Text.StringBuilder]::new(4096)
    [void]$sb.Append("<table><thead><tr>")
    foreach ($p in $props) {
        [void]$sb.Append("<th>$p</th>")
    }
    [void]$sb.Append("</tr></thead><tbody>")
    foreach ($row in $Data) {
        [void]$sb.Append("<tr>")
        foreach ($p in $props) {
            $val = $row.$p
            $class = ""
            # Conditional highlighting (match before encoding)
            if ($val -match "UNREACHABLE|Error|Inactive|NOT_HEALTHY|SUSPENDED") { $class = " class='warn'" }
            elseif ($val -match "HEALTHY|Active|SYNCHRONIZED|ONLINE|CONNECTED") { $class = " class='good'" }
            [void]$sb.Append("<td$class>$([System.Net.WebUtility]::HtmlEncode([string]$val))</td>")
        }
        [void]$sb.Append("</tr>")
    }
    [void]$sb.Append("</tbody></table>")
    return $sb.ToString()
}

$agServers   = ($allServerInfo | Where-Object { $_.HasAG }).Count
$replServers = ($allServerInfo | Where-Object { $_.HasReplication }).Count
$cdcServers  = ($allServerInfo | Where-Object { $_.HasCDC }).Count

$reportTitle = if ($InventoryOnly) {
    "CMS Server Report – Inventory"
} else {
    "CMS Server Report – Inventory, AG, Replication & CDC"
}

$reportHeader = if ($InventoryOnly) {
    "SQL Server CMS – Inventory Report"
} else {
    "SQL Server CMS – Inventory, Availability Group, Replication & CDC Report"
}

$summaryExtraCards = if ($InventoryOnly) {
    ""
} else {
@"
    <div class="summary-card"><div class="number">$agServers</div><div class="label">Servers with Availability Groups</div></div>
    <div class="summary-card"><div class="number">$replServers</div><div class="label">Servers with Replication</div></div>
    <div class="summary-card"><div class="number">$($allDistributors.Count)</div><div class="label">Distributor Databases</div></div>
    <div class="summary-card"><div class="number">$cdcServers</div><div class="label">Servers with CDC</div></div>
"@
}

$tocExtraItems = if ($InventoryOnly) {
    ""
} else {
@"
    <li><a href="#ag-replicas">2. Availability Group – Replicas</a></li>
    <li><a href="#ag-databases">3. Availability Group – Databases</a></li>
    <li><a href="#ag-listeners">4. Availability Group – Listeners</a></li>
    <li><a href="#repl-publications">5. Replication – Publications</a></li>
    <li><a href="#repl-articles">6. Replication – Articles</a></li>
    <li><a href="#repl-subscriptions">7. Replication – Subscriptions</a></li>
    <li><a href="#repl-schedules">8. Replication – Agent Schedules</a></li>
    <li><a href="#repl-distributors">9. Replication – Distributors</a></li>
    <li><a href="#repl-topology">10. Replication – Combined Topology</a></li>
    <li><a href="#cdc-databases">11. CDC – Enabled Databases</a></li>
    <li><a href="#cdc-tables">12. CDC – Tracked Tables</a></li>
    <li><a href="#cdc-jobs">13. CDC – Capture & Cleanup Jobs</a></li>
"@
}

$detailSections = ""
if (-not $InventoryOnly) {
    $sectionDefs = @(
        @{ Id='ag-replicas';      Num=2;  Title='Availability Group – Replicas';    Data=$allAGDetails;      Empty="No Availability Groups found across registered servers." },
        @{ Id='ag-databases';     Num=3;  Title='Availability Group – Databases';   Data=$allAGDatabases;    Empty="No AG databases found." },
        @{ Id='ag-listeners';     Num=4;  Title='Availability Group – Listeners';   Data=$allAGListeners;    Empty="No AG listeners found." },
        @{ Id='repl-publications'; Num=5;  Title='Replication – Publications';       Data=$allPublications;   Empty="No publications found." },
        @{ Id='repl-articles';    Num=6;  Title='Replication – Articles';           Data=$allArticles;       Empty="No articles found." },
        @{ Id='repl-subscriptions'; Num=7; Title='Replication – Subscriptions';     Data=$allSubscriptions;  Empty="No subscriptions found." },
        @{ Id='repl-schedules';   Num=8;  Title='Replication – Agent Schedules';    Data=$allReplSchedules;  Empty="No replication schedules found. (Schedule data is only available from distributor servers.)" },
        @{ Id='repl-distributors'; Num=9; Title='Replication – Distributors';       Data=$allDistributors;   Empty="No distributor databases found." },
        @{ Id='repl-topology';    Num=10; Title='Replication – Combined Topology';  Data=$allReplTopology;   Empty="No combined replication topology data. Ensure distributor servers are included in the scan." },
        @{ Id='cdc-databases';    Num=11; Title='CDC – Enabled Databases';          Data=$allCDCDatabases;   Empty="No CDC-enabled databases found across registered servers." },
        @{ Id='cdc-tables';       Num=12; Title='CDC – Tracked Tables';             Data=$allCDCTables;      Empty="No CDC-tracked tables found." },
        @{ Id='cdc-jobs';         Num=13; Title='CDC – Capture & Cleanup Jobs';     Data=$allCDCJobs;        Empty="No CDC jobs found." }
    )

    $sbSections = [System.Text.StringBuilder]::new(32768)
    foreach ($sec in $sectionDefs) {
        $rowCount = if ($sec.Data) { $sec.Data.Count } else { 0 }
        Write-Host "  Building section $($sec.Num). $($sec.Title) ($rowCount rows)..." -ForegroundColor DarkGray
        $tableHtml = ConvertTo-HtmlTable -Data $sec.Data -EmptyMessage $sec.Empty
        [void]$sbSections.AppendLine("<div class=`"section`" id=`"$($sec.Id)`">")
        [void]$sbSections.AppendLine("<h2>$($sec.Num). $($sec.Title)</h2>")
        [void]$sbSections.AppendLine($tableHtml)
        [void]$sbSections.AppendLine("</div>")
        [void]$sbSections.AppendLine()
    }
    $detailSections = $sbSections.ToString()
}

Write-Host "  Building section 1. Server Inventory ($($allServerInfo.Count) rows)..." -ForegroundColor DarkGray
$inventoryTableHtml = ConvertTo-HtmlTable -Data $allServerInfo -EmptyMessage "No server data collected."

$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>$reportTitle</title>
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

<h1>$reportHeader</h1>
<p class="meta">Server Source: <strong>$serverSource</strong> &nbsp;|&nbsp; Generated: <strong>$reportDate</strong> &nbsp;|&nbsp; Servers scanned: <strong>$($registeredServers.Count)</strong></p>

<div class="summary">
    <div class="summary-card"><div class="number">$($registeredServers.Count)</div><div class="label">Total Registered Servers</div></div>
$summaryExtraCards
</div>

<div class="toc">
<strong>Table of Contents</strong>
<ul>
    <li><a href="#versions">1. SQL Server Inventory & Configuration</a></li>
$tocExtraItems
</ul>
</div>

<!-- ═══════════════════════════════════════════════════════════════════ -->
<div class="section" id="versions">
<h2>1. SQL Server Inventory & Configuration</h2>
$inventoryTableHtml
</div>

$detailSections

</body>
</html>
"@

$htmlContent | Out-File -FilePath $reportFile -Encoding UTF8
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Report saved to: $reportFile" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""

# Also export CSVs for each section (same timestamp suffix as the HTML report)
$csvBase = Join-Path $OutputPath "CMS_Report_$reportSuffix"
if ($allServerInfo.Count -gt 0)     { $allServerInfo    | Export-Csv "$($csvBase)_ServerInventory.csv" -NoTypeInformation }
if (-not $InventoryOnly) {
    if ($allAGDetails.Count -gt 0)      { $allAGDetails     | Export-Csv "$($csvBase)_AG_Replicas.csv"     -NoTypeInformation }
    if ($allAGDatabases.Count -gt 0)    { $allAGDatabases   | Export-Csv "$($csvBase)_AG_Databases.csv"    -NoTypeInformation }
    if ($allAGListeners.Count -gt 0)    { $allAGListeners   | Export-Csv "$($csvBase)_AG_Listeners.csv"    -NoTypeInformation }
    if ($allPublications.Count -gt 0)   { $allPublications  | Export-Csv "$($csvBase)_Publications.csv"    -NoTypeInformation }
    if ($allArticles.Count -gt 0)       { $allArticles      | Export-Csv "$($csvBase)_Articles.csv"        -NoTypeInformation }
    if ($allSubscriptions.Count -gt 0)  { $allSubscriptions | Export-Csv "$($csvBase)_Subscriptions.csv"   -NoTypeInformation }
    if ($allReplSchedules.Count -gt 0)  { $allReplSchedules | Export-Csv "$($csvBase)_ReplSchedules.csv"   -NoTypeInformation }
    if ($allDistributors.Count -gt 0)   { $allDistributors  | Export-Csv "$($csvBase)_Distributors.csv"    -NoTypeInformation }
    if ($allReplTopology.Count -gt 0)   { $allReplTopology  | Export-Csv "$($csvBase)_ReplicationTopology.csv" -NoTypeInformation
        Write-Host "  Combined replication topology: $($csvBase)_ReplicationTopology.csv" -ForegroundColor Green
    }
    if ($allCDCDatabases.Count -gt 0)   { $allCDCDatabases  | Export-Csv "$($csvBase)_CDC_Databases.csv"   -NoTypeInformation }
    if ($allCDCTables.Count -gt 0)      { $allCDCTables     | Export-Csv "$($csvBase)_CDC_Tables.csv"      -NoTypeInformation }
    if ($allCDCJobs.Count -gt 0)        { $allCDCJobs       | Export-Csv "$($csvBase)_CDC_Jobs.csv"        -NoTypeInformation }
}

Write-Host "  CSV files exported to: $csvBase*.csv" -ForegroundColor Green
Write-Host ""

# Optionally open the report
if ($Host.Name -eq 'ConsoleHost') {
    Start-Process $reportFile
}
