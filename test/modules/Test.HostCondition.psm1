<#PSScriptInfo
.VERSION 2026.05.29
.GUID 42b8c9d0-e1f2-4a34-9567-8f9a0b1c2d31
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host
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

# Cross-platform host-condition facade. Applies AND asserts per-host
# preconditions for unattended VM testing; per-platform implementations
# live in Test.HostCondition.{Mac,Windows}.psm1.
# Architecture (facade contract, retained public exports, Linux stub):
# https://yuruna.link/test/harness

# -Global is required so the facade can re-export sibling function names;
# -DisableNameChecking suppresses singular-noun warnings on predate-rule
# public names.
Import-Module (Join-Path $PSScriptRoot 'Test.HostCondition.Mac.psm1')     -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.HostCondition.Windows.psm1') -Global -Force -DisableNameChecking

function Set-LinuxHostConditionSet {
    <#
    .SYNOPSIS
    Configures Linux/KVM host settings needed for unattended VM testing.
    Today a thin stub that delegates to the operator-facing
    host/ubuntu.kvm/Enable-TestAutomation.ps1 (display-blanking, sudoer
    cache, libvirt group membership). Kept as a symmetric peer to
    Set-MacHostConditionSet and Set-WindowsHostConditionSet so a future
    libvirt-side check (apparmor profile, systemd-resolved bridge DNS,
    KVM kernel module auto-load) has an obvious home and the
    dispatcher table is uniform across the three supported hosts.
    .EXAMPLE
    Set-LinuxHostConditionSet          # apply all settings
    Set-LinuxHostConditionSet -WhatIf  # show what would change without applying
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $IsLinux) {
        Write-Warning "Set-LinuxHostConditionSet is only supported on Linux."
        return
    }
    # No host-side mutations performed at runtime today: the persistent
    # install-time work (libvirt group membership, polkit rules, kernel
    # module load) lives in install/ubuntu.kvm.sh and the operator-
    # facing host/ubuntu.kvm/Enable-TestAutomation.ps1. The runtime
    # readiness checks live in Assert-HostConditionSet's Linux branch
    # (kvm device + libvirtd active + virsh round-trip + group set).
    # Future Linux-side mutations (turn off gnome screen blanking on a
    # GUI host, register a polkit override) land here, each gated by a
    # nested ShouldProcess call mirroring Set-MacHostConditionSet's
    # per-mutation pattern.
    if ($PSCmdlet.ShouldProcess('host.ubuntu.kvm', 'Apply Linux host condition set (no runtime mutations today)')) {
        Write-Verbose "Set-LinuxHostConditionSet: no runtime mutations required (host/ubuntu.kvm/Enable-TestAutomation.ps1 owns install-time setup)."
    }
}

function Assert-HostConditionSet {
    <#
    .SYNOPSIS
    Platform dispatcher: calls Assert-WindowsHostConditionSet or
    Assert-MacHostConditionSet based on the detected host type.
    Returns $true when all platform-specific prerequisites are met.
    #>
    param([string]$HostType)

    if ($HostType -eq "host.windows.hyper-v") {
        return Assert-WindowsHostConditionSet -HostType $HostType
    }
    if ($HostType -eq "host.macos.utm") {
        return Assert-MacHostConditionSet -HostType $HostType
    }
    if ($HostType -eq "host.ubuntu.kvm") {
        # Ubuntu KVM doesn't have macOS-style screen-saver / display-sleep
        # asserts, and elevation isn't a runtime requirement (the harness
        # runs as a libvirt-group user). The real readiness question is:
        # can THIS process reach libvirtd? Assert-Virtualization checks
        # /dev/kvm + libvirtd active + a no-op virsh `list` round-trip.
        # The runner calls Initialize-YurunaHost before invoking this
        # function; that imports Yuruna.Host.psm1 for host.ubuntu.kvm,
        # so Assert-Virtualization is in scope here.
        if (Assert-Virtualization) { return $true }
        # Diagnose: which of the three preconditions failed?
        if (-not (Test-Path -LiteralPath '/dev/kvm')) {
            Write-Error "/dev/kvm character device missing -- kvm.ko not loaded. Try: 'sudo modprobe kvm_intel' (Intel) or 'sudo modprobe kvm_amd' (AMD)."
            return $false
        }
        $active = (& systemctl is-active libvirtd 2>$null).Trim()
        if ($active -ne 'active') {
            Write-Error "libvirtd is not active (state=$active). Try: 'sudo systemctl start libvirtd' and check 'systemctl status libvirtd'."
            return $false
        }
        # libvirtd up, /dev/kvm present, but the round-trip failed -- the
        # by-far most common cause is a stale supplementary group set on
        # the calling shell. Detect that case specifically so the operator
        # gets actionable steps, not a generic "permission denied".
        $activeGroups   = (& id -nG 2>$null) -split '\s+'
        $libvirtLine    = & getent group libvirt 2>$null
        $libvirtMembers = if ($libvirtLine) { (($libvirtLine -split ':',4)[3]) -split ',' } else { @() }
        if ($libvirtMembers -contains $env:USER -and $activeGroups -notcontains 'libvirt') {
            Write-Error @"
Cannot reach libvirtd from this process: '$env:USER' IS in the 'libvirt'
group per /etc/group, but THIS shell's running group set does NOT include
libvirt -- so virt-install and virsh hit 'Permission denied' on the
libvirt socket. A desktop logout/login does NOT always refresh the group
set on systemd-logind systems with user lingering.

Fix (pick one) and re-run Invoke-TestRunner.ps1:
  A. one-off, no logout needed:
       sg libvirt -c 'pwsh ./Invoke-TestRunner.ps1'
  B. this shell only:
       newgrp libvirt
       pwsh ./Invoke-TestRunner.ps1
  C. fully refresh (most reliable):
       sudo reboot
"@
            return $false
        }
        if ($libvirtMembers -notcontains $env:USER) {
            Write-Error "'$env:USER' is not in the 'libvirt' group at all -- re-run install/ubuntu.kvm.sh, or: 'sudo usermod -aG libvirt $env:USER' then log out / back in."
            return $false
        }
        Write-Error "virsh round-trip against libvirtd failed but the usual causes (kvm missing, libvirtd down, stale group set) don't apply. Run 'virsh -c qemu:///system list' manually for the verbatim error."
        return $false
    }

    Write-Warning "Unknown host type '$HostType' -- skipping condition checks."
    return $true
}

Export-ModuleMember -Function Assert-ScreenLock, Initialize-SudoCache, Set-MacHostConditionSet, Set-WindowsHostConditionSet, Set-LinuxHostConditionSet, Assert-Accessibility, Assert-ScreenRecording, Assert-MacHostConditionSet, Assert-WindowsHostConditionSet, Assert-HostConditionSet
