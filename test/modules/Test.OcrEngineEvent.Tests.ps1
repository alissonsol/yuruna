<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42e3f4a5-6b7c-4d8e-9f0a-1b2c3d4e5f6a
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
    Four sites each re-built the same shell -- the Get-Command Send-CycleEventSafely
    presence guard, the UTC timestamp, failureClass='instrumentation_failure', and
    severity='soft' -- varying only the event name and payload. These AST guards
    assert the envelope lives in one Send-SoftCycleEvent helper, the four sites
    delegate to it, the raw Send-CycleEventSafely call appears exactly once (inside
    the helper), and the helper stays private. AST/source-only. Runs under Pester
    4.10.1 (script-scoped throw helper).
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.OcrEngine.psm1'
$helper     = 'Send-SoftCycleEvent'

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

Describe 'ocr-soft-event -- the guarded soft-instrumentation envelope is centralized' {
    It 'defines a single Send-SoftCycleEvent helper' {
        $found = $rootAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $helper
        }, $true)
        Assert-True (@($found).Count -eq 1) 'the four hand-built event envelopes must collapse into one helper'
    }
    It 'the four OCR instrumentation sites delegate to Send-SoftCycleEvent' {
        $n = Get-CommandCallCount -Ast $rootAst -CommandName $helper
        Assert-True ($n -eq 4) "expected exactly four Send-SoftCycleEvent call sites, found $n"
    }
    It 'the raw Send-CycleEventSafely emit appears exactly once (inside the helper)' {
        $n = Get-CommandCallCount -Ast $rootAst -CommandName 'Send-CycleEventSafely'
        Assert-True ($n -eq 1) "expected exactly one direct Send-CycleEventSafely call, found $n"
    }
    It 'Send-SoftCycleEvent stays private (not in the Export-ModuleMember allowlist)' {
        $exportCalls = $rootAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-ModuleMember'
        }, $true)
        Assert-True (@($exportCalls).Count -ge 1) 'Export-ModuleMember must be present'
        $exportText = ($exportCalls | ForEach-Object { $_.Extent.Text }) -join "`n"
        Assert-True ($exportText -notmatch [regex]::Escape($helper)) 'Send-SoftCycleEvent must not be exported (private helper)'
    }
}
