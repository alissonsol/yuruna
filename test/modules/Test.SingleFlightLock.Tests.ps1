<#PSScriptInfo
.VERSION 2026.09.30
.GUID 4218d096-eebe-4ef1-9ff3-17d8b1cc9c21
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test lock single-flight host-refresh pester
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
    Test.SingleFlightLock's held-open exclusive lock: real mutual exclusion
    across genuinely separate processes (never a fake holder written to
    disk), on each file system the qualification declares (tmpfs and ext4 on
    Linux, each case named after the one it ran on), with arrival
    synchronized by a barrier so simultaneous attempts are not mistaken for
    sequential ones; bounded waits; a SIGKILLed holder; alias paths; I/O
    failures that must not be retried; OS locking disabled by environment;
    the rank order; ownership validation; passive state observation; and the
    advisory metadata, including that clearing it never touches a lock
    someone else holds.
#>

BeforeDiscovery {
    # Mode bits do not stop root, so the access-denied case cannot fail for
    # it; an identity that cannot be read skips the case too.
    Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))) 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    $script:SkipPermissionCase = $IsWindows
    if (-not $IsWindows) {
        $identity = Get-YurunaCurrentOwnerId
        if (-not $identity.Resolved -or $identity.IsRoot) { $script:SkipPermissionCase = $true }
    }

    # The contention cases are the evidence behind the lock qualification
    # table, so each names the file system it ran on. On Linux the declared
    # ones (tmpfs, ext4) are each sought on a writable candidate directory,
    # and a file system this host does not offer is reported as a skipped
    # case rather than quietly exercised on another one. Elsewhere the temp
    # and repository file systems run under their own names.
    $repoBase = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $tempBase = [IO.Path]::GetTempPath()
    $fileSystemOf = {
        param([string]$Base)
        if ([string]::IsNullOrWhiteSpace($Base) -or -not [IO.Directory]::Exists($Base)) { return $null }
        $probe = Join-Path $Base ('sfl-probe-' + [Guid]::NewGuid().ToString('n') + '.tmp')
        try {
            $null = [IO.Directory]::CreateDirectory($probe)
            [IO.Directory]::Delete($probe)
        } catch { return $null }
        $drive = Get-YurunaPathDriveInfo -Path $Base
        if ($drive.Resolved) { return [string]$drive.FileSystem }
        return $null
    }
    $script:ContentionRoots = [System.Collections.Generic.List[hashtable]]::new()
    if ($IsLinux) {
        $candidates = @{ tmpfs = @($tempBase, '/dev/shm', $env:XDG_RUNTIME_DIR); ext4 = @($repoBase, $tempBase) }
        foreach ($fileSystem in @('tmpfs', 'ext4')) {
            $found = $null
            foreach ($base in $candidates[$fileSystem]) {
                if ((& $fileSystemOf $base) -eq $fileSystem) { $found = $base; break }
            }
            $script:ContentionRoots.Add(@{ FileSystem = $fileSystem; Base = $found; Skip = ($null -eq $found) })
        }
    } else {
        foreach ($base in @($tempBase, $repoBase)) {
            $fileSystem = & $fileSystemOf $base
            $label = if ($fileSystem) { $fileSystem } else { 'unidentified' }
            $script:ContentionRoots.Add(@{ FileSystem = $label; Base = $base; Skip = ($null -eq $fileSystem) })
        }
    }
    $script:SkipDiskFull = -not (Test-Path -LiteralPath '/dev/full')
}

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -DisableNameChecking
    $script:ModulePath = Join-Path $here 'Test.SingleFlightLock.psm1'

    $script:Pwsh = (Get-Process -Id $PID).Path
    if (-not $script:Pwsh) { $script:Pwsh = 'pwsh' }
    $script:TempDirs = [System.Collections.Generic.List[string]]::new()

    # Two roots: the OS temp directory (tmpfs on a typical Linux host) and a
    # directory inside the repository (the disk the checkout and $HOME sit
    # on). The repository one ends in .tmp, which .gitignore excludes.
    function New-TempLockDir {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture temp dir.')]
        param([ValidateSet('tmp', 'repo')][string]$Root = 'tmp', [string]$Base)
        $name = 'sfl-' + [Guid]::NewGuid().ToString('n') + '.tmp'
        if (-not $Base) { $Base = if ($Root -eq 'repo') { $script:RepoRoot } else { [IO.Path]::GetTempPath() } }
        $dir = Join-Path $Base $name
        $null = [IO.Directory]::CreateDirectory($dir)
        $script:TempDirs.Add($dir)
        return $dir
    }

    function New-TempLockPath {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture temp dir.')]
        param([ValidateSet('tmp', 'repo')][string]$Root = 'tmp')
        return (Join-Path (New-TempLockDir -Root $Root) 'test.lock')
    }

    # A child pwsh started with a real argument vector (no command-line
    # re-quoting), inheriting this process's output.
    function Start-TestPwsh {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: launches a disposable helper process.')]
        param([string[]]$ArgumentList)
        $psi = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($a in @('-NoProfile', '-NonInteractive') + $ArgumentList) { $psi.ArgumentList.Add([string]$a) }
        $psi.UseShellExecute = $false
        return [System.Diagnostics.Process]::Start($psi)
    }

    # Kills only a process this suite started, and only while it is still the
    # pwsh it started.
    function Stop-TestProcess {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: stops only a helper process this suite started.')]
        param($Process)
        if ($null -eq $Process) { return }
        try {
            if (-not $Process.HasExited -and $Process.ProcessName -like 'pwsh*') { $Process.Kill() }
        } catch { $null = $_ }
    }

    function Wait-Barrier {
        param([string]$BarrierPath, [int]$TimeoutMs = 30000)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            if ([IO.File]::Exists($BarrierPath)) { return $true }
            Start-Sleep -Milliseconds 20
        }
        return $false
    }

    # Acquires the lock in a separate process, writes BarrierPath the instant
    # it holds it, holds for HoldMs, then releases.
    function Start-LockHolderProcess {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: launches a disposable helper process.')]
        param([string]$LockPath, [string]$BarrierPath, [int]$HoldMs)
        $dir = Split-Path -Parent $BarrierPath
        $holderScript = Join-Path $dir ('holder-' + [Guid]::NewGuid().ToString('n') + '.ps1')
        Set-Content -LiteralPath $holderScript -Encoding utf8 -Value @'
param([string]$ModulePath, [string]$LockPath, [string]$BarrierPath, [int]$HoldMs)
Import-Module $ModulePath -DisableNameChecking
$lock = Enter-YurunaSingleFlightLock -Path $LockPath -Metadata @{ generation = 'holder' }
if (-not $lock.Held) { exit 1 }
[IO.File]::WriteAllText($BarrierPath, 'held')
Start-Sleep -Milliseconds $HoldMs
Exit-YurunaSingleFlightLock -Lock $lock
'@
        return (Start-TestPwsh -ArgumentList @('-File', $holderScript, '-ModulePath', $script:ModulePath,
                '-LockPath', $LockPath, '-BarrierPath', $BarrierPath, '-HoldMs', "$HoldMs"))
    }

    $script:ContenderSource = @'
param(
    [Parameter(Mandatory)][string]$ModulePath,
    [Parameter(Mandatory)][string]$LockPath,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$GoPath,
    [Parameter(Mandatory)][string]$ResultPath,
    [int]$WaitMs = 0,
    [int]$HoldMs = 0
)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -DisableNameChecking
[IO.File]::WriteAllText($ReadyPath, "$PID")
$spin = [Diagnostics.Stopwatch]::StartNew()
while (-not [IO.File]::Exists($GoPath)) {
    if ($spin.ElapsedMilliseconds -gt 60000) { exit 3 }
    Start-Sleep -Milliseconds 2
}
$attemptTick = [Environment]::TickCount64
$lock = Enter-YurunaSingleFlightLock -Path $LockPath -WaitMilliseconds $WaitMs
$returnTick = [Environment]::TickCount64
$releasedTick = $null
if ($lock.Held) {
    Start-Sleep -Milliseconds $HoldMs
    # Taken before the release, so the next holder's acquisition must follow it.
    $releasedTick = [Environment]::TickCount64
    Exit-YurunaSingleFlightLock -Lock $lock
}
$result = [ordered]@{
    pid = $PID; held = [bool]$lock.Held; reason = [string]$lock.Reason; attemptTick = $attemptTick
    returnTick = $returnTick; releasedTick = $releasedTick; waitedMs = $lock.WaitedMs
}
[IO.File]::WriteAllText("$ResultPath.partial", ($result | ConvertTo-Json -Compress))
[IO.File]::Move("$ResultPath.partial", $ResultPath, $true)
'@

    # Starts Count contenders, waits until every one is loaded and spinning on
    # the go barrier, then releases them together. Barriers are plain files:
    # a mkdir barrier is not atomic on every temp file system here.
    function Invoke-LockContention {
        param([string]$Base, [int]$Count, [int]$WaitMs, [int]$HoldMs)
        $dir = New-TempLockDir -Base $Base
        $lockPath = Join-Path $dir 'contended.lock'
        $contender = Join-Path $dir 'contender.ps1'
        Set-Content -LiteralPath $contender -Value $script:ContenderSource -Encoding utf8
        $go = Join-Path $dir 'go.flag'
        $processes = [System.Collections.Generic.List[object]]::new()
        try {
            for ($i = 0; $i -lt $Count; $i++) {
                $processes.Add((Start-TestPwsh -ArgumentList @('-File', $contender, '-ModulePath', $script:ModulePath,
                            '-LockPath', $lockPath, '-ReadyPath', (Join-Path $dir "ready.$i"), '-GoPath', $go,
                            '-ResultPath', (Join-Path $dir "result.$i.json"), '-WaitMs', "$WaitMs", '-HoldMs', "$HoldMs")))
            }
            for ($i = 0; $i -lt $Count; $i++) {
                (Wait-Barrier -BarrierPath (Join-Path $dir "ready.$i") -TimeoutMs 60000) | Should -Be $true
            }
            [IO.File]::WriteAllText($go, 'go')
            foreach ($p in $processes) { $null = $p.WaitForExit(120000) }
            $results = @(for ($i = 0; $i -lt $Count; $i++) {
                    Get-Content -LiteralPath (Join-Path $dir "result.$i.json") -Raw | ConvertFrom-Json
                })
            return [pscustomobject]@{
                Results    = $results
                FileSystem = (Get-YurunaPathDriveInfo -Path $dir).FileSystem
                Directory  = $dir
            }
        } finally {
            foreach ($p in $processes) { Stop-TestProcess $p }
        }
    }

    function Confirm-SimultaneousExclusion {
        param($Outcome, [string]$FileSystem)
        $Outcome.FileSystem | Should -Be $FileSystem -Because 'the case is evidence for the file system it is named after'
        $winners = @($Outcome.Results | Where-Object { $_.held })
        $losers  = @($Outcome.Results | Where-Object { -not $_.held })
        $winners.Count | Should -Be 1 -Because 'exactly one process may hold the lock while the others contend'
        $losers.Count | Should -Be 3
        foreach ($loser in $losers) {
            $loser.reason | Should -Be 'held-elsewhere'
            # Refused while the winner still held the lock: the attempts were
            # simultaneous, not sequential acquisitions after a release.
            [long]$loser.returnTick | Should -BeLessThan ([long]$winners[0].releasedTick)
            [long]$loser.returnTick | Should -BeGreaterOrEqual ([long]$winners[0].attemptTick)
        }
    }

    function Confirm-DisjointHolding {
        param($Outcome, [string]$FileSystem)
        $Outcome.FileSystem | Should -Be $FileSystem -Because 'the case is evidence for the file system it is named after'
        $held = @($Outcome.Results | Where-Object { $_.held } | Sort-Object { [long]$_.returnTick })
        $held.Count | Should -Be 4 -Because 'every waiting contender eventually acquires'
        for ($i = 1; $i -lt $held.Count; $i++) {
            [long]$held[$i].returnTick | Should -BeGreaterOrEqual ([long]$held[$i - 1].releasedTick) -Because 'no two holding intervals may overlap'
        }
    }
}

AfterAll {
    foreach ($dir in $script:TempDirs) {
        try {
            if (-not $IsWindows -and [IO.Directory]::Exists($dir)) {
                [IO.File]::SetUnixFileMode($dir, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
            }
        } catch { $null = $_ }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Enter-YurunaSingleFlightLock -- real cross-process exclusion' {
    It 'blocks a genuinely separate process while this one holds the lock, and lets it through after release' {
        $lockPath    = New-TempLockPath
        $barrierPath = Join-Path (Split-Path -Parent $lockPath) 'held.flag'
        $holder = Start-LockHolderProcess -LockPath $lockPath -BarrierPath $barrierPath -HoldMs 2000
        try {
            (Wait-Barrier -BarrierPath $barrierPath) | Should -Be $true -Because 'the holder process must confirm it actually holds the lock before this test contends for it'

            $contend = Enter-YurunaSingleFlightLock -Path $lockPath
            $contend.Held   | Should -Be $false
            $contend.Reason | Should -Be 'held-elsewhere'

            $holder.WaitForExit(10000) | Out-Null
            $holder.HasExited | Should -Be $true -Because 'the holder must have released within its own HoldMs plus overhead'

            # Sequential success after release is not the same claim as
            # concurrent exclusion above; both must hold for this test to
            # mean anything.
            $after = Enter-YurunaSingleFlightLock -Path $lockPath
            $after.Held | Should -Be $true
            Exit-YurunaSingleFlightLock -Lock $after
        } finally {
            Stop-TestProcess $holder
        }
    }

    It 'refuses same-process reentry with its own reason rather than silently granting it' {
        $lockPath = New-TempLockPath
        $first  = Enter-YurunaSingleFlightLock -Path $lockPath
        try {
            $first.Held | Should -Be $true
            $second = Enter-YurunaSingleFlightLock -Path $lockPath -WaitMilliseconds 2000
            $second.Held   | Should -Be $false
            $second.Reason | Should -Be 'held-by-this-process'
            $second.WaitedMs | Should -BeLessThan 1000 -Because 'a reentry cannot be resolved by waiting for ourselves'
        } finally {
            Exit-YurunaSingleFlightLock -Lock $first
        }
    }

    It 'never deletes the lock file on release or on a failed acquisition attempt' {
        $lockPath    = New-TempLockPath
        $barrierPath = Join-Path (Split-Path -Parent $lockPath) 'held.flag'
        $holder = Start-LockHolderProcess -LockPath $lockPath -BarrierPath $barrierPath -HoldMs 1500
        try {
            (Wait-Barrier -BarrierPath $barrierPath) | Should -Be $true
            $blocked = Enter-YurunaSingleFlightLock -Path $lockPath
            $blocked.Held | Should -Be $false
            [IO.File]::Exists($lockPath) | Should -Be $true -Because 'a failed contender must never remove the path it could not lock'
            $holder.WaitForExit(10000) | Out-Null
        } finally { Stop-TestProcess $holder }
        $lock = Enter-YurunaSingleFlightLock -Path $lockPath
        $lock.Held | Should -Be $true
        Exit-YurunaSingleFlightLock -Lock $lock
        [IO.File]::Exists($lockPath) | Should -Be $true -Because 'release closes the handle; it does not unlink the file'
    }
}

Describe 'Contention -- simultaneous processes on each local file system' {
    foreach ($contentionRoot in $script:ContentionRoots) {
        It "gives exactly one of four simultaneous no-wait contenders the lock on $($contentionRoot.FileSystem)" -Skip:$contentionRoot.Skip -ForEach @($contentionRoot) {
            Confirm-SimultaneousExclusion -FileSystem $FileSystem -Outcome (Invoke-LockContention -Base $Base -Count 4 -WaitMs 0 -HoldMs 1500)
        }

        It "serializes four waiting contenders into disjoint holding intervals on $($contentionRoot.FileSystem)" -Skip:$contentionRoot.Skip -ForEach @($contentionRoot) {
            Confirm-DisjointHolding -FileSystem $FileSystem -Outcome (Invoke-LockContention -Base $Base -Count 4 -WaitMs 15000 -HoldMs 300)
        }
    }

    It 'acquires within a longer wait once the holder releases, and gives up at the end of a shorter one' {
        $lockPath    = New-TempLockPath
        $barrierPath = Join-Path (Split-Path -Parent $lockPath) 'held.flag'
        $holder = Start-LockHolderProcess -LockPath $lockPath -BarrierPath $barrierPath -HoldMs 1500
        try {
            (Wait-Barrier -BarrierPath $barrierPath) | Should -Be $true
            $short = Enter-YurunaSingleFlightLock -Path $lockPath -WaitMilliseconds 300 -PollMilliseconds 20
            $short.Held     | Should -Be $false
            $short.Reason   | Should -Be 'held-elsewhere'
            $short.WaitedMs | Should -BeGreaterOrEqual 300
            $short.WaitedMs | Should -BeLessThan 1000
            $short.Attempts | Should -BeGreaterThan 1

            $long = Enter-YurunaSingleFlightLock -Path $lockPath -WaitMilliseconds 5000 -PollMilliseconds 20
            try {
                $long.Held     | Should -Be $true
                $long.WaitedMs | Should -BeGreaterThan 300
                $long.WaitedMs | Should -BeLessThan 5000
            } finally { Exit-YurunaSingleFlightLock -Lock $long }
        } finally { Stop-TestProcess $holder }
    }

    It 'lets a deadline shorten the wait but never lengthen it' {
        $lockPath    = New-TempLockPath
        $barrierPath = Join-Path (Split-Path -Parent $lockPath) 'held.flag'
        $holder = Start-LockHolderProcess -LockPath $lockPath -BarrierPath $barrierPath -HoldMs 3000
        try {
            (Wait-Barrier -BarrierPath $barrierPath) | Should -Be $true
            $deadline = New-YurunaDeadline -TotalMilliseconds 200
            $shortened = Enter-YurunaSingleFlightLock -Path $lockPath -WaitMilliseconds 10000 -Deadline $deadline
            $shortened.Reason   | Should -Be 'held-elsewhere'
            $shortened.WaitedMs | Should -BeLessThan 1000
            $ample = New-YurunaDeadline -TotalMilliseconds 60000
            $single = Enter-YurunaSingleFlightLock -Path $lockPath -Deadline $ample
            $single.Reason   | Should -Be 'held-elsewhere'
            $single.Attempts | Should -Be 1 -Because 'without a wait a deadline adds no retries'
        } finally { Stop-TestProcess $holder }
    }

    It 'acquires after the holder is killed, without anything unlinking the file' {
        $lockPath    = New-TempLockPath
        $barrierPath = Join-Path (Split-Path -Parent $lockPath) 'held.flag'
        $holder = Start-LockHolderProcess -LockPath $lockPath -BarrierPath $barrierPath -HoldMs 120000
        try {
            (Wait-Barrier -BarrierPath $barrierPath) | Should -Be $true
            (Enter-YurunaSingleFlightLock -Path $lockPath).Reason | Should -Be 'held-elsewhere'
            # SIGKILL: no finally block in the holder runs, only OS handle cleanup.
            $holder.Kill()
            $holder.WaitForExit(10000) | Out-Null
            $lock = Enter-YurunaSingleFlightLock -Path $lockPath -WaitMilliseconds 3000
            try {
                $lock.Held | Should -Be $true
                [IO.File]::Exists($lockPath) | Should -Be $true
            } finally { Exit-YurunaSingleFlightLock -Lock $lock }
        } finally { Stop-TestProcess $holder }
    }

    It 'refuses a contender that reaches the same file through a symlinked directory' -Skip:$IsWindows {
        $dir = New-TempLockDir
        $real = Join-Path $dir 'real'
        $alias = Join-Path $dir 'alias'
        $null = [IO.Directory]::CreateDirectory($real)
        $null = [IO.Directory]::CreateSymbolicLink($alias, $real)
        $barrierPath = Join-Path $dir 'held.flag'
        $holder = Start-LockHolderProcess -LockPath (Join-Path $real 'x.lock') -BarrierPath $barrierPath -HoldMs 2000
        try {
            (Wait-Barrier -BarrierPath $barrierPath) | Should -Be $true
            $viaAlias = Enter-YurunaSingleFlightLock -Path (Join-Path $alias 'x.lock')
            $viaAlias.Held   | Should -Be $false
            $viaAlias.Reason | Should -Be 'held-elsewhere'
        } finally { Stop-TestProcess $holder }
    }
}

Describe 'Failure classification -- a permanent failure returns at once' {
    It 'refuses a lock path that is itself a symlink and leaves the target untouched' -Skip:$IsWindows {
        $dir = New-TempLockDir
        $target = Join-Path $dir 'target.txt'
        [IO.File]::WriteAllText($target, 'untouched')
        $lockPath = Join-Path $dir 'link.lock'
        $null = [IO.File]::CreateSymbolicLink($lockPath, $target)
        $r = Enter-YurunaSingleFlightLock -Path $lockPath -WaitMilliseconds 2000
        $r.Held   | Should -Be $false
        $r.Reason | Should -Be 'reparse-point'
        [IO.File]::ReadAllText($target) | Should -Be 'untouched'
    }

    It 'reports a missing parent at once, creating nothing, even with a wait' {
        $dir = New-TempLockDir
        $missingDir = Join-Path $dir 'missing'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Enter-YurunaSingleFlightLock -Path (Join-Path $missingDir 'x.lock') -WaitMilliseconds 3000
        $sw.Stop()
        $r.Held   | Should -Be $false
        $r.Reason | Should -Be 'parent-missing'
        $r.Attempts | Should -Be 1
        $sw.ElapsedMilliseconds | Should -BeLessThan 1000 -Because 'a missing directory is not contention and must not be waited on'
        [IO.Directory]::Exists($missingDir) | Should -Be $false
    }

    It 'reports access-denied at once for an unwritable directory and for an unwritable lock file' -Skip:$script:SkipPermissionCase {
        $dir = New-TempLockDir
        $lockedDir = Join-Path $dir 'readonly'
        $null = [IO.Directory]::CreateDirectory($lockedDir)
        [IO.File]::SetUnixFileMode($lockedDir, [IO.UnixFileMode]'UserRead, UserExecute')
        try {
            $r = Enter-YurunaSingleFlightLock -Path (Join-Path $lockedDir 'x.lock') -WaitMilliseconds 3000
            $r.Reason   | Should -Be 'access-denied'
            $r.Attempts | Should -Be 1
        } finally {
            [IO.File]::SetUnixFileMode($lockedDir, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        }
        $lockFile = Join-Path $dir 'readonly.lock'
        [IO.File]::WriteAllText($lockFile, '')
        [IO.File]::SetUnixFileMode($lockFile, [IO.UnixFileMode]'UserRead')
        $r = Enter-YurunaSingleFlightLock -Path $lockFile -WaitMilliseconds 3000
        $r.Reason   | Should -Be 'access-denied'
        $r.Attempts | Should -Be 1
    }

    It 'rejects disabled Unix locking while Windows native share exclusion stays effective' {
        $dir = New-TempLockDir
        $probe = Join-Path $dir 'probe.ps1'
        Set-Content -LiteralPath $probe -Encoding utf8 -Value @'
param([string]$ModulePath, [string]$LockPath)
Import-Module $ModulePath -DisableNameChecking
$lock = Enter-YurunaSingleFlightLock -Path $LockPath
Write-Output ('REASON=' + $lock.Reason)
Write-Output ('HELD=' + $lock.Held)
try {
    $other = [IO.File]::Open($LockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $other.Dispose()
    Write-Output 'EXCLUSIVE=False'
} catch [IO.IOException] { Write-Output 'EXCLUSIVE=True' }
Exit-YurunaSingleFlightLock -Lock $lock
'@
        $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -TimeoutSeconds 60 `
            -Environment @{ DOTNET_SYSTEM_IO_DISABLEFILELOCKING = '1' } `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $probe, '-ModulePath', $script:ModulePath, '-LockPath', (Join-Path $dir 'x.lock'))
        $r.ExitCode | Should -Be 0
        $lines = @(Get-BoundedNativeOutputLine -Result $r)
        # This runtime switch affects Unix flock; Windows share modes stay
        # enforced by the kernel even when that environment value is set.
        if ($IsWindows) {
            $lines | Should -Contain 'REASON=acquired'
            $lines | Should -Contain 'HELD=True'
            $lines | Should -Contain 'EXCLUSIVE=True'
        } else {
            $lines | Should -Contain 'REASON=locking-ineffective'
            $lines | Should -Contain 'HELD=False'
            $lines | Should -Contain 'EXCLUSIVE=False'
        }
    }
}

Describe 'Lock order -- ranks refuse the acquisition that could deadlock' {
    It 'refuses a longer-lived lock while a shorter one is held, touching nothing on disk' {
        $dir = New-TempLockDir
        $admission = Enter-YurunaSingleFlightLock -Path (Join-Path $dir 'admission.lock') -Rank (Get-YurunaLockRank Admission)
        try {
            $admission.Held | Should -Be $true
            $lifetimePath = Join-Path $dir 'lifetime.lock'
            $lifetime = Enter-YurunaSingleFlightLock -Path $lifetimePath -Rank (Get-YurunaLockRank HostOperation) -WaitMilliseconds 2000
            $lifetime.Held   | Should -Be $false
            $lifetime.Reason | Should -Be 'lock-order-violation'
            [IO.File]::Exists($lifetimePath) | Should -Be $false
        } finally { Exit-YurunaSingleFlightLock -Lock $admission }
    }

    It 'orders equal-rank service-key locks by path and never allows two short locks together' {
        $dir = New-TempLockDir
        $serviceRank = Get-YurunaLockRank ServiceKey
        $b = Enter-YurunaSingleFlightLock -Path (Join-Path $dir 'service-b.lock') -Rank $serviceRank
        try {
            (Enter-YurunaSingleFlightLock -Path (Join-Path $dir 'service-a.lock') -Rank $serviceRank).Reason | Should -Be 'lock-order-violation'
            $c = Enter-YurunaSingleFlightLock -Path (Join-Path $dir 'service-c.lock') -Rank $serviceRank
            try {
                $c.Reason | Should -Be 'acquired'
                $admission = Enter-YurunaSingleFlightLock -Path (Join-Path $dir 'z-admission.lock') -Rank (Get-YurunaLockRank Admission)
                try {
                    $admission.Reason | Should -Be 'acquired' -Because 'a short lock may follow service-key locks'
                    (Enter-YurunaSingleFlightLock -Path (Join-Path $dir 'zz-gate.lock') -Rank (Get-YurunaLockRank Gate)).Reason |
                        Should -Be 'lock-order-violation' -Because 'two short locks are never held together, whatever their paths'
                } finally { Exit-YurunaSingleFlightLock -Lock $admission }
            } finally { Exit-YurunaSingleFlightLock -Lock $c }
        } finally { Exit-YurunaSingleFlightLock -Lock $b }
    }

    It 'leaves unranked locks outside the order' {
        $dir = New-TempLockDir
        $admission = Enter-YurunaSingleFlightLock -Path (Join-Path $dir 'admission.lock') -Rank (Get-YurunaLockRank Admission)
        try {
            $unranked = Enter-YurunaSingleFlightLock -Path (Join-Path $dir 'aaa.lock')
            try {
                $unranked.Reason | Should -Be 'acquired'
                $unranked.Rank | Should -BeNullOrEmpty
            } finally { Exit-YurunaSingleFlightLock -Lock $unranked }
        } finally { Exit-YurunaSingleFlightLock -Lock $admission }
        $lifetime = Enter-YurunaSingleFlightLock -Path (Join-Path $dir 'lifetime.lock') -Rank (Get-YurunaLockRank HostOperation)
        $lifetime.Reason | Should -Be 'acquired' -Because 'a released lock no longer constrains the order'
        Exit-YurunaSingleFlightLock -Lock $lifetime
    }

    It 'ranks the host-operation lock, then service keys, then the short locks' {
        (Get-YurunaLockRank HostOperation) | Should -Be 100
        (Get-YurunaLockRank ServiceKey)    | Should -Be 200
        (Get-YurunaLockRank Admission)     | Should -Be 300
        (Get-YurunaLockRank CensusMerge)   | Should -Be 300
        (Get-YurunaLockRank Gate)          | Should -Be 300
    }
}

Describe 'Ownership -- a passed lock object is validated, not trusted' {
    It 'forgets a lock whose handle was disposed without Exit' {
        $lockPath = New-TempLockPath
        $lock = Enter-YurunaSingleFlightLock -Path $lockPath
        $lock.Held | Should -Be $true
        $lock.Handle.Dispose()
        $again = Enter-YurunaSingleFlightLock -Path $lockPath
        try { $again.Reason | Should -Be 'acquired' } finally { Exit-YurunaSingleFlightLock -Lock $again }
    }

    It 'confirms ownership only while the lock is held, for its own path' {
        $lockPath = New-TempLockPath
        $lock = Enter-YurunaSingleFlightLock -Path $lockPath
        try {
            (Test-YurunaSingleFlightLockOwned -Lock $lock) | Should -Be $true
            (Test-YurunaSingleFlightLockOwned -Lock $lock -Path $lockPath) | Should -Be $true
            (Test-YurunaSingleFlightLockOwned -Lock $lock -Path (New-TempLockPath)) | Should -Be $false
            $forged = [pscustomobject]@{ Held = $true; Handle = [IO.MemoryStream]::new(); Path = $lockPath }
            (Test-YurunaSingleFlightLockOwned -Lock $forged) | Should -Be $false -Because 'only a handle this runspace registered carries authority'
            (Test-YurunaSingleFlightLockOwned -Lock $null) | Should -Be $false
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
        (Test-YurunaSingleFlightLockOwned -Lock $lock) | Should -Be $false
    }

    It 'stops confirming ownership once the lock path names a different file' -Skip:$IsWindows {
        $lockPath = New-TempLockPath
        $lock = Enter-YurunaSingleFlightLock -Path $lockPath
        try {
            $lock.FileIdentity | Should -Not -BeNullOrEmpty
            $replacement = Join-Path (Split-Path -Parent $lockPath) 'replacement'
            [IO.File]::WriteAllText($replacement, '')
            [IO.File]::Move($replacement, $lockPath, $true)
            (Test-YurunaSingleFlightLockOwned -Lock $lock) | Should -Be $false -Because 'a replaced lock file no longer excludes anyone'
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
    }
}

Describe 'Get-YurunaSingleFlightLockState -- observe without taking' {
    It 'reports held for a lock another process holds' {
        $lockPath    = New-TempLockPath
        $barrierPath = Join-Path (Split-Path -Parent $lockPath) 'held.flag'
        $holder = Start-LockHolderProcess -LockPath $lockPath -BarrierPath $barrierPath -HoldMs 2000
        try {
            (Wait-Barrier -BarrierPath $barrierPath) | Should -Be $true
            $state = Get-YurunaSingleFlightLockState -Path $lockPath
            $state.State         | Should -Be 'held'
            $state.MetadataState | Should -Be 'unread'
            $state.Metadata      | Should -BeNullOrEmpty
        } finally { Stop-TestProcess $holder }
    }

    It 'reports free with the last holder''s metadata, absent without creating the file, and malformed content' {
        $lockPath = New-TempLockPath
        $absent = Get-YurunaSingleFlightLockState -Path $lockPath
        $absent.State | Should -Be 'absent'
        [IO.File]::Exists($lockPath) | Should -Be $false -Because 'an observation never creates the lock file'

        $lock = Enter-YurunaSingleFlightLock -Path $lockPath -Metadata @{ requestId = 'r-7' }
        (Get-YurunaSingleFlightLockState -Path $lockPath).Reason | Should -Be 'held-by-this-process'
        Exit-YurunaSingleFlightLock -Lock $lock
        $free = Get-YurunaSingleFlightLockState -Path $lockPath
        $free.State            | Should -Be 'free'
        $free.MetadataState    | Should -Be 'ok'
        $free.Metadata.requestId | Should -Be 'r-7'

        [IO.File]::WriteAllText($lockPath, '{ not json')
        $malformed = Get-YurunaSingleFlightLockState -Path $lockPath
        $malformed.State         | Should -Be 'free'
        $malformed.MetadataState | Should -Be 'malformed'

        [IO.File]::WriteAllText($lockPath, '')
        (Get-YurunaSingleFlightLockState -Path $lockPath).MetadataState | Should -Be 'empty'
    }
}

Describe 'Metadata -- advisory, and unreadable while held' {
    It 'cannot be read by another process while the lock is live' {
        $lockPath    = New-TempLockPath
        $barrierPath = Join-Path (Split-Path -Parent $lockPath) 'held.flag'
        $holder = Start-LockHolderProcess -LockPath $lockPath -BarrierPath $barrierPath -HoldMs 1500
        try {
            (Wait-Barrier -BarrierPath $barrierPath) | Should -Be $true
            $meta = Read-YurunaSingleFlightLockMetadata -Path $lockPath
            $meta | Should -BeNullOrEmpty -Because 'the holder''s exclusive handle refuses every other open, including a read'
            $holder.WaitForExit(10000) | Out-Null
        } finally { Stop-TestProcess $holder }
    }

    It 'records standard fields the caller cannot override, keeps caller extras and the caller''s generation' {
        $lockPath = New-TempLockPath
        $lock = Enter-YurunaSingleFlightLock -Path $lockPath -Rank (Get-YurunaLockRank Admission) `
            -Metadata @{ generation = 'abc-123'; pid = 4242; startTimeUnixMs = 1; requestId = 'req-1' }
        $lock.Generation      | Should -Be 'abc-123'
        $lock.MetadataWritten | Should -Be $true
        $lock.MetadataReason  | Should -Be 'ok'
        Exit-YurunaSingleFlightLock -Lock $lock
        $meta = Read-YurunaSingleFlightLockMetadata -Path $lockPath
        $meta | Should -Not -BeNullOrEmpty
        $meta.format     | Should -Be 'yuruna.lock-metadata'
        $meta.version    | Should -Be 1
        $meta.generation | Should -Be 'abc-123'
        [long]$meta.pid  | Should -Be $PID -Because 'the lock records the process that holds it, not what the caller claims'
        $meta.startTimeUnixMs | Should -BeOfType [long]
        [long]$meta.startTimeUnixMs | Should -BeGreaterThan 1
        [long]$meta.acquiredUnixMs  | Should -BeGreaterOrEqual ([long]$meta.startTimeUnixMs)
        $meta.hostName   | Should -Be ([Environment]::MachineName)
        $meta.rank       | Should -Be 300
        $meta.requestId  | Should -Be 'req-1'
    }

    It 'generates a generation when the caller gives none' {
        $lockPath = New-TempLockPath
        $lock = Enter-YurunaSingleFlightLock -Path $lockPath
        Exit-YurunaSingleFlightLock -Lock $lock
        $lock.Generation | Should -Match '^[0-9a-f]{32}$'
        (Read-YurunaSingleFlightLockMetadata -Path $lockPath).generation | Should -Be $lock.Generation
    }

    It 'returns $null rather than throwing for a missing or empty file' {
        $missing = Join-Path (New-TempLockDir) 'missing.lock'
        Read-YurunaSingleFlightLockMetadata -Path $missing | Should -BeNullOrEmpty
        [IO.File]::WriteAllText($missing, '')
        Read-YurunaSingleFlightLockMetadata -Path $missing | Should -BeNullOrEmpty
    }
}

Describe 'Clear-YurunaSingleFlightLock -- metadata only, never a live holder' {
    It 'refuses and changes nothing when the lock is held by someone else' {
        $lockPath    = New-TempLockPath
        $barrierPath = Join-Path (Split-Path -Parent $lockPath) 'held.flag'
        $holder = Start-LockHolderProcess -LockPath $lockPath -BarrierPath $barrierPath -HoldMs 2000
        try {
            (Wait-Barrier -BarrierPath $barrierPath) | Should -Be $true
            $cleared = Clear-YurunaSingleFlightLock -Path $lockPath -Confirm:$false
            $cleared | Should -Be $false -Because 'a live holder must block the clear entirely, not just the metadata write'
            $holder.WaitForExit(10000) | Out-Null
        } finally { Stop-TestProcess $holder }
        (Read-YurunaSingleFlightLockMetadata -Path $lockPath).generation | Should -Be 'holder'
    }

    It 'clears metadata once it can itself acquire the now-unheld lock' {
        $lockPath = New-TempLockPath
        $lock = Enter-YurunaSingleFlightLock -Path $lockPath -Metadata @{ generation = 'stale' }
        Exit-YurunaSingleFlightLock -Lock $lock
        (Read-YurunaSingleFlightLockMetadata -Path $lockPath).generation | Should -Be 'stale'

        $cleared = Clear-YurunaSingleFlightLock -Path $lockPath -Confirm:$false
        $cleared | Should -Be $true
        Read-YurunaSingleFlightLockMetadata -Path $lockPath | Should -BeNullOrEmpty

        # The path itself must survive a clear -- only content is touched.
        [IO.File]::Exists($lockPath) | Should -Be $true
        $reacquire = Enter-YurunaSingleFlightLock -Path $lockPath
        $reacquire.Held | Should -Be $true
        Exit-YurunaSingleFlightLock -Lock $reacquire
    }

    It 'changes nothing under -WhatIf' {
        $lockPath = New-TempLockPath
        $lock = Enter-YurunaSingleFlightLock -Path $lockPath -Metadata @{ generation = 'kept' }
        Exit-YurunaSingleFlightLock -Lock $lock
        $before = [IO.File]::ReadAllText($lockPath)
        (Clear-YurunaSingleFlightLock -Path $lockPath -WhatIf) | Should -Be $false
        [IO.File]::ReadAllText($lockPath) | Should -Be $before
    }

    It 'never applies any age-based rule -- an old but live holder is still refused' {
        # There is no forced-drain code path to exercise here at all; this
        # test exists so a change that introduces one (an age check before
        # the Enter attempt) fails immediately rather than only in a slow,
        # timing-dependent integration test.
        $lockPath    = New-TempLockPath
        $barrierPath = Join-Path (Split-Path -Parent $lockPath) 'held.flag'
        $holder = Start-LockHolderProcess -LockPath $lockPath -BarrierPath $barrierPath -HoldMs 3000
        try {
            (Wait-Barrier -BarrierPath $barrierPath) | Should -Be $true
            [IO.File]::SetLastWriteTimeUtc($lockPath, [DateTime]::UtcNow.AddDays(-30))
            (Clear-YurunaSingleFlightLock -Path $lockPath -Confirm:$false) | Should -Be $false
            (Enter-YurunaSingleFlightLock -Path $lockPath).Reason | Should -Be 'held-elsewhere'
            $holder.WaitForExit(10000) | Out-Null
        } finally { Stop-TestProcess $holder }
    }
}

Describe 'Get-YurunaIoFailureKind -- by type and error code, never by message' {
    It 'classifies a real contention and a real missing directory' {
        $lockPath = New-TempLockPath
        $holder = [IO.FileStream]::new($lockPath, 'OpenOrCreate', 'Write', 'None')
        try {
            $caught = $null
            try { $null = [IO.FileStream]::new($lockPath, 'OpenOrCreate', 'Write', 'None') } catch { $caught = $_.Exception }
            (Get-YurunaIoFailureKind -Exception $caught) | Should -Be 'sharing-violation'
        } finally { $holder.Dispose() }

        $caught = $null
        try { $null = [IO.FileStream]::new((Join-Path (New-TempLockDir) 'no/such/dir/x.lock'), 'OpenOrCreate', 'Write', 'None') } catch { $caught = $_.Exception }
        (Get-YurunaIoFailureKind -Exception $caught) | Should -Be 'parent-missing' -Because 'a missing directory is an IOException too, and must not read as contention'
    }

    It 'classifies a real full disk' -Skip:$script:SkipDiskFull {
        # /dev/full fails every write with ENOSPC, the error a full disk gives.
        $caught = $null
        $full = [IO.FileStream]::new('/dev/full', 'Open', 'Write')
        try {
            try { $full.Write([byte[]](1, 2, 3), 0, 3); $full.Flush() } catch { $caught = $_.Exception }
        } finally { try { $full.Dispose() } catch { $null = $_ } }
        $caught | Should -Not -BeNullOrEmpty
        (Get-YurunaIoFailureKind -Exception $caught) | Should -Be 'disk-full'
    }

    It 'maps each platform''s error codes' {
        $cases = @(
            @('linux', 11, 'sharing-violation'), @('linux', 28, 'disk-full'), @('linux', 122, 'disk-full'),
            @('linux', 30, 'read-only'), @('linux', 13, 'access-denied'), @('linux', 1, 'access-denied'),
            @('linux', 20, 'parent-missing'), @('linux', 2, 'not-found'), @('linux', 5, 'io-error'), @('linux', 35, 'io-error'),
            @('macos', 35, 'sharing-violation'), @('macos', 69, 'disk-full'), @('macos', 28, 'disk-full'),
            @('macos', 30, 'read-only'), @('macos', 13, 'access-denied'), @('macos', 11, 'io-error'),
            @('windows', 0x80070020, 'sharing-violation'), @('windows', 0x80070021, 'sharing-violation'),
            @('windows', 0x80070070, 'disk-full'), @('windows', 0x80070027, 'disk-full'),
            @('windows', 0x80070005, 'access-denied'), @('windows', 0x80070013, 'read-only'),
            @('windows', 0x80070003, 'parent-missing'), @('windows', 0x80070002, 'not-found'),
            @('windows', 0x80131620, 'io-error'), @('windows', 11, 'io-error')
        )
        foreach ($case in $cases) {
            $exception = [IO.IOException]::new('any wording', [int]$case[1])
            (Get-YurunaIoFailureKind -Exception $exception -Platform $case[0]) | Should -Be $case[2] -Because "$($case[0]) code $($case[1])"
        }
        (Get-YurunaIoFailureKind -Exception ([UnauthorizedAccessException]::new('x'))) | Should -Be 'access-denied'
        (Get-YurunaIoFailureKind -Exception ([IO.DirectoryNotFoundException]::new('x'))) | Should -Be 'parent-missing'
        (Get-YurunaIoFailureKind -Exception ([IO.FileNotFoundException]::new('x'))) | Should -Be 'not-found'
        (Get-YurunaIoFailureKind -Exception ([InvalidOperationException]::new('sharing violation'))) | Should -Be 'io-error' -Because 'the message text is never consulted'
    }

    It 'unwraps the exception PowerShell wraps around a .NET method call' {
        $inner = [IO.IOException]::new('x', 11)
        $wrapped = [System.Management.Automation.MethodInvocationException]::new('wrapped', $inner)
        (Get-YurunaIoFailureKind -Exception $wrapped -Platform linux) | Should -Be 'sharing-violation'
        $aggregate = [AggregateException]::new([Exception[]]@([IO.DirectoryNotFoundException]::new('x')))
        (Get-YurunaIoFailureKind -Exception $aggregate) | Should -Be 'parent-missing'
    }
}

Describe 'Get-YurunaSingleFlightLockQualification -- exclusion is claimed only where demonstrated' {
    It 'declares Linux ext4 and tmpfs, macOS APFS and Windows NTFS qualified' {
        foreach ($platform in @('linux', 'macos', 'windows')) {
            $q = Get-YurunaSingleFlightLockQualification -Platform $platform
            $q.PlatformQualified | Should -Be $true
            $q.Qualified         | Should -Be $true
            $q.Reason            | Should -Be 'qualified'
        }
    }

    It 'reports the file system that holds a path and qualifies it only when declared' {
        $dir = New-TempLockDir
        $q = Get-YurunaSingleFlightLockQualification -Path (Join-Path $dir 'x.lock')
        $q.FileSystem | Should -Not -BeNullOrEmpty
        $expected = (($q.Platform -eq 'linux') -and (@('ext4', 'tmpfs') -contains $q.FileSystem)) -or
            (($q.Platform -eq 'windows') -and $q.FileSystem -eq 'NTFS') -or
            (($q.Platform -eq 'macos') -and $q.FileSystem -eq 'apfs')
        $q.Qualified | Should -Be $expected
        if (-not $expected) { $q.Reason | Should -Not -Be 'qualified' }
    }
}

Describe 'Dependency closure' {
    It 'works in a fresh process that imports only this module' {
        $dir = New-TempLockDir
        $closure = Join-Path $dir 'closure.ps1'
        Set-Content -LiteralPath $closure -Encoding utf8 -Value @'
param([string]$ModulePath, [string]$LockPath)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -DisableNameChecking
$lock = Enter-YurunaSingleFlightLock -Path $LockPath -WaitMilliseconds 500 -Rank (Get-YurunaLockRank Admission)
if (-not $lock.Held) { Write-Output "ENTER=$($lock.Reason)"; exit 1 }
if (-not (Test-YurunaSingleFlightLockOwned -Lock $lock -Path $LockPath)) { Write-Output 'OWNED=False'; exit 1 }
Exit-YurunaSingleFlightLock -Lock $lock
$state = Get-YurunaSingleFlightLockState -Path $LockPath
if ($state.State -ne 'free') { Write-Output "STATE=$($state.State)"; exit 1 }
Write-Output 'CLOSURE=OK'
exit 0
'@
        $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -TimeoutSeconds 60 `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $closure, '-ModulePath', $script:ModulePath, '-LockPath', (Join-Path $dir 'x.lock'))
        @(Get-BoundedNativeOutputLine -Result $r) | Should -Contain 'CLOSURE=OK'
        $r.ExitCode | Should -Be 0
    }
}
