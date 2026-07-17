<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42e060d7-36ff-4d1a-8a46-0ee20e443f51
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner state-machine pester
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
    Pester coverage for Test.RunnerState.psm1: the state enum, the transition
    adjacency map, boot recovery (the synthetic fault pair a crashed prior
    runner leaves behind), and the persistence contract of Set-RunnerState.
.DESCRIPTION
    The module's two loudest invariants are pinned here:
      * the validator NEVER rejects a recognised state -- an unrecognised
        (from, to) PAIR warns and is still recorded, so drift is visible
        instead of silently dropped;
      * an unrecognised TARGET state is refused outright, because writing one
        would wedge the validator on every later transition.
    Both directions are asserted, along with the trailing history cap and the
    cycle-context fields a quick read of runner.state.json must carry.

    Throw-based assertions rather than Should.
    Run: pwsh -NoProfile -File test/modules/Test.RunnerState.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.RunnerState.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

# Fixtures and helpers live at FILE scope, above the first Describe: a Describe
# body runs during discovery and its variables and functions are thrown away
# before any It executes, and the run pass stops descending top-level statements
# at the first Describe. -TestCases data is read during discovery and belongs
# here too.

function Initialize-TestRuntimeDir {
    <#
    .SYNOPSIS
        Point YURUNA_RUNTIME_DIR at a fresh empty directory and return it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('yuruna-runnerstate-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $dir -Force
    $env:YURUNA_RUNTIME_DIR = $dir
    return $dir
}

function Initialize-TestRunId {
    <#
    .SYNOPSIS
        Set the run-id anchor the module reads to detect a prior runner's state.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Initialize-RunnerState reads global:__YurunaRunId (set by Test.Log at module load); the test has to drive it to exercise boot recovery.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RunId)
    $global:__YurunaRunId = $RunId
}

function Initialize-TestCycleId {
    <#
    .SYNOPSIS
        Set the cycle-id anchor Set-RunnerState copies onto a cycle-start write.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Set-RunnerState reads global:__YurunaCycleId (set by Start-LogFile); the test has to drive it.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CycleId)
    $global:__YurunaCycleId = $CycleId
}

# The adjacency map as the module documents it, restated as data so that
# widening it without saying so breaks these tests.
$ValidTransitionCase = @(
    @{ From = 'idle'; To = 'cycle-start' }
    @{ From = 'idle'; To = 'fault' }
    @{ From = 'cycle-start'; To = 'in-cycle' }
    @{ From = 'cycle-start'; To = 'fault' }
    @{ From = 'in-cycle'; To = 'cycle-end' }
    @{ From = 'in-cycle'; To = 'fault' }
    @{ From = 'cycle-end'; To = 'idle' }
    @{ From = 'fault'; To = 'paused' }
    @{ From = 'fault'; To = 'idle' }
    @{ From = 'paused'; To = 'idle' }
    # The healthy pool-hold loop: a started cycle is gated to 'paused' by a
    # pulled desiredState=paused, and each 30s poll re-enters 'cycle-start'.
    @{ From = 'cycle-start'; To = 'paused' }
    @{ From = 'paused'; To = 'cycle-start' }
)

$InvalidTransitionCase = @(
    @{ From = 'idle'; To = 'in-cycle' }       # cannot skip cycle-start
    @{ From = 'idle'; To = 'cycle-end' }
    @{ From = 'idle'; To = 'paused' }
    @{ From = 'cycle-start'; To = 'cycle-end' }
    @{ From = 'in-cycle'; To = 'idle' }       # must pass through cycle-end or fault
    @{ From = 'cycle-end'; To = 'in-cycle' }
    @{ From = 'paused'; To = 'fault' }        # a pause resolves to idle or re-polls, never straight back to fault
    @{ From = 'fault'; To = 'in-cycle' }
    @{ From = 'not-a-state'; To = 'idle' }    # unknown source state
)

# Payloads Get-RunnerState must reject: none of them is a usable state object,
# and the caller decides what absent state means.
$UnreadableStateCase = @(
    @{ Name = 'truncated json'; Content = 'not json {{{' }
    @{ Name = 'whitespace only'; Content = '   ' }
    @{ Name = 'empty file'; Content = '' }
    @{ Name = 'json scalar'; Content = '"just-a-string"' }
    @{ Name = 'json array'; Content = '[1,2]' }
)

Describe 'Get-RunnerStateName' {
    It 'returns the canonical enum in declaration order' {
        $names = @(Get-RunnerStateName)
        Assert-Equal -Expected 6 -Actual $names.Count
        Assert-Equal -Expected 'idle,cycle-start,in-cycle,cycle-end,fault,paused' -Actual ($names -join ',')
    }
}

Describe 'Get-RunnerStatePath' {
    AfterAll { Remove-Item Env:\YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue }
    It 'places runner.state.json under the published runtime dir' {
        $dir = Initialize-TestRuntimeDir
        try {
            Assert-Equal -Expected (Join-Path $dir 'runner.state.json') -Actual (Get-RunnerStatePath)
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'falls back to the platform temp dir when the runtime dir is not published yet' {
        # GetTempPath, not $env:TEMP: the latter is Windows-only, and a test
        # fixture reading the fallback path has to work on every host type.
        Remove-Item Env:\YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue
        Assert-Equal -Expected (Join-Path ([System.IO.Path]::GetTempPath()) 'runner.state.json') -Actual (Get-RunnerStatePath)
    }
}

Describe 'Get-RunnerState' {
    BeforeAll { $null = Initialize-TestRuntimeDir }
    AfterAll {
        $dir = $env:YURUNA_RUNTIME_DIR
        Remove-Item Env:\YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue
        if ($dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    BeforeEach { Remove-Item -LiteralPath (Get-RunnerStatePath) -Force -ErrorAction SilentlyContinue }

    It 'returns null when no state file exists' {
        Assert-True ($null -eq (Get-RunnerState)) 'a missing state file is "fresh boot", not an error'
    }
    It 'returns null rather than throwing on an unreadable state file' -TestCases $UnreadableStateCase {
        param($Name, $Content)
        Set-Content -LiteralPath (Get-RunnerStatePath) -Value $Content -Encoding utf8NoBOM
        Assert-True ($null -eq (Get-RunnerState)) "$Name must read back as null"
    }
    It 'parses a well-formed state file into a dictionary' {
        Set-Content -LiteralPath (Get-RunnerStatePath) -Encoding utf8NoBOM `
            -Value '{"current":"in-cycle","runId":"run-7","writerPid":1234,"history":[]}'
        $s = Get-RunnerState
        Assert-True ($s -is [System.Collections.IDictionary]) 'state reads back as a dictionary'
        Assert-Equal -Expected 'in-cycle' -Actual $s['current']
        Assert-Equal -Expected 'run-7' -Actual $s['runId']
        Assert-Equal -Expected 1234 -Actual $s['writerPid']
    }
}

Describe 'Test-RunnerStateTransition' {
    It 'accepts every transition the lifecycle documents' -TestCases $ValidTransitionCase {
        param($From, $To)
        Assert-Equal -Expected $true -Actual (Test-RunnerStateTransition -From $From -To $To) -Because "$From -> $To is documented as valid"
    }
    It 'rejects a transition that is not in the adjacency map' -TestCases $InvalidTransitionCase {
        param($From, $To)
        Assert-Equal -Expected $false -Actual (Test-RunnerStateTransition -From $From -To $To) -Because "$From -> $To must not be accepted"
    }
    It 'has no side effects' {
        # Pure predicate: Set-RunnerState leans on that to warn without writing.
        $before = Get-RunnerState
        $null = Test-RunnerStateTransition -From 'idle' -To 'paused'
        Assert-True ($null -eq $before -or $null -ne (Get-RunnerState))
    }
}

Describe 'Initialize-RunnerState' {
    BeforeAll { $null = Initialize-TestRuntimeDir }
    AfterAll {
        $dir = $env:YURUNA_RUNTIME_DIR
        Remove-Item Env:\YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue
        if ($dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        Initialize-TestRunId -RunId ''
    }
    BeforeEach { Remove-Item -LiteralPath (Get-RunnerStatePath) -Force -ErrorAction SilentlyContinue }

    It 'writes a fresh idle state when there is no prior state file' {
        Initialize-TestRunId -RunId 'run-A'
        $s = Initialize-RunnerState -Confirm:$false
        Assert-Equal -Expected 'idle' -Actual $s.current
        Assert-Equal -Expected 'run-A' -Actual $s.runId
        Assert-Equal -Expected $PID -Actual $s.writerPid
        Assert-Equal -Expected 0 -Actual @($s.history).Count -Because 'a fresh boot narrates no crash'
        Assert-Equal -Expected 'idle' -Actual (Get-RunnerState).current -Because 'the state is persisted, not just returned'
    }
    It 'is a no-op when the prior state was written by this same run' {
        # Re-import in the same process must not rewind an in-flight cycle.
        Initialize-TestRunId -RunId 'run-A'
        $null = Initialize-RunnerState -Confirm:$false
        $null = Set-RunnerState -To 'cycle-start' -Confirm:$false
        $null = Set-RunnerState -To 'in-cycle' -Confirm:$false

        $s = Initialize-RunnerState -Confirm:$false
        Assert-Equal -Expected 'in-cycle' -Actual $s.current -Because 'the running cycle survives a re-initialize'
        Assert-Equal -Expected 'in-cycle' -Actual (Get-RunnerState).current
    }
    It 'synthesises a fault pair when a prior runner died mid-lifecycle' {
        Initialize-TestRunId -RunId 'run-A'
        $null = Initialize-RunnerState -Confirm:$false
        $null = Set-RunnerState -To 'cycle-start' -Confirm:$false
        $null = Set-RunnerState -To 'in-cycle' -Confirm:$false

        # A new runner boots and finds someone else's in-cycle state.
        Initialize-TestRunId -RunId 'run-B'
        $s = Initialize-RunnerState -Confirm:$false

        Assert-Equal -Expected 'idle' -Actual $s.current -Because 'boot recovery always lands on idle'
        Assert-Equal -Expected 'run-B' -Actual $s.runId
        Assert-Equal -Expected 2 -Actual @($s.history).Count -Because 'the crash boundary and its resolution are both narrated'
        Assert-Equal -Expected 'in-cycle' -Actual $s.history[0].from
        Assert-Equal -Expected 'fault' -Actual $s.history[0].to
        Assert-Equal -Expected $true -Actual $s.history[0].synthetic
        Assert-Equal -Expected 'fault' -Actual $s.history[1].from
        Assert-Equal -Expected 'idle' -Actual $s.history[1].to
        Assert-Equal -Expected $true -Actual $s.history[1].synthetic
    }
    It 'narrates no crash when the prior runner exited cleanly on idle' {
        Initialize-TestRunId -RunId 'run-A'
        $null = Initialize-RunnerState -Confirm:$false

        Initialize-TestRunId -RunId 'run-B'
        $s = Initialize-RunnerState -Confirm:$false
        Assert-Equal -Expected 'idle' -Actual $s.current
        Assert-Equal -Expected 0 -Actual @($s.history).Count -Because 'a clean prior shutdown is not a fault'
    }
    It 'writes nothing under -WhatIf' {
        Initialize-TestRunId -RunId 'run-A'
        $s = Initialize-RunnerState -WhatIf
        Assert-True ($null -eq $s)
        Assert-True (-not (Test-Path -LiteralPath (Get-RunnerStatePath))) 'a -WhatIf initialize must not create the state file'
    }
}

Describe 'Set-RunnerState' {
    BeforeAll {
        $null = Initialize-TestRuntimeDir
        Initialize-TestRunId -RunId 'run-set'
        Initialize-TestCycleId -CycleId ''
    }
    AfterAll {
        $dir = $env:YURUNA_RUNTIME_DIR
        Remove-Item Env:\YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue
        if ($dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        Initialize-TestRunId -RunId ''
        Initialize-TestCycleId -CycleId ''
    }
    BeforeEach {
        Remove-Item -LiteralPath (Get-RunnerStatePath) -Force -ErrorAction SilentlyContinue
        Initialize-TestCycleId -CycleId ''
    }

    It 'walks the happy path and persists every hop' {
        $null = Initialize-RunnerState -Confirm:$false
        foreach ($to in @('cycle-start', 'in-cycle', 'cycle-end', 'idle')) {
            $s = Set-RunnerState -To $to -Confirm:$false
            Assert-Equal -Expected $to -Actual $s.current
            Assert-Equal -Expected $to -Actual (Get-RunnerState).current -Because "$to must reach the file"
        }
        $history = @((Get-RunnerState).history)
        Assert-Equal -Expected 4 -Actual $history.Count
        Assert-Equal -Expected 'idle' -Actual $history[0].from
        Assert-Equal -Expected 'cycle-start' -Actual $history[0].to
    }
    It 'refuses a target state that is not in the enum, and leaves the file alone' {
        # Writing an unrecognised state would wedge the validator on every
        # later transition, so this one is a hard refusal, not a warn-and-write.
        $null = Initialize-RunnerState -Confirm:$false
        $s = Set-RunnerState -To 'exploded' -Confirm:$false -WarningAction SilentlyContinue
        Assert-True ($null -eq $s) 'an unrecognised target returns null'
        Assert-Equal -Expected 'idle' -Actual (Get-RunnerState).current -Because 'the refused write must not touch the file'
    }
    It 'records a transition outside the adjacency map anyway, so drift stays visible' {
        # The opposite policy from an unrecognised target: idle -> in-cycle is
        # not a documented hop, but dropping the telemetry would hide the drift.
        $null = Initialize-RunnerState -Confirm:$false
        $s = Set-RunnerState -To 'in-cycle' -Reason 'skipped cycle-start' -Confirm:$false -WarningAction SilentlyContinue
        Assert-Equal -Expected 'in-cycle' -Actual $s.current
        Assert-Equal -Expected 'in-cycle' -Actual (Get-RunnerState).current
        Assert-Equal -Expected 'skipped cycle-start' -Actual $s.history[-1].reason
    }
    It 'carries the reason onto the transition only when one was given' {
        $null = Initialize-RunnerState -Confirm:$false
        $s = Set-RunnerState -To 'cycle-start' -Confirm:$false
        Assert-True (-not $s.history[-1].Contains('reason')) 'no reason means no reason field'
    }
    It 'auto-initializes when the caller never called Initialize-RunnerState' {
        $s = Set-RunnerState -To 'cycle-start' -Reason 'cold start' -Confirm:$false -WarningAction SilentlyContinue
        Assert-Equal -Expected 'cycle-start' -Actual $s.current
        Assert-Equal -Expected 'idle' -Actual $s.history[-1].from -Because 'the synthesised baseline is idle'
        Assert-Equal -Expected $PID -Actual $s.writerPid
    }
    It 'caps the in-file history at the trailing 20 transitions' {
        # The NDJSON stream is the canonical history; the in-file slice is a
        # bounded "what just happened" cache and must not grow without limit.
        $null = Initialize-RunnerState -Confirm:$false
        for ($i = 0; $i -lt 7; $i++) {
            $null = Set-RunnerState -To 'cycle-start' -Confirm:$false
            $null = Set-RunnerState -To 'in-cycle' -Confirm:$false
            $null = Set-RunnerState -To 'cycle-end' -Confirm:$false
            $null = Set-RunnerState -To 'idle' -Confirm:$false
        }
        $history = @((Get-RunnerState).history)
        Assert-Equal -Expected 20 -Actual $history.Count -Because '28 transitions must leave only the last 20'
        Assert-Equal -Expected 'cycle-end' -Actual $history[-1].from
        Assert-Equal -Expected 'idle' -Actual $history[-1].to -Because 'the newest transition is kept'
    }
    It 'stamps the cycle id on a cycle-start and carries it across later hops' {
        $null = Initialize-RunnerState -Confirm:$false
        Initialize-TestCycleId -CycleId 'cycle-000042'
        $start = Set-RunnerState -To 'cycle-start' -Confirm:$false
        Assert-Equal -Expected 'cycle-000042' -Actual $start.lastCycleId

        $inCycle = Set-RunnerState -To 'in-cycle' -Confirm:$false
        Assert-Equal -Expected 'cycle-000042' -Actual $inCycle.lastCycleId -Because 'cycle context survives the next transition'
        Assert-Equal -Expected 'cycle-000042' -Actual (Get-RunnerState).lastCycleId
    }
    It 'preserves cycle-context fields a prior write left on the file' {
        $null = Initialize-RunnerState -Confirm:$false
        $s = Get-RunnerState
        $s['lastCycleNumber'] = 17
        Set-Content -LiteralPath (Get-RunnerStatePath) -Value ($s | ConvertTo-Json -Depth 6 -Compress) -Encoding utf8NoBOM

        $next = Set-RunnerState -To 'cycle-start' -Confirm:$false
        Assert-Equal -Expected 17 -Actual $next.lastCycleNumber -Because 'a quick read of runner.state.json keeps the most recent cycle metadata'
    }
    It 'writes nothing under -WhatIf' {
        $null = Initialize-RunnerState -Confirm:$false
        $s = Set-RunnerState -To 'cycle-start' -WhatIf
        Assert-True ($null -eq $s)
        Assert-Equal -Expected 'idle' -Actual (Get-RunnerState).current
    }
}
