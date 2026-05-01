<#PSScriptInfo
.VERSION 0.1
.GUID 42f0a1b2-c3d4-4e56-f789-0a1b2c3d4e57
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

# Honor debug/verbose flags propagated by Invoke-TestRunner.ps1 via env vars.
if ($env:YURUNA_DEBUG -eq '1')   { $DebugPreference   = 'Continue' }
if ($env:YURUNA_VERBOSE -eq '1') { $VerbosePreference = 'Continue' }
# Silence Write-Progress under the test runner.
if ($env:YURUNA_DEBUG -or $env:YURUNA_VERBOSE) { $ProgressPreference = 'SilentlyContinue' }

Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    exit 1
}

# === Configuration ===
$sourceUrl = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageName = "host.windows.hyper-v.guest.squid-cache"
$baseImageFile = Join-Path $downloadDir "$baseImageName.vhdx"

Write-Output "Hyper-V default VHDX folder: $downloadDir"
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
    exit 1
}

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

# === Download the cloud image ===
# Route HTTP downloads through the squid cache when one is reachable.
# Note: this script provisions the squid cache itself, so on a first-
# run host the cache won't exist yet — Get-CacheProxyForHostDownload
# returns $null and the download goes direct, which is correct.
# Subsequent runs (e.g. rebuilding the cache VM after an apt update)
# benefit if the cache image was already pulled by an earlier siblng
# guest. For HTTPS the helper also returns $null.
$iwrCommon = @{}
$cacheProxy = Get-CacheProxyForHostDownload -Uri $sourceUrl
if ($cacheProxy) {
    $iwrCommon['Proxy'] = $cacheProxy
    Write-Output "Routing download through squid cache: $cacheProxy"
}
$downloadFile = Join-Path $downloadDir "$baseImageName.downloading.img"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $sourceUrl to $downloadFile"
try {
    Invoke-WebRequest -Uri $sourceUrl -OutFile $downloadFile -ErrorAction Stop @iwrCommon
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

# Resize to 144 GB for cache storage (128 GB squid cache_dir + ~16 GB
# OS/logs headroom). Prefer Hyper-V's native Resize-VHD:
# qemu-img reports "This image does not support resize" for VHDX files it
# creates, even with subformat=dynamic. Resize-VHD handles VHDX correctly.
Write-Output "Resizing VHDX to 144GB..."
$resized = $false
try {
    Resize-VHD -Path $convertedFile -SizeBytes 144GB -ErrorAction Stop
    $resized = $true
} catch {
    Write-Warning "Resize-VHD failed: $($_.Exception.Message)"
    Write-Output "  Falling back to qemu-img resize..."
    & $qemuImg resize $convertedFile 144G
    if ($LASTEXITCODE -eq 0) { $resized = $true }
}
if (-not $resized) {
    Write-Warning "VHDX resize failed via both Resize-VHD and qemu-img."
    Write-Warning "The cache VM will have only ~3.5 GB of disk — enough for 1-2"
    Write-Warning "Ubuntu Desktop installs before squid fills it up."
    Write-Warning "Resize manually with: fsutil sparse setflag '$baseImageFile' 0; Resize-VHD -Path '$baseImageFile' -SizeBytes 144GB"
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
Set-Content -Path $baseImageOrigin -Value @($sourceFileName, $sourceUrl, "$downloadedSize")
Write-Output "Recorded source filename, URL, and byte count to: $baseImageOrigin"

Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue

Write-Output "Download complete: $baseImageFile"
