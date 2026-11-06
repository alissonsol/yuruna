<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42b44044-9076-41c3-a573-d5fa643cd35e
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

<#
.SYNOPSIS
    Continuous test cycle entry point. See test/README.md for the
    cycle flow, config schema, notifications, and YURUNA_CACHING_PROXY_SERVICE_IP;
    see docs/test-harness.md for harness architecture.

.PARAMETER ConfigPath
    test.config.yml path (default: next to this script)
.PARAMETER NoGitPull
    Skip `git pull` at cycle start
.PARAMETER NoConfigGate
    Skip this cycle's Test-Config.ps1 preflight
.PARAMETER ConfigGateInherited
    The parent already ran Test-Config.ps1; still check the synchronized project.
.PARAMETER NoStatusService
    Skip the built-in HTTP status service
.PARAMETER CycleDelaySeconds
    Pause between cycles (default 30)
.PARAMETER logLevel
    One of Error|Warning|Information|Verbose|Debug. Each level shows itself + all higher-priority levels (Error highest). Omit to read test.config.yml.logLevel (default "Information").

Strict binding: an unknown or misspelled parameter is a binding error, never
a value silently absorbed into $args while the cycle runs on defaults.

A chain restarted by a host refresh runs this script in one of two extra
roles, chosen from the environment the cycle process sets around the spawn:
preflight (YURUNA_REFRESH_PREFLIGHT with YURUNA_REFRESH_HANDOFF_TOKEN) proves
the host, acknowledges readiness and parks without any git, VM, control or
status-document work; barrier (YURUNA_REFRESH_BARRIER) runs an ordinary
cycle that first waits for the operator's preserved pauses and holds.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = '$global:__YurunaLogFile is the cross-module channel with Yuruna.Log; the proxy reads it to mirror Write-* output to the per-cycle log.')]
[CmdletBinding()]
param(
    [string]$ConfigPath        = $null,
    [switch]$NoGitPull,
    [switch]$NoStatusService,
    # Skip the in-cycle Update-ProjectClone (wipe + re-clone of
    # <RepoRoot>/project from repositories.projectUrl). Used by Invoke-TestProject.ps1,
    # which performs the wipe + clone itself as discrete steps before
    # spawning the inner -- so the inner re-doing them would be wasted
    # work. The cycle still requires <RepoRoot>/project/.git to exist;
    # if it doesn't, the cycle fails fast with a clear message.
    [switch]$NoProjectClone,
    # Skip this cycle's Test-Config.ps1 gate. Forwarded from the outer runner
    # so an operator who bypassed the startup gate for an in-progress edit is
    # not stopped by the same check one layer down.
    [switch]$NoConfigGate,
    [switch]$ConfigGateInherited,
    [int]$CycleDelaySeconds    = 30,
    # Three-state: omitted -> read test.config.yml.logLevel; explicit
    # value -> override JSON for the lifetime of this runner. Cmdline
    # override survives a JSON edit so a `-logLevel Information` started
    # at launch isn't flipped back to "Information" by a hot-reload. Each level
    # in the cascade shows itself + all higher-priority streams (Error is
    # highest), so e.g. logLevel="Warning" enables Error + Warning and
    # silences Information / Verbose / Debug. Validated at parse time.
    [ValidateSet('Error', 'Warning', 'Information', 'Verbose', 'Debug', IgnoreCase = $true)]
    [string]$logLevel
)

# Capture cmdline override for three-state resolution. PSBoundParameters
# is the only reliable source -- `[string]` defaults to '' when omitted,
# which would shadow "operator left it blank" vs "operator typed nothing"
# if we just read $logLevel.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$script:CmdLineLogLevel = if ($PSBoundParameters.ContainsKey('logLevel')) { $logLevel } else { $null }

# Canonical cascade implementation: Test.LogLevel.psm1. See docs/loglevels.md
# for the rank semantics and why we propagate the resolved level to child
# pwsh processes via $env:YURUNA_LOG_LEVEL.
Import-Module (Join-Path $PSScriptRoot 'Test.LogLevel.psm1') -Global -Force

# Exponential-backoff helper for filesystem-state poll loops is
# centralized in Test.Backoff.psm1 (Get-PollDelay) so a tuning change
# lands once. Imported with -Global by Test.Prelude's module sets,
# so callers in this file resolve the function via the global scope.

# Wraps Test.LogLevel\Resolve-LogLevel so the bootstrap stays terse. Called
# (a) at startup with cmdline-only data and (b) after Update-TestConfigFromTemplate
# loads $script:Config. The per-step refresh inside a cycle is the module sibling
# Resolve-RunnerLogLevel (run after each Sync-RunnerCycleConfig), so a JSON edit
# reaches the next step's child processes via $env:YURUNA_LOG_LEVEL.
function Resolve-LogLevel {
    [CmdletBinding()]
    param()
    $cfg = $script:Config
    $configLevel = if ($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('logLevel')) {
        [string]$cfg.logLevel
    } else { $null }
    $null = Test.LogLevel\Resolve-LogLevel -CmdLineLevel $script:CmdLineLogLevel -ConfigLevel $configLevel
}

# Initial pass: cmdline-only (test.config.yml hasn't been loaded yet). The
# next pass runs right after Update-TestConfigFromTemplate; per-step refreshes
# inside a cycle run via Resolve-RunnerLogLevel.
Resolve-LogLevel

# --- REGION: Resolve paths
# Track/log dirs come from Test.YurunaDir; override with
# $env:YURUNA_RUNTIME_DIR / $env:YURUNA_LOG_DIR. Defaults: test/status/runtime/
# and test/status/log/, both served by the status HTTP server.
# This script lives under test/modules/ (kept out of test/'s entry-point
# layer so operators never run it directly -- the outer runner is the
# only legitimate caller). $PSScriptRoot is therefore test/modules/, and
# $TestRoot has to walk one level up to reach test/.
Import-Module (Join-Path $PSScriptRoot 'Test.Prelude.psm1') -Global -Force
$paths          = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder -ConfigPath $ConfigPath
$ModulesDir     = $paths.ModulesDir
$TestRoot       = $paths.TestRoot
$RepoRoot       = $paths.RepoRoot
$StatusDir      = $paths.StatusDir
$StatusTmpl     = Join-Path $StatusDir "status.json.template"
$ScreenshotsDir = Join-Path $TestRoot "screenshots"
$SequencesDir   = $paths.SequencesDir

# Canonical exit codes from Test.Prelude. A future change to the contract
# (e.g. introduce code 2 for "needs operator action") lands in one place.
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure
$ConfigPath     = $paths.ConfigPath
# Publish the resolved config path so Test.Transport's
# Update-TransportDefault reads the SAME file Sync-RunnerCycleConfig uses.
# Outer also publishes this on its own ForwardEnvNames list; setting it
# here covers the standalone-direct invocation case (operator runs
# Invoke-TestRunnerInnerLoop.ps1 by hand).
$env:YURUNA_CONFIG_PATH = $ConfigPath

# See https://yuruna.link/4213a0b3-0014
Initialize-YurunaEntryPointModuleSet -For Inner -ModulesDir $ModulesDir
$null = Initialize-YurunaRuntimeDir
$null = Initialize-YurunaLogDir
# Stable per-host pool identity on the process global (before any NDJSON event)
# so cycle events + status.json carry hostId for cross-host joins. Script-top
# assignment, mirroring $global:__YurunaRunId.
$global:__YurunaHostId = Get-YurunaHostId
$StatusFile = Join-Path $env:YURUNA_RUNTIME_DIR "status.json"

# Refresh role of this inner: normal, preflight or barrier (see the help).
$RefreshMode = Get-YurunaRefreshInnerMode -RuntimeDir $env:YURUNA_RUNTIME_DIR

# Per-cycle helpers live in Test.RunnerInnerLoop.psm1 (imported with the Inner
# module set): Write-InnerLog (exit-path timeline log), the cycle-start
# working-tree-drift guard (Convert-LocalRepoUrlToPath /
# Write-UncommittedChangesWarning), and Assert-CachingProxyServiceStillReachable
# (per-step caching-proxy-service reachability probe).

# ConfigPath was resolved by Initialize-YurunaEntryPoint above.
$TemplatePath = Join-Path $TestRoot "test.config.yml.template"

# --- REGION: Single-instance guard
# See https://yuruna.link/4213a0b3-0015
$RunnerPidFile = Join-Path $env:YURUNA_RUNTIME_DIR "runner.pid"
if ($env:YURUNA_RUNNER_RELAUNCH -ne '1') {
    $priorRunner = Get-RunnerInstanceState -RunnerPidFile $RunnerPidFile -CmdLinePattern 'Start-TestRunner\.ps1'
    switch ($priorRunner.status) {
        'OtherRunner' {
            Write-Output ""
            Write-Output "========"
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_281a00eea15ab59c')
            Write-Output "  PID:     $($priorRunner.pid)"
            Write-Output ((Format-YurunaOperatorMessage -Key 'runner.prior_runner_cleanup_action').Replace("`n", [Environment]::NewLine))
            Write-Output "========"
            # 'test-' is the template default: test.config.yml hasn't been
            # merged yet, so we can't read a user override. If the user
            # picked a custom prefix this cleanup is a no-op -- same as
            # if the guard didn't run.
            Stop-StaleRunner -ProcessId $priorRunner.pid -TestRoot $TestRoot -CleanupPrefix 'test-' -Confirm:$false
        }
        'Stale' {
            if ($priorRunner.pid -gt 0) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_24ae709675586267' -Arguments @{ pid = "$($priorRunner.pid)" })
            }
        }
        default { } # 'None' / 'Self' -- nothing to do
    }
    Remove-Item -LiteralPath $RunnerPidFile -Force -ErrorAction SilentlyContinue
}
# When the outer Start-TestRunner.ps1 spawned us (YURUNA_RUNNER_RELAUNCH=1),
# leave the pidfile alone -- the outer owns the lock for the whole run.
# Standalone (direct) invocation owns its own pidfile (no StartTime
# sidecar -- the outer publishes that).
if ($env:YURUNA_RUNNER_RELAUNCH -ne '1') {
    # Atomic CreateNew lock. Two standalone-direct inner invocations
    # racing on the same host both see "None" from Get-RunnerInstanceState
    # above; the atomic write turns the race into a clear winner/loser.
    $pidWritten = Write-RunnerPidFile -RunnerPidFile $RunnerPidFile -Confirm:$false
    if (-not $pidWritten) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_2b9c15c940311224' -Arguments @{ runnerPidFile = "$RunnerPidFile" })
        exit $ExitFailure
    }
}

# --- REGION: Inner PID + heartbeat
# inner.pid lets the outer's watchdog target the inner pwsh by PID even
# though the outer spawns it via the call-operator (which doesn't return
# a Process handle). Written unconditionally on every inner start, regard-
# less of whether YURUNA_RUNNER_RELAUNCH is set, so a direct-invoke inner
# also publishes its PID for any external monitor.
$InnerPidFile      = Join-Path $env:YURUNA_RUNTIME_DIR "inner.pid"
$HeartbeatFile     = Join-Path $env:YURUNA_RUNTIME_DIR "runner.heartbeat"
# See https://yuruna.link/4213a0b3-0016
$StepHeartbeatFile = Join-Path $env:YURUNA_RUNTIME_DIR "runner.stepHeartbeat"
# See https://yuruna.link/4213a0b3-0017
# Chaos tests only (Test.FaultInjection): a fault before the inner records itself.
if ($env:YURUNA_FAULT_POINTS) { Import-Module (Join-Path $PSScriptRoot 'Test.FaultInjection.psm1') -DisableNameChecking; Invoke-YurunaFaultPoint -Name 'before-inner-pid' }
$null = Write-YurunaProcessStartRecord -Path (Join-Path $env:YURUNA_RUNTIME_DIR 'inner.start') -Confirm:$false
$innerPidWritten = Write-YurunaStateFile -Path $InnerPidFile -Content ([string]$PID) -Confirm:$false
if (-not $innerPidWritten) {
    $innerPidWarn = "inner.pid write to '$InnerPidFile' failed; the outer watchdog cannot target this inner by PID (a hung inner will run unguarded this cycle). Check YURUNA_RUNTIME_DIR permissions/free space."
    Write-Warning $innerPidWarn
    Write-InnerLog $innerPidWarn
}
Write-RunnerStepHeartbeat -Path $StepHeartbeatFile

# Background heartbeat timer lives in Test.RunnerHeartbeat.psm1 (imported with
# the Inner module set): a threadpool-driven runner.heartbeat that proves the
# inner PROCESS is alive even when the runspace is wedged in a long OCR / SSH
# call; no decision reads it. The watchdog judges the in-runspace
# runner.stepHeartbeat (seeded above, touched as work completes), and its one
# writer reports failed writes (Get-RunnerHeartbeatError counts them).
Start-RunnerHeartbeat -Path $HeartbeatFile

# --- REGION: Unattended contract
# See https://yuruna.link/4213a0b3-0018
$env:YURUNA_NONINTERACTIVE = '1'
# git: the network helpers in Test.HostGit already neutralize these per call,
# but bare `& git` sites elsewhere inherit whatever the launch shell had.
$env:GIT_TERMINAL_PROMPT = '0'
$env:GIT_ASKPASS         = ''
$env:SSH_ASKPASS         = ''
$env:GCM_INTERACTIVE     = 'never'
# ShouldProcess prompts from ConfirmImpact High or -Confirm would otherwise
# park the cycle on a confirmation nobody can answer.
$global:ConfirmPreference = 'None'
# Read-Host / PromptForChoice read Console.In. Pointing it at the null reader
# makes them return/throw immediately instead of blocking on the inherited
# terminal. Best-effort: a host without a usable console still runs.
try {
    [System.Console]::SetIn([System.IO.TextReader]::Null)
} catch {
    Write-Verbose "Console.SetIn(TextReader.Null) unavailable (non-fatal): $($_.Exception.Message)"
}

# Enter the guarded preamble. Everything from here to the sequence handoff is
# covered by the watchdog's tight testCycle.preambleTimeoutSeconds bound rather
# than the 45-minute step budget; Write-RunnerPhase refreshes runner.stepHeartbeat
# as it goes, so slow-but-progressing preamble work is not mistaken for a stall.
Write-RunnerPhase -Phase 'bootstrap'
# Note: $env:YURUNA_LOG_LEVEL is published by Resolve-LogLevel (here at
# bootstrap) and by Resolve-RunnerLogLevel per step inside the cycle. Children
# spawned from this runner inherit the value from the env block and apply the
# same severity cascade.

# --- REGION: Import all modules (suppress engine verbose noise during imports)
$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"

$yurunaLogModule = Join-Path -Path $RepoRoot -ChildPath "automation" -AdditionalChildPath "Yuruna.Log.psm1"
if (Test-Path $yurunaLogModule) {
    Import-Module $yurunaLogModule -Global -Force
}

# Shared retry policy with automation/yuruna-retry.sh (Get-YurunaRetryBackoff).
# Used by the post-cycle-failure backoff path in the cycle catch handler.
# --- REGION: https://yuruna.link/4220a755-0003
$yurunaRetryModule = Join-Path -Path $RepoRoot -ChildPath "automation" -AdditionalChildPath "Yuruna.Retry.psm1"
if (Test-Path $yurunaRetryModule) {
    Import-Module $yurunaRetryModule -Global -Force
}

# See https://yuruna.link/4213a0b3-0019

$global:VerbosePreference = $savedVerbose
# Chaos tests only (Test.FaultInjection): a fault once the module set loaded.
if ($env:YURUNA_FAULT_POINTS) { Import-Module (Join-Path $PSScriptRoot 'Test.FaultInjection.psm1') -DisableNameChecking; Invoke-YurunaFaultPoint -Name 'inner-import' }

# --- REGION: Bootstrap status.json from template if missing
# A preflight inner writes no status document: the dashboard keeps the last
# real cycle until the first ordinary cycle of the resumed chain.
if ($RefreshMode.Mode -ne 'preflight' -and -not (Test-Path $StatusFile)) {
    if (Test-Path $StatusTmpl) {
        Copy-Item -Path $StatusTmpl -Destination $StatusFile
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_9073dca2f5030e8f')
    } else {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_8ee4f8acc6c8cab7' -Arguments @{ statusTmpl = "$StatusTmpl" }); exit $ExitFailure
    }
}

# test.config.yml <-> template reconciliation lives in Test.ConfigSync.psm1
# (imported with the Inner module set): ConvertTo-MergedHashtable,
# Copy-HashtableWithoutSecretNode, Test-ConfigMatchesTemplateShape,
# Update-TestConfigFromTemplate (the cycle-start overlay + structure-departure
# guard), and Hide-SecretsInConfig (redacts the 'secrets' node before logging).

# Mutable per-run config state consumed by Invoke-RunnerInnerCycle
# (Test.RunnerInnerLoop.psm1): the mtime parse-cache slots plus the reloadable
# knobs. Built once here so the cmdline log level and the -CycleDelaySeconds
# fallback are captured; Sync-RunnerCycleConfig mutates it each step inside the
# cycle, keeping the parse-cache + reloadable-knob rules in one tested place.
$script:RunnerCfgState = New-RunnerConfigState -CmdLineLogLevel $script:CmdLineLogLevel -CycleDelaySecondsFallback $CycleDelaySeconds

# --- REGION: Read config (syncs against template first)
if (-not (Test-Path $ConfigPath) -and -not (Test-Path $TemplatePath)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_ac92ad6675163216' -Arguments @{ configPath = "$ConfigPath"; templatePath = "$TemplatePath" }); exit $ExitFailure
}
if ($RefreshMode.Mode -eq 'preflight') {
    # Read only: the preflight must not rewrite the operator's config file.
    $Config = $null
    try { $Config = Read-TestConfig -Path $ConfigPath } catch {
        Write-Verbose "Refresh preflight: config unreadable: $($_.Exception.Message)"
        $Config = $null
    }
} else {
    $Config = Update-TestConfigFromTemplate -ConfigPath $ConfigPath -TemplatePath $TemplatePath
}
$script:Config = $Config
# Re-resolve now that JSON values are loaded -- the early Resolve-LogLevel
# at the top of the script saw cmdline-only data. Per-step refreshes inside a
# cycle run via Resolve-RunnerLogLevel.
Resolve-LogLevel

# --- REGION: Pre-cycle config gate
# See https://yuruna.link/4213a0b3-001a
Import-Module (Join-Path $ModulesDir 'Test.SourceSelection.psm1') -Global -Force -DisableNameChecking
$cycleSourceHandoff = $null
if ($env:YURUNA_CYCLE_GENERATION -and $RefreshMode.Mode -ne 'preflight') {
    $cycleSourceHandoff = Read-GitSourceHandoff -CycleGeneration $env:YURUNA_CYCLE_GENERATION -RepoRoot $RepoRoot -ConfigPath $ConfigPath
    if (-not $cycleSourceHandoff) {
        # A resident old runner can start the new inner immediately after its
        # update. Record actual HEAD; no upstream attestation exists for it.
        $installed = Get-InstalledGitSourceSelection -RepoRoot $RepoRoot
        if (-not (Write-GitSourceHandoff -CycleGeneration $env:YURUNA_CYCLE_GENERATION -RepoRoot $RepoRoot -ConfigPath $ConfigPath -Framework $installed -Confirm:$false)) { throw 'source-handoff-write-failed' }
    }
}
if ($RefreshMode.Mode -ne 'preflight') {
    Write-RunnerPhase -Phase 'config-gate'
    $gateSkipReason = if ($NoConfigGate) { '-NoConfigGate' } else { 'parent command already validated configuration' }
    $gate = Invoke-ConfigGate -TestRoot $TestRoot -ConfigPath $ConfigPath -Skip:($NoConfigGate -or $ConfigGateInherited) -SkipReason $gateSkipReason -CallerName 'cycle start'
    $gateCommitSha = ([string](& git -C $RepoRoot rev-parse HEAD 2>$null)).Trim()
    try {
        $null = Write-ConfigGateArtifact -RuntimeDir $env:YURUNA_RUNTIME_DIR -Gate $gate `
            -AttemptGeneration ([string]$env:YURUNA_CYCLE_GENERATION) -FrameworkCommitSha $gateCommitSha -Confirm:$false
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.gate_evidence_save_failed' -Arguments @{ detail = [string]$_.Exception.Message })
    }
    if (-not $gate.passed) { exit (Get-ConfigGateFailureExitCode) }
}

# --- REGION: Bootstrap
$HostType = Get-HostType

# --- REGION: Host-refresh preflight
# The whole preflight: prove the host from this ancestry, acknowledge, park
# until the refresh releases the runner, and exit. Nothing below this block
# runs in preflight -- no host registration, no stash marker (an Apple Events
# call on macOS), no host-condition set, no VM stop or service restore, no
# status service.
if ($RefreshMode.Mode -eq 'preflight') {
    $preflightDeadline = New-YurunaDeadline -TotalMilliseconds 120000
    $preflight = Invoke-YurunaRefreshPreflight -Mode $RefreshMode -HostType ([string]$HostType) -RepoRoot $RepoRoot `
        -Config $Config -StepHeartbeatFile $StepHeartbeatFile -Deadline $preflightDeadline -RuntimeDir $env:YURUNA_RUNTIME_DIR
    $preflightExit = $ExitFailure
    if ($preflight.State -eq 'ready') {
        $release = Wait-YurunaRefreshRelease -TokenId ([string]$RefreshMode.TokenId) -Purpose ([string]$RefreshMode.Purpose) `
            -StepHeartbeatFile $StepHeartbeatFile -ShutdownState @{ Requested = $false } -RuntimeDir $env:YURUNA_RUNTIME_DIR
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.refresh_preflight_released' -Arguments @{ outcome = [string]$release.Outcome }) -InformationAction Continue
        if ($release.Outcome -in @('released', 'not-parked')) { $preflightExit = $ExitOk }
    }
    try { Stop-RunnerHeartbeat } catch { $null = $_ }
    try {
        $innerFilePid = 0
        try { $innerFilePid = [int]((Get-Content $InnerPidFile -Raw -ErrorAction Stop).Trim()) } catch { $innerFilePid = 0 }
        if ($innerFilePid -eq $PID) { Remove-Item $InnerPidFile -Force -ErrorAction SilentlyContinue }
    } catch { $null = $_ }
    Clear-RunnerPhase
    Write-InnerLog "refresh preflight finished ($($preflight.State)); exiting with code $preflightExit"
    exit $preflightExit
}

if (-not $HostType) { exit $ExitFailure }
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_82bcd42076e94095' -Arguments @{ hostType = "$HostType" })
Write-RunnerPhase -Phase 'host-detect'

# Announce here, prompt at the port-map refresh below: on host.ubuntu.kvm that
# refresh writes systemd forwarder units with sudo, and the operator should know
# a password may be wanted before the cycle's long VM work starts. No prompt at
# this point -- most cycles never reach a sudo call at all.
if ($HostType -eq 'host.ubuntu.kvm') {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_5a205d60747de8fa')
}

# Externalize this host's identity + capabilities to runtime/host.registration.json
# (served at /runtime/host.registration.json) for the multi-host pool-aggregator service.
# Once per cycle, main runspace, best-effort. See docs/opportunities.md.
if (Get-Command Write-HostRegistrationRecord -ErrorAction SilentlyContinue) {
    Write-RunnerPhase -Phase 'host-registration'
    $null = Write-HostRegistrationRecord -HostType $HostType -RepoRoot $RepoRoot
}

# Wire the host driver so the contract functions (New-VM, Start-VM,
# Stop-VM, Send-Text, Get-VMScreenshot, ...) are resolvable from this
# script's session without any HostType branches.
Write-RunnerPhase -Phase 'host-driver'
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

# --- REGION: Held-control barrier
# The first ordinary cycle after a host refresh adopts the operator's
# preserved pauses and holds before anything below can touch a VM or the
# host: the stash marker refresh, the host-condition set, the concurrent-VM
# stop, the service-VM restore and the cycle sweeps all come after this. The
# Ctrl+C handler is not registered yet, so a local handle stands in.
if ($RefreshMode.Mode -eq 'barrier') {
    Write-RunnerPhase -Phase 'refresh-barrier'
    $barrier = Wait-YurunaHeldControlBarrier -RuntimeDir $env:YURUNA_RUNTIME_DIR -StepHeartbeatFile $StepHeartbeatFile `
        -ShutdownState @{ Requested = $false } -Config $Config -HostType $HostType -RequestId ([string]$RefreshMode.RequestId)
    if ($barrier.Outcome -eq 'shutdown') { exit $ExitOk }
    if ($barrier.Outcome -eq 'lab-exhausted') { exit $ExitFailure }
    Write-RunnerPhase -Phase 'host-detect'
}

# Keep a stash-service host's advertised address current: re-resolve the stash-service VM's guest IP
# (single-shot, now that Get-VMIp is wired) and rewrite the marker's stashBaseUrl when
# it changes, so the Extension cell's /go/stash deep-link self-heals after a DHCP lease
# change. The refreshed URL folds into host.registration.json on the next cycle's
# Write-HostRegistrationRecord. No-op when this host runs no stash service.
if (Get-Command Update-StashServiceMarkerAddress -ErrorAction SilentlyContinue) {
    Write-RunnerPhase -Phase 'stash-address'
    $null = Update-StashServiceMarkerAddress
}

Write-RunnerPhase -Phase 'host-conditions'
$hostConditionVerdict = Get-HostConditionVerdict -HostType $HostType
if (-not $hostConditionVerdict.Passed) {
    # The failure record names the refused condition: an exit code alone
    # leaves the outer loop scoring an unrecorded outcome.
    Write-CycleInfraFailure -Stage 'HostCondition' -FailureClass $hostConditionVerdict.FailureClass -HostType $HostType `
        -Severity 'hard' -GuestKey '(host)' -ErrorMessage $hostConditionVerdict.Message
    exit $ExitFailure
}

# --- REGION: Concurrent-VM admission
# See https://yuruna.link/4213a0b3-001b
Write-RunnerPhase -Phase 'vm-admission'
$admissionStep = Invoke-CycleAdmissionStep -HostType $HostType
if (-not $admissionStep.Ok) {
    exit $admissionStep.ExitCode
}

# --- REGION: Cycle-start host guest-network gate
# See https://yuruna.link/4213a0b3-001c
Write-RunnerPhase -Phase 'host-network'
$hostNetworkGate = Invoke-CycleHostNetworkGate -HostType $HostType -RuntimeDir $env:YURUNA_RUNTIME_DIR -TestRoot $TestRoot -RepoRoot $RepoRoot
foreach ($line in $hostNetworkGate.SweepOutput) { Write-Output $line }
if (-not $hostNetworkGate.Ok) { exit $ExitFailure }
# The vSwitch repair below clears the same three files when it heals the switch.
$HostNetworkStateFile  = $hostNetworkGate.StateFile
$HostNetworkBannerFile = $hostNetworkGate.BannerFile
$HostNetworkRecordFile = $hostNetworkGate.RecordFile

Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_71bb57cd92796a43' -Arguments @{ dIR = "$env:YURUNA_RUNTIME_DIR" })
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_4a30dc2d3855f67b' -Arguments @{ dIR = "$env:YURUNA_LOG_DIR" })

# --- REGION: Stale cycle-restart flag sweep
# See https://yuruna.link/4213a0b3-001e
if (Get-Command Clear-StaleControlState -ErrorAction SilentlyContinue) {
    $ctl = Clear-StaleControlState -Scope Startup -SkipInteractiveState -RuntimeDir $env:YURUNA_RUNTIME_DIR -Confirm:$false
    if ($ctl.cycleRestartCleared) {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_298b67c69aa4a722' -Arguments @{ cycleRestartAgeSeconds = "$($ctl.cycleRestartAgeSeconds)" })
    }
    foreach ($w in $ctl.warnings) { Write-Verbose "Stale control-state sweep: $w" }
}

# See https://yuruna.link/4213a0b3-001f
Import-Module (Join-Path $ModulesDir 'Test.CachingProxyService.psm1') -Global -Force -DisableNameChecking -Verbose:$false

# --- REGION: Cycle-start service-VM restore
# See https://yuruna.link/4213a0b3-0020
Write-RunnerPhase -Phase 'service-vm-restore'
$null = Invoke-CycleServiceVmRestore -HostType $HostType -RuntimeDir $env:YURUNA_RUNTIME_DIR

# --- REGION: Cycle-start External vSwitch repair (Hyper-V only)
# See https://yuruna.link/4213a0b3-0021
$null = Invoke-CycleExternalSwitchRepair -HostType $HostType -RepoRoot $RepoRoot `
    -StateFile $HostNetworkStateFile -BannerFile $HostNetworkBannerFile -RecordFile $HostNetworkRecordFile

# --- REGION: Cycle-start caching-proxy-service gate
# See https://yuruna.link/4213a0b3-0023
Write-RunnerPhase -Phase 'caching-proxy-gate'
$cachingProxyGate = Invoke-CycleCachingProxyGate -Config $Config -RuntimeDir $env:YURUNA_RUNTIME_DIR
foreach ($line in $cachingProxyGate.Output) { Write-Output $line }
$cachingProxyUrl = $cachingProxyGate.CachingProxyUrl

$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"
# -Global without -Force: this process is fresh per cycle, so a forced
# re-import only re-parses a module the set above already loaded, and one
# into this script's scope evicts the global copy that other modules call.
Import-Module (Join-Path $ModulesDir "Test.OcrEngine.psm1") -Global
Import-Module (Join-Path $ModulesDir "Test.Tesseract.psm1") -Global
# Test.Ssh exposes Get-GuestAddress + Wait-GuestIp for the per-guest IP
# suffix printed alongside Start-VM: PASS. Imported even though SSH itself
# is optional, because IP discovery uses host-side facilities (Hyper-V
# KVP, utmctl, dhcpd_leases) and works without sshd in the guest.
Import-Module (Join-Path $ModulesDir "Test.Ssh.psm1") -Global
$global:VerbosePreference = $savedVerbose
$activeEngines = Get-EnabledOcrProvider
$combineMode = ($env:YURUNA_OCR_COMBINE -eq 'And') ? 'And' : 'Or'
Write-Debug "OCR engines: $($activeEngines -join ', ') | combine: $combineMode"
if (-not (Assert-TesseractInstalled)) { exit $ExitFailure }

Write-RunnerPhase -Phase 'status-service'
$startScript = Join-Path $TestRoot "service/Start-StatusService.ps1"
# Startup: no -Restart -- Start-YurunaStatusServiceIfEnabled lets the server
# compare-and-skip the relaunch when its in-memory code is still current (zero
# downtime on the common no-change cycle). The shared gate (Test.Prelude) keeps
# enabled / -NoStatusService / port handling identical across the entry-point trio.
$null = Start-YurunaStatusServiceIfEnabled -Config $Config -StartScript $startScript -NoStatusService:$NoStatusService

# NOTE: the config service (mTLS NAS-credential endpoint) is NOT started here.
# It is a companion of the CACHING PROXY (it serves NAS creds to the caching-proxy-service
# / stash-service VMs a host created), so its lifecycle belongs to Start-CachingProxyServiceVM.ps1
# (Step 2.6) on the caching-proxy-service host -- not the test runner. A plain test-runner
# host that never brings up a caching-proxy service must not start it.

# --- REGION: Ctrl+C handler
# The CancelKeyPress contract lives in Test.Prelude's
# Register-/Unregister-EntryPointCancelHandler so the register/poll/tear-down
# shape stays identical across every entry point. The returned hashtable is the
# shared shutdown flag: the event action (running in its own SessionState) flips
# ['Requested'], and the cycle polls it at safe points. Its plain-hashtable key
# indexing is interchangeable with the prior ConcurrentDictionary for the
# single boolean flag the loop reads.
$script:ShutdownState = Register-EntryPointCancelHandler -SourceIdentifier YurunaCancelKey
$script:ActiveVMName      = $null
$script:CycleFinalized    = $true    # have Complete-Run/Stop-LogFile been called?

# --- REGION: Continuous test loop
# The per-cycle work runs in Invoke-RunnerInnerCycle (Test.RunnerInnerLoop.psm1).
# The State hashtable threads paths, flags, the shared ShutdownState reference,
# and the config-reload state in, and carries the cycle outcome + gating
# counters back onto the locals the exit path below reads.
$cycleState = @{
    RepoRoot=$RepoRoot; TestRoot=$TestRoot; SequencesDir=$SequencesDir; ScreenshotsDir=$ScreenshotsDir
    StatusFile=$StatusFile; ConfigPath=$ConfigPath; TemplatePath=$TemplatePath; HostType=$HostType; ModulesDir=$ModulesDir
    NoStatusService=[bool]$NoStatusService; NoGitPull=[bool]$NoGitPull; NoProjectClone=[bool]$NoProjectClone; CycleDelaySeconds=$CycleDelaySeconds
    NoConfigGate=[bool]$NoConfigGate
    CachingProxyServiceUrl=$cachingProxyUrl; StartScript=$startScript; StepHeartbeatFile=$StepHeartbeatFile
    ShutdownState=$script:ShutdownState; RunnerCfgState=$script:RunnerCfgState; Config=$script:Config
}
if ($env:YURUNA_CYCLE_GENERATION -and $RefreshMode.Mode -ne 'preflight') {
    $cycleState['SourceHandoff'] = Read-GitSourceHandoff -CycleGeneration $env:YURUNA_CYCLE_GENERATION -RepoRoot $RepoRoot -ConfigPath $ConfigPath
}
# Leave the guarded preamble. The cycle body contains work that is legitimately
# long and unbounded -- the weekly base-image download most of all -- and from
# its first step Invoke-Sequence takes over refreshing runner.stepHeartbeat.
# Dropping runner.phase restores the full testCycle.stepTimeoutSeconds bound,
# i.e. exactly the behavior that shipped before the preamble bound existed.
Clear-RunnerPhase
Invoke-RunnerInnerCycle -State $cycleState
$OverallPassed        = $cycleState.OverallPassed
$FailedGuest          = $cycleState.FailedGuest
$FailedStep           = $cycleState.FailedStep
$FailureMessage       = $cycleState.FailureMessage
$CycleStartUtc              = $cycleState.CycleStartUtc
$LogFile              = $cycleState.LogFile
$GitCommit            = $cycleState.GitCommit
$ProjectGitCommit     = $cycleState.ProjectGitCommit
$ConsecutiveFailures  = $cycleState.ConsecutiveFailures
$ConsecutiveSuccesses = $cycleState.ConsecutiveSuccesses
$ConsecutiveCrashes   = [int]$cycleState.ConsecutiveCrashes
$AlertArmed           = $cycleState.AlertArmed
$FailuresBeforeAlert  = $cycleState.FailuresBeforeAlert
$GatingFile           = $cycleState.GatingFile

Write-InnerLog "post-loop cleanup: Unregister-Event YurunaCancelKey"
Unregister-EntryPointCancelHandler -SourceIdentifier YurunaCancelKey
Write-InnerLog "post-loop cleanup: Unregister-Event/Remove-Job complete"

# Persist gating state so the next single-cycle inner respawn picks
# up the correct (Armed | Fired) phase. Writes are best-effort.
try {
    $null = Write-YurunaStateFileJson -Path $GatingFile -Depth 4 -Compress:$false -WithBom -Confirm:$false -InputObject @{
        consecutiveFailures  = $ConsecutiveFailures
        consecutiveSuccesses = $ConsecutiveSuccesses
        consecutiveCrashes   = $ConsecutiveCrashes
        alertArmed           = $AlertArmed
        savedAt              = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
} catch {
    Write-Verbose "Gating-state save failed (best-effort, ignoring): $($_.Exception.Message)"
}
Write-InnerLog "post-loop cleanup: gating state saved"
if ($cycleState.RefreshGated) {
    # Held by a host refresh before any change: the cycle process reads
    # runner.refresh-gated.json and reports refresh-gated, so there is no
    # failure to announce here.
    Write-InnerLog "cycle held by the host-refresh gate; nothing was changed"
}

# --- REGION: Heartbeat cleanup
# Dispose the threadpool timer first so it can't race a final file write
# against the inner.pid removal that the outer's watchdog reads to know
# we exited cleanly. Errors are swallowed -- this runs after the cycle
# already produced its exit code, so a cleanup hiccup must not change it.
try { Stop-RunnerHeartbeat } catch { $null = $_ }
try {
    if (Test-Path $InnerPidFile) {
        $innerFilePid = 0
        try { $innerFilePid = [int]((Get-Content $InnerPidFile -Raw -ErrorAction Stop).Trim()) } catch { $innerFilePid = 0 }
        # Only remove if it still points to us. Don't clobber a competing
        # inner's pidfile (same pattern as the runner.pid cleanup below).
        if ($innerFilePid -eq $PID) {
            Remove-Item $InnerPidFile -Force -ErrorAction SilentlyContinue
        }
    }
} catch { $null = $_ }

# Outer (Start-TestRunner.ps1) owns the runner.pid file across our
# single-cycle lifetime; only release it if the inner was invoked
# directly (no YURUNA_RUNNER_RELAUNCH=1 from the outer).
if ($env:YURUNA_RUNNER_RELAUNCH -ne '1') {

# Release runner.pid on graceful exit -- only if it still points to us.
# A competing runner may have taken over and rewritten the file with its
# own PID; don't clobber theirs. Crash / kill -9 / power loss leaves a
# stale PID; next startup's single-instance guard handles it.
try {
    if (Test-Path $RunnerPidFile) {
        $filePid = 0
        # Malformed pidfile -> leave it alone (don't remove something we
        # can't identify as ours). $filePid stays 0 so the -eq $PID check
        # below is false.
        try { $filePid = [int]((Get-Content $RunnerPidFile -Raw -ErrorAction Stop).Trim()) } catch { $filePid = 0 }
        if ($filePid -eq $PID) {
            Remove-Item $RunnerPidFile -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    # Shutdown cleanup is best-effort: any failure (pidfile race with a
    # competing runner, fs permission blip) leaves a possibly-stale file.
    # Fine -- the single-instance guard handles it on next launch.
    Write-Verbose "Shutdown pidfile cleanup swallowed error: $($_.Exception.Message)"
}

}  # end of: if YURUNA_RUNNER_RELAUNCH -ne '1' (pidfile cleanup)

# --- REGION: Failure notification (only reached when stopOnFailure breaks the loop)
if (-not $OverallPassed -and $FailedGuest -and -not $cycleState.RefreshGated) {
    Write-Output ""
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_729aea0314e609b0')
    Write-Output "  Host:    $HostType"
    Write-Output "  Guest:   $FailedGuest"
    Write-Output "  Step:    $FailedStep"
    Write-Output "  Error:    $FailureMessage"
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_883feeb4c5f702cc' -Arguments @{ cycleStartUtc = "$CycleStartUtc" })
    $CommitLine = if ($ProjectGitCommit) { "$GitCommit, $ProjectGitCommit" } else { $GitCommit }
    Write-Output "  Commit:   $CommitLine"
    Write-Output "  Log:     $LogFile"
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_71ba518dfaab6431' -Arguments @{ consecutiveFailures = "$ConsecutiveFailures"; failuresBeforeAlert = "$FailuresBeforeAlert"; suppressed = "$(if ($AlertArmed) {'(armed)'} else {'(suppressed)'})" })
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_0c9556bde1cd92fc')
    Write-Output "  pwsh test/Start-TestRunner.ps1 -NoGitPull -logLevel Debug"

    if ($AlertArmed -and $ConsecutiveFailures -ge $FailuresBeforeAlert) {
        # EventData: post-loop alert (stopOnFailure path). Same
        # contract as the in-cycle handler above -- read schema-v2
        # last_failure.json from the cycle folder, augment with cycle/
        # host context, remediate below, then ship via
        # Send-CycleFailureNotification (its body JSON trailer and
        # -EventData both carry this payload).
        $postLoopEventData = Get-FailureEventData `
            -HostType      $HostType `
            -Hostname      (hostname) `
            -GuestKey      $FailedGuest `
            -StepName      $FailedStep `
            -ErrorMessage  $FailureMessage `
            -CycleStartUtc       $CycleStartUtc `
            -GitCommit     $GitCommit `
            -ProjectCommit $ProjectGitCommit
        # Advisory remediation dispatch (same as the in-cycle path): computes
        # the recommendation, emits the NDJSON breadcrumb, and persists the
        # durable last_remediation.json into the cycle folder (replicated to the
        # pool). Records the decision; never acts. Skip the planner-abort case
        # (FailedGuest '(planner)' / PlannerFatal): a duplicate-sequence config
        # error is never auto-remediable and would only route to
        # operator_intervention_required.
        if ((Get-Command Invoke-Remediation -ErrorAction SilentlyContinue) -and $FailedGuest -ne '(planner)') {
            $remediation = Invoke-Remediation -FailureRecord $postLoopEventData
            if ($remediation) { Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_975a24a1b1bf5b90' -Arguments @{ recommendation = "$($remediation.Recommendation)"; rationale = "$($remediation.Rationale)" }) }
        }
        # Payload built + (planner-guarded) remediated above; pass it
        # pre-built so the helper ships the same hashtable without
        # rebuilding or reordering remediation.
        Send-CycleFailureNotification `
            -HostType      $HostType `
            -SubjectSuffix "$FailedGuest / $FailedStep" `
            -GuestKey      $FailedGuest `
            -StepName      $FailedStep `
            -ErrorMessage  $FailureMessage `
            -CycleStartUtc       $CycleStartUtc `
            -GitCommit     $GitCommit `
            -EventData     $postLoopEventData
        # Disarm so a stopOnFailure stream (this block fires only when
        # stopOnFailure broke before the in-cycle inline handler could
        # update gating state) doesn't re-alert on every outer respawn.
        # The disarmed state is persisted further down by the gating-state
        # save, so the next inner reads it on entry. Successive successes
        # rearm via the in-cycle handler.
        $AlertArmed           = $false
        $ConsecutiveSuccesses = 0
    } else {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_0805b57566905173' -Arguments @{ consecutiveFailures = "$ConsecutiveFailures"; failuresBeforeAlert = "$FailuresBeforeAlert"; alertArmed = "$AlertArmed" })
    }
}

# Re-save gating state so the disarmed flag set by the post-loop block
# (above) is captured. The earlier save right after the cycle loop
# captures the in-cycle inline handler's state; this second write covers
# the stopOnFailure path.
try {
    $null = Write-YurunaStateFileJson -Path $GatingFile -Depth 4 -Compress:$false -WithBom -Confirm:$false -InputObject @{
        consecutiveFailures  = $ConsecutiveFailures
        consecutiveSuccesses = $ConsecutiveSuccesses
        consecutiveCrashes   = $ConsecutiveCrashes
        alertArmed           = $AlertArmed
        savedAt              = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
} catch {
    Write-Verbose "Final gating-state save failed (best-effort, ignoring): $($_.Exception.Message)"
}

# A pass that skipped a planned guest exits with the degraded code: a caller that
# reads 0 as a pass must not count a cycle that tested less than it planned.
$finalCode = if ($cycleState.ConfigGateFailed) { Get-ConfigGateFailureExitCode } elseif ($OverallPassed -and $cycleState.Degraded) { Get-DegradedCycleExitCode } else { $OverallPassed ? $ExitOk : $ExitFailure }
Write-InnerLog "about to exit with code $finalCode"
exit $finalCode
