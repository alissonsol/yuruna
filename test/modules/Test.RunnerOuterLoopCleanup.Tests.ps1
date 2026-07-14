<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42c5d6e7-f809-4a12-9b34-5c6d7e8f9012
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner outer watchdog notifier pester
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
    Guards on the outer loop's two cleanup paths: the watchdog job is stopped from
    a finally (so it never leaks), and a wedged pool-notifier thread job is leaked
    and reaped best-effort rather than blocked on.
.DESCRIPTION
    Structural (AST, so a comment cannot satisfy a guard): Stop-Watchdog is invoked
    exactly once and that invocation sits inside a finally block, so any throw
    between arming the watchdog and the inner spawn still stops it; Stop-Job is not
    invoked at all (a Stop-Job/Remove-Job -Force on a CIFS-wedged job can itself
    block, the stall the 120s cap exists to prevent); and the reap is delegated to
    Clear-TerminalNotifierJob.

    Behavioral: Clear-TerminalNotifierJob removes only terminal (Completed/Failed/
    Stopped) jobs from $State.LeakedNotifierJobs and keeps a still-Running one
    (removing a terminal job never blocks; a -Force removal of a running/wedged job
    would), and is a no-op when nothing was ever leaked. Exercised with real thread
    jobs so .State and Remove-Job behave as in production.

    The throw-free Should assertions run under Pester 4.10.1.
#>

$here    = Split-Path -Parent $PSCommandPath
$modPath = Join-Path $here 'Test.RunnerOuterLoop.psm1'
Import-Module $modPath -Force

# --- REGION: AST helpers (script scope; referenced from It blocks -> Pester 4)
function Get-ModuleAst {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($modPath, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($modPath): $($errs[0].Message)" }
    return $ast
}

# Count of command invocations of $Name (CommandAst only -- a definition or an
# Export-ModuleMember bareword is not a CommandAst with this name).
function Get-CommandInvokeCount {
    param($Ast, [string]$Name)
    $wanted = $Name   # local so the FindAll closure's use is visible to the analyzer
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq $wanted
    }, $true)).Count
}

# True when some try/finally has $Name invoked inside its finally block.
function Test-CommandInFinally {
    param($Ast, [string]$Name)
    $wanted = $Name
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.TryStatementAst]
    }, $true) | Where-Object {
        $_.Finally -and @($_.Finally.FindAll({ param($x)
            $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq $wanted
        }, $true)).Count -ge 1
    }).Count -ge 1
}

# True when an if-statement whose condition references $VarName contains a
# `continue` in its body -- pins the post-finally `if ($innerSpawnFailed){ continue }`.
function Test-ContinueGuardedByVar {
    param($Ast, [string]$VarName)
    $wanted = $VarName
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true) | Where-Object {
        ($_.Clauses[0].Item1.Extent.Text -match $wanted) -and
        @($_.Clauses[0].Item2.FindAll({ param($x) $x -is [System.Management.Automation.Language.ContinueStatementAst] }, $true)).Count -ge 1
    }).Count -ge 1
}

# Count of assignments with an exact LHS and RHS text (AST nodes; comment-proof).
function Get-ExactAssignmentCount {
    param($Ast, [string]$Lhs, [string]$Rhs)
    $wl = $Lhs; $wr = $Rhs
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq $wl -and $n.Right.Extent.Text -eq $wr
    }, $true)).Count
}

# True when the LeakedNotifierJobs lazy-init (assign a new List[object]) exists and
# precedes the .Add($njob) append, so the first leak cannot NRE on a null list.
function Test-LazyInitPrecedesAdd {
    param($Ast)
    $init = @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$State.LeakedNotifierJobs' -and
        $n.Right.Extent.Text -match 'List\[object\]'
    }, $true))
    $add = @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Member.Extent.Text -eq 'Add' -and $n.Expression.Extent.Text -eq '$State.LeakedNotifierJobs'
    }, $true))
    ($init.Count -ge 1) -and ($add.Count -ge 1) -and ($init[0].Extent.StartOffset -lt $add[0].Extent.StartOffset)
}

Describe 'Outer loop stops the watchdog from a finally' {
    It 'invokes Stop-Watchdog exactly once' {
        (Get-CommandInvokeCount -Ast (Get-ModuleAst) -Name 'Stop-Watchdog') | Should -Be 1
    }
    It 'places that Stop-Watchdog inside a finally block so a throw between arm and spawn still stops it' {
        (Test-CommandInFinally -Ast (Get-ModuleAst) -Name 'Stop-Watchdog') | Should -Be $true
    }
    It 'initializes the inner-spawn-failure flag to $false exactly once before the guarded spawn' {
        # Guards the retry gate: initializing it to $true would make every cycle
        # continue immediately -- an infinite no-op loop that stops nothing.
        (Get-ExactAssignmentCount -Ast (Get-ModuleAst) -Lhs '$innerSpawnFailed' -Rhs '$false') | Should -Be 1
    }
    It 'gates the retry continue on the inner-spawn-failure flag so a failed spawn skips the rest of the cycle' {
        (Test-ContinueGuardedByVar -Ast (Get-ModuleAst) -VarName 'innerSpawnFailed') | Should -Be $true
    }
}

Describe 'Outer loop leaks a wedged notifier job instead of blocking on Stop-Job' {
    It 'does not invoke Stop-Job (which can itself block on a wedged CIFS syscall)' {
        (Get-CommandInvokeCount -Ast (Get-ModuleAst) -Name 'Stop-Job') | Should -Be 0
    }
    It 'delegates the reap to Clear-TerminalNotifierJob' {
        (Get-CommandInvokeCount -Ast (Get-ModuleAst) -Name 'Clear-TerminalNotifierJob') | Should -BeGreaterOrEqual 1
    }
    It 'lazily initializes the leak list before appending, so the first leak cannot NRE on a null list' {
        (Test-LazyInitPrecedesAdd -Ast (Get-ModuleAst)) | Should -Be $true
    }
}

Describe 'Clear-TerminalNotifierJob reaps only terminal jobs' {
    AfterEach {
        Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'reaptest-*' } |
            Remove-Job -Force -ErrorAction SilentlyContinue
    }
    It 'removes Completed/Failed jobs from the list and keeps a still-Running one' {
        $c   = Start-ThreadJob -Name 'reaptest-c'   -ScriptBlock { 1 }
        $f   = Start-ThreadJob -Name 'reaptest-f'   -ScriptBlock { throw 'boom' }
        $run = Start-ThreadJob -Name 'reaptest-run' -ScriptBlock { Start-Sleep -Seconds 30 }
        $null = Wait-Job -Job $c, $f -Timeout 10
        # The kept job must be genuinely Running, not NotStarted: NotStarted is in
        # neither the terminal nor the kept set, so a reap-includes-Running mutant
        # would slip past a NotStarted job. Spin until it leaves NotStarted.
        $spinDeadline = [DateTime]::UtcNow.AddSeconds(10)
        while ($run.State -eq 'NotStarted' -and [DateTime]::UtcNow -lt $spinDeadline) { Start-Sleep -Milliseconds 50 }
        $run.State | Should -Be 'Running'
        $cId = $c.Id; $fId = $f.Id
        $list = [System.Collections.Generic.List[object]]::new()
        $list.Add($c); $list.Add($f); $list.Add($run)
        $State = @{ LeakedNotifierJobs = $list }

        Clear-TerminalNotifierJob -State $State

        # The list is pruned to only the running job...
        $State.LeakedNotifierJobs.Count  | Should -Be 1
        $State.LeakedNotifierJobs[0].Id  | Should -Be $run.Id
        # ...and Remove-Job actually ran (the reap's whole point): the terminal jobs
        # are gone from the job table, the running one is untouched (never -Force'd).
        @(Get-Job -Id $cId, $fId -ErrorAction SilentlyContinue).Count | Should -Be 0
        (Get-Job -Id $run.Id -ErrorAction SilentlyContinue)          | Should -Not -BeNullOrEmpty
    }
    It 'is a no-op when nothing was ever leaked' {
        $State = @{}
        { Clear-TerminalNotifierJob -State $State } | Should -Not -Throw
        $State.ContainsKey('LeakedNotifierJobs') | Should -Be $false
    }
}
