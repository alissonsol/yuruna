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

      * External — when $Env:YURUNA_CACHING_PROXY_IP is set, the script
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
    Override both $Env:YURUNA_CACHING_PROXY_IP and local discovery.
    Useful for ad-hoc probes against a candidate remote cache before
    exporting the env var.

.PARAMETER SetHostProxy
    When all FAIL-level checks pass, promote the resolved proxy to the
    machine-wide host proxy (user scope) via Test.HostProxy.psm1:
      * Windows: HKCU WinINet ProxyEnable/ProxyServer/ProxyOverride plus
        user HTTP_PROXY / HTTPS_PROXY / NO_PROXY env vars. No elevation
        required.
      * macOS: networksetup against the auto-detected active network
        service. Requires sudo (re-run via `sudo -E pwsh ...`).
    Previous proxy state is snapshotted to $HOME/.yuruna/host-proxy.backup.json
    BEFORE writing, so Stop-CachingProxy.ps1 / Clear-HostProxy restores it.

.PARAMETER NetworkService
    macOS only: override the auto-detected active network service name
    (e.g. "Wi-Fi", "Ethernet"). Pass this when -SetHostProxy can't figure
    out which service to target. Ignored on Windows.

.EXAMPLE
    # External — set the env var the runner will read, then probe.
    $Env:YURUNA_CACHING_PROXY_IP = '10.0.0.5'
    pwsh test/Test-CachingProxy.ps1

.EXAMPLE
    # Ad-hoc probe of a candidate without setting the env var.
    pwsh test/Test-CachingProxy.ps1 -CacheIp 10.0.0.5

.EXAMPLE
    # Local — no env var, discover whatever Start-SquidCache just brought up.
    pwsh test/Test-CachingProxy.ps1

.EXAMPLE
    # Probe + promote to host-wide proxy on success (Windows, user scope).
    $Env:YURUNA_CACHING_PROXY_IP = '192.168.1.50'
    pwsh test/Test-CachingProxy.ps1 -SetHostProxy

.EXAMPLE
    # Same, on macOS (sudo required for networksetup).
    sudo -E pwsh test/Test-CachingProxy.ps1 -SetHostProxy
#>

param(
    [string]$CacheIp,
    [switch]$SetHostProxy,
    [string]$NetworkService
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
# Priority: -CacheIp parameter > $Env:YURUNA_CACHING_PROXY_IP > local
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
} elseif ($Env:YURUNA_CACHING_PROXY_IP) {
    $externIp = $Env:YURUNA_CACHING_PROXY_IP.Trim()
    if ($externIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        Write-Fail "Env:YURUNA_CACHING_PROXY_IP='$externIp' is not a valid IPv4 address."
        exit 1
    }
    $resolvedIp   = $externIp
    $resolvedFrom = "`$Env:YURUNA_CACHING_PROXY_IP"
} else {
    # Local discovery via Test-CachingProxyAvailable. That module knows the
    # per-platform quirks (Hyper-V ARP+KVP, UTM 192.168.64.1 gateway
    # rewrite) — no point duplicating them here. If the module can't load
    # we can't usefully fall back, so FAIL with a pointer.
    $modulePath = Join-Path $PSScriptRoot "modules/Test.CachingProxy.psm1"
    if (-not (Test-Path $modulePath)) {
        Write-Fail "Local discovery requires $modulePath (not found). Set `$Env:YURUNA_CACHING_PROXY_IP or pass -CacheIp to probe remotely."
        exit 1
    }
    Import-Module $modulePath -Force
    $hostType = if ($IsMacOS) { 'host.macos.utm' } elseif ($IsWindows) { 'host.windows.hyper-v' } else { $null }
    if (-not $hostType) {
        Write-Fail "Local discovery only runs on macOS or Windows hosts. Set `$Env:YURUNA_CACHING_PROXY_IP or pass -CacheIp."
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
    # -NoProxy: we're fetching the cache's own Apache on :80. If the host
    # already has a proxy configured (including a stale yuruna one from a
    # prior cycle), routing this request through it would either loop or
    # fail against a dead endpoint -- the .42 fetch getting tunneled via a
    # leftover .63:3128 setting is exactly how this bug was spotted.
    $resp = Invoke-WebRequest -Uri $caUrl -UseBasicParsing -NoProxy -TimeoutSec 5 -ErrorAction Stop
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

# === Host system-proxy check ===========================================
# A stale system proxy (e.g. a previous Start-CachingProxy.ps1 -PromoteToHost
# against an IP that has since moved) will silently redirect every
# Invoke-WebRequest / curl in Invoke-TestRunner. .NET on macOS reads
# networksetup; .NET on Windows reads WinINet per-user (what
# Test.HostProxy.psm1 writes) and WinHTTP machine-wide. Env vars are
# only consulted as a fallback, which is why a stale system setting
# doesn't show up by dumping env vars alone.

Write-Output ""
Write-Output "=== Host system-proxy check ==="

if ($IsMacOS) {
    try {
        $scText = (& scutil --proxy 2>&1) -join "`n"
        Write-Output "  scutil --proxy:"
        foreach ($line in ($scText -split "`n")) { if ($line) { Write-Output ("    " + $line.TrimEnd()) } }
    } catch {
        Write-Output "  scutil --proxy failed: $($_.Exception.Message)"
    }
} elseif ($IsWindows) {
    try {
        $nwText = (& netsh winhttp show proxy 2>&1) -join "`n"
        Write-Output "  netsh winhttp show proxy:"
        foreach ($line in ($nwText -split "`n")) { if ($line) { Write-Output ("    " + $line.TrimEnd()) } }
    } catch {
        Write-Output "  netsh winhttp show proxy failed: $($_.Exception.Message)"
    }
    try {
        $is = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        Write-Output "  WinINet (HKCU Internet Settings):"
        Write-Output ("    ProxyEnable   = " + $is.ProxyEnable)
        Write-Output ("    ProxyServer   = " + $is.ProxyServer)
        Write-Output ("    ProxyOverride = " + $is.ProxyOverride)
    } catch {
        Write-Output "  WinINet registry probe failed: $($_.Exception.Message)"
    }
} else {
    Write-Output "  (no platform-specific system-proxy probe on this OS)"
}

$probeUri = [System.Uri]::new('https://cdimage.ubuntu.com/')
$dotnetResolved = $null
try {
    $dotnetProxy = [System.Net.WebRequest]::DefaultWebProxy
    $dotnetResolved = $dotnetProxy.GetProxy($probeUri)
    Write-Output ("  .NET DefaultWebProxy type: " + $dotnetProxy.GetType().FullName)
    Write-Output ("  .NET GetProxy($probeUri) = $dotnetResolved")
} catch {
    Write-Output "  .NET DefaultWebProxy probe failed: $($_.Exception.Message)"
}

# If .NET returns the original URL, it means "go direct, no proxy".
# Anything else is a proxy — compare it against the cache we just probed.
if ($dotnetResolved -and $dotnetResolved.AbsoluteUri -ne $probeUri.AbsoluteUri) {
    $dotnetHost = $dotnetResolved.Host
    $dotnetPort = $dotnetResolved.Port
    if ($dotnetHost -eq $resolvedIp -and $dotnetPort -eq 3128) {
        Write-Pass "System proxy routes external requests via ${dotnetHost}:${dotnetPort} (matches probe target)"
    } else {
        $platformTool = if ($IsMacOS) { 'networksetup (scutil --proxy)' } else { 'WinINet / WinHTTP' }
        $stopCmd = if ($IsMacOS) { 'sudo -E pwsh test/Stop-CachingProxy.ps1' } else { 'pwsh test/Stop-CachingProxy.ps1' }
        $promoteCmd = if ($IsMacOS) { 'sudo -E pwsh test/Test-CachingProxy.ps1 -SetHostProxy' } else { 'pwsh test/Test-CachingProxy.ps1 -SetHostProxy' }
        Write-Warn "System proxy routes external requests via ${dotnetHost}:${dotnetPort} but the caching proxy under test is ${resolvedIp}:3128 — Invoke-TestRunner downloads (Get-Image.ps1, guest package fetches) will tunnel through ${dotnetHost}:${dotnetPort}, not the proxy you're testing. Likely a stale $platformTool setting from a previous Start-CachingProxy cycle."
        Write-Output ""
        Write-Output "==== FIX ===="
        Write-Output ""
        Write-Output "  $stopCmd"
        Write-Output "  $promoteCmd"
    }
} else {
    Write-Pass "No system-level proxy configured (external HTTP/HTTPS clients go direct)"
}

# === Summary ============================================================

Write-Output ""
Write-Output "=== Summary: $script:PassCount PASS, $script:WarnCount WARN, $script:FailCount FAIL ==="

if ($script:FailCount -gt 0) {
    Write-Output ""
    Write-Output "One or more required ports did not answer. Invoke-TestRunner would treat this cache as broken."
    exit 1
}

# === Optional: promote to machine-wide host proxy =======================
# Only runs when every FAIL-level check passed -- WARN-level (missing :80 /
# missing CA cert) is compatible with a working HTTP proxy, so we don't
# block promotion on it. Test.HostProxy.psm1 snapshots the user's prior
# proxy state into $HOME/.yuruna/host-proxy.backup.json before writing,
# so Stop-CachingProxy.ps1 can restore it exactly rather than blindly
# wiping whatever proxy the user had before.

if ($SetHostProxy) {
    Write-Output ""
    Write-Output "=== Promoting to machine-wide host proxy ==="
    $hostProxyMod = Join-Path $PSScriptRoot 'modules/Test.HostProxy.psm1'
    if (-not (Test-Path -LiteralPath $hostProxyMod)) {
        Write-Warning "-SetHostProxy: $hostProxyMod not found -- skipping promotion."
        exit 0
    }
    Import-Module $hostProxyMod -Force
    try {
        $params = @{ Url = "http://${resolvedIp}:3128" }
        if ($NetworkService) { $params.NetworkService = $NetworkService }
        Set-HostProxy @params
        Write-Output ""
        Write-Output "Host proxy is now http://${resolvedIp}:3128."
        Write-Output "Run 'pwsh test/Stop-CachingProxy.ps1' to restore the previous proxy state."
    } catch {
        Write-Output ""
        Write-Output "[FAIL] Set-HostProxy threw: $($_.Exception.Message)"
        exit 1
    }
}

exit 0
