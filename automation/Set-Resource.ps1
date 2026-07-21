<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42b2c3d4-e5f6-4a78-9012-3b4c5d6e7f80
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
    A developer toolset for cross-cloud Kubernetes-based applications - Deploy resources.

    .DESCRIPTION
    Deploy resources using OpenTofu as helper.

    .PARAMETER project_root
    Base folder for the operations.

    .PARAMETER config_subfolder
    Configuration subfolder.

    .PARAMETER logLevel
    One of Error|Warning|Information|Verbose|Debug. Each level shows
    itself + all higher-priority streams (Error highest). Default 'Error'.

    .INPUTS
    Template files.

    .OUTPUTS
    Helper application output.

    .EXAMPLE
    C:\PS> Set-Resource.ps1 website localhost
    Deploy resources using OpenTofu as helper.

    .LINK
    Online version: https://yuruna.com
#>

param (
    [string]$project_root=$null,
    [string]$config_subfolder=$null,
    [ValidateSet('Error','Warning','Information','Verbose','Debug', IgnoreCase = $true)]
    [string]$logLevel='Error'
)

# logLevel cascade: shared by every automation entrypoint (see Yuruna.LogLevel.psm1).
Import-Module (Join-Path $PSScriptRoot 'Yuruna.LogLevel.psm1') -Global -Force
Set-YurunaLogLevel -LogLevel $logLevel

# Resolve yuruna/project/config roots (+ Env:) before evicting Yuruna.* -- the resolver
# lives in the Yuruna.LogLevel leaf imported above, which the eviction then sweeps up.
$roots = Resolve-YurunaRootSet -ScriptRoot $PSScriptRoot -ProjectRoot $project_root -ConfigSubfolder $config_subfolder
if (-not $roots) {
    # `exit 1`, never `return $false`: a bare `return` at script scope leaves the
    # PROCESS exit code at 0, and the guest wrappers run this entrypoint under
    # `set -euo pipefail` -- a zero exit reads as "provisioned" and the sequence
    # marches on. Same contract as Complete-YurunaRun's failure tail.
    Write-Warning "Root resolution failed; no resource was provisioned."
    exit 1
}
$yuruna_root = $roots.YurunaRoot
$project_root = $roots.ProjectRoot
Get-Module Yuruna.* | Remove-Module *>&1 | Write-Verbose
$resourcesModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Resource.psm1"
Import-Module -Name $resourcesModulePath -Force

$transcriptFileName = [System.IO.Path]::GetTempFileName()
$null = Start-Transcript $transcriptFileName

$result = Publish-ResourceList $project_root $config_subfolder

$null = Stop-Transcript
Complete-YurunaRun -Result $result -TranscriptFile $transcriptFileName
