<#PSScriptInfo
.VERSION 2026.08.07
.GUID 424c8e37-1b52-4f6d-8c07-e5d29a3b7104
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host ubuntu kvm disable-test-automation
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
    Restore the Ubuntu host settings Enable-TestAutomation changed.
.DESCRIPTION
    Reads status/runtime/host.pre-automation.json -- written by
    Enable-TestAutomation before it changed anything -- and puts each captured
    knob back:

      * the GNOME gsettings idle / lock / dim keys
      * the timedatectl NTP setting
      * libvirtd and virtlogd enabled-state

    And removes what Enable added, but ONLY when the capture proves Enable added
    it:

      * the ufw allow rule for the status-service port
      * libvirt / kvm group membership (only if this user was not a member before)
      * the libvirt-qemu search ACL on $HOME (only if there was none before)

    libvirtd and virtlogd are never disabled without a capture. On the normal
    install path it is install/ubuntu.kvm.sh -- not Enable-TestAutomation -- that
    enables them, and a capture-less "reversal" would stop unrelated VMs on the
    machine.

    Needs sudo for ufw, systemctl and gpasswd. The cache is primed once, up
    front, with a reason banner.
.PARAMETER StopServices
    Also stop the caching-proxy, stash, pool-control and download-agent VMs
    this host runs.
.EXAMPLE
    pwsh host/ubuntu.kvm/Disable-TestAutomation.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$StopServices
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

if (-not $IsLinux) {
    Write-Error 'Disable-TestAutomation.ps1 (host/ubuntu.kvm) only runs on Linux.'
    exit 1
}

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostAutomationState.psm1') -Force -DisableNameChecking
# Test.HostCondition re-exports Initialize-SudoCache (which despite living in
# the .Mac module is written for macOS AND Linux); importing the neutral module
# keeps a Linux script off a macOS-named one.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostCondition.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'test/modules/Test.Config.psm1')              -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Common.psm1')              -Force -DisableNameChecking

if (-not (Assert-SafeToDisable)) { exit 1 }

$state = Read-HostAutomationState
if ($state) {
    Write-Information "Restoring from the capture taken at $($state.capturedUtc)."
} else {
    Write-Warning 'No pre-automation capture on this host (it was enabled before the capture shipped, or the file was removed).'
    Write-Warning 'Only the ufw status-port rule will be removed -- it is provably ours. Group membership, the $HOME ACL, libvirtd/virtlogd and the GNOME keys are left exactly as they are, and reported.'
}

$restored = [System.Collections.Generic.List[string]]::new()
$skipped  = [System.Collections.Generic.List[string]]::new()

# Thin local shim over the shared driver so the three per-host scripts stay
# readable: -State, -Cmdlet and the two lists are the same on every call.
function Restore-Knob {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Apply,
        [scriptblock]$Absent
    )
    Invoke-HostKnobRestore -State $state -Name $Name -Description $Description `
        -Apply $Apply -Absent $Absent -Cmdlet $PSCmdlet -Restored $restored -Skipped $skipped
}

if (-not $WhatIfPreference) {
    [void](Initialize-SudoCache -Reasons @(
        'ufw delete allow <status port>',
        'systemctl disable libvirtd / virtlogd (only when the capture says they were off)',
        'gpasswd -d (only when the capture says this user was not a member)'
    ))
}

# --- REGION: GNOME idle / lock / dim
foreach ($t in @(
    @('org.gnome.settings-daemon.plugins.power', 'sleep-inactive-ac-type'),
    @('org.gnome.settings-daemon.plugins.power', 'sleep-inactive-battery-type'),
    @('org.gnome.desktop.session',               'idle-delay'),
    @('org.gnome.desktop.screensaver',           'lock-enabled'),
    @('org.gnome.settings-daemon.plugins.power', 'idle-dim')
)) {
    $schema = $t[0]; $key = $t[1]
    Restore-Knob -Name "gsettings/$schema/$key" -Description "gsettings $schema $key" -Apply {
        param($v)
        if (-not (Get-Command -Name 'gsettings' -ErrorAction SilentlyContinue)) { throw 'gsettings is not present on this host' }
        # gsettings prints values quoted ('nothing') and typed (uint32 0); it
        # also ACCEPTS them in that form, so the captured string round-trips
        # without parsing.
        & gsettings set $schema $key "$v"
        if ($LASTEXITCODE -ne 0) { throw "gsettings set $schema $key '$v' failed (exit $LASTEXITCODE)" }
    }.GetNewClosure()
}

# --- REGION: host clock
Restore-Knob -Name 'timedatectl/ntp' -Description 'timedatectl NTP' -Apply {
    param($v)
    $onOff = if ("$v" -match '^(yes|active|true)$') { 'true' } else { 'false' }
    $r = Invoke-YurunaSudo -Argument @('timedatectl', 'set-ntp', $onOff) -TolerateBlocked
    if ($r.ExitCode -ne 0) { throw "timedatectl set-ntp $onOff failed: $($r.Output)" }
}

# --- REGION: libvirt services
# Only ever acted on with a capture in hand: see the header.
foreach ($unit in @('libvirtd', 'virtlogd')) {
    Restore-Knob -Name "systemd/$unit" -Description "$unit enabled-state" -Apply {
        param($v)
        $was = "$v".Trim()
        if ($was -eq 'enabled') {
            Write-Verbose "$unit was already enabled before automation; leaving it enabled."
            return
        }
        $r = Invoke-YurunaSudo -Argument @('systemctl', 'disable', '--now', $unit) -TolerateBlocked
        if ($r.ExitCode -ne 0) { throw "systemctl disable --now $unit failed: $($r.Output)" }
    }.GetNewClosure()
}

# --- REGION: group membership
# Removed ONLY when the capture proves this user was not a member before. A user
# who was already in 'libvirt' before ever meeting Yuruna keeps that membership.
foreach ($grp in @('libvirt', 'kvm')) {
    $knob = Get-HostAutomationKnob -State $state -Name "group/$grp"
    if (-not $knob -or -not $knob.present) { $skipped.Add("Membership of '$grp' (not captured; left as it is)"); continue }
    $prior = "$($knob.value)".Trim()
    if ($prior -ne 'not-a-member') {
        $skipped.Add("Membership of '$grp' (was already '$prior' before automation)")
        continue
    }
    $line = & getent group $grp 2>$null
    if (-not $line) { $skipped.Add("Membership of '$grp' (the group no longer exists)"); continue }
    $members = (("$line" -split ':', 4)[3]) -split ','
    if ($members -notcontains $env:USER) { continue }
    if ($PSCmdlet.ShouldProcess("$env:USER in group '$grp'", 'Remove (added by Enable-TestAutomation)')) {
        $r = Invoke-YurunaSudo -Argument @('gpasswd', '-d', $env:USER, $grp) -TolerateBlocked
        if ($r.ExitCode -eq 0) {
            $restored.Add("Removed $env:USER from '$grp' (log out and back in for this shell's group set to catch up)")
        } else {
            $skipped.Add("Membership of '$grp' (gpasswd -d failed: $($r.Output))")
        }
    }
}

# --- REGION: libvirt-qemu search ACL on $HOME
$aclKnob = Get-HostAutomationKnob -State $state -Name 'acl/home'
if (-not $aclKnob -or -not $aclKnob.present) {
    $skipped.Add("libvirt-qemu search ACL on $HOME (not captured; left as it is)")
} elseif ("$($aclKnob.value)".Trim() -ne 'absent') {
    $skipped.Add("libvirt-qemu search ACL on $HOME (it was already there before automation)")
} elseif (-not (Get-Command -Name 'setfacl' -ErrorAction SilentlyContinue)) {
    $skipped.Add("libvirt-qemu search ACL on $HOME (setfacl is not installed)")
} elseif ($PSCmdlet.ShouldProcess("libvirt-qemu search ACL on $HOME", 'Remove (added by Enable-TestAutomation)')) {
    & setfacl -x 'u:libvirt-qemu' $HOME
    if ($LASTEXITCODE -eq 0) { $restored.Add("Removed the libvirt-qemu search ACL on $HOME") }
    else { $skipped.Add("libvirt-qemu search ACL on $HOME (setfacl -x failed, exit $LASTEXITCODE)") }
}

# --- REGION: ufw status-port rule
# Removed with or without a capture: the rule is ours by construction -- Enable
# is what added it, for the status service's port.
$statusPort = 8080
$configPath = Join-Path $RepoRoot 'test/test.config.yml'
if (Test-Path -LiteralPath $configPath) {
    try {
        $tc = Read-TestConfig -Path $configPath
        if ($tc -and $tc.statusService -and $tc.statusService.port) { $statusPort = [int]$tc.statusService.port }
    } catch { Write-Verbose "status port read: $($_.Exception.Message)" }
}
$ufwCmd = Get-Command ufw -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $ufwCmd) {
    $skipped.Add("ufw allow $statusPort/tcp (ufw is not installed)")
} else {
    # The absolute path: ufw lives in /usr/sbin, which is not on an
    # unprivileged PATH, and 'sudo ufw' would then read as "not installed".
    $ufwExe = if ($ufwCmd.Source) { $ufwCmd.Source } else { 'ufw' }
    $status = Invoke-YurunaSudo -Argument @($ufwExe, 'status') -TolerateBlocked
    if ($status.ExitCode -ne 0) {
        $skipped.Add("ufw allow $statusPort/tcp (could not read ufw status: $($status.Output))")
    } elseif ($status.Output -notmatch "(?m)^\s*$statusPort/tcp\s") {
        Write-Verbose "ufw has no allow rule for $statusPort/tcp."
    } elseif ($PSCmdlet.ShouldProcess("ufw allow $statusPort/tcp", 'Delete the status-service rule Yuruna added')) {
        $r = Invoke-YurunaSudo -Argument @($ufwExe, '--force', 'delete', 'allow', "$statusPort/tcp") -TolerateBlocked
        if ($r.ExitCode -eq 0) { $restored.Add("ufw rule removed: allow $statusPort/tcp") }
        else { $skipped.Add("ufw allow $statusPort/tcp (delete failed: $($r.Output))") }
    }
}

# --- REGION: services (opt-in)
if ($StopServices) {
    foreach ($svc in @('CachingProxyService', 'StashService', 'PoolControlService', 'DownloadAgentService')) {
        $script = Join-Path $RepoRoot "test/Stop-${svc}VM.ps1"
        if (-not (Test-Path -LiteralPath $script)) { $skipped.Add("test/Stop-${svc}VM.ps1 not found"); continue }
        if ($PSCmdlet.ShouldProcess("$svc VM", 'Stop')) {
            & pwsh -NoProfile -File $script
            $restored.Add("$svc VM stopped")
        }
    }
}

# --- REGION: report
Write-DisableReport -Platform 'ubuntu.kvm' -Restored $restored -Skipped $skipped

Write-Output ''
Write-Output 'NOT reversed (deliberately) -- run these yourself if you want them gone:'
Write-DisableManualStep -What 'apt packages (qemu-kvm, libvirt-daemon-system, cifs-utils, acl, ...) and PSGallery modules' -Command @(
    'Uninstall-Module powershell-yaml, PSScriptAnalyzer'
)
Write-DisableManualStep -What 'The libvirt default network, and any guests defined on this host' -Command @(
    'sudo virsh net-list --all',
    'sudo virsh list --all'
)
Write-DisableManualStep -What 'Cloned repos, VM images and run history under ~/yuruna'
Write-DisableManualStep -What 'networkStorage configuration, the vaulted credential and any mounts' `
    -Command (Get-PoolStorageManualTeardown -RepoRoot $RepoRoot)
Write-DisableManualStep -What 'The pool-storage sudoers drop-in, if one was installed' -Command @(
    'sudo ls /etc/sudoers.d/ | grep -i yuruna'
)
# Stated plainly rather than offered as a switch: nothing here removes the
# vault, and a -IncludeVault flag that only silenced this line would advertise a
# removal that never happened.
Write-DisableManualStep -What 'The Yuruna credential vault -- it holds credentials that are painful to recreate, so it is never removed automatically' -Command @(
    'Get-SecretVault                     # find the Yuruna vault',
    'Unregister-SecretVault -Name <name> # then delete its store on disk'
)
if (-not $StopServices) {
    Write-DisableManualStep -What 'The caching-proxy / stash / pool-control / download-agent VMs (re-run with -StopServices to stop them)'
}

$capturePath = Get-HostAutomationStatePath
if ($state -and (Test-Path -LiteralPath $capturePath)) {
    Write-Output ''
    Write-Output "The capture is kept at $capturePath so this can be re-run; delete it once the host is where you want it."
}
