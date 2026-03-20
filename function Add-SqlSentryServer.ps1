function Add-SqlSentryServer {
    <#
    .SYNOPSIS
        Registers a SQL Server into SQL Sentry under a specified site group path.
    .EXAMPLE
        # Integrated Security (default)
        Add-SqlSentryServer -SqlHostName "sql01.domain.com" `
                            -SentryServer "sentry01" `
                            -SentryDatabase "SentryDB"

    .EXAMPLE
        # Override target group and supply credentials
        Add-SqlSentryServer -SqlHostName "sql01.domain.com" `
                            -SentryServer "sentry01" `
                            -SentryDatabase "SentryDB" `
                            -TargetGroupPath "MBC Site\Development\SharedServer" `
                            -Credential (Get-Credential)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        # The SQL Server host to register (FQDN or NetBIOS)
        [Parameter(Mandatory)]
        [string]$SqlHostName,

        # SQL Sentry monitoring server host
        [Parameter(Mandatory)]
        [string]$SentryServer,

        # SQL Sentry repository database name
        [Parameter(Mandatory)]
        [string]$SentryDatabase,

        # Full group path: "SiteName\GroupLevel1\GroupLevel2"
        # Defaults to the standard initial build target
        [Parameter()]
        [string]$TargetGroupPath = 'MBC Site\Development\SharedServer',

        # Optional: SQL auth credential for Sentry connection
        # If omitted, integrated security is used
        [Parameter()]
        [PSCredential]$Credential
    )

    # ----------------------------------------------------------------
    # Derive site name and subgroup path from TargetGroupPath
    # e.g. "MBC Site\Development\SharedServer"
    #       -> SiteName  = "MBC Site"
    #       -> SubGroups = @("Development","SharedServer")
    # ----------------------------------------------------------------
    $pathParts  = $TargetGroupPath -split '\\'
    $siteName   = $pathParts[0]
    $subGroups  = $pathParts[1..($pathParts.Count - 1)]   # may be empty

    try {
        # --------------------------------------------------------
        # 1. Load the SQL Sentry PowerShell module
        # --------------------------------------------------------
        Write-Verbose "Loading SQLSentry module..."
        Import-Module SQLSentry -Force -ErrorAction Stop

        # --------------------------------------------------------
        # 2. Connect to SQL Sentry
        # --------------------------------------------------------
        Write-Verbose "Connecting to SQL Sentry: $SentryServer / $SentryDatabase"

        $connectParams = @{
            ServerName   = $SentryServer
            DatabaseName = $SentryDatabase
        }
        if ($Credential) {
            $connectParams['UserName'] = $Credential.UserName
            $connectParams['Password'] = $Credential.GetNetworkCredential().Password
        }
        Connect-SQLSentry @connectParams -ErrorAction Stop

        # --------------------------------------------------------
        # 3. Resolve the target Site
        # --------------------------------------------------------
        Write-Verbose "Resolving site: '$siteName'"
        $site = Get-Site -Name $siteName -ErrorAction Stop

        if (-not $site) {
            throw "Site '$siteName' not found in SQL Sentry. Verify the site name."
        }

        # --------------------------------------------------------
        # 4. Walk down the group hierarchy to find the target group
        #    e.g. Development -> SharedServer
        # --------------------------------------------------------
        $targetGroup = $site
        foreach ($groupName in $subGroups) {
            Write-Verbose "Navigating into group: '$groupName'"
            $targetGroup = $targetGroup.Groups |
                           Where-Object { $_.Name -eq $groupName } |
                           Select-Object -First 1

            if (-not $targetGroup) {
                throw "Group '$groupName' not found under path '$TargetGroupPath'. " +
                      "Check the group structure in SQL Sentry."
            }
        }

        Write-Verbose "Target group resolved: '$TargetGroupPath'"

        # --------------------------------------------------------
        # 5. Register the OS-level Windows Computer
        # --------------------------------------------------------
        Write-Verbose "Registering Windows computer: $SqlHostName"
        if ($PSCmdlet.ShouldProcess($SqlHostName, "Register-Computer in '$TargetGroupPath'")) {

            $computer = Register-Computer `
                            -ComputerType Windows `
                            -Name         $SqlHostName `
                            -TargetSite   $targetGroup `
                            -AccessLevel  Full `
                            -ErrorAction  Stop
        }

        # --------------------------------------------------------
        # 6. Register the SQL Server connection
        # --------------------------------------------------------
        Write-Verbose "Registering SQL Server connection: $SqlHostName"
        if ($PSCmdlet.ShouldProcess($SqlHostName, "Register-Connection in '$TargetGroupPath'")) {

            $conn = Register-Connection `
                        -ConnectionType       SqlServer `
                        -Name                 $SqlHostName `
                        -TargetSite           $targetGroup `
                        -UseIntegratedSecurity:$true `
                        -ErrorAction          Stop
        }

        # --------------------------------------------------------
        # 7. Start monitoring — OS and SQL Server
        # --------------------------------------------------------
        Write-Verbose "Starting OS watch on: $SqlHostName"
        Invoke-WatchComputer  -Computer   $computer -LicenseMode Standard -ErrorAction Stop

        Write-Verbose "Starting SQL watch on: $SqlHostName"
        Invoke-WatchConnection -Connection $conn    -ErrorAction Stop

        Write-Host "SUCCESS: '$SqlHostName' registered and monitored under '$TargetGroupPath'" `
                   -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to register '$SqlHostName': $_"
    }
    finally {
        # Always disconnect, even on failure
        Write-Verbose "Disconnecting from SQL Sentry."
        Disconnect-SQLSentry
    }
}