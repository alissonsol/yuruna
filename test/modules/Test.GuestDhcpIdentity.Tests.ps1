<#PSScriptInfo
.VERSION 2026.09.12
.GUID 4223adbe-1c67-4f91-9007-d00e25adf8ec
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test dhcp identity client-id seed cloud-init pester
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
if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error ("Pester is not available, so this suite cannot run. Install it with " +
                 "'Install-Module Pester -Scope CurrentUser', then re-run with " +
                 "Invoke-Pester -Path '$PSCommandPath'.")
    exit 1
}

<#
.SYNOPSIS
    Every cloud-init guest is handed its DHCP client identity on the seed, in
    time for the first lease it ever asks for.
.DESCRIPTION
    WHY THIS EXISTS. A deterministic MAC does not by itself bound a guest's
    address. Both networkd and NetworkManager identify themselves by a DUID
    derived from /etc/machine-id, and cloud-init rewrites machine-id per
    instance -- so a guest with a perfectly stable MAC still asks for a NEW
    lease on every build, and on a week-long lease each abandoned address is
    held long after the guest is gone. `dhcp-identifier: mac` is what closes
    that, by making the identity the server keys on the same address the MAC
    already fixes.

    WHEN it is applied is as load-bearing as whether. cloud-init reads
    network-config BEFORE it configures networking; a runcmd, a bootcmd or an
    installer late-command all run after the interface is already up and the
    wrong-identity lease is already taken. A pin applied late is a lease too
    late, and it costs a full lease period every build.

    WHERE it is applied decides whether a fix reaches the fleet. Baked into an
    image, it holds only for guests built from an image new enough to have it,
    so a lab pulling fresh vendor images every few days and restoring baselines
    built before the fix keeps leaking with the fix nominally shipped. On the
    seed, it applies at instantiation -- so it holds on an image downloaded an
    hour ago and on a baseline that predates the pin entirely.

    This suite pins all three: which guests get it, that it rides the seed, and
    that the ISO builders which enumerate their inputs actually list it. That
    last one is the quiet failure: dropping the file into the seed directory is
    enough for the builders that image a whole directory and silently a no-op
    for the ones that name each file.

    Static assertions over the builders, because the thing under test is what a
    guest is BUILT with; there is no guest to run.
    Run: Invoke-Pester -Path test/modules/Test.GuestDhcpIdentity.Tests.ps1
#>

BeforeAll {
    # test/modules/<this file> -> test/modules -> test -> repo root.
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:SharedConfig = Join-Path $script:RepoRoot 'host/vmconfig/guest-dhcp.network-config'

    # The guests that receive the shared seed network-config. Scoped by RENDERER,
    # not by "does it run cloud-init": the file identifies interfaces by name
    # glob, and only netplan resolves a glob against real devices.
    #
    # That scope is a safety boundary rather than an optimization. Handing
    # cloud-init a network-config REPLACES the fallback it would otherwise
    # generate, so seeding this file to a guest whose renderer cannot resolve the
    # glob does not leave it "unpinned" -- it leaves it with no network
    # configuration at all, nothing claiming the NIC, and no route in but the
    # console it can no longer use to say so.
    $script:NetplanGuests = @(
        'guest.ubuntu.server.24', 'guest.ubuntu.server.26',
        'guest.caching-proxy-service', 'guest.download-agent-service',
        'guest.pool-control-service', 'guest.stash-service'
    )

    # Receives no seed network-config: whether a given match form resolves
    # under its renderer is settled only by a lab cycle, and an unresolved
    # config costs the whole guest. Its client identity rides its user-data
    # instead -- a networkd ClientIdentifier=mac drop-in plus a fallback
    # profile (the image's live renderer is systemd-networkd), with a
    # best-effort nmcli pin for a NetworkManager-managed build.
    $script:NonNetplanGuests = @('guest.amazon.linux.2023')

    # windows.11 and macos.26 are in neither list: their DHCP clients send the
    # MAC as the client identifier by default, so the deterministic MAC already
    # bounds them and there is nothing to pin.
    $script:CloudInitGuests = @($script:NetplanGuests)
    $script:HostKinds = @('ubuntu.kvm', 'windows.hyper-v', 'macos.utm')

    function Get-BuilderPathList {
        param([string]$Guest)
        $out = @()
        foreach ($h in $script:HostKinds) {
            $p = Join-Path $script:RepoRoot "host/$h/$Guest/New-VM.ps1"
            if (Test-Path -LiteralPath $p -PathType Leaf) { $out += $p }
        }
        return $out
    }
}

Describe 'the shared guest DHCP identity file' {

    It 'pins the client identity to the MAC on both interface-name families' {
        $text = Get-Content -Raw -LiteralPath $script:SharedConfig
        # Matched by NAME pattern, not by MAC: one file serves every guest on
        # every host type, and the interface is enp0s1 on UTM, eth0 on Hyper-V
        # and enp1s0 on KVM.
        foreach ($match in @('name: "en\*"', 'name: "eth\*"')) {
            $text | Should -Match $match
        }
        # Two entries, two pins. A file that pinned only the family this host
        # happens to use would pass a single-host check and leak on the others.
        @([regex]::Matches($text, '(?m)^\s*dhcp-identifier:\s*mac\s*$')).Count |
            Should -Be 2 -Because 'both interface families must carry the pin'
    }
}

Describe 'no seed buys a DHCP identity by taking the network down' {

    # The seed pin above lands before networking comes up, so nothing later has
    # to bounce a link to make it take effect. That matters because the bounce
    # is not a symmetric operation: NetworkManager keeps the networking-enabled
    # flag in /var/lib/NetworkManager/NetworkManager.state, so a disable whose
    # re-enable does not run outlives the boot that issued it AND every reboot
    # after it. On a guest reachable only by an OCR'd console, that removes the
    # one channel through which it could be repaired -- and the guest reports
    # the same "interface down" a dead switch would, so the failure reads as
    # lab infrastructure and gets investigated on a healthy host.
    #
    # An `off && on` pair does not make it safe either: the enable has to
    # survive the disable returning non-zero after the daemon already applied
    # it, which is what a contended first boot produces.
    It 'never disables networking globally from any cloud-init seed' {
        $seeds = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'host/vmconfig') -Filter '*.user-data' -File)
        $seeds.Count | Should -BeGreaterThan 0 -Because 'the seeds must actually have been found'
        $offenders = @()
        foreach ($s in $seeds) {
            $text = Get-Content -Raw -LiteralPath $s.FullName
            foreach ($pattern in @(
                'nmcli\s+networking\s+off',
                'nmcli\s+radio\s+all\s+off',
                'systemctl\s+stop\s+NetworkManager',
                'systemctl\s+stop\s+systemd-networkd',
                'ip\s+link\s+set\s+\S+\s+down'
            )) {
                if ($text -match $pattern) { $offenders += "$($s.Name): $pattern" }
            }
        }
        $offenders -join "`n" | Should -BeExactly '' -Because 'a seed that downs its own link can strand the guest past the boot that did it'
    }

    # The nmcli pin must still be asserted present on Amazon Linux: the live
    # image renders through systemd-networkd (where the identity rides the
    # ClientIdentifier drop-in asserted below), and this line is what keeps a
    # NetworkManager-managed build of the same family pinned too.
    It 'still pins the client identity on Amazon Linux without re-activating anything' {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'host/vmconfig/amazon.linux.2023.base.user-data')
        $text | Should -Match 'ipv4\.dhcp-client-id mac' -Because 'the belt-and-braces pin for a profile the seed config did not render'
        # Failures have to be visible. A silenced state change cannot be told
        # apart from one that never ran, and this guest is diagnosed from a
        # console capture where a missing line is the whole evidence.
        $text | Should -Not -Match 'ipv4\.dhcp-client-id mac 2>/dev/null'
    }

    # networkd keys DHCPv4 on a DUID derived from /etc/machine-id unless told
    # otherwise, and machine-id is regenerated on every build -- so without
    # this pin a deterministic MAC still presents a brand-new identity each
    # cycle and draws a brand-new address. Three parts, each load-bearing:
    # the drop-in pins the profile cloud-init's fallback renders, the 98-
    # profile claims the NIC on the boot where that fallback claimed nothing,
    # and the reload is what makes either visible to a daemon that started
    # before they were written.
    It 'pins the networkd identity on Amazon Linux, drop-in and fallback profile both' {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'host/vmconfig/amazon.linux.2023.base.user-data')
        # Substring count, not line-anchored: the drop-in's copy rides inside
        # a printf format string on one source line, the fallback profile's
        # copy is a line of its own.
        @([regex]::Matches($text, 'ClientIdentifier=mac')).Count |
            Should -BeGreaterOrEqual 2 -Because 'both the drop-in and the fallback profile must carry the pin'
        $text | Should -Match '98-yuruna-fallback-dhcp\.network' -Because 'the boot where the fallback claims nothing needs a claiming profile'
        $text | Should -Match 'networkctl reload' -Because 'a profile written after networkd started is inert until reloaded'
    }
}

Describe 'the guests that are handed a DHCP identity' {

    It 'ships the shared network-config from every cloud-init guest builder' {
        $missing = @()
        foreach ($guest in $script:CloudInitGuests) {
            foreach ($builder in (Get-BuilderPathList -Guest $guest)) {
                $text = Get-Content -Raw -LiteralPath $builder
                if ($text -notmatch 'guest-dhcp\.network-config') {
                    $missing += (Resolve-Path -Relative $builder)
                }
            }
        }
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'a cloud-init guest with no seeded identity takes a fresh lease on every build'
    }

    # The counterpart to the test above, and the one that matters more. Seeding
    # this file to a guest whose renderer cannot resolve a name glob is not a
    # weaker pin -- it is a guest with NO network configuration, because
    # network-config replaces cloud-init's fallback rather than adding to it.
    # The symptom is indistinguishable from a dead switch from outside the
    # guest: no address, no carrier reading, and only an OCR'd console left to
    # report it on. Asserted per builder rather than once, because the file has
    # to be absent on every hypervisor for the guest to be safe on any of them.
    It 'never seeds it to a guest whose renderer cannot resolve a name glob' {
        $offenders = @()
        foreach ($guest in $script:NonNetplanGuests) {
            $builders = @(Get-BuilderPathList -Guest $guest)
            $builders.Count | Should -BeGreaterThan 0 -Because "$guest must actually have builders to check"
            foreach ($builder in $builders) {
                $text = Get-Content -Raw -LiteralPath $builder
                # Ignore commentary: what matters is whether the file is COPIED
                # into the seed or named as an ISO input, not whether the
                # builder explains why it is skipped.
                $code = ($text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
                if ($code -match 'guest-dhcp\.network-config') { $offenders += (Resolve-Path -Relative $builder) }
            }
        }
        $offenders -join ', ' | Should -BeNullOrEmpty `
            -Because 'a glob-matched network-config on a NetworkManager guest leaves it with no configuration at all, not a weaker one'
    }

    # The test above names ONE file, and that is the hole a regression walked
    # through: seeding a DIFFERENT network-config -- matched by MAC rather than
    # by glob -- passed it while leaving every Amazon guest on every hypervisor
    # with its NIC unclaimed and IFF_UP clear.
    #
    # The invariant is not "do not ship that file". It is "ship this guest NO
    # network-config by any name". Supplying one replaces cloud-init's fallback,
    # so any config its renderer fails to resolve to a real device is strictly
    # worse than none, and whether a given match form resolves under
    # NetworkManager is not decidable by reading the parser -- only a lab cycle
    # settles it. So the seed stays empty and the destination filename is what
    # gets asserted, not the source.
    It 'writes no network-config of any name into a NetworkManager guest seed' {
        $offenders = @()
        foreach ($guest in $script:NonNetplanGuests) {
            $builders = @(Get-BuilderPathList -Guest $guest)
            $builders.Count | Should -BeGreaterThan 0 -Because "$guest must actually have builders to check"
            foreach ($builder in $builders) {
                $text = Get-Content -Raw -LiteralPath $builder
                $code = ($text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
                # Any write whose DESTINATION is a seed file called
                # network-config, whatever the source file was named. The
                # character class has to cover both spellings the builders use:
                # a quoted Join-Path argument ('network-config') and an
                # interpolated path ("$SeedDir/network-config"). Matching only
                # the slash form silently passes the quoted one, which is the
                # form the KVM builder uses.
                if ($code -match "[""'/\\]network-config") { $offenders += (Resolve-Path -Relative $builder) }
            }
        }
        $offenders -join ', ' | Should -BeNullOrEmpty `
            -Because 'a seeded network-config this renderer cannot resolve leaves the NIC unclaimed, which costs the whole guest'
    }

    It 'writes it to the seed as network-config, the name cloud-init reads' {
        # cloud-init's NoCloud datasource looks for exactly `network-config`
        # beside user-data and meta-data. A correct file under any other name
        # is inert, and inert in the silent direction: the guest boots, gets an
        # address, and simply gets a different one next time.
        foreach ($guest in $script:CloudInitGuests) {
            foreach ($builder in (Get-BuilderPathList -Guest $guest)) {
                $text = Get-Content -Raw -LiteralPath $builder
                $text | Should -Match "network-config'?\`"?\s*\)?\s*(-Force)?" -Because "$builder must land it as network-config"
                @([regex]::Matches($text, "[/\\']network-config")).Count |
                    Should -BeGreaterThan 0 -Because "$builder must name the destination network-config"
            }
        }
    }

    It 'lists it among the inputs of every ISO builder that enumerates them' {
        # genisoimage is handed each file by path, so a file dropped into the
        # seed directory it never names is simply left out of the image -- the
        # one shape where seeding the file is not enough, and the failure is
        # invisible because the ISO builds fine without it.
        $enumerating = @()
        foreach ($guest in $script:CloudInitGuests) {
            foreach ($builder in (Get-BuilderPathList -Guest $guest)) {
                $text = Get-Content -Raw -LiteralPath $builder
                if ($text -match 'genisoimage') { $enumerating += $builder }
            }
        }
        $enumerating.Count | Should -BeGreaterThan 0 -Because 'the KVM builders name their ISO inputs one by one'
        foreach ($builder in $enumerating) {
            $text = Get-Content -Raw -LiteralPath $builder
            # The genisoimage invocation itself, continuations included, must
            # mention the file -- not merely the Copy-Item above it.
            $call = [regex]::Match($text, '(?s)genisoimage.*?\|\s*Out-Null')
            $call.Success | Should -BeTrue -Because "$builder has a readable genisoimage invocation"
            $call.Value | Should -Match 'network-config' -Because "$builder must put network-config INTO the seed ISO"
        }
    }
}

Describe 'the ledger that decides whether a rebuilt guest kept its address' {

    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.VMUtility.psm1') -Force -Global -DisableNameChecking
        function Get-LedgerTempDir {
            $d = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-gaddr-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            return $d
        }
    }

    It 'never calls a first sighting a violation' {
        # An identity with no prior address is being RECORDED, not judged. A lab
        # that has just added a guest and one that is leaking addresses look the
        # same on that first build, and only the second is worth failing for --
        # so the benefit of the doubt goes to the case that is indistinguishable.
        $d = Get-LedgerTempDir
        try {
            $r = Register-GuestAddressObservation -RuntimeDir $d -Identity 'amisad-build' -Address '192.168.7.59' -Confirm:$false
            $r.bounded       | Should -BeTrue
            $r.firstSighting | Should -BeTrue
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'calls a rebuild that came back on the same address bounded' {
        $d = Get-LedgerTempDir
        try {
            $null = Register-GuestAddressObservation -RuntimeDir $d -Identity 'amisad-build' -Address '192.168.7.59' -Confirm:$false
            $r = Register-GuestAddressObservation -RuntimeDir $d -Identity 'amisad-build' -Address '192.168.7.59' -Confirm:$false
            $r.bounded       | Should -BeTrue
            $r.firstSighting | Should -BeFalse
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'flags a rebuild of the SAME identity that was handed a different address' {
        # This is the whole signal: identity held constant, address moved. It
        # means the server is not keying on anything the guest keeps, so the
        # footprint is bounded by elapsed time instead of by guest count.
        $d = Get-LedgerTempDir
        try {
            $null = Register-GuestAddressObservation -RuntimeDir $d -Identity 'amisad-build' -Address '192.168.7.59' -Confirm:$false
            $r = Register-GuestAddressObservation -RuntimeDir $d -Identity 'amisad-build' -Address '192.168.7.204' -Confirm:$false
            $r.bounded  | Should -BeFalse
            $r.previous | Should -Be '192.168.7.59'
            $r.current  | Should -Be '192.168.7.204'
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'keeps identities apart rather than comparing a guest against its neighbor' {
        $d = Get-LedgerTempDir
        try {
            $null = Register-GuestAddressObservation -RuntimeDir $d -Identity 'amisad-build' -Address '192.168.7.59' -Confirm:$false
            $r = Register-GuestAddressObservation -RuntimeDir $d -Identity 'amisad-edge-a' -Address '192.168.7.61' -Confirm:$false
            $r.bounded       | Should -BeTrue
            $r.firstSighting | Should -BeTrue
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'treats an unreadable ledger as empty rather than failing the teardown it runs inside' {
        # Losing the history costs one cycle of detection. Throwing here would
        # cost the teardown, which is the more expensive of the two by far.
        $d = Get-LedgerTempDir
        try {
            Set-Content -Path (Join-Path $d 'guestaddress.ledger.json') -Value '{ not json'
            $r = Register-GuestAddressObservation -RuntimeDir $d -Identity 'amisad-build' -Address '192.168.7.59' -Confirm:$false
            $r.bounded       | Should -BeTrue
            $r.firstSighting | Should -BeTrue
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'counts a guest it could not resolve as unchecked, never as passing' {
        # Coverage and compliance are different facts. An unreachable guest is
        # the ordinary case on a failure path, and letting it report as bounded
        # would make a cycle where nothing could be checked read exactly like a
        # cycle where everything was.
        $d = Get-LedgerTempDir
        try {
            Reset-GuestAddressFootprintTally -Confirm:$false
            $r = Assert-GuestAddressBounded -VMName 'no-such-vm' -Identity 'no-such-vm' -RuntimeDir $d -Confirm:$false
            $r.checked | Should -BeFalse
            (Get-GuestAddressFootprintTally).checked | Should -Be 0
        } finally { Remove-Item -Recurse -Force $d }
    }
}

Describe 'the installer-driven guests' {

    It 'keeps the in-target netplan patch beside the seeded pin' {
        # Belt and braces, and they cover different moments: the seed governs
        # the INSTALLER's own lease, the late-command governs the installed
        # system if a future installer stops carrying its network config into
        # the target. Neither alone spans the guest's whole life.
        $userData = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'host/vmconfig/ubuntu.server.base.user-data')
        $userData | Should -Match 'dhcp-identifier' -Because 'the installed netplan must carry the pin too'
        $userData | Should -Match "grep -q 'dhcp-identifier'" -Because 'the patch must stay idempotent across re-runs'
    }

    # The late-command above patches /target, which does not exist while the
    # installer is running its own DHCP client. So the pin has to be in the
    # autoinstall `network:` key as well, or the INSTALL draws a lease under a
    # machine-id DUID and the installed system draws a second one under the MAC:
    # two addresses out of a shared pool for one guest, every build, with the
    # installer's copy belonging to no guest that still exists.
    #
    # The key is per-hypervisor because the interface name is: enp0s1 on UTM,
    # enp1s0 on KVM, eth0 on Hyper-V. Asserted for every overlay rather than
    # for one, because a pin present on the host someone tested and absent on
    # its siblings is the shape this whole suite exists to catch.
    It 'pins the installer''s own DHCP identity in every hypervisor overlay' {
        $overlays = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'host/vmconfig') `
                                    -Filter 'ubuntu.server.*.overlay.yml' -File)
        $overlays.Count | Should -BeGreaterThan 0 -Because 'the overlays must actually have been found'
        foreach ($o in $overlays) {
            $text = Get-Content -Raw -LiteralPath $o.FullName
            $section = [regex]::Match($text, '(?ms)^# === YURUNA_OVERLAY_NETWORK ===\s*$(.*?)^# === YURUNA_OVERLAY_')
            $section.Success | Should -BeTrue -Because "$($o.Name) must anchor a NETWORK section"
            $section.Groups[1].Value | Should -Match 'dhcp-identifier:\s*mac' `
                -Because "$($o.Name) must pin the installer's client identity, not only the installed system's"
        }
    }

    # The installed system's console-quiet grub drop-in governs the kernel booted
    # AFTER the install. The install itself is the phase a host can only read by
    # OCR, and it is the one with no cmdline seam short of remastering the ISO,
    # so its console has to be quieted from inside the installer environment.
    It 'quiets the installer console too, not only the installed system' {
        $userData = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'host/vmconfig/ubuntu.server.base.user-data')
        $userData | Should -Match 'loglevel=3' -Because 'the installed system keeps its grub drop-in'
        $overlays = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'host/vmconfig') `
                                    -Filter 'ubuntu.server.*.overlay.yml' -File)
        foreach ($o in $overlays) {
            $text = Get-Content -Raw -LiteralPath $o.FullName
            $section = [regex]::Match($text, '(?ms)^# === YURUNA_OVERLAY_EARLY_COMMANDS ===\s*$(.*?)^# === YURUNA_OVERLAY_')
            $section.Success | Should -BeTrue -Because "$($o.Name) must anchor an EARLY_COMMANDS section"
            $section.Groups[1].Value | Should -Match 'dmesg -n 1' `
                -Because "$($o.Name) must lower the installer's console log level before the OCR'd phase begins"
        }
    }
}
