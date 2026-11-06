<#PSScriptInfo
.VERSION 2026.11.05
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.Registry.psm1') -Global -Force
Import-Module (Join-Path $PSScriptRoot 'Test.FailureTaxonomy.psm1') -DisableNameChecking

# --- REGION: Slot declarations
# Every slot the store holds, with its default and its lifetime: when the
# engine puts it back to that default (Reset-SequenceFailureSlot).
#   sequence  at the start of each top-level sequence
#   step      at the start of each attempted step, nested ones included,
#             and of each sequence
#   wait      at the entry of each screen wait, and of each step and sequence
#   gate      by the sequence-start pause gate, before it runs, since the
#             gate itself records the hold the first step reads
#   process   seeded once; its one writer overwrites it before each use
# One table instead of a reset list per site: a slot added to a list and not
# to its siblings outlived the step or wait it described and reached a later
# failure record as that failure's cause.
$script:SequenceFailureSlots = [ordered]@{}
function Add-SequenceFailureSlot {
    # Private: declare one slot. A [string[]] default is copied on every
    # reset, so no two resets share an array.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('sequence', 'step', 'wait', 'gate', 'process')][string]$Lifetime,
        [AllowNull()][AllowEmptyString()][AllowEmptyCollection()]$Default
    )
    $script:SequenceFailureSlots[$Name] = [pscustomobject]@{ Name = $Name; Lifetime = $Lifetime; Default = $Default }
}

Add-SequenceFailureSlot -Name 'LastFailureLabel' -Lifetime sequence -Default $null
Add-SequenceFailureSlot -Name 'LastFailureDescription' -Lifetime sequence -Default $null
Add-SequenceFailureSlot -Name 'LastFailedAction' -Lifetime sequence -Default $null
Add-SequenceFailureSlot -Name 'LastFailedStepNumber' -Lifetime sequence -Default 0
# When the failing step began. The failure record judges the per-VM screen
# artifacts at the log root against it: those files are sticky and only the
# verbs that read a screen rewrite them, so anything written before the step
# started belongs to an earlier one and must not be claimed as this
# failure's evidence. $null means no boundary is known, and the record then
# claims the artifacts as it always did rather than guessing.
Add-SequenceFailureSlot -Name 'LastFailedStepStartedUtc' -Lifetime sequence -Default $null
Add-SequenceFailureSlot -Name 'LastFailedStepInvocationId' -Lifetime step -Default ''
Add-SequenceFailureSlot -Name 'LastFailedSequenceInvocationId' -Lifetime step -Default ''
# The outer retry owns the failure event; the leaf owns its fetch evidence.
Add-SequenceFailureSlot -Name 'OriginatingStepInvocationId' -Lifetime step -Default ''
Add-SequenceFailureSlot -Name 'OriginatingSequenceInvocationId' -Lifetime step -Default ''
# Inner-verb slots: a retry Handler captures the deepest inner verb's
# classification here before the outer per-step path overwrites
# LastFailedAction with 'retry', so the failure record can surface both
# the outer 'retry_exhausted' class and the inner cause a remediator
# needs to pick a recovery. [string[]] empty array, never $null, so the
# NDJSON field always renders as a JSON array.
Add-SequenceFailureSlot -Name 'LastInnerFailedAction' -Lifetime sequence -Default $null
Add-SequenceFailureSlot -Name 'LastInnerFailureClass' -Lifetime sequence -Default $null
Add-SequenceFailureSlot -Name 'LastInnerSeverity' -Lifetime sequence -Default $null
Add-SequenceFailureSlot -Name 'LastInnerSuggestedRecoveries' -Lifetime sequence -Default ([string[]]@())
# 0 = "no step succeeded": a fresh-cycle failure on step 1 must not carry
# a leftover resume boundary from a prior sequence's run.
Add-SequenceFailureSlot -Name 'LastSucceededStepNumber' -Lifetime sequence -Default 0
# Cross-function anti-pattern signal; reset per-step inside Wait-ForText
# and sshWaitReady, cleared here too so a sequence starts clean.
Add-SequenceFailureSlot -Name 'WaitForTextMatchedFailurePattern' -Lifetime wait -Default $null
# Runtime cause signal captured at the wait/OCR failure site: the freshest
# full-screen OCR text (bounded tail) and the patterns the wait was seeking.
# Lets a consumer see WHAT was on screen vs WHAT was sought, not just the
# verb-static failureClass. [string[]] empty (never $null) so the NDJSON
# field always renders as a JSON array, same guard as the inner-recovery slot.
Add-SequenceFailureSlot -Name 'WaitForTextOcrTail' -Lifetime wait -Default $null
Add-SequenceFailureSlot -Name 'WaitForTextPatternsSought' -Lifetime wait -Default ([string[]]@())
# Populated when a freshMatch wait times out on text the engines DID read
# but that had scrolled past the tail window. Without it the record shows a
# sought pattern, an OCR tail that appears not to contain it, and no way to
# tell "never printed" from "printed, then pushed out of the window" -- two
# failures with different owners and different fixes.
Add-SequenceFailureSlot -Name 'WaitForTextFreshWindowNearMiss' -Lifetime wait -Default ([string[]]@())
# See https://yuruna.link/4213a0b3-014e
Add-SequenceFailureSlot -Name 'WaitForTextClosestOnScreen' -Lifetime wait -Default $null
# Populated when the console filled with one repeating log line while the
# wait was seeking its pattern. That case is NOT the same failure as a
# pattern that never printed, and the byte-hash freeze detector cannot see
# it: a scrolling flood changes every frame, so the feed is live and only the
# CONTENT is useless. Left as one class they are indistinguishable in the
# record, and the flood is the one whose owner is the guest rather than the
# capture path.
Add-SequenceFailureSlot -Name 'WaitForTextConsoleFlood' -Lifetime wait -Default $null
# Longest run, in seconds, that the console CONTENT stayed unchanged during
# the wait. Separates the two screens the flood detail alone cannot: one
# scrolling a repeating line, and one frozen on text that scrolled past
# already -- the second is a guest parked on something, and the wait it
# failed was never going to end on its own.
Add-SequenceFailureSlot -Name 'WaitForTextConsoleStaticSeconds' -Lifetime wait -Default 0
# Last substantive Subiquity stage visible during the wait and seconds
# since that marker changed. Network update chatter is excluded; this is
# an observation, not proof that the stage is still executing.
Add-SequenceFailureSlot -Name 'WaitForTextInstallerStage' -Lifetime wait -Default ''
Add-SequenceFailureSlot -Name 'WaitForTextInstallerStageSeconds' -Lifetime wait -Default 0
# Set only on timeout with sustained static content and an independent
# hypervisor framebuffer confirmation. Never inferred from OCR absence.
Add-SequenceFailureSlot -Name 'WaitForTextGuestBootStalled' -Lifetime wait -Default $false
# Independent VM-console observations are distinct from the Windows host
# sampler's virtual-processor counters. Retain unavailable readings too,
# so absence of a probe is never reported as a measured idle guest.
Add-SequenceFailureSlot -Name 'WaitForTextConsoleSecondOpinion' -Lifetime wait -Default $null
# The host recording's livelock verdict at the failed wait (see
# Get-YurunaVmLivelockVerdict), and whether it found every virtual
# processor pinned in the hypervisor for the verdict's full window.
# $null when no host recording exists: not measured, which is not the
# same reading as measured and found running.
Add-SequenceFailureSlot -Name 'WaitForTextGuestLivelock' -Lifetime wait -Default $null
Add-SequenceFailureSlot -Name 'WaitForTextGuestLivelocked' -Lifetime wait -Default $false
# The evidence a wait ended on before its deadline because the guest kernel
# wedged with a processor or the whole guest silent (see
# Get-GuestKernelStallEnd); $null when the wait did not end that way.
Add-SequenceFailureSlot -Name 'WaitForTextKernelStallEnd' -Lifetime wait -Default $null
# Seconds the console had read blank -- no engine found any text -- when
# the wait ended. The content-static slot above measures only readable
# text, so without this a guest that went black leaves a record that
# reads like a wait that compared nothing.
Add-SequenceFailureSlot -Name 'WaitForTextBlankScreenSeconds' -Lifetime wait -Default 0
# Whether the wait that failed actually evaluated the two slots above. A
# tail-confined match reads the same frames but runs neither tracker, so it
# leaves them at these initializers -- which are also what a measured, moving,
# non-repeating console produces. Defaults to $true so a failure with no wait
# behind it keeps the shape it has always had; only a wait that declined to
# measure clears it.
Add-SequenceFailureSlot -Name 'WaitForTextConsoleSignalsMeasured' -Lifetime wait -Default $true
Add-SequenceFailureSlot -Name 'WaitForTextOutputStaticSeconds' -Lifetime wait -Default $null
Add-SequenceFailureSlot -Name 'StepProgressAdvisory' -Lifetime step -Default $null
# The guest kernel's own reports for the failed step: @{ stepInvocationId;
# serial; recorder } from Get-StepGuestKernelFault, else $null. A retry
# wrapper leaves its failed attempt's reading in place, and the record keeps
# it only for the step it names.
Add-SequenceFailureSlot -Name 'StepGuestKernelFault' -Lifetime step -Default $null
# Set by the sequence-start / per-step pause gate when an operator hold is
# released: @{ releasedAtUtc; heldSeconds; label; pauseScope }. The gate holds
# the runner while the guest keeps running, so a hold is part of the cause of
# whatever the next step finds on screen, and a record that omits it sends the
# reader looking for a guest fault that is not there.
Add-SequenceFailureSlot -Name 'LastPauseRelease' -Lifetime gate -Default $null
# Set by the ssh verbs when host-side discovery never produced an address
# and the bare VM name was dialed as the last route left. The verb registry
# classifies those verbs by their COMMON failure -- a guest command that
# exited non-zero -- but a step that never reached the guest is a different
# fault with a different owner, so the class is corrected from this signal
# rather than from the registry default.
Add-SequenceFailureSlot -Name 'StepGuestAddressUnresolved' -Lifetime step -Default $null
# Set by the ssh verbs when the session died mid-command instead of the
# guest reporting a status. The verb registry classifies those verbs by
# their COMMON failure -- a guest command that exited non-zero -- and a
# dropped transport is not that: nothing is known about the command, which
# may have completed, and the fault is on the path rather than in the
# script. The class is corrected from this signal so the record names the
# right fault and reaches the recovery that suits it.
Add-SequenceFailureSlot -Name 'StepGuestTransportLost' -Lifetime step -Default $null
# Set by the ssh verbs when a DETACHED run could not be accounted for: the
# supervisor was reached but the payload it was watching left no exit
# status. Distinct from a dropped transport, which says only that the host
# stopped watching -- here the work itself is gone, so re-attaching cannot
# recover it and the honest report is that the step's outcome is unknown.
Add-SequenceFailureSlot -Name 'StepGuestRunLost' -Lifetime step -Default $null
# Set by the ssh verbs when the guest ran the fetch wrapper but no source
# served the script. The verb registry classifies these verbs by their COMMON
# failure -- a guest command that exited non-zero -- and this is the opposite:
# no command ran at all. The wrapper says so in its own output; without this
# signal that statement is discarded and an operator is sent to debug a script
# that never executed.
Add-SequenceFailureSlot -Name 'StepGuestPayloadUnavailable' -Lifetime step -Default $null
# Set by a GUI fetch whose staged input was still open in the guest shell
# when the wait gave up. The closing guard never ran, so the payload never
# executed; that is what separates this from a script that ran and stalled.
Add-SequenceFailureSlot -Name 'StepInputLost' -Lifetime step -Default $null
# Set by the input dispatcher when the step's last key, text or click send
# failed: @{ action; stepInvocationId; kind; reason; transport; detail;
# delivered; total }, else $null. kind 'deterministic' -- text the input
# path has no key for, a key name no map defines, an action the host never
# registered -- fails the same way on every retry, so the step is filed as
# plan_invalid instead of the input verbs' retryable host_io_blocked.
Add-SequenceFailureSlot -Name 'StepHostInputFault' -Lifetime step -Default $null
# Set by a GUI fetch whose guest launcher refused the typed envelope, from the
# launcher's own record: the YFE code, the length and SHA-256 it received and
# those that were typed, and whether a context was prepared. Every refusal
# comes before the payload runs. The last refusal of the step, or $null.
Add-SequenceFailureSlot -Name 'StepLauncherRejection' -Lifetime step -Default $null
# Set by an SSH fetch whose apt reported an index that disagrees with its
# InRelease: the URL, the sizes, the server apt named, and what apt_retry saw
# of the caching proxy's copy. The script did fail, but the fix is in the
# cache or the origin, which script_error alone does not say.
Add-SequenceFailureSlot -Name 'StepAptIndexMismatch' -Lifetime step -Default $null
# Set by stopVm and startVm when the guest did not reach the stopped state
# inside the step's deadline. A VM that ignores a shutdown request is not a
# provisioning fault, and retrying the same wait cannot help it: the record
# carries the state the host observed, how long it waited, and the console
# and hypervisor evidence captured at that moment.
# @{ observedState; waitedSeconds; requestedAtUtc; action } or $null.
Add-SequenceFailureSlot -Name 'StepVmNotStopped' -Lifetime step -Default $null
# The step and verb whose handler is running, recorded before the handler is
# invoked, so a crash names the step it happened in rather than the last
# step that failed in the ordinary way.
Add-SequenceFailureSlot -Name 'CurrentAction' -Lifetime process -Default $null
Add-SequenceFailureSlot -Name 'CurrentStepNumber' -Lifetime process -Default 0
# A handler that threw on the current attempted step: @{ stepInvocationId;
# message; origin }, else $null. The step fails like a handler that
# returned $false, so a retry wrapping it can run it again; the record keeps
# the class unknown, because an unexpected exception says nothing about the
# verb's own failure class, and names the exception.
Add-SequenceFailureSlot -Name 'StepHandlerError' -Lifetime step -Default $null
# Which part of a wait-then-type step failed: 'wait' (the screen never
# showed what the step waited for), 'input' or 'confirm'. A verb's
# registered class describes the part that can only fail after the wait --
# passwdPrompt's credential_expired is a rejected password -- so a step that
# never got past its wait is filed as the wait's timeout instead.
Add-SequenceFailureSlot -Name 'StepFailurePhase' -Lifetime step -Default $null
# A handler's proof that the current attempted step did nothing to the
# guest: @{ effect = 'none-proven'; source; stepInvocationId }, else $null.
# Set through Set-StepEffectNoneProven by the handlers that hold such
# evidence; read only for the step that published it.
Add-SequenceFailureSlot -Name 'StepEffect' -Lifetime step -Default $null
# The deploy result a guest entry point reported on its YURUNA_RESULT line,
# read by the ssh verbs: @{ failureClass (canonical); deployFailureClass;
# errorMessage }, else $null. The guest said why its deploy failed, which
# the verb's registered script_error cannot.
Add-SequenceFailureSlot -Name 'StepDeployResult' -Lifetime step -Default $null
# The earliest moment in the current top-level sequence at which the guest
# stopped answering: a dropped SSH transport, typed input the console never
# acknowledged, a diagnostic that no rung could reach, or a shutdown request
# the guest ignored. Each later failure record carries it so a reader finds
# the first symptom instead of only the step that finally gave up. Reset
# at sequence start, never per step.
Add-SequenceFailureSlot -Name 'FirstGuestSilenceUtc' -Lifetime sequence -Default $null
Add-SequenceFailureSlot -Name 'FirstGuestSilenceSource' -Lifetime sequence -Default $null

function Initialize-SequenceFailureStateStore {
    # Private: seed every declared slot the store does not hold yet with its
    # default, in place (callers cache the store by reference, so it must
    # never rebind). On a fresh store that is every slot; after a -Force
    # re-import that is only a slot an updated module declared, so live
    # failure state survives the re-import.
    param([Parameter(Mandatory)]$Store)
    foreach ($slot in $script:SequenceFailureSlots.Values) {
        if (-not $Store.Contains($slot.Name)) { $Store[$slot.Name] = Copy-SequenceFailureSlotDefault -Slot $slot }
    }
}

function Copy-SequenceFailureSlotDefault {
    # Private: the slot's default, as a fresh array when it is one.
    param([Parameter(Mandatory)]$Slot)
    if ($Slot.Default -is [array]) { return , ([string[]]$Slot.Default.Clone()) }
    return $Slot.Default
}

$script:SeqFailReg = New-YurunaRegistry -Name 'SequenceFailureState'

# A -Force re-import mid-cycle must NOT wipe live failure state:
# New-YurunaRegistry reuses the existing store across re-imports, and the seed
# fills only the slots it does not hold yet.
Initialize-SequenceFailureStateStore $script:SeqFailReg.Store[0]

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

function Get-SequenceFailureSlot {
    <#
    .SYNOPSIS
        The declared slots of the failure-state store: Name, Lifetime and
        Default, in declaration order.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @($script:SequenceFailureSlots.Values)
}

function Reset-SequenceFailureSlot {
    <#
    .SYNOPSIS
        Put the slots of one lifetime back to their declared defaults.
    .DESCRIPTION
        Lifetimes nest: a sequence start also resets the step and wait slots,
        and a step start the wait slots, because a step or wait that ended
        with its sequence or step must not leave a cause behind for the next
        one's failure record. The gate and process slots are never reset
        here; their owners write them.
    .PARAMETER Lifetime
        sequence, step or wait.
    .PARAMETER State
        The failure-state store; the shared one when omitted.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Resets in-memory failure-state slots; it changes no system state.')]
    param(
        [Parameter(Mandatory)][ValidateSet('sequence', 'step', 'wait')][string]$Lifetime,
        [System.Collections.IDictionary]$State = (Get-SequenceFailureState)
    )
    $covered = switch ($Lifetime) {
        'sequence' { @('sequence', 'step', 'wait') }
        'step'     { @('step', 'wait') }
        'wait'     { @('wait') }
    }
    foreach ($slot in $script:SequenceFailureSlots.Values) {
        if ($slot.Lifetime -in $covered) { $State[$slot.Name] = Copy-SequenceFailureSlotDefault -Slot $slot }
    }
}

function Save-WaitFailureEvidence {
    <#
    .SYNOPSIS
        Keep a failed wait's last screen and text beside its failure record,
        and put the bounded text and the sought patterns into the cause slots.
    .DESCRIPTION
        One writer for every wait that gives up -- a timeout, a matched failure
        pattern, an installer failure while waiting for SSH, a guest that
        never stopped -- so they cannot drift in the file names, in how much
        text the record keeps, or in whether a path holding wildcard
        characters is copied at all. The patterns are recorded even with no
        readable text: a blank console's record would otherwise read like a
        wait that sought nothing.
    .PARAMETER CapturePath
        The last frame the wait read; copied to failure_screenshot_<vm>.png.
    .PARAMETER OcrText
        That frame's text; written to failure_ocr_<vm>.txt, its last 1200
        characters into the record.
    .PARAMETER Pattern
        What the wait sought. Omit it for a wait that sought no text.
    .PARAMETER LivelockVerdict
        The host recording's verdict over the wait, when one was read.
    .PARAMETER State
        The failure-state store; the shared one when omitted.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][AllowNull()][string]$LogDir,
        [Parameter(Mandatory)][string]$VMName,
        [AllowEmptyString()][AllowNull()][string]$CapturePath,
        [AllowEmptyString()][AllowNull()][string]$OcrText,
        [AllowEmptyCollection()][string[]]$Pattern,
        $LivelockVerdict,
        [System.Collections.IDictionary]$State = (Get-SequenceFailureState)
    )
    if ($LogDir -and $CapturePath -and (Test-Path -LiteralPath $CapturePath)) {
        $failScreenPath = Join-Path $LogDir "failure_screenshot_${VMName}.png"
        Copy-Item -LiteralPath $CapturePath -Destination $failScreenPath -Force -ErrorAction SilentlyContinue
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b24a2d8bfa724905' -Arguments @{ failScreenPath = "$failScreenPath"; screensDir = "$(Split-Path -Parent $CapturePath)" })
    }
    if ($PSBoundParameters.ContainsKey('Pattern')) { $State.WaitForTextPatternsSought = [string[]]@($Pattern) }
    if ($OcrText) {
        if ($LogDir) {
            $failOcrPath = Join-Path $LogDir "failure_ocr_${VMName}.txt"
            Set-Content -LiteralPath $failOcrPath -Value $OcrText -Force -ErrorAction SilentlyContinue
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_ae9f061222f374f7' -Arguments @{ failOcrPath = "$failOcrPath" })
        }
        $State.WaitForTextOcrTail = if ($OcrText.Length -le 1200) { $OcrText } else { $OcrText.Substring($OcrText.Length - 1200) }
    }
    if ($LivelockVerdict) {
        $State.WaitForTextGuestLivelock = $LivelockVerdict
        $State.WaitForTextGuestLivelocked = ($LivelockVerdict.Verdict -eq 'livelocked')
    }
}

function Test-StepHostInputFaultDeterministic {
    <#
    .SYNOPSIS
        Whether the last failed step's own input call failed in a way every
        retry would repeat.
    .DESCRIPTION
        Reads the StepHostInputFault slot the input dispatcher sets, and
        counts it only for the step that recorded it: a fault left by a step
        that ran earlier says nothing about the one that just failed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # The failure-state store; the shared one when omitted.
        [System.Collections.IDictionary]$State = (Get-SequenceFailureState)
    )
    $fail = $State
    $fault = $fail.StepHostInputFault
    return ($fault -is [System.Collections.IDictionary] -and [string]$fault.kind -ceq 'deterministic' -and
        [string]$fault.stepInvocationId -ceq [string]$fail.LastFailedStepInvocationId)
}

function Get-GuestKernelFaultKind {
    <#
    .SYNOPSIS
        The fault kinds either source of a guest kernel reading names for the
        step, in ordinal order; empty when the reading names none or is absent.
    .DESCRIPTION
        A recorder reading that says mayPredateStep can hold reports from
        before the step began, so its kinds stay in the reading and out of
        what the step is said to have shown.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()]$Reading)
    $kinds = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    if ($Reading -is [System.Collections.IDictionary]) {
        foreach ($source in 'serial', 'recorder') {
            $part = $Reading[$source]
            if ($part -isnot [System.Collections.IDictionary] -or $part['mayPredateStep'] -eq $true) { continue }
            foreach ($kind in @($part['kinds'])) { if ($kind) { [void]$kinds.Add([string]$kind) } }
        }
    }
    return [string[]]@($kinds)
}

function Get-GuestProgressAdvisory {
    <# .SYNOPSIS
        Describe independent progress observations without authorizing recovery.
    #>
    [CmdletBinding()]
    param(
        [Nullable[int]]$OutputStaticSeconds,
        [Nullable[int]]$HeartbeatAgeSeconds,
        [ValidateSet('responsive','unresponsive','unavailable')][string]$SshResponsiveness = 'unavailable',
        # Warning codes from the guest clock analysis of the step's recorder
        # samples. A clock that jumped is independent evidence about the
        # guest, never a stall signal on its own: it is listed, not scored.
        [AllowEmptyCollection()][string[]]$ClockWarningCodes = @(),
        # Fault kinds the guest kernel reported during the step (see
        # Get-GuestKernelFaultKind). The guest's own word on a stall, listed
        # beside the others and not scored: a lockup report that reached the
        # console says the kernel saw one, not how long the guest stopped.
        [AllowEmptyCollection()][string[]]$KernelFaultKinds = @()
    )
    $static = $null -ne $OutputStaticSeconds -and $OutputStaticSeconds -ge 120
    $stale = $null -ne $HeartbeatAgeSeconds -and $HeartbeatAgeSeconds -ge 120
    $unresponsive = $SshResponsiveness -eq 'unresponsive'
    [string[]]$clockAnomaly = @($ClockWarningCodes | Where-Object { $_ -and $_ -ne 'clock-evidence-incomplete' } | Select-Object -Unique)
    [string[]]$kernelFaults = @($KernelFaultKinds | Where-Object { $_ } | Select-Object -Unique)
    $signals = @()
    if ($static) { $signals += 'static-output' }
    if ($stale) { $signals += 'stale-recorder-heartbeat' }
    if ($unresponsive) { $signals += 'ssh-unresponsive' }
    if ($clockAnomaly.Count) { $signals += 'guest-clock-anomaly' }
    if ($kernelFaults.Count) { $signals += 'guest-kernel-fault' }
    $verdict = if (($static -and ($stale -or $unresponsive)) -or ($stale -and $unresponsive)) { 'progress-suspect' }
        elseif ($signals.Count) { 'insufficient-evidence' }
        elseif ($null -eq $OutputStaticSeconds -and $null -eq $HeartbeatAgeSeconds -and $SshResponsiveness -eq 'unavailable') { 'unavailable' }
        else { 'no-stall-evidence' }
    [pscustomobject]@{
        verdict=$verdict; signals=$signals; outputStaticSeconds=$OutputStaticSeconds
        heartbeatAgeSeconds=$HeartbeatAgeSeconds; sshResponsiveness=$SshResponsiveness
        clockWarnings=$clockAnomaly
        kernelFaults=$kernelFaults
        automaticRecoveryAllowed=$false
    }
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
    if ($Reason -eq 'crash' -and -not $actionName) {
        $actionName = if ($fail.CurrentAction) { [string]$fail.CurrentAction } else { 'script_error' }
    }
    $handlerError = if ($fail.StepHandlerError -and $Reason -eq 'step' -and
        [string]$fail.StepHandlerError['stepInvocationId'] -ceq [string]$fail.LastFailedStepInvocationId) { $fail.StepHandlerError } else { $null }
    $verbEntry    = if ($fail.LastFailedAction) { Get-SequenceAction -Name $fail.LastFailedAction } else { $null }
    $failureClass = if ($verbEntry) { [string]$verbEntry.FailureClass } else { 'unknown' }
    $severity     = if ($verbEntry) { [string]$verbEntry.Severity }     else { 'unknown' }
    # A thrown outer error is a distinct failure, even if a nested invocation
    # failed first. Only a normal failed wrapper may retain that leaf's join.
    $originatingStepInvocationId = [string]$fail.LastFailedStepInvocationId
    $originatingSequenceInvocationId = [string]$fail.LastFailedSequenceInvocationId
    $progressAdvisory = $fail.StepProgressAdvisory
    $consoleSecondOpinion = $fail.WaitForTextConsoleSecondOpinion
    # A handler that threw is a distinct failure in the same way a crash is.
    if ($Reason -eq 'step' -and -not $handlerError -and $fail.OriginatingStepInvocationId -and $fail.OriginatingSequenceInvocationId) {
        $originatingStepInvocationId = [string]$fail.OriginatingStepInvocationId
        $originatingSequenceInvocationId = [string]$fail.OriginatingSequenceInvocationId
    } elseif (($Reason -eq 'crash' -or $handlerError) -and $fail.OriginatingStepInvocationId -and
        $fail.OriginatingStepInvocationId -ne $fail.LastFailedStepInvocationId) {
        $progressAdvisory = $null
        $consoleSecondOpinion = $null
    }

    if ($Reason -eq 'crash') {
        [string[]]$suggested = @('Inspect the crash origin/stack under .context; cycle continues unless StopOnFailure is set.')
    } else {
        [string[]]$suggested = @()
    }
    if ($verbEntry -and $null -ne $verbEntry.SuggestedRecoveries) {
        [string[]]$suggested = @($verbEntry.SuggestedRecoveries)
    }

    $matchedFailPattern = $fail.WaitForTextMatchedFailurePattern
    $vmNotStopped = if ($fail.StepVmNotStopped -is [System.Collections.IDictionary]) { $fail.StepVmNotStopped } else { $null }
    $vmState = if ($vmNotStopped) { [string]$vmNotStopped.observedState } else { '' }
    $vmStateWaitedSeconds = if ($vmNotStopped) { [int]$vmNotStopped.waitedSeconds } else { 0 }
    $vmStateRequestedAtUtc = if ($vmNotStopped) { [string]$vmNotStopped.requestedAtUtc } else { '' }
    $firstGuestSilenceUtc = if ($fail.FirstGuestSilenceUtc) { [string]$fail.FirstGuestSilenceUtc } else { '' }
    $firstGuestSilenceSource = if ($fail.FirstGuestSilenceSource) { [string]$fail.FirstGuestSilenceSource } else { '' }
    $launcherRejection = if ($fail.StepLauncherRejection -is [System.Collections.IDictionary]) { [ordered]@{
        code           = [string]$fail.StepLauncherRejection.code
        attempt        = [int]$fail.StepLauncherRejection.attempt
        receivedChars  = [int]$fail.StepLauncherRejection.receivedChars
        expectedChars  = [int]$fail.StepLauncherRejection.expectedChars
        receivedSha256 = [string]$fail.StepLauncherRejection.receivedSha256
        expectedSha256 = [string]$fail.StepLauncherRejection.expectedSha256
        payloadState   = [string]$fail.StepLauncherRejection.payloadState
    } } else { $null }
    # The step's own failed input call only: a nested step's fault says nothing
    # about the wrapper that ran it.
    $hostInputFault = if ($fail.StepHostInputFault -is [System.Collections.IDictionary] -and
        [string]$fail.StepHostInputFault.stepInvocationId -ceq [string]$fail.LastFailedStepInvocationId) { [ordered]@{
        action    = [string]$fail.StepHostInputFault.action
        kind      = [string]$fail.StepHostInputFault.kind
        reason    = [string]$fail.StepHostInputFault.reason
        transport = [string]$fail.StepHostInputFault.transport
        detail    = [string]$fail.StepHostInputFault.detail
        delivered = [int]$fail.StepHostInputFault.delivered
        total     = [int]$fail.StepHostInputFault.total
    } } else { $null }
    $aptIndexMismatch = if ($fail.StepAptIndexMismatch -is [System.Collections.IDictionary]) { [ordered]@{
        kind               = [string]$fail.StepAptIndexMismatch.kind
        url                = [string]$fail.StepAptIndexMismatch.url
        receivedBytes      = $fail.StepAptIndexMismatch.receivedBytes
        expectedBytes      = $fail.StepAptIndexMismatch.expectedBytes
        server             = [string]$fail.StepAptIndexMismatch.server
        releaseFileCreated = [string]$fail.StepAptIndexMismatch.releaseFileCreated
        occurrences        = [int]$fail.StepAptIndexMismatch.occurrences
        proxyCopy          = [string]$fail.StepAptIndexMismatch.proxyCopy
        proxyPurgeStatus   = $fail.StepAptIndexMismatch.proxyPurgeStatus
    } } else { $null }
    # The guest kernel's own reports, kept only for the step the reading names:
    # after a retry forwards its failed attempt, that is the originating step,
    # and a reading left by any other step describes a different failure.
    $guestKernelFault = if ($fail.StepGuestKernelFault -is [System.Collections.IDictionary] -and
        [string]$fail.StepGuestKernelFault['stepInvocationId'] -ceq $originatingStepInvocationId) { [ordered]@{
        serial   = $fail.StepGuestKernelFault['serial']
        recorder = $fail.StepGuestKernelFault['recorder']
    } } else { $null }
    [string[]]$guestKernelFaultKinds = @(Get-GuestKernelFaultKind -Reading $guestKernelFault)
    # The host's own address moving while the step ran is evidence the step
    # cannot report about itself: a guest that fetched from the host's old
    # address fails with a plain script error, and the SSH session the runner
    # held into the guest dies with the address it was bound to. The beacon
    # records every move with its instant; the moves that fell inside this
    # step are carried here so the reader meets the cause before the symptom.
    $hostAddressChanges = Get-StepHostAddressChange -Fail $fail
    $hostAddressChangeSummary = ''
    if ($hostAddressChanges -and @($hostAddressChanges).Count -gt 0) {
        $latestMove = @($hostAddressChanges)[-1]
        $hostAddressChangeSummary = "$($latestMove.previous) -> $($latestMove.current) at $($latestMove.changedAtUtc)"
    }
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
    # See https://yuruna.link/4213a0b3-014f
    $consoleMeasured = ($null -eq $fail.WaitForTextConsoleSignalsMeasured) -or [bool]$fail.WaitForTextConsoleSignalsMeasured
    $consoleFlood = if (-not $consoleMeasured) { $null } elseif ($fail.WaitForTextConsoleFlood) { [string]$fail.WaitForTextConsoleFlood } else { '' }
    $consoleStaticSeconds = if (-not $consoleMeasured) { $null } elseif ($fail.WaitForTextConsoleStaticSeconds) { [int]$fail.WaitForTextConsoleStaticSeconds } else { 0 }
    $installerStage = [string]$fail.WaitForTextInstallerStage
    $installerStageSeconds = if ($installerStage) { [int]$fail.WaitForTextInstallerStageSeconds } else { 0 }
    $blankScreenSeconds = [int]$fail.WaitForTextBlankScreenSeconds
    $guestLivelock = $null
    if ($fail.WaitForTextGuestLivelock) {
        $verdict = $fail.WaitForTextGuestLivelock
        $guestLivelock = [ordered]@{
            verdict              = [string]$verdict.Verdict
            livelockedSeconds    = [int]$verdict.LivelockedSeconds
            minimumSeconds       = [int]$verdict.MinimumSeconds
            virtualProcessors    = [int]$verdict.VirtualProcessors
            guestRunPercent      = $verdict.GuestRunPercent
            hypervisorRunPercent = $verdict.HypervisorRunPercent
            interceptsPerSecond  = $verdict.InterceptsPerSecond
            dominantIntercept    = [string]$verdict.DominantIntercept
            interceptBreakdown   = $verdict.InterceptBreakdown
            sampleCount          = [int]$verdict.SampleCount
            newestSampleUtc      = [string]$verdict.NewestSampleUtc
            reason               = [string]$verdict.Reason
            processorWindow      = $verdict.ProcessorWindow
        }
    }
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
    if ($Reason -eq 'crash' -and $stepNumber -eq 0 -and $fail.CurrentStepNumber) { $stepNumber = [int]$fail.CurrentStepNumber }
    if ($Reason -eq 'crash') {
        $label = if ($fail.LastFailureLabel) { [string]$fail.LastFailureLabel } else { "engine crash: $($CrashError.Exception.Message)" }
        $desc  = if ($fail.LastFailureDescription) { [string]$fail.LastFailureDescription } else { '(crash before step completion)' }
    } else {
        # The handler threw before it could say how the step failed: the
        # registry's class describes the verb's own failure, not this one.
        if ($handlerError) {
            $failureClass = 'unknown'
            [string[]]$suggested = @('pause_and_inspect')
        }
        # See https://yuruna.link/4213a0b3-0150
        elseif ($matchedFailPattern) {
            $failureClass = 'pattern_matched_failure'
            [string[]]$suggested = @('pause_and_inspect')
        }
        # The guest's deploy entry point named its own failure class. Ordered
        # after the pattern match, which is likewise the guest's own statement,
        # and before the transport signals: a result line means the run ended
        # and reported.
        elseif ($fail.StepDeployResult -is [System.Collections.IDictionary]) {
            $failureClass = [string]$fail.StepDeployResult['failureClass']
            [string[]]$suggested = if ($failureClass -ceq 'network_timeout') { @('retry_with_backoff','pause_and_inspect') } else { @('pause_and_inspect') }
        }
        # A send the host can never make -- text its input path has no key for,
        # a key name no map defines -- fails the same way on every attempt, so
        # the retryable host_io_blocked would only repeat it. The step asks for
        # something this host cannot run: a plan problem, for a person to fix.
        elseif ($hostInputFault -and $hostInputFault.kind -ceq 'deterministic') {
            $failureClass = 'plan_invalid'
            [string[]]$suggested = @('pause_and_inspect')
        }
        # See https://yuruna.link/4213a0b3-0150
        elseif ($fail.StepInputLost) {
            $failureClass = 'input_lost'
            [string[]]$suggested = @('retry_with_backoff','pause_and_inspect')
        }
        # See https://yuruna.link/42820e91#failure-class-vm_not_stopped
        # A retry wrapper's cold restart is no route here:
        # Test-SequenceColdPowerCyclePolicy admits it only after a login wait. A
        # wait for an install's own power-off requested no shutdown, so it keeps
        # the verb's provisioning_failure.
        elseif ($fail.StepVmNotStopped -and -not ($vmNotStopped -and $vmNotStopped.installPowerOff)) {
            $failureClass = 'vm_not_stopped'
            [string[]]$suggested = @('retry_with_backoff','pause_and_inspect')
        }
        # See https://yuruna.link/42820e91#failure-class-guest_kernel_stalled
        # A display verdict has no processor readings and a guest clock that jumped
        # is never a stall on its own, so neither files here. After the guest's own
        # statements and the facts above; before the flood a wedged kernel's repeated
        # reports can print and the symptoms it causes.
        elseif ($fail.WaitForTextKernelStallEnd -or
            ($fail.WaitForTextGuestLivelocked -and $guestLivelock -and [int]$guestLivelock.virtualProcessors -gt 0)) {
            $failureClass = 'guest_kernel_stalled'
            [string[]]$suggested = @('retry_with_backoff','pause_and_inspect')
        }
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
        # See https://yuruna.link/4213a0b3-0151
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
            # Its own class: instrumentation_failure is retried unattended on the
            # strength of a repair that is safe to run twice, and a lost run is
            # not one a re-run of the same instrumentation brings back.
            $failureClass = 'guest_run_lost'
            [string[]]$suggested = @('restart_from_snapshot','pause_and_inspect')
        }
        # See https://yuruna.link/4213a0b3-0152
        elseif ($fail.StepGuestPayloadUnavailable) {
            $failureClass = 'payload_unavailable'
            [string[]]$suggested = @('retry_with_backoff')
        }
        # A wait-then-type step that never got past its wait timed out on the
        # screen, whatever the verb's class says about its later parts.
        elseif ([string]$fail.StepFailurePhase -ceq 'wait' -and $failureClass -cne 'ocr_timeout') {
            $waitEntry = Get-SequenceAction -Name 'waitForText'
            $failureClass = 'ocr_timeout'
            [string[]]$suggested = if ($waitEntry -and $null -ne $waitEntry.SuggestedRecoveries) { @($waitEntry.SuggestedRecoveries) } else { @('pause_and_inspect') }
        }
        $label = $fail.LastFailureLabel
        $desc  = $fail.LastFailureDescription
    }
    # What the failing step is proven to have done to the guest. Only its own
    # handler's proof counts: an inner step's says nothing about the wrapper
    # that ran it. A thrown handler or a matched failure pattern -- the guest
    # announcing its own failure -- outranks the proof, as it outranks the
    # address signal in the class chain above.
    $stepEffect = 'unknown'
    $stepEffectSource = ''
    if ($Reason -eq 'step' -and -not $handlerError -and -not $matchedFailPattern -and
        $fail.StepEffect -is [System.Collections.IDictionary] -and [string]$fail.StepEffect['effect'] -ceq 'none-proven' -and
        [string]$fail.StepEffect['stepInvocationId'] -ceq [string]$fail.LastFailedStepInvocationId) {
        $stepEffect = 'none-proven'
        $stepEffectSource = [string]$fail.StepEffect['source']
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
        elseif ($handlerError)       { 'handler-exception' }
        elseif ($matchedFailPattern) { 'pattern-match' }
        elseif ($fail.StepDeployResult -is [System.Collections.IDictionary]) { 'deploy-result' }
        elseif ($verbEntry)          { 'verb-registry' }
        else                         { 'unresolved-verb' }

    # See https://yuruna.link/4213a0b3-0153
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

    $tsFile        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    $tsEvent       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    # See https://yuruna.link/4213a0b3-0154
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
            docUrl               = (Get-FailureClassDocUrl -FailureClass $failureClass)
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
            stepEffect               = $stepEffect
            stepEffectSource         = $stepEffectSource
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
            docUrl               = (Get-FailureClassDocUrl -FailureClass $failureClass)
            severity             = $severity
            suggestedRecoveries  = $suggested
            actionVerb           = $actionName
            classificationSource = $classificationSource
            sequenceName         = $sequenceName
            repro                = $repro
            lastSucceededStepNumber = [int]$fail.LastSucceededStepNumber
            stepEffect                 = $stepEffect
            stepEffectSource           = $stepEffectSource
            innerActionVerb            = $fail.LastInnerFailedAction
            innerFailureClass          = $fail.LastInnerFailureClass
            innerSeverity              = $fail.LastInnerSeverity
            innerSuggestedRecoveries   = @($fail.LastInnerSuggestedRecoveries)
            context             = [ordered]@{
                hostType              = $HostType
                stepFailurePhase      = [string]$fail.StepFailurePhase
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
                    # How long the console had read blank when the wait ended;
                    # 0 when its last frame carried text. A blank console has
                    # no ocrTail and no static-content reading, so this is the
                    # field that says the screen went black.
                    blankScreenSeconds = $blankScreenSeconds
                    # The hypervisor's view: whether every virtual processor
                    # sat pinned in the hypervisor, for how long, and which
                    # intercepts it was taking. $null when the host keeps no
                    # recording to judge from.
                    guestLivelock = $guestLivelock
                    # Why a wait on a wedged guest kernel ended before its
                    # deadline: the rule that held (basis), the silent
                    # processors or the guest's silence readings, and the
                    # fault kinds on the serial console. $null when the wait
                    # did not end that way.
                    guestKernelStallEnd = $fail.WaitForTextKernelStallEnd
                    consoleSecondOpinion = $consoleSecondOpinion
                    progressAdvisory = $progressAdvisory
                    installerStage = $installerStage
                    installerStageUnchangedSeconds = $installerStageSeconds
                    # The operator hold that ended before this step ran, if any.
                    # A guest keeps running through a hold, so a prompt printed
                    # during one is gone by the time the run resumes -- which
                    # reads on screen exactly like a prompt that never printed.
                    pauseBeforeStepSeconds = $pauseHeldSeconds
                    pauseReleasedAtUtc     = $pauseReleasedAtUtc
                    # The host's reading of the VM when a stopped-wait gave up:
                    # the state it reported, how long the step waited, and when
                    # the shutdown was requested. Empty when no such wait failed.
                    vmState                = $vmState
                    vmStateWaitedSeconds   = $vmStateWaitedSeconds
                    vmStateRequestedAtUtc  = $vmStateRequestedAtUtc
                    # The earliest sign in this sequence that the guest stopped
                    # answering, and which mechanism saw it. Empty when none did.
                    firstGuestSilenceUtc   = $firstGuestSilenceUtc
                    firstGuestSilenceSource = $firstGuestSilenceSource
                    # The guest launcher's refusal of a typed GUI envelope, which
                    # always precedes the payload. $null when it refused nothing.
                    launcherRejection      = $launcherRejection
                    # An apt index that disagreed with its InRelease, as apt and
                    # apt_retry reported it. $null when apt reported none.
                    aptIndexMismatch       = $aptIndexMismatch
                    # How the step's last key, text or click send failed, as the
                    # transport reported it. $null when no send failed.
                    hostInputFault         = $hostInputFault
                    # The lockups, stalls, hung tasks, oopses and panics the
                    # guest kernel reported while the step ran: on its serial
                    # console (Hyper-V) and in the recorder's frozen first stall.
                    # $null when neither source could be read.
                    guestKernelFault       = $guestKernelFault
                    # The host's own address changes the beacon recorded while
                    # the step ran, each with its instant and the addresses it
                    # moved between. $null when no record or window existed;
                    # an empty list is a host that held its address.
                    hostAddressChanges     = $hostAddressChanges
                }
            }
        }
    }

    $file.stepInvocationId = [string]$fail.LastFailedStepInvocationId
    $file.sequenceInvocationId = [string]$fail.LastFailedSequenceInvocationId
    $file.originatingStepInvocationId = $originatingStepInvocationId
    $file.originatingSequenceInvocationId = $originatingSequenceInvocationId

    # Send-CycleEventSafely binds -EventRecord as [hashtable]; build a plain
    # hashtable (same shape both reasons; crash adds crashError).
    $eventRecord = @{
        timestamp               = $tsEvent
        event                   = 'step_failure'
        stepInvocationId        = [string]$fail.LastFailedStepInvocationId
        sequenceInvocationId    = [string]$fail.LastFailedSequenceInvocationId
        originatingStepInvocationId = $originatingStepInvocationId
        originatingSequenceInvocationId = $originatingSequenceInvocationId
        reason                  = $Reason
        stepNumber              = $stepNumber
        totalSteps              = [int]$TotalSteps
        actionVerb              = $actionName
        ok                      = $false
        durationMs              = $null
        failureClass            = $failureClass
        docUrl                  = (Get-FailureClassDocUrl -FailureClass $failureClass)
        severity                = $severity
        classificationSource    = $classificationSource
        suggestedRecoveries     = $suggested
        lastSucceededStepNumber = [int]$fail.LastSucceededStepNumber
        stepEffect                 = $stepEffect
        stepEffectSource           = $stepEffectSource
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
        causeInstallerStage     = $installerStage
        causeInstallerStageUnchangedSeconds = $installerStageSeconds
        causeBlankScreenSeconds = $blankScreenSeconds
        causeGuestLivelocked    = [bool]$fail.WaitForTextGuestLivelocked
        causeGuestLivelockedSeconds = [int]$(if ($guestLivelock) { $guestLivelock.livelockedSeconds } else { 0 })
        causeVmState            = $vmState
        causeVmStateWaitedSeconds = $vmStateWaitedSeconds
        firstGuestSilenceUtc    = $firstGuestSilenceUtc
        firstGuestSilenceSource = $firstGuestSilenceSource
        causeLauncherRejection  = if ($launcherRejection) { $launcherRejection.code } else { '' }
        causeAptIndexMismatch   = if ($aptIndexMismatch) { $aptIndexMismatch.url } else { '' }
        causeHostInputFault     = if ($hostInputFault) { $hostInputFault.reason } else { '' }
        causeGuestKernelFault   = $guestKernelFaultKinds -join ','
        causeHostAddressChange  = $hostAddressChangeSummary
        guestKernelFault        = $guestKernelFault
        progressAdvisory         = $progressAdvisory
        guestProcessorWindow    = if ($guestLivelock) { $guestLivelock.processorWindow } else { $null }
        consoleSecondOpinion    = $consoleSecondOpinion
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

function Get-StepHostAddressChange {
<#
.SYNOPSIS
    The host address changes the beacon recorded between the failed step's
    start and now; $null when there is no window or no record to read over it.
.DESCRIPTION
    The window opens at the step's recorded start and, for a failure before
    any step start was recorded, at the cycle start the log module stamps.
    The beacon module is imported on demand, as Stop-LogFile does: it imports
    nothing, so no cycle forms, and a Get-Command guard alone would be false
    in every session that has not loaded it. Nothing here throws: the record
    is being written for a failure that already happened, and a reading that
    cannot be taken is carried as absent rather than as a second failure.
.OUTPUTS
    [object[]] of ordered hashtables (changedAtUtc, previous, current), empty
    when the host held its address; $null when unmeasured.
#>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)]$Fail)
    $startUtc = $Fail.LastFailedStepStartedUtc -as [DateTime]
    if (-not $startUtc) {
        # The cycle-start stamp the log module keeps for the whole runner.
        $cycleStart = Get-Variable -Name '__YurunaCycleStartUtc' -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if ($cycleStart) {
            try {
                $startUtc = [datetime]::Parse([string]$cycleStart, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
            } catch {
                $startUtc = $null
            }
        }
    }
    if (-not $startUtc) { return $null }
    if (-not (Get-Command Get-HostAddressChangeRow -ErrorAction SilentlyContinue)) {
        try {
            Import-Module (Join-Path $PSScriptRoot 'Test.HostAddressBeacon.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
        } catch {
            Write-Verbose "step failure record: host-address beacon module unavailable -- $($_.Exception.Message)"
            return $null
        }
    }
    $runtimeDir = if ($env:YURUNA_RUNTIME_DIR) { $env:YURUNA_RUNTIME_DIR }
                  else { Join-Path (Split-Path -Parent $PSScriptRoot) 'status' -AdditionalChildPath 'runtime' }
    try {
        $rows = Get-HostAddressChangeRow -RuntimeDir $runtimeDir -StartUtc $startUtc -EndUtc ([datetime]::UtcNow)
    } catch {
        Write-Verbose "step failure record: host address changes unreadable -- $($_.Exception.Message)"
        return $null
    }
    if ($null -eq $rows) { return $null }
    return ,@($rows)
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
        [AllowNull()][hashtable]$HostMemory,
        [AllowNull()][hashtable]$HostStorage,
        [AllowNull()][hashtable[]]$DependencyFailures
    )
    # Two-step [string[]] guard so the empty recoveries list never collapses to
    # $null (the typed-array-cast-if-empty trap); the NDJSON field stays an array.
    [string[]]$suggested = @()
    $tsFile  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    $tsEvent = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
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
        docUrl               = (Get-FailureClassDocUrl -FailureClass $FailureClass)
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
        docUrl               = (Get-FailureClassDocUrl -FailureClass $FailureClass)
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
    if ($DependencyFailures) {
        $file.context['dependencyFailures'] = @($DependencyFailures)
        $eventRecord['dependencyFailures'] = @($DependencyFailures)
    }
    if ($HostStorage -and $HostStorage.Count -gt 0) {
        $file.context['hostStorage'] = $HostStorage
        $eventRecord['hostStorage'] = $HostStorage
    }
    # See https://yuruna.link/4213a0b3-0155
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

Export-ModuleMember -Function Get-SequenceFailureState, Get-GuestProgressAdvisory, Get-GuestKernelFaultKind, New-SequenceFailureRecord, New-InfraFailureRecord, Test-StepHostInputFaultDeterministic, `
    Get-SequenceFailureSlot, Reset-SequenceFailureSlot, Save-WaitFailureEvidence
