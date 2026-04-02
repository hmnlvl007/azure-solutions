[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfluenceBaseUrl,
    [Parameter(Mandatory)][string]$SpaceKey,
    [Parameter(Mandatory)][string]$Email,
    [Parameter(Mandatory)][string]$ApiToken,
    [Parameter(Mandatory)][string]$OutputPath,

    [int]$PageSize = 100
)

$ErrorActionPreference = 'Stop'

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
    $null = Invoke-WebRequest -Uri $uri -Method Get -Headers $Headers `
                -SessionVariable 'sess' -UseBasicParsing
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
        $uri = "{0}/content?spaceKey={1}&type=page&limit={2}&start={3}&expand=ancestors,version,body.export_view" `
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

# ── Export: Word (primary) ───────────────────────────────────────────────────

function Save-PageWord {
    <#
        Exports a page via Confluence's /exportword action URL.
        Returns .doc file that:
          - Preserves all formatting, tables, and hyperlinks
          - Opens natively in Word / Word Online
          - Is deeply indexed by M365 Copilot and SharePoint search
          - Supports SharePoint versioning, co-authoring, and metadata
    #>
    param(
        [Parameter(Mandatory)][string]$WikiBase,
        [Parameter(Mandatory)][string]$PageId,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$DestPath,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session
    )

    $wordUrl = "{0}/exportword?pageId={1}&os_authType=basic" -f $WikiBase, $PageId

    # Download to local temp first, then copy to destination
    $localTmp = Join-Path ([IO.Path]::GetTempPath()) "confluence-export-$PageId.doc"

    $webParams = @{
        Uri                = $wordUrl
        Method             = 'Get'
        Headers            = @{ Authorization = $Headers['Authorization'] }
        MaximumRedirection = 10
        OutFile            = $localTmp
        UseBasicParsing    = $true
        ErrorAction        = 'Stop'
    }
    if ($null -ne $Session) { $webParams['WebSession'] = $Session }

    try {
        Invoke-WebRequest @webParams | Out-Null
    }
    catch {
        if (Test-Path -LiteralPath $localTmp) { Remove-Item -LiteralPath $localTmp -Force }
        throw   # propagate so caller can detect 403 etc.
    }

    if ((Test-Path -LiteralPath $localTmp) -and (Get-Item -LiteralPath $localTmp).Length -gt 100) {
        # Copy with retry (handles transient I/O errors on network/redirected paths)
        $maxRetries = 3
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                Copy-Item -LiteralPath $localTmp -Destination $DestPath -Force
                break
            }
            catch {
                if ($attempt -eq $maxRetries) {
                    Remove-Item -LiteralPath $localTmp -Force -ErrorAction SilentlyContinue
                    throw
                }
                Start-Sleep -Milliseconds 500
            }
        }
        Remove-Item -LiteralPath $localTmp -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ Success = $true; Format = 'doc'; Path = $DestPath }
    }

    if (Test-Path -LiteralPath $localTmp) { Remove-Item -LiteralPath $localTmp -Force }
    return [PSCustomObject]@{ Success = $false; Format = $null; Path = $null }
}

# ── Export: HTML (fallback) ──────────────────────────────────────────────────

function Save-PageHtml {
    <#
        Fallback export via REST API body.export_view.
        Always works with API tokens. Preserves hyperlinks and formatting.
    #>
    param(
        [Parameter(Mandatory)][string]$ApiBase,
        [Parameter(Mandatory)][string]$WikiBase,
        [Parameter(Mandatory)][string]$PageId,
        [Parameter(Mandatory)][string]$PageTitle,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$DestPath,
        [string]$BodyHtml
    )

    # Use pre-fetched body if available; otherwise fetch it
    $body = $BodyHtml
    if ([string]::IsNullOrWhiteSpace($body)) {
        $uri  = "{0}/content/{1}?expand=body.export_view" -f $ApiBase, $PageId
        $resp = Invoke-RestMethod -Uri $uri -Headers $Headers
        $body = $resp.body.export_view.value
    }

    if ([string]::IsNullOrWhiteSpace($body)) {
        return [PSCustomObject]@{ Success = $false; Format = 'empty'; Path = $null }
    }

    $safeTitle     = [System.Net.WebUtility]::HtmlEncode($PageTitle)
    $confluenceUrl = "{0}/pages/viewpage.action?pageId={1}" -f $WikiBase, $PageId

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="generator" content="Confluence Export"/>
<meta name="source-page-id" content="$PageId"/>
<meta name="source-url" content="$confluenceUrl"/>
<title>$safeTitle</title>
<style>
  body   { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, sans-serif;
           max-width: 960px; margin: 2em auto; padding: 0 1em; color: #172B4D; line-height: 1.6; }
  h1     { border-bottom: 2px solid #0052CC; padding-bottom: .3em; }
  h2,h3  { color: #0052CC; }
  a      { color: #0052CC; text-decoration: underline; }
  .table-wrap { overflow-x: auto; margin: 1em 0; }
  table  { border-collapse: collapse; min-width: 50%; max-width: 100%; margin: 1em 0; }
  table[data-layout="wide"], table[data-layout="full-width"] { width: 100%; }
  th, td { border: 1px solid #C1C7D0; padding: .5em .75em; text-align: left;
           word-wrap: break-word; overflow-wrap: break-word; }
  td:has(> pre), td:has(> code) { max-width: 40em; }
  th     { background: #F4F5F7; font-weight: 600; white-space: nowrap; }
  tr:nth-child(even) { background: #FAFBFC; }
  col    { min-width: 6em; }
  code, pre { background: #F4F5F7; border-radius: 3px; font-size: 0.9em; }
  pre    { padding: 1em; overflow-x: auto; white-space: pre-wrap; word-break: break-word; }
  code   { padding: .15em .3em; }
  img    { max-width: 100%; height: auto; }
  .attachment-link { display: inline-block; padding: .2em .5em; background: #F4F5F7;
                     border-radius: 3px; margin: .2em 0; font-size: 0.9em; }
  .embedded-placeholder { padding: .75em; background: #FFFAE6; border: 1px solid #FFE380;
                          border-radius: 3px; margin: .5em 0; font-size: 0.9em; color: #6B778C; }
  .source-link { font-size: 0.85em; color: #6B778C; margin-bottom: 1.5em; }
  .source-link a { color: #6B778C; }
  @media print { body { margin: 0; } .source-link { display: none; } }
</style>
</head>
<body>
<h1>$safeTitle</h1>
<div class="source-link">Source: <a href="$confluenceUrl">View in Confluence</a></div>
$body
</body>
</html>
"@

    # Write with retry (handles transient I/O errors on network/redirected paths)
    $maxRetries = 3
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            Set-Content -LiteralPath $DestPath -Value $html -Encoding UTF8 -Force
            break
        }
        catch {
            if ($attempt -eq $maxRetries) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
    return [PSCustomObject]@{ Success = $true; Format = 'html'; Path = $DestPath }
}

# ── Attachments ──────────────────────────────────────────────────────────────

function Save-PageAttachments {
    <#
        Downloads all attachments for a Confluence page.
        Embedded documents (Excel, PDF, images) are saved to an _attachments
        subfolder next to the exported page document.
        Returns count and total bytes of downloaded attachments.
    #>
    param(
        [Parameter(Mandatory)][string]$ApiBase,
        [Parameter(Mandatory)][string]$WikiBase,
        [Parameter(Mandatory)][string]$PageId,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$PageFolder,
        [Parameter(Mandatory)][string]$FileBaseName
    )

    # List attachments via REST API
    $uri = "{0}/content/{1}/child/attachment?limit=100" -f $ApiBase, $PageId
    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers $Headers -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{ Count = 0; Bytes = [long]0; Files = @() }
    }

    if ($null -eq $resp.results -or $resp.results.Count -eq 0) {
        return [PSCustomObject]@{ Count = 0; Bytes = [long]0; Files = @() }
    }

    # Create _attachments subfolder named after the page
    $attachDir = Join-Path $PageFolder "$FileBaseName-attachments"
    if (-not (Test-Path -LiteralPath $attachDir)) {
        New-Item -Path $attachDir -ItemType Directory -Force | Out-Null
    }

    $dlCount = 0
    $dlBytes = [long]0
    $dlFiles = @()

    foreach ($att in $resp.results) {
        $attTitle = $att.title
        $safeName = Get-SafeFileName -Name $attTitle
        $dlPath   = Join-Path $attachDir $safeName

        # Build download URL from the attachment's _links.download
        $downloadPath = $null
        try { $downloadPath = $att._links.download } catch {}
        if ([string]::IsNullOrWhiteSpace($downloadPath)) { continue }

        $downloadUrl = "{0}{1}" -f $WikiBase, $downloadPath

        try {
            $webParams = @{
                Uri             = $downloadUrl
                Method          = 'Get'
                Headers         = @{ Authorization = $Headers['Authorization'] }
                OutFile         = $dlPath
                UseBasicParsing = $true
                ErrorAction     = 'Stop'
            }
            Invoke-WebRequest @webParams | Out-Null

            if (Test-Path -LiteralPath $dlPath) {
                $fileLen = (Get-Item -LiteralPath $dlPath).Length
                $dlCount++
                $dlBytes += $fileLen
                $dlFiles += [PSCustomObject]@{ Name = $attTitle; Size = $fileLen }
            }
        }
        catch {
            # Skip individual attachment failures silently
        }
    }

    # Clean up empty attachment folder
    if ($dlCount -eq 0 -and (Test-Path -LiteralPath $attachDir)) {
        Remove-Item -LiteralPath $attachDir -Force -Recurse -ErrorAction SilentlyContinue
    }

    return [PSCustomObject]@{ Count = $dlCount; Bytes = $dlBytes; Files = $dlFiles }
}

# ── Main ─────────────────────────────────────────────────────────────────────

$wikiBaseUrl = Get-WikiBaseUrl -BaseUrl $ConfluenceBaseUrl
$apiBaseUrl  = "$wikiBaseUrl/rest/api"
$headers     = Get-AuthHeaders -UserEmail $Email -Token $ApiToken

# Verify credentials
Write-Host 'Verifying Confluence credentials...'
try {
    $me = Invoke-RestMethod -Uri "$apiBaseUrl/user/current" -Headers $headers
    Write-Host "Authenticated as: $($me.displayName) ($($me.emailAddress))" -ForegroundColor Green
} catch {
    throw "Authentication failed. Check your email and API token."
}

# Establish session (cookies needed for /exportword action URL)
Write-Host 'Establishing session...'
$session = New-ConfluenceSession -ApiBase $apiBaseUrl -Headers $headers
Write-Host 'Session established.' -ForegroundColor Green

# Identify space home page so we can skip it in ancestor folder paths
$spaceHomeId = Get-SpaceHomePageId -ApiBase $apiBaseUrl -Space $SpaceKey -Headers $headers

$spaceOutput = Join-Path -Path $OutputPath -ChildPath $SpaceKey
if (-not (Test-Path -LiteralPath $spaceOutput)) {
    New-Item -Path $spaceOutput -ItemType Directory -Force | Out-Null
}

Write-Host ''
Write-Host "Fetching pages from space '$SpaceKey'..." -ForegroundColor Yellow
$pages = Get-ConfluencePages -ApiBase $apiBaseUrl -TargetSpace $SpaceKey -Headers $headers -Limit $PageSize

if ($pages.Count -eq 0) {
    Write-Host 'No pages found. Nothing to export.' -ForegroundColor Red
    exit 0
}

Write-Host "Found $($pages.Count) pages. Exporting to: $spaceOutput" -ForegroundColor Green
Write-Host 'Strategy: Word (.doc) primary, HTML fallback + attachments' -ForegroundColor Green
Write-Host ''

$index      = 0
$failed     = @()
$formats    = @{ doc = 0; html = 0 }
$totalBytes = [long]0
$totalAttachments   = 0
$totalAttachBytes   = [long]0
$runStart   = [DateTime]::UtcNow
$wordBlocked       = $false   # flip to $true after consecutive Word failures
$wordFailStreak    = 0       # consecutive Word export failures
$wordFailThreshold = 3       # switch to HTML-only after this many consecutive failures

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
    if ([string]::IsNullOrEmpty($relFolder)) { $relFolder = '.' }

    # ETA calc
    $pct = [math]::Round(($index / $pages.Count) * 100)
    $etaStr = ''
    if ($index -gt 1) {
        $avgSec    = ([DateTime]::UtcNow - $runStart).TotalSeconds / ($index - 1)
        $remainSec = $avgSec * ($pages.Count - $index + 1)
        $etaStr    = " | ETA {0:hh\:mm\:ss}" -f [TimeSpan]::FromSeconds([math]::Round($remainSec))
    }

    Write-Host ("[{0}/{1} {2}%{3}] {4}" -f $index, $pages.Count, $pct, $etaStr, $page.title) -ForegroundColor Cyan

    $result    = $null
    $failReason = ''

    # ── Try Word first ───────────────────────────────────────────────────
    if (-not $wordBlocked) {
        $docPath = Join-Path $pageFolder "$fileBaseName.doc"
        try {
            $result = Save-PageWord `
                          -WikiBase  $wikiBaseUrl `
                          -PageId    $page.id `
                          -Headers   $headers `
                          -DestPath  $docPath `
                          -Session   $session

            if ($result.Success) {
                $wordFailStreak = 0
            } else {
                $wordFailStreak++
                $failReason = 'Word returned empty/tiny file'
            }
        }
        catch {
            $failReason = $_.Exception.Message

            # Only count HTTP errors toward word-blocked; ignore file I/O errors
            $status = 0
            if ($_.Exception.Response) {
                try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            }

            if ($status -in @(401, 403)) {
                $wordBlocked = $true
                Write-Host "  Word export returned $status - switching to HTML for all remaining pages" -ForegroundColor Yellow
            }
            elseif ($status -gt 0) {
                # Real HTTP error (500, 404, etc.) - count toward streak
                $wordFailStreak++
            }
            # else: I/O error or other non-HTTP issue - do NOT count toward streak
            $result = $null
        }

        # Only auto-switch after consecutive HTTP failures, not I/O glitches
        if (-not $wordBlocked -and $wordFailStreak -ge $wordFailThreshold) {
            $wordBlocked = $true
            Write-Host "  Word failed $wordFailStreak consecutive HTTP errors - switching to HTML" -ForegroundColor Yellow
        }
    }

    # ── Fall back to HTML ────────────────────────────────────────────────
    if ($null -eq $result -or -not $result.Success) {
        $htmlPath = Join-Path $pageFolder "$fileBaseName.html"

        # Use pre-fetched body from the listing call (avoids extra API round-trip)
        $prefetchedBody = $null
        try { $prefetchedBody = $page.body.export_view.value } catch {}

        try {
            $result = Save-PageHtml `
                          -ApiBase   $apiBaseUrl `
                          -WikiBase  $wikiBaseUrl `
                          -PageId    $page.id `
                          -PageTitle $page.title `
                          -Headers   $headers `
                          -DestPath  $htmlPath `
                          -BodyHtml  $prefetchedBody

            if (-not $result.Success -and $result.Format -eq 'empty') {
                # Page body is empty (container page) - treat as SKIP, not FAIL
                $failReason = 'empty page (container/parent)'
            }
            elseif (-not $result.Success) {
                $failReason = 'HTML body empty'
            }
        }
        catch {
            $result = [PSCustomObject]@{ Success = $false; Format = $null; Path = $null }
            $failReason = "HTML fallback: $($_.Exception.Message)"
        }
    }

    $dur = ([DateTime]::UtcNow - $pageStart).TotalSeconds

    if ($result.Success) {
        $formats[$result.Format]++
        $fileSize = (Get-Item -LiteralPath $result.Path).Length
        $totalBytes += $fileSize
        $sizeStr = if ($fileSize -ge 1MB) { "{0:N1} MB" -f ($fileSize / 1MB) }
                   elseif ($fileSize -ge 1KB) { "{0:N0} KB" -f ($fileSize / 1KB) }
                   else { "$fileSize B" }
        Write-Host ("  OK  {0} | {1} | {2:N1}s | {3}" -f `
            $result.Format.ToUpper().PadRight(4), $sizeStr, $dur, $relFolder) -ForegroundColor Green

        # Download attachments (Excel, PDF, images, etc.)
        $attResult = Save-PageAttachments `
                         -ApiBase      $apiBaseUrl `
                         -WikiBase     $wikiBaseUrl `
                         -PageId       $page.id `
                         -Headers      $headers `
                         -PageFolder   $pageFolder `
                         -FileBaseName $fileBaseName

        if ($attResult.Count -gt 0) {
            $totalAttachments += $attResult.Count
            $totalAttachBytes += $attResult.Bytes
            $totalBytes       += $attResult.Bytes
            $attSizeStr = if ($attResult.Bytes -ge 1MB) { "{0:N1} MB" -f ($attResult.Bytes / 1MB) }
                          elseif ($attResult.Bytes -ge 1KB) { "{0:N0} KB" -f ($attResult.Bytes / 1KB) }
                          else { "$($attResult.Bytes) B" }
            Write-Host ("        + {0} attachment(s) | {1}" -f $attResult.Count, $attSizeStr) -ForegroundColor DarkCyan
        }
    }
    else {
        $reasonStr = if ($failReason) { $failReason } else { 'unknown' }
        $failed += [PSCustomObject]@{ Id = $page.id; Title = $page.title; Reason = $reasonStr }
        if ($failReason -match 'empty page') {
            Write-Host ("  SKIP  empty page ({0}) | {1:N1}s" -f $page.id, $dur) -ForegroundColor DarkYellow
        } else {
            Write-Host ("  FAIL  ({0}) | {1:N1}s | {2}" -f $page.id, $dur, $reasonStr) -ForegroundColor Red
        }
    }

    # Compact running totals every 10 pages
    if ($index % 10 -eq 0 -and $index -lt $pages.Count) {
        $elapsed = [TimeSpan]::FromSeconds(([DateTime]::UtcNow - $runStart).TotalSeconds)
        $exported = $formats.doc + $formats.html
        $tSize   = if ($totalBytes -ge 1MB) { "{0:N1} MB" -f ($totalBytes / 1MB) }
                   elseif ($totalBytes -ge 1KB) { "{0:N0} KB" -f ($totalBytes / 1KB) }
                   else { "$totalBytes B" }
        Write-Host ("  --- {0} exported (DOC:{1} HTML:{2}) | {3} failed | {4} | {5:hh\:mm\:ss} ---" -f `
            $exported, $formats.doc, $formats.html, $failed.Count, $tSize, $elapsed) -ForegroundColor DarkGray
    }
}

$totalExported = $formats.doc + $formats.html
$stamp         = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$summaryPath   = Join-Path $spaceOutput "export-summary-$stamp.json"
$totalElapsed  = [TimeSpan]::FromSeconds(([DateTime]::UtcNow - $runStart).TotalSeconds)

$totalSizeStr = if ($totalBytes -ge 1MB) { "{0:N1} MB" -f ($totalBytes / 1MB) }
                elseif ($totalBytes -ge 1KB) { "{0:N0} KB" -f ($totalBytes / 1KB) }
                else { "$totalBytes bytes" }

$summary = [PSCustomObject]@{
    runAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
    durationSec    = [math]::Round($totalElapsed.TotalSeconds)
    spaceKey       = $SpaceKey
    confluence     = $wikiBaseUrl
    totalPages     = $pages.Count
    exported       = [PSCustomObject]@{ doc = $formats.doc; html = $formats.html }
    exportedCount  = $totalExported
    totalSizeBytes = $totalBytes
    attachments    = [PSCustomObject]@{ count = $totalAttachments; bytes = $totalAttachBytes }
    failedCount    = $failed.Count
    failures       = $failed
    outputFolder   = $spaceOutput
}

$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host ''
Write-Host '--- EXPORT COMPLETE ---' -ForegroundColor Cyan
Write-Host "  Space    : $SpaceKey"
Write-Host "  Pages    : $($pages.Count)"
Write-Host "  Exported : $totalExported  (DOC: $($formats.doc) | HTML: $($formats.html))" -ForegroundColor Green
if ($totalAttachments -gt 0) {
    $attTotalStr = if ($totalAttachBytes -ge 1MB) { "{0:N1} MB" -f ($totalAttachBytes / 1MB) }
                   elseif ($totalAttachBytes -ge 1KB) { "{0:N0} KB" -f ($totalAttachBytes / 1KB) }
                   else { "$totalAttachBytes bytes" }
    Write-Host "  Attach.  : $totalAttachments files ($attTotalStr)" -ForegroundColor DarkCyan
}
Write-Host "  Failed   : $($failed.Count)" -ForegroundColor $(if ($failed.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Size     : $totalSizeStr"
Write-Host "  Duration : $("{0:hh\:mm\:ss}" -f $totalElapsed)"
Write-Host "  Output   : $spaceOutput"
Write-Host "  Summary  : $summaryPath"

if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host '  Failed pages:' -ForegroundColor Red
    foreach ($f in $failed) {
        Write-Host "    - $($f.Title) (ID $($f.Id))" -ForegroundColor Red
    }
    Write-Host ''
    exit 2
}
Write-Host ''
