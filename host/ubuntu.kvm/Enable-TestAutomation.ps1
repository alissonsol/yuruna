<#PSScriptInfo
.VERSION 2026.09.18
.GUID 4202d0ff-c419-4c17-bf82-ec1f841f72c7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host ubuntu kvm enable-test-automation
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
    Captures the host's original settings once, then applies the platform's
    unattended-test prerequisites and optional pool-storage setup. Re-running
    preserves the original capture used by Disable-TestAutomation.ps1.
    See https://yuruna.link/42e220c4-0004.
    Individual privileged changes use sudo. A new libvirt/kvm group membership
    requires a new login session before the test runner can use it.

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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = "Stop"

# --- REGION: Platform guard
if (-not $IsLinux) {
    Write-Error (Format-YurunaOperatorMessage -Key 'exceptions.host_8829c3d9ffaef2dd')
    exit 1
}

# --- REGION: Initialize host setup
# Shared bootstrap (Test.HostContract import + sudo prime + powershell-yaml +
# PSScriptAnalyzer install) lives in automation/Yuruna.HostSetup.psm1.
# -SudoCacheReason keeps the sudo prompt EARLY (before the long install)
# with a visible reason banner so the operator knows WHAT will need
# elevation before they consent. When invoked via install/ubuntu.kvm.sh
# (YURUNA_SUDO_PRIMED=1) Initialize-SudoCache returns silently.
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.HostSetup.psm1') -Force
# Test-YurunaCanPrompt: the one predicate for "can a question reach a person".
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
Initialize-HostSetupModule -RepoRoot $RepoRoot -BoundParameters $PSBoundParameters -SudoCacheReason @(
    'systemctl enable + start libvirtd / virtlogd',
    'virsh net-{list,start,autostart} default',
    'create the networkStorage pool SMB mount point (localPath) when its parent is root-owned',
    'read host hardware fingerprint (/sys/class/dmi product_uuid + board_serial) to register/reclaim this host pool identity'
)

# --- REGION: Script-local helpers
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
        @{ Package = $qemuPkg;                Critical = $true;  Why = (Format-YurunaOperatorMessage -Key 'host.operator_c981aa2f0a13e26b') }
        @{ Package = 'libvirt-daemon-system'; Critical = $true;  Why = (Format-YurunaOperatorMessage -Key 'host.operator_77f0eaf6efbc4bf9') }
        @{ Package = 'libvirt-clients';       Critical = $true;  Why = (Format-YurunaOperatorMessage -Key 'host.operator_4a504bc63a8df63c') }
        @{ Package = 'virtinst';              Critical = $true;  Why = (Format-YurunaOperatorMessage -Key 'host.operator_92e4fcc8d0e15f7c') }
        @{ Package = 'acl';                   Critical = $false; Why = (Format-YurunaOperatorMessage -Key 'host.operator_637c4dda4b9191b3') }
        @{ Package = 'cifs-utils';            Critical = $false; Why = (Format-YurunaOperatorMessage -Key 'host.operator_2d1ab313f776a956') }
        @{ Package = 'virt-manager';          Critical = $false; Why = (Format-YurunaOperatorMessage -Key 'host.operator_f138be59eb9fb325') }
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
        try { & $Action } catch { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_263f53927c61a241' -Arguments @{ description = "$Description"; message = "$($_.Exception.Message)" }) }
    } else {
        Write-Output "WhatIf: $Description"
    }
}

# Conditions this run wanted and could not establish. Counted at the end and
# turned into a distinct exit code, because the exit code is the only failure
# channel across the child-process boundary and a warning in a captured log
# reaches no report.
$Script:Unmet = [System.Collections.Generic.List[string]]::new()

function Test-UbuntuSudoAvailable {
    <#
    .SYNOPSIS
        Whether this process can run one privileged command right now without a
        password prompt.
    .DESCRIPTION
        Only sudo can answer. A credential timestamp expires on its own clock,
        the long apt phase above is exactly the kind of step that outlives one,
        and an /etc/sudoers.d NOPASSWD rule grants elevation with no timestamp
        at all -- none of which any environment variable records.

        Asking matters because sudo reads its password from /dev/tty, not from
        stdin: a child whose output is captured to a log can still raise a
        prompt on the terminal its parent has taken over, where nothing shows it
        and nothing answers it.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    # Pinned locally: a non-zero exit IS the answer this function returns, and
    # with $PSNativeCommandUseErrorActionPreference true a cold timestamp throws
    # instead -- so the probe written to keep a host from stalling would itself
    # abort the configuration pass on exactly the hosts it was written for.
    $PSNativeCommandUseErrorActionPreference = $false
    if (-not (Get-Command sudo -ErrorAction SilentlyContinue)) { return $false }
    & sudo -n true 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-HostSudo {
    <#
    .SYNOPSIS
        Run one privileged host-configuration command through `sudo -n`, and
        report whether it took.
    .DESCRIPTION
        -n unconditionally, including in front of an operator: the capability
        probe that admitted the block ran seconds earlier against a timestamp
        that can expire inside it, and the fallback for an expired one has to be
        an exit code rather than an unexplained second password box.
    .OUTPUTS
        [bool] $true when sudo ran the command and it exited 0.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string[]]$Argument)
    # Pinned locally: this function reports a failed step through its return
    # value, and the caller turns that into a named unmet condition. With
    # $PSNativeCommandUseErrorActionPreference true the non-zero exit throws
    # first, which Invoke-Step catches as a generic step failure -- losing both
    # the command that failed and the count the exit code is built from.
    $PSNativeCommandUseErrorActionPreference = $false
    $out = & sudo -n @Argument 2>&1
    if ($LASTEXITCODE -eq 0) { return $true }
    Write-Warning ("sudo {0} failed (exit {1}): {2}" -f ($Argument -join ' '), $LASTEXITCODE, ("$($out | Out-String)".Trim()))
    return $false
}

# --- REGION: Pre-automation capture
# BEFORE anything is changed: record what these knobs were, so
# Disable-TestAutomation can put them back. Written once and never overwritten
# -- a second Enable must not capture Enable's own values as the operator's.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostAutomationState.psm1') -Force -DisableNameChecking
$capturePath = Save-HostAutomationState -Platform 'ubuntu.kvm' -WhatIf:$WhatIfPreference
if ($capturePath) { Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_03e4abcc5cd53ea9' -Arguments @{ capturePath = "$capturePath" }) }

# --- REGION: Host package prerequisites
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
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_fb4dd946f32e035c')
    foreach ($p in $missingPkgs) {
        $tag = if ($p.Critical) { 'required' } else { 'optional' }
        Write-Output "  [$tag] $($p.Package) -- $($p.Why)"
    }
    $aptLine = "sudo apt-get install -y $(($missingPkgs | ForEach-Object { $_.Package }) -join ' ')"

    # The shared predicate, not a local console probe. On Linux
    # [Environment]::UserInteractive is unconditionally $true, so a probe built
    # from it answers "an operator is present" for a runner cycle spawned with an
    # inherited terminal -- and the offer below then blocks the host on a
    # question nobody is watching for.
    $canPrompt = Test-YurunaCanPrompt
    $installed = $false
    if ($canPrompt -and -not $WhatIfPreference) {
        $ans = Read-Host (Format-YurunaOperatorMessage -Key 'host.operator_29aa1547e4e4c25c')
        if ($ans -match '^\s*(y|yes)\s*$') {
            # The one place a sudo password prompt is legitimate: this branch is
            # reached only after a person answered a question at this terminal,
            # so they can see the prompt and type into it. sudo is invoked
            # directly (not through Invoke-HostSudo) for the same reason -- its
            # prompt and apt's progress both belong on that terminal.
            & sudo apt-get update -q
            & sudo apt-get install -y @($missingPkgs | ForEach-Object { $_.Package })
            if ($LASTEXITCODE -eq 0) {
                $installed   = $true
                $missingPkgs = @(Get-MissingHostPackage)
                $missingCrit = @($missingPkgs | Where-Object { $_.Critical })
                $libvirtReady = ($missingCrit.Count -eq 0)
                if ($missingPkgs.Count -eq 0) { Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_0a3b7c8ba926d7e8') }
            } else {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_20cc4b8c9d8b0a89' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE"; aptLine = "$aptLine" })
            }
        }
    }
    if (-not $installed -and $missingPkgs.Count -gt 0) {
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c6a74dce689da89e' -Arguments @{ aptLine = "$aptLine" })
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_ae926188af9d3ca0')
    }
    if (-not $libvirtReady) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_bf5cb6a52f334520')
    }
}

# --- REGION: libvirt services + default network
# Whether these steps run is decided by whether root is reachable RIGHT NOW,
# never by who started the run. Only install/ubuntu.kvm.sh performs these
# commands ahead of time; every other caller does not, so a gate keyed on the
# caller's identity leaves libvirtd disabled on those hosts while claiming a
# wrapper already handled it.
#
# Re-running them after the bash wrapper already did is safe: systemctl enable
# --now, virsh net-start and virsh net-autostart are all idempotent, and paying
# for that is the price of not guessing. Every call goes out with `sudo -n`, so
# a cold credential is an exit code rather than a password prompt on a terminal
# whose output is being captured.
$canSudo = Test-UbuntuSudoAvailable

if (-not $libvirtReady) {
    # Reported once by the package gate above; per-step warnings here would only
    # restate it in terms that point away from the cause.
    Write-Verbose 'libvirt packages missing -- skipping the service + default-network steps.'
} elseif (-not $canSudo) {
    # Verify what can be verified unelevated, and name the commands rather than
    # asserting that something else already ran them.
    foreach ($unit in @('libvirtd', 'virtlogd')) {
        $raw = & systemctl is-active $unit 2>$null
        $active = if ($raw) { "$raw".Trim() } else { '' }
        if ($active -ne 'active') {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4bda2a4b26710c65' -Arguments @{ unit = "$unit" })
            $Script:Unmet.Add("$unit not running")
        }
    }
} else {
    Invoke-Step -Description 'Enable + start libvirtd' -Action {
        if (-not (Invoke-HostSudo -Argument @('systemctl', 'enable', '--now', 'libvirtd'))) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_06933c41d231b3ad')
            $Script:Unmet.Add('libvirtd not enabled')
        }
    }
    Invoke-Step -Description 'Enable + start virtlogd' -Action {
        if (-not (Invoke-HostSudo -Argument @('systemctl', 'enable', '--now', 'virtlogd'))) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d5046be6d09f1958')
            $Script:Unmet.Add('virtlogd not enabled')
        }
    }

    $netListed = & sudo -n virsh net-list --name 2>$null
    if (-not ($netListed -match '^default$')) {
        Invoke-Step -Description "Start libvirt 'default' network" -Action {
            [void](Invoke-HostSudo -Argument @('virsh', 'net-start', 'default'))
        }
    }
    Invoke-Step -Description "Set libvirt 'default' network to autostart" -Action {
        [void](Invoke-HostSudo -Argument @('virsh', 'net-autostart', 'default'))
    }
    # Verify the 'default' network is actually active before declaring success -- a failed
    # net-start above otherwise leaves guests on the default network with no address.
    $netActive = & sudo -n virsh net-list --name 2>$null
    if (-not ($netActive -match '^default$')) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_27c4405eda553954')
        $Script:Unmet.Add("libvirt 'default' network not active")
    }
}

# --- REGION: Status-service LAN reachability (host firewall)
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
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_5bd7d6a7c4fb4e88' -Arguments @{ message = "$($fwResult.Message)" })
}

# --- REGION: Host clock
# libvirt seeds each guest's clock from this host at power-on, so a host
# that has drifted starts every VM equally wrong and the guest's own NTP
# client steps it to real time seconds into the boot -- mid-startup for
# whatever that guest is bringing up. On a Kubernetes guest that leaves
# pods Running but never Ready and every NodePort refusing, with nothing
# in the picture pointing back at a clock. The Windows and macOS paths do
# this inside their Set-*HostConditionSet; this host has no equivalent, so
# the same call lands here.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostCondition.psm1') -Force -DisableNameChecking
Invoke-Step -Description 'Put the host clock under NTP discipline (timedatectl set-ntp true)' -Action {
    $clockResult = Sync-LinuxHostClock
    if ($clockResult.Succeeded) {
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_f62d769e65f81877' -Arguments @{ message = "$($clockResult.Message)" })
    } else {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_7add5495ea2b2ef6' -Arguments @{ message = "$($clockResult.Message)" })
    }
}

# --- REGION: Yuruna image / VM storage layout
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
        # Prepare the mount point whenever the three pool paths are populated:
        # that is the opt-in to archiving, so the mount is needed either way.
        # Returns $null (skip) when they are not all set.
        if ($poolConfigDoc) {
            $poolCfg = Get-YurunaPoolStorageConfig -Config $poolConfigDoc -WarningAction SilentlyContinue
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_e9c2af0e714f9d69' -Arguments @{ cfgPath = "$cfgPath"; message = "$($_.Exception.Message)" })
    }
    if ($poolCfg -and -not [string]::IsNullOrWhiteSpace($poolCfg.LocalPath)) {
        $mountPoint = $poolCfg.LocalPath
        if (Test-Path -LiteralPath $mountPoint) {
            Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_4841cd30859f57a0' -Arguments @{ mountPoint = "$mountPoint" })
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
                    if (-not (Invoke-HostSudo -Argument @('install', '-d', '-o', "$env:USER", '-g', $grp, $mountPoint))) {
                        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_dc167ec9eaab1852' -Arguments @{ mountPoint = "$mountPoint"; uSER = "$env:USER"; grp = "$grp" })
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
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_e66e5fac2f0dcb7f' -Arguments @{ hOME = "$HOME" })
        }
    }
} elseif (-not $haveLibvirtQemu) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_20e79763dcd1fd23')
} else {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_00bc8834800bb544' -Arguments @{ hOME = "$HOME" })
}

# --- REGION: GNOME idle / lock / dim
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
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_21fe3d6e5b9c0ade')
}

# --- REGION: https://yuruna.link/42d69dfa-0022
$activeGroups = (& id -nG 2>$null) -split '\s+'
foreach ($grp in @('libvirt','kvm')) {
    $line    = & getent group $grp 2>$null
    # No such group at all: the package that creates it is not installed. Saying
    # usermod "must have failed" here would be false -- usermod cannot add anyone
    # to a group that does not exist, and the operator would chase the wrong fix.
    if (-not $line) {
        if ($libvirtReady) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_1c96d636b10e91f1' -Arguments @{ grp = "$grp" })
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
            if (Invoke-HostSudo -Argument @('usermod', '-aG', $grp, "$env:USER")) {
                Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_a5c2b328548a1dd1' -Arguments @{ uSER = "$env:USER"; grp = "$grp" })
            } else {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0a2c942a7a5d733a' -Arguments @{ grp = "$grp"; uSER = "$env:USER" })
                $Script:Unmet.Add("$env:USER not in group '$grp'")
            }
        }
    }
    elseif ($activeGroups -notcontains $grp) {
        # Reported for every caller. install/ubuntu.kvm.sh says the same thing
        # once more in its own closing summary, and that duplication is the
        # cheaper mistake: suppressing the reminder for callers that publish a
        # particular environment variable suppresses it for every caller that
        # publishes it, including the ones that print no such reminder of their
        # own -- and virsh then fails for a reason nothing on screen explains.
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_37d4fa1ce9d640c6' -Arguments @{ grp = "$grp" })
    }
}

# --- REGION: Pool storage and host identity
# Offer to configure networkStorage pool (NAS replication) and, on a host with no local
# pool identity, scan the NAS registry to reclaim a prior uuid after a reimage.
# Self-skips cleanly when run non-interactively or under -WhatIf. The orchestrator
# loads its own sibling dependencies (config/vault/mount); sudo is primed above so
# the privileged fingerprint read + mount work without a second prompt. The
# host fingerprint read is included in the -SudoCacheReason banner above.
# See docs/pool-storage.md.
if ($SkipPoolStorage) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d2dcd01d576691e7')
} elseif (-not $WhatIfPreference) {
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostIdentity.psm1') -Force
    Invoke-PoolStorageSetupAndReclaim -RepoRoot $RepoRoot
}

Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_3f17fafb77a9c9cb')

# --- REGION: Outcome
# See https://yuruna.link/42e220c4-0004 for the shared 0/1/2 host-setup contract.
if ($WhatIfPreference) { exit 0 }
if ($Script:Unmet.Count -gt 0) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0de8f302c3df063e' -Arguments @{ count = "$($Script:Unmet.Count)"; join = "$($Script:Unmet -join ', ')" })
    exit 2
}
exit 0
