<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42d2e3f4-a5b6-4789-0123-4d5e6f7a8b9c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.Component.Registry
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
    Resolves the per-cycle registry-login command for the component-push
    pipeline in [Yuruna.Component](Yuruna.Component.psm1) by reusing the
    neutral credential-provider registry
    ([Yuruna.CredentialProvider.psm1](Yuruna.CredentialProvider.psm1)).
.DESCRIPTION
    Both surfaces -- the runtime push pipeline here and the self-heal path
    after a 401 -- need exactly the same answer to "what is the login
    command for <registry>?". Hosting the providers in one
    automation-layer module ([Yuruna.CredentialProvider]) means a new
    registry kind (a private repo on a corp Nexus, a Harbor instance, ...)
    is registered in one place and picked up by both surfaces, with no
    dependency from the automation layer into the test tree.
#>

# Resolve the sibling module path once at module load. $PSScriptRoot is
# automation/, where Yuruna.CredentialProvider.psm1 also lives.
$script:CredentialProviderModulePath = Join-Path `
    -Path $PSScriptRoot `
    -ChildPath 'Yuruna.CredentialProvider.psm1'

if (Test-Path -LiteralPath $script:CredentialProviderModulePath) {
    # -Global so the registered providers stay reachable from the
    # caller's session (Publish-ComponentList runs in a nested
    # scriptblock; without -Global a non-Global re-import wouldn't
    # expose Get-CredentialProvider to the outer scope).
    Import-Module -Name $script:CredentialProviderModulePath -Global -Force
} else {
    Write-Warning "Yuruna.Component.Registry: Yuruna.CredentialProvider.psm1 not found at $($script:CredentialProviderModulePath); component-push registry login will be skipped for every registry."
}

function Resolve-ComponentRegistryLogin {
    <#
    .SYNOPSIS
        Look up the credential provider for $RegistryLocation and return
        the shell command to log in (or $null when no login is required).
    .DESCRIPTION
        Publish-ComponentList pipes the returned string through
        Invoke-ComponentCommand so the registryLogin phase shares the
        same docker.stderr.log + docker.rc capture path as build / tag /
        push. Returning $null is the "no login needed" signal -- caller
        silently skips the phase for any registry without a registered
        credential provider.
    .PARAMETER RegistryLocation
        Hostname (or hostname/path) read from the per-component
        componentVars["<registryName>.registryLocation"]. Empty / $null
        is silently a no-op.
    .OUTPUTS
        [string] login command, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$RegistryLocation)
    if ([string]::IsNullOrWhiteSpace($RegistryLocation)) { return $null }
    if (-not (Get-Command Get-CredentialProvider -ErrorAction SilentlyContinue)) {
        Write-Verbose "Resolve-ComponentRegistryLogin: Get-CredentialProvider not in scope; skipping login for '$RegistryLocation'."
        return $null
    }
    $provider = Get-CredentialProvider -Target $RegistryLocation
    if (-not $provider) {
        Write-Verbose "Resolve-ComponentRegistryLogin: no provider matches '$RegistryLocation'."
        return $null
    }
    if (-not $provider.LoginCommand) {
        Write-Verbose "Resolve-ComponentRegistryLogin: provider '$($provider.Type)' has no LoginCommand (self-heal only); skipping pipeline login."
        return $null
    }
    $cmd = & $provider.LoginCommand $RegistryLocation
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $null }
    return [string]$cmd
}

Export-ModuleMember -Function Resolve-ComponentRegistryLogin
