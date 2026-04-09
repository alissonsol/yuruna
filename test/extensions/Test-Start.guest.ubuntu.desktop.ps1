<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456761
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
    Drives the Ubuntu Desktop guest through initial boot via a JSON sequence.

.DESCRIPTION
    Reads the interaction sequence from ../sequences/Test-Start.guest.ubuntu.desktop.json
    and executes each step (keystrokes, delays, waits) against the VM.

    To customize the boot automation, edit the JSON file — not this script.
    See ../sequences/Test-Start.guest.ubuntu.desktop.json for the available actions and format.

.NOTES
    Exit 0 = success, non-zero = failure (stops the runner).
#>

# ─────────────────────────────────────────────────────────────────────────────
# PARAMETERS — passed by the test runner, do not change
# ─────────────────────────────────────────────────────────────────────────────
param(
    [string]$HostType,   # "host.windows.hyper-v" or "host.macos.utm"
    [string]$GuestKey,   # "guest.ubuntu.desktop"
    [string]$VMName      # e.g. "test-ubuntu-desktop01"
)

# ─────────────────────────────────────────────────────────────────────────────
# EXECUTION
# ─────────────────────────────────────────────────────────────────────────────
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$sequenceFile = Join-Path (Split-Path -Parent $ScriptDir) "sequences/Test-Start.$GuestKey.json"
$engineModule = Join-Path $ScriptDir "Invoke-Sequence.psm1"

Import-Module $engineModule -Force -Verbose:$false

Write-Output "[$GuestKey] Install-OS on $HostType (VM: $VMName)"
Write-Output "    Sequence file: $sequenceFile"

$ok = Invoke-Sequence -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencePath $sequenceFile
if ($ok -eq $false) {
    Write-Warning "[$GuestKey] Sequence failed. Install may require manual intervention."
    exit 1
}

Write-Output "[$GuestKey] Sequence complete."
exit 0
