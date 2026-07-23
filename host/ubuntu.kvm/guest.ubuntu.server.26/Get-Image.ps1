<#PSScriptInfo
.VERSION 2026.07.22
.GUID 4203b4c5-d6e7-4f89-a012-3b4c5d6e7f95
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
    Downloads the Ubuntu Server 26.04 live-server ISO for autoinstall on KVM.

.DESCRIPTION
    Mirrors host/macos.utm/guest.ubuntu.server.26/Get-Image.ps1 and
    host/windows.hyper-v/guest.ubuntu.server.26/Get-Image.ps1 so all three
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
    If set, pulls the rolling daily ISO instead of the latest stable
    point release. Pass -daily if subiquity's curtin extract step
    page-faults with `ovl_iterate_merged` / `BUG: unable to handle page
    fault`. Pre-release 26.04 kernels (e.g. linux 7.0.0-14-generic)
    tripped this overlayfs oops during rsync over a 3-deep overlay
    stack; daily ISOs pick up upstream kernel fixes weeks before the
    next point release does.
#>

param(
    [switch]$daily
)

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.ubuntu.server.26/Get-Image.ps1 only runs on Linux."
    exit 1
}

$arch = (& uname -m).Trim()
switch ($arch) {
    'x86_64'  { $cloudArch = 'amd64' }
    'aarch64' { $cloudArch = 'arm64' }
    default   { Write-Error "Unsupported arch: $arch"; exit 1 }
}

$downloadDir = "$HOME/yuruna/image/ubuntu.env"

# The KVM host driver ships Save-CachedHttpUri + Test-DownloadAlreadyCurrent;
# Save-UbuntuServerImage feature-detects them and routes the ISO download
# through the squid cache (with the shared 4-line same-source guard) when a
# cache is reachable, else downloads direct.
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Yuruna.Host.psm1') -Force
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.UbuntuImage.psm1') -Force

try {
    Save-UbuntuServerImage `
        -ReleaseCodename 'resolute' `
        -Arch $cloudArch `
        -DownloadDir $downloadDir `
        -BaseImageName 'host.ubuntu.kvm.guest.ubuntu.server.26' `
        -PreferDaily:$daily `
        -EmitProxyDiagnosticOnFailure
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
