<#PSScriptInfo
.VERSION 2026.07.03
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

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

# === Configuration ===
$sourceUrl = "https://cdn.amazonlinux.com/al2023/os-images/latest/kvm-arm64/"
$downloadDir = "$HOME/yuruna/image/amazon.linux.2023"
$baseImageName = "host.macos.utm.guest.amazon.linux.2023"
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
# Save-ImageWithChecksum (Yuruna.Image.psm1) routes the download
# through Save-CachedHttpUri when available + verifies SHA-256 against
# the publisher checksum. AL2023 publishes `<basename>.qcow2.sha256`
# next to each qcow2; the helper parses it transparently. A genuine
# mismatch deletes the tampered file and fails the run (WarnAndDelete);
# a MISSING upstream checksum stays a soft pass (publisher lag).
$downloadFile = Join-Path $downloadDir "downloaded.qcow2"
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
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

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
