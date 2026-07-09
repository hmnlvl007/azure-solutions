<#
.SYNOPSIS
    Reports the largest eligible tables in the DBA database across CMS registered SQL Servers.

.DESCRIPTION
    Connects to a SQL Server Central Management Server (CMS), enumerates registered
    SQL Server instances, queries the DBA database on each instance, and reports the
    top largest tables where used space is greater than or equal to the configured
    threshold.

    The output is a consolidated HTML report. If SMTP settings are provided, the
    same report is emailed as the message body and attached as an HTML file.

.PARAMETER CMSServer
    SQL Server Central Management Server instance that contains registered servers.

.PARAMETER ExcelFilePath
    Path to an Excel file (.xlsx) containing a list of server names.
    The file must have a column named ServerName unless -ServerColumn is provided.
    Mutually exclusive with CMSServer.

.PARAMETER SheetName
    Worksheet name to read from the Excel file. Defaults to the first worksheet.

.PARAMETER ServerColumn
    Column header in the Excel file that contains server names. Defaults to ServerName.

.PARAMETER DatabaseName
    Database to inspect on each registered SQL Server. Defaults to DBA.

.PARAMETER MinUsedSpaceMB
    Minimum table used space, in MB, required to be included. Defaults to 1024.

.PARAMETER Top
    Maximum number of eligible tables returned per server/database. Defaults to 5.

.PARAMETER OutputPath
    Folder where the HTML report will be saved. Defaults to the current directory.

.PARAMETER QueryTimeout
    Query timeout in seconds for per-server collection queries. Defaults to 120.

.PARAMETER SqlCredential
    Optional SQL credential used for CMS discovery and server queries when the
    dbatools command supports SqlCredential. If omitted, dbatools uses the
    current Windows security context.

.PARAMETER SmtpServer
    SMTP server used to email the report. If omitted, no email is sent.

.PARAMETER From
    Email sender address. Required when SmtpServer is provided.

.PARAMETER To
    Email recipients. Required when SmtpServer is provided.

.PARAMETER SkipCertValidation
    Uses dbatools trust-certificate/insecure options for SQL connections.

.EXAMPLE
    .\Get-CMSDbaLargeTableReport.ps1 -CMSServer "MyCmsServer" -OutputPath "C:\Reports"

.EXAMPLE
    .\Get-CMSDbaLargeTableReport.ps1 -ExcelFilePath "C:\Servers\ServerList.xlsx" -ServerColumn "SQLInstance" -OutputPath "C:\Reports"

.EXAMPLE
    .\Get-CMSDbaLargeTableReport.ps1 -CMSServer "MyCmsServer" -SmtpServer "smtp.company.com" -From "sqlreports@company.com" -To "dba-team@company.com"
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

    [string]$DatabaseName = 'DBA',

    [ValidateRange(1, 2147483647)]
    [int]$MinUsedSpaceMB = 1024,

    [ValidateRange(1, 100)]
    [int]$Top = 5,

    [string]$OutputPath = (Get-Location).Path,

    [ValidateRange(1, 2147483647)]
    [int]$QueryTimeout = 120,

    [System.Management.Automation.PSCredential]$SqlCredential,

    [string]$SmtpServer,

    [int]$Port = 25,

    [switch]$UseSsl,

    [string]$From,

    [string[]]$To,

    [string[]]$Cc,

    [string]$Subject = "SQL Server DBA Large Tables Report",

    [switch]$SkipCertValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name dbatools)) {
    Write-Error "The dbatools module is required. Install it with: Install-Module dbatools -Scope CurrentUser"
    exit 1
}

Import-Module dbatools -ErrorAction Stop

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
        Write-Warning "Could not set dbatools certificate settings automatically. Proceeding with best effort. Error: $($_.Exception.Message)"
    }
}

$invokeDbaQueryCommand = Get-Command -Name Invoke-DbaQuery -ErrorAction SilentlyContinue
if (-not $invokeDbaQueryCommand) {
    Write-Error "Invoke-DbaQuery was not found in dbatools. Please update/reinstall dbatools."
    exit 1
}

$script:InvokeDbaQuerySupportsTrustServerCertificate = $invokeDbaQueryCommand.Parameters.ContainsKey('TrustServerCertificate')
$script:InvokeDbaQuerySupportsEncryptConnection = $invokeDbaQueryCommand.Parameters.ContainsKey('EncryptConnection')
$script:InvokeDbaQuerySupportsSqlCredential = $invokeDbaQueryCommand.Parameters.ContainsKey('SqlCredential')
$script:LastSqlQueryError = $null

function Invoke-SqlQuerySafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerInstance,

        [Parameter(Mandatory = $true)]
        [string]$Database,

        [Parameter(Mandatory = $true)]
        [string]$Query,

        [int]$QueryTimeout = 120
    )

    $script:LastSqlQueryError = $null

    try {
        $queryParams = @{
            SqlInstance     = $ServerInstance
            Database        = $Database
            Query           = $Query
            QueryTimeout    = $QueryTimeout
            EnableException = $true
        }

        if ($SkipCertValidation -and $script:InvokeDbaQuerySupportsTrustServerCertificate) {
            $queryParams.TrustServerCertificate = $true
        }
        if ($SkipCertValidation -and $script:InvokeDbaQuerySupportsEncryptConnection) {
            $queryParams.EncryptConnection = $false
        }
        if ($SqlCredential -and $script:InvokeDbaQuerySupportsSqlCredential) {
            $queryParams.SqlCredential = $SqlCredential
        }

        Invoke-DbaQuery @queryParams
    }
    catch {
        $script:LastSqlQueryError = $_.Exception.Message
        Write-Warning "Failed to query [$ServerInstance]: $script:LastSqlQueryError"
        return $null
    }
}

function Get-CmsRegisteredServers {
    param([string]$SqlInstance)

    $registeredServerCommandName = @('Get-DbaRegisteredServer', 'Get-DbaRegServer', 'Get-DbaCmsRegServer') |
        Where-Object { Get-Command -Name $_ -ErrorAction SilentlyContinue } |
        Select-Object -First 1

    if (-not $registeredServerCommandName) {
        throw "No dbatools CMS command found (Get-DbaRegisteredServer/Get-DbaRegServer/Get-DbaCmsRegServer)."
    }

    $registeredServerCommand = Get-Command -Name $registeredServerCommandName -ErrorAction Stop
    $cmsParams = @{
        SqlInstance = $SqlInstance
        ErrorAction = 'Stop'
    }

    if ($registeredServerCommand.Parameters.ContainsKey('EnableException')) {
        $cmsParams.EnableException = $true
    }
    if ($SkipCertValidation -and $registeredServerCommand.Parameters.ContainsKey('TrustServerCertificate')) {
        $cmsParams.TrustServerCertificate = $true
    }
    if ($SkipCertValidation -and $registeredServerCommand.Parameters.ContainsKey('EncryptConnection')) {
        $cmsParams.EncryptConnection = $false
    }
    if ($SqlCredential -and $registeredServerCommand.Parameters.ContainsKey('SqlCredential')) {
        $cmsParams.SqlCredential = $SqlCredential
    }

    & $registeredServerCommandName @cmsParams |
        Select-Object -ExpandProperty ServerName -Unique |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object
}

function ConvertTo-HtmlTable {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Data,

        [string]$EmptyMessage = 'No rows found.'
    )

    if (-not $Data -or $Data.Count -eq 0) {
        return "<p class='empty'>$([System.Net.WebUtility]::HtmlEncode($EmptyMessage))</p>"
    }

    $properties = $Data[0].PSObject.Properties.Name
    $sb = [System.Text.StringBuilder]::new(4096)

    [void]$sb.AppendLine('<table>')
    [void]$sb.AppendLine('<thead><tr>')
    foreach ($property in $properties) {
        [void]$sb.AppendFormat('<th>{0}</th>', [System.Net.WebUtility]::HtmlEncode($property))
    }
    [void]$sb.AppendLine('</tr></thead>')
    [void]$sb.AppendLine('<tbody>')

    foreach ($row in $Data) {
        [void]$sb.AppendLine('<tr>')
        foreach ($property in $properties) {
            $value = [string]$row.$property
            [void]$sb.AppendFormat('<td>{0}</td>', [System.Net.WebUtility]::HtmlEncode($value))
        }
        [void]$sb.AppendLine('</tr>')
    }

    [void]$sb.AppendLine('</tbody></table>')
    $sb.ToString()
}

function Send-HtmlReport {
    param(
        [string]$Html,
        [string]$ReportFile
    )

    if ([string]::IsNullOrWhiteSpace($SmtpServer)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($From) -or -not $To -or $To.Count -eq 0) {
        throw "When -SmtpServer is provided, -From and -To are required."
    }

    $mailParams = @{
        SmtpServer = $SmtpServer
        Port       = $Port
        From       = $From
        To         = $To
        Subject    = $Subject
        Body       = $Html
        BodyAsHtml = $true
        Attachments = $ReportFile
    }

    if ($UseSsl) {
        $mailParams.UseSsl = $true
    }
    if ($Cc -and $Cc.Count -gt 0) {
        $mailParams.Cc = $Cc
    }

    Send-MailMessage @mailParams
}

if (-not (Test-Path $OutputPath -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $OutputPath -ErrorAction Stop | Out-Null
}

Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  SQL Server CMS - DBA Large Tables Report                     " -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""

if ($PSCmdlet.ParameterSetName -eq 'Excel') {
    Write-Host "Reading server list from Excel: $ExcelFilePath ..." -ForegroundColor Yellow

    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        Write-Error "The ImportExcel module is required for Excel input. Install it with: Install-Module ImportExcel -Scope CurrentUser"
        exit 1
    }
    Import-Module ImportExcel -ErrorAction Stop

    $importParams = @{ Path = $ExcelFilePath }
    if ($SheetName) {
        $importParams.WorksheetName = $SheetName
    }

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

    $registeredServers = @(
        $excelData |
            ForEach-Object { $_.$ServerColumn } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $serverSource = "Excel file: $ExcelFilePath"
}
else {
    Write-Host "Connecting to CMS: $CMSServer ..." -ForegroundColor Yellow
    try {
        $registeredServers = @(Get-CmsRegisteredServers -SqlInstance $CMSServer)
    }
    catch {
        Write-Error "Could not retrieve registered servers from CMS [$CMSServer] using dbatools. Error: $_"
        exit 1
    }

    $serverSource = "CMS: $CMSServer"
}

if ($registeredServers.Count -eq 0) {
    Write-Error "No servers found from $serverSource."
    exit 1
}

Write-Host "  Found $($registeredServers.Count) server(s) from $serverSource." -ForegroundColor Green
Write-Host ""

$escapedDatabaseName = $DatabaseName.Replace("'", "''")
$databaseLookupQuery = @"
SELECT TOP (1)
    d.name AS DatabaseName,
    d.state_desc AS DatabaseState,
    HAS_DBACCESS(d.name) AS HasDbAccess
FROM sys.databases d
WHERE d.name = N'$escapedDatabaseName'
   OR UPPER(d.name) = UPPER(N'$escapedDatabaseName')
ORDER BY
    CASE WHEN d.name = N'$escapedDatabaseName' THEN 0 ELSE 1 END,
    d.name;
"@

$collectionQuery = @"
;WITH RowCounts AS
(
    SELECT
        object_id,
        SUM(row_count) AS RowCounts
    FROM sys.dm_db_partition_stats
    WHERE index_id IN (0, 1)
    GROUP BY object_id
),
TableSpace AS
(
    SELECT
        object_id,
        SUM(reserved_page_count) * 8.0 / 1024 AS TotalSpaceMB,
        SUM(used_page_count) * 8.0 / 1024 AS UsedSpaceMB
    FROM sys.dm_db_partition_stats
    GROUP BY object_id
),
DatabaseSize AS
(
    SELECT SUM(size) * 8.0 / 1024 AS DatabaseMB
    FROM sys.database_files
)
SELECT TOP ($Top)
    DB_NAME() AS DatabaseName,
    s.name AS SchemaName,
    t.name AS TableName,
    CONVERT(bigint, ISNULL(rc.RowCounts, 0)) AS RowCounts,
    CONVERT(decimal(18,2), ts.TotalSpaceMB) AS TotalSpaceMB,
    CONVERT(decimal(18,2), ts.UsedSpaceMB) AS UsedSpaceMB,
    CONVERT(decimal(18,2), ds.DatabaseMB) AS DatabaseMB
FROM sys.tables t
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
INNER JOIN TableSpace ts ON t.object_id = ts.object_id
LEFT JOIN RowCounts rc ON t.object_id = rc.object_id
CROSS JOIN DatabaseSize ds
WHERE t.is_ms_shipped = 0
  AND ts.UsedSpaceMB >= $MinUsedSpaceMB
ORDER BY ts.UsedSpaceMB DESC, ts.TotalSpaceMB DESC, s.name, t.name;
"@

$eligibleTables = [System.Collections.Generic.List[PSObject]]::new()
$collectionIssues = [System.Collections.Generic.List[PSObject]]::new()

$serverCount = 0
foreach ($server in $registeredServers) {
    $serverCount++
    Write-Host "[$serverCount/$($registeredServers.Count)] Querying $server ..." -ForegroundColor White

    $databaseLookupResult = Invoke-SqlQuerySafe -ServerInstance $server -Database master -Query $databaseLookupQuery -QueryTimeout $QueryTimeout

    if ($null -eq $databaseLookupResult) {
        if ([string]::IsNullOrWhiteSpace($script:LastSqlQueryError)) {
            [void]$collectionIssues.Add([pscustomobject]@{
                ServerName = $server
                DatabaseName = $DatabaseName
                Status = "Database not found"
                Error = ""
            })
            continue
        }

        [void]$collectionIssues.Add([pscustomobject]@{
            ServerName = $server
            DatabaseName = $DatabaseName
            Status = "Collection failed"
            Error = $script:LastSqlQueryError
        })
        continue
    }

    $databaseLookupRows = @($databaseLookupResult)
    if ($databaseLookupRows.Count -eq 0) {
        [void]$collectionIssues.Add([pscustomobject]@{
            ServerName = $server
            DatabaseName = $DatabaseName
            Status = "Database not found"
            Error = ""
        })
        continue
    }

    $databaseInfo = $databaseLookupRows[0]
    $actualDatabaseName = [string]$databaseInfo.DatabaseName
    if ($databaseInfo.HasDbAccess -ne 1) {
        [void]$collectionIssues.Add([pscustomobject]@{
            ServerName = $server
            DatabaseName = $actualDatabaseName
            Status = "Database inaccessible"
            Error = "State=$($databaseInfo.DatabaseState); HAS_DBACCESS=$($databaseInfo.HasDbAccess)"
        })
        continue
    }

    $queryResult = Invoke-SqlQuerySafe -ServerInstance $server -Database $actualDatabaseName -Query $collectionQuery -QueryTimeout $QueryTimeout

    if ($null -eq $queryResult) {
        if ([string]::IsNullOrWhiteSpace($script:LastSqlQueryError)) {
            [void]$collectionIssues.Add([pscustomobject]@{
                ServerName = $server
                DatabaseName = $actualDatabaseName
                Status = "No eligible tables found"
                Error = ""
            })
            continue
        }

        [void]$collectionIssues.Add([pscustomobject]@{
            ServerName = $server
            DatabaseName = $actualDatabaseName
            Status = "Collection failed"
            Error = $script:LastSqlQueryError
        })
        continue
    }

    $rows = @($queryResult)
    if ($rows.Count -eq 0) {
        [void]$collectionIssues.Add([pscustomobject]@{
            ServerName = $server
            DatabaseName = $actualDatabaseName
            Status = "No eligible tables found"
            Error = ""
        })
        continue
    }

    foreach ($row in $rows) {
        [void]$eligibleTables.Add([pscustomobject]@{
            ServerName = $server
            DatabaseName = $row.DatabaseName
            SchemaName = $row.SchemaName
            TableName = $row.TableName
            RowCounts = $row.RowCounts
            TotalSpaceMB = $row.TotalSpaceMB
            UsedSpaceMB = $row.UsedSpaceMB
            DatabaseMB = $row.DatabaseMB
        })
    }

    Write-Host "  Eligible table rows: $($eligibleTables.Count)" -ForegroundColor DarkGray
}

$reportDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$reportSuffix = Get-Date -Format 'yyyyMMdd_HHmmss'
$reportFile = Join-Path $OutputPath "CMS_DBA_LargeTables_$reportSuffix.html"

$eligibleRows = @($eligibleTables | Sort-Object ServerName, @{ Expression = 'UsedSpaceMB'; Descending = $true })
$issueRows = @($collectionIssues | Sort-Object ServerName)

$totalUsedSpace = if ($eligibleRows.Count -gt 0) {
    [math]::Round((($eligibleRows | Measure-Object -Property UsedSpaceMB -Sum).Sum), 2)
}
else {
    0
}

$eligibleTableHtml = ConvertTo-HtmlTable -Data $eligibleRows -EmptyMessage "No tables were at or above $MinUsedSpaceMB MB used space."
$issueTableHtml = ConvertTo-HtmlTable -Data $issueRows -EmptyMessage "No collection issues."

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>$Subject</title>
<style>
    body { font-family: Segoe UI, Arial, sans-serif; color: #1f2933; background: #f5f7fa; margin: 0; padding: 24px; }
    h1 { margin: 0 0 8px 0; color: #102a43; font-size: 26px; }
    h2 { margin: 28px 0 12px 0; color: #243b53; font-size: 20px; }
    .meta { color: #52606d; margin-bottom: 20px; }
    .summary { display: flex; flex-wrap: wrap; gap: 12px; margin: 18px 0 26px 0; }
    .card { background: #ffffff; border: 1px solid #d9e2ec; border-radius: 6px; padding: 14px 16px; min-width: 180px; }
    .card .number { font-size: 24px; font-weight: 700; color: #0b7285; }
    .card .label { color: #52606d; font-size: 13px; margin-top: 2px; }
    table { width: 100%; border-collapse: collapse; background: #ffffff; border: 1px solid #d9e2ec; font-size: 13px; }
    th { background: #334e68; color: #ffffff; padding: 8px 10px; text-align: left; white-space: nowrap; }
    td { padding: 7px 10px; border-top: 1px solid #d9e2ec; }
    tr:nth-child(even) td { background: #f8fafc; }
    .empty { color: #7b8794; background: #ffffff; border: 1px solid #d9e2ec; padding: 12px; }
    .note { color: #52606d; font-size: 13px; margin-top: 10px; }
</style>
</head>
<body>
<h1>SQL Server DBA Large Tables Report</h1>
<div class="meta">
    Server Source: <strong>$([System.Net.WebUtility]::HtmlEncode($serverSource))</strong> |
    Database: <strong>$([System.Net.WebUtility]::HtmlEncode($DatabaseName))</strong> |
    Generated: <strong>$reportDate</strong>
</div>

<div class="summary">
    <div class="card"><div class="number">$($registeredServers.Count)</div><div class="label">Registered Servers Scanned</div></div>
    <div class="card"><div class="number">$($eligibleRows.Count)</div><div class="label">Eligible Tables Reported</div></div>
    <div class="card"><div class="number">$MinUsedSpaceMB</div><div class="label">Minimum Used Space MB</div></div>
    <div class="card"><div class="number">$Top</div><div class="label">Top Tables Per Server</div></div>
    <div class="card"><div class="number">$totalUsedSpace</div><div class="label">Reported Used Space MB</div></div>
</div>

<h2>Eligible Tables</h2>
$eligibleTableHtml
<div class="note">Each server returns only the top $Top tables from database $([System.Net.WebUtility]::HtmlEncode($DatabaseName)) where UsedSpaceMB is at least $MinUsedSpaceMB MB.</div>

<h2>Collection Issues / Servers Without Eligible Tables</h2>
$issueTableHtml
</body>
</html>
"@

$html | Out-File -FilePath $reportFile -Encoding UTF8
Write-Host "Report saved to: $reportFile" -ForegroundColor Green

$csvBase = Join-Path $OutputPath "CMS_DBA_LargeTables_$reportSuffix"
if ($eligibleRows.Count -gt 0) {
    $eligibleRows | Export-Csv "$($csvBase)_EligibleTables.csv" -NoTypeInformation
}
if ($issueRows.Count -gt 0) {
    $issueRows | Export-Csv "$($csvBase)_CollectionIssues.csv" -NoTypeInformation
}
Write-Host "CSV files exported to: $csvBase*.csv" -ForegroundColor Green

if (-not [string]::IsNullOrWhiteSpace($SmtpServer)) {
    Write-Host "Sending email report..." -ForegroundColor Yellow
    Send-HtmlReport -Html $html -ReportFile $reportFile
    Write-Host "Email report sent." -ForegroundColor Green
}

Write-Host "Eligible tables reported: $($eligibleRows.Count)" -ForegroundColor Green
