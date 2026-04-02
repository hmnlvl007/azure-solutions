# Confluence Space Export to OneDrive / SharePoint

Exports every page from a Confluence Cloud space as individual **Word (.doc)** files — with automatic **HTML fallback** — into a OneDrive for Business folder that syncs to SharePoint. Designed for M365 Copilot indexing, SharePoint search, and document library browsing.

## How it works

```
Confluence Cloud REST API
        │
        ├─ /exportword  ──▶  .doc  (primary – native Word, preserves links)
        │
        └─ body.export_view ──▶  .html  (fallback – always works with API tokens)
        │
        ▼
  OneDrive for Business (local sync folder)
        │
        ▼
  SharePoint Document Library  ──▶  M365 Copilot / Search
```

1. Authenticates against Confluence Cloud with Basic auth (email + API token).
2. Establishes a cookie-based session (required by the `/exportword` action URL).
3. Fetches all pages in the target space, including their ancestor chains.
4. Mirrors the Confluence page tree as a local folder hierarchy.
5. For each page: tries **Word export** first; if that fails (e.g. 403), falls back to **styled HTML**.
6. If Word returns 403 on any page, it flips to HTML-only mode for the rest of the run.
7. Writes a JSON summary file (`export-summary-<timestamp>.json`) with run stats.

## Why Word (.doc) as the primary format

| Feature | Word (.doc) | HTML | PDF |
|---|---|---|---|
| Preserves hyperlinks | Yes | Yes | Partial |
| Opens in Word Online | Yes (native) | No | No |
| SharePoint preview | Yes | Yes | Yes |
| M365 Copilot indexing | Deep | Good | Limited |
| SharePoint co-authoring | Yes | No | No |
| Formatting fidelity | High | High | Highest |
| Confluence Cloud API support | `/exportword` | REST API | Blocked (403) |

> **Note:** Confluence Cloud blocks the legacy `flyingpdf` PDF endpoint for API token auth. Word is the best available format that is natively supported across the M365 ecosystem.

## Files

| File | Purpose |
|---|---|
| `scripts/export-confluence-space-pdf.ps1` | Main export script — handles auth, pagination, hierarchy, Word+HTML export, progress, and summary |
| `scripts/run-confluence-export.ps1` | Config wrapper — auto-detects OneDrive path, sets credentials, calls the main script |

## Prerequisites

1. **Confluence Cloud** account with read access to the target space.
2. **Atlassian API token** — create one at: https://id.atlassian.com/manage-profile/security/api-tokens
3. **OneDrive for Business** sync client installed and signed in (syncs to SharePoint).
4. **PowerShell 5.1+** (built into Windows).

## One-time setup

### 1. Set the API token as an environment variable

```powershell
[Environment]::SetEnvironmentVariable('CONFLUENCE_API_TOKEN', 'paste-token-here', 'User')
```

Restart your terminal after setting this so the variable is picked up.

### 2. Edit the wrapper script

Open `scripts/run-confluence-export.ps1` and update the `$config` hashtable:

```powershell
$config = @{
    ConfluenceBaseUrl = 'https://your-company.atlassian.net'   # your Confluence Cloud URL
    SpaceKey          = 'DBA'                                   # space key to export
    Email             = 'you@your-company.com'                  # your Atlassian account email
    ApiToken          = $env:CONFLUENCE_API_TOKEN               # leave as-is (reads from env)
    OutputPath        = $resolvedOutputPath                     # auto-resolved OneDrive path
    PageSize          = 100                                     # pages per API request (max 100)
}
```

### 3. (Optional) Change the OneDrive sub-folder

The wrapper auto-detects your OneDrive for Business root via `$env:OneDriveCommercial` (falls back to `$env:OneDrive`). Files are placed in a sub-folder — edit this line in the wrapper if needed:

```powershell
$exportSubFolder = 'ConfluenceExports'
```

## Running the export

### Manual run

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-confluence-export.ps1
```

### What you'll see

```
Verifying Confluence credentials...
Authenticated as: Julie Ozmolski (julie.ozmolski@providence.org)
Establishing session...
Session established.

Fetching pages from space 'DBA'...
Found 42 pages. Exporting to: C:\Users\...\ConfluenceExports\DBA
Strategy: Word (.doc) primary, HTML fallback

[1/42 2% | ETA 00:03:12] Database Backup Procedures
  OK  DOC  | 45 KB | 1.2s | Documentation
[2/42 5% | ETA 00:02:58] SQL Server Monitoring
  OK  DOC  | 38 KB | 0.9s | Documentation\Monitoring
...
  --- 10 exported (DOC:10 HTML:0) | 0 failed | 412 KB | 00:00:14 ---
...

--- EXPORT COMPLETE ---
  Space    : DBA
  Pages    : 42
  Exported : 42  (DOC: 42 | HTML: 0)
  Failed   : 0
  Size     : 1.8 MB
  Duration : 00:01:23
  Output   : C:\Users\...\ConfluenceExports\DBA
  Summary  : C:\Users\...\ConfluenceExports\DBA\export-summary-2026-04-02_14-30-00.json
```

## Output structure

The script mirrors the Confluence page hierarchy as folders. Files are numbered for stable sort order.

```
ConfluenceExports/
└── DBA/
    ├── 0001-Knowledge Base.doc
    ├── Documentation/
    │   ├── 0005-Database Backup Procedures.doc
    │   ├── 0006-Restore Runbook.doc
    │   └── Monitoring/
    │       └── 0010-SQL Server Monitoring.doc
    ├── How-To/
    │   ├── 0015-Create New Database.doc
    │   └── 0016-Grant Permissions.doc
    └── export-summary-2026-04-02_14-30-00.json
```

The **space home page** is excluded from the folder path (exported at the space root, not in a redundant subfolder).

## Summary JSON

Each run writes a summary file with details about the export:

```json
{
  "runAtUtc": "2026-04-02T21:30:00.0000000Z",
  "durationSec": 83,
  "spaceKey": "DBA",
  "confluence": "https://your-company.atlassian.net/wiki",
  "totalPages": 42,
  "exported": { "doc": 42, "html": 0 },
  "exportedCount": 42,
  "totalSizeBytes": 1887436,
  "failedCount": 0,
  "failures": [],
  "outputFolder": "C:\\Users\\...\\ConfluenceExports\\DBA"
}
```

## Schedule nightly export (Windows Task Scheduler)

```powershell
$action  = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "c:\PHP_MCP\scripts\run-confluence-export.ps1"'

$trigger = New-ScheduledTaskTrigger -Daily -At 1:00am

Register-ScheduledTask `
    -TaskName    'Confluence-DBA-Export' `
    -Action      $action `
    -Trigger     $trigger `
    -Description 'Export Confluence DBA space to OneDrive (Word + HTML fallback)'
```

> The task runs under your user account so it inherits your `CONFLUENCE_API_TOKEN` environment variable and OneDrive paths.

## Script parameters

### export-confluence-space-pdf.ps1

| Parameter | Required | Default | Description |
|---|---|---|---|
| `ConfluenceBaseUrl` | Yes | — | Confluence Cloud URL (e.g. `https://company.atlassian.net`) |
| `SpaceKey` | Yes | — | Confluence space key to export |
| `Email` | Yes | — | Atlassian account email for API auth |
| `ApiToken` | Yes | — | Atlassian API token |
| `OutputPath` | Yes | — | Local folder for exported files (e.g. OneDrive sync folder) |
| `PageSize` | No | `100` | Pages per API request (max 100) |

## Export strategy details

### Word export (primary)

- Uses Confluence's `/exportword?pageId=<id>` action URL.
- Requires a cookie-based session established via `Invoke-WebRequest -SessionVariable`.
- Produces a `.doc` file (HTML-in-Word wrapper) that Word, Word Online, and SharePoint handle natively.
- All hyperlinks (internal Confluence links, external URLs) are preserved as clickable links.
- Atomic writes: downloads to a `.part` temp file, then renames on success.

### HTML export (fallback)

- Uses the Confluence REST API `body.export_view` endpoint — always works with API tokens.
- Produces a self-contained `.html` file with:
  - Inline CSS styling (Confluence-inspired theme)
  - `<meta>` tags for source page ID and URL
  - "View in Confluence" source link
  - Responsive layout, print-friendly styles
- Falls back automatically if Word export fails for a page.
- If Word returns HTTP 403, the script switches to HTML-only for all remaining pages in the run.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Authentication failed` | Wrong email or API token | Verify at https://id.atlassian.com/manage-profile/security/api-tokens |
| `CONFLUENCE_API_TOKEN is empty` | Env var not set | Run the `SetEnvironmentVariable` command above and restart terminal |
| `Cannot locate a synced OneDrive folder` | OneDrive not signed in | Sign into OneDrive for Business; or set `$env:OneDriveCommercial` manually |
| All pages export as HTML (0 DOC) | `/exportword` blocked (403) | This is expected on some Confluence Cloud tenants — HTML is the automatic fallback |
| `No pages found` | Wrong space key | Check the space key in Confluence URL (`/wiki/spaces/KEY/...`) |
| Exit code 2 | Some pages failed | Check the `failures` array in the summary JSON for page IDs |
