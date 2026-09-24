<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42f8008d-9acf-4ba5-8a9f-c29d843ce6a5
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

# --- REGION: Log level from environment
# Reuse the caller's log module so an in-process fetch preserves its state.
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }

# --- REGION: Platform guard
if (-not $IsMacOS) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_d0f5ad55eaf0f55a')
    exit 1
}

# --- REGION: Host architecture
# The supported Apple Silicon host consumes Amazon's native ARM64 KVM image.
$hostArch = 'arm64'
$platformDir = 'kvm-arm64'

# --- REGION: Configuration
$sourceUrl     = "https://cdn.amazonlinux.com/al2023/os-images/latest/$platformDir/"
$downloadDir   = "$HOME/yuruna/image/amazon.linux.2023"
$baseImageName = "host.macos.utm.guest.amazon.linux.2023"
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"
$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
$downloadFile = Join-Path $downloadDir 'downloaded.qcow2'

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# --- REGION: Import host modules
# See https://yuruna.link/42e220c4-0003
# Import cache/agent discovery and the shared image sentinel helpers.
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Host.psm1") -Force

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
        # and no SHA-256: re-hashing a multi-GB image every run would cost more
        # than the transfer it can save.
        $agentArgs = @{
            BaseUrl         = $agentBaseUrl
            HostType        = 'macos.utm'
            ImageKey        = 'guest.amazon.linux.2023'
            Arch            = $hostArch
            Variant         = 'stable'
            StagingPath     = $downloadFile
            DeadlineSeconds = 7200
            # UTM boots the native qcow2 directly; anything else would be promoted
            # to the base image as-is and fail at first boot.
            ExpectedFilenamePattern = '\.qcow2$'
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
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_57234ab9582f912d' -Arguments @{ agentBaseUrl = "$agentBaseUrl"; message = "$($_.Exception.Message)" })
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
            Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_1050eecd3dbb16e4' -Arguments @{ agentBaseUrl = "$agentBaseUrl"; filename = "$($agentResult.filename)"; downloadFile = "$downloadFile" })
        } elseif ($agentResult) {
            $detail = if ($agentResult.error) { ": $($agentResult.error)" } else { '' }
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_eacd62147f05f2a6' -Arguments @{ agentBaseUrl = "$agentBaseUrl"; outcome = "$($agentResult.outcome)"; detail = "$detail" })
        }
    }
}

if (-not $agentServed) {
    # --- REGION: Find the file to download
    $html = Invoke-WebRequest -Uri $sourceUrl -ErrorAction Stop
    $qcow2Link = ($html.Links | Where-Object { $_.href -match '\.qcow2$' } | Select-Object -First 1).href
    if (-not $qcow2Link) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_533d1ebbe03304b9' -Arguments @{ sourceUrl = "$sourceUrl" })
        exit 1
    }
    $downloadUrl = $sourceUrl + $qcow2Link

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
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    # Reject checksum mismatches; a publisher that omits a checksum remains a soft pass.
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
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_877d321158118deb' -Arguments @{ downloadUrl = "$downloadUrl" })
        exit 1
    }
}
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

# --- REGION: Preserve previous and finalize
$previousFile = Join-Path $downloadDir "$baseImageName.previous.qcow2"
Remove-Item -LiteralPath $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $baseImageFile) {
    Move-Item -LiteralPath $baseImageFile -Destination $previousFile
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_05027812540d620c' -Arguments @{ previousFile = "$previousFile" })
}
Move-Item -LiteralPath $downloadFile -Destination $baseImageFile

# --- REGION: https://yuruna.link/42ec97cd-0006
# Only Write-ImageSentinel emits the 4-line shape the reader matches. On the
# agent path the Last-Modified comes from the agent's record of the origin
# response, so the origin the agent path exists to spare is not re-probed here.
if ($agentServed) {
    Write-ImageSentinel -SourceUrl $downloadUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -LastModified $agentLastModified -Confirm:$false
} else {
    Write-ImageSentinel -SourceUrl $downloadUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -Confirm:$false
}
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_1dec325a446dd0f7' -Arguments @{ baseImageOrigin = "$baseImageOrigin" })

Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_347faa31fb049e6d' -Arguments @{ baseImageFile = "$baseImageFile" })

# --- REGION: Completion
# Clear a native discovery probe's stale exit code, including on cache hits.
exit 0
