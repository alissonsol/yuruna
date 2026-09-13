<#PSScriptInfo
.VERSION 2026.09.13
.GUID 4207e139-f8d7-47ca-aef7-9b91cc585612
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
    Downloads the Ubuntu Server 24.04 live-server ISO for autoinstall
    on Windows Hyper-V.
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
if (-not $IsWindows) {
    Write-Error "host/windows.hyper-v/guest.ubuntu.server.24/Get-Image.ps1 only runs on Windows Hyper-V."
    exit 1
}

# --- REGION: Elevation check
Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    Write-Output "Be careful."
    exit 1
}

# --- REGION: Host architecture
# OSArchitecture remains native when x64 PowerShell runs under ARM64 emulation.
switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64'   { $hostArch = 'amd64' }
    'Arm64' { $hostArch = 'arm64' }
    default {
        Write-Error "Unsupported processor architecture: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture). A Hyper-V host must be AMD64 or ARM64."
        exit 1
    }
}
Write-Output "Host architecture: $hostArch"

# --- REGION: Configuration
$downloadDir = (Get-VMHost).VirtualHardDiskPath
Write-Output "Hyper-V default VHDX folder: $downloadDir"
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
    exit 1
}

# --- REGION: Import host modules
# The host wrapper supplies cache discovery to the shared image pipeline.
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Yuruna.Host.psm1') -Force
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.UbuntuImage.psm1') -Force

# --- REGION: Download the base image
# See https://yuruna.link/42e220c4-0003
try {
    Save-UbuntuServerImage `
        -ReleaseCodename 'noble' `
        -Arch $hostArch `
        -DownloadDir $downloadDir `
        -BaseImageName 'host.windows.hyper-v.guest.ubuntu.server.24' `
        -PreferDaily:$daily `
        -EmitProxyDiagnosticOnFailure
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

# --- REGION: Completion
# Clear a native discovery probe's stale exit code, including on cache hits.
exit 0
