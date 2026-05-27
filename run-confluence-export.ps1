[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$ConfluenceBaseUrl = 'https://your-company.atlassian.net',
    [Parameter(Mandatory = $false)][string]$SpaceKey = 'DADS',
    [Parameter(Mandatory = $false)][string]$Email = 'you@your-company.com',
    [Parameter(Mandatory = $false)][string]$ApiToken = $env:CONFLUENCE_API_TOKEN,
    [Parameter(Mandatory = $false)][string]$ExportSubFolder = 'ConfluenceExports',
    [Parameter(Mandatory = $false)][ValidateSet('Incremental','Full')][string]$ExportMode = 'Incremental',
    [Parameter(Mandatory = $false)][ValidateRange(1,100)][int]$PageSize = 100,
    [Parameter(Mandatory = $false)][switch]$DiagnosticMode
)

$ErrorActionPreference = 'Stop'

function Resolve-OneDriveRoot {
    # \\tsclient\X\some\path is an RDP client-drive redirect.
    # CreateDirectory fails on it even when Test-Path returns $true.
    # Always convert to the equivalent local path X:\some\path.
    function ConvertFrom-TsClientPath {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
        $value = $Path.Trim()
        if ($value -match '^[\\]{2}tsclient\\([A-Za-z])\\(.*)$') {
            return ('{0}:\{1}' -f $matches[1].ToUpperInvariant(), $matches[2])
        }
        return $value
    }

    foreach ($raw in @($env:OneDriveCommercial, $env:OneDrive)) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $resolved = ConvertFrom-TsClientPath -Path $raw
        # Only require the drive root to exist — the OneDrive subfolder may not yet
        $driveRoot = [IO.Path]::GetPathRoot($resolved)
        if (-not [string]::IsNullOrWhiteSpace($driveRoot) -and (Test-Path -LiteralPath $driveRoot)) {
            return $resolved
        }
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
    Write-Host "Diagnostic    : $DiagnosticMode"

    $params = @{
        ConfluenceBaseUrl = $ConfluenceBaseUrl
        SpaceKey          = $SpaceKey
        Email             = $Email
        ApiToken          = $ApiToken
        OutputPath        = $outputRoot
        PageSize          = $PageSize
        ExportMode        = $ExportMode
        DiagnosticMode    = $DiagnosticMode
    }

    & $exporterPath @params
    exit $LASTEXITCODE
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}