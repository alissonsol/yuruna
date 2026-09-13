<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42ff1bc2-5f12-4c34-8a53-a45f6186f94f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host macos utm enable-test-automation
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
    Prepares the macOS UTM host to run yuruna automated VM tests.

.DESCRIPTION
    Captures the host's original settings once, then applies the platform's
    unattended-test prerequisites and optional pool-storage setup. Re-running
    preserves the original capture used by Disable-TestAutomation.ps1.
    See https://yuruna.link/42e220c4-0004 and https://yuruna.link/42885ada-0001.
    Run without sudo. Individual privileged changes announce their requirements;
    macOS privacy grants and the account password still require the operator.
    Exit 2 means some settings still need operator attention.

.PARAMETER WhatIf
    Shows what would change without applying any settings.

.EXAMPLE
    ./Enable-TestAutomation.ps1
    ./Enable-TestAutomation.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    # Settings-only run: skip the interactive networkStorage questionnaire at the
    # end. install/setup.ps1 configures storage itself, in its own order, and
    # would otherwise ask the same questions twice.
    [switch]$SkipPoolStorage
)

$ErrorActionPreference = "Stop"

# Surface the module's action-taken messages (Set-MacHostConditionSet
# reports each setting via Write-Information). Without Continue, the
# display-sleep / screen-lock / hot-corner / Spaces decisions print
# nothing and the operator can't tell what changed.
$InformationPreference = 'Continue'

# --- REGION: Initialize host setup
# Shared bootstrap (Test.HostContract import + sudo prime + powershell-yaml +
# PSScriptAnalyzer install) lives in automation/Yuruna.HostSetup.psm1.
# -SudoCacheReason keeps the sudo prompt EARLY (before the two PSGallery
# installs, which on a freshly imaged Mac are a long silent wait) with a visible
# reason banner so the operator knows WHAT will need elevation before they
# consent. Set-MacHostConditionSet primes again below and is idempotent; when
# invoked via install/macos.utm.sh (YURUNA_SUDO_PRIMED=1) both are silent no-ops.
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.HostSetup.psm1') -Force
Initialize-HostSetupModule -RepoRoot $RepoRoot -BoundParameters $PSBoundParameters -SudoCacheReason @(
    'pmset (display sleep, system sleep, power-nap, hibernation)',
    'defaults write /Library/Preferences (auto-logout delay)',
    'sysadminctl -screenLock off (Sonoma+ unified screen lock)',
    'systemsetup -setusingnetworktime + sntp -sS (host clock discipline)',
    'ln -s into /usr/local/bin (utmctl, the UTM command line, on PATH)'
)

# --- REGION: Pre-automation capture
# BEFORE anything is changed: record what these knobs were, so
# Disable-TestAutomation can put them back. Written once and never overwritten
# -- a second Enable must not capture Enable's own values as the operator's.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostAutomationState.psm1') -Force -DisableNameChecking
$capturePath = Save-HostAutomationState -Platform 'macos.utm' -WhatIf:$WhatIfPreference
if ($capturePath) { Write-Information "Captured prior host settings to $capturePath (Disable-TestAutomation restores from it)." }

# --- REGION: Host condition set
# -SkipPoolStorage is ours, not Set-MacHostConditionSet's; splatting it through
# would fail parameter binding.
$conditionArgs = @{}
foreach ($k in $PSBoundParameters.Keys) { if ($k -ne 'SkipPoolStorage') { $conditionArgs[$k] = $PSBoundParameters[$k] } }
# Select the count out of whatever came back rather than casting the lot.
# Set-MacHostConditionSet shells out to pmset, defaults and sysadminctl, and one
# uncaptured line from any of them would make its return an array -- which a
# straight [int] cast turns into a thrown error, converting a cosmetic leak into
# a failed setup step.
$conditionResult = @(Set-MacHostConditionSet @conditionArgs)
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

# --- REGION: Outcome
# See https://yuruna.link/42e220c4-0004 for the shared 0/1/2 host-setup contract.
if ($unmetCount -gt 0) {
    Write-Warning "Host settings applied, but $unmetCount condition(s) still need an operator (listed above)."
    exit 2
}
exit 0
