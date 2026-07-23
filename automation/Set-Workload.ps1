<#PSScriptInfo
.VERSION 2026.07.22
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

# Pre-flight check: delegate to Test-Runtime.ps1.
#
# Test-Runtime streams its docker images / containers tables to stdout on the
# healthy path, so the capture is a collection whose LAST element is the script's
# [bool] verdict. Test the collection itself and any stdout line at all reads as a
# pass -- which holds today only because the failing path happens to print nothing
# there, an accident one added diagnostic line would silently take away.
$testRuntimeScript = Join-Path -Path $PSScriptRoot -ChildPath "Test-Runtime.ps1"
$runtimeOutput = @(& $testRuntimeScript -logLevel $logLevel)
$runtimeOk = ($runtimeOutput.Count -gt 0) -and ($runtimeOutput[-1] -is [bool]) -and $runtimeOutput[-1]
if (-not $runtimeOk) {
    # `exit 1`, never `return $false`: a bare `return` at script scope leaves the
    # PROCESS exit code at 0. The guest wrappers run this entrypoint under
    # `set -euo pipefail`, so a zero exit reads as "deployed" -- the sequence marches
    # on and the real fault surfaces minutes later, in a different step, as an
    # unreachable endpoint. Same contract as Complete-YurunaRun's failure tail.
    Write-Warning "Runtime pre-flight failed; no workload was deployed."
    exit 1
}

# Resolve yuruna/project/config roots (+ Env:) before evicting Yuruna.* -- the resolver
# lives in the Yuruna.LogLevel leaf imported above, which the eviction then sweeps up.
$roots = Resolve-YurunaRootSet -ScriptRoot $PSScriptRoot -ProjectRoot $project_root -ConfigSubfolder $config_subfolder
if (-not $roots) {
    Write-Warning "Root resolution failed; no workload was deployed."
    exit 1
}
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
