<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42f6a7b8-c9d0-4e13-9456-7f8a9b0c1d2e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner inner prelude pester
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
    Guards on the inner runner entry script's prelude: the inner.pid write result
    is checked, and failure exits honor the canonical Get-EntryPointExitCode
    contract.
.DESCRIPTION
    Invoke-TestInnerRunner.ps1 is an entry script (top-level flow, not a function)
    so it is not invoked in-process here; the tests parse it and assert the
    required SHAPE via AST nodes rather than raw text, so a code comment cannot
    satisfy a guard.

    Pinned invariants:
      * The inner.pid write ($innerPidWritten = Write-YurunaStateFile ...) captures
        its [bool] result and, when false, both warns and mirrors to outer.log
        (Write-InnerLog, the durable sink at this point in the prelude) -- a failed
        inner.pid leaves the inner unmonitorable by the outer watchdog, so it must
        not be silently discarded.
      * No failure path uses a bare `exit 1`; the sites resolved after $ExitFailure
        exit with $ExitFailure (Get-EntryPointExitCode -Outcome Failure), so the
        canonical exit contract is honored everywhere.

    The throw-free Should assertions run under Pester 4.10.1.
#>

$here    = Split-Path -Parent $PSCommandPath
$script = Join-Path $here 'Invoke-TestInnerRunner.ps1'

# --- REGION: AST helpers (script scope; referenced from It blocks -> Pester 4)
function Get-ScriptAst {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($script): $($errs[0].Message)" }
    return $ast
}

# Count of `exit <arg>` statements whose argument text is exactly $ArgText.
function Get-ExitArgCount {
    param($Ast, [string]$ArgText)
    $want = $ArgText
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.ExitStatementAst] -and
        $n.Pipeline -and $n.Pipeline.Extent.Text -eq $want
    }, $true)).Count
}

# Count of assignments `$Lhs = ... <invoke $CmdName> ...`.
function Get-AssignmentInvokingCount {
    param($Ast, [string]$Lhs, [string]$CmdName)
    $wl = $Lhs; $wc = $CmdName
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true) | Where-Object {
        ($_.Left.Extent.Text -eq $wl) -and
        $_.Right.Find({ param($x)
            $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq $wc
        }, $true)
    }).Count
}

# Count of if-statement conditions whose text matches $Pattern.
function Get-IfConditionMatchCount {
    param($Ast, [string]$Pattern)
    $pat = $Pattern; $c = 0
    foreach ($ifs in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))) {
        foreach ($clause in $ifs.Clauses) { if ($clause.Item1.Extent.Text -match $pat) { $c++ } }
    }
    $c
}

# True when an if-statement whose condition matches $Pattern invokes $CmdName in its body.
function Test-IfBodyInvoke {
    param($Ast, [string]$Pattern, [string]$CmdName)
    $pat = $Pattern; $wc = $CmdName
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true) | Where-Object {
        ($_.Clauses[0].Item1.Extent.Text -match $pat) -and
        @($_.Clauses[0].Item2.FindAll({ param($x)
            $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq $wc
        }, $true)).Count -ge 1
    }).Count -ge 1
}

Describe 'Inner runner checks the inner.pid write result' {
    It 'captures the Write-YurunaStateFile result into $innerPidWritten (not $null =)' {
        (Get-AssignmentInvokingCount -Ast (Get-ScriptAst) -Lhs '$innerPidWritten' -CmdName 'Write-YurunaStateFile') |
            Should -BeGreaterOrEqual 1
    }
    It 'warns to the console when the inner.pid write failed (an unmonitorable inner)' {
        (Test-IfBodyInvoke -Ast (Get-ScriptAst) -Pattern 'innerPidWritten' -CmdName 'Write-Warning') | Should -Be $true
    }
    It 'mirrors the failure to outer.log via Write-InnerLog so it is durable' {
        (Test-IfBodyInvoke -Ast (Get-ScriptAst) -Pattern 'innerPidWritten' -CmdName 'Write-InnerLog') | Should -Be $true
    }
}

Describe 'Inner runner honors the canonical failure exit contract' {
    It 'has no bare `exit 1` failure path' {
        (Get-ExitArgCount -Ast (Get-ScriptAst) -ArgText '1') | Should -Be 0
    }
    It 'exits failure paths with $ExitFailure (all 7 sites: 6 converted + the pidfile-race path)' {
        # Floor at today's exact count so a single $ExitFailure -> $ExitOk revert on
        # a failure path (which is not a bare `exit 1`) still drops below the floor.
        (Get-ExitArgCount -Ast (Get-ScriptAst) -ArgText '$ExitFailure') | Should -BeGreaterOrEqual 7
    }
}
