<#PSScriptInfo
.VERSION 2026.07.22
.GUID 423fe01d-7d08-4606-94aa-0649157daa40
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test credential provider registry pester
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
    Pester coverage for Test.CredentialProvider.psm1 (Get-CredentialProviderMatrix,
    Repair-Credential, Clear-CredentialProvider) and the registry it re-exposes
    from automation/Yuruna.CredentialProvider.psm1 (Register-CredentialProvider,
    Get-CredentialProvider).
.DESCRIPTION
    Covers the first-match-wins pattern dispatch across the five built-in
    providers, the disjoint Authenticator (self-heal after a 401/403) and
    LoginCommand (batch push pipeline) surfaces, the env-var gating that makes
    a LoginCommand return $null, and the capability-matrix snapshot's promise
    not to leak the Authenticator scriptblock.

    No test shells out: the Authenticator under test is a stub registered over
    an existing provider Type, so nothing needs az / aws / gcloud / docker on
    PATH. The built-in registrations are restored by a -Force re-import in
    AfterAll.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.CredentialProvider.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.CredentialProvider.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# Fixtures at FILE scope: a Describe body runs during discovery and its
# variables/functions are discarded before any It executes.
$builtInType = @('azurecr','ecr','gar','dockerhub','docker-generic')

function Restore-CredentialRegistry {
    <#
    .SYNOPSIS
        Re-import the module so the five built-in providers are registered
        afresh. Called after any test that overwrites or clears an entry.
    #>
    [CmdletBinding()] [OutputType([void])] param()
    Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.CredentialProvider.psm1') -Force -DisableNameChecking
}

function Get-CredentialEnvSnapshot {
    <#
    .SYNOPSIS
        Capture the credential-bearing env vars so a test can set them and
        put them back exactly as they were (including "was not set").
    #>
    [CmdletBinding()] [OutputType([hashtable])] param()
    $snap = @{}
    foreach ($name in @('YURUNA_DOCKER_HUB_USERNAME','YURUNA_DOCKER_HUB_PASSWORD','YURUNA_REGISTRY_USERNAME','YURUNA_REGISTRY_PASSWORD')) {
        $snap[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    return $snap
}

function Restore-CredentialEnv {
    <#
    .SYNOPSIS
        Put the credential env vars back the way Get-CredentialEnvSnapshot
        found them.
    #>
    [CmdletBinding()] [OutputType([void])] param([Parameter(Mandatory)][hashtable]$Snapshot)
    foreach ($name in $Snapshot.Keys) {
        [Environment]::SetEnvironmentVariable($name, $Snapshot[$name])
    }
}

Describe 'Get-CredentialProvider pattern dispatch' {
    It 'routes a registry hostname to its provider' -TestCases @(
        @{ target = 'yuruna.azurecr.io';                                  expected = 'azurecr' }
        @{ target = '123456789012.dkr.ecr.us-east-1.amazonaws.com';       expected = 'ecr' }
        @{ target = 'us-central1-docker.pkg.dev';                         expected = 'gar' }
        @{ target = 'docker.io';                                          expected = 'dockerhub' }
        @{ target = 'index.docker.io';                                    expected = 'dockerhub' }
        @{ target = 'harbor.internal.example.com';                        expected = 'docker-generic' }
        @{ target = 'localhost:5000';                                     expected = 'docker-generic' }
    ) {
        param($target, $expected)
        $p = Get-CredentialProvider -Target $target
        Assert-True ($null -ne $p) "no provider matched '$target'"
        Assert-Equal -Expected $expected -Actual $p.Type -Because "'$target' must be claimed by the '$expected' provider"
    }
    It 'still matches when the target carries an image path' -TestCases @(
        @{ target = 'yuruna.azurecr.io/yuruna/web:1.2.3';                          expected = 'azurecr' }
        @{ target = '123456789012.dkr.ecr.eu-west-2.amazonaws.com/app:latest';     expected = 'ecr' }
        @{ target = 'europe-west4-docker.pkg.dev/proj/repo/img';                   expected = 'gar' }
        @{ target = 'docker.io/library/nginx';                                     expected = 'dockerhub' }
    ) {
        param($target, $expected)
        Assert-Equal -Expected $expected -Actual (Get-CredentialProvider -Target $target).Type
    }
    It 'does not let a lookalike hostname steal a specific provider' {
        # The patterns anchor on the registry suffix; a host that merely
        # contains the string must fall through to the catch-all rather than
        # run `az acr login` against something that is not an ACR.
        Assert-Equal -Expected 'docker-generic' -Actual (Get-CredentialProvider -Target 'azurecr.io.evil.example.com').Type
        Assert-Equal -Expected 'docker-generic' -Actual (Get-CredentialProvider -Target 'mydocker.io').Type
        Assert-Equal -Expected 'docker-generic' -Actual (Get-CredentialProvider -Target 'pkg.dev').Type -Because 'GAR needs the -docker prefix'
    }
    It 'claims every non-empty target through the catch-all' {
        # docker-generic is registered last with the pattern '.+', so
        # Get-CredentialProvider never returns $null for a real target. The
        # "no provider matches" branch in Repair-Credential is therefore only
        # reachable with an emptied registry.
        foreach ($t in @('a', 'registry.example', '10.0.0.5:5000/img', 'nonsense')) {
            Assert-True ($null -ne (Get-CredentialProvider -Target $t)) "catch-all must claim '$t'"
        }
    }
    It 'returns the whole entry, Authenticator and LoginCommand included' {
        $p = Get-CredentialProvider -Target 'yuruna.azurecr.io'
        Assert-Equal -Expected 'azurecr' -Actual $p.Type
        Assert-True ($p.Pattern -is [string] -and $p.Pattern.Length -gt 0)
        Assert-True ($p.Authenticator -is [scriptblock]) 'the self-heal path needs the Authenticator'
        Assert-True ($p.LoginCommand  -is [scriptblock]) 'the batch push path needs the LoginCommand'
    }
}

Describe 'LoginCommand: the batch-pipeline surface' {
    It 'builds the ACR login command from the registry host, dropping the image path' {
        $p = Get-CredentialProvider -Target 'yuruna.azurecr.io/web:1'
        Assert-Equal -Expected 'az acr login -n yuruna.azurecr.io' -Actual (& $p.LoginCommand 'yuruna.azurecr.io/web:1')
    }
    It 'reads the ECR region out of the fourth hostname segment' {
        $p = Get-CredentialProvider -Target '123456789012.dkr.ecr.ap-southeast-2.amazonaws.com'
        $cmd = & $p.LoginCommand '123456789012.dkr.ecr.ap-southeast-2.amazonaws.com/app:tag'
        Assert-True ($cmd -match '--region ap-southeast-2') "region not lifted from the host: $cmd"
        Assert-True ($cmd -match 'docker login --username AWS --password-stdin 123456789012\.dkr\.ecr\.ap-southeast-2\.amazonaws\.com$') "login target wrong: $cmd"
    }
    It 'pipes a gcloud access token into docker login for GAR' {
        $p = Get-CredentialProvider -Target 'us-central1-docker.pkg.dev'
        $cmd = & $p.LoginCommand 'us-central1-docker.pkg.dev/proj/repo/img'
        Assert-True ($cmd -match '^gcloud auth print-access-token \| docker login -u oauth2accesstoken --password-stdin https://us-central1-docker\.pkg\.dev$') "GAR login command wrong: $cmd"
    }
    It 'skips the Docker Hub login step when the credentials are not in the environment' {
        $snap = Get-CredentialEnvSnapshot
        try {
            [Environment]::SetEnvironmentVariable('YURUNA_DOCKER_HUB_USERNAME', $null)
            [Environment]::SetEnvironmentVariable('YURUNA_DOCKER_HUB_PASSWORD', $null)
            $p = Get-CredentialProvider -Target 'docker.io'
            Assert-Equal -Expected $null -Actual (& $p.LoginCommand 'docker.io') `
                -Because 'with no credentials the push must fall through to the operator-configured docker credential helper'

            [Environment]::SetEnvironmentVariable('YURUNA_DOCKER_HUB_USERNAME', 'yuruna-bot')
            Assert-Equal -Expected $null -Actual (& $p.LoginCommand 'docker.io') -Because 'a username with no password is still unusable'

            [Environment]::SetEnvironmentVariable('YURUNA_DOCKER_HUB_PASSWORD', 'hunter2')
            $cmd = & $p.LoginCommand 'docker.io'
            Assert-True ($cmd -is [string] -and $cmd.Length -gt 0) 'both vars set must produce a login command'
            Assert-True ($cmd -notmatch 'hunter2') 'the command must reference the env var, never inline the secret'
            Assert-True ($cmd -match 'YURUNA_DOCKER_HUB_PASSWORD') "expected an env-var reference: $cmd"
        } finally { Restore-CredentialEnv -Snapshot $snap }
    }
    It 'gates the generic docker login on YURUNA_REGISTRY_USERNAME / _PASSWORD' {
        $snap = Get-CredentialEnvSnapshot
        try {
            [Environment]::SetEnvironmentVariable('YURUNA_REGISTRY_USERNAME', $null)
            [Environment]::SetEnvironmentVariable('YURUNA_REGISTRY_PASSWORD', $null)
            $p = Get-CredentialProvider -Target 'harbor.example.com/team/img'
            Assert-Equal -Expected 'docker-generic' -Actual $p.Type
            Assert-Equal -Expected $null -Actual (& $p.LoginCommand 'harbor.example.com/team/img')

            [Environment]::SetEnvironmentVariable('YURUNA_REGISTRY_USERNAME', 'svc')
            [Environment]::SetEnvironmentVariable('YURUNA_REGISTRY_PASSWORD', 's3cr3t')
            $cmd = & $p.LoginCommand 'harbor.example.com/team/img'
            Assert-True ($cmd -match 'docker login --username \$env:YURUNA_REGISTRY_USERNAME --password-stdin harbor\.example\.com$') "generic login command wrong: $cmd"
            Assert-True ($cmd -notmatch 's3cr3t') 'the password must stay in the env var'
        } finally { Restore-CredentialEnv -Snapshot $snap }
    }
}

Describe 'Get-CredentialProviderMatrix' {
    It 'snapshots every provider as type -> pattern, in registration order' {
        $m = Get-CredentialProviderMatrix
        Assert-Equal -Expected ($builtInType -join ',') -Actual (@($m.Keys) -join ',') `
            -Because 'first-match-wins means the catch-all has to stay last'
        Assert-Equal -Expected '.+' -Actual $m['docker-generic']
        Assert-True  ($m['azurecr'] -is [string]) 'the matrix carries the Pattern string'
    }
    It 'never exposes the Authenticator scriptblock' {
        # The startup capability matrix is rendered into logs; a scriptblock
        # value here would print provider internals to the operator's console.
        $m = Get-CredentialProviderMatrix
        Assert-True (@($m.Keys).Count -ge 5) 'the matrix must not be empty'
        foreach ($k in $m.Keys) {
            Assert-True ($m[$k] -isnot [scriptblock]) "matrix value for '$k' leaks a scriptblock"
        }
    }
}

Describe 'Repair-Credential' {
    AfterAll { Restore-CredentialRegistry }

    It 'invokes the matching provider Authenticator and returns its verdict' {
        $seen = [System.Collections.Generic.List[object]]::new()
        # Overwrite an existing Type in place: Register-CredentialProvider keys
        # on Type, so the stub takes the azurecr slot (and its pattern position)
        # instead of landing behind the '.+' catch-all.
        Register-CredentialProvider -Type 'azurecr' -Pattern '\.azurecr\.io(/|$)' -Authenticator {
            param([string]$Target, [hashtable]$a)
            $seen.Add(@{ Target = $Target; Args = $a })
            return $true
        }
        $ok = Repair-Credential -Target 'yuruna.azurecr.io/web:1' -ProviderArguments @{ tenant = 'contoso' } -Confirm:$false
        Assert-Equal -Expected $true -Actual $ok
        Assert-Equal -Expected 1 -Actual $seen.Count -Because 'the Authenticator must run exactly once'
        Assert-Equal -Expected 'yuruna.azurecr.io/web:1' -Actual $seen[0].Target -Because 'the full target, path and all, reaches the Authenticator'
        Assert-Equal -Expected 'contoso' -Actual $seen[0].Args['tenant'] -Because 'ProviderArguments are forwarded'
    }
    It 'reports a failed re-authentication as $false' {
        Register-CredentialProvider -Type 'azurecr' -Pattern '\.azurecr\.io(/|$)' -Authenticator {
            param([string]$Target, [hashtable]$a)
            $null = $Target, $a
            return $false
        }
        Assert-Equal -Expected $false -Actual (Repair-Credential -Target 'yuruna.azurecr.io' -Confirm:$false)
    }
    It 'swallows an Authenticator that throws and warns instead of taking the caller down' {
        # The caller is a component-push failure path that already has a 401 in
        # hand; a second exception out of the self-heal would replace a useful
        # error with a useless one.
        Register-CredentialProvider -Type 'azurecr' -Pattern '\.azurecr\.io(/|$)' -Authenticator {
            param([string]$Target, [hashtable]$a)
            $null = $Target, $a
            throw 'az acr login: subscription not found'
        }
        $warnings = @()
        $r = Repair-Credential -Target 'yuruna.azurecr.io' -Confirm:$false -WarningVariable warnings -WarningAction SilentlyContinue
        Assert-Equal -Expected $false -Actual $r
        Assert-True (@($warnings) -match 'subscription not found') 'the underlying failure must survive into the warning'
        Assert-True (@($warnings) -match 'azurecr') 'the warning must name the provider that failed'
    }
    It 'does not touch the Authenticator under -WhatIf' {
        $calls = [System.Collections.Generic.List[object]]::new()
        Register-CredentialProvider -Type 'azurecr' -Pattern '\.azurecr\.io(/|$)' -Authenticator {
            param([string]$Target, [hashtable]$a)
            $null = $Target, $a
            $calls.Add('called')
            return $true
        }
        $r = Repair-Credential -Target 'yuruna.azurecr.io' -WhatIf
        Assert-Equal -Expected 0 -Actual $calls.Count -Because '-WhatIf must not run a real `az acr login`'
        Assert-Equal -Expected $true -Actual $r -Because 'a declined ShouldProcess is not a failure'
    }
    It 'keeps a re-registered Type in its original first-match-wins position' {
        Register-CredentialProvider -Type 'azurecr' -Pattern '\.azurecr\.io(/|$)' -Authenticator { param($t, $a) $null = $t, $a; $true }
        $m = Get-CredentialProviderMatrix
        Assert-Equal -Expected ($builtInType -join ',') -Actual (@($m.Keys) -join ',') `
            -Because 'replacing a provider must not push it behind the catch-all'
    }
}

Describe 'Clear-CredentialProvider' {
    # Runs last: the clear is process-wide. AfterAll re-imports so nothing
    # downstream inherits an emptied registry.
    AfterAll { Restore-CredentialRegistry }

    It 'leaves the registry untouched under -WhatIf' {
        Clear-CredentialProvider -WhatIf
        Assert-Equal -Expected 5 -Actual (Get-CredentialProviderMatrix).Count
        Assert-Equal -Expected 'azurecr' -Actual (Get-CredentialProvider -Target 'yuruna.azurecr.io').Type
    }
    It 'empties the registry so a test can build its own from scratch' {
        # Clear-CredentialProvider promises the registry is "observably empty":
        # tests-only, but Repair-Credential is a production path, and a stale
        # provider surviving the reset means the next Repair-Credential runs a
        # real `az acr login` a test believed it had unregistered.
        Assert-Equal -Expected 5 -Actual (Get-CredentialProviderMatrix).Count -Because 'precondition: the built-ins are loaded'
        Clear-CredentialProvider -Confirm:$false

        Assert-Equal -Expected 0 -Actual (Get-CredentialProviderMatrix).Count -Because 'the matrix must show an empty registry'
        Assert-Equal -Expected $null -Actual (Get-CredentialProvider -Target 'yuruna.azurecr.io') `
            -Because 'lookup must miss after every provider has been dropped'

        # ...and a provider registered into the cleared registry must be the one
        # that answers, rather than a survivor of the clear.
        Register-CredentialProvider -Type 'fake-acr' -Pattern '\.azurecr\.io(/|$)' -Authenticator { param($t, $a) $null = $t, $a; $true }
        Assert-Equal -Expected 'fake-acr' -Actual (Get-CredentialProvider -Target 'yuruna.azurecr.io').Type `
            -Because 'a provider registered after the clear must be reachable'
    }
}
