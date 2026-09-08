<#PSScriptInfo
.VERSION 2026.09.08
.GUID 424ac6f6-cc32-4fff-beb1-ec808f35ab29
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

# Test-only Repair-Credential / matrix / reset helpers over the
# credential-provider registry in automation/Yuruna.CredentialProvider.psm1 --
# see docs/authentication.md#component-registry-login.

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
        Available to render the active providers in a capability matrix.
        Get-HostCapabilityMatrix does NOT carry a credentials key today, so
        nothing calls this; it is kept because the shape it returns is the
        one such a matrix would need. Reads the active
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
        Re-authenticate against the registry whose Pattern matches $Target.

        NOT WIRED. No production path calls this: the remediation dispatcher
        classifies a 401 as credential_expired and returns a recommendation
        rather than acting on it. Invoking a real `az acr login` / `docker
        login` from a failure path is a behavior change on a live push, and
        needs a class allow-list plus an attempt cap first, so a misclassified
        failure cannot drive repeated logins.
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
