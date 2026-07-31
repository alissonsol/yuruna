<#PSScriptInfo
.VERSION 2026.07.31
.GUID 42c7a1b4-6e28-4d35-9f70-2a41c6b8e903
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
    Run exactly ONE test cycle, then exit. Spawned fresh by Invoke-TestRunner.ps1.

.DESCRIPTION
    This is the volatile half of the runner. Everything that changes when the inner
    runner changes lives here or in the modules this script imports: the framework
    repo pull, the pool-intent gate, the pre-spawn cleanup, the watchdog, the inner
    spawn itself, and the cycle-end hooks.

    It exists as a separate PROCESS so that an edit to it -- or to any module it
    imports -- is picked up by the very next cycle. The long-lived runner holds its
    own code resident and would otherwise keep running whatever it parsed at
    startup, which is why updating a machine used to mean stopping the runner.
    Invoke-TestRunner.ps1 keeps only what must not be redone per cycle: the
    single-instance pidfile, the boot-recovery sweep, the runner state machine, and
    the Ctrl+C subscription.

    The operator never invokes this directly.

    Transient outcomes (a failed pull, a paused pool, a drain request, a failed
    spawn) are reported through runner.cycle.outcome.json rather than an exit code,
    because the exit-code space belongs to the inner runner and a sentinel number
    could be mistaken for a real failure. The pause that follows a transient outcome
    is the caller's: a sleep here could not be interrupted by the Ctrl+C the
    operator pressed in the runner's own shell.

    See docs/runner-outer-loop.md for the loop contract and the state machine.

.PARAMETER Cycle
    Cycle number, for log correlation only. The counter itself lives in the caller.
.PARAMETER ConfigPath
    test.config.yml path. Defaults to the resolved canonical path.
.PARAMETER NoGitPull
    Skip the framework repo pull for this cycle.
.PARAMETER NoStatusService
    Forwarded to the inner runner.
.PARAMETER CycleDelaySeconds
    Forwarded to the inner runner.
.PARAMETER logLevel
    Forwarded to the inner runner.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = '$global:__YurunaHostId is the cross-host pool-identity channel; set at script top so NDJSON events + status.json carry hostId for pool joins.')]
param(
    [int]$Cycle = 1,
    [string]$ConfigPath = $null,
    [switch]$NoGitPull,
    [switch]$NoStatusService,
    [int]$CycleDelaySeconds = 30,
    [ValidateSet('Error', 'Warning', 'Information', 'Verbose', 'Debug', IgnoreCase = $true)]
    [string]$logLevel
)

Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths      = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -ConfigPath $ConfigPath
$TestRoot   = $paths.TestRoot
$RepoRoot   = $paths.RepoRoot
$ModulesDir = $paths.ModulesDir
$ConfigPath = $paths.ConfigPath
$env:YURUNA_CONFIG_PATH = $ConfigPath

$InnerScript = Join-Path $ModulesDir 'Invoke-TestRunnerInnerLoop.ps1'
if (-not (Test-Path -LiteralPath $InnerScript)) {
    Write-Error "Invoke-TestRunnerInnerLoop.ps1 not found at $InnerScript"
    exit 1
}

# -Force on every import is the point of this process: the modules are re-read from
# disk each cycle, so a fix lands without restarting the runner.
Initialize-YurunaEntryPointModuleSet -For Outer -ModulesDir $ModulesDir

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
$argList = New-InnerRunnerArgList -ScriptPath $InnerScript -Parameters $PSBoundParameters `
    -ExcludeParameter @('Cycle')

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
}
$result = Get-LastOuterCycleResult

$outcome  = if ($result -and $result.Outcome) { [string]$result.Outcome } else { 'completed' }
$exitCode = if ($result -and $null -ne $result.ExitCode) { [int]$result.ExitCode } else { 0 }

# Written before exiting so the caller can distinguish "the inner failed" from
# "the cycle never got that far".
$outcomeFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.cycle.outcome.json'
try {
    $json = '{"outcome":"' + $outcome + '","exitCode":' + $exitCode + '}'
    # The [bool] result is consumed rather than left on the success stream: this
    # process runs with its parent's console attached, so anything it returns
    # uncaptured prints a bare value between the caller's per-cycle lines. It
    # reports a failed write by returning $false rather than throwing, so the
    # catch below would not see one.
    if (-not (Write-YurunaStateFile -Path $outcomeFile -Content $json -Confirm:$false)) {
        Write-Warning "Could not write the cycle outcome file: $outcomeFile"
    }
} catch {
    Write-Warning "Could not write the cycle outcome file: $($_.Exception.Message)"
}

exit $exitCode
