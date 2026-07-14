<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42e1a9c4-2d63-4f58-9a17-3c8e0b6d5f24
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool auth admin
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
    Store the shared pool-auth-token in THIS host's vault (idempotent).
.DESCRIPTION
    Enables this host as a pool-auth-token holder so the status-server
    control routes (the Grafana deep-link control proofs) and cross-host
    config-sync can verify the shared token. Sets the users.yml vaultKey
    EQUAL to the Set-Password username, which removes the silent
    "stored under one key, read under another" 403 by construction, stores
    the token, and verifies the round-trip. With -BounceStatusServer it
    restarts the status server so the running process picks up the new
    vaultKey immediately instead of at the next cycle.

    Read the shared token once from the pool aggregator's proxy and pass
    the SAME value on every host + the proxy:

        ssh yuruna@<proxy> 'sudo cat /etc/yuruna/pool-auth.token'

    This is the host-neutral bootstrap that Sync-HostConfiguration.ps1
    -PersistSharedToken calls; run it directly to seed a host that is not
    syncing config from a reference host.
.PARAMETER Token
    The shared pool-auth-token (operator-owned). Identical on every host and
    on the proxy, or a minted proof will not validate.
.PARAMETER BounceStatusServer
    Restart the status server after storing, so the change is live now
    rather than at the next cycle.
.EXAMPLE
    pwsh test/Set-PoolAuthToken.ps1 -Token '<shared-token>' -BounceStatusServer
.EXAMPLE
    pwsh test/Set-PoolAuthToken.ps1 -Token '<shared-token>' -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Token,
    [switch]$BounceStatusServer
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# The authentication extension supplies Set-Password / Set-UserVaultKey /
# Test-VaultEntry; Test.HostConfigSync supplies the Set-PoolAuthToken
# orchestrator. -Global -Force mirrors Import-Extension so a nested import
# does not evict the module from the global scope.
Import-Module (Join-Path $PSScriptRoot 'extension/authentication/default.psm1') -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules/Test.HostConfigSync.psm1') -Global -Force -DisableNameChecking

$persistArgs = @{ Token = $Token; BounceStatusServer = [bool]$BounceStatusServer }
foreach ($k in @('WhatIf', 'Confirm')) {
    if ($PSBoundParameters.ContainsKey($k)) { $persistArgs[$k] = $PSBoundParameters[$k] }
}
$provision = Set-PoolAuthToken @persistArgs

if ($WhatIfPreference) {
    Write-Information 'What-if: no vault or users.yml change made.' -InformationAction Continue
    exit 0
}

if ($provision.ok) {
    $msg = "pool-auth-token stored and verified (vaultKey '$($provision.vaultKey)')."
    if ($provision.bounced) {
        $msg += ' Status server restarted.'
    } elseif ($BounceStatusServer) {
        $msg += ' Status-server bounce did not complete; the token takes effect at the next cycle.'
    }
    Write-Information $msg -InformationAction Continue
    exit 0
}

Write-Error "pool-auth-token provisioning did not verify (keyChanged=$($provision.keyChanged), verified=$($provision.verified))."
exit 1
