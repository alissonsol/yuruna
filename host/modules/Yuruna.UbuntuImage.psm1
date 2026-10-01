<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42418995-a462-47f5-816a-8709623807f8
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

# Downloads route through the squid cache only when the caller has imported a
# per-host Yuruna.Host.psm1 driver; a bare caller falls back to a direct fetch.
# Both paths and the sentinel formats:
# docs/guest-image-setup.md#ubuntu-iso-downloads-yurunaubuntuimagepsm1

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Image.psm1') -DisableNameChecking -Verbose:$false

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

function Get-UbuntuImageHttpStatus {
    param([AllowNull()]$ErrorRecord)
    Get-YurunaHttpErrorStatus -ErrorRecord $ErrorRecord
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_42f0f8d1abd44b3f' -Arguments @{ releaseBaseUrl = "$ReleaseBaseUrl"; message = "$($_.Exception.Message)" })
        Write-UbuntuImageExceptionDetail $_
        return $null
    }
    $found = [regex]::Matches($page, $IsoPattern)
    if ($found.Count -eq 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_a22385e20dbe740d' -Arguments @{ isoPattern = "$IsoPattern"; releaseBaseUrl = "$ReleaseBaseUrl" })
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_bf10148337542752' -Arguments @{ url = "$url"; message = "$($_.Exception.Message)" })
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
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d47b313283bbfa9f')
    foreach ($v in 'http_proxy','https_proxy','HTTP_PROXY','HTTPS_PROXY','no_proxy','NO_PROXY','all_proxy','ALL_PROXY') {
        $val = [System.Environment]::GetEnvironmentVariable($v)
        Write-Output ("  " + $v + '=' + ($(if ($val) { $val } else { '(not set)' })))
    }
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_ca6b567d25ee4169')
    if ($IsMacOS) {
        try {
            $sc = (& scutil --proxy 2>&1) -join "`n"
            Write-Output "  scutil --proxy:"
            foreach ($line in ($sc -split "`n")) { if ($line) { Write-Output ("    " + $line.TrimEnd()) } }
        } catch {
            Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_4de7942157cfd862' -Arguments @{ message = "$($_.Exception.Message)" })
        }
    } elseif ($IsWindows) {
        try {
            $nw = (& netsh winhttp show proxy 2>&1) -join "`n"
            Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_4ac977c303f1ed0e')
            foreach ($line in ($nw -split "`n")) { if ($line) { Write-Output ("    " + $line.TrimEnd()) } }
        } catch {
            Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_151869ef5e88ee85' -Arguments @{ message = "$($_.Exception.Message)" })
        }
    } else {
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_9c87c921239516dc')
    }
    if ($ProbeUrls.Count -gt 0) {
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_0e6be99a1c64ed77')
        try {
            Write-Output ("  Type: " + [System.Net.WebRequest]::DefaultWebProxy.GetType().FullName)
        } catch {
            Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_8d7e028bfdaf5af6' -Arguments @{ message = "$($_.Exception.Message)" })
        }
        foreach ($u in $ProbeUrls) {
            try {
                $uri = [System.Uri]::new($u)
                $resolved = [System.Net.WebRequest]::DefaultWebProxy.GetProxy($uri)
                $bypassed = [System.Net.WebRequest]::DefaultWebProxy.IsBypassed($uri)
                Write-Output ((Format-YurunaOperatorMessage -Key 'host.operator_106fbf5a8e4ad2b9' -Arguments @{ u = "$u"; resolved = "$resolved"; bypassed = "$bypassed" }))
            } catch {
                Write-Output ((Format-YurunaOperatorMessage -Key 'host.operator_ea4f8575bd4350f7' -Arguments @{ u = "$u"; message = "$($_.Exception.Message)" }))
            }
        }
    }
}

function Resolve-UbuntuServerImage {
    <#
    .SYNOPSIS
        Returns the resolved ISO manifest (filename, URL, checksum URL).

    .DESCRIPTION
        Tries stable then daily; -PreferDaily inverts that order. Returns
        $null when both are unreachable -- the caller emits any final
        user-facing error message.
    #>
    param(
        [Parameter(Mandatory)][string]$ReleaseCodename,
        [Parameter(Mandatory)][ValidateSet('amd64','arm64')][string]$Arch,
        [switch]$PreferDaily
    )
    $url = Get-UbuntuServerImageManifestUrl -ReleaseCodename $ReleaseCodename -Arch $Arch
    if ($PreferDaily) {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_92959818bd3cbd06' -Arguments @{ dailyBaseUrl = "$($url.DailyBaseUrl)" }) -InformationAction Continue
        $resolved = Resolve-UbuntuServerDailyImage -DailyBaseUrl $url.DailyBaseUrl -IsoFileName $url.DailyIsoFileName
        if (-not $resolved) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_836ce08aa7c8918a' -Arguments @{ stableReleaseUrl = "$($url.StableReleaseUrl)" })
            $resolved = Resolve-UbuntuServerStableImage -ReleaseBaseUrl $url.StableReleaseUrl -IsoPattern $url.StableIsoPattern
        }
    } else {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_c689a85719965f3f' -Arguments @{ stableReleaseUrl = "$($url.StableReleaseUrl)" }) -InformationAction Continue
        $resolved = Resolve-UbuntuServerStableImage -ReleaseBaseUrl $url.StableReleaseUrl -IsoPattern $url.StableIsoPattern
        if (-not $resolved) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_27a71e3ba4d8a962' -Arguments @{ dailyBaseUrl = "$($url.DailyBaseUrl)" })
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
        $DownloadFile. Returns $true with a warning only when the
        publisher genuinely provides no checksum (HTTP 403/404/410 on
        the checksum file, or no line for this ISO) -- that soft pass
        keeps mirrors without checksums usable. A transient checksum
        fetch failure is retried on a bounded backoff budget and, if it
        never clears, returns $false: unverifiable is not the same as
        unpublished, and the caller must not promote bytes it cannot
        check. Also returns $false on an actual hash mismatch (the LOUD
        case: tampering, bit rot, partial download); the caller chooses
        whether to keep the file.
    #>
    param(
        [Parameter(Mandatory)][string]$ChecksumUrl,
        [Parameter(Mandatory)][string]$IsoFileName,
        [Parameter(Mandatory)][string]$DownloadFile
    )
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_07fe5b3f6f64fc10') -InformationAction Continue
    Import-Module (Join-Path $PSScriptRoot 'Yuruna.Image.psm1') -DisableNameChecking -Verbose:$false
    $work     = Join-Path ([System.IO.Path]::GetTempPath()) ('yuruna-sums-' + [Guid]::NewGuid().ToString('N'))
    $sumsFile = Join-Path $work 'SHA256SUMS'
    $checksumContent = $null
    try {
        New-Item -ItemType Directory -Path $work -Force -ErrorAction Stop | Out-Null
        $fetched = Get-PublishedChecksumBody -ChecksumUrl $ChecksumUrl -DestinationPath $sumsFile
        $checksumContent = $fetched.Body
        if ($fetched.State -eq 'absent') {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_135befd0132343f2' -Arguments @{ checksumUrl = "$ChecksumUrl"; status = "$($fetched.Status)" })
            return $true
        }
        if ($fetched.State -ne 'fetched') {
            Write-Warning ('=' * 72)
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_ffa509d9c8227161')
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0a2316bbbe70c189' -Arguments @{ checksumUrl = "$ChecksumUrl" })
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_e96b79d3e29d27c5' -Arguments @{ returned = "$($fetched.Detail)" })
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b144a3f615f5cc3d')
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_89fba45b13464342')
            Write-Warning ('=' * 72)
            return $false
        }
        # Best-effort: authenticate the SHA256SUMS via its detached GPG signature
        # before trusting any hash parsed from it. The verifier lives in
        # Yuruna.Image, which the ISO path does not load, so import on demand and
        # capture a CommandInfo that resolves against its defining module. It is
        # handed the copy already on disk so the signature and the hash bind to
        # ONE artifact. No gpg/keyserver/.gpg -> 'unverified' (proceed on hash);
        # a definitively bad or foreign signature -> fail like a hash mismatch.
        $sigVerifier = Get-Command Test-PublishedChecksumSignature -ErrorAction SilentlyContinue
        if (-not $sigVerifier) {
            $imgMod = Join-Path $PSScriptRoot 'Yuruna.Image.psm1'
            if (Test-Path -LiteralPath $imgMod) {
                Import-Module $imgMod -ErrorAction SilentlyContinue
                $sigVerifier = Get-Command Test-PublishedChecksumSignature -ErrorAction SilentlyContinue
            }
        }
        if ($sigVerifier) {
            switch (& $sigVerifier -ChecksumUrl $ChecksumUrl -ChecksumFilePath $sumsFile) {
                'good'       { Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_16b618147c03a190') -InformationAction Continue }
                'unverified' { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_891e818fe6ad2659') }
                'bad'        {
                    Write-Warning ('=' * 72)
                    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_ad8085714f2d476d')
                    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0a2316bbbe70c189' -Arguments @{ checksumUrl = "$ChecksumUrl" })
                    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_72ff259bdf314467')
                    Write-Warning ('=' * 72)
                    return $false
                }
            }
        }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    $checksumLine = Get-ImageChecksumLine -ChecksumUrl $ChecksumUrl -TargetFileName $IsoFileName -ChecksumBody $checksumContent
    if ($checksumLine.State -ne 'found') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_1dfbd537872c61ec' -Arguments @{ isoFileName = "$IsoFileName"; checksumUrl = "$ChecksumUrl" })
        return $true
    }
    $expectedHash = $checksumLine.Hash
    $actualHash = (Get-FileHash -Path $DownloadFile -Algorithm SHA256).Hash
    if ($expectedHash -ine $actualHash) {
        # Visual banner instead of Write-Error: the operator's decision
        # is upstream (Save-UbuntuServerImage chooses warn-vs-abort), so
        # we surface the mismatch loud enough to spot in scrollback but
        # leave the abort/continue policy to the caller.
        Write-Warning ('=' * 72)
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0ae9e0059c4835bf')
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_c209cdb5554afd71' -Arguments @{ isoFileName = "$IsoFileName" })
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_e110fb938283f7b1' -Arguments @{ expectedHash = "$expectedHash" })
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_705af9e21ab944c5' -Arguments @{ actualHash = "$actualHash" })
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0a2316bbbe70c189' -Arguments @{ checksumUrl = "$ChecksumUrl" })
        Write-Warning ('=' * 72)
        return $false
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_f019bbe34971680c') -InformationAction Continue
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
        $lengthHeader = $head.Headers['Content-Length']
        if ($lengthHeader -is [array]) { $lengthHeader = $lengthHeader[0] }
        $remoteLen = [int64]0
        if (-not [int64]::TryParse([string]$lengthHeader, [ref]$remoteLen)) { return $false }
    } catch { $null = $_; return $false }
    return ([int64]$prior[2] -eq $remoteLen)
}

function Save-UbuntuServerImage {
    <#
    .SYNOPSIS
        Full resolve-download-verify-rename pipeline for an Ubuntu live-server ISO.

    .DESCRIPTION
        Consults a download agent first when one is reachable (see
        docs/guest-image-setup.md#agent-first-image-downloads); with no
        agent, or on any agent failure, resolves stable/daily, applies the
        skip-if-same-source guard, downloads (through Save-CachedHttpUri
        when available) and verifies SHA256. Either way it preserves the
        prior ISO as <baseImageName>.previous.iso and writes the sentinel
        <baseImageName>.txt with @(filename, url, byteCount).

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
    $downloadFile    = Join-Path $DownloadDir 'downloaded.iso'

    # --- REGION: https://yuruna.link/42ec97cd-0004
    # Ask the download agent before the origin is touched at all: when it
    # confirms the local copy IS the current artifact there is nothing to
    # resolve, HEAD-probe or transfer. Both the client module and a healthy
    # agent are feature-detected, so a lab with no agent -- or one whose agent
    # is down, has no pool, or errors mid-request -- falls through to the
    # resolve / same-source guard / download pipeline below.
    $agentServed       = $false
    $agentLastModified = ''
    $agentImageKey = switch ($ReleaseCodename) {
        'noble'    { 'guest.ubuntu.server.24' }
        'resolute' { 'guest.ubuntu.server.26' }
        default    { '' }
    }
    # The pool keys images by the host/ directory name; every caller's
    # BaseImageName already carries it as the "host.<host type>." prefix.
    $agentHostType = ''
    if ($BaseImageName -match '^host\.(windows\.hyper-v|ubuntu\.kvm|macos\.utm)\.') { $agentHostType = $Matches[1] }
    $agentProbe = Invoke-DownloadAgentFirst -HostType $agentHostType -ImageKey $agentImageKey -Arch $Arch -Variant $(if ($PreferDaily) { 'daily' } else { 'stable' }) -StagingPath $downloadFile -BaseImageFile $baseImageFile -OriginFile $baseImageOrigin
    $agentBaseUrl = $agentProbe.BaseUrl
    $agentResult = $agentProbe.Result
    if ($agentResult -and $agentResult.outcome -eq 'skipped') {
        $msg = "Skipping download: the download agent at $agentBaseUrl confirms $baseImageFile is the current $agentImageKey artifact. To force a re-download, delete or rename: $baseImageFile"
        Write-Information $msg -InformationAction Continue
        return 'skipped'
    } elseif ($agentResult -and $agentResult.outcome -eq 'downloaded') {
        $agentServed       = $true
        $isoFileName       = [string]$agentResult.filename
        $sourceUrl         = [string]$agentResult.sourceUrl
        $agentLastModified = [string]$agentResult.lastModified
        $downloadedSize    = (Get-Item -LiteralPath $downloadFile).Length
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_fcfb9dfaf41b6f33' -Arguments @{ agentBaseUrl = "$agentBaseUrl"; isoFileName = "$isoFileName"; downloadedSize = "$downloadedSize"; downloadFile = "$downloadFile" }) -InformationAction Continue
    } elseif ($agentResult) {
        $detail = if ($agentResult.error) { ": $($agentResult.error)" } else { '' }
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_eacd62147f05f2a6' -Arguments @{ agentBaseUrl = "$agentBaseUrl"; outcome = "$($agentResult.outcome)"; detail = "$detail" })
    }

    if (-not $agentServed) {
        # --- REGION: Resolve the published image URL
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
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_2e4bf1ca08afac07' -Arguments @{ variant = "$($resolved.Variant)"; isoFileName = "$isoFileName" }) -InformationAction Continue

        New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null

        # --- REGION: https://yuruna.link/42ec97cd-0006
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

        # --- REGION: Download the image
        Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_db76a809c970c1de' -Arguments @{ sourceUrl = "$sourceUrl"; downloadFile = "$downloadFile" }) -InformationAction Continue
        try {
            if (Get-Command -Name Save-CachedHttpUri -ErrorAction SilentlyContinue) {
                Save-CachedHttpUri -Uri $sourceUrl -OutFile $downloadFile
            } else {
                Invoke-WebRequest -Uri $sourceUrl -OutFile $downloadFile -ErrorAction Stop
            }
        } catch {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_78d93fd740dd1ed5' -Arguments @{ message = "$($_.Exception.Message)" })
        }
        $downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

        # --- REGION: Verify the published checksum
        if (-not (Test-UbuntuServerImageChecksum -ChecksumUrl $checksumUrl -IsoFileName $isoFileName -DownloadFile $downloadFile)) {
            # Hard-fail on a genuine checksum MISMATCH (corruption or tamper,
            # never benign) and on a SHA256SUMS fetch still failing after the
            # bounded retry budget -- unverifiable bytes must not be promoted.
            # Only a definitively MISSING upstream checksum (HTTP 403/404/410 or
            # no line for this ISO) is a soft pass, and that returns $true from
            # Test-UbuntuServerImageChecksum and never reaches here.
            Remove-Item -LiteralPath $downloadFile -Force -ErrorAction SilentlyContinue
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_9bbc5dc302229fc3' -Arguments @{ isoFileName = "$isoFileName" })
        }
    }

    # --- REGION: Preserve previous and finalize
    $previousFile = Join-Path $DownloadDir "$BaseImageName.previous.iso"
    Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $baseImageFile) {
        Move-Item -Path $baseImageFile -Destination $previousFile
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_3484688671544ee8' -Arguments @{ previousFile = "$previousFile" }) -InformationAction Continue
    }
    Move-Item -Path $downloadFile -Destination $baseImageFile

    # Write the sentinel in the SAME format the skip-guard above reads back: the
    # 4-line shape (filename + URL + size + Last-Modified) via Write-ImageSentinel
    # when the host driver ships Test-DownloadAlreadyCurrent, else the bundled
    # 3-line shape that Test-UbuntuServerImageAlreadyCurrent reads. An asymmetric
    # writer/reader pair never matches, so the skip-guard would re-download every
    # run.
    if (Get-Command -Name Test-DownloadAlreadyCurrent -ErrorAction SilentlyContinue) {
        if ($agentServed) {
            # Last-Modified comes from the agent's record of the origin
            # response. Letting Write-ImageSentinel HEAD the origin here would
            # re-touch the very server the agent path exists to spare, and on
            # an unreachable origin would record an empty 4th line for bytes
            # whose timestamp is known.
            Write-ImageSentinel -SourceUrl $sourceUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -LastModified $agentLastModified -Confirm:$false
        } else {
            Write-ImageSentinel -SourceUrl $sourceUrl -OriginFile $baseImageOrigin -SizeBytes $downloadedSize -Confirm:$false
        }
    } else {
        Set-Content -Path $baseImageOrigin -Value @($isoFileName, $sourceUrl, "$downloadedSize")
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_c0d4de13cd8a131d' -Arguments @{ baseImageOrigin = "$baseImageOrigin" }) -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_f8db1971afed42d8' -Arguments @{ baseImageFile = "$baseImageFile" }) -InformationAction Continue
    return 'downloaded'
}

# --- REGION: Exports
Export-ModuleMember -Function `
    Get-UbuntuServerImageManifestUrl, `
    Resolve-UbuntuServerImage, `
    Test-UbuntuServerImageChecksum, `
    Test-UbuntuServerImageAlreadyCurrent, `
    Save-UbuntuServerImage, `
    Write-UbuntuImageProxyDiagnostic
