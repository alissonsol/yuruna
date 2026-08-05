<#PSScriptInfo
.VERSION 2026.08.05
.GUID 42c8e5f1-9b30-4d27-8a64-3e1f70b2c5da
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

# Default pool-control-service extension. The Go daemon (operator board, pool
# and test-set CRUD over the pool-intent git store, embedded web UI) lives under
# [server/](server/); operator guide: docs/pool-admin.md.
#
# This module is the area's host-side presence: it makes the area visible to
# Get-ExtensionAreaName, gives it a capability-matrix entry, and supplies the
# pre-flight a caller needs to prove a resolved pool-control address.
#
# Get-PoolControlServiceInfo is a status stub returning the uniform hashtable
# the host-side cmdlet vocabulary uses across the extension areas; host-side
# status probing (querying a running board VM) is not wired yet, so the flags
# stay $false until that lands.
#
# Test-PoolControlServiceHost is the reachability pre-flight a caller runs
# BEFORE it commits to a board address, the same contract
# Test-DownloadAgentServiceHost and the stash pre-flight carry.

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
        the lab-auth token gates it -- and answers even when the intent store is
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
    $target = "$Address".Trim()
    if (-not $target) { return $false }
    # An IPv6 literal has to be bracketed to be a legal URL authority. A name or
    # IPv4 literal never contains a colon, and an already-bracketed authority
    # (with or without a :port suffix) is left alone, so this only fires on a
    # bare IPv6 literal.
    if ($target.Contains(':') -and -not $target.StartsWith('[') -and ($target -split ':').Count -gt 2) {
        $target = "[$target]"
    }
    $url = "http://$target/healthz"
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Milliseconds $BackoffMs }
        try {
            $resp = Invoke-WebRequest -Uri $url -NoProxy -TimeoutSec $TimeoutSeconds -ErrorAction Stop
            if ([int]$resp.StatusCode -eq 200) { return $true }
            Write-Verbose "pool-control-service.TestPoolControlServiceHost: $url attempt $attempt returned HTTP $([int]$resp.StatusCode)."
        } catch {
            Write-Verbose "pool-control-service.TestPoolControlServiceHost: $url attempt $attempt failed: $($_.Exception.Message)"
        }
    }
    return $false
}

Export-ModuleMember -Function Get-PoolControlServiceInfo, Test-PoolControlServiceHost
