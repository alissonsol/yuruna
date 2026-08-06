<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42d8e9f0-a1b2-4c34-d567-8e9f0a1b2c34
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
    Downloads the Amazon Linux 2023 KVM cloud image (qcow2) for UTM.

.DESCRIPTION
    AL2023 ships native qcow2 images under cdn.amazonlinux.com keyed by
    platform; UTM on Apple Silicon uses kvm-arm64. The directory listing
    on the HTTPS endpoint exposes a single qcow2 plus a matching sha256
    sidecar per release; this script picks both, verifies, and stages the
    file under ~/yuruna/image/amazon.linux.2023/.
#>

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

# --- REGION: Configuration
$sourceUrl = "https://cdn.amazonlinux.com/al2023/os-images/latest/kvm-arm64/"
$downloadDir = "$HOME/yuruna/image/amazon.linux.2023"
$baseImageName = "host.macos.utm.guest.amazon.linux.2023"
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"
$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
$downloadFile = Join-Path $downloadDir "downloaded.qcow2"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# The host driver brings the skip-if-same-source guard + sentinel writer, the
# cache-aware Save-CachedHttpUri wrapper, and the download-agent client.
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
            HostType        = 'macos.utm'
            ImageKey        = 'guest.amazon.linux.2023'
            Arch            = 'arm64'
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
    $html = Invoke-WebRequest -Uri $sourceUrl
    $qcow2Link = ($html.Links | Where-Object { $_.href -match "\.qcow2$" })[0].href
    $downloadUrl = $sourceUrl + $qcow2Link

    # --- REGION: https://yuruna.link/guest-image-setup#skip-if-same-source-guard
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
    # Save-ImageWithChecksum (Yuruna.Image.psm1) routes the download
    # through Save-CachedHttpUri when available + verifies SHA-256 against
    # the publisher checksum. AL2023 publishes `<basename>.qcow2.sha256`
    # next to each qcow2; the helper parses it transparently. A genuine
    # mismatch deletes the tampered file and fails the run (WarnAndDelete);
    # a MISSING upstream checksum stays a soft pass (publisher lag).
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "modules/Yuruna.Image.psm1") -Force
    $checksumLink = ($html.Links | Where-Object { $_.href -match "\.qcow2\.sha256$" })
    $checksumUrl = if ($checksumLink) { $sourceUrl + $checksumLink[0].href } else { $null }
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
if (Test-Path $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $downloadFile -Destination $baseImageFile

# --- REGION: https://yuruna.link/guest-image-setup#skip-if-same-source-guard
# Only Write-ImageSentinel emits the 4-line shape the reader matches. On the
# agent path the Last-Modified comes from the agent's record of the origin
# response, so the origin the agent path exists to spare is not re-probed here.
if ($agentServed) {
    Write-ImageSentinel -SourceUrl $downloadUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -LastModified $agentLastModified -Confirm:$false
} else {
    Write-ImageSentinel -SourceUrl $downloadUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -Confirm:$false
}
Write-Output "Recorded source filename, URL, byte count, and Last-Modified to: $baseImageOrigin"

Write-Output "Download complete: $baseImageFile"
