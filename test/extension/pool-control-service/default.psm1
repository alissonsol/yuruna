<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42ef1927-b8ef-4eaa-b7e6-2dd5a5a5af5f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool control service extension service
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# Default pool-control-service extension. See
# ../../../docs/pool-admin.md#architecture for the daemon, this module's
# role, and its cmdlet vocabulary. -- default.psm1

function Get-PoolControlServiceInfo {
    <#
    .SYNOPSIS
        Returns the pool-control-service extension's current status as a uniform
        hashtable, matching the host-side cmdlet vocabulary shape used elsewhere
        in the extension areas.
    .OUTPUTS
        @{ supported = $false; installed = $false; running = $false;
           message = '...'; daemonVersion = $null }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        supported     = $false
        installed     = $false
        running       = $false
        message       = 'pool-control-service: daemon source under server/; host-side status probing not wired yet. See docs/pool-admin.md.'
        daemonVersion = $null
    }
}

function Test-PoolControlServiceHost {
    <#
    .SYNOPSIS
        Reachability probe for a pool-control service: GET http://<address>/healthz.
    .DESCRIPTION
        /healthz is served unconditionally -- neither the lab-token unlock nor
        the internal authentication key gates it -- and answers even when the intent store is
        unreadable. A candidate that passes is one whose daemon is alive and
        whose address this host can route to, which is exactly what a caller
        needs before committing to an endpoint. Whether the intent store is
        readable is a separate question, answered by /api/diagnostics.

        The request retries instead of being given one wide deadline: over Wi-Fi
        the connect latency has a fat tail (a radio waking from power-save, ARP
        over the air, an AP retransmit or roam) that turns a single-shot probe
        into a spurious miss on a service that is up. The first attempt warms ARP
        and wakes the radio; a follow-up answers in milliseconds. A wired host
        passes on attempt 1 so the retries cost nothing there, and a board that
        is genuinely down misses every attempt. See
        feedback_wifi-connect-timeout-tail.md.

        -NoProxy is deliberate: the board sits on the lab LAN and the host may
        have a caching-proxy service in its environment that would neither reach
        it nor be meant to.
    .PARAMETER Address
        Host name, IP literal, or host:port authority of the pool-control
        service. A bare address is probed on the daemon's default port (80); an
        authority that already carries a port -- the UTM Shared-NAT forward, for
        instance -- is used verbatim.
    .PARAMETER Attempts
        Number of probe attempts before reporting unreachable (>=1).
    .PARAMETER TimeoutSeconds
        Per-attempt request deadline.
    .PARAMETER BackoffMs
        Delay before each retry (not applied before the first attempt).
    .OUTPUTS
        [bool] $true when any attempt got HTTP 200 from /healthz.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Address,
        [int]$Attempts = 3,
        [int]$TimeoutSeconds = 10,
        [int]$BackoffMs = 500
    )
    if (-not (Get-Command Test-YurunaServiceHealth -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Common.psm1') -Global -DisableNameChecking -Verbose:$false
    }
    return Test-YurunaServiceHealth -Verbose:($VerbosePreference -eq 'Continue') -Address $Address -DefaultPort 80 -Attempts $Attempts -TimeoutSeconds $TimeoutSeconds -BackoffMs $BackoffMs -Request {
        param($Uri, $Timeout)
        Invoke-WebRequest -Uri $Uri -NoProxy -TimeoutSec $Timeout -ErrorAction Stop
    }
}

Export-ModuleMember -Function Get-PoolControlServiceInfo, Test-PoolControlServiceHost
