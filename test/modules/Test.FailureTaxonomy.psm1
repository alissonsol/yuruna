<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42a11720-948f-47cf-8739-5beedf5f7176
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

# See https://yuruna.link/4213a0b3-0057

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$script:FailureClassEnum = @(
    'ocr_timeout', 'console_flooded', 'network_timeout', 'credential_expired',
    'host_io_blocked', 'pattern_matched_failure', 'retry_exhausted',
    'snapshot_restore_failed', 'script_error', 'wait_timeout',
    'extension_error', 'instrumentation_failure', 'provisioning_failure',
    # --- REGION: https://yuruna.link/42820e91-0015
    # Each name below is a distinct class only where retry policy, or the person
    # who can fix it, differs from every other class; the per-class derivation
    # lives in the doc.
    'bootstrap_sync', 'plan_invalid', 'elevation_required', 'project_access_denied',
    'host_network_degraded', 'ip_not_discovered', 'payload_unavailable',
    'pool_storage_full', 'dhcp_identity_unbounded', 'lab_dependency_down', 'input_lost',
    'hypervisor_unresponsive', 'source_integrity',
    # Split out of wait_timeout and instrumentation_failure: a guest that ignored
    # a shutdown and a run its supervisor could not account for are fixed by a
    # power-off from the host and a restore, where those two classes are retried
    # as-is.
    'vm_not_stopped', 'guest_run_lost',
    # Split out of wait_timeout so a wedged guest kernel's retries spend a budget
    # of their own.
    'guest_kernel_stalled',
    'unknown'
)
$script:SeverityEnum = @('hard', 'soft', 'unknown')

# --- REGION: Class routing
# How each class is routed, kept beside the enum so every consumer asks one
# table rather than keeping its own list: UnattendedRetry -- the outer loop may
# end a failure pause early and retry without an operator (Test.Remediation
# keeps the reason for each); WarmResume -- a step that failed with it may be
# resumed in place (Test.WarmResume); TransientNetwork -- a transport-only
# refusal the network gates treat as recoverable. A class the table does not
# name has none of them. The reasons per class are in the doc.
# See https://yuruna.link/42820e91-0015
$script:FailureClassRoute = [ordered]@{
    # The transient three: the condition is external and usually gone by the
    # next attempt, so the retry is the repair.
    'wait_timeout'            = @{ UnattendedRetry = $true; WarmResume = $true }
    'network_timeout'         = @{ UnattendedRetry = $true; WarmResume = $true; TransientNetwork = $true }
    # A step that never resolved an address never reached the guest, so nothing
    # it might have done is in question; on a host whose address moves under
    # it, discovery going quiet for a moment is the ordinary case.
    'ip_not_discovered'       = @{ UnattendedRetry = $true; WarmResume = $true }
    # The staged command never closed in the guest shell, so the payload never
    # ran and a retry repeats no work the guest already did.
    'input_lost'              = @{ UnattendedRetry = $true; WarmResume = $true }
    # Backed by a Repair-* primitive that is safe to run twice.
    'instrumentation_failure' = @{ UnattendedRetry = $true; WarmResume = $true }
    'host_io_blocked'         = @{ UnattendedRetry = $true; WarmResume = $true }
    # A wedged guest kernel cannot finish the step, and the same boot does not
    # recover: the repair is a new boot, which the next attempt starts. A budget
    # of its own leaves real step timeouts the minutes they are retried on. No
    # warm resume: a resume in place would wait again on the same wedged kernel.
    'guest_kernel_stalled'    = @{ UnattendedRetry = $true; RetryMinutesPerDay = 180 }
    # No source served the script, so the payload never ran: resuming the step
    # is sound. Only the shortage cases reach this class -- a digest mismatch is
    # a refusal and has its own -- and the usual cause, a host that renumbered,
    # is not one an unattended retry of the whole cycle can see past.
    'payload_unavailable'     = @{ WarmResume = $true }
    # The host's own guest-network path is down: a transport-only refusal, but
    # one no guest-level retry can influence.
    'host_network_degraded'   = @{ TransientNetwork = $true }
}

# Runner-minutes the unattended retries of one class may spend in a rolling
# 24 h: the cycles that failed with the class add their duration, and once the
# sum reaches the budget the failure pause runs to its end for that class until
# older failures leave the window. A hang that the watchdog kills is filed as a
# wait_timeout, the class whose repair is the retry, so without this bound the
# same hang would repeat at every early end of the pause; a wait that ended on a
# wedged guest kernel is filed as guest_kernel_stalled and spends that class's
# budget instead. A route entry may carry its own RetryMinutesPerDay; every
# other class has the default.
$script:DefaultRetryMinutesPerDay = 180

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

function Get-FailureClassRoute {
    <#
    .SYNOPSIS
        The routing attributes of one class -- UnattendedRetry, WarmResume and
        TransientNetwork -- each $false for a class the table does not name,
        and RetryMinutesPerDay, its runner-minute budget for unattended
        retries.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][AllowEmptyString()][string]$FailureClass)
    $route = if ($FailureClass -and $script:FailureClassRoute.Contains($FailureClass)) { $script:FailureClassRoute[$FailureClass] } else { @{} }
    return [pscustomobject]@{
        FailureClass = [string]$FailureClass; UnattendedRetry = [bool]$route['UnattendedRetry']
        WarmResume = [bool]$route['WarmResume']; TransientNetwork = [bool]$route['TransientNetwork']
        RetryMinutesPerDay = $(if ($null -ne $route['RetryMinutesPerDay']) { [int]$route['RetryMinutesPerDay'] } else { $script:DefaultRetryMinutesPerDay })
    }
}

function Get-FailureClassByRoute {
    <#
    .SYNOPSIS
        The classes that carry one routing attribute, in the table's order.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][ValidateSet('UnattendedRetry', 'WarmResume', 'TransientNetwork')][string]$Route)
    return [string[]]@($script:FailureClassRoute.Keys | Where-Object { [bool]$script:FailureClassRoute[$_][$Route] })
}

# A wrapper class says how a step gave up, not why: retry_exhausted means the
# retries ran out, and the inner class names what kept failing.
$script:WrapperFailureClass = @('retry_exhausted')

function Resolve-RoutingClass {
    <#
    .SYNOPSIS
        The class to route a failure record on: the inner cause of a wrapper
        class that carries one, else the record's own class.
    .DESCRIPTION
        One rule for every consumer -- the dispatcher, the status summary, its
        history rows and the recovery fact -- so they cannot disagree about what
        a retry_exhausted record was. A wrapper whose inner class is absent, is
        not canonical, or is the wrapper itself routes as itself.
    .OUTPUTS
        [pscustomobject] RoutingClass, FailureClass, InnerFailureClass, Wrapped.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyString()][string]$FailureClass,
        [AllowNull()][AllowEmptyString()][string]$InnerFailureClass
    )
    $wrapped = ($FailureClass -cin $script:WrapperFailureClass) -and $InnerFailureClass -and
        $InnerFailureClass -cne $FailureClass -and ($InnerFailureClass -cin $script:FailureClassEnum)
    return [pscustomobject]@{
        RoutingClass = $(if ($wrapped) { $InnerFailureClass } else { [string]$FailureClass })
        FailureClass = [string]$FailureClass; InnerFailureClass = [string]$InnerFailureClass; Wrapped = [bool]$wrapped
    }
}

# The failure schema's short link; each class has an anchor there
# (failure-class-<class>) giving its meaning and first check, the same
# destination the pool dashboard links a class to.
$script:FailureClassDocBase = 'https://yuruna.link/42820e91'

function Get-FailureClassDocUrl {
    <#
    .SYNOPSIS
        Where a class's meaning and first check are documented: the class's
        anchor in the failure schema, or the schema itself for a value the
        taxonomy does not name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$FailureClass)
    if ($FailureClass -and $FailureClass -cin $script:FailureClassEnum) { return "$($script:FailureClassDocBase)#failure-class-$FailureClass" }
    return $script:FailureClassDocBase
}

function Test-TransientNetworkFailureClass {
    <# .SYNOPSIS
        Identify transport-only refusals without treating authentication or integrity as network recovery.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$FailureClass)
    return $FailureClass -cin @(Get-FailureClassByRoute -Route TransientNetwork)
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_3794baf0dc7bb765' -Arguments @{ source = "$Source" })
        $ok = $false
    }
    if ((@($Severity) -join '|') -ne (@($script:SeverityEnum) -join '|')) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_3910eebedaccd757' -Arguments @{ source = "$Source" })
        $ok = $false
    }
    return $ok
}

Export-ModuleMember -Function Get-FailureClassEnum, Get-SeverityEnum, Get-FailureClassRoute, Get-FailureClassByRoute, Resolve-RoutingClass, Get-FailureClassDocUrl, Test-TransientNetworkFailureClass, Assert-FailureTaxonomyInSync
