[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfluenceBaseUrl,
    [Parameter(Mandatory)][string]$SpaceKey,
    [Parameter(Mandatory)][string]$Email,
    [Parameter(Mandatory)][string]$ApiToken,
    [Parameter(Mandatory)][string]$OutputPath,

    [int]$PageSize          = 100,
    [int]$MaxPdfAttempts    = 12,
    [int]$RetryDelaySeconds = 8
)

$ErrorActionPreference = 'Stop'

# Script-level flags — once a strategy gets a 403 we stop wasting time on it
# for every subsequent page.
$script:PdfExportBlocked  = $false
$script:WordExportBlocked = $false

# ── Helper functions ─────────────────────────────────────────────────────────

function Get-WikiBaseUrl {
    param([Parameter(Mandatory)][string]$BaseUrl)
    $trimmed = $BaseUrl.TrimEnd('/')
    if ($trimmed -match '/wiki$') { return $trimmed }
    return "$trimmed/wiki"
}

function Get-AuthHeaders {
    param(
        [Parameter(Mandatory)][string]$UserEmail,
        [Parameter(Mandatory)][string]$Token
    )
    $pair = "{0}:{1}" -f $UserEmail, $Token
    $enc  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    return @{
        Authorization = "Basic $enc"
        Accept        = 'application/json'
    }
}

function New-ConfluenceSession {
    param(
        [Parameter(Mandatory)][string]$ApiBase,
        [Parameter(Mandatory)][hashtable]$Headers
    )
    $uri = "$ApiBase/user/current"
    Write-Host 'Establishing Confluence session...'
    $null = Invoke-WebRequest -Uri $uri -Method Get -Headers $Headers `
                -SessionVariable 'sess' -UseBasicParsing
    Write-Host 'Session established.'
    return $sess
}

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    $safe = $Name
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $safe = $safe.Replace($c, '_') }
    $safe = ($safe -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'untitled' }
    if ($safe.Length -gt 100) { return $safe.Substring(0, 100).Trim() }
    return $safe
}

function Test-IsPdfFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -lt 4) { return $false }
    $s = [IO.File]::OpenRead($Path)
    try {
        $b = New-Object byte[] 4
        [void]$s.Read($b, 0, 4)
        return ($b[0] -eq 0x25 -and $b[1] -eq 0x50 -and $b[2] -eq 0x44 -and $b[3] -eq 0x46)
    } finally { $s.Dispose() }
}

# ── Space & page retrieval ───────────────────────────────────────────────────

function Get-SpaceHomePageId {
    param(
        [Parameter(Mandatory)][string]$ApiBase,
        [Parameter(Mandatory)][string]$Space,
        [Parameter(Mandatory)][hashtable]$Headers
    )
    $uri  = "{0}/space/{1}?expand=homepage" -f $ApiBase, [uri]::EscapeDataString($Space)
    $resp = Invoke-RestMethod -Uri $uri -Headers $Headers
    return [string]$resp.homepage.id
}

function Get-ConfluencePages {
    param(
        [Parameter(Mandatory)][string]$ApiBase,
        [Parameter(Mandatory)][string]$TargetSpace,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][int]$Limit
    )

    $all   = @()
    $start = 0

    while ($true) {
        # ancestors gives us the page tree; version gives the last-modified stamp
        $uri = "{0}/content?spaceKey={1}&type=page&limit={2}&start={3}&expand=ancestors,version" `
               -f $ApiBase, [uri]::EscapeDataString($TargetSpace), $Limit, $start

        $resp = Invoke-RestMethod -Uri $uri -Method Get -Headers $Headers
        if ($null -eq $resp.results -or $resp.results.Count -eq 0) { break }
        $all += $resp.results
        if ($resp._links.next) { $start += [int]$resp.limit } else { break }
    }
    return $all
}

# ── Hierarchy helper ─────────────────────────────────────────────────────────

function Get-PageFolderPath {
    <#
        Builds the local subfolder path that mirrors the Confluence page tree.
        Ancestors are ordered root → immediate parent.  The space home page is
        skipped so we don't duplicate the space-key folder we already create.
    #>
    param(
        [Parameter(Mandatory = $false)]$Ancestors,
        [Parameter(Mandatory)][string]$SpaceHomeId,
        [Parameter(Mandatory)][string]$RootFolder
    )
    $folder = $RootFolder
    if ($null -ne $Ancestors) {
        foreach ($a in $Ancestors) {
            if ([string]$a.id -eq $SpaceHomeId) { continue }
            $folder = Join-Path $folder (Get-SafeFileName -Name $a.title)
        }
    }
    return $folder
}

# ── Export functions (3 strategies) ──────────────────────────────────────────

function Save-PageExport {
    <#
        Tries three export strategies in order:
          1. PDF   – flyingpdf action URL  (needs PDF-export plugin enabled)
          2. Word  – /exportword action URL (works on most Cloud instances)
          3. HTML  – REST API body.export_view (always works with API tokens)
        Once a strategy returns 403 it is permanently disabled for the rest
        of the run via $script:PdfExportBlocked / $script:WordExportBlocked.
    #>
    param(
        [Parameter(Mandatory)][string]$WikiBase,
        [Parameter(Mandatory)][string]$ApiBase,
        [Parameter(Mandatory)][string]$PageId,
        [Parameter(Mandatory)][string]$PageTitle,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$DestFolder,
        [Parameter(Mandatory)][string]$FileBaseName,
        [Parameter(Mandatory)][int]$Attempts,
        [Parameter(Mandatory)][int]$DelaySec,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session
    )

    $authOnly = @{ Authorization = $Headers['Authorization'] }

    # ── Strategy 1: PDF via flyingpdf ────────────────────────────────────────
    if (-not $script:PdfExportBlocked) {
        Write-Host '     Strategy: PDF (flyingpdf)...' -NoNewline
        $pdfDest   = Join-Path $DestFolder "$FileBaseName.pdf"
        $pdfUrl    = "{0}/spaces/flyingpdf/pdfpageexport.action?pageId={1}&os_authType=basic" -f $WikiBase, $PageId
        $tempPath  = "$pdfDest.part"

        $webParams = @{
            Uri                = $pdfUrl
            Method             = 'Get'
            Headers            = $authOnly
            MaximumRedirection = 10
            OutFile            = $tempPath
            UseBasicParsing    = $true
            ErrorAction        = 'Stop'
        }
        if ($null -ne $Session) { $webParams['WebSession'] = $Session }

        $forbidden = 0
        for ($i = 1; $i -le $Attempts; $i++) {
            if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
            try {
                Invoke-WebRequest @webParams | Out-Null
                if (Test-IsPdfFile -Path $tempPath) {
                    Move-Item -LiteralPath $tempPath -Destination $pdfDest -Force
                    Write-Host ' OK' -ForegroundColor Green
                    return [PSCustomObject]@{ Success = $true; Format = 'pdf'; Path = $pdfDest }
                }
                Write-Host " attempt $i not PDF" -ForegroundColor Yellow -NoNewline
            }
            catch {
                $status = 0
                if ($_.Exception.Response) {
                    try { $status = [int]$_.Exception.Response.StatusCode } catch {}
                }
                if ($status -eq 403) {
                    $forbidden++
                    if ($forbidden -ge 2) {
                        Write-Host ' 403 BLOCKED' -ForegroundColor Red
                        Write-Host '     [!] PDF export returned 403 twice — disabling PDF strategy for remaining pages.' -ForegroundColor Red
                        $script:PdfExportBlocked = $true
                        break
                    }
                    Write-Host " 403(${i})" -ForegroundColor Red -NoNewline
                } else {
                    Write-Host " err(${i})" -ForegroundColor Yellow -NoNewline
                }
            }
            if ($i -lt $Attempts) { Start-Sleep -Seconds $DelaySec }
        }
        if (-not $script:PdfExportBlocked) { Write-Host ' FAILED' -ForegroundColor Red }
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    }

    # ── Strategy 2: Word export (/exportword) ────────────────────────────────
    if (-not $script:WordExportBlocked) {
        Write-Host '     Strategy: Word (exportword)...' -NoNewline
        $docDest  = Join-Path $DestFolder "$FileBaseName.doc"
        $wordUrl  = "{0}/exportword?pageId={1}&os_authType=basic" -f $WikiBase, $PageId
        $tmpWord  = "$docDest.part"

        $wordParams = @{
            Uri                = $wordUrl
            Method             = 'Get'
            Headers            = $authOnly
            MaximumRedirection = 10
            OutFile            = $tmpWord
            UseBasicParsing    = $true
            ErrorAction        = 'Stop'
        }
        if ($null -ne $Session) { $wordParams['WebSession'] = $Session }

        try {
            Invoke-WebRequest @wordParams | Out-Null
            if ((Test-Path -LiteralPath $tmpWord) -and (Get-Item -LiteralPath $tmpWord).Length -gt 100) {
                Move-Item -LiteralPath $tmpWord -Destination $docDest -Force
                Write-Host ' OK' -ForegroundColor Green
                return [PSCustomObject]@{ Success = $true; Format = 'doc'; Path = $docDest }
            }
            Write-Host ' empty response' -ForegroundColor Yellow
        }
        catch {
            $status = 0
            if ($_.Exception.Response) {
                try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            }
            if ($status -eq 403) {
                Write-Host ' 403 BLOCKED' -ForegroundColor Red
                Write-Host '     [!] Word export returned 403 — disabling Word strategy for remaining pages.' -ForegroundColor Red
                $script:WordExportBlocked = $true
            } else {
                Write-Host " FAILED ($($_.Exception.Message))" -ForegroundColor Red
            }
        }
        if (Test-Path -LiteralPath $tmpWord) { Remove-Item -LiteralPath $tmpWord -Force }
    }

    # ── Strategy 3: HTML via REST API body.export_view (always works) ────────
    Write-Host '     Strategy: HTML (REST API)...' -NoNewline
    $htmlDest = Join-Path $DestFolder "$FileBaseName.html"
    try {
        $uri  = "{0}/content/{1}?expand=body.export_view" -f $ApiBase, $PageId
        $resp = Invoke-RestMethod -Uri $uri -Headers $Headers
        $body = $resp.body.export_view.value

        if (-not [string]::IsNullOrWhiteSpace($body)) {
            $safeTitle = [System.Net.WebUtility]::HtmlEncode($PageTitle)
            $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<title>$safeTitle</title>
<style>
  body  { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, sans-serif;
          max-width: 960px; margin: 2em auto; padding: 0 1em; color: #172B4D; }
  h1    { border-bottom: 2px solid #0052CC; padding-bottom: .3em; }
  table { border-collapse: collapse; width: 100%; margin: 1em 0; }
  th,td { border: 1px solid #C1C7D0; padding: .5em .75em; }
  th    { background: #F4F5F7; }
  img   { max-width: 100%; }
  @media print { body { margin: 0; } }
</style>
</head>
<body>
<h1>$safeTitle</h1>
$body
</body>
</html>
"@
            [IO.File]::WriteAllText($htmlDest, $html, [Text.Encoding]::UTF8)
            Write-Host ' OK' -ForegroundColor Green
            return [PSCustomObject]@{ Success = $true; Format = 'html'; Path = $htmlDest }
        }
        Write-Host ' empty body' -ForegroundColor Yellow
    }
    catch {
        Write-Host " FAILED ($($_.Exception.Message))" -ForegroundColor Red
    }

    return [PSCustomObject]@{ Success = $false; Format = $null; Path = $null }
}

# ── Main ─────────────────────────────────────────────────────────────────────

$wikiBaseUrl = Get-WikiBaseUrl -BaseUrl $ConfluenceBaseUrl
$apiBaseUrl  = "$wikiBaseUrl/rest/api"
$headers     = Get-AuthHeaders -UserEmail $Email -Token $ApiToken

# Cookie-based session for legacy action URLs
$session = New-ConfluenceSession -ApiBase $apiBaseUrl -Headers $headers

# Identify space home page so we can skip it in ancestor folder paths
$spaceHomeId = Get-SpaceHomePageId -ApiBase $apiBaseUrl -Space $SpaceKey -Headers $headers
Write-Host "Space home page ID: $spaceHomeId"

$spaceOutput = Join-Path -Path $OutputPath -ChildPath $SpaceKey
if (-not (Test-Path -LiteralPath $spaceOutput)) {
    New-Item -Path $spaceOutput -ItemType Directory -Force | Out-Null
}

Write-Host ''
Write-Host '════════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host "  Confluence Space Export: $SpaceKey" -ForegroundColor Cyan
Write-Host "  Target folder : $spaceOutput" -ForegroundColor Cyan
Write-Host '════════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

Write-Host 'Fetching page list from Confluence...' -ForegroundColor Yellow
$pages = Get-ConfluencePages -ApiBase $apiBaseUrl -TargetSpace $SpaceKey -Headers $headers -Limit $PageSize

if ($pages.Count -eq 0) {
    Write-Host 'No pages found. Nothing to export.' -ForegroundColor Red
    exit 0
}

Write-Host ("Found {0} pages." -f $pages.Count) -ForegroundColor Green
Write-Host ''
Write-Host 'Active export strategies (in priority order):' -ForegroundColor Cyan
Write-Host '  1. PDF  (flyingpdf action URL)' -ForegroundColor White
Write-Host '  2. Word (exportword action URL)' -ForegroundColor White
Write-Host '  3. HTML (REST API body.export_view — always available)' -ForegroundColor White
Write-Host ''
Write-Host '────────────────────────────────────────────────────────────────' -ForegroundColor DarkGray

$index       = 0
$failed      = @()
$formats     = @{ pdf = 0; doc = 0; html = 0 }
$totalBytes  = [long]0
$runStart    = [DateTime]::UtcNow

foreach ($page in $pages) {
    $index++
    $pageStart = [DateTime]::UtcNow

    $safeTitle    = Get-SafeFileName -Name $page.title
    $fileBaseName = "{0:D4}-{1}" -f $index, $safeTitle

    # Build hierarchical folder path from the page's ancestor chain
    $pageFolder = Get-PageFolderPath -Ancestors $page.ancestors `
                      -SpaceHomeId $spaceHomeId -RootFolder $spaceOutput

    if (-not (Test-Path -LiteralPath $pageFolder)) {
        New-Item -Path $pageFolder -ItemType Directory -Force | Out-Null
    }

    # Relative path under the space output folder for display
    $relFolder = $pageFolder.Substring($spaceOutput.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
    if ([string]::IsNullOrEmpty($relFolder)) { $relFolder = '(root)' }

    # Percentage & ETA
    $pct = [math]::Round(($index / $pages.Count) * 100)
    $eta = ''
    if ($index -gt 1) {
        $elapsedSec  = ([DateTime]::UtcNow - $runStart).TotalSeconds
        $avgSec      = $elapsedSec / ($index - 1)
        $remainSec   = $avgSec * ($pages.Count - $index + 1)
        $etaSpan     = [TimeSpan]::FromSeconds([math]::Round($remainSec))
        $eta         = "  ETA: {0:hh\:mm\:ss}" -f $etaSpan
    }

    # Progress bar (Write-Progress renders in PS console)
    Write-Progress -Activity "Exporting $SpaceKey" `
        -Status "[$index/$($pages.Count)] $($page.title)" `
        -PercentComplete $pct -CurrentOperation "Folder: $relFolder"

    Write-Host ''
    Write-Host ("[{0}/{1}] ({2}%)  {3}" -f $index, $pages.Count, $pct, $page.title) -ForegroundColor White
    Write-Host ("     Page ID : {0}" -f $page.id) -ForegroundColor DarkGray
    Write-Host ("     Folder  : {0}" -f $relFolder) -ForegroundColor DarkGray
    if ($eta) { Write-Host ("     Remaining{0}" -f $eta) -ForegroundColor DarkGray }

    try {
        $result = Save-PageExport `
                      -WikiBase     $wikiBaseUrl `
                      -ApiBase      $apiBaseUrl `
                      -PageId       $page.id `
                      -PageTitle    $page.title `
                      -Headers      $headers `
                      -DestFolder   $pageFolder `
                      -FileBaseName $fileBaseName `
                      -Attempts     $MaxPdfAttempts `
                      -DelaySec     $RetryDelaySeconds `
                      -Session      $session
    }
    catch {
        $result = [PSCustomObject]@{ Success = $false; Format = $null; Path = $null }
        Write-Host ("     [X] Unexpected error: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }

    $pageDuration = ([DateTime]::UtcNow - $pageStart).TotalSeconds

    if ($result.Success) {
        $formats[$result.Format]++
        $fileSize = (Get-Item -LiteralPath $result.Path).Length
        $totalBytes += $fileSize
        $sizeStr = if ($fileSize -ge 1MB) { "{0:N1} MB" -f ($fileSize / 1MB) }
                   elseif ($fileSize -ge 1KB) { "{0:N0} KB" -f ($fileSize / 1KB) }
                   else { "$fileSize bytes" }
        Write-Host ("     [OK] {0}  |  {1}  |  {2:N1}s" -f `
            $result.Format.ToUpper(), $sizeStr, $pageDuration) -ForegroundColor Green
        Write-Host ("     File: {0}" -f (Split-Path $result.Path -Leaf)) -ForegroundColor DarkGray
    }
    else {
        $failed += [PSCustomObject]@{ Id = $page.id; Title = $page.title }
        Write-Host ("     [FAIL] All strategies failed for: {0} (ID {1})  |  {2:N1}s" -f `
            $page.title, $page.id, $pageDuration) -ForegroundColor Red
    }

    # Running totals every 5 pages
    if ($index % 5 -eq 0) {
        $elapsed = [TimeSpan]::FromSeconds(([DateTime]::UtcNow - $runStart).TotalSeconds)
        $totalSizeStr = if ($totalBytes -ge 1MB) { "{0:N1} MB" -f ($totalBytes / 1MB) }
                        elseif ($totalBytes -ge 1KB) { "{0:N0} KB" -f ($totalBytes / 1KB) }
                        else { "$totalBytes bytes" }
        Write-Host '     ── Progress ─────────────────────────────────────────' -ForegroundColor DarkGray
        Write-Host ("     Exported: {0}  |  Failed: {1}  |  Total size: {2}  |  Elapsed: {3:hh\:mm\:ss}" -f `
            ($formats.pdf + $formats.doc + $formats.html), $failed.Count, $totalSizeStr, $elapsed) -ForegroundColor DarkGray
        Write-Host ("     By format — PDF: {0}  DOC: {1}  HTML: {2}" -f `
            $formats.pdf, $formats.doc, $formats.html) -ForegroundColor DarkGray
    }
}

Write-Progress -Activity "Exporting $SpaceKey" -Completed

$stamp       = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$summaryPath = Join-Path $spaceOutput "export-summary-$stamp.json"
$totalElapsed = [TimeSpan]::FromSeconds(([DateTime]::UtcNow - $runStart).TotalSeconds)

$totalSizeStr = if ($totalBytes -ge 1MB) { "{0:N1} MB" -f ($totalBytes / 1MB) }
                elseif ($totalBytes -ge 1KB) { "{0:N0} KB" -f ($totalBytes / 1KB) }
                else { "$totalBytes bytes" }

$summary = [PSCustomObject]@{
    runAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
    durationSec    = [math]::Round($totalElapsed.TotalSeconds)
    spaceKey       = $SpaceKey
    confluence     = $wikiBaseUrl
    totalPages     = $pages.Count
    exported       = [PSCustomObject]@{ pdf = $formats.pdf; doc = $formats.doc; html = $formats.html }
    totalSizeBytes = $totalBytes
    failedCount    = $failed.Count
    failures       = $failed
    outputFolder   = $spaceOutput
}

$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host ''
Write-Host '════════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '  EXPORT COMPLETE' -ForegroundColor Cyan
Write-Host '════════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''
Write-Host ("  Space       : {0}" -f $SpaceKey)
Write-Host ("  Total pages : {0}" -f $pages.Count)
Write-Host ("  Exported    : {0}" -f ($formats.pdf + $formats.doc + $formats.html)) -ForegroundColor Green

if ($formats.pdf  -gt 0) { Write-Host ("    PDF       : {0}" -f $formats.pdf) -ForegroundColor Green }
if ($formats.doc  -gt 0) { Write-Host ("    Word      : {0}" -f $formats.doc) -ForegroundColor Green }
if ($formats.html -gt 0) { Write-Host ("    HTML      : {0}" -f $formats.html) -ForegroundColor Green }

if ($failed.Count -gt 0) {
    Write-Host ("  Failed      : {0}" -f $failed.Count) -ForegroundColor Red
    Write-Host ''
    Write-Host '  Failed pages:' -ForegroundColor Red
    foreach ($f in $failed) {
        Write-Host ("    - {0} (ID {1})" -f $f.Title, $f.Id) -ForegroundColor Red
    }
} else {
    Write-Host ("  Failed      : 0") -ForegroundColor Green
}

Write-Host ''
Write-Host ("  Total size  : {0}" -f $totalSizeStr)
Write-Host ("  Duration    : {0:hh\:mm\:ss}" -f $totalElapsed)
Write-Host ("  Output      : {0}" -f $spaceOutput)
Write-Host ("  Summary JSON: {0}" -f $summaryPath)
Write-Host ''

if ($failed.Count -gt 0) { exit 2 }
