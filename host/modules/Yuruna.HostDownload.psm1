<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42d93b11-69e5-4250-b84e-294562b68efd
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host download squid caching-proxy-service
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

# Shared squid caching-proxy-service download stack for the host drivers. Why
# Resolve-CacheHostIp is injected rather than called by name, and the per-driver
# import/re-export contract:
# docs/guest-image-setup.md#cache-routed-downloads-yurunahostdownloadpsm1

# Own the dependencies (Get-CachingProxyServicePort, Format-IpUrlHost) rather than
# assuming a caller imported Yuruna.Common into a visible scope.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -DisableNameChecking -ErrorAction SilentlyContinue

function Test-CachingProxyServicePort {
    <#
    .SYNOPSIS
        Async TCP port probe with a bounded wait. $true when $IpAddress:$Port
        accepts within $TimeoutMs. BeginConnect+WaitOne caps the wait
        predictably; a synchronous TcpClient.Connect() blocks ~20s on a
        filtered/dropped port.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 500
    )
    $tcp = [System.Net.Sockets.TcpClient]::new()
    try {
        $h = $tcp.BeginConnect($IpAddress, $Port, $null, $null)
        return ($h.AsyncWaitHandle.WaitOne($TimeoutMs) -and $tcp.Connected)
    } catch {
        Write-Verbose "Test-CachingProxyServicePort ${IpAddress}:${Port} failed: $($_.Exception.Message)"
        return $false
    } finally {
        $tcp.Close()
    }
}

function Test-DownloadAlreadyCurrent {
    <#
    .SYNOPSIS
        Same-source guard: $true when the prior sentinel (filename, URL, byte
        count, Last-Modified) still matches a fresh HEAD of $SourceUrl, so the
        cached base image can be reused without re-downloading.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$SourceUrl,
        [Parameter(Mandatory)][string]$BaseImageFile,
        [Parameter(Mandatory)][string]$OriginFile
    )
    if (-not (Test-Path -LiteralPath $BaseImageFile)) {
        Write-Verbose "Test-DownloadAlreadyCurrent: base image file missing ($BaseImageFile); will download."
        return $false
    }
    if (-not (Test-Path -LiteralPath $OriginFile)) {
        Write-Verbose "Test-DownloadAlreadyCurrent: sentinel file missing ($OriginFile); will download."
        return $false
    }

    $lines = @(Get-Content -LiteralPath $OriginFile -ErrorAction SilentlyContinue)
    if ($lines.Count -lt 4) {
        Write-Verbose "Test-DownloadAlreadyCurrent: sentinel has only $($lines.Count) line(s); the 4-line format with Last-Modified is required, will re-download to refresh."
        return $false
    }

    $sentinelFilename = $lines[0].Trim()
    $sentinelUrl      = $lines[1].Trim()
    $sentinelSizeRaw  = $lines[2].Trim()
    $sentinelLastMod  = $lines[3].Trim()

    $expectedFilename = [System.IO.Path]::GetFileName(([System.Uri]$SourceUrl).LocalPath)
    if ($sentinelFilename -ne $expectedFilename) {
        Write-Verbose "Test-DownloadAlreadyCurrent: sentinel filename '$sentinelFilename' != URL filename '$expectedFilename'; will download. (This is what catches a noble->resolute style URL change.)"
        return $false
    }
    if ($sentinelUrl -ne $SourceUrl) {
        Write-Verbose "Test-DownloadAlreadyCurrent: sentinel URL '$sentinelUrl' != requested URL '$SourceUrl'; will download."
        return $false
    }
    $previousSize = 0L
    if (-not [int64]::TryParse($sentinelSizeRaw, [ref]$previousSize) -or $previousSize -le 0) {
        Write-Verbose "Test-DownloadAlreadyCurrent: sentinel byte count '$sentinelSizeRaw' is not a positive integer; will download."
        return $false
    }

    try {
        $head = Invoke-WebRequest -Uri $SourceUrl -Method Head -ErrorAction Stop
    } catch {
        Write-Verbose "Test-DownloadAlreadyCurrent: HEAD probe of $SourceUrl failed: $($_.Exception.Message); will download."
        return $false
    }
    $cl = $head.Headers['Content-Length']
    if ($cl -is [System.Array]) { $cl = $cl[0] }
    $expectedSize = 0L
    if (-not [int64]::TryParse([string]$cl, [ref]$expectedSize)) {
        Write-Verbose "Test-DownloadAlreadyCurrent: HEAD response has no usable Content-Length; will download."
        return $false
    }
    if ($expectedSize -ne $previousSize) {
        Write-Verbose "Test-DownloadAlreadyCurrent: size mismatch (sentinel=$previousSize, HEAD=$expectedSize); will download."
        return $false
    }
    # Last-Modified check, lenient when either side lacks the header.
    $headLm = $head.Headers['Last-Modified']
    if ($headLm -is [System.Array]) { $headLm = $headLm[0] }
    $headLastMod = [string]$headLm
    if ($sentinelLastMod -and $headLastMod -and ($sentinelLastMod -ne $headLastMod)) {
        Write-Verbose "Test-DownloadAlreadyCurrent: Last-Modified differs (sentinel='$sentinelLastMod', HEAD='$headLastMod'); will download."
        return $false
    }
    Write-Verbose "Test-DownloadAlreadyCurrent: match (filename='$sentinelFilename', size=$previousSize, last-modified='$sentinelLastMod'); skipping."
    return $true
}

function Write-ImageSentinel {
    <#
    .SYNOPSIS
        Write the 4-line image sentinel (filename, source URL, byte count,
        Last-Modified) that Test-DownloadAlreadyCurrent reads back.
    .DESCRIPTION
        One writer for every Get-Image path, so the sentinel shape stays in
        lockstep with the reader: the filename is derived from the URL the SAME
        way the reader expects it, closing the noble->resolute URL-bump
        regression a 3-line sentinel silently misses. When -LastModified is
        omitted a HEAD probe captures what the server reports at fetch time; a
        server that strips the header records an empty 4th line, which the
        reader treats as "no Last-Modified comparison possible" (URL + size
        still gate the skip).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SourceUrl,
        [Parameter(Mandatory)][string]$OriginFile,
        [Parameter(Mandatory)][int64]$SizeBytes,
        [string]$LastModified
    )
    $filename = [System.IO.Path]::GetFileName(([System.Uri]$SourceUrl).LocalPath)
    if (-not $PSBoundParameters.ContainsKey('LastModified')) {
        $LastModified = ''
        try {
            $head = Invoke-WebRequest -Uri $SourceUrl -Method Head -ErrorAction Stop
            $lm = $head.Headers['Last-Modified']
            if ($lm -is [System.Array]) { $lm = $lm[0] }
            $LastModified = [string]$lm
        } catch {
            Write-Verbose "Write-ImageSentinel: Last-Modified HEAD probe failed (recording empty): $($_.Exception.Message)"
        }
    }
    if ($PSCmdlet.ShouldProcess($OriginFile, (Format-YurunaOperatorMessage -Key 'host.operator_b3a4a5bafc255b3c'))) {
        Set-Content -LiteralPath $OriginFile -Value @($filename, $SourceUrl, "$SizeBytes", "$LastModified")
    }
}

function Invoke-DownloadWithRetry {
    <#
    .SYNOPSIS
        Bounded retry around a download scriptblock, driven by a wall-clock deadline (not an
        attempt count), for transient network failures on CA / image / checksum fetches.
        Re-throws the last error once the deadline is exhausted so callers still fail closed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Download,
        [int]$TimeoutSeconds = 60,
        [int]$InitialBackoffSeconds = 2,
        [int]$MaxBackoffSeconds = 15
    )
    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds))
    $backoff = [Math]::Max(1, $InitialBackoffSeconds)
    $attempt = 0
    while ($true) {
        $attempt++
        try { & $Download; return }
        catch {
            if ([DateTime]::UtcNow -ge $deadline) { throw }
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b9071f2223cd19e1' -Arguments @{ attempt = "$attempt"; message = "$($_.Exception.Message)"; backoff = "${backoff}" })
            Start-Sleep -Seconds $backoff
            $backoff = [Math]::Min($backoff * 2, $MaxBackoffSeconds)
        }
    }
}

function Get-CacheProxyForHostDownload {
    <#
    .SYNOPSIS
        Returns a proxy config hashtable @{ Proxy; CaPemPath } for routing $Uri
        through the squid cache, or $null to go direct. The platform-specific
        cache-IP discovery is injected as -ResolveCacheHostIp (a scriptblock the
        driver supplies as a closure over its own Resolve-CacheHostIp).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][scriptblock]$ResolveCacheHostIp
    )

    $httpPort  = Get-CachingProxyServicePort -Scheme http
    $httpsPort = Get-CachingProxyServicePort -Scheme https

    $scheme = ([System.Uri]$Uri).Scheme.ToLowerInvariant()
    if ($scheme -ne 'http' -and $scheme -ne 'https') {
        Write-Verbose "Get-CacheProxyForHostDownload: scheme '$scheme' not http(s); going direct."
        return $null
    }

    $cacheIp = & $ResolveCacheHostIp
    if (-not $cacheIp) {
        Write-Verbose "Get-CacheProxyForHostDownload: no squid cache reachable on :${httpPort}; going direct."
        return $null
    }

    $cacheHost = Format-IpUrlHost $cacheIp
    if ($scheme -eq 'http') {
        return @{ Proxy = "http://${cacheHost}:${httpPort}"; CaPemPath = $null }
    }

    # HTTPS via SSL-bump on the HTTPS port -- needs the apache CA endpoint on
    # :80 AND the SSL-bump listener. Probe both before committing.
    if (-not (Test-CachingProxyServicePort -IpAddress $cacheIp -Port $httpsPort -TimeoutMs 500)) {
        Write-Verbose "Get-CacheProxyForHostDownload: squid :${httpsPort} not reachable on $cacheIp; HTTPS goes direct."
        return $null
    }
    if (-not (Test-CachingProxyServicePort -IpAddress $cacheIp -Port 80 -TimeoutMs 500)) {
        Write-Verbose "Get-CacheProxyForHostDownload: apache :80 not reachable on $cacheIp (cannot fetch CA); HTTPS goes direct."
        return $null
    }
    $caUrl = "http://${cacheHost}/yuruna-squid-ca.crt"
    # One file per call, removed by the caller once the download is done: a
    # shared fixed name would be deleted under a concurrent download, and kept
    # for good otherwise.
    $caPem = Join-Path ([System.IO.Path]::GetTempPath()) ('yuruna-squid-ca-' + [Guid]::NewGuid().ToString('N') + '.pem')
    try {
        # Retry the CA fetch on a transient blip: a single failed fetch here otherwise drops the
        # guest to a bumped-but-untrusted chain (empty-CA class) with no HTTPS fallback.
        Invoke-DownloadWithRetry -TimeoutSeconds 30 -Download {
            Invoke-WebRequest -Uri $caUrl -OutFile $caPem -ErrorAction Stop -UseBasicParsing | Out-Null
        }
    } catch {
        Write-Verbose "Get-CacheProxyForHostDownload: CA fetch from $caUrl failed after retries: $($_.Exception.Message); HTTPS goes direct."
        Remove-Item -LiteralPath $caPem -Force -ErrorAction SilentlyContinue
        return $null
    }
    # The CA came over plain HTTP, so a download trusts it only when it is a root
    # this host trusts for that proxy; anything else sends HTTPS direct, which
    # is slower but cannot be intercepted through the proxy.
    $verdict = $null
    try {
        if (-not (Get-Command Resolve-YurunaPinnedProxyCa -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $PSScriptRoot '../../test/modules/Test.CachingProxyService.psm1') -Global -DisableNameChecking -WarningAction SilentlyContinue
        }
        $verdict = Resolve-YurunaPinnedProxyCa -Pem ([IO.File]::ReadAllText($caPem)) -CacheHost $cacheIp -Statement (Get-CachingProxyServiceCaStatement -CacheHost $cacheIp)
    } catch { Write-Verbose "Get-CacheProxyForHostDownload: CA trust check failed: $($_.Exception.Message)" }
    if (-not $verdict -or -not $verdict.Accepted) {
        if ($verdict) { Write-YurunaProxyCaRefusal -CacheHost $cacheIp -Verdict $verdict }
        Remove-Item -LiteralPath $caPem -Force -ErrorAction SilentlyContinue
        return $null
    }
    return @{ Proxy = "http://${cacheHost}:${httpsPort}"; CaPemPath = $caPem }
}

function Save-CachedHttpUri {
    <#
    .SYNOPSIS
        Download $Uri to $OutFile, routing through the squid cache when one is
        reachable (HTTP proxy, or HTTPS via the SSL-bump path), else direct.
        -ResolveCacheHostIp is the driver-supplied cache-IP discovery closure;
        omit it (or pass $null) to download direct with no cache lookup.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [scriptblock]$ResolveCacheHostIp
    )
    # See https://yuruna.link/42e220c4-0003
    # Every path runs on the resumable engine, so a transfer cut short resumes
    # at its next attempt instead of starting over.
    if (-not $ResolveCacheHostIp) {
        $null = Invoke-YurunaResumableDownload -Uri $Uri -OutFile $OutFile
        return
    }
    $cfg = Get-CacheProxyForHostDownload -Uri $Uri -ResolveCacheHostIp $ResolveCacheHostIp
    if (-not $cfg) {
        $null = Invoke-YurunaResumableDownload -Uri $Uri -OutFile $OutFile
        return
    }
    if (-not $cfg.CaPemPath) {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_6324f0717ba924d0' -Arguments @{ proxy = "$($cfg.Proxy)" }) -InformationAction Continue
        $null = Invoke-YurunaResumableDownload -Uri $Uri -OutFile $OutFile -ProxyUrl $cfg.Proxy
        return
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_103c960e4cbdd8a2' -Arguments @{ proxy = "$($cfg.Proxy)"; caPemPath = "$($cfg.CaPemPath)" }) -InformationAction Continue
    try {
        Invoke-HttpsViaSquidBump -Uri $Uri -OutFile $OutFile -ProxyUrl $cfg.Proxy -CaPemPath $cfg.CaPemPath
    } finally {
        Remove-Item -LiteralPath $cfg.CaPemPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-SquidBumpCertValidator {
    <#
    .SYNOPSIS
        Compiled-delegate certificate validator for the squid SSL-bump leaf:
        accept iff the chain (seeded with $ExtraCa) roots at $ExtraCa by
        thumbprint, mirroring the pinned-CA policy.
    .DESCRIPTION
        Returned as a C# delegate rather than a scriptblock because HttpClient
        invokes ServerCertificateCustomValidationCallback on a TLS worker
        thread that has no PowerShell runspace: a scriptblock there throws
        "There is no Runspace available to run scripts in this thread" and
        fails every handshake. The type compiles once per process (guarded)
        and is idempotent across -Force module re-imports.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$ExtraCa)
    if (-not ('YurunaSquidCertValidator' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Net.Http;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class YurunaSquidCertValidator
{
    public static Func<HttpRequestMessage, X509Certificate2, X509Chain, SslPolicyErrors, bool> Make(X509Certificate2 extraCa)
    {
        string expectedThumb = extraCa.Thumbprint;
        return (req, cert, chain, errors) =>
        {
            if ((errors & SslPolicyErrors.RemoteCertificateNotAvailable) != 0) return false;
            if ((errors & SslPolicyErrors.RemoteCertificateNameMismatch) != 0) return false;
            if ((errors & SslPolicyErrors.RemoteCertificateChainErrors) == 0) return true;
            using (var extraChain = new X509Chain())
            {
                extraChain.ChainPolicy.ExtraStore.Add(extraCa);
                extraChain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
                extraChain.ChainPolicy.VerificationFlags = X509VerificationFlags.AllowUnknownCertificateAuthority;
                if (!extraChain.Build(cert)) return false;
                var root = extraChain.ChainElements[extraChain.ChainElements.Count - 1].Certificate;
                return string.Equals(root.Thumbprint, expectedThumb, StringComparison.OrdinalIgnoreCase);
            }
        };
    }
}
'@
    }
    return [YurunaSquidCertValidator]::Make($ExtraCa)
}

function Invoke-HttpsViaSquidBump {
    <#
    .SYNOPSIS
        Stream $Uri to $OutFile through the squid SSL-bump proxy, trusting only
        the cache's CA at $CaPemPath (per-process, via a compiled validator),
        on the resumable download engine.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][string]$ProxyUrl,
        [Parameter(Mandatory)][string]$CaPemPath,
        [datetime]$Deadline = [datetime]::UtcNow.AddHours(2),
        [ValidateRange(1, 3600)][int]$IdleTimeoutSeconds = 60
    )
    $null = Invoke-YurunaResumableDownload -Uri $Uri -OutFile $OutFile -ProxyUrl $ProxyUrl -CaPemPath $CaPemPath `
        -Deadline $Deadline -IdleTimeoutSeconds $IdleTimeoutSeconds -Activity "Downloading $Uri (via squid SSL-bump)"
}

function Read-YurunaDownloadSidecar {
    <#
    .SYNOPSIS
        The record beside a partial download: the URI it came from, the
        validator the server sent, and the full length when known; $null when
        there is none or it does not parse.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { $record = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { return $null }
    if ($record -isnot [System.Collections.IDictionary]) { return $null }
    $length = 0L
    $null = [int64]::TryParse([string]$record['length'], [ref]$length)
    return @{ uri = [string]$record['uri']; etag = [string]$record['etag']; lastModified = [string]$record['lastModified']; length = $length }
}

function Invoke-YurunaResumableDownload {
    <#
    .SYNOPSIS
        Download $Uri to $OutFile through the one HttpClient engine every image
        path uses (origin, squid proxy, squid SSL-bump, download agent), resuming
        a transfer an earlier attempt or process left part-way.
    .DESCRIPTION
        Bytes go to <OutFile>.partial, and <OutFile>.partial.json records the
        URI, the validator the server sent (a strong ETag, else Last-Modified)
        and the full length. A later attempt for the same URI asks for the
        remainder with Range and If-Range: a 206 that continues at the right
        offset is appended, and any other answer -- a server that ignored the
        range, or an entity that changed under its validator -- starts the file
        again from zero. A transfer with no validator cannot prove the
        remainder belongs to the same bytes, so it is never resumed unless the
        caller says the URI names immutable bytes (-AssumeImmutable).

        Only a complete transfer is renamed to $OutFile. A failed one keeps the
        partial and its record, so the next attempt -- in this call, a later
        retry, or a later cycle after the step watchdog ended this one -- pays
        only for the bytes still missing. A refusal that no retry changes (an
        HTTP 4xx other than 408, 425 and 429) is thrown at once, with its
        status in the message for the caller's classification.
    .PARAMETER ProxyUrl
        HTTP proxy for the request: the squid HTTP port, or its SSL-bump port.
    .PARAMETER CaPemPath
        With -ProxyUrl: trust only this CA for the TLS the proxy re-signs.
    .PARAMETER ExpectedByteCount
        The full length when the caller already knows it, or 0.
    .PARAMETER AssumeImmutable
        The URI names one immutable artifact (a content-named download-agent
        generation), so a transfer resumes without a validator.
    .PARAMETER Deadline
        UTC wall-clock deadline for this call.
    .PARAMETER IdleTimeoutSeconds
        Longest wait for response headers or the next bytes.
    .PARAMETER MaxAttempt
        Requests this call may send, resuming between them.
    .OUTPUTS
        [int64] the size of $OutFile.
    #>
    [CmdletBinding()]
    [OutputType([int64])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$ProxyUrl,
        [string]$CaPemPath,
        [int64]$ExpectedByteCount = 0,
        [switch]$AssumeImmutable,
        [datetime]$Deadline = [datetime]::UtcNow.AddHours(2),
        [ValidateRange(1, 3600)][int]$IdleTimeoutSeconds = 60,
        [ValidateRange(1, 20)][int]$MaxAttempt = 3,
        [string]$Activity
    )
    if (-not $Activity) { $Activity = "Downloading $Uri" }
    $partial = "$OutFile.partial"
    $sidecarPath = "$partial.json"
    $parent = Split-Path -Parent $OutFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop }
    $state = Read-YurunaDownloadSidecar -Path $sidecarPath
    if (-not $state -or $state.uri -cne $Uri -or (-not $AssumeImmutable -and -not $state.etag -and -not $state.lastModified)) {
        $state = $null
        Remove-Item -LiteralPath $partial, $sidecarPath -Force -ErrorAction SilentlyContinue
    }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $extraCa = $null
    if ($ProxyUrl) {
        $handler.UseProxy = $true
        $handler.Proxy = [System.Net.WebProxy]::new([System.Uri]$ProxyUrl, $true)
    }
    if ($CaPemPath) {
        # yuruna-squid-ca.crt is a cert-only PEM, so CreateFromPemFile (which
        # expects cert+key in one file) is not an option. Load from the DER bytes
        # parsed out of the PEM rather than the X509Certificate2 file constructor:
        # its PEM auto-detection goes through the platform crypto backend, which
        # reads PEM on Windows but FAILS on macOS. DER bytes load identically on
        # every platform.
        $caPemText = [System.IO.File]::ReadAllText($CaPemPath)
        $caDerB64  = (($caPemText -split "`r?`n") | Where-Object { $_ -and ($_ -notmatch 'CERTIFICATE') }) -join ''
        $extraCa   = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($caDerB64))
        # A compiled C# delegate, not a scriptblock: the callback fires on
        # HttpClient's TLS worker thread, which has no PowerShell runspace.
        $handler.ServerCertificateCustomValidationCallback = Get-SquidBumpCertValidator -ExtraCa $extraCa
    }
    $client = [System.Net.Http.HttpClient]::new($handler, $true)
    # No client-level timeout: a cold multi-GB image legitimately takes hours;
    # the deadline and the idle timeout are what bound this call.
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $null = $client.DefaultRequestHeaders.UserAgent.TryParseAdd("Yuruna PowerShell/$($PSVersionTable.PSVersion)")
    $complete = $false
    $lastError = ''
    try {
        for ($attempt = 1; $attempt -le $MaxAttempt -and -not $complete; $attempt++) {
            if ([datetime]::UtcNow -ge $Deadline) { $lastError = 'the deadline expired'; break }
            $offset = if (Test-Path -LiteralPath $partial) { (Get-Item -LiteralPath $partial).Length } else { 0L }
            if ($state -and $state.length -gt 0 -and $offset -eq $state.length) { $complete = $true; break }
            try {
                $answer = Receive-YurunaDownloadResponse -Client $client -Uri $Uri -Partial $partial -SidecarPath $sidecarPath `
                    -State $state -Offset $offset -ExpectedByteCount $ExpectedByteCount `
                    -Deadline $Deadline -IdleTimeoutSeconds $IdleTimeoutSeconds -Activity $Activity
                $state = $answer.State
                $complete = [bool]$answer.Complete
                if (-not $complete) { $lastError = "the transfer ended at $((Get-Item -LiteralPath $partial).Length) of $($state.length) byte(s)" }
            } catch {
                $lastError = $_.Exception.Message
                if ($_.Exception.Data.Contains('YurunaTerminal')) { throw }
                $state = Read-YurunaDownloadSidecar -Path $sidecarPath
                Write-Verbose "Invoke-YurunaResumableDownload: attempt $attempt of $Uri failed: $lastError"
            }
        }
    } finally {
        Write-Progress -Activity $Activity -Completed
        $client.Dispose()
        if ($extraCa) { $extraCa.Dispose() }
    }
    if (-not $complete) {
        $have = if (Test-Path -LiteralPath $partial) { (Get-Item -LiteralPath $partial).Length } else { 0L }
        throw (Format-YurunaOperatorMessage -Key 'host.download_incomplete' -Arguments @{ uri = "$Uri"; bytes = "$have"; detail = "$lastError" })
    }
    Move-Item -LiteralPath $partial -Destination $OutFile -Force -ErrorAction Stop
    Remove-Item -LiteralPath $sidecarPath -Force -ErrorAction SilentlyContinue
    return (Get-Item -LiteralPath $OutFile).Length
}

function Receive-YurunaDownloadResponse {
    <#
    .SYNOPSIS
        One GET of the resumable engine: ranged when bytes are already staged,
        copied onto the partial file.
    .OUTPUTS
        [hashtable] @{ Complete = [bool]; State = sidecar record }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Partial,
        [Parameter(Mandatory)][string]$SidecarPath,
        [AllowNull()][hashtable]$State,
        [int64]$Offset = 0,
        [int64]$ExpectedByteCount = 0,
        [datetime]$Deadline = [datetime]::MaxValue,
        [ValidateRange(1, 3600)][int]$IdleTimeoutSeconds = 60,
        [Parameter(Mandatory)][string]$Activity
    )
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, [System.Uri]$Uri)
    $ranged = $Offset -gt 0 -and $State
    if ($ranged) {
        $request.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new($Offset, $null)
        if ($State.etag) {
            $request.Headers.IfRange = [System.Net.Http.Headers.RangeConditionHeaderValue]::new([System.Net.Http.Headers.EntityTagHeaderValue]::Parse($State.etag))
        } elseif ($State.lastModified) {
            $request.Headers.IfRange = [System.Net.Http.Headers.RangeConditionHeaderValue]::new(
                [DateTimeOffset]::Parse($State.lastModified, [System.Globalization.CultureInfo]::InvariantCulture))
        }
    }
    $deadlineCancellation = [System.Threading.CancellationTokenSource]::new()
    if ($Deadline -ne [datetime]::MaxValue) {
        $remaining = [Math]::Max(0, ($Deadline - [datetime]::UtcNow).TotalMilliseconds)
        $deadlineCancellation.CancelAfter([int][Math]::Min([int]::MaxValue, $remaining))
    }
    $idleCancellation = [System.Threading.CancellationTokenSource]::CreateLinkedTokenSource($deadlineCancellation.Token)
    $response = $null
    try {
        $idleCancellation.CancelAfter([TimeSpan]::FromSeconds($IdleTimeoutSeconds))
        $response = $Client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $idleCancellation.Token).GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        $range = $response.Content.Headers.ContentRange
        if ($status -eq 416) {
            # Nothing past the offset: the staged bytes are whole when the
            # server's length says so, and otherwise start again.
            if ($range -and $range.Length -eq $Offset) {
                $State.length = $Offset
                return @{ Complete = $true; State = $State }
            }
            Remove-Item -LiteralPath $Partial, $SidecarPath -Force -ErrorAction SilentlyContinue
            throw "the server refused the range from byte $Offset"
        }
        if (-not $response.IsSuccessStatusCode) {
            $failure = [System.InvalidOperationException]::new((Format-YurunaOperatorMessage -Key 'exceptions.host_3fa13d65fc1bcf6d' -Arguments @{ statusCode = "$status"; reasonPhrase = "$($response.ReasonPhrase)"; uri = "$Uri" }))
            if ($status -ge 400 -and $status -lt 500 -and $status -notin @(408, 425, 429)) { $failure.Data['YurunaTerminal'] = $true }
            throw $failure
        }
        $append = $ranged -and $status -eq 206 -and $range -and $range.From -eq $Offset
        if ($ranged -and $status -eq 206 -and -not $append) {
            Remove-Item -LiteralPath $Partial, $SidecarPath -Force -ErrorAction SilentlyContinue
            throw "the server continued at byte $($range.From) instead of $Offset"
        }
        if (-not $append) {
            # A fresh transfer, or a server that answered a ranged request in
            # full (it ignored the range, or the entity changed under its
            # validator): record what this response describes before its bytes.
            $etag = $response.Headers.ETag
            $State = @{
                uri          = $Uri
                etag         = $(if ($etag -and -not $etag.IsWeak) { $etag.ToString() } else { '' })
                lastModified = $(if ($response.Content.Headers.LastModified) { $response.Content.Headers.LastModified.Value.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' })
                # A length the caller already knows wins over this response's:
                # a relay that cut the body short can also send a short length.
                length       = $(if ($ExpectedByteCount -gt 0) { $ExpectedByteCount } elseif ($response.Content.Headers.ContentLength) { [int64]$response.Content.Headers.ContentLength } else { 0L })
            }
            [System.IO.File]::WriteAllText($SidecarPath, (ConvertTo-Json -Compress -InputObject $State))
        } elseif ($State.length -le 0 -and $range.Length) {
            $State.length = [int64]$range.Length
            [System.IO.File]::WriteAllText($SidecarPath, (ConvertTo-Json -Compress -InputObject $State))
        }
        $mode = if ($append) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        try {
            $out = [System.IO.FileStream]::new($Partial, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            try {
                $buffer = [byte[]]::new(256 * 1024)
                $written = if ($append) { $Offset } else { 0L }
                $next = [datetime]::UtcNow.AddSeconds(2)
                while ($true) {
                    $idleCancellation.CancelAfter([TimeSpan]::FromSeconds($IdleTimeoutSeconds))
                    $read = $stream.ReadAsync($buffer, 0, $buffer.Length, $idleCancellation.Token).GetAwaiter().GetResult()
                    if ($read -eq 0) { break }
                    $out.Write($buffer, 0, $read)
                    $written += $read
                    if ([datetime]::UtcNow -gt $next) {
                        if ($State.length -gt 0) {
                            $pct = [Math]::Min(100, [Math]::Round($written * 100.0 / $State.length, 1))
                            Write-Progress -Activity $Activity -Status (Format-YurunaOperatorMessage -Key 'host.operator_ede646f387ba0602' -FormatValues (($written / 1MB), ($State.length / 1MB), $pct) -FormatBindings @{ mB = '0:N1'; mB2 = '1:N1'; pct = '2' }) -PercentComplete $pct
                        } else {
                            Write-Progress -Activity $Activity -Status (Format-YurunaOperatorMessage -Key 'host.operator_e12c13989dfbd234' -FormatValues (($written / 1MB)) -FormatBindings @{ mB = '0:N1' })
                        }
                        $next = [datetime]::UtcNow.AddSeconds(2)
                    }
                }
            } finally { $out.Dispose() }
        } finally { $stream.Dispose() }
        $have = (Get-Item -LiteralPath $Partial).Length
        if ($State.length -gt 0 -and $have -gt $State.length) {
            Remove-Item -LiteralPath $Partial, $SidecarPath -Force -ErrorAction SilentlyContinue
            throw "the transfer ran past its length ($have of $($State.length) byte(s))"
        }
        # With no length to compare, a body that ended without an error is the
        # whole of it.
        return @{ Complete = ($State.length -le 0 -or $have -eq $State.length); State = $State }
    } finally {
        if ($response) { $response.Dispose() }
        $request.Dispose()
        $idleCancellation.Dispose()
        $deadlineCancellation.Dispose()
    }
}

# --- REGION: Exports
Export-ModuleMember -Function Test-CachingProxyServicePort, Test-DownloadAlreadyCurrent, Write-ImageSentinel, Get-CacheProxyForHostDownload, Save-CachedHttpUri, Invoke-HttpsViaSquidBump, `
    Invoke-YurunaResumableDownload
