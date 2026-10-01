<#PSScriptInfo
.VERSION 2026.09.30
.GUID 423aae05-8d83-44cc-b4aa-068ce46e8c35
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking


# ConvertTo-LowerHex (SHA-256 -> lowercase-hex) is the shared leaf converter.
Import-Module (Join-Path $PSScriptRoot 'Test.Hash.psm1') -Global -Force

<#
.SYNOPSIS
    Structured per-step perf log emitter. One JSONL row per step
    execution; one JSONL file per cycle.

.DESCRIPTION
    Writes append-only rows under <testRoot>/status/perf/cycles/
    so cross-host / cross-guest queries (DuckDB, jq, BigQuery) can answer:
      * which harness commit changed step X's duration?
      * is step [seqY][step01] faster on macos.utm than ubuntu.kvm?
      * which guest+host pair is the bottleneck?
    Identity model:
      * sequenceName (file stem, primary join key) + sequenceGuid
        (`42`-prefixed, rename anchor) + sequenceRevision (author-bumped).
      * stepName (YAML `name:` -> raw `description:` -> step.action) +
        stepOrdinal as-of-execution + stepOccurrence (Nth time the name
        appeared in this sequence run). NO per-step GUIDs by design.
      * Two commits: harnessCommit (yuruna) + projectCommit (yuruna-project).
      * Host + guest diagnostics are stored content-addressed under
        status/perf/hostinfo/ and status/perf/guestinfo/; rows carry only
        the sha256 tag. Same dump across N cycles = one file.
      * host.uuid lives under status/runtime/host.uuid (sibling of perf/)
        because it is a per-machine identity used by code paths beyond
        the perf log.

    Defensive: any call before Start-PerfCycle is a silent no-op so a
    cycle that crashes before perf init never fails downstream because
    the row writer was missing context.

    Cross-process: a cycle owner publishes the open cycle handle to
    $env:YURUNA_PERF_CONTEXT, so a child pwsh spawned mid-cycle (a host
    action re-entering Debug-TestSequence.ps1, a nested run) appends to the
    SAME cycle file instead of losing its rows. Adoption is automatic --
    Set-PerfSequenceContext resumes from the handle when this runspace has
    no cycle of its own -- so a new call site cannot forget to opt in.
    Row appends are single-line [File]::AppendAllText, which is what makes
    concurrent writers on one cycle file safe.
#>

# --- REGION: Module state
# Schema 2 adds explicit sequence and step invocation identities; readers
# continue to accept schema 1 records without those fields.
$script:Schema = 2

# Cycle context (set once per cycle by Start-PerfCycle). $null means
# perf logging is disabled for this cycle (perf root unresolvable, or
# Start-PerfCycle never ran).
$script:Cycle    = $null
# Per-guest context. Reset by Set-PerfGuestContext. Optional -- row
# emission still works without a guest set (the row's guest fields go
# null), which matches the cycle-level steps (New-VM, Get-Image, ...)
# that are not bound to a single sequence.
$script:Guest    = $null
# Per-sequence context. Reset by Set-PerfSequenceContext. Carries the
# rolling stepOccurrences map so two passes through the same step name
# in one sequence run (loops, OCR re-polls handled at a higher level)
# get monotonic occurrence numbers.
$script:Sequence = $null

# Name of the environment handle carrying the open cycle across process
# boundaries. Mirrors YURUNA_CYCLE_CONTEXT (Test.Status.psm1), which threads
# the status-doc cycle to the same child processes.
$script:PerfContextEnvVar = 'YURUNA_PERF_CONTEXT'

# --- REGION: Helpers
function Test-PerfLogEnabled {
<#
.SYNOPSIS
    Per-host opt-out gate: testCycle.perfLog.enabled in test.config.yml.
    Returns $true unless the key is present and false.
.DESCRIPTION
    The knob is per HOST (test.config.yml is host-local and git-ignored),
    not per project, so a project's runner config cannot turn collection
    off for the machine.

    Every unreadable state -- no config file, unparseable YAML, missing
    section, absent key -- reads as ENABLED. Collection is the default an
    operator gets without configuring anything, and a host that wants it
    off says so explicitly; the reverse would make a parse hiccup silently
    stop collecting with no signal anywhere.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $modulesDir = $PSScriptRoot
    if (-not $modulesDir) { return $true }
    $testRoot = Split-Path -Parent $modulesDir
    if (-not $testRoot) { return $true }
    $configFile = Join-Path $testRoot 'test.config.yml'
    if (-not (Test-Path -LiteralPath $configFile)) { return $true }
    $doc = $null
    try {
        # Read-TestConfig is the mtime+hash cached parse the runner already
        # uses, so this costs nothing on the second reader in a process.
        # ConvertFrom-Yaml is the fallback for a runspace that loaded this
        # module without Test.Config (test eval, ad-hoc import).
        if (Get-Command -Name Read-TestConfig -ErrorAction SilentlyContinue) {
            $doc = Read-TestConfig -Path $configFile
        } elseif (Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue) {
            $doc = [System.IO.File]::ReadAllText($configFile) | ConvertFrom-Yaml -Ordered
        }
    } catch {
        Write-Verbose "Test-PerfLogEnabled: config read failed, treating as enabled: $($_.Exception.Message)"
        return $true
    }
    if ($doc -isnot [System.Collections.IDictionary]) { return $true }
    $tc = $doc['testCycle']
    if ($tc -isnot [System.Collections.IDictionary]) { return $true }
    $pl = $tc['perfLog']
    if ($pl -isnot [System.Collections.IDictionary]) { return $true }
    if (-not $pl.Contains('enabled')) { return $true }
    return [bool]$pl['enabled']
}

function Publish-PerfCycleContext {
<#
.SYNOPSIS
    Publish the open cycle to $env:YURUNA_PERF_CONTEXT so child processes
    spawned for the rest of this cycle append to the same cycle file.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $script:Cycle) { return }
    if (-not $PSCmdlet.ShouldProcess($script:PerfContextEnvVar, (Format-YurunaOperatorMessage -Key 'runner.operator_5f115efb4ddb7466'))) { return }
    $ctx = [ordered]@{}
    foreach ($k in $script:Cycle.Keys) { $ctx[$k] = $script:Cycle[$k] }
    $ctx['ownerPid'] = $PID
    try {
        Set-Item -LiteralPath "Env:\$($script:PerfContextEnvVar)" -Value ($ctx | ConvertTo-Json -Compress -Depth 5)
    } catch {
        Write-Verbose "Publish-PerfCycleContext: failed (non-fatal): $($_.Exception.Message)"
    }
}

function Clear-PerfCycleContext {
<#
.SYNOPSIS
    Drop the published cycle handle so a later child process cannot adopt a
    cycle that is no longer open.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess($script:PerfContextEnvVar, (Format-YurunaOperatorMessage -Key 'runner.operator_e1d6d0ba8bbb217e'))) { return }
    Remove-Item -LiteralPath "Env:\$($script:PerfContextEnvVar)" -ErrorAction SilentlyContinue
}

function Resume-PerfCycle {
<#
.SYNOPSIS
    Adopt the cycle handle published by an ancestor process. Returns $true
    when this runspace now has an open cycle.
.DESCRIPTION
    Lets a child pwsh contribute rows to the cycle that spawned it without
    minting a second cycle file. A handle with no cycleFile is ignored --
    an adopted cycle that cannot name its file would silently drop rows.
    Never overwrites a cycle this runspace already owns.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if ($script:Cycle) { return $true }
    $raw = [Environment]::GetEnvironmentVariable($script:PerfContextEnvVar)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($script:PerfContextEnvVar, (Format-YurunaOperatorMessage -Key 'runner.operator_9c5c126bfb40e6f7'))) { return $false }
    $jsonOptions = @{}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOptions.DateKind = 'String' }
    try {
        $ctx = $raw | ConvertFrom-Json @jsonOptions -ErrorAction Stop
    } catch {
        Write-Verbose "Resume-PerfCycle: unparseable handle, ignoring: $($_.Exception.Message)"
        return $false
    }
    $cycleFile = [string]$ctx.cycleFile
    if ([string]::IsNullOrWhiteSpace($cycleFile)) { return $false }
    $script:Cycle = @{
        cycleStartUtc           = [string]$ctx.cycleStartUtc
        cycleStartedAtUtc = [string]$ctx.cycleStartedAtUtc
        hostUuid          = [string]$ctx.hostUuid
        hostname          = [string]$ctx.hostname
        hostPlatform      = [string]$ctx.hostPlatform
        hostInfoHash      = [string]$ctx.hostInfoHash
        harnessCommit     = [string]$ctx.harnessCommit
        projectCommit     = [string]$ctx.projectCommit
        cycleFile         = $cycleFile
    }
    return $true
}

function Get-PerfRootDir {
<#
.SYNOPSIS
    Resolves <testRoot>/status/perf/. Returns $null when the module
    can't locate test/modules/ (cycle running outside the harness, or
    test eval from an unexpected location). Module file lives at
    test/modules/Test.Perf.psm1, so two Split-Path -Parent calls reach
    test/.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $modulesDir = $PSScriptRoot
    if (-not $modulesDir) { return $null }
    $testRoot = Split-Path -Parent $modulesDir
    if (-not $testRoot) { return $null }
    return (Join-Path -Path $testRoot -ChildPath 'status' -AdditionalChildPath 'perf')
}

function Get-RuntimeRootDir {
<#
.SYNOPSIS
    Resolves $env:YURUNA_RUNTIME_DIR (set by Initialize-YurunaRuntimeDir),
    falling back to <testRoot>/status/runtime/ when the env var is unset
    so host.uuid still resolves consistently for test-eval contexts.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($env:YURUNA_RUNTIME_DIR) { return $env:YURUNA_RUNTIME_DIR }
    $modulesDir = $PSScriptRoot
    if (-not $modulesDir) { return $null }
    $testRoot = Split-Path -Parent $modulesDir
    if (-not $testRoot) { return $null }
    return (Join-Path -Path $testRoot -ChildPath 'status' -AdditionalChildPath 'runtime')
}

Import-Module (Join-Path $PSScriptRoot 'Test.HostIdentitySeed.psm1') -DisableNameChecking

function Get-PerfHostUuid {
<#
.SYNOPSIS
    Returns a stable per-machine UUID, generated on first use and
    cached in status/runtime/host.uuid. 42-prefixed for visual filter
    in unified logs.
.DESCRIPTION
    Identity for cross-host queries: hostname can collide (multiple
    machines named `localhost`) and rename, MAC moves with NICs.
    A persisted UUID survives rename and is unique by construction.
    Built once per machine and committed to disk inside the runtime
    dir; a machine that loses that dir re-derives the SAME id from its
    hardware where a stable key can be read, so a reimage does not fork
    its history (YURUNA_HOST_ID_SEED=random re-keys deliberately).
    Lives in runtime/ rather than perf/ because
    it is consulted by non-perf code paths (cycle metadata) too.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $runtimeDir = Get-RuntimeRootDir
    if (-not $runtimeDir) { return $null }
    if (-not (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot 'Test.YurunaDir.psm1') -DisableNameChecking
    }
    return Get-YurunaHostId -RuntimeDir $runtimeDir
}

function Get-PerfContentHash {
<#
.SYNOPSIS
    Content-addressed sidecar store. Returns `sha256-<hex>` and writes
    perf/<Folder>/<tag><Extension> the first time a body is seen.
.DESCRIPTION
    Used for hostInfo (Get-SystemDiagnostic text), guestInfo (small
    JSON fingerprint), and sequence-content snapshots. Same body
    across N cycles collapses to one file; rows carry only the
    short tag. Empty/null body returns $null so callers can pass
    through without a guard.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [string]$Extension = '.txt'
    )
    if ([string]::IsNullOrEmpty($Body)) { return $null }
    $root = Get-PerfRootDir
    if (-not $root) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes  = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $hash   = $sha.ComputeHash($bytes)
        $hexStr = ConvertTo-LowerHex $hash
    } finally { $sha.Dispose() }
    $tag    = "sha256-$hexStr"
    $dir    = Join-Path $root $Folder
    $file   = Join-Path $dir   "$tag$Extension"
    if (-not (Test-Path -LiteralPath $file)) {
        $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue
        try {
            [System.IO.File]::WriteAllText($file, $Body)
        } catch {
            Write-Verbose "Get-PerfContentHash: write failed (non-fatal): $($_.Exception.Message)"
            return $null
        }
    }
    return $tag
}

# --- REGION: Lifecycle
function Start-PerfCycle {
<#
.SYNOPSIS
    Establishes cycle-level perf context: cycleStartUtc, both commits, host
    identity, hostInfo hash. Call once per cycle, after Initialize-
    StatusDocument has minted $CycleStartUtc AND the cycle-start host
    diagnostic has been captured.
.DESCRIPTION
    On Windows ":" is illegal in filenames, so the ISO cycleStartUtc
    "2026-05-21T18:42:11Z" becomes "2026-05-21T18-42-11Z" in the
    JSONL filename. The cycleStartUtc field inside each row is the
    untouched ISO so downstream tooling joining on cycleStartUtc across
    sources doesn't have to know about the path-safety transform.
    HostDiagnosticPath is optional; missing file just leaves
    hostInfoHash null on this cycle's rows.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$CycleStartUtc,
        [Parameter(Mandatory)][string]$HostPlatform,
        [string]$Hostname = (hostname),
        [string]$HarnessCommit,
        [string]$ProjectCommit,
        [string]$HostDiagnosticPath
    )
    $root = Get-PerfRootDir
    if (-not $root) {
        Write-Verbose 'Start-PerfCycle: perf root unresolvable; perf log disabled this cycle.'
        return
    }
    if (-not $PSCmdlet.ShouldProcess($root, (Format-YurunaOperatorMessage -Key 'runner.operator_d9c25172b9533b74' -Arguments @{ cycleStartUtc = "$CycleStartUtc" }))) { return }

    # Opting the host out must also retract any handle a previous cycle
    # published, or children would keep adopting a cycle nobody is writing.
    if (-not (Test-PerfLogEnabled)) {
        Write-Verbose 'Start-PerfCycle: disabled by testCycle.perfLog.enabled; no rows will be written this cycle.'
        $script:Cycle = $null; $script:Guest = $null; $script:Sequence = $null
        Clear-PerfCycleContext -Confirm:$false
        return
    }

    $hostInfoHash = $null
    if ($HostDiagnosticPath -and (Test-Path -LiteralPath $HostDiagnosticPath)) {
        try {
            $body = [System.IO.File]::ReadAllText($HostDiagnosticPath)
            $hostInfoHash = Get-PerfContentHash -Folder 'hostinfo' -Body $body
        } catch {
            Write-Verbose "Start-PerfCycle: hostInfo hash failed: $($_.Exception.Message)"
        }
    }

    $safeId    = $CycleStartUtc -replace ':', '-'
    $tail      = ([Guid]::NewGuid().ToString('N')).Substring(0, 4)
    $cycleDir  = Join-Path $root 'cycles'
    $null      = New-Item -ItemType Directory -Path $cycleDir -Force -ErrorAction SilentlyContinue
    $cycleFile = Join-Path $cycleDir "${safeId}__${tail}.jsonl"

    $script:Cycle = @{
        cycleStartUtc           = $CycleStartUtc
        cycleStartedAtUtc = [DateTime]::UtcNow.ToString('o')
        hostUuid          = Get-PerfHostUuid
        hostname          = $Hostname
        hostPlatform      = $HostPlatform
        hostInfoHash      = $hostInfoHash
        harnessCommit     = $HarnessCommit
        projectCommit     = $ProjectCommit
        cycleFile         = $cycleFile
    }
    $script:Guest    = $null
    $script:Sequence = $null
    Publish-PerfCycleContext -Confirm:$false
}

function Set-PerfGuestContext {
<#
.SYNOPSIS
    Sets the per-guest context (guestKey, vmName, optional fingerprint
    hash). Subsequent Write-PerfStepRow calls stamp every row with these
    values until Set-PerfGuestContext is called again or Clear-
    PerfGuestContext fires.
.DESCRIPTION
    GuestFingerprint is a small hashtable (guestKey, base-image
    filename, base-image URL, ...) that hashes to a stable tag
    across cycles when nothing changes. Cheap by design -- the
    full Save-GuestDiagnostic SSH capture is too expensive to run
    on every step row; the fingerprint is the cycle-stable subset
    that is already available without going into the guest.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [string]$VMName,
        [hashtable]$GuestFingerprint
    )
    if (-not $script:Cycle) { return }
    if (-not $PSCmdlet.ShouldProcess($GuestKey, (Format-YurunaOperatorMessage -Key 'runner.operator_b4a724285b579951'))) { return }

    $guestInfoHash = $null
    if ($GuestFingerprint -and $GuestFingerprint.Count -gt 0) {
        $sorted = [ordered]@{}
        foreach ($k in ($GuestFingerprint.Keys | Sort-Object)) { $sorted[$k] = $GuestFingerprint[$k] }
        $json = $sorted | ConvertTo-Json -Compress -Depth 5
        $guestInfoHash = Get-PerfContentHash -Folder 'guestinfo' -Body $json -Extension '.json'
    }
    $script:Guest = @{
        guestKey      = $GuestKey
        vmName        = $VMName
        guestInfoHash = $guestInfoHash
    }
}

function Clear-PerfGuestContext {
<#
.SYNOPSIS
    Drops the active per-guest context so subsequent Write-PerfStepRow
    calls emit null guestKey/vmName/guestInfoHash. Pairs with
    Set-PerfGuestContext at guest teardown.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess('perf-guest', (Format-YurunaOperatorMessage -Key 'runner.operator_7a73aae4c295df7d'))) { return }
    $script:Guest = $null
}

function Set-PerfSequenceContext {
<#
.SYNOPSIS
    Sets per-sequence context: sequenceName (file stem; the primary
    join key), sequenceGuid (`42`-prefixed; rename anchor), sequence-
    Revision (author-bumped int). Optionally snapshots the sequence
    file body into perf/sequences/<hash>.yml so a row carrying the
    content hash can be replayed against the exact YAML that ran.
.PARAMETER PassThru
    Return the fresh sequence invocation ID to the engine for action/checkpoint correlation.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SequenceName,
        [string]$SequenceGuid,
        [int]$SequenceRevision = 0,
        [string]$SequenceContent,
        [switch]$PassThru
    )
    # Every sequence run passes through here, which makes this the one place
    # that can attach a runspace to the ambient cycle. A child pwsh (host
    # action re-entering Debug-TestSequence.ps1, nested run) starts with no cycle
    # of its own; adopting here means no caller has to know it is nested for
    # its rows to land.
    if (-not $script:Cycle) { $null = Resume-PerfCycle -Confirm:$false }
    if (-not $script:Cycle) { return }
    if (-not $PSCmdlet.ShouldProcess($SequenceName, (Format-YurunaOperatorMessage -Key 'runner.operator_10c191b87c817287'))) { return }

    $contentHash = $null
    if ($SequenceContent) {
        $contentHash = Get-PerfContentHash -Folder 'sequences' -Body $SequenceContent -Extension '.yml'
    }
    $script:Sequence = @{
        sequenceInvocationId = [Guid]::NewGuid().ToString('N')
        sequenceName        = $SequenceName
        sequenceGuid        = $SequenceGuid
        sequenceRevision    = $SequenceRevision
        sequenceContentHash = $contentHash
        stepOccurrences     = @{}
    }
    if ($PassThru) { return $script:Sequence.sequenceInvocationId }
}

function Clear-PerfSequenceContext {
<#
.SYNOPSIS
    Drops the active per-sequence context (and its rolling step-
    occurrence map) so subsequent Write-PerfStepRow calls no-op until
    Set-PerfSequenceContext fires again. Pairs with that setter at
    sequence teardown.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess('perf-sequence', (Format-YurunaOperatorMessage -Key 'runner.operator_ecac3a199ab9afa5'))) { return }
    $script:Sequence = $null
}

# --- REGION: Row emit
function Write-PerfStepRow {
<#
.SYNOPSIS
    Appends one JSON line to the current cycle's JSONL file.
.DESCRIPTION
    No-ops silently when called outside a cycle (no Start-PerfCycle)
    or outside a sequence (no Set-PerfSequenceContext) -- matches the
    "facts only, never crash the cycle" contract for the perf log.
    StepOccurrence is derived from the rolling per-sequence map so
    callers don't have to track it; pass the same StepName twice and
    you get 1, 2 automatically. It counts the NAME across the whole
    sequence run and is NOT a retry attempt index -- ParentAttempt is.
    Uses [File]::AppendAllText for atomic single-line append -- no
    read-modify-write, so concurrent writes from the same process or
    a sibling tail/collector are safe.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StepName,
        [Parameter(Mandatory)][int]$StepOrdinal,
        [string]$StepKind = 'action',
        [Parameter(Mandatory)][DateTime]$StartedAtUtc,
        [Parameter(Mandatory)][DateTime]$EndedAtUtc,
        [Parameter(Mandatory)][int]$DurationMs,
        [Parameter(Mandatory)][ValidateSet('pass','fail','skipped','timeout')][string]$Outcome,
        [int]$Attempts = 1,
        [int]$RetryCount = 0,
        [int]$ParentStepOrdinal = 0,
        [string]$ParentAction = '',
        [int]$ParentAttempt = 0,
        [string]$StepInvocationId,
        [string]$CheckpointSourceStepInvocationId,
        [long]$EvidenceCaptureDurationMs = 0,
        [ValidateSet('', 'complete', 'partial', 'timeout', 'unavailable')]
        [string]$DiagnosticOutcome = ''
    )
    if (-not $script:Cycle -or -not $script:Sequence) { return }

    $occ = $script:Sequence.stepOccurrences
    if ($occ.ContainsKey($StepName)) {
        $occ[$StepName] = [int]$occ[$StepName] + 1
    } else {
        $occ[$StepName] = 1
    }
    $stepOccurrence = $occ[$StepName]

    $row = [ordered]@{
        schema              = $script:Schema
        cycleStartUtc             = $script:Cycle.cycleStartUtc
        cycleStartedAtUtc   = $script:Cycle.cycleStartedAtUtc
        hostUuid            = $script:Cycle.hostUuid
        hostname            = $script:Cycle.hostname
        hostPlatform        = $script:Cycle.hostPlatform
        hostInfoHash        = $script:Cycle.hostInfoHash
        harnessCommit       = $script:Cycle.harnessCommit
        projectCommit       = $script:Cycle.projectCommit
        sequenceName        = $script:Sequence.sequenceName
        sequenceInvocationId = $script:Sequence.sequenceInvocationId
        sequenceGuid        = $script:Sequence.sequenceGuid
        sequenceRevision    = $script:Sequence.sequenceRevision
        sequenceContentHash = $script:Sequence.sequenceContentHash
        guestKey            = if ($script:Guest) { $script:Guest.guestKey      } else { $null }
        vmName              = if ($script:Guest) { $script:Guest.vmName        } else { $null }
        guestInfoHash       = if ($script:Guest) { $script:Guest.guestInfoHash } else { $null }
        stepOrdinal         = $StepOrdinal
        stepInvocationId    = $StepInvocationId
        stepOccurrence      = $stepOccurrence
        stepName            = $StepName
        stepKind            = $StepKind
        parentStepOrdinal   = $ParentStepOrdinal
        parentAction        = $ParentAction
        # 1-based retry attempt; 0 outside a retry. stepOccurrence above counts
        # the step NAME across the sequence run, so it cannot answer "which
        # attempt": a step first reached in a later attempt still carries
        # occurrence 1, and two differently named steps in one attempt are both
        # occurrence 1. This field is the only one that separates the attempts.
        parentAttempt       = $ParentAttempt
        startedAtUtc        = $StartedAtUtc.ToUniversalTime().ToString('o')
        endedAtUtc          = $EndedAtUtc.ToUniversalTime().ToString('o')
        durationMs          = $DurationMs
        outcome             = $Outcome
        attempts            = $Attempts
        retryCount          = $RetryCount
    }
    if ($DiagnosticOutcome) { $row.diagnosticOutcome = $DiagnosticOutcome }
    if ($CheckpointSourceStepInvocationId) { $row.checkpointSourceStepInvocationId = $CheckpointSourceStepInvocationId }
    if ($EvidenceCaptureDurationMs -gt 0) { $row.evidenceCaptureDurationMs = $EvidenceCaptureDurationMs }
    $line = ConvertTo-Json -InputObject $row -Compress -Depth 5
    try {
        [System.IO.File]::AppendAllText($script:Cycle.cycleFile, $line + "`n")
    } catch {
        Write-Verbose "Write-PerfStepRow: append failed (non-fatal): $($_.Exception.Message)"
    }
}

function Get-PerfCycleFile {
<#
.SYNOPSIS
    Returns the active cycle's JSONL file path (or $null when no
    Start-PerfCycle has run). Lets a smoke test verify a cycle wrote
    rows.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $script:Cycle) { return $null }
    return $script:Cycle.cycleFile
}

function Get-PerfSchemaVersion {
<#
.SYNOPSIS
    Returns the integer schema version stamped onto every emitted
    perf row. Lets consumers (analysis scripts, downstream loaders)
    branch on schema without parsing a row first.
#>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return $script:Schema
}

Export-ModuleMember -Function `
    Start-PerfCycle, `
    Test-PerfLogEnabled, `
    Resume-PerfCycle, Publish-PerfCycleContext, Clear-PerfCycleContext, `
    Set-PerfGuestContext, Clear-PerfGuestContext, `
    Set-PerfSequenceContext, Clear-PerfSequenceContext, `
    Write-PerfStepRow, `
    Get-PerfCycleFile, Get-PerfSchemaVersion, `
    Get-PerfContentHash, Get-PerfHostUuid, Get-PerfRootDir, Get-RuntimeRootDir
