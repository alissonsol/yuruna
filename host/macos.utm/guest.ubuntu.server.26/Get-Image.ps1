<#PSScriptInfo
.VERSION 2026.06.05
.GUID 42e1f2a3-b4c5-4d67-8901-2e3f4a5b6c70
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
    Downloads the Ubuntu Server 26.04 live-server arm64 ISO for autoinstall.

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

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

$downloadDir = "$HOME/yuruna/image/ubuntu.env"

# Yuruna.Host.psm1 supplies Save-CachedHttpUri / Test-DownloadAlreadyCurrent;
# Yuruna.UbuntuImage.psm1 will pick those up via Get-Command when present so
# downloads route through the squid cache transparently.
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Yuruna.Host.psm1') -Force
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.UbuntuImage.psm1') -Force

try {
    Save-UbuntuServerImage `
        -ReleaseCodename 'resolute' `
        -Arch 'arm64' `
        -DownloadDir $downloadDir `
        -BaseImageName 'host.macos.utm.guest.ubuntu.server.26' `
        -PreferDaily:$daily `
        -EmitProxyDiagnosticOnFailure
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
