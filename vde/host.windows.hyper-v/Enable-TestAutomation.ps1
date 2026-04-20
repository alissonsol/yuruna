<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456755
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
    Requires Administrator elevation. Idempotent — safe to re-run.

    Run this before Invoke-TestRunner.ps1 when Assert-HostConditionSet
    reports that display timeout or lock screen settings will interfere
    with test runs.

.PARAMETER WhatIf
    Shows what would change without applying any settings.

.EXAMPLE
    .\Enable-TestAutomation.ps1
    .\Enable-TestAutomation.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = "Stop"
# This script lives under vde\host.windows.hyper-v\ ; the module it
# delegates to is at test\modules\Test.Host.psm1 (two directory levels
# up plus the test\ subtree). The cross-folder import is the same
# pattern already used by Test.New-VM.psm1 -> vde\host.*\VM.common.psm1.
$ScriptDir  = $PSScriptRoot
$RepoRoot   = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$ModulePath = Join-Path $RepoRoot 'test\modules\Test.Host.psm1'

$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"
Import-Module $ModulePath -Force
$global:VerbosePreference = $savedVerbose

Set-WindowsHostConditionSet @PSBoundParameters
