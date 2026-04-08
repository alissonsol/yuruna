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

# Inform and check for elevation
Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
	Write-Output "Please run this script as Administrator."
	Write-Output "Be careful."
	exit 1
}

# === Configuration (change these to customize the download) ===
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageName = "host.windows.hyper-v.guest.windows.11"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"

# Fido settings (change these to download a different edition/language)
$fidoUrl = "https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1"
$languageFilter = "English"

# Manual download fallback
$downloadPageUrl = "https://www.microsoft.com/en-us/software-download/windows11"

Write-Output ""
Write-Output "=== Windows 11 ISO Download ==="
Write-Output "Hyper-V default VHDX folder: $downloadDir"
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
    exit 1
}

if (Test-Path -Path $baseImageFile) {
    Write-Output "Windows 11 ISO already exists at: $baseImageFile"
    Write-Output "To re-download, delete the file first and run this script again."
    exit 0
}

# Check if a Windows 11 ISO was placed in the download directory with any name
$existingIso = Get-ChildItem -Path $downloadDir -Filter "Win11*.iso" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existingIso) {
    Write-Output "Found Windows 11 ISO: $($existingIso.FullName)"
    Write-Output "Renaming to: $baseImageFile"
    Move-Item -Path $existingIso.FullName -Destination $baseImageFile
    Write-Output "Done: $baseImageFile"
    exit 0
}

# === Try Fido (automated) ===
Write-Output ""
Write-Output "--- Attempting automated download via Fido ---"
$fidoScript = Join-Path $PSScriptRoot "Fido.ps1"
$downloadUrl = $null

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
        Write-Output "  BITS unavailable or failed. Downloading with curl..."
        & curl.exe -L --progress-bar -o $downloadFile $downloadUrl
        if ($LASTEXITCODE -ne 0) { throw "Download failed (curl exit code $LASTEXITCODE)" }
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
    Move-Item -Path $downloadFile -Destination $baseImageFile -Force
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
Write-Output "    7. Save the ISO file as: $baseImageFile"
Write-Output "       Or save any Win11*.iso file to: $downloadDir"
Write-Output ""
Write-Output "  Then run this script again to continue."
exit 1
