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

UTM: sweeps the Apple-Virtualization shared-NAT subnet 192.168.64.2-30
for a :3128 listener. Matches the probe range in
guest.ubuntu.desktop/New-VM.ps1.
#>
function Test-ProxyCacheAvailable {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string]$HostType)

    if ($HostType -eq 'host.windows.hyper-v') {
        $cacheVM = Get-VM -Name 'squid-cache' -ErrorAction SilentlyContinue
        if (-not $cacheVM -or $cacheVM.State -ne 'Running') { return $null }

        # Strategy 1: Hyper-V KVP via Get-VMNetworkAdapter. Requires
        # hv_kvp_daemon (hyperv-daemons) inside the guest. After a fresh
        # squid-cache install this is usually available, but if cloud-init
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
                Write-Verbose "squid-cache probe to ${ip}:3128 failed: $($_.Exception.Message)"
            } finally {
                $tcp.Close()
            }
        }
        return $null
    }
    if ($HostType -eq 'host.macos.utm') {
        # UTM guests on Apple Virtualization live on 192.168.64.0/24; probe
        # .2-.30 for a squid listener on 3128. Matches the probe range in
        # guest.ubuntu.desktop/New-VM.ps1 so banner and injected URL agree.
        for ($octet = 2; $octet -le 30; $octet++) {
            $candidate = "192.168.64.$octet"
            $tcp = New-Object System.Net.Sockets.TcpClient
            try {
                $async = $tcp.BeginConnect($candidate, 3128, $null, $null)
                if ($async.AsyncWaitHandle.WaitOne(200) -and $tcp.Connected) {
                    return "http://${candidate}:3128"
                }
            } catch {
                Write-Verbose "squid-cache probe to ${candidate}:3128 failed: $($_.Exception.Message)"
            } finally {
                $tcp.Close()
            }
        }
        return $null
    }
    return $null
}

Export-ModuleMember -Function Test-ProxyCacheAvailable
