<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42a346a8-65dc-4b6b-b4a8-0c5609e08d3f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna download agent service image
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

# Host-side client for the download-agent service: find an agent, ask it about
# an image, and take the bytes it already holds instead of pulling them from the
# origin once per host.
#
# Two structural rules this file lives by, both load-bearing:
#
#   * It imports NOTHING -- no -Global, no -Force, no nested import at all -- and
#     exports only three uniquely-named functions. The per-host drivers wrap
#     Save-CachedHttpUri to inject their own cache resolver and the image helpers
#     resolve that wrapper BY NAME, so a module re-exporting Save-CachedHttpUri
#     (or Test-DownloadAlreadyCurrent) and imported after a driver would take the
#     command-table slot, drop the cache-discovery closure, and send every
#     download direct with no error anywhere -- the regression class the drivers'
#     load-tail guards warn about.
#   * Nothing here throws at the caller. Discovery collapses to '' and the
#     request protocol to an outcome string, because every one of these calls
#     sits in front of a Get-Image run whose fallback is the origin path. A
#     broken agent must cost a warning line, never a cycle.

# The service VM name the local-VM rung of the ladder asks the driver about, and
# the extension area slug the pool rung asks the aggregator about.
$script:DownloadAgentVmName = 'yuruna-download-agent-service'
$script:DownloadAgentArea   = 'download-agent-service'

# Operator pin, spelled the way Get-ExtensionHostAddress derives it from an area.
$script:DownloadAgentPinVariable = 'YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE'

# The pool-aggregator-service listen port (its systemd unit and manifest agree
# on 9400); the aggregator rides inside the caching-proxy-service VM.
$script:AggregatorPort = 9400

# Every candidate is proved with a /healthz probe before it is accepted, on a
# budget short enough that three dead rungs cannot delay a cycle noticeably.
$script:HealthTimeoutSeconds = 2

# Per-request budget for the small JSON calls. Bytes are streamed separately and
# are NOT bounded by this.
$script:ApiTimeoutSeconds = 30

# Poll pacing while ensure answers "downloading": start responsive, back off so a
# multi-hour cold ISO does not produce thousands of requests.
$script:PollInitialSeconds = 2
$script:PollMaxSeconds     = 30

# Attempts one artifact fetch may consume. A resume costs a Range request, not a
# restart, so a small bound still covers a stream that breaks repeatedly -- while
# keeping a server that hands back nothing from looping forever.
$script:MaxFetchAttempt = 5

# Memoized discovery result. '' is a real answer (no agent), so the "have we
# looked" flag is separate from the value.
$script:EndpointResolved = $false
$script:EndpointValue    = ''

# The host/ directory names, which are what the pool tree is keyed by. Anything
# else is a caller mistake the agent would 400, so it is refused here instead of
# on the wire.
$script:KnownHostType = @('windows.hyper-v', 'ubuntu.kvm', 'macos.utm')

function Format-DownloadAgentUrlHost {
    <#
    .SYNOPSIS
        Bracket an IPv6 literal so a URL authority parses; pass anything else
        through unchanged.
    .DESCRIPTION
        Local rather than borrowed from Yuruna.Common on purpose: this module
        imports nothing, so it cannot evict a driver's command-table entry.
    .PARAMETER Address
        Bare address or hostname.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Address)
    $value = ([string]$Address).Trim()
    if ($value -eq '') { return '' }
    if ($value.StartsWith('[')) { return $value }
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($value, [ref]$parsed) -and
        $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        return "[$value]"
    }
    return $value
}

function ConvertTo-DownloadAgentBaseUrl {
    <#
    .SYNOPSIS
        Normalize an advertised address into a scheme://authority base URL, or ''
        when it cannot become one.
    .DESCRIPTION
        The three rungs of the ladder hand back three shapes: an operator pin
        may be a bare IP or a full URL, the driver's Get-VMIp answers a bare IP,
        and the pool advertises a base URL verbatim -- the only one that carries
        a non-default port (a UTM Shared-NAT Mac publishes :8082). Everything
        collapses here so the rest of the module composes paths onto one shape.

        An address carrying quotes or whitespace is dropped rather than
        composed: it cannot be a URL authority, and gluing it into one would
        produce a request against something nobody advertised.
    .PARAMETER Address
        Bare address, host:port, or an http(s) URL.
    .OUTPUTS
        [string] base URL with no trailing slash, or ''.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Address)

    $value = ([string]$Address).Trim()
    if ($value -eq '') { return '' }
    if ($value -match "['`"\s]") {
        Write-Verbose "ConvertTo-DownloadAgentBaseUrl: dropping '$value' -- an address carrying quotes or whitespace cannot be a URL authority."
        return ''
    }
    if ($value -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') {
        $value = 'http://' + (Format-DownloadAgentUrlHost -Address $value)
    }
    $uri = $null
    if (-not [System.Uri]::TryCreate($value, [System.UriKind]::Absolute, [ref]$uri)) {
        Write-Verbose "ConvertTo-DownloadAgentBaseUrl: '$Address' does not parse as an absolute URL."
        return ''
    }
    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') {
        Write-Verbose "ConvertTo-DownloadAgentBaseUrl: scheme '$($uri.Scheme)' is not http(s)."
        return ''
    }
    if ([string]::IsNullOrWhiteSpace($uri.Authority)) { return '' }
    return "$($uri.Scheme)://$($uri.Authority)"
}

function ConvertTo-DownloadAgentHostType {
    <#
    .SYNOPSIS
        Normalize a host type to the host/ directory name the pool tree uses, or
        '' when it is not one of the three.
    .DESCRIPTION
        Get-HostType answers the 'host.'-prefixed form ('host.ubuntu.kvm') while
        the pool is keyed by the directory name ('ubuntu.kvm'), and a caller may
        hand over either. Stripping defensively here keeps every call site from
        having to remember which vocabulary it holds.
    .PARAMETER HostType
        'ubuntu.kvm' or 'host.ubuntu.kvm', either case.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$HostType)
    $value = ([string]$HostType).Trim()
    if ($value -match '^(?i)host\.') { $value = $value.Substring(5) }
    $value = $value.ToLowerInvariant()
    if ($script:KnownHostType -notcontains $value) {
        Write-Verbose "ConvertTo-DownloadAgentHostType: '$HostType' is not one of $($script:KnownHostType -join ', ')."
        return ''
    }
    return $value
}

function Test-DownloadAgentHealth {
    <#
    .SYNOPSIS
        $true when $BaseUrl/healthz answers 200 inside the probe budget.
    .DESCRIPTION
        Every rung of the discovery ladder is a HINT -- an operator pin that
        outlived its VM, a driver lookup that returned a lease-recycled address,
        a pool record for a service that has since stopped. The probe is what
        turns a hint into an endpoint, so a wrong answer costs one bounded
        request instead of a cycle's worth of timeouts.
    .PARAMETER BaseUrl
        Normalized scheme://authority base URL.
    .PARAMETER TimeoutSeconds
        Probe budget.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()][string]$BaseUrl,
        [int]$TimeoutSeconds = 2
    )
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { return $false }
    try {
        $response = Invoke-WebRequest -Uri "$BaseUrl/healthz" -Method Get `
            -TimeoutSec ([Math]::Max(1, $TimeoutSeconds)) -SkipCertificateCheck -SkipHttpErrorCheck -ErrorAction Stop
        if ([int]$response.StatusCode -eq 200) { return $true }
        Write-Verbose "Test-DownloadAgentHealth: $BaseUrl/healthz answered HTTP $([int]$response.StatusCode)."
        return $false
    } catch {
        Write-Verbose "Test-DownloadAgentHealth: $BaseUrl/healthz failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-DownloadAgentPoolAddress {
    <#
    .SYNOPSIS
        The base URL the pool advertises for the download-agent-service area, or
        ''.
    .DESCRIPTION
        Reads the aggregator's extension-host record -- the same record that
        fills the dashboard's Extension hosts panel. The advertised 'target' is
        preferred over the bare 'host' because the target is the only one that
        carries a published port, and a Shared-NAT Mac is reachable only through
        the forward its marker published.

        https first, http second: a provisioned proxy mints the aggregator's TLS
        leaf in cloud-init, but an older plain-HTTP aggregator must still be
        askable. The leaf is signed by the proxy's own CA, which a harness host
        has no trust-store entry for, so verification is skipped -- the payload
        is LAN service coordinates and the answer is proved by /healthz anyway.
    .PARAMETER CacheHost
        Caching-proxy-service address; the aggregator lives in that VM.
    .PARAMETER TimeoutSeconds
        Per-request budget.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$CacheHost,
        [int]$TimeoutSeconds = 5
    )
    $urlHost = Format-DownloadAgentUrlHost -Address $CacheHost
    if ($urlHost -eq '') { return '' }
    $query = "/api/v1/extension-hosts?area=$([uri]::EscapeDataString($script:DownloadAgentArea))"
    foreach ($scheme in @('https', 'http')) {
        $uri = "${scheme}://${urlHost}:$($script:AggregatorPort)$query"
        try {
            $response = Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec $TimeoutSeconds `
                -SkipCertificateCheck -SkipHttpErrorCheck -ErrorAction Stop
            if ([int]$response.StatusCode -ne 200) {
                # 404 is the documented "no live host for this area" answer, not
                # a transport failure -- and an aggregator too old to know the
                # route answers the Go mux's own 404. Both mean the same thing
                # here, so neither is worth branching on.
                Write-Verbose "Get-DownloadAgentPoolAddress: $uri answered HTTP $([int]$response.StatusCode)."
                continue
            }
            $entry = $response.Content | ConvertFrom-Json
            $advertised = [string]$entry.target
            if ([string]::IsNullOrWhiteSpace($advertised)) { $advertised = [string]$entry.host }
            if (-not [string]::IsNullOrWhiteSpace($advertised)) { return $advertised.Trim() }
            Write-Verbose "Get-DownloadAgentPoolAddress: $uri answered with no address."
        } catch {
            Write-Verbose "Get-DownloadAgentPoolAddress: $uri failed: $($_.Exception.Message)"
        }
    }
    return ''
}

function Get-DownloadAgentEndpointCandidate {
    <#
    .SYNOPSIS
        The discovery ladder's candidates, nearest first, as
        @{ BaseUrl; Source } records.
    .DESCRIPTION
        Split out from Resolve-DownloadAgentEndpoint so the ORDER (an operator
        pin beats a local VM beats the pool) stays separate from the probing,
        and so a rung that fails is one skipped candidate rather than a failed
        resolution.
    .OUTPUTS
        [hashtable[]]
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param()

    $candidate = [System.Collections.Generic.List[hashtable]]::new()

    # 1. Operator pin. Always first: it is the escape hatch for a lab whose
    #    discovery is wrong, and discovery must never win over it.
    $pinned = [System.Environment]::GetEnvironmentVariable($script:DownloadAgentPinVariable)
    if (-not [string]::IsNullOrWhiteSpace($pinned)) {
        [void]$candidate.Add(@{ Address = $pinned; Source = "`$env:$($script:DownloadAgentPinVariable)" })
    }

    # 2. An agent VM on this host. Get-VMIp arrives with the host driver, and a
    #    Get-Image script has one loaded -- but a bare caller may not, which is
    #    a missing rung, not an error.
    if (Get-Command -Name Get-VMIp -ErrorAction SilentlyContinue) {
        try {
            $vmIp = [string](Get-VMIp -VMName $script:DownloadAgentVmName)
            if (-not [string]::IsNullOrWhiteSpace($vmIp)) {
                [void]$candidate.Add(@{ Address = $vmIp; Source = "VM '$($script:DownloadAgentVmName)' on this host" })
            }
        } catch {
            Write-Verbose "Get-DownloadAgentEndpointCandidate: Get-VMIp '$($script:DownloadAgentVmName)' failed: $($_.Exception.Message)"
        }
    } else {
        Write-Verbose "Get-DownloadAgentEndpointCandidate: no Get-VMIp in scope; skipping the local-VM rung."
    }

    # 3. The pool's record, reached through the caching proxy that hosts the
    #    aggregator. The driver's Resolve-CacheHostIp probes its claims before
    #    answering; the env var is the claim a host with no driver still has.
    $cacheHost = ''
    if (Get-Command -Name Resolve-CacheHostIp -ErrorAction SilentlyContinue) {
        try { $cacheHost = [string](Resolve-CacheHostIp) }
        catch { Write-Verbose "Get-DownloadAgentEndpointCandidate: Resolve-CacheHostIp failed: $($_.Exception.Message)" }
    }
    if ([string]::IsNullOrWhiteSpace($cacheHost)) {
        $cacheHost = [string][System.Environment]::GetEnvironmentVariable('YURUNA_CACHING_PROXY_SERVICE_IP')
    }
    if (-not [string]::IsNullOrWhiteSpace($cacheHost)) {
        $advertised = Get-DownloadAgentPoolAddress -CacheHost $cacheHost.Trim()
        if (-not [string]::IsNullOrWhiteSpace($advertised)) {
            [void]$candidate.Add(@{ Address = $advertised; Source = "the pool (aggregator at $($cacheHost.Trim()))" })
        }
    } else {
        Write-Verbose 'Get-DownloadAgentEndpointCandidate: no caching-proxy address known, so no aggregator to ask.'
    }

    $normalized = [System.Collections.Generic.List[hashtable]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $candidate) {
        $baseUrl = ConvertTo-DownloadAgentBaseUrl -Address ([string]$entry.Address)
        if ($baseUrl -eq '') { continue }
        if (-not $seen.Add($baseUrl)) { continue }
        [void]$normalized.Add(@{ BaseUrl = $baseUrl; Source = [string]$entry.Source })
    }
    return [hashtable[]]$normalized.ToArray()
}

function Resolve-DownloadAgentEndpoint {
    <#
    .SYNOPSIS
        Base URL of a healthy download-agent service, or '' when there is none.
    .DESCRIPTION
        The discovery ladder, nearest first:

          1. $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE -- the operator pin;
          2. an agent VM on this host, via the driver's Get-VMIp (feature-detected,
             because a caller outside a cycle may have loaded no driver);
          3. the pool's own record, read from the aggregator inside the
             caching-proxy VM.

        Every candidate is /healthz-probed before it is accepted, so an address
        that outlived its service is discarded rather than believed. Every
        failure shape -- no pin, no driver, no proxy, no aggregator, an
        aggregator that 404s, a probe that times out -- collapses to '', and
        nothing here throws: the caller's fallback is the origin path, and a
        broken agent must not be able to fail a cycle.

        The answer is memoized for the process. A Get-Image run asks once per
        family and would otherwise re-walk the whole ladder for each; -Refresh
        re-resolves for the rare caller that started an agent mid-process.
    .PARAMETER Refresh
        Re-run the ladder instead of answering from the memo.
    .OUTPUTS
        [string] base URL such as 'http://10.0.0.9' (or 'http://10.0.0.9:8082'
        where the marker published a forwarded port), or ''.
    .EXAMPLE
        $agent = Resolve-DownloadAgentEndpoint
        if ($agent) { ... }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$Refresh)

    if (-not $Refresh -and $script:EndpointResolved) { return $script:EndpointValue }

    $script:EndpointResolved = $true
    $script:EndpointValue    = ''
    try {
        foreach ($entry in (Get-DownloadAgentEndpointCandidate)) {
            if (Test-DownloadAgentHealth -BaseUrl $entry.BaseUrl -TimeoutSeconds $script:HealthTimeoutSeconds) {
                Write-Verbose "Resolve-DownloadAgentEndpoint: $($entry.BaseUrl) (from $($entry.Source)) answered /healthz."
                $script:EndpointValue = $entry.BaseUrl
                break
            }
            Write-Verbose "Resolve-DownloadAgentEndpoint: discarding $($entry.BaseUrl) (from $($entry.Source)) -- no healthy agent there."
        }
    } catch {
        # Deliberately total. Anything unforeseen in the ladder -- a driver
        # command that throws in a shape the rung did not expect, a malformed
        # aggregator payload -- means "no agent", which is a supported state.
        Write-Verbose "Resolve-DownloadAgentEndpoint: discovery failed: $($_.Exception.Message)"
        $script:EndpointValue = ''
    }
    return $script:EndpointValue
}

function Get-DownloadAgentImageUri {
    <#
    .SYNOPSIS
        Compose an image-route URL for one identity.
    .PARAMETER BaseUrl
        Normalized agent base URL.
    .PARAMETER HostType
        Pool host type, already normalized to the host/ directory name.
    .PARAMETER ImageKey
        Pool image key.
    .PARAMETER Arch
        'amd64' or 'arm64'.
    .PARAMETER Variant
        'stable' or 'daily'.
    .PARAMETER Suffix
        Route suffix appended after the identity, e.g. '/ensure'.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$ImageKey,
        [Parameter(Mandatory)][string]$Arch,
        [Parameter(Mandatory)][string]$Variant,
        [AllowEmptyString()][string]$Suffix = ''
    )
    $path = "/api/v1/images/$([uri]::EscapeDataString($HostType))/$([uri]::EscapeDataString($ImageKey))$Suffix"
    return "$($BaseUrl.TrimEnd('/'))$path" +
        "?arch=$([uri]::EscapeDataString($Arch))&variant=$([uri]::EscapeDataString($Variant))"
}

function Invoke-DownloadAgentEnsure {
    <#
    .SYNOPSIS
        One ensure POST. Returns @{ Status; Body } with Body possibly $null.
    .DESCRIPTION
        The fingerprint body is what the agent compares against its current
        pointer, and it deliberately carries no hash: hashing a multi-GB local
        artifact just to ask a question would cost more than the download the
        question avoids. The agent's fallback comparison is exactly filename +
        byte count, which the host's 4-line sentinel supplies for free.
    .PARAMETER Uri
        Fully composed ensure URL.
    .PARAMETER LocalFilename
        Upstream filename the host already holds, or ''.
    .PARAMETER LocalByteCount
        Byte count the host already holds, or 0.
    .PARAMETER LocalSha256
        Hash the host already holds, or '' when it has none.
    .OUTPUTS
        [hashtable]
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [AllowEmptyString()][string]$LocalFilename = '',
        [int64]$LocalByteCount = 0,
        [AllowEmptyString()][string]$LocalSha256 = ''
    )
    $body = @{
        filename  = [string]$LocalFilename
        byteCount = [int64]$LocalByteCount
        sha256    = [string]$LocalSha256
    } | ConvertTo-Json -Compress
    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Post -Body $body -ContentType 'application/json' `
            -TimeoutSec $script:ApiTimeoutSeconds -SkipCertificateCheck -SkipHttpErrorCheck -ErrorAction Stop
        $parsed = $null
        try { $parsed = $response.Content | ConvertFrom-Json }
        catch { Write-Verbose "Invoke-DownloadAgentEnsure: $Uri answered unparseable JSON: $($_.Exception.Message)" }
        return @{ Status = [int]$response.StatusCode; Body = $parsed; Error = '' }
    } catch {
        return @{ Status = 0; Body = $null; Error = $_.Exception.Message }
    }
}

function Save-DownloadAgentArtifact {
    <#
    .SYNOPSIS
        Stream one generation to $OutFile, resuming with Range instead of
        restarting when a transfer comes up short.
    .DESCRIPTION
        A multi-GB artifact that stops at 90% must not be re-fetched from zero:
        the byte route is http.ServeContent, so it honors Range and a resumed
        attempt costs only the remainder. An exception mid-body and a body that
        simply ended early (a proxy that truncated, a peer that stopped
        relaying) are treated the same, because to the file on disk they ARE the
        same: both leave a short file, answered by asking for the rest.

        Attempts are bounded so a server that hands back nothing cannot loop
        forever, and the wall-clock deadline is honored between attempts so the
        caller's budget still means something.
    .PARAMETER Uri
        Fully composed byte-route URL.
    .PARAMETER OutFile
        Staging path to write.
    .PARAMETER ExpectedByteCount
        Size the agent's metadata reports, or 0 when unknown.
    .PARAMETER Deadline
        UTC wall-clock deadline for the whole fetch.
    .OUTPUTS
        [hashtable] @{ Ok; ByteCount; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [int64]$ExpectedByteCount = 0,
        [datetime]$Deadline = [datetime]::MaxValue
    )

    Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    $parent = Split-Path -Parent $OutFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $client = [System.Net.Http.HttpClient]::new()
    # No client-level timeout: a cold ISO legitimately takes hours, and the
    # caller's deadline is the budget that governs this fetch.
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $written = 0L
    $lastError = ''
    try {
        for ($attempt = 1; $attempt -le $script:MaxFetchAttempt; $attempt++) {
            if ([datetime]::UtcNow -ge $Deadline) {
                $lastError = 'the deadline expired before the artifact finished transferring'
                break
            }
            $written = 0L
            if (Test-Path -LiteralPath $OutFile) { $written = (Get-Item -LiteralPath $OutFile).Length }
            if ($ExpectedByteCount -gt 0 -and $written -ge $ExpectedByteCount) { break }

            try {
                $written = Copy-DownloadAgentStream -Client $client -Uri $Uri -OutFile $OutFile -Offset $written -ExpectedByteCount $ExpectedByteCount
                $lastError = ''
            } catch {
                $lastError = $_.Exception.Message
                Write-Verbose "Save-DownloadAgentArtifact: attempt $attempt of $Uri failed after $written byte(s): $lastError"
                if (Test-Path -LiteralPath $OutFile) { $written = (Get-Item -LiteralPath $OutFile).Length }
                continue
            }

            if ($ExpectedByteCount -le 0 -or $written -ge $ExpectedByteCount) { break }
            $lastError = "the transfer ended at $written of $ExpectedByteCount byte(s)"
            Write-Verbose "Save-DownloadAgentArtifact: attempt $attempt came up short ($lastError); resuming with a Range request."
        }
    } finally {
        $client.Dispose()
        Write-Progress -Activity "Fetching $Uri from the download agent" -Completed
    }

    if ($ExpectedByteCount -gt 0 -and $written -lt $ExpectedByteCount) {
        if ($lastError -eq '') { $lastError = "the transfer ended at $written of $ExpectedByteCount byte(s)" }
        return @{ Ok = $false; ByteCount = $written; Error = $lastError }
    }
    if ($written -le 0) {
        if ($lastError -eq '') { $lastError = 'the agent served no bytes' }
        return @{ Ok = $false; ByteCount = 0; Error = $lastError }
    }
    return @{ Ok = $true; ByteCount = $written; Error = '' }
}

function Copy-DownloadAgentStream {
    <#
    .SYNOPSIS
        One GET (optionally ranged) copied onto $OutFile at $Offset. Returns the
        file's total length afterwards.
    .PARAMETER Client
        HttpClient to send on.
    .PARAMETER Uri
        Byte-route URL.
    .PARAMETER OutFile
        Staging path.
    .PARAMETER Offset
        Bytes already on disk; a positive value asks for the remainder.
    .PARAMETER ExpectedByteCount
        Size the agent's metadata reports, for progress only.
    .OUTPUTS
        [int64]
    #>
    [CmdletBinding()]
    [OutputType([int64])]
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [int64]$Offset = 0,
        [int64]$ExpectedByteCount = 0
    )

    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, [System.Uri]$Uri)
    if ($Offset -gt 0) {
        $request.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new($Offset, $null)
    }
    $response = $Client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    try {
        $status = [int]$response.StatusCode
        if ($status -eq 416) {
            # The server says there is nothing past our offset: the file on disk
            # is already whole as far as it is concerned.
            return (Get-Item -LiteralPath $OutFile).Length
        }
        if (-not $response.IsSuccessStatusCode) {
            throw "HTTP $status $($response.ReasonPhrase) for $Uri"
        }
        # A server that answers 200 to a ranged request ignored the range and is
        # sending the whole artifact again; appending would splice two copies.
        $append = ($Offset -gt 0 -and $status -eq 206)
        $mode = if ($append) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }

        $activity = "Fetching $Uri from the download agent"
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        try {
            $out = [System.IO.FileStream]::new($OutFile, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            try {
                $buffer = [byte[]]::new(256 * 1024)
                $total = if ($append) { $Offset } else { 0L }
                $next = [datetime]::UtcNow.AddSeconds(2)
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $out.Write($buffer, 0, $read)
                    $total += $read
                    if ([datetime]::UtcNow -gt $next) {
                        if ($ExpectedByteCount -gt 0) {
                            $percent = [Math]::Min(100, [Math]::Round($total * 100.0 / $ExpectedByteCount, 1))
                            Write-Progress -Activity $activity -PercentComplete $percent `
                                -Status ("{0:N1} / {1:N1} MB ({2}%)" -f ($total / 1MB), ($ExpectedByteCount / 1MB), $percent)
                        } else {
                            Write-Progress -Activity $activity -Status ("{0:N1} MB" -f ($total / 1MB))
                        }
                        $next = [datetime]::UtcNow.AddSeconds(2)
                    }
                }
            } finally { $out.Dispose() }
        } finally { $stream.Dispose() }
    } finally {
        $response.Dispose()
        $request.Dispose()
    }
    return (Get-Item -LiteralPath $OutFile).Length
}

function Get-DownloadAgentImageMetadata {
    <#
    .SYNOPSIS
        The agent's catalog entry for one image identity, or $null.
    .DESCRIPTION
        A plain read of GET /api/v1/images/{hostType}/{imageKey}. $null covers
        every "no answer" shape -- the agent knows no entry (404), the family is
        unsupported, the pool share is unmounted (503), the request failed -- so
        a caller branches on $null rather than on HTTP.

        The returned object is the agent's CatalogEntry: upstreamFilename,
        sourceUrl, byteCount, lastModified, sha256, fileUrl, state, and the
        freshness stamps. Callers that need bytes should use
        Request-DownloadAgentImage, which speaks the whole protocol.
    .PARAMETER BaseUrl
        Agent base URL, as Resolve-DownloadAgentEndpoint returns it.
    .PARAMETER HostType
        'ubuntu.kvm' or 'host.ubuntu.kvm' -- either vocabulary.
    .PARAMETER ImageKey
        Pool image key, e.g. 'guest.ubuntu.server.26'.
    .PARAMETER Arch
        'amd64' or 'arm64'.
    .PARAMETER Variant
        'stable' (default) or 'daily'.
    .OUTPUTS
        [psobject] the catalog entry, or $null.
    .EXAMPLE
        Get-DownloadAgentImageMetadata -BaseUrl $agent -HostType (Get-HostType) `
            -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64'
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Metadata is the mass noun for the record, not a collection of metadatums; the name also matches the wire vocabulary the daemon and the design use.')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$BaseUrl,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$ImageKey,
        [Parameter(Mandatory)][ValidateSet('amd64', 'arm64')][string]$Arch,
        [ValidateSet('stable', 'daily')][string]$Variant = 'stable'
    )

    $base = ConvertTo-DownloadAgentBaseUrl -Address $BaseUrl
    $pool = ConvertTo-DownloadAgentHostType -HostType $HostType
    if ($base -eq '' -or $pool -eq '') { return $null }

    $uri = Get-DownloadAgentImageUri -BaseUrl $base -HostType $pool -ImageKey $ImageKey -Arch $Arch -Variant $Variant
    try {
        $response = Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec $script:ApiTimeoutSeconds `
            -SkipCertificateCheck -SkipHttpErrorCheck -ErrorAction Stop
        if ([int]$response.StatusCode -ne 200) {
            Write-Verbose "Get-DownloadAgentImageMetadata: $uri answered HTTP $([int]$response.StatusCode)."
            return $null
        }
        $parsed = $response.Content | ConvertFrom-Json
        if ($null -eq $parsed.image) { return $null }
        return $parsed.image
    } catch {
        Write-Verbose "Get-DownloadAgentImageMetadata: $uri failed: $($_.Exception.Message)"
        return $null
    }
}

function Request-DownloadAgentImage {
    <#
    .SYNOPSIS
        Ask the agent for one image and, when it has bytes the caller lacks,
        fetch and verify them into $StagingPath.
    .DESCRIPTION
        The whole ensure protocol behind one call, answering a plain hashtable a
        Get-Image script can branch on without knowing any HTTP:

            @{ outcome      = 'skipped' | 'downloaded' | 'unavailable' | 'failed'
               filename     = ''   # upstream filename
               sourceUrl    = ''   # origin URL the agent fetched from
               byteCount    = 0    # origin Content-Length
               lastModified = ''   # origin Last-Modified
               sha256       = ''   # the agent's hash of the artifact
               error        = '' }

        The four metadata fields are the origin quadruple Write-ImageSentinel
        needs, so a host that took agent bytes writes the same 4-line sentinel
        it would have written from its own download -- which is what keeps the
        no-agent fallback path coherent on the next run.

        Outcomes:

          skipped      The agent answered localCurrent: what the host already
                       holds IS the current artifact. No bytes move and
                       $StagingPath is not touched. This holds even when the
                       entry is stale and a refresh is running -- a host must
                       never wait on, or re-download after, a refresh of bytes
                       it already has; it picks the new generation up next run.
          downloaded   Bytes are at $StagingPath and their SHA-256 matches the
                       agent's metadata. Claimed only after the hash matches.
          unavailable  No endpoint, unreachable, 404, 503, an unsupported
                       family, or a deadline that expired while the agent was
                       still downloading. The caller falls back to the origin.
          failed       A definite negative verdict: the agent reported a failed
                       download, or the bytes it served did not verify. Same
                       caller action as unavailable -- fall back -- but it names
                       a broken agent rather than an absent one.

        Never throws. A staging file is removed whenever the outcome is not
        'downloaded', so a bogus artifact can never be promoted by a caller that
        only checks for the file.
    .PARAMETER BaseUrl
        Agent base URL from Resolve-DownloadAgentEndpoint. '' yields
        'unavailable'.
    .PARAMETER HostType
        'ubuntu.kvm' or 'host.ubuntu.kvm' -- either vocabulary.
    .PARAMETER ImageKey
        Pool image key, e.g. 'guest.amazon.linux.2023'.
    .PARAMETER Arch
        'amd64' or 'arm64'.
    .PARAMETER Variant
        'stable' (default) or 'daily'.
    .PARAMETER LocalFilename
        Upstream filename the host already holds (sentinel line 1), or ''.
    .PARAMETER LocalByteCount
        Byte count the host already holds (sentinel line 3), or 0.
    .PARAMETER LocalSha256
        Hash the host already holds. Normally '': the 4-line sentinel carries no
        hash, and filename + byte count is exactly the agent's fallback
        comparison.
    .PARAMETER StagingPath
        Where downloaded bytes land. The caller's existing staging file, so the
        promote path that follows is unchanged.
    .PARAMETER DeadlineSeconds
        Wall-clock budget for the whole call, polling included. Defaults to the
        2-hour cold-ISO budget the direct path already allows.
    .OUTPUTS
        [hashtable]
    .EXAMPLE
        $r = Request-DownloadAgentImage -BaseUrl $agent -HostType (Get-HostType) `
            -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64' `
            -LocalFilename $sentinelName -LocalByteCount $sentinelSize `
            -StagingPath $downloadFile
        switch ($r.outcome) {
            'skipped'    { return 'skipped' }
            'downloaded' { Write-ImageSentinel -SourceUrl $r.sourceUrl -OriginFile $origin `
                               -SizeBytes $r.byteCount -LastModified $r.lastModified }
            default      { Write-Warning $r.error }
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$BaseUrl,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$ImageKey,
        [Parameter(Mandatory)][ValidateSet('amd64', 'arm64')][string]$Arch,
        [ValidateSet('stable', 'daily')][string]$Variant = 'stable',
        [AllowEmptyString()][string]$LocalFilename = '',
        [int64]$LocalByteCount = 0,
        [AllowEmptyString()][string]$LocalSha256 = '',
        [Parameter(Mandatory)][string]$StagingPath,
        [int]$DeadlineSeconds = 7200
    )

    $result = @{
        outcome = 'unavailable'; filename = ''; sourceUrl = ''
        byteCount = [int64]0; lastModified = ''; sha256 = ''; error = ''
    }

    $base = ConvertTo-DownloadAgentBaseUrl -Address $BaseUrl
    if ($base -eq '') {
        $result.error = 'no download-agent endpoint'
        return $result
    }
    $pool = ConvertTo-DownloadAgentHostType -HostType $HostType
    if ($pool -eq '') {
        $result.error = "'$HostType' is not a pool host type"
        return $result
    }

    $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(1, $DeadlineSeconds))
    $ensureUri = Get-DownloadAgentImageUri -BaseUrl $base -HostType $pool -ImageKey $ImageKey `
        -Arch $Arch -Variant $Variant -Suffix '/ensure'
    $identity = "$pool/$ImageKey/$Arch/$Variant"

    $image = $null
    $pollSeconds = $script:PollInitialSeconds
    while ($true) {
        $answer = Invoke-DownloadAgentEnsure -Uri $ensureUri -LocalFilename $LocalFilename `
            -LocalByteCount $LocalByteCount -LocalSha256 $LocalSha256
        $status = [int]$answer.Status
        $body = $answer.Body

        if ($status -eq 0) {
            $result.error = "the agent at $base could not be reached: $($answer.Error)"
            return $result
        }
        if ($status -eq 404) {
            $result.error = "the agent serves no $identity (HTTP 404)"
            return $result
        }
        if ($status -ge 500 -or $status -eq 400) {
            $reason = if ($body -and $body.reason) { [string]$body.reason } else { "HTTP $status" }
            $result.error = "the agent refused $identity ($reason)"
            return $result
        }
        if ($null -eq $body) {
            $result.error = "the agent answered HTTP $status with no usable body for $identity"
            return $result
        }

        $state = [string]$body.state
        if ($state -eq 'failed') {
            $result.outcome = 'failed'
            $result.error = if ($body.error) { [string]$body.error } else { "the agent reports a failed download for $identity" }
            return $result
        }
        if ([bool]$body.localCurrent) {
            # Freshness is deliberately not consulted: the skip condition is
            # "what this host holds IS the current artifact", so a stale entry
            # under refresh still skips instead of blocking on work whose result
            # this run would not use anyway.
            $result.outcome = 'skipped'
            Copy-DownloadAgentOriginMetadata -Result $result -Image $body.image
            Write-Verbose "Request-DownloadAgentImage: $identity is already current locally; nothing to transfer."
            return $result
        }
        if ($state -eq 'ready') {
            $image = $body.image
            break
        }
        if ($state -ne 'downloading') {
            $result.error = "the agent answered an unexpected state '$state' for $identity"
            return $result
        }

        $remaining = ($deadline - [datetime]::UtcNow).TotalSeconds
        if ($remaining -le 0) {
            $result.error = "the agent was still downloading $identity after $DeadlineSeconds second(s)"
            return $result
        }
        $done = [int64]$body.bytesDone
        $totalBytes = [int64]$body.bytesTotal
        if ($totalBytes -gt 0) {
            $percent = [Math]::Min(100, [Math]::Round($done * 100.0 / $totalBytes, 1))
            Write-Progress -Activity "Download agent is fetching $identity" -PercentComplete $percent `
                -Status ("{0:N1} / {1:N1} MB ({2}%)" -f ($done / 1MB), ($totalBytes / 1MB), $percent)
        } else {
            Write-Progress -Activity "Download agent is fetching $identity" -Status 'starting'
        }
        Start-Sleep -Seconds ([int][Math]::Min($pollSeconds, [Math]::Max(1, $remaining)))
        $pollSeconds = [Math]::Min($script:PollMaxSeconds, $pollSeconds * 2)
    }
    Write-Progress -Activity "Download agent is fetching $identity" -Completed

    if ($null -eq $image) {
        $result.error = "the agent reported $identity ready but sent no metadata"
        return $result
    }
    Copy-DownloadAgentOriginMetadata -Result $result -Image $image

    $fileUrl = [string]$image.fileUrl
    if ([string]::IsNullOrWhiteSpace($fileUrl)) {
        $result.error = "the agent reported $identity ready but advertised no artifact URL"
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($result.sha256)) {
        # Generation-addressed storage always carries a hash. Without one there
        # is nothing to verify the served bytes against, and unverifiable bytes
        # are not worth taking when the origin path is right there.
        $result.error = "the agent published no SHA-256 for $identity"
        return $result
    }

    # The byte route takes NO query parameters -- every arch/variant of a key
    # shares one directory and the artifact is content-named -- so the
    # advertised fileUrl is used verbatim, not recomposed.
    $byteUri = if ($fileUrl -match '^[A-Za-z][A-Za-z0-9+.-]*://') { $fileUrl } else { "$base$fileUrl" }
    Write-Verbose "Request-DownloadAgentImage: fetching $identity from $byteUri"
    $fetch = Save-DownloadAgentArtifact -Uri $byteUri -OutFile $StagingPath `
        -ExpectedByteCount $result.byteCount -Deadline $deadline
    if (-not $fetch.Ok) {
        Remove-Item -LiteralPath $StagingPath -Force -ErrorAction SilentlyContinue
        $result.error = "fetching $identity from the agent failed: $($fetch.Error)"
        return $result
    }

    $actual = ''
    try { $actual = (Get-FileHash -LiteralPath $StagingPath -Algorithm SHA256).Hash }
    catch { $actual = '' }
    if (-not $actual -or -not $actual.Equals($result.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        # Bytes that do not match the hash the agent published are discarded
        # here rather than left for a caller that only tests for the file's
        # existence to promote.
        Remove-Item -LiteralPath $StagingPath -Force -ErrorAction SilentlyContinue
        $result.outcome = 'failed'
        $result.error = "SHA-256 mismatch for ${identity}: the agent published $($result.sha256), the transfer produced '$actual'"
        return $result
    }

    $result.outcome = 'downloaded'
    return $result
}

function Copy-DownloadAgentOriginMetadata {
    <#
    .SYNOPSIS
        Copy the origin quadruple (plus the hash) out of an agent catalog entry
        into the result hashtable.
    .DESCRIPTION
        One place where the wire field names are read, so the sentinel the
        caller writes and the metadata the agent recorded cannot drift apart in
        two spellings. Mutates $Result in place: a hashtable is a reference.
    .PARAMETER Result
        Result hashtable to fill.
    .PARAMETER Image
        The agent's CatalogEntry, or $null.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Metadata is the mass noun for the record, not a collection of metadatums, and it names the same thing Get-DownloadAgentImageMetadata reads.')]
    param(
        [Parameter(Mandatory)][hashtable]$Result,
        [AllowNull()][psobject]$Image
    )
    if ($null -eq $Image) { return }
    $Result.filename     = [string]$Image.upstreamFilename
    $Result.sourceUrl    = [string]$Image.sourceUrl
    $Result.byteCount    = [int64]$Image.byteCount
    $Result.lastModified = [string]$Image.lastModified
    $Result.sha256       = [string]$Image.sha256
}

# Exactly three functions, all uniquely named. Never Save-CachedHttpUri or
# Test-DownloadAlreadyCurrent: re-exporting either would let this module take
# the command-table slot a driver's cache-injecting wrapper owns.
Export-ModuleMember -Function Resolve-DownloadAgentEndpoint, Get-DownloadAgentImageMetadata, Request-DownloadAgentImage
