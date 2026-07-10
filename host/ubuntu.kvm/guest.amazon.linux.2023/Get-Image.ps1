<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e96
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
    Downloads the Amazon Linux 2023 KVM cloud image (qcow2) for libvirt.

.DESCRIPTION
    AL2023 ships native qcow2 images under cdn.amazonlinux.com keyed by
    platform: kvm (x86_64) or kvm-arm64. The directory listing on the
    HTTPS endpoint exposes a single .qcow2 + matching .qcow2.sha256
    sidecar per release; this script picks both, verifies, and stages
    the file under ~/yuruna/image/amazon.linux.2023/.
#>

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.amazon.linux.2023/Get-Image.ps1 only runs on Linux."
    exit 1
}

$arch = (& uname -m).Trim()
switch ($arch) {
    'x86_64'  { $platDir = 'kvm' }
    'aarch64' { $platDir = 'kvm-arm64' }
    default   { Write-Error "Unsupported arch: $arch"; exit 1 }
}

# --- REGION: Configuration
$sourceUrl     = "https://cdn.amazonlinux.com/al2023/os-images/latest/$platDir/"
$downloadDir   = "$HOME/yuruna/image/amazon.linux.2023"
$baseImageName = "host.ubuntu.kvm.guest.amazon.linux.2023"
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"
$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# --- REGION: Find the file to download
$html = Invoke-WebRequest -Uri $sourceUrl -ErrorAction Stop
$qcow2Link = ($html.Links | Where-Object { $_.href -match '\.qcow2$' } | Select-Object -First 1).href
if (-not $qcow2Link) {
    Write-Error "No .qcow2 listed at $sourceUrl"
    exit 1
}
$downloadUrl = $sourceUrl + $qcow2Link

# The KVM host driver brings the skip-if-same-source guard + sentinel writer
# (Test-DownloadAlreadyCurrent / Write-ImageSentinel, the 4-line filename + URL +
# size + Last-Modified format shared across every KVM guest, with the
# noble->resolute URL-bump guard) AND the cache-aware Save-CachedHttpUri wrapper
# that routes this download through the squid cache.
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
$downloadFile = Join-Path $downloadDir 'downloaded.qcow2'
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
# Save-ImageWithChecksum (Yuruna.Image.psm1) verifies SHA-256 against
# the publisher checksum (a genuine mismatch deletes the file and fails;
# a missing upstream checksum is a soft pass). It feature-detects the
# driver's Save-CachedHttpUri wrapper and routes the fetch through the
# squid cache when one is reachable, else downloads direct.
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "modules/Yuruna.Image.psm1") -Force
$checksumLink = ($html.Links | Where-Object { $_.href -match '\.qcow2\.sha256$' } | Select-Object -First 1)
$checksumUrl = if ($checksumLink) { $sourceUrl + $checksumLink.href } else { $null }
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
if (Test-Path -LiteralPath $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $downloadFile -Destination $baseImageFile

Write-ImageSentinel -SourceUrl $downloadUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -Confirm:$false
Write-Output "Recorded 4-line sentinel (filename, URL, byte count, Last-Modified) to: $baseImageOrigin"
Write-Output "Download complete: $baseImageFile"
