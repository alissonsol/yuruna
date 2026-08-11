<#PSScriptInfo
.VERSION 2026.08.10
.GUID 42b3f7d1-08c4-4e29-b5a7-19d6c4f2a8e3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test kvm libvirt discovery arp neighbour pester
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
# Pester supplies Describe/It/Should here. Without it every one of those calls
# raises CommandNotFoundException, the engine keeps going, and the file reaches
# its end and exits 0 -- so a harness that shells this out records a PASS for a
# suite that executed no assertion at all. A test that cannot run must say so in
# its exit code; silence that reads as success is worse than no test.
if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error ("Pester is not available, so this suite cannot run. Install it with " +
                 "'Install-Module Pester -Scope CurrentUser', then re-run with " +
                 "Invoke-Pester -Path '$PSCommandPath'.")
    exit 1
}

<#
.SYNOPSIS
    The KVM guest-address chain: which row it picks out of `virsh domifaddr`,
    which neighbour states it will trust, and that it never answers with a name.
.DESCRIPTION
    WHY THIS EXISTS. Two of this driver's three virsh sources are silent by
    construction for a test guest: `lease` needs libvirt to be the DHCP server,
    which it is not on a bridge-forward network with no <dhcp> element, and
    `agent` needs qemu-guest-agent inside the guest. That leaves a passive read
    of the host neighbour cache carrying the whole chain, and a passive read of
    a decaying cache misses. A miss here is not cosmetic: the caller turns
    $null into an ssh target built from the VM name, which fails as a
    name-resolution error naming nothing about the real cause.

    Two properties therefore have to hold and are pinned below. The row picker
    must prefer the domain's own NIC and this host's subnet, because a
    Kubernetes node reports its CNI bridge, overlay device and docker bridge
    through the same source and all of them look routable -- picking one turns
    a loud failure into a silent connect timeout. And the neighbour reader must
    accept STALE while rejecting FAILED and INCOMPLETE, because only the latter
    two genuinely carry no link-layer address.

    HOW IT IS DRIVEN. Every case feeds pre-captured `virsh domifaddr`,
    `ip -4 neigh show` and `ip -o -4 addr show` text through the rungs' test
    seams. No VM, no libvirt, no root, and no Linux -- so these run on the
    hosts that actually execute CI.
#>

BeforeAll {
    $script:DriverPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'host', 'ubuntu.kvm', 'modules', 'Yuruna.Host.psm1'
    Import-Module $script:DriverPath -Force -DisableNameChecking -Global
    $script:Driver = Get-Module Yuruna.Host

    # A kubeadm node as libvirt reports it: the domain NIC first with the
    # overlay address, then a continuation row (MAC column '-') carrying the
    # real LAN address, then the docker bridge on its own MAC.
    $script:K8sRows = @(
        'vnet3      52:54:00:1a:b2:c3    ipv4         10.244.0.1/24',
        '-          -                    ipv4         192.168.7.70/24',
        'docker0    aa:bb:cc:dd:ee:ff    ipv4         172.17.0.1/16'
    )
    $script:DomainMac = '52:54:00:1A:B2:C3'
    $script:HostPrefix = '192.168.7'
}

Describe 'Select-VirshDomifaddrIp' {

    It 'prefers this host subnet over a CNI address on the same interface' {
        $ip = & $script:Driver { Select-VirshDomifaddrIp -Line $args[0] -HostPrefix $args[1] } $script:K8sRows $script:HostPrefix
        $ip | Should -Be '192.168.7.70'
    }

    It 'carries the MAC forward onto a continuation row so MAC affinity still matches' {
        # The MAC column repeats only on an interface's first row. Without the
        # carry-forward the LAN address would be attributed to no MAC at all and
        # the affinity pass would discard the very row it should prefer.
        $ip = & $script:Driver { Select-VirshDomifaddrIp -Line $args[0] -Mac $args[1] -HostPrefix $args[2] } `
            $script:K8sRows $script:DomainMac $script:HostPrefix
        $ip | Should -Be '192.168.7.70'
    }

    It 'never returns the docker bridge when the domain MAC is known' {
        $ip = & $script:Driver { Select-VirshDomifaddrIp -Line $args[0] -Mac $args[1] -HostPrefix $args[2] } `
            $script:K8sRows $script:DomainMac $script:HostPrefix
        $ip | Should -Not -Be '172.17.0.1'
    }

    It 'falls back to a routable address when none is on the host subnet' {
        $rows = @('vnet0      52:54:00:11:22:33    ipv4         10.10.0.5/24')
        $ip = & $script:Driver { Select-VirshDomifaddrIp -Line $args[0] -HostPrefix $args[1] } $rows $script:HostPrefix
        $ip | Should -Be '10.10.0.5'
    }

    It 'prefers v4 over v6 and returns v6 only when no v4 exists' {
        $both = @(
            'vnet0      52:54:00:11:22:33    ipv6         2001:db8::1234/64',
            'vnet0      52:54:00:11:22:33    ipv4         192.168.7.90/24'
        )
        (& $script:Driver { Select-VirshDomifaddrIp -Line $args[0] } $both) | Should -Be '192.168.7.90'

        $v6only = @('vnet0      52:54:00:11:22:33    ipv6         2001:db8::1234/64')
        (& $script:Driver { Select-VirshDomifaddrIp -Line $args[0] } $v6only) | Should -Be '2001:db8::1234'
    }

    It 'rejects loopback and link-local' {
        $junk = @(
            'lo         00:00:00:00:00:00    ipv4         127.0.0.1/8',
            'vnet0      52:54:00:11:22:33    ipv4         169.254.3.4/16',
            'vnet0      52:54:00:11:22:33    ipv6         fe80::1/64'
        )
        (& $script:Driver { Select-VirshDomifaddrIp -Line $args[0] } $junk) | Should -BeNullOrEmpty
    }

    It 'returns nothing for empty output rather than inventing a row' {
        (& $script:Driver { Select-VirshDomifaddrIp -Line @() } ) | Should -BeNullOrEmpty
        (& $script:Driver { Select-VirshDomifaddrIp -Line @(' Name  MAC  Protocol  Address', '-----') }) | Should -BeNullOrEmpty
    }
}

Describe 'Get-KvmNeighborIp' {

    BeforeAll {
        $script:Neigh = @(
            '192.168.7.70 dev yuruna-br0 lladdr 52:54:00:1a:b2:c3 STALE',
            '192.168.7.71 dev yuruna-br0 lladdr 52:54:00:aa:bb:cc FAILED',
            '192.168.7.72 dev yuruna-br0 lladdr 52:54:00:dd:ee:ff REACHABLE',
            '192.168.7.73 dev yuruna-br0  INCOMPLETE'
        )
    }

    It 'accepts STALE, which still carries a link-layer address' {
        $ip = & $script:Driver { Get-KvmNeighborIp -Mac $args[0] -NeighborLine $args[1] } '52:54:00:1A:B2:C3' $script:Neigh
        $ip | Should -Be '192.168.7.70'
    }

    It 'accepts REACHABLE' {
        $ip = & $script:Driver { Get-KvmNeighborIp -Mac $args[0] -NeighborLine $args[1] } '52:54:00:DD:EE:FF' $script:Neigh
        $ip | Should -Be '192.168.7.72'
    }

    It 'rejects FAILED, because that entry has no usable address behind it' {
        $ip = & $script:Driver { Get-KvmNeighborIp -Mac $args[0] -NeighborLine $args[1] } '52:54:00:AA:BB:CC' $script:Neigh
        $ip | Should -BeNullOrEmpty
    }

    It 'matches case-insensitively, since the kernel prints lowercase and the driver stores canonical' {
        $upper = & $script:Driver { Get-KvmNeighborIp -Mac $args[0] -NeighborLine $args[1] } '52:54:00:1A:B2:C3' $script:Neigh
        $lower = & $script:Driver { Get-KvmNeighborIp -Mac $args[0] -NeighborLine $args[1] } '52:54:00:1a:b2:c3' $script:Neigh
        $upper | Should -Be $lower
        $upper | Should -Be '192.168.7.70'
    }

    It 'returns nothing when the MAC is unknown or absent' {
        (& $script:Driver { Get-KvmNeighborIp -Mac '52:54:00:99:99:99' -NeighborLine $args[0] } $script:Neigh) | Should -BeNullOrEmpty
        (& $script:Driver { Get-KvmNeighborIp -Mac '' -NeighborLine $args[0] } $script:Neigh) | Should -BeNullOrEmpty
    }
}

Describe 'Get-HostIpv4Prefix' {

    It 'reads the prefix length rather than assuming /24' {
        # The sweep is only defensible on a /24; a driver that assumed one would
        # scan 65k addresses of the operator's LAN from a /16 host.
        Mock -ModuleName Yuruna.Host -CommandName Get-BestHostIp -MockWith { '10.0.0.5' }
        $addr = @('2: eth0    inet 10.0.0.5/16 brd 10.0.255.255 scope global eth0')
        $got = & $script:Driver { Get-HostIpv4Prefix -AddrLine $args[0] } $addr
        $got.Length  | Should -Be 16
        $got.Prefix  | Should -Be '10.0.0'
        $got.Address | Should -Be '10.0.0.5'
    }

    It 'returns nothing when no address line matches this host' {
        Mock -ModuleName Yuruna.Host -CommandName Get-BestHostIp -MockWith { '10.0.0.5' }
        $addr = @('2: eth0    inet 172.31.0.9/20 brd 172.31.15.255 scope global eth0')
        (& $script:Driver { Get-HostIpv4Prefix -AddrLine $args[0] } $addr) | Should -BeNullOrEmpty
    }

    It 'refuses to sweep a prefix wider than /24' {
        # The guard that turns a lookup back into a lookup instead of a scan.
        Mock -ModuleName Yuruna.Host -CommandName Get-BestHostIp -MockWith { '10.0.0.5' }
        Mock -ModuleName Yuruna.Host -CommandName Get-VMState -MockWith { 'running' }
        Mock -ModuleName Yuruna.Host -CommandName Get-HostIpv4Prefix -MockWith {
            @{ Address = '10.0.0.5'; Length = 16; Prefix = '10.0.0' }
        }
        $swept = & $script:Driver { Update-GuestNeighborCache -VMName 'any' -Confirm:$false }
        $swept | Should -BeFalse
    }

    It 'sweeps at most once per VM inside the cooldown' {
        Mock -ModuleName Yuruna.Host -CommandName Get-VMState -MockWith { 'running' }
        Mock -ModuleName Yuruna.Host -CommandName Get-HostIpv4Prefix -MockWith {
            @{ Address = '198.51.100.5'; Length = 24; Prefix = '198.51.100' }
        }
        # RFC 5737 documentation range: nothing on it answers, so the sweep is a
        # no-op on the wire while still exercising the memo.
        $first  = & $script:Driver { Update-GuestNeighborCache -VMName 'cooldown-probe' -Confirm:$false }
        $second = & $script:Driver { Update-GuestNeighborCache -VMName 'cooldown-probe' -Confirm:$false }
        $first  | Should -BeTrue
        $second | Should -BeFalse
    }
}

Describe 'The contract this chain owes its callers' {

    It 'exports Update-GuestNeighborCache so no caller has to feature-detect a probe by name' {
        (Get-Command -Module Yuruna.Host -Name Update-GuestNeighborCache -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It 'declines to sweep a VM that is not running' {
        # The running-state check is the guard that keeps a teardown loop from
        # paying for a /24 sweep per absent domain.
        $swept = & $script:Driver {
            Update-GuestNeighborCache -VMName 'yuruna-no-such-domain-for-tests' -Confirm:$false
        }
        $swept | Should -BeFalse
    }
}

Describe 'Invoke-GuestSsh honours the unresolved-address sentinel' {
    # WHY THIS BLOCK IS HERE. Get-GuestAddress answers with the VM name when no
    # probe found an address. Four consumers test for that; Invoke-GuestSsh was
    # the one that did not, so every transient discovery miss became a hard step
    # failure reported as a guest script error. The invariant is asserted by name
    # in Test.GuestAddressChurn.Tests.ps1, but only for a consumer that already
    # got it right -- these cases cover the one that did not.
    #
    # ssh really runs. Both targets below fail in single-digit milliseconds (an
    # unresolvable name, and a loopback that refuses the harness key), so the
    # cases stay fast without mocking System.Diagnostics.Process.

    BeforeAll {
        Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Test.Ssh.psm1') -Force -DisableNameChecking -Global
    }

    It 're-resolves once when the first lookup returns the bare VM name' {
        Mock -ModuleName Test.Ssh -CommandName Get-GuestAddress -MockWith { 'yuruna-unresolvable-test-host' }
        Mock -ModuleName Test.Ssh -CommandName Wait-GuestIp     -MockWith { $null }
        $r = Invoke-GuestSsh -VMName 'yuruna-unresolvable-test-host' -GuestKey 'guest.ubuntu.server.24' `
                -Command 'true' -TimeoutSeconds 20 -AddressWaitSeconds 5 -WarningAction SilentlyContinue
        Should -Invoke -ModuleName Test.Ssh -CommandName Wait-GuestIp -Times 1 -Exactly
        $r.addressResolved | Should -BeFalse
    }

    It 'reports a discovery failure as its own exit code, not ssh 255' {
        # 255 is what ssh returns for auth and host-key faults too, so the code
        # alone sends a reader to the guest for a fault that is on the host.
        Mock -ModuleName Test.Ssh -CommandName Get-GuestAddress -MockWith { 'yuruna-unresolvable-test-host' }
        Mock -ModuleName Test.Ssh -CommandName Wait-GuestIp     -MockWith { $null }
        $r = Invoke-GuestSsh -VMName 'yuruna-unresolvable-test-host' -GuestKey 'guest.ubuntu.server.24' `
                -Command 'true' -TimeoutSeconds 20 -AddressWaitSeconds 0 -WarningAction SilentlyContinue
        $r.success  | Should -BeFalse
        $r.exitCode | Should -Be -2
        $r.output   | Should -Match 'host address-discovery failure'
        $r.output   | Should -Match 'the command never ran'
    }

    It 'does not enter the wait when the caller passed an address as the VM name' {
        # -VMName is documented as accepting an address. For such a caller the
        # sentinel comparison is true on a perfectly good address, so the
        # Test-IpAddress half of the predicate is what keeps it out of the wait.
        Mock -ModuleName Test.Ssh -CommandName Get-GuestAddress -MockWith { '127.0.0.1' }
        Mock -ModuleName Test.Ssh -CommandName Wait-GuestIp     -MockWith { $null }
        $r = Invoke-GuestSsh -VMName '127.0.0.1' -GuestKey 'guest.ubuntu.server.24' `
                -Command 'true' -TimeoutSeconds 20 -AddressWaitSeconds 5 -WarningAction SilentlyContinue
        Should -Invoke -ModuleName Test.Ssh -CommandName Wait-GuestIp -Times 0 -Exactly
        $r.addressResolved | Should -BeTrue
        $r.exitCode        | Should -Not -Be -2
    }

    It 'adopts an address the re-resolve discovers and stops reporting a discovery fault' {
        Mock -ModuleName Test.Ssh -CommandName Get-GuestAddress -MockWith { 'yuruna-unresolvable-test-host' }
        Mock -ModuleName Test.Ssh -CommandName Wait-GuestIp     -MockWith { '127.0.0.1' }
        $r = Invoke-GuestSsh -VMName 'yuruna-unresolvable-test-host' -GuestKey 'guest.ubuntu.server.24' `
                -Command 'true' -TimeoutSeconds 20 -AddressWaitSeconds 5 -WarningAction SilentlyContinue
        $r.addressResolved | Should -BeTrue
        $r.exitCode        | Should -Not -Be -2
    }

    It 'skips the wait entirely when the caller is already polling' {
        Mock -ModuleName Test.Ssh -CommandName Get-GuestAddress -MockWith { 'yuruna-unresolvable-test-host' }
        Mock -ModuleName Test.Ssh -CommandName Wait-GuestIp     -MockWith { $null }
        $null = Invoke-GuestSsh -VMName 'yuruna-unresolvable-test-host' -GuestKey 'guest.ubuntu.server.24' `
                -Command 'true' -TimeoutSeconds 20 -AddressWaitSeconds 0 -WarningAction SilentlyContinue
        Should -Invoke -ModuleName Test.Ssh -CommandName Wait-GuestIp -Times 0 -Exactly
    }
}
