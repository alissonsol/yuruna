<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42b84cc3-7873-4cc2-800e-3d90a4776081
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
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_b6e237c7cda71c3f')
    exit 1
}

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

# Fido is external code on its own release cadence, never enlistment content: a
# copy sitting next to this script would be scanned as repository source and is
# one `git add` away from being committed. Clear any that is present -- the
# verified copy this run executes is fetched to a temp directory below.
Remove-Item -LiteralPath (Join-Path $PSScriptRoot 'Fido.ps1') -Force -ErrorAction SilentlyContinue

# Manual download fallback
$downloadPageUrl = "https://www.microsoft.com/en-us/software-download/windows11arm64"

Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e39505c185df23e7')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_26ff901dc61a1c4c' -Arguments @{ downloadDir = "$downloadDir" })
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
if (!(Test-Path -Path $downloadDir)) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_140ee0a4d13c6e47' -Arguments @{ downloadDir = "$downloadDir" })
    exit 1
}

$windowsOk = $false
$spiceOk = $false

# --- REGION: Windows 11 ARM64 ISO
Write-Output ""
Write-Output "--- Windows 11 ARM64 ISO ---"

if (Test-Path -Path $baseImageFile) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_b8484d0c8d0f00c6')
    Write-Output "  File: $baseImageFile"
    $windowsOk = $true
} else {
    # Check if a Windows 11 ARM64 ISO was placed in the download directory with any name
    $existingIso = Get-ChildItem -Path $downloadDir -Filter "*.iso" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Win11.*ARM|Windows.*11.*ARM|ARM.*Win.*11' } |
        Select-Object -First 1
    if ($existingIso) {
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_6c2dffba6952556b' -Arguments @{ fullName = "$($existingIso.FullName)" })
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e7d3ecc0c4541317' -Arguments @{ baseImageFile = "$baseImageFile" })
        $previousFile = Join-Path $downloadDir "$baseImageName.previous.iso"
        Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
        if (Test-Path $baseImageFile) {
            Move-Item -Path $baseImageFile -Destination $previousFile
            Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_05027812540d620c' -Arguments @{ previousFile = "$previousFile" })
        }
        $existingIsoOriginalPath = $existingIso.FullName
        Move-Item -Path $existingIso.FullName -Destination $baseImageFile
        $baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
        Set-Content -Path $baseImageOrigin -Value @($existingIso.Name, [System.Uri]::new($existingIsoOriginalPath).AbsoluteUri)
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_69295e2d532ea585' -Arguments @{ baseImageOrigin = "$baseImageOrigin" })
        Write-Output "Done: $baseImageFile"
        $windowsOk = $true
    }
}

if (-not $windowsOk) {
    # --- REGION: https://yuruna.link/42ec97cd-0005
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
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_57d6aa65fdb2331b' -Arguments @{ agentBaseUrl = "$agentBaseUrl"; message = "$($_.Exception.Message)" })
                $agentResult = $null
            }
            if ($agentResult -and $agentResult.outcome -eq 'downloaded') {
                Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_22010fb874c3c316' -Arguments @{ agentBaseUrl = "$agentBaseUrl"; filename = "$($agentResult.filename)"; agentStagingFile = "$agentStagingFile" })
                $previousFile = Join-Path $downloadDir "$baseImageName.previous.iso"
                Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $baseImageFile) {
                    Move-Item -Path $baseImageFile -Destination $previousFile
                    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_98c81fc58f9efc47' -Arguments @{ previousFile = "$previousFile" })
                }
                Move-Item -Path $agentStagingFile -Destination $baseImageFile -Force
                # The 2-line sidecar (filename + URL) this family has always
                # written; the 4-line sentinel reader is not wired up here, and
                # an asymmetric writer would only produce a shape nothing reads.
                $baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
                Set-Content -Path $baseImageOrigin -Value @([string]$agentResult.filename, [string]$agentResult.sourceUrl)
                Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_4b8869730ce185b8' -Arguments @{ baseImageOrigin = "$baseImageOrigin" })
                Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_2779f3bf3d45cf09' -Arguments @{ baseImageFile = "$baseImageFile" })
                $windowsOk = $true
            } elseif ($agentResult -and $agentResult.outcome -eq 'failed') {
                $detail = if ($agentResult.error) { ": $($agentResult.error)" } else { '' }
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_bd4076d09a36eec5' -Arguments @{ agentBaseUrl = "$agentBaseUrl"; detail = "$detail" })
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
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e4b4e4f1a7d0e41f')
    # Fetched per run into a throwaway directory: the only copy that executes
    # is the one this invocation just fetched, hash-verified and then patched
    # for the platform gate, and no external code -- least of all a patched
    # copy -- is left behind in the enlistment. The finally below clears the
    # directory whichever way this block leaves.
    $fidoWork   = Join-Path ([System.IO.Path]::GetTempPath()) ('yuruna-fido-' + [Guid]::NewGuid().ToString('N'))
    $fidoScript = Join-Path $fidoWork "Fido.ps1"
    $downloadUrl  = $null
    $downloadFile = $null

    try {
        New-Item -ItemType Directory -Path $fidoWork -Force -ErrorAction Stop | Out-Null
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_389e41379c7ea679')
        Write-Output "  URL: $fidoUrl"
        Invoke-WebRequest -Uri $fidoUrl -OutFile $fidoScript -UseBasicParsing -ErrorAction Stop
        Unblock-File $fidoScript
        # Verify the pinned Fido.ps1 before running it; a hash mismatch means the
        # tagged content changed or the fetch was tampered, so fall back to the
        # manual download (caught below) instead of executing unverified code.
        $fidoActual = (Get-FileHash -LiteralPath $fidoScript -Algorithm SHA256).Hash
        if ($fidoActual -ine $fidoSha256) {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_dd6d74db4a58cc9d' -Arguments @{ fidoSha256 = "$fidoSha256"; fidoActual = "$fidoActual" })
        }
        # Fido refuses to run anywhere but Windows: Get-Platform-Version answers
        # 0.0 off Windows and the command-line path exits 403 ("This feature is
        # not available on this platform.") before making any request. The
        # -GetUrl flow behind that gate is platform-neutral, so neuter the gate
        # -- AFTER the hash check, so only the verified pinned bytes are ever
        # patched. Without this the automated path can never work on macOS.
        $fidoText = Get-Content -LiteralPath $fidoScript -Raw
        Set-Content -LiteralPath $fidoScript -NoNewline `
            -Value $fidoText.Replace('$winver = Get-Platform-Version', '$winver = 10.0')
        Write-Output "  Done."

        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_6897d3661c2e2fcd')
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e4f3eb0b2275877a' -Arguments @{ languageFilter = "$languageFilter" })
        # -PlatformArch skips Fido's CPU autodetection, which uses Get-CimInstance
        # (WMI) -- a Windows-only cmdlet that fails under macOS/Linux pwsh.
        $downloadUrl = & $fidoScript -Win 11 -Lang $languageFilter -Arch arm64 -PlatformArch arm64 -GetUrl

        if (-not $downloadUrl) {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_3229f8d0887eda42')
        }
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_1e8fd043e8ea6df3' -Arguments @{ downloadUrl = "$downloadUrl" })

        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c2ac53c45cd20863')
        $downloadFile = Join-Path $downloadDir "downloaded.iso"
        Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
        Write-Output "  Destination: $downloadFile"
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_26d58e13fc858352')

        # Use BITS for progress, fall back to Invoke-WebRequest
        try {
            Import-Module BitsTransfer -ErrorAction Stop
            $bitsJob = Start-BitsTransfer -Source $downloadUrl -Destination $downloadFile -Asynchronous -DisplayName "Windows 11 ARM64 ISO"
            while ($bitsJob.JobState -eq "Transferring" -or $bitsJob.JobState -eq "Connecting") {
                if ($bitsJob.BytesTotal -gt 0) {
                    $pct = [math]::Round(($bitsJob.BytesTransferred / $bitsJob.BytesTotal) * 100, 1)
                    $transferredGB = [math]::Round($bitsJob.BytesTransferred / 1GB, 2)
                    $totalGB = [math]::Round($bitsJob.BytesTotal / 1GB, 2)
                    Write-Progress -Activity (Format-YurunaOperatorMessage -Key 'host.operator_357cbe83efce827f') -Status (Format-YurunaOperatorMessage -Key 'host.operator_13835229449d2daa' -Arguments @{ transferredGB = "$transferredGB"; totalGB = "$totalGB"; pct = "$pct" }) -PercentComplete $pct
                } else {
                    Write-Progress -Activity (Format-YurunaOperatorMessage -Key 'host.operator_357cbe83efce827f') -Status "Connecting..."
                }
                Start-Sleep -Seconds 2
            }
            Write-Progress -Activity (Format-YurunaOperatorMessage -Key 'host.operator_357cbe83efce827f') -Completed
            if ($bitsJob.JobState -eq "Transferred") {
                Complete-BitsTransfer -BitsJob $bitsJob
            } else {
                Remove-BitsTransfer -BitsJob $bitsJob -ErrorAction SilentlyContinue
                throw "BITS ended in state: $($bitsJob.JobState)"
            }
        } catch {
            Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_66c7eec66542e844')
            Invoke-WebRequest -Uri $downloadUrl -OutFile $downloadFile -ErrorAction Stop
        }

        if (-not (Test-Path $downloadFile)) {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_870df3a8573355af')
        }

        $fileSize = (Get-Item $downloadFile).Length
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_efabc01383fdbdc6' -Arguments @{ gB = "$([math]::Round($fileSize / 1GB, 2))" })
        if ($fileSize -lt 1GB) {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_88e5a12c10f16189')
        }

        $previousFile = Join-Path $downloadDir "$baseImageName.previous.iso"
        Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
        if (Test-Path $baseImageFile) {
            Move-Item -Path $baseImageFile -Destination $previousFile
            Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_98c81fc58f9efc47' -Arguments @{ previousFile = "$previousFile" })
        }
        Move-Item -Path $downloadFile -Destination $baseImageFile -Force
        $baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
        $originalName = [System.IO.Path]::GetFileName(([System.Uri]$downloadUrl).LocalPath)
        Set-Content -Path $baseImageOrigin -Value @($originalName, $downloadUrl)
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_4b8869730ce185b8' -Arguments @{ baseImageOrigin = "$baseImageOrigin" })
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_2779f3bf3d45cf09' -Arguments @{ baseImageFile = "$baseImageFile" })
        $windowsOk = $true

    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_a1f938bc4fb29457' -Arguments @{ value = "$_" })
        if ($downloadFile -and (Test-Path $downloadFile)) {
            Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
        }
    } finally {
        Remove-Item -LiteralPath $fidoWork -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not $windowsOk) {
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_89c416f7ffc8adfa')
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_9ce492cf22a68e03' -Arguments @{ downloadPageUrl = "$downloadPageUrl" })
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_bd13116ee0d4ceed')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_8256d85c6ffcd2b9')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_dee4cbb914cf0c9d')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_a8aa4c0e64d394c3')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c3b93b719bddfcc5')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e73bb843561f0649' -Arguments @{ baseImageFile = "$baseImageFile" })
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_618ffa4947e3742f' -Arguments @{ downloadDir = "$downloadDir" })
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_5a63a9ecfe4b9fc7')
}

# --- REGION: UTM Guest Tools ISO (SPICE + VirtIO drivers, ARM64-compatible)
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_53718658a3b1e181')

if (Test-Path -Path $spiceImageFile) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_7722c9ef31cf3f93' -Arguments @{ spiceImageFile = "$spiceImageFile" })
    $spiceOk = $true
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_0ca910cd9041c443' -Arguments @{ spiceDownloadUrl = "$spiceDownloadUrl" })
    $spiceDownloadFile = Join-Path $downloadDir "utm-guest-tools-download.iso"
    Remove-Item $spiceDownloadFile -Force -ErrorAction SilentlyContinue
    try {
        Invoke-WebRequest -Uri $spiceDownloadUrl -OutFile $spiceDownloadFile -ErrorAction Stop
        if (-not (Test-Path $spiceDownloadFile)) {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_870df3a8573355af')
        }
        $spiceSize = (Get-Item $spiceDownloadFile).Length
        if ($spiceSize -lt 1MB) {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_d35eaa0aac5124a8' -Arguments @{ spiceSize = "$spiceSize" })
        }
        $spicePreviousFile = Join-Path $downloadDir "$($spiceImageName -replace '\.iso$','.previous.iso')"
        Remove-Item $spicePreviousFile -Force -ErrorAction SilentlyContinue
        if (Test-Path $spiceImageFile) {
            Move-Item -Path $spiceImageFile -Destination $spicePreviousFile
            Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_dfa60366092971bd' -Arguments @{ spicePreviousFile = "$spicePreviousFile" })
        }
        Move-Item -Path $spiceDownloadFile -Destination $spiceImageFile -Force
        $spiceImageOrigin = Join-Path $downloadDir ([System.IO.Path]::GetFileNameWithoutExtension($spiceImageName) + ".txt")
        $spiceOriginalName = [System.IO.Path]::GetFileName(([System.Uri]$spiceDownloadUrl).LocalPath)
        Set-Content -Path $spiceImageOrigin -Value @($spiceOriginalName, $spiceDownloadUrl)
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_718c5db3d22f4ff0' -Arguments @{ spiceImageOrigin = "$spiceImageOrigin" })
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_f86f4d4267851951' -Arguments @{ spiceImageFile = "$spiceImageFile" })
        $spiceOk = $true
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_a2b80c19104e45ae' -Arguments @{ value = "$_" })
        Remove-Item $spiceDownloadFile -Force -ErrorAction SilentlyContinue
    }
}

if (-not $spiceOk) {
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_903e4d92fedb0e31')
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_557888cda7f096ec')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e54fbc2821ca7a8f')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_8b41e306b0fd4497')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_a2dda9a6a547eba1' -Arguments @{ spiceImageFile = "$spiceImageFile" })
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_5a63a9ecfe4b9fc7')
}

# --- REGION: Completion
Write-Output ""
if ($windowsOk -and $spiceOk) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_04e1429d924ce2b6')
    exit 0
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_76d9904f0f26416c')
    exit 1
}
