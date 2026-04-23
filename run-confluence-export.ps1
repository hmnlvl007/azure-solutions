[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$ConfluenceBaseUrl = 'https://your-company.atlassian.net',
    [Parameter(Mandatory = $false)][string]$SpaceKey = 'DADS',
    [Parameter(Mandatory = $false)][string]$Email = 'you@your-company.com',
    [Parameter(Mandatory = $false)][string]$ApiToken = $env:CONFLUENCE_API_TOKEN,
    [Parameter(Mandatory = $false)][string]$ExportSubFolder = 'ConfluenceExports',
    [Parameter(Mandatory = $false)][ValidateSet('Incremental','Full')][string]$ExportMode = 'Incremental',
    [Parameter(Mandatory = $false)][ValidateRange(1,100)][int]$PageSize = 100
)

$ErrorActionPreference = 'Stop'

function Resolve-OneDriveRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:OneDriveCommercial) -and (Test-Path -LiteralPath $env:OneDriveCommercial)) {
        return $env:OneDriveCommercial
    }
    if (-not [string]::IsNullOrWhiteSpace($env:OneDrive) -and (Test-Path -LiteralPath $env:OneDrive)) {
        return $env:OneDrive
    }
    throw 'Cannot locate OneDrive root. Sign into OneDrive for Business or set $env:OneDriveCommercial.'
}

function Assert-Value {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name is required. $Message"
    }
}

try {
    Assert-Value -Name 'ConfluenceBaseUrl' -Value $ConfluenceBaseUrl -Message 'Set your Confluence Cloud URL.'
    Assert-Value -Name 'SpaceKey' -Value $SpaceKey -Message 'Set the target Confluence space key.'
    Assert-Value -Name 'Email' -Value $Email -Message 'Set your Atlassian login email.'
    Assert-Value -Name 'ApiToken' -Value $ApiToken -Message 'Set CONFLUENCE_API_TOKEN in your user environment variables.'

    if ($ConfluenceBaseUrl -eq 'https://your-company.atlassian.net') {
        throw 'ConfluenceBaseUrl is still the placeholder value. Update it first.'
    }
    if ($Email -eq 'you@your-company.com') {
        throw 'Email is still the placeholder value. Update it first.'
    }

    $oneDriveRoot = Resolve-OneDriveRoot
    $outputRoot = Join-Path -Path $oneDriveRoot -ChildPath $ExportSubFolder
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    $exporterPath = Join-Path -Path $PSScriptRoot -ChildPath 'export-confluence-space-pdf.ps1'
    if (-not (Test-Path -LiteralPath $exporterPath)) {
        throw "Exporter script not found: $exporterPath"
    }

    Write-Host "OneDrive root : $oneDriveRoot"
    Write-Host "Export target : $outputRoot"
    Write-Host "Space key     : $SpaceKey"
    Write-Host "Mode          : $ExportMode"

    $params = @{
        ConfluenceBaseUrl = $ConfluenceBaseUrl
        SpaceKey          = $SpaceKey
        Email             = $Email
        ApiToken          = $ApiToken
        OutputPath        = $outputRoot
        PageSize          = $PageSize
        ExportMode        = $ExportMode
    }

    & $exporterPath @params
    exit $LASTEXITCODE
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}