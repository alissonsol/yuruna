<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42b78fbd-8036-4aa8-93eb-161e72bdba4a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner cycle
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
    Run exactly ONE test cycle, then exit. Spawned fresh by Start-TestRunner.ps1.

.DESCRIPTION
    This is the volatile half of the runner. Everything that changes when the inner
    runner changes lives here or in the modules this script imports: the framework
    repo pull, the pool-intent gate, the pre-spawn cleanup, the watchdog, the inner
    spawn itself, and the cycle-end hooks.

    It exists as a separate PROCESS so that an edit to it -- or to any module it
    imports -- is picked up by the very next cycle. The long-lived runner holds its
    own code resident and would otherwise keep running whatever it parsed at
    startup, so an update would need a runner restart to take effect.
    Start-TestRunner.ps1 keeps only what must not be redone per cycle: the
    single-instance pidfile, the boot-recovery sweep, the runner state machine, and
    the Ctrl+C subscription.

    The operator never invokes this directly.

    Transient outcomes (a failed pull, a paused pool, a drain request, a failed
    spawn) are reported through runner.cycle.outcome.json rather than an exit code,
    because the exit-code space belongs to the inner runner and a sentinel number
    could be mistaken for a real failure. The pause that follows a transient outcome
    is the caller's: a sleep here could not be interrupted by the Ctrl+C the
    operator pressed in the runner's own shell.

    A host refresh reaches this process through the environment the runner
    sets around the spawn: a handoff token with YURUNA_REFRESH_PREFLIGHT makes
    this a preflight cycle (validated here against the recorded runner, then
    passed to the inner), YURUNA_REFRESH_BARRIER marks the first ordinary cycle
    after a refresh. A cycle held by the refresh gate reports refresh-gated and
    changes nothing.

    Strict binding: an unknown or misspelled parameter is a binding error.

    See docs/runner-outer-loop.md for the loop contract and the state machine.

.PARAMETER Cycle
    Cycle number, for log correlation only. The counter itself lives in the caller.
.PARAMETER ConfigPath
    test.config.yml path. Defaults to the resolved canonical path.
.PARAMETER NoGitPull
    Skip the framework repo pull for this cycle.
.PARAMETER NoStatusService
    Forwarded to the inner runner.
.PARAMETER NoConfigGate
    Forwarded to the inner runner: skip this cycle's Test-Config.ps1
    preflight. An operator who bypassed the outer's startup gate for an
    in-progress edit would otherwise be stopped by the same check one
    layer down, on the very run they asked to bypass it for.
.PARAMETER CycleDelaySeconds
    Forwarded to the inner runner.
.PARAMETER logLevel
    Forwarded to the inner runner.
.PARAMETER CycleGeneration
    The runner-issued <runnerInstanceId>:<cycle> generation. Handed to the
    inner in YURUNA_CYCLE_GENERATION and echoed in the cycle outcome, so
    per-cycle evidence can be matched to the cycle that produced it.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = '$global:__YurunaHostId is the cross-host pool-identity channel; set at script top so NDJSON events + status.json carry hostId for pool joins.')]
[CmdletBinding()]
param(
    [int]$Cycle = 1,
    [string]$ConfigPath = $null,
    [switch]$NoGitPull,
    [switch]$NoStatusService,
    [switch]$NoConfigGate,
    [int]$CycleDelaySeconds = 30,
    [ValidateSet('Error', 'Warning', 'Information', 'Verbose', 'Debug', IgnoreCase = $true)]
    [string]$logLevel,
    [ValidatePattern('^[0-9a-f]{32}:[1-9][0-9]{0,8}$')]
    [string]$CycleGeneration
)

# --- REGION: Resolve paths
# Lives under test/modules/ alongside Invoke-TestRunnerInnerLoop.ps1: the outer
# runner is the only legitimate caller, so it stays out of test/'s operator-facing
# layer. $PSScriptRoot is therefore test/modules/, one level below $TestRoot.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.Prelude.psm1') -Global -Force
$paths      = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder -ConfigPath $ConfigPath
$TestRoot   = $paths.TestRoot
$RepoRoot   = $paths.RepoRoot
$ModulesDir = $paths.ModulesDir
$ConfigPath = $paths.ConfigPath
$env:YURUNA_CONFIG_PATH = $ConfigPath

$InnerScript = Join-Path $ModulesDir 'Invoke-TestRunnerInnerLoop.ps1'
if (-not (Test-Path -LiteralPath $InnerScript)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'exceptions.runner_187b34999bcb56f2' -Arguments @{ innerScript = "$InnerScript" })
    exit 1
}

# --- REGION: Re-import modules (fresh per cycle)
# -Force on every import is the point of this process: the modules are re-read from
# disk each cycle, so a fix lands without restarting the runner.
Initialize-YurunaEntryPointModuleSet -For Outer -ModulesDir $ModulesDir

# --- REGION: Bootstrap runtime + log dirs
# The runtime/log dirs are already published by the caller; re-resolving is
# idempotent and keeps this script runnable on its own for diagnosis.
$null = Initialize-YurunaRuntimeDir
$null = Initialize-YurunaLogDir
$global:__YurunaHostId = Get-YurunaHostId

# NOT done here, deliberately, because each is once-per-runner and re-running it
# per cycle is actively harmful: the single-instance pidfile dance (a child would
# classify its own parent as a competing runner and kill it), Invoke-YurunaBootRecovery
# (it clears control.step-pause / control.cycle-pause, so the operator's pause would
# be dropped at every cycle boundary), and Initialize-RunnerState (a fresh runId per
# cycle breaks run continuity on the event stream).

$pwshExe = Get-PwshExePath
# -NonInteractive: the inner shares this console and must refuse any prompt
# rather than park the host on one; it neutralizes its own prompts at startup,
# and the flag closes the window before that.
$argList = New-InnerRunnerArgList -ScriptPath $InnerScript -Parameters $PSBoundParameters `
    -ExcludeParameter @('Cycle', 'CycleGeneration') -NonInteractive

# --- REGION: Ctrl+C handler
# This process is not the one the operator's Ctrl+C reaches; the caller owns
# shutdown and kills this whole tree when it is requested. A local, never-set
# handle keeps the shared cycle code working unchanged.
$shutdownState = @{ Requested = $false; ExitAfterLabel = 'cycle' }

$forwardEnvSnapshot = @{}
foreach ($n in @('YURUNA_CACHING_PROXY_SERVICE_IP','YURUNA_RUNTIME_DIR','YURUNA_LOG_DIR',
                 'YURUNA_LOG_LEVEL','YURUNA_OCR_COMBINE','YURUNA_CONFIG_PATH',
                 'YURUNA_STATUS_PUBLIC_URL')) {
    $v = [Environment]::GetEnvironmentVariable($n)
    if ($null -ne $v -and $v -ne '') { $forwardEnvSnapshot[$n] = $v }
}

# --- REGION: Host-refresh transport
# A preflight token is honored only after it validates for this process: its
# parent must be the recorded, live runner. An invalid one is not an ordinary
# cycle either -- the cycle reports refresh-gated and the runner re-decides.
$refreshTokenId = [string]$env:YURUNA_REFRESH_HANDOFF_TOKEN
$refreshPreflightRequested = ($env:YURUNA_REFRESH_PREFLIGHT -eq '1') -and [bool]$refreshTokenId
$refreshPreflight = $null
if ($refreshPreflightRequested -and $refreshTokenId -match '^[0-9a-f]{32}$' -and
    (Get-Command Test-YurunaRunnerHandoffToken -ErrorAction SilentlyContinue)) {
    $checked = Test-YurunaRunnerHandoffToken -TokenId $refreshTokenId -Role cycle -RuntimeDir $env:YURUNA_RUNTIME_DIR
    if ($checked.Valid) { $refreshPreflight = $checked }
}
if (-not $refreshPreflight) {
    # The inner must never inherit a preflight request this process rejected.
    Remove-Item -LiteralPath 'Env:YURUNA_REFRESH_HANDOFF_TOKEN' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'Env:YURUNA_REFRESH_PREFLIGHT' -ErrorAction SilentlyContinue
}
$refreshBarrierRequestId = if ($env:YURUNA_REFRESH_BARRIER) { [string]$env:YURUNA_REFRESH_BARRIER } else { $null }

# --- REGION: Run one cycle
# Called BARE, and never captured: `$result = Invoke-RunnerOuterCycle ...` reads
# the cycle off the success stream, and that one assignment is enough to make
# PowerShell give the inner pwsh an anonymous pipe for stdout instead of letting it
# inherit this process's console. The call operator inside then returns when that
# pipe reaches EOF rather than when the inner exits -- and the status service the
# inner spawns holds the write end open for its whole life (Start-Process
# -RedirectStandard* sets bInheritHandles=TRUE, which hands it a duplicate of every
# inheritable handle the inner has). The host completes one cycle and stops: the
# inner logs "about to exit with code 0" and "outer runner back in control" never
# follows. Windows-only, because the POSIX detach replaces the descriptors.
# The result comes back through the module instead; letting the stream reach the
# host also puts the cycle's own output back on the operator's console.
Invoke-RunnerOuterCycle -Cycle $Cycle -State @{
    RepoRoot                  = $RepoRoot
    ConfigPath                = $ConfigPath
    InnerScript               = $InnerScript
    PwshExe                   = $pwshExe
    ArgList                   = $argList
    ForwardEnvSnapshot        = $forwardEnvSnapshot
    ShutdownState             = $shutdownState
    NoGitPull                 = [bool]$NoGitPull
    FailurePauseMaxSeconds    = 60 * 60
    FailureCommitPollSeconds  = 5 * 60
    OuterPullErrorSleepSeconds    = 30
    InnerSpawnErrorSleepSeconds   = 30
    StepTimeoutSecondsDefault = 2700
    PreambleTimeoutSecondsDefault = 600
    WatchdogPollSeconds       = 30
    TestRoot                  = $TestRoot
    CycleGeneration           = if ($CycleGeneration) { $CycleGeneration } else { $null }
    RefreshPreflightRequested = [bool]$refreshPreflightRequested
    RefreshPreflightTokenId   = if ($refreshPreflight) { $refreshTokenId } else { $null }
    RefreshPreflightPurpose   = if ($refreshPreflight) { [string]$refreshPreflight.Purpose } else { $null }
    RefreshPreflightRequestId = if ($refreshPreflight) { [string]$refreshPreflight.RequestId } else { $null }
    RefreshBarrierRequestId   = $refreshBarrierRequestId
}
$result = Get-LastOuterCycleResult

$outcome  = if ($result -and $result.Outcome) { [string]$result.Outcome } else { 'completed' }
$exitCode = if ($result -and $null -ne $result.ExitCode) { [int]$result.ExitCode } else { 0 }

# --- REGION: Write the cycle result
# Written before exiting so the caller can distinguish "the inner failed" from
# "the cycle never got that far".
$outcomeFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.cycle.outcome.json'
try {
    $json = [ordered]@{
        outcome         = $outcome
        exitCode        = $exitCode
        cycleGeneration = if ($CycleGeneration) { $CycleGeneration } else { $null }
    } | ConvertTo-Json -Compress
    # The [bool] result is consumed rather than left on the success stream: this
    # process runs with its parent's console attached, so anything it returns
    # uncaptured prints a bare value between the caller's per-cycle lines. It
    # reports a failed write by returning $false rather than throwing, so the
    # catch below would not see one.
    if (-not (Write-YurunaStateFile -Path $outcomeFile -Content $json -Confirm:$false)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_28a938238a1f9f61' -Arguments @{ outcomeFile = "$outcomeFile" })
    }
} catch {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d1c2444b71ef8fde' -Arguments @{ message = "$($_.Exception.Message)" })
}

exit $exitCode
