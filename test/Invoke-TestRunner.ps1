<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456707
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
    Resilient outer runner. Eternal loop:
      1. git pull the framework repo (this clone)
      2. spawn modules/Invoke-TestInnerRunner.ps1 in a fresh pwsh per cycle
         (so module/Add-Type caches are reset on every cycle, uniformly
          on Windows AND macOS)
      3. on inner success -- immediately loop (next iteration pulls + respawns)
      4. on inner failure -- pause up to FailurePauseMaxSeconds (cap)
         OR until a new framework commit lands, whichever first, polled
         every FailureCommitPollSeconds. Persistent failures don't burn
         the host in a tight retry loop; new commits resume work as soon
         as fresh code lands.
    Stops only on Ctrl+C. Per the resilience contract, anything else --
    a flaky network, a hung sequence, an unhandled exception inside the
    inner -- is just another failure that the outer absorbs and retries.

.DESCRIPTION
    Two-process design: a thin outer (this file) and a single-cycle
    inner (modules/Invoke-TestInnerRunner.ps1 -- intentionally placed
    under modules/ so it's not mistaken for an entry-point script in the
    test/ folder; the operator never invokes it directly).
    Why the split:
      * fresh pwsh per cycle on every host -- one code path, no platform-
        specific in-process / spawn fork
      * O(1) resident memory; outer is the only resident process and
        spends most of its time in Start-Process -Wait
      * backoff with commit polling stops infinite-failure burn

    See test/README.md for cycle flow, config, notifications, and the
    YURUNA_CACHING_PROXY_IP knob; docs/test-harness.md for harness architecture.

.PARAMETER ConfigPath           test.config.yml path (forwarded to inner)
.PARAMETER NoGitPull            Skip git pull (forwarded; outer also skips its own pull)
.PARAMETER NoServer             Skip the built-in HTTP status server (forwarded)
.PARAMETER CycleDelaySeconds    Pause between cycles inside the inner (forwarded; default 30)
.PARAMETER logLevel             Error|Warning|Information|Verbose|Debug (forwarded)
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = '$global:__YurunaHostId is the cross-host pool-identity channel; set at script top so NDJSON events + status.json carry hostId for pool joins.')]
param(
    [string]$ConfigPath        = $null,
    [switch]$NoGitPull,
    [switch]$NoServer,
    # Skip the pre-cycle Test-Config.ps1 gate. Use only for ad-hoc /
    # in-progress edit runs where the operator knowingly accepts that
    # a misconfigured test.config.yml / vault.yml / users.yml will fail
    # at first cycle instead of at startup. Production / CI / scheduled
    # runs MUST NOT pass this switch.
    [switch]$NoConfigGate,
    [int]$CycleDelaySeconds    = 30,
    [ValidateSet('Error', 'Warning', 'Information', 'Verbose', 'Debug', IgnoreCase = $true)]
    [string]$logLevel
)

# === Tunable backoff constants ==============================================
# Hardcoded at top-of-file by design -- NOT in test.config.yml -- so an
# operator can grep + adjust without a config-schema migration. Tune with
# care: the cap is meant to keep a wedged host from burning git/network
# while still being short enough that a one-off transient (network blip,
# mirror hiccup) recovers within an hour without manual intervention.
$script:FailurePauseMaxSeconds    = 60 * 60   # cap a backoff at 60 min
$script:FailureCommitPollSeconds  = 5 * 60    # check origin every 5 min
$script:OuterPullErrorSleepSec    = 30        # short pause if outer's own git pull errors
$script:InnerSpawnErrorSleepSec   = 30        # short pause if Start-Process itself fails
$script:StepTimeoutMinutesDefault = 45        # watchdog: kill inner when heartbeat older than this
$script:WatchdogPollSeconds       = 30        # how often the watchdog re-checks the heartbeat file

# --- REGION: https://yuruna.link/memory#why-yuruna-env-vars-are-snapshotted-and-re-asserted-across-inner-spawns
$script:ForwardEnvNames = @(
    'YURUNA_CACHING_PROXY_IP',  # Test-CachingProxy / external-cache branch
    'YURUNA_RUNTIME_DIR',         # Test.YurunaDir override
    'YURUNA_LOG_DIR',           # Test.YurunaDir override
    'YURUNA_LOG_LEVEL',         # cascade visibility
    'YURUNA_OCR_COMBINE',       # OCR combine mode (And|Or)
    'YURUNA_CONFIG_PATH',       # operator-supplied -ConfigPath (Sync-RuntimeConfig + Test.Transport agree)
    'YURUNA_STATUS_PUBLIC_URL'  # off-host dashboard URL for failure-notification deep links
)

# === Resolve paths ==========================================================
# Canonical path bundle from Test.Prelude. Same call shape used by
# Test-Project, Test-Sequence, and Invoke-TestInnerRunner -- adding a
# new entry point uses the same one-liner.
Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -ConfigPath $ConfigPath
$TestRoot    = $paths.TestRoot
$RepoRoot    = $paths.RepoRoot
$ModulesDir  = $paths.ModulesDir
$ConfigPath  = $paths.ConfigPath
# Publish the resolved config path so every cross-module reload site
# (Sync-RuntimeConfig in the inner runner, Update-TransportDefault in
# Test.Transport, future similar callers) reads the SAME file when the
# operator passes -ConfigPath <elsewhere>. Without this, Test.Transport
# falls back to the in-tree template and the operator's dashboard edits
# to vmCommunication.* never take effect.
$env:YURUNA_CONFIG_PATH = $ConfigPath
$InnerScript = Join-Path $ModulesDir 'Invoke-TestInnerRunner.ps1'
if (-not (Test-Path -LiteralPath $InnerScript)) {
    Write-Error "Invoke-TestInnerRunner.ps1 not found at $InnerScript"
    exit (Get-EntryPointExitCode -Outcome Failure)
}

# Outer entry-point's canonical module set: one Test.Prelude bootstrap
# call loads Test.Host, RuntimeDir, LogDir, Config, InnerSpawn,
# ConfigGate, Capability, and SingleInstance. See
# Initialize-YurunaEntryPointModuleSet for the per-kind module lists.
Initialize-YurunaEntryPointModuleSet -For Outer -ModulesDir $ModulesDir

# Auto-relaunch under `sg libvirt -c "..."` on host.ubuntu.kvm when this
# shell's running supplementary group set lacks libvirt. Done BEFORE we
# spawn any inner pwsh -- the inner inherits the outer's group set, so
# fixing it here means every cycle's virt-install / virsh call inside
# the inner runner reaches /var/run/libvirt/libvirt-sock cleanly. No-op
# on macOS/Windows and on shells that already have libvirt in the
# effective set. See Invoke-LibvirtGroupReExecIfNeeded for the full
# rationale (sg + initgroups, why $env: would leak, etc.).
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
# ConfigPath was resolved by Initialize-YurunaEntryPoint above; the
# failure-pause break-out triggers read repositories.projectUrl and
# watch the file's mtime without each call site re-deriving the path.

# === Bootstrap runtime dir + log dir ========================================
# Initialize-YurunaRuntimeDir / Initialize-YurunaLogDir publish the canonical
# locations as $env:YURUNA_RUNTIME_DIR / $env:YURUNA_LOG_DIR. The inner pwsh
# inherits these via Start-Process WITHOUT -UseNewEnvironment so the inner
# and the status server agree on the on-disk track + log paths every cycle.
$null = Initialize-YurunaRuntimeDir
$null = Initialize-YurunaLogDir
# Stable per-host pool identity, cached on the process global so NDJSON events
# (Write-CycleNdjsonEvent) and status.json carry hostId for cross-host joins.
# Set at script top (not inside a function) -- same pattern as $global:__YurunaRunId.
$global:__YurunaHostId = Get-YurunaHostId

# Boot-time recovery sweep. Resolves the stale-state classes a prior
# crash left behind: orphan `.incomplete` cycle-folder markers,
# stale inner.pid whose process is gone, a stale break-active.json
# that no live runner is honouring, and leftover pause flags
# (control.step-pause / control.cycle-pause) so a fresh launch never
# inherits a prior session's pause -- the same Clear-StalePauseFlag
# policy Test-Project and Test-Sequence apply directly at their startup.
# Runs ONCE per outer startup and is a no-op on a clean boot. Sits BEFORE the runner.pid dance so the
# existing single-instance flow sees a clean field; Clear-StalePidFile
# inside the sweep only removes pidfiles whose process is provably
# dead, so a legitimate concurrent OtherRunner is left for the
# pidfile dance below to detect + stop.
if (Get-Command Invoke-YurunaBootRecovery -ErrorAction SilentlyContinue) {
    $null = Invoke-YurunaBootRecovery -Confirm:$false
}

# Runner state machine init. Reads runner.state.json; if the prior
# state is not 'idle' AND the prior runId differs from ours, the
# previous outer crashed mid-lifecycle -- Initialize-RunnerState
# synthesises a <stale-state> -> fault -> idle pair on the NDJSON
# stream so a downstream consumer sees the crash explicitly. Then
# writes a fresh 'idle' state under our runId.
if (Get-Command Initialize-RunnerState -ErrorAction SilentlyContinue) {
    $null = Initialize-RunnerState -Confirm:$false
}

# Snapshot AFTER Initialize-YurunaRuntimeDir / Initialize-YurunaLogDir so the
# resolved (or operator-supplied) defaults for YURUNA_RUNTIME_DIR / YURUNA_-
# LOG_DIR are captured rather than the pre-resolution null. Only names
# present in $env: at this moment are stored -- absent names are not
# forwarded (we don't want to set them to '' downstream).
$script:ForwardEnvSnapshot = @{}
foreach ($n in $script:ForwardEnvNames) {
    $v = [Environment]::GetEnvironmentVariable($n)
    if ($null -ne $v -and $v -ne '') {
        $script:ForwardEnvSnapshot[$n] = $v
    }
}

# Sync-ForwardEnv + Write-OuterLog live in
# [Test.RunnerOuterLoop](modules/Test.RunnerOuterLoop.psm1) so the
# outer-loop body and the entry-point script see the same
# implementations. Sync-ForwardEnv takes the snapshot as a parameter
# (no script-scope read); Write-OuterLog reads YURUNA_RUNTIME_DIR
# from env at call time (resolved by Initialize-YurunaRuntimeDir above).

# === Single-instance guard ==================================================
# Outer owns the runner.pid file across the whole resilient lifetime. Inner
# detects YURUNA_RUNNER_RELAUNCH=1 and skips its own guard / pidfile write.
# Shared implementation in Test.SingleInstance.psm1 (imported above by
# Initialize-YurunaEntryPointModuleSet -For Outer) so a per-platform fix
# (BSD ps truncation, StartTime tolerance, etc.) lands in one place.
$RunnerPidFile   = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.pid'
$RunnerStartFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.start'
$priorRunner = Get-RunnerInstanceState -RunnerPidFile $RunnerPidFile -RunnerStartFile $RunnerStartFile
switch ($priorRunner.status) {
    'OtherRunner' {
        Write-Output ""
        Write-Output "============================================="
        Write-Output "  Another Invoke-TestRunner is running"
        Write-Output "  PID:    $($priorRunner.pid)"
        Write-Output "  Action: stopping it + Remove-TestVMFiles.ps1"
        Write-Output "============================================="
        Stop-StaleRunner -ProcessId $priorRunner.pid -TestRoot $TestRoot -Confirm:$false
    }
    'Stale' {
        if ($priorRunner.pid -gt 0) {
            Write-Warning "Stale runner.pid: PID $($priorRunner.pid) is not an Invoke-TestRunner process. Ignoring."
        }
    }
    default { } # 'None' / 'Self' -- nothing to do
}
Remove-Item -LiteralPath $RunnerPidFile   -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $RunnerStartFile -Force -ErrorAction SilentlyContinue
# Atomic CreateNew + FileShare.None lock. If a second runner started
# between the Remove-Item above and this open, the loser sees $false
# and aborts -- the winner now holds the pidfile lock for the rest of
# its lifetime. Without the atomic check the two would race on the
# plain Set-Content and one PID would silently get overwritten.
$pidWritten = Write-RunnerPidFile -RunnerPidFile $RunnerPidFile -RunnerStartFile $RunnerStartFile -Confirm:$false
if (-not $pidWritten) {
    Write-Error "Lost the pidfile race against a concurrent Invoke-TestRunner. Inspect $RunnerPidFile and retry."
    exit (Get-EntryPointExitCode -Outcome Failure)
}

# === Ctrl+C handler =========================================================
# Shared registration lives in Test.Prelude (Register-EntryPointCancelHandler): a
# Register-ObjectEvent CancelKeyPress subscription that flips the returned hashtable's
# 'Requested' flag on the pipeline thread (a raw .NET delegate would fire on a
# Runspace-less thread-pool thread). The outer runner surrenders after the current
# CYCLE -- the eternal loop and the failure-pause loop both poll
# $script:ShutdownState['Requested'] at their next iteration -- so pass -ExitAfterLabel 'cycle'.
$script:ShutdownState = Register-EntryPointCancelHandler -ExitAfterLabel 'cycle'

# === Build inner argument list ==============================================
# Canonical builder: Test.InnerSpawn\New-InnerRunnerArgList. Why -Command,
# -NoProfile, and single-quote escaping live in the helper, not here:
# see test/modules/Test.InnerSpawn.psm1.
$pwshExe = Get-PwshExePath
# Outer-only switches that the inner does not accept. Filter so the
# inner pwsh doesn't error with "A parameter cannot be found that
# matches parameter name 'NoConfigGate'" when the operator passes it
# to the outer.
$script:OuterOnlyParams = @('NoConfigGate')
$argList = New-InnerRunnerArgList -ScriptPath $InnerScript -Parameters $PSBoundParameters -ExcludeParameter $script:OuterOnlyParams

# === Helpers ================================================================
# git / config / watchdog / Sync-ForwardEnv / Write-OuterLog helpers all
# live in two sibling modules so the entry point stays thin and the
# heartbeat-watchdog + cycle dispatcher are unit-testable independent of
# this file. See modules/Test.RunnerWatchdog.psm1 + modules/Test.Runner-
# OuterLoop.psm1; both were loaded with -Global -Force by Initialize-
# YurunaEntryPointModuleSet -For Outer above.

# === Banner =================================================================
# First line written to runtime/outer.log on every outer startup. If this line
# is missing from outer.log after the runner has clearly been running (e.g.
# the inner emitted output to the console), Write-OuterLog itself is broken
# (env var, permissions, encoding) -- investigate before trusting outer.log
# absence as evidence that Start-Process -Wait hung.
Write-OuterLog "===== outer runner started (PID $PID) ====="
Write-Output ""
Write-Output "============================================="
Write-Output "  Yuruna outer runner"
Write-Output "  Inner:        $InnerScript"
Write-Output "  Backoff cap:  $($script:FailurePauseMaxSeconds / 60) min"
Write-Output "  Commit poll:  $($script:FailureCommitPollSeconds / 60) min"
Write-Output "  Step timeout: $(Get-OuterStepTimeoutMinute -ConfigPath $ConfigPath -DefaultMinutes $script:StepTimeoutMinutesDefault) min (testCycle.stepTimeoutMinutes; default $($script:StepTimeoutMinutesDefault))"
Write-Output "  Stop:         Ctrl+C"
if ($script:ForwardEnvSnapshot.Count -gt 0) {
    Write-Output "  Forwarded env to inner:"
    foreach ($n in ($script:ForwardEnvSnapshot.Keys | Sort-Object)) {
        Write-Output "    $n = $($script:ForwardEnvSnapshot[$n])"
    }
} else {
    $namesList = $script:ForwardEnvNames -join ', '
    Write-Output "  Forwarded env: (none of $namesList set in launch shell)"
}
Write-Output "============================================="

# Why a missing powershell-yaml is a hard stop rather than a warning:
# docs/test-runner.md#powershell-yaml-must-be-installed
if (-not (Get-Module -ListAvailable -Name powershell-yaml -ErrorAction SilentlyContinue)) {
    # exit is a bounded, non-interactive stop; the outer loop must never block
    # on a prompt.
    $yamlMissing = "powershell-yaml is not installed. The cycle planner cannot parse test.runner.yml, so every cycle would fall back to the legacy guestSequence and SKIP Start-GuestOS for every guest -- refusing to start a silently-degraded loop. Fix with: Install-Module powershell-yaml -Scope CurrentUser  (or re-run host/<host>/Enable-TestAutomation.ps1)"
    Write-OuterLog "[outer startup] $yamlMissing"
    Write-Warning $yamlMissing
    exit (Get-EntryPointExitCode -Outcome Failure)
}

# === Pre-cycle config gate ==================================================
# What it validates, why -SkipSend is mandatory here, and the -NoConfigGate
# bypass: docs/test-runner.md#pre-cycle-config-gate
$gate = Invoke-ConfigGate -TestRoot $TestRoot -ConfigPath $ConfigPath -Skip:$NoConfigGate -CallerName 'outer startup'
if (-not $gate.passed) {
    Write-OuterLog "[outer startup] Test-Config.ps1 exited $($gate.exitCode) -- refusing to start the cycle loop."
    exit (Get-EntryPointExitCode -Outcome Failure)
}

# === Eternal loop ===========================================================
# Cycle body lives in Test.RunnerOuterLoop.psm1 so it can be unit-tested
# without spawning a real inner pwsh. The State hashtable threads
# everything the loop needs (paths, tunables, ShutdownState reference,
# the call-op argv) so the function reads no caller-scope variables
# implicitly. ShutdownState is reference-shared with the Ctrl+C handler
# above; flipping ['Requested'] there ends the loop here.
Invoke-RunnerOuterLoop -State @{
    RepoRoot                  = $RepoRoot
    ConfigPath                = $ConfigPath
    InnerScript               = $InnerScript
    PwshExe                   = $pwshExe
    ArgList                   = $argList
    ForwardEnvSnapshot        = $script:ForwardEnvSnapshot
    ShutdownState             = $script:ShutdownState
    NoGitPull                 = [bool]$NoGitPull
    FailurePauseMaxSeconds    = $script:FailurePauseMaxSeconds
    FailureCommitPollSeconds  = $script:FailureCommitPollSeconds
    OuterPullErrorSleepSec    = $script:OuterPullErrorSleepSec
    InnerSpawnErrorSleepSec   = $script:InnerSpawnErrorSleepSec
    StepTimeoutMinutesDefault = $script:StepTimeoutMinutesDefault
    WatchdogPollSeconds       = $script:WatchdogPollSeconds
}

# === Graceful shutdown ======================================================
Write-Output ""
Write-Output "Shutdown requested. Releasing pidfile and exiting."
Unregister-EntryPointCancelHandler
try {
    if (Test-Path -LiteralPath $RunnerPidFile) {
        $filePid = 0
        try { $filePid = [int]((Get-Content $RunnerPidFile -Raw -ErrorAction Stop).Trim()) } catch { $filePid = 0 }
        if ($filePid -eq $PID) {
            Remove-Item -LiteralPath $RunnerPidFile -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    Write-Verbose "Pidfile cleanup swallowed error: $($_.Exception.Message)"
}
exit (Get-EntryPointExitCode -Outcome Ok)
