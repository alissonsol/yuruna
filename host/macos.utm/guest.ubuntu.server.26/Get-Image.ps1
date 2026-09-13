<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42f7131c-52d5-4a5a-bea9-e492c1af1605
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
    on macOS UTM.
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
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }

# --- REGION: Platform guard
if (-not $IsMacOS) {
    Write-Error "host/macos.utm/guest.ubuntu.server.26/Get-Image.ps1 only runs on macOS UTM."
    exit 1
}

# --- REGION: Host architecture
$hostArch = 'arm64'

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
        -BaseImageName 'host.macos.utm.guest.ubuntu.server.26' `
        -PreferDaily:$daily `
        -EmitProxyDiagnosticOnFailure
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

# --- REGION: Completion
# Clear a native discovery probe's stale exit code, including on cache hits.
exit 0
