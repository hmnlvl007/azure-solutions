[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('SetupCredential', 'LoadPrep', 'Validate')]
    [string]$Action,

    [Parameter(Position = 1)]
    [ValidateSet('Dev', 'IT', 'Prod', 'All')]
    [string]$Environment = 'Dev',

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'ZipCodeMaintenance.config.json'),
    [Alias('OutputPtath')]
    [string]$OutputPath,
    [string]$BackupTable,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonConfig {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-EnvironmentNames {
    param([string]$RequestedEnvironment)

    if ($RequestedEnvironment -eq 'All') {
        return @('Dev', 'IT', 'Prod')
    }

    return @($RequestedEnvironment)
}

function Join-SqlName {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Parts)

    ($Parts | ForEach-Object { '[' + ($_ -replace ']', ']]') + ']' }) -join '.'
}

function Get-CredentialFilePath {
    param(
        [pscustomobject]$Config,
        [string]$EnvironmentName
    )

    $credentialDirectory = $Config.CredentialDirectory
    if (-not [System.IO.Path]::IsPathRooted($credentialDirectory)) {
        $credentialDirectory = Join-Path $PSScriptRoot $credentialDirectory
    }

    Join-Path $credentialDirectory "$EnvironmentName.credential.xml"
}

function Get-SqlConnectionString {
    param(
        [pscustomobject]$Config,
        [string]$EnvironmentName
    )

    $envConfig = $Config.Environments.$EnvironmentName
    if ($null -eq $envConfig) {
        throw "Environment '$EnvironmentName' is not defined in $ConfigPath."
    }

    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = $envConfig.Server
    $builder['Initial Catalog'] = $envConfig.Database
    $builder['Application Name'] = 'ZipCodeSelfServiceMaintenance'
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = $true

    if ($envConfig.IntegratedSecurity) {
        $builder['Integrated Security'] = $true
    }
    else {
        $credentialFile = Get-CredentialFilePath -Config $Config -EnvironmentName $EnvironmentName
        if (-not (Test-Path -LiteralPath $credentialFile)) {
            throw "Credential file not found for $EnvironmentName. Run: .\Invoke-ZipCodeMaintenance.ps1 SetupCredential $EnvironmentName"
        }

        $credential = Import-Clixml -LiteralPath $credentialFile
        $builder['User ID'] = $credential.UserName
        $builder['Password'] = $credential.GetNetworkCredential().Password
    }

    $builder.ConnectionString
}

function Invoke-SqlDataTable {
    param(
        [string]$ConnectionString,
        [string]$CommandText,
        [int]$CommandTimeout = 300
    )

    $connection = [System.Data.SqlClient.SqlConnection]::new($ConnectionString)
    $command = $connection.CreateCommand()
    $command.CommandText = $CommandText
    $command.CommandTimeout = $CommandTimeout
    $adapter = [System.Data.SqlClient.SqlDataAdapter]::new($command)
    $table = [System.Data.DataTable]::new()

    try {
        [void]$adapter.Fill($table)
        return ,$table
    }
    finally {
        $adapter.Dispose()
        $command.Dispose()
        $connection.Dispose()
    }
}

function Invoke-SqlNonQuery {
    param(
        [string]$ConnectionString,
        [string]$CommandText,
        [int]$CommandTimeout = 300
    )

    $connection = [System.Data.SqlClient.SqlConnection]::new($ConnectionString)
    $command = $connection.CreateCommand()
    $command.CommandText = $CommandText
    $command.CommandTimeout = $CommandTimeout

    try {
        $connection.Open()
        [void]$command.ExecuteNonQuery()
    }
    finally {
        $command.Dispose()
        $connection.Dispose()
    }
}

function ConvertTo-StringArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [array]) {
        return @($Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    }

    if ($Value -is [string]) {
        return @($Value.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    }

    return @([string]$Value)
}

function Get-OptionalPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Send-CompletionNotification {
    param(
        [pscustomobject]$Config,
        [string]$ActionName,
        [string]$EnvironmentName,
        [string]$Status = 'completed',
        [string[]]$DetailLines
    )

    $emailConfigProperty = $Config.PSObject.Properties['EmailNotification']
    if ($null -eq $emailConfigProperty) {
        return
    }

    $emailConfig = $emailConfigProperty.Value
    if ($null -eq $emailConfig -or -not (Get-OptionalPropertyValue -Object $emailConfig -Name 'Enabled' -DefaultValue $false)) {
        return
    }

    $to = ConvertTo-StringArray (Get-OptionalPropertyValue -Object $emailConfig -Name 'To')
    if ($to.Count -eq 0) {
        Write-Warning 'Email notification is enabled, but no recipients are configured.'
        return
    }

    $smtpServer = [string](Get-OptionalPropertyValue -Object $emailConfig -Name 'SmtpServer')
    $from = [string](Get-OptionalPropertyValue -Object $emailConfig -Name 'From')
    if ([string]::IsNullOrWhiteSpace($smtpServer) -or [string]::IsNullOrWhiteSpace($from)) {
        Write-Warning 'Email notification is enabled, but SmtpServer or From is missing.'
        return
    }

    $subjectPrefix = [string](Get-OptionalPropertyValue -Object $emailConfig -Name 'SubjectPrefix')
    if ([string]::IsNullOrWhiteSpace($subjectPrefix)) {
        $subjectPrefix = 'Zip Code Maintenance'
    }

    $subject = "$subjectPrefix - $ActionName $Status for $EnvironmentName"
    $bodyLines = @(
        "Action: $ActionName",
        "Environment: $EnvironmentName",
        "Status: $Status",
        "Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "User: $env:USERNAME",
        "Computer: $env:COMPUTERNAME"
    )

    if ($DetailLines.Count -gt 0) {
        $bodyLines += ''
        $bodyLines += $DetailLines
    }

    $mailParameters = @{
        SmtpServer = $smtpServer
        From       = $from
        To         = $to
        Subject    = $subject
        Body       = ($bodyLines -join [Environment]::NewLine)
    }

    $port = Get-OptionalPropertyValue -Object $emailConfig -Name 'Port'
    if ($null -ne $port) {
        $mailParameters.Port = [int]$port
    }

    if (Get-OptionalPropertyValue -Object $emailConfig -Name 'UseSsl' -DefaultValue $false) {
        $mailParameters.UseSsl = $true
    }

    $cc = ConvertTo-StringArray (Get-OptionalPropertyValue -Object $emailConfig -Name 'Cc')
    if ($cc.Count -gt 0) {
        $mailParameters.Cc = $cc
    }

    try {
        Send-MailMessage @mailParameters
        Write-Host "Email notification sent to $($to -join ', ')."
    }
    catch {
        Write-Warning "Email notification failed: $($_.Exception.Message)"
    }
}

function Save-EnvironmentCredential {
    param(
        [pscustomobject]$Config,
        [string]$EnvironmentName
    )

    if ($EnvironmentName -eq 'All') {
        $results = foreach ($name in @('Dev', 'IT', 'Prod')) {
            Save-EnvironmentCredential -Config $Config -EnvironmentName $name
        }
        return ,$results
    }

    $envConfig = $Config.Environments.$EnvironmentName
    if ($null -eq $envConfig) {
        throw "Environment '$EnvironmentName' is not defined in $ConfigPath."
    }

    if ($envConfig.IntegratedSecurity) {
        Write-Host "$EnvironmentName uses Integrated Security. No saved credential is needed."
        return [pscustomobject]@{
            EnvironmentName = $EnvironmentName
            Status          = 'IntegratedSecurity'
            Server          = $envConfig.Server
            Database        = $envConfig.Database
            CredentialFile  = $null
        }
    }

    $credentialFile = Get-CredentialFilePath -Config $Config -EnvironmentName $EnvironmentName
    $credentialDirectory = Split-Path -Parent $credentialFile
    if (-not (Test-Path -LiteralPath $credentialDirectory)) {
        New-Item -ItemType Directory -Path $credentialDirectory | Out-Null
    }

    Write-Host "Enter the SQL credential for $EnvironmentName ($($envConfig.Server), database $($envConfig.Database))."
    Write-Host 'Use the SQL Server login name, not your Windows account, unless this SQL login is intentionally mapped that way.'
    Write-Host 'The password will be masked and DPAPI-encrypted for this Windows user.'

    $userName = Read-Host 'SQL login'
    if ([string]::IsNullOrWhiteSpace($userName)) {
        throw 'SQL login is required.'
    }

    $password = Read-Host 'SQL password' -AsSecureString
    $credential = [System.Management.Automation.PSCredential]::new($userName, $password)
    $credential | Export-Clixml -LiteralPath $credentialFile
    Write-Host "Saved encrypted credential for $EnvironmentName to $credentialFile"

    [pscustomobject]@{
        EnvironmentName = $EnvironmentName
        Status          = 'Saved'
        Server          = $envConfig.Server
        Database        = $envConfig.Database
        CredentialFile  = $credentialFile
    }
}

function Invoke-LoadPrep {
    param(
        [pscustomobject]$Config,
        [string]$EnvironmentName
    )

    $connectionString = Get-SqlConnectionString -Config $Config -EnvironmentName $EnvironmentName
    $schemaName = $Config.SchemaName
    $tableName = $Config.TableName
    $sourceTable = Join-SqlName $schemaName $tableName
    $backupName = '{0}_{1}' -f $Config.BackupTablePrefix, (Get-Date -Format 'yyyyMMdd_HHmmss')
    $backupTable = Join-SqlName $schemaName $backupName

    $sql = @"
SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF OBJECT_ID(N'$schemaName.$backupName', N'U') IS NOT NULL
BEGIN
    THROW 50001, 'Backup table already exists. Retry with a new timestamp.', 1;
END;

SELECT *
INTO $backupTable
FROM $sourceTable;

DECLARE @BackedUpRows int = @@ROWCOUNT;

DELETE FROM $sourceTable;

DECLARE @DeletedRows int = @@ROWCOUNT;

COMMIT TRANSACTION;

SELECT
    '$EnvironmentName' AS EnvironmentName,
    '$schemaName.$backupName' AS BackupTable,
    @BackedUpRows AS BackedUpRows,
    @DeletedRows AS DeletedRows;
"@

    if (-not $Force) {
        Write-Warning "LoadPrep will back up and then DELETE all rows from $EnvironmentName $sourceTable."
        $confirmation = Read-Host "Type $EnvironmentName to continue"
        if ($confirmation -ne $EnvironmentName) {
            Write-Host 'Load prep cancelled.'
            return [pscustomobject]@{
                EnvironmentName = $EnvironmentName
                Status          = 'Cancelled'
            }
        }
    }

    if ($PSCmdlet.ShouldProcess("$EnvironmentName $sourceTable", "Back up to $backupTable and delete all rows")) {
        $result = Invoke-SqlDataTable -ConnectionString $connectionString -CommandText $sql
        $result | Format-Table -AutoSize
        Write-Host "$EnvironmentName is ready to load new data. Backup table: $schemaName.$backupName"

        return [pscustomobject]@{
            EnvironmentName = $EnvironmentName
            Status          = 'Completed'
            SourceTable     = "$schemaName.$tableName"
            BackupTable     = "$schemaName.$backupName"
            BackedUpRows    = $result.Rows[0]['BackedUpRows']
            DeletedRows     = $result.Rows[0]['DeletedRows']
        }
    }

    [pscustomobject]@{
        EnvironmentName = $EnvironmentName
        Status          = 'Skipped'
    }
}

function Get-TableColumnNames {
    param(
        [string]$ConnectionString,
        [string]$SchemaName,
        [string]$TableName
    )

    $sql = @"
SELECT c.name
FROM sys.columns c
INNER JOIN sys.tables t ON c.object_id = t.object_id
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE s.name = N'$SchemaName'
  AND t.name = N'$TableName'
  AND c.is_computed = 0
ORDER BY c.column_id;
"@

    $table = Invoke-SqlDataTable -ConnectionString $ConnectionString -CommandText $sql
    if ($table.Rows.Count -eq 0) {
        throw "No columns found for $SchemaName.$TableName."
    }

    @($table.Rows | ForEach-Object { [string]$_['name'] })
}

function Get-LatestBackupTableName {
    param(
        [string]$ConnectionString,
        [string]$SchemaName,
        [string]$BackupTablePrefix
    )

    $sql = @"
SELECT TOP (1) t.name
FROM sys.tables t
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE s.name = N'$SchemaName'
  AND t.name LIKE N'$BackupTablePrefix[_]%'
ORDER BY t.create_date DESC;
"@

    $table = Invoke-SqlDataTable -ConnectionString $ConnectionString -CommandText $sql
    if ($table.Rows.Count -eq 0) {
        throw "No backup table found for $SchemaName.$BackupTablePrefix*. Run LoadPrep first, or pass -BackupTable."
    }

    [string]$table.Rows[0]['name']
}

function Get-ValidationData {
    param(
        [pscustomobject]$Config,
        [string]$EnvironmentName,
        [string]$RequestedBackupTable
    )

    $connectionString = Get-SqlConnectionString -Config $Config -EnvironmentName $EnvironmentName
    $schemaName = $Config.SchemaName
    $currentTableName = $Config.TableName
    $backupTableName = $RequestedBackupTable

    if ([string]::IsNullOrWhiteSpace($backupTableName)) {
        Write-Host "Finding latest backup table for $EnvironmentName..."
        $backupTableName = Get-LatestBackupTableName -ConnectionString $connectionString -SchemaName $schemaName -BackupTablePrefix $Config.BackupTablePrefix
    }
    elseif ($backupTableName.Contains('.')) {
        $backupTableName = $backupTableName.Split('.')[-1].Trim('[', ']')
    }

    Write-Host "Using backup table $schemaName.$backupTableName for $EnvironmentName."
    Write-Host "Reading column list for $schemaName.$currentTableName..."
    $columns = Get-TableColumnNames -ConnectionString $connectionString -SchemaName $schemaName -TableName $currentTableName
    $selectColumns = ($columns | ForEach-Object { 'src.' + (Join-SqlName $_) }) -join ', '
    $keyPredicateCurrentMissing = ($Config.KeyColumns | ForEach-Object {
        'cur.' + (Join-SqlName $_) + ' IS NULL'
    }) -join ' AND '
    $keyPredicateBackupMissing = ($Config.KeyColumns | ForEach-Object {
        'bak.' + (Join-SqlName $_) + ' IS NULL'
    }) -join ' AND '
    $joinPredicate = ($Config.KeyColumns | ForEach-Object {
        'cur.' + (Join-SqlName $_) + ' = bak.' + (Join-SqlName $_)
    }) -join ' AND '
    $newJoinPredicate = ($Config.KeyColumns | ForEach-Object {
        'src.' + (Join-SqlName $_) + ' = bak.' + (Join-SqlName $_)
    }) -join ' AND '
    $deletedJoinPredicate = ($Config.KeyColumns | ForEach-Object {
        'cur.' + (Join-SqlName $_) + ' = src.' + (Join-SqlName $_)
    }) -join ' AND '
    $orderByColumns = ($Config.KeyColumns | ForEach-Object {
        'src.' + (Join-SqlName $_)
    }) -join ', '

    $currentTable = Join-SqlName $schemaName $currentTableName
    $backupTable = Join-SqlName $schemaName $backupTableName

    $newSql = @"
SELECT $selectColumns
FROM $currentTable src
LEFT JOIN $backupTable bak ON $newJoinPredicate
WHERE $keyPredicateBackupMissing
ORDER BY $orderByColumns;
"@

    $deletedSql = @"
SELECT $selectColumns
FROM $backupTable src
LEFT JOIN $currentTable cur ON $deletedJoinPredicate
    WHERE $keyPredicateCurrentMissing
ORDER BY $orderByColumns;
"@

    Write-Host "Checking new rows for $EnvironmentName..."
    $newRows = Invoke-SqlDataTable -ConnectionString $connectionString -CommandText $newSql
    Write-Host "Checking deleted rows for $EnvironmentName..."
    $deletedRows = Invoke-SqlDataTable -ConnectionString $connectionString -CommandText $deletedSql

    [pscustomobject]@{
        EnvironmentName = $EnvironmentName
        BackupTable     = "$schemaName.$backupTableName"
        NewRows         = $newRows
        DeletedRows     = $deletedRows
    }
}

function Get-WorksheetByName {
    param(
        [object]$Workbook,
        [string]$WorksheetName
    )

    foreach ($worksheet in $Workbook.Worksheets) {
        if ($worksheet.Name -eq $WorksheetName) {
            return $worksheet
        }
    }

    return $null
}

function Remove-WorksheetByName {
    param(
        [object]$Workbook,
        [string]$WorksheetName
    )

    $worksheet = Get-WorksheetByName -Workbook $Workbook -WorksheetName $WorksheetName
    if ($null -eq $worksheet) {
        return
    }

    if ($Workbook.Worksheets.Count -eq 1) {
        [void]$Workbook.Worksheets.Add()
    }

    $worksheet.Delete()
}

function Add-WorksheetFromDataTable {
    param(
        [object]$Workbook,
        [string]$WorksheetName,
        [System.Data.DataTable]$Table
    )

    $worksheet = $Workbook.Worksheets.Add()
    $worksheet.Name = $WorksheetName
    Write-Host "Writing worksheet $WorksheetName..."

    for ($columnIndex = 0; $columnIndex -lt $Table.Columns.Count; $columnIndex++) {
        $worksheet.Cells.Item(1, $columnIndex + 1) = $Table.Columns[$columnIndex].ColumnName
        $worksheet.Cells.Item(1, $columnIndex + 1).Font.Bold = $true
    }

    for ($rowIndex = 0; $rowIndex -lt $Table.Rows.Count; $rowIndex++) {
        for ($columnIndex = 0; $columnIndex -lt $Table.Columns.Count; $columnIndex++) {
            $worksheet.Cells.Item($rowIndex + 2, $columnIndex + 1) = [string]$Table.Rows[$rowIndex][$columnIndex]
        }
    }

    if ($Table.Columns.Count -gt 0) {
        $usedRange = $worksheet.UsedRange
        [void]$usedRange.Columns.AutoFit()
        [void]$worksheet.ListObjects.Add(1, $usedRange, $null, 1)
    }
}

function Remove-BlankWorksheets {
    param([object]$Workbook)

    foreach ($worksheet in @($Workbook.Worksheets)) {
        if ($Workbook.Worksheets.Count -eq 1) {
            break
        }

        $usedRange = $worksheet.UsedRange
        if ($usedRange.Rows.Count -eq 1 -and
            $usedRange.Columns.Count -eq 1 -and
            [string]::IsNullOrWhiteSpace([string]$usedRange.Cells.Item(1, 1).Text)) {
            $worksheet.Delete()
        }
    }
}

function Set-WorksheetOrder {
    param([object]$Workbook)

    $orderedNames = @(
        'DevNew',
        'DevDeleted',
        'ITNew',
        'ITDeleted',
        'ProdNew',
        'ProdDeleted'
    )

    for ($index = $orderedNames.Count - 1; $index -ge 0; $index--) {
        $worksheet = Get-WorksheetByName -Workbook $Workbook -WorksheetName $orderedNames[$index]
        if ($null -ne $worksheet) {
            $worksheet.Move($Workbook.Worksheets.Item(1))
        }
    }
}

function Export-ValidationWorkbook {
    param(
        [pscustomobject[]]$ValidationData,
        [string]$Path
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $excel = $null
    $workbook = $null

    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false

        $directory = Split-Path -Parent $resolvedPath
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory | Out-Null
        }

        Write-Host "Writing validation workbook: $resolvedPath"
        if (Test-Path -LiteralPath $resolvedPath) {
            $workbook = $excel.Workbooks.Open($resolvedPath)
        }
        else {
            $workbook = $excel.Workbooks.Add()
        }

        if ($workbook.ReadOnly) {
            throw "Workbook is read-only or locked by another process: $resolvedPath. Close it in Excel and rerun Validate."
        }

        foreach ($envName in @('Dev', 'IT', 'Prod')) {
            $data = $ValidationData | Where-Object { $_.EnvironmentName -eq $envName } | Select-Object -First 1
            if ($null -eq $data) {
                continue
            }

            Remove-WorksheetByName -Workbook $workbook -WorksheetName "$($envName)New"
            Remove-WorksheetByName -Workbook $workbook -WorksheetName "$($envName)Deleted"
            Add-WorksheetFromDataTable -Workbook $workbook -WorksheetName "$($envName)New" -Table $data.NewRows
            Add-WorksheetFromDataTable -Workbook $workbook -WorksheetName "$($envName)Deleted" -Table $data.DeletedRows
        }

        Set-WorksheetOrder -Workbook $workbook
        Remove-BlankWorksheets -Workbook $workbook

        if (Test-Path -LiteralPath $resolvedPath) {
            $workbook.Save()
        }
        else {
            $workbook.SaveAs($resolvedPath, 51)
        }

        $sheetNames = @($workbook.Worksheets | ForEach-Object { $_.Name }) -join ', '
        Write-Host "Workbook sheets: $sheetNames"
        return $resolvedPath
    }
    finally {
        if ($null -ne $workbook) {
            $workbook.Close($false)
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($workbook) | Out-Null
        }

        if ($null -ne $excel) {
            $excel.Quit()
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
        }

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

$config = $null

try {
    $config = Read-JsonConfig -Path $ConfigPath

    switch ($Action) {
        'SetupCredential' {
            $credentialResults = @(Save-EnvironmentCredential -Config $config -EnvironmentName $Environment)
            $detailLines = foreach ($item in $credentialResults) {
                if ($null -eq $item) {
                    continue
                }

                if ($item.Status -eq 'Saved') {
                    "Credential saved for $($item.EnvironmentName): $($item.Server), database $($item.Database)"
                }
                elseif ($item.Status -eq 'IntegratedSecurity') {
                    "$($item.EnvironmentName) uses Integrated Security; no credential file was needed."
                }
            }

            Send-CompletionNotification -Config $config -ActionName 'SetupCredential' -EnvironmentName $Environment -DetailLines $detailLines
        }

        'LoadPrep' {
            if ($Environment -eq 'All') {
                throw 'LoadPrep requires one environment: Dev, IT, or Prod.'
            }

            $loadResult = Invoke-LoadPrep -Config $config -EnvironmentName $Environment
            if ($null -ne $loadResult -and $loadResult.Status -eq 'Completed') {
                $detailLines = @(
                    "Source table: $($loadResult.SourceTable)",
                    "Backup table: $($loadResult.BackupTable)",
                    "Backed up rows: $($loadResult.BackedUpRows)",
                    "Deleted rows: $($loadResult.DeletedRows)"
                )

                Send-CompletionNotification -Config $config -ActionName 'LoadPrep' -EnvironmentName $Environment -DetailLines $detailLines
            }
        }

        'Validate' {
            $envNames = Get-EnvironmentNames -RequestedEnvironment $Environment
            $data = foreach ($envName in $envNames) {
                Write-Host "Collecting validation data for $envName..."
                Get-ValidationData -Config $config -EnvironmentName $envName -RequestedBackupTable $BackupTable
            }

            if ([string]::IsNullOrWhiteSpace($OutputPath)) {
                $outputDirectory = $config.OutputDirectory
                if (-not [System.IO.Path]::IsPathRooted($outputDirectory)) {
                    $outputDirectory = Join-Path $PSScriptRoot $outputDirectory
                }

                $OutputPath = Join-Path $outputDirectory ('ZipCodeChanges{0}.xlsx' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            }

            $savedOutputPath = Export-ValidationWorkbook -ValidationData $data -Path $OutputPath

            foreach ($item in $data) {
                Write-Host ("{0}: Backup={1}; New={2}; Deleted={3}" -f $item.EnvironmentName, $item.BackupTable, $item.NewRows.Rows.Count, $item.DeletedRows.Rows.Count)
            }

            Write-Host "Validation workbook created: $savedOutputPath"

            $detailLines = @("Workbook: $savedOutputPath")
            $detailLines += foreach ($item in $data) {
                "$($item.EnvironmentName): Backup=$($item.BackupTable); New=$($item.NewRows.Rows.Count); Deleted=$($item.DeletedRows.Rows.Count)"
            }

            Send-CompletionNotification -Config $config -ActionName 'Validate' -EnvironmentName $Environment -DetailLines $detailLines
        }
    }
}
catch {
    if ($null -ne $config) {
        $detailLines = @(
            "Error: $($_.Exception.Message)",
            "Script: $($MyInvocation.MyCommand.Path)"
        )

        Send-CompletionNotification -Config $config -ActionName $Action -EnvironmentName $Environment -Status 'failed' -DetailLines $detailLines
    }

    throw
}
