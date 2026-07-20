# Confluence Space Export — Staging + OneDrive Copy

Exports every page from a Confluence Cloud space as individual **Word (.doc)** files — with automatic **HTML fallback** — plus page **attachments**. The export is written to a **local staging folder** first, then mirrored to a OneDrive / SharePoint path via `robocopy`. Designed for M365 Copilot indexing, SharePoint search, and document library browsing.

---

## How it works

```
Confluence Cloud REST API
        │
        ├─ /exportword  ──▶  .doc   (primary — native Word, preserves links)
        └─ body.export_view ──▶  .html  (fallback — always works with API tokens)
        │
        ├─ /child/attachment ──▶  <file>-attachments/  (alongside each page)
        │
        ▼
  Local staging folder  ($env:LOCALAPPDATA\ConfluenceExports-Staging)
        │
        └─ robocopy /MIR  ──▶  \\tsclient\<OneDrivePath>  (UNC / RDP drive redirect)
                                        │
                                        ▼
                               SharePoint Document Library  ──▶  M365 Copilot / Search
```

### Step-by-step

1. Authenticates against Confluence Cloud with Basic auth (email + API token).
2. Establishes a cookie-based session (required by the `/exportword` action URL).
3. Fetches all pages via three complementary API calls (content list, CQL search, descendants) and deduplicates results.
4. Mirrors the Confluence page tree as a local folder hierarchy inside the **staging root**.
5. For each page: tries **Word export** first; falls back to **styled HTML** if Word fails.
6. If Word returns HTTP 401/403 or fails 3 times in a row, the script switches to HTML-only for all remaining pages.
7. Downloads all page **attachments** into a `<filename>-attachments/` subfolder next to each exported file.
8. Long file/folder names are automatically truncated with a hash suffix to stay within the 235-character Windows path limit.
9. Writes a JSON state file (`export-state.json`) and a timestamped summary file after every run.
10. Default mode is **Incremental**: unchanged pages (same version + same path) are skipped. **Full** mode wipes and rebuilds from scratch.
11. After the exporter finishes successfully, `run-confluence-export.ps1` calls `robocopy /MIR` to copy the staged output to the OneDrive UNC path.

---

## Files

| File | Purpose |
|---|---|
| `scripts/export-confluence-space-pdf.ps1` | Main export engine — auth, pagination, hierarchy, Word + HTML export, attachments, summary |
| `scripts/run-confluence-export.ps1` | Launcher — manages staging root, resolves OneDrive UNC path, calls the exporter, then runs `robocopy` |

---

## Prerequisites

1. **Confluence Cloud** account with read access to the target space.
2. **Atlassian API token** — create one at: https://id.atlassian.com/manage-profile/security/api-tokens
3. **OneDrive UNC path** accessible (e.g. via RDP drive redirection at `\\tsclient\`), or update `Resolve-OneDriveRoot` with your actual path.
4. **PowerShell 5.1+** (built into Windows — no additional installs required).

---

## One-time setup

### Step 1 — Store your API token as an environment variable

```powershell
[Environment]::SetEnvironmentVariable('CONFLUENCE_API_TOKEN', 'your-token-here', 'User')
```

**Close and reopen your terminal** after running this so the variable is loaded.

Verify it is set:
```powershell
$env:CONFLUENCE_API_TOKEN
```

### Step 2 — Edit the launcher script

Open `scripts\run-confluence-export.ps1` and update the parameter defaults at the top:

```powershell
param(
    [string]$ConfluenceBaseUrl = 'https://your-company.atlassian.net',  # ← your Confluence URL
    [string]$SpaceKey          = 'DADS',                                 # ← space key to export
    [string]$Email             = 'you@your-company.com',                 # ← your Atlassian email
    [string]$ApiToken          = $env:CONFLUENCE_API_TOKEN,              # leave as-is
    [string]$ExportSubFolder   = 'ConfluenceExports',                    # subfolder name in OneDrive
    [string]$ExportMode        = 'Incremental',                          # Incremental or Full
    [int]   $PageSize          = 100,                                     # max 100
    [string]$StagingRoot       = (Join-Path $env:LOCALAPPDATA 'ConfluenceExports-Staging'),
    [bool]  $CopyToOneDrive    = $true
)
```

### Step 3 — Update the OneDrive UNC path

Inside `run-confluence-export.ps1`, find the `Resolve-OneDriveRoot` function and set `$target` to your actual OneDrive UNC path:

```powershell
function Resolve-OneDriveRoot {
    $target = '\\tsclient\'   # ← update to your UNC path or local OneDrive sync folder
    ...
}
```

If the UNC path is unavailable at runtime, the script prints a warning and keeps the output in the staging folder — it does **not** abort.

---

## Running the export

### Standard incremental run (recommended)

```powershell
cd C:\PHP_MCP
.\scripts\run-confluence-export.ps1
```

### Override parameters inline without editing the file

```powershell
.\scripts\run-confluence-export.ps1 -SpaceKey 'PROD' -ExportMode Full
```

### Full refresh — wipe and rebuild everything

```powershell
.\scripts\run-confluence-export.ps1 -ExportMode Full
```

### Diagnostic mode — troubleshoot empty or partial exports

```powershell
.\scripts\run-confluence-export.ps1 -SpaceKey 'DADS' -ExportMode Full -DiagnosticMode
```

When enabled, the exporter prints the API-reported `size/limit/totalSize` and a type/status breakdown so you can confirm whether the API is returning `current` pages.

### Export to staging only — skip the OneDrive copy

```powershell
.\scripts\run-confluence-export.ps1 -CopyToOneDrive $false
```

### Override the staging folder

```powershell
.\scripts\run-confluence-export.ps1 -StagingRoot 'D:\MyExports'
```

### If execution policy blocks the script

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-confluence-export.ps1
```

---

## What you will see

```
Staging root  : C:\Users\You\AppData\Local\ConfluenceExports-Staging
Export target : C:\Users\You\AppData\Local\ConfluenceExports-Staging\ConfluenceExports
OneDrive root : \\tsclient\
Space key     : DADS
Mode          : Incremental
Diagnostic    : False

Verifying credentials...
Authenticated as: Julie Ozmolski
Establishing session...
Session established.

Fetching pages from 'DADS'...
Found 42 pages.
Strategy: Word (.doc) primary, HTML fallback + attachments

[1/42] Data Administration Home
  OK DOC | 8 KB
[2/42] SQL Server Replication Guide
  OK DOC | 34 KB
     + 3 attachment(s)
[3/42] Archive: 2019 Projects
  SKIP (unchanged)
...

--- EXPORT COMPLETE ---
  Space    : DADS
  Mode     : Incremental
  Pages    : 42
  Exported : 38 (DOC: 37 | HTML: 1)
  Kept     : 4 unchanged
  Failed   : 0
  Attach.  : 9 files
  Duration : 00:01:52
  Output   : C:\Users\You\AppData\Local\ConfluenceExports-Staging\ConfluenceExports\DADS
  Summary  : ...\DADS\export-summary-2026-07-20_02-00-00.json

Copying from staging to OneDrive...
Copy complete.
```

---

## Output structure

The script mirrors the Confluence page hierarchy as a folder tree. Each file is named `<page-title>-<pageId>.doc`. The page ID suffix keeps names stable across Confluence title changes and moves. Long names are automatically shortened with a short hash to avoid Windows path length limits.

Attachments are saved in a `<filename>-attachments/` folder next to the exported page file.

```
ConfluenceExports-Staging\ConfluenceExports\
└── DADS\
    ├── Data Administration Home-75333649.doc
    ├── SQL Server Replication Guide-17846791.doc
    ├── SQL Server Replication Guide-17846791-attachments\
    │   ├── replication-diagram.png
    │   └── topology-notes.xlsx
    ├── Projects\
    │   ├── 2024 Migration Plan-75364938.doc
    │   └── Performance Baseline-75364741.doc
    ├── export-state.json
    └── export-summary-2026-07-20_02-00-00.json
```

After a successful run, `robocopy /MIR` replicates this exact structure to:

```
\\tsclient\<OneDrivePath>\ConfluenceExports\DADS\
```

---

## Incremental vs Full mode

| Behaviour | Incremental (default) | Full |
|---|---|---|
| Unchanged pages (same version + path) | Kept, skipped | Re-exported |
| Renamed or moved pages | Old file deleted, new file written | All rebuilt |
| Deleted Confluence pages | Stale file removed | All rebuilt |
| Output folder wiped on start | No | Yes |
| State file reset | No | Yes |

---

## Summary JSON

Each run writes a timestamped summary file (`export-summary-<timestamp>.json`) inside the space output folder:

```json
{
  "runAtUtc": "2026-07-20T02:00:00.0000000Z",
  "durationSec": 112,
  "exportMode": "Incremental",
  "spaceKey": "DADS",
  "confluence": "https://your-company.atlassian.net/wiki",
  "totalPages": 42,
  "exported": { "doc": 37, "html": 1 },
  "exportedCount": 38,
  "unchangedCount": 4,
  "attachments": { "count": 9, "bytes": 512000 },
  "totalSizeBytes": 3145728,
  "failedCount": 0,
  "failures": [],
  "outputFolder": "C:\\Users\\You\\AppData\\Local\\ConfluenceExports-Staging\\ConfluenceExports\\DADS"
}
```

If `failedCount > 0`, check the `failures` array for page IDs and error reasons.

---

## Schedule a nightly export (Windows Task Scheduler)

```powershell
$action  = New-ScheduledTaskAction `
    -Execute  'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\PHP_MCP\scripts\run-confluence-export.ps1"'

$trigger = New-ScheduledTaskTrigger -Daily -At 2:00am

Register-ScheduledTask `
    -TaskName    'Confluence-DADS-Export' `
    -Action      $action `
    -Trigger     $trigger `
    -Description 'Nightly Confluence DADS space export — staging then OneDrive copy'
```

> The task runs under your user account and inherits `CONFLUENCE_API_TOKEN` from your user environment variables.

---

## Script parameters

### run-confluence-export.ps1

| Parameter | Default | Description |
|---|---|---|
| `ConfluenceBaseUrl` | *(edit required)* | Confluence Cloud URL, e.g. `https://company.atlassian.net` |
| `SpaceKey` | *(edit required)* | Space key to export, e.g. `DADS` |
| `Email` | *(edit required)* | Your Atlassian account email |
| `ApiToken` | `$env:CONFLUENCE_API_TOKEN` | Leave as-is — reads from environment variable |
| `ExportSubFolder` | `ConfluenceExports` | Subfolder created inside both staging and OneDrive roots |
| `ExportMode` | `Incremental` | `Incremental` or `Full` |
| `PageSize` | `100` | Pages per API request (max 100) |
| `DiagnosticMode` | `$false` | Prints API size/limit diagnostics — useful for empty-space debugging |
| `StagingRoot` | `%LOCALAPPDATA%\ConfluenceExports-Staging` | Local folder where the export is written before copying |
| `CopyToOneDrive` | `$true` | Set to `$false` to skip the `robocopy` step |

### export-confluence-space-pdf.ps1

| Parameter | Required | Description |
|---|---|---|
| `ConfluenceBaseUrl` | Yes | Confluence Cloud URL |
| `SpaceKey` | Yes | Space key to export |
| `Email` | Yes | Atlassian account email |
| `ApiToken` | Yes | Atlassian API token |
| `OutputPath` | Yes | Local output folder (staging path, passed by the launcher) |
| `PageSize` | No (default `100`) | API page batch size |
| `ExportMode` | No (default `Incremental`) | `Incremental` or `Full` |
| `DiagnosticMode` | No | Switch — enables verbose API diagnostics |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Authentication failed` | Wrong email or API token | Verify token at https://id.atlassian.com/manage-profile/security/api-tokens |
| `ApiToken is required` | Env var not set or terminal not restarted | Re-run `SetEnvironmentVariable` and restart terminal |
| `OneDrive UNC path not found` | `\\tsclient\` unavailable | Update `Resolve-OneDriveRoot` with your actual path, or pass `-CopyToOneDrive $false` |
| `ConfluenceBaseUrl is still the placeholder` | Launcher script not edited | Update the default values in `run-confluence-export.ps1` |
| `Email is still the placeholder` | Launcher script not edited | Update the `Email` default in `run-confluence-export.ps1` |
| `StagingRoot must be a local path, not a UNC path` | `StagingRoot` set to a UNC path | Use a local drive path for staging (e.g. `C:\Temp\Staging`) |
| All pages export as HTML (0 DOC) | `/exportword` blocked by tenant (401/403) | Normal — HTML fallback is automatic and produces full content |
| Word fails then switches to HTML after a few pages | 3 consecutive Word failures triggers auto-switch | Check summary JSON `failures` array for the root cause |
| `No pages found` | Wrong space key | Confirm the key from your Confluence URL: `/wiki/spaces/KEY/` |
| Exit code `2` | One or more pages failed | Review the `failures` array in the summary JSON |
| `Robocopy reported errors (code N)` | Network / UNC path issue during copy | Check OneDrive/UNC connectivity; staged files are intact and safe to retry |
| Path-too-long errors on deeply nested pages | Long title + deep ancestor chain | Script auto-truncates; if it persists, shorten `ExportSubFolder` or `StagingRoot` |

