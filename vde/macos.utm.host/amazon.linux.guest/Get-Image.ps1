<#PSScriptInfo
.VERSION 0.3
.GUID 42d8e9f0-a1b2-4c34-d567-8e9f0a1b2c34
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

# Source URL (Amazon Linux 2023 KVM ARM64 image)
$sourceFolder = "https://cdn.amazonlinux.com/al2023/os-images/latest/kvm-arm64/"
$destDir = "$HOME/virtual/amazon.linux"
$destQcow2File = Join-Path $destDir "amazonlinux.qcow2"

# Ensure download directory exists
New-Item -ItemType Directory -Force -Path $destDir | Out-Null

# Find the first .qcow2 file link to download
$html = Invoke-WebRequest -Uri $sourceFolder
$qcow2File = ($html.Links | Where-Object { $_.href -match "\.qcow2$" })[0].href
$sourceFile = $sourceFolder + $qcow2File

# Download the image
Remove-Item $destQcow2File -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $sourceFile to $destQcow2File"
Invoke-WebRequest -Uri $sourceFile -OutFile $destQcow2File

Write-Output "Download Complete: $destQcow2File"
