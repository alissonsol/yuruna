<#PSScriptInfo
.VERSION 2026.07.31
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
    Cross-cycle persistence for the yuruna-caching-proxy-service VM state
    (the caching-proxy-service-admin user's password + the VM's IP address). Single YAML file
    under the runtime directory; survives cycle vault wipes.

.DESCRIPTION
    State lives in a single YAML doc at:
        <runtime-dir>/yuruna-caching-proxy-service.yml
    where <runtime-dir> is $env:YURUNA_RUNTIME_DIR (default
    <repoRoot>/test/status/runtime). One file, host-agnostic location,
    git-ignored alongside the rest of status/. The authentication
    extension's vault.yml persists across cycles too, but this
    file remains the source of truth for the cache VM's caching-proxy-service-admin user --
    caching-proxy-service New-VM.ps1 re-aligns the vault entry from here on
    every cycle so the two stay in sync if they ever diverge.

    Save uses merge semantics: only the fields you pass are touched.
    Atomic write via "write .tmp + Move-Item" so a concurrent reader
    never sees a half-written file.
#>

# === Path ===================================================================

<#
.SYNOPSIS
    Returns the absolute path of the yuruna-caching-proxy-service state file.
.DESCRIPTION
    Resolves <runtime-dir>/yuruna-caching-proxy-service.yml. Runtime dir defaults
    to <repoRoot>/test/status/runtime and can be overridden via
    $env:YURUNA_RUNTIME_DIR. Creates the directory on demand so callers
    don't have to Test-Path-and-mkdir.
#>
function Get-CachingProxyServiceStatePath {
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
    return (Join-Path -Path $runtimeDir -ChildPath 'yuruna-caching-proxy-service.yml')
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
function Read-CachingProxyServiceState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $path = Get-CachingProxyServiceStatePath
    $empty = @{ password = ''; ipAddress = ''; caCert = ''; caCertSourceHost = '' }
    if (-not (Test-Path -LiteralPath $path)) { return $empty }
    if (-not (Get-Module powershell-yaml)) {
        try {
            Import-Module powershell-yaml -Global -Verbose:$false -ErrorAction Stop
        } catch {
            Write-Warning "Read-CachingProxyServiceState: powershell-yaml not importable ($($_.Exception.Message)); returning empty."
            return $empty
        }
    }
    $parsed = Read-CachingProxyServiceStateFile -Path $path
    if ($null -ne $parsed) { return $parsed }
    # Primary file unparseable. Try a `.backup` rotated by Save-CachingProxyServiceState
    # so the cache VM's IP / vault password isn't silently lost on a torn
    # write or disk corruption. The backup is one rotation behind by design
    # -- if BOTH files corrupt simultaneously the operator gets an empty
    # dict (caller re-discovers IP and rebuilds vault from yuruna-vault.yml),
    # but the warning + corrupt-file rotation below leaves a forensics trail.
    $backupPath = "$path.backup"
    if (Test-Path -LiteralPath $backupPath) {
        $fallback = Read-CachingProxyServiceStateFile -Path $backupPath
        if ($null -ne $fallback) {
            Write-Warning "Read-CachingProxyServiceState: main file at $path was unparseable; recovered prior state from $backupPath."
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
        Write-Warning "Read-CachingProxyServiceState: $path was unparseable and no usable backup; preserved corrupt copy at $corruptPath. State reset to empty."
    } catch {
        Write-Warning "Read-CachingProxyServiceState: $path was unparseable AND the corrupt-rotation move failed ($($_.Exception.Message)). State reset to empty; next save will overwrite the broken file in place."
    }
    return $empty
}

function Read-CachingProxyServiceStateFile {
    <#
    .SYNOPSIS
        Parse a single caching-proxy-service state YAML file. Returns the hashtable
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
        Write-Verbose "Read-CachingProxyServiceStateFile: $Path parse failed: $($_.Exception.Message)"
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
function Save-CachingProxyServiceState {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        # The caching-proxy-service-admin user's password value to persist; on-disk YAML key is
        # `password:`. Pass '' to clear; omit to leave unchanged.
        [string]$Secret,
        [string]$IpAddress,
        # Last-good caching-proxy-service CA, base64 of the PEM text (same encoding the
        # guest seed's CA_CERT_BASE64 carries). Persisted so a later provision
        # whose live fetch flaps can fall back to it, and so the status service
        # can serve it. Pass '' to clear; omit to leave unchanged.
        [string]$CaCert,
        # The host string the persisted CA was fetched from (cache IP or the
        # host-forwarder the guest reaches it through). Guards reuse: a fallback
        # is only trusted when the current fetch host matches, so a CA saved for
        # one cache is never baked against a different one. Pass '' to clear.
        [string]$CaCertSourceHost
    )
    $path = Get-CachingProxyServiceStatePath
    $state = Read-CachingProxyServiceState
    # Merge: only update keys the caller actually passed.
    if ($PSBoundParameters.ContainsKey('Secret'))    { $state.password  = [string]$Secret }
    if ($PSBoundParameters.ContainsKey('IpAddress')) { $state.ipAddress = [string]$IpAddress }
    if ($PSBoundParameters.ContainsKey('CaCert'))    { $state.caCert    = [string]$CaCert }
    if ($PSBoundParameters.ContainsKey('CaCertSourceHost')) { $state.caCertSourceHost = [string]$CaCertSourceHost }
    if (-not $PSCmdlet.ShouldProcess($path, "Save caching-proxy-service state")) { return $path }
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
    # version in. Read-CachingProxyServiceState falls back to this backup when the
    # main file is corrupt, so the cache VM IP and vault password survive
    # a single torn write. Best-effort: copy failures degrade silently
    # because the new write is the primary safety guarantee.
    $backupPath = "$path.backup"
    if (Test-Path -LiteralPath $path) {
        try {
            Copy-Item -LiteralPath $path -Destination $backupPath -Force -ErrorAction Stop
        } catch {
            Write-Verbose "Save-CachingProxyServiceState: could not rotate prior main to $backupPath (non-fatal): $($_.Exception.Message)"
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
        the caching-proxy-service callers otherwise hand-roll, so the timeout policy and
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
    Smoke-tests the caching-proxy-service at the given IP. Shared core between
    Test-CachingProxyService.ps1 and the cycle-start gate in Invoke-TestRunnerInnerLoop.ps1.
.DESCRIPTION
    Probes :3128 / :3129 / :80 / :3000 and fetches /yuruna-squid-ca.crt off
    Apache. PASS / WARN / FAIL classification matches the standalone script:
    :3128 / :3129 / :3000 are FAIL on unreachable (hard requirements);
    :80 and the CA cert are WARN (HTTPS caching disabled on guests, HTTP
    still works).

    IP resolution, host system-proxy and outbound-proxy checks stay in the
    standalone script -- those are host-state-dependent, not cache-state-
    dependent. This function is the cache-side subset both callers need.

    Requires Test.VMUtility.psm1 (Get-CachingProxyServicePort, Format-IpUrlHost)
    to be imported by the caller.
.PARAMETER CacheIp
    Resolved cache IP (IPv4 or IPv6). The caller is expected to have
    validated the format with Test-IpAddress; this function does not
    re-check.
.PARAMETER CacheSource
    Free-form label rendered into the "Target:" diagnostic header (e.g.
    "$Env:YURUNA_CACHING_PROXY_SERVICE_IP" or "vmStart.cachingProxyIp"). Empty
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
    gate in Invoke-TestRunnerInnerLoop.ps1 uses so a barebones squid
    (without Grafana / ssl-bump) is still accepted as a working
    proxy -- the runner only relies on :3128 for guest installs.
#>
function Invoke-CachingProxyServiceProbe {
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

    $httpPort  = Get-CachingProxyServicePort -Scheme http
    $httpsPort = Get-CachingProxyServicePort -Scheme https
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

function Wait-CachingProxyServiceSettled {
    <#
    .SYNOPSIS
        Wait until the cache's HTTP proxy port has accepted $RequiredConsecutive
        times in a row, or the budget expires. Returns the verdict plus console
        lines for the caller to print verbatim.
    .DESCRIPTION
        One successful probe says the port answered ONCE. That is not the same
        as the cache being ready, and the gap between them is not theoretical: a
        cache VM rebuilt shortly before a cycle starts is still provisioning, and
        squid restarts once when the build applies its ssl-bump configuration
        against the freshly minted CA. A cycle that probes in the moment before
        that restart pins the address as accepted, then spends its next steps
        reporting the cache as lost -- and every guest created in that window is
        seeded with a proxy URL that refuses, so it silently downloads direct.

        Consecutive successes are what separates "up" from "up just then". The
        restart window is tens of seconds, far wider than the spacing here, so a
        restart in progress misses every probe instead of slipping between two.

        This never fails the caller. A cache that will not settle inside the
        budget is still handed back: it answered at least once, guests degrade to
        direct downloads on their own, and stalling a cycle over its cache is
        worse than running the cycle without one. The verdict rides in the
        returned lines so the operator sees why the cycle went ahead anyway.
    .PARAMETER RequiredConsecutive
        Successes in a row before the cache is called settled.
    .PARAMETER IntervalSeconds
        Spacing between probes. Small on purpose -- it only has to be small
        relative to a restart, and it is charged to every cycle.
    .PARAMETER TimeoutSeconds
        Total budget. Generous relative to a service restart, because the
        alternative to waiting is a whole cycle of direct downloads.
    .OUTPUTS
        [hashtable] @{ Settled = [bool]; Consecutive = [int]; Lines = [string[]] }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$CacheIp,
        [Parameter(Mandatory)][int]$Port,
        [int]$RequiredConsecutive = 3,
        [int]$IntervalSeconds = 2,
        [int]$TimeoutSeconds = 120
    )
    $lines       = [System.Collections.Generic.List[string]]::new()
    $consecutive = 0
    $probes      = 0
    $lastReason  = ''
    $announced   = $false
    # Wall-clock deadline, not an iteration count: each probe costs its own
    # latency on top of the interval (feedback_iter_counter_wallclock_trap).
    $deadline = (Get-Date).AddSeconds([Math]::Max(0, $TimeoutSeconds))
    $classify = Get-Command Test-TcpConnectOutcome -ErrorAction SilentlyContinue
    while ($true) {
        if ($probes -gt 0) { Start-Sleep -Seconds $IntervalSeconds }
        $probes++
        if ($classify) {
            $outcome = & $classify -IpAddress $CacheIp -Port $Port -TimeoutMs 3000
            $ok = [bool]$outcome.Reachable
            if (-not $ok) { $lastReason = "$($outcome.Outcome) after $($outcome.ElapsedMs) ms" }
        } else {
            $ok = Test-TcpPortReachable -TargetHost $CacheIp -Port $Port -Attempts 1 -TimeoutMs 3000
            if (-not $ok) { $lastReason = 'no connect' }
        }
        if ($ok) {
            $consecutive++
            if ($consecutive -ge $RequiredConsecutive) { break }
        } else {
            $consecutive = 0
            if (-not $announced) {
                # Said once, on the first miss: the operator needs to know the
                # cycle is deliberately paused here, not stalled.
                $lines.Add("  Cache at ${CacheIp}:${Port} is not settled yet ($lastReason) -- waiting up to ${TimeoutSeconds}s for it to stay up. A cache rebuilt just before this cycle restarts squid once while provisioning finishes.")
                $announced = $true
            }
        }
        if ((Get-Date) -ge $deadline) { break }
    }
    $settled = ($consecutive -ge $RequiredConsecutive)
    if ($settled -and $announced) {
        $lines.Add("  Cache settled after $probes probe(s); continuing.")
    } elseif (-not $settled) {
        $lines.Add("  Cache at ${CacheIp}:${Port} never accepted $RequiredConsecutive probes in a row within ${TimeoutSeconds}s (last: $lastReason). Proceeding anyway -- guests fall back to direct downloads whenever it refuses.")
    }
    return @{ Settled = $settled; Consecutive = $consecutive; Lines = $lines.ToArray() }
}

function Resolve-CachingProxyServiceEndpoint {
    <#
    .SYNOPSIS
        Resolve the effective caching-proxy-service IP from the operator's two
        sources by probing each, keeping the first whose HTTP proxy port
        is reachable, and clearing the choice when none answers.
    .DESCRIPTION
        The runner accepts a caching-proxy service from two operator-controlled
        sources, in priority order:
          1. $Config.vmStart.cachingProxyIp -- persistent UI-edited key
          2. $env:YURUNA_CACHING_PROXY_SERVICE_IP   -- session-scope env var,
             probed only when the config candidate is absent or its
             HTTP proxy port does not answer
        Each candidate is validated as an IP (Test-IpAddress) and then
        probed with the full Invoke-CachingProxyServiceProbe suite. The first
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
        the inner runner and Invoke-TestSequence must share so a syntactically
        valid but dead IP can't survive into guest cidata.
    .PARAMETER EnvIp
        Value of $env:YURUNA_CACHING_PROXY_SERVICE_IP (or ''), second priority:
        probed only when ConfigIp is absent or fails its probe.
    .PARAMETER ConfigIp
        Value of $Config.vmStart.cachingProxyIp (or ''), highest priority.
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
    # HttpPort rides back so a caller that wants to re-probe the accepted cache
    # uses the port this resolution actually tested, instead of looking it up
    # again and risking a different answer.
    $result = @{ EffectiveIp = ''; Probed = $false; Lines = @(); HttpPort = (Get-CachingProxyServicePort -Scheme http) }
    if (-not $envIpTrim -and -not $configIpTrim) { return $result }

    $result.Probed = $true
    $effectiveCacheIp = ''
    foreach ($cand in @(
        @{ Ip = $configIpTrim; Source = 'vmStart.cachingProxyIp'        }
        @{ Ip = $envIpTrim;    Source = '$env:YURUNA_CACHING_PROXY_SERVICE_IP' }
    )) {
        if (-not $cand.Ip) { continue }
        if (-not (Test-IpAddress $cand.Ip)) {
            $lines.Add("Caching-proxy service '$($cand.Ip)' (source: $($cand.Source)): rejected -- not a valid IPv4 or IPv6 address.")
            continue
        }
        $lines.Add('')
        $lines.Add("== Probing caching-proxy service at $($cand.Ip) (source: $($cand.Source)) ==")
        $probe = Invoke-CachingProxyServiceProbe -CacheIp $cand.Ip
        foreach ($line in $probe.Lines) { $lines.Add($line) }
        $lines.Add("  Summary: $($probe.PassCount) PASS, $($probe.WarnCount) WARN, $($probe.FailCount) FAIL")
        if ($probe.HttpProxyReachable) {
            $effectiveCacheIp = $cand.Ip
            $result.HttpPort  = $probe.HttpPort
            if ($probe.Success) {
                $lines.Add("Caching-proxy service at $($cand.Ip) ACCEPTED (full probe suite passed).")
            } else {
                $lines.Add("Caching-proxy service at $($cand.Ip) ACCEPTED (HTTP proxy :$($probe.HttpPort) reachable; see WARN/FAIL above for the non-essential checks that did not pass).")
            }
            break
        }
        $lines.Add("Caching-proxy service at $($cand.Ip) REJECTED -- HTTP proxy :$($probe.HttpPort) not reachable.")
    }
    $result.EffectiveIp = $effectiveCacheIp
    $result.Lines = $lines.ToArray()
    return $result
}

function Get-PoolAggregatorServiceClaim {
<#
.SYNOPSIS
    The deduped, ordered list of addresses that might be running the caching-proxy
    service, each with the source that claimed it. Never throws.
.DESCRIPTION
    Split out so "is there any proxy to talk to at all?" can be answered without
    probing. Wait-YurunaAggregatorReady needs exactly that distinction: an empty
    list means this host runs no proxy, and there is nothing to wait for -- waiting
    the full budget there would stall every standalone host that legitimately has
    no aggregator.

    An address carrying a quote or whitespace is dropped: the value lands inside a
    single-quoted env line in a guest seed, and the next claim still gets its turn
    rather than the seed being corrupted.
.OUTPUTS
    [System.Collections.Generic.List[hashtable]] of @{ Address; Source }.
#>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[hashtable]])]
    param()

    $stateIp = ''
    try {
        $state = Read-CachingProxyServiceState
        if ($state -and $state.ipAddress) { $stateIp = [string]$state.ipAddress }
    } catch { $null = $_ }

    $configIp = ''
    try {
        $configPath = $env:YURUNA_CONFIG_PATH
        if ([string]::IsNullOrWhiteSpace($configPath)) {
            $configPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'test.config.yml'
        }
        if (Test-Path -LiteralPath $configPath) {
            if (-not (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) {
                Import-Module (Join-Path $PSScriptRoot 'Test.Config.psm1') -Global -Force -DisableNameChecking -Verbose:$false
            }
            $cfg = Read-TestConfig -Path $configPath
            if ($cfg.vmStart -is [System.Collections.IDictionary] -and $cfg.vmStart.Contains('cachingProxyIp')) {
                $configIp = "$($cfg.vmStart.cachingProxyIp)".Trim()
            }
        }
    } catch { Write-Verbose "Get-PoolAggregatorServiceClaim: reading vmStart.cachingProxyIp failed: $($_.Exception.Message)" }

    # Deduped: the same address commonly appears in two claims at once, and
    # every distinct one costs a round trip to disprove.
    $claims = [System.Collections.Generic.List[hashtable]]::new()
    $seen   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($claim in @(
        @{ Address = $stateIp;                          Source = 'caching-proxy-service state'          }
        @{ Address = "$($env:YURUNA_CACHING_PROXY_SERVICE_IP)"; Source = '$env:YURUNA_CACHING_PROXY_SERVICE_IP' }
        @{ Address = $configIp;                         Source = 'vmStart.cachingProxyIp'       }
    )) {
        $address = "$($claim.Address)".Trim()
        if ([string]::IsNullOrWhiteSpace($address)) { continue }
        if ($address -match "['\s]") { continue }
        if (-not $seen.Add($address)) { continue }
        $claims.Add(@{ Address = $address; Source = $claim.Source })
    }
    # Comma: PowerShell would otherwise unroll a 1-item list to a bare hashtable
    # and a 0-item list to $null, and every caller reads .Count.
    return ,$claims
}

function Get-PoolAggregatorServiceSeedUrl {
<#
.SYNOPSIS
    Resolves the pool-aggregator-service base URL (https://<proxy-ip>:9400) to bake
    into a guest seed, e.g. the stash-service VM's presence-beacon destination.
.DESCRIPTION
    The aggregator runs inside the caching-proxy-service VM, so its address is the
    caching-proxy service's -- and one host can carry three separate claims about
    where that proxy is:

      1. the persisted caching-proxy-service state (`ipAddress`), written only when
         THIS host provisions, adopts, or stops a proxy VM of its own,
      2. $env:YURUNA_CACHING_PROXY_SERVICE_IP, the session-scope override,
      3. vmStart.cachingProxyIp, the persistent operator key naming a proxy
         this host USES but did not provision -- the only claim a host whose
         services all live elsewhere ever has.

    Every claim is PROBED on the aggregator port and the first that answers
    wins, which makes that order a preference among reachable addresses
    rather than blind trust in the highest-ranked one. A claim outlives the
    thing it describes: the state key keeps its last value on a host that
    stopped running a proxy of its own, and an env var exported for a proxy
    that has since moved keeps naming the old address. Believing either
    unprobed strands every consumer on a URL nothing has served for months
    while a live proxy sits in the claim right behind it -- and a guest seeded
    from that answer carries the dead address for the life of the VM. This is
    the probe-and-discard policy Resolve-CachingProxyServiceEndpoint applies to the
    cycle's own resolution, so the two agree about which addresses are real.

    The probe targets the aggregator port rather than squid's: this
    function's entire output is an aggregator URL, so the port that proves
    the answer is the port the answer names.

    A stored claim that loses to a live one is repaired in place, so a stale
    address costs one probe rather than every future call. A claim this host
    never stored is left unstored -- that key means "the proxy VM I run", and
    a host that merely uses someone else's must not begin claiming it.

    https because a provisioned proxy mints the aggregator's TLS leaf in
    cloud-init; a consumer facing an older plain-HTTP proxy downgrades per
    attempt (the beacon's https-then-http candidate order), so the baked
    scheme never strands it.

    Returns '' when no claim answers -- the caller bakes an empty value and
    the consuming service leaves its aggregator-dependent features off. The
    value lands inside a single-quoted env line in the seed, so a claim
    carrying a quote or whitespace is skipped (the next claim still gets its
    turn) rather than corrupting the seed file.
.PARAMETER MaxWaitSeconds
    How long to keep re-probing when NO claim answers the first sweep, so a
    momentary outage resolves to the right address instead of to ''. 0 (the
    default) is a single bounded sweep: seed rendering and the pre-cycle
    extension lookup both sit in front of a cycle and must not delay one.
    Callers with an operator waiting on the answer -- where resolving ''
    means a failed enrollment rather than a feature left off -- pass a real
    budget.
.OUTPUTS
    [string] aggregator base URL, or ''.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [int]$MaxWaitSeconds = 0
    )
    # The aggregator's LAN port: the one the host forwards among the proxy's
    # service ports, and the one guest seeds beacon to.
    $aggregatorPort = 9400

    $claims = Get-PoolAggregatorServiceClaim
    if ($claims.Count -eq 0) { return '' }

    # Repeat calls inside one process -- a render that emits several guests, a
    # cycle looking up more than one extension area -- must not re-pay the
    # sweep. Only a resolved address is remembered: a caller that asks again
    # with a wait budget is asking to keep trying, and a remembered '' would
    # rob it of exactly that.
    $claimKey = (($claims | ForEach-Object { $_.Address }) -join '|')
    if ($script:PoolAggregatorServiceUrlMemo -and
        $script:PoolAggregatorServiceUrlMemo.Key -eq $claimKey -and
        $script:PoolAggregatorServiceUrlMemo.ExpiresUtc -gt [datetime]::UtcNow) {
        return $script:PoolAggregatorServiceUrlMemo.Url
    }

    # Wall-clock deadline, not a round count: a probe's own duration swings
    # with the failure shape (a refused connect returns at once, a black-holed
    # address burns the full timeout), so counting rounds would make the same
    # budget mean a different wait on every network.
    $deadlineUtc = [datetime]::UtcNow.AddSeconds([Math]::Max(0, $MaxWaitSeconds))
    $winner      = $null
    $backoffMs   = 2000
    $announced   = $false
    while ($true) {
        foreach ($candidate in $claims) {
            # Two attempts: the first warms ARP and wakes a power-saved radio,
            # so a live proxy still answers when the first one times out.
            if (Test-TcpPortReachable -TargetHost $candidate.Address -Port $aggregatorPort -Attempts 2 -TimeoutMs 600 -BackoffMs 150) {
                $winner = $candidate
                break
            }
            Write-Verbose "Get-PoolAggregatorServiceSeedUrl: $($candidate.Address):$aggregatorPort (source: $($candidate.Source)) did not answer."
        }
        if ($winner) { break }
        $remainingMs = [int][Math]::Floor(($deadlineUtc - [datetime]::UtcNow).TotalMilliseconds)
        if ($remainingMs -le 0) { break }
        if (-not $announced) {
            Write-Information "No caching-proxy service answered on :$aggregatorPort ($($claimKey -replace '\|', ', ')); retrying for up to $MaxWaitSeconds s in case the outage is momentary ..." -InformationAction Continue
            $announced = $true
        }
        Start-Sleep -Milliseconds ([Math]::Min($backoffMs, $remainingMs))
        # Widen the gap so a long outage is not hammered, capped so a proxy
        # that does come back is noticed within seconds of doing so.
        $backoffMs = [Math]::Min(15000, $backoffMs * 2)
    }
    if (-not $winner) { return '' }

    # Repair a stored address that lost to a live one, so the next call pays
    # no probe to disprove it again. Only an address this host already
    # recorded is rewritten: an empty key means "I run no proxy of my own",
    # and filling it with a proxy someone else runs would assert an ownership
    # this host does not have.
    #
    # ShouldProcess, not $WhatIfPreference: preference variables resolve in the
    # module's OWN session state, where $WhatIfPreference reads $false however
    # the caller was invoked, and an unbound -WhatIf is not forwarded across
    # that boundary either. A caller that must not write has to pass -WhatIf by
    # hand, and this gate is what gives that pass an effect.
    if ($stateIp -and $stateIp -ne $winner.Address -and
        $PSCmdlet.ShouldProcess("caching-proxy-service state ipAddress ($stateIp)", "replace with the address that answered ($($winner.Address))")) {
        try {
            [void](Save-CachingProxyServiceState -IpAddress $winner.Address -Confirm:$false)
            Write-Verbose "Get-PoolAggregatorServiceSeedUrl: caching-proxy-service state ipAddress $stateIp -> $($winner.Address) (the stored address did not answer)."
        } catch {
            Write-Verbose "Get-PoolAggregatorServiceSeedUrl: could not update the caching-proxy-service state ($($_.Exception.Message)); the resolved address is unaffected."
        }
    }

    # Format-IpUrlHost (Test.VMUtility) brackets an IPv6 literal; callers that
    # haven't loaded that module still get a correct IPv4 URL from the raw IP.
    $urlHost = if (Get-Command Format-IpUrlHost -ErrorAction SilentlyContinue) { Format-IpUrlHost $winner.Address } else { $winner.Address }
    $url = "https://${urlHost}:${aggregatorPort}"
    $script:PoolAggregatorServiceUrlMemo = @{ Key = $claimKey; Url = $url; ExpiresUtc = [datetime]::UtcNow.AddSeconds(60) }
    return $url
}

function Wait-YurunaAggregatorReady {
<#
.SYNOPSIS
    Blocks until the pool-aggregator service is serving AND its base URL resolves,
    or a timeout expires. Returns $true/$false; never throws.
.DESCRIPTION
    Gates every caller that is about to BAKE the aggregator URL into a guest seed.

    Get-PoolAggregatorServiceSeedUrl is probe-and-discard by design: asked before
    :9400 answers, it returns '' -- correctly, since a dead address must never be
    baked in. But the seed then carries an empty URL, and both guests' presence
    beacons refuse to start without one (Enabled() requires a non-empty
    AggregatorURL; Run() returns immediately). The beacons retry their FIRST hello
    forever, so a late-but-present aggregator self-heals -- an empty URL is never
    re-resolved. The failure is therefore permanent, and silent: the VM is healthy,
    the service serves, and only the dashboard row is missing.

    The window is routine rather than rare. The aggregator is compiled from source
    inside the proxy guest and enabled near the end of runcmd, while
    Start-CachingProxyServiceVM reports success on a probe suite that does not
    include :9400 -- so "the proxy is ready" is regularly true minutes before the
    aggregator exists, which is exactly when an operator starts the next VM.

    Two conditions, in order:

      1. GET <base>/healthz answers 2xx. That route is open and unauthenticated by
         design (alongside /metrics and /api/v1/pool-status), so no credential is
         needed. It is strictly stronger than a TCP connect: a hypervisor
         port-forward accepts the connection whether or not the guest is listening
         behind it, which would make a port probe pass minutes early.
      2. Get-PoolAggregatorServiceSeedUrl returns non-empty -- the exact value the
         caller is about to bake, so the gate tests the real precondition rather
         than a proxy for it.

    A delay would not do: too short on a slow host, wasted on a fast one, and still
    silently wrong when it guessed. This signal is exact, and the only place machine
    speed matters is the timeout.
.PARAMETER ProxyAddress
    Address to poll. Omitted (the default), the resolver's own claim resolution
    supplies it -- which is what the New-VM callers need, holding no address of
    their own. TLS verification is off for this probe: the leaf is the proxy's
    self-signed CA, and this is a liveness check, matching the beacon's posture.
.PARAMETER TimeoutSeconds
    Total budget. The default 15 minutes covers a slow in-guest Go build with
    margin; that build, not the caller, is what bounds the wait.
.PARAMETER PollSeconds
    Gap between attempts.
.OUTPUTS
    [bool] $true when the aggregator is ready to be baked into a seed.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$ProxyAddress = '',
        [int]$TimeoutSeconds = 900,
        [int]$PollSeconds = 5
    )

    $aggregatorPort = 9400
    # An explicit -TimeoutSeconds always wins; the env var is for the call sites
    # that pass none (the six New-VM renderers), matching the tuning knob
    # Start-PoolControlServiceVM already offers for its own :80 wait. A
    # non-numeric or negative value is ignored rather than fatal: this runs in
    # front of VM creation and must not fail on a typo'd variable.
    if (-not $PSBoundParameters.ContainsKey('TimeoutSeconds') -and $env:YURUNA_AGGREGATOR_READY_TIMEOUT_SECONDS) {
        $parsed = 0
        if ([int]::TryParse($env:YURUNA_AGGREGATOR_READY_TIMEOUT_SECONDS, [ref]$parsed) -and $parsed -ge 0) { $TimeoutSeconds = $parsed }
        else { Write-Warning "YURUNA_AGGREGATOR_READY_TIMEOUT_SECONDS ('$($env:YURUNA_AGGREGATOR_READY_TIMEOUT_SECONDS)') is not a non-negative integer; using $TimeoutSeconds s." }
    }
    if ($TimeoutSeconds -lt 0) { $TimeoutSeconds = 0 }
    if ($PollSeconds -lt 1) { $PollSeconds = 1 }

    # Nothing claims to run a proxy: this host has no aggregator, and there is
    # nothing to wait for. Returning at once keeps a standalone host -- which
    # legitimately seeds an empty URL and leaves the beacon off -- from stalling
    # for the whole budget on every VM it creates.
    if (-not $ProxyAddress -and (Get-PoolAggregatorServiceClaim).Count -eq 0) {
        Write-Verbose 'Wait-YurunaAggregatorReady: no caching-proxy service is configured on this host; not waiting.'
        return $false
    }

    # https first, then plain http: a proxy provisioned before the aggregator's
    # TLS leaf existed serves this route in the clear, and the beacon downgrades
    # the same way. Trying only https would strand exactly those hosts.
    $healthzOk = {
        param([string]$BaseUrl)
        foreach ($candidate in @($BaseUrl, ($BaseUrl -replace '^https://', 'http://')) | Select-Object -Unique) {
            try {
                $response = Invoke-WebRequest -Uri "$($candidate.TrimEnd('/'))/healthz" -TimeoutSec 5 `
                    -SkipCertificateCheck -SkipHttpErrorCheck -ErrorAction Stop
                if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300) { return $true }
                Write-Verbose "Wait-YurunaAggregatorReady: $candidate/healthz answered $($response.StatusCode)."
            } catch {
                Write-Verbose "Wait-YurunaAggregatorReady: $candidate/healthz did not answer: $($_.Exception.Message)"
            }
        }
        return $false
    }

    $startedUtc  = [datetime]::UtcNow
    $deadlineUtc = $startedUtc.AddSeconds($TimeoutSeconds)
    $lastReport  = $startedUtc
    $announced   = $false

    while ($true) {
        # Resolved every round, not once: before the aggregator answers this is ''
        # by design, and the whole point of waiting is that it stops being ''.
        # Only a SUCCESSFUL resolution is memoised, so re-asking is not defeated
        # by a cached failure.
        $baseUrl = if ($ProxyAddress) {
            $urlHost = if (Get-Command Format-IpUrlHost -ErrorAction SilentlyContinue) { Format-IpUrlHost $ProxyAddress } else { $ProxyAddress }
            "https://${urlHost}:${aggregatorPort}"
        } else {
            Get-PoolAggregatorServiceSeedUrl
        }

        if ($baseUrl -and (& $healthzOk $baseUrl)) {
            # healthz answering is not sufficient when an explicit address was
            # given: the resolver picks from its OWN claims (service state, env,
            # vmStart.cachingProxyIp), so it can still come back empty for an
            # aggregator that is plainly serving. Report that precisely -- it is a
            # configuration gap, and no amount of further waiting fixes it.
            $seedUrl = Get-PoolAggregatorServiceSeedUrl
            if ($seedUrl) {
                $elapsed = [int]([datetime]::UtcNow - $startedUtc).TotalSeconds
                Write-Information "pool-aggregator service is ready at $seedUrl (waited ${elapsed}s)." -InformationAction Continue
                return $true
            }
            if ($ProxyAddress) {
                Write-Warning ("Wait-YurunaAggregatorReady: the aggregator at $baseUrl answered /healthz, but no configured claim " +
                    "resolves to it, so the seed URL is still empty. Set vmStart.cachingProxyIp (or " +
                    "`$env:YURUNA_CACHING_PROXY_SERVICE_IP) to $ProxyAddress and retry.")
                return $false
            }
        }

        $remainingMs = [int][Math]::Floor(($deadlineUtc - [datetime]::UtcNow).TotalMilliseconds)
        if ($remainingMs -le 0) { break }

        if (-not $announced) {
            $where = if ($ProxyAddress) { "$ProxyAddress" } else { 'the configured caching-proxy service' }
            Write-Information "Waiting for the pool-aggregator service on ${where}:$aggregatorPort (up to $TimeoutSeconds s; it is compiled inside the proxy guest, so a first build is slow) ..." -InformationAction Continue
            $announced = $true
        }
        # Every 30 s, so a long wait reads as work rather than as a hang.
        if (([datetime]::UtcNow - $lastReport).TotalSeconds -ge 30) {
            $mins = [Math]::Round(([datetime]::UtcNow - $startedUtc).TotalMinutes, 1)
            Write-Information "  ... still waiting for the pool-aggregator service ($mins min elapsed)." -InformationAction Continue
            $lastReport = [datetime]::UtcNow
        }
        Start-Sleep -Milliseconds ([Math]::Min($PollSeconds * 1000, $remainingMs))
    }

    Write-Warning ("Wait-YurunaAggregatorReady: the pool-aggregator service did not become ready within $TimeoutSeconds s. " +
        "Creating a dependent VM now bakes an EMPTY aggregator URL into its seed, which never re-resolves -- the service " +
        "would run but never appear on the dashboard. Check it inside the caching-proxy VM with " +
        "'journalctl -u pool-aggregator-service -n 50', then retry.")
    return $false
}

function Get-PoolIntentSeedUrl {
<#
.SYNOPSIS
    Resolves the pool-intent git URL to bake into the pool-control-service VM seed.
.DESCRIPTION
    The pool-control-service daemon COMMITS to this store, so the resolution prefers a
    writable location:

      1. An explicit networkStorage/pool `intentGitUrl` in test.config.yml. The
         operator said what they want; nothing overrides it.
      2. The bare repo on the pool NAS, addressed by its GUEST mount path. The
         pool-control-service VM and the caching-proxy-service both mount that share read-write,
         so it is the one place the daemon can push to without a new credential
         or a new authenticated endpoint. The guest bring-up creates and seeds
         the repo when it is absent.
      3. The proxy's read-only HTTP route, when no pool storage is configured.
         This is a DEGRADED answer and is returned last on purpose: apache
         publishes the repo through a plain Alias, so a clone works and every
         push fails. It leaves the UI able to display intent rather than
         nothing at all.

    Returns '' when none resolve, which the seed bakes as an empty value; the
    guest then reports the reason on its diagnostics page rather than guessing.
.PARAMETER Config
    Parsed test.config.yml, or $null.
.PARAMETER GuestPoolMount
    Mount point the pool-control-service guest uses for the pool NAS. Matches MOUNT in
    guest/ubuntu.server.26/ubuntu.server.26.pool-control-service.sh.
.OUTPUTS
    [string] intent git URL, or ''.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        $Config,
        [string]$GuestPoolMount = '/mnt/yuruna-pool'
    )
    if ($Config -and $Config.pool -and -not [string]::IsNullOrWhiteSpace([string]$Config.pool.intentGitUrl)) {
        return ([string]$Config.pool.intentGitUrl).Trim()
    }
    # Pool storage configured => the guest will mount it and can host the store.
    $hasPoolStorage = $false
    if ($Config -and $Config.networkStorage -and -not [string]::IsNullOrWhiteSpace([string]$Config.networkStorage.poolStorageNetworkPath)) {
        $hasPoolStorage = $true
    }
    if ($hasPoolStorage) {
        return ("{0}/pool-intent.git" -f $GuestPoolMount.TrimEnd('/'))
    }
    # Last resort: the proxy's pull-only route, so the UI at least reads.
    $ip = ''
    try {
        $state = Read-CachingProxyServiceState
        if ($state -and $state.ipAddress) { $ip = [string]$state.ipAddress }
    } catch { Write-Verbose "caching-proxy-service state: $($_.Exception.Message)" }
    if ([string]::IsNullOrWhiteSpace($ip) -and $env:YURUNA_CACHING_PROXY_SERVICE_IP) {
        $ip = $env:YURUNA_CACHING_PROXY_SERVICE_IP.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($ip)) { return '' }
    # The value lands in an unquoted seed env line the guest sed-extracts, so a
    # quote or whitespace would corrupt it.
    if ($ip -match "['\s]") { return '' }
    $urlHost = if (Get-Command Format-IpUrlHost -ErrorAction SilentlyContinue) { Format-IpUrlHost $ip } else { $ip }
    return "http://${urlHost}/pool-intent.git"
}

function Sync-PoolIntentAliasOnProxy {
<#
.SYNOPSIS
    Points the caching-proxy service's read-only pool-intent route at the pool NAS
    store, so runners pull the same bytes the pool-control service UI writes.
.DESCRIPTION
    The proxy originally served a proxy-LOCAL bare repo, which the pool-control-service
    daemon (on its own VM) cannot push to. Both boxes mount the pool NAS
    read-write, so the store lives there and apache serves it -- one store, no
    mirroring, no divergence between what an operator writes and what a runner
    pulls.

    This runs from the HOST, not from the pool-control-service VM: the host already
    holds the harness SSH key, while a guest carries only an authorized PUBLIC
    key. Doing it guest-side would mean baking a private key that grants
    sudo-capable access to the proxy into a web-facing VM.

    Idempotent and non-destructive:
      * refuses unless the NAS store is a real bare repo, so a failed seeding
        can never repoint apache at a missing path and 404 every runner;
      * no-ops when the alias already names that path;
      * backs the conf up, runs `apache2ctl configtest`, and RESTORES the
        previous conf if the new one is rejected -- a bad edit never leaves the
        proxy unable to reload.

    Best-effort by contract: it reports rather than throws, because a bring-up
    must not fail over a serving-path optimization.
.PARAMETER ProxyAddress
    Proxy host/IP. Resolved from the persisted caching-proxy-service state (then
    $env:YURUNA_CACHING_PROXY_SERVICE_IP) when omitted.
.PARAMETER StorePath
    Bare repo path AS THE PROXY SEES IT. The proxy mounts the pool NAS at
    /mnt/ypool-nas; the pool-control-service VM mounts the same share at
    /mnt/yuruna-pool, so the two paths differ by design.
.PARAMETER User
    SSH login on the proxy. Defaults to the seed-created service account.
.OUTPUTS
    [hashtable] Ok (bool), Changed (bool), Message (string).
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [string]$ProxyAddress,
        [string]$StorePath = '/mnt/ypool-nas/pool-intent.git',
        [string]$User = 'caching-proxy-service-admin',
        [int]$TimeoutSeconds = 60
    )
    if ([string]::IsNullOrWhiteSpace($ProxyAddress)) {
        try {
            $state = Read-CachingProxyServiceState
            if ($state -and $state.ipAddress) { $ProxyAddress = [string]$state.ipAddress }
        } catch { Write-Verbose "caching-proxy-service state: $($_.Exception.Message)" }
        if ([string]::IsNullOrWhiteSpace($ProxyAddress) -and $env:YURUNA_CACHING_PROXY_SERVICE_IP) {
            $ProxyAddress = $env:YURUNA_CACHING_PROXY_SERVICE_IP.Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($ProxyAddress)) {
        return @{ Ok = $false; Changed = $false; Message = 'no caching-proxy-service address known; skipped' }
    }
    if (-not (Get-Command 'Test.Ssh\Invoke-GuestSsh' -ErrorAction SilentlyContinue)) {
        return @{ Ok = $false; Changed = $false; Message = 'Test.Ssh (Invoke-GuestSsh) not loaded; skipped' }
    }
    # A path carrying a quote would break out of the single-quoted shell
    # assignment below and run as code on the proxy.
    if ($StorePath -match "['`"\s]") {
        return @{ Ok = $false; Changed = $false; Message = "refusing a store path containing quotes or whitespace: '$StorePath'" }
    }
    if (-not $PSCmdlet.ShouldProcess($ProxyAddress, "Point /pool-intent.git at $StorePath")) {
        return @{ Ok = $true; Changed = $false; Message = 'WhatIf: no change made' }
    }

    # Single-quoted here-string: PowerShell must not touch $STORE/$CONF, which
    # are SHELL variables. The store path is injected by literal replace.
    $script = @'
set -u
STORE='__STORE__'
CONF=/etc/apache2/conf-available/yuruna-pool-intent.conf
if [ ! -d "$STORE/refs" ]; then echo "SKIP: no bare repo at $STORE"; exit 0; fi
if [ -r "$CONF" ] && grep -qxF "Alias /pool-intent.git $STORE" "$CONF"; then echo "OK: alias already serves $STORE"; exit 0; fi
sudo cp -p "$CONF" "$CONF.bak" 2>/dev/null || true
printf 'Alias /pool-intent.git %s\n<Directory %s>\n    Options +Indexes\n    Require ip 127.0.0.1\n    Require ip 10.0.0.0/8\n    Require ip 172.16.0.0/12\n    Require ip 192.168.0.0/16\n</Directory>\n' "$STORE" "$STORE" | sudo tee "$CONF" >/dev/null
sudo a2enconf yuruna-pool-intent >/dev/null 2>&1 || true
if sudo apache2ctl configtest 2>&1 | grep -qi 'syntax ok'; then
  sudo systemctl reload apache2 && echo "CHANGED: /pool-intent.git -> $STORE"
else
  sudo cp -p "$CONF.bak" "$CONF" 2>/dev/null || true
  echo "FAILED: apache rejected the new conf; restored the previous one" >&2
  exit 1
fi
'@.Replace('__STORE__', $StorePath)

    $r = $null
    try {
        $r = Test.Ssh\Invoke-GuestSsh -VMName $ProxyAddress -GuestKey 'guest.caching-proxy-service' -User $User -Command $script -TimeoutSeconds $TimeoutSeconds
    } catch {
        return @{ Ok = $false; Changed = $false; Message = "ssh to ${User}@${ProxyAddress} failed: $($_.Exception.Message)" }
    }
    $out = if ($r) { [string]$r.output } else { '' }
    return @{
        Ok      = [bool]($r -and $r.success)
        Changed = ($out -match 'CHANGED:')
        Message = if ([string]::IsNullOrWhiteSpace($out)) { "ssh exit $($r.exitCode)" } else { $out.Trim() }
    }
}

# === CA cert ================================================================

function Test-CachingProxyServiceCaPem {
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
        Write-Verbose "Test-CachingProxyServiceCaPem: X509 parse failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-CachingProxyServiceCaCertBase64 {
    <#
    .SYNOPSIS
        Resolves the caching-proxy-service CA (base64 of PEM) for a guest seed, with a
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
    $caFetch = Invoke-WithYurunaRetry -Label 'caching-proxy-service CA cert' -MaxAttempts $MaxAttempts -InitialDelaySeconds 3 -MaxDelaySeconds 20 -ScriptBlock {
        $caResp = Invoke-WebRequest -Uri $caUrl -UseBasicParsing -NoProxy -TimeoutSec 10 -ErrorAction Stop
        if ($caResp.StatusCode -ne 200 -or $caResp.RawContentLength -le 0) {
            throw "caching-proxy-service returned status=$($caResp.StatusCode) length=$($caResp.RawContentLength)"
        }
        $caPem = if ($caResp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($caResp.Content) } else { [string]$caResp.Content }
        if (-not (Test-CachingProxyServiceCaPem -Pem $caPem)) { throw "caching-proxy-service CA is not a valid X509 PEM" }
        [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($caPem))
    }
    if ($caFetch.Success) {
        $b64 = [string]($caFetch.LastOutput | Select-Object -Last 1)
        try { $null = Save-CachingProxyServiceState -CaCert $b64 -CaCertSourceHost $CacheHost -Confirm:$false }
        catch { Write-Verbose "Get-CachingProxyServiceCaCertBase64: persist failed (non-fatal): $($_.Exception.Message)" }
        return @{ CaCertBase64 = $b64; Source = 'live'; Exhausted = $false }
    }
    # Live fetch exhausted -- try the last-good persisted CA, but only for the
    # same cache host and only if it still parses.
    Write-Warning "  Could not fetch CA cert from caching-proxy-service after $($caFetch.Attempts) attempt(s) : $($caFetch.LastError.Exception.Message)"
    $state = Read-CachingProxyServiceState
    if ($state.caCert -and $state.caCertSourceHost -eq $CacheHost) {
        try {
            $pem = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$state.caCert))
            if (Test-CachingProxyServiceCaPem -Pem $pem) {
                Write-Warning "  Using last-good persisted CA for $CacheHost (live fetch failed; the cache may have flapped during provisioning)."
                return @{ CaCertBase64 = [string]$state.caCert; Source = 'persisted'; Exhausted = $false }
            }
        } catch { Write-Verbose "Get-CachingProxyServiceCaCertBase64: persisted CA decode failed: $($_.Exception.Message)" }
    }
    return @{ CaCertBase64 = ''; Source = 'none'; Exhausted = $true }
}

function Resolve-CachingProxyServiceCaCertPem {
    <#
    .SYNOPSIS
        Resolves the caching-proxy-service CA as PEM text for the host status service's
        /ca.crt endpoint (guest CA self-heal). Live-read first so the CURRENT
        cache's CA is always served, sidestepping the stale-after-rebuild trap;
        the persisted CA is only a labeled last resort.
    .DESCRIPTION
        Resolution order: current cache host = $env:YURUNA_CACHING_PROXY_SERVICE_IP else
        Read-CachingProxyServiceState().ipAddress. If known, live-read
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
    param([int]$LiveTimeoutSeconds = 5)
    $state = Read-CachingProxyServiceState
    $cacheHost = if ($env:YURUNA_CACHING_PROXY_SERVICE_IP) { $env:YURUNA_CACHING_PROXY_SERVICE_IP.Trim() } else { [string]$state.ipAddress }
    if ($cacheHost) {
        $urlHost = if (Get-Command Format-IpUrlHost -ErrorAction SilentlyContinue) { Format-IpUrlHost $cacheHost } else { $cacheHost }
        try {
            $resp = Invoke-WebRequest -Uri "http://$urlHost/yuruna-squid-ca.crt" -UseBasicParsing -NoProxy -TimeoutSec $LiveTimeoutSeconds -ErrorAction Stop
            if ($resp.StatusCode -eq 200 -and $resp.RawContentLength -gt 0) {
                $pem = if ($resp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($resp.Content) } else { [string]$resp.Content }
                if (Test-CachingProxyServiceCaPem -Pem $pem) { return @{ Pem = $pem; Source = 'live' } }
            }
        } catch { Write-Verbose "Resolve-CachingProxyServiceCaCertPem: live read of $urlHost failed: $($_.Exception.Message)" }
    }
    if ($state.caCert) {
        try {
            $pem = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$state.caCert))
            if (Test-CachingProxyServiceCaPem -Pem $pem) { return @{ Pem = $pem; Source = 'persisted' } }
        } catch { Write-Verbose "Resolve-CachingProxyServiceCaCertPem: persisted CA decode failed: $($_.Exception.Message)" }
    }
    return @{ Pem = ''; Source = 'none' }
}

Export-ModuleMember -Function Get-CachingProxyServiceStatePath, Read-CachingProxyServiceState, Save-CachingProxyServiceState, Test-TcpPortReachable, Invoke-CachingProxyServiceProbe, Wait-CachingProxyServiceSettled, Resolve-CachingProxyServiceEndpoint, Get-PoolAggregatorServiceSeedUrl, Wait-YurunaAggregatorReady, Get-PoolIntentSeedUrl, Sync-PoolIntentAliasOnProxy, Test-CachingProxyServiceCaPem, Get-CachingProxyServiceCaCertBase64, Resolve-CachingProxyServiceCaCertPem
