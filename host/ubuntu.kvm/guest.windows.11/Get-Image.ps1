<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e9a
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
    Stages the Windows 11 install ISO + virtio-win driver ISO for KVM.

.DESCRIPTION
    Two artifacts are required to install Windows 11 on KVM/QEMU:
      * Windows 11 multi-edition x64 ISO (from microsoft.com/software-download).
        Microsoft serves this only via a JS-driven page that issues
        short-lived signed download URLs -- there is no clean wget-able
        link. This script prints manual-download instructions and exits
        non-zero until the operator drops the ISO at the expected path.
      * virtio-win ISO (Fedora's signed driver bundle). This IS publicly
        downloadable; we pull the latest stable from fedorapeople.org.

    Apple Virtualization Framework guests on macOS UTM use the
    Win11 ARM64 ISO; KVM x86_64 hosts use the regular x64 ISO. ARM64
    Windows 11 on KVM aarch64 is not currently supported by this script
    (UUP-dump-assembled ISOs work but are out of scope for the initial
    scaffold).
#>

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.windows.11/Get-Image.ps1 only runs on Linux."
    exit 1
}

$arch = (& uname -m).Trim()
if ($arch -ne 'x86_64') {
    Write-Error "Windows 11 on KVM is only supported on x86_64 hosts (this host is $arch). Use the macOS UTM guest for ARM64."
    exit 1
}

$downloadDir   = "$HOME/yuruna/image/windows.11"
$baseImageName = "host.ubuntu.kvm.guest.windows.11"
$winIso        = Join-Path $downloadDir "$baseImageName.iso"
$virtioIso     = Join-Path $downloadDir 'virtio-win.iso'
$virtioOrigin  = Join-Path $downloadDir 'virtio-win.txt'

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# -- Windows 11 ISO: manual download path ----------------------------------
$downloadPage = 'https://www.microsoft.com/en-us/software-download/windows11'
if (-not (Test-Path -LiteralPath $winIso)) {
    # Accept any Win11*.iso the user dropped here and rename it to the
    # expected path. Mirrors the Hyper-V variant's behavior.
    $candidate = Get-ChildItem -LiteralPath $downloadDir -Filter 'Win11*.iso' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($candidate) {
        Move-Item -Path $candidate.FullName -Destination $winIso
        Write-Output "Adopted $($candidate.Name) -> $winIso"
    }
}
if (-not (Test-Path -LiteralPath $winIso)) {
    Write-Output ""
    Write-Output "--- Manual download required ---"
    Write-Output ""
    Write-Output "  1. Open: $downloadPage"
    Write-Output "  2. Select 'Windows 11 (multi-edition ISO for x64 devices)'"
    Write-Output "  3. Click Confirm"
    Write-Output "  4. Select 'English' as the language"
    Write-Output "  5. Click Confirm"
    Write-Output "  6. Click the '64-bit Download' button"
    Write-Output "  7. Save the ISO as: $winIso"
    Write-Output "     (or save any Win11*.iso file to $downloadDir)"
    Write-Output ""
    Write-Output "  Then re-run this script."
    Write-Error "Windows 11 ISO not found at $winIso"
    exit 1
}
Write-Output "Windows 11 ISO present: $winIso"

# -- virtio-win ISO: Fedora's hosted bundle (signed) ----------------------
$virtioUrl = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso'

# The KVM host driver brings the skip-if-same-source guard + sentinel writer
# (Test-DownloadAlreadyCurrent / Write-ImageSentinel, the shared 4-line filename +
# URL + size + Last-Modified format) AND the cache-aware Save-CachedHttpUri
# wrapper used for the virtio-win download below. (The Windows ISO is a manual
# download -- Microsoft serves it only via short-lived signed URLs -- so it
# cannot route through the cache.)
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Host.psm1") -Force

if (Test-DownloadAlreadyCurrent -SourceUrl $virtioUrl -BaseImageFile $virtioIso -OriginFile $virtioOrigin) {
    Write-Output "Skipping virtio-win download: URL and size match prior run for $virtioIso"
} else {
    $tmp = Join-Path $downloadDir 'virtio-win.iso.part'
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Write-Output "Downloading $virtioUrl"
    Save-CachedHttpUri -Uri $virtioUrl -OutFile $tmp
    $size = (Get-Item -LiteralPath $tmp).Length
    if (Test-Path -LiteralPath $virtioIso) {
        Move-Item -Path $virtioIso -Destination (Join-Path $downloadDir 'virtio-win.previous.iso') -Force
    }
    Move-Item -Path $tmp -Destination $virtioIso
    Write-ImageSentinel -SourceUrl $virtioUrl -OriginFile $virtioOrigin -SizeBytes $size -Confirm:$false
    Write-Output "Download complete: $virtioIso"
}

Write-Output ""
Write-Output "Both required artifacts staged:"
Write-Output "  $winIso"
Write-Output "  $virtioIso"
