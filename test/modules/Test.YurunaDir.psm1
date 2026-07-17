<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42a3d6f5-c0b1-4478-de26-5f7a0c4d3e62
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
        ipaddresses.txt, caching-proxy.txt, server.err, host.uuid, and
        the detached status-service script. Keeping these separate from
        $env:YURUNA_LOG_DIR (which contains bulky HTML transcripts and OCR
        debug artifacts) makes investigations faster -- you don't sift
        through hundreds of log files to find the current runner.pid.

        Default location is <testRoot>/status/runtime/ so the status HTTP
        server can serve the files at /runtime/<name>. Callers can override
        by setting $env:YURUNA_RUNTIME_DIR before import; the status server
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

function Get-YurunaHostId {
    <#
    .SYNOPSIS
        Stable per-host identity (distinct from hostname; survives rename),
        persisted in $env:YURUNA_RUNTIME_DIR/host.uuid. 42-prefixed for visual
        filtering in unified pool logs.
    .DESCRIPTION
        The multi-host pool harness joins cross-host telemetry on
        (hostId, runId, cycleId); hostname can collide and rename, so a persisted
        UUID is the durable key. Shares the one host.uuid file -- same path, same
        42-prefixed format -- with Test.Perf's Get-PerfHostUuid; the file is the
        single source of truth, created once early in the single outer-runner
        process. Removing the runtime dir re-keys the host, matching the rest of
        that folder's state. Process entry points cache the value on
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
    # 42-prefixed (matches Get-PerfHostUuid): '42' + 30 hex = 32 chars.
    $id = '42' + ([Guid]::NewGuid().ToString('N')).Substring(2, 30)
    # Atomic first-write, shared with Get-PerfHostUuid on this same host.uuid: two
    # processes hitting first-use at once would each generate a DIFFERENT id, so a
    # plain overwrite would leave the host with two identities. Write a per-process
    # temp then rename with the two-arg [System.IO.File]::Move, which throws if the
    # destination already exists -- exactly one racer wins and every loser re-reads
    # and adopts the winner's id. A genuine persist failure is fatal to the caller
    # (return $null, per the OUTPUTS contract) rather than an unpersisted id the next
    # call would silently re-generate as a different one.
    $tmpFile = "$uuidFile.$PID-$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($tmpFile, $id, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($tmpFile, $uuidFile)
        return $id
    } catch {
        if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
        try {
            $winner = ([System.IO.File]::ReadAllText($uuidFile)).Trim()
            if ($winner) { return $winner }
        } catch { Write-Verbose "Get-YurunaHostId: winner re-read failed: $($_.Exception.Message)" }
        # A present-but-empty/corrupt host.uuid also lands here (the create-exclusive
        # Move fails on the existing path and the re-read is blank): yield $null rather
        # than overwrite it, so the operator removes the file to deliberately re-key.
        Write-Verbose "Get-YurunaHostId: host.uuid could not be persisted; returning null."
        return $null
    }
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

Export-ModuleMember -Function Initialize-YurunaLogDir, Initialize-YurunaRuntimeDir, Get-YurunaHostId, Test-PidFileIdentity
