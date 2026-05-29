<#PSScriptInfo
.VERSION 2026.05.29
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e96
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

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

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
# Save-ImageWithChecksum (Yuruna.Image.psm1) applies the warn-only
# checksum policy. The KVM platform doesn't ship Save-CachedHttpUri
# (yet) so this falls through to a direct Invoke-WebRequest -- still
# centralized so a future cache addition lands in one place.
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Image.psm1") -Force
$checksumLink = ($html.Links | Where-Object { $_.href -match '\.qcow2\.sha256$' } | Select-Object -First 1)
$checksumUrl = if ($checksumLink) { $sourceUrl + $checksumLink.href } else { $null }
$downloaded = Save-ImageWithChecksum `
    -SourceUrl  $downloadUrl `
    -DestPath   $downloadFile `
    -ChecksumUrl $checksumUrl `
    -ChecksumTargetFileName $qcow2Link `
    -OnMismatch 'WarnAndContinue' `
    -Confirm:$false
if (-not $downloaded) {
    Write-Error "Download failed for $downloadUrl"
    exit 1
}
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

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
