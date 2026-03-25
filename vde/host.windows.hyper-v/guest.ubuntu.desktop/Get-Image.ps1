<#PSScriptInfo
.VERSION 0.1
.GUID 42c7d8e9-f0a1-4b23-c456-7d8e9f0a1b23
.AUTHOR Alisson Sol
.COMPANYNAME None
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

param(
    [switch]$stable
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
$baseImageName = "host.windows.hyper-v.guest.ubuntu.desktop"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"

if ($stable) {
    $releaseBaseUrl = "https://releases.ubuntu.com/noble/"
    # Discover the latest stable ISO filename from the release page
    Write-Output "Discovering latest stable release from $releaseBaseUrl ..."
    $releasePage = (Invoke-WebRequest -Uri "$releaseBaseUrl/").Content
    $isoPattern = 'ubuntu-[\d.]+-desktop-amd64\.iso'
    $matches = [regex]::Matches($releasePage, $isoPattern)
    if ($matches.Count -eq 0) {
        Write-Error "Could not find a stable desktop amd64 ISO at $releaseBaseUrl"
        exit 1
    }
    $isoFileName = ($matches | Sort-Object Value -Descending | Select-Object -First 1).Value
    $sourceUrl = "$releaseBaseUrl/$isoFileName"
    $checksumUrl = "$releaseBaseUrl/SHA256SUMS"
} else {
    $isoFileName = "noble-desktop-amd64.iso"
    $sourceUrl = "https://cdimage.ubuntu.com/noble/daily-live/current/$isoFileName"
    $checksumUrl = "https://cdimage.ubuntu.com/noble/daily-live/current/SHA256SUMS"
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
Invoke-WebRequest -Uri $sourceUrl -OutFile $downloadFile

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
