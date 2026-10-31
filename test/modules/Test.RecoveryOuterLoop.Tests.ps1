<#PSScriptInfo
.VERSION 2026.10.31
.GUID 4277cde3-5e56-4d5e-beb5-7bed391f35c5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test recovery outer-loop ledger pester
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
    Drives the real outer loop with a faked cycle dispatch and a throwaway runtime
    directory, to pin how it reports a cycle and how the recovery ledger bounds
    what it repairs.
.DESCRIPTION
    The attempt budget used to live in the loop process, so a runner restart
    handed a deterministic transient a fresh set of retries. These cases run the
    loop more than once against the same runtime directory, which is exactly what a
    restart is, and check that the budget survives; that a pass re-arms it; that
    with repair off nothing reaches the ledger and the result only advises; and
    that a framework pull that fails on a stale git lock is repaired and retried at
    once. Only the dispatch and the sleeps are faked.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The loop reads the runtime and log directories from environment variables; the fixtures set and restore them.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -DisableNameChecking
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
# The loop reads testCycle.autoRemediation through the config reader, which needs the YAML module;
# without them the setting silently reads as off and every case below would pass for the wrong reason.
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { throw 'powershell-yaml is required for these cases.' }
Import-Module (Join-Path $here 'Test.Config.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.RecoveryContract.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.RecoveryLedger.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.RunnerOuterLoop.psm1') -Force -DisableNameChecking

$script:LoopConfigDir = New-YurunaTestTempDir -Prefix 'rol-config'

function New-LoopConfig {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes a throwaway config file under the suite temp folder.')]
    param([bool]$Enabled, [int]$MaxAttempts = 1)
    $path = Join-Path $script:LoopConfigDir ([guid]::NewGuid().ToString('N') + '.yml')
    $text = "testCycle:`n  autoRemediation:`n    enabled: $($Enabled.ToString().ToLowerInvariant())`n    maxAttemptsPerCycle: $MaxAttempts`n"
    Set-Content -LiteralPath $path -Value $text -Encoding utf8
    return $path
}

function Invoke-FakeLoop {
    <# Runs the loop to completion over a scripted list of cycle results; returns what it printed. #>
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][object[]]$Cycle,
        [string]$RepoRoot = $PSScriptRoot
    )
    $script:Script = [System.Collections.Generic.Queue[object]]::new()
    foreach ($step in $Cycle) { $script:Script.Enqueue($step) }
    $state = @{
        CycleScript = ''; RepoRoot = $RepoRoot; ConfigPath = $ConfigPath; InnerScript = 'x'; PwshExe = 'pwsh'; ArgList = @()
        ForwardEnvSnapshot = @{}; ShutdownState = @{ Requested = $false }; NoGitPull = $true
        FailurePauseMaxSeconds = 1; FailureCommitPollSeconds = 1; OuterPullErrorSleepSeconds = 1; InnerSpawnErrorSleepSeconds = 1
        StepTimeoutSecondsDefault = 1; WatchdogPollSeconds = 1
    }
    return (@(Invoke-RunnerOuterLoop -State $state 3>$null 6>$null 4>$null) -join "`n")
}
}

Describe 'The failure pause shortcut is budgeted by the ledger' {
    BeforeAll {
        $script:MessagePattern = "auto-remediation: transient 'wait_timeout'"
    }
    BeforeEach {
        $script:Dir = New-YurunaTestTempDir -Prefix 'rol'
        Set-Content -LiteralPath (Join-Path $script:Dir 'last_failure.json') -Value '{"failureClass":"wait_timeout"}' -Encoding utf8
        $script:SavedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $script:SavedLog = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR'
        $env:YURUNA_RUNTIME_DIR = $script:Dir
        $env:YURUNA_LOG_DIR = $script:Dir
        $script:Config = New-LoopConfig -Enabled $true -MaxAttempts 1
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
        Mock -ModuleName Test.RunnerOuterLoop Import-OuterRefreshTriggerModule { $false }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterCommitSha { 'sha0' }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterProjectUrl { '' }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterConfigMtime { $null }
        Mock -ModuleName Test.RunnerOuterLoop Test-OuterNewCommitsAvailable { $false }
        Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterCycleDispatch {
            $next = $script:Script.Dequeue()
            # 'stop' ends the loop with a pool drain, which is not a verdict: a stop that
            # exited 0 would be a pass, and a pass re-arms the very budget under test.
            if ($next -eq 'stop') {
                $State.ShutdownState['Requested'] = $true
                return [pscustomobject]@{ Outcome = 'drain'; ExitCode = 0 }
            }
            if ($next -eq 'fail') { return [pscustomobject]@{ Outcome = 'completed'; ExitCode = 1 } }
            return [pscustomobject]@{ Outcome = 'completed'; ExitCode = 0 }
        }
    }
    AfterEach {
        Restore-YurunaTestEnvironment -Saved $script:SavedRuntime
        Restore-YurunaTestEnvironment -Saved $script:SavedLog
        Remove-Item -LiteralPath $script:Config -Force -ErrorAction SilentlyContinue
        Remove-YurunaTestTempDir $script:Dir
    }

    It 'ends the pause early once for a failure, then lets the second one take its pause' {
        $out = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('fail', 'fail', 'stop')
        ([regex]::Matches($out, [regex]::Escape($script:MessagePattern))).Count | Should -Be 1
    }
    It 'does not hand a failure a fresh budget when the runner restarts' {
        $first = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('fail', 'stop')
        ([regex]::Matches($first, [regex]::Escape($script:MessagePattern))).Count | Should -Be 1 -Because 'the first run spends the one attempt'
        # A new call is a new process as far as the budget is concerned: the loop's
        # own memory starts empty, and only the ledger remembers.
        $second = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('fail', 'stop')
        ([regex]::Matches($second, [regex]::Escape($script:MessagePattern))).Count | Should -Be 0 -Because 'the ledger remembers the spent attempt'
    }
    It 're-arms the budget after a cycle passes' {
        $null = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('fail', 'stop')
        $out = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('pass', 'fail', 'stop')
        ([regex]::Matches($out, [regex]::Escape($script:MessagePattern))).Count | Should -Be 1
    }
    It 'records the attempt in the ledger and the decision on the result' {
        $null = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('fail', 'stop')
        $lines = @(Read-RecoveryLedger -RuntimeDir $script:Dir).Records
        @($lines | Where-Object { $_.phase -eq 'started' -and $_.action -eq 'end_failure_pause_early' }).Count | Should -Be 1
        @($lines | Where-Object { $_.phase -eq 'succeeded' }).Count | Should -Be 1
        $latest = Read-RecoveryResult -RuntimeDir $script:Dir
        $latest['outcome'] | Should -Be 'failed'
        $latest['failureClass'] | Should -Be 'wait_timeout'
        $latest['fingerprint'] | Should -Match '^fp1-[0-9a-f]{16}$'
        $latest['recovery']['state'] | Should -Be 'applied' -Because 'the decision made inside the pause is added to the latest result'
        $latest['recovery']['action'] | Should -Be 'end_failure_pause_early'
        $latest['recovery']['attempt'] | Should -Be 1
        $history = @(Get-RecoveryResultHistory -RuntimeDir $script:Dir -Last 10)
        $history.Count | Should -Be 1 -Because 'the history keeps a result once, as first recorded'
        $history[0]['recovery']['state'] | Should -Be 'none'
    }
    It 'leaves the ledger absent and only advises when automatic repair is off' {
        Remove-Item -LiteralPath $script:Config -Force
        $script:Config = New-LoopConfig -Enabled $false
        $out = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('fail', 'stop')
        $out | Should -Not -Match ([regex]::Escape($script:MessagePattern))
        Test-Path -LiteralPath (Get-RecoveryLedgerPath -RuntimeDir $script:Dir) | Should -BeFalse
        $latest = Read-RecoveryResult -RuntimeDir $script:Dir
        $latest['outcome'] | Should -Be 'failed'
        $latest['recovery']['state'] | Should -Be 'advised'
        @($latest['recovery']['advised']) | Should -Contain 'end_failure_pause_early'
    }
    It 'treats a cycle that is not a verdict as nothing to record' {
        Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterCycleDispatch {
            $script:Script.Dequeue() | Out-Null
            $State.ShutdownState['Requested'] = $true
            return [pscustomobject]@{ Outcome = 'drain'; ExitCode = 0 }
        }
        $null = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('x')
        Read-RecoveryResult -RuntimeDir $script:Dir | Should -BeNullOrEmpty
    }
}

# A host that cannot start a cycle process used to retry every 30 s all day,
# with nothing on the status page to say so.
Describe 'A run of attempts that produce no verdict' {
    BeforeEach {
        $script:Dir = New-YurunaTestTempDir -Prefix 'rol'
        $script:SavedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $env:YURUNA_RUNTIME_DIR = $script:Dir
        $script:Config = New-LoopConfig -Enabled $false -MaxAttempts 1
        $script:Holds = [System.Collections.Generic.List[int]]::new()
        $script:Faults = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
        Mock -ModuleName Test.RunnerOuterLoop Import-OuterRefreshTriggerModule { $false }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterCommitSha { 'sha0' }
        Mock -ModuleName Test.RunnerOuterLoop Wait-OuterInterruptible { $script:Holds.Add([int]$Seconds) }
        Mock -ModuleName Test.RunnerOuterLoop Update-RunnerFaultStatus { $script:Faults.Add([string]$FailureClass); $true }
        Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterCycleDispatch {
            $next = $script:Script.Dequeue()
            if ($next -eq 'stop') {
                $State.ShutdownState['Requested'] = $true
                return [pscustomobject]@{ Outcome = 'drain'; ExitCode = 0 }
            }
            if ($next -eq 'spawn') { return [pscustomobject]@{ Outcome = 'spawn-failed'; ExitCode = 0 } }
            return [pscustomobject]@{ Outcome = 'completed'; ExitCode = 0 }
        }
    }
    AfterEach {
        Restore-YurunaTestEnvironment -Saved $script:SavedRuntime
        Remove-Item -LiteralPath $script:Config -Force -ErrorAction SilentlyContinue
        Remove-YurunaTestTempDir $script:Dir
    }
    It 'doubles the hold after each cycle process that would not start, and says so' {
        $null = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('spawn', 'spawn', 'spawn', 'stop')
        @($script:Holds) | Should -Be @(1, 2, 4)
        @($script:Faults | Where-Object { $_ -eq 'cycle_spawn_failed' }).Count | Should -Be 3
    }
    It 'starts the run over after a cycle that ran' {
        $null = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('spawn', 'spawn', 'ok', 'spawn', 'stop')
        $script:Holds[0] | Should -Be 1
        $script:Holds[1] | Should -Be 2
        $script:Holds[-1] | Should -Be 1 -Because 'the cycle that ran ended the run'
    }
    It 'holds <Expected> s after <Streak> attempt(s) from a <Base> s base' -TestCases @(
        @{ Base = 30; Streak = 1; Expected = 30 }, @{ Base = 30; Streak = 2; Expected = 60 }
        @{ Base = 30; Streak = 5; Expected = 480 }, @{ Base = 30; Streak = 6; Expected = 900 }
        @{ Base = 30; Streak = 40; Expected = 900 }, @{ Base = 0; Streak = 1; Expected = 1 }
    ) {
        param($Base, $Streak, $Expected)
        InModuleScope Test.RunnerOuterLoop -Parameters @{ B = $Base; S = $Streak } { param($B, $S) Get-OuterRetryHoldSeconds -BaseSeconds $B -Streak $S } | Should -Be $Expected
    }
}

# A cycle whose guests were all quarantined exits 0 having tested nothing, and
# used to refill every repair budget as if a repair had worked.
Describe 'A passing cycle that skipped a guest' {
    BeforeEach {
        $script:Dir = New-YurunaTestTempDir -Prefix 'rol'
        $script:SavedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $script:SavedLog = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR'
        $env:YURUNA_RUNTIME_DIR = $script:Dir
        $env:YURUNA_LOG_DIR = $script:Dir
        $script:Config = New-LoopConfig -Enabled $true -MaxAttempts 1
        Set-Content -LiteralPath (Join-Path $script:Dir 'recovery.ledger.ndjson') -Value ''
        $script:Refills = 0
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
        Mock -ModuleName Test.RunnerOuterLoop Import-OuterRefreshTriggerModule { $false }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterCommitSha { 'sha0' }
        Mock -ModuleName Test.RunnerOuterLoop Complete-RecoveryFingerprint { $script:Refills++; $true }
        Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterCycleDispatch {
            $next = $script:Script.Dequeue()
            if ($next -eq 'stop') {
                $State.ShutdownState['Requested'] = $true
                return [pscustomobject]@{ Outcome = 'drain'; ExitCode = 0 }
            }
            return [pscustomobject]@{ Outcome = 'completed'; ExitCode = 0 }
        }
    }
    AfterEach {
        Restore-YurunaTestEnvironment -Saved $script:SavedRuntime
        Restore-YurunaTestEnvironment -Saved $script:SavedLog
        Remove-Item -LiteralPath $script:Config -Force -ErrorAction SilentlyContinue
        Remove-YurunaTestTempDir $script:Dir
    }
    It 're-arms <Expected> budget refill(s) when the guests were <Statuses>' -TestCases @(
        @{ Statuses = @('skipped', 'skipped'); Expected = 0 }
        @{ Statuses = @('pass', 'skipped'); Expected = 0 }
        @{ Statuses = @('pass', 'pass'); Expected = 1 }
    ) {
        param($Statuses, $Expected)
        $guests = @(for ($n = 0; $n -lt $Statuses.Count; $n++) { @{ guestKey = "guest.$n"; status = $Statuses[$n] } })
        Set-Content -LiteralPath (Join-Path $script:Dir 'status.json') -Value (@{ overallStatus = 'pass'; guests = $guests } | ConvertTo-Json -Depth 4)
        $null = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('ok', 'stop')
        $script:Refills | Should -Be $Expected
    }
}

# A cycle whose planned guests were all quarantined exited 0, so the resident
# counted a host that tested nothing as a pass.
Describe 'A cycle that failed nothing but skipped a planned guest' {
    BeforeEach {
        $script:Dir = New-YurunaTestTempDir -Prefix 'rol'
        $script:SavedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $script:SavedLog = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR'
        $env:YURUNA_RUNTIME_DIR = $script:Dir
        $env:YURUNA_LOG_DIR = $script:Dir
        $script:Config = New-LoopConfig -Enabled $true -MaxAttempts 1
        Set-Content -LiteralPath (Join-Path $script:Dir 'recovery.ledger.ndjson') -Value ''
        $guests = @(@{ guestKey = 'guest.0'; status = 'pass' }, @{ guestKey = 'guest.1'; status = 'skipped' })
        Set-Content -LiteralPath (Join-Path $script:Dir 'status.json') -Value (@{ overallStatus = 'pass'; cycle = 7; guests = $guests } | ConvertTo-Json -Depth 4)
        $script:Refills = 0
        $script:Faults = 0
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
        Mock -ModuleName Test.RunnerOuterLoop Import-OuterRefreshTriggerModule { $false }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterCommitSha { 'sha0' }
        Mock -ModuleName Test.RunnerOuterLoop Complete-RecoveryFingerprint { $script:Refills++; $true }
        Mock -ModuleName Test.RunnerOuterLoop Update-RunnerFaultStatus { $script:Faults++; $true }
        Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterCycleDispatch {
            $next = $script:Script.Dequeue()
            if ($next -eq 'stop') {
                $State.ShutdownState['Requested'] = $true
                return [pscustomobject]@{ Outcome = 'drain'; ExitCode = 0 }
            }
            return [pscustomobject]@{ Outcome = 'completed'; ExitCode = (Get-DegradedCycleExitCode) }
        }
    }
    AfterEach {
        Restore-YurunaTestEnvironment -Saved $script:SavedRuntime
        Restore-YurunaTestEnvironment -Saved $script:SavedLog
        Remove-Item -LiteralPath $script:Config -Force -ErrorAction SilentlyContinue
        Remove-YurunaTestTempDir $script:Dir
    }
    It 'raises no fault and re-arms no repair budget, and says how many guests it skipped' {
        $out = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('degraded', 'stop')
        $script:Faults | Should -Be 0
        $script:Refills | Should -Be 0
        $out | Should -Match 'Cycle 000007 - DEGRADED \(1 of 2 guests skipped\)'
        $result = Get-Content -Raw -LiteralPath (Join-Path $script:Dir 'recovery.result.json') | ConvertFrom-Json
        $result.outcome | Should -Be 'degraded'
        $result.exitCode | Should -Be 75
    }
}

# A pool share that had room again, a hypervisor that answered again: the host
# still waited out the whole failure pause, because nothing asked.
Describe 'A host condition whose probe says it cleared' {
    BeforeEach {
        $script:Dir = New-YurunaTestTempDir -Prefix 'rol'
        $script:SavedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $script:SavedLog = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR'
        $env:YURUNA_RUNTIME_DIR = $script:Dir
        $env:YURUNA_LOG_DIR = $script:Dir
        $script:Config = New-LoopConfig -Enabled $true -MaxAttempts 2
        $script:Probes = 0
        $script:ProbeClears = $true
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
        Mock -ModuleName Test.RunnerOuterLoop Import-OuterRefreshTriggerModule { $false }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterCommitSha { 'sha0' }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterProjectUrl { '' }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterConfigMtime { $null }
        Mock -ModuleName Test.RunnerOuterLoop Test-OuterNewCommitsAvailable { $false }
        # Every poll may probe: the registered interval is minutes, the fixture pause is a second.
        Mock -ModuleName Test.RunnerOuterLoop Get-RecoveryProbe { [pscustomobject]@{ FailureClass = 'pool_storage_full'; IntervalSeconds = 0; TimeoutSeconds = 5 } } `
            -ParameterFilter { $FailureClass -eq 'pool_storage_full' }
        Mock -ModuleName Test.RunnerOuterLoop Invoke-RecoveryProbe {
            $script:Probes++
            [pscustomobject]@{ Ran = $true; Cleared = $script:ProbeClears; ExitCode = $(if ($script:ProbeClears) { 0 } else { 1 }); Detail = 'pool storage: fixture' }
        }
        Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterCycleDispatch {
            $next = $script:Script.Dequeue()
            if ($next -eq 'stop') {
                $State.ShutdownState['Requested'] = $true
                return [pscustomobject]@{ Outcome = 'drain'; ExitCode = 0 }
            }
            return [pscustomobject]@{ Outcome = 'storage-full'; ExitCode = 1 }
        }
    }
    AfterEach {
        Restore-YurunaTestEnvironment -Saved $script:SavedRuntime
        Restore-YurunaTestEnvironment -Saved $script:SavedLog
        Remove-Item -LiteralPath $script:Config -Force -ErrorAction SilentlyContinue
        Remove-YurunaTestTempDir $script:Dir
    }
    It 'ends the pause through the ledger once the probe says the share has room' {
        $out = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('full', 'stop')
        $out | Should -Match 'the pool_storage_full condition has cleared \(pool storage: fixture\)'
        $script:Probes | Should -Be 1
        $lines = @(Read-RecoveryLedger -RuntimeDir $script:Dir).Records
        @($lines | Where-Object { $_.action -eq 'end_failure_pause_on_probe' -and $_.phase -eq 'succeeded' }).Count | Should -Be 1
        (Read-RecoveryResult -RuntimeDir $script:Dir)['recovery']['action'] | Should -Be 'end_failure_pause_on_probe'
    }
    It 'writes nothing to the ledger while the probe says the condition holds' {
        $script:ProbeClears = $false
        $out = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('full', 'stop')
        $out | Should -Not -Match 'condition has cleared'
        $script:Probes | Should -BeGreaterOrEqual 1
        @(Read-RecoveryLedger -RuntimeDir $script:Dir).Records | Where-Object { $_.action -eq 'end_failure_pause_on_probe' } | Should -BeNullOrEmpty
    }
    It 'does not probe while automatic recovery is off' {
        Remove-Item -LiteralPath $script:Config -Force
        $script:Config = New-LoopConfig -Enabled $false
        $null = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('full', 'stop')
        $script:Probes | Should -Be 0
        @((Read-RecoveryResult -RuntimeDir $script:Dir)['recovery']['advised']) | Should -Contain 'end_failure_pause_on_probe'
    }
}

# The early end of a failure pause came after one poll interval however many
# times the same failure had already been retried.
Describe 'The hold before an unattended retry ends a pause' {
    It 'doubles with each early end the ledger holds for the failure, to at most 15 minutes' {
        $dir = New-YurunaTestTempDir -Prefix 'rol'
        try {
            $result = New-RecoveryResult -EntryPoint runner -CycleGeneration (('c' * 32) + ':1') -Outcome failed -ExitCode 1 `
                -FailureClass wait_timeout -SequenceName 'workload.x' -ActionVerb waitForText -Reason 'timed out'
            $fingerprint = [string]$result['fingerprint']
            $hold = { & (Get-Module Test.RunnerOuterLoop) { param($d, $f) Get-OuterEarlyEndHoldSeconds -PollSeconds 300 -RuntimeDir $d -Fingerprint $f } $dir $fingerprint }
            & $hold | Should -Be 300
            foreach ($expected in 600, 900, 900) {
                $ended = Invoke-RecoveryAction -Name 'end_failure_pause_early' -Context @{ Result = $result; RuntimeDir = $dir } -RuntimeDir $dir -MaxAttempts 10
                $ended.Decision | Should -Be 'applied'
                & $hold | Should -Be $expected
            }
            $null = Complete-RecoveryFingerprint -RuntimeDir $dir -Generation (('c' * 32) + ':2')
            & $hold | Should -Be 300 -Because 'a pass re-arms the backoff with the budget'
            & (Get-Module Test.RunnerOuterLoop) { Get-OuterEarlyEndHoldSeconds -PollSeconds 300 -RuntimeDir '' -Fingerprint '' } | Should -Be 300
        } finally { Remove-YurunaTestTempDir $dir }
    }
}

Describe 'Why a framework pull failed' {
    BeforeEach {
        $script:Pull = @{ Success = $false; ErrorMessage = ''; Changed = $false; Skipped = $false;
            PreviousRevision = ('a' * 40); Revision = ('a' * 40); BackupRef = '' }
        Mock -ModuleName Test.RunnerOuterLoop Invoke-GitRepositoryUpdate {
            return $script:Pull
        }
    }

    It 'keeps the git output of a failed pull, redacted, for the cycle outcome record' {
        $script:Pull.ErrorMessage = "fatal: Unable to create '/x/.git/index.lock': File exists.`nfatal: could not read from https://user:s3cr3t@github.com/x/y.git"
        Invoke-OuterGitPull -RepoRoot 'R' 6>$null | Should -BeFalse
        $why = Get-LastOuterPullFailure
        $why | Should -Match 'index\.lock'
        $why | Should -Not -Match 's3cr3t'
        $why | Should -Not -Match "`n"
    }
    It 'forgets the failure once a pull succeeds' {
        $script:Pull.ErrorMessage = 'fatal: Unable to create index.lock'
        $null = Invoke-OuterGitPull -RepoRoot 'R' 6>$null
        Get-LastOuterPullFailure | Should -Not -BeNullOrEmpty
        $script:Pull.Success = $true
        $script:Pull.ErrorMessage = ''
        Invoke-OuterGitPull -RepoRoot 'R' 6>$null | Should -BeTrue
        Get-LastOuterPullFailure | Should -Be ''
    }
    It 'retains the shared updater refusal for an unmerged checkout' {
        $script:Pull.ErrorMessage = 'the working tree holds conflict markers or unmerged paths'
        Invoke-OuterGitPull -RepoRoot 'R' 6>$null | Should -BeFalse
        Get-LastOuterPullFailure | Should -Match 'conflict markers or unmerged'
    }
    It 'reports the source failure class and redacted reason in the actual cycle outcome' -ForEach @(
        @{Class='source_integrity'}, @{Class='network_timeout'}, @{Class='project_access_denied'}
    ) {
        $script:Pull.ErrorMessage = 'fixture source rejected'
        $script:Pull.FailureClass = $Class
        $state = @{
            RepoRoot=$TestDrive;ConfigPath=(Join-Path $TestDrive 'absent.yml');InnerScript='x';PwshExe='pwsh'
            ArgList=@();ForwardEnvSnapshot=@{};ShutdownState=@{Requested=$false};NoGitPull=$false
            FailurePauseMaxSeconds=1;FailureCommitPollSeconds=1;OuterPullErrorSleepSeconds=1;InnerSpawnErrorSleepSeconds=1
            StepTimeoutSecondsDefault=1;WatchdogPollSeconds=1
        }
        $returned = Invoke-RunnerOuterCycle -State $state -Cycle 1 3>$null 6>$null
        $returned.Outcome | Should -Be 'pull-error'
        $returned.FailureClass | Should -BeExactly $Class
        $returned.Detail | Should -BeExactly (Get-LastOuterPullFailure)
        $returned.Detail | Should -Match 'fixture source rejected'
    }
}

Describe 'A framework pull that fails on a stale git lock' {
    BeforeAll {
        $script:Git = (Get-Command git -ErrorAction SilentlyContinue)
    }
    BeforeEach {
        $script:Dir = New-YurunaTestTempDir -Prefix 'rolp'
        $script:Repo = Join-Path $script:Dir 'framework'
        New-Item -ItemType Directory -Path $script:Repo -Force | Out-Null
        $script:Runtime = Join-Path $script:Dir 'runtime'
        New-Item -ItemType Directory -Path $script:Runtime -Force | Out-Null
        if ($script:Git) {
            $null = New-YurunaTestGitRepository -Path $script:Repo -CommitMessage 'init'
            $script:Lock = Join-Path $script:Repo '.git/index.lock'
            Set-Content -LiteralPath $script:Lock -Value '' -NoNewline
            [IO.File]::SetLastWriteTimeUtc($script:Lock, [datetime]::UtcNow.AddHours(-2))
        }
        $script:SavedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $script:SavedLog = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR'
        $env:YURUNA_RUNTIME_DIR = $script:Runtime
        $env:YURUNA_LOG_DIR = $script:Runtime
        $script:Waits = [System.Collections.Generic.List[int]]::new()
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
        Mock -ModuleName Test.RunnerOuterLoop Import-OuterRefreshTriggerModule { $false }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterProjectUrl { '' }
        Mock -ModuleName Test.RunnerOuterLoop Wait-OuterInterruptible { $script:Waits.Add([int]$Seconds); return $true }
        # A real git process elsewhere on the machine must not decide this case.
        Mock -ModuleName Test.RecoveryActions Test-GitProcessRunning { $false }
        Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterCycleDispatch {
            $next = $script:Script.Dequeue()
            if ($next -eq 'pull-error') {
                return [pscustomobject]@{ Outcome = 'pull-error'; ExitCode = 0; RecordFailureClass = 'bootstrap_sync'; RecordDetail = "fatal: Unable to create '$($script:Repo -replace '\\', '/')/.git/index.lock': File exists." }
            }
            $State.ShutdownState['Requested'] = $true
            return [pscustomobject]@{ Outcome = 'drain'; ExitCode = 0 }
        }
    }
    AfterEach {
        Restore-YurunaTestEnvironment -Saved $script:SavedRuntime
        Restore-YurunaTestEnvironment -Saved $script:SavedLog
        Remove-Item -LiteralPath $script:Config -Force -ErrorAction SilentlyContinue
        Remove-YurunaTestTempDir $script:Dir
    }

    It 'moves the lock aside and retries at once instead of holding' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $script:Config = New-LoopConfig -Enabled $true -MaxAttempts 2
        $null = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('pull-error', 'stop') -RepoRoot $script:Repo
        Test-Path -LiteralPath $script:Lock | Should -BeFalse -Because 'the stale lock is out of the way'
        @(Get-ChildItem -LiteralPath (Join-Path $script:Runtime 'recovery.quarantine') -Recurse -Force -Filter 'index.lock' -File).Count | Should -Be 1 -Because 'it was moved, not deleted; the lock sits under .git, which -Force reveals on Unix'
        $script:Waits.Count | Should -Be 0 -Because 'a repair that applied replaces the hold'
        $ledger = @((Read-RecoveryLedger -RuntimeDir $script:Runtime).Records)
        @($ledger | Where-Object { $_.phase -eq 'started' -and $_.action -eq 'clear_stale_git_lock' }).Count | Should -Be 1
        @($ledger | Where-Object { $_.phase -eq 'succeeded' -and $_.action -eq 'clear_stale_git_lock' }).Count | Should -Be 1
        $pullResult = Read-RecoveryResult -RuntimeDir $script:Runtime
        $pullResult['stage'] | Should -Be 'FrameworkPull'
        $pullResult['failureClass'] | Should -Be 'bootstrap_sync'
        $pullResult['recovery']['state'] | Should -Be 'applied'
        $pullResult['recovery']['action'] | Should -Be 'clear_stale_git_lock'
    }
    It 'holds as it always did, and leaves the lock, when automatic repair is off' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $script:Config = New-LoopConfig -Enabled $false
        $null = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('pull-error', 'stop') -RepoRoot $script:Repo
        Test-Path -LiteralPath $script:Lock | Should -BeTrue
        $script:Waits.Count | Should -Be 1
        Test-Path -LiteralPath (Get-RecoveryLedgerPath -RuntimeDir $script:Runtime) | Should -BeFalse
        $pullResult = Read-RecoveryResult -RuntimeDir $script:Runtime
        $pullResult['stage'] | Should -Be 'FrameworkPull'
        $pullResult['recovery']['state'] | Should -Be 'advised'
        @($pullResult['recovery']['advised']) | Should -Contain 'clear_stale_git_lock'
    }
    It 'holds when the failure is not a lock' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $script:Config = New-LoopConfig -Enabled $true -MaxAttempts 2
        Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterCycleDispatch {
            $next = $script:Script.Dequeue()
            if ($next -eq 'pull-error') { return [pscustomobject]@{ Outcome = 'pull-error'; ExitCode = 0; RecordFailureClass = 'bootstrap_sync'; RecordDetail = 'fatal: unable to access the remote: Could not resolve host' } }
            $State.ShutdownState['Requested'] = $true
            return [pscustomobject]@{ Outcome = 'drain'; ExitCode = 0 }
        }
        $null = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('pull-error', 'stop') -RepoRoot $script:Repo
        Test-Path -LiteralPath $script:Lock | Should -BeTrue -Because 'a network failure is not a stale lock'
        $script:Waits.Count | Should -Be 1
    }
    It 'publishes a framework preflight failure before retrying without changing the prior pass or counting a crash' {
        $script:Config = New-LoopConfig -Enabled $false
        $statusPath = Join-Path $script:Runtime 'status.json'
        $prior = @{ schemaVersion = 1; overallStatus = 'pass'; testsPassed = 7; testsFailed = 0;
            finishedAt = '2026-10-18T01:00:00Z'; history = @(@{ overallStatus = 'pass'; cycleNumber = 42 }); guests = @() }
        $prior | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statusPath
        $script:ObservedBeforeWait = $null
        Mock -ModuleName Test.RunnerOuterLoop Update-RunnerCrashGating { throw 'an update refusal is not a runner crash' }
        Mock -ModuleName Test.RunnerOuterLoop Wait-OuterInterruptible {
            $script:ObservedBeforeWait = Get-Content -LiteralPath (Join-Path $script:Runtime 'status.json') -Raw | ConvertFrom-Json
            $script:Waits.Add([int]$Seconds)
            return $true
        }
        $null = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('pull-error', 'stop') -RepoRoot $script:Repo
        $script:ObservedBeforeWait.runnerFault.failureClass | Should -Be 'bootstrap_sync'
        $script:ObservedBeforeWait.runnerFault.stage | Should -Be 'FrameworkPull'
        $script:ObservedBeforeWait.runnerFault.errorMessage | Should -Match 'index\.lock'
        $script:ObservedBeforeWait.overallStatus | Should -Be 'pass'
        $script:ObservedBeforeWait.testsPassed | Should -Be 7
        $script:ObservedBeforeWait.testsFailed | Should -Be 0
        @($script:ObservedBeforeWait.history).Count | Should -Be 1
        $script:ObservedBeforeWait.history[0].cycleNumber | Should -Be 42
        $script:Waits.Count | Should -Be 1
        Should -Invoke -ModuleName Test.RunnerOuterLoop Update-RunnerCrashGating -Exactly -Times 0
    }
    It 'keeps a typed source failure in the runner fault and recovery record' -ForEach @(
        @{Class='source_integrity'}, @{Class='network_timeout'}, @{Class='project_access_denied'}
    ) {
        $script:SourceClass = $Class
        $script:Config = New-LoopConfig -Enabled $false
        Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterCycleDispatch {
            $next = $script:Script.Dequeue()
            if ($next -eq 'pull-error') { return [pscustomobject]@{Outcome='pull-error';ExitCode=0;RecordFailureClass=$script:SourceClass;RecordDetail='fixture source rejected'} }
            $State.ShutdownState['Requested']=$true
            return [pscustomobject]@{Outcome='drain';ExitCode=0}
        }
        Mock -ModuleName Test.RunnerOuterLoop Wait-OuterInterruptible {
            $script:ObservedSourceFault = Get-Content -LiteralPath (Join-Path $script:Runtime 'status.json') -Raw | ConvertFrom-Json
            return $true
        }
        $null = Invoke-FakeLoop -ConfigPath $script:Config -Cycle @('pull-error','stop') -RepoRoot $script:Repo
        $script:ObservedSourceFault.runnerFault.failureClass | Should -BeExactly $Class
        (Read-RecoveryResult -RuntimeDir $script:Runtime).failureClass | Should -BeExactly $Class
    }
}

AfterAll { Remove-YurunaTestTempDir $script:LoopConfigDir }
