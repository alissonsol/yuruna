<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42d7b5c1-8293-44a5-9fb6-2b3c4d5e6f70
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence chain pester
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
    Pester coverage for the chain-convergence seams in Invoke-Sequence.psm1:
    Select-SequenceStepWindow (the in-memory -StartStep/-StopStep slice, so
    Test-Sequence needs no temp-YAML step files) and Get-SequenceFinishedVMName
    (the shared mid-chain rename surface both chain paths read).
.DESCRIPTION
    Throw-based assertions for OS-bundled Pester 3.4 / Pester 5+ compatibility.
    The window helper is pure and fully covered here; the rename surface's value
    is set by a live Invoke-Sequence run (host I/O), so only its default + type
    contract are unit-checked -- the propagation itself is an operator live-cycle
    validation (snapshot-chain workload).
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Invoke-Sequence.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

function New-StepList {
    [CmdletBinding()]
    [OutputType([object[]])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: builds an in-memory step array; changes no state.')]
    param([int]$Count)
    return @(1..$Count | ForEach-Object { @{ action = "step$_" } })
}

# The Export-ModuleMember statement text the export guard matches against, read at
# FILE scope: a Describe body is executed during discovery and its variables are
# discarded before any It runs, so an in-Describe $exportStmt would reach the
# guard as $null.
$exportStmt = [regex]::Match((Get-Content -Raw (Join-Path $here 'Invoke-Sequence.psm1')), '(?s)Export-ModuleMember.*').Value

# @() at each call mirrors how Invoke-Sequence consumes the result -- PowerShell
# unwraps a one-element return, so callers wrap to keep array semantics.
Describe 'Select-SequenceStepWindow' {
    It 'returns all steps for a whole-sequence window (default)' {
        $s = New-StepList -Count 6
        Assert-Equal -Expected 6 -Actual @(Select-SequenceStepWindow -Steps $s).Count -Because 'default = whole'
        Assert-Equal -Expected 6 -Actual @(Select-SequenceStepWindow -Steps $s -StartStep 1 -StopStep 0).Count -Because '(1,0) = whole'
    }
    It 'slices an inclusive 1-based window and renumbers to the slice' {
        $w = @(Select-SequenceStepWindow -Steps (New-StepList -Count 6) -StartStep 3 -StopStep 5)
        Assert-Equal -Expected 3 -Actual $w.Count -Because 'count'
        Assert-Equal -Expected 'step3' -Actual $w[0].action -Because 'first is the window start'
        Assert-Equal -Expected 'step5' -Actual $w[-1].action -Because 'last is the window stop'
    }
    It 'runs from StartStep to the end when StopStep is 0' {
        Assert-Equal -Expected 3 -Actual @(Select-SequenceStepWindow -Steps (New-StepList -Count 6) -StartStep 4).Count -Because '4..end of 6'
    }
    It 'supports a single-step window' {
        $w = @(Select-SequenceStepWindow -Steps (New-StepList -Count 6) -StartStep 2 -StopStep 2)
        Assert-Equal -Expected 1 -Actual $w.Count -Because 'single step'
        Assert-Equal -Expected 'step2' -Actual $w[0].action -Because 'the right step'
    }
    It 'clamps StopStep beyond the total' {
        Assert-Equal -Expected 2 -Actual @(Select-SequenceStepWindow -Steps (New-StepList -Count 6) -StartStep 5 -StopStep 99).Count -Because 'clamped 5..6'
    }
    It 'returns empty for an out-of-range window or empty input' {
        Assert-Equal -Expected 0 -Actual @(Select-SequenceStepWindow -Steps (New-StepList -Count 6) -StartStep 10 -StopStep 12).Count -Because 'out of range'
        Assert-Equal -Expected 0 -Actual @(Select-SequenceStepWindow -Steps @() -StartStep 1 -StopStep 0).Count -Because 'empty input'
    }
}

Describe 'Get-SequenceFinishedVMName' {
    It 'returns a string (default empty before any sequence ran in this session)' {
        $v = Get-SequenceFinishedVMName
        Assert-True ($v -is [string]) 'string contract'
    }
}

Describe 'Get-OcrDegradationGrace' {
    It 'grants a full window for a console restart' {
        Assert-Equal 45 (Get-OcrDegradationGrace -Action 'console-restart' -AlreadyGrantedSeconds 0 -MaxGrantSeconds 120 -BaseWindowSeconds 45)
    }
    It 'grants half the window (rounded up) for a lighter ring repair' {
        Assert-Equal 23 (Get-OcrDegradationGrace -Action 'ring-repair' -AlreadyGrantedSeconds 0 -MaxGrantSeconds 120 -BaseWindowSeconds 45)
    }
    It 'clamps the grant to the remaining budget under the cap' {
        Assert-Equal 20 (Get-OcrDegradationGrace -Action 'console-restart' -AlreadyGrantedSeconds 100 -MaxGrantSeconds 120 -BaseWindowSeconds 45)
    }
    It 'returns 0 when the per-wait cap is exhausted (a dead feed still times out)' {
        Assert-Equal 0 (Get-OcrDegradationGrace -Action 'console-restart' -AlreadyGrantedSeconds 120 -MaxGrantSeconds 120 -BaseWindowSeconds 45)
    }
    It 'returns 0 when there is no grace budget at all' {
        Assert-Equal 0 (Get-OcrDegradationGrace -Action 'ring-repair' -AlreadyGrantedSeconds 0 -MaxGrantSeconds 0 -BaseWindowSeconds 45)
    }
    It 'caps a console restart to a small total budget (short waits)' {
        Assert-Equal 10 (Get-OcrDegradationGrace -Action 'console-restart' -AlreadyGrantedSeconds 0 -MaxGrantSeconds 10 -BaseWindowSeconds 45)
    }
    It 'rejects an out-of-set action at the parameter binder' {
        $threw = $false
        try { [void](Get-OcrDegradationGrace -Action 'reboot-guest' -AlreadyGrantedSeconds 0 -MaxGrantSeconds 120 -BaseWindowSeconds 45) }
        catch { $threw = $true }
        Assert-True $threw 'ValidateSet should reject an unknown action'
    }
}

Describe 'Module export surface' {
    # Assert against the Export-ModuleMember statement text, not ExportedFunctions:
    # Get-PollDelay is defined in Test.Backoff (never in this module), so PowerShell
    # silently ignores an Export-ModuleMember entry for it -- it is absent from
    # ExportedFunctions either way. Guarding the SOURCE list is what actually
    # catches a regression that re-adds the misleading re-export.
    It 'does not list Get-PollDelay in Export-ModuleMember (it is owned by Test.Backoff, resolved via the -Global import)' {
        Assert-True ($exportStmt.Length -gt 0) 'located the Export-ModuleMember statement'
        Assert-True ($exportStmt -notmatch '\bGet-PollDelay\b') 'Get-PollDelay belongs to Test.Backoff; callers resolve it via the global import, not an Invoke-Sequence re-export'
    }
    It 'still exports the core dispatch surface and pure helpers' {
        $exported = (Get-Module Invoke-Sequence).ExportedFunctions.Keys
        foreach ($fn in 'Invoke-Sequence', 'Invoke-SequenceByName', 'Wait-ForText', 'Select-SequenceStepWindow', 'Get-OcrDegradationGrace') {
            Assert-True ($exported -contains $fn) "expected export missing: $fn"
        }
    }
}
