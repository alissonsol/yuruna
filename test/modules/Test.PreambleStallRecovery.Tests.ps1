<#PSScriptInfo
.VERSION 2026.09.30
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
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
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
        # A descendant that inherits the pipes outlives its parent: the child
        # exits at once, but stdout/stderr stay open for the descendant's whole
        # lifetime. Reading an unfinished read task's result would block for
        # that lifetime; the call must instead end at its cap and say the
        # drain was cut short.
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r  = Invoke-BoundedNativeCommand -FilePath 'bash' -ArgumentList @('-c', 'sleep 6 & exit 0') -TimeoutSeconds 1
        $sw.Stop()
        $sw.ElapsedMilliseconds | Should -BeLessThan 1750 -Because 'the call must return close to its own cap, never anywhere near the descendant''s 6-second lifetime'
        $r.TimedOut       | Should -Be $false -Because 'the process this call launched (bash) really did exit inside the cap'
        $r.ExitCode       | Should -Be 0
        $r.DrainTimedOut  | Should -Be $true -Because 'stdout/stderr had not reached EOF when the call returned -- the descendant is still holding them'
        (Test-BoundedNativeResultComplete -Result $r) | Should -Be $false
    }

    It 'kills the tree and reports 124 for a child that fills both pipes and never exits' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r  = Invoke-BoundedNativeCommand -FilePath 'bash' `
            -ArgumentList @('-c', 'while true; do echo -n "out"; echo -n "err" 1>&2; done') -TimeoutSeconds 2
        $sw.Stop()
        $r.TimedOut | Should -Be $true
        $r.ExitCode | Should -Be 124
        $r.KillFailed | Should -Be $false
        $sw.ElapsedMilliseconds | Should -BeLessThan 2750 -Because 'the kill and the last drain happen inside the cap, not after it'
    }

    It 'confirms the kill of a child that outlived even a one-second cap' {
        # Kill($true) walks the whole process table to find descendants. A
        # cleanup reserve shorter than that walk reports a child it did kill
        # as a failed kill and returns after the cap.
        $r = Invoke-BoundedNativeCommand -FilePath 'sleep' -ArgumentList @('60') -TimeoutSeconds 1
        $r.TimedOut   | Should -Be $true
        $r.ExitCode   | Should -Be 124
        $r.KillFailed | Should -Be $false -Because 'the child was killed and seen to exit inside the cleanup reserve'
        $r.ElapsedMs  | Should -BeLessThan 1500
    }

    It 'ends by its cap when a descendant escaped the tree kill and still holds both pipes' {
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-bounded'
        $pidFile = Join-Path $dir 'escaped.pid'
        try {
            # The subshell backgrounds sleep and exits, so sleep is re-parented
            # and no longer a descendant the kill can enumerate.
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r  = Invoke-BoundedNativeCommand -FilePath 'bash' `
                -ArgumentList @('-c', "( sleep 30 & echo `$! > '$pidFile' ); sleep 60") -TimeoutSeconds 2
            $sw.Stop()
            $r.TimedOut      | Should -Be $true
            $r.ExitCode      | Should -Be 124
            $r.DrainTimedOut | Should -Be $true
            $r.KillFailed    | Should -Be $false -Because 'the direct child was killed and seen to exit; only the escaped descendant survives'
            $sw.ElapsedMilliseconds | Should -BeLessThan 2750
        } finally {
            if (Test-Path -LiteralPath $pidFile) {
                $escapedPid = [int]((Get-Content -LiteralPath $pidFile -Raw).Trim())
                $escaped = Get-Process -Id $escapedPid -ErrorAction SilentlyContinue
                if ($escaped -and $escaped.ProcessName -eq 'sleep') { $escaped.Kill() }
            }
            Remove-YurunaTestTempDir $dir
        }
    }

    It 'reports KillFailed and still returns by the cap when the kill itself fails' {
        Mock -ModuleName Yuruna.Common Invoke-BoundedNativeTreeKill { throw 'simulated kill failure' }
        $r = $null
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r  = Invoke-BoundedNativeCommand -FilePath 'sleep' -ArgumentList @('60') -TimeoutSeconds 2
            $sw.Stop()
            $r.KillFailed | Should -Be $true
            $r.TimedOut   | Should -Be $true
            $r.ExitCode   | Should -Be 124
            $sw.ElapsedMilliseconds | Should -BeLessThan 2750
            Should -Invoke -ModuleName Yuruna.Common Invoke-BoundedNativeTreeKill -Times 1 -Exactly
        } finally {
            if ($r -and $r.ProcessId -gt 0) {
                $survivor = Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue
                if ($survivor -and $survivor.ProcessName -eq 'sleep') { $survivor.Kill() }
            }
        }
    }

    It 'launches nothing and reports DeadlineExhausted, not a timeout, when the deadline has under a second left' {
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-bounded'
        try {
            $marker = Join-Path $dir 'ran.marker'
            $tick  = [ref]1000L
            $clock = { $tick.Value }.GetNewClosure()
            $deadline = New-YurunaDeadline -TotalMilliseconds 500 -ClockTicks $clock
            $r = Invoke-BoundedNativeCommand -FilePath 'bash' -ArgumentList @('-c', "touch '$marker'") -TimeoutSeconds 30 -Deadline $deadline
            $r.DeadlineExhausted | Should -Be $true
            $r.Started           | Should -Be $false
            $r.TimedOut          | Should -Be $false -Because 'a call that was never issued must not read as a tool that failed to answer'
            $r.ExitCode          | Should -Be -1
            $r.ProcessId         | Should -Be 0
            [IO.File]::Exists($marker) | Should -Be $false
        } finally { Remove-YurunaTestTempDir $dir }
    }

    It 'caps the call at the deadline''s remaining time when that is shorter than TimeoutSeconds' {
        $deadline = New-YurunaDeadline -TotalMilliseconds 2000
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r  = Invoke-BoundedNativeCommand -FilePath 'sleep' -ArgumentList @('30') -TimeoutSeconds 60 -Deadline $deadline
        $sw.Stop()
        $r.TimedOut          | Should -Be $true
        $r.DeadlineExhausted | Should -Be $false
        $sw.ElapsedMilliseconds | Should -BeLessThan 2750
    }

    It 'drains both pipes past the capture cap concurrently without blocking the writer' {
        $writer = '(head -c 200000 /dev/zero | tr "\0" x) & (head -c 200000 /dev/zero | tr "\0" y 1>&2) & wait'
        $r = Invoke-BoundedNativeCommand -FilePath 'bash' -ArgumentList @('-c', $writer) -TimeoutSeconds 20 -MaxCapturedChars 4096
        $r.TimedOut        | Should -Be $false
        $r.ExitCode        | Should -Be 0
        $r.OutputTruncated | Should -Be $true
        $r.StdOut.Length   | Should -Be 4096
        $r.StdErr.Length   | Should -Be 4096
        (Test-BoundedNativeResultComplete -Result $r) | Should -Be $false -Because 'truncated output is not a complete answer'
    }

    It 'reports the direct child''s process id' {
        # The shell's own pid on Windows would be an MSYS pid, not the Windows pid the runner reports.
        $r = if ($IsWindows) {
            Invoke-BoundedNativeCommand -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-Command', '$PID') -TimeoutSeconds 30
        } else {
            Invoke-BoundedNativeCommand -FilePath 'bash' -ArgumentList @('-c', 'echo $$') -TimeoutSeconds 10
        }
        $r.ProcessId | Should -BeGreaterThan 0
        [int]($r.StdOut.Trim()) | Should -Be $r.ProcessId
        (Test-BoundedNativeResultComplete -Result $r) | Should -Be $true
    }

    It 'classifies a result as complete only when it started and no incompleteness flag is set' {
        $complete = @{ Started = $true; TimedOut = $false; DrainTimedOut = $false; OutputTruncated = $false; KillFailed = $false; DeadlineExhausted = $false }
        (Test-BoundedNativeResultComplete -Result $complete) | Should -Be $true
        foreach ($flag in @('TimedOut', 'DrainTimedOut', 'OutputTruncated', 'KillFailed', 'DeadlineExhausted')) {
            $incomplete = $complete.Clone()
            $incomplete[$flag] = $true
            (Test-BoundedNativeResultComplete -Result $incomplete) | Should -Be $false -Because "$flag set means the answer may be partial"
        }
        (Test-BoundedNativeResultComplete -Result @{ Started = $false }) | Should -Be $false
        (Test-BoundedNativeResultComplete -Result @{ Started = $true }) | Should -Be $true -Because 'an absent key counts as false, so an older result shape still classifies'
        (Test-BoundedNativeResultComplete -Result $null) | Should -Be $false
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

Describe 'crash gating timestamp interpretation' {
    It 'accounts only for saves before spawn across cultures and local time zones' {
        $dir = Initialize-TempRuntimeDir
        $beforeCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        $beforeTimezone = $env:TZ
        try {
            foreach ($zone in @('Pacific/Honolulu', 'Europe/Berlin')) {
                $env:TZ = $zone
                [TimeZoneInfo]::ClearCachedData()
                foreach ($culture in @('en-US', 'pt-BR')) {
                    [Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::GetCultureInfo($culture)
                    foreach ($minutes in @(-55, 30)) {
                        $spawn = [datetime]::UtcNow.AddHours(-1)
                        [IO.File]::WriteAllText((Join-Path $dir 'runner.gating.json'), (@{ savedAt = $spawn.AddMinutes($minutes).ToString('o'); alertArmed = $false; consecutiveFailures = 0; consecutiveCrashes = 0 } | ConvertTo-Json))
                        $result = Update-RunnerCrashGating -RuntimeDir $dir -SpawnedAtUtc $spawn -Config $null -ExitCode 137 -Confirm:$false
                        $result.Updated | Should -Be ($minutes -lt 0)
                    }
                }
            }
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $beforeCulture
            if ($null -eq $beforeTimezone) { Remove-Item Env:TZ -ErrorAction SilentlyContinue } else { $env:TZ = $beforeTimezone }
            [TimeZoneInfo]::ClearCachedData()
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
    }
}
