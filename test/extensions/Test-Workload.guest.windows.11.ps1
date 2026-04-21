<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456722
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
    Workload test for the Windows 11 guest via JSON sequences.

.DESCRIPTION
    Iterates over the sequence names in $sequences. Each name is resolved
    to sequences/<mode>/<name>.json (mode = gui or ssh, picked from
    test-config.json keystrokeMechanism) by Invoke-SequenceByName, with
    fallback to the gui/ copy when no ssh/ variant exists.

    To customize the workload test, edit the JSON file — not this script.

.NOTES
    Exit 0 = pass, non-zero = fail (stops the runner and triggers notification).
#>

# ─────────────────────────────────────────────────────────────────────────────
# PARAMETERS — passed by the test runner, do not change
# ─────────────────────────────────────────────────────────────────────────────
param(
    [string]$HostType,   # "host.windows.hyper-v" or "host.macos.utm"
    [string]$GuestKey,   # "guest.windows.11"
    [string]$VMName      # e.g. "test-windows-1101"
)

# ─────────────────────────────────────────────────────────────────────────────
# EXECUTION
# ─────────────────────────────────────────────────────────────────────────────
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$SequencesDir = Join-Path (Split-Path -Parent $ScriptDir) "sequences"
$engineModule = Join-Path $ScriptDir "Invoke-Sequence.psm1"

Import-Module $engineModule -Force -Verbose:$false

# Ordered list of sequence names for this guest. A future generalisation
# will load this list from test-config.json instead.
$sequences = @(
    "Test-Workload.$GuestKey"
)

Write-Output "[$GuestKey] Workload test on $HostType (VM: $VMName)"

foreach ($seqName in $sequences) {
    $ok = Invoke-SequenceByName -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencesDir $SequencesDir -Name $seqName
    if ($ok -eq $false) {
        Write-Warning "[$GuestKey] Sequence '$seqName' failed."
        exit 1
    }
}

Write-Output "[$GuestKey] Workload sequence complete."
exit 0
