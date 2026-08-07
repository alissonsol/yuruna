<#PSScriptInfo
.VERSION 2026.08.07
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

# --- REGION: Configuration
$sourceUrl     = "https://cdn.amazonlinux.com/al2023/os-images/latest/$platDir/"
$downloadDir   = "$HOME/yuruna/image/amazon.linux.2023"
$baseImageName = "host.ubuntu.kvm.guest.amazon.linux.2023"
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"
$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
$downloadFile = Join-Path $downloadDir 'downloaded.qcow2'

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# The KVM host driver brings the skip-if-same-source guard + sentinel writer
# (Test-DownloadAlreadyCurrent / Write-ImageSentinel, the 4-line filename + URL +
# size + Last-Modified format shared across every KVM guest, with the
# noble->resolute URL-bump guard), the cache-aware Save-CachedHttpUri wrapper
# that routes this download through the squid cache, AND the download-agent
# client the block below feature-detects.
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Host.psm1") -Force

# --- REGION: https://yuruna.link/guest-image-setup#agent-first-image-downloads
# Ask the download agent before the origin listing is even read: when it
# confirms the local copy IS the current artifact there is nothing to scrape,
# HEAD-probe or transfer. Both the client module and a healthy agent are
# feature-detected, so with no agent -- or an agent that is down, has no pool,
# or errors mid-request -- everything below runs exactly as it always has.
$agentServed = $false
$agentLastModified = ''
if ((Get-Command -Name Resolve-DownloadAgentEndpoint -ErrorAction SilentlyContinue) -and
    (Get-Command -Name Request-DownloadAgentImage -ErrorAction SilentlyContinue)) {
    $agentBaseUrl = ''
    try { $agentBaseUrl = [string](Resolve-DownloadAgentEndpoint) } catch { $agentBaseUrl = '' }
    if (-not $agentBaseUrl) {
        Write-Verbose "No download agent reachable; using the origin path."
    } else {
        # Fingerprint the local copy with the sentinel's filename + byte count
        # and no SHA-256: re-hashing a multi-GB image every run would cost more
        # than the transfer it can save.
        $agentArgs = @{
            BaseUrl         = $agentBaseUrl
            HostType        = 'ubuntu.kvm'
            ImageKey        = 'guest.amazon.linux.2023'
            Arch            = $(if ($platDir -eq 'kvm-arm64') { 'arm64' } else { 'amd64' })
            Variant         = 'stable'
            StagingPath     = $downloadFile
            DeadlineSeconds = 7200
        }
        if ((Test-Path -LiteralPath $baseImageFile) -and (Test-Path -LiteralPath $baseImageOrigin)) {
            $sentinelLines = @(Get-Content -LiteralPath $baseImageOrigin -ErrorAction SilentlyContinue)
            $sentinelBytes = 0L
            if ($sentinelLines.Count -ge 3 -and [int64]::TryParse($sentinelLines[2].Trim(), [ref]$sentinelBytes) -and $sentinelBytes -gt 0) {
                $agentArgs['LocalFilename']  = $sentinelLines[0].Trim()
                $agentArgs['LocalByteCount'] = $sentinelBytes
            }
        }
        $agentResult = $null
        try {
            Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
            $agentResult = Request-DownloadAgentImage @agentArgs
        } catch {
            Write-Warning "Download agent at $agentBaseUrl failed ($($_.Exception.Message)); falling back to the origin download path."
            $agentResult = $null
        }
        if ($agentResult -and $agentResult.outcome -eq 'skipped') {
            $msg = @(
                "Skipping download: the download agent at $agentBaseUrl confirms $baseImageFile is the current guest.amazon.linux.2023 artifact."
                "  Sentinel: $baseImageOrigin"
                "  To force a re-download, delete or rename: $baseImageFile"
            ) -join [Environment]::NewLine
            Write-Information $msg -InformationAction Continue
            Write-Output $msg
            exit 0
        } elseif ($agentResult -and $agentResult.outcome -eq 'downloaded') {
            $agentServed = $true
            $downloadUrl = [string]$agentResult.sourceUrl
            $agentLastModified = [string]$agentResult.lastModified
            Write-Output "Download agent at $agentBaseUrl served verified $($agentResult.filename) to $downloadFile"
        } elseif ($agentResult) {
            $detail = if ($agentResult.error) { ": $($agentResult.error)" } else { '' }
            Write-Warning "Download agent at $agentBaseUrl answered '$($agentResult.outcome)'$detail; falling back to the origin download path."
        }
    }
}

if (-not $agentServed) {
    # --- REGION: Find the file to download
    $html = Invoke-WebRequest -Uri $sourceUrl -ErrorAction Stop
    $qcow2Link = ($html.Links | Where-Object { $_.href -match '\.qcow2$' } | Select-Object -First 1).href
    if (-not $qcow2Link) {
        Write-Error "No .qcow2 listed at $sourceUrl"
        exit 1
    }
    $downloadUrl = $sourceUrl + $qcow2Link

    if (Test-DownloadAlreadyCurrent -SourceUrl $downloadUrl -BaseImageFile $baseImageFile -OriginFile $baseImageOrigin) {
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

    # --- REGION: Retrieve and process the files
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    # Save-ImageWithChecksum (Yuruna.Image.psm1) verifies SHA-256 against
    # the publisher checksum (a genuine mismatch deletes the file and fails;
    # a missing upstream checksum is a soft pass). It feature-detects the
    # driver's Save-CachedHttpUri wrapper and routes the fetch through the
    # squid cache when one is reachable, else downloads direct.
    Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "modules/Yuruna.Image.psm1") -Force
    $checksumLink = ($html.Links | Where-Object { $_.href -match '\.qcow2\.sha256$' } | Select-Object -First 1)
    $checksumUrl = if ($checksumLink) { $sourceUrl + $checksumLink.href } else { $null }
    $downloaded = Save-ImageWithChecksum `
        -SourceUrl  $downloadUrl `
        -DestPath   $downloadFile `
        -ChecksumUrl $checksumUrl `
        -ChecksumTargetFileName $qcow2Link `
        -OnMismatch 'WarnAndDelete' `
        -Confirm:$false
    if (-not $downloaded) {
        Write-Error "Download failed for $downloadUrl"
        exit 1
    }
}
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

# --- REGION: Preserve previous and finalize
$previousFile = Join-Path $downloadDir "$baseImageName.previous.qcow2"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $downloadFile -Destination $baseImageFile

# On the agent path the Last-Modified comes from the agent's record of the
# origin response, so the origin the agent path exists to spare is not
# re-probed here.
if ($agentServed) {
    Write-ImageSentinel -SourceUrl $downloadUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -LastModified $agentLastModified -Confirm:$false
} else {
    Write-ImageSentinel -SourceUrl $downloadUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -Confirm:$false
}
Write-Output "Recorded 4-line sentinel (filename, URL, byte count, Last-Modified) to: $baseImageOrigin"
Write-Output "Download complete: $baseImageFile"
