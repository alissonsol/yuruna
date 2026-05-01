<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456753
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
Probes for a running squid-cache VM and returns its proxy URL when found.

.DESCRIPTION
Mirrors the probe each guest.ubuntu.desktop/New-VM.ps1 runs at VM-creation
time, so multiple callers (Invoke-TestRunner startup banner,
Start-StatusServer status-page banner) cannot disagree with the URL that
gets injected into autoinstall user-data. The cache is a generic HTTP
proxy on port 3128.

Returns a string like "http://192.168.64.5:3128" when reachable, $null
otherwise.

Hyper-V: uses Hyper-V KVP first, falls back to ARP lookup by VM MAC on
the Default Switch interface. Only returns an IP after confirming port
3128 accepts a TCP connection (an IP alone doesn't prove squid is up —
cloud-init may still be installing inside the cache VM).

UTM: probes 127.0.0.1:3128 for the host-side forwarder launched by
Start-CachingProxy.ps1, and returns http://192.168.64.1:3128 when it
answers. Apple Virtualization shared-NAT isolates guest↔guest traffic,
so guests cannot reach the squid VM's IP directly (EHOSTUNREACH on ARP).
The forwarder bridges :3128 on the host to the cache VM, and guests
reach it via the VZ gateway address.
#>
function Test-CachingProxyAvailable {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string]$HostType)

    # External cache override. $Env:YURUNA_CACHING_PROXY_IP short-circuits
    # the per-platform local-VM discovery and uses a remote caching proxy at the
    # given IP. The remote image is assumed identical to the local one —
    # Apache on :80 publishes /yuruna-squid-ca.crt, squid on :3128 / :3129,
    # Grafana on :3000. Guests reach the remote IP through the host's
    # outbound NAT (Hyper-V Default Switch and Apple VZ shared-NAT both NAT
    # off-subnet), so no host-side forwarder is needed — the URL returned
    # here goes straight to the remote, unlike the macOS local-VM branch
    # which rewrites to the VZ gateway. If the remote doesn't answer on
    # :3128 we return $null (same "no cache" semantics as a stopped local
    # VM) rather than falling back to local discovery: the operator set the
    # variable deliberately, and silently switching to a local cache would
    # mask misconfiguration. Caller then logs "not detected" and guests run
    # direct against Ubuntu mirrors.
    if ($Env:YURUNA_CACHING_PROXY_IP) {
        $externIp = $Env:YURUNA_CACHING_PROXY_IP.Trim()
        if ($externIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
            Write-Warning "YURUNA_CACHING_PROXY_IP='$externIp' is not a valid IPv4 address — ignoring."
            return $null
        }
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $tcp.BeginConnect($externIp, 3128, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(1000) -and $tcp.Connected) {
                return "http://${externIp}:3128"
            }
        } catch {
            Write-Verbose "external caching proxy probe to ${externIp}:3128 failed: $($_.Exception.Message)"
        } finally {
            $tcp.Close()
        }
        Write-Warning "YURUNA_CACHING_PROXY_IP=${externIp} set but ${externIp}:3128 did not answer. Guests will download directly for this cycle."
        return $null
    }

    if ($HostType -eq 'host.windows.hyper-v') {
        $cacheVM = Get-VM -Name 'squid-cache' -ErrorAction SilentlyContinue
        if (-not $cacheVM -or $cacheVM.State -ne 'Running') { return $null }

        # Pull in VM.common.psm1's discovery helpers so this module and
        # New-VM.ps1 share one definition of "where do we look for the
        # cache VM's IP". Drift between the two would mean Invoke-Test-
        # Runner sees a different IP than the one provisioning printed.
        $vmCommon = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) `
            'virtual/host.windows.hyper-v/VM.common.psm1'
        if (Test-Path $vmCommon) { Import-Module $vmCommon -Force -ErrorAction SilentlyContinue }

        # Detect which vSwitch the cache is on. Yuruna-External (bridged
        # to the host's LAN NIC) puts the cache on a real LAN IP and is
        # what gets created by default; Default Switch is the fallback
        # when no LAN-routable physical NIC is available. The probe
        # logic differs in two ways for the External path:
        #   * the host's ARP cache isn't auto-populated (the host is no
        #     longer the DHCP server), so a one-shot LAN sweep makes
        #     KVP-empty discovery work in seconds rather than waiting
        #     for hv_kvp_daemon to come up minutes into runcmd.
        #   * the TCP probe shouldn't pin its source IP to a Default
        #     Switch vEthernet that doesn't even share a subnet with
        #     the cache — let the OS route normally via the LAN NIC.
        $cacheSwitchName  = ($cacheVM | Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
                              Select-Object -First 1).SwitchName
        $cacheOnExternal  = ($cacheSwitchName -eq 'Yuruna-External')

        if ($cacheOnExternal -and (Get-Command Invoke-YurunaExternalArpProbe -ErrorAction SilentlyContinue)) {
            # ~5 second parallel ICMP sweep of the host's /24 to fill
            # the host's neighbor cache. Subsequent Get-NetNeighbor in
            # Get-CacheVmCandidateIp then finds the cache VM's MAC.
            Invoke-YurunaExternalArpProbe -SwitchName 'Yuruna-External'
        }

        # Default-Switch path: pin the probe's source IP to the host's
        # Default Switch vNIC. Without this, the OS may route via the
        # LAN NIC and TCP-handshake against an IP that only exists
        # inside the cache VM (docker bridge, libvirt bridge, stale
        # dual-NIC config); the URL we'd return is unreachable from
        # the autoinstall guest, and curtin hangs for the full
        # apt-get connect timeout. Yuruna-External path: skip the bind
        # — the cache lives on the LAN, the same network plane an
        # autoinstall guest reaches through host routing/NAT.
        $bindIp = $null
        if (-not $cacheOnExternal) {
            $hostAdapter = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceAlias -like '*Default Switch*' } | Select-Object -First 1
            if ($hostAdapter) { $bindIp = $hostAdapter.IPAddress }
        }

        # Get-CacheVmCandidateIp (VM.common.psm1) returns KVP IPs first,
        # then ARP-cache entries scoped by VM MAC across all interfaces.
        # Hyper-V's Default Switch accumulates stale State='Permanent'
        # entries across cache-VM recreations, so the same MAC can appear
        # at two IPs — the foreach loop below picks whichever actually
        # answers on :3128, so a stale entry can't poison detection.
        $candidateIps = if (Get-Command Get-CacheVmCandidateIp -ErrorAction SilentlyContinue) {
            @(Get-CacheVmCandidateIp -VM $cacheVM)
        } else {
            # Fallback if VM.common.psm1 didn't import: KVP only.
            @($cacheVM | Get-VMNetworkAdapter | ForEach-Object { $_.IPAddresses } |
                Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
        }

        foreach ($ip in $candidateIps) {
            $tcp = New-Object System.Net.Sockets.TcpClient
            try {
                if ($bindIp) {
                    $tcp.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($bindIp), 0))
                }
                $async = $tcp.BeginConnect($ip, 3128, $null, $null)
                if ($async.AsyncWaitHandle.WaitOne(500) -and $tcp.Connected) {
                    return "http://${ip}:3128"
                }
            } catch {
                Write-Verbose "caching proxy probe to ${ip}:3128 (bind=$bindIp) failed: $($_.Exception.Message)"
            } finally {
                $tcp.Close()
            }
        }
        return $null
    }
    if ($HostType -eq 'host.macos.utm') {
        # On macOS VZ, the URL guests should use is http://192.168.64.1:3128
        # (the VZ gateway — the host). Probing the guest-VM IP directly
        # would return a URL guests cannot actually reach, because VZ's
        # shared-NAT blocks guest↔guest traffic. The host-side forwarder
        # launched by Start-CachingProxy.ps1 binds :3128 on the host and
        # tunnels to the cache VM — guests reach it as 192.168.64.1:3128.
        # So probe :3128 on the host's loopback to confirm the forwarder
        # is up, and return the gateway URL if it answers.
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $tcp.BeginConnect("127.0.0.1", 3128, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(200) -and $tcp.Connected) {
                return "http://192.168.64.1:3128"
            }
        } catch {
            Write-Verbose "host forwarder probe 127.0.0.1:3128 failed: $($_.Exception.Message)"
        } finally {
            $tcp.Close()
        }

        # Fallback: forwarder is down but the cache VM may still be up on
        # the VZ shared-NAT subnet. Read the real VM IP from cache-ip.txt
        # (written by Start-CachingProxy.ps1) and probe it directly. If it
        # answers, return the VM URL so host-side callers (Test-CachingProxy
        # and the host-only parts of Invoke-TestRunner / Start-StatusServer)
        # can still see the cache as "detected" — and, critically, so
        # Add-CachingProxyPortMap downstream has a target IP to re-spawn
        # the missing forwarder(s) with. The next call to this function
        # will then hit the :3128 loopback path above and return the
        # gateway URL again.
        #
        # Guest provisioners (virtual/*/New-VM.ps1) run their own inline
        # :3128 forwarder probe and do NOT consume this function's return
        # value, so they are unaffected — a dead forwarder still means
        # "install without cache" for the guest until the forwarder is
        # repaired, which is the correct guest-facing semantics.
        $cacheIpFile = Join-Path $HOME "virtual/squid-cache/cache-ip.txt"
        if (-not (Test-Path $cacheIpFile)) { return $null }
        $directIp = (Get-Content -Raw $cacheIpFile -ErrorAction SilentlyContinue).Trim()
        if ($directIp -notmatch '^\d+\.\d+\.\d+\.\d+$') { return $null }
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $tcp.BeginConnect($directIp, 3128, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(500) -and $tcp.Connected) {
                Write-Warning "squid-cache VM is up at ${directIp}:3128 but the host-side forwarder on 127.0.0.1:3128 is DOWN. Guests cannot reach the gateway URL until the forwarder is restored. Run: pwsh test/Repair-CachingProxyForwarder.ps1"
                return "http://${directIp}:3128"
            }
        } catch {
            Write-Verbose "direct cache probe ${directIp}:3128 failed: $($_.Exception.Message)"
        } finally {
            $tcp.Close()
        }
        return $null
    }
    return $null
}

<#
.SYNOPSIS
    Returns the actual IP of the local cache VM for Add-CachingProxyPortMap.

.DESCRIPTION
    Test-CachingProxyAvailable returns the guest-facing proxy URL. On macOS
    that URL contains the VZ gateway address (192.168.64.1), NOT the cache
    VM's real IP. Add-CachingProxyPortMap needs the real IP to set up
    host-side forwarders correctly — forwarding to 192.168.64.1 creates a
    self-referential loop that crashes the forwarder and breaks detection.

    Start-CachingProxy.ps1 writes the real VM IP to
    $HOME/virtual/squid-cache/cache-ip.txt after discovering it. This
    function reads that file.

    Returns $null on Windows (the guest URL already contains the correct VM
    IP) or when the file is absent — callers should then fall back to
    extracting the IP from the Test-CachingProxyAvailable URL.

.PARAMETER HostType
    Same host-type token as Test-CachingProxyAvailable.
#>
function Get-CachingProxyVMIp {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$HostType)

    if ($HostType -ne 'host.macos.utm') { return $null }

    $cacheIpFile = Join-Path $HOME "virtual/squid-cache/cache-ip.txt"
    if (-not (Test-Path $cacheIpFile)) { return $null }
    $raw = Get-Content $cacheIpFile -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { return $null }
    $ip = $raw.Trim()
    if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { return $ip }
    return $null
}

Export-ModuleMember -Function Test-CachingProxyAvailable, Get-CachingProxyVMIp
