<#PSScriptInfo
.VERSION 0.1
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

# === Configuration ===
$sourceUrl = "https://cdn.amazonlinux.com/al2023/os-images/latest/kvm-arm64/"
$downloadDir = "$HOME/virtual/amazon.linux"
$baseImageName = "host.macos.utm.guest.amazon.linux"
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"

# === Find the file to download ===
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

$html = Invoke-WebRequest -Uri $sourceUrl
$qcow2Link = ($html.Links | Where-Object { $_.href -match "\.qcow2$" })[0].href
$downloadUrl = $sourceUrl + $qcow2Link

# === Retrieve and process the files ===
$downloadFile = Join-Path $downloadDir "downloaded.qcow2"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $downloadUrl to $downloadFile"
Invoke-WebRequest -Uri $downloadUrl -OutFile $downloadFile

# Verify download integrity using SHA256 checksum
$checksumLink = ($html.Links | Where-Object { $_.href -match "\.qcow2\.sha256$" })
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

# === Name the file as per naming convention ===
Remove-Item $baseImageFile -Force -ErrorAction SilentlyContinue
Move-Item -Path $downloadFile -Destination $baseImageFile

Write-Output "Download complete: $baseImageFile"
