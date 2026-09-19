<#PSScriptInfo
.VERSION 2026.09.18
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

# Shared, cross-module failure-state for the sequence engine. See
# ../../docs/failure-schema.md#failure-record-schema for why this is one
# registry-backed store rather than per-module $script: variables. -- Test.SequenceFailureState.psm1

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
    # When the failing step began. The failure record judges the per-VM screen
    # artifacts at the log root against it: those files are sticky and only the
    # verbs that read a screen rewrite them, so anything written before the step
    # started belongs to an earlier one and must not be claimed as this
    # failure's evidence. $null means no boundary is known, and the record then
    # claims the artifacts as it always did rather than guessing.
    $Store['LastFailedStepStartedUtc'] = $null
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
    # Populated at any wait that timed out having read some text: per engine and
    # per sought pattern, the line on the final frame that came closest and how
    # close. The near-miss slot above is empty for three unrelated screens, so on
    # its own it cannot say whether anything resembling the pattern was there;
    # this can, and on a frame shorter than the tail window -- where the window
    # is incapable of hiding anything -- it is the only screen evidence in the
    # record. Three states: entries, an empty array from a scan that compared the
    # frame and found nothing like the pattern, and $null from no scan at all --
    # a wait that ends on a failure pattern returns the moment it matches, and a
    # failure outside a wait has no frame. Only the first two say anything about
    # the screen, so the third must not arrive wearing the second's shape.
    $Store['WaitForTextClosestOnScreen'] = $null
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
    # Whether the wait that failed actually evaluated the two slots above. A
    # tail-confined match reads the same frames but runs neither tracker, so it
    # leaves them at these initializers -- which are also what a measured, moving,
    # non-repeating console produces. Defaults to $true so a failure with no wait
    # behind it keeps the shape it has always had; only a wait that declined to
    # measure clears it.
    $Store['WaitForTextConsoleSignalsMeasured'] = $true
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'global:__YurunaCycleIdentity / __YurunaCycleFolder are the cross-module cycle handles set by Start-LogFile; read here to stamp the cycle identity on the failure record.')]
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
    # Three states, so neither guard above fits: @($null) is a ONE-element array
    # whose element casts to '', which would publish a scan that never ran as one
    # that found a blank line, and an if-EXPRESSION cannot carry the other two
    # (its pipeline flattens an empty array to $null and a one-line result to a
    # bare string, collapsing exactly the distinction being drawn). Assign the
    # absent state first, then overwrite only when there is a reading.
    $closestOnScreen = $null
    if ($null -ne $fail.WaitForTextClosestOnScreen) {
        [string[]]$closestOnScreen = @($fail.WaitForTextClosestOnScreen)
    }
    # Both console fields describe a screen something looked at. When the wait
    # confined its match to the console tail, nothing did: the flood check and the
    # content-static tracker never ran, so 0 / '' are initializers rather than
    # readings -- and they are exactly the values a measured healthy console
    # produces. $null keeps both keys present while saying the wait did not look,
    # so no consumer can read "the console was moving" out of a measurement that
    # never happened. A store with no flag at all is treated as measured, so a
    # record built from one keeps the shape it already had.
    $consoleMeasured = ($null -eq $fail.WaitForTextConsoleSignalsMeasured) -or [bool]$fail.WaitForTextConsoleSignalsMeasured
    $consoleFlood = if (-not $consoleMeasured) { $null } elseif ($fail.WaitForTextConsoleFlood) { [string]$fail.WaitForTextConsoleFlood } else { '' }
    $consoleStaticSeconds = if (-not $consoleMeasured) { $null } elseif ($fail.WaitForTextConsoleStaticSeconds) { [int]$fail.WaitForTextConsoleStaticSeconds } else { 0 }
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
    # Cycle-dir-relative, naming where the artifacts actually land. The flat
    # root-level form these carried was keyed only by VM name, so every cycle
    # that failed on the same guest rewrote the same two files: a pointer read
    # later could resolve to a DIFFERENT cycle's screenshot and give no sign
    # that it had, which is worse than a path that resolves to nothing.
    #
    # Claimed only when the source artifact was written after the failing step
    # began. Both sources are sticky per-VM files at the log root that only the
    # verbs which read a screen ever rewrite, so a failure in a verb that reads
    # none inherits whatever an earlier step left behind -- and a pointer to
    # that reads as this failure's screen, sending the reader after a fault
    # that belongs to a different step. The boundary is the step's START, not
    # the failure instant: every artifact for a failure is written before the
    # record describing it, so the instant would reject all of them. The
    # 2-second slack absorbs filesystem timestamp granularity (FAT/exFAT round
    # mtime to 2s), the only skew that can under-report a genuinely fresh
    # write; a stale artifact is a whole step older at minimum, so the slack
    # cannot reach one. With no step boundary recorded, both are claimed as
    # before: nothing is known about their age, and an absent judgment is not
    # evidence of staleness.
    $failScreenName = "$VMName/failure_screenshot.png"
    $failOcrName    = "$VMName/failure_ocr.txt"
    $staleEvidence  = [System.Collections.Generic.List[string]]::new()
    $stepStartedUtc = $fail.LastFailedStepStartedUtc -as [DateTime]
    if ($stepStartedUtc) {
        $evidenceCutoffUtc = $stepStartedUtc.AddSeconds(-2)
        foreach ($artifact in @(
                @{ Kind = 'screen'; Source = "failure_screenshot_${VMName}.png"; Name = $failScreenName },
                @{ Kind = 'ocr';    Source = "failure_ocr_${VMName}.txt";        Name = $failOcrName })) {
            $item = Get-Item -LiteralPath (Join-Path $LogDir $artifact.Source) -ErrorAction SilentlyContinue
            if ($item -and $item.LastWriteTimeUtc -ge $evidenceCutoffUtc) { continue }
            if ($item) {
                $ageSeconds = [int][math]::Round(($stepStartedUtc - $item.LastWriteTimeUtc).TotalSeconds)
                $staleEvidence.Add("$($artifact.Name): last written ${ageSeconds}s before the failing step began -- it holds an earlier step's screen, not this failure's")
            }
            if ($artifact.Kind -eq 'screen') { $failScreenName = $null } else { $failOcrName = $null }
        }
    }

    # The cycle's stable identity, the same string the NDJSON stream stamps on
    # every record, so a consumer holding this file can join it to the events
    # and locate the folder on disk. The shared log ROOT was neither of those:
    # it is identical for every cycle on the host, so it identified nothing and
    # pointed at a directory containing all of them.
    $cycleIdentity = if ($global:__YurunaCycleIdentity) {
        [string]$global:__YurunaCycleIdentity
    } elseif ($global:__YurunaCycleFolder -and (Get-Command Get-CycleFolderIdentity -ErrorAction SilentlyContinue)) {
        Get-CycleFolderIdentity -Path $global:__YurunaCycleFolder
    } else {
        $LogDir
    }

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
                cycleFolder           = $cycleIdentity
                failureScreenshotPath = $failScreenName
                failureOcrPath        = $failOcrName
                # Names an artifact dropped from the two pointers above, with
                # its age: "no screen evidence exists" and "evidence exists but
                # shows an earlier step" send a reader to different places, and
                # a silent omission cannot tell them apart.
                staleEvidence         = [string[]]$staleEvidence
                # What was on screen vs what was sought at the wait/OCR failure
                # site -- the runtime cause behind a verb-static failureClass.
                causeDetail           = [ordered]@{
                    ocrTail            = $ocrTail
                    patternsSought     = $patternsSought
                    freshWindowNearMiss = $freshWindowNearMiss
                    # Read with freshWindowNearMiss, never instead of it. An empty
                    # near-miss list means one of three different screens, and
                    # this names what the closest line on the frame actually was
                    # and how close, so the empty one is never mistaken for a
                    # finding that nothing resembled the pattern. $null when no
                    # scan ran at all, on the same reasoning as consoleFlood
                    # below: an empty list is a reading, and absence is not.
                    closestOnScreen    = $closestOnScreen
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
        staleEvidence           = [string[]]$staleEvidence
    }
    if ($Reason -eq 'crash') { $eventRecord['crashError'] = "$CrashError" }

    # An artifact that failed the freshness check is dropped from both the file
    # and the event rather than carried as a name the reader has to distrust:
    # the pointer is followed, not audited, and one resolving to an earlier
    # step's screen costs more than no pointer at all. staleEvidence keeps it
    # findable for the reader who wants it anyway.
    if (-not $failScreenName) {
        $file.context.Remove('failureScreenshotPath')
        $eventRecord.Remove('failureScreenshotPath')
    }
    if (-not $failOcrName) {
        $file.context.Remove('failureOcrPath')
        $eventRecord.Remove('failureOcrPath')
    }

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
        [AllowEmptyString()][string]$ErrorMessage = '',
        # The host's own resource position at the moment the stage failed, when
        # the driver could measure it. Left unbound rather than zeroed when it
        # could not: a zeroed reading is indistinguishable from a measured one,
        # and the difference is the whole value of the field.
        [AllowNull()][hashtable]$HostMemory
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
    # What the host itself held at the moment it refused. A provisioning
    # failure is a statement about the machine rather than about the guest, and
    # the machine's memory position is recoverable from nothing else the cycle
    # keeps -- those numbers exist only in the instant of the call. Carried only
    # when a driver actually measured; ABSENT otherwise, on the same discipline
    # the screen-evidence pointers follow, because a zeroed block would be read
    # as a machine measured and found empty. The file nests the reading and the
    # event carries it flat, like every other nested value on this stream.
    if ($HostMemory -and $HostMemory.Contains('commitLimitBytes')) {
        $file.context['hostMemory'] = [ordered]@{
            availableMb          = [int64]$HostMemory['availableMb']
            committedBytes       = [int64]$HostMemory['committedBytes']
            commitLimitBytes     = [int64]$HostMemory['commitLimitBytes']
            commitAvailableBytes = [int64]$HostMemory['commitAvailableBytes']
            source               = [string]$HostMemory['source']
        }
        $eventRecord['hostAvailableMb']          = [int64]$HostMemory['availableMb']
        $eventRecord['hostCommittedBytes']       = [int64]$HostMemory['committedBytes']
        $eventRecord['hostCommitLimitBytes']     = [int64]$HostMemory['commitLimitBytes']
        $eventRecord['hostCommitAvailableBytes'] = [int64]$HostMemory['commitAvailableBytes']
    }
    return @{ File = $file; Event = $eventRecord }
}

Export-ModuleMember -Function Get-SequenceFailureState, New-SequenceFailureRecord, New-InfraFailureRecord
