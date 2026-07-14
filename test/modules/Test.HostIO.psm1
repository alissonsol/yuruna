<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456724
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

# Host I/O provider registry. The model mirrors Test.OcrEngine.psm1: each
# (HostType, Action) pair is a registered scriptblock; the dispatcher
# looks the pair up and invokes it. A single lookup table replaces what
# would otherwise be parallel if/elseif chains on $HostType inside every
# action (Send-Key, Send-Text, Send-Click, ...), and a missing backend
# is surfaced via the capability matrix rather than as "Unknown host:
# $HostType" deep in the sequence run.
#
# The capability matrix (Get-HostIOProviderMatrix) provides startup-time
# visibility of what each host can actually do -- see docs/host-io.md.

# Two-level table: { HostType -> { Action -> scriptblock } }. Ordered so
# Get-HostIOProviderMatrix returns hosts and actions in the registration
# order, which (today) puts the local host first in any matrix dump.
#
# The outer table is backed by the shared Test.Registry primitive
# (New-YurunaRegistry). The $global:YurunaHostIOProviders anchor name
# is the documented entry point for cross-module readers that inspect
# the registry directly. Inner per-host hashtables remain plain
# [ordered]@{} (the primitive holds them as opaque values).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Cross-module-eviction-safe anchor; the only reliable way to keep host-I/O registrations across -Force re-imports.')]
param()

Import-Module (Join-Path $PSScriptRoot 'Test.Registry.psm1') -Force -DisableNameChecking -Global

$script:HostIORegistry = New-YurunaRegistry -Name 'HostIO' -AnchorVar 'YurunaHostIOProviders' -Comparer 'OrdinalIgnoreCase'

function Register-HostIOProvider {
    <#
    .SYNOPSIS
        Bind a scriptblock to (HostType, Action). The block receives a
        single hashtable of named arguments and must return [bool].
    .PARAMETER HostType
        Stable host identifier ('host.windows.hyper-v', 'host.macos.utm',
        'host.ubuntu.kvm').
    .PARAMETER Action
        Action verb ('Send-Key', 'Send-Text', 'Send-Click', 'Get-VMScreenshot', ...).
    .PARAMETER Implementation
        Scriptblock signature: `param([hashtable]$a) ...` -- returns [bool]
        for action verbs whose contract is success/failure.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter',
        '', Justification = 'Parameters are stored in the registry, not used by this function body.')]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][scriptblock]$Implementation
    )
    $hostMap = & $script:HostIORegistry.Get $HostType
    if (-not $hostMap) {
        $hostMap = [ordered]@{}
        & $script:HostIORegistry.Register $HostType $hostMap
    }
    $hostMap[$Action] = $Implementation
}

function Test-HostIOActionAvailable {
    <#
    .SYNOPSIS
        $true when (HostType, Action) is registered. Useful for the
        startup capability matrix and for sequence validators that want
        to refuse a YAML referencing an action no host can run.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$Action
    )
    $hostMap = & $script:HostIORegistry.Get $HostType
    if (-not $hostMap) { return $false }
    return [bool]($hostMap.Contains($Action))
}

function Invoke-HostIOAction {
    <#
    .SYNOPSIS
        Dispatch to the scriptblock registered for (HostType, Action).
        Throws if the pair is not registered -- callers that need
        graceful degradation (the existing Send-Key/Send-Text/Send-Click
        dispatchers in Invoke-Sequence.psm1) wrap with try/catch.
    .PARAMETER Arguments
        Hashtable forwarded as the single positional argument to the
        scriptblock.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$Action,
        [hashtable]$Arguments = @{}
    )
    # Single registry lookup on the hot send path (this dispatcher runs on every
    # keystroke/click), then branch on the local reference. The availability
    # decision and the not-available message are derived from this one $hostMap
    # instead of re-invoking the registry Get inside Test-HostIOActionAvailable
    # and again here.
    $hostMap = & $script:HostIORegistry.Get $HostType
    if (-not $hostMap -or -not $hostMap.Contains($Action)) {
        $known = if ($hostMap) { ($hostMap.Keys -join ', ') } else { '<host not registered>' }
        throw "Host I/O action '$Action' is not available on '$HostType' (available actions: $known)."
    }
    $impl = $hostMap[$Action]
    return (& $impl $Arguments)
}

function Get-HostIOProviderMatrix {
    <#
    .SYNOPSIS
        Snapshot of the registry as an ordered hashtable of
        HostType -> [string[]] of action names. Read-only; mutating
        the result does not affect the registry. Consumed by the
        startup capability matrix.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    $store = $script:HostIORegistry.Store[0]
    $out = [ordered]@{}
    foreach ($h in $store.Keys) {
        $out[$h] = @($store[$h].Keys)
    }
    return $out
}

function Clear-HostIOProvider {
    <#
    .SYNOPSIS
        Drop every registration. Used by tests; production code should
        rely on -Force re-import to refresh the registry.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('Test.HostIO registry', 'Clear all providers')) {
        & $script:HostIORegistry.Clear
    }
}

Export-ModuleMember -Function Register-HostIOProvider, Test-HostIOActionAvailable, Invoke-HostIOAction, Get-HostIOProviderMatrix, Clear-HostIOProvider
