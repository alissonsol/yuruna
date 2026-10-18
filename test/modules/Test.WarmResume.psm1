<#PSScriptInfo
.VERSION 2026.10.14
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
    'payload_unavailable',
    # The staged command never closed in the guest shell, so the payload never
    # ran and replaying the step cannot repeat any of its work.
    'input_lost'
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
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
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
# See https://yuruna.link/4213a0b3-0191
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

# --- REGION: Replay safety
# See https://yuruna.link/4213a0b3-0192
$script:ReplayClassRank = @{ 'observe' = 0; 'composite' = 0; 'input' = 1; 'restore-point' = 2; 'state-changing' = 3; 'unclassified' = 4 }

function Get-WarmResumeActionReplayClass {
    <#
    .SYNOPSIS
        The replay-safety class a verb declared at registration, or
        'unclassified' when it declared none or the registry cannot be asked.
    .OUTPUTS
        [string] observe | input | state-changing | restore-point | composite |
        unclassified.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Action)
    if ([string]::IsNullOrWhiteSpace($Action)) { return 'unclassified' }
    if (-not (Get-Command Get-SequenceActionReplaySafety -ErrorAction SilentlyContinue)) { return 'unclassified' }
    try { return [string](Get-SequenceActionReplaySafety -Name $Action) }
    catch { return 'unclassified' }
}

function Get-WarmResumeStepWorstClass {
    <#
    .SYNOPSIS
        The least safe replay class found anywhere inside one step, descending
        into the steps it wraps (pure).
    .DESCRIPTION
        A wrapper such as `retry` runs every step it holds, so replaying it
        replays all of them; the verb it LEADS with says nothing about the ones
        after it. A wrapper that holds nothing, or nesting deeper than anyone
        writes, is not something this can vouch for.
    .OUTPUTS
        [string] one of the classes Get-WarmResumeActionReplayClass returns, with
        'composite' resolved into what it contains.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Step, [int]$Depth = 0)
    if ($null -eq $Step -or $Depth -ge 8) { return 'unclassified' }
    $own = Get-WarmResumeActionReplayClass -Action ([string]$Step.action)
    $inner = @(@($Step.steps) | Where-Object { $null -ne $_ }) + @(@($Step.stepsAfterVmRestart) | Where-Object { $null -ne $_ })
    if ($own -eq 'composite' -and $inner.Count -lt 1) { return 'unclassified' }
    $worst = if ($own -eq 'composite') { 'observe' } else { $own }
    foreach ($child in $inner) {
        $childClass = Get-WarmResumeStepWorstClass -Step $child -Depth ($Depth + 1)
        if ($script:ReplayClassRank[$childClass] -gt $script:ReplayClassRank[$worst]) { $worst = $childClass }
    }
    return $worst
}

function Get-WarmResumeStepReplayClass {
    <#
    .SYNOPSIS
        The replay class of each top-level step of a sequence file, read as a
        whole step rather than by the verb it leads with.
    .DESCRIPTION
        Same loader and same indexing as Get-WarmResumeStepAction, so the two
        lists line up with each other and with -StartStep. A file that cannot be
        read yields an empty list, which Get-WarmResumeReplayClass treats as "no
        reading" and answers from the lead verb alone.
    .OUTPUTS
        [string[]] one class per top-level step; empty when the file cannot be read.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return [string[]]@() }
    if (-not (Get-Command Read-SequenceFile -ErrorAction SilentlyContinue)) {
        Write-Verbose 'Get-WarmResumeStepReplayClass: sequence loader unavailable; no replay reading.'
        return [string[]]@()
    }
    try {
        $seq = Read-SequenceFile -Path $Path
        if ($seq -isnot [System.Collections.IDictionary] -or -not $seq.Contains('steps')) { return [string[]]@() }
        return [string[]]@(@($seq['steps']) | ForEach-Object { Get-WarmResumeStepWorstClass -Step $_ })
    } catch {
        Write-Verbose "Get-WarmResumeStepReplayClass: could not read $Path ($($_.Exception.Message)); no replay reading."
        return [string[]]@()
    }
}

function Get-WarmResumeReplayClass {
    <#
    .SYNOPSIS
        The replay class of the checkpoint step (pure).
    .DESCRIPTION
        Prefers the whole-step reading (-StepReplayClass) when it lines up with
        the action list, and otherwise falls back to the verb the step leads
        with. Anything that cannot be indexed -- no list, an empty list, a
        checkpoint outside it, a blank verb -- is 'unclassified'.
    .OUTPUTS
        [string] observe | input | state-changing | restore-point | unclassified.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][string[]]$StepAction,
        [int]$ResumeFromStep,
        [AllowNull()][string[]]$StepReplayClass = $null
    )
    # @($null) is a ONE-element array holding $null, not an empty one, so a null
    # action list would otherwise index to '' and read as a verb nobody
    # registered.
    if ($null -eq $StepAction) { return 'unclassified' }
    $actions = @($StepAction)
    if ($actions.Count -lt 1) { return 'unclassified' }
    if ([int]$ResumeFromStep -lt 1 -or [int]$ResumeFromStep -gt $actions.Count) { return 'unclassified' }
    $verb = [string]$actions[[int]$ResumeFromStep - 1]
    if ([string]::IsNullOrWhiteSpace($verb)) { return 'unclassified' }
    if ($null -ne $StepReplayClass -and @($StepReplayClass).Count -eq $actions.Count) {
        $whole = [string]@($StepReplayClass)[[int]$ResumeFromStep - 1]
        if (-not [string]::IsNullOrWhiteSpace($whole)) { return $whole }
    }
    $own = Get-WarmResumeActionReplayClass -Action $verb
    # A wrapper that surfaces as its own lead holds no steps of its own.
    if ($own -eq 'composite') { return 'unclassified' }
    return $own
}

function Test-WarmResumeReplayIsSafe {
    <#
    .SYNOPSIS
        Whether the checkpoint step can be replayed IN PLACE -- with no restore
        point to discard what the failed attempt already applied (pure).
    .DESCRIPTION
        Get-WarmResumeRewindStep pulls a resume point back to the
        loadDiskSnapshot before it precisely so the replay meets the state its
        steps were written for. When the sequence has no such boundary that
        lookup returns the checkpoint unchanged, and the resume would otherwise
        proceed anyway -- straight onto the residue the boundary exists to
        discard.

        Only a step that observes (waits, reads the screen, captures evidence)
        is replayed that way. One that types, clicks, or changes guest, host or
        external state is not: the replay fails on, or compounds, the leftovers
        of the first attempt, and THAT failure is what gets reported, so the
        cycle blames a state conflict the guest created rather than the
        transient that actually stopped it -- and the original evidence is gone.
        Declining keeps the real failure intact and costs only a recovery that
        was never sound to attempt.

        A verb that declared nothing, a checkpoint outside the action list and
        an unreadable sequence are all unsafe: not knowing is not evidence that
        replaying is harmless.
    .OUTPUTS
        [bool] $true when replaying in place is safe.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][string[]]$StepAction,
        [int]$ResumeFromStep,
        [AllowNull()][string[]]$StepReplayClass = $null
    )
    return ((Get-WarmResumeReplayClass -StepAction $StepAction -ResumeFromStep $ResumeFromStep -StepReplayClass $StepReplayClass) -ceq 'observe')
}

function Get-WarmResumeBoundarySnapshotId {
    <#
    .SYNOPSIS
        The snapshot id a restore-boundary step names, when that is a plain
        literal; '' otherwise.
    .DESCRIPTION
        A resume that rewinds to a loadDiskSnapshot is only as good as the
        snapshot behind it. The runner probes for it before relying on it, and
        can only do so when the id is known without a sequence's variables: an id
        built from `${...}` is left to the restore step's own check, which fails
        loudly on a missing snapshot.
    .OUTPUTS
        [string] the literal id, or '' when it is absent, not literal, or the
        file cannot be read.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [int]$BoundaryStep
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return '' }
    if (-not (Get-Command Read-SequenceFile -ErrorAction SilentlyContinue)) { return '' }
    try {
        $seq = Read-SequenceFile -Path $Path
        if ($seq -isnot [System.Collections.IDictionary] -or -not $seq.Contains('steps')) { return '' }
        $steps = @($seq['steps'])
        if ([int]$BoundaryStep -lt 1 -or [int]$BoundaryStep -gt $steps.Count) { return '' }
        $node = $steps[[int]$BoundaryStep - 1]
        # The boundary is the step's LEAD action (see Get-WarmResumeStepAction),
        # so a restore nested first inside a wrapper is read the same way.
        for ($depth = 0; $depth -lt 8; $depth++) {
            $inner = @(@($node.steps) | Where-Object { $null -ne $_ })
            if ($inner.Count -lt 1) { break }
            $node = $inner[0]
        }
        if ([string]$node.action -cne 'loadDiskSnapshot') { return '' }
        $id = [string]$node.id
        if ([string]::IsNullOrWhiteSpace($id) -or $id.Contains('${')) { return '' }
        return $id
    } catch {
        Write-Verbose "Get-WarmResumeBoundarySnapshotId: could not read $Path ($($_.Exception.Message))."
        return ''
    }
}

function New-WarmResumeDeclinedEvent {
    <#
    .SYNOPSIS
        Build the schema-valid warm_resume_declined NDJSON event envelope: a
        resume the runner could have attempted and chose not to, with why.
    .DESCRIPTION
        Declining leaves the original failure standing, which is the right
        outcome and an invisible one: nothing else records that a recovery was
        considered. The reason is a stable token (no-restore-point,
        restore-point-missing, safety-check-unavailable) so a remediation loop or
        dashboard can route on it, and replayClass names what made the step
        unsafe. Blank context fields are dropped so the typed-string schema
        check passes.
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
        [Parameter(Mandatory)][string]$Reason,
        [AllowNull()][string]$ReplayClass,
        [AllowNull()][string]$HostType
    )
    $emit = [ordered]@{
        timestamp      = (Get-WarmResumeUtcNow)
        event          = 'warm_resume_declined'
        guestKey       = [string]$GuestKey
        sequenceName   = [string]$SequenceName
        resumeFromStep = [int]$ResumeFromStep
        reason         = [string]$Reason
    }
    if (-not [string]::IsNullOrWhiteSpace($ReplayClass)) { $emit['replayClass'] = [string]$ReplayClass }
    if (-not [string]::IsNullOrWhiteSpace($FailureClass)) { $emit['failureClass'] = [string]$FailureClass }
    if ($VmName)   { $emit['vmName']   = [string]$VmName }
    if ($HostType) { $emit['hostType'] = [string]$HostType }
    return $emit
}

function Resolve-WarmResumeReplayPlan {
    <#
    .SYNOPSIS
        Decides where a failed sequence may restart and whether replaying it is
        safe, as one plan the runner acts on.
    .DESCRIPTION
        The checkpoint names the step that FAILED, and its work may be
        half-applied to the guest -- transient says why it stopped, not how far
        it got. So the replay restarts from the restore point that precedes it
        when there is one, and otherwise stands on its own safety:

          1. Rewind to the last loadDiskSnapshot at or before the checkpoint.
          2. When that restore point's id can be named without the sequence's
             variables and the host definitely does not have it, treat the
             sequence as having no boundary. The replay then has to stand on its
             own safety, instead of running against whatever state the failed
             attempt left. An id that cannot be named, or a probe that cannot
             answer, leaves the restore step's own check to fail loudly.
          3. With no boundary, only a step that merely observes is replayed in
             place. Anything that types, clicks or changes state would run onto
             its own residue and report a conflict in place of the transient that
             stopped the run. If the safety check itself cannot answer, the
             answer is the same: an unanswered question is not a yes.

        Pure with respect to the guest: it reads the sequence file and asks the
        host whether one snapshot exists, and changes nothing.
    .PARAMETER Decision
        The warm-resume decision; ResumeSequence names the sequence, verbatim from
        the workload list (a .yml suffix is allowed and ignored).
    .PARAMETER Checkpoint
        The checkpoint; ResumeFromStep is the step that failed.
    .OUTPUTS
        [pscustomobject] ResumeFromStep (where to restart), Rewound, BoundaryStep,
        Actions and Classes (the sequence's steps as the plan saw them),
        DeclineReason ('' to go ahead; 'no-restore-point', 'restore-point-missing'
        or 'safety-check-unavailable' to decline) and ReplayClass (the worst class
        of the replayed steps, set only when declining).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Decision,
        [Parameter(Mandatory)]$Checkpoint,
        [AllowEmptyString()][string]$SequencesDir = '',
        [AllowEmptyString()][string]$HostType = '',
        [AllowEmptyString()][string]$RepoRoot = '',
        [AllowEmptyString()][string]$VMName = ''
    )
    $checkpointStep = [int]$Checkpoint.ResumeFromStep
    # ResumeSequence is the workload-list entry verbatim, which is allowed to
    # carry a .yml suffix. The resolver appends its own, so a suffixed name looks
    # for <name>.yml.yml, finds nothing, and the boundary lookup comes back empty
    # -- which reads exactly like a sequence with no restore point and drops the
    # rewind without saying so. Strip it the same way the decision does when
    # matching.
    $sequenceName = [string]$Decision.ResumeSequence -replace '\.ya?ml$', ''
    $sequencePath = ''
    if (Get-Command Resolve-SequencePath -ErrorAction SilentlyContinue) {
        try { $sequencePath = [string](Resolve-SequencePath -SequencesDir $SequencesDir -Name $sequenceName -HostType $HostType -RepoRoot $RepoRoot) } catch { $sequencePath = '' }
    }
    [string[]]$actions = @(Get-WarmResumeStepAction -Path $sequencePath)
    $rewind = Get-WarmResumeRewindStep -StepAction $actions -ResumeFromStep $checkpointStep
    $step = [int]$rewind.ResumeFromStep
    $rewound = [bool]$rewind.Rewound
    $boundary = [int]$rewind.BoundaryStep
    # The whole step, not just the verb it leads with: a wrapper replays
    # everything it holds.
    [string[]]$classes = @(Get-WarmResumeStepReplayClass -Path $sequencePath)
    $restoreMissing = $false
    if ($boundary -gt 0 -and (Get-Command Test-VMDiskSnapshot -ErrorAction SilentlyContinue)) {
        $snapshotId = Get-WarmResumeBoundarySnapshotId -Path $sequencePath -BoundaryStep $boundary
        if ($snapshotId) {
            $present = $true
            try { $present = [bool](Test-VMDiskSnapshot -VMName $VMName -Id $snapshotId) } catch { $present = $true }
            if (-not $present) {
                $boundary = 0
                $rewound = $false
                $step = $checkpointStep
                $restoreMissing = $true
            }
        }
    }
    $decline = ''
    if ($boundary -le 0) {
        try {
            if (-not (Test-WarmResumeReplayIsSafe -StepAction $actions -ResumeFromStep $checkpointStep -StepReplayClass $classes)) {
                $decline = if ($restoreMissing) { 'restore-point-missing' } else { 'no-restore-point' }
            }
        } catch {
            Write-Verbose "Resolve-WarmResumeReplayPlan: the safety check failed: $($_.Exception.Message)"
            $decline = 'safety-check-unavailable'
        }
    }
    $replayClass = ''
    if ($decline) {
        $replayClass = 'unclassified'
        try { $replayClass = [string](Get-WarmResumeReplayClass -StepAction $actions -ResumeFromStep $checkpointStep -StepReplayClass $classes) } catch { $replayClass = 'unclassified' }
    }
    return [pscustomobject]@{
        ResumeFromStep = $step
        Rewound        = $rewound
        BoundaryStep   = $boundary
        Actions        = $actions
        Classes        = $classes
        DeclineReason  = $decline
        ReplayClass    = $replayClass
    }
}

Export-ModuleMember -Function `
    Get-WarmResumeEligibleClass, Test-WarmResumeEligibleClass, Get-WarmResumeCheckpointFromRecord, `
    Read-WarmResumeCheckpoint, Get-WarmResumeDecision, New-WarmResumeEvent, New-WarmResumeDeclinedEvent, `
    Get-WarmResumeRewindStep, Get-WarmResumeStepAction, Get-WarmResumeStepReplayClass, `
    Get-WarmResumeReplayClass, Get-WarmResumeActionReplayClass, Get-WarmResumeBoundarySnapshotId, `
    Test-WarmResumeReplayIsSafe, `
    Resolve-WarmResumeReplayPlan
