<#PSScriptInfo
.VERSION 2026.09.08
.GUID 4276263e-b3ef-4219-b17d-1c87a3cfa238
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host locate dhcp
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

<#
.SYNOPSIS
    Resolve this guest's Yuruna host coordinates, refreshing them when the
    host has moved to a new address.

.DESCRIPTION
    The Windows peer of automation/yuruna-host-locate.sh, and the same
    contract: probe the coordinate this guest already holds, and only when
    it has gone dead ask the pool aggregator on the caching-proxy machine
    where this hostId lives now. Identity is the constant -- the host's
    hostId and the caching proxy's pinned address -- so a host that
    renumbers under DHCP stays reachable without re-provisioning the guest.

    Deliberately NOT a port of the shell library. A Windows guest keeps its
    coordinates in C:\ProgramData\yuruna\host.env rather than /etc/yuruna,
    has no fetch-and-execute bootstrap to hook, and runs its guest scripts
    under Windows PowerShell 5.1, so this file holds to the 5.1 language and
    cmdlet surface throughout.

    That version floor is also why the hosts-file write is implemented here
    rather than delegated to Set-HostAlias.ps1, which does the same job on
    the host side: that script declares `#requires -version 7` and cannot
    load in this context. The removal semantics are kept deliberately
    identical -- LINE-based, so a line mapping the name is dropped whole,
    including any aliases sharing it -- so the two implementations cannot
    drift into disagreeing about what replacing a mapping means.

    Nothing here throws. A guest that cannot resolve is left exactly as it
    was found, and the caller reads the return value.

.PARAMETER HostEnvPath
    The guest's host.env. Defaults to the real path; overridable so a test
    can drive persistence against a fixture.

.PARAMETER HostsFilePath
    The hosts file to maintain the `yuruna-host` alias in. Defaults to the
    real path; overridable for the same reason.

.OUTPUTS
    System.Boolean. True when YURUNA_STATUS_SERVICE_IP / _PORT are set in
    the process environment and known good; false when they could not be
    established, which the caller must treat as "behave as though this
    script did not exist".
#>

# --- REGION: https://yuruna.link/4220a755-002d
[CmdletBinding()]
[OutputType([bool])]
param(
    [Parameter()][string]$HostEnvPath   = 'C:\ProgramData\yuruna\host.env',
    [Parameter()][string]$HostsFilePath = "$env:SystemRoot\System32\drivers\etc\hosts"
)

# --- REGION: https://yuruna.link/4220a755-002e
# Wall-clock caps, in seconds. Backstops for an unreachable peer, not
# normal-path budgets: each is a LAN round trip that completes in
# milliseconds when the peer is up. The livecheck cap is tightest because it
# is paid on every call including the happy path, where it is pure overhead.
$script:ProbeTimeoutSec = 2
$script:QueryTimeoutSec = 3
$script:DirectoryPort   = 9400
$script:MaxResponseBytes = 262144

# How hard to press the directory once the baked coordinate is dead. The
# directory learns the host's new address from the host itself, so a guest
# that starts resolving at the moment of a renumber can be told the address
# that just died -- both ends are racing the same change. Spacing a few
# re-asks over roughly ten seconds covers that gap, against a cycle that
# otherwise ends. The names and defaults are the shell library's, so one
# override drives both peers; a value that is not a whole number is ignored
# rather than raised, because nothing in this file may throw at its caller.
$script:RetryAttempts = 4
$script:RetryDelaySec = 3
if ($env:YURUNA_LOCATE_RETRY_ATTEMPTS -match '^\d+$') { $script:RetryAttempts = [int]$env:YURUNA_LOCATE_RETRY_ATTEMPTS }
if ($env:YURUNA_LOCATE_RETRY_DELAY -match '^\d+$')    { $script:RetryDelaySec = [int]$env:YURUNA_LOCATE_RETRY_DELAY }

# --- REGION: https://yuruna.link/4220a755-002f
function Get-YhlHttpString {
<#
.SYNOPSIS
    Bounded, proxy-free GET returning the response body, or $null.
.DESCRIPTION
    HttpWebRequest rather than Invoke-WebRequest because the proxy must be
    disabled explicitly and Windows PowerShell 5.1 has no -NoProxy: left to
    the default WebProxy, an address lookup would route through squid and be
    served from cache, which is the one response in this framework that must
    never be cached.

    The body is read through a byte cap. The pool view grows with the member
    count, and a bounded read keeps a pathological or hostile body from
    becoming this guest's problem.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][int]$TimeoutSec
    )
    $response = $null
    $stream   = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Uri)
        $request.Method    = 'GET'
        $request.Proxy     = $null
        $request.Timeout   = $TimeoutSec * 1000
        $request.ReadWriteTimeout = $TimeoutSec * 1000
        $response = $request.GetResponse()
        $stream   = $response.GetResponseStream()
        $buffer   = New-Object byte[] $script:MaxResponseBytes
        $read     = 0
        $total    = 0
        do {
            $read = $stream.Read($buffer, $total, $script:MaxResponseBytes - $total)
            $total += $read
        } while ($read -gt 0 -and $total -lt $script:MaxResponseBytes)
        return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $total)
    } catch {
        return $null
    } finally {
        if ($stream)   { $stream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Test-YhlLivecheck {
<#
.SYNOPSIS
    Does a Yuruna status service answer at this base URL? The one question
    that decides everything else in this script.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$BaseUrl)
    $probe = Get-YhlHttpString -Uri "$($BaseUrl.TrimEnd('/'))/livecheck" -TimeoutSec $script:ProbeTimeoutSec
    return ($null -ne $probe)
}

# --- REGION: https://yuruna.link/4220a755-0030
function Test-YhlPlausibleBaseUrl {
<#
.SYNOPSIS
    Refuse an address that is wrong on its face, before spending a probe on
    it.
.DESCRIPTION
    A directory answer is a claim from another machine about where a third
    machine lives. Loopback and link-local are the two forms that would
    resolve locally and appear to work while pointing at nothing -- loopback
    at this guest itself, link-local at whatever answers first on the
    segment.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$BaseUrl)
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { return $false }
    $parsed = $null
    if (-not [System.Uri]::TryCreate($BaseUrl, [System.UriKind]::Absolute, [ref]$parsed)) { return $false }
    if ($parsed.Scheme -notin @('http', 'https')) { return $false }
    $hostName = $parsed.Host
    if ([string]::IsNullOrWhiteSpace($hostName)) { return $false }
    if ($hostName -eq 'localhost' -or $hostName -eq '::1') { return $false }
    if ($hostName -match '^127\.' -or $hostName -eq '0.0.0.0') { return $false }
    if ($hostName -match '^169\.254\.') { return $false }
    if ($hostName -match '^(22[4-9]|23[0-9])\.') { return $false }
    return $true
}

# --- REGION: https://yuruna.link/4220a755-0031
function Get-YhlDirectoryAnswer {
<#
.SYNOPSIS
    Ask the pool aggregator where this hostId is now. Returns the host's
    base URL, or $null.
.DESCRIPTION
    Deliberately NOT /go/host, which answers the same question in one 302
    and is the wrong route for a guest to call: it mints a short-lived
    control proof into the redirect fragment, and a guest holding a control
    proof for its own host is exactly the capability the status service's
    control-route authentication exists to deny. The read routes used here
    mint nothing.

    Two routes tried in order. /api/v1/host-address answers one host in a
    body small enough to parse with certainty. /api/v1/pool-status predates
    it and is the compatibility leg, so a guest carrying this file still
    resolves against an aggregator that has never heard of the narrow route.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$CacheAddress,
        [Parameter(Mandatory)][string]$HostId
    )
    $base = "http://${CacheAddress}:$($script:DirectoryPort)"

    $body = Get-YhlHttpString -Uri "$base/api/v1/host-address?hostId=$HostId" -TimeoutSec $script:QueryTimeoutSec
    if ($body) {
        try {
            $one = $body | ConvertFrom-Json
            if ($one -and $one.baseUrl) { return [string]$one.baseUrl }
        } catch {
            Write-Verbose "host-address answered unparseable JSON; falling back to pool-status."
        }
    }

    $body = Get-YhlHttpString -Uri "$base/api/v1/pool-status" -TimeoutSec $script:QueryTimeoutSec
    if (-not $body) { return $null }
    try {
        $pool = $body | ConvertFrom-Json
    } catch {
        return $null
    }
    if (-not $pool -or -not $pool.hosts) { return $null }
    # Match on hostId, never on position: the pool view is a set, and a
    # single-member lab today is a multi-member lab tomorrow.
    $match = @($pool.hosts | Where-Object { $_.hostId -eq $HostId }) | Select-Object -First 1
    if ($match -and $match.baseUrl) { return [string]$match.baseUrl }
    return $null
}

# --- REGION: https://yuruna.link/4220a755-0032
function Set-YhlHostsAlias {
<#
.SYNOPSIS
    Upsert '<ip> yuruna-host' in the hosts file, idempotently.
.DESCRIPTION
    Line-based removal, matching Set-HostAlias on the host side (see this
    script's .DESCRIPTION for why the logic is duplicated rather than
    called). Comment and blank lines are preserved verbatim.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$IPAddress
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    if (-not $PSCmdlet.ShouldProcess($Path, "Map yuruna-host to $IPAddress")) { return }
    try {
        $kept = @(Get-Content -LiteralPath $Path -ErrorAction Stop |
            Where-Object { $_ -match '^\s*#' -or $_ -notmatch '(^|\s)yuruna-host(\s|$)' })
        Set-Content -LiteralPath $Path -Value ($kept + "$IPAddress`tyuruna-host") -ErrorAction Stop
    } catch {
        # A hosts file this guest may not write is not a reason to fail the
        # resolve: the in-process coordinates are already correct and are
        # what unblocks the caller.
        Write-Verbose "yuruna-host-locate: could not update '$Path' -- $($_.Exception.Message)"
    }
}

function Set-YhlHostEnvAddress {
<#
.SYNOPSIS
    Rewrite the address and port lines in host.env, leaving everything else
    the file carries (repo, ref, hostId, cache address) untouched.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][string]$Port
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    if (-not $PSCmdlet.ShouldProcess($Path, "Set host coordinates to ${IPAddress}:$Port")) { return }
    try {
        $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop | ForEach-Object {
            if ($_ -match '^\s*YURUNA_STATUS_SERVICE_IP\s*=') {
                "YURUNA_STATUS_SERVICE_IP=$IPAddress"
            } elseif ($_ -match '^\s*YURUNA_STATUS_SERVICE_PORT\s*=') {
                "YURUNA_STATUS_SERVICE_PORT=$Port"
            } else {
                $_
            }
        })
        Set-Content -LiteralPath $Path -Value $lines -ErrorAction Stop
    } catch {
        Write-Verbose "yuruna-host-locate: could not update '$Path' -- $($_.Exception.Message)"
    }
}

# --- REGION: https://yuruna.link/4220a755-0033
function Invoke-YurunaHostLocate {
<#
.SYNOPSIS
    Resolve this guest's host coordinates, refreshing them if stale.
.DESCRIPTION
    Probe-first ordering is what keeps this affordable. On the
    overwhelmingly common path the seeded coordinate is still correct, the
    directory is never consulted, nothing is written, and the whole call
    costs one LAN round trip -- which is why it is safe in front of every
    fetch and on a one-minute schedule.
.OUTPUTS
    System.Boolean
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$HostEnvPath,
        [Parameter(Mandatory)][string]$HostsFilePath
    )

    # host.env is the seeded record; load it into the process environment
    # the same way the guest update scripts do, so this script and they
    # agree on what the coordinates are.
    $coords = @{}
    if (Test-Path -LiteralPath $HostEnvPath -PathType Leaf) {
        Get-Content -LiteralPath $HostEnvPath | ForEach-Object {
            if ($_ -match '^\s*([A-Z0-9_]+)\s*=\s*"?([^"]*)"?\s*$') {
                $coords[$Matches[1]] = $Matches[2]
                Set-Item -Path "env:$($Matches[1])" -Value $Matches[2]
            }
        }
    }

    $currentIp   = $env:YURUNA_STATUS_SERVICE_IP
    $currentPort = $env:YURUNA_STATUS_SERVICE_PORT
    if ($currentIp -and $currentPort) {
        if (Test-YhlLivecheck -BaseUrl "http://${currentIp}:$currentPort") { return $true }
    }

    # Both coordinates of the indirection are required. A guest imaged
    # before this script existed carries neither, and a lab with no
    # caching-proxy machine has no directory to ask -- in both cases the
    # honest answer is that this guest cannot re-resolve.
    $hostId = $coords['YURUNA_HOST_ID']
    $cache  = $coords['YURUNA_CACHING_PROXY_SERVICE_IP']
    if ([string]::IsNullOrWhiteSpace($hostId) -or [string]::IsNullOrWhiteSpace($cache)) { return $false }

    # The directory learns a new address from the host, so asking the instant
    # the host renumbers returns the address that just died -- the guest and
    # the directory are racing the same change. One shot loses that race and
    # sends the caller to a fallback that cannot help it. Re-ask a few times
    # instead, spaced so the directory has time to catch up. This costs
    # nothing on the common path: the baked coordinate answered its livecheck
    # above and returned before reaching here, so the only callers that pay
    # are the ones already out of other options.
    $answer = $null
    for ($attempt = 1; $attempt -le $script:RetryAttempts; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Seconds $script:RetryDelaySec }
        $candidate = Get-YhlDirectoryAnswer -CacheAddress $cache -HostId $hostId
        if (-not (Test-YhlPlausibleBaseUrl -BaseUrl $candidate)) { continue }
        # The directory reports where IT reached the host. This guest may sit on
        # a different segment, so the answer is confirmed from here before it is
        # adopted -- an address that does not serve this guest is not an
        # improvement on the stale one it would replace. A stale answer fails
        # this check too, which is what makes re-asking worthwhile.
        if (Test-YhlLivecheck -BaseUrl $candidate) { $answer = $candidate; break }
    }
    if ([string]::IsNullOrWhiteSpace($answer)) { return $false }

    $uri  = [System.Uri]$answer
    $ip   = $uri.Host
    $port = if ($uri.IsDefaultPort) { '80' } else { [string]$uri.Port }

    Write-Verbose "yuruna-host-locate: host moved to ${ip}:$port (was ${currentIp}:$currentPort), resolved via $cache"
    Set-YhlHostEnvAddress -Path $HostEnvPath -IPAddress $ip -Port $port
    Set-YhlHostsAlias -Path $HostsFilePath -IPAddress $ip

    $env:YURUNA_STATUS_SERVICE_IP   = $ip
    $env:YURUNA_STATUS_SERVICE_PORT = $port
    return $true
}

# Dot-sourced, this file only defines the functions -- which is what a guest
# script needs when it wants to call the resolver at a point of its own
# choosing. Run directly, it resolves once and reports: the scheduled-task
# entry point.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-YurunaHostLocate -HostEnvPath $HostEnvPath -HostsFilePath $HostsFilePath
}
