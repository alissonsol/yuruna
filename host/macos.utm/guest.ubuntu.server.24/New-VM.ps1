<#PSScriptInfo
.VERSION 2026.09.30
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
    Uses the Server live ISO. The Server ISO's cdrom has linux-generic
    and a network-configured ubuntu.sources, so subiquity's
    install_kernel step always succeeds. First boot lands at the
    text-mode login prompt; the test harness's Test-Start sequence
    drives that prompt directly.
#>

param(
    [string]$VMName = "ubuntu-server01",
    # Forwarded by the test harness (Start-TestRunner -> Invoke-NewVM) so
    # every guest in a run agrees on a single caching-proxy service URL. When bound
    # (even to ""), the local subnet probe is skipped and this value is
    # used verbatim: "" means "no cache, go direct"; a URL means "use this".
    # When NOT bound (standalone / manual run), fall back to the probe below.
    [string]$CachingProxyServiceUrl,
    # OS user created by autoinstall and exercised by the test
    # sequences. See host/windows.hyper-v/guest.ubuntu.server.24/New-VM.ps1
    # for the rationale on the 'yuuser24' default name.
    [string]$Username = 'yuuser24',
    # cloud-init local-hostname for the guest. Empty means "follow the VM
    # name", which keeps host-side lookups that assume hostname == VM name
    # working for every caller that does not ask for a specific hostname.
    [string]$Hostname = '',
    # Planner-cascaded VM memory (variables.memoryStartupBytes). Raw byte count
    # or a KB/MB/GB suffix (e.g. 34359738368, 32768MB, 32GB); converted to the
    # MB the UTM plist wants. Empty keeps the 12 GB default below.
    [string]$MemoryStartupBytes = '',
    # Planner-cascaded vCPU count (variables.cores). Overrules the default
    # calculation below. Empty keeps the default. Clamped to the host cores.
    [string]$Cores = ''
)

$arguments = @{} + $PSBoundParameters
$arguments.Username = $Username
& (Join-Path $PSScriptRoot '../modules/New-UbuntuServerVM.ps1') @arguments -Release '24' -GuestScriptRoot $PSScriptRoot
exit $LASTEXITCODE
