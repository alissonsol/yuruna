<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42d7e8f9-a0b1-4c23-8d45-6e7f8a9b0c1d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cleanup ocr pester
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
    Structural (AST) guards on two maintenance entry-point scripts:
    Remove-TestVMFiles.ps1 and Test-WinRtOcr.ps1.
.DESCRIPTION
    These scripts run top-to-bottom with `exit` and heavy I/O (host contract
    imports, virsh/utmctl, process control), so they are not invoked in-process
    here; the tests parse each file and assert the required SHAPE via AST nodes
    (loop conditions, method invocations, string literals, variable references)
    rather than raw source text, so a code comment cannot satisfy a guard.

    Pinned invariants:
      * Remove-TestVMFiles.ps1's UTM stop-wait loops on a [DateTime]::UtcNow
        deadline with no iteration accumulator (no += / ++ in the loop body, and
        no variable named $waited), and surfaces an unconfirmed stop before the
        delete.
      * Test-WinRtOcr.ps1 names its temp OCR script with a per-run GUID, so
        concurrent runs cannot collide on a fixed shared name.

    These are structural guards: they verify the required nodes are present and
    correctly shaped, not that the scripts execute correctly end to end.

    The throw-based Assert-* helpers live at script scope and are referenced from
    It blocks, so this runs under Pester 4.10.1 (Pester 5's scope split hides
    top-level helpers from It blocks).
#>

$here    = Split-Path -Parent $PSCommandPath
$testDir = Split-Path -Parent $here   # .../test

$removeVmFiles = Join-Path $testDir 'Remove-TestVMFiles.ps1'
$winRtOcr      = Join-Path $testDir 'Test-WinRtOcr.ps1'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

function Get-ScriptAst {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path) "script exists: $Path"
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($Path): $($errs[0].Message)" }
    return $ast
}

# Names of every .Method(...) / [Type]::Method(...) invocation in the tree (AST
# InvokeMemberExpressionAst). Comments are not AST nodes, so a phrase inside a
# comment cannot satisfy a membership test against this list.
function Get-InvokedMember {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
        ForEach-Object { $_.Member.Extent.Text })
}

# Condition text of every while-loop in the tree.
function Get-WhileConditionText {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] }, $true) |
        ForEach-Object { $_.Condition.Extent.Text })
}

# String LITERAL nodes only (excludes comments).
function Get-StringLiteralExtent {
    param($Ast)
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true) | ForEach-Object { $_.Extent.Text })
}

# True when the tree references a variable by name (AST VariableExpressionAst) --
# a name-specific regression pin.
function Test-UsesVariable {
    param($Ast, [string]$Name)
    $wanted = $Name
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq $wanted
    }, $true)).Count -ge 1
}

# True when any while-loop body accumulates an iteration counter (a compound
# assignment += / -= ... or a ++ / -- increment). A wall-clock-bounded wait must
# not also count iterations: a fixed iteration bound in the body could break out
# before the deadline, so the real timeout would drift with per-call cost. This
# catches the defect class regardless of the counter's variable name.
function Test-WhileBodyAccumulator {
    param($Ast)
    foreach ($w in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] }, $true))) {
        $compound = @($w.Body.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals
        }, $true))
        if ($compound.Count -ge 1) { return $true }
        $incr = @($w.Body.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.UnaryExpressionAst] -and
            @('PostfixPlusPlus', 'PrefixPlusPlus', 'PostfixMinusMinus', 'PrefixMinusMinus') -contains "$($n.TokenKind)"
        }, $true))
        if ($incr.Count -ge 1) { return $true }
    }
    return $false
}

Describe 'Remove-TestVMFiles.ps1 bounds the UTM stop-wait by wall-clock' {
    It 'waits on a UtcNow deadline with no iteration accumulator, and warns when never confirmed stopped' {
        $ast = Get-ScriptAst $removeVmFiles
        $whileConds = Get-WhileConditionText -Ast $ast
        Assert-True (@($whileConds | Where-Object { $_ -match 'UtcNow' }).Count -ge 1) 'a while loop gates on [DateTime]::UtcNow'
        Assert-True (-not (Test-WhileBodyAccumulator -Ast $ast)) 'no while-loop body accumulates an iteration counter (+= / ++), which would short-circuit the deadline'
        Assert-True (-not (Test-UsesVariable -Ast $ast -Name 'waited')) 'the specific $waited counter is gone'
        $warn = @(Get-StringLiteralExtent -Ast $ast | Where-Object { $_ -match 'did not confirm stopped' })
        Assert-True ($warn.Count -ge 1) 'an unconfirmed-stop warning is emitted before delete'
    }
}

Describe 'Test-WinRtOcr.ps1 uses a unique temp script name' {
    It 'names the temp OCR script with a per-run GUID, not a fixed shared name' {
        $ast = Get-ScriptAst $winRtOcr
        Assert-True ((Get-InvokedMember -Ast $ast) -contains 'NewGuid') 'the temp script name includes a NewGuid'
        $fixed = @(Get-StringLiteralExtent -Ast $ast | Where-Object { $_ -eq "'Test-WinRtOcr-run.ps1'" })
        Assert-True ($fixed.Count -eq 0) 'the fixed shared temp name is gone'
    }
}
