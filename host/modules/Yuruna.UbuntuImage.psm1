<#PSScriptInfo
.VERSION 2026.07.03
.GUID 42b1e7d3-c9a4-4f82-a571-6c8d3e5f9a01
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna ubuntu image
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.RELEASENOTES
    Shared helpers used by every host's guest.ubuntu.server.*/Get-Image.ps1.
    Resolves stable/daily live-server ISO URLs, verifies SHA256, and
    swaps the new file into place with a previous-generation backup.
#>

#requires -version 7

<#
.SYNOPSIS
    Shared Ubuntu live-server ISO download library.

.DESCRIPTION
    Centralizes the resolve / download / verify / swap workflow used by
    host/<platform>/guest.ubuntu.server.<release>/Get-Image.ps1. Each
    host script supplies codename (noble, resolute, ...), CPU
    architecture (amd64 / arm64), and a target folder; this module
    figures out the canonical URLs and performs the download.

    The codename-less ubuntu-server/daily-live/ path on cdimage.ubuntu.com
    is rolling and serves whichever codename is currently in development,
    so requests for a now-past codename's ISO 404 there. All daily URLs
    here pin the codename in the path to stay aligned.
#>

# Save-CachedHttpUri and Test-DownloadAlreadyCurrent are exported from each
# per-host Yuruna.Host.psm1 driver (all three: KVM, macOS/UTM, Windows/Hyper-V).
# When a caller has imported its driver, Save-UbuntuServerImage routes downloads
# through the squid cache (HTTPS via the SSL-bump port with per-process trust of
# the freshly-fetched yuruna CA, HTTP via the proxy port; fall-through to direct
# Invoke-WebRequest when no cache is reachable) and reads/writes the shared
# 4-line sentinel. A bare caller that imports only this module (no host driver)
# falls back to a direct Invoke-WebRequest with the inline 3-line same-source
# guard.

function Write-UbuntuImageExceptionDetail {
    param($Record)
    Write-Verbose "Exception type: $($Record.Exception.GetType().FullName)"
    if ($Record.Exception.InnerException) {
        Write-Verbose "Inner: $($Record.Exception.InnerException.GetType().FullName) - $($Record.Exception.InnerException.Message)"
    }
    if ($Record.Exception.Response) {
        Write-Verbose "HTTP status: $([int]$Record.Exception.Response.StatusCode) $($Record.Exception.Response.StatusCode)"
    }
}

function Get-UbuntuServerImageManifestUrl {
    <#
    .SYNOPSIS
        Returns the stable + daily URL pair for a given codename and arch.

    .DESCRIPTION
        amd64 stable ISOs live on releases.ubuntu.com (it is amd64-only);
        arm64 stable ISOs live on cdimage.ubuntu.com/releases/<codename>/release.
        Dailies for both arches live on cdimage.ubuntu.com under
        ubuntu-server/<codename>/daily-live/current -- always with the
        codename in the path so the URL keeps working after the rolling
        codename-less path advances to a newer release.
    #>
    param(
        [Parameter(Mandatory)][string]$ReleaseCodename,
        [Parameter(Mandatory)][ValidateSet('amd64','arm64')][string]$Arch
    )
    if ($Arch -eq 'amd64') {
        $stable = "https://releases.ubuntu.com/$ReleaseCodename"
    } else {
        $stable = "https://cdimage.ubuntu.com/releases/$ReleaseCodename/release"
    }
    return [pscustomobject]@{
        StableReleaseUrl = $stable
        StableIsoPattern = "ubuntu-[\d.]+-live-server-$Arch\.iso"
        DailyBaseUrl     = "https://cdimage.ubuntu.com/ubuntu-server/$ReleaseCodename/daily-live/current"
        DailyIsoFileName = "$ReleaseCodename-live-server-$Arch.iso"
    }
}

function Resolve-UbuntuServerStableImage {
    param([string]$ReleaseBaseUrl, [string]$IsoPattern)
    Write-Verbose "Probing stable release index: $ReleaseBaseUrl/"
    try {
        $page = (Invoke-WebRequest -Uri "$ReleaseBaseUrl/" -ErrorAction Stop).Content
    } catch {
        Write-Warning "Stable release index at $ReleaseBaseUrl not reachable: $($_.Exception.Message)"
        Write-UbuntuImageExceptionDetail $_
        return $null
    }
    $found = [regex]::Matches($page, $IsoPattern)
    if ($found.Count -eq 0) {
        Write-Warning "No ISO matching pattern '$IsoPattern' found at $ReleaseBaseUrl"
        return $null
    }
    # Sort by the parsed [version], not lexically: as strings '24.04.2' sorts ABOVE '24.04.10',
    # so a lexical sort would pick the wrong (older) point release.
    $iso = ($found |
        Sort-Object -Property @{ Expression = {
                $m = [regex]::Match($_.Value, '(\d+(?:\.\d+)+)')
                if ($m.Success) { try { [version]$m.Groups[1].Value } catch { [version]'0.0' } } else { [version]'0.0' }
            }
        } -Descending |
        Select-Object -First 1).Value
    return [pscustomobject]@{
        IsoFileName = $iso
        SourceUrl   = "$ReleaseBaseUrl/$iso"
        ChecksumUrl = "$ReleaseBaseUrl/SHA256SUMS"
        Variant     = 'stable'
    }
}

function Resolve-UbuntuServerDailyImage {
    param([string]$DailyBaseUrl, [string]$IsoFileName)
    $url = "$DailyBaseUrl/$IsoFileName"
    Write-Verbose "HEAD-probing daily ISO: $url"
    try {
        Invoke-WebRequest -Uri $url -Method Head -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Daily ISO at $url not reachable: $($_.Exception.Message)"
        Write-UbuntuImageExceptionDetail $_
        return $null
    }
    return [pscustomobject]@{
        IsoFileName = $IsoFileName
        SourceUrl   = $url
        ChecksumUrl = "$DailyBaseUrl/SHA256SUMS"
        Variant     = 'daily'
    }
}

function Write-UbuntuImageProxyDiagnostic {
    <#
    .SYNOPSIS
        Emit a proxy-resolution snapshot for Ubuntu image download failures.
    .DESCRIPTION
        Logs proxy-related env vars, the platform's system proxy config
        (scutil on macOS, netsh winhttp on Windows), and how .NET's
        DefaultWebProxy resolves each $ProbeUrls entry. Called from
        Save-UbuntuServerImage when resolution fails completely, so the
        operator can tell whether the failure is a misrouted proxy or a
        genuinely unreachable mirror.
    #>
    param([string[]]$ProbeUrls = @())
    Write-Output "Proxy-related environment variables:"
    foreach ($v in 'http_proxy','https_proxy','HTTP_PROXY','HTTPS_PROXY','no_proxy','NO_PROXY','all_proxy','ALL_PROXY') {
        $val = [System.Environment]::GetEnvironmentVariable($v)
        Write-Output ("  " + $v + '=' + ($(if ($val) { $val } else { '(not set)' })))
    }
    Write-Output "System-level proxy configuration:"
    if ($IsMacOS) {
        try {
            $sc = (& scutil --proxy 2>&1) -join "`n"
            Write-Output "  scutil --proxy:"
            foreach ($line in ($sc -split "`n")) { if ($line) { Write-Output ("    " + $line.TrimEnd()) } }
        } catch {
            Write-Output "  scutil --proxy failed: $($_.Exception.Message)"
        }
    } elseif ($IsWindows) {
        try {
            $nw = (& netsh winhttp show proxy 2>&1) -join "`n"
            Write-Output "  netsh winhttp show proxy:"
            foreach ($line in ($nw -split "`n")) { if ($line) { Write-Output ("    " + $line.TrimEnd()) } }
        } catch {
            Write-Output "  netsh winhttp failed: $($_.Exception.Message)"
        }
    } else {
        Write-Output "  (no platform-specific system-proxy probe on this OS)"
    }
    if ($ProbeUrls.Count -gt 0) {
        Write-Output ".NET DefaultWebProxy resolution (what Invoke-WebRequest actually uses):"
        try {
            Write-Output ("  Type: " + [System.Net.WebRequest]::DefaultWebProxy.GetType().FullName)
        } catch {
            Write-Output "  (DefaultWebProxy unavailable: $($_.Exception.Message))"
        }
        foreach ($u in $ProbeUrls) {
            try {
                $uri = [System.Uri]::new($u)
                $resolved = [System.Net.WebRequest]::DefaultWebProxy.GetProxy($uri)
                $bypassed = [System.Net.WebRequest]::DefaultWebProxy.IsBypassed($uri)
                Write-Output ("  GetProxy('$u') = $resolved (bypassed=$bypassed)")
            } catch {
                Write-Output ("  GetProxy('$u') failed: $($_.Exception.Message)")
            }
        }
    }
}

function Resolve-UbuntuServerImage {
    <#
    .SYNOPSIS
        Returns the resolved ISO manifest (filename, URL, checksum URL).

    .DESCRIPTION
        Prefers stable; falls back to daily when -PreferDaily is omitted.
        Inverts that preference when -PreferDaily is set. Returns $null if
        both stable and daily are unreachable. Callers are responsible
        for emitting any final user-facing error message.
    #>
    param(
        [Parameter(Mandatory)][string]$ReleaseCodename,
        [Parameter(Mandatory)][ValidateSet('amd64','arm64')][string]$Arch,
        [switch]$PreferDaily
    )
    $url = Get-UbuntuServerImageManifestUrl -ReleaseCodename $ReleaseCodename -Arch $Arch
    if ($PreferDaily) {
        Write-Information "Resolving daily build from $($url.DailyBaseUrl) ..." -InformationAction Continue
        $resolved = Resolve-UbuntuServerDailyImage -DailyBaseUrl $url.DailyBaseUrl -IsoFileName $url.DailyIsoFileName
        if (-not $resolved) {
            Write-Warning "Daily build unavailable; falling back to stable build at $($url.StableReleaseUrl) ..."
            $resolved = Resolve-UbuntuServerStableImage -ReleaseBaseUrl $url.StableReleaseUrl -IsoPattern $url.StableIsoPattern
        }
    } else {
        Write-Information "Resolving stable build from $($url.StableReleaseUrl) ..." -InformationAction Continue
        $resolved = Resolve-UbuntuServerStableImage -ReleaseBaseUrl $url.StableReleaseUrl -IsoPattern $url.StableIsoPattern
        if (-not $resolved) {
            Write-Warning "Stable build unavailable; falling back to daily build at $($url.DailyBaseUrl) ..."
            $resolved = Resolve-UbuntuServerDailyImage -DailyBaseUrl $url.DailyBaseUrl -IsoFileName $url.DailyIsoFileName
        }
    }
    if ($resolved) {
        $resolved | Add-Member -NotePropertyName ManifestUrl -NotePropertyValue $url -PassThru | Out-Null
    }
    return $resolved
}

function Test-UbuntuServerImageChecksum {
    <#
    .SYNOPSIS
        Verifies a downloaded ISO against its SHA256SUMS entry.

    .DESCRIPTION
        Returns $true when the SHA256SUMS line for $IsoFileName matches
        $DownloadFile. Returns $true with a warning when no checksum
        file or matching line is available -- missing publisher
        checksum information is treated as a soft pass so a transient
        mirror outage doesn't block image refresh. Returns $false on
        an actual hash mismatch (the LOUD case: tampering, bit rot,
        partial download); the caller chooses whether to keep the file.
    #>
    param(
        [Parameter(Mandatory)][string]$ChecksumUrl,
        [Parameter(Mandatory)][string]$IsoFileName,
        [Parameter(Mandatory)][string]$DownloadFile
    )
    Write-Information "Verifying download integrity..." -InformationAction Continue
    # Best-effort: authenticate the SHA256SUMS via its detached GPG signature
    # before trusting any hash parsed from it. The verifier lives in
    # Yuruna.Image; import it on demand (that module isn't loaded in the ISO
    # path) and capture it as a CommandInfo so it resolves against its defining
    # module. gpg/keyserver absent or no .gpg -> 'unverified' (proceed on hash);
    # a definitively bad/foreign signature -> fail like a hash mismatch.
    $sigVerifier = Get-Command Test-PublishedChecksumSignature -ErrorAction SilentlyContinue
    if (-not $sigVerifier) {
        $imgMod = Join-Path $PSScriptRoot 'Yuruna.Image.psm1'
        if (Test-Path -LiteralPath $imgMod) {
            Import-Module $imgMod -ErrorAction SilentlyContinue
            $sigVerifier = Get-Command Test-PublishedChecksumSignature -ErrorAction SilentlyContinue
        }
    }
    if ($sigVerifier) {
        switch (& $sigVerifier -ChecksumUrl $ChecksumUrl) {
            'good'       { Write-Information "Checksum signature OK (pinned Ubuntu key)." -InformationAction Continue }
            'unverified' { Write-Warning "SHA256SUMS signature unverified (gpg/keyserver unavailable or no detached .gpg); proceeding on hash only." }
            'bad'        {
                Write-Warning ('=' * 72)
                Write-Warning "  SHA256SUMS GPG SIGNATURE INVALID"
                Write-Warning "  Source   : $ChecksumUrl"
                Write-Warning "  Failed verification against the pinned Ubuntu signing keys."
                Write-Warning ('=' * 72)
                return $false
            }
        }
    }
    try {
        $checksumContent = (Invoke-WebRequest -Uri $ChecksumUrl -ErrorAction Stop).Content
    } catch {
        Write-Warning "Could not download checksum file: $($_.Exception.Message)"
        return $true
    }
    $checksumLine = ($checksumContent -split "`n") | Where-Object { $_ -match [regex]::Escape($IsoFileName) } | Select-Object -First 1
    if (-not $checksumLine) {
        Write-Warning "Could not find checksum for $IsoFileName. Skipping verification."
        return $true
    }
    $expectedHash = ($checksumLine -split '\s+')[0]
    $actualHash = (Get-FileHash -Path $DownloadFile -Algorithm SHA256).Hash
    if ($expectedHash -ine $actualHash) {
        # Visual banner instead of Write-Error: the operator's decision
        # is upstream (Save-UbuntuServerImage chooses warn-vs-abort), so
        # we surface the mismatch loud enough to spot in scrollback but
        # leave the abort/continue policy to the caller.
        Write-Warning ('=' * 72)
        Write-Warning "  IMAGE CHECKSUM MISMATCH"
        Write-Warning "  File     : $IsoFileName"
        Write-Warning "  Expected : $expectedHash"
        Write-Warning "  Actual   : $actualHash"
        Write-Warning "  Source   : $ChecksumUrl"
        Write-Warning ('=' * 72)
        return $false
    }
    Write-Information "Checksum verified successfully." -InformationAction Continue
    return $true
}

function Test-UbuntuServerImageAlreadyCurrent {
    <#
    .SYNOPSIS
        Inline same-source guard for hosts whose Yuruna.Host.psm1 doesn't
        ship Test-DownloadAlreadyCurrent.

    .DESCRIPTION
        Returns $true only when $BaseImageFile is on disk, the sentinel
        records the same URL we just resolved, and a HEAD probe's
        Content-Length matches the recorded byte count.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceUrl,
        [Parameter(Mandatory)][string]$BaseImageFile,
        [Parameter(Mandatory)][string]$OriginFile
    )
    if (-not (Test-Path -LiteralPath $BaseImageFile)) { return $false }
    if (-not (Test-Path -LiteralPath $OriginFile)) { return $false }
    $prior = Get-Content -LiteralPath $OriginFile -ErrorAction SilentlyContinue
    if ($prior.Count -lt 3) { return $false }
    if ($prior[1] -ne $SourceUrl) { return $false }
    try {
        $head = Invoke-WebRequest -Uri $SourceUrl -Method Head -ErrorAction Stop
        $remoteLen = [int64]$head.Headers['Content-Length']
    } catch { $null = $_; return $false }
    return ([int64]$prior[2] -eq $remoteLen)
}

function Save-UbuntuServerImage {
    <#
    .SYNOPSIS
        Full resolve-download-verify-rename pipeline for an Ubuntu live-server ISO.

    .DESCRIPTION
        Resolves stable/daily, applies the skip-if-same-source guard,
        downloads (through Save-CachedHttpUri when available), verifies
        SHA256, preserves the prior ISO as <baseImageName>.previous.iso,
        and writes the sentinel <baseImageName>.txt with @(filename,
        url, byteCount).

        Returns one of: 'skipped', 'downloaded'. Throws on unrecoverable
        failure (no resolved manifest, download failure, checksum
        mismatch).

    .PARAMETER ReleaseCodename
        Ubuntu codename. 'noble' for 24.04, 'resolute' for 26.x.

    .PARAMETER Arch
        'amd64' or 'arm64'.

    .PARAMETER DownloadDir
        Folder where the ISO, sentinel, and previous-generation file live.

    .PARAMETER BaseImageName
        Stem used for <stem>.iso, <stem>.previous.iso, <stem>.txt.

    .PARAMETER PreferDaily
        Pull the daily ISO instead of the latest stable point release.

    .PARAMETER EmitProxyDiagnosticOnFailure
        When resolution fails completely, dump proxy environment +
        DefaultWebProxy diagnostics before throwing. Hosts that have a
        proxy-aware cache (macOS/Windows) set this; the bare KVM driver
        leaves it off to keep failure logs short.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ReleaseCodename,
        [Parameter(Mandatory)][ValidateSet('amd64','arm64')][string]$Arch,
        [Parameter(Mandatory)][string]$DownloadDir,
        [Parameter(Mandatory)][string]$BaseImageName,
        [switch]$PreferDaily,
        [switch]$EmitProxyDiagnosticOnFailure
    )

    $baseImageFile   = Join-Path $DownloadDir "$BaseImageName.iso"
    $baseImageOrigin = Join-Path $DownloadDir "$BaseImageName.txt"

    $resolved = Resolve-UbuntuServerImage -ReleaseCodename $ReleaseCodename -Arch $Arch -PreferDaily:$PreferDaily
    if (-not $resolved) {
        $url = Get-UbuntuServerImageManifestUrl -ReleaseCodename $ReleaseCodename -Arch $Arch
        $msg = "Could not resolve a usable Ubuntu live-server $Arch ISO. Stable ($($url.StableReleaseUrl)) and daily ($($url.DailyBaseUrl)) are both unreachable or missing the expected image."
        Write-Information $msg -InformationAction Continue
        if ($EmitProxyDiagnosticOnFailure) {
            Write-UbuntuImageProxyDiagnostic -ProbeUrls @("$($url.StableReleaseUrl)/", "$($url.DailyBaseUrl)/$($url.DailyIsoFileName)")
        }
        throw $msg
    }

    $isoFileName = $resolved.IsoFileName
    $sourceUrl   = $resolved.SourceUrl
    $checksumUrl = $resolved.ChecksumUrl
    Write-Information "Selected $($resolved.Variant) ISO: $isoFileName" -InformationAction Continue

    New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null

    # Same-source guard: prefer the host-shipped Test-DownloadAlreadyCurrent
    # (4-line sentinel; the writer below matches it), fall back to the bundled
    # Test-UbuntuServerImageAlreadyCurrent (3-line) for a bare caller with no
    # host driver imported.
    $alreadyCurrent = $false
    if (Get-Command -Name Test-DownloadAlreadyCurrent -ErrorAction SilentlyContinue) {
        $alreadyCurrent = Test-DownloadAlreadyCurrent -SourceUrl $sourceUrl -BaseImageFile $baseImageFile -OriginFile $baseImageOrigin
    } else {
        $alreadyCurrent = Test-UbuntuServerImageAlreadyCurrent -SourceUrl $sourceUrl -BaseImageFile $baseImageFile -OriginFile $baseImageOrigin
    }
    if ($alreadyCurrent) {
        $msg = "Skipping download: $sourceUrl URL and expected size match the prior run for $baseImageFile. To force a re-download, delete or rename: $baseImageFile"
        Write-Information $msg -InformationAction Continue
        return 'skipped'
    }

    $downloadFile = Join-Path $DownloadDir 'downloaded.iso'
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    Write-Information "Downloading $sourceUrl to $downloadFile" -InformationAction Continue
    try {
        if (Get-Command -Name Save-CachedHttpUri -ErrorAction SilentlyContinue) {
            Save-CachedHttpUri -Uri $sourceUrl -OutFile $downloadFile
        } else {
            Invoke-WebRequest -Uri $sourceUrl -OutFile $downloadFile -ErrorAction Stop
        }
    } catch {
        throw "Download failed: $($_.Exception.Message)"
    }
    $downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

    if (-not (Test-UbuntuServerImageChecksum -ChecksumUrl $checksumUrl -IsoFileName $isoFileName -DownloadFile $downloadFile)) {
        # Hard-fail on a genuine checksum MISMATCH: a present-and-wrong
        # publisher hash is corruption or tamper, never benign, so the
        # downloaded ISO is deleted and the refresh aborts rather than
        # promoting unverified bytes to the base image. A MISSING upstream
        # checksum or a transient SHA256SUMS fetch failure stays a soft pass
        # (publisher mirrors occasionally lag by minutes) -- that path
        # returns $true from Test-UbuntuServerImageChecksum and never reaches
        # here. The mismatch banner is printed above.
        Remove-Item -LiteralPath $downloadFile -Force -ErrorAction SilentlyContinue
        throw "Image checksum mismatch for $isoFileName (see banner above): the downloaded ISO did not match the publisher SHA256SUMS. Deleted the bad download and aborted; re-run once the publisher checksum catches up."
    }

    $previousFile = Join-Path $DownloadDir "$BaseImageName.previous.iso"
    Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $baseImageFile) {
        Move-Item -Path $baseImageFile -Destination $previousFile
        Write-Information "Previous image preserved as: $previousFile" -InformationAction Continue
    }
    Move-Item -Path $downloadFile -Destination $baseImageFile

    # Write the sentinel in the SAME format the skip-guard above reads back: when
    # the host driver ships the 4-line Test-DownloadAlreadyCurrent reader, emit the
    # matching 4-line sentinel (filename + URL + size + Last-Modified) via
    # Write-ImageSentinel; otherwise keep the bundled 3-line shape that
    # Test-UbuntuServerImageAlreadyCurrent reads. An asymmetric writer/reader pair
    # never matches, so the within-script skip-guard would re-download every
    # forced refresh.
    if (Get-Command -Name Test-DownloadAlreadyCurrent -ErrorAction SilentlyContinue) {
        Write-ImageSentinel -SourceUrl $sourceUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -Confirm:$false
    } else {
        Set-Content -Path $baseImageOrigin -Value @($isoFileName, $sourceUrl, "$downloadedSize")
    }
    Write-Information "Recorded source filename, URL, and byte count to: $baseImageOrigin" -InformationAction Continue
    Write-Information "Download complete: $baseImageFile" -InformationAction Continue
    return 'downloaded'
}

Export-ModuleMember -Function `
    Get-UbuntuServerImageManifestUrl, `
    Resolve-UbuntuServerImage, `
    Test-UbuntuServerImageChecksum, `
    Test-UbuntuServerImageAlreadyCurrent, `
    Save-UbuntuServerImage, `
    Write-UbuntuImageProxyDiagnostic
