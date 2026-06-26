<#PSScriptInfo
.VERSION 2026.06.26
.GUID 42d7e6c5-b4a3-4928-8f16-5a4b3c2d1e0f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool storage replication drain
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

# One-shot poolStorage drain, fired DETACHED by the outer loop at each cycle end
# (Test.RunnerOuterLoop.psm1). It drains the backlog of not-yet-replicated cycle
# folders to the optional SMB share (ypool-nas): fail-fast on an unreachable NAS,
# atomic per cycle, single-instance via a lock file. Runs in its own fresh process
# so a slow/absent NAS never delays the cycle loop and module imports start from a
# clean global scope. Env (YURUNA_CONFIG_PATH / YURUNA_RUNTIME_DIR / YURUNA_LOG_DIR)
# is inherited from the spawning runner; HostId is passed in (with a fallback).

[CmdletBinding()]
param([string]$HostId = '')

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $PSCommandPath

# Fresh-process imports: no -Force needed, so the global-module-eviction trap does
# not apply here. The auth extension is loaded via Import-Extension so the
# operator-configured active module is used (not a hardcoded default.psm1).
foreach ($m in @('Test.PoolStorage.psm1', 'Test.StateFile.psm1', 'Test.Config.psm1', 'Test.YurunaDir.psm1', 'Test.HostIdentity.psm1', 'Test.Log.psm1', 'Test.Extension.psm1')) {
    $p = Join-Path $here $m
    if (Test-Path -LiteralPath $p) { Import-Module $p -Global -ErrorAction SilentlyContinue }
}
if (Get-Command Import-Extension -ErrorAction SilentlyContinue) {
    try { $null = Import-Extension -Area 'authentication' -RequireSingle } catch { $null = $_ }
}

$runtimeDir = $env:YURUNA_RUNTIME_DIR
$logDir     = $env:YURUNA_LOG_DIR
if ([string]::IsNullOrWhiteSpace($runtimeDir) -or [string]::IsNullOrWhiteSpace($logDir)) {
    Write-Warning "poolStorage drain: YURUNA_RUNTIME_DIR / YURUNA_LOG_DIR not set; nothing to do."
    return
}

if ([string]::IsNullOrWhiteSpace($HostId) -and (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue)) {
    try { $HostId = [string](Get-YurunaHostId) } catch { $null = $_ }
}
if ([string]::IsNullOrWhiteSpace($HostId)) { $HostId = 'unknown-host' }
if (-not (Test-Path -LiteralPath $runtimeDir)) { New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null }

# --- single-instance lock (pidfile, hardened) ---------------------------------
# Acquisition is ATOMIC via [File]::Open CreateNew (an OS create-if-not-exists),
# not a check-then-write, so two near-simultaneous drains can't both win. The
# lock records PID + the holder's process StartTime; the liveness check requires
# BOTH a live PID AND a matching StartTime, so OS PID reuse after a crash can't
# make a stale lock masquerade as a running drain (which would silently break
# replication forever). Mirrors the runner.pid + runner.start hardening.
function Get-DrainProcStartUtc { param([int]$ProcId) try { return ((Get-Process -Id $ProcId -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')) } catch { return $null } }
function Test-DrainLockHeldLive {
    param([string]$Path)
    try { $j = (Get-Content -Raw -LiteralPath $Path -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
    if (-not $j.pid) { return $false }
    $liveStart = Get-DrainProcStartUtc -ProcId ([int]$j.pid)
    if (-not $liveStart) { return $false }                       # PID not running -> stale
    if ($j.startUtc -and ($liveStart -ne [string]$j.startUtc)) { return $false }  # PID reused -> stale
    return $true
}
function Add-DrainLockFile {
    param([string]$Path, [string]$Body)
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try { $b = [System.Text.Encoding]::UTF8.GetBytes($Body); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
        return $true
    } catch { return $false }   # already exists (or unwritable) -> not acquired
}

$lockPath = Join-Path $runtimeDir 'poolstorage.drain.lock'
$lockBody = (@{ pid = $PID; startUtc = (Get-DrainProcStartUtc -ProcId $PID) } | ConvertTo-Json -Compress)
$haveLock = Add-DrainLockFile -Path $lockPath -Body $lockBody
if (-not $haveLock) {
    if (Test-DrainLockHeldLive -Path $lockPath) {
        Write-Verbose "poolStorage drain: another live drain holds the lock; exiting."
        return
    }
    # Stale lock (dead PID, or PID reused by an unrelated process): reclaim once.
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    $haveLock = Add-DrainLockFile -Path $lockPath -Body $lockBody
    if (-not $haveLock) {
        Write-Verbose "poolStorage drain: lost the stale-lock reclaim race; exiting."
        return
    }
}

try {
    if (Get-Command Invoke-PoolStorageDrain -ErrorAction SilentlyContinue) {
        $summary = Invoke-PoolStorageDrain -HostId $HostId -LogDir $logDir -RuntimeDir $runtimeDir -Confirm:$false
        if ($summary) {
            Write-Information ("poolStorage drain: connectOk=$($summary.connectOk) copied=$($summary.copied) pending=$($summary.pending) error='$($summary.error)'") -InformationAction Continue
        }
    }
} catch {
    Write-Warning "poolStorage drain error (non-fatal): $($_.Exception.Message)"
} finally {
    # Release the lock only if we still own it (so a stale-lock reclaim by another
    # drain can't have us delete its newer lock).
    if ($haveLock -and (Test-Path -LiteralPath $lockPath)) {
        $owner = 0
        try { $owner = [int](((Get-Content -Raw -LiteralPath $lockPath -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop).pid) } catch { $owner = 0 }
        if ($owner -eq $PID) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
    }
}
