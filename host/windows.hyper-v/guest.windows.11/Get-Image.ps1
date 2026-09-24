<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42a337f9-dcb7-4dfa-9c51-9ddba462035e
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
if (-not $IsWindows) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_5c41679836569594')
    exit 1
}

# --- REGION: Host architecture
# See https://yuruna.link/42e220c4-0003
# Use native OS architecture even when the current PowerShell process is emulated.
switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64' {
        $hostArch        = 'amd64'
        $fidoArch        = 'x64'
        $downloadPageUrl = "https://www.microsoft.com/en-us/software-download/windows11"
        $editionChoice   = 'Windows 11 (multi-edition ISO for x64 devices)'
        $downloadButton  = '64-bit Download'
    }
    'Arm64' {
        $hostArch        = 'arm64'
        $fidoArch        = 'arm64'
        $downloadPageUrl = "https://www.microsoft.com/en-us/software-download/windows11arm64"
        $editionChoice   = 'Windows 11 (multi-edition ISO for ARM64 devices)'
        $downloadButton  = 'ARM64 Download'
    }
    default {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_1f5a3a41f93d6b9f' -Arguments @{ oSArchitecture = "$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" })
        exit 1
    }
}

# --- REGION: Configuration
$baseImageName      = "host.windows.hyper-v.guest.windows.11"
$defaultDownloadDir = "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks"

# Fido settings (change these to download a different edition/language).
# Fido is pinned to a tagged release (not the moving `master` ref) and its
# script hash is verified before execution: Fido.ps1 runs with this script's
# privileges, so an unpinned moving ref is an unchecked remote-code hop.
# Refresh on a new Fido release: bump the tag in the URL and replace the hash
# with the new file's (Get-FileHash -Algorithm SHA256).Hash.
$fidoUrl        = "https://raw.githubusercontent.com/pbatard/Fido/v1.70/Fido.ps1"
$fidoSha256     = "24c86067fa399d2fd75ef0693a2ec79ca8db162827f808caac03541cbf640c13"
$languageFilter = "English"

# Fido is external code on its own release cadence, never enlistment content: a
# copy sitting next to this script would be scanned as repository source and is
# one `git add` away from being committed. Clear any that is present -- the
# verified copy this run executes is fetched to a temp directory below.
Remove-Item -LiteralPath (Join-Path $PSScriptRoot 'Fido.ps1') -Force -ErrorAction SilentlyContinue

function Show-ManualDownloadInstruction {
    param([string]$TargetPath, [string]$TargetDir)
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_9a9f6a0905ffda91')
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_f7c147d8352a58c6')
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_9ce492cf22a68e03' -Arguments @{ downloadPageUrl = "$downloadPageUrl" })
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_fb4cd0846e3495d1' -Arguments @{ editionChoice = "$editionChoice" })
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_8256d85c6ffcd2b9')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_dee4cbb914cf0c9d')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_a8aa4c0e64d394c3')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c0e6cc13a1e7926a' -Arguments @{ downloadButton = "$downloadButton" })
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_074cbbcc4c6229ae' -Arguments @{ targetPath = "$TargetPath" })
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_f43df01203b35f3d' -Arguments @{ targetDir = "$TargetDir" })
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_5a63a9ecfe4b9fc7')
}

Write-Output ""
Write-Output "== Windows 11 ISO =="

# --- REGION: Short-circuit #1: default-path existence check (no admin needed)
# Hyper-V's default VHD location is predictable, so check there FIRST
# without loading the Hyper-V module or requiring elevation. Most hosts
# keep the default; when it's been relocated we re-check the configured
# path below after elevation clears Get-VMHost.
$defaultBaseFile = Join-Path $defaultDownloadDir "$baseImageName.iso"
if (Test-Path -LiteralPath $defaultBaseFile) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_b8484d0c8d0f00c6')
    Write-Output "  File: $defaultBaseFile"
    exit 0
}

# --- REGION: Elevation check
# See https://yuruna.link/42e220c4-0003
# Unelevated calls print the same manual-download guidance as the test runner.
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_3e3de8bf7b8f6ba1')
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_93759b73418bf09d' -Arguments @{ defaultDownloadDir = "$defaultDownloadDir" })
    Show-ManualDownloadInstruction -TargetPath $defaultBaseFile -TargetDir $defaultDownloadDir
    exit 1
}

# --- REGION: Resolve the configured VHD folder
try {
    $downloadDir = (Get-VMHost -ErrorAction Stop).VirtualHardDiskPath
} catch {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_5874e8355455ba51' -Arguments @{ message = "$($_.Exception.Message)" })
    $downloadDir = $defaultDownloadDir
}
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"

Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e30f6e2006f710fa' -Arguments @{ downloadDir = "$downloadDir" })
if (!(Test-Path -Path $downloadDir)) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_c9c60711aada785b' -Arguments @{ downloadDir = "$downloadDir" })
    Show-ManualDownloadInstruction -TargetPath $baseImageFile -TargetDir $downloadDir
    exit 1
}

# --- REGION: Short-circuit #2: configured-path existence check
# Re-check under the Hyper-V-configured VHD path when it differs from the
# default (we already covered the default above). Cheap, and catches the
# "custom VHD path" case without another download.
if ($downloadDir -ne $defaultDownloadDir -and (Test-Path -LiteralPath $baseImageFile)) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_b8484d0c8d0f00c6')
    Write-Output "  File: $baseImageFile"
    exit 0
}

# --- REGION: https://yuruna.link/42e220c4-0003
# Require ARM media on ARM64; reject ARM-labeled media on AMD64 before adoption.
$adoptArchPattern = if ($hostArch -eq 'arm64') { '(?i)arm' } else { '(?i)^(?!.*arm).+' }
$existingIso = Get-ChildItem -Path $downloadDir -Filter "Win11*.iso" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match $adoptArchPattern } |
    Select-Object -First 1
if ($existingIso) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_3a7a4395e08fe54e' -Arguments @{ hostArch = "$hostArch"; fullName = "$($existingIso.FullName)" })
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
    exit 0
}

# --- REGION: https://yuruna.link/42ec97cd-0005
$agentIsoServed = $false
$agentStagingFile = Join-Path $downloadDir "downloaded.iso"
# The host driver carries the download-agent client. This script has no other
# reason to load a driver, so the import is guarded: a driver that cannot load
# is a host with no agent, not a failed image fetch.
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
            # ExpectedFilenamePattern for the same reason the adopt-any-name
            # filter above carries one: an answer naming the other
            # architecture's media is staged under the host-standard name and
            # New-VM does not re-check it, so the mismatch only shows up as a
            # guest that never installs.
            $agentResult = Request-DownloadAgentImage -BaseUrl $agentBaseUrl -HostType 'windows.hyper-v' `
                -ImageKey 'guest.windows.11' -Arch $hostArch -Variant 'stable' `
                -StagingPath $agentStagingFile -DeadlineSeconds 7200 `
                -ExpectedFilenamePattern $adoptArchPattern
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
            # The 2-line sidecar (filename + URL) this family has always written;
            # the 4-line sentinel reader is not wired up here, and an asymmetric
            # writer would only produce a shape nothing reads.
            $baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
            Set-Content -Path $baseImageOrigin -Value @([string]$agentResult.filename, [string]$agentResult.sourceUrl)
            Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_69295e2d532ea585' -Arguments @{ baseImageOrigin = "$baseImageOrigin" })
            Write-Output ""
            Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d30e8fed9b87e70b' -Arguments @{ baseImageFile = "$baseImageFile" })
            $agentIsoServed = $true
        } elseif ($agentResult -and $agentResult.outcome -eq 'failed') {
            $detail = if ($agentResult.error) { ": $($agentResult.error)" } else { '' }
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_bd4076d09a36eec5' -Arguments @{ agentBaseUrl = "$agentBaseUrl"; detail = "$detail" })
        } elseif ($agentResult) {
            # 'unavailable' is what a working agent answers for a family it does
            # not hold, which is the documented steady state for Windows 11.
            Write-Verbose "Download agent at $agentBaseUrl answered '$($agentResult.outcome)'; using the Fido path."
        }
    }
}
if ($agentIsoServed) { exit 0 }

# --- REGION: Try Fido (automated)
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_a652e6111719f172')
# Fetched per run into a throwaway directory: the only copy that executes is
# the one this invocation just fetched and hash-verified, and no external code
# is left behind in the enlistment. The finally below clears the directory
# whichever way this block leaves -- including the `exit 0` on success.
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
    Write-Output "  Done."

    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_bcc868d6b0c7f0f3')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_6959d402ef57f18d' -Arguments @{ languageFilter = "$languageFilter"; fidoArch = "$fidoArch" })
    # -PlatformArch skips Fido's slow WMI CPU autodetection and keeps this
    # invocation the verbatim mirror of the download-agent daemon's, which needs
    # the parameter because Get-CimInstance does not exist off Windows.
    $downloadUrl = & $fidoScript -Win 11 -Lang $languageFilter -Arch $fidoArch -PlatformArch $fidoArch -GetUrl

    if (-not $downloadUrl) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_3229f8d0887eda42')
    }
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_1e8fd043e8ea6df3' -Arguments @{ downloadUrl = "$downloadUrl" })

    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_71da54de194597d7')
    $downloadFile = Join-Path $downloadDir "downloaded.iso"
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    Write-Output "  Destination: $downloadFile"
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_26d58e13fc858352')

    # Use BITS for progress, fall back to Invoke-WebRequest
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        $bitsJob = Start-BitsTransfer -Source $downloadUrl -Destination $downloadFile -Asynchronous -DisplayName "Windows 11 ISO"
        while ($bitsJob.JobState -eq "Transferring" -or $bitsJob.JobState -eq "Connecting") {
            if ($bitsJob.BytesTotal -gt 0) {
                $pct = [math]::Round(($bitsJob.BytesTransferred / $bitsJob.BytesTotal) * 100, 1)
                $transferredGB = [math]::Round($bitsJob.BytesTransferred / 1GB, 2)
                $totalGB = [math]::Round($bitsJob.BytesTotal / 1GB, 2)
                Write-Progress -Activity (Format-YurunaOperatorMessage -Key 'host.operator_22ca18573ae3e913') -Status (Format-YurunaOperatorMessage -Key 'host.operator_13835229449d2daa' -Arguments @{ transferredGB = "$transferredGB"; totalGB = "$totalGB"; pct = "$pct" }) -PercentComplete $pct
            } else {
                Write-Progress -Activity (Format-YurunaOperatorMessage -Key 'host.operator_22ca18573ae3e913') -Status "Connecting..."
            }
            Start-Sleep -Seconds 2
        }
        Write-Progress -Activity (Format-YurunaOperatorMessage -Key 'host.operator_22ca18573ae3e913') -Completed
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
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_69295e2d532ea585' -Arguments @{ baseImageOrigin = "$baseImageOrigin" })
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d30e8fed9b87e70b' -Arguments @{ baseImageFile = "$baseImageFile" })
    exit 0

} catch {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_a1f938bc4fb29457' -Arguments @{ value = "$_" })
    Write-Output ""
    if ($downloadFile -and (Test-Path $downloadFile)) {
        Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    }
} finally {
    Remove-Item -LiteralPath $fidoWork -Recurse -Force -ErrorAction SilentlyContinue
}

# --- REGION: Fallback: manual download instructions
Show-ManualDownloadInstruction -TargetPath $baseImageFile -TargetDir $downloadDir
# --- REGION: Completion
exit 1
