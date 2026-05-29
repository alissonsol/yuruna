<#PSScriptInfo
.VERSION 2026.05.29
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

# Container-registry / cloud-credential refresh registry, fourth of four paired registry+recovery modules.
#
# Today `automation/Yuruna.Component.psm1` only handles `*.azurecr.io`
# via `az acr login`. ECR / GAR / Docker Hub / generic-docker-login are
# the opportunities.md P0 -- this registry is the structural fix.
#
# Each provider registers an Authenticator scriptblock. The Repair-
# Credential primitive (called from a component-push failure path)
# looks up the registry hostname pattern and invokes the matching
# authenticator, then the caller retries the push.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Cross-module-eviction-safe anchor.')]
param()

if (-not $global:YurunaCredentialProviders) {
    $global:YurunaCredentialProviders = [ordered]@{}
}
$script:Providers = $global:YurunaCredentialProviders

function Register-CredentialProvider {
    <#
    .PARAMETER Pattern
        Regex matched against the target hostname (e.g. '\.amazonaws\.com$',
        '\.pkg\.dev$', '\.azurecr\.io$', '^docker\.io$', 'index\.docker\.io').
    .PARAMETER Authenticator
        Scriptblock that performs the auth, signature:
            param([string]$Target [, [hashtable]$Args])
            # returns [bool]
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter',
        '', Justification = 'Parameters land in the registry.')]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][scriptblock]$Authenticator
    )
    $script:Providers[$Type] = @{ Pattern = $Pattern; Authenticator = $Authenticator }
}

function Get-CredentialProvider {
    <#
    .SYNOPSIS
        Look up the first registered provider whose Pattern regex
        matches $Target. Returns the @{ Type; Pattern; Authenticator }
        entry or $null when no match.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Target)
    foreach ($key in $script:Providers.Keys) {
        $p = $script:Providers[$key]
        if ($Target -match $p.Pattern) { return @{ Type = $key; Pattern = $p.Pattern; Authenticator = $p.Authenticator } }
    }
    return $null
}

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
        refresh registrations. Resets both the script-local and global
        anchor so the registry is observably empty.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('Test.CredentialProvider registry', 'Clear all providers')) {
        $script:Providers = [ordered]@{}
        $global:YurunaCredentialProviders = $script:Providers
    }
}

# Built-in: Azure Container Registry (the legacy hard-coded path from
# Yuruna.Component.psm1). Other providers (ECR, GAR, Docker Hub) can
# register here without touching Yuruna.Component.
Register-CredentialProvider -Type 'azurecr' `
    -Pattern '\.azurecr\.io$' `
    -Authenticator {
        param([string]$Target, [hashtable]$a)
        # $a is part of the uniform Authenticator signature (other
        # providers will consume args); touch it so PSSA sees it.
        $null = $a
        $registry = ($Target -split '/')[0]
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
            Write-Warning "azurecr Authenticator: 'az' CLI not on PATH; cannot run 'az acr login'."
            return $false
        }
        & az acr login --name $registry | Out-Null
        return ($LASTEXITCODE -eq 0)
    }

Export-ModuleMember -Function Register-CredentialProvider, Get-CredentialProvider, Get-CredentialProviderMatrix, Repair-Credential, Clear-CredentialProvider
