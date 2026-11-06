<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42ef082c-e8a7-4b9b-a65e-775dd8f26574
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.CredentialProvider
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

# First-match-wins registry mapping a registry hostname to its login
# Authenticator/LoginCommand -- see docs/authentication.md#component-registry-login.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Cross-module-eviction-safe anchor.')]
param()

Import-Module (Join-Path $PSScriptRoot 'Yuruna.Globalization.psm1') -DisableNameChecking
# Invoke-YurunaToolWithDeadline, the deploy tools' deadline, under which every
# login below runs. -Global -Force so the import does not evict an instance
# another module loaded.
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Retry.psm1') -Global -Force
if (-not $global:YurunaCredentialProviders) {
    $global:YurunaCredentialProviders = [ordered]@{}
}
$script:Providers = $global:YurunaCredentialProviders
# Bound of one login, in seconds: the CLI's token exchange and the docker login
# together. A login reaches a registry or an identity service, and one that
# stops answering would otherwise hold a deploy's step past its budget. Well
# past a normal login, so it ends only one that stopped making progress; the
# stopped login reports exit 124 and the Authenticator answers $false.
$script:RegistryLoginTimeoutSeconds = 120
# The providers this module registers below. A provider a project registers
# is any other type, and Get-CredentialProvider consults those first: the
# built-in docker-generic matches every host, so a provider registered after
# it would otherwise never be reached.
$script:BuiltInProviderType = @('azurecr', 'ecr', 'gar', 'dockerhub', 'docker-generic')

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
        Look up the first provider whose Pattern regex matches $Target: a
        project's providers first, the most recently registered first, then
        the built-in ones in their registration order. Returns the
        @{ Type; Pattern; Authenticator; LoginCommand } entry or $null when
        no match.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Target)
    # A project's providers first, the most recently registered first, then the
    # built-in ones in their order, with the catch-all last.
    $keys = @($script:Providers.Keys)
    $external = @($keys | Where-Object { $_ -cnotin $script:BuiltInProviderType })
    [array]::Reverse($external)
    foreach ($key in @($external) + @($keys | Where-Object { $_ -cin $script:BuiltInProviderType })) {
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

# Built-in providers. First-match-wins: the specific-host patterns (azurecr,
# ecr, gar, dockerhub) precede the catch-all docker-generic, and patterns
# anchor the hostname so a path-suffixed target ('foo.azurecr.io/img') still
# matches. The Authenticator vs LoginCommand contract and the credential
# env vars: https://yuruna.link/427ac634-0009

# --- REGION: Azure Container Registry
Register-CredentialProvider -Type 'azurecr' `
    -Pattern '\.azurecr\.io(/|$)' `
    -Authenticator {
        param([string]$Target, [hashtable]$a)
        # $a is part of the uniform Authenticator signature (other
        # providers will consume args); touch it so PSSA sees it.
        $null = $a
        $registry = ($Target -split '/')[0]
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_a85e6d3c95a02f33')
            return $false
        }
        $outcome = @{}
        $null = Invoke-YurunaToolWithDeadline -Label "az acr login -n $registry" -TimeoutSeconds $script:RegistryLoginTimeoutSeconds -Outcome $outcome -ScriptBlock {
            & az acr login --name $registry | Out-Null
        }
        return (-not $outcome['TimedOut'] -and $LASTEXITCODE -eq 0)
    } `
    -LoginCommand {
        param([string]$Target)
        $registry = ($Target -split '/')[0]
        return "az acr login -n $registry"
    }

# --- REGION: AWS Elastic Container Registry
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
            Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_cb3a96dd4251d42c')
            return $false
        }
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_48ffd650c4a65b3b')
            return $false
        }
        $outcome = @{}
        $null = Invoke-YurunaToolWithDeadline -Label "aws ecr get-login-password | docker login $registryHost" -TimeoutSeconds $script:RegistryLoginTimeoutSeconds -Outcome $outcome -ScriptBlock {
            $password = & aws ecr get-login-password --region $region
            if ($LASTEXITCODE -ne 0) { return }
            $password | & docker login --username AWS --password-stdin $registryHost | Out-Null
        }
        return (-not $outcome['TimedOut'] -and $LASTEXITCODE -eq 0)
    } `
    -LoginCommand {
        param([string]$Target)
        $registryHost = ($Target -split '/')[0]
        $region = ($registryHost -split '\.')[3]
        return "aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $registryHost"
    }

# --- REGION: Google Artifact Registry
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
            Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_c53fba62e994e87a')
            return $false
        }
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_f4bb767139b39bba')
            return $false
        }
        $outcome = @{}
        $null = Invoke-YurunaToolWithDeadline -Label "gcloud auth print-access-token | docker login https://$registryHost" -TimeoutSeconds $script:RegistryLoginTimeoutSeconds -Outcome $outcome -ScriptBlock {
            $token = & gcloud auth print-access-token
            if ($LASTEXITCODE -ne 0) { return }
            $token | & docker login --username oauth2accesstoken --password-stdin "https://$registryHost" | Out-Null
        }
        return (-not $outcome['TimedOut'] -and $LASTEXITCODE -eq 0)
    } `
    -LoginCommand {
        param([string]$Target)
        $registryHost = ($Target -split '/')[0]
        return "gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin https://$registryHost"
    }

# --- REGION: Docker Hub
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
            Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_2b40950464027594')
            return $false
        }
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_2a3b65a19646de9d')
            return $false
        }
        $outcome = @{}
        $null = Invoke-YurunaToolWithDeadline -Label 'docker login docker.io' -TimeoutSeconds $script:RegistryLoginTimeoutSeconds -Outcome $outcome -ScriptBlock {
            $password | & docker login --username $userName --password-stdin | Out-Null
        }
        return (-not $outcome['TimedOut'] -and $LASTEXITCODE -eq 0)
    } `
    -LoginCommand {
        param([string]$Target)
        $null = $Target
        if ([string]::IsNullOrEmpty($env:YURUNA_DOCKER_HUB_USERNAME) -or [string]::IsNullOrEmpty($env:YURUNA_DOCKER_HUB_PASSWORD)) {
            return $null
        }
        return '$env:YURUNA_DOCKER_HUB_PASSWORD | docker login --username $env:YURUNA_DOCKER_HUB_USERNAME --password-stdin'
    }

# --- REGION: Generic Docker Login (catch-all, registered last)
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
            Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_7a8a2cc13729acb4' -Arguments @{ registryHost = "$registryHost" })
            return $false
        }
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_7f64bfad9ab853d4')
            return $false
        }
        $outcome = @{}
        $null = Invoke-YurunaToolWithDeadline -Label "docker login $registryHost" -TimeoutSeconds $script:RegistryLoginTimeoutSeconds -Outcome $outcome -ScriptBlock {
            $password | & docker login --username $userName --password-stdin $registryHost | Out-Null
        }
        return (-not $outcome['TimedOut'] -and $LASTEXITCODE -eq 0)
    } `
    -LoginCommand {
        param([string]$Target)
        if ([string]::IsNullOrEmpty($env:YURUNA_REGISTRY_USERNAME) -or [string]::IsNullOrEmpty($env:YURUNA_REGISTRY_PASSWORD)) {
            return $null
        }
        $registryHost = ($Target -split '/')[0]
        return "`$env:YURUNA_REGISTRY_PASSWORD | docker login --username `$env:YURUNA_REGISTRY_USERNAME --password-stdin $registryHost"
    }

Export-ModuleMember -Function Register-CredentialProvider, Get-CredentialProvider
