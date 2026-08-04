<#PSScriptInfo
.VERSION 2026.08.04
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e93
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
    Prepares an Ubuntu KVM/libvirt host to run yuruna automated VM tests.

.DESCRIPTION
    Configures host-side settings needed for unattended, long-running test
    runs against libvirt-managed guest VMs:
      * missing host packages (qemu, libvirt, virtinst, virt-manager, ...)
        named up front, and installed with apt-get on an interactive run
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
param(
    # Settings-only run: skip the interactive networkStorage questionnaire at the
    # end. install/setup.ps1 configures storage itself, in its own order, and
    # would otherwise ask the same questions twice.
    [switch]$SkipPoolStorage
)

$ErrorActionPreference = "Stop"

if (-not $IsLinux) {
    Write-Error "Enable-TestAutomation.ps1 (host/ubuntu.kvm) only runs on Linux."
    exit 1
}

# Shared bootstrap (Test.HostContract import + sudo prime + powershell-yaml +
# PSScriptAnalyzer install) lives in automation/Yuruna.HostSetup.psm1.
# -SudoCacheReason keeps the sudo prompt EARLY (before the long install)
# with a visible reason banner so the operator knows WHAT will need
# elevation before they consent. When invoked via install/ubuntu.kvm.sh
# (YURUNA_SUDO_PRIMED=1) Initialize-SudoCache returns silently.
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.HostSetup.psm1') -Force
Initialize-HostSetupModule -RepoRoot $RepoRoot -BoundParameters $PSBoundParameters -SudoCacheReason @(
    'systemctl enable + start libvirtd / virtlogd',
    'virsh net-{list,start,autostart} default',
    'create the networkStorage pool SMB mount point (localPath) when its parent is root-owned',
    'read host hardware fingerprint (/sys/class/dmi product_uuid + board_serial) to register/reclaim this host pool identity'
)

function Test-AptPackageInstalled {
    # dpkg-query is the only authority on "is the package installed": probing for
    # a binary on PATH gives false negatives for helpers that live in /sbin, and
    # a half-configured package still leaves its files behind. 'ii' is the only
    # state that means fully installed and configured.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    $state = & dpkg-query -W -f='${db:Status-Abbrev}' $Name 2>$null
    return ("$state".Trim() -eq 'ii')
}

function Get-MissingHostPackage {
    <#
    .SYNOPSIS
        The apt packages this host needs but does not have, as
        @{ Package; Why } records. Empty means every prerequisite is present.
    .DESCRIPTION
        This script CONFIGURES a KVM host; install/ubuntu.kvm.sh is what
        INSTALLS one. Run standalone on a host that never went through the
        installer, every step below fails on a missing binary and reports its
        own symptom -- "systemctl enable libvirtd" says the unit does not
        exist, the group probe says usermod "must have failed earlier" for a
        group no package ever created, and the SMB mount blames passwordless
        sudo for a missing mount.cifs. None of those name the actual cause.
        Establishing it once, up front, replaces that cascade with the one
        fact that explains all of it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]], [object[]])]
    param()
    # Mirrors the KVM-relevant subset of what install/ubuntu.kvm.sh installs
    # (APT_PACKAGES plus the separate virt-manager call).
    # Critical means no guest can run at all without it, so the steps that follow
    # are skipped rather than left to fail one by one; the rest degrade a single
    # feature and are reported without blocking.
    $qemuPkg = switch ("$(& uname -m)".Trim()) {
        'aarch64' { 'qemu-system-arm' }
        default   { 'qemu-system-x86' }
    }
    $required = @(
        @{ Package = $qemuPkg;                Critical = $true;  Why = 'the QEMU system emulator that actually runs the guests' }
        @{ Package = 'libvirt-daemon-system'; Critical = $true;  Why = 'the libvirtd/virtlogd services and the libvirt + kvm groups' }
        @{ Package = 'libvirt-clients';       Critical = $true;  Why = 'virsh, used by every VM lifecycle step' }
        @{ Package = 'virtinst';              Critical = $true;  Why = 'virt-install, used to build guests' }
        @{ Package = 'acl';                   Critical = $false; Why = 'setfacl, so libvirt-qemu can traverse $HOME to reach the VM disks' }
        @{ Package = 'cifs-utils';            Critical = $false; Why = 'the mount.cifs helper the optional networkStorage pool share needs' }
        @{ Package = 'virt-manager';          Critical = $false; Why = 'the libvirt GUI, to watch a guest a headless step is stuck on' }
    )
    return @($required | Where-Object { -not (Test-AptPackageInstalled -Name $_.Package) })
}

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

# --- REGION: pre-automation capture
# BEFORE anything is changed: record what these knobs were, so
# Disable-TestAutomation can put them back. Written once and never overwritten
# -- a second Enable must not capture Enable's own values as the operator's.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostAutomationState.psm1') -Force -DisableNameChecking
$capturePath = Save-HostAutomationState -Platform 'ubuntu.kvm' -WhatIf:$WhatIfPreference
if ($capturePath) { Write-Output "Captured prior host settings to $capturePath (Disable-TestAutomation restores from it)." }

# --- REGION: host package prerequisites
# Establish the ONE fact that explains a whole class of downstream symptoms
# before any step can misreport it (see Get-MissingHostPackage). Interactive
# operators are offered the install right here so a standalone run of this
# script can leave the host actually working; a declined or unattended run
# skips the steps that cannot succeed instead of emitting a warning per step.
$missingPkgs   = @(Get-MissingHostPackage)
$missingCrit   = @($missingPkgs | Where-Object { $_.Critical })
$libvirtReady  = ($missingCrit.Count -eq 0)

if ($missingPkgs.Count -gt 0) {
    Write-Output ''
    Write-Output 'Missing host packages -- this host either never went through install/ubuntu.kvm.sh, or predates one of these:'
    foreach ($p in $missingPkgs) {
        $tag = if ($p.Critical) { 'required' } else { 'optional' }
        Write-Output "  [$tag] $($p.Package) -- $($p.Why)"
    }
    $aptLine = "sudo apt-get install -y $(($missingPkgs | ForEach-Object { $_.Package }) -join ' ')"

    $canPrompt = $false
    try { $canPrompt = ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) } catch { $canPrompt = $false }
    $installed = $false
    if ($canPrompt -and -not $WhatIfPreference) {
        $ans = Read-Host "Install them now with apt-get? [y/N]"
        if ($ans -match '^\s*(y|yes)\s*$') {
            # sudo is invoked directly (not through a stream-redirecting helper) so
            # its password prompt and apt's progress reach the operator's terminal.
            & sudo apt-get update -q
            & sudo apt-get install -y @($missingPkgs | ForEach-Object { $_.Package })
            if ($LASTEXITCODE -eq 0) {
                $installed   = $true
                $missingPkgs = @(Get-MissingHostPackage)
                $missingCrit = @($missingPkgs | Where-Object { $_.Critical })
                $libvirtReady = ($missingCrit.Count -eq 0)
                if ($missingPkgs.Count -eq 0) { Write-Output 'All host packages are now installed.' }
            } else {
                Write-Warning "apt-get install failed (exit $LASTEXITCODE). Run it manually: $aptLine"
            }
        }
    }
    if (-not $installed -and $missingPkgs.Count -gt 0) {
        Write-Output "  Install them with: $aptLine"
        Write-Output '  (install/ubuntu.kvm.sh installs these plus the rest of the host toolchain.)'
    }
    if (-not $libvirtReady) {
        Write-Warning 'Skipping the libvirt service, network, group and search-ACL steps: they cannot succeed until the packages above are installed. Re-run this script afterwards.'
    }
}

# --- REGION: libvirt services + default network
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

if (-not $libvirtReady) {
    # Reported once by the package gate above; per-step warnings here would only
    # restate it in terms that point away from the cause.
    Write-Verbose 'libvirt packages missing -- skipping the service + default-network steps.'
} elseif ($wrapperPrimed) {
    foreach ($unit in @('libvirtd', 'virtlogd')) {
        $raw = & systemctl is-active $unit 2>$null
        $active = if ($raw) { "$raw".Trim() } else { '' }
        if ($active -ne 'active') {
            Write-Warning "$unit not active despite install/ubuntu.kvm.sh wrapper -- check 'systemctl status $unit'."
        }
    }
} else {
    Invoke-Step -Description 'Enable + start libvirtd' -Action {
        & sudo systemctl enable --now libvirtd | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "systemctl enable --now libvirtd failed (exit $LASTEXITCODE); check 'systemctl status libvirtd'." }
    }
    Invoke-Step -Description 'Enable + start virtlogd' -Action {
        & sudo systemctl enable --now virtlogd | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "systemctl enable --now virtlogd failed (exit $LASTEXITCODE); check 'systemctl status virtlogd'." }
    }

    $netListed = & sudo virsh net-list --name 2>$null
    if (-not ($netListed -match '^default$')) {
        Invoke-Step -Description "Start libvirt 'default' network" -Action {
            & sudo virsh net-start default 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Warning "virsh net-start default failed (exit $LASTEXITCODE)." }
        }
    }
    Invoke-Step -Description "Set libvirt 'default' network to autostart" -Action {
        & sudo virsh net-autostart default 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "virsh net-autostart default failed (exit $LASTEXITCODE)." }
    }
    # Verify the 'default' network is actually active before declaring success -- a failed
    # net-start above otherwise leaves guests on the default network with no address.
    $netActive = & sudo virsh net-list --name 2>$null
    if (-not ($netActive -match '^default$')) {
        Write-Warning "libvirt 'default' network is not active after net-start/net-autostart; check 'sudo virsh net-list --all'."
    }
}

# --- REGION: status-service LAN reachability (host firewall)
# Start-StatusService binds http://*:<port>/ (every interface), but a host
# firewall silently DROPs inbound TCP on non-loopback interfaces without an
# allow rule -- so localhost answers while the pool-aggregator service (and an operator's
# browser) time out, and the host disappears from the pool dashboard. The
# Windows path opens this in Set-WindowsHostConditionSet; do the ufw equivalent
# here so an Ubuntu host is reachable too. This is the PERSISTENT fix: a host
# whose runner is stopped never re-runs the per-cycle status start, so the
# status-service self-heal cannot fire there -- the rule set once at setup is
# what survives. Port from test.config.yml (8080 default), the same source
# Start-StatusService reads. No-op when ufw is inactive/absent.
$statusPort = 8080
Import-Module (Join-Path $RepoRoot 'test/modules/Test.Config.psm1') -Force
$statusConfigPath = Join-Path $RepoRoot 'test/test.config.yml'
if (Test-Path -LiteralPath $statusConfigPath) {
    try {
        $statusTc = Read-TestConfig -Path $statusConfigPath
        if ($statusTc -and $statusTc.statusService -and $statusTc.statusService.port) { $statusPort = [int]$statusTc.statusService.port }
    } catch { Write-Verbose "status port read: $($_.Exception.Message)" }
}
Import-Module (Join-Path $RepoRoot 'test/modules/Test.StatusFirewall.psm1') -Force
Invoke-Step -Description "Allow inbound TCP :$statusPort (status service) through the host firewall (ufw)" -Action {
    $fwResult = Set-YurunaStatusFirewallRule -Port $statusPort
    Write-Output "  status firewall: $($fwResult.Message)"
}

# --- REGION: host clock
# libvirt seeds each guest's clock from this host at power-on, so a host
# that has drifted starts every VM equally wrong and the guest's own NTP
# client steps it to real time seconds into the boot -- mid-startup for
# whatever that guest is bringing up. On a Kubernetes guest that leaves
# pods Running but never Ready and every NodePort refusing, with nothing
# in the picture pointing back at a clock. The Windows and macOS paths do
# this inside their Set-*HostConditionSet; this host's setup script does
# not route through Set-LinuxHostConditionSet, so the same call lands here.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostCondition.psm1') -Force -DisableNameChecking
Invoke-Step -Description 'Put the host clock under NTP discipline (timedatectl set-ntp true)' -Action {
    $clockResult = Sync-LinuxHostClock
    if ($clockResult.Succeeded) {
        Write-Output "  host clock: $($clockResult.Message)"
    } else {
        Write-Warning "host clock not disciplined: $($clockResult.Message)"
    }
}

# --- REGION: yuruna image / VM storage layout
$imgDir = Join-Path $HOME 'yuruna/image'
$vmDir  = Join-Path $HOME 'yuruna/vms'
foreach ($d in @($imgDir, $vmDir)) {
    if (-not (Test-Path -LiteralPath $d)) {
        Invoke-Step -Description "mkdir -p $d" -Action {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
        }
    }
}

# --- REGION: networkStorage pool SMB mount point (optional NAS replication target)
# networkStorage pool (test.config.yml) mounts an SMB share at localPath. The test
# runner runs UNPRIVILEGED; when localPath sits under a root-owned parent
# (e.g. /mnt/ypool-nas under /mnt 0755 root:root), Connect-YurunaPoolStorage's own
# New-Item cannot create the directory and the mount is never even attempted
# -- a reachable NAS that silently never replicates. Pre-create the mount
# point here, where this host-setup script can elevate, owned by the runner so
# the unprivileged mount path finds it already present and writable. The
# mount.cifs helper itself comes from cifs-utils (install/ubuntu.kvm.sh).
$cfgPath = Join-Path $RepoRoot 'test/test.config.yml'
if (Test-Path -LiteralPath $cfgPath) {
    $modulesDir = Join-Path $RepoRoot 'test/modules'
    Import-Module (Join-Path $modulesDir 'Test.Config.psm1')      -Force
    Import-Module (Join-Path $modulesDir 'Test.PoolStorage.psm1') -Force
    $poolCfg = $null
    try {
        $poolConfigDoc = Read-TestConfig -Path $cfgPath
        # -IgnoreReplicate: prepare the mount point even before the operator
        # flips replicate to true, as long as localPath is set -- mirrors the
        # connection-param pre-flight in Test-Config.ps1. Returns $null (skip)
        # when networkPath / networkUser / localPath are not all populated.
        if ($poolConfigDoc) {
            $poolCfg = Get-YurunaPoolStorageConfig -Config $poolConfigDoc -IgnoreReplicate -WarningAction SilentlyContinue
        }
    } catch {
        Write-Warning "networkStorage pool mount-point setup: could not read $cfgPath ($($_.Exception.Message)); skipping."
    }
    if ($poolCfg -and -not [string]::IsNullOrWhiteSpace($poolCfg.LocalPath)) {
        $mountPoint = $poolCfg.LocalPath
        if (Test-Path -LiteralPath $mountPoint) {
            Write-Output "networkStorage pool mount point already exists: $mountPoint"
        } else {
            Invoke-Step -Description "create networkStorage pool mount point $mountPoint (owned by $env:USER)" -Action {
                # Try unprivileged first (a localPath under $HOME needs no sudo);
                # fall back to sudo for a root-owned parent like /mnt, handing
                # ownership to the runner so the later unprivileged mount can
                # create + reach the directory.
                try {
                    New-Item -ItemType Directory -Force -Path $mountPoint -ErrorAction Stop | Out-Null
                } catch {
                    $grp = (& id -gn).Trim()
                    & sudo install -d -o $env:USER -g $grp $mountPoint
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "Could not create networkStorage pool mount point '$mountPoint'. Create it manually: sudo install -d -o $env:USER -g $grp '$mountPoint'."
                    }
                }
            }
        }
    }
}

# --- REGION: libvirt-qemu search ACL on $HOME
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
if (-not $libvirtReady) {
    Write-Verbose 'libvirt packages missing -- skipping the search-ACL step.'
} elseif ($haveLibvirtQemu -and $haveSetfacl) {
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

# --- REGION: GNOME idle / lock / dim (no-op on headless servers)
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

# --- REGION: https://yuruna.link/memory#why-the-group-membership-probe-uses-getent-rather-than-the-id-command
$activeGroups = (& id -nG 2>$null) -split '\s+'
foreach ($grp in @('libvirt','kvm')) {
    $line    = & getent group $grp 2>$null
    # No such group at all: the package that creates it is not installed. Saying
    # usermod "must have failed" here would be false -- usermod cannot add anyone
    # to a group that does not exist, and the operator would chase the wrong fix.
    if (-not $line) {
        if ($libvirtReady) {
            Write-Warning "group '$grp' does not exist even though the libvirt packages are installed -- check 'sudo dpkg-reconfigure libvirt-daemon-system'."
        } else {
            Write-Verbose "group '$grp' absent; the package that creates it is not installed (reported above)."
        }
        continue
    }
    $members = (($line -split ':',4)[3]) -split ','
    if ($members -notcontains $env:USER) {
        # The group exists, so this is fixable right here -- sudo is already
        # primed for this run. Telling the operator to go run usermod themselves
        # leaves the host broken for no reason.
        Invoke-Step -Description "usermod -aG $grp $env:USER" -Action {
            & sudo usermod -aG $grp $env:USER
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "'sudo usermod -aG $grp $env:USER' failed (exit $LASTEXITCODE). Run it manually, then re-run this script."
            } else {
                Write-Output "  added $env:USER to '$grp'; log out and back in (or 'newgrp $grp') before the next interactive pwsh call."
            }
        }
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

# --- REGION: networkStorage pool host-identity setup + reimage reclaim (interactive)
# Offer to configure networkStorage pool (NAS replication) and, on a host with no local
# pool identity, scan the NAS registry to reclaim a prior uuid after a reimage.
# Self-skips cleanly when run non-interactively or under -WhatIf. The orchestrator
# loads its own sibling dependencies (config/vault/mount); sudo is primed above so
# the privileged fingerprint read + mount work without a second prompt. The
# host fingerprint read is included in the -SudoCacheReason banner above.
if ($SkipPoolStorage) {
    Write-Output 'Skipping the networkStorage questionnaire (-SkipPoolStorage).'
} elseif (-not $WhatIfPreference) {
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostIdentity.psm1') -Force
    Invoke-PoolStorageSetupAndReclaim -RepoRoot $RepoRoot
}

Write-Output "Yuruna host configuration applied."
