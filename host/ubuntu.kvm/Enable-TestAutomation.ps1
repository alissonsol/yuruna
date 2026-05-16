<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e93
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
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
    Prepares an Ubuntu KVM/libvirt host to run yuruna automated VM tests.

.DESCRIPTION
    Configures host-side settings needed for unattended, long-running test
    runs against libvirt-managed guest VMs:
      * libvirtd + virtlogd enabled and running
      * libvirt 'default' network up + autostart (NAT 192.168.122.0/24)
      * yuruna VM image directory created under $HOME/yuruna/{image,vms}
      * GNOME idle / lock / dim disabled when running on a desktop session
        (no-op on a headless server -- gsettings just isn't present)
      * sudo can be cached for the run (the calling installer primed it)

    Run this before Invoke-TestRunner.ps1. Idempotent -- safe to re-run.

.PARAMETER WhatIf
    Shows what would change without applying any settings.

.EXAMPLE
    pwsh ./Enable-TestAutomation.ps1
    pwsh ./Enable-TestAutomation.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = "Stop"

if (-not $IsLinux) {
    Write-Error "Enable-TestAutomation.ps1 (host/ubuntu.kvm) only runs on Linux."
    exit 1
}

# Prime sudo once up front so the systemctl + virsh net-* sequence below
# doesn't re-prompt mid-run. Cross-folder import: this script lives at
# host/ubuntu.kvm/; the helper is in test/modules/Test.Host.psm1 (two
# levels up). Idempotent -- when the install wrapper (install/ubuntu.
# kvm.sh) already cached sudo, Initialize-SudoCache returns silently
# without printing the notice or re-prompting.
$ScriptDir  = $PSScriptRoot
$RepoRoot   = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$ModulePath = Join-Path $RepoRoot "test/modules/Test.Host.psm1"
$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"
Import-Module $ModulePath -Force
$global:VerbosePreference = $savedVerbose
[void](Initialize-SudoCache -Reasons @(
    'systemctl enable + start libvirtd / virtlogd',
    'virsh net-{list,start,autostart} default'
))

# Cycle planner reads project/test/test.sequence.yml and every per-sequence
# baseline via powershell-yaml. Missing here -> Resolve-CyclePlan throws ->
# inner runner falls back to legacy guestSequence -> Start-GuestOS runs with
# an empty sequence list and is recorded as "skipped" with no log trace.
[void](Install-PowerShellYamlIfMissing @PSBoundParameters)
[void](Install-PSScriptAnalyzerIfMissing @PSBoundParameters)

function Invoke-Step {
    # SupportsShouldProcess on the script-level param() does NOT propagate to
    # nested functions -- $PSCmdlet inside this function refers to the
    # function's own context, so the attribute must be repeated here for
    # ShouldProcess to be wired up and for PSScriptAnalyzer's PSShouldProcess
    # rule to be satisfied. -WhatIf flows through automatically because
    # $WhatIfPreference inherits from the calling scope.
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Description, [scriptblock]$Action)
    if ($PSCmdlet.ShouldProcess($Description)) {
        try { & $Action } catch { Write-Warning "$Description failed: $($_.Exception.Message)" }
    } else {
        Write-Output "WhatIf: $Description"
    }
}

# -- libvirt services + default network --------------------------------------
# When invoked from install/ubuntu.kvm.sh (YURUNA_SUDO_PRIMED=1), the bash
# wrapper has ALREADY done every sudo step in this block:
#   sudo systemctl enable --now libvirtd / virtlogd
#   sudo virsh net-start default
#   sudo virsh net-autostart default
# Re-running them here would burn the sudo cache for no operational reason
# AND, if the cache went cold during the long apt install phase, prompt
# the operator a second time. Trust the wrapper; only verify with non-sudo
# checks. On a standalone `pwsh ./Enable-TestAutomation.ps1` invocation
# (no wrapper) we still do the writes so the script works on its own.
$wrapperPrimed = ($env:YURUNA_SUDO_PRIMED -eq '1')

if ($wrapperPrimed) {
    foreach ($unit in @('libvirtd', 'virtlogd')) {
        $active = (& systemctl is-active $unit 2>$null).Trim()
        if ($active -ne 'active') {
            Write-Warning "$unit not active despite install/ubuntu.kvm.sh wrapper -- check 'systemctl status $unit'."
        }
    }
} else {
    Invoke-Step -Description 'Enable + start libvirtd' -Action {
        & sudo systemctl enable --now libvirtd | Out-Null
    }
    Invoke-Step -Description 'Enable + start virtlogd' -Action {
        & sudo systemctl enable --now virtlogd | Out-Null
    }

    $netListed = & sudo virsh net-list --name 2>$null
    if (-not ($netListed -match '^default$')) {
        Invoke-Step -Description "Start libvirt 'default' network" -Action {
            & sudo virsh net-start default 2>$null | Out-Null
        }
    }
    Invoke-Step -Description "Set libvirt 'default' network to autostart" -Action {
        & sudo virsh net-autostart default 2>$null | Out-Null
    }
}

# -- yuruna image / VM storage layout --------------------------------------
$imgDir = Join-Path $HOME 'yuruna/image'
$vmDir  = Join-Path $HOME 'yuruna/vms'
foreach ($d in @($imgDir, $vmDir)) {
    if (-not (Test-Path -LiteralPath $d)) {
        Invoke-Step -Description "mkdir -p $d" -Action {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
        }
    }
}

# -- libvirt-qemu search ACL on $HOME --------------------------------------
# Ubuntu 24.04 cloud images create /home/<user> with mode 0750, which
# excludes the libvirt-qemu user (uid 64055, gid kvm) that runs guest
# qemu processes. virt-install then fails with:
#   "Cannot access storage file '/home/<user>/yuruna/vms/.../*.qcow2'
#    (as uid:64055, gid:994): Permission denied"
# A traverse-only POSIX ACL is the narrowest fix -- read/write/listing on
# $HOME is unchanged, only path traversal is granted to libvirt-qemu.
& getent passwd libvirt-qemu *> $null
$haveLibvirtQemu = ($LASTEXITCODE -eq 0)
$haveSetfacl    = [bool](Get-Command -Name 'setfacl' -ErrorAction SilentlyContinue)
if ($haveLibvirtQemu -and $haveSetfacl) {
    Invoke-Step -Description "setfacl -m u:libvirt-qemu:--x $HOME" -Action {
        & setfacl -m 'u:libvirt-qemu:--x' $HOME
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "setfacl failed on $HOME -- libvirt-qemu may not be able to reach VM disks. Try 'chmod o+x $HOME' as a fallback."
        }
    }
} elseif (-not $haveLibvirtQemu) {
    Write-Warning "libvirt-qemu user not found -- skipping search-ACL step. (Is libvirt-daemon-system installed?)"
} else {
    Write-Warning "setfacl not available -- run 'sudo apt-get install acl' so libvirt-qemu can traverse $HOME."
}

# -- GNOME idle / lock / dim (no-op on headless servers) -------------------
# gsettings is GNOME-only. On a server install gsettings is missing
# entirely; on a desktop install we apply the same equivalents the macOS
# and Windows scripts apply for their host:
#   sleep-inactive-{ac,battery}-type   -> 'nothing'
#   idle-delay                         -> 0
#   lock-enabled                       -> false
#   idle-dim                           -> false
$gsettings = Get-Command -Name 'gsettings' -ErrorAction SilentlyContinue
if ($gsettings) {
    $tweaks = @(
        @('org.gnome.settings-daemon.plugins.power','sleep-inactive-ac-type','nothing'),
        @('org.gnome.settings-daemon.plugins.power','sleep-inactive-battery-type','nothing'),
        @('org.gnome.desktop.session','idle-delay','uint32 0'),
        @('org.gnome.desktop.screensaver','lock-enabled','false'),
        @('org.gnome.settings-daemon.plugins.power','idle-dim','false')
    )
    foreach ($t in $tweaks) {
        $schema = $t[0]; $key = $t[1]; $val = $t[2]
        Invoke-Step -Description "gsettings set $schema $key '$val'" -Action {
            # gsettings exits non-zero when the schema isn't installed (e.g.
            # GNOME minimal install); swallow so the script stays idempotent.
            & gsettings set $schema $key $val 2>$null
        }
    }
} else {
    Write-Output "gsettings not present -- headless server, skipping GNOME idle/lock tweaks."
}

# -- Group membership probe --------------------------------------------------
# --- See https://yuruna.link/memory#why-the-group-membership-probe-uses-getent-rather-than-the-id-command
$activeGroups = (& id -nG 2>$null) -split '\s+'
foreach ($grp in @('libvirt','kvm')) {
    $line    = & getent group $grp 2>$null
    $members = if ($line) { (($line -split ':',4)[3]) -split ',' } else { @() }
    if ($members -notcontains $env:USER) {
        Write-Warning "$env:USER is not a member of '$grp' in /etc/group -- 'sudo usermod -aG $grp $env:USER' must have failed earlier. Run it manually, then re-run this script."
    }
    elseif (-not $wrapperPrimed -and $activeGroups -notcontains $grp) {
        # Standalone invocation only. When called via install/ubuntu.kvm.sh, the
        # wrapper's final-summary block (NEEDS_RELOG_HINT) reports the same
        # condition once, at the end, with the better "Step 0: refresh your
        # shell" framing -- duplicating it here lands two near-identical
        # reminders in one transcript. Functionally the stale set is harmless
        # under the wrapper: every virsh call in this script is sudo'd.
        Write-Output "  '$grp' membership is in /etc/group; this shell's group set is stale. Log out and back in (or 'newgrp $grp') before the next interactive pwsh call so virsh / virt-install work without sudo."
    }
}

Write-Output "Yuruna host configuration applied."
