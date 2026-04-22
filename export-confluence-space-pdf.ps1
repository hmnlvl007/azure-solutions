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

$script:TempRoot = $null
$script:WritableDirectoryCache = @{}

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

function Get-MaxDirectoryPathLength {
    param([string]$Path)

    if (Test-IsTsClientPath -Path $Path) {
        return 190
    }

    return 240
}

function Get-LocalTempRoot {
    if (-not [string]::IsNullOrWhiteSpace($script:TempRoot)) {
        return $script:TempRoot
    }

    $candidates = @(
        $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Join-Path $env:LOCALAPPDATA 'ConfluenceExportStaging' }),
        $env:TEMP,
        $env:TMP,
        [IO.Path]::GetTempPath(),
        $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Join-Path $env:LOCALAPPDATA 'Temp' }),
        $(if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { Join-Path $env:USERPROFILE 'AppData\Local\Temp' }),
        $(if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { Join-Path $PSScriptRoot '.tmp' })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($dir in $candidates) {
        $probe = $null
        try {
            [IO.Directory]::CreateDirectory($dir) | Out-Null
            $probe = Join-Path $dir ('.probe-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            [IO.File]::WriteAllText($probe, 'ok', [Text.Encoding]::ASCII)
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            $script:TempRoot = $dir
            return $script:TempRoot
        }
        catch {
            if ($probe) {
                Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            }
        }
    }

    throw 'Could not locate a writable local temp folder for staging export files.'
}

function Test-IsTsClientPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return $Path.StartsWith('\\tsclient\', [StringComparison]::OrdinalIgnoreCase)
}

function New-LocalTempFilePath {
    param(
        [string]$Prefix = 'conf',
        [string]$Extension = '.tmp'
    )

    $ext = if ([string]::IsNullOrWhiteSpace($Extension)) { '.tmp' }
           elseif ($Extension.StartsWith('.')) { $Extension }
           else { ".{0}" -f $Extension }

    $name = '{0}-{1}{2}' -f $Prefix, [Guid]::NewGuid().ToString('N'), $ext
    return (Join-Path (Get-LocalTempRoot) $name)
}

function Remove-FileQuietly {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    $restoreNativePreference = $false
    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
        $restoreNativePreference = $true
        $previousNativePreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }

    try {
        $null = cmd /d /c "if exist `"$Path`" del /F /Q `"$Path`"" 2>$null
    }
    catch {
        # Best-effort cleanup only.
    }
    finally {
        if ($restoreNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
    }
}

function Test-DirectoryExistsSafe {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    try {
        return [IO.Directory]::Exists($Path)
    }
    catch {
        try {
            $null = cmd /d /c "if exist `"$Path\NUL`" (exit 0) else (exit 1)" 2>$null
            return ($LASTEXITCODE -eq 0)
        }
        catch {
            return $false
        }
    }
}

function Write-FileSafe {
    # Writes text via a local temp file then copies to destination with retries.
    # IMPORTANT: $tmp must be declared INSIDE the loop so each retry creates a
    # fresh temp file. The finally block deletes it after every iteration
    # (success or failure), which is correct - each retry writes a new one.
    # The retry + sleep is intentional: on \\tsclient\ RDP redirected paths,
    # the first write to a newly-created folder can fail while OneDrive is
    # still registering the directory. A short delay before retry succeeds.
    param([string]$Path, [string]$Text)
    for ($try = 1; $try -le 3; $try++) {
        $tmp = New-LocalTempFilePath -Prefix 'conf-write' -Extension '.tmp'
        try {
            [IO.File]::WriteAllText($tmp, $Text, [Text.Encoding]::UTF8)
            Copy-FileSafe -Source $tmp -Dest $Path
            return
        }
        catch {
            if ($try -eq 3) {
                throw "File write failed. TempRoot=$(Get-LocalTempRoot) | $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds (800 * $try)
        }
        finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Assert-DirectoryWritable {
    param([string]$Path)

    # Use a temp-file + cmd copy probe so this works on \\tsclient\ paths
    # where [IO.File]::WriteAllText fails with "device not functioning".
    $probeName = '.write-probe-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $localTmp  = Join-Path (Get-LocalTempRoot) $probeName
    $destProbe = Join-Path $Path $probeName
    try {
        Ensure-DirectorySafe -Path $Path
        [IO.File]::WriteAllText($localTmp, 'ok', [Text.Encoding]::ASCII)
        $null = cmd /c "copy /Y `"$localTmp`" `"$destProbe`"" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "cmd copy probe failed (exit $LASTEXITCODE)"
        }

    }
    catch {
        throw "Output path is not writable: $Path | $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $localTmp) { Remove-Item -LiteralPath $localTmp -Force -ErrorAction SilentlyContinue }
        # Do NOT use Test-Path on $destProbe - it is a \tsclient\ path and throws.
        # Best-effort cleanup only; redirected paths can emit benign stderr.
        Remove-FileQuietly -Path $destProbe
    }
}

function Ensure-DirectorySafe {
    param([string]$Path)

    if (Test-DirectoryExistsSafe -Path $Path) { return }

    $errors = @()
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            [IO.Directory]::CreateDirectory($Path) | Out-Null
        }
        catch {
            $errors += ("CreateDirectory try {0}: {1}" -f $attempt, $_.Exception.Message)
        }

        if (-not (Test-DirectoryExistsSafe -Path $Path)) {
            try {
                $null = cmd /d /c "mkdir `"$Path`"" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $errors += ("cmd mkdir try {0}: exit {1}" -f $attempt, $LASTEXITCODE)
                }
            }
            catch {
                $errors += ("cmd mkdir try {0}: {1}" -f $attempt, $_.Exception.Message)
            }
        }

        if (Test-DirectoryExistsSafe -Path $Path) {
            return
        }

        Start-Sleep -Milliseconds (300 * $attempt)
    }

    if (-not (Test-DirectoryExistsSafe -Path $Path)) {
        $detail = if ($errors.Count -gt 0) { " | " + ($errors -join ' | ') } else { '' }
        throw ("Could not create directory: {0}{1}" -f $Path, $detail)
    }
}

function Test-DirectoryWritable {
    param(
        [string]$Path,
        [int]$MaxAttempts = 6,
        [int]$BaseDelayMs = 1000
    )

    if ($script:WritableDirectoryCache.ContainsKey($Path)) {
        return $true
    }

    for ($try = 1; $try -le $MaxAttempts; $try++) {
        try {
            Ensure-DirectorySafe -Path $Path
            Assert-DirectoryWritable -Path $Path
            $script:WritableDirectoryCache[$Path] = $true
            return $true
        }
        catch {
            if ($try -eq $MaxAttempts) {
                throw
            }
            Start-Sleep -Milliseconds ($BaseDelayMs * $try)
        }
    }

    return $false
}

function Copy-FileSafe {
    # Transfers a source file to a destination using multiple fallback strategies.
    #
    # The destination may be an RDP-redirected client drive (\\tsclient\C\...).
    # On such paths ALL .NET / Win32 file-write APIs (WriteAllBytes, FileStream,
    # File.Copy) fail with "A device attached to the system is not functioning"
    # because they route through NtWriteFile which the TS client redirector does
    # not support reliably.
    #
    # cmd.exe  "copy /Y"  and  robocopy  use the SMB-layer redirector path and
    # are the only methods that work reliably on \\tsclient\ paths.
    # We therefore try .NET methods first (fast for local paths) and fall through
    # to cmd copy / robocopy so that \\tsclient\ targets always succeed.
    param([string]$Source, [string]$Dest)

    $errors = @()

    # Ensure destination directory exists.
    # Do NOT call [IO.Directory]::Exists() outside a try/catch - on \tsclient\
    # RDP redirected paths it can throw IOException uncaught (ERROR_DEV_NOT_EXIST).
    $destDir = [IO.Path]::GetDirectoryName($Dest)
    if (-not [string]::IsNullOrEmpty($destDir)) {
        Ensure-DirectorySafe -Path $destDir
        $null = Test-DirectoryWritable -Path $destDir
    }

    $isTsClient = (Test-IsTsClientPath -Path $Dest) -or (Test-IsTsClientPath -Path $destDir)

    if ($isTsClient) {
        for ($copyTry = 1; $copyTry -le 5; $copyTry++) {
            try {
                $null = cmd /c "copy /Y `"$Source`" `"$Dest`"" 2>&1
                if ($LASTEXITCODE -eq 0) { return }
                $errors += ("cmd copy try {0}: exit {1}" -f $copyTry, $LASTEXITCODE)
            }
            catch {
                $errors += ("cmd copy try {0}: {1}" -f $copyTry, $_.Exception.Message)
            }

            try {
                $srcFile = [IO.Path]::GetFileName($Source)
                $srcDir  = [IO.Path]::GetDirectoryName($Source)
                $tmpDest = Join-Path $destDir $srcFile
                $null = robocopy $srcDir $destDir $srcFile /R:2 /W:1 /NP /NJH /NJS 2>&1
                if ($LASTEXITCODE -le 1) {
                    if ($srcFile -ne [IO.Path]::GetFileName($Dest)) {
                        $null = cmd /c "move /Y `"$tmpDest`" `"$Dest`"" 2>&1
                    }
                    return
                }
                $errors += ("robocopy try {0}: exit {1}" -f $copyTry, $LASTEXITCODE)
            }
            catch {
                $errors += ("robocopy try {0}: {1}" -f $copyTry, $_.Exception.Message)
            }

            Start-Sleep -Milliseconds (750 * $copyTry)
        }

        throw "Copy failed. Source=$Source Dest=$Dest Errors=$($errors -join ' | ')"
    }

    # Method 1: .NET WriteAllBytes  (works for local / UNC shares, NOT \\tsclient\)
    try {
        $bytes = [IO.File]::ReadAllBytes($Source)
        [IO.File]::WriteAllBytes($Dest, $bytes)
        return
    }
    catch {
        $errors += "WriteAllBytes: $($_.Exception.Message)"
        # Attempt cleanup - may silently fail on \\tsclient\, that is fine
        Remove-FileQuietly -Path $Dest
    }

    # Method 2: .NET File.Copy  (same Win32 layer as above, worth one try)
    try {
        [IO.File]::Copy($Source, $Dest, $true)
        return
    }
    catch {
        $errors += "File.Copy: $($_.Exception.Message)"
    }

    # Method 3: cmd.exe copy  (uses SMB-layer redirector - works on \\tsclient\)
    # Do NOT call Test-Path against $Dest - on \\tsclient\ paths Test-Path itself
    # throws "A device attached to the system is not functioning" uncaught.
    # Trust exit code 0 as success.
    try {
        $null = cmd /c "copy /Y `"$Source`" `"$Dest`"" 2>&1
        if ($LASTEXITCODE -eq 0) { return }
        $errors += "cmd copy: exit $LASTEXITCODE"
    }
    catch {
        $errors += "cmd copy: $($_.Exception.Message)"
    }

    # Method 4: robocopy  (most robust SMB-layer transfer)
    # robocopy cannot rename; copy source file to dest dir under its own name,
    # then use cmd move to rename to final dest name.
    try {
        $srcFile = [IO.Path]::GetFileName($Source)
        $srcDir  = [IO.Path]::GetDirectoryName($Source)
        $tmpDest = Join-Path $destDir $srcFile
        $null = robocopy $srcDir $destDir $srcFile /R:2 /W:1 /NP /NJH /NJS 2>&1
        if ($LASTEXITCODE -le 1) {
            if ($srcFile -ne [IO.Path]::GetFileName($Dest)) {
                $null = cmd /c "move /Y `"$tmpDest`" `"$Dest`"" 2>&1
            }
            return
        }
        $errors += "robocopy: exit $LASTEXITCODE"
    }
    catch {
        $errors += "robocopy: $($_.Exception.Message)"
    }

    throw "Copy failed. Source=$Source Dest=$Dest Errors=$($errors -join ' | ')"
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
    # Keep enough headroom for the eventual page file / attachment folder.
    param($Ancestors, [string]$SpaceHomeId, [string]$RootFolder)
    $folder    = $RootFolder
    $maxDirLen = Get-MaxDirectoryPathLength -Path $RootFolder
    $reserved  = 80
    $maxFolder = [Math]::Max($RootFolder.Length, ($maxDirLen - $reserved))
    if ($null -ne $Ancestors) {
        foreach ($a in $Ancestors) {
            if ([string]$a.id -eq $SpaceHomeId) { continue }
            if ($folder.Length -ge $maxFolder) { break }
            $remaining = [Math]::Max(12, $maxFolder - $folder.Length - 1)
            $part      = Get-CompactSafeName -Name $a.title -MaxLength ([Math]::Min(40, $remaining))
            $candidate = Join-Path $folder $part
            if ($candidate.Length -gt $maxFolder) { break }
            $folder = $candidate
        }
    }
    return $folder
}

function Get-AttachmentsFolderPath {
    param(
        [string]$PageFolder,
        [string]$OutputRoot,
        [string]$FileBaseName,
        [string]$PageId
    )

    if (Test-IsTsClientPath -Path $OutputRoot) {
        return (Join-Path (Join-Path $OutputRoot '_a') $PageId)
    }

    $maxDirLen = Get-MaxDirectoryPathLength -Path $OutputRoot

    $localCandidates = @(
        "$FileBaseName-attachments",
        ((Get-CompactSafeName -Name $FileBaseName -MaxLength 24) + '-att'),
        ($PageId + '-att')
    )

    foreach ($name in $localCandidates) {
        $candidate = Join-Path $PageFolder $name
        if ($candidate.Length -le $maxDirLen) {
            return $candidate
        }
    }

    $hubRoot = Join-Path $OutputRoot '_a'
    $hubCandidates = @(
        (Join-Path $hubRoot ($PageId + '-' + (Get-CompactSafeName -Name $FileBaseName -MaxLength 16))),
        (Join-Path $hubRoot $PageId)
    )

    foreach ($candidate in $hubCandidates) {
        if ($candidate.Length -le $maxDirLen) {
            return $candidate
        }
    }

    return (Join-Path $hubRoot ((Get-CompactSafeName -Name $PageId -MaxLength 12) + '-att'))
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
    $tmp = New-LocalTempFilePath -Prefix "conf-word-$PageId" -Extension '.doc'

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
    return [PSCustomObject]@{ OK = $true; Fmt = 'html'; Path = $DestPath }
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
        [string]$FileBaseName,
        [string]$OutputRoot
    )

    $uri = "{0}/content/{1}/child/attachment?limit=100" -f $ApiBase, $PageId
    try { $resp = Invoke-RestMethod -Uri $uri -Headers $Headers -ErrorAction Stop }
    catch { return [PSCustomObject]@{ Count = 0; Bytes = [long]0 } }

    if ($null -eq $resp.results -or $resp.results.Count -eq 0) {
        return [PSCustomObject]@{ Count = 0; Bytes = [long]0 }
    }

    try {
        $dir = Get-AttachmentsFolderPath -PageFolder $PageFolder -OutputRoot $OutputRoot `
            -FileBaseName $FileBaseName -PageId $PageId
        Ensure-DirectorySafe -Path $dir
    }
    catch {
        try {
            $fallbackDir = Join-Path (Join-Path $OutputRoot '_a') $PageId
            Ensure-DirectorySafe -Path $fallbackDir
            $dir = $fallbackDir
        }
        catch {
            return [PSCustomObject]@{ Count = 0; Bytes = [long]0 }
        }
    }

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
        $tmp  = New-LocalTempFilePath -Prefix "conf-att-$($att.id)" -Extension '.tmp'
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

    if ($n -eq 0) {
        # Do NOT use Test-Path against \tsclient\ paths - it throws on RDP redirected drives.
        # Attempt remove silently; it will no-op if dir does not exist.
        try { Remove-Item $dir -Force -Recurse -ErrorAction SilentlyContinue } catch {}
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
$null = Test-DirectoryWritable -Path $outDir
Write-Host ("Temp staging: {0}" -f (Get-LocalTempRoot)) -ForegroundColor DarkGray

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
        $null = Test-DirectoryWritable -Path $folder
    }
    catch {
        $failed += [PSCustomObject]@{ Id = $pg.id; Title = $pg.title; Reason = "Could not create output folder: $($_.Exception.Message)" }
        Write-Host ('  FAIL ({0}) | folder create error: {1}' -f $pg.id, $_.Exception.Message) -ForegroundColor Red
        continue
    }

    # Verify the output folder is accessible before attempting writes
    if (-not (Test-DirectoryExistsSafe -Path $folder)) {
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
        $wordHttpCode = 0
        $wordErrorMessage = ''
        for ($wordTry = 1; $wordTry -le 3; $wordTry++) {
            try {
                $result = Save-PageWord -WikiBase $wiki -PageId $pg.id `
                              -Headers $headers -DestPath $docDest -Session $session
                if ($result.OK) {
                    $wordStreak = 0
                    $wordErrorMessage = ''
                    break
                }

                $result = $null
                $wordErrorMessage = 'Word: empty or undersized response'
                if ($wordTry -lt 3) {
                    Start-Sleep -Milliseconds (1000 * $wordTry)
                }
            }
            catch {
                $result = $null
                $wordErrorMessage = $_.Exception.Message
                $wordHttpCode = 0
                if ($null -ne $_.Exception.Response) {
                    try { $wordHttpCode = [int]$_.Exception.Response.StatusCode } catch {}
                }

                if ($wordHttpCode -in @(401, 403)) {
                    $wordOff = $true
                    Write-Host "  Word returned HTTP $wordHttpCode - switching to HTML only" -ForegroundColor Yellow
                    break
                }

                if ($wordTry -lt 3) {
                    Start-Sleep -Milliseconds (1000 * $wordTry)
                }
            }
        }

        if ($null -eq $result -or -not $result.OK) {
            $reason = $wordErrorMessage
            if ($wordHttpCode -gt 0) {
                # Only count HTTP errors toward streak - not I/O errors
                $wordStreak++
            }
        }

        if ((-not $wordOff) -and $wordStreak -ge 3) {
            $wordOff = $true
            Write-Host '  Word failed 3x via HTTP - switching to HTML only' -ForegroundColor Yellow
        }
    }

    # --- HTML (fallback) ---
    # NOTE: Use .doc extension even for HTML content. OneDrive's sync filter driver
    # blocks .html file creation in synced SharePoint libraries (security policy that
    # prevents script injection). .doc is always permitted and Word/SharePoint/M365
    # Copilot all open HTML-in-doc wrappers natively with full fidelity.
    if ($null -eq $result -or -not $result.OK) {
        $htmlDest = Get-SafeOutputFilePath -Folder $folder -BaseName $baseName -Extension '.doc'

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
            $result = [PSCustomObject]@{ OK = $false; Fmt = $null; Path = $null }
            $pathLen = 0
            try { $pathLen = $htmlDest.Length } catch {}
            $reason = "HTML write failed (len=$pathLen): $($_.Exception.Message)"
        }
    }

    $dur = ([DateTime]::UtcNow - $ps).TotalSeconds

    if ($result.OK) {
        $fmts[$result.Fmt]++
        # Get-Item against \tsclient\ paths throws on some RDP sessions - use
        # a dedicated try/catch and fall back to zero for size reporting only.
        $sz = 0
        try { $sz = (Get-Item -LiteralPath $result.Path -ErrorAction Stop).Length } catch {}
        $bytes += $sz

        if ($sz -ge 1MB)      { $szStr = '{0:N1} MB' -f ($sz / 1MB) }
        elseif ($sz -ge 1KB)  { $szStr = '{0:N0} KB' -f ($sz / 1KB) }
        else                  { $szStr = "$sz B" }

        Write-Host ('  OK   {0} | {1} | {2:N1}s | {3}' -f `
            $result.Fmt.ToUpper().PadRight(4), $szStr, $dur, $rel) -ForegroundColor Green

        # Download attachments
        $att = Save-PageAttachments -ApiBase $api -WikiBase $wiki -PageId $pg.id `
                   -Headers $headers -PageFolder $folder -FileBaseName $baseName -OutputRoot $outDir
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
