# Zip Code Maintenance PowerShell

This adds a PowerShell wrapper for the self-service zip code workflow.

## One-time setup

1. Edit `ZipCodeMaintenance.config.json`.
2. Set the real `Server`, `Database`, `SchemaName`, `TableName`, and `KeyColumns`.
3. Store credentials once per environment:

```powershell
.\Invoke-ZipCodeMaintenance.ps1 SetupCredential Dev
.\Invoke-ZipCodeMaintenance.ps1 SetupCredential IT
.\Invoke-ZipCodeMaintenance.ps1 SetupCredential Prod
```

The credential files are written under `.secrets` and encrypted with Windows DPAPI for the current Windows user on this computer. Users do not need to enter SQL credentials during normal runs.

When prompted, enter the SQL Server login name and password for that environment. The password prompt is masked in the console.

If an environment uses Windows authentication, set `IntegratedSecurity` to `true` in the config and skip `SetupCredential` for that environment.

## Email notifications

Email notification is optional and disabled by default. To enable it, edit `EmailNotification` in `ZipCodeMaintenance.config.json`:

```json
"EmailNotification": {
  "Enabled": true,
  "SmtpServer": "smtp.yourcompany.com",
  "Port": 25,
  "UseSsl": false,
  "From": "zipcode-maintenance@yourcompany.com",
  "To": [
    "dba-team@yourcompany.com"
  ],
  "Cc": [],
  "SubjectPrefix": "Zip Code Maintenance"
}
```

The script sends a completion email after these successful actions:

- `SetupCredential`: environment and SQL target
- `LoadPrep`: source table, backup table, backed-up row count, and deleted row count
- `Validate`: workbook path plus `New` and `Deleted` counts by environment

If one of these actions fails after the config is loaded, the script sends a failure email with the error message and still writes the normal PowerShell error to the console.

## Load prep

Backs up the current table with SQL Server `SELECT INTO`, deletes all rows from the live table, and prints the backup table name.

```powershell
.\Invoke-ZipCodeMaintenance.ps1 LoadPrep Dev
```

Use `IT` or `Prod` for the other environments.

## Validation report

Compares the latest backup table created by `LoadPrep` to the newly loaded live table and creates an Excel workbook.

```powershell
.\Invoke-ZipCodeMaintenance.ps1 Validate All
```

The workbook contains these tabs when all environments are selected:

- `DevNew`
- `DevDeleted`
- `ITNew`
- `ITDeleted`
- `ProdNew`
- `ProdDeleted`

To validate one environment:

```powershell
.\Invoke-ZipCodeMaintenance.ps1 Validate Dev
```

To accumulate environment tabs into the same workbook, pass the same `-OutputPath` for each environment:

```powershell
$report = 'C:\Temp\ZipCodeReports\ZipCodeChanges20260618.xlsx'
.\Invoke-ZipCodeMaintenance.ps1 Validate Dev -OutputPath $report
.\Invoke-ZipCodeMaintenance.ps1 Validate IT -OutputPath $report
.\Invoke-ZipCodeMaintenance.ps1 Validate Prod -OutputPath $report
```

If the workbook already exists, the script replaces only the selected environment's `New` and `Deleted` tabs and leaves the other environment tabs in place.

Close the workbook in Excel before running validation. Excel can lock the file while it is open.

To compare against a specific backup table:

```powershell
.\Invoke-ZipCodeMaintenance.ps1 Validate Dev -BackupTable dbo.ZipCodes_Backup_20260619_101500
```
