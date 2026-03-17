<#PSScriptInfo
.VERSION 0.3
.GUID 42d7e8f9-a0b1-4c23-d456-7e8f9a0b1c23
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
$sourceFolder = "https://cdn.amazonlinux.com/al2023/os-images/latest/hyperv/"
$localVhdxPath = (Get-VMHost).VirtualHardDiskPath
Write-Output "Hyper-V default VHDX folder: $localVhdxPath"
if (!(Test-Path -Path $localVhdxPath)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $localVhdxPath"
    exit 1
}

# Find the first .zip file link to download
$html = Invoke-WebRequest -Uri $sourceFolder
$zipFile = ($html.Links | Where-Object { $_.href -match "\.zip$" })[0].href
$sourceFile = $sourceFolder + $zipFile

# Destination file
$destFile = Join-Path $localVhdxPath "amazonlinux.zip"
Remove-Item $destFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $sourceFile to $destFile"
Invoke-WebRequest -Uri $sourceFile -OutFile $destFile

# Verify download integrity using SHA256 checksum
$checksumFile = ($html.Links | Where-Object { $_.href -match "\.zip\.sha256$" })
if ($checksumFile) {
	$checksumUrl = $sourceFolder + $checksumFile[0].href
	Write-Output "Verifying download integrity..."
	$checksumContent = (Invoke-WebRequest -Uri $checksumUrl).Content
	$expectedHash = ($checksumContent -split '\s+')[0]
	$actualHash = (Get-FileHash -Path $destFile -Algorithm SHA256).Hash
	if ($expectedHash -ine $actualHash) {
		Write-Error "Checksum verification failed. Expected: $expectedHash, Got: $actualHash"
		Remove-Item $destFile -Force -ErrorAction SilentlyContinue
		exit 1
	}
	Write-Output "Checksum verified successfully."
} else {
	Write-Warning "No checksum file found. Skipping integrity verification."
}

# Extract the .vhdx file from the zip and save as amazonlinux.vhdx
$vhdxName = "amazonlinux.vhdx"
$vhdxFile = Join-Path $localVhdxPath $vhdxName
Remove-Item $vhdxFile -Force -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($destFile)
$entry = $zip.Entries | Where-Object { $_.Name -match "\.vhdx$" }
if ($entry) {
	$stream = $entry.Open()
	try {
		$outStream = [System.IO.File]::Open($vhdxFile, [System.IO.FileMode]::Create)
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

# Clean up the downloaded zip file
Remove-Item $destFile -Force -ErrorAction SilentlyContinue
