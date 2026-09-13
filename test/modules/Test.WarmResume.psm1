<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42ea34d8-15ca-4975-b90d-c0c44c40017d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna runner warm-resume checkpoint resilience
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

# --- REGION: https://yuruna.link/42d69dfa-0013
# Warm-resume checkpointing: the pure decision core, the checkpoint reader, and
# the warm_resume event builder. The retry loop lives in Test.RunnerInnerLoop
# and the re-invocation in Invoke-Sequence -StartStep.

# The failure classes for which an in-place resume is sound -- the same
# transient allow-list the outer loop's gated auto-remediation already uses
# (Test.RunnerOuterLoop). A hard/deterministic class (script_error,
# provisioning_failure, pattern_matched_failure, ...) is never resumed.
$script:WarmResumeEligibleClass = @(
    'network_timeout', 'wait_timeout', 'instrumentation_failure', 'host_io_blocked',
    # A step that never resolved an address never reached the guest, so nothing
    # it might have done is in question and replaying it is as sound as replaying
    # a timeout. It earns a place here because on a host whose address moves
    # under it, discovery going quiet for a moment is the ordinary case rather
    # than a broken lab -- and it was the one class the harness produced with no
    # recovery at all, turning a lookup that would have answered seconds later
    # into a lost cycle.
    'ip_not_discovered',
    # No source served the script, so the payload never ran. That is the same
    # ground the address class stands on -- nothing the step might have done is
    # in question, because it did nothing -- and the usual cause, a host that
    # renumbered while the guest held its old address, is gone by the next
    # attempt. It reaches here only for the shortage cases: a digest mismatch
    # never ran either but is a refusal, and the taxonomy keeps it out.
    'payload_unavailable'
)

function Get-WarmResumeUtcNow {
    <#
    .SYNOPSIS
        ISO-8601 UTC 'Z' timestamp matching the telemetry event envelope format.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (Get-Command Get-UtcTimestamp -ErrorAction SilentlyContinue) { return [string](Get-UtcTimestamp) }
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

function Get-WarmResumeEligibleClass {
    <#
    .SYNOPSIS
        The transient failureClass allow-list eligible for an in-place warm resume.
    .OUTPUTS
        [string[]] the eligible class tokens.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    # Cast to the declared [string[]] on the way out. A leading-comma
    # single-object wrap (`return ,([string[]]$x)`) is statically inferred as
    # object[] and trips PSUseOutputTypeCorrectly; the only consumer reads
    # .Count, so emitting the typed array directly is equivalent.
    return [string[]]$script:WarmResumeEligibleClass
}

function Test-WarmResumeEligibleClass {
    <#
    .SYNOPSIS
        Is this failureClass one an in-place warm resume can soundly recover?
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][string]$FailureClass)
    if ([string]::IsNullOrWhiteSpace($FailureClass)) { return $false }
    return ($script:WarmResumeEligibleClass -contains ([string]$FailureClass))
}

function Get-WarmResumeCheckpointFromRecord {
    <#
    .SYNOPSIS
        Extract the warm-resume checkpoint fields from a parsed last_failure.json
        record (pure). Returns FailureClass, SequenceName, and ResumeFromStep
        (from repro.resumeFromStep) with safe defaults for a malformed record.
    .OUTPUTS
        [hashtable] FailureClass [string], SequenceName [string], ResumeFromStep [int].
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()]$Record)
    $out = @{ FailureClass = ''; SequenceName = ''; ResumeFromStep = 0 }
    if ($Record -isnot [System.Collections.IDictionary]) { return $out }
    if ($Record.Contains('failureClass')) { $out.FailureClass = [string]$Record['failureClass'] }
    if ($Record.Contains('sequenceName')) { $out.SequenceName = [string]$Record['sequenceName'] }
    $repro = if ($Record.Contains('repro')) { $Record['repro'] } else { $null }
    if ($repro -is [System.Collections.IDictionary] -and $repro.Contains('resumeFromStep')) {
        $out.ResumeFromStep = [int]$repro['resumeFromStep']
    }
    return $out
}

function Read-WarmResumeCheckpoint {
    <#
    .SYNOPSIS
        Read $LogDir/last_failure.json and extract the warm-resume checkpoint.
        Missing/unreadable file -> an empty checkpoint (ResumeFromStep 0), which
        the decision treats as "do not resume".
    .PARAMETER NotBeforeUtc
        Staleness guard: when set, a last_failure.json older than this (2s clock
        tolerance) is treated as stale (a prior phase's/cycle's record) and
        yields an empty checkpoint, so a resume never fires off a stale file.
    .OUTPUTS
        [hashtable] FailureClass [string], SequenceName [string], ResumeFromStep [int].
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$LogDir,
        [AllowNull()][Nullable[DateTime]]$NotBeforeUtc = $null
    )
    $path = Join-Path $LogDir 'last_failure.json'
    if (-not (Test-Path -LiteralPath $path)) { return (Get-WarmResumeCheckpointFromRecord -Record $null) }
    try {
        if ($null -ne $NotBeforeUtc) {
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            if ($item.LastWriteTimeUtc -lt ([DateTime]$NotBeforeUtc).AddSeconds(-2)) {
                Write-Verbose "Read-WarmResumeCheckpoint: $path predates the workload phase; treating as no checkpoint."
                return (Get-WarmResumeCheckpointFromRecord -Record $null)
            }
        }
        $rec = Get-Content -Raw -LiteralPath $path -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        return (Get-WarmResumeCheckpointFromRecord -Record $rec)
    } catch {
        Write-Verbose "Read-WarmResumeCheckpoint: could not parse $path ($($_.Exception.Message)); no resume."
        return (Get-WarmResumeCheckpointFromRecord -Record $null)
    }
}

function Get-WarmResumeDecision {
    <#
    .SYNOPSIS
        Decide, without side effects, whether the current workload failure can be
        warm-resumed and against which workload-list entry.
    .DESCRIPTION
        Resumes only when enabled, the class is transient-eligible, a resume step
        >= 1 was recorded, and the failed sequenceName matches a workload-list
        entry (exact or base-name). ResumeSequence is the matched list entry, so
        the runner passes it verbatim to Invoke-GuestSequenceList.
    .OUTPUTS
        [hashtable] ShouldResume [bool], Reason [string], ResumeSequence [string].
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [bool]$Enabled,
        [AllowNull()][string]$FailureClass,
        [AllowNull()][string]$SequenceName,
        [int]$ResumeFromStep,
        [string[]]$WorkloadSequences = @()
    )
    if (-not $Enabled) { return @{ ShouldResume = $false; Reason = 'disabled'; ResumeSequence = '' } }
    if (-not (Test-WarmResumeEligibleClass -FailureClass $FailureClass)) {
        return @{ ShouldResume = $false; Reason = "class-not-eligible ($FailureClass)"; ResumeSequence = '' }
    }
    if ([int]$ResumeFromStep -lt 1) {
        return @{ ShouldResume = $false; Reason = 'no-resume-step'; ResumeSequence = '' }
    }
    if ([string]::IsNullOrWhiteSpace($SequenceName)) {
        return @{ ShouldResume = $false; Reason = 'no-sequence-name'; ResumeSequence = '' }
    }
    $wantBase = (Split-Path -Leaf ([string]$SequenceName)) -replace '\.ya?ml$', ''
    foreach ($entry in $WorkloadSequences) {
        $e = [string]$entry
        $eBase = (Split-Path -Leaf $e) -replace '\.ya?ml$', ''
        if ($e -eq $SequenceName -or $eBase -eq $wantBase) {
            return @{ ShouldResume = $true; Reason = 'resume'; ResumeSequence = $e }
        }
    }
    return @{ ShouldResume = $false; Reason = "sequence-not-in-workload ($SequenceName)"; ResumeSequence = '' }
}

# --- REGION: https://yuruna.link/42d69dfa-0014
# A checkpoint names the step that FAILED, and resuming there replays it against
# a guest that step may already have half-changed: an install that unpacked
# before its network call died, a seed script that wrote some rows. The step is
# eligible for resume because its FAILURE was transient, which says nothing
# about how much of its work landed first. Replaying onto that residue is a
# different run from the one the sequence describes.
#
# loadDiskSnapshot is the one action that makes the guest's state known again,
# so it is the only honest place to restart: rewind to the most recent one at or
# before the checkpoint and every step after it runs against the state it was
# written for. The cost is redoing the steps in between, which is the trade warm
# resume already makes against a full cold rebuild.
#
# No boundary at or before the checkpoint means there is nothing to restore to.
# The checkpoint is then used as-is -- the same behavior as before any of this
# existed -- because declining to resume would turn a recoverable transient back
# into the lost cycle warm resume was built to prevent.
function Get-WarmResumeRewindStep {
    <#
    .SYNOPSIS
        Pull a resume point back to the loadDiskSnapshot that precedes it (pure).
    .DESCRIPTION
        Scans the sequence's 1-based action list backwards from the checkpoint
        for the nearest loadDiskSnapshot. Returns that step when it lies BEFORE
        the checkpoint; a checkpoint already sitting on the boundary, or a
        sequence with no boundary at or before it, is returned unchanged.
    .OUTPUTS
        [hashtable] ResumeFromStep [int], Rewound [bool], BoundaryStep [int]
        (0 when the sequence has no restore point at or before the checkpoint).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()][string[]]$StepAction,
        [int]$ResumeFromStep
    )
    $out = @{ ResumeFromStep = [int]$ResumeFromStep; Rewound = $false; BoundaryStep = 0 }
    if ([int]$ResumeFromStep -lt 1) { return $out }
    $actions = @($StepAction)
    if ($actions.Count -lt 1) { return $out }
    # A checkpoint past the end (a sequence edited since the failure) still gets
    # a boundary from the steps that do exist rather than no answer at all.
    $upper = [Math]::Min([int]$ResumeFromStep, $actions.Count)
    for ($i = $upper; $i -ge 1; $i--) {
        if ([string]$actions[$i - 1] -eq 'loadDiskSnapshot') {
            $out.BoundaryStep = $i
            if ($i -lt [int]$ResumeFromStep) {
                $out.ResumeFromStep = $i
                $out.Rewound        = $true
            }
            return $out
        }
    }
    return $out
}

function Get-WarmResumeStepAction {
    <#
    .SYNOPSIS
        The ordered action names of a sequence file, 1-based to match the step
        numbers a checkpoint records.
    .DESCRIPTION
        Reads through the engine's own loader, which already normalizes and
        expands snippets, so `steps` is the same flat list Invoke-Sequence walks
        and the indexes are the ones -StartStep counts against. Normalizing the
        result again would re-reject it: the loader's output carries the
        synthesized `baseline` key that the normalizer treats as the legacy
        shape. Any failure to read yields an empty list, which the rewind treats
        as "no boundary known" and leaves the checkpoint alone.
    .OUTPUTS
        [string[]] action names in step order; empty when the file cannot be read.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return [string[]]@() }
    if (-not (Get-Command Read-SequenceFile -ErrorAction SilentlyContinue) -or
        -not (Get-Command Get-StepLeadAction -ErrorAction SilentlyContinue)) {
        Write-Verbose 'Get-WarmResumeStepAction: sequence loader unavailable; no boundary known.'
        return [string[]]@()
    }
    try {
        $seq = Read-SequenceFile -Path $Path
        if ($seq -isnot [System.Collections.IDictionary] -or -not $seq.Contains('steps')) { return [string[]]@() }
        # Each step reports the action it LEADS with, not the name it carries: a
        # sequence that nests its restore inside a `retry` block has no
        # `loadDiskSnapshot` at top level, and reading the wrapper's own name
        # would leave the rewind with no boundary to find -- resuming in place,
        # onto the residue the boundary exists to discard. Rewinding to the
        # wrapper is sound because entering it runs that restore first.
        return [string[]]@(@($seq['steps']) | ForEach-Object { [string](Get-StepLeadAction -Step $_) })
    } catch {
        Write-Verbose "Get-WarmResumeStepAction: could not read $Path ($($_.Exception.Message)); no boundary known."
        return [string[]]@()
    }
}

function New-WarmResumeEvent {
    <#
    .SYNOPSIS
        Build the schema-valid warm_resume NDJSON event envelope. Blank context
        fields are dropped so the typed-string schema check passes.
    .OUTPUTS
        [System.Collections.Specialized.OrderedDictionary] the event record.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory builder: returns a fresh event hashtable; changes no externally observable state.')]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [AllowNull()][string]$VmName,
        [Parameter(Mandatory)][string]$SequenceName,
        [int]$ResumeFromStep,
        [AllowNull()][string]$FailureClass,
        [int]$Attempt,
        [AllowNull()][string]$HostType,
        # The checkpoint before any rewind. Recorded whenever it differs from
        # the step actually resumed, so a run that replayed work says how much
        # rather than leaving the gap to be inferred from two step numbers that
        # no longer agree.
        [int]$CheckpointStep = 0
    )
    $emit = [ordered]@{
        timestamp      = (Get-WarmResumeUtcNow)
        event          = 'warm_resume'
        guestKey       = [string]$GuestKey
        sequenceName   = [string]$SequenceName
        resumeFromStep = [int]$ResumeFromStep
        attempt        = [int]$Attempt
    }
    if ([int]$CheckpointStep -gt 0 -and [int]$CheckpointStep -ne [int]$ResumeFromStep) {
        $emit['checkpointStep'] = [int]$CheckpointStep
        $emit['rewoundSteps']   = [int]$CheckpointStep - [int]$ResumeFromStep
    }
    if (-not [string]::IsNullOrWhiteSpace($FailureClass)) { $emit['failureClass'] = [string]$FailureClass }
    if ($VmName)   { $emit['vmName']   = [string]$VmName }
    if ($HostType) { $emit['hostType'] = [string]$HostType }
    return $emit
}

# Verbs that hand work to the guest which OUTLIVES the step: a fetched script
# installs packages, writes files, initializes tofu state. Replaying one puts
# the second run on top of the first run's residue, and tools that are
# deliberately not idempotent (tofu refusing an already-initialized working
# directory is the canonical one) fail on the residue rather than on whatever
# stopped the original attempt. Verbs absent from this list only read, type or
# wait, so replaying them costs time and nothing else.
$script:WarmResumeGuestStateVerbs = @('fetchAndExecute', 'sshFetchAndExecute', 'sshExec')

function Test-WarmResumeReplayIsSafe {
    <#
    .SYNOPSIS
        Whether the checkpoint step can be replayed IN PLACE -- with no restore
        point to discard what the failed attempt already applied (pure).
    .DESCRIPTION
        Get-WarmResumeRewindStep pulls a resume point back to the
        loadDiskSnapshot before it precisely so the replay meets the state its
        steps were written for. When the sequence has no such boundary that
        lookup returns the checkpoint unchanged, and the resume proceeds anyway
        -- straight onto the residue the boundary exists to discard.

        For a step that only reads or types, that is harmless. For one that ran
        guest work, it is worse than not resuming: the replay fails on leftovers
        from the first attempt, and THAT failure is what gets reported, so the
        cycle blames a state conflict the guest created rather than the
        transient that actually stopped it -- and the original evidence is gone.
        Declining to resume keeps the real failure intact and costs only the
        recovery that was never sound to attempt.

        A checkpoint outside the known action list is treated as unsafe: an
        unreadable sequence is not evidence that replaying is harmless.
    .OUTPUTS
        [bool] $true when replaying in place is safe.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][string[]]$StepAction,
        [int]$ResumeFromStep
    )
    # @($null) is a ONE-element array holding $null, not an empty one, so a null
    # action list would otherwise index to '' -- a verb absent from the list --
    # and report the replay safe. For a guard, "I could not tell" must fall on
    # the same side as "unsafe".
    if ($null -eq $StepAction) { return $false }
    $actions = @($StepAction)
    if ($actions.Count -lt 1) { return $false }
    if ([int]$ResumeFromStep -lt 1 -or [int]$ResumeFromStep -gt $actions.Count) { return $false }
    $verb = [string]$actions[[int]$ResumeFromStep - 1]
    if ([string]::IsNullOrWhiteSpace($verb)) { return $false }
    return ($verb -notin $script:WarmResumeGuestStateVerbs)
}

Export-ModuleMember -Function `
    Get-WarmResumeEligibleClass, Test-WarmResumeEligibleClass, Get-WarmResumeCheckpointFromRecord, `
    Read-WarmResumeCheckpoint, Get-WarmResumeDecision, New-WarmResumeEvent, `
    Get-WarmResumeRewindStep, Get-WarmResumeStepAction, Test-WarmResumeReplayIsSafe
