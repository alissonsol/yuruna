<#PSScriptInfo
.VERSION 2026.05.22
.GUID 42f2c3d4-e5f6-4a78-b901-c2d3e4f5a6b8
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

# === Configuration ===
# Ubuntu 26.04 LTS (Resolute Raccoon), arm64 cloud image -- macOS UTM
# runs on Apple Silicon via Apple Virtualization. Moved up from 24.04
# LTS (Noble Numbat) so the cache VM stays inside the supported-LTS
# window and `unattended-upgrades` (enabled in vmconfig/user-data)
# keeps pulling security patches automatically rather than going EOL
# mid-cycle.
$sourceUrl = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-arm64.img"
$downloadDir = "$HOME/yuruna/image/squid-cache"
$baseImageName = "host.macos.utm.guest.squid-cache"
# Final artifact is RAW: Apple Virtualization.framework accepts only raw
# block-device images. Convert once here so New-VM.ps1 can copy the
# ready-to-boot disk directly into the .utm bundle.
$baseImageFile = Join-Path $downloadDir "$baseImageName.raw"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

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

$downloadFile = Join-Path $downloadDir "$baseImageName.downloading.qcow2"
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
# Capture the HTTP-download size BEFORE qcow2→raw conversion; the
# .raw at $baseImageFile is the converted+resized artifact, not the
# bytes Test-DownloadAlreadyCurrent will compare against next run.
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

$fileSize = (Get-Item $downloadFile).Length
if ($fileSize -lt 100MB) {
    Write-Error "Downloaded file is suspiciously small ($([math]::Round($fileSize / 1MB, 1)) MB). Expected ~600 MB."
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# === Convert qcow2 → raw for Apple Virtualization ===
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

# Resize to 512 GB (sparse on APFS: apparent 512 GB, actual ~2.5 GB
# until used). Sized for squid's 384 GB cache_dir + ~128 GB OS/logs/
# headroom -- see vmconfig/user-data `cache_dir ufs /var/spool/squid
# 393216` and the `maximum_object_size 65 GB` directive that lets the
# proxy cache files like the macOS install image (~18 GB) and other
# multi-GB blobs end-to-end instead of bypassing them direct to CDN.
Write-Output "Resizing raw image to 512GB..."
& qemu-img resize -f raw $convertedFile 512G
if ($LASTEXITCODE -ne 0) {
    Write-Warning "qemu-img resize failed — continuing with original size."
    Write-Warning "The cache VM will only have the base cloud-image capacity (~2.5 GB)"
    Write-Warning "which fills up after 1-2 installs. Resize manually with:"
    Write-Warning "  qemu-img resize -f raw '$baseImageFile' 512G"
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

# Only the raw is needed now.
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue

Write-Output "Download complete: $baseImageFile"
