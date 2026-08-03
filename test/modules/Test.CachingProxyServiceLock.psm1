<#PSScriptInfo
.VERSION 2026.08.03
.GUID 424c2b1a-6d93-4e57-b8a0-3c1f9d2e7b64
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna caching-proxy-service lock adopt drain
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
# the stale-holder drain, the self-owned reclaim, the abandoned-age ceiling, the
# hold-profile table, and the adopt-or-rebuild
# decision shape: docs/caching.md#rebuild-adopt-if-healthy-and-the-bring-up-lock

$script:CachingProxyServiceLockFile = 'caching-proxy-service.lock'

# Age past which a recorded lock is ABANDONED rather than slow, so it is drained
# on acquire (and by Clear-CachingProxyServiceLock). Draining takes the lock away
# from whoever recorded it, so the ceiling is set from the rebuild's real worst
# case and then multiplied out:
#   * BOUNDED phases total ~36 min -- host/ubuntu.kvm/guest.caching-proxy-service/
#     New-VM.ps1 waits up to 20 min for the VM's IP and 15 min for squid on :3128;
#     the macOS UTM path in Start-CachingProxyServiceVM.ps1 waits 15 min for
#     MAC/ARP discovery plus ~1 min of register + start retries.
#   * The Step 2 base-image fetch is the only UNBOUNDED phase (~600 MB, and
#     nothing in Yuruna.Image sets a download timeout). 6 h leaves >5 h for it --
#     600 MB at ~250 kbit/s -- which is slower than any link a lab host has.
# So this cannot fire during a legitimate slow rebuild. It is also the LAST
# recovery resort: a self-owned leftover is reclaimed immediately on acquire, and
# Stop-CachingProxyServiceVM.ps1 clears an abandoned lock on demand.
$script:CachingProxyServiceLockMaxAgeSeconds = 21600   # 6 hours

function Get-CachingProxyServiceLockUtcNow {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

function Get-CachingProxyServiceLockPath {
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
    $pidPath = Join-Path $dir $script:CachingProxyServiceLockFile
    return @{ PidPath = $pidPath; StartPath = "$pidPath.start" }
}

function Get-CachingProxyServiceLockHolder {
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
            Write-Verbose "caching-proxy-service lock: could not read StartTime sidecar ($($_.Exception.Message)); trusting PID liveness."
        }
    }
    # No sidecar (or unreadable): trust PID liveness alone.
    return @{ Alive = $true; Pid = $holderPid; Role = $role }
}

function Get-CachingProxyServiceLockAge {
    <#
    .SYNOPSIS
        How long ago the lock was taken, in SECONDS, from the sidecar's
        acquiredAtUtc. Module-private (Enter-/Clear- only), so not exported.
    .OUTPUTS
        [double] seconds, or $null when there is no sidecar / no readable
        stamp -- callers must then treat the age as UNKNOWN and never drain.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)][string]$StartPath)
    if (-not (Test-Path -LiteralPath $StartPath)) { return $null }
    try {
        $rec = Get-Content -Raw -LiteralPath $StartPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $raw = $rec.acquiredAtUtc
        if ($null -eq $raw) { return $null }
        # ConvertFrom-Json auto-coerces the ISO 'Z' stamp we write into a [datetime]
        # of Kind Local (the same coercion the startTimeUnixMs comment above dodges).
        # ToUniversalTime() on that Local value recovers the right instant; a value
        # that stayed a string is parsed as UTC explicitly rather than as local time.
        $acquiredUtc = if ($raw -is [datetime]) {
            ([datetime]$raw).ToUniversalTime()
        } else {
            [datetime]::Parse([string]$raw, [cultureinfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
        }
        return ((Get-Date).ToUniversalTime() - $acquiredUtc).TotalSeconds
    } catch {
        Write-Verbose "caching-proxy-service lock: could not read acquiredAtUtc ($($_.Exception.Message)); age unknown."
        return $null
    }
}

function Enter-CachingProxyServiceLock {
    <#
    .SYNOPSIS
        Acquire the caching-proxy-service lock, draining a stale holder. A live holder is
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
    $paths    = Get-CachingProxyServiceLockPath -RuntimeDir $RuntimeDir
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
            $rec = [ordered]@{ pid = $PID; role = $Role; startTimeUnixMs = ([DateTimeOffset]((Get-Process -Id $PID).StartTime)).ToUnixTimeMilliseconds(); acquiredAtUtc = (Get-CachingProxyServiceLockUtcNow) }
            [System.IO.File]::WriteAllText($startPath, ($rec | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
            $result.Acquired = $true
            return $result
        } catch [System.IO.IOException] {
            $holder = Get-CachingProxyServiceLockHolder -PidPath $pidPath -StartPath $startPath
            if (-not $holder.Alive) {
                # Stale holder (dead / PID reused) -> drain and retry immediately.
                Remove-Item -LiteralPath $pidPath, $startPath -Force -ErrorAction SilentlyContinue
                continue
            }
            if ($holder.Pid -eq $PID) {
                # OUR OWN leftover from an earlier invocation in THIS process -- not a
                # live peer. A .ps1 runs inside the caller's pwsh, so a bring-up that
                # exited without releasing recorded the operator's long-lived
                # interactive shell as the holder; that shell stays alive, so the
                # liveness drain above never fires and every later run is refused.
                # Safe because one pwsh process never holds two bring-up locks at
                # once: the only other caller (Invoke-TestRunnerInnerLoop.ps1's
                # 'portmap' hold) is try/finally-scoped and never starts a bring-up
                # inside its window, and Start-CachingProxyServiceVM.ps1 is never
                # dot-sourced or run as a job. A self-owned lock is therefore stale
                # by definition. Warned (not Verbose): it means an earlier bring-up
                # in this shell died, which the operator should know about.
                Write-Warning "caching-proxy-service lock: reclaiming this process's own leftover lock (PID $PID, role '$($holder.Role)') from an earlier bring-up that exited without releasing it."
                Remove-Item -LiteralPath $pidPath, $startPath -Force -ErrorAction SilentlyContinue
                continue
            }
            $holderAge = Get-CachingProxyServiceLockAge -StartPath $startPath
            if ($null -ne $holderAge -and $holderAge -gt $script:CachingProxyServiceLockMaxAgeSeconds) {
                # Past the ceiling the holder is abandoned, not slow (rationale where
                # the ceiling is defined). This is what a BRAND-NEW terminal hits after
                # a leak: the recorded PID is some other still-live shell, so neither
                # the liveness drain nor the self-owned reclaim applies. An unknown age
                # ($null -- no sidecar, or an unreadable stamp) never drains.
                Write-Warning ("caching-proxy-service lock: draining an abandoned lock -- PID $($holder.Pid) (role '$($holder.Role)') has held it {0:N1} h, past the {1:N1} h ceiling." -f ($holderAge / 3600), ($script:CachingProxyServiceLockMaxAgeSeconds / 3600))
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

function Exit-CachingProxyServiceLock {
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

function Clear-CachingProxyServiceLock {
    <#
    .SYNOPSIS
        Clear a leftover bring-up lock -- the operator reset path behind
        Stop-CachingProxyServiceVM.ps1. Removes a stale (dead / PID-reused),
        self-owned, or over-age abandoned lock. A genuinely live FOREIGN holder
        is REPORTED and left in place, so a reset never steals the lock from a
        real concurrent rebuild in another process.
    .OUTPUTS
        [hashtable] Removed [bool], Reason [string] (no-lock / stale / self /
        abandoned-age / live-foreign), HolderPid [int]. The caller renders the
        verdict in its own output style.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()][string]$RuntimeDir,
        [int]$MaxAgeSeconds = $script:CachingProxyServiceLockMaxAgeSeconds
    )
    $paths = Get-CachingProxyServiceLockPath -RuntimeDir $RuntimeDir
    if (-not (Test-Path -LiteralPath $paths.PidPath)) {
        return @{ Removed = $false; Reason = 'no-lock'; HolderPid = 0 }
    }
    $holder = Get-CachingProxyServiceLockHolder -PidPath $paths.PidPath -StartPath $paths.StartPath
    $age = Get-CachingProxyServiceLockAge -StartPath $paths.StartPath
    $reason =
        if (-not $holder.Alive) { 'stale' }
        elseif ($holder.Pid -eq $PID) { 'self' }
        elseif ($null -ne $age -and $age -gt $MaxAgeSeconds) { 'abandoned-age' }
        else { 'live-foreign' }
    if ($reason -eq 'live-foreign') {
        return @{ Removed = $false; Reason = $reason; HolderPid = $holder.Pid }
    }
    Remove-Item -LiteralPath $paths.PidPath, $paths.StartPath -Force -ErrorAction SilentlyContinue
    return @{ Removed = $true; Reason = $reason; HolderPid = $holder.Pid }
}

function Get-CachingProxyServiceAdoptDecision {
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

function Test-CachingProxyServiceAdoptable {
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
    if (Get-Command Read-CachingProxyServiceState -ErrorAction SilentlyContinue) {
        try { $ip = [string](Read-CachingProxyServiceState).ipAddress } catch { $ip = '' }
    }
    $probeSuccess = $false
    if ($ip -and (Get-Command Invoke-CachingProxyServiceProbe -ErrorAction SilentlyContinue)) {
        try { $probeSuccess = [bool](Invoke-CachingProxyServiceProbe -CacheIp $ip).Success } catch { $probeSuccess = $false }
    }
    return (Get-CachingProxyServiceAdoptDecision -VmState $state -ProbeSuccess $probeSuccess -Ip $ip)
}

Export-ModuleMember -Function `
    Get-CachingProxyServiceLockPath, Get-CachingProxyServiceLockHolder, Enter-CachingProxyServiceLock, `
    Exit-CachingProxyServiceLock, Clear-CachingProxyServiceLock, `
    Get-CachingProxyServiceAdoptDecision, Test-CachingProxyServiceAdoptable
