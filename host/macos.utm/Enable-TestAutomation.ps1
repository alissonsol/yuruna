<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456754
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
    Prepares the macOS UTM host to run yuruna automated VM tests.

.DESCRIPTION
    Configures host-side settings needed for unattended, long-running test
    runs against UTM guest VMs:
      * display sleep, system sleep, disk sleep -> Never
      * screen saver idle time + password -> disabled (user + currentHost)
      * sysadminctl unified screen lock -> off (Ventura+)
      * AutoLogOutDelay -> 0 (kills "Log out after N min of inactivity")
      * App Nap for UTM.app -> suppressed
      * UTM.app survives its last window closing -> on, so closing a VM
        window no longer terminates UTM and suspends every running VM
        (the caching proxy and stash services included)
      * Power Nap / standby / auto-poweroff / hibernation -> all off
      * lid-close (clamshell) sleep -> disabled, so a MacBook keeps running
        its cycle with the lid shut
      * hot corners bound to Start Screen Saver / Display Sleep / Lock
        Screen -> neutralized
      * AppleSpacesSwitchOnActivation -> false (UTM activate during a run
        no longer yanks the operator off another macOS Space -- e.g. when
        debugging in VS Code on a different desktop while the runner is
        going through an AVF-guest keystroke step)
      * Accessibility permission prompt (keystroke injection)
      * Screen Recording permission prompt (window enumeration + per-window
        screen capture -- a separate TCC bucket from Accessibility)

    Manual one-time step (intentionally NOT scripted -- Dock plist editing
    is fragile): right-click UTM in the Dock -> Options -> Assign To -> All
    Desktops. With this and AppleSpacesSwitchOnActivation off, you can
    leave a long Invoke-TestRunner cycle running in its own Space and
    debug in VS Code on another Space without disruption.
    Requires sudo (pmset, defaults write /Library/Preferences, sysadminctl).
    Every elevated write goes out as `sudo -n` after probing that root is
    reachable, so a host that cannot elevate reports the exact command to run
    instead of raising a password prompt where nobody can answer it.
    Idempotent -- safe to run multiple times.

    Exits 0 when every condition is in place and 2 when the settings were
    applied but something still needs an operator (an account password only a
    person can type, an MDM profile enforcing a lock). Re-running does not clear
    a 2, which is why it is not reported as an outright failure.

    Run this before Invoke-TestRunner.ps1. Assert-HostConditionSet gates
    every subsequent cycle on both permissions and on screen-lock /
    display-sleep settings.

    IMPORTANT: the Accessibility and Screen Recording prompts fire only on
    the FIRST request per process. If you dismiss either one, macOS will
    not ask again -- you must toggle it manually in System Settings and
    FULLY QUIT / relaunch the terminal (TCC grants don't apply to the
    already-running process).

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
    'systemsetup -setusingnetworktime + sntp -sS (host clock discipline)'
)

# --- REGION: pre-automation capture
# BEFORE anything is changed: record what these knobs were, so
# Disable-TestAutomation can put them back. Written once and never overwritten
# -- a second Enable must not capture Enable's own values as the operator's.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostAutomationState.psm1') -Force -DisableNameChecking
$capturePath = Save-HostAutomationState -Platform 'macos.utm' -WhatIf:$WhatIfPreference
if ($capturePath) { Write-Information "Captured prior host settings to $capturePath (Disable-TestAutomation restores from it)." }

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

# --- REGION: networkStorage pool host-identity setup + reimage reclaim (interactive)
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

# --- REGION: outcome
# The exit code is the only failure channel across the child-process boundary:
# everything this script says about a setting it could not apply goes to a
# captured log the orchestrator does not read, so an explicit exit is the one
# way that host is distinguishable from a clean success. Falling off the end
# gives 0.
#
#   0  every condition is in place
#   1  the script threw (ErrorActionPreference stops it before this line)
#   2  the settings were applied and some condition remains unmet
#
# 2 is deliberately not 1. Everything at 2 is a host that needs an operator --
# a password only a person can type, a Configuration Profile enforcing a lock --
# and re-running this script cannot clear any of it, so a caller that treats it
# as a failed step would advise a re-run that changes nothing. The caller maps
# it to a warned outcome; see install/setup.ps1's host-settings step.
if ($unmetCount -gt 0) {
    Write-Warning "Host settings applied, but $unmetCount condition(s) still need an operator (listed above)."
    exit 2
}
exit 0
