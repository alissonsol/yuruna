<#PSScriptInfo
.VERSION 2026.07.07
.GUID 42b4c5d6-e7f8-4a90-9b12-3c4d5e6f7081
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner config reload pester
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
    Guards on the inner loop's per-step config resync: the reload is driven through
    the single Sync-RunnerStepConfig hook, and that hook surfaces a sustained
    config-reload outage exactly once.
.DESCRIPTION
    Two invariants.

    Structural (AST, so a comment cannot satisfy a guard): Sync-RunnerCycleConfig
    is invoked from exactly one place (inside Sync-RunnerStepConfig), every step
    boundary routes through Sync-RunnerStepConfig, and the reload result is
    captured (not `$null = ...`) so the outage counter can be advanced.

    Behavioral (Sync-RunnerCycleConfig and Resolve-RunnerLogLevel mocked in the
    module scope so only the hook's tracking logic is exercised): the failure
    streak advances on each failed reload, the louder one-shot warning fires once
    at the threshold and not again, and any non-failed reload resets both the
    streak and the one-shot latch.

    Mock and the throw-free Should assertions run under Pester 4.10.1.
#>

$here    = Split-Path -Parent $PSCommandPath
$modPath = Join-Path $here 'Test.RunnerInnerLoop.psm1'
Import-Module $modPath -Force

# --- REGION: AST helpers (script scope; referenced from It blocks -> Pester 4)
function Get-ModuleAst {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($modPath, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($modPath): $($errs[0].Message)" }
    return $ast
}

# Count of command invocations of $Name (CommandAst nodes only -- the definition
# and the Export-ModuleMember bareword are not CommandAst with this name).
function Get-CommandInvokeCount {
    param($Ast, [string]$Name)
    $wanted = $Name   # local so the FindAll closure's use is visible to the analyzer
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq $wanted
    }, $true)).Count
}

# True when some assignment captures the result of invoking $Name into a non-$null
# variable (i.e. the return is kept, not thrown away with `$null = ...`).
function Test-CapturesNonNullResult {
    param($Ast, [string]$Name)
    $wanted = $Name   # local so the Find closure's use is visible to the analyzer
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true) | Where-Object {
        $invokesName = $_.Right.Find({ param($x)
            $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq $wanted
        }, $true)
        $invokesName -and ($_.Left.Extent.Text -ne '$null')
    }).Count -ge 1
}

Describe 'Inner loop resyncs config through the single Sync-RunnerStepConfig hook' {
    It 'invokes Sync-RunnerCycleConfig from exactly one place, not inline per step' {
        $ast = Get-ModuleAst
        (Get-CommandInvokeCount -Ast $ast -Name 'Sync-RunnerCycleConfig') | Should -Be 1
    }
    It 'routes every step boundary through Sync-RunnerStepConfig' {
        $ast = Get-ModuleAst
        (Get-CommandInvokeCount -Ast $ast -Name 'Sync-RunnerStepConfig') | Should -BeGreaterOrEqual 7
    }
    It 'captures the Sync-RunnerCycleConfig result rather than discarding it with $null =' {
        $ast = Get-ModuleAst
        (Test-CapturesNonNullResult -Ast $ast -Name 'Sync-RunnerCycleConfig') | Should -Be $true
    }
}

Describe 'Sync-RunnerStepConfig surfaces a sustained config-reload outage once' {
    It 'seeds the sustained-failure counters on a fresh config state' {
        $st = New-RunnerConfigState -CmdLineLogLevel $null -CycleDelayFallback 30
        $st.ContainsKey('SyncFailedStreak')  | Should -Be $true
        $st.ContainsKey('SyncFailureWarned') | Should -Be $true
        $st.SyncFailedStreak  | Should -Be 0
        $st.SyncFailureWarned | Should -Be $false
    }
    It 'stays silent below the threshold, warns once at it, and latches past it' {
        Mock -ModuleName Test.RunnerInnerLoop Sync-RunnerCycleConfig { 'failed' }
        Mock -ModuleName Test.RunnerInnerLoop Resolve-RunnerLogLevel { }
        $st = New-RunnerConfigState -CmdLineLogLevel $null -CycleDelayFallback 30
        # Sync-RunnerCycleConfig is mocked to a bare status and emits no warning of
        # its own, so any warning captured here is Sync-RunnerStepConfig's louder
        # one-shot -- a per-iteration warning COUNT is a structural discriminator
        # that pins the exact threshold, where an aggregate total cannot tell
        # warn-at-1 or warn-at-4 apart from warn-at-3.

        # Failure 1: streak climbs but a transient blip must not warn.
        Sync-RunnerStepConfig -State $st -ConfigPath 'x' -WarningVariable w1 -WarningAction SilentlyContinue
        @($w1).Count          | Should -Be 0
        $st.SyncFailedStreak  | Should -Be 1
        $st.SyncFailureWarned | Should -Be $false

        # Failure 2: still below the threshold, still silent.
        Sync-RunnerStepConfig -State $st -ConfigPath 'x' -WarningVariable w2 -WarningAction SilentlyContinue
        @($w2).Count          | Should -Be 0
        $st.SyncFailedStreak  | Should -Be 2
        $st.SyncFailureWarned | Should -Be $false

        # Failure 3 (threshold): the one-shot fires on THIS iteration.
        Sync-RunnerStepConfig -State $st -ConfigPath 'x' -WarningVariable w3 -WarningAction SilentlyContinue
        @($w3).Count          | Should -Be 1
        $st.SyncFailedStreak  | Should -Be 3
        $st.SyncFailureWarned | Should -Be $true

        # Failure 4: latched -- no further warning even as the streak grows.
        Sync-RunnerStepConfig -State $st -ConfigPath 'x' -WarningVariable w4 -WarningAction SilentlyContinue
        @($w4).Count          | Should -Be 0
        $st.SyncFailedStreak  | Should -Be 4
        $st.SyncFailureWarned | Should -Be $true
    }
    It 'resets the streak and the one-shot latch on a resolved reload' {
        Mock -ModuleName Test.RunnerInnerLoop Sync-RunnerCycleConfig { 'resolved' }
        Mock -ModuleName Test.RunnerInnerLoop Resolve-RunnerLogLevel { }
        $st = New-RunnerConfigState -CmdLineLogLevel $null -CycleDelayFallback 30
        $st.SyncFailedStreak = 5; $st.SyncFailureWarned = $true
        Sync-RunnerStepConfig -State $st -ConfigPath 'x' -WarningAction SilentlyContinue
        $st.SyncFailedStreak  | Should -Be 0
        $st.SyncFailureWarned | Should -Be $false
    }
    It 'resets the streak on a non-dictionary reload too (any non-failed result)' {
        Mock -ModuleName Test.RunnerInnerLoop Sync-RunnerCycleConfig { 'nondict' }
        Mock -ModuleName Test.RunnerInnerLoop Resolve-RunnerLogLevel { }
        $st = New-RunnerConfigState -CmdLineLogLevel $null -CycleDelayFallback 30
        $st.SyncFailedStreak = 4; $st.SyncFailureWarned = $true
        Sync-RunnerStepConfig -State $st -ConfigPath 'x' -WarningAction SilentlyContinue
        $st.SyncFailedStreak  | Should -Be 0
        $st.SyncFailureWarned | Should -Be $false
    }
}
