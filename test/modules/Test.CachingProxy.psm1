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

        # Strategy 1: Hyper-V KVP via Get-VMNetworkAdapter. Requires
        # hv_kvp_daemon (hyperv-daemons) inside the guest. After a fresh
        # caching proxy install this is usually available, but if cloud-init
        # hasn't fully completed — or the daemon isn't running — IPAddresses
        # comes back empty.
        $candidateIps = @($cacheVM | Get-VMNetworkAdapter | ForEach-Object { $_.IPAddresses } |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })

        # Strategy 2: ARP cache lookup by VM MAC, scoped to the Default
        # Switch interface. Mirrors guest.squid-cache/New-VM.ps1 so detection
        # here cannot disagree with what the cache-VM creator discovered.
        if (-not $candidateIps) {
            $hostAdapter = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceAlias -like '*Default Switch*' } | Select-Object -First 1
            $vmMac = ($cacheVM | Get-VMNetworkAdapter | Select-Object -First 1).MacAddress
            if ($hostAdapter -and $vmMac -match '^[0-9A-Fa-f]{12}$' -and $vmMac -ne '000000000000') {
                $vmMacDashed = (($vmMac -replace '(..)(?!$)', '$1-')).ToUpper()
                # Collect ALL matching neighbor entries — Hyper-V's Default
                # Switch accumulates stale State='Permanent' entries across
                # cache-VM recreations, so the same MAC can appear at two
                # IPs. Picking -First 1 previously caused detection to land
                # on the stale IP and fail the :3128 probe. The foreach loop
                # below picks whichever candidate actually answers.
                $candidateIps = @(Get-NetNeighbor -AddressFamily IPv4 -InterfaceIndex $hostAdapter.InterfaceIndex -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.LinkLayerAddress -eq $vmMacDashed -and
                        $_.IPAddress -match '^\d+\.\d+\.\d+\.\d+$' -and
                        $_.State -ne 'Unreachable'
                    } | ForEach-Object { $_.IPAddress })
            }
        }

        # Confirm port 3128 is actually listening before claiming a cache —
        # an IP alone doesn't prove squid is up (cloud-init may still be
        # installing). Same probe shape as the macos.utm branch.
        foreach ($ip in $candidateIps) {
            $tcp = New-Object System.Net.Sockets.TcpClient
            try {
                $async = $tcp.BeginConnect($ip, 3128, $null, $null)
                if ($async.AsyncWaitHandle.WaitOne(500) -and $tcp.Connected) {
                    return "http://${ip}:3128"
                }
            } catch {
                Write-Verbose "caching proxy probe to ${ip}:3128 failed: $($_.Exception.Message)"
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
        return $null
    }
    return $null
}

Export-ModuleMember -Function Test-CachingProxyAvailable
