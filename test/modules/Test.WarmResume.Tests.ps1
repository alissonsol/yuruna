<#PSScriptInfo
.VERSION 2026.08.21
.GUID 42bc2da1-ebdb-48ed-9d8a-68099d34d1f5
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

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.EventSchema.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.WarmResume.psm1')  -Force -DisableNameChecking
# The boundary reader goes through the engine's own loader, so the loader is
# part of what these tests cover: reading a sequence the way the engine does is
# the only thing that proves the step indexes line up with -StartStep.
Import-Module (Join-Path $here 'Test.SequenceResolve.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

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

# Fixtures must sit ABOVE THE FIRST Describe, not merely at file scope. Only
# top-level statements executed before the first Describe land in the session
# state the run phase reuses; a top-level assignment placed after one is
# evaluated during discovery and then discarded, so every later It reads $null.
# Declaring this inside the Describe body has the same effect for the same
# reason. It is a silent failure: an empty workload list refuses a resume just
# as surely as the condition each test means to check, so four of the five
# tests below -- including the two asserting a specific .Reason -- kept passing
# for the wrong reason while the list was empty.
$script:WarmResumeWorkload = @('ubuntu.server.26.update', 'ubuntu.server.26.k8s')

}

Describe 'Warm-resume class eligibility' {
    It 'accepts exactly the transient allow-list' {
        # ip_not_discovered belongs here for the same reason as the rest: a step
        # that never resolved an address never reached the guest, so nothing it
        # might have done is in doubt and replaying it is as sound as replaying a
        # timeout. The count is asserted alongside the members so that widening
        # this list stays a deliberate act -- a class added without a reason to
        # trust a replay is how warm resume starts re-running work that changed
        # something.
        # payload_unavailable earns its place on the same ground: the guest ran
        # the fetch wrapper and no source served the script, so the step did
        # nothing and there is nothing a replay could do twice. Its usual cause
        # -- a host that renumbered while the guest still held the old address --
        # is normally gone by the next attempt.
        foreach ($c in 'network_timeout','wait_timeout','instrumentation_failure','host_io_blocked','ip_not_discovered','payload_unavailable') {
            Assert-True (Test-WarmResumeEligibleClass -FailureClass $c) "expected eligible: $c"
        }
        Assert-Equal -Expected 6 -Actual (Get-WarmResumeEligibleClass).Count
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
    It 'resumes an eligible transient failure whose sequence is in the workload list' {
        $d = Get-WarmResumeDecision -Enabled $true -FailureClass 'network_timeout' -SequenceName 'ubuntu.server.26.k8s' -ResumeFromStep 27 -WorkloadSequences $script:WarmResumeWorkload
        Assert-True $d.ShouldResume "eligible + in list (reason: $($d.Reason))"
        Assert-Equal -Expected 'ubuntu.server.26.k8s' -Actual $d.ResumeSequence
    }
    It 'matches by base name when the workload entry carries a subdir + .yml' {
        $d = Get-WarmResumeDecision -Enabled $true -FailureClass 'host_io_blocked' -SequenceName 'ubuntu.server.26.k8s' -ResumeFromStep 3 -WorkloadSequences @('gui/ubuntu.server.26.k8s.yml','gui/ubuntu.server.26.update.yml')
        Assert-True $d.ShouldResume 'base-name match'
        Assert-Equal -Expected 'gui/ubuntu.server.26.k8s.yml' -Actual $d.ResumeSequence -Because 'returns the verbatim list entry'
    }
    It 'refuses when disabled' {
        Assert-Equal -Expected $false -Actual (Get-WarmResumeDecision -Enabled $false -FailureClass 'network_timeout' -SequenceName 'ubuntu.server.26.k8s' -ResumeFromStep 5 -WorkloadSequences $script:WarmResumeWorkload).ShouldResume
    }
    It 'refuses a hard failure class' {
        $d = Get-WarmResumeDecision -Enabled $true -FailureClass 'script_error' -SequenceName 'ubuntu.server.26.k8s' -ResumeFromStep 5 -WorkloadSequences $script:WarmResumeWorkload
        Assert-Equal -Expected $false -Actual $d.ShouldResume
        Assert-True ($d.Reason -like 'class-not-eligible*') 'reason names the class'
    }
    It 'refuses without a resume step (>= 1)' {
        Assert-Equal -Expected $false -Actual (Get-WarmResumeDecision -Enabled $true -FailureClass 'wait_timeout' -SequenceName 'ubuntu.server.26.k8s' -ResumeFromStep 0 -WorkloadSequences $script:WarmResumeWorkload).ShouldResume
    }
    It 'refuses when the failed sequence is not in the workload list' {
        $d = Get-WarmResumeDecision -Enabled $true -FailureClass 'wait_timeout' -SequenceName 'not.a.workload.seq' -ResumeFromStep 5 -WorkloadSequences $script:WarmResumeWorkload
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

Describe 'Get-WarmResumeRewindStep' {

    # The checkpoint names the step that FAILED. Transient says why it stopped,
    # not how much of its work landed first, so restarting there replays it onto
    # whatever residue it left. loadDiskSnapshot is the only action that makes
    # the guest known again, so it is the only sound restart point.
    It 'pulls the resume point back to the loadDiskSnapshot before the failed step' {
        $actions = @('loadDiskSnapshot', 'sshWaitReady', 'sshFetchAndExecute', 'saveSystemDiagnostic')
        $r = Get-WarmResumeRewindStep -StepAction $actions -ResumeFromStep 3
        Assert-Equal -Expected 1 -Actual $r.ResumeFromStep -Because 'the restore point precedes the half-applied step'
        Assert-True $r.Rewound 'the rewind is reported so the replay can be recorded'
        Assert-Equal -Expected 1 -Actual $r.BoundaryStep
    }

    It 'takes the NEAREST boundary, not the first one in the file' {
        $actions = @('loadDiskSnapshot', 'sshExec', 'loadDiskSnapshot', 'sshExec', 'sshFetchAndExecute')
        $r = Get-WarmResumeRewindStep -StepAction $actions -ResumeFromStep 5
        Assert-Equal -Expected 3 -Actual $r.ResumeFromStep -Because 'rewinding past a later restore would redo work that restore already reset'
    }

    It 'leaves a checkpoint that already sits on the boundary alone' {
        $actions = @('loadDiskSnapshot', 'sshWaitReady', 'sshExec')
        $r = Get-WarmResumeRewindStep -StepAction $actions -ResumeFromStep 1
        Assert-Equal -Expected 1 -Actual $r.ResumeFromStep
        Assert-True (-not $r.Rewound) 'restarting at the boundary is not a rewind and must not be reported as replayed work'
    }

    It 'keeps the checkpoint when the sequence has no restore point before it' {
        # Declining to resume here would turn a recoverable transient back into
        # the lost cycle warm resume exists to prevent, so the checkpoint stands.
        $actions = @('sshWaitReady', 'sshFetchAndExecute', 'saveSystemDiagnostic')
        $r = Get-WarmResumeRewindStep -StepAction $actions -ResumeFromStep 2
        Assert-Equal -Expected 2 -Actual $r.ResumeFromStep
        Assert-True (-not $r.Rewound) 'no boundary means no rewind, not a refusal'
        Assert-Equal -Expected 0 -Actual $r.BoundaryStep
    }

    It 'ignores a boundary that lies after the failed step' {
        $actions = @('sshWaitReady', 'sshExec', 'loadDiskSnapshot', 'sshExec')
        $r = Get-WarmResumeRewindStep -StepAction $actions -ResumeFromStep 2
        Assert-Equal -Expected 2 -Actual $r.ResumeFromStep -Because 'a restore the run never reached cannot have established any state'
        Assert-True (-not $r.Rewound) 'a later restore point is not a rewind target'
    }

    It 'survives an empty action list and an out-of-range checkpoint' {
        $r = Get-WarmResumeRewindStep -StepAction @() -ResumeFromStep 4
        Assert-Equal -Expected 4 -Actual $r.ResumeFromStep -Because 'an unreadable sequence must not change the resume point'
        Assert-True (-not $r.Rewound)
        # A sequence edited since the failure can leave the checkpoint past the
        # end; the boundary among the steps that DO exist is still the right one.
        $r2 = Get-WarmResumeRewindStep -StepAction @('loadDiskSnapshot', 'sshExec') -ResumeFromStep 9
        Assert-Equal -Expected 1 -Actual $r2.ResumeFromStep
        Assert-True $r2.Rewound
        $r3 = Get-WarmResumeRewindStep -StepAction @('loadDiskSnapshot') -ResumeFromStep 0
        Assert-Equal -Expected 0 -Actual $r3.ResumeFromStep -Because 'no checkpoint is not a resume'
    }
}

Describe 'warm_resume event records a replay' {

    It 'carries the checkpoint and the replayed count when the resume was rewound' {
        $ev = New-WarmResumeEvent -GuestKey 'g' -VmName 'vm' -SequenceName 's010' -ResumeFromStep 1 `
            -FailureClass 'network_timeout' -Attempt 1 -HostType 'host.ubuntu.kvm' -CheckpointStep 3
        Assert-Equal -Expected 1 -Actual $ev.resumeFromStep
        Assert-Equal -Expected 3 -Actual $ev.checkpointStep
        Assert-Equal -Expected 2 -Actual $ev.rewoundSteps -Because 'a resumed pass must say how much work it replayed'
        $v = @(Test-CycleEventSchema -Record ([hashtable]$ev))
        Assert-Equal -Expected 0 -Actual $v.Count -Because "schema violations: $($v -join '; ')"
    }

    It 'omits the replay fields when nothing was rewound' {
        $ev = New-WarmResumeEvent -GuestKey 'g' -VmName 'vm' -SequenceName 's010' -ResumeFromStep 3 `
            -FailureClass 'network_timeout' -Attempt 1 -HostType 'host.ubuntu.kvm' -CheckpointStep 3
        Assert-True (-not $ev.Contains('checkpointStep')) 'an unrewound resume must not claim replayed work'
        Assert-True (-not $ev.Contains('rewoundSteps'))
        $v = @(Test-CycleEventSchema -Record ([hashtable]$ev))
        Assert-Equal -Expected 0 -Actual $v.Count -Because "schema violations: $($v -join '; ')"
    }
}

Describe 'Get-WarmResumeStepAction (against the engine loader)' {

    # The rewind is only as good as the action list, and an empty list disables
    # it silently -- the resume simply proceeds from the checkpoint and nothing
    # says a boundary was missed. So this reads a real sequence off disk rather
    # than a hand-built list: it is the only assertion that catches the loader
    # contract changing underneath the reader.
    BeforeAll {
        $script:seqDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wr-seq-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:seqDir -Force | Out-Null
        $script:seqFile = Join-Path $script:seqDir 'workload.guest.ubuntu.server.24.probe.yml'
        @'
sequenceGuid: 42d9c1a7-3f5b-4e88-9a20-6b7c1d0e4f52
description: "Boundary-reader fixture: restore, wait, run, capture."
keystrokeMechanism: ssh
resource:
  ubuntu.server.24:
    - workload.guest.ubuntu.server.24.probe.base
requiresSnapshot:
  id: "probe"
component:
  - action: loadDiskSnapshot
    id: "probe"
    description: "Restore"
  - action: sshWaitReady
    timeoutSeconds: 300
    description: "SSH up"
workload:
  - action: sshFetchAndExecute
    description: "Run the payload"
  - action: saveSystemDiagnostic
    description: "Capture"
'@ | Set-Content -LiteralPath $script:seqFile -Encoding utf8
    }
    AfterAll {
        if ($script:seqDir -and (Test-Path -LiteralPath $script:seqDir)) {
            Remove-Item -LiteralPath $script:seqDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reads component and workload as one list, in the order -StartStep counts' {
        $a = @(Get-WarmResumeStepAction -Path $script:seqFile)
        Assert-Equal -Expected 4 -Actual $a.Count -Because 'an empty read would disable the rewind without saying so'
        Assert-Equal -Expected 'loadDiskSnapshot'   -Actual $a[0]
        Assert-Equal -Expected 'sshWaitReady'       -Actual $a[1]
        # workload continues the same numbering rather than restarting at 1.
        Assert-Equal -Expected 'sshFetchAndExecute' -Actual $a[2]
        Assert-Equal -Expected 'saveSystemDiagnostic' -Actual $a[3]
    }

    It 'drives a real rewind end to end' {
        # The shape that lost a cycle: a transient on the payload step, whose
        # restore point is step 1.
        $r = Get-WarmResumeRewindStep -StepAction (Get-WarmResumeStepAction -Path $script:seqFile) -ResumeFromStep 3
        Assert-Equal -Expected 1 -Actual $r.ResumeFromStep
        Assert-True $r.Rewound
    }

    It 'sees a restore nested inside a retry block, so the rewind still finds a boundary' {
        # A sequence may wrap restore + readiness in a `retry` so an attempt that
        # fails to put the guest in position replays from the snapshot. Reading
        # the wrapper's own name would leave no boundary in the list, and the
        # resume would restart on the residue of the step that failed.
        $wrapped = Join-Path $script:seqDir 'workload.guest.ubuntu.server.24.wrapped.yml'
        @'
sequenceGuid: 42a1b2c3-4d5e-4f60-8a91-2b3c4d5e6f70
description: "Boundary-reader fixture: the restore lives inside a retry block."
keystrokeMechanism: ssh
resource:
  ubuntu.server.24:
    - workload.guest.ubuntu.server.24.probe.base
requiresSnapshot:
  id: "probe"
component:
  - action: retry
    description: "Put the guest in position"
    steps:
      - action: loadDiskSnapshot
        id: "probe"
        description: "Restore"
      - action: sshWaitReady
        timeoutSeconds: 300
        description: "SSH up"
workload:
  - action: sshFetchAndExecute
    description: "Run the payload"
  - action: saveSystemDiagnostic
    description: "Capture"
'@ | Set-Content -LiteralPath $wrapped -Encoding utf8
        $a = @(Get-WarmResumeStepAction -Path $wrapped)
        Assert-Equal -Expected 3 -Actual $a.Count -Because 'the wrapper is one step, however many it wraps'
        Assert-Equal -Expected 'loadDiskSnapshot' -Actual $a[0] -Because 'the step leads with the restore, whatever the wrapper is called'
        $r = Get-WarmResumeRewindStep -StepAction $a -ResumeFromStep 2
        Assert-Equal -Expected 1 -Actual $r.ResumeFromStep
        Assert-True $r.Rewound 'a transient on the payload step must restart from the restore, not on top of it'
    }

    It 'returns nothing readable for a missing or blank path, without throwing' {
        Assert-Equal -Expected 0 -Actual (@(Get-WarmResumeStepAction -Path (Join-Path $script:seqDir 'no-such.yml'))).Count
        Assert-Equal -Expected 0 -Actual (@(Get-WarmResumeStepAction -Path '')).Count
    }
}

Describe 'Test-WarmResumeReplayIsSafe' {

    # Get-WarmResumeRewindStep pulls a resume back to the loadDiskSnapshot
    # before it so the replay meets the state its steps expect. With no such
    # boundary the resume proceeds in place, onto the residue the boundary
    # exists to discard -- harmless for a step that only waits or types, but
    # for one that ran guest work the replay fails on its own leftovers and
    # reports THAT instead of the transient that stopped the run.
    BeforeAll {
        $script:WithoutBoundary = @('retry', 'waitForText', 'fetchAndExecute', 'inputTextAndEnter', 'saveSystemDiagnostic')
    }

    It 'calls replaying a guest-work step unsafe when nothing can discard its residue' {
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $script:WithoutBoundary -ResumeFromStep 3)
    }

    It 'calls replaying a read-only step safe' {
        Assert-Equal -Expected $true -Actual (Test-WarmResumeReplayIsSafe -StepAction $script:WithoutBoundary -ResumeFromStep 2)
        Assert-Equal -Expected $true -Actual (Test-WarmResumeReplayIsSafe -StepAction $script:WithoutBoundary -ResumeFromStep 4)
    }

    It 'treats the ssh guest-work verbs the same as the console one' {
        $actions = @('sshWaitReady', 'sshFetchAndExecute', 'sshExec')
        Assert-Equal -Expected $true  -Actual (Test-WarmResumeReplayIsSafe -StepAction $actions -ResumeFromStep 1)
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $actions -ResumeFromStep 2)
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $actions -ResumeFromStep 3)
    }

    It 'treats an unreadable sequence as unsafe rather than assuming it is fine' {
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction @() -ResumeFromStep 1)
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $null -ResumeFromStep 1)
    }

    It 'treats an out-of-range checkpoint as unsafe' {
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $script:WithoutBoundary -ResumeFromStep 99)
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $script:WithoutBoundary -ResumeFromStep 0)
    }

    It 'pairs with the rewind: a boundary makes the same checkpoint recoverable' {
        $withBoundary = @('retry', 'loadDiskSnapshot', 'fetchAndExecute', 'inputTextAndEnter')
        $rw = Get-WarmResumeRewindStep -StepAction $withBoundary -ResumeFromStep 3
        Assert-Equal -Expected 2 -Actual $rw.BoundaryStep -Because 'the restore point is found'
        Assert-Equal -Expected $true -Actual $rw.Rewound
        # The guard keys off BoundaryStep, so the unsafe verdict no longer gates.
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $withBoundary -ResumeFromStep 3)
    }
}
