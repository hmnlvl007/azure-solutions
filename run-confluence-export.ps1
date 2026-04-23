[CmdletBinding()]
param(
    [string]$ConfluenceBaseUrl = 'https://your-company.atlassian.net',
    [string]$SpaceKey = 'DBA',
    [string]$Email = 'you@your-company.com',
    [string]$ApiToken = $env:CONFLUENCE_API_TOKEN,
    [string]$ExportSubFolder = 'ConfluenceExports',
    [ValidateSet('Incremental','Full')][string]$ExportMode = 'Incremental',
    [ValidateRange(1,100)][int]$PageSize = 100
)

$ErrorActionPreference = 'Stop'

function Resolve-OneDriveRoot {
    $root = if (-not [string]::IsNullOrWhiteSpace($env:OneDriveCommercial)) {
        $env:OneDriveCommercial
    } elseif (-not [string]::IsNullOrWhiteSpace($env:OneDrive)) {
        $env:OneDrive
    } else {
        $null
    }

    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
        throw (
            'Cannot locate a synced OneDrive folder. ' +
            'Sign into OneDrive for Business and confirm sync is active, ' +
            'or set `$env:OneDriveCommercial` manually.'
        )
    }

    return $root
}

function Assert-RequiredValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Value,
        [string]$Hint = ''
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ([string]::IsNullOrWhiteSpace($Hint)) {
            throw "Missing required value: $Name"
        }
        throw "Missing required value: $Name. $Hint"
    }
}

function Assert-NotPlaceholder {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string[]]$BlockedValues,
        [string]$Hint = ''
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return }

    foreach ($blocked in $BlockedValues) {
        if ($Value.Trim().ToLowerInvariant() -eq $blocked.Trim().ToLowerInvariant()) {
            if ([string]::IsNullOrWhiteSpace($Hint)) {
                throw "Invalid placeholder value for ${Name}: '$Value'"
            }
            throw "Invalid placeholder value for ${Name}: '$Value'. $Hint"
        }
    }
}

try {
    $oneDriveRoot = Resolve-OneDriveRoot
    $resolvedOutputPath = Join-Path -Path $oneDriveRoot -ChildPath $ExportSubFolder
    New-Item -ItemType Directory -Path $resolvedOutputPath -Force -ErrorAction Stop | Out-Null

    Assert-RequiredValue -Name 'ConfluenceBaseUrl' -Value $ConfluenceBaseUrl
    Assert-RequiredValue -Name 'SpaceKey' -Value $SpaceKey
    Assert-RequiredValue -Name 'Email' -Value $Email
    Assert-RequiredValue -Name 'ApiToken' -Value $ApiToken -Hint 'Set CONFLUENCE_API_TOKEN in your user environment variables.'

    Assert-NotPlaceholder -Name 'ConfluenceBaseUrl' -Value $ConfluenceBaseUrl -BlockedValues @('https://your-company.atlassian.net') -Hint 'Set your actual Confluence Cloud URL.'
    Assert-NotPlaceholder -Name 'Email' -Value $Email -BlockedValues @('you@your-company.com') -Hint 'Set your Atlassian account email.'

    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'export-confluence-space-pdf.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Exporter script not found: $scriptPath"
    }

    Write-Host "OneDrive root : $oneDriveRoot"
    Write-Host "Export target : $resolvedOutputPath"
    Write-Host "Space key    : $SpaceKey"
    Write-Host "Mode         : $ExportMode"

    $exportArgs = @{
        ConfluenceBaseUrl = $ConfluenceBaseUrl
        SpaceKey          = $SpaceKey
        Email             = $Email
        ApiToken          = $ApiToken
        OutputPath        = $resolvedOutputPath
        PageSize          = $PageSize
        ExportMode        = $ExportMode
    }

    & $scriptPath @exportArgs
    exit $LASTEXITCODE
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
