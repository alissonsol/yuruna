<#PSScriptInfo
.VERSION 2026.06.30
.GUID 42c3d4e5-f6a7-4b89-0123-4c5d6e7f8091
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
    A developer toolset for cross-cloud Kubernetes-based applications - Build and publish components.

    .DESCRIPTION
    Build and push components to registry.

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
    C:\PS> Set-Component.ps1 website localhost
    Build and push components to registry.

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
$componentsModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Component.psm1"
Import-Module -Name $componentsModulePath -Force

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

$result = Publish-ComponentList $project_root $config_subfolder

$null = Stop-Transcript
# Publish-ComponentList returns a result-manifest hashtable; a non-empty
# hashtable coerces to $true, so a bare `if (-Not $result)` would silently
# take the success branch on a failure manifest. Test the .success key.
if (-Not (Test-YurunaResultManifestOk $result)) {
    Write-Output ($result | ConvertTo-Json -Depth 4 -Compress)
    Write-Output $(Get-Content -Path $transcriptFileName)
    # Propagate the failure as a non-zero process exit so bash wrappers
    # using `set -e` (e.g. ubuntu.server.24.workload.k8s.website.sh) see it.
    # Without this, Publish-ComponentList reporting failure (e.g. docker
    # build/push failure) would print the transcript but exit 0, and the
    # wrapper would march into Set-Workload with a missing image.
    exit 1
}
else {
    Write-Debug "`n-- See transcript with command: Write-Output `$(Get-Content -Path $transcriptFileName)"
}
