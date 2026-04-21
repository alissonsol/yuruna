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
      * Accessibility permission prompt if not already granted
    Requires sudo (pmset, defaults write /Library/Preferences, sysadminctl).
    Idempotent — safe to run multiple times.

    Run this before Invoke-TestRunner.ps1 when Assert-HostConditionSet
    reports that screen lock or display sleep settings will blank the VM
    display during tests.

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
