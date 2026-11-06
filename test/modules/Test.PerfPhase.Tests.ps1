<#PSScriptInfo
.VERSION 2026.11.05
.GUID 4200f649-efda-4869-a307-3b20e9e7843e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test perf phase budget wait-poll pester
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
    Pester coverage for the perf log beyond sequence steps: phase rows for the
    preamble, teardown, inter-cycle delay, failure pause and whole cycles; the
    poll loop of a wait folded into the step row; and the cycle-time budget a
    passing cycle is checked against.
.DESCRIPTION
    Perf rows covered sequence steps only, so a cycle that grew slower in its
    preamble, teardown or waits moved no row, and a passing cycle that took
    twice as long as usual passed green with nothing said.
    Run: Invoke-Pester -Path test/modules/Test.PerfPhase.Tests.ps1
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.Perf.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.RunnerHeartbeat.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.RunnerOuterLoop.psm1') -Force -Global -DisableNameChecking

    # A phase row for the budget history, written as the resident would.
    function script:Add-CycleRow {
        param([string]$Root, [long]$DurationMs, [string]$Outcome = 'pass', [DateTime]$EndUtc = [DateTime]::UtcNow, [string]$Phase = 'cycle')
        $dir = Join-Path $Root 'phases'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $row = [ordered]@{ schema = 1; recordKind = 'phase'; phase = $Phase; scope = 'resident'; outcome = $Outcome
            startedAtUtc = $EndUtc.AddMilliseconds(-$DurationMs).ToString('o'); endedAtUtc = $EndUtc.ToString('o'); durationMs = $DurationMs }
        Add-Content -LiteralPath (Join-Path $dir ($EndUtc.ToString('yyyy-MM-dd') + '.jsonl')) -Value (ConvertTo-Json -InputObject $row -Compress)
    }
}

Describe 'where phase rows go' {
    It 'writes beside the runtime folder of the process, so a test runtime never reaches test/status' {
        $savedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        try {
            $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive 'layout/status/runtime'
            Assert-Equal -Expected (Join-Path $TestDrive 'layout/status/perf') -Actual (Get-PerfPhaseRootDir)
        } finally { Restore-YurunaTestEnvironment -Saved $savedRuntime }
    }
}

Describe 'phase rows' {
    BeforeEach {
        $script:PerfRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        Mock -ModuleName Test.Perf Get-PerfPhaseRootDir { $script:PerfRoot }
        Mock -ModuleName Test.Perf Get-PerfHostUuid { 'host-uuid' }
    }

    It 'appends a duration row to the day''s phase file, named by the cycle generation' {
        $saved = Save-YurunaTestEnvironment -Name 'YURUNA_CYCLE_GENERATION'
        try {
            $env:YURUNA_CYCLE_GENERATION = 'runner:7'
            $end = [DateTime]::UtcNow
            Write-PerfPhaseRow -Phase 'teardown' -StartedAtUtc $end.AddSeconds(-12) -EndedAtUtc $end -Scope cycle
            $file = Join-Path $script:PerfRoot ('phases/' + $end.ToString('yyyy-MM-dd') + '.jsonl')
            $row = Get-Content -LiteralPath $file | ConvertFrom-Json
            Assert-Equal -Expected 'teardown' -Actual $row.phase
            Assert-Equal -Expected 'cycle' -Actual $row.scope
            Assert-Equal -Expected 'runner:7' -Actual $row.cycleGeneration
            Assert-Equal -Expected 12000 -Actual ([long]$row.durationMs)
            Assert-Equal -Expected 'phase' -Actual $row.recordKind
            Assert-False (Test-Path -LiteralPath (Join-Path $script:PerfRoot 'cycles')) 'step-row readers never see a phase row'
        } finally { Restore-YurunaTestEnvironment -Saved $saved }
    }

    It 'writes nothing on a host that turned the perf log off' {
        Mock -ModuleName Test.Perf Test-PerfLogEnabled { $false }
        Write-PerfPhaseRow -Phase 'teardown' -StartedAtUtc ([DateTime]::UtcNow) -EndedAtUtc ([DateTime]::UtcNow)
        Assert-False (Test-Path -LiteralPath (Join-Path $script:PerfRoot 'phases')) 'no phase file'
    }

    It 'times each preamble phase from its start to the next one, and the last to the handoff' {
        $savedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        try {
            $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive 'runtime-phases'
            $null = New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR -Force
            Mock -ModuleName Test.RunnerHeartbeat Write-PerfPhaseRow { }
            Write-RunnerPhase -Phase 'host-detect'
            Start-Sleep -Milliseconds 50
            Write-RunnerPhase -Phase 'vm-admission'
            Clear-RunnerPhase
            Should -Invoke -ModuleName Test.RunnerHeartbeat Write-PerfPhaseRow -Times 2 -Exactly
            Should -Invoke -ModuleName Test.RunnerHeartbeat Write-PerfPhaseRow -Times 1 -Exactly -ParameterFilter {
                $Phase -eq 'host-detect' -and $Scope -eq 'preamble' -and ($EndedAtUtc - $StartedAtUtc).TotalMilliseconds -ge 40 }
            Should -Invoke -ModuleName Test.RunnerHeartbeat Write-PerfPhaseRow -Times 1 -Exactly -ParameterFilter { $Phase -eq 'vm-admission' }
            Clear-RunnerPhase
            Should -Invoke -ModuleName Test.RunnerHeartbeat Write-PerfPhaseRow -Times 2 -Exactly -Because 'a second handoff has no open phase to close'
        } finally { Restore-YurunaTestEnvironment -Saved $savedRuntime }
    }

    It 'is written at the teardown, the inter-cycle delay, the failure pause and each dispatched cycle' {
        $inner = (Get-YurunaTestFileAst -Path (Join-Path $here 'Test.RunnerInnerLoop.psm1')).Extent.Text
        Assert-Match -Pattern "Write-PerfPhaseRow -Phase 'teardown'" -Actual $inner
        Assert-Match -Pattern "Write-PerfPhaseRow -Phase 'inter-cycle-delay'" -Actual $inner
        $outer = (Get-YurunaTestFileAst -Path (Join-Path $here 'Test.RunnerOuterLoop.psm1')).Extent.Text
        Assert-Match -Pattern "Write-PerfPhaseRow -Phase 'failure-pause'" -Actual $outer
        Assert-Match -Pattern 'Write-OuterCyclePhase -Cycle \$cycle' -Actual $outer
    }
}

Describe 'the poll loop of a wait reaches the step row' {
    BeforeEach {
        $script:RowsFile = Join-Path $TestDrive "rows-$([guid]::NewGuid().ToString('n')).jsonl"
        & (Get-Module Test.Perf) {
            param($File)
            $script:Cycle = @{ cycleStartUtc = '2026-10-26T00:00:00Z'; cycleFile = $File }
            $script:Sequence = $null; $script:Guest = $null; $script:WaitPoll = $null
        } $script:RowsFile
        $null = Set-PerfSequenceContext -SequenceName 'wait' -Confirm:$false
    }

    It 'counts the passes, sums their work net of the poll sleep, and resets for the next step' {
        $start = [DateTime]::UtcNow
        Add-PerfWaitPoll -WaitStartUtc $start -PollSeconds 0
        Start-Sleep -Milliseconds 60
        Add-PerfWaitPoll -WaitStartUtc $start -PollSeconds 0
        Start-Sleep -Milliseconds 30
        Add-PerfWaitPoll -WaitStartUtc $start -PollSeconds 0
        $now = [DateTime]::UtcNow
        Write-PerfStepRow -StepName 'waitForText' -StepOrdinal 1 -StartedAtUtc $start -EndedAtUtc $now -DurationMs 100 -Outcome pass
        Write-PerfStepRow -StepName 'next' -StepOrdinal 2 -StartedAtUtc $now -EndedAtUtc $now -DurationMs 0 -Outcome pass
        $rows = @(Get-Content -LiteralPath $script:RowsFile | ConvertFrom-Json)
        Assert-Equal -Expected 3 -Actual ([int]$rows[0].waitPolls)
        Assert-True ([long]$rows[0].waitWorkMs -ge 80) "the two timed passes add up: $($rows[0].waitWorkMs)"
        Assert-True ([long]$rows[0].waitPollMaxMs -ge 50) "the slowest pass: $($rows[0].waitPollMaxMs)"
        Assert-False ($rows[1].PSObject.Properties.Name -contains 'waitPolls') 'a step without a wait carries no wait fields'
    }

    It 'takes the poll sleep out of each pass' {
        $start = [DateTime]::UtcNow
        Add-PerfWaitPoll -WaitStartUtc $start -PollSeconds 10
        Add-PerfWaitPoll -WaitStartUtc $start -PollSeconds 10
        Write-PerfStepRow -StepName 'w' -StepOrdinal 1 -StartedAtUtc $start -EndedAtUtc $start -DurationMs 0 -Outcome pass
        $row = Get-Content -LiteralPath $script:RowsFile | ConvertFrom-Json
        Assert-Equal -Expected 0 -Actual ([long]$row.waitWorkMs) -Because 'a pass shorter than its sleep is floored at zero work'
    }

    It 'is fed from the top of Wait-ForText''s poll loop' {
        $fn = Get-YurunaTestFunctionAst -Path (Join-Path $here 'Test.SequenceEngine.psm1') -Name 'Wait-ForText'
        $loop = $fn.Body.Find({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] }, $true)
        Assert-NotNull $loop 'the poll loop'
        Assert-True ((Get-YurunaTestCommandCallCount -Ast $loop -CommandName 'Add-PerfWaitPoll') -ge 1) 'each pass is counted'
    }
}

Describe 'the cycle-time budget' {
    BeforeEach {
        $script:PerfRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        Mock -ModuleName Test.Perf Get-PerfPhaseRootDir { $script:PerfRoot }
        Mock -ModuleName Test.Perf Get-PerfHostUuid { 'host-uuid' }
    }

    It 'has no budget before five passing cycles' {
        foreach ($i in 1..4) { Add-CycleRow -Root $script:PerfRoot -DurationMs 60000 }
        $budget = Get-PerfCycleBudget
        Assert-Equal -Expected 4 -Actual $budget.Samples
        Assert-Null $budget.BudgetMs
    }

    It 'is 1.5 times the 90th percentile of the last twenty passing cycles' {
        foreach ($i in 1..30) { Add-CycleRow -Root $script:PerfRoot -DurationMs 999999 -EndUtc ([DateTime]::UtcNow.AddMinutes(-200 + $i)) }
        foreach ($i in 1..20) { Add-CycleRow -Root $script:PerfRoot -DurationMs (1000 * $i) }
        Add-CycleRow -Root $script:PerfRoot -DurationMs 5000000 -Outcome 'fail'
        Add-CycleRow -Root $script:PerfRoot -DurationMs 5000000 -Phase 'teardown'
        $budget = Get-PerfCycleBudget
        Assert-Equal -Expected 20 -Actual $budget.Samples -Because 'only the last twenty passing cycles count'
        Assert-Equal -Expected 18000 -Actual $budget.P90Ms
        Assert-Equal -Expected 27000 -Actual $budget.BudgetMs
    }

    It 'warns about a passing cycle over its budget, records it, and keeps the pass' {
        foreach ($i in 1..10) { Add-CycleRow -Root $script:PerfRoot -DurationMs 60000 }
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
        $end = [DateTime]::UtcNow
        $warnings = @(Write-OuterCyclePhase -Cycle 11 -Outcome 'completed' -ExitCode 0 -StartedAtUtc $end.AddSeconds(-120) -EndedAtUtc $end 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        Assert-Equal -Expected 1 -Actual $warnings.Count
        Assert-Match -Pattern '11' -Actual $warnings[0].Message
        Should -Invoke -ModuleName Test.RunnerOuterLoop Write-OuterLog -Times 1 -Exactly
        $last = Get-Content -LiteralPath (Join-Path $script:PerfRoot ('phases/' + $end.ToString('yyyy-MM-dd') + '.jsonl')) | Select-Object -Last 1 | ConvertFrom-Json
        Assert-Equal -Expected 'pass' -Actual $last.outcome -Because 'the budget reports; it never fails the cycle'
        Assert-True ([bool]$last.overBudget) 'the row says so'
        Assert-Equal -Expected 90000 -Actual ([long]$last.budgetMs)
    }

    It 'judges a cycle by the ones before it, and only a passing one' {
        foreach ($i in 1..10) { Add-CycleRow -Root $script:PerfRoot -DurationMs 60000 }
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
        $end = [DateTime]::UtcNow
        $within = Write-OuterCyclePhase -Cycle 11 -Outcome 'completed' -ExitCode 0 -StartedAtUtc $end.AddSeconds(-80) -EndedAtUtc $end 3>$null
        Assert-False $within.OverBudget 'inside the budget'
        $failed = Write-OuterCyclePhase -Cycle 12 -Outcome 'completed' -ExitCode 1 -StartedAtUtc $end.AddSeconds(-900) -EndedAtUtc $end 3>$null
        Assert-Equal -Expected 'fail' -Actual $failed.Outcome
        Assert-False $failed.OverBudget 'a failed cycle is not budget-checked'
        $gated = Write-OuterCyclePhase -Cycle 13 -Outcome 'refresh-gated' -StartedAtUtc $end -EndedAtUtc $end 3>$null
        Assert-Equal -Expected 'refresh-gated' -Actual $gated.Outcome
        Should -Invoke -ModuleName Test.RunnerOuterLoop Write-OuterLog -Times 0 -Exactly
    }
}
