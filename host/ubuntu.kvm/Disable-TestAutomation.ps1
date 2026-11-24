<#PSScriptInfo
.VERSION 2026.11.23
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
# Resolve-ConfigServiceStart: the config service port, as the runner starts it.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.Prelude.psm1')             -Force -DisableNameChecking
# Get-YurunaStatusFirewallRuleComment: the comment on every ufw rule Yuruna adds.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.StatusFirewall.psm1')      -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Common.psm1')              -Force -DisableNameChecking

if (-not (Assert-SafeToDisable)) { exit 1 }

# --- REGION: Host update in progress
# A claimed host update has stopped the runner, or is about to start it, and
# only its controller finishes that. Stopping the controller here would leave
# the host with no runner and nothing to start one. A queued update is no
# reason to refuse: once the controller is stopped nothing claims it, and it
# expires on its own. The controller can still claim it before the stop, so
# the queue is read again once the controller is stopped. A journal that
# cannot be read can hide a claimed update, so it refuses too.
# A module imported inside another one is not visible here, so each module
# this script calls is imported by name.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.SingleFlightLock.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostOperationJournal.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostUpdate.psm1') -Force -DisableNameChecking
$journalReadable = @('ok', 'absent', 'recovered-previous')
$queue = Get-HostUpdateQueue
if ($queue.Status -notin $journalReadable) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.host_controller_update_unknown' -Arguments @{ status = "$($queue.Status)" })
    exit 1
}
if ($queue.Claimed) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.host_controller_update_claimed' -Arguments @{ requestId = "$($queue.Claimed['requestId'])" })
    exit 1
}

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
# See https://yuruna.link/42e220c4-0004
# Pass the script's bound cmdlet: WhatIf preferences do not cross module scope.
$Script:DisableCmdlet = $PSCmdlet

# --- REGION: Restore-Knob
function Restore-Knob {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Apply,
        [scriptblock]$Absent
    )
    Invoke-HostKnobRestore -State $state -Name $Name -Description $Description `
        -Apply $Apply -Absent $Absent -Cmdlet $Script:DisableCmdlet -Restored $restored -Skipped $skipped
}

# --- REGION: Prime sudo
# Prime sudo once, before the run, with the reasons visible -- the same posture
# Enable uses. Under -WhatIf nothing elevated actually runs, so skip the prompt.
if (-not $WhatIfPreference) {
    [void](Initialize-SudoCache -Reasons @(
        'ufw status, and ufw delete for each allow rule Yuruna marked as its own',
        'systemctl disable libvirtd / virtlogd (only when the capture says they were off)',
        'gpasswd -d (only when the capture says this user was not a member)',
        'systemctl stop / disable yuruna-host-controller.service, rm its unit file, daemon-reload',
        'rm -f /etc/sudoers.d/yuruna-host-update and systemctl stop of its expiry timer (a rule a host update left)'
    ))
}

# --- REGION: Host controller
# See https://yuruna.link/42f909ad-002b
# Removed with or without a capture: Enable generates the unit and deploys
# the controller files, so nothing of the operator's is in them. The
# controller files go only once nobody holds the controller lock; a stop
# signals only the shim (KillMode=process), which passes it on and waits.
$controllerUnit = 'yuruna-host-controller.service'
$controllerUnitPath = '/etc/systemd/system/yuruna-host-controller.service'
$controllerRoot = Get-HostUpdateControllerRoot -NoCreate
$keepController = $false
# No unit, or one stopped and removed: no controller can be using a sudo rule.
$controllerGone = -not [System.IO.File]::Exists($controllerUnitPath)
if ([System.IO.File]::Exists($controllerUnitPath) -and
    $PSCmdlet.ShouldProcess($controllerUnit, (Format-YurunaOperatorMessage -Key 'host.operator_f61cceb0afee5ae4'))) {
    $failed = $null
    $r = Invoke-YurunaSudo -Argument @('systemctl', 'stop', $controllerUnit) -TolerateBlocked
    if ($r.ExitCode -ne 0) { $failed = "systemctl stop $($controllerUnit): $($r.Output)" }
    # Stopped, the controller claims nothing more; one claimed before the
    # stop, or one a journal that cannot be read may hide, is continued by
    # starting the controller again.
    $queueNow = if (-not $failed) { Get-HostUpdateQueue } else { $null }
    $unknownNow = $queueNow -and $queueNow.Status -notin $journalReadable
    if ($unknownNow -or ($queueNow -and $queueNow.Claimed)) {
        $keepController = $true
        $start = Invoke-YurunaSudo -Argument @('systemctl', 'start', $controllerUnit) -TolerateBlocked
        $startDetail = "systemctl start $($controllerUnit): $($start.Output)"
        if ($unknownNow) {
            if ($start.ExitCode -eq 0) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.host_controller_update_unknown' -Arguments @{ status = "$($queueNow.Status)" })
                exit 1
            }
            $skipped.Add((Format-YurunaOperatorMessage -Key 'host.host_controller_update_unknown_not_restarted' -Arguments @{
                        status = "$($queueNow.Status)"; detail = $startDetail }))
        } else {
            if ($start.ExitCode -eq 0) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.host_controller_update_claimed' -Arguments @{ requestId = "$($queueNow.Claimed['requestId'])" })
                exit 1
            }
            $skipped.Add((Format-YurunaOperatorMessage -Key 'host.host_controller_update_claimed_not_restarted' -Arguments @{
                        requestId = "$($queueNow.Claimed['requestId'])"; detail = $startDetail }))
        }
    } elseif (-not $failed) {
        foreach ($step in @(@('systemctl', 'disable', $controllerUnit), @('rm', '-f', $controllerUnitPath), @('systemctl', 'daemon-reload'))) {
            $r = Invoke-YurunaSudo -Argument $step -TolerateBlocked
            if ($r.ExitCode -ne 0) { $failed = "$($step -join ' '): $($r.Output)"; break }
        }
    }
    if ($failed) { $skipped.Add((Format-YurunaOperatorMessage -Key 'host.host_controller_unit_not_removed' -Arguments @{ detail = "$failed" })) }
    elseif (-not $keepController) {
        $restored.Add((Format-YurunaOperatorMessage -Key 'host.host_controller_unit_removed'))
        $controllerGone = $true
    }
}
# The temporary sudo rule of the full scope, should a host update have left
# one: no update is claimed and no controller runs, so none is using it. rm -f
# also succeeds when there is none, which a test account cannot see in
# /etc/sudoers.d.
if ($controllerGone -and -not $keepController -and -not $WhatIfPreference -and -not (Remove-HostUpdateSudoRule -Confirm:$false)) {
    $skipped.Add((Format-YurunaOperatorMessage -Key 'host.host_update_rule_not_removed'))
}
if (-not $keepController -and $controllerRoot -and [System.IO.Directory]::Exists($controllerRoot) -and
    $PSCmdlet.ShouldProcess($controllerRoot, (Format-YurunaOperatorMessage -Key 'host.operator_f61cceb0afee5ae4'))) {
    $lockState = Get-HostUpdateControllerLockState
    for ($i = 0; $i -lt 60 -and $lockState -notin @('free', 'absent'); $i++) {
        Start-Sleep -Milliseconds 500
        $lockState = Get-HostUpdateControllerLockState
    }
    if ($lockState -notin @('free', 'absent')) {
        $skipped.Add((Format-YurunaOperatorMessage -Key 'host.host_controller_files_kept' -Arguments @{ path = "$controllerRoot" }))
    } else {
        try {
            [System.IO.Directory]::Delete($controllerRoot, $true)
            $restored.Add((Format-YurunaOperatorMessage -Key 'host.host_controller_files_removed' -Arguments @{ path = "$controllerRoot" }))
        } catch {
            $skipped.Add((Format-YurunaOperatorMessage -Key 'host.host_controller_files_not_removed' -Arguments @{ path = "$controllerRoot"; message = "$($_.Exception.Message)" }))
        }
    }
}

# --- REGION: GNOME idle / lock / dim
foreach ($t in (Get-LinuxAutomationGsetting)) {
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
# The capture is written once, so it can hold no record of a group Enable came
# to manage later; such a membership is left as it is too.
foreach ($grp in @('libvirt', 'kvm', 'systemd-journal')) {
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

# --- REGION: Status-service LAN reachability (host firewall)
# Removed with or without a capture, because a rule says itself whether it is
# ours: every ufw rule Yuruna adds -- Enable's, for the status and config
# service ports, and the one either service's launcher adds for its own port --
# carries the comment Get-YurunaStatusFirewallRuleComment returns. A rule with
# it goes whatever its port, so one added before the configured port changed
# goes too. An allow rule on either configured port without it was added by
# someone else, or by an older version before rules were marked; it stays, and
# the report gives the command that removes it.
$statusPort = 8080
$tc = $null
$configPath = Join-Path $RepoRoot 'test/test.config.yml'
if (Test-Path -LiteralPath $configPath) {
    try {
        $tc = Read-TestConfig -Path $configPath
        if ($tc -and $tc.statusService -and $tc.statusService.port) { $statusPort = [int]$tc.statusService.port }
    } catch { Write-Verbose "status port read: $($_.Exception.Message)" }
}
$configPort = (Resolve-ConfigServiceStart -Config $tc).Port
$servicePorts = @($statusPort, $configPort | Select-Object -Unique)
$ufwCmd = Get-Command ufw -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $ufwCmd) {
    foreach ($port in $servicePorts) { $skipped.Add("ufw allow $port/tcp (ufw is not installed)") }
} else {
    # The absolute path: ufw lives in /usr/sbin, which is not on an
    # unprivileged PATH, and 'sudo ufw' would then read as "not installed".
    $ufwExe = if ($ufwCmd.Source) { $ufwCmd.Source } else { 'ufw' }
    $status = Invoke-YurunaSudo -Argument @($ufwExe, 'status') -TolerateBlocked
    if ($status.ExitCode -ne 0) {
        foreach ($port in $servicePorts) { $skipped.Add("ufw allow $port/tcp (could not read ufw status: $($status.Output))") }
    } else {
        $marker = Get-YurunaStatusFirewallRuleComment
        # An inbound rule's line is its To, Action and From columns, then
        # ' # <comment>' when it has one. The '(v6)' twin of a rule from
        # Anywhere does not match, and the same delete removes it. A line with
        # more columns (logging, a source port, an outbound rule) is no shape
        # Yuruna adds, and is left alone.
        $allowLines = @([regex]::Matches($status.Output, '(?m)^[ \t]*(?<port>\d+)/tcp[ \t]+ALLOW[ \t]+(?<from>\S+)(?:[ \t]+#[ \t](?<comment>[^\r\n]*?))?[ \t]*\r?$'))
        foreach ($port in $servicePorts) {
            if (-not @($allowLines | Where-Object { $_.Groups['port'].Value -eq "$port" }).Count) { Write-Verbose "ufw has no allow rule for $port/tcp." }
        }
        foreach ($line in $allowLines) {
            $port = [int]$line.Groups['port'].Value
            $from = $line.Groups['from'].Value
            # The rule as ufw takes it, so the delete and the command in the
            # report address this rule and not another on the same port.
            $ruleArgs = if ($from -ceq 'Anywhere') { @('allow', "$port/tcp") } else { @('allow', 'from', $from, 'to', 'any', 'port', "$port", 'proto', 'tcp') }
            $rule = $ruleArgs -join ' '
            if ($line.Groups['comment'].Value -cne $marker) {
                if ($servicePorts -contains $port) {
                    $skipped.Add("ufw $rule (it has no '$marker' comment: someone added it by hand, or an older Yuruna version did before it marked its rules; to remove it: sudo ufw delete $rule)")
                }
                continue
            }
            $action = if ($port -eq $statusPort) { (Format-YurunaOperatorMessage -Key 'host.operator_503158d3bf5fcbd6') }
                      elseif ($port -eq $configPort) { (Format-YurunaOperatorMessage -Key 'host.kvm_config_port_rule_delete') }
                      else { (Format-YurunaOperatorMessage -Key 'host.operator_b15dd410559b0438') }
            if ($PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_88043c49f7b71195' -Arguments @{ statusPort = "$port" }), $action)) {
                # Named with its comment, ufw deletes only the marked rule: it
                # matches a delete without one to an unmarked rule as well.
                $r = Invoke-YurunaSudo -Argument (@($ufwExe, '--force', 'delete') + $ruleArgs + @('comment', $marker)) -TolerateBlocked
                if ($r.ExitCode -eq 0) { $restored.Add("ufw rule removed: $rule") }
                else { $skipped.Add("ufw $rule (delete failed: $($r.Output))") }
            }
        }
    }
}

# --- REGION: Host clock
Restore-Knob -Name 'timedatectl/ntp' -Description 'timedatectl NTP' -Apply {
    param($v)
    $onOff = if ("$v" -match '^(yes|active|true)$') { 'true' } else { 'false' }
    $r = Invoke-YurunaSudo -Argument @('timedatectl', 'set-ntp', $onOff) -TolerateBlocked
    if ($r.ExitCode -ne 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_b1cc462acbad03b8' -Arguments @{ onOff = "$onOff"; output = "$($r.Output)" }) }
}

# --- REGION: Services (opt-in)
if ($StopServices) {
    Stop-YurunaServiceVMSet -RepoRoot $RepoRoot -Cmdlet $Script:DisableCmdlet -Restored $restored -Skipped $skipped
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
