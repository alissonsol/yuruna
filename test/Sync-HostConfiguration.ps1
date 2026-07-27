<#PSScriptInfo
.VERSION 2026.07.26
.GUID 42795a67-cd5f-42ad-bd44-8d466ffec8fb
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host pool config
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
    Copy another pool host's test.config.yml onto THIS host, converted for it.
.DESCRIPTION
    Host-neutral entry point. Detects the host type and runs that host's
    Sync-HostConfiguration.ps1 in a child pwsh rooted in its own folder; this
    shell stays in test/. Arguments are forwarded verbatim and the child's exit
    code is returned.

    The conversion is what differs per host -- share paths, local mount-point
    conventions, and where a host alias gets written -- and it is owned by the
    per-host script:

        host/windows.hyper-v/Sync-HostConfiguration.ps1  (needs Administrator)
        host/macos.utm/Sync-HostConfiguration.ps1        (sudo for /etc/hosts)
        host/ubuntu.kvm/Sync-HostConfiguration.ps1       (sudo for /etc/hosts)

    Idempotent, because they are: a repeat run with nothing to change writes
    nothing.
.PARAMETER ReferenceHost
    Network name or IP address of the pool host to copy the config from. Any
    host type -- converting between them is the point.
.PARAMETER StatusPort
    The reference host's status-server port. The per-host script's default
    applies when this is omitted.
.PARAMETER SharedToken
    Shared pool-auth-token, used to fetch a missing vault credential from the
    reference host. The per-host script falls back to this host's own vault copy,
    then to a prompt.
.PARAMETER PersistSharedToken
    Store -SharedToken in THIS host's vault as the pool-auth-token (via
    Set-PoolAuthToken.ps1) before syncing config, and bounce the status server
    so it takes effect immediately. This is the DEFAULT whenever -SharedToken is
    supplied and the host is joining the pool, so a joined host is reachable from
    the dashboard instead of accepting control only from loopback; the switch
    remains for explicitness.
.PARAMETER NoPersistSharedToken
    Use -SharedToken only for this run and do NOT store it. The host keeps
    loopback-only control. For a host that should not be remotely drivable.
.PARAMETER NonInteractive
    Never prompt; skip anything needing operator input, with a warning.
.PARAMETER SkipValidation
    Skip the Test-Config.ps1 run the per-host script finishes with.
.PARAMETER NoPool
    Sync the reference config but do NOT join the pool (drops the pool +
    networkStorage nodes: no NAS mount, no replication, no pool registration).
    Caching-proxy + repository settings still come across, so cache reuse is
    unaffected. For disposable / self-verification hosts (e.g. example/nested.host).
.PARAMETER RemainingArguments
    Anything not declared here is forwarded to the per-host script verbatim
    (-WhatIf among them), so a parameter added there needs no edit here.
.EXAMPLE
    pwsh test/Sync-HostConfiguration.ps1 -ReferenceHost 192.168.7.12
.EXAMPLE
    pwsh test/Sync-HostConfiguration.ps1 -ReferenceHost alius202607a1 -WhatIf
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', 'SharedToken',
    Justification = 'Forwarded as the plaintext vault stores it, to a per-host script that takes it the same way; only its HMAC proof crosses the wire.')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$ReferenceHost,

    # No default values here on purpose: only parameters the operator actually
    # passed are forwarded, so an omitted one reaches the per-host script as
    # omitted and ITS default applies. Restating those defaults here would be a
    # second place for them to drift.
    [Parameter()][int]$StatusPort,
    [Parameter()][string]$SharedToken,
    [switch]$PersistSharedToken,
    [switch]$NoPersistSharedToken,
    [switch]$NonInteractive,
    [switch]$SkipValidation,
    [switch]$NoPool,

    [Parameter(ValueFromRemainingArguments)]
    [string[]]$RemainingArguments
)

$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) 'automation/Yuruna.HostRedirect.psm1') -Force -DisableNameChecking

# The per-host Sync-HostConfiguration.ps1 is an advanced script and narrates
# each decision (kept local path, added alias, stored credential) under
# -Verbose, so pass the switch on when it was asked for; it binds to this
# redirector as a common parameter and would otherwise stop here.
$extra = @()
if ($PSBoundParameters.ContainsKey('Verbose')) { $extra += '-Verbose' }

# -PersistSharedToken is host-neutral: storing the shared pool-auth-token in
# this host's vault is the identical vault operation on every platform (unlike
# the config conversion the per-host script owns), so it runs here in the
# redirector -- before the per-host config-sync, which can then also read the
# token from the local vault. Delegated to Set-PoolAuthToken.ps1 in a child
# pwsh so that script's own `exit` and -Global module imports stay out of this
# runspace; it is excluded from the forwarded arguments (the per-host script
# has no such parameter).
# Persisting is the DEFAULT once a token is supplied and the host is joining the
# pool: a host that syncs a pool config but stores no token accepts control only
# from loopback, so the dashboard's own deep link into it fails with a 403 that
# looks like a bug rather than an unfinished setup. -NoPersistSharedToken keeps
# the token transient for a host that should stay locally-driven, and -NoPool
# already means "not joining", so it does not persist either.
$persistToken = -not $NoPersistSharedToken -and -not $NoPool -and
                ($PersistSharedToken -or -not [string]::IsNullOrEmpty($SharedToken))
if ($persistToken) {
    if ([string]::IsNullOrEmpty($SharedToken)) {
        throw "-PersistSharedToken requires -SharedToken (the shared pool-auth-token to store in this host's vault)."
    }
    $persistScript = Join-Path $PSScriptRoot 'Set-PoolAuthToken.ps1'
    $pwshExe = [System.Environment]::ProcessPath
    if (-not ($pwshExe -and (Test-Path -LiteralPath $pwshExe))) {
        throw 'Could not resolve the pwsh executable to run Set-PoolAuthToken.ps1.'
    }
    $persistArgs = @('-NoProfile', '-File', $persistScript, '-Token', $SharedToken, '-BounceStatusService')
    if ($PSBoundParameters.ContainsKey('WhatIf')) { $persistArgs += '-WhatIf' }
    & $pwshExe @persistArgs
    if ($LASTEXITCODE -ne 0) {
        throw "pool-auth-token provisioning failed (exit $LASTEXITCODE)."
    }
}

$forwarded = @(ConvertTo-HostScriptArgument `
    -BoundParameters $PSBoundParameters `
    -RemainingArguments $RemainingArguments `
    -Exclude 'RemainingArguments', 'PersistSharedToken', 'NoPersistSharedToken' `
    -ExtraArgument $extra)

Invoke-YurunaHostScript -ScriptName 'Sync-HostConfiguration.ps1' -ArgumentList $forwarded

exit ([int]$LASTEXITCODE)
