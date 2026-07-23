<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42f1c7d5-6b28-4a19-8c40-7d2e5a9b1c63
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test lease dhcp subnet discovery pester
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
    Pester coverage for the guest-IP discovery helpers in Yuruna.Common.psm1:
    on-link netmask arithmetic, the interface-table parser, the dhcpd_leases
    selector, and the seeded-hostname reader.
.DESCRIPTION
    Throw-based assertions so the file runs under the OS-bundled Pester 3.4 and
    Pester 5+. Every case is driven from in-memory fixture text or a throwaway
    directory -- no VM, no /var/db/dhcpd_leases, no ifconfig invocation -- so the
    parsers stay testable on a host with no guests running.
    Run: Invoke-Pester -Path test/modules/Test.LeaseDiscovery.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path -Path (Split-Path -Parent $here) -ChildPath '..' -AdditionalChildPath 'automation', 'Yuruna.Common.psm1') -Force -DisableNameChecking

# Fixtures live at file scope, above the first Describe. An It block runs in a
# fresh script scope, so a $script:-qualified read from inside a test resolves
# there and comes back $null; only an unqualified name walks the scope chain out
# to this file's variables. The throwaway directory is named from $PID rather
# than a GUID so every execution of this body (discovery pass, and once more
# when the file is the entry script) computes the same path.
$LeaseTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-lease-$PID"
Remove-Item -LiteralPath $LeaseTestRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $LeaseTestRoot | Out-Null

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ($Expected -ne $Actual) { throw "Expected '$Expected' but got '$Actual'. $Because" }
}

# The live host's interface table at the time of the failure being guarded
# against: en0 on the LAN, bridge100 as the vmnet gateway every UTM guest is
# attached to, and lo0. Netmasks are hex, as macOS prints them.
$IfconfigFixture = @'
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
	inet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 192.168.7.101 netmask 0xffffff00 broadcast 192.168.7.255
bridge100: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 192.168.64.1 netmask 0xffffff00 broadcast 192.168.64.255
'@

# The exact failing shape: every block filed under the VM name is a stale
# predecessor on the retired 192.168.65.0/24, while the live guest registered
# under the pinned hostname on the subnet bridge100 actually serves. The two
# live blocks are both on-link and same-named, so the subnet guard alone cannot
# choose between them -- the lease= expiry still has to.
$LeaseFixture = @'
{
	name=test-amazon-linux-2023-01
	ip_address=192.168.65.42
	hw_address=1,a2:68:9d:cf:35:81
	identifier=1,a2:68:9d:cf:35:81
	lease=0x6a5e9999
}
{
	name=test-amazon-linux-2023-01
	ip_address=192.168.65.7
	hw_address=1,a2:68:9d:cf:35:82
	identifier=1,a2:68:9d:cf:35:82
	lease=0x6a5e1111
}
{
	name=ch01host1
	ip_address=192.168.64.4
	hw_address=1,a2:68:9d:cf:35:83
	identifier=1,a2:68:9d:cf:35:83
	lease=0x6a5e6b0b
}
{
	name=ch01host1
	ip_address=192.168.64.2
	hw_address=1,a2:68:9d:cf:35:84
	identifier=1,a2:68:9d:cf:35:84
	lease=0x6a5e7261
}
'@

Describe 'Get-HostIpv4Subnet' {
    It 'parses hex netmasks and skips loopback' {
        $subnets = Get-HostIpv4Subnet -IfconfigText $IfconfigFixture
        Assert-Equal -Expected 2 -Actual $subnets.Count -Because 'lo0 must be excluded; en0 and bridge100 must both appear.'
        Assert-True (($subnets | Where-Object { $_.Address -eq '192.168.64.1' }) -ne $null) 'bridge100 must be enumerated -- it is the vmnet subnet every UTM guest lives on.'
        foreach ($s in $subnets) { Assert-Equal -Expected 24 -Actual $s.PrefixLength -Because 'A hex mask parsed as a dotted quad would yield prefix 0.' }
    }

    It 'returns an empty table for text with no inet lines' {
        $subnets = Get-HostIpv4Subnet -IfconfigText "gif0: flags=8010<POINTOPOINT> mtu 1280`n"
        Assert-Equal 0 $subnets.Count
    }
}

Describe 'Get-Ipv4OnLinkVerdict' {
    It 'accepts an address on a live subnet and rejects one that is not' {
        $subnets = Get-HostIpv4Subnet -IfconfigText $IfconfigFixture
        Assert-Equal 'onlink'  (Get-Ipv4OnLinkVerdict -IpAddress '192.168.64.2'  -Subnet $subnets)
        Assert-Equal 'offlink' (Get-Ipv4OnLinkVerdict -IpAddress '192.168.65.42' -Subnet $subnets)
    }

    It 'answers unknown when no interface could be enumerated' {
        # Degrading to 'unknown' rather than 'offlink' is what keeps a host
        # whose interfaces cannot be listed from rejecting every candidate.
        Assert-Equal 'unknown' (Get-Ipv4OnLinkVerdict -IpAddress '192.168.64.2' -Subnet @())
    }

    It 'answers unknown for an unparseable address' {
        $subnets = Get-HostIpv4Subnet -IfconfigText $IfconfigFixture
        Assert-Equal 'unknown' (Get-Ipv4OnLinkVerdict -IpAddress 'not-an-ip' -Subnet $subnets)
    }

    It 'applies the real mask on a non-/24 interface' {
        # A /20 spans 10.8.0.0 - 10.8.15.255. A hardcoded /24 or a
        # leading-three-octet string compare would reject 10.8.9.5, which is
        # genuinely reachable, and would accept nothing outside 10.8.4.x.
        $wide = Get-HostIpv4Subnet -IfconfigText "en9: flags=8863<UP> mtu 1500`n`tinet 10.8.4.1 netmask 0xfffff000 broadcast 10.8.15.255`n"
        Assert-Equal 20 $wide[0].PrefixLength
        Assert-Equal 'onlink'  (Get-Ipv4OnLinkVerdict -IpAddress '10.8.9.5'   -Subnet $wide)
        Assert-Equal 'onlink'  (Get-Ipv4OnLinkVerdict -IpAddress '10.8.15.254' -Subnet $wide)
        Assert-Equal 'offlink' (Get-Ipv4OnLinkVerdict -IpAddress '10.8.16.1'  -Subnet $wide)
    }

    It 'converts addresses without an endianness flip' {
        # A GetAddressBytes/BitConverter pair reverses the octets on a
        # little-endian host and still returns a plausible number.
        # 192*2^24 + 168*2^16 + 64*2^8 + 2. The byte-reversed reading of the
        # same address is 34519232, which no test would flag on its own.
        Assert-Equal 3232251906 (ConvertTo-Ipv4UInt32 '192.168.64.2')
        Assert-Equal $null (ConvertTo-Ipv4UInt32 '999.1.1.1')
    }
}

Describe 'Select-DhcpLeaseIpAddress' {
    It 'prefers the pinned hostname over stale VM-name blocks' {
        $subnets = Get-HostIpv4Subnet -IfconfigText $IfconfigFixture
        $verdict = { param($ip) Get-Ipv4OnLinkVerdict -IpAddress $ip -Subnet $subnets }.GetNewClosure()
        $picked = Select-DhcpLeaseIpAddress -LeaseText $LeaseFixture `
            -Name @('ch01host1', 'test-amazon-linux-2023-01') -OnLinkVerdict $verdict
        Assert-Equal -Expected '192.168.64.2' -Actual $picked -Because 'The most recently renewed on-link block under the pinned hostname must win.'
    }

    It 'rejects off-subnet blocks even when the VM name is the only key tried' {
        # The failure being guarded against: keyed on the VM name alone, every
        # match is a stale predecessor on a subnet the host no longer serves.
        # Returning $null lets the caller keep polling instead of burning an
        # SSH connect-timeout budget per attempt against a dead address.
        $subnets = Get-HostIpv4Subnet -IfconfigText $IfconfigFixture
        $verdict = { param($ip) Get-Ipv4OnLinkVerdict -IpAddress $ip -Subnet $subnets }.GetNewClosure()
        $picked = Select-DhcpLeaseIpAddress -LeaseText $LeaseFixture `
            -Name @('test-amazon-linux-2023-01') -OnLinkVerdict $verdict
        Assert-Equal $null $picked
    }

    It 'falls through safely when interface enumeration yields nothing' {
        # Empty enumeration must not reject everything: a wrong rejection turns
        # a working discovery into a hard failure, so the pre-guard behavior
        # (highest lease= under the matched name) has to survive intact.
        $verdict = { param($ip) Get-Ipv4OnLinkVerdict -IpAddress $ip -Subnet @() }.GetNewClosure()
        $picked = Select-DhcpLeaseIpAddress -LeaseText $LeaseFixture `
            -Name @('test-amazon-linux-2023-01') -OnLinkVerdict $verdict
        Assert-Equal '192.168.65.42' $picked
    }

    It 'skips blocks with no parseable lease expiry' {
        $noExpiry = @'
{
	name=vm-a
	ip_address=192.168.64.30
}
{
	name=vm-a
	ip_address=192.168.64.31
	lease=0x1
}
'@
        # An empty subnet table is the real "could not enumerate" path, so
        # this exercises the production verdict rather than a stub of it.
        $verdict = { param($ip) Get-Ipv4OnLinkVerdict -IpAddress $ip -Subnet @() }
        $picked = Select-DhcpLeaseIpAddress -LeaseText $noExpiry -Name @('vm-a') -OnLinkVerdict $verdict
        Assert-Equal -Expected '192.168.64.31' -Actual $picked -Because 'A block that cannot prove it is renewing must not displace one that can.'
    }

    It 'returns null for an unmatched name and for empty text' {
        # An empty subnet table is the real "could not enumerate" path, so
        # this exercises the production verdict rather than a stub of it.
        $verdict = { param($ip) Get-Ipv4OnLinkVerdict -IpAddress $ip -Subnet @() }
        Assert-Equal $null (Select-DhcpLeaseIpAddress -LeaseText $LeaseFixture -Name @('absent-vm') -OnLinkVerdict $verdict)
        Assert-Equal $null (Select-DhcpLeaseIpAddress -LeaseText '' -Name @('ch01host1') -OnLinkVerdict $verdict)
    }
}

Describe 'Get-UtmGuestSeedHostname' {
    AfterAll {
        # Cleanup belongs here, not at the end of the file: file-level code runs
        # during discovery, BEFORE any It, so a trailing Remove-Item would delete
        # the fixture the tests are about to read.
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-lease-$PID"
        if ($root -match 'yrn-lease-') { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reads local-hostname out of a seeded bundle' {
        $dataDir = Join-Path $LeaseTestRoot 'test-amazon-linux-2023-01.utm' -AdditionalChildPath 'Data'
        New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
        # Padding stands in for the ISO9660 headers around the plain-text
        # meta-data; the key is found by scanning the raw bytes.
        $seed = "`0`0`0CD001" + "instance-id: test-amazon-linux-2023-01`nlocal-hostname: ch01host1`n" + ("`0" * 64)
        [IO.File]::WriteAllText((Join-Path $dataDir 'seed.iso'), $seed, [Text.UTF8Encoding]::new($false))
        Assert-Equal 'ch01host1' (Get-UtmGuestSeedHostname -VMName 'test-amazon-linux-2023-01' -BundleRoot $LeaseTestRoot)
    }

    It 'falls back to the VM name when no bundle or no key is present' {
        Assert-Equal 'no-such-vm' (Get-UtmGuestSeedHostname -VMName 'no-such-vm' -BundleRoot $LeaseTestRoot)
        $dataDir = Join-Path $LeaseTestRoot 'plain-vm.utm' -AdditionalChildPath 'Data'
        New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dataDir 'seed.iso'), "instance-id: plain-vm`n", [Text.UTF8Encoding]::new($false))
        Assert-Equal 'plain-vm' (Get-UtmGuestSeedHostname -VMName 'plain-vm' -BundleRoot $LeaseTestRoot)
    }
}
