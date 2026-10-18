<#PSScriptInfo
.VERSION 2026.10.14
.GUID 42e9ac75-3fda-482e-9c3e-944aff26fe2a
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
    See https://yuruna.link/42010605-0003.
.PARAMETER ReferenceHost
    Network name or IP address of the pool host to copy the config from. Any
    host type -- converting between them is the point.
.PARAMETER StatusPort
    The reference host's status-service port. The per-host script's default
    applies when this is omitted.
.PARAMETER InternalAuthKey
    Internal authentication key, used to fetch a missing vault credential from the
    reference host. The per-host script falls back to this host's own vault copy,
    then to a prompt. The convenient way to obtain the token on a new host is
    test/lab/Set-LabToken.ps1 with the dashboard's Lab token; this parameter takes
    the RAW key value, the host-to-host path for when the aggregator is not
    reachable.
.PARAMETER PersistInternalAuthKey
    Store -InternalAuthKey in THIS host's vault as the internal-auth-key (via the
    Set-InternalAuthKey provisioning) before syncing config, and bounce the status
    server so it takes effect immediately. This is the DEFAULT whenever
    -InternalAuthKey is supplied and the host is joining the pool, so a joined host
    is reachable from the dashboard instead of accepting control only from
    loopback; the switch remains for explicitness.
.PARAMETER NoPersistInternalAuthKey
    Use -InternalAuthKey only for this run and do NOT store it. The host keeps
    loopback-only control. For a host that should not be remotely drivable.
.PARAMETER AllowStaleReference
    Copy from a reference host whose test.config.yml is behind THIS host's
    test.config.yml.template without asking. The sync compares the fetched config
    against the local template first and, when the reference is missing current
    keys, still spells retired ones, or carries keys the schema dropped, it lists
    the differences and asks before overwriting -- copying a half-migrated config
    lands keys silently defaulted here. Under -NonInteractive that check FAILS the
    run instead of prompting, so this switch is what an unattended sync passes once
    the drift is understood.
.PARAMETER NonInteractive
    Never prompt; skip anything needing operator input, with a warning.
.PARAMETER SkipValidation
    Skip the Test-Config.ps1 run the per-host script finishes with.
.PARAMETER NoPool
    Sync the reference config but do NOT join the pool (drops the pool +
    networkStorage nodes: no NAS mount, no replication, no pool registration).
    Caching-proxy + repository settings still come across, so cache reuse is
    unaffected. For disposable / self-verification hosts (e.g. example/nested.host).
.PARAMETER RequireReferenceCredential
    Do not accept a networkStorage vault entry the reference host did not supply.
    Without it, an entry already present here survives when nothing can be
    fetched -- right for a host refreshing its config, wrong for one converting
    away from standalone, where that entry is the password this host minted for a
    share it used to serve itself. Passed by test/pool/Convert-ToPoolWorker.ps1, which
    fails the conversion on an unconverged user.
.PARAMETER RemainingArguments
    Anything not declared here is forwarded to the per-host script verbatim
    (-WhatIf among them), so a parameter added there needs no edit here.
.EXAMPLE
    pwsh test/lab/Sync-HostConfiguration.ps1 -ReferenceHost 192.168.7.12
.EXAMPLE
    pwsh test/lab/Sync-HostConfiguration.ps1 -ReferenceHost alius202607a1 -WhatIf
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', 'InternalAuthKey',
    Justification = 'Forwarded as the plaintext vault stores it, to a per-host script that takes it the same way; only its HMAC proof crosses the wire.')]
# See https://yuruna.link/42010605-0003
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$ReferenceHost,

    # No default values here on purpose: only parameters the operator actually
    # passed are forwarded, so an omitted one reaches the per-host script as
    # omitted and ITS default applies. Restating those defaults here would be a
    # second place for them to drift.
    [Parameter()][int]$StatusPort,
    [Parameter()][Alias('SharedToken')][string]$InternalAuthKey,
    [Alias('PersistSharedToken')][switch]$PersistInternalAuthKey,
    [Alias('NoPersistSharedToken')][switch]$NoPersistInternalAuthKey,
    [switch]$NonInteractive,
    [switch]$SkipValidation,
    [switch]$NoPool,
    [switch]$AllowStaleReference,
    [switch]$RequireReferenceCredential,

    [Parameter(ValueFromRemainingArguments)]
    [string[]]$RemainingArguments
)

$ErrorActionPreference = 'Stop'

# --- REGION: Log level from environment
# Honor the caller's logLevel, published as $env:YURUNA_LOG_LEVEL by whatever
# entry point started this script (install/setup.ps1). See docs/loglevels.md.
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv

# --- REGION: Shared bootstrap
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'automation/Yuruna.HostRedirect.psm1') -Force -DisableNameChecking

# --- REGION: Elevation check
# See https://yuruna.link/42010605-0003
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
$hostTarget = Resolve-YurunaHostScript -ScriptName 'Sync-HostConfiguration.ps1'
if ($hostTarget.RequiresElevation -and $IsWindows -and -not (Test-IsAdministrator)) {
    throw ("$($hostTarget.RelativePath) requires Administrator, and this session is not elevated. " +
           "Re-run the same command from an elevated PowerShell (Start-Process pwsh -Verb RunAs).")
}

# --- REGION: Common-parameter relay
# See https://yuruna.link/42010605-0003
$extra = @()
if ($PSBoundParameters.ContainsKey('Verbose') -or $VerbosePreference -eq 'Continue') { $extra += '-Verbose' }
if ($PSBoundParameters.ContainsKey('WhatIf'))  { $extra += '-WhatIf' }

# --- REGION: Internal authentication key
# See https://yuruna.link/42010605-0003
$persistToken = -not $NoPersistInternalAuthKey -and -not $NoPool -and
                ($PersistInternalAuthKey -or -not [string]::IsNullOrEmpty($InternalAuthKey))
if ($persistToken) {
    if ([string]::IsNullOrEmpty($InternalAuthKey)) {
        throw "-PersistInternalAuthKey requires -InternalAuthKey (the internal authentication key to store in this host's vault)."
    }
    Import-Module (Join-Path $PSScriptRoot '../extension/authentication/default.psm1') -Global -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '../modules/Test.ConfigServiceSync.psm1') -Global -Force -DisableNameChecking
    $tokenArgs = @{ Token = $InternalAuthKey; BounceStatusService = $true }
    if ($PSBoundParameters.ContainsKey('WhatIf')) { $tokenArgs['WhatIf'] = $PSBoundParameters['WhatIf'] }
    $provision = Set-InternalAuthKey @tokenArgs
    if (-not $WhatIfPreference -and -not $provision.ok) {
        throw "Internal authentication key provisioning failed (keyChanged=$($provision.keyChanged), verified=$($provision.verified))."
    }
}

# --- REGION: Delegate to the per-host script
$forwarded = @(ConvertTo-HostScriptArgument `
    -BoundParameters $PSBoundParameters `
    -RemainingArguments $RemainingArguments `
    -Exclude 'PersistInternalAuthKey', 'NoPersistInternalAuthKey', 'RemainingArguments' `
    -ExtraArgument $extra)

Invoke-YurunaHostScript -ScriptName 'Sync-HostConfiguration.ps1' -ArgumentList $forwarded

exit ([int]$LASTEXITCODE)
