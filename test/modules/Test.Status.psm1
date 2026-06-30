<#PSScriptInfo
.VERSION 2026.06.30
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456702
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

$script:Doc  = $null
$script:File = $null

# Test.StateFile owns the atomic temp-write + rename primitive (no-BOM,
# per-PID temp name). Import -Global so a -Force reimport here cannot evict it
# from the global session; the primitive is stateless, so the reimport wipes no
# per-cycle $script: state.
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Global -Force -DisableNameChecking

<#
.SYNOPSIS
    Returns the current UTC time as an ISO 8601 string with Z suffix.
#>
function Get-UtcTimestamp {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

<#
.SYNOPSIS
    Writes a minimal "running" status.json at the very start of a cycle so the
    dashboard stops showing the previous cycle's pass/fail + per-guest pills
    while git pull, project clone, status-service restart, module re-imports and
    cycle-plan resolution run before Initialize-StatusDocument.
.DESCRIPTION
    Preserves only the fields that genuinely span cycles -- history,
    lastGetImageAt, cycle counter, repoUrl, host, hostname. Everything else
    (overallStatus, guests[], cycleId, startedAt, finishedAt, gitCommit,
    pause flags) is cycle-specific and would otherwise leak forward. Sets
    overallStatus="running" and an interim cycleId/startedAt so the banner
    flips immediately; Initialize-StatusDocument overwrites both later with
    the real values once the cycle plan has resolved.
#>
function Reset-StatusDocumentForCycleStart {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$StatusFilePath)

    if (-not $PSCmdlet.ShouldProcess($StatusFilePath, "Reset status document for new cycle")) { return }

    $history        = @()
    $lastGetImageAt = $null
    $repoUrl        = $null
    $cycle          = 0
    $hostType       = $null
    $hostnameValue  = $null
    if (Test-Path $StatusFilePath) {
        try {
            $prev = Get-Content -Raw $StatusFilePath | ConvertFrom-Json
            if ($prev.history)        { $history        = @($prev.history) }
            if ($prev.lastGetImageAt) { $lastGetImageAt = $prev.lastGetImageAt }
            if ($prev.repoUrl)        { $repoUrl        = $prev.repoUrl }
            if ($prev.cycle)          { $cycle          = [int]$prev.cycle }
            if ($prev.host)           { $hostType       = $prev.host }
            if ($prev.hostname)       { $hostnameValue  = $prev.hostname }
        } catch {
            # Prior status.json is unparseable -- preserve the corrupt
            # copy under a timestamped name so an operator (or remediator)
            # can diff it against the fresh doc instead of finding only
            # a silent counter reset. Stamp is millisecond-precision to
            # tolerate same-second rotations (write-write race against
            # the status server). Emit an NDJSON event into the current
            # cycle's ndjson so dashboards / autonomous remediators see
            # the gap explicitly instead of inferring it from a missing
            # history entry.
            $reasonMsg = $_.Exception.Message
            Write-Warning "Could not read previous status: $reasonMsg"
            try {
                $tsStamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ss-fffZ')
                $dst = $StatusFilePath -replace '\.json$', ".corrupt.$tsStamp.json"
                Move-Item -LiteralPath $StatusFilePath -Destination $dst -Force -ErrorAction Stop
                Write-Warning "  preserved corrupt copy at: $dst"
                Send-CycleEventSafely -EventRecord @{
                    timestamp     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event         = 'status_doc_corrupt'
                    original      = [string]$StatusFilePath
                    preservedAt   = [string]$dst
                    parseError    = [string]$reasonMsg
                }
            } catch {
                Write-Verbose "Test.Status: could not rename corrupt status doc: $($_.Exception.Message)"
            }
        }
    }

    $now = Get-UtcTimestamp
    $script:File = $StatusFilePath
    # hostId: the stable per-host pool identity (runtime/host.uuid; distinct from
    # hostname). Resolved via Get-YurunaHostId (reads the same file the entry
    # point seeds) so this never touches the $global directly; '' when
    # Test.YurunaDir is not loaded (standalone status init).
    $hostIdValue = if (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue) {
        [string](Get-YurunaHostId)
    } else { '' }
    $script:Doc  = [ordered]@{
        schemaVersion  = 1
        host           = $hostType
        hostname       = $hostnameValue
        hostId         = $hostIdValue
        cycleId        = $now
        startedAt      = $now
        finishedAt     = $null
        overallStatus  = "running"
        stepPaused     = $false
        cyclePaused    = $false
        # gitCommits is empty until Initialize-StatusDocument runs; the
        # dashboard renders an em-dash for the commit cell in that
        # ~seconds-long window between Reset and Initialize.
        gitCommits     = @()
        repoUrl        = $repoUrl
        lastGetImageAt = $lastGetImageAt
        cycle          = $cycle
        # Cycle-scoped; null on the interim doc so a prior cycle's cause can't
        # leak into the running banner before a guest fails (matches Initialize).
        lastFailure    = $null
        guests         = @()
        # Empty until Initialize-StatusDocument resolves the cycle plan; kept
        # here so the interim "running" doc carries the same shape the
        # dashboard expects (it falls back to the flat guest list while this
        # is empty).
        sequences      = @()
        history        = $history
    }
    Write-StatusJson
}

<#
.SYNOPSIS
    Initializes a fresh status document for a new run and writes status.json.

.DESCRIPTION
    Creates a new status document with the provided parameters. StepNames controls
    which steps are tracked per guest (allows the caller to add Start-GuestWorkload
    when extension scripts are present). Preserves history, cycle count, and
    lastGetImageAt from the previous status file if present. Returns the cycleId
    string.

.PARAMETER GitCommits
    Array of @{ sha = '...'; repoUrl = '...' } hashtables, one per repo
    (framework, project, ...). Persisted into the status document as
    `gitCommits` and rendered as comma-separated linked SHAs in the
    dashboard. Order is preserved; the FIRST element is treated as the
    "primary" repo by the dashboard's logFileUrl helper (used to form the
    per-cycle log filename), so the runner emits the framework entry
    first by convention.
.PARAMETER GitCommit
    DEPRECATED scalar form of GitCommits. When supplied without
    GitCommits, gets wrapped into a single-element array. Kept so older
    callers (and the email-notification path that only knows the
    framework SHA) keep working without a touch-up.
.PARAMETER RepoUrl
    DEPRECATED scalar form of GitCommits. Combined with GitCommit when
    GitCommits is empty. Also persisted into the document's top-level
    `repoUrl` field for legacy-dashboard compat and as the source for
    Start-StatusService.ps1's bootstrap path.
.PARAMETER Sequences
    Ordered list of the cycle's top-level sequences (the entries in
    project/test/test.runner.yml), each an ordered hashtable
    @{ name = '<sequence>'; guests = @('guest.<os>', ...) }, as produced by
    Get-CyclePlanSequenceList. Persisted as the document's `sequences` array;
    the dashboard renders one card per entry (in this order) and joins each
    `guests` member back to the `guests[]` array for step progress. Empty for
    the legacy guestSequence path, where the dashboard falls back to a flat
    per-guest list.
#>
function Initialize-StatusDocument {
    param(
        [string]   $StatusFilePath,
        [string]   $HostType,
        [string]   $Hostname,
        [string]   $GitCommit,
        [string]   $RepoUrl    = $null,
        [object[]] $GitCommits = @(),
        [string[]] $GuestList,
        [object[]] $Sequences  = @(),
        [string[]] $StepNames = @("New-VM", "Start-VM", "New-VM.Resource")
    )
    $script:File = $StatusFilePath

    $history = @()
    $lastGetImageAt = $null
    $repoUrl = $RepoUrl
    $cycle = 0
    if (Test-Path $StatusFilePath) {
        try {
            $prev = Get-Content -Raw $StatusFilePath | ConvertFrom-Json
            if ($prev.history) { $history = @($prev.history) }
            if ($prev.lastGetImageAt) { $lastGetImageAt = $prev.lastGetImageAt }
            if ($prev.cycle) { $cycle = [int]$prev.cycle }
            if (-not $repoUrl -and $prev.repoUrl) { $repoUrl = $prev.repoUrl }
        } catch { Write-Warning "Could not read previous status: $_" }
    }

    # Build the gitCommits array. Callers using the new GitCommits param
    # win; otherwise wrap the legacy GitCommit + RepoUrl scalars into a
    # one-element array so existing callers keep working seamlessly.
    if (-not $GitCommits -or $GitCommits.Count -eq 0) {
        if ($GitCommit) {
            $GitCommits = @([ordered]@{ sha = $GitCommit; repoUrl = $repoUrl })
        } else {
            $GitCommits = @()
        }
    }

    $cycleId = (Get-UtcTimestamp)

    $guests = foreach ($key in $GuestList) {
        $steps = foreach ($sn in $StepNames) {
            [ordered]@{ name=$sn; status="pending"; startedAt=$null; finishedAt=$null; skipped=$false; errorMessage=$null }
        }
        # provenanceFilename / provenanceUrl are populated later via
        # Set-GuestProvenance (called by Invoke-TestRunner once per cycle
        # after the status doc is initialized). Both default to empty so
        # a cycle with missing sidecars still serializes cleanly — the UI
        # falls back to `guestKey` for the card title when
        # provenanceFilename is blank.
        [ordered]@{
            guestKey           = $key
            vmName             = $null
            # Top-level workload sequence(s) this guest is being driven
            # through this cycle (planner-derived). The dashboard renders
            # this above the step pills so an operator immediately sees
            # which user-defined workload is currently in flight rather
            # than just the per-OS guest key. Empty string when no plan
            # entry covers this guest (legacy guestSequence path).
            topLevel           = ''
            status             = "pending"
            steps              = @($steps)
            provenanceFilename = ''
            provenanceUrl      = ''
            # Relative URL (from test/status/) of the debug folder created
            # by Copy-FailureArtifactsToStatusLog when this guest failed
            # mid-cycle. Empty string means no folder exists for this run
            # (guest passed, or failed before any screen capture). Wired
            # into history.guestSummary at Complete-Run so the dashboard
            # can hyperlink the per-guest pill straight to the artifacts.
            failureArtifacts   = ''
        }
    }

    $hostIdValue = if (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue) {
        [string](Get-YurunaHostId)
    } else { '' }
    $script:Doc = [ordered]@{
        schemaVersion  = 1
        host           = $HostType
        hostname       = $Hostname
        hostId         = $hostIdValue
        cycleId        = $cycleId
        startedAt      = $cycleId
        finishedAt     = $null
        overallStatus  = "running"
        stepPaused     = $false
        cyclePaused    = $false
        # `gitCommits` is the source of truth. `repoUrl` (top-level) is
        # kept as the framework URL for legacy-dashboard compat and as the
        # source Start-StatusService.ps1 reads when seeding a fresh
        # status.json. We do NOT keep the old top-level `gitCommit` -- the
        # dashboard reads gitCommits[0].sha instead.
        gitCommits     = @($GitCommits)
        repoUrl        = $repoUrl
        lastGetImageAt = $lastGetImageAt
        cycle          = $cycle + 1
        # Relative URL of this cycle's folder under test/status/. Populated
        # by Start-LogFile once it builds the cycleFolder path; empty until
        # then so a status snapshot taken between Initialize-StatusDocument
        # and Start-LogFile (rare but possible during emergency cleanup)
        # still serializes cleanly. The dashboard uses this URL as the
        # base for the cycle-log link and every per-guest pill: each pill
        # navigates to "<cycleFolderUrl><vmName>/".
        cycleFolderUrl = ''
        # Top-level classified-cause summary of the most recent failure this
        # cycle (failureClass / severity / stepNumber / sequenceName /
        # reproCommand / relPath), set by Set-LastFailureSummary at failure time;
        # null until a guest fails. relPath deep-links the dashboard to
        # last_failure.json under the per-guest folder.
        lastFailure    = $null
        guests         = @($guests)
        # Ordered top-level sequences (the test.runner.yml entries) mapped to
        # the guest(s) each drives. The dashboard renders one card per entry,
        # in this order, and joins `guests` back to the guests[] array above
        # for per-step progress. Empty on the legacy guestSequence path.
        sequences      = @($Sequences)
        history        = $history
    }

    Write-StatusJson
    return $cycleId
}

<#
.SYNOPSIS
    Sets the vmName field for a guest in the current document.
#>
function Set-GuestVMName {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$GuestKey, [string]$VMName)
    if ($PSCmdlet.ShouldProcess($GuestKey, "Set VM name to '$VMName'")) {
        $g = $script:Doc.guests | Where-Object { $_.guestKey -eq $GuestKey }
        if ($g) { $g.vmName = $VMName }
    }
}

<#
.SYNOPSIS
    Updates the top-level status of a guest and flushes status.json.
#>
function Set-GuestStatus {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$GuestKey, [string]$Status)
    if ($PSCmdlet.ShouldProcess($GuestKey, "Set guest status to '$Status'")) {
        $g = $script:Doc.guests | Where-Object { $_.guestKey -eq $GuestKey }
        if ($g) { $g.status = $Status }
        Write-StatusJson
    }
}

<#
.SYNOPSIS
    Updates a step inside a guest and flushes status.json.
#>
function Set-StepStatus {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $GuestKey,
        [string] $StepName,
        [string] $Status,
        [bool]   $Skipped      = $false,
        [string] $ErrorMessage = $null
    )
    if ($PSCmdlet.ShouldProcess("$GuestKey/$StepName", "Set step status to '$Status'")) {
        $g = $script:Doc.guests | Where-Object { $_.guestKey -eq $GuestKey }
        if (-not $g) { return }
        $step = $g.steps | Where-Object { $_.name -eq $StepName }
        if (-not $step) { return }

        $now = (Get-UtcTimestamp)
        if ($Status -eq "running") {
            $step.startedAt = $now
        } else {
            if (-not $step.startedAt) { $step.startedAt = $now }
            $step.finishedAt = $now
        }
        $step.status  = $Status
        $step.skipped = $Skipped
        if ($ErrorMessage) { $step.errorMessage = $ErrorMessage }
        Write-StatusJson
    }
}

<#
.SYNOPSIS
    Records the classified cause + a pointer to last_failure.json on the live
    status doc, so the dashboard (and an agent reading status.json) sees the
    failureClass / severity / repro for the running cycle without re-reading the
    per-guest cycle folder.
.DESCRIPTION
    Top-level lastFailure summary, set at failure time. relPath points to the
    per-guest cycle-folder last_failure.json (resolved by the dashboard against
    the per-guest folder URL). null until a guest fails this cycle.
#>
function Set-LastFailureSummary {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$FailureClass = 'unknown',
        [string]$Severity     = 'unknown',
        [int]   $StepNumber   = 0,
        [string]$SequenceName = '',
        [string]$ReproCommand = '',
        [string]$RelPath      = '',
        [string]$GuestKey     = '',
        [string]$StepName     = '',
        [string]$ErrorMessage = '',
        [string]$VmName       = ''
    )
    if (-not $script:Doc) { return }
    if (-not $PSCmdlet.ShouldProcess('lastFailure', "Record failure cause $FailureClass")) { return }
    $script:Doc.lastFailure = [ordered]@{
        failureClass = $FailureClass
        severity     = $Severity
        stepNumber   = [int]$StepNumber
        sequenceName = $SequenceName
        guestKey     = $GuestKey
        stepName     = $StepName
        errorMessage = $ErrorMessage
        reproCommand = $ReproCommand
        relPath      = $RelPath
        vmName       = $VmName
        recordedAt   = (Get-UtcTimestamp)
    }
    Write-StatusJson
}

<#
.SYNOPSIS
    Marks the run as finished, appends to history, and flushes status.json.
#>
function Complete-Run {
    param([string]$OverallStatus, [int]$MaxHistoryRuns = 30)
    # Emergency-cleanup paths (e.g. a git-pull failure before
    # Initialize-StatusDocument runs) can reach us with no doc. Silently
    # no-op rather than crashing the catch block — nothing to finalize.
    if (-not $script:Doc) { return }
    $script:Doc.finishedAt    = (Get-UtcTimestamp)
    $script:Doc.overallStatus = $OverallStatus

    # Returns integer wall-clock seconds between two ISO-8601-Z
    # timestamps. Null/unparseable inputs and negative deltas (rare
    # clock-skew between Set-StepStatus writes) both yield 0 so the
    # serialized map never has missing or negative values that would
    # complicate downstream trend analysis. All step timestamps the
    # runner writes are Z-suffixed UTC, so a plain DateTime.Parse
    # diff is timezone-safe.
    function Get-StepDurationSec {
        param($StartedAt, $FinishedAt)
        if (-not $StartedAt -or -not $FinishedAt) { return 0 }
        try {
            $s = [datetime]::Parse($StartedAt, [cultureinfo]::InvariantCulture)
            $f = [datetime]::Parse($FinishedAt, [cultureinfo]::InvariantCulture)
            $dt = ($f - $s).TotalSeconds
            if ($dt -lt 0) { return 0 }
            return [int][math]::Round($dt)
        } catch { return 0 }
    }

    # [ordered]@{} preserves insertion order so guestSummary keys keep
    # guestSequence order in the JSON. Per-guest value shape (current
    # object form vs legacy bare-string form), stepDurationsSec contract,
    # and dashboard fallback: https://yuruna.link/test/harness
    $guestSummary = [ordered]@{}
    foreach ($g in $script:Doc.guests) {
        $artifacts = if ($g.Contains('failureArtifacts')) { [string]$g.failureArtifacts } else { '' }
        $stepDurationsSec = [ordered]@{}
        foreach ($s in $g.steps) {
            $stepDurationsSec[$s.name] = (Get-StepDurationSec $s.startedAt $s.finishedAt)
        }
        $guestEntry = [ordered]@{
            status           = $g.status
            stepDurationsSec = $stepDurationsSec
        }
        if ($artifacts) { $guestEntry.failureArtifacts = $artifacts }
        # Persist the failing step's message + the classified cause into the
        # history row so a row is self-describing without re-reading
        # last_failure.json (additive; old rows simply lack these keys).
        $failStep = $g.steps | Where-Object { $_.status -eq 'fail' -and $_.errorMessage } | Select-Object -First 1
        if ($failStep) { $guestEntry.errorMessage = [string]$failStep.errorMessage }
        if ($script:Doc.Contains('lastFailure') -and $script:Doc.lastFailure -and $script:Doc.lastFailure.guestKey -eq $g.guestKey) {
            $guestEntry.failureClass = [string]$script:Doc.lastFailure.failureClass
        }
        $guestSummary[$g.guestKey] = $guestEntry
    }

    # History entries carry their OWN gitCommits snapshot so a row
    # written months ago still links to the right framework + project
    # commits even if the runner has since picked up a new repo URL or
    # added/removed a project clone. The dashboard renders these as
    # comma-separated linked SHAs (framework first, project second).
    # cycleFolderUrl is snapshotted too so the history-row cycle-id
    # link survives even after the live $Doc rolls to the next cycle.
    # The live URL still carries the `.incomplete/` suffix at this
    # point (Complete-Run runs before Stop-LogFile renames the folder
    # to its bare base), so strip the lifecycle suffix to record the
    # post-rename location -- the only location history rows are
    # expected to resolve to.
    # totalDurationSec is the cycle's wall-clock seconds; the dashboard
    # already derives this from startedAt/finishedAt on the fly, so the
    # field is additive — its purpose is to let programmatic trend
    # analysis (jq / Python) read a number directly without re-parsing
    # ISO timestamps.
    $totalDurationSec = (Get-StepDurationSec $script:Doc.startedAt $script:Doc.finishedAt)
    $historyCycleFolderUrl = if ($script:Doc.cycleFolderUrl) {
        $script:Doc.cycleFolderUrl `
            -replace '\.incomplete(/?)$', '$1' `
            -replace '\.aborted\.[^/]+(/?)$', '$1'
    } else { '' }

    # Per-sequence rollup, parallel to guestSummary. The dashboard's Recent
    # Cycles table renders one button per sequence (the test.runner.yml
    # entries this cycle ran), each linking to that sequence's results
    # folder. Built from the cycle's ordered sequences[] joined to the
    # per-guest status + folder URL already gathered in $guestSummary. The
    # status rank mirrors the dashboard's aggregateStatus
    # (fail > running > pass > skipped > pending) so a sequence row's badge
    # matches the Latest Cycle sequence card. A 1:1 sequence links straight
    # to its guest's per-VM folder; a sequence that fans out to >1 guest
    # links to the cycle folder so every guest subfolder stays reachable.
    $statusRank = @{ fail = 5; running = 4; pass = 3; skipped = 2; pending = 1 }
    $sequenceSummary = @(
        foreach ($seq in $script:Doc.sequences) {
            $seqGuests  = @($seq.guests)
            $bestStatus = 'pending'
            $bestRank   = 0
            foreach ($gk in $seqGuests) {
                $gEntry = $guestSummary[$gk]
                $st = if ($gEntry) { [string]$gEntry.status } else { 'pending' }
                $r  = if ($statusRank.ContainsKey($st)) { [int]$statusRank[$st] } else { 0 }
                if ($r -gt $bestRank) { $bestRank = $r; $bestStatus = $st }
            }
            $folderUrl = $historyCycleFolderUrl
            if ($seqGuests.Count -eq 1) {
                $only = $guestSummary[$seqGuests[0]]
                if ($only -and $only.Contains('failureArtifacts') -and $only.failureArtifacts) {
                    $folderUrl = [string]$only.failureArtifacts
                }
            }
            [ordered]@{ name = [string]$seq.name; status = $bestStatus; folderUrl = $folderUrl }
        }
    )

    $entry = [ordered]@{
        cycleId          = $script:Doc.cycleId
        startedAt        = $script:Doc.startedAt
        finishedAt       = $script:Doc.finishedAt
        totalDurationSec = $totalDurationSec
        overallStatus    = $OverallStatus
        gitCommits       = @($script:Doc.gitCommits)
        host             = $script:Doc.host
        hostname         = $script:Doc.hostname
        cycleFolderUrl   = $historyCycleFolderUrl
        guestSummary     = $guestSummary
        sequenceSummary  = @($sequenceSummary)
        # Freeze the cycle's classified cause into the row (like gitCommits /
        # cycleFolderUrl) so a history row is self-describing; null on a pass.
        lastFailure      = if ($script:Doc.Contains('lastFailure') -and $script:Doc.lastFailure) { $script:Doc.lastFailure } else { $null }
    }
    $script:Doc.history = @($entry) + @($script:Doc.history) | Select-Object -First $MaxHistoryRuns
    Write-StatusJson
}

<#
.SYNOPSIS
    Atomically writes the in-memory document to status.json.
.DESCRIPTION
    Before serializing, refreshes $script:Doc.stepPaused and
    $script:Doc.cyclePaused from the presence of control.step-pause and
    control.cycle-pause in $env:YURUNA_RUNTIME_DIR. Those files are the
    source of truth for the two UI Pause/Continue buttons: the status
    server creates/removes them and the runner + Invoke-Sequence poll
    them. Mirroring the flags here keeps the parent's periodic status
    writes from clobbering the server-written values.

    Reads the runtime dir directly from $env:YURUNA_RUNTIME_DIR rather
    than deriving it from the status.json path (Split-Path -Parent
    $script:File) so every consumer of the pause flags -- status
    server, runner, sequence interpreter, this module -- uses the same
    single source of truth. An earlier revision derived it from the
    file path and was correct by coincidence; a caller that ever moved
    status.json outside the runtime dir would have silently desynced.
#>
function Write-StatusJson {
    $runtimeDir = $env:YURUNA_RUNTIME_DIR
    $stepPauseFlag  = Join-Path $runtimeDir 'control.step-pause'
    $cyclePauseFlag = Join-Path $runtimeDir 'control.cycle-pause'
    $script:Doc.stepPaused  = (Test-Path $stepPauseFlag)
    $script:Doc.cyclePaused = (Test-Path $cyclePauseFlag)
    # Per-writer unique temp name: the runner and the status-server
    # process both flush status.json, so a shared fixed "$File.tmp"
    # lets one process's Move-Item rename the other's half-written temp.
    # A PID+GUID suffix keeps each writer's temp private; the rename to
    # the final path stays atomic. Suffix ends in .tmp so existing
    # *.tmp cleanup/ignore rules still match.
    # Atomic temp-write + rename via the shared primitive: guarantees no BOM
    # (Set-Content -Encoding utf8 emits one on PS5.1, and a leading BOM breaks
    # fetch().json() in the browser) and keeps the per-PID temp-name concurrency
    # safety in one place. -Compress:$false preserves the pretty-printed on-disk
    # shape; -Depth 10 matches the document nesting.
    $null = Write-YurunaStateFileJson -Path $script:File -InputObject $script:Doc -Depth 10 -Compress:$false -Confirm:$false
}

<#
.SYNOPSIS
    Reads the lastGetImageAt timestamp from the status file. Returns null if not set.
#>
function Get-LastGetImageTime {
    param([string]$StatusFilePath)
    if ($script:Doc -and $script:Doc.lastGetImageAt) {
        return $script:Doc.lastGetImageAt
    }
    if (-not (Test-Path $StatusFilePath)) { return $null }
    try {
        $doc = Get-Content -Raw $StatusFilePath | ConvertFrom-Json
        return $doc.lastGetImageAt
    } catch { $null = $_; return $null }
}

<#
.SYNOPSIS
    Records the current time as the last Get-Image timestamp and flushes status.json.
#>
function Set-LastGetImageTime {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess("lastGetImageAt", "Set to current UTC time")) {
        $script:Doc.lastGetImageAt = (Get-UtcTimestamp)
        Write-StatusJson
    }
}

<#
.SYNOPSIS
    Records the base-image provenance (downloaded filename + source URL) for
    a guest and flushes status.json.
.DESCRIPTION
    The UI swaps the guest-card title from "guest.ubuntu.server.24" to the
    actual ISO filename (e.g. "ubuntu-24.04.4-live-server-amd64.iso")
    when provenanceFilename is populated; a blank value means fall back
    to guestKey. provenanceUrl is informational (not rendered today;
    kept in the document so operators inspecting track/status.json can
    see where the ISO came from without cross-referencing
    host/*/*.txt sidecars).
#>
function Get-CycleNumber {
<#
.SYNOPSIS
Returns the monotonic cycle counter (1, 2, 3, ...) for the current cycle.
.DESCRIPTION
Read-after-write of $script:Doc.cycle, which Initialize-StatusDocument
incremented from the previous status.json. Used by Start-LogFile to
build the zero-padded cycleId portion of the cycle-folder name
("000001.YYYY-MM-DD.HH-mm-ss.HOSTNAME"). Returns 0 when no document is
loaded (emergency-cleanup callers that reach the log helpers before
Initialize-StatusDocument has run); Start-LogFile treats 0 as the
"no cycle context" case and uses it as the padded prefix verbatim.
#>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    if (-not $script:Doc) { return 0 }
    if ($script:Doc.cycle) { return [int]$script:Doc.cycle }
    return 0
}

function Set-CycleFolderUrl {
<#
.SYNOPSIS
Records the URL of this cycle's folder under test/status/ so the
dashboard can build per-guest tile URLs from it.
.DESCRIPTION
Called by Start-LogFile right after it creates the cycleFolder on disk.
$RelativeUrl is the URL the dashboard (served from test/status/) uses
to navigate -- typically "log/000001.2026-05-11.16-24-39.HOST/". The
per-guest pill URL is built as "<RelativeUrl><vmName>/". Both the live
$Doc field and the per-history snapshot read this value.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RelativeUrl
    )
    if (-not $script:Doc) { return }
    if (-not $PSCmdlet.ShouldProcess('cycleFolderUrl', "Set to '$RelativeUrl'")) { return }
    $script:Doc.cycleFolderUrl = $RelativeUrl
    Write-StatusJson
}

function Set-GuestFailureArtifact {
<#
.SYNOPSIS
Records the relative URL of the per-guest data folder (cycleGuestData-
Folder) where this guest's diagnostics, logs, and failure artifacts
live. Set on every guest -- success or failure -- so the dashboard
tile always navigates to the same place.
.DESCRIPTION
The folder layout is one folder per guest per cycle (independent of
pass/fail), so Invoke-TestInnerRunner calls this function eagerly as
soon as the per-guest folder is created -- not only on failure. The
dashboard JS uses the empty-string check to decide whether to wrap the
pill in an anchor, so an empty string clears the field for contexts
that legitimately have no per-guest folder (status reset between
cycles). The JSON field name is `failureArtifacts` for back-compat
with old history rows and the dashboard JS that reads them; only the
cmdlet name is singular per PowerShell Verb-Noun convention.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RelativeUrl
    )
    if (-not $script:Doc) { return }
    if (-not $PSCmdlet.ShouldProcess($GuestKey, "Set failureArtifacts to '$RelativeUrl'")) { return }
    $g = $script:Doc.guests | Where-Object { $_.guestKey -eq $GuestKey }
    if (-not $g) { return }
    $g.failureArtifacts = $RelativeUrl
    Write-StatusJson
}

function Set-GuestTopLevel {
<#
.SYNOPSIS
    Records the cycle plan's top-level workload(s) on a guest's status entry.
.DESCRIPTION
    Each plan entry is a (top-level, guest, chain) tuple. When the same
    guest appears in multiple top-levels in one cycle (because more than
    one workload depends on it), we join the names with " + " so the
    dashboard cell stays one line. Stored in $script:Doc.guests[].topLevel
    and rendered above the step pills.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [string]$TopLevel = ''
    )
    if (-not $script:Doc) { return }
    if (-not $PSCmdlet.ShouldProcess($GuestKey, "Set top-level workload to '$TopLevel'")) { return }
    $g = $script:Doc.guests | Where-Object { $_.guestKey -eq $GuestKey }
    if (-not $g) { return }
    $g.topLevel = $TopLevel
    Write-StatusJson
}

function Set-GuestProvenance {
<#
.SYNOPSIS
    Records the base-image provenance (filename + source URL) on a
    guest's live status entry.
.DESCRIPTION
    The dashboard swaps the guest-card title from "guest.<key>" to the
    actual base-image filename when provenanceFilename is non-empty;
    blank values fall back to the guest key. provenanceUrl is kept in
    the document for operator inspection only (not rendered today).
    Both values are read once per cycle from the Get-Image sidecar and
    flushed to status.json via Write-StatusJson.
.PARAMETER GuestKey
    Guest identifier as it appears in $script:Doc.guests (e.g.
    "guest.ubuntu.server.24"). Silently no-ops when the key isn't found.
.PARAMETER Filename
    Base-image filename to display in the dashboard. Empty clears it.
.PARAMETER Url
    Source URL of the base image. Empty clears it.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [string]$Filename = '',
        [string]$Url      = ''
    )
    if (-not $script:Doc) { return }
    if (-not $PSCmdlet.ShouldProcess($GuestKey, "Set provenance to filename='$Filename' url='$Url'")) { return }
    $g = $script:Doc.guests | Where-Object { $_.guestKey -eq $GuestKey }
    if (-not $g) { return }
    $g.provenanceFilename = $Filename
    $g.provenanceUrl      = $Url
    Write-StatusJson
}

function Get-GuestProvenance {
<#
.SYNOPSIS
    Returns the recorded base-image provenance for a guest as a hashtable.
.DESCRIPTION
    Mirror of Set-GuestProvenance. Returns @{ Filename=''; Url='' } when
    the guest isn't on the document or provenance hasn't been set yet,
    so callers don't have to null-guard.
.PARAMETER GuestKey
    Guest identifier as it appears in $script:Doc.guests.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$GuestKey)
    $empty = @{ Filename = ''; Url = '' }
    if (-not $script:Doc) { return $empty }
    $g = $script:Doc.guests | Where-Object { $_.guestKey -eq $GuestKey }
    if (-not $g) { return $empty }
    return @{
        Filename = [string]$g.provenanceFilename
        Url      = [string]$g.provenanceUrl
    }
}

Export-ModuleMember -Function Reset-StatusDocumentForCycleStart, Initialize-StatusDocument, Set-GuestVMName, Set-GuestStatus, Set-StepStatus, Set-LastFailureSummary, Set-GuestProvenance, Get-GuestProvenance, Set-GuestTopLevel, Set-GuestFailureArtifact, Set-CycleFolderUrl, Get-CycleNumber, Complete-Run, Write-StatusJson, Get-LastGetImageTime, Set-LastGetImageTime
