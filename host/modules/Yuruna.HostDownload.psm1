<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42e0d1c8-9b3a-4f52-8c61-7d2e4a9b0f33
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host download squid caching-proxy
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

# Shared squid caching-proxy download stack for the host drivers
# (Test-DownloadAlreadyCurrent, Get-CacheProxyForHostDownload, Save-CachedHttpUri,
# Invoke-HttpsViaSquidBump, plus the TCP port probe). Defined once here so a
# hardening fix to the X509 chain-validation callback lands in one place and
# cannot drift between drivers. The only genuinely platform-specific piece --
# discovering the cache VM's IP -- stays per-driver (Resolve-CacheHostIp) and is
# INJECTED as a scriptblock so this module never reaches across a module boundary
# by name (which would be fragile under -Force re-imports; see
# feedback_module_force_import_evicts_global.md).
#
# Each driver imports this module (non-Global) into its own scope, keeps its own
# Resolve-CacheHostIp, and re-exports the names its callers use. The driver's
# thin Save-CachedHttpUri wrapper passes { Resolve-CacheHostIp } so the closure
# resolves the driver's own discovery while executing inside this module.

# Own the dependencies (Get-CachingProxyPort, Format-IpUrlHost) rather than
# assuming a caller imported Yuruna.Common into a visible scope.
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -DisableNameChecking -ErrorAction SilentlyContinue

function Test-CachingProxyPort {
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
        Write-Verbose "Test-CachingProxyPort ${IpAddress}:${Port} failed: $($_.Exception.Message)"
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
        One writer for every KVM Get-Image script so the sentinel shape stays
        in lockstep with the reader: the filename is derived from the URL the
        SAME way the reader expects it, closing the noble->resolute URL-bump
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
    if ($PSCmdlet.ShouldProcess($OriginFile, 'Write 4-line image sentinel')) {
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
            Write-Warning "Download attempt $attempt failed ($($_.Exception.Message)); retrying in ${backoff}s."
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

    $httpPort  = Get-CachingProxyPort -Scheme http
    $httpsPort = Get-CachingProxyPort -Scheme https

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
    if (-not (Test-CachingProxyPort -IpAddress $cacheIp -Port $httpsPort -TimeoutMs 500)) {
        Write-Verbose "Get-CacheProxyForHostDownload: squid :${httpsPort} not reachable on $cacheIp; HTTPS goes direct."
        return $null
    }
    if (-not (Test-CachingProxyPort -IpAddress $cacheIp -Port 80 -TimeoutMs 500)) {
        Write-Verbose "Get-CacheProxyForHostDownload: apache :80 not reachable on $cacheIp (cannot fetch CA); HTTPS goes direct."
        return $null
    }
    $caUrl = "http://${cacheHost}/yuruna-squid-ca.crt"
    $caPem = Join-Path ([System.IO.Path]::GetTempPath()) 'yuruna-squid-ca.pem'
    try {
        # Retry the CA fetch on a transient blip: a single failed fetch here otherwise drops the
        # guest to a bumped-but-untrusted chain (empty-CA class) with no HTTPS fallback.
        Invoke-DownloadWithRetry -TimeoutSeconds 30 -Download {
            Invoke-WebRequest -Uri $caUrl -OutFile $caPem -ErrorAction Stop -UseBasicParsing | Out-Null
        }
    } catch {
        Write-Verbose "Get-CacheProxyForHostDownload: CA fetch from $caUrl failed after retries: $($_.Exception.Message); HTTPS goes direct."
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
    # A platform that imports this shared module only for the sentinel/skip
    # helpers ships no driver wrapper to bind its own Resolve-CacheHostIp, so the
    # closure arrives $null: with no discovery there is no cache to route through,
    # download direct. The closure stays optional (not mandatory) on purpose --
    # the image helpers feature-detect this command by name and invoke it with
    # just -Uri/-OutFile, and a mandatory closure would make that by-name call
    # bind against a missing mandatory parameter, which stalls on an interactive
    # prompt instead of falling through to a direct fetch.
    if (-not $ResolveCacheHostIp) {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -ErrorAction Stop
        return
    }
    $cfg = Get-CacheProxyForHostDownload -Uri $Uri -ResolveCacheHostIp $ResolveCacheHostIp
    if (-not $cfg) {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -ErrorAction Stop
        return
    }
    if (-not $cfg.CaPemPath) {
        Write-Information "Routing download through squid cache: $($cfg.Proxy)" -InformationAction Continue
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -Proxy $cfg.Proxy -ErrorAction Stop
        return
    }
    Write-Information "Routing HTTPS download through squid SSL-bump: $($cfg.Proxy) (per-process trust of Yuruna CA at $($cfg.CaPemPath))" -InformationAction Continue
    Invoke-HttpsViaSquidBump -Uri $Uri -OutFile $OutFile -ProxyUrl $cfg.Proxy -CaPemPath $cfg.CaPemPath
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
        fails every handshake. See feedback_scriptblock_timer_callback.md. The
        type compiles once per process (guarded) and is idempotent across
        -Force module re-imports.
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
        the cache's CA at $CaPemPath (per-process, via a compiled validator).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][string]$ProxyUrl,
        [Parameter(Mandatory)][string]$CaPemPath
    )
    # yuruna-squid-ca.crt is a cert-only PEM, so CreateFromPemFile (which expects
    # cert+key in one file) is not an option. Load from the DER bytes parsed out of
    # the PEM rather than the X509Certificate2 file constructor: the constructor's
    # PEM auto-detection goes through the platform crypto backend, which reads PEM
    # on Windows but FAILS on macOS. DER bytes load identically on every platform.
    $caPemText = [System.IO.File]::ReadAllText($CaPemPath)
    $caDerB64  = (($caPemText -split "`r?`n") | Where-Object { $_ -and ($_ -notmatch 'CERTIFICATE') }) -join ''
    $extraCa   = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($caDerB64))

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $true
    $handler.Proxy = [System.Net.WebProxy]::new([System.Uri]$ProxyUrl, $true)
    # The validation callback fires on HttpClient's TLS worker thread, which
    # has no PowerShell runspace -- a scriptblock there throws "There is no
    # Runspace available to run scripts in this thread" and fails every
    # handshake. Use a compiled C# delegate, which runs on any thread.
    $handler.ServerCertificateCustomValidationCallback = Get-SquidBumpCertValidator -ExtraCa $extraCa

    $client = [System.Net.Http.HttpClient]::new($handler, $true)
    # 4 GB at ~50 MB/s LAN cache = ~80s; HTTP/SSL handshake + cold cache
    # populate from origin can stretch this. Generous timeout vs. the
    # default 100s which would abort mid-fetch on a cold ISO pull.
    $client.Timeout = [TimeSpan]::FromHours(2)
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, [System.Uri]$Uri)
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) {
                throw "HTTP $([int]$response.StatusCode) $($response.ReasonPhrase) for $Uri"
            }
            $total = $response.Content.Headers.ContentLength
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            try {
                $out = [System.IO.File]::Create($OutFile)
                try {
                    $buf = [byte[]]::new(64 * 1024)
                    $written = 0L
                    $next = [DateTime]::UtcNow.AddSeconds(2)
                    $activity = "Downloading $Uri (via squid SSL-bump)"
                    while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                        $out.Write($buf, 0, $n)
                        $written += $n
                        if ([DateTime]::UtcNow -gt $next) {
                            if ($total) {
                                $pct = [math]::Round($written * 100.0 / $total, 1)
                                Write-Progress -Activity $activity -Status ("{0:N1} / {1:N1} MB ({2}%)" -f ($written/1MB), ($total/1MB), $pct) -PercentComplete $pct
                            } else {
                                Write-Progress -Activity $activity -Status ("{0:N1} MB" -f ($written/1MB))
                            }
                            $next = [DateTime]::UtcNow.AddSeconds(2)
                        }
                    }
                } finally { $out.Dispose() }
            } finally { $stream.Dispose() }
            Write-Progress -Activity $activity -Completed
        } finally { $response.Dispose() }
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

Export-ModuleMember -Function Test-CachingProxyPort, Test-DownloadAlreadyCurrent, Write-ImageSentinel, Get-CacheProxyForHostDownload, Save-CachedHttpUri, Invoke-HttpsViaSquidBump
