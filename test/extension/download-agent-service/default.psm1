<#PSScriptInfo
.VERSION 2026.08.04
.GUID 4246a48b-da0d-4494-b03f-f496468893cd
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna download agent service extension service
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

# Default download-agent-service extension. The Go daemon (image pool over the
# pool share, freshness scanner, single-flight downloads, embedded web UI) lives
# under [server/](server/); operator guide: docs/download-agent.md.
#
# Get-DownloadAgentServiceInfo is a status stub returning the uniform hashtable
# the host-side cmdlet vocabulary uses across the extension areas; host-side
# status probing (querying a running agent VM) is not wired yet, so the flags
# stay $false until that lands.
#
# Test-DownloadAgentServiceHost is the reachability pre-flight a caller runs
# BEFORE it commits to an agent address, so an unreachable agent surfaces
# before any long-running work depends on it rather than in the middle of a
# multi-gigabyte fetch.

function Get-DownloadAgentServiceInfo {
    <#
    .SYNOPSIS
        Returns the download-agent-service extension's current status as a
        uniform hashtable, matching the host-side cmdlet vocabulary shape used
        elsewhere in the extension areas.
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
        message       = 'download-agent-service: daemon source under server/; host-side status probing not wired yet. See docs/download-agent.md.'
        daemonVersion = $null
    }
}

function Test-DownloadAgentServiceHost {
    <#
    .SYNOPSIS
        Reachability probe for a download-agent service:
        GET http://<address>/healthz.
    .DESCRIPTION
        /healthz is served unconditionally -- neither the UI's lab-token unlock
        nor the lab-auth token gates it -- and answers 200 even when the pool
        share is unmounted. A candidate that passes is one whose daemon is alive
        and whose address this host can route to, which is exactly what a caller
        needs before committing to an endpoint. Pool availability is a separate
        question, answered by /api/v1/status.

        The request retries instead of being given one wide deadline: over Wi-Fi
        the connect latency has a fat tail (a radio waking from power-save, ARP
        over the air, an AP retransmit or roam) that turns a single-shot probe
        into a spurious miss on a service that is up. The first attempt warms
        ARP and wakes the radio; a follow-up answers in milliseconds. A wired
        host passes on attempt 1 so the retries cost nothing there, and an agent
        that is genuinely down misses every attempt. See
        feedback_wifi-connect-timeout-tail.md.

        -NoProxy is deliberate: the agent sits on the lab LAN and the host may
        have a caching-proxy service in its environment that would neither reach
        it nor be meant to.
    .PARAMETER Address
        Host name, IP literal, or host:port authority of the download-agent
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
            Write-Verbose "download-agent-service.TestDownloadAgentServiceHost: $url attempt $attempt returned HTTP $([int]$resp.StatusCode)."
        } catch {
            Write-Verbose "download-agent-service.TestDownloadAgentServiceHost: $url attempt $attempt failed: $($_.Exception.Message)"
        }
    }
    return $false
}

Export-ModuleMember -Function Get-DownloadAgentServiceInfo, Test-DownloadAgentServiceHost
