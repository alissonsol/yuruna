<#PSScriptInfo
.VERSION 2026.05.22
.GUID 4225d6e7-f8a9-4b02-c456-7d8e9f0a1b25
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
    Downloads the Ubuntu Server 26.04 live-server amd64 ISO for autoinstall.

.DESCRIPTION
    Pulls the Ubuntu Server live ISO. Its cdrom ships a full kernel
    meta-package (`linux-generic`) and a network-configured
    `ubuntu.sources`, so curtin's install_kernel step always succeeds.
    First boot lands in a text-mode login.

.PARAMETER daily
    If set, pulls the rolling daily ISO instead of the latest stable point
    release. Useful for catching regressions before a yuruna release commits
    to a specific point release.
#>

param(
    [switch]$daily
)

# Inform and check for elevation
Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    Write-Output "Be careful."
    exit 1
}

# === Configuration ===
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageName = "host.windows.hyper-v.guest.ubuntu.server.26"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"

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

function Write-ExceptionDetail {
    param($Record)
    Write-Verbose "Exception type: $($Record.Exception.GetType().FullName)"
    if ($Record.Exception.InnerException) {
        Write-Verbose "Inner: $($Record.Exception.InnerException.GetType().FullName) - $($Record.Exception.InnerException.Message)"
    }
    if ($Record.Exception.Response) {
        Write-Verbose "HTTP status: $([int]$Record.Exception.Response.StatusCode) $($Record.Exception.Response.StatusCode)"
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

function Write-ProxyEnvDiagnostic {
    param([string[]]$ProbeUrls = @())
    Write-Output "Proxy-related environment variables:"
    foreach ($v in 'http_proxy','https_proxy','HTTP_PROXY','HTTPS_PROXY','no_proxy','NO_PROXY','all_proxy','ALL_PROXY') {
        $val = [System.Environment]::GetEnvironmentVariable($v)
        Write-Output ("  " + $v + '=' + ($(if ($val) { $val } else { '(not set)' })))
    }
    Write-Output "System-level proxy configuration:"
    if ($IsMacOS) {
        try {
            $sc = (& scutil --proxy 2>&1) -join "`n"
            Write-Output "  scutil --proxy:"
            foreach ($line in ($sc -split "`n")) { if ($line) { Write-Output ("    " + $line.TrimEnd()) } }
        } catch {
            Write-Output "  scutil --proxy failed: $($_.Exception.Message)"
        }
    } elseif ($IsWindows) {
        try {
            $nw = (& netsh winhttp show proxy 2>&1) -join "`n"
            Write-Output "  netsh winhttp show proxy:"
            foreach ($line in ($nw -split "`n")) { if ($line) { Write-Output ("    " + $line.TrimEnd()) } }
        } catch {
            Write-Output "  netsh winhttp failed: $($_.Exception.Message)"
        }
    } else {
        Write-Output "  (no platform-specific system-proxy probe on this OS)"
    }
    if ($ProbeUrls.Count -gt 0) {
        Write-Output ".NET DefaultWebProxy resolution (what Invoke-WebRequest actually uses):"
        try {
            Write-Output ("  Type: " + [System.Net.WebRequest]::DefaultWebProxy.GetType().FullName)
        } catch {
            Write-Output "  (DefaultWebProxy unavailable: $($_.Exception.Message))"
        }
        foreach ($u in $ProbeUrls) {
            try {
                $uri = [System.Uri]::new($u)
                $resolved = [System.Net.WebRequest]::DefaultWebProxy.GetProxy($uri)
                $bypassed = [System.Net.WebRequest]::DefaultWebProxy.IsBypassed($uri)
                Write-Output ("  GetProxy('$u') = $resolved (bypassed=$bypassed)")
            } catch {
                Write-Output ("  GetProxy('$u') failed: $($_.Exception.Message)")
            }
        }
    }
}

# Server dailies live under ubuntu-server/<codename>/daily-live/. The
# codename-less ubuntu-server/daily-live/ path is rolling and serves
# whichever codename is currently in development, so requesting
# resolute-live-server-amd64.iso there can 404 once it rolls past
# resolute. Pin the codename in the URL to stay aligned.
$stableReleaseUrl = 'https://releases.ubuntu.com/resolute'
$stablePattern    = 'ubuntu-[\d.]+-live-server-amd64\.iso'
$dailyBaseUrl     = 'https://cdimage.ubuntu.com/ubuntu-server/resolute/daily-live/current'
$dailyIsoFileName = 'resolute-live-server-amd64.iso'

# NOTE: pass -daily if subiquity's curtin extract step page-faults with
# `ovl_iterate_merged` / `BUG: unable to handle page fault`. Pre-release
# 26.04 kernels (e.g. linux 7.0.0-14-generic) tripped this overlayfs oops
# during rsync over a 3-deep overlay stack; daily ISOs pick up upstream
# kernel fixes weeks before the next point release does.
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
    $msg = "Could not resolve a usable Ubuntu live-server amd64 ISO. Stable ($stableReleaseUrl) and daily ($dailyBaseUrl) are both unreachable or missing the expected image."
    Write-Output $msg
    Write-Information $msg -InformationAction Continue
    Write-ProxyEnvDiagnostic -ProbeUrls @("$stableReleaseUrl/", "$dailyBaseUrl/$dailyIsoFileName")
    Write-Error $msg
    exit 1
}

$isoFileName = $resolved.IsoFileName
$sourceUrl   = $resolved.SourceUrl
$checksumUrl = $resolved.ChecksumUrl
Write-Output "Selected $($resolved.Variant) ISO: $isoFileName"

Write-Output "Hyper-V default VHDX folder: $downloadDir"
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
    exit 1
}

# Skip-if-same-source guard. Test-DownloadAlreadyCurrent (Yuruna.Host.psm1)
# returns $true only when $baseImageFile is on disk, the sentinel records
# the same URL we just resolved, and a HEAD probe's Content-Length matches
# the recorded byte count. The only way to force a re-download is to
# delete or rename $baseImageFile.
$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Host.psm1") -Force
if (Test-DownloadAlreadyCurrent -SourceUrl $sourceUrl -BaseImageFile $baseImageFile -OriginFile $baseImageOrigin) {
    $msg = "Skipping download: $sourceUrl URL and expected size match the prior run for $baseImageFile. To force a re-download, delete or rename: $baseImageFile"
    Write-Information $msg -InformationAction Continue
    Write-Output $msg
    exit 0
}

# === Retrieve and process the files ===
$downloadFile = Join-Path $downloadDir "downloaded.iso"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $sourceUrl to $downloadFile"
# Save-CachedHttpUri (Yuruna.Host.psm1) routes through the squid cache
# transparently: HTTP origins go through :3128; HTTPS origins go
# through :3129 with per-process trust of the freshly-fetched yuruna
# CA (no OS trust-store mutation); when no cache is reachable it
# falls through to a direct Invoke-WebRequest. Throws on failure.
try {
    Save-CachedHttpUri -Uri $sourceUrl -OutFile $downloadFile
} catch {
    Write-Error "Download failed: $($_.Exception.Message)"
    exit 1
}
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

# Verify download integrity using SHA256 checksum
Write-Output "Verifying download integrity..."
try {
    $checksumContent = (Invoke-WebRequest -Uri $checksumUrl).Content
    $checksumLine = ($checksumContent -split "`n") | Where-Object { $_ -match [regex]::Escape($isoFileName) }
    if ($checksumLine) {
        $expectedHash = ($checksumLine -split '\s+')[0]
        $actualHash = (Get-FileHash -Path $downloadFile -Algorithm SHA256).Hash
        if ($expectedHash -ine $actualHash) {
            Write-Error "Checksum verification failed. Expected: $expectedHash, Got: $actualHash"
            Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
            exit 1
        }
        Write-Output "Checksum verified successfully."
    } else {
        Write-Warning "Could not find checksum for $isoFileName. Skipping verification."
    }
} catch {
    Write-Warning "Could not download checksum file. Skipping integrity verification."
}

# === Name the file as per naming convention ===
$previousFile = Join-Path $downloadDir "$baseImageName.previous.iso"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $downloadFile -Destination $baseImageFile

Set-Content -Path $baseImageOrigin -Value @($isoFileName, $sourceUrl, "$downloadedSize")
Write-Output "Recorded source filename, URL, and byte count to: $baseImageOrigin"

Write-Output "Download complete: $baseImageFile"
