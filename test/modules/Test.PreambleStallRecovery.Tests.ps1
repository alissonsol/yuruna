<#PSScriptInfo
.VERSION 2026.09.24
.GUID 425d1ef1-c9ad-47cc-8b78-45a0c1156135
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner preamble watchdog bounded pester
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
    Guards the recovery path for a cycle that is killed before it runs: bounded
    native calls, and the accounting the outer runner does on behalf of an inner
    that never got to close its own books.
.DESCRIPTION
    A host whose system services stop answering wedges the cycle preamble, and
    the step-heartbeat watchdog ends it with a kill rather than an exit. Three
    behaviors have to hold for that to be survivable and visible:

    Bounded calls. Invoke-BoundedNativeCommand returns instead of waiting, kills
    the tree it started, reports a timeout as exit 124 with TimedOut set, and
    separates "could not be launched" from "ran and said nothing" -- the
    distinction every grant probe maps onto 'unknown' rather than 'denied'.

    Accounting. A killed inner leaves runner.gating.json frozen, so the outer
    advances the crash and failure counters itself -- and must NOT when the
    inner did save, or one failed cycle counts twice and the alert fires at half
    the configured threshold.

    Visibility. status.json keeps describing the last cycle that finished, so a
    faulted runner leaves a green host on the fleet view until the runner state
    is stamped into it; and a stall that repeats in the same phase widens the
    failure pause, because nothing the runner can do from inside its own process
    tree will clear a service wedged outside it.
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.StateFile.psm1')               -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.RunnerOuterLoop.psm1')         -Force -DisableNameChecking

    $script:Pwsh = (Get-Process -Id $PID).Path
    if (-not $script:Pwsh) { $script:Pwsh = 'pwsh' }

    function Initialize-TempRuntimeDir {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-stall-" + [Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }
}

Describe 'Invoke-BoundedNativeCommand' {
    It 'captures output and the exit code of a command that completes' {
        $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh `
            -ArgumentList @('-NoProfile', '-Command', 'Write-Output one; Write-Output two; exit 3') -TimeoutSeconds 60
        $r.Started  | Should -Be $true
        $r.TimedOut | Should -Be $false
        $r.ExitCode | Should -Be 3
        @(Get-BoundedNativeOutputLine -Result $r) | Should -Be @('one', 'two')
    }

    It 'stops a command that outlives its cap and reports 124' {
        $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -TimeoutSeconds 2
        $r.TimedOut | Should -Be $true
        $r.ExitCode | Should -Be 124
    }

    It 'reports a command it could not launch as not started, never as a timeout' {
        $r = Invoke-BoundedNativeCommand -FilePath 'yuruna-no-such-tool-xyz' -TimeoutSeconds 5
        $r.Started  | Should -Be $false
        $r.TimedOut | Should -Be $false
        $r.ExitCode | Should -Be -1
    }

    It 'yields no lines for a timed-out or unlaunched command' {
        # An empty string presented as one line would let a caller's first-element
        # read succeed on a command that answered nothing at all.
        $timedOut = @{ Started = $true; TimedOut = $true; StdOut = 'partial'; StdErr = '' }
        @(Get-BoundedNativeOutputLine -Result $timedOut).Count | Should -Be 0
        $missing  = @{ Started = $false; TimedOut = $false; StdOut = ''; StdErr = '' }
        @(Get-BoundedNativeOutputLine -Result $missing).Count  | Should -Be 0
    }

    It 'keeps interior blank lines and drops only the trailing one' {
        $r = @{ Started = $true; TimedOut = $false; StdOut = "a`n`nb`n"; StdErr = '' }
        @(Get-BoundedNativeOutputLine -Result $r) | Should -Be @('a', '', 'b')
    }

    It 'does not block past its own cap when the immediate child exits but a descendant keeps both pipes open' {
        # The exact bug this primitive was rewritten to fix: a child that
        # backgrounds work and exits itself leaves a descendant holding the
        # inherited pipe, and the old implementation blocked on that
        # descendant's exit regardless of TimeoutSeconds by reading an async
        # task's .Result before confirming, through a bounded wait, that it
        # had actually finished. Reproduced against this exact shape before
        # the fix: a 1-second cap took 6.1 seconds, ExitCode=0, TimedOut=false.
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r  = Invoke-BoundedNativeCommand -FilePath 'bash' -ArgumentList @('-c', 'sleep 6 & exit 0') -TimeoutSeconds 1
        $sw.Stop()
        $sw.ElapsedMilliseconds | Should -BeLessThan 3000 -Because 'the fixed primitive must return close to its own cap, never anywhere near the descendant''s 6-second lifetime'
        $r.TimedOut       | Should -Be $false -Because 'the process this call launched (bash) really did exit inside the cap'
        $r.ExitCode       | Should -Be 0
        $r.DrainTimedOut  | Should -Be $true -Because 'stdout/stderr had not reached EOF when the call returned -- the descendant is still holding them'
    }

    It 'kills the tree and reports 124 for a child that fills both pipes and never exits' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r  = Invoke-BoundedNativeCommand -FilePath 'bash' `
            -ArgumentList @('-c', 'while true; do echo -n "out"; echo -n "err" 1>&2; done') -TimeoutSeconds 2
        $sw.Stop()
        $r.TimedOut | Should -Be $true
        $r.ExitCode | Should -Be 124
        $sw.ElapsedMilliseconds | Should -BeLessThan 10000 -Because 'killing the tree must free both pipes well inside the bounded cleanup allowance'
    }

    It 'caps captured output per stream and keeps draining past the cap instead of blocking the writer' {
        $r = Invoke-BoundedNativeCommand -FilePath 'bash' `
            -ArgumentList @('-c', 'for i in $(seq 1 200000); do printf x; done; echo done') `
            -TimeoutSeconds 10 -MaxCapturedChars 4096
        $r.TimedOut         | Should -Be $false -Because 'the writer must never block on a full pipe once this call stops keeping the extra bytes'
        $r.ExitCode         | Should -Be 0
        $r.OutputTruncated  | Should -Be $true
        $r.StdOut.Length    | Should -Be 4096
    }

    It 'leaves KillFailed false on every path that never needs to kill anything' {
        $completed = Invoke-BoundedNativeCommand -FilePath 'bash' -ArgumentList @('-c', 'exit 0') -TimeoutSeconds 60
        $completed.KillFailed | Should -Be $false
        $missing = Invoke-BoundedNativeCommand -FilePath 'yuruna-no-such-tool-xyz' -TimeoutSeconds 5
        $missing.KillFailed | Should -Be $false
    }
}

Describe 'Get-RunnerStalledPreamblePhase' {
    It 'names the phase when runner.phase survived the inner' {
        $dir = Initialize-TempRuntimeDir
        try {
            Set-Content -LiteralPath (Join-Path $dir 'runner.phase') -Value "config-gate`n" -NoNewline
            Get-RunnerStalledPreamblePhase -RuntimeDir $dir | Should -Be 'config-gate'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports no stall when the inner cleared the phase' {
        $dir = Initialize-TempRuntimeDir
        try {
            Get-RunnerStalledPreamblePhase -RuntimeDir $dir | Should -Be ''
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Update-RunnerCrashGating' {
    It 'advances the counters when the inner was killed before saving them' {
        $dir = Initialize-TempRuntimeDir
        try {
            $gatingFile = Join-Path $dir 'runner.gating.json'
            # The shape a healthy run leaves behind, saved before this cycle began.
            Set-Content -LiteralPath $gatingFile -Value (@{
                    consecutiveFailures  = 0
                    consecutiveSuccesses = 90
                    consecutiveCrashes   = 0
                    alertArmed           = $true
                    savedAt              = '2020-01-01T00:00:00Z'
                } | ConvertTo-Json)

            $result = Update-RunnerCrashGating -RuntimeDir $dir -SpawnedAtUtc ([DateTime]::UtcNow.AddMinutes(-5)) `
                -Config $null -Cycle 42 -ExitCode 137 -StalledPhase 'config-gate' -StallStreak 2 -Confirm:$false

            $result.Updated             | Should -Be $true
            $result.ConsecutiveCrashes  | Should -Be 1
            $result.ConsecutiveFailures | Should -Be 1

            $saved = Get-Content -Raw -LiteralPath $gatingFile | ConvertFrom-Json
            $saved.consecutiveCrashes   | Should -Be 1
            $saved.consecutiveFailures  | Should -Be 1
            # A streak of successes cannot survive a cycle that never ran.
            $saved.consecutiveSuccesses | Should -Be 0
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'leaves the counters alone when the inner saved them during this cycle' {
        $dir = Initialize-TempRuntimeDir
        try {
            $gatingFile = Join-Path $dir 'runner.gating.json'
            $spawnedAt  = [DateTime]::UtcNow.AddMinutes(-5)
            Set-Content -LiteralPath $gatingFile -Value (@{
                    consecutiveFailures  = 4
                    consecutiveSuccesses = 0
                    consecutiveCrashes   = 0
                    alertArmed           = $true
                    savedAt              = [DateTime]::UtcNow.AddMinutes(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                } | ConvertTo-Json)

            $result = Update-RunnerCrashGating -RuntimeDir $dir -SpawnedAtUtc $spawnedAt `
                -Config $null -Cycle 42 -ExitCode 1 -Confirm:$false

            $result.Updated | Should -Be $false
            # Counting the same failed cycle twice would reach failuresBeforeAlert
            # in half the failures the operator asked for.
            $saved = Get-Content -Raw -LiteralPath $gatingFile | ConvertFrom-Json
            $saved.consecutiveFailures | Should -Be 4
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'starts the counters from zero when no gating file exists at all' {
        $dir = Initialize-TempRuntimeDir
        try {
            $result = Update-RunnerCrashGating -RuntimeDir $dir -SpawnedAtUtc ([DateTime]::UtcNow.AddMinutes(-5)) `
                -Config $null -Cycle 1 -ExitCode 137 -Confirm:$false
            $result.ConsecutiveCrashes | Should -Be 1
            (Test-Path -LiteralPath (Join-Path $dir 'runner.gating.json')) | Should -Be $true
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Update-RunnerFaultStatus' {
    It 'stops a faulted host reporting the last completed cycle as a pass' {
        $dir = Initialize-TempRuntimeDir
        try {
            $statusFile = Join-Path $dir 'status.json'
            Set-Content -LiteralPath $statusFile -Value (@{
                    schemaVersion = 1
                    overallStatus = 'pass'
                    cycle         = 1886
                    guests        = @()
                } | ConvertTo-Json)

            Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'paused' `
                -Reason 'failure-pause begin (inner exited 137)' -StalledPhase 'config-gate' -Confirm:$false |
                Should -Be $true

            $doc = Get-Content -Raw -LiteralPath $statusFile | ConvertFrom-Json
            $doc.runnerState        | Should -Be 'paused'
            $doc.runnerStalledPhase | Should -Be 'config-gate'
            # 'fail' and not a new word: it is already in the value set every
            # consumer switches on, so no reader has to learn a state to stop
            # painting this host green.
            $doc.overallStatus      | Should -Be 'fail'
            # The cycle it describes is untouched -- the verdict changed, not the record.
            $doc.cycle              | Should -Be 1886
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'leaves the verdict alone for a state that still produces one' {
        $dir = Initialize-TempRuntimeDir
        try {
            $statusFile = Join-Path $dir 'status.json'
            Set-Content -LiteralPath $statusFile -Value (@{ schemaVersion = 1; overallStatus = 'pass' } | ConvertTo-Json)
            $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'cycle-start' -Confirm:$false
            $doc = Get-Content -Raw -LiteralPath $statusFile | ConvertFrom-Json
            $doc.overallStatus | Should -Be 'pass'
            $doc.runnerState   | Should -Be 'cycle-start'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports no write when there is no status document to amend' {
        $dir = Initialize-TempRuntimeDir
        try {
            Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'fault' -Confirm:$false | Should -Be $false
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-RunnerPreambleStallStreak' {
    It 'counts repeats in the same phase and widens the pause once they escalate' {
        $dir = Initialize-TempRuntimeDir
        try {
            $first  = Get-RunnerPreambleStallStreak -RuntimeDir $dir -StalledPhase 'config-gate' -Confirm:$false
            $first.Streak     | Should -Be 1
            $first.Multiplier | Should -Be 1

            $second = Get-RunnerPreambleStallStreak -RuntimeDir $dir -StalledPhase 'config-gate' -Confirm:$false
            $second.Streak     | Should -Be 2
            $second.Multiplier | Should -Be 1

            # Three in a row is no longer a passing condition: the same service is
            # wedged every time, and the retry cadence is the only thing the runner
            # can change about that.
            $third = Get-RunnerPreambleStallStreak -RuntimeDir $dir -StalledPhase 'config-gate' -Confirm:$false
            $third.Streak     | Should -Be 3
            $third.Multiplier | Should -BeGreaterThan 1
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'restarts the streak when the stall moves to a different phase' {
        $dir = Initialize-TempRuntimeDir
        try {
            $null = Get-RunnerPreambleStallStreak -RuntimeDir $dir -StalledPhase 'host-detect' -Confirm:$false
            $null = Get-RunnerPreambleStallStreak -RuntimeDir $dir -StalledPhase 'host-detect' -Confirm:$false
            $moved = Get-RunnerPreambleStallStreak -RuntimeDir $dir -StalledPhase 'config-gate' -Confirm:$false
            $moved.Streak | Should -Be 1
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'clears the streak when a failure is not a preamble stall' {
        $dir = Initialize-TempRuntimeDir
        try {
            $null = Get-RunnerPreambleStallStreak -RuntimeDir $dir -StalledPhase 'config-gate' -Confirm:$false
            $cleared = Get-RunnerPreambleStallStreak -RuntimeDir $dir -StalledPhase '' -Confirm:$false
            $cleared.Streak     | Should -Be 0
            $cleared.Multiplier | Should -Be 1
            # A later stall must not inherit a widened pause from an unrelated failure.
            $again = Get-RunnerPreambleStallStreak -RuntimeDir $dir -StalledPhase 'config-gate' -Confirm:$false
            $again.Streak | Should -Be 1
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
