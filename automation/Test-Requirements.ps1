<#PSScriptInfo
.VERSION 0.3
.GUID 42e5f6a7-b8c9-4d01-2345-6e7f80910213
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2019-2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
    .SYNOPSIS
    A developer toolset for cross-cloud Kubernetes-based applications - Test requirements.

    .DESCRIPTION
    Check if machine has all requirements.

    .PARAMETER debug_mode
    Set to $true to see debug messages.

    .PARAMETER verbose_mode
    Set to $true to see verbose messages.

    .INPUTS
    None.

    .OUTPUTS
    Requirements verification output.

    .EXAMPLE
    C:\PS> Test-Requirements.ps1
    Check if machine has all requirements.

    .LINK
    Online version: http://www.yuruna.com
#>

param (
    [bool]$debug_mode=$false,
    [bool]$verbose_mode=$false
)

$global:InformationPreference = "Continue"

$global:DebugPreference = "SilentlyContinue"
$global:VerbosePreference = "SilentlyContinue"
if ($true -eq $debug_mode) {
    $global:DebugPreference = "Continue"
}
if ($true -eq $verbose_mode) {
    $global:VerbosePreference = "Continue"
}

$yuruna_root = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")
Set-Item -Path Env:yuruna_root -Value ${yuruna_root}
Write-Debug "yuruna_root is $yuruna_root"
Get-Module | Remove-Module *>&1 | Write-Verbose
$requirementsModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/yuruna-requirements"
Import-Module -Name $requirementsModulePath -Force

$transcriptFileName = [System.IO.Path]::GetTempFileName()
$null = Start-Transcript $transcriptFileName

$result = Confirm-RequirementList

$null = Stop-Transcript
if (-Not $result) {
    Write-Output $result
    Write-Output $(Get-Content -Path $transcriptFileName)
}
else {
    Write-Debug "`n-- See transcript with command: Write-Output `$(Get-Content -Path $transcriptFileName)"
}
