<#PSScriptInfo
.VERSION 2026.05.29
.GUID 42f2c3d4-e5f6-4a78-b901-c2d3e4f5a682
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

# === Configuration ===
# Ubuntu 24.04 LTS (Noble Numbat), arm64 cloud image -- macOS UTM
# runs on Apple Silicon. Pinned per the stash-service spec (§3.1:
# default image ubuntu.server.24).
$sourceUrl = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img"
$downloadDir = "$HOME/yuruna/image/stash-service"
$baseImageName = "host.macos.utm.guest.stash-service"
# Final artifact is RAW: standardized on raw so New-VM.ps1 can copy
# the ready-to-boot disk directly into the .utm bundle without a
# format-conversion step. Matches the caching-proxy UTM pipeline.
$baseImageFile = Join-Path $downloadDir "$baseImageName.raw"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Host.psm1") -Force
if (Test-DownloadAlreadyCurrent -SourceUrl $sourceUrl -BaseImageFile $baseImageFile -OriginFile $baseImageOrigin -Verbose:($VerbosePreference -ne 'SilentlyContinue')) {
    $skipLines = @(Get-Content -LiteralPath $baseImageOrigin -ErrorAction SilentlyContinue)
    $msg = @(
        "Skipping download: source URL + size + Last-Modified all match the prior run for $baseImageFile."
        "  Sentinel: $baseImageOrigin"
        "    filename     : $($skipLines[0])"
        "    source URL   : $($skipLines[1])"
        "    byte count   : $($skipLines[2])"
        "    last-modified: $($skipLines[3])"
        "  To force a re-download, delete or rename: $baseImageFile"
    ) -join [Environment]::NewLine
    Write-Information $msg -InformationAction Continue
    Write-Output $msg
    exit 0
}

$downloadFile = Join-Path $downloadDir "$baseImageName.downloading.qcow2"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Image.psm1") -Force
$sourceDir = $sourceUrl.Substring(0, $sourceUrl.LastIndexOf('/'))
$sourceBaseName = $sourceUrl.Substring($sourceUrl.LastIndexOf('/') + 1)
$downloaded = Save-ImageWithChecksum `
    -SourceUrl   $sourceUrl `
    -DestPath    $downloadFile `
    -ChecksumUrl "$sourceDir/SHA256SUMS" `
    -ChecksumTargetFileName $sourceBaseName `
    -OnMismatch  'WarnAndContinue' `
    -Confirm:$false
if (-not $downloaded) {
    Write-Error "Download failed for $sourceUrl"
    exit 1
}
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

$fileSize = (Get-Item $downloadFile).Length
if ($fileSize -lt 100MB) {
    Write-Error "Downloaded file is suspiciously small ($([math]::Round($fileSize / 1MB, 1)) MB). Expected ~600 MB."
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# === Convert qcow2 → raw ===
$convertedFile = Join-Path $downloadDir "$baseImageName.converting.raw"
Remove-Item $convertedFile -Force -ErrorAction SilentlyContinue
Write-Output "Converting qcow2 to raw..."
& qemu-img convert -f qcow2 -O raw $downloadFile $convertedFile
if ($LASTEXITCODE -ne 0) {
    Write-Error "qemu-img convert failed. Install QEMU with: brew install qemu"
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    Remove-Item $convertedFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# Resize to 256 GB (sparse on APFS: apparent size only; actual usage
# grows on write).
Write-Output "Resizing raw image to 256GB..."
& qemu-img resize -f raw $convertedFile 256G
if ($LASTEXITCODE -ne 0) {
    Write-Warning "qemu-img resize failed -- continuing with original size."
    Write-Warning "Resize manually with: qemu-img resize -f raw '$baseImageFile' 256G"
}

# === Preserve previous and finalize ===
$previousFile = Join-Path $downloadDir "$baseImageName.previous.raw"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $convertedFile -Destination $baseImageFile

$sourceFileName = [System.IO.Path]::GetFileName(([System.Uri]$sourceUrl).LocalPath)
$sourceLastModified = ''
try {
    $head = Invoke-WebRequest -Uri $sourceUrl -Method Head -ErrorAction Stop
    $lm = $head.Headers['Last-Modified']
    if ($lm -is [System.Array]) { $lm = $lm[0] }
    $sourceLastModified = [string]$lm
} catch {
    Write-Verbose "Last-Modified HEAD probe failed (sentinel will record empty): $($_.Exception.Message)"
}
Set-Content -Path $baseImageOrigin -Value @($sourceFileName, $sourceUrl, "$downloadedSize", $sourceLastModified)
Write-Output "Recorded source filename, URL, byte count, and Last-Modified to: $baseImageOrigin"

Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue

Write-Output "Download complete: $baseImageFile"
