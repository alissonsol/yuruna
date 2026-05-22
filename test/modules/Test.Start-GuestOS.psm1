<#PSScriptInfo
.VERSION 2026.05.22
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456716
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# ── Start-GuestOS dispatcher ────────────────────────────────────────────────
#
# Replaces the old per-OS Test-Start.guest.*.ps1 extension scripts with a
# generic dispatcher that runs a caller-supplied list of sequence names
# via Invoke-SequenceByName. The cycle planner derives the list from
# project/test/test.sequence.yml and the per-sequence baseline fields.
# Module file name and exported function match the dashboard tile
# (Start-GuestOS) so the operator can find the source from the UI.

Import-Module (Join-Path $PSScriptRoot "Test.LogDir.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false
$script:EngineModule = Join-Path $PSScriptRoot "Invoke-Sequence.psm1"
if (Test-Path $script:EngineModule) {
    Import-Module $script:EngineModule -Force -Verbose:$false -ErrorAction SilentlyContinue
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
    the status-server UI both have actionable context.

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
    if (-not $SequenceNames -or $SequenceNames.Count -eq 0) {
        return @{ success=$true; skipped=$true; errorMessage=$null }
    }
    foreach ($s in $SequenceNames) {
        Write-Information "  Running: $s" -InformationAction Continue
        $ok = Invoke-SequenceByName -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencesDir $SequencesDir -RepoRoot $RepoRoot -Name $s -EffectiveVariables $EffectiveVariables
        if (-not $ok) {
            $errMsg = "Start sequence '$s' failed"
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
    }
    return @{ success=$true; skipped=$false; errorMessage=$null }
}

Export-ModuleMember -Function Start-GuestOS
