<#PSScriptInfo
.VERSION 2026.07.31
.GUID 422d9f13-4b78-4c50-9e31-8d0a5c2f7b91
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test caching-proxy-service lock adopt pester
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
    Pester coverage for the caching-proxy-service serialization lock + adopt decision
    (Test.CachingProxyServiceLock.psm1): drain-style acquire/release, live-holder
    fail-fast + bounded wait, stale drain, self-owned reclaim, the abandoned-age
    ceiling, Clear- (the operator reset), idempotent release, and the strict
    adopt-if-healthy decision. Plus an AST guard that Start-CachingProxyServiceVM.ps1
    still releases the lock on every exit path.
.DESCRIPTION
    Throw-based assertions for OS-bundled Pester 3.4 / Pester 5+ compatibility.
    All lock state lives under a per-test temp runtime dir.
    Run with:  Invoke-Pester -Path test/modules/Test.CachingProxyServiceLock.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.CachingProxyServiceLock.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

function New-LockTempDir {
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: creates a throwaway runtime dir the calling It block deletes in its finally.')]
    param()
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-cplk-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

# Sidecar timestamp in the exact format the module writes (acquiredAtUtc).
function Get-UtcStamp {
    [CmdletBinding()]
    [OutputType([string])]
    param([double]$SecondsAgo = 0)
    return (Get-Date).ToUniversalTime().AddSeconds(-$SecondsAgo).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

function Get-ForeignLiveProcess {
    <#
    .SYNOPSIS
        An ALREADY-RUNNING process that is not us, with a StartTime this session
        can read -- the stand-in for "a bring-up in another pwsh".
    .DESCRIPTION
        Nothing is spawned (the rest of this file fakes holders by writing files),
        but the holder classifier reads the real Get-Process StartTime, so a live
        FOREIGN holder cannot be faked with an invented PID. The longest-running
        candidate is picked: it is the least likely to exit between fixture setup
        and the assertion. PIDs whose StartTime is access-denied (Idle/System and
        other protected processes on Windows) are skipped.
    #>
    [CmdletBinding()]
    param()
    $candidates = foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($p.Id -eq $PID) { continue }
        try { $st = $p.StartTime } catch { continue }
        if ($null -eq $st) { continue }
        [pscustomobject]@{ Id = $p.Id; StartTime = $st }
    }
    return @($candidates | Sort-Object StartTime | Select-Object -First 1)[0]
}

function Write-ForeignLockFixture {
    <#
    .SYNOPSIS
        Stage a lock owned by a live, non-us PID. Returns that PID.
    .DESCRIPTION
        Omit -AcquiredAtUtc to stage a lock of UNKNOWN age (no stamp), which the
        age ceiling must never drain on.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [string]$Role = 'rebuild',
        [AllowNull()][string]$AcquiredAtUtc
    )
    $proc = Get-ForeignLiveProcess
    Assert-True ($null -ne $proc) 'a live foreign process is available to stand in for another bring-up'
    $pidPath = Join-Path $RuntimeDir 'caching-proxy-service.lock'
    Set-Content -Path $pidPath -Value ([string]$proc.Id) -NoNewline
    $rec = [ordered]@{ pid = $proc.Id; role = $Role; startTimeUnixMs = ([DateTimeOffset]$proc.StartTime).ToUnixTimeMilliseconds() }
    if ($AcquiredAtUtc) { $rec.acquiredAtUtc = $AcquiredAtUtc }
    $rec | ConvertTo-Json -Compress | Set-Content -Path "$pidPath.start" -NoNewline
    return $proc.Id
}

Describe 'Get-CachingProxyServiceAdoptDecision (strict adopt)' {
    It 'adopts a running VM with a recorded IP and a fully-successful probe' {
        $d = Get-CachingProxyServiceAdoptDecision -VmState 'running' -ProbeSuccess $true -Ip '192.168.7.50'
        Assert-True $d.Adoptable 'running + healthy + ip'
        Assert-Equal -Expected '192.168.7.50' -Actual $d.Ip
    }
    It 'refuses when the VM is not running' {
        $d = Get-CachingProxyServiceAdoptDecision -VmState 'off' -ProbeSuccess $true -Ip '192.168.7.50'
        Assert-Equal -Expected $false -Actual $d.Adoptable
        Assert-True ($d.Reason -like 'vm-not-running*') 'reason names the state'
    }
    It 'refuses when the health probe did not fully succeed (half-wedged proxy rebuilds)' {
        Assert-Equal -Expected $false -Actual (Get-CachingProxyServiceAdoptDecision -VmState 'running' -ProbeSuccess $false -Ip '192.168.7.50').Adoptable
    }
    It 'refuses when there is no recorded IP' {
        $d = Get-CachingProxyServiceAdoptDecision -VmState 'running' -ProbeSuccess $true -Ip ''
        Assert-Equal -Expected $false -Actual $d.Adoptable
        Assert-Equal -Expected 'no-recorded-ip' -Actual $d.Reason
    }
}

Describe 'Enter/Exit-CachingProxyServiceLock (drain-style mutex)' {
    It 'acquires a free lock and releases it' {
        $rd = New-LockTempDir
        try {
            $h = Enter-CachingProxyServiceLock -RuntimeDir $rd -Role 'rebuild' -TimeoutSeconds 0
            Assert-True $h.Acquired 'free lock acquires'
            Assert-True (Test-Path (Join-Path $rd 'caching-proxy-service.lock')) 'lock file created'
            Exit-CachingProxyServiceLock -Handle $h
            Assert-Equal -Expected $false -Actual (Test-Path (Join-Path $rd 'caching-proxy-service.lock')) -Because 'release removes the lock'
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'fail-fasts (try-once) against a live FOREIGN holder and reports its pid/role' {
        # Staged with a real foreign PID, not a second same-process acquire: a
        # self-owned lock is now RECLAIMED as our own leftover (see below), so a
        # same-process fixture no longer exercises mutual exclusion at all.
        $rd = New-LockTempDir
        try {
            $foreignPid = Write-ForeignLockFixture -RuntimeDir $rd -Role 'rebuild' -AcquiredAtUtc (Get-UtcStamp -SecondsAgo 5)
            $h = Enter-CachingProxyServiceLock -RuntimeDir $rd -Role 'portmap' -TimeoutSeconds 0
            Assert-Equal -Expected $false -Actual $h.Acquired -Because 'a live foreign holder blocks a try-once acquire'
            Assert-Equal -Expected $foreignPid -Actual $h.HolderPid -Because 'holder pid surfaced'
            Assert-Equal -Expected 'rebuild' -Actual $h.HolderRole -Because 'holder role surfaced'
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'drains a stale (dead-PID) holder and acquires' {
        $rd = New-LockTempDir
        try {
            $pidPath = Join-Path $rd 'caching-proxy-service.lock'
            Set-Content -Path $pidPath -Value '999999' -NoNewline
            @{ pid = 999999; role = 'rebuild'; startTimeUnixMs = 1 } | ConvertTo-Json -Compress | Set-Content -Path "$pidPath.start" -NoNewline
            $holder = Get-CachingProxyServiceLockHolder -PidPath $pidPath -StartPath "$pidPath.start"
            Assert-Equal -Expected $false -Actual $holder.Alive -Because 'dead pid is not a live holder'
            $h = Enter-CachingProxyServiceLock -RuntimeDir $rd -Role 'rebuild' -TimeoutSeconds 0
            Assert-True $h.Acquired 'stale lock drained + acquired'
            Exit-CachingProxyServiceLock -Handle $h
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'waits out a live FOREIGN holder up to the timeout, then reports not-acquired' {
        $rd = New-LockTempDir
        try {
            $null = Write-ForeignLockFixture -RuntimeDir $rd -Role 'rebuild' -AcquiredAtUtc (Get-UtcStamp -SecondsAgo 5)
            $t0 = [DateTime]::UtcNow
            $hWait = Enter-CachingProxyServiceLock -RuntimeDir $rd -Role 'rebuild' -TimeoutSeconds 2
            $elapsed = ([DateTime]::UtcNow - $t0).TotalSeconds
            Assert-Equal -Expected $false -Actual $hWait.Acquired -Because 'a live foreign holder inside the age ceiling is not reclaimed'
            Assert-True ($elapsed -ge 1.5) "bounded wait honored the timeout (elapsed $([Math]::Round($elapsed,1))s)"
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'reclaims THIS process own leftover lock instead of waiting it out' {
        # The operator-reported bug: a bring-up that exits on one of its error paths
        # without releasing leaves a lock recording the long-lived interactive pwsh
        # it ran inside. That PID never dies, so the stale drain can never fire and
        # every later run in the same shell is refused.
        $rd = New-LockTempDir
        try {
            $h1 = Enter-CachingProxyServiceLock -RuntimeDir $rd -Role 'rebuild' -TimeoutSeconds 0
            Assert-True $h1.Acquired 'first acquire'
            $h2 = Enter-CachingProxyServiceLock -RuntimeDir $rd -Role 'rebuild' -TimeoutSeconds 0 `
                -WarningAction SilentlyContinue -WarningVariable reclaimWarn
            Assert-True $h2.Acquired 'a self-owned leftover is reclaimed, not refused'
            Assert-True (@($reclaimWarn).Count -ge 1) 'the reclaim is warned, not silent'
            Exit-CachingProxyServiceLock -Handle $h2
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'drains a live FOREIGN holder that is past the abandoned-age ceiling' {
        # 7 h, past the 6 h ceiling. The recorded PID is live and is not ours, so
        # neither the stale drain nor the self-owned reclaim applies -- only age does.
        # This is the case a BRAND-NEW terminal hits after a leak in another shell.
        $rd = New-LockTempDir
        try {
            $foreignPid = Write-ForeignLockFixture -RuntimeDir $rd -Role 'rebuild' -AcquiredAtUtc (Get-UtcStamp -SecondsAgo 25200)
            $h = Enter-CachingProxyServiceLock -RuntimeDir $rd -Role 'rebuild' -TimeoutSeconds 0 `
                -WarningAction SilentlyContinue -WarningVariable ageWarn
            Assert-True $h.Acquired "an abandoned lock (recorded PID $foreignPid) is drained"
            Assert-True (@($ageWarn).Count -ge 1) 'the age drain is warned, not silent'
            Exit-CachingProxyServiceLock -Handle $h
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'never drains on an UNKNOWN age (sidecar without acquiredAtUtc)' {
        $rd = New-LockTempDir
        try {
            $foreignPid = Write-ForeignLockFixture -RuntimeDir $rd -Role 'rebuild'
            $h = Enter-CachingProxyServiceLock -RuntimeDir $rd -Role 'rebuild' -TimeoutSeconds 0
            Assert-Equal -Expected $false -Actual $h.Acquired -Because 'an unreadable age must not license a drain'
            Assert-Equal -Expected $foreignPid -Actual $h.HolderPid -Because 'the live foreign holder is still honored'
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'is idempotent on double-release and never removes a lock it does not own' {
        $rd = New-LockTempDir
        try {
            $h = Enter-CachingProxyServiceLock -RuntimeDir $rd -Role 'rebuild' -TimeoutSeconds 0
            Exit-CachingProxyServiceLock -Handle $h
            Exit-CachingProxyServiceLock -Handle $h   # no throw, no-op
            # a lock owned by a DIFFERENT pid is never removed by our handle
            $foreign = Join-Path $rd 'caching-proxy-service.lock'
            Set-Content -Path $foreign -Value '999999' -NoNewline
            Exit-CachingProxyServiceLock -Handle @{ Acquired = $true; PidPath = $foreign; StartPath = "$foreign.start" }
            Assert-True (Test-Path $foreign) 'Exit must not remove a lock owned by another pid (999999 != our pid)'
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
}

Describe 'Clear-CachingProxyServiceLock (the operator reset behind Stop-CachingProxyServiceVM)' {
    It 'reports no-lock when there is nothing to clear' {
        $rd = New-LockTempDir
        try {
            $c = Clear-CachingProxyServiceLock -RuntimeDir $rd
            Assert-Equal -Expected 'no-lock' -Actual $c.Reason
            Assert-Equal -Expected $false -Actual $c.Removed
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'removes a stale (dead-PID) lock' {
        $rd = New-LockTempDir
        try {
            $pidPath = Join-Path $rd 'caching-proxy-service.lock'
            Set-Content -Path $pidPath -Value '999999' -NoNewline
            @{ pid = 999999; role = 'rebuild'; startTimeUnixMs = 1 } | ConvertTo-Json -Compress | Set-Content -Path "$pidPath.start" -NoNewline
            $c = Clear-CachingProxyServiceLock -RuntimeDir $rd
            Assert-Equal -Expected 'stale' -Actual $c.Reason
            Assert-True $c.Removed 'stale lock removed'
            Assert-Equal -Expected $false -Actual (Test-Path $pidPath) -Because 'both lock files are gone'
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'removes THIS process own leftover lock' {
        $rd = New-LockTempDir
        try {
            $h = Enter-CachingProxyServiceLock -RuntimeDir $rd -Role 'rebuild' -TimeoutSeconds 0
            Assert-True $h.Acquired 'staged a self-owned lock'
            $c = Clear-CachingProxyServiceLock -RuntimeDir $rd
            Assert-Equal -Expected 'self' -Actual $c.Reason
            Assert-True $c.Removed 'self-owned lock removed'
            Assert-Equal -Expected $false -Actual (Test-Path (Join-Path $rd 'caching-proxy-service.lock')) -Because 'lock file gone'
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'removes a live FOREIGN lock that is past the age ceiling' {
        $rd = New-LockTempDir
        try {
            $null = Write-ForeignLockFixture -RuntimeDir $rd -Role 'rebuild' -AcquiredAtUtc (Get-UtcStamp -SecondsAgo 25200)
            $c = Clear-CachingProxyServiceLock -RuntimeDir $rd
            Assert-Equal -Expected 'abandoned-age' -Actual $c.Reason
            Assert-True $c.Removed 'abandoned lock removed'
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'refuses to steal a live FOREIGN lock inside the ceiling, and reports its pid' {
        $rd = New-LockTempDir
        try {
            $foreignPid = Write-ForeignLockFixture -RuntimeDir $rd -Role 'rebuild' -AcquiredAtUtc (Get-UtcStamp -SecondsAgo 60)
            $c = Clear-CachingProxyServiceLock -RuntimeDir $rd
            Assert-Equal -Expected 'live-foreign' -Actual $c.Reason
            Assert-Equal -Expected $false -Actual $c.Removed -Because 'a reset must not steal the lock from a real concurrent rebuild'
            Assert-Equal -Expected $foreignPid -Actual $c.HolderPid -Because 'the caller needs the pid to name in its warning'
            Assert-True (Test-Path (Join-Path $rd 'caching-proxy-service.lock')) 'the live holder keeps its lock'
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
}

# Structural (AST) guard on the CALLER side of the lock contract. It lives with the
# lock tests because what it pins is the module's release invariant -- every exit
# path releases -- not Start-CachingProxyServiceVM.ps1's internal shape. AST nodes,
# not a text regex, so a comment describing the guard cannot satisfy it.
Describe 'Start-CachingProxyServiceVM.ps1 releases the lock on every exit path' {
    It 'wraps the critical section in a try whose finally calls Exit-CachingProxyServiceLock' {
        $startCp = Join-Path (Split-Path -Parent $here) 'Start-CachingProxyServiceVM.ps1'
        Assert-True (Test-Path -LiteralPath $startCp) "script exists: $startCp"
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($startCp, [ref]$null, [ref]$errs)
        if ($errs) { throw "Parse errors in $($startCp): $($errs[0].Message)" }

        $enter = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Enter-CachingProxyServiceLock'
        }, $true))
        Assert-Equal -Expected 1 -Actual $enter.Count -Because 'exactly one bring-up acquire'

        $guards = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.TryStatementAst] -and
            $n.Finally -and
            @($n.Finally.FindAll({ param($m)
                $m -is [System.Management.Automation.Language.CommandAst] -and
                $m.GetCommandName() -eq 'Exit-CachingProxyServiceLock'
            }, $true)).Count -gt 0
        }, $true))
        $guard = @($guards | Where-Object { $_.Extent.StartOffset -gt $enter[0].Extent.EndOffset })[0]
        Assert-True ($null -ne $guard) 'a try/finally opening after the acquire releases the lock in its finally'

        # Every `exit` after the acquire must sit inside that try, or the lock leaks.
        # The one exemption is the refusal path (`if (-not $cpLock.Acquired) { ... exit 1 }`):
        # there is no lock to release when the acquire itself failed.
        $refusals = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.IfStatementAst] -and
            $n.Clauses[0].Item1.Extent.Text -match 'cpLock\.Acquired'
        }, $true))
        # Plain loops, not nested Where-Object: an inner pipeline's $_ shadows the
        # outer one, which would silently exempt every exit.
        $leaked = @()
        foreach ($ex in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true))) {
            if ($ex.Extent.StartOffset -le $enter[0].Extent.EndOffset) { continue }
            if ($ex.Extent.StartOffset -ge $guard.Extent.StartOffset -and $ex.Extent.EndOffset -le $guard.Extent.EndOffset) { continue }
            $exempt = $false
            foreach ($r in $refusals) {
                if ($r.Extent.StartOffset -le $ex.Extent.StartOffset -and $r.Extent.EndOffset -ge $ex.Extent.EndOffset) { $exempt = $true }
            }
            if (-not $exempt) { $leaked += $ex }
        }
        Assert-Equal -Expected 0 -Actual $leaked.Count -Because "every exit after the acquire is inside the guarded try; unguarded at line(s) $(($leaked | ForEach-Object { $_.Extent.StartLineNumber }) -join ', ')"
    }
}

Describe 'Get-CachingProxyServiceLockPath' {
    It 'roots the lock under the supplied runtime dir' {
        $p = Get-CachingProxyServiceLockPath -RuntimeDir 'C:\some\runtime'
        Assert-True ($p.PidPath -like '*caching-proxy-service.lock') 'pid path name'
        Assert-Equal -Expected ($p.PidPath + '.start') -Actual $p.StartPath -Because 'start sidecar sits beside the pid file'
    }
}
