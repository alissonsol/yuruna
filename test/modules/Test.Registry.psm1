<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42e1b4d3-a8f9-4256-bc04-3d5e8a2b1c40
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

# Generic registry primitive shared by Test.SequenceAction and
# Test.HostIO. Each domain calls New-YurunaRegistry once at module
# load and receives a closure-bundle hashtable:
#
#     $reg = New-YurunaRegistry -Name '<DomainName>'
#     # $reg is @{
#     #   Register    = { param($name, $value) ... }  scriptblock
#     #   Get         = { param($name) ... }
#     #   GetMatrix   = { }
#     #   Clear       = { }
#     #   Has         = { param($name) ... }
#     # }
#
# The closures share a script-scope hashtable anchored under
# $global:__YurunaRegistry__<DomainName> so a `-Force` re-import of
# Test.Registry does not blow away the live entries.
# Wrappers expose domain-specific Register-*/Get-* names; this module
# stays generic so future per-cycle registries can reuse it.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Cross-module-eviction-safe anchor; the only reliable way to keep registry entries across -Force re-imports.')]
param()

# Cross-domain directory. Every New-YurunaRegistry call records its
# (Name, AnchorVar, Store) here so an introspection caller can list ALL
# Yuruna registries through a single API, with no need for callers
# to know each module's private $script:* anchor.
# Anchored under a stable $global: name so a -Force re-import of this
# module does NOT lose the cross-domain index.
if (-not (Get-Variable -Name '__YurunaRegistryDirectory' -Scope Global -ErrorAction SilentlyContinue)) {
    Set-Variable -Name '__YurunaRegistryDirectory' -Scope Global -Value ([ordered]@{})
}

function New-YurunaRegistry {
    <#
    .SYNOPSIS
        Build a closure-bundle for an in-memory, eviction-safe registry.
    .DESCRIPTION
        Returns a hashtable whose values are scriptblocks (Register,
        Get, Has, GetMatrix, Clear) closing over a shared backing
        store. The backing store is anchored under
        $global:__YurunaRegistry__<Name> (or, if -AnchorVar is given,
        $global:<AnchorVar>) so `-Force` re-imports of the calling
        module do NOT evict live entries.

        Both Test.SequenceAction and Test.HostIO use
        `[ordered]@{}` (PowerShell-default case-insensitive). Pass
        -Comparer when a different case-sensitivity policy is required.
    .PARAMETER Name
        Domain identifier (e.g. 'SequenceAction', 'HostIO'). Used to
        build the default $global: anchor name and for error messages.
    .PARAMETER AnchorVar
        Override for the $global: anchor variable name. Used by
        existing modules that have a stable historical anchor name
        (e.g. 'YurunaSequenceActions', 'YurunaHostIOProviders') and
        cannot rename without breaking cross-module visibility.
    .PARAMETER Comparer
        'OrdinalIgnoreCase' (default) uses `[ordered]@{}` which is
        case-insensitive — matches Test.SequenceAction and Test.HostIO
        today. 'Ordinal' uses [Hashtable]::new([StringComparer]::Ordinal)
        wrapped in an OrderedDictionary-compatible shape for callers
        that need case-sensitive keys.
    .OUTPUTS
        Hashtable with keys: Register, Get, Has, GetMatrix, Clear,
        Store (the live backing store, for advanced callers that need
        direct enumeration in the same style the originals did).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Returns a closure-bundle; no external state change at construction time.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseLiteralInitializerForHashtable',
        '', Justification = 'Ordinal branch needs an explicit StringComparer.Ordinal hashtable; literal @{} is case-insensitive by design.')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$AnchorVar,
        [ValidateSet('OrdinalIgnoreCase', 'Ordinal')]
        [string]$Comparer = 'OrdinalIgnoreCase'
    )

    if (-not $AnchorVar) { $AnchorVar = "__YurunaRegistry__$Name" }

    # Acquire or build the backing store. We bind it as a single-element
    # array reference ($storeRef) so Clear can replace the contents
    # atomically AND keep the $global: anchor in sync without breaking
    # any other closure's view of "the current store".
    $existing = Get-Variable -Name $AnchorVar -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $anchorPreExisted = ($null -ne $existing)
    if ($null -eq $existing) {
        if ($Comparer -eq 'Ordinal') {
            $existing = [Hashtable]::new([StringComparer]::Ordinal)
        } else {
            $existing = [ordered]@{}
        }
        Set-Variable -Name $AnchorVar -Scope Global -Value $existing
    }

    # Report the case-sensitivity of the store ACTUALLY in use, not the requested
    # -Comparer. When a global anchor already exists (a -Force re-import, or a second
    # caller sharing an AnchorVar), the requested -Comparer is not applied to the live
    # store; echoing it would misreport case-sensitivity to introspection callers and
    # would make Clear rebuild the store with the wrong comparer. This module builds
    # exactly two store shapes -- an OrderedDictionary (the case-insensitive
    # [ordered]@{} default) and a StringComparer.Ordinal Hashtable (case-sensitive) --
    # so the live store's type is an exact, truthful signal of its comparer.
    $effectiveComparer =
        if     ($existing -is [System.Collections.Specialized.OrderedDictionary]) { 'OrdinalIgnoreCase' }
        elseif ($existing -is [System.Collections.Hashtable])                     { 'Ordinal' }
        else                                                                       { $Comparer }
    if ($anchorPreExisted -and $PSBoundParameters.ContainsKey('Comparer') -and $effectiveComparer -ne $Comparer) {
        Write-Warning ("New-YurunaRegistry: anchor '$AnchorVar' for '$Name' already holds a " +
            "'$effectiveComparer' store; requested -Comparer '$Comparer' is not applied (live entries " +
            "are preserved). The reported Comparer reflects the live store.")
    }

    # $storeRef[0] is the live store; Clear rebinds it.
    $storeRef = , $existing
    $anchorName = $AnchorVar
    $domainName = $Name
    $comparerChoice = $effectiveComparer

    $register = {
        param([string]$Key, $Value)
        $storeRef[0][$Key] = $Value
    }.GetNewClosure()

    $get = {
        param([string]$Key)
        $s = $storeRef[0]
        if ($s.Contains($Key)) { return $s[$Key] }
        return $null
    }.GetNewClosure()

    $has = {
        param([string]$Key)
        return [bool]($storeRef[0].Contains($Key))
    }.GetNewClosure()

    $getMatrix = {
        $out = [ordered]@{}
        foreach ($k in $storeRef[0].Keys) {
            $out[$k] = $storeRef[0][$k]
        }
        return $out
    }.GetNewClosure()

    $clear = {
        if ($comparerChoice -eq 'Ordinal') {
            $fresh = [Hashtable]::new([StringComparer]::Ordinal)
        } else {
            $fresh = [ordered]@{}
        }
        $storeRef[0] = $fresh
        Set-Variable -Name $anchorName -Scope Global -Value $fresh
    }.GetNewClosure()

    $bundle = @{
        Name      = $domainName
        AnchorVar = $anchorName
        Comparer  = $comparerChoice
        Store     = $storeRef
        Register  = $register
        Get       = $get
        Has       = $has
        GetMatrix = $getMatrix
        Clear     = $clear
    }
    # Self-register in the cross-domain directory. Last writer wins on
    # the same Name (a -Force re-import of a domain module replaces its
    # entry with a fresh closure-bundle pointing at the same anchor).
    $global:__YurunaRegistryDirectory[$domainName] = $bundle
    return $bundle
}

function Get-YurunaRegistryDirectory {
    <#
    .SYNOPSIS
        Returns every Yuruna registry currently registered, keyed by name.
    .DESCRIPTION
        Single introspection entry point for autonomous remediation
        tooling. The returned table maps domain names (e.g.
        'SequenceAction', 'HostIO', 'OcrProvider') to their bundles
        (Register / Get / GetMatrix / Has / Clear scriptblocks plus
        Store, Name, AnchorVar, Comparer). Mutating the table doesn't
        affect the live registries; mutating a returned bundle's
        scriptblocks DOES affect the registry it represents.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads the cross-domain directory anchor created at module load.')]
    param()
    return $global:__YurunaRegistryDirectory
}

function Get-YurunaRegistrySummary {
    <#
    .SYNOPSIS
        One row per registered registry: name, key count, anchor.
    .DESCRIPTION
        Lightweight inventory view for the startup capability matrix /
        operator dashboards. Each row is a [PSCustomObject] so the
        caller can pipe to Format-Table for a human-readable layout.
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads the cross-domain directory anchor created at module load.')]
    param()
    $rows = @()
    foreach ($name in $global:__YurunaRegistryDirectory.Keys) {
        $bundle = $global:__YurunaRegistryDirectory[$name]
        $store  = $bundle.Store[0]
        $rows += [PSCustomObject]@{
            Name      = $name
            AnchorVar = $bundle.AnchorVar
            Comparer  = $bundle.Comparer
            KeyCount  = if ($store) { $store.Keys.Count } else { 0 }
        }
    }
    return $rows
}

Export-ModuleMember -Function New-YurunaRegistry, Get-YurunaRegistryDirectory, Get-YurunaRegistrySummary
