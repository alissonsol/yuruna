<#PSScriptInfo
.VERSION 2026.05.29
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456755
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
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
    Configures host-side settings needed for unattended, long-running test
    runs against Hyper-V guest VMs:
      * starts the Hyper-V Virtual Machine Management service (vmms)
      * display timeout (AC + DC) → Never
      * machine inactivity lock → disabled
      * lock screen on resume → disabled
      * inbound ICMPv4 echo allowed (guest VMs + LAN can ping the host)
      * inbound TCP on the status-server port allowed (LAN can see status)
      * display scale / text scale → 100% (prevents Tesseract OCR failures
        on VM screenshots caused by HiDPI up-scaling on fresh Win11 laptops)
    Requires Administrator elevation. Idempotent — safe to re-run.

    Run this before Invoke-TestRunner.ps1 when Assert-HostConditionSet
    reports that display timeout or lock screen settings will interfere
    with test runs. If the scale reset fires on a machine that was at
    125% or 150%, sign out and back in (or reboot) before the next run
    so the compositor picks up the new DPI — OCR otherwise still sees
    the old scale.

.PARAMETER WhatIf
    Shows what would change without applying any settings.

.EXAMPLE
    .\Enable-TestAutomation.ps1
    .\Enable-TestAutomation.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = "Stop"
# Surface the module's action-taken messages (Set-WindowsHostConditionSet
# reports each setting via Write-Information). Without Continue, the
# display-scale + screen-lock + display-timeout decisions print nothing
# and the operator can't tell what changed -- contradicting the script's
# own header which promises to "inform" of each action.
$InformationPreference = 'Continue'
# This script lives under host\windows.hyper-v\ ; the module it
# delegates to is at test\modules\Test.Host.psm1 (two directory levels
# up plus the test\ subtree). The cross-folder import is the same
# pattern already used by Test.New-VM.psm1 -> host\<short-host>\modules\Yuruna.Host.psm1.
$ScriptDir  = $PSScriptRoot
$RepoRoot   = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$ModulePath = Join-Path $RepoRoot 'test\modules\Test.Host.psm1'

$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"
Import-Module $ModulePath -Force
$global:VerbosePreference = $savedVerbose

# Cycle planner reads project/test/test.sequence.yml and every per-sequence
# baseline via powershell-yaml. Missing here -> Resolve-CyclePlan throws ->
# inner runner falls back to legacy guestSequence -> Start-GuestOS runs with
# an empty sequence list and is recorded as "skipped" with no log trace.
[void](Install-PowerShellYamlIfMissing @PSBoundParameters)
[void](Install-PSScriptAnalyzerIfMissing @PSBoundParameters)

Set-WindowsHostConditionSet @PSBoundParameters
