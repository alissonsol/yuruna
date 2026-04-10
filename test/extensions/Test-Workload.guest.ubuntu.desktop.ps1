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
    Runs workload sequences for the Ubuntu Desktop guest:
    1. Test-Workload.guest.ubuntu.desktop.json
    2. Test-Workload.guest.ubuntu.desktop.k8s.website.json

    To customize the workload tests, edit the JSON files — not this script.

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
$SequencesDir = Join-Path (Split-Path -Parent $ScriptDir) "sequences"
$engineModule = Join-Path $ScriptDir "Invoke-Sequence.psm1"

Import-Module $engineModule -Force -Verbose:$false

# Ordered list of sequences to run for this guest
$sequences = @(
    "Test-Workload.$GuestKey"
    "Test-Workload.$GuestKey.k8s.website"
)

foreach ($seqName in $sequences) {
    $sequenceFile = Join-Path $SequencesDir "$seqName.json"
    if (-not (Test-Path $sequenceFile)) {
        Write-Warning "[$GuestKey] Sequence file not found, skipping: $sequenceFile"
        continue
    }

    Write-Output "[$GuestKey] Running sequence: $seqName on $HostType (VM: $VMName)"
    Write-Output "    Sequence file: $sequenceFile"

    $ok = Invoke-Sequence -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencePath $sequenceFile
    if ($ok -eq $false) {
        Write-Warning "[$GuestKey] Sequence '$seqName' failed."
        exit 1
    }

    Write-Output "[$GuestKey] Sequence '$seqName' complete."
}

Write-Output "[$GuestKey] All workload sequences complete."
exit 0
