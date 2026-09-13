<#PSScriptInfo
.VERSION 2026.09.13
.GUID 422b5978-3d42-4072-9818-eeacacbe29ad
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

# logLevel cascade: shared by every automation entrypoint (see Yuruna.LogLevel.psm1).
Import-Module (Join-Path $PSScriptRoot 'Yuruna.LogLevel.psm1') -Global -Force
Set-YurunaLogLevel -LogLevel $logLevel

# Resolve yuruna/project/config roots (+ Env:) before evicting Yuruna.* -- the resolver
# lives in the Yuruna.LogLevel leaf imported above, which the eviction then sweeps up.
$roots = Resolve-YurunaRootSet -ScriptRoot $PSScriptRoot -ProjectRoot $project_root -ConfigSubfolder $config_subfolder
if (-not $roots) {
    # `exit 1`, never `return $false`: a bare `return` at script scope leaves the
    # PROCESS exit code at 0, and the guest wrappers run this entrypoint under
    # `set -euo pipefail` -- a zero exit reads as "built" and the sequence marches
    # on. Same contract as Complete-YurunaRun's failure tail.
    Write-Warning "Root resolution failed; no component was built."
    exit 1
}
$yuruna_root = $roots.YurunaRoot
$project_root = $roots.ProjectRoot
# The transcript path is decided here, beside the root set and before the
# Yuruna.* eviction sweeps up the leaf that resolves it. A caller can name
# the file it will read afterwards; see Resolve-YurunaTranscriptPath.
$transcriptFileName = Resolve-YurunaTranscriptPath
Get-Module Yuruna.* | Remove-Module *>&1 | Write-Verbose
$componentsModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Component.psm1"
Import-Module -Name $componentsModulePath -Force

$null = Start-Transcript $transcriptFileName

$result = Publish-ComponentList $project_root $config_subfolder

$null = Stop-Transcript
Complete-YurunaRun -Result $result -TranscriptFile $transcriptFileName
