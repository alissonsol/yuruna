<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42b47d8f-871e-450a-a09f-784da333c78b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host ubuntu kvm disable-deep-diagnostics restore
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
    Takes an Ubuntu KVM host out of deep diagnostics mode and restores what
    Enable-DeepDiagnostics.ps1 changed.
.DESCRIPTION
    Reads /var/lib/yuruna/deep-diagnostics/state.json and reverts exactly what
    it records: every runtime sysctl goes back to its recorded value (reported
    as 'key: current -> restored'), the files, units and hooks Enable created
    are removed and a file it replaced gets its earlier content back, the
    netconsole target is removed, systemd re-reads its configuration, journald
    restarts, rasdaemon is purged only when Enable installed it (the packages
    its install pulled in stay, and the plan says how to remove them), and
    drivers Enable loaded are unloaded when nothing uses them. The evidence
    bundles in /var/log/yuruna/deep-diagnostics stay unless -RemoveEvidence is
    given. A step that fails keeps the state file, so running this again
    finishes.

    Exit codes: 0 restored (or nothing to restore), 1 refused before changing
    anything, 2 partly restored.

.PARAMETER RemoveEvidence
    Also delete the evidence bundles, and /var/log/yuruna once nothing else is
    in it.

.PARAMETER WhatIf
    Shows what would be restored without changing anything.

.EXAMPLE
    pwsh host/ubuntu.kvm/Disable-DeepDiagnostics.ps1 -WhatIf
.EXAMPLE
    pwsh host/ubuntu.kvm/Disable-DeepDiagnostics.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$RemoveEvidence
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'

# --- REGION: Initialize
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $PSScriptRoot 'modules/Yuruna.Host.DeepDiagnostics.psm1') -Force -DisableNameChecking

# --- REGION: Platform guard
$refusal = Get-DeepDiagnosticsRefusal
if ($refusal) {
    Write-Error $refusal
    exit 1
}

# --- REGION: Plan
# Read without privilege, so -WhatIf shows the whole plan with no password.
$read = Read-DeepDiagnosticsState
if ($read.Error) {
    Write-Error $read.Error
    exit 1
}
$plan = Get-DeepDiagnosticsRestorePlan -State $read.State -RemoveEvidence:$RemoveEvidence
Write-DeepDiagnosticsRestorePlan -Plan $plan -InformationAction Continue
if (-not $read.State -and $plan.Items.Count -eq 0) { exit 0 }

# --- REGION: Prime sudo
# Once, with the reasons on screen; every privileged command after it runs
# through sudo -n. Under -WhatIf nothing privileged runs, so nothing is asked.
if (-not $WhatIfPreference) {
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostCondition.psm1') -Force -DisableNameChecking
    [void](Initialize-SudoCache -Reasons @(
            'remove the yuruna-deep-diagnostics drop-ins, units, hooks and scripts',
            'sysctl -w back to the recorded values',
            'systemctl disable / stop the yuruna units, daemon-reexec, restart journald',
            'modprobe -r the drivers deep diagnostics mode loaded, apt-get purge rasdaemon when it installed it',
            'remove /var/lib/yuruna/deep-diagnostics/state.json'
        ))
}

# --- REGION: Restore
$common = @{ InformationAction = 'Continue' }
foreach ($name in @('WhatIf', 'Confirm')) {
    if ($PSBoundParameters.ContainsKey($name)) { $common[$name] = $PSBoundParameters[$name] }
}
$result = Invoke-DeepDiagnosticsDisable -Plan $plan @common
exit $result.ExitCode
