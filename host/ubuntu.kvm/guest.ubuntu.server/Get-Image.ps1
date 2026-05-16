<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e94
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
    Downloads the Ubuntu Server 24.04 live-server ISO for autoinstall on KVM.

.DESCRIPTION
    Mirrors host/macos.utm/guest.ubuntu.server/Get-Image.ps1 and
    host/windows.hyper-v/guest.ubuntu.server/Get-Image.ps1 so all three
    hosts boot the same live-server ISO and run subiquity autoinstall.
    The earlier KVM revision used the pre-baked cloud image (.img) +
    NoCloud cloud-init seed, which boots in seconds but DOES NOT show
    the "Continue with autoinstall?" prompt or fire subiquity's
    late-commands — making the boot sequence non-comparable across
    hosts (the GUI test sequence step that waits for that prompt would
    time out on KVM only).

    Architecture (amd64/arm64) is picked from the host. Stable point
    release is preferred; falls back to the rolling daily build.

.PARAMETER daily
    If set, pulls the rolling daily ISO instead of the latest stable
    point release. Useful for catching regressions before yuruna
    pins to a specific point release.
#>

param(
    [switch]$daily
)

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL.
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
    Write-Error "host/ubuntu.kvm/guest.ubuntu.server/Get-Image.ps1 only runs on Linux."
    exit 1
}

$arch = (& uname -m).Trim()
switch ($arch) {
    'x86_64'  { $cloudArch = 'amd64' }
    'aarch64' { $cloudArch = 'arm64' }
    default   { Write-Error "Unsupported arch: $arch"; exit 1 }
}

# === Configuration ===
$downloadDir   = "$HOME/yuruna/image/ubuntu.env"
$baseImageName = "host.ubuntu.kvm.guest.ubuntu.server"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"

function Write-ExceptionDetail {
    param($Record)
    Write-Verbose "Exception type: $($Record.Exception.GetType().FullName)"
    if ($Record.Exception.InnerException) {
        Write-Verbose "Inner: $($Record.Exception.InnerException.GetType().FullName) - $($Record.Exception.InnerException.Message)"
    }
}

function Resolve-StableIso {
    param([string]$ReleaseBaseUrl, [string]$IsoPattern)
    Write-Verbose "Probing stable release index: $ReleaseBaseUrl/"
    try {
        $page = (Invoke-WebRequest -Uri "$ReleaseBaseUrl/" -ErrorAction Stop).Content
    } catch {
        Write-Warning "Stable release index at $ReleaseBaseUrl not reachable: $($_.Exception.Message)"
        Write-ExceptionDetail $_
        return $null
    }
    $found = [regex]::Matches($page, $IsoPattern)
    if ($found.Count -eq 0) {
        Write-Warning "No ISO matching pattern '$IsoPattern' found at $ReleaseBaseUrl"
        return $null
    }
    $iso = ($found | Sort-Object Value -Descending | Select-Object -First 1).Value
    return [pscustomobject]@{
        IsoFileName = $iso
        SourceUrl   = "$ReleaseBaseUrl/$iso"
        ChecksumUrl = "$ReleaseBaseUrl/SHA256SUMS"
        Variant     = 'stable'
    }
}

function Resolve-DailyIso {
    param([string]$DailyBaseUrl, [string]$IsoFileName)
    $url = "$DailyBaseUrl/$IsoFileName"
    Write-Verbose "HEAD-probing daily ISO: $url"
    try {
        Invoke-WebRequest -Uri $url -Method Head -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Daily ISO at $url not reachable: $($_.Exception.Message)"
        Write-ExceptionDetail $_
        return $null
    }
    return [pscustomobject]@{
        IsoFileName = $IsoFileName
        SourceUrl   = $url
        ChecksumUrl = "$DailyBaseUrl/SHA256SUMS"
        Variant     = 'daily'
    }
}

# Stable amd64 server ISOs live on releases.ubuntu.com; arm64 lives on
# cdimage.ubuntu.com (releases.ubuntu.com is amd64-only). Server dailies
# live under ubuntu-server/<codename>/daily-live/. The codename-less
# ubuntu-server/daily-live/ path is rolling and now serves the next
# codename, so requesting noble-live-server-<arch>.iso there 404s.
if ($cloudArch -eq 'amd64') {
    $stableReleaseUrl = 'https://releases.ubuntu.com/noble'
    $stablePattern    = 'ubuntu-[\d.]+-live-server-amd64\.iso'
    $dailyBaseUrl     = 'https://cdimage.ubuntu.com/ubuntu-server/noble/daily-live/current'
    $dailyIsoFileName = 'noble-live-server-amd64.iso'
} else {
    $stableReleaseUrl = 'https://cdimage.ubuntu.com/releases/noble/release'
    $stablePattern    = 'ubuntu-[\d.]+-live-server-arm64\.iso'
    $dailyBaseUrl     = 'https://cdimage.ubuntu.com/ubuntu-server/noble/daily-live/current'
    $dailyIsoFileName = 'noble-live-server-arm64.iso'
}

if ($daily) {
    Write-Output "Resolving daily build from $dailyBaseUrl ..."
    $resolved = Resolve-DailyIso -DailyBaseUrl $dailyBaseUrl -IsoFileName $dailyIsoFileName
    if (-not $resolved) {
        Write-Warning "Daily build unavailable; falling back to stable build at $stableReleaseUrl ..."
        $resolved = Resolve-StableIso -ReleaseBaseUrl $stableReleaseUrl -IsoPattern $stablePattern
    }
} else {
    Write-Output "Resolving stable build from $stableReleaseUrl ..."
    $resolved = Resolve-StableIso -ReleaseBaseUrl $stableReleaseUrl -IsoPattern $stablePattern
    if (-not $resolved) {
        Write-Warning "Stable build unavailable; falling back to daily build at $dailyBaseUrl ..."
        $resolved = Resolve-DailyIso -DailyBaseUrl $dailyBaseUrl -IsoFileName $dailyIsoFileName
    }
}

if (-not $resolved) {
    $msg = "Could not resolve a usable Ubuntu live-server $cloudArch ISO. Stable ($stableReleaseUrl) and daily ($dailyBaseUrl) are both unreachable or missing the expected image."
    Write-Error $msg
    exit 1
}

$isoFileName = $resolved.IsoFileName
$sourceUrl   = $resolved.SourceUrl
$checksumUrl = $resolved.ChecksumUrl
Write-Output "Selected $($resolved.Variant) ISO: $isoFileName"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# Skip if URL + Content-Length match the prior run. Same convention as
# host/macos.utm/guest.ubuntu.server/Get-Image.ps1's
# Test-DownloadAlreadyCurrent helper, inlined here -- the helper lives
# in macos.utm's Yuruna.Host.psm1 and the KVM driver hasn't needed it
# anywhere else yet.
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

if (Test-AlreadyCurrent -Url $sourceUrl -File $baseImageFile -Sentinel $baseImageOrigin) {
    Write-Output "Skipping download: $sourceUrl URL and size match prior run for $baseImageFile"
    exit 0
}

$downloadFile = Join-Path $downloadDir 'downloaded.iso'
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $sourceUrl"
Invoke-WebRequest -Uri $sourceUrl -OutFile $downloadFile -ErrorAction Stop
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

# Verify SHA256.
try {
    $sums = (Invoke-WebRequest -Uri $checksumUrl -ErrorAction Stop).Content
    $line = ($sums -split "`n") | Where-Object { $_ -match [regex]::Escape($isoFileName) } | Select-Object -First 1
    if ($line) {
        $expected = ($line -split '\s+')[0]
        $actual   = (Get-FileHash -Path $downloadFile -Algorithm SHA256).Hash
        if ($expected -ine $actual) {
            Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
            Write-Error "Checksum mismatch. Expected $expected, got $actual"
            exit 1
        }
        Write-Output "Checksum verified."
    } else {
        Write-Warning "Checksum line for $isoFileName not in SHA256SUMS; skipping verification."
    }
} catch {
    Write-Warning "Could not download checksum file: $($_.Exception.Message)"
}

$previousFile = Join-Path $downloadDir "$baseImageName.previous.iso"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $downloadFile -Destination $baseImageFile

Set-Content -Path $baseImageOrigin -Value @($isoFileName, $sourceUrl, "$downloadedSize")
Write-Output "Recorded source filename, URL, and byte count to: $baseImageOrigin"
Write-Output "Download complete: $baseImageFile"
