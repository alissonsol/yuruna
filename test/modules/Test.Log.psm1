<#PSScriptInfo
.VERSION 2026.07.03
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456790
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

# One of THREE Yuruna logger modules with disjoint responsibilities --
# see test/modules/README.md "Three loggers, three jobs" before adding
# helpers here. This module owns ONLY the cycle-filesystem layout:
# Start-LogFile, Stop-LogFile, Get-CycleGuestDataFolder, Get-CycleScreenDir,
# Write-CycleNdjsonEvent, Write-CycleManifest. Sibling modules: Yuruna.Log
# (stream interceptor) and Test.Output (per-script PASS/FAIL tally).
# Don't add Write-* cmdlet wrappers or PASS-counting helpers here -- they
# belong in the other two.
#
# Two cross-module channels are intentionally process-wide: __YurunaLogFile
# (set here, read by the Yuruna.Log proxy) and __YurunaCycleFolder (the
# cycle's folder under test/status/log/, read by failure / diagnostics
# helpers so the path doesn't have to thread through every call site).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'global:__YurunaLogFile is the cross-module log-file handle read by Yuruna.Log.psm1; global:__YurunaCycleFolder is the cycle folder path read by failure / diagnostics handlers; global:__YurunaCycleId is the stable per-cycle correlation key stamped on every NDJSON event by Write-CycleNdjsonEvent; global:__YurunaRunId is the per-runner-process GUID stamped on every NDJSON event so a multi-host pool consumer can join (runId, cycleId) to identify a specific cycle on a specific host. All four are intentionally process-wide.')]
param()

# Per-runner-process correlation ID. Generated once at module load and
# reused for the life of the process; a -Force re-import preserves the
# existing GUID so a mid-run `git pull` reload doesn't split one cycle's
# stream across two runIds. New outer / inner / Test-Sequence processes
# get their own GUIDs because each starts with a fresh global scope.
if (-not (Get-Variable -Name '__YurunaRunId' -Scope Global -ErrorAction SilentlyContinue) -or
    -not $global:__YurunaRunId) {
    $global:__YurunaRunId = [Guid]::NewGuid().ToString()
}

# === Cycle-log rotation policy ============================================
# Bound the per-host log directory so a long-running runner doesn't fill
# disk with thousands of cycle folders. Top-level cap is CYCLE_HISTORY_LIMIT
# (1000); once the count reaches that threshold, the oldest folders are
# moved into a history.YYYY-MM-DD/ subdirectory, keeping the most recent
# CYCLE_HISTORY_KEEP (30) at the top level for quick triage. Both values
# are code constants by design -- NOT in test.config.yml -- so an operator
# can grep + tune without a schema migration. Mirrors the
# FailurePauseMaxSeconds policy in Invoke-TestRunner.ps1: tunables that
# only matter on the failure / boundary paths are kept close to the code
# that enforces them.
$script:CycleHistoryLimit = 1000
$script:CycleHistoryKeep  = 30

function Get-CycleFolderIdentity {
    <#
    .SYNOPSIS
        Strip the lifecycle suffix from a cycle folder leaf name so the
        return value is the cycle's stable IDENTITY rather than its
        on-disk location.
    .DESCRIPTION
        A cycle folder moves through three on-disk names:

          `<base>.incomplete`        in progress (set by Start-LogFile)
          `<base>`                   clean close (set by Stop-LogFile rename)
          `<base>.aborted.<UTC>`     boot-detected crash (set by boot-recovery sweep)

        Every NDJSON event records `cycleFolder` as the bare `<base>` --
        the cycle's identity, not its transient location -- so a
        streaming consumer joins events across the rename boundary
        without seeing the suffix flip mid-cycle. Callers that need to
        FIND the on-disk artifacts try `<base>` first, then
        `<base>.incomplete`, then `<base>.aborted.*`.
    .PARAMETER Path
        Either an absolute folder path or a bare leaf name; both work.
    .OUTPUTS
        [string] The base identity (no suffix).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $leaf = Split-Path -Leaf $Path
    return ($leaf -replace '\.incomplete$', '' -replace '\.aborted\.[^/\\]+$', '')
}

function Format-CycleFolderBaseName {
<#
.SYNOPSIS
    Builds the cycleFolder base name: "000001.YYYY-MM-DD.HH-mm-ss.HOSTID".
.DESCRIPTION
    Single source of truth for the format so Start-LogFile, the per-guest
    folder helper, and the dashboard JS all produce identical strings.
    The 4th segment is the stable per-host hostId (runtime/host.uuid), NOT
    the hostname: the cycleFolder name surfaces in the pool aggregator's
    cycleFolderUrl (the dashboard deep-link + /api/v1/pool-status), which
    must stay hostname-free so the unauthenticated pool view discloses no
    hostnames. CycleNumber is zero-padded to 6 digits per spec; CycleId is
    parsed as an ISO-8601 UTC timestamp and split into date + time-with-
    dashes (colons can't appear in filenames on Windows/macOS volumes).
#>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [int]$CycleNumber,
        [Parameter(Mandatory)] [string]$CycleId,
        # Optional: empty/missing yields the 'unknown-host' placeholder
        # below. A Mandatory string param would REJECT an empty string,
        # which a one-shot caller with no host identity legitimately
        # produces -- and would throw mid-cycle in Start-LogFile.
        [string]$HostId = ''
    )
    $padded = '{0:D6}' -f $CycleNumber
    # CycleId is "2026-05-11T16:24:39Z" -- index 0..9 is the date,
    # index 11..18 is HH:mm:ss. Defensive .Length checks so a caller
    # passing a non-ISO timestamp (Test-Sequence.ps1 one-shots) still
    # yields a usable folder name with whatever the substring produces.
    $cycleDate = if ($CycleId.Length -ge 10) { $CycleId.Substring(0,10) } else { 'unknown-date' }
    $cycleTime = if ($CycleId.Length -ge 19) { ($CycleId.Substring(11,8) -replace ':','-') } else { 'unknown-time' }
    # 4th segment: the opaque hostId (keeps the name hostname-free). The
    # 'unknown-host' placeholder only applies to a one-shot caller with no
    # host identity established; it preserves the 4-segment shape that the
    # rotation/recovery patterns (^\d{6}\..+\..+\..+) require.
    $hostSeg = if ([string]::IsNullOrWhiteSpace($HostId)) { 'unknown-host' } else { $HostId }
    return "$padded.$cycleDate.$cycleTime.$hostSeg"
}

function Get-LogDir {
    <#
    .SYNOPSIS
        Returns the test/status/log directory path, creating it if needed.
    #>
    param([string]$TestRoot)
    $logDir = Join-Path -Path $TestRoot -ChildPath "status" -AdditionalChildPath "log"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    return $logDir
}

function Invoke-CycleLogRotation {
    <#
    .SYNOPSIS
        Rotate old cycle folders into a dated history.YYYY-MM-DD bucket
        once the top-level count reaches CYCLE_HISTORY_LIMIT.
    .DESCRIPTION
        Idempotent: below the cap, the function returns 0 after a single
        directory listing. At or above the cap, sorts cycle folders by
        name descending (lexicographic order matches cycle-number order
        because of the 6-digit prefix), keeps the most recent
        CYCLE_HISTORY_KEEP at the top level, and moves the remainder
        into history.YYYY-MM-DD/. If that history folder already exists
        from a prior rotation on the same date, the older cycles are
        merged in via per-folder Move-Item.

        Cycle-folder names match `^\d{6}\..+\..+\..+` (cycle-number,
        date, time, host). Operator-created folders or pre-existing
        history.* buckets are skipped by the filter so a manual
        bookkeeping folder isn't swept into a rotation bucket.
    .OUTPUTS
        [int] number of cycle folders moved (0 when no rotation fired).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$LogDir
    )
    if (-not (Test-Path -LiteralPath $LogDir)) { return 0 }
    $cycleFolders = @(Get-ChildItem -LiteralPath $LogDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{6}\..+\..+\..+' } |
        Sort-Object Name -Descending)
    if ($cycleFolders.Count -lt $script:CycleHistoryLimit) { return 0 }
    $keep    = @($cycleFolders | Select-Object -First $script:CycleHistoryKeep)
    $moveSet = @($cycleFolders | Select-Object -Skip $script:CycleHistoryKeep)
    if ($moveSet.Count -eq 0) { return 0 }
    $today      = (Get-Date).ToString('yyyy-MM-dd')
    $historyDir = Join-Path $LogDir "history.$today"
    if (-not $PSCmdlet.ShouldProcess($historyDir, "Rotate $($moveSet.Count) cycle folders")) { return 0 }
    if (-not (Test-Path -LiteralPath $historyDir)) {
        try {
            New-Item -ItemType Directory -Path $historyDir -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Warning "Invoke-CycleLogRotation: could not create $historyDir; aborting rotation. $($_.Exception.Message)"
            return 0
        }
    }
    $moved = 0
    foreach ($folder in $moveSet) {
        $dest = Join-Path $historyDir $folder.Name
        try {
            Move-Item -LiteralPath $folder.FullName -Destination $dest -Force -ErrorAction Stop
            $moved++
        } catch {
            Write-Warning "Invoke-CycleLogRotation: could not move $($folder.Name) into $historyDir ($($_.Exception.Message)); continuing."
        }
    }
    Send-CycleEventSafely -EventRecord @{
        timestamp     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        event         = 'cycle_log_rotated'
        historyFolder = "history.$today"
        moved         = [int]$moved
        kept          = [int]$keep.Count
        limit         = $script:CycleHistoryLimit
        keepCount     = $script:CycleHistoryKeep
    }
    # Write-Information (not Write-Output) so the caller's `$n = Invoke-
    # CycleLogRotation ...` receives only the [int] return value; pipeline
    # pollution would otherwise turn the assignment into an array.
    Write-Information "Cycle-log rotation: moved $moved folder(s) into $historyDir (kept $($keep.Count) at top level)." -InformationAction Continue
    return $moved
}

function Start-LogFile {
    <#
    .SYNOPSIS
        Creates this cycle's folder and starts logging Write-* output
        to the HTML file inside it.
    .DESCRIPTION
        Folder layout:
            test/status/log/000001.YYYY-MM-DD.HH-mm-ss.HOSTNAME/
                000001.YYYY-MM-DD.HH-mm-ss.HOSTNAME.html
                <vmName>/        <- created lazily by per-guest helper
                    <date>-<time>.system.diagnostic.<id>.txt
                    raw_*.png/raw_*.txt    (on failure)
                    failure_screenshot.png (on failure)
                    failure_ocr.txt        (on failure)
        Sets:
          $global:__YurunaLogFile      absolute path of the HTML file
          $global:__YurunaCycleFolder absolute path of the cycle folder
        so the Yuruna.Log proxy module appends to the right file and
        downstream helpers (Copy-FailureArtifactsToStatusLog,
        saveSystemDiagnostic action) can locate per-guest subfolders
        without having to plumb the path through every call site.
    .OUTPUTS
        The absolute path to the HTML log file (existing callers store
        it as $LogFile and pass it around).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$TestRoot,
        [Parameter(Mandatory)] [string]$CycleId,
        [Parameter(Mandatory)] [string]$Hostname,
        # Monotonic cycle counter (1, 2, 3, ...). Defaults to 0 for
        # callers without cycle context (Test-Sequence.ps1); the
        # resulting folder is 000000.YYYY-MM-DD.HH-mm-ss.HOSTID which
        # is still unique-per-invocation thanks to the timestamp.
        [int]$CycleNumber = 0
    )
    $logDir = Get-LogDir -TestRoot $TestRoot
    # Cap the top-level cycle folder count before allocating a new one.
    # The function is a fast no-op below CYCLE_HISTORY_LIMIT, so the cost
    # is one Get-ChildItem per cycle even on a brand-new install.
    try {
        Invoke-CycleLogRotation -LogDir $logDir -Confirm:$false | Out-Null
    } catch {
        Write-Warning "Cycle-log rotation failed (non-fatal; cycle continues): $($_.Exception.Message)"
    }
    # The cycleFolder name carries the opaque hostId (hostname-free; see
    # Format-CycleFolderBaseName), resolved from the runner-set global with a
    # fresh-read fallback so one-shot drivers still produce a usable name.
    $folderHostId = if ($global:__YurunaHostId) {
        [string]$global:__YurunaHostId
    } elseif (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue) {
        [string](Get-YurunaHostId)
    } else { '' }
    $cycleBase = Format-CycleFolderBaseName -CycleNumber $CycleNumber -CycleId $CycleId -HostId $folderHostId
    # Allocate the cycle folder with a `.incomplete` suffix so a
    # crashed cycle is visible at the folder-name level (in addition to
    # the in-folder marker file). Stop-LogFile renames to the bare
    # <base>/ on clean close; boot recovery renames to
    # <base>.aborted.<UTC>/ when it sees the crash on startup. Every
    # NDJSON event records the bare <base> as `cycleFolder` (the
    # cycle's stable identity) regardless of which suffix is on disk
    # at emit time -- consumers join events across the rename boundary
    # without seeing the suffix flip mid-cycle.
    $cycleFolder = Join-Path $logDir "$cycleBase.incomplete"
    $logFile = Join-Path $cycleFolder "$cycleBase.html"
    if ($PSCmdlet.ShouldProcess($logFile, 'Start log file')) {
        if (-not (Test-Path $cycleFolder)) {
            New-Item -ItemType Directory -Path $cycleFolder -Force | Out-Null
        }
        # Cycle-folder lifecycle marker. A `.incomplete` sidecar file
        # inside the cycle folder carries the cycleId / pid / startedAtUtc
        # for the boot-recovery sweep. Layers with the folder-name
        # suffix: the folder name signals "in progress / clean close /
        # aborted" at a glance; the marker file carries the forensic
        # detail (which pid, which cycleId).
        $incompleteMarker = Join-Path $cycleFolder '.incomplete'
        $markerPayload = [ordered]@{
            cycleId      = [string]$CycleId
            cycleNumber  = [int]$CycleNumber
            cycleFolder  = $cycleBase
            startedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            pid          = $PID
            hostname     = [string]$Hostname
        }
        # Atomic write via the shared state-file helper. Best-effort
        # by design: if the marker can't land, the cycle still
        # proceeds -- worst case the boot-recovery sweep won't see
        # this cycle as crashed, which is the safe direction (a
        # cleanly-finished cycle that lost its marker write looks
        # the same as one that never started).
        if (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue) {
            $null = Write-YurunaStateFileJson -Path $incompleteMarker -InputObject $markerPayload -Confirm:$false
        } else {
            try {
                $markerJson = $markerPayload | ConvertTo-Json -Compress
                [System.IO.File]::WriteAllText($incompleteMarker, $markerJson, [System.Text.UTF8Encoding]::new($false))
            } catch {
                Write-Verbose "Could not write $incompleteMarker (non-fatal): $($_.Exception.Message)"
            }
        }
        # HTML preamble with cache-control meta tags so the log expires in
        # the browser after 30s and a hard reload always fetches fresh
        # content. Status server already sends
        # `Cache-Control: no-store, no-cache, must-revalidate` as HTTP
        # headers, but browsers still serve stale pages from bfcache
        # (back/forward navigation) and some proxies ignore response
        # headers. Meta tags are advisory but bake the directive into the
        # file itself so it survives download / mirroring / direct
        # file:// opens as well.
        $preamble = @'
<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta http-equiv="Cache-Control" content="max-age=30, must-revalidate">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="0">
<title>Yuruna test-runner log</title>
</head><body><pre>
'@
        $preamble | Microsoft.PowerShell.Utility\Out-File -FilePath $logFile -Encoding utf8 -ErrorAction SilentlyContinue
        $global:__YurunaLogFile = $logFile
        $global:__YurunaCycleFolder = $cycleFolder
        # Stable run-correlator stamped on every NDJSON record by Write-
        # CycleNdjsonEvent. cycleFolder alone IS unique on a single host,
        # but a multi-host pool consumer joining live streams off three
        # boxes would otherwise have to parse the leaf name to recover
        # the originating cycle time. cycleId is the ISO timestamp the
        # outer assigned at cycle start, so two events with the same
        # cycleId are guaranteed to belong to the same cycle even when
        # the cycleFolder leaf names diverge across hosts.
        $global:__YurunaCycleId = [string]$CycleId
        # Fallback: import the proxy module if not already loaded
        if (-not (Get-Module Yuruna.Log)) {
            $repoRoot = Split-Path -Parent (Split-Path -Parent $TestRoot)
            $logModule = Join-Path -Path $repoRoot -ChildPath "automation" -AdditionalChildPath "Yuruna.Log.psm1"
            if (Test-Path $logModule) {
                Import-Module $logModule -Global -Force -Verbose:$false
            }
        }
        # Emit the cycle-boundary opening event. Pairs with the cycle_end
        # emitted by Stop-LogFile. A streaming remediator can now index
        # cycles by these two events without directory-walking the
        # status/log/ tree: every cycle has exactly one cycle_start
        # whose `cycleFolder` resolves the on-disk artifacts and exactly
        # one cycle_end whose `outcome` tells it pass/fail/aborted.
        Write-CycleNdjsonEvent -EventRecord @{
            timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            event        = 'cycle_start'
            cycleId      = [string]$CycleId
            cycleNumber  = [int]$CycleNumber
            cycleFolder  = $cycleBase
            hostname     = [string]$Hostname
        }
        # Persist the cycle folder URL on the status doc so the dashboard
        # can build per-guest tile links without re-deriving the format.
        # During the cycle the on-disk folder is <base>.incomplete/; the
        # status server's directory listing serves it under that path,
        # so the URL has to include the suffix. Stop-LogFile updates
        # the URL to the bare <base>/ after the clean-close rename.
        if (Get-Command Set-CycleFolderUrl -ErrorAction SilentlyContinue) {
            Set-CycleFolderUrl -RelativeUrl "log/$cycleBase.incomplete/"
        }
    }
    return $logFile
}

function Get-CycleGuestDataFolder {
    <#
    .SYNOPSIS
        Returns the absolute path of the per-guest data folder
        ("cycleGuestDataFolder") under the current cycleFolder, creating
        it on demand.
    .DESCRIPTION
        Layout: {cycleFolder}/{VMName}/. Every file produced for a guest
        within this cycle -- failure screenshots, OCR text, system
        diagnostics, etc. -- is written under this folder so the
        dashboard tile that links here surfaces them all in one place.
        Returns $null when called before Start-LogFile (no cycle folder
        established), so callers can no-op without crashing the cycle.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$VMName
    )
    if (-not $global:__YurunaCycleFolder) { return $null }
    $folder = Join-Path $global:__YurunaCycleFolder $VMName
    if ($PSCmdlet.ShouldProcess($folder, 'Ensure cycleGuestDataFolder exists')) {
        if (-not (Test-Path $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
    }
    return $folder
}

function Get-CycleScreenDir {
    <#
    .SYNOPSIS
        Returns the absolute path of the per-VM Wait-ForText ring-buffer
        directory ({cycleFolder}/screens_{VMName}/), creating it on demand.
    .DESCRIPTION
        Wait-ForText captures every pre-OCR screenshot + its OCR sidecar
        into this directory so the failure path can surface the run-up
        to the bug. Nested INSIDE the cycle folder (not at the
        YURUNA_LOG_DIR root) so a cycle that hangs / restarts with no
        failure-path firing still leaves its evidence behind under the
        cycle that produced it -- the next cycle gets its own folder
        and can't overwrite earlier captures.
        Falls back to {YURUNA_LOG_DIR}/screens_{VMName}/ when no cycle
        folder is established (Test-Sequence.ps1 normally calls
        Start-LogFile, but defensive in case future drivers don't).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'global:__YurunaCycleFolder is the cross-module cycle folder handle set by Start-LogFile.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$VMName
    )
    if ($global:__YurunaCycleFolder) {
        $folder = Join-Path $global:__YurunaCycleFolder "screens_${VMName}"
    } else {
        if (-not $env:YURUNA_LOG_DIR) {
            Import-Module (Join-Path $PSScriptRoot 'Test.YurunaDir.psm1') -Force -ErrorAction SilentlyContinue
            if (Get-Command Initialize-YurunaLogDir -ErrorAction SilentlyContinue) {
                Initialize-YurunaLogDir | Out-Null
            }
        }
        $folder = Join-Path $env:YURUNA_LOG_DIR "screens_${VMName}"
    }
    if ($PSCmdlet.ShouldProcess($folder, 'Ensure cycle screen dir exists')) {
        if (-not (Test-Path $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
    }
    return $folder
}

function Write-CycleManifest {
    <#
    .SYNOPSIS
        Write <cycleFolder>/manifest.json enumerating every artifact in
        the cycle folder.
    .DESCRIPTION
        One well-known entry point for downstream consumers (autonomous
        remediator, dashboard, CI) so they don't have to directory-walk
        and guess file roles. Each entry carries:
            path        relative to cycleFolder, forward-slash normalized
            kind        coarse classification (transcript, ndjson, screenshot,
                        ocr, diagnostic, manifest, failure, perf, other)
            sizeBytes   file size
            sha256      hex sha256 (best-effort, $null on read failure)
            modifiedUtc ISO-8601 UTC mtime
        Best-effort: a per-file read failure logs Verbose and emits the
        entry with sha256=$null; a manifest write failure logs Verbose
        and returns -- the cycle never fails because the manifest write
        failed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads the cycle-folder anchor set by Start-LogFile in the same module.')]
    param([string]$CycleFolder)
    if (-not $CycleFolder) { $CycleFolder = $global:__YurunaCycleFolder }
    if (-not $CycleFolder -or -not (Test-Path -LiteralPath $CycleFolder -PathType Container)) { return }
    if (-not $PSCmdlet.ShouldProcess($CycleFolder, 'Write cycle manifest.json')) { return }
    try {
        $entries = New-Object System.Collections.Generic.List[hashtable]
        $items = Get-ChildItem -LiteralPath $CycleFolder -Recurse -File -Force -ErrorAction SilentlyContinue
        foreach ($f in $items) {
            $rel = $f.FullName.Substring($CycleFolder.Length).TrimStart('\','/') -replace '\\','/'
            if ($rel -eq 'manifest.json') { continue }
            $kind = switch -Wildcard ($rel) {
                '*.html'                 { 'transcript'; break }
                'cycle.events.ndjson'    { 'ndjson'; break }
                'cycle.events.gaps'      { 'ndjson-gaps'; break }
                'last_failure.json'      { 'failure'; break }
                'last_remediation.json'  { 'remediation'; break }
                'failure_screenshot*.png'{ 'screenshot-failure'; break }
                'failure_ocr*.txt'       { 'ocr-failure'; break }
                'host.diagnostic.txt'    { 'diagnostic-host'; break }
                '*.system.diagnostic.*'  { 'diagnostic-guest'; break }
                'screens_*/*.png'        { 'screenshot'; break }
                'screens_*/*.txt'        { 'ocr'; break }
                'raw_*.png'              { 'screenshot-raw'; break }
                'raw_*.txt'              { 'ocr-raw'; break }
                'last-fetch-and-execute.log' { 'fetch-and-execute-log'; break }
                'perf*.tsv'              { 'perf'; break }
                'notification.delivery*' { 'notification-delivery'; break }
                default                  { 'other' }
            }
            # Skip SHA-256 for bulky-but-ephemeral artifacts (the ring-buffer
            # poll captures + their OCR sidecars). Cycle-end SHA-256 over
            # hundreds of raw_*.png frames was 0.2-2 s with no operator
            # value: nobody hashes them later. Path + size + mtime in the
            # manifest is enough for downstream consumers to locate them;
            # an integrity check on a specific frame is a one-off operator
            # action that can compute the hash on demand.
            $sha = $null
            if ($kind -notin @('screenshot', 'screenshot-raw', 'ocr', 'ocr-raw')) {
                try {
                    $h = Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop
                    if ($h) { $sha = [string]$h.Hash }
                } catch {
                    Write-Verbose "Write-CycleManifest: sha256 failed for $($f.FullName): $($_.Exception.Message)"
                }
            }
            $entries.Add(@{
                path        = $rel
                kind        = $kind
                sizeBytes   = [long]$f.Length
                sha256      = $sha
                modifiedUtc = $f.LastWriteTimeUtc.ToString('o')
            }) | Out-Null
        }
        $payload = [ordered]@{
            schemaVersion = 1
            cycleFolder   = Get-CycleFolderIdentity -Path $CycleFolder
            writtenAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
            artifactCount = $entries.Count
            artifacts     = @($entries | Sort-Object -Property @{Expression = { $_.path }})
        }
        $json = $payload | ConvertTo-Json -Depth 5
        $manifestPath = Join-Path $CycleFolder 'manifest.json'
        Set-Content -LiteralPath $manifestPath -Value $json -Encoding utf8NoBOM -ErrorAction Stop
    } catch {
        Write-Verbose "Write-CycleManifest: $($_.Exception.Message)"
    }
}

function Stop-LogFile {
    <#
    .SYNOPSIS
        Stops file logging by clearing the log file path.
    .DESCRIPTION
        Clears $global:__YurunaLogFile so the Yuruna.Log proxy stops
        appending to the log file. The proxy module remains loaded so
        it can be reactivated by the next Start-LogFile call.

        Emits a `cycle_end` NDJSON event (pair to `cycle_start` from
        Start-LogFile) carrying the cycle outcome. Streaming consumers
        index cycle history off the cycle_start/cycle_end pair without
        directory-walking. Outcome defaults to 'unknown' so legacy
        callers that don't pass it still emit a parseable event.

        Then writes <cycleFolder>/manifest.json so downstream consumers
        (autonomous remediator, dashboard, CI) have one well-known
        entry point listing every artifact in the cycle folder with
        kind + sha256 + size + mtime. The manifest is written AFTER
        cycle_end so its sweep of the cycle folder picks up the
        completed cycle.events.ndjson tail.
    .PARAMETER Outcome
        Cycle disposition: 'pass' / 'fail' / 'aborted' / 'unknown'.
        Caller supplies what it knows; 'unknown' is the safe default
        for early-exit paths that lack cycle context.
    .PARAMETER Reason
        Short free-text reason for the outcome. Carried verbatim in
        the cycle_end event; useful when 'fail' but the failing-step
        record is in a different artifact, or when 'aborted' to name
        the trigger (cycle-restart marker, ctrl+C, watchdog).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('pass','fail','aborted','unknown')][string]$Outcome = 'unknown',
        [string]$Reason = ''
    )
    if ($PSCmdlet.ShouldProcess('log file', 'Stop logging')) {
        if ($global:__YurunaCycleFolder) {
            # cycle_end emitted BEFORE the manifest so the manifest's
            # artifact scan picks up the now-completed
            # cycle.events.ndjson. NDJSON write is best-effort; the
            # gap-sentinel inside Write-CycleNdjsonEvent surfaces
            # any failure.
            Write-CycleNdjsonEvent -EventRecord @{
                timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                event     = 'cycle_end'
                outcome   = [string]$Outcome
                reason    = [string]$Reason
            }
        }
        if ($global:__YurunaLogFile) {
            "</pre></body></html>" | Microsoft.PowerShell.Utility\Out-File -FilePath $global:__YurunaLogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue
        }
        if ($global:__YurunaCycleFolder) {
            # Archive the cycle's last_failure.json (when any) into the cycle
            # folder BEFORE the manifest sweep, so the full schema-v2 record --
            # matched pattern, label, OCR tail, repro, inner cause -- persists
            # with the cycle for post-hoc analysis, not just the flattened
            # step_failure event in cycle.events.ndjson. The engine/infra paths
            # write it to $env:YURUNA_LOG_DIR (the log root, shared across
            # cycles); Write-CycleManifest already classifies last_failure.json
            # as kind 'failure', so the copied file is catalogued automatically.
            # Only on a non-pass outcome: a passing cycle has no failure of its
            # own, so any last_failure.json present is stale from an earlier cycle.
            if ($Outcome -ne 'pass' -and $env:YURUNA_LOG_DIR) {
                $srcFailure = Join-Path $env:YURUNA_LOG_DIR 'last_failure.json'
                if (Test-Path -LiteralPath $srcFailure) {
                    $dstFailure = Join-Path $global:__YurunaCycleFolder 'last_failure.json'
                    try { Copy-Item -LiteralPath $srcFailure -Destination $dstFailure -Force -ErrorAction Stop }
                    catch { Write-Verbose "Stop-LogFile: could not archive last_failure.json: $($_.Exception.Message)" }
                }
                # The remediation dispatcher's decision (Invoke-Remediation) rides
                # the same archive path as the failure it routed on, so the cycle
                # folder -- and the pool copy of it -- carries the recommendation
                # next to the failure. Only on a non-pass outcome: a passing cycle
                # has no remediation of its own, so any file present is stale.
                $srcRemediation = Join-Path $env:YURUNA_LOG_DIR 'last_remediation.json'
                if (Test-Path -LiteralPath $srcRemediation) {
                    $dstRemediation = Join-Path $global:__YurunaCycleFolder 'last_remediation.json'
                    try { Copy-Item -LiteralPath $srcRemediation -Destination $dstRemediation -Force -ErrorAction Stop }
                    catch { Write-Verbose "Stop-LogFile: could not archive last_remediation.json: $($_.Exception.Message)" }
                }
            }
            Write-CycleManifest -CycleFolder $global:__YurunaCycleFolder -Confirm:$false
            # Drop the `.incomplete` marker last, after cycle_end + manifest
            # have landed. Order matters: a crash AFTER manifest but BEFORE
            # this Remove-Item leaves the marker, which downstream consumers
            # correctly interpret as "ended in an ambiguous state" -- safer
            # than racing the marker delete with the manifest write.
            $incompleteMarker = Join-Path $global:__YurunaCycleFolder '.incomplete'
            if (Test-Path -LiteralPath $incompleteMarker) {
                Remove-Item -LiteralPath $incompleteMarker -Force -ErrorAction SilentlyContinue
            }
            # Rename <base>.incomplete/ -> <base>/ so the folder name
            # itself reflects the clean-close state. Best-effort:
            # rename failure leaves the folder as .incomplete/, and
            # the boot sweep on the next outer startup detects the
            # crash signature (.incomplete suffix with no marker
            # inside means "Stop-LogFile got past the marker delete
            # but failed the rename" -- still treated as recoverable).
            $inProgress = [string]$global:__YurunaCycleFolder
            if ($inProgress -match '\.incomplete$') {
                $final = $inProgress -replace '\.incomplete$', ''
                if (Test-Path -LiteralPath $final) {
                    Write-Warning "Stop-LogFile: cannot rename '$inProgress' to '$final' -- destination already exists; leaving cycle folder with .incomplete suffix."
                } else {
                    try {
                        Move-Item -LiteralPath $inProgress -Destination $final -Force -ErrorAction Stop
                        # Update cycleFolderUrl now that the on-disk
                        # name has changed. Soft import + soft call:
                        # Test.Status not loaded in every caller (Test-
                        # Sequence.ps1 drives Stop-LogFile too).
                        if (Get-Command Set-CycleFolderUrl -ErrorAction SilentlyContinue) {
                            $finalLeaf = Split-Path -Leaf $final
                            Set-CycleFolderUrl -RelativeUrl "log/$finalLeaf/" -ErrorAction SilentlyContinue
                        }
                    } catch {
                        Write-Warning "Stop-LogFile: rename of '$inProgress' to '$final' failed: $($_.Exception.Message). Folder stays with .incomplete suffix; boot recovery will handle it."
                    }
                }
            }
        }
        $global:__YurunaLogFile = $null
        $global:__YurunaCycleFolder = $null
        $global:__YurunaCycleId = $null
    }
}

function Write-CycleNdjsonEvent {
    <#
    .SYNOPSIS
        Append one JSON-Lines record to the per-cycle event log.
    .DESCRIPTION
        File path: <cycleFolder>/cycle.events.ndjson where cycleFolder
        is $global:__YurunaCycleFolder (set by Start-LogFile) or
        $env:YURUNA_LOG_DIR as the fallback. One JSON line per event,
        UTF-8 no-BOM.

        Best-effort: an open-file race or disk-full condition is
        swallowed at Verbose level -- the cycle never fails because
        the NDJSON write failed. The dropped event count is surfaced
        via a sibling `cycle.events.gaps` file (one line per failed
        write, JSON Lines) so an autonomous remediator sees that the
        stream is incomplete instead of silently consuming truncated
        truth.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Append-only telemetry; failure is silent (Write-Verbose only); no destructive operation.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads the cycle-folder anchor set by Start-LogFile in the same module.')]
    param([Parameter(Mandatory)][hashtable]$EventRecord)
    $cycleFolder = $global:__YurunaCycleFolder
    if (-not $cycleFolder -and $env:YURUNA_LOG_DIR) { $cycleFolder = $env:YURUNA_LOG_DIR }
    if (-not $cycleFolder) { return }
    $path = Join-Path $cycleFolder 'cycle.events.ndjson'
    # Stamp cycleFolder + cycleId on every record so off-host consumers
    # can join events back to their cycle without reparsing the file
    # path or the leaf-name format. Existing values from the caller win
    # (cycle_start in particular already carries both); only set when
    # missing. cycleId is the multi-host correlation key -- two events
    # with the same cycleId belong to the same cycle even when emitted
    # by sibling runners on different hosts.
    #
    # Stamp cycleFolder as the cycle's stable IDENTITY, not the
    # on-disk leaf -- the on-disk folder transitions
    # <base>.incomplete/ -> <base>/ -> <base>.aborted.<UTC>/, and the
    # NDJSON stream must NOT flip the cycleFolder field across those
    # renames or a streaming consumer's join would break. Get-Cycle-
    # FolderIdentity strips any of the three suffixes.
    if (-not $EventRecord.Contains('cycleFolder')) {
        $EventRecord['cycleFolder'] = Get-CycleFolderIdentity -Path $cycleFolder
    }
    if (-not $EventRecord.Contains('cycleId') -and $global:__YurunaCycleId) {
        $EventRecord['cycleId'] = [string]$global:__YurunaCycleId
    }
    # runId stamps the per-runner-process GUID. With (runId, cycleId)
    # a multi-host pool consumer joins events back to a specific cycle
    # on a specific host without parsing folder leaf names or relying
    # on hostname collisions across the pool.
    if (-not $EventRecord.Contains('runId') -and $global:__YurunaRunId) {
        $EventRecord['runId'] = [string]$global:__YurunaRunId
    }
    # hostId stamps the STABLE per-host identity (persisted in runtime/host.uuid;
    # distinct from hostname, which can collide/rename across a pool). With
    # (hostId, runId, cycleId) a pool consumer joins events to a cycle on a
    # specific host without trusting hostname uniqueness. Set on $global at the
    # process entry point (Get-YurunaHostId), so this mirrors the runId stamp:
    # conditional, and a no-op when unset (standalone Test-Sequence, tests).
    if (-not $EventRecord.Contains('hostId') -and $global:__YurunaHostId) {
        $EventRecord['hostId'] = [string]$global:__YurunaHostId
    }
    try {
        $json = $EventRecord | ConvertTo-Json -Compress -Depth 5
        Add-Content -LiteralPath $path -Value $json -Encoding utf8NoBOM -ErrorAction Stop
    } catch {
        $errMsg = $_.Exception.Message
        Write-Verbose "Write-CycleNdjsonEvent: $errMsg"
        # Sentinel: surface the dropped event so a remediator polling
        # cycle.events.ndjson knows the stream has gaps. Best-effort
        # (a disk-full state will also defeat this) -- but on the
        # common open-handle / encoding-race case the sentinel lands.
        try {
            $gapsPath = Join-Path $cycleFolder 'cycle.events.gaps'
            $gapEvent = [ordered]@{
                timestamp      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                event          = 'ndjson_write_gap'
                cycleFolder    = Get-CycleFolderIdentity -Path $cycleFolder
                droppedEvent   = if ($EventRecord.Contains('event')) { [string]$EventRecord['event'] } else { '(unknown)' }
                droppedAction  = if ($EventRecord.Contains('actionVerb')) { [string]$EventRecord['actionVerb'] } else { $null }
                ndjsonPath     = $path
                writeError     = $errMsg
            } | ConvertTo-Json -Compress -Depth 3
            Add-Content -LiteralPath $gapsPath -Value $gapEvent -Encoding utf8NoBOM -ErrorAction Stop
        } catch {
            Write-Verbose "Write-CycleNdjsonEvent gap sentinel write also failed: $($_.Exception.Message)"
        }
    }
}

function Send-CycleEventSafely {
    <#
    .SYNOPSIS
        Centralised guard for cycle.events.ndjson emission. Validates
        the record against the cycle-event schema, surfaces violations
        as a sibling `schema_violation` event, and writes both.
    .DESCRIPTION
        Consolidates the 4-line emit pattern
            if (Get-Command Write-CycleNdjsonEvent -ErrorAction SilentlyContinue) {
                try { Write-CycleNdjsonEvent -EventRecord @{...} } catch { $null = $_ }
            }
        used by Invoke-Sequence, Test.SequenceHandler, and Test.Status
        into one helper. A single helper has three payoffs: (a) every
        emit site is one line instead of four, easier to audit for
        missing events; (b) the inner try/catch is in one place, so a
        future change to the failure mode updates every site at once;
        (c) schema validation runs at the emit site so a typo in a
        field name surfaces immediately as a Write-Warning + an
        auxiliary `schema_violation` record on the wire.

        Schema validation is best-effort and NEVER rejects the original
        record -- a malformed event is still written so a consumer
        sees what was actually emitted next to the violation report.

        Returns silently when Write-CycleNdjsonEvent isn't available
        (Test.Log not imported in this scope) and when the call itself
        throws (open-file race, disk full). The cycle never fails
        because telemetry failed.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Append-only telemetry pass-through; no destructive operation.')]
    param([Parameter(Mandatory)][hashtable]$EventRecord)
    if (-not (Get-Command Write-CycleNdjsonEvent -ErrorAction SilentlyContinue)) { return }
    # Schema validation. Soft import -- a consumer that loaded Test.Log
    # without Test.EventSchema (test fixture, unusual entry-point) still
    # gets the emit; validation just no-ops in that case.
    if (Get-Command Test-CycleEventSchema -ErrorAction SilentlyContinue) {
        $violations = @()
        try { $violations = @(Test-CycleEventSchema -Record $EventRecord) }
        catch { Write-Verbose "Send-CycleEventSafely: schema validator threw ($($_.Exception.Message)); skipping check." }
        if ($violations.Count -gt 0) {
            $badEvent = if ($EventRecord.Contains('event')) { [string]$EventRecord['event'] } else { '(missing)' }
            Write-Warning "cycle.events.ndjson schema violation for event '$badEvent': $($violations -join '; ')"
            # Synthetic schema_violation event, emitted FIRST so the
            # consumer reads the diagnosis on the line above the bad
            # record. Direct call to Write-CycleNdjsonEvent (not back
            # through Send-CycleEventSafely) to avoid validation
            # recursion on the marker event itself.
            try {
                Write-CycleNdjsonEvent -EventRecord @{
                    timestamp  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event      = 'schema_violation'
                    badEvent   = $badEvent
                    violations = @($violations)
                }
            } catch { $null = $_ }
        }
    }
    try {
        Write-CycleNdjsonEvent -EventRecord $EventRecord
    } catch {
        $null = $_
    }
}

function New-YurunaDegradationRecord {
    <#
    .SYNOPSIS
        Builds the `degradation` event hashtable. Pure -- separated from the
        emitter so the field contract is unit-testable without an open cycle
        event stream.
    .OUTPUTS
        [hashtable] the event record for Send-CycleEventSafely.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure builder: constructs and returns the degradation record; changes no system state.')]
    param(
        [Parameter(Mandatory)][string]$Dependency,
        [Parameter(Mandatory)][string]$Primary,
        [Parameter(Mandatory)][string]$Fallback,
        [string]$Reason = '',
        [ValidateSet('soft','hard')][string]$Severity = 'soft',
        [string]$Timestamp
    )
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    return @{
        timestamp  = $Timestamp
        event      = 'degradation'
        dependency = [string]$Dependency
        primary    = [string]$Primary
        fallback   = [string]$Fallback
        reason     = [string]$Reason
        severity   = [string]$Severity
    }
}

function Send-YurunaDegradation {
    <#
    .SYNOPSIS
        Records that the harness fell back from a primary mechanism to a lesser
        alternative and is CONTINUING in a degraded mode -- the observability
        contract for graceful degradation.
    .DESCRIPTION
        Emits a structured `degradation` event onto cycle.events.ndjson so a
        degraded-but-passing cycle is first-class and queryable, instead of a
        silent (or merely Write-Verbose) fallback that reads as a clean pass.
        Distinct from the *_failed / *_unavailable events: those report a
        capability that BROKE; a degradation reports one that was unavailable
        and was WORKED AROUND, the cycle proceeding.

        Thin wrapper over Send-CycleEventSafely (schema-validated, never throws,
        no-ops when the cycle event stream isn't open), so a degradation can
        never fail a cycle. Also writes one Write-Information breadcrumb so the
        fallback is visible in the console log without each call site repeating
        the line.
    .PARAMETER Dependency
        The subsystem/capability that degraded (e.g. 'keystroke-mechanism',
        'capture-feed', 'caching-proxy').
    .PARAMETER Primary
        The preferred mechanism that was unavailable (e.g. 'ssh-sequence').
    .PARAMETER Fallback
        The lesser alternative actually taken (e.g. 'gui-sequence').
    .PARAMETER Reason
        Short human reason for the fallback.
    .PARAMETER Severity
        'soft' (default) -- work continues degraded; 'hard' -- proceeding but a
        material capability is lost (degradation is soft by nature, so rarely).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Append-only telemetry pass-through; no destructive operation.')]
    param(
        [Parameter(Mandatory)][string]$Dependency,
        [Parameter(Mandatory)][string]$Primary,
        [Parameter(Mandatory)][string]$Fallback,
        [string]$Reason = '',
        [ValidateSet('soft','hard')][string]$Severity = 'soft'
    )
    Send-CycleEventSafely -EventRecord (New-YurunaDegradationRecord `
        -Dependency $Dependency -Primary $Primary -Fallback $Fallback `
        -Reason $Reason -Severity $Severity)
    $suffix = if ($Reason) { " ($Reason)" } else { '' }
    Write-Information "  [degradation] ${Dependency}: ${Primary} -> ${Fallback}${suffix}"
}

Export-ModuleMember -Function Start-LogFile, Stop-LogFile, Get-CycleGuestDataFolder, Get-CycleScreenDir, Format-CycleFolderBaseName, Get-CycleFolderIdentity, Write-CycleNdjsonEvent, Write-CycleManifest, Send-CycleEventSafely, New-YurunaDegradationRecord, Send-YurunaDegradation, Invoke-CycleLogRotation
