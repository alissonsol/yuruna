<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42e323d2-d7e2-475d-9165-2a5fd9fd9379
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test recovery probe failure-pause
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Say, from a short-lived process, whether the host condition behind a
    failure class has cleared.
.DESCRIPTION
    Run by the failure pause through Invoke-RecoveryProbe (Test.RecoveryProbe),
    never by an operator. It loads the module set and the host driver the cycle
    runs with, asks the same check the cycle used to raise the class, prints one
    line of detail and exits:
      0  the condition has cleared
      1  the condition still holds
      2  the probe could not tell (no such check on this host, or it failed)
.PARAMETER FailureClass
    The class to probe.
.PARAMETER ConfigPath
    The runner configuration; defaults to the resolved canonical path.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('hypervisor_unresponsive', 'host_network_degraded', 'pool_storage_full')][string]$FailureClass,
    [string]$ConfigPath = $null
)
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Prelude.psm1') -Global -Force
    # The level the process that started this one resolved (YURUNA_LOG_LEVEL).
    Import-Module (Join-Path $PSScriptRoot 'Test.LogLevel.psm1') -DisableNameChecking
    Use-LogLevelFromEnv
    $paths = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder -ConfigPath $ConfigPath
    if ($FailureClass -eq 'pool_storage_full') {
        Initialize-YurunaEntryPointModuleSet -For Outer -ModulesDir $paths.ModulesDir
        $space = Test-OuterPoolStorageSpaceReady -ConfigPath $paths.ConfigPath
        Write-Output "pool storage: $(if ($space.ok) { 'room for a cycle' } else { $space.message })"
        exit $(if ($space.ok) { 0 } else { 1 })
    }
    Initialize-YurunaEntryPointModuleSet -For Inner -ModulesDir $paths.ModulesDir
    $hostType = Get-HostType
    [void](Initialize-YurunaHost -RepoRoot $paths.RepoRoot -HostType $hostType)
    if ($FailureClass -eq 'host_network_degraded') {
        $degraded = Test-CycleHostNetworkDegraded
        Write-Output "host network: $(if ($degraded) { 'no usable bridged switch' } else { 'a bridged switch forwards' })"
        exit $(if ($degraded) { 1 } else { 0 })
    }
    # The cycle's control gate where the driver has a lifecycle probe, and the
    # driver's plain responsiveness check everywhere else.
    $gate = Test-RunnerHypervisorControlGate -HostType $hostType -Config (Read-TestConfig -Path $paths.ConfigPath)
    if ($gate.Probed) {
        Write-Output "hypervisor: $($gate.Reason)"
        exit $(if ($gate.Ok) { 0 } else { 1 })
    }
    if (-not (Get-Command -Name Test-VirtualizationResponsive -ErrorAction SilentlyContinue)) {
        Write-Output "hypervisor: no responsiveness check on $hostType"
        exit 2
    }
    $answer = Test-VirtualizationResponsive -TimeoutSeconds 30
    Write-Output "hypervisor: $($answer.state) ($($answer.reason))"
    exit $(switch ([string]$answer.state) { 'Responsive' { 0 } 'Unresponsive' { 1 } default { 2 } })
} catch {
    Write-Output "probe failed: $($_.Exception.Message)"
    exit 2
}
