<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456716
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

# -- Start-GuestOS dispatcher ------------------------------------------------
#
# Generic dispatcher that runs a caller-supplied list of sequence names
# via Invoke-SequenceByName -- one entry point regardless of the guest
# OS, in place of per-OS Test-Start.guest.*.ps1 extension scripts. The
# cycle planner derives the list from project/test/test.runner.yml
# and the per-sequence baseline fields.
#
# Naming convention (by design):
#     Module filename = "Test.<exported-cmdlet>.psm1"
# This file exports exactly one cmdlet, `Start-GuestOS`, so the filename
# is `Test.Start-GuestOS.psm1`. The hyphen makes the basename look like
# a cmdlet -- that is the FEATURE: `grep -l Test.Start-GuestOS` finds
# the single source file that defines the dashboard tile of the same
# name, and the operator clicking through from the status UI lands on
# the right file. If you're adding a sibling dispatcher (e.g.
# Start-GuestRepair), follow the same shape: one exported cmdlet,
# filename = "Test.<cmdlet>".

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
    Runs the start-phase sequences for a guest.
.DESCRIPTION
    Iterates the supplied sequence names in order, calling
    Invoke-SequenceByName for each. The caller (the runner) builds the
    list from the cycle plan; an empty list returns success/skipped so
    the cycle's Start-GuestOS step shows as skipped rather than failing.

    On a sequence failure we read test/status/log/last_failure.json (the
    sidecar Invoke-Sequence drops on failure) and surface the step
    location in the error message so the runner's notification mail and
    the status-service UI both have actionable context.

    Returns @{ success; skipped; errorMessage }.
#>
function Start-GuestOS {
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
        # Planner-cascaded variable overrides (Test.SequencePlanner ->
        # Invoke-Sequence). Forwarded to each Invoke-SequenceByName call
        # so the workload's `variables.username` override reaches the
        # baseline `start.*.yml` despite the baseline declaring its own
        # default value.
        # IDictionary (not [hashtable]) preserves the planner's
        # [ordered]@{} insertion order through parameter binding so
        # `${username}` resolves before `${currentPassword}` in the
        # downstream Invoke-Sequence expansion loop.
        [System.Collections.IDictionary]$EffectiveVariables,
        [bool]$ShowOutput = $true
    )
    # ShowOutput is a transitional shim. The flag has never been read inside
    # this function, but a long-running macOS runner re-imports modules each
    # cycle without reloading Invoke-TestRunner.ps1 itself, so a runner that
    # was launched before the call-site removal is still passing the arg.
    # Accept and ignore until those runners restart.
    Write-Debug "Start-GuestOS: -ShowOutput=$ShowOutput accepted as a no-op (transitional shim)."
    # The dispatcher loop lives in Invoke-Sequence (Invoke-GuestSequenceList), shared
    # verbatim with Start-GuestWorkload; only the failure-message phase label differs.
    return Invoke-GuestSequenceList -PhaseLabel 'Start' `
        -HostType $HostType -GuestKey $GuestKey -VMName $VMName -RepoRoot $RepoRoot `
        -SequencesDir $SequencesDir -SequenceNames $SequenceNames -EffectiveVariables $EffectiveVariables
}

Export-ModuleMember -Function Start-GuestOS
