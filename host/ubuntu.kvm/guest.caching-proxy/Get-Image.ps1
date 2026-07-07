<#PSScriptInfo
.VERSION 2026.07.07
.GUID 42f3d4e5-f6a7-4b89-c012-3d4e5f6a7b8c
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

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.caching-proxy/Get-Image.ps1 only runs on Linux."
    exit 1
}

# --- REGION: Configuration
# Ubuntu 26.04 LTS (Resolute Raccoon). Matches the windows.hyper-v and
# macos.utm caching-proxy guests so a cache rebuilt on any host produces
# the same Squid 7.x baseline. `unattended-upgrades` (enabled in
# host/vmconfig/caching-proxy.base.user-data) keeps pulling security patches automatically so
# the long-lived cache box stays inside the supported window between
# rebuilds.
$arch = (& uname -m).Trim()
switch ($arch) {
    'x86_64'  { $imgArch = 'amd64' }
    'aarch64' { $imgArch = 'arm64' }
    default   { Write-Error "Unsupported arch: $arch"; exit 1 }
}
$sourceUrl     = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-$imgArch.img"
$downloadDir   = "$HOME/yuruna/image/caching-proxy"
$baseImageName = "host.ubuntu.kvm.guest.caching-proxy"
# libvirt-qemu boots qcow2 natively; no format conversion needed (unlike
# the Hyper-V variant which produces VHDX and the macOS UTM variant which
# produces raw). Keep the cloud-image's native qcow2 and just resize it
# to 512 GB sparse so the squid `cache_dir 393216 16 256` (= 384 GB) +
# OS/logs headroom fits.
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# The KVM host driver brings the skip-if-same-source guard + sentinel writer
# (Test-DownloadAlreadyCurrent / Write-ImageSentinel, the shared 4-line filename +
# URL + size + Last-Modified format with the noble->resolute URL-bump guard) AND
# the cache-aware Save-CachedHttpUri wrapper.
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
# Save-ImageWithChecksum (Yuruna.Image.psm1) routes the download and
# verifies SHA-256 against cloud-images.ubuntu.com's published
# SHA256SUMS (a genuine mismatch deletes the file and fails; a missing
# checksum is a soft pass). It feature-detects the driver's Save-CachedHttpUri
# wrapper and routes through the squid cache when one is reachable. This guest
# IS the cache, so on a first build no cache exists and the fetch goes direct;
# when an older cache VM is still up its image refresh can route through it.
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

# --- REGION: Resize the qcow2 to 512 GB
# Resize to 512 GB sparse. qcow2 is dynamic, so 512 GB is the APPARENT
# size only -- actual disk consumption stays low until squid starts
# caching. Sized for squid's `cache_dir ufs /var/spool/squid 393216 16
# 256` (= 384 GB) + ~128 GB OS/logs/headroom. The `maximum_object_size
# 65 GB` directive in host/vmconfig/caching-proxy.base.user-data lets the proxy cache files
# like the macOS install image (~18 GB) and other multi-GB blobs end-
# to-end instead of bypassing them direct to CDN.
Write-Output "Resizing qcow2 to 512GB..."
& qemu-img resize $downloadFile 512G
if ($LASTEXITCODE -ne 0) {
    Write-Warning "qemu-img resize failed -- continuing with original size."
    Write-Warning "The cache VM will only have the base cloud-image capacity (~3.5 GB)"
    Write-Warning "which fills up after the first prewarm. Resize manually with:"
    Write-Warning "  qemu-img resize '$baseImageFile' 512G"
}

# --- REGION: Preserve previous and finalize
$previousFile = Join-Path $downloadDir "$baseImageName.previous.qcow2"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $downloadFile -Destination $baseImageFile

# Write the 4-line sentinel (filename + URL + size + Last-Modified). The shared
# writer HEAD-probes the upstream Last-Modified at fetch time and records an
# empty 4th line when the server strips the header.
Write-ImageSentinel -SourceUrl $sourceUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -Confirm:$false
Write-Output "Recorded 4-line sentinel (filename, URL, byte count, Last-Modified) to: $baseImageOrigin"

Write-Output "Download complete: $baseImageFile"
