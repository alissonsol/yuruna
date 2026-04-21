<#PSScriptInfo
.VERSION 0.1
.GUID 42d8e9f0-a1b2-4c34-d567-8e9f0a1b2c34
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
& curl -L --progress-bar -o $downloadFile $downloadUrl
if ($LASTEXITCODE -ne 0) { Write-Error "Download failed (curl exit code $LASTEXITCODE)"; exit 1 }

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
$previousFile = Join-Path $downloadDir "$baseImageName.previous.qcow2"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $downloadFile -Destination $baseImageFile

$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
Set-Content -Path $baseImageOrigin -Value @($qcow2Link, $downloadUrl)
Write-Output "Recorded source filename and URL to: $baseImageOrigin"

Write-Output "Download complete: $baseImageFile"
