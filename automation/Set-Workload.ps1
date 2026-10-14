<#PSScriptInfo
.VERSION 2026.10.14
.GUID 42a7b68b-0145-4180-9461-1dd7c9bbb69a
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

# --- REGION: Log level
# See https://yuruna.link/42e220c4-0019
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Yuruna.LogLevel.psm1') -Global -Force
Set-YurunaLogLevel -LogLevel $logLevel

# --- REGION: Check runtime
# See https://yuruna.link/42e220c4-0019
$testRuntimeScript = Join-Path -Path $PSScriptRoot -ChildPath "Test-Runtime.ps1"
$runtimeOutput = @(& $testRuntimeScript -logLevel $logLevel)
$runtimeOk = ($runtimeOutput.Count -gt 0) -and ($runtimeOutput[-1] -is [bool]) -and $runtimeOutput[-1]
if (-not $runtimeOk) {
    # A missing prerequisite must return a nonzero process exit.
    Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_acfdc6c69e5739b9')
    exit 1
}

# --- REGION: Resolve roots
# See https://yuruna.link/42e220c4-0019
$roots = Resolve-YurunaRootSet -ScriptRoot $PSScriptRoot -ProjectRoot $project_root -ConfigSubfolder $config_subfolder
if (-not $roots) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_19fa10611ea08e8b')
    exit 1
}
$yuruna_root = $roots.YurunaRoot
$project_root = $roots.ProjectRoot
# --- REGION: Transcript path
# See https://yuruna.link/42e220c4-0019
$transcriptFileName = Resolve-YurunaTranscriptPath
# --- REGION: Import operation modules
Get-Module Yuruna.* | Remove-Module *>&1 | Write-Verbose
$workloadsModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Workload.psm1"
Import-Module -Name $workloadsModulePath -Force

# --- REGION: Start transcript
$null = Start-Transcript $transcriptFileName

# --- REGION: Run operation
$result = Publish-WorkloadList $project_root $config_subfolder

# --- REGION: Stop transcript
$null = Stop-Transcript

# --- REGION: Completion
Complete-YurunaRun -Result $result -TranscriptFile $transcriptFileName
