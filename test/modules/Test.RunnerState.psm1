<#PSScriptInfo
.VERSION 2026.06.05
.GUID 42bc8a7d-e6f5-4d23-9180-3a4b5c6d7e95
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna runner state-machine lifecycle
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
    Explicit state machine for the outer runner's lifecycle, with
    persistent state + schema-validated NDJSON transition events.

.DESCRIPTION
    Before this module the outer's lifecycle was implicit -- a
    watchdog or dashboard had to reconstruct what the runner was
    DOING from a mix of heartbeat mtimes, pidfile presence, and
    cycle-folder existence. This module gives the lifecycle an
    explicit observable shape:

      idle           runner is alive and ready for the next cycle
      cycle-start    a new cycle is starting; pre-spawn work in flight
      in-cycle       inner runner is executing steps
      cycle-end      inner exited 0; outer is in post-cycle cleanup
      fault          inner exited non-zero or crashed before exit
      paused         failure-pause loop waiting for new commit / cap

    Valid transitions:

      idle        -> cycle-start, fault   (fault when boot recovery
                                           sees a stale prior state)
      cycle-start -> in-cycle, fault
      in-cycle    -> cycle-end, fault
      cycle-end   -> idle
      fault       -> paused, idle
      paused      -> idle

    Each transition writes runner.state.json atomically (via the
    state-file helper) and emits a `runner_state_transition` NDJSON
    event that an off-host consumer joins on `(runId, cycleId)`.

    Pairs with boot recovery: on outer startup, Initialize-Runner-
    State reads the prior state file. If it shows a different runId
    (= a prior runner wrote it and crashed without resetting), a
    synthetic `<prior-state> -> fault -> idle` transition pair lands
    so a downstream consumer sees the crash explicitly, not as a
    silent gap in the stream.

    The transition validator NEVER rejects -- an unrecognised pair
    logs a Write-Warning and writes the new state anyway. Same
    contract as the schema validator: catch drift loudly, never lose
    telemetry.
#>

Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Force -DisableNameChecking -Global

# State enum -- kept in sync with the runnerStateEnum in
# Test.EventSchema.psm1. Any addition here must land in both files
# in the same change.
$script:StateEnum = @('idle', 'cycle-start', 'in-cycle', 'cycle-end', 'fault', 'paused')

# Adjacency map of valid transitions. Last writer in the same
# transition stays; a fault-from-anywhere fallback comes from the
# boot-recovery synthetic transitions below.
$script:ValidTransition = @{
    'idle'        = @('cycle-start', 'fault')
    'cycle-start' = @('in-cycle', 'fault')
    'in-cycle'   = @('cycle-end', 'fault')
    'cycle-end'   = @('idle')
    'fault'       = @('paused', 'idle')
    'paused'      = @('idle')
}

# Cap on the in-file transition log. The NDJSON stream is the canonical
# history; this trailing slice is a cheap "what just happened" cache for
# /control/runner-status and similar quick lookups.
$script:HistoryDepth = 20

function Get-RunnerStateName {
    <#
    .SYNOPSIS
        Names of every state in the canonical enum, in declaration order.
    .DESCRIPTION
        Lets the startup capability matrix / dashboard enumerate states
        without re-deriving them from the validator.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param()
    return @($script:StateEnum)
}

function Get-RunnerStatePath {
    <#
    .SYNOPSIS
        Canonical on-disk path for the runner state file.
    .DESCRIPTION
        $env:YURUNA_RUNTIME_DIR/runner.state.json. Falls back to
        $env:TEMP when the runtime dir isn't published yet (the only
        legitimate caller in that state is a test fixture).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $base = if ($env:YURUNA_RUNTIME_DIR) { $env:YURUNA_RUNTIME_DIR } else { $env:TEMP }
    return (Join-Path $base 'runner.state.json')
}

function Get-RunnerState {
    <#
    .SYNOPSIS
        Read runner.state.json and return its parsed hashtable.
    .DESCRIPTION
        Returns $null when the file is missing or malformed. The
        caller decides whether absent state means "fresh boot"
        (Initialize-RunnerState) or "operator intervention required".
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $path = Get-RunnerStatePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -Raw -LiteralPath $path -ErrorAction Stop
        if (-not $raw -or -not $raw.Trim()) { return $null }
        $obj = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($obj -is [System.Collections.IDictionary]) { return [hashtable]$obj }
        return $null
    } catch {
        Write-Verbose "Get-RunnerState: parse failed at $path : $($_.Exception.Message)"
        return $null
    }
}

function Test-RunnerStateTransition {
    <#
    .SYNOPSIS
        Predicate: is the (From, To) pair an allowed transition?
    .DESCRIPTION
        Pure check; no side effects. Set-RunnerState calls this and
        logs a Write-Warning when the answer is $false, but writes
        the new state anyway (the validator's purpose is to flag
        drift, never to lose telemetry).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )
    if (-not $script:ValidTransition.ContainsKey($From)) { return $false }
    return ($script:ValidTransition[$From] -contains $To)
}

function Initialize-RunnerState {
    <#
    .SYNOPSIS
        Outer-startup entry point. Detects stale prior-runner state
        and synthesises a fault transition pair so the crash is
        explicit in the NDJSON stream.
    .DESCRIPTION
        Three cases on startup:
          1. No prior state file -> write 'idle' fresh.
          2. Prior file, prior runId == current runId -> defensive
             no-op (re-import in the same process).
          3. Prior file, prior runId != current runId AND prior state
             not 'idle' -> the prior outer crashed mid-lifecycle.
             Emit a synthetic <prior-state> -> fault transition AND
             a fault -> idle transition so a downstream consumer
             sees the crash explicitly. Then write 'idle' fresh.
        Returns the new state hashtable.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads global:__YurunaRunId set by Test.Log at module load.')]
    param()
    if (-not $PSCmdlet.ShouldProcess('runner.state.json', 'Initialize-RunnerState')) { return $null }
    $myRunId = if ($global:__YurunaRunId) { [string]$global:__YurunaRunId } else { '(unknown)' }
    $prior = Get-RunnerState
    if ($prior -and $prior.Contains('runId') -and ([string]$prior['runId'] -eq $myRunId)) {
        return $prior
    }
    if ($prior -and $prior.Contains('current') -and ([string]$prior['current'] -ne 'idle')) {
        $staleState = [string]$prior['current']
        $stalePid   = if ($prior.Contains('writerPid')) { [int]$prior['writerPid'] } else { 0 }
        $staleRunId = if ($prior.Contains('runId'))     { [string]$prior['runId'] } else { '(unknown)' }
        # Synthetic transitions: the crash itself is unobservable
        # post-hoc, so we emit two events that frame it cleanly:
        # 1) <stale> -> fault  (the crash boundary)
        # 2) fault   -> idle   (the boot recovery resolution)
        if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
            Send-CycleEventSafely -EventRecord @{
                timestamp     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                event         = 'runner_state_transition'
                fromState     = $staleState
                toState       = 'fault'
                reason        = 'boot_recovery_detected_stale_state'
                priorWriterPid = $stalePid
                priorRunId    = $staleRunId
                synthetic     = $true
            }
        }
    }
    # Always end Initialize with state 'idle'. If the prior was non-idle,
    # the synthetic transitions above narrated the crash; this final
    # write installs the clean state for the new runner.
    $fresh = @{
        current    = 'idle'
        since      = (Get-Date).ToUniversalTime().ToString('o')
        runId      = $myRunId
        writerPid  = $PID
        history    = @()
    }
    if ($prior -and $prior.Contains('current') -and ([string]$prior['current'] -ne 'idle')) {
        # The synthetic fault -> idle pair is the FIRST entry of the new
        # history so a consumer that joins runner.state.json directly
        # (rather than the NDJSON stream) sees the recovery boundary.
        $fresh.history = @(
            @{ from = [string]$prior['current']; to = 'fault'; at = (Get-Date).ToUniversalTime().ToString('o'); synthetic = $true },
            @{ from = 'fault';                   to = 'idle';  at = (Get-Date).ToUniversalTime().ToString('o'); synthetic = $true }
        )
        if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
            Send-CycleEventSafely -EventRecord @{
                timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                event     = 'runner_state_transition'
                fromState = 'fault'
                toState   = 'idle'
                reason    = 'boot_recovery_resolved'
                synthetic = $true
            }
        }
    }
    $null = Write-YurunaStateFileJson -Path (Get-RunnerStatePath) -InputObject $fresh -Confirm:$false
    return $fresh
}

function Set-RunnerState {
    <#
    .SYNOPSIS
        Transition the runner state machine. Validates the (current,
        target) pair, atomically rewrites runner.state.json, and
        emits a `runner_state_transition` NDJSON event.
    .PARAMETER To
        Target state. Must be a value from Get-RunnerStateName; an
        unrecognised target is rejected with a Write-Warning AND the
        write is skipped (the schema's "never lose telemetry" stance
        does not apply here -- writing an unrecognised state would
        wedge the validator on every subsequent transition).
    .PARAMETER Reason
        Short free-text reason for the transition. Carried verbatim
        on the NDJSON event so a streaming consumer can pivot on it
        without joining back to the cycle context.
    .OUTPUTS
        Hashtable describing the new state, or $null when the call
        is a no-op (initialize required, write blocked by -WhatIf,
        unrecognised target state, etc.).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads global:__YurunaRunId / __YurunaCycleId for the emitted event.')]
    param(
        [Parameter(Mandatory)][string]$To,
        [string]$Reason = ''
    )
    if (-not ($script:StateEnum -contains $To)) {
        Write-Warning "Set-RunnerState: '$To' is not in the canonical state enum ($($script:StateEnum -join ', ')); refusing the write."
        return $null
    }
    if (-not $PSCmdlet.ShouldProcess('runner.state.json', "Set-RunnerState -To $To")) { return $null }
    $cur = Get-RunnerState
    if (-not $cur) {
        # Auto-initialize so a caller that forgot to call Initialize-RunnerState
        # at startup still gets a usable history. The Initialize call
        # synthesises a fault recovery if appropriate; subsequent
        # transitions land on top of that baseline.
        $cur = Initialize-RunnerState -Confirm:$false
    }
    $fromState = [string]$cur['current']
    if (-not (Test-RunnerStateTransition -From $fromState -To $To)) {
        Write-Warning "Set-RunnerState: '$fromState' -> '$To' is not in the canonical adjacency map; recording anyway so the drift is visible."
    }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $transition = @{ from = $fromState; to = $To; at = $now }
    if ($Reason) { $transition['reason'] = $Reason }
    $history = if ($cur.Contains('history') -and $cur['history']) { @($cur['history']) } else { @() }
    $history = @($history) + @($transition)
    if ($history.Count -gt $script:HistoryDepth) {
        $history = $history[(-1 * $script:HistoryDepth)..-1]
    }
    $myRunId = if ($global:__YurunaRunId) { [string]$global:__YurunaRunId } else { '(unknown)' }
    $newState = @{
        current   = $To
        since     = $now
        runId     = $myRunId
        writerPid = $PID
        history   = $history
    }
    # Preserve cycle-context fields a prior write left on the file
    # (lastCycleId, lastCycleNumber) so a quick read of runner.state.json
    # carries the most-recent cycle metadata without needing to join
    # to the manifest.
    foreach ($carry in @('lastCycleId', 'lastCycleNumber')) {
        if ($cur.Contains($carry)) { $newState[$carry] = $cur[$carry] }
    }
    # Cycle-context update: cycle-start writes lastCycleId from the
    # global __YurunaCycleId set by Start-LogFile. The state machine
    # is upstream of Start-LogFile inside a cycle, so this is only
    # populated when the caller already set the global beforehand
    # (Test-Sequence / Project paths that drive Start-LogFile
    # themselves).
    if (($To -eq 'cycle-start') -and $global:__YurunaCycleId) {
        $newState['lastCycleId'] = [string]$global:__YurunaCycleId
    }
    $null = Write-YurunaStateFileJson -Path (Get-RunnerStatePath) -InputObject $newState -Confirm:$false
    if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
        $emit = @{
            timestamp = $now
            event     = 'runner_state_transition'
            fromState = $fromState
            toState   = $To
        }
        if ($Reason) { $emit['reason'] = $Reason }
        Send-CycleEventSafely -EventRecord $emit
    }
    return $newState
}

Export-ModuleMember -Function `
    Get-RunnerStateName, Get-RunnerStatePath, Get-RunnerState, `
    Test-RunnerStateTransition, Initialize-RunnerState, Set-RunnerState
