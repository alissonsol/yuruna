<#PSScriptInfo
.VERSION 2026.06.30
.GUID 42a1b2c3-d4e5-4f67-8901-2a3b4c5d6e7f
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
    A developer toolset for cross-cloud Kubernetes-based applications.

    .DESCRIPTION
    A developer toolset for cross-cloud Kubernetes-based applications.

    .PARAMETER operation
    Valid operations: resources, components, workloads, validate, requirements, clear.

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
    C:\PS> yuruna.ps1 resources website localhost
    Deploys resources using OpenTofu as helper.

    .EXAMPLE
    C:\PS> yuruna.ps1 components website localhost
    Build and push components to registry.

    .EXAMPLE
    C:\PS> yuruna.ps1 workloads website localhost
    Deploy workloads using Helm as helper.

    .LINK
    Online version: https://yuruna.com
#>

param (
    [string]$operation=$null,
    [string]$project_root=$null,
    [string]$config_subfolder=$null,
    [ValidateSet('Error','Warning','Information','Verbose','Debug', IgnoreCase = $true)]
    [string]$logLevel='Error'
)

# logLevel cascade -- see Invoke-Clear.ps1 for rationale.
$_logRank = @{ Error=1; Warning=2; Information=3; Verbose=4; Debug=5 }
$_logEff  = $_logRank[$logLevel]
$global:WarningPreference     = if ($_logRank.Warning     -le $_logEff) { 'Continue' } else { 'SilentlyContinue' }
$global:InformationPreference = if ($_logRank.Information -le $_logEff) { 'Continue' } else { 'SilentlyContinue' }
$global:VerbosePreference     = if ($_logRank.Verbose     -le $_logEff) { 'Continue' } else { 'SilentlyContinue' }
$global:DebugPreference       = if ($_logRank.Debug       -le $_logEff) { 'Continue' } else { 'SilentlyContinue' }

$yuruna_root = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")
Set-Item -Path Env:yuruna_root -Value ${yuruna_root}
Write-Debug "yuruna_root is $yuruna_root"
Get-Module | Remove-Module *>&1 | Write-Verbose
$requirementsModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Requirement.psm1"
$clearModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Clear.psm1"
$validationModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Validation.psm1"
$resourcesModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Resource.psm1"
$componentsModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Component.psm1"
$workloadsModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Workload.psm1"
Import-Module -Name $requirementsModulePath -Force
Import-Module -Name $clearModulePath -Force
Import-Module -Name $validationModulePath -Force
Import-Module -Name $resourcesModulePath -Force
Import-Module -Name $componentsModulePath -Force
Import-Module -Name $workloadsModulePath -Force

if ([string]::IsNullOrEmpty($project_root)) { $project_root = Get-Location; }
$resolved_root = Resolve-Path -Path $project_root -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($resolved_root)) { Write-Information "Project folder not found: $project_root"; return $false; }
$project_root = $resolved_root
Set-Item -Path Env:project_root -Value ${project_root}
Write-Debug "project_root is $project_root"

$config_relative = Join-Path -Path $project_root -ChildPath "config/$config_subfolder"
$config_root = Resolve-Path -Path $config_relative -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($config_root)) { Write-Information "Configuration folder not found: $config_relative"; return $false; }
Set-Item -Path Env:config_root -Value ${config_root}
Write-Debug "config_root is $config_root"

$transcriptFileName = [System.IO.Path]::GetTempFileName()
$null = Start-Transcript $transcriptFileName

$result = $false
switch -Exact ($operation)
{
    'requirements' { $result = Confirm-RequirementList }
    'clear' { $result = Clear-Configuration $project_root $config_subfolder }
    'validate' { $result = Confirm-Configuration $project_root $config_subfolder }
    'resources' { $result = Publish-ResourceList $project_root $config_subfolder }
    'components' { $result = Publish-ComponentList $project_root $config_subfolder }
    'workloads' { $result = Publish-WorkloadList $project_root $config_subfolder }
    Default {
        Write-Output "yuruna requirements`n    Check if machine has all requirements.";
        Write-Output "yuruna clear [project_root] [config_subfolder]`n    Clear resources for given configuration.";
        Write-Output "yuruna validate [project_root] [config_subfolder]`n    Validate configuration files.";
        Write-Output "yuruna resources [project_root] [config_subfolder]`n    Deploys resources using OpenTofu as helper.";
        Write-Output "yuruna components [project_root] [config_subfolder]`n    Build and push components to registry.";
        Write-Output "yuruna workloads [project_root] [config_subfolder]`n    Deploy workloads using Helm as helper.";
    }
}

$null = Stop-Transcript
# Publish-Resource/Component/WorkloadList return a result-manifest
# hashtable; the other operations still return a bare [bool]. Probe the
# type before reading .success.
$isOk = $false
if ($result -is [hashtable] -or $result -is [System.Collections.IDictionary]) {
    $isOk = (Test-YurunaResultManifestOk $result)
}
else {
    $isOk = [bool]$result
}
if (-Not $isOk) {
    if ($result -is [hashtable] -or $result -is [System.Collections.IDictionary]) {
        Write-Output ($result | ConvertTo-Json -Depth 4 -Compress)
    }
    else {
        Write-Output $result
    }
    Write-Output $(Get-Content -Path $transcriptFileName)
}
else {
    Write-Debug "`n-- See transcript with command: Write-Output `$(Get-Content -Path $transcriptFileName)"
}
