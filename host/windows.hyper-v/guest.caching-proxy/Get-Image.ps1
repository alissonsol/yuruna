<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42f0a1b2-c3d4-4e56-f789-0a1b2c3d4e57
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

Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    exit 1
}

# === Configuration ===
# Ubuntu 26.04 LTS (Resolute Raccoon). Moved up from 24.04 LTS (Noble
# Numbat) so the cache VM stays inside the supported-LTS window and
# `unattended-upgrades` (enabled in host/vmconfig/caching-proxy.base.user-data) keeps pulling
# security patches automatically rather than going EOL mid-cycle.
$sourceUrl = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageName = "host.windows.hyper-v.guest.caching-proxy"
$baseImageFile = Join-Path $downloadDir "$baseImageName.vhdx"

Write-Output "Hyper-V default VHDX folder: $downloadDir"
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
    exit 1
}

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

# === Download the cloud image ===
$downloadFile = Join-Path $downloadDir "$baseImageName.downloading.img"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
# Save-ImageWithChecksum (Yuruna.Image.psm1) routes the fetch
# through Save-CachedHttpUri when available + verifies SHA-256 against
# the publisher checksum. cloud-images.ubuntu.com publishes SHA256SUMS
# in the parent codename directory; the helper parses it and matches
# on the cloud-image basename. A genuine mismatch deletes the file and
# fails the run; a missing checksum is a soft pass. Note: this script
# PROVISIONS the squid cache, so on a first-run host the cache doesn't
# exist yet and the helper falls through to a direct Invoke-WebRequest.
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
# Capture the HTTP-download size BEFORE qcow2->vhdx conversion; the
# .vhdx at $baseImageFile is the converted+resized artifact, not the
# bytes Test-DownloadAlreadyCurrent will compare against next run.
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

$fileSize = (Get-Item $downloadFile).Length
if ($fileSize -lt 100MB) {
    Write-Error "Downloaded file is suspiciously small ($([math]::Round($fileSize / 1MB, 1)) MB). Expected ~600 MB."
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# === Convert qcow2 to VHDX + resize ===
# The shared Convert-Qcow2ToVhdx (Yuruna.Image) owns qemu-img discovery, the
# convert, the NTFS sparse-flag clear, and the Resize-VHD/qemu-img resize
# fallback (feedback_qemu_img_vhdx_sparse.md), so the trap fix lives once.
$convertedFile = Join-Path $downloadDir "$baseImageName.converting.vhdx"
if (-not (Convert-Qcow2ToVhdx -SourcePath $downloadFile -DestPath $convertedFile -SizeBytes 512GB)) {
    Write-Error "qcow2 to VHDX conversion failed for the download"
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# === Preserve previous and finalize ===
$previousFile = Join-Path $downloadDir "$baseImageName.previous.vhdx"
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

Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue

Write-Output "Download complete: $baseImageFile"
