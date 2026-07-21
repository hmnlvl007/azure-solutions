# Get-CMSDbaLargeTableReport.ps1

## Purpose

`Get-CMSDbaLargeTableReport.ps1` scans SQL Server instances from a Central Management Server (CMS), or from an Excel server list, and reports the largest eligible tables in the `DBA` database.

By default, it returns the top 5 tables per SQL Server where `UsedSpaceMB` is at least `1024` MB.

## Requirements

- Windows PowerShell
- `dbatools` PowerShell module
- Access to the CMS server or Excel server list
- Access to query the target SQL Server instances
- Optional: `ImportExcel` module when using `-ExcelFilePath`
- Optional: SMTP relay if emailing the report

Install dbatools if needed:

```powershell
Install-Module dbatools -Scope CurrentUser
```

## Authentication

By default, the script uses the current Windows account running PowerShell.

If your SSMS connection uses SQL authentication or a different account, pass a SQL credential:

```powershell
$cred = Get-Credential
```

Then include:

```powershell
-SqlCredential $cred
```

## Basic CMS Run

```powershell
.\Get-CMSDbaLargeTableReport.ps1 `
  -CMSServer "Your-CMS-Server" `
  -OutputPath "C:\Temp\Reports" `
  -SkipCertValidation
```

## Run With SQL Credential

```powershell
$cred = Get-Credential

.\Get-CMSDbaLargeTableReport.ps1 `
  -CMSServer "Your-CMS-Server" `
  -OutputPath "C:\Temp\Reports" `
  -SkipCertValidation `
  -SqlCredential $cred
```

## Run From Excel Server List

The Excel file must have a server-name column. The default column name is `ServerName`.

```powershell
.\Get-CMSDbaLargeTableReport.ps1 `
  -ExcelFilePath "C:\Servers\ServerList.xlsx" `
  -OutputPath "C:\Temp\Reports" `
  -SkipCertValidation
```

If the column is named something else:

```powershell
.\Get-CMSDbaLargeTableReport.ps1 `
  -ExcelFilePath "C:\Servers\ServerList.xlsx" `
  -ServerColumn "SQLInstance" `
  -OutputPath "C:\Temp\Reports" `
  -SkipCertValidation
```

## Email Report

```powershell
.\Get-CMSDbaLargeTableReport.ps1 `
  -CMSServer "Your-CMS-Server" `
  -OutputPath "C:\Temp\Reports" `
  -SkipCertValidation `
  -SmtpServer "smtp.yourcompany.com" `
  -From "sqlreports@yourcompany.com" `
  -To "dba-team@yourcompany.com"
```

The email body is HTML, and the HTML report is also attached.

## Useful Parameters

`-DatabaseName`

Target database name. Defaults to `DBA`. The script attempts a case-insensitive match and reports the actual matched database name.

`-MinUsedSpaceMB`

Minimum used space required for a table to appear in the report. Defaults to `1024`.

`-Top`

Maximum number of eligible tables returned per SQL Server. Defaults to `5`.

`-QueryTimeout`

Per-server query timeout in seconds. Defaults to `120`.

`-SkipCertValidation`

Uses dbatools trust-certificate/insecure connection settings for SQL Server connections.

`-SqlCredential`

Optional SQL credential for CMS discovery and SQL Server queries, when supported by the installed dbatools version.

## Output Files

The script creates files under `-OutputPath`:

- `CMS_DBA_LargeTables_yyyyMMdd_HHmmss.html`
- `CMS_DBA_LargeTables_yyyyMMdd_HHmmss_EligibleTables.csv`
- `CMS_DBA_LargeTables_yyyyMMdd_HHmmss_CollectionIssues.csv`

The HTML report contains:

- Summary cards
- Eligible tables
- Collection issues and servers without eligible tables

## Report Columns

Eligible table rows include:

- `ServerName`
- `DatabaseName`
- `SchemaName`
- `TableName`
- `RowCounts`
- `TotalSpaceMB`
- `UsedSpaceMB`
- `DatabaseMB`

## Collection Issue Meanings

`Database not found`

The server was reachable, but the target database name was not found.

`Database inaccessible`

The database was found, but `HAS_DBACCESS` did not return `1`.

`No eligible tables found`

The database was queried successfully, but no table met the `-MinUsedSpaceMB` threshold.

`Collection failed`

The query threw an error. Check the `Error` column in the collection issues CSV for the actual exception.

## Common Troubleshooting

If many servers show collection failures, check whether the script is using the same credentials as SSMS.

If SSMS uses SQL authentication, run with `-SqlCredential`.

If certificate or encryption errors appear, use `-SkipCertValidation`.

If servers are slow, increase `-QueryTimeout`.

If most rows say `No eligible tables found`, the script is working, but those servers do not have tables at or above the threshold.
