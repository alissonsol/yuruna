<#PSScriptInfo
.VERSION 2026.06.19
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
    # $using: pulls $RuntimeDir/$thresholdSec/$PollSeconds straight from the
    # enclosing scope at job-dispatch time. Cleaner than param() +
    # -ArgumentList, and dodges a PSSA false-positive where the rule
    # PSUseUsingScopeModifierInNewRunspaces misreads the scriptblock's
    # own param() declarations as undeclared references.
    return Start-Job -Name 'yurunaWatchdog' -ScriptBlock {
        $runtimeDir   = $using:RuntimeDir
        $thresholdSec = $using:thresholdSec
        $pollSec      = $using:PollSeconds
        $stepHbFile = Join-Path $runtimeDir 'runner.stepHeartbeat'
        $pidFile    = Join-Path $runtimeDir 'inner.pid'
        $outerLog   = Join-Path $runtimeDir 'outer.log'
        # Wait briefly for the inner to publish inner.pid + the first
        # heartbeat. 60 s upper bound: if neither file appears, log and
        # exit without killing anything -- preferable to picking a PID
        # blindly. The outer wipes both files before spawning the inner
        # so a stale copy from the previous cycle can't short-circuit
        # this wait.
        $waitUntil = (Get-Date).AddSeconds(60)
        while (-not (Test-Path $pidFile) -and (Get-Date) -lt $waitUntil) {
            Start-Sleep -Seconds 2
        }
        if (-not (Test-Path $pidFile)) {
            Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] inner.pid never appeared in 60s; exiting watchdog without action."
            return
        }
        $innerPid = 0
        try { $innerPid = [int]((Get-Content -LiteralPath $pidFile -Raw).Trim()) } catch { $innerPid = 0 }
        if (-not $innerPid) {
            Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] inner.pid present but unreadable; exiting watchdog without action."
            return
        }
        Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] armed: innerPid=$innerPid thresholdSec=$thresholdSec pollSec=$pollSec signal=runner.stepHeartbeat"
        while ($true) {
            Start-Sleep -Seconds $pollSec
            if (-not (Get-Process -Id $innerPid -ErrorAction SilentlyContinue)) {
                Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] inner pid $innerPid exited normally; watchdog disarming."
                return
            }
            if (-not (Test-Path $stepHbFile)) { continue }
            $age = ((Get-Date) - (Get-Item -LiteralPath $stepHbFile).LastWriteTime).TotalSeconds
            if ($age -gt $thresholdSec) {
                Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] step heartbeat stale $([int]$age)s > $thresholdSec s; killing inner PID $innerPid"
                Stop-Process -Id $innerPid -Force -ErrorAction SilentlyContinue
                return
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

Export-ModuleMember -Function Start-Watchdog, Stop-Watchdog
