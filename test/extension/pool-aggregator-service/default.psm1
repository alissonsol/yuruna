<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42cccee0-5874-465b-83ed-85e8f9c9e9d3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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
    Default pool-aggregator-service extension: the VM-side Go pull-collector that
    powers the multi-host pool view (docs/opportunities.md).

.DESCRIPTION
    The bulk of the extension is the Go source under this folder (main.go,
    pool-aggregator-service.service); both get fetched + built + installed on the
    caching-proxy-service VM (the pool services host) by that VM's cloud-init user-data
    on first boot -- the same mechanism as caching-proxy-parser-service.

    Nothing of the collector runs on the harness host. This module exposes the
    metadata helper (where the source lives, which port the service listens on,
    its endpoints) and the host-side READ of the collector's extension-host
    lookup -- the one call a host makes to find a pool service it does not run
    itself.
#>

# Why the last extension-host lookup answered as it did. Initialized here, not
# on first write, so reading it before any lookup is a defined 'none' rather
# than an error under Set-StrictMode in a calling scope.
$script:LastPoolLookup = $null

<#
.SYNOPSIS
    Returns metadata about the pool-aggregator-service extension: its source-file list
    (relative to test/extension/pool-aggregator-service/), the listen port baked into
    the systemd unit, and the URL paths the running service exposes.
.DESCRIPTION
    Self-describing hook; keep ListenPort in sync with main.go, the .service
    unit, the Prometheus scrape target, and the README.
#>
function Get-PoolAggregatorServiceManifest {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        SourceFiles = @(
            'main.go',
            'go.mod',
            'pool-aggregator-service.service'
        )
        ListenPort  = 9400
        # The daemon registers these same five paths as named constants
        # (main.go routeHealth..routeLabToken). The two sides are wired
        # independently, so a rename on one alone answers 404 to a host asking
        # the right question; route_names_test.go and
        # Test.ExtensionArea.Tests.ps1 fail the pair apart.
        Endpoints   = @{
            Health = '/healthz'
            Metrics = '/metrics'
            Status = '/api/v1/pool-status'
            ExtensionHosts = '/api/v1/extension-hosts'
            LabToken = '/api/v1/lab-token'
        }
        InstallPath = '/usr/local/bin/pool-aggregator-service'
        ServicePath = '/etc/systemd/system/pool-aggregator-service.service'
        # Pool members are auto-discovered from the squid access log + a status
        # probe -- no static host list. Identity is the stable hostId, so a
        # DHCP-served LAN (changing / reused IPs) collapses to one member.
        DiscoverFrom = '/var/log/squid/yuruna_access.log'
        StatusProbePort = 8080
    }
}

<#
.SYNOPSIS
    Address of the pool service serving $Area (e.g. 'stash-service',
    'pool-control-service'), or '' when the pool knows none.

.DESCRIPTION
    A host that needs the stash or pool-control service usually does not run it:
    the service lives on another host, often on another subnet, at an address
    DHCP is free to change. Nothing in this host's config knows where it is, and
    a hard-coded literal is only correct until the service moves -- which is how
    a cycle spends its timeouts on a machine that no longer exists.

    The pool already collects the answer. Every extension service registers
    through its owning host and self-announces to the aggregator, which is how
    the dashboard's Extension hosts panel is populated; this reads the same
    record back. The aggregator lives in the caching-proxy-service VM, so knowing the
    proxy address -- which every host needs anyway, to reach the cache at all --
    is enough to locate every other service the pool offers. A host with no
    caching-proxy service gets '' and falls back to whatever its caller does without a
    pool, which is the honest answer: with no proxy there is no aggregator, and
    with no aggregator there is no pool to ask.

    Returns the bare host ('192.168.7.227'), not a URL, because that is what the
    callers compose: an http probe, an scp target, a guest env value.

    NOT authenticated, and the TLS leaf is not verified. The aggregator's cert is
    minted by the caching-proxy service's own CA, which a harness host has no trust store
    entry for; the payload is LAN service coordinates, not a secret. The address
    that comes back is a HINT -- every consumer proves it independently (the
    stash pre-flight demands /healthz before publishing it), so a wrong answer
    fails closed at the probe rather than being trusted on the aggregator's word.

.PARAMETER Area
    Extension area slug as registered/announced: 'stash-service', 'pool-control-service'.

.PARAMETER TimeoutSeconds
    Per-request timeout. Short by default: this sits in front of a cycle, and a
    pool that does not answer promptly must not delay one.

.PARAMETER BaseUrl
    Aggregator base URL. Defaults to the one derived from this host's caching
    proxy; pass it to reach a specific collector (and so the tests can answer
    with a local listener instead of the pool).

.OUTPUTS
    [string] host address, or '' when unresolved.
#>
function Get-PoolExtensionHost {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Area,
        [int]$TimeoutSeconds = 5,
        [string]$BaseUrl
    )

    if ($BaseUrl) { return (Get-PoolExtensionHostFrom -BaseUrl $BaseUrl -Area $Area -TimeoutSeconds $TimeoutSeconds) }
    if (-not (Get-Command Get-PoolAggregatorServiceSeedUrl -ErrorAction SilentlyContinue)) {
        $cachingProxy = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules' |
            Join-Path -ChildPath 'Test.CachingProxyService.psm1'
        if (Test-Path -LiteralPath $cachingProxy) {
            Import-Module $cachingProxy -Global -Force -DisableNameChecking -Verbose:$false
        }
    }
    if (-not (Get-Command Get-PoolAggregatorServiceSeedUrl -ErrorAction SilentlyContinue)) {
        Set-PoolLookupOutcome -Outcome 'no-aggregator' -Detail 'Test.CachingProxyService not loadable' -Confirm:$false
        Write-Verbose "Get-PoolExtensionHost: Test.CachingProxyService not loadable; cannot resolve the aggregator."
        return ''
    }
    $base = Get-PoolAggregatorServiceSeedUrl
    if ([string]::IsNullOrWhiteSpace($base)) {
        Set-PoolLookupOutcome -Outcome 'no-aggregator' -Detail 'no caching-proxy-service address known' -Confirm:$false
        Write-Verbose "Get-PoolExtensionHost: no caching-proxy-service address known, so no aggregator to ask."
        return ''
    }
    return (Get-PoolExtensionHostFrom -BaseUrl $base -Area $Area -TimeoutSeconds $TimeoutSeconds)
}

<#
.SYNOPSIS
    The one request Get-PoolExtensionHost makes, against an explicit aggregator.
.DESCRIPTION
    Split out so address RESOLUTION (which needs a caching-proxy service, a config file,
    a whole host) stays separate from the LOOKUP (which needs only a URL). Every
    failure shape returns '' -- this sits in front of a cycle and must not throw
    into one.

    Returning '' for every shape keeps that contract but erases the distinction
    a caller most needs: "the pool says no host serves this area" is a settled
    answer, while "the pool could not be reached" is a statement about the
    asker's own link and usually cures itself. A caller that stops a cycle on
    the empty string reports the first when it saw the second, sending an
    operator to look for a service that was running the whole time. The reason
    is therefore recorded alongside the return for
    Get-PoolExtensionHostLastOutcome to read, and a transport failure is a
    warning rather than a verbose line: it is the shape that stops cycles.
.OUTPUTS
    [string] host address, or ''.
#>
function Get-PoolExtensionHostFrom {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Area,
        [int]$TimeoutSeconds = 5
    )

    # Route from the manifest, not a second literal: a copy here is a copy that
    # keeps answering the old path after the map is corrected.
    $route = (Get-PoolAggregatorServiceManifest).Endpoints.ExtensionHosts
    $uri = "$($BaseUrl.TrimEnd('/'))$route`?area=$([uri]::EscapeDataString($Area))"
    try {
        # 404 is the documented "no live host for this area" answer, not a
        # transport failure, so it must not throw its way into the catch and be
        # reported as an aggregator problem.
        $response = Invoke-WebRequest -Uri $uri -TimeoutSec $TimeoutSeconds -SkipCertificateCheck -SkipHttpErrorCheck -ErrorAction Stop
        if ($response.StatusCode -eq 404) {
            # Two different 404s land here and both mean "cannot answer": this
            # handler's "no live host for that extension area", and the Go mux's
            # "404 page not found" from an aggregator too old to have the route.
            # The fallback is identical, so they are not worth branching on --
            # but the body tells them apart, and the second is fixed by
            # redeploying the collector.
            $detail = ($response.Content | Out-String).Trim()
            Set-PoolLookupOutcome -Outcome 'no-host' -Uri $uri -Detail "404 -- $detail" -Confirm:$false
            Write-Verbose "Get-PoolExtensionHost: 404 for area '$Area' -- $detail"
            return ''
        }
        if ($response.StatusCode -ne 200) {
            Set-PoolLookupOutcome -Outcome 'http-error' -Uri $uri -Detail "HTTP $($response.StatusCode)" -Confirm:$false
            Write-Verbose "Get-PoolExtensionHost: aggregator answered $($response.StatusCode) for area '$Area'."
            return ''
        }
        $entry = $response.Content | ConvertFrom-Json
        $resolved = [string]$entry.host
        if ([string]::IsNullOrWhiteSpace($resolved)) {
            Set-PoolLookupOutcome -Outcome 'no-host' -Uri $uri -Detail 'aggregator answered 200 with no host' -Confirm:$false
            return ''
        }
        Set-PoolLookupOutcome -Outcome 'ok' -Uri $uri -Detail $resolved.Trim() -Confirm:$false
        return $resolved.Trim()
    } catch {
        Set-PoolLookupOutcome -Outcome 'transport-error' -Uri $uri -Detail $_.Exception.Message -Confirm:$false
        Write-Warning "Get-PoolExtensionHost: could not reach the aggregator at $BaseUrl for area '$Area' ($($_.Exception.Message)). This is the asker's own link, not a statement that no '$Area' host exists."
        return ''
    }
}

<#
.SYNOPSIS
    Why the last Get-PoolExtensionHostFrom in this session returned what it did.
.DESCRIPTION
    The lookup answers with a bare string so it can never throw into a cycle.
    This is where the reason behind an empty answer is kept, so a caller about
    to stop a cycle can say WHICH condition it hit instead of reporting the one
    that happens to read worst.

    Session-scoped and overwritten per lookup: read it immediately after the
    call it belongs to.
.OUTPUTS
    [hashtable] Outcome ('none' | 'ok' | 'no-host' | 'http-error' |
    'transport-error' | 'no-aggregator'), Detail [string], Uri [string].
#>
function Get-PoolExtensionHostLastOutcome {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if ($null -eq $script:LastPoolLookup) {
        return @{ Outcome = 'none'; Detail = ''; Uri = '' }
    }
    return $script:LastPoolLookup
}

function Set-PoolLookupOutcome {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Outcome,
        [AllowEmptyString()][string]$Uri = '',
        [AllowEmptyString()][string]$Detail = ''
    )
    if ($PSCmdlet.ShouldProcess('pool lookup outcome', "record '$Outcome'")) {
        $script:LastPoolLookup = @{ Outcome = $Outcome; Detail = $Detail; Uri = $Uri }
    }
}

Export-ModuleMember -Function Get-PoolAggregatorServiceManifest, Get-PoolExtensionHost, Get-PoolExtensionHostFrom, Get-PoolExtensionHostLastOutcome
