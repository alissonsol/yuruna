<#PSScriptInfo
.VERSION 2026.06.05
.GUID 42d5e8a2-b1c4-4f09-a6d3-7e8f0a1b2c3d
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
    $stepNumber = if ($fail.LastFailedStepNumber) { [int]$fail.LastFailedStepNumber } else { 0 }
    if ($Reason -eq 'crash') {
        $label = if ($fail.LastFailureLabel) { [string]$fail.LastFailureLabel } else { "engine crash: $($CrashError.Exception.Message)" }
        $desc  = if ($fail.LastFailureDescription) { [string]$fail.LastFailureDescription } else { '(crash before step completion)' }
    } else {
        # Wait-ForText short-circuit on a hard-block pattern reclassifies the step.
        if ($matchedFailPattern) { $failureClass = 'pattern_matched_failure' }
        $label = $fail.LastFailureLabel
        $desc  = $fail.LastFailureDescription
    }

    $tsFile        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    $tsEvent       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $failScreenName = "failure_screenshot_${VMName}.png"
    $failOcrName    = "failure_ocr_${VMName}.txt"

    if ($Reason -eq 'crash') {
        $file = [ordered]@{
            schemaVersion = 2
            stepNumber    = $stepNumber
            totalSteps    = [int]$TotalSteps
            action        = $label
            description   = $desc
            vmName        = $VMName
            guestKey      = $GuestKey
            timestamp     = $tsFile
            failureClass        = $failureClass
            severity            = $severity
            suggestedRecoveries = $suggested
            actionVerb          = $actionName
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
            stepNumber    = $stepNumber
            totalSteps    = [int]$TotalSteps
            action        = $label
            description   = $desc
            vmName        = $VMName
            guestKey      = $GuestKey
            timestamp     = $tsFile
            failureClass        = $failureClass
            severity            = $severity
            suggestedRecoveries = $suggested
            actionVerb          = $actionName
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
            }
        }
    }

    # Send-CycleEventSafely binds -EventRecord as [hashtable]; build a plain
    # hashtable (same shape both reasons; crash adds crashError).
    $eventRecord = @{
        timestamp               = $tsEvent
        event                   = 'step_failure'
        stepNumber              = $stepNumber
        totalSteps              = [int]$TotalSteps
        actionVerb              = $actionName
        ok                      = $false
        durationMs              = $null
        failureClass            = $failureClass
        severity                = $severity
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
        sequencePath            = $SequencePath
        failureScreenshotPath   = $failScreenName
        failureOcrPath          = $failOcrName
    }
    if ($Reason -eq 'crash') { $eventRecord['crashError'] = "$CrashError" }

    return @{ File = $file; Event = $eventRecord }
}

Export-ModuleMember -Function Get-SequenceFailureState, New-SequenceFailureRecord
