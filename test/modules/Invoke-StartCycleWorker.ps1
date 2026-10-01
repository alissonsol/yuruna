<#PSScriptInfo
.VERSION 2026.09.30
.GUID 427a68b2-7a5f-432f-b773-6b5bb75b5a2d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna status service start-cycle worker detached host-refresh
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
    Detached worker behind /control/start-cycle: under the host's lifetime
    repair lock, clears the operator's pause and lab-hold controls, signals a
    restart, runs the bounded VM cleanup, and then starts or wakes the runner.

.DESCRIPTION
    The listener only reserves the operation and launches this worker; it
    writes nothing else. Every mutation the page's "Save and start cycle"
    button asks for happens here, in the order the page has always relied on,
    and only after two things hold:

      * this worker holds the lifetime lock a host refresh also takes, so a
        refresh can never capture half-cleared controls, and a start-cycle
        can never un-pause a runner a refresh is holding parked;
      * the reservation the listener recorded is still this operation's.

    A worker that is missing a dependency, cannot take the lock, or cannot
    confirm its reservation writes no control file at all. Whatever the
    outcome, a worker that loaded the reservation API clears its reservation
    before it exits; one that could not is cleared by identity once it is
    gone.

    The runner decision is made from the state observed AFTER the cleanup:
    the cleanup can take minutes and a runner can start or exit meanwhile, so
    the observation taken before it cannot authorize a new runner. Only a
    positively absent runner is replaced; a live one is woken through the
    restart request; an unknown one is left alone and reported. The restart
    request was written either way, so a live runner that could not be
    identified still restarts its cycle.

    Progress is published to runtime/start-cycle.state.json with no paths,
    process ids or transcripts. The worker's own streams and the spawned
    runner's streams stay in the private start-cycle directory.

    Exit codes: 0 succeeded, 2 incomplete (no runner started because its
    state was unknown, or the cleanup failed and the decision was still
    made), 1 failed or refused.

.PARAMETER OperationId
    The operation's id, a canonical lowercase UUID the listener minted.

.PARAMETER Generation
    The reservation generation the listener recorded for this operation.

.PARAMETER RuntimeDir
    The runtime directory holding the controls, status.json and runner.pid.

.PARAMETER CleanupScriptPath
    The VM cleanup script (Remove-TestVMFiles.ps1).

.PARAMETER RunnerScriptPath
    The runner entry script (Start-TestRunner.ps1).

.PARAMETER WorkingDirectory
    The working directory for the cleanup and the runner (the repository root).

.PARAMETER LockWaitSeconds
    How long to wait for the lifetime lock before refusing.

.PARAMETER CleanupTimeoutSeconds
    Wall-clock bound for the cleanup script.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OperationId,
    [Parameter(Mandatory)][string]$Generation,
    [Parameter(Mandatory)][string]$RuntimeDir,
    [Parameter(Mandatory)][string]$CleanupScriptPath,
    [Parameter(Mandatory)][string]$RunnerScriptPath,
    [Parameter(Mandatory)][string]$WorkingDirectory,
    [ValidateRange(1, 120)][int]$LockWaitSeconds = 30,
    [ValidateRange(60, 3600)][int]$CleanupTimeoutSeconds = 1200
)

$ErrorActionPreference = 'Stop'
# A detached worker has no console to answer a preview or confirmation; an
# inherited preview would make every write below a silent no-op.
$callerWhatIf = $WhatIfPreference
$WhatIfPreference = $false

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
# Every other module is imported best effort, one at a time. A module that
# fails to load leaves its commands missing, and the dependency check below
# refuses before any control is touched; failing here instead would end the
# worker before its finally could release the reservation the listener made
# for it, and publish nothing. The refresh journal module (the reservation
# API) is imported last.
$script:StartCycleImportFailure = [System.Collections.Generic.List[string]]::new()
foreach ($moduleRelativePath in @('../../automation/Yuruna.Common.psm1', 'Test.StateFile.psm1', 'Test.SingleFlightLock.psm1',
        'Test.SingleInstance.psm1', 'Test.InnerSpawn.psm1', 'Test.StatusControlRoute.psm1', 'Test.HostRefreshIntent.psm1')) {
    try {
        Import-Module (Join-Path $PSScriptRoot $moduleRelativePath) -Global -Force -DisableNameChecking -ErrorAction Stop
    } catch {
        $script:StartCycleImportFailure.Add([System.IO.Path]::GetFileName($moduleRelativePath))
        Write-Verbose "Invoke-StartCycleWorker: $moduleRelativePath did not load: $($_.Exception.Message)"
    }
}

$script:StartCycleState = [ordered]@{
    schemaVersion   = 1
    operationId     = $OperationId
    generation      = $Generation
    phase           = 'waiting_for_lock'
    heartbeatUtc    = ''
    stepDeadlineUtc = ''
    result          = $null
    action          = $null
    reason          = $null
}
$script:StartCycleStatePath = Join-Path $RuntimeDir 'start-cycle.state.json'

function Write-StartCycleState {
    <#
    .SYNOPSIS
        Publish the operation's public progress record; a failed write is
        reported on the worker's own stream, never fatal.
    .PARAMETER Phase
        waiting_for_lock, clearing_controls, cleanup, deciding or completed.
    .PARAMETER StepSeconds
        How long the phase may take, published as stepDeadlineUtc so a reader
        can tell a long bounded step from a worker that died.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateSet('waiting_for_lock', 'clearing_controls', 'cleanup', 'deciding', 'completed')][string]$Phase,
        [ValidateRange(0, 7200)][int]$StepSeconds = 0
    )
    $now = [DateTime]::UtcNow
    $script:StartCycleState.phase = $Phase
    $script:StartCycleState.heartbeatUtc = $now.ToString('o')
    $script:StartCycleState.stepDeadlineUtc = if ($StepSeconds -gt 0) { $now.AddSeconds($StepSeconds).ToString('o') } else { '' }
    if (-not $PSCmdlet.ShouldProcess($script:StartCycleStatePath, (Format-YurunaOperatorMessage -Key 'runner.status_worker_state_write_action'))) { return $false }
    $written = Write-YurunaStateFileJson -Path $script:StartCycleStatePath -InputObject $script:StartCycleState -Confirm:$false
    if (-not $written) { Write-Verbose "Invoke-StartCycleWorker: progress write to $script:StartCycleStatePath failed." }
    return [bool]$written
}

function Get-StartCycleRunnerObservation {
    <#
    .SYNOPSIS
        The runner's current state, from the process-identity classifier when
        it is available and from the pidfile classification otherwise.
    .OUTPUTS
        [pscustomobject] @{ State; ProcessAlive }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $pidFile = Join-Path $RuntimeDir 'runner.pid'
    $startFile = Join-Path $RuntimeDir 'runner.start'
    $identity = Get-Command -Name 'Get-YurunaRunnerRecordState' -ErrorAction SilentlyContinue
    if ($identity) {
        try {
            $record = Get-YurunaRunnerRecordState -PidFile $pidFile -StartFile $startFile -ExpectedScriptPath $RunnerScriptPath
            return [pscustomobject]@{ State = $record; ProcessAlive = $null }
        } catch {
            Write-Verbose "Invoke-StartCycleWorker: the process-identity classifier failed: $($_.Exception.Message)"
            return [pscustomobject]@{ State = $null; ProcessAlive = $null }
        }
    }
    $legacy = Get-RunnerInstanceState -RunnerPidFile $pidFile -RunnerStartFile $startFile
    $alive = $null
    $recordedPid = 0
    if ($legacy -and [int]::TryParse([string]$legacy.pid, [ref]$recordedPid) -and $recordedPid -gt 0) {
        $alive = [bool](Get-Process -Id $recordedPid -ErrorAction SilentlyContinue)
    }
    return [pscustomobject]@{ State = $legacy; ProcessAlive = $alive }
}

function Clear-StartCycleControl {
    <#
    .SYNOPSIS
        The page's start request, applied to the runtime controls in the order
        the runner has always observed: pause flags and the lab hold removed,
        the status fields that mirror them rewritten atomically, then the
        restart request written.
    .OUTPUTS
        [bool] $true when every step completed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess($RuntimeDir, (Format-YurunaOperatorMessage -Key 'runner.start_cycle_worker_clear_action'))) { return $false }
    $complete = $true
    # A restart re-probes the lab within a step of starting, so a hold left by
    # the cycle being replaced would only be re-raised if it is still true --
    # and would otherwise park the new cycle on the old one's verdict.
    foreach ($name in @('control.cycle-pause', 'control.step-pause', 'control.lab-hold', 'lab-hold.json', 'control.lab-hold-release')) {
        $target = Join-Path $RuntimeDir $name
        try {
            if ([System.IO.File]::Exists($target)) { [System.IO.File]::Delete($target) }
        } catch {
            Write-Verbose "Invoke-StartCycleWorker: could not remove $name`: $($_.Exception.Message)"
            $complete = $false
        }
    }
    # Read-modify-write straight from disk: a runner-side write between the
    # read and the replace would otherwise be clobbered by a cached copy.
    $statusPath = Join-Path $RuntimeDir 'status.json'
    if ([System.IO.File]::Exists($statusPath)) {
        try {
            $document = [System.IO.File]::ReadAllText($statusPath) | ConvertFrom-Json -AsHashtable
            $document['cyclePaused'] = $false
            $document['stepPaused'] = $false
            $document['cyclePausedSinceUtc'] = ''
            $document['stepPausedSinceUtc'] = ''
            $document['labHold'] = $false
            $document['labHoldAreas'] = @()
            if (-not (Write-YurunaStateFile -Path $statusPath -Content ($document | ConvertTo-Json -Depth 20) -Confirm:$false)) { $complete = $false }
        } catch {
            Write-Verbose "Invoke-StartCycleWorker: status.json rewrite failed: $($_.Exception.Message)"
            $complete = $false
        }
    }
    if (-not (Write-YurunaStateFile -Path (Join-Path $RuntimeDir 'control.cycle-restart') -Content ([DateTime]::UtcNow.ToString('o')) -Confirm:$false)) {
        $complete = $false
    }
    return $complete
}

function Get-StartCycleRunnerArgumentList {
    <#
    .SYNOPSIS
        The runner arguments the recorded launch carried, validated against
        the runner script; empty when there is no valid record.
    .OUTPUTS
        [string] elements; capture with @().
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not (Get-Command -Name 'Read-YurunaRunnerLaunchRecord' -ErrorAction SilentlyContinue)) { return }
    try {
        $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $RuntimeDir
        if (-not $launch -or -not $launch.Found -or -not $launch.Valid) { return }
        if (Get-Command -Name 'Test-YurunaRunnerLaunchSpec' -ErrorAction SilentlyContinue) {
            $spec = Test-YurunaRunnerLaunchSpec -Record $launch.Record -ScriptPath $RunnerScriptPath -RequireExistingConfig
            if (-not $spec.Valid) {
                Write-Verbose "Invoke-StartCycleWorker: the recorded launch does not validate ($($spec.Reason)); starting the runner on its defaults."
                return
            }
        }
        $candidate = @(Get-StartCycleRunnerArgument -Record $launch.Record)
        $check = Test-StatusWorkerArgument -ScriptPath $RunnerScriptPath -ArgumentList $candidate
        if (-not $check.Valid) {
            Write-Verbose "Invoke-StartCycleWorker: the recorded arguments do not bind ($($check.Reason) $($check.Parameter)); starting the runner on its defaults."
            return
        }
        foreach ($token in $candidate) { $token }
    } catch {
        Write-Verbose "Invoke-StartCycleWorker: the launch record could not be read: $($_.Exception.Message)"
    }
}

$exitCode = 1
$lock = $null
$reservationTouched = $false
$publishAllowed = $false
$result = 'failed'
$action = $null
$reason = $null
try {
    if ($OperationId -cnotmatch '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z' -or
        $Generation -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z' -or
        -not [System.IO.Directory]::Exists($RuntimeDir)) {
        # Nothing trustworthy to publish under: the state file is keyed by
        # this operation and lives in a directory that must already exist.
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.start_cycle_worker_refused' -Arguments @{ operationId = '-'; reason = 'invalid_invocation' })
        exit 1
    }
    $publishAllowed = $true
    $reservationTouched = $true
    $null = Write-StartCycleState -Phase 'waiting_for_lock' -StepSeconds $LockWaitSeconds -Confirm:$false

    # A refusal sets $reason, reports it and throws this message-less
    # sentinel, which the catch below turns into a failed result.
    $refusal = [System.OperationCanceledException]::new()
    $required = @('Get-YurunaHostRefreshLockPath', 'Confirm-HostRefreshStartCycleReservation', 'Complete-HostRefreshStartCycleReservation',
        'Start-YurunaDetachedProcess', 'Enter-YurunaSingleFlightLock', 'Get-YurunaLockRank', 'Exit-YurunaSingleFlightLock',
        'Write-YurunaStateFile', 'Write-YurunaStateFileJson', 'Invoke-BoundedNativeCommand', 'Test-BoundedNativeResultComplete', 'New-YurunaDeadline',
        'Get-StatusWorkerDirectory', 'Get-StartCycleRunnerDecision', 'Get-StartCycleRefusalReason', 'Test-StatusWorkerArgument',
        'Get-StartCycleRunnerArgument', 'Get-PwshExePath')
    $absent = @($required | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
    # The runner's state is read through the identity classifier or, without
    # it, the older pidfile classification; with neither, nothing may be
    # decided after the controls are cleared.
    if (-not (Get-Command -Name 'Get-YurunaRunnerRecordState' -ErrorAction SilentlyContinue) -and
        -not (Get-Command -Name 'Get-RunnerInstanceState' -ErrorAction SilentlyContinue)) {
        $absent += 'Get-YurunaRunnerRecordState'
    }
    if ($absent.Count -gt 0) {
        $reason = 'internal_error'
        $missingDetail = @($absent) + @($script:StartCycleImportFailure)
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.start_cycle_worker_refused' -Arguments @{ operationId = $OperationId; reason = "dependency_missing:$($missingDetail -join ',')" })
        throw $refusal
    }

    $lockPath = Get-YurunaHostRefreshLockPath
    if (-not $lockPath) {
        $reason = 'internal_error'
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.start_cycle_worker_refused' -Arguments @{ operationId = $OperationId; reason = 'lock_path_unavailable' })
        throw $refusal
    }
    $lock = Enter-YurunaSingleFlightLock -Path ([string]$lockPath) -WaitMilliseconds ($LockWaitSeconds * 1000) `
        -Rank (Get-YurunaLockRank -Name 'HostOperation') -Metadata @{ purpose = 'start-cycle'; operationId = $OperationId }
    if (-not $lock.Held) {
        $reason = if ($lock.Reason -in @('held-elsewhere', 'held-by-this-process')) { 'lock_busy' } else { 'internal_error' }
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.start_cycle_worker_refused' -Arguments @{ operationId = $OperationId; reason = ([string]$lock.Reason).Replace('-', '_') })
        throw $refusal
    }
    $selfStart = [long]0
    try { $selfStart = [DateTimeOffset]::new((Get-Process -Id $PID).StartTime).ToUnixTimeMilliseconds() } catch { $selfStart = [long]0 }
    $confirmation = Confirm-HostRefreshStartCycleReservation -OperationId $OperationId -Generation $Generation -LifetimeLock $lock `
        -Worker @{ pid = $PID; startTimeUnixMs = $selfStart }
    if (-not $confirmation -or -not $confirmation.Valid) {
        $why = [string]$(if ($confirmation) { $confirmation.Reason } else { '' })
        $reason = Get-StartCycleRefusalReason -ConfirmReason $why
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.start_cycle_worker_refused' -Arguments @{
                operationId = $OperationId; reason = $(if ($why) { '{0}:{1}' -f $reason, $why.Replace('-', '_') } else { $reason }) })
        throw $refusal
    }

    $before = Get-StartCycleRunnerObservation
    Write-Verbose "Invoke-StartCycleWorker: runner before cleanup: $($before.State | ConvertTo-Json -Compress -Depth 3 -WarningAction SilentlyContinue)"

    $null = Write-StartCycleState -Phase 'clearing_controls' -StepSeconds 30 -Confirm:$false
    if (-not (Clear-StartCycleControl -Confirm:$false)) {
        Write-Verbose 'Invoke-StartCycleWorker: at least one control step did not complete.'
    }

    $null = Write-StartCycleState -Phase 'cleanup' -StepSeconds ($CleanupTimeoutSeconds + 5) -Confirm:$false
    $cleanupReason = $null
    if (-not [System.IO.File]::Exists($CleanupScriptPath)) {
        $cleanupReason = 'cleanup_failed'
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.start_cycle_worker_cleanup_failed' -Arguments @{ operationId = $OperationId; exitCode = -1; timedOut = 'false' })
    } else {
        $pwsh = Get-PwshExePath
        if (-not $pwsh) { $pwsh = 'pwsh' }
        $cleanup = Invoke-BoundedNativeCommand -FilePath $pwsh -TimeoutSeconds $CleanupTimeoutSeconds `
            -Environment @{ YURUNA_NONINTERACTIVE = '1'; YURUNA_RUNTIME_DIR = $RuntimeDir } `
            -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-WorkingDirectory', $WorkingDirectory, '-File', $CleanupScriptPath)
        if (-not [string]::IsNullOrEmpty([string]$cleanup.StdOut)) { Write-Output ([string]$cleanup.StdOut) }
        if (-not [string]::IsNullOrEmpty([string]$cleanup.StdErr)) { Write-Output ([string]$cleanup.StdErr) }
        if ($cleanup.TimedOut) {
            $cleanupReason = 'cleanup_timeout'
        } elseif (-not (Test-BoundedNativeResultComplete -Result $cleanup) -or [int]$cleanup.ExitCode -ne 0) {
            $cleanupReason = 'cleanup_failed'
        }
        if ($cleanupReason) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.start_cycle_worker_cleanup_failed' -Arguments @{
                    operationId = $OperationId; exitCode = [int]$cleanup.ExitCode; timedOut = ([string][bool]$cleanup.TimedOut).ToLowerInvariant() })
        }
    }

    $null = Write-StartCycleState -Phase 'deciding' -StepSeconds 30 -Confirm:$false
    $after = Get-StartCycleRunnerObservation
    $decisionArguments = @{ State = $after.State }
    if ($null -ne $after.ProcessAlive) { $decisionArguments.ProcessAlive = [bool]$after.ProcessAlive }
    $decision = Get-StartCycleRunnerDecision @decisionArguments
    switch -CaseSensitive ($decision.Decision) {
        'restarted' {
            $action = 'restarted'
            $result = if ($cleanupReason) { 'incomplete' } else { 'succeeded' }
            $reason = $cleanupReason
        }
        'spawn' {
            $directory = Get-StatusWorkerDirectory -Name 'start-cycle' -Confirm:$false
            if (-not $directory.Resolved) {
                $action = 'not_spawned'; $result = 'failed'; $reason = 'spawn_failed'
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.start_cycle_worker_spawn_failed' -Arguments @{ operationId = $OperationId; reason = "private_state_$(([string]$directory.Reason).Replace('-', '_'))" })
            } else {
                $runnerArguments = @(Get-StartCycleRunnerArgumentList)
                $launch = Start-YurunaDetachedProcess -FilePath $RunnerScriptPath -ArgumentList $runnerArguments `
                    -WorkingDirectory $WorkingDirectory -PrivateDirectory $directory.Path -StdInPath $directory.StdInPath `
                    -StdOutPath (Join-Path $directory.Path "runner.$OperationId.out") `
                    -StdErrPath (Join-Path $directory.Path "runner.$OperationId.err") `
                    -Environment @{ YURUNA_RUNTIME_DIR = $RuntimeDir } `
                    -Deadline (New-YurunaDeadline -TotalMilliseconds 15000) -Confirm:$false
                if ($launch -and $launch.Launched) {
                    $action = 'spawned'
                    $result = if ($cleanupReason) { 'incomplete' } else { 'succeeded' }
                    $reason = $cleanupReason
                } else {
                    $action = 'not_spawned'; $result = 'failed'; $reason = 'spawn_failed'
                    $launchReason = [string]$(if ($launch) { $launch.Reason } else { 'no_result' })
                    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.start_cycle_worker_spawn_failed' -Arguments @{ operationId = $OperationId; reason = $launchReason.Replace('-', '_') })
                }
            }
        }
        default {
            $action = 'not_spawned'; $result = 'incomplete'; $reason = 'runner_unknown'
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.start_cycle_worker_runner_unknown' -Arguments @{ operationId = $OperationId })
        }
    }
} catch [System.OperationCanceledException] {
    # A refusal: reason is already set and nothing was changed.
    $result = 'failed'
} catch {
    Write-Verbose "Invoke-StartCycleWorker: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    $result = 'failed'
    if (-not $reason -or $reason -notin @('lock_busy', 'reservation_lost', 'busy')) { $reason = 'internal_error' }
} finally {
    if ($reservationTouched -and (Get-Command -Name 'Complete-HostRefreshStartCycleReservation' -ErrorAction SilentlyContinue)) {
        try {
            $null = Complete-HostRefreshStartCycleReservation -OperationId $OperationId -Generation $Generation
        } catch {
            Write-Verbose "Invoke-StartCycleWorker: the reservation could not be cleared: $($_.Exception.Message)"
        }
    }
    if ($null -ne $lock -and $lock.Held) {
        try { Exit-YurunaSingleFlightLock -Lock $lock } catch { Write-Verbose "Invoke-StartCycleWorker: lock release failed: $($_.Exception.Message)" }
    }
    if ($publishAllowed -and $script:StartCycleState.phase -ne 'completed') {
        $script:StartCycleState.result = $result
        $script:StartCycleState.action = $action
        $script:StartCycleState.reason = $reason
        try { $null = Write-StartCycleState -Phase 'completed' -Confirm:$false } catch { Write-Verbose "Invoke-StartCycleWorker: terminal state not written: $($_.Exception.Message)" }
    }
    $WhatIfPreference = $callerWhatIf
}
$exitCode = switch ($result) { 'succeeded' { 0 } 'incomplete' { 2 } default { 1 } }
Write-Information (Format-YurunaOperatorMessage -Key 'runner.start_cycle_worker_completed' -Arguments @{
        operationId = $OperationId; result = [string]$result; action = $(if ($action) { [string]$action } else { 'none' }) }) -InformationAction Continue
exit $exitCode
