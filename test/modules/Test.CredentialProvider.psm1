<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42be89e8-3a2d-4f1f-b917-21148e97c8ef
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

# Test-only recovery / inspection helpers over the container-registry
# credential-provider registry.
#
# The registry itself (a first-match-wins map of hostname patterns to
# { Authenticator ; LoginCommand } pairs) lives in the neutral
# automation-layer module and is imported below. This module keeps only the
# helpers that no runtime path needs: Repair-Credential (self-heal after a
# 401/403 -- look up the matching provider, invoke its Authenticator, caller
# retries the push), Get-CredentialProviderMatrix (capability-matrix
# snapshot), and Clear-CredentialProvider (reset the registry between tests).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Cross-module-eviction-safe anchor.')]
param()

# The registry itself (the $global:YurunaCredentialProviders anchor,
# Register-CredentialProvider, Get-CredentialProvider, and the five built-in
# provider registrations) lives in the neutral automation-layer module so the
# runtime component-push pipeline no longer imports from test/. Import it here
# -Global -Force so the registry is populated and Register/Get are re-exposed
# to test callers and to the surviving test-only helpers below, which read the
# same $script:Providers alias of the global anchor.
Import-Module (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'automation' -AdditionalChildPath 'Yuruna.CredentialProvider.psm1') -Global -Force

$script:Providers = $global:YurunaCredentialProviders

function Get-CredentialProviderMatrix {
    <#
    .SYNOPSIS
        Snapshot of registered providers as an ordered dictionary keyed
        by provider type, value = the match Pattern.
    .DESCRIPTION
        Used by the startup capability matrix to render the active
        credential providers without exposing the Authenticator
        scriptblock.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    $out = [ordered]@{}
    foreach ($k in $script:Providers.Keys) { $out[$k] = $script:Providers[$k].Pattern }
    return $out
}

function Repair-Credential {
    <#
    .SYNOPSIS
        Self-healing primitive: re-authenticate against the registry
        whose Pattern matches $Target. Called from a component-push
        failure path after a 401/403 response.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Target,
        [hashtable]$ProviderArguments = @{}
    )
    $provider = Get-CredentialProvider -Target $Target
    if (-not $provider) {
        Write-Warning "Repair-Credential: no provider matches '$Target'. Registered patterns: $(($script:Providers.Values | ForEach-Object { $_.Pattern }) -join ', ')"
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($Target, "Re-authenticate via $($provider.Type) provider")) { return $true }
    try { return [bool](& $provider.Authenticator $Target $ProviderArguments) }
    catch { Write-Warning "Repair-Credential ($($provider.Type)): $($_.Exception.Message)"; return $false }
}

function Clear-CredentialProvider {
    <#
    .SYNOPSIS
        Drop every registered credential provider.
    .DESCRIPTION
        Tests-only: production code relies on -Force re-import to
        refresh registrations. Empties the registry in place so it is
        observably empty to EVERY holder of it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('Test.CredentialProvider registry', 'Clear all providers')) {
        # Mutate the shared dictionary; do NOT rebind the names to a fresh one.
        # Yuruna.CredentialProvider aliases this same object into its own
        # $script:Providers at import, and that alias is what Get-CredentialProvider
        # and Register-CredentialProvider actually read and write. Rebinding here
        # would leave that alias pointing at the original dictionary: the matrix
        # would report an empty registry while lookups kept resolving the live
        # built-ins, and a provider registered after the clear would land in the
        # orphaned copy where nothing can see it. A test that believed it had
        # isolated the registry would then be exercising the real providers -- and
        # Repair-Credential would invoke a real `az acr login`.
        $global:YurunaCredentialProviders.Clear()
        $script:Providers = $global:YurunaCredentialProviders
    }
}

Export-ModuleMember -Function Get-CredentialProviderMatrix, Repair-Credential, Clear-CredentialProvider
