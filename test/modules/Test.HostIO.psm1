<#PSScriptInfo
.VERSION 2026.10.14
.GUID 42987493-0ebe-43b4-b8e8-475951cbb931
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

# See https://yuruna.link/4213a0b3-0084

# See https://yuruna.link/4213a0b3-0085

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Cross-module-eviction-safe anchor; the only reliable way to keep host-I/O registrations across -Force re-imports.')]
param()

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking


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
        dispatchers in Test.SequenceEngine.psm1) wrap with try/catch.
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
        throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_2e7c522081d7df58' -Arguments @{ action = "$Action"; hostType = "$HostType"; known = "$known" })
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
    if ($PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'runner.operator_38dba2a38524aa74'), (Format-YurunaOperatorMessage -Key 'runner.operator_01286d1a561aca1c'))) {
        & $script:HostIORegistry.Clear
    }
}

Export-ModuleMember -Function Register-HostIOProvider, Test-HostIOActionAvailable, Invoke-HostIOAction, Get-HostIOProviderMatrix, Clear-HostIOProvider
