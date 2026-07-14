<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42d9c8b7-6f5e-4a23-9c81-7e4f3a2d1b50
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna runner pidfile single-instance
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
    Shared single-instance pidfile guard for the runner trio.
.DESCRIPTION
    Outer ([test/Invoke-TestRunner.ps1](../Invoke-TestRunner.ps1)) and
    inner ([test/modules/Invoke-TestInnerRunner.ps1](Invoke-TestInnerRunner.ps1))
    share one pidfile guard here instead of each carrying a near-identical
    hand-rolled copy that drifts when a per-platform fix lands -- the
    [BSD `ps -ww` truncation trap](../../docs/test-harness.md), for
    instance, is fixed once for both.

    Both entry points call into this module. The contract:

    - Get-RunnerInstanceState  : Inspect <RuntimeDir>/runner.pid +
                                 runner.start; classify the prior
                                 occupant as None / Self / Stale /
                                 OtherRunner.
    - Stop-StaleRunner         : Force-stop a prior occupant identified
                                 as OtherRunner, wait up to 10 s for
                                 exit, then run Remove-TestVMFiles.ps1
                                 with the default 'test-' prefix so the
                                 next cycle isn't fighting orphan VMs.
    - Write-RunnerPidFile      : Atomically publish runner.pid +
                                 runner.start (StartTime sidecar) so
                                 Start-StatusService's /control/runner-
                                 status endpoint can cross-check PID
                                 reuse without seeing a torn write.

    Identity precedence is StartTime sidecar first (works from any launch
    shape, including the macOS/Linux interactive `pwsh` REPL where argv
    is bare `pwsh`), with the cmdline regex as a backwards-compatible
    fallback for older pidfiles written before the sidecar landed.
#>

function Get-RunnerInstanceState {
    <#
    .SYNOPSIS
        Classify the existing runner.pid + runner.start pair, if any.
    .OUTPUTS
        [hashtable] with:
          status      'None' | 'Self' | 'Stale' | 'OtherRunner'
          pid         [int] PID from the file (0 when missing)
          identityVia 'startTime' | 'cmdline' | 'none'
          cmdline     [string] cmdline match (when identityVia=cmdline)
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunnerPidFile,
        [string]$RunnerStartFile,
        # Cmdline regex applied as the identity fallback. Outer matches
        # "Invoke-Test(?:Inner)?Runner.ps1" so a stranded inner is also
        # taken over; inner restricts to "Invoke-TestRunner.ps1" so it
        # never targets a sibling inner.
        [string]$CmdLinePattern = 'Invoke-Test(?:Inner)?Runner\.ps1'
    )
    if (-not (Test-Path -LiteralPath $RunnerPidFile)) {
        return @{ status='None'; pid=0; identityVia='none'; cmdline=$null }
    }
    $filePid = 0
    try { $filePid = [int]((Get-Content -LiteralPath $RunnerPidFile -Raw -ErrorAction Stop).Trim()) } catch { $filePid = 0 }
    if ($filePid -le 0) {
        return @{ status='Stale'; pid=0; identityVia='none'; cmdline=$null }
    }
    if ($filePid -eq $PID) {
        return @{ status='Self'; pid=$filePid; identityVia='none'; cmdline=$null }
    }
    $proc = Get-Process -Id $filePid -ErrorAction SilentlyContinue
    if (-not $proc) {
        return @{ status='Stale'; pid=$filePid; identityVia='none'; cmdline=$null }
    }
    # Identity precedence: StartTime sidecar first (forgery-resistant,
    # works regardless of launch shape), cmdline regex fallback.
    if ($RunnerStartFile -and (Test-Path -LiteralPath $RunnerStartFile)) {
        try {
            $recorded   = (Get-Content -LiteralPath $RunnerStartFile -Raw -ErrorAction Stop).Trim()
            $recordedDt = [DateTimeOffset]::Parse($recorded).UtcDateTime
            $liveDt     = $proc.StartTime.ToUniversalTime()
            # 2s tolerance: ToString('o') is sub-microsecond on .NET but
            # DateTimeOffset.Parse + StartTime can lose precision across
            # the round-trip on some kernels. Wide enough to absorb that
            # without admitting a different process.
            if ([Math]::Abs(($recordedDt - $liveDt).TotalSeconds) -le 2) {
                return @{ status='OtherRunner'; pid=$filePid; identityVia='startTime'; cmdline=$null }
            }
        } catch {
            Write-Verbose "runner.start cross-check failed: $($_.Exception.Message)"
        }
    }
    $cmd = $null
    if ($IsWindows) {
        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$filePid" -ErrorAction SilentlyContinue).CommandLine
    } elseif ($IsMacOS -or $IsLinux) {
        # `-ww` forces unlimited column width. Without it, BSD/macOS ps
        # truncates `args` to the controlling terminal's columns (or 80
        # if there's no TTY), hiding the trailing Invoke-TestRunner.ps1
        # token and breaking the regex match.
        $cmd = & '/bin/ps' -ww -p $filePid -o args= 2>$null
    }
    if ($cmd -and $cmd -match $CmdLinePattern) {
        return @{ status='OtherRunner'; pid=$filePid; identityVia='cmdline'; cmdline=[string]$cmd }
    }
    return @{ status='Stale'; pid=$filePid; identityVia='none'; cmdline=[string]$cmd }
}

function Stop-StaleRunner {
    <#
    .SYNOPSIS
        Force-stop an OtherRunner, wait for exit, then run
        Remove-TestVMFiles.ps1 to clear orphan VMs.
    .DESCRIPTION
        Best-effort: stop and cleanup failures are warnings, not throws.
        A caller racing the kill (operator clicks "Start cycle" while a
        runner is still up) needs the call to make progress rather than
        bail.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$TestRoot,
        [string]$CleanupPrefix = 'test-',
        [int]$WaitForExitMs = 10000
    )
    if (-not $PSCmdlet.ShouldProcess("PID $ProcessId", 'Stop stale runner + clear orphan VMs')) { return }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    $deadline = [DateTime]::UtcNow.AddMilliseconds($WaitForExitMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 500
    }
    # Surface a runner that outlived the kill: the takeover assumes the PID is gone before it
    # clears orphan VMs, so a survivor means the new cycle may contend with the old one.
    if (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) {
        Write-Warning "Stop-StaleRunner: PID $ProcessId is still alive after ${WaitForExitMs}ms; the new cycle may contend with the old runner. Investigate a wedged process."
    }
    $cleanup = Join-Path $TestRoot 'Remove-TestVMFiles.ps1'
    if (Test-Path -LiteralPath $cleanup) {
        try {
            & pwsh -NoProfile -File $cleanup -Prefix $CleanupPrefix
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Remove-TestVMFiles.ps1 exited $LASTEXITCODE during single-instance takeover; orphan VMs may remain -- the next cycle could fight them."
            }
        } catch {
            Write-Warning "Remove-TestVMFiles.ps1 failed during single-instance takeover: $($_.Exception.Message)"
        }
    }
}

function Write-RunnerPidFile {
    <#
    .SYNOPSIS
        Publish runner.pid + runner.start so /control/runner-status can
        cross-check the live runner without a torn read.
    .DESCRIPTION
        Atomic-create with exclusive share. Two concurrent operators
        launching Invoke-TestRunner.ps1 at the same moment otherwise
        both pass Get-RunnerInstanceState's check (both see "None")
        and both write their PID via plain Set-Content, leaving the
        loser's file overwritten and neither knowing the other won
        the takeover. CreateNew + FileShare.None turns the write into
        a compare-and-set: the loser's open throws and signals the
        race.

        Order matters: pidfile (with exclusive lock) first, sidecar
        second. A reader that races us sees either "no pidfile"
        (returns 'None') or "pidfile + sidecar" (returns 'OtherRunner')
        -- never a pidfile without its StartTime sidecar.

        Returns $true on successful write, $false when another runner
        won the race (caller should treat the loss the same way as
        Get-RunnerInstanceState returning 'OtherRunner' on the next
        retry path).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'ShouldProcess gates the actual writes; this attribute is for the wrapper.')]
    param(
        [Parameter(Mandatory)][string]$RunnerPidFile,
        [string]$RunnerStartFile
    )
    if (-not $PSCmdlet.ShouldProcess($RunnerPidFile, 'Write runner pidfile')) { return $true }
    # Atomic-write contract for the pidfile + StartTime sidecar pair:
    # the reader must never see a pidfile without its sidecar, or it
    # falls back to cmdline regex on a stale identity and may
    # misattribute. Sequence:
    #
    #   1. Compute startIso and write to a per-PID `.tmp` next to
    #      RunnerStartFile so a concurrent runner's tmp can't collide.
    #   2. CreateNew + FileShare.None on the pidfile -- this is the
    #      compare-and-set that decides the race.
    #   3. On win: Move-Item .tmp -> RunnerStartFile (atomic rename
    #      on same-volume NTFS / ext4 / APFS).
    #   4. On loss: delete the orphan .tmp and return $false; the
    #      caller treats this the same as Get-RunnerInstanceState
    #      returning 'OtherRunner'.
    #
    # The only remaining unprotected window is between (2) and (3) --
    # ~one rename syscall.
    $startIso = $null
    if ($RunnerStartFile) {
        try {
            $startIso = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        } catch {
            Write-Verbose "Could not compute runner.start StartTime (non-fatal): $($_.Exception.Message)"
        }
    }
    $startTmp = $null
    if ($RunnerStartFile -and $startIso) {
        $startTmp = "$RunnerStartFile.$PID.tmp"
        try {
            [System.IO.File]::WriteAllText($startTmp, $startIso, [System.Text.UTF8Encoding]::new($false))
        } catch {
            Write-Verbose "Could not stage runner.start tmp (non-fatal; sidecar will be skipped): $($_.Exception.Message)"
            $startTmp = $null
        }
    }
    # Open with CreateNew + FileShare.None so a concurrent open from
    # another runner fails with IOException. Any pre-existing pidfile
    # at this point is a logic error in the caller -- Get-RunnerInstanceState
    # + the Remove-Item that follows should have cleared it.
    $bytes = [System.Text.Encoding]::ASCII.GetBytes([string]$PID)
    try {
        $fs = [System.IO.File]::Open($RunnerPidFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
        } finally {
            $fs.Dispose()
        }
    } catch [System.IO.IOException] {
        Write-Warning "Write-RunnerPidFile: another runner won the pidfile race ($($_.Exception.Message)). This process should abort or retry."
        if ($startTmp -and (Test-Path -LiteralPath $startTmp)) {
            Remove-Item -LiteralPath $startTmp -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
    if ($startTmp -and (Test-Path -LiteralPath $startTmp)) {
        try {
            Move-Item -LiteralPath $startTmp -Destination $RunnerStartFile -Force -ErrorAction Stop
        } catch {
            Write-Verbose "Could not rename runner.start tmp into place (non-fatal; identity fallback will use cmdline regex): $($_.Exception.Message)"
            Remove-Item -LiteralPath $startTmp -Force -ErrorAction SilentlyContinue
        }
    }
    return $true
}

Export-ModuleMember -Function Get-RunnerInstanceState, Stop-StaleRunner, Write-RunnerPidFile
