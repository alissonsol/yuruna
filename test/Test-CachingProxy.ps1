<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc012345674a
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
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
    Smoke-tests a yuruna squid-cache (local or external) before running Invoke-TestRunner.

.DESCRIPTION
    Probes every port the harness relies on and reports PASS / FAIL / WARN
    per check, so a misconfigured cache surfaces here instead of failing
    the middle of a guest install. Two modes:

      * External — when $Env:CachingProxyIpAddress is set, the script
        targets that IP directly. This is the exact path Invoke-TestRunner
        will take, so a PASS here means the runner will use that cache.
        Runnable from any machine — no VM host, no Hyper-V / UTM modules
        required.

      * Local — falls back to Test-CachingProxyAvailable (from
        test/modules/Test.CachingProxy.psm1), which finds the squid-cache VM
        on Hyper-V's Default Switch or UTM's Shared NAT. Must be run on
        the harness host.

    Checks performed against the resolved cache IP:
      * TCP :3128  — squid HTTP proxy + HTTPS CONNECT tunnel
      * TCP :3129  — squid ssl-bump listener (HTTPS body caching)
      * TCP :80    — Apache (serves the CA cert + cachemgr.cgi)
      * TCP :3000  — Grafana dashboard
      * HTTP GET http://<ip>/yuruna-squid-ca.crt — verifies the CA is
        reachable and looks like a PEM-encoded certificate. Failure here
        disables HTTPS body caching on guests but does not break HTTP
        caching, so it's a WARN.

    The script does NOT exercise the proxy as a client (no CONNECT probe,
    no chained request through :3128). Those fail modes tend to surface
    as subiquity 429s when they matter; catching them here would require
    the script to speak squid's protocol, and the TCP probes already
    answer "is anything listening".

.PARAMETER CacheIp
    Override both $Env:CachingProxyIpAddress and local discovery.
    Useful for ad-hoc probes against a candidate remote cache before
    exporting the env var.

.EXAMPLE
    # External — set the env var the runner will read, then probe.
    $Env:CachingProxyIpAddress = '10.0.0.5'
    pwsh test/Test-CachingProxy.ps1

.EXAMPLE
    # Ad-hoc probe of a candidate without setting the env var.
    pwsh test/Test-CachingProxy.ps1 -CacheIp 10.0.0.5

.EXAMPLE
    # Local — no env var, discover whatever Start-SquidCache just brought up.
    pwsh test/Test-CachingProxy.ps1
#>

param(
    [string]$CacheIp
)

$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

$script:PassCount = 0
$script:FailCount = 0
$script:WarnCount = 0

function Write-Pass { param([string]$msg) Write-Output "  [PASS] $msg"; $script:PassCount++ }
function Write-Fail { param([string]$msg) Write-Output "  [FAIL] $msg"; $script:FailCount++ }
function Write-Warn { param([string]$msg) Write-Output "  [WARN] $msg"; $script:WarnCount++ }

function Test-TcpPort {
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 1500
    )
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $tcp.BeginConnect($IpAddress, $Port, $null, $null)
        return ($async.AsyncWaitHandle.WaitOne($TimeoutMs) -and $tcp.Connected)
    } catch {
        Write-Verbose "Test-TcpPort ${IpAddress}:${Port} failed: $($_.Exception.Message)"
        return $false
    } finally {
        $tcp.Close()
    }
}

# === Resolve the cache IP ===============================================
# Priority: -CacheIp parameter > $Env:CachingProxyIpAddress > local
# discovery via Test-CachingProxyAvailable. Each source settles $resolvedIp
# before the port probes run; failure at this stage is a hard FAIL because
# nothing else the script does is meaningful without an IP to target.

Write-Output ""
Write-Output "=== yuruna caching proxy probe ==="

$resolvedIp   = $null
$resolvedFrom = $null

if ($CacheIp) {
    if ($CacheIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        Write-Fail "CacheIp parameter '$CacheIp' is not a valid IPv4 address."
        exit 1
    }
    $resolvedIp   = $CacheIp
    $resolvedFrom = "-CacheIp parameter"
} elseif ($Env:CachingProxyIpAddress) {
    $externIp = $Env:CachingProxyIpAddress.Trim()
    if ($externIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        Write-Fail "Env:CachingProxyIpAddress='$externIp' is not a valid IPv4 address."
        exit 1
    }
    $resolvedIp   = $externIp
    $resolvedFrom = "`$Env:CachingProxyIpAddress"
} else {
    # Local discovery via Test-CachingProxyAvailable. That module knows the
    # per-platform quirks (Hyper-V ARP+KVP, UTM 192.168.64.1 gateway
    # rewrite) — no point duplicating them here. If the module can't load
    # we can't usefully fall back, so FAIL with a pointer.
    $modulePath = Join-Path $PSScriptRoot "modules/Test.CachingProxy.psm1"
    if (-not (Test-Path $modulePath)) {
        Write-Fail "Local discovery requires $modulePath (not found). Set `$Env:CachingProxyIpAddress or pass -CacheIp to probe remotely."
        exit 1
    }
    Import-Module $modulePath -Force
    $hostType = if ($IsMacOS) { 'host.macos.utm' } elseif ($IsWindows) { 'host.windows.hyper-v' } else { $null }
    if (-not $hostType) {
        Write-Fail "Local discovery only runs on macOS or Windows hosts. Set `$Env:CachingProxyIpAddress or pass -CacheIp."
        exit 1
    }
    $proxyUrl = Test-CachingProxyAvailable -HostType $hostType
    if (-not $proxyUrl) {
        Write-Fail "Test-CachingProxyAvailable returned no cache. Either Start-CachingProxy.ps1 hasn't been run, or the cache VM is not listening on :3128."
        exit 1
    }
    if ($proxyUrl -match '^http://([0-9.]+):') {
        $resolvedIp   = $matches[1]
        $resolvedFrom = "Test-CachingProxyAvailable ($proxyUrl)"
    } else {
        Write-Fail "Test-CachingProxyAvailable returned '$proxyUrl' (could not parse IP)."
        exit 1
    }
}

Write-Output "  Target: $resolvedIp  (source: $resolvedFrom)"
Write-Output ""

# === Port probes ========================================================
# Treat :80 as WARN rather than FAIL — a cache without :80 exposed still
# serves HTTP caching, just not HTTPS (no CA distribution). :3128 / :3129 /
# :3000 are harder requirements: :3128 must answer for the runner to
# consider the cache "detected", :3129 is needed for HTTPS body caching,
# :3000 is the dashboard every other caller links to.

$ports = @(
    @{ Port = 3128; Name = 'Squid HTTP proxy';       Level = 'FAIL' }
    @{ Port = 3129; Name = 'Squid ssl-bump (HTTPS)';  Level = 'FAIL' }
    @{ Port = 80;   Name = 'Apache (CA cert)';        Level = 'WARN' }
    @{ Port = 3000; Name = 'Grafana dashboard';       Level = 'FAIL' }
)
foreach ($p in $ports) {
    $label = "{0,-5} ({1})" -f $p.Port, $p.Name
    if (Test-TcpPort -IpAddress $resolvedIp -Port $p.Port) {
        Write-Pass "TCP :$label"
    } elseif ($p.Level -eq 'WARN') {
        Write-Warn "TCP :$label — not reachable (HTTPS caching will be disabled on guests, HTTP unaffected)"
    } else {
        Write-Fail "TCP :$label — not reachable"
    }
}

# === CA cert fetch ======================================================
# Only meaningful if :80 is up. We fetch the whole cert (a few KB), parse
# it as an X.509 to confirm it's really a certificate — catches the case
# where Apache is answering but serving its default index instead of the
# ca.pem we copied into /var/www/html. Fetch failure is a WARN because,
# again, HTTP caching still works; only HTTPS body caching breaks.

$caUrl = "http://${resolvedIp}/yuruna-squid-ca.crt"
try {
    $resp = Invoke-WebRequest -Uri $caUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    if ($resp.StatusCode -eq 200 -and $resp.RawContentLength -gt 0) {
        $raw = if ($resp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($resp.Content) } else { [string]$resp.Content }
        if ($raw -match '-----BEGIN CERTIFICATE-----' -and $raw -match '-----END CERTIFICATE-----') {
            # Try parsing — catches "looks PEM-shaped but is actually corrupt".
            try {
                $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([System.Text.Encoding]::UTF8.GetBytes($raw))
                Write-Pass "CA cert $caUrl -> $($cert.Subject) (expires $($cert.NotAfter.ToString('yyyy-MM-dd')))"
            } catch {
                Write-Warn "CA cert $caUrl returned PEM-looking bytes but X509 parse failed: $($_.Exception.Message)"
            }
        } else {
            Write-Warn "CA cert $caUrl returned $($raw.Length) bytes but no BEGIN/END CERTIFICATE markers found."
        }
    } else {
        Write-Warn "CA cert $caUrl returned HTTP $($resp.StatusCode) with $($resp.RawContentLength) bytes."
    }
} catch {
    Write-Warn "CA cert $caUrl fetch failed: $($_.Exception.Message)"
}

# === Summary ============================================================

Write-Output ""
Write-Output "=== Summary: $script:PassCount PASS, $script:WarnCount WARN, $script:FailCount FAIL ==="

if ($script:FailCount -gt 0) {
    Write-Output ""
    Write-Output "One or more required ports did not answer. Invoke-TestRunner would treat this cache as broken."
    exit 1
}
exit 0
