<#PSScriptInfo
.VERSION 2026.06.19
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
        Assert-Equal 'ocr_timeout' $j2.lastFailure.failureClass 'cause recorded'
        Assert-Equal 3 $j2.lastFailure.stepNumber 'step recorded'
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
        Assert-Equal 'provisioning_failure' $j.history[0].lastFailure.failureClass 'history row snapshots the cause'
        Assert-Equal 'boom' $j.history[0].guestSummary.'guest.x'.errorMessage 'per-guest errorMessage persisted'
        Assert-Equal 'provisioning_failure' $j.history[0].guestSummary.'guest.x'.failureClass 'per-guest failureClass persisted'
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
