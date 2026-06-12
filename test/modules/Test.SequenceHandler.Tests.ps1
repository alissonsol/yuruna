<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42a9d4e1-7c3b-4f08-9e21-3b6c5d8a1f02
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence break pester
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
    Structural Pester guard on the `break` action handler in
    Test.SequenceHandler.psm1: snapshot-restore-on-Continue must stay gated
    behind the opt-in `restoreOnContinue` flag.
.DESCRIPTION
    A plain breakpoint pauses and resumes in place. The step's `id` is a pure
    label and must NOT trigger Restore-VMDiskSnapshot + Start-VM on Continue --
    a break id legitimately matches a real snapshot name (the workload's
    requiresSnapshot / loadDiskSnapshot id) without meaning "rewind". The
    restore path is opt-in via `restoreOnContinue: true`.

    This test parses the module (no host I/O), isolates the break handler's
    scriptblock, and asserts the Restore-VMDiskSnapshot call is lexically nested
    inside an `if` whose condition references $restoreOnContinue. AST-only, so it
    runs under OS-bundled Pester 3.4 / Pester 5+ with throw-based assertions.
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.SequenceHandler.psm1'

function Assert-True { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# Argument expression following a named parameter on a command call, handling
# both `-P arg` (space) and `-P:arg` (colon) forms.
function Get-NamedArg {
    param([System.Management.Automation.Language.CommandAst]$Call, [string]$Name)
    $els = $Call.CommandElements
    for ($i = 0; $i -lt $els.Count; $i++) {
        $el = $els[$i]
        if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -eq $Name) {
            if ($el.Argument) { return $el.Argument }
            if ($i + 1 -lt $els.Count) { return $els[$i + 1] }
        }
    }
    return $null
}

# The scriptblock passed to Register-SequenceAction -Name 'break' -Handler { ... }.
function Get-BreakHandlerScriptBlockAst {
    param([string]$Path)
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }

    $regs = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Register-SequenceAction'
    }, $true)
    foreach ($call in $regs) {
        $nameArg = Get-NamedArg -Call $call -Name 'Name'
        if ($nameArg -and ($nameArg.Extent.Text.Trim("'`"") -eq 'break')) {
            $handler = Get-NamedArg -Call $call -Name 'Handler'
            if ($handler -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $handler }
        }
    }
    throw "break handler scriptblock not found in $Path"
}

Describe 'break handler gates snapshot-restore behind restoreOnContinue' {
    It 'reads the restoreOnContinue flag from the step' {
        $handler = Get-BreakHandlerScriptBlockAst -Path $modulePath
        Assert-True ($handler.Extent.Text -match 'restoreOnContinue') 'handler must consult restoreOnContinue'
    }

    It 'calls Restore-VMDiskSnapshot only inside an if ($restoreOnContinue ...) block' {
        $handler = Get-BreakHandlerScriptBlockAst -Path $modulePath
        $restoreCalls = $handler.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Restore-VMDiskSnapshot'
        }, $true)
        Assert-True (@($restoreCalls).Count -ge 1) 'expected a Restore-VMDiskSnapshot call to guard'

        foreach ($call in $restoreCalls) {
            $gated = $false
            $node = $call.Parent
            while ($node -and -not ($node -is [System.Management.Automation.Language.ScriptBlockAst] -and $node.Parent -eq $handler)) {
                if ($node -is [System.Management.Automation.Language.IfStatementAst]) {
                    foreach ($clause in $node.Clauses) {
                        if ($clause.Item1.Extent.Text -match 'restoreOnContinue') { $gated = $true }
                    }
                }
                $node = $node.Parent
            }
            Assert-True $gated "Restore-VMDiskSnapshot at $($call.Extent.StartLineNumber) is not gated by an if referencing restoreOnContinue."
        }
    }
}
