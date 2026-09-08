<#PSScriptInfo
.VERSION 2026.09.08
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
    Downloads the Ubuntu Server 26.04 live-server ISO for autoinstall.

.DESCRIPTION
    Pulls the Ubuntu Server live ISO. Its cdrom ships a full kernel
    meta-package (`linux-generic`) and a network-configured
    `ubuntu.sources`, so curtin's install_kernel step always succeeds.
    First boot lands in a text-mode login.

    Architecture (amd64/arm64) is picked from the host. Hyper-V has no
    cross-architecture emulation, so the host's architecture is also the
    guest's; the ISO lands under the same host-standard file name either
    way, and New-VM.ps1 consumes it unchanged.

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

# Honor logLevel from Start-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

# --- REGION: Environment checks
Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    Write-Output "Be careful."
    exit 1
}

# --- REGION: Host architecture
# OSArchitecture, not $env:PROCESSOR_ARCHITECTURE: an x64 pwsh running under
# emulation on an ARM64 Windows host reports AMD64 in that variable, which
# would pick an ISO the hypervisor cannot boot. Hyper-V has no
# cross-architecture emulation, so the host's architecture is the guest's.
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

# Yuruna.Host.psm1 supplies Save-CachedHttpUri / Test-DownloadAlreadyCurrent;
# Yuruna.UbuntuImage.psm1 will pick those up via Get-Command when present so
# downloads route through the squid cache transparently.
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Yuruna.Host.psm1') -Force
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.UbuntuImage.psm1') -Force

# --- REGION: Download the base image
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
