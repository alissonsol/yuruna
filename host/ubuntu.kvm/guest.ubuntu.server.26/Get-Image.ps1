<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42bd869c-ef6b-4b88-bd37-3f2e8aa2f1ce
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
    Downloads the Ubuntu Server 26.04 live-server ISO for autoinstall
    on Ubuntu KVM.
.DESCRIPTION
    Uses the shared server ISO pipeline so each host runs the same
    subiquity installation sequence. See https://yuruna.link/42e220c4-0003.
.PARAMETER daily
    Prefer the rolling daily ISO over the latest stable point release.
    See https://yuruna.link/42e220c4-0003 for release-specific kernel workarounds.
#>

param(
    [switch]$daily
)

# --- REGION: Log level from environment
# Reuse the caller's log module so an in-process fetch preserves its state.
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }

# --- REGION: Platform guard
if (-not $IsLinux) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_713c26d7b0425606')
    exit 1
}

# --- REGION: Host architecture
$arch = (& uname -m).Trim()
switch ($arch) {
    'x86_64'  { $hostArch = 'amd64' }
    'aarch64' { $hostArch = 'arm64' }
    default   { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_fdfd0961eabd7db1' -Arguments @{ arch = "$arch" }); exit 1 }
}

# --- REGION: Configuration
$downloadDir = "$HOME/yuruna/image/ubuntu.env"

# --- REGION: Import host modules
# The host wrapper supplies cache discovery to the shared image pipeline.
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Yuruna.Host.psm1') -Force
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.UbuntuImage.psm1') -Force

# --- REGION: Download the base image
# See https://yuruna.link/42e220c4-0003
try {
    Save-UbuntuServerImage `
        -ReleaseCodename 'resolute' `
        -Arch $hostArch `
        -DownloadDir $downloadDir `
        -BaseImageName 'host.ubuntu.kvm.guest.ubuntu.server.26' `
        -PreferDaily:$daily `
        -EmitProxyDiagnosticOnFailure
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

# --- REGION: Completion
# Clear a native discovery probe's stale exit code, including on cache hits.
exit 0
