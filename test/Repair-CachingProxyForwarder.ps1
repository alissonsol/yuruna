<#PSScriptInfo
.VERSION 2026.06.26
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456771
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
    Verify the caching-proxy VM is reachable on the LAN and refresh the
    yuruna-caching-proxy state file. macOS/UTM only.

.DESCRIPTION
    Pre-bridged-mode this script revived dead host-side port forwarders.
    With VZBridgedNetworkDeviceAttachment (config.plist.template) the
    cache VM has its own LAN DHCP IP and there is no host-side forwarder
    layer to revive -- the LAN cable IS the data path. What can still
    drift is the state file under <track>/yuruna-caching-proxy.yml: an
    old shared-NAT IP from before the upgrade, or an empty entry from
    Stop-CachingProxy. This script:

      1. Calls Test-CachingProxyAvailable (state file only, no scan --
         see Yuruna.Host.psm1). Returns the URL or $null.
      2. Reports the cache URL + LAN IP for the operator.
      3. Tears down any leftover host-side forwarders from a prior
         shared-NAT cycle (Remove-PortMap), so a future Mac:3128 bind
         (e.g. another tool) does not conflict with stale pwsh
         subprocesses still listening from before the upgrade.

    Safe to re-run. NEVER touches: utmctl / the .utm bundle / the VM
    itself / Get-Image / cloud-init / system proxy / Wi-Fi / DNS.

    Auto-discovery: if the state file is empty (e.g. after Stop-
    CachingProxy.ps1) auto-discovery has nothing to consult and the
    script errors out. Re-run Start-CachingProxy.ps1 to repopulate, or
    pass -CacheIp <lan-ip> to commit a known IP directly. LAN-wide
    cache discovery is a separate future feature.

.PARAMETER CacheIp
    Override auto-discovery. When provided, the LAN scan is skipped and
    this IP is committed to the state file (after a quick :3128 probe
    confirms it answers). Must be IPv4.

.EXAMPLE
    pwsh test/Repair-CachingProxyForwarder.ps1

.EXAMPLE
    # State file has the wrong IP; you already know the right one:
    pwsh test/Repair-CachingProxyForwarder.ps1 -CacheIp 192.168.7.150
#>

param(
    [string]$CacheIp
)

$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

if (-not $IsMacOS) {
    Write-Error "Repair-CachingProxyForwarder.ps1 is macOS-only. On Hyper-V the External vSwitch keeps the cache LAN-direct with no host-side layer to repair."
    exit 1
}

Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths      = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
$RepoRoot   = $paths.RepoRoot
$ModulesDir = $paths.ModulesDir
# CachingProxy kind loads Test.VMUtility + Test.CachingProxy + Test.HostContract
# with -Global -Force, so the trio is in scope for the rest of the
# script.
Initialize-YurunaEntryPointModuleSet -For CachingProxy -ModulesDir $ModulesDir

[void](Initialize-YurunaHost -RepoRoot $RepoRoot)
# Re-import Test.CachingProxy -Global -Force AFTER Initialize-YurunaHost so
# Save-/Read-CachingProxyState survive the nested-import eviction triggered
# by Yuruna.Host.psm1's non-global Test.CachingProxy import at line 36 (which
# takes over the "active version" slot for the module). Same shape as
# Start-CachingProxy.ps1 / Stop-CachingProxy.ps1 use to keep the state-file
# helpers visible.
Import-Module (Join-Path $ModulesDir 'Test.CachingProxy.psm1') -Global -Force -Verbose:$false

$StateFile = Get-CachingProxyStatePath
$httpPort  = Get-CachingProxyPort -Scheme http
$httpsPort = Get-CachingProxyPort -Scheme https

if ($CacheIp -and -not (Test-IpAddress $CacheIp)) {
    Write-Error "CacheIp '$CacheIp' is not a valid IPv4 or IPv6 address."
    exit 1
}

# === Step 1: tear down legacy shared-NAT forwarders ========================
# The cache lives directly on the LAN now. Any pwsh forwarder.<port>.pid
# subprocess left behind from the legacy shared-NAT layout is noise --
# it binds 0.0.0.0:<port> on this Mac, tunnels to a stale 192.168.64.X
# IP that may have been reassigned, and blocks anything else (this very
# script's verification probes; a remote host that points
# YURUNA_CACHING_PROXY_IP back at the Mac instead of the cache) from
# reusing those ports. No-op on a fresh install.
Write-Output ""
Write-Output "== Step 1: tear down any legacy host-side forwarders =="
[void](Remove-PortMap -Confirm:$false)

# === Step 2: locate + verify the cache =====================================
Write-Output ""
Write-Output "== Step 2: locate the cache VM on the LAN =="
if ($CacheIp) {
    $tcp = [System.Net.Sockets.TcpClient]::new()
    $reachable = $false
    try {
        $async = $tcp.BeginConnect($CacheIp, $httpPort, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne(1500) -and $tcp.Connected) { $reachable = $true }
    } catch {
        Write-Verbose "-CacheIp probe ${CacheIp}:${httpPort} failed: $($_.Exception.Message)"
    } finally {
        $tcp.Close()
    }
    if (-not $reachable) {
        Write-Error "${CacheIp}:${httpPort} did not answer. The IP you passed is not serving squid. If the VM is up but on a different LAN IP, omit -CacheIp and let the LAN scan find it."
        exit 1
    }
    Write-Output "  -CacheIp parameter probed OK: ${CacheIp}:${httpPort} answered."
    $foundUrl = "http://$(Format-IpUrlHost $CacheIp):${httpPort}"
    [void](Save-CachingProxyState -IpAddress $CacheIp -Confirm:$false)
} else {
    # Test-CachingProxyAvailable does the state-file fast path + LAN
    # /24 scan + state refresh atomically. No need to re-implement here.
    $foundUrl = Test-CachingProxyAvailable
    if (-not $foundUrl) {
        Write-Error "Could not locate yuruna-caching-proxy VM on the LAN."
        Write-Error "  Yuruna.Host.psm1's Test-CachingProxyAvailable returned no URL."
        Write-Error "  If the VM is stopped/missing, rebuild with: pwsh test/Start-CachingProxy.ps1"
        Write-Error "  If you already know the VM's LAN IP, rerun with:"
        Write-Error "    pwsh test/Repair-CachingProxyForwarder.ps1 -CacheIp <lan-ip>"
        exit 1
    }
    if ($foundUrl -match '^http://([0-9.]+):') { $CacheIp = $matches[1] } else { $CacheIp = '' }
}

# === Step 3: summarize =====================================================
Write-Output ""
Write-Output "================================================================="
Write-Output "== caching-proxy REACHABLE (LAN-direct) =="
Write-Output "================================================================="
Write-Output "  VM IP:       $CacheIp"
Write-Output "  Proxy URL:   $foundUrl"
Write-Output "  HTTPS bump:  http://${CacheIp}:${httpsPort}"
Write-Output "  Grafana:     http://${CacheIp}:3000"
Write-Output "  Recent 100:  http://${CacheIp}:9302/"
Write-Output "  cachemgr:    http://${CacheIp}/cgi-bin/cachemgr.cgi"
Write-Output "  CA cert:     http://${CacheIp}/yuruna-squid-ca.crt"
Write-Output "  State file:  $StateFile  (refreshed)"
Write-Output "================================================================="
exit 0
