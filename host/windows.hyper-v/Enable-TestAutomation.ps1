<#PSScriptInfo
.VERSION 2026.09.13
.GUID 4256c18e-dd7e-400d-aa57-445e74e55994
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host windows hyper-v enable-test-automation
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
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Prepares the Windows Hyper-V host to run yuruna automated VM tests.

.DESCRIPTION
    Captures the host's original settings once, then applies the platform's
    unattended-test prerequisites and optional pool-storage setup. Re-running
    preserves the original capture used by Disable-TestAutomation.ps1.
    See https://yuruna.link/42e220c4-0004 and https://yuruna.link/42dc5bb9-0001.
    Run as Administrator. After a display-scale change, sign out and back in
    before testing so the compositor uses the new scale.

.PARAMETER WhatIf
    Shows what would change without applying any settings.

.EXAMPLE
    .\Enable-TestAutomation.ps1
    .\Enable-TestAutomation.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    # Settings-only run: skip the interactive networkStorage questionnaire at the
    # end. install/setup.ps1 configures storage itself, in its own order, and
    # would otherwise ask the same questions twice.
    [switch]$SkipPoolStorage
)

$ErrorActionPreference = "Stop"
# Set-WindowsHostConditionSet reports each setting it touches via
# Write-Information; without Continue the display-scale, screen-lock and
# display-timeout decisions print nothing and the operator cannot tell what
# changed.
$InformationPreference = 'Continue'
# --- REGION: Initialize host setup
# Shared bootstrap (Test.HostContract import + powershell-yaml +
# PSScriptAnalyzer install) lives in automation/Yuruna.HostSetup.psm1.
# Rationale + ordering are documented there.
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.HostSetup.psm1') -Force
Initialize-HostSetupModule -RepoRoot $RepoRoot -BoundParameters $PSBoundParameters

# --- REGION: Pre-automation capture
# BEFORE anything is changed: record what these knobs were, so
# Disable-TestAutomation can put them back. Written once and never overwritten
# -- a second Enable must not capture Enable's own values as the operator's.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostAutomationState.psm1') -Force -DisableNameChecking
$capturePath = Save-HostAutomationState -Platform 'windows.hyper-v' -WhatIf:$WhatIfPreference
if ($capturePath) { Write-Information "Captured prior host settings to $capturePath (Disable-TestAutomation restores from it)." }

# --- REGION: Host condition set
# -SkipPoolStorage is ours, not Set-WindowsHostConditionSet's; splatting it
# through would fail parameter binding.
$conditionArgs = @{}
foreach ($k in $PSBoundParameters.Keys) { if ($k -ne 'SkipPoolStorage') { $conditionArgs[$k] = $PSBoundParameters[$k] } }
# Select the count out of whatever came back rather than casting the lot.
# Set-WindowsHostConditionSet shells out to powercfg, dism and w32tm, and one
# uncaptured line from any of them would make its return an array -- which a
# straight [int] cast turns into a thrown error, converting a cosmetic leak into
# a failed setup step.
$conditionResult = @(Set-WindowsHostConditionSet @conditionArgs)
$unmetCount = @($conditionResult | Where-Object { $_ -is [int] } | Select-Object -Last 1)
$unmetCount = if ($unmetCount.Count) { [int]$unmetCount[0] } else { 0 }

# --- REGION: Pool storage and host identity
# Offer to configure networkStorage pool (NAS replication) and, on a host with no local
# pool identity, scan the NAS registry to reclaim a prior uuid after a reimage.
# Self-skips cleanly when run non-interactively or under -WhatIf. The orchestrator
# loads its own sibling dependencies (config/vault/mount). See docs/pool-storage.md.
if ($SkipPoolStorage) {
    Write-Information 'Skipping the networkStorage questionnaire (-SkipPoolStorage).'
} elseif (-not $WhatIfPreference) {
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostIdentity.psm1') -Force
    Invoke-PoolStorageSetupAndReclaim -RepoRoot $RepoRoot
}

# The virtual display is opt-in (see header) and deliberately NOT set here: it
# changes the host's monitor topology / scaling, so it stays an explicit
# operator choice. Test-YurunaVirtualDisplayEnabled resolves the live process
# variable first, then the persisted User/Machine scope, so this reflects what
# the runner will actually do rather than this shell's (possibly stale)
# process block. See docs/host-hyperv.md.
if (Test-YurunaVirtualDisplayEnabled) {
    Write-Information "YURUNA_VIRTUAL_DISPLAY is enabled -- each test cycle will attach a virtual display, so screen-capture/OCR survives running without a connected monitor. To turn it off: [Environment]::SetEnvironmentVariable('YURUNA_VIRTUAL_DISPLAY', `$null, 'Machine'); `$env:YURUNA_VIRTUAL_DISPLAY = `$null"
} else {
    Write-Information @"
YURUNA_VIRTUAL_DISPLAY is not enabled. Leave it off if this host always has a
connected monitor while tests run. If it will operate WITHOUT a connected
display (headless box, closed laptop lid, or a KVM switch that can drop the
monitor mid-run), enable it so each test cycle attaches a virtual display and
screen-capture/OCR doesn't go all-black:

  # persist across sessions (this script runs elevated). The runner reads this
  # scope directly, so it takes effect on the next cycle even when launched from
  # this shell -- though 'dir env:' won't show it until you open a new terminal:
  [Environment]::SetEnvironmentVariable('YURUNA_VIRTUAL_DISPLAY', 'true', 'Machine')

  # or just this shell, for a one-off run (not persisted):
  `$env:YURUNA_VIRTUAL_DISPLAY = 'true'

See docs/host-hyperv.md for what it attaches (checksum-pinned usbmmidd_v2) and the manual fallbacks.
"@
}

# --- REGION: Outcome
# See https://yuruna.link/42e220c4-0004 for the shared 0/1/2 host-setup contract.
if ($unmetCount -gt 0) {
    Write-Warning "Host settings applied, but $unmetCount condition(s) still need an operator (listed above)."
    exit 2
}
exit 0
