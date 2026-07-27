<#PSScriptInfo
.VERSION 2026.07.26
.GUID 42b9d4e1-7c53-4a08-8bd6-0f92e5a37c14
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner cycle split pester
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
    Guards the once-per-runner / once-per-cycle boundary.
.DESCRIPTION
    Running a cycle in its own process is what lets an edit take effect without
    restarting the runner, but three startup routines become actively destructive
    if they run per cycle, and each fails silently rather than loudly:

      * the single-instance pidfile dance -- a child matches the same command-line
        pattern as its parent, so it classifies the parent as a competing runner
        and stops it;
      * the boot-recovery sweep -- it clears control.step-pause / control.cycle-pause,
        so an operator's pause would be dropped at every cycle boundary and the
        status-UI pause buttons would appear to do nothing;
      * runner-state initialization -- a fresh runId per cycle breaks run continuity
        on the event stream.

    These assert the boundary from the source AST, so a later edit that moves one of
    them into the per-cycle path fails here instead of on a live lab host.
#>

$ErrorActionPreference = 'Stop'
$testRoot   = Split-Path -Parent $PSScriptRoot
$cycleFile  = Join-Path $testRoot 'Invoke-TestCycleRunner.ps1'
$outerFile  = Join-Path $testRoot 'Invoke-TestRunner.ps1'
$loopModule = Join-Path $PSScriptRoot 'Test.RunnerOuterLoop.psm1'

Import-Module $loopModule -Force -DisableNameChecking

function Get-CommandNameList {
    param([string]$Path)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
}

Describe 'Per-cycle runner never performs once-per-runner startup' {
    $cycleCommands = Get-CommandNameList -Path $cycleFile
    $outerCommands = Get-CommandNameList -Path $outerFile

    It 'does not run the single-instance pidfile dance (it would stop its own parent)' {
        ($cycleCommands -contains 'Get-RunnerInstanceState') | Should -Be $false
        ($cycleCommands -contains 'Write-RunnerPidFile')     | Should -Be $false
        ($cycleCommands -contains 'Stop-StaleRunner')        | Should -Be $false
    }
    It 'does not run boot recovery (it would clear the operator pause flags every cycle)' {
        ($cycleCommands -contains 'Invoke-YurunaBootRecovery') | Should -Be $false
    }
    It 'does not re-initialize runner state (it would mint a new runId per cycle)' {
        ($cycleCommands -contains 'Initialize-RunnerState') | Should -Be $false
    }
    It 'leaves all three with the long-lived runner' {
        ($outerCommands -contains 'Get-RunnerInstanceState')   | Should -Be $true
        ($outerCommands -contains 'Invoke-YurunaBootRecovery')  | Should -Be $true
        ($outerCommands -contains 'Initialize-RunnerState')     | Should -Be $true
    }
    It 'spawns the cycle runner rather than the inner runner directly' {
        (Get-Content $outerFile -Raw) | Should -Match 'Invoke-TestCycleRunner\.ps1'
    }
}

Describe 'Cycle outcomes are reported, not acted on, inside the cycle' {
    $cycleFnText = (Get-Command Invoke-RunnerOuterCycle).Definition

    It 'never sleeps inside the cycle (the caller owns every wait, so Ctrl+C stays observable)' {
        # A Start-Sleep here runs where the operator's Ctrl+C flag does not exist,
        # so it could not be cut short. The loop holds the waits instead.
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($cycleFnText, [ref]$null, [ref]$null)
        $sleeps = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Sleep'
        }, $true))
        $sleeps.Count | Should -Be 0
    }
    It 'reports drain instead of flipping a shutdown flag the caller cannot see' {
        $cycleFnText | Should -Match "Outcome = 'drain'"
    }
}

Describe 'Wait-OuterInterruptible' {
    It 'returns immediately when shutdown is already requested' {
        $state = @{ Requested = $true }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $cut = Wait-OuterInterruptible -Seconds 30 -ShutdownState $state
        $sw.Stop()
        $cut | Should -Be $true
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 3
    }
    It 'sleeps in slices small enough to notice a shutdown mid-wait' {
        $state = @{ Requested = $false }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $cut = Wait-OuterInterruptible -Seconds 2 -ShutdownState $state -SliceSeconds 1
        $sw.Stop()
        $cut | Should -Be $false
        $sw.Elapsed.TotalSeconds | Should -BeGreaterThan 1
    }
}

Describe 'Cycle dispatch' {
    It 'falls back to running in-process when no cycle script is configured' {
        # Keeps the loop working if the script is missing, at the cost of the reload.
        $state = @{
            CycleScript = ''
            RepoRoot = $testRoot; ConfigPath = 'x'; InnerScript = 'x'; PwshExe = 'pwsh'
            ArgList = @(); ForwardEnvSnapshot = @{}; ShutdownState = @{ Requested = $false }
            NoGitPull = $true; FailurePauseMaxSeconds = 1; FailureCommitPollSeconds = 1
            OuterPullErrorSleepSec = 1; InnerSpawnErrorSleepSec = 1
            StepTimeoutMinutesDefault = 1; WatchdogPollSeconds = 1
        }
        Mock -CommandName Invoke-RunnerOuterCycle -MockWith {
            [pscustomobject]@{ Outcome = 'completed'; ExitCode = 7 }
        } -ModuleName Test.RunnerOuterLoop
        $r = Invoke-OuterCycleDispatch -State $state -Cycle 1
        $r.Outcome  | Should -Be 'completed'
        $r.ExitCode | Should -Be 7
    }
}
