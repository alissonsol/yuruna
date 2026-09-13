<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42f7b3b7-64ca-41c6-96ad-88a15026c482
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
    Downloads the Amazon Linux 2023 image and stages it as a VHDX for
    Hyper-V.

.DESCRIPTION
    AL2023 publishes under cdn.amazonlinux.com keyed by platform. On AMD64
    the `hyperv` platform exposes a zip that packages a native VHDX per
    release. AMD64 is the only architecture that platform is published for,
    so on ARM64 this pulls the `kvm-arm64` qcow2 instead and converts it to
    VHDX locally with qemu-img.

    Either way the artifact is verified against the publisher SHA-256 before
    it is unpacked, and the result is promoted to the same host-standard
    file name under the Hyper-V default VHDX folder
    ((Get-VMHost).VirtualHardDiskPath), so New-VM.ps1 consumes it unchanged.

    Architecture is picked from the host: Hyper-V has no cross-architecture
    emulation, so the host's architecture is also the guest's.
#>

# --- REGION: Log level from environment
# Reuse the caller's log module so an in-process fetch preserves its state.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }

# --- REGION: Platform guard
if (-not $IsWindows) {
    Write-Error "host/windows.hyper-v/guest.amazon.linux.2023/Get-Image.ps1 only runs on Windows Hyper-V."
    exit 1
}

Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    Write-Output "Be careful."
    exit 1
}

# --- REGION: Host architecture
# See https://yuruna.link/42e220c4-0003
# Use native OS architecture even when the current PowerShell process is emulated.
switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64'   { $hostArch = 'amd64'; $platformDir = 'hyperv';    $downloadExtension = 'zip' }
    'Arm64' { $hostArch = 'arm64'; $platformDir = 'kvm-arm64'; $downloadExtension = 'qcow2' }
    default {
        Write-Error "Unsupported processor architecture: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture). A Hyper-V host must be AMD64 or ARM64."
        exit 1
    }
}
Write-Output "Host architecture: $hostArch (Amazon Linux 2023 platform: $platformDir)"

# --- REGION: https://yuruna.link/42dc5bb9-0004
# Conversion succeeds, but the AL2023 ARM64 kernel lacks Hyper-V disk and NIC drivers.
if ($hostArch -eq 'arm64') {
    Write-Warning "Amazon Linux 2023 has no Hyper-V-capable ARM64 image: the KVM qcow2 fetched below converts fine but boots to a dracut device wait, because its aarch64 kernel carries no Hyper-V drivers. Run this guest on host.macos.utm or host.ubuntu.kvm for ARM64 coverage. See docs/host-hyperv.md."
}

# The extension is the only property of a downloaded artifact the staging
# step depends on, so it is also the whole test for "is this the platform
# this run asked for". A pooled copy served under the other platform would
# otherwise reach the unzip-or-convert branch below named as this one.
$expectedArtifactPattern = '\.{0}$' -f [regex]::Escape($downloadExtension)

# --- REGION: Configuration
$sourceUrl = "https://cdn.amazonlinux.com/al2023/os-images/latest/$platformDir/"
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageName = "host.windows.hyper-v.guest.amazon.linux.2023"
$baseImageFile = Join-Path $downloadDir "$baseImageName.vhdx"
$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
$downloadFile = Join-Path $downloadDir "downloaded.$downloadExtension"

Write-Output "Hyper-V default VHDX folder: $downloadDir"
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
    exit 1
}

# --- REGION: Import host modules
# See https://yuruna.link/42e220c4-0003
# Import cache/agent discovery and the shared image sentinel helpers.
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Host.psm1") -Force
# Yuruna.Image.psm1 second, so its module scope never shadows the driver's
# cache-injecting Save-CachedHttpUri. It carries Save-ImageWithChecksum for
# the origin path AND Convert-Qcow2ToVhdx for the ARM64 staging step, which
# the agent path also reaches -- so the import cannot sit inside the
# origin-only branch.
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "modules/Yuruna.Image.psm1") -Force

# --- REGION: https://yuruna.link/42ec97cd-0004
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
        # and no SHA-256: the sentinel records the size of the download, which
        # is the pooled artifact, not the VHDX that staging leaves on disk.
        $agentArgs = @{
            BaseUrl         = $agentBaseUrl
            HostType        = 'windows.hyper-v'
            ImageKey        = 'guest.amazon.linux.2023'
            Arch            = $hostArch
            Variant         = 'stable'
            StagingPath     = $downloadFile
            DeadlineSeconds = 7200
            # The staging step below is chosen by architecture -- unzip a native
            # VHDX, or convert a qcow2 -- so an answer naming the other
            # platform's artifact must not be taken.
            ExpectedFilenamePattern = $expectedArtifactPattern
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
    $artifactLink = ($html.Links | Where-Object { $_.href -match "\.$downloadExtension$" } | Select-Object -First 1).href
    if (-not $artifactLink) {
        Write-Error "No .$downloadExtension listed at $sourceUrl"
        exit 1
    }
    $downloadUrl = $sourceUrl + $artifactLink

    # --- REGION: https://yuruna.link/42ec97cd-0006
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
    # Reject checksum mismatches; a publisher that omits a checksum remains a soft pass.
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    $checksumLink = ($html.Links | Where-Object { $_.href -match "\.$downloadExtension\.sha256$" } | Select-Object -First 1)
    $checksumUrl = if ($checksumLink) { $sourceUrl + $checksumLink.href } else { $null }
    $downloaded = Save-ImageWithChecksum `
        -SourceUrl  $downloadUrl `
        -DestPath   $downloadFile `
        -ChecksumUrl $checksumUrl `
        -ChecksumTargetFileName $artifactLink `
        -OnMismatch 'WarnAndDelete' `
        -Confirm:$false
    if (-not $downloaded) {
        Write-Error "Download failed for $downloadUrl"
        exit 1
    }
}
# Capture the HTTP-download size BEFORE staging; the .vhdx that lands at
# $baseImageFile is the unpacked (AMD64) or converted (ARM64) artifact, not
# the bytes Test-DownloadAlreadyCurrent will compare against on the next run.
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

# --- REGION: Stage the VHDX from the download
# Write to a temp path first so the previous image is only replaced after a
# successful extraction or conversion.
$extractedFile = Join-Path $downloadDir "$baseImageName.downloading.vhdx"
Remove-Item $extractedFile -Force -ErrorAction SilentlyContinue
if ($hostArch -eq 'amd64') {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($downloadFile)
    $entry = $zip.Entries | Where-Object { $_.Name -match "\.vhdx$" }
    if ($entry) {
        $stream = $entry.Open()
        try {
            $outStream = [System.IO.File]::Open($extractedFile, [System.IO.FileMode]::Create)
            try {
                $stream.CopyTo($outStream)
            } finally {
                $outStream.Close()
            }
        } finally {
            $stream.Close()
        }
    } else {
        Write-Error "No .vhdx file found inside the downloaded zip."
        $zip.Dispose()
        exit 1
    }
    $zip.Dispose()
} else {
    # -SizeBytes 0 converts only, leaving the cloud image at its native
    # capacity: New-VM.ps1 grows its own per-VM copy, and a base pre-grown to
    # the largest consumer would force smaller ones to shrink, which Hyper-V
    # refuses while the guest partition still spans the disk.
    Write-Output "Converting the Amazon Linux 2023 ARM64 cloud image to VHDX..."
    if (-not (Convert-Qcow2ToVhdx -SourcePath $downloadFile -DestPath $extractedFile -SizeBytes 0)) {
        Write-Error "Could not convert $downloadFile to VHDX. Install QEMU for Windows (winget install SoftwareFreedomConservancy.QEMU) if qemu-img is missing."
        Remove-Item $extractedFile -Force -ErrorAction SilentlyContinue
        exit 1
    }
}

# --- REGION: Preserve previous and finalize
$previousFile = Join-Path $downloadDir "$baseImageName.previous.vhdx"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $extractedFile -Destination $baseImageFile

# --- REGION: https://yuruna.link/42ec97cd-0006
# Only Write-ImageSentinel emits the 4-line shape the reader matches. On the
# agent path the Last-Modified comes from the agent's record of the origin
# response, so the origin the agent path exists to spare is not re-probed here.
if ($agentServed) {
    Write-ImageSentinel -SourceUrl $downloadUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -LastModified $agentLastModified -Confirm:$false
} else {
    Write-ImageSentinel -SourceUrl $downloadUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -Confirm:$false
}
Write-Output "Recorded source filename, URL, byte count, and Last-Modified to: $baseImageOrigin"

Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue

Write-Output "Download complete: $baseImageFile"

# --- REGION: Completion
# Clear a native discovery probe's stale exit code, including on cache hits.
exit 0
