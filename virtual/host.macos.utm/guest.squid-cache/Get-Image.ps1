<#PSScriptInfo
.VERSION 0.1
.GUID 42f2c3d4-e5f6-4a78-b901-c2d3e4f5a6b8
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

# Honor debug/verbose flags from Invoke-TestRunner.ps1. Silence
# Write-Progress when the runner (non-interactive) set either flag.
if ($env:YURUNA_DEBUG -eq '1')   { $DebugPreference   = 'Continue' }
if ($env:YURUNA_VERBOSE -eq '1') { $VerbosePreference = 'Continue' }
if ($env:YURUNA_DEBUG -or $env:YURUNA_VERBOSE) { $ProgressPreference = 'SilentlyContinue' }

# === Configuration ===
# arm64 cloud image -- macOS UTM runs on Apple Silicon via Apple Virtualization.
$sourceUrl = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img"
$downloadDir = "$HOME/virtual/squid-cache"
$baseImageName = "host.macos.utm.guest.squid-cache"
# Final artifact is RAW: Apple Virtualization.framework accepts only raw
# block-device images. Convert once here so New-VM.ps1 can copy the
# ready-to-boot disk directly into the .utm bundle.
$baseImageFile = Join-Path $downloadDir "$baseImageName.raw"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# Skip-if-same-source guard. Test-DownloadAlreadyCurrent (VM.common.psm1)
# returns $true only when $baseImageFile is on disk, the sentinel records
# the same URL we just resolved, and a HEAD probe's Content-Length matches
# the recorded byte count. The only way to force a re-download is to
# delete or rename $baseImageFile.
$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "VM.common.psm1") -Force
if (Test-DownloadAlreadyCurrent -SourceUrl $sourceUrl -BaseImageFile $baseImageFile -OriginFile $baseImageOrigin) {
    $msg = "Skipping download: $sourceUrl URL and expected size match the prior run for $baseImageFile. To force a re-download, delete or rename: $baseImageFile"
    Write-Information $msg -InformationAction Continue
    Write-Output $msg
    exit 0
}

# Route HTTP downloads through the squid cache when one is reachable.
# Note: this script provisions the squid cache itself, so on a first-
# run host the cache won't exist yet — Get-CacheProxyForHostDownload
# returns $null and the download goes direct, which is correct.
# Subsequent runs (e.g. rebuilding the cache VM after an apt update)
# benefit if the cache image was already pulled by an earlier sibling
# guest. For HTTPS the helper also returns $null.
$iwrCommon = @{}
$cacheProxy = Get-CacheProxyForHostDownload -Uri $sourceUrl
if ($cacheProxy) {
    $iwrCommon['Proxy'] = $cacheProxy
    Write-Output "Routing download through squid cache: $cacheProxy"
}
$downloadFile = Join-Path $downloadDir "$baseImageName.downloading.qcow2"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $sourceUrl to $downloadFile"
try {
    Invoke-WebRequest -Uri $sourceUrl -OutFile $downloadFile -ErrorAction Stop @iwrCommon
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

# Resize to 144 GB (sparse on APFS: apparent 144 GB, actual ~2.5 GB
# until used). Sized for squid's 128 GB cache_dir + ~16 GB OS/logs/swap
# headroom -- see vmconfig/user-data `cache_dir ufs /var/spool/squid 131072`.
Write-Output "Resizing raw image to 144GB..."
& qemu-img resize -f raw $convertedFile 144G
if ($LASTEXITCODE -ne 0) {
    Write-Warning "qemu-img resize failed — continuing with original size."
    Write-Warning "The cache VM will only have the base cloud-image capacity (~2.5 GB)"
    Write-Warning "which fills up after 1-2 installs. Resize manually with:"
    Write-Warning "  qemu-img resize -f raw '$baseImageFile' 144G"
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
Set-Content -Path $baseImageOrigin -Value @($sourceFileName, $sourceUrl, "$downloadedSize")
Write-Output "Recorded source filename, URL, and byte count to: $baseImageOrigin"

# Only the raw is needed now.
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue

Write-Output "Download complete: $baseImageFile"
