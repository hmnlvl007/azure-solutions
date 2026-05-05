# Confluence Space Export to OneDrive / SharePoint

Exports every page from a Confluence Cloud space as individual **Word (.doc)** files — with automatic **HTML fallback** — plus page **attachments**, into a OneDrive for Business folder that syncs to SharePoint. Designed for M365 Copilot indexing, SharePoint search, and document library browsing.

## How it works

```
Confluence Cloud REST API
        │
        ├─ /exportword  ──▶  .doc  (primary – native Word, preserves links)
        │
        └─ body.export_view ──▶  .html  (fallback – always works with API tokens)
        │
        ├─ /child/attachment ──▶  <file>-attachments/  (downloaded alongside each page)
        │
        ▼
  OneDrive for Business (local sync folder)
        │
        ▼
  SharePoint Document Library  ──▶  M365 Copilot / Search
```

1. Authenticates against Confluence Cloud with Basic auth (email + API token).
2. Establishes a cookie-based session (required by the `/exportword` action URL).
3. Fetches all pages via three complementary API calls (content list, CQL search, descendants) and deduplicates results.
4. Mirrors the Confluence page tree as a local folder hierarchy.
5. For each page: tries **Word export** first; falls back to **styled HTML** if Word fails.
6. If Word returns HTTP 401/403, or fails 3 times in a row, the script switches to HTML-only for all remaining pages.
7. Downloads all page **attachments** into a `<filename>-attachments/` subfolder next to each exported file.
8. Long file/folder names are automatically truncated with a hash suffix to stay within the 235-character Windows path limit.
9. Writes a JSON state file (`export-state.json`) and a timestamped summary file after every run.
10. Default mode is **Incremental**: unchanged pages (same version + same path) are skipped. **Full** mode wipes and rebuilds from scratch.

## Files

| File | Purpose |
|---|---|
| `scripts/export-confluence-space-pdf.ps1` | Main export engine — auth, pagination, hierarchy, Word + HTML export, attachments, summary |
| `scripts/run-confluence-export.ps1` | Launcher — auto-detects OneDrive path, holds your credentials, calls the main script |

## Prerequisites

1. **Confluence Cloud** account with read access to the target space.
2. **Atlassian API token** — create one at: https://id.atlassian.com/manage-profile/security/api-tokens
3. **OneDrive for Business** sync client installed and signed in (syncs to SharePoint automatically).
4. **PowerShell 5.1+** (built into Windows — no additional installs required).

---

## One-time setup

### Step 1 — Store your API token as an environment variable

Open PowerShell and run:

```powershell
[Environment]::SetEnvironmentVariable('CONFLUENCE_API_TOKEN', 'your-token-here', 'User')
```

**Close and reopen your terminal** after running this so the variable is loaded.

To verify it is set:
```powershell
$env:CONFLUENCE_API_TOKEN
```

### Step 2 — Edit the launcher script

Open `scripts\run-confluence-export.ps1` and update the default parameter values at the top of the file:

```powershell
param(
    [string]$ConfluenceBaseUrl = 'https://your-company.atlassian.net',  # ← your Confluence URL
    [string]$SpaceKey          = 'DBA',                                  # ← space key to export
    [string]$Email             = 'you@your-company.com',                 # ← your Atlassian email
    [string]$ApiToken          = $env:CONFLUENCE_API_TOKEN,              # leave as-is
    [string]$ExportSubFolder   = 'ConfluenceExports',                    # OneDrive subfolder name
    [string]$ExportMode        = 'Incremental',                          # Incremental or Full
    [int]   $PageSize          = 100                                      # max 100
)
```

The script auto-detects your OneDrive for Business root from `$env:OneDriveCommercial` (falls back to `$env:OneDrive`). Files are exported to:

```
<OneDrive root>\<ExportSubFolder>\<SpaceKey>\
```

---

## Running the export

### Standard run

```powershell
cd C:\PHP_MCP
.\scripts\run-confluence-export.ps1
```

### Override parameters inline (without editing the file)

```powershell
.\scripts\run-confluence-export.ps1 -SpaceKey 'PROD' -ExportMode Full
```

### Full refresh (wipe and rebuild everything)

```powershell
.\scripts\run-confluence-export.ps1 -ExportMode Full
```

### If execution policy blocks the script

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-confluence-export.ps1
```

---

## What you will see

```
OneDrive root : C:\Users\JulieOzmolski.adm\OneDrive - Providence St. Joseph Health
Export target : C:\Users\JulieOzmolski.adm\OneDrive - ...\ConfluenceExports
Space key     : DBA
Mode          : Incremental

Verifying credentials...
Authenticated as: Julie Ozmolski
Establishing session...
Session established.

Fetching pages from 'DBA'...
Found 18 pages.
Strategy: Word (.doc) primary, HTML fallback + attachments

[1/18] Export Infrastructure Architecture
  OK DOC | 6 KB
[2/18] Export 2008 Upgrades For 2021 - Archive
  OK DOC | 40 KB
[3/18] Export Adding Tables to SQL Server Replication
  OK DOC | 10 KB
     + 2 attachment(s)
...

--- EXPORT COMPLETE ---
  Space    : DBA
  Mode     : Incremental
  Pages    : 18
  Exported : 17 (DOC: 17 | HTML: 0)
  Kept     : 1 unchanged
  Failed   : 0
  Attach.  : 3 files
  Duration : 00:01:04
  Output   : C:\Users\...\ConfluenceExports\DBA
  Summary  : C:\Users\...\ConfluenceExports\DBA\export-summary-2026-05-05_13-00-00.json
```

---

## Output structure

The script mirrors the Confluence page hierarchy as a folder tree. Each file is named `<page-title>-<pageId>.doc`. The page ID suffix keeps names stable across Confluence title changes and moves. Long names are automatically shortened with a short hash to avoid Windows path length limits.

Attachments are saved in a `<filename>-attachments/` folder next to the exported page file.

```
ConfluenceExports/
└── DBA/
    ├── Infrastructure Architecture-75364662.doc
    ├── Database Administration-75333649.doc
    ├── Projects/
    │   ├── Replication Assessment-17846791.doc
    │   └── Replication Assessment-17846791-attachments/
    │       └── current-state.xlsx
    ├── Test Plans - Archive this entire section/
    │   ├── Backup options Test Plan-75364938.doc
    │   └── Load Testing on Facets AGs-75364741.doc
    ├── export-state.json
    └── export-summary-2026-05-05_13-00-00.json
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

Each run writes a timestamped summary file (`export-summary-<timestamp>.json`):

```json
{
  "runAtUtc": "2026-05-05T13:00:00.0000000Z",
  "durationSec": 64,
  "exportMode": "Incremental",
  "spaceKey": "DBA",
  "confluence": "https://providencehealthplans.atlassian.net/wiki",
  "totalPages": 18,
  "exported": { "doc": 17, "html": 0 },
  "exportedCount": 17,
  "unchangedCount": 1,
  "attachments": { "count": 3, "bytes": 204800 },
  "totalSizeBytes": 1245184,
  "failedCount": 0,
  "failures": [],
  "outputFolder": "C:\\Users\\...\\ConfluenceExports\\DBA"
}
```

If `failedCount > 0`, check the `failures` array for page IDs and error reasons.

---

## Schedule nightly export (Windows Task Scheduler)

```powershell
$action  = New-ScheduledTaskAction `
    -Execute   'powershell.exe' `
    -Argument  '-NoProfile -ExecutionPolicy Bypass -File "C:\PHP_MCP\scripts\run-confluence-export.ps1"'

$trigger = New-ScheduledTaskTrigger -Daily -At 2:00am

Register-ScheduledTask `
    -TaskName    'Confluence-DBA-Export' `
    -Action      $action `
    -Trigger     $trigger `
    -Description 'Nightly Confluence DBA space export to OneDrive'
```

> The task runs under your user account and automatically inherits `CONFLUENCE_API_TOKEN` and your OneDrive path.

---

## Script parameters

### run-confluence-export.ps1

| Parameter | Default | Description |
|---|---|---|
| `ConfluenceBaseUrl` | *(edit required)* | Confluence Cloud URL, e.g. `https://company.atlassian.net` |
| `SpaceKey` | *(edit required)* | Space key to export, e.g. `DBA` |
| `Email` | *(edit required)* | Your Atlassian account email |
| `ApiToken` | `$env:CONFLUENCE_API_TOKEN` | Leave as-is — reads from environment variable |
| `ExportSubFolder` | `ConfluenceExports` | Subfolder name inside your OneDrive root |
| `ExportMode` | `Incremental` | `Incremental` or `Full` |
| `PageSize` | `100` | Pages per API request (max 100) |

### export-confluence-space-pdf.ps1

| Parameter | Required | Description |
|---|---|---|
| `ConfluenceBaseUrl` | Yes | Confluence Cloud URL |
| `SpaceKey` | Yes | Space key to export |
| `Email` | Yes | Atlassian account email |
| `ApiToken` | Yes | Atlassian API token |
| `OutputPath` | Yes | Local output folder (your OneDrive sync path) |
| `PageSize` | No (default `100`) | API page batch size |
| `ExportMode` | No (default `Incremental`) | `Incremental` or `Full` |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Authentication failed` | Wrong email or API token | Verify token at https://id.atlassian.com/manage-profile/security/api-tokens |
| `ApiToken is required` | Env var not set or terminal not restarted | Re-run `SetEnvironmentVariable` and restart terminal |
| `Cannot locate OneDrive root` | OneDrive for Business not signed in | Sign into OneDrive for Business, or set `$env:OneDriveCommercial` manually |
| `ConfluenceBaseUrl is still the placeholder` | Launcher script not edited | Update the default values in `run-confluence-export.ps1` |
| All pages export as HTML (0 DOC) | `/exportword` blocked by tenant (401/403) | Normal — HTML fallback is automatic and produces full content |
| Word fails then switches to HTML after a few pages | 3 consecutive Word failures triggers auto-switch | Check summary JSON `failures` array for the root cause |
| `No pages found` | Wrong space key | Confirm the key from your Confluence URL: `/wiki/spaces/KEY/` |
| Exit code `2` | One or more pages failed | Review the `failures` array in the summary JSON |
| Path-too-long errors on deeply nested pages | Long title + deep ancestor chain nears 260 chars | Script auto-truncates; if it persists, shorten the `ExportSubFolder` name |
