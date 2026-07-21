<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42f6b7c8-9d0a-4b1c-8e2d-3f4a5b6c7d8e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner cycle pester
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
    Structural Pester guard on test/modules/Test.RunnerInnerLoop.psm1: the
    rename-stable cycle base name (Get-CycleFolderIdentity else Split-Path -Leaf)
    is derived by one helper, not inlined at each URL/log site.
.DESCRIPTION
    These AST guards assert the guarded 'if Get-CycleFolderIdentity available use
    it on the cycle folder, else the raw leaf' resolution lives in one
    Get-StableCycleBaseName helper (never re-inlined per URL/log site), the three
    sites call it, the raw Get-CycleFolderIdentity invocation appears exactly once
    (inside the helper), and the helper stays private. AST/source-only -- no
    module import, no runner. The throw-based Assert-True helper is script-scoped
    so this runs under Pester 4.10.1.
#>

$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$modulePath = Join-Path $repoRoot 'test/modules/Test.RunnerInnerLoop.psm1'

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

# Count of CommandAst invocations of $CommandName (a direct call, not a bareword arg).
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

$rootAst = Get-ModuleAst -Path $modulePath

Describe 'runner-cycle-name -- rename-stable cycle base name is derived by one helper' {
    It 'defines a Get-StableCycleBaseName helper' {
        Assert-True (Test-FunctionDefined -RootAst $rootAst -FunctionName 'Get-StableCycleBaseName') `
            'the stable-identity resolution must live in one helper'
    }
    It 'the three URL/log sites call Get-StableCycleBaseName' {
        $n = Get-CommandCallCount -Ast $rootAst -CommandName 'Get-StableCycleBaseName'
        Assert-True ($n -eq 3) "expected exactly three Get-StableCycleBaseName call sites, found $n"
    }
    It 'the raw Get-CycleFolderIdentity is invoked exactly once (inside the helper)' {
        $n = Get-CommandCallCount -Ast $rootAst -CommandName 'Get-CycleFolderIdentity'
        Assert-True ($n -eq 1) "expected exactly one direct Get-CycleFolderIdentity call (inside the helper), found $n"
    }
    It 'Get-StableCycleBaseName stays private (not in the Export-ModuleMember allowlist)' {
        $exportCalls = $rootAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-ModuleMember'
        }, $true)
        Assert-True (@($exportCalls).Count -ge 1) 'Export-ModuleMember must be present'
        $exportText = ($exportCalls | ForEach-Object { $_.Extent.Text }) -join "`n"
        Assert-True ($exportText -notmatch 'Get-StableCycleBaseName') 'Get-StableCycleBaseName must not be exported (private helper)'
    }
}
