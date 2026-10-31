<#PSScriptInfo
.VERSION 2026.10.31
.GUID 422408a8-20aa-41db-8fbb-13e90b2c0264
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host ubuntu.kvm driver network bridge
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

# --- REGION: External network helpers
# Internal. Returns the interface name carrying the default IPv4 route, or
# $null if none. Filters out the NIC if it's already a bridge port whose
# master is the one we're about to (re-)create; matches "what's the WAN-
# facing physical NIC of this host" semantically.
# --- REGION: Get-YurunaDefaultRouteIface
function Get-YurunaDefaultRouteIface {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $jsonLines = & ip -j -4 route show default 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $jsonLines) { return $null }
    try {
        $routes = ($jsonLines -join "`n") | ConvertFrom-Json -ErrorAction Stop
    } catch { $null = $_; return $null }
    $first = @($routes) | Where-Object { $_.dev } | Select-Object -First 1
    if (-not $first) { return $null }
    return [string]$first.dev
}

# Internal. True iff $Iface is a wireless (802.11) interface. The kernel
# exposes /sys/class/net/<iface>/wireless for Wi-Fi NICs; the presence
# of the directory is a stable signal across drivers.
function Test-YurunaIfaceIsWifi {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Iface)
    return (Test-Path "/sys/class/net/$Iface/wireless")
}

# See https://yuruna.link/42e5cdfd-0017
function Get-YurunaIfaceBridgeBlocker {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Iface)
    if ($Iface -notmatch '^[A-Za-z0-9_.-]+$') {
        return "its name contains characters that are unsafe to embed in netplan/nmcli configuration"
    }
    $typePath = "/sys/class/net/$Iface/type"
    if (Test-Path -LiteralPath $typePath) {
        $ifType = "$(Get-Content -LiteralPath $typePath -ErrorAction SilentlyContinue | Select-Object -First 1)".Trim()
        # ARPHRD_ETHER == 1; anything else (tun/wireguard/ppp/...) cannot
        # be a bridge port.
        if ($ifType -ne '1') { return "it is not an Ethernet-framed interface (ARPHRD type $ifType)" }
    }
    if (Test-Path -LiteralPath "/sys/class/net/$Iface/bonding") {
        return "it is a bond master (bonds need their own netplan 'bonds:' section)"
    }
    $ueventPath = "/sys/class/net/$Iface/uevent"
    if (Test-Path -LiteralPath $ueventPath) {
        $devtype = @(Get-Content -LiteralPath $ueventPath -ErrorAction SilentlyContinue) |
            Where-Object { $_ -match '^DEVTYPE=(.+)$' } | Select-Object -First 1
        if ($devtype -match '^DEVTYPE=(vlan|bond)$') {
            return "it is a $($matches[1]) device (declare it in its own netplan section, not as a plain NIC)"
        }
    }
    return ''
}

# Internal. If $Iface is already a slave of a Linux bridge, return the
# bridge name; otherwise $null. /sys/class/net/<iface>/master is the
# canonical kernel pointer for bridge membership.
function Get-YurunaIfaceBridgeMaster {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Iface)
    $masterLink = "/sys/class/net/$Iface/master"
    if (-not (Test-Path $masterLink)) { return $null }
    $target = & readlink -f $masterLink 2>$null
    if (-not $target) { return $null }
    $candidate = Split-Path -Leaf $target
    # Confirm it actually IS a bridge (vs other master types like bond).
    if (Test-Path "/sys/class/net/$candidate/bridge") { return $candidate }
    return $null
}

# Internal. The MAC address currently on $Iface, or '' when unreadable.
# /sys/class/net/<iface>/address is the kernel's canonical view.
function Get-YurunaNicMac {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Iface)
    $macPath = "/sys/class/net/$Iface/address"
    if (-not (Test-Path -LiteralPath $macPath)) { return '' }
    $mac = (Get-Content -LiteralPath $macPath -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $mac) { return '' }
    return "$mac".Trim()
}

# Internal. The Linux bridge name a libvirt network is backed by
# (its <bridge name='...'/> element), or $null when the network has no
# bridge element or virsh cannot dump it.
function Get-YurunaLibvirtNetworkBridge {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$NetworkName)
    $xmlLines = Invoke-Virsh -VirshArgs @('net-dumpxml', $NetworkName)
    foreach ($line in $xmlLines) {
        if ($line -match "<bridge\s+name='([^']+)'") { return $matches[1] }
    }
    return $null
}

# --- REGION: Test-YurunaLibvirtNetworkIsBridgeMode
function Test-YurunaLibvirtNetworkIsBridgeMode {
    <#
    .SYNOPSIS
        Return true only when a readable libvirt network uses host bridging.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$NetworkName)
    # NAT, routed, and isolated networks also have a libvirt-owned bridge.
    # See https://yuruna.link/42e220c4-0004
    $xmlLines = Invoke-Virsh -VirshArgs @('net-dumpxml', $NetworkName)
    if ($LASTEXITCODE -ne 0) { return $false }
    try {
        $network = [xml]([string]::Join("`n", @($xmlLines)))
        return [bool]($network.network.forward.mode -eq 'bridge')
    } catch {
        Write-Debug "Test-YurunaLibvirtNetworkIsBridgeMode: could not read '$NetworkName': $($_.Exception.Message)"
    }
    return $false
}

# See https://yuruna.link/42e220c4-0004
function Get-YurunaNicActiveProfileName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Nic)
    if (-not (Get-Command nmcli -ErrorAction SilentlyContinue)) { return $Nic }
    $activeName = (& nmcli -t -f NAME,DEVICE connection show --active 2>$null |
                   Where-Object { $_ -match "^([^:]+):$([regex]::Escape($Nic))`$" } |
                   ForEach-Object { ($_ -split ':', 2)[0] } |
                   Select-Object -First 1)
    if ($activeName) { return $activeName }
    return $Nic
}

# Internal, pure. The operator rollback recipe for a (half-)built
# bridge. Ordered so connectivity is RESTORED before artifacts are torn
# down: an operator following it over SSH must not lose the session at
# step 1 with the restoring steps still unrun (activating the NIC's own
# profile detaches it from the bridge, so the later deletes are safe).
function Get-YurunaBridgeRollbackRecipe {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BridgeName,
        [Parameter(Mandatory)][string]$Nic,
        [Parameter(Mandatory)][string]$NicProfile
    )
    return @"
Rollback (run ALL of these, in this order -- connectivity first, so an
SSH session survives; each is a no-op when its artifact is absent):
  sudo nmcli device set '$Nic' managed yes
  sudo nmcli connection modify '$NicProfile' connection.autoconnect yes
  sudo nmcli connection up '$NicProfile'
  sudo nmcli connection delete '$BridgeName' '$BridgeName-slave-$Nic'
  sudo rm -f /etc/netplan/99-yuruna-external.yaml && sudo netplan apply
  sudo ip link delete '$BridgeName'
"@
}

# Internal. Stop (never undefine) $NetworkName when it is running --
# called when its backing host bridge is unusable and was not rebuilt.
# Get-ExternalNetwork only offers ACTIVE networks to guests, so stopping
# is what actually steers them to the NAT 'default' fallback instead of
# stranding them on a bridge that can never DHCP.
function Stop-YurunaUnusableExternalNetwork {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private helper invoked from New-YurunaExternalNetwork''s failure paths; the public caller already gates via SupportsShouldProcess. Adding ShouldProcess here would double-prompt.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$NetworkName)
    $running = Invoke-Virsh -VirshArgs @('net-list', '--name')
    if ($running -contains $NetworkName) {
        Invoke-Virsh -VirshArgs @('net-destroy', $NetworkName) | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_16656037757bbcc2' -Arguments @{ networkName = "$NetworkName" })
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f29ceda33915a5d0' -Arguments @{ networkName = "$NetworkName"; lASTEXITCODE = "$LASTEXITCODE" })
        }
    } else {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4991467056bc0e31' -Arguments @{ networkName = "$NetworkName" })
    }
}

# Internal. True iff NetworkManager is installed AND running. Two checks
# rather than one: `command -v nmcli` can be present without NM active
# (the binary survives an `apt purge network-manager-runtime`), and a
# running NM is what we need to actually create+activate the bridge.
function Test-YurunaNetworkManagerActive {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Get-Command nmcli -ErrorAction SilentlyContinue)) { return $false }
    $state = & nmcli -t -f RUNNING general 2>$null
    return ("$state".Trim() -eq 'running')
}

# See https://yuruna.link/42e5cdfd-0017
function Test-YurunaNicManagedByNetworkManager {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Nic,
        [Parameter()][AllowNull()][string[]]$StatusLines
    )
    if ($null -eq $StatusLines) {
        if (-not (Get-Command nmcli -ErrorAction SilentlyContinue)) { return $false }
        $StatusLines = @(& nmcli -t -f DEVICE,STATE device status 2>$null)
    }
    # Terse rows are 'DEVICE:STATE' (e.g. 'eno1:connected', 'eno1:unmanaged').
    $line = @($StatusLines) | Where-Object { $_ -match "^$([regex]::Escape($Nic)):" } | Select-Object -First 1
    if (-not $line) { return $false }          # NM doesn't list it -> NM doesn't manage it
    # Every NM device state EXCEPT 'unmanaged' (unavailable/disconnected/
    # connecting/connected/...) means NM will bind + build on the NIC.
    return ($line -notmatch ':unmanaged(\b|$)')
}

function Test-NetworkManagerCrashedRecently {
    <#
    .SYNOPSIS
        Returns $true if NetworkManager core-dumped within the last
        $WithinMinutes minutes. Read-only -- queries the systemd journal
        only (no sudo; journal read works for any 'adm'/'systemd-journal'
        group member).
    .DESCRIPTION
        NetworkManager 1.54.x can hit an internal settings-layer
        assertion (nm:ERROR:.../nm-settings-utils.c: assertion failed)
        while a Linux bridge is being created via nmcli, and then SIGABRT
        itself (systemd records 'code=dumped, status=6/ABRT'). That
        crash is what raises Ubuntu's apport "system problem detected"
        dialog. Once it has happened, re-running the same nmcli sequence
        just crashes NM again. Callers use this to SKIP the nmcli bridge
        path and fall back to libvirt NAT instead of re-triggering the
        crash + another apport report.
    .PARAMETER WithinMinutes
        Look-back window. Default 60. Use a short window (~3) right after
        an nmcli call to attribute a just-now failure to a NM crash.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([int]$WithinMinutes = 60)
    if (-not (Get-Command journalctl -ErrorAction SilentlyContinue)) { return $false }
    $hits = & journalctl -u NetworkManager --since "-${WithinMinutes}min" --no-pager 2>$null |
        Select-String -Pattern 'code=dumped|core-dump|nm-settings-utils\.c.*assertion'
    return (@($hits).Count -gt 0)
}

function Write-YurunaNmcliFailure {
    <#
    .SYNOPSIS
        Emit the right diagnosis for a failed nmcli call: distinguish a
        NetworkManager crash (its own bug -- the apport-dialog source)
        from a plain rejected request, and surface the verbatim nmcli
        output either way.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [object[]]$NmcliOutput = @()
    )
    if (Test-NetworkManagerCrashedRecently -WithinMinutes 3) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f723e2637a819ebc' -Arguments @{ operation = "$Operation" })
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d51d62e7c9ed3701')
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_77240278d57e7feb')
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_cb83aca140e41904')
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_7d3759d60761e085')
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4fcc5a4693566633')
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_91fb8bd5d3786902')
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_3f2bc91d0d5e444f')
    } else {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_eabfc8c3589f08a7' -Arguments @{ operation = "$Operation" })
        foreach ($l in @($NmcliOutput)) {
            if ("$l".Trim()) { Write-Warning "    $l" }
        }
    }
}

# See https://yuruna.link/42d69dfa-0020
# Callers invoke this ONLY when $Nic is not enslaved to $BridgeName, so
# nothing removed here can be carrying the host's connectivity: an
# uplink-less bridge forwards no traffic by construction.
# --- REGION: Clear-YurunaExternalBridgeResidue
function Clear-YurunaExternalBridgeResidue {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private helper invoked from New-YurunaExternalNetwork''s build path, which already gates via SupportsShouldProcess. Adding ShouldProcess here would double-prompt.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Nic,
        [Parameter(Mandatory)][string]$BridgeName
    )
    # See https://yuruna.link/42e5cdfd-0018
    if ((Get-YurunaIfaceBridgeMaster -Iface $Nic) -eq $BridgeName) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_51d154571ef1e845' -Arguments @{ nic = "$Nic"; bridgeName = "$BridgeName" })
        return
    }
    if (Test-Path -LiteralPath "/sys/class/net/$Nic/bridge") {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_12c1c9adfaecb9b1' -Arguments @{ nic = "$Nic" })
        return
    }
    if (Test-Path -LiteralPath "/sys/class/net/$BridgeName") {
        if (Test-YurunaBridgeHasUplink -BridgeName $BridgeName) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_9cceb6fb2d6d1d12' -Arguments @{ bridgeName = "$BridgeName"; nic = "$Nic" })
            return
        }
        $defRouteDev = Get-YurunaDefaultRouteIface
        if ($defRouteDev -eq $BridgeName) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_bd884891a3af3bba' -Arguments @{ bridgeName = "$BridgeName" })
            return
        }
    }

    # 1. Stale NM profiles (a previous nmcli attempt, either as the picked
    #    backend or as the pre-fallback half of a previous run).
    if (Get-Command nmcli -ErrorAction SilentlyContinue) {
        $staleConns = @(& nmcli -t -f NAME connection show 2>$null) |
            Where-Object { $_ -eq $BridgeName -or $_ -like "$BridgeName-slave-*" }
        foreach ($sc in $staleConns) {
            Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_b71b7d147e26ec7a' -Arguments @{ sc = "$sc" })
            & sudo nmcli connection delete $sc 2>&1 | ForEach-Object { Write-Verbose "$_" }
        }
    }

    # See https://yuruna.link/42e5cdfd-0018
    $netplanPath = '/etc/netplan/99-yuruna-external.yaml'
    $sweptNetplan = $false
    if ((Test-Path -LiteralPath $netplanPath) -and (Get-Command netplan -ErrorAction SilentlyContinue)) {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_14a5b48380ba2726' -Arguments @{ netplanPath = "$netplanPath" })
        & sudo mv -f $netplanPath "$netplanPath.bak" 2>&1 | ForEach-Object { Write-Verbose "$_" }
        & sudo netplan generate 2>&1 | ForEach-Object { Write-Verbose "$_" }
        & sudo udevadm control --reload 2>&1 | ForEach-Object { Write-Verbose "$_" }
        & sudo udevadm trigger --subsystem-match=net --action=change 2>&1 | ForEach-Object { Write-Verbose "$_" }
        if (Get-Command networkctl -ErrorAction SilentlyContinue) {
            & sudo networkctl reload 2>&1 | ForEach-Object { Write-Verbose "$_" }
        }
        $sweptNetplan = $true
    }

    # 3. Stale kernel bridge device. The latches above guarantee this
    #    device carries no host traffic; any taps still attached belong
    #    to guests that have no connectivity anyway. Neither `netplan
    #    apply` nor networkd removes a netdev whose definition vanished,
    #    so an explicit delete is the only way to clear it.
    if (Test-Path -LiteralPath "/sys/class/net/$BridgeName") {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_58d831021de668db' -Arguments @{ bridgeName = "$BridgeName" })
        & sudo ip link delete $BridgeName 2>&1 | ForEach-Object { Write-Verbose "$_" }
        if (Test-Path -LiteralPath "/sys/class/net/$BridgeName") {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4b42f77ed64dee7d' -Arguments @{ bridgeName = "$BridgeName" })
        }
    }

    # See https://yuruna.link/42e5cdfd-0018
    if ($sweptNetplan -and (Test-YurunaNetworkManagerActive)) {
        $nicState = @(& nmcli -t -f DEVICE,STATE device status 2>$null) |
            Where-Object { $_ -match "^$([regex]::Escape($Nic)):unmanaged(\b|$)" }
        if ($nicState) {
            $nicInOtherYaml = $false
            $otherYamls = @(Get-ChildItem -Path '/etc/netplan' -Filter '*.yaml' -ErrorAction SilentlyContinue)
            foreach ($f in $otherYamls) {
                $hit = & sudo grep -l -- $Nic $f.FullName 2>$null
                if ($hit) { $nicInOtherYaml = $true; break }
            }
            if (-not $nicInOtherYaml) {
                Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_5365a43db3f3d3f2' -Arguments @{ nic = "$Nic" })
                & sudo nmcli device set $Nic managed yes 2>&1 | ForEach-Object { Write-Verbose "$_" }
            }
        }
    }
}

# Internal. True iff $BridgeName has at least one physical (non-tap)
# port. Tap ports (vnetN/tapN) are guest-side only; without a physical
# port the bridge has no path to the upstream LAN/DHCP server.
function Test-YurunaBridgeHasUplink {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$BridgeName)
    $brifDir = "/sys/class/net/$BridgeName/brif"
    if (-not (Test-Path -LiteralPath $brifDir)) { return $false }
    $ports = @(Get-ChildItem -LiteralPath $brifDir -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notmatch '^(vnet|tap)\d+$' })
    return ($ports.Count -gt 0)
}

# Internal. Wait until $BridgeName has a physical uplink port -- or, when
# -Nic is given, until that specific NIC is enslaved. $true on success.
# Wall-clock deadline (not an iteration count): the per-iteration probes
# add their own latency, so a counted loop would stretch past the budget.
function Wait-YurunaBridgeUplink {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$BridgeName,
        [string]$Nic,
        [int]$TimeoutSeconds = 10
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        if ($Nic) {
            if (Test-Path -LiteralPath "/sys/class/net/$BridgeName/brif/$Nic") { return $true }
        } elseif (Test-YurunaBridgeHasUplink -BridgeName $BridgeName) {
            return $true
        }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Milliseconds 500
    }
}

# See https://yuruna.link/42d69dfa-001f
# --- REGION: Repair-YurunaExternalBridgeSlave
function Repair-YurunaExternalBridgeSlave {
    <#
    .SYNOPSIS
        Probe the host bridge behind a libvirt network; heal a missing
        physical uplink, or report that the caller must rebuild.
    .DESCRIPTION
        A previous bring-up can leave the bridge half-built regardless of
        backend: the NM bridge connection up but the slave never
        activated, or the netplan definition applied but the NIC never
        released by NetworkManager. Either way the libvirt network looks
        fine to virsh while guests on it never get DHCP leases, because
        the bridge has no path to the upstream DHCP server. This probes
        /sys/class/net/<bridge>/brif for a physical (non-tap) port and,
        when it is missing, heals with the backend that owns the bridge:
          * netplan definition present -> release the NIC from
            NetworkManager if it still holds it, re-run `netplan apply`,
            and wait for enslavement;
          * otherwise -> activate the NM bridge-slave connection(s)
            whose connection.master is the bridge.
        Healing may briefly flap the host's LAN session (the NIC migrates
        onto the bridge), same as the original build.
    .OUTPUTS
        [string] 'healthy' (uplink present), 'healed' (uplink restored),
        or 'rebuild' (bridge device missing, or uplink unrecoverable --
        the caller must rebuild the bridge from scratch).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private helper invoked from New-YurunaExternalNetwork only when its idempotency branch detects a half-built bridge. The user-facing caller (Start-CachingProxyServiceVM.ps1) already opted in to network-changing behavior via New-YurunaExternalNetwork''s SupportsShouldProcess. Adding ShouldProcess here would double-prompt.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$NetworkName)

    # Only <forward mode='bridge'/> networks are backed by a host bridge
    # this module owns. NAT/routed/isolated networks also carry a
    # <bridge name='virbrN'/> element, but that bridge is libvirt's own
    # (dnsmasq serves DHCP on it; no physical uplink by design) --
    # probing or rebuilding it would tear a WORKING network down.
    if (-not (Test-YurunaLibvirtNetworkIsBridgeMode -NetworkName $NetworkName)) { return 'healthy' }

    $bridgeName = Get-YurunaLibvirtNetworkBridge -NetworkName $NetworkName
    if (-not $bridgeName) { return 'healthy' }   # no bridge element; nothing to probe

    if (-not (Test-Path -LiteralPath "/sys/class/net/$bridgeName/brif")) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_c77fa353349289bd' -Arguments @{ bridgeName = "$bridgeName"; networkName = "$NetworkName" })
        return 'rebuild'
    }
    if (Test-YurunaBridgeHasUplink -BridgeName $bridgeName) { return 'healthy' }

    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_a9b466db2e20d135' -Arguments @{ bridgeName = "$bridgeName" })

    # Heal 1: the bridge is netplan-declared. The usual reason the uplink
    # is missing here is that NetworkManager never released the NIC to
    # systemd-networkd, so release it explicitly, then re-apply. The
    # netplan file is root-owned 600 -- read it via sudo.
    $netplanPath = '/etc/netplan/99-yuruna-external.yaml'
    if ((Test-Path -LiteralPath $netplanPath) -and (Get-Command netplan -ErrorAction SilentlyContinue)) {
        $netplanText = (& sudo cat $netplanPath 2>$null) -join "`n"
        if ($netplanText -match [regex]::Escape($bridgeName)) {
            $nic = $null
            if ($netplanText -match 'interfaces:\s*\[\s*([^\]\s,]+)') { $nic = $matches[1] }
            # See https://yuruna.link/42e220c4-0004
            if ($nic) {
                $nicMac = Get-YurunaNicMac -Iface $nic
                $brMac  = Get-YurunaNicMac -Iface $bridgeName
                if ($nicMac -and $brMac -and ($nicMac -ne $brMac)) {
                    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_c319018d146decfd' -Arguments @{ bridgeName = "$bridgeName"; brMac = "$brMac"; nic = "$nic"; nicMac = "$nicMac" })
                    return 'rebuild'
                }
            }
            $released = $false
            if ($nic -and (Test-YurunaNicManagedByNetworkManager -Nic $nic)) {
                Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_f303b03da5066386' -Arguments @{ nic = "$nic" })
                & sudo nmcli device set $nic managed no 2>&1 | ForEach-Object { Write-Verbose "$_" }
                $released = $true
            }
            Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_dd5116399fa7eb32' -Arguments @{ netplanPath = "$netplanPath" })
            & sudo netplan apply 2>&1 | ForEach-Object { Write-Verbose "$_" }
            if (Wait-YurunaBridgeUplink -BridgeName $bridgeName -Nic $nic) {
                Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_99d1b419322487c4' -Arguments @{ bridgeName = "$bridgeName"; networkName = "$NetworkName" })
                return 'healed'
            }
            # See https://yuruna.link/42e220c4-0004
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4496ea1417ee8739')
            & sudo mv -f $netplanPath "$netplanPath.bak" 2>&1 | ForEach-Object { Write-Verbose "$_" }
            & sudo netplan apply 2>&1 | ForEach-Object { Write-Verbose "$_" }
            if ($released) {
                & sudo nmcli device set $nic managed yes 2>&1 | ForEach-Object { Write-Verbose "$_" }
                & sudo nmcli device connect $nic 2>&1 | ForEach-Object { Write-Verbose "$_" }
            }
            # Give the restored config a moment to bring the default
            # route back, so the rebuild path can resolve the NIC.
            $routeDeadline = (Get-Date).AddSeconds(20)
            while (((Get-Date) -lt $routeDeadline) -and -not (Get-YurunaDefaultRouteIface)) {
                Start-Sleep -Seconds 1
            }
            return 'rebuild'
        }
    }

    # Heal 2: NM-built bridge -- activate the bridge-slave connection(s)
    # whose connection.master equals our bridge. `nmcli -g
    # connection.master c show <name>` returns just the value (empty for
    # non-slaves), avoiding colon-escaping issues in NAME fields.
    if (Test-YurunaNetworkManagerActive) {
        $slaveConns = @()
        $allNames = @(& nmcli -g NAME c show 2>$null | Where-Object { $_ })
        foreach ($n in $allNames) {
            $master = (& nmcli -g connection.master c show $n 2>$null | Select-Object -First 1)
            if ($master -and ("$master".Trim() -eq $bridgeName)) {
                $slaveConns += $n
            }
        }
        foreach ($slave in $slaveConns) {
            & sudo nmcli connection up $slave 2>&1 | ForEach-Object { Write-Verbose "$_" }
            if (($LASTEXITCODE -eq 0) -and (Wait-YurunaBridgeUplink -BridgeName $bridgeName)) {
                Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_57d04989b79f71fc' -Arguments @{ slave = "$slave"; bridgeName = "$bridgeName"; networkName = "$NetworkName" })
                return 'healed'
            }
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d9f5e63dbaea5cc8' -Arguments @{ slave = "$slave" })
        }
    }

    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d3b82b9cf50e1dd4' -Arguments @{ bridgeName = "$bridgeName" })
    return 'rebuild'
}

<#
.SYNOPSIS
    Create a host-side Linux bridge + matching libvirt network so a guest
    on this network DHCPs onto the host's LAN and is reachable by remote
    LAN clients (mirrors the Hyper-V Yuruna-External vSwitch role).

.DESCRIPTION
    Idempotent. If $NetworkName is already defined in libvirt, ensures
    it's active + autostart, then runs Repair-YurunaExternalBridgeSlave
    to self-heal a half-built host bridge (uplink NIC never enslaved --
    DHCP loops, guests get no lease). The self-heal is a no-op on a
    healthy bridge; on a broken one it re-attaches the uplink through
    whichever backend owns the bridge (netplan re-apply or NM slave
    activation), which may briefly flap the host's LAN session -- and
    when even that is impossible it falls THROUGH to rebuild the bridge
    from scratch. Otherwise (network not yet defined):

      1. Resolves the host's default-route NIC.
      2. Refuses Wi-Fi (most APs filter frames for the bridge-side MAC).
      3. Detects whether the NIC is already a bridge port -- reuses
         that bridge if so (no host networking change).
      4. Else sweeps the residue of any previous half-built attempt
         (stale NM profiles, stale netplan file, stale bridge device --
         each makes a fresh build fail differently), then creates a new
         bridge ($BridgeName) and moves the NIC onto it via nmcli
         (preferred) or netplan (fallback). THIS CAUSES A BRIEF NETWORK
         OUTAGE while DHCP migrates IP from the NIC to the bridge --
         callers running over SSH on this NIC should expect their
         session to drop and require reconnect.
      5. Defines + starts a libvirt network of type bridge.

    On failure the function returns $null after rolling back the
    half-built bridge state, and -- when the network was already
    defined -- stops the network so guests fall back to NAT 'default'
    instead of being attached to a bridge with no uplink.

.OUTPUTS
    The libvirt network name on success ($NetworkName), or $null.
#>
function Get-YurunaExternalNetworkPlan {
    <#
    .SYNOPSIS
        Read-only preview of what New-YurunaExternalNetwork WOULD do, so a
        caller can explain the host-networking impact to the operator
        up front -- before any change is made -- and decide whether to
        proceed. Has NO side effects: only queries virsh + the host's
        network interface state.
    .DESCRIPTION
        Mirrors steps 1-3 of New-YurunaExternalNetwork (idempotency
        check, default-route NIC resolution, already-bridged check)
        without performing step 4 (the actual bridge build). Lets
        Start-CachingProxyServiceVM.ps1 print the brief-network-outage warning at
        the very start of the run instead of mid-way, and proceed in one
        shot with no ShouldProcess prompt.
    .OUTPUTS
        [hashtable] with keys:
          Action      'reuse-network' | 'reuse-bridge' | 'create-bridge'
                      | 'fallback-nat'
          NetworkName libvirt network name
          BridgeName  Linux bridge name (existing or to-be-created)
          Nic         default-route interface, or $null
          WillChangeHostNetworking  $true only for 'create-bridge'
          CanBridge   $false when a LAN-routable bridge is impossible
                      (no default route, or Wi-Fi NIC) -- the cache VM
                      then falls back to NAT 'default' (host-only),
                      which is degraded but NOT a hard failure
          Explanation operator-facing multi-line description
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$NetworkName = 'yuruna-external',
        [string]$BridgeName = 'yuruna-br0'
    )

    $plan = @{
        Action                   = $null
        NetworkName               = $NetworkName
        BridgeName                = $BridgeName
        Nic                       = $null
        WillChangeHostNetworking  = $false
        CanBridge                 = $true
        Explanation               = $null
    }

    # Step 1: libvirt network already defined?
    $defined = Invoke-Virsh -VirshArgs @('net-list', '--all', '--name')
    if ($defined -contains $NetworkName) {
        $plan.Action = 'reuse-network'
        # See https://yuruna.link/42e220c4-0004
        if (-not (Test-YurunaLibvirtNetworkIsBridgeMode -NetworkName $NetworkName)) {
            $plan.Explanation = "libvirt network '$NetworkName' already exists (not host-bridge-backed) -- it will be (re)started and set to autostart. No host networking change."
            return $plan
        }
        $xmlBridge = Get-YurunaLibvirtNetworkBridge -NetworkName $NetworkName
        if ($xmlBridge) { $plan.BridgeName = $xmlBridge }
        if (-not $xmlBridge -or (Test-YurunaBridgeHasUplink -BridgeName $xmlBridge)) {
            $plan.Explanation = "libvirt network '$NetworkName' already exists (bridge uplink verified) -- it will be (re)started and set to autostart. No host networking change."
        } else {
            $plan.WillChangeHostNetworking = $true
            $plan.Nic = Get-YurunaDefaultRouteIface
            $recipe = if ($plan.Nic) {
                Get-YurunaBridgeRollbackRecipe -BridgeName $plan.BridgeName -Nic $plan.Nic -NicProfile (Get-YurunaNicActiveProfileName -Nic $plan.Nic)
            } else {
                'Rollback recipe: see the Rollback section of host/ubuntu.kvm/guest.caching-proxy-service/README.md.'
            }
            $plan.Explanation = @"
libvirt network '$NetworkName' already exists but its backing bridge
('$($plan.BridgeName)') is missing or has NO LAN uplink -- this run will heal
or rebuild it, causing a brief network outage like the original build.

$recipe
"@
        }
        return $plan
    }

    # Step 2: default-route NIC.
    $nic = Get-YurunaDefaultRouteIface
    if (-not $nic) {
        $plan.Action      = 'fallback-nat'
        $plan.CanBridge   = $false
        $plan.Explanation = "No IPv4 default route on the host -- a bridged LAN network cannot be built. The cache VM will use libvirt's NAT 'default' network and be reachable from THIS host only."
        return $plan
    }
    $plan.Nic = $nic

    if (Test-YurunaIfaceIsWifi -Iface $nic) {
        $plan.Action      = 'fallback-nat'
        $plan.CanBridge   = $false
        $plan.Explanation = "Default-route NIC '$nic' is Wi-Fi. Linux bridges don't work over 802.11 STA mode (APs drop frames for MACs the radio didn't authenticate), so a bridged network is impossible here. The cache VM will use NAT 'default' (host-only). Use a wired connection for LAN exposure."
        return $plan
    }

    # Step 3: NIC already a bridge itself, or a bridge port?
    if (Test-Path -LiteralPath "/sys/class/net/$nic/bridge") {
        if (-not (Test-YurunaBridgeHasUplink -BridgeName $nic)) {
            $plan.Action      = 'fallback-nat'
            $plan.CanBridge   = $false
            $plan.Explanation = "Default-route interface '$nic' is a Linux bridge with NO physical uplink (stale route on a dead bridge). Roll it back per host/ubuntu.kvm/guest.caching-proxy-service/README.md, then re-run. Until then the cache VM will use NAT 'default' (host-only)."
            return $plan
        }
        $plan.Action      = 'reuse-bridge'
        $plan.BridgeName  = $nic
        $plan.Explanation = "Default-route interface '$nic' is itself a Linux bridge -- it will be reused as-is. No host networking change."
        return $plan
    }
    $existingBridge = Get-YurunaIfaceBridgeMaster -Iface $nic
    if ($existingBridge) {
        $plan.Action      = 'reuse-bridge'
        $plan.BridgeName  = $existingBridge
        $plan.Explanation = "NIC '$nic' is already a port of bridge '$existingBridge' -- it will be reused as-is. No host networking change."
        return $plan
    }

    # Step 3.5: only plain wired Ethernet can back the bridge.
    $blocker = Get-YurunaIfaceBridgeBlocker -Iface $nic
    if ($blocker) {
        $plan.Action      = 'fallback-nat'
        $plan.CanBridge   = $false
        $plan.Explanation = "Default-route NIC '$nic' cannot back a bridge: $blocker. The cache VM will use NAT 'default' (host-only)."
        return $plan
    }

    # Step 4: the bridge would have to be built. Before committing to
    # that, check whether NetworkManager has crashed recently -- if it
    # has, the nmcli bridge-build sequence is what crashed it (upstream
    # NM assertion bug), and re-running it just crashes NM again plus
    # raises another apport "system problem" dialog. Degrade to NAT.
    if ((Test-YurunaNetworkManagerActive) -and (Test-NetworkManagerCrashedRecently)) {
        $plan.Action      = 'fallback-nat'
        $plan.CanBridge   = $false
        $plan.Explanation = @"
NetworkManager has core-dumped recently on this host (visible in its
journal -- an internal NM assertion in nm-settings-utils.c, triggered by
nmcli bridge creation). That crash is what raised the Ubuntu 'system
problem detected' dialog.

Re-running the bridge build would just crash NetworkManager again, so it
will be SKIPPED. The cache VM will use libvirt's NAT 'default' network
(reachable from this host only) -- which is fully functional for guests
on this same host.

For LAN exposure despite the NM bug, either:
  * upgrade NetworkManager (the assertion is an upstream NM defect), or
  * define the 'yuruna-external' bridge manually (netplan) -- see
    host/ubuntu.kvm/guest.caching-proxy-service/README.md
"@
        return $plan
    }

    # See https://yuruna.link/42e220c4-0004
    $nicProfile = Get-YurunaNicActiveProfileName -Nic $nic
    $plan.Action                  = 'create-bridge'
    $plan.WillChangeHostNetworking = $true
    $plan.Explanation = @"
The host's default-route NIC ($nic) will be moved onto a new Linux bridge
($BridgeName). The bridge clones the NIC's MAC and requests a DHCP lease in
its place -- normally the SAME IP comes back -- causing a brief network
outage (typically 1-5 s on a responsive DHCP server). An SSH session over
$nic will likely drop and reconnect once the lease arrives. Leftovers from
any previous half-built attempt (NetworkManager profiles, the netplan file,
a stale '$BridgeName' device) are swept first.

$(Get-YurunaBridgeRollbackRecipe -BridgeName $BridgeName -Nic $nic -NicProfile $nicProfile)
"@
    return $plan
}

<#
.SYNOPSIS
    Define a libvirt bridged network ($NetworkName, default 'yuruna-external')
    backed by a host bridge ($BridgeName, default 'yuruna-br0') over the
    default-route NIC, so cache and test guests are reachable from the LAN.
.DESCRIPTION
    Idempotent and self-healing. On a host where the libvirt network is
    already defined, returns the network name immediately AFTER checking
    that its backing bridge has a working LAN uplink (a previous bring-up
    can leave the bridge half-built -- uplink NIC never enslaved -- and
    guests on it never get DHCP leases). If the bridge is half-built,
    Repair-YurunaExternalBridgeSlave re-attaches the uplink via the
    backend that owns the bridge; if the bridge is unrecoverable it is
    rebuilt from scratch under the same name.

    On a clean host:
      1. Resolves the default-route NIC (refuses Wi-Fi; bridges over Wi-Fi
         don't work for guest traffic the way they do over Ethernet).
      2. Sweeps stale residue from previous attempts, then builds the
         Linux bridge via NetworkManager (nmcli) or netplan -- picked by
         which backend manages the NIC. Brief LAN flap (1-5 s) while
         DHCP migrates from the bare NIC onto the bridge (the bridge
         clones the NIC's MAC, so the same IP normally comes back).
      3. Defines the libvirt network as a forward-mode=bridge interface
         pointing at the new host bridge, sets it autostart, starts it.

    All diagnostics are emitted via Write-Information / Write-Warning /
    Write-Error so the function's only success output stays the single
    network name string -- callers can safely assign with
    `$x = New-YurunaExternalNetwork`. A stray Write-Output would turn $x
    into a string[] and break downstream consumers (Get-ExternalNetwork
    compares against the exact name).
.PARAMETER NetworkName
    libvirt network name. Default 'yuruna-external'.
.PARAMETER BridgeName
    Host bridge interface name. Default 'yuruna-br0'.
.OUTPUTS
    [string] The network name on success (existing OR freshly created),
    $null when the operator opted out via -WhatIf or when the bridge
    build failed.
#>
function New-YurunaExternalNetwork {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    [OutputType([string])]
    param(
        [string]$NetworkName = 'yuruna-external',
        [string]$BridgeName = 'yuruna-br0'
    )

    # See https://yuruna.link/42e5cdfd-0019

    # --- REGION: Step 1: Reuse an already-defined network
    # Verify and repair the bridge uplink before reusing a defined network.
    # See https://yuruna.link/42e220c4-0004
    $defined = Invoke-Virsh -VirshArgs @('net-list', '--all', '--name')
    $netDefined = $defined -contains $NetworkName
    if ($netDefined) {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_56aa4cd4e8221b7b' -Arguments @{ networkName = "$NetworkName" })
        # Under -WhatIf report the network as-is BEFORE any mutation:
        # even (re)starting it counts -- a previous failed run may have
        # deliberately stopped it so guests fall back to NAT 'default',
        # and a preview must not re-arm a dead network.
        if ($WhatIfPreference) { return $NetworkName }
        $running = Invoke-Virsh -VirshArgs @('net-list', '--name')
        if (-not ($running -contains $NetworkName)) {
            Invoke-Virsh -VirshArgs @('net-start', $NetworkName) | Out-Null
        }
        Invoke-Virsh -VirshArgs @('net-autostart', $NetworkName) | Out-Null
        $repair = Repair-YurunaExternalBridgeSlave -NetworkName $NetworkName
        if ($repair -ne 'rebuild') { return $NetworkName }
        # Rebuild the bridge under the SAME name the network XML already
        # references, so the existing definition stays valid.
        $xmlBridge = Get-YurunaLibvirtNetworkBridge -NetworkName $NetworkName
        if ($xmlBridge) { $BridgeName = $xmlBridge }
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_afb798cdf6e697d6' -Arguments @{ bridgeName = "$BridgeName"; networkName = "$NetworkName" })
    }

    # --- REGION: Step 2: Resolve the default-route NIC
    # See https://yuruna.link/42e5cdfd-0019
    $nic = Get-YurunaDefaultRouteIface
    if (-not $nic) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_a3517dfa1bc5ed4b' -Arguments @{ networkName = "$NetworkName" })
        if ($netDefined) { Stop-YurunaUnusableExternalNetwork -NetworkName $NetworkName }
        return $null
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_6d08dce3222aea60' -Arguments @{ nic = "$nic" })

    if (Test-YurunaIfaceIsWifi -Iface $nic) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_7f672114891b8a1f' -Arguments @{ nic = "$nic" })
        if ($netDefined) { Stop-YurunaUnusableExternalNetwork -NetworkName $NetworkName }
        return $null
    }

    # --- REGION: Step 3: Reuse an already-bridged NIC
    # See https://yuruna.link/42e5cdfd-0019
    if (Test-Path -LiteralPath "/sys/class/net/$nic/bridge") {
        # Only a bridge that actually has its uplink is worth reusing. A
        # dead bridge can still hold a STALE default route (the kernel
        # keeps routes until the old lease ages out), and reusing it
        # would attach guests to a bridge that can never DHCP them --
        # while its real uplink NIC cannot be derived from the route.
        if (-not (Test-YurunaBridgeHasUplink -BridgeName $nic)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_e8acb2369dabbb2a' -Arguments @{ nic = "$nic" })
            if ($netDefined) { Stop-YurunaUnusableExternalNetwork -NetworkName $NetworkName }
            return $null
        }
        $existingBridge = $nic
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_3ec9f21facd50a2d' -Arguments @{ nic = "$nic" })
    } else {
        $existingBridge = Get-YurunaIfaceBridgeMaster -Iface $nic
        if ($existingBridge) {
            Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_cd47fb33aabc4897' -Arguments @{ nic = "$nic"; existingBridge = "$existingBridge" })
        }
    }
    if ($existingBridge) {
        $BridgeName = $existingBridge
    } else {
        # --- REGION: Step 4: Build the bridge
        # See https://yuruna.link/42e5cdfd-001a
        if ((Test-YurunaNetworkManagerActive) -and (Test-NetworkManagerCrashedRecently)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f1fbdb4d5f2e3394')
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b24cd356cf4d01e9')
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_699ff5d4716ff43f')
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_905604f5e2aa1bd4')
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_177c91d4127baf48')
            if ($netDefined) { Stop-YurunaUnusableExternalNetwork -NetworkName $NetworkName }
            return $null
        }

        # See https://yuruna.link/42e5cdfd-0019
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_fca7faa4a4ccb506' -Arguments @{ bridgeName = "$BridgeName"; nic = "$nic" })

        # Only plain wired Ethernet can be enslaved; bond/vlan/tunnel
        # devices (or a hostile interface name) would produce a broken
        # netplan yaml or an unactivatable nmcli slave profile.
        $blocker = Get-YurunaIfaceBridgeBlocker -Iface $nic
        if ($blocker) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d2fdb19108e5936a' -Arguments @{ nic = "$nic"; blocker = "$blocker" })
            if ($netDefined) { Stop-YurunaUnusableExternalNetwork -NetworkName $NetworkName }
            return $null
        }

        if (-not $PSCmdlet.ShouldProcess("$nic + $BridgeName", (Format-YurunaOperatorMessage -Key 'host.operator_614cae015ba6f4c9' -Arguments @{ nic = "$nic"; bridgeName = "$BridgeName" }))) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_69b2d5c408d306f0')
            if ($netDefined) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b82c5e55e5a0af3d' -Arguments @{ networkName = "$NetworkName" })
            }
            return $null
        }

        # Refresh the sudo timestamp BEFORE the outage window opens: the
        # build and its rollbacks issue sudo calls while host networking
        # flaps, where an expired timestamp would hang an unattended run
        # on an invisible password prompt. (Start-CachingProxyServiceVM primes the
        # cache up-front; this covers standalone callers and long gaps.)
        & sudo -v 2>&1 | Out-Null

        # See https://yuruna.link/42e5cdfd-0019
        Clear-YurunaExternalBridgeResidue -Nic $nic -BridgeName $BridgeName

        # See https://yuruna.link/42e5cdfd-001a
        $ok = $false
        if ((Test-YurunaNetworkManagerActive) -and (Test-YurunaNicManagedByNetworkManager -Nic $nic)) {
            $ok = New-YurunaBridgeViaNmcli -Nic $nic -BridgeName $BridgeName
            if (-not $ok) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b797b5ece4b87be2')
                $ok = New-YurunaBridgeViaNetplan -Nic $nic -BridgeName $BridgeName
            }
        } else {
            if (Test-YurunaNetworkManagerActive) {
                Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_ef067e7328ed1c14' -Arguments @{ nic = "$nic" })
            } else {
                Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_0e3e389832dbc97d')
            }
            $ok = New-YurunaBridgeViaNetplan -Nic $nic -BridgeName $BridgeName
        }
        if (-not $ok) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_12968989b3705520')
            if ($netDefined) { Stop-YurunaUnusableExternalNetwork -NetworkName $NetworkName }
            return $null
        }
    }

    # --- REGION: Step 5: Define and start the libvirt network
    # See https://yuruna.link/42e5cdfd-0019
    $needsDefine = -not $netDefined
    if ($netDefined) {
        $xmlBridgeNow = Get-YurunaLibvirtNetworkBridge -NetworkName $NetworkName
        if ($xmlBridgeNow -ne $BridgeName) {
            $running = Invoke-Virsh -VirshArgs @('net-list', '--name')
            if ($running -contains $NetworkName) {
                Invoke-Virsh -VirshArgs @('net-destroy', $NetworkName) | Out-Null
            }
            Invoke-Virsh -VirshArgs @('net-undefine', $NetworkName) | Out-Null
            $needsDefine = $true
        }
    }
    if ($needsDefine) {
        $xmlContent = @"
<network>
  <name>$NetworkName</name>
  <forward mode='bridge'/>
  <bridge name='$BridgeName'/>
</network>
"@
        $xmlPath = New-TemporaryFile
        try {
            Set-Content -LiteralPath $xmlPath.FullName -Value $xmlContent -NoNewline
            Invoke-Virsh -VirshArgs @('net-define', $xmlPath.FullName) | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_640df0d6dcbb011e' -Arguments @{ networkName = "$NetworkName"; lASTEXITCODE = "$LASTEXITCODE" })
                return $null
            }
        } finally {
            Remove-Item -LiteralPath $xmlPath.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    $running = Invoke-Virsh -VirshArgs @('net-list', '--name')
    if (-not ($running -contains $NetworkName)) {
        Invoke-Virsh -VirshArgs @('net-start', $NetworkName) | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_fae4b0ca3431a5dc' -Arguments @{ networkName = "$NetworkName"; lASTEXITCODE = "$LASTEXITCODE" })
            return $null
        }
    }
    Invoke-Virsh -VirshArgs @('net-autostart', $NetworkName) | Out-Null
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_191b359ad430e736' -Arguments @{ networkName = "$NetworkName"; bridgeName = "$BridgeName" })
    return $NetworkName
}

# Internal. Build $BridgeName via NetworkManager, with $Nic as a slave.
# Returns $true on success. Side effect: the active connection on $Nic
# is brought down and replaced by the bridge connection.
function New-YurunaBridgeViaNmcli {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private helper; the public New-YurunaExternalNetwork caller already gates via SupportsShouldProcess (see the "Move $nic onto new Linux bridge" ShouldProcess call). Adding a nested gate here would double-prompt.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Nic,
        [Parameter(Mandatory)][string]$BridgeName
    )
    $slaveConn = "$BridgeName-slave-$Nic"
    # Stale profiles/devices from previous attempts were already removed
    # by Clear-YurunaExternalBridgeResidue in the caller's build path.

    # Apply the MAC and DHCP client identity at profile creation: a later MAC
    # modify races device creation, and the MAC alone may not preserve the lease.
    # Keep autoconnect off until ordered activation completes; one uplink needs no STP.
    # See https://yuruna.link/4220a755-0027
    $nicMac = Get-YurunaNicMac -Iface $Nic
    if (-not $nicMac) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4f4646a7c84a5765' -Arguments @{ nic = "$Nic" })
    }

    # nmcli output is captured (not piped to Write-Verbose) so
    # Write-YurunaNmcliFailure can surface the verbatim error -- or
    # diagnose a NetworkManager crash -- on failure.
    $addArgs = @('connection', 'add', 'type', 'bridge',
        'ifname', $BridgeName, 'con-name', $BridgeName,
        'autoconnect', 'no',
        'bridge.stp', 'no',
        'ipv4.method', 'auto',
        'ipv4.dhcp-client-id', 'mac',
        'ipv4.dhcp-iaid', 'mac',
        'ipv4.dhcp-send-release', 'yes',
        'ipv6.method', 'auto')
    if ($nicMac) { $addArgs += @('bridge.mac-address', $nicMac) }
    $addOut = & sudo nmcli @addArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-YurunaNmcliFailure -Operation "add bridge connection '$BridgeName'" -NmcliOutput $addOut
        return $false
    }

    # Attach $Nic as a bridge-slave. This profile is the one NM will
    # auto-activate at boot to keep the bridge populated (autoconnect is
    # enabled at the end of the build).
    $slaveOut = & sudo nmcli connection add type bridge-slave ifname $Nic master $BridgeName `
        con-name $slaveConn autoconnect no 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-YurunaNmcliFailure -Operation "add bridge-slave connection for '$Nic'" -NmcliOutput $slaveOut
        # Delete the orphan bridge profile so a retry (or the netplan
        # fallback) starts clean.
        Clear-YurunaExternalBridgeResidue -Nic $Nic -BridgeName $BridgeName
        return $false
    }

    # See https://yuruna.link/42e5cdfd-001b
    $oldConn = (& nmcli -t -f NAME,DEVICE connection show --active 2>$null |
                Where-Object { $_ -match "^([^:]+):$Nic`$" } |
                ForEach-Object { ($_ -split ':', 2)[0] } |
                Select-Object -First 1)
    if ($oldConn -and ($oldConn -eq $slaveConn -or $oldConn -eq $BridgeName)) { $oldConn = $null }
    $restoreNic = {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d44e12c7bd610d38' -Arguments @{ nic = "$Nic" })
        if ($oldConn) {
            & sudo nmcli connection up $oldConn 2>&1 | ForEach-Object { Write-Verbose "$_" }
        } else {
            & sudo nmcli device connect $Nic 2>&1 | ForEach-Object { Write-Verbose "$_" }
        }
    }

    # See https://yuruna.link/42e5cdfd-001b
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_41630aabf4bd4c06' -Arguments @{ bridgeName = "$BridgeName" })
    $brUpOut = & sudo nmcli connection up $BridgeName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-YurunaNmcliFailure -Operation "bring up bridge '$BridgeName'" -NmcliOutput $brUpOut
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_266b54d6b96583f4')
        Clear-YurunaExternalBridgeResidue -Nic $Nic -BridgeName $BridgeName
        return $false
    }

    # See https://yuruna.link/42e5cdfd-001b
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_7c0523905b3ee3ea' -Arguments @{ nic = "$Nic"; bridgeName = "$BridgeName" })
    $slUpOut = & sudo nmcli connection up $slaveConn 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-YurunaNmcliFailure -Operation "enslave '$Nic' to bridge '$BridgeName'" -NmcliOutput $slUpOut
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_edfab703348ab819' -Arguments @{ nic = "$Nic" })
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_266b54d6b96583f4')
        Clear-YurunaExternalBridgeResidue -Nic $Nic -BridgeName $BridgeName
        & $restoreNic
        return $false
    }

    # Trust /sys, not nmcli's exit code, for the state that actually
    # matters: $Nic present in the bridge's port list.
    if (-not (Wait-YurunaBridgeUplink -BridgeName $BridgeName -Nic $Nic)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_028ad8fb2010c909' -Arguments @{ nic = "$Nic"; bridgeName = "$BridgeName" })
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_266b54d6b96583f4')
        Clear-YurunaExternalBridgeResidue -Nic $Nic -BridgeName $BridgeName
        & $restoreNic
        return $false
    }

    # The bridge verifiably holds its uplink -- NOW make the layout
    # boot-persistent: both profiles autoconnect, the bridge pulls its
    # port up with it (autoconnect-slaves), and the old NIC profile
    # stops autoconnecting (it would otherwise re-grab the LAN IP at
    # boot and starve the bridge of its port).
    & sudo nmcli connection modify $BridgeName connection.autoconnect yes connection.autoconnect-slaves 1 2>&1 |
        ForEach-Object { Write-Verbose "$_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_12e7b55dcdfe19f9' -Arguments @{ bridgeName = "$BridgeName" })
    }
    & sudo nmcli connection modify $slaveConn connection.autoconnect yes 2>&1 |
        ForEach-Object { Write-Verbose "$_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_01b9bade8d78a614' -Arguments @{ slaveConn = "$slaveConn" })
    }
    if ($oldConn) {
        & sudo nmcli connection modify $oldConn connection.autoconnect no 2>&1 | Out-Null
    }

    # See https://yuruna.link/42e5cdfd-001b
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $brIp = & ip -4 -o addr show dev $BridgeName 2>$null | Select-String -Pattern 'inet '
        if ($brIp) {
            Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_1fcd66a663cf4d86' -Arguments @{ bridgeName = "$BridgeName"; value = "$($brIp -replace '^\s+|\s+$','')" })
            return $true
        }
        Start-Sleep -Seconds 1
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_2e94e17d6c886c3b' -Arguments @{ bridgeName = "$BridgeName" })
    return $true
}

# Internal, pure (no side effects): the netplan yaml that moves $Nic
# onto $BridgeName. Three identity/ownership pins (renderer: networkd,
# macaddress: cloned from the NIC, dhcp-identifier: mac) make it behave
# the same on every host. See docs/network.md (KVM host bridge
# netplan: identity pins).
function Get-YurunaBridgeNetplanYaml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Nic,
        [Parameter(Mandatory)][string]$BridgeName,
        [AllowEmptyString()][string]$Mac = ''
    )
    $macLine = if ($Mac) { "`n      macaddress: $Mac" } else { '' }
    return @"
network:
  version: 2
  ethernets:
    ${Nic}:
      renderer: networkd
      dhcp4: no
      dhcp6: no
  bridges:
    ${BridgeName}:
      renderer: networkd
      interfaces: [${Nic}]$macLine
      dhcp4: yes
      dhcp-identifier: mac
      dhcp6: yes
      parameters:
        stp: false
"@
}

# See https://yuruna.link/42e5cdfd-001c
function New-YurunaBridgeViaNetplan {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private helper; the public New-YurunaExternalNetwork caller already gates via SupportsShouldProcess (see the "Move $nic onto new Linux bridge" ShouldProcess call). Adding a nested gate here would double-prompt.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Nic,
        [Parameter(Mandatory)][string]$BridgeName
    )
    # Stale profiles/devices from previous attempts were already removed
    # by Clear-YurunaExternalBridgeResidue in the caller's build path.

    # See https://yuruna.link/42e5cdfd-001c
    $handedOff = $false
    $oldConn = $null
    if (Test-YurunaNicManagedByNetworkManager -Nic $Nic) {
        $oldConn = (& nmcli -t -f NAME,DEVICE connection show --active 2>$null |
                    Where-Object { $_ -match "^([^:]+):$Nic`$" } |
                    ForEach-Object { ($_ -split ':', 2)[0] } |
                    Select-Object -First 1)
        if ($oldConn) {
            & sudo nmcli connection modify $oldConn connection.autoconnect no 2>&1 | Out-Null
        }
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_9a93f742283b5cf6' -Arguments @{ nic = "$Nic" })
        & sudo nmcli device set $Nic managed no 2>&1 | ForEach-Object { Write-Verbose "$_" }
        $handedOff = $true
    }

    # See https://yuruna.link/42e5cdfd-001c
    $netplanPath = "/etc/netplan/99-yuruna-external.yaml"
    $rollback = {
        & sudo rm -f $netplanPath 2>&1 | ForEach-Object { Write-Verbose "$_" }
        & sudo netplan apply 2>&1 | ForEach-Object { Write-Verbose "$_" }
        if (Test-Path -LiteralPath "/sys/class/net/$BridgeName") {
            & sudo ip link delete $BridgeName 2>&1 | ForEach-Object { Write-Verbose "$_" }
        }
        if ($handedOff) {
            & sudo nmcli device set $Nic managed yes 2>&1 | ForEach-Object { Write-Verbose "$_" }
            if ($oldConn) {
                & sudo nmcli connection modify $oldConn connection.autoconnect yes 2>&1 | Out-Null
                & sudo nmcli connection up $oldConn 2>&1 | ForEach-Object { Write-Verbose "$_" }
            }
        }
    }

    # The yaml pins `renderer: networkd` on both stanzas (rationale in
    # Get-YurunaBridgeNetplanYaml's header): without the pin, a global
    # 'renderer: NetworkManager' -- standard on Ubuntu Desktop -- would
    # turn these definitions into NM keyfiles, and the NIC handoff above
    # would then fight the very config this path just wrote.
    $yaml = Get-YurunaBridgeNetplanYaml -Nic $Nic -BridgeName $BridgeName -Mac (Get-YurunaNicMac -Iface $Nic)
    # netplan files are root-owned 600; write via sudo+tee.
    $yaml | & sudo tee $netplanPath > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_398ccf080207bc32' -Arguments @{ netplanPath = "$netplanPath" })
        if ($handedOff) { & $rollback }
        return $false
    }
    & sudo chmod 600 $netplanPath 2>&1 | Out-Null

    # netplan validates the rendered config before applying. A parse
    # error here means our yaml is wrong; bail BEFORE running apply so
    # the operator's networking stays untouched.
    & sudo netplan generate 2>&1 | ForEach-Object { Write-Verbose "$_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_3fcb53efee68e05d' -Arguments @{ netplanPath = "$netplanPath" })
        & $rollback
        return $false
    }

    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_088321ac50d84a12')
    & sudo netplan apply 2>&1 | ForEach-Object { Write-Verbose "$_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_a364da43ba1a8746')
        & $rollback
        return $false
    }

    # netplan apply returns before systemd-networkd finishes reassembling
    # the link set, and enslavement of $Nic is what actually makes the
    # bridge usable -- so verify it in /sys instead of trusting the exit
    # code. networkd enslaves in well under a second once it owns the
    # NIC; the wait is generous to ride out a slow daemon restart.
    if (-not (Wait-YurunaBridgeUplink -BridgeName $BridgeName -Nic $Nic)) {
        # One forced attempt: enslaving by hand matches exactly what the
        # netplan config declares, so this cannot fight networkd -- it
        # only wins the race networkd just lost (usually against a
        # NetworkManager that had not fully released the NIC yet).
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_3ec30441269e453e' -Arguments @{ nic = "$Nic"; bridgeName = "$BridgeName" })
        & sudo ip link set $Nic master $BridgeName 2>&1 | ForEach-Object { Write-Verbose "$_" }
        if (-not (Wait-YurunaBridgeUplink -BridgeName $BridgeName -Nic $Nic -TimeoutSeconds 3)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_8901b9ff5d800b56' -Arguments @{ bridgeName = "$BridgeName"; nic = "$Nic" })
            & $rollback
            return $false
        }
    }

    # Wait up to 30 s for the bridge to DHCP. Same wall-clock deadline
    # rationale as the nmcli path: a counted loop would overrun the 30 s
    # budget because the per-iteration `ip` probe has its own latency.
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $brIp = & ip -4 -o addr show dev $BridgeName 2>$null | Select-String -Pattern 'inet '
        if ($brIp) {
            Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_1fcd66a663cf4d86' -Arguments @{ bridgeName = "$BridgeName"; value = "$($brIp -replace '^\s+|\s+$','')" })
            return $true
        }
        Start-Sleep -Seconds 1
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_2e94e17d6c886c3b' -Arguments @{ bridgeName = "$BridgeName" })
    return $true
}
