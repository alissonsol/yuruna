<#PSScriptInfo
.VERSION 2026.07.21
.GUID 422b4f6a-1c3e-4a57-8b90-6e2d4c1a7f38
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner circuit-breaker guest-quarantine pester
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
    Pester coverage for the guest-quarantine circuit breaker
    (Test.GuestQuarantine.psm1): the pure streak/quarantine-trip counting, the
    pure skip/release decision, the schema-valid guest_quarantined event, the
    state-file round-trip, and the read->decide->apply->emit orchestration.
.DESCRIPTION
    Assertions are throw-based inside It blocks so the file runs under the
    OS-bundled Pester 3.4 (no Install-Module needed) and under Pester 5+.
    Test.EventSchema is imported (it auto-loads Test.FailureTaxonomy) so the
    event builder can be validated against the real schema; the guest_quarantined
    emit path is exercised through a global Send-CycleEventSafely stub.
    Run with:  Invoke-Pester -Path test/modules/Test.GuestQuarantine.Tests.ps1
#>

# The emit path resolves Send-CycleEventSafely from the GLOBAL command table at
# call time (Get-Command-guarded), so the collector stub the trip test asserts
# through must live in the global scope or the module would never see it.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The global scope is the resolution contract under test: Register-GuestQuarantineOutcome finds Send-CycleEventSafely in the global table, so the collector stub and its assertion must straddle that scope.')]
param()

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Prelude.psm1')          -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.EventSchema.psm1')      -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.GuestQuarantine.psm1')  -Force -DisableNameChecking

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ($Expected -ne $Actual) { throw "Expected [$Expected] but got [$Actual]. $Because" }
}
function Assert-True {
    param($Condition, [string]$Because = '')
    if (-not $Condition) { throw "Expected condition to be true. $Because" }
}
function New-QTempDir {
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: creates a throwaway runtime dir the calling It block deletes in its finally.')]
    param()
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-quar-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

Describe 'Add-GuestQuarantineFailure (same-class streak + trip)' {
    It 'extends the streak on the same class and trips at the threshold' {
        $s = New-GuestQuarantineState
        $r1 = Add-GuestQuarantineFailure -State $s -GuestKey 'g' -FailureClass 'ocr_timeout' -GitCommit 'a' -ProjectGitCommit '' -FailuresToQuarantine 3 -SkipCycles 5
        Assert-Equal -Expected 1 -Actual $r1.ConsecutiveFailures
        Assert-Equal -Expected $false -Actual $r1.NewlyQuarantined
        $r2 = Add-GuestQuarantineFailure -State $s -GuestKey 'g' -FailureClass 'ocr_timeout' -GitCommit 'a' -ProjectGitCommit '' -FailuresToQuarantine 3 -SkipCycles 5
        Assert-Equal -Expected 2 -Actual $r2.ConsecutiveFailures
        Assert-Equal -Expected $false -Actual $r2.NewlyQuarantined
        $r3 = Add-GuestQuarantineFailure -State $s -GuestKey 'g' -FailureClass 'ocr_timeout' -GitCommit 'sha9' -ProjectGitCommit 'proj7' -FailuresToQuarantine 3 -SkipCycles 5
        Assert-Equal -Expected 3 -Actual $r3.ConsecutiveFailures
        Assert-Equal -Expected $true -Actual $r3.NewlyQuarantined -Because 'third same-class failure trips quarantine'
        Assert-Equal -Expected 'sha9'  -Actual $s.guests['g'].quarantinedAtCommit
        Assert-Equal -Expected 'proj7' -Actual $s.guests['g'].quarantinedAtProjectCommit
        Assert-Equal -Expected 5       -Actual $s.guests['g'].skipCyclesRemaining
    }
    It 'resets the streak to 1 when the failure class changes' {
        $s = New-GuestQuarantineState
        [void](Add-GuestQuarantineFailure -State $s -GuestKey 'g' -FailureClass 'ocr_timeout' -GitCommit 'a' -ProjectGitCommit '' -FailuresToQuarantine 3 -SkipCycles 5)
        [void](Add-GuestQuarantineFailure -State $s -GuestKey 'g' -FailureClass 'ocr_timeout' -GitCommit 'a' -ProjectGitCommit '' -FailuresToQuarantine 3 -SkipCycles 5)
        $r = Add-GuestQuarantineFailure -State $s -GuestKey 'g' -FailureClass 'network_timeout' -GitCommit 'a' -ProjectGitCommit '' -FailuresToQuarantine 3 -SkipCycles 5
        Assert-Equal -Expected 1 -Actual $r.ConsecutiveFailures -Because 'a different class is not the same deterministic failure'
        Assert-Equal -Expected $false -Actual $r.NewlyQuarantined
    }
    It 'normalises a blank failure class to unknown' {
        $s = New-GuestQuarantineState
        $r = Add-GuestQuarantineFailure -State $s -GuestKey 'g' -FailureClass '' -GitCommit 'a' -ProjectGitCommit '' -FailuresToQuarantine 3 -SkipCycles 5
        Assert-Equal -Expected 'unknown' -Actual $r.FailureClass
    }
}

Describe 'Get-GuestQuarantineDecision (pure skip/release)' {
    It 'returns not-tracked for an unknown guest' {
        $d = Get-GuestQuarantineDecision -State (New-GuestQuarantineState) -GuestKey 'g' -GitCommit 'a' -ProjectGitCommit ''
        Assert-Equal -Expected $false -Actual $d.Skip
        Assert-Equal -Expected 'none' -Actual $d.Action
    }
    It 'does not skip a tracked-but-not-yet-quarantined guest' {
        $s = New-GuestQuarantineState
        [void](Add-GuestQuarantineFailure -State $s -GuestKey 'g' -FailureClass 'ocr_timeout' -GitCommit 'a' -ProjectGitCommit '' -FailuresToQuarantine 3 -SkipCycles 5)
        $d = Get-GuestQuarantineDecision -State $s -GuestKey 'g' -GitCommit 'a' -ProjectGitCommit ''
        Assert-Equal -Expected $false -Actual $d.Skip
        Assert-Equal -Expected 'none' -Actual $d.Action
    }
    It 'skips (and reports the decremented budget) on the same commit with budget left' {
        $s = New-GuestQuarantineState
        1..3 | ForEach-Object { [void](Add-GuestQuarantineFailure -State $s -GuestKey 'g' -FailureClass 'ocr_timeout' -GitCommit 'a' -ProjectGitCommit '' -FailuresToQuarantine 3 -SkipCycles 5) }
        $d = Get-GuestQuarantineDecision -State $s -GuestKey 'g' -GitCommit 'a' -ProjectGitCommit ''
        Assert-Equal -Expected $true  -Actual $d.Skip
        Assert-Equal -Expected 'skip' -Actual $d.Action
        Assert-Equal -Expected 4      -Actual $d.SkipCyclesRemaining -Because '5-cycle budget, one consumed this cycle'
    }
    It 'releases on a changed framework commit' {
        $s = New-GuestQuarantineState
        1..3 | ForEach-Object { [void](Add-GuestQuarantineFailure -State $s -GuestKey 'g' -FailureClass 'ocr_timeout' -GitCommit 'a' -ProjectGitCommit '' -FailuresToQuarantine 3 -SkipCycles 5) }
        $d = Get-GuestQuarantineDecision -State $s -GuestKey 'g' -GitCommit 'b' -ProjectGitCommit ''
        Assert-Equal -Expected $false -Actual $d.Skip
        Assert-Equal -Expected 'release' -Actual $d.Action
        Assert-Equal -Expected 'released-new-commit' -Actual $d.Reason
    }
    It 'releases on a changed project commit even when the framework commit is unchanged' {
        $s = New-GuestQuarantineState
        1..3 | ForEach-Object { [void](Add-GuestQuarantineFailure -State $s -GuestKey 'g' -FailureClass 'ocr_timeout' -GitCommit 'a' -ProjectGitCommit 'p1' -FailuresToQuarantine 3 -SkipCycles 5) }
        $d = Get-GuestQuarantineDecision -State $s -GuestKey 'g' -GitCommit 'a' -ProjectGitCommit 'p2'
        Assert-Equal -Expected 'release' -Actual $d.Action
    }
    It 'does not treat an empty current commit as a change' {
        $s = New-GuestQuarantineState
        1..3 | ForEach-Object { [void](Add-GuestQuarantineFailure -State $s -GuestKey 'g' -FailureClass 'ocr_timeout' -GitCommit 'a' -ProjectGitCommit '' -FailuresToQuarantine 3 -SkipCycles 5) }
        $d = Get-GuestQuarantineDecision -State $s -GuestKey 'g' -GitCommit '' -ProjectGitCommit ''
        Assert-Equal -Expected 'skip' -Actual $d.Action -Because 'unknown commit must not falsely release'
    }
    It 'releases once the skip budget is exhausted' {
        $s = New-GuestQuarantineState
        1..3 | ForEach-Object { [void](Add-GuestQuarantineFailure -State $s -GuestKey 'g' -FailureClass 'ocr_timeout' -GitCommit 'a' -ProjectGitCommit '' -FailuresToQuarantine 3 -SkipCycles 1) }
        $s.guests['g'].skipCyclesRemaining = 0
        $d = Get-GuestQuarantineDecision -State $s -GuestKey 'g' -GitCommit 'a' -ProjectGitCommit ''
        Assert-Equal -Expected 'release' -Actual $d.Action
        Assert-Equal -Expected 'released-budget-exhausted' -Actual $d.Reason
    }
}

Describe 'Clear-GuestQuarantineEntry' {
    It 'drops the guest entry so a recovered guest starts clean' {
        $s = New-GuestQuarantineState
        [void](Add-GuestQuarantineFailure -State $s -GuestKey 'g' -FailureClass 'ocr_timeout' -GitCommit 'a' -ProjectGitCommit '' -FailuresToQuarantine 3 -SkipCycles 5)
        Clear-GuestQuarantineEntry -State $s -GuestKey 'g'
        Assert-True (-not $s.guests.Contains('g')) 'entry removed on pass'
    }
}

Describe 'New-GuestQuarantineEvent (schema)' {
    It 'builds a schema-valid guest_quarantined event' {
        $ev = New-GuestQuarantineEvent -GuestKey 'guest.a' -VmName 'test-a' -FailureClass 'ocr_timeout' -ConsecutiveFailures 3 -SkipCycles 5 -GitCommit 'abc1234' -ProjectGitCommit '' -HostType 'host.ubuntu.kvm'
        Assert-Equal -Expected 'guest_quarantined' -Actual $ev.event
        Assert-Equal -Expected 'ocr_timeout' -Actual $ev.failureClass
        Assert-Equal -Expected 'abc1234' -Actual $ev.quarantinedUntilCommit
        $violations = @(Test-CycleEventSchema -Record ([hashtable]$ev))
        Assert-Equal -Expected 0 -Actual $violations.Count -Because "schema violations: $($violations -join '; ')"
    }
    It 'drops blank context fields so the typed-string check passes' {
        $ev = New-GuestQuarantineEvent -GuestKey 'guest.a' -VmName '' -FailureClass 'unknown' -ConsecutiveFailures 3 -SkipCycles 5 -GitCommit 'abc' -ProjectGitCommit '' -HostType ''
        Assert-True (-not $ev.Contains('vmName'))   'blank vmName dropped'
        Assert-True (-not $ev.Contains('hostType')) 'blank hostType dropped'
        $violations = @(Test-CycleEventSchema -Record ([hashtable]$ev))
        Assert-Equal -Expected 0 -Actual $violations.Count -Because "schema violations: $($violations -join '; ')"
    }
}

Describe 'Read/Save state round-trip' {
    It 'round-trips a quarantine entry through the state file' {
        $rd = New-QTempDir
        try {
            $path = Join-Path $rd 'runner.quarantine.json'
            $s = New-GuestQuarantineState
            1..3 | ForEach-Object { [void](Add-GuestQuarantineFailure -State $s -GuestKey 'guest.a' -FailureClass 'wait_timeout' -GitCommit 'c1' -ProjectGitCommit 'p1' -FailuresToQuarantine 3 -SkipCycles 5) }
            Assert-True ([bool](Save-GuestQuarantineState -Path $path -State $s)) 'save succeeds'
            $back = Read-GuestQuarantineState -Path $path
            $e = $back.guests['guest.a']
            Assert-Equal -Expected $true -Actual $e.quarantined
            Assert-Equal -Expected 'wait_timeout' -Actual $e.failureClass
            Assert-Equal -Expected 3 -Actual $e.consecutiveFailures
            Assert-Equal -Expected 'c1' -Actual $e.quarantinedAtCommit
            Assert-Equal -Expected 5 -Actual $e.skipCyclesRemaining
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'returns empty state for a missing file' {
        $rd = New-QTempDir
        try {
            $back = Read-GuestQuarantineState -Path (Join-Path $rd 'nope.json')
            Assert-Equal -Expected 0 -Actual $back.guests.Count
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'resets to empty state on a corrupt file' {
        $rd = New-QTempDir
        try {
            $path = Join-Path $rd 'runner.quarantine.json'
            [System.IO.File]::WriteAllText($path, '{ this is not json', [System.Text.UTF8Encoding]::new($false))
            $back = Read-GuestQuarantineState -Path $path
            Assert-Equal -Expected 0 -Actual $back.guests.Count -Because 'soft parse fallback resets state'
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
}

Describe 'Invoke-GuestQuarantineGate + Register-GuestQuarantineOutcome (orchestration)' {
    It 'trips, skips across cycles, and re-admits on a new commit' {
        $rd = New-QTempDir
        try {
            [void](Register-GuestQuarantineOutcome -RuntimeDir $rd -GuestKey 'guest.z' -Outcome 'fail' -FailureClass 'wait_timeout' -GitCommit 'c1' -FailuresToQuarantine 2 -SkipCycles 3)
            $o2 = Register-GuestQuarantineOutcome -RuntimeDir $rd -GuestKey 'guest.z' -Outcome 'fail' -FailureClass 'wait_timeout' -GitCommit 'c1' -FailuresToQuarantine 2 -SkipCycles 3
            Assert-True $o2.NewlyQuarantined 'second same-class failure trips'
            $g1 = Invoke-GuestQuarantineGate -RuntimeDir $rd -GuestKey 'guest.z' -GitCommit 'c1' -ProjectGitCommit ''
            Assert-True $g1.Skip 'same commit -> skipped'
            $g2 = Invoke-GuestQuarantineGate -RuntimeDir $rd -GuestKey 'guest.z' -GitCommit 'c2' -ProjectGitCommit ''
            Assert-Equal -Expected $false -Actual $g2.Skip -Because 'new commit re-admits'
            Assert-Equal -Expected 'released-new-commit' -Actual $g2.Reason
            $g3 = Invoke-GuestQuarantineGate -RuntimeDir $rd -GuestKey 'guest.z' -GitCommit 'c2' -ProjectGitCommit ''
            Assert-Equal -Expected 'not-tracked' -Actual $g3.Reason -Because 'released entry is gone'
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'clears the streak on a pass' {
        $rd = New-QTempDir
        try {
            [void](Register-GuestQuarantineOutcome -RuntimeDir $rd -GuestKey 'guest.p' -Outcome 'fail' -FailureClass 'wait_timeout' -GitCommit 'c1' -FailuresToQuarantine 3 -SkipCycles 5)
            [void](Register-GuestQuarantineOutcome -RuntimeDir $rd -GuestKey 'guest.p' -Outcome 'pass')
            $back = Read-GuestQuarantineState -Path (Join-Path $rd 'runner.quarantine.json')
            Assert-True (-not $back.guests.Contains('guest.p')) 'a pass clears the streak'
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'emits a guest_quarantined event only when a failure trips the threshold' {
        $global:__QEmitted = @()
        function global:Send-CycleEventSafely { param($EventRecord) $global:__QEmitted += , $EventRecord }
        $rd = New-QTempDir
        try {
            [void](Register-GuestQuarantineOutcome -RuntimeDir $rd -GuestKey 'guest.e' -Outcome 'fail' -FailureClass 'wait_timeout' -GitCommit 'c1' -FailuresToQuarantine 2 -SkipCycles 3)
            Assert-Equal -Expected 0 -Actual $global:__QEmitted.Count -Because 'first failure below threshold: no event'
            [void](Register-GuestQuarantineOutcome -RuntimeDir $rd -GuestKey 'guest.e' -Outcome 'fail' -FailureClass 'wait_timeout' -VmName 'test-e' -GitCommit 'c1' -HostType 'host.ubuntu.kvm' -FailuresToQuarantine 2 -SkipCycles 3)
            Assert-Equal -Expected 1 -Actual $global:__QEmitted.Count -Because 'exactly one event on the trip'
            Assert-Equal -Expected 'guest_quarantined' -Actual $global:__QEmitted[0].event
            Assert-Equal -Expected 'guest.e' -Actual $global:__QEmitted[0].guestKey
        } finally {
            Remove-Item Function:\Send-CycleEventSafely -ErrorAction SilentlyContinue
            Remove-Variable -Name __QEmitted -Scope Global -ErrorAction SilentlyContinue
            if (Test-Path $rd) { Remove-Item -Recurse -Force $rd }
        }
    }
}
