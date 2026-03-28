<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456760
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
    Drives the Amazon Linux guest through first boot to a usable state.

.DESCRIPTION
    Amazon Linux boots from a pre-built disk image with cloud-init.
    No interactive OS installation is needed. This script waits for
    cloud-init to finish configuring the system.

    == TRAINING GUIDE ==

    This guest requires no keystroke automation. If your image ever
    changes to require interaction (e.g., a GRUB menu), add steps below
    following the pattern used in Test-Start.guest.windows.11.ps1.

    To add a wait-for-prompt step:
      1. Start the VM manually and observe the boot sequence.
      2. Note the time (in seconds after VM start) when the prompt appears.
      3. Add a Start-Sleep and keystroke call at that point.

.NOTES
    Exit 0 = OS is ready, non-zero = boot failed or timed out.
#>

param(
    [string]$HostType,
    [string]$GuestKey,
    [string]$VMName
)

Write-Output "[$GuestKey] Amazon Linux boots from a pre-built image with cloud-init."
Write-Output "[$GuestKey] No interactive installation steps required."

# Cloud-init typically completes within 30-60 seconds after VM reports running.
# The Verify-VM step (with boot delay) handles this wait.

exit 0
