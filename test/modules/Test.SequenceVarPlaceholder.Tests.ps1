<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42a7c8d9-0e1f-4a2b-9c3d-4e5f6a7b8c9d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence variable pester
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
    Structural Pester guard on test/modules/Test.SequenceVariable.psm1: the
    single-pass ${var} MatchEvaluator lives in one Expand-VarPlaceholder helper.
.DESCRIPTION
    Expand-Variable and the ${ext:...} argument expansion in
    Expand-ExtensionExpression each open-coded the same [regex]::Replace over
    '\$\{([^}]+)\}' with the identical resolve-or-leave-verbatim closure. These
    AST guards assert it is now in one helper, both sites delegate, the raw
    plain-${var} regex literal appears exactly once, and the helper stays private.
    AST/source-only. Runs under Pester 4.10.1 (script-scoped throw helper).
#>

$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$modulePath = Join-Path $repoRoot 'test/modules/Test.SequenceVariable.psm1'
$varPattern = '\$\{([^}]+)\}'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

function Get-ModuleAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.ScriptBlockAst])]
    param([Parameter(Mandatory)][string]$Path)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }
    return $ast
}

function Test-FunctionDefined {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$RootAst, [Parameter(Mandatory)][string]$FunctionName)
    Write-Verbose "Looking for function '$FunctionName'"
    $hits = $RootAst.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName
    }, $true)
    return (@($hits).Count -gt 0)
}

function Get-CommandCallCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$CommandName)
    Write-Verbose "Counting calls to '$CommandName'"
    $hits = $Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $CommandName
    }, $true)
    return @($hits).Count
}

function Get-StringConstantCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Value)
    Write-Verbose "Counting string constant '$Value'"
    $hits = $Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -eq $Value
    }, $true)
    return @($hits).Count
}

$rootAst = Get-ModuleAst -Path $modulePath

Describe 'sequence-var-placeholder -- the single-pass ${var} resolver is centralized' {
    It 'defines an Expand-VarPlaceholder helper' {
        Assert-True (Test-FunctionDefined -RootAst $rootAst -FunctionName 'Expand-VarPlaceholder') `
            'the duplicated ${var} MatchEvaluator must collapse into one helper'
    }
    It 'both var-expansion sites delegate to Expand-VarPlaceholder (was inlined twice)' {
        $n = Get-CommandCallCount -Ast $rootAst -CommandName 'Expand-VarPlaceholder'
        Assert-True ($n -ge 2) "expected the two var-expansion sites to call Expand-VarPlaceholder, found $n"
    }
    It 'the plain-${var} regex literal now appears exactly once (inside the helper)' {
        $n = Get-StringConstantCount -Ast $rootAst -Value $varPattern
        Assert-True ($n -eq 1) "expected exactly one plain-`${var} regex literal after dedup, found $n"
    }
    It 'Expand-VarPlaceholder stays private (not in the Export-ModuleMember allowlist)' {
        $exportCalls = $rootAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-ModuleMember'
        }, $true)
        Assert-True (@($exportCalls).Count -ge 1) 'Export-ModuleMember must be present'
        $exportText = ($exportCalls | ForEach-Object { $_.Extent.Text }) -join "`n"
        Assert-True ($exportText -notmatch 'Expand-VarPlaceholder') 'Expand-VarPlaceholder must not be exported (private helper)'
    }
}
