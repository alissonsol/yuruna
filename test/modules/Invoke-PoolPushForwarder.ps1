<#PSScriptInfo
.VERSION 2026.07.07
.GUID 424f2c91-6d3b-4e75-9012-3c7a1e5b8d6f
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
# (the operator's push opt-in) + a reachable caching-proxy; a slow/absent aggregator never
# delays the cycle (own fresh process + bounded HttpClient). Pull backfills anything push
# drops. Env (YURUNA_RUNTIME_DIR / YURUNA_LOG_DIR) is inherited; HostId is passed (for logs).

[CmdletBinding()]
param([string]$HostId = '', [string]$CycleFolder = '')

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $PSCommandPath

foreach ($m in @('Test.PoolPush.psm1', 'Test.CachingProxy.psm1', 'Test.YurunaDir.psm1', 'Test.Log.psm1', 'Test.Extension.psm1')) {
    $p = Join-Path $here $m
    if (Test-Path -LiteralPath $p) { Import-Module $p -Global -ErrorAction SilentlyContinue }
}
if (Get-Command Import-Extension -ErrorAction SilentlyContinue) {
    try { $null = Import-Extension -Area 'authentication' -RequireSingle } catch { $null = $_ }
}

$runtimeDir = $env:YURUNA_RUNTIME_DIR
$logDir     = $env:YURUNA_LOG_DIR
if ([string]::IsNullOrWhiteSpace($runtimeDir) -or [string]::IsNullOrWhiteSpace($logDir)) {
    Write-Warning "pool push: YURUNA_RUNTIME_DIR / YURUNA_LOG_DIR not set; nothing to do."
    return
}
if (-not (Test-Path -LiteralPath $runtimeDir)) { New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null }

# --- Push opt-in gate: the shared bearer token. Resolve ONLY when the operator declared a
# vaultKey for 'pool-auth-token' AND populated it (Test-VaultEntry); an empty vaultKey means
# push is DISABLED, and calling Get-Password then would auto-generate a junk per-host token.
$token = ''
try {
    if ((Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue) -and (Get-Command Test-VaultEntry -ErrorAction SilentlyContinue)) {
        $eff = Get-EffectiveUser -LogicalUser 'pool-auth-token'
        if ($eff.vaultKey -and (Test-VaultEntry -VaultKey $eff.vaultKey)) {
            $token = [string](Get-Password -Username 'pool-auth-token')
        }
    }
} catch { $null = $_ }
if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Verbose "pool push: no pool-auth-token configured; push disabled."
    return
}

# --- REGION: caching-proxy (aggregator) address
$proxyIp = ''
if (Get-Command Read-CachingProxyState -ErrorAction SilentlyContinue) {
    try { $st = Read-CachingProxyState; if ($st -and $st.ipAddress) { $proxyIp = [string]$st.ipAddress } } catch { $null = $_ }
}
if ([string]::IsNullOrWhiteSpace($proxyIp) -and $env:YURUNA_CACHING_PROXY_IP) { $proxyIp = $env:YURUNA_CACHING_PROXY_IP.Trim() }
if ([string]::IsNullOrWhiteSpace($proxyIp)) {
    Write-Verbose "pool push: no caching-proxy IP; cannot reach the aggregator."
    return
}

# --- REGION: resolve the cycle folder to push (explicit, else the newest with an events file)
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

# --- REGION: single-instance lock (atomic CreateNew; reclaim a stale lock once)
function Get-PushProcStartUtc { param([int]$ProcId) try { return ((Get-Process -Id $ProcId -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')) } catch { return $null } }
function Test-PushLockHeldLive {
    param([string]$Path)
    try { $j = (Get-Content -Raw -LiteralPath $Path -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
    if (-not $j.pid) { return $false }
    $liveStart = Get-PushProcStartUtc -ProcId ([int]$j.pid)
    if (-not $liveStart) { return $false }
    # No recorded startUtc -> the PID's identity can't be verified, so a reused PID could
    # masquerade as the holder; treat as stale (reclaimable) rather than held.
    if (-not $j.startUtc) { return $false }
    if ($liveStart -ne [string]$j.startUtc) { return $false }
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
$lockBody = (@{ pid = $PID; startUtc = (Get-PushProcStartUtc -ProcId $PID) } | ConvertTo-Json -Compress)
$haveLock = Add-PushLockFile -Path $lockPath -Body $lockBody
if (-not $haveLock) {
    if (Test-PushLockHeldLive -Path $lockPath) { Write-Verbose "pool push: another live forwarder holds the lock; exiting."; return }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    $haveLock = Add-PushLockFile -Path $lockPath -Body $lockBody
    if (-not $haveLock) { Write-Verbose "pool push: lost the stale-lock reclaim race; exiting."; return }
}

if ([string]::IsNullOrWhiteSpace($HostId) -and (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue)) {
    try { $HostId = [string](Get-YurunaHostId) } catch { $null = $_ }
}

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
