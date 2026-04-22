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
        [int]$Port = 3128
    )
    $forwarderScript = Join-Path $PSScriptRoot "Start-CachingProxyForwarder.ps1"
    if (-not (Test-Path $forwarderScript)) {
        Write-Warning "Start-CachingProxyForwarder.ps1 not found at: $forwarderScript"
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess("0.0.0.0:${Port} -> ${CacheIp}:${Port}", 'Launch detached host-side TCP forwarder')) {
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

    Write-Output "  Launching host-side forwarder: 0.0.0.0:${Port} → ${CacheIp}:${Port}"
    # RedirectStandard* is required: without them pwsh inherits the
    # parent TTY and dies when Start-CachingProxy.ps1 exits. The
    # forwarder's own log gets live traffic; stdout/stderr go to files.
    $procArgs = @(
        '-NoProfile','-NoLogo','-File', $forwarderScript,
        '-CacheIp', $CacheIp,
        '-Port', $Port,
        '-PidFile', $pidFile,
        '-LogFile', $logFile
    )
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
            -RedirectStandardOutput "$stateDir/forwarder.stdout.log" `
            -RedirectStandardError  "$stateDir/forwarder.stderr.log" `
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
                Write-Output "  Forwarder up (pid $actualPid). Guests should use http://192.168.64.1:${Port}"
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
    $procOwner = (& '/bin/ps' -p $forwarderPid -o 'user=' 2>$null).Trim()
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

Export-ModuleMember -Function Remove-UtmBundleWithRetry, Start-CachingProxyForwarder, Stop-CachingProxyForwarder, Get-CachingProxyForwarder, Stop-AllCachingProxyForwarder
