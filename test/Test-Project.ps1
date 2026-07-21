<#PSScriptInfo
.VERSION 2026.07.21
.GUID 4292b214-b454-46f0-976c-81a548f8de5d
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
    Invoke-TestRunner would have. Not a loop -- exits when the cycle
    finishes.

.DESCRIPTION
    Each step is gated and reports its own reason on failure:

      Step 1+2 wipe + re-clone <RepoRoot>/project via the same
                Test.HostContract\Update-ProjectClone helper Invoke-TestInnerRunner
                calls every cycle. A failure here stops with a clear
                "what + why" line; the inner is never spawned.

      Step 3   spawns Invoke-TestInnerRunner.ps1 in a fresh pwsh -- the
                same spawn shape Invoke-TestRunner uses for every cycle --
                with -NoProjectClone (the clone is already fresh) and
                -NoGitPull (Test-Project tests the project as it stands
                locally; a mid-test framework update would muddle the
                signal). The inner does the full cycle, records it as a
                regular cycle in status.json, and exits.

      Step 4   surface the inner's exit code as our own and stop. Not
                resumed; the operator (or CI) re-invokes Test-Project
                explicitly if they want another pass.

    By calling Update-ProjectClone + Invoke-TestInnerRunner directly,
    Test-Project exercises the same code paths Invoke-TestRunner does --
    a regression in either surfaces here first.

.PARAMETER ConfigPath  test.config.yml path (default: next to this script)
.PARAMETER logLevel    Error|Warning|Information|Verbose|Debug. Forwarded to
                       the inner. Omit to read test.config.yml.logLevel.

.NOTES
    Concurrency: Test-Project does not manage runner.pid itself. The
    inner runner it spawns owns inner.pid and runs its own single-
    instance check (which will stop a running Invoke-TestRunner.ps1).
    Stop any long-running Invoke-TestRunner before invoking Test-Project
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
    # on Invoke-TestRunner / Test-Sequence.
    [switch]$NoConfigGate,
    # Skip the built-in HTTP status server. Test-Project starts no server of
    # its own -- it delegates that to the inner runner it spawns -- so this is
    # forwarded to Invoke-TestInnerRunner, where the shared status-service gate
    # honors it. Mirrors -NoServer on Invoke-TestRunner / Test-Sequence.
    [switch]$NoServer,
    [ValidateSet('Error', 'Warning', 'Information', 'Verbose', 'Debug', IgnoreCase = $true)]
    [string]$logLevel
)

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
$InnerScript = Join-Path $ModulesDir 'Invoke-TestInnerRunner.ps1'
# Canonical module set for the Project entry-point: Test.Config,
# Test.YurunaDir, Test.ConfigPreflight, Test.HostContract, Test.InnerSpawn.
Initialize-YurunaEntryPointModuleSet -For Project -ModulesDir $ModulesDir

# Exit-code contract: 0 = success, 1 = anything else. A binary code
# is what pass/fail consumers want; a CI consumer that needs to
# discriminate between "preflight" / "clone failed" / "inner spawn
# failed" reads the Stop-WithReason banner ("STOP at <Step>") rather
# than a numeric code. Standardised on 0/1 across all entry points;
# the $Step + $Reason in the banner carry the "why".
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure

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
    Write-Output "  Test-Project: STOP (exit $Code) at $Step"
    foreach ($line in ($Reason -split "`r?`n")) { Write-Output "  $line" }
    Write-Output '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
    Write-Output ''
    exit $Code
}

# --- REGION: Pre-flight: repo layout
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

# --- REGION: Pre-flight: powershell-yaml + projectUrl
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
repositories.projectUrl is empty in $ConfigPath. Test-Project requires a
remote project to wipe and re-clone -- the in-tree fallback path
(project/ shipped with the framework) is not supported here.
Set repositories.projectUrl to a clonable URL and retry.
"@
}

# --- REGION: Bootstrap runtime + log dirs
# Initialize-YurunaRuntimeDir / Initialize-YurunaLogDir publish
# YURUNA_RUNTIME_DIR / YURUNA_LOG_DIR; the inner inherits them so its
# pidfile, heartbeats, status.json, and per-cycle log all land in the
# same place an Invoke-TestRunner cycle would write to. Test.YurunaDir
# was imported by Initialize-YurunaEntryPointModuleSet above.
$null = Initialize-YurunaRuntimeDir
$null = Initialize-YurunaLogDir

# Refuse to start when an Invoke-TestRunner already owns the runtime dir.
# Test-Project spawns its own inner with YURUNA_RUNNER_RELAUNCH=1 below,
# which tells inner to skip its own pidfile-takeover guard -- safe only
# when Test-Project itself is the legitimate parent. If a real Invoke-
# TestRunner is already running, that contract would let our inner race
# the live cycle's runner.pid + status.json updates. Assert-NoOtherRunner
# (Test.Prelude, backed by Test.SingleInstance) reads runner.pid +
# runner.start and refuses; Invoke-TestRunner's takeover path is the
# opposite (Stop-StaleRunner) and stays in the outer.
if (-not (Assert-NoOtherRunner -RuntimeDir $env:YURUNA_RUNTIME_DIR -CallerName 'Test-Project')) {
    Stop-WithReason -Code $ExitFailure -Step 'Pre-flight (single-instance)' `
        -Reason 'A live Invoke-TestRunner already owns runner.pid in this runtime dir. Stop it before invoking Test-Project, or run from a different YURUNA_RUNTIME_DIR.'
}

# Sweep the parked interactive control state before handing off to the
# inner. -Scope PreSpawn archives a leftover break-active.json and clears
# leftover pause flags (control.step-pause / .cycle-pause) so the spawned
# inner doesn't inherit the parked break state -- the status UI would
# otherwise keep the previous run's Continue button live. Test-Project
# spawns Invoke-TestInnerRunner directly (bypassing the outer
# Invoke-TestRunner that normally hosts Invoke-YurunaBootRecovery), so
# this sweep has to happen here. PreSpawn deliberately leaves
# control.cycle-restart for the child inner to consume as ITS own restart.
if (Get-Command Clear-StaleControlState -ErrorAction SilentlyContinue) {
    $null = Clear-StaleControlState -Scope PreSpawn -RuntimeDir $env:YURUNA_RUNTIME_DIR -Confirm:$false
}

Write-Output ''
Write-Output '============================================='
Write-Output '  Test-Project (single test cycle)'
Write-Output "  Config:     $ConfigPath"
Write-Output "  ProjectUrl: $projectUrl"
Write-Output "  RepoRoot:   $RepoRoot"
Write-Output "  Inner:      $InnerScript"
Write-Output "  Stop:       Ctrl+C (or completes when the inner exits)"
Write-Output '============================================='

# --- REGION: Pre-cycle config gate (mirrors Invoke-TestRunner + Test-Sequence)
# Test-Project re-clones the project then runs one cycle. Without this gate
# a misconfigured framework config (vault, users, transports) would only
# surface mid-cycle as a confusing step failure. Bypass with -NoConfigGate
# for in-progress edits.
$gate = Invoke-ConfigGate -TestRoot $TestRoot -ConfigPath $ConfigPath -Skip:$NoConfigGate -CallerName 'Test-Project'
if (-not $gate.passed) {
    Stop-WithReason -Code $ExitFailure -Step 'Pre-cycle config gate' `
        -Reason "Test-Config.ps1 exited $($gate.exitCode). Fix the FAIL items above (test.config.yml, vault.yml, users.yml, transports.yml, ...) then re-run. To bypass for an in-progress edit, pass -NoConfigGate."
}

# --- REGION: Step 1+2: wipe + re-clone project
# Update-ProjectClone is the same helper Invoke-TestInnerRunner uses every
# cycle -- by calling it here, a regression in clone removal, git clone
# itself, or the safety check (refuse to delete outside RepoRoot) surfaces
# in Test-Project before it ever bites Invoke-TestRunner. The function
# combines the wipe + clone in a single safe sequence; splitting them in
# Test-Project would duplicate the safety check without adding value.
# Test.HostContract was imported by Initialize-YurunaEntryPointModuleSet above.

Write-Output ''
Write-Output "[Test-Project] Step 1+2: wipe and re-clone <RepoRoot>/project from $projectUrl"
$cloneRes = Update-ProjectClone -RepoRoot $RepoRoot -ProjectUrl $projectUrl -Confirm:$false
if (-not $cloneRes.success) {
    Stop-WithReason -Code $ExitFailure -Step 'Step 1+2 (wipe + clone)' `
        -Reason $cloneRes.errorMessage
}
Write-Output '[Test-Project] Step 1+2: complete.'

# --- REGION: Step 3: spawn one inner cycle
# Mirror Invoke-TestRunner's spawn pattern so Test-Project exercises the
# same boundary the recurring runner does:
#   * call operator (not Start-Process) -- the inner inherits our env,
#     stdio, and signal context; same as Invoke-TestRunner
#   * -Command (not -File) -- pwsh -File coerces every argv to [string],
#     which would break [switch] / [int] parameters
#   * -NoProfile -- $PROFILE can't clobber YURUNA_* env vars
#   * YURUNA_RUNNER_RELAUNCH=1 -- inner skips its own pidfile-takeover guard
#     (it can't safely take over us; we're the legitimate parent)
#   * -NoProjectClone -- step 1+2 already produced a fresh tree; the
#     inner trusts it and skips Update-ProjectClone
#   * -NoGitPull -- Test-Project is a project test, not a framework test;
#     a mid-test framework update would conflate signals
Write-Output ''
Write-Output '[Test-Project] Step 3: spawning Invoke-TestInnerRunner for one test cycle.'

# Test.InnerSpawn was imported by Initialize-YurunaEntryPointModuleSet above.
$pwshExe = Get-PwshExePath
# Build the parameter set Test-Project must pass to the inner. -NoGitPull
# and -NoProjectClone are *always* forced here -- Test-Project does a fresh
# clone itself and tests the local tree as-is; a mid-test framework update
# would conflate signals. logLevel is forwarded only if the operator passed
# it on this script's command line (PSBoundParameters), so the inner falls
# back to its config-file default otherwise.
$innerParams = [ordered]@{
    ConfigPath     = $ConfigPath
    NoGitPull      = [switch]::new($true)
    NoProjectClone = [switch]::new($true)
}
# Forward -NoServer so the inner's shared status-service gate honors it; the
# server is the inner's responsibility, so Test-Project only passes it through.
if ($NoServer)                                  { $innerParams['NoServer'] = [switch]::new($true) }
if ($PSBoundParameters.ContainsKey('logLevel')) { $innerParams['logLevel'] = $logLevel }
$argList = New-InnerRunnerArgList -ScriptPath $InnerScript -Parameters $innerParams

$env:YURUNA_RUNNER_RELAUNCH = '1'

$innerExit = 0
try {
    & $pwshExe @argList
    $innerExit = $LASTEXITCODE
} catch {
    Stop-WithReason -Code $ExitFailure -Step 'Step 3 (spawn inner)' `
        -Reason "Could not invoke inner pwsh ($pwshExe): $($_.Exception.Message)"
}

Write-Output ''
Write-Output "[Test-Project] Step 3: inner cycle exited with code $innerExit."

# --- REGION: Step 4: stop
# Not a repeated process. Surface the inner's exit code so a CI step or
# upstream wrapper can branch on cycle pass/fail just as if Invoke-Test-
# InnerRunner had been called directly.
Write-Output ''
Write-Output '============================================='
Write-Output "  Test-Project: STOP (exit $innerExit)"
if ($innerExit -eq $ExitOk) {
    Write-Output '  Cycle PASSED.'
} else {
    Write-Output "  Cycle FAILED. See $env:YURUNA_LOG_DIR for the per-cycle log."
}
Write-Output '============================================='

exit $innerExit
