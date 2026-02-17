<#PSScriptInfo
.VERSION 0.3
.GUID 42a3b4c5-d6e7-4f89-a012-3b4c5d6e7f89
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

# Source URL
$sourceFile = "https://cdimage.ubuntu.com/noble/daily-live/current/noble-desktop-arm64.iso"
$destDir = "$HOME/virtual/ubuntu.env"
$destFile = Join-Path $destDir "ubuntu.desktop.arm64.downloaded.iso"

# Ensure download directory exists
New-Item -ItemType Directory -Force -Path $destDir | Out-Null

# Destination file
Remove-Item $destFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $sourceFile to $destFile"
Invoke-WebRequest -Uri $sourceFile -OutFile $destFile

# Verify download integrity using SHA256 checksum
$checksumUrl = "https://cdimage.ubuntu.com/noble/daily-live/current/SHA256SUMS"
Write-Output "Verifying download integrity..."
try {
    $checksumContent = (Invoke-WebRequest -Uri $checksumUrl).Content
    $isoFileName = "noble-desktop-arm64.iso"
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
