<#PSScriptInfo
.VERSION 2026.06.19
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
# Ubuntu 26.04 LTS (Resolute Raccoon), arm64 cloud image -- macOS UTM
# runs on Apple Silicon. Moved up from 24.04 LTS (Noble Numbat) per the
# stash-service spec (section 3.1: default image ubuntu.server.26),
# matching the caching-proxy LTS so the stash VM stays in the supported-LTS
# window and the distro Go toolchain satisfies the daemon's go.mod directive.
$sourceUrl = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-arm64.img"
$downloadDir = "$HOME/yuruna/image/stash-service"
$baseImageName = "host.macos.utm.guest.stash-service"
# Final artifact is qcow2: UTM's QEMU backend boots qcow2 directly, so
# no raw conversion is needed. qcow2 is also required for correctness on
# macOS -- UTM attaches read-write disks with
# discard=unmap,detect-zeroes=unmap, and QEMU's macOS file-posix backend
# services those discards via fcntl(F_PUNCHHOLE), which rejects any
# request not aligned to the APFS 4 KiB block size with EINVAL ("Invalid
# argument"). A raw image punches holes at the guest's 512-byte discard
# granularity and trips that; qcow2 only ever punches at its 64 KiB
# cluster boundaries. Matches the caching-proxy UTM pipeline. See
# feedback_macos-qemu-punchhole-alignment.md.
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"

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
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "modules/Yuruna.Image.psm1") -Force
$sourceDir = $sourceUrl.Substring(0, $sourceUrl.LastIndexOf('/'))
$sourceBaseName = $sourceUrl.Substring($sourceUrl.LastIndexOf('/') + 1)
$downloaded = Save-ImageWithChecksum `
    -SourceUrl   $sourceUrl `
    -DestPath    $downloadFile `
    -ChecksumUrl "$sourceDir/SHA256SUMS" `
    -ChecksumTargetFileName $sourceBaseName `
    -OnMismatch  'WarnAndDelete' `
    -VerifyUbuntuSignature `
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

# === Resize the qcow2 to 256 GB ===
# No raw conversion: UTM's QEMU backend boots qcow2 directly, and qcow2
# avoids the macOS F_PUNCHHOLE-alignment EINVAL a raw disk hits under
# UTM's discard=unmap,detect-zeroes=unmap (see the header note and
# feedback_macos-qemu-punchhole-alignment.md). Resize a staging copy of
# the downloaded qcow2, then promote it in the finalize block below.
$convertedFile = Join-Path $downloadDir "$baseImageName.staging.qcow2"
Remove-Item $convertedFile -Force -ErrorAction SilentlyContinue
Copy-Item -LiteralPath $downloadFile -Destination $convertedFile

# Resize to 256 GB (qcow2 grows on demand: apparent size only; actual
# usage grows on write).
Write-Output "Resizing qcow2 image to 256GB..."
& qemu-img resize -f qcow2 $convertedFile 256G
if ($LASTEXITCODE -ne 0) {
    Write-Warning "qemu-img resize failed -- continuing with original size."
    Write-Warning "Resize manually with: qemu-img resize -f qcow2 '$baseImageFile' 256G"
}

# === Preserve previous and finalize ===
$previousFile = Join-Path $downloadDir "$baseImageName.previous.qcow2"
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
