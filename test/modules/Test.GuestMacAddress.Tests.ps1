<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42b98737-f5a4-45fd-a853-c26c9d97ec84
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna mac address dhcp lease determinism pester
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
    Deterministic guest MAC derivation: one address per (host, guest), forever.
.DESCRIPTION
    WHAT THIS PROTECTS. Every hypervisor hands a freshly-built VM a random MAC, and
    a lab rebuilds its guests constantly -- so each build asked the DHCP server for a
    NEW lease while the old one was still held by a guest that no longer existed. The
    shared pool drained until it had nothing left, and guests then booted with no
    IPv4 at all: `wget` failed, the guest script exited non-zero, and cycles failed
    across unrelated hosts and hypervisors with no common cause visible from any one
    of them.

    The property that fixes it is narrow and worth pinning precisely: the SAME host
    rebuilding the SAME guest must present the SAME MAC, so the server returns the
    lease it already holds instead of allocating another. Everything else here
    guards the ways that property can be lost -- casing drift in a name, a host
    part that stops being stable, a layout that lets two hosts collide on the guest
    names they share, or an address that moves out from under a guest mid-life
    because it was keyed on a name the guest does not keep.

    Assertions are plain throws and the Pester harness is shimmed when Pester is
    absent, so this runs either way.
    Run: pwsh -NoProfile -File test/modules/Test.GuestMacAddress.Tests.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command -Name 'Describe' -ErrorAction SilentlyContinue)) {
    function Describe { param([string]$Name, [scriptblock]$Fixture) Write-Output "Describe: $Name"; & $Fixture }
    function It       { param([string]$Name, [scriptblock]$Test)    & $Test; Write-Output "    [pass] $Name" }
}

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# A representative slot name: the shape the harness actually builds
# (testVmNamePrefix + guest key + instance number).
$script:VM1 = 'test-guest.ubuntu.server.24-01'
$script:VM2 = 'test-guest.ubuntu.server.24-02'
$script:HOSTA = '422dd0cac87e4cc6831c3228f12ae689'
$script:HOSTB = '42512149e3dc437ca677a40828382528'

# Fixtures for the rename block far below. Every fixture this file uses lives
# in the BeforeAll, which is the scope Pester 5 shares with the It blocks:
# discovery and run are separate passes, so a variable assigned at file scope
# is already gone by the time a test body reads it and binds as empty.
$KvmModule    = Join-Path $repoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'
$script:UtmModule    = Join-Path $repoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
$script:HyperVModule = Join-Path $repoRoot 'host/windows.hyper-v/modules/Yuruna.Host.psm1'
$KvmText      = Get-Content -Raw -LiteralPath $KvmModule

# Define the KVM rewriter and its reader from their own source so the behavior
# asserted below is the shipped one, without importing a module that expects a
# live libvirt.
. ([scriptblock]::Create([regex]::Match($KvmText, '(?ms)^function Set-GuestMacInDomainXml\b.*?\n\}').Value))
. ([scriptblock]::Create([regex]::Match($KvmText, '(?ms)^function Get-GuestMacFromDomainXml\b.*?\n\}').Value))

# The nine guest builders that take a -Hostname: the ones whose guests are
# promoted out of the shared slot, and so the ones that must key on the identity
# the guest keeps rather than on the slot it is built in. The rest (service VMs,
# windows.11, macos.26) carry one fixed name for life, where the two coincide.
$script:PromotableBuilders = @(
    'host/windows.hyper-v/guest.ubuntu.server.24/New-VM.ps1'
    'host/windows.hyper-v/guest.ubuntu.server.26/New-VM.ps1'
    'host/windows.hyper-v/guest.amazon.linux.2023/New-VM.ps1'
    'host/ubuntu.kvm/guest.ubuntu.server.24/New-VM.ps1'
    'host/ubuntu.kvm/guest.ubuntu.server.26/New-VM.ps1'
    'host/ubuntu.kvm/guest.amazon.linux.2023/New-VM.ps1'
    'host/macos.utm/guest.ubuntu.server.24/New-VM.ps1'
    'host/macos.utm/guest.ubuntu.server.26/New-VM.ps1'
    'host/macos.utm/guest.amazon.linux.2023/New-VM.ps1'
)

function Format-DomainXml {
    param([string]$Mac, [int]$NicCount = 1)
    $nics = (1..$NicCount | ForEach-Object {
        "    <interface type='network'>`n      <mac address='$Mac'/>`n    </interface>"
    }) -join "`n"
    "<domain type='kvm'>`n  <name>amisad-build</name>`n  <devices>`n$nics`n  </devices>`n</domain>"
}
}

Describe 'Get-YurunaGuestMacAddress -- the identity property' {
    It 'returns the SAME MAC for the same host and VM, every time' {
        # This is the whole point: a rebuilt guest must reclaim its existing lease.
        $first = Get-YurunaGuestMacAddress -VMName $script:VM1 -HostId $script:HOSTA
        foreach ($i in 1..25) {
            Assert-Equal -Expected $first -Actual (Get-YurunaGuestMacAddress -VMName $script:VM1 -HostId $script:HOSTA) -Because 'derivation is deterministic'
        }
    }
    It 'ignores casing and surrounding whitespace in both inputs' {
        # An operator retyping a VM name with different casing must not mint a
        # second identity for a slot that already has one.
        $canonical = Get-YurunaGuestMacAddress -VMName $script:VM1 -HostId $script:HOSTA
        Assert-Equal -Expected $canonical -Actual (Get-YurunaGuestMacAddress -VMName $script:VM1.ToUpperInvariant() -HostId $script:HOSTA.ToUpperInvariant()) -Because 'case-insensitive'
        Assert-Equal -Expected $canonical -Actual (Get-YurunaGuestMacAddress -VMName "  $script:VM1  " -HostId "  $script:HOSTA  ") -Because 'whitespace-insensitive'
    }
}

Describe 'Get-YurunaGuestMacAddress -- the wire format' {
    It 'is a canonical uppercase MAC starting with the Yuruna 42 marker' {
        $mac = Get-YurunaGuestMacAddress -VMName $script:VM1 -HostId $script:HOSTA
        Assert-True ($mac -cmatch '^42(:[0-9A-F]{2}){5}$') "got '$mac'; expected 42:XX:XX:XX:XX:XX uppercase"
    }
    It 'is a valid locally-administered UNICAST address' {
        # 0x42 = 0100 0010: bit 0 (multicast) clear so a NIC can source from it and
        # DHCP will lease to it; bit 1 (locally administered) set so it cannot
        # collide with a real vendor OUI on the LAN. Both matter -- a multicast
        # first octet is silently never leased.
        $first = [Convert]::ToInt32(((Get-YurunaGuestMacAddress -VMName $script:VM1 -HostId $script:HOSTA) -split ':')[0], 16)
        Assert-Equal -Expected 0 -Actual ($first -band 0x01) -Because 'unicast (multicast bit clear)'
        Assert-Equal -Expected 2 -Actual ($first -band 0x02) -Because 'locally administered bit set'
    }
    It 'survives the shared MAC validator unchanged' {
        $mac = Get-YurunaGuestMacAddress -VMName $script:VM1 -HostId $script:HOSTA
        Assert-Equal -Expected $mac -Actual (ConvertTo-YurunaMacAddress -MacAddress $mac) -Because 'already canonical'
    }
}

Describe 'Get-YurunaGuestMacAddress -- the 42:HH:HH:VV:VV:VV layout' {
    It 'keeps the host pair constant across every guest on one host' {
        # This is what makes a DHCP lease table readable: all of a host's leases
        # share a visible prefix, so an operator can group them by machine.
        $prefix = ((Get-YurunaGuestMacAddress -VMName $script:VM1 -HostId $script:HOSTA) -split ':')[0..2] -join ':'
        foreach ($vm in @($script:VM2, 'test-guest.windows.11-01', 'test-guest.amazon.linux.2023-01')) {
            $got = ((Get-YurunaGuestMacAddress -VMName $vm -HostId $script:HOSTA) -split ':')[0..2] -join ':'
            Assert-Equal -Expected $prefix -Actual $got -Because "host pair is stable for '$vm'"
        }
    }
    It 'gives different hosts different host pairs' {
        $a = ((Get-YurunaGuestMacAddress -VMName $script:VM1 -HostId $script:HOSTA) -split ':')[1..2] -join ':'
        $b = ((Get-YurunaGuestMacAddress -VMName $script:VM1 -HostId $script:HOSTB) -split ':')[1..2] -join ':'
        Assert-NotEqual -NotExpected $a -Actual $b -Because 'host pair separates hosts'
    }
    It 'gives different guest slots on one host different addresses' {
        Assert-NotEqual -NotExpected (Get-YurunaGuestMacAddress -VMName $script:VM1 -HostId $script:HOSTA) `
                        -Actual      (Get-YurunaGuestMacAddress -VMName $script:VM2 -HostId $script:HOSTA) -Because 'slots must not share a lease'
    }
    It 'varies the VM bytes BY HOST, not by name alone' {
        # The subtle one. Guest slots are named identically on every host
        # ('test-guest.ubuntu.server.24-01' exists everywhere), so hashing the name
        # by itself would make the whole address depend on the two host bytes --
        # and two hosts landing on the same pair would then collide on every guest
        # they share. Mixing the host into the VM hash restores the full 40 bits.
        $a = ((Get-YurunaGuestMacAddress -VMName $script:VM1 -HostId $script:HOSTA) -split ':')[3..5] -join ':'
        $b = ((Get-YurunaGuestMacAddress -VMName $script:VM1 -HostId $script:HOSTB) -split ':')[3..5] -join ':'
        Assert-NotEqual -NotExpected $a -Actual $b -Because 'same slot name on two hosts must not share VM bytes'
    }
}

Describe 'Get-YurunaGuestMacAddress -- fleet-scale uniqueness' {
    It 'produces no duplicates across a lab far larger than the real one' {
        # 60 hosts x 12 slots, with the SAME slot names repeated on every host --
        # the arrangement that would expose a layout whose uniqueness rested on the
        # host bytes alone.
        $slots = @('test-guest.ubuntu.server.24-01','test-guest.ubuntu.server.24-02',
                   'test-guest.ubuntu.server.26-01','test-guest.ubuntu.server.26-02',
                   'test-guest.amazon.linux.2023-01','test-guest.windows.11-01',
                   'yuruna-caching-proxy-service','yuruna-stash-service',
                   'yuruna-pool-control-service','yuruna-download-agent-service',
                   'test-guest.macos.26-01','test-guest.ubuntu.server.24-03')
        $seen = @{}
        $dupes = 0
        foreach ($h in 1..60) {
            $hostId = '42{0:x30}' -f $h
            foreach ($s in $slots) {
                $mac = Get-YurunaGuestMacAddress -VMName $s -HostId $hostId
                if ($seen.ContainsKey($mac)) { $dupes++ }
                $seen[$mac] = "$hostId/$s"
            }
        }
        Assert-Equal -Expected 720 -Actual $seen.Count -Because 'every (host, slot) pair got its own address'
        Assert-Equal -Expected 0   -Actual $dupes     -Because 'no two slots share a MAC'
    }
}

Describe 'Get-YurunaHostMacSeed -- what the host half is keyed on' {
    It 'prefers an explicitly supplied host id' {
        Assert-Equal -Expected $script:HOSTA -Actual (Get-YurunaHostMacSeed -HostId $script:HOSTA) -Because 'explicit wins'
        Assert-Equal -Expected $script:HOSTA -Actual (Get-YurunaHostMacSeed -HostId "  $script:HOSTA ") -Because 'trimmed'
    }
    It 'falls back to something STABLE, never to randomness, when no id exists' {
        # A random fallback would hand every guest a new MAC on every build -- the
        # exact behavior this mechanism exists to remove -- and it would do so
        # silently, on precisely the hosts that have not finished a cycle yet.
        $saved = $env:YURUNA_RUNTIME_DIR
        try {
            $env:YURUNA_RUNTIME_DIR = (Join-Path ([System.IO.Path]::GetTempPath()) ('mac-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
            $first = Get-YurunaHostMacSeed
            Assert-True (-not [string]::IsNullOrWhiteSpace($first)) 'a seed is always produced'
            foreach ($i in 1..5) {
                Assert-Equal -Expected $first -Actual (Get-YurunaHostMacSeed) -Because 'fallback seed is stable across calls'
            }
        } finally { $env:YURUNA_RUNTIME_DIR = $saved }
    }
    It 'reads the host id from runtime/host.uuid when one is present' {
        $saved = $env:YURUNA_RUNTIME_DIR
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('mac-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            Set-Content -LiteralPath (Join-Path $tmp 'host.uuid') -Value "$script:HOSTB`n" -NoNewline
            $env:YURUNA_RUNTIME_DIR = $tmp
            Assert-Equal -Expected $script:HOSTB -Actual (Get-YurunaHostMacSeed) -Because 'host.uuid is the preferred seed'
            Assert-Equal -Expected (Get-YurunaGuestMacAddress -VMName $script:VM1 -HostId $script:HOSTB) `
                         -Actual  (Get-YurunaGuestMacAddress -VMName $script:VM1) -Because 'resolved seed matches an explicit one'
        } finally {
            $env:YURUNA_RUNTIME_DIR = $saved
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'the guest is pinned at build time to the identity it keeps' {
    # No guest keeps the name it was BUILT with: every one is built as the
    # per-kind slot and promoted afterwards (test-guest.ubuntu.server.24-01 ->
    # amisad-core-k8s -> amisad-core). Keying the address on the name the VM
    # happens to carry therefore moves it twice mid-life, and a guest that
    # recorded its own address while it held the first one never answers there
    # again -- a kubeadm control plane writes it into certificates, etcd URLs
    # and every kubeconfig, so nothing short of a rebuild recovers. Keying on
    # the identity the guest keeps (its declared hostname) makes the promotion
    # a pure metadata change.

    It 'derives from the guest identity, not the slot the VM is built in' {
        foreach ($rel in $script:PromotableBuilders) {
            $text = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $rel)
            Assert-True ($text -match '\$GuestHostname\s*=\s*if\s*\(\$Hostname\)') "$rel resolves a guest identity"
            Assert-True ($text -match 'Get-YurunaGuestMacAddress\s+-VMName\s+\$GuestHostname') `
                "$rel must key its NIC on the guest identity; keying on `$VMName pins the slot's address into whatever the guest records"
            Assert-True ($text -notmatch 'Get-YurunaGuestMacAddress\s+-VMName\s+\$VMName') "$rel has no slot-keyed derivation left"
        }
    }
    It 'has an identity that outlives the names the VM is promoted through' {
        # amisad-core is built in the slot, promoted to amisad-core-k8s, then to
        # amisad-core: three names, one guest. Keyed on the name it carries the
        # address would move at each step -- which is what makes the input to the
        # derivation, asserted above, the whole of the fix.
        $carried = @($script:VM1, 'amisad-core-k8s', 'amisad-core')
        $byCarriedName = @($carried | ForEach-Object { Get-YurunaGuestMacAddress -VMName $_ -HostId $script:HOSTA })
        Assert-Equal -Expected $carried.Count -Actual (@($byCarriedName | Select-Object -Unique).Count) `
            -Because 'each name the VM wears derives its own address, so the carried name cannot be the key'
    }
    It 'still separates guests built one after another in the same slot' {
        # The collision this whole scheme guards: four guests built serially in
        # one slot must never end up sharing an address on one switch.
        $macs = @('amisad-build', 'amisad-edge-a', 'amisad-edge-b', 'amisad-core') |
            ForEach-Object { Get-YurunaGuestMacAddress -VMName $_ -HostId $script:HOSTA }
        Assert-Equal -Expected 4 -Actual (@($macs | Select-Object -Unique).Count) -Because 'four identities, four addresses'
        Assert-True ($macs -notcontains (Get-YurunaGuestMacAddress -VMName $script:VM1 -HostId $script:HOSTA)) `
            'and none of them is the slot address, so the next build of the slot is free'
    }
}

Describe 'Test-YurunaGuestMacMatchesName -- whose address is this NIC on?' {
    It 'recognizes the address a name derives, in any notation a hypervisor reports' {
        $mac = Get-YurunaGuestMacAddress -VMName $script:VM1 -HostId $script:HOSTA
        foreach ($form in @($mac, $mac.ToLowerInvariant(), ($mac -replace ':', ''), ($mac -replace ':', '-'))) {
            Assert-True (Test-YurunaGuestMacMatchesName -MacAddress $form -VMName $script:VM1 -HostId $script:HOSTA) `
                "'$form' is the same address as '$mac'"
        }
    }
    It 'says no for an address belonging to any other name' {
        $mac = Get-YurunaGuestMacAddress -VMName $script:VM1 -HostId $script:HOSTA
        Assert-True (-not (Test-YurunaGuestMacMatchesName -MacAddress $mac -VMName 'amisad-core' -HostId $script:HOSTA)) `
            'a guest on its own identity must not be mistaken for one on the slot address'
        Assert-True (-not (Test-YurunaGuestMacMatchesName -MacAddress '52:54:00:aa:bb:cc' -VMName $script:VM1 -HostId $script:HOSTA)) `
            'nor must an address this scheme never issued'
    }
    It 'treats an address it could not read as no match, quietly' {
        # The caller acts on $true by rewriting a NIC. An unreadable adapter must
        # therefore answer $false -- and without a warning, because this is a
        # question about state, not an assertion that the state is wrong.
        foreach ($bad in @('', '   ', 'not-a-mac', '42:7E:F9:EA:82')) {
            Assert-True (-not (Test-YurunaGuestMacMatchesName -MacAddress $bad -VMName $script:VM1 -HostId $script:HOSTA -WarningAction Stop)) `
                "'$bad' is not a match"
        }
    }
}

Describe 'a rename releases the name it vacates, and nothing else' {
    # The rewrite still exists for the guest that never declared an identity of
    # its own: it was pinned to the slot, and leaving it there means the NEXT
    # build of the slot asks for an address already in use -- a refused build on
    # libvirt, and two live NICs sharing an address on the hypervisors that do
    # not check. The test is whether the NIC is on the OUTGOING name's address:
    # that address belongs to the name, every other one belongs to the guest.

    It 'rewrites the domain NIC to the address the NEW name derives' {
        $slotMac = (Get-YurunaGuestMacAddress -VMName $script:VM1).ToLowerInvariant()
        $out = Set-GuestMacInDomainXml -DomainXml (Format-DomainXml -Mac $slotMac) -VMName 'amisad-build'
        $want = (Get-YurunaGuestMacAddress -VMName 'amisad-build').ToLowerInvariant()
        Assert-True ($out -match "<mac address='$want'/>") "expected the promoted name's address; got: $out"
        Assert-True ($out -notmatch [regex]::Escape($slotMac)) 'the slot address is gone, so the next build of the slot can have it'
    }
    It 'frees the slot address for the next build, and separates the promoted guests' {
        # The actual failure: build slot -> promote to amisad-build -> build slot
        # again -> promote to amisad-edge-a. All three addresses must differ.
        $slotMac = (Get-YurunaGuestMacAddress -VMName $script:VM1).ToLowerInvariant()
        $build = [regex]::Match((Set-GuestMacInDomainXml -DomainXml (Format-DomainXml -Mac $slotMac) -VMName 'amisad-build'), "address='([^']+)'").Groups[1].Value
        $edge  = [regex]::Match((Set-GuestMacInDomainXml -DomainXml (Format-DomainXml -Mac $slotMac) -VMName 'amisad-edge-a'), "address='([^']+)'").Groups[1].Value
        Assert-NotEqual -NotExpected $slotMac -Actual $build -Because 'the promoted VM must release the slot address'
        Assert-NotEqual -NotExpected $slotMac -Actual $edge  -Because 'and so must the next one'
        Assert-NotEqual -NotExpected $build   -Actual $edge  -Because 'two promoted guests must not share an address'
    }
    It 'writes the address in the casing libvirt itself uses' {
        # dumpxml emits lowercase. Matching it keeps an unchanged domain comparing
        # equal to its dump, so the rename does not redefine a domain needlessly.
        $mac = [regex]::Match((Set-GuestMacInDomainXml -DomainXml (Format-DomainXml -Mac '52:54:00:aa:bb:cc') -VMName 'amisad-build'), "address='([^']+)'").Groups[1].Value
        Assert-Equal -Expected $mac.ToLowerInvariant() -Actual $mac -Because 'lowercase, as dumpxml writes it'
    }
    It 'leaves a second interface alone rather than duplicating one address' {
        # A second NIC needs a second DISTINCT address; giving it this one twice
        # would recreate on a single guest what the rewrite exists to prevent.
        $out = Set-GuestMacInDomainXml -DomainXml (Format-DomainXml -Mac '52:54:00:aa:bb:cc' -NicCount 2) -VMName 'amisad-build'
        Assert-Equal -Expected 1 -Actual ([regex]::Matches($out, "52:54:00:aa:bb:cc").Count) -Because 'only the first NIC is rewritten'
    }
    It 'returns XML with no interface unchanged' {
        $noNic = "<domain type='kvm'><name>amisad-build</name><devices/></domain>"
        Assert-Equal -Expected $noNic -Actual (Set-GuestMacInDomainXml -DomainXml $noNic -VMName 'amisad-build') -Because 'nothing to rewrite'
        Assert-Equal -Expected '' -Actual (Set-GuestMacInDomainXml -DomainXml '' -VMName 'amisad-build') -Because 'empty dumpxml is not an error here'
    }

    It 'is applied by the libvirt rename, in the same define as the disk paths' {
        $body = [regex]::Match($KvmText, '(?ms)^function Rename-VM\b.*?\n\}').Value
        Assert-True ($body -match 'Set-GuestMacInDomainXml') 'the rename re-pins the NIC'
        $rewriteAt = $body.IndexOf('Set-GuestMacInDomainXml')
        $defineAt  = $body.IndexOf("'define'", $rewriteAt)
        Assert-True ($rewriteAt -ge 0 -and $defineAt -gt $rewriteAt) 'the rewrite lands in the XML that is then defined'
    }
    It 'is applied by the UTM rename, while UTM is quit and before it reloads' {
        # UTM reads config.plist when it loads a VM and holds that copy for the
        # life of the app, so a write while it holds the VM changes the file and
        # not the running configuration.
        $body = [regex]::Match((Get-Content -Raw -LiteralPath $script:UtmModule), '(?ms)^function Rename-VM\b.*?\n\}').Value
        Assert-True ($body -match 'Set-GuestMacInBundle') 'the rename re-pins the NIC'
        $quitAt   = $body.IndexOf('to quit')
        $macAt    = $body.IndexOf('Set-GuestMacInBundle')
        $reopenAt = $body.IndexOf('open -a UTM', $macAt)
        Assert-True ($quitAt -ge 0 -and $quitAt -lt $macAt) 'UTM is quit before the address is written'
        Assert-True ($reopenAt -gt $macAt) 'and relaunched after, so it loads the new value'
    }
    It 'is applied by the Hyper-V rename, after the VM answers to the new name' {
        $body = [regex]::Match((Get-Content -Raw -LiteralPath $script:HyperVModule), '(?ms)^function Rename-VM\b.*?\n\}').Value
        Assert-True ($body -match 'StaticMacAddress') 'the rename re-pins the NIC'
        $renameAt = $body.IndexOf('Hyper-V\Rename-VM -Name')
        $macAt    = $body.IndexOf('StaticMacAddress')
        Assert-True ($renameAt -ge 0 -and $macAt -gt $renameAt) 'set on the new name, which is the name the address derives from'
    }
    It 'derives from the destination name on every host type' {
        # Deriving from $VMName would re-pin the address the guest already has:
        # a no-op that reads like a fix.
        foreach ($m in @($KvmModule, $script:UtmModule, $script:HyperVModule)) {
            $body = [regex]::Match((Get-Content -Raw -LiteralPath $m), '(?ms)^function Rename-VM\b.*?\n\}').Value
            $line = @($body -split "`n" | Where-Object { $_ -match 'Set-GuestMacInDomainXml|Set-GuestMacInBundle|StaticMacAddress' })[0]
            Assert-True ($line -match '\$NewName') "in $(Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $m))): '$line' must key on the destination name"
        }
    }
    It 'reads the same first NIC the rewrite would replace' {
        Assert-Equal -Expected '52:54:00:aa:bb:cc' `
                     -Actual (Get-GuestMacFromDomainXml -DomainXml (Format-DomainXml -Mac '52:54:00:aa:bb:cc')) `
                     -Because 'the value compared is the value about to be overwritten'
        Assert-Equal -Expected '' -Actual (Get-GuestMacFromDomainXml -DomainXml "<domain type='kvm'><devices/></domain>") -Because 'no NIC, nothing to move'
        Assert-Equal -Expected '' -Actual (Get-GuestMacFromDomainXml -DomainXml '') -Because 'empty dumpxml is not an error here'
    }
    It 'asks whose address the NIC is on before touching it, on every host type' {
        # The guard, not the rewrite, is what keeps a promoted guest on the
        # address it was built with. Without it the rename re-keys every NIC it
        # passes -- including one already pinned to the guest's own identity,
        # whose in-guest state records the address it currently answers on.
        foreach ($m in @($KvmModule, $script:UtmModule, $script:HyperVModule)) {
            $where = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $m))
            $body  = [regex]::Match((Get-Content -Raw -LiteralPath $m), '(?ms)^function Rename-VM\b.*?\n\}').Value
            $guardAt = $body.IndexOf('Test-YurunaGuestMacMatchesName')
            Assert-True ($guardAt -ge 0) "in ${where}: the rename must ask before it rewrites"
            $guardLine = @($body -split "`n" | Where-Object { $_ -match 'Test-YurunaGuestMacMatchesName' })[0]
            Assert-True ($guardLine -match '-VMName\s+\$VMName') `
                "in ${where}: the guard must key on the OUTGOING name -- that is the address being vacated"
            $setterAt = @(@($body.IndexOf('Set-GuestMacInDomainXml -DomainXml $newXmlText'),
                            $body.IndexOf('Set-GuestMacInBundle -VMName'),
                            $body.IndexOf('-StaticMacAddress')) | Where-Object { $_ -ge 0 })[0]
            Assert-True ($setterAt -gt $guardAt) "in ${where}: the rewrite must come after the question, not before it"
        }
    }
}

Describe 'every New-VM.ps1 derives its MAC (no randomness left)' {
    It 'has no random-MAC generator anywhere under host/' {
        $rand = @(Get-ChildItem (Join-Path $repoRoot 'host') -Recurse -Filter 'New-VM.ps1' |
            Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match 'NextBytes\(\$MacBytes\)' })
        Assert-Equal -Expected 0 -Actual $rand.Count -Because "these still randomize: $(($rand | ForEach-Object { $_.FullName }) -join ', ')"
    }
    It 'calls the shared derivation from every New-VM.ps1' {
        $all  = @(Get-ChildItem (Join-Path $repoRoot 'host') -Recurse -Filter 'New-VM.ps1')
        $with = @($all | Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match 'Get-YurunaGuestMacAddress' })
        Assert-Equal -Expected $all.Count -Actual $with.Count -Because 'every guest builder pins its MAC'
    }
}
