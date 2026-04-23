[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfluenceBaseUrl,
    [Parameter(Mandatory)][string]$SpaceKey,
    [Parameter(Mandatory)][string]$Email,
    [Parameter(Mandatory)][string]$ApiToken,
    [Parameter(Mandatory)][string]$OutputPath,
    [int]$PageSize = 50,
    [ValidateSet('Incremental','Full')][string]$ExportMode = 'Incremental'
)

$ErrorActionPreference = 'Stop'

$script:TempRoot               = $null
$script:WritableDirectoryCache = @{}

# ==============================================================================
# HELPERS – paths / names
# ==============================================================================

function Get-WikiBaseUrl {
    param([string]$BaseUrl)
    $t = $BaseUrl.TrimEnd('/')
    if ($t -match '/wiki$') { return $t }
    return "$t/wiki"
}

function Get-AuthHeaders {
    param([string]$UserEmail, [string]$Token)
    $pair = "${UserEmail}:${Token}"
    $enc  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    return @{ Authorization = "Basic $enc"; Accept = 'application/json' }
}

function Get-SafeFileName {
    param([string]$Name)
    $s = $Name
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $s = $s.Replace($c, '_') }
    $s = ($s -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return 'untitled' }
    if ($s.Length -gt 100) { return $s.Substring(0, 100).Trim() }
    return $s
}

function Get-CompactSafeName {
    param([string]$Name, [int]$MaxLength = 60)
    $safe = Get-SafeFileName -Name $Name
    if ($safe.Length -le $MaxLength) { return $safe }
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        $hash = ([BitConverter]::ToString($md5.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($safe)))).Replace('-','').ToLowerInvariant().Substring(0,8)
    } finally { $md5.Dispose() }
    $headLen = [Math]::Max(8, $MaxLength - 9)
    return ($safe.Substring(0, $headLen).TrimEnd() + '-' + $hash)
}

function Get-SafeOutputFilePath {
    param([string]$Folder, [string]$BaseName, [string]$Extension, [int]$MaxPathLength = 235)
    $ext  = if ([string]::IsNullOrWhiteSpace($Extension)) { '' }
            elseif ($Extension.StartsWith('.')) { $Extension }
            else { ".$Extension" }
    $dest = Join-Path $Folder ($BaseName + $ext)
    if ($dest.Length -le $MaxPathLength) { return $dest }
    $excess    = $dest.Length - $MaxPathLength
    $shortBase = Get-CompactSafeName -Name $BaseName -MaxLength ([Math]::Max(12, $BaseName.Length - $excess - 2))
    $dest = Join-Path $Folder ($shortBase + $ext)
    if ($dest.Length -le $MaxPathLength) { return $dest }
    return (Join-Path $Folder ((Get-CompactSafeName -Name $BaseName -MaxLength 20) + $ext))
}

function Test-IsTsClientPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return $Path.StartsWith('\\tsclient\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-MaxDirPathLength {
    param([string]$Path)
    if (Test-IsTsClientPath -Path $Path) { return 190 }
    return 240
}

# ==============================================================================
# HELPERS – local temp / file I/O
# ==============================================================================

function Get-LocalTempRoot {
    if (-not [string]::IsNullOrWhiteSpace($script:TempRoot)) { return $script:TempRoot }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'ConfluenceExportStaging'),
        $env:TEMP, $env:TMP, [IO.Path]::GetTempPath()
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    foreach ($dir in $candidates) {
        try {
            [IO.Directory]::CreateDirectory($dir) | Out-Null
            $probe = Join-Path $dir ('.probe-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            [IO.File]::WriteAllText($probe, 'ok', [Text.Encoding]::ASCII)
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            $script:TempRoot = $dir
            return $script:TempRoot
        } catch {}
    }
    throw 'Could not locate a writable local temp folder.'
}

function New-LocalTempFilePath {
    param([string]$Prefix = 'conf', [string]$Extension = '.tmp')
    $ext = if ($Extension.StartsWith('.')) { $Extension } else { ".$Extension" }
    return (Join-Path (Get-LocalTempRoot) ('{0}-{1}{2}' -f $Prefix, [Guid]::NewGuid().ToString('N'), $ext))
}

function Remove-FileQuietly {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try { $null = cmd /d /c "if exist `"$Path`" del /F /Q `"$Path`"" 2>$null } catch {}
}

function Test-DirectoryExistsSafe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return [IO.Directory]::Exists($Path) }
    catch {
        try { $null = cmd /d /c "if exist `"$Path\NUL`" (exit 0) else (exit 1)" 2>$null; return ($LASTEXITCODE -eq 0) }
        catch { return $false }
    }
}

function Ensure-DirectorySafe {
    param([string]$Path)
    if (Test-DirectoryExistsSafe -Path $Path) { return }
    for ($i = 1; $i -le 5; $i++) {
        try { [IO.Directory]::CreateDirectory($Path) | Out-Null } catch {}
        if (-not (Test-DirectoryExistsSafe -Path $Path)) {
            try { $null = cmd /d /c "mkdir `"$Path`"" 2>&1 } catch {}
        }
        if (Test-DirectoryExistsSafe -Path $Path) { return }
        Start-Sleep -Milliseconds (300 * $i)
    }
    if (-not (Test-DirectoryExistsSafe -Path $Path)) { throw "Could not create directory: $Path" }
}

function Remove-DirectoryTreeSafe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-DirectoryExistsSafe -Path $Path)) { return }

    for ($i = 1; $i -le 5; $i++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        } catch {}

        if (-not (Test-DirectoryExistsSafe -Path $Path)) { return }

        try { $null = cmd /d /c "rmdir /S /Q `"$Path`"" 2>&1 } catch {}
        if (-not (Test-DirectoryExistsSafe -Path $Path)) { return }

        Start-Sleep -Milliseconds (600 * $i)
    }

    if (Test-DirectoryExistsSafe -Path $Path) {
        throw "Could not remove existing output directory: $Path"
    }
}

function Copy-FileSafe {
    param([string]$Source, [string]$Dest)
    $destDir = [IO.Path]::GetDirectoryName($Dest)
    if (-not [string]::IsNullOrEmpty($destDir)) { Ensure-DirectorySafe -Path $destDir }

    if (Test-IsTsClientPath -Path $Dest) {
        for ($i = 1; $i -le 5; $i++) {
            $null = cmd /c "copy /Y `"$Source`" `"$Dest`"" 2>&1
            if ($LASTEXITCODE -eq 0) { return }
            $sf = [IO.Path]::GetFileName($Source)
            $null = robocopy ([IO.Path]::GetDirectoryName($Source)) $destDir $sf /R:2 /W:1 /NP /NJH /NJS 2>&1
            if ($LASTEXITCODE -le 1) {
                if ($sf -ne [IO.Path]::GetFileName($Dest)) { $null = cmd /c "move /Y `"$(Join-Path $destDir $sf)`" `"$Dest`"" 2>&1 }
                return
            }
            Start-Sleep -Milliseconds (750 * $i)
        }
        throw "Copy failed (tsclient): $Source -> $Dest"
    }

    try { $b = [IO.File]::ReadAllBytes($Source); [IO.File]::WriteAllBytes($Dest, $b); return } catch { Remove-FileQuietly -Path $Dest }
    try { [IO.File]::Copy($Source, $Dest, $true); return } catch {}
    $null = cmd /c "copy /Y `"$Source`" `"$Dest`"" 2>&1
    if ($LASTEXITCODE -eq 0) { return }
    $sf = [IO.Path]::GetFileName($Source)
    $null = robocopy ([IO.Path]::GetDirectoryName($Source)) $destDir $sf /R:2 /W:1 /NP /NJH /NJS 2>&1
    if ($LASTEXITCODE -le 1) {
        if ($sf -ne [IO.Path]::GetFileName($Dest)) { $null = cmd /c "move /Y `"$(Join-Path $destDir $sf)`" `"$Dest`"" 2>&1 }
        return
    }
    throw "Copy failed: $Source -> $Dest"
}

function Write-FileSafe {
    param([string]$Path, [string]$Text)
    for ($i = 1; $i -le 3; $i++) {
        $tmp = New-LocalTempFilePath -Prefix 'conf-write' -Extension '.tmp'
        try {
            [IO.File]::WriteAllText($tmp, $Text, [Text.Encoding]::UTF8)
            Copy-FileSafe -Source $tmp -Dest $Path
            return
        } catch {
            if ($i -eq 3) { throw "Write failed: $($_.Exception.Message)" }
            Start-Sleep -Milliseconds (800 * $i)
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Read-JsonFileSafe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -Depth 20)
    } catch {
        Write-Host ("  Warning: unable to read JSON file: {0}" -f $Path) -ForegroundColor Yellow
        return $null
    }
}

function Remove-FileIfExistsSafe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { Remove-FileQuietly -Path $Path }
}

function Test-DirectoryWritable {
    param([string]$Path)
    if ($script:WritableDirectoryCache.ContainsKey($Path)) { return $true }
    Ensure-DirectorySafe -Path $Path
    $pn  = '.wp-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $ltmp = Join-Path (Get-LocalTempRoot) $pn
    $dp   = Join-Path $Path $pn
    try {
        [IO.File]::WriteAllText($ltmp, 'ok', [Text.Encoding]::ASCII)
        $null = cmd /c "copy /Y `"$ltmp`" `"$dp`"" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "copy probe failed exit $LASTEXITCODE" }
        $script:WritableDirectoryCache[$Path] = $true
        return $true
    } catch {
        throw "Output path not writable: $Path | $($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $ltmp) { Remove-Item -LiteralPath $ltmp -Force -ErrorAction SilentlyContinue }
        Remove-FileQuietly -Path $dp
    }
}

# ==============================================================================
# CONFLUENCE API
# ==============================================================================

function New-ConfluenceSession {
    param([string]$ApiBase, [hashtable]$Headers)
    try {
        $null = Invoke-WebRequest -Uri "$ApiBase/user/current" -Method Get `
                    -Headers $Headers -SessionVariable 'sess' -UseBasicParsing -ErrorAction Stop
        return $sess
    } catch { return $null }
}

function Get-SpaceHomePageId {
    param([string]$ApiBase, [string]$Space, [hashtable]$Headers)
    $resp = Invoke-RestMethod -Uri "$ApiBase/space/$([uri]::EscapeDataString($Space))?expand=homepage" `
                -Method Get -Headers $Headers -ErrorAction Stop
    return [string]$resp.homepage.id
}

function Get-AllPages {
    # Fetches every page in the space across all paginated batches.
    # - Expands 'ancestors' for folder hierarchy (NOT body - that truncates ancestors).
    # - Advances $start by actual results.Count, never by $resp.limit (can be null).
    # - Stops when _links.next is absent OR batch is smaller than requested.
    param([string]$ApiBase, [string]$Space, [hashtable]$Headers, [int]$BatchSize)
    $all   = [System.Collections.Generic.List[object]]::new()
    $start = 0
    while ($true) {
        $uri   = "$ApiBase/content?spaceKey=$([uri]::EscapeDataString($Space))&type=page&limit=$BatchSize&start=$start&expand=ancestors,version"
        $resp  = Invoke-RestMethod -Uri $uri -Method Get -Headers $Headers -ErrorAction Stop
        $batch = @($resp.results)
        if ($batch.Count -eq 0) { break }
        foreach ($p in $batch) { $all.Add($p) }
        Write-Host ("  batch start={0,4}  got={1,3}  total={2}" -f $start, $batch.Count, $all.Count) -ForegroundColor DarkGray
        $start += $batch.Count
        if (-not $resp._links.next) { break }
    }
    return $all.ToArray()
}

function Get-PageBodyHtml {
    param([string]$ApiBase, [string]$PageId, [hashtable]$Headers)
    try {
        $resp = Invoke-RestMethod -Uri "$ApiBase/content/$PageId`?expand=body.export_view" `
                    -Method Get -Headers $Headers -ErrorAction Stop
        return $resp.body.export_view.value
    } catch { return $null }
}

function Get-PageFolderPath {
    # Builds a folder path from the page's ancestor chain (root -> immediate parent).
    # The space home page is skipped. Each ancestor becomes one subfolder level.
    param($Ancestors, [string]$HomeId, [string]$Root)
    $folder = $Root
    $maxDir = (Get-MaxDirPathLength -Path $Root) - 80
    if ($null -ne $Ancestors) {
        foreach ($a in $Ancestors) {
            if ([string]$a.id -eq $HomeId) { continue }
            if ($folder.Length -ge $maxDir) { break }
            $remaining = [Math]::Max(12, $maxDir - $folder.Length - 1)
            $part      = Get-CompactSafeName -Name $a.title -MaxLength ([Math]::Min(60, $remaining))
            $candidate = Join-Path $folder $part
            if ($candidate.Length -gt $maxDir) { break }
            $folder = $candidate
        }
    }
    return $folder
}

function Resolve-PageIdentity {
    param($Page, [int]$Index = 0)

    $id = $null
    $idCandidates = @(
        (try { $Page.id } catch { $null }),
        (try { $Page.pageId } catch { $null }),
        (try { $Page.contentId } catch { $null }),
        (try { $Page.content.id } catch { $null })
    )
    foreach ($c in $idCandidates) {
        if (-not [string]::IsNullOrWhiteSpace([string]$c)) {
            $id = [string]$c
            break
        }
    }

    $title = $null
    $titleCandidates = @(
        (try { $Page.title } catch { $null }),
        (try { $Page.name } catch { $null }),
        (try { $Page.content.title } catch { $null })
    )
    foreach ($c in $titleCandidates) {
        if (-not [string]::IsNullOrWhiteSpace([string]$c)) {
            $title = [string]$c
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = if ($Index -gt 0) { "Untitled page $Index" } else { 'Untitled page' }
    }

    return [PSCustomObject]@{ Id = $id; Title = $title }
}

function Initialize-HierarchyFolders {
    # Pre-creates folder paths needed to mirror the Confluence tree.
    # 1) Every ancestor chain target folder used by exported pages.
    # 2) Any page that acts as a parent for other pages gets its own folder node.
    param([object[]]$Pages, [string]$HomeId, [string]$Root)

    $pageById  = @{}
    $parentIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    foreach ($p in $Pages) {
        $id = [string]$p.id
        if (-not [string]::IsNullOrWhiteSpace($id) -and -not $pageById.ContainsKey($id)) {
            $pageById[$id] = $p
        }

        $anc = $p.ancestors
        if ($null -ne $anc -and $null -ne $anc.results) { $anc = $anc.results }
        foreach ($a in @($anc)) {
            $aid = [string]$a.id
            if (-not [string]::IsNullOrWhiteSpace($aid) -and $aid -ne $HomeId) {
                $null = $parentIds.Add($aid)
            }
        }
    }

    $seen = @{}
    $created = 0
    $maxDir = (Get-MaxDirPathLength -Path $Root) - 80

    foreach ($p in $Pages) {
        $anc = $p.ancestors
        if ($null -ne $anc -and $null -ne $anc.results) { $anc = $anc.results }
        $folder = Get-PageFolderPath -Ancestors $anc -HomeId $HomeId -Root $Root
        if (-not $seen.ContainsKey($folder)) {
            $null = Test-DirectoryWritable -Path $folder
            $seen[$folder] = $true
            $created++
        }
    }

    foreach ($pid in $parentIds) {
        if (-not $pageById.ContainsKey($pid)) { continue }
        $parentPage = $pageById[$pid]
        $title = [string]$parentPage.title
        if ([string]::IsNullOrWhiteSpace($title)) { $title = "page-$pid" }

        $anc = $parentPage.ancestors
        if ($null -ne $anc -and $null -ne $anc.results) { $anc = $anc.results }
        $baseFolder = Get-PageFolderPath -Ancestors $anc -HomeId $HomeId -Root $Root
        if ($baseFolder.Length -ge $maxDir) { continue }

        $remaining = [Math]::Max(12, $maxDir - $baseFolder.Length - 1)
        $part = Get-CompactSafeName -Name $title -MaxLength ([Math]::Min(60, $remaining))
        $folder = Join-Path $baseFolder $part
        if ($folder.Length -gt $maxDir) { continue }

        if (-not $seen.ContainsKey($folder)) {
            $null = Test-DirectoryWritable -Path $folder
            $seen[$folder] = $true
            $created++
        }
    }

    return [PSCustomObject]@{ Created = $created; ParentNodes = $parentIds.Count }
}

# ==============================================================================
# EXPORT – Word (.doc)
# ==============================================================================

function Save-PageWord {
    param([string]$WikiBase, [string]$PageId, [hashtable]$Headers,
          [string]$DestPath, [Microsoft.PowerShell.Commands.WebRequestSession]$Session)
    $url = "$WikiBase/exportword?pageId=$PageId&os_authType=basic"
    $tmp = New-LocalTempFilePath -Prefix "cw-$PageId" -Extension '.doc'
    $p   = @{
        Uri = $url; Method = 'Get'; OutFile = $tmp; UseBasicParsing = $true
        MaximumRedirection = 10; ErrorAction = 'Stop'
        Headers = @{ Authorization = $Headers['Authorization'] }
    }
    if ($null -ne $Session) { $p['WebSession'] = $Session }
    try { Invoke-WebRequest @p | Out-Null }
    catch { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }; throw }
    if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt 100) {
        Copy-FileSafe -Source $tmp -Dest $DestPath
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ OK = $true; Fmt = 'doc'; Path = $DestPath }
    }
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    return [PSCustomObject]@{ OK = $false; Fmt = $null; Path = $null }
}

# ==============================================================================
# EXPORT – HTML fallback
# Saved as .doc because OneDrive sync blocks .html in SharePoint libraries.
# ==============================================================================

function Save-PageHtml {
    param([string]$WikiBase, [string]$PageId, [string]$PageTitle,
          [string]$BodyHtml, [string]$DestPath)
    if ([string]::IsNullOrWhiteSpace($BodyHtml)) {
        return [PSCustomObject]@{ OK = $false; Fmt = 'empty'; Path = $null }
    }
    $safe = [System.Net.WebUtility]::HtmlEncode($PageTitle)
    $src  = "$WikiBase/pages/viewpage.action?pageId=$PageId"
    $h  = '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/>'
    $h += "<title>$safe</title>"
    $h += '<style>body{font-family:Segoe UI,sans-serif;max-width:960px;margin:2em auto;padding:0 1em;color:#172B4D;line-height:1.6}'
    $h += 'h1{border-bottom:2px solid #0052CC;padding-bottom:.3em}h2,h3{color:#0052CC}'
    $h += 'a{color:#0052CC}.table-wrap{overflow-x:auto;width:100%;margin:1em 0}'
    $h += 'table{border-collapse:collapse;width:100%}th,td{border:1px solid #C1C7D0;padding:.5em .75em;text-align:left}'
    $h += 'th{background:#F4F5F7;font-weight:600}tr:nth-child(even){background:#FAFBFC}'
    $h += 'code,pre{background:#F4F5F7;border-radius:3px;font-size:.9em}pre{padding:1em;white-space:pre-wrap}'
    $h += 'img{max-width:100%;height:auto}.src{font-size:.85em;color:#6B778C;margin-bottom:1.5em}'
    $h += '@media print{body{margin:0}.src{display:none}}</style></head><body>'
    $h += "<h1>$safe</h1><div class='src'>Source: <a href='$src'>View in Confluence</a></div>"
    $wb = $BodyHtml
    $wb = [regex]::Replace($wb, '(?i)<table',   '<div class="table-wrap"><table')
    $wb = [regex]::Replace($wb, '(?i)</table>',  '</table></div>')
    $h += $wb + '</body></html>'
    Write-FileSafe -Path $DestPath -Text $h
    return [PSCustomObject]@{ OK = $true; Fmt = 'html'; Path = $DestPath }
}

# ==============================================================================
# ATTACHMENTS
# ==============================================================================

function Save-PageAttachments {
    param([string]$ApiBase, [string]$WikiBase, [string]$PageId,
          [hashtable]$Headers, [string]$PageFolder, [string]$FileBaseName, [string]$OutputRoot)
    try { $resp = Invoke-RestMethod -Uri "$ApiBase/content/$PageId/child/attachment?limit=100" -Headers $Headers -ErrorAction Stop }
    catch { return [PSCustomObject]@{ Count = 0; Bytes = [long]0 } }
    if ($null -eq $resp.results -or $resp.results.Count -eq 0) {
        return [PSCustomObject]@{ Count = 0; Bytes = [long]0 }
    }
    $dir = Join-Path $PageFolder ($FileBaseName + '-attachments')
    if ($dir.Length -gt (Get-MaxDirPathLength -Path $OutputRoot)) {
        $dir = Join-Path (Join-Path $OutputRoot '_a') $PageId
    }
    try { Ensure-DirectorySafe -Path $dir } catch { return [PSCustomObject]@{ Count = 0; Bytes = [long]0 } }

    $n = 0; $b = [long]0
    foreach ($att in $resp.results) {
        $dlPath = try { $att._links.download } catch { $null }
        if ([string]::IsNullOrWhiteSpace($dlPath)) { continue }
        $name = Get-SafeFileName -Name $att.title
        $ext  = [IO.Path]::GetExtension($name)
        $base = Get-CompactSafeName -Name ([IO.Path]::GetFileNameWithoutExtension($name)) -MaxLength 48
        if ([string]::IsNullOrWhiteSpace($base)) { $base = 'attachment' }
        $dest = Get-SafeOutputFilePath -Folder $dir -BaseName $base -Extension $ext
        $tmp  = New-LocalTempFilePath -Prefix "ca-$($att.id)" -Extension '.tmp'
        try {
            Invoke-WebRequest -Uri "$WikiBase$dlPath" -Method Get -OutFile $tmp -UseBasicParsing `
                -Headers @{ Authorization = $Headers['Authorization'] } -ErrorAction Stop | Out-Null
            if (Test-Path $tmp) { Copy-FileSafe -Source $tmp -Dest $dest; $n++; $b += (Get-Item $dest).Length }
        } catch {} finally {
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($n -eq 0) { try { Remove-Item $dir -Force -Recurse -ErrorAction SilentlyContinue } catch {} }
    return [PSCustomObject]@{ Count = $n; Bytes = $b }
}

# ==============================================================================
# MAIN
# ==============================================================================

$wiki    = Get-WikiBaseUrl -BaseUrl $ConfluenceBaseUrl
$api     = "$wiki/rest/api"
$headers = Get-AuthHeaders -UserEmail $Email -Token $ApiToken

Write-Host 'Verifying credentials...'
try {
    $me = Invoke-RestMethod -Uri "$api/user/current" -Method Get -Headers $headers -ErrorAction Stop
    Write-Host "Authenticated as: $($me.displayName)" -ForegroundColor Green
} catch {
    throw "Authentication failed: $($_.Exception.Message)"
}

Write-Host 'Establishing session...'
$session = New-ConfluenceSession -ApiBase $api -Headers $headers
if ($null -ne $session) { Write-Host 'Session established.' -ForegroundColor Green }
else { Write-Host 'No session - proceeding without cookie auth.' -ForegroundColor Yellow }

Write-Host "Resolving space home page for '$SpaceKey'..."
$homeId = Get-SpaceHomePageId -ApiBase $api -Space $SpaceKey -Headers $headers
Write-Host "  Home page ID: $homeId" -ForegroundColor DarkGray

$outDir = Join-Path $OutputPath $SpaceKey
if ($ExportMode -eq 'Full') {
    Write-Host 'Resetting output folder for a full refresh export...' -ForegroundColor DarkCyan
    if (Test-DirectoryExistsSafe -Path $outDir) {
        Remove-DirectoryTreeSafe -Path $outDir
    }
} else {
    Write-Host 'Running incremental export (changed/new pages only)...' -ForegroundColor DarkCyan
}
$null = Test-DirectoryWritable -Path $outDir
$statePath = Join-Path $outDir 'export-state.json'

$prevStateById = @{}
if ($ExportMode -eq 'Incremental') {
    $prevState = Read-JsonFileSafe -Path $statePath
    $prevPages = @()
    if ($null -ne $prevState) { $prevPages = @($prevState.pages) }
    foreach ($sp in $prevPages) {
        $sid = [string]$sp.id
        if (-not [string]::IsNullOrWhiteSpace($sid)) { $prevStateById[$sid] = $sp }
    }
    Write-Host ("  Previous state entries: {0}" -f $prevStateById.Count) -ForegroundColor DarkGray
}
Write-Host "Output root  : $outDir"
Write-Host "Temp staging : $(Get-LocalTempRoot)" -ForegroundColor DarkGray

Write-Host ''
Write-Host "Fetching all pages from space '$SpaceKey' (batch=$PageSize)..." -ForegroundColor Yellow
$pages = @(Get-AllPages -ApiBase $api -Space $SpaceKey -Headers $headers -BatchSize $PageSize)

if ($pages.Count -eq 0) {
    Write-Host "No pages found in space '$SpaceKey'." -ForegroundColor Red
    exit 0
}
Write-Host "Found $($pages.Count) pages." -ForegroundColor Green
Write-Host 'Strategy: Word (.doc) primary, HTML fallback + attachments' -ForegroundColor Green
Write-Host 'Materializing folder hierarchy from page ancestry...' -ForegroundColor DarkCyan
$hier = Initialize-HierarchyFolders -Pages $pages -HomeId $homeId -Root $outDir
Write-Host ("  Ready folders: {0} (parent nodes: {1})" -f $hier.Created, $hier.ParentNodes) -ForegroundColor DarkGray
Write-Host ''

$idx = 0; $failed = @(); $skipped = @(); $fmts = @{ doc = 0; html = 0 }; $unchanged = 0
$bytes = [long]0; $attTotal = 0; $attBytes = [long]0
$t0 = [DateTime]::UtcNow; $wordOff = $false; $wordStreak = 0
$currentStatePages = [System.Collections.Generic.List[object]]::new()
$currentPageIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

foreach ($pg in $pages) {
    $idx++
    $ps       = [DateTime]::UtcNow
    $identity = Resolve-PageIdentity -Page $pg -Index $idx
    $pageId   = $identity.Id
    $pageTitle = $identity.Title
    $safeName = Get-CompactSafeName -Name $pageTitle -MaxLength 52
    $baseName = '{0}-{1}' -f $safeName, $pageId

    if ([string]::IsNullOrWhiteSpace($pageId)) {
        $failed += [PSCustomObject]@{ Id = '(unknown)'; Title = $pageTitle; Reason = 'missing page id in API response' }
        Write-Host ("  FAIL ({0}) missing page id in API response" -f $pageTitle) -ForegroundColor Red
        continue
    }

    $null = $currentPageIds.Add($pageId)

    $ancestors = $pg.ancestors
    if ($null -ne $ancestors -and $null -ne $ancestors.results) { $ancestors = $ancestors.results }
    $ancCount = if ($null -ne $ancestors) { @($ancestors).Count } else { 0 }

    $folder = Get-PageFolderPath -Ancestors $ancestors -HomeId $homeId -Root $outDir
    try { $null = Test-DirectoryWritable -Path $folder }
    catch {
        $failed += [PSCustomObject]@{ Id = $pageId; Title = $pageTitle; Reason = "folder: $($_.Exception.Message)" }
        Write-Host ("  FAIL ({0}) folder: {1}" -f $pageId, $_.Exception.Message) -ForegroundColor Red
        continue
    }

    $rel     = $folder.Substring($outDir.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
    if ([string]::IsNullOrEmpty($rel)) { $rel = '.' }
    $pct     = [math]::Round(($idx / $pages.Count) * 100)
    $eta     = if ($idx -gt 1) {
                   $avg = ([DateTime]::UtcNow - $t0).TotalSeconds / ($idx - 1)
                   ' | ETA {0:hh\:mm\:ss}' -f [TimeSpan]::FromSeconds([math]::Round($avg * ($pages.Count - $idx + 1)))
               } else { '' }
    $ancInfo = if ($ancCount -gt 0) { " | anc:$ancCount" } else { '' }
    Write-Host ("[{0}/{1} {2}%{3}{4}] {5}" -f $idx, $pages.Count, $pct, $eta, $ancInfo, $pageTitle) -ForegroundColor Cyan

    $expectedPath = Get-SafeOutputFilePath -Folder $folder -BaseName $baseName -Extension '.doc'
    $currentVersion = 0
    try { $currentVersion = [int]$pg.version.number } catch { $currentVersion = 0 }

    $prev = $null
    if ($prevStateById.ContainsKey($pageId)) { $prev = $prevStateById[$pageId] }

    if ($ExportMode -eq 'Incremental' -and $null -ne $prev) {
        $prevVersion = 0
        try { $prevVersion = [int]$prev.version } catch { $prevVersion = 0 }
        $prevPath = [string]$prev.outputPath
        $sameVersion = ($prevVersion -eq $currentVersion)
        $samePath = (-not [string]::IsNullOrWhiteSpace($prevPath) -and ($prevPath -eq $expectedPath))
        if ($sameVersion -and $samePath -and (Test-Path -LiteralPath $expectedPath)) {
            $unchanged++
            $sz = 0; try { $sz = (Get-Item -LiteralPath $expectedPath -ErrorAction Stop).Length } catch {}
            $bytes += $sz
            Write-Host ("  KEEP unchanged v{0} | {1}" -f $currentVersion, $rel) -ForegroundColor DarkGreen
            $currentStatePages.Add([PSCustomObject]@{
                id = $pageId; title = $pageTitle; version = $currentVersion
                outputPath = $expectedPath; folder = $folder; baseName = $baseName
                format = [string]$prev.format; attachmentsPath = [string]$prev.attachmentsPath
            }) | Out-Null
            continue
        }
    }

    $result = $null; $reason = ''

    # --- Word (primary) ---
    if (-not $wordOff) {
        $docDest = $expectedPath
        $wCode = 0; $wMsg = ''
        for ($t = 1; $t -le 3; $t++) {
            try {
                $result = Save-PageWord -WikiBase $wiki -PageId $pageId -Headers $headers -DestPath $docDest -Session $session
                if ($result.OK) { $wordStreak = 0; $wMsg = ''; break }
                $result = $null; $wMsg = 'empty/undersized response'
                if ($t -lt 3) { Start-Sleep -Milliseconds (1000 * $t) }
            } catch {
                $result = $null; $wMsg = $_.Exception.Message; $wCode = 0
                if ($null -ne $_.Exception.Response) { try { $wCode = [int]$_.Exception.Response.StatusCode } catch {} }
                if ($wCode -in @(401, 403)) { $wordOff = $true; Write-Host "  Word HTTP $wCode - switching to HTML" -ForegroundColor Yellow; break }
                if ($t -lt 3) { Start-Sleep -Milliseconds (1000 * $t) }
            }
        }
        if ($null -eq $result -or -not $result.OK) { $reason = $wMsg; if ($wCode -gt 0) { $wordStreak++ } }
        if (-not $wordOff -and $wordStreak -ge 3) { $wordOff = $true; Write-Host '  Word failed 3x - switching to HTML' -ForegroundColor Yellow }
    }

    # --- HTML fallback ---
    if ($null -eq $result -or -not $result.OK) {
        $htmlDest = $expectedPath
        $body     = Get-PageBodyHtml -ApiBase $api -PageId $pageId -Headers $headers
        try {
            $result = Save-PageHtml -WikiBase $wiki -PageId $pageId -PageTitle $pageTitle -BodyHtml $body -DestPath $htmlDest
            if (-not $result.OK -and $result.Fmt -eq 'empty') { $reason = 'empty page (container/parent)' }
        } catch {
            $result = [PSCustomObject]@{ OK = $false; Fmt = $null; Path = $null }
            $reason = "HTML write failed: $($_.Exception.Message)"
        }
    }

    $dur = ([DateTime]::UtcNow - $ps).TotalSeconds

    if ($result.OK) {
        $fmts[$result.Fmt]++
        $sz = 0; try { $sz = (Get-Item -LiteralPath $result.Path -ErrorAction Stop).Length } catch {}
        $bytes += $sz
        $szStr = if ($sz -ge 1MB) { '{0:N1} MB' -f ($sz/1MB) } elseif ($sz -ge 1KB) { '{0:N0} KB' -f ($sz/1KB) } else { "$sz B" }
        Write-Host ("  OK   {0} | {1} | {2:N1}s | {3}" -f $result.Fmt.ToUpper().PadRight(4), $szStr, $dur, $rel) -ForegroundColor Green

        $att = Save-PageAttachments -ApiBase $api -WikiBase $wiki -PageId $pageId `
                   -Headers $headers -PageFolder $folder -FileBaseName $baseName -OutputRoot $outDir
        $attPath = Join-Path $folder ($baseName + '-attachments')
        if ($att.Count -eq 0) { $attPath = $null }
        if ($att.Count -gt 0) {
            $attTotal += $att.Count; $attBytes += $att.Bytes; $bytes += $att.Bytes
            $aStr = if ($att.Bytes -ge 1KB) { '{0:N0} KB' -f ($att.Bytes/1KB) } else { "$($att.Bytes) B" }
            Write-Host ("       + $($att.Count) attachment(s) | $aStr") -ForegroundColor DarkCyan
        }

        if ($ExportMode -eq 'Incremental' -and $null -ne $prev) {
            $prevPath = [string]$prev.outputPath
            if (-not [string]::IsNullOrWhiteSpace($prevPath) -and $prevPath -ne $result.Path) {
                Remove-FileIfExistsSafe -Path $prevPath
            }
            $prevAttPath = [string]$prev.attachmentsPath
            if (-not [string]::IsNullOrWhiteSpace($prevAttPath) -and $prevAttPath -ne $attPath) {
                try { Remove-DirectoryTreeSafe -Path $prevAttPath } catch {}
            }
        }

        $currentStatePages.Add([PSCustomObject]@{
            id = $pageId; title = $pageTitle; version = $currentVersion
            outputPath = $result.Path; folder = $folder; baseName = $baseName
            format = $result.Fmt; attachmentsPath = $attPath
        }) | Out-Null
    } else {
        $r = if ($reason) { $reason } else { 'unknown error' }
        if ($reason -match 'empty page') {
            $skipped += [PSCustomObject]@{ Id = $pageId; Title = $pageTitle; Reason = $r }
            Write-Host ("  SKIP empty ({0}) | {1:N1}s" -f $pageId, $dur) -ForegroundColor DarkYellow
            $currentStatePages.Add([PSCustomObject]@{
                id = $pageId; title = $pageTitle; version = $currentVersion
                outputPath = $null; folder = $folder; baseName = $baseName
                format = 'empty'; attachmentsPath = $null
            }) | Out-Null
        } else {
            $failed += [PSCustomObject]@{ Id = $pageId; Title = $pageTitle; Reason = $r }
            Write-Host ("  FAIL ({0}) | {1:N1}s | {2}" -f $pageId, $dur, $r) -ForegroundColor Red
        }
    }

    if ($idx % 10 -eq 0 -and $idx -lt $pages.Count) {
        $el  = [TimeSpan]::FromSeconds(([DateTime]::UtcNow - $t0).TotalSeconds)
        $exp = $fmts.doc + $fmts.html
        $ts  = if ($bytes -ge 1MB) { '{0:N1} MB' -f ($bytes/1MB) } elseif ($bytes -ge 1KB) { '{0:N0} KB' -f ($bytes/1KB) } else { "$bytes B" }
        Write-Host ("  --- {0} exported (DOC:{1} HTML:{2}) | {3} failed | {4} | elapsed {5:hh\:mm\:ss} ---" -f `
            $exp, $fmts.doc, $fmts.html, $failed.Count, $ts, $el) -ForegroundColor DarkGray
    }
}

if ($ExportMode -eq 'Incremental' -and $prevStateById.Count -gt 0) {
    $removed = 0
    foreach ($kv in $prevStateById.GetEnumerator()) {
        $pid = [string]$kv.Key
        if ($currentPageIds.Contains($pid)) { continue }
        $rec = $kv.Value
        $oldPath = [string]$rec.outputPath
        if (-not [string]::IsNullOrWhiteSpace($oldPath)) {
            Remove-FileIfExistsSafe -Path $oldPath
        }
        $oldAttPath = [string]$rec.attachmentsPath
        if (-not [string]::IsNullOrWhiteSpace($oldAttPath)) {
            try { Remove-DirectoryTreeSafe -Path $oldAttPath } catch {}
        }
        $removed++
    }
    if ($removed -gt 0) {
        Write-Host ("  Cleanup: removed {0} stale page export(s)" -f $removed) -ForegroundColor DarkGray
    }
}

# ==============================================================================
# SUMMARY
# ==============================================================================

$exported = $fmts.doc + $fmts.html
$elapsed  = [TimeSpan]::FromSeconds(([DateTime]::UtcNow - $t0).TotalSeconds)
$stamp    = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$sumPath  = Join-Path $outDir "export-summary-$stamp.json"
$totalStr = if ($bytes -ge 1MB) { '{0:N1} MB' -f ($bytes/1MB) } elseif ($bytes -ge 1KB) { '{0:N0} KB' -f ($bytes/1KB) } else { "$bytes bytes" }

$summary = [PSCustomObject]@{
    runAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
    durationSec    = [math]::Round($elapsed.TotalSeconds)
    exportMode     = $ExportMode
    spaceKey       = $SpaceKey
    confluence     = $wiki
    totalPages     = $pages.Count
    exported       = [PSCustomObject]@{ doc = $fmts.doc; html = $fmts.html }
    exportedCount  = $exported
    unchangedCount = $unchanged
    totalSizeBytes = $bytes
    attachments    = [PSCustomObject]@{ count = $attTotal; bytes = $attBytes }
    failedCount    = $failed.Count
    failures       = $failed
    skippedCount   = $skipped.Count
    skipped        = $skipped
    outputFolder   = $outDir
}
Write-FileSafe -Path $sumPath -Text ($summary | ConvertTo-Json -Depth 5)

$state = [PSCustomObject]@{
    runAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    spaceKey = $SpaceKey
    exportMode = $ExportMode
    pages = $currentStatePages
}
Write-FileSafe -Path $statePath -Text ($state | ConvertTo-Json -Depth 6)

Write-Host ''
Write-Host '--- EXPORT COMPLETE ---' -ForegroundColor Cyan
Write-Host "  Space    : $SpaceKey"
Write-Host "  Mode     : $ExportMode"
Write-Host "  Pages    : $($pages.Count)"
Write-Host "  Exported : $exported  (DOC: $($fmts.doc) | HTML: $($fmts.html))" -ForegroundColor Green
Write-Host ("  Kept     : {0} unchanged" -f $unchanged) -ForegroundColor DarkGreen
Write-Host ("  Skipped  : {0}" -f $skipped.Count) -ForegroundColor $(if ($skipped.Count -gt 0) { 'DarkYellow' } else { 'Green' })
if ($attTotal -gt 0) {
    $atStr = if ($attBytes -ge 1KB) { '{0:N0} KB' -f ($attBytes/1KB) } else { "$attBytes B" }
    Write-Host "  Attach.  : $attTotal files ($atStr)" -ForegroundColor DarkCyan
}
Write-Host ("  Failed   : {0}" -f $failed.Count) -ForegroundColor $(if ($failed.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Size     : $totalStr"
Write-Host ('  Duration : {0:hh\:mm\:ss}' -f $elapsed)
Write-Host "  Output   : $outDir"
Write-Host "  Summary  : $sumPath"
Write-Host "  State    : $statePath"

if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host '  Failed pages:' -ForegroundColor Red
    foreach ($f in $failed) {
        $ft = if ([string]::IsNullOrWhiteSpace([string]$f.Title)) { '(untitled)' } else { $f.Title }
        $fi = if ([string]::IsNullOrWhiteSpace([string]$f.Id)) { '(unknown)' } else { $f.Id }
        Write-Host "    - $ft (ID $fi)" -ForegroundColor Red
    }
    Write-Host ''
    exit 2
}
Write-Host ''

