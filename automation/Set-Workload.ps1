<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42d4e5f6-a7b8-4c90-1234-5d6e7f809102
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
    A developer toolset for cross-cloud Kubernetes-based applications - Deploy workloads.

    .DESCRIPTION
    Deploy workloads using Helm as helper.

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
    C:\PS> Set-Workload.ps1 website localhost
    Deploy workloads using Helm as helper.

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

# Pre-flight check: delegate to Test-Runtime.ps1
$testRuntimeScript = Join-Path -Path $PSScriptRoot -ChildPath "Test-Runtime.ps1"
$runtimeOk = & $testRuntimeScript -logLevel $logLevel
if (-not $runtimeOk) {
    return $false
}

# Resolve yuruna/project/config roots (+ Env:) before evicting Yuruna.* -- the resolver
# lives in the Yuruna.LogLevel leaf imported above, which the eviction then sweeps up.
$roots = Resolve-YurunaRootSet -ScriptRoot $PSScriptRoot -ProjectRoot $project_root -ConfigSubfolder $config_subfolder
if (-not $roots) { return $false }
$yuruna_root = $roots.YurunaRoot
$project_root = $roots.ProjectRoot
Get-Module Yuruna.* | Remove-Module *>&1 | Write-Verbose
$workloadsModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Workload.psm1"
Import-Module -Name $workloadsModulePath -Force

$transcriptFileName = [System.IO.Path]::GetTempFileName()
$null = Start-Transcript $transcriptFileName

$result = Publish-WorkloadList $project_root $config_subfolder

$null = Stop-Transcript
Complete-YurunaRun -Result $result -TranscriptFile $transcriptFileName
