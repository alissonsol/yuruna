<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42f2c3d4-e5f6-4a78-b901-c2d3e4f5a682
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

# --- REGION: Configuration
# Ubuntu 26.04 LTS (Resolute Raccoon), arm64 cloud image -- macOS UTM
# runs on Apple Silicon. Per the stash-service spec (section 3.1: default
# image ubuntu.server.26), matching the caching-proxy LTS so the stash VM
# stays in the supported-LTS window and the distro Go toolchain satisfies
# the daemon's go.mod directive.
$sourceUrl = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-arm64.img"
$downloadDir = "$HOME/yuruna/image/stash-service"
$baseImageName = "host.macos.utm.guest.stash-service"
# --- REGION: https://yuruna.link/vmconfig#macos-utm-qcow2-punchhole-alignment
# Final artifact stays qcow2 -- a raw disk trips the macOS F_PUNCHHOLE
# 4 KiB-alignment EINVAL under UTM's discard=unmap.
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# --- REGION: https://yuruna.link/guest-image-setup#skip-if-same-source-guard
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

$fileSize = (Get-Item $downloadFile).Length
if ($fileSize -lt 100MB) {
    Write-Error "Downloaded file is suspiciously small ($([math]::Round($fileSize / 1MB, 1)) MB). Expected ~600 MB."
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# --- REGION: Resize the qcow2 to 256 GB
# --- REGION: https://yuruna.link/vmconfig#macos-utm-qcow2-punchhole-alignment
# Resize a staging copy of the downloaded qcow2; the finalize block below
# promotes it.
$convertedFile = Join-Path $downloadDir "$baseImageName.staging.qcow2"
Remove-Item $convertedFile -Force -ErrorAction SilentlyContinue
Copy-Item -LiteralPath $downloadFile -Destination $convertedFile

# Resize to 256 GB (qcow2 grows on demand: apparent size only; actual
# usage grows on write).
Write-Output "Resizing qcow2 to 256GB..."
& qemu-img resize -f qcow2 $convertedFile 256G
if ($LASTEXITCODE -ne 0) {
    Write-Warning "qemu-img resize failed -- continuing with original size."
    Write-Warning "Resize manually with: qemu-img resize -f qcow2 '$baseImageFile' 256G"
}

# --- REGION: Preserve previous and finalize
$previousFile = Join-Path $downloadDir "$baseImageName.previous.qcow2"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $convertedFile -Destination $baseImageFile

# --- REGION: https://yuruna.link/guest-image-setup#skip-if-same-source-guard
Write-ImageSentinel -SourceUrl $sourceUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -Confirm:$false
Write-Output "Recorded source filename, URL, byte count, and Last-Modified to: $baseImageOrigin"

Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue

Write-Output "Download complete: $baseImageFile"
