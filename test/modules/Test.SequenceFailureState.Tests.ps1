<#PSScriptInfo
.VERSION 2026.07.14
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
        Assert-Equal -Expected 'workload.guest.ubuntu.server.24.k8s.text-to-sql.test' -Actual $r.File.sequenceName -Because 'sequenceName from path basename'
        Assert-Equal -Expected 'step' -Actual $r.File.reason -Because 'reason'
        Assert-Equal -Expected 'verb-registry' -Actual $r.File.classificationSource -Because 'resolved verb -> verb-registry'
        Assert-Equal -Expected 'ocr_timeout' -Actual $r.File.failureClass -Because 'class from stubbed registry'
        Assert-True ($null -ne $r.File.repro) 'repro block present'
        Assert-Equal -Expected 3 -Actual $r.File.repro.resumeFromStep -Because 'resumeFromStep = file-local failing step'
        Assert-Equal -Expected 'Test-Sequence' -Actual $r.File.repro.entrypoint -Because 'entrypoint'
    }
    It 'builds a repro command that omits -StartStep (chain-global vs file-local trap)' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'guest.ubuntu.server.24' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 11
        Assert-Match -Pattern 'Test-Sequence\.ps1' -Actual $r.File.repro.command -Because 'command runs Test-Sequence'
        Assert-Match -Pattern '-SequenceName "workload\.guest\.ubuntu\.server\.24\.k8s\.text-to-sql\.test"' -Actual $r.File.repro.command -Because 'names the failing sequence'
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
        Assert-Equal -Expected 6 -Actual (@($cmd.ToCharArray() | Where-Object { $_ -eq '"' }).Count) -Because 'only wrapping quotes remain'
        Assert-True ($cmd -match '-VMName ') 'still emits a -VMName arg'
    }
    It 'mirrors the actionability fields onto the flat event (incl reproCommand)' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'g' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 11
        Assert-Equal -Expected $r.File.repro.command -Actual $r.Event.reproCommand -Because 'event reproCommand == file repro.command'
        Assert-Equal -Expected $r.File.sequenceName  -Actual $r.Event.sequenceName -Because 'event sequenceName'
        Assert-Equal -Expected 'verb-registry'       -Actual $r.Event.classificationSource -Because 'event classificationSource'
    }
    It 'emits an event that passes the cycle event schema validator' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'g' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 11
        $violations = Test-CycleEventSchema -Record $r.Event
        Assert-Equal -Expected 0 -Actual (@($violations).Count) -Because "event must validate; got: $($violations -join '; ')"
    }
}

Describe 'New-SequenceFailureRecord classificationSource discrimination' {
    It 'reports unresolved-verb (and unknown class) when the verb has no registration' {
        $f = Reset-FailState
        $f.LastFailedAction = 'no_such_verb'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'unresolved-verb' -Actual $r.File.classificationSource -Because 'unresolved verb'
        Assert-Equal -Expected 'unknown' -Actual $r.File.failureClass -Because 'unknown class for unresolved verb'
    }
    It 'reports pattern-match when a hard-block OCR pattern fired' {
        $f = Reset-FailState
        $f.WaitForTextMatchedFailurePattern = 'kernel panic'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'pattern-match' -Actual $r.File.classificationSource -Because 'pattern-match source'
        Assert-Equal -Expected 'pattern_matched_failure' -Actual $r.File.failureClass -Because 'reclassified to pattern_matched_failure'
    }
}

Describe 'New-SequenceFailureRecord OCR causeDetail' {
    It 'surfaces the OCR tail + sought patterns in the step record context and flat on the event' {
        $f = Reset-FailState
        $f.WaitForTextOcrTail = 'yt2sqluser@host:~$'
        $f.WaitForTextPatternsSought = [string[]]@('login prompt', 'Not listed?')
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 11
        Assert-Equal -Expected 'yt2sqluser@host:~$' -Actual $r.File.context.causeDetail.ocrTail -Because 'nested ocrTail'
        Assert-Equal -Expected 2 -Actual (@($r.File.context.causeDetail.patternsSought).Count) -Because 'nested patternsSought count'
        Assert-Equal -Expected 'yt2sqluser@host:~$' -Actual $r.Event.causeOcrTail -Because 'flat event ocr tail mirrors context'
        Assert-Equal -Expected 2 -Actual (@($r.Event.causePatternsSought).Count) -Because 'flat event patterns count'
    }
    It 'defaults to empty (array, not null) when no wait cause was captured' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $seqPath -LogDir 'd' -TotalSteps 11
        Assert-Equal -Expected '' -Actual $r.Event.causeOcrTail -Because 'empty ocr tail'
        Assert-Equal -Expected 0 -Actual (@($r.Event.causePatternsSought).Count) -Because 'empty patterns array (not null)'
        $violations = Test-CycleEventSchema -Record $r.Event
        Assert-Equal -Expected 0 -Actual (@($violations).Count) -Because "event still validates; got: $($violations -join '; ')"
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
}

# Remove the global stub so later test files see the real (or absent) command.
Remove-Item function:global:Get-SequenceAction -ErrorAction SilentlyContinue
