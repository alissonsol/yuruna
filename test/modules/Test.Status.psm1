<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456702
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
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

<#
.SYNOPSIS
    Returns the current UTC time as an ISO 8601 string with Z suffix.
#>
function Get-UtcTimestamp {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

<#
.SYNOPSIS
    Initializes a fresh status document for a new run and writes status.json.

.DESCRIPTION
    Creates a new status document with the provided parameters. StepNames controls
    which steps are tracked per guest (allows the caller to add Invoke-PoolTest when
    extension scripts are present). Preserves history, cycle count, and lastGetImageAt
    from the previous status file if present. Returns the cycleId string.

.PARAMETER RepoUrl
    Repository URL (typically from test-config.json) used by the status page for
    commit links. If not provided, attempts to read from previous status.json.
#>
function Initialize-StatusDocument {
    param(
        [string]   $StatusFilePath,
        [string]   $HostType,
        [string]   $Hostname,
        [string]   $GitCommit,
        [string]   $RepoUrl    = $null,
        [string[]] $GuestList,
        [string[]] $StepNames = @("New-VM", "Start-VM", "Verify-VM")
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

    $script:Doc = [ordered]@{
        schemaVersion  = 1
        host           = $HostType
        hostname       = $Hostname
        cycleId        = $cycleId
        startedAt      = $cycleId
        finishedAt     = $null
        overallStatus  = "running"
        stepPaused     = $false
        cyclePaused    = $false
        gitCommit      = $GitCommit
        repoUrl        = $repoUrl
        lastGetImageAt = $lastGetImageAt
        cycle          = $cycle + 1
        guests         = @($guests)
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

    # [ordered]@{} preserves insertion order so the JSON-serialized
    # history entry's `guestSummary` keeps the keys in guestOrder.
    # A plain @{} is a [hashtable] whose enumeration is bucketed and
    # arbitrary, which scrambled the pill order in the dashboard's
    # "Recent Cycles" table even though the cycle itself ran in order.
    #
    # Value shape (backward-compatible):
    #   * "pass" / "fail"            - bare string when no debug folder
    #                                  was produced (guest passed, or
    #                                  failed before screenshots were
    #                                  captured). Old history entries
    #                                  written before failureArtifacts
    #                                  existed are also bare strings.
    #   * { status, failureArtifacts } - object when the cycle created
    #                                  a per-guest debug folder. The UI
    #                                  hyperlinks the pill to that URL.
    # The dispatch keeps payload small (most cycles are all-pass) and
    # avoids breaking older dashboards that read .guestSummary[k] as a
    # string.
    $guestSummary = [ordered]@{}
    foreach ($g in $script:Doc.guests) {
        $artifacts = if ($g.Contains('failureArtifacts')) { [string]$g.failureArtifacts } else { '' }
        if ($artifacts) {
            $guestSummary[$g.guestKey] = [ordered]@{
                status           = $g.status
                failureArtifacts = $artifacts
            }
        } else {
            $guestSummary[$g.guestKey] = $g.status
        }
    }

    $entry = [ordered]@{
        cycleId       = $script:Doc.cycleId
        startedAt     = $script:Doc.startedAt
        finishedAt    = $script:Doc.finishedAt
        overallStatus = $OverallStatus
        gitCommit     = $script:Doc.gitCommit
        host          = $script:Doc.host
        hostname      = $script:Doc.hostname
        guestSummary  = $guestSummary
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
    control.cycle-pause in $env:YURUNA_TRACK_DIR. Those files are the
    source of truth for the two UI Pause/Continue buttons: the status
    server creates/removes them and the runner + Invoke-Sequence poll
    them. Mirroring the flags here keeps the parent's periodic status
    writes from clobbering the server-written values.

    Reads the track dir directly from $env:YURUNA_TRACK_DIR rather than
    deriving it from the status.json path (Split-Path -Parent $script:File)
    so every consumer of the pause flags — status server, runner,
    sequence interpreter, this module — uses the same single source of
    truth. An earlier revision derived it from the file path and was
    correct by coincidence; a caller that ever moved status.json outside
    the track dir would have silently desynced.
#>
function Write-StatusJson {
    $trackDir = $env:YURUNA_TRACK_DIR
    $stepPauseFlag  = Join-Path $trackDir 'control.step-pause'
    $cyclePauseFlag = Join-Path $trackDir 'control.cycle-pause'
    $script:Doc.stepPaused  = (Test-Path $stepPauseFlag)
    $script:Doc.cyclePaused = (Test-Path $cyclePauseFlag)
    $tmp = "$($script:File).tmp"
    $script:Doc | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Path $tmp -Destination $script:File -Force
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
    } catch { return $null }
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
    The UI swaps the guest-card title from "guest.ubuntu.desktop" to the
    actual ISO filename (e.g. "ubuntu-24.04.4-desktop-amd64.iso") when
    provenanceFilename is populated; a blank value means fall back to
    guestKey. provenanceUrl is informational (not rendered today; kept in
    the document so operators inspecting track/status.json can see where
    the ISO came from without cross-referencing host/*/*.txt sidecars).
#>
function Set-GuestFailureArtifacts {
<#
.SYNOPSIS
Records the relative URL of the per-guest debug folder produced by a
failed cycle, so the dashboard can link the guest pill straight to it.
.DESCRIPTION
Called by Copy-FailureArtifactsToStatusLog right after a debug folder
is created on disk. $RelativeUrl is the URL the dashboard (served from
test/status/) uses to navigate — typically "log/<logId>.<ts>.failure-
screens-<vmname>/". Empty string clears the field. Persisted on both
the live guests[] entry (so a long-running cycle reflects the path
mid-run) and copied into history.guestSummary by Complete-Run.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns', '',
        Justification = 'Noun mirrors the JSON field name (failureArtifacts) and the artifact set is genuinely plural — frames plus OCR sidecars.')]
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

function Set-GuestProvenance {
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

Export-ModuleMember -Function Initialize-StatusDocument, Set-GuestVMName, Set-GuestStatus, Set-StepStatus, Set-GuestProvenance, Set-GuestFailureArtifacts, Complete-Run, Write-StatusJson, Get-LastGetImageTime, Set-LastGetImageTime
