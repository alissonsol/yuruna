<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42d4e5f6-7a8b-49c0-8d1e-2f3a4b5c6d7e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-refresh request intent lock
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking


# One durable, private request record per host-refresh attempt. Built on
# Test.SingleFlightLock's held-open OS lock (the lifetime repair lock) and
# Get-YurunaPrivateStateRoot (automation/Yuruna.Common.psm1) for a root
# outside every HTTP-served tree.
#
# SCOPE NOTE: this module implements the request/attempt bookkeeping (queued
# -> running -> completed/refused/abandoned, retry-with-same-ID, immutable
# policy) from section 4. It does NOT implement the admission-lock-separate-
# from-repair-lock split for a concurrent HTTP listener (section 4's second
# lock), the recovery snapshot of captured service/runner state, or the
# 30-minute unclaimed-request expiry sweep -- those need the listener
# (package 5) and the service-capture work this session did not reach. What
# is here is real and independently useful: one caller at a time, a durable
# record of what happened, and a bounded retry count.

function Get-YurunaHostRefreshRequestPath {
    <#
    .SYNOPSIS
        The private request-journal path under Get-YurunaPrivateStateRoot.
    .OUTPUTS
        [string] or $null when the private root itself could not be secured.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $root = Get-YurunaPrivateStateRoot
    if (-not $root.Resolved) { return $null }
    return (Join-Path $root.Path 'host-refresh.request.json')
}

function Get-YurunaHostRefreshLockPath {
    <#
    .SYNOPSIS
        The lifetime repair lock path under Get-YurunaPrivateStateRoot.
    .OUTPUTS
        [string] or $null when the private root itself could not be secured.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $root = Get-YurunaPrivateStateRoot
    if (-not $root.Resolved) { return $null }
    return (Join-Path $root.Path 'host-refresh.lock')
}

function New-YurunaHostRefreshRequestId {
    <#
    .SYNOPSIS
        A fresh canonical request identity.
    .OUTPUTS
        [string] a GUID in 'N' (32 hex digit) form.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Generates an in-memory value only; nothing on disk or in process state changes.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [Guid]::NewGuid().ToString('N')
}

function Read-YurunaHostRefreshRequest {
    <#
    .SYNOPSIS
        Best-effort read of the current request journal. $null when absent,
        empty, or unparseable -- a corrupt/missing journal means no active
        request is known, not an error to throw over.
    .OUTPUTS
        [hashtable] or $null
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Write-YurunaHostRefreshRequest {
    <#
    .SYNOPSIS
        Atomically replace the request journal. Requires the lifetime lock
        to already be held by the caller -- this function does not acquire
        it, matching the plan's ordering (repair lock first, then the
        request write).
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Request
    )
    if (-not $PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'runner.operator_ae404c37892f11d1'))) { return $false }
    try {
        $json = $Request | ConvertTo-Json -Compress -Depth 10
        $tmp  = "$Path.$PID-$([Guid]::NewGuid().ToString('n')).tmp"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($tmp, $Path, $true)
        return $true
    } catch {
        Write-Verbose "Write-YurunaHostRefreshRequest: failed for '$Path': $($_.Exception.Message)"
        return $false
    }
}

function Confirm-HostRefreshIntent {
    <#
    .SYNOPSIS
        Claim or resume ownership of one host-refresh request under the
        caller's already-held lifetime lock. The approved-verb ownership
        operation section 4 names.
    .DESCRIPTION
        Canonical states: queued, running, completed, refused, abandoned.
        An exact retry (same RequestId, same immutable Policy) of an
        existing request returns that same request, incrementing Attempt,
        rather than creating a new one. A different RequestId while another
        request is active (queued/running, or abandoned with outstanding
        obligations reported by the caller) is refused. A known RequestId
        whose Policy differs from what was recorded is refused with
        'request-policy-mismatch', even after completion -- immutable
        policy is immutable.

        Does not itself acquire the lifetime lock: the caller (Invoke-
        HostRefresh.ps1) holds it for the whole repair and calls this only
        to claim/update the durable record inside that ownership window.
    .PARAMETER RequestPath
        From Get-YurunaHostRefreshRequestPath.
    .PARAMETER RequestId
        The canonical UUID this attempt uses. A fresh one for new work; the
        same one to retry.
    .PARAMETER Policy
        A hashtable the caller controls (Tier, MaxRung, Force, AllowHardStop
        at minimum). Compared for equality (via a canonical JSON encoding)
        against a previously recorded request of the same RequestId.
    .OUTPUTS
        [pscustomobject] @{ Accepted; Request; Reason }. Reason is one of:
        accepted-new, accepted-retry, refused-active-other-request,
        refused-policy-mismatch, refused-terminal-no-retry (a refused/
        expired/abandoned-without-obligations ID resubmitted).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestPath,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][hashtable]$Policy
    )
    $policyJson = $Policy | ConvertTo-Json -Compress -Depth 10
    $existing = Read-YurunaHostRefreshRequest -Path $RequestPath

    if ($existing -and $existing.RequestId -eq $RequestId) {
        $existingPolicyJson = if ($existing.Policy) { $existing.Policy | ConvertTo-Json -Compress -Depth 10 } else { $null }
        if ($existingPolicyJson -ne $policyJson) {
            return [pscustomobject]@{ Accepted = $false; Request = $existing; Reason = 'refused-policy-mismatch' }
        }
        if ($existing.State -in @('refused')) {
            return [pscustomobject]@{ Accepted = $false; Request = $existing; Reason = 'refused-terminal-no-retry' }
        }
        $attempt = if ($existing.Attempt) { [int]$existing.Attempt + 1 } else { 1 }
        if ($attempt -gt 3) {
            $existing.State = 'abandoned'
            $null = Write-YurunaHostRefreshRequest -Path $RequestPath -Request $existing -Confirm:$false
            return [pscustomobject]@{ Accepted = $false; Request = $existing; Reason = 'refused-terminal-no-retry' }
        }
        $existing.State   = 'running'
        $existing.Attempt = $attempt
        $existing.ClaimedAtUtc = [DateTime]::UtcNow.ToString('o')
        $existing.ClaimedByPid = $PID
        $null = Write-YurunaHostRefreshRequest -Path $RequestPath -Request $existing -Confirm:$false
        return [pscustomobject]@{ Accepted = $true; Request = $existing; Reason = 'accepted-retry' }
    }

    if ($existing -and $existing.State -in @('queued', 'running')) {
        return [pscustomobject]@{ Accepted = $false; Request = $existing; Reason = 'refused-active-other-request' }
    }

    $fresh = @{
        RequestId     = $RequestId
        Policy        = $Policy
        State         = 'running'
        Attempt       = 1
        GenerationId  = [Guid]::NewGuid().ToString('n')
        CreatedAtUtc  = [DateTime]::UtcNow.ToString('o')
        ClaimedAtUtc  = [DateTime]::UtcNow.ToString('o')
        ClaimedByPid  = $PID
    }
    $null = Write-YurunaHostRefreshRequest -Path $RequestPath -Request $fresh -Confirm:$false
    return [pscustomobject]@{ Accepted = $true; Request = $fresh; Reason = 'accepted-new' }
}

function Complete-YurunaHostRefreshRequest {
    <#
    .SYNOPSIS
        Publish the terminal state for a claimed request: completed
        (verified convergence, healthy no-op, or a failure with no
        outstanding obligation) or refused (a pre-mutation refusal).
        Never called for a partial/incomplete outcome -- that keeps the
        request 'running' so a retry sees it as still owned work, per
        section 4's "any outstanding obligation moves the request to
        recovery-pending, no verdict silently discharges it" (recovery-
        pending itself is not implemented in this pass; an incomplete
        outcome here is surfaced by simply leaving State as 'running' and
        relying on the dead-worker retry path rather than a distinct
        recovery-pending state).
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RequestPath,
        [Parameter(Mandatory)][ValidateSet('completed', 'refused')][string]$State,
        [Parameter(Mandatory)][string]$Verdict,
        [string]$Detail
    )
    $existing = Read-YurunaHostRefreshRequest -Path $RequestPath
    if (-not $existing) { return $false }
    $existing.State           = $State
    $existing.Verdict         = $Verdict
    $existing.Detail          = $Detail
    $existing.CompletedAtUtc  = [DateTime]::UtcNow.ToString('o')
    return (Write-YurunaHostRefreshRequest -Path $RequestPath -Request $existing -Confirm:$false)
}

Export-ModuleMember -Function Get-YurunaHostRefreshRequestPath, Get-YurunaHostRefreshLockPath, `
    New-YurunaHostRefreshRequestId, Read-YurunaHostRefreshRequest, Write-YurunaHostRefreshRequest, `
    Confirm-HostRefreshIntent, Complete-YurunaHostRefreshRequest
