<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42f2c3d4-e5f6-4a78-b901-c2d3e4f5a6b8
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

# === Configuration ===
# Ubuntu 26.04 LTS (Resolute Raccoon), arm64 cloud image -- macOS UTM
# runs on Apple Silicon via Apple Virtualization. Moved up from 24.04
# LTS (Noble Numbat) so the cache VM stays inside the supported-LTS
# window and `unattended-upgrades` (enabled in host/vmconfig/caching-proxy.base.user-data)
# keeps pulling security patches automatically rather than going EOL
# mid-cycle.
$sourceUrl = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-arm64.img"
$downloadDir = "$HOME/yuruna/image/caching-proxy"
$baseImageName = "host.macos.utm.guest.caching-proxy"
# Final artifact is qcow2: these bundles run on UTM's QEMU backend, which
# boots qcow2 natively, so no raw conversion is needed. qcow2 is also
# required for correctness on macOS -- UTM attaches read-write disks with
# discard=unmap,detect-zeroes=unmap, and QEMU's macOS file-posix backend
# services those discards via fcntl(F_PUNCHHOLE), which rejects any
# request not aligned to the APFS 4 KiB block size with EINVAL ("Invalid
# argument"). A raw image punches holes at the guest's 512-byte discard
# granularity and trips that; qcow2 only ever punches at its 64 KiB
# cluster boundaries, which are always 4 KiB-aligned. See
# feedback_macos-qemu-punchhole-alignment.md.
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# Skip-if-same-source guard. Test-DownloadAlreadyCurrent (Yuruna.Host.psm1)
# returns $true only when ALL of the following match the on-disk state:
#   * $baseImageFile exists
#   * the sentinel records the same filename, URL, byte count, AND
#     Last-Modified date as a fresh HEAD probe of $sourceUrl
# Any mismatch -- including a legacy 3-line sentinel that lacks the
# Last-Modified field -- forces a re-download. The only way to force a
# re-download manually is to delete or rename $baseImageFile (or
# $baseImageOrigin). The 4-line sentinel guards against the silent-skip
# regression class where a noble->resolute style URL bump matches the
# byte count by coincidence.
$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Host.psm1") -Force
if (Test-DownloadAlreadyCurrent -SourceUrl $sourceUrl -BaseImageFile $baseImageFile -OriginFile $baseImageOrigin -Verbose:($VerbosePreference -ne 'SilentlyContinue')) {
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

$downloadFile = Join-Path $downloadDir "$baseImageName.downloading.qcow2"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
# Save-ImageWithChecksum (Yuruna.Image.psm1) routes the download
# through Save-CachedHttpUri when available + verifies SHA-256 against
# cloud-images.ubuntu.com's published SHA256SUMS (a genuine mismatch
# deletes the file and fails; a missing checksum is a soft pass). This
# script PROVISIONS the squid cache, so on a first-run host the helper
# falls through to a direct fetch.
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
# Capture the HTTP-download size BEFORE the in-place resize; the qcow2
# at $baseImageFile is the resized artifact, not the bytes
# Test-DownloadAlreadyCurrent will compare against next run.
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

$fileSize = (Get-Item $downloadFile).Length
if ($fileSize -lt 100MB) {
    Write-Error "Downloaded file is suspiciously small ($([math]::Round($fileSize / 1MB, 1)) MB). Expected ~600 MB."
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# === Resize the qcow2 to 512 GB ===
# No raw conversion: UTM's QEMU backend boots qcow2 directly, and qcow2
# avoids the macOS F_PUNCHHOLE-alignment EINVAL a raw disk hits under
# UTM's discard=unmap,detect-zeroes=unmap (see the header note and
# feedback_macos-qemu-punchhole-alignment.md). Resize a staging copy of
# the downloaded qcow2, then promote it in the finalize block below.
$convertedFile = Join-Path $downloadDir "$baseImageName.staging.qcow2"
Remove-Item $convertedFile -Force -ErrorAction SilentlyContinue
Copy-Item -LiteralPath $downloadFile -Destination $convertedFile

# Resize to 512 GB (qcow2 grows on demand: apparent 512 GB, actual only
# what the guest has written). Sized for squid's 384 GB cache_dir + ~128
# GB OS/logs/headroom -- see host/vmconfig/caching-proxy.base.user-data `cache_dir ufs
# /var/spool/squid 393216` and the `maximum_object_size 65 GB` directive
# that lets the proxy cache files like the macOS install image (~18 GB)
# and other multi-GB blobs end-to-end instead of bypassing them direct to
# CDN.
Write-Output "Resizing qcow2 image to 512GB..."
& qemu-img resize -f qcow2 $convertedFile 512G
if ($LASTEXITCODE -ne 0) {
    Write-Warning "qemu-img resize failed -- continuing with original size."
    Write-Warning "The cache VM will only have the base cloud-image capacity (~2.5 GB)"
    Write-Warning "which fills up after 1-2 installs. Resize manually with:"
    Write-Warning "  qemu-img resize -f qcow2 '$baseImageFile' 512G"
}

# === Preserve previous and finalize ===
$previousFile = Join-Path $downloadDir "$baseImageName.previous.qcow2"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $convertedFile -Destination $baseImageFile

$sourceFileName = [System.IO.Path]::GetFileName(([System.Uri]$sourceUrl).LocalPath)
# Capture the upstream Last-Modified header after the download finishes so
# the sentinel records WHAT THE SERVER SAID at the moment we fetched it.
# A subsequent Test-DownloadAlreadyCurrent compares the new HEAD's
# Last-Modified against this string. cloud-images.ubuntu.com exposes
# Last-Modified consistently; some CDNs strip it. Missing header -> empty
# string, and Test-DownloadAlreadyCurrent skips the date check in that
# direction (URL + size still gate the skip).
$sourceLastModified = ''
try {
    $head = Invoke-WebRequest -Uri $sourceUrl -Method Head -ErrorAction Stop
    $lm = $head.Headers['Last-Modified']
    if ($lm -is [System.Array]) { $lm = $lm[0] }
    $sourceLastModified = [string]$lm
} catch {
    Write-Verbose "Last-Modified HEAD probe failed (sentinel will record empty): $($_.Exception.Message)"
}
Set-Content -Path $baseImageOrigin -Value @($sourceFileName, $sourceUrl, "$downloadedSize", $sourceLastModified)
Write-Output "Recorded source filename, URL, byte count, and Last-Modified to: $baseImageOrigin"

# Only the raw is needed now.
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue

Write-Output "Download complete: $baseImageFile"
