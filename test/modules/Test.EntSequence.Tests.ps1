<#PSScriptInfo
.VERSION 2026.08.21
.GUID 4255aa64-3611-4e05-addc-aea90bd5791a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence startstep loaddisksnapshot pester
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
    Debug-TestSequence.ps1's pre-start VM-skip decision inspects the step that will ACTUALLY
    execute first (the global -StartStep index across the concatenated chain), so a
    prerequisite chain at ChainEntries[0] or a partway -StartStep does not hide the
    sequence's loadDiskSnapshot first step.
.DESCRIPTION
    The decision is made by Get-FirstExecutedStepAction (Test.SequenceRunner.psm1, shared
    with the orchestrator's copy of the same decision); the tests import it and exercise it
    directly (StartStep=1 equivalence, prerequisite chain, partway start, out-of-range,
    empty). Its descent through wrapper steps is covered in Test.SequenceRunner.Tests.ps1.
    An AST guard asserts the pre-start block routes through it with -StartStep rather than
    hard-coding ChainEntries[0].steps[0]. Pester 4.10.1.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$scriptPath = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath 'Debug-TestSequence.ps1')).Path
# The AST is an unqualified file-scope variable: inside an It block a $script: reference
# resolves to the test runner's own script scope, not this file's, so a $script:-qualified
# fixture reaches the assertions as $null -- and a -Not -Match against $null passes
# vacuously, which is exactly the silent false-pass the AST guards exist to prevent.
$errs = $null
$seqAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errs)
if ($errs) { throw "Parse errors in Debug-TestSequence.ps1: $($errs[0].Message)" }
if (-not $seqAst.Extent.Text) {
    throw "Test.EntSequence.Tests.ps1: Debug-TestSequence.ps1 parsed to an empty AST -- the -Not -Match guards below would pass vacuously."
}
Import-Module (Join-Path $here 'Test.SequenceRunner.psm1') -Force -DisableNameChecking
# Get-FirstExecutedStepAction resolves a wrapper step through Get-StepLeadAction.
Import-Module (Join-Path $here 'Test.SequenceResolve.psm1') -Force -DisableNameChecking
if (-not (Get-Command Get-FirstExecutedStepAction -ErrorAction SilentlyContinue)) {
    throw "Test.EntSequence.Tests.ps1: Test.SequenceRunner.psm1 does not export Get-FirstExecutedStepAction (renamed or removed?)."
}

function Get-MockSeqEntry {
    # A ChainEntry shaped like the plan's: .sequence.steps[].action.
    param([string[]]$Actions)
    [pscustomobject]@{
        sequence = [pscustomobject]@{ steps = @($Actions | ForEach-Object { [pscustomobject]@{ action = $_ } }) }
    }
}
function Get-CommandCallCount {
    param($Ast, [string]$Name)
    $wm = $Name
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $wm
    }, $true)).Count
}

}

Describe 'Get-FirstExecutedStepAction resolves the first executed step honoring StartStep' {
    It 'StartStep 1 on a single chain returns the literal first step action (equivalence)' {
        Get-FirstExecutedStepAction -ChainEntries @(Get-MockSeqEntry 'loadDiskSnapshot','runThing') -StartStep 1 |
            Should -Be 'loadDiskSnapshot'
        Get-FirstExecutedStepAction -ChainEntries @(Get-MockSeqEntry 'startGuest','runThing') -StartStep 1 |
            Should -Be 'startGuest'
    }
    It 'a prerequisite chain at index 0 does not hide the main sequence loadDiskSnapshot' {
        $chain = @((Get-MockSeqEntry 'prereqA','prereqB'), (Get-MockSeqEntry 'loadDiskSnapshot','main2'))
        # Whole-chain run: the first executed step is the prerequisite's first step.
        Get-FirstExecutedStepAction -ChainEntries $chain -StartStep 1 | Should -Be 'prereqA'
        # Starting at the snapshot step (global index 3): the first executed step IS loadDiskSnapshot.
        Get-FirstExecutedStepAction -ChainEntries $chain -StartStep 3 | Should -Be 'loadDiskSnapshot'
    }
    It 'returns $null when StartStep is past the end of the chain' {
        Get-FirstExecutedStepAction -ChainEntries @(Get-MockSeqEntry 'a','b') -StartStep 99 | Should -BeNullOrEmpty
    }
    It 'returns $null for an empty chain' {
        Get-FirstExecutedStepAction -ChainEntries @() -StartStep 1 | Should -BeNullOrEmpty
    }
    It 'coerces a $null step action to an empty string (a non-match, so the VM is started normally)' {
        $entry = [pscustomobject]@{ sequence = [pscustomobject]@{ steps = @([pscustomobject]@{ action = $null }) } }
        Get-FirstExecutedStepAction -ChainEntries @($entry) -StartStep 1 | Should -Be ''
    }
}

Describe 'Debug-TestSequence.ps1 routes the pre-start skip through the StartStep-aware lookup' {
    It 'the pre-start decision calls Get-FirstExecutedStepAction' {
        (Get-CommandCallCount -Ast $seqAst -Name 'Get-FirstExecutedStepAction') | Should -BeGreaterOrEqual 1
    }
    It 'the hard-coded literal-first-step form (ChainEntries[0].sequence.steps) is gone' {
        $seqAst.Extent.Text | Should -Not -Match '\$ChainEntries\[0\]\.sequence\.steps'
    }
}
