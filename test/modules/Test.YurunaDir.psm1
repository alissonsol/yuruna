<#PSScriptInfo
.VERSION 2026.09.18
.GUID 4201fdd8-53b7-4416-b2a6-1f61d3cff3af
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

# Idempotent setup helpers for Yuruna directory env vars: default a path
# under <testRoot>/status/<sub>, create the directory if missing, return
# the resolved path. Two semantically-split exports: bulky logs
# (Initialize-YurunaLogDir) and small runtime state
# (Initialize-YurunaRuntimeDir).

function Initialize-YurunaLogDir {
    <#
    .SYNOPSIS
        Ensure $env:YURUNA_LOG_DIR points to a writable log directory,
        creating the directory if needed. Idempotent.
    .DESCRIPTION
        $env:YURUNA_LOG_DIR is the unified reference for Yuruna's log
        directory: bulky HTML transcripts, OCR debug images, failure
        screenshots, per-component debug subdirs (NewText, Screenshot).
        Separate from $env:YURUNA_RUNTIME_DIR, which holds the small
        operationally-interesting state files (pids, status.json,
        control flags). Callers should reference $env:YURUNA_LOG_DIR
        directly after invoking this initializer at least once.
    .OUTPUTS
        System.String. The resolved $env:YURUNA_LOG_DIR path, for the
        common case where a caller wants it inline.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $env:YURUNA_LOG_DIR) {
        # Default: <testRoot>/status/log/. Co-located with the runtime dir
        # and served by the status HTTP server at /log/<name>, so bulky
        # diagnostic artifacts (HTML transcripts, OCR debug images,
        # failure screenshots) can be linked directly from the status
        # page without copying them out of %TEMP%. Override by setting
        # $env:YURUNA_LOG_DIR before import; the server maps /log/* onto
        # the overridden path.
        $testRoot = Split-Path -Parent $PSScriptRoot
        $env:YURUNA_LOG_DIR = Join-Path -Path $testRoot -ChildPath 'status' -AdditionalChildPath 'log'
    }
    if (-not (Test-Path $env:YURUNA_LOG_DIR)) {
        New-Item -ItemType Directory -Path $env:YURUNA_LOG_DIR -Force | Out-Null
    }
    return $env:YURUNA_LOG_DIR
}

function Initialize-YurunaRuntimeDir {
    <#
    .SYNOPSIS
        Ensure $env:YURUNA_RUNTIME_DIR points to a writable runtime directory,
        creating the directory if needed. Idempotent.
    .DESCRIPTION
        $env:YURUNA_RUNTIME_DIR holds the small operationally-interesting
        state files: status.json, *.pid files, control.*-pause flags,
        ipaddresses.txt, caching-proxy-service.txt, server.err, host.uuid,
        host-network.txt, host-network.json, and the detached status-service
        script. Keeping these separate from
        $env:YURUNA_LOG_DIR (which contains bulky HTML transcripts and OCR
        debug artifacts) makes investigations faster -- you don't sift
        through hundreds of log files to find the current runner.pid.

        Default location is <testRoot>/status/runtime/ so the status HTTP
        server can serve the files at /runtime/<name>. Callers can override
        by setting $env:YURUNA_RUNTIME_DIR before import; the status service
        then maps /runtime/* onto the overridden path.
    .OUTPUTS
        System.String. The resolved $env:YURUNA_RUNTIME_DIR path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $env:YURUNA_RUNTIME_DIR) {
        # <testRoot>/status/runtime/ -- this module lives at test/modules/
        # so two levels up is test/.
        $testRoot = Split-Path -Parent $PSScriptRoot
        $env:YURUNA_RUNTIME_DIR = Join-Path -Path $testRoot -ChildPath 'status' -AdditionalChildPath 'runtime'
    }
    if (-not (Test-Path $env:YURUNA_RUNTIME_DIR)) {
        New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR -Force | Out-Null
    }
    return $env:YURUNA_RUNTIME_DIR
}

# Resolve-SeededHostId returns the id this machine's hardware implies, or '' to
# mean "generate one". Test.HostIdentity owns the derivation and the platform
# reads behind it; this only reaches them, loading that sibling on demand
# because it is needed exactly once in a host's life -- the call that brings
# host.uuid into existence -- and importing it on every module load would put a
# fingerprint gather in front of every entry point that touches a runtime path.
#
# Test.Perf carries the twin of this helper for the same reason: both modules
# create host.uuid, either can be the one that wins the race, and a machine
# whose identity depended on which one got there first would be exactly the
# forked identity all of this exists to prevent. The two must agree.
#
# Never throws and never blocks on a prompt: an id is always obtainable, and a
# host that cannot read its own hardware must still get one.
function Resolve-SeededHostId {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # An operator deliberately re-keying a host needs a way to ask for a new
    # identity rather than the one its hardware implies, since the derivation
    # would otherwise hand back the same id the removed runtime directory had.
    if ($env:YURUNA_HOST_ID_SEED -eq 'random') { return '' }
    if (-not (Get-Command Get-HostIdentitySeedUuid -ErrorAction SilentlyContinue)) {
        $module = Join-Path $PSScriptRoot 'Test.HostIdentity.psm1'
        if (-not (Test-Path -LiteralPath $module)) { return '' }
        # No -Force: this only needs the command reachable from here, and a
        # forced reload would evict the module from a caller that already holds
        # it, taking its commands with it.
        try { Import-Module $module -ErrorAction Stop } catch {
            Write-Verbose "Resolve-SeededHostId: Test.HostIdentity unavailable: $($_.Exception.Message)"
            return ''
        }
    }
    # -AllowSudo because the strong keys are root-only on Linux and the sudo
    # cache is primed during host setup, which is when a fresh host first asks
    # for an id. Cold, `sudo -n` fails fast rather than prompting.
    try { return [string](Get-HostIdentitySeedUuid -AllowSudo) } catch {
        Write-Verbose "Resolve-SeededHostId: derivation failed: $($_.Exception.Message)"
        return ''
    }
}

function Get-YurunaHostId {
    <#
    .SYNOPSIS
        Stable per-host identity (distinct from hostname; survives rename),
        persisted in $env:YURUNA_RUNTIME_DIR/host.uuid. 42-prefixed for visual
        filtering in unified pool logs.
    .DESCRIPTION
        The multi-host pool harness joins cross-host telemetry on
        (hostId, runId, cycleStartUtc); hostname can collide and rename, so a persisted
        UUID is the durable key. Shares the one host.uuid file -- same path, same
        42-prefixed format -- with Test.Perf's Get-PerfHostUuid; the file is the
        single source of truth, created once early in the single outer-runner
        process. A host that loses the runtime dir re-derives the SAME id from
        its hardware where a stable key can be read, so a reimage or a re-clone
        does not fork its pool history; set YURUNA_HOST_ID_SEED=random to re-key
        deliberately, and see Get-HostIdentitySeedUuid for which keys count.
        Process entry points cache the value on
        $global:__YurunaHostId at script top (the same pattern as
        $global:__YurunaRunId) so the NDJSON hot path reads a global, not the disk.
    .OUTPUTS
        System.String -- the host UUID, or $null if the runtime dir is unwritable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $runtimeDir = Initialize-YurunaRuntimeDir
    if (-not $runtimeDir) { return $null }
    $uuidFile = Join-Path $runtimeDir 'host.uuid'
    if (Test-Path -LiteralPath $uuidFile) {
        try {
            $existing = ([System.IO.File]::ReadAllText($uuidFile)).Trim()
            if ($existing) { return $existing }
        } catch { Write-Verbose "Get-YurunaHostId: read failed, regenerating: $($_.Exception.Message)" }
    }
    # Derived from a stable hardware key when one can be read, so a machine that
    # lost this file comes back as the same host instead of forking its pool
    # history under a fresh identity. Random is the fallback, and the shape is
    # the same either way -- 42-prefixed (matches Get-PerfHostUuid): '42' + 30
    # hex = 32 chars.
    $id = Resolve-SeededHostId
    if (-not $id) { $id = '42' + ([Guid]::NewGuid().ToString('N')).Substring(2, 30) }
    # Atomic first-write, shared with Get-PerfHostUuid on this same host.uuid: two
    # processes hitting first-use at once would each generate a DIFFERENT id, so a
    # plain overwrite would leave the host with two identities. The create itself is
    # the lock -- FileMode.CreateNew is O_CREAT|O_EXCL on POSIX and CREATE_NEW on
    # Windows, so exactly one caller can bring the path into existence and everyone
    # else adopts what that caller wrote. A temp-then-rename cannot hold this line on
    # POSIX: [System.IO.File]::Move tests for the destination and then renames, so
    # racers that pass the test together all rename successfully, the last one lands
    # on disk, and every earlier one walks away with an id that was never persisted.
    # A genuine persist failure is fatal to the caller (return $null, per the OUTPUTS
    # contract) rather than an unpersisted id the next call would silently
    # re-generate as a different one.
    $claim = $null
    try {
        $claim = [System.IO.File]::Open($uuidFile, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    } catch {
        Write-Verbose "Get-YurunaHostId: did not win the host.uuid claim: $($_.Exception.Message)"
    }
    if ($claim) {
        try {
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($id)
            $claim.Write($bytes, 0, $bytes.Length)
            $claim.Flush()
            return $id
        } catch {
            Write-Verbose "Get-YurunaHostId: host.uuid could not be written: $($_.Exception.Message)"
            return $null
        } finally { $claim.Dispose() }
    }
    # The winner owns the path from the instant it is created, so a loser reading
    # straight away can catch it before the id is flushed. Give that write a bounded
    # window to land instead of reading one empty file and calling it corrupt.
    foreach ($attempt in 1..5) {
        try {
            $winner = ([System.IO.File]::ReadAllText($uuidFile)).Trim()
            if ($winner) { return $winner }
        } catch { Write-Verbose "Get-YurunaHostId: winner re-read failed: $($_.Exception.Message)" }
        Start-Sleep -Milliseconds 20
    }
    # A present-but-empty/corrupt host.uuid also lands here: yield $null rather than
    # overwrite it, so the operator removes the file to deliberately re-key.
    Write-Verbose "Get-YurunaHostId: host.uuid could not be persisted; returning null."
    return $null
}

function Format-YurunaHostId {
    <#
    .SYNOPSIS
        The GUID-dashed spelling of a host id (8-4-4-4-12), for every surface
        that shows an operator a FULL one.
    .DESCRIPTION
        Get-YurunaHostId mints and every store keys on the undashed 32-hex form,
        so this is a rendering and nothing that goes back to a store may be built
        from it. It exists because 32 undifferentiated hex characters are not
        checkable against another screen by eye, and a lab holds a dozen ids that
        share the '42' prefix -- the dashes are what let an operator confirm they
        are looking at the same machine in two places. ConvertTo-YurunaHostId is
        the inverse and takes this spelling back to the key, which is why every
        pool-admin command accepts an id pasted off a panel.

        A value that is not 32 hex is returned untouched: a pool GUID already
        carries its dashes, and an id in some other shape is not this function's
        to reinterpret.
    .OUTPUTS
        System.String -- the id as 8-4-4-4-12, or the input unchanged.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][string]$HostId)
    if ([string]::IsNullOrWhiteSpace($HostId)) { return [string]$HostId }
    $h = $HostId.Trim()
    if ($h -notmatch '^[0-9a-fA-F]{32}$') { return $HostId }
    return ('{0}-{1}-{2}-{3}-{4}' -f $h.Substring(0, 8), $h.Substring(8, 4), $h.Substring(12, 4), $h.Substring(16, 4), $h.Substring(20, 12))
}

function Test-PidFileIdentity {
    <#
    .SYNOPSIS
        True when $Process is plausibly the process that wrote $PidFile.
    .DESCRIPTION
        A detached service writes its pidfile just after it starts, so a
        genuine owner started at (or a hair before) the pidfile's mtime; a
        process that reused the PID after the owner died started later. This
        is the identity check that lets a kill path force-kill ONLY the real
        server: on a long-uptime host the OS recycles PIDs, so a bare
        "process exists and is a pwsh" test can kill an unrelated process --
        e.g. the freshly-launched outer runner that inherited the dead
        server's PID after a reboot. Returns $false when the process is
        null, is not a PowerShell process, started after the pidfile, or its
        StartTime / the pidfile mtime is unreadable -- a caller must never
        force-kill a PID it cannot confirm. Companion of Clear-StalePidFile
        (which clears the stale pidfile once identity is disproven).
    .PARAMETER PidFile
        Absolute path to the pidfile whose mtime dates the owner's launch.
    .PARAMETER Process
        The live process currently holding that PID (Get-Process result).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$PidFile,
        $Process
    )
    if ($null -eq $Process) { return $false }
    if ($Process.ProcessName -notmatch 'pwsh|PowerShell') { return $false }
    try {
        $mtime = (Get-Item -LiteralPath $PidFile -ErrorAction Stop).LastWriteTime
        return ($Process.StartTime -le $mtime.AddSeconds(2))
    } catch {
        Write-Verbose "Test-PidFileIdentity: cannot confirm identity for PID $($Process.Id): $($_.Exception.Message)"
        return $false
    }
}

Export-ModuleMember -Function Initialize-YurunaLogDir, Initialize-YurunaRuntimeDir, Get-YurunaHostId, Format-YurunaHostId, Test-PidFileIdentity
