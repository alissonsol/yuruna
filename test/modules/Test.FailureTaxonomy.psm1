<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42b7e3c5-9a14-4d28-8f63-1e0a2b4c6d80
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna telemetry failure-taxonomy enum
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

# Canonical FailureClass + Severity taxonomy: the single source of truth for
# the Register-SequenceAction ValidateSet (Test.SequenceAction.psm1) and the
# schema validator's enum check (Test.EventSchema.psm1). A ValidateSet
# ATTRIBUTE argument must be a constant expression and cannot reference these
# arrays, so Test.SequenceAction keeps a literal copy and calls
# Assert-FailureTaxonomyInSync at module load to catch silent drift; every
# OTHER consumer reads the arrays here. Leaf module: imports nothing, so it is
# safe to load first in any module set.

$script:FailureClassEnum = @(
    'ocr_timeout', 'network_timeout', 'credential_expired',
    'host_io_blocked', 'pattern_matched_failure', 'retry_exhausted',
    'snapshot_restore_failed', 'script_error', 'wait_timeout',
    'extension_error', 'instrumentation_failure', 'provisioning_failure',
    # elevation_required: the host asked for a sudo password with no operator
    # present. Its own class because it is the one failure that is provably
    # unfixable from anywhere but the console -- retrying it, on this cycle or
    # any later one, can only reproduce it, so remediation must route it
    # straight to operator_intervention_required rather than burn the backoff.
    # project_access_denied: a POOL assigned this host a projectUrl its
    # credential cannot read. Distinct from bootstrap_sync (this host's own
    # project failing to clone) because the fix belongs to a different person --
    # the pool admin who made the assignment, not the host owner -- and distinct
    # from network_timeout because no retry can ever succeed.
    # host_network_degraded: the HOST's own guest-network path is broken, so
    # every network-touching guest on it fails identically for a reason no
    # guest-level retry can influence. Its own class because a virtual switch
    # object outlives its uplink binding across a host reboot -- the switch is
    # still there, nothing it carries forwards, and each guest reports only its
    # own symptom (network_timeout / provisioning_failure). It is deliberately
    # absent from the transient fast-retry allow-lists: retrying against a
    # bridge with no carrier can only spend the cycle budget, so it routes to
    # the operator like elevation_required does.
    'bootstrap_sync', 'plan_invalid', 'elevation_required', 'project_access_denied',
    'host_network_degraded', 'unknown'
)
$script:SeverityEnum = @('hard', 'soft', 'unknown')

function Get-FailureClassEnum {
    <#
    .SYNOPSIS
        The canonical FailureClass values (machine-routable failure categories).
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param()
    return @($script:FailureClassEnum)
}

function Get-SeverityEnum {
    <#
    .SYNOPSIS
        The canonical Severity values.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param()
    return @($script:SeverityEnum)
}

function Assert-FailureTaxonomyInSync {
    <#
    .SYNOPSIS
        Compare a caller's literal FailureClass/Severity copy (e.g. the
        Register-SequenceAction ValidateSet) against the canonical arrays.
    .DESCRIPTION
        Order-sensitive equality so a reordered list is also flagged. Warn-only
        (never throws), matching the schema validator's never-reject policy: a
        drifted ValidateSet should surface loudly at module load, not abort the
        cycle. Returns $true when in sync.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$FailureClass,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Severity
    )
    $ok = $true
    if ((@($FailureClass) -join '|') -ne (@($script:FailureClassEnum) -join '|')) {
        Write-Warning "$Source FailureClass list drifted from Test.FailureTaxonomy canonical set."
        $ok = $false
    }
    if ((@($Severity) -join '|') -ne (@($script:SeverityEnum) -join '|')) {
        Write-Warning "$Source Severity list drifted from Test.FailureTaxonomy canonical set."
        $ok = $false
    }
    return $ok
}

Export-ModuleMember -Function Get-FailureClassEnum, Get-SeverityEnum, Assert-FailureTaxonomyInSync
