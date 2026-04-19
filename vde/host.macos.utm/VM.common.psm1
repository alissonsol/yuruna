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

    Start-SquidForwarder spawns vde/host.macos.utm/Start-SquidForwarder.ps1
    as a detached `pwsh` subprocess that binds :3128 on the host and
    tunnels every connection to $CacheIp:3128. Guests then use
    http://192.168.64.1:3128. The subprocess is detached so the forwarder
    outlives the Start-SquidCache.ps1 invocation that launched it.

    The PID goes into $HOME/virtual/squid-cache/forwarder.pid.
    Stop-SquidForwarder reads that PID and sends SIGTERM. Get-SquidForwarder
    reports whether the forwarder is up without killing it.

    Returns $true when the forwarder is verified listening on :3128
    (Start), terminated (Stop), or currently running (Get).

.PARAMETER CacheIp
    IP of the squid-cache VM (Start-SquidForwarder only). Typically
    192.168.64.X discovered by Start-SquidCache.ps1's subnet probe.
#>
function Start-SquidForwarder {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$CacheIp,
        [int]$Port = 3128
    )
    $forwarderScript = Join-Path $PSScriptRoot "Start-SquidForwarder.ps1"
    if (-not (Test-Path $forwarderScript)) {
        Write-Warning "Start-SquidForwarder.ps1 not found at: $forwarderScript"
        return $false
    }
    $stateDir = Join-Path $HOME "virtual/squid-cache"
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    $pidFile = Join-Path $stateDir "forwarder.pid"
    $logFile = Join-Path $stateDir "forwarder.log"

    # If a stale pid is still alive, kill it first — we want a single
    # forwarder per host.
    [void](Stop-SquidForwarder -Quiet)

    Write-Output "  Launching host-side forwarder: 0.0.0.0:${Port} → ${CacheIp}:${Port}"
    # Start-Process launches pwsh detached. RedirectStandard* is required
    # because without them pwsh inherits the parent's TTY and dies when
    # Start-SquidCache.ps1 exits. The forwarder's own log file gets the
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
        } catch { } finally { $tcp.Close() }
        Start-Sleep -Milliseconds 100
    }
    Write-Warning "Forwarder launched (pid $($proc.Id)) but :${Port} did not answer within 3s."
    Write-Warning "  Check $stateDir/forwarder.stderr.log and forwarder.log"
    return $false
}

function Stop-SquidForwarder {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [switch]$Quiet
    )
    $pidFile = Join-Path $HOME "virtual/squid-cache/forwarder.pid"
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
    # `ps -p <pid> -o comm=` prints the short process name; `ps -p <pid> -o command=`
    # (full argv) lets us confirm it's the Start-SquidForwarder.ps1 we launched
    # and not some unrelated pid that happens to match a stale pidfile.
    $cmd = (& ps -p $forwarderPid -o command= 2>$null) -join ""
    if ($LASTEXITCODE -ne 0 -or -not $cmd) {
        if (-not $Quiet) { Write-Output "  Forwarder pid $forwarderPid not running — cleaning pidfile." }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    if ($cmd -notmatch 'Start-SquidForwarder\.ps1') {
        if (-not $Quiet) { Write-Warning "Pid $forwarderPid is not Start-SquidForwarder.ps1 (is: $cmd) — leaving alone, removing stale pidfile." }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    if (-not $Quiet) { Write-Output "  Stopping forwarder (pid $forwarderPid)..." }
    & kill $forwarderPid 2>$null | Out-Null
    # Wait for the process to actually exit before declaring success.
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 100
        & ps -p $forwarderPid -o pid= 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
            return $true
        }
    }
    # Didn't die with SIGTERM — escalate.
    if (-not $Quiet) { Write-Warning "Forwarder $forwarderPid did not exit after SIGTERM — sending SIGKILL." }
    & kill -9 $forwarderPid 2>$null | Out-Null
    Start-Sleep -Milliseconds 200
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    return $true
}

function Get-SquidForwarder {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $pidFile = Join-Path $HOME "virtual/squid-cache/forwarder.pid"
    if (-not (Test-Path $pidFile)) { return $false }
    $forwarderPid = (Get-Content $pidFile -Raw).Trim()
    if (-not ($forwarderPid -as [int])) { return $false }
    & ps -p $forwarderPid -o pid= 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

Export-ModuleMember -Function Remove-UtmBundleWithRetry, Start-SquidForwarder, Stop-SquidForwarder, Get-SquidForwarder
