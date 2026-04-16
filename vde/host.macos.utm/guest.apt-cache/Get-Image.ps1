<#PSScriptInfo
.VERSION 0.1
.GUID 42f2c3d4-e5f6-4a78-b901-c2d3e4f5a6b7
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# === Configuration ===
$sourceUrl = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img"
$downloadDir = "$HOME/virtual/apt-cache"
$baseImageName = "host.macos.utm.guest.apt-cache"
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"

# === Download ===
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

$downloadFile = Join-Path $downloadDir "$baseImageName.downloading.qcow2"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $sourceUrl to $downloadFile"
& curl -L --progress-bar -o $downloadFile $sourceUrl
if ($LASTEXITCODE -ne 0) { Write-Error "Download failed (curl exit code $LASTEXITCODE)"; exit 1 }

$fileSize = (Get-Item $downloadFile).Length
if ($fileSize -lt 100MB) {
    Write-Error "Downloaded file is suspiciously small ($([math]::Round($fileSize / 1MB, 1)) MB). Expected ~600 MB."
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# Resize to 50GB for cache storage
Write-Output "Resizing image to 50GB..."
& qemu-img resize $downloadFile 50G
if ($LASTEXITCODE -ne 0) {
    Write-Warning "qemu-img resize failed — continuing with original size."
}

# === Preserve previous and finalize ===
$previousFile = Join-Path $downloadDir "$baseImageName.previous.qcow2"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $downloadFile -Destination $baseImageFile

Write-Output "Download complete: $baseImageFile"
