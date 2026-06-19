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

If an environment uses Windows authentication, set `IntegratedSecurity` to `true` in the config and skip `SetupCredential` for that environment.

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

To compare against a specific backup table:

```powershell
.\Invoke-ZipCodeMaintenance.ps1 Validate Dev -BackupTable dbo.ZipCodes_Backup_20260619_101500
```

