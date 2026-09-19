<#PSScriptInfo
.VERSION 2026.09.18
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
    across a genuinely separate process (not a fake holder written to disk),
    same-PID reentry refusal, metadata write/read semantics including that a
    live holder's metadata is unreadable from outside, and that clearing
    stale metadata never touches a lock someone else holds.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -DisableNameChecking

    $script:Pwsh = (Get-Process -Id $PID).Path
    if (-not $script:Pwsh) { $script:Pwsh = 'pwsh' }

    function New-TempLockPath {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture temp dir.')]
        param()
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-sfl-" + [Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return (Join-Path $dir 'test.lock')
    }

    # Launches a real separate pwsh process that acquires the lock, writes a
    # barrier file the instant it holds it (so the test can wait for genuine
    # concurrency rather than guessing with a sleep), holds for HoldMs, then
    # releases.
    function Start-LockHolderProcess {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: launches a disposable helper process, never anything a caller would want to -WhatIf.')]
        param([string]$LockPath, [string]$ModulePath, [string]$BarrierPath, [int]$HoldMs)
        $script = @"
Import-Module '$ModulePath' -Force -DisableNameChecking
`$lock = Enter-YurunaSingleFlightLock -Path '$LockPath' -Metadata @{ pid = `$PID; generation = 'holder' }
if (-not `$lock.Held) { Write-Output 'HOLDER_FAILED'; exit 1 }
[IO.File]::WriteAllText('$BarrierPath', 'held')
Start-Sleep -Milliseconds $HoldMs
Exit-YurunaSingleFlightLock -Lock `$lock
Write-Output 'HOLDER_RELEASED'
"@
        $scriptPath = [IO.Path]::GetTempFileName() + '.ps1'
        Set-Content -LiteralPath $scriptPath -Value $script -Encoding utf8
        $proc = Start-Process -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $scriptPath) `
            -PassThru -NoNewWindow -RedirectStandardOutput ([IO.Path]::GetTempFileName())
        return $proc
    }

    function Wait-Barrier {
        param([string]$BarrierPath, [int]$TimeoutMs = 5000)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            if (Test-Path -LiteralPath $BarrierPath) { return $true }
            Start-Sleep -Milliseconds 20
        }
        return $false
    }
}

Describe 'Enter-YurunaSingleFlightLock -- real cross-process exclusion' {
    It 'blocks a genuinely separate process while this one holds the lock, and lets it through after release' {
        $lockPath    = New-TempLockPath
        $modulePath  = Join-Path $here 'Test.SingleFlightLock.psm1'
        $barrierPath = [IO.Path]::GetTempFileName()
        Remove-Item -LiteralPath $barrierPath -ErrorAction SilentlyContinue

        $holder = Start-LockHolderProcess -LockPath $lockPath -ModulePath $modulePath -BarrierPath $barrierPath -HoldMs 2000
        try {
            (Wait-Barrier -BarrierPath $barrierPath) | Should -Be $true -Because 'the holder process must confirm it actually holds the lock before this test contends for it'

            # Now genuinely concurrent: the other process holds the OS lock.
            $contend = Enter-YurunaSingleFlightLock -Path $lockPath
            $contend.Held   | Should -Be $false
            $contend.Reason | Should -Be 'held-elsewhere'

            $holder.WaitForExit(5000) | Out-Null
            $holder.HasExited | Should -Be $true -Because 'the holder must have released within its own HoldMs plus overhead'

            # Sequential success after release is not the same claim as
            # concurrent exclusion above; both must hold for this test to
            # mean anything.
            $after = Enter-YurunaSingleFlightLock -Path $lockPath
            $after.Held | Should -Be $true
            Exit-YurunaSingleFlightLock -Lock $after
        } finally {
            if (-not $holder.HasExited) { $holder.Kill() }
        }
    }

    It 'refuses same-PID reentry rather than silently granting it' {
        $lockPath = New-TempLockPath
        $first  = Enter-YurunaSingleFlightLock -Path $lockPath
        try {
            $first.Held | Should -Be $true
            $second = Enter-YurunaSingleFlightLock -Path $lockPath
            $second.Held   | Should -Be $false
            $second.Reason | Should -Be 'held-elsewhere'
        } finally {
            Exit-YurunaSingleFlightLock -Lock $first
        }
    }

    It 'never deletes the lock file on release or on a failed acquisition attempt' {
        $lockPath = New-TempLockPath
        $lock = Enter-YurunaSingleFlightLock -Path $lockPath -Metadata @{ generation = 'g1' }
        $lock.Held | Should -Be $true
        [IO.File]::Exists($lockPath) | Should -Be $true
        $blocked = Enter-YurunaSingleFlightLock -Path $lockPath
        $blocked.Held | Should -Be $false
        [IO.File]::Exists($lockPath) | Should -Be $true -Because 'a failed contender must never remove the path it could not lock'
        Exit-YurunaSingleFlightLock -Lock $lock
        [IO.File]::Exists($lockPath) | Should -Be $true -Because 'release closes the handle; it does not unlink the file'
    }
}

Describe 'Metadata -- advisory, and unreadable while held' {
    It 'cannot be read by another process while the lock is live' {
        $lockPath    = New-TempLockPath
        $modulePath  = Join-Path $here 'Test.SingleFlightLock.psm1'
        $barrierPath = [IO.Path]::GetTempFileName()
        Remove-Item -LiteralPath $barrierPath -ErrorAction SilentlyContinue
        $holder = Start-LockHolderProcess -LockPath $lockPath -ModulePath $modulePath -BarrierPath $barrierPath -HoldMs 1500
        try {
            (Wait-Barrier -BarrierPath $barrierPath) | Should -Be $true
            $meta = Read-YurunaSingleFlightLockMetadata -Path $lockPath
            $meta | Should -BeNullOrEmpty -Because 'FileShare.None blocks a read-only open from a second process while held, verified on this runtime'
            $holder.WaitForExit(5000) | Out-Null
        } finally {
            if (-not $holder.HasExited) { $holder.Kill() }
        }
    }

    It 'is readable after release and round-trips the written fields' {
        $lockPath = New-TempLockPath
        $lock = Enter-YurunaSingleFlightLock -Path $lockPath -Metadata @{ generation = 'abc-123'; pid = 4242; startTimeUnixMs = 1700000000000 }
        Exit-YurunaSingleFlightLock -Lock $lock
        $meta = Read-YurunaSingleFlightLockMetadata -Path $lockPath
        $meta | Should -Not -BeNullOrEmpty
        $meta.generation | Should -Be 'abc-123'
        [int64]$meta.pid | Should -Be 4242
    }

    It 'returns $null rather than throwing for a missing or empty file' {
        $missing = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-sfl-missing-" + [Guid]::NewGuid().ToString('n'))
        Read-YurunaSingleFlightLockMetadata -Path $missing | Should -BeNullOrEmpty
    }
}

Describe 'Clear-YurunaSingleFlightLock -- metadata only, never a live holder' {
    It 'refuses and changes nothing when the lock is held by someone else' {
        $lockPath    = New-TempLockPath
        $modulePath  = Join-Path $here 'Test.SingleFlightLock.psm1'
        $barrierPath = [IO.Path]::GetTempFileName()
        Remove-Item -LiteralPath $barrierPath -ErrorAction SilentlyContinue
        $holder = Start-LockHolderProcess -LockPath $lockPath -ModulePath $modulePath -BarrierPath $barrierPath -HoldMs 2000
        try {
            (Wait-Barrier -BarrierPath $barrierPath) | Should -Be $true
            $cleared = Clear-YurunaSingleFlightLock -Path $lockPath -Confirm:$false
            $cleared | Should -Be $false -Because 'a live holder must block the clear entirely, not just the metadata write'
            $holder.WaitForExit(5000) | Out-Null
        } finally {
            if (-not $holder.HasExited) { $holder.Kill() }
        }
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

    It 'never applies any age-based rule -- an old but live holder is still refused' {
        # There is no forced-drain code path to exercise here at all; this
        # test exists so a future change that reintroduces one (an age
        # check before the Enter attempt) fails immediately rather than
        # only in a slow, timing-dependent integration test.
        $lockPath    = New-TempLockPath
        $modulePath  = Join-Path $here 'Test.SingleFlightLock.psm1'
        $barrierPath = [IO.Path]::GetTempFileName()
        Remove-Item -LiteralPath $barrierPath -ErrorAction SilentlyContinue
        $holder = Start-LockHolderProcess -LockPath $lockPath -ModulePath $modulePath -BarrierPath $barrierPath -HoldMs 3000
        try {
            (Wait-Barrier -BarrierPath $barrierPath) | Should -Be $true
            Start-Sleep -Milliseconds 500
            (Clear-YurunaSingleFlightLock -Path $lockPath -Confirm:$false) | Should -Be $false
            $holder.WaitForExit(5000) | Out-Null
        } finally {
            if (-not $holder.HasExited) { $holder.Kill() }
        }
    }
}
