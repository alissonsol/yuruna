<#PSScriptInfo
.VERSION 2026.10.11
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
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
# The loop reads testCycle.autoRemediation through the config reader, which needs the YAML module;
# without them the setting silently reads as off and every case below would pass for the wrong reason.
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { throw 'powershell-yaml is required for these cases.' }
Import-Module (Join-Path $here 'Test.Config.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.RecoveryContract.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.RecoveryLedger.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.RunnerOuterLoop.psm1') -Force -DisableNameChecking

function New-LoopConfig {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes a throwaway config file under the OS temp directory.')]
    param([bool]$Enabled, [int]$MaxAttempts = 1)
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('rol-' + [guid]::NewGuid().ToString('N') + '.yml')
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
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('rol-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Dir 'last_failure.json') -Value '{"failureClass":"wait_timeout"}' -Encoding utf8
        $script:SavedRuntime = $env:YURUNA_RUNTIME_DIR
        $script:SavedLog = $env:YURUNA_LOG_DIR
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
        if ($null -eq $script:SavedRuntime) { Remove-Item Env:\YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntime }
        if ($null -eq $script:SavedLog) { Remove-Item Env:\YURUNA_LOG_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_LOG_DIR = $script:SavedLog }
        Remove-Item -LiteralPath $script:Config -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
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

Describe 'Why a framework pull failed' {
    BeforeAll {
        # The caller's named arguments are of no interest here; they land in $args.
        function global:Test-GitWorktreeMerged {
            return $global:__pullMerged
        }
    }
    AfterAll {
        # The path form: the scope-qualified spelling removes nothing.
        Remove-Item -Path Function:\Test-GitWorktreeMerged -ErrorAction SilentlyContinue
        Remove-Variable __pullMerged -Scope Global -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $global:__pullMerged = $true
        $script:Pull = @{ ExitCode = 1; StdOut = ''; StdErr = '' }
        Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterNetworkGit {
            [pscustomobject]@{ ExitCode = $script:Pull.ExitCode; StdOut = $script:Pull.StdOut; StdErr = $script:Pull.StdErr; Output = ($script:Pull.StdErr + $script:Pull.StdOut) }
        }
    }

    It 'keeps the git output of a failed pull, redacted, for the cycle outcome record' {
        $script:Pull.StdErr = "fatal: Unable to create '/x/.git/index.lock': File exists.`nfatal: could not read from https://user:s3cr3t@github.com/x/y.git"
        Invoke-OuterGitPull -RepoRoot 'R' 6>$null | Should -BeFalse
        $why = Get-LastOuterPullFailure
        $why | Should -Match 'index\.lock'
        $why | Should -Not -Match 's3cr3t'
        $why | Should -Not -Match "`n"
    }
    It 'forgets the failure once a pull succeeds' {
        $script:Pull.StdErr = 'fatal: Unable to create index.lock'
        $null = Invoke-OuterGitPull -RepoRoot 'R' 6>$null
        Get-LastOuterPullFailure | Should -Not -BeNullOrEmpty
        $script:Pull.ExitCode = 0
        $script:Pull.StdErr = ''
        Invoke-OuterGitPull -RepoRoot 'R' 6>$null | Should -BeTrue
        Get-LastOuterPullFailure | Should -Be ''
    }
    It 'says why a pull that exited 0 is still not usable' {
        $script:Pull.ExitCode = 0
        $global:__pullMerged = $false
        Invoke-OuterGitPull -RepoRoot 'R' 6>$null | Should -BeFalse
        Get-LastOuterPullFailure | Should -Match 'conflict markers or unmerged'
    }
    It 'is what the pull-error outcome reports to the runner' {
        $text = Get-Content -LiteralPath (Join-Path $here 'Test.RunnerOuterLoop.psm1') -Raw
        $text | Should -Match "Outcome = 'pull-error'; ExitCode = 0; FailureClass = 'bootstrap_sync'; Detail = \(Get-LastOuterPullFailure\)"
    }
}

Describe 'A framework pull that fails on a stale git lock' {
    BeforeAll {
        $script:Git = (Get-Command git -ErrorAction SilentlyContinue)
    }
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('rolp-' + [guid]::NewGuid().ToString('N'))
        $script:Repo = Join-Path $script:Dir 'framework'
        New-Item -ItemType Directory -Path $script:Repo -Force | Out-Null
        $script:Runtime = Join-Path $script:Dir 'runtime'
        New-Item -ItemType Directory -Path $script:Runtime -Force | Out-Null
        if ($script:Git) {
            & git -C $script:Repo init --quiet 2>&1 | Out-Null
            & git -C $script:Repo -c user.name=t -c user.email=t@example.invalid commit --allow-empty -m init --quiet 2>&1 | Out-Null
            $script:Lock = Join-Path $script:Repo '.git/index.lock'
            Set-Content -LiteralPath $script:Lock -Value '' -NoNewline
            [IO.File]::SetLastWriteTimeUtc($script:Lock, [datetime]::UtcNow.AddHours(-2))
        }
        $script:SavedRuntime = $env:YURUNA_RUNTIME_DIR
        $script:SavedLog = $env:YURUNA_LOG_DIR
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
        if ($null -eq $script:SavedRuntime) { Remove-Item Env:\YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntime }
        if ($null -eq $script:SavedLog) { Remove-Item Env:\YURUNA_LOG_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_LOG_DIR = $script:SavedLog }
        Remove-Item -LiteralPath $script:Config -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
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
}
