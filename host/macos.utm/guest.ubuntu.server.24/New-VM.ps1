<#PSScriptInfo
.VERSION 2026.10.11
.GUID 42398c5e-c859-4bdc-9114-f9b19317cd8b
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
    Creates a UTM VM that installs Ubuntu Server 24.04 unattended.

.DESCRIPTION
    Uses the shared live-server ISO and subiquity autoinstall workflow.
    First login requires changing the expired guest password.
    See https://yuruna.link/42e220c4-0004.
#>

param(
    [string]$VMName = "ubuntu-server01",
    # A bound URL, including empty for direct fetching, overrides discovery.
    # See https://yuruna.link/42e220c4-0004
    [string]$CachingProxyServiceUrl,
    # Versioned usernames keep release-specific guest logs distinguishable.
    [string]$Username = 'yuuser24',
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
& (Join-Path $PSScriptRoot '../modules/New-UbuntuServerVM.ps1') @arguments -Release '24' -GuestScriptRoot $PSScriptRoot
exit $LASTEXITCODE
