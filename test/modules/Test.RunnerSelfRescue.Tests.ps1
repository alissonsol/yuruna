<#PSScriptInfo
.VERSION 2026.10.26
.GUID 42b2fd46-f55d-409b-bf93-6b7dbb5f5595
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner supervisor rescue ceiling pester
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
    Pins the ways the resident runner keeps a host cycling without an
    operator: it survives an exception that escapes its loop, it pulls the
    framework itself when cycle processes keep dying before they can, it stops
    a cycle process whose working time outlives its ceiling, and it applies the
    step watchdog's bounds itself when that watchdog stands down.
.DESCRIPTION
    Each mechanism exists because the layer below it can fail silently: a
    config read during the failure pause used to end the runner, a commit that
    broke the cycle process's imports used to stop every later pull, and a
    watchdog that stood down used to leave the cycle with no bound at all. The
    loop cases drive the real Invoke-RunnerOuterLoop with a faked dispatch; the
    ceiling case spawns a real process tree and checks that a grandchild dies.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The loop reads the runtime and log directories from environment variables; the fixtures set and restore them.')]
param()

BeforeAll {
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { throw 'powershell-yaml is required for these cases.' }
Import-Module (Join-Path $here '../../automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Config.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.RecoveryContract.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.RecoveryLedger.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.SingleInstance.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.RunnerOuterLoop.psm1') -Force -DisableNameChecking

function Get-RescueState {
    param([string]$ConfigPath, [bool]$NoGitPull = $true)
    return @{
        CycleScript = ''; RepoRoot = $PSScriptRoot; ConfigPath = $ConfigPath; InnerScript = 'x'; PwshExe = 'pwsh'; ArgList = @()
        ForwardEnvSnapshot = @{}; ShutdownState = @{ Requested = $false }; NoGitPull = $NoGitPull
        FailurePauseMaxSeconds = 1; FailureCommitPollSeconds = 1; OuterPullErrorSleepSeconds = 1; InnerSpawnErrorSleepSeconds = 1
        StepTimeoutSecondsDefault = 1; WatchdogPollSeconds = 1
    }
}

function Test-ProcessAlive {
    param([int]$ProcessId)
    return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}
}

Describe 'Source polls during the failure pause' {
    BeforeEach {
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
        Mock -ModuleName Test.RunnerOuterLoop Get-GitSourceConfiguration { throw 'mirror-key-invalid: not a key' }
    }
    It 'reports no new commits when the configuration cannot be read, instead of throwing' {
        Test-OuterNewCommitsAvailable -RepoRoot $PSScriptRoot -BaselineSha 'abc' -ConfigPath 'x.yml' | Should -BeFalse
        Should -Invoke -ModuleName Test.RunnerOuterLoop Write-OuterLog -Times 1 -Exactly -ParameterFilter { $Message -match 'framework' -and $Message -match 'mirror-key-invalid' }
    }
    It 'reports no remote SHA when the configuration cannot be read, instead of throwing' {
        Get-OuterRemoteSha -RemoteUrl 'https://example.invalid/repo.git' -ConfigPath 'x.yml' | Should -BeNullOrEmpty
        Should -Invoke -ModuleName Test.RunnerOuterLoop Write-OuterLog -Times 1 -Exactly -ParameterFilter { $Message -match 'project' }
    }
}

Describe 'Invoke-RunnerOuterSupervisor' {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('sup-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:SavedRuntime = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = $script:Dir
        $script:Config = Join-Path $script:Dir 'test.config.yml'
        Set-Content -LiteralPath $script:Config -Value "notification:`n  failuresBeforeAlert: 9`n" -Encoding utf8
        $script:Holds = [System.Collections.Generic.List[int]]::new()
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
        Mock -ModuleName Test.RunnerOuterLoop Write-Warning { }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterCommitSha { 'sha1' }
        Mock -ModuleName Test.RunnerOuterLoop Send-OuterCycleFailureNotification { $true }
        Mock -ModuleName Test.RunnerOuterLoop Wait-OuterInterruptible { $script:Holds.Add($Seconds); $false }
    }
    AfterEach {
        if ($null -eq $script:SavedRuntime) { Remove-Item Env:\YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntime }
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'logs an escaped exception, publishes a runner fault and enters the loop again' {
        $state = Get-RescueState -ConfigPath $script:Config
        $script:Calls = 0
        $loop = { param($S) $script:Calls++; if ($script:Calls -eq 1) { throw 'boom from the pause' }; $S.ShutdownState['Requested'] = $true }
        Invoke-RunnerOuterSupervisor -State $state -Loop $loop -BaseHoldSeconds 7
        $script:Calls | Should -Be 2
        $script:Holds | Should -Be @(7)
        Should -Invoke -ModuleName Test.RunnerOuterLoop Write-OuterLog -ParameterFilter { $Message -match 'boom from the pause' }
        $doc = Get-Content -Raw -LiteralPath (Join-Path $script:Dir 'status.json') | ConvertFrom-Json -AsHashtable
        $doc['runnerState'] | Should -Be 'paused'
        $doc['runnerFault']['failureClass'] | Should -Be 'script_error'
        $gating = Get-Content -Raw -LiteralPath (Join-Path $script:Dir 'runner.gating.json') | ConvertFrom-Json
        $gating.consecutiveFailures | Should -Be 1 -Because 'an escaped loop counts toward the crash alert'
    }
    It 'doubles the hold for each repeat within an hour, up to the cap' {
        $state = Get-RescueState -ConfigPath $script:Config
        $script:Calls = 0
        $loop = { param($S) $script:Calls++; if ($script:Calls -le 4) { throw "boom $script:Calls" }; $S.ShutdownState['Requested'] = $true }
        Invoke-RunnerOuterSupervisor -State $state -Loop $loop -BaseHoldSeconds 10 -MaxHoldSeconds 35
        $script:Holds | Should -Be @(10, 20, 35, 35)
    }
    It 'returns at once when the loop returns' {
        $state = Get-RescueState -ConfigPath $script:Config
        { Invoke-RunnerOuterSupervisor -State $state -Loop { param($S) $null = $S } } | Should -Not -Throw
        $script:Holds.Count | Should -Be 0
    }
    It 'stops a cycle process the escaped loop left running before entering the loop again' {
        $state = Get-RescueState -ConfigPath $script:Config
        Mock -ModuleName Test.RunnerOuterLoop Read-YurunaRunnerCycleRecord { [pscustomobject]@{ State = 'AliveOwned'; Pid = 424242 } }
        Mock -ModuleName Test.RunnerOuterLoop Stop-ProcessTree { }
        Mock -ModuleName Test.RunnerOuterLoop Clear-YurunaRunnerCycleRecord { $true }
        $script:Calls = 0
        $loop = { param($S) $script:Calls++; if ($script:Calls -eq 1) { throw 'boom' }; $S.ShutdownState['Requested'] = $true }
        Invoke-RunnerOuterSupervisor -State $state -Loop $loop
        Should -Invoke -ModuleName Test.RunnerOuterLoop Stop-ProcessTree -Times 1 -Exactly -ParameterFilter { $ProcessId -eq 424242 }
    }
    It 'continues the cycle numbering after re-entering the real loop, so no generation repeats' {
        $state = Get-RescueState -ConfigPath $script:Config
        $script:Generations = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Test.RunnerOuterLoop Import-OuterRefreshTriggerModule { $false }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterProjectUrl { '' }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterConfigMtime { $null }
        Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterCycleDispatch {
            $script:Generations.Add([string]$State['CycleGeneration'])
            if ($script:Generations.Count -ge 2) { $State.ShutdownState['Requested'] = $true; return [pscustomobject]@{ Outcome = 'drain'; ExitCode = 0; FromRecord = $true } }
            return [pscustomobject]@{ Outcome = 'completed'; ExitCode = 0; FromRecord = $true }
        }
        $script:Thrown = $false
        Mock -ModuleName Test.RunnerOuterLoop Publish-OuterRecoveryResult { if (-not $script:Thrown) { $script:Thrown = $true; throw 'first publish fails' }; $null }
        $null = Invoke-RunnerOuterSupervisor -State $state 3>$null 6>$null
        $script:Generations.Count | Should -Be 2
        $script:Generations[0] | Should -Match ':1$'
        $script:Generations[1] | Should -Match ':2$'
    }
}

Describe 'Update-OuterFrameworkHealth' {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('fwh-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:Sha = 'good1'
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterCommitSha { $script:Sha }
    }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'records the commit of a cycle that produced an outcome record as the last good one' {
        $h = Update-OuterFrameworkHealth -RuntimeDir $script:Dir -RepoRoot $PSScriptRoot -Outcome 'completed' -FromRecord
        $h.LastGoodSha | Should -Be 'good1'
        $h.RescueDue | Should -BeFalse
    }
    It 'calls for a rescue at the second unrecorded death at one commit, and survives a restart' {
        $null = Update-OuterFrameworkHealth -RuntimeDir $script:Dir -RepoRoot $PSScriptRoot -Outcome 'completed' -FromRecord
        $script:Sha = 'broken2'
        $first = Update-OuterFrameworkHealth -RuntimeDir $script:Dir -RepoRoot $PSScriptRoot -Outcome 'cycle-aborted'
        $first.RescueDue | Should -BeFalse
        $first.Streak | Should -Be 1
        # A new call reads the file again, which is what a runner restart does.
        $second = Update-OuterFrameworkHealth -RuntimeDir $script:Dir -RepoRoot $PSScriptRoot -Outcome 'outcome-unrecorded'
        $second.RescueDue | Should -BeTrue
        $second.Streak | Should -Be 2
        $second.LastGoodSha | Should -Be 'good1'
    }
    It 'starts the streak again when the commit changes' {
        $script:Sha = 'broken2'
        $null = Update-OuterFrameworkHealth -RuntimeDir $script:Dir -RepoRoot $PSScriptRoot -Outcome 'cycle-aborted'
        $script:Sha = 'broken3'
        (Update-OuterFrameworkHealth -RuntimeDir $script:Dir -RepoRoot $PSScriptRoot -Outcome 'cycle-aborted').Streak | Should -Be 1
    }
    It 'treats an abort that the cycle process itself recorded as proof the framework ran' {
        $h = Update-OuterFrameworkHealth -RuntimeDir $script:Dir -RepoRoot $PSScriptRoot -Outcome 'cycle-aborted' -FromRecord
        $h.Streak | Should -Be 0
        $h.LastGoodSha | Should -Be 'good1'
    }
    It 'leaves the record alone for a spawn failure or a shutdown' {
        $null = Update-OuterFrameworkHealth -RuntimeDir $script:Dir -RepoRoot $PSScriptRoot -Outcome 'cycle-aborted'
        (Update-OuterFrameworkHealth -RuntimeDir $script:Dir -RepoRoot $PSScriptRoot -Outcome 'spawn-failed').Streak | Should -Be 1
        (Update-OuterFrameworkHealth -RuntimeDir $script:Dir -RepoRoot $PSScriptRoot -Outcome 'shutdown').Streak | Should -Be 1
    }
}

Describe 'The resident pulls the framework when cycle processes keep dying before they can' {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('rsc-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:SavedRuntime = $env:YURUNA_RUNTIME_DIR
        $script:SavedLog = $env:YURUNA_LOG_DIR
        $env:YURUNA_RUNTIME_DIR = $script:Dir
        $env:YURUNA_LOG_DIR = $script:Dir
        $script:Config = Join-Path $script:Dir 'test.config.yml'
        Set-Content -LiteralPath $script:Config -Value "notification:`n  failuresBeforeAlert: 2`n" -Encoding utf8
        $script:Holds = [System.Collections.Generic.List[int]]::new()
        $script:Sent = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
        Mock -ModuleName Test.RunnerOuterLoop Write-Warning { }
        Mock -ModuleName Test.RunnerOuterLoop Import-OuterRefreshTriggerModule { $false }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterCommitSha { 'broken9' }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterProjectUrl { '' }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterConfigMtime { $null }
        Mock -ModuleName Test.RunnerOuterLoop Wait-OuterInterruptible { $script:Holds.Add($Seconds); $false }
        Mock -ModuleName Test.RunnerOuterLoop Send-OuterCycleFailureNotification { $script:Sent.Add([string]$ErrorMessage); $true }
        Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterGitPull { $true }
        $script:Aborts = 0
        Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterCycleDispatch {
            $script:Aborts++
            if ($script:Aborts -gt 3) { $State.ShutdownState['Requested'] = $true; return [pscustomobject]@{ Outcome = 'drain'; ExitCode = 0; FromRecord = $true } }
            return [pscustomobject]@{ Outcome = 'cycle-aborted'; ExitCode = 1 }
        }
    }
    AfterEach {
        if ($null -eq $script:SavedRuntime) { Remove-Item Env:\YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntime }
        if ($null -eq $script:SavedLog) { Remove-Item Env:\YURUNA_LOG_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_LOG_DIR = $script:SavedLog }
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'pulls from the resident from the second abort on, alerts once, and widens the hold' {
        $state = Get-RescueState -ConfigPath $script:Config -NoGitPull $false
        $null = Invoke-RunnerOuterLoop -State $state 3>$null 6>$null
        Should -Invoke -ModuleName Test.RunnerOuterLoop Invoke-OuterGitPull -Times 2 -Exactly
        $script:Holds | Should -Be @(1, 2, 4)
        $script:Sent.Count | Should -Be 1 -Because 'the streak alerts at failuresBeforeAlert and then stays disarmed'
        $script:Sent[0] | Should -Match 'broken9'
        $doc = Get-Content -Raw -LiteralPath (Join-Path $script:Dir 'status.json') | ConvertFrom-Json -AsHashtable
        $doc['runnerFault']['failureClass'] | Should -Be 'cycle_killed'
        $health = Get-Content -Raw -LiteralPath (Join-Path $script:Dir 'runner.framework-health.json') | ConvertFrom-Json
        $health.lastGoodSha | Should -Be 'broken9' -Because 'the drain at the end came from a record, which proves the framework ran'
    }
    It 'does not pull when the runner was started with -NoGitPull' {
        $state = Get-RescueState -ConfigPath $script:Config -NoGitPull $true
        $null = Invoke-RunnerOuterLoop -State $state 3>$null 6>$null
        Should -Invoke -ModuleName Test.RunnerOuterLoop Invoke-OuterGitPull -Times 0 -Exactly
    }
}

Describe 'Invoke-OuterFrameworkRescue reports what the pull did' {
    BeforeEach {
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
        Mock -ModuleName Test.RunnerOuterLoop Write-Warning { }
        $script:Health = [pscustomobject]@{ Sha = 'old1'; LastGoodSha = ''; Streak = 2; RescueDue = $true }
        $script:State = @{ RepoRoot = $PSScriptRoot; ConfigPath = 'x.yml'; NoGitPull = $false; CycleGeneration = '' }
    }
    It 'reports <Expected>' -TestCases @(
        @{ Pulled = $true; After = 'new2'; Expected = 'updated' }
        @{ Pulled = $true; After = 'old1'; Expected = 'unchanged' }
        @{ Pulled = $false; After = 'old1'; Expected = 'failed' }
    ) {
        param($Pulled, $After, $Expected)
        $env:RESCUE_PULLED = "$Pulled"; $env:RESCUE_AFTER = $After
        try {
            Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterGitPull { $env:RESCUE_PULLED -eq 'True' }
            Mock -ModuleName Test.RunnerOuterLoop Get-OuterCommitSha { $env:RESCUE_AFTER }
            Mock -ModuleName Test.RunnerOuterLoop Get-LastOuterPullFailure { 'fetch timed out' }
            Invoke-OuterFrameworkRescue -State $script:State -Health $script:Health -Outcome 'outcome-unrecorded' -Confirm:$false | Should -Be $Expected
            Should -Invoke -ModuleName Test.RunnerOuterLoop Write-OuterLog -ParameterFilter { $Message -match "none" -and $Message -match 'old1' }
        } finally { Remove-Item Env:RESCUE_PULLED, Env:RESCUE_AFTER -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-OuterMaxCycleSeconds' {
    BeforeEach {
        $script:Config = Join-Path ([System.IO.Path]::GetTempPath()) ('mcs-' + [guid]::NewGuid().ToString('N') + '.yml')
        Mock -ModuleName Test.RunnerOuterLoop Write-Warning { }
    }
    AfterEach { Remove-Item -LiteralPath $script:Config -Force -ErrorAction SilentlyContinue }
    It 'reads <Value> as <Expected>' -TestCases @(
        @{ Value = '7200'; Expected = 7200 }
        @{ Value = '0'; Expected = 0 }
        @{ Value = 'six-hours'; Expected = 21600 }
    ) {
        param($Value, $Expected)
        Set-Content -LiteralPath $script:Config -Value "testCycle:`n  maxCycleSeconds: $Value`n" -Encoding utf8
        Get-OuterMaxCycleSeconds -ConfigPath $script:Config -DefaultSeconds 21600 | Should -Be $Expected
    }
    It 'uses the default when the key is absent' {
        Set-Content -LiteralPath $script:Config -Value "testCycle:`n  stepTimeoutSeconds: 3600`n" -Encoding utf8
        Get-OuterMaxCycleSeconds -ConfigPath $script:Config -DefaultSeconds 21600 | Should -Be 21600
    }
    It 'is a key of the tracked template, so cycle-start reconciliation keeps it' {
        $template = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../test.config.yml.template') | ConvertFrom-Yaml
        $template['testCycle']['maxCycleSeconds'] | Should -Be 21600
    }
}

Describe 'The resident stops a cycle process at testCycle.maxCycleSeconds' -Skip:$IsWindows {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('ceil-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:SavedRuntime = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = $script:Dir
        $script:GrandchildFile = Join-Path $script:Dir 'grandchild.pid'
        $script:CycleScript = Join-Path $script:Dir 'cycle.ps1'
        # A cycle that never ends, holding a grandchild the way an inner holds a capture.
        Set-Content -LiteralPath $script:CycleScript -Encoding utf8 -Value @"
param([int]`$Cycle, [string]`$CycleGeneration)
`$g = Start-Process -FilePath /bin/sleep -ArgumentList '300' -PassThru
Set-Content -LiteralPath '$($script:GrandchildFile)' -Value `$g.Id
Start-Sleep -Seconds 300
"@
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
        Mock -ModuleName Test.RunnerOuterLoop Write-Warning { }
        $script:Generation = ('d' * 32) + ':3'
        $script:State = @{
            CycleScript = $script:CycleScript; PwshExe = (Get-Process -Id $PID).Path; ShutdownState = @{ Requested = $false }
            CycleGeneration = $script:Generation; MaxCycleSecondsDefault = 3
        }
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:GrandchildFile) {
            $grandchild = [int](Get-Content -Raw -LiteralPath $script:GrandchildFile)
            Stop-Process -Id $grandchild -Force -ErrorAction SilentlyContinue
        }
        if ($null -eq $script:SavedRuntime) { Remove-Item Env:\YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntime }
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'kills the whole tree, records the stop for this attempt and reports a ceiling outcome' {
        $r = Invoke-OuterCycleDispatch -State $script:State -Cycle 3
        $r.Outcome | Should -Be 'outcome-unrecorded'
        $r.OutcomeReason | Should -Be 'cycle-ceiling'
        $r.OutcomeDetail | Should -Match 'maxCycleSeconds'
        Test-Path -LiteralPath $script:GrandchildFile | Should -BeTrue -Because 'the fixture started its grandchild before the ceiling'
        $grandchild = [int](Get-Content -Raw -LiteralPath $script:GrandchildFile)
        $deadline = [datetime]::UtcNow.AddSeconds(5)
        while ((Test-ProcessAlive -ProcessId $grandchild) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
        Test-ProcessAlive -ProcessId $grandchild | Should -BeFalse -Because 'a ceiling stop reaches below the direct children'
        $kill = Get-Content -Raw -LiteralPath (Join-Path $script:Dir 'runner.watchdog-kill.json') | ConvertFrom-Json
        $kill.failureClass | Should -Be 'cycle_killed'
        $kill.attemptGeneration | Should -Be $script:Generation
        $fault = Get-RunnerAttemptFault -RuntimeDir $script:Dir -AttemptGeneration $script:Generation -SpawnedAtUtc ([datetime]::UtcNow.AddMinutes(-5))
        $fault.FailureClass | Should -Be 'cycle_killed'
    }
    It 'maps a ceiling stop to an aborted cycle_killed recovery result' {
        $result = ConvertTo-RunnerRecoveryResult -Dispatch ([pscustomobject]@{ Outcome = 'outcome-unrecorded'; ExitCode = 137; OutcomeReason = 'cycle-ceiling'; OutcomeDetail = 'reached testCycle.maxCycleSeconds' }) `
            -CycleGeneration $script:Generation -LogDir $script:Dir -RuntimeDir $script:Dir
        $result['outcome'] | Should -Be 'aborted'
        $result['failureClass'] | Should -Be 'cycle_killed'
        $result['stage'] | Should -Be 'CycleCeiling'
    }

    # Pauses, lab holds and debug breaks are time an operator chose to spend; a
    # cycle paused past the ceiling used to be stopped right after it resumed.
    It 'does not count held time toward the ceiling' {
        Set-Content -LiteralPath $script:CycleScript -Encoding utf8 -Value @"
param([int]`$Cycle, [string]`$CycleGeneration)
`$flag = Join-Path '$($script:Dir)' 'control.step-pause'
Set-Content -LiteralPath `$flag -Value 'held'
Start-Sleep -Seconds 5
Remove-Item -LiteralPath `$flag -Force
Start-Sleep -Seconds 300
"@
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-OuterCycleDispatch -State $script:State -Cycle 3
        $watch.Stop()
        $r.OutcomeReason | Should -Be 'cycle-ceiling'
        $watch.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 7 -Because 'five held seconds do not count toward a three-second ceiling'
    }

    It 'raises the ceiling to two step timeouts for each run the cycle plans' {
        Set-Content -LiteralPath $script:CycleScript -Encoding utf8 -Value @"
param([int]`$Cycle, [string]`$CycleGeneration)
`$doc = [ordered]@{ cycleStartUtc = [DateTime]::UtcNow.AddSeconds(1).ToString('o'); guests = @(@{ guestKey = 'a' }, @{ guestKey = 'b' }, @{ guestKey = 'c' }) }
Set-Content -LiteralPath (Join-Path '$($script:Dir)' 'status.json') -Value (`$doc | ConvertTo-Json -Depth 4)
Start-Sleep -Seconds 300
"@
        $script:State.MaxCycleSecondsDefault = 2
        $script:State.StepTimeoutSecondsDefault = 1
        $script:State.PlanPollSeconds = 1
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-OuterCycleDispatch -State $script:State -Cycle 3
        $watch.Stop()
        $r.OutcomeReason | Should -Be 'cycle-ceiling'
        $watch.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 5 -Because 'three runs at two one-second step timeouts each outlast the two-second floor'
        $r.OutcomeDetail | Should -Match '\b6 s\b'
        Should -Invoke -ModuleName Test.RunnerOuterLoop Write-OuterLog -ParameterFilter { $Message -match 'plans 3 run' }
    }
}

# The step watchdog stands down whenever it cannot prove the inner's identity,
# and its lapse used to leave the cycle bounded only by the ceiling: hours of a
# hang nobody stopped. The resident now applies the watchdog's own bounds.
Describe 'The resident guards a cycle whose step watchdog stood down' -Skip:$IsWindows {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('guard-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:SavedRuntime = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = $script:Dir
        $script:GrandchildFile = Join-Path $script:Dir 'grandchild.pid'
        $script:CycleScript = Join-Path $script:Dir 'cycle.ps1'
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
        Mock -ModuleName Test.RunnerOuterLoop Write-Warning { }
        $script:Generation = ('e' * 32) + ':4'
        $script:State = @{
            CycleScript = $script:CycleScript; PwshExe = (Get-Process -Id $PID).Path; ShutdownState = @{ Requested = $false }
            CycleGeneration = $script:Generation; MaxCycleSecondsDefault = 60; StepTimeoutSecondsDefault = 2
        }
        # A cycle whose watchdog stood down, holding a grandchild, whose heartbeat
        # and phase each fixture sets up after the lapse.
        $script:WriteCycle = {
            param([string]$Lapse, [string]$Body = '')
            Set-Content -LiteralPath $script:CycleScript -Encoding utf8 -Value @"
param([int]`$Cycle, [string]`$CycleGeneration)
`$g = Start-Process -FilePath /bin/sleep -ArgumentList '300' -PassThru
Set-Content -LiteralPath '$($script:GrandchildFile)' -Value `$g.Id
Set-Content -LiteralPath (Join-Path '$($script:Dir)' 'runner.watchdog.lapsed') -Value '$Lapse'
$Body
Start-Sleep -Seconds 300
"@
        }
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:GrandchildFile) {
            Stop-Process -Id ([int](Get-Content -Raw -LiteralPath $script:GrandchildFile)) -Force -ErrorAction SilentlyContinue
        }
        if ($null -eq $script:SavedRuntime) { Remove-Item Env:\YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntime }
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'stops the tree at the step bound the watchdog recorded, as a wait_timeout for this attempt' {
        & $script:WriteCycle '2026-10-24T10:00:00Z inner.pid never appeared in 180s [stepSeconds=2 preambleSeconds=1]'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-OuterCycleDispatch -State $script:State -Cycle 4
        $watch.Stop()
        $r.Outcome | Should -Be 'outcome-unrecorded'
        $r.OutcomeReason | Should -Be 'resident-watchdog'
        $r.RecordFailureClass | Should -Be 'wait_timeout'
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 30 -Because 'the step bound, not the 60-second ceiling, ended the cycle'
        $grandchild = [int](Get-Content -Raw -LiteralPath $script:GrandchildFile)
        $deadline = [datetime]::UtcNow.AddSeconds(5)
        while ((Test-ProcessAlive -ProcessId $grandchild) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
        Test-ProcessAlive -ProcessId $grandchild | Should -BeFalse -Because 'the stop reaches below the direct children'
        $kill = Get-Content -Raw -LiteralPath (Join-Path $script:Dir 'runner.watchdog-kill.json') | ConvertFrom-Json
        $kill.failureClass | Should -Be 'wait_timeout'
        $kill.attemptGeneration | Should -Be $script:Generation
        $kill.timeoutSeconds | Should -Be 2
        $fault = Get-RunnerAttemptFault -RuntimeDir $script:Dir -AttemptGeneration $script:Generation -SpawnedAtUtc ([datetime]::UtcNow.AddMinutes(-5))
        $fault.FailureClass | Should -Be 'wait_timeout'
    }
    It 'applies the preamble bound and names the phase while runner.phase exists' {
        & $script:WriteCycle 'lapse [stepSeconds=30 preambleSeconds=1]' "Set-Content -LiteralPath (Join-Path '$($script:Dir)' 'runner.phase') -Value 'caching-proxy-gate'"
        $r = Invoke-OuterCycleDispatch -State $script:State -Cycle 4
        $r.OutcomeReason | Should -Be 'resident-watchdog'
        $r.RecordFailureClass | Should -Be 'preamble_stall'
        $r.OutcomeDetail | Should -Match 'caching-proxy-gate'
        (Get-Content -Raw -LiteralPath (Join-Path $script:Dir 'runner.watchdog-kill.json') | ConvertFrom-Json).phase | Should -Be 'caching-proxy-gate'
        $fault = Get-RunnerAttemptFault -RuntimeDir $script:Dir -AttemptGeneration $script:Generation -SpawnedAtUtc ([datetime]::UtcNow.AddMinutes(-5))
        $fault.StalledPhase | Should -Be 'caching-proxy-gate'
    }
    It 'leaves a cycle alone while its step heartbeat moves' {
        $refresh = "`$hb = Join-Path '$($script:Dir)' 'runner.stepHeartbeat'`nforeach (`$i in 1..40) { Set-Content -LiteralPath `$hb -Value `$i; Start-Sleep -Milliseconds 250 }"
        & $script:WriteCycle 'lapse [stepSeconds=2 preambleSeconds=1]' $refresh
        $script:State.MaxCycleSecondsDefault = 6
        $r = Invoke-OuterCycleDispatch -State $script:State -Cycle 4
        $r.OutcomeReason | Should -Be 'cycle-ceiling' -Because 'a heartbeat that moves is progress, so only the ceiling stops this cycle'
    }
    It 'falls back to the configured bounds when the sentinel names none' {
        & $script:WriteCycle 'inner.pid present but unreadable'
        $r = Invoke-OuterCycleDispatch -State $script:State -Cycle 4
        $r.OutcomeReason | Should -Be 'resident-watchdog'
        (Get-Content -Raw -LiteralPath (Join-Path $script:Dir 'runner.watchdog-kill.json') | ConvertFrom-Json).timeoutSeconds | Should -Be 2
    }
    It 'maps the stop to an aborted recovery result with the watchdog''s class (<RecordClass>)' -TestCases @(
        @{ RecordClass = 'wait_timeout'; Expected = 'wait_timeout' }
        @{ RecordClass = 'preamble_stall'; Expected = 'preamble_stall' }
        @{ RecordClass = 'not-a-class'; Expected = 'wait_timeout' }
    ) {
        param($RecordClass, $Expected)
        $result = ConvertTo-RunnerRecoveryResult -Dispatch ([pscustomobject]@{ Outcome = 'outcome-unrecorded'; ExitCode = 137; OutcomeReason = 'resident-watchdog'; OutcomeDetail = 'step heartbeat stale'; RecordFailureClass = $RecordClass }) `
            -CycleGeneration $script:Generation -LogDir $script:Dir -RuntimeDir $script:Dir
        $result['outcome'] | Should -Be 'aborted'
        $result['failureClass'] | Should -Be $Expected
        $result['stage'] | Should -Be 'ResidentWatchdog'
    }
}

Describe 'Cycle ceiling and guard helpers' {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('ceilh-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
    }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'derives <Expected> s from <Configured> s, a <Step> s step timeout and <Runs> run(s)' -TestCases @(
        @{ Configured = 21600; Step = 3600; Runs = 0; Expected = 21600 }
        @{ Configured = 21600; Step = 3600; Runs = 3; Expected = 21600 }
        @{ Configured = 21600; Step = 3600; Runs = 6; Expected = 43200 }
        @{ Configured = 7200; Step = 3600; Runs = 2; Expected = 14400 }
        @{ Configured = 0; Step = 3600; Runs = 6; Expected = 0 }
        @{ Configured = -1; Step = 3600; Runs = 6; Expected = 0 }
        @{ Configured = 21600; Step = 3600; Runs = 2000000; Expected = [int]::MaxValue }
    ) {
        param($Configured, $Step, $Runs, $Expected)
        Get-OuterCycleCeilingSeconds -ConfiguredSeconds $Configured -StepTimeoutSeconds $Step -PlannedRunCount $Runs | Should -Be $Expected
    }
    It 'counts the plan of the cycle this attempt spawned and nothing else' {
        $spawned = [datetime]::UtcNow
        $status = Join-Path $script:Dir 'status.json'
        Get-OuterCyclePlannedRunCount -RuntimeDir $script:Dir -SpawnedAtUtc $spawned | Should -Be 0 -Because 'no plan is published yet'
        Set-Content -LiteralPath $status -Value (@{ cycleStartUtc = $spawned.AddMinutes(-30).ToString('o'); guests = @(@{}, @{}) } | ConvertTo-Json)
        Get-OuterCyclePlannedRunCount -RuntimeDir $script:Dir -SpawnedAtUtc $spawned | Should -Be 0 -Because 'the last cycle''s plan is not this one''s'
        Set-Content -LiteralPath $status -Value '{"cycleStartUtc": "'
        Get-OuterCyclePlannedRunCount -RuntimeDir $script:Dir -SpawnedAtUtc $spawned | Should -Be 0 -Because 'a half-written record is no plan'
        Set-Content -LiteralPath $status -Value (@{ cycleStartUtc = $spawned.AddSeconds(5).ToString('o'); guests = @(@{}, @{}, @{}) } | ConvertTo-Json)
        Get-OuterCyclePlannedRunCount -RuntimeDir $script:Dir -SpawnedAtUtc $spawned | Should -Be 3
    }
    It 'reads a hold from <Name>' -TestCases @(
        @{ Name = 'control.step-pause' }, @{ Name = 'control.cycle-pause' }, @{ Name = 'control.pause' },
        @{ Name = 'control.lab-hold' }, @{ Name = 'break-active.json' }
    ) {
        param($Name)
        Test-OuterCycleHeld -RuntimeDir $script:Dir | Should -BeFalse
        Set-Content -LiteralPath (Join-Path $script:Dir $Name) -Value 'x'
        Test-OuterCycleHeld -RuntimeDir $script:Dir | Should -BeTrue
    }
    It 'reads the bounds a lapse recorded, and nothing from a sentinel without them' {
        $lapse = Join-Path $script:Dir 'runner.watchdog.lapsed'
        Read-OuterWatchdogLapseBound -Path $lapse | Should -BeNullOrEmpty
        Set-Content -LiteralPath $lapse -Value '2026-10-24T10:00:00Z inner.pid never appeared in 180s'
        Read-OuterWatchdogLapseBound -Path $lapse | Should -BeNullOrEmpty
        Set-Content -LiteralPath $lapse -Value '2026-10-24T10:00:00Z why [stepSeconds=0 preambleSeconds=600]'
        Read-OuterWatchdogLapseBound -Path $lapse | Should -BeNullOrEmpty -Because 'a zero step bound would stop every cycle at once'
        Set-Content -LiteralPath $lapse -Value '2026-10-24T10:00:00Z why [stepSeconds=5400 preambleSeconds=600]'
        $bound = Read-OuterWatchdogLapseBound -Path $lapse
        $bound.StepSeconds | Should -Be 5400
        $bound.PreambleSeconds | Should -Be 600
    }
    It 'measures staleness from the last heartbeat change it saw, with the watchdog''s phase rule' {
        $fakeWatch = [pscustomobject]@{ Restarts = 0 }
        $fakeWatch | Add-Member -MemberType ScriptProperty -Name Elapsed -Value { [timespan]::FromSeconds($script:FakeElapsed) }
        $fakeWatch | Add-Member -MemberType ScriptMethod -Name Restart -Value { $this.Restarts++; $script:FakeElapsed = 0 }
        $guard = @{ Watch = $fakeWatch; LastWriteUtc = $null; StepSeconds = 60; PreambleSeconds = 10 }
        $script:FakeElapsed = 30
        Step-OuterHeartbeatGuard -Guard $guard -RuntimeDir $script:Dir | Should -BeNullOrEmpty -Because '30 s is inside the 60 s step bound'
        Set-Content -LiteralPath (Join-Path $script:Dir 'runner.phase') -Value 'bootstrap'
        $stall = Step-OuterHeartbeatGuard -Guard $guard -RuntimeDir $script:Dir
        $stall.BoundSeconds | Should -Be 10
        $stall.Phase | Should -Be 'bootstrap'
        Set-Content -LiteralPath (Join-Path $script:Dir 'runner.stepHeartbeat') -Value 'beat'
        Step-OuterHeartbeatGuard -Guard $guard -RuntimeDir $script:Dir | Should -BeNullOrEmpty -Because 'a new heartbeat restarts the clock'
        $fakeWatch.Restarts | Should -Be 1
        Remove-Item -LiteralPath (Join-Path $script:Dir 'runner.phase')
        $script:FakeElapsed = 61
        $stall = Step-OuterHeartbeatGuard -Guard $guard -RuntimeDir $script:Dir
        $stall.BoundSeconds | Should -Be 60
        $stall.Phase | Should -Be ''
        $stall.AgeSeconds | Should -Be 61
    }
}
