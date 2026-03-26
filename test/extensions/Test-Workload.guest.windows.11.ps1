<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456722
.AUTHOR Alisson Sol
.COMPANYNAME None
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

<#
.SYNOPSIS
    Workload test for the Windows 11 guest.

.DESCRIPTION
    Runs after the guest VM has been created, started, and verified running.
    Use it to validate workloads, connectivity, or any guest-specific behaviour.
    See test/extensions/README.md for the full extension API.

.NOTES
    Exit 0 = pass, non-zero = fail (stops the runner and triggers notification).
#>

param(
    [string]$HostType,
    [string]$GuestKey,
    [string]$VMName
)

Write-Output "[$GuestKey] Custom test placeholder for VM '$VMName' on $HostType"
Write-Output "[$GuestKey] Replace this script with real validation (SSH check, workload run, etc.)"

exit 0
