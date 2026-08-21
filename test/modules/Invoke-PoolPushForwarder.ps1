<#PSScriptInfo
.VERSION 2026.08.21
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
# aggregator's POST /ingest over CA-pinned HTTPS with the shared bearer token, closing the
# trailing-event gap between 30s pulls. Best-effort: gated on the token being configured
# (the operator's push opt-in) + a reachable caching-proxy-service; a slow/absent aggregator never
# delays the cycle (own fresh process + bounded HttpClient). Pull backfills anything push
# drops. Env (YURUNA_RUNTIME_DIR / YURUNA_LOG_DIR) is inherited; HostId is passed (for logs).

[CmdletBinding()]
param([string]$HostId = '', [string]$CycleFolder = '')

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
    Write-Warning "pool push: YURUNA_RUNTIME_DIR / YURUNA_LOG_DIR not set; nothing to do."
    return
}
if (-not (Test-Path -LiteralPath $runtimeDir)) { New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null }

# --- REGION: Push opt-in gate (shared bearer token)
# Resolve ONLY when a vaultKey is declared for the logical user AND populated
# (Test-VaultEntry); an empty vaultKey means push is DISABLED, and calling
# Get-Password then would auto-generate a junk per-host token. 'lab-auth-token'
# first, then the legacy 'pool-auth-token' name, so a host enrolled under the
# old logical user keeps pushing (same fallback order as Get-LabAuthTokenValue,
# inlined because Test.ConfigServiceSync is not among this forwarder's imports).
$token = ''
try {
    if ((Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue) -and (Get-Command Test-VaultEntry -ErrorAction SilentlyContinue)) {
        foreach ($logical in @('lab-auth-token', 'pool-auth-token')) {
            $eff = Get-EffectiveUser -LogicalUser $logical
            if ($eff.vaultKey -and (Test-VaultEntry -VaultKey $eff.vaultKey)) {
                $token = [string](Get-Password -Username $logical)
                break
            }
        }
    }
} catch { $null = $_ }
if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Verbose "pool push: no lab-auth-token configured; push disabled."
    return
}

# --- REGION: Caching-proxy-service (aggregator) address
$proxyIp = ''
if (Get-Command Read-CachingProxyServiceState -ErrorAction SilentlyContinue) {
    try { $st = Read-CachingProxyServiceState; if ($st -and $st.ipAddress) { $proxyIp = [string]$st.ipAddress } } catch { $null = $_ }
}
if ([string]::IsNullOrWhiteSpace($proxyIp) -and $env:YURUNA_CACHING_PROXY_SERVICE_IP) { $proxyIp = $env:YURUNA_CACHING_PROXY_SERVICE_IP.Trim() }
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

# --- REGION: Single-instance lock (atomic CreateNew; reclaim a stale lock once)
# --- REGION: https://yuruna.link/test/harness#single-instance-locks
# Ticks, not a formatted timestamp: a JSON ISO-8601 field round-trips as a
# [datetime] whose string form is locale-formatted, so every live lock would
# read as stale.
function Get-PushProcStartUtc { param([int]$ProcId) try { return ((Get-Process -Id $ProcId -ErrorAction Stop).StartTime.ToUniversalTime().Ticks) } catch { return $null } }
function Test-PushLockHeldLive {
    param([string]$Path)
    try { $j = (Get-Content -Raw -LiteralPath $Path -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
    if (-not $j.pid) { return $false }
    $liveStart = Get-PushProcStartUtc -ProcId ([int]$j.pid)
    if (-not $liveStart) { return $false }
    # No recorded start time -> the PID's identity can't be verified, so a reused PID could
    # masquerade as the holder; treat as stale (reclaimable) rather than held.
    if (-not $j.startTicks) { return $false }
    if ([long]$liveStart -ne [long]$j.startTicks) { return $false }
    return $true
}
function Add-PushLockFile {
    param([string]$Path, [string]$Body)
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try { $b = [System.Text.Encoding]::UTF8.GetBytes($Body); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
        return $true
    } catch { return $false }
}

$lockPath = Join-Path $runtimeDir 'poolpush.forwarder.lock'
$lockBody = (@{ pid = $PID; startTicks = (Get-PushProcStartUtc -ProcId $PID) } | ConvertTo-Json -Compress)
$haveLock = Add-PushLockFile -Path $lockPath -Body $lockBody
if (-not $haveLock) {
    if (Test-PushLockHeldLive -Path $lockPath) { Write-Verbose "pool push: another live forwarder holds the lock; exiting."; return }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    $haveLock = Add-PushLockFile -Path $lockPath -Body $lockBody
    if (-not $haveLock) { Write-Verbose "pool push: lost the stale-lock reclaim race; exiting."; return }
}

# --- REGION: Host identity
if ([string]::IsNullOrWhiteSpace($HostId) -and (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue)) {
    try { $HostId = [string](Get-YurunaHostId) } catch { $null = $_ }
}

# --- REGION: Run the worker
try {
    if (Get-Command Invoke-PoolEventPush -ErrorAction SilentlyContinue) {
        $summary = Invoke-PoolEventPush -CycleFolder $CycleFolder -ProxyIp $proxyIp -Token $token -RuntimeDir $runtimeDir
        if ($summary) {
            Write-Information ("pool push: sent=$($summary.sent) batches=$($summary.batches) lastStatus=$($summary.lastStatus) reason='$($summary.reason)'") -InformationAction Continue
        }
    }
} catch {
    Write-Warning "pool push error (non-fatal): $($_.Exception.Message)"
} finally {
    if ($haveLock -and (Test-Path -LiteralPath $lockPath)) {
        $owner = 0
        try { $owner = [int](((Get-Content -Raw -LiteralPath $lockPath -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop).pid) } catch { $owner = 0 }
        if ($owner -eq $PID) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
    }
}
