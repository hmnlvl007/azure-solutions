<#
.SYNOPSIS
    Adds a gMSA login to SQL Server and grants sysadmin.
    Removes an existing gMSA from sysadmin (login preserved).
    If -NewSysadminGmsa is omitted, the MSSQL service account is used.

.EXAMPLE
    .\Set-GmsaSysadmin.ps1 -SqlInstance "I1XFWIPSQL0001" -RemoveFromSysadmin "HP\gmsaOld$"
    .\Set-GmsaSysadmin.ps1 -SqlInstance "I1XFWIPSQL0001" -NewSysadminGmsa "HP\gmsaNew$" -RemoveFromSysadmin "HP\gmsaOld$"
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)] [string]$SqlInstance,
    [Parameter()]          [string]$NewSysadminGmsa,
    [Parameter(Mandatory)] [string]$RemoveFromSysadmin,
    [Parameter()]          [PSCredential]$SqlCredential
)

#Requires -Module dbatools
$ErrorActionPreference = 'Stop'

$c = @{ SqlInstance = $SqlInstance }
if ($SqlCredential) { $c['SqlCredential'] = $SqlCredential }

# ── Resolve new gMSA from MSSQL service if not provided ──────────────────────
if (-not $NewSysadminGmsa) {
    $host    = ($SqlInstance -split '\\|,')[0]
    $svcName = if ($SqlInstance -match '\\') { "MSSQL`$$( ($SqlInstance -split '\\')[1] )" }
               else                          { 'MSSQLSERVER' }

    $NewSysadminGmsa = (Get-WmiObject Win32_Service -ComputerName $host -Filter "Name='$svcName'").StartName
    if (-not $NewSysadminGmsa) { throw "Could not detect service account for '$svcName' on '$host'." }
    Write-Host "Detected service account: $NewSysadminGmsa" -ForegroundColor Cyan
}

if ($NewSysadminGmsa -eq $RemoveFromSysadmin) {
    throw "NewSysadminGmsa and RemoveFromSysadmin cannot be the same account."
}

Connect-DbaInstance @c | Out-Null

# ── Add new gMSA login + grant sysadmin ──────────────────────────────────────
if (-not (Get-DbaLogin @c -Login $NewSysadminGmsa)) {
    Write-Host "Creating login: $NewSysadminGmsa"
    New-DbaLogin @c -Login $NewSysadminGmsa -LoginType WindowsUser -DefaultDatabase master -Confirm:$false
}

$login = Get-DbaLogin @c -Login $NewSysadminGmsa
if (-not $login.IsMember('sysadmin')) {
    Write-Host "Granting sysadmin: $NewSysadminGmsa"
    Set-DbaLogin @c -Login $NewSysadminGmsa -AddRole sysadmin -Confirm:$false
}

# ── Remove existing gMSA from sysadmin ───────────────────────────────────────
$old = Get-DbaLogin @c -Login $RemoveFromSysadmin
if (-not $old)                      { Write-Warning "Login '$RemoveFromSysadmin' not found — skipping." }
elseif (-not $old.IsMember('sysadmin')) { Write-Warning "'$RemoveFromSysadmin' is not sysadmin — skipping." }
else {
    Write-Host "Removing sysadmin from: $RemoveFromSysadmin"
    Set-DbaLogin @c -Login $RemoveFromSysadmin -RemoveRole sysadmin -Confirm:$false
}

# ── Summary ──────────────────────────────────────────────────────────────────
Get-DbaLogin @c -Login $NewSysadminGmsa, $RemoveFromSysadmin |
    Select-Object Name, @{ N='IsSysadmin'; E={ $_.IsMember('sysadmin') } }, IsDisabled |
    Format-Table -AutoSize