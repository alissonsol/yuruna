<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42d7e8f9-a0b1-4c23-d456-7e8f9a0b1c23
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
    Downloads the Amazon Linux 2023 Hyper-V image (VHDX) for Hyper-V.

.DESCRIPTION
    AL2023 ships native Hyper-V images under cdn.amazonlinux.com keyed by
    platform: hyperv. The directory listing on the HTTPS endpoint exposes
    a zip that packages the VHDX per release; this script downloads it,
    verifies its SHA-256 against the publisher checksum, extracts the
    VHDX, and stages it under the Hyper-V default VHDX folder
    ((Get-VMHost).VirtualHardDiskPath).
#>

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
	Write-Output "Please run this script as Administrator."
	Write-Output "Be careful."
	exit 1
}

# --- REGION: Configuration
$sourceUrl = "https://cdn.amazonlinux.com/al2023/os-images/latest/hyperv/"
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageName = "host.windows.hyper-v.guest.amazon.linux.2023"
$baseImageFile = Join-Path $downloadDir "$baseImageName.vhdx"

Write-Output "Hyper-V default VHDX folder: $downloadDir"
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
    exit 1
}

# --- REGION: Find the file to download
$html = Invoke-WebRequest -Uri $sourceUrl
$zipLink = ($html.Links | Where-Object { $_.href -match "\.zip$" })[0].href
$downloadUrl = $sourceUrl + $zipLink

# --- REGION: https://yuruna.link/guest-image-setup#skip-if-same-source-guard
$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Host.psm1") -Force
if (Test-DownloadAlreadyCurrent -SourceUrl $downloadUrl -BaseImageFile $baseImageFile -OriginFile $baseImageOrigin) {
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

# --- REGION: Retrieve and process the files
# Save-ImageWithChecksum (Yuruna.Image.psm1) routes the download
# through Save-CachedHttpUri when available + verifies SHA-256 against
# the publisher checksum. A MISSING upstream checksum is a soft pass;
# a genuine mismatch deletes the tampered file and fails the run
# (WarnAndDelete), so unverified bytes never reach the base image.
$downloadFile = Join-Path $downloadDir "downloaded.zip"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "modules/Yuruna.Image.psm1") -Force
$checksumLink = ($html.Links | Where-Object { $_.href -match "\.zip\.sha256$" })
$checksumUrl = if ($checksumLink) { $sourceUrl + $checksumLink[0].href } else { $null }
$downloaded = Save-ImageWithChecksum `
    -SourceUrl  $downloadUrl `
    -DestPath   $downloadFile `
    -ChecksumUrl $checksumUrl `
    -ChecksumTargetFileName $zipLink `
    -OnMismatch 'WarnAndDelete' `
    -Confirm:$false
if (-not $downloaded) {
    Write-Error "Download failed for $downloadUrl"
    exit 1
}
# Capture the HTTP-download size BEFORE extraction; the .vhdx that
# lands at $baseImageFile is the unzipped artifact, not the bytes
# Test-DownloadAlreadyCurrent will compare against on the next run.
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

# Extract the .vhdx file from the zip -- write to a temp path first so the
# previous image is only replaced after a successful extraction.
$extractedFile = Join-Path $downloadDir "$baseImageName.downloading.vhdx"
Remove-Item $extractedFile -Force -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($downloadFile)
$entry = $zip.Entries | Where-Object { $_.Name -match "\.vhdx$" }
if ($entry) {
	$stream = $entry.Open()
	try {
		$outStream = [System.IO.File]::Open($extractedFile, [System.IO.FileMode]::Create)
		try {
			$stream.CopyTo($outStream)
		} finally {
			$outStream.Close()
		}
	} finally {
		$stream.Close()
	}
} else {
	Write-Error "No .vhdx file found inside the downloaded zip."
	$zip.Dispose()
	exit 1
}
$zip.Dispose()

# --- REGION: Preserve previous and finalize
$previousFile = Join-Path $downloadDir "$baseImageName.previous.vhdx"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path $baseImageFile) {
	Move-Item -Path $baseImageFile -Destination $previousFile
	Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $extractedFile -Destination $baseImageFile

# --- REGION: https://yuruna.link/guest-image-setup#skip-if-same-source-guard
# Write-ImageSentinel writes the 4-line sentinel Test-DownloadAlreadyCurrent
# requires; a legacy 3-line sentinel never matches and silently defeats the
# skip guard (every run re-downloads).
Write-ImageSentinel -SourceUrl $downloadUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -Confirm:$false
Write-Output "Recorded source filename, URL, byte count, and Last-Modified to: $baseImageOrigin"

Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue

Write-Output "Download complete: $baseImageFile"
