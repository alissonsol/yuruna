<#PSScriptInfo
.VERSION 2026.10.18.1
.GUID 42fca3ae-ff54-4779-a27e-25c44c02ade3
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
    Runs under Pester 5.x (script-scoped throw helper).
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$modulePath = Join-Path $repoRoot 'test/modules/Test.ConfigSync.psm1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

function Get-ModuleAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.ScriptBlockAst])]
    param([Parameter(Mandatory)][string]$Path)
    return Get-YurunaTestFileAst -Path $Path
}

function Get-FunctionAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.FunctionDefinitionAst])]
    param([Parameter(Mandatory)]$RootAst, [Parameter(Mandatory)][string]$FunctionName)
    $f = Get-YurunaTestFunctionAst -Ast $RootAst -Name $FunctionName
    if (-not $f) { throw "Function '$FunctionName' not found." }
    return $f
}

function Test-AstCallsCommand {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$CommandName)
    return ((Get-YurunaTestCommandCallCount -Ast $Ast -CommandName $CommandName) -gt 0)
}

$rootAst = Get-ModuleAst -Path $modulePath
$script:helper  = 'Test-ConfigDiffersOutsideSecretNode'

}

Describe 'configsync-diff -- the outside-secrets write-gate predicate is shared' {
    It 'defines a Test-ConfigDiffersOutsideSecretNode helper' {
        $found = $rootAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $script:helper
        }, $true)
        Assert-True (@($found).Count -eq 1) 'the duplicated secrets-stripped-YAML diff must collapse into one helper'
    }
    It 'both reconciliation entry points delegate to the shared predicate' {
        $upd  = Get-FunctionAst -RootAst $rootAst -FunctionName 'Update-TestConfigFromTemplate'
        $sync = Get-FunctionAst -RootAst $rootAst -FunctionName 'Sync-TestConfigToTemplate'
        Assert-True (Test-AstCallsCommand -Ast $upd -CommandName $script:helper) 'Update-TestConfigFromTemplate must use the shared write-gate predicate'
        Assert-True (Test-AstCallsCommand -Ast $sync -CommandName $script:helper) 'Sync-TestConfigToTemplate must use the shared write-gate predicate'
    }
    It 'the helper strips secrets and serializes to YAML' {
        $h = Get-FunctionAst -RootAst $rootAst -FunctionName $script:helper
        Assert-True (Test-AstCallsCommand -Ast $h -CommandName 'Copy-HashtableWithoutSecretNode') 'the helper must strip the secrets node'
        Assert-True (Test-AstCallsCommand -Ast $h -CommandName 'ConvertTo-Yaml') 'the helper must serialize to YAML for the comparison'
    }
    It 'the helper stays private (not in the Export-ModuleMember allowlist)' {
        $exportCalls = $rootAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-ModuleMember'
        }, $true)
        Assert-True (@($exportCalls).Count -ge 1) 'Export-ModuleMember must be present'
        $exportText = ($exportCalls | ForEach-Object { $_.Extent.Text }) -join "`n"
        Assert-True ($exportText -notmatch [regex]::Escape($script:helper)) 'the write-gate predicate must not be exported (private helper)'
    }
}

Describe 'the function lookup behind these guards' {
    It 'throws for a function the module does not define' {
        # A guard reads what the lookup hands it. Were an absent function to come
        # back as nothing, a guard asserting that something is NOT in it would
        # pass against nothing.
        Assert-Throw { Get-FunctionAst -RootAst $rootAst -FunctionName 'Get-FunctionThatIsNotDefined' } 'not found' `
            'an absent function must stop the test that asked for it'
    }
}
