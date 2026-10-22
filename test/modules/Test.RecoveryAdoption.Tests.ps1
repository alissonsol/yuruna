<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42ca3251-686b-4dc2-8cb3-c234aec016e5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test recovery adoption entry-point pester
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
    Pins that all three entry points take their checkout, admission, replay and
    outcome steps from the shared recovery contract instead of re-implementing
    them, and that the module sets load what they need.
.DESCRIPTION
    A shared contract only helps while every entry point goes through it. These
    cases read the entry-point sources and the module sets and fail when one of
    them calls a wrapped command directly again, drops the step that records its
    typed result, or loses a module from its set. They are static on purpose: the
    behavior of each step is covered where the step lives.
#>

param()

BeforeAll {
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$script:TestRoot = Split-Path -Parent $here
$script:Sources = @{}
foreach ($rel in 'Debug-TestSequence.ps1', 'Invoke-TestProject.ps1', 'modules/Invoke-TestRunnerInnerLoop.ps1', 'modules/Invoke-TestCycleRunner.ps1',
                 'modules/Test.RunnerInnerLoop.psm1', 'modules/Test.RunnerOuterLoop.psm1', 'modules/Test.Prelude.psm1') {
    $script:Sources[$rel] = Get-Content -LiteralPath (Join-Path $script:TestRoot $rel) -Raw
}

function Get-CommandName {
    param([string]$Rel)
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:Sources[$Rel], [ref]$null, [ref]$null)
    return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
}

function Get-ModuleSet {
    param([string]$Kind)
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:Sources['modules/Test.Prelude.psm1'], [ref]$null, [ref]$null)
    # The sets are the entries of one hashtable literal: Outer = @(...), Inner = @(...), and so on.
    $table = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] -and @($n.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'Outer' }).Count -gt 0 }, $true)
    $entry = @($table.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq $Kind })[0]
    return @($entry.Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -like '*.psm1' }, $true) | ForEach-Object { $_.Value })
}
}

Describe 'Every entry point goes through the shared steps' {
    It 'Debug-TestSequence refreshes the checkout and asks admission through the steps, never the wrapped commands' {
        $calls = Get-CommandName 'Debug-TestSequence.ps1'
        @($calls | Where-Object { $_ -eq 'Invoke-CycleCheckoutStep' }).Count | Should -Be 1
        @($calls | Where-Object { $_ -eq 'Invoke-CycleAdmissionStep' }).Count | Should -Be 2 -Because 'one for an orchestration run and one for a guest run'
        $calls | Should -Not -Contain 'Update-ProjectClone'
        $calls | Should -Not -Contain 'Invoke-HostVmAdmission'
    }
    It 'Debug-TestSequence records its typed result on every exit and leaves a nested run to its owner' {
        $text = $script:Sources['Debug-TestSequence.ps1']
        $text | Should -Match 'function Save-SequenceRecoveryResult'
        $text | Should -Match 'if \(\$isNested -or -not \(Get-Command Save-RecoveryResult'
        # Each early exit saves first; the main run saves in its finally block.
        ([regex]::Matches($text, 'Save-SequenceRecoveryResult -ExitCode')).Count | Should -BeGreaterOrEqual 5
    }
    It 'Invoke-TestProject refreshes the checkout through the step and records its result when it stops' {
        $calls = Get-CommandName 'Invoke-TestProject.ps1'
        $calls | Should -Contain 'Invoke-CycleCheckoutStep'
        $calls | Should -Not -Contain 'Update-ProjectClone'
        $text = $script:Sources['Invoke-TestProject.ps1']
        $text | Should -Match 'Save-RecoveryResult -EntryPoint project -ExitCode \$Code'
        $text | Should -Match 'Save-RecoveryResult -EntryPoint project -ExitCode \$innerExit'
    }
    It 'the inner runner asks admission through the step and exits with the step''s code' {
        $calls = Get-CommandName 'modules/Invoke-TestRunnerInnerLoop.ps1'
        $calls | Should -Contain 'Invoke-CycleAdmissionStep'
        $calls | Should -Not -Contain 'Invoke-HostVmAdmission'
        $script:Sources['modules/Invoke-TestRunnerInnerLoop.ps1'] | Should -Match 'exit \$admissionStep\.ExitCode'
    }
    It 'the inner runner module takes its checkout and replay decisions from the steps' {
        $calls = Get-CommandName 'modules/Test.RunnerInnerLoop.psm1'
        $calls | Should -Contain 'Invoke-CycleCheckoutStep'
        $calls | Should -Contain 'Resolve-CycleReplayStep'
        $calls | Should -Not -Contain 'Update-ProjectClone'
        foreach ($inline in 'Get-WarmResumeRewindStep', 'Get-WarmResumeStepAction', 'Get-WarmResumeBoundarySnapshotId', 'Test-WarmResumeReplayIsSafe', 'Test-VMDiskSnapshot') {
            $calls | Should -Not -Contain $inline -Because "the replay decision moved into Resolve-WarmResumeReplayPlan; $inline must not be called inline again"
        }
    }
    It 'the cycle process publishes its outcome through the contract module' {
        $calls = Get-CommandName 'modules/Invoke-TestCycleRunner.ps1'
        $calls | Should -Contain 'Publish-CycleOutcomeRecord'
        $calls | Should -Not -Contain 'Publish-OuterCycleOutcome'
    }
    It 'the outer loop reports and recovers through the contract and the ledger' {
        $calls = Get-CommandName 'modules/Test.RunnerOuterLoop.psm1'
        foreach ($name in 'Read-CycleOutcomeRecord', 'Read-VmAdmissionRecord', 'ConvertTo-RunnerRecoveryResult', 'Write-RecoveryResult', 'Invoke-RecoveryForResult', 'Invoke-RecoveryAction', 'Complete-RecoveryFingerprint') {
            $calls | Should -Contain $name
        }
        $script:Sources['modules/Test.RunnerOuterLoop.psm1'] | Should -Not -Match 'remediationAutoSkips\s*=\s*0' -Because 'the retry budget lives in the ledger, which a restart does not reset'
    }
}

Describe 'The module sets carry the contract' {
    It 'loads the contract in every entry-point set that runs a cycle step' -ForEach @(
        @{ Kind = 'Outer' }, @{ Kind = 'Inner' }, @{ Kind = 'Project' }, @{ Kind = 'Sequence' }
    ) {
        Get-ModuleSet $Kind | Should -Contain 'Test.RecoveryContract.psm1'
    }
    It 'loads the ledger and the repairs before the outer loop that calls them' {
        $set = Get-ModuleSet 'Outer'
        $set | Should -Contain 'Test.RecoveryLedger.psm1'
        $set | Should -Contain 'Test.RecoveryActions.psm1'
        $loop = [array]::IndexOf($set, 'Test.RunnerOuterLoop.psm1')
        foreach ($name in 'Test.RecoveryContract.psm1', 'Test.RecoveryLedger.psm1', 'Test.RecoveryActions.psm1') {
            [array]::IndexOf($set, $name) | Should -BeLessThan $loop
        }
        [array]::IndexOf($set, 'Test.RecoveryContract.psm1') | Should -BeLessThan ([array]::IndexOf($set, 'Test.RecoveryLedger.psm1'))
        [array]::IndexOf($set, 'Test.RecoveryLedger.psm1') | Should -BeLessThan ([array]::IndexOf($set, 'Test.RecoveryActions.psm1'))
    }
    It 'does not load the ledger or the repairs where nothing may repair' {
        foreach ($kind in 'Inner', 'Project', 'Sequence') {
            Get-ModuleSet $kind | Should -Not -Contain 'Test.RecoveryActions.psm1' -Because "an operator-driven $kind run must not change the machine behind the operator's back"
        }
    }
    It 'names only modules that exist' {
        foreach ($kind in 'Outer', 'Inner', 'Project', 'Sequence') {
            foreach ($module in Get-ModuleSet $kind) {
                Test-Path -LiteralPath (Join-Path $here $module) | Should -BeTrue -Because "$kind lists $module"
            }
        }
    }
}
