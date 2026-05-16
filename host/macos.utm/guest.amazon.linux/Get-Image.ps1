<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42d8e9f0-a1b2-4c34-d567-8e9f0a1b2c34
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

# === Configuration ===
$sourceUrl = "https://cdn.amazonlinux.com/al2023/os-images/latest/kvm-arm64/"
$downloadDir = "$HOME/yuruna/image/amazon.linux"
$baseImageName = "host.macos.utm.guest.amazon.linux"
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

$html = Invoke-WebRequest -Uri $sourceUrl
$qcow2Link = ($html.Links | Where-Object { $_.href -match "\.qcow2$" })[0].href
$downloadUrl = $sourceUrl + $qcow2Link

# Skip-if-same-source guard. Test-DownloadAlreadyCurrent (Yuruna.Host.psm1)
# returns $true only when $baseImageFile is on disk, the sentinel records
# the same URL we just resolved, and a HEAD probe's Content-Length matches
# the recorded byte count. The only way to force a re-download is to
# delete or rename $baseImageFile.
$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Host.psm1") -Force
if (Test-DownloadAlreadyCurrent -SourceUrl $downloadUrl -BaseImageFile $baseImageFile -OriginFile $baseImageOrigin) {
    $msg = "Skipping download: $downloadUrl URL and expected size match the prior run for $baseImageFile. To force a re-download, delete or rename: $baseImageFile"
    Write-Information $msg -InformationAction Continue
    Write-Output $msg
    exit 0
}

# === Retrieve and process the files ===
$downloadFile = Join-Path $downloadDir "downloaded.qcow2"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $downloadUrl to $downloadFile"
# Save-CachedHttpUri (Yuruna.Host.psm1) routes through the squid cache
# transparently: HTTP origins go through :3128; HTTPS origins go
# through :3129 with per-process trust of the freshly-fetched yuruna
# CA (no OS trust-store mutation); when no cache is reachable it
# falls through to a direct Invoke-WebRequest. Throws on failure.
try {
    Save-CachedHttpUri -Uri $downloadUrl -OutFile $downloadFile
} catch {
    Write-Error "Download failed: $($_.Exception.Message)"
    exit 1
}
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

# SHA256 integrity check.
$checksumLink = ($html.Links | Where-Object { $_.href -match "\.qcow2\.sha256$" })
if ($checksumLink) {
    $checksumUrl = $sourceUrl + $checksumLink[0].href
    Write-Output "Verifying download integrity..."
    $checksumContent = (Invoke-WebRequest -Uri $checksumUrl).Content
    $expectedHash = ($checksumContent -split '\s+')[0]
    $actualHash = (Get-FileHash -Path $downloadFile -Algorithm SHA256).Hash
    if ($expectedHash -ine $actualHash) {
        Write-Error "Checksum verification failed. Expected: $expectedHash, Got: $actualHash"
        Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
        exit 1
    }
    Write-Output "Checksum verified successfully."
} else {
    Write-Warning "No checksum file found. Skipping integrity verification."
}

# === Name the file as per naming convention ===
$previousFile = Join-Path $downloadDir "$baseImageName.previous.qcow2"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $downloadFile -Destination $baseImageFile

Set-Content -Path $baseImageOrigin -Value @($qcow2Link, $downloadUrl, "$downloadedSize")
Write-Output "Recorded source filename, URL, and byte count to: $baseImageOrigin"

Write-Output "Download complete: $baseImageFile"
