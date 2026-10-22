<#PSScriptInfo
.VERSION 2026.10.22
.GUID 424987be-221a-49fe-a0ac-06e90a13e1b0
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
    Creates a Hyper-V VM that installs Ubuntu Server 26.04 in text mode.

.DESCRIPTION
    Uses the Server live ISO. The Server ISO's cdrom has linux-generic
    and a network-configured ubuntu.sources, so subiquity's
    install_kernel step always succeeds. First boot lands at the
    text-mode login prompt; the test harness's Test-Start sequence
    drives that prompt directly.
#>

param(
    [string]$VMName = "ubuntu-server01",
    # A bound URL, including empty for direct fetching, overrides discovery.
    # See https://yuruna.link/42e220c4-0004
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
    [string]$Cores = '',
    # Nested virtualization is opt-in and requires an AMD64 Hyper-V host.
    # See https://yuruna.link/42e220c4-0004
    [string]$ExposeVirtualizationExtensions = ''
)

# --- REGION: Create the VM
# See https://yuruna.link/42e220c4-0004
$arguments = @{} + $PSBoundParameters
$arguments.Username = $Username
& (Join-Path $PSScriptRoot '../modules/New-UbuntuServerVM.ps1') @arguments -Release '26' -GuestScriptRoot $PSScriptRoot
exit $LASTEXITCODE
