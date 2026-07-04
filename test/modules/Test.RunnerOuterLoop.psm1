<#PSScriptInfo
.VERSION 2026.07.03
.GUID 42e5f6a7-b8c9-4d12-9345-6e7f8a9b0c1d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner outer-loop
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
    Eternal cycle loop for [test/Invoke-TestRunner.ps1](../Invoke-TestRunner.ps1):
    git pull, spawn the inner runner per cycle, watch the heartbeat,
    pause on failure with four break-out triggers (framework commit,
    project commit, local config edit, status-UI start request).
.DESCRIPTION
    Stops only on Ctrl+C (caller's $State.ShutdownState['Requested']
    flip). Per the resilience contract, anything else -- a flaky
    network, a hung sequence, an unhandled exception inside the
    inner -- is just another failure that the outer absorbs and retries.

    Lives in its own module, separate from the Invoke-TestRunner.ps1
    entry point, so the loop body and its helpers can be unit-tested
    independently of the entry-point script. The caller (Invoke-TestRunner.ps1) builds
    a State hashtable and calls Invoke-RunnerOuterLoop; the function
    returns when ShutdownState['Requested'] flips. The watchdog lives
    in its own module ([Test.RunnerWatchdog](Test.RunnerWatchdog.psm1))
    so the heartbeat + kill logic stays decoupled from the loop.
#>

# === Pure git / config helpers ============================================
# Each helper is module-level and takes its inputs as parameters; no
# script-scope state is read implicitly. Callers (Invoke-RunnerOuterLoop
# and downstream test fixtures) pass repo paths + config paths
# explicitly so the helpers stay testable.

function Get-OuterCommitSha {
    <#
    .SYNOPSIS
        Return the local HEAD SHA of the repo at $RepoRoot, or $null when
        git fails (not a repo, detached/unborn HEAD, git error).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $sha = & git -C $RepoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]$sha).Trim()
}

function Test-OuterNewCommitsAvailable {
    <#
    .SYNOPSIS
        Fetch origin and report whether the upstream tracking branch's tip
        now differs from $BaselineSha. $false on any git/fetch failure or
        when there is no upstream.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$BaselineSha
    )
    & git -C $RepoRoot fetch --quiet origin 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    $upstream = & git -C $RepoRoot rev-parse '@{u}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $upstream) { return $false }
    return (([string]$upstream).Trim() -ne $BaselineSha)
}

function Invoke-OuterGitPull {
    <#
    .SYNOPSIS
        Fast-forward-only pull of the repo at $RepoRoot, streaming git's
        output. Returns $true when the pull succeeded, $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    & git -C $RepoRoot pull --ff-only --quiet 2>&1 | Write-Output
    return ($LASTEXITCODE -eq 0)
}

function Get-OuterRemoteSha {
    <#
    .SYNOPSIS
        Query a remote repo's current HEAD SHA via git ls-remote without
        needing a local clone (the project is wiped + re-cloned at cycle
        start, so a local clone may not exist mid-pause). $null on empty
        URL or any failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RemoteUrl)
    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) { return $null }
    $line = & git ls-remote $RemoteUrl HEAD 2>$null | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($line)) { return $null }
    return ([string]$line).Split("`t")[0].Trim()
}

function Get-OuterConfigMtime {
    <#
    .SYNOPSIS
        Snapshot the on-disk UTC mtime of test.config.yml, or $null when
        the file is missing. The pause loop compares two snapshots with
        -ne, so a $null / non-null transition (config deleted or created
        mid-pause) is itself a change worth breaking on, letting an
        operator edit/create the config and get a near-immediate restart.
    #>
    [CmdletBinding()]
    [OutputType([Nullable[datetime]])]
    param([Parameter(Mandatory)][string]$ConfigPath)
    try {
        if (Test-Path -LiteralPath $ConfigPath) {
            return (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
        }
    } catch {
        Write-Verbose "Get-OuterConfigMtime: $($_.Exception.Message)"
    }
    return $null
}

function Get-OuterPoolTestCycleOverride {
    <#
    .SYNOPSIS
        Extract a pool's config.testCycle override map from the pool object
        Sync-YurunaPoolIntent returns. PURE + null-safe: returns @{} for a
        null pool / no config / no testCycle, so a no-pool host overlays
        nothing (identical to single-host). Reads straight off the pool
        object -- not pool.manifest.json -- so a pool that authors a
        testCycle override WITHOUT test-sets still applies it (the manifest
        is deleted when a pool has no test-sets).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$Pool)
    if (-not ($Pool -is [System.Collections.IDictionary])) { return @{} }
    $cfg = $Pool['config']
    if (-not ($cfg -is [System.Collections.IDictionary])) { return @{} }
    $tc = $cfg['testCycle']
    if (-not ($tc -is [System.Collections.IDictionary])) { return @{} }
    # Copy into a plain hashtable so callers index it uniformly (the source is the
    # OrderedDictionary ConvertFrom-Yaml produced).
    $out = @{}
    foreach ($k in $tc.Keys) { $out[[string]$k] = $tc[$k] }
    return $out
}

function Get-OuterStepTimeoutMinute {
    <#
    .SYNOPSIS
        Read testCycle.stepTimeoutMinutes from test.config.yml each cycle so
        an operator can edit between cycles and the new bound takes effect on
        the next spawn without restarting the outer. A positive per-pool
        config.testCycle override WINS over the local config (precedence:
        pool > config > default).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][int]$DefaultMinutes,
        # Per-pool config.testCycle overrides (from Get-OuterPoolTestCycleOverride).
        # An override here WINS over test.config.yml (precedence: pool > config >
        # default). Empty @{} for a no-pool host -> identical to single-host.
        [Parameter()][hashtable]$PoolTestCycleOverride = @{}
    )
    # -NoCache so a mid-cycle operator edit (the "lower stepTimeout for
    # the next cycle" workflow documented in test/README.md) takes effect
    # at the spawn boundary even if Read-TestConfig's mtime-keyed cache
    # hasn't noticed yet on a low-resolution filesystem.
    $cfg = Read-TestConfig -Path $ConfigPath -NoCache
    $v = Get-TestConfigValue -Config $cfg -Path 'testCycle.stepTimeoutMinutes'
    $result = $DefaultMinutes
    if ($null -ne $v) {
        $i = [int]$v
        if ($i -gt 0) { $result = $i }
    }
    if ($PoolTestCycleOverride.ContainsKey('stepTimeoutMinutes') -and ([int]$PoolTestCycleOverride['stepTimeoutMinutes'] -gt 0)) {
        $result = [int]$PoolTestCycleOverride['stepTimeoutMinutes']
    }
    return $result
}

function Get-OuterAutoRemediation {
    <#
    .SYNOPSIS
        Read the default-off auto-remediation opt-in (enable flag + per-streak
        cap) fresh from test.config.yml so an operator edit takes effect at the
        spawn boundary, like Get-OuterStepTimeoutMinute. A per-pool config.testCycle
        override WINS over the local config (pool > config > default), so a pool can
        ENGAGE remediation fleet-wide without editing every host's test.config.yml.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter()][hashtable]$PoolTestCycleOverride = @{}
    )
    $enabled = $false
    $maxAttempts = 2
    try {
        $cfg = Read-TestConfig -Path $ConfigPath -NoCache
        $e = Get-TestConfigValue -Config $cfg -Path 'testCycle.autoRemediationEnabled'
        if ($null -ne $e) { $enabled = [bool]$e }
        $m = Get-TestConfigValue -Config $cfg -Path 'testCycle.autoRemediationMaxAttemptsPerCycle'
        if (($null -ne $m) -and ([int]$m -gt 0)) { $maxAttempts = [int]$m }
    } catch { Write-Verbose "Get-OuterAutoRemediation: $($_.Exception.Message)" }
    if ($PoolTestCycleOverride.ContainsKey('autoRemediationEnabled')) {
        $enabled = [bool]$PoolTestCycleOverride['autoRemediationEnabled']
    }
    if ($PoolTestCycleOverride.ContainsKey('autoRemediationMaxAttemptsPerCycle') -and ([int]$PoolTestCycleOverride['autoRemediationMaxAttemptsPerCycle'] -gt 0)) {
        $maxAttempts = [int]$PoolTestCycleOverride['autoRemediationMaxAttemptsPerCycle']
    }
    return @{ Enabled = $enabled; MaxAttempts = $maxAttempts }
}

function Get-OuterLastFailureClass {
    <#
    .SYNOPSIS
        failureClass from the just-failed cycle's last_failure.json. Safe to
        read during the failure-pause -- the pre-spawn wipe runs at the NEXT
        cycle start, so the file is intact here. $null when absent/unparseable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $env:YURUNA_LOG_DIR) { return $null }
    $f = Join-Path $env:YURUNA_LOG_DIR 'last_failure.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try {
        $rec = Get-Content -Raw -LiteralPath $f -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($rec.Contains('failureClass')) { return [string]$rec['failureClass'] }
    } catch { Write-Verbose "Get-OuterLastFailureClass: $($_.Exception.Message)" }
    return $null
}

function Get-OuterProjectUrl {
    <#
    .SYNOPSIS
        Return repositories.projectUrl from test.config.yml, or $null when
        it is unset -- the remote the failure-pause polls for new project
        commits.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ConfigPath)
    $cfg = Read-TestConfig -Path $ConfigPath
    $v = Get-TestConfigValue -Config $cfg -Path 'repositories.projectUrl'
    if ($v) { return [string]$v }
    return $null
}

# === Forward-env + outer.log helpers ======================================

function Sync-ForwardEnv {
    <#
    .SYNOPSIS
        Re-assert the launch-time snapshot of YURUNA_* env vars so the
        inner sees them even if some module in this outer process
        clobbered $env: mid-run. See [[feedback memory entry on snapshot
        + re-assert]] for why this is not a one-shot at outer startup.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Re-asserts a known-good snapshot; -WhatIf would be noise per key.')]
    param([Parameter(Mandatory)][hashtable]$ForwardEnvSnapshot)
    foreach ($n in $ForwardEnvSnapshot.Keys) {
        $current = [Environment]::GetEnvironmentVariable($n)
        if ($current -ne $ForwardEnvSnapshot[$n]) {
            Set-Item -Path "Env:$n" -Value $ForwardEnvSnapshot[$n]
        }
    }
}

function Write-OuterLog {
    <#
    .SYNOPSIS
        Append a timestamped line to runtime/outer.log. Survives a
        console-output wedge (observed on Windows: conhost can swallow
        every Write-Output for the entire failure-pause window).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    try {
        Add-Content -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'outer.log') `
            -Value "$stamp $Message" -Encoding utf8 -ErrorAction Stop
    } catch {
        Write-Verbose "outer.log write failed (non-fatal): $($_.Exception.Message)"
    }
}

# === Main loop ============================================================

function Invoke-RunnerOuterLoop {
    <#
    .SYNOPSIS
        Run the eternal cycle loop until ShutdownState['Requested'] flips.
    .PARAMETER State
        Hashtable carrying per-run config + cross-thread references.
        Required keys (all enforced via the validation block below):
          RepoRoot, ConfigPath, InnerScript, PwshExe, ArgList,
          ForwardEnvSnapshot, ShutdownState, NoGitPull,
          FailurePauseMaxSeconds, FailureCommitPollSeconds,
          OuterPullErrorSleepSec, InnerSpawnErrorSleepSec,
          StepTimeoutMinutesDefault, WatchdogPollSeconds.
        ShutdownState is a hashtable (reference-shared with the
        caller's Ctrl+C handler) whose ['Requested'] key flipping
        ends the loop.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Implementation reads keys from $State; PSSA cannot track hashtable indexer reads.')]
    param([Parameter(Mandatory)][hashtable]$State)
    $required = @(
        'RepoRoot','ConfigPath','InnerScript','PwshExe','ArgList',
        'ForwardEnvSnapshot','ShutdownState','NoGitPull',
        'FailurePauseMaxSeconds','FailureCommitPollSeconds',
        'OuterPullErrorSleepSec','InnerSpawnErrorSleepSec',
        'StepTimeoutMinutesDefault','WatchdogPollSeconds'
    )
    foreach ($k in $required) {
        if (-not $State.ContainsKey($k)) {
            throw "Invoke-RunnerOuterLoop: -State is missing required key '$k'."
        }
    }
    $cycle = 0
    # Consecutive auto-remediation pause-skips; reset on a passing cycle so a
    # deterministic transient still escalates to the normal wait-for-human
    # pause after the per-streak cap, while an isolated transient retries fast.
    $remediationAutoSkips = 0
    while (-not $State.ShutdownState['Requested']) {
        $cycle++

        # State machine: idle -> cycle-start. The transition lands
        # before any per-cycle work so a watchdog reading
        # runner.state.json sees "cycle-start" while the git pull /
        # pre-spawn cleanup is in flight; a crash during that window
        # leaves "cycle-start" stale, which the next outer's
        # Initialize-RunnerState detects + synthesises a fault.
        if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
            $null = Set-RunnerState -To 'cycle-start' -Reason "cycle $cycle starting" -Confirm:$false
        }

        # 1. Outer git pull (framework repo). Skip on -NoGitPull,
        #    mirroring the prior runner's flag. A failure here is
        #    treated as transient: short sleep + retry, so the loop
        #    doesn't burn CPU thrashing on a transient git error.
        if (-not $State.NoGitPull) {
            Write-Output ""
            Write-Output "[outer cycle $cycle] git pull (framework)"
            if (-not (Invoke-OuterGitPull -RepoRoot $State.RepoRoot)) {
                Write-Warning "[outer cycle $cycle] git pull failed -- sleeping $($State.OuterPullErrorSleepSec)s before retry."
                Start-Sleep -Seconds $State.OuterPullErrorSleepSec
                continue
            }
        }

        # 1b. Pool intent sync (best-effort, IN-PROCESS, DEFAULT-OFF). Pull the
        #     pool intent over the LAN and reconcile desiredState BEFORE spawning
        #     the inner, so a pulled paused/drain gates THIS cycle. A no-op (single
        #     try-wrapped call that short-circuits) when pool sync is unconfigured
        #     -- a no-pool host is unaffected. The pull is wall-clock-bounded +
        #     credential-prompt-proof inside Sync-YurunaPoolIntent, so this can't
        #     hang the (bare-pwsh-INTERACTIVE) outer loop; any error is non-fatal.
        # Per-pool config.testCycle override (default-off, empty for a no-pool host),
        # captured at the cycle boundary so the watchdog (step-timeout) + the failure-
        # pause (auto-remediation) below can let a pool ENGAGE remediation / tighten
        # the step timeout fleet-wide without editing each host's test.config.yml.
        $poolTC = @{}
        if (Get-Command Sync-YurunaPoolIntent -ErrorAction SilentlyContinue) {
            $poolState = 'run'
            try {
                $poolObj   = Sync-YurunaPoolIntent
                $poolState = Resolve-YurunaPoolDesiredState -Pool $poolObj
                if (Get-Command Get-OuterPoolTestCycleOverride -ErrorAction SilentlyContinue) {
                    $poolTC = Get-OuterPoolTestCycleOverride -Pool $poolObj
                }
            } catch {
                Write-OuterLog "[outer cycle $cycle] pool sync error (non-fatal): $($_.Exception.Message)"
            }
            if ($poolState -eq 'drain') {
                # Stop-after-cycle: any in-flight cycle already completed (this
                # runs at the cycle boundary), so draining never corrupts an
                # accumulating cycle. The host stops; re-adding it (set desiredState
                # back to run + restart the runner) rejoins the pool.
                Write-Output "[outer cycle $cycle] pool desiredState=drain -- stopping (no further cycles)."
                Write-OuterLog "[outer cycle $cycle] pool desiredState=drain -- requesting shutdown at the cycle boundary."
                $State.ShutdownState['Requested'] = $true
                break
            }
            if ($poolState -eq 'paused') {
                # Healthy hold (distinct from the failure-pause below): the outer
                # while-loop IS the poll -- log, reflect 'paused' in the runner
                # state, sleep, and re-pull intent next iteration. Flips back to a
                # normal cycle as soon as a pull shows desiredState=run.
                if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                    $null = Set-RunnerState -To 'paused' -Reason "pool desiredState=paused (cycle $cycle)" -Confirm:$false
                }
                Write-Output "[outer cycle $cycle] pool desiredState=paused -- holding; re-checking intent in 30s."
                Write-OuterLog "[outer cycle $cycle] pool desiredState=paused -- holding (no cycle spawned)."
                Start-Sleep -Seconds 30
                continue
            }
        }

        # 2. Spawn the inner. YURUNA_RUNNER_RELAUNCH=1 tells the inner
        #    that we (the outer) own the pidfile + Ctrl+C handler;
        #    inner skips its own copies of those. Sync-ForwardEnv
        #    re-asserts the launch-time snapshot of YURUNA_* vars
        #    (cache IP, track/log dirs, log level, OCR combine) so
        #    the inner sees them even if some module in this outer
        #    process clobbered $env: mid-run.
        Sync-ForwardEnv -ForwardEnvSnapshot $State.ForwardEnvSnapshot
        $env:YURUNA_RUNNER_RELAUNCH = '1'
        if ($State.ForwardEnvSnapshot.Count -gt 0) {
            Write-Output "[outer cycle $cycle] forwarding env: $($State.ForwardEnvSnapshot.Keys -join ', ')"
        }
        Write-Output "[outer cycle $cycle] spawning inner pwsh... (local time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))"
        Write-OuterLog "[outer cycle $cycle] about to invoke inner pwsh"
        # Wipe last cycle's inner.pid + runner.stepHeartbeat BEFORE
        # arming the watchdog. Without this, Start-Watchdog's wait-
        # for-pidfile loop sees the stale file from the previous cycle
        # and skips the wait entirely; it then reads the dead PID,
        # observes Get-Process returns nothing, and disarms in <60s
        # -- leaving the new inner unwatched for the whole cycle. A
        # stale runner.stepHeartbeat has the symmetric trap: the
        # watchdog would see a 7h-old mtime and kill the new inner
        # before it even started its first step.
        #
        # last_failure.json is wiped here too. Invoke-Sequence removes
        # it at the start of each sequence within a cycle, but between
        # the previous cycle's failure and the new cycle's first
        # sequence there is a multi-second window where a dashboard /
        # status-server reader sees stale cycle-N failure context
        # attached to cycle N+1. Pre-spawn deletion closes that window.
        $innerPidFile    = Join-Path $env:YURUNA_RUNTIME_DIR 'inner.pid'
        $stepHbFile      = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'
        $lastFailureFile = Join-Path $env:YURUNA_LOG_DIR     'last_failure.json'
        Remove-Item -LiteralPath $innerPidFile    -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stepHbFile      -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $lastFailureFile -Force -ErrorAction SilentlyContinue
        # Post-wipe: if Remove-Item failed (locked file, transient
        # permission error, AV mid-scan, anything), the watchdog about
        # to arm would read the stale mtime and kill the new inner
        # inside one poll. Force a fresh stepHeartbeat mtime so the
        # watchdog window is full regardless of whether Remove-Item
        # succeeded.
        try {
            [System.IO.File]::WriteAllText($stepHbFile, [DateTime]::UtcNow.ToString('o'))
        } catch {
            Write-Warning "[outer cycle $cycle] could not force-fresh runner.stepHeartbeat ($($_.Exception.Message)) -- watchdog may false-positive within the first poll."
            Write-OuterLog "[outer cycle $cycle] runner.stepHeartbeat force-touch failed: $($_.Exception.Message)"
        }
        # inner.pid is the watchdog's other input; the new inner
        # overwrites it at startup. If a stale pidfile survived
        # Remove-Item, log loudly so the operator can investigate;
        # the watchdog's wait-for-pidfile loop sees the stale content
        # and either targets a dead PID (no-op) or, worst case, kills
        # a live unrelated process. Surface so it's diagnosable
        # instead of silently weird.
        if (Test-Path -LiteralPath $innerPidFile) {
            Write-Warning "[outer cycle $cycle] inner.pid wipe failed and the file is still present; watchdog may target the stale PID."
            Write-OuterLog "[outer cycle $cycle] inner.pid wipe failed -- stale content survived Remove-Item"
        }
        # break-active.json: written by the `break` sequence action
        # when a cooperative breakpoint parks the cycle, removed on
        # resume. If the operator restarts only Invoke-TestRunner.ps1
        # while a break is parked, the file survives and the first
        # new-cycle step's Gate #1 thinks a break is still active --
        # hanging the cycle on a non-existent marker. Status-server
        # startup also sweeps this file but the runner can start
        # without the status server; clean here so both startup paths
        # agree.
        Remove-Item -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'break-active.json') -Force -ErrorAction SilentlyContinue
        # Arm the watchdog BEFORE the spawn so it's already polling
        # by the time the inner writes inner.pid + the first
        # heartbeat. Re-read stepTimeoutMinutes each cycle so an
        # operator can tighten / loosen the bound between cycles
        # without restarting the outer.
        $stepTimeoutMin = Get-OuterStepTimeoutMinute -ConfigPath $State.ConfigPath -DefaultMinutes $State.StepTimeoutMinutesDefault -PoolTestCycleOverride $poolTC
        Write-OuterLog "[outer cycle $cycle] watchdog: stepTimeoutMinutes=$stepTimeoutMin"
        $watchdogJob = Start-Watchdog -StepTimeoutMinutes $stepTimeoutMin -RuntimeDir $env:YURUNA_RUNTIME_DIR -PollSeconds $State.WatchdogPollSeconds
        # A watchdog that failed to arm (null job, or one already in a
        # terminal/failed state) silently disables hang protection: the inner
        # would run unguarded and a hang would never be killed. Surface it
        # loudly to console AND outer.log. A freshly started job is
        # NotStarted -> Running, so only a terminal state here means the arm did
        # not take -- this avoids a false warn on the NotStarted transition.
        if ((-not $watchdogJob) -or ($watchdogJob.State -in @('Failed', 'Stopped', 'Completed'))) {
            $wdState = if ($watchdogJob) { [string]$watchdogJob.State } else { '<null>' }
            Write-Warning "[outer cycle $cycle] watchdog did NOT arm (state=$wdState) -- hang protection is DISABLED for this cycle."
            Write-OuterLog "[outer cycle $cycle] WARNING: watchdog did not arm (job state=$wdState); cycle runs without hang protection."
        }
        # State machine: cycle-start -> in-cycle. Lands AFTER the
        # watchdog is armed and BEFORE the call-op blocks. A crash
        # while inner is running leaves "in-cycle" stale; boot
        # recovery + Initialize-RunnerState narrate the recovery on
        # the next startup.
        if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
            $null = Set-RunnerState -To 'in-cycle' -Reason "inner spawning" -Confirm:$false
        }
        # --- See https://yuruna.link/memory#why-the-inner-spawn-uses-the-call-operator-instead-of-start-process
        $exitCode = 0
        try {
            & $State.PwshExe @($State.ArgList)
            $exitCode = $LASTEXITCODE
        } catch {
            Write-Warning "[outer cycle $cycle] failed to invoke inner pwsh: $_"
            Stop-Watchdog -Job $watchdogJob
            Start-Sleep -Seconds $State.InnerSpawnErrorSleepSec
            continue
        }
        Stop-Watchdog -Job $watchdogJob
        # Outer regained control. Emit BOTH to console and to runtime/
        # outer.log so a conhost wedge (documented above) can't hide
        # the moment Start-Process -Wait returned.
        Write-Output "[outer cycle $cycle] outer runner back in control (local time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))"
        Write-OuterLog "[outer cycle $cycle] outer runner back in control"
        Write-Output "[outer cycle $cycle] inner exited with code $exitCode"
        Write-OuterLog "[outer cycle $cycle] inner exited with code $exitCode"

        # === poolStorage health surfacing (best-effort) ===========================
        # The drain below runs DETACHED + best-effort, so a host that has STOPPED
        # replicating (bad credential, read-only share, a Windows drive-letter /
        # credential collision) records the failure ONLY in the ledger -- where no
        # operator looks. Read the PRIOR drain's ledger (the one fired at the end of
        # the previous cycle has had a full cycle to finish) and WARN to console +
        # outer.log when replication is failing/stalled, so a silent failure becomes
        # visible. Never throws; a missing module / config / ledger just skips it.
        try {
            if (-not (Get-Command Get-PoolStorageHealthWarning -ErrorAction SilentlyContinue)) {
                $psHealthMod = Join-Path $PSScriptRoot 'Test.PoolStorage.psm1'
                if (Test-Path -LiteralPath $psHealthMod) { Import-Module $psHealthMod -ErrorAction SilentlyContinue }
            }
            if ((Get-Command Read-PoolStorageLedger -ErrorAction SilentlyContinue) -and
                (Get-Command Get-PoolStorageHealthWarning -ErrorAction SilentlyContinue) -and
                (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) {
                $psReplicate = $false
                try {
                    $psCfgNow = Read-TestConfig -Path $State.ConfigPath
                    if (($psCfgNow -is [System.Collections.IDictionary]) -and
                        ($psCfgNow['pool'] -is [System.Collections.IDictionary])) {
                        $psReplicate = [bool]$psCfgNow['pool']['networkReplicate']
                    }
                } catch { $null = $_ }
                if ($psReplicate) {
                    $psLedger = Read-PoolStorageLedger -RuntimeDir $env:YURUNA_RUNTIME_DIR
                    $psWarn   = Get-PoolStorageHealthWarning -Ledger $psLedger -Replicate $true
                    if ($psWarn) {
                        Write-Warning "[outer cycle $cycle] $psWarn"
                        Write-OuterLog "[outer cycle $cycle] poolStorage health: $psWarn"
                    }
                }
            }
        } catch {
            Write-Verbose "poolStorage health check skipped: $($_.Exception.Message)"
        }

        # === yuruna pool storage replication (best-effort, DETACHED) ===
        # Fire the backlog-draining replicator in its OWN detached process so a
        # slow/absent NAS can NEVER delay the next cycle. The drain self-dedupes
        # (single-instance lock file), fail-fasts on an unreachable share, copies
        # every not-yet-replicated cycle atomically, and is a no-op unless
        # poolStorage.replicate is configured. Spawn failure is non-fatal. Detach
        # idiom mirrors Start-StatusService.ps1 (empty stdin sink on Windows so the
        # child can't pin conhost; nohup + own process group on macOS/Linux).
        try {
            $drainScript = Join-Path $PSScriptRoot 'Invoke-PoolStorageDrain.ps1'
            if (Test-Path -LiteralPath $drainScript) {
                $hid = if (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue) { [string](Get-YurunaHostId) } else { '' }
                $drainErr = Join-Path $env:YURUNA_RUNTIME_DIR 'poolstorage.drain.err'
                if ($IsWindows) {
                    $drainStdin = Join-Path $env:YURUNA_RUNTIME_DIR 'poolstorage.drain.stdin.empty'
                    if (-not (Test-Path -LiteralPath $drainStdin)) { [System.IO.File]::WriteAllBytes($drainStdin, [byte[]]@()) }
                    $drainOut = Join-Path $env:YURUNA_RUNTIME_DIR 'poolstorage.drain.out'
                    $scriptQuoted = '"' + $drainScript + '"'
                    Start-Process -FilePath $State.PwshExe `
                        -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-File", $scriptQuoted, "-HostId", $hid `
                        -RedirectStandardInput  $drainStdin `
                        -RedirectStandardOutput $drainOut `
                        -RedirectStandardError  $drainErr | Out-Null
                } else {
                    & bash -c "set -m; nohup '$($State.PwshExe)' -NoProfile -File '$drainScript' -HostId '$hid' </dev/null >/dev/null 2>'$drainErr' & echo `$!" | Out-Null
                }
            }
        } catch {
            Write-Warning "[outer cycle $cycle] poolStorage drain spawn error (non-fatal): $($_.Exception.Message)"
        }

        # === pool push forwarder (best-effort, DETACHED) ===
        # Ship this cycle's NDJSON events to the aggregator's /ingest so they reach Loki
        # without waiting for the next 30s pull. Runs in its OWN detached process (same
        # idiom as the drain) so a slow/absent aggregator can NEVER delay the next cycle
        # (preserving read-side decoupling); pull backfills anything push drops. The
        # forwarder self-gates: it is a fast no-op unless the pool-auth-token is configured
        # (the operator's push opt-in) AND a caching-proxy is reachable. Spawn failure is
        # non-fatal.
        try {
            $pushScript = Join-Path $PSScriptRoot 'Invoke-PoolPushForwarder.ps1'
            if (Test-Path -LiteralPath $pushScript) {
                $phid = if (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue) { [string](Get-YurunaHostId) } else { '' }
                $pushErr = Join-Path $env:YURUNA_RUNTIME_DIR 'poolpush.forwarder.err'
                if ($IsWindows) {
                    $pushStdin = Join-Path $env:YURUNA_RUNTIME_DIR 'poolpush.forwarder.stdin.empty'
                    if (-not (Test-Path -LiteralPath $pushStdin)) { [System.IO.File]::WriteAllBytes($pushStdin, [byte[]]@()) }
                    $pushOut = Join-Path $env:YURUNA_RUNTIME_DIR 'poolpush.forwarder.out'
                    $pushScriptQuoted = '"' + $pushScript + '"'
                    Start-Process -FilePath $State.PwshExe `
                        -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-File", $pushScriptQuoted, "-HostId", $phid `
                        -RedirectStandardInput  $pushStdin `
                        -RedirectStandardOutput $pushOut `
                        -RedirectStandardError  $pushErr | Out-Null
                } else {
                    & bash -c "set -m; nohup '$($State.PwshExe)' -NoProfile -File '$pushScript' -HostId '$phid' </dev/null >/dev/null 2>'$pushErr' & echo `$!" | Out-Null
                }
            }
        } catch {
            Write-Warning "[outer cycle $cycle] pool push spawn error (non-fatal): $($_.Exception.Message)"
        }

        # === pool alert notifier (best-effort, BOUNDED cycle-end hook) =============
        # On the ONE host the operator configured the pool.alert transport, deliver the
        # aggregator's ADVISORY pool-degraded alerts: read the latched yuruna_pool_alert_
        # active gauge over HTTP, enqueue rising edges on the poolStorage NAS spool, deliver
        # via the notification extension, move to delivered/. Self-elects -- a clean no-op
        # everywhere the transport is not configured. Fully bounded (HTTP -TimeoutSec on the
        # gauge fetch AND the Resend POST, plus a per-cycle message cap) and never throws,
        # so it is safe on the bare-pwsh-INTERACTIVE outer loop (the cycle-end hook
        # prompt-safe + subprocess-bounded contract). IN-PROCESS so the dispatcher's delivery
        # ledger (the confirmation channel) is readable; no detached spawn needed.
        try {
            # Import the notifier + its dependencies (poolStorage config, caching-proxy IP,
            # the Send-Notification dispatcher) best-effort. Plain Import-Module (no -Force)
            # is idempotent and avoids the global-module-eviction trap.
            foreach ($m in @('Test.PoolStorage.psm1', 'Test.CachingProxy.psm1', 'Test.Notify.psm1', 'Test.PoolNotifier.psm1')) {
                $mp = Join-Path $PSScriptRoot $m
                if (Test-Path -LiteralPath $mp) { Import-Module $mp -ErrorAction SilentlyContinue }
            }
            if (Get-Command Invoke-PoolNotifierCycle -ErrorAction SilentlyContinue) {
                $notifierCfg = $null
                if (Get-Command Read-TestConfig -ErrorAction SilentlyContinue) {
                    try { $notifierCfg = Read-TestConfig -Path $State.ConfigPath } catch { $null = $_ }
                }
                $notifySummary = $null
                # The notifier touches the poolStorage NAS in-process (it needs the delivery
                # ledger to confirm a send). A wedged CIFS mount mid-drain could otherwise
                # block here for the OS SMB timeout, stalling the unattended loop. Run it in a
                # thread job with a hard wall-clock cap: Wait-Job -Timeout returns control to
                # the loop even if a syscall is still blocked (the loop moves on; an
                # uncompleted delivery simply retries next cycle). Send-Notification works in a
                # thread job -- the async notification path relies on the same.
                if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
                    $njob = Start-ThreadJob -Name "pool-notifier-$cycle" -ScriptBlock {
                        Invoke-PoolNotifierCycle -Config $using:notifierCfg
                    }
                    if (Wait-Job -Job $njob -Timeout 120) {
                        $notifySummary = Receive-Job -Job $njob -ErrorAction SilentlyContinue
                    } else {
                        Write-OuterLog "[outer cycle $cycle] pool notifier exceeded 120s -- detaching; will retry next cycle."
                        Stop-Job -Job $njob -ErrorAction SilentlyContinue
                    }
                    Remove-Job -Job $njob -Force -ErrorAction SilentlyContinue
                } else {
                    $notifySummary = Invoke-PoolNotifierCycle -Config $notifierCfg
                }
                if ($notifySummary -and $notifySummary.ran -and (($notifySummary.enqueued + $notifySummary.delivered + $notifySummary.failed + $notifySummary.retried) -gt 0)) {
                    Write-OuterLog "[outer cycle $cycle] pool notifier: enqueued=$($notifySummary.enqueued) delivered=$($notifySummary.delivered) retried=$($notifySummary.retried) failed=$($notifySummary.failed)"
                }
            }
        } catch {
            Write-Verbose "pool notifier hook skipped: $($_.Exception.Message)"
        }

        # Watchdog-kill detection: when the inner exits non-zero AND
        # the last step heartbeat is older than the threshold, the
        # cause was almost certainly the watchdog (the exit code is
        # whatever Stop-Process -Force happened to deliver; the
        # application-level failure path can't run after a SIGKILL/
        # TerminateProcess). Tag the situation so the operator doesn't
        # waste time hunting an application-level failure that never
        # happened.
        if ($exitCode -ne 0) {
            $stepHbFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'
            if (Test-Path -LiteralPath $stepHbFile) {
                $hbAge = ((Get-Date) - (Get-Item -LiteralPath $stepHbFile).LastWriteTime).TotalSeconds
                if ($hbAge -gt ($stepTimeoutMin * 60)) {
                    Write-Warning "[outer cycle $cycle] inner exited non-zero AND runner.stepHeartbeat is $([int]$hbAge)s stale (threshold $($stepTimeoutMin * 60)s) -- watchdog likely killed the inner. See runtime/outer.log for the kill line."
                    Write-OuterLog "[outer cycle $cycle] inner kill attributed to watchdog (step heartbeat age $([int]$hbAge)s > $($stepTimeoutMin * 60)s)"
                    # A SIGKILL leaves no last_failure.json (the inner's application
                    # failure path cannot run), so the auto-remediation pause-skip
                    # below has nothing to classify and the cycle escalates straight
                    # to the full human-wait pause. Synthesize a minimal schema-v2
                    # record -- only when the inner left none -- with the already-
                    # wired 'wait_timeout' class so the streak-capped auto-retry can
                    # end the pause early. Atomic write so a reader never sees a
                    # partial record; the existing per-streak cap still escalates a
                    # deterministic hang after MaxAttempts.
                    $synthFailureFile = if ($env:YURUNA_LOG_DIR) { Join-Path $env:YURUNA_LOG_DIR 'last_failure.json' } else { $null }
                    if ($synthFailureFile -and -not (Test-Path -LiteralPath $synthFailureFile) -and (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue)) {
                        $null = Write-YurunaStateFileJson -Path $synthFailureFile -Confirm:$false -InputObject ([ordered]@{
                            schemaVersion           = 2
                            reason                  = 'watchdog_kill'
                            failureClass            = 'wait_timeout'
                            severity                = 'hard'
                            classificationSource    = 'synthetic'
                            # SIGKILL destroyed the inner runspace that held the only
                            # structured step location (runner.stepHeartbeat records a
                            # bare mtime; current-action.json a free-text line), so
                            # these stay unresolved -- 0 / '' (not omitted) keeps the
                            # schema-v2 contract satisfied and Invoke-Remediation
                            # null-safe.
                            stepNumber              = 0
                            sequenceName            = ''
                            # Remaining schema-v2 file fields so the record genuinely
                            # matches the shape New-SequenceFailureRecord emits (all
                            # 'unresolved' -- a SIGKILL left no inner state to read).
                            totalSteps              = 0
                            action                  = 'watchdog kill (inner runspace SIGKILLed)'
                            description             = 'Outer watchdog killed a wedged inner; no in-runspace failure state survived.'
                            vmName                  = ''
                            guestKey                = ''
                            actionVerb              = 'watchdog'
                            suggestedRecoveries     = @()
                            stepHeartbeatAgeSeconds = [int]$hbAge
                            stepTimeoutSeconds      = ($stepTimeoutMin * 60)
                            cycle                   = $cycle
                            synthesizedBy           = 'outer-watchdog'
                            timestamp               = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                        })
                        Write-OuterLog "[outer cycle $cycle] synthesized last_failure.json (failureClass=wait_timeout) for the watchdog kill so auto-remediation can retry."
                    }
                }
            }
        }

        if ($exitCode -eq 0) {
            # 3a. Success -- next iteration pulls and respawns
            # immediately. State machine: in-cycle -> cycle-end ->
            # idle. Both transitions are emitted so a streaming
            # consumer sees the clean closure explicitly rather than
            # inferring it from the absence of a fault event.
            if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                $null = Set-RunnerState -To 'cycle-end' -Reason "inner exited 0" -Confirm:$false
                $null = Set-RunnerState -To 'idle'      -Reason "cycle complete"  -Confirm:$false
            }
            # A passing cycle re-arms the auto-remediation budget.
            $remediationAutoSkips = 0
            continue
        }

        # State machine: in-cycle -> fault. The transition lands BEFORE
        # the failure-pause loop so a dashboard sees "fault" the moment
        # the inner exits non-zero; the subsequent fault -> paused
        # transition at the start of the pause loop makes the long
        # wait explicit.
        if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
            $null = Set-RunnerState -To 'fault' -Reason "inner exited $exitCode" -Confirm:$false
        }

        # 3b. Failure -- pause until either a new upstream commit
        #     lands on the framework repo OR a new commit lands on
        #     repositories.projectUrl OR the local test.config.yml
        #     is edited OR the status-UI requests a restart OR the
        #     cap elapses, polled every FailureCommitPollSeconds.
        #     The wait loop sleeps in 5-second slices so Ctrl+C is
        #     responsive (Start-Sleep can't be interrupted by our
        #     event handler in long sweeps).
        $baselineSha         = Get-OuterCommitSha -RepoRoot $State.RepoRoot
        $baselineProjectUrl  = Get-OuterProjectUrl -ConfigPath $State.ConfigPath
        $baselineProjectSha  = if ($baselineProjectUrl) { Get-OuterRemoteSha -RemoteUrl $baselineProjectUrl } else { $null }
        $baselineConfigMtime = Get-OuterConfigMtime -ConfigPath $State.ConfigPath
        $pauseStart  = Get-Date
        $deadline    = $pauseStart.AddSeconds($State.FailurePauseMaxSeconds)
        $projectWatchMsg = if ($baselineProjectUrl) { "framework + project ($baselineProjectUrl) + local config" } else { "framework + local config (no repositories.projectUrl)" }
        Write-Warning "[outer cycle $cycle] inner failed -- pausing up to $($State.FailurePauseMaxSeconds / 60) min, polling $projectWatchMsg every $($State.FailureCommitPollSeconds / 60) min."
        Write-OuterLog "[outer cycle $cycle] inner failed -- pausing up to $($State.FailurePauseMaxSeconds / 60) min; watching: $projectWatchMsg."
        # Progress bar: tracks elapsed time toward the failure-pause
        # cap (or earlier break-out when a trigger fires). Updated on
        # every 5-second slice so the bar advances ~1.4%/tick and the
        # operator sees forward motion instead of a silent terminal.
        # -Id is fixed so we only ever own one progress row;
        # -Completed in the finally clears it cleanly when the loop
        # exits via any path (success, cap, Ctrl+C, exception).
        $progressId = 1
        # State machine: fault -> paused. The pause loop polls the
        # framework + project + config-mtime triggers; this transition
        # makes the waiting state explicit on the NDJSON stream.
        if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
            $null = Set-RunnerState -To 'paused' -Reason "failure-pause begin" -Confirm:$false
        }
        try {
            while ((Get-Date) -lt $deadline -and -not $State.ShutdownState['Requested']) {
                $remainingPoll = $State.FailureCommitPollSeconds
                while ($remainingPoll -gt 0 -and -not $State.ShutdownState['Requested']) {
                    $slice = [math]::Min(5, $remainingPoll)
                    Start-Sleep -Seconds $slice
                    $remainingPoll -= $slice
                    $remainingSec = [math]::Max(0, [int]($deadline - (Get-Date)).TotalSeconds)
                    $elapsedSec   = [int]((Get-Date) - $pauseStart).TotalSeconds
                    $percent      = [math]::Min(100, [math]::Max(0, [int](($elapsedSec * 100) / $State.FailurePauseMaxSeconds)))
                    $remainingMin = [math]::Round($remainingSec / 60, 1)
                    # Hardened the same way Wait-WithProgress draws its bar:
                    # Write-Progress throws on tmux/sshd PTYs without a
                    # resolvable TERM (the SetCursorPosition trap in
                    # feedback_pwsh_linux_write_progress_setcursor.md). Swallow
                    # the render failure so the pause keeps sleeping + polling
                    # silently instead of aborting the whole outer loop.
                    try {
                        Write-Progress -Id $progressId `
                            -Activity "[outer cycle $cycle] failure-pause toward next cycle" `
                            -Status  ("{0} min remain (next commit poll in {1}s)" -f $remainingMin, $remainingPoll) `
                            -PercentComplete $percent `
                            -SecondsRemaining $remainingSec
                    } catch { $null = $_ }
                }
                if ($State.ShutdownState['Requested']) { break }
                # Trigger 1: framework repo new commit.
                if (Test-OuterNewCommitsAvailable -RepoRoot $State.RepoRoot -BaselineSha $baselineSha) {
                    Write-Output "[outer cycle $cycle] new framework upstream commits detected -- ending pause."
                    Write-OuterLog "[outer cycle $cycle] new framework upstream commits detected -- ending pause."
                    break
                }
                # Trigger 2: project repo new commit. ls-remote returns
                # $null on network failure; require a non-null current
                # AND a non-null baseline so a transient failure on
                # either side doesn't fire spuriously, and don't fire
                # when repositories.projectUrl wasn't set in the first
                # place.
                if ($baselineProjectUrl) {
                    $currentProjectSha = Get-OuterRemoteSha -RemoteUrl $baselineProjectUrl
                    if ($currentProjectSha -and $baselineProjectSha -and ($currentProjectSha -ne $baselineProjectSha)) {
                        Write-Output "[outer cycle $cycle] new project upstream commits detected at $baselineProjectUrl -- ending pause."
                        Write-OuterLog "[outer cycle $cycle] new project upstream commits detected at $baselineProjectUrl ($baselineProjectSha -> $currentProjectSha) -- ending pause."
                        break
                    }
                }
                # Trigger 3: local test.config.yml edit (mtime change
                # OR file appearing/disappearing relative to the
                # baseline). Comparing nullable datetimes with -ne
                # handles all three transitions (changed / created /
                # deleted) in one shot.
                $currentConfigMtime = Get-OuterConfigMtime -ConfigPath $State.ConfigPath
                if ($currentConfigMtime -ne $baselineConfigMtime) {
                    Write-Output "[outer cycle $cycle] local test.config.yml changed ($($State.ConfigPath)) -- ending pause."
                    Write-OuterLog "[outer cycle $cycle] local test.config.yml changed ($($State.ConfigPath): $baselineConfigMtime -> $currentConfigMtime) -- ending pause."
                    break
                }
                # Trigger 4: status-service /control/start-cycle from
                # the UI. The endpoint sees this outer's runner.pid as
                # alive and skips spawning a replacement; without this
                # poll, that path would leave the UI's "Start cycle"
                # button silent until the backoff cap. Consume the
                # flag here so the next inner spawn doesn't re-fire on
                # it (Test-Sequence / inner's boot sweep also consume,
                # but the closer the consume to the wake the smaller
                # the window for stale-flag re-entry).
                $outerRestartFlag = Join-Path $env:YURUNA_RUNTIME_DIR 'control.cycle-restart'
                if (Test-Path -LiteralPath $outerRestartFlag) {
                    Write-Output "[outer cycle $cycle] /control/start-cycle requested via status UI -- ending pause."
                    Write-OuterLog "[outer cycle $cycle] /control/start-cycle requested via status UI -- ending pause."
                    Remove-Item -LiteralPath $outerRestartFlag -Force -ErrorAction SilentlyContinue
                    break
                }
                # Trigger 5: gated auto-remediation (default off). The remediation
                # dispatcher's recovery vocabulary maps four failure classes to
                # a clearly-safe retry; for those there is no point waiting the
                # full human-commit pause, so end it early and let the next spawn
                # retry. Capped per consecutive-failure streak (reset on a
                # passing cycle) so a DETERMINISTIC transient still escalates to
                # the normal wait-for-human pause after a couple of fast retries.
                # Everything else (pause_and_inspect / operator_intervention_
                # required / restart_from_snapshot classes) keeps the full pause.
                $autoRem = Get-OuterAutoRemediation -ConfigPath $State.ConfigPath -PoolTestCycleOverride $poolTC
                if ($autoRem.Enabled -and $remediationAutoSkips -lt $autoRem.MaxAttempts) {
                    $failClass = Get-OuterLastFailureClass
                    if ($failClass -in @('wait_timeout','instrumentation_failure','network_timeout','host_io_blocked')) {
                        $remediationAutoSkips++
                        Write-Output "[outer cycle $cycle] auto-remediation: transient '$failClass' -- ending pause early to retry (auto-retry $remediationAutoSkips/$($autoRem.MaxAttempts))."
                        Write-OuterLog "[outer cycle $cycle] auto-remediation: transient '$failClass' -- ending pause early (auto-retry $remediationAutoSkips/$($autoRem.MaxAttempts))."
                        if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                            Send-CycleEventSafely -EventRecord @{
                                timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                                event        = 'auto_remediation_applied'
                                failureClass = [string]$failClass
                                action       = 'end_failure_pause_early'
                                attempt      = $remediationAutoSkips
                                maxAttempts  = $autoRem.MaxAttempts
                            }
                        }
                        break
                    }
                }
                $remainingMin = [math]::Max(0, [math]::Round((($deadline - (Get-Date)).TotalMinutes), 1))
                Write-Output "[outer cycle $cycle] no new commits, no config edit; ${remainingMin} min remain in pause."
            }
        } finally {
            # Dismiss the bar on every exit path (trigger, cap, Ctrl+C,
            # exception). Wrapped for the same render-failure reason as the
            # in-loop draw above; an unrenderable terminal must not turn loop
            # teardown into a thrown error.
            try { Write-Progress -Id $progressId -Activity 'failure-pause' -Completed } catch { $null = $_ }
            # State machine: paused -> idle. The pause-loop exits via
            # any of: new framework commit, new project commit, config
            # edit, status-UI request, cap elapsed, or Ctrl+C. All are
            # "ready to try again" from the state machine's perspective.
            if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                $null = Set-RunnerState -To 'idle' -Reason "failure-pause ended" -Confirm:$false
            }
        }
    }
}

Export-ModuleMember -Function `
    Get-OuterCommitSha, Test-OuterNewCommitsAvailable, Invoke-OuterGitPull, `
    Get-OuterRemoteSha, Get-OuterConfigMtime, Get-OuterStepTimeoutMinute, Get-OuterProjectUrl, `
    Get-OuterPoolTestCycleOverride, Get-OuterAutoRemediation, `
    Sync-ForwardEnv, Write-OuterLog, `
    Invoke-RunnerOuterLoop
