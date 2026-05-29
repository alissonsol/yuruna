<#PSScriptInfo
.VERSION 2026.05.29
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
    Splits the previous monolithic Invoke-TestRunner.ps1 into a thin
    outer (this file) and a single-cycle inner
    (modules/Invoke-TestInnerRunner.ps1 -- intentionally placed under
    modules/ so it's not mistaken for an entry-point script in the test/
    folder; the operator never invokes it directly).
    Benefits over the prior in-process loop:
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

# --- See https://yuruna.link/memory#why-yuruna-env-vars-are-snapshotted-and-re-asserted-across-inner-spawns
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
# Test-Project, Test-Sequence, and Invoke-TestInnerRunner — adding a
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

# Outer entry-point's canonical module set: shared bootstrap helper in
# Test.Prelude collapses the prior 8 inline Import-Module calls (Test.
# Host, RuntimeDir, LogDir, Config, InnerSpawn, ConfigGate, Capability,
# SingleInstance) into a single call. See Initialize-YurunaEntryPoint
# ModuleSet for the per-kind module lists.
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

# Boot-time recovery sweep. Resolves the stale-state classes a prior
# crash left behind: orphan `.incomplete` cycle-folder markers,
# stale inner.pid whose process is gone, and a stale break-active.json
# that no live runner is honouring. Runs ONCE per outer startup and
# is a no-op on a clean boot. Sits BEFORE the runner.pid dance so the
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
# present in $env: at this moment are stored — absent names are not
# forwarded (we don't want to set them to '' downstream).
$script:ForwardEnvSnapshot = @{}
foreach ($n in $script:ForwardEnvNames) {
    $v = [Environment]::GetEnvironmentVariable($n)
    if ($null -ne $v -and $v -ne '') {
        $script:ForwardEnvSnapshot[$n] = $v
    }
}

function Sync-ForwardEnv {
    [CmdletBinding()]
    param()
    foreach ($n in $script:ForwardEnvSnapshot.Keys) {
        $current = [Environment]::GetEnvironmentVariable($n)
        if ($current -ne $script:ForwardEnvSnapshot[$n]) {
            Set-Item -Path "Env:$n" -Value $script:ForwardEnvSnapshot[$n]
        }
    }
}

# === Outer milestone log ====================================================
# Persist the cycle-boundary lines (exit code, failure-pause entry/exit) to
# runtime/outer.log so they survive a console-output wedge. Observed on
# Windows: conhost can swallow every Write-Output for the entire failure-
# pause window, hiding the exit code that drove outer into the pause. The
# file path is resolvable post-hoc (different terminal, status server) so
# the diagnostic survives even when the foreground console is stuck.
function Write-OuterLog {
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
# Same shape as the previous in-process runner: subscribe via Register-Object-
# Event so the handler runs on the pipeline thread (a raw .NET event delegate
# would fire on a thread-pool thread with no Runspace, throwing on shutdown).
# Setting $script:ShutdownState['Requested']=$true lets the eternal loop and
# the failure-pause loop both observe the request at their next iteration.
$script:ShutdownState = @{ Requested = $false }
try {
    Unregister-Event -SourceIdentifier YurunaCancelKey -ErrorAction SilentlyContinue
    Remove-Job -Name YurunaCancelKey -Force -ErrorAction SilentlyContinue
    $null = Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress `
        -SourceIdentifier YurunaCancelKey -MessageData $script:ShutdownState -Action {
            $Event.SourceEventArgs.Cancel = $true
            $Event.MessageData['Requested'] = $true
            Write-Warning "Shutdown requested (Ctrl+C). Will exit after the current cycle..."
        }
} catch {
    Write-Verbose "Could not register CancelKeyPress handler (non-interactive session): $_"
}

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
function Get-OuterCommitSha {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $sha = & git -C $RepoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]$sha).Trim()
}

function Test-OuterNewCommitsAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$BaselineSha)
    & git -C $RepoRoot fetch --quiet origin 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    $upstream = & git -C $RepoRoot rev-parse '@{u}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $upstream) { return $false }
    return (([string]$upstream).Trim() -ne $BaselineSha)
}

function Invoke-OuterGitPull {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    & git -C $RepoRoot pull --ff-only --quiet 2>&1 | Write-Output
    return ($LASTEXITCODE -eq 0)
}

# ---- Failure-pause break-out triggers ----------------------------------
# The outer's failure-pause used to wait up to 60 min for ONE signal: a
# new commit on the framework remote. Now it watches THREE signals --
# new framework commit, new project commit, AND a local edit of
# test.config.yml -- and breaks out on whichever fires first. Network
# / IO failure on any individual probe is treated as "no change for now"
# (return $null / unchanged baseline) so a flaky network can't cut a
# pause short and a missing config file can't crash the loop.

# Query a remote repo's current HEAD SHA without needing a local clone.
# Used for the repositories.projectUrl probe (the project is wiped + re-cloned at
# cycle start, so a local clone may not exist mid-pause). Returns $null
# on any failure.
function Get-OuterRemoteSha {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RemoteUrl)
    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) { return $null }
    $line = & git ls-remote $RemoteUrl HEAD 2>$null | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($line)) { return $null }
    # `git ls-remote` line format: "<sha>\tHEAD".
    return ([string]$line).Split("`t")[0].Trim()
}

# Snapshot the on-disk mtime of test.config.yml. Returns $null when the
# file is missing -- pairs with the comparison logic below: a $null/non-
# null transition (file deleted or created mid-pause) is itself a change
# worth breaking on, so the operator can edit/create the config and
# expect a near-immediate cycle restart.
function Get-OuterConfigMtime {
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

# Read testCycle.stepTimeoutMinutes from test.config.yml: the watchdog
# uses this as the upper bound on how long a single step (or any other
# slice of inner-runner work) may run without refreshing runner.step-
# Heartbeat before we consider the inner stuck and kill it. Default 45
# mirrors the value baked into test.config.yml.template -- generous
# enough that
# the slow legitimate steps (k8s install, image resize, sequence step
# with a 30-min ssh exec) finish well under the cap, tight enough that
# a wedged ssh.exe / vmconnect / virsh call is caught within ~one cycle
# duration. Read each time the outer is about to spawn, not just at
# script start, so an operator can edit test.config.yml between cycles
# and the new bound takes effect on the next spawn without restarting
# the outer.
function Get-OuterStepTimeoutMinute {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$ConfigPath)
    # -NoCache so a mid-cycle operator edit (the "lower stepTimeout for the
    # next cycle" workflow documented in test/README.md) takes effect at the
    # spawn boundary even if Read-TestConfig's mtime-keyed cache hasn't
    # noticed yet on a low-resolution filesystem.
    $cfg = Read-TestConfig -Path $ConfigPath -NoCache
    $v = Get-TestConfigValue -Config $cfg -Path 'testCycle.stepTimeoutMinutes'
    if ($null -ne $v) {
        $i = [int]$v
        if ($i -gt 0) { return $i }
    }
    return $script:StepTimeoutMinutesDefault
}

# Read repositories.projectUrl from test.config.yml so we know which
# remote to probe. We deliberately read this ONCE at pause start (rather
# than every poll); any in-flight edit of it will trip the config-mtime
# trigger below, which breaks the pause and the next cycle re-reads the
# (now-current) URL. Returns $null when the file is missing or the key
# is empty.
# Watchdog: an out-of-process background job that monitors the inner's
# heartbeat file and kills the inner if it goes stale beyond stepTimeout-
# Minutes. We run it in Start-Job (own pwsh) rather than Start-ThreadJob
# / runspace because the outer's pipeline thread is blocked inside the
# call-operator wait that spawns the inner -- any in-runspace monitor
# (Register-ObjectEvent action, timer, ThreadJob piped through the same
# runspace) can't pump while we wait. Start-Job is heavier but its child
# pwsh is independent, so it fires reliably even when the outer is
# completely wedged on the call-op.
function Start-Watchdog {
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
        $runtimeDir     = $using:RuntimeDir
        $thresholdSec = $using:thresholdSec
        $pollSec      = $using:PollSeconds
        # runner.stepHeartbeat (NOT runner.heartbeat): the legacy heartbeat
        # is written by a System.Threading.Timer on a threadpool thread that
        # keeps ticking even when the runspace is deadlocked inside a
        # never-terminating OCR / SSH / virsh loop. The watchdog has to
        # poll a signal that ONLY the runspace can refresh, otherwise an
        # in-runspace infinite loop is invisible to it. runner.stepHeartbeat
        # is touched by Invoke-Sequence at the top of each step iteration
        # from the runspace thread itself.
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
    [CmdletBinding(SupportsShouldProcess)]
    param($Job)
    if (-not $Job) { return }
    if (-not $PSCmdlet.ShouldProcess($Job.Name, 'Stop-Job/Remove-Job')) { return }
    Stop-Job  -Job $Job -ErrorAction SilentlyContinue
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
}

function Get-OuterProjectUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ConfigPath)
    $cfg = Read-TestConfig -Path $ConfigPath
    $v = Get-TestConfigValue -Config $cfg -Path 'repositories.projectUrl'
    if ($v) { return [string]$v }
    return $null
}

# === Banner =================================================================
# First line written to runtime/outer.log on every outer startup. If this line
# is missing from outer.log after the runner has clearly been running (e.g.
# the inner emitted output to the console), Write-OuterLog itself is broken
# (env var, permissions, encoding) — investigate before trusting outer.log
# absence as evidence that Start-Process -Wait hung.
Write-OuterLog "===== outer runner started (PID $PID) ====="
Write-Output ""
Write-Output "============================================="
Write-Output "  Yuruna outer runner"
Write-Output "  Inner:        $InnerScript"
Write-Output "  Backoff cap:  $($script:FailurePauseMaxSeconds / 60) min"
Write-Output "  Commit poll:  $($script:FailureCommitPollSeconds / 60) min"
Write-Output "  Step timeout: $(Get-OuterStepTimeoutMinute -ConfigPath $ConfigPath) min (testCycle.stepTimeoutMinutes; default $($script:StepTimeoutMinutesDefault))"
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

# Pre-flight: the cycle planner (Test.SequencePlanner.Resolve-CyclePlan)
# parses project/test/test.sequence.yml via powershell-yaml. When the
# module is missing, the inner runner's try/catch swallows the throw
# into a Write-Warning (whose stream the per-cycle log does not capture)
# and falls back to the legacy guestSequence list. That fallback leaves
# Start-GuestOS without any sequence names -- the step is recorded as
# "skipped" in status.json with no line in the cycle log. Surface the
# condition once at outer startup so the operator notices before
# cycles silently degrade. Install with `Install-Module powershell-yaml
# -Scope CurrentUser` or re-run host/<host>/Enable-TestAutomation.ps1.
if (-not (Get-Module -ListAvailable -Name powershell-yaml -ErrorAction SilentlyContinue)) {
    Write-Warning "powershell-yaml is not installed. The cycle planner will fall back to the legacy guestSequence and Start-GuestOS will be SKIPPED for every guest. Fix with: Install-Module powershell-yaml -Scope CurrentUser  (or re-run host/<host>/Enable-TestAutomation.ps1)"
}

# === Pre-cycle config gate ==================================================
# Block the eternal loop from starting when test.config.yml, the extension
# configs, vault.yml, or users.yml are in a state that would make the first
# cycle's New-VM/Start-GuestOS fail in a confusing way. Test-Config.ps1 is
# the single source of validation rules (schema + completeness + cross-
# references); calling it here as a gate is what turns it from an operator
# tool into a hard production guardrail (users.yml strict mode, vaultKey-
# resolves-in-vault.yml check, etc.).
#
# -SkipSend is mandatory in this context: Test-Config's notification path
# is a smoke test for an operator-initiated run, not a cycle event, and
# delivering an email on every outer relaunch would flood the
# subscribers["config.smoke"] list.
#
# Bypass with -NoConfigGate for "I know what I am doing" ad-hoc runs (and
# for the existing dev-iteration flow where the operator wants to spawn
# the runner against an in-progress edit).
$gate = Invoke-ConfigGate -TestRoot $TestRoot -ConfigPath $ConfigPath -Skip:$NoConfigGate -CallerName 'outer startup'
if (-not $gate.passed) {
    Write-OuterLog "[outer startup] Test-Config.ps1 exited $($gate.exitCode) -- refusing to start the cycle loop."
    exit $gate.exitCode
}

# === Eternal loop ===========================================================
$cycle = 0
while (-not $script:ShutdownState['Requested']) {
    $cycle++

    # State machine: idle -> cycle-start. The transition lands before
    # any per-cycle work so a watchdog reading runner.state.json sees
    # "cycle-start" while the git pull / pre-spawn cleanup is in flight;
    # a crash during that window leaves "cycle-start" stale, which the
    # next outer's Initialize-RunnerState detects + synthesises a fault.
    if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
        $null = Set-RunnerState -To 'cycle-start' -Reason "cycle $cycle starting" -Confirm:$false
    }

    # 1. Outer git pull (framework repo). Skip on -NoGitPull, mirroring
    #    the prior runner's flag. A failure here is treated as transient:
    #    short sleep + retry, so the loop doesn't burn CPU thrashing on a
    #    transient git error.
    if (-not $NoGitPull) {
        Write-Output ""
        Write-Output "[outer cycle $cycle] git pull (framework)"
        if (-not (Invoke-OuterGitPull)) {
            Write-Warning "[outer cycle $cycle] git pull failed -- sleeping ${script:OuterPullErrorSleepSec}s before retry."
            Start-Sleep -Seconds $script:OuterPullErrorSleepSec
            continue
        }
    }

    # 2. Spawn the inner. YURUNA_RUNNER_RELAUNCH=1 tells the inner that
    #    we (the outer) own the pidfile + Ctrl+C handler; inner skips
    #    its own copies of those. Sync-ForwardEnv re-asserts the launch-
    #    time snapshot of YURUNA_* vars (cache IP, track/log dirs, log
    #    level, OCR combine) so the inner sees them even if some module
    #    in this outer process clobbered $env: mid-run.
    Sync-ForwardEnv
    $env:YURUNA_RUNNER_RELAUNCH = '1'
    if ($script:ForwardEnvSnapshot.Count -gt 0) {
        Write-Output "[outer cycle $cycle] forwarding env: $($script:ForwardEnvSnapshot.Keys -join ', ')"
    }
    Write-Output "[outer cycle $cycle] spawning inner pwsh... (local time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))"
    Write-OuterLog "[outer cycle $cycle] about to invoke inner pwsh"
    # Wipe last cycle's inner.pid + runner.stepHeartbeat BEFORE arming the
    # watchdog. Without this, Start-Watchdog's wait-for-pidfile loop sees
    # the stale file from the previous cycle and skips the wait entirely;
    # it then reads the dead PID, observes Get-Process returns nothing,
    # and disarms in <60s — leaving the new inner unwatched for the whole
    # cycle. A stale runner.stepHeartbeat has the symmetric trap: the
    # watchdog would see a 7h-old mtime and kill the new inner before it
    # even started its first step.
    #
    # last_failure.json is wiped here too. Invoke-Sequence removes it at
    # the start of each sequence within a cycle (Invoke-Sequence.psm1:1678),
    # but between the previous cycle's failure and the new cycle's first
    # sequence there is a multi-second window where a dashboard / status-
    # server reader sees stale cycle-N failure context attached to
    # cycle N+1. Pre-spawn deletion closes that window.
    $innerPidFile    = Join-Path $env:YURUNA_RUNTIME_DIR 'inner.pid'
    $stepHbFile      = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'
    $lastFailureFile = Join-Path $env:YURUNA_LOG_DIR     'last_failure.json'
    Remove-Item -LiteralPath $innerPidFile    -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stepHbFile      -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $lastFailureFile -Force -ErrorAction SilentlyContinue
    # Post-wipe: if Remove-Item failed (locked file, transient permission
    # error, AV mid-scan, anything), the watchdog about to arm at line 599
    # would read the stale mtime and kill the new inner inside one poll.
    # Force a fresh stepHeartbeat mtime so the watchdog window is full
    # regardless of whether Remove-Item succeeded. WriteAllText creates
    # the file when missing and overwrites when present, so this also
    # subsumes the inner's seed-write at the top of its bootstrap (the
    # inner re-writes it again immediately, just makes the watchdog
    # robust against an out-of-order spawn).
    try {
        [System.IO.File]::WriteAllText($stepHbFile, [DateTime]::UtcNow.ToString('o'))
    } catch {
        Write-Warning "[outer cycle $cycle] could not force-fresh runner.stepHeartbeat ($($_.Exception.Message)) -- watchdog may false-positive within the first poll."
        Write-OuterLog "[outer cycle $cycle] runner.stepHeartbeat force-touch failed: $($_.Exception.Message)"
    }
    # inner.pid is the watchdog's other input; the new inner overwrites
    # it at startup. If a stale pidfile survived Remove-Item, log loudly
    # so the operator can investigate; the watchdog's wait-for-pidfile
    # loop sees the stale content and either targets a dead PID (no-op)
    # or, worst case, kills a live unrelated process. Surface so it's
    # diagnosable instead of silently weird.
    if (Test-Path -LiteralPath $innerPidFile) {
        Write-Warning "[outer cycle $cycle] inner.pid wipe failed and the file is still present; watchdog may target the stale PID."
        Write-OuterLog "[outer cycle $cycle] inner.pid wipe failed -- stale content survived Remove-Item"
    }
    # break-active.json: written by the `break` sequence action when a
    # cooperative breakpoint parks the cycle, removed on resume. If the
    # operator restarts only Invoke-TestRunner.ps1 while a break is parked,
    # the file survives and the first new-cycle step's Gate #1 thinks a
    # break is still active -- hanging the cycle on a non-existent marker.
    # Status-server startup also sweeps this file but the runner can start
    # without the status server; clean here so both startup paths agree.
    Remove-Item -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'break-active.json')     -Force -ErrorAction SilentlyContinue
    # Arm the watchdog BEFORE the spawn so it's already polling by the
    # time the inner writes inner.pid + the first heartbeat. Re-read
    # stepTimeoutMinutes each cycle so an operator can tighten / loosen
    # the bound between cycles without restarting the outer.
    $stepTimeoutMin = Get-OuterStepTimeoutMinute -ConfigPath $ConfigPath
    Write-OuterLog "[outer cycle $cycle] watchdog: stepTimeoutMinutes=$stepTimeoutMin"
    $watchdogJob = Start-Watchdog -StepTimeoutMinutes $stepTimeoutMin -RuntimeDir $env:YURUNA_RUNTIME_DIR -PollSeconds $script:WatchdogPollSeconds
    # State machine: cycle-start -> in-cycle. Lands AFTER the watchdog
    # is armed and BEFORE the call-op blocks. A crash while inner is
    # running leaves "in-cycle" stale; boot recovery + Initialize-
    # RunnerState narrate the recovery on the next startup.
    if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
        $null = Set-RunnerState -To 'in-cycle' -Reason "inner spawning" -Confirm:$false
    }
    # --- See https://yuruna.link/memory#why-the-inner-spawn-uses-the-call-operator-instead-of-start-process
    $exitCode = 0
    try {
        & $pwshExe @argList
        $exitCode = $LASTEXITCODE
    } catch {
        Write-Warning "[outer cycle $cycle] failed to invoke inner pwsh: $_"
        Stop-Watchdog -Job $watchdogJob
        Start-Sleep -Seconds $script:InnerSpawnErrorSleepSec
        continue
    }
    Stop-Watchdog -Job $watchdogJob
    # Outer regained control. Emit BOTH to console and to runtime/outer.log so
    # a conhost wedge (documented above) can't hide the moment Start-Process
    # -Wait returned. If the operator sees the inner's "wait complete --
    # exiting inner" line but never sees this one in the console, check
    # runtime/outer.log: presence there means outer IS running (output wedged);
    # absence means Start-Process -Wait itself never returned.
    Write-Output "[outer cycle $cycle] outer runner back in control (local time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))"
    Write-OuterLog "[outer cycle $cycle] outer runner back in control"
    Write-Output "[outer cycle $cycle] inner exited with code $exitCode"
    Write-OuterLog "[outer cycle $cycle] inner exited with code $exitCode"

    # Watchdog-kill detection: when the inner exits non-zero AND the last
    # step heartbeat is older than the threshold, the cause was almost
    # certainly the watchdog (the exit code is whatever Stop-Process -Force
    # happened to deliver; the application-level failure path can't run
    # after a SIGKILL/TerminateProcess). Tag the situation so the operator
    # doesn't waste time hunting an application-level failure that never
    # happened, and surface the same line in runtime/outer.log for post-
    # mortem.
    if ($exitCode -ne 0) {
        $stepHbFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'
        if (Test-Path -LiteralPath $stepHbFile) {
            $hbAge = ((Get-Date) - (Get-Item -LiteralPath $stepHbFile).LastWriteTime).TotalSeconds
            if ($hbAge -gt ($stepTimeoutMin * 60)) {
                Write-Warning "[outer cycle $cycle] inner exited non-zero AND runner.stepHeartbeat is $([int]$hbAge)s stale (threshold $($stepTimeoutMin * 60)s) -- watchdog likely killed the inner. See runtime/outer.log for the kill line."
                Write-OuterLog "[outer cycle $cycle] inner kill attributed to watchdog (step heartbeat age $([int]$hbAge)s > $($stepTimeoutMin * 60)s)"
            }
        }
    }

    if ($exitCode -eq 0) {
        # 3a. Success -- next iteration pulls and respawns immediately.
        # State machine: in-cycle -> cycle-end -> idle. Both transitions
        # are emitted so a streaming consumer sees the clean closure
        # explicitly rather than inferring it from the absence of a
        # fault event.
        if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
            $null = Set-RunnerState -To 'cycle-end' -Reason "inner exited 0" -Confirm:$false
            $null = Set-RunnerState -To 'idle'      -Reason "cycle complete"  -Confirm:$false
        }
        continue
    }

    # State machine: in-cycle -> fault. The transition lands BEFORE the
    # failure-pause loop so a dashboard sees "fault" the moment the
    # inner exits non-zero; the subsequent fault -> paused transition
    # at the start of the pause loop makes the long wait explicit.
    if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
        $null = Set-RunnerState -To 'fault' -Reason "inner exited $exitCode" -Confirm:$false
    }

    # 3b. Failure -- pause until either a new upstream commit lands on
    #     the framework repo OR a new commit lands on repositories.projectUrl OR
    #     the local test.config.yml is edited OR the cap elapses,
    #     polled every FailureCommitPollSeconds. The wait loop sleeps
    #     in 5-second slices so Ctrl+C is responsive (Start-Sleep can't
    #     be interrupted by our event handler in long sweeps).
    #
    # Three baselines are captured up front; any one of them changing
    # ends the pause and starts the next cycle immediately -- the
    # operator's mental model is "fix anything actionable and the loop
    # picks it up within 5 minutes" without having to Ctrl+C / restart.
    $baselineSha         = Get-OuterCommitSha
    $baselineProjectUrl  = Get-OuterProjectUrl -ConfigPath $ConfigPath
    $baselineProjectSha  = if ($baselineProjectUrl) { Get-OuterRemoteSha -RemoteUrl $baselineProjectUrl } else { $null }
    $baselineConfigMtime = Get-OuterConfigMtime -ConfigPath $ConfigPath
    $pauseStart  = Get-Date
    $deadline    = $pauseStart.AddSeconds($script:FailurePauseMaxSeconds)
    $projectWatchMsg = if ($baselineProjectUrl) { "framework + project ($baselineProjectUrl) + local config" } else { "framework + local config (no repositories.projectUrl)" }
    Write-Warning "[outer cycle $cycle] inner failed -- pausing up to $($script:FailurePauseMaxSeconds / 60) min, polling $projectWatchMsg every $($script:FailureCommitPollSeconds / 60) min."
    Write-OuterLog "[outer cycle $cycle] inner failed -- pausing up to $($script:FailurePauseMaxSeconds / 60) min; watching: $projectWatchMsg."
    # Progress bar: tracks elapsed time toward the 60-min cap (or earlier
    # break-out when a fresh upstream commit lands). Updated on every
    # 5-second slice so the bar advances ~1.4%/tick and the operator sees
    # forward motion instead of a silent terminal. -Id is fixed so we
    # only ever own one progress row; -Completed in the finally clears
    # it cleanly when the loop exits via any path (success, cap, Ctrl+C,
    # exception).
    $progressId = 1
    # State machine: fault -> paused. The pause loop below polls the
    # framework + project + config-mtime triggers; this transition
    # makes the waiting state explicit on the NDJSON stream.
    if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
        $null = Set-RunnerState -To 'paused' -Reason "failure-pause begin" -Confirm:$false
    }
    try {
    while ((Get-Date) -lt $deadline -and -not $script:ShutdownState['Requested']) {
        $remainingPoll = $script:FailureCommitPollSeconds
        while ($remainingPoll -gt 0 -and -not $script:ShutdownState['Requested']) {
            $slice = [math]::Min(5, $remainingPoll)
            Start-Sleep -Seconds $slice
            $remainingPoll -= $slice
            $remainingSec = [math]::Max(0, [int]($deadline - (Get-Date)).TotalSeconds)
            $elapsedSec   = [int]((Get-Date) - $pauseStart).TotalSeconds
            $percent      = [math]::Min(100, [math]::Max(0, [int](($elapsedSec * 100) / $script:FailurePauseMaxSeconds)))
            $remainingMin = [math]::Round($remainingSec / 60, 1)
            Write-Progress -Id $progressId `
                -Activity "[outer cycle $cycle] failure-pause toward next cycle" `
                -Status  ("{0} min remain (next commit poll in {1}s)" -f $remainingMin, $remainingPoll) `
                -PercentComplete $percent `
                -SecondsRemaining $remainingSec
        }
        if ($script:ShutdownState['Requested']) { break }
        # Trigger 1: framework repo new commit (existing behavior, kept).
        if (Test-OuterNewCommitsAvailable -BaselineSha $baselineSha) {
            Write-Output "[outer cycle $cycle] new framework upstream commits detected -- ending pause."
            Write-OuterLog "[outer cycle $cycle] new framework upstream commits detected -- ending pause."
            break
        }
        # Trigger 2: project repo new commit. ls-remote returns $null on
        # network failure; require a non-null current AND a non-null
        # baseline so a transient failure on either side doesn't fire
        # spuriously, and don't fire when repositories.projectUrl wasn't set in
        # the first place.
        if ($baselineProjectUrl) {
            $currentProjectSha = Get-OuterRemoteSha -RemoteUrl $baselineProjectUrl
            if ($currentProjectSha -and $baselineProjectSha -and ($currentProjectSha -ne $baselineProjectSha)) {
                Write-Output "[outer cycle $cycle] new project upstream commits detected at $baselineProjectUrl -- ending pause."
                Write-OuterLog "[outer cycle $cycle] new project upstream commits detected at $baselineProjectUrl ($baselineProjectSha -> $currentProjectSha) -- ending pause."
                break
            }
        }
        # Trigger 3: local test.config.yml edit (mtime change OR file
        # appearing/disappearing relative to the baseline). Comparing
        # nullable datetimes with -ne handles all three transitions
        # (changed / created / deleted) in one shot.
        $currentConfigMtime = Get-OuterConfigMtime -ConfigPath $ConfigPath
        if ($currentConfigMtime -ne $baselineConfigMtime) {
            Write-Output "[outer cycle $cycle] local test.config.yml changed ($ConfigPath) -- ending pause."
            Write-OuterLog "[outer cycle $cycle] local test.config.yml changed (${ConfigPath}: $baselineConfigMtime -> $currentConfigMtime) -- ending pause."
            break
        }
        # Trigger 4: status-service /control/start-cycle from the UI. The
        # endpoint sees this outer's runner.pid as alive and skips spawning
        # a replacement; without this poll, that path would leave the UI's
        # "Start cycle" button silent until the backoff cap. Consume the
        # flag here so the next inner spawn doesn't re-fire on it (Test-
        # Sequence / inner's boot sweep also consume, but the closer the
        # consume to the wake the smaller the window for stale-flag re-
        # entry).
        $outerRestartFlag = Join-Path $env:YURUNA_RUNTIME_DIR 'control.cycle-restart'
        if (Test-Path -LiteralPath $outerRestartFlag) {
            Write-Output "[outer cycle $cycle] /control/start-cycle requested via status UI -- ending pause."
            Write-OuterLog "[outer cycle $cycle] /control/start-cycle requested via status UI -- ending pause."
            Remove-Item -LiteralPath $outerRestartFlag -Force -ErrorAction SilentlyContinue
            break
        }
        $remainingMin = [math]::Max(0, [math]::Round((($deadline - (Get-Date)).TotalMinutes), 1))
        Write-Output "[outer cycle $cycle] no new commits, no config edit; ${remainingMin} min remain in pause."
    }
    } finally {
        Write-Progress -Id $progressId -Activity 'failure-pause' -Completed
        # State machine: paused -> idle. The pause-loop exits via any
        # of: new framework commit, new project commit, config edit,
        # cap elapsed, or Ctrl+C. All are "ready to try again" from
        # the state machine's perspective.
        if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
            $null = Set-RunnerState -To 'idle' -Reason "failure-pause ended" -Confirm:$false
        }
    }
}

# === Graceful shutdown ======================================================
Write-Output ""
Write-Output "Shutdown requested. Releasing pidfile and exiting."
Unregister-Event -SourceIdentifier YurunaCancelKey -ErrorAction SilentlyContinue
Remove-Job -Name YurunaCancelKey -Force -ErrorAction SilentlyContinue
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
