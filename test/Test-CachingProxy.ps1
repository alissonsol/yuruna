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
    Smoke-tests a squid-cache (local or remote) before Invoke-TestRunner.
    Probes :3128, :3129, :80, :3000 and GETs /yuruna-squid-ca.crt, PASS/
    FAIL/WARN per check. See test/CachingProxy.md for the full story.
    Falls back to local discovery when $Env:YURUNA_CACHING_PROXY_IP and
    -CacheIp are unset.

.PARAMETER CacheIp         Override the env var and local discovery.
.PARAMETER SetHostProxy    On success, promote to host proxy (Windows:
                           user WinINet; macOS: networksetup, needs sudo).
                           Wipes any stale WinINet ProxyServer + proxy
                           env vars BEFORE writing the new state, so a
                           single `-SetHostProxy` run is enough to fix
                           a stale-proxy WARN.
.PARAMETER NetworkService  macOS: override auto-detected network service.
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

# === Effective proxy for outbound calls =================================
# Read process env vars DIRECTLY rather than asking
# [System.Net.WebRequest]::DefaultWebProxy.GetProxy(). DefaultWebProxy
# is a per-AppDomain singleton -- HttpEnvironmentProxy gets constructed
# from env vars on the FIRST .NET HTTP call and is then cached for the
# life of the process, with no refresh path. So once Test-CachingProxy.ps1
# (or any earlier script in the same pwsh) has touched .NET HTTP, the
# singleton is stuck at whatever HTTP_PROXY said at that moment, even
# after Set-WindowsHostProxy updates $env:HTTP_PROXY in the same session.
# That is why two consecutive -SetHostProxy runs in one pwsh kept warning
# despite the underlying state being correct.
#
# Reading env vars directly reflects what NEW child processes will
# inherit (Invoke-TestRunner spawns fresh pwsh per cycle on Windows;
# child gets the parent's process env block at fork time, builds its
# own DefaultWebProxy from THOSE values). $env: hits the live process
# env block on every read.
$envHttp  = $env:HTTP_PROXY
$envHttps = $env:HTTPS_PROXY
$envNo    = $env:NO_PROXY
Write-Output "  Process env (what child processes inherit):"
Write-Output ("    HTTP_PROXY    = " + ($(if ($envHttp)  { $envHttp }  else { '(not set)' })))
Write-Output ("    HTTPS_PROXY   = " + ($(if ($envHttps) { $envHttps } else { '(not set)' })))
Write-Output ("    NO_PROXY      = " + ($(if ($envNo)    { $envNo }    else { '(not set)' })))

# Hint: HKCU env (User scope) drives what fresh-from-explorer pwsh sees;
# Process scope drives what children of THIS pwsh see. They diverge when
# the parent shell predates the most recent setx -- informational, no WARN.
if ($IsWindows) {
    foreach ($name in 'HTTP_PROXY','HTTPS_PROXY') {
        $procVal = [Environment]::GetEnvironmentVariable($name, 'Process')
        $userVal = [Environment]::GetEnvironmentVariable($name, 'User')
        if (($procVal -or $userVal) -and ($procVal -ne $userVal)) {
            $shown = if ($userVal) { $userVal } else { '(not set)' }
            Write-Output ("    (HKCU $name = $shown differs from this process; new shells from explorer would see HKCU.)")
        }
    }
}

# HTTPS_PROXY wins for HTTPS targets (cdimage.ubuntu.com is the canonical
# probe URL); fall back to HTTP_PROXY when only that is set.
$effProxy = if ($envHttps) { $envHttps } else { $envHttp }
$effHost = $null; $effPort = $null
if ($effProxy -and $effProxy -match '^https?://([^:/]+):(\d+)/?') {
    $effHost = $matches[1]
    $effPort = [int]$matches[2]
}

if (-not $effHost) {
    Write-Pass "No process-env proxy configured (HTTP/HTTPS clients go direct or via WinINet for WinINet-aware apps)"
} elseif ($effHost -eq $resolvedIp -and $effPort -eq 3128) {
    Write-Pass "Process env routes external requests via ${effHost}:${effPort} (matches probe target)"
} else {
    Write-Warn "Process env HTTP(S)_PROXY routes external requests via ${effHost}:${effPort} but the caching proxy under test is ${resolvedIp}:3128 — Invoke-TestRunner downloads (Get-Image.ps1, guest package fetches) will tunnel through ${effHost}:${effPort}, not the proxy you're testing. Stale env from before the most recent -SetHostProxy."
    Write-Output ""
    if ($SetHostProxy) {
        # The promotion below wipes process env (Remove-HostProxy) and
        # writes the new yuruna proxy. Single-step recovery: the WARN
        # above will be gone after this run completes.
        Write-Output "==== FIX ===="
        Write-Output ""
        Write-Output "  This run will wipe the stale env vars and promote ${resolvedIp}:3128 below."
    } else {
        $isElev    = if ($IsMacOS) { 'sudo -E ' } else { '' }
        $promoteCmd= "${isElev}pwsh test/Test-CachingProxy.ps1 -SetHostProxy"
        Write-Output "==== FIX ===="
        Write-Output ""
        Write-Output "  Single step -- wipes the stale process-env HTTP(S)_PROXY and"
        Write-Output "  promotes ${resolvedIp}:3128:"
        Write-Output "    $promoteCmd"
    }
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
# block promotion on it.
#
# Auto-wipe before promotion: Remove-HostProxy unconditionally clears any
# leftover WinINet ProxyServer string and HTTP_PROXY/HTTPS_PROXY/NO_PROXY
# env vars BEFORE Set-HostProxy writes the new ones. The previous
# snapshot-and-restore design preserved whatever proxy state was on the
# host when the FIRST Set-HostProxy ran -- which on a host that had a
# pre-existing (or older-cycle) HTTP_PROXY env var meant Stop-CachingProxy
# would faithfully restore it, leaking a stale IP into every subsequent
# Test-CachingProxy probe. Wiping first means each promotion lands on a
# guaranteed-clean baseline; Stop-CachingProxy similarly wipes definitively
# rather than restoring. No user-action -ClearHostProxy required.

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
        $removeParams = @{}
        if ($NetworkService) { $removeParams.NetworkService = $NetworkService }
        Remove-HostProxy @removeParams
        $setParams = @{ Url = "http://${resolvedIp}:3128" }
        if ($NetworkService) { $setParams.NetworkService = $NetworkService }
        Set-HostProxy @setParams
        Write-Output ""
        Write-Output "Host proxy is now http://${resolvedIp}:3128."
        Write-Output "Run 'pwsh test/Stop-CachingProxy.ps1' to wipe the host proxy when you're done."
    } catch {
        Write-Output ""
        Write-Output "[FAIL] -SetHostProxy threw: $($_.Exception.Message)"
        exit 1
    }
}

exit 0
