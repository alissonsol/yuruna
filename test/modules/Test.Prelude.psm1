<#PSScriptInfo
.VERSION 2026.05.29
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
        Sequence = Test-Sequence.ps1) used to hand-roll its own
        Import-Module sequence: 6-13 lines per script, drifting whenever
        a new module landed. This function centralizes the lists so
        adding a new shared module is one edit, not four.

        Entry points still issue their own Import-Module calls for
        modules outside the shared core (e.g. status-service-only helpers,
        per-host drivers). The "shared core" here is the set of modules
        that every entry point of the same kind has historically loaded.

        -Global -Force is applied so re-running the function across
        cycle boundaries refreshes mid-run git-pull'd code changes,
        matching the prior inline behavior.
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
        [Parameter(Mandatory)][ValidateSet('Outer','Inner','Project','Sequence','StatusService','CachingProxy')][string]$For,
        [Parameter(Mandatory)][string]$ModulesDir
    )
    # Canonical per-kind module lists. Order matters where a downstream
    # module depends on an upstream one being already loaded with -Global
    # (e.g. Test.Host imports Test.VMUtility as a side effect; later
    # callers expect Test.VMUtility's exports to be in scope).
    $sets = @{
        Outer    = @(
            'Test.SingleInstance.psm1', 'Test.Host.psm1', 'Test.YurunaDir.psm1',
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
            'Test.EventSchema.psm1', 'Test.StateFile.psm1',
            'Test.Log.psm1', 'Test.Recovery.psm1', 'Test.RunnerState.psm1'
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
            # inline call sites so dependency edges (Test.Host depends on
            # Test.VMUtility, etc.) are preserved.
            'Test.SingleInstance.psm1', 'Test.YurunaDir.psm1', 'Test.Backoff.psm1',
            'Test.Extension.psm1', 'Test.Host.psm1', 'Test.Status.psm1',
            'Test.Notify.psm1', 'Test.Provenance.psm1',
            'Test.Start-GuestOS.psm1', 'Test.Start-GuestWorkload.psm1',
            # Order: Test.EventSchema + Test.StateFile before Test.Log so
            # Send-CycleEventSafely finds Test-CycleEventSchema and the
            # `.incomplete` marker write resolves Write-YurunaStateFileJson
            # at module-load time; Test.Recovery + Test.Remediation +
            # Test.RunnerState after Test.Log so their module-load Send-
            # CycleEventSafely calls resolve cleanly. Test.SnapshotManifest
            # depends on Test.StateFile; Test.LogRotation is leaf.
            'Test.EventSchema.psm1', 'Test.StateFile.psm1', 'Test.Log.psm1',
            'Test.Recovery.psm1', 'Test.Remediation.psm1', 'Test.RunnerState.psm1',
            'Test.SnapshotManifest.psm1', 'Test.LogRotation.psm1',
            'Test.SequencePlanner.psm1',
            'Test.CachingProxy.psm1', 'Test.Perf.psm1',
            'Test.HostIO.psm1', 'Test.Capability.psm1',
            'Test.KeyCodeRegistry.psm1', 'Test.Transport.psm1'
        )
        Project  = @(
            'Test.Config.psm1', 'Test.YurunaDir.psm1',
            'Test.ConfigPreflight.psm1', 'Test.Host.psm1', 'Test.InnerSpawn.psm1',
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
            'Test.HostIO.psm1', 'Test.Host.psm1',
            'Test.EventSchema.psm1', 'Test.StateFile.psm1',
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
            'Test.Tesseract.psm1', 'Test.ConfigPreflight.psm1'
        )
        StatusService = @(
            # Modules the parent (non-detached-server) status-service
            # code needs: Test.YurunaDir for Initialize-YurunaRuntimeDir /
            # Initialize-YurunaLogDir, Test.VMUtility for IP / port helpers,
            # Test.CachingProxy for state-file + probe helpers, Test.Host
            # for Get-HostType + Initialize-YurunaHost. Test.PortOwner is
            # consumed later in the file (Resolve-PortOrphan) so it is
            # included here too -- one bootstrap pass loads every module
            # the parent needs. The detached status-service child process
            # imports its own modules from a here-string and is not
            # affected by this set.
            'Test.YurunaDir.psm1', 'Test.VMUtility.psm1',
            'Test.CachingProxy.psm1', 'Test.PortOwner.psm1',
            'Test.Host.psm1'
        )
        CachingProxy = @(
            # Union of Start-/Stop-/Test-/Repair-CachingProxy.ps1 inline
            # imports: Test.Host (for Initialize-YurunaHost, Get-HostType,
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
            'Test.Host.psm1'
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

Export-ModuleMember -Function Initialize-YurunaEntryPoint, Get-EntryPointExitCode, Initialize-YurunaEntryPointModuleSet, Wait-WithProgress
