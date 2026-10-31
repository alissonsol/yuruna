<#PSScriptInfo
.VERSION 2026.10.31
.GUID 4245d5d1-5745-4e5e-b405-e37f1c12f700
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
    One-shot project test: wipe <RepoRoot>/project, re-clone from
    repositories.projectUrl, then run a single test cycle exactly as
    Start-TestRunner would have. Not a loop -- exits when the cycle
    finishes.

.DESCRIPTION
    See https://yuruna.link/42010605-0021.
.PARAMETER ConfigPath
    test.config.yml path (default: next to this script)
.PARAMETER logLevel
    Error|Warning|Information|Verbose|Debug. Forwarded to
    the inner. Omit to read test.config.yml.logLevel.

.NOTES
    Concurrency: Invoke-TestProject holds the runtime's one-shot lease
    (oneshot.pid) from before the checkout is replaced until it exits, and
    refuses to start while a Start-TestRunner owns runner.pid or another
    one-shot run holds the lease. Start-TestRunner refuses to start while
    this run holds it.

    -WhatIf reports the replacement and stops before anything is changed;
    an unknown or misspelled parameter is a binding error.

    Exit codes are the cycle's: 0 passed, 1 failed, 75 failed nothing but
    skipped a planned guest, 78 the configuration gate refused, 70 the cycle
    left no usable outcome record; 2 when it did not run (a drained or paused
    pool, a host refresh, Ctrl+C).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = $null,
    # Skip the pre-cycle Test-Config.ps1 gate. Use only for ad-hoc /
    # in-progress edit runs where the operator knowingly accepts that a
    # misconfigured test.config.yml / vault.yml / users.yml will surface
    # in the cycle itself instead of at startup. Mirrors -NoConfigGate
    # on Start-TestRunner / Debug-TestSequence.
    [switch]$NoConfigGate,
    # Skip the built-in HTTP status service. Invoke-TestProject starts no server of
    # its own -- it delegates that to the inner runner it spawns -- so this is
    # forwarded to Invoke-TestRunnerInnerLoop, where the shared status-service gate
    # honors it. Mirrors -NoStatusService on Start-TestRunner / Debug-TestSequence.
    [switch]$NoStatusService,
    [ValidateSet('Error', 'Warning', 'Information', 'Verbose', 'Debug', IgnoreCase = $true)]
    [string]$logLevel
)

# A Windows console code page prints Chinese and Hebrew catalog text as
# question marks; YURUNA_KEEP_CONSOLE_ENCODING=1 keeps the console's own.
if ($IsWindows -and $env:YURUNA_KEEP_CONSOLE_ENCODING -ne '1') { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) }

Import-Module (Join-Path $PSScriptRoot '../automation/Yuruna.Globalization.psm1') -DisableNameChecking

# --- REGION: Resolve paths
Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -ConfigPath $ConfigPath
$TestRoot    = $paths.TestRoot
$RepoRoot    = $paths.RepoRoot
$ModulesDir  = $paths.ModulesDir
$ConfigPath  = $paths.ConfigPath
# Publish the resolved config path so every cross-module reload site
# (Sync-RunnerCycleConfig in the inner runner, Update-TransportDefault in
# Test.Transport) reads the SAME file when -ConfigPath <elsewhere> is
# in play. The inner runner that this script spawns inherits the var.
$env:YURUNA_CONFIG_PATH = $ConfigPath
$InnerScript = Join-Path $ModulesDir 'Invoke-TestRunnerInnerLoop.ps1'
# Canonical module set for the Project entry-point: Test.Config,
# Test.YurunaDir, Test.ConfigPreflight, Test.HostContract, Test.InnerSpawn.
Initialize-YurunaEntryPointModuleSet -For Project -ModulesDir $ModulesDir

# On host.ubuntu.kvm, relaunch under `sg libvirt` when this shell's group set
# lacks libvirt: the inner cycle drives virsh and virt-install with the groups
# it inherits from this process. Runs before the lease, which the relaunched
# run then takes for itself.
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

# See https://yuruna.link/42010605-0020
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure


# --- REGION: Stop-WithReason
function Stop-WithReason {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Pure exit helper; no externally observable state change beyond the exit itself.')]
    param(
        [Parameter(Mandatory)][int]$Code,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Reason
    )
    Write-Output ''
    Write-Output '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
    Write-Output "  Invoke-TestProject: STOP (exit $Code) at $Step"
    foreach ($line in ($Reason -split "`r?`n")) { Write-Output "  $line" }
    Write-Output '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
    Write-Output ''
    if (Get-Command Save-RecoveryResult -ErrorAction SilentlyContinue) {
        $null = Save-RecoveryResult -EntryPoint project -ExitCode $Code
    }
    Close-ProjectRun
    exit $Code
}

# Remove this run's Ctrl+C subscription and release its one-shot lease. Both
# are left alone when this run never took them, so the stops before the lease
# pass through harmlessly; the subscription would otherwise outlive the run in
# the operator's shell.
function Close-ProjectRun {
    if (Get-Command Unregister-EntryPointCancelHandler -ErrorAction SilentlyContinue) { Unregister-EntryPointCancelHandler }
    if ($env:YURUNA_RUNTIME_DIR -and (Get-Command Exit-YurunaOneShotLease -ErrorAction SilentlyContinue)) {
        $null = Exit-YurunaOneShotLease -RuntimeDir $env:YURUNA_RUNTIME_DIR -Confirm:$false
    }
}

# --- REGION: Elevation check
# See https://yuruna.link/42010605-001f
if (-not (Assert-Elevation -HostType (Get-HostType))) {
    Stop-WithReason -Code $ExitFailure -Step 'Pre-flight (elevation)' `
        -Reason 'This host requires an elevated shell. Re-run from an elevated PowerShell -- stopping now, before <RepoRoot>/project is wiped and re-cloned.'
}

# --- REGION: Preflight: repo layout
if (-not (Test-Path -LiteralPath $InnerScript)) {
    Stop-WithReason -Code $ExitFailure -Step 'Pre-flight' `
        -Reason "Inner test runner not found at $InnerScript. The yuruna repo layout appears wrong; verify your clone is intact."
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Stop-WithReason -Code $ExitFailure -Step 'Pre-flight' `
        -Reason @"
test.config.yml not found at $ConfigPath. Bootstrap it with:
  Copy-Item $TestRoot/test.config.yml.template $ConfigPath
and set repositories.projectUrl before re-running.
"@
}

# --- REGION: Preflight: powershell-yaml + projectUrl
if (-not (Get-Module -ListAvailable -Name powershell-yaml -ErrorAction SilentlyContinue)) {
    Stop-WithReason -Code $ExitFailure -Step 'Pre-flight' `
        -Reason "powershell-yaml is not installed. Install with: Install-Module powershell-yaml -Scope CurrentUser"
}
Import-Module powershell-yaml -ErrorAction Stop
# Test.Config / Test.YurunaDir / Test.ConfigPreflight / Test.HostContract /
# Test.InnerSpawn already imported by Initialize-YurunaEntryPointModuleSet above.

try {
    $cfg = Read-TestConfig -Path $ConfigPath -ThrowOnError
} catch {
    Stop-WithReason -Code $ExitFailure -Step 'Pre-flight' `
        -Reason "Could not parse $ConfigPath as YAML: $($_.Exception.Message)"
}

$projectUrl = Get-TestConfigValue -Config $cfg -Path 'repositories.projectUrl'
if ($projectUrl) { $projectUrl = "$projectUrl".Trim() }
if ([string]::IsNullOrWhiteSpace($projectUrl)) {
    Stop-WithReason -Code $ExitFailure -Step 'Pre-flight' `
        -Reason @"
repositories.projectUrl is empty in $ConfigPath. Invoke-TestProject requires a
remote project to wipe and re-clone -- the in-tree fallback path
(project/ shipped with the framework) is not supported here.
Set repositories.projectUrl to a clonable URL and retry.
"@
}

# --- REGION: Confirm the replacement
# Everything above only read state. -WhatIf stops here, before the lease, the
# source handoff, the checkout replacement and the cycle: module functions do
# not inherit this script's -WhatIf, so nothing below may run under it.
if (-not $PSCmdlet.ShouldProcess((Join-Path $RepoRoot 'project'), (Format-YurunaOperatorMessage -Key 'runner.project_checkout_replace_action' -Arguments @{ projectUrl = "$projectUrl" }))) {
    exit $ExitOk
}

# --- REGION: Bootstrap runtime + log dirs, claim the runtime
# Publish the runtime and log dirs the inner inherits, take the one-shot lease
# and refuse while another run owns the runtime. Stop-WithReason and the finally
# block at the end of the script release the lease.
# See https://yuruna.link/42010605-001e
if (-not (Initialize-YurunaOneShotEntryPoint -CallerName 'Invoke-TestProject')) {
    Stop-WithReason -Code $ExitFailure -Step 'Pre-flight (single-instance)' `
        -Reason 'Another run owns this runtime dir (a live Start-TestRunner, or the one-shot run named above). Stop it before invoking Invoke-TestProject, or run from a different YURUNA_RUNTIME_DIR.'
}

# --- REGION: Ctrl+C handler
# Ctrl+C flips the shared flag. The runner's dispatcher, which waits on the
# cycle, stops the cycle's process tree when it sees it; this process keeps
# running so it records the result and releases the runtime.
# See https://yuruna.link/42010605-0002
$script:CancelState = Register-EntryPointCancelHandler -ExitAfterLabel 'cycle'

# See https://yuruna.link/42010605-001d
if (Get-Command Clear-StaleControlState -ErrorAction SilentlyContinue) {
    $null = Clear-StaleControlState -Scope PreSpawn -RuntimeDir $env:YURUNA_RUNTIME_DIR -Confirm:$false
}

Write-Output ''
Write-Output '========'
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_c785c19a8a938b31')
Write-Output "  Config:     $ConfigPath"
Write-Output "  ProjectUrl: $projectUrl"
Write-Output "  RepoRoot:   $RepoRoot"
Write-Output "  Inner:      $InnerScript"
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_9b5f387caf6f42bd')
Write-Output '========'

# --- REGION: Run one runner cycle
# Run the cycle through the runner's own dispatcher, as a Start-TestRunner cycle
# runs, and score it from its outcome record. The framework stays as installed:
# the cycle never pulls it.
# See https://yuruna.link/42010605-001b
Initialize-YurunaEntryPointModuleSet -For Outer -ModulesDir $ModulesDir
$previousGeneration = $env:YURUNA_CYCLE_GENERATION
$env:YURUNA_CYCLE_GENERATION = [guid]::NewGuid().ToString('N') + ':1'
try {
    Write-Output ''
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_4fb40cac594a7bbc' -Arguments @{ projectUrl = "$projectUrl" })
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_554a120b73560a96')
    $cycleState = @{
        CycleScript     = Join-Path $ModulesDir 'Invoke-TestCycleRunner.ps1'
        RepoRoot        = $RepoRoot
        ConfigPath      = $ConfigPath
        PwshExe         = Get-PwshExePath
        ShutdownState   = $script:CancelState
        NoGitPull       = $true
        NoStatusService = [bool]$NoStatusService
        NoConfigGate    = [bool]$NoConfigGate
        CycleGeneration = $env:YURUNA_CYCLE_GENERATION
    }
    if ($PSBoundParameters.ContainsKey('logLevel')) { $cycleState['LogLevel'] = $logLevel }
    $cycleResult = Invoke-OuterCycleDispatch -State $cycleState -Cycle 1
    $exitCode = Get-OneShotCycleExitCode -Result $cycleResult

    Write-Output ''
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_d8c8c432b7e3764d' -Arguments @{ innerExit = "$exitCode" })

    # --- REGION: Stop
    # Not a repeated process. Surface the cycle's exit code so a CI step or
    # upstream wrapper can branch on cycle pass/fail just as if
    # Invoke-TestRunnerInnerLoop had been called directly.
    Write-Output ''
    Write-Output '========'
    Write-Output "  Invoke-TestProject: STOP (exit $exitCode)"
    if ($exitCode -eq $ExitOk) {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_4573c62ccdadf85e')
    } elseif ($cycleResult.Outcome -cin @('drain', 'paused', 'refresh-gated', 'refresh-preflight', 'shutdown')) {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.project_cycle_not_run' -Arguments @{ outcome = [string]$cycleResult.Outcome })
    } elseif ($exitCode -eq (Get-DegradedCycleExitCode)) {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.project_cycle_degraded' -Arguments @{ dIR = "$env:YURUNA_LOG_DIR" })
    } else {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_3d14a370bf8bc861' -Arguments @{ dIR = "$env:YURUNA_LOG_DIR" })
    }
    Write-Output '========'

    if (Get-Command Save-RecoveryResult -ErrorAction SilentlyContinue) {
        $null = Save-RecoveryResult -EntryPoint project -ExitCode $exitCode
    }
    exit $exitCode
} catch {
    Stop-WithReason -Code $ExitFailure -Step 'Cycle dispatch' -Reason $_.Exception.Message
} finally {
    $env:YURUNA_CYCLE_GENERATION = $previousGeneration
    Close-ProjectRun
}
