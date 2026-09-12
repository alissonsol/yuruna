<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42914d9e-337f-4e2e-936a-1f6c1af240ff
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test ocr event pester
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
    Structural Pester guard on test/modules/Test.OcrEngine.psm1: the guarded
    soft-instrumentation event envelope is emitted through one helper, not
    hand-rebuilt at each OCR instrumentation site.
.DESCRIPTION
    Four OCR instrumentation sites emit the same guarded shell -- the Get-Command Send-CycleEventSafely
    presence guard, the UTC timestamp, failureClass='instrumentation_failure', and
    severity='soft' -- varying only the event name and payload. These AST guards
    assert the envelope lives in one Send-SoftCycleEvent helper, the four sites
    delegate to it, the raw Send-CycleEventSafely call appears exactly once (inside
    the helper), and the helper stays private. AST/source-only. Runs under Pester
    4.10.1 (script-scoped throw helper).
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.OcrEngine.psm1'
$script:helper     = 'Send-SoftCycleEvent'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

function Get-ModuleAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.ScriptBlockAst])]
    param([Parameter(Mandatory)][string]$Path)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }
    return $ast
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

$script:rootAst = Get-ModuleAst -Path $modulePath

}

Describe 'ocr-soft-event -- the guarded soft-instrumentation envelope is centralized' {
    It 'defines a single Send-SoftCycleEvent helper' {
        $found = $script:rootAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $script:helper
        }, $true)
        Assert-True (@($found).Count -eq 1) 'the four hand-built event envelopes must collapse into one helper'
    }
    It 'the four OCR instrumentation sites delegate to Send-SoftCycleEvent' {
        $n = Get-CommandCallCount -Ast $script:rootAst -CommandName $script:helper
        Assert-True ($n -eq 4) "expected exactly four Send-SoftCycleEvent call sites, found $n"
    }
    It 'the raw Send-CycleEventSafely emit appears exactly once (inside the helper)' {
        $n = Get-CommandCallCount -Ast $script:rootAst -CommandName 'Send-CycleEventSafely'
        Assert-True ($n -eq 1) "expected exactly one direct Send-CycleEventSafely call, found $n"
    }
    It 'Send-SoftCycleEvent stays private (not in the Export-ModuleMember allowlist)' {
        $exportCalls = $script:rootAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-ModuleMember'
        }, $true)
        Assert-True (@($exportCalls).Count -ge 1) 'Export-ModuleMember must be present'
        $exportText = ($exportCalls | ForEach-Object { $_.Extent.Text }) -join "`n"
        Assert-True ($exportText -notmatch [regex]::Escape($script:helper)) 'Send-SoftCycleEvent must not be exported (private helper)'
    }
}
