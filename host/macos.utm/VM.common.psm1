<#PSScriptInfo
.VERSION 0.1
.GUID 42c0ffee-a0de-4e1f-a2b3-c4d5e6f7aa01
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
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
    Removes a UTM .utm bundle from disk with retry-on-EACCES.

.DESCRIPTION
    After `utmctl delete`, UTM.app (and its QEMUHelper.xpc) can hold file
    handles on bundle contents for a few seconds — most commonly on the
    mmap'd sparse disk.img or on efi_vars.fd. A single-shot
    `Remove-Item -Recurse -Force` during that window fails with "Access
    to the path '…' is denied" even though the bundle is deregistered
    and would remove cleanly moments later.

    Retries with 2,4,6,8s backoff (~20s total), absorbing the handle-
    release race. Returns $true on success (or if the bundle was already
    gone), $false if all retries fail.

.PARAMETER Path
    Filesystem path of the .utm bundle directory to remove.

.PARAMETER MaxAttempts
    Number of removal attempts before giving up (default 5).

.OUTPUTS
    [bool] $true on success, $false on persistent failure.
#>
function Remove-UtmBundleWithRetry {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxAttempts = 5
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    if (-not $PSCmdlet.ShouldProcess($Path, "Remove UTM bundle (with up to $MaxAttempts retries)")) {
        return $false
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            if ($attempt -gt 1) {
                Write-Output "Removed UTM bundle after $attempt attempt(s): $Path"
            }
            return $true
        } catch {
            if ($attempt -ge $MaxAttempts) {
                Write-Warning "Failed to remove '$Path' after $MaxAttempts attempts: $($_.Exception.Message)"
                Write-Warning "  This usually means UTM.app or QEMUHelper.xpc still holds file handles"
                Write-Warning "  on the bundle (most commonly the mmap'd disk.img). Check with:"
                Write-Warning "    lsof +D '$Path'"
                Write-Warning "  Quitting UTM.app (pkill -f QEMUHelper ; killall UTM) usually clears it."
                return $false
            }
            $sleepSec = 2 * $attempt
            Write-Warning "Remove-Item attempt $attempt/$MaxAttempts on '$Path' failed: $($_.Exception.Message). Retrying in ${sleepSec}s..."
            Start-Sleep -Seconds $sleepSec
        }
    }
    return $false
}

<#
.SYNOPSIS
    Launches (or stops) the squid-cache TCP forwarder on the Mac host.

.DESCRIPTION
    Apple Virtualization.framework's shared-NAT isolates guest-to-guest
    traffic on 192.168.64.0/24 — guests can reach the gateway
    (192.168.64.1 = the host) but not another guest's IP (ARP between
    guests is not forwarded). Without a host-side shim, guests cannot
    reach a squid-cache VM and subiquity falls back to an offline install.

    Start-CachingProxyForwarder spawns Start-CachingProxyForwarder.ps1
    as a detached `pwsh` subprocess that binds :3128 on the host and
    tunnels to $CacheIp:3128. Guests then use http://192.168.64.1:3128.
    Detached so the forwarder outlives Start-CachingProxy.ps1.

    PID is written to $HOME/virtual/squid-cache/forwarder.<Port>.pid.
    Stop-CachingProxyForwarder reads it and sends SIGTERM.
    Get-CachingProxyForwarder reports liveness without signalling.

    Returns $true when the forwarder is verified listening (Start),
    terminated (Stop), or currently running (Get).

.PARAMETER CacheIp
    IP of the squid-cache VM (Start-CachingProxyForwarder only). Typically
    192.168.64.X discovered by Start-CachingProxy.ps1's subnet probe.
#>
function Start-CachingProxyForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$CacheIp,
        [int]$Port = 3128,
        [int]$VMPort = 0,
        [switch]$PrependProxyV1
    )
    # 0 sentinel — when unspecified, host port == VM port (the common case;
    # proxy/Grafana/etc.). Split ports kick in for SSH (8022 -> 22) and any
    # other future host:VM remap. Pidfile name uses HOST port (predictable;
    # what `lsof -i :<host>` would show).
    if ($VMPort -eq 0) { $VMPort = $Port }
    $forwarderScript = Join-Path $PSScriptRoot "Start-CachingProxyForwarder.ps1"
    if (-not (Test-Path $forwarderScript)) {
        Write-Warning "Start-CachingProxyForwarder.ps1 not found at: $forwarderScript"
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess("0.0.0.0:${Port} -> ${CacheIp}:${VMPort}", 'Launch detached host-side TCP forwarder')) {
        return $false
    }
    $stateDir = Join-Path $HOME "virtual/squid-cache"
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    # Pidfile/log are PER PORT so concurrent forwarders (squid :3128,
    # Grafana :3000, etc.) never fight over the same path. Port-named
    # files make discovery and selective teardown trivial.
    $pidFile = Join-Path $stateDir "forwarder.$Port.pid"
    $logFile = Join-Path $stateDir "forwarder.$Port.log"

    # Kill any stale pid for THIS port first; other ports' forwarders
    # stay up untouched.
    [void](Stop-CachingProxyForwarder -Port $Port -Quiet)

    $proxyTag = if ($PrependProxyV1) { ' [PROXY v1]' } else { '' }
    Write-Output "  Launching host-side forwarder: 0.0.0.0:${Port} → ${CacheIp}:${VMPort}${proxyTag}"
    # RedirectStandard* is required: without them pwsh inherits the
    # parent TTY and dies when Start-CachingProxy.ps1 exits. The
    # forwarder's own log gets live traffic; stdout/stderr go to files.
    $procArgs = @(
        '-NoProfile','-NoLogo','-File', $forwarderScript,
        '-CacheIp', $CacheIp,
        '-Port', $Port,
        '-VMPort', $VMPort,
        '-PidFile', $pidFile,
        '-LogFile', $logFile
    )
    if ($PrependProxyV1) { $procArgs += '-PrependProxyV1' }
    # Ports below 1024 need root on macOS. Spawn via `sudo -E pwsh` when not
    # already root; the caller pre-caches credentials via `sudo -v` so the
    # detached subprocess can bind the port without an interactive tty prompt.
    # sudo exec's pwsh (no fork), so the pidfile PID matches the sudo PID.
    $isRoot = $false
    try { $isRoot = ((& '/usr/bin/id' -u) -eq '0') } catch { Write-Verbose "id -u check failed, assuming non-root: $_" }
    $needsSudo = ($Port -lt 1024) -and (-not $isRoot)

    # If the privileged forwarder is already running (root-owned, started by
    # Start-CachingProxy.ps1 which called `sudo -v` first), leave it alone.
    # Killing a root process requires sudo credentials that the caller
    # (e.g. Invoke-TestRunner) may not have cached — and the correct CacheIp
    # is already baked into the running process. Only restart if crashed.
    if ($needsSudo -and (Get-CachingProxyForwarder -Port $Port)) {
        Write-Output "  Port ${Port} forwarder already running (root-owned); skipping restart."
        return $true
    }

    $spawnFile = if ($needsSudo) { 'sudo' } else { 'pwsh' }
    $spawnArgs = if ($needsSudo) { @('-E', 'pwsh') + $procArgs } else { $procArgs }

    try {
        $proc = Start-Process -FilePath $spawnFile `
            -ArgumentList $spawnArgs `
            -RedirectStandardOutput "$stateDir/forwarder.$Port.stdout.log" `
            -RedirectStandardError  "$stateDir/forwarder.$Port.stderr.log" `
            -PassThru
    } catch {
        Write-Warning "Failed to spawn forwarder: $($_.Exception.Message)"
        return $false
    }
    # Wait briefly for the listener to bind and the pidfile to be written.
    # 3s is generous; pwsh startup + TcpListener.Start() is sub-second.
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline) {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        try {
            $h = $tcp.BeginConnect("127.0.0.1", $Port, $null, $null)
            if ($h.AsyncWaitHandle.WaitOne(150) -and $tcp.Connected) {
                $tcp.Close()
                $actualPid = if (Test-Path $pidFile) { (Get-Content $pidFile -Raw).Trim() } else { $proc.Id }
                $upMsg = if ($Port -eq $VMPort) {
                    "Forwarder up (pid $actualPid). Guests should use http://192.168.64.1:${Port}"
                } else {
                    "Forwarder up (pid $actualPid): host :${Port} -> ${CacheIp}:${VMPort}"
                }
                Write-Output "  $upMsg"
                return $true
            }
        } catch {
            # Expected while the child is still booting (pwsh startup +
            # TcpListener.Start). Retry until the deadline.
            $null = $_
        } finally { $tcp.Close() }
        Start-Sleep -Milliseconds 100
    }
    Write-Warning "Forwarder launched (pid $($proc.Id)) but :${Port} did not answer within 3s."
    Write-Warning "  Check $stateDir/forwarder.stderr.log and forwarder.log"
    return $false
}

<#
.SYNOPSIS
    Terminates the host-side squid-cache TCP forwarder if it is running.

.DESCRIPTION
    Reads $HOME/virtual/squid-cache/forwarder.<Port>.pid and verifies the
    PID belongs to Start-CachingProxyForwarder.ps1 (via /bin/ps -o
    command=) before signalling — a stale pidfile pointing at an
    unrelated process must NOT be killed. Sends SIGTERM and waits up to
    2s; escalates to SIGKILL if no response. The pidfile is removed on
    every success path and on stale-pidfile detection so the next Start
    call is clean.

.PARAMETER Quiet
    Suppress the informational Write-Output lines. Start-CachingProxyForwarder
    passes this when preflight-stopping a stale forwarder so the happy
    path stays quiet.

.OUTPUTS
    [bool] $true on any exit where the pidfile is in a coherent state
    (process stopped or never running). No current failure modes
    surface as $false.
#>
function Stop-CachingProxyForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [int]$Port = 3128,
        [switch]$Quiet
    )
    $pidFile = Join-Path $HOME "virtual/squid-cache/forwarder.$Port.pid"
    if (-not (Test-Path $pidFile)) {
        if (-not $Quiet) { Write-Output "  No forwarder pidfile — nothing to stop." }
        return $true
    }
    $forwarderPid = (Get-Content $pidFile -Raw).Trim()
    if (-not ($forwarderPid -as [int])) {
        if (-not $Quiet) { Write-Warning "Pidfile '$pidFile' contents invalid: '$forwarderPid' — removing." }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    # Verify the process looks like our forwarder before killing.
    # `/bin/ps` path-qualified so PSScriptAnalyzer's PSAvoidUsingCmdletAliases
    # doesn't confuse it with the `ps` alias for Get-Process. -o command=
    # prints full argv so we can match Start-CachingProxyForwarder.ps1 and
    # avoid killing an unrelated pid that matches a stale pidfile.
    $cmd = (& '/bin/ps' -p $forwarderPid -o command= 2>$null) -join ""
    if ($LASTEXITCODE -ne 0 -or -not $cmd) {
        if (-not $Quiet) { Write-Output "  Forwarder pid $forwarderPid not running — cleaning pidfile." }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    if ($cmd -notmatch 'Start-CachingProxyForwarder\.ps1') {
        if (-not $Quiet) { Write-Warning "Pid $forwarderPid is not Start-CachingProxyForwarder.ps1 (is: $cmd) — leaving alone, removing stale pidfile." }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess("pid $forwarderPid (Start-CachingProxyForwarder.ps1)", 'SIGTERM then SIGKILL if needed')) {
        return $false
    }
    if (-not $Quiet) { Write-Output "  Stopping forwarder (pid $forwarderPid)..." }
    # /bin/kill sends SIGTERM (default). PowerShell 7's Stop-Process on
    # Unix maps to Process.Kill() == SIGKILL unconditionally, bypassing
    # graceful shutdown — hence the external binary for TERM-then-KILL.
    # Port 80's forwarder is root-owned (spawned via sudo); a regular user
    # cannot signal it — detect and escalate via sudo kill if needed.
    $procOwner = "$( & '/bin/ps' -p $forwarderPid -o 'user=' 2>$null )".Trim()
    $meIsRoot  = $false
    try { $meIsRoot = ((& '/usr/bin/id' -u) -eq '0') } catch { Write-Verbose "id -u check failed, assuming non-root: $_" }
    $useSudo   = ($procOwner -eq 'root') -and (-not $meIsRoot)
    if ($useSudo) {
        & sudo '/bin/kill' $forwarderPid 2>$null | Out-Null
    } else {
        & '/bin/kill' $forwarderPid 2>$null | Out-Null
    }
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 100
        & '/bin/ps' -p $forwarderPid -o pid= 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
            return $true
        }
    }
    if (-not $Quiet) { Write-Warning "Forwarder $forwarderPid did not exit after SIGTERM — sending SIGKILL." }
    if ($useSudo) {
        & sudo '/bin/kill' -9 $forwarderPid 2>$null | Out-Null
    } else {
        & '/bin/kill' -9 $forwarderPid 2>$null | Out-Null
    }
    Start-Sleep -Milliseconds 200
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    return $true
}

<#
.SYNOPSIS
    Reports whether the host-side squid-cache TCP forwarder is running.

.DESCRIPTION
    Pure observer — never signals, never removes files. Returns $true
    iff $HOME/virtual/squid-cache/forwarder.<Port>.pid exists, parses as
    an int, and refers to a live process (via /bin/ps). Does NOT verify
    the process is actually our forwarder; Stop-CachingProxyForwarder
    handles that stricter identity check on the write path.

.OUTPUTS
    [bool] $true if the pidfile points at a live process, $false
    otherwise (missing pidfile, malformed content, or dead pid).
#>
function Get-CachingProxyForwarder {
    [CmdletBinding()]
    [OutputType([bool])]
    param([int]$Port = 3128)
    $pidFile = Join-Path $HOME "virtual/squid-cache/forwarder.$Port.pid"
    if (-not (Test-Path $pidFile)) { return $false }
    $forwarderPid = (Get-Content $pidFile -Raw).Trim()
    if (-not ($forwarderPid -as [int])) { return $false }
    & '/bin/ps' -p $forwarderPid -o pid= 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS
    Stop every squid-cache port forwarder the host currently has.

.DESCRIPTION
    Enumerates $HOME/virtual/squid-cache/forwarder.<Port>.pid entries
    and sends SIGTERM to each (SIGKILL escalation per port via
    Stop-CachingProxyForwarder). Missing directory / no pidfiles is a
    no-op; safe to call even when nothing is running.

    Cross-platform `Add-CachingProxyPortMap` / `Remove-CachingProxyPortMap`
    (test/modules/Test.PortMap.psm1) dispatch to
    Start-CachingProxyForwarder + this function on macOS. High-level
    symbols live there; only platform primitives stay here.

.OUTPUTS
    [int[]] — ports whose forwarder was stopped (may be empty).
#>
function Stop-AllCachingProxyForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int[]], [System.Object[]])]
    param([switch]$Quiet)
    $stateDir = Join-Path $HOME "virtual/squid-cache"
    if (-not (Test-Path $stateDir)) { return @() }
    $stopped = @()
    # Glob forwarder.<N>.pid; BaseName strips ".pid" so the regex only
    # needs the middle token.
    Get-ChildItem -LiteralPath $stateDir -Filter 'forwarder.*.pid' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.BaseName -match '^forwarder\.(\d+)$') {
                $portInt = [int]$matches[1]
                if ($PSCmdlet.ShouldProcess("port $portInt", 'Stop squid forwarder')) {
                    [void](Stop-CachingProxyForwarder -Port $portInt -Quiet:$Quiet)
                    $stopped += $portInt
                }
            }
        }
    return ,$stopped
}

<#
.SYNOPSIS
    Returns the host's IP address as reachable from a UTM Apple Virtualization guest.

.DESCRIPTION
    On Apple Virtualization shared NAT (the default UTM networking mode for
    this repo), guests always reach the host at 192.168.64.1 — that is the
    VZ gateway IP set by the framework, not configurable per VM. The same
    constant is hardcoded as the squid-cache forwarder URL in
    guest.ubuntu.server/New-VM.ps1, by long convention.

    Bridged networking (not the repo default) would route guests via the
    host's LAN IP instead. If/when that mode is added, this helper needs a
    mode-detection branch.

.OUTPUTS
    [string] '192.168.64.1' — the VZ gateway address.
#>
function Get-GuestReachableHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return '192.168.64.1'
}

<#
.SYNOPSIS
    Returns $true when $BaseImageFile already matches what we'd
    download from $SourceUrl, so the caller can skip the transfer.

.DESCRIPTION
    Three conditions, all required:
      1. $BaseImageFile exists on disk.
      2. $OriginFile (the sentinel a previous successful run wrote
         next to $BaseImageFile) records the same $SourceUrl on its
         second line AND a positive byte count on its third line.
      3. A fresh HEAD probe of $SourceUrl returns a Content-Length
         that exactly equals the recorded byte count.

    Sentinels missing the third line (older script versions that
    only wrote name + URL) fall through to $false so the caller
    re-downloads -- graceful upgrade with no "force" flag needed.

    HEAD failure (offline, 4xx, no Content-Length, mirror redirect
    that strips the header, etc.) returns $false too, so the caller
    falls through to the regular download path rather than skipping
    silently on a transient error.

    Forcing a re-download is intentionally not a parameter here:
    the operator deletes or renames $BaseImageFile (or $OriginFile),
    which makes condition #1 or #2 fail. Keeping it filesystem-only
    means there is exactly one way to override and it survives a
    crashed/aborted prior run with no extra cleanup.

.PARAMETER SourceUrl
    URL the caller has resolved as the download target.

.PARAMETER BaseImageFile
    Final on-disk path of the image (e.g. *.iso, *.qcow2, *.raw).

.PARAMETER OriginFile
    Sentinel path -- typically "$baseImageName.txt" next to
    $BaseImageFile. Lines: [0] original filename, [1] source URL,
    [2] byte count of the downloaded source.

.OUTPUTS
    [bool]
#>
function Test-DownloadAlreadyCurrent {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$SourceUrl,
        [Parameter(Mandatory)][string]$BaseImageFile,
        [Parameter(Mandatory)][string]$OriginFile
    )
    if (-not (Test-Path -LiteralPath $BaseImageFile)) { return $false }
    if (-not (Test-Path -LiteralPath $OriginFile))    { return $false }

    $lines = @(Get-Content -LiteralPath $OriginFile -ErrorAction SilentlyContinue)
    if ($lines.Count -lt 3) { return $false }
    if ($lines[1].Trim() -ne $SourceUrl) { return $false }
    $previousSize = 0L
    if (-not [int64]::TryParse($lines[2].Trim(), [ref]$previousSize)) { return $false }
    if ($previousSize -le 0) { return $false }

    try {
        $head = Invoke-WebRequest -Uri $SourceUrl -Method Head -ErrorAction Stop
    } catch {
        Write-Verbose "HEAD probe of $SourceUrl failed: $($_.Exception.Message)"
        return $false
    }
    $cl = $head.Headers['Content-Length']
    if ($cl -is [System.Array]) { $cl = $cl[0] }
    $expectedSize = 0L
    if (-not [int64]::TryParse([string]$cl, [ref]$expectedSize)) { return $false }
    return ($expectedSize -eq $previousSize)
}

<#
.SYNOPSIS
    Async TCP port probe with bounded wait. $true when $IpAddress:$Port
    accepts within $TimeoutMs.

.DESCRIPTION
    BeginConnect+WaitOne caps the wait predictably; synchronous
    TcpClient.Connect() blocks ~20s on a filtered/dropped port.
    Same shape as host.windows.hyper-v\VM.common.psm1's
    Test-CachingProxyPort, copied here so the macOS module stays
    self-contained.
#>
function Test-CacheTcpPort {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 500
    )
    $tcp = [System.Net.Sockets.TcpClient]::new()
    try {
        $h = $tcp.BeginConnect($IpAddress, $Port, $null, $null)
        return ($h.AsyncWaitHandle.WaitOne($TimeoutMs) -and $tcp.Connected)
    } catch {
        Write-Verbose "Test-CacheTcpPort ${IpAddress}:${Port} failed: $($_.Exception.Message)"
        return $false
    } finally {
        $tcp.Close()
    }
}

<#
.SYNOPSIS
    Returns the IP of a reachable squid-cache (probed on :3128), or
    $null when no cache is currently usable. Prefers the direct VM IP
    so SSL-bump (:3129) and the CA endpoint (:80) are also reachable;
    falls back to 127.0.0.1 (host forwarder) for HTTP-only.

.DESCRIPTION
    Discovery order:
      1. $HOME/virtual/squid-cache/cache-ip.txt -- written by
         Start-CachingProxy.ps1 with the VM's 192.168.64.X address.
         If reachable, return THIS IP; the caller can hit :80 / :3128
         / :3129 on it directly across Apple Virtualization shared NAT.
      2. 127.0.0.1 -- the local Start-CachingProxyForwarder bridges
         host:3128 -> VM:3128. Useful for HTTP origins; SSL-bump
         (:3129) won't work via the forwarder since only :3128 is
         bridged. Save-CachedHttpUri detects that case via separate
         :3129 probes and falls through to direct download.
.OUTPUTS
    [string] IPv4 like '192.168.64.5' or '127.0.0.1', or $null.
#>
function Resolve-CacheHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $cacheIpFile = Join-Path $HOME "virtual/squid-cache/cache-ip.txt"
    if (Test-Path -LiteralPath $cacheIpFile) {
        $ip = (Get-Content -LiteralPath $cacheIpFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($ip -match '^\d+\.\d+\.\d+\.\d+$' -and (Test-CacheTcpPort -IpAddress $ip -Port 3128 -TimeoutMs 500)) {
            return $ip
        }
    }
    if (Test-CacheTcpPort -IpAddress '127.0.0.1' -Port 3128 -TimeoutMs 500) {
        return '127.0.0.1'
    }
    return $null
}

<#
.SYNOPSIS
    Resolves the right squid endpoint for $Uri: HTTP through :3128 or
    SSL-bumped HTTPS through :3129 with a freshly-fetched yuruna CA,
    or $null when going direct is the only viable option.

.DESCRIPTION
    Output is a hashtable consumed by Save-CachedHttpUri:

        @{ Proxy = 'http://<ip>:3128'; CaPemPath = $null }
            HTTP origin: route through squid; no extra trust needed.

        @{ Proxy = 'http://<ip>:3129'; CaPemPath = '<temp>.pem' }
            HTTPS origin AND :3129 + :80 reachable AND
            http://<ip>/yuruna-squid-ca.crt fetched OK. Caller passes
            the PEM path to Invoke-HttpsViaSquidBump's per-process
            HttpClient handler -- system trust store stays untouched.

        $null
            Cache not running, ports unreachable, or CA fetch failed.
            Caller goes direct (still safer than forcing a dead proxy).

    The CA is regenerated on every cache VM rebuild
    (`openssl req -x509 ... CN=yuruna-squid-cache <hostname> <utc>` in
    user-data runcmd), so we always re-fetch -- no stable thumbprint
    to pin out-of-band. Trust is bootstrapped over plain HTTP from the
    cache itself, which is the same trust assumption the rest of the
    yuruna LAN-side workflow makes.
.PARAMETER Uri
    The download URL the caller is about to fetch.
.OUTPUTS
    [hashtable] or $null.
#>
function Get-CacheProxyForHostDownload {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Uri)

    $scheme = ([System.Uri]$Uri).Scheme.ToLowerInvariant()
    if ($scheme -ne 'http' -and $scheme -ne 'https') {
        Write-Verbose "Get-CacheProxyForHostDownload: scheme '$scheme' not http(s); going direct."
        return $null
    }

    $cacheIp = Resolve-CacheHostIp
    if (-not $cacheIp) {
        Write-Verbose "Get-CacheProxyForHostDownload: no squid cache reachable on :3128; going direct."
        return $null
    }

    if ($scheme -eq 'http') {
        return @{ Proxy = "http://${cacheIp}:3128"; CaPemPath = $null }
    }

    # HTTPS via SSL-bump on :3129 -- needs the apache CA endpoint on :80
    # AND the SSL-bump listener on :3129. Probe both before committing.
    if (-not (Test-CacheTcpPort -IpAddress $cacheIp -Port 3129 -TimeoutMs 500)) {
        Write-Verbose "Get-CacheProxyForHostDownload: squid :3129 not reachable on $cacheIp; HTTPS goes direct."
        return $null
    }
    if (-not (Test-CacheTcpPort -IpAddress $cacheIp -Port 80 -TimeoutMs 500)) {
        Write-Verbose "Get-CacheProxyForHostDownload: apache :80 not reachable on $cacheIp (cannot fetch CA); HTTPS goes direct."
        return $null
    }
    $caUrl = "http://${cacheIp}/yuruna-squid-ca.crt"
    $caPem = Join-Path ([System.IO.Path]::GetTempPath()) 'yuruna-squid-ca.pem'
    try {
        Invoke-WebRequest -Uri $caUrl -OutFile $caPem -ErrorAction Stop -UseBasicParsing | Out-Null
    } catch {
        Write-Verbose "Get-CacheProxyForHostDownload: CA fetch from $caUrl failed: $($_.Exception.Message); HTTPS goes direct."
        return $null
    }
    return @{ Proxy = "http://${cacheIp}:3129"; CaPemPath = $caPem }
}

<#
.SYNOPSIS
    Downloads $Uri to $OutFile, transparently routing through the
    squid cache (HTTP via :3128 or SSL-bumped HTTPS via :3129) when
    one is reachable. Throws on failure.

.DESCRIPTION
    Single entry point used by every host-side Get-Image.ps1 in
    place of Invoke-WebRequest -OutFile. Three paths:

      1. No cache reachable, or unsupported scheme -> falls through to
         Invoke-WebRequest direct. Same behavior the scripts had
         before any squid wiring existed.

      2. HTTP origin + cache reachable -> Invoke-WebRequest with
         -Proxy http://<cache>:3128. Standard CONNECT-less HTTP
         proxying; squid caches per the snapshot-cache config.

      3. HTTPS origin + cache reachable + SSL-bump usable -> custom
         HttpClient with proxy http://<cache>:3129 and a per-call
         ServerCertificateCustomValidationCallback that trusts ONLY
         the freshly-fetched yuruna CA on top of the system roots.
         The OS trust store is never modified; the trust closes when
         this PowerShell process exits.

    Throwing model: any underlying exception (TLS failure, HTTP non-
    2xx, write error, etc.) propagates to the caller's try/catch,
    same as Invoke-WebRequest -ErrorAction Stop.
.PARAMETER Uri
    Source URL.
.PARAMETER OutFile
    Destination file path; overwritten if it exists.
#>
function Save-CachedHttpUri {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    $cfg = Get-CacheProxyForHostDownload -Uri $Uri
    if (-not $cfg) {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -ErrorAction Stop
        return
    }
    if (-not $cfg.CaPemPath) {
        Write-Output "Routing download through squid cache: $($cfg.Proxy)"
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -Proxy $cfg.Proxy -ErrorAction Stop
        return
    }
    Write-Output "Routing HTTPS download through squid SSL-bump: $($cfg.Proxy) (per-process trust of yuruna CA at $($cfg.CaPemPath))"
    Invoke-HttpsViaSquidBump -Uri $Uri -OutFile $OutFile -ProxyUrl $cfg.Proxy -CaPemPath $cfg.CaPemPath
}

<#
.SYNOPSIS
    Internal: HTTPS GET through a squid SSL-bump listener with a
    per-process custom CA trust. Invoke via Save-CachedHttpUri.

.DESCRIPTION
    Why HttpClient and not Invoke-WebRequest:

    PowerShell 7's Invoke-WebRequest exposes -SkipCertificateCheck
    (accept ANY cert -- too loose) and accepts no custom server-cert
    callback. Modern .NET HttpClient with HttpClientHandler does
    expose ServerCertificateCustomValidationCallback, which lets us
    accept yuruna-CA-signed leaves WITHOUT touching the OS trust
    store and WITHOUT skipping name validation.

    Validation policy: defer to the OS for everything except a chain
    error. On a chain error (the expected case for squid SSL-bumped
    leaves, since yuruna CA isn't a public root), rebuild the chain
    with the yuruna CA in ExtraStore and AllowUnknownCertificateAuthority,
    then require the chain to terminate at a root whose thumbprint
    matches our CA. Name mismatches and missing-cert errors still
    fail closed.

    Progress: Write-Progress every 2s with bytes/MB and percent when
    Content-Length is known; honors $ProgressPreference (the test
    runner sets it to SilentlyContinue, so the runner's HTML log
    stays clean).
#>
function Invoke-HttpsViaSquidBump {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][string]$ProxyUrl,
        [Parameter(Mandatory)][string]$CaPemPath
    )
    # X509Certificate2::CreateFromPemFile expects cert+key in the same
    # file; the yuruna-squid-ca.crt published by the cache is cert-only.
    # The ctor auto-detects PEM/DER/PFX and works for cert-only PEM.
    $extraCa = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CaPemPath)
    $expectedThumb = $extraCa.Thumbprint

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $true
    $handler.Proxy = [System.Net.WebProxy]::new([System.Uri]$ProxyUrl, $true)
    $handler.ServerCertificateCustomValidationCallback = {
        param($req, $cert, $chain, $errors)
        # $req (HttpRequestMessage) and $chain (the system-built chain)
        # are part of the delegate signature but unused by our policy --
        # we make our own chain below seeded with the yuruna CA. Touching
        # them as $null = ... silences PSReviewUnusedParameter without
        # changing the delegate's contract.
        $null = $req; $null = $chain
        if (($errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNotAvailable) -ne 0) { return $false }
        if (($errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch) -ne 0) { return $false }
        if (($errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors) -eq 0) { return $true }
        $extraChain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
        [void]$extraChain.ChainPolicy.ExtraStore.Add($extraCa)
        $extraChain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $extraChain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
        if (-not $extraChain.Build($cert)) { return $false }
        $root = $extraChain.ChainElements[$extraChain.ChainElements.Count - 1].Certificate
        return ($root.Thumbprint -eq $expectedThumb)
    }.GetNewClosure()

    $client = [System.Net.Http.HttpClient]::new($handler, $true)
    # 4 GB at ~50 MB/s LAN cache = ~80s; HTTP/SSL handshake + cold cache
    # populate from origin can stretch this. Generous timeout vs. the
    # default 100s which would abort mid-fetch on a cold ISO pull.
    $client.Timeout = [TimeSpan]::FromHours(2)
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, [System.Uri]$Uri)
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) {
                throw "HTTP $([int]$response.StatusCode) $($response.ReasonPhrase) for $Uri"
            }
            $total = $response.Content.Headers.ContentLength
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            try {
                $out = [System.IO.File]::Create($OutFile)
                try {
                    $buf = [byte[]]::new(64 * 1024)
                    $written = 0L
                    $next = [DateTime]::UtcNow.AddSeconds(2)
                    $activity = "Downloading $Uri (via squid SSL-bump)"
                    while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                        $out.Write($buf, 0, $n)
                        $written += $n
                        if ([DateTime]::UtcNow -gt $next) {
                            if ($total) {
                                $pct = [math]::Round($written * 100.0 / $total, 1)
                                Write-Progress -Activity $activity -Status ("{0:N1} / {1:N1} MB ({2}%)" -f ($written/1MB), ($total/1MB), $pct) -PercentComplete $pct
                            } else {
                                Write-Progress -Activity $activity -Status ("{0:N1} MB" -f ($written/1MB))
                            }
                            $next = [DateTime]::UtcNow.AddSeconds(2)
                        }
                    }
                } finally { $out.Dispose() }
            } finally { $stream.Dispose() }
            Write-Progress -Activity $activity -Completed
        } finally { $response.Dispose() }
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

Export-ModuleMember -Function Remove-UtmBundleWithRetry, Start-CachingProxyForwarder, Stop-CachingProxyForwarder, Get-CachingProxyForwarder, Stop-AllCachingProxyForwarder, Get-GuestReachableHostIp, Test-DownloadAlreadyCurrent, Test-CacheTcpPort, Resolve-CacheHostIp, Get-CacheProxyForHostDownload, Save-CachedHttpUri, Invoke-HttpsViaSquidBump
