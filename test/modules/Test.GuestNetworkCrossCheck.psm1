<#PSScriptInfo
.VERSION 2026.10.22
.GUID 4267ee73-f58a-4dfa-94f2-3b782d20040d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna runner diagnostics network cross-check
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

# Host-side cross-check of the two ends a failed cycle gets blamed on: the
# caching proxy and the guest. A guest that loses its address mid-cycle and a
# proxy that stops answering can leave the same console behind; recording
# which endpoints the HOST can still reach narrows the investigation without
# claiming that the guest's egress path was tested. Leaf module:
# it imports nothing. The proven-address memo, the host driver and the event
# writer are resolved at call time and Get-Command-guarded, so the check runs
# on every host type and inside a session that loaded none of them, and it
# never throws: a failed probe is a reading, not a fault of its own.

$script:GuestNetworkCrossCheckCachePort = 5000

function Resolve-GuestNetworkCrossCheckCacheHost {
    <#
    .SYNOPSIS
        The caching-proxy host to probe: the parameter, else the address the
        runner resolved for this cycle in $env:YURUNA_CACHING_PROXY_SERVICE_IP.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$CacheHost)
    $candidate = if (-not [string]::IsNullOrWhiteSpace($CacheHost)) { $CacheHost } else { [string]$env:YURUNA_CACHING_PROXY_SERVICE_IP }
    return ([string]$candidate).Trim()
}

function Resolve-GuestNetworkCrossCheckProxyPort {
    <#
    .SYNOPSIS
        Resolve a proxy listener through the loaded shared helper, retaining
        the environment override and defaults when this leaf runs alone.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([ValidateSet('http', 'https')][string]$Scheme)
    if (Get-Command Get-CachingProxyServicePort -ErrorAction SilentlyContinue) {
        try { return Get-CachingProxyServicePort -Scheme $Scheme }
        catch { Write-Verbose "shared proxy port lookup unavailable: $($_.Exception.Message)" }
    }
    $value = [Environment]::GetEnvironmentVariable("YURUNA_CACHING_PROXY_SERVICE_$($Scheme.ToUpperInvariant())_PORT")
    $port = 0
    if ([int]::TryParse($value, [ref]$port) -and $port -gt 0 -and $port -lt 65536) { return $port }
    if ($Scheme -eq 'https') { return 3129 }
    return 3128
}

function Resolve-GuestNetworkCrossCheckGuestAddress {
    <#
    .SYNOPSIS
        The guest address to probe and where it came from: the parameter, else
        the address SSH last authenticated to, else what the host driver reports.
    .OUTPUTS
        [hashtable] address (empty when none), source.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$GuestAddress
    )
    if (-not [string]::IsNullOrWhiteSpace($GuestAddress)) { return @{ address = $GuestAddress.Trim(); source = 'parameter' } }
    if (Get-Command 'Test.Ssh\Get-ProvenGuestAddress' -ErrorAction SilentlyContinue) {
        try {
            $proven = [string](Test.Ssh\Get-ProvenGuestAddress -VMName $VMName)
            if (-not [string]::IsNullOrWhiteSpace($proven)) { return @{ address = $proven.Trim(); source = 'proven-ssh' } }
        } catch { Write-Verbose "proven guest address unavailable: $($_.Exception.Message)" }
    }
    if (Get-Command Get-VMIp -ErrorAction SilentlyContinue) {
        try {
            $reported = [string](Get-VMIp -VMName $VMName)
            if (-not [string]::IsNullOrWhiteSpace($reported)) { return @{ address = $reported.Trim(); source = 'host-driver' } }
        } catch { Write-Verbose "host driver guest address unavailable: $($_.Exception.Message)" }
    }
    return @{ address = ''; source = 'none' }
}

function Test-GuestNetworkCrossCheckHttp {
    <#
    .SYNOPSIS
        One bounded GET. `answered` is true for any HTTP status, because a 401
        or 404 still proves the host and the service are there; `ok` is 2xx.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$TimeoutSec = 5
    )
    $result = [ordered]@{ uri = $Uri; answered = $false; ok = $false; status = $null; ms = $null; firstLine = $null; error = $null }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -NoProxy -TimeoutSec $TimeoutSec -ErrorAction Stop
        $result.status = [int]$response.StatusCode
        $result.ok = $true
        $content = [string]$response.Content
        if ($content) {
            $first = (($content -split "`r?`n")[0]).Trim()
            if ($first.Length -gt 200) { $first = $first.Substring(0, 200) }
            $result.firstLine = $first
        }
    } catch {
        $result.error = $_.Exception.Message
        $failed = $_.Exception.Response
        if ($failed) { try { $result.status = [int]$failed.StatusCode } catch { $null = $_ } }
    }
    $result.answered = ($null -ne $result.status)
    $result.ms = [int]$clock.ElapsedMilliseconds
    return $result
}

function Test-GuestNetworkCrossCheckTcpPort {
    <#
    .SYNOPSIS
        One TCP connect with a hard deadline; the socket closes on every path.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Address,
        [int]$Port = 22,
        [int]$TimeoutMs = 2000
    )
    $result = [ordered]@{ address = $Address; port = $Port; open = $false; ms = $null; error = $null }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $tcp = $null
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $async = $tcp.BeginConnect($Address, $Port, $null, $null)
        $result.open = [bool]($async.AsyncWaitHandle.WaitOne($TimeoutMs) -and $tcp.Connected)
        if (-not $result.open) { $result.error = 'timeout' }
    } catch {
        $result.error = $_.Exception.Message
    } finally {
        if ($tcp) { $tcp.Close() }
    }
    $result.ms = [int]$clock.ElapsedMilliseconds
    return $result
}

function Test-GuestNetworkCrossCheckPing {
    <#
    .SYNOPSIS
        One ICMP echo with a two-second budget. $null when the host cannot
        say (no cmdlet, or it failed to run), so an unknown never reads as a
        guest that stayed silent.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Address)
    if (-not (Get-Command Test-Connection -ErrorAction SilentlyContinue)) { return $null }
    try {
        $reply = Test-Connection -TargetName $Address -Count 1 -TimeoutSeconds 2 -Quiet -ErrorAction SilentlyContinue
        if ($null -eq $reply) { return $null }
        return [bool]$reply
    } catch {
        Write-Verbose "ping of $Address unavailable: $($_.Exception.Message)"
        return $null
    }
}

function Get-GuestNetworkCrossCheckNeighborState {
    <#
    .SYNOPSIS
        What the host's neighbor cache holds for the address: the entry's
        state and MAC, 'absent' when the cache has none, 'unavailable' when
        this host offers no way to ask.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Address)
    try {
        if (Get-Command Get-NetNeighbor -ErrorAction SilentlyContinue) {
            $entry = @(Get-NetNeighbor -IPAddress $Address -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($entry.Count) { return ("$($entry[0].State) $($entry[0].LinkLayerAddress)").Trim() }
            return 'absent'
        }
        if (Get-Command ip -CommandType Application -ErrorAction SilentlyContinue) {
            $rows = @(& ip -4 neigh show to $Address 2>$null | Where-Object { $_ })
            if ($rows.Count) { return ([string]$rows[0]).Trim() }
            return 'absent'
        }
        if (Get-Command arp -CommandType Application -ErrorAction SilentlyContinue) {
            $rows = @(& arp -n $Address 2>$null | Where-Object { $_ -match [regex]::Escape($Address) })
            if ($rows.Count -and ($rows[0] -notmatch 'no entry')) { return ([string]$rows[0]).Trim() }
            return 'absent'
        }
        return 'unavailable'
    } catch {
        Write-Verbose "neighbor cache lookup of $Address unavailable: $($_.Exception.Message)"
        return 'unavailable'
    }
}

function Get-GuestNetworkCrossCheckVerdict {
    <#
    .SYNOPSIS
        The pure verdict: which of the two ends the host could reach, with an
        explicit "unknown" for an end it had no address for, so a missing
        address never reads as a silent machine.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [bool]$HasCacheHost,
        [bool]$HasGuestAddress,
        [bool]$ProxyReachable,
        [bool]$GuestReachable
    )
    if (-not $HasCacheHost -and -not $HasGuestAddress) { return 'unavailable' }
    if (-not $HasCacheHost) { if ($GuestReachable) { return 'guest-reachable-proxy-unknown' } else { return 'guest-unreachable-proxy-unknown' } }
    if (-not $HasGuestAddress) { if ($ProxyReachable) { return 'proxy-reachable-guest-unknown' } else { return 'proxy-unreachable-guest-unknown' } }
    if ($ProxyReachable -and $GuestReachable) { return 'both-reachable' }
    if ($ProxyReachable) { return 'proxy-reachable-guest-unreachable' }
    if ($GuestReachable) { return 'proxy-unreachable-guest-reachable' }
    return 'both-unreachable'
}

function Format-GuestNetworkCrossCheckText {
    <#
    .SYNOPSIS
        The short human summary written as network-cross-check.txt.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Result)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("vmName:      $($Result.vmName)")
    $lines.Add("guestKey:    $($Result.guestKey)")
    $lines.Add("checkedUtc:  $($Result.timestampUtc)")
    $lines.Add("verdict:     $($Result.verdict)")
    if ($Result.cacheHost) {
        $lines.Add("cacheHost:   $($Result.cacheHost)")
        foreach ($name in 'cacheHttpTcp', 'cacheHttpsTcp') {
            $probe = $Result[$name]
            if (-not $probe) { continue }
            $detail = "open=$($probe.open) ms=$($probe.ms)"
            if ($probe.error) { $detail += " error=$($probe.error)" }
            $lines.Add("${name}: $($probe.address):$($probe.port) $detail")
        }
        foreach ($name in 'cacheV2', 'cacheHealth') {
            $probe = $Result[$name]
            if (-not $probe) { continue }
            $detail = if ($null -ne $probe.status) { "status=$($probe.status)" } else { 'no response' }
            $detail += " ms=$($probe.ms)"
            if ($probe.error) { $detail += " error=$($probe.error)" }
            if ($probe.firstLine) { $detail += " first line: $($probe.firstLine)" }
            $lines.Add(("{0,-12} {1} {2}" -f ($name + ':'), $probe.uri, $detail))
        }
    } else {
        $lines.Add('cacheHost:   (none: no -CacheHost and no YURUNA_CACHING_PROXY_SERVICE_IP in this process)')
    }
    if ($Result.guestAddress) {
        $lines.Add("guest:       $($Result.guestAddress) (from $($Result.guestAddressSource))")
        if ($Result.guestTcp22) {
            $lines.Add("tcp22:       open=$($Result.guestTcp22.open) ms=$($Result.guestTcp22.ms)$(if ($Result.guestTcp22.error) { " error=$($Result.guestTcp22.error)" })")
        }
        $lines.Add("ping:        $(if ($null -eq $Result.guestPingOk) { 'unavailable' } else { $Result.guestPingOk })")
        $lines.Add("neighbor:    $($Result.neighborState)")
    } else {
        $lines.Add('guest:       (no address: none passed, none proven by SSH this cycle, none reported by the host driver)')
    }
    if ($Result.error) { $lines.Add("error:       $($Result.error)") }
    $lines.Add('reading:     the verdict combines cacheV2/cacheHealth HTTP responses with guest')
    $lines.Add('             TCP 22/ICMP replies, all observed from the host at capture time.')
    $lines.Add('             cacheHttpTcp/cacheHttpsTcp separately record proxy listener access;')
    $lines.Add('             they do not change the verdict. An open TCP port does not prove TLS')
    $lines.Add('             or upstream service health. both-reachable does not establish guest egress')
    $lines.Add('             or rule out an earlier transient failure. An -unknown side had no address.')
    return $lines.ToArray()
}

function Invoke-GuestNetworkCrossCheck {
    <#
    .SYNOPSIS
        Probe the caching proxy and the guest from the host, write
        network-cross-check.json and network-cross-check.txt into
        OutputDirectory, emit the network_cross_check cycle event, and return
        the reading. Never throws.
    .DESCRIPTION
        The proxy is probed on its registry endpoint (http://<cache>:5000/v2/)
        and its health page (http://<cache>/cache-health); any HTTP status
        counts as reachable because the question is whether the host can reach
        it, not whether it is healthy, and the statuses are recorded for the
        reader who asks the second question. The guest is probed on TCP 22 and
        ICMP, and the host's neighbor cache is read for its address, so a guest
        that answers ARP but not SSH is distinguishable from one that is gone.
        Separate two-second TCP probes record the HTTP and HTTPS proxy
        listeners before the HTTP requests can consume their timeout budgets.
        These use the configured proxy ports (defaults 3128/3129) and do not
        alter the existing host-reachability verdict or test guest egress.
    .PARAMETER TcpProbe
        Test seam: a scriptblock taking (address, port) that returns the TCP
        probe record, in place of the built-in connect.
    .OUTPUTS
        [ordered] the reading; `verdict` is one of the values
        Get-GuestNetworkCrossCheckVerdict produces.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [AllowEmptyString()][string]$GuestKey = '',
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$CacheHost,
        [string]$GuestAddress,
        [scriptblock]$TcpProbe
    )
    $result = [ordered]@{
        schema = 'yuruna.network-cross-check/v1'
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        vmName = $VMName
        guestKey = $GuestKey
        verdict = 'unavailable'
        cacheHost = ''
        cacheV2 = $null
        cacheHealth = $null
        cacheHttpTcp = $null
        cacheHttpsTcp = $null
        proxyReachable = $false
        guestAddress = ''
        guestAddressSource = 'none'
        guestTcp22 = $null
        guestPingOk = $null
        neighborState = 'unavailable'
        guestReachable = $false
        error = $null
    }
    try {
        $cache = Resolve-GuestNetworkCrossCheckCacheHost -CacheHost $CacheHost
        $result.cacheHost = $cache
        # Each probe is caught where it is called as well as inside: a reading
        # that could not be taken is recorded as unknown, never as a silence,
        # and never stops the probes that follow it.
        if ($cache) {
            foreach ($listener in @(
                    @{ key = 'cacheHttpTcp'; scheme = 'http' }
                    @{ key = 'cacheHttpsTcp'; scheme = 'https' })) {
                $port = $null
                try {
                    $port = Resolve-GuestNetworkCrossCheckProxyPort -Scheme $listener.scheme
                    $result[$listener.key] = if ($TcpProbe) { & $TcpProbe $cache $port } else { Test-GuestNetworkCrossCheckTcpPort -Address $cache -Port $port -TimeoutMs 2000 }
                } catch {
                    $result[$listener.key] = [ordered]@{ address = $cache; port = $port; open = $false; ms = $null; error = $_.Exception.Message }
                }
            }
            foreach ($endpoint in @(
                    @{ key = 'cacheV2'; uri = "http://${cache}:$($script:GuestNetworkCrossCheckCachePort)/v2/" }
                    @{ key = 'cacheHealth'; uri = "http://${cache}/cache-health" })) {
                try {
                    $result[$endpoint.key] = Test-GuestNetworkCrossCheckHttp -Uri $endpoint.uri
                } catch {
                    $result[$endpoint.key] = [ordered]@{ uri = $endpoint.uri; answered = $false; ok = $false; status = $null; ms = $null; firstLine = $null; error = $_.Exception.Message }
                }
            }
            $result.proxyReachable = [bool]($result.cacheV2.answered -or $result.cacheHealth.answered)
        }
        $guest = Resolve-GuestNetworkCrossCheckGuestAddress -VMName $VMName -GuestAddress $GuestAddress
        $result.guestAddress = [string]$guest.address
        $result.guestAddressSource = [string]$guest.source
        if ($result.guestAddress) {
            try {
                $result.guestTcp22 = if ($TcpProbe) { & $TcpProbe $result.guestAddress 22 } else { Test-GuestNetworkCrossCheckTcpPort -Address $result.guestAddress -Port 22 -TimeoutMs 2000 }
            } catch {
                $result.guestTcp22 = [ordered]@{ address = $result.guestAddress; port = 22; open = $false; ms = $null; error = $_.Exception.Message }
            }
            try { $result.guestPingOk = Test-GuestNetworkCrossCheckPing -Address $result.guestAddress } catch { $result.guestPingOk = $null }
            try { $result.neighborState = Get-GuestNetworkCrossCheckNeighborState -Address $result.guestAddress } catch { $result.neighborState = 'unavailable' }
            $result.guestReachable = [bool](($result.guestTcp22 -and $result.guestTcp22.open) -or ($result.guestPingOk -eq $true))
        }
        $result.verdict = Get-GuestNetworkCrossCheckVerdict -HasCacheHost ([bool]$cache) -HasGuestAddress ([bool]$result.guestAddress) `
            -ProxyReachable $result.proxyReachable -GuestReachable $result.guestReachable
    } catch {
        $result.error = $_.Exception.Message
    }
    try {
        if (-not (Test-Path -LiteralPath $OutputDirectory)) {
            New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
        }
        $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'network-cross-check.json') -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'network-cross-check.txt') -Encoding utf8NoBOM -Value (Format-GuestNetworkCrossCheckText -Result $result)
    } catch {
        Write-Verbose "network cross-check files not written: $($_.Exception.Message)"
    }
    try {
        if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
            Send-CycleEventSafely -EventRecord @{
                timestamp     = [datetime]::UtcNow.ToString('o')
                event         = 'network_cross_check'
                vmName        = [string]$VMName
                guestKey      = [string]$GuestKey
                verdict       = [string]$result.verdict
                cacheHost     = [string]$result.cacheHost
                cacheV2Status = $(if ($result.cacheV2) { $result.cacheV2.status } else { $null })
                cacheV2Ms     = $(if ($result.cacheV2) { $result.cacheV2.ms } else { $null })
                cacheHealthOk = [bool]($result.cacheHealth -and $result.cacheHealth.ok)
                cacheHttpTcp  = $result.cacheHttpTcp
                cacheHttpsTcp = $result.cacheHttpsTcp
                guestAddress  = [string]$result.guestAddress
                guestTcp22Ok  = [bool]($result.guestTcp22 -and $result.guestTcp22.open)
                guestPingOk   = $result.guestPingOk
                neighborState = [string]$result.neighborState
            }
        }
    } catch {
        Write-Verbose "network_cross_check event not emitted: $($_.Exception.Message)"
    }
    return $result
}

Export-ModuleMember -Function Invoke-GuestNetworkCrossCheck, Get-GuestNetworkCrossCheckVerdict
