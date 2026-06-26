<#PSScriptInfo
.VERSION 2026.06.26
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456715
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# ── Start-GuestWorkload dispatcher ──────────────────────────────────────────
#
# Generic dispatcher that runs a caller-supplied list of workload
# sequence names via Invoke-SequenceByName -- one entry point regardless
# of the guest OS, in place of per-OS Test-Workload.guest.*.ps1
# extension scripts. The cycle planner builds the list by walking each
# top-level baseline chain and collecting every entry whose name does
# not start with "start.".
#
# Naming convention (by design):
#     Module filename = "Test.<exported-cmdlet>.psm1"
# This file exports exactly one cmdlet, `Start-GuestWorkload`, so the
# filename is `Test.Start-GuestWorkload.psm1`. The hyphen makes the
# basename look like a cmdlet -- that is the FEATURE:
# `grep -l Test.Start-GuestWorkload` finds the single source file that
# defines the dashboard tile of the same name, and the operator clicking
# through from the status UI lands on the right file. See its sibling
# Test.Start-GuestOS.psm1 for the convention's full statement.

Import-Module (Join-Path $PSScriptRoot "Test.YurunaDir.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false
$script:EngineModule = Join-Path $PSScriptRoot "Invoke-Sequence.psm1"
if (Test-Path $script:EngineModule) {
    # -Global is load-bearing: a -Force import without it evicts Invoke-Sequence
    # from the global session (the engine becomes private to this module's
    # scope), so the runner's later guests crash with "Write-ProgressTick /
    # Wait-ForText is not recognized". Same engine-import convention as
    # Test.Prelude's Reset-SequenceRegistry.
    Import-Module $script:EngineModule -Global -Force -DisableNameChecking -Verbose:$false -ErrorAction SilentlyContinue
}

<#
.SYNOPSIS
    Runs the workload-phase sequences for a guest.
.DESCRIPTION
    Iterates the supplied sequence names in order. An empty list returns
    success/skipped so the cycle's Start-GuestWorkload step shows as
    skipped rather than failing.

    Returns @{ success; skipped; errorMessage }.
#>
function Start-GuestWorkload {
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal dispatcher: state changes happen inside per-step Invoke-Sequence calls. Gating here would only add a redundant prompt.')]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SequencesDir,
        [string[]]$SequenceNames = @(),
        # Planner-cascaded variable overrides; see Start-GuestOS / Test.SequencePlanner.
        # IDictionary (not [hashtable]) preserves planner ordering.
        [System.Collections.IDictionary]$EffectiveVariables,
        [bool]$ShowOutput = $true
    )
    # ShowOutput is a transitional shim. The flag has never been read inside
    # this function, but a long-running macOS runner re-imports modules each
    # cycle without reloading Invoke-TestRunner.ps1 itself, so a runner that
    # was launched before the call-site removal is still passing the arg.
    # Accept and ignore until those runners restart.
    Write-Debug "Start-GuestWorkload: -ShowOutput=$ShowOutput accepted as a no-op (transitional shim)."
    if (-not $SequenceNames -or $SequenceNames.Count -eq 0) {
        return @{ success=$true; skipped=$true; errorMessage=$null }
    }
    foreach ($s in $SequenceNames) {
        Write-Information "  Running: $s" -InformationAction Continue
        $ok = Invoke-SequenceByName -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencesDir $SequencesDir -RepoRoot $RepoRoot -Name $s -EffectiveVariables $EffectiveVariables
        if (-not $ok) {
            $errMsg = "Workload sequence '$s' failed"
            $logDir = Initialize-YurunaLogDir
            $failFile = Join-Path $logDir "last_failure.json"
            if (Test-Path $failFile) {
                try {
                    $failInfo = Get-Content -Raw $failFile | ConvertFrom-Json
                    $errMsg = "Step [$($failInfo.stepNumber)/$($failInfo.totalSteps)] $($failInfo.action) - $($failInfo.description) (sequence: $s)"
                } catch {
                    Write-Verbose "Could not parse failure details: $_"
                }
            }
            return @{ success=$false; skipped=$false; errorMessage=$errMsg }
        }
        Write-Information "  ${s}: PASS" -InformationAction Continue
        # Pick up a mid-sequence saveDiskSnapshot rename (e.g. a baseline that
        # ends in saveDiskSnapshot before a dependent .test loads it) so the next
        # sequence targets the renamed VM -- the same Get-SequenceFinishedVMName
        # mechanism Test-Sequence's chain runner uses. No-op when nothing renamed.
        $finishedVm = Get-SequenceFinishedVMName
        if ($finishedVm -and $finishedVm -ne $VMName) {
            Write-Information "  VM renamed mid-chain: '$VMName' -> '$finishedVm'." -InformationAction Continue
            $VMName = $finishedVm
        }
    }
    return @{ success=$true; skipped=$false; errorMessage=$null }
}

Export-ModuleMember -Function Start-GuestWorkload
