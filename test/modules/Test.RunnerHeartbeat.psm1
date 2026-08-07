<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42f3718d-4e5f-4061-9b72-8d9e0f1a2b3c
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

    The outer watchdog reads runner.heartbeat's mtime: stale beyond
    testCycle.stepTimeoutSeconds means the inner is wedged and gets killed.
    runner.heartbeat proves the PROCESS is alive; the in-runspace
    runner.stepHeartbeat (touched per step by Invoke-Sequence) proves the
    RUNSPACE is alive -- the two are complementary and the watchdog uses the
    step file to catch hangs the threadpool heartbeat cannot.
#>

# Compile the timer helper once per process. The [type] guard makes the
# -Force re-import the Inner module set performs each cycle a no-op (the type
# persists in the AppDomain), so re-import never throws "type already exists".
if (-not ('Yuruna.HeartbeatWriter' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Threading;
namespace Yuruna {
    public static class HeartbeatWriter {
        private static Timer _timer;
        private static string _path;
        // Silent error-swallowing here would let a disk-full condition
        // stay invisible until the watchdog killed the inner as
        // "stale". These two fields surface persistent failures via
        // a sibling `.errors.log` AND expose the counter to the main
        // runspace (Get-RunnerHeartbeatError) so a Wait-For-Text observer
        // can flag the degraded state.
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
    if ($script:HeartbeatStarted) {
        try { [Yuruna.HeartbeatWriter]::Stop() } catch { $null = $_ }
        $script:HeartbeatStarted = $false
    }
}

function Get-RunnerHeartbeatError {
    <#
    .SYNOPSIS
        Consecutive heartbeat-write failures (disk full / AV write-lock). A
        non-zero value pinpoints a degraded heartbeat as a write problem rather
        than a wedged runspace.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param()
    try { return [long]([Yuruna.HeartbeatWriter]::ConsecutiveErrors) }
    catch { return [long]0 }
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
        sequence. Absence restores the stepTimeoutSeconds behaviour, so a
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
    try {
        [System.IO.File]::WriteAllText((Join-Path $env:YURUNA_RUNTIME_DIR 'runner.phase'), $Phase)
        [System.IO.File]::WriteAllText((Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'), [DateTime]::UtcNow.ToString('o'))
    } catch {
        Write-Verbose "Write-RunnerPhase('$Phase') failed (non-fatal): $($_.Exception.Message)"
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
    if (-not $env:YURUNA_RUNTIME_DIR) { return }
    $phasePath = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.phase'
    # The delete goes FIRST, and it is verified and retried. Two reasons, and
    # this is the one place in the module where a best-effort file operation
    # would otherwise fail toward the TIGHT bound:
    #
    #  * Ordering. A .NET exception is TERMINATING in PowerShell, so if the
    #    stepHeartbeat write below sat ahead of this and threw (disk full, an
    #    AV/backup handle -- the failure class the heartbeat timer's own catch
    #    block already exists for), control would jump past the delete and the
    #    marker would survive into the cycle.
    #  * Contention. The watchdog polls the marker with Get-Content, whose
    #    handle is taken without FILE_SHARE_DELETE, so a Remove-Item landing in
    #    that window fails -- and -ErrorAction SilentlyContinue makes it a
    #    non-terminating error the try/catch never sees. That handle lives
    #    microseconds against a multi-second poll, so one retry effectively
    #    always wins.
    #
    # Either miss would leave the 600 s preamble bound in force over the whole
    # cycle and false-kill the weekly base-image download at ~10 minutes.
    for ($attempt = 0; $attempt -lt 5 -and (Test-Path -LiteralPath $phasePath); $attempt++) {
        Remove-Item -LiteralPath $phasePath -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $phasePath) { Start-Sleep -Milliseconds 200 }
    }
    if (Test-Path -LiteralPath $phasePath) {
        # Warning, not Verbose: this is the difference between a 2700 s and a
        # 600 s bound for the rest of the cycle, so it must be visible at the
        # default log level rather than surfacing later as an inexplicable kill.
        Write-Warning "Clear-RunnerPhase: runner.phase survived removal; the tight preamble watchdog bound will apply to this cycle's steps."
    }
    # Only now refresh the heartbeat, so the restored bound starts from a fresh
    # timestamp. Its own try/catch: nothing follows it, so a failure here can no
    # longer skip anything, and it lands on the loose-bound side either way.
    try {
        [System.IO.File]::WriteAllText((Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'), [DateTime]::UtcNow.ToString('o'))
    } catch {
        Write-Verbose "Clear-RunnerPhase: stepHeartbeat refresh failed (non-fatal): $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Start-RunnerHeartbeat, Stop-RunnerHeartbeat, Get-RunnerHeartbeatError, Write-RunnerPhase, Clear-RunnerPhase
