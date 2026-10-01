<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42f12da2-1112-4de8-b565-c97a7434c2c2
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
    Creates a libvirt VM that installs Ubuntu Server 24.04 via the
    live-server ISO + subiquity autoinstall.

.DESCRIPTION
    Mirrors host/macos.utm/guest.ubuntu.server.24/New-VM.ps1 and
    host/windows.hyper-v/guest.ubuntu.server.24/New-VM.ps1 so all three
    hosts run the same boot sequence: GRUB -> "Continue with autoinstall?"
    confirmation -> subiquity unattended install -> reboot -> text-mode
    login prompt with an EXPIRED `password` so the harness's first login
    triggers the current/new/retype dialog.

    Workflow:
      1. Build seed.iso from host/vmconfig/ubuntu.server.base.user-data + meta-data (CIDATA volume).
         Subiquity scans CD/DVD drives for cidata at boot and consumes the
         autoinstall config from there.
      2. Create a fresh empty 64 G qcow2 disk -- subiquity installs onto it.
      3. virt-install with two CDs (live-server ISO + cidata seed) plus
         the empty install-target qcow2; --noautoconsole because the
         harness's Restart-VMConsole launches virt-viewer separately
         (and detached, so the harness pipe still EOFs cleanly).

    The pre-baked Ubuntu cloud image (.img, qcow2-format) + NoCloud
    cloud-init seed is deliberately NOT used: it boots in ~30s but
    DOES NOT show the "Continue with autoinstall?" prompt, does not run
    subiquity's late-commands, and lands at the login prompt without
    expiring the password -- making the GUI test sequence's first three
    steps non-comparable across hosts. The live-server flow is slower
    (~5-10 min install) but produces the same boot sequence and end
    state as macos.utm and hyper-v.
#>

param(
    [string]$VMName = "ubuntu-server01",
    [string]$CachingProxyServiceUrl,
    # OS user created by autoinstall and exercised by the test
    # sequences. Default 'yuuser24' chosen for greppability (vs the
    # cloud-image default 'ubuntu', which collides with anything Ubuntu)
    # and version-tagged so 24.04 and 26.04 guests don't collide in
    # shared logs.
    [string]$Username = 'yuuser24',
    # cloud-init local-hostname for the guest. Empty means "follow the VM
    # name", which keeps host-side lookups that assume hostname == VM name
    # working for every caller that does not ask for a specific hostname.
    [string]$Hostname = '',
    # Planner-cascaded VM memory (variables.memoryStartupBytes). Raw byte count
    # or a KB/MB/GB suffix (e.g. 34359738368, 32768MB, 32GB); converted to the
    # MB virt-install wants. Empty keeps the 8 GB default below.
    [string]$MemoryStartupBytes = '',
    # Planner-cascaded vCPU count (variables.cores). Overrules the default
    # calculation below. Empty keeps the default. Clamped to the host cores.
    [string]$Cores = ''
)

$arguments = @{} + $PSBoundParameters
$arguments.Username = $Username
& (Join-Path $PSScriptRoot '../modules/New-UbuntuServerVM.ps1') @arguments -Release '24' -GuestScriptRoot $PSScriptRoot -EnvironmentErrorKey 'host.operator_5b90e07df6e150e7'
exit $LASTEXITCODE
