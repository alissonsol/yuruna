<#PSScriptInfo
.VERSION 0.1
.GUID 42d7e8f9-a0b1-4c23-d456-7e8f9a0b1c23
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

# Honor debug/verbose flags propagated by Invoke-TestRunner.ps1 via env vars.
if ($env:YURUNA_DEBUG -eq '1')   { $DebugPreference   = 'Continue' }
if ($env:YURUNA_VERBOSE -eq '1') { $VerbosePreference = 'Continue' }

# Inform and check for elevation
Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
	Write-Output "Please run this script as Administrator."
	Write-Output "Be careful."
	exit 1
}

# === Configuration ===
$sourceUrl = "https://cdn.amazonlinux.com/al2023/os-images/latest/hyperv/"
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageName = "host.windows.hyper-v.guest.amazon.linux"
$baseImageFile = Join-Path $downloadDir "$baseImageName.vhdx"

Write-Output "Hyper-V default VHDX folder: $downloadDir"
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
    exit 1
}

# === Find the file to download ===
$html = Invoke-WebRequest -Uri $sourceUrl
$zipLink = ($html.Links | Where-Object { $_.href -match "\.zip$" })[0].href
$downloadUrl = $sourceUrl + $zipLink

# === Retrieve and process the files ===
$downloadFile = Join-Path $downloadDir "downloaded.zip"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $downloadUrl to $downloadFile"
& curl.exe -L --progress-bar -o $downloadFile $downloadUrl
if ($LASTEXITCODE -ne 0) { Write-Error "Download failed (curl exit code $LASTEXITCODE)"; exit 1 }

# Verify download integrity using SHA256 checksum
$checksumLink = ($html.Links | Where-Object { $_.href -match "\.zip\.sha256$" })
if ($checksumLink) {
	$checksumUrl = $sourceUrl + $checksumLink[0].href
	Write-Output "Verifying download integrity..."
	$checksumContent = (Invoke-WebRequest -Uri $checksumUrl).Content
	$expectedHash = ($checksumContent -split '\s+')[0]
	$actualHash = (Get-FileHash -Path $downloadFile -Algorithm SHA256).Hash
	if ($expectedHash -ine $actualHash) {
		Write-Error "Checksum verification failed. Expected: $expectedHash, Got: $actualHash"
		Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
		exit 1
	}
	Write-Output "Checksum verified successfully."
} else {
	Write-Warning "No checksum file found. Skipping integrity verification."
}

# Extract the .vhdx file from the zip — write to a temp path first so the
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

# === Name the file as per naming convention ===
$previousFile = Join-Path $downloadDir "$baseImageName.previous.vhdx"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path $baseImageFile) {
	Move-Item -Path $baseImageFile -Destination $previousFile
	Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $extractedFile -Destination $baseImageFile

$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
Set-Content -Path $baseImageOrigin -Value @($zipLink, $downloadUrl)
Write-Output "Recorded source filename and URL to: $baseImageOrigin"

# Clean up the downloaded zip file
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue

Write-Output "Download complete: $baseImageFile"
