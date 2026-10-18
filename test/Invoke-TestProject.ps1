<#PSScriptInfo
.VERSION 2026.10.18.1
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
    See https://yuruna.link/42010605-0002.
.PARAMETER ConfigPath
    test.config.yml path (default: next to this script)
.PARAMETER logLevel
    Error|Warning|Information|Verbose|Debug. Forwarded to
    the inner. Omit to read test.config.yml.logLevel.

.NOTES
    Concurrency: Invoke-TestProject does not manage runner.pid itself. The
    inner runner it spawns owns inner.pid and runs its own single-
    instance check (which will stop a running Start-TestRunner.ps1).
    Stop any long-running Start-TestRunner before invoking Invoke-TestProject
    if you want clean isolation; the inner's takeover handles the
    interactive operator case but cannot rescue cycles already
    mid-flight.
#>

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
Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -ConfigPath $ConfigPath
$TestRoot    = $paths.TestRoot
$RepoRoot    = $paths.RepoRoot
$ModulesDir  = $paths.ModulesDir
$ConfigPath  = $paths.ConfigPath
# Publish the resolved config path so every cross-module reload site
# (Sync-RuntimeConfig in the inner runner, Update-TransportDefault in
# Test.Transport) reads the SAME file when -ConfigPath <elsewhere> is
# in play. The inner runner that this script spawns inherits the var.
$env:YURUNA_CONFIG_PATH = $ConfigPath
$InnerScript = Join-Path $ModulesDir 'Invoke-TestRunnerInnerLoop.ps1'
# Canonical module set for the Project entry-point: Test.Config,
# Test.YurunaDir, Test.ConfigPreflight, Test.HostContract, Test.InnerSpawn.
Initialize-YurunaEntryPointModuleSet -For Project -ModulesDir $ModulesDir

# See https://yuruna.link/42010605-0002
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure

# The steps this run took, in order, for the typed result recorded at every exit.
$script:RecoverySteps = [System.Collections.Generic.List[object]]::new()

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
        $null = Save-RecoveryResult -EntryPoint project -ExitCode $Code -Steps @($script:RecoverySteps)
    }
    exit $Code
}

# --- REGION: Elevation check
# See https://yuruna.link/42010605-0002
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

# --- REGION: Bootstrap runtime + log dirs
# Initialize-YurunaRuntimeDir / Initialize-YurunaLogDir publish
# YURUNA_RUNTIME_DIR / YURUNA_LOG_DIR; the inner inherits them so its
# pidfile, heartbeats, status.json, and per-cycle log all land in the
# same place a Start-TestRunner cycle would write to. Test.YurunaDir
# was imported by Initialize-YurunaEntryPointModuleSet above.
$null = Initialize-YurunaRuntimeDir
$null = Initialize-YurunaLogDir

# See https://yuruna.link/42010605-0002
if (-not (Assert-NoOtherRunner -RuntimeDir $env:YURUNA_RUNTIME_DIR -CallerName 'Invoke-TestProject')) {
    Stop-WithReason -Code $ExitFailure -Step 'Pre-flight (single-instance)' `
        -Reason 'A live Start-TestRunner already owns runner.pid in this runtime dir. Stop it before invoking Invoke-TestProject, or run from a different YURUNA_RUNTIME_DIR.'
}

# See https://yuruna.link/42010605-0002
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

# --- REGION: Pre-cycle config gate
# Same gate as Start-TestRunner and Debug-TestSequence. Invoke-TestProject
# re-clones the project then runs one cycle. Without this gate a misconfigured
# framework config (vault, users, transports) would only surface mid-cycle as a
# confusing step failure. Bypass with -NoConfigGate for in-progress edits.
$gate = Invoke-ConfigGate -TestRoot $TestRoot -ConfigPath $ConfigPath -Skip:$NoConfigGate -CallerName 'Invoke-TestProject'
if (-not $gate.passed) {
    Stop-WithReason -Code $ExitFailure -Step 'Pre-cycle config gate' `
        -Reason "Test-Config.ps1 exited $($gate.exitCode). Fix the FAIL items above (test.config.yml, vault.yml, users.yml, transports.yml, ...) then re-run. To bypass for an in-progress edit, pass -NoConfigGate."
}

# --- REGION: Step 1+2: wipe + re-clone project
# See https://yuruna.link/42010605-0002

Write-Output ''
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_4fb40cac594a7bbc' -Arguments @{ projectUrl = "$projectUrl" })
$checkoutStep = Invoke-CycleCheckoutStep -RepoRoot $RepoRoot -ProjectUrl $projectUrl
[void]$script:RecoverySteps.Add($checkoutStep)
$cloneRes = @{ success = $checkoutStep.Ok; skipped = $checkoutStep.Skipped; errorMessage = $checkoutStep.ErrorMessage }
if (-not $cloneRes.success) {
    Stop-WithReason -Code $ExitFailure -Step 'Step 1+2 (wipe + clone)' `
        -Reason $cloneRes.errorMessage
}
Write-Output '[Invoke-TestProject] Step 1+2: complete.'

# --- REGION: Step 3: spawn one inner cycle
# See https://yuruna.link/42010605-0002
Write-Output ''
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_554a120b73560a96')

# Test.InnerSpawn was imported by Initialize-YurunaEntryPointModuleSet above.
$pwshExe = Get-PwshExePath
# See https://yuruna.link/42010605-0002
$innerParams = [ordered]@{
    ConfigPath     = $ConfigPath
    NoGitPull      = [switch]::new($true)
    NoProjectClone = [switch]::new($true)
    NoConfigGate   = [switch]::new($true)
}
# Forward -NoStatusService so the inner's shared status-service gate honors it; the
# server is the inner's responsibility, so Invoke-TestProject only passes it through.
if ($NoStatusService)                           { $innerParams['NoStatusService'] = [switch]::new($true) }
if ($PSBoundParameters.ContainsKey('logLevel')) { $innerParams['logLevel'] = $logLevel }
$argList = New-InnerRunnerArgList -ScriptPath $InnerScript -Parameters $innerParams

$previousRelaunch = $env:YURUNA_RUNNER_RELAUNCH
$env:YURUNA_RUNNER_RELAUNCH = '1'

$innerExit = 0
try {
    & $pwshExe @argList
    $innerExit = $LASTEXITCODE
} catch {
    Stop-WithReason -Code $ExitFailure -Step 'Step 3 (spawn inner)' `
        -Reason "Could not invoke inner pwsh ($pwshExe): $($_.Exception.Message)"
} finally {
    $env:YURUNA_RUNNER_RELAUNCH = $previousRelaunch
}

Write-Output ''
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_d8c8c432b7e3764d' -Arguments @{ innerExit = "$innerExit" })

# --- REGION: Step 4: stop
# Not a repeated process. Surface the inner's exit code so a CI step or
# upstream wrapper can branch on cycle pass/fail just as if
# Invoke-TestRunnerInnerLoop had been called directly.
Write-Output ''
Write-Output '========'
Write-Output "  Invoke-TestProject: STOP (exit $innerExit)"
if ($innerExit -eq $ExitOk) {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_4573c62ccdadf85e')
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_3d14a370bf8bc861' -Arguments @{ dIR = "$env:YURUNA_LOG_DIR" })
}
Write-Output '========'

if (Get-Command Save-RecoveryResult -ErrorAction SilentlyContinue) {
    $null = Save-RecoveryResult -EntryPoint project -ExitCode $innerExit -Steps @($script:RecoverySteps)
}
exit $innerExit
