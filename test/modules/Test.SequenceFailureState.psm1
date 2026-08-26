<#PSScriptInfo
.VERSION 2026.08.25
.GUID 428d5583-549b-428b-9150-dfe8fe3266a4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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

# Shared, cross-module failure-state for the sequence engine.
#
# The engine's verb Handlers and the SSH/OCR handlers in
# Test.SequenceHandler must read and write the SAME failure slots. A
# scriptblock's $script: resolves to the module that DEFINED it, so a
# handler in Test.SequenceHandler writing $script:WaitForTextMatchedFailurePattern
# lands in a scope the engine (Invoke-Sequence) never reads -- the signal
# silently vanishes and an installer-crash gets mis-classified as a plain
# timeout. Anchoring the slots in one New-YurunaRegistry-backed store (a
# $global: ordered hashtable, eviction-safe across -Force re-imports) lets
# every module share one object: each does `$script:Fail = Get-SequenceFailureState`
# once and then reads/writes $script:Fail.<slot>. This is also the
# prerequisite that lets the retry / recoverFromSnapshot verbs migrate out
# of the engine without losing their failure-state coupling.

Import-Module (Join-Path $PSScriptRoot 'Test.Registry.psm1') -Global -Force

function Initialize-SequenceFailureStateStore {
    # Private: seed every slot on $Store with its default, in place (callers
    # cache the store by reference, so it must never rebind). Run once, only
    # when the store is first created -- the engine resets the slots itself
    # at the top of each sequence run via member access on the live store.
    param([Parameter(Mandatory)]$Store)
    $Store['LastFailureLabel']       = $null
    $Store['LastFailureDescription'] = $null
    $Store['LastFailedAction']       = $null
    $Store['LastFailedStepNumber']   = 0
    # Inner-verb slots: a retry Handler captures the deepest inner verb's
    # classification here before the outer per-step path overwrites
    # LastFailedAction with 'retry', so the failure record can surface both
    # the outer 'retry_exhausted' class and the inner cause a remediator
    # needs to pick a recovery. [string[]] empty array, never $null, so the
    # NDJSON field always renders as a JSON array.
    $Store['LastInnerFailedAction']        = $null
    $Store['LastInnerFailureClass']        = $null
    $Store['LastInnerSeverity']            = $null
    $Store['LastInnerSuggestedRecoveries'] = [string[]]@()
    # 0 = "no step succeeded": a fresh-cycle failure on step 1 must not carry
    # a leftover resume boundary from a prior sequence's run.
    $Store['LastSucceededStepNumber']      = 0
    # Cross-function anti-pattern signal; reset per-step inside Wait-ForText
    # and sshWaitReady, cleared here too so a sequence starts clean.
    $Store['WaitForTextMatchedFailurePattern'] = $null
    # Runtime cause signal captured at the wait/OCR failure site: the freshest
    # full-screen OCR text (bounded tail) and the patterns the wait was seeking.
    # Lets a consumer see WHAT was on screen vs WHAT was sought, not just the
    # verb-static failureClass. [string[]] empty (never $null) so the NDJSON
    # field always renders as a JSON array, same guard as the inner-recovery slot.
    $Store['WaitForTextOcrTail']        = $null
    $Store['WaitForTextPatternsSought'] = [string[]]@()
    # Populated when a freshMatch wait times out on text the engines DID read
    # but that had scrolled past the tail window. Without it the record shows a
    # sought pattern, an OCR tail that appears not to contain it, and no way to
    # tell "never printed" from "printed, then pushed out of the window" -- two
    # failures with different owners and different fixes.
    $Store['WaitForTextFreshWindowNearMiss'] = [string[]]@()
    # Populated when the console filled with one repeating log line while the
    # wait was seeking its pattern. That case is NOT the same failure as a
    # pattern that never printed, and the byte-hash freeze detector cannot see
    # it: a scrolling flood changes every frame, so the feed is live and only the
    # CONTENT is useless. Left as one class they are indistinguishable in the
    # record, and the flood is the one whose owner is the guest rather than the
    # capture path.
    $Store['WaitForTextConsoleFlood'] = $null
    # Longest run, in seconds, that the console CONTENT stayed unchanged during
    # the wait. Separates the two screens the flood detail alone cannot: one
    # scrolling a repeating line, and one frozen on text that scrolled past
    # already -- the second is a guest parked on something, and the wait it
    # failed was never going to end on its own.
    $Store['WaitForTextConsoleStaticSeconds'] = 0
    # Set by the sequence-start / per-step pause gate when an operator hold is
    # released: @{ releasedAtUtc; heldSeconds; label; pauseScope }. The gate holds
    # the runner while the guest keeps running, so a hold is part of the cause of
    # whatever the next step finds on screen, and a record that omits it sends the
    # reader looking for a guest fault that is not there.
    $Store['LastPauseRelease'] = $null
    # Set by the ssh verbs when host-side discovery never produced an address
    # and the bare VM name was dialed as the last route left. The verb registry
    # classifies those verbs by their COMMON failure -- a guest command that
    # exited non-zero -- but a step that never reached the guest is a different
    # fault with a different owner, so the class is corrected from this signal
    # rather than from the registry default.
    $Store['StepGuestAddressUnresolved'] = $null
    # Set by the ssh verbs when the session died mid-command instead of the
    # guest reporting a status. The verb registry classifies those verbs by
    # their COMMON failure -- a guest command that exited non-zero -- and a
    # dropped transport is not that: nothing is known about the command, which
    # may have completed, and the fault is on the path rather than in the
    # script. The class is corrected from this signal so the record names the
    # right fault and reaches the recovery that suits it.
    $Store['StepGuestTransportLost'] = $null
    # Set by the ssh verbs when a DETACHED run could not be accounted for: the
    # supervisor was reached but the payload it was watching left no exit
    # status. Distinct from a dropped transport, which says only that the host
    # stopped watching -- here the work itself is gone, so re-attaching cannot
    # recover it and the honest report is that the step's outcome is unknown.
    $Store['StepGuestRunLost'] = $null
    # Set by the ssh verbs when the guest ran the fetch wrapper but no source
    # served the script. The verb registry classifies these verbs by their COMMON
    # failure -- a guest command that exited non-zero -- and this is the opposite:
    # no command ran at all. The wrapper says so in its own output; without this
    # signal that statement is discarded and an operator is sent to debug a script
    # that never executed.
    $Store['StepGuestPayloadUnavailable'] = $null
}

$script:SeqFailReg = New-YurunaRegistry -Name 'SequenceFailureState'

# Seed the slots once, on first creation only. A -Force re-import mid-cycle
# must NOT wipe live failure state, so seed defaults only when the global
# store is still empty (New-YurunaRegistry reuses the existing store across
# re-imports, so a re-import lands here with the slots already populated).
if ($script:SeqFailReg.Store[0].Count -eq 0) { Initialize-SequenceFailureStateStore $script:SeqFailReg.Store[0] }

function Get-SequenceFailureState {
    <#
    .SYNOPSIS
        Return the live, cross-module sequence failure-state store.
    .DESCRIPTION
        The returned OrderedDictionary is the one $global:-anchored object
        every sequence-engine module binds to. Read or write a slot with
        member access ($state.LastFailureLabel, $state.LastFailedStepNumber,
        $state.WaitForTextMatchedFailurePattern, ...). The reference is
        stable for the process lifetime, so callers cache it once as
        $script:Fail at module load.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    return $script:SeqFailReg.Store[0]
}

function New-SequenceFailureRecord {
    <#
    .SYNOPSIS
        Build the schema-v2 failure record from the live $script:Fail slots.
    .DESCRIPTION
        Single source for both the on-disk last_failure.json ordered dict
        (.File) and the matching step_failure NDJSON record (.Event), so the
        file and the event stream can never drift in classification or fields.
        Reads the shared sequence failure-state store itself; the engine only
        supplies per-cycle identity. -Reason 'crash' folds in the crash
        origin/stack and the 'engine crash: ...' fallback label. The contract
        is documented in docs/failure-schema.md.
    .OUTPUTS
        Hashtable with two keys: File ([ordered] -> ConvertTo-Json by the
        caller) and Event ([hashtable] for Send-CycleEventSafely).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure builder: constructs and returns the failure record; changes no system state.')]
    param(
        [Parameter(Mandatory)][ValidateSet('step', 'crash')][string]$Reason,
        [Parameter(Mandatory)][string]$VMName,
        [AllowEmptyString()][string]$GuestKey,
        [AllowEmptyString()][string]$HostType,
        [AllowEmptyString()][string]$SequencePath,
        [Parameter(Mandatory)][string]$LogDir,
        [int]$TotalSteps = 0,
        [System.Management.Automation.ErrorRecord]$CrashError
    )
    $fail = Get-SequenceFailureState

    # Resolve the failing verb's registry entry into failureClass / severity /
    # suggestedRecoveries. Two-step [string[]] guard so an empty
    # SuggestedRecoveries never collapses to $null via the if-pipeline flatten
    # (the typed-array-cast-if-empty trap); the NDJSON field always renders as
    # a JSON array.
    $actionName = [string]$fail.LastFailedAction
    if ($Reason -eq 'crash' -and -not $actionName) { $actionName = 'script_error' }
    $verbEntry    = if ($fail.LastFailedAction) { Get-SequenceAction -Name $fail.LastFailedAction } else { $null }
    $failureClass = if ($verbEntry) { [string]$verbEntry.FailureClass } else { 'unknown' }
    $severity     = if ($verbEntry) { [string]$verbEntry.Severity }     else { 'unknown' }
    if ($Reason -eq 'crash') {
        [string[]]$suggested = @('Inspect the crash origin/stack under .context; cycle continues unless StopOnFailure is set.')
    } else {
        [string[]]$suggested = @()
    }
    if ($verbEntry -and $null -ne $verbEntry.SuggestedRecoveries) {
        [string[]]$suggested = @($verbEntry.SuggestedRecoveries)
    }

    $matchedFailPattern = $fail.WaitForTextMatchedFailurePattern
    # Runtime cause signal (empty-array guard mirrors innerSuggestedRecoveries so
    # patternsSought never collapses to $null via the if-pipeline flatten).
    $ocrTail = if ($fail.WaitForTextOcrTail) { [string]$fail.WaitForTextOcrTail } else { '' }
    [string[]]$patternsSought = @($fail.WaitForTextPatternsSought)
    [string[]]$freshWindowNearMiss = @($fail.WaitForTextFreshWindowNearMiss)
    $consoleFlood = if ($fail.WaitForTextConsoleFlood) { [string]$fail.WaitForTextConsoleFlood } else { '' }
    $consoleStaticSeconds = if ($fail.WaitForTextConsoleStaticSeconds) { [int]$fail.WaitForTextConsoleStaticSeconds } else { 0 }
    # 0 / '' rather than $null when there was no hold, matching consoleFlood: the
    # fields are always present, so a consumer never has to tell "not paused" from
    # "this record predates the gate reporting it".
    $pauseHeldSeconds  = 0
    $pauseReleasedAtUtc = ''
    if ($fail.LastPauseRelease) {
        $pauseHeldSeconds   = [int]$fail.LastPauseRelease.heldSeconds
        $pauseReleasedAtUtc = [string]$fail.LastPauseRelease.releasedAtUtc
    }
    $stepNumber = if ($fail.LastFailedStepNumber) { [int]$fail.LastFailedStepNumber } else { 0 }
    if ($Reason -eq 'crash') {
        $label = if ($fail.LastFailureLabel) { [string]$fail.LastFailureLabel } else { "engine crash: $($CrashError.Exception.Message)" }
        $desc  = if ($fail.LastFailureDescription) { [string]$fail.LastFailureDescription } else { '(crash before step completion)' }
    } else {
        # Wait-ForText short-circuit on a hard-block pattern reclassifies the step.
        # The recoveries move with the class: the verb registry's hint describes
        # its DEFAULT failure (a completion marker that never arrived, which is
        # worth retrying), and a matched failure pattern is the opposite case --
        # the guest script announced its own failure, so a retry only re-runs a
        # command already known to fail. Leaving the registry's retry hint in
        # place here would advertise a retry for exactly the failure that cannot
        # benefit from one.
        if ($matchedFailPattern) {
            $failureClass = 'pattern_matched_failure'
            [string[]]$suggested = @('pause_and_inspect')
        }
        # A wait that ended with the console overwriting itself did not fail the
        # way ocr_timeout describes. ocr_timeout's recoveries assume the pattern
        # never printed -- so they restart the guest and try again, which reruns
        # the flood. The owner here is whatever is filling the console, and the
        # answer is to read it, so the class and the recovery both change. Ranked
        # below a matched failure pattern: that is the guest announcing its own
        # failure in words, which outranks an inference drawn from screen shape.
        elseif ($fail.WaitForTextConsoleFlood) {
            $failureClass = 'console_flooded'
            [string[]]$suggested = @('pause_and_inspect')
        }
        # A step that never resolved an address never reached the guest, so the
        # registry's script_error is describing a script that did not run. The
        # correction is ordered after the pattern match on purpose: a matched
        # failure pattern is evidence the guest DID run and announced its own
        # failure, which outranks an address signal left over from the attempt.
        elseif ($fail.StepGuestAddressUnresolved) {
            # Discovery lateness, not a dead path: the address source publishes late
            # or its cache aged out, and the same lookup usually answers seconds
            # later. Retrying is what clears it, and the step never reached the guest
            # so replaying it puts nothing in doubt -- the same reasoning that keeps
            # this class on the warm-resume allow-list and routes it to
            # retry_with_backoff in remediation.
            $failureClass = 'ip_not_discovered'
            [string[]]$suggested = @('retry_with_backoff')
        }
        # The session dropped while the command was running, so the registry's
        # script_error is describing a script whose outcome nobody observed.
        # network_timeout is both the honest name and the one an in-place warm
        # resume acts on -- re-running the sequence from its last-good step on
        # the same live guest is exactly the right answer to a path that broke
        # under it, and is unreachable while the record says script_error.
        # Ordered after the address check on purpose: an unresolved address is
        # the more specific fault, and the two cannot both be true anyway --
        # the ssh driver returns before dialing when it has no address.
        elseif ($fail.StepGuestTransportLost) {
            $failureClass = 'network_timeout'
            [string[]]$suggested = @('reconnect','retry_with_backoff')
        }
        # Ordered after the transport check: a dropped link is the recoverable
        # case and the common one, and a run is only judged lost after a
        # supervisor was actually reached and could not account for it. Not
        # network_timeout -- reconnecting is precisely what will not help -- and
        # not script_error either, because no script reported anything.
        elseif ($fail.StepGuestRunLost) {
            $failureClass = 'instrumentation_failure'
            [string[]]$suggested = @('restart_from_snapshot','pause_and_inspect')
        }
        # Ordered last of the guest-side corrections, and that ordering is what
        # makes it safe: this signal is read out of output the guest sent, so
        # reaching it means the session held and the wrapper spoke. The three
        # above describe the ways that does NOT happen -- no address, a dropped
        # link, a run nobody could account for -- and each is the more specific
        # fault where both could look true. What is left is a guest that ran the
        # wrapper and was served nothing, so no script executed and the registry's
        # script_error names a thing that does not exist.
        elseif ($fail.StepGuestPayloadUnavailable) {
            $failureClass = 'payload_unavailable'
            [string[]]$suggested = @('retry_with_backoff')
        }
        $label = $fail.LastFailureLabel
        $desc  = $fail.LastFailureDescription
    }

    # --- REGION: Actionability enrichment (schema v2, additive)
    # sequenceName: first-class failing-sequence identity. The record otherwise
    # carried only the path (nested under context); a remediator routing or a
    # repro builder needs the bare name.
    $sequenceName = if ($SequencePath) { [System.IO.Path]::GetFileNameWithoutExtension($SequencePath) } else { '' }

    # classificationSource: lets a consumer tell a genuinely-unknown cause from
    # one that is 'unknown' only because the failing verb has no registry entry,
    # or one synthesized from a crash / hard-block OCR pattern. Drives a
    # fix-the-registration vs. escalate decision instead of blind retry.
    $classificationSource =
        if ($Reason -eq 'crash')     { 'crash' }
        elseif ($matchedFailPattern) { 'pattern-match' }
        elseif ($verbEntry)          { 'verb-registry' }
        else                         { 'unresolved-verb' }

    # repro: a copy-paste command that re-runs the failing sequence (and its
    # baseline chain) to reproduce the failure deterministically. The command
    # deliberately OMITS -StartStep: stepNumber is file-local (1-based within
    # this sequence file), but Debug-TestSequence's -StartStep is chain-GLOBAL, so a
    # naive -StartStep would mis-target a leaf that still has an unbuilt
    # baseline. The file-local failing step is exposed as resumeFromStep
    # (advisory; valid as -StartStep on the warm / no-baseline path). Contract
    # in docs/failure-schema.md.
    # Strip characters that would break out of the double-quoted repro arguments
    # ('"', backtick, '$') or split the command line (CR/LF). The repro is
    # surfaced for copy-paste and for an autonomous remediator to run, so a
    # hostile or malformed VM/guest name must not become an execution hazard.
    # Identifiers are normally quote-free, so this only ever changes pathological
    # names; the data fields (sequenceName, vmName, guestKey) keep the real value.
    $shellSafe = { param([string]$v) ($v -replace '[`"$\r\n]', '') }
    $reproCommand = ''
    if ($sequenceName) {
        $reproParts = @('pwsh test/Debug-TestSequence.ps1', "-SequenceName `"$(& $shellSafe $sequenceName)`"")
        if ($GuestKey) { $reproParts += "-GuestKey `"$(& $shellSafe $GuestKey)`"" }
        if ($VMName)   { $reproParts += "-VMName `"$(& $shellSafe $VMName)`"" }
        $reproParts += '-logLevel Debug'
        $reproCommand = $reproParts -join ' '
    }
    $repro = [ordered]@{
        command        = $reproCommand
        runnerScript   = 'test/Debug-TestSequence.ps1'
        entrypoint     = 'Debug-TestSequence'
        sequenceName   = $sequenceName
        resumeFromStep = $stepNumber
    }

    $tsFile        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    $tsEvent       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $failScreenName = "failure_screenshot_${VMName}.png"
    $failOcrName    = "failure_ocr_${VMName}.txt"

    if ($Reason -eq 'crash') {
        $file = [ordered]@{
            schemaVersion = 2
            reason        = $Reason
            stepNumber    = $stepNumber
            totalSteps    = [int]$TotalSteps
            action        = $label
            description   = $desc
            vmName        = $VMName
            guestKey      = $GuestKey
            timestamp     = $tsFile
            failureClass         = $failureClass
            severity             = $severity
            suggestedRecoveries  = $suggested
            actionVerb           = $actionName
            classificationSource = $classificationSource
            sequenceName         = $sequenceName
            repro                = $repro
            # Replay boundary + inner cause also on crash records: a crash after
            # step N began still has a safe-to-replay-past boundary and, if it
            # bubbled through an exhausted retry, an inner cause worth routing on.
            lastSucceededStepNumber = [int]$fail.LastSucceededStepNumber
            innerActionVerb          = $fail.LastInnerFailedAction
            innerFailureClass        = $fail.LastInnerFailureClass
            innerSeverity            = $fail.LastInnerSeverity
            innerSuggestedRecoveries = @($fail.LastInnerSuggestedRecoveries)
            context             = [ordered]@{
                hostType              = $HostType
                matchedFailurePattern = $matchedFailPattern
                sequencePath          = $SequencePath
                crash = [ordered]@{
                    error  = "$CrashError"
                    origin = $CrashError.InvocationInfo ? $CrashError.InvocationInfo.PositionMessage : $null
                    stack  = $CrashError.ScriptStackTrace
                }
            }
        }
    } else {
        $file = [ordered]@{
            schemaVersion = 2
            reason        = $Reason
            stepNumber    = $stepNumber
            totalSteps    = [int]$TotalSteps
            action        = $label
            description   = $desc
            vmName        = $VMName
            guestKey      = $GuestKey
            timestamp     = $tsFile
            failureClass         = $failureClass
            severity             = $severity
            suggestedRecoveries  = $suggested
            actionVerb           = $actionName
            classificationSource = $classificationSource
            sequenceName         = $sequenceName
            repro                = $repro
            lastSucceededStepNumber = [int]$fail.LastSucceededStepNumber
            innerActionVerb            = $fail.LastInnerFailedAction
            innerFailureClass          = $fail.LastInnerFailureClass
            innerSeverity              = $fail.LastInnerSeverity
            innerSuggestedRecoveries   = @($fail.LastInnerSuggestedRecoveries)
            context             = [ordered]@{
                hostType              = $HostType
                matchedFailurePattern = $matchedFailPattern
                sequencePath          = $SequencePath
                cycleFolder           = $LogDir
                failureScreenshotPath = $failScreenName
                failureOcrPath        = $failOcrName
                # What was on screen vs what was sought at the wait/OCR failure
                # site -- the runtime cause behind a verb-static failureClass.
                causeDetail           = [ordered]@{
                    ocrTail            = $ocrTail
                    patternsSought     = $patternsSought
                    freshWindowNearMiss = $freshWindowNearMiss
                    # Empty string rather than $null when absent, so the field is
                    # always present and a consumer never has to tell "not
                    # flooded" from "this record predates the check".
                    consoleFlood       = $consoleFlood
                    consoleStaticSeconds = $consoleStaticSeconds
                    # The operator hold that ended before this step ran, if any.
                    # A guest keeps running through a hold, so a prompt printed
                    # during one is gone by the time the run resumes -- which
                    # reads on screen exactly like a prompt that never printed.
                    pauseBeforeStepSeconds = $pauseHeldSeconds
                    pauseReleasedAtUtc     = $pauseReleasedAtUtc
                }
            }
        }
    }

    # Send-CycleEventSafely binds -EventRecord as [hashtable]; build a plain
    # hashtable (same shape both reasons; crash adds crashError).
    $eventRecord = @{
        timestamp               = $tsEvent
        event                   = 'step_failure'
        reason                  = $Reason
        stepNumber              = $stepNumber
        totalSteps              = [int]$TotalSteps
        actionVerb              = $actionName
        ok                      = $false
        durationMs              = $null
        failureClass            = $failureClass
        severity                = $severity
        classificationSource    = $classificationSource
        suggestedRecoveries     = $suggested
        lastSucceededStepNumber = [int]$fail.LastSucceededStepNumber
        innerActionVerb            = $fail.LastInnerFailedAction
        innerFailureClass          = $fail.LastInnerFailureClass
        innerSeverity              = $fail.LastInnerSeverity
        innerSuggestedRecoveries   = @($fail.LastInnerSuggestedRecoveries)
        vmName                  = $VMName
        guestKey                = $GuestKey
        hostType                = $HostType
        action                  = $label
        description             = $desc
        sequenceName            = $sequenceName
        sequencePath            = $SequencePath
        matchedFailurePattern   = $matchedFailPattern
        causeOcrTail            = $ocrTail
        causePatternsSought     = $patternsSought
        reproCommand            = $reproCommand
        failureScreenshotPath   = $failScreenName
        failureOcrPath          = $failOcrName
    }
    if ($Reason -eq 'crash') { $eventRecord['crashError'] = "$CrashError" }

    return @{ File = $file; Event = $eventRecord }
}

function New-InfraFailureRecord {
    <#
    .SYNOPSIS
        Build a schema-v2 failure record for a host-side infra stage (GitPull,
        ProjectClone, Resolve-CyclePlan, New-VM, Start-VM, ...) that has no
        sequence/$script:Fail slot state to read.
    .DESCRIPTION
        Infra stages fail before (or outside) the sequence engine, so they never
        populate the shared failure-state slots New-SequenceFailureRecord reads.
        This sibling builds the same File + Event shape from scalars so an infra
        failure lands on disk as last_failure.json and on the event stream as a
        step_failure the remediation dispatcher can route on. reason='infra' and
        classificationSource='infra-stage' distinguish it; failureClass MUST be a
        canonical value (see Test.FailureTaxonomy). The contract is documented in
        docs/failure-schema.md.
    .OUTPUTS
        Hashtable with File ([ordered]) and Event ([hashtable]) keys.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure builder: constructs and returns the infra failure record; changes no system state.')]
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$FailureClass,
        [string]$Severity = 'hard',
        [AllowEmptyString()][string]$VMName = '',
        [AllowEmptyString()][string]$GuestKey = '',
        [AllowEmptyString()][string]$HostType = '',
        [AllowEmptyString()][string]$ErrorMessage = ''
    )
    # Two-step [string[]] guard so the empty recoveries list never collapses to
    # $null (the typed-array-cast-if-empty trap); the NDJSON field stays an array.
    [string[]]$suggested = @()
    $tsFile  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    $tsEvent = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $file = [ordered]@{
        schemaVersion        = 2
        reason               = 'infra'
        stepNumber           = 0
        totalSteps           = 0
        action               = $Stage
        description          = $ErrorMessage
        vmName               = $VMName
        guestKey             = $GuestKey
        timestamp            = $tsFile
        failureClass         = $FailureClass
        severity             = $Severity
        suggestedRecoveries  = $suggested
        actionVerb           = $Stage
        classificationSource = 'infra-stage'
        sequenceName         = ''
        context              = [ordered]@{
            hostType = $HostType
            stage    = $Stage
        }
    }
    $eventRecord = @{
        timestamp            = $tsEvent
        event                = 'step_failure'
        reason               = 'infra'
        stepNumber           = 0
        totalSteps           = 0
        actionVerb           = $Stage
        ok                   = $false
        durationMs           = $null
        failureClass         = $FailureClass
        severity             = $Severity
        classificationSource = 'infra-stage'
        suggestedRecoveries  = $suggested
        vmName               = $VMName
        guestKey             = $GuestKey
        hostType             = $HostType
        action               = $Stage
        description          = $ErrorMessage
        sequenceName         = ''
    }
    return @{ File = $file; Event = $eventRecord }
}

Export-ModuleMember -Function Get-SequenceFailureState, New-SequenceFailureRecord, New-InfraFailureRecord
