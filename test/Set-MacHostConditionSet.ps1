<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456750
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
    Configures macOS host settings needed for unattended VM testing.

.DESCRIPTION
    Disables display sleep, screen saver idle activation, and screen lock
    password.  Also triggers the Accessibility permission prompt if not
    already granted.  Requires sudo for pmset.  Idempotent.

    Run this script before Invoke-TestRunner.ps1 when Assert-HostConditionSet
    reports that screen lock or display sleep settings will blank the VM display.

.PARAMETER WhatIf
    Shows what would change without applying any settings.

.EXAMPLE
    ./Set-MacHostConditionSet.ps1
    ./Set-MacHostConditionSet.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = "Stop"
$TestRoot = $PSScriptRoot

$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"
Import-Module (Join-Path -Path $TestRoot -ChildPath "modules" -AdditionalChildPath "Test.Host.psm1") -Force
$global:VerbosePreference = $savedVerbose

Set-MacHostConditionSet @PSBoundParameters
