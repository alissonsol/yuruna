<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42e9f0a1-b2c3-4d45-9e67-8f9a0b1c2d36
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
    Test-Sequence.ps1's pre-start VM-skip decision inspects the step that will ACTUALLY
    execute first (the global -StartStep index across the concatenated chain), so a
    prerequisite chain at ChainEntries[0] or a partway -StartStep does not hide the
    sequence's loadDiskSnapshot first step.
.DESCRIPTION
    The decision is made by the script-local Get-FirstExecutedStepAction; the tests lift
    it from the script AST and exercise it directly (StartStep=1 equivalence, prerequisite
    chain, partway start, out-of-range, empty). An AST guard asserts the pre-start block
    routes through it with -StartStep rather than hard-coding ChainEntries[0].steps[0].
    Pester 4.10.1.
#>

$here       = Split-Path -Parent $PSCommandPath
$scriptPath = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath 'Test-Sequence.ps1')).Path
$errs = $null
$script:seqAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errs)
if ($errs) { throw "Parse errors in Test-Sequence.ps1: $($errs[0].Message)" }
$fnDef = $script:seqAst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-FirstExecutedStepAction'
}, $true) | Select-Object -First 1
if (-not $fnDef) { throw "Test.EntSequence.Tests.ps1: could not lift Get-FirstExecutedStepAction from Test-Sequence.ps1 (renamed or removed?)." }
. ([ScriptBlock]::Create($fnDef.Extent.Text))

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

Describe 'Test-Sequence.ps1 routes the pre-start skip through the StartStep-aware lookup' {
    It 'the pre-start decision calls Get-FirstExecutedStepAction' {
        (Get-CommandCallCount -Ast $script:seqAst -Name 'Get-FirstExecutedStepAction') | Should -BeGreaterOrEqual 1
    }
    It 'the hard-coded literal-first-step form (ChainEntries[0].sequence.steps) is gone' {
        $script:seqAst.Extent.Text | Should -Not -Match '\$ChainEntries\[0\]\.sequence\.steps'
    }
}
