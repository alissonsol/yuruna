<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e9a
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
        link. This script prints manual-download instructions and exits
        non-zero until the operator drops the ISO at the expected path.
      * virtio-win ISO (Fedora's signed driver bundle). This IS publicly
        downloadable; we pull the latest stable from fedorapeople.org.

    Apple Virtualization Framework guests on macOS UTM use the
    Win11 ARM64 ISO; KVM x86_64 hosts use the regular x64 ISO. ARM64
    Windows 11 on KVM aarch64 is not currently supported by this script
    (UUP-dump-assembled ISOs work but are out of scope for the initial
    scaffold).
#>

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.windows.11/Get-Image.ps1 only runs on Linux."
    exit 1
}

$arch = (& uname -m).Trim()
if ($arch -ne 'x86_64') {
    Write-Error "Windows 11 on KVM is only supported on x86_64 hosts (this host is $arch). Use the macOS UTM guest for ARM64."
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
    # Accept any Win11*.iso the user dropped here and rename it to the
    # expected path. Mirrors the Hyper-V variant's behavior.
    $candidate = Get-ChildItem -LiteralPath $downloadDir -Filter 'Win11*.iso' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($candidate) {
        $candidateOriginalPath = $candidate.FullName
        Move-Item -Path $candidate.FullName -Destination $winIso
        # Provenance sidecar for Write-BaseImageProvenance (original filename +
        # adopted-from URI), matching the Hyper-V/UTM variants.
        $baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"
        Set-Content -Path $baseImageOrigin -Value @($candidate.Name, [System.Uri]::new($candidateOriginalPath).AbsoluteUri)
        Write-Output "Adopted $($candidate.Name) -> $winIso"
        Write-Output "Recorded source filename and URL to: $baseImageOrigin"
    }
}
if (-not (Test-Path -LiteralPath $winIso)) {
    Write-Output ""
    Write-Output "--- Manual download required ---"
    Write-Output ""
    Write-Output "  1. Open: $downloadPage"
    Write-Output "  2. Select 'Windows 11 (multi-edition ISO for x64 devices)'"
    Write-Output "  3. Click Confirm"
    Write-Output "  4. Select 'English' as the language"
    Write-Output "  5. Click Confirm"
    Write-Output "  6. Click the '64-bit Download' button"
    Write-Output "  7. Save the ISO as: $winIso"
    Write-Output "     (or save any Win11*.iso file to $downloadDir)"
    Write-Output ""
    Write-Output "  Then re-run this script."
    Write-Error "Windows 11 ISO not found at $winIso"
    exit 1
}
Write-Output "Windows 11 ISO present: $winIso"

# Fail fast for the staging steps below. Save-CachedHttpUri raises a
# *statement*-terminating .NET exception on a squid SSL-bump TLS handshake
# failure: under the default ErrorActionPreference that aborts only the one
# statement, so the script blunders on through the Get-Item/Move-Item of a
# never-written file and falsely prints "Download complete" before exiting 0.
# 'Stop' makes any download/move/sentinel error abort with a non-zero exit so
# the caller (New-VM.ps1) reacts to a real failure instead of a phantom one.
$ErrorActionPreference = 'Stop'

# --- REGION: virtio-win ISO: Fedora's hosted bundle (signed)
# Pin the concrete versioned file under archive-virtio/. The convenience
# paths (stable-virtio/ and latest-virtio/) 301-redirect virtio-win.iso to
# this archived file through a chain that bounces https -> http -> https
# (Apache emits http:// Location headers; HSTS preload upgrades them back).
# Clients that refuse an https->http downgrade -- .NET HttpClient /
# Invoke-WebRequest, and the squid SSL-bump the host download routes through
# -- cannot follow that chain and fail at the TLS/redirect step, which breaks
# the whole guest. The archived versioned URL is a single-hop 200 over https.
# To refresh: list .../direct-downloads/stable-virtio/ for the current
# virtio-win-<ver>.iso, then point this at
# .../archive-virtio/virtio-win-<ver>-1/virtio-win-<ver>.iso.
$virtioUrl = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso'

# The KVM host driver brings the skip-if-same-source guard + sentinel writer
# (Test-DownloadAlreadyCurrent / Write-ImageSentinel, the shared 4-line filename +
# URL + size + Last-Modified format) AND the cache-aware Save-CachedHttpUri
# wrapper used for the virtio-win download below. (The Windows ISO is a manual
# download -- Microsoft serves it only via short-lived signed URLs -- so it
# cannot route through the cache.)
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Host.psm1") -Force
Import-Module -Name (Join-Path $PSScriptRoot '../../../automation/Yuruna.Retry.psm1') -Force

if (Test-DownloadAlreadyCurrent -SourceUrl $virtioUrl -BaseImageFile $virtioIso -OriginFile $virtioOrigin) {
    Write-Output "Skipping virtio-win download: URL and size match prior run for $virtioIso"
} else {
    $tmp = Join-Path $downloadDir 'virtio-win.iso.part'
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Write-Output "Downloading $virtioUrl"
    # Retry so a transient squid SSL-bump / origin blip on this single fetch
    # does not fail the whole guest (matching the kubectl/helm fetch policy).
    # Invoke-WithYurunaRetry catches the statement-terminating exception
    # Save-CachedHttpUri raises on a TLS handshake failure and retries with
    # backoff. Save-CachedHttpUri is invoked through a captured CommandInfo so
    # it still resolves when the scriptblock runs inside the retry module's
    # session state (see feedback_closure_foreign_module_command_resolution).
    $saveCmd = Get-Command -Name Save-CachedHttpUri
    # Make the downloaded FILE the authoritative success signal, not the
    # ambient $LASTEXITCODE. Save-CachedHttpUri's cache discovery runs native
    # `virsh` probes (Get-VMIp) that leave a non-zero $LASTEXITCODE when the
    # cache VM has no lease, even when the subsequent direct download succeeds;
    # Invoke-WithYurunaRetry keys success off $LASTEXITCODE, so without the
    # in-scriptblock file-check + reset a clean download is misreported as a
    # failure with no exception to show (an empty error message). See
    # feedback_lastexitcode_null_pure_ps_chain. A missing/empty file throws,
    # giving the retry a real message to surface and a reason to retry.
    $dlLog = Join-Path $downloadDir 'virtio-win.download.log'
    Remove-Item $dlLog -Force -ErrorAction SilentlyContinue
    $download = Invoke-WithYurunaRetry -Label 'virtio-win.iso' -LogPath $dlLog -ScriptBlock ({
        & $saveCmd -Uri $virtioUrl -OutFile $tmp
        if (-not (Test-Path -LiteralPath $tmp)) { throw "download wrote no file to $tmp" }
        if ((Get-Item -LiteralPath $tmp).Length -le 0) { throw "download produced an empty file at $tmp" }
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
        throw ("virtio-win.iso download failed after $($download.Attempts)/$($download.MaxAttempts) attempt(s) " +
               "[lastExit=$($download.LastExit)]: $detail`n  last-attempt output:`n    $tail`n  full per-attempt log: $dlLog")
    }
    $size = (Get-Item -LiteralPath $tmp).Length
    if (Test-Path -LiteralPath $virtioIso) {
        Move-Item -Path $virtioIso -Destination (Join-Path $downloadDir 'virtio-win.previous.iso') -Force
    }
    Move-Item -Path $tmp -Destination $virtioIso
    Write-ImageSentinel -SourceUrl $virtioUrl -OriginFile $virtioOrigin -SizeBytes $size -Confirm:$false
    Write-Output "Download complete: $virtioIso"
}

Write-Output ""
Write-Output "Both required artifacts staged:"
Write-Output "  $winIso"
Write-Output "  $virtioIso"
