<#PSScriptInfo
.VERSION 0.3
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

# Inform and check for elevation
Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
	Write-Output "Please run this script as Administrator."
	Write-Output "Be careful."
	exit 1
}

# Source URL
$sourceFile = "https://cdimage.ubuntu.com/noble/daily-live/current/noble-desktop-amd64.iso"
$localVhdxPath = (Get-VMHost).VirtualHardDiskPath
Write-Output "Hyper-V default VHDX folder: $localVhdxPath"
if (!(Test-Path -Path $localVhdxPath)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $localVhdxPath"
    exit 1
}

# Destination file
$destFile = Join-Path $localVhdxPath "ubuntu.desktop.amd64.iso"
Remove-Item $destFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $sourceFile to $destFile"
Invoke-WebRequest -Uri $sourceFile -OutFile $destFile

# Verify download integrity using SHA256 checksum
$checksumUrl = "https://cdimage.ubuntu.com/noble/daily-live/current/SHA256SUMS"
Write-Output "Verifying download integrity..."
try {
	$checksumContent = (Invoke-WebRequest -Uri $checksumUrl).Content
	$isoFileName = "noble-desktop-amd64.iso"
	$checksumLine = ($checksumContent -split "`n") | Where-Object { $_ -match $isoFileName }
	if ($checksumLine) {
		$expectedHash = ($checksumLine -split '\s+')[0]
		$actualHash = (Get-FileHash -Path $destFile -Algorithm SHA256).Hash
		if ($expectedHash -ine $actualHash) {
			Write-Error "Checksum verification failed. Expected: $expectedHash, Got: $actualHash"
			Remove-Item $destFile -Force -ErrorAction SilentlyContinue
			exit 1
		}
		Write-Output "Checksum verified successfully."
	} else {
		Write-Warning "Could not find checksum for $isoFileName. Skipping verification."
	}
} catch {
	Write-Warning "Could not download checksum file. Skipping integrity verification."
}

Write-Output "Download Complete: $destFile"
