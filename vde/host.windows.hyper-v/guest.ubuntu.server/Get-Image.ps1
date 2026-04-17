<#PSScriptInfo
.VERSION 0.1
.GUID 42c7d8e9-f0a1-4b23-c456-7d8e9f0a1b24
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

<#
.SYNOPSIS
    Downloads the Ubuntu Server 24.04 live-server amd64 ISO for autoinstall.

.DESCRIPTION
    Sister script to guest.ubuntu.desktop/Get-Image.ps1 that pulls the SERVER
    variant instead. The server ISO matters because its cdrom ships a full
    kernel meta-package (`linux-generic`) and a network-configured
    `ubuntu.sources` — the desktop (bootstrap) ISO ships neither, which made
    curtin's install_kernel step fail with "Unable to locate package".

    The desktop environment is added post-install via the user-data
    `packages:` list (ubuntu-desktop), so the final VM still boots to GDM —
    it just takes a longer first-boot while ubuntu-desktop downloads via
    squid-cache.

.PARAMETER daily
    If set, pulls the rolling daily ISO instead of the latest stable point
    release. Useful for catching regressions before a yuruna release commits
    to a specific point release.
#>

param(
    [switch]$daily
)

# Inform and check for elevation
Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    Write-Output "Be careful."
    exit 1
}

# === Configuration ===
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageName = "host.windows.hyper-v.guest.ubuntu.server"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"

if ($daily) {
    # Server dailies live under ubuntu-server/daily-live/ — different path
    # from the desktop daily-live/ tree.
    $isoFileName = "noble-live-server-amd64.iso"
    $sourceUrl = "https://cdimage.ubuntu.com/ubuntu-server/daily-live/current/$isoFileName"
    $checksumUrl = "https://cdimage.ubuntu.com/ubuntu-server/daily-live/current/SHA256SUMS"
} else {
    $releaseBaseUrl = "https://releases.ubuntu.com/noble/"
    Write-Output "Discovering latest stable release from $releaseBaseUrl ..."
    $releasePage = (Invoke-WebRequest -Uri "$releaseBaseUrl/").Content
    $isoPattern = 'ubuntu-[\d.]+-live-server-amd64\.iso'
    $isoMatches = [regex]::Matches($releasePage, $isoPattern)
    if ($isoMatches.Count -eq 0) {
        Write-Error "Could not find a stable live-server amd64 ISO at $releaseBaseUrl"
        exit 1
    }
    $isoFileName = ($isoMatches | Sort-Object Value -Descending | Select-Object -First 1).Value
    $sourceUrl = "$releaseBaseUrl/$isoFileName"
    $checksumUrl = "$releaseBaseUrl/SHA256SUMS"
}

Write-Output "Hyper-V default VHDX folder: $downloadDir"
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
    exit 1
}

# === Retrieve and process the files ===
$downloadFile = Join-Path $downloadDir "downloaded.iso"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $sourceUrl to $downloadFile"
& curl.exe -L --progress-bar -o $downloadFile $sourceUrl
if ($LASTEXITCODE -ne 0) { Write-Error "Download failed (curl exit code $LASTEXITCODE)"; exit 1 }

# Verify download integrity using SHA256 checksum
Write-Output "Verifying download integrity..."
try {
    $checksumContent = (Invoke-WebRequest -Uri $checksumUrl).Content
    $checksumLine = ($checksumContent -split "`n") | Where-Object { $_ -match [regex]::Escape($isoFileName) }
    if ($checksumLine) {
        $expectedHash = ($checksumLine -split '\s+')[0]
        $actualHash = (Get-FileHash -Path $downloadFile -Algorithm SHA256).Hash
        if ($expectedHash -ine $actualHash) {
            Write-Error "Checksum verification failed. Expected: $expectedHash, Got: $actualHash"
            Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
            exit 1
        }
        Write-Output "Checksum verified successfully."
    } else {
        Write-Warning "Could not find checksum for $isoFileName. Skipping verification."
    }
} catch {
    Write-Warning "Could not download checksum file. Skipping integrity verification."
}

# === Name the file as per naming convention ===
$previousFile = Join-Path $downloadDir "$baseImageName.previous.iso"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $downloadFile -Destination $baseImageFile

Write-Output "Download complete: $baseImageFile"
