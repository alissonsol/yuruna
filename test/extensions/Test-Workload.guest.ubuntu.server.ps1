<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456723
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
    Workload test for the Ubuntu Server guest via a JSON sequence.

.DESCRIPTION
    Runs the base workload sequence for the Ubuntu Server guest:
    1. Test-Workload.guest.ubuntu.server.json

    Shares the extras-pattern with Test-Workload.guest.ubuntu.desktop.ps1: any
    Test-Workload.guest.ubuntu.server.*.json sibling (e.g. a future
    Test-Workload.guest.ubuntu.server.k8s.website.json) is picked up and run
    after the base sequence. To customize the workload tests, edit the JSON
    files — not this script.

.NOTES
    Exit 0 = pass, non-zero = fail (stops the runner and triggers notification).
#>

# ─────────────────────────────────────────────────────────────────────────────
# PARAMETERS — passed by the test runner, do not change
# ─────────────────────────────────────────────────────────────────────────────
param(
    [string]$HostType,   # "host.windows.hyper-v" or "host.macos.utm"
    [string]$GuestKey,   # "guest.ubuntu.server"
    [string]$VMName      # e.g. "test-ubuntu-server-01"
)

# ─────────────────────────────────────────────────────────────────────────────
# EXECUTION
# ─────────────────────────────────────────────────────────────────────────────
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$SequencesDir = Join-Path (Split-Path -Parent $ScriptDir) "sequences"
$engineModule = Join-Path $ScriptDir "Invoke-Sequence.psm1"

Import-Module $engineModule -Force -Verbose:$false

# Base sequence always runs; additional Test-Workload.$GuestKey.<suffix>.json
# siblings run in sorted order after the base sequence. This mirrors the
# ubuntu.desktop variant but auto-discovers the extras instead of hardcoding
# them, so adding a new sequence is a file-drop rather than a script edit.
#
# The ".ssh" suffix is reserved: Test-Workload.$GuestKey.ssh.json is the
# parallel-path alternative that Invoke-Sequence substitutes for the base
# when test-config.json has keystrokeMechanism="ssh". It is NEVER an
# additional workload to run on top of the base — without this filter the
# harness in hypervisor mode would also execute the SSH variant, which
# correctly fails because sshd isn't up (Test-Start only brought up GDM).
$baseSeq  = "Test-Workload.$GuestKey"
$sequences = @($baseSeq)
$extras = Get-ChildItem -Path $SequencesDir -Filter "$baseSeq.*.json" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "$baseSeq.ssh.json" } |
    Sort-Object Name |
    ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }
if ($extras) { $sequences += $extras }

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
