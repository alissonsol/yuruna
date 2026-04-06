<#PSScriptInfo
.VERSION 0.1
.GUID 42b9c0d1-e2f3-4a56-b789-0c1d2e3f4a57
.AUTHOR Alisson Sol
.COMPANYNAME None
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

# === Configuration (change these to customize the download) ===
$downloadDir = "$HOME/virtual/windows.env"
$baseImageName = "host.macos.utm.guest.windows.11"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
$spiceImageName = "host.macos.utm.guest.windows.11.spice.iso"
$spiceImageFile = Join-Path $downloadDir $spiceImageName
# UTM Guest Tools ISO (includes SPICE + VirtIO drivers for ARM64 Windows)
$spiceDownloadUrl = "https://getutm.app/downloads/utm-guest-tools-latest.iso"

# Fido settings (change these to download a different edition/language)
$fidoUrl = "https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1"
$languageFilter = "English"

# Manual download fallback
$downloadPageUrl = "https://www.microsoft.com/en-us/software-download/windows11arm64"

Write-Output ""
Write-Output "=== Image Download ==="
Write-Output "Download folder: $downloadDir"
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The download folder does not exist and could not be created: $downloadDir"
    exit 1
}

# Track whether each image is ready
$windowsOk = $false
$spiceOk = $false

# ===========================================================================
# 1) Windows 11 ARM64 ISO
# ===========================================================================
Write-Output ""
Write-Output "--- Windows 11 ARM64 ISO ---"

if (Test-Path -Path $baseImageFile) {
    Write-Output "Already exists: $baseImageFile"
    $windowsOk = $true
} else {
    # Check if a Windows 11 ARM64 ISO was placed in the download directory with any name
    $existingIso = Get-ChildItem -Path $downloadDir -Filter "*.iso" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Win11.*ARM|Windows.*11.*ARM|ARM.*Win.*11' } |
        Select-Object -First 1
    if ($existingIso) {
        Write-Output "Found Windows 11 ARM64 ISO: $($existingIso.FullName)"
        Write-Output "Renaming to: $baseImageFile"
        Move-Item -Path $existingIso.FullName -Destination $baseImageFile
        Write-Output "Done: $baseImageFile"
        $windowsOk = $true
    }
}

if (-not $windowsOk) {
    # === Try Fido (automated) ===
    Write-Output ""
    Write-Output "Attempting automated download via Fido..."
    $fidoScript = Join-Path $PSScriptRoot "Fido.ps1"
    $downloadUrl = $null

    try {
        Write-Output "[Step 1/3] Downloading Fido script..."
        Write-Output "  URL: $fidoUrl"
        Invoke-WebRequest -Uri $fidoUrl -OutFile $fidoScript -UseBasicParsing -ErrorAction Stop
        Unblock-File $fidoScript
        Write-Output "  Done."

        Write-Output "[Step 2/3] Retrieving Windows 11 ARM64 ISO download URL..."
        Write-Output "  Language: $languageFilter | Architecture: arm64"
        $downloadUrl = & $fidoScript -Win 11 -Lang $languageFilter -Arch arm64 -GetUrl

        if (-not $downloadUrl) {
            throw "Fido did not return a download URL."
        }
        Write-Output "  Download URL: $downloadUrl"

        Write-Output "[Step 3/3] Downloading Windows 11 ARM64 ISO..."
        $downloadFile = Join-Path $downloadDir "downloaded.iso"
        Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
        Write-Output "  Destination: $downloadFile"
        Write-Output "  This may take a while depending on your connection speed..."

        # Use BITS for progress, fall back to Invoke-WebRequest
        $bitsOk = $false
        try {
            Import-Module BitsTransfer -ErrorAction Stop
            $bitsJob = Start-BitsTransfer -Source $downloadUrl -Destination $downloadFile -Asynchronous -DisplayName "Windows 11 ARM64 ISO"
            while ($bitsJob.JobState -eq "Transferring" -or $bitsJob.JobState -eq "Connecting") {
                if ($bitsJob.BytesTotal -gt 0) {
                    $pct = [math]::Round(($bitsJob.BytesTransferred / $bitsJob.BytesTotal) * 100, 1)
                    $transferredGB = [math]::Round($bitsJob.BytesTransferred / 1GB, 2)
                    $totalGB = [math]::Round($bitsJob.BytesTotal / 1GB, 2)
                    Write-Progress -Activity "Downloading Windows 11 ARM64 ISO" -Status "$transferredGB GB / $totalGB GB ($pct%)" -PercentComplete $pct
                } else {
                    Write-Progress -Activity "Downloading Windows 11 ARM64 ISO" -Status "Connecting..."
                }
                Start-Sleep -Seconds 2
            }
            Write-Progress -Activity "Downloading Windows 11 ARM64 ISO" -Completed
            if ($bitsJob.JobState -eq "Transferred") {
                Complete-BitsTransfer -BitsJob $bitsJob
                $bitsOk = $true
            } else {
                Remove-BitsTransfer -BitsJob $bitsJob -ErrorAction SilentlyContinue
                throw "BITS ended in state: $($bitsJob.JobState)"
            }
        } catch {
            Write-Output "  BITS unavailable or failed. Downloading with curl..."
            & curl -L --progress-bar -o $downloadFile $downloadUrl
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

        Move-Item -Path $downloadFile -Destination $baseImageFile -Force
        Write-Output "  Saved as: $baseImageFile"
        $windowsOk = $true

    } catch {
        Write-Warning "Automated download failed: $_"
        if ($downloadFile -and (Test-Path $downloadFile)) {
            Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not $windowsOk) {
    Write-Output ""
    Write-Output "  Manual download required for Windows 11 ARM64 ISO:"
    Write-Output ""
    Write-Output "    1. Open: $downloadPageUrl"
    Write-Output "    2. Select 'Windows 11 (multi-edition ISO for ARM64 devices)'"
    Write-Output "    3. Click Confirm"
    Write-Output "    4. Select 'English' as the language"
    Write-Output "    5. Click Confirm"
    Write-Output "    6. Click the 'ARM64 Download' button"
    Write-Output "    7. Save the ISO file as: $baseImageFile"
    Write-Output "       Or save any *ARM*.iso file to: $downloadDir"
    Write-Output ""
    Write-Output "  Then run this script again to continue."
}

# ===========================================================================
# 2) UTM Guest Tools ISO (SPICE + VirtIO drivers, ARM64-compatible)
# ===========================================================================
Write-Output ""
Write-Output "--- UTM Guest Tools ISO (SPICE + VirtIO drivers for ARM64) ---"

if (Test-Path -Path $spiceImageFile) {
    Write-Output "Already exists: $spiceImageFile"
    $spiceOk = $true
} else {
    Write-Output "Downloading from: $spiceDownloadUrl"
    $spiceDownloadFile = Join-Path $downloadDir "utm-guest-tools-download.iso"
    Remove-Item $spiceDownloadFile -Force -ErrorAction SilentlyContinue
    try {
        & curl -L --progress-bar -o $spiceDownloadFile $spiceDownloadUrl
        if ($LASTEXITCODE -ne 0) { throw "Download failed (curl exit code $LASTEXITCODE)" }
        if (-not (Test-Path $spiceDownloadFile)) {
            throw "Download failed: file not found."
        }
        $spiceSize = (Get-Item $spiceDownloadFile).Length
        if ($spiceSize -lt 1MB) {
            throw "Downloaded file is too small ($spiceSize bytes). It may not be a valid ISO."
        }
        Move-Item -Path $spiceDownloadFile -Destination $spiceImageFile -Force
        Write-Output "  Saved as: $spiceImageFile"
        $spiceOk = $true
    } catch {
        Write-Warning "Automated download of UTM Guest Tools ISO failed: $_"
        Remove-Item $spiceDownloadFile -Force -ErrorAction SilentlyContinue
    }
}

if (-not $spiceOk) {
    Write-Output ""
    Write-Output "  Manual download required for UTM Guest Tools ISO:"
    Write-Output ""
    Write-Output "    1. Open: https://docs.getutm.app/guest-support/windows/"
    Write-Output "    2. Download the UTM Guest Tools ISO linked on that page"
    Write-Output "       (contains SPICE tools and VirtIO drivers including arm64)"
    Write-Output "    3. Save the file as: $spiceImageFile"
    Write-Output ""
    Write-Output "  Then run this script again to continue."
}

# ===========================================================================
# Final status
# ===========================================================================
Write-Output ""
if ($windowsOk -and $spiceOk) {
    Write-Output "=== All images ready ==="
    exit 0
} else {
    Write-Output "=== Some images are missing — see manual download instructions above ==="
    exit 1
}
