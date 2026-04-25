<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456754
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
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
      * display sleep, system sleep, disk sleep → Never
      * screen saver idle time + password → disabled (user + currentHost)
      * sysadminctl unified screen lock → off (Ventura+)
      * AutoLogOutDelay → 0 (kills "Log out after N min of inactivity")
      * App Nap for UTM.app → suppressed
      * Power Nap / standby / auto-poweroff / hibernation → all off
      * hot corners bound to Start Screen Saver / Display Sleep / Lock
        Screen → neutralized
      * AppleSpacesSwitchOnActivation → false (UTM activate during a run
        no longer yanks the operator off another macOS Space — e.g. when
        debugging in VS Code on a different desktop while the runner is
        going through an AVF-guest keystroke step)
      * Accessibility permission prompt (keystroke injection)
      * Screen Recording permission prompt (window enumeration + per-window
        screen capture — a separate TCC bucket from Accessibility)

    Manual one-time step (intentionally NOT scripted — Dock plist editing
    is fragile): right-click UTM in the Dock → Options → Assign To → All
    Desktops. With this and AppleSpacesSwitchOnActivation off, you can
    leave a long Invoke-TestRunner cycle running in its own Space and
    debug in VS Code on another Space without disruption.
    Requires sudo (pmset, defaults write /Library/Preferences, sysadminctl).
    Idempotent — safe to run multiple times.

    Run this before Invoke-TestRunner.ps1. Assert-HostConditionSet gates
    every subsequent cycle on both permissions and on screen-lock /
    display-sleep settings.

    IMPORTANT: the Accessibility and Screen Recording prompts fire only on
    the FIRST request per process. If you dismiss either one, macOS will
    not ask again — you must toggle it manually in System Settings and
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
# Cross-folder import: script lives under virtual/host.macos.utm/; delegated
# module is at test/modules/Test.Host.psm1 (two levels up, then test/).
# Same pattern as Test.New-VM.psm1 -> virtual/host.macos.utm/VM.common.psm1.
$ScriptDir = $PSScriptRoot
$RepoRoot  = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$ModulePath = Join-Path $RepoRoot "test/modules/Test.Host.psm1"

$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"
Import-Module $ModulePath -Force
$global:VerbosePreference = $savedVerbose

Set-MacHostConditionSet @PSBoundParameters
