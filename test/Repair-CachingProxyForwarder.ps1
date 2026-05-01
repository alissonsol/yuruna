<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456771
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
    Revives dead host-side squid-cache port forwarders without rebuilding
    the VM. macOS/UTM only.

.DESCRIPTION
    Start-CachingProxy.ps1 does the full setup: download image, create VM,
    wait 15 min for cloud-init + pre-warm, then launch the host-side TCP
    forwarders. When ONLY the forwarders died — Mac slept, pwsh crashed,
    network change invalidated a socket — the cache VM is still running
    and full of warm objects; the 15-minute rebuild (and the re-pre-warm
    bandwidth hit) is wasted.

    This script takes the fast path:
      1. Read $HOME/virtual/squid-cache/cache-ip.txt (or subnet-scan
         192.168.64.0/24 as a fallback, same probe Start-CachingProxy.ps1
         uses in its Step 5).
      2. Confirm the VM answers on :3128 from the host.
      3. Cache sudo credentials (port 80 forwarder is root-owned).
      4. Call Add-CachingProxyPortMap — which per-port:
           * leaves a live forwarder alone (Start-CachingProxyForwarder's
             self-check at VM.common.psm1:Get-CachingProxyForwarder)
           * (re)launches any forwarder whose pidfile is missing or points
             at a dead pid
         so the root-owned :80 forwarder (if still alive) is NOT disturbed.

    This script NEVER touches:
      * utmctl / the .utm bundle / the VM itself
      * Get-Image / New-VM / cloud-init / Ubuntu mirrors
      * system proxy (scutil / networksetup) / DNS / Wi-Fi
      * the existing :3128 system-proxy setting (if any)

    All activity is local TCP binds on the Mac host and probes against
    192.168.64.0/24 (VZ shared-NAT, isolated from the outside network).
    Safe to run on a metered / paid / captive-portal network connection:
    no outbound Ubuntu-mirror traffic, no Wi-Fi reauth.

.PARAMETER CacheIp
    Override auto-discovery. When provided, cache-ip.txt and the subnet
    scan are skipped; this IP is used directly. Must be IPv4.

.EXAMPLE
    pwsh test/Repair-CachingProxyForwarder.ps1

.EXAMPLE
    # cache-ip.txt is wrong / missing, you already know the VM IP:
    pwsh test/Repair-CachingProxyForwarder.ps1 -CacheIp 192.168.64.206
#>

param(
    [string]$CacheIp
)

$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

if (-not $IsMacOS) {
    Write-Error "Repair-CachingProxyForwarder.ps1 is macOS-only. On Hyper-V the netsh portproxy is restored automatically by Invoke-TestRunner / Start-CachingProxy."
    exit 1
}

if ($CacheIp -and $CacheIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    Write-Error "CacheIp '$CacheIp' is not a valid IPv4 address."
    exit 1
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$stateDir = Join-Path $HOME 'virtual/squid-cache'

# === Step 1: discover the cache VM IP =======================================

if (-not $CacheIp) {
    $ipFile = Join-Path $stateDir 'cache-ip.txt'
    if (Test-Path $ipFile) {
        $candidate = (Get-Content -Raw $ipFile -ErrorAction SilentlyContinue).Trim()
        if ($candidate -match '^\d+\.\d+\.\d+\.\d+$') {
            $CacheIp = $candidate
            Write-Output "Cache IP from $ipFile : $CacheIp"
        }
    }
}

# Fallback: subnet scan (same shape as Start-CachingProxy.ps1 Step 5). We
# scan only the VZ shared-NAT subnet — never the host's outside network —
# so this is a no-op for any paid/captive Wi-Fi the Mac is currently on.
if (-not $CacheIp) {
    Write-Output "No valid cache-ip.txt; scanning 192.168.64.0/24 for a :3128 listener (VZ shared-NAT only)..."
    for ($octet = 2; $octet -le 254 -and -not $CacheIp; $octet++) {
        $candidate = "192.168.64.$octet"
        $tcp = [System.Net.Sockets.TcpClient]::new()
        try {
            $async = $tcp.BeginConnect($candidate, 3128, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(150) -and $tcp.Connected) { $CacheIp = $candidate }
        } catch {
            Write-Verbose "probe ${candidate}:3128 failed: $($_.Exception.Message)"
        } finally {
            $tcp.Close()
        }
    }
    if ($CacheIp) { Write-Output "Cache VM discovered at $CacheIp" }
}

if (-not $CacheIp) {
    Write-Error "Could not locate squid-cache VM."
    Write-Error "  Neither $stateDir/cache-ip.txt nor a :3128 listener on 192.168.64.0/24 found."
    Write-Error "  If the VM is stopped/missing, rebuild with: pwsh test/Start-CachingProxy.ps1"
    Write-Error "  If the VM IP is known, rerun with: pwsh test/Repair-CachingProxyForwarder.ps1 -CacheIp <ip>"
    exit 1
}

# === Step 2: confirm the VM is actually answering ===========================
# An IP alone doesn't prove squid is up — the :3128 probe above might have
# been satisfied by a stale ARP entry on a VM that has since stopped. Do a
# longer-timeout re-probe with a fresh socket so we don't restart forwarders
# pointed at a dead target (which would just accept-and-close loops).

$tcp = [System.Net.Sockets.TcpClient]::new()
$reachable = $false
try {
    $async = $tcp.BeginConnect($CacheIp, 3128, $null, $null)
    if ($async.AsyncWaitHandle.WaitOne(1500) -and $tcp.Connected) { $reachable = $true }
} catch {
    Write-Verbose "${CacheIp}:3128 re-probe failed: $($_.Exception.Message)"
} finally {
    $tcp.Close()
}

if (-not $reachable) {
    Write-Error "${CacheIp}:3128 did not answer on the re-probe."
    Write-Error "  The VM is not reachable from the host. If UTM lost track of it"
    Write-Error "  (utmctl list shows it missing), open UTM.app manually and start"
    Write-Error "  the squid-cache VM, then re-run this script."
    Write-Error "  If the VM itself is gone, rebuild with: pwsh test/Start-CachingProxy.ps1"
    exit 1
}

Write-Output "Confirmed: squid-cache VM reachable at ${CacheIp}:3128."

# === Step 3: report which forwarders are currently up =======================
# Informational only — Add-CachingProxyPortMap's per-port path (via
# Start-CachingProxyForwarder) decides what to restart. We don't call
# Stop-AllCachingProxyForwarder; it would needlessly kill forwarders that
# are still working fine.

Import-Module (Join-Path $RepoRoot 'virtual/host.macos.utm/VM.common.psm1') -Force
$expectedPorts = @(80, 3128, 3129, 3000, 8022)
Write-Output ""
Write-Output "Current forwarder state:"
foreach ($p in $expectedPorts) {
    $alive = Get-CachingProxyForwarder -Port $p
    $label = if ($alive) { "RUNNING" } else { "DOWN" }
    Write-Output ("  port {0,-4} : {1}" -f $p, $label)
}

# === Step 4: cache sudo credentials for the port-80 forwarder ==============
# Start-CachingProxyForwarder skips the :80 restart if the root-owned process
# is still live (VM.common.psm1 self-check). Only prompt for sudo if we
# actually need it — i.e. the :80 forwarder is down.

$port80Alive = Get-CachingProxyForwarder -Port 80
$isRoot = $false
try { $isRoot = ((& '/usr/bin/id' -u) -eq '0') } catch { Write-Verbose "id -u check failed: $_" }
if (-not $port80Alive -and -not $isRoot) {
    Write-Output ""
    Write-Output "Port 80 forwarder is down and requires root to bind — caching sudo credentials..."
    & sudo -v
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "sudo -v failed — port 80 forwarder will be skipped. HTTPS caching for LAN clients will be unavailable until it is restarted."
    }
}

# === Step 5: persist cache-ip.txt ===========================================
# Idempotent — rewrite with the same bytes if cache-ip.txt was already
# correct. If the user passed -CacheIp to override a stale file, this
# commits the correction so Invoke-TestRunner / Start-StatusServer can
# see the right IP on their next run.

if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
Set-Content -Path (Join-Path $stateDir 'cache-ip.txt') -Value $CacheIp -NoNewline -Encoding ascii

# === Step 6: relaunch forwarders ============================================
# Port list matches Start-CachingProxy.ps1 Step 6. Add-CachingProxyPortMap
# on macOS is per-port (pidfile-keyed), not "clear all then re-add" —
# live forwarders for any port already in good shape stay untouched,
# dead ones get replaced. See Test.PortMap.psm1:Add-CachingProxyPortMap
# macOS branch and VM.common.psm1:Start-CachingProxyForwarder.

Write-Output ""
Write-Output "=== Relaunching forwarders (80 CA + 3128 proxy + 3129 ssl-bump + 3000 Grafana + 8022->22 SSH) ==="
Import-Module (Join-Path $RepoRoot 'test/modules/Test.PortMap.psm1') -Force
[void](Add-CachingProxyPortMap -VMIp $CacheIp -Port $expectedPorts -PortRemap @{8022 = 22})

# === Step 7: verify ========================================================
# Re-import VM.common.psm1 before calling Get-CachingProxyForwarder.
# Test.PortMap.psm1 (Step 6) does its own `Import-Module VM.common.psm1 -Force`
# inside its macOS branch, which pulls VM.common into Test.PortMap's nested
# module scope and evicts the script-scope import from Step 3. Without this
# re-import, Get-CachingProxyForwarder is no longer resolvable here even
# though it worked in Step 3's identical call site above.

Import-Module (Join-Path $RepoRoot 'virtual/host.macos.utm/VM.common.psm1') -Force

Write-Output ""
Write-Output "Post-repair forwarder state:"
$allUp = $true
foreach ($p in $expectedPorts) {
    $alive = Get-CachingProxyForwarder -Port $p
    $label = if ($alive) { "RUNNING" } else { "DOWN" }
    if (-not $alive) { $allUp = $false }
    Write-Output ("  port {0,-4} : {1}" -f $p, $label)
}

Write-Output ""
if ($allUp) {
    Write-Output "================================================================="
    Write-Output "=== squid-cache forwarders RESTORED ==="
    Write-Output "================================================================="
    Write-Output "  VM IP:     $CacheIp"
    Write-Output "  Proxy URL: http://192.168.64.1:3128  (host forwarder → $CacheIp)"
    Write-Output "  Grafana:   http://192.168.64.1:3000"
    Write-Output "================================================================="
    exit 0
} else {
    Write-Warning "One or more forwarders are still DOWN — inspect $stateDir/forwarder.*.log"
    exit 1
}
