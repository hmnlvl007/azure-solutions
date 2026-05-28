[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$ConfluenceBaseUrl = 'https://your-company.atlassian.net',
    [Parameter(Mandatory = $false)][string]$SpaceKey = 'DADS',
    [Parameter(Mandatory = $false)][string]$Email = 'you@your-company.com',
    [Parameter(Mandatory = $false)][string]$ApiToken = $env:CONFLUENCE_API_TOKEN,
    [Parameter(Mandatory = $false)][string]$ExportSubFolder = 'ConfluenceExports',
    [Parameter(Mandatory = $false)][ValidateSet('Incremental','Full')][string]$ExportMode = 'Incremental',
    [Parameter(Mandatory = $false)][ValidateRange(1,100)][int]$PageSize = 100,
    [Parameter(Mandatory = $false)][switch]$DiagnosticMode,
    [Parameter(Mandatory = $false)][string]$StagingRoot = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'ConfluenceExports-Staging'),
    [Parameter(Mandatory = $false)][bool]$CopyToOneDrive = $true
)

$ErrorActionPreference = 'Stop'

function Resolve-OneDriveRoot {
    # UNC placeholder for RDP drive redirection. Update to your actual path.
    $target = '\\tsclient\'
    if ([string]::IsNullOrWhiteSpace($target)) {
        throw 'OneDrive UNC path is empty. Update Resolve-OneDriveRoot.'
    }
    if (-not (Test-Path -LiteralPath $target)) {
        throw "OneDrive UNC path not found: $target"
    }
    return $target
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

    $stagingRoot = Resolve-StagingRoot -Root $StagingRoot
    $outputRoot = Join-Path -Path $stagingRoot -ChildPath $ExportSubFolder
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    $oneDriveRoot = $null
    if ($CopyToOneDrive) {
        try {
            $oneDriveRoot = Resolve-OneDriveRoot
        }
        catch {
            Write-Host "OneDrive UNC path unavailable. Export will remain in staging: $outputRoot" -ForegroundColor Yellow
            $oneDriveRoot = $null
        }
    }

    $exporterPath = Join-Path -Path $PSScriptRoot -ChildPath 'export-confluence-space-pdf.ps1'
    if (-not (Test-Path -LiteralPath $exporterPath)) {
        throw "Exporter script not found: $exporterPath"
    }

    Write-Host "Staging root  : $stagingRoot"
    Write-Host "Export target : $outputRoot"
    if ($CopyToOneDrive) {
        Write-Host "OneDrive root : $oneDriveRoot"
    }
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
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0 -and $CopyToOneDrive -and -not [string]::IsNullOrWhiteSpace($oneDriveRoot)) {
        $targetRoot = Join-Path -Path $oneDriveRoot -ChildPath $ExportSubFolder
        $sourceSpaceRoot = Join-Path -Path $outputRoot -ChildPath $SpaceKey
        $targetSpaceRoot = Join-Path -Path $targetRoot -ChildPath $SpaceKey

        New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $targetSpaceRoot -Force | Out-Null

        Write-Host "Copying from staging to OneDrive..." -ForegroundColor DarkCyan
        $robocopyArgs = @(
            $sourceSpaceRoot,
            $targetSpaceRoot,
            '/MIR',
            '/FFT',
            '/Z',
            '/R:2',
            '/W:2',
            '/NFL',
            '/NDL',
            '/NP'
        )
        & robocopy @robocopyArgs | Out-Null
        $robocopyExit = $LASTEXITCODE
        if ($robocopyExit -ge 8) {
            Write-Host "Robocopy reported errors (code $robocopyExit). Check OneDrive connectivity." -ForegroundColor Yellow
        }
        else {
            Write-Host "Copy complete." -ForegroundColor Green
        }
    }

    exit $exitCode
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

function Resolve-StagingRoot {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        throw 'StagingRoot is empty. Provide a local folder path.'
    }

    $resolved = $Root.TrimEnd('\\')
    if ($resolved -match '^\\\\') {
        throw "StagingRoot must be a local path, not a UNC path: $resolved"
    }

    if (-not (Test-Path -LiteralPath $resolved)) {
        New-Item -ItemType Directory -Path $resolved -Force | Out-Null
    }

    return $resolved
}