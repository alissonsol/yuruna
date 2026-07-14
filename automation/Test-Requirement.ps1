<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42e5f6a7-b8c9-4d01-2345-6e7f80910213
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
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

    .PARAMETER logLevel
    One of Error|Warning|Information|Verbose|Debug. Each level shows
    itself + all higher-priority streams (Error highest). Default 'Error'.

    .INPUTS
    None.

    .OUTPUTS
    Requirements verification output.

    .EXAMPLE
    C:\PS> Test-Requirement.ps1
    Check if machine has all requirements.

    .LINK
    Online version: https://yuruna.com
#>

param (
    [ValidateSet('Error','Warning','Information','Verbose','Debug', IgnoreCase = $true)]
    [string]$logLevel='Error'
)

# logLevel cascade: shared by every automation entrypoint (see Yuruna.LogLevel.psm1).
Import-Module (Join-Path $PSScriptRoot 'Yuruna.LogLevel.psm1') -Global -Force
Set-YurunaLogLevel -LogLevel $logLevel

$yuruna_root = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")
Set-Item -Path Env:yuruna_root -Value ${yuruna_root}
Write-Debug "yuruna_root is $yuruna_root"
Get-Module Yuruna.* | Remove-Module *>&1 | Write-Verbose
$requirementsModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Requirement.psm1"
Import-Module -Name $requirementsModulePath -Force

$transcriptFileName = [System.IO.Path]::GetTempFileName()
$null = Start-Transcript $transcriptFileName

$result = Confirm-RequirementList

$null = Stop-Transcript
if (-Not $result) {
    Write-Output $result
    Write-Output $(Get-Content -Path $transcriptFileName)
    # Propagate the failure as a non-zero process exit so bash `set -e` wrappers see a
    # Confirm-RequirementList failure -- matching `yuruna.ps1 requirements` (its bool tail exits 1).
    exit 1
}
else {
    Write-Debug "`n-- See transcript with command: Write-Output `$(Get-Content -Path $transcriptFileName)"
}
