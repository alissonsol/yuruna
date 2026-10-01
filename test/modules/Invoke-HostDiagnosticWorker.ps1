<#PSScriptInfo
.VERSION 2026.09.30
.GUID 427e5cfa-1fd6-4fde-89f5-c7a1f409aa07
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna status service host diagnostic worker detached
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
    Detached worker behind /control/host-diagnostic: runs the host diagnostic
    once, under a bound, and leaves the report where the listener serves it.

.DESCRIPTION
    The status listener handles one request at a time, and the diagnostic
    script reaches system_profiler, scutil, lsof, helm, the hypervisor client
    and more -- any one of which can take minutes or never return. Run inside
    the listener, one slow call would park every route, including the read-only
    status pages an operator uses to see whether the host is alive at all. The
    listener only launches this worker and answers "pending" until the
    worker's state file says the run finished.

    Single flight: the worker takes the directory's lock without waiting, and
    a second worker that finds it held exits at once and writes nothing, so a
    burst of requests runs the diagnostic once.

    Everything it writes stays in the private worker directory: the running
    and terminal state (state.json) and the report (result.txt), each replaced
    atomically. The report is never written under the served runtime or log
    directories.

    Exit codes: 0 when the run completed (or another worker already holds the
    run), 1 when it failed or was refused.

.PARAMETER RunId
    The run's id, a canonical lowercase UUID the listener minted. It names
    nothing on disk except through this validation.

.PARAMETER DiagnosticScriptPath
    The diagnostic script to run.

.PARAMETER WorkDirectory
    The private worker directory; must be the one the private state root
    resolves for host-diagnostic, or the worker refuses.

.PARAMETER WorkingDirectory
    The working directory the diagnostic runs in (the repository root).

.PARAMETER TimeoutSeconds
    Wall-clock bound for the whole diagnostic run.

.PARAMETER MaxReportChars
    Per-stream cap on the captured report.

.PARAMETER MaxReportBytes
    Cap on the stored report as UTF-8 bytes, truncation notice included. Two
    streams each under MaxReportChars can still exceed what the listener
    serves (4 MiB by default, the same value), and a report it cannot serve
    is one the caller never gets.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$DiagnosticScriptPath,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$WorkingDirectory,
    [ValidateRange(10, 900)][int]$TimeoutSeconds = 300,
    [ValidateRange(65536, 16777216)][int]$MaxReportChars = 4194304,
    [ValidateRange(65536, 16777216)][int]$MaxReportBytes = 4194304
)

$ErrorActionPreference = 'Stop'
# A detached worker has no console to answer a preview or confirmation; an
# inherited preview would make every write below a silent no-op.
$callerWhatIf = $WhatIfPreference
$WhatIfPreference = $false

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.SingleFlightLock.psm1') -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.InnerSpawn.psm1') -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.StatusControlRoute.psm1') -Global -Force -DisableNameChecking

function Write-HostDiagnosticState {
    <#
    .SYNOPSIS
        Replace the worker state file; a failed write is reported, never fatal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][System.Collections.IDictionary]$State)
    if (-not $PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'runner.status_worker_state_write_action'))) { return $false }
    $written = Write-YurunaStateFileJson -Path $Path -InputObject $State -Confirm:$false
    if (-not $written) { Write-Verbose "Invoke-HostDiagnosticWorker: state write to $Path failed." }
    return [bool]$written
}

function Limit-HostDiagnosticReport {
    <#
    .SYNOPSIS
        The report as stored: at most MaxReportBytes of UTF-8, ending with a
        truncation notice when either stream hit its cap or the whole had to
        be cut.
    .DESCRIPTION
        The cut is made on the encoded bytes and moved back to the start of
        the character it would split, so the stored text is valid UTF-8. The
        room kept for the notice is measured on the widest number it can
        carry, so the notice actually written always fits.
    .OUTPUTS
        [pscustomobject] @{ Text; Truncated }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Report,
        [switch]$StreamTruncated,
        [Parameter(Mandatory)][int]$MaxReportChars,
        [Parameter(Mandatory)][int]$MaxReportBytes
    )
    $encoding = [System.Text.UTF8Encoding]::new($false)
    if (-not $StreamTruncated -and $encoding.GetByteCount($Report) -le $MaxReportBytes) {
        return [pscustomobject]@{ Text = $Report; Truncated = $false }
    }
    $notice = { param([long]$Chars) "`n" + (Format-YurunaOperatorMessage -Key 'runner.host_diagnostic_worker_truncated' -Arguments @{ chars = $Chars }) + "`n" }
    $body = $Report.TrimEnd("`r", "`n")
    $keptChars = [long]$MaxReportChars
    $budget = $MaxReportBytes - $encoding.GetByteCount((& $notice ([long][int]::MaxValue)))
    $bytes = $encoding.GetBytes($body)
    if ($bytes.Length -gt $budget) {
        $cut = [Math]::Max(0, $budget)
        # Step back off UTF-8 continuation bytes (10xxxxxx) so the cut falls
        # between characters.
        while ($cut -gt 0 -and ($bytes[$cut] -band 0xC0) -eq 0x80) { $cut-- }
        $body = $encoding.GetString($bytes, 0, $cut)
        $keptChars = $body.Length
    }
    return [pscustomobject]@{ Text = ($body + (& $notice $keptChars)); Truncated = $true }
}

$exitCode = 1
$lock = $null
$state = $null
$statePath = $null
try {
    if ($RunId -cnotmatch '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.host_diagnostic_worker_refused' -Arguments @{ runId = '-'; reason = 'invalid_run_id' })
        exit 1
    }
    # The directory comes from the command line; accept it only when it is the
    # private directory this user's state root resolves, so a caller cannot
    # point the worker's writes somewhere else.
    $expected = Get-StatusWorkerDirectory -Name 'host-diagnostic' -Confirm:$false
    $given = [System.IO.Path]::GetFullPath($WorkDirectory).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $comparison = if ($IsLinux) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
    if (-not $expected.Resolved -or -not [string]::Equals([System.IO.Path]::GetFullPath($expected.Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar), $given, $comparison)) {
        $why = if ($expected.Resolved) { 'directory_mismatch' } else { "private_state_$(([string]$expected.Reason).Replace('-', '_'))" }
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.host_diagnostic_worker_refused' -Arguments @{ runId = $RunId; reason = $why })
        exit 1
    }
    $statePath = Join-Path $given 'state.json'
    $resultPath = Join-Path $given 'result.txt'

    $lock = Enter-YurunaSingleFlightLock -Path (Join-Path $given 'host-diagnostic.lock') -WaitMilliseconds 0 `
        -Metadata @{ purpose = 'host-diagnostic'; runId = $RunId }
    if (-not $lock.Held) {
        if ($lock.Reason -in @('held-elsewhere', 'held-by-this-process')) {
            Write-Verbose "Invoke-HostDiagnosticWorker: another run holds the diagnostic; this one writes nothing."
            $exitCode = 0
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.host_diagnostic_worker_refused' -Arguments @{ runId = $RunId; reason = ([string]$lock.Reason).Replace('-', '_') })
            $exitCode = 1
        }
        exit $exitCode
    }

    $startedUtc = [DateTime]::UtcNow
    $state = [ordered]@{
        schemaVersion = 1
        runId         = $RunId
        phase         = 'running'
        startedUtc    = $startedUtc.ToString('o')
        deadlineUtc   = $startedUtc.AddSeconds($TimeoutSeconds).ToString('o')
    }
    $null = Write-HostDiagnosticState -Path $statePath -State $state -Confirm:$false

    $reason = $null
    $timedOut = $false
    $truncated = $false
    $childExit = $null
    $report = ''
    if (-not [System.IO.File]::Exists($DiagnosticScriptPath)) {
        $reason = 'script_missing'
    } else {
        $pwsh = Get-PwshExePath
        if (-not $pwsh) { $pwsh = 'pwsh' }
        $run = Invoke-BoundedNativeCommand -FilePath $pwsh -TimeoutSeconds $TimeoutSeconds -MaxCapturedChars $MaxReportChars `
            -Environment @{ YURUNA_NONINTERACTIVE = '1' } `
            -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-WorkingDirectory', $WorkingDirectory, '-File', $DiagnosticScriptPath)
        $childExit = [int]$run.ExitCode
        $timedOut = [bool]$run.TimedOut
        $truncated = [bool]$run.OutputTruncated -or [bool]$run.DrainTimedOut -or [bool]$run.KillFailed
        $report = [string]$run.StdOut
        if (-not [string]::IsNullOrEmpty([string]$run.StdErr)) {
            $report = $report.TrimEnd("`r", "`n") + "`n" + [string]$run.StdErr
        }
        $limited = Limit-HostDiagnosticReport -Report $report -StreamTruncated:$truncated -MaxReportChars $MaxReportChars -MaxReportBytes $MaxReportBytes
        $truncated = [bool]$limited.Truncated
        $report = [string]$limited.Text
        if (-not $run.Started) { $reason = 'launch_failed' }
        elseif ($timedOut) { $reason = 'timeout' }
    }
    if (-not [string]::IsNullOrEmpty($report)) {
        if (-not (Write-YurunaStateFile -Path $resultPath -Content $report -Confirm:$false)) {
            $reason = if ($reason) { $reason } else { 'result_unwritable' }
        }
    } elseif (-not $reason) {
        if (-not (Write-YurunaStateFile -Path $resultPath -Content '' -Confirm:$false)) { $reason = 'result_unwritable' }
    }

    $state.phase = if ($reason) { 'failed' } else { 'completed' }
    $state.completedUtc = [DateTime]::UtcNow.ToString('o')
    $state.exitCode = $childExit
    $state.timedOut = $timedOut
    $state.truncated = $truncated
    $state.reason = $reason
    $null = Write-HostDiagnosticState -Path $statePath -State $state -Confirm:$false
    if ($reason) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.host_diagnostic_worker_failed' -Arguments @{ runId = $RunId; reason = $reason })
        $exitCode = 1
    } else {
        $exitCode = 0
    }
} catch {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.host_diagnostic_worker_failed' -Arguments @{ runId = $RunId; reason = 'internal_error' })
    Write-Verbose "Invoke-HostDiagnosticWorker: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    # A running state left behind would read as pending until its deadline;
    # say the run is over so the next request can start another.
    if ($null -ne $state -and $state.phase -eq 'running' -and $statePath) {
        $state.phase = 'failed'
        $state.completedUtc = [DateTime]::UtcNow.ToString('o')
        $state.reason = 'internal_error'
        try { $null = Write-HostDiagnosticState -Path $statePath -State $state -Confirm:$false } catch { Write-Verbose "Invoke-HostDiagnosticWorker: failure state not written: $($_.Exception.Message)" }
    }
    $exitCode = 1
} finally {
    if ($null -ne $lock -and $lock.Held) { Exit-YurunaSingleFlightLock -Lock $lock }
    $WhatIfPreference = $callerWhatIf
}
exit $exitCode
