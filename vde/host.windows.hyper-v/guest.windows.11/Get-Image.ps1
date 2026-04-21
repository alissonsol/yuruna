<#PSScriptInfo
.VERSION 0.1
.GUID 42a8b3c4-d5e6-4f78-9a0b-1c2d3e4f5a6b
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

# Honor debug/verbose flags propagated by Invoke-TestRunner.ps1 via env vars.
if ($env:YURUNA_DEBUG -eq '1')   { $DebugPreference   = 'Continue' }
if ($env:YURUNA_VERBOSE -eq '1') { $VerbosePreference = 'Continue' }
# Silence Write-Progress under the test runner.
if ($env:YURUNA_DEBUG -or $env:YURUNA_VERBOSE) { $ProgressPreference = 'SilentlyContinue' }

# === Configuration (change these to customize the download) ===
$baseImageName      = "host.windows.hyper-v.guest.windows.11"
$defaultDownloadDir = "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks"

# Fido settings (change these to download a different edition/language)
$fidoUrl        = "https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1"
$languageFilter = "English"

# Manual download fallback
$downloadPageUrl = "https://www.microsoft.com/en-us/software-download/windows11"

function Show-ManualDownloadInstruction {
    param([string]$TargetPath, [string]$TargetDir)
    Write-Output ""
    Write-Output "--- Manual download required ---"
    Write-Output ""
    Write-Output "  Please download the Windows 11 ISO manually:"
    Write-Output ""
    Write-Output "    1. Open: $downloadPageUrl"
    Write-Output "    2. Select 'Windows 11 (multi-edition ISO for x64 devices)'"
    Write-Output "    3. Click Confirm"
    Write-Output "    4. Select 'English' as the language"
    Write-Output "    5. Click Confirm"
    Write-Output "    6. Click the '64-bit Download' button"
    Write-Output "    7. Save the ISO file as: $TargetPath"
    Write-Output "       Or save any Win11*.iso file to: $TargetDir"
    Write-Output ""
    Write-Output "  Then run this script again to continue."
}

Write-Output ""
Write-Output "=== Windows 11 ISO ==="

# --- Short-circuit #1: default-path existence check (no admin needed) -------
# Hyper-V's default VHD location is predictable, so check there FIRST
# without loading the Hyper-V module or requiring elevation. Most hosts
# keep the default; when it's been relocated we re-check the configured
# path below after elevation clears Get-VMHost.
$defaultBaseFile = Join-Path $defaultDownloadDir "$baseImageName.iso"
if (Test-Path -LiteralPath $defaultBaseFile) {
    Write-Output "Skipping Windows download since ISO for this host is already present"
    Write-Output "  File: $defaultBaseFile"
    exit 0
}

# --- Elevation check --------------------------------------------------------
# Get-VMHost, BITS, and writing under ProgramData all need admin. When we
# don't have it, the only way forward is a manual download — print the
# fallback instructions instead of a terse "please run as admin" so the
# operator sees the same guidance whether called directly or from
# Invoke-TestRunner (which runs the script non-elevated and forwards its
# exit code up).
Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Not elevated — cannot query Hyper-V or write to $defaultDownloadDir."
    Show-ManualDownloadInstruction -TargetPath $defaultBaseFile -TargetDir $defaultDownloadDir
    exit 1
}

# --- Resolve the configured VHD folder --------------------------------------
try {
    $downloadDir = (Get-VMHost -ErrorAction Stop).VirtualHardDiskPath
} catch {
    Write-Warning "Get-VMHost failed ($($_.Exception.Message)); falling back to default path."
    $downloadDir = $defaultDownloadDir
}
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"

Write-Output "Hyper-V default VHDX folder: $downloadDir"
if (!(Test-Path -Path $downloadDir)) {
    Write-Warning "The Hyper-V default VHDX folder does not exist: $downloadDir"
    Show-ManualDownloadInstruction -TargetPath $baseImageFile -TargetDir $downloadDir
    exit 1
}

# --- Short-circuit #2: configured-path existence check ----------------------
# Re-check under the Hyper-V-configured VHD path when it differs from the
# default (we already covered the default above). Cheap, and catches the
# "custom VHD path" case without another download.
if ($downloadDir -ne $defaultDownloadDir -and (Test-Path -LiteralPath $baseImageFile)) {
    Write-Output "Skipping Windows download since ISO for this host is already present"
    Write-Output "  File: $baseImageFile"
    exit 0
}

# Check if a Windows 11 ISO was placed in the download directory with any name
$existingIso = Get-ChildItem -Path $downloadDir -Filter "Win11*.iso" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existingIso) {
    Write-Output "Found Windows 11 ISO: $($existingIso.FullName)"
    Write-Output "Renaming to: $baseImageFile"
    $previousFile = Join-Path $downloadDir "$baseImageName.previous.iso"
    Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
    if (Test-Path $baseImageFile) {
        Move-Item -Path $baseImageFile -Destination $previousFile
        Write-Output "Previous image preserved as: $previousFile"
    }
    $existingIsoOriginalPath = $existingIso.FullName
    Move-Item -Path $existingIso.FullName -Destination $baseImageFile
    $baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
    Set-Content -Path $baseImageOrigin -Value @($existingIso.Name, [System.Uri]::new($existingIsoOriginalPath).AbsoluteUri)
    Write-Output "Recorded source filename and URL to: $baseImageOrigin"
    Write-Output "Done: $baseImageFile"
    exit 0
}

# === Try Fido (automated) ===
Write-Output ""
Write-Output "--- Attempting automated download via Fido ---"
$fidoScript = Join-Path $PSScriptRoot "Fido.ps1"
$downloadUrl  = $null
$downloadFile = $null

try {
    Write-Output "[Step 1/3] Downloading Fido script..."
    Write-Output "  URL: $fidoUrl"
    Invoke-WebRequest -Uri $fidoUrl -OutFile $fidoScript -UseBasicParsing -ErrorAction Stop
    Unblock-File $fidoScript
    Write-Output "  Done."

    Write-Output "[Step 2/3] Retrieving Windows 11 ISO download URL..."
    Write-Output "  Language: $languageFilter | Architecture: x64"
    $downloadUrl = & $fidoScript -Win 11 -Lang $languageFilter -Arch x64 -GetUrl

    if (-not $downloadUrl) {
        throw "Fido did not return a download URL."
    }
    Write-Output "  Download URL: $downloadUrl"

    Write-Output "[Step 3/3] Downloading Windows 11 ISO..."
    $downloadFile = Join-Path $downloadDir "downloaded.iso"
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    Write-Output "  Destination: $downloadFile"
    Write-Output "  This may take a while depending on your connection speed..."

    # Use BITS for progress, fall back to Invoke-WebRequest
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        $bitsJob = Start-BitsTransfer -Source $downloadUrl -Destination $downloadFile -Asynchronous -DisplayName "Windows 11 ISO"
        while ($bitsJob.JobState -eq "Transferring" -or $bitsJob.JobState -eq "Connecting") {
            if ($bitsJob.BytesTotal -gt 0) {
                $pct = [math]::Round(($bitsJob.BytesTransferred / $bitsJob.BytesTotal) * 100, 1)
                $transferredGB = [math]::Round($bitsJob.BytesTransferred / 1GB, 2)
                $totalGB = [math]::Round($bitsJob.BytesTotal / 1GB, 2)
                Write-Progress -Activity "Downloading Windows 11 ISO" -Status "$transferredGB GB / $totalGB GB ($pct%)" -PercentComplete $pct
            } else {
                Write-Progress -Activity "Downloading Windows 11 ISO" -Status "Connecting..."
            }
            Start-Sleep -Seconds 2
        }
        Write-Progress -Activity "Downloading Windows 11 ISO" -Completed
        if ($bitsJob.JobState -eq "Transferred") {
            Complete-BitsTransfer -BitsJob $bitsJob
        } else {
            Remove-BitsTransfer -BitsJob $bitsJob -ErrorAction SilentlyContinue
            throw "BITS ended in state: $($bitsJob.JobState)"
        }
    } catch {
        Write-Output "  BITS unavailable or failed. Downloading with Invoke-WebRequest..."
        Invoke-WebRequest -Uri $downloadUrl -OutFile $downloadFile -ErrorAction Stop
    }

    if (-not (Test-Path $downloadFile)) {
        throw "Download failed: file not found."
    }

    $fileSize = (Get-Item $downloadFile).Length
    Write-Output "  Downloaded: $([math]::Round($fileSize / 1GB, 2)) GB"
    if ($fileSize -lt 1GB) {
        throw "Downloaded file is suspiciously small (< 1 GB). It may not be a valid ISO."
    }

    # Rename to the naming convention
    $previousFile = Join-Path $downloadDir "$baseImageName.previous.iso"
    Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
    if (Test-Path $baseImageFile) {
        Move-Item -Path $baseImageFile -Destination $previousFile
        Write-Output "  Previous image preserved as: $previousFile"
    }
    Move-Item -Path $downloadFile -Destination $baseImageFile -Force
    $baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
    $originalName = [System.IO.Path]::GetFileName(([System.Uri]$downloadUrl).LocalPath)
    Set-Content -Path $baseImageOrigin -Value @($originalName, $downloadUrl)
    Write-Output "Recorded source filename and URL to: $baseImageOrigin"
    Write-Output ""
    Write-Output "=== Download complete: $baseImageFile ==="
    exit 0

} catch {
    Write-Warning "Automated download failed: $_"
    Write-Output ""
    # Clean up partial downloads
    if ($downloadFile -and (Test-Path $downloadFile)) {
        Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    }
}

# === Fallback: manual download instructions ===
Show-ManualDownloadInstruction -TargetPath $baseImageFile -TargetDir $downloadDir
exit 1
