[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfluenceBaseUrl,
    [Parameter(Mandatory)][string]$SpaceKey,
    [Parameter(Mandatory)][string]$Email,
    [Parameter(Mandatory)][string]$ApiToken,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory = $false)][ValidateRange(1,100)][int]$PageSize = 100,
    [Parameter(Mandatory = $false)][ValidateSet('Incremental','Full')][string]$ExportMode = 'Incremental',
    [Parameter(Mandatory = $false)][switch]$DiagnosticMode
)

$ErrorActionPreference = 'Stop'
$script:HttpClientReady = $false

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

function Add-OsAuthTypeBasic {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $Url }
    if ($Url -match '(^|[?&])os_authType=basic([&#]|$)') { return $Url }

    # Use plain string splitting to avoid UriBuilder/Uri round-tripping which
    # double-encodes percent-encoded path characters (e.g. turns /wiki/download/...
    # into /wiki%2Fdownload%2F...) causing Confluence to 302 to the login page.
    $qIndex = $Url.IndexOf('?')
    if ($qIndex -lt 0) {
        return $Url + '?os_authType=basic'
    }
    $fragment = ''
    $hashIndex = $Url.IndexOf('#', $qIndex)
    if ($hashIndex -ge 0) {
        $fragment = $Url.Substring($hashIndex)
        $Url = $Url.Substring(0, $hashIndex)
    }
    $existing = $Url.Substring($qIndex + 1)
    if ([string]::IsNullOrWhiteSpace($existing)) {
        return $Url + 'os_authType=basic' + $fragment
    }
    return $Url + '&os_authType=basic' + $fragment
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
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Output path is empty. Cannot create directory.'
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        try {
            [IO.Directory]::CreateDirectory($Path) | Out-Null
        }
        catch {
            throw "Failed to create directory: $Path. $($_.Exception.Message)"
        }
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
        [string]$HomePageId,
        [switch]$Diagnostics
    )

    $byId = @{}
    $discoveryMode = 'strict'

    function Get-WikiRootFromApiBase {
        param([string]$Base)
        if ($Base -match '/rest/api/?$') {
            return ($Base -replace '/rest/api/?$', '')
        }
        return $Base.TrimEnd('/')
    }

    function Get-ApiResultItems {
        param([object]$Response)

        if ($null -eq $Response) { return @() }

        $raw = $null
        try { $raw = $Response.results } catch { $raw = $null }
        if ($null -eq $raw) { return @() }

        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in @($raw)) {
            if ($null -ne $entry) { $items.Add($entry) }
        }

        return @($items)
    }

    function Write-BatchDiagnostics {
        param(
            [string]$Label,
            [int]$Start,
            [int]$Returned,
            [object]$Response,
            [int]$Added,
            [int]$Unique
        )

        if (-not $Diagnostics) { return }

        $apiSize = '?'
        $apiLimit = '?'
        $apiTotal = '?'
        $hasNext = $false
        try { if ($null -ne $Response.size) { $apiSize = [string][int]$Response.size } } catch {}
        try { if ($null -ne $Response.limit) { $apiLimit = [string][int]$Response.limit } } catch {}
        try { if ($null -ne $Response.totalSize) { $apiTotal = [string][int]$Response.totalSize } } catch {}
        try { $hasNext = -not [string]::IsNullOrWhiteSpace([string]$Response._links.next) } catch { $hasNext = $false }

        Write-Host (
            "    diag({0}) start={1} returned={2} api.size={3} api.limit={4} api.totalSize={5} added={6} unique={7} next={8}" -f
            $Label, $Start, $Returned, $apiSize, $apiLimit, $apiTotal, $Added, $Unique, $hasNext
        ) -ForegroundColor DarkCyan
    }

    function Add-UniquePages {
        param([object[]]$Items)
        $added = 0
        foreach ($item in @($Items)) {
            $id = [string]$item.id
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            if ($byId.ContainsKey($id)) {
                $existing = $byId[$id]
                $existingAncestors = @()
                $incomingAncestors = @()

                try { $existingAncestors = @(Normalize-Ancestors -AncestorsValue $existing.ancestors) } catch { $existingAncestors = @() }
                try { $incomingAncestors = @(Normalize-Ancestors -AncestorsValue $item.ancestors) } catch { $incomingAncestors = @() }

                if ($existingAncestors.Count -eq 0 -and $incomingAncestors.Count -gt 0) {
                    $byId[$id] = $item
                }
                continue
            }
            $byId[$id] = $item
            $added++
        }
        return $added
    }

    function Invoke-V2PageDiscovery {
        param([switch]$RelaxedStatus)

        $wikiRoot = Get-WikiRootFromApiBase -Base $ApiBase
        $spaceId = $null
        try {
            $spacesUri = "$wikiRoot/api/v2/spaces?keys=$([Uri]::EscapeDataString($Key))&limit=1"
            $spacesResponse = Invoke-RestMethod -Uri $spacesUri -Method Get -Headers $Headers -ErrorAction Stop
            foreach ($candidate in @($spacesResponse.results)) {
                $candidateId = [string]$candidate.id
                if (-not [string]::IsNullOrWhiteSpace($candidateId)) {
                    $spaceId = $candidateId
                    break
                }
            }
        }
        catch {
            if ($Diagnostics) {
                Write-Host ("  diag v2 spaces lookup failed: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
            }
            return 0
        }

        if ([string]::IsNullOrWhiteSpace($spaceId)) {
            if ($Diagnostics) {
                Write-Host '  diag v2 spaces lookup returned no matching space id.' -ForegroundColor DarkYellow
            }
            return 0
        }

        $addedTotal = 0
        if ($RelaxedStatus) {
            $nextUri = "$wikiRoot/api/v2/pages?space-id=$([Uri]::EscapeDataString($spaceId))&limit=$BatchSize"
        }
        else {
            $nextUri = "$wikiRoot/api/v2/pages?space-id=$([Uri]::EscapeDataString($spaceId))&status=current&limit=$BatchSize"
        }

        while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
            $response = $null
            try {
                $response = Invoke-RestMethod -Uri $nextUri -Method Get -Headers $Headers -ErrorAction Stop
            }
            catch {
                $errMsg = $_.Exception.Message
                if ($errMsg -match '404|Not Found') {
                    Write-Host ("  v2 pagination: reached end (404 Not Found)" ) -ForegroundColor DarkGray
                } else {
                    Write-Host ("  v2 pagination error (non-fatal): {0}" -f $errMsg) -ForegroundColor DarkYellow
                }
                break
            }
            $batch = @(Get-ApiResultItems -Response $response)
            if ($batch.Count -eq 0) { break }

            $added = Add-UniquePages -Items $batch
            $addedTotal += $added
            $label = if ($RelaxedStatus) { 'v2-relaxed' } else { 'v2' }
            Write-Host ("  {0,-12} got={1,3} added={2,3} total={3}" -f $label, $batch.Count, $added, $byId.Count) -ForegroundColor DarkGray

            $rawNext = $null
            try { $rawNext = [string]$response._links.next } catch { $rawNext = $null }
            if ([string]::IsNullOrWhiteSpace($rawNext)) {
                $nextUri = $null
            }
            else {
                $nextUri = Resolve-ConfluenceUrl -BaseUrl $wikiRoot -PathOrUrl $rawNext
            }
        }

        return $addedTotal
    }

    $contentTotal = 0

    function Invoke-ContentDiscovery {
        param([switch]$Relaxed)

        $addedTotal = 0
        $start = 0
        while ($true) {
            if ($Relaxed) {
                $uri = "$ApiBase/content?spaceKey=$([Uri]::EscapeDataString($Key))&type=page&expand=ancestors,version&limit=$BatchSize&start=$start"
            }
            else {
                $uri = "$ApiBase/content?spaceKey=$([Uri]::EscapeDataString($Key))&type=page&status=current&expand=ancestors,version&limit=$BatchSize&start=$start"
            }

            $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $Headers -ErrorAction Stop
            $batch = @(Get-ApiResultItems -Response $response)
            if ($batch.Count -eq 0) { break }

            $added = Add-UniquePages -Items $batch
            $addedTotal += $added
            $label = if ($Relaxed) { 'content-relaxed' } else { 'content' }
            Write-Host ("  {0,-12} start={1,4} got={2,3} added={3,3} total={4}" -f $label, $start, $batch.Count, $added, $byId.Count) -ForegroundColor DarkGray
            Write-BatchDiagnostics -Label $label -Start $start -Returned $batch.Count -Response $response -Added $added -Unique $byId.Count
            $start += $batch.Count
            if (-not $response._links.next) { break }
        }

        return $addedTotal
    }

    $contentTotal += (Invoke-ContentDiscovery)

    $searchTotal = 0
    try {
        $start = 0
        $cql = [Uri]::EscapeDataString("space=`"$Key`" AND type=page")
        while ($true) {
            $uri = "$ApiBase/content/search?cql=$cql&expand=ancestors,version&limit=$BatchSize&start=$start"
            $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $Headers -ErrorAction Stop
            $batch = @(Get-ApiResultItems -Response $response)
            if ($batch.Count -eq 0) { break }
            $added = Add-UniquePages -Items $batch
            $searchTotal += $added
            Write-Host ("  cql-search start={0,4} got={1,3} added={2,3} total={3}" -f $start, $batch.Count, $added, $byId.Count) -ForegroundColor DarkGray
            Write-BatchDiagnostics -Label 'cql' -Start $start -Returned $batch.Count -Response $response -Added $added -Unique $byId.Count
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
                $batch = @(Get-ApiResultItems -Response $response)
                if ($batch.Count -eq 0) { break }
                $added = Add-UniquePages -Items $batch
                $descTotal += $added
                Write-Host ("  descendants start={0,4} got={1,3} added={2,3} total={3}" -f $start, $batch.Count, $added, $byId.Count) -ForegroundColor DarkGray
                Write-BatchDiagnostics -Label 'descendants' -Start $start -Returned $batch.Count -Response $response -Added $added -Unique $byId.Count
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
                if ($Diagnostics) {
                    Write-Host ("  diag home-page fetch failed: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
                }
            }
        }
    }

    if ($byId.Count -eq 0) {
        $discoveryMode = 'relaxed'
        $contentTotal += (Invoke-ContentDiscovery -Relaxed)
        
        if ($byId.Count -eq 0) {
            Write-Host '  strict and relaxed discovery returned zero pages.' -ForegroundColor DarkYellow
        } elseif (-not [string]::IsNullOrWhiteSpace($HomePageId) -and -not $byId.ContainsKey($HomePageId)) {
            try {
                $homeUri = "$ApiBase/content/$HomePageId?expand=ancestors,version"
                $homePage = Invoke-RestMethod -Uri $homeUri -Method Get -Headers $Headers -ErrorAction Stop
                $null = Add-UniquePages -Items @($homePage)
                Write-Host '  relaxed mode recovered home page directly by ID.' -ForegroundColor DarkGray
            }
            catch {
                if ($Diagnostics) {
                    Write-Host ("  diag relaxed home-page fetch failed: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
                }
            }
        }
    }

    if ($byId.Count -eq 0) {
        Write-Host '  v1 discovery returned zero pages. Trying Confluence API v2 discovery...' -ForegroundColor DarkYellow
        $discoveryMode = 'v2'
        try {
            $v2Added = Invoke-V2PageDiscovery
            if ($v2Added -eq 0) {
                Write-Host '  v2 current-status discovery returned zero pages. Trying v2 relaxed status...' -ForegroundColor DarkYellow
                $discoveryMode = 'v2-relaxed'
                $null = Invoke-V2PageDiscovery -RelaxedStatus
            }
        }
        catch {
            Write-Host ("  v2 discovery unavailable: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
        }
    }

    Write-Host ("  discovery totals -> mode:{0} content:{1} cql:{2} descendants:{3} unique:{4}" -f $discoveryMode, $contentTotal, $searchTotal, $descTotal, $byId.Count) -ForegroundColor DarkGray

    if ($Diagnostics -and $byId.Count -gt 0) {
        $typeCounts = @{}
        $statusCounts = @{}
        foreach ($row in $byId.Values) {
            $type = ''
            $status = ''
            try { $type = [string]$row.type } catch { $type = '' }
            try { $status = [string]$row.status } catch { $status = '' }
            if ([string]::IsNullOrWhiteSpace($type)) { $type = '(blank)' }
            if ([string]::IsNullOrWhiteSpace($status)) { $status = '(blank)' }

            if (-not $typeCounts.ContainsKey($type)) { $typeCounts[$type] = 0 }
            if (-not $statusCounts.ContainsKey($status)) { $statusCounts[$status] = 0 }
            $typeCounts[$type]++
            $statusCounts[$status]++
        }

        $typeSummary = ($typeCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { "{0}:{1}" -f $_.Key, $_.Value }) -join ', '
        $statusSummary = ($statusCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { "{0}:{1}" -f $_.Key, $_.Value }) -join ', '
        Write-Host ("  diag type counts   -> {0}" -f $typeSummary) -ForegroundColor DarkCyan
        Write-Host ("  diag status counts -> {0}" -f $statusSummary) -ForegroundColor DarkCyan
    }

    # ── Post-discovery ancestry enrichment ────────────────────────────────────
    # v2 API pages carry no 'ancestors' field. Fetch each page individually via
    # v1 to get the full ancestor chain so folder hierarchy is correct.
    $needsEnrichment = @($byId.Values | Where-Object {
        $ancs = @()
        try { $ancs = @(Normalize-Ancestors -AncestorsValue $_.ancestors) } catch { $ancs = @() }
        return $ancs.Count -eq 0
    })
    if ($needsEnrichment.Count -gt 0) {
        Write-Host ("  Enriching ancestry for {0} page(s) via v1 API..." -f $needsEnrichment.Count) -ForegroundColor DarkGray
        $enriched = 0
        $enrichFailed = 0
        foreach ($p in $needsEnrichment) {
            $enrichPageId = [string]$p.id
            try {
                $full = Invoke-RestMethod -Uri "$ApiBase/content/$enrichPageId`?expand=ancestors,version" -Method Get -Headers $Headers -ErrorAction Stop
                $byId[$enrichPageId] = $full
                $enriched++
            }
            catch {
                $enrichFailed++
                if ($Diagnostics) {
                    Write-Host ("  diag enrich failed for {0}: {1}" -f $enrichPageId, $_.Exception.Message) -ForegroundColor DarkYellow
                }
            }
        }
        Write-Host ("  Ancestry enrichment: {0} ok, {1} failed." -f $enriched, $enrichFailed) -ForegroundColor DarkGray
    }

    if ($byId.Count -eq 0) { return @() }
    return @($byId.Values | Sort-Object -Property @{ Expression = { [string]$_.title } }, @{ Expression = { [string]$_.id } })
}

function Get-PageFolder {
    param([object[]]$Ancestors, [string]$HomePageId, [string]$Root)
    $folder = $Root
    $pastHome = $false
    $parts = [System.Collections.Generic.List[string]]::new()

    foreach ($ancestor in @($Ancestors)) {
        $ancestorId = [string]$ancestor.id
        if ([string]::IsNullOrWhiteSpace($ancestorId)) { continue }
        if ($ancestorId -eq $HomePageId) {
            $pastHome = $true
            continue  # skip the space home page itself
        }
        if (-not $pastHome) {
            # Collect pre-home ancestors separately in case home is never found
            continue
        }
        $parts.Add((Get-CompactName -Name ([string]$ancestor.title) -MaxLength 60))
    }

    # If home page was never matched (e.g. v2 parent map didn't include it),
    # fall back: use the full ancestor list skipping only the very first entry
    # (the Confluence space root), so we still get real subfolder structure.
    if (-not $pastHome -and $Ancestors.Count -gt 0) {
        $skip = 1   # skip virtual space root at index 0
        for ($i = $skip; $i -lt $Ancestors.Count; $i++) {
            $ancestorId = [string]$Ancestors[$i].id
            if ([string]::IsNullOrWhiteSpace($ancestorId)) { continue }
            if ($ancestorId -eq $HomePageId) { continue }  # skip home if encountered here
            $parts.Add((Get-CompactName -Name ([string]$Ancestors[$i].title) -MaxLength 60))
        }
    }

    foreach ($part in $parts) {
        $folder = Join-Path -Path $folder -ChildPath $part
    }
    return $folder
}

function Get-DestinationPath {
    param([string]$Folder, [string]$Title, [string]$PageId)
    foreach ($maxLen in @(60, 40, 20, 8)) {
        $baseName = '{0}-{1}' -f (Get-CompactName -Name $Title -MaxLength $maxLen), $PageId
        $path = Join-Path -Path $Folder -ChildPath ($baseName + '.doc')
        if ($path.Length -le 235) { return $path }
    }
    # Last resort: use only the page ID
    return (Join-Path -Path $Folder -ChildPath ($PageId + '.doc'))
}

function Get-PageBodyHtml {
    param([string]$ApiBase, [string]$PageId, [hashtable]$Headers)
    $uri = "$ApiBase/content/$PageId`?expand=body.export_view"
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $Headers -ErrorAction Stop
    return [string]$response.body.export_view.value
}

function Resolve-ConfluenceUrl {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$PathOrUrl
    )

    if ([string]::IsNullOrWhiteSpace($PathOrUrl)) { return $null }
    if ($PathOrUrl -match '^https?://') { return $PathOrUrl }

    try {
        $baseUri = [Uri]$BaseUrl
        return ([Uri]::new($baseUri, $PathOrUrl)).AbsoluteUri
    }
    catch {
        return ($BaseUrl.TrimEnd('/') + '/' + $PathOrUrl.TrimStart('/'))
    }
}

function Test-IsCdnHost {
    # Returns $true for known CDN / object-storage hosts whose pre-signed URLs
    # must NOT carry an Authorization header (adding one causes a 400/403 from S3
    # because it sees conflicting query-string and header credentials).
    param([string]$HostName)
    if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
    $h = $HostName.ToLowerInvariant()
    return (
        $h -match '\.amazonaws\.com$' -or
        $h -match '\.cloudfront\.net$' -or
        $h -match '\.akamaiedge\.net$' -or
        $h -match '\.akamai\.net$' -or
        $h -match '\.atlassian-us-east-1\.net$' -or
        $h -match '\.atlassian-eu-west-1\.net$' -or
        $h -match '\.atlassian-us-east-1-2\.net$' -or
        $h -match '\.atlassian\.net$' -and $h -notmatch '^[a-z0-9-]+\.atlassian\.net$' -or   # sub-sub-domains used for CDN
        $h -match '\.storage\.googleapis\.com$' -or
        $h -match '\.blob\.core\.windows\.net$' -or
        $h -match 'cdn\.' -or
        $h -match 'files\.'
    )
}

function Test-IsConfluenceTenantHost {
    # Returns $true for first-party Atlassian tenant hosts where adding
    # os_authType=basic can help bypass login redirects for attachment paths.
    param([string]$HostName)
    if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
    $h = $HostName.ToLowerInvariant()
    return ($h -match '^[a-z0-9-]+\.atlassian\.net$')
}

function Test-IsAtlassianHost {
    # Returns $true for Atlassian-owned hosts where credential forwarding across
    # redirects is acceptable (except known CDN/object storage hosts).
    # Includes atlassianusercontent.com — Atlassian's media service — which
    # requires auth on every hop (unlike S3 pre-signed URLs).
    param([string]$HostName)
    if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
    $h = $HostName.ToLowerInvariant()
    return (
        $h -eq 'atlassian.com' -or
        $h -match '\.atlassian\.com$' -or
        $h -eq 'atlassian.net' -or
        $h -match '\.atlassian\.net$' -or
        $h -eq 'atlassianusercontent.com' -or
        $h -match '\.atlassianusercontent\.com$'
    )
}

function Test-IsConfluenceAttachmentPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return ($Path -match '/wiki/download/' -or $Path -match '/download/attachments/')
}

function Invoke-FileDownload {
    # Downloads a URL to a file, following redirects internally within a single
    # HttpClient instance (avoids creating a new handler per hop, which lowers
    # latency and prevents pre-signed CDN URLs from expiring mid-chain).
    #
    # Auth-stripping rules applied on every hop:
    #   • Any redirect to a known CDN / object-storage host (S3, CloudFront …)
    #     → Authorization and Cookie headers are dropped immediately, even for
    #       same-host hops, because S3 pre-signed URLs reject extra credentials.
    #   • Any redirect that crosses to a different host (and is not CDN) strips
    #     auth headers to avoid leaking credentials to third-party servers.
    #   • Redirects to id.atlassian.com or URLs containing "login" / "application=confluence"
    #     are treated as auth-failure redirects and abort the chain.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [hashtable]$Headers,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [int]$MaxRedirects = 10
    )

    $statusCode = $null
    $location = $null
    $handler = $null
    $client = $null
    $contentStream = $null
    $fileStream = $null

    # Resolved responses that need disposing after each hop
    $responses = [System.Collections.Generic.List[object]]::new()

    try {
        if (-not $script:HttpClientReady) {
            if (-not ('System.Net.Http.HttpClientHandler' -as [type])) {
                Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
            }
            $script:HttpClientReady = $true
        }

        if (Test-Path -LiteralPath $OutFile) {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        }

        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false   # we follow manually to control auth stripping
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate

        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(120)

        # Determine the "origin host" — the host that owns the credentials.
        $originHost = ''
        try { $originHost = ([Uri]$Url).Host } catch {}

        $currentUrl  = $Url
        $useHeaders  = $Headers    # may be set to $null once we cross to CDN / foreign host
        $useSession  = $Session

        for ($hop = 0; $hop -le $MaxRedirects; $hop++) {

            # Detect CDN / object-storage host and proactively drop auth headers.
            # This prevents S3 from rejecting requests that carry both a
            # query-string signature and an Authorization header (HTTP 400).
            $currentHost = ''
            try { $currentHost = ([Uri]$currentUrl).Host } catch {}

            if (Test-IsCdnHost -HostName $currentHost) {
                $useHeaders = $null
                $useSession = $null
            }

            $hasAuthHeader = $false
            if ($null -ne $useHeaders) {
                try { $hasAuthHeader = -not [string]::IsNullOrWhiteSpace([string]$useHeaders['Authorization']) } catch { $hasAuthHeader = $false }
            }

            # Confluence attachment endpoints may still emit login redirects
            # unless os_authType=basic is present when using Basic auth.
            if ($hasAuthHeader) {
                try {
                    $curUri = [Uri]$currentUrl
                    if ((Test-IsConfluenceTenantHost -HostName $curUri.Host) -and (Test-IsConfluenceAttachmentPath -Path $curUri.AbsolutePath)) {
                        $currentUrl = Add-OsAuthTypeBasic -Url $currentUrl
                    }
                }
                catch {}
            }

            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $currentUrl)

            if ($null -ne $useHeaders) {
                foreach ($key in $useHeaders.Keys) {
                    $value = [string]$useHeaders[$key]
                    if ([string]::IsNullOrWhiteSpace($value)) { continue }
                    $null = $request.Headers.TryAddWithoutValidation([string]$key, $value)
                }
            }

            $request.Headers.Accept.Clear()
            $null = $request.Headers.TryAddWithoutValidation('Accept', '*/*')

            # Attach session cookies for non-CDN hosts (including alongside
            # Authorization on Confluence hosts). Keep cookies off CDN/object
            # storage hops to avoid conflicting-credential failures.
            if ($null -ne $useSession -and $null -ne $useSession.Cookies) {
                try {
                    $cookieHost = ([Uri]$currentUrl).Host
                    if (-not (Test-IsCdnHost -HostName $cookieHost)) {
                        $cookieHeader = $useSession.Cookies.GetCookieHeader([Uri]$currentUrl)
                        if (-not [string]::IsNullOrWhiteSpace($cookieHeader)) {
                            $null = $request.Headers.TryAddWithoutValidation('Cookie', $cookieHeader)
                        }
                    }
                }
                catch {}
            }

            $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $responses.Add($response)
            $statusCode = [int]$response.StatusCode

            if ($statusCode -ge 200 -and $statusCode -lt 300) {
                $contentStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $fileStream = [System.IO.File]::Create($OutFile)
                $contentStream.CopyTo($fileStream)
                $fileStream.Flush()
                return [PSCustomObject]@{ Success = $true; StatusCode = $statusCode; Location = $null; Error = $null }
            }

            if ($statusCode -notin @(301, 302, 303, 307, 308)) {
                # Non-redirect, non-success — surface the location if present (may be used
                # by callers) and report failure.
                try {
                    if ($null -ne $response.Headers.Location) {
                        $location = [string]$response.Headers.Location.OriginalString
                    }
                }
                catch { $location = $null }
                return [PSCustomObject]@{ Success = $false; StatusCode = $statusCode; Location = $location; Error = [System.Exception]::new("HTTP $statusCode for $currentUrl") }
            }

            # ---- Redirect handling ----
            $rawLocation = $null
            try {
                if ($null -ne $response.Headers.Location) {
                    $rawLocation = [string]$response.Headers.Location.OriginalString
                }
            }
            catch { $rawLocation = $null }

            # Some servers return the Location as a raw string in the Content-Location
            # header when the Location header cannot be parsed as a URI by HttpClient.
            if ([string]::IsNullOrWhiteSpace($rawLocation)) {
                try {
                    $rawLocation = $response.Headers.GetValues('Location') | Select-Object -First 1
                }
                catch { $rawLocation = $null }
            }

            if ([string]::IsNullOrWhiteSpace($rawLocation)) {
                # 3xx with no Location — cannot follow
                $location = $null
                return [PSCustomObject]@{ Success = $false; StatusCode = $statusCode; Location = $null; Error = [System.Exception]::new("HTTP $statusCode (no Location) for $currentUrl") }
            }

            $nextUrl = Resolve-ConfluenceUrl -BaseUrl $currentUrl -PathOrUrl $rawLocation

            # Detect auth-failure redirects (login page) — abort immediately.
            $isLoginRedirect = $false
            try {
                $nextHost = ([Uri]$nextUrl).Host
                if ($nextHost -ieq 'id.atlassian.com') { $isLoginRedirect = $true }
                elseif ($nextUrl -match 'login' -or $nextUrl -match 'application=confluence') { $isLoginRedirect = $true }
            }
            catch { $isLoginRedirect = $false }

            if ($isLoginRedirect) {
                $location = $nextUrl
                return [PSCustomObject]@{ Success = $false; StatusCode = $statusCode; Location = $nextUrl; Error = [System.Exception]::new("HTTP $statusCode redirected to login for $currentUrl") }
            }

            # Strip auth when leaving the origin host, except for Atlassian->Atlassian
            # redirects that are not CDN/object-storage hosts.
            $nextHost2 = ''
            try { $nextHost2 = ([Uri]$nextUrl).Host } catch {}

            $keepCrossHostCreds = $false
            if ($nextHost2 -ine $originHost) {
                try {
                    $originIsAtlassian = Test-IsAtlassianHost -HostName $originHost
                    $nextIsAtlassian = Test-IsAtlassianHost -HostName $nextHost2
                    $nextIsCdn = Test-IsCdnHost -HostName $nextHost2
                    if ($originIsAtlassian -and $nextIsAtlassian -and -not $nextIsCdn) {
                        $keepCrossHostCreds = $true
                    }
                }
                catch {
                    $keepCrossHostCreds = $false
                }
            }

            if ($nextHost2 -ine $originHost -and -not $keepCrossHostCreds) {
                $useHeaders = $null
                $useSession = $null
            }

            $currentUrl = $nextUrl
        }

        # Redirect limit exceeded
        return [PSCustomObject]@{ Success = $false; StatusCode = $statusCode; Location = $null; Error = [System.Exception]::new("Too many redirects ($MaxRedirects) for $Url") }
    }
    catch {
        $err = $_
        return [PSCustomObject]@{ Success = $false; StatusCode = $statusCode; Location = $location; Error = $err; Message = $err.Exception.Message }
    }
    finally {
        if ($null -ne $fileStream) { try { $fileStream.Flush(); $fileStream.Dispose() } catch {} }
        if ($null -ne $contentStream) { try { $contentStream.Dispose() } catch {} }
        foreach ($r in $responses) { try { $r.Dispose() } catch {} }
        if ($null -ne $client) { try { $client.Dispose() } catch {} }
        if ($null -ne $handler) { try { $handler.Dispose() } catch {} }
    }
}

function Finalize-DownloadedFile {
    param(
        [Parameter(Mandatory)][string]$TempPath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $destDir = [IO.Path]::GetDirectoryName($DestinationPath)
    if (-not [string]::IsNullOrWhiteSpace($destDir)) { Ensure-Directory -Path $destDir }

    [IO.File]::Copy($TempPath, $DestinationPath, $true)
    Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue
}

function Test-DownloadLooksValid {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedExtension
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -le 0) { return $false }

    if ($ExpectedExtension -match '\.(html|htm)$') { return $true }
    if ($size -ge 2048) { return $true }

    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $len = [Math]::Min(512, $bytes.Length)
        $text = [Text.Encoding]::UTF8.GetString($bytes, 0, $len)
    }
    catch {
        return $true
    }

    if ($text -match '<html|<head|<body|login|unauthorized|atlassian|confluence') {
        return $false
    }

    return $true
}

function Normalize-Ancestors {
    param([object]$AncestorsValue)

    if ($null -eq $AncestorsValue) { return @() }

    $candidate = $AncestorsValue
    if ($candidate -is [System.Collections.IDictionary] -and $candidate.Contains('results')) {
        $candidate = $candidate['results']
    }
    elseif ($candidate -is [System.Management.Automation.PSCustomObject] -and $null -ne $candidate.results) {
        $candidate = $candidate.results
    }

    return @($candidate)
}

function Build-PageParentMap {
    # Returns a hashtable: pageId -> PSCustomObject with .id and .title
    # Built from inline ancestors and v2-style parent fields in discovery payloads.
    param([object[]]$Pages)

    $map = @{}   # pageId -> direct-parent PSCustomObject (id + title)
    $titleById = @{}

    foreach ($p in @($Pages)) {
        $id = [string]$p.id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $title = ''
        try { $title = [string]$p.title } catch { $title = '' }
        if (-not [string]::IsNullOrWhiteSpace($title)) {
            $titleById[$id] = $title
        }
    }

    foreach ($p in @($Pages)) {
        $pageId = [string]$p.id
        if ([string]::IsNullOrWhiteSpace($pageId)) { continue }

        $parentId = ''
        $parentTitle = ''

        $ancs = Normalize-Ancestors -AncestorsValue $p.ancestors
        if ($ancs.Count -gt 0) {
            # The last ancestor is the direct parent
            $parent = $ancs[$ancs.Count - 1]
            if ($null -ne $parent -and -not [string]::IsNullOrWhiteSpace([string]$parent.id)) {
                $parentId = [string]$parent.id
                try { $parentTitle = [string]$parent.title } catch { $parentTitle = '' }
            }
        }

        if ([string]::IsNullOrWhiteSpace($parentId)) {
            try { $parentId = [string]$p.parentId } catch { $parentId = '' }
        }

        if ([string]::IsNullOrWhiteSpace($parentId)) {
            try { $parentId = [string]$p.parent.id } catch { $parentId = '' }
        }

        if ([string]::IsNullOrWhiteSpace($parentId)) {
            $parentPath = ''
            try { $parentPath = [string]$p._expandable.parent } catch { $parentPath = '' }
            if (-not [string]::IsNullOrWhiteSpace($parentPath)) {
                $m = [regex]::Match($parentPath, '/content/([^/?]+)')
                if ($m.Success) {
                    $parentId = [string]$m.Groups[1].Value
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($parentId)) { continue }
        if ($parentId -eq $pageId) { continue }

        if ([string]::IsNullOrWhiteSpace($parentTitle) -and $titleById.ContainsKey($parentId)) {
            $parentTitle = [string]$titleById[$parentId]
        }

        $map[$pageId] = [PSCustomObject]@{
            id    = $parentId
            title = $parentTitle
        }
    }

    return $map
}

function Get-AncestorsFromParentMap {
    # Walks the parent map upward from $pageId, returning ancestors ordered
    # root-first (same order as Confluence's ancestors array).
    param(
        [string]$PageId,
        [hashtable]$ParentMap
    )

    $chain = [System.Collections.Generic.List[object]]::new()
    $current = $PageId
    $visited  = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    while (-not [string]::IsNullOrWhiteSpace($current) -and $ParentMap.ContainsKey($current)) {
        if (-not $visited.Add($current)) { break }  # cycle guard
        $parent = $ParentMap[$current]
        $chain.Insert(0, $parent)
        $current = [string]$parent.id
    }

    return @($chain)
}

function Get-ResolvedAncestors {
    param(
        [object]$Page,
        [string]$ApiBase,
        [hashtable]$Headers,
        [hashtable]$AncestorCache,
        [hashtable]$ParentMap,      # pre-built from all pages; may be $null
        [string]$HomePageId,
        [switch]$Diagnostics
    )

    $pageId = ''
    try { $pageId = [string]$Page.id } catch { $pageId = '' }

    if (-not [string]::IsNullOrWhiteSpace($pageId) -and $AncestorCache.ContainsKey($pageId)) {
        return @($AncestorCache[$pageId])
    }

    if ([string]::IsNullOrWhiteSpace($pageId)) { return @() }

    $fromMap = @()

    # ── 1. Inline ancestors from the discovery payload (fastest, no extra call) ──
    $inlineAncestors = Normalize-Ancestors -AncestorsValue $Page.ancestors
    if ($inlineAncestors.Count -gt 0) {
        $hasHome = $false
        if (-not [string]::IsNullOrWhiteSpace($HomePageId)) {
            foreach ($a in $inlineAncestors) {
                if ([string]$a.id -eq $HomePageId) { $hasHome = $true; break }
            }
        }

        if ($hasHome -or [string]::IsNullOrWhiteSpace($HomePageId)) {
            $AncestorCache[$pageId] = $inlineAncestors
            return $inlineAncestors
        }
        # If the inline list is missing the home page, fall through to fetch a full chain.
    }

    # ── 2. Walk the pre-built parent map (handles v2 pages with no ancestors) ────
    if ($null -ne $ParentMap -and $ParentMap.Count -gt 0) {
        $fromMap = Get-AncestorsFromParentMap -PageId $pageId -ParentMap $ParentMap
        if ($fromMap.Count -gt 0) {
            $hasHome = $false
            if (-not [string]::IsNullOrWhiteSpace($HomePageId)) {
                foreach ($a in $fromMap) {
                    if ([string]$a.id -eq $HomePageId) { $hasHome = $true; break }
                }
            }
            if ($hasHome -or [string]::IsNullOrWhiteSpace($HomePageId)) {
                $AncestorCache[$pageId] = $fromMap
                return $fromMap
            }
            # If the parent map chain is missing the home page, fall through.
        }
    }

    # ── 3. Last resort: REST calls for this page's ancestors ─────────────────────
    $resolved = @()
    try {
        $fullPage = Invoke-RestMethod -Uri "$ApiBase/content/$pageId?expand=ancestors" -Method Get -Headers $Headers -ErrorAction Stop
        $resolved = @(Normalize-Ancestors -AncestorsValue $fullPage.ancestors)
    }
    catch {
        if ($Diagnostics) {
            Write-Host ("  diag ancestors expand call failed for {0}: {1}" -f $pageId, $_.Exception.Message) -ForegroundColor DarkYellow
        }
    }

    if ($resolved.Count -eq 0) {
        $ancestorsUri = $null
        try { $ancestorsUri = [string]$Page._expandable.ancestors } catch { $ancestorsUri = $null }

        if ([string]::IsNullOrWhiteSpace($ancestorsUri)) {
            $ancestorsUri = "$ApiBase/content/$pageId/ancestors"
        }
        elseif ($ancestorsUri -notmatch '^https?://') {
            $ancestorsUri = Resolve-ConfluenceUrl -BaseUrl $ApiBase -PathOrUrl $ancestorsUri
        }

        try {
            $ancestorsResponse = Invoke-RestMethod -Uri $ancestorsUri -Method Get -Headers $Headers -ErrorAction Stop
            if ($ancestorsResponse -is [System.Array]) {
                $resolved = @($ancestorsResponse)
            }
            else {
                $resolved = @(Normalize-Ancestors -AncestorsValue $ancestorsResponse)
            }
        }
        catch {
            if ($Diagnostics) {
                Write-Host ("  diag ancestors endpoint failed for {0}: {1}" -f $pageId, $_.Exception.Message) -ForegroundColor DarkYellow
            }
        }
    }

    if ($resolved.Count -gt 0) {
        $AncestorCache[$pageId] = $resolved
        return $resolved
    }

    if ($inlineAncestors.Count -gt 0) {
        $AncestorCache[$pageId] = $inlineAncestors
        return $inlineAncestors
    }

    if ($fromMap.Count -gt 0) {
        $AncestorCache[$pageId] = $fromMap
        return $fromMap
    }

    $AncestorCache[$pageId] = @()
    return @()
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
        $iwrParams = @{
            Uri = $url
            Method = 'Get'
            OutFile = $tempFile
            UseBasicParsing = $true
            MaximumRedirection = 10
            ErrorAction = 'Stop'
            Headers = @{ Authorization = $Headers.Authorization }
        }
        if ($null -ne $Session) {
            $iwrParams.WebSession = $Session
        }
        Invoke-WebRequest @iwrParams | Out-Null

        if (-not (Test-Path -LiteralPath $tempFile)) {
            return [PSCustomObject]@{ Success = $false; Reason = 'Word export did not produce a file'; StatusCode = 0 }
        }

        $size = (Get-Item -LiteralPath $tempFile).Length
        if ($size -lt 100) {
            return [PSCustomObject]@{ Success = $false; Reason = 'Word export file was empty/too small'; StatusCode = 0 }
        }

        $destDir = [IO.Path]::GetDirectoryName($DestinationPath)
        if (-not [string]::IsNullOrWhiteSpace($destDir)) { Ensure-Directory -Path $destDir }
        [IO.File]::Move($tempFile, $DestinationPath)
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

    $destDir = [IO.Path]::GetDirectoryName($DestinationPath)
    if (-not [string]::IsNullOrWhiteSpace($destDir)) { Ensure-Directory -Path $destDir }
    [IO.File]::WriteAllText($DestinationPath, $html, [Text.Encoding]::UTF8)
    return [PSCustomObject]@{ Success = $true; Reason = '' }
}

function Save-Attachments {
    param(
        [string]$ApiBase,
        [string]$WikiBase,
        [string]$PageId,
        [hashtable]$Headers,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [string]$PageFolder,
        [string]$BaseFilePath
    )

    $baseName = [IO.Path]::GetFileNameWithoutExtension($BaseFilePath)
    $attachmentFolder = Join-Path -Path $PageFolder -ChildPath ($baseName + '-attachments')

    $items = [System.Collections.Generic.List[object]]::new()
    $failures = [System.Collections.Generic.List[object]]::new()
    $count = 0
    $failCount = 0
    $totalBytes = [long]0
    $nextUri = "$ApiBase/content/$PageId/child/attachment?limit=200"

    while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
        try {
            $response = Invoke-RestMethod -Uri $nextUri -Method Get -Headers $Headers -ErrorAction Stop
        }
        catch {
            $msg = $_.Exception.Message
            if ($items.Count -eq 0) {
                throw "Attachment list request failed for page ${PageId}: $msg"
            }
            $failCount++
            $failures.Add([PSCustomObject]@{
                pageId = $PageId
                attachmentId = ''
                title = '(attachment list)'
                download = $nextUri
                reason = $msg
            }) | Out-Null
            break
        }

        foreach ($entry in @($response.results)) {
            if ($null -ne $entry) { $items.Add($entry) }
        }

        $rawNext = $null
        try { $rawNext = [string]$response._links.next } catch { $rawNext = $null }
        if ([string]::IsNullOrWhiteSpace($rawNext)) {
            $nextUri = $null
        }
        else {
            $nextUri = Resolve-ConfluenceUrl -BaseUrl $ApiBase -PathOrUrl $rawNext
        }
    }

    if ($items.Count -eq 0) {
        return [PSCustomObject]@{ Count = 0; Failed = 0; Attempted = 0; Bytes = [long]0; Path = $null; Failures = @() }
    }

    Ensure-Directory -Path $attachmentFolder

    foreach ($item in $items) {
        $downloadPath = $null
        try { $downloadPath = [string]$item._links.download } catch { $downloadPath = $null }
        if ([string]::IsNullOrWhiteSpace($downloadPath)) { continue }

        $attTitle = [string]$item.title
        $attId = ''
        try { $attId = [string]$item.id } catch { $attId = '' }

        # Preserve the file extension from the title so the saved file opens correctly
        $ext = [IO.Path]::GetExtension($attTitle)   # e.g. ".pdf" or ""
        $nameNoExt = [IO.Path]::GetFileNameWithoutExtension($attTitle)
        $safeBase = Get-CompactName -Name $nameNoExt -MaxLength 60
        # Append attachment ID to prevent collisions when two attachments share the same name
        $fileName = if ([string]::IsNullOrWhiteSpace($attId)) { $safeBase + $ext } else { "$safeBase-$attId$ext" }
        $filePath = Join-Path -Path $attachmentFolder -ChildPath $fileName
        $tempFile = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("cf-att-$([Guid]::NewGuid().ToString('N')).tmp")

        $downloaded = $false
        $lastError  = $null

        # Primary path: direct REST API binary download with Basic auth headers.
        # Invoke-FileDownload now follows the full redirect chain internally
        # (REST API → /wiki/download/… → CDN pre-signed URL) with automatic
        # auth-stripping on CDN / cross-host hops.
        # Do NOT append os_authType=basic here – the REST API uses the Authorization header.
        if (-not [string]::IsNullOrWhiteSpace($attId)) {
            $directApiUrl = "$ApiBase/content/$PageId/child/attachment/$attId/download"
            try {
                if (Test-Path -LiteralPath $tempFile) {
                    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
                }

                $directResult = Invoke-FileDownload -Url $directApiUrl -OutFile $tempFile -Headers $Headers -Session $Session
                if (-not $directResult.Success) {
                    $directMsg = "Direct API attachment request failed with status $($directResult.StatusCode)"
                    if (-not [string]::IsNullOrWhiteSpace([string]$directResult.Location)) {
                        $directMsg += "; location=$([string]$directResult.Location)"
                    }
                    if ($null -ne $directResult.Error) {
                        $directMsg += "; error=$($directResult.Error.Message)"
                    }
                    $lastError = [System.Exception]::new($directMsg)
                }

                if (Test-Path -LiteralPath $tempFile) {
                    $directSize = (Get-Item -LiteralPath $tempFile).Length
                    if ($directSize -gt 0 -and (Test-DownloadLooksValid -Path $tempFile -ExpectedExtension $ext)) {
                        Finalize-DownloadedFile -TempPath $tempFile -DestinationPath $filePath
                        $count++
                        $totalBytes += $directSize
                        $downloaded = $true
                    }
                    elseif ($directSize -gt 0) {
                        $lastError = [System.Exception]::new('Direct API attachment response was non-empty but not a valid file payload.')
                    }
                }
            }
            catch {
                $lastError = $_
            }
        }

        if ($downloaded) { continue }

        # Build candidate download URLs; some tenants return paths without /wiki
        $confluenceRoot = $WikiBase -replace '/wiki$', ''
        $candidates = [System.Collections.Generic.List[string]]::new()

        if (-not [string]::IsNullOrWhiteSpace($attId)) {
            $wikiRoot = $WikiBase
            if ($wikiRoot -match '/wiki$') { $wikiRoot = $wikiRoot.TrimEnd('/') }
            else { $wikiRoot = ($WikiBase.TrimEnd('/') + '/wiki') }

            $apiDownload = "$ApiBase/content/$PageId/child/attachment/$attId/download"
            $candidates.Add($apiDownload)

            # Confluence Cloud v2 download endpoint fallback (often avoids v1 attachment 403s).
            $v2Download = "$wikiRoot/api/v2/attachments/$attId/download"
            $candidates.Add($v2Download)
        }

        if ($downloadPath -match '^https?://') {
            $candidates.Add($downloadPath)
        }
        else {
            $raw = $downloadPath
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $resolved = Resolve-ConfluenceUrl -BaseUrl $confluenceRoot -PathOrUrl $raw
                $candidates.Add($resolved)

                if ($raw -match '^/download/') {
                    $raw = "/wiki$raw"
                }
                elseif ($raw -match '^download/') {
                    $raw = "/wiki/$raw"
                }

                if ($raw -ne $downloadPath) {
                    $resolved = Resolve-ConfluenceUrl -BaseUrl $confluenceRoot -PathOrUrl $raw
                    $candidates.Add($resolved)
                }
            }
        }
        
        $uniqueCandidates = [System.Collections.Generic.List[string]]::new()
        $seenCandidates = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($candidate in $candidates) {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            $normalized = $candidate.Trim()
            if ($seenCandidates.Add($normalized)) {
                $uniqueCandidates.Add($normalized)
            }

            # For Confluence-hosted attachment URLs, also try an explicit
            # os_authType=basic variant. This avoids 302 login redirects on
            # some tenants/endpoints while keeping CDN pre-signed URLs untouched.
            try {
                $candidateUri = [Uri]$normalized
                $isTenantHost = Test-IsConfluenceTenantHost -HostName $candidateUri.Host
                $looksLikeAttachmentPath = ($candidateUri.AbsolutePath -match '/wiki/download/' -or $candidateUri.AbsolutePath -match '/download/attachments/')
                if ($isTenantHost -and $looksLikeAttachmentPath) {
                    $basicCandidate = Add-OsAuthTypeBasic -Url $normalized
                    if (-not [string]::IsNullOrWhiteSpace($basicCandidate)) {
                        $basicNormalized = $basicCandidate.Trim()
                        if ($seenCandidates.Add($basicNormalized)) {
                            $uniqueCandidates.Add($basicNormalized)
                        }
                    }
                }
            }
            catch {}
        }

        foreach ($candidateUrl in $uniqueCandidates) {
            if ($downloaded) { break }
            if ([string]::IsNullOrWhiteSpace($candidateUrl)) { continue }

            if (Test-Path -LiteralPath $tempFile) {
                Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            }

            try {
                # Invoke-FileDownload now follows the full redirect chain internally
                # (Confluence → CDN pre-signed URL), stripping auth on CDN / cross-host
                # hops automatically.  We only need to try different starting-auth modes
                # in case the first mode is rejected by the server (e.g. 401/403).
                $authModes = @(
                    @{ Headers = $Headers; Session = $Session },
                    @{ Headers = $Headers; Session = $null },
                    @{ Headers = $null;    Session = $Session },
                    @{ Headers = $null;    Session = $null }
                )

                $downloadResult = $null
                foreach ($mode in $authModes) {
                    $downloadResult = Invoke-FileDownload -Url $candidateUrl -OutFile $tempFile -Headers $mode.Headers -Session $mode.Session

                    if ($downloadResult.Success) { break }

                    # Auth-failure on the very first hop → try next mode.
                    if ($downloadResult.StatusCode -in @(401, 403)) { continue }

                    # Login redirect abort → try next mode.
                    $errMsg = ''
                    try { $errMsg = $downloadResult.Error.Message } catch {}
                    if ($errMsg -match 'login') { continue }

                    # A 302 that was not detected as a login redirect may require
                    # session-cookie-only auth (e.g. Confluence Cloud inline images
                    # whose /wiki/download/attachments/ endpoint ignores os_authType=basic
                    # but honours the cloud.session.token cookie set during initial auth).
                    # Continue to try the remaining auth modes, especially Headers=$null + Session.
                    if ($downloadResult.StatusCode -eq 302) { continue }

                    # Any other failure (404, 400, timeout, redirect limit) → no point
                    # retrying with different auth; break and move to next candidate.
                    break
                }

                if ($null -eq $downloadResult -or -not $downloadResult.Success) {
                    if ($null -ne $downloadResult) {
                        $detail = "Attachment request failed status=$($downloadResult.StatusCode)"
                        if (-not [string]::IsNullOrWhiteSpace([string]$downloadResult.Location)) {
                            $detail += "; location=$([string]$downloadResult.Location)"
                        }
                        if ($null -ne $downloadResult.Error -and -not [string]::IsNullOrWhiteSpace([string]$downloadResult.Error.Message)) {
                            $detail += "; error=$([string]$downloadResult.Error.Message)"
                        }
                        $detail += "; url=$candidateUrl"
                        throw [System.Exception]::new($detail)
                    }
                    throw [System.Exception]::new('Attachment request failed without a response payload.')
                }

                if (Test-Path -LiteralPath $tempFile) {
                    $size = (Get-Item -LiteralPath $tempFile).Length
                    if ($size -gt 0 -and (Test-DownloadLooksValid -Path $tempFile -ExpectedExtension $ext)) {
                        Finalize-DownloadedFile -TempPath $tempFile -DestinationPath $filePath
                        $count++
                        $totalBytes += $size
                        $downloaded = $true
                    }
                    elseif ($size -gt 0) {
                        $lastError = [System.Exception]::new('Downloaded content appears to be HTML or unauthorized response.')
                    }
                }
            }
            catch {
                $lastError = $_
            }
        }
        
        # ── Invoke-WebRequest two-hop fallback ───────────────────────────────────
        # The /wiki/download/attachments/ redirect chain is always 2 hops:
        #   Hop 1: Confluence (needs Basic Auth) → 302 to CDN pre-signed URL
        #   Hop 2: CDN pre-signed URL (NO auth — S3/CloudFront rejects Authorization)
        # Invoke-WebRequest with MaximumRedirection>0 forwards the Authorization
        # header to the CDN leg, causing 400/404.  The fix: stop after hop 1 to
        # capture the CDN URL, then fetch that URL with zero auth headers.
        if (-not $downloaded -and $null -ne $Headers -and -not [string]::IsNullOrWhiteSpace([string]$Headers['Authorization'])) {
            # Build candidate URLs from raw _links.download, clean of os_authType=basic.
            $iwrCandidates = [System.Collections.Generic.List[string]]::new()
            if (-not [string]::IsNullOrWhiteSpace($downloadPath)) {
                $confluenceRootFb = $WikiBase -replace '/wiki$', ''
                $cleanDp = $downloadPath -replace '[?&]os_authType=basic', '' -replace '\?&', '?' -replace '\?$', '' -replace '&&', '&'
                if ($cleanDp -match '^https?://') {
                    $iwrCandidates.Add($cleanDp)
                } else {
                    $iwrCandidates.Add((Resolve-ConfluenceUrl -BaseUrl $confluenceRootFb -PathOrUrl $cleanDp))
                    if ($cleanDp -match '^/download/') {
                        $iwrCandidates.Add((Resolve-ConfluenceUrl -BaseUrl $confluenceRootFb -PathOrUrl ("/wiki" + $cleanDp)))
                    } elseif ($cleanDp -match '^download/') {
                        $iwrCandidates.Add((Resolve-ConfluenceUrl -BaseUrl $confluenceRootFb -PathOrUrl ("/wiki/" + $cleanDp)))
                    }
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($attId)) {
                $wikiRootFb = if ($WikiBase -match '/wiki$') { $WikiBase.TrimEnd('/') } else { $WikiBase.TrimEnd('/') + '/wiki' }
                $iwrCandidates.Add("$ApiBase/content/$PageId/child/attachment/$attId/download")
                $iwrCandidates.Add("$wikiRootFb/api/v2/attachments/$attId/download")
            }

            $seenIwr = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($iwrUrl in $iwrCandidates) {
                if ($downloaded) { break }
                if ([string]::IsNullOrWhiteSpace($iwrUrl)) { continue }
                if (-not $seenIwr.Add($iwrUrl.Trim())) { continue }

                if (Test-Path -LiteralPath $tempFile) {
                    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
                }

                try {
                    # ── Hop 1: auth → Confluence, do NOT follow redirect ──────────
                    $hop1 = $null
                    try {
                        $hop1 = Invoke-WebRequest -Uri $iwrUrl -Method Get -Headers @{ Authorization = $Headers['Authorization'] } `
                            -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop
                    } catch [System.Net.WebException] {
                        # PowerShell < 6 throws on 3xx when MaximumRedirection=0;
                        # pull the Location from the exception's response.
                        $hop1Response = $_.Exception.Response
                        if ($null -ne $hop1Response) {
                            $loc1 = $hop1Response.Headers['Location']
                            if (-not [string]::IsNullOrWhiteSpace($loc1)) {
                                $hop1 = [PSCustomObject]@{ StatusCode = [int]$hop1Response.StatusCode; Headers = @{ Location = $loc1 } }
                            }
                        }
                    } catch {
                        # Non-redirect error on hop 1 — try next candidate
                        $lastError = $_
                        continue
                    }

                    # Extract Location from hop 1 response
                    $cdnUrl = $null
                    if ($null -ne $hop1) {
                        $sc1 = 0
                        try { $sc1 = [int]$hop1.StatusCode } catch {}

                        if ($sc1 -ge 200 -and $sc1 -lt 300) {
                            # Already a direct 200 — content in response body? Save it.
                            # (some tenants serve small attachments inline)
                            try {
                                [IO.File]::WriteAllBytes($tempFile, $hop1.Content)
                            } catch {}
                            if (Test-Path -LiteralPath $tempFile) {
                                $directSize2 = (Get-Item -LiteralPath $tempFile).Length
                                if ($directSize2 -gt 0 -and (Test-DownloadLooksValid -Path $tempFile -ExpectedExtension $ext)) {
                                    Finalize-DownloadedFile -TempPath $tempFile -DestinationPath $filePath
                                    $count++; $totalBytes += $directSize2; $downloaded = $true
                                    break
                                }
                            }
                        }

                        if ($sc1 -in @(301,302,303,307,308)) {
                            try { $cdnUrl = [string]$hop1.Headers['Location'] } catch {}
                            if ([string]::IsNullOrWhiteSpace($cdnUrl)) {
                                try { $cdnUrl = [string]($hop1.Headers.Location) } catch {}
                            }
                            if (-not [string]::IsNullOrWhiteSpace($cdnUrl) -and $cdnUrl -notmatch '^https?://') {
                                $cdnUrl = Resolve-ConfluenceUrl -BaseUrl $iwrUrl -PathOrUrl $cdnUrl
                            }
                        }
                    }

                    if ([string]::IsNullOrWhiteSpace($cdnUrl) -or $downloaded) { continue }

                    # Abort if hop 1 redirected to a login page
                    if ($cdnUrl -match 'id\.atlassian\.com|/login|application=confluence') { continue }

                    # ── Hop 2: fetch redirect target ──────────────────────────────
                    # Keep Authorization for Atlassian-owned hosts (e.g. media.atlassianusercontent.com)
                    # which require auth on every hop.  Strip it only for real pre-signed CDN
                    # hosts (S3, CloudFront, etc.) where a conflicting auth header causes errors.
                    $hop2Headers = $null
                    try {
                        $cdnHost = ([Uri]$cdnUrl).Host
                        $isRealCdn = Test-IsCdnHost -HostName $cdnHost
                        $isAtlassian = Test-IsAtlassianHost -HostName $cdnHost
                        if ($isAtlassian -and -not $isRealCdn -and $null -ne $Headers -and -not [string]::IsNullOrWhiteSpace([string]$Headers['Authorization'])) {
                            $hop2Headers = @{ Authorization = $Headers['Authorization'] }
                        }
                    } catch {}

                    $hop2Params = @{
                        Uri                = $cdnUrl
                        Method             = 'Get'
                        OutFile            = $tempFile
                        UseBasicParsing    = $true
                        MaximumRedirection = 10
                        ErrorAction        = 'Stop'
                    }
                    if ($null -ne $hop2Headers) { $hop2Params['Headers'] = $hop2Headers }
                    if ($null -ne $Session) { $hop2Params['WebSession'] = $Session }
                    Invoke-WebRequest @hop2Params | Out-Null

                    if (Test-Path -LiteralPath $tempFile) {
                        $iwrSize = (Get-Item -LiteralPath $tempFile).Length
                        if ($iwrSize -gt 0 -and (Test-DownloadLooksValid -Path $tempFile -ExpectedExtension $ext)) {
                            Finalize-DownloadedFile -TempPath $tempFile -DestinationPath $filePath
                            $count++; $totalBytes += $iwrSize; $downloaded = $true
                        }
                    }
                }
                catch {
                    $lastError = $_
                }
            }
        }

        if (-not $downloaded) {
            $failCount++
            if ($null -ne $lastError) {
                $msg = ''
                if ($lastError -is [System.Management.Automation.ErrorRecord]) {
                    $msg = $lastError.Exception.Message
                }
                elseif ($lastError -is [System.Exception]) {
                    $msg = $lastError.Message
                }
                else {
                    $msg = [string]$lastError
                }
                if (-not [string]::IsNullOrWhiteSpace($msg)) {
                    $msg = $msg.Trim()
                }
                if ($msg -match '404|Not Found') {
                    Write-Host ("     ! Attachment 404 [{0}]: {1}" -f $attTitle, $msg) -ForegroundColor DarkGray
                } else {
                    $errType = ''
                    try {
                        if ($lastError -is [System.Management.Automation.ErrorRecord]) {
                            $errType = $lastError.Exception.GetType().FullName
                        }
                        elseif ($lastError -is [System.Exception]) {
                            $errType = $lastError.GetType().FullName
                        }
                    }
                    catch {
                        $errType = ''
                    }

                    if ([string]::IsNullOrWhiteSpace($errType)) {
                        Write-Host ("     ! Attachment download failed [{0}]: {1}" -f $attTitle, $msg) -ForegroundColor DarkYellow
                    }
                    else {
                        Write-Host ("     ! Attachment download failed [{0}] ({1}): {2}" -f $attTitle, $errType, $msg) -ForegroundColor DarkYellow
                    }
                }

                $failures.Add([PSCustomObject]@{
                    pageId = $PageId
                    attachmentId = $attId
                    title = $attTitle
                    download = $downloadPath
                    reason = $msg
                }) | Out-Null
            }
        }
        
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    if ($count -eq 0) {
        Remove-Item -LiteralPath $attachmentFolder -Recurse -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ Count = 0; Failed = $failCount; Attempted = ($count + $failCount); Bytes = [long]0; Path = $null; Failures = @($failures) }
    }

    return [PSCustomObject]@{ Count = $count; Failed = $failCount; Attempted = ($count + $failCount); Bytes = $totalBytes; Path = $attachmentFolder; Failures = @($failures) }
}

$wikiBase = Get-WikiBaseUrl -BaseUrl $ConfluenceBaseUrl
$apiBase = "$wikiBase/rest/api"
$headers = Get-AuthHeaders -UserEmail $Email -Token $ApiToken

$exporterVersion = '2026-05-27-httpclient-v2'
Write-Host ("Exporter version: {0}" -f $exporterVersion) -ForegroundColor DarkCyan
Write-Host ("Exporter script : {0}" -f $PSCommandPath) -ForegroundColor DarkCyan

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
$pages = @(Get-AllPages -ApiBase $apiBase -Key $SpaceKey -Headers $headers -BatchSize $PageSize -HomePageId $homePageId -Diagnostics:$DiagnosticMode)
if ($pages.Count -eq 0) {
    Write-Host "No pages found for space '$SpaceKey'." -ForegroundColor Yellow
    if ($DiagnosticMode) {
        Write-Host "Diagnostic hint: this usually means API-visible current pages are zero (restrictions, status/type mismatch, or policy filters)." -ForegroundColor DarkYellow
    }
    exit 0
}
Write-Host "Found $($pages.Count) pages." -ForegroundColor Green
Write-Host 'Strategy: Word (.doc) primary, HTML fallback + attachments' -ForegroundColor Green
Write-Host ''

# Build parent map from inline discovery data for fast, reliable hierarchy resolution
$pageParentMap = Build-PageParentMap -Pages $pages
Write-Host ("Parent map built: {0} entries." -f $pageParentMap.Count) -ForegroundColor DarkGray

$started = [DateTime]::UtcNow
$failed = [System.Collections.Generic.List[object]]::new()
$formats = @{ doc = 0; html = 0 }
$unchanged = 0
$attachmentsCount = 0
$attachmentsBytes = [long]0
$attachmentsFailed = 0
$attachmentsAttempted = 0
$attachmentFailures = [System.Collections.Generic.List[object]]::new()
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

    $ancestors = Get-ResolvedAncestors -Page $page -ApiBase $apiBase -Headers $headers -AncestorCache $ancestorCache -ParentMap $pageParentMap -HomePageId $homePageId -Diagnostics:$DiagnosticMode

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

    try {
        $attachmentInfo = Save-Attachments -ApiBase $apiBase -WikiBase $wikiBase -PageId $pageId -Headers $headers -Session $session -PageFolder $folder -BaseFilePath $destPath
    }
    catch {
        $attachmentInfo = [PSCustomObject]@{ Count = 0; Failed = 1; Attempted = 1; Bytes = [long]0; Path = $null; Failures = @() }
        $attachErr = $_.Exception.Message
        $attachmentFailures.Add([PSCustomObject]@{ pageId = $pageId; attachmentId = ''; title = '(attachment list)'; download = ''; reason = $attachErr }) | Out-Null
        Write-Host ("     ! Attachment processing failed: {0}" -f $attachErr) -ForegroundColor Yellow
    }
    $attachmentsAttempted += $attachmentInfo.Attempted
    $attachmentsFailed    += $attachmentInfo.Failed
    foreach ($failure in @($attachmentInfo.Failures)) {
        if ($null -ne $failure) { $attachmentFailures.Add($failure) | Out-Null }
    }
    if ($attachmentInfo.Count -gt 0) {
        $attachmentsCount += $attachmentInfo.Count
        $attachmentsBytes += $attachmentInfo.Bytes
        $totalBytes += $attachmentInfo.Bytes
        Write-Host ("     + {0} attachment(s) saved" -f $attachmentInfo.Count) -ForegroundColor DarkCyan
    } elseif ($attachmentInfo.Attempted -gt 0) {
        Write-Host ("     ! {0} attachment(s) attempted, all failed" -f $attachmentInfo.Attempted) -ForegroundColor Yellow
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
    attachments = [PSCustomObject]@{ count = $attachmentsCount; failed = $attachmentsFailed; attempted = $attachmentsAttempted; bytes = $attachmentsBytes }
    attachmentFailures = $attachmentFailures
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
$attColor = if ($attachmentsFailed -gt 0 -and $attachmentsCount -eq 0) { 'Red' } elseif ($attachmentsFailed -gt 0) { 'Yellow' } else { 'DarkCyan' }
Write-Host ("  Attach.  : {0} saved, {1} failed of {2} attempted" -f $attachmentsCount, $attachmentsFailed, $attachmentsAttempted) -ForegroundColor $attColor
Write-Host ("  Duration : {0:hh\:mm\:ss}" -f $elapsed)
Write-Host "  Output   : $spaceRoot"
Write-Host "  Summary  : $summaryPath"
Write-Host "  State    : $statePath"

if ($failed.Count -gt 0 -or $attachmentsFailed -gt 0) {
    exit 2
}

exit 0