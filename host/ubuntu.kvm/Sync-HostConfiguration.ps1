<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42e8a1b2-c3d4-4e5f-9012-cd0123456822
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

<#
.SYNOPSIS
    Copies another pool host's test.config.yml onto this Ubuntu KVM host.

.DESCRIPTION
    Pulls the reference host's config over its status server
    (http://<ReferenceHost>:8080/control/test-config), converts the
    host-type-specific values for Linux (share paths to //server/share,
    missing local mount paths to the /mnt/<server> convention -- an
    already-populated local path is kept), preserves the local 'secrets'
    node, and writes the result atomically with the previous file backed
    up to test.config.yml.backup.

    It then reconciles what the config depends on:
      * a networkStorage server name that does not resolve here is looked
        up on the reference host and added to /etc/hosts via
        automation/Set-HostAlias.ps1 -- that write runs under sudo, so
        expect one sudo prompt when an alias is actually missing
        (-NonInteractive uses `sudo -n` and skips with a warning instead);
      * a networkStorage user with no local vault entry has its password
        fetched from the reference host's token-gated
        /control/vault-credential endpoint (encrypted with a key derived
        from the shared pool-auth-token; prompt as fallback) and stored
        via Set-Password.

    Finishes by running test/Test-Config.ps1 so mount + credential
    problems surface immediately. Idempotent -- a repeat run with nothing
    to change writes nothing.

.PARAMETER ReferenceHost
    Network name or IP address of the host to copy from. Any host type
    (macos.utm / ubuntu.kvm / windows.hyper-v).

.PARAMETER StatusPort
    The reference host's status-server port. Default 8080.

.PARAMETER SharedToken
    The shared pool-auth-token used to fetch missing vault credentials.
    Defaults to this host's own vault copy when configured; an interactive
    session prompts as the last resort.

.PARAMETER NonInteractive
    Never prompt; skip anything that would need operator input, with a
    warning.

.PARAMETER SkipValidation
    Skip the final test/Test-Config.ps1 run.

.EXAMPLE
    ./Sync-HostConfiguration.ps1 -ReferenceHost 192.168.7.64
    ./Sync-HostConfiguration.ps1 -ReferenceHost alius202607a1 -WhatIf
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', 'SharedToken',
    Justification = 'Shared token handled as the plaintext vault stores it; only its HMAC proof crosses the wire.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$ReferenceHost,

    [Parameter()][int]$StatusPort = 8080,
    [Parameter()][string]$SharedToken = '',
    [switch]$NonInteractive,
    [switch]$SkipValidation
)

$ErrorActionPreference = 'Stop'
# Sync-HostConfiguration narrates each decision (kept local path, added
# alias, stored credential) via Write-Information; without Continue the
# operator sees none of it.
$InformationPreference = 'Continue'

if (-not $IsLinux) {
    throw "This is the Ubuntu KVM variant; run host/<type>/Sync-HostConfiguration.ps1 for this platform instead."
}

# Shared bootstrap (Test.HostContract import + powershell-yaml +
# PSScriptAnalyzer install) lives in automation/Yuruna.HostSetup.psm1.
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

Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostConfigSync.psm1') -Force -DisableNameChecking

Sync-HostConfiguration -ReferenceHost $ReferenceHost -StatusPort $StatusPort -RepoRoot $RepoRoot `
    -SharedToken $SharedToken -NonInteractive:$NonInteractive -SkipValidation:$SkipValidation
