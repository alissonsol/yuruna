<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e90
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host windows hyperv
.LICENSEURI https://yuruna.com
.PROJECTURI https://yuruna.com
.RELEASENOTES
    Yuruna host driver for Windows + Hyper-V. Implements the contract
    documented in host/ubuntu.kvm/modules/Yuruna.Host.psm1.
#>

#requires -version 7

<#
.SYNOPSIS
    Yuruna host driver for Windows + Hyper-V.

.DESCRIPTION
    Self-contained host driver: contract surface plus the Hyper-V /
    Windows helpers (formerly host/windows.hyper-v/modules/Yuruna.Host.psm1)
    it consumes. Cross-host helpers still live in
    test/modules/Test.VM.common.psm1 and Test.Ssh.psm1, imported below.

    Module-qualified calls (e.g. `Test.HostProxy\Set-HostProxy`) appear
    where an external helper shares its name with the contract function
    -- without the qualifier the call would re-enter our own definition
    and recurse.
#>

# === Module setup ===========================================================

$script:HostTag        = 'host.windows.hyper-v'
$script:RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:TestModulesDir = Join-Path $script:RepoRoot 'test\modules'
$script:HostFolder     = Join-Path $script:RepoRoot 'host\windows.hyper-v'

# Import the legacy test/modules + host/<x>/modules/Yuruna.Host.psm1 into
# THIS module's scope (no -Global). Their functions become callable from
# our function bodies; Export-ModuleMember below decides which of OUR
# functions become visible to test/ orchestration. Yuruna.Host.psm1's
# exports shadow any same-name exports the legacy modules also produce.
Import-Module (Join-Path $script:TestModulesDir 'Test.VM.common.psm1')    -Force -DisableNameChecking
Import-Module (Join-Path $script:TestModulesDir 'Test.Ssh.psm1')          -Force -DisableNameChecking
Import-Module (Join-Path $script:TestModulesDir 'Test.CachingProxy.psm1') -Force -DisableNameChecking
# === Helpers lifted from former Yuruna.Host.psm1 (host/windows.hyper-v) ======

# --- Define Oscdimg Path (adjust '10' for your ADK version if necessary) ---
$OscdimgPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\Oscdimg.exe"

<#
.SYNOPSIS
Build an ISO image from a directory tree using Oscdimg.exe.

.DESCRIPTION
Wraps the Windows ADK Oscdimg utility to package $SourceDir into a
single-track ISO at $OutputFile with the supplied volume id (default
"cidata", used for cloud-init NoCloud seed disks). Resolves relative
paths against the current location, creates the output directory if
needed, and throws if Oscdimg.exe is missing.
#>
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

    Write-Verbose "Creating ISO `nfrom '$SourceDir' `nto '$OutputFile' `nwith Volume ID '$VolumeId'..."
    # Capture oscdimg's chatty banner+progress so it's silent at logLevel
    # Information; replay each line via Write-Verbose so logLevel Verbose
    # still gets the full transcript.
    $oscOutput = & $OscdimgPath "$SourceDir" "$OutputFile" -n -h -m -l"$VolumeId" 2>&1
    foreach ($line in $oscOutput) {
        $text = "$line".TrimEnd()
        if ($text) { Write-Verbose $text }
    }

    Write-Verbose "ISO created successfully at: $OutputFile"
}

# --- squid-cache IP discovery (shared by producer + consumers) --------------
# Prior state copy-pasted the KVP+ARP dual strategy across squid-cache
# and ubuntu.server New-VM.ps1s plus a KVP-only variant in
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

    # KVP can emit both IPv4 and IPv6. Net-routable v4 stays first since
    # downstream port-forwarders here are netsh portproxy v4tov4; v6
    # entries are kept too so callers that handle v6 (SSH, generic TCP)
    # still see them. Loopback/link-local on either family is excluded.
    $kvpIps = @($VM | Get-VMNetworkAdapter |
        ForEach-Object { $_.IPAddresses } |
        Where-Object { Test-IpAddress $_ } |
        Where-Object { $_ -notmatch '^(127\.|169\.254\.)' -and $_ -inotmatch '^(::1$|fe80:)' })

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
                (Test-Ipv4Address $_.IPAddress) -and
                $_.State -ne 'Unreachable'
            } | ForEach-Object { $_.IPAddress })
    }

    # --- See https://yuruna.link/memory#why-get-cachevmcandidateip-emits-a-bare-pipeline
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

    # IMPORTANT: this function's only pipeline output is a single string
    # (switch name) or $null. All diagnostics MUST go through
    # Write-Information / Write-Warning / Write-Error so callers can
    # safely assign with `$x = Get-OrCreateYurunaExternalSwitch`. A
    # stray Write-Output here turned $x into a string[] and broke
    # downstream `-SwitchName` parameter binding (System.Object[] ->
    # System.String coercion failure).

    # 1. Preferred name (default 'Yuruna-External'): use as-is if External.
    $existing = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.SwitchType -ne 'External') {
            Write-Warning "Switch '$SwitchName' exists but is type '$($existing.SwitchType)', not External. Cache VM may not be LAN-reachable."
        }
        return $SwitchName
    }

    # 2. ANY existing External-type vSwitch: reuse it instead of
    # creating a redundant second External on the same NIC. Hyper-V
    # only allows one External vSwitch per physical adapter, so a
    # blind New-VMSwitch on top of an existing one tears down the
    # original (network blip + every existing VM on the old switch
    # gets disconnected). On hosts where the operator pre-created an
    # External vSwitch under a different name (e.g., 'External',
    # 'LAN-Bridge'), we honor that and return its name.
    $anyExternal = Get-VMSwitch -ErrorAction SilentlyContinue |
        Where-Object { $_.SwitchType -eq 'External' } |
        Select-Object -First 1
    if ($anyExternal) {
        Write-Information "Using existing External vSwitch '$($anyExternal.Name)' (preferred name '$SwitchName' not present)."
        return $anyExternal.Name
    }

    # 3. No External vSwitch exists -- create one bridged on the NIC
    # carrying the default IPv4 route. Filter routes that are
    # themselves through a vEthernet (Default Switch / Hyper-V internal
    # switches) to avoid feedback if a prior bad bridge state left a
    # vEthernet as default.
    $defaultRoute = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' -and $_.NextHop -ne '::' } |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1
    if (-not $defaultRoute) {
        Write-Warning "No IPv4 default route on the host. Cannot create External vSwitch -- connect a NIC to the LAN first."
        return $null
    }

    $nic = Get-NetAdapter -InterfaceIndex $defaultRoute.InterfaceIndex -ErrorAction SilentlyContinue
    if (-not $nic) {
        Write-Warning "Cannot resolve adapter for default-route InterfaceIndex $($defaultRoute.InterfaceIndex)."
        return $null
    }

    if ($nic.Status -ne 'Up') {
        Write-Warning "Adapter '$($nic.InterfaceAlias)' is in state '$($nic.Status)', not Up. Cannot bridge."
        return $null
    }

    if ($nic.PhysicalMediaType -eq 'Native 802.11') {
        Write-Warning "Default-route adapter '$($nic.InterfaceAlias)' is Wi-Fi. Hyper-V External vSwitch on Wi-Fi: most APs refuse to forward frames for MACs they didn't authenticate, so the cache VM's DHCP request may go unanswered and remote LAN clients may not reach it. If LAN reachability fails, run on a wired connection."
    }

    if (-not $PSCmdlet.ShouldProcess($SwitchName, "Create External vSwitch bridged on '$($nic.InterfaceAlias)' with -AllowManagementOS")) {
        return $null
    }

    Write-Information "Creating External vSwitch '$SwitchName' bridged on '$($nic.InterfaceAlias)'... (host networking will briefly drop on this NIC during the bind; open SSH/RDP sessions through it will reconnect.)"
    try {
        New-VMSwitch -Name $SwitchName -NetAdapterName $nic.InterfaceAlias -AllowManagementOS:$true -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "New-VMSwitch failed: $($_.Exception.Message)"
        return $null
    }

    Write-Information "External vSwitch '$SwitchName' ready."
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
        [int]$Port = $(Get-CachingProxyPort -Scheme http),
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
        $true if the squid-cache VM is attached to ANY External-type
        vSwitch (LAN-bridged, has a real LAN IP, no host forwarders needed).
    .DESCRIPTION
        Used by the cross-platform test/ scripts to decide whether
        Add-CachingProxyPortMap is needed on Windows. When the cache VM
        is bridged to LAN, remote clients reach it directly at its own
        LAN IP and squid sees real client IPs natively -- netsh portproxy
        adds nothing useful and would only register a redundant alternate
        path that loses source IP through kernel NAT. When the cache VM
        is on Default Switch (or any internal/private switch), netsh
        portproxy is the LAN-reachability mechanism and must run.

        Function name retains the historical 'Yuruna' reference for
        call-site stability, but the check is by SwitchType=External --
        operators who pre-create an External vSwitch under a different
        name (e.g., 'External', 'LAN-Bridge') get the same fast path.
    .OUTPUTS
        [bool] -- $false on non-Windows, missing VM, no NIC, or non-External switch.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VMName = 'yuruna-caching-proxy')

    if (-not $IsWindows) { return $false }
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { return $false }
    $switchName = ($vm | Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
        Select-Object -First 1).SwitchName
    if (-not $switchName) { return $false }
    $switch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
    return ($switch -and $switch.SwitchType -eq 'External')
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
        [string]$VMName = "yuruna-caching-proxy",
        [int]$ProbeTimeoutMs = 500
    )

    $cacheVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $cacheVM -or $cacheVM.State -ne 'Running') { return $null }

    $httpPort = Get-CachingProxyPort -Scheme http
    foreach ($ip in (Get-CacheVmCandidateIp -VM $cacheVM)) {
        if (Test-CachingProxyPort -IpAddress $ip -Port $httpPort -TimeoutMs $ProbeTimeoutMs) {
            return "http://$(Format-IpUrlHost $ip):${httpPort}"
        }
    }
    return $null
}

<#
.SYNOPSIS
    Returns the host's IPv4 reachable from a guest VM, picked by the
    guest's vSwitch attachment.

.DESCRIPTION
    Two distinct topologies need two distinct answers:

    * Default Switch (NAT-mode internal): the host has an auto-assigned
      IPv4 on `vEthernet (Default Switch)` (e.g. 172.26.176.1). That's
      the gateway the guest reaches the host at. Caveat: the IP CHANGES
      across host reboots (Microsoft regenerates it from a 172.x.x.x
      pool). A VM provisioned today and reused tomorrow may end up with
      a stale IP baked into /etc/yuruna/host.env -- run
      Test-YurunaHost.ps1 inside the guest to detect; remediation is to
      rebuild the guest VM.

    * External vSwitch (LAN-bridged): the guest gets a real LAN IP via
      DHCP from the LAN router, so `vEthernet (Default Switch)`'s
      172.x.x.x is unreachable from the guest -- it sees the host only
      at the host's LAN IP (e.g. 192.168.7.13). Returning the Default
      Switch IP for an External-attached guest is the bug behind the
      "guest hammers 172.26.176.1:8080" symptom.

    Pass -SwitchName to opt into the right answer. With no parameter,
    legacy callers continue to receive the Default Switch IP for
    backward compatibility.

.PARAMETER SwitchName
    Hyper-V vSwitch name the guest will be attached to. 'Default Switch'
    returns the Default-Switch host IP; any other name is looked up via
    Get-VMSwitch and the host's default-route IPv4 is returned for
    External-type switches. Falls back to Default-Switch behavior for
    unknown switches so a typo can't strand a guest with $null.

.OUTPUTS
    [string] IPv4 address, or $null if no candidate adapter is found.
#>
function Get-GuestReachableHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$SwitchName
    )

    # Helper: host's LAN IPv4 (the IP on the NIC carrying the default
    # IPv4 route). When -AllowManagementOS is enabled on an External
    # vSwitch, that IP rides on `vEthernet (<switchName>)`; without it,
    # it stays on the underlying physical NIC. Either way, default-route
    # adapter is the one a guest on the same LAN reaches the host at.
    $getLanIp = {
        $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -ne '0.0.0.0' -and $_.NextHop -ne '::' } |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1
        if (-not $route) { return $null }
        $ip = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
            Select-Object -First 1
        if ($ip) { return [string]$ip.IPAddress }
        return $null
    }

    # Default Switch path (also the legacy no-arg path).
    $isDefault = (-not $SwitchName) -or ($SwitchName -eq 'Default Switch')
    if (-not $isDefault) {
        # Resolve switch type. Unknown switch -> fall back to Default
        # Switch logic so a stale name in a New-VM script doesn't bake
        # an empty value into the seed.iso.
        $switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
        if ($switch -and $switch.SwitchType -eq 'External') {
            $lanIp = & $getLanIp
            if ($lanIp) { return $lanIp }
            # External switch with no usable host IP (rare: host is
            # disconnected from LAN). Fall through to Default-Switch
            # so the guest at least has SOMETHING -- it'll fail probes
            # but won't crash on missing hostname.
        }
    }

    $defaultSwitchIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -like '*Default Switch*' } |
        Select-Object -First 1
    if ($defaultSwitchIp) { return [string]$defaultSwitchIp.IPAddress }
    return $null
}

<#
.SYNOPSIS
    Returns $true when $BaseImageFile already matches what we'd
    download from $SourceUrl, so the caller can skip the transfer.

.DESCRIPTION
    Four conditions, ALL required (any single mismatch forces a
    re-download):
      1. $BaseImageFile exists on disk.
      2. $OriginFile (the sentinel a previous successful run wrote
         next to $BaseImageFile) has at least 4 lines:
           [0] source filename  (matches Path.GetFileName($SourceUrl))
           [1] source URL       (matches $SourceUrl exactly)
           [2] byte count       (positive int64)
           [3] Last-Modified    (HTTP date string, optionally empty
                                 if the upstream doesn't expose it)
      3. A fresh HEAD probe of $SourceUrl returns:
           - Content-Length that exactly equals the recorded byte count.
           - Last-Modified that exactly equals the recorded date
             (when both sentinel and HEAD provide one; if either is
             missing, the date check is skipped — some mirrors strip
             Last-Modified, so we don't punish that).

    Sentinels from older script versions (3 lines, no Last-Modified)
    deliberately fail the line-count gate so the caller re-downloads
    once. After that the new 4-line sentinel is in place and the
    full check applies on every subsequent run. The cost is a single
    re-download per upgrade; the benefit is that the check catches
    cases where the URL/filename was changed in Get-Image.ps1 but a
    previously-cached sentinel was somehow updated to match without
    the corresponding image being re-fetched (the noble→resolute
    bug that motivated this rewrite).

    HEAD failure (offline, 4xx, no Content-Length, mirror redirect
    that strips the header, etc.) returns $false too, so the caller
    falls through to the regular download path rather than skipping
    silently on a transient error.

    Mismatch reasons are surfaced via Write-Verbose so the operator
    can run `Get-Image.ps1 -Verbose` and see WHICH check failed.

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
    [2] byte count of the downloaded source, [3] Last-Modified date.

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
    if (-not (Test-Path -LiteralPath $BaseImageFile)) {
        Write-Verbose "Test-DownloadAlreadyCurrent: base image file missing ($BaseImageFile); will download."
        return $false
    }
    if (-not (Test-Path -LiteralPath $OriginFile)) {
        Write-Verbose "Test-DownloadAlreadyCurrent: sentinel file missing ($OriginFile); will download."
        return $false
    }

    $lines = @(Get-Content -LiteralPath $OriginFile -ErrorAction SilentlyContinue)
    if ($lines.Count -lt 4) {
        Write-Verbose "Test-DownloadAlreadyCurrent: sentinel has only $($lines.Count) line(s); the 4-line format with Last-Modified is required, will re-download to refresh."
        return $false
    }

    $sentinelFilename = $lines[0].Trim()
    $sentinelUrl      = $lines[1].Trim()
    $sentinelSizeRaw  = $lines[2].Trim()
    $sentinelLastMod  = $lines[3].Trim()

    $expectedFilename = [System.IO.Path]::GetFileName(([System.Uri]$SourceUrl).LocalPath)
    if ($sentinelFilename -ne $expectedFilename) {
        Write-Verbose "Test-DownloadAlreadyCurrent: sentinel filename '$sentinelFilename' != URL filename '$expectedFilename'; will download. (This is what catches a noble->resolute style URL change.)"
        return $false
    }
    if ($sentinelUrl -ne $SourceUrl) {
        Write-Verbose "Test-DownloadAlreadyCurrent: sentinel URL '$sentinelUrl' != requested URL '$SourceUrl'; will download."
        return $false
    }
    $previousSize = 0L
    if (-not [int64]::TryParse($sentinelSizeRaw, [ref]$previousSize) -or $previousSize -le 0) {
        Write-Verbose "Test-DownloadAlreadyCurrent: sentinel byte count '$sentinelSizeRaw' is not a positive integer; will download."
        return $false
    }

    try {
        $head = Invoke-WebRequest -Uri $SourceUrl -Method Head -ErrorAction Stop
    } catch {
        Write-Verbose "Test-DownloadAlreadyCurrent: HEAD probe of $SourceUrl failed: $($_.Exception.Message); will download."
        return $false
    }
    $cl = $head.Headers['Content-Length']
    if ($cl -is [System.Array]) { $cl = $cl[0] }
    $expectedSize = 0L
    if (-not [int64]::TryParse([string]$cl, [ref]$expectedSize)) {
        Write-Verbose "Test-DownloadAlreadyCurrent: HEAD response has no usable Content-Length; will download."
        return $false
    }
    if ($expectedSize -ne $previousSize) {
        Write-Verbose "Test-DownloadAlreadyCurrent: size mismatch (sentinel=$previousSize, HEAD=$expectedSize); will download."
        return $false
    }
    # Last-Modified check, lenient when either side lacks the header.
    $headLm = $head.Headers['Last-Modified']
    if ($headLm -is [System.Array]) { $headLm = $headLm[0] }
    $headLastMod = [string]$headLm
    if ($sentinelLastMod -and $headLastMod -and ($sentinelLastMod -ne $headLastMod)) {
        Write-Verbose "Test-DownloadAlreadyCurrent: Last-Modified differs (sentinel='$sentinelLastMod', HEAD='$headLastMod'); will download."
        return $false
    }
    Write-Verbose "Test-DownloadAlreadyCurrent: match (filename='$sentinelFilename', size=$previousSize, last-modified='$sentinelLastMod'); skipping."
    return $true
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
    param([string]$VMName = 'yuruna-caching-proxy')
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm -or $vm.State -ne 'Running') { return $null }
    $httpPort = Get-CachingProxyPort -Scheme http
    foreach ($ip in (Get-CacheVmCandidateIp -VM $vm)) {
        if (Test-CachingProxyPort -IpAddress $ip -Port $httpPort -TimeoutMs 500) {
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

    $httpPort  = Get-CachingProxyPort -Scheme http
    $httpsPort = Get-CachingProxyPort -Scheme https

    $scheme = ([System.Uri]$Uri).Scheme.ToLowerInvariant()
    if ($scheme -ne 'http' -and $scheme -ne 'https') {
        Write-Verbose "Get-CacheProxyForHostDownload: scheme '$scheme' not http(s); going direct."
        return $null
    }

    $cacheIp = Resolve-CacheHostIp
    if (-not $cacheIp) {
        Write-Verbose "Get-CacheProxyForHostDownload: no squid cache reachable on :${httpPort}; going direct."
        return $null
    }

    $cacheHost = Format-IpUrlHost $cacheIp
    if ($scheme -eq 'http') {
        return @{ Proxy = "http://${cacheHost}:${httpPort}"; CaPemPath = $null }
    }

    # HTTPS via SSL-bump on the HTTPS port — needs the apache CA
    # endpoint on :80 AND the SSL-bump listener. Probe both before committing.
    if (-not (Test-CachingProxyPort -IpAddress $cacheIp -Port $httpsPort -TimeoutMs 500)) {
        Write-Verbose "Get-CacheProxyForHostDownload: squid :${httpsPort} not reachable on $cacheIp; HTTPS goes direct."
        return $null
    }
    if (-not (Test-CachingProxyPort -IpAddress $cacheIp -Port 80 -TimeoutMs 500)) {
        Write-Verbose "Get-CacheProxyForHostDownload: apache :80 not reachable on $cacheIp (cannot fetch CA); HTTPS goes direct."
        return $null
    }
    $caUrl = "http://${cacheHost}/yuruna-squid-ca.crt"
    $caPem = Join-Path ([System.IO.Path]::GetTempPath()) 'yuruna-squid-ca.pem'
    try {
        Invoke-WebRequest -Uri $caUrl -OutFile $caPem -ErrorAction Stop -UseBasicParsing | Out-Null
    } catch {
        Write-Verbose "Get-CacheProxyForHostDownload: CA fetch from $caUrl failed: $($_.Exception.Message); HTTPS goes direct."
        return $null
    }
    return @{ Proxy = "http://${cacheHost}:${httpsPort}"; CaPemPath = $caPem }
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
        Write-Information "Routing download through squid cache: $($cfg.Proxy)"
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -Proxy $cfg.Proxy -ErrorAction Stop
        return
    }
    Write-Information "Routing HTTPS download through squid SSL-bump: $($cfg.Proxy) (per-process trust of yuruna CA at $($cfg.CaPemPath))"
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
        # $req (HttpRequestMessage) and $chain (the system-built chain)
        # are part of the delegate signature but unused by our policy --
        # we make our own chain below seeded with the yuruna CA. Touching
        # them as $null = ... silences PSReviewUnusedParameter without
        # changing the delegate's contract.
        $null = $req; $null = $chain
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
        install/windows.hyper-v.ps1).

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
        Write-Information "dism.exe not found at $dismExe. Cannot verify Hyper-V state."
        return $false
    }
    $infoOut = & $dismExe /English /Online /Get-FeatureInfo /FeatureName:Microsoft-Hyper-V-All 2>&1
    $infoExit = $LASTEXITCODE
    if ($infoExit -ne 0) {
        if ($infoOut -match '0x800f080c' -or $infoOut -match 'Feature name .* is unknown') {
            Write-Information 'Microsoft-Hyper-V-All feature not available on this SKU (Home edition?). Hyper-V VMs cannot run here.'
        } else {
            Write-Information "dism.exe /Get-FeatureInfo exited $infoExit."
            Write-Information ($infoOut -join [Environment]::NewLine)
        }
        return $false
    }

    $state = 'Unknown'
    foreach ($line in $infoOut) {
        if ($line -match '^State\s*:\s*(\S+)') { $state = $Matches[1]; break }
    }
    if ($state -ne 'Enabled') {
        Write-Information "Hyper-V is not enabled (state: $state). Run install\windows.hyper-v.ps1 and reboot, then retry."
        return $false
    }

    $service = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Information "Hyper-V Virtual Machine Management service (vmms) not found. Hyper-V likely needs a reboot after enabling."
        return $false
    }
    if ($service.Status -ne 'Running') {
        Write-Information "Hyper-V Virtual Machine Management service (vmms) is not running (status: $($service.Status)). Try: Start-Service vmms"
        return $false
    }

    return $true
}

# === VM lifecycle helpers (migrated from test/modules/Test.New-VM.psm1
#     and test/modules/Test.Start-VM.psm1 during the Yuruna.Host refactor)
#
# These functions remain Hyper-V-internal helpers consumed by
# host/windows.hyper-v/modules/Yuruna.Host.psm1. They are NOT part of
# the test-facing host driver contract; new test code calls the
# contract (Yuruna.Host) which delegates here.

<#
.SYNOPSIS
Verify that a Hyper-V VM with the given name is registered.

.DESCRIPTION
Returns $true and writes a verification line when Hyper-V\Get-VM finds
the VM (in any state); returns $false and writes an error otherwise.
Used by the test harness right after New-VM to fail fast when the VM
did not actually register.
#>
function Confirm-HyperVVMCreated {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm) {
        Write-Information "Verified: Hyper-V VM '$VMName' (State: $($vm.State))"
        return $true
    }
    Write-Error "VM verification failed: Hyper-V VM '$VMName' not found."
    return $false
}

<#
.SYNOPSIS
Force a Hyper-V VM to the 'Off' state, escalating to a vmwp.exe kill if
Stop-VM -TurnOff doesn't take effect.

.DESCRIPTION
Stop-VM -TurnOff can hang indefinitely on a stuck VM (any transient
state where vmms can't complete the transition). Each running VM is
hosted by a `vmwp.exe` worker process whose command line contains the
VM's Id GUID; killing that process deallocates the VM and lets
Remove-VM proceed.

Returns $true when the VM is gone or 'Off'; $false when even the
vmwp.exe kill didn't clear it.
#>
function Stop-HyperVVMForce {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$StopTimeoutSeconds = 20
    )
    $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { return $true }
    if ($vm.State -in @('Off', 'Saved', 'OffCritical')) { return $true }
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Force-stop VM (Stop-VM -TurnOff, then kill vmwp.exe if still not Off)')) {
        return $false
    }

    # First attempt: graceful-ish TurnOff in a background job so a hung
    # vmms can't block us.
    $stopJob = Start-Job -ScriptBlock {
        Hyper-V\Stop-VM -Name $using:VMName -Force -TurnOff -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds($StopTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if (-not $vm -or $vm.State -eq 'Off') {
            Stop-Job   -Job $stopJob -ErrorAction SilentlyContinue
            Remove-Job -Job $stopJob -Force -ErrorAction SilentlyContinue
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    Stop-Job   -Job $stopJob -ErrorAction SilentlyContinue
    Remove-Job -Job $stopJob -Force -ErrorAction SilentlyContinue

    # Escalate: kill the vmwp.exe worker process hosting this VM.
    $vmId = $vm.Id.Guid
    Write-Warning "  Stop-VM did not bring '$VMName' to Off within ${StopTimeoutSeconds}s (state: $($vm.State)). Killing vmwp.exe for VM $vmId..."
    $workers = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ieq 'vmwp.exe' -and $_.CommandLine -and $_.CommandLine -match [regex]::Escape($vmId) }
    if (-not $workers) {
        Write-Warning "  No vmwp.exe worker found for VM $vmId. VM may already be transitioning; will retry Stop-VM."
        $retryJob = Start-Job -ScriptBlock {
            Hyper-V\Stop-VM -Name $using:VMName -Force -TurnOff -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        }
        Wait-Job   -Job $retryJob -Timeout 10 | Out-Null
        Stop-Job   -Job $retryJob -ErrorAction SilentlyContinue
        Remove-Job -Job $retryJob -Force -ErrorAction SilentlyContinue
    } else {
        foreach ($w in $workers) {
            try {
                Stop-Process -Id $w.ProcessId -Force -ErrorAction Stop
                Write-Information "  Killed vmwp.exe PID $($w.ProcessId) for VM '$VMName'."
            } catch {
                Write-Warning "  Stop-Process failed for PID $($w.ProcessId): $_"
            }
        }
    }

    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if (-not $vm -or $vm.State -eq 'Off') { return $true }
        Start-Sleep -Milliseconds 500
    }

    $finalState = (Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue).State
    Write-Warning "  '$VMName' still reports state '$finalState' after vmwp.exe kill."
    return $false
}

<#
.SYNOPSIS
Force-stop and delete a Hyper-V VM along with its disk directory.

.DESCRIPTION
Brings the VM to Off via Stop-HyperVVMForce, calls Remove-VM, and then
removes the per-VM subdirectory under Get-VMHost.VirtualHardDiskPath.
Returns $true only when the VM is no longer registered after Remove-VM
returns; disk-cleanup failures are warned but do not flip the result.
#>
function Remove-HyperVTestVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Remove VM')) { return $false }
    $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue
    $registryRemoved = $true
    if ($vm) {
        $null = Stop-HyperVVMForce -VMName $VMName -Confirm:$false
        try {
            Hyper-V\Remove-VM -Name $VMName -Force -Confirm:$false -ErrorAction Stop 6>$null
            if (Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
                $registryRemoved = $false
                Write-Warning "Remove-VM '$VMName' returned 0 but VM still registered."
            } else {
                Write-Information "Removed Hyper-V VM: $VMName"
            }
        } catch {
            $registryRemoved = $false
            Write-Warning "Remove-VM '$VMName' failed: $_"
        }
    }
    $vhdPath = (Hyper-V\Get-VMHost -ErrorAction SilentlyContinue).VirtualHardDiskPath
    if ($vhdPath) {
        $vmDir = Join-Path $vhdPath $VMName
        if (Test-Path $vmDir) {
            try {
                Remove-Item -Recurse -Force $vmDir -ErrorAction Stop 6>$null
                Write-Verbose "Removed VM disk directory: $vmDir"
            } catch {
                Write-Warning "Remove-Item '$vmDir' failed: $_"
            }
        }
    }
    return $registryRemoved
}

<#
.SYNOPSIS
Start a Hyper-V VM and open a vmconnect window in basic mode.

.DESCRIPTION
Calls Hyper-V\Start-VM, then launches vmconnect.exe against
localhost\$VMName so screenshots and keystroke delivery work without
guest integration tools. After spawn it dismisses the "Another user is
connected" dialog if vmconnect raises it. Returns a hashtable
@{ success; errorMessage } so callers can branch on transport
failures separately from PowerShell exceptions.
#>
function Start-HyperVVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$VMName)
    try {
        if ($PSCmdlet.ShouldProcess($VMName, 'Start Hyper-V VM')) {
            Hyper-V\Start-VM -Name $VMName -ErrorAction Stop -WarningAction SilentlyContinue 6>$null
            # Open a vmconnect window in basic mode for screenshots / keystroke
            # delivery without requiring guest integration tools.
            $vmconnect = "$env:SystemRoot\System32\vmconnect.exe"
            if (Test-Path $vmconnect) {
                Start-Process -FilePath $vmconnect -ArgumentList "localhost", $VMName
                Start-Sleep -Seconds 2
                [void](Resolve-VMConnectAnotherUserDialog -VMName $VMName -TimeoutSeconds 8)
            }
        }
        return @{ success = $true; errorMessage = $null }
    } catch {
        return @{ success = $false; errorMessage = "Start-VM failed for '$VMName': $_" }
    }
}

<#
.SYNOPSIS
Stop a Hyper-V VM and close any matching vmconnect window.

.DESCRIPTION
Delegates the Off transition to Stop-HyperVVMForce (with a 20-second
timeout and vmwp.exe escalation), then kills any vmconnect process
whose window title references this VM so the desktop doesn't accumulate
stale viewer windows. Returns whether the VM actually reached Off.
#>
function Stop-HyperVVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Stop Hyper-V VM')) { return $true }
    $stopped = $false
    try {
        $stopped = [bool](Stop-HyperVVMForce -VMName $VMName -StopTimeoutSeconds 20 -Confirm:$false)
    } catch {
        Write-Warning "Stop-HyperVVMForce threw for '$VMName': $_"
        $stopped = $false
    }
    Get-Process -Name "vmconnect" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -match [regex]::Escape($VMName) } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    if ($stopped) {
        Write-Information "Stopped Hyper-V VM: $VMName"
    } else {
        Write-Warning "Failed to stop Hyper-V VM '$VMName'; Remove-VM may take over."
    }
    return $stopped
}

<#
.SYNOPSIS
Wait for a Hyper-V VM to reach the Running state.

.DESCRIPTION
Polls Hyper-V\Get-VM every 5 seconds for up to $TimeoutSeconds
(default 120) and returns $true when State is Running. On timeout it
writes an error and returns $false so the caller can decide whether
to retry, stop the VM, or treat this as a fatal harness failure.
#>
function Confirm-HyperVVMStarted {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName, [int]$TimeoutSeconds = 120)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if ($vm -and $vm.State -eq 'Running') {
            Write-Information "Verified: Hyper-V VM '$VMName' is running (State: $($vm.State))"
            return $true
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    Write-Error "Hyper-V VM '$VMName' did not reach Running state within ${TimeoutSeconds}s"
    return $false
}

<#
.SYNOPSIS
    Auto-dismiss vmconnect's "Another user is connected" prompt.
.DESCRIPTION
    Polls for the dialog and posts WM_COMMAND IDYES so the runner
    stays unattended. Returns $true if a dialog was dismissed,
    $false if none appeared (the healthy path).
#>
function Resolve-VMConnectAnotherUserDialog {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds = 8
    )
    if (-not $IsWindows) { return $false }
    if (-not ('YurunaVMConnectDialog' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class YurunaVMConnectDialog {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hParent, EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    const uint WM_COMMAND = 0x0111;
    const uint BM_CLICK   = 0x00F5;
    const int IDOK  = 1;
    const int IDYES = 6;

    private static string ChildText(IntPtr hWnd) {
        StringBuilder agg = new StringBuilder();
        EnumChildWindows(hWnd, (h, lp) => {
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            agg.Append(sb.ToString()); agg.Append('\n');
            return true;
        }, IntPtr.Zero);
        return agg.ToString();
    }

    public static IntPtr FindDialog(uint[] vmconnectPids, string vmName) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, lp) => {
            if (!IsWindowVisible(hWnd)) return true;
            uint pid; GetWindowThreadProcessId(hWnd, out pid);
            bool ours = false;
            for (int i = 0; i < vmconnectPids.Length; i++) {
                if (vmconnectPids[i] == pid) { ours = true; break; }
            }
            if (!ours) return true;
            var cls = new StringBuilder(64);
            GetClassName(hWnd, cls, 64);
            if (cls.ToString() != "#32770") return true;
            if (ChildText(hWnd).IndexOf(vmName, StringComparison.OrdinalIgnoreCase) >= 0) {
                found = hWnd; return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool Dismiss(IntPtr hWnd) {
        SetForegroundWindow(hWnd);
        System.Threading.Thread.Sleep(120);
        SendMessage(hWnd, WM_COMMAND, (IntPtr)IDYES, IntPtr.Zero);
        System.Threading.Thread.Sleep(200);
        if (IsWindowVisible(hWnd)) {
            SendMessage(hWnd, WM_COMMAND, (IntPtr)IDOK, IntPtr.Zero);
        }
        System.Threading.Thread.Sleep(200);
        if (IsWindowVisible(hWnd)) {
            EnumChildWindows(hWnd, (h, lp) => {
                var cls = new StringBuilder(64);
                GetClassName(h, cls, 64);
                if (string.Equals(cls.ToString(), "Button", StringComparison.OrdinalIgnoreCase)) {
                    var t = new StringBuilder(128);
                    GetWindowText(h, t, 128);
                    string text = t.ToString();
                    if (text.IndexOf("Yes",     StringComparison.OrdinalIgnoreCase) >= 0 ||
                        text.IndexOf("Connect", StringComparison.OrdinalIgnoreCase) >= 0 ||
                        text.IndexOf("OK",      StringComparison.OrdinalIgnoreCase) >= 0) {
                        SendMessage(h, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
                    }
                }
                return true;
            }, IntPtr.Zero);
        }
        return true;
    }
}
"@
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $vmconnectPids = @(Get-Process -Name "vmconnect" -ErrorAction SilentlyContinue |
            ForEach-Object { [uint32]$_.Id })
        if ($vmconnectPids.Count -gt 0) {
            $hWnd = [YurunaVMConnectDialog]::FindDialog([uint32[]]$vmconnectPids, $VMName)
            if ($hWnd -ne [IntPtr]::Zero) {
                Write-Information "    Auto-dismissing vmconnect 'Another user is connected' dialog for '$VMName'"
                [void][YurunaVMConnectDialog]::Dismiss($hWnd)
                Start-Sleep -Milliseconds 600
                return $true
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

<#
.SYNOPSIS
Close and re-open the vmconnect viewer for a Hyper-V VM.

.DESCRIPTION
Closes any vmconnect.exe whose main window title matches $VMName
(graceful CloseMainWindow, then Stop-Process -Force after a 3-second
wait), then re-launches vmconnect against localhost\$VMName and
auto-dismisses the "Another user is connected" prompt. Used to refresh
a stalled viewer mid-run when keystroke delivery or screenshot capture
starts failing.
#>
function Restart-HyperVConnect {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    $vmconnect = "$env:SystemRoot\System32\vmconnect.exe"
    if (-not (Test-Path $vmconnect)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Reconnect vmconnect')) { return $false }
    $existing = @(Get-Process -Name "vmconnect" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -match [regex]::Escape($VMName) })
    foreach ($p in $existing) {
        try { [void]$p.CloseMainWindow() } catch { Write-Verbose "CloseMainWindow failed for vmconnect pid $($p.Id): $_" }
    }
    foreach ($p in $existing) {
        if (-not $p.WaitForExit(3000)) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { Write-Verbose "Force-kill of vmconnect pid $($p.Id) failed: $_" }
        }
    }
    if ($existing.Count -gt 0) { Start-Sleep -Seconds 3 }
    Start-Process -FilePath $vmconnect -ArgumentList "localhost", $VMName
    Start-Sleep -Seconds 2
    [void](Resolve-VMConnectAnotherUserDialog -VMName $VMName -TimeoutSeconds 8)
    Write-Verbose "    Reconnected vmconnect for '$VMName'"
    return $true
}

# === Host proxy helpers (migrated from test/modules/Test.HostProxy.psm1) =====
# --- See https://yuruna.link/definition#defining-the-windows-host-proxy-registry-keys

$script:WinInetRegPath    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$script:WinInetMarkerName = 'YurunaProxyManaged'
$script:EnvMarkerName     = 'YURUNA_PROXY_MANAGED'

<#
.SYNOPSIS
Indicate whether the current host proxy state was set by Yuruna.

.DESCRIPTION
Returns $true when either the WinINet YurunaProxyManaged DWORD or the
HKCU\Environment YURUNA_PROXY_MANAGED variable equals 1. The marker
prevents a re-promotion across a missing snapshot file from capturing
our own proxy URL as if it were the user's original setting.
#>
function Test-WindowsProxyIsYurunaManaged {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (Test-Path -LiteralPath $script:WinInetRegPath) {
        try {
            $val = Get-ItemPropertyValue -LiteralPath $script:WinInetRegPath -Name $script:WinInetMarkerName -ErrorAction Stop
            if ([int]$val -eq 1) { return $true }
        } catch {
            Write-Verbose "WinINet marker not present: $($_.Exception.Message)"
        }
    }
    $envMarker = [Environment]::GetEnvironmentVariable($script:EnvMarkerName, 'User')
    return ($envMarker -eq '1')
}

<#
.SYNOPSIS
Snapshot the current Windows host proxy state for later restore.

.DESCRIPTION
Reads HKCU\...\Internet Settings (ProxyEnable / ProxyServer /
ProxyOverride) and the user-scope HTTP_PROXY / HTTPS_PROXY / NO_PROXY
environment variables and returns them as a hashtable suitable for
Restore-WindowsHostProxy. When the marker reports the state is already
yuruna-managed it returns a sentinel "reset" snapshot
(yurunaResetSnapshot=$true) so callers can avoid re-capturing our own
proxy URL.
#>
function Read-WindowsProxyState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if (Test-WindowsProxyIsYurunaManaged) {
        return @{
            platform            = 'windows'
            winInet             = @{ ProxyEnable = 0; ProxyServer = $null; ProxyOverride = $null }
            envVars             = @{ HTTP_PROXY  = $null; HTTPS_PROXY = $null; NO_PROXY = $null }
            yurunaResetSnapshot = $true
        }
    }
    $wi = @{ ProxyEnable = 0; ProxyServer = $null; ProxyOverride = $null }
    if (Test-Path -LiteralPath $script:WinInetRegPath) {
        $props = Get-ItemProperty -LiteralPath $script:WinInetRegPath -ErrorAction SilentlyContinue
        if ($props) {
            if ($null -ne $props.ProxyEnable)   { $wi.ProxyEnable   = [int]$props.ProxyEnable }
            if ($null -ne $props.ProxyServer)   { $wi.ProxyServer   = [string]$props.ProxyServer }
            if ($null -ne $props.ProxyOverride) { $wi.ProxyOverride = [string]$props.ProxyOverride }
        }
    }
    $env = @{
        HTTP_PROXY  = [Environment]::GetEnvironmentVariable('HTTP_PROXY',  'User')
        HTTPS_PROXY = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'User')
        NO_PROXY    = [Environment]::GetEnvironmentVariable('NO_PROXY',    'User')
    }
    return @{ platform = 'windows'; winInet = $wi; envVars = $env }
}

<#
.SYNOPSIS
Broadcast WinINet INTERNET_OPTION_SETTINGS_CHANGED + REFRESH.

.DESCRIPTION
Notifies already-running WinINet clients (Edge, Invoke-WebRequest,
etc.) to reload proxy settings from the registry without restarting
the user session. Adds a small Add-Type once per session for the
wininet.dll P/Invoke and is a no-op on non-Windows hosts when the
type compiles (the runtime call simply returns $false).
#>
function Invoke-WinInetRefresh {
    # Broadcast SETTINGS_CHANGED + REFRESH so already-running WinINet
    # clients (Edge, Invoke-WebRequest) reload without a session restart.
    $sig = @'
using System;
using System.Runtime.InteropServices;
public static class YurunaWinInet {
    [DllImport("wininet.dll", SetLastError = true)]
    public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
'@
    if (-not ('YurunaWinInet' -as [type])) {
        Add-Type -TypeDefinition $sig -Language CSharp | Out-Null
    }
    [void][YurunaWinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][YurunaWinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}

<#
.SYNOPSIS
Point the Windows host at a Yuruna-managed HTTP proxy.

.DESCRIPTION
Writes ProxyEnable=1, ProxyServer=$ProxyParts.HostPort, and a
localhost+<local> bypass list into HKCU WinINet, then mirrors the
values into HKCU\Environment as HTTP_PROXY / HTTPS_PROXY / NO_PROXY
via setx and updates the current process Env: drive. Also stamps the
YurunaProxyManaged DWORD and YURUNA_PROXY_MANAGED env marker so a
later Read-WindowsProxyState knows the state belongs to us, then
broadcasts an Invoke-WinInetRefresh so live clients pick it up.
#>
function Set-WindowsHostProxy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][hashtable]$ProxyParts)
    $hostPort   = $ProxyParts.HostPort
    $proxyUrl   = $ProxyParts.Url
    $bypassWi   = 'localhost;127.0.0.1;<local>'
    $bypassEnv  = 'localhost,127.0.0.1,::1'
    if (-not $PSCmdlet.ShouldProcess("HKCU WinINet + HKCU\Environment", "Set host proxy to $proxyUrl")) {
        return
    }
    if (-not (Test-Path -LiteralPath $script:WinInetRegPath)) {
        New-Item -Path $script:WinInetRegPath -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyEnable'   -Value 1          -Type DWord
    Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyServer'   -Value $hostPort  -Type String
    Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyOverride' -Value $bypassWi  -Type String
    Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name $script:WinInetMarkerName -Value 1 -Type DWord
    & setx HTTP_PROXY  $proxyUrl  | Out-Null
    & setx HTTPS_PROXY $proxyUrl  | Out-Null
    & setx NO_PROXY    $bypassEnv | Out-Null
    & setx $script:EnvMarkerName 1 | Out-Null
    $env:HTTP_PROXY  = $proxyUrl
    $env:HTTPS_PROXY = $proxyUrl
    $env:NO_PROXY    = $bypassEnv
    Set-Item "Env:$($script:EnvMarkerName)" -Value '1'
    Invoke-WinInetRefresh
}

<#
.SYNOPSIS
Restore Windows host proxy state from a Read-WindowsProxyState snapshot.

.DESCRIPTION
Replays the WinINet ProxyEnable / ProxyServer / ProxyOverride values
from $State.winInet, restores the user-scope HTTP_PROXY / HTTPS_PROXY
/ NO_PROXY env vars from $State.envVars (clearing those that were
absent), strips the YurunaProxyManaged + YURUNA_PROXY_MANAGED markers,
and broadcasts Invoke-WinInetRefresh so live clients reload. Used by
the test harness to undo a prior Set-WindowsHostProxy.
#>
function Restore-WindowsHostProxy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $wi  = $State.winInet
    $env = $State.envVars
    if (-not (Test-Path -LiteralPath $script:WinInetRegPath)) {
        New-Item -Path $script:WinInetRegPath -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyEnable' -Value ([int]$wi.ProxyEnable) -Type DWord
    if ($null -ne $wi.ProxyServer) {
        Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyServer' -Value $wi.ProxyServer -Type String
    } else {
        Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyServer' -ErrorAction SilentlyContinue
    }
    if ($null -ne $wi.ProxyOverride) {
        Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyOverride' -Value $wi.ProxyOverride -Type String
    } else {
        Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyOverride' -ErrorAction SilentlyContinue
    }
    Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name $script:WinInetMarkerName -ErrorAction SilentlyContinue
    foreach ($name in 'HTTP_PROXY','HTTPS_PROXY','NO_PROXY') {
        $val = $env[$name]
        if ([string]::IsNullOrEmpty($val)) {
            [Environment]::SetEnvironmentVariable($name, $null, 'User')
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $val, 'User')
            Set-Item "Env:$name" -Value $val
        }
    }
    [Environment]::SetEnvironmentVariable($script:EnvMarkerName, $null, 'User')
    Remove-Item "Env:$($script:EnvMarkerName)" -ErrorAction SilentlyContinue
    Invoke-WinInetRefresh
}

<#
.SYNOPSIS
Turn the Windows host proxy off without losing the user's proxy URL.

.DESCRIPTION
Sets WinINet ProxyEnable to 0; if the marker says yuruna owns the
state it also clears ProxyServer and ProxyOverride so a stale Yuruna
URL isn't left behind. Always strips the YurunaProxyManaged DWORD,
clears HTTP_PROXY / HTTPS_PROXY / NO_PROXY in user scope and the
current process, drops the YURUNA_PROXY_MANAGED env marker, and
broadcasts Invoke-WinInetRefresh.
#>
function Disable-WindowsHostProxy {
    if (Test-Path -LiteralPath $script:WinInetRegPath) {
        $yurunaManaged = Test-WindowsProxyIsYurunaManaged
        Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyEnable' -Value 0 -Type DWord -ErrorAction SilentlyContinue
        if ($yurunaManaged) {
            Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyServer'   -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyOverride' -ErrorAction SilentlyContinue
        }
        Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name $script:WinInetMarkerName -ErrorAction SilentlyContinue
    }
    foreach ($name in 'HTTP_PROXY','HTTPS_PROXY','NO_PROXY') {
        [Environment]::SetEnvironmentVariable($name, $null, 'User')
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    [Environment]::SetEnvironmentVariable($script:EnvMarkerName, $null, 'User')
    Remove-Item "Env:$($script:EnvMarkerName)" -ErrorAction SilentlyContinue
    Invoke-WinInetRefresh
}

<#
.SYNOPSIS
Aggressively wipe Windows host proxy state regardless of marker.

.DESCRIPTION
Module-private helper invoked by the contract Remove-HostProxy entry
point: zeroes ProxyEnable and unconditionally removes ProxyServer +
ProxyOverride, the YurunaProxyManaged DWORD, and the user/process
HTTP_PROXY / HTTPS_PROXY / NO_PROXY values plus the
YURUNA_PROXY_MANAGED env marker, then broadcasts Invoke-WinInetRefresh.
ShouldProcess is intentionally suppressed because the public
Remove-HostProxy already gates the prompt; calling it here would
double-prompt the user.
#>
function Remove-WindowsHostProxy {
    # Aggressive marker-LESS wipe: ProxyServer + ProxyOverride removed
    # unconditionally even when no yuruna marker is present. Used by the
    # contract Remove-HostProxy entry point; that one owns ShouldProcess
    # so this private helper suppresses to avoid double-prompting.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Module-private helper; public Remove-HostProxy gates ShouldProcess.')]
    [CmdletBinding()]
    param()
    if (Test-Path -LiteralPath $script:WinInetRegPath) {
        Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyEnable' -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyServer'   -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyOverride' -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name $script:WinInetMarkerName -ErrorAction SilentlyContinue
    }
    foreach ($name in 'HTTP_PROXY','HTTPS_PROXY','NO_PROXY') {
        [Environment]::SetEnvironmentVariable($name, $null, 'User')
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    [Environment]::SetEnvironmentVariable($script:EnvMarkerName, $null, 'User')
    Remove-Item "Env:$($script:EnvMarkerName)" -ErrorAction SilentlyContinue
    Invoke-WinInetRefresh
}

# === Port-map helpers (migrated from test/modules/Test.PortMap.psm1) =========
$script:FirewallRulePrefix        = 'Yuruna-CachingProxy-Port-'
$script:FirewallProgramRulePrefix = 'Yuruna-CachingProxy-Pwsh-'

<#
.SYNOPSIS
Return the path to the shared squid-cache TCP forwarder script.

.DESCRIPTION
Resolves host/macos.utm/Start-CachingProxyForwarder.ps1 against the
repository root inferred from $PSScriptRoot. The forwarder script
lives under host/macos.utm/ for historical reasons but is pure
PowerShell and runs unchanged on Windows.
#>
function Get-CachingProxyForwarderScriptPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Forwarder script lives under host/macos.utm/ for historical reasons;
    # it's pure PowerShell so it runs on Windows as well.
    # $PSScriptRoot is host/windows.hyper-v/modules, so three levels up is repo root.
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    return (Join-Path $repoRoot 'host/macos.utm/Start-CachingProxyForwarder.ps1')
}

<#
.SYNOPSIS
Return the path to pwsh.exe for use in firewall per-program rules.

.DESCRIPTION
Best-guess via Get-Command -CommandType Application. The result may
point at the WindowsApps App Execution Alias stub (a zero-byte
reparse point); Defender filters on the post-resolution path so the
caller should re-read Get-Process .Path after spawning the forwarder
and rewrite the rule when the loaded binary differs. Returns $null
when pwsh.exe is not on PATH.
#>
function Get-PwshExePath {
    # Best-guess for Defender's per-program rule. WindowsApps App Execution
    # Alias is a reparse stub; Defender filters on the post-resolution path.
    # After spawn, callers re-read Get-Process .Path and rewrite the rule
    # if the loaded path differs.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $cmd = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

<#
.SYNOPSIS
Return the pidfile path for the per-port caching-proxy forwarder.

.DESCRIPTION
Composes ~/virtual/squid-cache/forwarder.<Port>.pid. The pidfile is
the canonical handle Stop-WindowsCachingProxyForwarder uses to find
and kill the detached pwsh worker that owns a given listen port.
#>
function Get-WindowsForwarderPidPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Port)
    $stateDir = Join-Path $HOME 'virtual\squid-cache'
    return (Join-Path $stateDir "forwarder.$Port.pid")
}

<#
.SYNOPSIS
Stop a detached pwsh caching-proxy forwarder by listen port.

.DESCRIPTION
Reads ~/virtual/squid-cache/forwarder.<Port>.pid, validates the pid
belongs to a pwsh/powershell process, and calls Stop-Process -Force.
Removes the pidfile in all cases (including missing pid, non-pwsh
owner, or successful kill) so a stale file doesn't trip later starts.
No-op on non-Windows hosts; -Quiet suppresses the per-port summary
line.
#>
function Stop-WindowsCachingProxyForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][int]$Port, [switch]$Quiet)
    if (-not $IsWindows) { return $true }
    $pidFile = Get-WindowsForwarderPidPath -Port $Port
    if (-not (Test-Path $pidFile)) { return $true }
    $forwarderPid = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not ($forwarderPid -as [int])) {
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    $proc = Get-Process -Id ([int]$forwarderPid) -ErrorAction SilentlyContinue
    if ($proc) {
        if ($proc.ProcessName -match '^(pwsh|powershell)$') {
            if ($PSCmdlet.ShouldProcess("pid $forwarderPid (port :${Port})", 'Stop forwarder process')) {
                if (-not $Quiet) { Write-Information "  Stopping forwarder (pid $forwarderPid, port :${Port})..." }
                Stop-Process -Id ([int]$forwarderPid) -Force -ErrorAction SilentlyContinue
            }
        } elseif (-not $Quiet) {
            Write-Warning "Pid $forwarderPid is not pwsh/powershell (is: $($proc.ProcessName)) -- leaving alone, removing stale pidfile."
        }
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    return $true
}

<#
.SYNOPSIS
Launch a detached pwsh TCP forwarder for the squid caching proxy.

.DESCRIPTION
Stops any prior forwarder for the same $Port, then spawns
Start-CachingProxyForwarder.ps1 hidden, wired to redirect stdout /
stderr to per-port logs under ~/virtual/squid-cache/. Polls
127.0.0.1:$Port for up to 3 s; on success returns a PSCustomObject
@{ Success=$true; Pid; PwshPath } where PwshPath is the post-spawn
loaded binary (used by callers to rewrite the Defender per-program
firewall rule when the WindowsApps alias differs). $VMPort defaults
to $Port. -PrependProxyV1 forwards a HAProxy v1 PROXY header so the
upstream cache can see the original LAN client IP.
#>
function Start-WindowsCachingProxyForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$CacheIp,
        [Parameter(Mandatory)][int]$Port,
        [int]$VMPort = 0,
        [switch]$PrependProxyV1
    )
    if (-not $IsWindows) {
        Write-Warning "Start-WindowsCachingProxyForwarder called on non-Windows host -- no-op."
        return [PSCustomObject]@{ Success = $false; Pid = $null; PwshPath = $null }
    }
    if ($VMPort -eq 0) { $VMPort = $Port }
    $forwarderScript = Get-CachingProxyForwarderScriptPath
    if (-not (Test-Path $forwarderScript)) {
        Write-Warning "Forwarder script not found: $forwarderScript"
        return [PSCustomObject]@{ Success = $false; Pid = $null; PwshPath = $null }
    }
    $stateDir = Join-Path $HOME 'virtual\squid-cache'
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $pidFile = Get-WindowsForwarderPidPath -Port $Port
    $logFile = Join-Path $stateDir "forwarder.$Port.log"
    $stdoutLog = Join-Path $stateDir "forwarder.$Port.stdout.log"
    $stderrLog = Join-Path $stateDir "forwarder.$Port.stderr.log"
    Stop-WindowsCachingProxyForwarder -Port $Port -Quiet
    $proxyTag = if ($PrependProxyV1) { ' [PROXY v1]' } else { '' }
    $action   = "0.0.0.0:${Port} -> ${CacheIp}:${VMPort}${proxyTag}"
    if (-not $PSCmdlet.ShouldProcess($action, 'Launch detached pwsh TCP forwarder')) {
        return [PSCustomObject]@{ Success = $false; Pid = $null; PwshPath = $null }
    }
    Write-Information "  Launching userspace forwarder: ${action}"
    $procArgs = @(
        '-NoProfile','-NoLogo','-File', $forwarderScript,
        '-CacheIp', $CacheIp,
        '-Port', $Port,
        '-VMPort', $VMPort,
        '-PidFile', $pidFile,
        '-LogFile', $logFile
    )
    if ($PrependProxyV1) { $procArgs += '-PrependProxyV1' }
    try {
        $proc = Start-Process -FilePath 'pwsh' `
            -ArgumentList $procArgs `
            -RedirectStandardOutput $stdoutLog `
            -RedirectStandardError  $stderrLog `
            -WindowStyle Hidden `
            -PassThru
    } catch {
        Write-Warning "Failed to spawn forwarder: $($_.Exception.Message)"
        return [PSCustomObject]@{ Success = $false; Pid = $null; PwshPath = $null }
    }
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline) {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        try {
            $h = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
            if ($h.AsyncWaitHandle.WaitOne(150) -and $tcp.Connected) {
                $tcp.Close()
                $actualPid = if (Test-Path $pidFile) { [int]((Get-Content $pidFile -Raw).Trim()) } else { [int]$proc.Id }
                $loadedPath = $null
                try { $loadedPath = (Get-Process -Id $actualPid -ErrorAction Stop).Path } catch { $null = $_ }
                Write-Information "  Forwarder up (pid $actualPid): ${action}"
                if ($loadedPath) { Write-Information "    loaded binary: $loadedPath" }
                return [PSCustomObject]@{ Success = $true; Pid = $actualPid; PwshPath = $loadedPath }
            }
        } catch { $null = $_ } finally { $tcp.Close() }
        Start-Sleep -Milliseconds 100
    }
    Write-Warning "Forwarder launched (pid $($proc.Id)) but :${Port} did not answer within 3s -- see $stderrLog."
    return [PSCustomObject]@{ Success = $false; Pid = [int]$proc.Id; PwshPath = $null }
}

<#
.SYNOPSIS
Install Yuruna-tagged inbound firewall rules for a caching-proxy port.

.DESCRIPTION
Removes any existing rules with the Yuruna-CachingProxy-Port-<Port>
display name, then creates a fresh Allow rule on that TCP port across
all profiles. When -IncludeProgram is set it also (re)creates a
Yuruna-CachingProxy-Pwsh-<Port> per-program rule scoped to
$ProgramPath (or Get-PwshExePath when omitted). The per-program rule
guards against Defender silently dropping LAN traffic when the
WindowsApps App Execution Alias resolves to a different binary than
the loaded pwsh.exe; if no path is resolvable the rule is skipped
with a warning.
#>
function Add-CachingProxyFirewallRule {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Description,
        [switch]$IncludeProgram,
        [string]$ProgramPath
    )
    if (-not $IsWindows) { return }
    $portRule = "${script:FirewallRulePrefix}${Port}"
    if ($PSCmdlet.ShouldProcess($portRule, 'Install port-scope Allow rule')) {
        Get-NetFirewallRule -DisplayName $portRule -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $portRule -Direction Inbound `
            -Protocol TCP -LocalPort $Port -Action Allow `
            -Profile Any `
            -Description $Description `
            -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not $IncludeProgram) { return }
    $programRule = "${script:FirewallProgramRulePrefix}${Port}"
    if ($PSCmdlet.ShouldProcess($programRule, 'Install per-program Allow rule for pwsh.exe')) {
        Get-NetFirewallRule -DisplayName $programRule -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
        $pwshPath = if ($ProgramPath) { $ProgramPath } else { Get-PwshExePath }
        if (-not $pwshPath) {
            Write-Warning "No pwsh.exe path available -- skipping ${programRule}. LAN clients may see :${Port} silently dropped by Windows Defender Firewall."
            return
        }
        New-NetFirewallRule -DisplayName $programRule -Direction Inbound `
            -Protocol TCP -LocalPort $Port -Action Allow `
            -Profile Any `
            -Program $pwshPath `
            -Description "${Description} (per-program: $pwshPath)" `
            -ErrorAction SilentlyContinue | Out-Null
    }
}

<#
.SYNOPSIS
List ports that currently have a forwarder pidfile on disk.

.DESCRIPTION
Walks ~/virtual/squid-cache/ for forwarder.<port>.pid files and
returns the parsed integer port numbers as an array (always wrapped
with the unary comma so a single-element result still flows as an
array). Empty array on non-Windows hosts or when the state directory
is missing.
#>
function Get-WindowsForwarderPidPort {
    [CmdletBinding()]
    [OutputType([int[]], [System.Object[]])]
    param()
    if (-not $IsWindows) { return @() }
    $stateDir = Join-Path $HOME 'virtual\squid-cache'
    if (-not (Test-Path $stateDir)) { return @() }
    $ports = @()
    Get-ChildItem -LiteralPath $stateDir -Filter 'forwarder.*.pid' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.BaseName -match '^forwarder\.(\d+)$') { $ports += [int]$matches[1] }
        }
    return ,$ports
}

<#
.SYNOPSIS
Discover Yuruna caching-proxy ports from existing firewall rules.

.DESCRIPTION
Scans Get-NetFirewallRule for display names that begin with
Yuruna-CachingProxy-Port- or Yuruna-CachingProxy-Pwsh- and returns
the parsed integer ports, sorted and de-duplicated. Used by
Clear-AllCachingProxyPortMapping to clean up rules left behind when
a state file was deleted out of band.
#>
function Get-YurunaMappedPortFromFirewall {
    [CmdletBinding()]
    [OutputType([int[]], [System.Object[]])]
    param()
    if (-not $IsWindows) { return @() }
    $ports = @()
    $prefixPattern = '^(?:' +
        [regex]::Escape($script:FirewallRulePrefix) + '|' +
        [regex]::Escape($script:FirewallProgramRulePrefix) +
        ')(\d+)$'
    Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -like "${script:FirewallRulePrefix}*" -or
            $_.DisplayName -like "${script:FirewallProgramRulePrefix}*"
        } |
        ForEach-Object {
            if ($_.DisplayName -match $prefixPattern) {
                $ports += [int]$matches[1]
            }
        }
    return ,($ports | Sort-Object -Unique)
}

<#
.SYNOPSIS
Remove the portproxy, forwarder, and firewall rules for one port.

.DESCRIPTION
Deletes the netsh interface portproxy v4tov4 entry on 0.0.0.0:$Port,
stops the matching detached pwsh forwarder, and removes both the
Yuruna-CachingProxy-Port-<Port> and Yuruna-CachingProxy-Pwsh-<Port>
firewall rules if present. Idempotent: missing pieces are silently
skipped so callers can issue a blanket sweep.
#>
function Remove-SinglePortMap {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][int]$Port)
    if (-not $PSCmdlet.ShouldProcess("host:${Port}", 'Remove portproxy + firewall rule')) { return }
    & netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=0.0.0.0 2>&1 | Out-Null
    Stop-WindowsCachingProxyForwarder -Port $Port -Quiet
    foreach ($prefix in @($script:FirewallRulePrefix, $script:FirewallProgramRulePrefix)) {
        $ruleName = "${prefix}${Port}"
        Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
Tear down every Yuruna caching-proxy port mapping on this host.

.DESCRIPTION
Builds the union of ports recorded in the optional $StatePath JSON,
ports discovered via Get-YurunaMappedPortFromFirewall, and ports with
a live forwarder pidfile (Get-WindowsForwarderPidPort), then calls
Remove-SinglePortMap on each. Deletes $StatePath when present and
returns the de-duplicated, sorted port list as an array. The triple
union is the safety net that keeps state, firewall, and pidfile in
sync even when one of them has drifted.
#>
function Clear-AllCachingProxyPortMapping {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int[]], [System.Object[]])]
    param([string]$StatePath)
    $ports = @()
    if ($StatePath -and (Test-Path $StatePath)) {
        try {
            $prev = Get-Content -Raw $StatePath | ConvertFrom-Json
            foreach ($p in @($prev.ports)) {
                if ($p -is [int] -or $p -match '^\d+$') { $ports += [int]$p }
            }
        } catch {
            Write-Verbose "Clear-AllCachingProxyPortMapping: could not read state ($StatePath): $_"
        }
    }
    foreach ($p in (Get-YurunaMappedPortFromFirewall)) { $ports += $p }
    foreach ($p in (Get-WindowsForwarderPidPort)) { $ports += $p }
    $unique = @($ports | Sort-Object -Unique)
    foreach ($p in $unique) {
        if ($PSCmdlet.ShouldProcess("host:${p}", 'Clear Yuruna port mapping')) {
            Remove-SinglePortMap -Port $p -Confirm:$false
        }
    }
    if ($StatePath -and (Test-Path $StatePath)) {
        Remove-Item -Path $StatePath -Force -ErrorAction SilentlyContinue
    }
    return ,$unique
}

# === SSH server helpers (migrated from test/modules/Test.SshServer.psm1) =====
# A single Yuruna-managed firewall rule (LocalSubnet + all profiles) opens
# TCP/22 for peers on the receiving adapter's local subnet. Distinct from
# the default 'OpenSSH-Server-In-TCP' rule (Private only) so they coexist.

$script:YurunaSshRuleName = 'Yuruna-OpenSSH-LocalSubnet'

<#
.SYNOPSIS
Install the Yuruna LocalSubnet inbound rule for OpenSSH on TCP/22.

.DESCRIPTION
Idempotently creates Yuruna-OpenSSH-LocalSubnet, an inbound TCP/22
Allow rule scoped to LocalSubnet across all profiles. This sits next
to the default 'OpenSSH-Server-In-TCP' rule (Private profile only) so
LAN-side test peers can reach sshd without widening the built-in
rule. Returns $true when the rule exists at the end (whether
pre-existing or newly added) and $false on failure.
#>
function Add-YurunaSshFirewallRule {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        if (Get-NetFirewallRule -Name $script:YurunaSshRuleName -ErrorAction SilentlyContinue) {
            Write-Information "Firewall rule '$script:YurunaSshRuleName' already present." -InformationAction Continue
            return $true
        }
        New-NetFirewallRule `
            -Name          $script:YurunaSshRuleName `
            -DisplayName   'Yuruna OpenSSH Server (LocalSubnet, all profiles)' `
            -Description   'Inbound TCP/22 from peers on the receiving adapter''s local subnet. Managed by Yuruna.Host Start-SshServer / Stop-SshServer.' `
            -Direction     Inbound `
            -Protocol      TCP `
            -LocalPort     22 `
            -RemoteAddress LocalSubnet `
            -Profile       Any `
            -Action        Allow `
            -ErrorAction   Stop | Out-Null
        Write-Information "Firewall rule '$script:YurunaSshRuleName' created (LocalSubnet, all profiles)." -InformationAction Continue
        return $true
    } catch {
        Write-Warning "Add-YurunaSshFirewallRule failed: $_"
        return $false
    }
}

<#
.SYNOPSIS
Remove the Yuruna LocalSubnet OpenSSH firewall rule.

.DESCRIPTION
Deletes Yuruna-OpenSSH-LocalSubnet via Remove-NetFirewallRule when it
exists. Returns $true on success or when the rule was already absent;
$false only when Remove-NetFirewallRule itself errored.
#>
function Remove-YurunaSshFirewallRule {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    try {
        if (Get-NetFirewallRule -Name $script:YurunaSshRuleName -ErrorAction SilentlyContinue) {
            if ($PSCmdlet.ShouldProcess($script:YurunaSshRuleName, 'Remove-NetFirewallRule')) {
                Remove-NetFirewallRule -Name $script:YurunaSshRuleName -ErrorAction Stop
                Write-Information "Firewall rule '$script:YurunaSshRuleName' removed." -InformationAction Continue
            }
        } else {
            Write-Information "Firewall rule '$script:YurunaSshRuleName' not present." -InformationAction Continue
        }
        return $true
    } catch {
        Write-Warning "Remove-YurunaSshFirewallRule failed: $_"
        return $false
    }
}

<#
.SYNOPSIS
Start the sshd service and ensure it auto-starts on boot.

.DESCRIPTION
Requires administrator privileges. Starts the sshd service if it's
not already running, sets its startup type to Automatic, and ensures
the Yuruna LocalSubnet firewall rule is present. Returns $false when
the service isn't installed (caller should run Install-SshServer
first), when not elevated, or on a service-control failure.
#>
function Enable-WindowsSshServer {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Test-IsAdministrator)) {
        Write-Warning "Enable-WindowsSshServer: not running as Administrator -- skipping."
        return $false
    }
    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Warning "sshd service not installed. Run Install-SshServer first."
        return $false
    }
    try {
        if ($svc.Status -ne 'Running') {
            Start-Service -Name sshd -ErrorAction Stop
            Write-Information "sshd service started." -InformationAction Continue
        } else {
            Write-Information "sshd service is already running." -InformationAction Continue
        }
        if ($svc.StartType -ne 'Automatic') {
            Set-Service -Name sshd -StartupType 'Automatic' -ErrorAction Stop
            Write-Information "sshd startup type set to Automatic." -InformationAction Continue
        }
        $null = Add-YurunaSshFirewallRule
        return $true
    } catch {
        Write-Warning "Failed to start/configure sshd service: $_"
        return $false
    }
}

<#
.SYNOPSIS
Stop the sshd service, demote it to Manual start, and remove the rule.

.DESCRIPTION
Requires administrator privileges. Stops sshd if it is running, sets
its startup type to Manual when currently Automatic, and removes the
Yuruna LocalSubnet firewall rule. Treats a missing service as success
(still removes the firewall rule). Returns $false when not elevated
or on a service-control failure.
#>
function Disable-WindowsSshServer {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Test-IsAdministrator)) {
        Write-Warning "Disable-WindowsSshServer: not running as Administrator -- skipping."
        return $false
    }
    try {
        $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Information "sshd service is not installed -- nothing to disable." -InformationAction Continue
            $null = Remove-YurunaSshFirewallRule
            return $true
        }
        if ($svc.Status -eq 'Running') {
            Stop-Service -Name sshd -ErrorAction Stop
            Write-Information "sshd service stopped." -InformationAction Continue
        } else {
            Write-Information "sshd service is already stopped." -InformationAction Continue
        }
        if ($svc.StartType -ne 'Manual' -and $svc.StartType -ne 'Disabled') {
            Set-Service -Name sshd -StartupType 'Manual' -ErrorAction Stop
            Write-Information "sshd startup type set to Manual." -InformationAction Continue
        }
        $null = Remove-YurunaSshFirewallRule
        return $true
    } catch {
        Write-Warning "Failed to stop/configure sshd service: $_"
        return $false
    }
}

<#
.SYNOPSIS
Install the OpenSSH Server capability and bring it fully online.

.DESCRIPTION
Requires administrator privileges. Fast-paths to a no-op when the
sshd service is already registered (which proves the capability is
installed) -- otherwise queries Get-WindowsCapability -Online (a
30+ s call) and runs Add-WindowsCapability if needed. Then calls
Enable-WindowsSshServer to start the service and add the firewall
rule, and finally checks that at least one OpenSSH-Server* firewall
rule is enabled. Returns $false on any failure.
#>
function Install-WindowsSshServer {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Test-IsAdministrator)) {
        Write-Warning "Install-WindowsSshServer: not running as Administrator -- skipping."
        return $false
    }
    # Fast-path: skip Get-WindowsCapability -Online (30+ s) when the sshd
    # service is already registered, which proves the capability is installed.
    $sshService = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($sshService) {
        Write-Information "OpenSSH Server already installed (sshd service present)." -InformationAction Continue
    } else {
        try {
            Write-Information "OpenSSH Server not detected. Querying Windows capability store (this can take 30+ seconds)..." -InformationAction Continue
            $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" -ErrorAction Stop |
                Select-Object -First 1
            if (-not $cap) {
                Write-Warning "Could not enumerate OpenSSH.Server capability."
                return $false
            }
            if ($cap.State -ne 'Installed') {
                Write-Information "Installing OpenSSH Server capability ($($cap.Name)). This may take SEVERAL MINUTES -- please wait..." -InformationAction Continue
                $null = Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop
                Write-Information "OpenSSH Server capability install complete." -InformationAction Continue
            } else {
                Write-Information "OpenSSH Server capability is marked Installed but sshd service is not yet registered." -InformationAction Continue
            }
        } catch {
            Write-Warning "Failed to install OpenSSH Server capability: $_"
            return $false
        }
    }
    if (-not (Enable-WindowsSshServer)) { return $false }
    try {
        $rules = Get-NetFirewallRule -Name "*OpenSSH-Server*" -ErrorAction SilentlyContinue
        if (-not $rules) {
            Write-Warning "No OpenSSH-Server firewall rule found. SSH on port 22 may be blocked."
        } else {
            $enabledRules = $rules | Where-Object { $_.Enabled -eq 'True' }
            if (-not $enabledRules) {
                Write-Warning "OpenSSH-Server firewall rule(s) exist but none are enabled."
            } else {
                Write-Information "OpenSSH-Server firewall rule is enabled." -InformationAction Continue
            }
        }
    } catch {
        Write-Warning "Firewall rule check failed: $_"
    }
    return $true
}

# === Screenshot helpers (migrated from test/modules/Test.Screenshot.psm1) ====
# Two capture paths:
#   1. Msvm_VirtualSystemManagementService.GetVirtualSystemThumbnailImage --
#      no window required, native VM resolution. Used by OCR.
#   2. PrintWindow against the vmconnect window -- used by click-by-OCR
#      because clicks need the same coord space as the captured pixels,
#      and the WMI thumbnail does NOT match vmconnect's client area.

<#
.SYNOPSIS
Capture a screenshot of a Hyper-V VM via the WMI thumbnail API.

.DESCRIPTION
Uses Msvm_VirtualSystemManagementService.GetVirtualSystemThumbnailImage
to grab the VM's framebuffer at native resolution and writes it to
$OutputPath as a PNG. Does not require a vmconnect window and runs
even when the host is headless. Use the PrintWindow path (separate
helper) when click-by-OCR needs coordinates that match vmconnect's
client area.
#>
function Get-HyperVScreenshot {
    param([string]$VMName, [string]$OutputPath)

    # ── Load C# type (once per session) ────────────────────────────────────
    try {
        if (-not ('HyperVCapture' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public class HyperVCapture {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
    [DllImport("gdi32.dll")]  public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")]  public static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int w, int h);
    [DllImport("gdi32.dll")]  public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")]  public static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")]  public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")]  public static extern int GetDIBits(IntPtr hdc, IntPtr hbmp, uint start, uint lines, byte[] bits, ref BITMAPINFO bi, uint usage);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hdc);
    static bool dpiAware = false;
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct BITMAPINFOHEADER {
        public uint biSize; public int biWidth; public int biHeight; public ushort biPlanes;
        public ushort biBitCount; public uint biCompression; public uint biSizeImage;
        public int biXPelsPerMeter; public int biYPelsPerMeter; public uint biClrUsed; public uint biClrImportant;
    }
    [StructLayout(LayoutKind.Sequential)] public struct BITMAPINFO { public BITMAPINFOHEADER bmiHeader; }

    public static IntPtr FindWindow(string titleContains) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, lp) => {
            if (!IsWindowVisible(hWnd)) return true;
            var sb = new StringBuilder(256);
            GetWindowText(hWnd, sb, 256);
            if (sb.ToString().Contains(titleContains)) { found = hWnd; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    const uint PW_CLIENT_RENDER = 3;

    public static void EnsureDpiAware() {
        if (!dpiAware) { SetProcessDPIAware(); dpiAware = true; }
    }

    static bool GetClientSize(IntPtr hWnd, out int w, out int h) {
        EnsureDpiAware();
        RECT r; GetClientRect(hWnd, out r);
        w = r.Right; h = r.Bottom;
        return w > 0 && h > 0;
    }

    static FileStream OpenWriteWithRetry(string path) {
        IOException last = null;
        for (int attempt = 0; attempt < 5; attempt++) {
            try {
                return new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
            } catch (IOException ex) {
                last = ex;
                if (attempt < 4) System.Threading.Thread.Sleep(200);
            }
        }
        throw last;
    }

    public static bool CaptureToFile(IntPtr hWnd, string path) {
        int w, h;
        if (!GetClientSize(hWnd, out w, out h)) return false;
        IntPtr screenDC = GetDC(IntPtr.Zero);
        IntPtr memDC = CreateCompatibleDC(screenDC);
        IntPtr hBmp = CreateCompatibleBitmap(screenDC, w, h);
        IntPtr old = SelectObject(memDC, hBmp);
        PrintWindow(hWnd, memDC, PW_CLIENT_RENDER);
        var bi = new BITMAPINFO();
        bi.bmiHeader.biSize = 40; bi.bmiHeader.biWidth = w; bi.bmiHeader.biHeight = -h;
        bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 32;
        byte[] pixels = new byte[w * h * 4];
        GetDIBits(memDC, hBmp, 0, (uint)h, pixels, ref bi, 0);
        SelectObject(memDC, old); DeleteObject(hBmp); DeleteDC(memDC); ReleaseDC(IntPtr.Zero, screenDC);
        using (var fs = OpenWriteWithRetry(path)) {
            WritePng(fs, w, h, pixels);
        }
        return true;
    }

    // Detects a fully-rendered framebuffer that came back essentially
    // black -- the Hyper-V "headless host" symptom (DWM not rendering
    // because no monitor is connected). Returns true when the fraction
    // of "dark" pixels (every channel below `byteThreshold`) meets or
    // exceeds `darkFraction`. Used by Get-HyperVScreenshot to surface a
    // clear warning when the WMI thumbnail comes back all-black so the
    // operator gets pointed at the troubleshooting page instead of
    // chasing a silent OCR-times-out failure.
    public static bool IsImageMostlyBlack(byte[] imageData, int w, int h, double darkFraction) {
        if (imageData == null || w <= 0 || h <= 0) return false;
        int expected16 = w * h * 2;
        int expected24 = w * h * 3;
        int expected32 = w * h * 4;
        long total = (long)w * h;
        if (total <= 0) return false;
        long dark = 0;
        const int byteThreshold = 16;
        if (imageData.Length >= expected32) {
            for (int i = 0; i < total; i++) {
                int p = i * 4;
                if (imageData[p] < byteThreshold && imageData[p+1] < byteThreshold && imageData[p+2] < byteThreshold) dark++;
            }
        } else if (imageData.Length >= expected24) {
            for (int i = 0; i < total; i++) {
                int p = i * 3;
                if (imageData[p] < byteThreshold && imageData[p+1] < byteThreshold && imageData[p+2] < byteThreshold) dark++;
            }
        } else if (imageData.Length >= expected16) {
            // RGB565: pack-value < 0x1083 ~= every channel below ~16/255.
            for (int i = 0; i < total; i++) {
                ushort pixel = (ushort)(imageData[i*2] | (imageData[i*2+1] << 8));
                if (pixel < 0x1083) dark++;
            }
        } else {
            return false;
        }
        return ((double)dark / total) >= darkFraction;
    }

    public static bool SaveRawImageAsPng(byte[] imageData, int w, int h, string path) {
        if (imageData == null || w <= 0 || h <= 0) return false;
        int expected32 = w * h * 4;
        int expected16 = w * h * 2;
        int expected24 = w * h * 3;
        byte[] bgra;
        if (imageData.Length >= expected32) {
            bgra = imageData;
        } else if (imageData.Length >= expected24) {
            bgra = new byte[expected32];
            for (int i = 0; i < w * h; i++) {
                bgra[i*4]   = imageData[i*3+2]; // B
                bgra[i*4+1] = imageData[i*3+1]; // G
                bgra[i*4+2] = imageData[i*3];   // R
                bgra[i*4+3] = 255;
            }
        } else if (imageData.Length >= expected16) {
            bgra = new byte[expected32];
            for (int i = 0; i < w * h; i++) {
                ushort pixel = (ushort)(imageData[i*2] | (imageData[i*2+1] << 8));
                byte r = (byte)(((pixel >> 11) & 0x1F) << 3);
                byte g = (byte)(((pixel >> 5) & 0x3F) << 2);
                byte b = (byte)((pixel & 0x1F) << 3);
                bgra[i*4] = b; bgra[i*4+1] = g; bgra[i*4+2] = r; bgra[i*4+3] = 255;
            }
        } else {
            return false;
        }
        using (var fs = OpenWriteWithRetry(path)) {
            WritePng(fs, w, h, bgra);
        }
        return true;
    }

    static void WritePng(Stream s, int w, int h, byte[] bgra) {
        s.Write(new byte[]{137,80,78,71,13,10,26,10}, 0, 8);
        var ihdr = new byte[13];
        WriteInt32BE(ihdr, 0, w); WriteInt32BE(ihdr, 4, h);
        ihdr[8]=8; ihdr[9]=2;
        WriteChunk(s, "IHDR", ihdr);
        using (var ms = new MemoryStream()) {
            using (var ds = new System.IO.Compression.DeflateStream(ms, System.IO.Compression.CompressionLevel.Fastest, true)) {
                for (int y = 0; y < h; y++) {
                    ds.WriteByte(0);
                    int rowOff = y * w * 4;
                    for (int x = 0; x < w; x++) {
                        int p = rowOff + x * 4;
                        ds.WriteByte(bgra[p+2]);
                        ds.WriteByte(bgra[p+1]);
                        ds.WriteByte(bgra[p]);
                    }
                }
            }
            byte[] compressed = ms.ToArray();
            using (var zlib = new MemoryStream()) {
                zlib.WriteByte(0x78); zlib.WriteByte(0x01);
                zlib.Write(compressed, 0, compressed.Length);
                uint a1=1, a2=0;
                for (int y=0; y<h; y++) {
                    a1=(a1+0)%65521; a2=(a2+a1)%65521;
                    int rowOff = y * w * 4;
                    for (int x=0; x<w; x++) {
                        int p = rowOff + x * 4;
                        a1=(a1+bgra[p+2])%65521; a2=(a2+a1)%65521;
                        a1=(a1+bgra[p+1])%65521; a2=(a2+a1)%65521;
                        a1=(a1+bgra[p])%65521;   a2=(a2+a1)%65521;
                    }
                }
                var adler = new byte[4];
                WriteInt32BE(adler, 0, (int)((a2<<16)|a1));
                zlib.Write(adler, 0, 4);
                WriteChunk(s, "IDAT", zlib.ToArray());
            }
        }
        WriteChunk(s, "IEND", new byte[0]);
    }
    static void WriteChunk(Stream s, string type, byte[] data) {
        var len = new byte[4]; WriteInt32BE(len, 0, data.Length); s.Write(len,0,4);
        var t = Encoding.ASCII.GetBytes(type); s.Write(t,0,4);
        s.Write(data, 0, data.Length);
        uint crc = Crc32(t, data);
        var c = new byte[4]; WriteInt32BE(c, 0, (int)crc); s.Write(c,0,4);
    }
    static void WriteInt32BE(byte[] b, int off, int v) {
        b[off]=(byte)(v>>24); b[off+1]=(byte)(v>>16); b[off+2]=(byte)(v>>8); b[off+3]=(byte)v;
    }
    static uint Crc32(byte[] type, byte[] data) {
        uint c = 0xFFFFFFFF;
        foreach (byte b in type) c = CrcByte(c, b);
        foreach (byte b in data) c = CrcByte(c, b);
        return c ^ 0xFFFFFFFF;
    }
    static uint CrcByte(uint c, byte b) {
        c ^= b;
        for (int i=0;i<8;i++) c = (c&1)!=0 ? (c>>1)^0xEDB88320 : c>>1;
        return c;
    }
}
"@
        }
    } catch {
        Write-Warning "Failed to load HyperVCapture type: $_"
    }

    Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.LogDir.psm1') -Force -ErrorAction SilentlyContinue -Verbose:$false
    $debugDir = Join-Path (Initialize-YurunaLogDir) "Screenshot"
    if (-not (Test-Path $debugDir)) { New-Item -ItemType Directory -Force -Path $debugDir | Out-Null }

    # ── Primary: WMI GetVirtualSystemThumbnailImage ────────────────────────
    try {
        $vmSettingData = Get-CimInstance -Namespace root/virtualization/v2 `
            -ClassName Msvm_VirtualSystemSettingData `
            -Filter "ElementName='$VMName'" |
            Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }
        if ($vmSettingData) {
            $vmms = Get-CimInstance -Namespace root/virtualization/v2 `
                -ClassName Msvm_VirtualSystemManagementService
            $vmVideo = Hyper-V\Get-VMVideo -VMName $VMName -ErrorAction SilentlyContinue
            $reqW = $vmVideo ? [uint16]$vmVideo.HorizontalResolution : [uint16]1920
            $reqH = $vmVideo ? [uint16]$vmVideo.VerticalResolution : [uint16]1080
            $result = Invoke-CimMethod -InputObject $vmms `
                -MethodName GetVirtualSystemThumbnailImage `
                -Arguments @{
                    TargetSystem = $vmSettingData
                    WidthPixels  = $reqW
                    HeightPixels = $reqH
                }
            if ($result.ReturnValue -eq 0 -and $result.ImageData -and $result.ImageData.Length -gt 0) {
                # Detect the "headless host" symptom: WMI returns a valid
                # thumbnail but every pixel is black because the host's
                # DWM isn't actively painting the synthetic GPU. Warn
                # ONCE per process so a long Invoke-TestRunner cycle
                # doesn't flood the log with the same message every step.
                if (-not $script:__YurunaHyperVBlankWarned -and
                    [HyperVCapture]::IsImageMostlyBlack(
                        [byte[]]$result.ImageData, [int]$reqW, [int]$reqH, 0.99)) {
                    Write-Verbose "Hyper-V WMI thumbnail came back all-black for '$VMName'."
                    Write-Verbose "See https://yuruna.link/monitorless"
                    $script:__YurunaHyperVBlankWarned = $true
                }
                $ok = [HyperVCapture]::SaveRawImageAsPng(
                    [byte[]]$result.ImageData, [int]$reqW, [int]$reqH, $OutputPath)
                if ($ok -and (Test-Path $OutputPath)) {
                    Copy-Item -Path $OutputPath -Destination (Join-Path $debugDir "wmi_full.png") -Force
                    Write-Debug "Screenshot saved (WMI ${reqW}x${reqH}): $OutputPath"
                    return $OutputPath
                }
                [System.IO.File]::WriteAllText((Join-Path $debugDir "wmi_debug.txt"),
                    "dataLen=$($result.ImageData.Length) expected16=$(${reqW}*${reqH}*2) expected24=$(${reqW}*${reqH}*3) expected32=$(${reqW}*${reqH}*4)")
            } else {
                $rc = $result ? $result.ReturnValue : "null"
                $len = ($result -and $result.ImageData) ? $result.ImageData.Length : 0
                [System.IO.File]::WriteAllText((Join-Path $debugDir "wmi_debug.txt"), "rc=$rc dataLen=$len")
            }
        } else {
            [System.IO.File]::WriteAllText((Join-Path $debugDir "wmi_debug.txt"), "vmSettingData not found")
        }
    } catch {
        [System.IO.File]::WriteAllText((Join-Path $debugDir "wmi_debug.txt"), "exception: $_")
    }

    # ── Fallback: PrintWindow via vmconnect window ─────────────────────────
    try {
        [HyperVCapture]::EnsureDpiAware()
        $hWnd = [HyperVCapture]::FindWindow($VMName)
        if ($hWnd -eq [IntPtr]::Zero) {
            Write-Warning "vmconnect window not found for '$VMName'."
            return $null
        }
        $dpi = [HyperVCapture]::GetDpiForWindow($hWnd)
        $ok = [HyperVCapture]::CaptureToFile($hWnd, $OutputPath)
        if ($ok -and (Test-Path $OutputPath)) {
            Copy-Item -Path $OutputPath -Destination (Join-Path $debugDir "printwindow_full.png") -Force
            $imgSize = (Get-Item $OutputPath).Length
            [System.IO.File]::WriteAllText((Join-Path $debugDir "printwindow_debug.txt"),
                "dpi=$dpi fileSize=$imgSize")
            Write-Debug "Screenshot saved (PrintWindow): $OutputPath"
            return $OutputPath
        }
    } catch {
        Write-Warning "PrintWindow screenshot failed: $_"
    }
    Write-Error "Screenshot capture failed for '$VMName'"
    return $null
}

function Get-HyperVWindowScreenshot {
    <#
    .SYNOPSIS
        Captures the vmconnect client area via PrintWindow and returns hWnd
        + dimensions. Used by click-by-OCR -- the WMI thumbnail path from
        Get-HyperVScreenshot does NOT share vmconnect's coord space.
    .OUTPUTS
        Hashtable @{ ImagePath; HWnd; Width; Height } on success, or $null.
    #>
    param([string]$VMName, [string]$OutputPath)
    if (-not ('HyperVCapture' -as [type])) {
        $warmupPath = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna_warmup_${VMName}.png"
        Get-HyperVScreenshot -VMName $VMName -OutputPath $warmupPath | Out-Null
        Remove-Item $warmupPath -Force -ErrorAction SilentlyContinue
    }
    if (-not ('HyperVCapture' -as [type])) {
        Write-Warning "HyperVCapture type failed to load. Click-by-OCR requires the screenshot helpers in host/windows.hyper-v/modules/Yuruna.Host.psm1."
        return $null
    }
    try {
        [HyperVCapture]::EnsureDpiAware()
        $hWnd = [HyperVCapture]::FindWindow($VMName)
        if ($hWnd -eq [IntPtr]::Zero) {
            Write-Warning "vmconnect window not found for '$VMName'. Open a vmconnect session for this VM before using waitForAndClickButton."
            return $null
        }
        $ok = [HyperVCapture]::CaptureToFile($hWnd, $OutputPath)
        if (-not $ok -or -not (Test-Path $OutputPath)) {
            Write-Warning "PrintWindow capture failed for '$VMName'."
            return $null
        }
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $bmp = [System.Drawing.Bitmap]::new($OutputPath)
        try {
            return @{
                ImagePath = $OutputPath
                HWnd      = $hWnd
                Width     = $bmp.Width
                Height    = $bmp.Height
            }
        } finally { $bmp.Dispose() }
    } catch {
        Write-Warning "Get-HyperVWindowScreenshot failed: $_"
        return $null
    }
}

# === VM lifecycle ===========================================================

<#
.SYNOPSIS
    Create a guest VM by running the per-guest New-VM.ps1 script.
#>
function New-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$VMName,
        [string]$CachingProxyUrl
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, "Create VM ($GuestKey)")) { return @{ success = $false; errorMessage = 'WhatIf' } }
    # Run the per-guest New-VM.ps1 as a child process so exit codes are
    # captured cleanly. -CachingProxyUrl is forwarded only when (a) the
    # caller bound it and (b) the target script declares it -- some
    # guests (amazon.linux, windows.11) don't wire a proxy into install.
    $scriptPath = Join-Path $RepoRoot (Join-Path 'host\windows.hyper-v' (Join-Path $GuestKey 'New-VM.ps1'))
    if (-not (Test-Path $scriptPath)) {
        return @{ success = $false; errorMessage = "New-VM.ps1 not found at: $scriptPath" }
    }
    $childArgs = @('-VMName', $VMName)
    $scriptAcceptsProxy = $false
    try {
        $cmdInfo = Get-Command -Name $scriptPath -ErrorAction Stop
        $scriptAcceptsProxy = [bool]($cmdInfo.Parameters -and $cmdInfo.Parameters.ContainsKey('CachingProxyUrl'))
    } catch {
        $scriptAcceptsProxy = $false
    }
    if ($PSBoundParameters.ContainsKey('CachingProxyUrl') -and $scriptAcceptsProxy) {
        $childArgs += @('-CachingProxyUrl', $CachingProxyUrl)
        Write-Verbose "Running: $scriptPath -VMName $VMName -CachingProxyUrl '$CachingProxyUrl'"
    } else {
        Write-Verbose "Running: $scriptPath -VMName $VMName"
    }
    $output = & pwsh -NoProfile -File $scriptPath @childArgs 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        $text = "$line".TrimEnd()
        if ($text -ne '' -and $text -notmatch '^\s*\d+%\s+complete') {
            Write-Information $text
        }
    }
    if ($exitCode -ne 0) {
        return @{ success = $false; errorMessage = "New-VM.ps1 exited with code $exitCode" }
    }
    return @{ success = $true; errorMessage = $null }
}

<#
.SYNOPSIS
    Start a guest VM previously created by New-VM.
#>
function Start-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Start VM')) { return @{ success = $false; errorMessage = 'WhatIf' } }
    return Start-HyperVVM -VMName $VMName -Confirm:$false
}

<#
.SYNOPSIS
    Stop a running guest VM (graceful by default; -Force uses Stop-VMForce).
#>
function Stop-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [switch]$Force
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, ($Force ? 'Force-stop VM' : 'Stop VM'))) { return $false }
    if ($Force) {
        return [bool](Stop-HyperVVMForce -VMName $VMName -Confirm:$false)
    }
    return [bool](Stop-HyperVVM -VMName $VMName -Confirm:$false)
}

<#
.SYNOPSIS
    Force-stop a guest VM, escalating to vmwp.exe kill on Windows when graceful stop hangs.
#>
function Stop-VMForce {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$StopTimeoutSeconds = 20
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Force-stop VM (kill vmwp.exe if needed)')) { return $false }
    return [bool](Stop-HyperVVMForce -VMName $VMName -StopTimeoutSeconds $StopTimeoutSeconds -Confirm:$false)
}

<#
.SYNOPSIS
    Remove a guest VM and its on-disk artifacts.
#>
function Remove-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Remove VM')) { return $false }
    return [bool](Remove-HyperVTestVM -VMName $VMName -Confirm:$false)
}

<#
.SYNOPSIS
    Returns 'absent', 'stopped', 'running', or 'unknown' for the given VM.
#>
function Get-VMState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { return 'absent' }
    switch ($vm.State) {
        'Running'      { return 'running' }
        'Saving'       { return 'running' }
        'Off'          { return 'stopped' }
        'Saved'        { return 'stopped' }
        'OffCritical'  { return 'stopped' }
        default        { return 'unknown' }
    }
}

<#
.SYNOPSIS
    Returns true when a console window is open for the given VM.
#>
function Test-VMConsoleOpen {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    # vmconnect's window title contains the VM name. A best-effort check;
    # the legacy code uses similar logic in Invoke-Sequence.psm1's Send-ClickHyperV.
    $proc = Get-Process -Name 'vmconnect' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -match [regex]::Escape($VMName) } |
        Select-Object -First 1
    return [bool]$proc
}

<#
.SYNOPSIS
    Refresh or re-open the host-side console window for the given VM.
#>
function Restart-VMConsole {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Restart VM console (vmconnect)')) { return $false }
    return [bool](Restart-HyperVConnect -VMName $VMName -Confirm:$false)
}

# === Image ==================================================================

<#
.SYNOPSIS
    Run the per-guest Get-Image.ps1 to download or refresh the base image.
#>
function Get-Image {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Force
    )
    if (-not $PSCmdlet.ShouldProcess($GuestKey, 'Download / refresh base image')) { return @{ success = $false; skipped = $false; errorMessage = 'WhatIf' } }
    $scriptPath = Join-Path $RepoRoot (Join-Path 'host\windows.hyper-v' (Join-Path $GuestKey 'Get-Image.ps1'))
    if (-not (Test-Path $scriptPath)) {
        return @{ success = $false; skipped = $false; errorMessage = "Get-Image.ps1 not found at: $scriptPath" }
    }
    if (-not $Force) {
        $imagePath = Get-ImagePath -GuestKey $GuestKey
        if ($imagePath -and (Test-Path $imagePath)) {
            Write-GetImageLine "Image exists, skipping download: $imagePath"
            return @{ success = $true; skipped = $true; errorMessage = $null }
        }
    }
    Write-GetImageLine "Running: $scriptPath"
    & pwsh -NoProfile -File $scriptPath 2>&1 | ForEach-Object {
        Write-GetImageLine ([string]$_)
    }
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        return @{ success = $false; skipped = $false; errorMessage = "Get-Image.ps1 exited with code $code" }
    }
    return @{ success = $true; skipped = $false; errorMessage = $null }
}

<#
.SYNOPSIS
    Return the expected on-disk path of the base image for a guest.
#>
function Get-ImagePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$GuestKey)
    $fileNames = @{
        'guest.amazon.linux'    = 'host.windows.hyper-v.guest.amazon.linux.vhdx'
        'guest.ubuntu.server'   = 'host.windows.hyper-v.guest.ubuntu.server.iso'
        'guest.windows.11'      = 'host.windows.hyper-v.guest.windows.11.iso'
    }
    $fileName = $fileNames[$GuestKey]
    if (-not $fileName) { return $null }
    try {
        $vhdPath = (Hyper-V\Get-VMHost -ErrorAction Stop).VirtualHardDiskPath
        return Join-Path $vhdPath $fileName
    } catch { return $null }
}

# Helper for Get-Image: emits a line to the console AND -- if active -- to
# the cycle's HTML log via $global:__YurunaLogFile. Bypasses the function
# output pipeline so a `$r = Get-Image ...` capture doesn't accidentally
# swallow the diagnostic stream alongside the return hashtable.
<#
.SYNOPSIS
    Write-GetImageLine.
#>
function Write-GetImageLine {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'global:__YurunaLogFile is the per-cycle HTML log handle, set/cleared by the runner; intentionally process-wide.')]
    [CmdletBinding()]
    param([string]$Line)
    Microsoft.PowerShell.Utility\Write-Host $Line
    if ($global:__YurunaLogFile) {
        [System.Net.WebUtility]::HtmlEncode($Line) |
            Microsoft.PowerShell.Utility\Out-File -FilePath $global:__YurunaLogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue
    }
}

# === VM I/O =================================================================
# Send-Text / Send-Key / Send-Click / Get-VMScreenshot delegate to the
# extension module (test/extensions/Invoke-Sequence.psm1) which the
# runner already imports. Yuruna.Host's facade shape lets callers move
# off direct `Send-TextHyperV` calls and onto the contract.

<#
.SYNOPSIS
    Type text into the guest VM via gui or ssh mechanism.
#>
function Send-Text {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('gui','ssh')][string]$Mechanism = 'gui',
        # Required when -Mechanism ssh: maps to the SSH login user via
        # Test.Ssh\Get-GuestSshUser (per-guest test user, ec2-user, root, ...).
        [string]$GuestKey,
        [int]$CharDelayMs = 30,
        [switch]$Sensitive
    )
    # Sensitive is part of the contract for log redaction; the underlying
    # Invoke-Sequence dispatcher gains it once bodies are lifted out.
    if ($Sensitive) { Write-Debug "Send-Text: -Sensitive set on '$VMName'; log redaction not yet implemented on Hyper-V." }
    if ($Mechanism -eq 'ssh') {
        if (-not $GuestKey) {
            Write-Warning "Send-Text -Mechanism ssh requires -GuestKey to determine the SSH login user."
            return $false
        }
        $r = Invoke-GuestSsh -VMName $VMName -GuestKey $GuestKey -Command $Text
        return [bool]$r.success
    }
    # GUI: defer to Invoke-Sequence's host-aware dispatcher (same pattern
    # as KVM and macOS). Send-TextHyperV is a private helper inside that
    # module; calling it directly from here fails under module scoping
    # because Yuruna.Host's body cannot see another module's private
    # functions even when both are loaded -Global. Going through the
    # exported Invoke-Sequence\Send-Text avoids the visibility trap.
    $invokeSequence = Join-Path $script:TestModulesDir 'Invoke-Sequence.psm1'
    if (Test-Path $invokeSequence) {
        Import-Module $invokeSequence -Force -DisableNameChecking
        return [bool](Invoke-Sequence\Send-Text -HostType $script:HostTag -VMName $VMName -Text $Text -CharDelayMs $CharDelayMs)
    }
    Write-Warning "Send-Text -Mechanism gui: Invoke-Sequence.psm1 not found at '$invokeSequence'."
    return $false
}

<#
.SYNOPSIS
    Send a named key to the guest VM via gui or ssh mechanism.
#>
function Send-Key {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Key,
        [ValidateSet('gui','ssh')][string]$Mechanism = 'gui'
    )
    if ($Mechanism -eq 'ssh') {
        Write-Warning "Send-Key -Mechanism ssh: not meaningful for SSH (use Send-Text with the typed command)."
        return $false
    }
    # Defer to Invoke-Sequence's host-aware dispatcher (same reasoning as
    # Send-Text above -- Send-KeyHyperV is private to Invoke-Sequence and
    # not resolvable from this module's scope).
    $invokeSequence = Join-Path $script:TestModulesDir 'Invoke-Sequence.psm1'
    if (Test-Path $invokeSequence) {
        Import-Module $invokeSequence -Force -DisableNameChecking
        return [bool](Invoke-Sequence\Send-Key -HostType $script:HostTag -VMName $VMName -KeyName $Key)
    }
    Write-Warning "Send-Key -Mechanism gui: Invoke-Sequence.psm1 not found at '$invokeSequence'."
    return $false
}

<#
.SYNOPSIS
    Send a mouse click at the given pixel coordinate.
#>
function Send-Click {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y
    )
    $invokeSequence = Join-Path $script:TestModulesDir 'Invoke-Sequence.psm1'
    if (Test-Path $invokeSequence) {
        Import-Module $invokeSequence -Force -DisableNameChecking
        return [bool](Invoke-Sequence\Send-Click -HostType $script:HostTag -VMName $VMName -X $X -Y $Y)
    }
    Write-Warning "Send-Click: Invoke-Sequence.psm1 not found at '$invokeSequence'."
    return $false
}

<#
.SYNOPSIS
    Capture a PNG of the VM display from frame or window source.
#>
function Get-VMScreenshot {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [ValidateSet('frame','window')][string]$Source = 'frame',
        [string]$OutFile
    )
    if (-not $OutFile) {
        $tmp = [System.IO.Path]::GetTempFileName()
        $OutFile = [System.IO.Path]::ChangeExtension($tmp, '.png')
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
    if ($Source -eq 'window') {
        return Get-HyperVWindowScreenshot -VMName $VMName -OutputPath $OutFile
    }
    # 'frame' source: WMI Msvm_VideoHead / vmconnect bitmap path.
    return Get-HyperVScreenshot -VMName $VMName -OutputPath $OutFile
}

<#
.SYNOPSIS
    Return a host-specific handle for the VM console window.
#>
function Get-VMConsoleHandle {
    [CmdletBinding()]
    [OutputType([System.IntPtr])]
    param([Parameter(Mandatory)][string]$VMName)
    $proc = Get-Process -Name 'vmconnect' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -match [regex]::Escape($VMName) } |
        Select-Object -First 1
    if (-not $proc) { return [System.IntPtr]::Zero }
    return $proc.MainWindowHandle
}

# === Discovery ==============================================================

<#
.SYNOPSIS
    Poll Get-VMIp until an IPv4 address is discovered or timeout expires.
#>
function Wait-VMIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds = 30,
        [int]$PollSeconds    = 3
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $candidate = Get-VMIp -VMName $VMName
        if ($candidate) { return [string]$candidate }
        Start-Sleep -Seconds $PollSeconds
    }
    return $null
}

<#
.SYNOPSIS
    Return the guest's host-side IPv4, or null if not yet discoverable.
#>
function Get-VMIp {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    # Two-stage lookup. KVP is the primary source of truth, but on the
    # External vSwitch path hv_kvp_daemon can take 5-15 min to publish
    # (memory note: hyperv_external_vswitch_arp_discovery), so we ALSO
    # consult the host's ARP/neighbor cache filtered by the VM's MAC.
    # The MAC filter is sufficient -- only this VM can populate ARP
    # cache entries for its own MAC. Active probing (the slow part)
    # lives in Invoke-YurunaExternalArpProbe; that is called by
    # consumers that need fresh data (Save-GuestDiagnostic) and by
    # the squid-cache discovery path. This Get-VMIp is the cheap
    # lookup -- safe to call from polling loops.
    try {
        $vmAdapter = Hyper-V\Get-VMNetworkAdapter -VMName $VMName -ErrorAction Stop
        $addrs = $vmAdapter.IPAddresses
        # Prefer IPv4 (downstream Add-PortMap uses netsh portproxy v4tov4),
        # but fall back to a routable IPv6 if no v4 is available so v6-only
        # guests don't return $null. Loopback/link-local excluded.
        $ipv4 = $addrs | Where-Object { (Test-Ipv4Address $_) -and ($_ -notmatch '^(127\.|169\.254\.)') } | Select-Object -First 1
        if ($ipv4) { return [string]$ipv4 }

        # KVP empty -- try the host's ARP cache for an entry matching
        # this VM's MAC. Format-conversion mirrors Get-CacheVmCandidateIp
        # (KVP MAC is bare hex; Get-NetNeighbor returns dash-separated).
        $vmMac = ($vmAdapter | Select-Object -First 1).MacAddress
        if ($vmMac -match '^[0-9A-Fa-f]{12}$' -and $vmMac -ne '000000000000') {
            $vmMacDashed = (($vmMac -replace '(..)(?!$)', '$1-')).ToUpper()
            $arpIp = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.LinkLayerAddress -eq $vmMacDashed -and
                    (Test-Ipv4Address $_.IPAddress) -and
                    $_.State -ne 'Unreachable' -and
                    $_.IPAddress -notmatch '^(127\.|169\.254\.)'
                } |
                Select-Object -First 1 |
                ForEach-Object { $_.IPAddress }
            if ($arpIp) { return [string]$arpIp }
        }

        $ipv6 = $addrs | Where-Object { (Test-Ipv6Address $_) -and ($_ -inotmatch '^(::1$|fe80:)') } | Select-Object -First 1
        if ($ipv6) { return [string]$ipv6 }
    } catch {
        Write-Debug "Get-VMIp: Get-VMNetworkAdapter failed for ${VMName}: $_"
    }
    return $null
}

<#
.SYNOPSIS
    Return the guest's MAC address, or null if not available.
#>
function Get-VMMac {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { return $null }
    $mac = ($vm | Hyper-V\Get-VMNetworkAdapter | Select-Object -First 1).MacAddress
    if ($mac -match '^[0-9A-Fa-f]{12}$') {
        return ($mac -replace '(.{2})(?!$)', '$1:').ToUpper()
    }
    return $mac
}

# === Networking =============================================================

<#
.SYNOPSIS
    Return the name of the host-side External-type vSwitch or network.
#>
function Get-ExternalNetwork {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Don't create -- just discover. Get-OrCreateYurunaExternalSwitch's
    # internal logic checks "preferred name" then "any External vSwitch"
    # before creation; we emulate the no-create variant here by passing
    # -WhatIf, which skips ShouldProcess and returns $null on the create
    # branch.
    return Get-OrCreateYurunaExternalSwitch -WhatIf 2>$null
}

<#
.SYNOPSIS
    Create the host-side External-type vSwitch or network if missing.
#>
function New-ExternalNetwork {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param()
    if (-not $PSCmdlet.ShouldProcess('Yuruna-External', 'Create External vSwitch on default-route NIC')) { return $null }
    return Get-OrCreateYurunaExternalSwitch
}

<#
.SYNOPSIS
    Returns true if the squid-cache VM is on an External-type network.
#>
function Test-CacheVMOnExternalNetwork {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VMName = 'yuruna-caching-proxy')
    return [bool](Test-CacheVmOnYurunaExternalSwitch -VMName $VMName)
}

<#
.SYNOPSIS
    Install host to VM port forwarders for the caching proxy.
#>
function Add-PortMap {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMIp,
        [int[]]$Port = @(3000),
        [hashtable]$PortRemap = @{},
        [int[]]$ProxyProtocolPort = @(),
        [string]$TrackDir
    )
    if (-not $PSCmdlet.ShouldProcess($VMIp, "Install netsh portproxy + pwsh forwarders for ports $($Port -join ',')")) { return $false }
    if (-not (Test-Ipv4Address $VMIp)) {
        # Hyper-V Add-PortMap uses netsh portproxy v4tov4. v6 inputs (which
        # Test-IpAddress accepts elsewhere as operator-facing values) are
        # rejected here because the underlying mechanism is v4-only.
        Write-Warning "Add-PortMap: VMIp '$VMIp' is not a valid IPv4 address (netsh portproxy v4tov4 cannot bridge IPv6 destinations) -- skipping."
        return $false
    }
    if (-not (Test-IsAdministrator)) {
        Write-Warning "Add-PortMap: admin privilege required (netsh portproxy + New-NetFirewallRule both need elevation). Skipping."
        return $false
    }
    $proxyProtoSet = @{}
    foreach ($p in $ProxyProtocolPort) { $proxyProtoSet[[int]$p] = $true }
    $remapHostPorts = @{}
    foreach ($k in $PortRemap.Keys) { $remapHostPorts[[int]$k] = [int]$PortRemap[$k] }
    $mappings = @()
    foreach ($p in $Port) {
        if ($remapHostPorts.ContainsKey([int]$p)) { continue }
        $mappings += [PSCustomObject]@{ HostPort = [int]$p; VMPort = [int]$p }
    }
    foreach ($k in $remapHostPorts.Keys) {
        $mappings += [PSCustomObject]@{ HostPort = [int]$k; VMPort = [int]$remapHostPorts[$k] }
    }
    $statePath = Get-PortMapStatePath -TrackDir $TrackDir
    # Tear down every prior Yuruna mapping (state-file ports + firewall-
    # rule ports + live forwarder pidfiles) before adding the new set.
    [void](Clear-AllCachingProxyPortMapping -StatePath $statePath -Confirm:$false)
    foreach ($m in $mappings) {
        $hostPort = $m.HostPort; $vmPort = $m.VMPort
        $useProxy = $proxyProtoSet.ContainsKey([int]$hostPort)
        $proxyTag = if ($useProxy) { ' [PROXY v1]' } else { '' }
        if (-not $PSCmdlet.ShouldProcess("host:${hostPort} -> ${VMIp}:${vmPort}${proxyTag}", 'Add port mapping')) { continue }
        $desc = "Yuruna caching proxy: forward host :${hostPort} to VM :${vmPort}${proxyTag}"
        & netsh interface portproxy delete v4tov4 listenport=$hostPort listenaddress=0.0.0.0 2>&1 | Out-Null
        Stop-WindowsCachingProxyForwarder -Port $hostPort -Quiet
        Add-CachingProxyFirewallRule -Port $hostPort -Description $desc -IncludeProgram:$useProxy -Confirm:$false
        if ($useProxy) {
            $spawn = Start-WindowsCachingProxyForwarder -CacheIp $VMIp -Port $hostPort -VMPort $vmPort -PrependProxyV1
            if (-not $spawn.Success) {
                Write-Warning "Add-PortMap: pwsh forwarder failed for host ${hostPort} -> ${VMIp}:${vmPort} (PROXY v1)."
                continue
            }
            # Self-heal the per-program rule if Get-PwshExePath's pre-spawn
            # guess didn't match the binary the OS actually loaded (Microsoft
            # Store App Execution Alias trap).
            if ($spawn.PwshPath) {
                $existingProgramPath = $null
                try {
                    $existingProgramPath = (Get-NetFirewallRule -DisplayName "Yuruna-CachingProxy-Pwsh-${hostPort}" -ErrorAction Stop |
                                            Get-NetFirewallApplicationFilter -ErrorAction Stop).Program
                } catch { $null = $_ }
                if ($existingProgramPath -ne $spawn.PwshPath) {
                    if ($existingProgramPath) {
                        Write-Information "  Pwsh path resolved to '$($spawn.PwshPath)' (rule had '$existingProgramPath') -- rewriting per-program firewall rule."
                    } else {
                        Write-Information "  Installing per-program firewall rule with resolved pwsh path '$($spawn.PwshPath)'."
                    }
                    Add-CachingProxyFirewallRule -Port $hostPort -Description $desc -IncludeProgram -ProgramPath $spawn.PwshPath -Confirm:$false
                }
            }
        } else {
            & netsh interface portproxy add v4tov4 listenport=$hostPort listenaddress=0.0.0.0 connectport=$vmPort connectaddress=$VMIp | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Add-PortMap: netsh portproxy add failed for host ${hostPort} -> ${VMIp}:${vmPort} (exit $LASTEXITCODE)."
                continue
            }
        }
        Write-Information "  Port map added: host:${hostPort} -> ${VMIp}:${vmPort}${proxyTag}"
    }
    $state = [ordered]@{
        vmIp      = $VMIp
        ports     = @($mappings | ForEach-Object { $_.HostPort })
        mappings  = @($mappings | ForEach-Object {
            [ordered]@{
                hostPort      = $_.HostPort
                vmPort        = $_.VMPort
                proxyProtocol = $proxyProtoSet.ContainsKey([int]$_.HostPort)
            }
        })
        createdAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    $tmp = "$statePath.tmp"
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Path $tmp -Destination $statePath -Force
    return $true
}

<#
.SYNOPSIS
    Tear down all yuruna caching-proxy port forwarders.
#>
function Remove-PortMap {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string]$TrackDir)
    if (-not $PSCmdlet.ShouldProcess('netsh portproxy mappings + pwsh forwarders', 'Clear all yuruna port mappings')) { return $false }
    if (-not (Test-IsAdministrator)) {
        $pendingPorts = Get-YurunaMappedPortFromFirewall
        if ($pendingPorts.Count -gt 0) {
            Write-Warning "Remove-PortMap: admin privilege required to remove portproxy/firewall rules for ports: $($pendingPorts -join ', '). State left in place for a later elevated run."
        }
        return $false
    }
    $statePath = Get-PortMapStatePath -TrackDir $TrackDir
    $cleared = @(Clear-AllCachingProxyPortMapping -StatePath $statePath -Confirm:$false)
    foreach ($p in $cleared) {
        Write-Information "  Port map removed: host:${p}"
    }
    return ($cleared.Count -gt 0)
}

<#
.SYNOPSIS
    Return the host's best LAN-routable IPv4 for browser-facing URLs.
#>
function Get-BestHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Filter loopback / link-local / Hyper-V vEthernet, then rank by:
    # 1. Has default route (penalty 0 vs 1000), 2. InterfaceMetric.
    $ranked = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.PrefixOrigin -ne 'WellKnown' -and
        $_.InterfaceAlias -notmatch 'vEthernet|Pseudo'
    } | ForEach-Object {
        $ifaceIndex = $_.InterfaceIndex
        $interface  = Get-NetIPInterface -InterfaceIndex $ifaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $hasGateway = [bool](Get-NetRoute -InterfaceIndex $ifaceIndex -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue)
        [PSCustomObject]@{
            IPAddress     = $_.IPAddress
            InterfaceName = $_.InterfaceAlias
            Metric        = $interface.InterfaceMetric
            HasGateway    = $hasGateway
            Priority      = ($hasGateway ? 0 : 1000) + [int]($interface.InterfaceMetric)
        }
    } | Sort-Object Priority
    return ($ranked | Select-Object -ExpandProperty IPAddress -First 1)
}

# === Caching proxy ==========================================================

<#
.SYNOPSIS
    Probe and return the squid-cache URL, or null if none is reachable.
.DESCRIPTION
    Discovery is intentionally narrow -- only caches this host owns,
    or a remote cache the operator explicitly named, are returned:
      1. $Env:YURUNA_CACHING_PROXY_IP -- explicit remote cache override.
      2. State file (Read-CachingProxyState).ipAddress -- the cache VM's
         IP written by Start-CachingProxy.ps1 (our own VM).

    No Hyper-V VM enumeration, no KVP/ARP discovery. Get-CacheVmCandidate-
    Ip / Get-WorkingCachingProxyUrl still exist for use by the producer
    (guest.squid-cache/New-VM.ps1) and Start-CachingProxy.ps1 itself
    while the cache VM is being brought up -- they are not part of the
    steady-state discovery path. LAN-wide cache discovery is a separate
    future feature.
#>
function Test-CachingProxyAvailable {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $httpPort = Get-CachingProxyPort -Scheme http
    # External cache override -- $Env:YURUNA_CACHING_PROXY_IP short-circuits
    # local discovery and points at a remote squid. If the remote doesn't
    # answer, return $null (do NOT fall back to local) so misconfiguration
    # surfaces as "no cache" instead of silently flipping target.
    if ($Env:YURUNA_CACHING_PROXY_IP) {
        $externIp = $Env:YURUNA_CACHING_PROXY_IP.Trim()
        if (-not (Test-IpAddress $externIp)) {
            Write-Warning "YURUNA_CACHING_PROXY_IP='$externIp' is not a valid IPv4 or IPv6 address -- ignoring."
            return $null
        }
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $tcp.BeginConnect($externIp, $httpPort, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(1000) -and $tcp.Connected) {
                return "http://$(Format-IpUrlHost $externIp):${httpPort}"
            }
        } catch {
            Write-Verbose "external caching proxy probe to ${externIp}:${httpPort} failed: $($_.Exception.Message)"
        } finally {
            $tcp.Close()
        }
        Write-Warning "YURUNA_CACHING_PROXY_IP=${externIp} set but ${externIp}:${httpPort} did not answer."
        return $null
    }

    # Local cache: probe only the IP we recorded ourselves at the last
    # Start-CachingProxy.ps1. Empty state -> no cache (the explicit
    # contract after Stop-CachingProxy.ps1). State-set-but-unreachable
    # is loud (Write-Warning) because the inner runner's bootstrap
    # detection runs ONCE per cycle -- a silently-failed probe means
    # the whole cycle's guests download direct from the internet, and
    # we want the operator to see "why" alongside the headline
    # "Caching proxy: not detected" line in Invoke-TestRunner output.
    $stateIp = (Read-CachingProxyState).ipAddress
    if (-not $stateIp -or -not (Test-IpAddress $stateIp)) {
        Write-Warning "Test-CachingProxyAvailable: state.ipAddress is empty -- no locally-owned cache. Set `$Env:YURUNA_CACHING_PROXY_IP to point at a remote cache, or run Start-CachingProxy.ps1."
        return $null
    }
    # 1500 ms matches test/Test-CachingProxy.ps1's CLI probe so a
    # cache that answers the standalone smoke test also answers here;
    # the earlier 500 ms left a window where a momentarily busy squid
    # (cold start, big cidata fetch) would miss the runner's single
    # bootstrap probe and silently strand the whole inner cycle.
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $tcp.BeginConnect($stateIp, $httpPort, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne(1500) -and $tcp.Connected) {
            return "http://$(Format-IpUrlHost $stateIp):${httpPort}"
        }
    } catch {
        Write-Verbose "cache probe ${stateIp}:${httpPort} failed: $($_.Exception.Message)"
    } finally {
        $tcp.Close()
    }
    Write-Warning "Test-CachingProxyAvailable: state.ipAddress=${stateIp} did not answer :${httpPort} within 1500 ms; treating cache as unavailable. Verify with 'Test-NetConnection ${stateIp} -Port ${httpPort}'; if it answers, the cache is running and the next runner cycle will pick it up. If not, re-run Start-CachingProxy.ps1 (the VM may have restarted with a new DHCP lease)."
    return $null
}

<#
.SYNOPSIS
    Return the cache VM's real IP for downstream port-forwarder setup.
#>
function Get-CachingProxyVMIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # On Windows the URL Test-CachingProxyAvailable returns already
    # contains the cache VM's real IP, so callers extract it from there.
    # The yuruna-caching-proxy state file is a macOS-specific breadcrumb
    # (the macOS URL contains the VZ gateway, not the VM IP). Returning
    # $null here is correct.
    return $null
}

# === Host config ============================================================

<#
.SYNOPSIS
    Promote a proxy URL to the machine-wide host proxy with backup.
#>
function Set-HostProxy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$ProxyUrl)
    if (-not $PSCmdlet.ShouldProcess('Windows host proxy registry', "Set proxy = $ProxyUrl")) { return $false }
    $parts = ConvertTo-ProxyHostPort -Url $ProxyUrl
    $backupPath = Get-HostProxyBackupPath
    if (-not (Test-Path -LiteralPath $backupPath)) {
        # Idempotent backup: only snapshot BEFORE the first apply, so a
        # repeat Set-HostProxy doesn't overwrite the backup with the
        # squid-promoted state.
        $state = Read-WindowsProxyState
        $state['timestamp']  = (Get-Date).ToUniversalTime().ToString('o')
        $state['promotedTo'] = $parts.Url
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupPath -Encoding UTF8
        Write-Information "  Host proxy: backup written to $backupPath"
    } else {
        Write-Information "  Host proxy: existing backup at $backupPath preserved (still apply)"
    }
    Set-WindowsHostProxy -ProxyParts $parts -Confirm:$false
    Write-Information "  Host proxy: Windows HKCU WinINet + HTTP_PROXY/HTTPS_PROXY/NO_PROXY set to $($parts.Url)"
    return $true
}

<#
.SYNOPSIS
    Restore the host proxy from the saved backup, or disable if none.
#>
function Clear-HostProxy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('Windows host proxy registry', 'Clear proxy (preserves backup)')) { return $false }
    $backupPath = Get-HostProxyBackupPath
    $state = $null
    if (Test-Path -LiteralPath $backupPath) {
        try {
            $state = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json -AsHashtable
        } catch {
            Write-Warning "Host proxy: could not parse backup '$backupPath' ($($_.Exception.Message)). Falling back to disable-only."
            $state = $null
        }
    }
    if ($state) {
        Restore-WindowsHostProxy -State $state
        Write-Information "  Host proxy: Windows proxy state restored from backup"
    } else {
        Disable-WindowsHostProxy
        Write-Information "  Host proxy: Windows proxy disabled (no backup to restore)"
    }
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
    return $true
}

<#
.SYNOPSIS
    Aggressively wipe every host-proxy reference and the backup file.
#>
function Remove-HostProxy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('Windows HKCU WinINet + HKCU\Environment', 'Wipe host proxy state')) { return $false }
    Remove-WindowsHostProxy
    Write-Information "  Host proxy: Windows WinINet (ProxyEnable/Server/Override) and HTTP_PROXY/HTTPS_PROXY/NO_PROXY env vars wiped"
    $backupPath = Get-HostProxyBackupPath
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
    return $true
}

<#
.SYNOPSIS
    Return the path of the host-proxy backup JSON.
#>
function Get-HostProxyBackupPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Test.VM.common.psm1's Get-HostProxyBackupPath is the authoritative
    # implementation -- same path on every host. Module-qualified call
    # avoids re-entering OUR function.
    return Test.VM.common\Get-HostProxyBackupPath
}

<#
.SYNOPSIS
    Returns true if the host hypervisor is installed and ready.
#>
function Assert-Virtualization {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool](Assert-HyperVEnabled)
}

# === SSH server (host-side) =================================================

<#
.SYNOPSIS
    Returns true if the host has a code path for SSH-server lifecycle.
#>
function Test-SshServerSupported {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return $true
}

<#
.SYNOPSIS
    Returns true if the host SSH server is installed.
#>
function Test-SshServerInstalled {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    # sshd service registered == OpenSSH.Server capability installed.
    # Avoids the 30+ s Get-WindowsCapability -Online query.
    return ($null -ne (Get-Service -Name sshd -ErrorAction SilentlyContinue))
}

<#
.SYNOPSIS
    Install the host SSH server (idempotent).
#>
function Install-SshServer {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('OpenSSH Server', 'Install + autostart')) { return $false }
    return [bool](Install-WindowsSshServer)
}

<#
.SYNOPSIS
    Start the host SSH server and set it to autostart.
#>
function Start-SshServer {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('OpenSSH Server', 'Start')) { return $false }
    return [bool](Enable-WindowsSshServer)
}

<#
.SYNOPSIS
    Stop the host SSH server.
#>
function Stop-SshServer {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('OpenSSH Server', 'Stop')) { return $false }
    return [bool](Disable-WindowsSshServer)
}

<#
.SYNOPSIS
    Return 'running', 'stopped', 'not-installed', or 'unsupported'.
#>
function Get-SshServerStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not (Test-SshServerInstalled)) { return 'not-installed' }
    try {
        $svc = Get-Service -Name sshd -ErrorAction Stop
        if ($svc.Status -eq 'Running') { return 'running' }
        return 'stopped'
    } catch { return 'unknown' }
}

# === Exports ================================================================

Export-ModuleMember -Function `
    New-VM, Start-VM, Stop-VM, Stop-VMForce, Remove-VM, Get-VMState, `
    Test-VMConsoleOpen, Restart-VMConsole, `
    Get-Image, Get-ImagePath, `
    Send-Text, Send-Key, Send-Click, Get-VMScreenshot, Get-VMConsoleHandle, `
    Wait-VMIp, Get-VMIp, Get-VMMac, `
    Get-ExternalNetwork, New-ExternalNetwork, Test-CacheVMOnExternalNetwork, `
    Add-PortMap, Remove-PortMap, Get-BestHostIp, Get-GuestReachableHostIp, `
    Test-CachingProxyAvailable, Get-CachingProxyVMIp, `
    Set-HostProxy, Clear-HostProxy, Remove-HostProxy, Get-HostProxyBackupPath, Assert-Virtualization, `
    Test-SshServerSupported, Test-SshServerInstalled, Install-SshServer, `
    Start-SshServer, Stop-SshServer, Get-SshServerStatus, `
    `
    CreateIso, Get-CacheVmCandidateIp, `
    Get-OrCreateYurunaExternalSwitch, Test-CachingProxyPort, Invoke-YurunaExternalArpProbe, `
    Test-CacheVmOnYurunaExternalSwitch, Get-WorkingCachingProxyUrl, `
    Test-DownloadAlreadyCurrent, Resolve-CacheHostIp, Get-CacheProxyForHostDownload, `
    Save-CachedHttpUri, Invoke-HttpsViaSquidBump, Assert-HyperVEnabled, `
    Confirm-HyperVVMCreated, Stop-HyperVVMForce, Remove-HyperVTestVM, `
    Start-HyperVVM, Stop-HyperVVM, Confirm-HyperVVMStarted, `
    Resolve-VMConnectAnotherUserDialog, Restart-HyperVConnect, `
    Test-WindowsProxyIsYurunaManaged, Read-WindowsProxyState, Invoke-WinInetRefresh, `
    Set-WindowsHostProxy, Restore-WindowsHostProxy, Disable-WindowsHostProxy, Remove-WindowsHostProxy, `
    Get-CachingProxyForwarderScriptPath, Get-PwshExePath, Get-WindowsForwarderPidPath, `
    Stop-WindowsCachingProxyForwarder, Start-WindowsCachingProxyForwarder, Add-CachingProxyFirewallRule, `
    Get-WindowsForwarderPidPort, Get-YurunaMappedPortFromFirewall, `
    Remove-SinglePortMap, Clear-AllCachingProxyPortMapping, `
    Add-YurunaSshFirewallRule, Remove-YurunaSshFirewallRule, `
    Enable-WindowsSshServer, Disable-WindowsSshServer, Install-WindowsSshServer, `
    Get-HyperVScreenshot, Get-HyperVWindowScreenshot
