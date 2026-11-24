<#PSScriptInfo
.VERSION 2026.11.23
.GUID 4200c0e5-3caa-4228-ae7d-cbd3cb6ac10c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host-update controller lab
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
    The host controller: claims queued host updates from the request journal
    and runs their phases, continuing after any interruption.
.DESCRIPTION
    Started by the shim (yuruna-host-controller-shim.sh) from a private
    snapshot under the controller root, never from the checkout, and it
    imports only from that snapshot. It reads no network input and parses no
    request body: its only input is a journal row of a closed vocabulary.
.PARAMETER ControllerRoot
    The absolute controller root (the shim's own folder).
.PARAMETER Snapshot
    The 16-hex snapshot this instance runs from.
.PARAMETER Checkout
    The absolute checkout every phase's step child runs from.
.OUTPUTS
    Nothing; the exit code is for the shim:
      75  start me again on the current snapshot (one was staged, or the
          install phase changed PowerShell)
      76  another controller holds the controller lock
      77  run the PowerShell upgrade (Windows)
      1   anything else
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateScript({ [System.IO.Path]::IsPathRooted($_) })][string]$ControllerRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{16}$', Options = 'None')][string]$Snapshot,
    [Parameter(Mandatory)][ValidateScript({ [System.IO.Path]::IsPathRooted($_) })][string]$Checkout
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$env:YURUNA_NONINTERACTIVE = '1'
$ConfirmPreference = 'None'
$exitCode = 1
try {
    Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force -DisableNameChecking
    Initialize-YurunaEntryPointModuleSet -For HostUpdateController -ModulesDir (Join-Path $PSScriptRoot '../modules')
    $exitCode = Invoke-HostUpdateController -ControllerRoot $ControllerRoot -Snapshot $Snapshot -Checkout $Checkout
} catch {
    [Console]::Error.WriteLine("yuruna-host-controller: event=startup-failed type=$($_.Exception.GetType().Name)")
    $exitCode = 1
}
exit $exitCode
