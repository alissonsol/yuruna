<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42bdbb68-d8ab-4a5d-ab31-5e9f7428a1a6
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

# Workload dispatcher architecture: ../../docs/test-harness.md#module-responsibilities.

Import-Module (Join-Path $PSScriptRoot "Test.YurunaDir.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false
$script:EngineModule = Join-Path $PSScriptRoot "Test.SequenceEngine.psm1"
if (Test-Path $script:EngineModule) {
    # -Global is load-bearing: a -Force import without it evicts Invoke-Sequence
    # from the global session (the engine becomes private to this module's
    # scope), so the runner's later guests crash with "Write-ProgressTick /
    # Wait-ForText is not recognized". Same engine-import convention as
    # Test.Prelude's Initialize-SequenceEngineRegistry.
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
        [bool]$ShowOutput = $true,
        # Warm-resume passthrough: restart at ResumeFromSequence/ResumeFromStep
        # instead of running the whole list from the top. Default ('' / 1) is the
        # normal full run. See Invoke-GuestSequenceList.
        [string]$ResumeFromSequence = '',
        [int]$ResumeFromStep = 1
    )
    # ShowOutput is a compatibility shim, never read inside this function. A
    # long-running macOS runner re-imports modules each cycle without reloading
    # Start-TestRunner.ps1 itself, so a runner launched from an older call site
    # can still be passing the arg. Accept and ignore until those runners restart.
    Write-Debug "Start-GuestWorkload: -ShowOutput=$ShowOutput accepted as a no-op (transitional shim)."
    # The dispatcher loop lives in Invoke-Sequence (Invoke-GuestSequenceList), shared
    # verbatim with Start-GuestOS; only the failure-message phase label differs.
    return Invoke-GuestSequenceList -PhaseLabel 'Workload' `
        -HostType $HostType -GuestKey $GuestKey -VMName $VMName -RepoRoot $RepoRoot `
        -SequencesDir $SequencesDir -SequenceNames $SequenceNames -EffectiveVariables $EffectiveVariables `
        -ResumeFromSequence $ResumeFromSequence -ResumeFromStep $ResumeFromStep
}

Export-ModuleMember -Function Start-GuestWorkload
