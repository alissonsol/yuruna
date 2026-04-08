<#PSScriptInfo
.VERSION 0.1
.GUID 42a3b4c5-d6e7-4f89-a012-3b4c5d6e7f89
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

param(
    [switch]$stable
)

# === Configuration ===
$downloadDir = "$HOME/virtual/ubuntu.env"
$baseImageName = "host.macos.utm.guest.ubuntu.desktop"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"

if ($stable) {
    $releaseBaseUrl = "https://cdimage.ubuntu.com/releases/noble/release"
    # Discover the latest stable ISO filename from the release page
    Write-Output "Discovering latest stable release from $releaseBaseUrl ..."
    $releasePage = (Invoke-WebRequest -Uri "$releaseBaseUrl/").Content
    $isoPattern = 'ubuntu-[\d.]+-desktop-arm64\.iso'
    $isoMatches = [regex]::Matches($releasePage, $isoPattern)
    if ($isoMatches.Count -eq 0) {
        Write-Error "Could not find a stable desktop arm64 ISO at $releaseBaseUrl"
        exit 1
    }
    $isoFileName = ($isoMatches | Sort-Object Value -Descending | Select-Object -First 1).Value
    $sourceUrl = "$releaseBaseUrl/$isoFileName"
    $checksumUrl = "$releaseBaseUrl/SHA256SUMS"
} else {
    $isoFileName = "noble-desktop-arm64.iso"
    $sourceUrl = "https://cdimage.ubuntu.com/noble/daily-live/current/$isoFileName"
    $checksumUrl = "https://cdimage.ubuntu.com/noble/daily-live/current/SHA256SUMS"
}

# === Find the file to download ===
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# === Retrieve and process the files ===
$downloadFile = Join-Path $downloadDir "downloaded.iso"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $sourceUrl to $downloadFile"
& curl -L --progress-bar -o $downloadFile $sourceUrl
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
Remove-Item $baseImageFile -Force -ErrorAction SilentlyContinue
Move-Item -Path $downloadFile -Destination $baseImageFile

Write-Output "Download complete: $baseImageFile"
