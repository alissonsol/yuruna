<#PSScriptInfo
.VERSION 2026.09.30
.GUID 422ef6fd-7932-4b4f-914a-157316240cb6
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
    Provides the shared Ubuntu Server release image acquisition workflow.
#>

param(
    [switch]$daily,
    [Parameter(Mandatory)][ValidateSet('24', '26')][string]$Release,
    [Parameter(Mandatory)][string]$GuestScriptRoot,
    [string]$EnvironmentErrorKey
)

# --- REGION: Log level from environment
# Reuse the caller's log module so an in-process fetch preserves its state.
Import-Module (Join-Path $GuestScriptRoot '../../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$_logLevelMod = Join-Path $GuestScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }

# --- REGION: Platform guard
if (-not $IsMacOS) {
    Write-Error (Format-YurunaOperatorMessage -Key $EnvironmentErrorKey)
    exit 1
}

# --- REGION: Host architecture
$hostArch = 'arm64'

# --- REGION: Configuration
$downloadDir = "$HOME/yuruna/image/ubuntu.env"

# --- REGION: Import host modules
# The host wrapper supplies cache discovery to the shared image pipeline.
Import-Module -Name (Join-Path (Split-Path -Parent $GuestScriptRoot) 'modules/Yuruna.Host.psm1') -Force
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $GuestScriptRoot)) 'modules/Yuruna.UbuntuImage.psm1') -Force

# --- REGION: Download the base image
# See https://yuruna.link/42e220c4-0003
try {
    Save-UbuntuServerImage `
        -ReleaseCodename $(if ($Release -eq '26') { 'resolute' } else { 'noble' }) `
        -Arch $hostArch `
        -DownloadDir $downloadDir `
        -BaseImageName "host.macos.utm.guest.ubuntu.server.$Release" `
        -PreferDaily:$daily `
        -EmitProxyDiagnosticOnFailure
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

# --- REGION: Completion
# Clear a native discovery probe's stale exit code, including on cache hits.
exit 0
