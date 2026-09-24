<#PSScriptInfo
.VERSION 2026.09.24
.GUID 4264541c-67da-418e-bf26-a11eb9662af8
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
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

function Sync-LinuxHostClock {
    <#
    .SYNOPSIS
        Put the host clock back under NTP discipline via timedatectl.
        Returns @{ Succeeded; Message }.
    .DESCRIPTION
        libvirt seeds each guest's clock from this host at power-on. What a
        drifted clock then does to a guest:
        https://yuruna.link/42d38664-001a

        `timedatectl set-ntp true` is the durable half. Restarting the
        active sync daemon afterwards is the immediate half: enabling NTP
        does not itself step a clock that is already hours out, and
        systemd-timesyncd only steps on start.

        Reports rather than throws, and never prompts (`sudo -n`): a
        scripted host-prep run blocked on a hidden password prompt is a
        hang, not a failed clock sync. An interactive caller that wants
        the sync to succeed primes the credential cache first
        (Initialize-SudoCache), which asks once and visibly.
    .OUTPUTS
        [hashtable] Succeeded (bool), Message (string).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param()

    if (-not $IsLinux) {
        return @{ Succeeded = $false; Message = (Format-YurunaOperatorMessage -Key 'runner.operator_2cabc360ec407ae8') }
    }
    if (-not (Get-Command timedatectl -ErrorAction SilentlyContinue)) {
        return @{ Succeeded = $false; Message = (Format-YurunaOperatorMessage -Key 'runner.operator_55f10ef5009ca033') }
    }
    $manual = (Format-YurunaOperatorMessage -Key 'runner.operator_fc482441ba59283e')
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'runner.operator_ab78290b0162b326'), (Format-YurunaOperatorMessage -Key 'runner.operator_5b2ab60cf43c713c'))) {
        return @{ Succeeded = $false; Message = 'Skipped (WhatIf).' }
    }

    $ntpOut = & sudo -n timedatectl set-ntp true 2>&1
    if ($LASTEXITCODE -ne 0) {
        return @{ Succeeded = $false; Message = (Format-YurunaOperatorMessage -Key 'runner.operator_1bf17ab0244b3137' -Arguments @{ trim = "$(($ntpOut | Out-String).Trim())"; manual = "$manual" }) }
    }
    $steps = @('NTP enabled')

    # Whichever daemon this host actually runs -- chrony steps on demand,
    # timesyncd only on start. A host with neither still counts as synced:
    # set-ntp succeeded, so something is disciplining the clock.
    # Coerce before .Trim(): a missing unit makes (& ...) return $null, and
    # $null.Trim() throws (same guard as Assert-LinuxHostConditionSet).
    $chronyRaw   = & systemctl is-active chrony 2>$null
    $chronydRaw  = & systemctl is-active chronyd 2>$null
    $timesyncRaw = & systemctl is-active systemd-timesyncd 2>$null
    $chronyState   = if ($chronyRaw)   { "$chronyRaw".Trim() }   else { '' }
    $chronydState  = if ($chronydRaw)  { "$chronydRaw".Trim() }  else { '' }
    $timesyncState = if ($timesyncRaw) { "$timesyncRaw".Trim() } else { '' }
    if ($chronyState -eq 'active' -or $chronydState -eq 'active') {
        $stepOut = & sudo -n chronyc makestep 2>&1
        if ($LASTEXITCODE -eq 0) { $steps += 'chrony stepped' }
        else { Write-Verbose "chronyc makestep: $(($stepOut | Out-String).Trim())" }
    } elseif ($timesyncState -eq 'active') {
        $restartOut = & sudo -n systemctl restart systemd-timesyncd 2>&1
        if ($LASTEXITCODE -eq 0) { $steps += 'timesyncd restarted' }
        else { Write-Verbose "systemctl restart systemd-timesyncd: $(($restartOut | Out-String).Trim())" }
    }
    return @{ Succeeded = $true; Message = (Format-YurunaOperatorMessage -Key 'runner.operator_e8c769a3703de6a4' -Arguments @{ join = "$($steps -join ', ')" }) }
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
    # --- REGION: https://yuruna.link/42d38664-001a
    # Warn-only and once per cycle: the repair needs a privilege this process
    # cannot ask for, so a drifted host runs and says so rather than refusing
    # every cycle until an operator notices.
    Write-HostClockDriftWarning -HostType $HostType
    # The runner calls Initialize-YurunaHost before invoking this
    # function; that imports host/ubuntu.kvm/modules/Yuruna.Host.psm1
    # for host.ubuntu.kvm, so Assert-Virtualization is in scope here.
    if (Get-Command Assert-Virtualization -ErrorAction SilentlyContinue) {
        if (Assert-Virtualization) { return $true }
    }
    # --- REGION: Diagnose which precondition failed
    if (-not (Test-Path -LiteralPath '/dev/kvm')) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_43e66f1b323df1ce')
        return $false
    }
    # Coerce before .Trim(): a missing systemctl / empty output makes (& ...) return $null, and
    # $null.Trim() throws "cannot call a method on a null-valued expression".
    $raw = & systemctl is-active libvirtd 2>$null
    $active = if ($raw) { "$raw".Trim() } else { '' }
    if ($active -ne 'active') {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_5bd775f79ee13443' -Arguments @{ active = "$active" })
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
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_6086c8f7e49eae24' -Arguments @{ me = "$me" })
        return $false
    }
    if ($libvirtMembers -notcontains $me) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_af9331d7fcad1b25' -Arguments @{ me = "$me" })
        return $false
    }
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_71200c53c662e070')
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
        # Package names match install/ubuntu.kvm.sh. 'qemu-kvm' is only a
        # transitional shim on current Ubuntu -- naming the real qemu-system-*
        # package keeps this hint working as the shim is retired.
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_1a3ffa06ec11b7a6')
        $ok = $false
    }
    if (-not (Test-Path '/dev/kvm')) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7fa56a2704d96ae2')
        $ok = $false
    }
    return $ok
}

Export-ModuleMember -Function Get-LibvirtGroupState, Assert-LinuxHostConditionSet, Test-LinuxHostMinimum, Sync-LinuxHostClock
