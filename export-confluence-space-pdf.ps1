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

# ==============================================================================
# HELPER FUNCTIONS
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

function New-ConfluenceSession {
    param([string]$ApiBase, [hashtable]$Headers)
    try {
        $null = Invoke-WebRequest -Uri "$ApiBase/user/current" -Method Get `
                    -Headers $Headers -SessionVariable 'sess' -UseBasicParsing -ErrorAction Stop
        return $sess
    }
    catch {
        return $null
    }
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
    param(
        [string]$Name,
        [int]$MaxLength = 60
    )

    $safe = Get-SafeFileName -Name $Name
    if ($safe.Length -le $MaxLength) { return $safe }

    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($safe)
        $hashBytes = $md5.ComputeHash($bytes)
    }
    finally {
        $md5.Dispose()
    }

    $hash = ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant().Substring(0, 8)
    $headLen = [Math]::Max(8, $MaxLength - 9)
    return ($safe.Substring(0, $headLen).TrimEnd() + '-' + $hash)
}

function Get-SafeOutputFilePath {
    param(
        [string]$Folder,
        [string]$BaseName,
        [string]$Extension,
        [int]$MaxPathLength = 235
    )

    $ext = if ([string]::IsNullOrWhiteSpace($Extension)) { '' }
           elseif ($Extension.StartsWith('.')) { $Extension }
           else { ".{0}" -f $Extension }

    $dest = Join-Path $Folder ($BaseName + $ext)
    if ($dest.Length -le $MaxPathLength) { return $dest }

    $excess = $dest.Length - $MaxPathLength
    $newLen = [Math]::Max(12, $BaseName.Length - $excess - 2)
    $shortBase = Get-CompactSafeName -Name $BaseName -MaxLength $newLen
    $dest = Join-Path $Folder ($shortBase + $ext)

    if ($dest.Length -le $MaxPathLength) { return $dest }
    $fallbackBase = Get-CompactSafeName -Name $BaseName -MaxLength 20
    return (Join-Path $Folder ($fallbackBase + $ext))
}

function Write-FileSafe {
    # Writes text via local temp file, then copies to destination with retries.
    # This avoids direct WriteAllText calls against flaky network/redirected paths.
    param([string]$Path, [string]$Text)
    $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), ([IO.Path]::GetRandomFileName() + '.txt'))
    for ($try = 1; $try -le 3; $try++) {
        try {
            [IO.File]::WriteAllText($tmp, $Text, [Text.Encoding]::UTF8)
            Copy-FileSafe -Source $tmp -Dest $Path
            return
        }
        catch {
            if ($try -eq 3) { throw }
            Start-Sleep -Milliseconds (500 * $try)
        }
        finally {
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Assert-DirectoryWritable {
    param([string]$Path)

    $probe = Join-Path $Path ('.write-probe-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($probe, 'ok', [Text.Encoding]::ASCII)
    }
    catch {
        throw "Output path is not writable: $Path | $($_.Exception.Message)"
    }
    finally {
        if (Test-Path $probe) { Remove-Item $probe -Force -ErrorAction SilentlyContinue }
    }
}

function Test-ExtensionWritable {
    param(
        [string]$Folder,
        [string]$Extension
    )

    $ext = if ([string]::IsNullOrWhiteSpace($Extension)) { '.tmp' }
           elseif ($Extension.StartsWith('.')) { $Extension }
           else { ".{0}" -f $Extension }

    $probe = Join-Path $Folder ('.ext-probe-' + [Guid]::NewGuid().ToString('N') + $ext)
    try {
        [IO.File]::WriteAllText($probe, 'probe', [Text.Encoding]::ASCII)
        return [PSCustomObject]@{ OK = $true; Message = '' }
    }
    catch {
        return [PSCustomObject]@{ OK = $false; Message = $_.Exception.Message }
    }
    finally {
        if (Test-Path $probe) { Remove-Item $probe -Force -ErrorAction SilentlyContinue }
    }
}

function Ensure-DirectorySafe {
    param([string]$Path)
    for ($try = 1; $try -le 3; $try++) {
        try {
            if (-not [IO.Directory]::Exists($Path)) {
                [IO.Directory]::CreateDirectory($Path) | Out-Null
            }
            # Verify the directory actually exists after creation (catches silent failures on redirected drives)
            if (-not [IO.Directory]::Exists($Path)) {
                throw "Directory does not exist after creation attempt: $Path"
            }
            return
        }
        catch {
            if ($try -eq 3) { throw }
            Start-Sleep -Milliseconds (500 * $try)
        }
    }
}

function Copy-FileSafe {
    # Transfers a file using multiple write strategies.
    # Some storage providers (OneDrive placeholders, redirected/network drives,
    # filter drivers) can intermittently fail specific Win32/.NET write paths.
    # We try several methods before failing to improve reliability.
    param([string]$Source, [string]$Dest)
    for ($try = 1; $try -le 5; $try++) {
        $errors = @()
        $partial = "$Dest.__partial"

        try {
            $destDir = [IO.Path]::GetDirectoryName($Dest)
            if (-not [string]::IsNullOrEmpty($destDir) -and -not [IO.Directory]::Exists($destDir)) {
                [IO.Directory]::CreateDirectory($destDir) | Out-Null
            }
        }
        catch {
            if ($try -eq 5) { throw }
            Start-Sleep -Milliseconds (500 * $try)
            continue
        }

        # Method 1: ReadAllBytes + WriteAllBytes
        try {
            $bytes = [IO.File]::ReadAllBytes($Source)
            [IO.File]::WriteAllBytes($Dest, $bytes)
            return
        }
        catch {
            $errors += "WriteAllBytes: $($_.Exception.Message)"
            if (Test-Path $Dest) { Remove-Item $Dest -Force -ErrorAction SilentlyContinue }
        }

        # Method 2: stream copy to partial in destination folder, then atomic move
        try {
            if (Test-Path $partial) { Remove-Item $partial -Force -ErrorAction SilentlyContinue }

            $inStream = [IO.File]::OpenRead($Source)
            try {
                $outStream = [IO.File]::Open($partial, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $inStream.CopyTo($outStream)
                    $outStream.Flush()
                }
                finally {
                    $outStream.Dispose()
                }
            }
            finally {
                $inStream.Dispose()
            }

            Move-Item -LiteralPath $partial -Destination $Dest -Force
            return
        }
        catch {
            $errors += "StreamCopy: $($_.Exception.Message)"
            if (Test-Path $partial) { Remove-Item $partial -Force -ErrorAction SilentlyContinue }
        }

        # Method 3: Win32 CopyFile path
        try {
            [IO.File]::Copy($Source, $Dest, $true)
            return
        }
        catch {
            $errors += "File.Copy: $($_.Exception.Message)"
        }

        if ($try -eq 5) {
            throw "Copy failed after $try attempts. Source=$Source Dest=$Dest Errors=$($errors -join ' | ')"
        }

        Start-Sleep -Milliseconds (700 * $try)
    }
}

# ==============================================================================
# CONFLUENCE API
# ==============================================================================

function Get-SpaceHomePageId {
    param([string]$ApiBase, [string]$Space, [hashtable]$Headers)
    $uri  = "{0}/space/{1}?expand=homepage" -f $ApiBase, [uri]::EscapeDataString($Space)
    $resp = Invoke-RestMethod -Uri $uri -Headers $Headers
    return [string]$resp.homepage.id
}

function Get-ConfluencePages {
    param([string]$ApiBase, [string]$TargetSpace, [hashtable]$Headers, [int]$Limit)
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

function Get-PageFolderPath {
    # Windows dir path limit: 247 chars.
    # Longest suffix appended to the folder after this function returns:
    #   "\NNNN-<60charTitle>-attachments"  =  1 + 5 + 60 + 12 = 78 chars
    # Therefore the folder itself must stay at or below 247 - 78 = 169 chars.
    # NOTE: if $RootFolder is already >= 169 we cannot nest at all, but we still
    # return it as-is; the attachments guard in Save-PageAttachments handles that.
    param($Ancestors, [string]$SpaceHomeId, [string]$RootFolder)
    $folder    = $RootFolder
    $maxFolder = 169
    if ($null -ne $Ancestors) {
        foreach ($a in $Ancestors) {
            if ([string]$a.id -eq $SpaceHomeId) { continue }
            if ($folder.Length -ge $maxFolder) { break }
            $part      = Get-CompactSafeName -Name $a.title -MaxLength 50
            $candidate = Join-Path $folder $part
            if ($candidate.Length -gt $maxFolder) { break }
            $folder = $candidate
        }
    }
    return $folder
}

# ==============================================================================
# EXPORT: WORD (primary)
# Downloads to %TEMP% first, then copies to destination atomically.
# ==============================================================================

function Save-PageWord {
    param(
        [string]$WikiBase,
        [string]$PageId,
        [hashtable]$Headers,
        [string]$DestPath,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session
    )

    $url = "{0}/exportword?pageId={1}&os_authType=basic" -f $WikiBase, $PageId
    $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), "conf-word-$PageId.doc")

    $params = @{
        Uri                = $url
        Method             = 'Get'
        Headers            = @{ Authorization = $Headers['Authorization'] }
        MaximumRedirection = 10
        OutFile            = $tmp
        UseBasicParsing    = $true
        ErrorAction        = 'Stop'
    }
    if ($null -ne $Session) { $params['WebSession'] = $Session }

    try { Invoke-WebRequest @params | Out-Null }
    catch {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }

    if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt 100) {
        Copy-FileSafe -Source $tmp -Dest $DestPath
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ OK = $true; Fmt = 'doc'; Path = $DestPath }
    }

    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    return [PSCustomObject]@{ OK = $false; Fmt = $null; Path = $null }
}

# ==============================================================================
# EXPORT: HTML (fallback)
# Uses body.export_view already fetched in the listing call - no extra API call.
# ==============================================================================

function Save-PageHtml {
    param(
        [string]$WikiBase,
        [string]$PageId,
        [string]$PageTitle,
        [string]$BodyHtml,
        [string]$DestPath
    )

    if ([string]::IsNullOrWhiteSpace($BodyHtml)) {
        return [PSCustomObject]@{ OK = $false; Fmt = 'empty'; Path = $null }
    }

    $safe = [System.Net.WebUtility]::HtmlEncode($PageTitle)
    $src  = "{0}/pages/viewpage.action?pageId={1}" -f $WikiBase, $PageId

    # Build HTML using string concatenation to avoid any here-string encoding issues
    $head = '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/>'
    $head += '<meta name="generator" content="Confluence Export"/>'
    $head += '<meta name="source-page-id" content="' + $PageId + '"/>'
    $head += '<meta name="source-url" content="' + $src + '"/>'
    $head += '<title>' + $safe + '</title>'
    $head += '<style>'
    $head += 'body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;max-width:960px;margin:2em auto;padding:0 1em;color:#172B4D;line-height:1.6}'
    $head += 'h1{border-bottom:2px solid #0052CC;padding-bottom:.3em}'
    $head += 'h2,h3{color:#0052CC}'
    $head += 'a{color:#0052CC;text-decoration:underline}'
    $head += 'table{border-collapse:collapse;max-width:100%;margin:1em 0}'
    $head += 'th,td{border:1px solid #C1C7D0;padding:.5em .75em;text-align:left;word-wrap:break-word}'
    $head += 'th{background:#F4F5F7;font-weight:600}'
    $head += 'tr:nth-child(even){background:#FAFBFC}'
    $head += 'code,pre{background:#F4F5F7;border-radius:3px;font-size:.9em}'
    $head += 'pre{padding:1em;overflow-x:auto;white-space:pre-wrap}'
    $head += 'code{padding:.15em .3em}'
    $head += 'img{max-width:100%;height:auto}'
    $head += '.src{font-size:.85em;color:#6B778C;margin-bottom:1.5em}'
    $head += '.src a{color:#6B778C}'
    $head += '@media print{body{margin:0}.src{display:none}}'
    $head += '</style></head>'

    $body  = '<body>'
    $body += '<h1>' + $safe + '</h1>'
    $body += '<div class="src">Source: <a href="' + $src + '">View in Confluence</a></div>'
    $body += $BodyHtml
    $body += '</body></html>'

    $html = $head + $body

    Write-FileSafe -Path $DestPath -Text $html
    $fmt = [IO.Path]::GetExtension($DestPath).TrimStart('.').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($fmt)) { $fmt = 'html' }
    return [PSCustomObject]@{ OK = $true; Fmt = $fmt; Path = $DestPath }
}

# ==============================================================================
# ATTACHMENTS
# ==============================================================================

function Save-PageAttachments {
    param(
        [string]$ApiBase,
        [string]$WikiBase,
        [string]$PageId,
        [hashtable]$Headers,
        [string]$PageFolder,
        [string]$FileBaseName
    )

    $uri = "{0}/content/{1}/child/attachment?limit=100" -f $ApiBase, $PageId
    try { $resp = Invoke-RestMethod -Uri $uri -Headers $Headers -ErrorAction Stop }
    catch { return [PSCustomObject]@{ Count = 0; Bytes = [long]0 } }

    if ($null -eq $resp.results -or $resp.results.Count -eq 0) {
        return [PSCustomObject]@{ Count = 0; Bytes = [long]0 }
    }

    # Build attachments subfolder, capping total dir path below the 247-char Windows limit.
    # $FileBaseName can be up to 65 chars; adding "-attachments" makes the suffix 77 chars.
    # If the combined path would exceed 240 (safe margin below 247), shorten the subfolder name.
    $attSuffix = "$FileBaseName-attachments"
    $dir = Join-Path $PageFolder $attSuffix
    if ($dir.Length -gt 240) {
        $headroom  = [Math]::Max(8, 240 - $PageFolder.Length - 5)  # 5 = separator + "-att"
        $shortBase = Get-CompactSafeName -Name $FileBaseName -MaxLength $headroom
        $dir       = Join-Path $PageFolder "$shortBase-att"
    }
    Ensure-DirectorySafe -Path $dir

    $n = 0
    $b = [long]0

    foreach ($att in $resp.results) {
        $dlPath = $null
        try { $dlPath = $att._links.download } catch {}
        if ([string]::IsNullOrWhiteSpace($dlPath)) { continue }

        $name = Get-SafeFileName -Name $att.title
        $ext = [IO.Path]::GetExtension($name)
        $base = [IO.Path]::GetFileNameWithoutExtension($name)
        if ([string]::IsNullOrWhiteSpace($base)) { $base = 'attachment' }
        $base = Get-CompactSafeName -Name $base -MaxLength 48
        $dest = Get-SafeOutputFilePath -Folder $dir -BaseName $base -Extension $ext
        $tmp  = [IO.Path]::Combine([IO.Path]::GetTempPath(), "conf-att-$($att.id).tmp")
        $url  = "{0}{1}" -f $WikiBase, $dlPath

        try {
            Invoke-WebRequest -Uri $url -Method Get -OutFile $tmp -UseBasicParsing `
                -Headers @{ Authorization = $Headers['Authorization'] } -ErrorAction Stop | Out-Null
            if (Test-Path $tmp) {
                Copy-FileSafe -Source $tmp -Dest $dest
                $n++
                $b += (Get-Item $dest).Length
            }
        }
        catch { <# skip individual attachment failures silently #> }
        finally {
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
    }

    if ($n -eq 0 -and (Test-Path $dir)) {
        Remove-Item $dir -Force -Recurse -ErrorAction SilentlyContinue
    }
    return [PSCustomObject]@{ Count = $n; Bytes = $b }
}

# ==============================================================================
# MAIN
# ==============================================================================

$wiki    = Get-WikiBaseUrl -BaseUrl $ConfluenceBaseUrl
$api     = "$wiki/rest/api"
$headers = Get-AuthHeaders -UserEmail $Email -Token $ApiToken

# Verify credentials
Write-Host 'Verifying Confluence credentials...'
try {
    $me = Invoke-RestMethod -Uri "$api/user/current" -Headers $headers -ErrorAction Stop
    Write-Host "Authenticated as: $($me.displayName)" -ForegroundColor Green
}
catch {
    throw "Authentication failed. Check email and API token. Details: $($_.Exception.Message)"
}

# Establish session for /exportword cookie auth
Write-Host 'Establishing session...'
$session = New-ConfluenceSession -ApiBase $api -Headers $headers
if ($null -ne $session) {
    Write-Host 'Session established.' -ForegroundColor Green
}
else {
    Write-Host 'Session not available - proceeding without cookie auth.' -ForegroundColor Yellow
}

# Space home page ID (excluded from folder hierarchy)
$homeId = Get-SpaceHomePageId -ApiBase $api -Space $SpaceKey -Headers $headers

# Output root directory
$outDir = Join-Path $OutputPath $SpaceKey
Ensure-DirectorySafe -Path $outDir
Assert-DirectoryWritable -Path $outDir

# Some synced SharePoint/OneDrive targets block .html writes while allowing .doc.
# Probe once up front and select the safest fallback extension.
$htmlFallbackExtension = '.html'
$htmlProbe = Test-ExtensionWritable -Folder $outDir -Extension '.html'
if (-not $htmlProbe.OK) {
    $docProbe = Test-ExtensionWritable -Folder $outDir -Extension '.doc'
    if ($docProbe.OK) {
        $htmlFallbackExtension = '.doc'
        Write-Host ("Notice: .html writes are blocked at target. HTML fallback will be saved as .doc. Reason: {0}" -f $htmlProbe.Message) -ForegroundColor Yellow
    }
    else {
        Write-Host ("Warning: .html probe failed and .doc probe also failed. HTML fallback may fail. HTML reason: {0} | DOC reason: {1}" -f $htmlProbe.Message, $docProbe.Message) -ForegroundColor Yellow
    }
}

# Fetch all pages (body.export_view pre-fetched - avoids extra API calls later)
Write-Host ''
Write-Host "Fetching pages from space '$SpaceKey'..." -ForegroundColor Yellow
$pages = Get-ConfluencePages -ApiBase $api -TargetSpace $SpaceKey -Headers $headers -Limit $PageSize

if ($pages.Count -eq 0) {
    Write-Host 'No pages found.' -ForegroundColor Red
    exit 0
}

Write-Host "Found $($pages.Count) pages. Exporting to: $outDir" -ForegroundColor Green
Write-Host 'Strategy: Word (.doc) primary, HTML fallback + attachments' -ForegroundColor Green
Write-Host ''

# Counters
$idx        = 0
$failed     = @()
$fmts       = @{ doc = 0; html = 0 }
$bytes      = [long]0
$attTotal   = 0
$attBytes   = [long]0
$t0         = [DateTime]::UtcNow
$wordOff    = $false
$wordStreak = 0

foreach ($pg in $pages) {
    $idx++
    $ps = [DateTime]::UtcNow

    $safeName = Get-CompactSafeName -Name $pg.title -MaxLength 60
    $baseName = '{0:D4}-{1}' -f $idx, $safeName

    # Determine folder from page hierarchy
    $folder = Get-PageFolderPath -Ancestors $pg.ancestors -SpaceHomeId $homeId -RootFolder $outDir
    try {
        Ensure-DirectorySafe -Path $folder
    }
    catch {
        $failed += [PSCustomObject]@{ Id = $pg.id; Title = $pg.title; Reason = "Could not create output folder: $($_.Exception.Message)" }
        Write-Host ('  FAIL ({0}) | folder create error: {1}' -f $pg.id, $_.Exception.Message) -ForegroundColor Red
        continue
    }

    # Verify the output folder is accessible before attempting writes
    if (-not [IO.Directory]::Exists($folder)) {
        $failed += [PSCustomObject]@{ Id = $pg.id; Title = $pg.title; Reason = "Output folder inaccessible or could not be created: $folder" }
        Write-Host ('  FAIL ({0}) | folder unavailable: {1}' -f $pg.id, $folder) -ForegroundColor Red
        continue
    }

    $rel = $folder.Substring($outDir.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
    if ([string]::IsNullOrEmpty($rel)) { $rel = '.' }

    # Progress indicator
    $pct = [math]::Round(($idx / $pages.Count) * 100)
    $eta = ''
    if ($idx -gt 1) {
        $avg = ([DateTime]::UtcNow - $t0).TotalSeconds / ($idx - 1)
        $rem = $avg * ($pages.Count - $idx + 1)
        $eta = ' | ETA {0:hh\:mm\:ss}' -f [TimeSpan]::FromSeconds([math]::Round($rem))
    }
    Write-Host ('[{0}/{1} {2}%{3}] {4}' -f $idx, $pages.Count, $pct, $eta, $pg.title) -ForegroundColor Cyan

    $result = $null
    $reason = ''

    # --- WORD (primary) ---
    if (-not $wordOff) {
        $docDest = Get-SafeOutputFilePath -Folder $folder -BaseName $baseName -Extension '.doc'
        try {
            $result = Save-PageWord -WikiBase $wiki -PageId $pg.id `
                          -Headers $headers -DestPath $docDest -Session $session
            if ($result.OK) {
                $wordStreak = 0
            }
            else {
                $wordStreak++
                $reason = 'Word: empty or undersized response'
            }
        }
        catch {
            $reason = $_.Exception.Message
            $httpCode = 0
            if ($null -ne $_.Exception.Response) {
                try { $httpCode = [int]$_.Exception.Response.StatusCode } catch {}
            }
            if ($httpCode -in @(401, 403)) {
                $wordOff = $true
                Write-Host "  Word returned HTTP $httpCode - switching to HTML only" -ForegroundColor Yellow
            }
            elseif ($httpCode -gt 0) {
                # Only count HTTP errors toward streak - not I/O errors
                $wordStreak++
            }
            $result = $null
        }

        if ((-not $wordOff) -and $wordStreak -ge 3) {
            $wordOff = $true
            Write-Host '  Word failed 3x via HTTP - switching to HTML only' -ForegroundColor Yellow
        }
    }

    # --- HTML (fallback) ---
    if ($null -eq $result -or -not $result.OK) {
        $htmlDest = Get-SafeOutputFilePath -Folder $folder -BaseName $baseName -Extension $htmlFallbackExtension

        # Use body already fetched during page listing - no extra API call needed
        $body = $null
        try { $body = $pg.body.export_view.value } catch {}

        try {
            $result = Save-PageHtml -WikiBase $wiki -PageId $pg.id `
                          -PageTitle $pg.title -BodyHtml $body -DestPath $htmlDest
            if (-not $result.OK -and $result.Fmt -eq 'empty') {
                $reason = 'empty page (container/parent)'
            }
        }
        catch {
            if ($htmlFallbackExtension -eq '.html') {
                try {
                    $altDest = Get-SafeOutputFilePath -Folder $folder -BaseName $baseName -Extension '.doc'
                    $result = Save-PageHtml -WikiBase $wiki -PageId $pg.id `
                                  -PageTitle $pg.title -BodyHtml $body -DestPath $altDest
                    Write-Host '  HTML write blocked; saved fallback content as DOC wrapper' -ForegroundColor Yellow
                }
                catch {
                    $result = [PSCustomObject]@{ OK = $false; Fmt = $null; Path = $null }
                    $pathLen = 0
                    try { $pathLen = $htmlDest.Length } catch {}
                    $reason = "HTML write failed (len=$pathLen): $($_.Exception.Message)"
                }
            }
            else {
                $result = [PSCustomObject]@{ OK = $false; Fmt = $null; Path = $null }
                $pathLen = 0
                try { $pathLen = $htmlDest.Length } catch {}
                $reason = "Fallback write failed (len=$pathLen): $($_.Exception.Message)"
            }
        }
    }

    $dur = ([DateTime]::UtcNow - $ps).TotalSeconds

    if ($result.OK) {
        $fmts[$result.Fmt]++
        $sz    = (Get-Item $result.Path).Length
        $bytes += $sz

        if ($sz -ge 1MB)      { $szStr = '{0:N1} MB' -f ($sz / 1MB) }
        elseif ($sz -ge 1KB)  { $szStr = '{0:N0} KB' -f ($sz / 1KB) }
        else                  { $szStr = "$sz B" }

        Write-Host ('  OK   {0} | {1} | {2:N1}s | {3}' -f `
            $result.Fmt.ToUpper().PadRight(4), $szStr, $dur, $rel) -ForegroundColor Green

        # Download attachments
        $att = Save-PageAttachments -ApiBase $api -WikiBase $wiki -PageId $pg.id `
                   -Headers $headers -PageFolder $folder -FileBaseName $baseName
        if ($att.Count -gt 0) {
            $attTotal  += $att.Count
            $attBytes  += $att.Bytes
            $bytes     += $att.Bytes
            if ($att.Bytes -ge 1KB) { $aStr = '{0:N0} KB' -f ($att.Bytes / 1KB) }
            else                    { $aStr = "$($att.Bytes) B" }
            Write-Host ("       + $($att.Count) attachment(s) | $aStr") -ForegroundColor DarkCyan
        }
    }
    else {
        $r = if ($reason) { $reason } else { 'unknown error' }
        $failed += [PSCustomObject]@{ Id = $pg.id; Title = $pg.title; Reason = $r }

        if ($reason -match 'empty page') {
            Write-Host ('  SKIP empty page ({0}) | {1:N1}s' -f $pg.id, $dur) -ForegroundColor DarkYellow
        }
        else {
            Write-Host ('  FAIL ({0}) | {1:N1}s | {2}' -f $pg.id, $dur, $r) -ForegroundColor Red
        }
    }

    # Progress summary every 10 pages
    if ($idx % 10 -eq 0 -and $idx -lt $pages.Count) {
        $el  = [TimeSpan]::FromSeconds(([DateTime]::UtcNow - $t0).TotalSeconds)
        $exp = $fmts.doc + $fmts.html
        if ($bytes -ge 1MB)     { $ts = '{0:N1} MB' -f ($bytes / 1MB) }
        elseif ($bytes -ge 1KB) { $ts = '{0:N0} KB' -f ($bytes / 1KB) }
        else                    { $ts = "$bytes B" }
        Write-Host ('  --- {0} exported (DOC:{1} HTML:{2}) | {3} failed | {4} | {5:hh\:mm\:ss} ---' -f `
            $exp, $fmts.doc, $fmts.html, $failed.Count, $ts, $el) -ForegroundColor DarkGray
    }
}

# ==============================================================================
# SUMMARY
# ==============================================================================

$exported = $fmts.doc + $fmts.html
$elapsed  = [TimeSpan]::FromSeconds(([DateTime]::UtcNow - $t0).TotalSeconds)
$stamp    = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$sumPath  = Join-Path $outDir "export-summary-$stamp.json"

if ($bytes -ge 1MB)     { $totalStr = '{0:N1} MB'  -f ($bytes / 1MB) }
elseif ($bytes -ge 1KB) { $totalStr = '{0:N0} KB'  -f ($bytes / 1KB) }
else                    { $totalStr = "$bytes bytes" }

$summary = [PSCustomObject]@{
    runAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
    durationSec    = [math]::Round($elapsed.TotalSeconds)
    spaceKey       = $SpaceKey
    confluence     = $wiki
    totalPages     = $pages.Count
    exported       = [PSCustomObject]@{ doc = $fmts.doc; html = $fmts.html }
    exportedCount  = $exported
    totalSizeBytes = $bytes
    attachments    = [PSCustomObject]@{ count = $attTotal; bytes = $attBytes }
    failedCount    = $failed.Count
    failures       = $failed
    outputFolder   = $outDir
}

# Write summary using atomic WriteAllText - same as HTML pages
Write-FileSafe -Path $sumPath -Text ($summary | ConvertTo-Json -Depth 5)

Write-Host ''
Write-Host '--- EXPORT COMPLETE ---' -ForegroundColor Cyan
Write-Host "  Space    : $SpaceKey"
Write-Host "  Pages    : $($pages.Count)"
Write-Host "  Exported : $exported  (DOC: $($fmts.doc) | HTML: $($fmts.html))" -ForegroundColor Green
if ($attTotal -gt 0) {
    if ($attBytes -ge 1KB) { $atStr = '{0:N0} KB' -f ($attBytes / 1KB) }
    else                   { $atStr = "$attBytes B" }
    Write-Host "  Attach.  : $attTotal files ($atStr)" -ForegroundColor DarkCyan
}
if ($failed.Count -gt 0) {
    Write-Host "  Failed   : $($failed.Count)" -ForegroundColor Red
}
else {
    Write-Host "  Failed   : 0" -ForegroundColor Green
}
Write-Host "  Size     : $totalStr"
Write-Host ('  Duration : {0:hh\:mm\:ss}' -f $elapsed)
Write-Host "  Output   : $outDir"
Write-Host "  Summary  : $sumPath"

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
