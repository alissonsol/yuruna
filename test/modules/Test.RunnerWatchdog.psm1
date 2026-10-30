<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42547b68-a60f-4a35-be1d-21d02f08f7bf
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.SingleInstance.psm1') -DisableNameChecking


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
    stale iff that thread is genuinely wedged.

    Two bounds, selected by runner.phase (Write-RunnerPhase /
    Clear-RunnerPhase in Test.RunnerHeartbeat.psm1):

      runner.phase PRESENT -> PreambleTimeoutSeconds. The inner is still
        in its preamble (bootstrap, host detection, the caching-proxy
        gate and its port-map refresh, status-service start). None of
        that is legitimately slow, so the tight bound applies.
      runner.phase ABSENT  -> StepTimeoutSeconds. Either the inner cleared
        it for a legitimately long stretch (the weekly base-image
        download) or the sequence has taken over.

    Why the split: the inner SEEDS runner.stepHeartbeat at startup, so
    without the tighter bound the preamble is nominally guarded but
    effectively unguarded -- a preamble stall (the motivating case: a bare
    `sudo` prompting on the inherited terminal with nobody present) burns
    the full step budget while the dashboard still shows the previous
    cycle's green. Absence of runner.phase restores the plain
    step-timeout behavior, so the looser bound is always the failure
    direction.
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
    .PARAMETER StepTimeoutSeconds
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
    .PARAMETER PreambleTimeoutSeconds
        Tighter bound applied while runner.phase exists -- i.e. before the
        inner reaches its first sequence step. Defaults to 600 so an existing
        caller that has not been updated still gets the protection. Values <= 0
        disable the tighter bound (StepTimeoutSeconds everywhere) -- the
        documented escape hatch for a host whose preamble is genuinely slow.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Management.Automation.Job])]
    # PSReviewUnusedParameter on PollSeconds is a known false-positive:
    # the parameter IS read via $using:PollSeconds inside the Start-Job
    # scriptblock below, but PSSA's static analysis doesn't follow $using:
    # references back to the enclosing function's param block.
    # PreambleTimeoutSeconds needs no such suppression -- it is read directly
    # here (the collapse rule below), so PSSA sees the use.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PollSeconds')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CycleGeneration')]
    param(
        [Parameter(Mandatory)][int]$StepTimeoutSeconds,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][int]$PollSeconds,
        [Parameter()][int]$PreambleTimeoutSeconds = 600,
        [Parameter()][string]$CycleGeneration = ''
    )
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'runner.operator_f865490d58581482' -Arguments @{ runtimeDir = "$RuntimeDir"; stepTimeoutSeconds = "${StepTimeoutSeconds}"; preambleTimeoutSeconds = "${PreambleTimeoutSeconds}" }), 'Start-Job')) { return $null }
    $thresholdSeconds = $StepTimeoutSeconds
    # A preamble bound at or above the step bound buys nothing and a
    # non-positive one is the documented opt-out; both collapse to "no tighter
    # bound" so the job body has a single rule to apply.
    $preambleSeconds  = if ($PreambleTimeoutSeconds -gt 0 -and $PreambleTimeoutSeconds -lt $StepTimeoutSeconds) { $PreambleTimeoutSeconds } else { $StepTimeoutSeconds }
    # The identity predicate is captured as source text and rebuilt inside the job
    # (a separate-process Start-Job cannot see this module's functions), so the
    # tests and the watchdog exercise one definition.
    $innerIdentityScript = Get-WatchdogInnerIdentityScript
    # The same text Stop-YurunaProcessTree runs, for the same reason.
    $treeKillScript = Get-YurunaProcessTreeKillScript
    # $using: pulls $RuntimeDir/$thresholdSeconds/$PollSeconds straight from the
    # enclosing scope at job-dispatch time. Cleaner than param() +
    # -ArgumentList, and dodges a PSSA false-positive where the rule
    # PSUseUsingScopeModifierInNewRunspaces misreads the scriptblock's
    # own param() declarations as undeclared references.
    return Start-Job -Name 'yurunaWatchdog' -ScriptBlock {
        $runtimeDir   = $using:RuntimeDir
        $thresholdSeconds = $using:thresholdSeconds
        $preambleSeconds  = $using:preambleSeconds
        $pollSeconds      = $using:PollSeconds
        # Rebuild the shared identity predicate in this separate-process job.
        $sameInner    = [scriptblock]::Create($using:innerIdentityScript)
        $treeKill     = [scriptblock]::Create($using:treeKillScript)
        $stepHbFile = Join-Path $runtimeDir 'runner.stepHeartbeat'
        $phaseFile  = Join-Path $runtimeDir 'runner.phase'
        $pidFile    = Join-Path $runtimeDir 'inner.pid'
        $outerLog   = Join-Path $runtimeDir 'outer.log'
        # Any early exit below leaves this job unable to guard the cycle, and
        # the outer is already blocked on the call-op with no live view of it
        # -- so every lapse leaves a durable sentinel, in addition to the log
        # line. The resident runner reads it while the cycle runs and applies
        # these bounds itself; they ride in the sentinel because the pool's
        # overrides that shaped them are resolved only in this cycle process.
        $lapseFile = Join-Path $runtimeDir 'runner.watchdog.lapsed'
        $reportLapse = {
            param([string]$Why)
            Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] $Why; exiting watchdog without action -- the resident runner guards the cycle."
            Set-Content -LiteralPath $lapseFile -Value "$((Get-Date).ToString('o')) $Why [stepSeconds=$thresholdSeconds preambleSeconds=$preambleSeconds]" -ErrorAction SilentlyContinue
        }
        # See https://yuruna.link/4213a0b3-011c
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
        Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] armed: innerPid=$innerPid startUtc=$innerStartUtc thresholdSeconds=$thresholdSeconds preambleSeconds=$preambleSeconds pollSeconds=$pollSeconds signal=runner.stepHeartbeat"
        # Staleness is the heartbeat's age when this job first saw it, read once
        # in UTC, plus monotonic time since it last changed. Subtracting a local
        # mtime from Get-Date moved by an hour at each daylight-saving change, so
        # a healthy inner was killed in spring. With no heartbeat published yet,
        # the age runs from arm, so a hang before the first step is still caught.
        $staleWatch = [Diagnostics.Stopwatch]::StartNew()
        $hbSeenUtc = $null
        $hbAgeAtSeen = 0.0
        while ($true) {
            Start-Sleep -Seconds $pollSeconds
            if (& $sameInnerConfirmedGone $innerPid $innerStartUtc) {
                # PID gone, or a different process now holds it (reused), confirmed
                # across spaced probes: either way the armed inner is no longer
                # running, so disarm without touching the PID.
                Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] inner pid $innerPid no longer matches the armed identity (exited or PID reused; confirmed); watchdog disarming."
                return
            }
            # Pick the bound BEFORE reading the age, and read the phase every
            # poll rather than caching it: the inner clears runner.phase the
            # moment a legitimately long stretch begins, and a cached "still in
            # preamble" would kill it mid-download.
            $phase = $null
            try {
                if (Test-Path -LiteralPath $phaseFile) { $phase = "$(Get-Content -LiteralPath $phaseFile -Raw)".Trim() }
            } catch {
                # Unreadable phase marker -> fall through to the looser bound.
                # Guessing "preamble" here would kill a healthy long phase.
                $phase = $null
            }
            $effectiveThreshold = if ($phase) { $preambleSeconds } else { $thresholdSeconds }
            try {
                $hbUtc = if (Test-Path $stepHbFile) { (Get-Item -LiteralPath $stepHbFile).LastWriteTimeUtc } else { $null }
                if ($hbUtc -and $hbUtc -ne $hbSeenUtc) {
                    $hbAgeAtSeen = if ($null -eq $hbSeenUtc) { [math]::Max(0.0, ([datetime]::UtcNow - $hbUtc).TotalSeconds) } else { 0.0 }
                    $hbSeenUtc = $hbUtc
                    $staleWatch.Restart()
                }
                $age = $hbAgeAtSeen + $staleWatch.Elapsed.TotalSeconds
            } catch {
                # A transient read failure (file replaced between Test-Path and
                # Get-Item, AV lock) must not crash the job -- a dead watchdog
                # is a silent unguarded cycle. Treat as not-stale this poll.
                continue
            }
            if ($age -gt $effectiveThreshold) {
                # Re-verify identity immediately before the kill: between the disarm
                # check above and here the inner could have exited and its PID been
                # reused, and killing the wrong process is worse than a missed kill.
                if (& $sameInner $innerPid $innerStartUtc) {
                    # Name the phase in the kill line: "stale in preamble phase
                    # 'caching-proxy-gate'" points straight at the wedged work,
                    # where a bare step-timeout message sends the operator
                    # hunting through a cycle that never reached step 1.
                    $whereMsg = if ($phase) { "preamble phase '$phase' (bound ${preambleSeconds}s)" } else { "bound ${thresholdSeconds}s" }
                    Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] step heartbeat stale $([int]$age)s > $whereMsg; killing inner PID $innerPid and its descendants"
                    # Record the decision while the armed identity is still proven.
                    # A phase marker or old heartbeat alone cannot establish a kill.
                    $killRecord = [ordered]@{
                        schemaVersion = 1
                        recordPath = 'runner.watchdog-kill.json'
                        attemptGeneration = $using:CycleGeneration
                        startedAtUtc = $innerStartUtc
                        timestamp = [DateTime]::UtcNow.ToString('o')
                        innerPid = $innerPid
                        phase = [string]$phase
                        failureClass = if ($phase) { 'preamble_stall' } else { 'wait_timeout' }
                        description = "step heartbeat stale $([int]$age)s > ${effectiveThreshold}s; watchdog killing inner PID $innerPid"
                        stepHeartbeatAgeSeconds = [int]$age
                        timeoutSeconds = $effectiveThreshold
                    }
                    try {
                        $killPath = Join-Path $runtimeDir 'runner.watchdog-kill.json'
                        $killTemp = $killPath + '.' + [Guid]::NewGuid().ToString('n') + '.tmp'
                        [IO.File]::WriteAllText($killTemp, ($killRecord | ConvertTo-Json -Depth 6))
                        [IO.File]::Move($killTemp, $killPath, $true)
                    } catch {
                        Add-Content -LiteralPath $outerLog -Value "$([DateTime]::UtcNow.ToString('o')) [watchdog] kill evidence write failed: $($_.Exception.Message)"
                    }
                    # Kill the whole tree, not just the inner pwsh: a wedged
                    # step usually has live children (console capture, OCR,
                    # ssh) that would otherwise orphan, keep handles open,
                    # and confuse the next cycle's process discovery.
                    & $treeKill $innerPid 2000
                    return
                }
                if (& $sameInnerConfirmedGone $innerPid $innerStartUtc) {
                    Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] step heartbeat stale but inner PID $innerPid no longer matches the armed identity (exited or PID reused; confirmed); disarming without kill."
                    return
                }
                # Identity probe failed transiently while the heartbeat is
                # stale: neither kill (might not be our process) nor disarm
                # (might still be our wedged inner). Keep polling.
                Add-Content -LiteralPath $outerLog -Value "$((Get-Date).ToString('o')) [watchdog] step heartbeat stale $([int]$age)s (bound ${effectiveThreshold}s$(if ($phase) { ", preamble phase '$phase'" })) but identity probe is transiently failing; retrying next poll."
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
