<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456751
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
    Configures Windows host settings needed for unattended VM testing.

.DESCRIPTION
    Starts the Hyper-V management service, disables display timeout (AC and DC),
    disables the machine inactivity lock, and disables lock screen on resume.
    Requires Administrator elevation.  Idempotent.

    Run this script before Invoke-TestRunner.ps1 when Assert-HostConditionSet
    reports that display timeout or lock screen settings will interfere with
    test runs.

.PARAMETER WhatIf
    Shows what would change without applying any settings.

.EXAMPLE
    ./Set-WindowsHostConditionSet.ps1
    ./Set-WindowsHostConditionSet.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = "Stop"
$TestRoot = $PSScriptRoot

$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"
Import-Module (Join-Path -Path $TestRoot -ChildPath "modules" -AdditionalChildPath "Test.Host.psm1") -Force
$global:VerbosePreference = $savedVerbose

Set-WindowsHostConditionSet @PSBoundParameters
