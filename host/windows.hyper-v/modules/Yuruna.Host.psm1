<#PSScriptInfo
.VERSION 2026.08.05
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e90
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host windows hyperv
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.RELEASENOTES
    Yuruna host driver for Windows + Hyper-V. Implements the Yuruna.Host
    driver contract defined in host/Yuruna.Host.Contract.psm1 (rationale in docs/host-io.md).
#>

#requires -version 7

<#
.SYNOPSIS
    Yuruna host driver for Windows + Hyper-V.

.DESCRIPTION
    Self-contained host driver: contract surface plus the Hyper-V /
    Windows helpers it consumes. Cross-host helpers live in
    automation/Yuruna.Common.psm1 and test/modules/Test.Ssh.psm1, imported below.

    Module-qualified calls (e.g. `Yuruna.HostDownload\Save-CachedHttpUri`) appear
    where an external helper shares its name with the contract function
    -- without the qualifier the call would re-enter our own definition
    and recurse.
#>

# --- REGION: Module setup

$script:HostTag        = 'host.windows.hyper-v'
$script:RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:TestModulesDir = Join-Path $script:RepoRoot 'test\modules'
$script:HostFolder     = Join-Path $script:RepoRoot 'host\windows.hyper-v'

<#
.SYNOPSIS
    Returns this driver's host tag, repairing it if module state was lost.
.DESCRIPTION
    $script: state does not survive this module being -Force re-imported
    (feedback_module_script_state_reset_by_force_reimport). A caller holding
    an already-resolved reference to a contract function keeps running against
    the evicted instance, whose session state has been torn down, and
    $script:HostTag then reads as an empty string.

    That empty string is load-bearing: binding it to the dispatcher's
    -HostType fails with "Cannot bind argument to parameter 'HostType'
    because it is an empty string", so the keystroke types nothing while the
    caller sees only a non-terminating error and carries on. A console line
    left half-typed that way stays in the tty and the next text sent to the
    guest is appended to it, surfacing much later as a command nobody wrote.

    The tag is a compile-time constant for this driver, so resolving it
    through a literal fallback makes the empty binding impossible regardless
    of module lifetime, and restores the variable for any other reader that
    can still reach this scope.
#>
function Resolve-HostTag {
    [OutputType([string])]
    param()
    if ([string]::IsNullOrWhiteSpace($script:HostTag)) { $script:HostTag = 'host.windows.hyper-v' }
    return $script:HostTag
}

# The supporting test/modules become callable from our function bodies;
# Export-ModuleMember below decides which of OUR functions become visible
# to test/ orchestration. Yuruna.Host.psm1's exports shadow any same-name
# exports the supporting modules also produce.
# These dependency modules are imported -Global: Yuruna.Host is -Force re-imported
# mid-cycle, and a bare -Force import here lands in Yuruna.Host's nested scope and
# EVICTS the global copy other modules call via qualified names (e.g.
# Test.Ssh\Invoke-GuestSsh) -- feedback_module_force_import_evicts_global.
Import-Module (Join-Path $script:RepoRoot 'automation\Yuruna.Common.psm1') -Force -DisableNameChecking -Global
Import-Module (Join-Path $script:TestModulesDir 'Test.Ssh.psm1')          -Force -DisableNameChecking -Global
Import-Module (Join-Path $script:TestModulesDir 'Test.CachingProxyService.psm1') -Force -DisableNameChecking -Global
# Shared squid download / TLS-bump stack -- single source of truth across host drivers.
# The X509 chain-validation callback lives here verbatim; per-driver cache-host
# discovery is injected via the -ResolveCacheHostIp scriptblock (see wrapper below).
Import-Module (Join-Path $script:RepoRoot 'host\modules\Yuruna.HostDownload.psm1') -Force -DisableNameChecking -Global
# Download-agent client. The Get-Image hooks feature-detect its two functions by
# name, so this import is what decides whether the agent path exists at all on
# this host; without it the agent is silently never consulted.
Import-Module (Join-Path $script:RepoRoot 'host\modules\Yuruna.DownloadAgent.psm1') -Force -DisableNameChecking -Global
# Shared per-guest provisioning helpers (the New-VM.ps1 child-runner +
# the Get-Image log-line writer) common to all three drivers.
Import-Module (Join-Path $script:RepoRoot 'host\modules\Yuruna.HostProvision.psm1') -Force -DisableNameChecking -Global
# --- REGION: Hyper-V host helpers

# --- REGION: Define Oscdimg Path (adjust '10' for your ADK version if necessary)
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

    if (-not [System.IO.Path]::IsPathRooted($SourceDir)) {
        $SourceDir = Join-Path $cwd $SourceDir
    }
    $SourceDir = [System.IO.Path]::GetFullPath($SourceDir)

    if (-not (Test-Path -Path $SourceDir)) {
        Throw "SourceDir not found: $SourceDir"
    }

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

# --- REGION: caching-proxy-service IP discovery (shared by producer + consumers)
# Single source of truth for KVP+ARP discovery shared by guest.caching-proxy-service/
# New-VM.ps1, ubuntu.server.24/New-VM.ps1, and test/Start-CachingProxyServiceVM.ps1.
# Guards against the regression class where a KVP-only summary reports
# "(discovery failed)" even though the ARP fallback has already found the
# cache and it is serving -- by routing all three callers through the same
# function.

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

    # --- REGION: https://yuruna.link/memory#why-get-cachevmcandidateip-emits-a-bare-pipeline
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
function Test-WindowsUplinkNotBridgeable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not $IsWindows) { return $false }

    $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' -and $_.NextHop -ne '::' } |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1
    if (-not $route) { return $false }

    $nic = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
    if (-not $nic) { return $false }

    if ($nic.InterfaceDescription -match 'Hyper-V Virtual Ethernet') {
        # Route rides a vEthernet: find the External vSwitch whose
        # management-OS adapter this is ('vEthernet (<name>)'), then test
        # the switch's underlying physical NIC.
        $switch = Get-VMSwitch -ErrorAction SilentlyContinue |
            Where-Object { $_.SwitchType -eq 'External' -and "vEthernet ($($_.Name))" -eq $nic.InterfaceAlias } |
            Select-Object -First 1
        if (-not $switch -or -not $switch.NetAdapterInterfaceDescription) { return $false }
        $phys = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceDescription -eq $switch.NetAdapterInterfaceDescription } |
            Select-Object -First 1
        if (-not $phys) { return $false }
        # Native 802.11 => Wi-Fi; PnPDeviceID 'USB\...' => USB adapter.
        return ($phys.PhysicalMediaType -eq 'Native 802.11' -or $phys.PnPDeviceID -like 'USB\*')
    }

    # Native 802.11 => Wi-Fi; PnPDeviceID 'USB\...' => USB adapter.
    return ($nic.PhysicalMediaType -eq 'Native 802.11' -or $nic.PnPDeviceID -like 'USB\*')
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
    $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' -and $_.NextHop -ne '::' } |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1
    if (-not $route) { return $false }
    $routeAdapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
    return (Test-YurunaAdapterOnSwitchSegment -SwitchRecord $SwitchRecord -Adapter $routeAdapter)
}

# --- REGION: https://yuruna.link/network#why-a-reused-external-vswitch-is-validated-before-it-is-handed-out
# The blank line below is load-bearing. A single-line comment that touches the
# <# #> block gets absorbed into it, and PowerShell then no longer reads the
# block as comment-based help -- Get-Help for this function returns nothing at
# all, silently. Keep any comment here separated from the block by a blank line.

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
function Test-YurunaExternalSwitchUplink {
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
    if (@($bound | Where-Object { "$($_.Status)" -eq 'Up' }).Count -eq 0) { return 'uplink-down' }

    # A switch deliberately created without -AllowManagementOS has no
    # management vNIC by design; the host keeps its address on the bridged
    # NIC and the bridge is fine.
    if ($SwitchRecord.AllowManagementOS -ne $true) { return 'healthy' }

    # Hyper-V's own answer, asked two ways so a single property name is
    # never what decides an unhealthy verdict: a vNIC record flagged
    # IsManagementOs, or any vSwitch-side record naming this switch (live
    # mode only queries those for the switch's management OS, and a
    # host-side Get-NetAdapter record always carries an
    # InterfaceDescription instead).
    $management = @($adapter | Where-Object {
        (($_.IsManagementOs -eq $true) -or ($null -eq $_.InterfaceDescription)) -and
        ((-not $_.SwitchName) -or ("$($_.SwitchName)" -eq $SwitchName))
    })
    if ($management.Count -eq 0) { return 'management-os-detached' }

    # Map the management vNIC onto the host adapter that carries its
    # addresses. MAC first (survives a renamed vNIC), alias second.
    $hostNic = $null
    foreach ($vnic in $management) {
        $mac = ("$($vnic.MacAddress)" -replace '[^0-9A-Fa-f]', '')
        if (-not $mac) { continue }
        $hostNic = @($adapter | Where-Object {
            $_.MacAddress -and (("$($_.MacAddress)" -replace '[^0-9A-Fa-f]', '') -eq $mac) -and
            ("$($_.InterfaceDescription)" -match 'Hyper-V Virtual Ethernet')
        }) | Select-Object -First 1
        if ($hostNic) { break }
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
        $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -ne '0.0.0.0' -and $_.NextHop -ne '::' } |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1
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
        # management vNIC that vmms is still materialising right after a
        # bind is not mistaken for one that will never exist.
        if ($pass -ge 2 -and $SwitchName -and (Test-YurunaManagementVnicAbsent -SwitchName $SwitchName)) {
            Write-Verbose "vSwitch '$SwitchName' has no management-OS vNIC, so no address can appear on its segment$offSegment -- reporting no host IPv4 instead of waiting out the timeout."
            return $null
        }

        Write-Verbose "No usable host IPv4 yet (vSwitch bind still settling)$offSegment -- retrying in ${PollSeconds}s."
        Start-Sleep -Seconds $PollSeconds
    }
}

# Both reuse branches of Get-OrCreateYurunaExternalSwitch funnel a
# degraded verdict through here. Two invariants shape what it may do:
#
#   * $null is the only "no bridge" signal the guest scripts understand,
#     and declining is always at least as good as handing back a bridge
#     the classifier just rejected. Each guest script substitutes
#     'Default Switch' for $null, verifies that switch exists, and where
#     it does not (Windows Server SKUs ship none, and an operator can
#     delete it on a client SKU) falls back to any vSwitch the host has,
#     ranking non-External first -- which is the better choice precisely
#     here, because a guest on a carrier-less External switch comes up
#     with no address at all while an Internal/NAT switch still gives it
#     a working one. Returning the degraded name instead would skip that
#     picker entirely, so declining is what lets it run.
#   * The branches run several times per cycle plus once per read-only
#     Get-ExternalNetwork probe, so the diagnosis is latched to once per
#     process per (switch, verdict) rather than repeated on every call.
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
            "Recreate '$SwitchName' as an External switch, or point the guests at an External switch that already exists."
        }
        'uplink-missing' {
            "The switch names no uplink NIC. Re-bind it with Set-VMSwitch -Name '$SwitchName' -NetAdapterName <adapter>."
        }
        'uplink-down' {
            'The bound NIC is not Up. Check the cable, the switch port and the adapter driver -- Hyper-V cannot bridge a link that is down.'
        }
        'management-os-detached' {
            "Hyper-V reports no management-OS vNIC on the switch. Set-VMSwitch -Name '$SwitchName' -AllowManagementOS `$true restores it, at the cost of a brief host-networking drop on that NIC."
        }
        'management-os-unaddressed' {
            "The switch's management vNIC holds no usable IPv4. Check DHCP on that segment, or the static address on 'vEthernet ($SwitchName)'."
        }
        default {
            "Inspect the switch with Get-VMSwitch -Name '$SwitchName' and Get-NetAdapter."
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
        Write-Warning "External vSwitch '$SwitchName' cannot carry a bridged guest (verdict '$Verdict'$detailText). $consequence Remedy: $remedy"
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
    $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' -and $_.NextHop -ne '::' } |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1
    if (-not $route) { return $null }
    $nic = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
    if (-not $nic) { return $null }
    if ($nic.InterfaceDescription -match 'Hyper-V Virtual Ethernet') {
        $sw = Get-VMSwitch -ErrorAction SilentlyContinue |
            Where-Object { $_.SwitchType -eq 'External' -and "vEthernet ($($_.Name))" -eq $nic.InterfaceAlias } |
            Select-Object -First 1
        if (-not $sw) { return $null }
        $descriptions = @(Get-YurunaSwitchUplinkDescription -SwitchRecord $sw)
        if ($descriptions.Count -eq 0) { return $null }
        $nic = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $descriptions -contains $_.InterfaceDescription } |
            Select-Object -First 1
        if (-not $nic) { return $null }
    }
    if ($nic.PhysicalMediaType -eq 'Native 802.11' -or $nic.PnPDeviceID -like 'USB\*') { return $null }
    if ("$($nic.Status)" -ne 'Up') { return $null }
    return $nic
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
    .OUTPUTS
        pscustomobject -- Repairable (bool), Adapter (record or $null), Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SwitchName,
        [Parameter(Mandatory)][string]$Verdict
    )
    $no = { param($why) [pscustomobject]@{ Repairable = $false; Adapter = $null; Reason = $why } }
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
        Adapter    = $target
        Reason     = "bound elsewhere while '$($target.Name)' carries the default route"
    }
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
        Rebind a stale External vSwitch onto the adapter that currently carries
        the default route. Verifies the host survived and rolls back if not.
        Returns $true only when the switch ends healthy.
    .DESCRIPTION
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
    if ($state -and $state.switchName -eq $SwitchName) {
        $attempts = [int]$state.attempts
        $firstUtc = [datetime]::MinValue
        if ($state.firstAttemptUtc -and [datetime]::TryParse("$($state.firstAttemptUtc)", [ref]$firstUtc)) {
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
        Write-Verbose "'$SwitchName' verdict '$verdict' is not repairable by rebinding: $($r.Reason)"
        return $false
    }
    if (Test-YurunaRunnerSessionRemote) {
        Write-Warning "External vSwitch '$SwitchName' needs a rebind onto '$($r.Adapter.Name)', but this runner is in a remote session and the rebind would sever it. Run the cycle from the console session, or rebind by hand: Set-VMSwitch -Name '$SwitchName' -NetAdapterName '$($r.Adapter.Name)' -AllowManagementOS `$true"
        return $false
    }
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')) {
        Write-Warning "External vSwitch '$SwitchName' needs a rebind onto '$($r.Adapter.Name)', which needs Administrator. Continuing on the fallback."
        return $false
    }
    # A rebind pulls carrier from anything already attached. At a cycle boundary
    # there should be nothing; if there is, the cycle is not where we thought it
    # was and re-plumbing under a live guest is not worth the recovery it buys.
    $live = @(Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' } |
              Get-VMNetworkAdapter -ErrorAction SilentlyContinue | Where-Object { $_.SwitchName -eq $SwitchName })
    if ($live.Count -gt 0) {
        Write-Warning "External vSwitch '$SwitchName' needs a rebind, but $($live.Count) running guest(s) are attached to it. Skipping: a rebind would drop their carrier."
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($SwitchName, "Rebind External vSwitch to '$($r.Adapter.Name)'")) { return $false }

    $existing = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    $priorDescriptions = if ($existing) { @(Get-YurunaSwitchUplinkDescription -SwitchRecord $existing) } else { @() }
    $priorAdapterName = $null
    if ($priorDescriptions.Count -gt 0) {
        $priorAdapterName = (Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $priorDescriptions -contains $_.InterfaceDescription } |
            Select-Object -First 1).Name
    }

    $attempts++
    $record = [ordered]@{
        switchName      = $SwitchName
        attempts        = $attempts
        firstAttemptUtc = if ($state -and $state.firstAttemptUtc -and $attempts -gt 1) { "$($state.firstAttemptUtc)" }
                          else { (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
        lastVerdict     = $verdict
    }
    try {
        [System.IO.File]::WriteAllText($statePath, ($record | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    } catch { Write-Verbose "switch repair state not written: $($_.Exception.Message)" }

    Write-Information -MessageData "  Rebinding External vSwitch '$SwitchName' onto '$($r.Adapter.Name)' (attempt $attempts of $MaxAttempts) -- $($r.Reason). Host networking on that NIC drops briefly." -InformationAction Continue
    try {
        Set-VMSwitch -Name $SwitchName -NetAdapterName $r.Adapter.Name -AllowManagementOS $true -ErrorAction Stop
    } catch {
        Write-Warning "Rebinding '$SwitchName' onto '$($r.Adapter.Name)' failed: $($_.Exception.Message). The switch is unchanged; guests stay on the fallback."
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
        Write-Warning "After rebinding '$SwitchName' onto '$($r.Adapter.Name)' the host had no default route within ${VerifySeconds}s. Rolling back so this host stays reachable."
        try {
            if ($priorAdapterName) {
                Set-VMSwitch -Name $SwitchName -NetAdapterName $priorAdapterName -AllowManagementOS $true -ErrorAction Stop
            } else {
                Remove-VMSwitch -Name $SwitchName -Force -ErrorAction Stop
            }
        } catch {
            Write-Warning "Roll-back of '$SwitchName' ALSO failed: $($_.Exception.Message). This host may be off the network -- it needs console access: Remove-VMSwitch -Name '$SwitchName' -Force"
        }
        return $false
    }

    $after = Test-YurunaExternalSwitchUplink -SwitchName $SwitchName
    if ($after -in $script:UplinkVerdictOk) {
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        Write-Information -MessageData "  External vSwitch '$SwitchName' repaired: bridged on '$($r.Adapter.Name)', host route intact." -InformationAction Continue
        return $true
    }
    Write-Warning "Rebound '$SwitchName' onto '$($r.Adapter.Name)' and the host kept its route, but the switch still reports '$after'. Guests stay on the fallback."
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
    Hyper-V hosts; see test/Start-CachingProxyServiceVM.ps1 for the long note).

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

    # IMPORTANT: this function's only pipeline output is a single string
    # (switch name) or $null. All diagnostics MUST go through
    # Write-Verbose / Write-Information / Write-Warning / Write-Error so callers can
    # safely assign with `$x = Get-OrCreateYurunaExternalSwitch`. A stray
    # Write-Output turns $x into a string[] and breaks downstream
    # `-SwitchName` binding (System.Object[] -> System.String coercion
    # failure).

    # --- REGION: https://yuruna.link/network#why-hyper-v-never-bridges-wi-fi-or-usb-uplinks
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

    # 2. ANY existing External-type vSwitch: reuse it instead of
    # creating a redundant second External on the same NIC. Hyper-V
    # only allows one External vSwitch per physical adapter, so a
    # blind New-VMSwitch on top of an existing one tears down the
    # original (network blip + every existing VM on the old switch
    # gets disconnected). On hosts where the operator pre-created an
    # External vSwitch under a different name (e.g., 'External',
    # 'LAN-Bridge'), we honor that and return its name. That same
    # invariant is why an External switch whose bridge is degraded
    # declines here instead of falling through to the create path.
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
            Write-Information "Using existing External vSwitch '$($picked.Name)' (preferred name '$SwitchName' not present)."
            return $picked.Name
        }
        $fallback = @($candidate | Sort-Object -Property Name)[0]
        $detail   = 'External vSwitches on this host: ' + ((@($candidate | ForEach-Object { "'$($_.Name)' -> $($_.Verdict)" })) -join ', ')
        $declined = Resolve-DegradedExternalSwitchFallback -SwitchName $fallback.Name -Verdict $fallback.Verdict -Detail $detail
        return $declined
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

    # A Wi-Fi default route was already diverted to NAT at step 0, so the
    # NIC reached here is wired -- safe to bridge.

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

    # The bind just moved the host's IP stack onto `vEthernet ($SwitchName)`,
    # which has to re-DHCP before the host is addressable again. Callers
    # resolve the guest-reachable host IPv4 immediately after this returns
    # and bake it into a seed image, so hold the switch "ready" signal until
    # the host actually has an address to hand out. A warning (not a
    # failure) because the switch itself is usable: the guest can still
    # boot and reach its off-LAN sources, it just loses the host route.
    $settleSeconds = 60
    if (-not (Wait-ExternalSwitchHostIpv4 -SwitchName $SwitchName -TimeoutSeconds $settleSeconds)) {
        Write-Warning "Host regained no usable IPv4 on 'vEthernet ($SwitchName)' or its default route within ${settleSeconds}s of the bridge. A guest seed built now carries no reachable host address."
    }

    Write-Information "External vSwitch '$SwitchName' ready."
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
        Add-PortMap's clear-all-first behavior would darken any port left
        off the list -- reachable only on a positive fault.

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

    An External switch that yields no host IPv4 returns $null rather
    than the Default Switch address: the two are on segments that do not
    route to each other, so the substitute is not a degraded answer but
    a wrong one, and it is wrong in a way the guest can only discover
    after it has booted with it burned into its seed. $null lets the
    caller fall back to its off-LAN source instead.

.PARAMETER SwitchName
    Hyper-V vSwitch name the guest will be attached to. 'Default Switch'
    returns the Default-Switch host IP; any other name is looked up via
    Get-VMSwitch and the host IPv4 on that switch's segment is returned
    for External-type switches. Falls back to Default-Switch behavior
    for unknown switches so a typo can't strand a guest with $null.

.PARAMETER SettleTimeoutSeconds
    How long an External-switch lookup keeps polling for a host IPv4
    before reporting none. Covers the address-less window while a
    freshly bridged NIC re-DHCPs.

.OUTPUTS
    [string] IPv4 address, or $null if no candidate adapter is found.
#>
function Get-GuestReachableHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$SwitchName,
        [int]$SettleTimeoutSeconds = 30
    )

    # Default Switch path (also the legacy no-arg path).
    $isDefault = (-not $SwitchName) -or ($SwitchName -eq 'Default Switch')
    if (-not $isDefault) {
        # Resolve switch type. Unknown switch -> fall back to Default
        # Switch logic so a stale name in a New-VM script doesn't bake
        # an empty value into the seed.iso.
        $switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
        if ($switch -and $switch.SwitchType -eq 'External') {
            # Polls, because a switch bridged moments ago leaves the host
            # briefly address-less while `vEthernet (<switch>)` re-DHCPs.
            $lanIp = Wait-ExternalSwitchHostIpv4 -SwitchName $SwitchName -TimeoutSeconds $SettleTimeoutSeconds
            if ($lanIp) { return $lanIp }
            # Host really is off the LAN. The Default Switch's 172.x.x.x
            # sits on an internal NAT segment this guest holds no route
            # to, so offering it would hand back an address that cannot
            # work rather than admitting there is none.
            Write-Warning "No host IPv4 reachable from a guest on External vSwitch '$SwitchName' ('vEthernet ($SwitchName)' and the default route both empty after ${SettleTimeoutSeconds}s). Reporting none instead of an unroutable Default Switch address."
            return $null
        }
        # Falling through to the Default-Switch address keeps a stale or
        # mistyped switch name from stranding a guest with no host address
        # at all, but the answer is only correct if the guest really does
        # attach to the Default Switch. Say so, because the alternative is
        # a 172.x address baked into a bridged guest's seed with nothing
        # in the log to explain where it came from.
        if ($switch) {
            Write-Warning "vSwitch '$SwitchName' is type '$($switch.SwitchType)', not External. Answering with the Default Switch address, which is reachable only from a guest actually attached to the Default Switch."
        } else {
            Write-Warning "vSwitch '$SwitchName' does not exist on this host (renamed or removed since the guest's switch was chosen). Answering with the Default Switch address, which is reachable only from a guest actually attached to the Default Switch."
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
    Returns the IP of a reachable caching-proxy-service VM (probed on :3128),
    or $null when no cache is currently usable.

.DESCRIPTION
    Caller-facing primitive shared by Get-CacheProxyForHostDownload
    and Save-CachedHttpUri so the platform-specific discovery logic
    lives in exactly one place. Wraps Get-CacheVmCandidateIp +
    Test-CachingProxyServicePort: we need the IP itself (not the proxy URL)
    so callers can also reach :80 (CA fetch) and :3129 (SSL-bump).
.OUTPUTS
    [string] IPv4 like '172.17.96.42', or $null.
#>
function Resolve-CacheHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$VMName = 'yuruna-caching-proxy-service')
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm -or $vm.State -ne 'Running') { return $null }
    $httpPort = Get-CachingProxyServicePort -Scheme http
    foreach ($ip in (Get-CacheVmCandidateIp -VM $vm)) {
        if (Test-CachingProxyServicePort -IpAddress $ip -Port $httpPort -TimeoutMs 500) {
            return $ip
        }
    }
    return $null
}

<#
.SYNOPSIS
    Downloads $Uri to $OutFile through the caching-proxy service, resolving the
    Hyper-V cache VM's IP via this driver's Resolve-CacheHostIp.

.DESCRIPTION
    Thin driver-local wrapper over the shared download stack. The closure
    binds this driver's Resolve-CacheHostIp (Hyper-V VM discovery) so the
    shared module stays platform-agnostic while still reaching the
    Hyper-V-specific cache lookup.
#>
function Save-CachedHttpUri {
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
        with a diagnostic Write-Output otherwise.

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

# --- REGION: VM lifecycle helpers
# Hyper-V-internal helpers consumed by Yuruna.Host's contract entry
# points above. Not part of the test-facing host driver contract; test
# code calls the contract verbs (New-VM / Start-VM / ...) which
# delegate here.

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
    # vmwp.exe workers run under the per-VM virtual account 'NT VIRTUAL MACHINE\<vmId>', so
    # Win32_Process.CommandLine is frequently empty (the process is owned by another account)
    # and a CommandLine-only match silently skips the worker, defeating the force-stop. Match on
    # the command line when it is readable, and otherwise on the owning account, whose user name
    # is the VM GUID.
    $workers = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='vmwp.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.CommandLine -and ($_.CommandLine -match [regex]::Escape($vmId))) -or
            (($_ | Invoke-CimMethod -MethodName GetOwner -ErrorAction SilentlyContinue).User -eq $vmId)
        })
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
Brings the VM to Off via Stop-HyperVVMForce, closes any vmconnect
viewer attached to the VM (deleting a VM with its viewer open leaves a
modal "has been deleted" dialog that blocks until dismissed by hand),
calls Remove-VM, and then removes the per-VM subdirectory under
Get-VMHost.VirtualHardDiskPath. Returns $true only when the VM is no
longer registered after Remove-VM returns; disk-cleanup failures are
warned but do not flip the result.
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
        # Close the VM's vmconnect viewer before unregistering. vmconnect has
        # no setting to suppress the modal "The virtual machine ... has been
        # deleted" dialog it raises when its VM disappears, and that dialog
        # blocks until a human clicks Exit. Must happen pre-delete: once the
        # dialog is up the window title no longer carries the VM name, so the
        # title match below would miss it.
        Get-Process -Name "vmconnect" -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -match [regex]::Escape($VMName) } |
            Stop-Process -Force -ErrorAction SilentlyContinue
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
                Remove-Item -LiteralPath $vmDir -Recurse -Force -ErrorAction Stop 6>$null
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
Ask the guest OS to shut itself down, and wait for the VM to reach Off.

.DESCRIPTION
Hyper-V's Stop-VM WITHOUT -TurnOff is served by the Shutdown integration
component, so the guest unmounts and flushes before the disk stops
changing. -Force here only suppresses the logged-on-user confirmation
prompt; it does NOT turn the semantics into a power cut.

That distinction is load-bearing whenever the stop is followed by a
checkpoint. A -TurnOff is a virtual power cut: an ext4 guest with delayed
allocation loses every write still inside its writeback window (30s by
default), and files created in that window come back with their metadata
intact and size 0 -- while the same files' data blocks were never
allocated. Those zero-length files are then baked into the checkpoint and
reappear on every later restore. A 0-byte file with the +x bit still
executes as an empty script under bash (exit 0, no output), so a truncated
tool can survive a whole provisioning run without anything complaining.

The shutdown request runs in a background job so a hung vmms cannot block
the caller. A guest that cannot answer (no integration services, stuck at a
firmware prompt) makes Stop-VM return quickly without ever reaching Off; the
job-completed check below stops waiting out the full timeout in that case.

Returns $true when the VM is gone or reached Off, $false when the guest did
not follow through -- the caller decides whether to escalate.
#>
function Request-HyperVVMShutdown {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$ShutdownTimeoutSeconds = 120
    )
    $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { return $true }
    if ($vm.State -in @('Off', 'Saved', 'OffCritical')) { return $true }
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Request guest shutdown (Stop-VM, no -TurnOff)')) { return $false }

    $shutdownJob = Start-Job -ScriptBlock {
        Hyper-V\Stop-VM -Name $using:VMName -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    }
    try {
        $deadline    = (Get-Date).AddSeconds($ShutdownTimeoutSeconds)
        $jobDoneAt   = $null
        # Grace after the request returns: Stop-VM can hand back before the VM's
        # state has settled to Off, so a completed job is not by itself a refusal.
        $graceSeconds = 5
        while ((Get-Date) -lt $deadline) {
            $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue
            if (-not $vm -or $vm.State -eq 'Off') { return $true }
            if ($shutdownJob.State -notin @('NotStarted', 'Running')) {
                if ($null -eq $jobDoneAt) { $jobDoneAt = Get-Date }
                elseif (((Get-Date) - $jobDoneAt).TotalSeconds -gt $graceSeconds) {
                    Write-Verbose "Request-HyperVVMShutdown: shutdown request for '$VMName' completed but the VM is '$($vm.State)'; the guest is not honoring it."
                    return $false
                }
            }
            Start-Sleep -Milliseconds 500
        }
    } finally {
        Stop-Job   -Job $shutdownJob -ErrorAction SilentlyContinue
        Remove-Job -Job $shutdownJob -Force -ErrorAction SilentlyContinue
    }
    return $false
}

<#
.SYNOPSIS
Stop a Hyper-V VM cleanly and close any matching vmconnect window.

.DESCRIPTION
Asks the guest to shut itself down first (Request-HyperVVMShutdown) so its
filesystem is flushed and consistent, and only escalates to
Stop-HyperVVMForce -- a -TurnOff plus vmwp.exe kill -- when the guest does
not reach Off in time. Callers that genuinely want the power cut (teardown,
where the disk is about to be deleted) call Stop-HyperVVMForce directly.

Then kills any vmconnect process whose window title references this VM so
the desktop doesn't accumulate stale viewer windows. Returns whether the VM
actually reached Off.
#>
function Stop-HyperVVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$ShutdownTimeoutSeconds = 120
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Stop Hyper-V VM (guest shutdown, escalating to force)')) { return $true }
    $stopped = $false
    try {
        $stopped = [bool](Request-HyperVVMShutdown -VMName $VMName -ShutdownTimeoutSeconds $ShutdownTimeoutSeconds -Confirm:$false)
        if (-not $stopped) {
            Write-Warning "Guest shutdown did not bring '$VMName' to Off within ${ShutdownTimeoutSeconds}s; escalating to a force-stop. Writes still inside the guest's writeback window will be lost."
            $stopped = [bool](Stop-HyperVVMForce -VMName $VMName -StopTimeoutSeconds 20 -Confirm:$false)
        }
    } catch {
        Write-Warning "Stopping Hyper-V VM '$VMName' threw: $_"
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
    # Wall-clock deadline rather than an iter counter: memory file
    # feedback_iter_counter_wallclock_trap.md flags `$elapsed += $Poll`
    # as silently expanding the budget by 3-6x when each iteration does
    # real work (Get-VM is CIM-backed and can hang briefly under VMMS
    # contention). [DateTime]::UtcNow is monotonic-enough for a 120s
    # budget and tracks actual wall time regardless of poll cost.
    $deadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadlineUtc) {
        $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if ($vm -and $vm.State -eq 'Running') {
            Write-Information "Verified: Hyper-V VM '$VMName' is running (State: $($vm.State))"
            return $true
        }
        Start-Sleep -Seconds 1
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

# --- REGION: Host proxy helpers
# --- REGION: https://yuruna.link/definition#defining-the-windows-host-proxy-registry-keys

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

# --- REGION: Port-map helpers
$script:FirewallRulePrefix        = 'Yuruna-CachingProxyService-Port-'
$script:FirewallProgramRulePrefix = 'Yuruna-CachingProxyService-Pwsh-'

<#
.SYNOPSIS
Return the path to the shared caching-proxy-service TCP forwarder script.

.DESCRIPTION
Resolves host/macos.utm/Start-CachingProxyServiceForwarder.ps1 against the
repository root inferred from $PSScriptRoot. The forwarder script
lives under host/macos.utm/ as the canonical copy but is pure
PowerShell and runs unchanged on Windows.
#>
function Get-CachingProxyServiceForwarderScriptPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # $PSScriptRoot is host/windows.hyper-v/modules, so three levels up is repo root.
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    return (Join-Path $repoRoot 'host/macos.utm/Start-CachingProxyServiceForwarder.ps1')
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
Return the pidfile path for the per-port caching-proxy-service forwarder.

.DESCRIPTION
Composes ~/virtual/caching-proxy-service/forwarder.<Port>.pid. The pidfile is
the canonical handle Stop-WindowsCachingProxyServiceForwarder uses to find
and kill the detached pwsh worker that owns a given listen port.
#>
function Get-WindowsForwarderPidPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Port)
    $stateDir = Join-Path $HOME 'virtual\caching-proxy-service'
    return (Join-Path $stateDir "forwarder.$Port.pid")
}

<#
.SYNOPSIS
Stop a detached pwsh caching-proxy-service forwarder by listen port.

.DESCRIPTION
Reads ~/virtual/caching-proxy-service/forwarder.<Port>.pid, validates the pid
belongs to a pwsh/powershell process, and calls Stop-Process -Force.
Removes the pidfile in all cases (including missing pid, non-pwsh
owner, or successful kill) so a stale file doesn't trip later starts.
No-op on non-Windows hosts; -Quiet suppresses the per-port summary
line.
#>
function Stop-WindowsCachingProxyServiceForwarder {
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
Launch a detached pwsh TCP forwarder for the squid caching-proxy service.

.DESCRIPTION
Stops any prior forwarder for the same $Port, then spawns
Start-CachingProxyServiceForwarder.ps1 hidden, wired to redirect stdout /
stderr to per-port logs under ~/virtual/caching-proxy-service/. Polls
127.0.0.1:$Port for up to 3 s; on success returns a PSCustomObject
@{ Success=$true; Pid; PwshPath } where PwshPath is the post-spawn
loaded binary (used by callers to rewrite the Defender per-program
firewall rule when the WindowsApps alias differs). $VMPort defaults
to $Port. -PrependProxyV1 forwards a HAProxy v1 PROXY header so the
upstream cache can see the original LAN client IP.
#>
function Start-WindowsCachingProxyServiceForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$CacheIp,
        [Parameter(Mandatory)][int]$Port,
        [int]$VMPort = 0,
        [switch]$PrependProxyV1
    )
    if (-not $IsWindows) {
        Write-Warning "Start-WindowsCachingProxyServiceForwarder called on non-Windows host -- no-op."
        return [PSCustomObject]@{ Success = $false; Pid = $null; PwshPath = $null }
    }
    if ($VMPort -eq 0) { $VMPort = $Port }
    $forwarderScript = Get-CachingProxyServiceForwarderScriptPath
    if (-not (Test-Path $forwarderScript)) {
        Write-Warning "Forwarder script not found: $forwarderScript"
        return [PSCustomObject]@{ Success = $false; Pid = $null; PwshPath = $null }
    }
    $stateDir = Join-Path $HOME 'virtual\caching-proxy-service'
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $pidFile = Get-WindowsForwarderPidPath -Port $Port
    $logFile = Join-Path $stateDir "forwarder.$Port.log"
    $stdoutLog = Join-Path $stateDir "forwarder.$Port.stdout.log"
    $stderrLog = Join-Path $stateDir "forwarder.$Port.stderr.log"
    Stop-WindowsCachingProxyServiceForwarder -Port $Port -Quiet
    $proxyTag = if ($PrependProxyV1) { ' [PROXY v1]' } else { '' }
    $action   = "0.0.0.0:${Port} -> ${CacheIp}:${VMPort}${proxyTag}"
    if (-not $PSCmdlet.ShouldProcess($action, 'Launch detached pwsh TCP forwarder')) {
        return [PSCustomObject]@{ Success = $false; Pid = $null; PwshPath = $null }
    }
    Write-Information "  Launching userspace forwarder: ${action}"
    # Pre-quote every path-valued argument. Start-Process joins -ArgumentList
    # array elements with spaces WITHOUT quoting, so a path under
    # "C:\Users\Yuruna Test\..." gets re-split by CreateProcess and the
    # child sees mis-aligned flag/value pairs ("-File C:\Users\Yuruna").
    # Wrapping each path in literal double quotes makes the joined command
    # line parse correctly. Non-path scalars (IP, port numbers) need no
    # quoting.
    $forwarderScriptQuoted = '"' + $forwarderScript + '"'
    $pidFileQuoted         = '"' + $pidFile + '"'
    $logFileQuoted         = '"' + $logFile + '"'
    $procArgs = @(
        '-NoProfile','-NoLogo','-File', $forwarderScriptQuoted,
        '-CacheIp', $CacheIp,
        '-Port', $Port,
        '-VMPort', $VMPort,
        '-PidFile', $pidFileQuoted,
        '-LogFile', $logFileQuoted
    )
    if ($PrependProxyV1) { $procArgs += '-PrependProxyV1' }
    try {
        # -RedirectStandardInput against an empty file: without an explicit
        # stdin redirect the detached forwarder inherits the parent
        # console's stdin handle, and Windows conhost cannot tear down
        # when the parent shell exits -- pinning the operator's
        # PowerShell window in a close-pending state until the forwarder
        # is killed. Passing 'NUL' / '\\.\NUL' is rejected by
        # Start-Process's path resolver (it prepends the cwd and the
        # underlying FileStream open fails), so we use a persistent empty
        # sentinel file in the forwarder's state dir.
        $stdinSink = Join-Path $stateDir 'stdin.empty'
        if (-not (Test-Path -LiteralPath $stdinSink)) {
            [System.IO.File]::WriteAllBytes($stdinSink, [byte[]]@())
        }
        $proc = Start-Process -FilePath 'pwsh' `
            -ArgumentList $procArgs `
            -RedirectStandardInput  $stdinSink `
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
Install Yuruna-tagged inbound firewall rules for a caching-proxy-service port.

.DESCRIPTION
Removes any existing rules with the Yuruna-CachingProxyService-Port-<Port>
display name, then creates a fresh Allow rule on that TCP port across
all profiles. When -IncludeProgram is set it also (re)creates a
Yuruna-CachingProxyService-Pwsh-<Port> per-program rule scoped to
$ProgramPath (or Get-PwshExePath when omitted). The per-program rule
guards against Defender silently dropping LAN traffic when the
WindowsApps App Execution Alias resolves to a different binary than
the loaded pwsh.exe; if no path is resolvable the rule is skipped
with a warning.
#>
function Add-CachingProxyServiceFirewallRule {
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
Walks ~/virtual/caching-proxy-service/ for forwarder.<port>.pid files and
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
    $stateDir = Join-Path $HOME 'virtual\caching-proxy-service'
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
Discover Yuruna caching-proxy-service ports from existing firewall rules.

.DESCRIPTION
Scans Get-NetFirewallRule for display names that begin with
Yuruna-CachingProxyService-Port- or Yuruna-CachingProxyService-Pwsh- and returns
the parsed integer ports, sorted and de-duplicated. Used by
Clear-AllCachingProxyServicePortMapping to clean up rules left behind when
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
Yuruna-CachingProxyService-Port-<Port> and Yuruna-CachingProxyService-Pwsh-<Port>
firewall rules if present. Idempotent: missing pieces are silently
skipped so callers can issue a blanket sweep.
#>
function Remove-SinglePortMap {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][int]$Port)
    if (-not $PSCmdlet.ShouldProcess("host:${Port}", 'Remove portproxy + firewall rule')) { return }
    & netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=0.0.0.0 2>&1 | Out-Null
    Stop-WindowsCachingProxyServiceForwarder -Port $Port -Quiet
    foreach ($prefix in @($script:FirewallRulePrefix, $script:FirewallProgramRulePrefix)) {
        $ruleName = "${prefix}${Port}"
        Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
Tear down every Yuruna caching-proxy-service port mapping on this host.

.DESCRIPTION
Builds the union of ports recorded in the optional $StatePath JSON,
ports discovered via Get-YurunaMappedPortFromFirewall, and ports with
a live forwarder pidfile (Get-WindowsForwarderPidPort), then calls
Remove-SinglePortMap on each. Deletes $StatePath when present and
returns the de-duplicated, sorted port list as an array. The triple
union is the safety net that keeps state, firewall, and pidfile in
sync even when one of them has drifted.
#>
function Clear-AllCachingProxyServicePortMapping {
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
            Write-Verbose "Clear-AllCachingProxyServicePortMapping: could not read state ($StatePath): $_"
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

# --- REGION: Screenshot helpers
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

    # --- REGION: Load C# type (once per session)
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
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);
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

    // Per-Monitor-V2 makes GetClientRect/PrintWindow operate in the window's
    // true physical pixels. A merely system-DPI-aware capture on a display
    // scaled above 100% (e.g. a 150% Yuruna virtual display) measures the
    // vmconnect client area in the virtualized 96-DPI space, so PrintWindow
    // renders only the top-left of the real window and the bottom of the guest
    // console -- where waitForText's success marker and the shell prompt sit --
    // falls off-frame, silently timing OCR out. Thread-scoped so it is
    // reversible and sidesteps the once-per-process awareness constraint;
    // returns IntPtr.Zero (no restore needed) on Windows builds without the
    // API, leaving the EnsureDpiAware process awareness in force.
    static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = new IntPtr(-4);
    static IntPtr EnterPerMonitorV2() {
        try { return SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2); }
        catch { return IntPtr.Zero; }
    }
    static void RestoreThreadDpiContext(IntPtr prev) {
        if (prev == IntPtr.Zero) return;
        try { SetThreadDpiAwarenessContext(prev); } catch { }
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
        IntPtr prevDpiCtx = EnterPerMonitorV2();
        try {
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
        } finally {
            RestoreThreadDpiContext(prevDpiCtx);
        }
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

    Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.YurunaDir.psm1') -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    $debugDir = Join-Path (Initialize-YurunaLogDir) "Screenshot"
    if (-not (Test-Path $debugDir)) { New-Item -ItemType Directory -Force -Path $debugDir | Out-Null }

    # --- REGION: Primary: WMI GetVirtualSystemThumbnailImage
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
                # DWM isn't actively painting the synthetic GPU. Reported
                # ONCE per process so a long Invoke-TestRunner cycle
                # doesn't flood the log with the same message every step.
                # Verbose, not Warning: the PrintWindow/vmconnect fallback
                # below recovers a usable framebuffer, so a headless host
                # keeps passing -- raise the log level to see the
                # troubleshooting pointer when OCR does start timing out.
                if (-not $script:__YurunaHyperVBlankWarned -and
                    [HyperVCapture]::IsImageMostlyBlack(
                        [byte[]]$result.ImageData, [int]$reqW, [int]$reqH, 0.99)) {
                    Write-Verbose "Hyper-V WMI thumbnail came back all-black for '$VMName' -- DWM is not painting the synthetic GPU (likely no monitor / RDP session on this host)."
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

    # --- REGION: Fallback: PrintWindow via vmconnect window
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
            Write-Warning "vmconnect window not found for '$VMName'. Open a vmconnect session for this VM before using tapOn."
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

# --- REGION: VM lifecycle

<#
.SYNOPSIS
    Create a guest VM by running the per-guest New-VM.ps1 script.
#>
function New-VM {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is delegated to Invoke-PerGuestNewVm, which declares SupportsShouldProcess and calls it; -WhatIf/-Confirm propagate via the splatted PSBoundParameters.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$VMName,
        [string]$CachingProxyServiceUrl,
        # Planner-cascaded username override (resolved by Test.SequencePlanner
        # from variables.username on the chain's top sequence). Forwarded
        # to the per-guest New-VM.ps1 only when (a) the caller bound it
        # AND (b) the target script declares a -Username parameter -- some
        # guests (windows.11, caching-proxy-service, macos.26) don't take one and
        # would error on the unexpected arg.
        [string]$Username,
        # Planner-cascaded guest hostname (variables.hostname), forwarded
        # under the same declare-or-drop rule as -Username. Empty leaves the
        # per-guest script on its VM-name default.
        [string]$Hostname,
        # Planner-cascaded VM sizing (variables.memoryStartupBytes /
        # variables.cores), forwarded under the same declare-or-drop rule as
        # -Username. Empty leaves the per-guest script on its built-in default.
        [string]$MemoryStartupBytes,
        [string]$Cores
    )
    # Thin wrapper over the shared per-guest runner; the host subdir is the
    # only platform variable. Splatting $PSBoundParameters preserves the
    # conditional -CachingProxyServiceUrl/-Username/-Hostname/-MemoryStartupBytes/-Cores
    # forwarding (the runner checks ContainsKey) and propagates -WhatIf/-Confirm.
    Invoke-PerGuestNewVm -HostSubdir 'host\windows.hyper-v' @PSBoundParameters
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
    Rename a stopped VM and relocate its on-disk storage to a folder
    matching the new name.
.DESCRIPTION
    Hyper-V's Rename-VM only renames the registry entry; the VHDX files
    stay at <vhdPath>\<oldName>\. Leaving them there would let
    Remove-OrphanedVMFiles.ps1 reclaim the directory on the next cycle
    because the dir name no longer matches any registered VM, killing
    the persisted snapshot. Move-VMStorage relocates VHDX + .vmcx +
    snapshot data into a fresh <vhdPath>\<NewName>\ tree so the new
    name owns the disk layout.

    Requires the VM to be stopped; the caller (Save-VMDiskSnapshot) is
    responsible for the stop. Returns $false on rename or storage-move
    failure -- a partial rename (registry succeeded, move failed) is
    surfaced rather than swallowed so the operator sees the broken state.
#>
function Rename-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$NewName
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, "Rename to '$NewName' and relocate storage")) { return $false }
    if ($VMName -eq $NewName) { return $true }
    $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Warning "Rename-VM: source VM '$VMName' not registered."
        return $false
    }
    if (Hyper-V\Get-VM -Name $NewName -ErrorAction SilentlyContinue) {
        Write-Warning "Rename-VM: destination name '$NewName' already exists."
        return $false
    }
    try {
        Hyper-V\Rename-VM -Name $VMName -NewName $NewName -Confirm:$false -ErrorAction Stop
    } catch {
        Write-Warning "Rename-VM: Hyper-V Rename-VM failed: $($_.Exception.Message)"
        return $false
    }
    # Relocate storage so the on-disk dir-name matches the new VM-name.
    # Without this, Remove-OrphanedVMFiles' "dir name with no matching
    # VM" sweep would later wipe the persisted snapshot's files.
    $vhdRoot = (Hyper-V\Get-VMHost -ErrorAction SilentlyContinue).VirtualHardDiskPath
    if ($vhdRoot) {
        $destDir = Join-Path $vhdRoot $NewName
        try {
            Hyper-V\Move-VMStorage -VMName $NewName -DestinationStoragePath $destDir -Confirm:$false -ErrorAction Stop
        } catch {
            Write-Warning "Rename-VM: registry renamed to '$NewName' but Move-VMStorage to '$destDir' failed: $($_.Exception.Message). Files still live under '<vhdPath>\$VMName\' and may be swept by the orphan-file sweep."
            return $false
        }
    }
    return $true
}

<#
.SYNOPSIS
    Save a disk-only snapshot of the VM, then rename the VM (and
    relocate its storage) so it persists across test-cycle cleanup.
.DESCRIPTION
    Hyper-V's Checkpoint-VM captures runtime state by default. For a
    disk-only point this function stops the VM first (graceful, then
    Stop-VMForce on graceful timeout); with no RAM to checkpoint, the
    resulting .avhdx differencing disk + .vmrs pair is effectively a
    disk-only point. Leaves the VM stopped on return so the caller's
    sequence can decide when to restart -- mirrors KVM and UTM
    semantics where the underlying tool requires an offline VM.

    After a successful checkpoint, the VM is renamed to $Id and its
    storage is moved into <vhdPath>\<Id>\ so the next cycle's
    Remove-TestVMFiles.ps1 (which sweeps every name matching the
    test-* prefix) leaves the persisted VM and its snapshot alone.
    Caller is expected to update its local $VMName reference to $Id;
    the sequence engine does this automatically after a successful
    saveDiskSnapshot step so subsequent steps target the persisted VM.
#>
function Save-VMDiskSnapshot {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, "Save disk snapshot '$Id' and rename to '$Id'")) { return $false }
    # The checkpoint is only as good as the disk under it: the guest has to
    # flush before the bytes are frozen, or the snapshot is crash-consistent
    # and silently missing the tail of whatever the sequence just installed
    # (see Request-HyperVVMShutdown). A force-stop here still beats leaving the
    # VM running -- Checkpoint-VM on a live VM would capture the same dirty
    # state -- but it makes the snapshot untrustworthy, so say so loudly rather
    # than persisting a corrupt baseline every later restore inherits.
    # Gate on "not genuinely off" rather than -eq 'running': Get-VMState
    # reports transitional Hyper-V states (Paused, Starting, Stopping, ...)
    # as 'unknown', and skipping the stop for those would checkpoint a
    # non-Off guest -- the same dirty-state capture the warning below is
    # about, taken silently.
    if ((Get-VMState -VMName $VMName) -notin @('stopped', 'absent')) {
        if (-not (Stop-VM -VMName $VMName)) {
            Write-Warning "Save-VMDiskSnapshot: '$VMName' would not shut down cleanly; force-stopping. Checkpoint '$Id' may be crash-consistent -- files written in the last seconds before the stop can be zero-length in it."
            [void](Stop-VMForce -VMName $VMName)
        }
    }
    $existing = Hyper-V\Get-VMCheckpoint -VMName $VMName -Name $Id -ErrorAction SilentlyContinue
    if ($existing) {
        try { Hyper-V\Remove-VMCheckpoint -VMName $VMName -Name $Id -Confirm:$false -ErrorAction Stop }
        catch { Write-Warning "Save-VMDiskSnapshot: removing prior checkpoint '$Id' failed: $($_.Exception.Message)"; return $false }
    }
    try {
        Hyper-V\Checkpoint-VM -Name $VMName -SnapshotName $Id -Confirm:$false -ErrorAction Stop
    } catch {
        Write-Warning "Save-VMDiskSnapshot: Checkpoint-VM failed for '$VMName/$Id': $($_.Exception.Message)"
        return $false
    }
    # Promote the VM out of the test-* namespace so it survives the
    # next cycle's Remove-TestVMFiles sweep. If the VM is already named
    # $Id (re-running the same sequence against the persisted VM),
    # Rename-VM is a $VMName -eq $NewName no-op.
    if ($VMName -ne $Id) {
        if (-not (Rename-VM -VMName $VMName -NewName $Id -Confirm:$false)) {
            Write-Warning "Save-VMDiskSnapshot: snapshot '$Id' saved but rename '$VMName' -> '$Id' failed; VM will be wiped on next cycle cleanup."
            return $false
        }
    }
    return $true
}

<#
.SYNOPSIS
    Returns $true when checkpoint $Id is present on $VMName, $false
    otherwise (including when the VM does not exist). Used by
    Invoke-TestSequence.ps1's requiresSnapshot warm-path probe before
    deciding whether to walk the baseline chain.
#>
function Test-VMDiskSnapshot {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    if ((Get-VMState -VMName $VMName) -eq 'absent') { return $false }
    $cp = Hyper-V\Get-VMCheckpoint -VMName $VMName -Name $Id -ErrorAction SilentlyContinue
    return [bool]$cp
}

function Restore-VMDiskSnapshot {
    <#
    .SYNOPSIS
        Restore $VMName to Hyper-V checkpoint $Id.
    .DESCRIPTION
        Verifies the checkpoint exists first so a typo'd Id does not
        bounce a healthy guest, stops the VM if it is running, then
        calls Hyper-V\Restore-VMCheckpoint. Returns the apply status as
        a bool so callers can branch on success.
    .OUTPUTS
        [bool] $true on success; $false on missing checkpoint or restore failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, "Restore disk snapshot '$Id'")) { return $false }
    $cp = Hyper-V\Get-VMCheckpoint -VMName $VMName -Name $Id -ErrorAction SilentlyContinue
    if (-not $cp) {
        Write-Warning "Restore-VMDiskSnapshot: no checkpoint '$Id' on '$VMName'."
        return $false
    }
    # Force-stop deliberately: the running guest's disk state is about to be
    # rolled back to the checkpoint, so flushing it first buys nothing and a
    # guest shutdown would only add its full timeout to every restore.
    # Gate on "not genuinely off" rather than -eq 'running': transitional
    # states (Paused, Starting, Stopping, ...) surface as 'unknown', and
    # Restore-VMCheckpoint against a non-Off VM fails.
    if ((Get-VMState -VMName $VMName) -notin @('stopped', 'absent')) {
        [void](Stop-VMForce -VMName $VMName)
    }
    try {
        Hyper-V\Restore-VMCheckpoint -VMName $VMName -Name $Id -Confirm:$false -ErrorAction Stop
        return $true
    } catch {
        Write-Warning "Restore-VMDiskSnapshot: Restore-VMCheckpoint failed for '$VMName/$Id': $($_.Exception.Message)"
        return $false
    }
}

<#
.SYNOPSIS
    Return the names of every Hyper-V VM, optionally filtered to those
    starting with one of $Prefix.
.DESCRIPTION
    Host-neutral inventory call (see the contract's VM inventory block).
    Every registered VM is returned regardless of run state, so a caller
    sweeping by prefix removes stopped leftovers as well as running ones.

    THROWS when Hyper-V itself cannot be queried rather than returning an
    empty list: without elevation (or with vmms down) Get-VM fails, and a
    caller that read that as "nothing registered" would report a clean
    host and let the orphan-file pass delete VHDX directories that are
    still in use.
.PARAMETER Prefix
    Zero or more name prefixes. A VM is returned when its name starts
    with any of them. Omit to return every VM.
.OUTPUTS
    [string[]] matching VM names; empty when none match.
#>
function Get-VMName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string[]]$Prefix)
    try {
        # Module-qualified: the unqualified Get-VM resolves to this
        # driver's contract surface, which exposes Get-VMState instead.
        $all = @(Hyper-V\Get-VM -ErrorAction Stop | ForEach-Object { $_.Name })
    } catch {
        throw "Get-VMName: could not enumerate Hyper-V VMs (is this session elevated and the Hyper-V service running?): $($_.Exception.Message)"
    }
    return Select-NameByPrefix -Name $all -Prefix $Prefix
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
    # Test.SequenceEngine.psm1's Send-ClickHyperV uses similar logic.
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

# --- REGION: Image

<#
.SYNOPSIS
    Run the per-guest Get-Image.ps1 to download or refresh the base image.
#>
function Get-Image {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is delegated to Invoke-GetImage, which declares SupportsShouldProcess and calls it; -WhatIf/-Confirm propagate via the splatted PSBoundParameters.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Force
    )
    # Thin wrapper over the shared runner; the host subdir is the only platform
    # variable and Get-ImagePath (the per-platform image table) is injected as a
    # CommandInfo resolved in THIS driver's scope so the shared body binds ours.
    Invoke-GetImage -HostSubdir 'host\windows.hyper-v' -ResolveImagePath (Get-Command Get-ImagePath) @PSBoundParameters
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
        'guest.amazon.linux.2023'    = 'host.windows.hyper-v.guest.amazon.linux.2023.vhdx'
        'guest.ubuntu.server.24'   = 'host.windows.hyper-v.guest.ubuntu.server.24.iso'
        'guest.windows.11'      = 'host.windows.hyper-v.guest.windows.11.iso'
    }
    $fileName = $fileNames[$GuestKey]
    if (-not $fileName) { return $null }
    try {
        $vhdPath = (Hyper-V\Get-VMHost -ErrorAction Stop).VirtualHardDiskPath
        return Join-Path $vhdPath $fileName
    } catch { $null = $_; return $null }
}

# --- REGION: VM I/O

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
        [int]$CharDelayMs = 10,
        [switch]$Sensitive
    )
    # Sensitive is part of the contract for log redaction; current paths
    # (SSH and the Invoke-Sequence GUI dispatcher) do not yet honour it.
    if ($Sensitive) { Write-Debug "Send-Text: -Sensitive set on '$VMName'; log redaction not yet implemented on Hyper-V." }
    if ($Mechanism -eq 'ssh') {
        if (-not $GuestKey) {
            Write-Warning "Send-Text -Mechanism ssh requires -GuestKey to determine the SSH login user."
            return $false
        }
        # Test.Ssh\Invoke-GuestSsh resolves both the user (from GuestKey)
        # and the address (from VMName) internally; surface .success, not the
        # hashtable itself -- [bool] of a non-null hashtable is always $true
        # (truthy-hashtable trap).
        $r = Invoke-GuestSsh -VMName $VMName -GuestKey $GuestKey -Command $Text
        return [bool]$r.success
    }
    # GUI: defer to Invoke-Sequence's host-aware dispatcher (same pattern
    # as KVM and macOS). Send-TextHyperV is a private helper inside that
    # module; calling it directly from here fails under module scoping
    # because Yuruna.Host's body cannot see another module's private
    # functions even when both are loaded -Global. Going through the
    # exported Test.SequenceEngine\Send-Text avoids the visibility trap.
    $sequenceEngine = Join-Path $script:TestModulesDir 'Test.SequenceEngine.psm1'
    if (Test-Path $sequenceEngine) {
        # Import once and reuse. When the outer loop already loaded Invoke-Sequence -Global we must
        # NOT re-import per call: a -Force re-import evicts/reinitializes the global module (and its
        # nested modules + $script: state) the outer loop still calls, and doing it on every
        # keystroke is pure overhead (feedback_module_force_import_evicts_global,
        # feedback_module_script_state_reset_by_force_reimport).
        if (-not (Get-Module -Name Test.SequenceEngine)) { Import-Module $sequenceEngine -DisableNameChecking -Global }
        return [bool](Test.SequenceEngine\Send-Text -HostType (Resolve-HostTag) -VMName $VMName -Text $Text -CharDelayMs $CharDelayMs)
    }
    Write-Warning "Send-Text -Mechanism gui: Test.SequenceEngine.psm1 not found at '$sequenceEngine'."
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
    $sequenceEngine = Join-Path $script:TestModulesDir 'Test.SequenceEngine.psm1'
    if (Test-Path $sequenceEngine) {
        # Import once and reuse, never -Force per call -- same trap as Send-Text
        # above (feedback_module_force_import_evicts_global,
        # feedback_module_script_state_reset_by_force_reimport).
        if (-not (Get-Module -Name Test.SequenceEngine)) { Import-Module $sequenceEngine -DisableNameChecking -Global }
        return [bool](Test.SequenceEngine\Send-Key -HostType (Resolve-HostTag) -VMName $VMName -KeyName $Key)
    }
    Write-Warning "Send-Key -Mechanism gui: Test.SequenceEngine.psm1 not found at '$sequenceEngine'."
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
    $sequenceEngine = Join-Path $script:TestModulesDir 'Test.SequenceEngine.psm1'
    if (Test-Path $sequenceEngine) {
        # Import once and reuse, never -Force per call -- same trap as Send-Text
        # above (feedback_module_force_import_evicts_global,
        # feedback_module_script_state_reset_by_force_reimport).
        if (-not (Get-Module -Name Test.SequenceEngine)) { Import-Module $sequenceEngine -DisableNameChecking -Global }
        return [bool](Test.SequenceEngine\Send-Click -HostType (Resolve-HostTag) -VMName $VMName -X $X -Y $Y)
    }
    Write-Warning "Send-Click: Test.SequenceEngine.psm1 not found at '$sequenceEngine'."
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
    # 'frame' source: WMI GetVirtualSystemThumbnailImage, with vmconnect PrintWindow fallback (Get-HyperVScreenshot).
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

# --- REGION: Discovery

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
        [int]$PollSeconds    = 3,
        # Forwarded so a caller can widen or waive the shared poller's settle
        # window; its default applies when this is not bound.
        [int]$StableForSeconds = 8
    )
    # Get-Command runs in THIS driver's scope, so the shared poller resolves
    # our Get-VMIp; a bare name would resolve in the shared module's scope.
    Invoke-WaitVmIp @PSBoundParameters -ResolveVmIp (Get-Command Get-VMIp)
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
    # the caching-proxy-service discovery path. This Get-VMIp is the cheap
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

# --- REGION: Networking

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
    Returns true if the caching-proxy-service VM is on an External-type network.
#>
function Test-CacheVMOnExternalNetwork {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VMName = 'yuruna-caching-proxy-service')
    return [bool](Test-CacheVmOnYurunaExternalSwitch -VMName $VMName)
}

<#
.SYNOPSIS
    Install host to VM port forwarders for the caching-proxy service.
#>
function Add-PortMap {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMIp,
        [int[]]$Port = @(3000),
        [hashtable]$PortRemap = @{},
        [int[]]$ProxyProtocolPort = @(),
        [string]$RuntimeDir
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
    $statePath = Get-PortMapStatePath -RuntimeDir $RuntimeDir
    # Tear down every prior Yuruna mapping (state-file ports + firewall-
    # rule ports + live forwarder pidfiles) before adding the new set.
    [void](Clear-AllCachingProxyServicePortMapping -StatePath $statePath -Confirm:$false)
    # Track which host ports actually came up so the state file records only live mappings and
    # the caller can detect (and re-drive) a partial setup instead of trusting a complete state.
    $launched = [System.Collections.Generic.List[int]]::new()
    $failed   = [System.Collections.Generic.List[int]]::new()
    foreach ($m in $mappings) {
        $hostPort = $m.HostPort; $vmPort = $m.VMPort
        $useProxy = $proxyProtoSet.ContainsKey([int]$hostPort)
        $proxyTag = if ($useProxy) { ' [PROXY v1]' } else { '' }
        if (-not $PSCmdlet.ShouldProcess("host:${hostPort} -> ${VMIp}:${vmPort}${proxyTag}", 'Add port mapping')) { continue }
        $desc = "Yuruna caching-proxy service: forward host :${hostPort} to VM :${vmPort}${proxyTag}"
        & netsh interface portproxy delete v4tov4 listenport=$hostPort listenaddress=0.0.0.0 2>&1 | Out-Null
        Stop-WindowsCachingProxyServiceForwarder -Port $hostPort -Quiet
        Add-CachingProxyServiceFirewallRule -Port $hostPort -Description $desc -IncludeProgram:$useProxy -Confirm:$false
        if ($useProxy) {
            $spawn = Start-WindowsCachingProxyServiceForwarder -CacheIp $VMIp -Port $hostPort -VMPort $vmPort -PrependProxyV1
            if (-not $spawn.Success) {
                Write-Warning "Add-PortMap: pwsh forwarder failed for host ${hostPort} -> ${VMIp}:${vmPort} (PROXY v1)."
                $failed.Add($hostPort)
                continue
            }
            # Self-heal the per-program rule if Get-PwshExePath's pre-spawn
            # guess didn't match the binary the OS actually loaded (Microsoft
            # Store App Execution Alias trap).
            if ($spawn.PwshPath) {
                $existingProgramPath = $null
                try {
                    $existingProgramPath = (Get-NetFirewallRule -DisplayName "Yuruna-CachingProxyService-Pwsh-${hostPort}" -ErrorAction Stop |
                                            Get-NetFirewallApplicationFilter -ErrorAction Stop).Program
                } catch { $null = $_ }
                if ($existingProgramPath -ne $spawn.PwshPath) {
                    if ($existingProgramPath) {
                        Write-Information "  Pwsh path resolved to '$($spawn.PwshPath)' (rule had '$existingProgramPath') -- rewriting per-program firewall rule."
                    } else {
                        Write-Information "  Installing per-program firewall rule with resolved pwsh path '$($spawn.PwshPath)'."
                    }
                    Add-CachingProxyServiceFirewallRule -Port $hostPort -Description $desc -IncludeProgram -ProgramPath $spawn.PwshPath -Confirm:$false
                }
            }
        } else {
            & netsh interface portproxy add v4tov4 listenport=$hostPort listenaddress=0.0.0.0 connectport=$vmPort connectaddress=$VMIp | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Add-PortMap: netsh portproxy add failed for host ${hostPort} -> ${VMIp}:${vmPort} (exit $LASTEXITCODE)."
                $failed.Add($hostPort)
                continue
            }
        }
        $launched.Add($hostPort)
        Write-Information "  Port map added: host:${hostPort} -> ${VMIp}:${vmPort}${proxyTag}"
    }
    # Persist ONLY the ports that actually came up, so a later reader / self-heal never treats a
    # partially-installed map as complete.
    $liveMappings = @($mappings | Where-Object { $launched -contains $_.HostPort })
    $state = [ordered]@{
        vmIp      = $VMIp
        ports     = @($liveMappings | ForEach-Object { $_.HostPort })
        mappings  = @($liveMappings | ForEach-Object {
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
    if ($failed.Count -gt 0) {
        Write-Warning "Add-PortMap: $($failed.Count) of $($mappings.Count) port mapping(s) failed to come up (port(s): $($failed -join ', ')); state records only the live ports."
        return $false
    }
    return $true
}

<#
.SYNOPSIS
    Tear down all yuruna caching-proxy-service port forwarders.
#>
function Remove-PortMap {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string]$RuntimeDir)
    if (-not $PSCmdlet.ShouldProcess('netsh portproxy mappings + pwsh forwarders', 'Clear all yuruna port mappings')) { return $false }
    if (-not (Test-IsAdministrator)) {
        $pendingPorts = Get-YurunaMappedPortFromFirewall
        if ($pendingPorts.Count -gt 0) {
            Write-Warning "Remove-PortMap: admin privilege required to remove portproxy/firewall rules for ports: $($pendingPorts -join ', '). State left in place for a later elevated run."
        }
        return $false
    }
    $statePath = Get-PortMapStatePath -RuntimeDir $RuntimeDir
    $cleared = @(Clear-AllCachingProxyServicePortMapping -StatePath $statePath -Confirm:$false)
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

# --- REGION: Caching-proxy service

<#
.SYNOPSIS
    Probe and return the caching-proxy-service URL, or null if none is reachable.
.DESCRIPTION
    Discovery is intentionally narrow -- only caches this host owns,
    or a remote cache the operator explicitly named, are returned:
      1. $Env:YURUNA_CACHING_PROXY_SERVICE_IP -- explicit remote cache override.
      2. State file (Read-CachingProxyServiceState).ipAddress -- the cache VM's
         IP written by Start-CachingProxyServiceVM.ps1 (our own VM).

    No Hyper-V VM enumeration, no KVP/ARP discovery. Get-CacheVmCandidateIp
    and Get-WorkingCachingProxyServiceUrl still exist for use by the producer
    (guest.caching-proxy-service/New-VM.ps1) and Start-CachingProxyServiceVM.ps1 itself
    while the cache VM is being brought up -- they are not part of the
    steady-state discovery path. LAN-wide cache discovery is a separate
    future feature.
#>
function Test-CachingProxyServiceAvailable {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Thin wrapper over the shared probe; the only platform variable is the
    # operator verify-command template embedded in the unreachable-cache
    # warning (Test-NetConnection on Windows). The kvm driver keeps its own
    # probe (it omits Format-IpUrlHost's IPv6 bracketing the guests rely on).
    Invoke-CachingProxyServiceAvailableProbe -VerifyHint 'Test-NetConnection {0} -Port {1}'
}

<#
.SYNOPSIS
    Return the cache VM's real IP for downstream port-forwarder setup.
#>
function Get-CachingProxyServiceVmIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # On Windows the URL Test-CachingProxyServiceAvailable returns already
    # contains the cache VM's real IP, so callers extract it from there.
    # The yuruna-caching-proxy-service state file is a macOS-specific breadcrumb
    # (the macOS URL contains the VZ gateway, not the VM IP). Returning
    # $null here is correct.
    return $null
}

# --- REGION: Host config

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
    # Yuruna.Common.psm1's Get-HostProxyBackupPath is the authoritative
    # implementation -- same path on every host. Module-qualified call
    # avoids re-entering OUR function.
    return Yuruna.Common\Get-HostProxyBackupPath
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

function Remove-OrphanedVMFileAccess {
    <#
    .SYNOPSIS
        Strip stale per-VM access ACEs from a file's ACL, keeping only the
        ACEs of VMs that still exist. Returns the number removed.
    .DESCRIPTION
        Guards against Hyper-V shared-image DACL bloat: each attach appends a
        per-VM ACE (SID family S-1-5-83-1-*) that Remove-VM never revokes,
        until the ~64 KB DACL cap fails the next attach with 0x8007053C /
        0x80070005 regardless of caller elevation. Only stale per-VM ACEs are
        removed -- inherited ACEs, admin/SYSTEM, the all-VMs group
        (S-1-5-83-0), capability SIDs, and live VMs' own ACEs stay, so it is
        safe to run while other VMs use the file. Set-Acl writes a SMALLER
        descriptor, so it succeeds even when the on-disk ACL is already at
        the limit. See https://yuruna.link/vmconfig#hyper-v-iso-ace-bloat.
    .OUTPUTS
        System.Int32 -- the number of stale per-VM ACEs removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not $IsWindows) { return 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }

    # A specific VM's virtual account is S-1-5-83-1-<RID derived from its
    # GUID>; the all-VMs group is S-1-5-83-0 and must be preserved.
    $perVmSidPrefix = 'S-1-5-83-1-'

    # Live set: translate each existing VM's virtual-account name to its SID.
    # If ANY translation fails we cannot prove which ACEs are stale, so we
    # abort rather than risk purging a live VM's access.
    $liveSids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($vm in (Hyper-V\Get-VM -ErrorAction Stop)) {
            $acct = "NT VIRTUAL MACHINE\$($vm.Id.Guid)"
            $sid  = ([System.Security.Principal.NTAccount]$acct).Translate([System.Security.Principal.SecurityIdentifier]).Value
            [void]$liveSids.Add($sid)
        }
    } catch {
        Write-Warning "Remove-OrphanedVMFileAccess: could not enumerate/translate live VM accounts ($($_.Exception.Message)); skipping ACL cleanup for '$Path' to avoid removing a live VM's access."
        return 0
    }

    $acl = Get-Acl -LiteralPath $Path
    $staleSids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in $acl.Access) {
        if ($rule.IsInherited) { continue }
        # Normalize to a SID string -- the name form for a deleted VM still
        # translates because the SID is derived from the GUID, not a lookup.
        $sidVal = $null
        try {
            $sidVal = if ($rule.IdentityReference -is [System.Security.Principal.SecurityIdentifier]) {
                $rule.IdentityReference.Value
            } else {
                $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
            }
        } catch { continue }   # un-translatable, non-VM principal -- leave it
        if ($sidVal -like "$perVmSidPrefix*" -and -not $liveSids.Contains($sidVal)) {
            [void]$staleSids.Add($sidVal)
        }
    }

    if ($staleSids.Count -eq 0) { return 0 }

    if ($PSCmdlet.ShouldProcess($Path, "Remove $($staleSids.Count) stale per-VM access ACE(s)")) {
        foreach ($s in $staleSids) {
            # Purge by SID so both stored forms (raw SID and resolved
            # NT VIRTUAL MACHINE\<guid> name) for that account are removed.
            $acl.PurgeAccessRules([System.Security.Principal.SecurityIdentifier]$s)
        }
        try {
            Set-Acl -LiteralPath $Path -AclObject $acl
        } catch {
            Write-Warning "Remove-OrphanedVMFileAccess: failed to write trimmed ACL for '$Path' ($($_.Exception.Message))."
            return 0
        }
    }
    return $staleSids.Count
}

# --- REGION: Exports

Export-ModuleMember -Function `
    New-VM, Start-VM, Stop-VM, Stop-VMForce, Remove-VM, Rename-VM, Get-VMState, Get-VMName, `
    Save-VMDiskSnapshot, Restore-VMDiskSnapshot, Test-VMDiskSnapshot, `
    Test-VMConsoleOpen, Restart-VMConsole, `
    Get-Image, Get-ImagePath, `
    Send-Text, Send-Key, Send-Click, Get-VMScreenshot, Get-VMConsoleHandle, `
    Wait-VMIp, Get-VMIp, Get-VMMac, `
    Get-ExternalNetwork, New-ExternalNetwork, Test-CacheVMOnExternalNetwork, Repair-YurunaExternalSwitch, `
    Add-PortMap, Remove-PortMap, Get-BestHostIp, Get-GuestReachableHostIp, `
    Test-CachingProxyServiceAvailable, Get-CachingProxyServiceVmIp, `
    Set-HostProxy, Clear-HostProxy, Remove-HostProxy, Get-HostProxyBackupPath, Assert-Virtualization, `
    `
    CreateIso, Get-CacheVmCandidateIp, `
    Get-OrCreateYurunaExternalSwitch, Test-WindowsUplinkNotBridgeable, Test-YurunaExternalSwitchUplink, Test-CachingProxyServicePort, Invoke-YurunaExternalArpProbe, `
    Test-CacheVmOnYurunaExternalSwitch, Get-WorkingCachingProxyServiceUrl, `
    Test-DownloadAlreadyCurrent, Resolve-CacheHostIp, `
    Save-CachedHttpUri, Assert-HyperVEnabled, `
    Confirm-HyperVVMCreated, Stop-HyperVVMForce, Remove-HyperVTestVM, `
    Start-HyperVVM, Stop-HyperVVM, Request-HyperVVMShutdown, Confirm-HyperVVMStarted, `
    Resolve-VMConnectAnotherUserDialog, Restart-HyperVConnect, `
    Test-WindowsProxyIsYurunaManaged, Read-WindowsProxyState, Invoke-WinInetRefresh, `
    Set-WindowsHostProxy, Restore-WindowsHostProxy, Disable-WindowsHostProxy, Remove-WindowsHostProxy, `
    Get-CachingProxyServiceForwarderScriptPath, Get-PwshExePath, Get-WindowsForwarderPidPath, `
    Stop-WindowsCachingProxyServiceForwarder, Start-WindowsCachingProxyServiceForwarder, Add-CachingProxyServiceFirewallRule, `
    Get-WindowsForwarderPidPort, Get-YurunaMappedPortFromFirewall, `
    Remove-SinglePortMap, Clear-AllCachingProxyServicePortMapping, `
    Get-HyperVScreenshot, Get-HyperVWindowScreenshot, `
    Remove-OrphanedVMFileAccess

# Contract-coverage assertion: warns at load time if the export block
# above drifts away from the canonical Yuruna.Host contract. See
# host/Yuruna.Host.Contract.psm1 for the verb list and rationale.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'Yuruna.Host.Contract.psm1') -Force -DisableNameChecking
$null = Assert-YurunaHostContractCoverage -HostType 'windows.hyper-v' -ExportedFunction @(
    'New-VM','Start-VM','Stop-VM','Stop-VMForce','Remove-VM','Rename-VM','Get-VMState','Get-VMName',
    'Save-VMDiskSnapshot','Restore-VMDiskSnapshot','Test-VMDiskSnapshot',
    'Test-VMConsoleOpen','Restart-VMConsole',
    'Get-Image','Get-ImagePath',
    'Send-Text','Send-Key','Send-Click','Get-VMScreenshot','Get-VMConsoleHandle',
    'Wait-VMIp','Get-VMIp','Get-VMMac',
    'Get-ExternalNetwork','New-ExternalNetwork','Test-CacheVMOnExternalNetwork',
    'Add-PortMap','Remove-PortMap','Get-BestHostIp','Get-GuestReachableHostIp',
    'Test-CachingProxyServiceAvailable','Get-CachingProxyServiceVmIp',
    'Set-HostProxy','Clear-HostProxy','Remove-HostProxy','Get-HostProxyBackupPath','Assert-Virtualization'
)

# Load-time guard for the cache-download wrapper precedence. The image helpers
# (Save-ImageWithChecksum / Save-UbuntuServerImage) feature-detect Save-CachedHttpUri
# BY NAME and invoke it with only -Uri/-OutFile, so this driver's 2-param wrapper
# must win the command-table slot over the shared 3-param
# Yuruna.HostDownload\Save-CachedHttpUri. If an import-order change flips that
# precedence the cache-discovery closure is dropped and downloads silently bypass
# the squid cache (direct, no error) -- surface that regression loudly here.
$__yurunaCacheDownloadCmd = Get-Command -Name Save-CachedHttpUri -ErrorAction SilentlyContinue
if (-not $__yurunaCacheDownloadCmd) {
    Write-Warning "Yuruna.Host (windows.hyper-v): Save-CachedHttpUri is not on the command table after load; image downloads cannot route through the squid cache."
} elseif ($__yurunaCacheDownloadCmd.Parameters.ContainsKey('ResolveCacheHostIp')) {
    Write-Warning "Yuruna.Host (windows.hyper-v): Save-CachedHttpUri resolves to the shared Yuruna.HostDownload implementation (mandatory -ResolveCacheHostIp), not this driver's cache-injecting wrapper; image downloads will silently bypass the squid cache. Check module import order."
}
