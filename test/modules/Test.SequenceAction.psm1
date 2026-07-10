<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456726
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

# Sequence-action metadata registry — single source of truth for the
# failure-label switch and the verb -> required-capability table. Storage
# is delegated to Test.Registry; the $global:YurunaSequenceActions anchor
# is the cross-module-eviction-safe lookup target.
# Action contract: https://yuruna.link/test/sequences

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Cross-module-eviction-safe anchor; the only reliable way to keep sequence-action registrations across -Force re-imports.')]
param()

Import-Module (Join-Path $PSScriptRoot 'Test.Registry.psm1') -Force -DisableNameChecking -Global
# Leaf taxonomy module: the FailureClass/Severity ValidateSet below is a literal
# copy of its canonical arrays (a ValidateSet attribute arg must be a constant
# expression), kept honest by an Assert-FailureTaxonomyInSync call at load.
Import-Module (Join-Path $PSScriptRoot 'Test.FailureTaxonomy.psm1') -Force -DisableNameChecking -Global

$script:SequenceActionRegistry = New-YurunaRegistry -Name 'SequenceAction' -AnchorVar 'YurunaSequenceActions' -Comparer 'OrdinalIgnoreCase'

function Register-SequenceAction {
    <#
    .SYNOPSIS
        Register metadata for a sequence action verb. Idempotent — a second
        Register-SequenceAction with the same Name overwrites the prior
        entry (so a -Force re-import of the registering module re-asserts
        cleanly).
    .PARAMETER Name
        Action verb as it appears in a sequence YAML step's `action:`
        field (e.g. 'waitForText', 'pressKey'). Case-sensitive.
    .PARAMETER FailureLabel
        Scriptblock that builds the human-readable failure label for a
        failed step. Signature: `param([hashtable]$Context)`, where
        $Context carries Step (the parsed YAML step), Vars (the variable
        scope hashtable Expand-Variable consumes), and ExpandVariable
        (the live Expand-Variable function reference). Return a single
        string. When omitted, the default label is the verb name.
    .PARAMETER HostIORequirement
        Names of host I/O actions (Send-Key, Send-Text, Send-Click)
        this verb requires. Consumed by Test-CyclePlanCapability.
    .PARAMETER OcrRequired
        $true when this verb needs at least one enabled OCR provider.
    .PARAMETER Description
        Free-form note for the matrix dump / future docs page.
    .PARAMETER Aliases
        Alternate YAML names that resolve to this entry (legacy renames,
        e.g. 'typeAndEnter' -> 'inputTextAndEnter').
    .PARAMETER Handler
        Optional scriptblock that runs the action. Signature:
            param([hashtable]$Context)
            # Context fields: Step, StepNum, StepCount, Vars, VMName,
            # GuestKey, HostType, LogDir, RuntimeDir, ShowSensitive,
            # SequencePath, ExpandVariable. Returns [bool] (success).
        When registered, the
        engine dispatches via Invoke-SequenceActionHandler instead of
        the legacy switch arm. Migrated verbs use the Handler; the
        legacy switch remains as the safety net for verbs not yet
        migrated.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter',
        '', Justification = 'Parameters are stored in the registry, not used by this function body.')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [scriptblock]$FailureLabel,
        [string[]]$HostIORequirement = @(),
        [bool]$OcrRequired = $false,
        [string]$Description = '',
        [string[]]$Aliases = @(),
        [scriptblock]$Handler,
        # Telemetry metadata used by last_failure.json schema v2 + the
        # NDJSON per-cycle log. FailureClass is a canonical, machine-
        # readable category a downstream consumer can route on without
        # regex-matching the human label. Severity tags whether retry
        # is plausible. SuggestedRecoveries are ordered hints for an
        # autonomous remediation loop.
        [ValidateSet('ocr_timeout','network_timeout','credential_expired',
            'host_io_blocked','pattern_matched_failure','retry_exhausted',
            'snapshot_restore_failed','script_error','wait_timeout',
            'extension_error','instrumentation_failure','provisioning_failure',
            'bootstrap_sync','plan_invalid','unknown')]
        [string]$FailureClass = 'unknown',
        [ValidateSet('hard','soft','unknown')]
        [string]$Severity = 'unknown',
        [string[]]$SuggestedRecoveries = @()
    )
    # SuggestedRecoveries must draw from the same recovery vocabulary the
    # remediation dispatcher routes on (Test.Remediation). Late-bound via
    # Get-Command + soft (warn, not throw) so registration never hard-depends on
    # Test.Remediation being loaded; in the full runtime it is, so a drifted
    # token surfaces loudly at module load instead of silently routing to
    # nothing once the remediation loop is wired.
    if ($SuggestedRecoveries.Count -gt 0 -and (Get-Command Get-RecoveryRecommendationName -ErrorAction SilentlyContinue)) {
        $recoveryVocab = Get-RecoveryRecommendationName
        foreach ($recoveryToken in $SuggestedRecoveries) {
            if ($recoveryVocab -notcontains $recoveryToken) {
                Write-Warning "Register-SequenceAction '$Name': SuggestedRecoveries token '$recoveryToken' is not in the recovery vocabulary; the remediation dispatcher cannot route on it."
            }
        }
    }
    $entry = [ordered]@{
        Name                = $Name
        FailureLabel        = $FailureLabel
        Handler             = $Handler
        HostIORequirement   = @($HostIORequirement)
        OcrRequired         = $OcrRequired
        Description         = $Description
        Aliases             = @($Aliases)
        FailureClass        = $FailureClass
        Severity            = $Severity
        SuggestedRecoveries = @($SuggestedRecoveries)
    }
    & $script:SequenceActionRegistry.Register $Name $entry
    foreach ($alias in $Aliases) {
        if ($alias -ne $Name) { & $script:SequenceActionRegistry.Register $alias $entry }
    }
}

# The ValidateSet on $FailureClass/$Severity above must be a constant expression,
# so it duplicates the canonical taxonomy. Assert at module load that the literal
# still matches Test.FailureTaxonomy (warn-only, never throws). Get-Command guard
# so a standalone import without the taxonomy module degrades to no-check.
if (Get-Command Assert-FailureTaxonomyInSync -ErrorAction SilentlyContinue) {
    $null = Assert-FailureTaxonomyInSync -Source 'Test.SequenceAction Register-SequenceAction ValidateSet' `
        -FailureClass @('ocr_timeout','network_timeout','credential_expired',
            'host_io_blocked','pattern_matched_failure','retry_exhausted',
            'snapshot_restore_failed','script_error','wait_timeout',
            'extension_error','instrumentation_failure','provisioning_failure',
            'bootstrap_sync','plan_invalid','unknown') `
        -Severity @('hard','soft','unknown')
}

function Test-SequenceActionHasHandler {
    <#
    .SYNOPSIS
        $true when (Name) is registered AND has a Handler scriptblock.
        Used by the engine to decide between the registry dispatch and
        the legacy switch arm.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    $entry = & $script:SequenceActionRegistry.Get $Name
    return ($null -ne $entry -and $null -ne $entry.Handler)
}

function Invoke-SequenceActionHandler {
    <#
    .SYNOPSIS
        Invoke the registered Handler scriptblock for an action. Returns
        the Handler's [bool] result. Throws when the action is not
        registered or has no Handler -- callers check with
        Test-SequenceActionHasHandler before calling, OR catch the
        throw and fall through to a legacy implementation.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Context
    )
    $entry = & $script:SequenceActionRegistry.Get $Name
    if (-not $entry)         { throw "Sequence action '$Name' is not registered." }
    if (-not $entry.Handler) { throw "Sequence action '$Name' has no Handler scriptblock registered (legacy switch only)." }
    return [bool](& $entry.Handler $Context)
}

function Get-SequenceAction {
    <#
    .SYNOPSIS
        Look up a registered action by name (or alias). Returns $null when
        the name is unknown — callers decide whether that's a soft warning
        (typo) or a hard error.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string]$Name)
    return (& $script:SequenceActionRegistry.Get $Name)
}

function Get-SequenceActionName {
    <#
    .SYNOPSIS
        Canonical action names (excluding aliases) in registration order.
    .DESCRIPTION
        Used by docs generators and the capability matrix to enumerate
        what verbs the harness actually knows about.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param()
    $store = $script:SequenceActionRegistry.Store[0]
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($k in $store.Keys) {
        $entry = $store[$k]
        if ($seen.Add($entry.Name)) { [void]$names.Add($entry.Name) }
    }
    return @($names.ToArray())
}

function Get-SequenceActionFailureLabel {
    <#
    .SYNOPSIS
        Build the human-readable failure label for a failed step. Returns
        the verb name when no FailureLabel scriptblock is registered or
        the action isn't in the registry — same default the prior switch's
        fall-through used.
    .PARAMETER Step
        The parsed YAML step (an IDictionary; access fields via dot
        notation or .Contains/.Item).
    .PARAMETER Vars
        Variable scope for the FailureLabel scriptblock's Expand-Variable
        calls.
    .PARAMETER ExpandVariable
        Reference to the live Expand-Variable function (passed in
        because Test.SequenceAction does not import Invoke-Sequence —
        the FailureLabel scriptblocks bind it via the Context hashtable
        at call time).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Step,
        [Parameter(Mandatory)]$Vars,
        $ExpandVariable
    )
    if (-not $Step.Contains('action')) { return '' }
    $name = [string]$Step.action
    $entry = & $script:SequenceActionRegistry.Get $name
    if (-not $entry -or -not $entry.FailureLabel) { return $name }
    $ctx = @{
        Step           = $Step
        Vars           = $Vars
        ExpandVariable = $ExpandVariable
    }
    try {
        return [string](& $entry.FailureLabel $ctx)
    } catch {
        Write-Verbose "Get-SequenceActionFailureLabel: '$name' label scriptblock threw: $($_.Exception.Message)"
        return $name
    }
}

function Get-SequenceActionRequirementMap {
    <#
    .SYNOPSIS
        Verb -> @{ HostIO; OcrRequired } map consumed by
        Test-CyclePlanCapability.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    $store = $script:SequenceActionRegistry.Store[0]
    $out = [ordered]@{}
    foreach ($k in $store.Keys) {
        $entry = $store[$k]
        $out[$k] = @{
            HostIO      = @($entry.HostIORequirement)
            OcrRequired = [bool]$entry.OcrRequired
        }
    }
    return $out
}

function Clear-SequenceAction {
    <#
    .SYNOPSIS
        Drop every registration. Used by tests; production code should
        rely on the -Force re-import to refresh the registry.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('Test.SequenceAction registry', 'Clear all actions')) {
        & $script:SequenceActionRegistry.Clear
    }
}

Export-ModuleMember -Function Register-SequenceAction, Get-SequenceAction, Get-SequenceActionName, Get-SequenceActionFailureLabel, Get-SequenceActionRequirementMap, Test-SequenceActionHasHandler, Invoke-SequenceActionHandler, Clear-SequenceAction
