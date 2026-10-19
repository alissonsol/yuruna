<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 421654e8-21f9-45e4-9613-5c67d4e4290f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool push forwarder ingest
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

# One-shot pool push forwarder, fired DETACHED by the outer loop at each cycle end
# (Test.RunnerOuterLoop.psm1). It ships the latest cycle's cycle.events.ndjson to the
# aggregator's POST /ingest over CA-pinned HTTPS with the internal authentication key, closing the
# trailing-event gap between 30s pulls. Best-effort: gated on the token being configured
# (the operator's push opt-in) + a reachable caching-proxy-service; a slow/absent aggregator never
# delays the cycle (own fresh process + bounded HttpClient). Pull backfills anything push
# drops. Env (YURUNA_RUNTIME_DIR / YURUNA_LOG_DIR) is inherited; HostId is passed (for logs).

[CmdletBinding()]
param([string]$HostId = '', [string]$CycleFolder = '')

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $PSCommandPath

# --- REGION: Fresh-process module imports
foreach ($m in @('Test.PoolPush.psm1', 'Test.CachingProxyService.psm1', 'Test.YurunaDir.psm1', 'Test.Log.psm1', 'Test.Extension.psm1')) {
    $p = Join-Path $here $m
    if (Test-Path -LiteralPath $p) { Import-Module $p -Global -ErrorAction SilentlyContinue }
}
if (Get-Command Import-Extension -ErrorAction SilentlyContinue) {
    try { $null = Import-Extension -Area 'authentication' -RequireSingle } catch { $null = $_ }
}

# --- REGION: Runtime + log dir gate
$runtimeDir = $env:YURUNA_RUNTIME_DIR
$logDir     = $env:YURUNA_LOG_DIR
if ([string]::IsNullOrWhiteSpace($runtimeDir) -or [string]::IsNullOrWhiteSpace($logDir)) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_1fe1d584f0290ac2')
    return
}
if (-not (Test-Path -LiteralPath $runtimeDir)) { New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null }

# --- REGION: Push opt-in gate (internal authentication key)
# Resolve ONLY when a vaultKey is declared for the logical user AND populated
# (Test-VaultEntry); an empty vaultKey means push is DISABLED, and calling
# Get-Password then would auto-generate a junk per-host token. 'internal-auth-key'
# first, then the legacy 'lab-auth-token' and 'pool-auth-token' names, so a host
# enrolled under an older one keeps pushing (same order as Get-InternalAuthKeyValue,
# inlined because Test.ConfigServiceSync is not among this forwarder's imports).
$token = ''
try {
    if ((Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue) -and (Get-Command Test-VaultEntry -ErrorAction SilentlyContinue)) {
        foreach ($logical in @('internal-auth-key', 'lab-auth-token', 'pool-auth-token')) {
            $eff = Get-EffectiveUser -LogicalUser $logical
            if ($eff.vaultKey -and (Test-VaultEntry -VaultKey $eff.vaultKey)) {
                $token = [string](Get-Password -Username $logical)
                break
            }
        }
    }
} catch { $null = $_ }
if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Verbose "pool push: no internal authentication key configured; push disabled."
    return
}

# --- REGION: Caching-proxy-service (aggregator) address
$proxyIp = ''
try {
    $base = Get-PoolAggregatorServiceSeedUrl -WhatIf:$false
    if ($base) { $proxyIp = ([uri]$base).Host }
} catch { Write-Verbose "pool push: aggregator discovery failed: $($_.Exception.Message)" }
if ([string]::IsNullOrWhiteSpace($proxyIp)) {
    Write-Verbose "pool push: no caching-proxy-service IP; cannot reach the aggregator."
    return
}

# --- REGION: Resolve the cycle folder to push (explicit, else the newest with an events file)
if ([string]::IsNullOrWhiteSpace($CycleFolder) -or -not (Test-Path -LiteralPath (Join-Path $CycleFolder 'cycle.events.ndjson'))) {
    $CycleFolder = ''
    try {
        $newest = Get-ChildItem -LiteralPath $logDir -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { $f = Join-Path $_.FullName 'cycle.events.ndjson'; if (Test-Path -LiteralPath $f) { [pscustomobject]@{ Dir = $_.FullName; Mtime = (Get-Item -LiteralPath $f).LastWriteTimeUtc } } } |
            Sort-Object Mtime -Descending | Select-Object -First 1
        if ($newest) { $CycleFolder = $newest.Dir }
    } catch { $null = $_ }
}
if ([string]::IsNullOrWhiteSpace($CycleFolder)) {
    Write-Verbose "pool push: no cycle with an events file found; nothing to push."
    return
}

# --- REGION: Single-instance lock
# See https://yuruna.link/42d38664-001e
# Yuruna.Common's PID-file lock: one creator, a holder known by its PID and
# start time, and a stale lock reclaimed once without taking a live one.
$lockPath = Join-Path $runtimeDir 'poolpush.forwarder.lock'
$haveLock = Enter-YurunaPidFileLock -Path $lockPath
if (-not $haveLock) { Write-Verbose "pool push: another live forwarder holds the lock; exiting."; return }

# --- REGION: Host identity
if ([string]::IsNullOrWhiteSpace($HostId) -and (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue)) {
    try { $HostId = [string](Get-YurunaHostId) } catch { $null = $_ }
}

# --- REGION: Run the worker
try {
    if (Get-Command Invoke-PoolEventPush -ErrorAction SilentlyContinue) {
        $summary = Invoke-PoolEventPush -CycleFolder $CycleFolder -ProxyIp $proxyIp -Token $token -RuntimeDir $runtimeDir
        if ($summary) {
            Write-Information ((Format-YurunaOperatorMessage -Key 'runner.operator_7782e9a6cf3f4795' -Arguments @{ sent = "$($summary.sent)"; batches = "$($summary.batches)"; lastStatus = "$($summary.lastStatus)"; reason = "$($summary.reason)" })) -InformationAction Continue
        }
    }
} catch {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_9597c2fd2b52e11e' -Arguments @{ message = "$($_.Exception.Message)" })
} finally {
    if ($haveLock) { $null = Exit-YurunaPidFileLock -Path $lockPath }
}
