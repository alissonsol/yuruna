<#PSScriptInfo
.VERSION 2026.07.21
.GUID 424c2b1a-6d93-4e57-b8a0-3c1f9d2e7b64
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna caching-proxy lock adopt drain
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

# Caching-proxy serialization lock + adopt-if-healthy decision.
#
# The lock is a drain-style PID+StartTime mutex so the destructive VM lifecycle
# and the host port-map writes cannot interleave; the two hold profiles
# ('rebuild' and 'portmap') differ only in their acquire timeout. Lock identity,
# the stale-holder drain, the hold-profile table, and the adopt-or-rebuild
# decision shape: docs/caching-proxy.md#rebuild-adopt-if-healthy-and-the-bring-up-lock

$script:CachingProxyLockFile = 'caching-proxy.lock'

function Get-CachingProxyLockUtcNow {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

function Get-CachingProxyLockPath {
    <#
    .SYNOPSIS
        Resolve the lock file + its StartTime sidecar path under the runtime dir.
    .OUTPUTS
        [hashtable] PidPath, StartPath.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][string]$RuntimeDir)
    $dir = if ($RuntimeDir) { $RuntimeDir } elseif ($env:YURUNA_RUNTIME_DIR) { $env:YURUNA_RUNTIME_DIR } else { [System.IO.Path]::GetTempPath() }
    $pidPath = Join-Path $dir $script:CachingProxyLockFile
    return @{ PidPath = $pidPath; StartPath = "$pidPath.start" }
}

function Get-CachingProxyLockHolder {
    <#
    .SYNOPSIS
        Classify the current lock holder: alive (PID exists AND recorded
        StartTime still matches) vs stale (missing/dead/PID-reused).
    .OUTPUTS
        [hashtable] Alive [bool], Pid [int], Role [string].
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$PidPath,
        [Parameter(Mandatory)][string]$StartPath
    )
    if (-not (Test-Path -LiteralPath $PidPath)) { return @{ Alive = $false; Pid = 0; Role = '' } }
    $holderPid = 0
    try { $holderPid = [int]((Get-Content -LiteralPath $PidPath -Raw -ErrorAction Stop).Trim()) } catch { $holderPid = 0 }
    if ($holderPid -le 0) { return @{ Alive = $false; Pid = 0; Role = '' } }
    $proc = Get-Process -Id $holderPid -ErrorAction SilentlyContinue
    if (-not $proc) { return @{ Alive = $false; Pid = $holderPid; Role = '' } }
    $role = ''
    if (Test-Path -LiteralPath $StartPath) {
        try {
            $rec = Get-Content -Raw -LiteralPath $StartPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($rec.role) { $role = [string]$rec.role }
            # StartTime is stored as epoch-ms (a number), NOT an ISO string:
            # ConvertFrom-Json auto-coerces an ISO date string into a [datetime]
            # whose Kind then shifts a re-parse by the local UTC offset (a false
            # >2s mismatch). A number is read back verbatim.
            if ($null -ne $rec.startTimeUnixMs) {
                $recordedMs = [long]$rec.startTimeUnixMs
                $liveMs     = ([DateTimeOffset]($proc.StartTime)).ToUnixTimeMilliseconds()
                # 2s tolerance mirrors Test.SingleInstance: a mismatch means the
                # PID was reused by a different process -> the holder is stale.
                if ([Math]::Abs($recordedMs - $liveMs) -le 2000) {
                    return @{ Alive = $true; Pid = $holderPid; Role = $role }
                }
                return @{ Alive = $false; Pid = $holderPid; Role = $role }
            }
        } catch {
            Write-Verbose "caching-proxy lock: could not read StartTime sidecar ($($_.Exception.Message)); trusting PID liveness."
        }
    }
    # No sidecar (or unreadable): trust PID liveness alone.
    return @{ Alive = $true; Pid = $holderPid; Role = $role }
}

function Enter-CachingProxyLock {
    <#
    .SYNOPSIS
        Acquire the caching-proxy lock, draining a stale holder. A live holder is
        waited out up to -TimeoutSeconds (0 = try once); past that, not acquired.
    .OUTPUTS
        [hashtable] Acquired [bool], HolderPid [int], HolderRole [string],
        PidPath, StartPath, Role.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()][string]$RuntimeDir,
        [ValidateSet('rebuild', 'portmap')][string]$Role = 'rebuild',
        [int]$TimeoutSeconds = 0
    )
    $paths    = Get-CachingProxyLockPath -RuntimeDir $RuntimeDir
    $pidPath  = $paths.PidPath
    $startPath = $paths.StartPath
    $dir = Split-Path -Parent $pidPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } catch { $null = $_ }
    }
    $deadline = (Get-Date).ToUniversalTime().AddSeconds([Math]::Max(0, $TimeoutSeconds))
    $result = @{ Acquired = $false; HolderPid = 0; HolderRole = ''; PidPath = $pidPath; StartPath = $startPath; Role = $Role }
    while ($true) {
        try {
            # Atomic compare-and-set: CreateNew throws if the file exists. Write the
            # PID INTO the create stream (not after) so a concurrent reader never
            # sees an empty file and mistakes our fresh lock for a stale one.
            $fs = [System.IO.File]::Open($pidPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $sw = [System.IO.StreamWriter]::new($fs)
            $sw.Write([string]$PID)
            $sw.Dispose()
            $rec = [ordered]@{ pid = $PID; role = $Role; startTimeUnixMs = ([DateTimeOffset]((Get-Process -Id $PID).StartTime)).ToUnixTimeMilliseconds(); acquiredAtUtc = (Get-CachingProxyLockUtcNow) }
            [System.IO.File]::WriteAllText($startPath, ($rec | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
            $result.Acquired = $true
            return $result
        } catch [System.IO.IOException] {
            $holder = Get-CachingProxyLockHolder -PidPath $pidPath -StartPath $startPath
            if (-not $holder.Alive) {
                # Stale holder (dead / PID reused) -> drain and retry immediately.
                Remove-Item -LiteralPath $pidPath, $startPath -Force -ErrorAction SilentlyContinue
                continue
            }
            $result.HolderPid = $holder.Pid
            $result.HolderRole = $holder.Role
            if ((Get-Date).ToUniversalTime() -ge $deadline) { return $result }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Exit-CachingProxyLock {
    <#
    .SYNOPSIS
        Release the lock, but only if this process still owns it (idempotent, and
        never removes a lock a drain-takeover handed to someone else).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Handle)
    if (-not $Handle -or -not $Handle.Acquired -or -not $Handle.PidPath) { return }
    if (-not (Test-Path -LiteralPath $Handle.PidPath)) { return }
    $ownPid = 0
    try { $ownPid = [int]((Get-Content -LiteralPath $Handle.PidPath -Raw -ErrorAction Stop).Trim()) } catch { $ownPid = 0 }
    if ($ownPid -eq $PID) {
        Remove-Item -LiteralPath $Handle.PidPath, $Handle.StartPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-CachingProxyAdoptDecision {
    <#
    .SYNOPSIS
        Pure adopt decision: adopt only a running VM with a recorded IP whose
        health probe fully succeeded (strict -- a half-wedged proxy rebuilds).
    .OUTPUTS
        [hashtable] Adoptable [bool], Reason [string], Ip [string].
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()][string]$VmState,
        [bool]$ProbeSuccess,
        [AllowNull()][string]$Ip
    )
    if ([string]$VmState -ne 'running') { return @{ Adoptable = $false; Reason = "vm-not-running ($VmState)"; Ip = '' } }
    if ([string]::IsNullOrWhiteSpace($Ip)) { return @{ Adoptable = $false; Reason = 'no-recorded-ip'; Ip = '' } }
    if (-not $ProbeSuccess) { return @{ Adoptable = $false; Reason = 'probe-unhealthy'; Ip = [string]$Ip } }
    return @{ Adoptable = $true; Reason = 'healthy'; Ip = [string]$Ip }
}

function Test-CachingProxyAdoptable {
    <#
    .SYNOPSIS
        I/O wrapper: resolve the proxy VM state + recorded IP + a full health
        probe, then apply the pure adopt decision.
    .OUTPUTS
        [hashtable] Adoptable [bool], Reason [string], Ip [string].
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$VMName)
    $state = if (Get-Command Get-VMState -ErrorAction SilentlyContinue) { [string](Get-VMState -VMName $VMName) } else { 'unknown' }
    $ip = ''
    if (Get-Command Read-CachingProxyState -ErrorAction SilentlyContinue) {
        try { $ip = [string](Read-CachingProxyState).ipAddress } catch { $ip = '' }
    }
    $probeSuccess = $false
    if ($ip -and (Get-Command Invoke-CachingProxyProbe -ErrorAction SilentlyContinue)) {
        try { $probeSuccess = [bool](Invoke-CachingProxyProbe -CacheIp $ip).Success } catch { $probeSuccess = $false }
    }
    return (Get-CachingProxyAdoptDecision -VmState $state -ProbeSuccess $probeSuccess -Ip $ip)
}

Export-ModuleMember -Function `
    Get-CachingProxyLockPath, Get-CachingProxyLockHolder, Enter-CachingProxyLock, `
    Exit-CachingProxyLock, Get-CachingProxyAdoptDecision, Test-CachingProxyAdoptable
