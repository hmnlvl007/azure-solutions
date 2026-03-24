<#
.SYNOPSIS
    - Adds a new gMSA as a SQL login and grants sysadmin.
      If no gMSA is specified, auto-detects the account running the MSSQL service.
    - Removes an existing gMSA login from the sysadmin role (login is kept).

.EXAMPLE
    # Auto-detect MSSQL service account as the new sysadmin gMSA
    .\Set-GmsaSysadmin.ps1 -SqlInstance "I1XFWIPSQL0001" `
                            -RemoveFromSysadmin "HP\gmsaSqlOld$"

.EXAMPLE
    # Explicitly specify the new gMSA to promote
    .\Set-GmsaSysadmin.ps1 -SqlInstance "I1XFWIPSQL0001" `
                            -NewSysadminGmsa    "HP\gmsaSqlNew$" `
                            -RemoveFromSysadmin "HP\gmsaSqlOld$"
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    # Target SQL Server instance
    [Parameter(Mandatory)]
    [string]$SqlInstance,

    # NEW gMSA to add as login and grant sysadmin.
    # If omitted, the account running the MSSQL service is used automatically.
    [Parameter()]
    [string]$NewSysadminGmsa,

    # EXISTING gMSA login to remove from sysadmin (login is preserved).
    [Parameter(Mandatory)]
    [string]$RemoveFromSysadmin,

    # Named instance service name - only needed if non-default instance
    # e.g. "MSSQL$INSTANCE01"  (default: "MSSQLSERVER" for default instance)
    [Parameter()]
    [string]$MssqlServiceName,

    # Optional SQL credential if not using integrated security to connect
    [Parameter()]
    [PSCredential]$SqlCredential
)

#Requires -Module dbatools

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$connectParams = @{ SqlInstance = $SqlInstance }
if ($SqlCredential) { $connectParams['SqlCredential'] = $SqlCredential }

# ----------------------------------------------------------------
# Helper — derive the Windows host name from the instance string
# e.g. "SERVER01\INST01" → "SERVER01"  |  "SERVER01" → "SERVER01"
# ----------------------------------------------------------------
function Get-HostFromInstance {
    param ([string]$Instance)
    ($Instance -split '\\|,')[0]
}

try {
    # ============================================================
    # 1. Connect & confirm reachable
    # ============================================================
    Write-Host "`nConnecting to: $SqlInstance" -ForegroundColor Cyan
    $server = Connect-DbaInstance @connectParams
    Write-Host "Connected: $($server.Name)  (SQL Server $($server.VersionString))" `
               -ForegroundColor Green

    # ============================================================
    # 2. Resolve NEW gMSA  — explicit param OR auto-detect service account
    # ============================================================
    if (-not $NewSysadminGmsa) {

        # Derive the host to query for the Windows service
        $targetHost = Get-HostFromInstance -Instance $SqlInstance

        # Resolve service name (default instance vs named instance)
        if (-not $MssqlServiceName) {
            $MssqlServiceName = if ($SqlInstance -match '\\') {
                "MSSQL`$$( ($SqlInstance -split '\\')[1] )"   # named: MSSQL$INSTNAME
            } else {
                'MSSQLSERVER'                                   # default instance
            }
        }

        Write-Host "`nAuto-detecting MSSQL service account from '$MssqlServiceName' on '$targetHost'..." `
                   -ForegroundColor Cyan

        $svc = Get-WmiObject Win32_Service `
                   -ComputerName $targetHost `
                   -Filter       "Name='$MssqlServiceName'" `
                   -ErrorAction  Stop

        if (-not $svc) {
            throw "Service '$MssqlServiceName' not found on '$targetHost'. " +
                  "Use -MssqlServiceName to specify the correct service name."
        }

        $NewSysadminGmsa = $svc.StartName
        Write-Host "Detected service account: $NewSysadminGmsa" -ForegroundColor Green
    }

    # Sanity check — don't promote and demote the same account
    if ($NewSysadminGmsa -eq $RemoveFromSysadmin) {
        throw "NewSysadminGmsa and RemoveFromSysadmin cannot be the same account: '$NewSysadminGmsa'"
    }

    # ============================================================
    # 3. ADD new gMSA login + GRANT sysadmin
    # ============================================================
    Write-Host "`n--- ADD & PROMOTE: $NewSysadminGmsa ---" -ForegroundColor Yellow

    # 3a. Create the login if it doesn't exist
    $newLogin = Get-DbaLogin @connectParams -Login $NewSysadminGmsa
    if (-not $newLogin) {
        Write-Host "  Login not found — creating: $NewSysadminGmsa"
        if ($PSCmdlet.ShouldProcess($NewSysadminGmsa, "New-DbaLogin on $SqlInstance")) {
            $newLogin = New-DbaLogin @connectParams `
                                     -Login           $NewSysadminGmsa `
                                     -LoginType       WindowsUser `
                                     -DefaultDatabase master `
                                     -Confirm:$false
        }
        Write-Host "  Login created." -ForegroundColor Green
    } else {
        Write-Host "  Login already exists — skipping creation." -ForegroundColor DarkYellow
    }

    # 3b. Grant sysadmin if not already a member
    $newLogin = Get-DbaLogin @connectParams -Login $NewSysadminGmsa
    if (-not $newLogin.IsMember('sysadmin')) {
        Write-Host "  Adding to sysadmin role..."
        if ($PSCmdlet.ShouldProcess($NewSysadminGmsa, "Add to sysadmin on $SqlInstance")) {
            Set-DbaLogin @connectParams `
                         -Login    $NewSysadminGmsa `
                         -AddRole  sysadmin `
                         -Confirm:$false
        }
        Write-Host "  Granted sysadmin." -ForegroundColor Green
    } else {
        Write-Host "  Already sysadmin — nothing to do." -ForegroundColor DarkYellow
    }

    # ============================================================
    # 4. REMOVE existing gMSA from sysadmin (login stays)
    # ============================================================
    Write-Host "`n--- DEMOTE (remove sysadmin only): $RemoveFromSysadmin ---" -ForegroundColor Yellow

    $oldLogin = Get-DbaLogin @connectParams -Login $RemoveFromSysadmin
    if (-not $oldLogin) {
        Write-Warning "Login '$RemoveFromSysadmin' does not exist on $SqlInstance — skipping."
    } elseif (-not $oldLogin.IsMember('sysadmin')) {
        Write-Host "  '$RemoveFromSysadmin' is not a sysadmin member — nothing to remove." `
                   -ForegroundColor DarkYellow
    } else {
        Write-Host "  Removing from sysadmin role..."
        if ($PSCmdlet.ShouldProcess($RemoveFromSysadmin, "Remove from sysadmin on $SqlInstance")) {
            Set-DbaLogin @connectParams `
                         -Login       $RemoveFromSysadmin `
                         -RemoveRole  sysadmin `
                         -Confirm:$false
        }
        Write-Host "  Removed from sysadmin. Login preserved." -ForegroundColor Green
    }

    # ============================================================
    # 5. Verification report
    # ============================================================
    Write-Host "`n--- Final State ---" -ForegroundColor Cyan
    Get-DbaLogin @connectParams -Login $NewSysadminGmsa, $RemoveFromSysadmin |
        Select-Object Name,
                      LoginType,
                      IsDisabled,
                      @{ N = 'IsSysadmin'; E = { $_.IsMember('sysadmin') } },
                      DefaultDatabase,
                      CreateDate |
        Format-Table -AutoSize
}
catch {
    Write-Error "Script failed: $_"
    exit 1
}