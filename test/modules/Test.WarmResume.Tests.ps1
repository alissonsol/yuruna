<#PSScriptInfo
.VERSION 2026.07.21
.GUID 429c3e7a-2d84-4f16-9c05-7a1e3b6d0f42
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner warm-resume pester
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
    Pester coverage for the warm-resume decision core (Test.WarmResume.psm1):
    the transient-class eligibility gate, the checkpoint extraction/read, the
    resume decision (sequence-name matching + all refusal reasons), and the
    schema-valid warm_resume event.
.DESCRIPTION
    Throw-based assertions for OS-bundled Pester 3.4 / Pester 5+ compatibility.
    Test.EventSchema is imported (it auto-loads Test.FailureTaxonomy) so the
    event builder is validated against the real schema.
    Run with:  pwsh -NoProfile -File test/modules/Test.WarmResume.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.EventSchema.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.WarmResume.psm1')  -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

function New-WRTempDir {
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: creates a throwaway log dir the calling It block deletes in its finally.')]
    param()
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-wr-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

Describe 'Warm-resume class eligibility' {
    It 'accepts exactly the transient allow-list' {
        foreach ($c in 'network_timeout','wait_timeout','instrumentation_failure','host_io_blocked') {
            Assert-True (Test-WarmResumeEligibleClass -FailureClass $c) "expected eligible: $c"
        }
        Assert-Equal -Expected 4 -Actual (Get-WarmResumeEligibleClass).Count
    }
    It 'rejects hard/deterministic classes and blanks' {
        foreach ($c in 'script_error','provisioning_failure','pattern_matched_failure','ocr_timeout','plan_invalid','') {
            Assert-Equal -Expected $false -Actual (Test-WarmResumeEligibleClass -FailureClass $c) -Because "must not resume: '$c'"
        }
    }
}

Describe 'Get-WarmResumeCheckpointFromRecord' {
    It 'extracts failureClass, sequenceName and repro.resumeFromStep' {
        $rec = @{ failureClass='network_timeout'; sequenceName='k8s'; repro=@{ resumeFromStep=27 } }
        $cp = Get-WarmResumeCheckpointFromRecord -Record $rec
        Assert-Equal -Expected 'network_timeout' -Actual $cp.FailureClass
        Assert-Equal -Expected 'k8s' -Actual $cp.SequenceName
        Assert-Equal -Expected 27 -Actual $cp.ResumeFromStep
    }
    It 'returns safe defaults for a null / malformed record' {
        $cp = Get-WarmResumeCheckpointFromRecord -Record $null
        Assert-Equal -Expected '' -Actual $cp.SequenceName
        Assert-Equal -Expected 0 -Actual $cp.ResumeFromStep
        $cp2 = Get-WarmResumeCheckpointFromRecord -Record @{ failureClass='wait_timeout' }
        Assert-Equal -Expected 0 -Actual $cp2.ResumeFromStep -Because 'no repro -> step 0'
    }
}

Describe 'Get-WarmResumeDecision' {
    $ws = @('ubuntu.server.26.update', 'ubuntu.server.26.k8s')
    It 'resumes an eligible transient failure whose sequence is in the workload list' {
        $d = Get-WarmResumeDecision -Enabled $true -FailureClass 'network_timeout' -SequenceName 'ubuntu.server.26.k8s' -ResumeFromStep 27 -WorkloadSequences $ws
        Assert-True $d.ShouldResume 'eligible + in list'
        Assert-Equal -Expected 'ubuntu.server.26.k8s' -Actual $d.ResumeSequence
    }
    It 'matches by base name when the workload entry carries a subdir + .yml' {
        $d = Get-WarmResumeDecision -Enabled $true -FailureClass 'host_io_blocked' -SequenceName 'ubuntu.server.26.k8s' -ResumeFromStep 3 -WorkloadSequences @('gui/ubuntu.server.26.k8s.yml','gui/ubuntu.server.26.update.yml')
        Assert-True $d.ShouldResume 'base-name match'
        Assert-Equal -Expected 'gui/ubuntu.server.26.k8s.yml' -Actual $d.ResumeSequence -Because 'returns the verbatim list entry'
    }
    It 'refuses when disabled' {
        Assert-Equal -Expected $false -Actual (Get-WarmResumeDecision -Enabled $false -FailureClass 'network_timeout' -SequenceName 'ubuntu.server.26.k8s' -ResumeFromStep 5 -WorkloadSequences $ws).ShouldResume
    }
    It 'refuses a hard failure class' {
        $d = Get-WarmResumeDecision -Enabled $true -FailureClass 'script_error' -SequenceName 'ubuntu.server.26.k8s' -ResumeFromStep 5 -WorkloadSequences $ws
        Assert-Equal -Expected $false -Actual $d.ShouldResume
        Assert-True ($d.Reason -like 'class-not-eligible*') 'reason names the class'
    }
    It 'refuses without a resume step (>= 1)' {
        Assert-Equal -Expected $false -Actual (Get-WarmResumeDecision -Enabled $true -FailureClass 'wait_timeout' -SequenceName 'ubuntu.server.26.k8s' -ResumeFromStep 0 -WorkloadSequences $ws).ShouldResume
    }
    It 'refuses when the failed sequence is not in the workload list' {
        $d = Get-WarmResumeDecision -Enabled $true -FailureClass 'wait_timeout' -SequenceName 'not.a.workload.seq' -ResumeFromStep 5 -WorkloadSequences $ws
        Assert-Equal -Expected $false -Actual $d.ShouldResume
        Assert-True ($d.Reason -like 'sequence-not-in-workload*') 'reason names the mismatch'
    }
}

Describe 'New-WarmResumeEvent (schema)' {
    It 'builds a schema-valid warm_resume event' {
        $ev = New-WarmResumeEvent -GuestKey 'guest.ubuntu.server.26' -VmName 'test-a' -SequenceName 'ubuntu.server.26.k8s' -ResumeFromStep 27 -FailureClass 'network_timeout' -Attempt 1 -HostType 'host.ubuntu.kvm'
        Assert-Equal -Expected 'warm_resume' -Actual $ev.event
        Assert-Equal -Expected 27 -Actual $ev.resumeFromStep
        Assert-Equal -Expected 1 -Actual $ev.attempt
        $v = @(Test-CycleEventSchema -Record ([hashtable]$ev))
        Assert-Equal -Expected 0 -Actual $v.Count -Because "schema violations: $($v -join '; ')"
    }
    It 'drops blank vmName / hostType so the typed-string check passes' {
        $ev = New-WarmResumeEvent -GuestKey 'g' -VmName '' -SequenceName 'k8s' -ResumeFromStep 5 -FailureClass 'wait_timeout' -Attempt 2 -HostType ''
        Assert-True (-not $ev.Contains('vmName'))   'blank vmName dropped'
        Assert-True (-not $ev.Contains('hostType')) 'blank hostType dropped'
        $v = @(Test-CycleEventSchema -Record ([hashtable]$ev))
        Assert-Equal -Expected 0 -Actual $v.Count -Because "schema violations: $($v -join '; ')"
    }
}

Describe 'Read-WarmResumeCheckpoint' {
    It 'round-trips a checkpoint from last_failure.json' {
        $d = New-WRTempDir
        try {
            @{ failureClass='network_timeout'; sequenceName='k8s'; repro=@{ resumeFromStep=27 } } |
                ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $d 'last_failure.json')
            $cp = Read-WarmResumeCheckpoint -LogDir $d
            Assert-Equal -Expected 'network_timeout' -Actual $cp.FailureClass
            Assert-Equal -Expected 27 -Actual $cp.ResumeFromStep
        } finally { if (Test-Path $d) { Remove-Item -Recurse -Force $d } }
    }
    It 'returns an empty checkpoint for a missing file' {
        $d = New-WRTempDir
        try { Assert-Equal -Expected 0 -Actual (Read-WarmResumeCheckpoint -LogDir $d).ResumeFromStep }
        finally { if (Test-Path $d) { Remove-Item -Recurse -Force $d } }
    }
    It 'returns an empty checkpoint for a corrupt file' {
        $d = New-WRTempDir
        try {
            [System.IO.File]::WriteAllText((Join-Path $d 'last_failure.json'), '{ not json', [System.Text.UTF8Encoding]::new($false))
            Assert-Equal -Expected 0 -Actual (Read-WarmResumeCheckpoint -LogDir $d).ResumeFromStep
        } finally { if (Test-Path $d) { Remove-Item -Recurse -Force $d } }
    }
    It 'treats a file older than NotBeforeUtc as no checkpoint (staleness gate)' {
        $d = New-WRTempDir
        try {
            @{ failureClass='network_timeout'; sequenceName='k8s'; repro=@{ resumeFromStep=27 } } |
                ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $d 'last_failure.json')
            $cp = Read-WarmResumeCheckpoint -LogDir $d -NotBeforeUtc ([DateTime]::UtcNow.AddMinutes(5))
            Assert-Equal -Expected 0 -Actual $cp.ResumeFromStep -Because 'a stale record must not drive a resume'
        } finally { if (Test-Path $d) { Remove-Item -Recurse -Force $d } }
    }
}
