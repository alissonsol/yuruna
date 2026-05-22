<#PSScriptInfo
.VERSION 2026.05.22
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456710
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
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
                Test.Host\Update-ProjectClone helper Invoke-TestInnerRunner
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
    [ValidateSet('Error', 'Warning', 'Information', 'Verbose', 'Debug', IgnoreCase = $true)]
    [string]$logLevel
)

$TestRoot    = $PSScriptRoot
$RepoRoot    = Split-Path -Parent $TestRoot
$ModulesDir  = Join-Path $TestRoot 'modules'
$InnerScript = Join-Path $ModulesDir 'Invoke-TestInnerRunner.ps1'

# Distinct exit codes per failure mode so a CI log can tell "config
# missing" apart from "clone failed" apart from "the cycle itself failed"
# without parsing the message.
$ExitOk           = 0
$ExitPreFlight    = 2  # repo layout / config / module missing
$ExitCloneFailed  = 3  # Update-ProjectClone returned success=false
$ExitInnerSpawn   = 4  # could not start the inner pwsh at all
# Cycle-level failure surfaces as the inner's own exit code (typically 1).

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

# --- Pre-flight: repo layout ------------------------------------------------
if (-not (Test-Path -LiteralPath $InnerScript)) {
    Stop-WithReason -Code $ExitPreFlight -Step 'Pre-flight' `
        -Reason "Inner test runner not found at $InnerScript. The yuruna repo layout appears wrong; verify your clone is intact."
}

if (-not $ConfigPath) { $ConfigPath = Join-Path $TestRoot 'test.config.yml' }
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Stop-WithReason -Code $ExitPreFlight -Step 'Pre-flight' `
        -Reason @"
test.config.yml not found at $ConfigPath. Bootstrap it with:
  Copy-Item $TestRoot/test.config.yml.template $ConfigPath
and set repositories.projectUrl before re-running.
"@
}

# --- Pre-flight: powershell-yaml + projectUrl --------------------------------
if (-not (Get-Module -ListAvailable -Name powershell-yaml -ErrorAction SilentlyContinue)) {
    Stop-WithReason -Code $ExitPreFlight -Step 'Pre-flight' `
        -Reason "powershell-yaml is not installed. Install with: Install-Module powershell-yaml -Scope CurrentUser"
}
Import-Module powershell-yaml -ErrorAction Stop

try {
    $cfg = Get-Content -Raw -LiteralPath $ConfigPath -ErrorAction Stop | ConvertFrom-Yaml -Ordered -ErrorAction Stop
} catch {
    Stop-WithReason -Code $ExitPreFlight -Step 'Pre-flight' `
        -Reason "Could not parse $ConfigPath as YAML: $($_.Exception.Message)"
}

$projectUrl = $null
if ($cfg -is [System.Collections.IDictionary] -and
    $cfg.repositories -is [System.Collections.IDictionary] -and
    $cfg.repositories.Contains('projectUrl')) {
    $projectUrl = "$($cfg.repositories.projectUrl)".Trim()
}
if ([string]::IsNullOrWhiteSpace($projectUrl)) {
    Stop-WithReason -Code $ExitPreFlight -Step 'Pre-flight' `
        -Reason @"
repositories.projectUrl is empty in $ConfigPath. Test-Project requires a
remote project to wipe and re-clone -- the in-tree fallback path
(project/ shipped with the framework) is not supported here.
Set repositories.projectUrl to a clonable URL and retry.
"@
}

# --- Bootstrap runtime + log dirs ------------------------------------------
# Initialize-YurunaRuntimeDir / Initialize-YurunaLogDir publish
# YURUNA_RUNTIME_DIR / YURUNA_LOG_DIR; the inner inherits them so its
# pidfile, heartbeats, status.json, and per-cycle log all land in the
# same place an Invoke-TestRunner cycle would write to.
Import-Module (Join-Path $ModulesDir 'Test.RuntimeDir.psm1') -Force
Import-Module (Join-Path $ModulesDir 'Test.LogDir.psm1')   -Force
$null = Initialize-YurunaRuntimeDir
$null = Initialize-YurunaLogDir

Write-Output ''
Write-Output '============================================='
Write-Output '  Test-Project (single test cycle)'
Write-Output "  Config:     $ConfigPath"
Write-Output "  ProjectUrl: $projectUrl"
Write-Output "  RepoRoot:   $RepoRoot"
Write-Output "  Inner:      $InnerScript"
Write-Output "  Stop:       Ctrl+C (or completes when the inner exits)"
Write-Output '============================================='

# --- Step 1+2: wipe + re-clone project --------------------------------------
# Update-ProjectClone is the same helper Invoke-TestInnerRunner uses every
# cycle -- by calling it here, a regression in clone removal, git clone
# itself, or the safety check (refuse to delete outside RepoRoot) surfaces
# in Test-Project before it ever bites Invoke-TestRunner. The function
# combines the wipe + clone in a single safe sequence; splitting them in
# Test-Project would duplicate the safety check without adding value.
Import-Module (Join-Path $ModulesDir 'Test.Host.psm1') -Force

Write-Output ''
Write-Output "[Test-Project] Step 1+2: wipe and re-clone <RepoRoot>/project from $projectUrl"
$cloneRes = Update-ProjectClone -RepoRoot $RepoRoot -ProjectUrl $projectUrl -Confirm:$false
if (-not $cloneRes.success) {
    Stop-WithReason -Code $ExitCloneFailed -Step 'Step 1+2 (wipe + clone)' `
        -Reason $cloneRes.errorMessage
}
Write-Output '[Test-Project] Step 1+2: complete.'

# --- Step 3: spawn one inner cycle ------------------------------------------
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

$pwshExe       = (Get-Process -Id $PID).Path
$escapedScript = $InnerScript -replace "'", "''"
$escapedConfig = $ConfigPath  -replace "'", "''"
$cmdParts = @(
    "& '$escapedScript'"
    "-ConfigPath '$escapedConfig'"
    '-NoGitPull'
    '-NoProjectClone'
)
if ($PSBoundParameters.ContainsKey('logLevel')) {
    $escapedLevel = $logLevel -replace "'", "''"
    $cmdParts += "-logLevel '$escapedLevel'"
}
$argList = @('-NoLogo', '-NoProfile', '-Command', ($cmdParts -join ' '))

$env:YURUNA_RUNNER_RELAUNCH = '1'

$innerExit = 0
try {
    & $pwshExe @argList
    $innerExit = $LASTEXITCODE
} catch {
    Stop-WithReason -Code $ExitInnerSpawn -Step 'Step 3 (spawn inner)' `
        -Reason "Could not invoke inner pwsh ($pwshExe): $($_.Exception.Message)"
}

Write-Output ''
Write-Output "[Test-Project] Step 3: inner cycle exited with code $innerExit."

# --- Step 4: stop -----------------------------------------------------------
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
