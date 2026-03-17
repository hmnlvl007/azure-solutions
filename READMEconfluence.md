# Confluence Space to PDF (OneDrive/SharePoint Ready)

This setup exports every page from a Confluence space as individual PDFs using Confluence's own PDF rendering endpoint, then saves them to a OneDrive-synced folder.

## Why this is the best practical approach

- Uses native Confluence PDF generation (`flyingpdf`) for best fidelity (tables, images, hyperlinks, page formatting).
- Produces one PDF per page, which works well for SharePoint indexing and Copilot retrieval.
- Drops files directly into OneDrive, which syncs to SharePoint automatically.

## Files

- `scripts/export-confluence-space-pdf.ps1` - main exporter.
- `scripts/run-confluence-export.ps1` - config wrapper for manual/scheduled runs.

## Prerequisites

1. Confluence Cloud account with read access to the target space.
2. Atlassian API token (create at: https://id.atlassian.com/manage-profile/security/api-tokens).
3. OneDrive sync client installed and signed in.

## One-time setup

1. Open `scripts/run-confluence-export.ps1`.
2. Set these values in `$config`:
   - `ConfluenceBaseUrl` (example: `https://your-company.atlassian.net`)
   - `SpaceKey` (example: `DBA`)
   - `Email`
   - `OutputPath` (your local OneDrive folder path)
3. Set API token in user environment variable (PowerShell):

```powershell
[Environment]::SetEnvironmentVariable('CONFLUENCE_API_TOKEN', 'paste-token-here', 'User')
```

Restart terminal after setting this.

## Run manually

From the workspace root (`c:\MCP`):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-confluence-export.ps1
```

PDFs are saved under:

- `<OutputPath>\<SpaceKey>\`

A JSON run summary is also written there (`export-summary-*.json`).

## Schedule nightly export (Windows Task Scheduler)

Create a daily task at 1:00 AM:

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "c:\MCP\scripts\run-confluence-export.ps1"'
$trigger = New-ScheduledTaskTrigger -Daily -At 1:00am
Register-ScheduledTask -TaskName 'Confluence-DBA-PDF-Export' -Action $action -Trigger $trigger -Description 'Export Confluence DBA space to OneDrive PDFs'
```

## Notes on fidelity

- This script is designed for Confluence Cloud and uses Confluence-rendered PDFs, which is typically the closest to 1:1 output.
- Some dynamic macros or embedded third-party widgets may still vary from interactive page view.
- If your tenant blocks `flyingpdf` endpoint behavior, use built-in Space PDF export from Confluence UI as fallback.
