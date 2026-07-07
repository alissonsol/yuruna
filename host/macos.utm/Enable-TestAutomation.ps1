<#PSScriptInfo
.VERSION 2026.07.07
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
      * Power Nap / standby / auto-poweroff / hibernation -> all off
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
    Idempotent -- safe to run multiple times.

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
param()

$ErrorActionPreference = "Stop"

# Surface the module's action-taken messages (Set-MacHostConditionSet
# reports each setting via Write-Information). Without Continue, the
# display-sleep / screen-lock / hot-corner / Spaces decisions print
# nothing and the operator can't tell what changed.
$InformationPreference = 'Continue'

# Shared bootstrap (Test.HostContract import + powershell-yaml +
# PSScriptAnalyzer install) lives in automation/Yuruna.HostSetup.psm1.
# Rationale + ordering are documented there.
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.HostSetup.psm1') -Force
Initialize-HostSetupModule -RepoRoot $RepoRoot -BoundParameters $PSBoundParameters

Set-MacHostConditionSet @PSBoundParameters

# --- REGION: networkStorage pool host-identity setup + reimage reclaim (interactive)
# Offer to configure networkStorage pool (NAS replication) and, on a host with no local
# pool identity, scan the NAS registry to reclaim a prior uuid after a reimage.
# Self-skips cleanly when run non-interactively or under -WhatIf. The orchestrator
# loads its own sibling dependencies (config/vault/mount). See docs/pool-storage.md.
if (-not $WhatIfPreference) {
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostIdentity.psm1') -Force
    Invoke-PoolStorageSetupAndReclaim -RepoRoot $RepoRoot
}
