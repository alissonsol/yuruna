<#PSScriptInfo
.VERSION 0.1
.GUID 42c0ffee-a0de-4e1f-a2b3-c4d5e6f7a8b9
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

# --- Define Oscdimg Path (adjust '10' for your ADK version if necessary) ---
$OscdimgPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\Oscdimg.exe"

function CreateIso {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$OutputFile,
        [string]$VolumeId = "cidata"
    )

    $cwd = (Get-Location).ProviderPath

    # Make SourceDir absolute if relative
    if (-not [System.IO.Path]::IsPathRooted($SourceDir)) {
        $SourceDir = Join-Path $cwd $SourceDir
    }
    $SourceDir = [System.IO.Path]::GetFullPath($SourceDir)

    if (-not (Test-Path -Path $SourceDir)) {
        Throw "SourceDir not found: $SourceDir"
    }

    # Make OutputFile absolute if relative
    if (-not [System.IO.Path]::IsPathRooted($OutputFile)) {
        $OutputFile = Join-Path $cwd $OutputFile
    }
    $OutputFile = [System.IO.Path]::GetFullPath($OutputFile)

    $outDir = Split-Path -Path $OutputFile -Parent
    if ($outDir -and -not (Test-Path -Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    if (-not (Test-Path -Path $OscdimgPath)) {
        Throw "Oscdimg.exe not found at path: $OscdimgPath. Install the Windows ADK Deployment Tools or set ``-OscdimgPath`` to the proper location."
    }

    Write-Information "Creating ISO `nfrom '$SourceDir' `nto '$OutputFile' `nwith Volume ID '$VolumeId'..."
    & $OscdimgPath "$SourceDir" "$OutputFile" -n -h -m -l"$VolumeId"

    Write-Output "ISO created successfully at: $OutputFile"
}

# --- squid-cache IP discovery (shared by producer + consumers) --------------
# Prior state copy-pasted the KVP+ARP dual strategy across squid-cache,
# ubuntu.server, ubuntu.desktop New-VM.ps1s plus a KVP-only variant in
# test/Start-CachingProxy.ps1. The variants drifted — Start-SquidCache's
# KVP-only summary printed "(discovery failed)" even while the inner
# ARP path had already succeeded and the cache was serving. These three
# functions are the single source of truth.

function Get-CacheVmCandidateIp {
    <#
    .SYNOPSIS
        Candidate IPv4 addresses for a running Hyper-V VM.
    .DESCRIPTION
        Combines two lookups, dedup, KVP first:
          1. Hyper-V KVP (Get-VMNetworkAdapter.IPAddresses) — needs
             hv_kvp_daemon inside the guest; empty until hyperv-daemons
             is installed and the daemon running. Once it's up, the
             single source of truth regardless of which vSwitch the VM
             is attached to (Default Switch or External).
          2. ARP-cache fallback for the early-boot window before KVP is
             populated. Filtered by the VM's MAC across ALL host
             interfaces (Default Switch's vEthernet for guests on the
             internal NAT, plus the External-vSwitch vEthernet for the
             squid-cache VM after the External-vSwitch migration). The
             MAC filter is sufficient — it can only match neighbors of
             this specific VM. Stale 'Permanent' entries across VM
             rebuilds can map one MAC to multiple IPs; all returned so
             the caller's :3128 probe picks the live one.
    .OUTPUTS
        System.String[] — zero or more IPv4, KVP entries first.
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $VM
    )

    $kvpIps = @($VM | Get-VMNetworkAdapter |
        ForEach-Object { $_.IPAddresses } |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })

    $arpIps = @()
    $vmMac = ($VM | Get-VMNetworkAdapter | Select-Object -First 1).MacAddress
    if ($vmMac -match '^[0-9A-Fa-f]{12}$' -and $vmMac -ne '000000000000') {
        $vmMacDashed = (($vmMac -replace '(..)(?!$)', '$1-')).ToUpper()
        # No InterfaceIndex filter: the MAC is the VM's MAC and only that
        # VM can populate the ARP cache with it. This catches both Default
        # Switch (172.x) and External vSwitch (real LAN IP) entries.
        $arpIps = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LinkLayerAddress -eq $vmMacDashed -and
                $_.IPAddress -match '^\d+\.\d+\.\d+\.\d+$' -and
                $_.State -ne 'Unreachable'
            } | ForEach-Object { $_.IPAddress })
    }

    # Emit individual strings into the pipeline. Callers that need a
    # guaranteed array wrap with @().
    #
    # Three traps this shape avoids:
    # 1. No leading `,` array-wrap — made the function emit ONE String[];
    #    @(Get-CacheVmCandidateIp ...) then wrapped into Object[1] whose
    #    sole element was the array, breaking `foreach ($ip in ...)`
    #    with "Cannot convert value to type System.String".
    # 2. No `[string[]](pipeline)` as the return expression — on empty
    #    input the cast emits a single $null instead of zero items, so
    #    callers get a ghost element.
    # 3. No outer `@(...)` — PSScriptAnalyzer statically infers
    #    System.Array from the @-subexpression even with string content,
    #    tripping PSUseOutputTypeCorrectly. The bare pipeline emits
    #    strings directly.
    ($kvpIps + $arpIps) | Select-Object -Unique
}

<#
.SYNOPSIS
    Idempotently create (or return) the Yuruna External vSwitch bridged
    to the host's primary physical NIC.
.DESCRIPTION
    The squid-cache VM rides on this switch (instead of the built-in
    Default Switch) so it gets a real LAN IP via DHCP and is reachable
    by remote LAN clients without any host-side port forwarding. squid
    sees the actual LAN client IP at TCP level — no PROXY-protocol
    forwarder needed and no Defender per-program filtering layer to
    fight (which is what blocked the user-mode forwarder path on
    Hyper-V hosts; see test/Start-CachingProxy.ps1 for the long note).

    Picks the NIC carrying the default IPv4 route (the one with actual
    LAN connectivity, by definition). Wi-Fi works in principle but most
    Wi-Fi APs reject MAC addresses they didn't authenticate, so the
    cache VM may fail DHCP or be unreachable from peers — flagged with
    a warning, not a hard error.

    -AllowManagementOS:$true keeps the host's own networking on the
    same physical NIC after the bridge — without it, creating the
    External vSwitch would strand the host until the operator manually
    re-binds protocols. Brief (~5s) network blip during creation is
    inherent to Hyper-V vSwitch reconfiguration.

    Idempotent: re-runs return the existing switch. Removing it
    requires explicit Remove-VMSwitch (we don't auto-clean — operators
    may have other VMs on the same External vSwitch).

    Requires admin (vmms calls). Returns $null on any failure so the
    caller can decide whether to fall back to Default Switch.
.OUTPUTS
    [string] switch name (typically 'Yuruna-External'), or $null on failure.
#>
function Get-OrCreateYurunaExternalSwitch {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [string]$SwitchName = 'Yuruna-External'
    )

    $existing = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.SwitchType -ne 'External') {
            Write-Output "WARNING: switch '$SwitchName' exists but is type '$($existing.SwitchType)', not External. Cache VM may not be LAN-reachable."
        }
        return $SwitchName
    }

    # Pick the NIC carrying the default IPv4 route. Filter routes that
    # are themselves through a vEthernet (Default Switch / Hyper-V
    # internal switches) to avoid feedback if a prior bad bridge state
    # left a vEthernet as default.
    $defaultRoute = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' -and $_.NextHop -ne '::' } |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1
    if (-not $defaultRoute) {
        Write-Output "ERROR: No IPv4 default route on the host. Cannot create External vSwitch — connect a NIC to the LAN first."
        return $null
    }

    $nic = Get-NetAdapter -InterfaceIndex $defaultRoute.InterfaceIndex -ErrorAction SilentlyContinue
    if (-not $nic) {
        Write-Output "ERROR: Cannot resolve adapter for default-route InterfaceIndex $($defaultRoute.InterfaceIndex)."
        return $null
    }

    if ($nic.Status -ne 'Up') {
        Write-Output "ERROR: Adapter '$($nic.InterfaceAlias)' is in state '$($nic.Status)', not Up. Cannot bridge."
        return $null
    }

    if ($nic.PhysicalMediaType -eq 'Native 802.11') {
        Write-Output "WARNING: Default-route adapter '$($nic.InterfaceAlias)' is Wi-Fi."
        Write-Output "  Hyper-V External vSwitch on Wi-Fi: most APs refuse to forward frames"
        Write-Output "  for MACs they didn't authenticate, so the cache VM's DHCP request"
        Write-Output "  may go unanswered and remote LAN clients may not reach it. If LAN"
        Write-Output "  reachability fails, run on a wired connection."
    }

    if (-not $PSCmdlet.ShouldProcess($SwitchName, "Create External vSwitch bridged on '$($nic.InterfaceAlias)' with -AllowManagementOS")) {
        return $null
    }

    Write-Output "Creating External vSwitch '$SwitchName' bridged on '$($nic.InterfaceAlias)'..."
    Write-Output "  (host networking will briefly drop on this NIC during the bind;"
    Write-Output "   open SSH/RDP sessions through it will reconnect.)"
    try {
        New-VMSwitch -Name $SwitchName -NetAdapterName $nic.InterfaceAlias -AllowManagementOS:$true -ErrorAction Stop | Out-Null
    } catch {
        Write-Output "ERROR: New-VMSwitch failed: $($_.Exception.Message)"
        return $null
    }

    Write-Output "External vSwitch '$SwitchName' ready."
    return $SwitchName
}

function Test-CachingProxyPort {
    <#
    .SYNOPSIS
        Non-blocking TCP probe: $true iff the port accepts within $TimeoutMs.
    .DESCRIPTION
        Synchronous TcpClient.Connect() blocks ~20s on a filtered or
        silently-dropped port and starves outer progress loops; async
        BeginConnect + WaitOne caps the wait predictably.
    #>
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [int]$Port = 3128,
        [int]$TimeoutMs = 500
    )
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $tcp.BeginConnect($IpAddress, $Port, $null, $null)
        return ($async.AsyncWaitHandle.WaitOne($TimeoutMs) -and $tcp.Connected)
    } catch {
        Write-Verbose "probe ${IpAddress}:${Port} failed: $($_.Exception.Message)"
        return $false
    } finally {
        $tcp.Close()
    }
}

<#
.SYNOPSIS
    Populate the host's ARP cache on the Yuruna-External subnet by
    sweep-pinging it in parallel. Cheap fallback for IP discovery when
    the cache VM has DHCP'd a LAN address but hv_kvp_daemon hasn't
    started yet.
.DESCRIPTION
    On the Default Switch path, the host is the NAT/DHCP server so the
    cache VM's MAC↔IP mapping lands in the ARP cache the moment DHCP
    completes. On External vSwitch the LAN's DHCP server (not the host)
    answers, so the host has no reason to ARP for the VM's IP and
    `Get-NetNeighbor` returns nothing — even though the VM is up,
    has its lease, and is happily installing apt packages. KVP would
    eventually fill this gap, but `hv_kvp_daemon` only starts late in
    cloud-init's runcmd (after grafana / prometheus / loki / squid have
    all installed) — that's 5-15 minutes of "not discovered yet" while
    the VM is actually fine.

    This active sweep ARP-resolves every IP on the host's
    Yuruna-External subnet (parallel `Test-Connection -Count 1
    -TimeoutSeconds 1`, throttle 64). Responses populate the host's
    neighbor cache; subsequent `Get-NetNeighbor` calls then find the
    cache VM at its DHCP'd IP within seconds of boot, not minutes.

    No-op on non-Windows or when the host has no Yuruna-External
    vEthernet (e.g., Default-Switch fallback path). Only handles /24
    subnets — the common home/office LAN size; wider subnets fall back
    to KVP-only discovery.

.OUTPUTS
    [void]
#>
function Invoke-YurunaExternalArpProbe {
    [CmdletBinding()]
    param([string]$SwitchName = 'Yuruna-External')

    if (-not $IsWindows) { return }

    $hostIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -like "*$SwitchName*" } |
        Select-Object -First 1
    if (-not $hostIp) { return }
    if ($hostIp.PrefixLength -ne 24) {
        # Sweeping a /16 (65k hosts) or larger is impractical in this
        # loop. Most home/office LANs are /24; if the host is on a
        # different prefix the operator can fall back to KVP-only
        # discovery (slower but works once hv_kvp_daemon is up).
        Write-Verbose "Invoke-YurunaExternalArpProbe: host /$($hostIp.PrefixLength) — skipping sweep (only /24 supported)."
        return
    }

    $ipBytes = ([System.Net.IPAddress]::Parse($hostIp.IPAddress)).GetAddressBytes()
    $base    = "$($ipBytes[0]).$($ipBytes[1]).$($ipBytes[2])"
    $hostLast = [int]$ipBytes[3]

    # Parallel sweep: 254 hosts at ThrottleLimit=64 with a 1s ICMP
    # timeout completes in ~5s on a healthy LAN. Skip the host's own
    # last octet (no value pinging ourselves) and .0/.255 (network +
    # broadcast). Pipe to Out-Null so any timing/error noise doesn't
    # reach the caller's progress display.
    1..254 |
        Where-Object { $_ -ne $hostLast } |
        ForEach-Object -ThrottleLimit 64 -Parallel {
            $null = Test-Connection -ComputerName "$using:base.$_" -Count 1 -TimeoutSeconds 1 -Quiet -ErrorAction SilentlyContinue
        } | Out-Null
}

function Test-CacheVmOnYurunaExternalSwitch {
    <#
    .SYNOPSIS
        $true if the squid-cache VM is attached to the Yuruna-External
        vSwitch (LAN-bridged, has a real LAN IP, no host forwarders needed).
    .DESCRIPTION
        Used by the cross-platform test/ scripts to decide whether
        Add-CachingProxyPortMap is needed on Windows. When the cache VM
        is bridged to LAN, remote clients reach it directly at its own
        LAN IP and squid sees real client IPs natively — netsh portproxy
        adds nothing useful and would only register a redundant alternate
        path that loses source IP through kernel NAT. When the cache VM
        is on Default Switch (the fallback when no External vSwitch can
        be created), netsh portproxy is the LAN-reachability mechanism
        and must run.
    .OUTPUTS
        [bool] — $false on non-Windows, missing VM, no NIC, or any other switch.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VMName = 'squid-cache')

    if (-not $IsWindows) { return $false }
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { return $false }
    $switchName = ($vm | Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
        Select-Object -First 1).SwitchName
    return ($switchName -eq 'Yuruna-External')
}

function Get-WorkingCachingProxyUrl {
    <#
    .SYNOPSIS
        "http://<ip>:3128" of a squid-cache VM that answers on :3128,
        or $null if none of the candidate IPs respond.
    .DESCRIPTION
        One-shot helper for consumers (ubuntu guests) and
        Start-CachingProxy.ps1's summary. Does NOT wait for the cache VM
        to boot or for squid to come up — callers expect the VM already
        running and squid listening. The producer
        (guest.squid-cache/New-VM.ps1) uses Get-CacheVmCandidateIp
        directly because it provisions the cache and must poll while
        cloud-init runs.
    .OUTPUTS
        System.String or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [string]$VMName = "squid-cache",
        [int]$ProbeTimeoutMs = 500
    )

    $cacheVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $cacheVM -or $cacheVM.State -ne 'Running') { return $null }

    foreach ($ip in (Get-CacheVmCandidateIp -VM $cacheVM)) {
        if (Test-CachingProxyPort -IpAddress $ip -TimeoutMs $ProbeTimeoutMs) {
            return "http://${ip}:3128"
        }
    }
    return $null
}

<#
.SYNOPSIS
    Returns the host's IPv4 on the Hyper-V Default Switch — the IP a guest
    on Default Switch can reach the host at.

.DESCRIPTION
    Default Switch is a NAT-mode internal vSwitch; the host gets an
    auto-assigned IPv4 on the matching vEthernet adapter, and that IP is
    what guests reach the host at (e.g. for the yuruna status server).

    Caveat: Default Switch's host-side IP CHANGES across host reboots
    (Microsoft regenerates it from a 172.x.x.x pool). A VM provisioned
    today and reused tomorrow may end up with a stale IP baked into
    /etc/yuruna/host.env. Run Test-YurunaHost.ps1 inside the guest to
    detect; the documented remediation is to rebuild the guest VM.

    Bridged networking (External Switch) would route guests via the
    host's LAN IP instead — this helper currently does not detect that
    mode.

.OUTPUTS
    [string] IPv4 address, or $null if Default Switch isn't configured.
#>
function Get-GuestReachableHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $hostAdapter = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -like '*Default Switch*' } | Select-Object -First 1
    if ($hostAdapter) { return $hostAdapter.IPAddress }
    return $null
}

<#
.SYNOPSIS
    Returns $true when $BaseImageFile already matches what we'd
    download from $SourceUrl, so the caller can skip the transfer.

.DESCRIPTION
    Three conditions, all required:
      1. $BaseImageFile exists on disk.
      2. $OriginFile (the sentinel a previous successful run wrote
         next to $BaseImageFile) records the same $SourceUrl on its
         second line AND a positive byte count on its third line.
      3. A fresh HEAD probe of $SourceUrl returns a Content-Length
         that exactly equals the recorded byte count.

    Sentinels missing the third line (older script versions that
    only wrote name + URL) fall through to $false so the caller
    re-downloads — graceful upgrade with no "force" flag needed.

    HEAD failure (offline, 4xx, no Content-Length, mirror redirect
    that strips the header, etc.) returns $false too, so the caller
    falls through to the regular download path rather than skipping
    silently on a transient error.

    Forcing a re-download is intentionally not a parameter here:
    the operator deletes or renames $BaseImageFile (or $OriginFile),
    which makes condition #1 or #2 fail. Keeping it filesystem-only
    means there is exactly one way to override and it survives a
    crashed/aborted prior run with no extra cleanup.

.PARAMETER SourceUrl
    URL the caller has resolved as the download target.

.PARAMETER BaseImageFile
    Final on-disk path of the image (e.g. *.iso, *.vhdx, *.raw).

.PARAMETER OriginFile
    Sentinel path — typically "$baseImageName.txt" next to
    $BaseImageFile. Lines: [0] original filename, [1] source URL,
    [2] byte count of the downloaded source.

.OUTPUTS
    [bool]
#>
function Test-DownloadAlreadyCurrent {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$SourceUrl,
        [Parameter(Mandatory)][string]$BaseImageFile,
        [Parameter(Mandatory)][string]$OriginFile
    )
    if (-not (Test-Path -LiteralPath $BaseImageFile)) { return $false }
    if (-not (Test-Path -LiteralPath $OriginFile))    { return $false }

    $lines = @(Get-Content -LiteralPath $OriginFile -ErrorAction SilentlyContinue)
    if ($lines.Count -lt 3) { return $false }
    if ($lines[1].Trim() -ne $SourceUrl) { return $false }
    $previousSize = 0L
    if (-not [int64]::TryParse($lines[2].Trim(), [ref]$previousSize)) { return $false }
    if ($previousSize -le 0) { return $false }

    try {
        $head = Invoke-WebRequest -Uri $SourceUrl -Method Head -ErrorAction Stop
    } catch {
        Write-Verbose "HEAD probe of $SourceUrl failed: $($_.Exception.Message)"
        return $false
    }
    $cl = $head.Headers['Content-Length']
    if ($cl -is [System.Array]) { $cl = $cl[0] }
    $expectedSize = 0L
    if (-not [int64]::TryParse([string]$cl, [ref]$expectedSize)) { return $false }
    return ($expectedSize -eq $previousSize)
}

<#
.SYNOPSIS
    Returns the IP of a reachable squid-cache VM (probed on :3128),
    or $null when no cache is currently usable.

.DESCRIPTION
    Caller-facing primitive shared by Get-CacheProxyForHostDownload
    and Save-CachedHttpUri so the platform-specific discovery logic
    lives in exactly one place. Wraps Get-CacheVmCandidateIp +
    Test-CachingProxyPort: we need the IP itself (not the proxy URL)
    so callers can also reach :80 (CA fetch) and :3129 (SSL-bump).
.OUTPUTS
    [string] IPv4 like '172.17.96.42', or $null.
#>
function Resolve-CacheHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$VMName = 'squid-cache')
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm -or $vm.State -ne 'Running') { return $null }
    foreach ($ip in (Get-CacheVmCandidateIp -VM $vm)) {
        if (Test-CachingProxyPort -IpAddress $ip -Port 3128 -TimeoutMs 500) {
            return $ip
        }
    }
    return $null
}

<#
.SYNOPSIS
    Resolves the right squid endpoint for $Uri: HTTP through :3128 or
    SSL-bumped HTTPS through :3129 with a freshly-fetched yuruna CA,
    or $null when going direct is the only viable option.

.DESCRIPTION
    Output is a hashtable consumed by Save-CachedHttpUri:

        @{ Proxy = 'http://<ip>:3128'; CaPemPath = $null }
            HTTP origin: route through squid; no extra trust needed.

        @{ Proxy = 'http://<ip>:3129'; CaPemPath = '<temp>.pem' }
            HTTPS origin AND :3129 + :80 reachable AND
            http://<ip>/yuruna-squid-ca.crt fetched OK. Caller passes
            the PEM path to Invoke-HttpsViaSquidBump's per-process
            HttpClient handler — system root store stays untouched.

        $null
            Cache not running, ports unreachable, or CA fetch failed.
            Caller goes direct (still safer than forcing a dead proxy).

    The CA is regenerated on every cache VM rebuild
    (`openssl req -x509 ... CN=yuruna-squid-cache <hostname> <utc>` in
    user-data runcmd), so we always re-fetch — no stable thumbprint to
    pin out-of-band. Trust is bootstrapped over plain HTTP from the
    cache itself, which is the same trust assumption the rest of the
    yuruna LAN-side workflow makes.
.PARAMETER Uri
    The download URL the caller is about to fetch.
.OUTPUTS
    [hashtable] or $null.
#>
function Get-CacheProxyForHostDownload {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Uri)

    $scheme = ([System.Uri]$Uri).Scheme.ToLowerInvariant()
    if ($scheme -ne 'http' -and $scheme -ne 'https') {
        Write-Verbose "Get-CacheProxyForHostDownload: scheme '$scheme' not http(s); going direct."
        return $null
    }

    $cacheIp = Resolve-CacheHostIp
    if (-not $cacheIp) {
        Write-Verbose "Get-CacheProxyForHostDownload: no squid cache reachable on :3128; going direct."
        return $null
    }

    if ($scheme -eq 'http') {
        return @{ Proxy = "http://${cacheIp}:3128"; CaPemPath = $null }
    }

    # HTTPS via SSL-bump on :3129 — needs the apache CA endpoint on :80
    # AND the SSL-bump listener on :3129. Probe both before committing.
    if (-not (Test-CachingProxyPort -IpAddress $cacheIp -Port 3129 -TimeoutMs 500)) {
        Write-Verbose "Get-CacheProxyForHostDownload: squid :3129 not reachable on $cacheIp; HTTPS goes direct."
        return $null
    }
    if (-not (Test-CachingProxyPort -IpAddress $cacheIp -Port 80 -TimeoutMs 500)) {
        Write-Verbose "Get-CacheProxyForHostDownload: apache :80 not reachable on $cacheIp (cannot fetch CA); HTTPS goes direct."
        return $null
    }
    $caUrl = "http://${cacheIp}/yuruna-squid-ca.crt"
    $caPem = Join-Path ([System.IO.Path]::GetTempPath()) 'yuruna-squid-ca.pem'
    try {
        Invoke-WebRequest -Uri $caUrl -OutFile $caPem -ErrorAction Stop -UseBasicParsing | Out-Null
    } catch {
        Write-Verbose "Get-CacheProxyForHostDownload: CA fetch from $caUrl failed: $($_.Exception.Message); HTTPS goes direct."
        return $null
    }
    return @{ Proxy = "http://${cacheIp}:3129"; CaPemPath = $caPem }
}

<#
.SYNOPSIS
    Downloads $Uri to $OutFile, transparently routing through the
    squid cache (HTTP via :3128 or SSL-bumped HTTPS via :3129) when
    one is reachable. Throws on failure.

.DESCRIPTION
    Single entry point used by every host-side Get-Image.ps1 in
    place of Invoke-WebRequest -OutFile. Three paths:

      1. No cache reachable, or unsupported scheme → falls through to
         Invoke-WebRequest direct. Same behavior the scripts had
         before any squid wiring existed.

      2. HTTP origin + cache reachable → Invoke-WebRequest with
         -Proxy http://<cache>:3128. Standard CONNECT-less HTTP
         proxying; squid caches per the snapshot-cache config.

      3. HTTPS origin + cache reachable + SSL-bump usable → custom
         HttpClient with proxy http://<cache>:3129 and a per-call
         ServerCertificateCustomValidationCallback that trusts ONLY
         the freshly-fetched yuruna CA on top of the system roots.
         The OS trust store is never modified; the trust closes when
         this PowerShell process exits.

    Throwing model: any underlying exception (TLS failure, HTTP non-
    2xx, write error, etc.) propagates to the caller's try/catch,
    same as Invoke-WebRequest -ErrorAction Stop.
.PARAMETER Uri
    Source URL.
.PARAMETER OutFile
    Destination file path; overwritten if it exists.
#>
function Save-CachedHttpUri {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    $cfg = Get-CacheProxyForHostDownload -Uri $Uri
    if (-not $cfg) {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -ErrorAction Stop
        return
    }
    if (-not $cfg.CaPemPath) {
        Write-Output "Routing download through squid cache: $($cfg.Proxy)"
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -Proxy $cfg.Proxy -ErrorAction Stop
        return
    }
    Write-Output "Routing HTTPS download through squid SSL-bump: $($cfg.Proxy) (per-process trust of yuruna CA at $($cfg.CaPemPath))"
    Invoke-HttpsViaSquidBump -Uri $Uri -OutFile $OutFile -ProxyUrl $cfg.Proxy -CaPemPath $cfg.CaPemPath
}

<#
.SYNOPSIS
    Internal: HTTPS GET through a squid SSL-bump listener with a
    per-process custom CA trust. Invoke via Save-CachedHttpUri.

.DESCRIPTION
    Why HttpClient and not Invoke-WebRequest:

    PowerShell 7's Invoke-WebRequest exposes -SkipCertificateCheck
    (accept ANY cert — too loose) and accepts no custom server-cert
    callback. Modern .NET HttpClient with HttpClientHandler does
    expose ServerCertificateCustomValidationCallback, which lets us
    accept yuruna-CA-signed leaves WITHOUT touching the OS trust
    store and WITHOUT skipping name validation.

    Validation policy: defer to the OS for everything except a chain
    error. On a chain error (the expected case for squid SSL-bumped
    leaves, since yuruna CA isn't a public root), rebuild the chain
    with the yuruna CA in ExtraStore and AllowUnknownCertificateAuthority,
    then require the chain to terminate at a root whose thumbprint
    matches our CA. Name mismatches and missing-cert errors still
    fail closed.

    Progress: Write-Progress every 2s with bytes/MB and percent when
    Content-Length is known; honors $ProgressPreference (the test
    runner sets it to SilentlyContinue, so the runner's HTML log
    stays clean).
#>
function Invoke-HttpsViaSquidBump {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][string]$ProxyUrl,
        [Parameter(Mandatory)][string]$CaPemPath
    )
    # X509Certificate2::CreateFromPemFile expects cert+key in the same
    # file; the yuruna-squid-ca.crt published by the cache is cert-only.
    # The ctor auto-detects PEM/DER/PFX and works for cert-only PEM.
    $extraCa = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CaPemPath)
    $expectedThumb = $extraCa.Thumbprint

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $true
    $handler.Proxy = [System.Net.WebProxy]::new([System.Uri]$ProxyUrl, $true)
    $handler.ServerCertificateCustomValidationCallback = {
        param($req, $cert, $chain, $errors)
        if (($errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNotAvailable) -ne 0) { return $false }
        if (($errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch) -ne 0) { return $false }
        if (($errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors) -eq 0) { return $true }
        $extraChain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
        [void]$extraChain.ChainPolicy.ExtraStore.Add($extraCa)
        $extraChain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $extraChain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
        if (-not $extraChain.Build($cert)) { return $false }
        $root = $extraChain.ChainElements[$extraChain.ChainElements.Count - 1].Certificate
        return ($root.Thumbprint -eq $expectedThumb)
    }.GetNewClosure()

    $client = [System.Net.Http.HttpClient]::new($handler, $true)
    # 4 GB at ~50 MB/s LAN cache = ~80s; HTTP/SSL handshake + cold cache
    # populate from origin can stretch this. Generous timeout vs. the
    # default 100s which would abort mid-fetch on a cold ISO pull.
    $client.Timeout = [TimeSpan]::FromHours(2)
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, [System.Uri]$Uri)
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) {
                throw "HTTP $([int]$response.StatusCode) $($response.ReasonPhrase) for $Uri"
            }
            $total = $response.Content.Headers.ContentLength
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            try {
                $out = [System.IO.File]::Create($OutFile)
                try {
                    $buf = [byte[]]::new(64 * 1024)
                    $written = 0L
                    $next = [DateTime]::UtcNow.AddSeconds(2)
                    $activity = "Downloading $Uri (via squid SSL-bump)"
                    while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                        $out.Write($buf, 0, $n)
                        $written += $n
                        if ([DateTime]::UtcNow -gt $next) {
                            if ($total) {
                                $pct = [math]::Round($written * 100.0 / $total, 1)
                                Write-Progress -Activity $activity -Status ("{0:N1} / {1:N1} MB ({2}%)" -f ($written/1MB), ($total/1MB), $pct) -PercentComplete $pct
                            } else {
                                Write-Progress -Activity $activity -Status ("{0:N1} MB" -f ($written/1MB))
                            }
                            $next = [DateTime]::UtcNow.AddSeconds(2)
                        }
                    }
                } finally { $out.Dispose() }
            } finally { $stream.Dispose() }
            Write-Progress -Activity $activity -Completed
        } finally { $response.Dispose() }
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Assert-HyperVEnabled {
    <#
    .SYNOPSIS
        Returns $true when Hyper-V is enabled AND vmms is running; $false
        with a diagnostic Write-Output otherwise.

    .DESCRIPTION
        Verifies the Hyper-V preconditions every New-VM and tear-down
        script depends on. Bypasses Get-WindowsOptionalFeature: that
        cmdlet dispatches through a COM shim (CompatiblePSEdition proxy
        in pwsh 7) that, on fresh Windows 11 installs or right after
        Enable-WindowsOptionalFeature completes, can fail with "Class
        not registered" (HRESULT 0x80040154) even when Hyper-V is
        enabled and healthy. Seen on the first post-install run of
        Start-SquidCache → guest.squid-cache/New-VM.ps1. dism.exe is
        the plain Win32 tool the cmdlet wraps; calling it directly
        sidesteps the COM failure (same workaround as
        install/windows-install.ps1).

        Home editions: if Microsoft-Hyper-V-All isn't on the SKU at all,
        dism.exe emits 0x800f080c / "Feature name ... is unknown". We
        surface that as a distinct message so the operator knows the
        issue is the edition, not transient state.

    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $dismExe = Join-Path $env:WINDIR 'System32\dism.exe'
    if (-not (Test-Path $dismExe)) {
        Write-Output "dism.exe not found at $dismExe. Cannot verify Hyper-V state."
        return $false
    }
    $infoOut = & $dismExe /English /Online /Get-FeatureInfo /FeatureName:Microsoft-Hyper-V-All 2>&1
    $infoExit = $LASTEXITCODE
    if ($infoExit -ne 0) {
        if ($infoOut -match '0x800f080c' -or $infoOut -match 'Feature name .* is unknown') {
            Write-Output 'Microsoft-Hyper-V-All feature not available on this SKU (Home edition?). Hyper-V VMs cannot run here.'
        } else {
            Write-Output "dism.exe /Get-FeatureInfo exited $infoExit."
            Write-Output ($infoOut -join [Environment]::NewLine)
        }
        return $false
    }

    $state = 'Unknown'
    foreach ($line in $infoOut) {
        if ($line -match '^State\s*:\s*(\S+)') { $state = $Matches[1]; break }
    }
    if ($state -ne 'Enabled') {
        Write-Output "Hyper-V is not enabled (state: $state). Run install\windows-install.ps1 and reboot, then retry."
        return $false
    }

    $service = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Output "Hyper-V Virtual Machine Management service (vmms) not found. Hyper-V likely needs a reboot after enabling."
        return $false
    }
    if ($service.Status -ne 'Running') {
        Write-Output "Hyper-V Virtual Machine Management service (vmms) is not running (status: $($service.Status)). Try: Start-Service vmms"
        return $false
    }

    return $true
}
