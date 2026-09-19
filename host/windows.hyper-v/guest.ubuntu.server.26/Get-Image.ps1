<#PSScriptInfo
.VERSION 2026.09.18
.GUID 4239cae2-d619-439b-8e82-1021baaae161
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
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }

# --- REGION: Platform guard
if (-not $IsWindows) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_ea494ffdd86805ef')
    exit 1
}

# --- REGION: Elevation check
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_3e3de8bf7b8f6ba1')
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_73905e18abf967cb')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d9fd336c78bc7623')
    exit 1
}

# --- REGION: Host architecture
# OSArchitecture remains native when x64 PowerShell runs under ARM64 emulation.
switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64'   { $hostArch = 'amd64' }
    'Arm64' { $hostArch = 'arm64' }
    default {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_1f5a3a41f93d6b9f' -Arguments @{ oSArchitecture = "$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" })
        exit 1
    }
}
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_5d5bccb746b0bc5e' -Arguments @{ hostArch = "$hostArch" })

# --- REGION: Configuration
$downloadDir = (Get-VMHost).VirtualHardDiskPath
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e30f6e2006f710fa' -Arguments @{ downloadDir = "$downloadDir" })
if (!(Test-Path -Path $downloadDir)) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_84177e952e2487af' -Arguments @{ downloadDir = "$downloadDir" })
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
        -ReleaseCodename 'resolute' `
        -Arch $hostArch `
        -DownloadDir $downloadDir `
        -BaseImageName 'host.windows.hyper-v.guest.ubuntu.server.26' `
        -PreferDaily:$daily `
        -EmitProxyDiagnosticOnFailure
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

# --- REGION: Completion
# Clear a native discovery probe's stale exit code, including on cache hits.
exit 0
