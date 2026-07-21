<#PSScriptInfo
.VERSION 2026.07.21
.GUID 429b1c74-2a6d-4f38-91c0-7b3e8d2a4f16
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool push ingest tls
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
    Runner-side push forwarder for the pool aggregator's POST /ingest: ships a
    cycle's NDJSON events to the aggregator so they reach Loki without waiting for the next
    pull (closes the between-poll trailing-event gap). SUPPLEMENTS pull; pull stays the
    discovery + backfill authority, and Loki dedups the overlap by the event's own
    timestamp -- so a dropped push is never lost.
.DESCRIPTION
    The push carries the shared bearer token, so it is delivered over CA-PINNED HTTPS: the
    aggregator's TLS leaf must chain to the published pool CA, else the request is refused
    (a MITM with any other cert can never receive the token). The pinning uses a COMPILED
    C# validation delegate, not a PowerShell scriptblock -- the cert callback fires on a
    threadpool thread during the TLS handshake, where a scriptblock-as-delegate hits the
    GetContextFromTLS crash class (feedback_scriptblock_timer_callback).

    Every call is bounded (HttpClient timeout) and best-effort: any failure is swallowed and
    the events are simply re-pulled. The forwarder is spawned DETACHED per cycle (mirroring
    the poolStorage drain) so a slow/absent aggregator can never delay the next cycle --
    preserving the read-side-decoupling invariant.
#>

# Compile the pinned-TLS HttpClient factory once. Guarded so a compile failure on an
# unexpected runtime degrades to "push disabled" (pull still covers) rather than throwing
# at import. CustomRootTrust + CustomTrustStore are .NET 5+ (PowerShell 7.2+ is .NET 6+).
$script:PoolPinnedTlsType = $false
try {
    if (-not ([System.Management.Automation.PSTypeName]'YurunaPoolPinnedTls').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Net.Http;
using System.Security.Cryptography.X509Certificates;
public static class YurunaPoolPinnedTls {
    // Takes a pre-loaded CA cert (PowerShell loads it, avoiding the obsolete
    // X509Certificate2(string) constructor that newer .NET treats as a build error).
    public static HttpClient Client(X509Certificate2 ca, int timeoutSec) {
        var h = new HttpClientHandler();
        h.ServerCertificateCustomValidationCallback = (req, cert, chain, errors) => {
            if (cert == null) { return false; }
            var c = new X509Chain();
            c.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            c.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
            c.ChainPolicy.CustomTrustStore.Add(ca);
            // Offer the server-presented chain as intermediates so a leaf signed by an
            // intermediate (not the root directly) still builds to the pinned CA.
            if (chain != null) {
                foreach (var el in chain.ChainElements) { c.ChainPolicy.ExtraStore.Add(el.Certificate); }
            }
            return c.Build(cert);
        };
        var client = new HttpClient(h);
        client.Timeout = TimeSpan.FromSeconds(timeoutSec);
        return client;
    }
}
'@
    }
    $script:PoolPinnedTlsType = [bool]([System.Management.Automation.PSTypeName]'YurunaPoolPinnedTls').Type
} catch {
    Write-Warning "Test.PoolPush: pinned-TLS helper did not compile ($($_.Exception.Message)); pool push disabled."
}

function New-PoolX509Certificate {
    <#
    .SYNOPSIS
        Load a PEM/DER cert file into an X509Certificate2, preferring the modern
        X509CertificateLoader (.NET 9+) and falling back to the constructor on older
        PowerShell 7 runtimes. Loading in PowerShell keeps the obsolete-constructor build
        error out of the compiled pinned-TLS helper.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure loader: reads a cert file into an in-memory object, changes no external state.')]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param([Parameter(Mandatory)][string]$Path)
    # Load via DER bytes so this works on EVERY platform and .NET version. The pool
    # CA (pool-ca.crt, written by Get-PoolCaCertPath) is a cert-only PEM, which both
    # prior strategies mishandle: X509CertificateLoader.LoadCertificateFromFile does
    # NOT read PEM at all (throws on .NET 9), and the X509Certificate2 file ctor
    # reads PEM on Windows but FAILS on macOS (DER-expecting backend). Strip the PEM
    # armor and decode to DER (a raw DER file loads as-is), then prefer the modern
    # X509CertificateLoader.LoadCertificate(byte[]) (.NET 9+), else the ctor.
    $bytes  = [System.IO.File]::ReadAllBytes($Path)
    $asText = [System.Text.Encoding]::ASCII.GetString($bytes)
    if ($asText -match '-----BEGIN CERTIFICATE-----') {
        $b64   = (($asText -split "`r?`n") | Where-Object { $_ -and ($_ -notmatch '-----') }) -join ''
        $bytes = [Convert]::FromBase64String($b64)
    }
    $loader = 'System.Security.Cryptography.X509Certificates.X509CertificateLoader' -as [type]
    if ($loader) { return $loader::LoadCertificate($bytes) }
    return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes)
}

function Get-PoolCaCertPath {
    <#
    .SYNOPSIS
        Fetch + cache the published pool CA (http://<proxy>/yuruna-pool-ca.crt) to
        runtime/pool-ca.crt for pinning the aggregator's TLS leaf. Trust-on-first-use over
        HTTP on the trusted LAN (the same model guests use to fetch the squid CA at install).
        Returns the cached path, or $null when unfetchable (the caller then cannot push).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ProxyIp,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter()][int]$TimeoutSec = 10,
        [Parameter()][switch]$Refresh
    )
    $path = Join-Path $RuntimeDir 'pool-ca.crt'
    if ((-not $Refresh) -and (Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Length -gt 0)) { return $path }
    if (-not $PSCmdlet.ShouldProcess($path, 'Fetch + cache pool CA')) { return $null }
    try {
        $resp = Invoke-WebRequest -Uri "http://${ProxyIp}/yuruna-pool-ca.crt" -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop -Verbose:$false
        if ($resp.StatusCode -ne 200) { return $null }
        $content = [string]$resp.Content
        if ($content -notmatch 'BEGIN CERTIFICATE') { return $null }
        [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
        return $path
    } catch { Write-Verbose "Get-PoolCaCertPath: $($_.Exception.Message)"; return $null }
}

function Get-PoolPushBatch {
    <#
    .SYNOPSIS
        PURE: split NDJSON lines into batches of at most MaxLines, dropping blank lines, so a
        push stays within the aggregator's per-request line cap. Returns an array of
        string[] batches (empty array for no usable lines).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][AllowEmptyString()][string[]]$Lines,
        [Parameter()][int]$MaxLines = 1000
    )
    $batches = [System.Collections.Generic.List[object]]::new()
    $cur = [System.Collections.Generic.List[string]]::new()
    foreach ($ln in @($Lines)) {
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        $cur.Add([string]$ln)
        if ($cur.Count -ge $MaxLines) { $batches.Add($cur.ToArray()); $cur = [System.Collections.Generic.List[string]]::new() }
    }
    if ($cur.Count -gt 0) { $batches.Add($cur.ToArray()) }
    return , $batches.ToArray()
}

function Send-PoolEventBatch {
    <#
    .SYNOPSIS
        POST one batch of NDJSON event lines to the aggregator's /ingest over CA-PINNED
        HTTPS with the shared bearer token. Returns the HTTP status code, or 0 when the
        request could not be made (no pinned-TLS type, missing CA, transport error). Never
        throws -- push is best-effort.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$IngestUrl,
        [Parameter(Mandatory)][string]$CaCertPath,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter()][int]$TimeoutSec = 15
    )
    if (-not $script:PoolPinnedTlsType) { Write-Verbose 'Send-PoolEventBatch: pinned-TLS helper unavailable.'; return 0 }
    if (@($Lines).Count -eq 0) { return 0 }
    $client = $null
    $ca = $null
    try {
        $ca = New-PoolX509Certificate -Path $CaCertPath
        $client = [YurunaPoolPinnedTls]::Client($ca, $TimeoutSec)
        $body = ((@($Lines)) -join "`n")
        $content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/x-ndjson')
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $IngestUrl)
        $req.Content = $content
        [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $Token")
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        return [int]$resp.StatusCode
    } catch {
        Write-Verbose "Send-PoolEventBatch: $($_.Exception.Message)"
        return 0
    } finally {
        if ($client) { $client.Dispose() }
        if ($ca) { $ca.Dispose() }
    }
}

function Invoke-PoolEventPush {
    <#
    .SYNOPSIS
        Read a cycle's cycle.events.ndjson and push it (in capped batches) to the
        aggregator's /ingest over CA-pinned HTTPS. Best-effort + bounded; never throws.
        Returns @{ sent; batches; lastStatus; reason }.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Best-effort network push of already-written telemetry; no local state change, never throws.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$CycleFolder,
        [Parameter(Mandatory)][string]$ProxyIp,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter()][int]$Port = 9400,
        [Parameter()][int]$MaxLines = 1000,
        [Parameter()][int]$TimeoutSec = 15
    )
    $summary = @{ sent = 0; batches = 0; lastStatus = 0; reason = '' }
    try {
        $eventsFile = Join-Path $CycleFolder 'cycle.events.ndjson'
        if (-not (Test-Path -LiteralPath $eventsFile)) { $summary.reason = 'no events file'; return $summary }
        $caPath = Get-PoolCaCertPath -ProxyIp $ProxyIp -RuntimeDir $RuntimeDir -TimeoutSec $TimeoutSec -Confirm:$false
        if (-not $caPath) { $summary.reason = 'pool CA unavailable (cannot pin -> not pushing the token)'; return $summary }
        $lines = @(Get-Content -LiteralPath $eventsFile -ErrorAction Stop)
        $batches = Get-PoolPushBatch -Lines $lines -MaxLines $MaxLines
        $ingestUrl = "https://${ProxyIp}:$Port/ingest"
        $refreshed = $false
        foreach ($batch in $batches) {
            $code = Send-PoolEventBatch -IngestUrl $ingestUrl -CaCertPath $caPath -Token $Token -Lines $batch -TimeoutSec $TimeoutSec
            if (($code -lt 200 -or $code -ge 300) -and -not $refreshed) {
                # A cached CA that no longer matches the aggregator's leaf (the pool CA was
                # rotated on a proxy rebuild) makes pinning fail. Re-fetch the published CA
                # ONCE and retry this batch before giving up. (A first-fetch TOFU poisoning
                # is the documented residual of trust-on-first-use over HTTP.)
                $refreshed = $true
                $fresh = Get-PoolCaCertPath -ProxyIp $ProxyIp -RuntimeDir $RuntimeDir -TimeoutSec $TimeoutSec -Refresh -Confirm:$false
                if ($fresh) {
                    $caPath = $fresh
                    $code = Send-PoolEventBatch -IngestUrl $ingestUrl -CaCertPath $caPath -Token $Token -Lines $batch -TimeoutSec $TimeoutSec
                }
            }
            $summary.batches++
            $summary.lastStatus = $code
            if ($code -ge 200 -and $code -lt 300) { $summary.sent += @($batch).Count }
            else { break }   # stop on the first still-failed batch; pull backfills the rest
        }
    } catch {
        $summary.reason = "error: $($_.Exception.Message)"
        Write-Verbose "Invoke-PoolEventPush: $($_.Exception.Message)"
    }
    return $summary
}

Export-ModuleMember -Function `
    New-PoolX509Certificate, Get-PoolCaCertPath, Get-PoolPushBatch, Send-PoolEventBatch, Invoke-PoolEventPush
