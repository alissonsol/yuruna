<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42fa7b6c-d5e4-4a83-9170-2f3a4b5c6d94
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna recovery boot-sweep stale-state
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

<#
.SYNOPSIS
    Boot-time recovery sweep: detect + archive stale state classes
    that a prior cycle / process crash left behind.

.DESCRIPTION
    Companion mechanisms close individual stale-state slices:

      * `.incomplete` marker lets a consumer detect a crashed cycle
        in O(1) by checking marker presence in the cycle folder.
      * Outer re-entry force-touches runner.stepHeartbeat so the
        watchdog never reads a 7-hour-old mtime.
      * Test.SingleInstance.Get-RunnerInstanceState classifies a stale
        runner.pid (its pid not a live process) as 'Stale' so the
        outer can take over without an operator click.

    This module owns the cross-class SWEEP that runs ONCE at outer
    startup and resolves every stale class together:

      1. Orphan `.incomplete` cycle folders -> rename marker to
         `.aborted.<UTC>.json` with augmented payload (recoveredAtUtc,
         recoveredByPid). The cycle folder itself is preserved as
         forensics; the rename makes future sweeps idempotent (already
         archived markers are not re-archived).
      2. Stale runner.pid / inner.pid (pid not a live process) -> delete.
         runner.pid takes its runner.start sidecar with it so a future
         Write-RunnerPidFile call sees a clean pair, not a half-state.
      3. Stale break-active.json (no live runner to honor the breakpoint)
         -> archive as `break-active.<UTC>.json.aborted` so an operator
         can audit what was paused.

    Every sweep emits a `boot_recovery_completed` NDJSON event with the
    archived / cleared counts so a streaming consumer / dashboard sees
    that the framework recovered from a crash without grep'ing console
    output.

    Policy: this is a READ-ONLY recovery -- nothing is deleted that
    has forensics value (cycle folders, .incomplete payloads, paused
    break-active state). Stale pidfiles are deleted because the pid
    is provably dead and the file content has no forensics value on
    its own.

    Pair with the marker-file write, the atomic-write helpers, and
    the Write-YurunaStateFile primitive: every state class either
    has a marker that this sweep can act on, or is reconstructible
    from the artifacts the cycle folder preserved.
#>

# Cycle-folder name patterns. Two shapes:
#
#   Bare:           NNNNNN.YYYY-MM-DD.HH-mm-ss.HOSTID
#                   (clean close)
#   With suffix:    NNNNNN.YYYY-MM-DD.HH-mm-ss.HOSTID.incomplete
#                   (in progress, OR crashed before Stop-LogFile's rename)
#
# Anything else under status/log/ is left alone (operator-created
# folders, history.YYYY-MM-DD buckets, prior .aborted.<UTC> archives,
# etc.).
$script:CycleFolderPattern           = '^\d{6}\..+\..+\..+$'
$script:CycleFolderIncompletePattern = '^\d{6}\..+\..+\..+\.incomplete$'

function Find-OrphanIncompleteCycle {
    <#
    .SYNOPSIS
        Return cycle folders under $LogDir that crashed mid-cycle.
    .DESCRIPTION
        Two crash signatures:

          a) Folder name has the `.incomplete` SUFFIX. The
             Stop-LogFile rename did not run -- the cycle either
             crashed mid-execution or after manifest write but
             before the folder rename. Either way the marker file
             inside may or may not still be present.
          b) Bare-named folder contains a `.incomplete` marker FILE
             (older shape, kept for backward compatibility with
             cycles written before the folder-suffix lifecycle).

        Returns one FileInfo per detected marker. When the folder
        has the suffix but no marker file inside (rename-failure
        case), returns a synthetic FileInfo for the folder itself
        (Resolve-OrphanIncompleteCycle handles both cases).
    .PARAMETER LogDir
        Path to test/status/log/. Defaults to $env:YURUNA_LOG_DIR.
    .OUTPUTS
        [System.IO.FileSystemInfo[]] one entry per orphan signal.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileSystemInfo[]], [object[]])]
    param([string]$LogDir = $env:YURUNA_LOG_DIR)
    if (-not $LogDir -or -not (Test-Path -LiteralPath $LogDir)) { return @() }
    $orphans = @()
    foreach ($cycleFolder in (Get-ChildItem -LiteralPath $LogDir -Directory -ErrorAction SilentlyContinue |
                              Where-Object { $_.Name -match $script:CycleFolderPattern -or
                                             $_.Name -match $script:CycleFolderIncompletePattern })) {
        $marker = Join-Path $cycleFolder.FullName '.incomplete'
        if (Test-Path -LiteralPath $marker) {
            $orphans += (Get-Item -LiteralPath $marker)
        } elseif ($cycleFolder.Name -match $script:CycleFolderIncompletePattern) {
            # Suffix says incomplete but no marker file. Rename failure
            # after Stop-LogFile removed the marker but before the
            # folder-level Move-Item; treat the folder itself as the
            # orphan signal so Resolve-OrphanIncompleteCycle can still
            # rename it to .aborted.<UTC>/.
            $orphans += $cycleFolder
        }
    }
    return $orphans
}

function Resolve-OrphanIncompleteCycle {
    <#
    .SYNOPSIS
        Archive a crashed cycle. Two cases:

          a) MarkerPath points at an `.incomplete` marker FILE inside
             a cycle folder -- write `.aborted.<UTC>.json` with
             augmented payload, remove the marker, AND (when the
             parent folder has the `.incomplete` suffix) rename
             the folder to `<base>.aborted.<UTC>/`.

          b) MarkerPath points at a FOLDER with the `.incomplete`
             suffix but no marker file inside (rename-failure during
             Stop-LogFile) -- skip the marker work and rename the
             folder.

        Both cases end with the folder renamed away from the
        `.incomplete` suffix so a second sweep is a no-op.
    .PARAMETER MarkerPath
        Either a `.incomplete` marker file (case a) OR a cycle folder
        with `.incomplete` suffix (case b).
    .OUTPUTS
        Hashtable describing what was archived, or $null on failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$MarkerPath)
    if (-not (Test-Path -LiteralPath $MarkerPath)) { return $null }
    if (-not $PSCmdlet.ShouldProcess($MarkerPath, 'Archive orphan .incomplete signal')) { return $null }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ssZ')
    $now   = (Get-Date).ToUniversalTime().ToString('o')

    # Detect shape: file (marker) vs directory (folder-with-suffix).
    $isDir = (Get-Item -LiteralPath $MarkerPath -ErrorAction SilentlyContinue) -is [System.IO.DirectoryInfo]

    if ($isDir) {
        # Case b: bare folder with .incomplete suffix, no marker file.
        $cycleDir = $MarkerPath
        $markerObj = @{}
    } else {
        # Case a: marker file. Parse payload + augment.
        $cycleDir = Split-Path -Parent $MarkerPath
        $markerObj = @{}
        try {
            $raw = Get-Content -Raw -LiteralPath $MarkerPath -ErrorAction Stop
            if ($raw -and $raw.Trim()) {
                $parsed = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                if ($parsed -is [System.Collections.IDictionary]) { $markerObj = [hashtable]$parsed }
            }
        } catch {
            Write-Verbose "Resolve-OrphanIncompleteCycle: marker parse failed at $MarkerPath ($($_.Exception.Message)); archiving with minimal payload."
        }
    }
    $markerObj['recoveredAtUtc'] = $now
    $markerObj['recoveredByPid'] = $PID
    $markerObj['recoverySignal'] = if ($isDir) { 'folder_suffix' } else { 'marker_file' }

    # Decide the post-recovery folder name. If the folder is already
    # `<base>.incomplete/`, rename to `<base>.aborted.<UTC>/`. If the
    # folder is bare, leave the folder name alone and just archive
    # the marker inside.
    $cycleDirLeaf = Split-Path -Leaf $cycleDir
    $hasIncompleteSuffix = $cycleDirLeaf -match '\.incomplete$'
    $finalCycleDir = $cycleDir
    if ($hasIncompleteSuffix) {
        $abortedLeaf = ($cycleDirLeaf -replace '\.incomplete$', '') + ".aborted.$stamp"
        $finalCycleDir = Join-Path (Split-Path -Parent $cycleDir) $abortedLeaf
        try {
            Move-Item -LiteralPath $cycleDir -Destination $finalCycleDir -Force -ErrorAction Stop
        } catch {
            Write-Verbose "Resolve-OrphanIncompleteCycle: folder rename '$cycleDir' -> '$finalCycleDir' failed: $($_.Exception.Message). Leaving folder with .incomplete suffix; marker archive below proceeds in-place."
            $finalCycleDir = $cycleDir
        }
    }

    # Marker-file archive (case a only; case b had no marker to copy).
    $archivedPath = $null
    if (-not $isDir) {
        $archivedPath = Join-Path $finalCycleDir ".aborted.$stamp.json"
        $ok = $false
        if (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue) {
            $ok = Write-YurunaStateFileJson -Path $archivedPath -InputObject $markerObj -Confirm:$false
        } else {
            # Defensive fallback for callers that loaded Test.Recovery without
            # Test.StateFile in scope (test fixtures, unusual entry points).
            try {
                $json = $markerObj | ConvertTo-Json -Compress
                [System.IO.File]::WriteAllText($archivedPath, $json, [System.Text.UTF8Encoding]::new($false))
                $ok = $true
            } catch {
                Write-Verbose "Resolve-OrphanIncompleteCycle: fallback write failed: $($_.Exception.Message)"
                $ok = $false
            }
        }
        if (-not $ok) { return $null }
        # The original marker is now inside $finalCycleDir (Move-Item
        # carried the folder contents with it when the folder was
        # renamed). Remove it.
        $relocatedMarker = Join-Path $finalCycleDir '.incomplete'
        if (Test-Path -LiteralPath $relocatedMarker) {
            Remove-Item -LiteralPath $relocatedMarker -Force -ErrorAction SilentlyContinue
        }
    }

    return @{
        cycleFolder        = Split-Path -Leaf $finalCycleDir
        archivedAs         = if ($archivedPath) { Split-Path -Leaf $archivedPath } else { $null }
        signal             = $markerObj['recoverySignal']
        markerCycleId      = if ($markerObj.Contains('cycleId'))      { [string]$markerObj['cycleId'] }      else { $null }
        markerStartedAtUtc = if ($markerObj.Contains('startedAtUtc')) { [string]$markerObj['startedAtUtc'] } else { $null }
        markerPid          = if ($markerObj.Contains('pid'))          { [int]$markerObj['pid'] }            else { 0 }
    }
}

function Clear-StalePidFile {
    <#
    .SYNOPSIS
        Delete a pidfile when its pid is not a live process.
    .DESCRIPTION
        Reads the pidfile, looks up the process, and removes the
        pidfile (plus its companion if -CompanionPath is given) when
        the process is gone -- OR when the PID is live but its StartTime
        does not match the recorded companion StartTime, i.e. the OS
        recycled a dead prior occupant's PID onto an unrelated process
        (the failure mode that silently blocks crash takeover on a
        long-uptime host). A self-PID is left alone; so is a live PID
        that cannot be disproven (no companion StartTime recorded, or
        the live StartTime is unreadable), because a false clear would
        drop a genuinely live runner's pidfile -- worse than a missed
        reclaim. Identity precedence mirrors Get-RunnerInstanceState.
        Returns the pid that was cleared, or $null when no clear happened.
    .PARAMETER PidFile
        Absolute path to the pidfile (runner.pid, inner.pid, etc.).
    .PARAMETER CompanionPath
        Optional companion file to delete alongside the pidfile (e.g.
        runner.start for runner.pid). Removed only when the pidfile
        itself is cleared.
    .OUTPUTS
        [hashtable] describing what was cleared, or $null when no-op.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$PidFile,
        [string]$CompanionPath,
        # Service pidfiles (server.pid / config-server.pid) have no .start
        # companion; opt into using the pidfile's own mtime as the launch
        # reference so a live PID recycled onto an unrelated process is still
        # cleared (a genuine owner started at/before the mtime it then wrote).
        [switch]$MtimeIdentity
    )
    if (-not (Test-Path -LiteralPath $PidFile)) { return $null }
    if (-not $PSCmdlet.ShouldProcess($PidFile, 'Clear stale pidfile')) { return $null }
    $filePid = 0
    try { $filePid = [int]((Get-Content -LiteralPath $PidFile -Raw -ErrorAction Stop).Trim()) }
    catch { $filePid = 0 }
    if ($filePid -le 0) {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        # Take the companion with it: an orphan runner.start left behind
        # feeds the next launch a StartTime for a pid that no longer
        # exists, recreating the half-state the pairing exists to prevent.
        if ($CompanionPath -and (Test-Path -LiteralPath $CompanionPath)) {
            Remove-Item -LiteralPath $CompanionPath -Force -ErrorAction SilentlyContinue
        }
        return @{ pidFile = (Split-Path -Leaf $PidFile); stalePid = 0; reason = 'unparseable' }
    }
    if ($filePid -eq $PID) { return $null }
    $proc = Get-Process -Id $filePid -ErrorAction SilentlyContinue
    $recycled = $false
    if ($proc) {
        # The PID is live, but the OS may have recycled a dead prior
        # occupant's PID onto an unrelated process. Trust the pidfile as
        # live only when the live process's StartTime matches the recorded
        # companion StartTime (runner.start, written by Write-RunnerPidFile
        # as ToString('o')). 2s tolerance matches Get-RunnerInstanceState:
        # DateTimeOffset.Parse + StartTime can lose precision across the
        # round-trip on some kernels, but the window is far narrower than
        # any real recycle. When identity cannot be established (no
        # companion StartTime, or the live StartTime is unreadable), stay
        # conservative and treat it as live.
        $recordedStart = $null
        if ($CompanionPath -and (Test-Path -LiteralPath $CompanionPath)) {
            try {
                $rawStart = (Get-Content -LiteralPath $CompanionPath -Raw -ErrorAction Stop).Trim()
                if ($rawStart) { $recordedStart = [DateTimeOffset]::Parse($rawStart).UtcDateTime }
            } catch {
                Write-Verbose "Clear-StalePidFile: companion StartTime parse failed at $CompanionPath ($($_.Exception.Message))."
            }
        }
        $liveStart = $null
        try { $liveStart = $proc.StartTime.ToUniversalTime() }
        catch { Write-Verbose "Clear-StalePidFile: live StartTime unreadable for pid $filePid ($($_.Exception.Message))." }
        if ($null -ne $recordedStart) {
            # Companion StartTime recorded: it is the exact launch time, so a
            # match within 2s is the genuine owner; a mismatch is a recycle.
            if ($null -eq $liveStart) { return $null }
            if ([Math]::Abs(($recordedStart - $liveStart).TotalSeconds) -le 2) { return $null }
            $recycled = $true
        } elseif ($MtimeIdentity) {
            # No companion, but the caller opted into pidfile-mtime identity: a
            # genuine owner started at/before the mtime it then wrote; a PID that
            # started later is a recycle. Keep on start<=mtime, clear otherwise.
            if ($null -eq $liveStart) { return $null }
            $mtimeUtc = $null
            try { $mtimeUtc = (Get-Item -LiteralPath $PidFile -ErrorAction Stop).LastWriteTime.ToUniversalTime() }
            catch { return $null }
            if ($liveStart -le $mtimeUtc.AddSeconds(2)) { return $null }
            $recycled = $true
        } else {
            # Live PID that cannot be disproven (no companion, no mtime opt-in)
            # -> stay conservative and treat it as live.
            return $null
        }
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    if ($CompanionPath -and (Test-Path -LiteralPath $CompanionPath)) {
        Remove-Item -LiteralPath $CompanionPath -Force -ErrorAction SilentlyContinue
    }
    return @{
        pidFile  = (Split-Path -Leaf $PidFile)
        stalePid = $filePid
        reason   = if ($recycled) { 'pid_recycled' } else { 'process_not_running' }
    }
}

function Resolve-StaleBreakActive {
    <#
    .SYNOPSIS
        Archive a break-active.json left over from a crashed cycle.
    .DESCRIPTION
        A `break` action writes break-active.json while paused; the
        action's resume path deletes it. If the runner crashed while
        paused, the file survives and the next cycle's first step
        sees a parked breakpoint that nobody is waiting on. This
        helper renames the file to `break-active.<UTC>.json.aborted`
        so an operator can still audit what was paused.
    .PARAMETER RuntimeDir
        Path to test/status/runtime/.
    .OUTPUTS
        [hashtable] describing the archived file, or $null on no-op.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $path = Join-Path $RuntimeDir 'break-active.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    if (-not $PSCmdlet.ShouldProcess($path, 'Archive stale break-active.json')) { return $null }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ssZ')
    $archived = Join-Path $RuntimeDir "break-active.$stamp.json.aborted"
    try {
        Move-Item -LiteralPath $path -Destination $archived -Force -ErrorAction Stop
    } catch {
        Write-Verbose "Resolve-StaleBreakActive: rename failed: $($_.Exception.Message)"
        return $null
    }
    return @{
        archivedAs = Split-Path -Leaf $archived
    }
}

function Clear-StalePauseFlag {
    <#
    .SYNOPSIS
        Delete leftover control.step-pause / control.cycle-pause /
        control.pause flags so a fresh runner launch never starts
        paused.
    .DESCRIPTION
        The status UI's pause endpoints write these flags into
        $RuntimeDir; the play endpoint deletes them. If the operator
        paused a prior cycle and then crashed or killed the runner
        before clicking play, the flags persist and the NEXT runner
        launch would start paused -- confusing the operator, who
        never clicked pause on this fresh run. Entry-point scripts
        call this at startup to enforce the policy "a new command
        line never inherits a prior session's pause state".
    .PARAMETER RuntimeDir
        test/status/runtime/. Defaults to $env:YURUNA_RUNTIME_DIR.
    .OUTPUTS
        [hashtable] { cleared = string[] } listing the basenames that
        were removed, or $null when no flag was present.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR)
    if (-not $RuntimeDir -or -not (Test-Path -LiteralPath $RuntimeDir)) { return $null }
    if (-not $PSCmdlet.ShouldProcess($RuntimeDir, 'Clear stale pause flags')) { return $null }
    $cleared = @()
    foreach ($flag in @('control.step-pause', 'control.cycle-pause', 'control.pause')) {
        $path = Join-Path $RuntimeDir $flag
        if (Test-Path -LiteralPath $path) {
            try {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                $cleared += $flag
            } catch {
                Write-Verbose "Clear-StalePauseFlag: failed to remove $flag : $($_.Exception.Message)"
            }
        }
    }
    if ($cleared.Count -gt 0) { return @{ cleared = $cleared } }
    return $null
}

function Clear-StaleControlState {
    <#
    .SYNOPSIS
        Sweep the stale inter-cycle control-state flags a starting entry
        point must not inherit, for a given lifecycle scope.
    .DESCRIPTION
        The status server writes control flags into $RuntimeDir to steer
        a running cycle: control.cycle-restart (rewind to step 1),
        control.step-pause / control.cycle-pause / control.pause (hold),
        and break-active.json (a parked breakpoint). A session killed
        before consuming a flag leaves it behind, and the NEXT session
        would then wake to a request the operator never made for it.

        This is the single place the three flag-classes are swept, keyed
        by -Scope so a caller cannot hand-pick an inconsistent subset:

          Startup  -- a fresh top-level entry point that IS the restart
                      the operator just asked for: consume
                      control.cycle-restart. Interactive parked state
                      (break-active + pause flags) is also cleared unless
                      -SkipInteractiveState is passed.
          PreSpawn -- an entry point about to hand off to a child cycle
                      it spawns: clear the interactive parked state so
                      the child does not inherit it, but leave
                      control.cycle-restart for the child to consume as
                      ITS own restart.

        -SkipInteractiveState narrows Startup to control.cycle-restart
        only. It exists for the spawned inner, whose interactive parked
        state is already swept by its parent (the outer's boot recovery
        or a PreSpawn caller); re-sweeping it would clear a pause the
        operator set on a direct-invoke inner.

        Best-effort: a failed removal is recorded, not thrown, so a
        single locked/permission-denied flag can never block the launch.
    .PARAMETER Scope
        Startup | PreSpawn (see above).
    .PARAMETER SkipInteractiveState
        Startup-only: consume control.cycle-restart but leave break-active
        and pause flags untouched.
    .PARAMETER RuntimeDir
        test/status/runtime/. Defaults to $env:YURUNA_RUNTIME_DIR.
    .OUTPUTS
        [hashtable] {
            cycleRestartCleared = [bool]
            cycleRestartAgeSeconds = [int] or $null  (age of the consumed flag)
            breakActive = archive result or $null
            pauseFlags = string[] basenames cleared
            warnings = string[]
        }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateSet('Startup','PreSpawn')][string]$Scope,
        [switch]$SkipInteractiveState,
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR
    )
    $summary = @{
        cycleRestartCleared    = $false
        cycleRestartAgeSeconds = $null
        breakActive            = $null
        pauseFlags             = @()
        warnings               = @()
    }
    if (-not $RuntimeDir -or -not (Test-Path -LiteralPath $RuntimeDir)) { return $summary }
    if (-not $PSCmdlet.ShouldProcess($RuntimeDir, "Clear stale control state ($Scope)")) { return $summary }

    # control.cycle-restart: only a Startup caller IS the restart, so only
    # Startup consumes it. A PreSpawn caller leaves it for the child cycle.
    if ($Scope -eq 'Startup') {
        $restartFlag = Join-Path $RuntimeDir 'control.cycle-restart'
        if (Test-Path -LiteralPath $restartFlag) {
            try {
                $age = (Get-Date) - (Get-Item -LiteralPath $restartFlag).LastWriteTime
                $summary.cycleRestartAgeSeconds = [int]$age.TotalSeconds
            } catch { $summary.cycleRestartAgeSeconds = $null }
            try {
                Remove-Item -LiteralPath $restartFlag -Force -ErrorAction Stop
                $summary.cycleRestartCleared = $true
            } catch {
                $summary.warnings += "control.cycle-restart clear failed: $($_.Exception.Message)"
            }
        }
    }

    # Interactive parked state (break-active + pause flags). Swept for
    # PreSpawn always, and for Startup unless the caller opts out.
    $sweepInteractive = ($Scope -eq 'PreSpawn') -or (-not $SkipInteractiveState)
    if ($sweepInteractive) {
        try {
            $archivedBreak = Resolve-StaleBreakActive -RuntimeDir $RuntimeDir -Confirm:$false
            if ($archivedBreak) { $summary.breakActive = $archivedBreak }
        } catch {
            $summary.warnings += "Resolve-StaleBreakActive failed: $($_.Exception.Message)"
        }
        try {
            $clearedPause = Clear-StalePauseFlag -RuntimeDir $RuntimeDir -Confirm:$false
            if ($clearedPause -and $clearedPause.cleared) { $summary.pauseFlags = @($clearedPause.cleared) }
        } catch {
            $summary.warnings += "Clear-StalePauseFlag failed: $($_.Exception.Message)"
        }
    }

    return $summary
}

function Invoke-YurunaBootRecovery {
    <#
    .SYNOPSIS
        Top-level sweep. Called once at outer startup; resolves every
        stale state class found and emits a single
        `boot_recovery_completed` NDJSON event with the summary.
    .DESCRIPTION
        Idempotent and best-effort: any sub-step's failure surfaces as
        a Write-Warning but never aborts the sweep. A future-cycle
        call sees the prior pass's archived markers and skips them
        (already-resolved markers no longer have `.incomplete`).

        Order:
          1. Stale pidfiles (delete; pid is dead, or -- for the service
             pidfiles that carry no .start companion -- a live PID that
             provably recycled onto an unrelated process, judged by the
             pidfile's own mtime)
          2. Stale break-active.json (archive)
          3. Stale pause flags (delete; a fresh launch never inherits
             a prior session's pause request)
          4. Orphan `.incomplete` cycle folders (archive markers)

        Pidfiles go first because a stale runner.pid would otherwise
        confuse downstream callers that read it before the sweep gets
        a chance.
    .PARAMETER RuntimeDir
        test/status/runtime/. Defaults to $env:YURUNA_RUNTIME_DIR.
    .PARAMETER LogDir
        test/status/log/. Defaults to $env:YURUNA_LOG_DIR.
    .OUTPUTS
        Hashtable summary: ArchivedCycles, ClearedPidFiles,
        ArchivedBreakActive, ClearedPauseFlags, Warnings,
        StartedAtUtc, CompletedAtUtc.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [string]$LogDir     = $env:YURUNA_LOG_DIR
    )
    $summary = @{
        StartedAtUtc        = (Get-Date).ToUniversalTime().ToString('o')
        ArchivedCycles      = @()
        ClearedPidFiles     = @()
        ArchivedBreakActive = $null
        ClearedPauseFlags   = @()
        Warnings            = @()
    }
    if (-not $PSCmdlet.ShouldProcess('Yuruna runtime state', 'Boot recovery sweep')) {
        $summary.CompletedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        return $summary
    }

    if ($RuntimeDir -and (Test-Path -LiteralPath $RuntimeDir)) {
        # Pidfiles. inner.pid has no companion sidecar; runner.pid pairs
        # with runner.start (StartTime sidecar from Write-RunnerPidFile).
        foreach ($entry in @(
            @{ pid = 'inner.pid';         companion = $null;          mtimeIdentity = $false },
            @{ pid = 'runner.pid';        companion = 'runner.start';  mtimeIdentity = $false },
            # Service pidfiles have no .start sidecar, so use pidfile-mtime
            # identity: a stale server.pid / config-server.pid must not survive a
            # reboot, where the OS can recycle the old PID onto the freshly
            # launched runner and a kill path would otherwise take it down.
            @{ pid = 'server.pid';        companion = $null;          mtimeIdentity = $true },
            @{ pid = 'config-server.pid'; companion = $null;          mtimeIdentity = $true }
        )) {
            try {
                $companion = if ($entry.companion) { Join-Path $RuntimeDir $entry.companion } else { $null }
                $cleared = Clear-StalePidFile -PidFile (Join-Path $RuntimeDir $entry.pid) -CompanionPath $companion -MtimeIdentity:$entry.mtimeIdentity -Confirm:$false
                if ($cleared) { $summary.ClearedPidFiles += $cleared }
            } catch {
                $summary.Warnings += "Clear-StalePidFile failed for $($entry.pid): $($_.Exception.Message)"
            }
        }
        try {
            $archivedBreak = Resolve-StaleBreakActive -RuntimeDir $RuntimeDir -Confirm:$false
            if ($archivedBreak) { $summary.ArchivedBreakActive = $archivedBreak }
        } catch {
            $summary.Warnings += "Resolve-StaleBreakActive failed: $($_.Exception.Message)"
        }
        try {
            $clearedPause = Clear-StalePauseFlag -RuntimeDir $RuntimeDir -Confirm:$false
            if ($clearedPause -and $clearedPause.cleared) { $summary.ClearedPauseFlags = @($clearedPause.cleared) }
        } catch {
            $summary.Warnings += "Clear-StalePauseFlag failed: $($_.Exception.Message)"
        }
    }

    if ($LogDir -and (Test-Path -LiteralPath $LogDir)) {
        foreach ($marker in (Find-OrphanIncompleteCycle -LogDir $LogDir)) {
            try {
                $archived = Resolve-OrphanIncompleteCycle -MarkerPath $marker.FullName -Confirm:$false
                if ($archived) { $summary.ArchivedCycles += $archived }
            } catch {
                $summary.Warnings += "Resolve-OrphanIncompleteCycle failed for $($marker.FullName): $($_.Exception.Message)"
            }
        }
    }

    $summary.CompletedAtUtc = (Get-Date).ToUniversalTime().ToString('o')

    # Emit NDJSON breadcrumb iff there's something to report. The clean-
    # boot case (no orphans, no stale pids, no break-active) stays silent
    # so a healthy host doesn't flood cycle.events.ndjson with no-op
    # recovery events.
    $touched = ($summary.ArchivedCycles.Count -gt 0) -or
               ($summary.ClearedPidFiles.Count -gt 0) -or
               ($null -ne $summary.ArchivedBreakActive) -or
               ($summary.ClearedPauseFlags.Count -gt 0) -or
               ($summary.Warnings.Count -gt 0)
    if ($touched -and (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue)) {
        Send-CycleEventSafely -EventRecord @{
            timestamp             = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            event                 = 'boot_recovery_completed'
            archivedCycleCount    = [int]$summary.ArchivedCycles.Count
            clearedPidFileCount   = [int]$summary.ClearedPidFiles.Count
            archivedBreakActive   = [bool]($null -ne $summary.ArchivedBreakActive)
            clearedPauseFlagCount = [int]$summary.ClearedPauseFlags.Count
            warningCount          = [int]$summary.Warnings.Count
            startedAtUtc          = [string]$summary.StartedAtUtc
            completedAtUtc        = [string]$summary.CompletedAtUtc
        }
    }
    if ($touched) {
        Write-Information ("Yuruna boot recovery: archivedCycles={0} clearedPidFiles={1} archivedBreakActive={2} clearedPauseFlags={3} warnings={4}" -f `
            $summary.ArchivedCycles.Count,
            $summary.ClearedPidFiles.Count,
            ($null -ne $summary.ArchivedBreakActive),
            $summary.ClearedPauseFlags.Count,
            $summary.Warnings.Count) -InformationAction Continue
    }
    return $summary
}

Export-ModuleMember -Function Invoke-YurunaBootRecovery, Find-OrphanIncompleteCycle, Resolve-OrphanIncompleteCycle, Clear-StalePidFile, Resolve-StaleBreakActive, Clear-StalePauseFlag, Clear-StaleControlState
