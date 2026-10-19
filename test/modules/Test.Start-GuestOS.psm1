<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 424a4bb4-0925-4cb5-8746-7b99ea564ac0
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

# --- REGION: Start-GuestOS dispatcher
# See https://yuruna.link/4213a0b3-017a

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
        # See https://yuruna.link/4213a0b3-017b
        [System.Collections.IDictionary]$EffectiveVariables,
        [bool]$ShowOutput = $true
    )
    # ShowOutput is a compatibility shim, never read inside this function. A
    # long-running macOS runner re-imports modules each cycle without reloading
    # Start-TestRunner.ps1 itself, so a runner launched from an older call site
    # can still be passing the arg. Accept and ignore until those runners restart.
    Write-Debug "Start-GuestOS: -ShowOutput=$ShowOutput accepted as a no-op (transitional shim)."
    # The dispatcher loop lives in Invoke-Sequence (Invoke-GuestSequenceList), shared
    # verbatim with Start-GuestWorkload; only the failure-message phase label differs.
    return Invoke-GuestSequenceList -PhaseLabel 'Start' `
        -HostType $HostType -GuestKey $GuestKey -VMName $VMName -RepoRoot $RepoRoot `
        -SequencesDir $SequencesDir -SequenceNames $SequenceNames -EffectiveVariables $EffectiveVariables
}

Export-ModuleMember -Function Start-GuestOS
