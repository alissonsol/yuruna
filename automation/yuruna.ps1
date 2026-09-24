<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42311ffa-42b0-4315-961e-121394721d42
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

# logLevel cascade: shared by every automation entrypoint (see Yuruna.LogLevel.psm1).
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Yuruna.LogLevel.psm1') -Global -Force
Set-YurunaLogLevel -LogLevel $logLevel

# Resolve yuruna/project/config roots (+ Env:) before evicting Yuruna.* -- the resolver
# lives in the Yuruna.LogLevel leaf imported above, which the eviction then sweeps up.
$roots = Resolve-YurunaRootSet -ScriptRoot $PSScriptRoot -ProjectRoot $project_root -ConfigSubfolder $config_subfolder
if (-not $roots) { return $false }
$yuruna_root = $roots.YurunaRoot
$project_root = $roots.ProjectRoot
# The transcript path is decided here, beside the root set and before the
# Yuruna.* eviction sweeps up the leaf that resolves it. A caller can name
# the file it will read afterwards; see Resolve-YurunaTranscriptPath.
$transcriptFileName = Resolve-YurunaTranscriptPath
Get-Module Yuruna.* | Remove-Module *>&1 | Write-Verbose
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
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_f4f81454232e5a55');
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_26f9c3d0c529d327');
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_bb12775978dc7d56');
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_5b2ea4673a88ff6f');
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_e0765f1e2dfb2c75');
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_8cc3b54d17ecd066');
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
    # Propagate failure as a non-zero process exit so a `set -e` shell wrapper sees this
    # dispatcher fail, matching the `exit 1` the Set-Component/Set-Resource/Set-Workload
    # wrappers already emit for the same failure.
    exit 1
}
else {
    Write-Debug "`n-- See transcript with command: Write-Output `$(Get-Content -Path $transcriptFileName)"
}
