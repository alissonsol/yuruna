<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42e6b2d9-4a17-4c83-9f25-3b8c1d6e0a47
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status telemetry pester
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
    Pester coverage for the status.json lastFailure surface: Set-LastFailureSummary
    writes the classified cause on the live doc, Initialize/Reset seed it null, and
    Complete-Run snapshots it (+ per-guest failureClass/errorMessage) into history.
.DESCRIPTION
    Drives the real doc lifecycle through a temp status.json (Write-StatusJson is
    the only side effect). Throw-based assertions (Pester 3.4 / 5+).
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Status.psm1') -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Null  { param($Actual, [string]$Because='') if ($null -ne $Actual) { throw "Expected null got [$Actual]. $Because" } }

function New-TempStatusDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: creates a throwaway temp dir for the status.json fixture.')]
    param()
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-status-test-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

# --- REGION: Structural guard: cycle-event emits must be Get-Command guarded
# Test.Status does not import the cycle-event logger, so each
# Send-CycleEventSafely emit must be gated on command existence or it throws in
# a degraded context instead of leaving Write-Warning as the fallback. AST-only.
#
# These helpers and the parsed module AST sit at file scope, above every
# Describe: file-level code only executes as far as the first Describe on the
# run pass, and a Describe body is evaluated during discovery with its scope
# discarded before any It runs. A helper or fixture declared after the first
# Describe -- or inside one -- is therefore unresolvable from an It body.

$statusModulePath = Join-Path $here 'Test.Status.psm1'

function Get-StatusModuleAst {
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

# True iff EVERY call to $CommandName has an ancestor if-statement whose
# condition calls `Get-Command <CommandName>`.
function Test-AllCallsGuardedByGetCommand {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$CommandName)
    Write-Verbose "Checking every '$CommandName' call is Get-Command guarded"
    $emits = $Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $CommandName
    }, $true)
    if (@($emits).Count -eq 0) { return $false }
    foreach ($emit in $emits) {
        $guarded = $false
        $anc = $emit.Parent
        while ($anc) {
            if ($anc -is [System.Management.Automation.Language.IfStatementAst]) {
                foreach ($clause in $anc.Clauses) {
                    $gc = $clause.Item1.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and
                        $n.GetCommandName() -eq 'Get-Command' -and
                        (@($n.CommandElements | Where-Object { $_.Extent.Text -eq $CommandName }).Count -gt 0)
                    }, $true)
                    if (@($gc).Count -gt 0) { $guarded = $true; break }
                }
            }
            if ($guarded) { break }
            $anc = $anc.Parent
        }
        if (-not $guarded) { return $false }
    }
    return $true
}

$rootAst = Get-StatusModuleAst -Path $statusModulePath

Describe 'status.json lastFailure surface' {
    It 'Initialize seeds lastFailure null; Set-LastFailureSummary records the cause' {
        $dir = New-TempStatusDir
        $env:YURUNA_RUNTIME_DIR = $dir
        $sf = Join-Path $dir 'status.json'
        Initialize-StatusDocument -StatusFilePath $sf -HostType 'h' -Hostname 'host' -GitCommit 'abc' -GuestList @('guest.x') -StepNames @('Sequence')
        $j = Get-Content -Raw $sf | ConvertFrom-Json
        Assert-Null $j.lastFailure 'fresh doc has null lastFailure'

        Set-LastFailureSummary -FailureClass 'ocr_timeout' -Severity 'hard' -StepNumber 3 -SequenceName 'wl.test' `
            -ReproCommand 'pwsh test/Test-Sequence.ps1 -SequenceName "wl.test"' -RelPath 'last_failure.json' `
            -GuestKey 'guest.x' -StepName 'Start-GuestWorkload' -ErrorMessage 'OCR timeout' -VmName 'vm1' -Confirm:$false
        $j2 = Get-Content -Raw $sf | ConvertFrom-Json
        Assert-Equal -Expected 'ocr_timeout' -Actual $j2.lastFailure.failureClass -Because 'cause recorded'
        Assert-Equal -Expected 3 -Actual $j2.lastFailure.stepNumber -Because 'step recorded'
        Assert-True ([string]$j2.lastFailure.reproCommand -match 'Test-Sequence') 'repro recorded'
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    }

    It 'Complete-Run snapshots the cause into the history row and per-guest summary' {
        $dir = New-TempStatusDir
        $env:YURUNA_RUNTIME_DIR = $dir
        $sf = Join-Path $dir 'status.json'
        Initialize-StatusDocument -StatusFilePath $sf -HostType 'h' -Hostname 'host' -GitCommit 'abc' -GuestList @('guest.x') -StepNames @('Sequence')
        Set-StepStatus  -GuestKey 'guest.x' -StepName 'Sequence' -Status 'fail' -ErrorMessage 'boom' -Confirm:$false
        Set-GuestStatus -GuestKey 'guest.x' -Status 'fail' -Confirm:$false
        Set-LastFailureSummary -FailureClass 'provisioning_failure' -Severity 'hard' -GuestKey 'guest.x' -StepName 'New-VM' -ErrorMessage 'boom' -VmName 'vm1' -Confirm:$false
        Complete-Run -OverallStatus 'fail' -MaxHistoryRuns 5
        $j = Get-Content -Raw $sf | ConvertFrom-Json
        Assert-Equal -Expected 'provisioning_failure' -Actual $j.history[0].lastFailure.failureClass -Because 'history row snapshots the cause'
        Assert-Equal -Expected 'boom' -Actual $j.history[0].guestSummary.'guest.x'.errorMessage -Because 'per-guest errorMessage persisted'
        Assert-Equal -Expected 'provisioning_failure' -Actual $j.history[0].guestSummary.'guest.x'.failureClass -Because 'per-guest failureClass persisted'
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    }

    It 'a passing cycle records a null history lastFailure' {
        $dir = New-TempStatusDir
        $env:YURUNA_RUNTIME_DIR = $dir
        $sf = Join-Path $dir 'status.json'
        Initialize-StatusDocument -StatusFilePath $sf -HostType 'h' -Hostname 'host' -GitCommit 'abc' -GuestList @('guest.x') -StepNames @('Sequence')
        Set-GuestStatus -GuestKey 'guest.x' -Status 'pass' -Confirm:$false
        Complete-Run -OverallStatus 'pass' -MaxHistoryRuns 5
        $j = Get-Content -Raw $sf | ConvertFrom-Json
        Assert-Null $j.history[0].lastFailure 'a pass row has null lastFailure'
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    }
}

Describe 'Test.Status guards its Send-CycleEventSafely emits' {

    It 'emits both cycle-event records (status_doc_corrupt and status_doc_write_failed)' {
        Assert-Equal -Expected 2 -Actual (Get-CommandCallCount -Ast $rootAst -CommandName 'Send-CycleEventSafely') -Because `
            'the read-path corrupt-doc event and the write-path write-failed event are both present'
    }
    It 'gates every Send-CycleEventSafely emit behind a Get-Command existence check' {
        Assert-True (Test-AllCallsGuardedByGetCommand -Ast $rootAst -CommandName 'Send-CycleEventSafely') `
            'the module does not import the logger; an absent Send-CycleEventSafely must fall back to Write-Warning, not throw'
    }
}
