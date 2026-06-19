<#PSScriptInfo
.VERSION 2026.06.19
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
# A first-match-wins registry maps hostname patterns to
# { Authenticator ; LoginCommand } pairs. Repair-Credential (called
# from a component-push failure path after a 401/403) looks up the
# provider whose pattern matches the target hostname, invokes its
# Authenticator, and the caller retries the push. Adding support for a
# new registry kind (ECR / GAR / Docker Hub / Harbor / ...) is a single
# Register-CredentialProvider call -- no change to the recovery path.

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
    .PARAMETER LoginCommand
        Optional scriptblock that, given $Target, returns the shell
        command string a batch pipeline can pipe through its own
        logging path ([Yuruna.Component.Registry] uses this so the
        registryLogin phase shares docker.stderr.log / docker.rc with
        build / tag / push). Signature:
            param([string]$Target)
            # returns [string] command, or $null to skip the step
        Providers without a LoginCommand still work for the self-heal
        path (Repair-Credential -> Authenticator); only the batch
        pipeline silently skips them.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter',
        '', Justification = 'Parameters land in the registry.')]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][scriptblock]$Authenticator,
        [scriptblock]$LoginCommand
    )
    $script:Providers[$Type] = @{
        Pattern       = $Pattern
        Authenticator = $Authenticator
        LoginCommand  = $LoginCommand
    }
}

function Get-CredentialProvider {
    <#
    .SYNOPSIS
        Look up the first registered provider whose Pattern regex
        matches $Target. Returns the @{ Type; Pattern; Authenticator;
        LoginCommand } entry or $null when no match.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Target)
    foreach ($key in $script:Providers.Keys) {
        $p = $script:Providers[$key]
        if ($Target -match $p.Pattern) {
            return @{
                Type          = $key
                Pattern       = $p.Pattern
                Authenticator = $p.Authenticator
                LoginCommand  = $p.LoginCommand
            }
        }
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

# Built-in providers. Order matters: Get-CredentialProvider is
# first-match-wins, so the specific-host patterns (azurecr, ecr, gar,
# dockerhub) precede the catch-all docker-generic. Patterns anchor at
# the end of the hostname so a path-suffixed target ('foo.azurecr.io/img')
# still matches via the (-split '/')[0] step inside each Authenticator.
#
# Each provider exports two scriptblocks with disjoint use cases:
#   - Authenticator : self-heal path (Repair-Credential after a 401).
#                     Runs auth in-process; returns [bool].
#   - LoginCommand  : batch pipeline (Yuruna.Component push). Returns
#                     a shell command string the caller pipes through
#                     its own logging wrapper; returns $null when the
#                     environment doesn't have the credentials.
#
# Credential-bearing env vars (Docker Hub / generic):
#   YURUNA_DOCKER_HUB_USERNAME / YURUNA_DOCKER_HUB_PASSWORD
#   YURUNA_REGISTRY_USERNAME   / YURUNA_REGISTRY_PASSWORD

# --- Azure Container Registry --------------------------------------------
Register-CredentialProvider -Type 'azurecr' `
    -Pattern '\.azurecr\.io(/|$)' `
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
    } `
    -LoginCommand {
        param([string]$Target)
        $registry = ($Target -split '/')[0]
        return "az acr login -n $registry"
    }

# --- AWS Elastic Container Registry --------------------------------------
# Host shape: <account>.dkr.ecr.<region>.amazonaws.com. Region is the
# fourth dotted segment; aws ecr get-login-password needs it explicitly.
Register-CredentialProvider -Type 'ecr' `
    -Pattern '\.dkr\.ecr\.[^.]+\.amazonaws\.com(/|$)' `
    -Authenticator {
        param([string]$Target, [hashtable]$a)
        $null = $a
        $registryHost = ($Target -split '/')[0]
        $region = ($registryHost -split '\.')[3]
        if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
            Write-Warning "ecr Authenticator: 'aws' CLI not on PATH; cannot run 'aws ecr get-login-password'."
            return $false
        }
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            Write-Warning "ecr Authenticator: 'docker' CLI not on PATH; cannot complete login."
            return $false
        }
        $password = & aws ecr get-login-password --region $region
        if ($LASTEXITCODE -ne 0) { return $false }
        $password | & docker login --username AWS --password-stdin $registryHost | Out-Null
        return ($LASTEXITCODE -eq 0)
    } `
    -LoginCommand {
        param([string]$Target)
        $registryHost = ($Target -split '/')[0]
        $region = ($registryHost -split '\.')[3]
        return "aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $registryHost"
    }

# --- Google Artifact Registry --------------------------------------------
# Host shape: <region>-docker.pkg.dev (e.g. us-central1-docker.pkg.dev).
# Token-based login -- no service-account JSON needed when gcloud has an
# active credential context.
Register-CredentialProvider -Type 'gar' `
    -Pattern '-docker\.pkg\.dev(/|$)' `
    -Authenticator {
        param([string]$Target, [hashtable]$a)
        $null = $a
        $registryHost = ($Target -split '/')[0]
        if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
            Write-Warning "gar Authenticator: 'gcloud' CLI not on PATH; cannot run 'gcloud auth print-access-token'."
            return $false
        }
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            Write-Warning "gar Authenticator: 'docker' CLI not on PATH; cannot complete login."
            return $false
        }
        $token = & gcloud auth print-access-token
        if ($LASTEXITCODE -ne 0) { return $false }
        $token | & docker login --username oauth2accesstoken --password-stdin "https://$registryHost" | Out-Null
        return ($LASTEXITCODE -eq 0)
    } `
    -LoginCommand {
        param([string]$Target)
        $registryHost = ($Target -split '/')[0]
        return "gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin https://$registryHost"
    }

# --- Docker Hub ----------------------------------------------------------
# Pattern matches the canonical 'docker.io' and the legacy 'index.docker.io'
# alias. Credentials must be in YURUNA_DOCKER_HUB_USERNAME +
# YURUNA_DOCKER_HUB_PASSWORD; when they're not, the LoginCommand returns
# $null so the operator's pre-existing docker credential helper handles
# the push without an extra interactive prompt.
Register-CredentialProvider -Type 'dockerhub' `
    -Pattern '^(index\.)?docker\.io(/|$)' `
    -Authenticator {
        param([string]$Target, [hashtable]$a)
        $null = $a, $Target
        $userName = $env:YURUNA_DOCKER_HUB_USERNAME
        $password = $env:YURUNA_DOCKER_HUB_PASSWORD
        if ([string]::IsNullOrEmpty($userName) -or [string]::IsNullOrEmpty($password)) {
            Write-Warning "dockerhub Authenticator: set YURUNA_DOCKER_HUB_USERNAME and YURUNA_DOCKER_HUB_PASSWORD env vars to enable Docker Hub login."
            return $false
        }
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            Write-Warning "dockerhub Authenticator: 'docker' CLI not on PATH."
            return $false
        }
        $password | & docker login --username $userName --password-stdin | Out-Null
        return ($LASTEXITCODE -eq 0)
    } `
    -LoginCommand {
        param([string]$Target)
        $null = $Target
        if ([string]::IsNullOrEmpty($env:YURUNA_DOCKER_HUB_USERNAME) -or [string]::IsNullOrEmpty($env:YURUNA_DOCKER_HUB_PASSWORD)) {
            return $null
        }
        return '$env:YURUNA_DOCKER_HUB_PASSWORD | docker login --username $env:YURUNA_DOCKER_HUB_USERNAME --password-stdin'
    }

# --- Generic Docker Login (catch-all, registered last) -------------------
# Any host the more-specific providers above did not claim. Requires
# YURUNA_REGISTRY_USERNAME + YURUNA_REGISTRY_PASSWORD; when they're not
# set the LoginCommand returns $null and the push proceeds against
# whatever credential the operator already configured locally.
Register-CredentialProvider -Type 'docker-generic' `
    -Pattern '.+' `
    -Authenticator {
        param([string]$Target, [hashtable]$a)
        $null = $a
        $userName = $env:YURUNA_REGISTRY_USERNAME
        $password = $env:YURUNA_REGISTRY_PASSWORD
        $registryHost = ($Target -split '/')[0]
        if ([string]::IsNullOrEmpty($userName) -or [string]::IsNullOrEmpty($password)) {
            Write-Warning "docker-generic Authenticator: set YURUNA_REGISTRY_USERNAME and YURUNA_REGISTRY_PASSWORD env vars to enable login for '$registryHost'."
            return $false
        }
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            Write-Warning "docker-generic Authenticator: 'docker' CLI not on PATH."
            return $false
        }
        $password | & docker login --username $userName --password-stdin $registryHost | Out-Null
        return ($LASTEXITCODE -eq 0)
    } `
    -LoginCommand {
        param([string]$Target)
        if ([string]::IsNullOrEmpty($env:YURUNA_REGISTRY_USERNAME) -or [string]::IsNullOrEmpty($env:YURUNA_REGISTRY_PASSWORD)) {
            return $null
        }
        $registryHost = ($Target -split '/')[0]
        return "`$env:YURUNA_REGISTRY_PASSWORD | docker login --username `$env:YURUNA_REGISTRY_USERNAME --password-stdin $registryHost"
    }

Export-ModuleMember -Function Register-CredentialProvider, Get-CredentialProvider, Get-CredentialProviderMatrix, Repair-Credential, Clear-CredentialProvider
