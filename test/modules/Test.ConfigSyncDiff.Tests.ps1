<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42c9d0e1-2f3a-4b4c-8d5e-6f7a8b9c0d1e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test configsync pester
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
    Structural Pester guard on test/modules/Test.ConfigSync.psm1: the
    'differs-from-disk-outside-secrets' write-gate predicate is shared, not
    duplicated across the two reconciliation entry points.
.DESCRIPTION
    Update-TestConfigFromTemplate and Sync-TestConfigToTemplate each open-coded
    the same secrets-stripped-YAML string comparison to decide whether to rewrite
    test.config.yml. These AST guards assert it is now in one
    Test-ConfigDiffersOutsideSecretNode helper, both entry points delegate to it,
    the helper strips + serializes, and it stays private. AST/source-only.
    Runs under Pester 4.10.1 (script-scoped throw helper).
#>

$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$modulePath = Join-Path $repoRoot 'test/modules/Test.ConfigSync.psm1'

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

$rootAst = Get-ModuleAst -Path $modulePath
$helper  = 'Test-ConfigDiffersOutsideSecretNode'

Describe 'configsync-diff -- the outside-secrets write-gate predicate is shared' {
    It 'defines a Test-ConfigDiffersOutsideSecretNode helper' {
        $found = $rootAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $helper
        }, $true)
        Assert-True (@($found).Count -eq 1) 'the duplicated secrets-stripped-YAML diff must collapse into one helper'
    }
    It 'both reconciliation entry points delegate to the shared predicate' {
        $upd  = Get-FunctionAst -RootAst $rootAst -FunctionName 'Update-TestConfigFromTemplate'
        $sync = Get-FunctionAst -RootAst $rootAst -FunctionName 'Sync-TestConfigToTemplate'
        Assert-True (Test-AstCallsCommand -Ast $upd -CommandName $helper) 'Update-TestConfigFromTemplate must use the shared write-gate predicate'
        Assert-True (Test-AstCallsCommand -Ast $sync -CommandName $helper) 'Sync-TestConfigToTemplate must use the shared write-gate predicate'
    }
    It 'the helper strips secrets and serializes to YAML' {
        $h = Get-FunctionAst -RootAst $rootAst -FunctionName $helper
        Assert-True (Test-AstCallsCommand -Ast $h -CommandName 'Copy-HashtableWithoutSecretNode') 'the helper must strip the secrets node'
        Assert-True (Test-AstCallsCommand -Ast $h -CommandName 'ConvertTo-Yaml') 'the helper must serialize to YAML for the comparison'
    }
    It 'the helper stays private (not in the Export-ModuleMember allowlist)' {
        $exportCalls = $rootAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-ModuleMember'
        }, $true)
        Assert-True (@($exportCalls).Count -ge 1) 'Export-ModuleMember must be present'
        $exportText = ($exportCalls | ForEach-Object { $_.Extent.Text }) -join "`n"
        Assert-True ($exportText -notmatch [regex]::Escape($helper)) 'the write-gate predicate must not be exported (private helper)'
    }
}
