<#PSScriptInfo
.VERSION 2026.11.23
.GUID 429b7f76-69f3-4b3e-9d30-6b5954d0dae9
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host-update step lab
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
    One phase of a host update, run by the host controller as a step child.
.DESCRIPTION
    The controller starts it detached, with standard input closed, output in
    the request's work folder and YURUNA_RUNTIME_DIR set to the runtime the
    request names. It imports the modules beside it: the checkout's, or a
    controller snapshot's when the controller runs the source update of a
    recovering update with code that predates the checkout. It reads the
    request journal and never writes it; its outcome is the result file,
    written last.
.PARAMETER Step
    preflight, stop_runner, update_source, install, enable, start_listener or
    start_runner.
.PARAMETER RequestId
    The host update's request id.
.PARAMETER Attempt
    The phase's attempt number, as the controller journaled it.
.PARAMETER ResultPath
    The result file, in the request's work folder under the controller root.
.PARAMETER RepoRoot
    The checkout the step acts on; by default the one this script is in.
    Required when the script runs from a snapshot.
.PARAMETER ControllerPid
    The controller, which start_runner records as the gate's owner.
.OUTPUTS
    Nothing; the result file is the outcome, and the exit code mirrors it:
      0  done
      2  done, with remarks an operator should read
      3  skipped: not applicable here, or already true
      1  failed, or no result written
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('preflight', 'stop_runner', 'update_source', 'install', 'enable', 'start_listener', 'start_runner')][string]$Step,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$RequestId,
    [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$Attempt,
    [Parameter(Mandatory)][ValidateScript({ [System.IO.Path]::IsPathFullyQualified($_) })][string]$ResultPath,
    [ValidateScript({ [System.IO.Path]::IsPathFullyQualified($_) })][string]$RepoRoot,
    [ValidateRange(1, [int]::MaxValue)][int]$ControllerPid
)

$startTick = [Environment]::TickCount64
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$env:YURUNA_NONINTERACTIVE = '1'
$ConfirmPreference = 'None'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$exitCode = 1
try {
    Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force -DisableNameChecking
    $modulesDir = Join-Path $PSScriptRoot '../modules'
    # The source update calls the pull a cycle calls, which only the Outer
    # set loads; every other step keeps the outer loop's kills out.
    if ($Step -eq 'update_source') { Initialize-YurunaEntryPointModuleSet -For Outer -ModulesDir $modulesDir }
    Initialize-YurunaEntryPointModuleSet -For HostUpdate -ModulesDir $modulesDir
    Import-Module (Join-Path $modulesDir 'Test.HostUpdateStep.psm1') -Global -Force -DisableNameChecking
    $stepArgs = @{ Step = $Step; RequestId = $RequestId; Attempt = $Attempt; ResultPath = $ResultPath; RepoRoot = $RepoRoot; StartTickMs = $startTick }
    if ($PSBoundParameters.ContainsKey('ControllerPid')) { $stepArgs.ControllerPid = $ControllerPid }
    $exitCode = Get-HostUpdateStepExitCode -Result (Invoke-HostUpdateStep @stepArgs)
} catch {
    [Console]::Error.WriteLine("yuruna-host-update-step: event=step-failed step=$Step type=$($_.Exception.GetType().Name)")
    $exitCode = 1
}
exit $exitCode
