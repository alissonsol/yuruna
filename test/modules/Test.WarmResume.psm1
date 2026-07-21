<#PSScriptInfo
.VERSION 2026.07.21
.GUID 428a1d5f-7c92-4b40-a6e1-9d2f4c8b0a63
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

# Warm-resume checkpointing. On an eligible transient workload failure the
# runner re-runs the failed sequence from its last-good step on the SAME live
# VM instead of tearing the guest down and redoing the whole (~40-min) install
# from step 0. This module is the pure decision core + the checkpoint reader +
# the warm_resume event builder; the retry loop and the sequence re-invocation
# live in the runner (Test.RunnerInnerLoop) and the engine (Invoke-Sequence's
# -StartStep / Invoke-GuestSequenceList's -ResumeFromSequence/-ResumeFromStep).
#
# Soundness: resume is only ever attempted for genuinely transient failure
# classes (a hard/deterministic failure would just redo the install and fail
# again), and only in the runner path -- where each workload sequence runs as a
# single file (Invoke-SequenceByName), so last_failure.json's file-local
# `repro.resumeFromStep` maps directly onto Invoke-Sequence's file-local
# -StartStep. (Test-Sequence's chain runner concatenates baselines, making that
# mapping chain-global instead of file-local; the runner does not, so the
# mapping is exact -- see docs/failure-schema.md.) A resume that targets the
# wrong VM/step merely fails and falls through to today's teardown + cold
# re-provision, so the mechanism is safe-on-failure.
#
# Leaf module: Send-CycleEventSafely is resolved at call time (Get-Command
# guarded) by the runner, not here; this module only builds the event record.

# The failure classes for which an in-place resume is sound -- the same
# transient allow-list the outer loop's gated auto-remediation already uses
# (Test.RunnerOuterLoop). A hard/deterministic class (script_error,
# provisioning_failure, pattern_matched_failure, ...) is never resumed.
$script:WarmResumeEligibleClass = @(
    'network_timeout', 'wait_timeout', 'instrumentation_failure', 'host_io_blocked'
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
    return , ([string[]]$script:WarmResumeEligibleClass)
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
        [AllowNull()][string]$HostType
    )
    $emit = [ordered]@{
        timestamp      = (Get-WarmResumeUtcNow)
        event          = 'warm_resume'
        guestKey       = [string]$GuestKey
        sequenceName   = [string]$SequenceName
        resumeFromStep = [int]$ResumeFromStep
        attempt        = [int]$Attempt
    }
    if (-not [string]::IsNullOrWhiteSpace($FailureClass)) { $emit['failureClass'] = [string]$FailureClass }
    if ($VmName)   { $emit['vmName']   = [string]$VmName }
    if ($HostType) { $emit['hostType'] = [string]$HostType }
    return $emit
}

Export-ModuleMember -Function `
    Get-WarmResumeEligibleClass, Test-WarmResumeEligibleClass, Get-WarmResumeCheckpointFromRecord, `
    Read-WarmResumeCheckpoint, Get-WarmResumeDecision, New-WarmResumeEvent
