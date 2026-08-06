<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42b9c0d1-e2f3-4a56-b789-0c1d2e3f4a57
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

# --- REGION: Configuration
$downloadDir = "$HOME/yuruna/image/windows.env"
$baseImageName = "host.macos.utm.guest.windows.11"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
$spiceImageName = "host.macos.utm.guest.windows.11.spice.iso"
$spiceImageFile = Join-Path $downloadDir $spiceImageName
# UTM Guest Tools ISO (includes SPICE + VirtIO drivers for ARM64 Windows)
$spiceDownloadUrl = "https://getutm.app/downloads/utm-guest-tools-latest.iso"

# Fido settings (change these to download a different edition/language).
# Fido is pinned to a tagged release (not the moving `master` ref) and its
# script hash is verified before execution: Fido.ps1 runs with this script's
# privileges, so an unpinned moving ref is an unchecked remote-code hop.
# Refresh on a new Fido release: bump the tag in the URL and replace the hash
# with the new file's (Get-FileHash -Algorithm SHA256).Hash.
$fidoUrl = "https://raw.githubusercontent.com/pbatard/Fido/v1.70/Fido.ps1"
$fidoSha256 = "24c86067fa399d2fd75ef0693a2ec79ca8db162827f808caac03541cbf640c13"
$languageFilter = "English"

# Manual download fallback
$downloadPageUrl = "https://www.microsoft.com/en-us/software-download/windows11arm64"

Write-Output ""
Write-Output "== Image Download =="
Write-Output "Download folder: $downloadDir"
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The download folder does not exist and could not be created: $downloadDir"
    exit 1
}

$windowsOk = $false
$spiceOk = $false

# --- REGION: 1. Windows 11 ARM64 ISO
Write-Output ""
Write-Output "--- Windows 11 ARM64 ISO ---"

if (Test-Path -Path $baseImageFile) {
    Write-Output "Skipping Windows download since ISO for this host is already present"
    Write-Output "  File: $baseImageFile"
    $windowsOk = $true
} else {
    # Check if a Windows 11 ARM64 ISO was placed in the download directory with any name
    $existingIso = Get-ChildItem -Path $downloadDir -Filter "*.iso" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Win11.*ARM|Windows.*11.*ARM|ARM.*Win.*11' } |
        Select-Object -First 1
    if ($existingIso) {
        Write-Output "Found Windows 11 ARM64 ISO: $($existingIso.FullName)"
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
        $windowsOk = $true
    }
}

if (-not $windowsOk) {
    # --- REGION: https://yuruna.link/guest-image-setup#agent-first-image-downloads
    # Only reached with no ARM64 ISO on this host: the existence check and the
    # drop-in adoption above have already run, so a local copy is never traded
    # for a LAN transfer. When the lab has an agent holding the Windows media
    # this spares a multi-gigabyte pull through Microsoft's short-lived signed
    # URL; when it does not, the Fido attempt below runs exactly as it always
    # has. The family is best effort by design (the agent mints its URL by
    # running this same Fido under Linux pwsh), so "the agent does not serve
    # Windows 11" is an ordinary answer and stays verbose -- only an agent that
    # took the request and then broke is worth a warning.
    #
    # No local fingerprint is sent: this script's sidecar is the 2-line
    # filename + URL form, which carries no byte count for the agent to compare,
    # and the existence check above is already the local-copy decision.
    $agentStagingFile = Join-Path $downloadDir "downloaded.iso"
    # The host driver carries the download-agent client. This script has no other
    # reason to load a driver, so the import is guarded: a driver that cannot
    # load is a host with no agent, not a failed image fetch.
    if (-not (Get-Command -Name Resolve-DownloadAgentEndpoint -ErrorAction SilentlyContinue)) {
        try {
            Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Host.psm1") -Force -ErrorAction Stop
        } catch {
            Write-Verbose "Host driver did not load ($($_.Exception.Message)); no download agent will be consulted."
        }
    }
    if ((Get-Command -Name Resolve-DownloadAgentEndpoint -ErrorAction SilentlyContinue) -and
        (Get-Command -Name Request-DownloadAgentImage -ErrorAction SilentlyContinue)) {
        $agentBaseUrl = ''
        try { $agentBaseUrl = [string](Resolve-DownloadAgentEndpoint) } catch { $agentBaseUrl = '' }
        if (-not $agentBaseUrl) {
            Write-Verbose "No download agent reachable; using the Fido path."
        } else {
            $agentResult = $null
            try {
                Remove-Item $agentStagingFile -Force -ErrorAction SilentlyContinue
                $agentResult = Request-DownloadAgentImage -BaseUrl $agentBaseUrl -HostType 'macos.utm' `
                    -ImageKey 'guest.windows.11' -Arch 'arm64' -Variant 'stable' `
                    -StagingPath $agentStagingFile -DeadlineSeconds 7200
            } catch {
                Write-Warning "Download agent at $agentBaseUrl failed ($($_.Exception.Message)); falling back to the Fido path."
                $agentResult = $null
            }
            if ($agentResult -and $agentResult.outcome -eq 'downloaded') {
                Write-Output "Download agent at $agentBaseUrl served verified $($agentResult.filename) to $agentStagingFile"
                $previousFile = Join-Path $downloadDir "$baseImageName.previous.iso"
                Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $baseImageFile) {
                    Move-Item -Path $baseImageFile -Destination $previousFile
                    Write-Output "  Previous image preserved as: $previousFile"
                }
                Move-Item -Path $agentStagingFile -Destination $baseImageFile -Force
                # The 2-line sidecar (filename + URL) this family has always
                # written; the 4-line sentinel reader is not wired up here, and
                # an asymmetric writer would only produce a shape nothing reads.
                $baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
                Set-Content -Path $baseImageOrigin -Value @([string]$agentResult.filename, [string]$agentResult.sourceUrl)
                Write-Output "  Recorded source filename and URL to: $baseImageOrigin"
                Write-Output "  Saved as: $baseImageFile"
                $windowsOk = $true
            } elseif ($agentResult -and $agentResult.outcome -eq 'failed') {
                $detail = if ($agentResult.error) { ": $($agentResult.error)" } else { '' }
                Write-Warning "Download agent at $agentBaseUrl answered 'failed'$detail; falling back to the Fido path."
            } elseif ($agentResult) {
                # 'unavailable' is what a working agent answers for a family it
                # does not hold, the documented steady state for Windows 11.
                Write-Verbose "Download agent at $agentBaseUrl answered '$($agentResult.outcome)'; using the Fido path."
            }
        }
    }
}

if (-not $windowsOk) {
    # --- REGION: Try Fido (automated)
    Write-Output ""
    Write-Output "Attempting automated download via Fido..."
    $fidoScript = Join-Path $PSScriptRoot "Fido.ps1"
    $downloadUrl = $null

    try {
        Write-Output "[Step 1/3] Downloading Fido script..."
        Write-Output "  URL: $fidoUrl"
        Invoke-WebRequest -Uri $fidoUrl -OutFile $fidoScript -UseBasicParsing -ErrorAction Stop
        Unblock-File $fidoScript
        # Verify the pinned Fido.ps1 before running it; a hash mismatch means the
        # tagged content changed or the fetch was tampered, so fall back to the
        # manual download (caught below) instead of executing unverified code.
        $fidoActual = (Get-FileHash -LiteralPath $fidoScript -Algorithm SHA256).Hash
        if ($fidoActual -ine $fidoSha256) {
            throw "Fido.ps1 hash mismatch (pinned v1.70): expected $fidoSha256, got $fidoActual"
        }
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
        Write-Output "  Recorded source filename and URL to: $baseImageOrigin"
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

# --- REGION: 2. UTM Guest Tools ISO (SPICE + VirtIO drivers, ARM64-compatible)
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
        Invoke-WebRequest -Uri $spiceDownloadUrl -OutFile $spiceDownloadFile -ErrorAction Stop
        if (-not (Test-Path $spiceDownloadFile)) {
            throw "Download failed: file not found."
        }
        $spiceSize = (Get-Item $spiceDownloadFile).Length
        if ($spiceSize -lt 1MB) {
            throw "Downloaded file is too small ($spiceSize bytes). It may not be a valid ISO."
        }
        $spicePreviousFile = Join-Path $downloadDir "$($spiceImageName -replace '\.iso$','.previous.iso')"
        Remove-Item $spicePreviousFile -Force -ErrorAction SilentlyContinue
        if (Test-Path $spiceImageFile) {
            Move-Item -Path $spiceImageFile -Destination $spicePreviousFile
            Write-Output "  Previous SPICE image preserved as: $spicePreviousFile"
        }
        Move-Item -Path $spiceDownloadFile -Destination $spiceImageFile -Force
        $spiceImageOrigin = Join-Path $downloadDir ([System.IO.Path]::GetFileNameWithoutExtension($spiceImageName) + ".txt")
        $spiceOriginalName = [System.IO.Path]::GetFileName(([System.Uri]$spiceDownloadUrl).LocalPath)
        Set-Content -Path $spiceImageOrigin -Value @($spiceOriginalName, $spiceDownloadUrl)
        Write-Output "  Recorded source filename and URL to: $spiceImageOrigin"
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

# --- REGION: Final status
Write-Output ""
if ($windowsOk -and $spiceOk) {
    Write-Output "== All images ready =="
    exit 0
} else {
    Write-Output "== Some images are missing -- see manual download instructions above =="
    exit 1
}
