<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 429746c7-cf5b-4f84-8ccd-0d7f99927afa
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

# --- REGION: Log level
# See https://yuruna.link/42e220c4-0019
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Yuruna.LogLevel.psm1') -Global -Force
Set-YurunaLogLevel -LogLevel $logLevel

# --- REGION: Resolve roots
# See https://yuruna.link/42e220c4-0019
$roots = Resolve-YurunaRootSet -ScriptRoot $PSScriptRoot -ProjectRoot $project_root -ConfigSubfolder $config_subfolder
if (-not $roots) {
    # A missing prerequisite must return a nonzero process exit.
    Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_36db573bfe1ac885')
    exit 1
}
$yuruna_root = $roots.YurunaRoot
$project_root = $roots.ProjectRoot
# --- REGION: Transcript path
# See https://yuruna.link/42e220c4-0019
$transcriptFileName = Resolve-YurunaTranscriptPath
# --- REGION: Import operation modules
Get-Module Yuruna.* | Remove-Module *>&1 | Write-Verbose
$resourcesModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Resource.psm1"
Import-Module -Name $resourcesModulePath -Force

# --- REGION: Start transcript
$null = Start-Transcript $transcriptFileName

# --- REGION: Run operation
$result = Publish-ResourceList $project_root $config_subfolder

# --- REGION: Stop transcript
$null = Stop-Transcript

# --- REGION: Completion
Complete-YurunaRun -Result $result -TranscriptFile $transcriptFileName
