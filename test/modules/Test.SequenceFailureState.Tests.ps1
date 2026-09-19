<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42da4d2b-cbcd-4c6d-b4e8-973686da3b1a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test telemetry failure pester
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
    Pester coverage for the actionability enrichment in
    New-SequenceFailureRecord (Test.SequenceFailureState.psm1): the repro
    block, sequenceName, classificationSource, reason, and the inner-cause /
    replay-boundary fields on crash records.
.DESCRIPTION
    Throw-based assertions (OS-bundled Pester 3.4 / Pester 5+). Get-SequenceAction
    is stubbed globally so the builder resolves deterministic classifications
    independent of the live verb registry; the stub is removed at file end.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.SequenceFailureState.psm1'
$evtPath    = Join-Path $here 'Test.EventSchema.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module $evtPath    -Force -DisableNameChecking -ErrorAction SilentlyContinue

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# Deterministic verb registry: waitForText resolves, anything else is unknown.
# Dot-sourced into the module under test rather than defined globally: the
# builder resolves the name from its own session state first, and the stub dies
# with the module instead of outliving the file. A global function cannot be
# taken back -- Remove-Item on function:global: from inside a Pester block
# reports success and leaves the command in place -- so a global stub would
# shadow the real registry for every later file in the shared runspace.
. (Get-Module Test.SequenceFailureState) {
    function Get-SequenceAction {
        param([string]$Name)
        if ($Name -eq 'waitForText') {
            return [pscustomobject]@{ FailureClass = 'ocr_timeout'; Severity = 'hard'; SuggestedRecoveries = @('reconnect') }
        }
        return $null
    }
}

function Reset-FailState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: seeds the in-memory failure-state slots to a known baseline; no external state.')]
    param()
    $f = Get-SequenceFailureState
    $f.LastFailureLabel = 'waitForText: "login prompt"'
    $f.LastFailureDescription = 'OCR: yt2sqluser@'
    $f.LastFailedAction = 'waitForText'
    $f.LastFailedStepNumber = 3
    $f.LastSucceededStepNumber = 2
    $f.LastInnerFailedAction = $null
    $f.LastInnerFailureClass = $null
    $f.LastInnerSeverity = $null
    $f.LastInnerSuggestedRecoveries = [string[]]@()
    $f.WaitForTextMatchedFailurePattern = $null
    $f.WaitForTextOcrTail = $null
    $f.WaitForTextPatternsSought = [string[]]@()
    # Cleared here too, or a test that sets it leaves every later test in this
    # file reclassified as a flooded console -- the failure mode this baseline
    # exists to prevent.
    $f.WaitForTextConsoleFlood = $null
    # Same reasoning as the flood slot: a test that sets either of these would
    # otherwise leave every later test in this file reporting a parked console or
    # an operator hold it never had.
    $f.WaitForTextConsoleStaticSeconds = 0
    # And the qualifier on those two slots, for the same reason: a test that
    # clears it would leave every later test in this file publishing nulls.
    $f.WaitForTextConsoleSignalsMeasured = $true
    $f.LastPauseRelease = $null
    return $f
}

# The builder derives sequenceName with [System.IO.Path]::GetFileNameWithoutExtension,
# which splits only on the running platform's separator -- a backslash is an
# ordinary filename character on Linux/macOS. The path the engine hands it is
# always a local one, so build the fixture with the native separator and the
# basename resolves the same everywhere.
$script:seqPath = @('C:', 'repo', 'project', 'example',
    'workload.guest.ubuntu.server.24.k8s.text-to-sql.test.yml') -join [System.IO.Path]::DirectorySeparatorChar

}

Describe 'New-SequenceFailureRecord actionability enrichment (step)' {
    It 'carries sequenceName, reason, classificationSource and a repro block' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'k8s.text-to-sql' -GuestKey 'guest.ubuntu.server.24' -HostType 'host.windows.hyper-v' -SequencePath $script:seqPath -LogDir 'C:\cyc' -TotalSteps 11
        Assert-Equal -Expected 'workload.guest.ubuntu.server.24.k8s.text-to-sql.test' -Actual $r.File.sequenceName -Because 'sequenceName from path basename'
        Assert-Equal -Expected 'step' -Actual $r.File.reason -Because 'reason'
        Assert-Equal -Expected 'verb-registry' -Actual $r.File.classificationSource -Because 'resolved verb -> verb-registry'
        Assert-Equal -Expected 'ocr_timeout' -Actual $r.File.failureClass -Because 'class from stubbed registry'
        Assert-True ($null -ne $r.File.repro) 'repro block present'
        Assert-Equal -Expected 3 -Actual $r.File.repro.resumeFromStep -Because 'resumeFromStep = file-local failing step'
        Assert-Equal -Expected 'Debug-TestSequence' -Actual $r.File.repro.entrypoint -Because 'entrypoint'
    }
    It 'builds a repro command that omits -StartStep (chain-global vs file-local trap)' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'guest.ubuntu.server.24' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 11
        Assert-Match -Pattern 'Debug-TestSequence\.ps1' -Actual $r.File.repro.command -Because 'command runs Debug-TestSequence'
        Assert-Match -Pattern '-SequenceName "workload\.guest\.ubuntu\.server\.24\.k8s\.text-to-sql\.test"' -Actual $r.File.repro.command -Because 'names the failing sequence'
        Assert-True ($r.File.repro.command -notmatch '-StartStep') 'command must NOT contain -StartStep'
    }
    It 'strips shell-breaking characters from the repro command (no copy-paste injection)' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm";rm -rf /"' -GuestKey 'g$(whoami)' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 11
        $cmd = $r.File.repro.command
        Assert-True ($cmd -notmatch '\$') 'no $ (interpolation) survives sanitizing'
        Assert-True ($cmd -notmatch '";')  'no quote-then-command breakout survives sanitizing'
        # Only the 6 argument-wrapping quotes remain (3 quoted args x 2) -- the
        # two injected quotes were stripped.
        Assert-Equal -Expected 6 -Actual (@($cmd.ToCharArray() | Where-Object { $_ -eq '"' }).Count) -Because 'only wrapping quotes remain'
        Assert-True ($cmd -match '-VMName ') 'still emits a -VMName arg'
    }
    It 'mirrors the actionability fields onto the flat event (incl reproCommand)' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 11
        Assert-Equal -Expected $r.File.repro.command -Actual $r.Event.reproCommand -Because 'event reproCommand == file repro.command'
        Assert-Equal -Expected $r.File.sequenceName  -Actual $r.Event.sequenceName -Because 'event sequenceName'
        Assert-Equal -Expected 'verb-registry'       -Actual $r.Event.classificationSource -Because 'event classificationSource'
    }
    It 'emits an event that passes the cycle event schema validator' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 11
        $violations = Test-CycleEventSchema -Record $r.Event
        Assert-Equal -Expected 0 -Actual (@($violations).Count) -Because "event must validate; got: $($violations -join '; ')"
    }
}

Describe 'New-SequenceFailureRecord classificationSource discrimination' {
    It 'reports unresolved-verb (and unknown class) when the verb has no registration' {
        $f = Reset-FailState
        $f.LastFailedAction = 'no_such_verb'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'unresolved-verb' -Actual $r.File.classificationSource -Because 'unresolved verb'
        Assert-Equal -Expected 'unknown' -Actual $r.File.failureClass -Because 'unknown class for unresolved verb'
    }
    It 'reports pattern-match when a hard-block OCR pattern fired' {
        $f = Reset-FailState
        $f.WaitForTextMatchedFailurePattern = 'kernel panic'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'pattern-match' -Actual $r.File.classificationSource -Because 'pattern-match source'
        Assert-Equal -Expected 'pattern_matched_failure' -Actual $r.File.failureClass -Because 'reclassified to pattern_matched_failure'
    }
    It 'swaps the recovery hint to pause_and_inspect when reclassifying' {
        # The recoveries must move with the class. The registry's hint describes
        # the verb's DEFAULT failure -- for the timeout-style verbs that is
        # something worth retrying -- but a matched failure pattern is the
        # opposite case: the guest announced its own failure, so a retry only
        # re-runs a command already known to fail. The stub registry hands
        # waitForText a 'reconnect' hint, so this asserts the reclassification
        # REPLACES a registry hint rather than merely appending to an empty one.
        $f = Reset-FailState
        $f.WaitForTextMatchedFailurePattern = 'NONZERO SCRIPT EXIT:'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'pattern_matched_failure' -Actual $r.File.failureClass
        $sugg = @($r.File.suggestedRecoveries)
        Assert-Equal -Expected 1 -Actual $sugg.Count -Because "expected only pause_and_inspect; got: $($sugg -join ', ')"
        Assert-Equal -Expected 'pause_and_inspect' -Actual $sugg[0]
    }
    It 'reclassifies a flooded console instead of calling it a missing pattern' {
        # ocr_timeout's recoveries assume the pattern never printed, so they
        # restart the guest and wait again -- which reruns whatever was filling
        # the console. The two failures have different owners: a missing pattern
        # points at the guest script that should have printed it, a flooded
        # console points at whatever is overwriting the surface it would have
        # been read from.
        $f = Reset-FailState
        $f.WaitForTextConsoleFlood = "console filled with a repeating line while seeking 'Continue with autoinstall?'"
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'console_flooded' -Actual $r.File.failureClass -Because 'a flood is not an absent pattern'
        $sugg = @($r.File.suggestedRecoveries)
        Assert-Equal -Expected 1 -Actual $sugg.Count -Because "expected only pause_and_inspect; got: $($sugg -join ', ')"
        Assert-Equal -Expected 'pause_and_inspect' -Actual $sugg[0]
        Assert-True ($r.File.context.causeDetail.consoleFlood -like '*repeating line*') `
            'the evidence has to ride along, or the class is an assertion the artifact cannot support'
    }

    It 'records how long the console content sat unchanged' {
        # The flood detail alone cannot separate a console still filling from one
        # frozen on text that scrolled by earlier -- repeats are counted within a
        # single frame, so both read as a flood. Only the second is a guest parked
        # on something, and only the second can be unblocked by answering it.
        $f = Reset-FailState
        $f.WaitForTextConsoleFlood = "console filled with a repeating line while seeking 'Continue with autoinstall?'"
        $f.WaitForTextConsoleStaticSeconds = 840
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 840 -Actual $r.File.context.causeDetail.consoleStaticSeconds `
            -Because 'a wall of text that stopped moving is the evidence that the guest is waiting, not working'
    }

    It 'reports the console fields as unmeasured, not as zero, when the wait never looked' {
        # A wait confined to the console tail runs neither console-shape tracker,
        # so both slots hold their initializers -- the same 0 and '' a measured,
        # moving, non-repeating console produces. Published as numbers they assert
        # something about the screen that nothing observed, and the reader who
        # trusts them goes looking for a guest that was working the whole time.
        $f = Reset-FailState
        $f.WaitForTextConsoleSignalsMeasured = $false
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-True ($r.File.context.causeDetail.Contains('consoleStaticSeconds')) 'the field must always be present'
        Assert-True ($r.File.context.causeDetail.Contains('consoleFlood')) 'the field must always be present'
        Assert-True ($null -eq $r.File.context.causeDetail.consoleStaticSeconds) `
            'an unmeasured screen must not read as a screen measured at zero'
        Assert-True ($null -eq $r.File.context.causeDetail.consoleFlood) `
            'an unevaluated flood check must not read as a screen found non-repetitive'
        Assert-Equal -Expected 'ocr_timeout' -Actual $r.File.failureClass -Because 'not measuring the screen is not a reclassification'
    }

    It 'carries an operator hold released before the failing step' {
        # The pause gate holds the runner, not the guest: a VM keeps running and
        # printing through a hold, so a prompt printed during one is gone from the
        # screen the resumed step then has to read. A record that omits the hold
        # sends the reader looking for a guest fault that never happened.
        $f = Reset-FailState
        $f.LastPauseRelease = @{ releasedAtUtc = '2026-08-22T10:56:48Z'; heldSeconds = 1650; label = '[sequence start]'; pauseScope = 'step' }
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 1650 -Actual $r.File.context.causeDetail.pauseBeforeStepSeconds -Because 'the hold is part of the cause'
        Assert-Equal -Expected '2026-08-22T10:56:48Z' -Actual $r.File.context.causeDetail.pauseReleasedAtUtc -Because 'when it ended places it against the step'
    }

    It 'leaves the pause and static fields at zero, not absent, with no hold' {
        # Same contract the flood field is held to: always present, so a consumer
        # never has to tell "no hold" from "this record predates the gate".
        $null = Reset-FailState
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-True ($r.File.context.causeDetail.Contains('pauseBeforeStepSeconds')) 'the field must always be present'
        Assert-Equal -Expected 0 -Actual $r.File.context.causeDetail.pauseBeforeStepSeconds
        Assert-Equal -Expected '' -Actual $r.File.context.causeDetail.pauseReleasedAtUtc
        Assert-Equal -Expected 0 -Actual $r.File.context.causeDetail.consoleStaticSeconds
    }

    It 'ranks a matched failure pattern above a flooded console' {
        # A guest that announced its own failure in words outranks an inference
        # drawn from the shape of the screen -- the words are direct evidence and
        # the shape is circumstantial.
        $f = Reset-FailState
        $f.WaitForTextMatchedFailurePattern = 'NONZERO SCRIPT EXIT:'
        $f.WaitForTextConsoleFlood = 'console filled with a repeating line'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'pattern_matched_failure' -Actual $r.File.failureClass
    }

    It 'leaves the flood field empty, not absent, on an ordinary failure' {
        # A consumer must never have to tell "not flooded" from "this record
        # predates the check".
        $null = Reset-FailState
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-True ($r.File.context.causeDetail.Contains('consoleFlood')) 'the field must always be present'
        Assert-Equal -Expected '' -Actual $r.File.context.causeDetail.consoleFlood
        Assert-Equal -Expected 'ocr_timeout' -Actual $r.File.failureClass -Because 'no flood means no reclassification'
    }

    It 'keeps the registry recovery hint when no pattern matched' {
        # The counterpart: with no failure pattern, nothing is reclassified and
        # the verb's own hint must survive untouched. Without this, a swap that
        # fired unconditionally would look correct in the test above.
        $null = Reset-FailState
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'ocr_timeout' -Actual $r.File.failureClass
        Assert-Equal -Expected 'verb-registry' -Actual $r.File.classificationSource
        Assert-Equal -Expected 'reconnect' -Actual (@($r.File.suggestedRecoveries)[0]) -Because 'the registry hint is preserved'
    }
}

Describe 'New-SequenceFailureRecord OCR causeDetail' {
    It 'surfaces the OCR tail + sought patterns in the step record context and flat on the event' {
        $f = Reset-FailState
        $f.WaitForTextOcrTail = 'yt2sqluser@host:~$'
        $f.WaitForTextPatternsSought = [string[]]@('login prompt', 'Not listed?')
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 11
        Assert-Equal -Expected 'yt2sqluser@host:~$' -Actual $r.File.context.causeDetail.ocrTail -Because 'nested ocrTail'
        Assert-Equal -Expected 2 -Actual (@($r.File.context.causeDetail.patternsSought).Count) -Because 'nested patternsSought count'
        Assert-Equal -Expected 'yt2sqluser@host:~$' -Actual $r.Event.causeOcrTail -Because 'flat event ocr tail mirrors context'
        Assert-Equal -Expected 2 -Actual (@($r.Event.causePatternsSought).Count) -Because 'flat event patterns count'
    }
    It 'defaults to empty (array, not null) when no wait cause was captured' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 11
        Assert-Equal -Expected '' -Actual $r.Event.causeOcrTail -Because 'empty ocr tail'
        Assert-Equal -Expected 0 -Actual (@($r.Event.causePatternsSought).Count) -Because 'empty patterns array (not null)'
        $violations = Test-CycleEventSchema -Record $r.Event
        Assert-Equal -Expected 0 -Actual (@($violations).Count) -Because "event still validates; got: $($violations -join '; ')"
    }
    It 'omits causeDetail from a crash record context but keeps the flat event fields' {
        [void](Reset-FailState)
        $err = $null
        try { throw 'boom' } catch { $err = $_ }
        $r = New-SequenceFailureRecord -Reason crash -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5 -CrashError $err
        Assert-True (-not $r.File.context.Contains('causeDetail')) 'crash context has no causeDetail'
        Assert-True ($r.Event.Contains('causeOcrTail')) 'crash event keeps the uniform flat field'
    }
}

Describe 'New-SequenceFailureRecord crash record backfill' {
    It 'reports reason=crash / classificationSource=crash and carries replay boundary + inner fields' {
        [void](Reset-FailState)
        $err = $null
        try { throw 'boom' } catch { $err = $_ }
        $r = New-SequenceFailureRecord -Reason crash -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5 -CrashError $err
        Assert-Equal -Expected 'crash' -Actual $r.File.reason -Because 'reason'
        Assert-Equal -Expected 'crash' -Actual $r.File.classificationSource -Because 'classificationSource'
        Assert-True ($r.File.Contains('lastSucceededStepNumber')) 'crash record carries replay boundary'
        Assert-Equal -Expected 2 -Actual $r.File.lastSucceededStepNumber -Because 'replay boundary value'
        Assert-True ($r.File.Contains('innerActionVerb')) 'crash record carries inner-cause slot'
        Assert-True ($null -ne $r.File.repro) 'crash record still has a repro block'
    }
}

Describe 'New-InfraFailureRecord (infra-stage failures)' {
    It 'builds a schema-v2 record with reason=infra / classificationSource=infra-stage' {
        $r = New-InfraFailureRecord -Stage 'New-VM' -FailureClass 'provisioning_failure' -Severity 'hard' -GuestKey 'guest.x' -VMName 'vm1' -HostType 'host.windows.hyper-v' -ErrorMessage 'define failed'
        Assert-Equal -Expected 2 -Actual $r.File.schemaVersion -Because 'schema v2'
        Assert-Equal -Expected 'infra' -Actual $r.File.reason -Because 'reason'
        Assert-Equal -Expected 'infra-stage' -Actual $r.File.classificationSource -Because 'classificationSource'
        Assert-Equal -Expected 'provisioning_failure' -Actual $r.File.failureClass -Because 'class'
        Assert-Equal -Expected 'New-VM' -Actual $r.File.actionVerb -Because 'stage as actionVerb'
        Assert-Equal -Expected 0 -Actual $r.File.stepNumber -Because 'no step for an infra stage'
        Assert-True (@($r.File.suggestedRecoveries) -is [array]) 'suggestedRecoveries is an array'
    }
    It 'emits an event that passes the cycle event schema validator (in-enum class)' {
        foreach ($cls in 'provisioning_failure','bootstrap_sync','plan_invalid','network_timeout') {
            $r = New-InfraFailureRecord -Stage 'GitPull' -FailureClass $cls -GuestKey '(bootstrap)' -ErrorMessage 'x'
            $v = Test-CycleEventSchema -Record $r.Event
            Assert-Equal -Expected 0 -Actual (@($v).Count) -Because "event for $cls must validate; got: $($v -join '; ')"
        }
    }

    # What the machine held when it refused is recoverable from nothing else the
    # cycle keeps -- those numbers exist only in the instant of the call -- so a
    # driver that measured them has to get them into the record and onto the
    # stream, and the file nests them while the event carries them flat.
    It 'carries a measured host memory position into the record and the event' {
        $reading = @{ availableMb = 1192; committedBytes = 46236958720; commitLimitBytes = 48257269760
                      commitAvailableBytes = 2020311040; source = 'Win32_OperatingSystem' }
        $r = New-InfraFailureRecord -Stage 'Start-VM' -FailureClass 'provisioning_failure' -GuestKey 'guest.x' `
            -VMName 'vm1' -HostType 'host.windows.hyper-v' -ErrorMessage 'refused' -HostMemory $reading
        $block = $r.File.context['hostMemory']
        Assert-NotNull $block 'a measured reading must reach the record'
        foreach ($key in 'availableMb', 'committedBytes', 'commitLimitBytes', 'commitAvailableBytes', 'source') {
            Assert-True ($block.Contains($key)) "the nested block must state $key"
        }
        Assert-Equal -Expected 'Win32_OperatingSystem' -Actual $block['source'] -Because 'the reading names where it came from'
        Assert-Equal -Expected 1192 -Actual $r.Event['hostAvailableMb'] -Because 'flat event field'
        Assert-Equal -Expected 46236958720 -Actual $r.Event['hostCommittedBytes'] -Because 'flat event field'
        Assert-Equal -Expected 48257269760 -Actual $r.Event['hostCommitLimitBytes'] -Because 'flat event field'
        Assert-Equal -Expected 2020311040 -Actual $r.Event['hostCommitAvailableBytes'] -Because 'flat event field'
        # A commit figure overflows Int32 on any host worth measuring, so the
        # width is part of the contract rather than an implementation detail.
        Assert-True ($r.Event['hostCommittedBytes'] -is [long]) 'byte counts must be Int64'
        $roundTrip = $r.File | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        Assert-Equal -Expected 48257269760 -Actual $roundTrip.context.hostMemory.commitLimitBytes `
            -Because 'the reading has to survive the serialization the record is stored and read through'
    }

    # ABSENT, never zeroed: a zeroed reading is indistinguishable from a measured
    # one, and a fabricated memory figure reads as a measurement. The drivers
    # that cannot measure their host state nothing at all.
    It 'states no host memory at all when the driver could not measure it' {
        $cases = @(
            @{ Label = 'no argument'; Reading = $null; Pass = $false },
            @{ Label = 'an explicit null'; Reading = $null; Pass = $true },
            @{ Label = 'an empty reading'; Reading = @{}; Pass = $true },
            @{ Label = 'a partial reading with no commit limit'; Reading = @{ availableMb = 1192 }; Pass = $true }
        )
        foreach ($case in $cases) {
            $r = if ($case.Pass) {
                New-InfraFailureRecord -Stage 'Start-VM' -FailureClass 'provisioning_failure' -GuestKey 'guest.x' -ErrorMessage 'refused' -HostMemory $case.Reading
            } else {
                New-InfraFailureRecord -Stage 'Start-VM' -FailureClass 'provisioning_failure' -GuestKey 'guest.x' -ErrorMessage 'refused'
            }
            Assert-False ($r.File.context.Contains('hostMemory')) "$($case.Label): the record must carry no hostMemory block"
            foreach ($field in 'hostAvailableMb', 'hostCommittedBytes', 'hostCommitLimitBytes', 'hostCommitAvailableBytes') {
                Assert-False ($r.Event.Contains($field)) "$($case.Label): the event must not carry $field"
            }
        }
    }

    It 'emits an event that still validates with the host memory fields on it' {
        $reading = @{ availableMb = 1192; committedBytes = 46236958720; commitLimitBytes = 48257269760
                      commitAvailableBytes = 2020311040; source = 'Win32_PerfRawData_PerfOS_Memory' }
        $r = New-InfraFailureRecord -Stage 'Start-VM' -FailureClass 'provisioning_failure' -GuestKey 'guest.x' `
            -ErrorMessage 'refused' -HostMemory $reading
        $v = @(Test-CycleEventSchema -Record $r.Event)
        Assert-Equal -Expected 0 -Actual $v.Count -Because "a measured reading must not make the event invalid; got: $($v -join '; ')"
    }
}

# Drop the module the stub was dot-sourced into, so nothing this file defined is
# visible to the files that run after it in the shared runspace.
AfterAll {
    Remove-Module Test.SequenceFailureState -Force -ErrorAction SilentlyContinue
}
