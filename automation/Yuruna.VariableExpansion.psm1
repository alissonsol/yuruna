<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42c1d2e3-f4a5-4678-9012-3c4d5e6f7a8b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.VariableExpansion
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

<#
.SYNOPSIS
    Shared "walk a variable bag, optionally expand each value, push to
    env, mirror into a caller-supplied sink" helpers used by both
    [Yuruna.Workload](Yuruna.Workload.psm1) and
    [Yuruna.Component](Yuruna.Component.psm1).
.DESCRIPTION
    The two consumers used to walk the same data shapes in opposite
    flavours: Workload always expanded values (so a `${env:X}` reference
    in a workload variable resolves against the layer below it),
    Component always emitted them verbatim (its comment block stated
    the layering happens at the YAML level, not via expansion). Both
    walked the same two structures -- a flat `variables` hashtable and
    the nested `resources.output.yml` shape with its `globalVariables`
    special case -- and both pushed every key to env so subsequent
    `${env:...}` references resolved against the merged state. Hoisting
    the walk here, with an opt-in `-NoExpand` switch, means a future
    schema tweak (a new sentinel resource type, a new debug pattern)
    lands in one place rather than three.
#>

function Set-ExpandedVariableHashtable {
    <#
    .SYNOPSIS
        Walk a `variables` hashtable: optionally string-expand each
        value, push it to env, mirror into a sink, optionally cache.
    .PARAMETER Variables
        The hashtable / ordered dict produced by `ConvertFrom-File`.
        $null or empty is silently a no-op so callers don't need a
        guard at every layer.
    .PARAMETER Sink
        Optional ordered dict the helper writes each (key, value) pair
        into. Callers use this to build a merged map for downstream
        YAML rendering (e.g. helm `values.yaml`).
    .PARAMETER DebugLabel
        When set, emits `Write-Debug "$DebugLabel[$key] = $value"` per
        key. Use the layer name (`globalVariables`,
        `workloadVariables`, `componentVariables`) so the per-cycle
        debug log shows where each value entered the merged map.
    .PARAMETER CacheExpanded
        Write the expanded value back into $Variables[$key]. Workload
        uses this on its first global-pass so the second per-deployment
        pass doesn't pay re-expansion cost. Implies (and is a no-op
        under) -NoExpand.
    .PARAMETER WarnOnEmpty
        Emit a Write-Debug warning when a key resolved to the empty
        string. Component / Workload use this on the deepest layer
        (deployment-locals) where an empty value almost always means a
        misspelled `${env:...}` reference.
    .PARAMETER NoExpand
        Skip the `ExpandString` step and push raw values to env / sink.
        Component uses this because its layering happens at the YAML
        level; calling ExpandString there would interpolate against
        whatever happens to be in env at the moment, which is exactly
        what the layered model is meant to avoid.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates only env vars and a caller-supplied sink; ShouldProcess would be noise per key.')]
    param(
        [Parameter()]$Variables,
        [Parameter()][System.Collections.IDictionary]$Sink,
        [string]$DebugLabel,
        [switch]$CacheExpanded,
        [switch]$WarnOnEmpty,
        [switch]$NoExpand
    )
    if ($null -eq $Variables -or $null -eq $Variables.Keys) { return }
    $keys = @($Variables.Keys)
    foreach ($key in $keys) {
        $raw = $Variables[$key]
        $value = if ($NoExpand) { $raw } else { $ExecutionContext.InvokeCommand.ExpandString($raw) }
        if ($WarnOnEmpty -and [string]::IsNullOrEmpty($value)) { Write-Debug "WARNING: empty value for $key" }
        if ($DebugLabel) { Write-Debug "$DebugLabel[$key] = $value" }
        Set-Item -Path Env:$key -Value $value
        if ($Sink) { $Sink[$key] = $value }
        # -CacheExpanded only matters when expansion happened; in -NoExpand
        # mode the value already equals the raw input, so writing back is
        # a no-op. Guarding here keeps the contract explicit.
        if ($CacheExpanded -and -not $NoExpand) { $Variables[$key] = $value }
    }
}

function Set-ExpandedResourcesOutput {
    <#
    .SYNOPSIS
        Walk the `resources.output.yml` shape: optionally string-expand
        each leaf value, push it to env under a flattened key, mirror
        into a sink.
    .DESCRIPTION
        `resources.output.yml` has two layers: a `globalVariables`
        section whose keys land at the top of env (flat) and one
        section per terraform resource whose keys carry the resource
        name as a dotted prefix in env (`registry.host`,
        `cluster.endpoint`, ...). The `globalVariables` leaves are raw
        scalars; resource leaves are `{ value: ..., sensitive: ... }`
        dicts. The walker handles both shapes; callers see one
        function instead of two.
    .PARAMETER ResourcesOutputYaml
        The parsed `resources.output.yml`. $null or empty is silently
        a no-op.
    .PARAMETER Sink
        Optional ordered dict the helper writes each flattened
        (resourceKey, value) pair into.
    .PARAMETER EmitDebug
        When set, emits `Write-Debug "globalVariables[$key] = ..."` or
        `Write-Debug "resourcesOutput[$key] = ..."` per flattened key.
    .PARAMETER NoExpand
        Skip the `ExpandString` step. See the matching parameter on
        Set-ExpandedVariableHashtable for the why.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates only env vars and a caller-supplied sink; ShouldProcess would be noise per key.')]
    param(
        [Parameter()]$ResourcesOutputYaml,
        [Parameter()][System.Collections.IDictionary]$Sink,
        [switch]$EmitDebug,
        [switch]$NoExpand
    )
    if ($null -eq $ResourcesOutputYaml -or $null -eq $ResourcesOutputYaml.Keys) { return }
    foreach ($resource in $ResourcesOutputYaml.Keys) {
        $isGlobal = ($resource -eq 'globalVariables')
        foreach ($key in $ResourcesOutputYaml.$resource.Keys) {
            if ($isGlobal) {
                $resourceKey = "$key"
                $raw = $ResourcesOutputYaml.$resource[$key]
            } else {
                $resourceKey = "$resource.$key"
                $raw = $ResourcesOutputYaml.$resource[$key].value
            }
            $value = if ($NoExpand) { $raw } else { $ExecutionContext.InvokeCommand.ExpandString($raw) }
            if ($EmitDebug) {
                $label = if ($isGlobal) { 'globalVariables' } else { 'resourcesOutput' }
                Write-Debug "$label[$resourceKey] = $value"
            }
            Set-Item -Path Env:$resourceKey -Value $value
            if ($Sink) { $Sink[$resourceKey] = $value }
        }
    }
}

Export-ModuleMember -Function Set-ExpandedVariableHashtable, Set-ExpandedResourcesOutput
