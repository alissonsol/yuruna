<#PSScriptInfo
.VERSION 2026.06.26
.GUID 42b1f7c4-3a8e-4d52-9c61-0e7a2b3c4d5f
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

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.SequenceFailureState.psm1'
$evtPath    = Join-Path $here 'Test.EventSchema.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module $evtPath    -Force -DisableNameChecking -ErrorAction SilentlyContinue

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Match { param([string]$Pattern, [string]$Actual, [string]$Because='') if ($Actual -notmatch $Pattern) { throw "Expected /$Pattern/ to match [$Actual]. $Because" } }

# Deterministic verb registry: waitForText resolves, anything else is unknown.
function global:Get-SequenceAction {
    param([string]$Name)
    if ($Name -eq 'waitForText') {
        return [pscustomobject]@{ FailureClass = 'ocr_timeout'; Severity = 'hard'; SuggestedRecoveries = @('reconnect') }
    }
    return $null
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
    return $f
}

$seqPath = 'C:\repo\project\example\workload.guest.ubuntu.server.24.k8s.text-to-sql.test.yml'

Describe 'New-SequenceFailureRecord actionability enrichment (step)' {
    It 'carries sequenceName, reason, classificationSource and a repro block' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'k8s.text-to-sql' -GuestKey 'guest.ubuntu.server.24' -HostType 'host.windows.hyper-v' -SequencePath $seqPath -LogDir 'C:\cyc' -TotalSteps 11
        Assert-Equal 'workload.guest.ubuntu.server.24.k8s.text-to-sql.test' $r.File.sequenceName 'sequenceName from path basename'
        Assert-Equal 'step' $r.File.reason 'reason'
        Assert-Equal 'verb-registry' $r.File.classificationSource 'resolved verb -> verb-registry'
        Assert-Equal 'ocr_timeout' $r.File.failureClass 'class from stubbed registry'
        Assert-True ($null -ne $r.File.repro) 'repro block present'
        Assert-Equal 3 $r.File.repro.resumeFromStep 'resumeFromStep = file-local failing step'
        Assert-Equal 'Test-Sequence' $r.File.repro.entrypoint 'entrypoint'
    }
    It 'builds a repro command that omits -StartStep (chain-global vs file-local trap)' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'guest.ubuntu.server.24' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 11
        Assert-Match 'Test-Sequence\.ps1' $r.File.repro.command 'command runs Test-Sequence'
        Assert-Match '-SequenceName "workload\.guest\.ubuntu\.server\.24\.k8s\.text-to-sql\.test"' $r.File.repro.command 'names the failing sequence'
        Assert-True ($r.File.repro.command -notmatch '-StartStep') 'command must NOT contain -StartStep'
    }
    It 'strips shell-breaking characters from the repro command (no copy-paste injection)' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm";rm -rf /"' -GuestKey 'g$(whoami)' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 11
        $cmd = $r.File.repro.command
        Assert-True ($cmd -notmatch '\$') 'no $ (interpolation) survives sanitizing'
        Assert-True ($cmd -notmatch '";')  'no quote-then-command breakout survives sanitizing'
        # Only the 6 argument-wrapping quotes remain (3 quoted args x 2) -- the
        # two injected quotes were stripped.
        Assert-Equal 6 (@($cmd.ToCharArray() | Where-Object { $_ -eq '"' }).Count) 'only wrapping quotes remain'
        Assert-True ($cmd -match '-VMName ') 'still emits a -VMName arg'
    }
    It 'mirrors the actionability fields onto the flat event (incl reproCommand)' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'g' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 11
        Assert-Equal $r.File.repro.command $r.Event.reproCommand 'event reproCommand == file repro.command'
        Assert-Equal $r.File.sequenceName  $r.Event.sequenceName 'event sequenceName'
        Assert-Equal 'verb-registry'       $r.Event.classificationSource 'event classificationSource'
    }
    It 'emits an event that passes the cycle event schema validator' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'g' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 11
        $violations = Test-CycleEventSchema -Record $r.Event
        Assert-Equal 0 (@($violations).Count) "event must validate; got: $($violations -join '; ')"
    }
}

Describe 'New-SequenceFailureRecord classificationSource discrimination' {
    It 'reports unresolved-verb (and unknown class) when the verb has no registration' {
        $f = Reset-FailState
        $f.LastFailedAction = 'no_such_verb'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal 'unresolved-verb' $r.File.classificationSource 'unresolved verb'
        Assert-Equal 'unknown' $r.File.failureClass 'unknown class for unresolved verb'
    }
    It 'reports pattern-match when a hard-block OCR pattern fired' {
        $f = Reset-FailState
        $f.WaitForTextMatchedFailurePattern = 'kernel panic'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal 'pattern-match' $r.File.classificationSource 'pattern-match source'
        Assert-Equal 'pattern_matched_failure' $r.File.failureClass 'reclassified to pattern_matched_failure'
    }
}

Describe 'New-SequenceFailureRecord OCR causeDetail' {
    It 'surfaces the OCR tail + sought patterns in the step record context and flat on the event' {
        $f = Reset-FailState
        $f.WaitForTextOcrTail = 'yt2sqluser@host:~$'
        $f.WaitForTextPatternsSought = [string[]]@('login prompt', 'Not listed?')
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 11
        Assert-Equal 'yt2sqluser@host:~$' $r.File.context.causeDetail.ocrTail 'nested ocrTail'
        Assert-Equal 2 (@($r.File.context.causeDetail.patternsSought).Count) 'nested patternsSought count'
        Assert-Equal 'yt2sqluser@host:~$' $r.Event.causeOcrTail 'flat event ocr tail mirrors context'
        Assert-Equal 2 (@($r.Event.causePatternsSought).Count) 'flat event patterns count'
    }
    It 'defaults to empty (array, not null) when no wait cause was captured' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 11
        Assert-Equal '' $r.Event.causeOcrTail 'empty ocr tail'
        Assert-Equal 0 (@($r.Event.causePatternsSought).Count) 'empty patterns array (not null)'
        $violations = Test-CycleEventSchema -Record $r.Event
        Assert-Equal 0 (@($violations).Count) "event still validates; got: $($violations -join '; ')"
    }
    It 'omits causeDetail from a crash record context but keeps the flat event fields' {
        [void](Reset-FailState)
        $err = $null
        try { throw 'boom' } catch { $err = $_ }
        $r = New-SequenceFailureRecord -Reason crash -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 5 -CrashError $err
        Assert-True (-not $r.File.context.Contains('causeDetail')) 'crash context has no causeDetail'
        Assert-True ($r.Event.Contains('causeOcrTail')) 'crash event keeps the uniform flat field'
    }
}

Describe 'New-SequenceFailureRecord crash record backfill' {
    It 'reports reason=crash / classificationSource=crash and carries replay boundary + inner fields' {
        [void](Reset-FailState)
        $err = $null
        try { throw 'boom' } catch { $err = $_ }
        $r = New-SequenceFailureRecord -Reason crash -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 5 -CrashError $err
        Assert-Equal 'crash' $r.File.reason 'reason'
        Assert-Equal 'crash' $r.File.classificationSource 'classificationSource'
        Assert-True ($r.File.Contains('lastSucceededStepNumber')) 'crash record carries replay boundary'
        Assert-Equal 2 $r.File.lastSucceededStepNumber 'replay boundary value'
        Assert-True ($r.File.Contains('innerActionVerb')) 'crash record carries inner-cause slot'
        Assert-True ($null -ne $r.File.repro) 'crash record still has a repro block'
    }
}

Describe 'New-InfraFailureRecord (infra-stage failures)' {
    It 'builds a schema-v2 record with reason=infra / classificationSource=infra-stage' {
        $r = New-InfraFailureRecord -Stage 'New-VM' -FailureClass 'provisioning_failure' -Severity 'hard' -GuestKey 'guest.x' -VMName 'vm1' -HostType 'host.windows.hyper-v' -ErrorMessage 'define failed'
        Assert-Equal 2 $r.File.schemaVersion 'schema v2'
        Assert-Equal 'infra' $r.File.reason 'reason'
        Assert-Equal 'infra-stage' $r.File.classificationSource 'classificationSource'
        Assert-Equal 'provisioning_failure' $r.File.failureClass 'class'
        Assert-Equal 'New-VM' $r.File.actionVerb 'stage as actionVerb'
        Assert-Equal 0 $r.File.stepNumber 'no step for an infra stage'
        Assert-True (@($r.File.suggestedRecoveries) -is [array]) 'suggestedRecoveries is an array'
    }
    It 'emits an event that passes the cycle event schema validator (in-enum class)' {
        foreach ($cls in 'provisioning_failure','bootstrap_sync','plan_invalid','network_timeout') {
            $r = New-InfraFailureRecord -Stage 'GitPull' -FailureClass $cls -GuestKey '(bootstrap)' -ErrorMessage 'x'
            $v = Test-CycleEventSchema -Record $r.Event
            Assert-Equal 0 (@($v).Count) "event for $cls must validate; got: $($v -join '; ')"
        }
    }
}

# Remove the global stub so later test files see the real (or absent) command.
Remove-Item function:global:Get-SequenceAction -ErrorAction SilentlyContinue
