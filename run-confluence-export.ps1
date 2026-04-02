[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# OneDrive for Business path detection
# $env:OneDriveCommercial  -> OneDrive for Business (syncs to SharePoint)
# $env:OneDrive            -> fallback (personal OneDrive or older clients)
# ---------------------------------------------------------------------------
$oneDriveRoot = if (-not [string]::IsNullOrWhiteSpace($env:OneDriveCommercial)) {
    $env:OneDriveCommercial
} elseif (-not [string]::IsNullOrWhiteSpace($env:OneDrive)) {
    $env:OneDrive
} else {
    $null
}

if ([string]::IsNullOrWhiteSpace($oneDriveRoot) -or -not (Test-Path -LiteralPath $oneDriveRoot)) {
    throw (
        'Cannot locate a synced OneDrive folder. ' +
        'Make sure OneDrive for Business is signed in and sync is active, ' +
        'or set $env:OneDriveCommercial to the correct path manually.'
    )
}

# Sub-folder inside OneDrive that will be synced to your SharePoint document library.
# Change "ConfluenceExports" to match the SharePoint library / sub-folder name you pre-created.
$exportSubFolder = 'ConfluenceExports'
$resolvedOutputPath = Join-Path -Path $oneDriveRoot -ChildPath $exportSubFolder

Write-Host "OneDrive root : $oneDriveRoot"
Write-Host "Export target : $resolvedOutputPath"

# Edit these values once, then use this wrapper for manual or scheduled runs.
$config = @{
    ConfluenceBaseUrl = 'https://your-company.atlassian.net'
    SpaceKey          = 'DBA'
    Email             = 'you@your-company.com'
    ApiToken          = $env:CONFLUENCE_API_TOKEN

    # Automatically resolved to the OneDrive for Business folder above.
    # Files placed here are synced to SharePoint by the OneDrive client.
    OutputPath        = $resolvedOutputPath

    PageSize          = 100
}

if ([string]::IsNullOrWhiteSpace($config.ApiToken)) {
    throw 'CONFLUENCE_API_TOKEN is empty. Set it in your user environment variables before running this script.'
}

$scriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'export-confluence-space-pdf.ps1'

& $scriptPath `
    -ConfluenceBaseUrl $config.ConfluenceBaseUrl `
    -SpaceKey $config.SpaceKey `
    -Email $config.Email `
    -ApiToken $config.ApiToken `
    -OutputPath $config.OutputPath `
    -PageSize $config.PageSize
