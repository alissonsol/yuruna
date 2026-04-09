<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456721
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
    Workload test for the Ubuntu Desktop guest via a JSON sequence.

.DESCRIPTION
    Reads the interaction sequence from ../sequences/Test-Workload.guest.ubuntu.desktop.json
    and executes each step against the VM.

    To customize the workload test, edit the JSON file — not this script.

.NOTES
    Exit 0 = pass, non-zero = fail (stops the runner and triggers notification).
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
$sequenceFile = Join-Path (Split-Path -Parent $ScriptDir) "sequences/Test-Workload.$GuestKey.json"
$engineModule = Join-Path $ScriptDir "Invoke-Sequence.psm1"

Import-Module $engineModule -Force -Verbose:$false

Write-Output "[$GuestKey] Workload test on $HostType (VM: $VMName)"
Write-Output "    Sequence file: $sequenceFile"

$ok = Invoke-Sequence -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencePath $sequenceFile
if ($ok -eq $false) {
    Write-Warning "[$GuestKey] Workload sequence failed."
    exit 1
}

Write-Output "[$GuestKey] Workload sequence complete."
exit 0
