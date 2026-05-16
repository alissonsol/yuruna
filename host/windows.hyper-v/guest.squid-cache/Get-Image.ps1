<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42f0a1b2-c3d4-4e56-f789-0a1b2c3d4e57
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL.
# Each level shows itself + all higher-priority streams; Error is highest.
if ($env:YURUNA_LOG_LEVEL) {
    $_rank = @{ Error=1; Warning=2; Information=3; Verbose=4; Debug=5 }
    if ($_rank.ContainsKey($env:YURUNA_LOG_LEVEL)) {
        $_eff = $_rank[$env:YURUNA_LOG_LEVEL]
        $WarningPreference     = if ($_rank.Warning     -le $_eff) { 'Continue' } else { 'SilentlyContinue' }
        $InformationPreference = if ($_rank.Information -le $_eff) { 'Continue' } else { 'SilentlyContinue' }
        $VerbosePreference     = if ($_rank.Verbose     -le $_eff) { 'Continue' } else { 'SilentlyContinue' }
        $DebugPreference       = if ($_rank.Debug       -le $_eff) { 'Continue' } else { 'SilentlyContinue' }
        if ($_eff -ge $_rank.Verbose) { $ProgressPreference = 'SilentlyContinue' }
    }
}

Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    exit 1
}

# === Configuration ===
# Ubuntu 26.04 LTS (Resolute Raccoon). Moved up from 24.04 LTS (Noble
# Numbat) so the cache VM stays inside the supported-LTS window and
# `unattended-upgrades` (enabled in vmconfig/user-data) keeps pulling
# security patches automatically rather than going EOL mid-cycle.
$sourceUrl = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageName = "host.windows.hyper-v.guest.squid-cache"
$baseImageFile = Join-Path $downloadDir "$baseImageName.vhdx"

Write-Output "Hyper-V default VHDX folder: $downloadDir"
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
    exit 1
}

# Skip-if-same-source guard. Test-DownloadAlreadyCurrent (Yuruna.Host.psm1)
# returns $true only when ALL of the following match the on-disk state:
#   * $baseImageFile exists
#   * the sentinel records the same filename, URL, byte count, AND
#     Last-Modified date as a fresh HEAD probe of $sourceUrl
# Any mismatch -- including a stale 3-line sentinel from before the
# Last-Modified field was added -- forces a re-download. The only way
# to force a re-download manually is to delete or rename $baseImageFile
# (or $baseImageOrigin). The original 3-line format was vulnerable to
# a noble->resolute style URL bump being silently skipped if the
# sentinel happened to be out of sync; the 4-line format closes that.
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

# === Download the cloud image ===
$downloadFile = Join-Path $downloadDir "$baseImageName.downloading.img"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $sourceUrl to $downloadFile"
# Save-CachedHttpUri (Yuruna.Host.psm1) routes through the squid cache
# transparently when one is reachable. Note: this script PROVISIONS
# the squid cache, so on a first-run host the cache doesn't exist yet
# and Save-CachedHttpUri falls through to a direct fetch. Subsequent
# rebuilds (e.g. cache VM rotation) benefit when the cache is up,
# including HTTPS via :3129 SSL-bump with per-process CA trust.
try {
    Save-CachedHttpUri -Uri $sourceUrl -OutFile $downloadFile
} catch {
    Write-Error "Download failed: $($_.Exception.Message)"
    exit 1
}
# Capture the HTTP-download size BEFORE qcow2→vhdx conversion; the
# .vhdx at $baseImageFile is the converted+resized artifact, not the
# bytes Test-DownloadAlreadyCurrent will compare against next run.
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

$fileSize = (Get-Item $downloadFile).Length
if ($fileSize -lt 100MB) {
    Write-Error "Downloaded file is suspiciously small ($([math]::Round($fileSize / 1MB, 1)) MB). Expected ~600 MB."
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# === Convert qcow2 to VHDX ===
# The Ubuntu cloud image is in qcow2 format (.img); Hyper-V needs VHDX.
$qemuImg = Get-Command qemu-img -ErrorAction SilentlyContinue
if (-not $qemuImg) {
    # Try common install locations
    $candidates = @(
        "$env:ProgramFiles\qemu\qemu-img.exe",
        "${env:ProgramFiles(x86)}\qemu\qemu-img.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $qemuImg = $c; break }
    }
}
if (-not $qemuImg) {
    Write-Error "qemu-img not found. Install QEMU for Windows (winget install SoftwareFreedomConservancy.QEMU) or add qemu-img to PATH."
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    exit 1
}

$convertedFile = Join-Path $downloadDir "$baseImageName.converting.vhdx"
Remove-Item $convertedFile -Force -ErrorAction SilentlyContinue
Write-Output "Converting qcow2 to VHDX..."
& $qemuImg convert -f qcow2 -O vhdx -o subformat=dynamic $downloadFile $convertedFile
if ($LASTEXITCODE -ne 0) {
    Write-Error "qemu-img convert failed (exit code $LASTEXITCODE)"
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    Remove-Item $convertedFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# qemu-img on Windows writes the output VHDX through NTFS sparse files,
# which leaves FILE_ATTRIBUTE_SPARSE_FILE set on the file. Resize-VHD
# then fails with 0xC03A001A ("Virtual hard disk files ... must not be
# sparse"). Clear the flag before resizing.
& fsutil sparse setflag $convertedFile 0 | Out-Null

# --- See https://yuruna.link/memory#why-cache-vhdx-uses-resize-vhd-instead-of-qemu-img-resize
Write-Output "Resizing VHDX to 512GB..."
$resized = $false
try {
    Resize-VHD -Path $convertedFile -SizeBytes 512GB -ErrorAction Stop
    $resized = $true
} catch {
    Write-Warning "Resize-VHD failed: $($_.Exception.Message)"
    Write-Output "  Falling back to qemu-img resize..."
    & $qemuImg resize $convertedFile 512G
    if ($LASTEXITCODE -eq 0) { $resized = $true }
}
if (-not $resized) {
    Write-Warning "VHDX resize failed via both Resize-VHD and qemu-img."
    Write-Warning "The cache VM will have only ~3.5 GB of disk — enough for 1-2"
    Write-Warning "Ubuntu Server installs before squid fills it up."
    Write-Warning "Resize manually with: fsutil sparse setflag '$baseImageFile' 0; Resize-VHD -Path '$baseImageFile' -SizeBytes 512GB"
}

# === Preserve previous and finalize ===
$previousFile = Join-Path $downloadDir "$baseImageName.previous.vhdx"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $convertedFile -Destination $baseImageFile

$sourceFileName = [System.IO.Path]::GetFileName(([System.Uri]$sourceUrl).LocalPath)
# Capture the upstream Last-Modified header after the download finishes so
# the sentinel records WHAT THE SERVER SAID at the moment we fetched it.
# A subsequent Test-DownloadAlreadyCurrent compares the new HEAD's
# Last-Modified against this string. cloud-images.ubuntu.com exposes
# Last-Modified consistently; some CDNs strip it. Missing header -> empty
# string, and Test-DownloadAlreadyCurrent skips the date check in that
# direction (URL + size still gate the skip).
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
