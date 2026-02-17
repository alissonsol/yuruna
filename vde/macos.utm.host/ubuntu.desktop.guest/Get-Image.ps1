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

Write-Output "Download Complete: $destFile"
