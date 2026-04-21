<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456763
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
    Drives the Ubuntu Server guest through initial boot via JSON sequences.

.DESCRIPTION
    Iterates over the sequence names in $sequences. Each name is resolved
    to sequences/<mode>/<name>.json (mode = gui or ssh, picked from
    test-config.json keystrokeMechanism) by Invoke-SequenceByName, with
    fallback to the gui/ copy when no ssh/ variant exists.

    Identical wrapper pattern to Test-Start.guest.ubuntu.desktop.ps1 — the
    JSON files hold all the guest-specific behaviour. To customize the
    boot automation, edit the JSON file, not this script.

.NOTES
    Exit 0 = success, non-zero = failure (stops the runner).
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

# Ordered list of sequence names for this guest. A future generalisation
# will load this list from test-config.json instead.
$sequences = @(
    "Test-Start.$GuestKey"
)

Write-Output "[$GuestKey] Install-OS on $HostType (VM: $VMName)"

foreach ($seqName in $sequences) {
    $ok = Invoke-SequenceByName -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencesDir $SequencesDir -Name $seqName
    if ($ok -eq $false) {
        Write-Warning "[$GuestKey] Sequence '$seqName' failed. Install may require manual intervention."
        exit 1
    }
}

Write-Output "[$GuestKey] Sequence complete."
exit 0
