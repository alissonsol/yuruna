<#PSScriptInfo
.VERSION 2026.09.18
.GUID 427d85b1-fda1-4ae0-9a2f-5a950d4da265
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
    Restores values captured in status/runtime/host.pre-automation.json and
    removes Yuruna-owned additions. Missing captured values are reported and
    left unchanged. Refuses to restore settings during an active test cycle.
    Service shutdown is opt-in. See https://yuruna.link/42e220c4-0004.

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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# --- REGION: Platform guard
if (-not $IsLinux) {
    Write-Error (Format-YurunaOperatorMessage -Key 'exceptions.host_56dd0a83b1740c20')
    exit 1
}

# --- REGION: Initialize host setup
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostAutomationState.psm1') -Force -DisableNameChecking
# Test.HostCondition re-exports Initialize-SudoCache (which despite living in
# the .Mac module is written for macOS AND Linux); importing the neutral module
# keeps a Linux script off a macOS-named one.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostCondition.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'test/modules/Test.Config.psm1')              -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Common.psm1')              -Force -DisableNameChecking

if (-not (Assert-SafeToDisable)) { exit 1 }

# --- REGION: Read captured host settings
$state = Read-HostAutomationState
if ($state) {
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_97b7a77dbbb6e9c9' -Arguments @{ capturedUtc = "$($state.capturedUtc)" })
} else {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b151e82086a9c67b')
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_a0e97dcbb626019f')
}

$restored = [System.Collections.Generic.List[string]]::new()
$skipped  = [System.Collections.Generic.List[string]]::new()

# --- REGION: Script-local helpers
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
        if (-not (Get-Command -Name 'gsettings' -ErrorAction SilentlyContinue)) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_8d770e16b147abe9') }
        # gsettings prints values quoted ('nothing') and typed (uint32 0); it
        # also ACCEPTS them in that form, so the captured string round-trips
        # without parsing.
        & gsettings set $schema $key "$v"
        if ($LASTEXITCODE -ne 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_ee375a40b48f886b' -Arguments @{ schema = "$schema"; key = "$key"; v = "$v"; lASTEXITCODE = "$LASTEXITCODE" }) }
    }.GetNewClosure()
}

# --- REGION: Host clock
Restore-Knob -Name 'timedatectl/ntp' -Description 'timedatectl NTP' -Apply {
    param($v)
    $onOff = if ("$v" -match '^(yes|active|true)$') { 'true' } else { 'false' }
    $r = Invoke-YurunaSudo -Argument @('timedatectl', 'set-ntp', $onOff) -TolerateBlocked
    if ($r.ExitCode -ne 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_b1cc462acbad03b8' -Arguments @{ onOff = "$onOff"; output = "$($r.Output)" }) }
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
        if ($r.ExitCode -ne 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_e9ae1d4da44d99f5' -Arguments @{ unit = "$unit"; output = "$($r.Output)" }) }
    }.GetNewClosure()
}

# --- REGION: Group membership
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
    if ($PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_50d00b7a87dd80cf' -Arguments @{ uSER = "$env:USER"; grp = "$grp" }), (Format-YurunaOperatorMessage -Key 'host.operator_f61cceb0afee5ae4'))) {
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
} elseif ($PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_410c0c308f73c958' -Arguments @{ hOME = "$HOME" }), (Format-YurunaOperatorMessage -Key 'host.operator_f61cceb0afee5ae4'))) {
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
    } elseif ($PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_88043c49f7b71195' -Arguments @{ statusPort = "$statusPort" }), (Format-YurunaOperatorMessage -Key 'host.operator_503158d3bf5fcbd6'))) {
        $r = Invoke-YurunaSudo -Argument @($ufwExe, '--force', 'delete', 'allow', "$statusPort/tcp") -TolerateBlocked
        if ($r.ExitCode -eq 0) { $restored.Add("ufw rule removed: allow $statusPort/tcp") }
        else { $skipped.Add("ufw allow $statusPort/tcp (delete failed: $($r.Output))") }
    }
}

# --- REGION: Services (opt-in)
if ($StopServices) {
    Stop-YurunaServiceVMSet -RepoRoot $RepoRoot -Cmdlet $PSCmdlet -Restored $restored -Skipped $skipped
}

# --- REGION: Report
Write-DisableReport -Platform 'ubuntu.kvm' -Restored $restored -Skipped $skipped

Write-Output ''
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_87f50089fdd7e8c5')
Write-DisableManualStep -What (Format-YurunaOperatorMessage -Key 'host.operator_f08765755eb06413') -Command @(
    (Format-YurunaOperatorMessage -Key 'host.operator_8da23b13d6bee38a')
)
Write-DisableManualStep -What (Format-YurunaOperatorMessage -Key 'host.operator_67dd1ec8d0469702') -Command @(
    'sudo virsh net-list --all',
    'sudo virsh list --all'
)
Write-DisableManualStep -What (Format-YurunaOperatorMessage -Key 'host.operator_51ad715d8bf6eabf')
Write-DisableManualStep -What (Format-YurunaOperatorMessage -Key 'host.operator_c65c4b6881513631') `
    -Command (Get-PoolStorageManualTeardown -RepoRoot $RepoRoot)
Write-DisableManualStep -What (Format-YurunaOperatorMessage -Key 'host.operator_2407762573afa1d1') -Command @(
    'sudo ls /etc/sudoers.d/ | grep -i yuruna'
)
Write-DisableCommonEpilogue -StateCaptured ([bool]$state) -StopServices ([bool]$StopServices)
