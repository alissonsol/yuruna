<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42c30a62-cbee-46de-84c0-e6f2b967b3ec
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna extension caching-proxy-service squid
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

<#
.SYNOPSIS
    Default caching-proxy-service extension: the host-side pair for the
    management daemon that runs beside squid.

.DESCRIPTION
    The caching-proxy VM was the one Yuruna service outside this interface --
    a hardcoded roster row, no manifest, no beacon, nothing the pool could
    ask about. This area gives it the shape its three siblings have, without
    moving anything that serves traffic: squid, zot, Grafana, Prometheus,
    Loki and the exporters stay exactly where they are, on the ports they
    already use.

    What this area adds is a MANAGEMENT plane -- a small Go daemon on 9310
    that answers "what is this proxy doing" in JSON and owns the two operator
    switches (offline mode, no-upstream) that were previously flipped by
    hand over SSH. That daemon is deliberately separable from squid's host:
    it reads squid through the manager API and the share, so it can run
    either on the proxy VM (local mode, the default) or on another machine
    that can reach those (remote mode, which ships dormant).

    Nothing here runs during a cycle. Like the parser area next door, this
    module is the host-side description of a service that lives in the VM,
    plus the pre-flight a caller uses before trusting an address.
#>

<#
.SYNOPSIS
    Metadata about the caching-proxy-service extension: where its source
    lives, the port the daemon listens on, and the routes it serves.
.DESCRIPTION
    Self-describing hook for the VM templating step and for an operator
    confirming the source tree before a cycle. Pure data -- no I/O.

    SourceFiles is the list the caching-proxy VM's cloud-init fetches, and
    Test.ExtensionService.Tests.ps1 holds the seed's fetch loop to it: a file
    added here and not there is never fetched, and the daemon silently never
    installs.
.OUTPUTS
    [hashtable]
#>
function Get-CachingProxyServiceInfo {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        SourceFiles = @(
            'go.mod',
            'main.go',
            'squid.go',
            'switches.go',
            'registry.go',
            'mcp.go',
            'ui.go',
            'requestadapter.go',
            'landing.go',
            'caching-proxy-service.service'
        )
        ListenPort  = 9310
        Endpoints   = @{
            Health   = '/healthz'
            HostInfo = '/api/hostinfo'
            Session  = '/api/session'
            Ui       = '/'
            Status   = '/api/status'
            Switches = '/api/switches'
        }
        # Mutations. In remote mode both answer 501 with the
        # caching-proxy-remote-readonly reason: stock squid has no remote
        # reconfigure, so a daemon off the box can read the switch state but
        # cannot apply one.
        Mutation    = @{
            Offline    = '/api/switches/offline'
            NoUpstream = '/api/switches/no-upstream'
        }
        InstallPath = '/usr/local/bin/caching-proxy-service'
        ServicePath = '/etc/systemd/system/caching-proxy-service.service'
    }
}

<#
.SYNOPSIS
    Reachability probe for the caching-proxy management daemon:
    GET http://<address>/healthz.
.DESCRIPTION
    The daemon answering is what makes the management plane usable; squid on
    :3128 is a different question, answered by the service-VM roster's health
    port. A caller that wants to know whether the CACHE works should probe
    the cache.

    The request retries instead of being given one wide deadline: over Wi-Fi
    the connect latency has a fat tail (a radio waking from power-save, ARP
    over the air, an AP retransmit or roam) that turns a single-shot probe
    into a spurious miss on a service that is up. The first attempt warms ARP
    and wakes the radio; a follow-up answers in milliseconds. A wired host
    passes on attempt 1 so the retries cost nothing there, and a daemon that
    is genuinely down misses every attempt. See
    feedback_wifi-connect-timeout-tail.md.

    -NoProxy is deliberate, and doubly so here: routing a probe for the proxy
    through the proxy would report the cache's health as the daemon's.
.PARAMETER Address
    Host name, IP literal, or host:port authority of the daemon. A bare
    address is probed on the daemon's default port (9310); an authority that
    already carries a port -- the UTM Shared-NAT forward, for instance -- is
    used verbatim.
.PARAMETER Attempts
    Number of probe attempts before reporting unreachable (>=1).
.PARAMETER TimeoutSeconds
    Per-attempt request deadline.
.PARAMETER BackoffMs
    Delay before each retry (not applied before the first attempt).
.OUTPUTS
    [bool] $true when any attempt got HTTP 200 from /healthz.
#>
function Test-CachingProxyServiceHost {
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
    return Test-YurunaServiceHealth -Verbose:($VerbosePreference -eq 'Continue') -Address $Address -DefaultPort 9310 -Attempts $Attempts -TimeoutSeconds $TimeoutSeconds -BackoffMs $BackoffMs -Request {
        param($Uri, $Timeout)
        Invoke-WebRequest -Uri $Uri -NoProxy -TimeoutSec $Timeout -ErrorAction Stop
    }
}

Export-ModuleMember -Function Get-CachingProxyServiceInfo, Test-CachingProxyServiceHost
