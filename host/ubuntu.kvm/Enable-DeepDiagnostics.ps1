<#PSScriptInfo
.VERSION 2026.11.05
.GUID 425cc5e5-e328-424c-b2e0-20ce8ca052ee
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host ubuntu kvm enable-deep-diagnostics freeze evidence
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
    Puts an Ubuntu KVM host into deep diagnostics mode, so a hard freeze
    leaves evidence behind.
.DESCRIPTION
    Turns lockups and oopses into a panic that reboots after 30 seconds, keeps
    crash records in UEFI storage, arms the hardware watchdog through systemd,
    syncs a persistent journal every 10 seconds, installs rasdaemon, logs host
    vitals every 10 seconds, writes an evidence bundle at every boot and, with
    -NetconsoleTarget, sends kernel messages to another machine as they happen.
    The planned changes are shown first, each value as 'key: previous -> new',
    and every prior value is recorded in
    /var/lib/yuruna/deep-diagnostics/state.json before the first change.
    Disable-DeepDiagnostics.ps1 restores the host from that record. Running
    this again changes only what drifted. The host/ubuntu.kvm README section
    "Deep diagnostics mode" covers the evidence and the caveats.

    Exit codes: 0 every component applied or skipped with a reason, 1 refused
    before changing anything, 2 a component failed and the others are in place.

.PARAMETER NetconsoleTarget
    IPv4 address of the machine running test/lab/Receive-Netconsole.ps1, with
    an optional :port (default 6666). Omitted, a target from an earlier run is
    kept, and with none netconsole is skipped.

.PARAMETER WhatIf
    Shows the planned changes without applying any.

.EXAMPLE
    pwsh host/ubuntu.kvm/Enable-DeepDiagnostics.ps1 -WhatIf
.EXAMPLE
    pwsh host/ubuntu.kvm/Enable-DeepDiagnostics.ps1 -NetconsoleTarget 192.168.1.20:6666
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$NetconsoleTarget = ''
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'

# --- REGION: Initialize
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $PSScriptRoot 'modules/Yuruna.Host.DeepDiagnostics.psm1') -Force -DisableNameChecking

# --- REGION: Platform guard
$refusal = Get-DeepDiagnosticsRefusal -NetconsoleTarget $NetconsoleTarget
if ($refusal) {
    Write-Error $refusal
    exit 1
}

# --- REGION: Plan
# Read without privilege, so -WhatIf shows the whole plan with no password.
try {
    $plan = Get-DeepDiagnosticsPlan -NetconsoleTarget $NetconsoleTarget
} catch {
    Write-Error "$($_.Exception.Message)"
    exit 1
}
Write-DeepDiagnosticsPlan -Plan $plan -InformationAction Continue

# --- REGION: Prime sudo
# Once, with the reasons on screen; every privileged command after it runs
# through sudo -n. Under -WhatIf nothing privileged runs, and when the host and
# the state file are both current nothing is written, so nothing is asked.
if (-not $WhatIfPreference -and -not $plan.StateCurrent) {
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostCondition.psm1') -Force -DisableNameChecking
    [void](Initialize-SudoCache -Reasons @(
            'write sysctl, systemd, journald, module and NetworkManager drop-ins named yuruna-deep-diagnostics',
            'sysctl -w for the kernel panic, lockup and console settings',
            'modprobe the pstore, watchdog and netconsole drivers',
            'apt-get install rasdaemon when it is missing',
            'systemctl enable / start the yuruna units, daemon-reexec, restart journald',
            'write /var/lib/yuruna/deep-diagnostics/state.json'
        ))
}

# --- REGION: Apply
$common = @{ InformationAction = 'Continue' }
foreach ($name in @('WhatIf', 'Confirm')) {
    if ($PSBoundParameters.ContainsKey($name)) { $common[$name] = $PSBoundParameters[$name] }
}
$result = Invoke-DeepDiagnosticsEnable -Plan $plan @common
exit $result.ExitCode
