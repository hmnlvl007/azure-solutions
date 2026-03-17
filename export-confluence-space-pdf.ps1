[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfluenceBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$SpaceKey,

    [Parameter(Mandatory = $true)]
    [string]$Email,

    [Parameter(Mandatory = $true)]
    [string]$ApiToken,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [int]$PageSize = 100,
    [int]$MaxPdfAttempts = 12,
    [int]$RetryDelaySeconds = 8
)

$ErrorActionPreference = 'Stop'

function Get-WikiBaseUrl {
    param([Parameter(Mandatory = $true)][string]$BaseUrl)

    $trimmed = $BaseUrl.TrimEnd('/')
    if ($trimmed -match '/wiki$') {
        return $trimmed
    }
    return "$trimmed/wiki"
}

function Get-AuthHeaders {
    param(
        [Parameter(Mandatory = $true)][string]$UserEmail,
        [Parameter(Mandatory = $true)][string]$Token
    )

    $pair = "{0}:{1}" -f $UserEmail, $Token
    $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    return @{
        Authorization = "Basic $encoded"
        Accept        = 'application/json'
    }
}

function New-ConfluenceSession {
    <#
        .SYNOPSIS
        Creates an authenticated WebRequestSession by hitting a lightweight
        REST endpoint. The returned session carries the cookies that
        Confluence Cloud requires for legacy action URLs (e.g. PDF export).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ApiBase,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $uri = "$ApiBase/user/current"
    Write-Host 'Establishing Confluence session...'
    $null = Invoke-WebRequest -Uri $uri -Method Get -Headers $Headers `
                -SessionVariable 'session' -UseBasicParsing
    Write-Host 'Session established.'
    return $session
}

function Get-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Name)

    $safe = $Name
    foreach ($invalid in [IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace($invalid, '_')
    }

    $safe = ($safe -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return 'untitled'
    }

    if ($safe.Length -gt 100) {
        return $safe.Substring(0, 100).Trim()
    }

    return $safe
}

function Test-IsPdfFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $info = Get-Item -LiteralPath $Path
    if ($info.Length -lt 4) {
        return $false
    }

    $stream = [IO.File]::OpenRead($Path)
    try {
        $bytes = New-Object byte[] 4
        [void]$stream.Read($bytes, 0, 4)
        return ($bytes[0] -eq 0x25 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x44 -and $bytes[3] -eq 0x46)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-ConfluencePages {
    param(
        [Parameter(Mandatory = $true)][string]$ApiBase,
        [Parameter(Mandatory = $true)][string]$TargetSpace,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][int]$Limit
    )

    $all = @()
    $start = 0

    while ($true) {
        $uri = "{0}/content?spaceKey={1}&type=page&limit={2}&start={3}&expand=version" -f $ApiBase, [uri]::EscapeDataString($TargetSpace), $Limit, $start

        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $Headers

        if ($null -eq $response.results -or $response.results.Count -eq 0) {
            break
        }

        $all += $response.results

        if ($response._links.next) {
            $start += [int]$response.limit
        }
        else {
            break
        }
    }

    return $all
}

function Save-PagePdf {
    param(
        [Parameter(Mandatory = $true)][string]$WikiBase,
        [Parameter(Mandatory = $true)][string]$PageId,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][int]$Attempts,
        [Parameter(Mandatory = $true)][int]$DelaySec,
        [Parameter(Mandatory = $false)][Microsoft.PowerShell.Commands.WebRequestSession]$Session
    )

    # os_authType=basic tells Confluence Cloud to honour Basic auth on action URLs
    $exportUrl = "{0}/spaces/flyingpdf/pdfpageexport.action?pageId={1}&os_authType=basic" -f $WikiBase, $PageId
    $tempPath = "$Destination.part"

    # Build common splat; prefer the session (carries cookies) when available
    $webParams = @{
        Uri                = $exportUrl
        Method             = 'Get'
        Headers            = @{ Authorization = $Headers['Authorization'] }   # only auth, no Accept:json
        MaximumRedirection = 10
        OutFile            = $tempPath
        UseBasicParsing    = $true
    }
    if ($null -ne $Session) {
        $webParams['WebSession'] = $Session
    }

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }

        try {
            Invoke-WebRequest @webParams | Out-Null
        }
        catch {
            Write-Verbose ("Attempt {0}/{1} failed: {2}" -f $attempt, $Attempts, $_.Exception.Message)
            Start-Sleep -Seconds $DelaySec
            continue
        }

        if (Test-IsPdfFile -Path $tempPath) {
            Move-Item -LiteralPath $tempPath -Destination $Destination -Force
            return $true
        }

        Start-Sleep -Seconds $DelaySec
    }

    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force
    }

    return $false
}

$wikiBaseUrl = Get-WikiBaseUrl -BaseUrl $ConfluenceBaseUrl
$apiBaseUrl = "$wikiBaseUrl/rest/api"
$headers = Get-AuthHeaders -UserEmail $Email -Token $ApiToken

# Establish a cookie-based session so legacy action URLs (PDF export) accept our auth.
$confluenceSession = New-ConfluenceSession -ApiBase $apiBaseUrl -Headers $headers

$spaceOutput = Join-Path -Path $OutputPath -ChildPath $SpaceKey
if (-not (Test-Path -LiteralPath $spaceOutput)) {
    New-Item -Path $spaceOutput -ItemType Directory -Force | Out-Null
}

Write-Host "Fetching pages from space '$SpaceKey'..."
$pages = Get-ConfluencePages -ApiBase $apiBaseUrl -TargetSpace $SpaceKey -Headers $headers -Limit $PageSize

if ($pages.Count -eq 0) {
    Write-Host 'No pages found. Nothing to export.'
    exit 0
}

Write-Host ("Found {0} pages. Exporting PDFs to: {1}" -f $pages.Count, $spaceOutput)

$index = 0
$failed = @()

foreach ($page in $pages) {
    $index++

    $safeTitle = Get-SafeFileName -Name $page.title
    $fileName = "{0:D4}-{1}-{2}.pdf" -f $index, $safeTitle, $page.id
    $targetPath = Join-Path -Path $spaceOutput -ChildPath $fileName

    Write-Host ("[{0}/{1}] Exporting: {2}" -f $index, $pages.Count, $page.title)

    $ok = Save-PagePdf -WikiBase $wikiBaseUrl -PageId $page.id -Headers $headers -Destination $targetPath -Attempts $MaxPdfAttempts -DelaySec $RetryDelaySeconds -Session $confluenceSession

    if (-not $ok) {
        $failed += [PSCustomObject]@{
            Id    = $page.id
            Title = $page.title
        }
        Write-Warning ("Failed to export page: {0} ({1})" -f $page.title, $page.id)
    }
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$summaryPath = Join-Path -Path $spaceOutput -ChildPath "export-summary-$stamp.json"

$summary = [PSCustomObject]@{
    runAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
    spaceKey     = $SpaceKey
    confluence   = $wikiBaseUrl
    totalPages   = $pages.Count
    failedCount  = $failed.Count
    failures     = $failed
    outputFolder = $spaceOutput
}

$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host ''
Write-Host ("Completed. Exported: {0}, Failed: {1}" -f ($pages.Count - $failed.Count), $failed.Count)
Write-Host ("Summary: {0}" -f $summaryPath)

if ($failed.Count -gt 0) {
    exit 2
}
