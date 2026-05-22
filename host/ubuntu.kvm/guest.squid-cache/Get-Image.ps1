<#PSScriptInfo
.VERSION 2026.05.22
.GUID 42f3d4e5-f6a7-4b89-c012-3d4e5f6a7b8c
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

if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.squid-cache/Get-Image.ps1 only runs on Linux."
    exit 1
}

# === Configuration ===
# Ubuntu 26.04 LTS (Resolute Raccoon). Matches the windows.hyper-v and
# macos.utm squid-cache guests so a cache rebuilt on any host produces
# the same Squid 7.x baseline. `unattended-upgrades` (enabled in
# vmconfig/user-data) keeps pulling security patches automatically so
# the long-lived cache box stays inside the supported window between
# rebuilds.
$arch = (& uname -m).Trim()
switch ($arch) {
    'x86_64'  { $imgArch = 'amd64' }
    'aarch64' { $imgArch = 'arm64' }
    default   { Write-Error "Unsupported arch: $arch"; exit 1 }
}
$sourceUrl     = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-$imgArch.img"
$downloadDir   = "$HOME/yuruna/image/squid-cache"
$baseImageName = "host.ubuntu.kvm.guest.squid-cache"
# libvirt-qemu boots qcow2 natively; no format conversion needed (unlike
# the Hyper-V variant which produces VHDX and the macOS UTM variant which
# produces raw). Keep the cloud-image's native qcow2 and just resize it
# to 512 GB sparse so the squid `cache_dir 393216 16 256` (= 384 GB) +
# OS/logs headroom fits.
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# Skip-if-same-source guard. Inlined here -- the host.windows.hyper-v and
# host.macos.utm Yuruna.Host.psm1 modules export a Test-DownloadAlreadyCurrent
# helper, but the KVM Yuruna.Host.psm1 doesn't (same pattern as the KVM
# ubuntu.server.24 Get-Image.ps1, which also inlines its own check). 4-line
# sentinel records filename + URL + size + Last-Modified; any mismatch
# forces a re-download. The 4-line format closes the noble->resolute
# style URL-bump regression that a 3-line sentinel would silently miss.
$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
function Test-AlreadyCurrent {
    param([string]$Url, [string]$File, [string]$Sentinel)
    if (-not (Test-Path -LiteralPath $File))     { return $false }
    if (-not (Test-Path -LiteralPath $Sentinel)) { return $false }
    $prior = @(Get-Content -LiteralPath $Sentinel -ErrorAction SilentlyContinue)
    if ($prior.Count -lt 4) { return $false }
    $expectedFileName = [System.IO.Path]::GetFileName(([System.Uri]$Url).LocalPath)
    if ($prior[0] -ne $expectedFileName) { return $false }
    if ($prior[1] -ne $Url)              { return $false }
    try {
        $head = Invoke-WebRequest -Uri $Url -Method Head -ErrorAction Stop
        $remoteLen = [int64]$head.Headers['Content-Length']
        $remoteLm  = $head.Headers['Last-Modified']
        if ($remoteLm -is [System.Array]) { $remoteLm = $remoteLm[0] }
        $remoteLm = [string]$remoteLm
    } catch { return $false }
    if ([int64]$prior[2] -ne $remoteLen) { return $false }
    # Last-Modified is the strong signal: cloud-images.ubuntu.com bumps
    # it on every rebuild. Compare only when the server actually returned
    # a header (some CDNs strip it) -- otherwise the URL+size check above
    # carries the skip decision.
    if ($remoteLm -and $prior[3] -and ($prior[3] -ne $remoteLm)) { return $false }
    return $true
}

if (Test-AlreadyCurrent -Url $sourceUrl -File $baseImageFile -Sentinel $baseImageOrigin) {
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
# Direct Invoke-WebRequest (no Save-CachedHttpUri on KVM, where that
# helper isn't exported by Yuruna.Host.psm1). On a first-run host the
# squid cache doesn't exist yet anyway, and subsequent rebuilds will
# still benefit from the kernel page cache if the prior file is still
# warm. SSL-bumped caching of this download requires per-process CA
# trust which the Get-Image bootstrap can't reasonably set up.
try {
    Invoke-WebRequest -Uri $sourceUrl -OutFile $downloadFile -ErrorAction Stop
} catch {
    Write-Error "Download failed: $($_.Exception.Message)"
    exit 1
}
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

if ($downloadedSize -lt 100MB) {
    Write-Error "Downloaded file is suspiciously small ($([math]::Round($downloadedSize / 1MB, 1)) MB). Expected ~600 MB."
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# Resize to 512 GB sparse. qcow2 is dynamic, so 512 GB is the APPARENT
# size only -- actual disk consumption stays low until squid starts
# caching. Sized for squid's `cache_dir ufs /var/spool/squid 393216 16
# 256` (= 384 GB) + ~128 GB OS/logs/headroom. The `maximum_object_size
# 65 GB` directive in vmconfig/user-data lets the proxy cache files
# like the macOS install image (~18 GB) and other multi-GB blobs end-
# to-end instead of bypassing them direct to CDN.
Write-Output "Resizing qcow2 to 512GB..."
& qemu-img resize $downloadFile 512G
if ($LASTEXITCODE -ne 0) {
    Write-Warning "qemu-img resize failed -- continuing with original size."
    Write-Warning "The cache VM will only have the base cloud-image capacity (~3.5 GB)"
    Write-Warning "which fills up after the first prewarm. Resize manually with:"
    Write-Warning "  qemu-img resize '$baseImageFile' 512G"
}

# === Preserve previous and finalize ===
$previousFile = Join-Path $downloadDir "$baseImageName.previous.qcow2"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $downloadFile -Destination $baseImageFile

$sourceFileName = [System.IO.Path]::GetFileName(([System.Uri]$sourceUrl).LocalPath)
# Capture the upstream Last-Modified header after the download finishes so
# the sentinel records WHAT THE SERVER SAID at the moment we fetched it.
# cloud-images.ubuntu.com exposes Last-Modified consistently; some CDNs
# strip it. Missing header -> empty string, and the next-run check
# treats that as "no comparison possible" (URL + size still gate skip).
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

Write-Output "Download complete: $baseImageFile"
