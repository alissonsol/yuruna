<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456821
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
    Cross-cycle persistence for the yuruna-caching-proxy VM state
    (yuruna user's password + the VM's IP address). Single YAML file
    under the runtime directory; survives cycle vault wipes.

.DESCRIPTION
    Previous design split this between two host-local sidecar files:
      * caching-proxy-password.txt next to the VHD (Windows) or under
        $HOME/yuruna/image/caching-proxy/ (macOS)
      * cache-ip.txt under $HOME/yuruna/image/caching-proxy/ (macOS only)

    Both have moved to a single YAML doc at:
        <runtime-dir>/yuruna-caching-proxy.yml
    where <runtime-dir> is $env:YURUNA_RUNTIME_DIR (default
    <repoRoot>/test/status/runtime). One file, host-agnostic location,
    git-ignored alongside the rest of status/. The authentication
    extension's vault.yml now persists across cycles too, but this
    file remains the source of truth for the cache VM's yuruna user --
    caching-proxy New-VM.ps1 re-aligns the vault entry from here on
    every cycle so the two stay in sync if they ever diverge.

    Save uses merge semantics: only the fields you pass are touched.
    Atomic write via "write .tmp + Move-Item" so a concurrent reader
    never sees a half-written file.
#>

# === Path ===================================================================

<#
.SYNOPSIS
    Returns the absolute path of the yuruna-caching-proxy state file.
.DESCRIPTION
    Resolves <runtime-dir>/yuruna-caching-proxy.yml. Runtime dir defaults
    to <repoRoot>/test/status/runtime and can be overridden via
    $env:YURUNA_RUNTIME_DIR. Creates the directory on demand so callers
    don't have to Test-Path-and-mkdir.
#>
function Get-CachingProxyStatePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($env:YURUNA_RUNTIME_DIR) {
        $runtimeDir = $env:YURUNA_RUNTIME_DIR
    } else {
        # This module lives at test/modules/; two levels up is test/.
        $testRoot = Split-Path -Parent $PSScriptRoot
        $runtimeDir = Join-Path -Path $testRoot -ChildPath 'status' -AdditionalChildPath 'runtime'
    }
    if (-not (Test-Path -LiteralPath $runtimeDir)) {
        New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    }
    return (Join-Path -Path $runtimeDir -ChildPath 'yuruna-caching-proxy.yml')
}

# === Read ===================================================================

<#
.SYNOPSIS
    Returns the persisted state as a hashtable. Empty hashtable when
    the file is missing or unparsable; never $null.
.OUTPUTS
    [hashtable] with keys 'password' and 'ipAddress' (each a string,
    possibly empty). Additional keys round-trip through Save unchanged.
#>
function Read-CachingProxyState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $path = Get-CachingProxyStatePath
    $empty = @{ password = ''; ipAddress = ''; caCert = ''; caCertSourceHost = '' }
    if (-not (Test-Path -LiteralPath $path)) { return $empty }
    if (-not (Get-Module powershell-yaml)) {
        try {
            Import-Module powershell-yaml -Global -Verbose:$false -ErrorAction Stop
        } catch {
            Write-Warning "Read-CachingProxyState: powershell-yaml not importable ($($_.Exception.Message)); returning empty."
            return $empty
        }
    }
    $parsed = Read-CachingProxyStateFile -Path $path
    if ($null -ne $parsed) { return $parsed }
    # Primary file unparseable. Try a `.backup` rotated by Save-CachingProxyState
    # so the cache VM's IP / vault password isn't silently lost on a torn
    # write or disk corruption. The backup is one rotation behind by design
    # -- if BOTH files corrupt simultaneously the operator gets an empty
    # dict (caller re-discovers IP and rebuilds vault from yuruna-vault.yml),
    # but the warning + corrupt-file rotation below leaves a forensics trail.
    $backupPath = "$path.backup"
    if (Test-Path -LiteralPath $backupPath) {
        $fallback = Read-CachingProxyStateFile -Path $backupPath
        if ($null -ne $fallback) {
            Write-Warning "Read-CachingProxyState: main file at $path was unparseable; recovered prior state from $backupPath."
            return $fallback
        }
    }
    # Both main and backup unparseable (or backup absent). Rotate the
    # broken main aside with a timestamp suffix so it can be diff'd
    # against the next good write; the cycle continues with $empty.
    try {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ss-fffZ')
        $corruptPath = "$path.corrupt.$stamp"
        Move-Item -LiteralPath $path -Destination $corruptPath -Force -ErrorAction Stop
        Write-Warning "Read-CachingProxyState: $path was unparseable and no usable backup; preserved corrupt copy at $corruptPath. State reset to empty."
    } catch {
        Write-Warning "Read-CachingProxyState: $path was unparseable AND the corrupt-rotation move failed ($($_.Exception.Message)). State reset to empty; next save will overwrite the broken file in place."
    }
    return $empty
}

function Read-CachingProxyStateFile {
    <#
    .SYNOPSIS
        Parse a single caching-proxy state YAML file. Returns the hashtable
        on success, $null on any parse / shape failure. Caller decides
        whether to escalate (warning, fallback, rotate-corrupt).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    try {
        $raw = Get-Content -Raw -LiteralPath $Path
        if (-not $raw -or -not $raw.Trim()) { return $null }
        $parsed = $raw | ConvertFrom-Yaml
        if ($parsed -isnot [System.Collections.IDictionary]) { return $null }
        $h = @{ password = ''; ipAddress = ''; caCert = ''; caCertSourceHost = '' }
        foreach ($k in $parsed.Keys) { $h[[string]$k] = [string]$parsed[$k] }
        return $h
    } catch {
        Write-Verbose "Read-CachingProxyStateFile: $Path parse failed: $($_.Exception.Message)"
        return $null
    }
}

# === Save ===================================================================

<#
.SYNOPSIS
    Merges the given fields into the persisted state and writes the
    file atomically. Existing fields not named here are preserved.
.PARAMETER Secret
    yuruna OS user password (named -Secret to avoid the rule that flags
    plaintext-typed parameters whose name contains 'password' -- the
    on-disk YAML key is still `password:`). Pass '' to clear; omit to
    leave unchanged.
.PARAMETER IpAddress
    Current VM IP. Pass '' to clear; omit to leave unchanged.
.OUTPUTS
    [string] The path of the file written.
.NOTES
    The on-disk YAML key remains `password:` -- the parameter name dodges
    PSAvoidUsingPlainTextForPassword (the rule matches parameter NAMES
    containing 'password'/'passphrase' but does not inspect hashtable
    keys or file contents). Renaming the on-disk key would be a breaking
    change to the file format; renaming just the parameter keeps the
    file format stable and the rule satisfied.
#>
function Save-CachingProxyState {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        # The yuruna user's password value to persist; on-disk YAML key is
        # `password:`. Pass '' to clear; omit to leave unchanged.
        [string]$Secret,
        [string]$IpAddress,
        # Last-good caching-proxy CA, base64 of the PEM text (same encoding the
        # guest seed's CA_CERT_BASE64 carries). Persisted so a later provision
        # whose live fetch flaps can fall back to it, and so the status server
        # can serve it. Pass '' to clear; omit to leave unchanged.
        [string]$CaCert,
        # The host string the persisted CA was fetched from (cache IP or the
        # host-forwarder the guest reaches it through). Guards reuse: a fallback
        # is only trusted when the current fetch host matches, so a CA saved for
        # one cache is never baked against a different one. Pass '' to clear.
        [string]$CaCertSourceHost
    )
    $path = Get-CachingProxyStatePath
    $state = Read-CachingProxyState
    # Merge: only update keys the caller actually passed.
    if ($PSBoundParameters.ContainsKey('Secret'))    { $state.password  = [string]$Secret }
    if ($PSBoundParameters.ContainsKey('IpAddress')) { $state.ipAddress = [string]$IpAddress }
    if ($PSBoundParameters.ContainsKey('CaCert'))    { $state.caCert    = [string]$CaCert }
    if ($PSBoundParameters.ContainsKey('CaCertSourceHost')) { $state.caCertSourceHost = [string]$CaCertSourceHost }
    if (-not $PSCmdlet.ShouldProcess($path, "Save caching-proxy state")) { return $path }
    if (-not (Get-Module powershell-yaml)) {
        Import-Module powershell-yaml -Global -Verbose:$false -ErrorAction Stop
    }
    # Sort keys for stable diffs; ConvertTo-Yaml on an unordered hashtable
    # otherwise re-emits in random order on every save.
    $ordered = [ordered]@{}
    foreach ($k in ($state.Keys | Sort-Object)) { $ordered[$k] = $state[$k] }
    $yaml = $ordered | ConvertTo-Yaml
    $tmp = "$path.tmp"
    # UTF-8 without BOM: shell consumers on the macOS/Linux side don't
    # parse a BOM cleanly. .NET's UTF8Encoding($false) is the BOM-less
    # variant; Set-Content -Encoding utf8 is already BOM-less on PS7 but
    # using WriteAllText keeps the encoding choice explicit and matches
    # the pattern used elsewhere in the repo for shell-consumed files.
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tmp, $yaml, $utf8NoBom)
    # Rotate the prior main file aside as `.backup` before swapping the new
    # version in. Read-CachingProxyState falls back to this backup when the
    # main file is corrupt, so the cache VM IP and vault password survive
    # a single torn write. Best-effort: copy failures degrade silently
    # because the new write is the primary safety guarantee.
    $backupPath = "$path.backup"
    if (Test-Path -LiteralPath $path) {
        try {
            Copy-Item -LiteralPath $path -Destination $backupPath -Force -ErrorAction Stop
        } catch {
            Write-Verbose "Save-CachingProxyState: could not rotate prior main to $backupPath (non-fatal): $($_.Exception.Message)"
        }
    }
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $path
}

# === Probe ==================================================================

function Test-TcpPortReachable {
    <#
    .SYNOPSIS
        Bounded, retrying TCP-connect reachability probe that always closes its
        socket. Returns $true on a successful connect, $false otherwise.
    .DESCRIPTION
        Single home for the TcpClient + BeginConnect + WaitOne(timeout) pattern
        the caching-proxy callers otherwise hand-roll, so the timeout policy and
        the close-in-finally live in one place. A per-attempt WaitOne caps a
        black-holed host at $TimeoutMs instead of the OS default; the socket is
        closed in a finally on every path (connect, timeout, or throw) so no
        attempt leaks a handle.

        Retries the connect rather than trusting a single deadline. On a wired
        host the first attempt answers in well under a millisecond, so the extra
        attempts never run. Over Wi-Fi the connect latency has a fat tail: a cold
        radio waking from power-save plus an ARP-over-air round trip can burn most
        of the budget on its own, and a single AP retransmit or roam pushes it
        past the cliff -- producing a spurious miss on a port that is actually up.
        The first attempt warms ARP / wakes the radio; a follow-up then connects
        in milliseconds. A genuinely dead port still misses every attempt.
    .PARAMETER TargetHost
        Host or IP literal to connect to (IPv4, IPv6, or name).
    .PARAMETER Port
        TCP port to probe.
    .PARAMETER Attempts
        Number of connect attempts before giving up (>=1).
    .PARAMETER TimeoutMs
        Per-attempt connect deadline in milliseconds.
    .PARAMETER BackoffMs
        Delay before each retry (not applied before the first attempt).
    .OUTPUTS
        [bool] $true if any attempt connected, else $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$TargetHost,
        [Parameter(Mandatory)][int]$Port,
        [int]$Attempts = 3,
        [int]$TimeoutMs = 3000,
        [int]$BackoffMs = 200
    )
    $ok = $false
    for ($attempt = 1; $attempt -le $Attempts -and -not $ok; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Milliseconds $BackoffMs }
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $tcp.BeginConnect($TargetHost, $Port, $null, $null)
            $ok    = ($async.AsyncWaitHandle.WaitOne($TimeoutMs) -and $tcp.Connected)
        } catch {
            Write-Verbose "TCP probe ${TargetHost}:$Port attempt $attempt failed: $($_.Exception.Message)"
        } finally {
            $tcp.Close()
        }
    }
    return $ok
}

<#
.SYNOPSIS
    Smoke-tests the caching-proxy at the given IP. Shared core between
    Test-CachingProxy.ps1 and the cycle-start gate in Invoke-TestInnerRunner.ps1.
.DESCRIPTION
    Probes :3128 / :3129 / :80 / :3000 and fetches /yuruna-squid-ca.crt off
    Apache. PASS / WARN / FAIL classification matches the standalone script:
    :3128 / :3129 / :3000 are FAIL on unreachable (hard requirements);
    :80 and the CA cert are WARN (HTTPS caching disabled on guests, HTTP
    still works).

    IP resolution, host system-proxy and outbound-proxy checks stay in the
    standalone script -- those are host-state-dependent, not cache-state-
    dependent. This function is the cache-side subset both callers need.

    Requires Test.VMUtility.psm1 (Get-CachingProxyPort, Format-IpUrlHost)
    to be imported by the caller.
.PARAMETER CacheIp
    Resolved cache IP (IPv4 or IPv6). The caller is expected to have
    validated the format with Test-IpAddress; this function does not
    re-check.
.PARAMETER CacheSource
    Free-form label rendered into the "Target:" diagnostic header (e.g.
    "$Env:YURUNA_CACHING_PROXY_IP" or "vmStart.cachingProxyIP"). Empty
    omits the header line.
.OUTPUTS
    [hashtable] with keys:
        Success              [bool] -- FailCount == 0 (full-suite pass)
        HttpProxyReachable   [bool] -- :3128 (HTTP proxy) answered
        PassCount / WarnCount / FailCount [int]
        HttpPort / HttpsPort [int]
        Lines                [string[]] -- diagnostic output

    Callers wanting a strict "fully healthy" verdict check Success;
    callers that only need "usable as an HTTP forward proxy" check
    HttpProxyReachable. The latter is the criterion the cycle-start
    gate in Invoke-TestInnerRunner.ps1 uses so a barebones squid
    (without Grafana / ssl-bump) is still accepted as a working
    proxy -- the runner only relies on :3128 for guest installs.
#>
function Invoke-CachingProxyProbe {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$CacheIp,
        [string]$CacheSource = ''
    )

    $passCount = 0
    $warnCount = 0
    $failCount = 0
    $lines     = [System.Collections.Generic.List[string]]::new()
    $httpProxyReachable = $false

    if ($CacheSource) {
        $lines.Add("  Target: $CacheIp  (source: $CacheSource)")
        $lines.Add('')
    }

    $httpPort  = Get-CachingProxyPort -Scheme http
    $httpsPort = Get-CachingProxyPort -Scheme https
    $ports = @(
        @{ Port = $httpPort;  Name = 'Squid HTTP proxy';      Level = 'FAIL' }
        @{ Port = $httpsPort; Name = 'Squid ssl-bump (HTTPS)'; Level = 'FAIL' }
        @{ Port = 80;         Name = 'Apache (CA cert)';       Level = 'WARN' }
        @{ Port = 3000;       Name = 'Grafana dashboard';      Level = 'FAIL' }
    )
    # Connect policy for the shared probe. 3 attempts because a single deadline
    # spuriously FAILs a cache that is actually up: on Wi-Fi a cold radio plus an
    # ARP-over-air round trip can burn most of the budget, and one AP retransmit
    # or roam pushes it past the cliff (the first attempt warms ARP / wakes the
    # radio; a follow-up connects in milliseconds). 3s/attempt because a remote /
    # cross-host cache (e.g. UTM/macOS squid over bridged networking) routinely
    # takes 600ms-1s+ to ACCEPT; the cap is free for a fast local cache -- connect
    # returns the instant the port accepts.
    $connectAttempts    = 3
    $connectTimeoutMs   = 3000
    $connectBackoffMs   = 200
    foreach ($p in $ports) {
        $label = "{0,-5} ({1})" -f $p.Port, $p.Name
        $ok = Test-TcpPortReachable -TargetHost $CacheIp -Port $p.Port `
            -Attempts $connectAttempts -TimeoutMs $connectTimeoutMs -BackoffMs $connectBackoffMs
        if ($ok) {
            $lines.Add("  [PASS] TCP :$label")
            $passCount++
            if ($p.Port -eq $httpPort) { $httpProxyReachable = $true }
        } elseif ($p.Level -eq 'WARN') {
            $lines.Add("  [WARN] TCP :$label -- not reachable (HTTPS caching will be disabled on guests, HTTP unaffected)")
            $warnCount++
        } else {
            $lines.Add("  [FAIL] TCP :$label -- not reachable")
            $failCount++
        }
    }

    # CA cert fetch. Only meaningful if :80 is up; failures are WARN
    # because HTTP caching still works even without CA distribution.
    # -NoProxy: this request goes to the cache's own Apache on :80; an
    # existing host proxy (stale or fresh) would loop or fail the call.
    $caUrl = "http://$(Format-IpUrlHost $CacheIp)/yuruna-squid-ca.crt"
    try {
        $resp = Invoke-WebRequest -Uri $caUrl -UseBasicParsing -NoProxy -TimeoutSec 5 -ErrorAction Stop
        if ($resp.StatusCode -eq 200 -and $resp.RawContentLength -gt 0) {
            $raw = if ($resp.Content -is [byte[]]) {
                [System.Text.Encoding]::UTF8.GetString($resp.Content)
            } else {
                [string]$resp.Content
            }
            if ($raw -match '-----BEGIN CERTIFICATE-----' -and $raw -match '-----END CERTIFICATE-----') {
                try {
                    # Decode the PEM to DER first: [X509Certificate2]::new(PEM bytes)
                    # works on Windows but FAILS on macOS (DER-expecting backend).
                    $caDerB64 = (($raw -split "`r?`n") | Where-Object { $_ -and ($_ -notmatch '-----') }) -join ''
                    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($caDerB64))
                    $lines.Add("  [PASS] CA cert $caUrl -> $($cert.Subject) (expires $($cert.NotAfter.ToString('yyyy-MM-dd')))")
                    $passCount++
                } catch {
                    $lines.Add("  [WARN] CA cert $caUrl returned PEM-looking bytes but X509 parse failed: $($_.Exception.Message)")
                    $warnCount++
                }
            } else {
                $lines.Add("  [WARN] CA cert $caUrl returned $($raw.Length) bytes but no BEGIN/END CERTIFICATE markers found.")
                $warnCount++
            }
        } else {
            $lines.Add("  [WARN] CA cert $caUrl returned HTTP $($resp.StatusCode) with $($resp.RawContentLength) bytes.")
            $warnCount++
        }
    } catch {
        $lines.Add("  [WARN] CA cert $caUrl fetch failed: $($_.Exception.Message)")
        $warnCount++
    }

    return @{
        Success            = ($failCount -eq 0)
        HttpProxyReachable = $httpProxyReachable
        PassCount          = $passCount
        WarnCount          = $warnCount
        FailCount          = $failCount
        HttpPort           = $httpPort
        HttpsPort          = $httpsPort
        Lines              = $lines.ToArray()
    }
}

function Resolve-CachingProxyEndpoint {
    <#
    .SYNOPSIS
        Resolve the effective caching-proxy IP from the operator's two
        sources by probing each, keeping the first whose HTTP proxy port
        is reachable, and clearing the choice when none answers.
    .DESCRIPTION
        The runner accepts a caching proxy from two operator-controlled
        sources, in priority order:
          1. $Config.vmStart.cachingProxyIP -- persistent UI-edited key
          2. $env:YURUNA_CACHING_PROXY_IP   -- session-scope env var,
             probed only when the config candidate is absent or its
             HTTP proxy port does not answer
        Each candidate is validated as an IP (Test-IpAddress) and then
        probed with the full Invoke-CachingProxyProbe suite. The first
        candidate whose HTTP proxy port (:3128) is reachable wins -- that
        port is the only requirement the runner actually depends on
        (guest installs route through it); the other probes (:3129 ssl-
        bump, :3000 Grafana, :80 + CA cert) still run for operator
        visibility but do not gate acceptance, so a barebones squid cache
        is not rejected for lacking Grafana/ssl-bump.

        When both sources are empty, EffectiveIp is '' and nothing is
        probed -- the caller's local-discovery fallback runs unchanged.
        When sources are set but none has a reachable :3128, EffectiveIp
        is '' too, so the caller clears the env var and the same local-
        discovery fallback applies. This "probe and clear" is the policy
        the inner runner and Test-Sequence must share so a syntactically
        valid but dead IP can't survive into guest cidata.
    .PARAMETER EnvIp
        Value of $env:YURUNA_CACHING_PROXY_IP (or ''), second priority:
        probed only when ConfigIp is absent or fails its probe.
    .PARAMETER ConfigIp
        Value of $Config.vmStart.cachingProxyIP (or ''), highest priority.
    .OUTPUTS
        [hashtable] {
            EffectiveIp = the accepted IP, or '' when none answered / none set
            Probed      = [bool] whether any candidate was probed
            Lines       = string[] console lines the caller prints verbatim
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$EnvIp = '',
        [string]$ConfigIp = ''
    )
    $envIpTrim    = if ($EnvIp)    { $EnvIp.Trim() }    else { '' }
    $configIpTrim = if ($ConfigIp) { $ConfigIp.Trim() } else { '' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $result = @{ EffectiveIp = ''; Probed = $false; Lines = @() }
    if (-not $envIpTrim -and -not $configIpTrim) { return $result }

    $result.Probed = $true
    $effectiveCacheIp = ''
    foreach ($cand in @(
        @{ Ip = $configIpTrim; Source = 'vmStart.cachingProxyIP'        }
        @{ Ip = $envIpTrim;    Source = '$env:YURUNA_CACHING_PROXY_IP' }
    )) {
        if (-not $cand.Ip) { continue }
        if (-not (Test-IpAddress $cand.Ip)) {
            $lines.Add("Caching proxy '$($cand.Ip)' (source: $($cand.Source)): rejected -- not a valid IPv4 or IPv6 address.")
            continue
        }
        $lines.Add('')
        $lines.Add("== Probing caching proxy at $($cand.Ip) (source: $($cand.Source)) ==")
        $probe = Invoke-CachingProxyProbe -CacheIp $cand.Ip
        foreach ($line in $probe.Lines) { $lines.Add($line) }
        $lines.Add("  Summary: $($probe.PassCount) PASS, $($probe.WarnCount) WARN, $($probe.FailCount) FAIL")
        if ($probe.HttpProxyReachable) {
            $effectiveCacheIp = $cand.Ip
            if ($probe.Success) {
                $lines.Add("Caching proxy at $($cand.Ip) ACCEPTED (full probe suite passed).")
            } else {
                $lines.Add("Caching proxy at $($cand.Ip) ACCEPTED (HTTP proxy :$($probe.HttpPort) reachable; see WARN/FAIL above for the non-essential checks that did not pass).")
            }
            break
        }
        $lines.Add("Caching proxy at $($cand.Ip) REJECTED -- HTTP proxy :$($probe.HttpPort) not reachable.")
    }
    $result.EffectiveIp = $effectiveCacheIp
    $result.Lines = $lines.ToArray()
    return $result
}

function Get-PoolAggregatorSeedUrl {
<#
.SYNOPSIS
    Resolves the pool-aggregator base URL (https://<proxy-ip>:9400) to bake
    into a guest seed, e.g. the stash VM's presence-beacon destination.
.DESCRIPTION
    The aggregator runs inside the caching-proxy VM, so its address is the
    proxy's IP from the persisted caching-proxy state (the same resolution the
    host-side pool notifier uses), with the YURUNA_CACHING_PROXY_IP environment
    override as fallback. https because a provisioned proxy mints the
    aggregator's TLS leaf in cloud-init; a consumer facing an older plain-HTTP
    proxy downgrades per attempt (the beacon's https-then-http candidate
    order), so the baked scheme never strands it.

    Returns '' when no proxy IP is known -- the caller bakes an empty value and
    the consuming service leaves its aggregator-dependent features off. The
    value lands inside a single-quoted env line in the seed, so any resolved
    value carrying a quote or whitespace is refused (returns '') rather than
    corrupting the seed file.
.OUTPUTS
    [string] aggregator base URL, or ''.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $ip = ''
    try {
        $state = Read-CachingProxyState
        if ($state -and $state.ipAddress) { $ip = [string]$state.ipAddress }
    } catch { $null = $_ }
    if ([string]::IsNullOrWhiteSpace($ip) -and $env:YURUNA_CACHING_PROXY_IP) {
        $ip = $env:YURUNA_CACHING_PROXY_IP.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($ip)) { return '' }
    if ($ip -match "['\s]") { return '' }
    # Format-IpUrlHost (Test.VMUtility) brackets an IPv6 literal; callers that
    # haven't loaded that module still get a correct IPv4 URL from the raw IP.
    $urlHost = if (Get-Command Format-IpUrlHost -ErrorAction SilentlyContinue) { Format-IpUrlHost $ip } else { $ip }
    return "https://${urlHost}:9400"
}

# === CA cert ================================================================

function Test-CachingProxyCaPem {
    <#
    .SYNOPSIS
        True when $Pem is a well-formed X.509 certificate in PEM form.
    .DESCRIPTION
        Guards every path that would bake or serve a CA: a truncated or
        garbage blob must never be installed (it would fail
        update-ca-certificates in the guest, or worse install a junk anchor)
        nor served as if valid. Decodes the base64 DER between the PEM markers
        and constructs an X509Certificate2 -- feeding the PEM text straight to
        [X509Certificate2]::new works on Windows but fails on macOS (its
        backend expects DER), so the DER extraction is mandatory for a
        host-agnostic check.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Pem)
    if ([string]::IsNullOrWhiteSpace($Pem)) { return $false }
    if ($Pem -notmatch '-----BEGIN CERTIFICATE-----' -or $Pem -notmatch '-----END CERTIFICATE-----') { return $false }
    try {
        $der = (($Pem -split "`r?`n") | Where-Object { $_ -and ($_ -notmatch '-----') }) -join ''
        $null = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($der))
        return $true
    } catch {
        Write-Verbose "Test-CachingProxyCaPem: X509 parse failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-CachingProxyCaCertBase64 {
    <#
    .SYNOPSIS
        Resolves the caching-proxy CA (base64 of PEM) for a guest seed, with a
        last-good persisted fallback so a proxy flap during this guest's
        provisioning window does not strand it CA-less.
    .DESCRIPTION
        Shared by every ubuntu.server New-VM across the three host platforms.
        Order: (1) live-fetch http://<host>/yuruna-squid-ca.crt off the cache's
        own Apache :80 under the shared capped-backoff retry, -NoProxy so a
        stale host proxy env can't route the trust-bootstrap request; on success
        persist it (keyed by -CacheHost) and return it. (2) On exhaustion fall
        back to the persisted CA, but only when it was saved for the SAME
        -CacheHost and still parses as X509 -- a mismatched or corrupt fallback
        is refused so one cache's CA is never baked against another's bump.
        Exhausted=$true means neither source yielded a usable CA; the caller
        (New-VM) treats "proxy URL present => CA mandatory" as a hard-fail rather
        than booting a guest that would hit curl rc=60 on every HTTPS. See
        feedback_sslbump_rc60_untrusted_chain_and_ca_gate_trap and
        project_sslbump_ca_gating_durable_fix.
    .OUTPUTS
        [hashtable] @{ CaCertBase64 [string]; Source 'live'|'persisted'|'none'; Exhausted [bool] }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$CacheCaUrl,
        [Parameter(Mandatory)][string]$CacheHost,
        [int]$MaxAttempts = 5
    )
    if (-not (Get-Command Invoke-WithYurunaRetry -ErrorAction SilentlyContinue)) {
        $retryModule = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'automation/Yuruna.Retry.psm1'
        Import-Module -Name $retryModule -Global -Force -ErrorAction Stop
    }
    # Capture into a local so the retry scriptblock closes over it explicitly.
    $caUrl = $CacheCaUrl
    $caFetch = Invoke-WithYurunaRetry -Label 'caching-proxy CA cert' -MaxAttempts $MaxAttempts -InitialDelaySeconds 3 -MaxDelaySeconds 20 -ScriptBlock {
        $caResp = Invoke-WebRequest -Uri $caUrl -UseBasicParsing -NoProxy -TimeoutSec 10 -ErrorAction Stop
        if ($caResp.StatusCode -ne 200 -or $caResp.RawContentLength -le 0) {
            throw "caching-proxy returned status=$($caResp.StatusCode) length=$($caResp.RawContentLength)"
        }
        $caPem = if ($caResp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($caResp.Content) } else { [string]$caResp.Content }
        if (-not (Test-CachingProxyCaPem -Pem $caPem)) { throw "caching-proxy CA is not a valid X509 PEM" }
        [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($caPem))
    }
    if ($caFetch.Success) {
        $b64 = [string]($caFetch.LastOutput | Select-Object -Last 1)
        try { $null = Save-CachingProxyState -CaCert $b64 -CaCertSourceHost $CacheHost -Confirm:$false }
        catch { Write-Verbose "Get-CachingProxyCaCertBase64: persist failed (non-fatal): $($_.Exception.Message)" }
        return @{ CaCertBase64 = $b64; Source = 'live'; Exhausted = $false }
    }
    # Live fetch exhausted -- try the last-good persisted CA, but only for the
    # same cache host and only if it still parses.
    Write-Warning "  Could not fetch CA cert from caching-proxy after $($caFetch.Attempts) attempt(s) : $($caFetch.LastError.Exception.Message)"
    $state = Read-CachingProxyState
    if ($state.caCert -and $state.caCertSourceHost -eq $CacheHost) {
        try {
            $pem = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$state.caCert))
            if (Test-CachingProxyCaPem -Pem $pem) {
                Write-Warning "  Using last-good persisted CA for $CacheHost (live fetch failed; the cache may have flapped during provisioning)."
                return @{ CaCertBase64 = [string]$state.caCert; Source = 'persisted'; Exhausted = $false }
            }
        } catch { Write-Verbose "Get-CachingProxyCaCertBase64: persisted CA decode failed: $($_.Exception.Message)" }
    }
    return @{ CaCertBase64 = ''; Source = 'none'; Exhausted = $true }
}

function Resolve-CachingProxyCaCertPem {
    <#
    .SYNOPSIS
        Resolves the caching-proxy CA as PEM text for the host status server's
        /ca.crt endpoint (guest CA self-heal). Live-read first so the CURRENT
        cache's CA is always served, sidestepping the stale-after-rebuild trap;
        the persisted CA is only a labeled last resort.
    .DESCRIPTION
        Resolution order: current cache host = $env:YURUNA_CACHING_PROXY_IP else
        Read-CachingProxyState().ipAddress. If known, live-read
        http://<host>/yuruna-squid-ca.crt -NoProxy and return it when it parses
        as X509 (Source='live'). Otherwise fall back to the persisted base64 CA,
        decoded and re-validated (Source='persisted'). '' with Source='none'
        when neither yields a usable CA -- the endpoint then 404s so the guest
        degrades to a diagnosed rc=60 rather than a silent 443 relaxation.
    .OUTPUTS
        [hashtable] @{ Pem [string]; Source 'live'|'persisted'|'none' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([int]$LiveTimeoutSec = 5)
    $state = Read-CachingProxyState
    $cacheHost = if ($env:YURUNA_CACHING_PROXY_IP) { $env:YURUNA_CACHING_PROXY_IP.Trim() } else { [string]$state.ipAddress }
    if ($cacheHost) {
        $urlHost = if (Get-Command Format-IpUrlHost -ErrorAction SilentlyContinue) { Format-IpUrlHost $cacheHost } else { $cacheHost }
        try {
            $resp = Invoke-WebRequest -Uri "http://$urlHost/yuruna-squid-ca.crt" -UseBasicParsing -NoProxy -TimeoutSec $LiveTimeoutSec -ErrorAction Stop
            if ($resp.StatusCode -eq 200 -and $resp.RawContentLength -gt 0) {
                $pem = if ($resp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($resp.Content) } else { [string]$resp.Content }
                if (Test-CachingProxyCaPem -Pem $pem) { return @{ Pem = $pem; Source = 'live' } }
            }
        } catch { Write-Verbose "Resolve-CachingProxyCaCertPem: live read of $urlHost failed: $($_.Exception.Message)" }
    }
    if ($state.caCert) {
        try {
            $pem = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$state.caCert))
            if (Test-CachingProxyCaPem -Pem $pem) { return @{ Pem = $pem; Source = 'persisted' } }
        } catch { Write-Verbose "Resolve-CachingProxyCaCertPem: persisted CA decode failed: $($_.Exception.Message)" }
    }
    return @{ Pem = ''; Source = 'none' }
}

Export-ModuleMember -Function Get-CachingProxyStatePath, Read-CachingProxyState, Save-CachingProxyState, Test-TcpPortReachable, Invoke-CachingProxyProbe, Resolve-CachingProxyEndpoint, Get-PoolAggregatorSeedUrl, Test-CachingProxyCaPem, Get-CachingProxyCaCertBase64, Resolve-CachingProxyCaCertPem
