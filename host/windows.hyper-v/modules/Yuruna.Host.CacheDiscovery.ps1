<#PSScriptInfo
.VERSION 2026.10.30
.GUID 4220bbab-79ca-404d-a1ce-4cb14b7a89c7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host windows.hyper-v driver cache discovery external switch
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

# --- REGION: Caching-proxy service IP discovery
# See https://yuruna.link/42e5cdfd-0028

function Get-CacheVmCandidateIp {
    <#
    .SYNOPSIS
        Candidate IPv4 addresses for a running Hyper-V VM.
    .DESCRIPTION
        Combines two lookups, dedup, KVP first:
          1. Hyper-V KVP (Get-VMNetworkAdapter.IPAddresses) -- needs
             hv_kvp_daemon inside the guest; empty until hyperv-daemons
             is installed and the daemon running. Once it's up, the
             single source of truth regardless of which vSwitch the VM
             is attached to (Default Switch or External).
          2. ARP-cache fallback for the early-boot window before KVP is
             populated. Filtered by the VM's MAC across ALL host
             interfaces (Default Switch's vEthernet for guests on the
             internal NAT, plus the External-vSwitch vEthernet for the
             caching-proxy-service VM on the External vSwitch). The MAC filter
             is sufficient -- it can only match neighbors of this
             specific VM. Stale 'Permanent' entries across VM
             rebuilds can map one MAC to multiple IPs; all returned so
             the caller's :3128 probe picks the live one.
    .OUTPUTS
        System.String[] -- zero or more IPv4, KVP entries first.
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $VM
    )

    # See https://yuruna.link/42e5cdfd-0028
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

    # --- REGION: https://yuruna.link/42d69dfa-0023
    ($kvpIps + $arpIps) | Select-Object -Unique
}

<#
.SYNOPSIS
    $true when the host's default-route uplink cannot carry a bridged
    guest MAC -- the signal to build guests on NAT instead of a bridge.
.DESCRIPTION
    A Hyper-V External vSwitch L2-bridges the guest's own MAC onto the
    host's physical uplink. Two uplink classes cannot forward frames for
    that guest MAC, so a bridged guest never gets a DHCP lease and boots
    with eth0 DOWN:

      * Wi-Fi (Native 802.11) -- the AP refuses to forward frames for a
        MAC it never authenticated.
      * USB Ethernet adapters (PnP bus 'USB') -- the miniport does not
        support the promiscuous / MAC-spoofing mode Hyper-V bridging
        needs, so the guest MAC never reaches the wire even though the
        host itself uses the adapter normally.

    When either holds the caller must fall back to the Default Switch
    (NAT + DHCP, the equivalent of UTM Shared NAT) and export any service
    via host port-forwarders rather than a bridged LAN IP. This is the
    Windows counterpart of host.macos.utm Test-MacUplinkNotBridgeable,
    but the criteria differ by hypervisor: macOS/vmnet and Linux/KVM
    bridge USB Ethernet fine (it is plain wired Ethernet to them), so
    only Hyper-V's External vSwitch rejects it.

    Resolves the physical NIC behind the default route. With
    -AllowManagementOS the route rides a `vEthernet (<switch>)` virtual
    adapter, so when the default-route adapter is a Hyper-V vEthernet we
    follow the External vSwitch back to its underlying physical NIC and
    test that adapter -- otherwise a Wi-Fi- or USB-backed External switch
    would masquerade as a bridgeable wired NIC and defeat the whole check.
.OUTPUTS
    [bool] -- $false on non-Windows, no default route, or a bridgeable
    (PCI-attached, wired) uplink.
#>
function Get-WindowsDefaultIPv4Route {
    <#
    .SYNOPSIS
        Select the lowest-metric usable default IPv4 route.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()
    return Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' -and $_.NextHop -ne '::' } |
        Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
}

function Get-WindowsDefaultRoutePhysicalAdapter {
    <#
    .SYNOPSIS
        Resolve the default route through an external switch, including team members.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $route = Get-WindowsDefaultIPv4Route
    if (-not $route) { return @() }
    $nic = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
    if (-not $nic) { return @() }
    if ($nic.InterfaceDescription -notmatch 'Hyper-V Virtual Ethernet') { return @($nic) }
    $switch = Get-VMSwitch -ErrorAction SilentlyContinue |
        Where-Object { $_.SwitchType -eq 'External' -and "vEthernet ($($_.Name))" -eq $nic.InterfaceAlias } | Select-Object -First 1
    if (-not $switch) { return @() }
    $descriptions = @(Get-YurunaSwitchUplinkDescription -SwitchRecord $switch)
    return @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $descriptions -contains $_.InterfaceDescription })
}

function Test-WindowsUplinkNotBridgeable {
    <#
    .SYNOPSIS
        Identifies Wi-Fi and USB uplinks behind the default route.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not $IsWindows) { return $false }
    $adapters = @(Get-WindowsDefaultRoutePhysicalAdapter)
    return @($adapters | Where-Object { $_.PhysicalMediaType -eq 'Native 802.11' -or $_.PnPDeviceID -like 'USB\*' }).Count -gt 0
}

# Uplink verdicts a caller may treat as "the bridge is fine". 'unknown' is
# in the list on purpose: the classifier can only ever demote a host to
# NAT, so anything it could not evaluate has to read as OK.
$script:UplinkVerdictOk = @('healthy', 'unknown')

# Get-VMSwitch reports a Switch Embedded Team / LBFO team on the PLURAL
# NetAdapterInterfaceDescriptions, and on such a switch the singular
# property matches no single adapter -- so both are read everywhere a
# switch has to be resolved back to the NIC(s) it bridges, and a match on
# any team member counts.
function Test-YurunaAdapterUp {
    <#
    .SYNOPSIS
        Whether an adapter is operationally up, read from the value rather than
        from the word Windows chose to display.
    .DESCRIPTION
        Get-NetAdapter's Status is a display string, and Windows translates it:
        the same healthy NIC reads 'Up' in English and something else in every
        other install language, so a comparison against 'Up' calls a working
        uplink down on a host whose operator did not install in English.

        ifOperStatus is the IF-MIB value underneath it and is 1 for up in every
        language. It is read by name because a record that does not carry it --
        a management-OS vNIC, or a test double standing in for one -- answers
        $null for a missing property rather than raising, and $null is
        indistinguishable from "down" once it has been compared.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()][object]$Adapter)

    if ($null -eq $Adapter) { return $false }
    foreach ($name in @('ifOperStatus', 'InterfaceOperationalStatus')) {
        $property = $Adapter.PSObject.Properties[$name]
        if ($property -and $null -ne $property.Value) {
            $value = 0
            if ([int]::TryParse([string]$property.Value, [ref]$value)) { return ($value -eq 1) }
        }
    }
    # Nothing numeric to read. The display string is all that is left, and on a
    # non-English host it will not match -- which is why every real adapter path
    # above has to resolve first.
    return ("$($Adapter.Status)" -eq 'Up')
}

function Get-YurunaSwitchUplinkDescription {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowNull()][object]$SwitchRecord)

    if (-not $SwitchRecord) { return [string[]]@() }
    $description = @()
    foreach ($d in (@($SwitchRecord.NetAdapterInterfaceDescriptions) + @($SwitchRecord.NetAdapterInterfaceDescription))) {
        if ("$d".Trim()) { $description += [string]$d }
    }
    return [string[]]@($description | Select-Object -Unique)
}

# $true when $Adapter sits on the same L2 segment a guest bridged to
# $SwitchRecord lands on: either it is the switch's management-OS vNIC
# ('vEthernet (<switch>)'), or it is a NIC the switch itself bridges --
# the -AllowManagementOS:$false topology, where the host keeps its own
# address on the bridged NIC and shares the guest's segment through it.
function Test-YurunaAdapterOnSwitchSegment {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$SwitchRecord,
        [Parameter(Mandatory)][AllowNull()][object]$Adapter,
        [string]$SwitchName
    )

    if (-not $Adapter) { return $false }
    if (-not $SwitchName -and $SwitchRecord) { $SwitchName = [string]$SwitchRecord.Name }
    if ($SwitchName -and ("$($Adapter.InterfaceAlias)" -eq "vEthernet ($SwitchName)")) { return $true }
    $description = @(Get-YurunaSwitchUplinkDescription -SwitchRecord $SwitchRecord)
    if ($description.Count -eq 0) { return $false }
    return ($description -contains [string]$Adapter.InterfaceDescription)
}

# $true when the host's IPv4 default route rides this switch's own
# segment. Used only to rank equally-usable External switches, so every
# unresolvable step answers $false rather than guessing.
function Test-YurunaSwitchOnDefaultRoute {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()][object]$SwitchRecord)

    if (-not $SwitchRecord) { return $false }
    $route = Get-WindowsDefaultIPv4Route
    if (-not $route) { return $false }
    $routeAdapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
    return (Test-YurunaAdapterOnSwitchSegment -SwitchRecord $SwitchRecord -Adapter $routeAdapter)
}

# See https://yuruna.link/4220a755-0021
# --- REGION: Test-YurunaExternalSwitchUplink
function Test-YurunaExternalSwitchUplink {
    <#
    .SYNOPSIS
        One-word verdict on whether an External vSwitch's bridge can still
        carry a guest.

    .DESCRIPTION
        A Hyper-V vSwitch object outlives its uplink binding across a host
        reboot: the switch keeps its name, its SwitchType and the description
        of the NIC it was bridged to, while the host's IP stack sits back on
        the bare physical adapter and nothing forwards frames for a guest MAC.
        The object's survival is therefore not evidence that the bridge works,
        and nothing else in this driver asks the question -- the switch record
        is read for its name and type only, and AllowManagementOS is written
        at creation and never read back.

        Verdicts, first match wins:
          'not-external'              SwitchType is no longer External.
          'uplink-missing'            the switch names no uplink adapter at all.
          'uplink-down'               every named uplink adapter reports not Up.
          'management-os-detached'    the switch is set to share its NIC with
                                      the management OS, yet Hyper-V reports no
                                      management-OS vNIC on it.
          'management-os-unaddressed' that vNIC exists but holds no usable
                                      IPv4, so a seed built now would carry no
                                      host address the guest could reach.
          'healthy'                   nothing above matched.
          'unknown'                   not evaluable: non-Windows, a probe
                                      cmdlet missing, a throw, no switch
                                      record, or an ambiguous binding.

        Failing open is a hard rule -- every unevaluable probe yields
        'unknown', and callers treat 'unknown' exactly like 'healthy'. A false
        unhealthy verdict demotes a whole host to NAT (its cache VM loses its
        LAN IP, ARP discovery no-ops), which costs far more than missing one
        degraded switch.

        Management-OS presence is resolved from Hyper-V itself
        (Get-VMNetworkAdapter -ManagementOS) rather than by looking for an
        adapter named 'vEthernet (<switch>)': that alias is only a default,
        and Rename-NetAdapter or a disambiguating enumeration suffix breaks
        the shape on a perfectly working bridge.

    .PARAMETER SwitchName
        vSwitch to classify.

    .PARAMETER SwitchRecord
        Test seam, Get-VMSwitch shape. Binding it selects injected mode for
        ALL THREE record parameters together, so a partially-bound call can
        never fall through to live cmdlets on a host with no Hyper-V.

    .PARAMETER AdapterRecord
        Test seam. Adapter records in the Get-NetAdapter shape
        (InterfaceDescription, InterfaceAlias, Status, MacAddress,
        InterfaceIndex), plus the switch's management-OS vNICs in the
        Get-VMNetworkAdapter -ManagementOS shape (IsManagementOs, SwitchName,
        MacAddress) -- live mode reads both and concatenates them here. A
        record counts as a management vNIC when it is flagged IsManagementOs
        or simply carries no InterfaceDescription, so injecting an adapter
        with neither shape reads as "management OS present".

    .PARAMETER HostIpRecord
        Test seam. Host IPv4 records in the Get-NetIPAddress shape
        (IPAddress, InterfaceAlias, InterfaceIndex).

    .OUTPUTS
        [string] exactly one verdict from the closed list above.
    #>
        [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$SwitchName,
        [Parameter()][AllowNull()][object]$SwitchRecord,
        [Parameter()][AllowNull()][object[]]$AdapterRecord,
        [Parameter()][AllowNull()][object[]]$HostIpRecord
    )

    if (-not $PSBoundParameters.ContainsKey('SwitchRecord')) {
        if (-not $IsWindows) { return 'unknown' }
        foreach ($probe in @('Get-VMSwitch', 'Get-NetAdapter', 'Get-VMNetworkAdapter', 'Get-NetIPAddress')) {
            if (-not (Get-Command $probe -ErrorAction SilentlyContinue)) { return 'unknown' }
        }
        try {
            $SwitchRecord  = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue | Select-Object -First 1
            $AdapterRecord = @(Get-NetAdapter -ErrorAction SilentlyContinue) +
                             @(Get-VMNetworkAdapter -ManagementOS -SwitchName $SwitchName -ErrorAction SilentlyContinue)
            $HostIpRecord  = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        } catch {
            Write-Verbose "Uplink classification of '$SwitchName' could not run ($($_.Exception.Message)) -- reporting 'unknown'."
            return 'unknown'
        }
    }

    if (-not $SwitchRecord) { return 'unknown' }
    if ("$($SwitchRecord.SwitchType)" -ne 'External') { return 'not-external' }

    $description = @(Get-YurunaSwitchUplinkDescription -SwitchRecord $SwitchRecord)
    if ($description.Count -eq 0) { return 'uplink-missing' }

    $adapter = @($AdapterRecord | Where-Object { $null -ne $_ })
    $bound = @($adapter | Where-Object { $_.InterfaceDescription -and ($description -contains [string]$_.InterfaceDescription) })
    # A named binding that resolves to no adapter is ambiguous rather than
    # broken -- a team member list, a driver-supplied description change or
    # an enumeration in flight all land here -- so it fails open.
    if ($bound.Count -eq 0) { return 'unknown' }
    if (@($bound | Where-Object { Test-YurunaAdapterUp -Adapter $_ }).Count -eq 0) { return 'uplink-down' }

    # A switch deliberately created without -AllowManagementOS has no
    # management vNIC by design; the host keeps its address on the bridged
    # NIC and the bridge is fine.
    if ($SwitchRecord.AllowManagementOS -ne $true) { return 'healthy' }

    # See https://yuruna.link/42e220c4-0004
    $management = @($adapter | Where-Object {
        (($_.IsManagementOs -eq $true) -or ($null -eq $_.InterfaceDescription)) -and
        ((-not $_.SwitchName) -or ("$($_.SwitchName)" -eq $SwitchName))
    })
    if ($management.Count -eq 0) { return 'management-os-detached' }

    # Match the management vNIC by MAC, then alias; ambiguous matches stay unresolved.
    # See https://yuruna.link/42e220c4-0004
    $hostNic = $null
    foreach ($vnic in $management) {
        $mac = ("$($vnic.MacAddress)" -replace '[^0-9A-Fa-f]', '')
        if (-not $mac) { continue }
        $candidate = @($adapter | Where-Object {
            $_.MacAddress -and (("$($_.MacAddress)" -replace '[^0-9A-Fa-f]', '') -eq $mac) -and
            ("$($_.InterfaceDescription)" -match 'Hyper-V Virtual Ethernet')
        })
        if ($candidate.Count -gt 1) {
            $alias = @("vEthernet ($SwitchName)")
            if ($vnic.Name) { $alias += "vEthernet ($($vnic.Name))" }
            $candidate = @($candidate | Where-Object { $alias -contains "$($_.InterfaceAlias)" })
        }
        if ($candidate.Count -eq 1) { $hostNic = $candidate[0]; break }
    }
    if (-not $hostNic) {
        $hostNic = @($adapter | Where-Object { "$($_.InterfaceAlias)" -eq "vEthernet ($SwitchName)" }) | Select-Object -First 1
    }
    if (-not $hostNic) { return 'unknown' }

    $isUsable = { param($Address) $Address -and ($Address -notmatch '^(127\.|169\.254\.)') }
    $address = @($HostIpRecord | Where-Object {
        $null -ne $_ -and (& $isUsable $_.IPAddress) -and (
            (($null -ne $_.InterfaceIndex) -and ($null -ne $hostNic.InterfaceIndex) -and
                ("$($_.InterfaceIndex)" -eq "$($hostNic.InterfaceIndex)")) -or
            ($_.InterfaceAlias -and ("$($_.InterfaceAlias)" -eq "$($hostNic.InterfaceAlias)"))
        )
    })
    if ($address.Count -eq 0) { return 'management-os-unaddressed' }

    return 'healthy'
}

# $true only when Hyper-V positively reports that the switch has no
# management-OS vNIC. Every unresolvable case answers $false: an unknown
# state must keep a caller polling, never cut its wait short.
function Test-YurunaManagementVnicAbsent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$SwitchName)

    if (-not (Get-Command Get-VMNetworkAdapter -ErrorAction SilentlyContinue)) { return $false }
    try {
        $vnic = @(Get-VMNetworkAdapter -ManagementOS -SwitchName $SwitchName -ErrorAction Stop)
    } catch {
        return $false
    }
    return ($vnic.Count -eq 0)
}

<#
.SYNOPSIS
    Poll until the host holds an IPv4 a guest bridged onto $SwitchName
    can reach it at, or the timeout expires.

.DESCRIPTION
    Binding a physical NIC to an External vSwitch tears the host's own
    IP stack off that NIC and re-attaches it to `vEthernet (<switch>)`,
    which then has to re-DHCP. For several seconds in the middle the
    host holds NO default IPv4 route and no LAN address on either
    adapter. A single-shot lookup inside that window reads as "this
    host is not on a LAN", and whatever the caller substitutes for the
    missing answer gets baked into a guest seed that cannot be changed
    afterwards -- so wait the window out instead of answering from it.

    Two sources, in order of precision:
      1. the IPv4 on `vEthernet (<switch>)` -- by construction an
         address on the very segment a bridged guest lands on;
      2. the IPv4 on the default-route interface, but ONLY when that
         interface is on the switch's own segment: either the switch's
         management vNIC, or a NIC the switch bridges (the
         -AllowManagementOS:$false topology, where the host keeps its
         address on the bridged NIC). A default-route address on any
         other adapter belongs to a segment the bridged guest holds no
         route to, which is not a degraded answer but a wrong one -- and
         it is wrong in a way the guest can only discover after the seed
         carrying it has been burned.
    APIPA (169.254/16) and loopback are rejected: an adapter sitting at
    APIPA has not been answered by DHCP yet, so it is still mid-bind.

    Waiting only helps while an address is still arriving. When Hyper-V
    reports that the switch has no management vNIC at all, source 1 can
    never produce an answer, so the poll is abandoned within one interval
    instead of spending the whole budget on an adapter that cannot appear.

.PARAMETER SwitchName
    External vSwitch the guest will attach to. Used to look up
    `vEthernet (<SwitchName>)`; when empty only the default route is
    consulted.

.PARAMETER TimeoutSeconds
    How long to keep polling before giving up.

.PARAMETER PollSeconds
    Delay between attempts.

.OUTPUTS
    [string] IPv4 address, or $null if the host never regained one.
#>
function Wait-ExternalSwitchHostIpv4 {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$SwitchName,
        [int]$TimeoutSeconds = 60,
        [int]$PollSeconds = 2
    )

    $isUsable = { param($Address) $Address -and ($Address -notmatch '^(127\.|169\.254\.)') }

    $switchRecord = $null
    if ($SwitchName) {
        $switchRecord = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $pass = 0
    while ($true) {
        $pass++
        if ($SwitchName) {
            $switchIp = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "vEthernet ($SwitchName)" -ErrorAction SilentlyContinue |
                Where-Object { & $isUsable $_.IPAddress } |
                Select-Object -First 1
            if ($switchIp) { return [string]$switchIp.IPAddress }
        }

        $offSegment = $null
        $route = Get-WindowsDefaultIPv4Route
        if ($route) {
            $routeAdapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
            # No -SwitchName is the legacy no-arg contract (any host IPv4
            # will do), and a route whose adapter cannot be resolved is not
            # evidence of a foreign segment -- both stay accepted.
            $qualified = (-not $SwitchName) -or (-not $routeAdapter) -or
                (Test-YurunaAdapterOnSwitchSegment -SwitchRecord $switchRecord -Adapter $routeAdapter -SwitchName $SwitchName)
            if ($qualified) {
                $routeIp = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue |
                    Where-Object { & $isUsable $_.IPAddress } |
                    Select-Object -First 1
                if ($routeIp) { return [string]$routeIp.IPAddress }
            } else {
                $offSegment = " (default route rides '$($routeAdapter.InterfaceAlias)', which is neither 'vEthernet ($SwitchName)' nor a NIC '$SwitchName' bridges, so its address is on a segment the guest cannot route to)"
            }
        }

        if ((Get-Date) -ge $deadline) { return $null }

        # Re-checked one interval in rather than on the first pass, so a
        # management vNIC that vmms is still materializing right after a
        # bind is not mistaken for one that will never exist.
        if ($pass -ge 2 -and $SwitchName -and (Test-YurunaManagementVnicAbsent -SwitchName $SwitchName)) {
            Write-Verbose "vSwitch '$SwitchName' has no management-OS vNIC, so no address can appear on its segment$offSegment -- reporting no host IPv4 instead of waiting out the timeout."
            return $null
        }

        Write-Verbose "No usable host IPv4 yet (vSwitch bind still settling)$offSegment -- retrying in ${PollSeconds}s."
        Start-Sleep -Seconds $PollSeconds
    }
}

# A confirmed degraded External switch returns $null so guest builders can
# select a validated fallback; latch the diagnosis once per switch and verdict.
# See https://yuruna.link/4220a755-0021
function Resolve-DegradedExternalSwitchFallback {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$SwitchName,
        [Parameter(Mandatory)][string]$Verdict,
        [string]$Detail
    )

    $remedy = switch ($Verdict) {
        'not-external' {
            (Format-YurunaOperatorMessage -Key 'host.operator_710de7288caf79e4' -Arguments @{ switchName = "$SwitchName" })
        }
        'uplink-missing' {
            (Format-YurunaOperatorMessage -Key 'host.operator_8508b39a41d150f0' -Arguments @{ switchName = "$SwitchName" })
        }
        'uplink-down' {
            (Format-YurunaOperatorMessage -Key 'host.operator_7e71105ad8861eb3')
        }
        'management-os-detached' {
            (Format-YurunaOperatorMessage -Key 'host.operator_f6be3a6bb731458d' -Arguments @{ switchName = "$SwitchName" })
        }
        'management-os-unaddressed' {
            (Format-YurunaOperatorMessage -Key 'host.operator_38cd6d99f2d7616b' -Arguments @{ switchName = "$SwitchName" })
        }
        default {
            (Format-YurunaOperatorMessage -Key 'host.operator_dc75df94eaaa9e40' -Arguments @{ switchName = "$SwitchName" })
        }
    }

    $haveDefaultSwitch = [bool](Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue)
    $latchKey = "$SwitchName/$Verdict/$haveDefaultSwitch"
    if ($script:DegradedSwitchLatch -ne $latchKey) {
        $script:DegradedSwitchLatch = $latchKey
        $detailText = if ($Detail) { "; $Detail" } else { '' }
        $consequence = if ($haveDefaultSwitch) {
            'Guests attached to it come up with no carrier, so they are built on the Default Switch instead (NAT + DHCP); LAN-exposed services ride host port-forwarders rather than a bridged LAN IP.'
        } else {
            "Guests attached to it come up with no carrier, and this host has no 'Default Switch', so they are built on whichever vSwitch this host does have (non-External preferred); LAN-exposed services ride host port-forwarders rather than a bridged LAN IP."
        }
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_a4149a26e3a5fd3f' -Arguments @{ switchName = "$SwitchName"; verdict = "$Verdict"; detailText = "$detailText"; consequence = "$consequence"; remedy = "$remedy" })
    }

    return $null
}

function Get-YurunaBridgeableRouteAdapter {
    <#
    .SYNOPSIS
        The PHYSICAL adapter currently carrying the default IPv4 route, when
        Hyper-V could bridge it. $null when there is none worth binding to.
    .DESCRIPTION
        Resolves through a vEthernet: once an External switch exists with a
        management-OS vNIC, the host's default route usually rides
        'vEthernet (<switch>)' rather than the physical NIC underneath it, and
        binding a switch to its own management adapter is not a thing that can
        work. Wi-Fi and USB adapters are excluded for the reason
        Test-WindowsUplinkNotBridgeable exists: Hyper-V cannot carry a bridged
        guest MAC over either, so "repairing" onto one would trade a dead
        bridge for a bridge that is dead in a subtler way.
    .OUTPUTS
        The Get-NetAdapter record, or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()
    if (-not $IsWindows) { return $null }
    return Get-WindowsDefaultRoutePhysicalAdapter | Where-Object {
        $_.PhysicalMediaType -ne 'Native 802.11' -and $_.PnPDeviceID -notlike 'USB\*' -and (Test-YurunaAdapterUp -Adapter $_)
    } | Select-Object -First 1
}

function Test-YurunaSwitchRepairable {
    <#
    .SYNOPSIS
        Split a bad uplink verdict into "stale binding, rebinding fixes it" and
        "the link is genuinely down, rebinding changes nothing".
    .DESCRIPTION
        The distinction is the whole safety argument. 'uplink-down' today means
        only "no bound NIC reports Up", which covers two opposite situations:

          * the switch names an adapter that is down or gone WHILE a different
            bridgeable adapter carries the default route -- a stale binding,
            which a rebind repairs; and
          * the bound adapter IS the one the host routes over and its link is
            down, or nothing bridgeable has a route at all -- a real fault,
            where a rebind accomplishes nothing and still costs the host a
            networking drop.

        Repairing the second class per cycle is how a degraded-but-working host
        becomes an unreachable one, so it is refused here rather than left to a
        guard further down.

        'management-os-unaddressed' is a third class and gets a different, far
        smaller remedy. The bridge itself is intact there -- switch External,
        uplink Up, management vNIC present -- and only the host leg's DHCP
        lease is missing, so rebinding would re-plumb a NIC that has nothing
        wrong with it. A lease renew touches exactly what is absent and leaves
        the binding alone; if it does not answer, the host is no worse off than
        it already was. Note what is still NOT repaired here:
        'management-os-detached' is mechanically fixable by the same cmdlet
        that rebinds, but re-adding a management vNIC is the operation most
        likely to leave the host with no address at all when DHCP does not come
        back, so it stays an operator decision.
    .OUTPUTS
        pscustomobject -- Repairable (bool), Remedy ('rebind' | 'renew-dhcp' |
        'none'), Adapter (record or $null), Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SwitchName,
        [Parameter(Mandatory)][string]$Verdict
    )
    $no = { param($why) [pscustomobject]@{ Repairable = $false; Remedy = 'none'; Adapter = $null; Reason = $why } }
    if ($Verdict -eq 'management-os-unaddressed') {
        return [pscustomobject]@{
            Repairable = $true
            Remedy     = 'renew-dhcp'
            Adapter    = $null
            Reason     = (Format-YurunaOperatorMessage -Key 'host.operator_c57bb9bc8d0199f8' -Arguments @{ switchName = "$SwitchName" })
        }
    }
    if ($Verdict -notin @('uplink-down', 'uplink-missing')) {
        return (& $no "verdict '$Verdict' is not a binding fault")
    }
    $target = Get-YurunaBridgeableRouteAdapter
    if (-not $target) {
        return (& $no 'no bridgeable adapter currently carries the default route, so there is nothing to bind to')
    }
    $existing = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if ($existing) {
        $bound = @(Get-YurunaSwitchUplinkDescription -SwitchRecord $existing)
        if ($bound -contains $target.InterfaceDescription) {
            # Already bound to the adapter that holds the route, and the verdict
            # is still bad: the link itself is the problem. Rebinding to the same
            # NIC would drop host networking to achieve exactly nothing.
            return (& $no "already bound to '$($target.InterfaceDescription)', which holds the route -- the link itself is down")
        }
    }
    return [pscustomobject]@{
        Repairable = $true
        Remedy     = 'rebind'
        Adapter    = $target
        Reason     = (Format-YurunaOperatorMessage -Key 'host.operator_cdbc1c26789f6f1b' -Arguments @{ name = "$($target.Name)" })
    }
}

function Invoke-YurunaManagementVnicDhcpRenew {
    <#
    .SYNOPSIS
        Renew the DHCP lease on a switch's management-OS vNIC. $true only when
        the vNIC ends up holding a usable IPv4.
    .DESCRIPTION
        The bounded remedy for 'management-os-unaddressed'. A renew, not a
        Restart-NetAdapter: restarting re-runs the entire bind -- carrier,
        802.1X, the lot -- on the adapter the host's own leg lives on, which is
        a far bigger hammer than a missing lease deserves and can leave the
        host down if any of those stages stall. RenewDHCPLease asks for exactly
        the thing that is absent, and a host that was unaddressed before a
        failed renew is still only unaddressed after it.

        Declines rather than guesses on a statically-addressed vNIC: there is
        no lease to renew, so an operator set that address and the verdict is
        reporting a configuration, not a fault.
    .OUTPUTS
        [bool] the vNIC holds a usable IPv4 afterwards.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$SwitchName,
        [int]$TimeoutSeconds = 60
    )
    if (-not $IsWindows) { return $false }
    foreach ($probe in @('Get-CimInstance', 'Invoke-CimMethod', 'Get-NetAdapter')) {
        if (-not (Get-Command $probe -ErrorAction SilentlyContinue)) { return $false }
    }

    $alias = "vEthernet ($SwitchName)"
    $nic = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nic) {
        Write-Verbose "No adapter named '$alias' to renew."
        return $false
    }
    $config = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration `
        -Filter "InterfaceIndex=$($nic.InterfaceIndex)" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $config) {
        Write-Verbose "No IP configuration for '$alias' (interface $($nic.InterfaceIndex))."
        return $false
    }
    if ($config.DHCPEnabled -ne $true) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_8ca5971160cae12e' -Arguments @{ alias = "$alias" })
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($alias, (Format-YurunaOperatorMessage -Key 'host.operator_b4ff57c817c9c679'))) { return $false }

    try {
        $result = Invoke-CimMethod -InputObject $config -MethodName 'RenewDHCPLease' -ErrorAction Stop
        if ($result.ReturnValue -ne 0) {
            Write-Verbose "RenewDHCPLease on '$alias' returned $($result.ReturnValue); waiting for the lease anyway in case it lands late."
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4a92938eff3fa2e3' -Arguments @{ alias = "$alias"; message = "$($_.Exception.Message)" })
        return $false
    }

    # The lease arrives asynchronously, so the answer comes from the same
    # poller the create path uses rather than from the method's return value.
    return [bool](Wait-ExternalSwitchHostIpv4 -SwitchName $SwitchName -TimeoutSeconds $TimeoutSeconds)
}

function Test-YurunaRunnerSessionRemote {
    <#
    .SYNOPSIS
        True when THIS process is running inside a remote (RDP) session.
    .DESCRIPTION
        The repair re-plumbs the NIC it is reached over. A runner started from
        an RDP session would sever its own connection mid-rebind and take the
        cycle down with it, so that case declines. An operator merely watching
        from a second session is not detected here on purpose: refusing
        whenever anyone is connected is how a lab host with a forgotten idle
        session quietly never self-repairs.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not $IsWindows) { return $false }
    # SESSIONNAME is 'Console' for the physical/autologin session and
    # 'RDP-Tcp#<n>' for a remote one.
    return ("$env:SESSIONNAME" -like 'RDP-*')
}

function Get-YurunaSwitchRepairStatePath {
    <#
    .SYNOPSIS
        Where the per-host repair attempt counter lives.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $dir = if ($env:YURUNA_RUNTIME_DIR) { $env:YURUNA_RUNTIME_DIR } else { [System.IO.Path]::GetTempPath() }
    return (Join-Path $dir 'hyperv-switch-repair.json')
}

function Repair-YurunaExternalSwitch {
    <#
    .SYNOPSIS
        Repair a degraded External vSwitch with the smallest remedy its verdict
        allows, and return $true only when the switch ends healthy.
    .DESCRIPTION
        Two remedies, chosen by Test-YurunaSwitchRepairable rather than by the
        caller, because they carry very different risk:

          * REBIND (a stale binding) -- move the switch onto the adapter that
            currently carries the default route. Verified against the host's own
            route and rolled back if that route does not come back.
          * RENEW (an unaddressed management vNIC) -- ask DHCP for the host
            leg's missing lease. The binding is already correct there, so
            re-plumbing it would be the wrong tool; nothing needs undoing when
            a renew goes unanswered.

        CALL THIS AT CYCLE START ONLY, before any guest exists. A rebind takes
        carrier away from every guest already on the switch, and it drops host
        networking on the target NIC for a moment -- both are acceptable at a
        cycle boundary and neither is acceptable between two guest builds.

        Set-VMSwitch rather than Remove + New: recreating loses the switch GUID,
        so every VM attached to it needs re-attaching and any static config on
        'vEthernet (<name>)' is gone. The rebind is the smaller hammer for the
        same fault.

        Bounded three ways, because the failure this guards against is a host
        that cannot be reached to fix:
          * only a stale binding is repaired (Test-YurunaSwitchRepairable);
          * a verify-and-roll-back window -- if the host has no default route
            after the rebind, the switch is put back the way it was, so a failed
            repair costs a cycle rather than the machine;
          * an attempt cap, so a permanent fault cannot become a permanent
            re-plumb loop. The counter clears the moment the switch reports
            healthy and ages out after a day, so a replaced cable recovers
            without anyone editing a state file.
    .PARAMETER SwitchName
        External switch to repair. Default: Yuruna-External.
    .PARAMETER MaxAttempts
        Repairs tried before latching to the reported fallback.
    .PARAMETER VerifySeconds
        How long the host is given to get its default route back before the
        repair is judged to have failed and is undone.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [string]$SwitchName    = 'Yuruna-External',
        [int]$MaxAttempts      = 3,
        [int]$VerifySeconds    = 60,
        [int]$ResetAfterHours  = 24
    )
    if (-not $IsWindows) { return $false }

    $verdict = Test-YurunaExternalSwitchUplink -SwitchName $SwitchName
    $statePath = Get-YurunaSwitchRepairStatePath
    $state = $null
    if (Test-Path -LiteralPath $statePath) {
        try { $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -ErrorAction Stop } catch {
            Write-Verbose "switch repair state unreadable ($($_.Exception.Message)); starting a fresh count."
        }
    }
    # Healthy clears the count immediately: whatever was wrong is not wrong now,
    # and the next fault deserves its own full budget rather than the remains of
    # an older one.
    if ($verdict -in $script:UplinkVerdictOk) {
        if ($state) { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue }
        return $true
    }

    $attempts = 0
    $firstUtc = [datetime]::MinValue
    if ($state -and $state.switchName -eq $SwitchName) {
        $attempts = [int]$state.attempts
        $parsedFirstUtc = $false
        if ($state.firstAttemptUtc -is [datetime]) {
            $firstUtc = $state.firstAttemptUtc.ToUniversalTime()
            $parsedFirstUtc = $true
        } elseif ($state.firstAttemptUtc) {
            $parsedFirstUtc = [datetime]::TryParse([string]$state.firstAttemptUtc,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal,
                [ref]$firstUtc)
        }
        if ($parsedFirstUtc) {
            if (((Get-Date).ToUniversalTime() - $firstUtc).TotalHours -ge $ResetAfterHours) {
                Write-Verbose "switch repair budget aged out after $ResetAfterHours h; trying again."
                $attempts = 0
            }
        }
    }
    if ($attempts -ge $MaxAttempts) {
        Write-Verbose "'$SwitchName' repair already tried $attempts time(s) without success; leaving the reported fallback in place."
        return $false
    }

    $r = Test-YurunaSwitchRepairable -SwitchName $SwitchName -Verdict $verdict
    if (-not $r.Repairable) {
        Write-Verbose "'$SwitchName' verdict '$verdict' is not repairable at cycle start: $($r.Reason)"
        return $false
    }
    $renewing = ($r.Remedy -eq 'renew-dhcp')
    # Both remedies act on the adapter the host's own leg lives on, so both can
    # cut a runner that is reached over it, and both need Administrator.
    $action = if ($renewing) { "a DHCP renew on 'vEthernet ($SwitchName)'" } else { "a rebind onto '$($r.Adapter.Name)'" }
    if (Test-YurunaRunnerSessionRemote) {
        $byHand = if ($renewing) { "ipconfig /renew `"vEthernet ($SwitchName)`"" }
                  else { "Set-VMSwitch -Name '$SwitchName' -NetAdapterName '$($r.Adapter.Name)' -AllowManagementOS `$true" }
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_a74a594d6e7c15a4' -Arguments @{ switchName = "$SwitchName"; action = "$action"; byHand = "$byHand" })
        return $false
    }
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_a31c1b64d4b949a8' -Arguments @{ switchName = "$SwitchName"; action = "$action" })
        return $false
    }
    # A rebind pulls carrier from anything already attached. At a cycle boundary
    # there should be nothing; if there is, the cycle is not where we thought it
    # was and re-plumbing under a live guest is not worth the recovery it buys.
    # A renew is exempt: it asks DHCP for the host leg's own lease and never
    # touches the switch's forwarding path, so attached guests do not notice it.
    if (-not $renewing) {
        $live = @(Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' } |
                  Get-VMNetworkAdapter -ErrorAction SilentlyContinue | Where-Object { $_.SwitchName -eq $SwitchName })
        if ($live.Count -gt 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_15a6309222839c03' -Arguments @{ switchName = "$SwitchName"; count = "$($live.Count)" })
            return $false
        }
    }
    # Gated before the attempt counter is written, so a declined or -WhatIf run
    # leaves no state behind and does not spend part of the repair budget.
    $intent = if ($renewing) { "Renew the DHCP lease on 'vEthernet ($SwitchName)'" }
              else { "Rebind External vSwitch to '$($r.Adapter.Name)'" }
    if (-not $PSCmdlet.ShouldProcess($SwitchName, $intent)) { return $false }

    $priorAdapterName = $null
    if (-not $renewing) {
        $existing = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
        $priorDescriptions = if ($existing) { @(Get-YurunaSwitchUplinkDescription -SwitchRecord $existing) } else { @() }
        if ($priorDescriptions.Count -gt 0) {
            $priorAdapterName = (Get-NetAdapter -ErrorAction SilentlyContinue |
                Where-Object { $priorDescriptions -contains $_.InterfaceDescription } |
                Select-Object -First 1).Name
        }
    }

    $attempts++
    $record = [ordered]@{
        switchName      = $SwitchName
        attempts        = $attempts
        firstAttemptUtc = if ($firstUtc -ne [datetime]::MinValue -and $attempts -gt 1) { $firstUtc.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
                          else { [datetime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
        lastVerdict     = $verdict
    }
    try {
        [System.IO.File]::WriteAllText($statePath, ($record | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    } catch { Write-Verbose "switch repair state not written: $($_.Exception.Message)" }

    if ($renewing) {
        # No rollback window here, unlike the rebind below: a renew that does
        # not answer leaves the vNIC exactly as unaddressed as it already was,
        # so there is no prior state worth restoring.
        Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_700059c0fbee589a' -Arguments @{ switchName = "$SwitchName"; attempts = "$attempts"; maxAttempts = "$MaxAttempts"; reason = "$($r.Reason)" }) -InformationAction Continue
        $null = Invoke-YurunaManagementVnicDhcpRenew -SwitchName $SwitchName -TimeoutSeconds $VerifySeconds -Confirm:$false
        $renewVerdict = Test-YurunaExternalSwitchUplink -SwitchName $SwitchName
        if ($renewVerdict -in $script:UplinkVerdictOk) {
            Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
            Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_74adb6c89d5b326d' -Arguments @{ switchName = "$SwitchName" }) -InformationAction Continue
            return $true
        }
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_56774322cef868bc' -Arguments @{ switchName = "$SwitchName"; verifySeconds = "${VerifySeconds}"; renewVerdict = "$renewVerdict" })
        return $false
    }

    Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_0a90ff42da4c208c' -Arguments @{ switchName = "$SwitchName"; name = "$($r.Adapter.Name)"; attempts = "$attempts"; maxAttempts = "$MaxAttempts"; reason = "$($r.Reason)" }) -InformationAction Continue
    try {
        Set-VMSwitch -Name $SwitchName -NetAdapterName $r.Adapter.Name -AllowManagementOS $true -ErrorAction Stop
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_ab1fcde57a7857c8' -Arguments @{ switchName = "$SwitchName"; name = "$($r.Adapter.Name)"; message = "$($_.Exception.Message)" })
        return $false
    }

    # Verify the host still has a way out, and undo if it does not. This window
    # is the difference between self-healing and self-destroying: DHCP on the new
    # management vNIC can take a few seconds, and can also never arrive.
    $deadline = (Get-Date).AddSeconds([Math]::Max(5, $VerifySeconds))
    $routeBack = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -ne '0.0.0.0' }) { $routeBack = $true; break }
    }
    if (-not $routeBack) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_a06c9a13a89841f7' -Arguments @{ switchName = "$SwitchName"; name = "$($r.Adapter.Name)"; verifySeconds = "${VerifySeconds}" })
        try {
            if ($priorAdapterName) {
                Set-VMSwitch -Name $SwitchName -NetAdapterName $priorAdapterName -AllowManagementOS $true -ErrorAction Stop
            } else {
                Remove-VMSwitch -Name $SwitchName -Force -ErrorAction Stop
            }
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_44815e503565a001' -Arguments @{ switchName = "$SwitchName"; message = "$($_.Exception.Message)" })
        }
        return $false
    }

    $after = Test-YurunaExternalSwitchUplink -SwitchName $SwitchName
    if ($after -in $script:UplinkVerdictOk) {
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_da3d2f1f78ad6fd4' -Arguments @{ switchName = "$SwitchName"; name = "$($r.Adapter.Name)" }) -InformationAction Continue
        return $true
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4843e747d7df16f4' -Arguments @{ switchName = "$SwitchName"; name = "$($r.Adapter.Name)"; after = "$after" })
    return $false
}

<#
.SYNOPSIS
    Idempotently create (or return) the Yuruna External vSwitch bridged
    to the host's primary physical NIC.
.DESCRIPTION
    The caching-proxy-service VM rides on this switch (instead of the built-in
    Default Switch) so it gets a real LAN IP via DHCP and is reachable
    by remote LAN clients without any host-side port forwarding. squid
    sees the actual LAN client IP at TCP level -- no PROXY-protocol
    forwarder needed and no Defender per-program filtering layer to
    fight (which is what blocked the user-mode forwarder path on
    Hyper-V hosts; see test/service/Start-CachingProxyServiceVM.ps1 for the long note).

    Picks the NIC carrying the default IPv4 route (the one with actual
    LAN connectivity, by definition). An uplink that can't carry a
    bridged guest MAC is diverted to NAT instead: Wi-Fi APs reject a MAC
    they never authenticated, and USB Ethernet miniports lack the
    promiscuous/MAC-spoofing support bridging needs, so a bridged guest
    fails DHCP and boots with eth0 DOWN. In those cases this returns
    $null (see Test-WindowsUplinkNotBridgeable) so the caller falls back
    to the Default Switch.

    -AllowManagementOS:$true keeps the host's own networking on the
    same physical NIC after the bridge -- without it, creating the
    External vSwitch would strand the host until the operator manually
    re-binds protocols. Brief (~5s) network blip during creation is
    inherent to Hyper-V vSwitch reconfiguration.

    Idempotent: re-runs return the existing switch. Removing it
    requires explicit Remove-VMSwitch (we don't auto-clean -- operators
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

    # Emit only a switch name or $null; diagnostics must stay off the pipeline.
    # See https://yuruna.link/42e220c4-0004

    # --- REGION: https://yuruna.link/4220a755-0020
    # 0. Not-bridgeable-uplink divert: return $null so the caller falls back to the Default Switch (NAT + DHCP).
    if (Test-WindowsUplinkNotBridgeable) {
        Write-Verbose "Host default-route uplink is not bridgeable (Wi-Fi 802.11, or a USB Ethernet adapter) -- Hyper-V can't carry a bridged guest MAC over it, so guests fail DHCP and boot with eth0 DOWN. Using the Default Switch (NAT); LAN export rides host port-forwarders."
        return $null
    }

    # 1. Preferred name (default 'Yuruna-External'): use as-is when its
    # bridge still works. A vSwitch object outlives its uplink binding
    # across a host reboot, so finding the object is not evidence that a
    # guest attached to it would get a carrier.
    $existing = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if ($existing) {
        # No -SwitchRecord: binding any record parameter puts the
        # classifier in fully-injected mode, where it must not reach for
        # the adapter and address facts it needs to say anything but
        # 'unknown'. Live callers pass the name and let it read all of
        # them together.
        $verdict = Test-YurunaExternalSwitchUplink -SwitchName $SwitchName
        if ($verdict -in $script:UplinkVerdictOk) {
            Write-Verbose "Reusing existing vSwitch '$SwitchName' (uplink verdict '$verdict')."
            return $SwitchName
        }
        $uplink  = @(Get-YurunaSwitchUplinkDescription -SwitchRecord $existing) -join ', '
        $detail  = if ($uplink) { "bound NIC: $uplink" } else { 'no bound NIC' }
        $declined = Resolve-DegradedExternalSwitchFallback -SwitchName $SwitchName -Verdict $verdict -Detail $detail
        return $declined
    }

    # See https://yuruna.link/42e5cdfd-0029
    $external = @(Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object { $_.SwitchType -eq 'External' })
    if ($external.Count -gt 0) {
        $candidate = @($external | ForEach-Object {
            [pscustomobject]@{
                Name           = [string]$_.Name
                Verdict        = (Test-YurunaExternalSwitchUplink -SwitchName $_.Name)
                OnDefaultRoute = (Test-YurunaSwitchOnDefaultRoute -SwitchRecord $_)
            }
        })
        # Deterministic pick: the switch carrying the host's own default
        # route is the one whose segment the host is demonstrably on;
        # name order breaks any remaining tie so repeated runs on the
        # same host agree with each other.
        $usable = @($candidate |
            Where-Object { $_.Verdict -in $script:UplinkVerdictOk } |
            Sort-Object -Property @{ Expression = 'OnDefaultRoute'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })
        if ($usable.Count -gt 0) {
            $picked = $usable[0]
            Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_4770215bffdbd75c' -Arguments @{ name = "$($picked.Name)"; switchName = "$SwitchName" })
            return $picked.Name
        }
        $fallback = @($candidate | Sort-Object -Property Name)[0]
        $detail   = (Format-YurunaOperatorMessage -Key 'host.operator_ebb334b20c14e63c' -Arguments @{ join = [string](((@($candidate | ForEach-Object { "'$($_.Name)' -> $($_.Verdict)" })) -join ', ')) })
        $declined = Resolve-DegradedExternalSwitchFallback -SwitchName $fallback.Name -Verdict $fallback.Verdict -Detail $detail
        return $declined
    }

    # 3. No External vSwitch exists -- create one bridged on the NIC
    # carrying the default IPv4 route. Filter routes that are
    # themselves through a vEthernet (Default Switch / Hyper-V internal
    # switches) to avoid feedback if a prior bad bridge state left a
    # vEthernet as default.
    $defaultRoute = Get-WindowsDefaultIPv4Route
    if (-not $defaultRoute) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_56b61ac1fd231932')
        return $null
    }

    $nic = Get-NetAdapter -InterfaceIndex $defaultRoute.InterfaceIndex -ErrorAction SilentlyContinue
    if (-not $nic) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_26843e669bc191ba' -Arguments @{ interfaceIndex = "$($defaultRoute.InterfaceIndex)" })
        return $null
    }

    if (-not (Test-YurunaAdapterUp -Adapter $nic)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_cf17af079799e5c1' -Arguments @{ interfaceAlias = "$($nic.InterfaceAlias)"; status = "$($nic.Status)" })
        return $null
    }

    # A Wi-Fi default route was already diverted to NAT at step 0, so the
    # NIC reached here is wired -- safe to bridge.

    if (-not $PSCmdlet.ShouldProcess($SwitchName, (Format-YurunaOperatorMessage -Key 'host.operator_1cc226961160e63b' -Arguments @{ interfaceAlias = "$($nic.InterfaceAlias)" }))) {
        return $null
    }

    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_f1828451620bc0f7' -Arguments @{ switchName = "$SwitchName"; interfaceAlias = "$($nic.InterfaceAlias)" })
    try {
        New-VMSwitch -Name $SwitchName -NetAdapterName $nic.InterfaceAlias -AllowManagementOS:$true -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_3aa815d3eed4c968' -Arguments @{ message = "$($_.Exception.Message)" })
        return $null
    }

    # Wait for host DHCP before seeding the guest with its reachable host address.
    # See https://yuruna.link/42e220c4-0004
    $settleSeconds = 60
    if (-not (Wait-ExternalSwitchHostIpv4 -SwitchName $SwitchName -TimeoutSeconds $settleSeconds)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_6526c96616af3782' -Arguments @{ switchName = "$SwitchName"; settleSeconds = "${settleSeconds}" })
    }

    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_2eafe07b6f1ae191' -Arguments @{ switchName = "$SwitchName" })
    return $SwitchName
}

<#
.SYNOPSIS
    Populate the host's ARP cache on the Yuruna-External subnet by
    sweep-pinging it in parallel. Cheap fallback for IP discovery when
    the cache VM has DHCP'd a LAN address but hv_kvp_daemon hasn't
    started yet.
.DESCRIPTION
    On the Default Switch path, the host is the NAT/DHCP server so the
    cache VM's MAC<->IP mapping lands in the ARP cache the moment DHCP
    completes. On External vSwitch the LAN's DHCP server (not the host)
    answers, so the host has no reason to ARP for the VM's IP and
    `Get-NetNeighbor` returns nothing -- even though the VM is up,
    has its lease, and is happily installing apt packages. KVP would
    eventually fill this gap, but `hv_kvp_daemon` only starts late in
    cloud-init's runcmd (after grafana / prometheus / loki / squid have
    all installed) -- that's 5-15 minutes of "not discovered yet" while
    the VM is actually fine.

    This active sweep ARP-resolves every IP on the host's
    Yuruna-External subnet (parallel `Test-Connection -Count 1
    -TimeoutSeconds 1`, throttle 64). Responses populate the host's
    neighbor cache; subsequent `Get-NetNeighbor` calls then find the
    cache VM at its DHCP'd IP within seconds of boot, not minutes.

    No-op on non-Windows or when the host has no Yuruna-External
    vEthernet (e.g., Default-Switch fallback path). Only handles /24
    subnets -- the common home/office LAN size; wider subnets fall back
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
        Write-Verbose "Invoke-YurunaExternalArpProbe: host /$($hostIp.PrefixLength) -- skipping sweep (only /24 supported)."
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
        $true if the caching-proxy-service VM is attached to an External-type
        vSwitch whose bridge still has a live uplink (LAN-bridged, has a
        real LAN IP, no host forwarders needed).
    .DESCRIPTION
        Used by the cross-platform test/ scripts to decide whether
        Add-PortMap is needed on Windows. When the cache VM
        is bridged to LAN, remote clients reach it directly at its own
        LAN IP and squid sees real client IPs natively -- netsh portproxy
        adds nothing useful and would only register a redundant alternate
        path that loses source IP through kernel NAT. When the cache VM
        is on Default Switch (or any internal/private switch), netsh
        portproxy is the LAN-reachability mechanism and must run.

        The fast path therefore means bridged AND the bridge has a live
        uplink: a vSwitch object outlives its uplink binding across a host
        reboot, and a cache attached to such a switch holds no LAN address
        at all, so answering $true for it would remove the forwarders that
        are the only remaining way to reach the cache. An uplink the
        classifier cannot evaluate answers $true, keeping the inverse --
        installing forwarders in front of a healthy bridged cache, where
        Add-PortMap replaces the cache's own forwarders and would darken any
        of its ports left off the list -- reachable only on a positive fault.

        Function name retains the historical 'Yuruna' reference for
        call-site stability, but the check is by SwitchType=External --
        operators who pre-create an External vSwitch under a different
        name (e.g., 'External', 'LAN-Bridge') get the same fast path.
    .OUTPUTS
        [bool] -- $false on non-Windows, missing VM, no NIC, a non-External
        switch, or an External switch whose uplink is positively degraded.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VMName = 'yuruna-caching-proxy-service')

    if (-not $IsWindows) { return $false }
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { return $false }
    $switchName = ($vm | Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
        Select-Object -First 1).SwitchName
    if (-not $switchName) { return $false }
    $switch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
    if (-not $switch -or $switch.SwitchType -ne 'External') { return $false }
    $verdict = Test-YurunaExternalSwitchUplink -SwitchName $switchName
    if ($verdict -notin $script:UplinkVerdictOk) {
        Write-Verbose "Cache VM '$VMName' is on External vSwitch '$switchName', but its uplink is '$verdict' -- treating the cache as not LAN-bridged."
    }
    return ($verdict -in $script:UplinkVerdictOk)
}

function Get-WorkingCachingProxyServiceUrl {
    <#
    .SYNOPSIS
        "http://<ip>:3128" of a caching-proxy-service VM that answers on :3128,
        or $null if none of the candidate IPs respond.
    .DESCRIPTION
        One-shot helper for consumers (ubuntu guests) and
        Start-CachingProxyServiceVM.ps1's summary. Does NOT wait for the cache VM
        to boot or for squid to come up -- callers expect the VM already
        running and squid listening. The producer
        (guest.caching-proxy-service/New-VM.ps1) uses Get-CacheVmCandidateIp
        directly because it provisions the cache and must poll while
        cloud-init runs.
    .OUTPUTS
        System.String or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [string]$VMName = "yuruna-caching-proxy-service",
        [int]$ProbeTimeoutMs = 500
    )

    $cacheVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $cacheVM -or $cacheVM.State -ne 'Running') { return $null }

    $httpPort = Get-CachingProxyServicePort -Scheme http
    foreach ($ip in (Get-CacheVmCandidateIp -VM $cacheVM)) {
        if (Test-CachingProxyServicePort -IpAddress $ip -Port $httpPort -TimeoutMs $ProbeTimeoutMs) {
            return "http://$(Format-IpUrlHost $ip):${httpPort}"
        }
    }
    return $null
}

# --- REGION: Resolve-CacheHostIp
function Resolve-CacheHostIp {
    <#
    .SYNOPSIS
        Returns a reachable caching-proxy-service IP, or $null when unavailable.
    .DESCRIPTION
        Honors the explicit remote-cache override before local discovery.
        An unreachable override returns $null rather than using a local cache.
    .OUTPUTS
        [string] Reachable cache IP address, or $null.
    .LINK
        https://yuruna.link/42ec97cd-0018
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$VMName = 'yuruna-caching-proxy-service')
    $httpPort = Get-CachingProxyServicePort -Scheme http
    if ($Env:YURUNA_CACHING_PROXY_SERVICE_IP) {
        $externIp = $Env:YURUNA_CACHING_PROXY_SERVICE_IP.Trim()
        if ((Test-IpAddress $externIp) -and (Test-CachingProxyServicePort -IpAddress $externIp -Port $httpPort -TimeoutMs 500)) {
            return $externIp
        }
        return $null
    }
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm -or $vm.State -ne 'Running') { return $null }
    foreach ($ip in (Get-CacheVmCandidateIp -VM $vm)) {
        if (Test-CachingProxyServicePort -IpAddress $ip -Port $httpPort -TimeoutMs 500) {
            return $ip
        }
    }
    return $null
}

# --- REGION: Save-CachedHttpUri
function Save-CachedHttpUri {
    <#
    .SYNOPSIS
        Downloads $Uri to $OutFile through the cache, with a direct fallback.
    .DESCRIPTION
        Binds this driver's cache discovery to the shared download pipeline.
    .LINK
        https://yuruna.link/42ec97cd-0018
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    Yuruna.HostDownload\Save-CachedHttpUri -Uri $Uri -OutFile $OutFile -ResolveCacheHostIp { Resolve-CacheHostIp }
}

function Assert-HyperVEnabled {
    <#
    .SYNOPSIS
        Returns $true when Hyper-V is enabled AND vmms is running; $false
        with a diagnostic Write-Information otherwise.

    .DESCRIPTION
        Verifies the Hyper-V preconditions every New-VM and tear-down
        script depends on. Bypasses Get-WindowsOptionalFeature: that
        cmdlet dispatches through a COM shim (CompatiblePSEdition proxy
        in pwsh 7) that, on fresh Windows 11 installs or right after
        Enable-WindowsOptionalFeature completes, can fail with "Class
        not registered" (HRESULT 0x80040154) even when Hyper-V is
        enabled and healthy. Seen on the first post-install run of
        Start-CachingProxyServiceVM -> guest.caching-proxy-service/New-VM.ps1. dism.exe is
        the plain Win32 tool the cmdlet wraps; calling it directly
        sidesteps the COM failure (same workaround as
        install/windows.hyper-v.ps1). The call goes through
        Get-HyperVFeatureState, which bounds it: a servicing stack busy
        with an update can leave dism.exe waiting far longer than any
        caller of this check is prepared to.

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

    $featureTimeoutSeconds = 120
    $feature = Get-HyperVFeatureState -TimeoutSeconds $featureTimeoutSeconds
    switch ($feature.Probe) {
        'missing-client' {
            Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_683db69e0f21153d' -Arguments @{ dismExe = "$($feature.Path)" })
            return $false
        }
        'unknown-to-sku' {
            Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_3993337ab1c4f142')
            return $false
        }
        'timeout' {
            Write-Information (Format-YurunaOperatorMessage -Key 'host.hyperv_dism_timed_out' -Arguments @{ seconds = "$featureTimeoutSeconds" })
            return $false
        }
    }
    if ($feature.Probe -notin @('ok', 'invalid-response') -or $feature.ExitCode -ne 0) {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_ea0434e09c4fc728' -Arguments @{ infoExit = "$($feature.ExitCode)" })
        Write-Information ([string]$feature.Output)
        return $false
    }
    if ($feature.State -ne 'Enabled') {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_5956121984632a78' -Arguments @{ state = "$($feature.State)" })
        return $false
    }

    $service = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_32c598c080522dc9')
        return $false
    }
    if ($service.Status -ne 'Running') {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_d7a37d0b142d440c' -Arguments @{ status = "$($service.Status)" })
        return $false
    }

    return $true
}
