<#PSScriptInfo
.VERSION 2026.07.03
.GUID 42ab19c1-07c0-4d84-be69-80c4f1c780a8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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

# Cross-entry-point prelude. One function returns the canonical path
# bundle every entry-point script needs ($TestRoot, $RepoRoot,
# $ModulesDir, $SequencesDir, $StatusDir, $ConfigPath), so the four
# entry points (Invoke-TestRunner, Invoke-TestInnerRunner,
# Test-Sequence, Test-Project) can never drift.
#
# Centralises the path-bundle computation that every entry point
# needs, so a new entry point ("Test-DockerCycle.ps1",
# "Invoke-K8sRunner.ps1") doesn't have to copy-paste:
#
#   $TestRoot   = $PSScriptRoot                # or one level up for the inner
#   $RepoRoot   = Split-Path -Parent $TestRoot
#   $ModulesDir = Join-Path $TestRoot 'modules'
#   ...
#
# Exit-code contract: 0 = success, 1 = anything else. Distinct preflight
# failures surface via Stop-WithReason banner text (operator + CI parser
# reads the "STOP at <Step>" line, not the numeric code). Standardising
# on 0/1 means CI doesn't need a per-script lookup table.

function Initialize-YurunaEntryPoint {
    <#
    .SYNOPSIS
        Return the canonical path bundle for any entry-point script.
    .PARAMETER ScriptRoot
        Caller passes $PSScriptRoot verbatim.
    .PARAMETER InsideModulesDir
        Set when the caller lives under test/modules/ rather than test/
        (today: Invoke-TestInnerRunner.ps1). Walks one more level up
        to reach TestRoot.
    .PARAMETER ConfigPath
        Optional override; when null, defaults to <TestRoot>/test.config.yml.
    .OUTPUTS
        [ordered]@{ TestRoot; RepoRoot; ModulesDir; SequencesDir; StatusDir; ConfigPath }
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [switch]$InsideModulesDir,
        [string]$ConfigPath
    )
    if ($InsideModulesDir) {
        $modulesDir = $ScriptRoot
        $testRoot   = Split-Path -Parent $modulesDir
    } else {
        $testRoot   = $ScriptRoot
        $modulesDir = Join-Path $testRoot 'modules'
    }
    $repoRoot     = Split-Path -Parent $testRoot
    $sequencesDir = Join-Path $testRoot 'sequences'
    $statusDir    = Join-Path $testRoot 'status'
    if (-not $ConfigPath) { $ConfigPath = Join-Path $testRoot 'test.config.yml' }
    return [ordered]@{
        TestRoot     = $testRoot
        RepoRoot     = $repoRoot
        ModulesDir   = $modulesDir
        SequencesDir = $sequencesDir
        StatusDir    = $statusDir
        ConfigPath   = $ConfigPath
    }
}

# Canonical exit codes. 0 = success, 1 = anything else. Stop-WithReason
# / Write-Summary surface the "why" in stdout; the numeric code is
# binary by design so CI consumers do not need a per-script lookup.
$script:ExitOk      = 0
$script:ExitFailure = 1

function Get-EntryPointExitCode {
    <#
    .SYNOPSIS
        Return the canonical exit code for 'Ok' (0) or 'Failure' (1).
    .DESCRIPTION
        Centralised so a future change to the contract (e.g. introduce
        a "needs operator action" code = 2) lands in one place.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][ValidateSet('Ok','Failure')][string]$Outcome
    )
    if ($Outcome -eq 'Ok') { return $script:ExitOk }
    return $script:ExitFailure
}

function Initialize-YurunaEntryPointModuleSet {
    <#
    .SYNOPSIS
        Import the canonical module set for an entry-point kind.
    .DESCRIPTION
        Each of the four entry points (Outer = Invoke-TestRunner.ps1,
        Inner = Invoke-TestInnerRunner.ps1, Project = Test-Project.ps1,
        Sequence = Test-Sequence.ps1) would otherwise hand-roll its own
        Import-Module sequence (6-13 lines per script), which drifts
        whenever a new module lands. Centralizing the lists here makes
        adding a new shared module one edit, not four.

        Entry points still issue their own Import-Module calls for
        modules outside the shared core (e.g. status-service-only helpers,
        per-host drivers). The "shared core" here is the set of modules
        that every entry point of the same kind loads.

        -Global -Force is applied so re-running the function across
        cycle boundaries refreshes mid-run git-pull'd code changes.
    .PARAMETER For
        Which entry-point kind is calling. Outer/Inner/Project/Sequence/
        StatusService/CachingProxy.
    .PARAMETER ModulesDir
        Absolute path to test/modules/. Caller passes
        $paths.ModulesDir from Initialize-YurunaEntryPoint.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Module-import side effects only; the operator has no -WhatIf intent here.')]
    param(
        [Parameter(Mandatory)][ValidateSet('Outer','Inner','Project','Sequence','StatusService','CachingProxy','PoolAdmin')][string]$For,
        [Parameter(Mandatory)][string]$ModulesDir
    )
    # Canonical per-kind module lists. Order matters where a downstream
    # module depends on an upstream one being already loaded with -Global
    # (e.g. Test.HostContract imports Test.VMUtility as a side effect; later
    # callers expect Test.VMUtility's exports to be in scope).
    $sets = @{
        Outer    = @(
            'Test.SingleInstance.psm1', 'Test.HostContract.psm1', 'Test.YurunaDir.psm1',
            'Test.Config.psm1', 'Test.InnerSpawn.psm1',
            'Test.ConfigPreflight.psm1', 'Test.Capability.psm1',
            # Boot-time recovery sweep + atomic state-file helper + runner
            # state machine. Order matters: Test.EventSchema before
            # Test.Log so Send-CycleEventSafely validates emits at module
            # load; Test.StateFile before Test.Recovery so Resolve-Orphan-
            # IncompleteCycle resolves the helper at load time; Test.Log
            # before Test.RunnerState so state-transition emits land
            # cleanly; Test.RunnerState last so Initialize-RunnerState's
            # synthetic transitions reach a fully-loaded emit path.
            'Test.FailureTaxonomy.psm1', 'Test.EventSchema.psm1', 'Test.StateFile.psm1',
            'Test.Log.psm1', 'Test.Recovery.psm1', 'Test.RunnerState.psm1',
            # Watchdog + outer-loop body live in their own modules so
            # the Start-Job heartbeat watcher and the cycle dispatcher
            # are unit-testable independent of Invoke-TestRunner.ps1.
            # Test.RunnerWatchdog before Test.RunnerOuterLoop because
            # Invoke-RunnerOuterLoop calls Start-Watchdog / Stop-Watchdog
            # at the cycle boundary.
            'Test.RunnerWatchdog.psm1', 'Test.RunnerOuterLoop.psm1',
            # Test.PoolSync: the optional, default-off pool-intent PULL the outer
            # loop calls (Get-Command-gated) at each cycle start. Leaf; loaded so
            # Invoke-RunnerOuterLoop resolves Sync-YurunaPoolIntent /
            # Resolve-YurunaPoolDesiredState when a pool is configured.
            'Test.PoolSync.psm1'
        )
        Inner    = @(
            # Inner has additional imports threaded through its cycle loop
            # (mid-cycle refreshes via $script:RunnerModules, OCR/Tesseract/
            # SSH imports after the cycle gate, etc). The core set below
            # covers BOTH the early-bootstrap imports AND the per-cycle
            # workhorses listed in $script:RunnerModules so a single
            # Initialize-YurunaEntryPointModuleSet -For Inner call at
            # bootstrap replaces 7+ inline Import-Module sites; the same
            # call inside the cycle-body re-import loop refreshes them all
            # in lockstep when a mid-run `git pull` lands. Order matches the
            # inline call sites so dependency edges (Test.HostContract depends on
            # Test.VMUtility, etc.) are preserved.
            'Test.SingleInstance.psm1', 'Test.YurunaDir.psm1', 'Test.Backoff.psm1',
            # Test.ConfigSync (test.config.yml <-> template overlay) is leaf
            # apart from Get-EntryPointExitCode (Test.Prelude, always loaded)
            # and powershell-yaml; loaded early so the cycle-start
            # Update-TestConfigFromTemplate call resolves it.
            'Test.ConfigSync.psm1',
            # Test.RunnerInnerLoop holds the inner runner's per-cycle helpers
            # (Write-InnerLog, working-tree-drift guard, caching-proxy
            # reachability probe). Leaf at load time; its functions resolve
            # git / sockets / env at call time.
            'Test.RunnerInnerLoop.psm1',
            # Test.RunnerHeartbeat: the threadpool runner.heartbeat timer
            # (compiled C# helper). Leaf; the [type] guard makes the per-cycle
            # -Force re-import a no-op.
            'Test.RunnerHeartbeat.psm1',
            'Test.Extension.psm1', 'Test.HostContract.psm1', 'Test.Status.psm1',
            'Test.Notify.psm1', 'Test.Provenance.psm1',
            'Test.Start-GuestOS.psm1', 'Test.Start-GuestWorkload.psm1',
            # Order: Test.EventSchema + Test.StateFile before Test.Log so
            # Send-CycleEventSafely finds Test-CycleEventSchema and the
            # `.incomplete` marker write resolves Write-YurunaStateFileJson
            # at module-load time; Test.Recovery + Test.Remediation +
            # Test.RunnerState after Test.Log so their module-load Send-
            # CycleEventSafely calls resolve cleanly. Test.SnapshotManifest
            # depends on Test.StateFile; Test.LogRotation is leaf.
            'Test.FailureTaxonomy.psm1', 'Test.EventSchema.psm1', 'Test.StateFile.psm1', 'Test.Log.psm1',
            'Test.Recovery.psm1', 'Test.Remediation.psm1', 'Test.RunnerState.psm1',
            'Test.SnapshotManifest.psm1', 'Test.LogRotation.psm1',
            'Test.SequencePlanner.psm1',
            'Test.CachingProxy.psm1', 'Test.Perf.psm1',
            'Test.HostIO.psm1', 'Test.Capability.psm1',
            # Test.PoolPlanner: resolve a pool's test-sets into this
            # host's runnable cycle plan. After Test.SequencePlanner + Test.Capability
            # (it calls Resolve-TestSetCyclePlan + Test-CyclePlanCapabilityFromPlan at
            # runtime); leaf at load time.
            'Test.PoolPlanner.psm1',
            'Test.KeyCodeRegistry.psm1', 'Test.Transport.psm1',
            # Paired registry + bounded recovery primitives: Repair-VncConnection
            # (clear a stale cached VNC handle so the next capture/send
            # re-handshakes) and Repair-ScreenshotRing. Loaded so Wait-ForText's
            # no-text self-heal can reach them and the capability banner can show
            # which hosts have a reconnect provider.
            'Test.VncProvider.psm1', 'Test.ScreenshotProvider.psm1'
        )
        Project  = @(
            'Test.Config.psm1', 'Test.YurunaDir.psm1',
            'Test.ConfigPreflight.psm1', 'Test.HostContract.psm1', 'Test.InnerSpawn.psm1',
            # Test.SingleInstance lets Assert-NoOtherRunner see runner.pid so
            # a Test-Project run refuses to race a live Invoke-TestRunner
            # instead of silently overlapping it on the same runtime dir.
            'Test.SingleInstance.psm1',
            # Test.Recovery is loaded so Test-Project can archive any stale
            # break-active.json left over from a prior Test-Sequence /
            # Invoke-TestRunner that crashed mid-break. Without this sweep,
            # the inner runner inherits the parked breakpoint state and the
            # status UI shows a "Continue" button for the previous cycle.
            # Test.Recovery's Send-CycleEventSafely / Write-YurunaStateFileJson
            # callers are Get-Command-guarded, so we do not need to pre-load
            # Test.EventSchema / Test.StateFile here; the archive path
            # remains best-effort either way.
            'Test.Recovery.psm1'
        )
        Sequence = @(
            'Test.LogLevel.psm1', 'Test.Config.psm1', 'Test.SequenceAction.psm1',
            'Test.HostIO.psm1', 'Test.HostContract.psm1',
            # Test.SingleInstance is loaded so Assert-NoOtherRunner can read
            # runner.pid + runner.start and refuse the run if a real
            # Invoke-TestRunner already owns the runtime dir. Outer-runner
            # takeover semantics live in the caller; this entry point only
            # uses the read side of the contract.
            'Test.SingleInstance.psm1',
            'Test.FailureTaxonomy.psm1', 'Test.EventSchema.psm1', 'Test.StateFile.psm1',
            'Test.Log.psm1', 'Test.Remediation.psm1',
            'Test.SnapshotManifest.psm1', 'Test.LogRotation.psm1',
            'Test.Backoff.psm1',
            # Test.Status is loaded so Test-Sequence can register the run
            # as its own cycle in status.json (otherwise the dashboard's
            # cycle history skips Test-Sequence runs and break-active.json
            # has no live cycle to anchor the Continue button to).
            'Test.Status.psm1',
            # Test.Recovery archives any stale break-active.json left
            # behind by a prior Test-Sequence / Invoke-TestRunner that
            # crashed mid-break. Without this sweep, the new run inherits
            # the parked breakpoint state and the status UI keeps showing
            # the stale Continue button.
            'Test.Recovery.psm1',
            'Invoke-Sequence.psm1', 'Test.SequencePlanner.psm1',
            'Test.YurunaDir.psm1', 'Test.OcrEngine.psm1',
            'Test.Tesseract.psm1', 'Test.ConfigPreflight.psm1',
            # Bounded recovery primitives reached by Wait-ForText's no-text
            # self-heal (Repair-VncConnection / Repair-ScreenshotRing).
            'Test.VncProvider.psm1', 'Test.ScreenshotProvider.psm1'
        )
        StatusService = @(
            # Modules the parent (non-detached-server) status-service
            # code needs: Test.YurunaDir for Initialize-YurunaRuntimeDir /
            # Initialize-YurunaLogDir, Test.VMUtility for IP / port helpers,
            # Test.CachingProxy for state-file + probe helpers, Test.HostContract
            # for Get-HostType + Initialize-YurunaHost. Test.PortOwner is
            # consumed later in the file (Resolve-PortOrphan) so it is
            # included here too -- one bootstrap pass loads every module
            # the parent needs. The detached status-service child process
            # imports its own modules from a here-string and is not
            # affected by this set.
            'Test.YurunaDir.psm1', 'Test.VMUtility.psm1',
            'Test.CachingProxy.psm1', 'Test.PortOwner.psm1',
            'Test.HostContract.psm1'
        )
        CachingProxy = @(
            # Union of Start-/Stop-/Test-/Repair-CachingProxy.ps1 inline
            # imports: Test.HostContract (for Initialize-YurunaHost, Get-HostType,
            # Invoke-LibvirtGroupReExecIfNeeded, Add-PortMap / Remove-PortMap,
            # Test-CacheVMOnExternalNetwork, Remove-HostProxy / Set-HostProxy,
            # Initialize-SudoCache), Test.CachingProxy (Get-CachingProxyState-
            # Path, Save-/Read-CachingProxyState, Test-CachingProxyAvailable,
            # Invoke-CachingProxyProbe, Get-CachingProxyVMIp), Test.VMUtility
            # (Test-IpAddress, Get-CachingProxyPort, Format-IpUrlHost) for
            # the env-var / -CacheIp branches that bypass Test-CachingProxy-
            # Available's transitive imports. Per-host Yuruna.Host.psm1 lives
            # under host/<short>/modules/ and is loaded by Initialize-Yuruna-
            # Host via the contract layer -- not part of this set.
            'Test.VMUtility.psm1', 'Test.CachingProxy.psm1',
            'Test.HostContract.psm1'
        )
        PoolAdmin = @(
            # The pool admin CLI (New-Pool / Add-HostToPool / ... / Test-PoolIntent):
            # Test.YurunaDir for the runtime dir (default clone path), Test.Config
            # for Read-TestConfig (Get-YurunaPoolConfig path resolution),
            # Test.ConfigValidator for Test-AgainstSchema (it pulls Test.Output +
            # Test.HostGit), and Test.PoolSync for Get-YurunaPoolConfig + the
            # bounded, credential-prompt-proof Invoke-PoolSyncGit the CLI shares.
            'Test.YurunaDir.psm1', 'Test.Config.psm1',
            'Test.ConfigValidator.psm1', 'Test.PoolSync.psm1', 'Test.PoolAdmin.psm1'
        )
    }
    foreach ($modName in $sets[$For]) {
        $modPath = Join-Path $ModulesDir $modName
        if (-not (Test-Path -LiteralPath $modPath)) {
            Write-Warning "Initialize-YurunaEntryPointModuleSet: $modName not found at $modPath (kind=$For); skipping."
            continue
        }
        Import-Module -Name $modPath -Global -Force -DisableNameChecking -Verbose:$false
    }
}

function Wait-WithProgress {
    <#
    .SYNOPSIS
        Wait up to a deadline, drawing one updating Write-Progress bar
        instead of per-tick scroll output. Optional check scriptblock
        breaks the loop early on truthy return.
    .DESCRIPTION
        Replaces the "Start-Sleep + periodic Write-Output 'still waiting'"
        idiom. The progress bar updates every $PollSeconds and is
        dismissed (-Completed) on every exit path (success, timeout,
        thrown error). Write-Progress is wrapped in try/catch per
        feedback_pwsh_linux_write_progress_setcursor.md so the loop
        keeps polling silently on hosts that can't render a bar
        (tmux/sshd PTYs without TERM); the post-loop result still
        tells the caller whether the wait succeeded.

        If $Test is supplied, it is invoked once per poll tick. Any
        truthy return ends the wait and is returned to the caller.
        Exceptions inside $Test are swallowed (treated as "not done")
        so a transient probe failure doesn't abort the wait.
    .PARAMETER Activity
        Bar title (e.g. "Status server", "inter-cycle delay").
    .PARAMETER TotalSeconds
        Maximum time to wait. <= 0 returns $null immediately.
    .PARAMETER PollSeconds
        Sleep between iterations + how often the bar updates. Default 1.
    .PARAMETER Test
        Optional scriptblock evaluated at the TOP of each iteration;
        return any truthy value to exit the wait early. Whatever it
        returns is what Wait-WithProgress returns to the caller.
    .PARAMETER Id
        Progress -Id (lets a caller own a dedicated row when nested
        progress bars are in play). Default 0.
    .OUTPUTS
        The truthy value returned by $Test on early exit, or $null
        when the deadline elapsed without $Test ever returning truthy.
        When no $Test is supplied the wait always returns $null after
        $TotalSeconds (timed-sleep mode).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][int]$TotalSeconds,
        [int]$PollSeconds = 1,
        [scriptblock]$Test,
        [int]$Id = 0
    )
    if ($TotalSeconds -le 0) { return $null }
    if ($PollSeconds  -le 0) { $PollSeconds = 1 }

    $start    = Get-Date
    $deadline = $start.AddSeconds($TotalSeconds)
    $result   = $null
    try {
        while ((Get-Date) -lt $deadline) {
            if ($Test) {
                $r = $null
                try { $r = & $Test } catch { $r = $null }
                if ($r) { $result = $r; break }
            }
            $elapsedSec   = [int]((Get-Date) - $start).TotalSeconds
            $remainingSec = [math]::Max(0, $TotalSeconds - $elapsedSec)
            $pct          = [math]::Min(100, [math]::Max(0, [int](($elapsedSec * 100) / $TotalSeconds)))
            try {
                Write-Progress -Id $Id -Activity $Activity `
                    -Status ("{0}s remain (of {1}s)" -f $remainingSec, $TotalSeconds) `
                    -PercentComplete $pct -SecondsRemaining $remainingSec
            } catch { $null = $_ }
            Start-Sleep -Seconds $PollSeconds
        }
    } finally {
        try { Write-Progress -Id $Id -Activity $Activity -Completed } catch { $null = $_ }
    }
    return $result
}

function Initialize-SequenceEngineRegistry {
    <#
    .SYNOPSIS
        Reset the per-shell sequence-action + host-I/O registries and
        repopulate the action registry from Invoke-Sequence.psm1.
    .DESCRIPTION
        Test-Sequence is the only entry point that can be re-invoked
        inside the same shell. The `$global:` registry anchors that
        protect built-in handlers from `-Force` re-imports also keep
        stale extension registrations alive across runs, so a renamed
        verb today could be silently shadowed by a "myCustomAction"
        registered yesterday in the same pwsh.
        Clear-SequenceAction + Clear-HostIOProvider wipe the registries;
        re-importing Invoke-Sequence.psm1 re-runs its module-load body,
        which re-registers `retry` / `recoverFromSnapshot` AND triggers
        Test.SequenceHandler.psm1 to register every other built-in verb
        (waitForText, passwdPrompt, fetchAndExecute, ...). Without the
        re-import the engine's per-step lookup fails with
        "Unknown action 'retry' -- treating as failure." on the first
        verb of the chain.
        Host I/O providers are re-registered later via
        Initialize-YurunaHost (per-host Test.HostIO.&lt;Host&gt;.psm1 loads
        there), so Clear-HostIOProvider does not need a matching
        refresh here.
    .PARAMETER ModulesDir
        Absolute path to test/modules/. Caller passes
        $paths.ModulesDir from Initialize-YurunaEntryPoint.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'ShouldProcess gates each registry write; this attribute is for the wrapper.')]
    param(
        [Parameter(Mandatory)][string]$ModulesDir
    )
    if (-not $PSCmdlet.ShouldProcess('SequenceAction + HostIO registries', 'Reset + repopulate')) { return }
    Clear-SequenceAction -Confirm:$false
    Clear-HostIOProvider -Confirm:$false
    Import-Module -Name (Join-Path $ModulesDir 'Invoke-Sequence.psm1') `
        -Global -Force -DisableNameChecking -Verbose:$false
}

function Assert-NoOtherRunner {
    <#
    .SYNOPSIS
        Return $false (and emit a banner) when a live Invoke-TestRunner
        already owns runner.pid in the given runtime dir.
    .DESCRIPTION
        Invoke-TestRunner ([test/Invoke-TestRunner.ps1](../Invoke-TestRunner.ps1))
        owns runner.pid for its whole lifetime and takes over an
        OtherRunner via Stop-StaleRunner. The dev / project entry
        points (Test-Sequence, Test-Project) need the opposite
        contract: refuse to start so they do not interfere with a
        cycle in progress.
        Surfaces a banner naming the live runner's PID and the
        caller, then returns $false so the caller can exit with the
        canonical failure code.
    .OUTPUTS
        [bool] $true when the runtime dir is unowned or owned by us;
        $false when an OtherRunner is live (caller should exit).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$CallerName
    )
    if (-not (Get-Command Get-RunnerInstanceState -ErrorAction SilentlyContinue)) {
        Write-Verbose "$CallerName : Test.SingleInstance not loaded; skipping no-other-runner check."
        return $true
    }
    $runnerPidFile   = Join-Path $RuntimeDir 'runner.pid'
    $runnerStartFile = Join-Path $RuntimeDir 'runner.start'
    $state = Get-RunnerInstanceState -RunnerPidFile $runnerPidFile -RunnerStartFile $runnerStartFile
    if ($state.status -ne 'OtherRunner') { return $true }
    Write-Output ''
    Write-Output '============================================='
    Write-Output '  Another Invoke-TestRunner is already running'
    Write-Output "  PID:    $($state.pid)"
    Write-Output "  Caller: $CallerName refuses to interfere"
    Write-Output '  Action: stop the existing runner first, or run'
    Write-Output '          this from a different YURUNA_RUNTIME_DIR.'
    Write-Output '============================================='
    return $false
}

function Register-EntryPointCancelHandler {
    <#
    .SYNOPSIS
        Register a CancelKeyPress handler that flips a shared shutdown
        flag instead of letting Ctrl+C tear down the runspace mid-step.
    .DESCRIPTION
        Same shape as Invoke-TestRunner.ps1's handler -- callers poll
        the returned hashtable['Requested'] at safe points (end of
        step, finally block) and surrender voluntarily.
        Register-ObjectEvent is used (not a raw .NET delegate) because
        the handler must run on the pipeline thread; see
        [[scriptblock_timer_callback]] for the threadpool-trap that
        otherwise applies. Non-interactive sessions (no Console attached)
        catch the registration failure and return a state whose
        Requested flag never flips; the caller still gets a usable
        hashtable so its `if ($state['Requested'])` guard does not
        need a null check.
    .OUTPUTS
        [hashtable] Shared state with key 'Requested' = $false; flips
        to $true on the next Ctrl+C.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$SourceIdentifier = 'YurunaCancelKey'
    )
    $state = @{ Requested = $false }
    try {
        Unregister-Event -SourceIdentifier $SourceIdentifier -ErrorAction SilentlyContinue
        Remove-Job -Name $SourceIdentifier -Force -ErrorAction SilentlyContinue
        $null = Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress `
            -SourceIdentifier $SourceIdentifier -MessageData $state -Action {
                $Event.SourceEventArgs.Cancel = $true
                $Event.MessageData['Requested'] = $true
                Write-Warning "Shutdown requested (Ctrl+C). Will exit after the current step..."
            }
    } catch {
        Write-Verbose "Could not register CancelKeyPress handler (non-interactive session): $($_.Exception.Message)"
    }
    return $state
}

function Unregister-EntryPointCancelHandler {
    <#
    .SYNOPSIS
        Tear down the handler registered by Register-EntryPointCancelHandler.
    .DESCRIPTION
        Safe to call from any exit path (success, failure, mid-finally)
        even when registration failed earlier -- both calls are
        SilentlyContinue.
    #>
    [CmdletBinding()]
    param(
        [string]$SourceIdentifier = 'YurunaCancelKey'
    )
    Unregister-Event -SourceIdentifier $SourceIdentifier -ErrorAction SilentlyContinue
    Remove-Job -Name $SourceIdentifier -Force -ErrorAction SilentlyContinue
}

function Resolve-StatusServiceStart {
    <#
    .SYNOPSIS
        Decide whether the built-in HTTP status server should start this run and
        on which port, from test.config.yml's statusService node plus the
        caller's -NoServer switch.
    .DESCRIPTION
        Pure decision: the single source of the gating + port-resolution rules
        the entry points share (the inner runner, Test-Sequence, Test-Project).
        Keeping it separate from the invocation makes the gate unit-testable.
    .OUTPUTS
        [hashtable] @{ ShouldStart = [bool]; Port = [int] }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]$Config,
        [switch]$NoServer
    )
    $svc     = if ($Config -is [System.Collections.IDictionary]) { $Config['statusService'] } else { $null }
    $enabled = [bool]($svc -is [System.Collections.IDictionary] -and $svc['isEnabled'])
    $port    = if ($svc -is [System.Collections.IDictionary] -and $svc['port']) { [int]$svc['port'] } else { 8080 }
    return @{ ShouldStart = ($enabled -and -not $NoServer); Port = $port }
}

function Start-YurunaStatusServiceIfEnabled {
    <#
    .SYNOPSIS
        Start (or restart) the status server when statusService.isEnabled and
        -NoServer was not requested -- the one gate the entry-point trio shares
        so they honor isEnabled, -NoServer, the port, and the restart policy
        identically.
    .DESCRIPTION
        -Restart forces a kill+relaunch (Test-Sequence and the inner runner's
        per-cycle refresh, which must pick up file/config changes). Omitting it
        lets Start-StatusService.ps1 compare the running server's persisted
        server.sha against the current framework HEAD and skip the relaunch when
        the code in memory is still current -- zero downtime on the common
        no-change cycle (the inner runner's startup path).
    .OUTPUTS
        [hashtable] the Resolve-StatusServiceStart decision (ShouldStart, Port).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Thin gate over Start-StatusService.ps1, which owns its own start/restart/compare-and-skip semantics; -WhatIf here would only duplicate that.')]
    [OutputType([hashtable])]
    param(
        [AllowNull()]$Config,
        [Parameter(Mandatory)][string]$StartScript,
        [switch]$NoServer,
        [switch]$Restart
    )
    $decision = Resolve-StatusServiceStart -Config $Config -NoServer:$NoServer
    if ($decision.ShouldStart) {
        try {
            if ($Restart) { & $StartScript -Port $decision.Port -Restart }
            else          { & $StartScript -Port $decision.Port }
        } catch {
            # Start-StatusService.ps1 tags an unrecoverable status-port conflict
            # (port owned by another user / another checkout) so the cycle can
            # refuse instead of running blind without its dashboard + breakpoint
            # controls. The banner is already printed there; exit terminates the
            # calling entry point (Test-Sequence, the inner runner,
            # Start-CachingProxy) the same way Assert-NoOtherRunner's refusal
            # does -- no stack trace. Re-throw anything that is not this tag.
            if ($_.Exception.Data -and $_.Exception.Data['YurunaPortConflict']) {
                exit (Get-EntryPointExitCode -Outcome Failure)
            }
            throw
        }
    }
    return $decision
}

function Resolve-ConfigServiceStart {
    <#
    .SYNOPSIS
        Decide whether the Host Config Service (mTLS NAS-credential endpoint)
        should run this host, and on which port, from test.config.yml's
        configService node.
    .DESCRIPTION
        Pure decision (no I/O), the twin of Resolve-StatusServiceStart. The
        service defaults to ENABLED when the node/flag is absent so existing
        configs (and any host that has not adopted the configService node) still
        serve NAS credentials -- matching the in-code defaults in
        Start-HostConfigService.ps1. Default port 8443.
    .OUTPUTS
        [hashtable] @{ ShouldStart = [bool]; Port = [int] }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()]$Config)
    $svc     = if ($Config -is [System.Collections.IDictionary]) { $Config['configService'] } else { $null }
    $enabled = $true
    if ($svc -is [System.Collections.IDictionary] -and $svc.Contains('isEnabled')) { $enabled = [bool]$svc['isEnabled'] }
    $port    = if ($svc -is [System.Collections.IDictionary] -and $svc['port']) { [int]$svc['port'] } else { 8443 }
    return @{ ShouldStart = $enabled; Port = $port }
}

function Start-YurunaConfigServiceIfEnabled {
    <#
    .SYNOPSIS
        Ensure the Host Config Service is running when configService.isEnabled --
        the gate every entry point shares so the mTLS NAS-credential endpoint has
        the SAME runner-managed lifecycle as the status server.
    .DESCRIPTION
        Idempotent + best-effort. Start-HostConfigService.ps1 is a no-op when a
        healthy instance is already serving (so the runner can call this every
        cycle cheaply) and re-launches when none is, so the service self-heals
        after a host reboot or crash -- the same way the status server is kept
        alive, rather than relying on a one-shot Start-CachingProxy run. A failure
        here NEVER aborts the caller: the harness keeps testing even when the
        NAS-credential channel (Extension hosts + ypool-nas rotation) is down; it
        is re-ensured on the next cycle. Pass -Restart to force a relaunch (new
        service code).
    .OUTPUTS
        [hashtable] the Resolve-ConfigServiceStart decision (ShouldStart, Port).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Thin gate over Start-HostConfigService.ps1, which owns its own skip-if-healthy / replace semantics.')]
    [OutputType([hashtable])]
    param(
        [AllowNull()]$Config,
        [Parameter(Mandatory)][string]$StartScript,
        [switch]$Restart
    )
    $decision = Resolve-ConfigServiceStart -Config $Config
    if ($decision.ShouldStart) {
        if (Test-Path -LiteralPath $StartScript) {
            try {
                if ($Restart) { & $StartScript -Port $decision.Port -Restart }
                else          { & $StartScript -Port $decision.Port }
            } catch {
                Write-Warning "Host Config Service ensure failed: $($_.Exception.Message). NAS-credential serving (Extension hosts + ypool-nas rotation) is unavailable until the next cycle re-ensures it."
            }
        } else {
            Write-Verbose "Start-HostConfigService.ps1 not found at '$StartScript'; skipping config-service ensure."
        }
    }
    return $decision
}

Export-ModuleMember -Function Initialize-YurunaEntryPoint, Get-EntryPointExitCode, Initialize-YurunaEntryPointModuleSet, Wait-WithProgress, Initialize-SequenceEngineRegistry, Assert-NoOtherRunner, Register-EntryPointCancelHandler, Unregister-EntryPointCancelHandler, Resolve-StatusServiceStart, Start-YurunaStatusServiceIfEnabled, Resolve-ConfigServiceStart, Start-YurunaConfigServiceIfEnabled
