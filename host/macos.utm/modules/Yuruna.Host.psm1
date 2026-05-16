<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e91
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host macos utm
.LICENSEURI https://yuruna.com
.PROJECTURI https://yuruna.com
.RELEASENOTES
    Yuruna host driver for macOS + UTM. Implements the contract
    documented in host/ubuntu.kvm/modules/Yuruna.Host.psm1.
#>

#requires -version 7

<#
.SYNOPSIS
    Yuruna host driver for macOS + UTM (Apple Silicon and Intel).

.DESCRIPTION
    Self-contained host driver: contract surface plus the UTM/macOS
    helpers (formerly host/macos.utm/modules/Yuruna.Host.psm1) it consumes.
    Cross-host helpers still live in test/modules/Test.VM.common.psm1
    and Test.Ssh.psm1, imported below.
#>

# === Module setup ===========================================================

$script:HostTag        = 'host.macos.utm'
$script:RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:TestModulesDir = Join-Path $script:RepoRoot 'test/modules'
$script:HostFolder     = Join-Path $script:RepoRoot 'host/macos.utm'

Import-Module (Join-Path $script:TestModulesDir 'Test.VM.common.psm1')    -Force -DisableNameChecking
Import-Module (Join-Path $script:TestModulesDir 'Test.Ssh.psm1')          -Force -DisableNameChecking
Import-Module (Join-Path $script:TestModulesDir 'Test.CachingProxy.psm1') -Force -DisableNameChecking
# === Helpers lifted from former Yuruna.Host.psm1 (host/macos.utm) ============

<#
.SYNOPSIS
    Removes a UTM .utm bundle from disk with retry-on-EACCES.

.DESCRIPTION
    After `utmctl delete`, UTM.app (and its QEMUHelper.xpc) can hold file
    handles on bundle contents for a few seconds ? most commonly on the
    mmap'd sparse disk.img or on efi_vars.fd. A single-shot
    `Remove-Item -Recurse -Force` during that window fails with "Access
    to the path '?' is denied" even though the bundle is deregistered
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
    Compiles, self-signs, and runs an embedded Swift helper that uses the
    Virtualization framework.

.DESCRIPTION
    The Virtualization framework's restore-image and installer APIs
    (VZMacOSRestoreImage.fetchLatestSupported, VZMacOSRestoreImage.load,
    VZMacOSInstaller.install) only connect to the system installation
    service when the calling binary carries the
    `com.apple.security.virtualization` entitlement.

    Running a helper via the `swift <file>` interpreter produces an
    ad-hoc-signed binary with NO entitlements, so every one of those
    calls fails with VZErrorDomain "Unable to connect to installation
    service" (code 10004 for load, 10001 for the catalog fetch).

    This helper does the entitled equivalent:
      1. writes $Source to a real `.swift` file (swiftc keys off the
         extension; New-TemporaryFile's `.tmp` would be rejected),
      2. compiles it with `swiftc`,
      3. self-signs the executable with an entitlements plist granting
         `com.apple.security.virtualization` (ad-hoc `-` identity -- the
         entitlement needs no provisioning profile on macOS),
      4. runs it with $ArgumentList, merging stderr into stdout the same
         way `& swift ... 2>&1` did.

    Each merged output line is surfaced live as the helper produces it
    (the pipeline streams object-by-object) AND collected into the return
    value. By default a line is echoed via
    Write-Information -InformationAction Continue; pass -LineHandler to
    intercept instead -- e.g. New-VM.ps1 routes the 15-25 min restore's
    "Restore progress: N%" lines into a Write-Progress bar.

    On compile or codesign failure the diagnostic text is returned and
    $LASTEXITCODE is left non-zero (set by swiftc/codesign), so callers
    keep the existing `if ($LASTEXITCODE -ne 0)` pattern unchanged. On
    success $LASTEXITCODE reflects the helper binary's own exit code.

.PARAMETER Source
    Swift source text to compile and run.

.PARAMETER ArgumentList
    Arguments passed to the compiled helper binary.

.PARAMETER LineHandler
    Optional scriptblock invoked once per merged output line, with the
    line (a string) as its single argument. When supplied it replaces the
    default Write-Information echo; the line is still added to the return
    value either way.
#>
function Invoke-EntitledSwift {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [string[]]$ArgumentList = @(),
        [scriptblock]$LineHandler
    )

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-vzswift-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    try {
        $srcFile = Join-Path $tmpDir 'helper.swift'
        $exeFile = Join-Path $tmpDir 'helper'
        $entFile = Join-Path $tmpDir 'vz.entitlements'
        Set-Content -LiteralPath $srcFile -Value $Source

        $compileOut = & swiftc $srcFile -o $exeFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @('swiftc compile failed:') + $compileOut
        }

        Set-Content -LiteralPath $entFile -Value @'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.virtualization</key>
    <true/>
</dict>
</plist>
'@

        $signOut = & codesign --force --sign - --entitlements $entFile $exeFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @('codesign (com.apple.security.virtualization) failed:') + $signOut
        }

        # Surface each line as the helper produces it (the pipeline streams
        # object-by-object) and also emit it as the function's return
        # value. -LineHandler, when given, takes over the live display.
        return (& $exeFile @ArgumentList 2>&1 | ForEach-Object {
            $line = [string]$_
            if ($LineHandler) { & $LineHandler $line }
            else { Write-Information $line -InformationAction Continue }
            $line
        })
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Launches (or stops) the squid-cache TCP forwarder on the Mac host.

.DESCRIPTION
    Apple Virtualization.framework's shared-NAT isolates guest-to-guest
    traffic on 192.168.64.0/24 ? guests can reach the gateway
    (192.168.64.1 = the host) but not another guest's IP (ARP between
    guests is not forwarded). Without a host-side shim, guests cannot
    reach a squid-cache VM and subiquity falls back to an offline install.

    Start-CachingProxyForwarder spawns Start-CachingProxyForwarder.ps1
    as a detached `pwsh` subprocess that binds :3128 on the host and
    tunnels to $CacheIp:3128. Guests then use http://192.168.64.1:3128.
    Detached so the forwarder outlives Start-CachingProxy.ps1.

    PID is written to $HOME/yuruna/image/squid-cache/forwarder.<Port>.pid.
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
        [int]$Port = $(Get-CachingProxyPort -Scheme http),
        [int]$VMPort = 0,
        [switch]$PrependProxyV1
    )
    # 0 sentinel ? when unspecified, host port == VM port (the common case;
    # proxy/Grafana/etc.). Split ports kick in for SSH (8022 -> 22) and any
    # other future host:VM remap. Pidfile name uses HOST port (predictable;
    # what `lsof -i :<host>` would show).
    if ($VMPort -eq 0) { $VMPort = $Port }
    # Forwarder script lives at host/macos.utm/Start-CachingProxyForwarder.ps1.
    # Use $script:HostFolder (set at module load) instead of $PSScriptRoot:
    # the module-scoped variable is anchored to the .psm1's directory, so
    # the lookup is independent of how the function is dispatched.
    $forwarderScript = Join-Path $script:HostFolder "Start-CachingProxyForwarder.ps1"
    if (-not (Test-Path $forwarderScript)) {
        Write-Warning "Start-CachingProxyForwarder.ps1 not found at: $forwarderScript"
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess("0.0.0.0:${Port} -> ${CacheIp}:${VMPort}", 'Launch detached host-side TCP forwarder')) {
        return $false
    }
    $stateDir = Join-Path $HOME "yuruna/image/squid-cache"
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
    Write-Output "  Launching host-side forwarder: 0.0.0.0:${Port} ? ${CacheIp}:${VMPort}${proxyTag}"
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
    # (e.g. Invoke-TestRunner) may not have cached ? and the correct CacheIp
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
    Reads $HOME/yuruna/image/squid-cache/forwarder.<Port>.pid and verifies the
    PID belongs to Start-CachingProxyForwarder.ps1 (via /bin/ps -o
    command=) before signalling ? a stale pidfile pointing at an
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
        [int]$Port = $(Get-CachingProxyPort -Scheme http),
        [switch]$Quiet
    )
    $pidFile = Join-Path $HOME "yuruna/image/squid-cache/forwarder.$Port.pid"
    if (-not (Test-Path $pidFile)) {
        if (-not $Quiet) { Write-Output "  No forwarder pidfile ? nothing to stop." }
        return $true
    }
    $forwarderPid = (Get-Content $pidFile -Raw).Trim()
    if (-not ($forwarderPid -as [int])) {
        if (-not $Quiet) { Write-Warning "Pidfile '$pidFile' contents invalid: '$forwarderPid' ? removing." }
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
        if (-not $Quiet) { Write-Output "  Forwarder pid $forwarderPid not running ? cleaning pidfile." }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    if ($cmd -notmatch 'Start-CachingProxyForwarder\.ps1') {
        if (-not $Quiet) { Write-Warning "Pid $forwarderPid is not Start-CachingProxyForwarder.ps1 (is: $cmd) ? leaving alone, removing stale pidfile." }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess("pid $forwarderPid (Start-CachingProxyForwarder.ps1)", 'SIGTERM then SIGKILL if needed')) {
        return $false
    }
    if (-not $Quiet) { Write-Output "  Stopping forwarder (pid $forwarderPid)..." }
    # /bin/kill sends SIGTERM (default). PowerShell 7's Stop-Process on
    # Unix maps to Process.Kill() == SIGKILL unconditionally, bypassing
    # graceful shutdown ? hence the external binary for TERM-then-KILL.
    # Port 80's forwarder is root-owned (spawned via sudo); a regular user
    # cannot signal it ? detect and escalate via sudo kill if needed.
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
    if (-not $Quiet) { Write-Warning "Forwarder $forwarderPid did not exit after SIGTERM ? sending SIGKILL." }
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
    Pure observer ? never signals, never removes files. Returns $true
    iff $HOME/yuruna/image/squid-cache/forwarder.<Port>.pid exists, parses as
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
    param([int]$Port = $(Get-CachingProxyPort -Scheme http))
    $pidFile = Join-Path $HOME "yuruna/image/squid-cache/forwarder.$Port.pid"
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
    Enumerates $HOME/yuruna/image/squid-cache/forwarder.<Port>.pid entries
    and sends SIGTERM to each (SIGKILL escalation per port via
    Stop-CachingProxyForwarder). Missing directory / no pidfiles is a
    no-op; safe to call even when nothing is running.

    Cross-platform `Add-CachingProxyPortMap` / `Remove-CachingProxyPortMap`
    (test/modules/Test.PortMap.psm1) dispatch to
    Start-CachingProxyForwarder + this function on macOS. High-level
    symbols live there; only platform primitives stay here.

.OUTPUTS
    [int[]] ? ports whose forwarder was stopped (may be empty).
#>
function Stop-AllCachingProxyForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int[]], [System.Object[]])]
    param([switch]$Quiet)
    $stateDir = Join-Path $HOME "yuruna/image/squid-cache"
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
    Returns $true when $BaseImageFile already matches what we'd
    download from $SourceUrl, so the caller can skip the transfer.

.DESCRIPTION
    Four conditions, ALL required (any single mismatch forces a
    re-download):
      1. $BaseImageFile exists on disk.
      2. $OriginFile (the sentinel a previous successful run wrote
         next to $BaseImageFile) has at least 4 lines:
           [0] source filename  (matches Path.GetFileName($SourceUrl))
           [1] source URL       (matches $SourceUrl exactly)
           [2] byte count       (positive int64)
           [3] Last-Modified    (HTTP date string, optionally empty
                                 if the upstream doesn't expose it)
      3. A fresh HEAD probe of $SourceUrl returns:
           - Content-Length that exactly equals the recorded byte count.
           - Last-Modified that exactly equals the recorded date
             (when both sentinel and HEAD provide one; if either is
             missing, the date check is skipped -- some mirrors strip
             Last-Modified, so we don't punish that).

    Sentinels from older script versions (3 lines, no Last-Modified)
    deliberately fail the line-count gate so the caller re-downloads
    once. After that the new 4-line sentinel is in place and the
    full check applies on every subsequent run. The cost is a single
    re-download per upgrade; the benefit is that the check catches
    cases where the URL/filename was changed in Get-Image.ps1 but a
    previously-cached sentinel was somehow updated to match without
    the corresponding image being re-fetched (the noble->resolute
    bug that motivated this rewrite).

    HEAD failure (offline, 4xx, no Content-Length, mirror redirect
    that strips the header, etc.) returns $false too, so the caller
    falls through to the regular download path rather than skipping
    silently on a transient error.

    Mismatch reasons are surfaced via Write-Verbose so the operator
    can run `Get-Image.ps1 -Verbose` and see WHICH check failed.

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
    [2] byte count of the downloaded source, [3] Last-Modified date.

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
    if (-not (Test-Path -LiteralPath $BaseImageFile)) {
        Write-Verbose "Test-DownloadAlreadyCurrent: base image file missing ($BaseImageFile); will download."
        return $false
    }
    if (-not (Test-Path -LiteralPath $OriginFile)) {
        Write-Verbose "Test-DownloadAlreadyCurrent: sentinel file missing ($OriginFile); will download."
        return $false
    }

    $lines = @(Get-Content -LiteralPath $OriginFile -ErrorAction SilentlyContinue)
    if ($lines.Count -lt 4) {
        Write-Verbose "Test-DownloadAlreadyCurrent: sentinel has only $($lines.Count) line(s); the 4-line format with Last-Modified is required, will re-download to refresh."
        return $false
    }

    $sentinelFilename = $lines[0].Trim()
    $sentinelUrl      = $lines[1].Trim()
    $sentinelSizeRaw  = $lines[2].Trim()
    $sentinelLastMod  = $lines[3].Trim()

    $expectedFilename = [System.IO.Path]::GetFileName(([System.Uri]$SourceUrl).LocalPath)
    if ($sentinelFilename -ne $expectedFilename) {
        Write-Verbose "Test-DownloadAlreadyCurrent: sentinel filename '$sentinelFilename' != URL filename '$expectedFilename'; will download. (This is what catches a noble->resolute style URL change.)"
        return $false
    }
    if ($sentinelUrl -ne $SourceUrl) {
        Write-Verbose "Test-DownloadAlreadyCurrent: sentinel URL '$sentinelUrl' != requested URL '$SourceUrl'; will download."
        return $false
    }
    $previousSize = 0L
    if (-not [int64]::TryParse($sentinelSizeRaw, [ref]$previousSize) -or $previousSize -le 0) {
        Write-Verbose "Test-DownloadAlreadyCurrent: sentinel byte count '$sentinelSizeRaw' is not a positive integer; will download."
        return $false
    }

    try {
        $head = Invoke-WebRequest -Uri $SourceUrl -Method Head -ErrorAction Stop
    } catch {
        Write-Verbose "Test-DownloadAlreadyCurrent: HEAD probe of $SourceUrl failed: $($_.Exception.Message); will download."
        return $false
    }
    $cl = $head.Headers['Content-Length']
    if ($cl -is [System.Array]) { $cl = $cl[0] }
    $expectedSize = 0L
    if (-not [int64]::TryParse([string]$cl, [ref]$expectedSize)) {
        Write-Verbose "Test-DownloadAlreadyCurrent: HEAD response has no usable Content-Length; will download."
        return $false
    }
    if ($expectedSize -ne $previousSize) {
        Write-Verbose "Test-DownloadAlreadyCurrent: size mismatch (sentinel=$previousSize, HEAD=$expectedSize); will download."
        return $false
    }
    # Last-Modified check, lenient when either side lacks the header.
    $headLm = $head.Headers['Last-Modified']
    if ($headLm -is [System.Array]) { $headLm = $headLm[0] }
    $headLastMod = [string]$headLm
    if ($sentinelLastMod -and $headLastMod -and ($sentinelLastMod -ne $headLastMod)) {
        Write-Verbose "Test-DownloadAlreadyCurrent: Last-Modified differs (sentinel='$sentinelLastMod', HEAD='$headLastMod'); will download."
        return $false
    }
    Write-Verbose "Test-DownloadAlreadyCurrent: match (filename='$sentinelFilename', size=$previousSize, last-modified='$sentinelLastMod'); skipping."
    return $true
}

<#
.SYNOPSIS
    Async TCP port probe with bounded wait. $true when $IpAddress:$Port
    accepts within $TimeoutMs.

.DESCRIPTION
    BeginConnect+WaitOne caps the wait predictably; synchronous
    TcpClient.Connect() blocks ~20s on a filtered/dropped port.
    Same shape as host\windows.hyper-v\modules\Yuruna.Host.psm1's
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
      1. The cache VM IP recorded in the yuruna-caching-proxy state
         file (<track>/yuruna-caching-proxy.yml, written by
         Start-CachingProxy.ps1 with the VM's 192.168.64.X address).
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
    $httpPort = Get-CachingProxyPort -Scheme http
    $ip = (Read-CachingProxyState).ipAddress
    if ($ip -and (Test-IpAddress $ip) -and (Test-CacheTcpPort -IpAddress $ip -Port $httpPort -TimeoutMs 500)) {
        return $ip
    }
    if (Test-CacheTcpPort -IpAddress '127.0.0.1' -Port $httpPort -TimeoutMs 500) {
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

    $httpPort  = Get-CachingProxyPort -Scheme http
    $httpsPort = Get-CachingProxyPort -Scheme https

    $scheme = ([System.Uri]$Uri).Scheme.ToLowerInvariant()
    if ($scheme -ne 'http' -and $scheme -ne 'https') {
        Write-Verbose "Get-CacheProxyForHostDownload: scheme '$scheme' not http(s); going direct."
        return $null
    }

    $cacheIp = Resolve-CacheHostIp
    if (-not $cacheIp) {
        Write-Verbose "Get-CacheProxyForHostDownload: no squid cache reachable on :${httpPort}; going direct."
        return $null
    }

    $cacheHost = Format-IpUrlHost $cacheIp
    if ($scheme -eq 'http') {
        return @{ Proxy = "http://${cacheHost}:${httpPort}"; CaPemPath = $null }
    }

    # HTTPS via SSL-bump on the HTTPS port -- needs the apache CA
    # endpoint on :80 AND the SSL-bump listener. Probe both before committing.
    if (-not (Test-CacheTcpPort -IpAddress $cacheIp -Port $httpsPort -TimeoutMs 500)) {
        Write-Verbose "Get-CacheProxyForHostDownload: squid :${httpsPort} not reachable on $cacheIp; HTTPS goes direct."
        return $null
    }
    if (-not (Test-CacheTcpPort -IpAddress $cacheIp -Port 80 -TimeoutMs 500)) {
        Write-Verbose "Get-CacheProxyForHostDownload: apache :80 not reachable on $cacheIp (cannot fetch CA); HTTPS goes direct."
        return $null
    }
    $caUrl = "http://${cacheHost}/yuruna-squid-ca.crt"
    $caPem = Join-Path ([System.IO.Path]::GetTempPath()) 'yuruna-squid-ca.pem'
    try {
        Invoke-WebRequest -Uri $caUrl -OutFile $caPem -ErrorAction Stop -UseBasicParsing | Out-Null
    } catch {
        Write-Verbose "Get-CacheProxyForHostDownload: CA fetch from $caUrl failed: $($_.Exception.Message); HTTPS goes direct."
        return $null
    }
    return @{ Proxy = "http://${cacheHost}:${httpsPort}"; CaPemPath = $caPem }
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

# === VM lifecycle helpers (migrated from test/modules/Test.New-VM.psm1
#     and test/modules/Test.Start-VM.psm1 during the Yuruna.Host refactor)
#
# UTM-internal helpers consumed by host/macos.utm/modules/Yuruna.Host.psm1.
# Not part of the test-facing host driver contract; new test code calls
# Yuruna.Host which delegates here.

# --- UTM dialog watchdog ---------------------------------------------------
# Background osascript that clicks accept buttons on UTM dialogs every ~2 s
# (custom-args import warning, intermittent QEMU "Invalid argument"). PID
# kept at $HOME/yuruna/image/utm-dialog-watchdog.pid.

$script:WatchdogPidFile    = Join-Path $HOME "yuruna/image/utm-dialog-watchdog.pid"
$script:WatchdogScriptPath = Join-Path $HOME "yuruna/image/utm-dialog-watchdog.applescript"
$script:WatchdogLogPath    = Join-Path $HOME "yuruna/image/utm-dialog-watchdog.log"

<#
.SYNOPSIS
    Kill the background osascript watchdog that auto-clicks UTM dialogs.
#>
function Stop-UtmDialogWatchdog {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param()
    if (-not (Test-Path $script:WatchdogPidFile)) { return }
    if (-not $PSCmdlet.ShouldProcess($script:WatchdogPidFile, 'Stop UTM dialog watchdog')) { return }
    $pidText = (Get-Content $script:WatchdogPidFile -Raw -ErrorAction SilentlyContinue)
    if ($pidText) {
        $pidText = $pidText.Trim()
        if ($pidText -as [int]) {
            & '/bin/kill' $pidText 2>$null | Out-Null
        }
    }
    Remove-Item -LiteralPath $script:WatchdogPidFile -Force -ErrorAction SilentlyContinue
}

<#
.SYNOPSIS
    Spawn a background osascript watchdog that auto-clicks UTM dialogs.
#>
function Start-UtmDialogWatchdog {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param()
    if (-not $PSCmdlet.ShouldProcess('UTM dialog watchdog', 'Start')) { return }
    Stop-UtmDialogWatchdog
    $stateDir = Split-Path -Parent $script:WatchdogPidFile
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    $asScript = @'
set acceptLabels to {"Continue", "OK", "Okay", "Run", "Open", "Allow", "Dismiss", "Close", "Ignore"}
repeat
    try
        tell application "System Events"
            tell process "UTM"
                set candidates to {}
                try
                    repeat with w in (every window)
                        repeat with s in (every sheet of w)
                            set end of candidates to s
                        end repeat
                    end repeat
                end try
                try
                    repeat with d in (every window whose subrole is "AXDialog")
                        set end of candidates to d
                    end repeat
                end try
                repeat with c in candidates
                    try
                        repeat with b in (every button of c)
                            if (title of b) is in acceptLabels then
                                click b
                                exit repeat
                            end if
                        end repeat
                    end try
                end repeat
            end tell
        end tell
    end try
    delay 2
end repeat
'@
    Set-Content -LiteralPath $script:WatchdogScriptPath -Value $asScript -NoNewline
    $proc = Start-Process -FilePath '/usr/bin/osascript' `
        -ArgumentList @($script:WatchdogScriptPath) `
        -RedirectStandardOutput $script:WatchdogLogPath `
        -RedirectStandardError  "$($script:WatchdogLogPath).stderr" `
        -PassThru
    $proc.Id | Set-Content -LiteralPath $script:WatchdogPidFile
    Write-Debug "      UTM dialog watchdog started (pid $($proc.Id))"
}

# --- VM lifecycle ----------------------------------------------------------

<#
.SYNOPSIS
    Returns true if a UTM .utm bundle exists for the given VM.
#>
function Confirm-UtmVMCreated {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    $configPlist = "$HOME/yuruna/guest.nosync/$VMName.utm/config.plist"
    if (Test-Path $configPlist) {
        Write-Output "Verified: $configPlist"
        return $true
    }
    Write-Error "VM verification failed: $configPlist not found."
    return $false
}

<#
.SYNOPSIS
    Stop, delete, and remove the UTM bundle for the given VM.
#>
function Remove-UtmTestVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Remove VM')) { return $false }
    & utmctl stop "$VMName" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Output "Stopped UTM VM: $VMName"
        $waited = 0
        while ($waited -lt 30) {
            Start-Sleep -Seconds 2
            $waited += 2
            $status = & utmctl status "$VMName" 2>&1
            if ($status -match "stopped|shutdown") { break }
        }
    }
    & utmctl delete "$VMName" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Start-Sleep -Seconds 3
        & utmctl delete "$VMName" 2>&1 | Out-Null
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Verbose "Deleted UTM VM from registry: $VMName"
    }
    $utmBundle = "$HOME/yuruna/guest.nosync/$VMName.utm"
    if (Test-Path $utmBundle) {
        if (Remove-UtmBundleWithRetry -Path $utmBundle) {
            Write-Output "Removed UTM bundle: $utmBundle"
        } else {
            Write-Warning "Remove-UtmTestVM: bundle still present after retries: $utmBundle"
            return $false
        }
    }
    return $true
}

<#
.SYNOPSIS
    Cold-start a UTM VM (clears stale vmstate and spawns dialog watchdog).
#>
function Start-UtmVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$VMName)
    $utmBundle = "$HOME/yuruna/guest.nosync/$VMName.utm"
    if (-not (Test-Path $utmBundle)) {
        return @{ success = $false; errorMessage = "UTM bundle not found: $utmBundle" }
    }
    try {
        if ($PSCmdlet.ShouldProcess($VMName, 'Start UTM VM')) {
            $vmstatePath = Join-Path $utmBundle "Data/vmstate"
            if (Test-Path $vmstatePath) {
                Remove-Item -LiteralPath $vmstatePath -Force -ErrorAction SilentlyContinue
                Write-Output "  Removed stale vmstate for '$VMName' -- forcing cold boot."
            }
            Start-UtmDialogWatchdog
            & open "$utmBundle"
            Start-Sleep -Seconds 3
            & utmctl start "$VMName" 2>&1 | Write-Output
            if ($LASTEXITCODE -ne 0) {
                return @{ success = $false; errorMessage = "utmctl start failed for '$VMName' (exit code $LASTEXITCODE)" }
            }
        }
        return @{ success = $true; errorMessage = $null }
    } catch {
        return @{ success = $false; errorMessage = "Failed to start UTM VM '$VMName': $_" }
    }
}

<#
.SYNOPSIS
    Stop a UTM VM via utmctl.
#>
function Stop-UtmVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Stop UTM VM')) { return $true }
    Stop-UtmDialogWatchdog
    & utmctl stop "$VMName" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Output "Stopped UTM VM: $VMName"
        Start-Sleep -Seconds 2
        return $true
    }
    Write-Warning "utmctl stop failed for '$VMName' (exit $LASTEXITCODE)"
    return $false
}

<#
.SYNOPSIS
    Poll utmctl status until it reports 'started' or 'running'.
#>
function Confirm-UtmVMStarted {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName, [int]$TimeoutSeconds = 120)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $output = & utmctl status "$VMName" 2>&1
        if ($output -match "started|running") {
            Write-Output "Verified: UTM VM '$VMName' is running"
            return $true
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    Write-Error "UTM VM '$VMName' did not reach running state within ${TimeoutSeconds}s"
    return $false
}

<#
.SYNOPSIS
    Activate the UTM application window (Metal repaint nudge).
#>
function Restart-UtmConsole {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Activate UTM display window')) { return $false }
    & osascript -e 'tell application "UTM" to activate' 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    Write-Verbose "    Activated UTM window for '$VMName' (display repaint)"
    return $true
}

# === Host proxy helpers (migrated from test/modules/Test.HostProxy.psm1) =====
# networksetup is sudo-only for writes. Read paths don't need sudo, so the
# backup capture can happen before the sudo check and surface a clearer
# error if sudo is missing. Marker file at $HOME/.yuruna/host-proxy.managed
# flags "this state was set by yuruna" -- same role as the WinINet
# YurunaProxyManaged registry value.

<#
.SYNOPSIS
    Return the path of the yuruna-managed macOS proxy marker file.
#>
function Get-MacProxyMarkerPath {
    $stateDir = Join-Path $HOME '.yuruna'
    return (Join-Path $stateDir 'host-proxy.managed')
}

<#
.SYNOPSIS
    Returns true if the marker file says yuruna set the macOS proxy.
#>
function Test-MacProxyIsYurunaManaged {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return (Test-Path -LiteralPath (Get-MacProxyMarkerPath))
}

<#
.SYNOPSIS
    Return the macOS network service for the default-route interface.
#>
function Get-MacActiveNetworkService {
    # `route -n get default` -> default-route interface (en0).
    # `networksetup -listnetworkserviceorder` pairs service names to
    # Device: entries; we match en0 back to "Wi-Fi" / "Ethernet" / etc.
    try {
        $routeOut = & route -n get default 2>$null
        $iface = $null
        foreach ($line in $routeOut) {
            if ($line -match 'interface:\s+(\S+)') { $iface = $matches[1]; break }
        }
        if (-not $iface) { return $null }
        $orderOut = & networksetup -listnetworkserviceorder 2>$null
        $lastService = $null
        foreach ($line in $orderOut) {
            if ($line -match '^\(\d+\)\s+(.+?)\s*$') { $lastService = $matches[1]; continue }
            if ($line -match '^\(Hardware Port:.*Device:\s*([^\)]+)\)') {
                if ($matches[1].Trim() -eq $iface) { return $lastService }
            }
        }
    } catch {
        Write-Verbose "Get-MacActiveNetworkService failed: $($_.Exception.Message)"
    }
    return $null
}

<#
.SYNOPSIS
    Read current macOS networksetup proxy state into a backup hashtable.
#>
function Read-MacProxyState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$NetworkService)
    if (Test-MacProxyIsYurunaManaged) {
        return @{
            platform            = 'macos'
            networkService      = $NetworkService
            webProxy            = @{ Enabled = 'No'; Server = $null; Port = $null }
            secureWebProxy      = @{ Enabled = 'No'; Server = $null; Port = $null }
            bypassDomains       = @()
            yurunaResetSnapshot = $true
        }
    }
    <#
    .SYNOPSIS
        ConvertFrom-NetworksetupBlock.
    #>
    function ConvertFrom-NetworksetupBlock {
        param([string[]]$Lines)
        $h = @{}
        foreach ($line in $Lines) {
            if ($line -match '^\s*(Enabled|Server|Port|Authenticated|Username):\s*(.*)$') {
                $h[$matches[1]] = $matches[2].Trim()
            }
        }
        return $h
    }
    $webOut = & networksetup -getwebproxy       $NetworkService 2>$null
    $sslOut = & networksetup -getsecurewebproxy $NetworkService 2>$null
    $bypOut = & networksetup -getproxybypassdomains $NetworkService 2>$null
    $bypassList = @()
    if ($bypOut -and -not ($bypOut -is [string] -and $bypOut -match "aren't any")) {
        foreach ($line in @($bypOut)) {
            if ($line -match "aren't any") { $bypassList = @(); break }
            $t = "$line".Trim()
            if ($t) { $bypassList += $t }
        }
    }
    return @{
        platform       = 'macos'
        networkService = $NetworkService
        webProxy       = ConvertFrom-NetworksetupBlock -Lines $webOut
        secureWebProxy = ConvertFrom-NetworksetupBlock -Lines $sslOut
        bypassDomains  = $bypassList
    }
}

<#
.SYNOPSIS
    Cache sudo credentials when the current user is not root.
#>
function Invoke-MacElevationIfNeeded {
    if ((& '/usr/bin/id' -u).Trim() -eq '0') { return }
    Write-Output "  macOS networksetup requires root -- caching sudo credentials (you may be prompted for your password)..."
    & sudo -v
    if ($LASTEXITCODE -ne 0) {
        throw "sudo -v failed -- cannot obtain root for networksetup. Check your sudo configuration."
    }
}

<#
.SYNOPSIS
    Run networksetup with sudo iff not already root.
#>
function Invoke-MacNetworksetup {
    param([string[]]$Arguments)
    if ((& '/usr/bin/id' -u).Trim() -eq '0') {
        & networksetup @Arguments | Out-Null
    } else {
        & sudo networksetup @Arguments | Out-Null
    }
}

<#
.SYNOPSIS
    Apply the proxy via networksetup and write the yuruna marker.
#>
function Set-MacHostProxy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][hashtable]$ProxyParts,
        [Parameter(Mandatory)][string]$NetworkService
    )
    $h = $ProxyParts.Host; $p = $ProxyParts.Port
    if (-not $PSCmdlet.ShouldProcess("macOS networksetup service '$NetworkService'", "Set web/securewebproxy to ${h}:${p} and enable")) {
        return
    }
    Invoke-MacNetworksetup @('-setwebproxy',            $NetworkService, $h, [string]$p)
    Invoke-MacNetworksetup @('-setsecurewebproxy',      $NetworkService, $h, [string]$p)
    Invoke-MacNetworksetup @('-setwebproxystate',       $NetworkService, 'on')
    Invoke-MacNetworksetup @('-setsecurewebproxystate', $NetworkService, 'on')
    Invoke-MacNetworksetup @('-setproxybypassdomains',  $NetworkService, 'localhost', '127.0.0.1', '*.local', '169.254/16', '192.168.64.*')
    $markerPath = Get-MacProxyMarkerPath
    $markerDir  = Split-Path -Parent $markerPath
    if (-not (Test-Path -LiteralPath $markerDir)) { New-Item -ItemType Directory -Path $markerDir -Force | Out-Null }
    Set-Content -LiteralPath $markerPath -Value $NetworkService -NoNewline -Encoding ascii
}

<#
.SYNOPSIS
    Restore macOS networksetup proxy state from the backup hashtable.
#>
function Restore-MacHostProxy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $svc = [string]$State.networkService
    if (-not $svc) { return }
    $web = $State.webProxy
    $ssl = $State.secureWebProxy
    if ($web.Server -and $web.Port) {
        Invoke-MacNetworksetup @('-setwebproxy', $svc, [string]$web.Server, [string]$web.Port)
    }
    if ($ssl.Server -and $ssl.Port) {
        Invoke-MacNetworksetup @('-setsecurewebproxy', $svc, [string]$ssl.Server, [string]$ssl.Port)
    }
    $webOn = ($web.Enabled -match '^(Yes|On)$')
    $sslOn = ($ssl.Enabled -match '^(Yes|On)$')
    Invoke-MacNetworksetup @('-setwebproxystate',       $svc, ($webOn ? 'on' : 'off'))
    Invoke-MacNetworksetup @('-setsecurewebproxystate', $svc, ($sslOn ? 'on' : 'off'))
    if ($State.bypassDomains -and $State.bypassDomains.Count -gt 0) {
        Invoke-MacNetworksetup (@('-setproxybypassdomains', $svc) + @($State.bypassDomains))
    } else {
        Invoke-MacNetworksetup @('-setproxybypassdomains', $svc, 'Empty')
    }
    $markerPath = Get-MacProxyMarkerPath
    if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
}

<#
.SYNOPSIS
    Turn web and securewebproxy off without restoring backup.
#>
function Disable-MacHostProxy {
    param([string]$NetworkService)
    if (-not $NetworkService) { $NetworkService = Get-MacActiveNetworkService }
    if (-not $NetworkService) { return }
    Invoke-MacNetworksetup @('-setwebproxystate',       $NetworkService, 'off')
    Invoke-MacNetworksetup @('-setsecurewebproxystate', $NetworkService, 'off')
    $markerPath = Get-MacProxyMarkerPath
    if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
}

<#
.SYNOPSIS
    Aggressively wipe networksetup proxy state and the marker file.
#>
function Remove-MacHostProxy {
    # --- See https://yuruna.link/memory#why-remove-machostproxy-sets-state-off-as-the-last-step
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Module-private helper; public Remove-HostProxy gates ShouldProcess.')]
    [CmdletBinding()]
    param([string]$NetworkService)
    if (-not $NetworkService) { $NetworkService = Get-MacActiveNetworkService }
    if (-not $NetworkService) { return }
    Invoke-MacNetworksetup @('-setwebproxy',            $NetworkService, '0.0.0.0', '0')
    Invoke-MacNetworksetup @('-setsecurewebproxy',      $NetworkService, '0.0.0.0', '0')
    Invoke-MacNetworksetup @('-setproxybypassdomains',  $NetworkService, 'Empty')
    Invoke-MacNetworksetup @('-setwebproxystate',       $NetworkService, 'off')
    Invoke-MacNetworksetup @('-setsecurewebproxystate', $NetworkService, 'off')
    $markerPath = Get-MacProxyMarkerPath
    if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
}

# === Screenshot helpers (migrated from test/modules/Test.Screenshot.psm1) ====
# UTM-side screenshot capture: VNC framebuffer first (real pixels even when
# UTM's NSWindow stays black), then CGWindowList screencapture -l <id>,
# then bounds-based screencapture -R fallback. Per-VM VNC port (5910..5989)
# derived deterministically from the VM name so producer (config.plist
# template) and consumers (capture, keystrokes) agree without a sidecar.

<#
.SYNOPSIS
    Return a deterministic VNC display number (10..89) from the VM name.
#>
function Get-VncDisplayForVm {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$VMName)
    # Displays 0..9 reserved for legacy/default callers.
    $h = 0
    foreach ($ch in $VMName.ToCharArray()) {
        $h = (($h * 131) + [int][char]$ch) -band 0x3FFFFFFF
    }
    return ($h % 80) + 10
}

<#
.SYNOPSIS
    Return the VNC TCP port (5910..5989) for the given VM.
#>
function Get-VncPortForVm {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$VMName)
    return 5900 + (Get-VncDisplayForVm -VMName $VMName)
}

# C# helper for a hot byte-swap loop (BGRX framebuffer -> P6 PPM).
# Pure-PowerShell over a 1920x1080 buffer is multiple seconds; compiled
# version is tens of ms. Idempotent via type-presence check.
if (-not ('YurunaVncPixels' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
public static class YurunaVncPixels {
    public static void BgrxToRgb(byte[] src, byte[] dst, int dstOffset) {
        int n = src.Length / 4;
        for (int i = 0; i < n; i++) {
            int s = i * 4;
            int d = dstOffset + i * 3;
            dst[d]     = src[s + 2]; // R
            dst[d + 1] = src[s + 1]; // G
            dst[d + 2] = src[s];     // B
        }
    }
}
'@
}

<#
.SYNOPSIS
    Read exactly $Count bytes from $Stream into a fresh byte[]. Uses
    Stream.ReadExactly (.NET 7+) so the read loop runs inside the runtime
    instead of being driven from PowerShell — measured against a 1920x1080
    QEMU VNC capture (7.9 MB payload), the runtime-side loop completes
    in ~150 ms while the PowerShell-side equivalent took ~10.6 s because
    QEMU's RFB encoder emits the pixel rect in many small frames and
    every PowerShell loop iteration paid scriptblock-invocation overhead.
.NOTES
    Stream.ReadExactly throws EndOfStreamException on premature EOF; we
    wrap that to match the previous error-message style for log parity.
#>
function Read-VncScreenshotBuffer {
    param([System.IO.Stream]$Stream, [int]$Count)
    $buf = [byte[]]::new($Count)
    try {
        $Stream.ReadExactly($buf, 0, $Count)
    } catch [System.IO.EndOfStreamException] {
        throw "VNC connection closed before $Count bytes were read"
    }
    return $buf
}

<#
.SYNOPSIS
    Capture a VNC framebuffer to PNG via raw RFB 3.8 protocol.
#>
function Get-VncScreenshot {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$OutputPath,
        [int]$Port = 5900,
        [int]$TimeoutMs = 5000
    )
    $tcp = $null
    $ppmPath = $null
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $tcp.ReceiveTimeout = $TimeoutMs
        $tcp.SendTimeout    = $TimeoutMs
        $tcp.Connect('127.0.0.1', $Port)
        $stream = $tcp.GetStream()
        # RFB 3.8 handshake
        $null = Read-VncScreenshotBuffer -Stream $stream -Count 12
        $stream.Write([System.Text.Encoding]::ASCII.GetBytes("RFB 003.008`n"), 0, 12)
        $countBuf = Read-VncScreenshotBuffer -Stream $stream -Count 1
        $numTypes = [int]$countBuf[0]
        if ($numTypes -eq 0) { throw 'VNC server refused (0 security types offered)' }
        $typesBuf = Read-VncScreenshotBuffer -Stream $stream -Count $numTypes
        if ($typesBuf -notcontains 1) { throw "VNC server does not offer None-auth (got: $($typesBuf -join ','))" }
        $stream.WriteByte(1)
        $secResult = Read-VncScreenshotBuffer -Stream $stream -Count 4
        if ($secResult[0] -ne 0 -or $secResult[1] -ne 0 -or $secResult[2] -ne 0 -or $secResult[3] -ne 0) {
            throw "VNC security handshake failed"
        }
        $stream.WriteByte(1) # ClientInit shared=1
        $initBuf = Read-VncScreenshotBuffer -Stream $stream -Count 24
        $w = [int][BitConverter]::ToUInt16([byte[]]@($initBuf[1], $initBuf[0]), 0)
        $h = [int][BitConverter]::ToUInt16([byte[]]@($initBuf[3], $initBuf[2]), 0)
        $nameLen = [int][BitConverter]::ToInt32([byte[]]@($initBuf[23], $initBuf[22], $initBuf[21], $initBuf[20]), 0)
        $bpp = [int]$initBuf[4]
        $bigEndian = [int]$initBuf[6]
        if ($nameLen -gt 0) { $null = Read-VncScreenshotBuffer -Stream $stream -Count $nameLen }
        if ($bpp -ne 32)    { throw "Unsupported bpp=$bpp (this capture path assumes 32bpp BGRX)" }
        if ($bigEndian -ne 0) { throw "Unsupported big-endian framebuffer (this path assumes little-endian BGRX)" }
        $req = [byte[]]::new(10)
        $req[0] = 3
        $req[1] = 0
        $req[6] = [byte](($w -shr 8) -band 0xFF); $req[7] = [byte]($w -band 0xFF)
        $req[8] = [byte](($h -shr 8) -band 0xFF); $req[9] = [byte]($h -band 0xFF)
        $stream.Write($req, 0, 10)
        $updHdr = Read-VncScreenshotBuffer -Stream $stream -Count 4
        if ($updHdr[0] -ne 0) { throw "Expected FramebufferUpdate (0), got message type $($updHdr[0])" }
        $nRects = [int][BitConverter]::ToUInt16([byte[]]@($updHdr[3], $updHdr[2]), 0)
        $fbBytes = $w * $h * 4
        $fb = [byte[]]::new($fbBytes)
        for ($r = 0; $r -lt $nRects; $r++) {
            $rectHdr = Read-VncScreenshotBuffer -Stream $stream -Count 12
            $rx = [int][BitConverter]::ToUInt16([byte[]]@($rectHdr[1],  $rectHdr[0]),  0)
            $ry = [int][BitConverter]::ToUInt16([byte[]]@($rectHdr[3],  $rectHdr[2]),  0)
            $rw = [int][BitConverter]::ToUInt16([byte[]]@($rectHdr[5],  $rectHdr[4]),  0)
            $rh = [int][BitConverter]::ToUInt16([byte[]]@($rectHdr[7],  $rectHdr[6]),  0)
            $enc = [BitConverter]::ToInt32([byte[]]@($rectHdr[11], $rectHdr[10], $rectHdr[9], $rectHdr[8]), 0)
            if ($enc -ne 0) { throw "Unsupported VNC encoding $enc for rect $r (need Raw=0)" }
            $rectBytes = $rw * $rh * 4
            if ($rx -eq 0 -and $ry -eq 0 -and $rw -eq $w -and $rh -eq $h) {
                # Full-frame rect (the common case for an initial
                # FramebufferUpdateRequest after a fresh handshake): read
                # straight into $fb so we skip the per-row PowerShell copy
                # loop. Without this fast path, a 1080-row loop of
                # [Array]::Copy in PowerShell takes ~10 s on a 1920x1080
                # framebuffer because each iteration pays scriptblock
                # dispatch overhead — the bytes arrive in <50 ms, the
                # loop is the bottleneck.
                $stream.ReadExactly($fb, 0, $rectBytes)
            } else {
                # Sub-rect (would occur if we ever sent incremental=1):
                # the row-by-row PowerShell copy is still slow but
                # tolerable because the sub-rect is small. Kept as
                # fallback so the function remains correct under
                # encodings that emit multiple rects.
                $pixels = Read-VncScreenshotBuffer -Stream $stream -Count $rectBytes
                for ($row = 0; $row -lt $rh; $row++) {
                    $srcOff = $row * $rw * 4
                    $dstOff = (($ry + $row) * $w + $rx) * 4
                    [Array]::Copy($pixels, $srcOff, $fb, $dstOff, $rw * 4)
                }
            }
        }
        $headerBytes = [System.Text.Encoding]::ASCII.GetBytes("P6`n$w $h`n255`n")
        $ppm = [byte[]]::new($headerBytes.Length + $w * $h * 3)
        [Array]::Copy($headerBytes, 0, $ppm, 0, $headerBytes.Length)
        [YurunaVncPixels]::BgrxToRgb($fb, $ppm, $headerBytes.Length)
        $ppmPath = "$OutputPath.ppm"
        [System.IO.File]::WriteAllBytes($ppmPath, $ppm)
        $sipsErr = & sips -s format png $ppmPath --out $OutputPath 2>&1
        if (-not (Test-Path $OutputPath)) {
            Write-Debug "      VNC capture: sips conversion failed: $sipsErr"
            return $false
        }
        return $true
    } catch {
        Write-Debug "      VNC capture failed: $_"
        return $false
    } finally {
        if ($tcp) { try { $tcp.Close() } catch { Write-Debug "      VNC capture: tcp.Close() failed: $_" } }
        if ($ppmPath -and (Test-Path $ppmPath)) {
            Remove-Item -LiteralPath $ppmPath -Force -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
    Capture the UTM VM's display (VNC then screencapture fallbacks).
#>
function Get-UtmScreenshot {
    param([string]$VMName, [string]$OutputPath)
    $vncPort = Get-VncPortForVm -VMName $VMName
    if (Get-VncScreenshot -OutputPath $OutputPath -Port $vncPort) {
        Write-Debug "      Captured via VNC (port $vncPort, VM $VMName)"
        Write-Debug "Screenshot saved: $OutputPath"
        return $OutputPath
    }
    if (-not $script:ScreencaptureChecked) {
        $script:ScreencaptureChecked = $true
        $testFile = Join-Path ([System.IO.Path]::GetTempPath()) "screencapture_test_$PID.png"
        $testErr = & screencapture -x "$testFile" 2>&1
        if (Test-Path $testFile) {
            $fileSize = (Get-Item $testFile).Length
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
            if ($fileSize -lt 100) {
                Write-Warning "screencapture produces empty files. Grant Screen Recording permission to your terminal:"
                Write-Warning "  System Settings > Privacy & Security > Screen Recording > enable your terminal app, then restart."
                $script:ScreencaptureWorks = $false
            } else {
                $script:ScreencaptureWorks = $true
            }
        } else {
            Write-Warning "screencapture failed: $testErr"
            Write-Warning "Grant Screen Recording permission to your terminal."
            $script:ScreencaptureWorks = $false
        }
    }
    if ($script:ScreencaptureWorks -eq $false) { return $null }
    $safeVMName = $VMName -replace '\\', '\\\\' -replace "'", "\\'"
    $windowIdScript = @"
ObjC.import('CoreGraphics');
ObjC.import('CoreFoundation');
var winList = ObjC.unwrap(
    `$.CGWindowListCopyWindowInfo(`$.kCGWindowListOptionAll, 0));
var vmName = '__VMNAME__';
var result = 'not_found';
for (var i = 0; i < winList.length; i++) {
    var w = winList[i];
    var owner = ObjC.unwrap(w.kCGWindowOwnerName) || '';
    var name  = ObjC.unwrap(w.kCGWindowName)      || '';
    if (owner.indexOf('UTM') >= 0 && name.indexOf(vmName) >= 0) {
        result = '' + ObjC.unwrap(w.kCGWindowNumber);
        break;
    }
}
result;
"@
    $windowIdScript = $windowIdScript -replace '__VMNAME__', $safeVMName
    $windowIdResult = & osascript -l JavaScript -e $windowIdScript 2>&1
    Write-Debug "      CG window ID query: $windowIdResult"
    $captured = $false
    if ($LASTEXITCODE -eq 0 -and "$windowIdResult" -match '^\d+$') {
        $captureErr = & screencapture -x -o -l "$windowIdResult" "$OutputPath" 2>&1
        if (Test-Path $OutputPath) {
            $fileSize = (Get-Item $OutputPath).Length
            if ($fileSize -gt 100) {
                $captured = $true
            } else {
                Write-Debug "      screencapture -l produced small file ($fileSize bytes), trying -R fallback"
                Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Debug "      screencapture -l failed: $captureErr"
        }
    }
    if (-not $captured) {
        $safeVMNameAS = $VMName -replace '\\', '\\\\' -replace '"', '\\"'
        $boundsScript = @"
tell application "System Events"
    tell process "UTM"
        repeat with w in windows
            if name of w contains "$safeVMNameAS" then
                try
                    set contentArea to first group of w
                    set {cx, cy} to position of contentArea
                    set {cw, ch} to size of contentArea
                    return ("" & cx & "," & cy & "," & cw & "," & ch)
                end try
                set {wx, wy} to position of w
                set {ww, wh} to size of w
                set titleBarH to 28
                return ("" & wx & "," & (wy + titleBarH) & "," & ww & "," & (wh - titleBarH))
            end if
        end repeat
    end tell
    return "not_found"
end tell
"@
        $boundsResult = & osascript -e $boundsScript 2>&1
        Write-Debug "      Window bounds query: $boundsResult"
        if ($LASTEXITCODE -eq 0 -and "$boundsResult" -match '^\d+,\d+,\d+,\d+$') {
            $captureErr = & screencapture -x -R "$boundsResult" "$OutputPath" 2>&1
            if (Test-Path $OutputPath) {
                $captured = $true
                Write-Debug "      Captured via -R (window may include overlapping content)"
            } else {
                Write-Warning "screencapture -R '$boundsResult' failed: $captureErr"
            }
        } else {
            Write-Warning "UTM window for '$VMName' not found. CG: $windowIdResult, bounds: $boundsResult"
        }
    }
    if ($captured) {
        Write-Debug "Screenshot saved: $OutputPath"
        return $OutputPath
    }
    Write-Error "Screenshot capture failed for '$VMName'"
    return $null
}

<#
.SYNOPSIS
    Capture the UTM window with metadata (id, origin, scale) for clicks.
#>
function Get-UtmWindowScreenshot {
    param([string]$VMName, [string]$OutputPath)
    if ($script:ScreencaptureWorks -eq $false) { return $null }
    $safeVMName = $VMName -replace '\\', '\\\\' -replace "'", "\\'"
    $windowScript = @"
ObjC.import('CoreGraphics');
var winList = ObjC.unwrap(
    `$.CGWindowListCopyWindowInfo(`$.kCGWindowListOptionAll, 0));
var vmName = '__VMNAME__';
var result = 'not_found';
for (var i = 0; i < winList.length; i++) {
    var w = winList[i];
    var owner = ObjC.unwrap(w.kCGWindowOwnerName) || '';
    var name  = ObjC.unwrap(w.kCGWindowName)      || '';
    if (owner.indexOf('UTM') >= 0 && name.indexOf(vmName) >= 0) {
        var id = ObjC.unwrap(w.kCGWindowNumber);
        var b  = ObjC.unwrap(w.kCGWindowBounds);
        result = '' + id + ',' + b.X + ',' + b.Y + ',' + b.Width + ',' + b.Height;
        break;
    }
}
result;
"@
    $windowScript = $windowScript -replace '__VMNAME__', $safeVMName
    $windowResult = & osascript -l JavaScript -e $windowScript 2>&1
    Write-Debug "      CG window query (window+bounds): $windowResult"
    $windowId = 0
    $originX  = 0.0
    $originY  = 0.0
    $pointW   = 0.0
    $pointH   = 0.0
    $cgOk     = $false
    if ($LASTEXITCODE -eq 0 -and "$windowResult" -match '^\d+,-?\d+(\.\d+)?,-?\d+(\.\d+)?,\d+(\.\d+)?,\d+(\.\d+)?$') {
        $parts    = "$windowResult".Split(',')
        $windowId = [int]$parts[0]
        $originX  = [double]$parts[1]
        $originY  = [double]$parts[2]
        $pointW   = [double]$parts[3]
        $pointH   = [double]$parts[4]
        $cgOk     = $true
    } else {
        $safeVMNameAS = $VMName -replace '\\', '\\\\' -replace '"', '\\"'
        $boundsScript = @"
tell application "System Events"
    tell process "UTM"
        repeat with w in windows
            if name of w contains "$safeVMNameAS" then
                try
                    set contentArea to first group of w
                    set {cx, cy} to position of contentArea
                    set {cw, ch} to size of contentArea
                    return ("" & cx & "," & cy & "," & cw & "," & ch)
                end try
                set {wx, wy} to position of w
                set {ww, wh} to size of w
                set titleBarH to 28
                return ("" & wx & "," & (wy + titleBarH) & "," & ww & "," & (wh - titleBarH))
            end if
        end repeat
    end tell
    return "not_found"
end tell
"@
        $boundsResult = & osascript -e $boundsScript 2>&1
        Write-Debug "      Window bounds query (fallback): $boundsResult"
        if ($LASTEXITCODE -eq 0 -and "$boundsResult" -match '^-?\d+(\.\d+)?,-?\d+(\.\d+)?,\d+(\.\d+)?,\d+(\.\d+)?$') {
            $parts   = "$boundsResult".Split(',')
            $originX = [double]$parts[0]
            $originY = [double]$parts[1]
            $pointW  = [double]$parts[2]
            $pointH  = [double]$parts[3]
        } else {
            Write-Warning "UTM window for '$VMName' not found (CG: $windowResult, bounds: $boundsResult)."
            return $null
        }
    }
    if ($cgOk) {
        $captureErr = & screencapture -x -o -l "$windowId" "$OutputPath" 2>&1
    } else {
        $region = "{0},{1},{2},{3}" -f $originX, $originY, $pointW, $pointH
        $captureErr = & screencapture -x -R "$region" "$OutputPath" 2>&1
    }
    if (-not (Test-Path $OutputPath)) {
        Write-Warning "screencapture failed for '$VMName': $captureErr"
        return $null
    }
    $fileSize = (Get-Item $OutputPath).Length
    if ($fileSize -lt 100) {
        Write-Warning "screencapture produced a ${fileSize}-byte PNG -- likely Screen Recording permission missing."
        Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
        return $null
    }
    try {
        $fs = [IO.File]::OpenRead($OutputPath)
        try {
            $buf = New-Object byte[] 24
            [void]$fs.Read($buf, 0, 24)
        } finally { $fs.Dispose() }
        $pixelW = ([int]$buf[16] -shl 24) -bor ([int]$buf[17] -shl 16) -bor ([int]$buf[18] -shl 8) -bor [int]$buf[19]
        $pixelH = ([int]$buf[20] -shl 24) -bor ([int]$buf[21] -shl 16) -bor ([int]$buf[22] -shl 8) -bor [int]$buf[23]
    } catch {
        Write-Warning "Failed to read PNG dimensions from '$OutputPath': $_"
        return $null
    }
    $scale = if ($pointW -gt 0) { $pixelW / $pointW } else { 1.0 }
    Write-Debug "      UTM window: id=$windowId origin=($originX,$originY) point=${pointW}x${pointH} pixel=${pixelW}x${pixelH} scale=$scale"
    return @{
        ImagePath   = $OutputPath
        WindowId    = $windowId
        OriginX     = $originX
        OriginY     = $originY
        Width       = $pixelW
        Height      = $pixelH
        PointWidth  = $pointW
        PointHeight = $pointH
        Scale       = $scale
    }
}

# === VM lifecycle ===========================================================

<#
.SYNOPSIS
    Create a guest VM by running the per-guest New-VM.ps1 script.
#>
function New-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$VMName,
        [string]$CachingProxyUrl
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, "Create VM ($GuestKey)")) { return @{ success = $false; errorMessage = 'WhatIf' } }
    $scriptPath = Join-Path $RepoRoot (Join-Path 'host/macos.utm' (Join-Path $GuestKey 'New-VM.ps1'))
    if (-not (Test-Path $scriptPath)) {
        return @{ success = $false; errorMessage = "New-VM.ps1 not found at: $scriptPath" }
    }
    $childArgs = @('-VMName', $VMName)
    $scriptAcceptsProxy = $false
    try {
        $cmdInfo = Get-Command -Name $scriptPath -ErrorAction Stop
        $scriptAcceptsProxy = [bool]($cmdInfo.Parameters -and $cmdInfo.Parameters.ContainsKey('CachingProxyUrl'))
    } catch {
        $scriptAcceptsProxy = $false
    }
    if ($PSBoundParameters.ContainsKey('CachingProxyUrl') -and $scriptAcceptsProxy) {
        $childArgs += @('-CachingProxyUrl', $CachingProxyUrl)
        Write-Verbose "Running: $scriptPath -VMName $VMName -CachingProxyUrl '$CachingProxyUrl'"
    } else {
        Write-Verbose "Running: $scriptPath -VMName $VMName"
    }
    $output = & pwsh -NoProfile -File $scriptPath @childArgs 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        $text = "$line".TrimEnd()
        if ($text -ne '' -and $text -notmatch '^\s*\d+%\s+complete') {
            Write-Output $text
        }
    }
    if ($exitCode -ne 0) {
        return @{ success = $false; errorMessage = "New-VM.ps1 exited with code $exitCode" }
    }
    return @{ success = $true; errorMessage = $null }
}

<#
.SYNOPSIS
    Start a guest VM previously created by New-VM.
#>
function Start-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Start VM')) { return @{ success = $false; errorMessage = 'WhatIf' } }
    return Start-UtmVM -VMName $VMName -Confirm:$false
}

<#
.SYNOPSIS
    Stop a running guest VM (graceful by default; -Force uses Stop-VMForce).
#>
function Stop-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [switch]$Force
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Stop VM')) { return $false }
    # UTM only exposes `utmctl stop`; -Force is accepted for cross-host
    # contract parity and maps to the same op here.
    if ($Force) { Write-Debug "Stop-VM on host.macos.utm: -Force maps to the same utmctl stop (no graceful/force distinction)." }
    return [bool](Stop-UtmVM -VMName $VMName -Confirm:$false)
}

<#
.SYNOPSIS
    Force-stop a UTM VM via utmctl stop (synchronous; timeout parameter exists for parity with other hosts).
#>
function Stop-VMForce {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$StopTimeoutSeconds = 20
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Force-stop UTM VM')) { return $false }
    # StopTimeoutSeconds is reserved for parity with Hyper-V Stop-VMForce;
    # utmctl stop is synchronous so the value is informational only.
    Write-Debug "Stop-VMForce on host.macos.utm: -StopTimeoutSeconds $StopTimeoutSeconds is informational (utmctl is synchronous)."
    & utmctl stop $VMName 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS
    Remove a guest VM and its on-disk artifacts.
#>
function Remove-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Remove VM')) { return $false }
    return [bool](Remove-UtmTestVM -VMName $VMName -Confirm:$false)
}

<#
.SYNOPSIS
    Returns 'absent', 'stopped', 'running', or 'unknown' for the given VM.
#>
function Get-VMState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not (Get-Command utmctl -ErrorAction SilentlyContinue)) { return 'absent' }
    $status = & utmctl status $VMName 2>&1
    if ($LASTEXITCODE -ne 0) { return 'absent' }
    switch -Regex ($status) {
        'started'   { return 'running' }
        'paused'    { return 'stopped' }
        'suspended' { return 'stopped' }
        'stopped'   { return 'stopped' }
        default     { return 'unknown' }
    }
}

<#
.SYNOPSIS
    Returns true when a console window is open for the given VM.
#>
function Test-VMConsoleOpen {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    # UTM does not expose per-VM window state today; "console open" is
    # approximated by "UTM app process running." VMName is accepted for
    # cross-host parity and surfaced in the debug stream.
    Write-Debug "Test-VMConsoleOpen on host.macos.utm: VMName '$VMName' resolved to UTM-process check (no per-VM window detection)."
    return [bool](Get-Process -Name 'UTM' -ErrorAction SilentlyContinue)
}

<#
.SYNOPSIS
    Refresh or re-open the host-side console window for the given VM.
#>
function Restart-VMConsole {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Restart console window (UTM activate)')) { return $false }
    return [bool](Restart-UtmConsole -VMName $VMName -Confirm:$false)
}

# === Image ==================================================================

<#
.SYNOPSIS
    Run the per-guest Get-Image.ps1 to download or refresh the base image.
#>
function Get-Image {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Force
    )
    if (-not $PSCmdlet.ShouldProcess($GuestKey, 'Download / refresh base image')) { return @{ success = $false; skipped = $false; errorMessage = 'WhatIf' } }
    $scriptPath = Join-Path $RepoRoot (Join-Path 'host/macos.utm' (Join-Path $GuestKey 'Get-Image.ps1'))
    if (-not (Test-Path $scriptPath)) {
        return @{ success = $false; skipped = $false; errorMessage = "Get-Image.ps1 not found at: $scriptPath" }
    }
    if (-not $Force) {
        $imagePath = Get-ImagePath -GuestKey $GuestKey
        if ($imagePath -and (Test-Path $imagePath)) {
            Write-GetImageLine "Image exists, skipping download: $imagePath"
            return @{ success = $true; skipped = $true; errorMessage = $null }
        }
    }
    Write-GetImageLine "Running: $scriptPath"
    & pwsh -NoProfile -File $scriptPath 2>&1 | ForEach-Object {
        Write-GetImageLine ([string]$_)
    }
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        return @{ success = $false; skipped = $false; errorMessage = "Get-Image.ps1 exited with code $code" }
    }
    return @{ success = $true; skipped = $false; errorMessage = $null }
}

<#
.SYNOPSIS
    Return the expected on-disk path of the base image for a guest.
#>
function Get-ImagePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$GuestKey)
    # Per-guest paths under $HOME/yuruna/image/ -- not a single-dir pattern;
    # subdir names are part of the legacy convention (amazon.linux,
    # ubuntu.env, windows.env). Keep the explicit table so a typo or new
    # guest fails loud instead of silently composing the wrong path.
    $paths = @{
        'guest.amazon.linux'    = "$HOME/yuruna/image/amazon.linux/host.macos.utm.guest.amazon.linux.qcow2"
        'guest.ubuntu.server'   = "$HOME/yuruna/image/ubuntu.env/host.macos.utm.guest.ubuntu.server.iso"
        'guest.windows.11'      = "$HOME/yuruna/image/windows.env/host.macos.utm.guest.windows.11.iso"
    }
    return $paths[$GuestKey]
}

# Helper for Get-Image: console + cycle log without polluting the
# function-output pipeline (callers do `$r = Get-Image ...` and would
# otherwise capture the diagnostic stream alongside the hashtable).
<#
.SYNOPSIS
    Write-GetImageLine.
#>
function Write-GetImageLine {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'global:__YurunaLogFile is the per-cycle HTML log handle, set/cleared by the runner; intentionally process-wide.')]
    [CmdletBinding()]
    param([string]$Line)
    Microsoft.PowerShell.Utility\Write-Host $Line
    if ($global:__YurunaLogFile) {
        [System.Net.WebUtility]::HtmlEncode($Line) |
            Microsoft.PowerShell.Utility\Out-File -FilePath $global:__YurunaLogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue
    }
}

# === VM I/O =================================================================

<#
.SYNOPSIS
    Type text into the guest VM via gui or ssh mechanism.
#>
function Send-Text {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('gui','ssh')][string]$Mechanism = 'gui',
        # Required when -Mechanism ssh: maps to the SSH login user via
        # Test.Ssh\Get-GuestSshUser (per-guest test user, ec2-user, root, ...).
        [string]$GuestKey,
        [int]$CharDelayMs = 30,
        [switch]$Sensitive
    )
    # Sensitive is part of the contract for log redaction; underlying
    # Send-Text* helpers gain it once bodies are lifted out of test/extensions.
    if ($Sensitive) { Write-Debug "Send-Text: -Sensitive set on '$VMName'; log redaction not yet implemented on UTM." }
    if ($Mechanism -eq 'ssh') {
        if (-not $GuestKey) {
            Write-Warning "Send-Text -Mechanism ssh requires -GuestKey to determine the SSH login user."
            return $false
        }
        # Test.Ssh\Invoke-GuestSsh resolves both the user (from GuestKey)
        # and the address (from VMName) internally; .success is the right
        # bool to surface -- the prior `[bool]<hashtable>` cast always
        # returned $true because a non-null hashtable is truthy.
        $r = Invoke-GuestSsh -VMName $VMName -GuestKey $GuestKey -Command $Text
        return [bool]$r.success
    }
    # GUI: Invoke-Sequence.psm1 has the cross-platform dispatcher and the
    # macOS-specific Send-TextVNC / Send-TextUTM helpers. We import it on
    # demand here (it ships in test/modules/ and the runner already loads
    # it for sequence execution).
    $invokeSequence = Join-Path $script:TestModulesDir 'Invoke-Sequence.psm1'
    if (Test-Path $invokeSequence) {
        Import-Module $invokeSequence -Force -DisableNameChecking
        # Module-qualified call avoids re-entering OUR Send-Text.
        return [bool](Invoke-Sequence\Send-Text -HostType $script:HostTag -VMName $VMName -Text $Text -CharDelayMs $CharDelayMs)
    }
    Write-Warning "Send-Text -Mechanism gui: Invoke-Sequence.psm1 not found at '$invokeSequence'."
    return $false
}

<#
.SYNOPSIS
    Send a named key to the guest VM via gui or ssh mechanism.
#>
function Send-Key {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Key,
        [ValidateSet('gui','ssh')][string]$Mechanism = 'gui'
    )
    if ($Mechanism -eq 'ssh') {
        Write-Warning "Send-Key -Mechanism ssh: not meaningful for SSH (use Send-Text with the typed command)."
        return $false
    }
    if ($Key -ieq 'Enter') {
        return [bool](Send-Text -VMName $VMName -Text "`r" -Mechanism gui)
    }
    Write-Warning "Send-Key '$Key': not implemented in this facade phase on host.macos.utm."
    return $false
}

<#
.SYNOPSIS
    Send a mouse click at the given pixel coordinate.
#>
function Send-Click {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y
    )
    Write-Warning "Send-Click on host.macos.utm: not implemented (Hyper-V-only today). (vm='$VMName' ignored x=$X y=$Y)"
    return $false
}

<#
.SYNOPSIS
    Capture a PNG of the VM display from frame or window source.
#>
function Get-VMScreenshot {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [ValidateSet('frame','window')][string]$Source = 'frame',
        [string]$OutFile
    )
    if (-not $OutFile) {
        $tmp = [System.IO.Path]::GetTempFileName()
        $OutFile = [System.IO.Path]::ChangeExtension($tmp, '.png')
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
    if ($Source -eq 'window') {
        return Get-UtmWindowScreenshot -VMName $VMName -OutputPath $OutFile
    }
    return Get-UtmScreenshot -VMName $VMName -OutputPath $OutFile
}

<#
.SYNOPSIS
    Return a host-specific handle for the VM console window.
#>
function Get-VMConsoleHandle {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$VMName)
    # macOS UTM exposes one app-level console; we return the UTM PID and
    # surface the requested VMName in the debug stream until per-VM window
    # handles are wired up.
    Write-Debug "Get-VMConsoleHandle on host.macos.utm: returning UTM app PID for '$VMName' (no per-VM window handle today)."
    $proc = Get-Process -Name 'UTM' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { return $null }
    return $proc.Id
}

# === Discovery ==============================================================

<#
.SYNOPSIS
    Poll Get-VMIp until an IPv4 address is discovered or timeout expires.
#>
function Wait-VMIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds = 30,
        [int]$PollSeconds    = 3
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $candidate = Get-VMIp -VMName $VMName
        if ($candidate) { return [string]$candidate }
        Start-Sleep -Seconds $PollSeconds
    }
    return $null
}

<#
.SYNOPSIS
    Return the guest's host-side IPv4, or null if not yet discoverable.
#>
function Get-VMIp {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    # Primary: utmctl ip-address (Apple Virtualization integration-services).
    if (Get-Command utmctl -ErrorAction SilentlyContinue) {
        try {
            $output = & utmctl ip-address $VMName 2>&1
            if ($LASTEXITCODE -eq 0) {
                # Accept either IPv4 or IPv6; exclude loopback (127., ::1)
                # and link-local (169.254., fe80:) for both families. v4 is
                # preferred only by output ordering -- utmctl emits the v4
                # row first today, so callers that expect a connectable
                # address still get one. If only v6 is present, take it.
                $ipPick = ($output -split "`r?`n") |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { Test-IpAddress $_ } |
                    Where-Object { $_ -notmatch '^(127\.|169\.254\.)' -and $_ -inotmatch '^(::1$|fe80:)' } |
                    Select-Object -First 1
                if ($ipPick) { return [string]$ipPick }
            }
        } catch {
            Write-Debug "Get-VMIp: utmctl ip-address failed for ${VMName}: $_"
        }
    }
    # Fallback: macOS shared-NAT DHCP server's lease file. cloud-init sets
    # the guest hostname to VMName, so the lease's name= matches.
    $leaseFile = '/var/db/dhcpd_leases'
    if (Test-Path $leaseFile) {
        try {
            $content = Get-Content $leaseFile -Raw -ErrorAction Stop
            $blocks = [regex]::Matches($content, '\{[^}]*\}')
            foreach ($b in $blocks) {
                $text = $b.Value
                if ($text -match "(?m)^\s*name=$([regex]::Escape($VMName))\s*$") {
                    if (($text -match "(?m)^\s*ip_address=(\d+\.\d+\.\d+\.\d+)\s*$") -and (Test-Ipv4Address $Matches[1])) {
                        return [string]$Matches[1]
                    }
                }
            }
        } catch {
            Write-Debug "Get-VMIp: dhcpd_leases lookup failed for ${VMName}: $_"
        }
    }
    return $null
}

<#
.SYNOPSIS
    Return the guest's MAC address, or null if not available.
#>
function Get-VMMac {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    Write-Verbose "Get-VMMac on host.macos.utm: not implemented for '$VMName' (utmctl does not expose MAC; would require config.plist parsing)."
    return $null
}

# === Networking =============================================================

<#
.SYNOPSIS
    Return the name of the host-side External-type vSwitch or network.
#>
function Get-ExternalNetwork {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # macOS UTM uses VMnet shared / VZ NAT; there's no operator-managed
    # 'external network' to pick by name. Return the conventional value
    # so callers can compare without branching on host.
    return 'vmnet-shared'
}

<#
.SYNOPSIS
    Create the host-side External-type vSwitch or network if missing.
#>
function New-ExternalNetwork {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param()
    if (-not $PSCmdlet.ShouldProcess('vmnet-shared', 'No-op on macOS UTM (managed by VMnet)')) { return $null }
    return 'vmnet-shared'
}

<#
.SYNOPSIS
    Returns true if the squid-cache VM is on an External-type network.
.DESCRIPTION
    On macOS the cache VM is built with VZBridgedNetworkDeviceAttachment
    (see host/macos.utm/guest.squid-cache/config.plist.template), so it
    rides the host's physical LAN with its own DHCP-assigned IP. That
    is the macOS analog of Hyper-V's Yuruna-External vSwitch path: the
    caller's "no host portproxy needed" fast path applies unconditionally
    on this host. VMName is accepted for cross-host parity (Hyper-V
    consults Get-VMNetworkAdapter); we never look at the VM here.
#>
function Test-CacheVMOnExternalNetwork {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VMName = 'yuruna-caching-proxy')
    Write-Debug "Test-CacheVMOnExternalNetwork on host.macos.utm: returning `$true for '$VMName' (cache VM is VZ-bridged to the host's physical NIC)."
    return $true
}

<#
.SYNOPSIS
    Install host to VM port forwarders for the caching proxy.
#>
function Add-PortMap {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMIp,
        [int[]]$Port = @(3000),
        [hashtable]$PortRemap = @{},
        [int[]]$ProxyProtocolPort = @()
    )
    if (-not $PSCmdlet.ShouldProcess($VMIp, "Install pwsh forwarders for ports $($Port -join ',')")) { return $false }
    if (-not (Test-Ipv4Address $VMIp)) {
        # macOS Add-PortMap drives the host-side pwsh forwarders that bind
        # IPv4 sockets to the cache VM. v6 inputs (which Test-IpAddress
        # accepts as operator-facing values elsewhere) are rejected here
        # because the forwarder mechanism currently targets v4.
        Write-Warning "Add-PortMap: VMIp '$VMIp' is not a valid IPv4 address (pwsh forwarders are v4-only today) -- skipping."
        return $false
    }
    $proxyProtoSet = @{}
    foreach ($p in $ProxyProtocolPort) { $proxyProtoSet[[int]$p] = $true }
    $remapHostPorts = @{}
    foreach ($k in $PortRemap.Keys) { $remapHostPorts[[int]$k] = [int]$PortRemap[$k] }
    $mappings = @()
    foreach ($p in $Port) {
        if ($remapHostPorts.ContainsKey([int]$p)) { continue }
        $mappings += [PSCustomObject]@{ HostPort = [int]$p; VMPort = [int]$p }
    }
    foreach ($k in $remapHostPorts.Keys) {
        $mappings += [PSCustomObject]@{ HostPort = [int]$k; VMPort = [int]$remapHostPorts[$k] }
    }
    # Apple VZ shared-NAT path: per-port pwsh TcpListener via Yuruna.Host.psm1's
    # Start-CachingProxyForwarder. Each call is idempotent per port and
    # leaves OTHER ports' forwarders alone -- mid-cycle :3000 refresh
    # MUST NOT disturb the running :3128 forwarder.
    $launched = @()
    foreach ($m in $mappings) {
        $useProxy = $proxyProtoSet.ContainsKey([int]$m.HostPort)
        $proxyTag = if ($useProxy) { ' [PROXY v1]' } else { '' }
        if (-not $PSCmdlet.ShouldProcess("0.0.0.0:$($m.HostPort) -> ${VMIp}:$($m.VMPort)${proxyTag}", 'Launch macOS squid forwarder')) { continue }
        $started = if ($useProxy) {
            Start-CachingProxyForwarder -CacheIp $VMIp -Port $m.HostPort -VMPort $m.VMPort -PrependProxyV1
        } else {
            Start-CachingProxyForwarder -CacheIp $VMIp -Port $m.HostPort -VMPort $m.VMPort
        }
        if ($started) { $launched += $m.HostPort }
    }
    return ($launched.Count -gt 0)
}

<#
.SYNOPSIS
    Tear down all yuruna caching-proxy port forwarders.
#>
function Remove-PortMap {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('pwsh forwarders', 'Stop all yuruna port forwarders')) { return $false }
    $stopped = @(Stop-AllCachingProxyForwarder)
    return ($stopped.Count -gt 0)
}

<#
.SYNOPSIS
    Return the host's best LAN-routable IPv4 for browser-facing URLs.
#>
function Get-BestHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # `route -n get default` -> default-route interface, then
    # `ipconfig getifaddr <iface>` for that interface's IPv4. Skips
    # loopback / utun / VZ bridges (no default route).
    $routeOut = & '/sbin/route' -n get default 2>$null
    $iface = $null
    foreach ($line in $routeOut) {
        if ($line -match 'interface:\s*(\S+)') { $iface = $matches[1]; break }
    }
    if (-not $iface) { return $null }
    $ip = "$( & '/usr/sbin/ipconfig' getifaddr $iface 2>$null )".Trim()
    if (Test-Ipv4Address $ip) { return $ip }
    return $null
}

<#
.SYNOPSIS
    Returns the host IP a UTM Apple Virtualization guest reaches the host at.

.DESCRIPTION
    On Apple Virtualization shared NAT (the default UTM networking mode for
    this repo), guests always reach the host at 192.168.64.1 -- that is the
    VZ gateway IP set by the framework, not configurable per VM. The same
    constant is hardcoded as the squid-cache forwarder URL in
    guest.ubuntu.server/New-VM.ps1, by long convention.

    Bridged networking (not the repo default) would route guests via the
    host's LAN IP instead. If/when that mode is added, this helper needs a
    mode-detection branch.

.PARAMETER SwitchName
    Accepted for cross-host contract parity (Hyper-V uses it to choose
    Default Switch vs. External vSwitch); unused on macOS.

.OUTPUTS
    [string] '192.168.64.1' -- the VZ gateway address.
#>
function Get-GuestReachableHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$SwitchName)
    # macOS has no Default Switch / External vSwitch concepts; SwitchName
    # is accepted for cross-host parity and the answer is the VZ gateway.
    if ($SwitchName) { Write-Debug "Get-GuestReachableHostIp on host.macos.utm: -SwitchName '$SwitchName' ignored; VMnet shared gateway is implied." }
    return '192.168.64.1'
}

# === Caching proxy ==========================================================

<#
.SYNOPSIS
    Returns the host's LAN /24 prefix (e.g. '192.168.7.') based on the
    default-route interface, or $null when the host has no default route.
.DESCRIPTION
    Used by Start-CachingProxy.ps1 Step 5 to locate the just-booted
    bridged squid-cache VM by walking the same /24 the host sits on,
    and reserved for a future LAN-wide cache-discovery feature. (It is
    NOT consulted by Test-CachingProxyAvailable, which is restricted to
    state-file + YURUNA_CACHING_PROXY_IP discovery.) Returns the first
    three octets with a trailing dot so the caller can append
    "$prefix$octet" without further string surgery. /24 is an assumption
    -- it matches the home/office DHCP setups the repo targets; a /23
    LAN would silently miss half the address space. Acceptable trade-off
    given the alternative is parsing the netmask from `ifconfig` output
    for what is, in practice, a /24 99% of the time.
.OUTPUTS
    [string] e.g. '192.168.7.' (with trailing dot), or $null.
#>
function Get-HostLanPrefix {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $hostIp = Get-BestHostIp
    if (-not $hostIp) { return $null }
    if ($hostIp -notmatch '^(\d+\.\d+\.\d+)\.(\d+)$') { return $null }
    return ($matches[1] + '.')
}

<#
.SYNOPSIS
    Probe and return the squid-cache URL, or null if none is reachable.
.DESCRIPTION
    Discovery is intentionally narrow -- only caches this host owns,
    or a remote cache the operator explicitly named, are returned:
      1. $Env:YURUNA_CACHING_PROXY_IP -- explicit remote cache override.
      2. State file (Read-CachingProxyState).ipAddress -- the cache VM's
         LAN IP written by Start-CachingProxy.ps1 Step 4 (our own VM).

    No LAN scan, no ARP discovery. The previous /24 subnet scan would
    happily lock onto a sibling host's yuruna-caching-proxy on the same
    LAN and even persist its IP back into the state file, so Stop-
    CachingProxy could not actually take the local host out of the
    "cache available" state when a peer was still serving on :3128.
    LAN-wide cache discovery is a separate future feature.

    Returns the cache VM's LAN URL directly -- no host-side forwarder
    layer to fail in between, no VZ-gateway URL gymnastics. This is the
    macOS equivalent of the Hyper-V Yuruna-External vSwitch path: squid
    sees real client IPs at TCP level, remote operators set
    YURUNA_CACHING_PROXY_IP=<cache-lan-ip> and reach the cache directly,
    and other UTM guests on shared-NAT reach the LAN IP through the
    VMnet outbound NAT (same path they use to reach Ubuntu mirrors).
#>
function Test-CachingProxyAvailable {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $httpPort = Get-CachingProxyPort -Scheme http
    # External cache override (same shape as the Windows host).
    if ($Env:YURUNA_CACHING_PROXY_IP) {
        $externIp = $Env:YURUNA_CACHING_PROXY_IP.Trim()
        if (-not (Test-IpAddress $externIp)) {
            Write-Warning "YURUNA_CACHING_PROXY_IP='$externIp' is not a valid IPv4 or IPv6 address -- ignoring."
            return $null
        }
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $tcp.BeginConnect($externIp, $httpPort, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(1000) -and $tcp.Connected) {
                return "http://$(Format-IpUrlHost $externIp):${httpPort}"
            }
        } catch {
            Write-Verbose "external caching proxy probe to ${externIp}:${httpPort} failed: $($_.Exception.Message)"
        } finally {
            $tcp.Close()
        }
        Write-Warning "YURUNA_CACHING_PROXY_IP=${externIp} set but ${externIp}:${httpPort} did not answer."
        return $null
    }

    # Local cache: probe only the IP we recorded ourselves at the last
    # Start-CachingProxy.ps1. Empty state -> no cache (the explicit
    # contract after Stop-CachingProxy.ps1). State-set-but-unreachable
    # is loud (Write-Warning) because the inner runner's bootstrap
    # detection runs ONCE per cycle -- a silently-failed probe means
    # the whole cycle's guests download direct from the internet, and
    # we want the operator to see "why" alongside the headline
    # "Caching proxy: not detected" line in Invoke-TestRunner output.
    $stateIp = (Read-CachingProxyState).ipAddress
    if (-not $stateIp -or -not (Test-IpAddress $stateIp)) {
        Write-Warning "Test-CachingProxyAvailable: state.ipAddress is empty -- no locally-owned cache. Set `$Env:YURUNA_CACHING_PROXY_IP to point at a remote cache, or run Start-CachingProxy.ps1."
        return $null
    }
    # 1500 ms matches test/Test-CachingProxy.ps1's CLI probe so a
    # cache that answers the standalone smoke test also answers here;
    # the earlier 500 ms left a window where a momentarily busy squid
    # (cold start, big cidata fetch) would miss the runner's single
    # bootstrap probe and silently strand the whole inner cycle.
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $tcp.BeginConnect($stateIp, $httpPort, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne(1500) -and $tcp.Connected) {
            return "http://$(Format-IpUrlHost $stateIp):${httpPort}"
        }
    } catch {
        Write-Verbose "cache probe ${stateIp}:${httpPort} failed: $($_.Exception.Message)"
    } finally {
        $tcp.Close()
    }
    Write-Warning "Test-CachingProxyAvailable: state.ipAddress=${stateIp} did not answer :${httpPort} within 1500 ms; treating cache as unavailable. Verify with 'nc -G 2 -z ${stateIp} ${httpPort}'; if it answers, the cache is running and the next runner cycle will pick it up. If not, re-run Start-CachingProxy.ps1 (the VM may have restarted with a new DHCP lease)."
    return $null
}

<#
.SYNOPSIS
    Return the cache VM's LAN IP, or $null when none is recorded yet.
.DESCRIPTION
    With Apple Virtualization bridged networking the cache VM gets its
    own DHCP-assigned LAN IP (no VZ-gateway indirection), so the URL
    Test-CachingProxyAvailable returns already carries the real IP. This
    helper exists for callers that want JUST the IP (status server's
    portproxy IP target on Windows; on macOS the result feeds into
    summary lines and YURUNA_CACHING_PROXY_IP hints).
#>
function Get-CachingProxyVMIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $ip = (Read-CachingProxyState).ipAddress
    if ($ip -and (Test-Ipv4Address $ip)) { return $ip }
    return $null
}

# === Host config ============================================================

<#
.SYNOPSIS
    Promote a proxy URL to the machine-wide host proxy with backup.
#>
function Set-HostProxy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ProxyUrl,
        [string]$NetworkService
    )
    if (-not $PSCmdlet.ShouldProcess('macOS networksetup', "Set proxy = $ProxyUrl")) { return $false }
    $parts = ConvertTo-ProxyHostPort -Url $ProxyUrl
    $backupPath = Get-HostProxyBackupPath
    Invoke-MacElevationIfNeeded
    $svc = if ($NetworkService) { $NetworkService } else { Get-MacActiveNetworkService }
    if (-not $svc) {
        throw "Could not auto-detect the active macOS network service. Pass -NetworkService 'Wi-Fi' (or the name of your active service)."
    }
    if (-not (Test-Path -LiteralPath $backupPath)) {
        $state = Read-MacProxyState -NetworkService $svc
        $state['timestamp']  = (Get-Date).ToUniversalTime().ToString('o')
        $state['promotedTo'] = $parts.Url
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupPath -Encoding UTF8
        Write-Information "  Host proxy: backup written to $backupPath"
    } else {
        Write-Information "  Host proxy: existing backup at $backupPath preserved (still apply)"
    }
    Set-MacHostProxy -ProxyParts $parts -NetworkService $svc -Confirm:$false
    Write-Information "  Host proxy: macOS networksetup on service '$svc' set to $($parts.Url)"
    return $true
}

<#
.SYNOPSIS
    Restore the host proxy from the saved backup, or disable if none.
#>
function Clear-HostProxy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('macOS networksetup', 'Disable proxy / restore backup')) { return $false }
    $backupPath = Get-HostProxyBackupPath
    $state = $null
    if (Test-Path -LiteralPath $backupPath) {
        try {
            $state = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json -AsHashtable
        } catch {
            Write-Warning "Host proxy: could not parse backup '$backupPath' ($($_.Exception.Message)). Falling back to disable-only."
            $state = $null
        }
    }
    if ($state) {
        Invoke-MacElevationIfNeeded
        Restore-MacHostProxy -State $state
        Write-Information "  Host proxy: macOS proxy state restored on service '$($state.networkService)'"
    } else {
        try { Invoke-MacElevationIfNeeded } catch {
            Write-Warning "  Host proxy: no backup found and could not get sudo ($($_.Exception.Message)); skipping macOS disable."
            return $false
        }
        Disable-MacHostProxy
        Write-Information "  Host proxy: macOS proxy disabled (no backup to restore)"
    }
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
    return $true
}

<#
.SYNOPSIS
    Aggressively wipe every host-proxy reference and the backup file.
#>
function Remove-HostProxy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string]$NetworkService)
    if (-not $PSCmdlet.ShouldProcess('macOS proxy state', 'Wipe host proxy state')) { return $false }
    Invoke-MacElevationIfNeeded
    $svc = if ($NetworkService) { $NetworkService } else { Get-MacActiveNetworkService }
    if (-not $svc) {
        Write-Warning "Remove-HostProxy: could not auto-detect active network service; nothing to wipe."
        return $false
    }
    Remove-MacHostProxy -NetworkService $svc
    # Verify the wipe actually took. networksetup silently ignores invalid
    # service names and `-setwebproxy` re-enables state as a side-effect, so
    # the log line below has to be earned, not asserted. Parse the live
    # state and refuse to claim "wiped" if web/secure web is still Enabled.
    $webProbe = ''
    $sslProbe = ''
    try {
        $webProbe = (& networksetup -getwebproxy        $svc) 2>&1 | Out-String
        $sslProbe = (& networksetup -getsecurewebproxy  $svc) 2>&1 | Out-String
    } catch {
        Write-Warning "  Host proxy: post-wipe probe failed ($($_.Exception.Message)); state on '$svc' is unverified."
    }
    $webEnabled = ($webProbe -match '(?m)^Enabled:\s*Yes')
    $sslEnabled = ($sslProbe -match '(?m)^Enabled:\s*Yes')
    if ($webEnabled -or $sslEnabled) {
        Write-Warning ("  Host proxy: wipe on '{0}' FAILED -- web Enabled={1}, securewebproxy Enabled={2}. Live state:`n{3}{4}" -f `
            $svc, $webEnabled, $sslEnabled, $webProbe.TrimEnd(), $sslProbe.TrimEnd())
        return $false
    }
    Write-Information "  Host proxy: macOS networksetup state on '$svc' wiped (web/securewebproxy off, server cleared, bypass empty)"
    $backupPath = Get-HostProxyBackupPath
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
    return $true
}

<#
.SYNOPSIS
    Return the path of the host-proxy backup JSON.
#>
function Get-HostProxyBackupPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return Test.VM.common\Get-HostProxyBackupPath
}

<#
.SYNOPSIS
    Returns true if the host hypervisor is installed and ready.
#>
function Assert-Virtualization {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    # Assert-VirtualizationFrameworkEnabled lives in Enable-TestAutomation.ps1
    # not in a module. UTM's presence + Apple Virtualization availability is
    # the practical signal here.
    return [bool](Test-Path '/Applications/UTM.app')
}

# === SSH server (host-side) =================================================

<#
.SYNOPSIS
    Returns true if the host has a code path for SSH-server lifecycle.
#>
function Test-SshServerSupported {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    # macOS Remote Login: not yet wired into the harness. The legacy
    # Test.SshServer returned $false here (deferred); preserve that.
    return $false
}

<#
.SYNOPSIS
    Returns true if the host SSH server is installed.
#>
function Test-SshServerInstalled {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return $false
}

<#
.SYNOPSIS
    Install the host SSH server (idempotent).
#>
function Install-SshServer {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('macOS Remote Login', 'Enable')) { return $false }
    Write-Information "SSH server install on host.macos.utm: not yet implemented (placeholder)." -InformationAction Continue
    return $true
}

<#
.SYNOPSIS
    Start the host SSH server and set it to autostart.
#>
function Start-SshServer {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('macOS Remote Login', 'Start')) { return $false }
    Write-Information "SSH server enable on host.macos.utm: not yet implemented (placeholder)." -InformationAction Continue
    return $true
}

<#
.SYNOPSIS
    Stop the host SSH server.
#>
function Stop-SshServer {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('macOS Remote Login', 'Stop')) { return $false }
    Write-Information "SSH server disable on host.macos.utm: not yet implemented (placeholder)." -InformationAction Continue
    return $true
}

<#
.SYNOPSIS
    Return 'running', 'stopped', 'not-installed', or 'unsupported'.
#>
function Get-SshServerStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'unsupported'
}

# === Exports ================================================================

Export-ModuleMember -Function `
    New-VM, Start-VM, Stop-VM, Stop-VMForce, Remove-VM, Get-VMState, `
    Test-VMConsoleOpen, Restart-VMConsole, `
    Get-Image, Get-ImagePath, `
    Send-Text, Send-Key, Send-Click, Get-VMScreenshot, Get-VMConsoleHandle, `
    Wait-VMIp, Get-VMIp, Get-VMMac, `
    Get-ExternalNetwork, New-ExternalNetwork, Test-CacheVMOnExternalNetwork, `
    Add-PortMap, Remove-PortMap, Get-BestHostIp, Get-GuestReachableHostIp, `
    Test-CachingProxyAvailable, Get-CachingProxyVMIp, Get-HostLanPrefix, `
    Set-HostProxy, Clear-HostProxy, Remove-HostProxy, Get-HostProxyBackupPath, Assert-Virtualization, `
    Test-SshServerSupported, Test-SshServerInstalled, Install-SshServer, `
    Start-SshServer, Stop-SshServer, Get-SshServerStatus, `
    `
    Remove-UtmBundleWithRetry, Invoke-EntitledSwift, `
    Start-CachingProxyForwarder, Stop-CachingProxyForwarder, Get-CachingProxyForwarder, Stop-AllCachingProxyForwarder, `
    Test-DownloadAlreadyCurrent, Test-CacheTcpPort, Resolve-CacheHostIp, Get-CacheProxyForHostDownload, `
    Save-CachedHttpUri, Invoke-HttpsViaSquidBump, `
    Stop-UtmDialogWatchdog, Start-UtmDialogWatchdog, `
    Confirm-UtmVMCreated, Remove-UtmTestVM, Start-UtmVM, Stop-UtmVM, Confirm-UtmVMStarted, Restart-UtmConsole, `
    Get-MacProxyMarkerPath, Test-MacProxyIsYurunaManaged, Get-MacActiveNetworkService, Read-MacProxyState, `
    Invoke-MacElevationIfNeeded, Invoke-MacNetworksetup, `
    Set-MacHostProxy, Restore-MacHostProxy, Disable-MacHostProxy, Remove-MacHostProxy, `
    Get-VncDisplayForVm, Get-VncPortForVm, Get-VncScreenshot, Get-UtmScreenshot, Get-UtmWindowScreenshot
