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
    After `utmctl delete`, UTM.app (and its QEMUHelper.xpc subprocess) can
    still hold file handles on the bundle's contents — most commonly on
    the mmap'd sparse disk.img or on efi_vars.fd — for a few seconds.
    A single-shot `Remove-Item -Recurse -Force` during that window fails
    with "Access to the path '…' is denied" even though the bundle is no
    longer registered with UTM and would remove cleanly seconds later.

    This helper retries with 2,4,6,8s backoff (≈20s total), absorbing the
    handle-release race. Returns $true on success (or if the bundle was
    already gone), $false if all retries fail. Callers decide whether to
    treat persistent failure as fatal.

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
            $sleepSec = 2 * $attempt  # 2,4,6,8s
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
    Apple Virtualization.framework's shared-NAT isolates guest↔guest
    traffic on 192.168.64.0/24. Guests can reach the gateway
    (192.168.64.1 = the host) but not another guest's IP — ARP between
    guests is not forwarded. Without a host-side shim, guests cannot
    reach a squid-cache VM at 192.168.64.X and subiquity fails over
    to an offline install.

    Start-CachingProxyForwarder spawns vde/host.macos.utm/Start-CachingProxyForwarder.ps1
    as a detached `pwsh` subprocess that binds :3128 on the host and
    tunnels every connection to $CacheIp:3128. Guests then use
    http://192.168.64.1:3128. The subprocess is detached so the forwarder
    outlives the Start-CachingProxy.ps1 invocation that launched it.

    The PID goes into $HOME/virtual/squid-cache/forwarder.pid.
    Stop-CachingProxyForwarder reads that PID and sends SIGTERM. Get-CachingProxyForwarder
    reports whether the forwarder is up without killing it.

    Returns $true when the forwarder is verified listening on :3128
    (Start), terminated (Stop), or currently running (Get).

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
    # Pidfile/log are PER PORT so concurrent forwarders (one for the
    # squid proxy at :3128, one for the Grafana dashboard at :3000, and
    # potentially more) never fight over the same path. The old single-
    # forwarder scheme used `forwarder.pid`/`forwarder.log`; naming by
    # port makes discovery and selective teardown trivial from
    # Stop-CachingProxyForwarder / Stop-AllCachingProxyForwarder.
    $pidFile = Join-Path $stateDir "forwarder.$Port.pid"
    $logFile = Join-Path $stateDir "forwarder.$Port.log"

    # If a stale pid is still alive for THIS port, kill it first. Other
    # ports' forwarders stay up untouched.
    [void](Stop-CachingProxyForwarder -Port $Port -Quiet)

    Write-Output "  Launching host-side forwarder: 0.0.0.0:${Port} → ${CacheIp}:${Port}"
    # Start-Process launches pwsh detached. RedirectStandard* is required
    # because without them pwsh inherits the parent's TTY and dies when
    # Start-CachingProxy.ps1 exits. The forwarder's own log file gets the
    # live traffic; stdout/stderr go to /dev/null equivalents.
    $procArgs = @(
        '-NoProfile','-NoLogo','-File', $forwarderScript,
        '-CacheIp', $CacheIp,
        '-Port', $Port,
        '-PidFile', $pidFile,
        '-LogFile', $logFile
    )
    try {
        $proc = Start-Process -FilePath 'pwsh' `
            -ArgumentList $procArgs `
            -RedirectStandardOutput "$stateDir/forwarder.stdout.log" `
            -RedirectStandardError  "$stateDir/forwarder.stderr.log" `
            -PassThru
    } catch {
        Write-Warning "Failed to spawn forwarder: $($_.Exception.Message)"
        return $false
    }
    # Wait briefly for the listener to bind and the pidfile to be written.
    # 3s is generous — PowerShell startup plus TcpListener.Start() is sub-second.
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
            # Probe-time connection failure is expected while the child
            # forwarder is still booting (pwsh startup + TcpListener.Start
            # takes a moment). Retry until the deadline below.
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
    Reads $HOME/virtual/squid-cache/forwarder.pid and verifies the PID
    belongs to Start-CachingProxyForwarder.ps1 (via /bin/ps -o command=) before
    signalling — a stale pidfile pointing at an unrelated process must
    NOT be killed. Sends SIGTERM first and waits up to 2 s for the
    process to exit; escalates to SIGKILL if the forwarder doesn't
    respond. The pidfile is removed on either success path and on
    stale-pidfile detection so the next Start-CachingProxyForwarder call
    starts clean.

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
    # Verify the process exists and looks like our forwarder before killing.
    # `/bin/ps -p <pid> -o command=` (path-qualified so PSScriptAnalyzer's
    # PSAvoidUsingCmdletAliases doesn't confuse this with the `ps` alias
    # for Get-Process) prints the full argv so we can confirm it's the
    # Start-CachingProxyForwarder.ps1 we launched — not some unrelated pid that
    # happens to match a stale pidfile.
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
    # /bin/kill for SIGTERM (default). Stop-Process in PowerShell 7 on
    # Unix maps to Process.Kill() which sends SIGKILL unconditionally --
    # bypassing graceful shutdown, so we must invoke the external binary
    # to get the two-phase TERM-then-KILL sequence below.
    & '/bin/kill' $forwarderPid 2>$null | Out-Null
    # Wait for the process to actually exit before declaring success.
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 100
        & '/bin/ps' -p $forwarderPid -o pid= 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
            return $true
        }
    }
    # Didn't die with SIGTERM — escalate.
    if (-not $Quiet) { Write-Warning "Forwarder $forwarderPid did not exit after SIGTERM — sending SIGKILL." }
    & '/bin/kill' -9 $forwarderPid 2>$null | Out-Null
    Start-Sleep -Milliseconds 200
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    return $true
}

<#
.SYNOPSIS
    Reports whether the host-side squid-cache TCP forwarder is running.

.DESCRIPTION
    Pure observer — never signals, never removes files. Returns $true
    iff $HOME/virtual/squid-cache/forwarder.pid exists, parses as an
    int, and refers to a live process (checked via /bin/ps). Does NOT
    verify that the process is actually our Start-CachingProxyForwarder.ps1;
    Stop-CachingProxyForwarder handles that stricter identity check on the
    write path. Callers that only need a liveness hint (status UI,
    should-I-launch-one decisions) can rely on this cheaper check.

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
    and sends SIGTERM to each (SIGKILL escalation via Stop-Squid-
    Forwarder per port). Missing directory / no pidfiles is a no-op.
    Safe to call from Stop-CachingProxy.ps1 even when no forwarders are
    running.

    Cross-platform `Add-CachingProxyPortMap` / `Remove-CachingProxyPortMap`
    (see test/modules/Test.PortMap.psm1) dispatch to Start-CachingProxyForwarder
    + this function on macOS. The high-level symbols live there — only
    platform-specific primitives stay here.

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
    # Glob each forwarder.<N>.pid under the state dir. BaseName strips the
    # trailing ".pid" so the regex just needs to match the middle token.
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
