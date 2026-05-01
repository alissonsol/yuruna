<#PSScriptInfo
.VERSION 0.1
.GUID 42c7d8e9-f0a1-4b23-c456-7d8e9f0a1b23
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

# Inform and check for elevation
Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
	Write-Output "Please run this script as Administrator."
	Write-Output "Be careful."
	exit 1
}

# === Configuration ===
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageName = "host.windows.hyper-v.guest.ubuntu.desktop"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"

# Honor debug/verbose flags propagated by Invoke-TestRunner.ps1 via env vars.
if ($env:YURUNA_DEBUG -eq '1')   { $DebugPreference   = 'Continue' }
if ($env:YURUNA_VERBOSE -eq '1') { $VerbosePreference = 'Continue' }
# Silence Write-Progress under the test runner (see sibling ubuntu.server comment).
if ($env:YURUNA_DEBUG -or $env:YURUNA_VERBOSE) { $ProgressPreference = 'SilentlyContinue' }

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

$stableReleaseUrl = 'https://releases.ubuntu.com/noble'
$stablePattern    = 'ubuntu-[\d.]+-desktop-amd64\.iso'
$dailyBaseUrl     = 'https://cdimage.ubuntu.com/noble/daily-live/current'
$dailyIsoFileName = 'noble-desktop-amd64.iso'

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
    $msg = "Could not resolve a usable Ubuntu desktop amd64 ISO. Stable ($stableReleaseUrl) and daily ($dailyBaseUrl) are both unreachable or missing the expected image."
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

# === Retrieve and process the files ===
# Route HTTP downloads through the squid cache when one is reachable.
# Get-CacheProxyForHostDownload (VM.common.psm1) returns $null for
# HTTPS URLs (squid :3128 can't cache CONNECT-tunneled traffic) and
# when no listener answers — so this is a no-op until an HTTP origin
# or :3129 SSL-bump support is wired in.
$iwrCommon = @{}
$cacheProxy = Get-CacheProxyForHostDownload -Uri $sourceUrl
if ($cacheProxy) {
    $iwrCommon['Proxy'] = $cacheProxy
    Write-Output "Routing download through squid cache: $cacheProxy"
}
$downloadFile = Join-Path $downloadDir "downloaded.iso"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $sourceUrl to $downloadFile"
try {
    Invoke-WebRequest -Uri $sourceUrl -OutFile $downloadFile -ErrorAction Stop @iwrCommon
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
