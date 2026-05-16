<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42b2c3d4-e5f6-4a78-9012-3b4c5d6e7f80
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
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
$resourcesModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Resource.psm1"
Import-Module -Name $resourcesModulePath -Force

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

$result = Publish-ResourceList $project_root $config_subfolder

$null = Stop-Transcript
if (-Not $result) {
    Write-Output $result
    Write-Output $(Get-Content -Path $transcriptFileName)
    # Propagate the failure as a non-zero process exit so bash wrappers
    # using `set -e` (e.g. ubuntu.server.workload.k8s.website.sh) see it.
    # Without this, Publish-ResourceList returning $false would print the
    # transcript but exit 0, and the wrapper would march into a later
    # `kubectl wait` that times out -- losing the deploy-time error.
    exit 1
}
else {
    Write-Debug "`n-- See transcript with command: Write-Output `$(Get-Content -Path $transcriptFileName)"
}
