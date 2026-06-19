[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('SetupCredential', 'LoadPrep', 'Validate')]
    [string]$Action,

    [Parameter(Position = 1)]
    [ValidateSet('Dev', 'IT', 'Prod', 'All')]
    [string]$Environment = 'Dev',

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'ZipCodeMaintenance.config.json'),
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
        return $table
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

function Save-EnvironmentCredential {
    param(
        [pscustomobject]$Config,
        [string]$EnvironmentName
    )

    if ($EnvironmentName -eq 'All') {
        foreach ($name in @('Dev', 'IT', 'Prod')) {
            Save-EnvironmentCredential -Config $Config -EnvironmentName $name
        }
        return
    }

    $envConfig = $Config.Environments.$EnvironmentName
    if ($null -eq $envConfig) {
        throw "Environment '$EnvironmentName' is not defined in $ConfigPath."
    }

    if ($envConfig.IntegratedSecurity) {
        Write-Host "$EnvironmentName uses Integrated Security. No saved credential is needed."
        return
    }

    $credentialFile = Get-CredentialFilePath -Config $Config -EnvironmentName $EnvironmentName
    $credentialDirectory = Split-Path -Parent $credentialFile
    if (-not (Test-Path -LiteralPath $credentialDirectory)) {
        New-Item -ItemType Directory -Path $credentialDirectory | Out-Null
    }

    $credential = Get-Credential -Message "Enter the SQL credential for $EnvironmentName ($($envConfig.Server)\$($envConfig.Database)). It will be DPAPI-encrypted for this Windows user."
    $credential | Export-Clixml -LiteralPath $credentialFile
    Write-Host "Saved encrypted credential for $EnvironmentName to $credentialFile"
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
            return
        }
    }

    if ($PSCmdlet.ShouldProcess("$EnvironmentName $sourceTable", "Back up to $backupTable and delete all rows")) {
        $result = Invoke-SqlDataTable -ConnectionString $connectionString -CommandText $sql
        $result | Format-Table -AutoSize
        Write-Host "$EnvironmentName is ready to load new data. Backup table: $schemaName.$backupName"
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
        $backupTableName = Get-LatestBackupTableName -ConnectionString $connectionString -SchemaName $schemaName -BackupTablePrefix $Config.BackupTablePrefix
    }
    elseif ($backupTableName.Contains('.')) {
        $backupTableName = $backupTableName.Split('.')[-1].Trim('[', ']')
    }

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

    [pscustomobject]@{
        EnvironmentName = $EnvironmentName
        BackupTable     = "$schemaName.$backupTableName"
        NewRows         = Invoke-SqlDataTable -ConnectionString $connectionString -CommandText $newSql
        DeletedRows     = Invoke-SqlDataTable -ConnectionString $connectionString -CommandText $deletedSql
    }
}

function Add-WorksheetFromDataTable {
    param(
        [object]$Workbook,
        [string]$WorksheetName,
        [System.Data.DataTable]$Table
    )

    $worksheet = $Workbook.Worksheets.Add()
    $worksheet.Name = $WorksheetName

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

function Export-ValidationWorkbook {
    param(
        [pscustomobject[]]$ValidationData,
        [string]$Path
    )

    $excel = $null
    $workbook = $null

    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        $workbook = $excel.Workbooks.Add()

        while ($workbook.Worksheets.Count -gt 1) {
            $workbook.Worksheets.Item(1).Delete()
        }

        foreach ($envName in @('Prod', 'IT', 'Dev')) {
            $data = $ValidationData | Where-Object { $_.EnvironmentName -eq $envName } | Select-Object -First 1
            if ($null -eq $data) {
                continue
            }

            Add-WorksheetFromDataTable -Workbook $workbook -WorksheetName "$($envName)Deleted" -Table $data.DeletedRows
            Add-WorksheetFromDataTable -Workbook $workbook -WorksheetName "$($envName)New" -Table $data.NewRows
        }

        if ($workbook.Worksheets.Count -gt 6) {
            $workbook.Worksheets.Item($workbook.Worksheets.Count).Delete()
        }

        $directory = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory | Out-Null
        }

        $workbook.SaveAs($Path, 51)
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

$config = Read-JsonConfig -Path $ConfigPath

switch ($Action) {
    'SetupCredential' {
        Save-EnvironmentCredential -Config $config -EnvironmentName $Environment
    }

    'LoadPrep' {
        if ($Environment -eq 'All') {
            throw 'LoadPrep requires one environment: Dev, IT, or Prod.'
        }

        Invoke-LoadPrep -Config $config -EnvironmentName $Environment
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

        Export-ValidationWorkbook -ValidationData $data -Path $OutputPath

        foreach ($item in $data) {
            Write-Host ("{0}: Backup={1}; New={2}; Deleted={3}" -f $item.EnvironmentName, $item.BackupTable, $item.NewRows.Rows.Count, $item.DeletedRows.Rows.Count)
        }

        Write-Host "Validation workbook created: $OutputPath"
    }
}
