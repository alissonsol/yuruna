<#PSScriptInfo
.VERSION 2026.10.18
.GUID 4246a89e-2ebb-49a1-87a4-31d719f44bf1
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
      2. spawn modules/Invoke-TestRunnerInnerLoop.ps1 in a fresh pwsh per cycle
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
    See https://yuruna.link/42010605-0002.
.PARAMETER ConfigPath
    test.config.yml path (forwarded to inner)
.PARAMETER NoGitPull
    Skip git pull (forwarded; outer also skips its own pull)
.PARAMETER NoStatusService
    Skip the built-in HTTP status service (forwarded)
.PARAMETER NoConfigGate
    Skip the startup and per-cycle Test-Config.ps1 gate (forwarded)
.PARAMETER CycleDelaySeconds
    Pause between cycles inside the inner (forwarded; default 30)
.PARAMETER logLevel
    Error|Warning|Information|Verbose|Debug (forwarded)
.PARAMETER RefreshResume
    Internal: set only by a host-refresh worker restarting this
    runner. Startup keeps the operator's pauses, holds and restart
    request, never takes over or deletes a live or unknown runner
    record, never prompts, and runs one preflight cycle before the
    first ordinary one. Requires -RefreshHandoffToken.
.PARAMETER RefreshHandoffToken
    Internal: the handoff token (32 lowercase hex) that admits this
    runner's preflight chain. Requires -RefreshResume. Neither
    internal parameter reaches the inner or the launch record.

Strict binding: an unknown or misspelled parameter is a binding error, never a
value silently absorbed into $args while the runner starts on defaults.

While a host refresh holds this host's runner (the refresh gate is closed,
recovery-pending, in a handoff, or unreadable), a normal start refuses.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = '$global:__YurunaHostId is the cross-host pool-identity channel; set at script top so NDJSON events + status.json carry hostId for pool joins.')]
[CmdletBinding()]
param(
    [string]$ConfigPath        = $null,
    [switch]$NoGitPull,
    [switch]$NoStatusService,
    # Skip the pre-cycle Test-Config.ps1 gate. Use only for ad-hoc /
    # in-progress edit runs where the operator knowingly accepts that
    # a misconfigured test.config.yml / vault.yml / users.yml will fail
    # at first cycle instead of at startup. Production / CI / scheduled
    # runs MUST NOT pass this switch.
    [switch]$NoConfigGate,
    [int]$CycleDelaySeconds    = 30,
    [ValidateSet('Error', 'Warning', 'Information', 'Verbose', 'Debug', IgnoreCase = $true)]
    [string]$logLevel,
    [switch]$RefreshResume,
    [ValidatePattern('^[0-9a-f]{32}$')]
    [string]$RefreshHandoffToken
)

# A Windows console code page prints Chinese and Hebrew catalog text as
# question marks; YURUNA_KEEP_CONSOLE_ENCODING=1 keeps the console's own.
if ($IsWindows -and $env:YURUNA_KEEP_CONSOLE_ENCODING -ne '1') { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) }

# --- REGION: Tunable backoff constants
# Hardcoded at top-of-file by design -- NOT in test.config.yml -- so an
# operator can grep + adjust without a config-schema migration. Tune with
# care: the cap is meant to keep a wedged host from burning git/network
# while still being short enough that a one-off transient (network blip,
# mirror hiccup) recovers within an hour without manual intervention.
Import-Module (Join-Path $PSScriptRoot '../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$script:FailurePauseMaxSeconds    = 60 * 60   # cap a backoff at 60 min
$script:FailureCommitPollSeconds  = 5 * 60    # check origin every 5 min
$script:OuterPullErrorSleepSeconds    = 30        # short pause if outer's own git pull errors
$script:InnerSpawnErrorSleepSeconds   = 30        # short pause if Start-Process itself fails
$script:StepTimeoutSecondsDefault = 2700        # watchdog: kill inner when heartbeat older than this
# Tighter bound while the inner is still in its preamble (runner.phase present):
# nothing before the first sequence step is legitimately slow, so a stall there
# is a wedged runner, not long work. testCycle.preambleTimeoutSeconds overrides;
# 0 opts out, applying stepTimeoutSeconds everywhere.
$script:PreambleTimeoutSecondsDefault = 600
$script:WatchdogPollSeconds       = 30        # how often the watchdog re-checks the heartbeat file

# --- REGION: https://yuruna.link/42d69dfa-000d
$script:ForwardEnvNames = @(
    'YURUNA_CACHING_PROXY_SERVICE_IP',  # Test-CachingProxyService / external-cache branch
    'YURUNA_RUNTIME_DIR',         # Test.YurunaDir override
    'YURUNA_LOG_DIR',           # Test.YurunaDir override
    'YURUNA_LOG_LEVEL',         # cascade visibility
    'YURUNA_OCR_COMBINE',       # OCR combine mode (And|Or)
    'YURUNA_CONFIG_PATH',       # operator-supplied -ConfigPath (Sync-RuntimeConfig + Test.Transport agree)
    'YURUNA_STATUS_PUBLIC_URL'  # off-host dashboard URL for failure-notification deep links
)

# --- REGION: Resolve paths
# Canonical path bundle from Test.Prelude. Same call shape used by
# Invoke-TestProject, Debug-TestSequence, and Invoke-TestRunnerInnerLoop -- adding a
# new entry point uses the same one-liner.
Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
# The two refresh transport parameters travel together or not at all.
if ([bool]$RefreshResume -ne [bool]$RefreshHandoffToken) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.refresh_resume_switch_pair')
    exit (Get-EntryPointExitCode -Outcome Failure)
}
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -ConfigPath $ConfigPath
$TestRoot    = $paths.TestRoot
$RepoRoot    = $paths.RepoRoot
$ModulesDir  = $paths.ModulesDir
$ConfigPath  = $paths.ConfigPath
# See https://yuruna.link/42010605-0002
$env:YURUNA_CONFIG_PATH = $ConfigPath
$InnerScript = Join-Path $ModulesDir 'Invoke-TestRunnerInnerLoop.ps1'
if (-not (Test-Path -LiteralPath $InnerScript)) {
    Write-Error "Invoke-TestRunnerInnerLoop.ps1 not found at $InnerScript"
    exit (Get-EntryPointExitCode -Outcome Failure)
}

# Outer entry-point's canonical module set: one Test.Prelude bootstrap
# call loads Test.Host, RuntimeDir, LogDir, Config, InnerSpawn,
# ConfigGate, Capability, and SingleInstance. See
# Initialize-YurunaEntryPointModuleSet for the per-kind module lists.
Initialize-YurunaEntryPointModuleSet -For Outer -ModulesDir $ModulesDir

# --- REGION: Private startup state
# sg relaunches pwsh noninteractively. Repair private files while the original
# terminal can still answer sudo, including locks left owned by a root launch.
if (-not $RefreshResume) {
    Import-Module (Join-Path $ModulesDir 'Test.PrivateStateRepair.psm1') -DisableNameChecking
    $privateState = Repair-YurunaStartupPrivateState -AllowPrompt -RepairFileAccess:(!$IsWindows) `
        -ServedRoot @($RepoRoot, $paths.StatusDir, $env:YURUNA_RUNTIME_DIR, $env:YURUNA_LOG_DIR) -Confirm:$false
    if (-not $privateState.Resolved) {
        Write-Error "Runner private state could not be prepared ($($privateState.Reason)). Start the runner from an interactive terminal to allow any required sudo authentication."
        exit (Get-EntryPointExitCode -Outcome Failure)
    }
}

# See https://yuruna.link/42010605-0002
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

# Surface the credential a cycle may need BEFORE the operator walks away from a
# loop that runs for hours. On a NAT-networked caching proxy the inner loop's
# port-map refresh installs and removes systemd forwarder units with sudo. The
# prompt itself stays where the work is -- priming here would ask on hosts whose
# cycles never touch the port map, and a sudo timestamp is long dead by cycle 2.
if ((Get-HostType) -eq 'host.ubuntu.kvm') {
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_783976daaabd38c7')
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_319b8b8ddbb44d44')
    Write-Output "    * write/remove /etc/systemd/system/yuruna-cacheproxy-p<port>.{socket,service}"
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_d65393848cb9de2a')
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_50e4965e15c28e7c')
}

# ConfigPath was resolved by Initialize-YurunaEntryPoint above; the
# failure-pause break-out triggers read repositories.projectUrl and
# watch the file's mtime without each call site re-deriving the path.

# --- REGION: Bootstrap runtime + log dirs
# Initialize-YurunaRuntimeDir / Initialize-YurunaLogDir publish the canonical
# locations as $env:YURUNA_RUNTIME_DIR / $env:YURUNA_LOG_DIR. The inner pwsh
# inherits these via Start-Process WITHOUT -UseNewEnvironment so the inner
# and the status service agree on the on-disk track + log paths every cycle.
$null = Initialize-YurunaRuntimeDir
$null = Initialize-YurunaLogDir
# Stable per-host pool identity, cached on the process global so NDJSON events
# (Write-CycleNdjsonEvent) and status.json carry hostId for cross-host joins.
# Set at script top (not inside a function) -- same pattern as $global:__YurunaRunId.
$global:__YurunaHostId = Get-YurunaHostId

# --- REGION: Host-refresh gate at startup
# See https://yuruna.link/42010605-0002
$refreshToken = $null
if ($RefreshResume) {
    $refreshToken = Test-YurunaRunnerHandoffToken -TokenId $RefreshHandoffToken -Role outer -RuntimeDir $env:YURUNA_RUNTIME_DIR
    if (-not $refreshToken.Valid) {
        if ($refreshToken.Reason -in @('expired', 'boot-changed', 'runtime-mismatch', 'not-designated')) {
            $null = Write-YurunaRunnerReadinessAck -TokenId $RefreshHandoffToken -Role outer -State failed -FailureReason 'token-invalid' -Confirm:$false
        }
        $tokenRefused = Format-YurunaOperatorMessage -Key 'runner.refresh_resume_token_refused' -Arguments @{ reason = "$($refreshToken.Reason)" }
        Write-Warning $tokenRefused
        Write-OuterLog $tokenRefused
        exit (Get-EntryPointExitCode -Outcome Failure)
    }
} else {
    $startGate = Get-YurunaRefreshGateState -RuntimeDir $env:YURUNA_RUNTIME_DIR
    if (-not $startGate.SpawnAllowed) {
        $gateBlocks = Format-YurunaOperatorMessage -Key 'runner.refresh_gate_blocks_start' -Arguments @{ requestId = "$($startGate.RequestId)"; state = "$($startGate.State)" }
        Write-Warning $gateBlocks
        Write-OuterLog $gateBlocks
        # An orphaned gate -- owner provably dead or recycled, no live
        # handoff token -- has no worker mid-repair, and nothing else may
        # bring the status service back while the hold stands: the outer's
        # ensure defers to the gate, and a refresh worker only restores the
        # listener when one runs. Without the service a remote operator has
        # no dashboard, no view of the unresolved request, and no Retry to
        # relaunch it. The runner stays refused; only the observational
        # status service is ensured so the resume controls are reachable
        # off-host.
        if ($startGate.Orphaned -and -not $NoStatusService) {
            try {
                $ensureDecision = Start-YurunaStatusServiceIfEnabled -Config (Read-TestConfig -Path $ConfigPath) `
                    -StartScript (Join-Path $RepoRoot 'test/service/Start-StatusService.ps1')
                if ($ensureDecision.ShouldStart) {
                    $ensured = Format-YurunaOperatorMessage -Key 'runner.refresh_gate_status_ensured' -Arguments @{ requestId = "$($startGate.RequestId)"; port = "$($ensureDecision.Port)" }
                    Write-Information $ensured -InformationAction Continue
                    Write-OuterLog $ensured
                }
            } catch {
                $ensureFailed = Format-YurunaOperatorMessage -Key 'runner.refresh_gate_status_ensure_failed' -Arguments @{ message = "$($_.Exception.Message)" }
                Write-Warning $ensureFailed
                Write-OuterLog $ensureFailed
            }
        }
        exit (Get-EntryPointExitCode -Outcome Failure)
    }
}

# Recover stale runtime state before starting a fresh outer runner.
# See https://yuruna.link/42e220c4-0008
$runStartupRecovery = {
    if (Get-Command Invoke-YurunaBootRecovery -ErrorAction SilentlyContinue) {
        if ($RefreshResume) {
            $null = Invoke-YurunaBootRecovery -RefreshPreservation -ReclaimedInner $refreshToken.Reclaimed.inner -Confirm:$false
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.refresh_resume_started' -Arguments @{ requestId = "$($refreshToken.RequestId)" })
        } else {
            $null = Invoke-YurunaBootRecovery -Confirm:$false
        }
    }
    if (Get-Command Initialize-RunnerState -ErrorAction SilentlyContinue) {
        $null = Initialize-RunnerState -Confirm:$false
    }
}
if (-not $RefreshResume) { & $runStartupRecovery }

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

# See https://yuruna.link/42010605-0002

# --- REGION: Single-instance guard
# Outer owns the runner.pid file across the whole resilient lifetime. Inner
# detects YURUNA_RUNNER_RELAUNCH=1 and skips its own guard / pidfile write.
# Shared implementation in Test.SingleInstance.psm1 (imported above by
# Initialize-YurunaEntryPointModuleSet -For Outer) so a per-platform fix
# (BSD ps truncation, StartTime tolerance, etc.) lands in one place.
$RunnerPidFile   = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.pid'
$RunnerStartFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.start'
if ($RefreshResume) {
    # No takeover in a resumed start: a runner that started meanwhile is
    # preserved, and an unknown record is never deleted. Only the exact
    # generation proven dead or recycled (the one the refresh reclaimed) is
    # removed, so the pidfile write below can succeed.
    $priorRecord = Get-YurunaRunnerRecordState -PidFile $RunnerPidFile -StartFile $RunnerStartFile -ExpectedScriptPath @($PSCommandPath)
    $recordRefusal = $null
    switch ($priorRecord.State) {
        'Missing' { }
        'DeadOrRecycled' {
            $removal = Remove-YurunaRunnerRecordGeneration -PidFile $RunnerPidFile -StartFile $RunnerStartFile -Fingerprint ([string]$priorRecord.Fingerprint) -Confirm:$false
            if (-not $removal.Removed -and $removal.Reason -ne 'missing') { $recordRefusal = 'runner-record-unknown' }
        }
        'Unknown' { $recordRefusal = 'runner-record-unknown' }
        default   { $recordRefusal = 'other-runner' }
    }
    if ($recordRefusal) {
        $null = Write-YurunaRunnerReadinessAck -TokenId $RefreshHandoffToken -Role outer -State failed -FailureReason $recordRefusal -Confirm:$false
        $recordRefused = Format-YurunaOperatorMessage -Key 'runner.refresh_resume_record_refused' -Arguments @{ pidFile = 'runner.pid'; state = "$($priorRecord.State)" }
        Write-Warning $recordRefused
        Write-OuterLog $recordRefused
        exit (Get-EntryPointExitCode -Outcome Failure)
    }
} else {
    $priorRunner = Get-RunnerInstanceState -RunnerPidFile $RunnerPidFile -RunnerStartFile $RunnerStartFile
    switch ($priorRunner.status) {
        'OtherRunner' {
            Write-Output ""
            Write-Output "========"
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_9a7da697fb6cf571')
            Write-Output "  PID:    $($priorRunner.pid)"
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_3a128bde2c1c8d18')
            Write-Output "========"
            Stop-StaleRunner -ProcessId $priorRunner.pid -TestRoot $TestRoot -Confirm:$false
        }
        'Stale' {
            if ($priorRunner.pid -gt 0) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_544711bfa51696ae' -Arguments @{ pid = "$($priorRunner.pid)" })
            }
        }
        default { } # 'None' / 'Self' -- nothing to do
    }
    Remove-Item -LiteralPath $RunnerPidFile   -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $RunnerStartFile -Force -ErrorAction SilentlyContinue
}
# Atomic CreateNew + FileShare.None lock. If a second runner started
# between the Remove-Item above and this open, the loser sees $false
# and aborts -- the winner now holds the pidfile lock for the rest of
# its lifetime. Without the atomic check the two would race on the
# plain Set-Content and one PID would silently get overwritten.
$pidWritten = Write-RunnerPidFile -RunnerPidFile $RunnerPidFile -RunnerStartFile $RunnerStartFile -Confirm:$false
if (-not $pidWritten) {
    if ($RefreshResume) {
        $null = Write-YurunaRunnerReadinessAck -TokenId $RefreshHandoffToken -Role outer -State failed -FailureReason 'pidfile-lost' -Confirm:$false
    }
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_e00026446a75f063' -Arguments @{ runnerPidFile = "$RunnerPidFile" })
    exit (Get-EntryPointExitCode -Outcome Failure)
}
if ($RefreshResume) { & $runStartupRecovery }

# --- REGION: Launch record
# The validated launch options, recorded privately so a host refresh can
# restart this runner with the configuration it had -- never one derived from
# a command line, which for an interactive pwsh carries nothing. A record that
# cannot be written only means a later refresh cannot restart this runner and
# leaves the restart to the operator.
$launchRecord = Write-YurunaRunnerLaunchRecord -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters `
    -ResolvedConfigPath $ConfigPath -RuntimeDir $env:YURUNA_RUNTIME_DIR -RepoRoot $RepoRoot `
    -WorkingDirectory (Get-Location).ProviderPath -ForwardEnvironment $script:ForwardEnvSnapshot `
    -AllowedEnvironmentName $script:ForwardEnvNames -Confirm:$false
if (-not $launchRecord.Written) {
    $launchSkipped = Format-YurunaOperatorMessage -Key 'runner.refresh_launch_record_skipped' -Arguments @{ reason = "$($launchRecord.Reason)" }
    Write-Warning $launchSkipped
    Write-OuterLog $launchSkipped
}
# The startup refusals below are orderly exits, not crashes: a record left
# open would read as a runner to restart, and a refresh would relaunch it
# straight into the same refusal.
$completeLaunchRecord = {
    if ($launchRecord.Written) { $null = Complete-YurunaRunnerLaunchRecord -RuntimeDir $env:YURUNA_RUNTIME_DIR -CleanExit -Confirm:$false }
}

# --- REGION: Ctrl+C handler
# See https://yuruna.link/42010605-0002
$script:ShutdownState = Register-EntryPointCancelHandler -ExitAfterLabel 'cycle'

# --- REGION: Build inner argument list
# Canonical builder: Test.InnerSpawn\New-InnerRunnerArgList. Why -Command,
# -NoProfile, and single-quote escaping live in the helper, not here:
# see test/modules/Test.InnerSpawn.psm1.
$pwshExe = Get-PwshExePath
# See https://yuruna.link/42010605-0002
$argList = New-InnerRunnerArgList -ScriptPath $InnerScript -Parameters $PSBoundParameters `
    -ExcludeParameter @('RefreshResume', 'RefreshHandoffToken')

# --- REGION: Helpers
# See https://yuruna.link/42010605-0002

# --- REGION: Banner
# First line written to runtime/outer.log on every outer startup. If this line
# is missing from outer.log after the runner has clearly been running (e.g.
# the inner emitted output to the console), Write-OuterLog itself is broken
# (env var, permissions, encoding) -- investigate before trusting outer.log
# absence as evidence that Start-Process -Wait hung.
Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_60c1179c7c8d2b83' -Arguments @{ pID = "$PID" })
Write-Output ""
Write-Output "========"
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_c38026188af9ed4c')
Write-Output "  Inner:        $InnerScript"
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_c83f88602397b5a8' -Arguments @{ failurePauseMaxSeconds = "$($script:FailurePauseMaxSeconds / 60)" })
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_05d9260581fa8254' -Arguments @{ failureCommitPollSeconds = "$($script:FailureCommitPollSeconds / 60)" })
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_0f8092ec9d970028' -Arguments @{ stepTimeoutSecondsDefault = "$(Get-OuterStepTimeoutSeconds -ConfigPath $ConfigPath -DefaultSeconds $script:StepTimeoutSecondsDefault)"; stepTimeoutSecondsDefault2 = "$($script:StepTimeoutSecondsDefault)" })
$script:PreambleBanner = Get-OuterPreambleTimeoutSeconds -ConfigPath $ConfigPath -DefaultSeconds $script:PreambleTimeoutSecondsDefault
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_acbe98987ce4b852' -Arguments @{ applies = "$(if ($script:PreambleBanner -gt 0) { "$script:PreambleBanner s" } else { 'off (step timeout applies)' })"; preambleTimeoutSecondsDefault = "$($script:PreambleTimeoutSecondsDefault)" })
Write-Output "  Stop:         Ctrl+C"
if ($script:ForwardEnvSnapshot.Count -gt 0) {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_4575b87368f13304')
    foreach ($n in ($script:ForwardEnvSnapshot.Keys | Sort-Object)) {
        Write-Output "    $n = $($script:ForwardEnvSnapshot[$n])"
    }
} else {
    $namesList = $script:ForwardEnvNames -join ', '
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_0021edc0297e700d' -Arguments @{ namesList = "$namesList" })
}
Write-Output "========"

# Why a missing powershell-yaml is a hard stop rather than a warning:
# docs/runner-outer-loop.md#powershell-yaml-must-be-installed
if (-not (Get-Module -ListAvailable -Name powershell-yaml -ErrorAction SilentlyContinue)) {
    # exit is a bounded, non-interactive stop; the outer loop must never block
    # on a prompt.
    $yamlMissing = "powershell-yaml is not installed. The cycle planner cannot parse test.runner.yml, so every cycle would fall back to the legacy guestSequence and SKIP Start-GuestOS for every guest -- refusing to start a silently-degraded loop. Fix with: Install-Module powershell-yaml -Scope CurrentUser  (or re-run test/lab/Enable-TestAutomation.ps1)"
    if ($RefreshResume) {
        $null = Write-YurunaRunnerReadinessAck -TokenId $RefreshHandoffToken -Role outer -State failed -FailureReason 'yaml-missing' -Confirm:$false
    }
    Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_1b2d45fc84aa493b' -Arguments @{ yamlMissing = "$yamlMissing" })
    Write-Warning $yamlMissing
    & $completeLaunchRecord
    exit (Get-EntryPointExitCode -Outcome Failure)
}

# --- REGION: Elevation check
# See https://yuruna.link/42010605-0002
$elevationHostType = Get-HostType
# A resumed start has nobody at a console, so it never prompts: a missing
# credential is a refusal the worker reports.
if ($elevationHostType -and (Get-Command Assert-RunnerElevation -ErrorAction SilentlyContinue)) {
    if (-not (Assert-RunnerElevation -HostType $elevationHostType -NonInteractive:$RefreshResume)) {
        if ($RefreshResume) {
            $null = Write-YurunaRunnerReadinessAck -TokenId $RefreshHandoffToken -Role outer -State failed -FailureReason 'elevation-refused' -Confirm:$false
        }
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_71c777325565d43c' -Arguments @{ elevationHostType = "$elevationHostType" })
        & $completeLaunchRecord
        exit (Get-EntryPointExitCode -Outcome Failure)
    }
}

# --- REGION: Pre-cycle config gate
# What it validates, why -SkipSend is mandatory here, and the -NoConfigGate
# bypass: docs/runner-outer-loop.md#pre-cycle-config-gate
$gate = Invoke-ConfigGate -TestRoot $TestRoot -ConfigPath $ConfigPath -Skip:$NoConfigGate -CallerName 'outer startup'
if (-not $gate.passed) {
    if ($RefreshResume) {
        $null = Write-YurunaRunnerReadinessAck -TokenId $RefreshHandoffToken -Role outer -State failed -FailureReason 'config-gate-failed' -Confirm:$false
    }
    Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_4bc00ee22cf67a77' -Arguments @{ exitCode = "$($gate.exitCode)" })
    & $completeLaunchRecord
    exit (Get-EntryPointExitCode -Outcome Failure)
}

# --- REGION: Eternal loop
# See https://yuruna.link/42010605-0002
$CycleScript = Join-Path $ModulesDir 'Invoke-TestCycleRunner.ps1'
if (-not (Test-Path -LiteralPath $CycleScript)) {
    # Not fatal: the loop falls back to running the cycle in-process, which behaves
    # identically except that an edit then needs a runner restart to take effect.
    Write-Warning "Invoke-TestCycleRunner.ps1 not found at $CycleScript -- running cycles in-process; edits to cycle logic will need a runner restart."
    $CycleScript = ''
}

Invoke-RunnerOuterLoop -State @{
    CycleScript               = $CycleScript
    RepoRoot                  = $RepoRoot
    ConfigPath                = $ConfigPath
    InnerScript               = $InnerScript
    PwshExe                   = $pwshExe
    ArgList                   = $argList
    ForwardEnvSnapshot        = $script:ForwardEnvSnapshot
    ShutdownState             = $script:ShutdownState
    NoGitPull                 = [bool]$NoGitPull
    # Every operator option crosses into the per-cycle child process
    # (Invoke-TestCycleRunner.ps1) through Invoke-OuterCycleDispatch, which
    # builds that child's argument vector from these keys; a key missing here
    # would revert the child to that script's own default on every cycle.
    NoStatusService           = [bool]$NoStatusService
    NoConfigGate              = [bool]$NoConfigGate
    CycleDelaySeconds         = $CycleDelaySeconds
    LogLevel                  = $logLevel
    FailurePauseMaxSeconds    = $script:FailurePauseMaxSeconds
    FailureCommitPollSeconds  = $script:FailureCommitPollSeconds
    OuterPullErrorSleepSeconds    = $script:OuterPullErrorSleepSeconds
    InnerSpawnErrorSleepSeconds   = $script:InnerSpawnErrorSleepSeconds
    StepTimeoutSecondsDefault = $script:StepTimeoutSecondsDefault
    PreambleTimeoutSecondsDefault = $script:PreambleTimeoutSecondsDefault
    WatchdogPollSeconds       = $script:WatchdogPollSeconds
    # A resumed runner's first dispatch is the preflight chain of its handoff.
    RefreshHandoff            = if ($RefreshResume) {
        @{ TokenId = $RefreshHandoffToken; RequestId = [string]$refreshToken.RequestId; Generation = [string]$refreshToken.Generation; Purpose = 'new-outer' }
    } else { $null }
    RefreshBarrierRequestId   = $null
    RefreshGateHoldSeconds    = 15
}

# --- REGION: Graceful shutdown
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_865d99d9b774d3ab')
Unregister-EntryPointCancelHandler
# An orderly end (Ctrl+C, a pool drain): a host refresh must not restart a
# runner the operator stopped.
$null = Complete-YurunaRunnerLaunchRecord -RuntimeDir $env:YURUNA_RUNTIME_DIR -CleanExit -Confirm:$false
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
