<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42f3d4e5-f6a7-4b89-c012-3d4e5f6a7b81
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
    Downloads the Ubuntu 26.04 (resolute) server cloud image (qcow2) for
    the stash-service VM.

.DESCRIPTION
    Pulls the arch-matched resolute-server-cloudimg from
    cloud-images.ubuntu.com, verifies it, resizes the qcow2 to 256 GB
    (apparent size; qcow2 grows on write), and stages it under
    ~/yuruna/image/stash-service/ as the base image for the stash-service
    VM. libvirt-qemu boots the qcow2 natively, so no format conversion is
    needed.
#>

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.stash-service/Get-Image.ps1 only runs on Linux."
    exit 1
}

# --- REGION: Configuration
# Ubuntu 26.04 LTS (Resolute Raccoon), per the stash-service spec
# (section 3.1: default image ubuntu.server.26), matching the
# caching-proxy LTS so the stash VM stays in the supported-LTS window
# and the distro Go toolchain satisfies the daemon's go.mod directive
# without a toolchain fetch.
$arch = (& uname -m).Trim()
switch ($arch) {
    'x86_64'  { $imgArch = 'amd64' }
    'aarch64' { $imgArch = 'arm64' }
    default   { Write-Error "Unsupported arch: $arch"; exit 1 }
}
$sourceUrl     = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-$imgArch.img"
$downloadDir   = "$HOME/yuruna/image/stash-service"
$baseImageName = "host.ubuntu.kvm.guest.stash-service"
# libvirt-qemu boots qcow2 natively; no format conversion needed.
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# The KVM host driver brings the skip-if-same-source guard + sentinel writer
# (Test-DownloadAlreadyCurrent / Write-ImageSentinel, the shared 4-line filename +
# URL + size + Last-Modified format with the noble->resolute URL-bump guard) AND
# the cache-aware Save-CachedHttpUri wrapper that routes this download through the
# squid cache.
$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Host.psm1") -Force

if (Test-DownloadAlreadyCurrent -SourceUrl $sourceUrl -BaseImageFile $baseImageFile -OriginFile $baseImageOrigin) {
    $skipLines = @(Get-Content -LiteralPath $baseImageOrigin -ErrorAction SilentlyContinue)
    $msg = @(
        "Skipping download: source URL + size + Last-Modified all match the prior run for $baseImageFile."
        "  Sentinel: $baseImageOrigin"
        "    filename     : $($skipLines[0])"
        "    source URL   : $($skipLines[1])"
        "    byte count   : $($skipLines[2])"
        "    last-modified: $($skipLines[3])"
        "  To force a re-download, delete or rename: $baseImageFile"
    ) -join [Environment]::NewLine
    Write-Information $msg -InformationAction Continue
    Write-Output $msg
    exit 0
}

# --- REGION: Download the cloud image
$downloadFile = Join-Path $downloadDir "$baseImageName.downloading.qcow2"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "modules/Yuruna.Image.psm1") -Force
$sourceDir = $sourceUrl.Substring(0, $sourceUrl.LastIndexOf('/'))
$sourceBaseName = $sourceUrl.Substring($sourceUrl.LastIndexOf('/') + 1)
$downloaded = Save-ImageWithChecksum `
    -SourceUrl   $sourceUrl `
    -DestPath    $downloadFile `
    -ChecksumUrl "$sourceDir/SHA256SUMS" `
    -ChecksumTargetFileName $sourceBaseName `
    -OnMismatch  'WarnAndDelete' `
    -VerifyUbuntuSignature `
    -Confirm:$false
if (-not $downloaded) {
    Write-Error "Download failed for $sourceUrl"
    exit 1
}
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

if ($downloadedSize -lt 100MB) {
    Write-Error "Downloaded file is suspiciously small ($([math]::Round($downloadedSize / 1MB, 1)) MB). Expected ~600 MB."
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# --- REGION: Resize the qcow2 to 256 GB
# Resize to 256 GB sparse (qcow2 grows on write).
Write-Output "Resizing qcow2 to 256GB..."
& qemu-img resize $downloadFile 256G
if ($LASTEXITCODE -ne 0) {
    Write-Warning "qemu-img resize failed -- continuing with original size."
    Write-Warning "Resize manually with: qemu-img resize '$baseImageFile' 256G"
}

# --- REGION: Preserve previous and finalize
$previousFile = Join-Path $downloadDir "$baseImageName.previous.qcow2"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $downloadFile -Destination $baseImageFile

# Write the 4-line sentinel (filename + URL + size + Last-Modified) via the
# shared writer, which HEAD-probes the upstream Last-Modified at fetch time.
Write-ImageSentinel -SourceUrl $sourceUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -Confirm:$false
Write-Output "Recorded 4-line sentinel (filename, URL, byte count, Last-Modified) to: $baseImageOrigin"

Write-Output "Download complete: $baseImageFile"
