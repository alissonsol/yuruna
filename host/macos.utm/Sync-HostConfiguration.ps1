<#PSScriptInfo
.VERSION 2026.09.12
.GUID 4294865c-194b-42cf-97c1-6dee3c2b9aa4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host macos utm pool config
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
    Copies another pool host's test.config.yml onto this macOS UTM host.

.DESCRIPTION
    Copies and converts the reference host's configuration, preserving local
    secrets and populated mount paths. Reconciles host aliases and vault
    credentials, writes an atomic backup, and validates the result.
    See https://yuruna.link/428405a0-0011 for platform and elevation details.

.PARAMETER ReferenceHost
    Network name or IP address of the host to copy from. Any host type
    (macos.utm / ubuntu.kvm / windows.hyper-v).

.PARAMETER StatusPort
    The reference host's status-service port. Default 8080.

.PARAMETER InternalAuthKey
    The internal authentication key used to fetch missing vault credentials.
    Defaults to this host's own vault copy when configured; an interactive
    session prompts as the last resort.

.PARAMETER NonInteractive
    Never prompt; skip anything that would need operator input, with a
    warning.

.PARAMETER SkipValidation
    Skip the final test/Test-Config.ps1 run.

.PARAMETER NoPool
    Sync the reference config but do NOT join the pool: the pool + networkStorage
    nodes are dropped, so this host never mounts the NAS, replicates cycles, or
    registers in the pool set. The caching-proxy service + repository settings still come
    across (cache reuse is unaffected). For disposable / self-verification hosts.

.EXAMPLE
    ./Sync-HostConfiguration.ps1 -ReferenceHost 192.168.7.12
    ./Sync-HostConfiguration.ps1 -ReferenceHost alius202607a1 -WhatIf
    ./Sync-HostConfiguration.ps1 -ReferenceHost 192.168.7.12 -NoPool   # borrow config, don't join the pool
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', 'InternalAuthKey',
    Justification = 'The internal authentication key is handled as the plaintext vault stores it; only its HMAC proof crosses the wire.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$ReferenceHost,

    [Parameter()][int]$StatusPort = 8080,
    [Parameter()][Alias('SharedToken')][string]$InternalAuthKey = '',
    [switch]$NonInteractive,
    [switch]$SkipValidation,
    [switch]$NoPool,
    [switch]$AllowStaleReference,
    [switch]$RequireReferenceCredential
)

$ErrorActionPreference = 'Stop'
# Sync-HostConfiguration narrates each decision (kept local path, added
# alias, stored credential) via Write-Information; without Continue the
# operator sees none of it.
$InformationPreference = 'Continue'

# --- REGION: Platform guard
if (-not $IsMacOS) {
    throw "This is the macOS UTM variant; run host/<type>/Sync-HostConfiguration.ps1 for this platform instead."
}

# --- REGION: Elevation notice
# Announce conditional privileged writes without requesting unused credentials.
if (-not $NoPool -and -not $NonInteractive -and -not $WhatIfPreference) {
    Write-Information @'

Note: this sync may need sudo later in the run --
  * write /etc/hosts via automation/Set-HostAlias.ps1, when a networkStorage
    server name does not resolve to what the reference host says
You may be prompted for your password once.
'@
}

# --- REGION: Initialize host setup
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.HostSetup.psm1') -Force
# Only the ShouldProcess switches may reach the bootstrap: its
# -BoundParameters is splatted onto the Install-* helpers, which reject
# this script's own parameters.
$bootstrapParams = @{}
foreach ($k in @('WhatIf', 'Confirm')) {
    if ($PSBoundParameters.ContainsKey($k)) { $bootstrapParams[$k] = $PSBoundParameters[$k] }
}
Initialize-HostSetupModule -RepoRoot $RepoRoot -BoundParameters $bootstrapParams

# --- REGION: Synchronize host configuration
Import-Module (Join-Path $RepoRoot 'test/modules/Test.ConfigServiceSync.psm1') -Force -DisableNameChecking

Sync-HostConfiguration -ReferenceHost $ReferenceHost -StatusPort $StatusPort -RepoRoot $RepoRoot `
    -InternalAuthKey $InternalAuthKey -NonInteractive:$NonInteractive -SkipValidation:$SkipValidation -NoPool:$NoPool `
    -AllowStaleReference:$AllowStaleReference -RequireReferenceCredential:$RequireReferenceCredential
