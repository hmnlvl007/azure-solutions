[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfluenceBaseUrl,
    [Parameter(Mandatory)][string]$SpaceKey,
    [Parameter(Mandatory)][string]$Email,
    [Parameter(Mandatory)][string]$ApiToken,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory = $false)][ValidateRange(1,100)][int]$PageSize = 100,
    [Parameter(Mandatory = $false)][ValidateSet('Incremental','Full')][string]$ExportMode = 'Incremental'
)

$ErrorActionPreference = 'Stop'

function Get-WikiBaseUrl {
    param([string]$BaseUrl)
    $trimmed = $BaseUrl.TrimEnd('/')
    if ($trimmed -match '/wiki$') { return $trimmed }
    return "$trimmed/wiki"
}

function Get-AuthHeaders {
    param([string]$UserEmail, [string]$Token)
    $pair = "${UserEmail}:${Token}"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    return @{ Authorization = "Basic $encoded"; Accept = 'application/json' }
}

function Get-SafeFileName {
    param([string]$Name)
    $safe = $Name
    foreach ($invalid in [IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace($invalid, '_')
    }
    $safe = ($safe -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'untitled' }
    return $safe
}

function Get-ShortHash {
    param([string]$Text)
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $md5.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant().Substring(0, 8)
    }
    finally {
        $md5.Dispose()
    }
}

function Get-CompactName {
    param([string]$Name, [int]$MaxLength = 64)
    $safe = Get-SafeFileName -Name $Name
    if ($safe.Length -le $MaxLength) { return $safe }
    $hash = Get-ShortHash -Text $safe
    $headLength = [Math]::Max(16, $MaxLength - 9)
    return ($safe.Substring(0, $headLength).TrimEnd() + '-' + $hash)
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json -Depth 20)
}

function Write-JsonFile {
    param([string]$Path, [object]$Value, [int]$Depth = 10)
    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) { Ensure-Directory -Path $parent }
    $json = $Value | ConvertTo-Json -Depth $Depth
    [IO.File]::WriteAllText($Path, $json, [Text.Encoding]::UTF8)
}

function New-ConfluenceSession {
    param([string]$ApiBase, [hashtable]$Headers)
    try {
        $null = Invoke-WebRequest -Uri "$ApiBase/user/current" -Method Get -Headers $Headers -SessionVariable session -UseBasicParsing -ErrorAction Stop
        return $session
    }
    catch {
        return $null
    }
}

function Get-SpaceHomePageId {
    param([string]$ApiBase, [string]$Key, [hashtable]$Headers)
    $uri = "$ApiBase/space/$([Uri]::EscapeDataString($Key))?expand=homepage"
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $Headers -ErrorAction Stop
    return [string]$response.homepage.id
}

function Get-AllPages {
    param(
        [string]$ApiBase,
        [string]$Key,
        [hashtable]$Headers,
        [int]$BatchSize,
        [string]$HomePageId
    )

    $byId = @{}

    function Add-UniquePages {
        param([object[]]$Items)
        $added = 0
        foreach ($item in @($Items)) {
            $id = [string]$item.id
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            if ($byId.ContainsKey($id)) { continue }
            $byId[$id] = $item
            $added++
        }
        return $added
    }

    $contentTotal = 0
    $start = 0
    while ($true) {
        $uri = "$ApiBase/content?spaceKey=$([Uri]::EscapeDataString($Key))&type=page&status=current&expand=ancestors,version&limit=$BatchSize&start=$start"
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $Headers -ErrorAction Stop
        $batch = @($response.results)
        if ($batch.Count -eq 0) { break }
        $added = Add-UniquePages -Items $batch
        $contentTotal += $added
        Write-Host ("  content    start={0,4} got={1,3} added={2,3} total={3}" -f $start, $batch.Count, $added, $byId.Count) -ForegroundColor DarkGray
        $start += $batch.Count
        if (-not $response._links.next) { break }
    }

    $searchTotal = 0
    try {
        $start = 0
        $cql = [Uri]::EscapeDataString("space=`"$Key`" AND type=page")
        while ($true) {
            $uri = "$ApiBase/content/search?cql=$cql&expand=ancestors,version&limit=$BatchSize&start=$start"
            $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $Headers -ErrorAction Stop
            $batch = @($response.results)
            if ($batch.Count -eq 0) { break }
            $added = Add-UniquePages -Items $batch
            $searchTotal += $added
            Write-Host ("  cql-search start={0,4} got={1,3} added={2,3} total={3}" -f $start, $batch.Count, $added, $byId.Count) -ForegroundColor DarkGray
            $start += $batch.Count
            if (-not $response._links.next) { break }
        }
    } catch {
        Write-Host ("  cql-search unavailable: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
    }

    $descTotal = 0
    if (-not [string]::IsNullOrWhiteSpace($HomePageId)) {
        try {
            $start = 0
            while ($true) {
                $uri = "$ApiBase/content/$HomePageId/descendant/page?expand=ancestors,version&limit=$BatchSize&start=$start"
                $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $Headers -ErrorAction Stop
                $batch = @($response.results)
                if ($batch.Count -eq 0) { break }
                $added = Add-UniquePages -Items $batch
                $descTotal += $added
                Write-Host ("  descendants start={0,4} got={1,3} added={2,3} total={3}" -f $start, $batch.Count, $added, $byId.Count) -ForegroundColor DarkGray
                $start += $batch.Count
                if (-not $response._links.next) { break }
            }
        } catch {
            Write-Host ("  descendants unavailable: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
        }

        if (-not $byId.ContainsKey($HomePageId)) {
            try {
                $homeUri = "$ApiBase/content/$HomePageId?expand=ancestors,version"
                $homePage = Invoke-RestMethod -Uri $homeUri -Method Get -Headers $Headers -ErrorAction Stop
                $null = Add-UniquePages -Items @($homePage)
            } catch {
            }
        }
    }

    Write-Host ("  discovery totals -> content:{0} cql:{1} descendants:{2} unique:{3}" -f $contentTotal, $searchTotal, $descTotal, $byId.Count) -ForegroundColor DarkGray

    if ($byId.Count -eq 0) { return @() }
    return @($byId.Values | Sort-Object -Property @{ Expression = { [string]$_.title } }, @{ Expression = { [string]$_.id } })
}

function Get-PageFolder {
    param([object[]]$Ancestors, [string]$HomePageId, [string]$Root)
    $folder = $Root
    foreach ($ancestor in @($Ancestors)) {
        $ancestorId = [string]$ancestor.id
        if ([string]::IsNullOrWhiteSpace($ancestorId)) { continue }
        if ($ancestorId -eq $HomePageId) { continue }
        $part = Get-CompactName -Name ([string]$ancestor.title) -MaxLength 60
        $folder = Join-Path -Path $folder -ChildPath $part
    }
    return $folder
}

function Get-DestinationPath {
    param([string]$Folder, [string]$Title, [string]$PageId)
    $baseName = '{0}-{1}' -f (Get-CompactName -Name $Title -MaxLength 80), $PageId
    $path = Join-Path -Path $Folder -ChildPath ($baseName + '.doc')
    if ($path.Length -le 235) { return $path }
    $baseName = '{0}-{1}' -f (Get-CompactName -Name $Title -MaxLength 40), $PageId
    return (Join-Path -Path $Folder -ChildPath ($baseName + '.doc'))
}

function Get-PageBodyHtml {
    param([string]$ApiBase, [string]$PageId, [hashtable]$Headers)
    $uri = "$ApiBase/content/$PageId`?expand=body.export_view"
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $Headers -ErrorAction Stop
    return [string]$response.body.export_view.value
}

function Get-ResolvedAncestors {
    param(
        [object]$Page,
        [string]$ApiBase,
        [hashtable]$Headers,
        [hashtable]$AncestorCache
    )

    $pageId = ''
    try { $pageId = [string]$Page.id } catch { $pageId = '' }

    if (-not [string]::IsNullOrWhiteSpace($pageId) -and $AncestorCache.ContainsKey($pageId)) {
        return @($AncestorCache[$pageId])
    }

    if ([string]::IsNullOrWhiteSpace($pageId)) {
        return @()
    }

    $inlineAncestors = $null
    try { $inlineAncestors = $Page.ancestors } catch { $inlineAncestors = $null }
    if ($null -ne $inlineAncestors -and $null -ne $inlineAncestors.results) {
        $inlineAncestors = $inlineAncestors.results
    }

    try {
        $uri = "$ApiBase/content/$pageId?expand=ancestors"
        $fullPage = Invoke-RestMethod -Uri $uri -Method Get -Headers $Headers -ErrorAction Stop
        $resolved = $fullPage.ancestors
        if ($null -ne $resolved -and $null -ne $resolved.results) {
            $resolved = $resolved.results
        }
        $resolvedArray = @($resolved)
        $AncestorCache[$pageId] = $resolvedArray
        return $resolvedArray
    }
    catch {
        $fallback = @($inlineAncestors)
        $AncestorCache[$pageId] = $fallback
        return $fallback
    }
}

function Save-WordExport {
    param(
        [string]$WikiBase,
        [string]$PageId,
        [hashtable]$Headers,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [string]$DestinationPath
    )

    $url = "$WikiBase/exportword?pageId=$PageId&os_authType=basic"
    $tempFile = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("cf-word-$PageId-$([Guid]::NewGuid().ToString('N')).doc")
    try {
        $args = @{
            Uri = $url
            Method = 'Get'
            OutFile = $tempFile
            UseBasicParsing = $true
            MaximumRedirection = 10
            ErrorAction = 'Stop'
            Headers = @{ Authorization = $Headers.Authorization }
        }
        if ($null -ne $Session) {
            $args.WebSession = $Session
        }
        Invoke-WebRequest @args | Out-Null

        if (-not (Test-Path -LiteralPath $tempFile)) {
            return [PSCustomObject]@{ Success = $false; Reason = 'Word export did not produce a file'; StatusCode = 0 }
        }

        $size = (Get-Item -LiteralPath $tempFile).Length
        if ($size -lt 100) {
            return [PSCustomObject]@{ Success = $false; Reason = 'Word export file was empty/too small'; StatusCode = 0 }
        }

        Move-Item -LiteralPath $tempFile -Destination $DestinationPath -Force
        return [PSCustomObject]@{ Success = $true; Reason = ''; StatusCode = 0 }
    }
    catch {
        $statusCode = 0
        if ($null -ne $_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = 0 }
        }
        return [PSCustomObject]@{ Success = $false; Reason = $_.Exception.Message; StatusCode = $statusCode }
    }
    finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Save-HtmlFallback {
    param(
        [string]$WikiBase,
        [string]$ApiBase,
        [string]$PageId,
        [string]$PageTitle,
        [hashtable]$Headers,
        [string]$DestinationPath
    )

    $bodyHtml = $null
    try {
        $bodyHtml = Get-PageBodyHtml -ApiBase $ApiBase -PageId $PageId -Headers $Headers
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Reason = "Could not fetch body.export_view: $($_.Exception.Message)" }
    }

    if ([string]::IsNullOrWhiteSpace($bodyHtml)) {
        $bodyHtml = '<p><em>This Confluence page has no exportable body content.</em></p>'
    }

    $safeTitle = [System.Net.WebUtility]::HtmlEncode($PageTitle)
    $sourceUrl = "$WikiBase/pages/viewpage.action?pageId=$PageId"
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="confluence-page-id" content="$PageId" />
  <title>$safeTitle</title>
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; max-width: 960px; margin: 24px auto; line-height: 1.5; color: #172B4D; }
    h1 { border-bottom: 1px solid #DFE1E6; padding-bottom: 8px; }
    .source { margin: 12px 0 24px; color: #505F79; font-size: 12px; }
    img { max-width: 100%; height: auto; }
        table, .confluenceTable {
            border-collapse: collapse;
            border-spacing: 0;
            width: 100%;
            table-layout: auto;
            margin: 12px 0;
            font-size: 12px;
        }
        th, td, .confluenceTh, .confluenceTd {
            border: 1px solid #C1C7D0;
            padding: 6px 8px;
            text-align: left;
            vertical-align: top;
            word-break: break-word;
            overflow-wrap: anywhere;
        }
        th, .confluenceTh {
            background: #F4F5F7;
            font-weight: 600;
        }
        tr { page-break-inside: avoid; }
        @media print {
            thead { display: table-header-group; }
            tfoot { display: table-footer-group; }
            table { page-break-inside: auto; }
            tr { page-break-inside: avoid; page-break-after: auto; }
            th, td { white-space: normal; }
        }
  </style>
</head>
<body>
  <h1>$safeTitle</h1>
  <div class="source">Source: <a href="$sourceUrl">View in Confluence</a></div>
  $bodyHtml
</body>
</html>
"@

    [IO.File]::WriteAllText($DestinationPath, $html, [Text.Encoding]::UTF8)
    return [PSCustomObject]@{ Success = $true; Reason = '' }
}

function Save-Attachments {
    param(
        [string]$ApiBase,
        [string]$WikiBase,
        [string]$PageId,
        [hashtable]$Headers,
        [string]$PageFolder,
        [string]$BaseFilePath
    )

    $baseName = [IO.Path]::GetFileNameWithoutExtension($BaseFilePath)
    $attachmentFolder = Join-Path -Path $PageFolder -ChildPath ($baseName + '-attachments')

    try {
        $uri = "$ApiBase/content/$PageId/child/attachment?limit=200"
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $Headers -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{ Count = 0; Bytes = [long]0; Path = $null }
    }

    $items = @($response.results)
    if ($items.Count -eq 0) {
        return [PSCustomObject]@{ Count = 0; Bytes = [long]0; Path = $null }
    }

    Ensure-Directory -Path $attachmentFolder
    $count = 0
    $totalBytes = [long]0

    foreach ($item in $items) {
        $downloadPath = $null
        try { $downloadPath = [string]$item._links.download } catch { $downloadPath = $null }
        if ([string]::IsNullOrWhiteSpace($downloadPath)) { continue }

        $fileName = Get-SafeFileName -Name ([string]$item.title)
        $filePath = Join-Path -Path $attachmentFolder -ChildPath $fileName
        $tempFile = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("cf-att-$([Guid]::NewGuid().ToString('N')).tmp")

        try {
            $url = "$WikiBase$downloadPath"
            Invoke-WebRequest -Uri $url -Method Get -OutFile $tempFile -UseBasicParsing -Headers @{ Authorization = $Headers.Authorization } -ErrorAction Stop | Out-Null
            Move-Item -LiteralPath $tempFile -Destination $filePath -Force
            $size = (Get-Item -LiteralPath $filePath).Length
            $count++
            $totalBytes += $size
        }
        catch {
        }
        finally {
            if (Test-Path -LiteralPath $tempFile) {
                Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($count -eq 0) {
        Remove-Item -LiteralPath $attachmentFolder -Recurse -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ Count = 0; Bytes = [long]0; Path = $null }
    }

    return [PSCustomObject]@{ Count = $count; Bytes = $totalBytes; Path = $attachmentFolder }
}

$wikiBase = Get-WikiBaseUrl -BaseUrl $ConfluenceBaseUrl
$apiBase = "$wikiBase/rest/api"
$headers = Get-AuthHeaders -UserEmail $Email -Token $ApiToken

Write-Host 'Verifying credentials...'
try {
    $me = Invoke-RestMethod -Uri "$apiBase/user/current" -Method Get -Headers $headers -ErrorAction Stop
    Write-Host "Authenticated as: $($me.displayName)" -ForegroundColor Green
}
catch {
    throw "Authentication failed: $($_.Exception.Message)"
}

Write-Host 'Establishing session...'
$session = New-ConfluenceSession -ApiBase $apiBase -Headers $headers
if ($null -ne $session) {
    Write-Host 'Session established.' -ForegroundColor Green
}
else {
    Write-Host 'No session established. Word export may fall back to HTML.' -ForegroundColor Yellow
}

Write-Host "Resolving space home page for '$SpaceKey'..."
$homePageId = Get-SpaceHomePageId -ApiBase $apiBase -Key $SpaceKey -Headers $headers
Write-Host "  Home page ID: $homePageId" -ForegroundColor DarkGray

$spaceRoot = Join-Path -Path $OutputPath -ChildPath $SpaceKey
if ($ExportMode -eq 'Full') {
    Write-Host 'Resetting output folder for full export...' -ForegroundColor DarkCyan
    if (Test-Path -LiteralPath $spaceRoot) {
        Remove-Item -LiteralPath $spaceRoot -Recurse -Force
    }
}
Ensure-Directory -Path $spaceRoot

$statePath = Join-Path -Path $spaceRoot -ChildPath 'export-state.json'
$prevById = @{}
if ($ExportMode -eq 'Incremental') {
    $prevState = Read-JsonFile -Path $statePath
    if ($null -ne $prevState) {
        foreach ($row in @($prevState.pages)) {
            $id = [string]$row.id
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                $prevById[$id] = $row
            }
        }
    }
    Write-Host ("Loaded previous state entries: {0}" -f $prevById.Count) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host "Fetching pages from '$SpaceKey'..." -ForegroundColor Yellow
$pages = @(Get-AllPages -ApiBase $apiBase -Key $SpaceKey -Headers $headers -BatchSize $PageSize -HomePageId $homePageId)
if ($pages.Count -eq 0) {
    Write-Host "No pages found for space '$SpaceKey'." -ForegroundColor Yellow
    exit 0
}
Write-Host "Found $($pages.Count) pages." -ForegroundColor Green
Write-Host 'Strategy: Word (.doc) primary, HTML fallback + attachments' -ForegroundColor Green
Write-Host ''

$started = [DateTime]::UtcNow
$failed = [System.Collections.Generic.List[object]]::new()
$formats = @{ doc = 0; html = 0 }
$unchanged = 0
$attachmentsCount = 0
$attachmentsBytes = [long]0
$totalBytes = [long]0
$wordDisabled = $false
$wordFailureStreak = 0
$currentPages = [System.Collections.Generic.List[object]]::new()
$currentIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$ancestorCache = @{}

$index = 0
foreach ($page in $pages) {
    $index++
    $pageId = [string]$page.id
    $pageTitle = [string]$page.title
    if ([string]::IsNullOrWhiteSpace($pageTitle)) { $pageTitle = "Untitled-$index" }

    if ([string]::IsNullOrWhiteSpace($pageId)) {
        $failed.Add([PSCustomObject]@{ id = '(unknown)'; title = $pageTitle; reason = 'Missing page id' }) | Out-Null
        continue
    }

    $null = $currentIds.Add($pageId)

    $ancestors = Get-ResolvedAncestors -Page $page -ApiBase $apiBase -Headers $headers -AncestorCache $ancestorCache

    $folder = Get-PageFolder -Ancestors @($ancestors) -HomePageId $homePageId -Root $spaceRoot
    Ensure-Directory -Path $folder

    $destPath = Get-DestinationPath -Folder $folder -Title $pageTitle -PageId $pageId
    $version = 0
    try { $version = [int]$page.version.number } catch { $version = 0 }

    $previous = $null
    if ($prevById.ContainsKey($pageId)) {
        $previous = $prevById[$pageId]
    }

    if ($ExportMode -eq 'Incremental' -and $null -ne $previous) {
        $previousVersion = 0
        try { $previousVersion = [int]$previous.version } catch { $previousVersion = 0 }
        $previousPath = [string]$previous.outputPath
        if ($previousVersion -eq $version -and $previousPath -eq $destPath -and (Test-Path -LiteralPath $destPath)) {
            $unchanged++
            $size = (Get-Item -LiteralPath $destPath).Length
            $totalBytes += $size
            Write-Host ("[{0}/{1}] KEEP v{2} {3}" -f $index, $pages.Count, $version, $pageTitle) -ForegroundColor DarkGreen
            $currentPages.Add([PSCustomObject]@{
                id = $pageId
                title = $pageTitle
                version = $version
                outputPath = $destPath
                folder = $folder
                format = [string]$previous.format
                attachmentsPath = [string]$previous.attachmentsPath
            }) | Out-Null
            continue
        }
    }

    Write-Host ("[{0}/{1}] Export {2}" -f $index, $pages.Count, $pageTitle) -ForegroundColor Cyan

    $result = $null
    if (-not $wordDisabled) {
        for ($tryCount = 1; $tryCount -le 3; $tryCount++) {
            $result = Save-WordExport -WikiBase $wikiBase -PageId $pageId -Headers $headers -Session $session -DestinationPath $destPath
            if ($result.Success) {
                $wordFailureStreak = 0
                break
            }

            if ($result.StatusCode -in @(401, 403)) {
                $wordDisabled = $true
                Write-Host ("  Word export blocked with HTTP {0}. Switching to HTML fallback." -f $result.StatusCode) -ForegroundColor Yellow
                break
            }

            if ($tryCount -lt 3) {
                Start-Sleep -Milliseconds (500 * $tryCount)
            }
        }

        if (-not $result.Success) {
            $wordFailureStreak++
            if ($wordFailureStreak -ge 3 -and -not $wordDisabled) {
                $wordDisabled = $true
                Write-Host '  Word export failed 3 times in a row. Switching to HTML fallback.' -ForegroundColor Yellow
            }
        }
    }

    $format = 'doc'
    if ($null -eq $result -or -not $result.Success) {
        $htmlResult = Save-HtmlFallback -WikiBase $wikiBase -ApiBase $apiBase -PageId $pageId -PageTitle $pageTitle -Headers $headers -DestinationPath $destPath
        if (-not $htmlResult.Success) {
            $failed.Add([PSCustomObject]@{ id = $pageId; title = $pageTitle; reason = $htmlResult.Reason }) | Out-Null
            Write-Host ("  FAIL {0}" -f $htmlResult.Reason) -ForegroundColor Red
            continue
        }
        $format = 'html'
        $result = [PSCustomObject]@{ Success = $true; Reason = '' }
    }

    $formats[$format]++
    $fileSize = (Get-Item -LiteralPath $destPath).Length
    $totalBytes += $fileSize
    Write-Host ("  OK {0} | {1:N0} KB" -f $format.ToUpper(), ($fileSize / 1KB)) -ForegroundColor Green

    $attachmentInfo = Save-Attachments -ApiBase $apiBase -WikiBase $wikiBase -PageId $pageId -Headers $headers -PageFolder $folder -BaseFilePath $destPath
    if ($attachmentInfo.Count -gt 0) {
        $attachmentsCount += $attachmentInfo.Count
        $attachmentsBytes += $attachmentInfo.Bytes
        $totalBytes += $attachmentInfo.Bytes
        Write-Host ("     + {0} attachment(s)" -f $attachmentInfo.Count) -ForegroundColor DarkCyan
    }

    if ($ExportMode -eq 'Incremental' -and $null -ne $previous) {
        $oldOutput = [string]$previous.outputPath
        if (-not [string]::IsNullOrWhiteSpace($oldOutput) -and $oldOutput -ne $destPath -and (Test-Path -LiteralPath $oldOutput)) {
            Remove-Item -LiteralPath $oldOutput -Force -ErrorAction SilentlyContinue
        }

        $oldAttachmentPath = [string]$previous.attachmentsPath
        if (-not [string]::IsNullOrWhiteSpace($oldAttachmentPath) -and $oldAttachmentPath -ne $attachmentInfo.Path -and (Test-Path -LiteralPath $oldAttachmentPath)) {
            Remove-Item -LiteralPath $oldAttachmentPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $currentPages.Add([PSCustomObject]@{
        id = $pageId
        title = $pageTitle
        version = $version
        outputPath = $destPath
        folder = $folder
        format = $format
        attachmentsPath = $attachmentInfo.Path
    }) | Out-Null
}

if ($ExportMode -eq 'Incremental' -and $prevById.Count -gt 0) {
    $removed = 0
    foreach ($item in $prevById.GetEnumerator()) {
        $oldId = [string]$item.Key
        if ($currentIds.Contains($oldId)) { continue }

        $old = $item.Value
        $oldPath = [string]$old.outputPath
        if (-not [string]::IsNullOrWhiteSpace($oldPath) -and (Test-Path -LiteralPath $oldPath)) {
            Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
        }

        $oldAttachments = [string]$old.attachmentsPath
        if (-not [string]::IsNullOrWhiteSpace($oldAttachments) -and (Test-Path -LiteralPath $oldAttachments)) {
            Remove-Item -LiteralPath $oldAttachments -Recurse -Force -ErrorAction SilentlyContinue
        }
        $removed++
    }
    if ($removed -gt 0) {
        Write-Host ("Cleanup removed {0} stale page export(s)." -f $removed) -ForegroundColor DarkGray
    }
}

$elapsed = [DateTime]::UtcNow - $started
$exportedCount = $formats.doc + $formats.html
$summaryStamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$summaryPath = Join-Path -Path $spaceRoot -ChildPath ("export-summary-$summaryStamp.json")

$summary = [PSCustomObject]@{
    runAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    durationSec = [Math]::Round($elapsed.TotalSeconds)
    exportMode = $ExportMode
    spaceKey = $SpaceKey
    confluence = $wikiBase
    totalPages = $pages.Count
    exported = [PSCustomObject]@{ doc = $formats.doc; html = $formats.html }
    exportedCount = $exportedCount
    unchangedCount = $unchanged
    attachments = [PSCustomObject]@{ count = $attachmentsCount; bytes = $attachmentsBytes }
    totalSizeBytes = $totalBytes
    failedCount = $failed.Count
    failures = $failed
    outputFolder = $spaceRoot
}

$state = [PSCustomObject]@{
    runAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    spaceKey = $SpaceKey
    exportMode = $ExportMode
    pages = $currentPages
}

Write-JsonFile -Path $summaryPath -Value $summary -Depth 8
Write-JsonFile -Path $statePath -Value $state -Depth 8

Write-Host ''
Write-Host '--- EXPORT COMPLETE ---' -ForegroundColor Cyan
Write-Host "  Space    : $SpaceKey"
Write-Host "  Mode     : $ExportMode"
Write-Host "  Pages    : $($pages.Count)"
Write-Host "  Exported : $exportedCount (DOC: $($formats.doc) | HTML: $($formats.html))" -ForegroundColor Green
Write-Host "  Kept     : $unchanged unchanged" -ForegroundColor DarkGreen
Write-Host "  Failed   : $($failed.Count)" -ForegroundColor $(if ($failed.Count -gt 0) { 'Red' } else { 'Green' })
if ($attachmentsCount -gt 0) {
    Write-Host "  Attach.  : $attachmentsCount files" -ForegroundColor DarkCyan
}
Write-Host ("  Duration : {0:hh\:mm\:ss}" -f $elapsed)
Write-Host "  Output   : $spaceRoot"
Write-Host "  Summary  : $summaryPath"
Write-Host "  State    : $statePath"

if ($failed.Count -gt 0) {
    exit 2
}

exit 0