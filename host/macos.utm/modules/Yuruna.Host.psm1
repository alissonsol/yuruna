<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e91
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host macos utm
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.RELEASENOTES
    Yuruna host driver for macOS + UTM. Implements the Yuruna.Host
    driver contract defined in host/Yuruna.Host.Contract.psm1 (rationale in docs/host-io.md).
#>

#requires -version 7

<#
.SYNOPSIS
    Yuruna host driver for macOS + UTM (Apple Silicon and Intel).

.DESCRIPTION
    Self-contained host driver: contract surface plus the UTM/macOS
    helpers it consumes. Cross-host helpers live in
    automation/Yuruna.Common.psm1 and test/modules/Test.Ssh.psm1, imported below.
    Module-qualified calls (e.g. `Yuruna.HostDownload\Save-CachedHttpUri`) appear
    where an external helper shares its name with the contract function
    -- without the qualifier the call would re-enter our own definition
    and recurse.
#>

# --- REGION: Module setup

$script:HostTag        = 'host.macos.utm'
$script:RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:TestModulesDir = Join-Path $script:RepoRoot 'test/modules'
$script:HostFolder     = Join-Path $script:RepoRoot 'host/macos.utm'

<#
.SYNOPSIS
    Returns this driver's host tag, repairing it if module state was lost.
.DESCRIPTION
    $script: state does not survive this module being -Force re-imported
    (feedback_module_script_state_reset_by_force_reimport). A caller holding
    an already-resolved reference to a contract function keeps running against
    the evicted instance, whose session state has been torn down, and
    $script:HostTag then reads as an empty string.

    That empty string is load-bearing: binding it to the dispatcher's
    -HostType fails with "Cannot bind argument to parameter 'HostType'
    because it is an empty string", so the keystroke types nothing while the
    caller sees only a non-terminating error and carries on. A console line
    left half-typed that way stays in the tty and the next text sent to the
    guest is appended to it, surfacing much later as a command nobody wrote.

    The tag is a compile-time constant for this driver, so resolving it
    through a literal fallback makes the empty binding impossible regardless
    of module lifetime, and restores the variable for any other reader that
    can still reach this scope.
#>
function Resolve-HostTag {
    [OutputType([string])]
    param()
    if ([string]::IsNullOrWhiteSpace($script:HostTag)) { $script:HostTag = 'host.macos.utm' }
    return $script:HostTag
}

# These dependency modules are imported -Global: Yuruna.Host is -Force re-imported
# mid-cycle, and a bare -Force import here lands in Yuruna.Host's nested scope and
# EVICTS the global copy other modules call via qualified names (e.g.
# Test.Ssh\Invoke-GuestSsh) -- feedback_module_force_import_evicts_global.
Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking -Global
Import-Module (Join-Path $script:TestModulesDir 'Test.Ssh.psm1')          -Force -DisableNameChecking -Global
Import-Module (Join-Path $script:TestModulesDir 'Test.CachingProxyService.psm1') -Force -DisableNameChecking -Global
# Shared squid download / TLS-bump stack -- single source of truth across host drivers.
# The X509 chain-validation callback lives here verbatim; per-driver cache-host
# discovery is injected via the -ResolveCacheHostIp scriptblock (see wrapper below).
Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostDownload.psm1') -Force -DisableNameChecking -Global
# Download-agent client. The Get-Image hooks feature-detect its two functions by
# name, so this import is what decides whether the agent path exists at all on
# this host; without it the agent is silently never consulted.
Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.DownloadAgent.psm1') -Force -DisableNameChecking -Global
# Shared per-guest provisioning helpers (the New-VM.ps1 child-runner +
# the Get-Image log-line writer) common to all three drivers.
Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostProvision.psm1') -Force -DisableNameChecking -Global
# --- REGION: macOS/UTM host helpers

<#
.SYNOPSIS
    Removes a UTM .utm bundle from disk with retry-on-EACCES.

.DESCRIPTION
    After `utmctl delete`, UTM.app (and its QEMUHelper.xpc) can hold file
    handles on bundle contents for a few seconds -- most commonly on the
    mmap'd sparse disk.img or on efi_vars.fd. A single-shot
    `Remove-Item -Recurse -Force` during that window fails with "Access
    to the path '...' is denied" even though the bundle is deregistered
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
                Write-Information "Removed UTM bundle after $attempt attempt(s): $Path" -InformationAction Continue
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
            $sleepSeconds = 2 * $attempt
            Write-Warning "Remove-Item attempt $attempt/$MaxAttempts on '$Path' failed: $($_.Exception.Message). Retrying in ${sleepSeconds}s..."
            Start-Sleep -Seconds $sleepSeconds
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
    Launches (or stops) the caching-proxy-service TCP forwarder on the Mac host.

.DESCRIPTION
    Exposes the Shared-NAT caching-proxy-service VM to REMOTE LAN hosts: it binds
    a cache port on the host's LAN IP and tunnels to $CacheIp on the
    192.168.64.0/24 vmnet subnet, so machines elsewhere on the LAN can use
    the cache. Same-Mac UTM guests do NOT need this -- on macOS 26 every
    vmnet-shared VM joins one bridge (192.168.64.1) and guests reach a
    sibling VM's 192.168.64.x IP directly. (An older belief that shared-NAT
    blocks guest-to-guest ARP on 192.168.64.0/24 did not reproduce there.)

    Start-CachingProxyServiceForwarder spawns Start-CachingProxyServiceForwarder.ps1
    as a detached `pwsh` subprocess that binds :3128 on the host and
    tunnels to $CacheIp:3128. Detached so the forwarder outlives
    Start-CachingProxyServiceVM.ps1 (it survives the launcher exiting -- it is
    reparented to launchd -- but any Remove-PortMap still tears it down).

    PID is written to $HOME/yuruna/image/caching-proxy-service/forwarder.<Port>.pid.
    Stop-CachingProxyServiceForwarder reads it and sends SIGTERM.
    Get-CachingProxyServiceForwarder reports liveness without signaling.

    Returns $true when the forwarder is verified listening (Start),
    terminated (Stop), or currently running (Get).

.PARAMETER CacheIp
    IP of the caching-proxy-service VM (Start-CachingProxyServiceForwarder only). Typically
    192.168.64.X discovered by Start-CachingProxyServiceVM.ps1's subnet probe.
#>
function Start-CachingProxyServiceForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$CacheIp,
        [int]$Port = $(Get-CachingProxyServicePort -Scheme http),
        [int]$VMPort = 0,
        [switch]$PrependProxyV1
    )
    # 0 sentinel -- when unspecified, host port == VM port (the common case;
    # proxy/Grafana/etc.). Split ports kick in for SSH (8022 -> 22) and any
    # other future host:VM remap. Pidfile name uses HOST port (predictable;
    # what `lsof -i :<host>` would show).
    if ($VMPort -eq 0) { $VMPort = $Port }
    # Forwarder script lives at host/macos.utm/Start-CachingProxyServiceForwarder.ps1.
    # Use $script:HostFolder (set at module load) instead of $PSScriptRoot:
    # the module-scoped variable is anchored to the .psm1's directory, so
    # the lookup is independent of how the function is dispatched.
    $forwarderScript = Join-Path $script:HostFolder "Start-CachingProxyServiceForwarder.ps1"
    if (-not (Test-Path $forwarderScript)) {
        Write-Warning "Start-CachingProxyServiceForwarder.ps1 not found at: $forwarderScript"
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess("0.0.0.0:${Port} -> ${CacheIp}:${VMPort}", 'Launch detached host-side TCP forwarder')) {
        return $false
    }
    $stateDir = Join-Path $HOME "yuruna/image/caching-proxy-service"
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
    [void](Stop-CachingProxyServiceForwarder -Port $Port -Quiet)

    $proxyTag = if ($PrependProxyV1) { ' [PROXY v1]' } else { '' }
    Write-Information "  Launching host-side forwarder: 0.0.0.0:${Port} -> ${CacheIp}:${VMPort}${proxyTag}" -InformationAction Continue
    # RedirectStandard* is required: without them pwsh inherits the
    # parent TTY and dies when Start-CachingProxyServiceVM.ps1 exits. The
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
    # Start-CachingProxyServiceVM.ps1 which called `sudo -v` first), leave it alone.
    # Killing a root process requires sudo credentials that the caller
    # (e.g. Invoke-TestRunner) may not have cached -- and the correct CacheIp
    # is already baked into the running process. Only restart if crashed.
    if ($needsSudo -and (Get-CachingProxyServiceForwarder -Port $Port)) {
        Write-Information "  Port ${Port} forwarder already running (root-owned); skipping restart." -InformationAction Continue
        return $true
    }

    # -n on the sudo spawn: this is a DETACHED process whose stdout and stderr
    # are redirected to files, so a password prompt would be written to a log
    # and the forwarder would sit there unbound until something noticed. With -n
    # a missing credential fails immediately and the bind wait below reports it.
    $spawnFile = if ($needsSudo) { 'sudo' } else { 'pwsh' }
    $spawnArgs = if ($needsSudo) { @('-n', '-E', 'pwsh') + $procArgs } else { $procArgs }

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
                Write-Information "  $upMsg" -InformationAction Continue
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
    # A non-answering child may still be half-bound (listener up, connect
    # racing) or wedged. Tear it down so it is not orphaned holding the
    # port past our return. Prefer the pidfile-driven, identity-verified
    # stop (matches Start-CachingProxyServiceForwarder.ps1, honors root ownership);
    # if the child never wrote its pidfile, signal the spawned pid directly.
    if (Test-Path $pidFile) {
        [void](Stop-CachingProxyServiceForwarder -Port $Port -Quiet)
    } else {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop }
        catch { Write-Verbose "Could not stop orphaned forwarder pid $($proc.Id): $_" }
    }
    return $false
}

<#
.SYNOPSIS
    Terminates the host-side caching-proxy-service TCP forwarder if it is running.

.DESCRIPTION
    Reads $HOME/yuruna/image/caching-proxy-service/forwarder.<Port>.pid and verifies the
    PID belongs to Start-CachingProxyServiceForwarder.ps1 (via /bin/ps -o
    command=) before signaling -- a stale pidfile pointing at an
    unrelated process must NOT be killed. Sends SIGTERM and waits up to
    2s; escalates to SIGKILL if no response. The pidfile is removed on
    every success path and on stale-pidfile detection so the next Start
    call is clean.

.PARAMETER Quiet
    Suppress the informational Write-Output lines. Start-CachingProxyServiceForwarder
    passes this when preflight-stopping a stale forwarder so the happy
    path stays quiet.

.OUTPUTS
    [bool] $true on any exit where the pidfile is in a coherent state
    (process stopped or never running). No current failure modes
    surface as $false.
#>
function Stop-CachingProxyServiceForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [int]$Port = $(Get-CachingProxyServicePort -Scheme http),
        [switch]$Quiet
    )
    $pidFile = Join-Path $HOME "yuruna/image/caching-proxy-service/forwarder.$Port.pid"
    if (-not (Test-Path $pidFile)) {
        if (-not $Quiet) { Write-Output "  No forwarder pidfile -- nothing to stop." }
        return $true
    }
    $forwarderPid = (Get-Content $pidFile -Raw).Trim()
    if (-not ($forwarderPid -as [int])) {
        if (-not $Quiet) { Write-Warning "Pidfile '$pidFile' contents invalid: '$forwarderPid' -- removing." }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    # Verify the process looks like our forwarder before killing.
    # `/bin/ps` path-qualified so PSScriptAnalyzer's PSAvoidUsingCmdletAliases
    # doesn't confuse it with the `ps` alias for Get-Process. -o command=
    # prints full argv so we can match Start-CachingProxyServiceForwarder.ps1 and
    # avoid killing an unrelated pid that matches a stale pidfile.
    $cmd = (& '/bin/ps' -p $forwarderPid -o command= 2>$null) -join ""
    if ($LASTEXITCODE -ne 0 -or -not $cmd) {
        if (-not $Quiet) { Write-Output "  Forwarder pid $forwarderPid not running -- cleaning pidfile." }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    if ($cmd -notmatch 'Start-CachingProxyServiceForwarder\.ps1') {
        if (-not $Quiet) { Write-Warning "Pid $forwarderPid is not Start-CachingProxyServiceForwarder.ps1 (is: $cmd) -- leaving alone, removing stale pidfile." }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess("pid $forwarderPid (Start-CachingProxyServiceForwarder.ps1)", 'SIGTERM then SIGKILL if needed')) {
        return $false
    }
    if (-not $Quiet) { Write-Output "  Stopping forwarder (pid $forwarderPid)..." }
    # /bin/kill sends SIGTERM (default). PowerShell 7's Stop-Process on
    # Unix maps to Process.Kill() == SIGKILL unconditionally, bypassing
    # graceful shutdown -- hence the external binary for TERM-then-KILL.
    # Port 80's forwarder is root-owned (spawned via sudo); a regular user
    # cannot signal it -- detect and escalate via sudo kill if needed.
    $procOwner = "$( & '/bin/ps' -p $forwarderPid -o 'user=' 2>$null )".Trim()
    $meIsRoot  = $false
    try { $meIsRoot = ((& '/usr/bin/id' -u) -eq '0') } catch { Write-Verbose "id -u check failed, assuming non-root: $_" }
    $useSudo   = ($procOwner -eq 'root') -and (-not $meIsRoot)
    if ($useSudo) {
        # -n: this runs inside teardown paths whose console belongs to a caller,
        # and sudo takes its password from /dev/tty regardless of how stdin was
        # set up -- so a cold credential here would stall the teardown on a
        # prompt nobody sees, rather than reporting that root was unavailable.
        & sudo -n '/bin/kill' $forwarderPid 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0 -and -not $Quiet) {
            Write-Warning "Could not signal root-owned forwarder $forwarderPid without a password. Run: sudo kill $forwarderPid"
        }
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
    if (-not $Quiet) { Write-Warning "Forwarder $forwarderPid did not exit after SIGTERM -- sending SIGKILL." }
    if ($useSudo) {
        & sudo -n '/bin/kill' -9 $forwarderPid 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0 -and -not $Quiet) {
            Write-Warning "Could not SIGKILL root-owned forwarder $forwarderPid without a password. Run: sudo kill -9 $forwarderPid"
        }
    } else {
        & '/bin/kill' -9 $forwarderPid 2>$null | Out-Null
    }
    Start-Sleep -Milliseconds 200
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    return $true
}

<#
.SYNOPSIS
    Reports whether the host-side caching-proxy-service TCP forwarder is running.

.DESCRIPTION
    Pure observer -- never signals, never removes files. Returns $true
    iff $HOME/yuruna/image/caching-proxy-service/forwarder.<Port>.pid exists, parses as
    an int, and refers to a live process (via /bin/ps). Does NOT verify
    the process is actually our forwarder; Stop-CachingProxyServiceForwarder
    handles that stricter identity check on the write path.

.OUTPUTS
    [bool] $true if the pidfile points at a live process, $false
    otherwise (missing pidfile, malformed content, or dead pid).
#>
function Get-CachingProxyServiceForwarder {
    [CmdletBinding()]
    [OutputType([bool])]
    param([int]$Port = $(Get-CachingProxyServicePort -Scheme http))
    $pidFile = Join-Path $HOME "yuruna/image/caching-proxy-service/forwarder.$Port.pid"
    if (-not (Test-Path $pidFile)) { return $false }
    $forwarderPid = (Get-Content $pidFile -Raw).Trim()
    if (-not ($forwarderPid -as [int])) { return $false }
    & '/bin/ps' -p $forwarderPid -o pid= 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS
    Stop every caching-proxy-service port forwarder the host currently has.

.DESCRIPTION
    Enumerates $HOME/yuruna/image/caching-proxy-service/forwarder.<Port>.pid entries
    and sends SIGTERM to each (SIGKILL escalation per port via
    Stop-CachingProxyServiceForwarder). Missing directory / no pidfiles is a
    no-op; safe to call even when nothing is running.

    The host-contract `Add-PortMap` / `Remove-PortMap` (declared in
    host/Yuruna.Host.Contract.psm1, implemented per platform) dispatch to
    Start-CachingProxyServiceForwarder + this function on macOS.

.OUTPUTS
    [int[]] -- ports whose forwarder was stopped (may be empty).
#>
function Stop-AllCachingProxyServiceForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int[]], [System.Object[]])]
    param([switch]$Quiet)
    $stateDir = Join-Path $HOME "yuruna/image/caching-proxy-service"
    if (-not (Test-Path $stateDir)) { return @() }
    $stopped = @()
    # Glob forwarder.<N>.pid; BaseName strips ".pid" so the regex only
    # needs the middle token.
    Get-ChildItem -LiteralPath $stateDir -Filter 'forwarder.*.pid' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.BaseName -match '^forwarder\.(\d+)$') {
                $portInt = [int]$matches[1]
                if ($PSCmdlet.ShouldProcess("port $portInt", 'Stop squid forwarder')) {
                    [void](Stop-CachingProxyServiceForwarder -Port $portInt -Quiet:$Quiet)
                    $stopped += $portInt
                }
            }
        }
    return ,$stopped
}

<#
.SYNOPSIS
    Returns the IP of a reachable caching-proxy-service (probed on :3128), or
    $null when no cache is currently usable. Prefers the direct VM IP
    so SSL-bump (:3129) and the CA endpoint (:80) are also reachable;
    falls back to 127.0.0.1 (host forwarder) for HTTP-only.

.DESCRIPTION
    Discovery order:
      1. The cache VM IP recorded in the yuruna-caching-proxy-service state
         file (<track>/yuruna-caching-proxy-service.yml, written by
         Start-CachingProxyServiceVM.ps1 with the VM's 192.168.64.X address).
         If reachable, return THIS IP; the caller can hit :80 / :3128
         / :3129 on it directly across Apple Virtualization shared NAT.
      2. 127.0.0.1 -- the local Start-CachingProxyServiceForwarder bridges
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
    $httpPort = Get-CachingProxyServicePort -Scheme http
    $ip = (Read-CachingProxyServiceState).ipAddress
    if ($ip -and (Test-IpAddress $ip) -and (Test-CachingProxyServicePort -IpAddress $ip -Port $httpPort -TimeoutMs 500)) {
        return $ip
    }
    if (Test-CachingProxyServicePort -IpAddress '127.0.0.1' -Port $httpPort -TimeoutMs 500) {
        return '127.0.0.1'
    }
    return $null
}

<#
.SYNOPSIS
    Download $Uri to $OutFile through the UTM caching-proxy service, falling back to
    a direct fetch when no cache is reachable.
.DESCRIPTION
    Thin driver-local wrapper over the shared download stack. The closure binds
    this driver's Resolve-CacheHostIp (UTM cache discovery) so the shared module
    stays platform-agnostic while still reaching macOS-specific cache lookup.
#>
function Save-CachedHttpUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    Yuruna.HostDownload\Save-CachedHttpUri -Uri $Uri -OutFile $OutFile -ResolveCacheHostIp { Resolve-CacheHostIp }
}

# --- REGION: VM lifecycle helpers
# UTM-internal helpers consumed by Yuruna.Host's contract entry points
# above. Not part of the test-facing host driver contract; test code
# calls the contract verbs (New-VM / Start-VM / ...) which delegate here.

# --- REGION: UTM dialog watchdog
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

# --- REGION: VM lifecycle

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
    # Write-Warning (not Write-Error) for this expected-negative outcome so the [bool] contract
    # holds under a caller's ErrorActionPreference=Stop instead of throwing a terminating error.
    Write-Warning "VM verification failed: $configPlist not found."
    return $false
}

<#
.SYNOPSIS
    True when UTM still holds a registration for the named VM.

.DESCRIPTION
    `utmctl status` exits 0 for every VM UTM knows about regardless of run
    state, and non-zero only when the name resolves to nothing, so it answers
    "is this name still registered" on its own. That makes it the check a
    delete has to be judged by -- `utmctl delete` does not report its own
    outcome reliably (see Remove-UtmVMRegistration).

.OUTPUTS
    [bool] $true when UTM still lists the name.
#>
function Test-UtmVMRegistered {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not (Get-Command utmctl -ErrorAction SilentlyContinue)) { return $false }
    $null = & utmctl status "$VMName" 2>&1
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS
    Deregister a VM from UTM, confirming by probe that the name is really gone.

.DESCRIPTION
    `utmctl delete` exits 0 even when it deleted nothing: it prints the reason
    ("Error from event: The operation couldn't be completed. (OSStatus error
    -2700.) '<name>.utm' couldn't be removed.") on stdout and still returns
    success. An exit-code check therefore reads a total failure as a clean
    delete, so every attempt here is judged by re-probing the registration.

    The case that cannot resolve itself is a registration whose bundle is
    missing from disk. UTM deletes a VM by moving its bundle to the trash, so
    with nothing at the recorded path the delete fails identically on every
    future attempt and the name stays registered indefinitely. That is not
    cosmetic: the name still answers `utmctl status`, so the sequence engine's
    reuse check treats it as an existing VM, skips creation, and hands a
    bundle-less name to Start-VM, which can only fail. Recreating an empty
    bundle directory at the expected path gives the trash-move something to
    operate on and the deregistration completes.

.PARAMETER MaxAttempts
    Delete attempts before giving up. The bundle-restore path needs a second
    pass by construction: the first attempt is what reveals the delete did not
    take.

.OUTPUTS
    [bool] $true when the name is no longer registered with UTM.
#>
function Remove-UtmVMRegistration {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$MaxAttempts = 3
    )
    if (-not (Test-UtmVMRegistered -VMName $VMName)) { return $true }
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Deregister VM from UTM')) { return $false }

    $utmBundle = "$HOME/yuruna/guest.nosync/$VMName.utm"
    $placeholderPath = $null
    try {
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            $deleteOutput = & utmctl delete "$VMName" 2>&1
            if (-not (Test-UtmVMRegistered -VMName $VMName)) { return $true }
            foreach ($line in @($deleteOutput)) {
                $text = "$line".Trim()
                if ($text) { Write-Verbose "utmctl delete '$VMName' (attempt $attempt): $text" }
            }
            if (-not (Test-Path -LiteralPath $utmBundle)) {
                Write-Information -MessageData "  UTM still lists '$VMName' but its bundle is gone; restoring an empty bundle at $utmBundle so the deregistration can complete." -InformationAction Continue
                $null = New-Item -Path $utmBundle -ItemType Directory -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $utmBundle) { $placeholderPath = $utmBundle }
                continue
            }
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds 3 }
        }
        return (-not (Test-UtmVMRegistered -VMName $VMName))
    } finally {
        # A placeholder that outlived a still-failing delete would be read as a
        # real bundle by anything sizing or inventorying the VM store, so it is
        # only allowed to persist when it is about to become the deleted VM's
        # trashed bundle. Guarded on emptiness so a bundle that reappeared
        # underneath (a concurrent New-VM for the same name) is never removed.
        if ($placeholderPath -and (Test-Path -LiteralPath $placeholderPath) -and
            -not (Get-ChildItem -LiteralPath $placeholderPath -Recurse -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $placeholderPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
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
    if ($LASTEXITCODE -eq 0) { Write-Output "Stopped UTM VM: $VMName" }
    # Confirm the VM is actually powered off (escalating to `utmctl stop --kill`
    # if the soft stop stalls) and its qcow2/bundle handles are released BEFORE
    # the deregistration -- otherwise the delete runs against a still-locked
    # bundle. Wait-UtmVMPoweredOff drives the same kill-escalation + lock check
    # the snapshot paths use.
    if (-not (Wait-UtmVMPoweredOff -VMName $VMName)) {
        Write-Warning "Remove-UtmTestVM: '$VMName' did not confirm powered-off within the timeout; proceeding with delete, but the bundle may still be locked."
    }
    if (-not (Remove-UtmVMRegistration -VMName $VMName -Confirm:$false)) {
        # Leaving the bundle on disk is the point. UTM deletes a VM by moving
        # its bundle to the trash, so removing the files under a registration
        # that survived strands the name in UTM with nothing left to delete --
        # and a stranded name is worse than a stranded bundle, because it still
        # answers `utmctl status` and so reads as a reusable VM to the sequence
        # engine, which then starts a VM that has no disk.
        Write-Warning "Remove-UtmTestVM: UTM still lists '$VMName' after the delete; leaving its bundle in place so the registration stays removable."
        return $false
    }
    Write-Verbose "Deleted UTM VM from registry: $VMName"
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
    Classify what `utmctl start` printed: an Apple Event transport failure, a
    QEMU failure, or nothing wrong. Returns 'apple-event', 'qemu' or 'none'.

.DESCRIPTION
    utmctl exits 0 for both failure classes, and the two need opposite
    responses. An Apple Event error (an OSStatus code, "Error from event")
    means UTM.app did not ACT on the request: the VM was never launched, it is
    exactly as it was, and the same call issued moments later routinely
    succeeds. A QEMU error means the VM DID launch and its process then died --
    a port it cannot bind, a missing disk -- which no amount of repeating will
    change.

    Reporting the first as the second sends the reader to the VM layer for a
    fault that never reached it, and tells them to rebuild a VM that is fine.
#>
function Get-UtmStartFailureKind {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'none' }
    # QEMU first: a message naming QEMU is about the VM process even if an
    # Apple Event phrase appears alongside it.
    if ($Text -match 'QEMU error|QEMU exited from an error') { return 'qemu' }
    if ($Text -match 'OSStatus error|Error from event|couldn.t be completed') { return 'apple-event' }
    return 'none'
}

<#
.SYNOPSIS
    Start a UTM VM and confirm it by POLLING STATE, retrying a few times.
    Returns @{ success; errorMessage; attempts; kind }.

.DESCRIPTION
    `utmctl start` is not a trustworthy report of its own outcome. It exits 0
    while UTM is still ingesting a bundle and drops the request; it exits 0 and
    prints an Apple Event error when UTM never acted on it; and it exits 0 for a
    VM whose QEMU then dies. The VM's state afterwards is the only answer that
    means anything, so every attempt here is judged by polling Get-VMState
    rather than by the verb's exit code or its output.

    Retrying is the point of this function. An Apple Event failure leaves the
    VM untouched, and the same start issued seconds later normally works -- so a
    single attempt turns a momentary refusal into an outage that lasts until an
    operator types the command by hand, taking every guest that consumes the
    service down with it for as long as that takes.

    A QEMU failure is deliberately NOT retried. The VM launched and its process
    died; repeating that only multiplies the delay before the caller finds out
    something is really wrong.

    The state pre-check at the top of each attempt keeps a slow starter from
    being handed a second start while the first is still coming up.

    The dialog watchdog is the caller's business, not this function's: some
    callers hold one open across a longer sequence, and Start-UtmDialogWatchdog
    stops any predecessor, so starting one here would kill theirs.

.PARAMETER MaxAttempts
    Start attempts before giving up. Attempts after the first are spaced by a
    pause that grows with the attempt number.

.PARAMETER SettleSeconds
    How long one attempt waits for the VM to reach 'running' before that
    attempt is judged to have failed.
#>
function Invoke-UtmVMStartWithRetry {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$MaxAttempts    = 3,
        [int]$SettleSeconds  = 20,
        [int]$BackoffSeconds = 5
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Start UTM VM (with retry)')) {
        return @{ success = $false; errorMessage = 'WhatIf'; attempts = 0; kind = 'none' }
    }
    $attemptCap = [Math]::Max(1, $MaxAttempts)
    $lastError  = ''
    $lastKind   = 'none'
    for ($attempt = 1; $attempt -le $attemptCap; $attempt++) {
        $state = 'unknown'
        try { $state = [string](Get-VMState -VMName $VMName) } catch { $state = 'unknown' }
        if ($state -eq 'running') {
            return @{ success = $true; errorMessage = $null; attempts = $attempt; kind = 'none' }
        }
        if ($attempt -gt 1) {
            $pause = $BackoffSeconds * ($attempt - 1)
            Write-Information -MessageData "  '$VMName' is still $state -- start attempt $attempt of $attemptCap in ${pause}s..." -InformationAction Continue
            Start-Sleep -Seconds $pause
        }

        $output = & utmctl start "$VMName" 2>&1
        $exit   = $LASTEXITCODE
        $text   = (@($output) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join '; '
        if ($text) { Write-Information -MessageData "  utmctl start: $text" -InformationAction Continue }
        $lastKind = Get-UtmStartFailureKind -Text $text
        $lastError = if ($exit -ne 0) { "utmctl start exited $exit$(if ($text) { ": $text" })" }
                     elseif ($lastKind -ne 'none') { $text }
                     else { '' }

        # Polled even when the verb reported an error: a start that printed an
        # Apple Event timeout can still have been carried out, and the state is
        # what settles it.
        $deadline = (Get-Date).AddSeconds([Math]::Max(1, $SettleSeconds))
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 1
            $now = 'unknown'
            try { $now = [string](Get-VMState -VMName $VMName) } catch { $now = 'unknown' }
            if ($now -eq 'running') {
                return @{ success = $true; errorMessage = $null; attempts = $attempt; kind = 'none' }
            }
        }
        if ($lastKind -eq 'qemu') {
            return @{ success = $false; attempts = $attempt; kind = 'qemu'
                      errorMessage = "QEMU did not survive for '$VMName': $lastError" }
        }
    }
    $detail = if ($lastKind -eq 'apple-event') {
        "UTM would not act on the start request for '$VMName' across $attemptCap attempt(s); the last reported '$lastError'. utmctl reached UTM.app -- state queries were answered throughout -- but the start itself was never carried out, so the VM was never launched and its disk is untouched. Retry it (utmctl start '$VMName'); rebuilding fixes nothing here."
    } elseif ($lastError) {
        "'$VMName' did not reach 'running' across $attemptCap attempt(s): $lastError"
    } else {
        "'$VMName' did not reach 'running' across $attemptCap attempt(s); utmctl reported no error, so UTM accepted each request and dropped it."
    }
    return @{ success = $false; errorMessage = $detail; attempts = $attemptCap; kind = $lastKind }
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
        # Distinguish the two ways the bundle can be missing. Still registered
        # means UTM holds a name whose files are gone -- the caller reached here
        # because that name answered the reuse check, so pointing at the path
        # alone would send the reader looking for a VM that was never created,
        # not for the registration that has to be cleared before one can be.
        if (Test-UtmVMRegistered -VMName $VMName) {
            return @{ success = $false; errorMessage = "UTM lists '$VMName' but its bundle is gone ($utmBundle). Clear the registration (Remove-VM -VMName '$VMName') so the VM can be created again." }
        }
        return @{ success = $false; errorMessage = "UTM bundle not found: $utmBundle" }
    }
    try {
        if ($PSCmdlet.ShouldProcess($VMName, 'Start UTM VM')) {
            $vmstatePath = Join-Path $utmBundle "Data/vmstate"
            if (Test-Path $vmstatePath) {
                Remove-Item -LiteralPath $vmstatePath -Force -ErrorAction SilentlyContinue
                # Progress on the information stream, never the success stream:
                # this function returns a status record, and anything written to
                # output becomes part of that return. A caller checking
                # `$result -is [hashtable]` then sees an Object[] and skips its
                # own failure check, so a VM that never started reports success.
                Write-Information -MessageData "  Removed stale vmstate for '$VMName' -- forcing cold boot." -InformationAction Continue
            }
            # Resolve the VNC display before starting. The display is baked into
            # the bundle when the VM is BUILT, and every guest of a kind is built
            # under the same test-VM name, so a topology that promotes several
            # VMs out of that namespace ends up with all of them pinned to one
            # port -- QEMU then refuses to start every VM after the first with
            # "Failed to find an available port: Address already in use". Prefer
            # the display derived from the VM's CURRENT name (distinct per VM),
            # and exclude what the other bundles already claim so a genuine hash
            # collision falls through to the next free slot.
            #
            # This write only reaches QEMU for a bundle UTM has not loaded yet.
            # UTM reads config.plist when it loads a VM and keeps that copy for
            # the life of the app, so for an already-registered VM the file and
            # the command line diverge silently. Rename-VM does the durable
            # allocation, in the window where it has UTM quit.
            $wantDisplay = Find-FreeVncDisplay `
                -Preferred (Get-VncDisplayForVm -VMName $VMName) `
                -ExcludeDisplays (Get-ClaimedVncDisplay -ExcludeVMName $VMName)
            if ($wantDisplay -lt 0) {
                return @{ success = $false; errorMessage = "No free VNC display in 10..89 for '$VMName'; every port 5910-5989 is in use." }
            }
            if ((Get-VncDisplayFromBundle -VMName $VMName) -ne $wantDisplay) {
                if (Set-VncDisplayInBundle -VMName $VMName -Display $wantDisplay -Confirm:$false) {
                    Write-Information -MessageData "  VNC display for '$VMName' set to $wantDisplay (port $(5900 + $wantDisplay))." -InformationAction Continue
                } else {
                    # Not fatal on its own: the bundle may still hold a usable
                    # display. Say so, because a screenshot aimed at the stale
                    # port would otherwise capture another VM's framebuffer.
                    Write-Warning "Start-UtmVM: could not set the VNC display for '$VMName'; the bundle keeps its previous port."
                }
            }
            Start-UtmDialogWatchdog
            & open "$utmBundle"
            Start-Sleep -Seconds 3
            # Adjudicated by state and retried, because utmctl exits 0 in three
            # different situations that are not success: a request UTM dropped
            # while still ingesting the bundle, a request UTM never acted on
            # (Apple Event error), and a VM whose QEMU died right after launch.
            # Reporting any of them as started buys a dead VM a full sequence of
            # downstream steps before anything notices, and the eventual symptom
            # -- an SSH timeout, a guest asserting on a peer that never came up
            # -- names neither this VM nor this reason.
            $start = Invoke-UtmVMStartWithRetry -VMName $VMName -Confirm:$false
            if (-not $start.success) {
                return @{ success = $false; errorMessage = $start.errorMessage }
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
    # Wall-clock deadline rather than an iter counter -- same rationale
    # as Confirm-HyperVVMStarted in host/windows.hyper-v. utmctl status
    # is cheap today but a future utmctl that retries internally would
    # silently expand the budget; deadline keeps the contract honest.
    $deadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadlineUtc) {
        $output = & utmctl status "$VMName" 2>&1
        if ($output -match "started|running") {
            Write-Output "Verified: UTM VM '$VMName' is running"
            return $true
        }
        Start-Sleep -Seconds 1
    }
    # Write-Warning (not Write-Error) for this expected-negative timeout so the [bool] contract
    # holds under a caller's ErrorActionPreference=Stop instead of throwing a terminating error.
    Write-Warning "UTM VM '$VMName' did not reach running state within ${TimeoutSeconds}s"
    return $false
}

<#
.SYNOPSIS
    Block until the VM's QEMU process is gone and every qcow2 disk is
    unlocked, so a following qemu-img snapshot create/apply is safe.
.DESCRIPTION
    `utmctl stop` (default --force) returns when the power-off *event* is
    sent, not when QEMUHelper has exited and released the qcow2. A
    qemu-img snapshot -c/-a that runs while the helper is still alive
    races its in-memory L1/L2 tables: the helper flushes its own
    (un-reverted) view on exit and silently clobbers the change, so the
    revert "succeeds" yet the guest resumes the pre-revert disk. This
    waits that window out -- polling `utmctl status` to drive a hard
    `--kill` escalation if the power-off stalls, and gating success on the
    write lock actually being free. `qemu-img info` WITHOUT -U fails while
    any process holds the lock, so a clean exit on every disk is the
    unambiguous "safe to mutate" signal (a bare status check is not: a
    'suspended'/'paused' guest still holds the lock).
.OUTPUTS
    [bool] $true once powered off and every disk is unlocked; $false on
    timeout.
#>
function Wait-UtmVMPoweredOff {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds = 30
    )
    $dataDir = "$HOME/yuruna/guest.nosync/$VMName.utm/Data"
    $deadlineUtc  = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $escalateUtc  = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds / 2)
    $killIssued   = $false
    while ([DateTime]::UtcNow -lt $deadlineUtc) {
        $status  = & utmctl status $VMName 2>&1
        $running = ($status -match 'started|paused|suspended')
        # Drive the kill escalation off status: the default power-off event
        # is near-instant, but a stalled (or suspended) guest never frees
        # the lock on its own. After half the budget, force-kill the
        # process so the qcow2 is released deterministically.
        if ($running -and -not $killIssued -and [DateTime]::UtcNow -ge $escalateUtc) {
            & utmctl stop $VMName --kill 2>&1 | Out-Null
            $killIssued = $true
        }
        # Gate on status FIRST: if UTM runs QEMU without an enforced write
        # lock, the qemu-img probe below would pass while the process is
        # still alive, so the lock check alone is not sufficient. Only once
        # status leaves the running set do we confirm the lock is actually
        # free (status can flip to 'stopped' a beat before QEMUHelper
        # releases the file handle -- qemu-img info WITHOUT -U fails while
        # the lock is held, so a clean exit on every disk is the all-clear).
        if (-not $running) {
            $allFree = $true
            foreach ($disk in @(Get-ChildItem -LiteralPath $dataDir -Filter '*.qcow2' -File -ErrorAction SilentlyContinue)) {
                & qemu-img info $disk.FullName 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { $allFree = $false; break }
            }
            if ($allFree) { return $true }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

<#
.SYNOPSIS
    Return the names of every UTM VM whose `utmctl list` Status is
    `started`. Empty array when none are running, when utmctl is missing,
    or when utmctl errors. Cheap (single `utmctl list` call).

.DESCRIPTION
    utmctl list columns are UUID, Status, Name (see
    [[utmctl-list-column-order]] memory note). We parse the UUID column
    as the row anchor so VM names containing spaces aren't truncated.
#>
function Get-RunningVmName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    # Returns the array via the canonical "scatter to pipeline" pattern --
    # PS will emit zero scalars for an empty array, N scalars for N items.
    # Callers MUST normalize with `@(Get-RunningVmName)` to get a proper
    # array regardless of count. Do NOT use `return ,@($arr)` here: the
    # comma wrapper inverts for empty arrays (caller's @() then receives
    # a 1-element array whose single element is the empty array itself,
    # surfacing as a phantom "running VM" with empty name).
    if (-not (Get-Command utmctl -ErrorAction SilentlyContinue)) { return }
    $output = & utmctl list 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) { return }
    $running = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($output -split "`r?`n")) {
        if ($line -match '^([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\s+(\S+)\s+(.+)$') {
            if ($matches[2] -eq 'started') {
                $name = $matches[3].Trim()
                if ($name) { [void]$running.Add($name) }
            }
        }
    }
    return $running.ToArray()
}

<#
.SYNOPSIS
    Return $true only when utmctl can actually talk to UTM.app right now.
.DESCRIPTION
    Under host memory pressure UTM.app stops answering Apple Events, and
    utmctl surfaces that as "The operation couldn't be completed. (OSStatus
    error -1712.)" (errAETimeout) -- sometimes with a zero exit code and an
    otherwise-empty listing. An exit-code check alone therefore can't tell
    "no VMs running" from "couldn't ask UTM.app", so a caller that reads an
    empty running-set as a verified-clean host would false-pass. Match the
    timeout signature explicitly so "couldn't verify" stays distinguishable
    from "confirmed clear".
.OUTPUTS
    [bool] $true when utmctl responded; $false when utmctl is missing,
    exited non-zero, or UTM.app timed out.
#>
function Test-UtmctlResponsive {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Get-Command utmctl -ErrorAction SilentlyContinue)) { return $false }
    $output = & utmctl list 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }
    if ($output -match 'OSStatus error|couldn.t be completed') { return $false }
    return $true
}

<#
.SYNOPSIS
    Refuse the cycle start when any UTM VM other than $ExceptVmName is
    currently `started`. Writes a multi-line actionable warning naming
    each offender + the exact `utmctl stop` command, then returns $false.
    Returns $true on success (no concurrent VMs).

.DESCRIPTION
    On some macOS versions UTM vmnet-shared assigns a separate host-side
    bridge per vmnet "session" (bridge100, bridge101, ...); guests on
    different bridges don't route to each other or to the host's vmnet
    gateway, so the cloud-init host-proxy URL baked into seed.iso (from the
    first bridge's host IP) becomes unreachable and the cycle fails at its
    first fetch-and-execute step with "Connection timed out". This helper
    is invoked at cycle start (Invoke-TestSequence.ps1 and Invoke-TestRunnerInnerLoop.ps1)
    to refuse the cycle before any test bundle is created, so the operator
    can stop the offender(s) and re-run.

    On macOS 26, every vmnet-shared VM observed instead shares ONE bridge
    (bridge100 / 192.168.64.1) and all guests route to each other directly
    -- so the split does not occur there. The guard stays for older hosts
    where it still can, but these names never trip the refusal:
      * the service VMs (Get-YurunaServiceVmName) -- infrastructure meant to run
        alongside cycles, and consumed BY them. Test guests take squid from the
        caching proxy and, on the shared bridge, reach it directly at its
        192.168.64.x IP; the build uploads to the stash service; the intent store
        is served by pool-control. A running service is a dependency, not an
        offender, and refusing over one blocks the cycle on something it needs.
      * $ExceptVmName -- the dev-loop case where Invoke-TestSequence is re-invoked
        against a VM the operator left running for inspection.

.PARAMETER ExceptVmName
    Optional. A single VM name to exclude from the running-VM list
    before the refuse check. Typically the cycle's target test VM.
#>
function Assert-NoConcurrentUtmVm {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$ExceptVmName)
    # Distinguish "confirmed no concurrent VM" from "couldn't check". If
    # UTM.app is unresponsive (host memory pressure -> Apple Event timeout,
    # OSStatus -1712), utmctl list returns empty and the running-set probe
    # below reads as "nothing running" -- a false all-clear that would let a
    # leftover VM slip past this guard. Surface that instead of silently
    # passing. We still proceed (returning $false here would wedge every cycle
    # on a host whose utmctl is intermittently unresponsive); the warning is
    # the signal, and the per-guest teardown probe is the other backstop.
    if (-not (Test-UtmctlResponsive)) {
        Write-Warning "Assert-NoConcurrentUtmVm: utmctl is not responding (UTM.app likely unresponsive under host memory pressure); cannot verify no other VM is running -- proceeding WITHOUT the single-VM guarantee for this cycle."
        return $true
    }
    # The service VMs are infrastructure designed to coexist with test cycles;
    # never let one count as a concurrent offender (see .DESCRIPTION). Shared with
    # Stop-ConcurrentVM's exemption list, because a name exempt from one guard and
    # not the other is worse than being absent from both: the first guard stops
    # the service, and the second still refuses the cycle over it.
    $alwaysAllow = @(Get-YurunaServiceVmName)
    $running = @(Get-RunningVmName | Where-Object { $alwaysAllow -notcontains $_ })
    if ($ExceptVmName) {
        $running = @($running | Where-Object { $_ -ne $ExceptVmName })
    }
    if ($running.Count -eq 0) { return $true }
    Write-Warning "==================================================================="
    Write-Warning " One or more UTM VMs are currently running:"
    foreach ($vm in $running) { Write-Warning "   - $vm" }
    Write-Warning ""
    Write-Warning " On some macOS versions vmnet-shared puts each new vmnet session on"
    Write-Warning " its own bridge (192.168.64.x, 192.168.65.x, ...) that don't route"
    Write-Warning " between each other. A concurrent VM can then split test guests onto"
    Write-Warning " a separate bridge from the host's vmnet gateway, breaking the"
    Write-Warning " cloud-init proxy URL baked into seed.iso. Stop the other VM(s)"
    Write-Warning " before re-running this cycle:"
    foreach ($vm in $running) { Write-Warning "   utmctl stop '$vm'" }
    Write-Warning ""
    Write-Warning " (The service VMs -- $($alwaysAllow -join ', ') -- are always allowed to coexist.)"
    if ($ExceptVmName) {
        Write-Warning " (Also excluding the cycle's target VM '$ExceptVmName'.)"
    }
    Write-Warning "==================================================================="
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

# --- REGION: Host proxy helpers
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
    # Ask the machine before asking a person: an already-warm credential needs
    # neither the notice nor the prompt, and `sudo -n -v` refreshes it silently.
    & sudo -n -v 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return }
    # sudo reads its password from /dev/tty, which neither a closed stdin nor
    # -NonInteractive can redirect. The proxy teardown paths call this
    # unconditionally and run inside children whose console belongs to a parent,
    # so a bare `sudo -v` there raises a prompt nothing displays and nothing
    # answers, and the step waits forever. Fail with the remedy instead.
    if (-not (Test-YurunaCanPrompt)) {
        throw ("networksetup needs root and this run cannot ask for a password. Run 'sudo -v' in the terminal that owns this run " +
               "before starting it, or grant this account a passwordless rule for /usr/sbin/networksetup in /etc/sudoers.d.")
    }
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
        if ($LASTEXITCODE -ne 0) { Write-Warning "networksetup $($Arguments -join ' ') exited $LASTEXITCODE." }
        return
    }
    # -n, because Invoke-MacElevationIfNeeded has already established that root
    # is reachable and every caller runs a short sequence of these. If the
    # timestamp expires mid-sequence the honest outcome is an exit code: a
    # password prompt here lands on a console the caller may not own, and the
    # operator was told they would be asked once.
    & sudo -n networksetup @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "sudo networksetup $($Arguments -join ' ') exited $LASTEXITCODE." }
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
    # --- REGION: https://yuruna.link/memory#why-remove-machostproxy-sets-state-off-as-the-last-step
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

# --- REGION: Screenshot helpers
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
    Return the VNC display recorded in the VM bundle's config.plist, or -1
    when the bundle has no -vnc argument (or cannot be read).
.DESCRIPTION
    The bundle is the authority on which port a VM actually listens on:
    the display is written into QEMU's AdditionalArguments when the VM is
    built, and Start-UtmVM may rewrite it to avoid a collision. A caller
    that derived the port from the VM name instead would aim a screenshot
    at whatever else happens to hold that port.
#>
function Get-VncDisplayFromBundle {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$VMName)
    $configPath = "$HOME/yuruna/guest.nosync/$VMName.utm/config.plist"
    if (-not (Test-Path -LiteralPath $configPath)) { return -1 }
    try {
        $json = & plutil -convert json -o - $configPath 2>$null | ConvertFrom-Json
        $qemuArgs = @($json.QEMU.AdditionalArguments)
        for ($i = 0; $i -lt $qemuArgs.Count - 1; $i++) {
            if ("$($qemuArgs[$i])" -ne '-vnc') { continue }
            # Value shape: 127.0.0.1:<display>[,share=force-shared]
            if ("$($qemuArgs[$i + 1])" -match ':(\d+)') { return [int]$Matches[1] }
        }
    } catch {
        Write-Debug "Get-VncDisplayFromBundle: could not read $configPath`: $($_.Exception.Message)"
    }
    return -1
}

<#
.SYNOPSIS
    Return a VM bundle's network descriptor -- plist path, network mode and
    MAC -- or $null when the host has no such bundle.
.DESCRIPTION
    The bundle is the authority on how a VM is attached and what MAC it
    boots with: both are fixed when it is BUILT, and the guest's seed
    carries addresses derived for them, so what the bundle says -- not what
    this host's uplink would choose today -- is what the running VM is
    actually on. Address discovery reads both together because it needs
    both to pick a rung, and one plutil invocation answers for the pair.
.OUTPUTS
    [pscustomobject] with VMName, PlistPath, Mode ('Bridged' / 'Shared' /
    '' when unreadable) and MacAddress ('' when absent), or $null.
#>
function Get-UtmBundleNetwork {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$VMName)
    $configPath = "$HOME/yuruna/guest.nosync/$VMName.utm/config.plist"
    if (-not (Test-Path -LiteralPath $configPath)) { return $null }
    $mode = ''
    $mac  = ''
    try {
        $json = & plutil -convert json -o - $configPath 2>$null | ConvertFrom-Json
        $nic  = @($json.Network)[0]
        $mode = "$($nic.Mode)".Trim()
        $mac  = "$($nic.MacAddress)".Trim()
    } catch {
        Write-Debug "Get-UtmBundleNetwork: could not read $configPath`: $($_.Exception.Message)"
    }
    return [pscustomobject]@{
        VMName     = $VMName
        PlistPath  = $configPath
        Mode       = $mode
        MacAddress = $mac
    }
}

<#
.SYNOPSIS
    Return the network mode recorded in a VM bundle's config.plist
    ('Bridged' / 'Shared'), or '' when the bundle or the key is absent.
.DESCRIPTION
    A caller compares this against what the host's uplink would choose today
    to detect a host that has moved between Wi-Fi and Ethernet since the VM
    was created, and decides whether to forward host ports (Shared) or
    expect a LAN address (Bridged).
#>
function Get-UtmNetworkModeFromBundle {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $bundleNetwork = Get-UtmBundleNetwork -VMName $VMName
    if (-not $bundleNetwork) { return '' }
    return [string]$bundleNetwork.Mode
}

<#
.SYNOPSIS
    Write $Display into the VM bundle's -vnc QEMU argument. Returns $true
    when the bundle now carries that display.
#>
function Set-VncDisplayInBundle {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][int]$Display
    )
    $configPath = "$HOME/yuruna/guest.nosync/$VMName.utm/config.plist"
    if (-not (Test-Path -LiteralPath $configPath)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($VMName, "Set VNC display to $Display")) { return $false }
    try {
        $json = & plutil -convert json -o - $configPath 2>$null | ConvertFrom-Json
        $qemuArgs = @($json.QEMU.AdditionalArguments)
        for ($i = 0; $i -lt $qemuArgs.Count - 1; $i++) {
            if ("$($qemuArgs[$i])" -ne '-vnc') { continue }
            # Preserve whatever suffix the builder attached (share=force-shared
            # lets the screenshot client attach while the console is open);
            # only the display number changes.
            $suffix = ''
            if ("$($qemuArgs[$i + 1])" -match ':\d+(,.*)$') { $suffix = $Matches[1] }
            $value = "127.0.0.1:${Display}${suffix}"
            & /usr/libexec/PlistBuddy -c "Set :QEMU:AdditionalArguments:$($i + 1) $value" $configPath 2>&1 | Out-Null
            return ((Get-VncDisplayFromBundle -VMName $VMName) -eq $Display)
        }
    } catch {
        Write-Warning "Set-VncDisplayInBundle: could not update $configPath`: $($_.Exception.Message)"
    }
    return $false
}

<#
.SYNOPSIS
    $true when nothing is listening on 127.0.0.1:$Port right now.
.DESCRIPTION
    A real bind, not a connect probe: QEMU fails to start when it cannot
    bind, and only a bind tells us whether it will be able to.
#>
function Test-VncPortFree {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][int]$Port)
    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { try { $listener.Stop() } catch { Write-Debug "Test-VncPortFree: listener stop on $Port`: $($_.Exception.Message)" } }
    }
}

<#
.SYNOPSIS
    Return a VNC display in 10..89 whose port is free, preferring $Preferred.
    Returns -1 when every display in the range is taken.
#>
function Find-FreeVncDisplay {
    [CmdletBinding()]
    [OutputType([int])]
    param([int]$Preferred = -1, [int[]]$ExcludeDisplays = @())
    # A bind test only sees VMs that are running RIGHT NOW. When the caller
    # is allocating for a fleet whose members are stopped -- or with UTM
    # quit entirely -- every port answers "free" and two VMs happily take
    # the same one. ExcludeDisplays carries the displays already spoken for
    # by other bundles so the choice holds once they all start.
    $excluded = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($d in $ExcludeDisplays) { $null = $excluded.Add([int]$d) }
    if ($Preferred -ge 10 -and $Preferred -le 89 -and
        -not $excluded.Contains($Preferred) -and (Test-VncPortFree -Port (5900 + $Preferred))) {
        return $Preferred
    }
    for ($d = 10; $d -le 89; $d++) {
        if (-not $excluded.Contains($d) -and (Test-VncPortFree -Port (5900 + $d))) { return $d }
    }
    return -1
}

<#
.SYNOPSIS
    Return the VNC displays recorded in every .utm bundle except $ExcludeVMName.
.DESCRIPTION
    The bundles on disk are the only durable record of which display each
    VM will ask QEMU for, so they are what a new allocation has to avoid.
#>
function Get-ClaimedVncDisplay {
    [CmdletBinding()]
    [OutputType([int[]])]
    param([string]$ExcludeVMName)
    $guestDir = "$HOME/yuruna/guest.nosync"
    if (-not (Test-Path -LiteralPath $guestDir)) { return [int[]]@() }
    $displays = @()
    foreach ($bundle in (Get-ChildItem -LiteralPath $guestDir -Filter '*.utm' -Directory -ErrorAction SilentlyContinue)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($bundle.Name)
        if ($name -eq $ExcludeVMName) { continue }
        $display = Get-VncDisplayFromBundle -VMName $name
        if ($display -ge 0) { $displays += $display }
    }
    return [int[]]$displays
}

<#
.SYNOPSIS
    Return the VNC TCP port (5910..5989) for the given VM.
.DESCRIPTION
    The bundle's own -vnc argument wins: Start-UtmVM resolves the display
    at start time, so the name-derived value is only the seed, not the
    answer. Falling back to the hash keeps callers working for a VM that
    has no bundle on this host (or none yet).
#>
function Get-VncPortForVm {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$VMName)
    $fromBundle = Get-VncDisplayFromBundle -VMName $VMName
    if ($fromBundle -ge 0) { return 5900 + $fromBundle }
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
    instead of being driven from PowerShell -- measured against a 1920x1080
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
                # dispatch overhead -- the bytes arrive in <50 ms, the
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

# --- REGION: VM lifecycle

<#
.SYNOPSIS
    Create a guest VM by running the per-guest New-VM.ps1 script.
#>
function New-VM {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is delegated to Invoke-PerGuestNewVm, which declares SupportsShouldProcess and calls it; -WhatIf/-Confirm propagate via the splatted PSBoundParameters.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$VMName,
        [string]$CachingProxyServiceUrl,
        # Planner-cascaded username override; forwarded only when the
        # per-guest script declares -Username (introspected below).
        [string]$Username,
        # Planner-cascaded guest hostname (variables.hostname); same
        # declare-or-drop forwarding rule as -Username.
        [string]$Hostname,
        # Planner-cascaded VM sizing (variables.memoryStartupBytes /
        # variables.cores); same declare-or-drop forwarding rule as -Username.
        [string]$MemoryStartupBytes,
        [string]$Cores
    )
    # Thin wrapper over the shared per-guest runner; the host subdir is the
    # only platform variable. Splatting $PSBoundParameters preserves the
    # conditional -CachingProxyServiceUrl/-Username/-Hostname/-MemoryStartupBytes/-Cores
    # forwarding (the runner checks ContainsKey) and propagates -WhatIf/-Confirm.
    Invoke-PerGuestNewVm -HostSubdir 'host/macos.utm' @PSBoundParameters
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
    Force-stop a UTM VM via `utmctl stop --kill` (hard-kills the VM process; timeout parameter exists for parity with other hosts).
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
    # --kill hard-kills the VM process instead of the default power-off
    # event, so the qcow2 write lock is released without waiting on an
    # ACPI shutdown that a busy or mid-reboot guest may ignore.
    & utmctl stop $VMName --kill 2>&1 | Out-Null
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
    Return the names of every VM registered with UTM, optionally filtered
    to those starting with one of $Prefix.
.DESCRIPTION
    Host-neutral inventory call (see the contract's VM inventory block).
    Every VM UTM knows about is returned regardless of run state, so a
    caller sweeping by prefix removes stopped leftovers as well as
    running ones.

    THROWS when utmctl cannot reach UTM.app rather than returning an
    empty list. utmctl exits 0 and prints its error to stderr when Apple
    Events are denied (OSStatus -1743, typical from an SSH session or a
    process without Automation access), when a request times out (-1712),
    and for other Apple Event faults besides -- so an exit-code check alone
    reads "cannot ask" as "nothing registered". A sweep that accepted that
    empty list would report a clean host, and the orphan-file pass behind
    it would delete bundles UTM still has registered.

    Matched on ANY OSStatus code rather than an enumerated few. The set that
    can appear here is open, the consequence of missing one is deleting a
    VM's disk, and there is no OSStatus value whose correct reading is
    "believe the empty list".
.PARAMETER Prefix
    Zero or more name prefixes. A VM is returned when its name starts
    with any of them. Omit (or pass none) to return every VM.
.OUTPUTS
    [string[]] matching VM names; empty when none match.
#>
function Get-VMName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string[]]$Prefix)
    if (-not (Get-Command utmctl -ErrorAction SilentlyContinue)) {
        throw "Get-VMName: utmctl not found on PATH; cannot enumerate UTM VMs."
    }
    $output = & utmctl list 2>&1
    $text = ($output | ForEach-Object { "$_" }) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $text -match 'OSStatus error|couldn.t be completed|utmctl does not work from SSH') {
        throw "Get-VMName: utmctl could not reach UTM. Run from a Terminal session with Automation access for pwsh, after UTM.app is launched and a user is logged in graphically. Output:`n$text"
    }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($text -split "`r?`n")) {
        $line = $line.Trim()
        if (-not $line -or $line -match '^-+$') { continue }
        # utmctl list is FIXED-COLUMN, not 2+-space delimited: the UUID
        # column is 36 chars plus a single pad space, so splitting on
        # \s{2,} merges UUID and Status into one 44-char field that never
        # matches a UUID and silently yields zero rows. Anchor on the UUID
        # and take the remainder as the name so names containing spaces
        # survive intact.
        if ($line -match '^([0-9A-Fa-f-]{36})\s+(\S+)\s+(\S.*)$') {
            $name = $matches[3].Trim()
            if ($name) { [void]$names.Add($name) }
        }
    }
    return Select-NameByPrefix -Name $names.ToArray() -Prefix $Prefix
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
    Bring the named service VMs back to `started` after UTM.app has been
    quit and relaunched. Returns the names that did NOT come back.

.DESCRIPTION
    UTM saves the state of every running VM on its way out, so a VM that
    was `started` before UTM was quit is `suspended` when UTM returns --
    and it stays that way, because nothing resumes it automatically. For
    the service VMs that is not a cosmetic difference: guests take their
    packages through the caching proxy, the build uploads to the stash
    service, and the intent store is served by pool-control, so every one
    of those consumers fails for as long as the service sits suspended.

    `utmctl start` is also the resume verb -- on a suspended VM it
    restores the saved state instead of cold-booting -- so a caller can
    restore the pre-quit set without having to know whether UTM chose to
    suspend or to fully stop each one.

    Best-effort by design. A caller reaches this only after its own work
    is done, and a service that refuses to come back is something for the
    operator to see, not a reason to report that work as failed.

.PARAMETER VMName
    Names captured (while UTM was still up) as `started`. Empty is fine.

.PARAMETER TimeoutSeconds
    Per-VM budget for re-registration and, separately, for the resume to
    reach `started`.

.OUTPUTS
    [string[]] the names that did not return to `started`; empty on full
    success. Callers must normalize with `@(...)`.
#>
function Resume-YurunaServiceVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]])]
    param(
        [string[]]$VMName,
        [int]$TimeoutSeconds = 90
    )
    $names = @($VMName | Where-Object { $_ })
    if ($names.Count -eq 0) { return }
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($name in $names) {
        if (-not $PSCmdlet.ShouldProcess($name, 'Resume service VM after UTM relaunch')) { continue }
        # UTM ingests its library asynchronously after launch, and utmctl
        # cannot address a VM until that finishes -- an immediate start
        # would be answered with "not found" and silently dropped.
        $registerDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $state = 'absent'
        while ((Get-Date) -lt $registerDeadline) {
            $state = Get-VMState -VMName $name
            if ($state -ne 'absent') { break }
            Start-Sleep -Milliseconds 500
        }
        if ($state -eq 'absent') {
            Write-Warning "Resume-YurunaServiceVM: '$name' did not re-register with UTM within $TimeoutSeconds s; resume it by hand (utmctl start '$name')."
            [void]$failed.Add($name)
            continue
        }
        if ($state -eq 'running') { continue }
        # The watchdog is started HERE rather than left to the caller. The path
        # that leads to a resume quits UTM, and the Stop-VM on the way in reaps
        # any watchdog with it -- so this is the one place a service VM is
        # launched with nothing to dismiss the launch-time custom-QEMU-args
        # confirmation that both service VMs carry, and a start waiting on a
        # modal nobody answers looks exactly like a start that was refused.
        Start-UtmDialogWatchdog
        try {
            # The retry budget is spread ACROSS TimeoutSeconds rather than added
            # on top of it, so a caller's timeout still means what it says while
            # a momentary refusal now gets the second and third try that a
            # single-shot start never had.
            $start = Invoke-UtmVMStartWithRetry -VMName $name -Confirm:$false `
                -SettleSeconds ([Math]::Max(15, [int]($TimeoutSeconds / 3)))
        } finally {
            Stop-UtmDialogWatchdog
        }
        if ($start.success) {
            Write-Verbose "Resume-YurunaServiceVM: '$name' is running again (attempt $($start.attempts))."
        } else {
            Write-Warning "Resume-YurunaServiceVM: '$name' did not return to 'started'. $($start.errorMessage) Every guest that consumes it will fail until it is running."
            [void]$failed.Add($name)
        }
    }
    return $failed.ToArray()
}

<#
.SYNOPSIS
    Rename a stopped UTM VM by editing its .utm bundle and UTM's Registry
    plist while UTM.app is quit.
.DESCRIPTION
    UTM exposes no rename verb in utmctl, and macOS 26 builds mark the
    AppleScript `name` property of `virtual machine` as read-only
    (osascript fails with -10006). The reliable workaround is on-disk
    surgery while UTM is offline:

      1. Quit UTM.app (and any QEMUHelper child) so cfprefsd flushes the
         in-memory Registry to its plist on disk, then flush cfprefsd's
         cache so our subsequent edits aren't clobbered.
      2. Rename `<guest.nosync>/<VMName>.utm` -> `<guest.nosync>/<NewName>.utm`.
         The qcow2 disks (including snapshots written by Save-VMDiskSnapshot)
         move with the bundle.
      3. PlistBuddy: set `:Information:Name` in the new bundle's
         config.plist to NewName.
      4. PlistBuddy: set `:Registry:<UUID>:Name` and
         `:Registry:<UUID>:Package:Path` inside
         `~/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/com.utmapp.UTM.plist`.
      5. killall cfprefsd so UTM re-reads our edited plist on relaunch.
      6. `open -a UTM` and poll utmctl until the new name surfaces.
      7. Resume the service VMs that step 1 took down (see below).

    Step 1 is not free for the rest of the host. UTM saves the state of
    every VM still running as it terminates, so any service VM that was up
    -- the caching proxy, the stash service, pool-control -- returns as
    `suspended` and stays there. Guests consume those services for the
    whole cycle, so the running set is captured before the quit and
    resumed after the relaunch, on every path out of this function.

    The Package.Bookmark blob is left untouched: macOS file bookmarks
    resolve via catalog inode + volume UUID, so a directory rename within
    the same volume continues to resolve to the new path.

    Requires the VM to be stopped (UTM holds an exclusive lock on the
    bundle while running). Caller (Save-VMDiskSnapshot) handles the stop.
#>
function Rename-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$NewName
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, "Rename to '$NewName' (bundle + Registry surgery)")) { return $false }
    if ($VMName -eq $NewName) { return $true }
    if ($VMName -match '[/"\\]' -or $NewName -match '[/"\\]') {
        Write-Warning "Rename-VM: refusing to rename '$VMName' -> '$NewName' (names must not contain '/', '\\', or '`"')."
        return $false
    }
    if ((Get-VMState -VMName $VMName) -eq 'absent') {
        Write-Warning "Rename-VM: source VM '$VMName' not registered with UTM."
        return $false
    }
    if ((Get-VMState -VMName $NewName) -ne 'absent') {
        Write-Warning "Rename-VM: destination name '$NewName' already exists."
        return $false
    }
    if ((Get-VMState -VMName $VMName) -eq 'running') {
        Write-Warning "Rename-VM: '$VMName' is still running; UTM holds an exclusive lock on the bundle. Stop the VM first."
        return $false
    }

    $guestDir  = "$HOME/yuruna/guest.nosync"
    $srcBundle = Join-Path $guestDir "$VMName.utm"
    $dstBundle = Join-Path $guestDir "$NewName.utm"
    $srcConfig = Join-Path $srcBundle 'config.plist'
    if (-not (Test-Path -LiteralPath $srcConfig)) {
        Write-Warning "Rename-VM: source config.plist not found at '$srcConfig'."
        return $false
    }
    if (Test-Path -LiteralPath $dstBundle) {
        Write-Warning "Rename-VM: destination bundle already exists: '$dstBundle'."
        return $false
    }

    # UUID is the only stable key in UTM's Registry; read it from the
    # bundle's own config.plist rather than parsing `defaults` output.
    $uuid = (& /usr/libexec/PlistBuddy -c 'Print :Information:UUID' $srcConfig 2>&1).ToString().Trim()
    if ($LASTEXITCODE -ne 0 -or $uuid -notmatch '^[0-9A-Fa-f-]{36}$') {
        Write-Warning "Rename-VM: could not read :Information:UUID from '$srcConfig' (got '$uuid')."
        return $false
    }

    $utmPrefs = "$HOME/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/com.utmapp.UTM.plist"
    if (-not (Test-Path -LiteralPath $utmPrefs)) {
        Write-Warning "Rename-VM: UTM preferences plist not found at '$utmPrefs'."
        return $false
    }

    # Quitting UTM is collateral damage for every OTHER VM that happens to
    # be running: UTM saves their state on the way out and they come back
    # suspended, not started. The service VMs are the ones that matter --
    # a cycle consumes them from beginning to end -- so record which are up
    # now, while UTM can still be asked, and resume them on every path out
    # of here.
    $serviceVmToResume = @(@(Get-RunningVmName) | Where-Object { (Get-YurunaServiceVmName) -contains $_ })

    # Quit UTM so cfprefsd flushes the Registry to disk before our edits.
    & osascript -e 'tell application "UTM" to quit' 2>&1 | Out-Null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $procs   = & pgrep -i -x UTM 2>$null
        $helpers = & pgrep -f QEMUHelper 2>$null
        if (-not $procs -and -not $helpers) { break }
        Start-Sleep -Milliseconds 500
    }
    & pkill -f QEMUHelper 2>$null | Out-Null
    & pkill -i -x UTM     2>$null | Out-Null
    Start-Sleep -Seconds 1
    # Drop cfprefsd cache so PlistBuddy reads/writes go straight to the
    # plist file rather than being shadowed by stale daemon state.
    & killall cfprefsd 2>$null | Out-Null
    Start-Sleep -Milliseconds 500

    try {
        Rename-Item -LiteralPath $srcBundle -NewName "$NewName.utm" -ErrorAction Stop
    } catch {
        Write-Warning "Rename-VM: bundle rename '$srcBundle' -> '$dstBundle' failed: $($_.Exception.Message)."
        & open -a UTM 2>$null | Out-Null
        [void](Resume-YurunaServiceVM -VMName $serviceVmToResume -Confirm:$false)
        return $false
    }

    $dstConfig = Join-Path $dstBundle 'config.plist'
    & /usr/libexec/PlistBuddy -c "Set :Information:Name $NewName" $dstConfig 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Rename-VM: PlistBuddy could not update :Information:Name in '$dstConfig'."
        try { Rename-Item -LiteralPath $dstBundle -NewName "$VMName.utm" -ErrorAction Stop }
        catch { Write-Debug "Rename-VM revert: bundle rename back failed: $_" }
        & open -a UTM 2>$null | Out-Null
        [void](Resume-YurunaServiceVM -VMName $serviceVmToResume -Confirm:$false)
        return $false
    }

    & /usr/libexec/PlistBuddy -c "Set :Registry:${uuid}:Name $NewName"            $utmPrefs 2>&1 | Out-Null
    $regExitName = $LASTEXITCODE
    & /usr/libexec/PlistBuddy -c "Set :Registry:${uuid}:Package:Path $dstBundle" $utmPrefs 2>&1 | Out-Null
    $regExitPath = $LASTEXITCODE
    if ($regExitName -ne 0 -or $regExitPath -ne 0) {
        Write-Warning "Rename-VM: PlistBuddy could not update UTM Registry for UUID $uuid (Name exit=$regExitName, Path exit=$regExitPath)."
        # Best-effort revert: undo plist Name + bundle rename so the
        # next cycle sees a coherent state.
        & /usr/libexec/PlistBuddy -c "Set :Information:Name $VMName" $dstConfig 2>$null | Out-Null
        try { Rename-Item -LiteralPath $dstBundle -NewName "$VMName.utm" -ErrorAction Stop }
        catch { Write-Debug "Rename-VM revert: bundle rename back failed: $_" }
        & killall cfprefsd 2>$null | Out-Null
        & open -a UTM 2>$null | Out-Null
        [void](Resume-YurunaServiceVM -VMName $serviceVmToResume -Confirm:$false)
        return $false
    }

    # Re-derive the VNC display for the NEW name, here, while UTM is down.
    # UTM reads a bundle's -vnc argument only when it loads the VM, and
    # loads it once per app launch: a rewrite performed while UTM already
    # holds the VM changes the file without changing the QEMU command
    # line, so the guest still starts on the display it was loaded with.
    # This relaunch is the one moment the file is authoritative again.
    # It matters because bundles are built under a single per-kind test
    # name -- every VM promoted out of that namespace inherits the same
    # display, and only the first of them can bind the port.
    $wantDisplay = Find-FreeVncDisplay `
        -Preferred (Get-VncDisplayForVm -VMName $NewName) `
        -ExcludeDisplays (Get-ClaimedVncDisplay -ExcludeVMName $NewName)
    if ($wantDisplay -lt 0) {
        Write-Warning "Rename-VM: no free VNC display in 10..89 for '$NewName'; it keeps display $(Get-VncDisplayFromBundle -VMName $NewName) and may collide with another VM."
    } elseif ((Get-VncDisplayFromBundle -VMName $NewName) -ne $wantDisplay) {
        if (Set-VncDisplayInBundle -VMName $NewName -Display $wantDisplay -Confirm:$false) {
            Write-Verbose "Rename-VM: VNC display for '$NewName' set to $wantDisplay (port $(5900 + $wantDisplay))."
        } else {
            Write-Warning "Rename-VM: could not set the VNC display for '$NewName'; it keeps display $(Get-VncDisplayFromBundle -VMName $NewName) and may collide with another VM."
        }
    }

    # Force cfprefsd to reload from our edited file on next access.
    & killall cfprefsd 2>$null | Out-Null
    Start-Sleep -Milliseconds 500
    & open -a UTM 2>$null | Out-Null

    $deadline = (Get-Date).AddSeconds(30)
    $surfaced = $false
    while ((Get-Date) -lt $deadline) {
        if ((Get-VMState -VMName $NewName) -ne 'absent') { $surfaced = $true; break }
        Start-Sleep -Milliseconds 500
    }
    # Resume regardless of whether the rename surfaced: the services were
    # taken down by the quit above either way, and leaving them suspended
    # to report a rename failure would trade one broken thing for several.
    #
    # The failed list is NOT discarded. This function's caller judges the
    # rename, and a rename can succeed while the services it took down stay
    # down -- which reads as a passing step that quietly hands every later
    # step, and the next cycle, a host with no cache and no stash. The rename
    # verdict is still the return value; this makes the collateral damage say
    # so at the point it happened, instead of surfacing minutes later as an
    # unrelated-looking failure somewhere downstream.
    $resumeFailed = @(Resume-YurunaServiceVM -VMName $serviceVmToResume -Confirm:$false)
    if ($resumeFailed.Count -gt 0) {
        Write-Warning "Rename-VM: '$NewName' was renamed, but $($resumeFailed.Count) service VM(s) that this rename stopped did not come back: $($resumeFailed -join ', '). Every later step that consumes them will fail. Start them before continuing: $(($resumeFailed | ForEach-Object { "utmctl start '$_'" }) -join '; ')."
    }
    if ($surfaced) { return $true }
    Write-Warning "Rename-VM: UTM relaunch did not surface '$NewName' within timeout."
    return $false
}

<#
.SYNOPSIS
    Save a disk-only snapshot of each qcow2 disk in the UTM bundle,
    then attempt to rename the VM (best-effort) so it persists across
    test-cycle cleanup.
.DESCRIPTION
    UTM owns its QEMU process and does not expose a stable QMP/CLI
    snapshot verb, so this contract drops to qemu-img with the VM
    offline. The .utm bundle lives at $HOME/yuruna/guest.nosync/<vm>.utm
    and disks are *.qcow2 under <bundle>/Data/. For multi-disk VMs the
    same Id is written into every qcow2 -- Restore-VMDiskSnapshot
    reverts the same set as a group so the disks stay coherent.

    After a successful snapshot, Rename-VM renames the VM to $Id by
    on-disk surgery (bundle dir + config.plist + UTM Registry) so the
    snapshot survives the next cycle's Remove-TestVMFiles sweep. If the
    rename fails, the qcow2 snapshot is still on disk and can be
    restored manually from the original bundle path.
#>
function Save-VMDiskSnapshot {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, "Save disk snapshot '$Id' and rename to '$Id'")) { return $false }
    $utmBundle = "$HOME/yuruna/guest.nosync/$VMName.utm"
    $dataDir   = Join-Path $utmBundle 'Data'
    if (-not (Test-Path -LiteralPath $dataDir)) {
        Write-Warning "Save-VMDiskSnapshot: UTM bundle data dir not found: $dataDir"
        return $false
    }
    $disks = @(Get-ChildItem -LiteralPath $dataDir -Filter '*.qcow2' -File -ErrorAction SilentlyContinue)
    if ($disks.Count -eq 0) {
        Write-Warning "Save-VMDiskSnapshot: no *.qcow2 disks under $dataDir."
        return $false
    }
    if (-not (Get-Command qemu-img -ErrorAction SilentlyContinue)) {
        Write-Warning "Save-VMDiskSnapshot: qemu-img not on PATH (brew install qemu)."
        return $false
    }
    if ((Get-VMState -VMName $VMName) -eq 'running') {
        if (-not (Stop-VM -VMName $VMName)) {
            [void](Stop-VMForce -VMName $VMName)
        }
    }
    # A snapshot created while the QEMU helper still holds the qcow2 open
    # races its in-memory metadata: qemu-img -c either fails to lock
    # ("Failed to lock byte 100") or captures an inconsistent disk. Block
    # until the process is gone and the write lock is free before -c.
    if (-not (Wait-UtmVMPoweredOff -VMName $VMName)) {
        Write-Warning "Save-VMDiskSnapshot: '$VMName' did not fully power off (qcow2 still locked); aborting to avoid an inconsistent snapshot."
        return $false
    }
    foreach ($disk in $disks) {
        # Idempotent overwrite: drop a prior snapshot with the same id
        # if present, then create.
        & qemu-img snapshot -d $Id $disk.FullName 2>&1 | Out-Null
        & qemu-img snapshot -c $Id $disk.FullName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Save-VMDiskSnapshot: qemu-img snapshot -c failed for $($disk.Name) (exit $LASTEXITCODE)."
            return $false
        }
    }
    if ($VMName -ne $Id) {
        if (-not (Rename-VM -VMName $VMName -NewName $Id -Confirm:$false)) {
            Write-Warning "Save-VMDiskSnapshot: snapshot '$Id' saved into '$utmBundle' but rename '$VMName' -> '$Id' failed; VM will be wiped on next cycle cleanup. The qcow2 snapshot is on disk and can be restored manually."
            return $false
        }
    }
    return $true
}

<#
.SYNOPSIS
    Returns $true when snapshot $Id is present on every qcow2 disk of
    the UTM bundle for $VMName. False on missing bundle, missing
    qemu-img, or any disk lacking the snapshot. Used by Invoke-TestSequence's
    requiresSnapshot warm-path probe before deciding whether to walk
    the baseline chain.
#>
function Test-VMDiskSnapshot {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    $utmBundle = "$HOME/yuruna/guest.nosync/$VMName.utm"
    $dataDir   = Join-Path $utmBundle 'Data'
    if (-not (Test-Path -LiteralPath $dataDir)) { return $false }
    $disks = @(Get-ChildItem -LiteralPath $dataDir -Filter '*.qcow2' -File -ErrorAction SilentlyContinue)
    if ($disks.Count -eq 0) { return $false }
    if (-not (Get-Command qemu-img -ErrorAction SilentlyContinue)) { return $false }
    foreach ($disk in $disks) {
        # -U (--force-share) so a running QEMU's exclusive lock on the
        # qcow2 doesn't fail this metadata-only read with "Failed to get
        # shared write lock". Test-VMDiskSnapshot is a pure read; it
        # never mutates the disk, so force-share is safe.
        $info = & qemu-img snapshot -l -U $disk.FullName 2>&1
        # `$array -notmatch <rx>` returns the filtered array of NON-matching
        # lines, not a Boolean -- with qemu-img's two header lines that's a
        # non-empty (truthy) array even when the data row matches, so the
        # naive `if (-notmatch)` form always reports "not present" on UTM.
        # Use Where-Object + .Count for an unambiguous count of hits.
        $hits = @($info | Where-Object { $_ -match ("^\s*\d+\s+" + [regex]::Escape($Id) + "\s") })
        if ($hits.Count -eq 0) {
            return $false
        }
    }
    return $true
}

function Restore-VMDiskSnapshot {
    <#
    .SYNOPSIS
        Restore every *.qcow2 disk under the UTM VM bundle to snapshot $Id.
    .DESCRIPTION
        Verifies the snapshot exists on every disk first so a typo'd Id
        does not bounce a healthy guest, stops the VM if it is running,
        then applies `qemu-img snapshot -a $Id` per disk. Multi-disk VMs
        must have the snapshot on all disks to stay coherent.
    .OUTPUTS
        [bool] $true on success; $false on any precondition or apply failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, "Restore disk snapshot '$Id'")) { return $false }
    $utmBundle = "$HOME/yuruna/guest.nosync/$VMName.utm"
    $dataDir   = Join-Path $utmBundle 'Data'
    if (-not (Test-Path -LiteralPath $dataDir)) {
        Write-Warning "Restore-VMDiskSnapshot: UTM bundle data dir not found: $dataDir"
        return $false
    }
    $disks = @(Get-ChildItem -LiteralPath $dataDir -Filter '*.qcow2' -File -ErrorAction SilentlyContinue)
    if ($disks.Count -eq 0) {
        Write-Warning "Restore-VMDiskSnapshot: no *.qcow2 disks under $dataDir."
        return $false
    }
    if (-not (Get-Command qemu-img -ErrorAction SilentlyContinue)) {
        Write-Warning "Restore-VMDiskSnapshot: qemu-img not on PATH (brew install qemu)."
        return $false
    }
    # Verify the id exists on every disk before stopping the VM, so a
    # typo on a healthy guest does not bounce it for nothing. Multi-disk
    # VMs must have the snapshot on all disks to stay coherent.
    foreach ($disk in $disks) {
        # -U (--force-share) so a running QEMU's exclusive lock doesn't
        # fail this metadata-only read with "Failed to get shared write
        # lock". This is a verify probe; the actual `qemu-img snapshot
        # -a` apply below runs AFTER the VM is stopped, so there is no
        # risk of read-while-write inconsistency here.
        $info = & qemu-img snapshot -l -U $disk.FullName 2>&1
        # `$array -notmatch <rx>` returns the filtered NON-matching lines,
        # not a Boolean -- qemu-img's two header lines make that array
        # truthy even when the data row matches. Count Where-Object hits
        # explicitly instead.
        $hits = @($info | Where-Object { $_ -match ("^\s*\d+\s+" + [regex]::Escape($Id) + "\s") })
        if ($hits.Count -eq 0) {
            Write-Warning "Restore-VMDiskSnapshot: snapshot '$Id' not present on $($disk.Name)."
            return $false
        }
    }
    if ((Get-VMState -VMName $VMName) -eq 'running') {
        if (-not (Stop-VM -VMName $VMName)) {
            [void](Stop-VMForce -VMName $VMName)
        }
    }
    # The apply below must not race a still-live QEMU helper: it holds the
    # qcow2's L1/L2 tables in memory and flushes its (un-reverted) view on
    # exit, so `qemu-img snapshot -a` exits 0 yet the guest resumes the
    # pre-revert disk -- "continues from where the last run left off"
    # instead of starting from the snapshot. Blocking on a true power-off
    # and lock release is what makes this revert as deterministic as a
    # Hyper-V checkpoint restore. Runs unconditionally because Get-VMState
    # maps 'suspended'/'paused' to 'stopped' yet those still hold the lock.
    if (-not (Wait-UtmVMPoweredOff -VMName $VMName)) {
        Write-Warning "Restore-VMDiskSnapshot: '$VMName' did not fully power off (qcow2 still locked); aborting to avoid a clobbered revert."
        return $false
    }
    # Removing vmstate at this point mirrors Start-UtmVM's cold-boot
    # prep -- the saved RAM (if any) belongs to the post-snapshot
    # universe and would collide with the reverted disk on next start.
    $vmstatePath = Join-Path $utmBundle 'Data/vmstate'
    if (Test-Path -LiteralPath $vmstatePath) {
        Remove-Item -LiteralPath $vmstatePath -Force -ErrorAction SilentlyContinue
    }
    foreach ($disk in $disks) {
        & qemu-img snapshot -a $Id $disk.FullName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Restore-VMDiskSnapshot: qemu-img snapshot -a failed for $($disk.Name) (exit $LASTEXITCODE)."
            return $false
        }
    }
    return $true
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

# --- REGION: Image

<#
.SYNOPSIS
    Run the per-guest Get-Image.ps1 to download or refresh the base image.
#>
function Get-Image {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is delegated to Invoke-GetImage, which declares SupportsShouldProcess and calls it; -WhatIf/-Confirm propagate via the splatted PSBoundParameters.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Force
    )
    # Thin wrapper over the shared runner; the host subdir is the only platform
    # variable and Get-ImagePath (the per-platform image table) is injected as a
    # CommandInfo resolved in THIS driver's scope so the shared body binds ours.
    Invoke-GetImage -HostSubdir 'host/macos.utm' -ResolveImagePath (Get-Command Get-ImagePath) @PSBoundParameters
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
    # subdir names are part of the legacy convention (amazon.linux.2023,
    # ubuntu.env, windows.env). Keep the explicit table so a typo or new
    # guest fails loud instead of silently composing the wrong path.
    $paths = @{
        'guest.amazon.linux.2023'    = "$HOME/yuruna/image/amazon.linux.2023/host.macos.utm.guest.amazon.linux.2023.qcow2"
        'guest.ubuntu.server.24'   = "$HOME/yuruna/image/ubuntu.env/host.macos.utm.guest.ubuntu.server.24.iso"
        'guest.windows.11'      = "$HOME/yuruna/image/windows.env/host.macos.utm.guest.windows.11.iso"
    }
    return $paths[$GuestKey]
}

# --- REGION: VM I/O

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
        [int]$CharDelayMs = 10,
        [switch]$Sensitive
    )
    # Sensitive is part of the contract for log redaction; current paths
    # (SSH and the Invoke-Sequence GUI dispatcher) do not yet honour it.
    if ($Sensitive) { Write-Debug "Send-Text: -Sensitive set on '$VMName'; log redaction not yet implemented on UTM." }
    if ($Mechanism -eq 'ssh') {
        if (-not $GuestKey) {
            Write-Warning "Send-Text -Mechanism ssh requires -GuestKey to determine the SSH login user."
            return $false
        }
        # Test.Ssh\Invoke-GuestSsh resolves both the user (from GuestKey)
        # and the address (from VMName) internally; surface .success, not the
        # hashtable itself -- [bool] of a non-null hashtable is always $true
        # (truthy-hashtable trap).
        $r = Invoke-GuestSsh -VMName $VMName -GuestKey $GuestKey -Command $Text
        return [bool]$r.success
    }
    # GUI: Test.SequenceEngine.psm1 has the cross-platform dispatcher and the
    # macOS-specific Send-TextVNC / Send-TextUTM helpers. We import it on
    # demand here (it ships in test/modules/ and the runner already loads
    # it for sequence execution).
    $sequenceEngine = Join-Path $script:TestModulesDir 'Test.SequenceEngine.psm1'
    if (Test-Path $sequenceEngine) {
        # Import once and reuse, matching Send-Key below. Re-importing -Force on
        # every call evicts the global Invoke-Sequence (and its nested modules
        # + $script: state) that the outer loop still calls
        # (feedback_module_force_import_evicts_global,
        # feedback_module_script_state_reset_by_force_reimport). Paying that per
        # keystroke is not just overhead: it churns the module state that this
        # driver's own -HostType argument is read from, so the very act of
        # typing can disable the keystrokes that follow it.
        if (-not (Get-Module -Name Test.SequenceEngine)) { Import-Module $sequenceEngine -DisableNameChecking -Global }
        # Module-qualified call avoids re-entering OUR Send-Text.
        return [bool](Test.SequenceEngine\Send-Text -HostType (Resolve-HostTag) -VMName $VMName -Text $Text -CharDelayMs $CharDelayMs)
    }
    Write-Warning "Send-Text -Mechanism gui: Test.SequenceEngine.psm1 not found at '$sequenceEngine'."
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
    # Defer to Invoke-Sequence's host-aware dispatcher, which resolves the key
    # name through the key-code registry and picks the VNC or CGEvent backend.
    #
    # Routing a key name through Send-Text instead does NOT work: the
    # character maps cover printable ASCII only, so a control character such
    # as CR is warn-and-skipped by every text backend while the call still
    # reports success -- a key that silently types nothing. Named keys and
    # modifier chords have to go through the key path.
    $sequenceEngine = Join-Path $script:TestModulesDir 'Test.SequenceEngine.psm1'
    if (Test-Path $sequenceEngine) {
        # Import once and reuse: a -Force re-import evicts the global
        # Invoke-Sequence (and its nested modules + $script: state) that the
        # outer loop still calls (feedback_module_force_import_evicts_global,
        # feedback_module_script_state_reset_by_force_reimport), and paying
        # that on every keystroke is pure overhead.
        if (-not (Get-Module -Name Test.SequenceEngine)) { Import-Module $sequenceEngine -DisableNameChecking -Global }
        return [bool](Test.SequenceEngine\Send-Key -HostType (Resolve-HostTag) -VMName $VMName -KeyName $Key)
    }
    Write-Warning "Send-Key -Mechanism gui: Test.SequenceEngine.psm1 not found at '$sequenceEngine'."
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

# --- REGION: Discovery

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
        [int]$PollSeconds    = 3,
        # Forwarded so a caller can widen or waive the shared poller's settle
        # window; its default applies when this is not bound.
        [int]$StableForSeconds = 8
    )
    # Get-Command runs in THIS driver's scope, so the shared poller resolves
    # our Get-VMIp; a bare name would resolve in the shared module's scope.
    Invoke-WaitVmIp @PSBoundParameters -ResolveVmIp (Get-Command Get-VMIp)
}

<#
.SYNOPSIS
    Return the guest's host-side IPv4, or null if not yet discoverable.

.DESCRIPTION
    Three rungs, cheapest first. Each answers for a different class of
    guest, and the order is part of the contract: a rung runs only when
    every rung above it declined, so a Shared-NAT guest -- which the lease
    file answers for in milliseconds -- never pays for the LAN sweep a
    bridged guest needs.

      1. utmctl ip-address -- the guest's own report, via qemu-guest-agent.
         Free when it answers and silent for every guest this repo seeds,
         because the seeds do not install the agent.
      2. /var/db/dhcpd_leases -- the lease file of the macOS SHARED-NAT
         DHCP server. Authoritative for a Shared guest, and structurally
         blind to a bridged one, which leases from the LAN router and
         never appears in it.
      3. The bundle's MAC in the host ARP table. The only rung that can see
         a bridged guest, and the reason this chain has three rungs: with
         just the first two, a healthy bridged guest serving traffic is
         indistinguishable from a VM that does not exist, and every caller
         waits out its whole budget against $null.

    Each decline is narrated to the verbose stream naming the rung and why
    it could not answer. Three sources that all return $null otherwise
    report "no address yet" in exactly the same words as "no such VM",
    which is the difference between a 30-second diagnosis and a 30-minute
    one when a run is examined afterwards.

    Safe to call from a polling loop, which is what rung 3 is shaped
    around. A guest that is up and has exchanged traffic with the host
    answers from the ARP table in well under a second; a guest that is
    not running is declined for the cost of one state query; and the ICMP
    sweep -- the only part measured in seconds -- runs at most once per
    minute per VM, so no caller can turn its poll interval into a sweep
    interval.
#>
function Get-VMIp {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $ip = Get-UtmAgentReportedIp -VMName $VMName
    if ($ip) { return $ip }
    # Read the bundle once and hand it to both rungs that need it: each
    # would otherwise shell out to plutil for the same file.
    $bundleNetwork = Get-UtmBundleNetwork -VMName $VMName
    $ip = Get-UtmSharedLeaseIp -VMName $VMName -BundleNetwork $bundleNetwork
    if ($ip) { return $ip }
    $ip = Get-UtmBridgedGuestIp -VMName $VMName -BundleNetwork $bundleNetwork
    if ($ip) { return $ip }
    Write-Verbose "Get-VMIp: all three rungs declined for '$VMName' (guest agent, shared-NAT lease file, bundle MAC in ARP); each said why above."
    return $null
}

<#
.SYNOPSIS
    Rung 1: the address the guest reports through utmctl, or $null.
.PARAMETER UtmctlLine
    Pre-captured `utmctl ip-address` output. The live command is run when
    this is not bound; supplying it keeps the parsing testable with no VM.
#>
function Get-UtmAgentReportedIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [AllowEmptyCollection()][string[]]$UtmctlLine
    )
    $output = $UtmctlLine
    if (-not $PSBoundParameters.ContainsKey('UtmctlLine')) {
        if (-not (Get-Command utmctl -ErrorAction SilentlyContinue)) {
            Write-Verbose "Get-VMIp rung 'guest agent' declined for '$VMName': utmctl is not on PATH."
            return $null
        }
        try {
            $output = & utmctl ip-address $VMName 2>&1
            # utmctl exits 0 even when the guest has no agent to ask, writing
            # its complaint to stderr, so the exit code cannot be the test for
            # "an address came back" -- only the parse below can be.
            if ($LASTEXITCODE -ne 0) {
                Write-Verbose "Get-VMIp rung 'guest agent' declined for '$VMName': utmctl ip-address exited $LASTEXITCODE."
                return $null
            }
        } catch {
            Write-Verbose "Get-VMIp rung 'guest agent' declined for '$VMName': utmctl ip-address failed: $($_.Exception.Message)"
            return $null
        }
    }
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
    Write-Verbose "Get-VMIp rung 'guest agent' declined for '$VMName': utmctl reported no usable address (the seeds do not install qemu-guest-agent, so this is the normal answer)."
    return $null
}

<#
.SYNOPSIS
    Rung 2: the guest's address in the macOS shared-NAT lease file, or $null.
.DESCRIPTION
    The DHCP server keys each block on the name the GUEST sent, which is the
    VM name only when no sequence pinned variables.hostname; a pinned hostname
    makes the guest register under that instead. A VM-name lookup therefore
    does not come back empty when a hostname is pinned -- it matches leftover
    blocks filed under the VM name by predecessors and hands back a dead
    address, often on a subnet the host no longer serves, which costs a full
    SSH connect-timeout budget per attempt. Both keys are tried, pinned
    hostname first, and Select-DhcpLeaseIpAddress discards any candidate that
    is not on a live host-interface subnet.

    A guest whose bundle says Bridged is skipped outright. This file belongs
    to the shared-NAT DHCP server; a bridged guest takes its lease from the
    LAN router and cannot legitimately appear here, so any block bearing its
    name is a predecessor's from when the name was last built on Shared NAT.
    Those blocks parse, sit on-link while the vmnet bridge is up, and look
    exactly like a good answer -- returning one would hide the guest's real
    LAN address behind a dead 192.168.64.x for the rest of the run.
.PARAMETER BundleNetwork
    The bundle's network descriptor (Get-UtmBundleNetwork). Read here when
    not supplied; Get-VMIp supplies it so one plist read serves the chain.
.PARAMETER LeaseText
    Pre-captured lease-file text. The live file is read when this is not
    bound; supplying it keeps the selection testable with no guests running.
.PARAMETER OnLinkVerdict
    Forwarded to Select-DhcpLeaseIpAddress, which judges each candidate
    against the host's live interface subnets by default. Supplying a
    verdict fixes that judgement, so a lease fixture reads the same on a
    host that serves the vmnet subnet and on one that does not.
#>
function Get-UtmSharedLeaseIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [psobject]$BundleNetwork,
        [AllowEmptyString()][AllowNull()][string]$LeaseText,
        [scriptblock]$OnLinkVerdict
    )
    if (-not $PSBoundParameters.ContainsKey('BundleNetwork')) { $BundleNetwork = Get-UtmBundleNetwork -VMName $VMName }
    if ($BundleNetwork -and $BundleNetwork.Mode -eq 'Bridged') {
        Write-Verbose "Get-VMIp rung 'shared-NAT lease file' declined for '$VMName': the bundle is Bridged, so its lease comes from the LAN router and any block under this name belongs to a predecessor."
        return $null
    }
    $content = $LeaseText
    if (-not $PSBoundParameters.ContainsKey('LeaseText')) {
        $leaseFile = '/var/db/dhcpd_leases'
        if (-not (Test-Path $leaseFile)) {
            Write-Verbose "Get-VMIp rung 'shared-NAT lease file' declined for '$VMName': $leaseFile does not exist (no guest has ever taken a shared-NAT lease on this host)."
            return $null
        }
        try {
            $content = Get-Content $leaseFile -Raw -ErrorAction Stop
        } catch {
            Write-Verbose "Get-VMIp rung 'shared-NAT lease file' declined for '$VMName': could not read $leaseFile`: $($_.Exception.Message)"
            return $null
        }
    }
    $pinnedHostname = Get-UtmGuestSeedHostname -VMName $VMName
    $leaseNames = @($pinnedHostname)
    if ($pinnedHostname -ne $VMName) { $leaseNames += $VMName }
    $selectArgs = @{ LeaseText = $content; Name = $leaseNames }
    if ($PSBoundParameters.ContainsKey('OnLinkVerdict')) { $selectArgs['OnLinkVerdict'] = $OnLinkVerdict }
    $bestIp = Select-DhcpLeaseIpAddress @selectArgs
    if ($bestIp) { return [string]$bestIp }
    Write-Verbose "Get-VMIp rung 'shared-NAT lease file' declined for '$VMName': no on-link lease filed under $($leaseNames -join ' or ')."
    return $null
}

<#
.SYNOPSIS
    Rung 3: the guest's bundle MAC matched in the host ARP table, or $null.

.DESCRIPTION
    The rung a bridged guest depends on. It sits on the host's LAN with an
    address from the LAN's own DHCP server, so neither the guest agent nor
    the shared-NAT lease file can name it -- but it answers ARP, and the
    bundle's MAC identifies it unambiguously among everything else on that
    LAN, including a sibling host's identically-named VM.

    Two passes, and the order is the whole reason this is affordable in a
    hot path. The passive pass reads `arp -an` and matches: ~20 ms, and it
    is what steady state costs, because a guest that has exchanged any
    traffic with the host is already in the table. Only when the table has
    nothing does the ICMP sweep run -- a full /24 at 32-way parallelism is
    SECONDS (measured at ~8 s on a 253-address subnet), which is why it is
    one attempt with no retry loop: Get-VMIp is called per cycle by the
    runner and inside Wait-VMIp's poll loop, and a rung that blocked for
    minutes there would be worse than the discovery hole it closes. The
    poll loop is the retry.

    Two further guards bound what the sweep can cost a REPEAT caller, because
    the passive pass only protects a guest that is already on the LAN:

      * a VM that is not RUNNING is never swept for. Nothing powered off
        answers ICMP, so the sweep could only come back empty -- and this is
        the common shape, not an edge case: a bundle outlives its guest, so
        every lookup for a service whose VM is down would otherwise pay full
        price to learn what one state query already knows;
      * an empty sweep is remembered briefly, so a caller polling every few
        seconds through a guest's boot sweeps on a cadence of its own rather
        than once per poll. A found address retires the memo at once, and the
        memo suppresses only the ESCALATION -- the passive read still runs on
        every call, so a guest that appears mid-cooldown is picked up by the
        very next poll at ~20 ms.

    A guest whose bundle says Shared is skipped: it lives on the vmnet
    subnet, not the host's LAN, so the sweep could not match it and rung 2
    already answered for it. A bundle with no readable mode still gets both
    passes -- an unreadable mode is not evidence the guest is on NAT.
.PARAMETER BundleNetwork
    The bundle's network descriptor (Get-UtmBundleNetwork). Read here when
    not supplied; Get-VMIp supplies it so one plist read serves the chain.
.PARAMETER SubnetPrefix
    The dot-terminated /24 to match and, if needed, sweep. Derived from the
    host's own default-route interface when not supplied -- a bridged guest
    is on the host's LAN by construction, so that is where it must be
    looked for, on whatever subnet this host happens to sit on.
.PARAMETER HostIp
    The host's address on that subnet, skipped by the sweep. Derived
    alongside -SubnetPrefix when not supplied.
.PARAMETER ArpLine
    Pre-captured `arp -an` output. The live table is read when this is not
    bound; supplying it keeps the match testable with no guests running.
#>
# How long an empty sweep suppresses the next one, per VM. Long enough that a
# 3-second poll loop cannot turn every poll into a /24 of ICMP, short enough
# that a guest finishing its DHCP exchange is swept for again while the caller
# that wants it is still waiting.
$script:UtmBridgedSweepCooldownSeconds = 60
$script:UtmBridgedSweepMiss = @{}

function Get-UtmBridgedGuestIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [psobject]$BundleNetwork,
        [string]$SubnetPrefix,
        [string]$HostIp,
        [AllowEmptyCollection()][string[]]$ArpLine
    )
    if (-not $PSBoundParameters.ContainsKey('BundleNetwork')) { $BundleNetwork = Get-UtmBundleNetwork -VMName $VMName }
    if (-not $BundleNetwork) {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': no readable .utm bundle on this host, so there is no MAC to match."
        return $null
    }
    if ($BundleNetwork.Mode -eq 'Shared') {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': the bundle is on Shared NAT, which the lease file answers for; this rung looks on the host's LAN."
        return $null
    }
    $macNeedle = ConvertTo-ArpMacNeedle -MacAddress $BundleNetwork.MacAddress
    if (-not $macNeedle) {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': the bundle carries no usable MacAddress."
        return $null
    }
    if (-not ($PSBoundParameters.ContainsKey('SubnetPrefix') -and $PSBoundParameters.ContainsKey('HostIp'))) {
        # One default-route read answers both. Get-HostLanPrefix is
        # Get-BestHostIp plus a regex, so resolving them independently spawns
        # `route` and `ipconfig` twice per call on a path Wait-VMIp polls --
        # and lets the prefix and the host address come from different uplinks
        # when the default route changes between the two reads.
        $lanIp = Get-BestHostIp
        if (-not $PSBoundParameters.ContainsKey('HostIp'))       { $HostIp = $lanIp }
        if (-not $PSBoundParameters.ContainsKey('SubnetPrefix')) { $SubnetPrefix = Get-HostLanPrefix -HostIp $lanIp }
    }
    if (-not $SubnetPrefix) {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': this host has no default-route IPv4, so there is no LAN to look on."
        return $null
    }
    if (-not $PSBoundParameters.ContainsKey('ArpLine')) { $ArpLine = @(& /usr/sbin/arp -an 2>$null) }
    $ip = Select-ArpIpByMac -ArpLine $ArpLine -MacNeedle $macNeedle -SubnetPrefix $SubnetPrefix
    if ($ip) {
        # A hit retires any memo: whatever kept the guest off the LAN is over,
        # and the next call must be free to escalate again the moment it is not.
        $script:UtmBridgedSweepMiss.Remove($VMName)
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' resolved '$VMName' to $ip from the host's existing ARP table."
        return [string]$ip
    }

    # Everything below escalates. The guards are ordered by what they cost:
    # the memo is a hashtable read, the state query one utmctl call, the sweep
    # seconds -- so the cheapest thing that can rule the sweep out runs first.
    $lastMiss = $script:UtmBridgedSweepMiss[$VMName]
    if ($lastMiss -and ((Get-Date) - $lastMiss).TotalSeconds -lt $script:UtmBridgedSweepCooldownSeconds) {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': a sweep of ${SubnetPrefix}0/24 found nothing $([int]((Get-Date) - $lastMiss).TotalSeconds)s ago and the host's ARP table still has no entry, so another one now would cost seconds to learn the same thing."
        return $null
    }
    $state = Get-VMState -VMName $VMName
    if ($state -ne 'running') {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': the VM is '$state', not running -- a guest that is not up answers no ICMP, so there is nothing for a sweep to find."
        return $null
    }

    Write-Verbose "Get-VMIp rung 'bundle MAC in ARP': MAC $($BundleNetwork.MacAddress) is not in the host's ARP table yet; sweeping ${SubnetPrefix}0/24 ONCE to populate it (seconds)."
    $swept = Resolve-UtmGuestIpByMac -PlistPath $BundleNetwork.PlistPath -SubnetPrefix $SubnetPrefix -HostIp $HostIp -MaxAttempt 1
    if ($swept) {
        $script:UtmBridgedSweepMiss.Remove($VMName)
        return [string]$swept
    }
    $script:UtmBridgedSweepMiss[$VMName] = Get-Date
    Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': the sweep of ${SubnetPrefix}0/24 matched no entry carrying MAC $($BundleNetwork.MacAddress). The guest is running but not on this LAN yet; the next $($script:UtmBridgedSweepCooldownSeconds)s of calls read the ARP table without re-sweeping."
    return $null
}

<#
.SYNOPSIS
    Return the guest's MAC address, or null if not available.
.DESCRIPTION
    utmctl exposes no MAC, so the bundle is the source: it is where UTM
    records the address the VM boots with, and it is readable whether or
    not the VM is running.
#>
function Get-VMMac {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $bundleNetwork = Get-UtmBundleNetwork -VMName $VMName
    if (-not $bundleNetwork -or -not $bundleNetwork.MacAddress) {
        Write-Verbose "Get-VMMac on host.macos.utm: no MacAddress in the bundle for '$VMName'."
        return $null
    }
    return ([string]$bundleNetwork.MacAddress).ToUpperInvariant()
}

<#
.SYNOPSIS
    Normalize a MAC to the form `arp -an` prints it, or $null when the
    input is not six hex octets.
.DESCRIPTION
    macOS prints ARP entries lowercase with the leading zero of each octet
    stripped ('0F' -> 'f'), while the bundle stores the canonical
    'E6:01:BC:6D:21:CD'. Comparing the two forms directly never matches, so
    every ARP lookup normalizes through here rather than carrying its own
    copy of the rule.
#>
function ConvertTo-ArpMacNeedle {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$MacAddress)
    if ([string]::IsNullOrWhiteSpace($MacAddress)) { return $null }
    $octets = @($MacAddress -split ':')
    if ($octets.Count -ne 6) { return $null }
    try {
        return (($octets | ForEach-Object { ([Convert]::ToInt32($_, 16)).ToString('x') }) -join ':')
    } catch {
        Write-Debug "ConvertTo-ArpMacNeedle: '$MacAddress' is not six hex octets: $($_.Exception.Message)"
        return $null
    }
}

<#
.SYNOPSIS
    Return the IPv4 in $SubnetPrefix whose ARP entry carries $MacNeedle,
    or $null when the table holds no such entry.
.DESCRIPTION
    The match is required to be IN the given subnet, not just any ARP entry
    carrying that MAC. `arp -an` lists EVERY interface, so a stale or
    foreign entry with the same MAC (a recreated bundle MAC still cached on
    another NIC) printed first would otherwise be selected -- and, since
    the first match wins, re-selected on every poll, wedging a caller
    against the wrong address until its timeout.

    $SubnetPrefix is dot-terminated (e.g. '192.168.64.'), so the prefix test
    cannot false-match a sibling /24 like 192.168.640.x.
.PARAMETER ArpLine
    Lines as `arp -an` prints them.
#>
function Select-ArpIpByMac {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArpLine,
        [Parameter(Mandatory)][string]$MacNeedle,
        [Parameter(Mandatory)][string]$SubnetPrefix
    )
    foreach ($line in $ArpLine) {
        if ($line -match '^\? \(([\d.]+)\) at (\S+)' -and
            $matches[2] -eq $MacNeedle -and
            $matches[1].StartsWith($SubnetPrefix)) {
            return [string]$matches[1]
        }
    }
    return $null
}

<#
.SYNOPSIS
    Resolve a freshly-built UTM bundle's current IPv4 by matching its
    config.plist MAC against the host ARP table -- the reliable identity
    signal for both Shared-NAT and bridged VMs.

.DESCRIPTION
    The bundle's MAC (random per build, written to config.plist) is the
    ONLY stable identity for a just-created VM. Discovery by DHCP hostname
    is unsafe: a rebuilt VM reuses the same hostname, so /var/db/dhcpd_leases
    accumulates stale same-named blocks from deleted predecessors, and the
    lease's hw_address is a DHCP DUID (not the link MAC), so it can't
    disambiguate -- a name lookup that runs before THIS VM has DHCP'd locks
    onto a dead predecessor's IP. Matching the MAC in `arp -an` instead
    always returns the live VM, immune to the DHCP race and stale leases.

    Populates the ARP cache by ICMP-sweeping the subnet in parallel (the VM
    answers ICMP from cloud-init early, before squid binds), then matches
    OUR MAC. When -ProbePort > 0, the candidate must also answer that TCP
    port before it is accepted, so the returned IP is one squid is already
    serving on. Polls until found, until -TimeoutMinutes elapses, or until
    -MaxAttempt sweeps have been made.

.PARAMETER PlistPath
    Path to the bundle's config.plist (holds <key>MacAddress</key>).

.PARAMETER SubnetPrefix
    The /24 to sweep, e.g. '192.168.64.' (Shared-NAT) or the host's LAN
    prefix (bridged). Octets 2..254 are pinged.

.PARAMETER HostIp
    Address to skip in the sweep (the host's own IP on that subnet).

.PARAMETER ProbePort
    If > 0, require this TCP port to answer on the MAC-matched IP before
    accepting it (e.g. squid's 3128). 0 = accept on MAC match alone.

.PARAMETER MaxAttempt
    Cap on sweep-and-match rounds. 0 (the default) means "as many as
    -TimeoutMinutes allows" -- the bring-up scripts wait out a whole guest
    boot that way. 1 makes this a single bounded probe that returns in the
    time one sweep takes, which is what a caller in a per-cycle path needs:
    for it the surrounding poll loop is the retry, and blocking here for
    minutes would cost far more than the answer is worth.

.OUTPUTS
    [string] the matched IPv4, or $null on timeout / missing-MAC.
#>
function Resolve-UtmGuestIpByMac {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$PlistPath,
        [Parameter(Mandatory)][string]$SubnetPrefix,
        [string]$HostIp,
        [int]$ProbePort = 0,
        [int]$TimeoutMinutes = 15,
        [int]$PollSeconds = 5,
        [int]$MaxAttempt = 0
    )
    if (-not (Test-Path -LiteralPath $PlistPath)) {
        Write-Warning "Resolve-UtmGuestIpByMac: bundle plist not found at $PlistPath -- cannot identify the VM by MAC."
        return $null
    }
    $plistText = Get-Content -Raw -LiteralPath $PlistPath
    if ($plistText -notmatch '<key>MacAddress</key>\s*<string>([0-9A-Fa-f:]+)</string>') {
        Write-Warning "Resolve-UtmGuestIpByMac: no MacAddress in $PlistPath -- cannot identify the VM by MAC."
        return $null
    }
    $ourMacRaw = $matches[1]
    $macNeedle = ConvertTo-ArpMacNeedle -MacAddress $ourMacRaw
    if (-not $macNeedle) {
        Write-Warning "Resolve-UtmGuestIpByMac: MacAddress '$ourMacRaw' in $PlistPath is not six hex octets -- cannot identify the VM by MAC."
        return $null
    }
    Write-Verbose "Resolve-UtmGuestIpByMac: matching MAC $ourMacRaw (needle '$macNeedle') on ${SubnetPrefix}0/24."

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $found = $null
    $attempt = 0
    # A do-loop, so one round always happens: -MaxAttempt 1 has to mean
    # "sweep once and answer", and a while-first shape would decide the
    # deadline had passed before ever looking.
    do {
        $attempt++
        # ICMP-sweep the /24 in parallel to populate the host ARP cache.
        # -t 1 keeps packets on-LAN (TTL 1); -W 200 caps per-host wait at
        # 200 ms; ThrottleLimit 32 holds a 253-address sweep to seconds --
        # measured at ~8 s, so this is never on a path that cannot spare it.
        2..254 |
            Where-Object { "$SubnetPrefix$_" -ne $HostIp } |
            ForEach-Object -Parallel {
                $c = "$using:SubnetPrefix$_"
                try { & /sbin/ping -c 1 -W 200 -t 1 $c *>$null } catch { $null = $_ }
            } -ThrottleLimit 32 | Out-Null

        $candidateIp = Select-ArpIpByMac -ArpLine @(& /usr/sbin/arp -an 2>$null) `
            -MacNeedle $macNeedle -SubnetPrefix $SubnetPrefix
        if ($candidateIp) {
            if ($ProbePort -le 0) { $found = $candidateIp; break }
            $tcp = New-Object System.Net.Sockets.TcpClient
            try {
                $async = $tcp.BeginConnect($candidateIp, $ProbePort, $null, $null)
                if ($async.AsyncWaitHandle.WaitOne(500) -and $tcp.Connected) {
                    $found = $candidateIp
                    break
                }
            } catch {
                Write-Verbose "Resolve-UtmGuestIpByMac: probe ${candidateIp}:${ProbePort} failed: $($_.Exception.Message)"
            } finally { $tcp.Close() }
            Write-Verbose "Resolve-UtmGuestIpByMac: MAC match at $candidateIp but :$ProbePort not listening yet -- waiting."
        }
        if ($MaxAttempt -gt 0 -and $attempt -ge $MaxAttempt) {
            Write-Verbose "Resolve-UtmGuestIpByMac: no match after $attempt attempt(s); the caller asked for at most $MaxAttempt."
            break
        }
        # Sleep only when another round will follow, so a run that is out of
        # budget returns now instead of one poll interval from now.
        if ((Get-Date).AddSeconds($PollSeconds) -ge $deadline) { break }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)
    return $found
}

# --- REGION: Networking

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
    True when the host's default-route uplink cannot carry a bridged
    guest MAC -- on macOS that is the Wi-Fi hardware port.
.DESCRIPTION
    QEMU bridged networking is unreliable over Wi-Fi: the access point
    commonly drops frames from the VM's locally-administered MAC, so a
    bridged guest never gets a LAN DHCP lease. Callers use this to fall
    back to UTM Shared NAT (192.168.64.x) + host port-forwarders on Wi-Fi-
    only hosts. Returns $false when the default route is Ethernet/USB-
    Ethernet, or when there is no default route at all (the caller surfaces
    the missing-route error on its own bridged path).

    macOS counterpart of host.windows.hyper-v Test-WindowsUplinkNotBridgeable,
    but the criteria differ by hypervisor: vmnet bridges USB Ethernet fine
    (it is plain wired Ethernet here), so only Wi-Fi is rejected -- whereas
    Hyper-V's External vSwitch also rejects USB NICs.
.OUTPUTS
    [bool]
#>
function Test-MacUplinkNotBridgeable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $iface = $null
    foreach ($line in (& '/sbin/route' -n get default 2>$null)) {
        if ($line -match 'interface:\s*(\S+)') { $iface = $matches[1]; break }
    }
    if (-not $iface) { return $false }
    # networksetup -listallhardwareports prints stanzas of the form:
    #   Hardware Port: Wi-Fi
    #   Device: en0
    #   Ethernet Address: ...
    # Collect the Device of every Wi-Fi port, then test the default-route
    # interface for membership.
    $wifiDevices = [System.Collections.Generic.List[string]]::new()
    $portIsWifi  = $false
    foreach ($line in (& '/usr/sbin/networksetup' -listallhardwareports 2>$null)) {
        if ($line -match '^Hardware Port:\s*(.+?)\s*$') {
            $portIsWifi = ($matches[1] -match 'Wi-?Fi')
            continue
        }
        if ($portIsWifi -and $line -match '^Device:\s*(\S+)') {
            $wifiDevices.Add($matches[1])
            $portIsWifi = $false
        }
    }
    return ($wifiDevices -contains $iface)
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
    Returns true if the caching-proxy-service VM is on an External-type network.
.DESCRIPTION
    On macOS the cache VM is built with UTM's QEMU bridged networking on
    an Ethernet default route (see
    host/macos.utm/guest.caching-proxy-service/config.plist.template; Wi-Fi
    hosts fall back to Shared NAT + host forwarders), so it
    rides the host's physical LAN with its own DHCP-assigned IP. That
    is the macOS analog of Hyper-V's Yuruna-External vSwitch path: the
    caller's "no host portproxy needed" fast path applies unconditionally
    on this host. VMName is accepted for cross-host parity (Hyper-V
    consults Get-VMNetworkAdapter); we never look at the VM here.
#>
function Test-CacheVMOnExternalNetwork {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VMName = 'yuruna-caching-proxy-service')
    Write-Debug "Test-CacheVMOnExternalNetwork on host.macos.utm: returning `$true for '$VMName' (cache VM is QEMU-bridged to the host's physical NIC)."
    return $true
}

<#
.SYNOPSIS
    Install host to VM port forwarders for the caching-proxy service.
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
    # Start-CachingProxyServiceForwarder. Each call is idempotent per port and
    # leaves OTHER ports' forwarders alone -- mid-cycle :3000 refresh
    # MUST NOT disturb the running :3128 forwarder.
    $launched = @()
    $failed = @()
    $attempted = 0
    foreach ($m in $mappings) {
        $useProxy = $proxyProtoSet.ContainsKey([int]$m.HostPort)
        $proxyTag = if ($useProxy) { ' [PROXY v1]' } else { '' }
        if (-not $PSCmdlet.ShouldProcess("0.0.0.0:$($m.HostPort) -> ${VMIp}:$($m.VMPort)${proxyTag}", 'Launch macOS squid forwarder')) { continue }
        $attempted++
        $started = if ($useProxy) {
            Start-CachingProxyServiceForwarder -CacheIp $VMIp -Port $m.HostPort -VMPort $m.VMPort -PrependProxyV1
        } else {
            Start-CachingProxyServiceForwarder -CacheIp $VMIp -Port $m.HostPort -VMPort $m.VMPort
        }
        if ($started) { $launched += $m.HostPort } else { $failed += $m.HostPort }
    }
    if ($failed.Count -gt 0) {
        Write-Warning "Add-PortMap: forwarder(s) failed to launch for port(s): $($failed -join ', '). The cache pipeline for those ports is unavailable."
    }
    # Report success only when EVERY attempted forwarder launched. A partial launch reported as
    # success hides a missing forwarder (e.g. :3128 / :3129 / SSH) so downstream guest fetches
    # silently bypass or fail against the cache with no recovery triggered.
    return ($attempted -gt 0 -and $launched.Count -eq $attempted)
}

<#
.SYNOPSIS
    Tear down all yuruna caching-proxy-service port forwarders.
#>
function Remove-PortMap {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('pwsh forwarders', 'Stop all yuruna port forwarders')) { return $false }
    $stopped = @(Stop-AllCachingProxyServiceForwarder)
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
    Hands artifacts written by a root-run build back to the operator who
    invoked sudo. Returns $true when ownership was restored. No-op off macOS,
    when not running as root, or when sudo did not name an invoking user.

.DESCRIPTION
    A UTM bundle created under sudo is root-owned, and UTM.app runs as the
    operator -- it cannot open, start, or later delete such a bundle. The
    parents matter as much as the bundle: removing a directory needs write
    permission on the directory ABOVE it, and ~/yuruna/guest.nosync is shared by
    every macOS builder, so one root-run build blocks every later rebuild.
    Restoring the whole tree is therefore the fix; restoring the bundle alone
    repairs this run and breaks the next.

    This is a GUARD, not a licence to run these scripts under sudo: root has no
    Aqua session, so `open`, `utmctl` and the osascript dialog watchdog fail
    before ownership is ever reached. The supported invocation is unelevated --
    the scripts request sudo per operation.
#>
function Restore-SudoUserOwnership {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string[]]$Path)
    if (-not $IsMacOS) { return $false }
    $sudoUser = "$env:SUDO_USER".Trim()
    if (-not $sudoUser -or $sudoUser -eq 'root') { return $false }
    $isRoot = $false
    try { $isRoot = ((& '/usr/bin/id' -u) -eq '0') } catch { Write-Verbose "id -u check failed: $($_.Exception.Message)" }
    if (-not $isRoot) { return $false }

    # Plain `sudo` (without -E) resets HOME to /var/root, so a build launched
    # that way put every artifact in root's home, where chown cannot help --
    # the operator cannot traverse into it. Say so instead of silently
    # "succeeding" on a tree they will never see.
    $sudoUserHome = "$(& '/usr/bin/dscl' . -read "/Users/$sudoUser" NFSHomeDirectory 2>$null)" -replace '^NFSHomeDirectory:\s*', ''
    $sudoUserHome = $sudoUserHome.Trim()
    if ($sudoUserHome -and $HOME -and -not $HOME.StartsWith($sudoUserHome)) {
        Write-Warning "This build ran as root with HOME=$HOME, so its artifacts are in root's home, not $sudoUserHome. UTM (running as $sudoUser) cannot reach them. Re-run WITHOUT sudo -- these scripts elevate the individual operations that need it."
    }

    $restored = $false
    foreach ($p in $Path) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        if (-not $PSCmdlet.ShouldProcess($p, "Restore ownership to '$sudoUser'")) { continue }
        & /usr/sbin/chown -R "$sudoUser" $p 2>$null
        if ($LASTEXITCODE -eq 0) { $restored = $true }
        else { Write-Warning "Could not restore ownership of '$p' to '$sudoUser'; run: sudo chown -R $sudoUser '$p'" }
    }
    if ($restored) { Write-Information -MessageData "  Restored ownership of the build artifacts to '$sudoUser' (they were created as root)." -InformationAction Continue }
    return $restored
}

<#
.SYNOPSIS
    Returns the network mode a UTM service VM must be built with on this host:
    'Bridged' on an Ethernet default route, 'Shared' on a Wi-Fi one.

.DESCRIPTION
    The mode and the address a guest reaches the host at are a matched pair --
    the address only works from the network it was derived for -- so both are
    resolved from this one verdict. Bridged is preferred: the VM takes a LAN
    DHCP lease and peers reach its services at <vm-lan-ip> directly. vmnet
    cannot bridge a Wi-Fi uplink (the AP drops frames from the VM's
    locally-administered MAC), so a Wi-Fi default route falls back to UTM
    Shared NAT and the caller forwards host ports for LAN reach.

    USB Ethernet bridges fine here (it is plain wired Ethernet to vmnet),
    unlike Hyper-V -- so a dongle turns a Wi-Fi laptop into the Bridged case.

.OUTPUTS
    [string] 'Bridged' or 'Shared'.
#>
function Resolve-UtmNetworkMode {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (Test-MacUplinkNotBridgeable) { return 'Shared' }
    return 'Bridged'
}

<#
.SYNOPSIS
    Returns the host IP a UTM guest reaches the host at, for the network mode
    that guest is attached to.

.DESCRIPTION
    On Apple Virtualization shared NAT -- the mode every install guest uses,
    and the default here -- guests always reach the host at 192.168.64.1, the
    VZ gateway IP set by the framework and not configurable per VM.

    A Bridged guest sits on the LAN instead and cannot reach that gateway at
    all, so it reaches the host at the host's own LAN address. Callers that
    build Bridged VMs (the service VMs, via Resolve-UtmNetworkMode) must pass
    -NetworkMode Bridged or they bake an address the guest cannot route to.
    Returns $null when Bridged is asked for and the host has no LAN address:
    there is no correct answer to fall back to, and an empty value makes the
    caller degrade honestly rather than bake the wrong gateway.

.PARAMETER SwitchName
    Accepted for cross-host contract parity (Hyper-V uses it to choose
    Default Switch vs. External vSwitch); unused on macOS.

.PARAMETER NetworkMode
    The mode the consuming guest is attached to. Defaults to 'Shared', which
    is what every caller that does not build a Bridged VM wants.

.OUTPUTS
    [string] the VZ gateway address, the host's LAN IPv4, or $null.
#>
function Get-GuestReachableHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$SwitchName,
        [ValidateSet('Shared', 'Bridged')][string]$NetworkMode = 'Shared'
    )
    # macOS has no Default Switch / External vSwitch concepts; SwitchName
    # is accepted for cross-host parity and the mode decides the answer.
    if ($SwitchName) { Write-Debug "Get-GuestReachableHostIp on host.macos.utm: -SwitchName '$SwitchName' ignored; the network mode selects the address." }
    if ($NetworkMode -eq 'Bridged') {
        $lanIp = Get-BestHostIp
        if ($lanIp) { return $lanIp }
        Write-Warning "Get-GuestReachableHostIp: -NetworkMode Bridged but this host has no default-route IPv4; a bridged guest has no address to reach it at."
        return $null
    }
    return '192.168.64.1'
}

# --- REGION: Caching-proxy service

<#
.SYNOPSIS
    Returns the host's LAN /24 prefix (e.g. '192.168.7.') based on the
    default-route interface, or $null when the host has no default route.
.DESCRIPTION
    This is the /24 a bridged guest is looked for on: it sits on the host's
    LAN by construction, so the host's own default-route subnet is where its
    address must be. (It is NOT consulted by
    Test-CachingProxyServiceAvailable, which is restricted to state-file +
    YURUNA_CACHING_PROXY_SERVICE_IP discovery.) Returns the first three
    octets with a trailing dot so the caller can append "$prefix$octet"
    without further string surgery. /24 is an assumption -- it matches the
    home/office DHCP setups the repo targets; a /23 LAN would silently miss
    half the address space. Acceptable trade-off given the alternative is
    parsing the netmask from `ifconfig` output for what is, in practice, a
    /24 99% of the time.
.PARAMETER HostIp
    The host address to take the prefix from. Resolved with Get-BestHostIp
    when not supplied; a caller that already has it passes it so the
    default-route lookup (two process spawns) is not repeated.
.OUTPUTS
    [string] e.g. '192.168.7.' (with trailing dot), or $null.
#>
function Get-HostLanPrefix {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$HostIp)
    if (-not $PSBoundParameters.ContainsKey('HostIp')) { $HostIp = Get-BestHostIp }
    if (-not $HostIp) { return $null }
    if ($HostIp -notmatch '^(\d+\.\d+\.\d+)\.(\d+)$') { return $null }
    return ($matches[1] + '.')
}

<#
.SYNOPSIS
    Probe and return the caching-proxy-service URL, or null if none is reachable.
.DESCRIPTION
    Discovery is intentionally narrow -- only caches this host owns,
    or a remote cache the operator explicitly named, are returned:
      1. $Env:YURUNA_CACHING_PROXY_SERVICE_IP -- explicit remote cache override.
      2. State file (Read-CachingProxyServiceState).ipAddress -- the cache VM's
         LAN IP written by Start-CachingProxyServiceVM.ps1 Step 4 (our own VM).

    No LAN scan, no ARP discovery. The previous /24 subnet scan would
    happily lock onto a sibling host's yuruna-caching-proxy-service on the same
    LAN and even persist its IP back into the state file, so Stop-
    CachingProxyService could not actually take the local host out of the
    "cache available" state when a peer was still serving on :3128.
    LAN-wide cache discovery is a separate future feature.

    Returns the cache VM's LAN URL directly -- no host-side forwarder
    layer to fail in between, no VZ-gateway URL gymnastics. This is the
    macOS equivalent of the Hyper-V Yuruna-External vSwitch path: squid
    sees real client IPs at TCP level, remote operators set
    YURUNA_CACHING_PROXY_SERVICE_IP=<cache-lan-ip> and reach the cache directly,
    and other UTM guests on shared-NAT reach the LAN IP through the
    VMnet outbound NAT (same path they use to reach Ubuntu mirrors).
#>
function Test-CachingProxyServiceAvailable {
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$Quiet)
    # Thin wrapper over the shared probe; the only platform variable is the
    # operator verify-command template embedded in the unreachable-cache
    # warning (nc on macOS). The kvm driver keeps its own probe (it omits
    # Format-IpUrlHost's IPv6 bracketing the guests rely on). -Quiet drops the
    # "no cache" diagnostics to verbose for callers that only decorate with a
    # cache URL when one exists.
    Invoke-CachingProxyServiceAvailableProbe -VerifyHint 'nc -G 2 -z {0} {1}' -Quiet:$Quiet
}

<#
.SYNOPSIS
    Return the cache VM's LAN IP, or $null when none is recorded yet.
.DESCRIPTION
    With Apple Virtualization bridged networking the cache VM gets its
    own DHCP-assigned LAN IP (no VZ-gateway indirection), so the URL
    Test-CachingProxyServiceAvailable returns already carries the real IP. This
    helper exists for callers that want JUST the IP (status service's
    portproxy IP target on Windows; on macOS the result feeds into
    summary lines and YURUNA_CACHING_PROXY_SERVICE_IP hints).
#>
function Get-CachingProxyServiceVmIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $ip = (Read-CachingProxyServiceState).ipAddress
    if ($ip -and (Test-Ipv4Address $ip)) { return $ip }
    return $null
}

# --- REGION: Host config

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
    # Idempotent backup: only snapshot BEFORE the first apply, so a
    # repeat Set-HostProxy doesn't overwrite the backup with the
    # squid-promoted state.
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
    return Yuruna.Common\Get-HostProxyBackupPath
}

<#
.SYNOPSIS
    Returns true if the host hypervisor is installed and ready.
#>
function Assert-Virtualization {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    # There is no separate framework probe: host enablement runs through
    # Enable-TestAutomation.ps1 -> Set-MacHostConditionSet, not a module
    # function. UTM's presence + Apple Virtualization availability is
    # the practical signal here.
    return [bool](Test-Path '/Applications/UTM.app')
}

# --- REGION: Exports

Export-ModuleMember -Function `
    New-VM, Start-VM, Stop-VM, Stop-VMForce, Remove-VM, Rename-VM, Get-VMState, Get-VMName, `
    Save-VMDiskSnapshot, Restore-VMDiskSnapshot, Test-VMDiskSnapshot, `
    Test-VMConsoleOpen, Restart-VMConsole, `
    Get-Image, Get-ImagePath, `
    Send-Text, Send-Key, Send-Click, Get-VMScreenshot, Get-VMConsoleHandle, `
    Wait-VMIp, Get-VMIp, Get-VMMac, Resolve-UtmGuestIpByMac, `
    Get-ExternalNetwork, New-ExternalNetwork, Test-CacheVMOnExternalNetwork, `
    Add-PortMap, Remove-PortMap, Get-BestHostIp, Get-GuestReachableHostIp, `
    Test-CachingProxyServiceAvailable, Get-CachingProxyServiceVmIp, Get-HostLanPrefix, Test-MacUplinkNotBridgeable, Resolve-UtmNetworkMode, `
    Set-HostProxy, Clear-HostProxy, Remove-HostProxy, Get-HostProxyBackupPath, Assert-Virtualization, `
    `
    Remove-UtmBundleWithRetry, Invoke-EntitledSwift, `
    Start-CachingProxyServiceForwarder, Stop-CachingProxyServiceForwarder, Get-CachingProxyServiceForwarder, Stop-AllCachingProxyServiceForwarder, `
    Test-DownloadAlreadyCurrent, Test-CachingProxyServicePort, Resolve-CacheHostIp, `
    Save-CachedHttpUri, `
    Stop-UtmDialogWatchdog, Start-UtmDialogWatchdog, `
    Confirm-UtmVMCreated, Remove-UtmTestVM, Test-UtmVMRegistered, Remove-UtmVMRegistration, Start-UtmVM, Stop-UtmVM, Confirm-UtmVMStarted, Wait-UtmVMPoweredOff, Restart-UtmConsole, `
    Get-RunningVmName, Test-UtmctlResponsive, Assert-NoConcurrentUtmVm, Resume-YurunaServiceVM, `
    Get-MacProxyMarkerPath, Test-MacProxyIsYurunaManaged, Get-MacActiveNetworkService, Read-MacProxyState, `
    Invoke-MacElevationIfNeeded, Invoke-MacNetworksetup, `
    Set-MacHostProxy, Restore-MacHostProxy, Disable-MacHostProxy, Remove-MacHostProxy, `
    Get-UtmNetworkModeFromBundle, Restore-SudoUserOwnership, `
    Get-VncDisplayForVm, Get-VncPortForVm, Get-VncDisplayFromBundle, Set-VncDisplayInBundle, Test-VncPortFree, Find-FreeVncDisplay, Get-ClaimedVncDisplay, Get-VncScreenshot, Get-UtmScreenshot, Get-UtmWindowScreenshot

# Contract-coverage assertion: warns at load time if the export block
# above drifts away from the canonical Yuruna.Host contract. See
# host/Yuruna.Host.Contract.psm1 for the verb list and rationale.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'Yuruna.Host.Contract.psm1') -Force -DisableNameChecking
$null = Assert-YurunaHostContractCoverage -HostType 'macos.utm' -ExportedFunction @(
    'New-VM','Start-VM','Stop-VM','Stop-VMForce','Remove-VM','Rename-VM','Get-VMState','Get-VMName',
    'Save-VMDiskSnapshot','Restore-VMDiskSnapshot','Test-VMDiskSnapshot',
    'Test-VMConsoleOpen','Restart-VMConsole',
    'Get-Image','Get-ImagePath',
    'Send-Text','Send-Key','Send-Click','Get-VMScreenshot','Get-VMConsoleHandle',
    'Wait-VMIp','Get-VMIp','Get-VMMac',
    'Get-ExternalNetwork','New-ExternalNetwork','Test-CacheVMOnExternalNetwork',
    'Add-PortMap','Remove-PortMap','Get-BestHostIp','Get-GuestReachableHostIp',
    'Test-CachingProxyServiceAvailable','Get-CachingProxyServiceVmIp','Get-HostLanPrefix',
    'Set-HostProxy','Clear-HostProxy','Remove-HostProxy','Get-HostProxyBackupPath','Assert-Virtualization'
)

# Load-time guard for the cache-download wrapper precedence. The image helpers
# (Save-ImageWithChecksum / Save-UbuntuServerImage) feature-detect Save-CachedHttpUri
# BY NAME and invoke it with only -Uri/-OutFile, so this driver's 2-param wrapper
# must win the command-table slot over the shared 3-param
# Yuruna.HostDownload\Save-CachedHttpUri. If an import-order change flips that
# precedence the cache-discovery closure is dropped and downloads silently bypass
# the squid cache (direct, no error) -- surface that regression loudly here.
$__yurunaCacheDownloadCmd = Get-Command -Name Save-CachedHttpUri -ErrorAction SilentlyContinue
if (-not $__yurunaCacheDownloadCmd) {
    Write-Warning "Yuruna.Host (macos.utm): Save-CachedHttpUri is not on the command table after load; image downloads cannot route through the squid cache."
} elseif ($__yurunaCacheDownloadCmd.Parameters.ContainsKey('ResolveCacheHostIp')) {
    Write-Warning "Yuruna.Host (macos.utm): Save-CachedHttpUri resolves to the shared Yuruna.HostDownload implementation (mandatory -ResolveCacheHostIp), not this driver's cache-injecting wrapper; image downloads will silently bypass the squid cache. Check module import order."
}
