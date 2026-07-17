<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42c5d6e7-f8a9-4b01-9234-5e6f7a8b9c0d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host linux kvm libvirt
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

# Linux / KVM sibling of Test.HostCondition.psm1. Mirrors the per-platform
# layout that Mac and Windows already follow: Set/Assert pair (used by
# the registry dispatcher) plus Test-LinuxHostMinimum (the quick check
# Test-HostRequirement runs from one-off operator helpers). The
# diagnostic logic for Assert lives here, not in the facade, so the
# facade stays pure dispatch and a future libvirt-side check has an
# obvious home.

function Get-LibvirtGroupState {
    <#
    .SYNOPSIS
        Reads the libvirt group picture two callers both need: the
        calling process's RUNNING supplementary group set and the
        libvirt group's membership per /etc/group.
    .DESCRIPTION
        Returns a hashtable with:
          ActiveGroups   -- the running shell's supplementary group set
                            (from `id -nG`); what actually governs socket
                            access, and what a stale `usermod -aG` does
                            NOT refresh.
          LibvirtMembers -- the libvirt group's members per `getent group
                            libvirt`. getent joins members with commas and
                            no spaces; the last token can carry a trailing
                            newline, so each token is trimmed and empties
                            dropped -- otherwise a `-contains $user` test
                            can miss the last, newline-suffixed member.
        The ActiveGroups-vs-LibvirtMembers gap is the classic
        "member in /etc/group but not in the live group set" case that
        makes libvirt-sock return Permission denied until the group set
        is refreshed (sg / newgrp / reboot).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $activeGroups = (& id -nG 2>$null) -split '\s+'
    $libvirtLine  = & getent group libvirt 2>$null
    $libvirtMembers = if ($libvirtLine) {
        (($libvirtLine -split ':', 4)[3]) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    } else { @() }
    return @{
        ActiveGroups   = $activeGroups
        LibvirtMembers = @($libvirtMembers)
    }
}

function Set-LinuxHostConditionSet {
    <#
    .SYNOPSIS
        Configures Linux/KVM host settings needed for unattended VM
        testing. Today a thin stub that delegates to the operator-
        facing host/ubuntu.kvm/Enable-TestAutomation.ps1 (display-
        blanking, sudoer cache, libvirt group membership).
    .DESCRIPTION
        Kept as a symmetric peer to Set-MacHostConditionSet and
        Set-WindowsHostConditionSet so the registry dispatcher in
        Test.HostCondition has a uniform Set callback across all
        three supported hosts.
    .EXAMPLE
        Set-LinuxHostConditionSet          # apply all settings
        Set-LinuxHostConditionSet -WhatIf  # show what would change without applying
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$HostType)
    if (-not $IsLinux) {
        Write-Warning "Set-LinuxHostConditionSet is only supported on Linux."
        return
    }
    # No host-side mutations performed at runtime today: the persistent
    # install-time work (libvirt group membership, polkit rules, kernel
    # module load) lives in install/ubuntu.kvm.sh and the operator-
    # facing host/ubuntu.kvm/Enable-TestAutomation.ps1. The runtime
    # readiness checks live in Assert-LinuxHostConditionSet (kvm device
    # + libvirtd active + virsh round-trip + group set). Future Linux-
    # side mutations (turn off gnome screen blanking on a GUI host,
    # register a polkit override) land here, each gated by a nested
    # ShouldProcess call mirroring Set-MacHostConditionSet's per-
    # mutation pattern.
    $null = $HostType
    if ($PSCmdlet.ShouldProcess('host.ubuntu.kvm', 'Apply Linux host condition set (no runtime mutations today)')) {
        Write-Verbose "Set-LinuxHostConditionSet: no runtime mutations required (host/ubuntu.kvm/Enable-TestAutomation.ps1 owns install-time setup)."
    }
}

function Assert-LinuxHostConditionSet {
    <#
    .SYNOPSIS
        Single gate for Linux / KVM prerequisites: virsh round-trip,
        /dev/kvm character device, libvirtd active, current shell's
        supplementary group set includes libvirt.
    .DESCRIPTION
        Returns $true on non-Linux (the registry only dispatches to
        this for the matching HostType, but the guard keeps the
        function safe to call directly) or when all conditions pass;
        $false with diagnostics on failure. Diagnostics distinguish
        the four common failure modes so the operator gets actionable
        steps, not a generic "permission denied".
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$HostType)
    if ($HostType -ne 'host.ubuntu.kvm') { return $true }
    # The runner calls Initialize-YurunaHost before invoking this
    # function; that imports host/ubuntu.kvm/modules/Yuruna.Host.psm1
    # for host.ubuntu.kvm, so Assert-Virtualization is in scope here.
    if (Get-Command Assert-Virtualization -ErrorAction SilentlyContinue) {
        if (Assert-Virtualization) { return $true }
    }
    # Diagnose: which of the three preconditions failed?
    if (-not (Test-Path -LiteralPath '/dev/kvm')) {
        Write-Error "/dev/kvm character device missing -- kvm.ko not loaded. Try: 'sudo modprobe kvm_intel' (Intel) or 'sudo modprobe kvm_amd' (AMD)."
        return $false
    }
    # Coerce before .Trim(): a missing systemctl / empty output makes (& ...) return $null, and
    # $null.Trim() throws "cannot call a method on a null-valued expression".
    $raw = & systemctl is-active libvirtd 2>$null
    $active = if ($raw) { "$raw".Trim() } else { '' }
    if ($active -ne 'active') {
        Write-Error "libvirtd is not active (state=$active). Try: 'sudo systemctl start libvirtd' and check 'systemctl status libvirtd'."
        return $false
    }
    # libvirtd up, /dev/kvm present, but the round-trip failed -- the
    # by-far most common cause is a stale supplementary group set on
    # the calling shell. Detect that case specifically so the operator
    # gets actionable steps, not a generic "permission denied".
    $groupState     = Get-LibvirtGroupState
    $activeGroups   = $groupState.ActiveGroups
    $libvirtMembers = $groupState.LibvirtMembers
    # Use the process's REAL identity, not $env:USER: under sg/newgrp/sudo/systemd
    # the inherited USER can be empty or wrong, which would select the wrong
    # remediation branch -- the opposite of the actionable diagnostics intended.
    $me = (& id -un 2>$null); if (-not $me) { $me = $env:USER }
    $me = ([string]$me).Trim()
    if ($libvirtMembers -contains $me -and $activeGroups -notcontains 'libvirt') {
        Write-Error @"
Cannot reach libvirtd from this process: '$me' IS in the 'libvirt'
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
    if ($libvirtMembers -notcontains $me) {
        Write-Error "'$me' is not in the 'libvirt' group at all -- re-run install/ubuntu.kvm.sh, or: 'sudo usermod -aG libvirt $me' then log out / back in."
        return $false
    }
    Write-Error "virsh round-trip against libvirtd failed but the usual causes (kvm missing, libvirtd down, stale group set) don't apply. Run 'virsh -c qemu:///system list' manually for the verbatim error."
    return $false
}

function Test-LinuxHostMinimum {
    <#
    .SYNOPSIS
        KVM quick-check for [Test-HostRequirement] (virsh on PATH +
        /dev/kvm present). Emits actionable warnings on failure and
        returns $false; emits nothing and returns $true when both
        conditions are met.
    .DESCRIPTION
        Lighter than Assert-LinuxHostConditionSet (which also gates
        on libvirtd-active + libvirt-group membership) -- this exists
        for one-off operator helpers (Remove-OrphanedVMFiles.ps1 etc.)
        where the libvirtd / group checks would be confusing during
        interactive maintenance run via sudo.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $ok = $true
    if (-not (Get-Command virsh -ErrorAction SilentlyContinue)) {
        Write-Warning "virsh not found on PATH. Install libvirt + QEMU: sudo apt install libvirt-clients libvirt-daemon-system qemu-kvm"
        $ok = $false
    }
    if (-not (Test-Path '/dev/kvm')) {
        Write-Warning "/dev/kvm missing -- kvm.ko not loaded or VT-x/SVM disabled in firmware. Enable hardware virtualization in BIOS/UEFI and load the kvm kernel module."
        $ok = $false
    }
    return $ok
}

Export-ModuleMember -Function Get-LibvirtGroupState, Set-LinuxHostConditionSet, Assert-LinuxHostConditionSet, Test-LinuxHostMinimum
