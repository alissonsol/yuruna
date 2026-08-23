<#PSScriptInfo
.VERSION 2026.08.23
.GUID 421ff7ed-6fcc-4816-b558-d052d6a39c1a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host address dhcp beacon sidecar
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
    Long-running sidecar that keeps the pool directory's idea of this host's
    address true.

.DESCRIPTION
    Ticks Invoke-HostAddressBeaconTick on a short interval for as long as the
    status service is up: notices an address change, refreshes the host's own
    address records, announces to the aggregator, and nudges the squid log.

    A DETACHED PROCESS rather than a timer inside the status service, for the
    same reason the pool push forwarder is one -- and one more. The status
    service's accept loop blocks indefinitely in HttpListener.GetContext() by
    design (it has no self-exit timer, so it needs no periodic wake-up), so
    there is no tick site inside it. A System.Threading.Timer cannot help
    either: its callback runs on a threadpool thread with no runspace, where a
    PowerShell scriptblock throws (the trap Test.RunnerHeartbeat documents),
    and this work is PowerShell -- HTTP calls and file writes -- not something
    a compiled callback could do. A separate process is the only shape that
    ticks on time without either constraint.

    Bound to the status service's lifetime because that service is what the
    beacon advertises: announcing an address nothing answers on would be
    worse than announcing nothing. It re-announces on start, on change, and on
    a periodic beat, so its own restarts, the collector's restarts, and the
    host renumbering all converge without anyone deciding which happened.

    Single-instance via a PID+start-ticks lock claimed before anything
    expensive runs, the same shape the pool push forwarder uses: a repeated
    status-service start must not stack beacons, and a lock naming a dead
    PID must not wedge the next one out.

.PARAMETER RuntimeDir
    The runtime directory holding host.uuid and ipaddresses.txt. Defaults to
    $env:YURUNA_RUNTIME_DIR.

.PARAMETER CacheAddress
    The caching-proxy machine's address. Defaults to
    $env:YURUNA_CACHING_PROXY_SERVICE_IP. Empty means no pool directory in
    this lab, and the beacon reduces to keeping the local records honest.

.PARAMETER StatusPort
    The port this host's status service listens on.

.PARAMETER IntervalSeconds
    Seconds between ticks. A tick that finds the address unchanged and the
    beacon interval unelapsed does nothing and touches no network, so this is
    cheap to keep short.
#>

param(
    [string]$RuntimeDir   = $env:YURUNA_RUNTIME_DIR,
    [string]$CacheAddress = $env:YURUNA_CACHING_PROXY_SERVICE_IP,
    [int]$StatusPort      = 8080,
    [int]$IntervalSeconds = 15
)

$ErrorActionPreference = 'Continue'
# This process exists to leave a record; its stdout is captured to
# hostaddress.beacon.out. The default SilentlyContinue would discard every
# Write-Information the tick emits.
$InformationPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($RuntimeDir) -or -not (Test-Path -LiteralPath $RuntimeDir)) {
    Write-Verbose 'host address beacon: no runtime directory; exiting.'
    return
}

# --- REGION: Single-instance lock (OS-held exclusive handle)
# --- REGION: https://yuruna.link/test/harness#single-instance-locks
# An OS-HELD exclusive handle, not a parsed PID file: opened FileShare::None and
# kept open for the whole run, so the kernel releases it even on SIGKILL. Taken
# BEFORE the module imports below, which pull in the host driver and take
# seconds -- long enough for two beacons spawned seconds apart to both clear a
# later check. File contents are diagnostics only.
$lockPath = Join-Path $RuntimeDir 'hostaddress.beacon.lock'
$script:LockStream = $null
try {
    $script:LockStream = [System.IO.File]::Open(
        $lockPath, [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
} catch {
    Write-Verbose 'host address beacon: another beacon holds the lock; exiting.'
    return
}
try {
    $script:LockStream.SetLength(0)
    $stamp = [System.Text.Encoding]::UTF8.GetBytes(
        (@{ pid = $PID; startedUtc = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress))
    $script:LockStream.Write($stamp, 0, $stamp.Length)
    $script:LockStream.Flush()
} catch {
    Write-Verbose "host address beacon: could not stamp the lock -- $($_.Exception.Message)"
}

Import-Module (Join-Path $PSScriptRoot 'Test.HostAddressBeacon.psm1') -Force -DisableNameChecking

# The host driver owns "what address does this host answer on" -- it is the
# one question whose answer differs per platform, so it is imported rather
# than reimplemented. Without it there is nothing to beacon.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$hostFolder = ''
try {
    Import-Module (Join-Path $PSScriptRoot 'Test.HostDetection.psm1') -Force -DisableNameChecking
    # -HostType is Mandatory, so calling Get-HostFolder bare does not fail --
    # it PROMPTS, and a prompt in a detached sidecar with no console blocks
    # forever. Resolve the type first and pass it explicitly.
    $detectedType = [string](Get-HostType)
    if (-not [string]::IsNullOrWhiteSpace($detectedType)) {
        # Already repo-relative and prefixed ('host/ubuntu.kvm'), so it is
        # joined to the repo root, not to a 'host' directory.
        $hostFolder = [string](Get-HostFolder -HostType $detectedType)
    }
} catch {
    Write-Verbose "host address beacon: host detection failed -- $($_.Exception.Message)"
}
if ([string]::IsNullOrWhiteSpace($hostFolder)) { return }
$hostDriver = Join-Path $repoRoot $hostFolder | Join-Path -ChildPath 'modules/Yuruna.Host.psm1'
if (-not (Test-Path -LiteralPath $hostDriver)) {
    Write-Verbose "host address beacon: no host driver at '$hostDriver'; exiting."
    return
}
Import-Module $hostDriver -Force

# The status service's PID file is the liveness signal this beacon follows.
# Read once per tick rather than cached: the service can be restarted under a
# running beacon, and the beacon should keep going for the new one rather than
# exit on a PID that changed underneath it.
$serverPidPath = Join-Path $RuntimeDir 'server.pid'
function Test-StatusServiceLive {
    if (-not (Test-Path -LiteralPath $serverPidPath)) { return $false }
    try {
        $svcPid = [int]((Get-Content -Raw -LiteralPath $serverPidPath -ErrorAction Stop).Trim())
        $null = Get-Process -Id $svcPid -ErrorAction Stop
        return $true
    } catch { return $false }
}

try {
    Write-Information "host address beacon: started (interval ${IntervalSeconds}s, directory '$CacheAddress')" -InformationAction Continue
    # A short grace at the top: this process is spawned alongside the status
    # service, so server.pid may not exist yet on the first tick or two, and
    # exiting on that race would leave the pool with no push path at all.
    $grace = 6
    while ($true) {
        if (-not (Test-StatusServiceLive)) {
            if ($grace -le 0) {
                Write-Information 'host address beacon: status service is gone; exiting.' -InformationAction Continue
                break
            }
            $grace--
        } else {
            $grace = 0
        }
        try {
            $current = [string](Get-BestHostIp)
            if ($current) {
                $null = Invoke-HostAddressBeaconTick -RuntimeDir $RuntimeDir -CurrentAddress $current `
                    -CacheAddress $CacheAddress -StatusPort $StatusPort
            }
        } catch {
            # A tick must never end the beacon: the next one may well succeed,
            # and a host with no beacon is a host the pool loses track of.
            Write-Verbose "host address beacon tick: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    # Releasing the handle is what frees the slot. Removing the file is
    # cosmetic -- the next beacon opens it exclusively either way.
    if ($script:LockStream) { $script:LockStream.Dispose(); $script:LockStream = $null }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}
