<#PSScriptInfo
.VERSION 2026.06.26
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
    'bootstrap_sync', 'plan_invalid', 'unknown'
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
