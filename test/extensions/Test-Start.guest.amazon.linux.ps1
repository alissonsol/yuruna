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
    Drives the Amazon Linux guest through first boot via a JSON sequence.

.DESCRIPTION
    Reads the interaction sequence from sequences/Test-Start.guest.amazon.linux.json.
    Amazon Linux boots from a pre-built image with cloud-init, so the
    default sequence has no steps. Add steps to the JSON file if a future
    image requires interaction.

.NOTES
    Exit 0 = success, non-zero = failure (stops the runner).
#>

# ─────────────────────────────────────────────────────────────────────────────
# PARAMETERS — passed by the test runner, do not change
# ─────────────────────────────────────────────────────────────────────────────
param(
    [string]$HostType,   # "host.windows.hyper-v" or "host.macos.utm"
    [string]$GuestKey,   # "guest.amazon.linux"
    [string]$VMName      # e.g. "test-amazon-linux01"
)

# ─────────────────────────────────────────────────────────────────────────────
# EXECUTION
# ─────────────────────────────────────────────────────────────────────────────
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$sequenceFile = Join-Path $ScriptDir "sequences/Test-Start.$GuestKey.json"
$engineModule = Join-Path $ScriptDir "Invoke-Sequence.psm1"

Import-Module $engineModule -Force

Write-Output "[$GuestKey] Install-OS on $HostType (VM: $VMName)"
Write-Output "    Sequence file: $sequenceFile"

$ok = Invoke-Sequence -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencePath $sequenceFile
if ($ok -eq $false) {
    Write-Warning "[$GuestKey] Sequence failed."
    exit 1
}

Write-Output "[$GuestKey] Sequence complete."
exit 0
