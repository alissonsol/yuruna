<#PSScriptInfo
.VERSION 2026.08.25
.GUID 4223cd4e-7ab2-4316-8d12-b6869c2182c8
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
    Downloads the Ubuntu Server 24.04 live-server ISO for autoinstall on KVM.

.DESCRIPTION
    Mirrors host/macos.utm/guest.ubuntu.server.24/Get-Image.ps1 and
    host/windows.hyper-v/guest.ubuntu.server.24/Get-Image.ps1 so all three
    hosts boot the same live-server ISO and run subiquity autoinstall.
    The pre-baked cloud image (.img) + NoCloud cloud-init seed is
    deliberately NOT used: it boots in seconds but DOES NOT show
    the "Continue with autoinstall?" prompt or fire subiquity's
    late-commands -- making the boot sequence non-comparable across
    hosts (the GUI test sequence step that waits for that prompt would
    time out on KVM only).

    Architecture (amd64/arm64) is picked from the host. Stable point
    release is preferred; falls back to the rolling daily build.

.PARAMETER daily
    If set, pulls the rolling daily ISO instead of the latest stable point
    release. Useful for catching regressions before a yuruna release commits
    to a specific point release.
#>

param(
    [switch]$daily
)

# Honor logLevel from Start-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

# --- REGION: Environment checks
if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.ubuntu.server.24/Get-Image.ps1 only runs on Linux."
    exit 1
}

# --- REGION: Configuration
$arch = (& uname -m).Trim()
switch ($arch) {
    'x86_64'  { $cloudArch = 'amd64' }
    'aarch64' { $cloudArch = 'arm64' }
    default   { Write-Error "Unsupported arch: $arch"; exit 1 }
}

$downloadDir = "$HOME/yuruna/image/ubuntu.env"

# Yuruna.Host.psm1 supplies Save-CachedHttpUri / Test-DownloadAlreadyCurrent;
# Yuruna.UbuntuImage.psm1 will pick those up via Get-Command when present so
# downloads route through the squid cache transparently.
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Yuruna.Host.psm1') -Force
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.UbuntuImage.psm1') -Force

# --- REGION: Download the base image
try {
    Save-UbuntuServerImage `
        -ReleaseCodename 'noble' `
        -Arch $cloudArch `
        -DownloadDir $downloadDir `
        -BaseImageName 'host.ubuntu.kvm.guest.ubuntu.server.24' `
        -PreferDaily:$daily `
        -EmitProxyDiagnosticOnFailure
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
