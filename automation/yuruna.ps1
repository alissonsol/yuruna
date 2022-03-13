<#PSScriptInfo
.VERSION 0.1
.GUID 06e8bceb-f7aa-47e8-a633-1fc36173d278
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2020-2022 Alisson Sol et al.
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
    A developer toolset for cross-cloud Kubernetes-based applications.

    .DESCRIPTION
    A developer toolset for cross-cloud Kubernetes-based applications.

    .PARAMETER operation
    Valid operations: resources, components, workloads, validate, requirements, clear.

    .PARAMETER project_root
    Base folder for the operations.

    .PARAMETER config_subfolder
    Configuration subfolder.

    .PARAMETER debug_mode
    Set to $true to see debug messages.

    .PARAMETER verbose_mode
    Set to $true to see verbose messages.

    .INPUTS
    Template files.

    .OUTPUTS
    Helper application output.

    .EXAMPLE
    C:\PS> ./yuruna.ps1 resources ../examples/website localhost
    Deploys resources using Terraform as helper.

    .EXAMPLE
    C:\PS> ./yuruna.ps1 resources ../examples/website localhost
    Build and push components to registry.

    .EXAMPLE
    C:\PS> ./yuruna.ps1 resources ../examples/website localhost
    Deploy workloads using Helm as helper.

    .LINK
    Online version: http://www.yuruna.com
#>

param (
    [string]$operation=$null,
    [string]$project_root=$null,
    [string]$config_subfolder=$null,
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
$clearModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/yuruna-clear"
$validationModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/yuruna-validation"
$resourcesModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/yuruna-resources"
$componentsModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/yuruna-components"
$workloadsModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/yuruna-workloads"
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
        Write-Output "yuruna resources [project_root] [config_subfolder]`n    Deploys resources using Terraform as helper.";
        Write-Output "yuruna components [project_root] [config_subfolder]`n    Build and push components to registry.";
        Write-Output "yuruna workloads [project_root] [config_subfolder]`n    Deploy workloads using Helm as helper.";
    }
}

$null = Stop-Transcript
if (-Not $result) {
    Write-Output $result
    Write-Output $(Get-Content -Path $transcriptFileName)
}
else {
    Write-Debug "`n-- See transcript with command: Write-Output `$(Get-Content -Path $transcriptFileName)"
}
