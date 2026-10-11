<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 42d0182d-73ed-4bbd-ba70-035faed23f01
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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
    Creates a libvirt VM that installs Ubuntu Server 26.04 via the
    live-server ISO + subiquity autoinstall.

.DESCRIPTION
    Uses the shared live-server ISO and subiquity autoinstall workflow.
    First login requires changing the expired guest password.
    See https://yuruna.link/42e220c4-0004.
#>

param(
    [string]$VMName = "ubuntu-server01",
    [string]$CachingProxyServiceUrl,
    # Versioned usernames keep release-specific guest logs distinguishable.
    [string]$Username = 'yuuser26',
    # An empty hostname follows the VM name for host-side lookup.
    [string]$Hostname = '',
    # Accept raw bytes or a KB/MB/GB suffix; an empty value keeps the host default.
    # See https://yuruna.link/42fa6f45-0016
    [string]$MemoryStartupBytes = '',
    # An empty core count keeps the host default; explicit values are clamped.
    # See https://yuruna.link/42fa6f45-0015
    [string]$Cores = ''
)

# --- REGION: Create the VM
# See https://yuruna.link/42e220c4-0004
$arguments = @{} + $PSBoundParameters
$arguments.Username = $Username
& (Join-Path $PSScriptRoot '../modules/New-UbuntuServerVM.ps1') @arguments -Release '26' -GuestScriptRoot $PSScriptRoot -EnvironmentErrorKey 'host.operator_5cd00af4f123b6b1'
exit $LASTEXITCODE
