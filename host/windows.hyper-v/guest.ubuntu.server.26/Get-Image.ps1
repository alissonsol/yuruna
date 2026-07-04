<#PSScriptInfo
.VERSION 2026.07.03
.GUID 4225d6e7-f8a9-4b02-c456-7d8e9f0a1b25
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
    Downloads the Ubuntu Server 26.04 live-server amd64 ISO for autoinstall.

.DESCRIPTION
    Pulls the Ubuntu Server live ISO. Its cdrom ships a full kernel
    meta-package (`linux-generic`) and a network-configured
    `ubuntu.sources`, so curtin's install_kernel step always succeeds.
    First boot lands in a text-mode login.

.PARAMETER daily
    If set, pulls the rolling daily ISO instead of the latest stable point
    release. Pass -daily if subiquity's curtin extract step page-faults with
    `ovl_iterate_merged` / `BUG: unable to handle page fault`. Pre-release
    26.04 kernels (e.g. linux 7.0.0-14-generic) tripped this overlayfs oops
    during rsync over a 3-deep overlay stack; daily ISOs pick up upstream
    kernel fixes weeks before the next point release does.
#>

param(
    [switch]$daily
)

Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    Write-Output "Be careful."
    exit 1
}

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

$downloadDir = (Get-VMHost).VirtualHardDiskPath
Write-Output "Hyper-V default VHDX folder: $downloadDir"
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
    exit 1
}

# Yuruna.Host.psm1 supplies Save-CachedHttpUri / Test-DownloadAlreadyCurrent;
# Yuruna.UbuntuImage.psm1 will pick those up via Get-Command when present so
# downloads route through the squid cache transparently.
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Yuruna.Host.psm1') -Force
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.UbuntuImage.psm1') -Force

try {
    Save-UbuntuServerImage `
        -ReleaseCodename 'resolute' `
        -Arch 'amd64' `
        -DownloadDir $downloadDir `
        -BaseImageName 'host.windows.hyper-v.guest.ubuntu.server.26' `
        -PreferDaily:$daily `
        -EmitProxyDiagnosticOnFailure
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
