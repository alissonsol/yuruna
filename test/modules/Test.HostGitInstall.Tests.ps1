<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42d1e2f3-4a5b-4c6d-8e7f-9a0b1c2d3e4f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test hostgit install pester
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
    Structural Pester guard on test/modules/Test.HostGit.psm1: the PSGallery
    module-install policy is shared by one helper, not duplicated across the two
    Install-*IfMissing bootstrappers.
.DESCRIPTION
    Install-PowerShellYamlIfMissing and Install-PSScriptAnalyzerIfMissing had
    byte-identical bodies (Get-Module early return / ShouldProcess WhatIf gate /
    Install-Module -Scope CurrentUser -Force -AllowClobber / catch-warn) differing
    only in the module-name string. These AST guards assert the policy is now in
    one Install-YurunaGalleryModuleIfMissing helper, both wrappers delegate, the
    raw Install-Module call appears exactly once, and the helper stays private.
    AST/source-only. Runs under Pester 4.10.1 (script-scoped throw helper).
#>

$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$modulePath = Join-Path $repoRoot 'test/modules/Test.HostGit.psm1'
$helper     = 'Install-YurunaGalleryModuleIfMissing'

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

function Get-FunctionAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.FunctionDefinitionAst])]
    param([Parameter(Mandatory)]$RootAst, [Parameter(Mandatory)][string]$FunctionName)
    $f = $RootAst.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName
    }, $true) | Select-Object -First 1
    if (-not $f) { throw "Function '$FunctionName' not found." }
    return $f
}

function Test-AstCallsCommand {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$CommandName)
    Write-Verbose "Searching for a call to '$CommandName'"
    $hits = $Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $CommandName
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

$rootAst = Get-ModuleAst -Path $modulePath

Describe 'hostgit-install -- the PSGallery install policy is shared by one helper' {
    It 'defines an Install-YurunaGalleryModuleIfMissing helper' {
        $found = $rootAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $helper
        }, $true)
        Assert-True (@($found).Count -eq 1) 'the two byte-identical install bodies must collapse into one helper'
    }
    It 'both Install-*IfMissing wrappers delegate to the shared helper' {
        $yaml = Get-FunctionAst -RootAst $rootAst -FunctionName 'Install-PowerShellYamlIfMissing'
        $psa  = Get-FunctionAst -RootAst $rootAst -FunctionName 'Install-PSScriptAnalyzerIfMissing'
        Assert-True (Test-AstCallsCommand -Ast $yaml -CommandName $helper) 'Install-PowerShellYamlIfMissing must delegate to the shared policy'
        Assert-True (Test-AstCallsCommand -Ast $psa -CommandName $helper) 'Install-PSScriptAnalyzerIfMissing must delegate to the shared policy'
    }
    It 'the raw Install-Module call now appears exactly once (inside the helper)' {
        $n = Get-CommandCallCount -Ast $rootAst -CommandName 'Install-Module'
        Assert-True ($n -eq 1) "expected exactly one Install-Module call after dedup, found $n"
    }
    It 'the helper stays private; both public wrappers remain exported' {
        $exportCalls = $rootAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-ModuleMember'
        }, $true)
        Assert-True (@($exportCalls).Count -ge 1) 'Export-ModuleMember must be present'
        $exportText = ($exportCalls | ForEach-Object { $_.Extent.Text }) -join "`n"
        Assert-True ($exportText -notmatch [regex]::Escape($helper)) 'the shared policy helper must not be exported'
        Assert-True ($exportText -match 'Install-PowerShellYamlIfMissing') 'Install-PowerShellYamlIfMissing must remain exported'
        Assert-True ($exportText -match 'Install-PSScriptAnalyzerIfMissing') 'Install-PSScriptAnalyzerIfMissing must remain exported'
    }
}
