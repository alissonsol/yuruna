<#PSScriptInfo
.VERSION 2026.10.11.1
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
    Throw-based assertions for Pester 5+.
    Test.EventSchema is imported (it auto-loads Test.FailureTaxonomy) so the
    event builder is validated against the real schema.
    Run with:  pwsh -NoProfile -File test/modules/Test.WarmResume.Tests.ps1
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The stand-ins for the sequence resolver and the snapshot probe are global functions, so the case state they read has to be global too.')]
param()

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.EventSchema.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.WarmResume.psm1')  -Force -DisableNameChecking
# The replay class of each verb is declared where the verb registers, so the
# registrations are part of what the safety check reads.
Import-Module (Join-Path $here 'Test.SequenceHandler.psm1') -Force -DisableNameChecking -Global
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

# --- REGION: Fixture helpers
# See https://yuruna.link/42e220c4-0014
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
        foreach ($c in 'network_timeout','wait_timeout','instrumentation_failure','host_io_blocked','ip_not_discovered','payload_unavailable','input_lost') {
            Assert-True (Test-WarmResumeEligibleClass -FailureClass $c) "expected eligible: $c"
        }
        Assert-Equal -Expected 7 -Actual (Get-WarmResumeEligibleClass).Count
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
    # boundary the resume would proceed in place, onto the residue the boundary
    # exists to discard. Only a step that observes can be replayed that way; a
    # step that types, or that changes guest, host or external state, leaves the
    # replay failing on (or compounding) its own leftovers and reporting THAT
    # instead of the transient that stopped the run.
    BeforeAll {
        $script:WithoutBoundary = @('retry', 'waitForText', 'fetchAndExecute', 'inputTextAndEnter', 'saveSystemDiagnostic')
    }

    It 'calls replaying a guest-work step unsafe when nothing can discard its residue' {
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $script:WithoutBoundary -ResumeFromStep 3)
    }

    It 'calls replaying a step that only observes safe' {
        Assert-Equal -Expected $true -Actual (Test-WarmResumeReplayIsSafe -StepAction $script:WithoutBoundary -ResumeFromStep 2)
        Assert-Equal -Expected $true -Actual (Test-WarmResumeReplayIsSafe -StepAction $script:WithoutBoundary -ResumeFromStep 5)
    }

    It 'calls replaying a step that types into the guest unsafe' {
        # A command half-entered when the host stopped delivering keys is still on
        # the line; typing it again appends to it.
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $script:WithoutBoundary -ResumeFromStep 4)
    }

    It 'calls replaying an extension call unsafe' {
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction @('callExtension') -ResumeFromStep 1)
    }

    It 'treats the ssh guest-work verbs the same as the console one' {
        $actions = @('sshWaitReady', 'sshFetchAndExecute', 'sshExec')
        Assert-Equal -Expected $true  -Actual (Test-WarmResumeReplayIsSafe -StepAction $actions -ResumeFromStep 1)
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $actions -ResumeFromStep 2)
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $actions -ResumeFromStep 3)
    }

    It 'treats a verb nobody registered as unsafe rather than assuming it is fine' {
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction @('noSuchVerb') -ResumeFromStep 1)
        Assert-Equal -Expected 'unclassified' -Actual (Get-WarmResumeReplayClass -StepAction @('noSuchVerb') -ResumeFromStep 1)
    }

    It 'treats a wrapper that surfaces with nothing inside as unsafe' {
        # The first entry of $WithoutBoundary: a `retry` the loader could not
        # read any step out of has no behavior anyone vouched for.
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $script:WithoutBoundary -ResumeFromStep 1)
    }

    It 'treats an unreadable sequence as unsafe rather than assuming it is fine' {
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction @() -ResumeFromStep 1)
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $null -ResumeFromStep 1)
    }

    It 'treats an out-of-range checkpoint as unsafe' {
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $script:WithoutBoundary -ResumeFromStep 99)
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $script:WithoutBoundary -ResumeFromStep 0)
    }

    It 'prefers the whole-step reading over the verb the step leads with' {
        # The lead verb alone would call this step safe.
        $lead = @('waitForText')
        Assert-Equal -Expected $true  -Actual (Test-WarmResumeReplayIsSafe -StepAction $lead -ResumeFromStep 1)
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $lead -ResumeFromStep 1 -StepReplayClass @('input'))
        Assert-Equal -Expected 'input' -Actual (Get-WarmResumeReplayClass -StepAction $lead -ResumeFromStep 1 -StepReplayClass @('input'))
    }

    It 'ignores a whole-step reading that does not line up with the action list' {
        Assert-Equal -Expected $true -Actual (Test-WarmResumeReplayIsSafe -StepAction @('waitForText') -ResumeFromStep 1 -StepReplayClass @('input', 'input'))
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

Describe 'Replay safety is declared by every registered action' {

    # The class lives with the verb so a verb added later cannot default to
    # "replaying it is fine". This reads the live registry, which is the only
    # check that notices a registration that forgot to declare one.
    It 'gives every registered action an explicit class' {
        $names = @(Get-SequenceActionName)
        Assert-True ($names.Count -ge 20) "the registry is populated (found $($names.Count))"
        $undeclared = @($names | Where-Object { (Get-SequenceActionReplaySafety -Name $_) -eq 'unclassified' })
        Assert-Equal -Expected '' -Actual ($undeclared -join ', ') -Because 'every verb must declare -ReplaySafety'
    }

    It 'lets only the observing verbs be replayed in place' {
        # Pinned on purpose: widening this set widens what a resume will replay
        # onto a failed attempt's residue, so it takes a deliberate edit here.
        $observing = @(Get-SequenceActionName | Where-Object { (Get-SequenceActionReplaySafety -Name $_) -eq 'observe' } | Sort-Object)
        $expected = @('break', 'saveGuestClockSnapshot', 'saveSystemDiagnostic', 'sshWaitReady', 'takeScreenshot', 'waitForSeconds', 'waitForText', 'waitForTextWithNudge')
        Assert-Equal -Expected ($expected -join ',') -Actual ($observing -join ',')
    }

    It 'classes the verbs that type or change state as unsafe to replay in place' -TestCases @(
        @{ Verb = 'pressKey' }, @{ Verb = 'inputText' }, @{ Verb = 'inputTextAndEnter' }, @{ Verb = 'waitForAndEnter' }
        @{ Verb = 'passwdPrompt' }, @{ Verb = 'tapOn' }, @{ Verb = 'callExtension' }, @{ Verb = 'fetchAndExecute' }
        @{ Verb = 'sshExec' }, @{ Verb = 'sshFetchAndExecute' }, @{ Verb = 'saveDiskSnapshot' }, @{ Verb = 'startVm' }
        @{ Verb = 'networkRelease' }, @{ Verb = 'loadDiskSnapshot' }, @{ Verb = 'recoverFromSnapshot' }
    ) {
        param($Verb)
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction @($Verb) -ResumeFromStep 1) -Because $Verb
    }

    It 'resolves an alias to the verb it stands for' {
        Assert-Equal -Expected (Get-SequenceActionReplaySafety -Name 'inputTextAndEnter') -Actual (Get-SequenceActionReplaySafety -Name 'typeAndEnter')
    }

    It 'reports an unregistered name as unclassified, never as safe' {
        Assert-Equal -Expected 'unclassified' -Actual (Get-SequenceActionReplaySafety -Name 'noSuchVerb')
    }
}

Describe 'Get-WarmResumeStepReplayClass (against the engine loader)' {

    BeforeAll {
        $script:rcDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wr-rc-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:rcDir -Force | Out-Null
        $script:rcFile = Join-Path $script:rcDir 'workload.guest.ubuntu.server.24.replay.yml'
        @'
sequenceGuid: 42b7a1c3-5d2e-4f60-9a81-3c4d5e6f7a80
description: "Replay-class fixture: a wrapper that leads with a wait and then types."
keystrokeMechanism: ssh
resource:
  ubuntu.server.24:
    - workload.guest.ubuntu.server.24.probe.base
requiresSnapshot:
  id: "probe"
component:
  - action: sshWaitReady
    timeoutSeconds: 300
    description: "SSH up"
  - action: retry
    description: "Wait, then type"
    steps:
      - action: waitForText
        pattern: "login:"
        description: "Wait for the prompt"
      - action: inputTextAndEnter
        text: "echo hello"
        description: "Type"
  - action: retry
    description: "Only observes"
    steps:
      - action: waitForText
        pattern: "login:"
        description: "Wait for the prompt"
      - action: takeScreenshot
        description: "Look"
workload:
  - action: sshFetchAndExecute
    description: "Run the payload"
'@ | Set-Content -LiteralPath $script:rcFile -Encoding utf8
    }
    AfterAll {
        if ($script:rcDir -and (Test-Path -LiteralPath $script:rcDir)) {
            Remove-Item -LiteralPath $script:rcDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reads a whole step, so a wrapper is as unsafe as the least safe thing it holds' {
        $classes = @(Get-WarmResumeStepReplayClass -Path $script:rcFile)
        Assert-Equal -Expected 4 -Actual $classes.Count -Because 'one entry per top-level step, aligned with the action list'
        Assert-Equal -Expected 'observe' -Actual $classes[0]
        Assert-Equal -Expected 'input' -Actual $classes[1] -Because 'it leads with a wait but replaying it types'
        Assert-Equal -Expected 'observe' -Actual $classes[2]
        Assert-Equal -Expected 'state-changing' -Actual $classes[3]
    }

    It 'lines up with the lead-action list the rewind reads' {
        $actions = @(Get-WarmResumeStepAction -Path $script:rcFile)
        $classes = @(Get-WarmResumeStepReplayClass -Path $script:rcFile)
        Assert-Equal -Expected $actions.Count -Actual $classes.Count
        Assert-Equal -Expected 'waitForText' -Actual $actions[1] -Because 'the lead verb of the typing wrapper is a wait'
        Assert-Equal -Expected $true  -Actual (Test-WarmResumeReplayIsSafe -StepAction $actions -ResumeFromStep 2) -Because 'the lead verb alone would pass'
        Assert-Equal -Expected $false -Actual (Test-WarmResumeReplayIsSafe -StepAction $actions -ResumeFromStep 2 -StepReplayClass $classes)
        Assert-Equal -Expected $true   -Actual (Test-WarmResumeReplayIsSafe -StepAction $actions -ResumeFromStep 3 -StepReplayClass $classes)
    }

    It 'returns nothing readable for a missing or blank path, without throwing' {
        Assert-Equal -Expected 0 -Actual (@(Get-WarmResumeStepReplayClass -Path (Join-Path $script:rcDir 'no-such.yml'))).Count
        Assert-Equal -Expected 0 -Actual (@(Get-WarmResumeStepReplayClass -Path '')).Count
    }
}

Describe 'Get-WarmResumeBoundarySnapshotId' {

    BeforeAll {
        $script:bsDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wr-bs-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:bsDir -Force | Out-Null
        $script:bsLiteral = Join-Path $script:bsDir 'workload.guest.ubuntu.server.24.literal.yml'
        @'
sequenceGuid: 42c8b2d4-6e3f-4071-8b92-4d5e6f7a8b91
description: "Boundary id fixture: a literal id, then one nested inside a retry."
keystrokeMechanism: ssh
resource:
  ubuntu.server.24:
    - workload.guest.ubuntu.server.24.probe.base
requiresSnapshot:
  id: "probe"
component:
  - action: loadDiskSnapshot
    id: "probe-literal"
    description: "Restore"
  - action: retry
    description: "Put the guest in position"
    steps:
      - action: loadDiskSnapshot
        id: "probe-nested"
        description: "Restore"
      - action: sshWaitReady
        timeoutSeconds: 300
        description: "SSH up"
  - action: loadDiskSnapshot
    id: "${snapshotName}"
    description: "Restore by variable"
workload:
  - action: sshFetchAndExecute
    description: "Run the payload"
'@ | Set-Content -LiteralPath $script:bsLiteral -Encoding utf8
    }
    AfterAll {
        if ($script:bsDir -and (Test-Path -LiteralPath $script:bsDir)) {
            Remove-Item -LiteralPath $script:bsDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns the literal id of a top-level restore' {
        Assert-Equal -Expected 'probe-literal' -Actual (Get-WarmResumeBoundarySnapshotId -Path $script:bsLiteral -BoundaryStep 1)
    }
    It 'returns the id of a restore nested first inside a wrapper' {
        Assert-Equal -Expected 'probe-nested' -Actual (Get-WarmResumeBoundarySnapshotId -Path $script:bsLiteral -BoundaryStep 2)
    }
    It 'returns nothing for an id built from variables, which only the restore step can resolve' {
        Assert-Equal -Expected '' -Actual (Get-WarmResumeBoundarySnapshotId -Path $script:bsLiteral -BoundaryStep 3)
    }
    It 'returns nothing for a step that is not a restore, an out-of-range step or an unreadable file' {
        Assert-Equal -Expected '' -Actual (Get-WarmResumeBoundarySnapshotId -Path $script:bsLiteral -BoundaryStep 4)
        Assert-Equal -Expected '' -Actual (Get-WarmResumeBoundarySnapshotId -Path $script:bsLiteral -BoundaryStep 99)
        Assert-Equal -Expected '' -Actual (Get-WarmResumeBoundarySnapshotId -Path $script:bsLiteral -BoundaryStep 0)
        Assert-Equal -Expected '' -Actual (Get-WarmResumeBoundarySnapshotId -Path (Join-Path $script:bsDir 'no-such.yml') -BoundaryStep 1)
    }
}

Describe 'New-WarmResumeDeclinedEvent' {

    It 'builds a schema-valid event carrying the reason and the step class' {
        $ev = New-WarmResumeDeclinedEvent -GuestKey 'guest.ubuntu.server.24' -VmName 'vm-01' -SequenceName 'workload.guest.ubuntu.server.24.x' `
            -ResumeFromStep 3 -FailureClass 'host_io_blocked' -Reason 'no-restore-point' -ReplayClass 'input' -HostType 'host.ubuntu.kvm'
        Assert-Equal -Expected 'warm_resume_declined' -Actual $ev.event
        Assert-Equal -Expected 'no-restore-point' -Actual $ev.reason
        Assert-Equal -Expected 'input' -Actual $ev.replayClass
        Assert-Equal -Expected 3 -Actual $ev.resumeFromStep
        $v = @(Test-CycleEventSchema -Record ([hashtable]$ev))
        Assert-Equal -Expected 0 -Actual $v.Count -Because "schema violations: $($v -join '; ')"
    }
    It 'drops blank context fields so the typed-string schema check passes' {
        $ev = New-WarmResumeDeclinedEvent -GuestKey 'g' -VmName '' -SequenceName 's' -ResumeFromStep 1 -FailureClass '' `
            -Reason 'safety-check-unavailable' -ReplayClass '' -HostType ''
        foreach ($field in 'vmName', 'failureClass', 'replayClass', 'hostType') {
            Assert-True (-not $ev.Contains($field)) "$field is omitted rather than blank"
        }
        $v = @(Test-CycleEventSchema -Record ([hashtable]$ev))
        Assert-Equal -Expected 0 -Actual $v.Count -Because "schema violations: $($v -join '; ')"
    }
}

Describe 'Resolve-WarmResumeReplayPlan' {
    BeforeAll {
        $script:rpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wr-rp-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:rpDir -Force | Out-Null
        $script:rpWithBoundary = Join-Path $script:rpDir 'workload.guest.ubuntu.server.24.boundary.yml'
        @'
sequenceGuid: 42c8b2d4-6e3f-4071-8b92-4d5e6f7a8b92
description: "Replay plan fixture: a restore point, then a state-changing step, then an observing step."
keystrokeMechanism: ssh
resource:
  ubuntu.server.24:
    - workload.guest.ubuntu.server.24.probe.base
requiresSnapshot:
  id: "probe"
component:
  - action: loadDiskSnapshot
    id: "plan-probe"
    description: "Restore"
  - action: sshWaitReady
    timeoutSeconds: 300
    description: "SSH up"
workload:
  - action: inputTextAndEnter
    text: "echo hello"
    description: "Type"
  - action: waitForText
    pattern: "hello"
    description: "Observe"
'@ | Set-Content -LiteralPath $script:rpWithBoundary -Encoding utf8
        $script:rpNoBoundary = Join-Path $script:rpDir 'workload.guest.ubuntu.server.24.noboundary.yml'
        @'
sequenceGuid: 42c8b2d4-6e3f-4071-8b92-4d5e6f7a8b93
description: "Replay plan fixture: no restore point anywhere."
keystrokeMechanism: ssh
resource:
  ubuntu.server.24:
    - workload.guest.ubuntu.server.24.probe.base
requiresSnapshot:
  id: "probe"
workload:
  - action: waitForText
    pattern: "ready"
    description: "Observe"
  - action: inputTextAndEnter
    text: "echo hello"
    description: "Type"
  - action: waitForText
    pattern: "hello"
    description: "Observe"
'@ | Set-Content -LiteralPath $script:rpNoBoundary -Encoding utf8
        $global:__rpPlan = @{ Path = $script:rpWithBoundary; SnapshotPresent = $true; SeenName = ''; SnapshotProbeThrows = $false }
        # Only the name matters here; the other named arguments land in $args.
        function global:Resolve-SequencePath {
            param($Name)
            $global:__rpPlan.SeenName = [string]$Name
            return $global:__rpPlan.Path
        }
        function global:Test-VMDiskSnapshot {
            if ($global:__rpPlan.SnapshotProbeThrows) { throw 'the hypervisor did not answer' }
            return $global:__rpPlan.SnapshotPresent
        }
        function Build-RPDecision { param([string]$Sequence = 'workload.guest.ubuntu.server.24.boundary') return [pscustomobject]@{ ResumeSequence = $Sequence } }
        function Build-RPCheckpoint { param([int]$Step) return [pscustomobject]@{ ResumeFromStep = $Step; FailureClass = 'wait_timeout' } }
    }
    AfterAll {
        # The path form: the scope-qualified spelling removes nothing.
        Remove-Item -Path Function:\Resolve-SequencePath, Function:\Test-VMDiskSnapshot -ErrorAction SilentlyContinue
        Remove-Variable __rpPlan -Scope Global -ErrorAction SilentlyContinue
        if ($script:rpDir -and (Test-Path -LiteralPath $script:rpDir)) { Remove-Item -LiteralPath $script:rpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    BeforeEach { $global:__rpPlan = @{ Path = $script:rpWithBoundary; SnapshotPresent = $true; SeenName = ''; SnapshotProbeThrows = $false } }

    It 'rewinds to the restore point that precedes the checkpoint and replays from there' {
        $plan = Resolve-WarmResumeReplayPlan -Decision (Build-RPDecision) -Checkpoint (Build-RPCheckpoint 3) -VMName 'vm-1'
        Assert-Equal -Expected '' -Actual $plan.DeclineReason
        Assert-Equal -Expected $true -Actual $plan.Rewound
        Assert-Equal -Expected 1 -Actual $plan.BoundaryStep
        Assert-Equal -Expected 1 -Actual $plan.ResumeFromStep
        Assert-Equal -Expected '' -Actual $plan.ReplayClass -Because 'the class is computed only when declining'
    }
    It 'strips the .yml suffix the workload list may carry before it resolves the sequence' {
        $null = Resolve-WarmResumeReplayPlan -Decision (Build-RPDecision 'workload.guest.ubuntu.server.24.boundary.yml') -Checkpoint (Build-RPCheckpoint 3) -VMName 'vm-1'
        Assert-Equal -Expected 'workload.guest.ubuntu.server.24.boundary' -Actual $global:__rpPlan.SeenName
    }
    It 'treats a restore point the host does not have as no boundary, and declines a state-changing replay' {
        $global:__rpPlan.SnapshotPresent = $false
        $plan = Resolve-WarmResumeReplayPlan -Decision (Build-RPDecision) -Checkpoint (Build-RPCheckpoint 3) -VMName 'vm-1'
        Assert-Equal -Expected 'restore-point-missing' -Actual $plan.DeclineReason
        Assert-Equal -Expected $false -Actual $plan.Rewound
        Assert-Equal -Expected 0 -Actual $plan.BoundaryStep
        Assert-Equal -Expected 3 -Actual $plan.ResumeFromStep -Because 'the checkpoint stands'
        Assert-True ($plan.ReplayClass -and $plan.ReplayClass -ne 'observe') 'the declined replay names a class that is not observe'
    }
    It 'still replays an observing step in place when the restore point is missing' {
        $global:__rpPlan.SnapshotPresent = $false
        $plan = Resolve-WarmResumeReplayPlan -Decision (Build-RPDecision) -Checkpoint (Build-RPCheckpoint 4) -VMName 'vm-1'
        Assert-Equal -Expected '' -Actual $plan.DeclineReason
        Assert-Equal -Expected 4 -Actual $plan.ResumeFromStep
    }
    It 'reads a probe that cannot answer as the restore point being present, leaving the restore step to fail loudly' {
        $global:__rpPlan.SnapshotProbeThrows = $true
        $plan = Resolve-WarmResumeReplayPlan -Decision (Build-RPDecision) -Checkpoint (Build-RPCheckpoint 3) -VMName 'vm-1'
        Assert-Equal -Expected '' -Actual $plan.DeclineReason
        Assert-Equal -Expected 1 -Actual $plan.BoundaryStep
    }
    It 'declines a state-changing replay when the sequence has no restore point at all' {
        $global:__rpPlan.Path = $script:rpNoBoundary
        $plan = Resolve-WarmResumeReplayPlan -Decision (Build-RPDecision 'workload.guest.ubuntu.server.24.noboundary') -Checkpoint (Build-RPCheckpoint 2) -VMName 'vm-1'
        Assert-Equal -Expected 'no-restore-point' -Actual $plan.DeclineReason
        Assert-Equal -Expected 2 -Actual $plan.ResumeFromStep
    }
    It 'replays an observing step when the sequence has no restore point' {
        $global:__rpPlan.Path = $script:rpNoBoundary
        $plan = Resolve-WarmResumeReplayPlan -Decision (Build-RPDecision 'workload.guest.ubuntu.server.24.noboundary') -Checkpoint (Build-RPCheckpoint 1) -VMName 'vm-1'
        Assert-Equal -Expected '' -Actual $plan.DeclineReason
    }
    It 'declines when the sequence cannot be found, because nothing about its steps is known' {
        $global:__rpPlan.Path = ''
        $plan = Resolve-WarmResumeReplayPlan -Decision (Build-RPDecision) -Checkpoint (Build-RPCheckpoint 3) -VMName 'vm-1'
        Assert-Equal -Expected 'no-restore-point' -Actual $plan.DeclineReason
        Assert-Equal -Expected 0 -Actual @($plan.Actions).Count
    }
    It 'declines as unavailable when the safety check itself fails' {
        Mock -ModuleName Test.WarmResume Test-WarmResumeReplayIsSafe { throw 'the check broke' }
        $global:__rpPlan.Path = $script:rpNoBoundary
        $plan = Resolve-WarmResumeReplayPlan -Decision (Build-RPDecision 'workload.guest.ubuntu.server.24.noboundary') -Checkpoint (Build-RPCheckpoint 1) -VMName 'vm-1'
        Assert-Equal -Expected 'safety-check-unavailable' -Actual $plan.DeclineReason
    }
}
