<#PSScriptInfo
.VERSION 2026.08.21
.GUID 42d109f3-873a-4131-8420-1d54845d2805
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test kvm libvirt rail addressing pester
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
# suite that executed no assertion at all.
if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error ("Pester is not available, so this suite cannot run. Install it with " +
                 "'Install-Module Pester -Scope CurrentUser', then re-run with " +
                 "Invoke-Pester -Path '$PSCommandPath'.")
    exit 1
}

<#
.SYNOPSIS
    The derivation behind the guest-to-guest rail: one guest name, one MAC and
    one address, the same answer everywhere.
.DESCRIPTION
    WHY THIS EXISTS. The rail's value is that a guest can address a peer without
    looking anything up -- so the derivation has to give the same answer in a
    different process, before the VM exists, and after it is gone. If it ever
    disagrees with itself, a reservation is made for one address while a peer
    dials another, and the failure looks like a network fault rather than a
    naming one.

    Only the pure derivation is covered here. Reserving is a live libvirt
    operation with no seam worth inventing, and it is exercised on a host that
    has the network rather than pinned in a unit test.
#>

BeforeAll {
    $script:RailModule = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'host', 'ubuntu.kvm', 'modules', 'Yuruna.GuestRail.psm1'
    Import-Module $script:RailModule -Force -DisableNameChecking
}

Describe 'Get-GuestRailAddress' {

    It 'gives the same answer every time it is asked' {
        $a = Get-GuestRailAddress -VMName 'amisad-edge-a'
        $b = Get-GuestRailAddress -VMName 'amisad-edge-a'
        $a.Ip  | Should -Be $b.Ip
        $a.Mac | Should -Be $b.Mac
    }

    It 'treats the name case-insensitively, as libvirt does' {
        # Two spellings of one domain must not become two rail addresses, or a
        # peer that capitalises differently silently dials somewhere else.
        $lower = Get-GuestRailAddress -VMName 'amisad-edge-a'
        $upper = Get-GuestRailAddress -VMName 'AMISAD-EDGE-A'
        $upper.Ip  | Should -Be $lower.Ip
        $upper.Mac | Should -Be $lower.Mac
    }

    It 'separates the guests that actually talk to each other' {
        $names = 'amisad-core', 'amisad-edge-a', 'amisad-edge-b', 'amisad-build'
        $ips  = @($names | ForEach-Object { (Get-GuestRailAddress -VMName $_).Ip })
        $macs = @($names | ForEach-Object { (Get-GuestRailAddress -VMName $_).Mac })
        ($ips  | Sort-Object -Unique).Count | Should -Be $names.Count -Because 'the workload guests must not collide with each other'
        ($macs | Sort-Object -Unique).Count | Should -Be $names.Count
    }

    It 'stays inside the reservable band' {
        # Outside libvirt's DHCP range a reservation is simply never served, and
        # the guest falls back to a dynamic address that defeats the point.
        foreach ($n in 'a', 'b', 'some-much-longer-guest-name', 'x') {
            $r = Get-GuestRailAddress -VMName $n
            $r.Ip | Should -Match '^192\.168\.122\.(2[0-4][0-9])$' -Because "$n must land in .200-.249"
        }
    }

    It 'uses the QEMU OUI so the address reads as a KVM guest in a capture' {
        (Get-GuestRailAddress -VMName 'amisad-core').Mac | Should -Match '^52:54:00:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}$'
    }

    It 'carries the name it was asked about' {
        (Get-GuestRailAddress -VMName 'amisad-core').VMName | Should -Be 'amisad-core'
    }
}

Describe 'The rail is optional by construction' {

    It 'reports availability without throwing, on any host' {
        # Two of the three host types this workload runs on have no libvirt at
        # all. Asking must be safe there, because every caller asks first.
        { Test-GuestRailAvailable } | Should -Not -Throw
        (Test-GuestRailAvailable) | Should -BeOfType [bool]
    }

    It 'lists reservations without throwing, on any host' {
        { Get-GuestRailReservation } | Should -Not -Throw
    }
}
