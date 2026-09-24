<#PSScriptInfo
.VERSION 2026.09.24
.GUID 422c7a57-c395-4a3c-9648-066af9dbee1a
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
    Stages the Windows 11 install ISO + virtio-win driver ISO for KVM.

.DESCRIPTION
    Two artifacts are required to install Windows 11 on KVM/QEMU:
      * Windows 11 multi-edition x64 ISO (from microsoft.com/software-download).
        Microsoft serves this only via a JS-driven page that issues
        short-lived signed download URLs -- there is no clean wget-able
        link. A download agent that holds the media can serve it to this
        host; failing that, this script prints manual-download
        instructions and exits non-zero until the operator drops the ISO
        at the expected path.
      * virtio-win ISO (Fedora's signed driver bundle). This IS publicly
        downloadable; we pull the latest stable from fedorapeople.org.

    Apple Virtualization Framework guests on macOS UTM use the
    Win11 ARM64 ISO; KVM x86_64 hosts use the regular x64 ISO. ARM64
    Windows 11 on KVM aarch64 is not currently supported by this script
    (UUP-dump-assembled ISOs work but are out of scope for the initial
    scaffold).
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
if (-not $IsLinux) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_a96b67d0b8d27088')
    exit 1
}

# --- REGION: Host architecture
$arch = (& uname -m).Trim()
if ($arch -ne 'x86_64') {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_314ad0568cf5e5b2' -Arguments @{ arch = "$arch" })
    exit 1
}

# --- REGION: Configuration
$downloadDir   = "$HOME/yuruna/image/windows.11"
$baseImageName = "host.ubuntu.kvm.guest.windows.11"
$winIso        = Join-Path $downloadDir "$baseImageName.iso"
$virtioIso     = Join-Path $downloadDir 'virtio-win.iso'
$virtioOrigin  = Join-Path $downloadDir 'virtio-win.txt'

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# --- REGION: Windows 11 ISO: manual download path
$downloadPage = 'https://www.microsoft.com/en-us/software-download/windows11'
if (-not (Test-Path -LiteralPath $winIso)) {
    # --- REGION: https://yuruna.link/42e220c4-0003
    # Reject ARM-labeled media; an x64 image need not carry an architecture token.
    $candidate = Get-ChildItem -LiteralPath $downloadDir -Filter 'Win11*.iso' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '(?i)arm' } |
        Select-Object -First 1
    if ($candidate) {
        $candidateOriginalPath = $candidate.FullName
        Move-Item -Path $candidate.FullName -Destination $winIso
        # Provenance sidecar for Write-BaseImageProvenance (original filename +
        # adopted-from URI), matching the Hyper-V/UTM variants.
        $baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
        Set-Content -Path $baseImageOrigin -Value @($candidate.Name, [System.Uri]::new($candidateOriginalPath).AbsoluteUri)
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d6023b5bf2910216' -Arguments @{ name = "$($candidate.Name)"; winIso = "$winIso" })
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_69295e2d532ea585' -Arguments @{ baseImageOrigin = "$baseImageOrigin" })
    }
}
if (-not (Test-Path -LiteralPath $winIso)) {
    # --- REGION: https://yuruna.link/42ec97cd-0005
    $agentStagingFile = Join-Path $downloadDir 'downloaded.iso'
    # The host driver carries the download-agent client. It is imported again
    # further down for the virtio-win fetch; here the import is guarded because
    # a driver that cannot load is a host with no agent, not a failed run.
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
            Write-Verbose "No download agent reachable; the Windows 11 ISO stays a manual download."
        } else {
            $agentResult = $null
            try {
                Remove-Item $agentStagingFile -Force -ErrorAction SilentlyContinue
                $agentResult = Request-DownloadAgentImage -BaseUrl $agentBaseUrl -HostType 'ubuntu.kvm' `
                    -ImageKey 'guest.windows.11' -Arch 'amd64' -Variant 'stable' `
                    -StagingPath $agentStagingFile -DeadlineSeconds 7200
            } catch {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_ebf285f00d214782' -Arguments @{ agentBaseUrl = "$agentBaseUrl"; message = "$($_.Exception.Message)" })
                $agentResult = $null
            }
            if ($agentResult -and $agentResult.outcome -eq 'downloaded') {
                Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_22010fb874c3c316' -Arguments @{ agentBaseUrl = "$agentBaseUrl"; filename = "$($agentResult.filename)"; agentStagingFile = "$agentStagingFile" })
                $previousFile = Join-Path $downloadDir "$baseImageName.previous.iso"
                Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $winIso) {
                    Move-Item -Path $winIso -Destination $previousFile
                    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_05027812540d620c' -Arguments @{ previousFile = "$previousFile" })
                }
                Move-Item -Path $agentStagingFile -Destination $winIso -Force
                # The 2-line sidecar (filename + URL) Write-BaseImageProvenance
                # reads, the same shape the adoption path above writes.
                $baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
                Set-Content -Path $baseImageOrigin -Value @([string]$agentResult.filename, [string]$agentResult.sourceUrl)
                Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_69295e2d532ea585' -Arguments @{ baseImageOrigin = "$baseImageOrigin" })
            } elseif ($agentResult -and $agentResult.outcome -eq 'failed') {
                $detail = if ($agentResult.error) { ": $($agentResult.error)" } else { '' }
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_8756846a3985e94a' -Arguments @{ agentBaseUrl = "$agentBaseUrl"; detail = "$detail" })
            } elseif ($agentResult) {
                # 'unavailable' is what a working agent answers for a family it
                # does not hold, the documented steady state for Windows 11.
                Write-Verbose "Download agent at $agentBaseUrl answered '$($agentResult.outcome)'; the Windows 11 ISO stays a manual download."
            }
        }
    }
}
if (-not (Test-Path -LiteralPath $winIso)) {
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_9a9f6a0905ffda91')
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_3344aaf03bd51440' -Arguments @{ downloadPage = "$downloadPage" })
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_1deaa24f39b6e1b2')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_b70ffa30075acd01')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_efd4fb1b7ef75a83')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_9955eb48a65fa8d4')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_641d4bde8dc788c6')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_cfc1589048d71445' -Arguments @{ winIso = "$winIso" })
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_a9e197e13deba921' -Arguments @{ downloadDir = "$downloadDir" })
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_957da187da3adef7')
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_2148bcc575bad4ac' -Arguments @{ winIso = "$winIso" })
    exit 1
}
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_1af721e69b7a4d55' -Arguments @{ winIso = "$winIso" })

# --- REGION: https://yuruna.link/42e220c4-0003
# Abort on a failed download or staging operation before reporting success.
$ErrorActionPreference = 'Stop'

# --- REGION: virtio-win ISO: Fedora's hosted bundle (signed)
# See https://yuruna.link/42e220c4-0003
# Use the archived HTTPS URL to avoid downgrade redirects in the convenience URL.
$virtioUrl = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso'

# The KVM host driver brings the skip-if-same-source guard + sentinel writer
# (Test-DownloadAlreadyCurrent / Write-ImageSentinel, the shared 4-line filename +
# URL + size + Last-Modified format) AND the cache-aware Save-CachedHttpUri
# wrapper used for the virtio-win download below. (The Windows ISO is a manual
# download -- Microsoft serves it only via short-lived signed URLs -- so it
# cannot route through the cache.)
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Host.psm1") -Force
Import-Module -Name (Join-Path $PSScriptRoot '../../../automation/Yuruna.Retry.psm1') -Force

# --- REGION: https://yuruna.link/42ec97cd-0004
# See https://yuruna.link/42e220c4-0003
# Ask the download agent before probing the origin; retain the direct-download fallback.
$tmp = Join-Path $downloadDir 'virtio-win.iso.part'
$virtioAgentServed  = $false
$virtioAgentSkipped = $false
$virtioAgentUrl     = ''
$virtioAgentLastModified = ''
if ((Get-Command -Name Resolve-DownloadAgentEndpoint -ErrorAction SilentlyContinue) -and
    (Get-Command -Name Request-DownloadAgentImage -ErrorAction SilentlyContinue)) {
    $agentBaseUrl = ''
    try { $agentBaseUrl = [string](Resolve-DownloadAgentEndpoint) } catch { $agentBaseUrl = '' }
    if (-not $agentBaseUrl) {
        Write-Verbose "No download agent reachable; using the origin path for virtio-win."
    } else {
        # Fingerprint the local copy with the sentinel's filename + byte count
        # and no SHA-256: re-hashing the ISO every run would cost more than the
        # transfer it can save.
        $agentArgs = @{
            BaseUrl         = $agentBaseUrl
            HostType        = 'ubuntu.kvm'
            ImageKey        = 'virtio-win'
            Arch            = 'amd64'
            Variant         = 'stable'
            StagingPath     = $tmp
            DeadlineSeconds = 7200
        }
        if ((Test-Path -LiteralPath $virtioIso) -and (Test-Path -LiteralPath $virtioOrigin)) {
            $sentinelLines = @(Get-Content -LiteralPath $virtioOrigin -ErrorAction SilentlyContinue)
            $sentinelBytes = 0L
            if ($sentinelLines.Count -ge 3 -and [int64]::TryParse($sentinelLines[2].Trim(), [ref]$sentinelBytes) -and $sentinelBytes -gt 0) {
                $agentArgs['LocalFilename']  = $sentinelLines[0].Trim()
                $agentArgs['LocalByteCount'] = $sentinelBytes
            }
        }
        $agentResult = $null
        try {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            $agentResult = Request-DownloadAgentImage @agentArgs
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_57234ab9582f912d' -Arguments @{ agentBaseUrl = "$agentBaseUrl"; message = "$($_.Exception.Message)" })
            $agentResult = $null
        }
        if ($agentResult -and $agentResult.outcome -eq 'skipped') {
            $virtioAgentSkipped = $true
        } elseif ($agentResult -and $agentResult.outcome -eq 'downloaded') {
            $virtioAgentServed = $true
            # An agent that served bytes but published no origin URL still has
            # to produce a sentinel: Write-ImageSentinel refuses an empty
            # SourceUrl, and under this script's Stop preference that refusal
            # would abort a run whose download actually succeeded.
            $virtioAgentUrl = [string]$agentResult.sourceUrl
            if (-not $virtioAgentUrl) { $virtioAgentUrl = $virtioUrl }
            $virtioAgentLastModified = [string]$agentResult.lastModified
            Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c9280c32bb45be5e' -Arguments @{ agentBaseUrl = "$agentBaseUrl"; filename = "$($agentResult.filename)"; tmp = "$tmp" })
        } elseif ($agentResult) {
            $detail = if ($agentResult.error) { ": $($agentResult.error)" } else { '' }
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_eacd62147f05f2a6' -Arguments @{ agentBaseUrl = "$agentBaseUrl"; outcome = "$($agentResult.outcome)"; detail = "$detail" })
        }
    }
}

if ($virtioAgentSkipped) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_442b393595a79113' -Arguments @{ agentBaseUrl = "$agentBaseUrl"; virtioIso = "$virtioIso" })
} elseif (-not $virtioAgentServed -and (Test-DownloadAlreadyCurrent -SourceUrl $virtioUrl -BaseImageFile $virtioIso -OriginFile $virtioOrigin)) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e5e109ba266fe483' -Arguments @{ virtioIso = "$virtioIso" })
} else {
    if (-not $virtioAgentServed) {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Write-Output "Downloading $virtioUrl"
        # --- REGION: https://yuruna.link/42e220c4-0003
        # Capture the download command before entering the retry module scope.
        $saveCmd = Get-Command -Name Save-CachedHttpUri
        # --- REGION: https://yuruna.link/42e220c4-0003
        # Require a nonempty artifact before clearing a stale native discovery exit code.
        $dlLog = Join-Path $downloadDir 'virtio-win.download.log'
        Remove-Item $dlLog -Force -ErrorAction SilentlyContinue
        $download = Invoke-WithYurunaRetry -Label 'virtio-win.iso' -LogPath $dlLog -ScriptBlock ({
            & $saveCmd -Uri $virtioUrl -OutFile $tmp
            if (-not (Test-Path -LiteralPath $tmp)) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_29df6c21ee80406c' -Arguments @{ tmp = "$tmp" }) }
            if ((Get-Item -LiteralPath $tmp).Length -le 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_a937232a82280ebc' -Arguments @{ tmp = "$tmp" }) }
            $global:LASTEXITCODE = 0
        }).GetNewClosure()
        if (-not $download.Success) {
            # Surface the real cause: unwind the inner-exception chain (the squid
            # bump failure detail lives in an inner exception, not the top message),
            # and fall back to the captured per-attempt output when no exception
            # was recorded. The full per-attempt transcript is in $dlLog.
            if ($download.LastError) {
                $chain = @(); $ex = $download.LastError.Exception
                while ($ex) { $chain += ('{0}: {1}' -f $ex.GetType().Name, $ex.Message); $ex = $ex.InnerException }
                $detail = $chain -join ' -> '
            } else {
                $detail = 'no exception recorded (a stale non-zero $LASTEXITCODE from cache discovery, or a non-terminating failure)'
            }
            $tail = (@($download.LastOutput) | ForEach-Object { [string]$_ }) -join "`n    "
            throw ((Format-YurunaOperatorMessage -Key 'exceptions.host_88d0b2dc03ee17c2' -Arguments @{ attempts = "$($download.Attempts)"; maxAttempts = "$($download.MaxAttempts)"; lastExit = "$($download.LastExit)"; detail = "$detail"; tail = "$tail"; dlLog = "$dlLog" }))
        }
    }
    $size = (Get-Item -LiteralPath $tmp).Length
    if (Test-Path -LiteralPath $virtioIso) {
        Move-Item -Path $virtioIso -Destination (Join-Path $downloadDir 'virtio-win.previous.iso') -Force
    }
    Move-Item -Path $tmp -Destination $virtioIso
    if ($virtioAgentServed) {
        # --- REGION: https://yuruna.link/42e220c4-0003
        # Preserve the agent's origin URL and timestamp without probing the origin again.
        Write-ImageSentinel -SourceUrl $virtioAgentUrl -OriginFile $virtioOrigin -SizeBytes $size -LastModified $virtioAgentLastModified -Confirm:$false
    } else {
        Write-ImageSentinel -SourceUrl $virtioUrl -OriginFile $virtioOrigin -SizeBytes $size -Confirm:$false
    }
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_0474f0a01f20b99a' -Arguments @{ virtioIso = "$virtioIso" })
}

Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_6c1e9a279c4465de')
Write-Output "  $winIso"
Write-Output "  $virtioIso"

# --- REGION: Completion
# Clear a native discovery probe's stale exit code, including on cache hits.
exit 0
