<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42b7d1e4-9c2a-4f68-8b30-5d1c7e9a0b46
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test kvm bridge networkmanager pester
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
    Guards the Ubuntu-KVM bridge-backend choice: the caching-proxy bridge must be
    built with netplan (systemd-networkd) when NetworkManager is RUNNING but does
    not MANAGE the default-route NIC -- the Ubuntu Server default. Keying the
    backend off "is the NM daemon running" instead silently drops the cache to
    NAT, because `nmcli connection up <bridge>` fails with "Failed to find a
    compatible device for this connection" on an NM-unmanaged NIC.
.DESCRIPTION
    Test-YurunaNicManagedByNetworkManager is a module-internal helper; it is
    invoked in module scope (`& (Get-Module Yuruna.Host) { ... }`) and fed
    pre-captured `nmcli -t -f DEVICE,STATE device status` lines through its
    -StatusLines test seam, so no live nmcli is needed and the classification runs
    cross-platform. The module is imported at file scope (it persists into the run
    phase); the module handle is fetched INSIDE each It (a file-scope variable does
    not survive Pester 5's discovery/run split). Throw-based Assert-* helpers so
    this runs under Pester 4.10.1 and 5+.
#>

$here = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent (Split-Path -Parent $here)
$modulePath = Join-Path $repo 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

function Invoke-NicManaged {
    param([string]$Nic, [string[]]$Lines)
    $mod = Get-Module Yuruna.Host
    & $mod { param($n, $l) Test-YurunaNicManagedByNetworkManager -Nic $n -StatusLines $l } $Nic $Lines
}

function Invoke-NetplanYaml {
    param([string]$Nic, [string]$BridgeName, [string]$Mac = '')
    $mod = Get-Module Yuruna.Host
    & $mod { param($n, $b, $m) Get-YurunaBridgeNetplanYaml -Nic $n -BridgeName $b -Mac $m } $Nic $BridgeName $Mac
}

function Invoke-BridgeBlocker {
    param([string]$Iface)
    $mod = Get-Module Yuruna.Host
    & $mod { param($i) Get-YurunaIfaceBridgeBlocker -Iface $i } $Iface
}

Describe 'Ubuntu-KVM bridge backend: NIC-management classification' {

    It 'loaded the ubuntu.kvm host module' {
        Assert-True ($null -ne (Get-Module Yuruna.Host)) 'Yuruna.Host (ubuntu.kvm) must import for the backend classifier'
    }

    # The regression: NM is running but the netplan renderer is systemd-networkd,
    # so every NIC is 'unmanaged'. nmcli cannot build the bridge here -> netplan.
    It 'treats an NM-unmanaged NIC (Ubuntu Server / networkd renderer) as NOT managed' {
        Assert-Equal -Expected $false -Actual (Invoke-NicManaged -Nic 'eno1' -Lines @('eno1:unmanaged','lo:unmanaged','virbr0:unmanaged')) `
            -Because 'NM running + NIC unmanaged must route to the netplan backend, not nmcli'
    }

    It 'treats an NM-managed (connected) NIC as managed -> nmcli' {
        Assert-Equal -Expected $true -Actual (Invoke-NicManaged -Nic 'eno1' -Lines @('eno1:connected','lo:unmanaged'))
    }

    It 'treats a managed-but-carrierless NIC (unavailable/disconnected) as managed' {
        Assert-Equal -Expected $true -Actual (Invoke-NicManaged -Nic 'eno1' -Lines @('eno1:unavailable'))
        Assert-Equal -Expected $true -Actual (Invoke-NicManaged -Nic 'eno1' -Lines @('eno1:disconnected'))
    }

    It 'treats a NIC NM does not list at all as NOT managed' {
        Assert-Equal -Expected $false -Actual (Invoke-NicManaged -Nic 'eno1' -Lines @('enp3s0:connected','lo:unmanaged')) `
            -Because 'a NIC absent from nmcli device status is not NM-managed'
    }

    It 'does not confuse a different device that is unmanaged with the target NIC' {
        # eno1 is connected; virbr0 is unmanaged. The target eno1 must read managed.
        Assert-Equal -Expected $true -Actual (Invoke-NicManaged -Nic 'eno1' -Lines @('eno1:connected','virbr0:unmanaged'))
    }
}

Describe 'Ubuntu-KVM bridge backend: source keys the choice off NIC management' {
    # AST/source guard: the backend selector must consult NIC management, not just
    # the daemon-running check, and must retain a netplan fallback. Read the source
    # INSIDE the It so the value survives Pester 5's discovery/run split.
    It 'New-YurunaExternalNetwork gates the nmcli path on Test-YurunaNicManagedByNetworkManager' {
        $src = Get-Content -Raw -LiteralPath $modulePath
        Assert-True ($src -match 'Test-YurunaNicManagedByNetworkManager -Nic \$nic') 'the backend choice must check NIC management'
    }
    It 'still falls back to the netplan path when nmcli fails' {
        $src = Get-Content -Raw -LiteralPath $modulePath
        Assert-True ($src -match 'nmcli bridge build failed; falling back to the netplan') 'an nmcli failure must fall back to netplan, not straight to NAT'
    }
}

Describe 'Ubuntu-KVM bridge build: netplan yaml pins identity and backend' {
    # The yaml must pin three things or the bridge misbehaves per-host:
    # renderer (a global Desktop 'renderer: NetworkManager' would flip the
    # definitions to NM keyfiles and fight the NIC handoff), the bridge
    # MAC (systemd MACAddressPolicy=persistent otherwise generates one and
    # the host renumbers), and the DHCP client identifier (networkd's DUID
    # default renumbers the host even with the MAC pinned).
    It 'pins renderer: networkd on both the NIC and the bridge stanzas' {
        $yaml = Invoke-NetplanYaml -Nic 'eno1' -BridgeName 'yuruna-br0' -Mac 'aa:bb:cc:dd:ee:ff'
        $rendererCount = ([regex]::Matches($yaml, 'renderer: networkd')).Count
        Assert-Equal -Expected 2 -Actual $rendererCount 'ethernets.eno1 and bridges.yuruna-br0 must each pin the networkd renderer'
    }
    It 'clones the NIC MAC onto the bridge and keys DHCP on it' {
        $yaml = Invoke-NetplanYaml -Nic 'eno1' -BridgeName 'yuruna-br0' -Mac 'aa:bb:cc:dd:ee:ff'
        Assert-True ($yaml.Contains('macaddress: aa:bb:cc:dd:ee:ff')) 'bridge must clone the NIC MAC so the host keeps its DHCP lease'
        Assert-True ($yaml.Contains('dhcp-identifier: mac')) 'DHCPv4 must key on the MAC, not the machine-id DUID'
    }
    It 'moves the NIC under the bridge with DHCP off and STP off' {
        $yaml = Invoke-NetplanYaml -Nic 'eno1' -BridgeName 'yuruna-br0'
        Assert-True ($yaml.Contains('interfaces: [eno1]')) 'the NIC must be the bridge port'
        Assert-True ($yaml -match '(?s)eno1:.*?dhcp4: no') 'the enslaved NIC must not DHCP for itself'
        Assert-True ($yaml.Contains('stp: false')) 'single-port bridge must skip the STP forwarding delay'
    }
    It 'omits the MAC pin when the MAC is unknown' {
        $yaml = Invoke-NetplanYaml -Nic 'eno1' -BridgeName 'yuruna-br0' -Mac ''
        Assert-True (-not $yaml.Contains('macaddress:')) 'an empty MAC must not emit a broken macaddress: line'
    }
}

Describe 'Ubuntu-KVM bridge build: uplink-NIC eligibility' {
    It 'rejects an interface name with characters unsafe for generated config' {
        Assert-True ('' -ne (Invoke-BridgeBlocker -Iface 'eno1; rm -rf /')) 'shell/yaml metacharacters must be rejected'
        Assert-True ('' -ne (Invoke-BridgeBlocker -Iface "eno1`nx")) 'a newline in the name must be rejected'
    }
    It 'accepts a plain ethernet-style name' {
        Assert-Equal -Expected '' -Actual (Invoke-BridgeBlocker -Iface 'eno1') 'a plain NIC name (no sysfs contra-indications) must pass'
    }
}

Describe 'Ubuntu-KVM bridge lifecycle: half-built-state source guards' {
    # Source guards for the residue/verification behaviors that keep the
    # bridge bring-up reliable. Each literal below is load-bearing: if a
    # refactor drops it, one of the wedge states comes back.
    It 'build path sweeps residue before building' {
        $src = Get-Content -Raw -LiteralPath $modulePath
        Assert-True ($src.Contains('Clear-YurunaExternalBridgeResidue -Nic $nic -BridgeName $BridgeName')) 'stale profiles/netplan/device must be swept before any backend builds'
    }
    It 'residue sweep removes a stale kernel bridge device' {
        $src = Get-Content -Raw -LiteralPath $modulePath
        Assert-True ($src.Contains('ip link delete $BridgeName')) 'a stale same-named device is what makes nmcli fail with "no compatible device"'
    }
    It 'residue sweep refuses to touch a NIC that is itself a bridge' {
        $src = Get-Content -Raw -LiteralPath $modulePath
        Assert-True ($src.Contains('/sys/class/net/$Nic/bridge')) 'deleting the bridge that holds the default route would cut the host off'
    }
    It 'nmcli build adds profiles with autoconnect no and the MAC pinned at add time' {
        $src = Get-Content -Raw -LiteralPath $modulePath
        Assert-True ($src.Contains("'autoconnect', 'no'")) 'NM must not race ahead of the explicit activation order'
        Assert-True ($src.Contains("'bridge.mac-address', `$nicMac")) 'a MAC set by a later modify races device realization and fails activation'
    }
    It 'nmcli build defers boot persistence until the uplink is verified' {
        $src = Get-Content -Raw -LiteralPath $modulePath
        Assert-True ($src.Contains('connection.autoconnect-slaves 1')) 'the bridge must pull its port up at boot'
    }
    It 'nmcli failure paths re-activate the original NIC connection' {
        $src = Get-Content -Raw -LiteralPath $modulePath
        Assert-True ($src.Contains('nmcli device connect $Nic')) 'a failed build must never strand the host without networking'
    }
    It 'netplan build hands the NIC off from NetworkManager before apply' {
        $src = Get-Content -Raw -LiteralPath $modulePath
        Assert-True ($src.Contains('nmcli device set $Nic managed no')) 'without the handoff NM and networkd fight for the NIC and the bridge stays uplink-less'
    }
    It 'netplan build verifies enslavement in /sys instead of trusting exit codes' {
        $src = Get-Content -Raw -LiteralPath $modulePath
        Assert-True ($src.Contains('Wait-YurunaBridgeUplink -BridgeName $BridgeName -Nic $Nic')) 'netplan apply returns before networkd converges; only brif membership proves the uplink'
    }
    It 'reuse path rebuilds when the repair reports the bridge unrecoverable' {
        $src = Get-Content -Raw -LiteralPath $modulePath
        Assert-True ($src.Contains("if (`$repair -ne 'rebuild') { return `$NetworkName }")) 'a wedged bridge must fall through to the build steps, not fast-return'
    }
    It 'Get-ExternalNetwork only offers ACTIVE libvirt networks to guests' {
        $src = Get-Content -Raw -LiteralPath $modulePath
        Assert-True ($src -match '\$active\s+= Invoke-Virsh -VirshArgs @\(''net-list'', ''--name''\)') 'a defined-but-stopped network must never be handed to virt-install'
    }
    It 'caching-proxy New-VM refuses to create a VM on an uplink-less bridge -- but only for bridge-mode networks' {
        $newVmPath = Join-Path $repo 'host/ubuntu.kvm/guest.caching-proxy/New-VM.ps1'
        $src = Get-Content -Raw -LiteralPath $newVmPath
        Assert-True ($src.Contains('/brif')) 'the 20-minute IP wait must be preempted by a bridge-uplink probe'
        Assert-True ($src -match "<forward\\s\+mode='bridge'") 'NAT/routed networks own a virbr bridge with no uplink by design; probing it would veto a working network'
    }
    It 'repair refuses to touch networks that are not host-bridge-backed' {
        $src = Get-Content -Raw -LiteralPath $modulePath
        Assert-True ($src.Contains('Test-YurunaLibvirtNetworkIsBridgeMode')) 'rebuilding a libvirt-owned NAT bridge as a LAN bridge would put its dnsmasq on the LAN (rogue DHCP)'
    }
    It 'netplan build rollback re-applies netplan so the running daemons restore the NIC' {
        $src = Get-Content -Raw -LiteralPath $modulePath
        Assert-True ($src -match '(?s)\$rollback = \{.{0,500}netplan apply') 'generate only rewrites /run; without apply a pure-networkd host is left addressless after a failed build'
    }
    It 'rebuild-flow bail-outs stop an already-defined network on an unusable bridge' {
        $src = Get-Content -Raw -LiteralPath $modulePath
        $stopCalls = ([regex]::Matches($src, 'Stop-YurunaUnusableExternalNetwork -NetworkName \$NetworkName')).Count
        Assert-True ($stopCalls -ge 5) "every pre-build failure exit must deactivate the dead network so guests fall back to NAT (found $stopCalls call sites)"
    }
}
