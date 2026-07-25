<#PSScriptInfo
.VERSION 2026.07.25
.GUID 6b2f9d41-8c73-4a05-9e62-1d47f3a8b520
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool discovery extension stash
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

# Pool-level service discovery: "where is the extension service that is ACTIVE
# right now?", answered from the pool aggregator rather than from any one host's
# hypervisor.
#
# WHY THIS EXISTS. Extension services (the stash service, pool control) were
# discovered with a LOCAL Get-VMIp against a well-known VM name. That only
# answers when the service VM happens to run on the machine asking -- in a pool
# the stash service usually runs somewhere else entirely, and the lookup returns
# nothing with a "is it running?" warning even while the service is healthy and
# visible on the dashboard.
#
# The pool aggregator already owns the correct answer. Each host self-reports its
# activeExtensions + extensionTargets in its registration record; the aggregator
# polls those, folds in any live self-announce (POST /announce, which survives a
# host whose status server is down), and publishes the result three ways:
#   * yuruna_pool_host_extension{hostId,area,baseUrl,target} -> the "Extension
#     hosts" table on the Grafana pool dashboard, whose Extension column links to
#     that hidden `target` field. That table IS the operator-facing view of this.
#   * GET /api/v1/pool-status -> the same data as JSON (this module's source).
#   * GET /go/stash?host=<hostId> -> a 302 for consumers that have a hostId and
#     want the redirect done server-side.
# This module reads the JSON view, so a caller gets exactly the URL an operator
# would reach by clicking the dashboard's Extension column -- no VM names, no
# hypervisor calls, no host-local assumptions.
#
# Results are memoized (default 5 minutes) because every sequence step that
# expands ${ext:...} would otherwise re-run a TLS handshake against the
# aggregator for an answer that changes only when a service moves.

Import-Module (Join-Path $PSScriptRoot 'Test.PoolPush.psm1')    -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.CachingProxy.psm1') -Global -Force -DisableNameChecking -ErrorAction SilentlyContinue
# Test.Config supplies Read-TestConfig / Get-TestConfigValue for the
# vmStart.cachingProxyIP fallback in Get-PoolAggregatorIp. Imported rather than
# assumed: without it that fallback is Get-Command-gated and silently never
# fires, so a host with no caching-proxy state file resolves NO aggregator and
# discovery degrades for a reason no log line explains.
Import-Module (Join-Path $PSScriptRoot 'Test.Config.psm1') -Global -Force -DisableNameChecking -ErrorAction SilentlyContinue

# One process-wide memo: @{ FetchedAt = [datetime]; Map = @{ area -> @{...} } }.
$script:PoolExtensionCache = $null

function Get-PoolDiscoveryTtlSecond {
    <#
    .SYNOPSIS
        How long a discovered extension-target map stays fresh, in seconds.
    .DESCRIPTION
        Default 300 (5 minutes). $env:YURUNA_POOL_DISCOVERY_TTL_SECONDS overrides
        it for a host that moves services often (or a test that wants no cache at
        all, via 0). A non-numeric or negative value is ignored rather than
        throwing -- discovery must never fail on a malformed knob.
    .OUTPUTS
        [int] seconds.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    $ttl = 300
    if (-not [string]::IsNullOrWhiteSpace($env:YURUNA_POOL_DISCOVERY_TTL_SECONDS)) {
        $parsed = 0
        if ([int]::TryParse($env:YURUNA_POOL_DISCOVERY_TTL_SECONDS.Trim(), [ref]$parsed) -and $parsed -ge 0) {
            $ttl = $parsed
        } else {
            Write-Verbose "Get-PoolDiscoveryTtlSecond: ignoring non-numeric YURUNA_POOL_DISCOVERY_TTL_SECONDS='$env:YURUNA_POOL_DISCOVERY_TTL_SECONDS'."
        }
    }
    return $ttl
}

function Get-PoolAggregatorIp {
    <#
    .SYNOPSIS
        The address of the host running the pool aggregator (the caching-proxy
        VM, which also serves Grafana on :3000 and the aggregator on :9400).
    .DESCRIPTION
        Same resolution order the other aggregator callers use
        (Remove-PoolHost.ps1): the caching-proxy state file first because it is
        written when the VM is started and therefore reflects a rebuilt VM's new
        IP, then $env:YURUNA_CACHING_PROXY_IP which the runner forwards into
        every child, then the configured vmStart.cachingProxyIP as the static
        fallback. Returns '' when nothing is known -- callers degrade rather
        than fail.
    .OUTPUTS
        [string] IPv4/host, or ''.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (Get-Command Read-CachingProxyState -ErrorAction SilentlyContinue) {
        try {
            $state = Read-CachingProxyState
            if ($state -and $state.ipAddress) { return [string]$state.ipAddress }
        } catch { Write-Verbose "Get-PoolAggregatorIp: caching-proxy state unreadable ($($_.Exception.Message))." }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:YURUNA_CACHING_PROXY_IP)) {
        return $env:YURUNA_CACHING_PROXY_IP.Trim()
    }
    if ((Get-Command Read-TestConfig -ErrorAction SilentlyContinue) -and
        -not [string]::IsNullOrWhiteSpace($env:YURUNA_CONFIG_PATH)) {
        try {
            $cfg = Read-TestConfig -Path $env:YURUNA_CONFIG_PATH
            $ip  = Get-TestConfigValue -Config $cfg -Path 'vmStart.cachingProxyIP'
            if (-not [string]::IsNullOrWhiteSpace([string]$ip)) { return ([string]$ip).Trim() }
        } catch { Write-Verbose "Get-PoolAggregatorIp: config read failed ($($_.Exception.Message))." }
    }
    return ''
}

function Get-PoolStatusDocument {
    <#
    .SYNOPSIS
        GET /api/v1/pool-status from the aggregator over CA-pinned HTTPS and
        return the parsed JSON, or $null.
    .DESCRIPTION
        Uses the same pinned-TLS client and CA-refresh-once behavior as the
        push/forget paths (Test.PoolPush): the aggregator serves a private CA, so
        an unpinned request would either fail validation or require disabling it.
        pool-status is unauthenticated by design -- it is the read-only snapshot
        the dashboard renders -- so no bearer token is involved.

        Never throws: discovery is an optimization over the caller's fallback,
        and an unreachable aggregator must not fail a cycle step.
    .OUTPUTS
        [pscustomobject] parsed pool-status, or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()][AllowEmptyString()][string]$ProxyIp,
        [Parameter()][int]$Port = 9400,
        [Parameter()][int]$TimeoutSec = 10
    )
    if ([string]::IsNullOrWhiteSpace($ProxyIp)) { $ProxyIp = Get-PoolAggregatorIp }
    if ([string]::IsNullOrWhiteSpace($ProxyIp)) {
        Write-Verbose 'Get-PoolStatusDocument: no caching-proxy/aggregator address known.'
        return $null
    }
    if (-not ([System.Management.Automation.PSTypeName]'YurunaPoolPinnedTls').Type) {
        Write-Verbose 'Get-PoolStatusDocument: pinned-TLS helper unavailable.'
        return $null
    }
    $runtimeDir = if ($env:YURUNA_RUNTIME_DIR) { $env:YURUNA_RUNTIME_DIR } else { [System.IO.Path]::GetTempPath() }
    $url = "https://${ProxyIp}:$Port/api/v1/pool-status"

    # Try the cached CA, then once more with a freshly fetched one: a rebuilt
    # caching-proxy rotates its CA and the stale pin would fail every call until
    # something forced a refresh.
    foreach ($refresh in @($false, $true)) {
        $caPath = ''
        try {
            $caPath = if ($refresh) {
                Get-PoolCaCertPath -ProxyIp $ProxyIp -RuntimeDir $runtimeDir -TimeoutSec $TimeoutSec -Refresh -Confirm:$false
            } else {
                Get-PoolCaCertPath -ProxyIp $ProxyIp -RuntimeDir $runtimeDir -TimeoutSec $TimeoutSec -Confirm:$false
            }
        } catch { Write-Verbose "Get-PoolStatusDocument: CA fetch failed ($($_.Exception.Message))." }
        if ([string]::IsNullOrWhiteSpace($caPath)) { continue }

        $client = $null
        try {
            $ca     = New-PoolX509Certificate -Path $caPath
            $client = [YurunaPoolPinnedTls]::Client($ca, $TimeoutSec)
            $resp   = $client.GetAsync($url).GetAwaiter().GetResult()
            if ([int]$resp.StatusCode -ne 200) {
                Write-Verbose "Get-PoolStatusDocument: HTTP $([int]$resp.StatusCode) from $url."
                continue
            }
            $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ([string]::IsNullOrWhiteSpace($body)) { continue }
            return ($body | ConvertFrom-Json)
        } catch {
            Write-Verbose "Get-PoolStatusDocument: $($_.Exception.Message)"
        } finally {
            if ($client) { $client.Dispose() }
        }
    }
    return $null
}

function ConvertFrom-PoolStatusExtensionTarget {
    <#
    .SYNOPSIS
        Reduce a pool-status document to @{ area -> @{ Target; HostId;
        LastSeenUnixMs; Source } }, keeping the most recently seen advertiser
        for each area.
    .DESCRIPTION
        Two sources, in the aggregator's own precedence order:

          * hosts[].extensionTargets -- what the owning host advertised in its
            registration record. Authoritative while that host is polled.
          * announcedExtensions[] -- the service's own POST /announce. This is
            the observable that survives a service whose OWNING HOST is dark, so
            it must be considered, not just used as decoration.

        Split out from the fetch so the reduction is unit-testable against a
        recorded document without a live aggregator.
    .OUTPUTS
        [hashtable] area -> @{ Target; HostId; LastSeenUnixMs; Source }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$Document)

    $map = @{}
    if ($null -eq $Document) { return $map }

    # Flatten both signals into one candidate list first, then reduce. Collecting
    # before choosing keeps the freshest-wins rule in ONE place instead of
    # duplicating the comparison across the two source loops.
    $candidates = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($hostEntry in @($Document.hosts)) {
        if ($null -eq $hostEntry) { continue }
        $lastSeen = 0L
        if ($hostEntry.PSObject.Properties['lastSeenUnixMs']) { $lastSeen = [long]$hostEntry.lastSeenUnixMs }
        $targets = $hostEntry.PSObject.Properties['extensionTargets']
        if (-not $targets -or -not $targets.Value) { continue }
        foreach ($prop in $targets.Value.PSObject.Properties) {
            $candidates.Add(@{
                Area = [string]$prop.Name; Target = [string]$prop.Value
                HostId = [string]$hostEntry.hostId; LastSeenUnixMs = $lastSeen; Source = 'registration'
            })
        }
    }

    foreach ($ann in @($Document.announcedExtensions)) {
        if ($null -eq $ann) { continue }
        $lastSeen = 0L
        if ($ann.PSObject.Properties['lastSeenUnixMs']) { $lastSeen = [long]$ann.lastSeenUnixMs }
        $candidates.Add(@{
            Area = [string]$ann.area; Target = [string]$ann.target
            HostId = [string]$ann.hostId; LastSeenUnixMs = $lastSeen; Source = 'announce'
        })
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.Area) -or [string]::IsNullOrWhiteSpace($candidate.Target)) { continue }
        $area = $candidate.Area
        if ($map.ContainsKey($area) -and $map[$area].LastSeenUnixMs -ge $candidate.LastSeenUnixMs) { continue }
        $map[$area] = @{
            Target = $candidate.Target.Trim(); HostId = $candidate.HostId
            LastSeenUnixMs = $candidate.LastSeenUnixMs; Source = $candidate.Source
        }
    }

    return $map
}

function Clear-PoolExtensionTargetCache {
    <#
    .SYNOPSIS
        Drop the memoized extension-target map so the next lookup refetches.
        Used by tests and by any caller that just moved a service.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('pool extension-target cache', 'Clear')) {
        $script:PoolExtensionCache = $null
    }
}

function Get-PoolExtensionTargetMap {
    <#
    .SYNOPSIS
        The memoized area -> advertiser map for every extension service the pool
        currently reports.
    .PARAMETER MaxAgeSeconds
        Override the memo TTL for this call. Defaults to
        Get-PoolDiscoveryTtlSecond (300s, or YURUNA_POOL_DISCOVERY_TTL_SECONDS).
    .PARAMETER Refresh
        Ignore the memo and refetch now.
    .OUTPUTS
        [hashtable] area -> @{ Target; HostId; LastSeenUnixMs; Source }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][int]$MaxAgeSeconds = -1,
        [Parameter()][switch]$Refresh
    )
    if ($MaxAgeSeconds -lt 0) { $MaxAgeSeconds = Get-PoolDiscoveryTtlSecond }

    if (-not $Refresh -and $null -ne $script:PoolExtensionCache -and $MaxAgeSeconds -gt 0) {
        $age = ((Get-Date) - $script:PoolExtensionCache.FetchedAt).TotalSeconds
        if ($age -lt $MaxAgeSeconds) {
            Write-Verbose "Get-PoolExtensionTargetMap: memo hit (age $([int]$age)s < ${MaxAgeSeconds}s)."
            return $script:PoolExtensionCache.Map
        }
    }

    $doc = Get-PoolStatusDocument
    $map = ConvertFrom-PoolStatusExtensionTarget -Document $doc
    # Cache even an empty result: a pool with no stash service must not re-probe
    # the aggregator on every single ${ext:...} expansion for the same 'no'.
    # Only a hard transport failure ($doc -eq $null) stays uncached, so a
    # temporarily unreachable aggregator is retried on the next lookup.
    if ($null -ne $doc) {
        $script:PoolExtensionCache = @{ FetchedAt = (Get-Date); Map = $map }
    }
    return $map
}

function Get-PoolExtensionTarget {
    <#
    .SYNOPSIS
        The URL of the extension service that is ACTIVE in the pool right now --
        the same value the Grafana pool dashboard's "Extension hosts" table links
        to from its Extension column.
    .DESCRIPTION
        This is the official, host-agnostic way to find an extension service. It
        asks the pool aggregator (which every host reports into) rather than the
        local hypervisor, so it answers correctly when the service runs on
        another host, and it keeps answering when the owning host's status server
        is down (the service's own announce backs it).

        Returns '' when the pool cannot answer -- no aggregator configured, none
        reachable, or nobody advertising this area. Callers are expected to
        degrade (a local lookup, a documented default) rather than fail, because
        a single-host operator may run no aggregator at all.
    .PARAMETER Area
        Extension area to resolve. 'stash-service' (default) or 'pool-control'.
    .PARAMETER AsHost
        Return just the host/IP instead of the full URL. The advertised target is
        a URL ('http://10.0.0.5'), but consumers like the guest-side STASH_HOST
        want a bare host they can put in an scp target or their own URL.
    .PARAMETER MaxAgeSeconds
        Memo TTL override for this call.
    .PARAMETER Refresh
        Ignore the memo and refetch now.
    .OUTPUTS
        [string] URL (or host with -AsHost), '' when unresolved.
    .EXAMPLE
        Get-PoolExtensionTarget
        # http://192.168.7.138
    .EXAMPLE
        Get-PoolExtensionTarget -Area 'stash-service' -AsHost
        # 192.168.7.138
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][string]$Area = 'stash-service',
        [Parameter()][switch]$AsHost,
        [Parameter()][int]$MaxAgeSeconds = -1,
        [Parameter()][switch]$Refresh
    )
    $map = Get-PoolExtensionTargetMap -MaxAgeSeconds $MaxAgeSeconds -Refresh:$Refresh
    if (-not $map.ContainsKey($Area)) {
        Write-Verbose "Get-PoolExtensionTarget: pool reports no active '$Area'."
        return ''
    }
    $target = [string]$map[$Area].Target
    if (-not $AsHost) { return $target }

    # A target is normally an absolute URL; tolerate a bare host/IP that an older
    # or hand-written registration advertised instead of failing to parse it.
    try {
        $uri = [System.Uri]::new($target)
        if ($uri.IsAbsoluteUri -and -not [string]::IsNullOrWhiteSpace($uri.Host)) { return $uri.Host }
    } catch { Write-Verbose "Get-PoolExtensionTarget: '$target' is not an absolute URL; returning it as-is." }
    return $target
}

Export-ModuleMember -Function Get-PoolDiscoveryTtlSecond, Get-PoolAggregatorIp, Get-PoolStatusDocument, ConvertFrom-PoolStatusExtensionTarget, Get-PoolExtensionTargetMap, Get-PoolExtensionTarget, Clear-PoolExtensionTargetCache
