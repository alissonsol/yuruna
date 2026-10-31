<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42bf60de-1efd-47a3-9c1c-7472978c1c6d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner heartbeat watchdog
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
    Process-level heartbeat timer for the single-cycle inner runner.
.DESCRIPTION
    Touches runner.heartbeat on a fixed period from a threadpool thread
    (System.Threading.Timer), NOT a Register-ObjectEvent action, so the
    heartbeat keeps advancing even when the runspace thread is blocked inside
    a long SSH call / Wait-Job / OCR pass. The callback is a compiled .NET
    method, not a PowerShell scriptblock cast to [TimerCallback] -- the
    scriptblock path goes through ScriptBlock.GetContextFromTLS() which throws
    PSInvalidOperationException ("There is no Runspace available...") on the
    threadpool thread that fires the timer.

    runner.heartbeat proves only that the PROCESS is alive, and no decision
    reads it. The watchdog judges the inner by runner.stepHeartbeat, which the
    runspace itself touches as work completes: stale beyond the step bound
    means the inner is wedged and gets killed. Write-RunnerStepHeartbeat is
    that file's one writer, so a write that keeps failing is counted and
    reported there before it can read as a wedge.
#>

# Compile the timer helper once per process. The [type] guard makes the
# -Force re-import the Inner module set performs each cycle a no-op (the type
# persists in the AppDomain), so re-import never throws "type already exists".
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
if (-not ('Yuruna.HeartbeatWriter' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Threading;
namespace Yuruna {
    public static class HeartbeatWriter {
        private static Timer _timer;
        private static string _path;
        // A failed tick is recorded in a sibling `.errors.log` (at most
        // once a minute) so a post-hoc reader sees the error class. The
        // watchdog does not read this file, so its failures are a
        // diagnostic only; runner.stepHeartbeat failures are reported by
        // Write-RunnerStepHeartbeat.
        private static long _consecutiveErrors = 0;
        private static DateTime _lastErrorLogUtc = DateTime.MinValue;
        public static long ConsecutiveErrors { get { return _consecutiveErrors; } }
        public static void Start(string path, int dueMs, int periodMs) {
            _path = path;
            _timer = new Timer(Tick, null, dueMs, periodMs);
        }
        public static void Stop() {
            if (_timer != null) { _timer.Dispose(); _timer = null; }
        }
        private static void Tick(object state) {
            try {
                File.WriteAllText(_path, DateTime.UtcNow.ToString("o"));
                _consecutiveErrors = 0;
            } catch (Exception ex) {
                // Disk full / AV write-lock / network share gone. The
                // next tick may recover. We surface the failure in two
                // ways without flooding the disk:
                //   * Increment a static counter the main runspace can
                //     poll (Get-RunnerHeartbeatError below).
                //   * Append at most one line per minute to a sibling
                //     `<path>.errors.log` so a post-hoc operator sees
                //     the underlying error class (vs. just "stale").
                _consecutiveErrors++;
                try {
                    DateTime now = DateTime.UtcNow;
                    if ((now - _lastErrorLogUtc).TotalSeconds >= 60.0) {
                        _lastErrorLogUtc = now;
                        string errPath = _path + ".errors.log";
                        string line = now.ToString("o") + " consecutive=" + _consecutiveErrors + " " + ex.GetType().Name + ": " + ex.Message + System.Environment.NewLine;
                        File.AppendAllText(errPath, line);
                    }
                } catch { /* throttle write itself failed -- nothing
                             reasonable to do from a threadpool thread */ }
            }
        }
    }
}
"@
}

# Module-scoped so Stop-RunnerHeartbeat is idempotent and the entry point does
# not have to track the started state itself.
$script:HeartbeatStarted = $false

function Start-RunnerHeartbeat {
    <#
    .SYNOPSIS
        Seed the heartbeat file and start the background timer.
    .PARAMETER Path
        runner.heartbeat path the timer touches each period.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Starts a fire-and-forget process-local timer in the runner; there is no externally observable state worth gating with -WhatIf.')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$DueMs    = 30000,
        [int]$PeriodMs = 30000
    )
    # Seed once so the first watchdog poll sees a fresh mtime before the
    # timer's first tick fires (dueMs out).
    try {
        [System.IO.File]::WriteAllText($Path, [DateTime]::UtcNow.ToString('o'))
    } catch {
        Write-Verbose "Could not seed heartbeat file '$Path' (non-fatal): $($_.Exception.Message)"
    }
    try {
        [Yuruna.HeartbeatWriter]::Start($Path, $DueMs, $PeriodMs)
        $script:HeartbeatStarted = $true
    } catch {
        $script:HeartbeatStarted = $false
        Write-Verbose "Could not start heartbeat timer (non-fatal): $($_.Exception.Message)"
    }
}

function Stop-RunnerHeartbeat {
    <#
    .SYNOPSIS
        Dispose the heartbeat timer. Idempotent; safe to call when never started.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Disposes a process-local timer; there is no externally observable state to gate with -WhatIf, and it runs unconditionally in the inner runner exit path.')]
    param()
    try { [Yuruna.HeartbeatWriter]::Stop() } catch { $null = $_ }
    $script:HeartbeatStarted = $false
}

# Consecutive runner.stepHeartbeat write failures, and when one was last
# reported. Per process: the inner is fresh per cycle.
$script:StepHeartbeatConsecutiveErrors = 0
$script:StepHeartbeatLastReportUtc = [DateTime]::MinValue
# The preamble phase this process is in and when it began, so the next
# Write-RunnerPhase (or Clear-RunnerPhase) can time it.
$script:OpenRunnerPhase = $null

function Close-RunnerPhaseTiming {
    <#
    .SYNOPSIS
        Write the duration row of the open preamble phase, if any.
    .DESCRIPTION
        Through Test.Perf's Write-PerfPhaseRow when the process has it; a
        phase closed before Test.Perf is loaded is dropped, never a failure.
    #>
    [CmdletBinding()]
    param()
    $open = $script:OpenRunnerPhase
    $script:OpenRunnerPhase = $null
    if (-not $open) { return }
    if (-not (Get-Command -Name Write-PerfPhaseRow -ErrorAction SilentlyContinue)) { return }
    try {
        Write-PerfPhaseRow -Phase $open.Phase -StartedAtUtc $open.StartedUtc -EndedAtUtc ([DateTime]::UtcNow) -Scope preamble
    } catch {
        Write-Verbose "Close-RunnerPhaseTiming: $($_.Exception.Message)"
    }
}

function Get-RunnerHeartbeatError {
    <#
    .SYNOPSIS
        Consecutive runner.stepHeartbeat write failures (disk full, a write
        lock). A non-zero value pinpoints a stale heartbeat as a write problem
        rather than a wedged runspace.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param()
    return [long]$script:StepHeartbeatConsecutiveErrors
}

function Write-RunnerPhase {
    <#
    .SYNOPSIS
        Mark the inner runner as inside a named PREAMBLE phase -- the stretch
        between process start and the first sequence step -- and refresh
        runner.stepHeartbeat in the same call.
    .DESCRIPTION
        The presence of runner.phase is the watchdog's signal to apply the
        SHORT preamble bound instead of testCycle.stepTimeoutSeconds. Nothing
        the runner does before its first step is legitimately slow, so a stall
        there is a wedged runner -- an unanswerable sudo / credential prompt is
        the motivating case -- and spending the full 45-minute step budget to
        notice leaves the host GREEN on the dashboard while nothing advances.

        Callers MUST Clear-RunnerPhase before any legitimately long stretch
        (the weekly base-image download) and before handing off to the
        sequence. Absence restores the stepTimeoutSeconds behavior, so a
        forgotten clear is never worse than not calling this at all -- the
        failure direction is deliberately toward the looser bound.

        Best-effort throughout: a liveness marker that cannot be written must
        never fail a cycle. A missing runner.phase costs only the tighter bound.
    .PARAMETER Phase
        Short label for the phase. Surfaced in the watchdog's kill line, so it
        should name the work an operator would need to look at.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes a runner-local liveness marker consumed by the outer watchdog; there is no operator-visible state worth gating with -WhatIf, and it runs unconditionally on the inner startup path.')]
    param([Parameter(Mandatory)][string]$Phase)
    if (-not $env:YURUNA_RUNTIME_DIR) { return }
    # Each phase is timed from its Write-RunnerPhase to the next one (or to
    # Clear-RunnerPhase), so a preamble that grows slower names the phase.
    Close-RunnerPhaseTiming
    $script:OpenRunnerPhase = @{ Phase = $Phase; StartedUtc = [DateTime]::UtcNow }
    try {
        [System.IO.File]::WriteAllText((Join-Path $env:YURUNA_RUNTIME_DIR 'runner.phase'), $Phase)
    } catch {
        Write-Verbose "Write-RunnerPhase('$Phase') failed (non-fatal): $($_.Exception.Message)"
    }
    Write-RunnerStepHeartbeat -RuntimeDir $env:YURUNA_RUNTIME_DIR
    # The next attempt overwrites runner.phase; retain the transition timeline
    # independently so an earlier watchdog kill remains attributable.
    try {
        $stamp = [DateTime]::UtcNow.ToString('o')
        $line = "$stamp [inner phase] pid=$PID generation=$env:YURUNA_CYCLE_GENERATION phase=$Phase"
        [IO.File]::AppendAllText((Join-Path $env:YURUNA_RUNTIME_DIR 'outer.log'), $line + [Environment]::NewLine)
    } catch {
        Write-Verbose "Write-RunnerPhase('$Phase') timeline unavailable (non-fatal): $($_.Exception.Message)"
    }
}

# --- REGION: Write-RunnerStepHeartbeat
function Write-RunnerStepHeartbeat {
    <#
    .SYNOPSIS
        Report completed work from the runner's active runspace.
    .DESCRIPTION
        Called after a step boundary or a completed control poll. A background
        timer must never call this: a blocked probe or an abandoned hold must
        still age out under the watchdog's normal bound.

        The one writer of runner.stepHeartbeat, the file the watchdog judges
        the inner by. A failed write is counted (Get-RunnerHeartbeatError),
        and at most once a minute it is reported as a warning and appended to
        a sibling `.errors.log`: unreported, a full disk or a write lock reads
        as a wedged runspace and the watchdog kills a healthy cycle.
    .PARAMETER RuntimeDir
        Directory holding the runner's progress heartbeat.
    .PARAMETER Path
        The heartbeat file itself, for a caller that already holds its path.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Updates a runner-local liveness marker; gating this telemetry write would manufacture a stalled runspace.')]
    param([string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR, [string]$Path)
    # Chaos tests only (Test.FaultInjection): hang here and the step stops reporting.
    if ($env:YURUNA_FAULT_POINTS) { Import-Module (Join-Path $PSScriptRoot 'Test.FaultInjection.psm1') -DisableNameChecking; Invoke-YurunaFaultPoint -Name 'step-heartbeat' }
    $target = $Path
    if (-not $target) {
        if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return }
        $target = Join-Path $RuntimeDir 'runner.stepHeartbeat'
    }
    try {
        [IO.File]::WriteAllText($target, [datetime]::UtcNow.ToString('o'))
        $script:StepHeartbeatConsecutiveErrors = 0
    } catch {
        $script:StepHeartbeatConsecutiveErrors++
        $now = [datetime]::UtcNow
        if (($now - $script:StepHeartbeatLastReportUtc).TotalSeconds -lt 60) { return }
        $script:StepHeartbeatLastReportUtc = $now
        $detail = "$($_.Exception.GetType().Name): $($_.Exception.Message)"
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.step_heartbeat_write_failed' -Arguments @{
            path = "$target"; count = "$($script:StepHeartbeatConsecutiveErrors)"; detail = $detail })
        try {
            [IO.File]::AppendAllText("$target.errors.log", "$($now.ToString('o')) consecutive=$($script:StepHeartbeatConsecutiveErrors) $detail" + [Environment]::NewLine)
        } catch {
            Write-Verbose "Write-RunnerStepHeartbeat: error log unavailable: $($_.Exception.Message)"
        }
    }
}

function Clear-RunnerPhase {
    <#
    .SYNOPSIS
        Drop runner.phase so the watchdog reverts to the full
        testCycle.stepTimeoutSeconds bound, and start that bound with a fresh
        runner.stepHeartbeat.
    .DESCRIPTION
        Called once, at the handoff into the cycle body -- the single boundary
        past which a long wait becomes legitimate. That one call dominates
        BOTH long stretches: the weekly base-image refresh (a multi-GB
        download that never touches the step heartbeat) and the sequence
        itself, where Invoke-Sequence takes over touching it per step. There
        is deliberately no second call site inside Get-Image; this one runs
        before it.

        Because it is the only clear, it has to be reliable rather than
        best-effort -- hence the verified, retried delete below. The heartbeat
        refresh matters too: without it the long phase would inherit whatever
        age the preamble left behind and could trip the restored bound early.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Removes a runner-local liveness marker consumed by the outer watchdog; there is no operator-visible state worth gating with -WhatIf.')]
    param()
    Close-RunnerPhaseTiming
    if (-not $env:YURUNA_RUNTIME_DIR) { return }
    $phasePath = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.phase'
    # See https://yuruna.link/4213a0b3-00e0
    for ($attempt = 0; $attempt -lt 5 -and (Test-Path -LiteralPath $phasePath); $attempt++) {
        Remove-Item -LiteralPath $phasePath -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $phasePath) { Start-Sleep -Milliseconds 200 }
    }
    if (Test-Path -LiteralPath $phasePath) {
        # Warning, not Verbose: this is the difference between a 2700 s and a
        # 600 s bound for the rest of the cycle, so it must be visible at the
        # default log level rather than surfacing later as an inexplicable kill.
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_8f0e63efce713f70')
    }
    # Only now refresh the heartbeat, so the restored bound starts from a fresh
    # timestamp. Nothing follows it, so a failed write can no longer skip
    # anything; the writer reports it.
    Write-RunnerStepHeartbeat -RuntimeDir $env:YURUNA_RUNTIME_DIR
}

Export-ModuleMember -Function Start-RunnerHeartbeat, Stop-RunnerHeartbeat, Get-RunnerHeartbeatError, Write-RunnerPhase, Clear-RunnerPhase, Write-RunnerStepHeartbeat
