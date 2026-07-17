<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42d4e5f6-a7b8-4c91-9234-5d6e7f8a9b0c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner watchdog
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
    Out-of-process step-heartbeat watchdog for the inner test runner.
.DESCRIPTION
    Lives outside the outer's pipeline thread (Start-Job, own pwsh)
    because the outer is blocked inside the call-operator wait that
    spawns the inner -- an in-runspace monitor (Register-ObjectEvent
    action, runspace timer, ThreadJob piped through the same
    runspace) can't pump while we wait. Start-Job is heavier but its
    child pwsh is independent, so it fires reliably even when the
    outer is completely wedged on the call-op.

    The watchdog polls runner.stepHeartbeat (NOT runner.heartbeat):
    the legacy heartbeat is written by a System.Threading.Timer on a
    threadpool thread that keeps ticking even when the runspace is
    deadlocked inside a never-terminating OCR / SSH / virsh loop.
    runner.stepHeartbeat is touched by Invoke-Sequence at the top of
    each step iteration from the runspace thread itself, so it goes
    stale iff that thread is genuinely wedged. See
    [[feedback_threadpool_heartbeat_watchdog_blind]] for the trap class.
#>

function Get-WatchdogInnerIdentityScript {
<#
.SYNOPSIS
    The PID-identity predicate the watchdog uses to tell the armed inner apart from
    an unrelated process that later reused its PID, returned as source text.
.DESCRIPTION
    The watchdog runs as a separate-process Start-Job that cannot see this module's
    functions, so the check is handed over as text and rebuilt inside the job via
    [scriptblock]::Create -- the tests build it from the SAME text, so there is one
    definition. The predicate is true only when a live process at $ProcId has a
    StartTime matching the UTC-ISO timestamp captured when the watchdog armed. A
    gone PID, an unreadable start, or an empty recorded start (identity unprovable)
    is treated as not-the-same-inner, matching the live-PID + matching-StartTime
    precedence the pool storage/push forwarders use to survive OS PID reuse.
.OUTPUTS
    [string] the identity-check scriptblock body: param([int]$ProcId,[string]$ExpectedStartUtc) -> [bool].
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return @'
param([int]$ProcId, [string]$ExpectedStartUtc)
if (-not $ExpectedStartUtc) { return $false }
try { $s = (Get-Process -Id $ProcId -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') } catch { return $false }
return ($s -eq $ExpectedStartUtc)
'@
}

function Start-Watchdog {
    <#
    .SYNOPSIS
        Arm a step-heartbeat watchdog Start-Job that kills the inner
        runner if runner.stepHeartbeat goes stale past the threshold.
    .PARAMETER StepTimeoutMinutes
        Upper bound on how long a single step (or any other slice of
        inner-runner work) may run without refreshing
        runner.stepHeartbeat. The watchdog logs to runtime/outer.log
        when it disarms or kills.
    .PARAMETER RuntimeDir
        Absolute path to YURUNA_RUNTIME_DIR. The watchdog reads
        runner.stepHeartbeat + inner.pid from here and appends to
        outer.log.
    .PARAMETER PollSeconds
        Sleep between heartbeat-staleness checks (typical: 30).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Management.Automation.Job])]
    # PSReviewUnusedParameter on PollSeconds is a known false-positive:
    # the parameter IS read via $using:PollSeconds inside the Start-Job
    # scriptblock below, but PSSA's static analysis doesn't follow $using:
    # references back to the enclosing function's param block.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PollSeconds')]
    param(
        [Parameter(Mandatory)][int]$StepTimeoutMinutes,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][int]$PollSeconds
    )
    if (-not $PSCmdlet.ShouldProcess("watchdog job for $RuntimeDir (threshold ${StepTimeoutMinutes}m)", 'Start-Job')) { return $null }
    $thresholdSec = $StepTimeoutMinutes * 60
    # The identity predicate is captured as source text and rebuilt inside the job
    # (a separate-process Start-Job cannot see this module's functions), so the
    # tests and the watchdog exercise one definition.
    $innerIdentityScript = Get-WatchdogInnerIdentityScript
    # $using: pulls $RuntimeDir/$thresholdSec/$PollSeconds straight from the
    # enclosing scope at job-dispatch time. Cleaner than param() +
    # -ArgumentList, and dodges a PSSA false-positive where the rule
    # PSUseUsingScopeModifierInNewRunspaces misreads the scriptblock's
    # own param() declarations as undeclared references.
    return Start-Job -Name 'yurunaWatchdog' -ScriptBlock {
        $runtimeDir   = $using:RuntimeDir
        $thresholdSec = $using:thresholdSec
        $pollSec      = $using:PollSeconds
        # Rebuild the shared identity predicate in this separate-process job.
        $sameInner    = [scriptblock]::Create($using:innerIdentityScript)
        $stepHbFile = Join-Path $runtimeDir 'runner.stepHeartbeat'
        $pidFile    = Join-Path $runtimeDir 'inner.pid'
        $outerLog   = Join-Path $runtimeDir 'outer.log'
        # Any early exit below leaves the cycle running UNGUARDED, and the
        # outer is already blocked on the call-op with no live view of this
        # job -- so every lapse must leave a durable sentinel the outer
        # surfaces when it regains control, in addition to the log line.
        $lapseFile = Join-Path $runtimeDir 'runner.watchdog.lapsed'
        $reportLapse = {
            param([string]$Why)
            Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] $Why; exiting watchdog without action -- CYCLE RUNS UNGUARDED."
            Set-Content -LiteralPath $lapseFile -Value "$((Get-Date).ToString('o')) $Why" -ErrorAction SilentlyContinue
        }
        # Wait for the inner to publish inner.pid + the first heartbeat.
        # 180 s upper bound: a loaded host can take well past a minute to
        # spawn pwsh and import the runner modules, and a premature
        # give-up here runs the whole cycle unguarded, while a longer
        # wait costs nothing (the job just idles). If the file still
        # never appears, log and exit without killing anything --
        # preferable to picking a PID blindly. The outer wipes both files
        # before spawning the inner so a stale copy from the previous
        # cycle can't short-circuit this wait.
        $waitUntil = (Get-Date).AddSeconds(180)
        while (-not (Test-Path $pidFile) -and (Get-Date) -lt $waitUntil) {
            Start-Sleep -Seconds 2
        }
        if (-not (Test-Path $pidFile)) {
            & $reportLapse 'inner.pid never appeared in 180s'
            return
        }
        $innerPid = 0
        try { $innerPid = [int]((Get-Content -LiteralPath $pidFile -Raw).Trim()) } catch { $innerPid = 0 }
        if (-not $innerPid) {
            & $reportLapse 'inner.pid present but unreadable'
            return
        }
        # Capture the inner's identity (PID + StartTime) at arm so a later PID reuse
        # can't fool the disarm/kill decisions below. Get-Process can fail
        # transiently on a loaded host for reasons other than process-gone,
        # so probe a few times before concluding there is nothing to guard.
        $innerStartUtc = $null
        for ($armProbe = 0; $armProbe -lt 3 -and -not $innerStartUtc; $armProbe++) {
            $innerStartUtc = try { (Get-Process -Id $innerPid -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') } catch { $null }
            if (-not $innerStartUtc) { Start-Sleep -Seconds 2 }
        }
        if (-not $innerStartUtc) {
            & $reportLapse "inner pid $innerPid not present/readable at arm (3 probes)"
            return
        }
        # Confirmation wrapper around the identity predicate for the
        # NEGATIVE direction only: the predicate reports a transient
        # Get-Process failure and a genuinely gone/reused PID identically
        # (both false), and acting on a single false reading permanently
        # disarms hang protection for the rest of the cycle. Require the
        # negative to hold across three spaced probes before treating the
        # inner as gone; a single positive reading short-circuits.
        $sameInnerConfirmedGone = {
            param([int]$ProcId, [string]$ExpectedStartUtc)
            for ($goneProbe = 0; $goneProbe -lt 3; $goneProbe++) {
                if (& $sameInner $ProcId $ExpectedStartUtc) { return $false }
                Start-Sleep -Seconds 5
            }
            return $true
        }
        Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] armed: innerPid=$innerPid startUtc=$innerStartUtc thresholdSec=$thresholdSec pollSec=$pollSec signal=runner.stepHeartbeat"
        # Arm timestamp: when no step heartbeat has been published yet, staleness is aged from
        # here so a hang BEFORE the first step write is still detected (not ignored forever).
        $armedAt = Get-Date
        while ($true) {
            Start-Sleep -Seconds $pollSec
            if (& $sameInnerConfirmedGone $innerPid $innerStartUtc) {
                # PID gone, or a different process now holds it (reused), confirmed
                # across spaced probes: either way the armed inner is no longer
                # running, so disarm without touching the PID.
                Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] inner pid $innerPid no longer matches the armed identity (exited or PID reused; confirmed); watchdog disarming."
                return
            }
            try {
                if (Test-Path $stepHbFile) {
                    $age = ((Get-Date) - (Get-Item -LiteralPath $stepHbFile).LastWriteTime).TotalSeconds
                } else {
                    # No step heartbeat file yet -> age from arm time so a never-published heartbeat
                    # (inner wedged before its first step write) is treated as stale past the threshold.
                    $age = ((Get-Date) - $armedAt).TotalSeconds
                }
            } catch {
                # A transient read failure (file replaced between Test-Path and
                # Get-Item, AV lock) must not crash the job -- a dead watchdog
                # is a silent unguarded cycle. Treat as not-stale this poll.
                continue
            }
            if ($age -gt $thresholdSec) {
                # Re-verify identity immediately before the kill: between the disarm
                # check above and here the inner could have exited and its PID been
                # reused, and killing the wrong process is worse than a missed kill.
                if (& $sameInner $innerPid $innerStartUtc) {
                    Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] step heartbeat stale $([int]$age)s > $thresholdSec s; killing inner PID $innerPid and its descendants"
                    # Kill the whole tree, not just the inner pwsh: a wedged
                    # step usually has live children (console capture, OCR,
                    # ssh) that would otherwise orphan, keep handles open,
                    # and confuse the next cycle's process discovery.
                    if ($IsWindows) {
                        & taskkill /PID $innerPid /T /F 2>$null | Out-Null
                        # Backstop when taskkill is unavailable or failed;
                        # a still-live root is worse than orphaned leaves.
                        Stop-Process -Id $innerPid -Force -ErrorAction SilentlyContinue
                    } else {
                        $childrenOf = @{}
                        foreach ($row in @(& /bin/ps -eo pid=,ppid= 2>$null)) {
                            $parts = -split "$row"
                            if ($parts.Count -eq 2) {
                                $childrenOf[[int]$parts[1]] = @($childrenOf[[int]$parts[1]]) + [int]$parts[0]
                            }
                        }
                        $doomed = [System.Collections.Generic.List[int]]::new()
                        $queue  = [System.Collections.Generic.Queue[int]]::new()
                        $queue.Enqueue($innerPid)
                        while ($queue.Count -gt 0) {
                            $cur = $queue.Dequeue()
                            $doomed.Add($cur)
                            foreach ($kid in @($childrenOf[$cur])) {
                                if ($kid) { $queue.Enqueue($kid) }
                            }
                        }
                        # Leaves first so a dying parent can't respawn or
                        # reparent work mid-sweep; the root goes last.
                        for ($di = $doomed.Count - 1; $di -ge 0; $di--) {
                            Stop-Process -Id $doomed[$di] -Force -ErrorAction SilentlyContinue
                        }
                    }
                    return
                }
                if (& $sameInnerConfirmedGone $innerPid $innerStartUtc) {
                    Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] step heartbeat stale but inner PID $innerPid no longer matches the armed identity (exited or PID reused; confirmed); disarming without kill."
                    return
                }
                # Identity probe failed transiently while the heartbeat is
                # stale: neither kill (might not be our process) nor disarm
                # (might still be our wedged inner). Keep polling.
                Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] step heartbeat stale $([int]$age)s but identity probe is transiently failing; retrying next poll."
            }
        }
    }
}

function Stop-Watchdog {
    <#
    .SYNOPSIS
        Tear down a watchdog job returned by Start-Watchdog.
    .DESCRIPTION
        Safe to call with $null (returns silently); safe to call after
        the watchdog has already exited (Stop-Job / Remove-Job are
        SilentlyContinue).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param($Job)
    if (-not $Job) { return }
    if (-not $PSCmdlet.ShouldProcess($Job.Name, 'Stop-Job/Remove-Job')) { return }
    Stop-Job  -Job $Job -ErrorAction SilentlyContinue
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Get-WatchdogInnerIdentityScript, Start-Watchdog, Stop-Watchdog
