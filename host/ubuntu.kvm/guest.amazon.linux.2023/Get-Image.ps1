<#PSScriptInfo
.VERSION 2026.05.22
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e96
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

<#
.SYNOPSIS
    Downloads the Amazon Linux 2023 KVM cloud image (qcow2) for libvirt.

.DESCRIPTION
    AL2023 ships native qcow2 images under cdn.amazonlinux.com keyed by
    platform: kvm (x86_64) or kvm-arm64. The directory listing on the
    HTTPS endpoint exposes a single .qcow2 + matching .qcow2.sha256
    sidecar per release; this script picks both, verifies, and stages
    the file under ~/yuruna/image/amazon.linux.2023/.
#>

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
    Write-Error "host/ubuntu.kvm/guest.amazon.linux.2023/Get-Image.ps1 only runs on Linux."
    exit 1
}

$arch = (& uname -m).Trim()
switch ($arch) {
    'x86_64'  { $platDir = 'kvm' }
    'aarch64' { $platDir = 'kvm-arm64' }
    default   { Write-Error "Unsupported arch: $arch"; exit 1 }
}

$sourceUrl     = "https://cdn.amazonlinux.com/al2023/os-images/latest/$platDir/"
$downloadDir   = "$HOME/yuruna/image/amazon.linux.2023"
$baseImageName = "host.ubuntu.kvm.guest.amazon.linux.2023"
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"
$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

$html = Invoke-WebRequest -Uri $sourceUrl -ErrorAction Stop
$qcow2Link = ($html.Links | Where-Object { $_.href -match '\.qcow2$' } | Select-Object -First 1).href
if (-not $qcow2Link) {
    Write-Error "No .qcow2 listed at $sourceUrl"
    exit 1
}
$downloadUrl = $sourceUrl + $qcow2Link

function Test-AlreadyCurrent {
    param([string]$Url, [string]$File, [string]$Sentinel)
    if (-not (Test-Path -LiteralPath $File)) { return $false }
    if (-not (Test-Path -LiteralPath $Sentinel)) { return $false }
    $prior = Get-Content -LiteralPath $Sentinel -ErrorAction SilentlyContinue
    if ($prior.Count -lt 3) { return $false }
    if ($prior[1] -ne $Url) { return $false }
    try {
        $head = Invoke-WebRequest -Uri $Url -Method Head -ErrorAction Stop
        $remoteLen = [int64]$head.Headers['Content-Length']
    } catch { return $false }
    return ([int64]$prior[2] -eq $remoteLen)
}

if (Test-AlreadyCurrent -Url $downloadUrl -File $baseImageFile -Sentinel $baseImageOrigin) {
    Write-Output "Skipping download: $downloadUrl URL and size match prior run for $baseImageFile"
    exit 0
}

$downloadFile = Join-Path $downloadDir 'downloaded.qcow2'
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $downloadUrl"
Invoke-WebRequest -Uri $downloadUrl -OutFile $downloadFile -ErrorAction Stop
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

# SHA256 sidecar (e.g. al2023-kvm-2023.x.y.qcow2.sha256).
$checksumLink = ($html.Links | Where-Object { $_.href -match '\.qcow2\.sha256$' } | Select-Object -First 1)
if ($checksumLink) {
    try {
        $checksumUrl  = $sourceUrl + $checksumLink.href
        $expectedHash = (Invoke-WebRequest -Uri $checksumUrl -ErrorAction Stop).Content.Trim().Split()[0]
        $actualHash   = (Get-FileHash -Path $downloadFile -Algorithm SHA256).Hash
        if ($expectedHash -ine $actualHash) {
            Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
            Write-Error "Checksum mismatch. Expected $expectedHash, got $actualHash"
            exit 1
        }
        Write-Output "Checksum verified."
    } catch {
        Write-Warning "Could not verify checksum: $($_.Exception.Message)"
    }
} else {
    Write-Warning "No .qcow2.sha256 sidecar at $sourceUrl; skipping integrity check."
}

$previousFile = Join-Path $downloadDir "$baseImageName.previous.qcow2"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $downloadFile -Destination $baseImageFile

Set-Content -Path $baseImageOrigin -Value @($qcow2Link, $downloadUrl, "$downloadedSize")
Write-Output "Recorded source filename, URL, and byte count to: $baseImageOrigin"
Write-Output "Download complete: $baseImageFile"
