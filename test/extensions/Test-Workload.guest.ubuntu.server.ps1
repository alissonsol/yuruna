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
    Workload test for the Ubuntu Server guest via JSON sequences.

.DESCRIPTION
    Iterates over the sequence names in $sequences. Each name is resolved
    to sequences/<mode>/<name>.json (mode = gui or ssh, picked from
    test-config.json keystrokeMechanism) by Invoke-SequenceByName, with
    fallback to the gui/ copy when no ssh/ variant exists.

    The base sequence (Test-Workload.$GuestKey) runs first; any additional
    sequences under sequences/gui/ matching Test-Workload.$GuestKey.*.json
    are picked up in sorted order so new sequences are added by dropping
    files instead of editing this script.

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
# siblings under sequences/gui/ run in sorted order after the base. Extras
# are discovered from the gui/ folder because that is the canonical source
# of truth for "which workloads exist for this guest"; Invoke-SequenceByName
# then resolves each name to the active mode. A future generalisation will
# load this list from test-config.json instead.
$baseSeq    = "Test-Workload.$GuestKey"
$sequences  = @($baseSeq)
$guiDir     = Join-Path $SequencesDir 'gui'
$extras = Get-ChildItem -Path $guiDir -Filter "$baseSeq.*.json" -ErrorAction SilentlyContinue |
    Sort-Object Name |
    ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }
if ($extras) { $sequences += $extras }

foreach ($seqName in $sequences) {
    $ok = Invoke-SequenceByName -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencesDir $SequencesDir -Name $seqName
    if ($ok -eq $false) {
        Write-Warning "[$GuestKey] Sequence '$seqName' failed."
        exit 1
    }
}

Write-Output "[$GuestKey] All workload sequences complete."
exit 0
