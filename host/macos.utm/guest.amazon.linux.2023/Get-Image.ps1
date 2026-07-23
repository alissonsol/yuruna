<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42d8e9f0-a1b2-4c34-d567-8e9f0a1b2c34
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
    Downloads the Amazon Linux 2023 KVM cloud image (qcow2) for UTM.

.DESCRIPTION
    AL2023 ships native qcow2 images under cdn.amazonlinux.com keyed by
    platform; UTM on Apple Silicon uses kvm-arm64. The directory listing
    on the HTTPS endpoint exposes a single qcow2 plus a matching sha256
    sidecar per release; this script picks both, verifies, and stages the
    file under ~/yuruna/image/amazon.linux.2023/.
#>

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

# --- REGION: Configuration
$sourceUrl = "https://cdn.amazonlinux.com/al2023/os-images/latest/kvm-arm64/"
$downloadDir = "$HOME/yuruna/image/amazon.linux.2023"
$baseImageName = "host.macos.utm.guest.amazon.linux.2023"
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# --- REGION: Find the file to download
$html = Invoke-WebRequest -Uri $sourceUrl
$qcow2Link = ($html.Links | Where-Object { $_.href -match "\.qcow2$" })[0].href
$downloadUrl = $sourceUrl + $qcow2Link

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
# the publisher checksum. AL2023 publishes `<basename>.qcow2.sha256`
# next to each qcow2; the helper parses it transparently. A genuine
# mismatch deletes the tampered file and fails the run (WarnAndDelete);
# a MISSING upstream checksum stays a soft pass (publisher lag).
$downloadFile = Join-Path $downloadDir "downloaded.qcow2"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "modules/Yuruna.Image.psm1") -Force
$checksumLink = ($html.Links | Where-Object { $_.href -match "\.qcow2\.sha256$" })
$checksumUrl = if ($checksumLink) { $sourceUrl + $checksumLink[0].href } else { $null }
$downloaded = Save-ImageWithChecksum `
    -SourceUrl  $downloadUrl `
    -DestPath   $downloadFile `
    -ChecksumUrl $checksumUrl `
    -ChecksumTargetFileName $qcow2Link `
    -OnMismatch 'WarnAndDelete' `
    -Confirm:$false
if (-not $downloaded) {
    Write-Error "Download failed for $downloadUrl"
    exit 1
}
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

# --- REGION: Preserve previous and finalize
$previousFile = Join-Path $downloadDir "$baseImageName.previous.qcow2"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $downloadFile -Destination $baseImageFile

# --- REGION: https://yuruna.link/guest-image-setup#skip-if-same-source-guard
# Only Write-ImageSentinel emits the 4-line shape the reader matches.
Write-ImageSentinel -SourceUrl $downloadUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -Confirm:$false
Write-Output "Recorded source filename, URL, byte count, and Last-Modified to: $baseImageOrigin"

Write-Output "Download complete: $baseImageFile"
