<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42040d67-5b20-4d5c-a82c-4a95c2371f44
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host ubuntu kvm pool config
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
    Copies another pool host's test.config.yml onto this Ubuntu KVM host.

.DESCRIPTION
    Copies and converts the reference host's configuration, preserving local
    secrets and populated mount paths. Reconciles host aliases and vault
    credentials, writes an atomic backup, and validates the result.
    See https://yuruna.link/428405a0-0011 for platform and elevation details.

.PARAMETER ReferenceHost
    Network name or IP address of the host to copy from. Any host type
    (macos.utm / ubuntu.kvm / windows.hyper-v).

.PARAMETER StatusPort
    The reference host's status-service port. Default 8080.

.PARAMETER InternalAuthKey
    The internal authentication key used to fetch missing vault credentials.
    Defaults to this host's own vault copy when configured; an interactive
    session prompts as the last resort.

.PARAMETER NonInteractive
    Never prompt; skip anything that would need operator input, with a
    warning.

.PARAMETER SkipValidation
    Skip the final test/Test-Config.ps1 run.

.PARAMETER NoPool
    Sync the reference config but do NOT join the pool: the pool + networkStorage
    nodes are dropped, so this host never mounts the NAS, replicates cycles, or
    registers in the pool set. The caching-proxy service + repository settings still come
    across (cache reuse is unaffected). For disposable / self-verification hosts.

.EXAMPLE
    ./Sync-HostConfiguration.ps1 -ReferenceHost 192.168.7.64
    ./Sync-HostConfiguration.ps1 -ReferenceHost alius202607a1 -WhatIf
    ./Sync-HostConfiguration.ps1 -ReferenceHost 192.168.7.64 -NoPool   # borrow config, don't join the pool
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', 'InternalAuthKey',
    Justification = 'The internal authentication key is handled as the plaintext vault stores it; only its HMAC proof crosses the wire.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$ReferenceHost,

    [Parameter()][int]$StatusPort = 8080,
    [Parameter()][Alias('SharedToken')][string]$InternalAuthKey = '',
    [switch]$NonInteractive,
    [switch]$SkipValidation,
    [switch]$NoPool,
    [switch]$AllowStaleReference,
    [switch]$RequireReferenceCredential
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
# Sync-HostConfiguration narrates each decision (kept local path, added
# alias, stored credential) via Write-Information; without Continue the
# operator sees none of it.
$InformationPreference = 'Continue'

# --- REGION: Platform guard
if (-not $IsLinux) {
    throw (Format-YurunaOperatorMessage -Key 'exceptions.host_1568d9e12a12e190')
}

# --- REGION: Elevation notice
# Announce conditional privileged writes without requesting unused credentials.
if (-not $NoPool -and -not $NonInteractive -and -not $WhatIfPreference) {
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_0a29da20e90b72f2')
}

# --- REGION: Initialize host setup
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.HostSetup.psm1') -Force
# Only the ShouldProcess switches may reach the bootstrap: its
# -BoundParameters is splatted onto the Install-* helpers, which reject
# this script's own parameters.
$bootstrapParams = @{}
foreach ($k in @('WhatIf', 'Confirm')) {
    if ($PSBoundParameters.ContainsKey($k)) { $bootstrapParams[$k] = $PSBoundParameters[$k] }
}
Initialize-HostSetupModule -RepoRoot $RepoRoot -BoundParameters $bootstrapParams

# --- REGION: Synchronize host configuration
Import-Module (Join-Path $RepoRoot 'test/modules/Test.ConfigServiceSync.psm1') -Force -DisableNameChecking

Sync-HostConfiguration -ReferenceHost $ReferenceHost -StatusPort $StatusPort -RepoRoot $RepoRoot `
    -InternalAuthKey $InternalAuthKey -NonInteractive:$NonInteractive -SkipValidation:$SkipValidation -NoPool:$NoPool `
    -AllowStaleReference:$AllowStaleReference -RequireReferenceCredential:$RequireReferenceCredential

# --- REGION: Guest address-discovery readiness
# Which of this driver's discovery rungs can answer AT ALL is decided by host
# configuration, not by the harness: the lease rung needs libvirt to be the DHCP
# server for the guest network, and the agent rung needs qemu-guest-agent inside
# the guest. When both are structurally silent, discovery rests entirely on a
# passive read of the host neighbor cache -- which decays, so lookups start
# missing intermittently, and a miss surfaces to the operator as an ssh
# name-resolution error that says nothing about any of this.
#
# Reporting it here turns that from something diagnosed across many failed
# cycles into a line of setup output.
Write-Output ''
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_fc3a019bfe08955e')
$networkName = ''
try {
    Import-Module (Join-Path $RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop
    $networkName = [string](Get-ExternalNetwork)
} catch {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_99da1a0d2e9fb034' -Arguments @{ message = "$($_.Exception.Message)" })
}
if ($networkName) {
    $netXml = (& virsh --connect qemu:///system net-dumpxml $networkName 2>&1) -join "`n"
    $isNat  = ($netXml -match '<dhcp>')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_4551eef5e24cf289' -Arguments @{ networkName = "$networkName" })
    if ($isNat) {
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_448cdaf2e660e77c')
    } else {
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_56ba8d186d33f488')
    }
    $seed = Join-Path $RepoRoot 'host/vmconfig/ubuntu.server.kvm.overlay.yml'
    # "attempted", not "available". The seed installs the agent from a
    # failure-tolerant late command, so its presence here says the build TRIES,
    # not that this guest ended up with it -- and reporting a rung as available
    # when it may be silent is the failure this whole section exists to prevent.
    # Only the guest itself can settle it: virsh domifaddr --source agent.
    $hasAgent = (Test-Path -LiteralPath $seed) -and ((Get-Content -LiteralPath $seed -Raw) -match 'qemu-guest-agent')
    if ($hasAgent) {
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_f0fd9838eca3f370')
    } else {
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_68ed859cee56ba19')
    }
    # Get-HostIpv4Prefix is module-private, so it has to be invoked inside the
    # driver's own scope. Called bare from here it raises CommandNotFound, the
    # catch swallows it, and the report claims the refresh rung is unavailable on
    # every host -- the one line of this whole section that would always lie.
    $prefix = $null
    try {
        $driverModule = Get-Module Yuruna.Host
        if ($driverModule) { $prefix = & $driverModule { Get-HostIpv4Prefix } }
    } catch { $prefix = $null }
    if ($prefix) {
        $sweep = if ($prefix.Length -ge 24) { 'available' } else { "REFUSED -- /$($prefix.Length) is wider than /24" }
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_41899d644a8d91fb' -Arguments @{ sweep = "$sweep"; address = "$($prefix.Address)"; length = "$($prefix.Length)" })
    } else {
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_91e92935992072a4')
    }
    if (-not $isNat -and -not $hasAgent) {
        Write-Warning ((Format-YurunaOperatorMessage -Key 'host.operator_d9865efa39e8e674'))
    }
}
