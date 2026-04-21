<#PSScriptInfo
.VERSION 0.1
.GUID 42a3b4c5-d6e7-4f89-a012-3b4c5d6e7f89
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

param(
    [switch]$daily
)

# Honor debug/verbose flags propagated by Invoke-TestRunner.ps1 via env vars.
if ($env:YURUNA_DEBUG -eq '1')   { $DebugPreference   = 'Continue' }
if ($env:YURUNA_VERBOSE -eq '1') { $VerbosePreference = 'Continue' }

# === Configuration ===
$downloadDir = "$HOME/virtual/ubuntu.env"
$baseImageName = "host.macos.utm.guest.ubuntu.desktop"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"

function Write-ExceptionDetails {
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
        Write-ExceptionDetails $_
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
        Write-ExceptionDetails $_
        return $null
    }
    return [pscustomobject]@{
        IsoFileName = $IsoFileName
        SourceUrl   = $url
        ChecksumUrl = "$DailyBaseUrl/SHA256SUMS"
        Variant     = 'daily'
    }
}

function Write-ProxyEnvDiagnostics {
    Write-Output "Proxy-related environment variables:"
    foreach ($v in 'http_proxy','https_proxy','HTTP_PROXY','HTTPS_PROXY','no_proxy','NO_PROXY','all_proxy','ALL_PROXY') {
        $val = [System.Environment]::GetEnvironmentVariable($v)
        Write-Output ("  " + $v + '=' + ($(if ($val) { $val } else { '(not set)' })))
    }
}

$stableReleaseUrl = 'https://cdimage.ubuntu.com/releases/noble/release'
$stablePattern    = 'ubuntu-[\d.]+-desktop-arm64\.iso'
$dailyBaseUrl     = 'https://cdimage.ubuntu.com/noble/daily-live/current'
$dailyIsoFileName = 'noble-desktop-arm64.iso'

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
    $msg = "Could not resolve a usable Ubuntu desktop arm64 ISO. Stable ($stableReleaseUrl) and daily ($dailyBaseUrl) are both unreachable or missing the expected image."
    Write-Output $msg
    Write-Information $msg -InformationAction Continue
    Write-ProxyEnvDiagnostics
    Write-Error $msg
    exit 1
}

$isoFileName = $resolved.IsoFileName
$sourceUrl   = $resolved.SourceUrl
$checksumUrl = $resolved.ChecksumUrl
Write-Output "Selected $($resolved.Variant) ISO: $isoFileName"

# === Find the file to download ===
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# === Retrieve and process the files ===
$downloadFile = Join-Path $downloadDir "downloaded.iso"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $sourceUrl to $downloadFile"
& curl -L --progress-bar -o $downloadFile $sourceUrl
if ($LASTEXITCODE -ne 0) { Write-Error "Download failed (curl exit code $LASTEXITCODE)"; exit 1 }

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

$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
Set-Content -Path $baseImageOrigin -Value @($isoFileName, $sourceUrl)
Write-Output "Recorded source filename and URL to: $baseImageOrigin"

Write-Output "Download complete: $baseImageFile"
