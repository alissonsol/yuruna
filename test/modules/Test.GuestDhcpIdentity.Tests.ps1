<#PSScriptInfo
.VERSION 2026.10.18.1
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

    # See https://yuruna.link/42e220c4-0014
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
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
            # A per-release script that hands its work to the host's shared Ubuntu builder is judged by that builder.
            $shared = Join-Path $script:RepoRoot "host/$h/modules/New-UbuntuServerVM.ps1"
            if ((Get-Content -Raw -LiteralPath $p) -match 'New-UbuntuServerVM\.ps1' -and (Test-Path -LiteralPath $shared -PathType Leaf)) { $p = $shared }
            if ($out -notcontains $p) { $out += $p }
        }
        return $out
    }

    # The keys of one YAML mapping: the lines at the indentation of the line
    # at $Index, inside the contiguous run of lines indented at least that
    # deep. Comments and blank lines do not end the run, so a why-comment
    # between two keys of one interface entry keeps them siblings.
    function Get-YamlSiblingLine {
        param([string[]]$Lines, [int]$Index)
        $indent = [regex]::Match($Lines[$Index], '^[ \t]*').Value.Length
        $leaves = {
            param($line)
            ($line -notmatch '^\s*(#|$)') -and ([regex]::Match($line, '^[ \t]*').Value.Length -lt $indent)
        }
        $first = $Index
        while ($first -gt 0 -and -not (& $leaves $Lines[$first - 1])) { $first-- }
        $last = $Index
        while ($last -lt ($Lines.Count - 1) -and -not (& $leaves $Lines[$last + 1])) { $last++ }
        return @($Lines[$first..$last] | Where-Object {
            ($_ -notmatch '^\s*(#|$)') -and ([regex]::Match($_, '^[ \t]*').Value.Length -eq $indent)
        })
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
        # The kernel expires a DHCP address by its own clock; critical keeps
        # the lifetime open so only the lease can drop the address.
        @([regex]::Matches($text, '(?m)^\s*critical:\s*true\s*$')).Count |
            Should -Be 2 -Because 'both interface families must keep their address through a guest clock jump'
    }
}

Describe 'no seed buys a DHCP identity by taking the network down' {

    # See https://yuruna.link/42e220c4-0004
    # NetworkManager persists global disable across reboots; pin identity before boot.
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

    # See https://yuruna.link/42e220c4-0014
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
                $text | Should -Match '(?:Join-Path\s+\$\w+\s+''network-config''|[/\\]network-config["''])' -Because "$builder must land it as network-config"
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

    # See https://yuruna.link/42e220c4-0014
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

    # systemd-networkd installs the DHCPv4 address in the kernel with a valid
    # lifetime equal to the lease, and from then on two clocks run: the kernel
    # expires the address on its own jiffies-based clock, networkd renews on
    # CLOCK_BOOTTIME. A guest clock anomaly that advances jiffies deletes the
    # address and its routes while networkd still holds a valid lease and asks
    # for nothing -- a guest off the network with a healthy-looking lease.
    # `critical: true` renders as KeepConfiguration=true, under which networkd
    # installs the address with an infinite kernel lifetime, so only the lease
    # can end it. Renewal, and the release on shutdown (networkctl down), still
    # run on networkd's own timers and are unaffected.
    It 'keeps the installer''s DHCP address as critical beside every identity pin' {
        $overlays = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'host/vmconfig') `
                                    -Filter 'ubuntu.server.*.overlay.yml' -File)
        $overlays.Count | Should -BeGreaterThan 0 -Because 'the overlays must actually have been found'
        foreach ($o in $overlays) {
            $text = Get-Content -Raw -LiteralPath $o.FullName
            $section = [regex]::Match($text, '(?ms)^# === YURUNA_OVERLAY_NETWORK ===\s*$(.*?)^# === YURUNA_OVERLAY_')
            $section.Success | Should -BeTrue -Because "$($o.Name) must anchor a NETWORK section"
            $lines = @($section.Groups[1].Value -split "`r?`n")
            $pins = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match '^\s*dhcp-identifier:\s*mac\s*$' })
            $pins.Count | Should -BeGreaterThan 0 -Because "$($o.Name) must pin the identity the address pin rides beside"
            foreach ($i in $pins) {
                # A sibling of the identity key, not merely somewhere in the
                # section: the key belongs to the interface entry, and one on
                # another level is netplan's to reject at install time.
                @(Get-YamlSiblingLine -Lines $lines -Index $i | Where-Object { $_ -match '^\s*critical:\s*true\s*$' }).Count |
                    Should -Be 1 -Because "$($o.Name): the entry pinned at line $($i + 1) of its NETWORK section must keep its address as critical"
            }
            @($lines | Where-Object { $_ -match '^\s*critical:' }).Count |
                Should -Be $pins.Count -Because "$($o.Name) must carry critical: true once per dhcp-identifier: mac and nowhere else"
        }
    }

    # The counterpart for the installed system, and it has to be a pass of its
    # own: the identity guard skips a file that already carries that key, which
    # is every file the installer writes from the overlay, so a critical pin
    # folded into the same pass would never run on the common case.
    It 'keeps the in-target netplan patch pinning the address as critical, idempotently' {
        $userData = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'host/vmconfig/ubuntu.server.base.user-data')
        $userData | Should -Match "grep -q 'critical:'" -Because 'the patch must stay idempotent across re-runs'
        # Anchored on the identity line and reusing its captured indentation,
        # so the key lands inside the same interface entry whatever renderer or
        # indentation wrote the file.
        $userData | Should -Match '(?m)^\s*sed -i -E ''s/\^\(\[\[:space:\]\]\*\)dhcp-identifier:[^\r\n]*\\n\\1critical: true/'' "\$f"\s*$' `
            -Because 'the installed netplan must carry the pin on the line after dhcp-identifier: mac, at its indentation'
        $userData.IndexOf('\1critical: true') | Should -BeGreaterThan $userData.IndexOf('\1dhcp-identifier: mac') `
            -Because 'the critical pass anchors on the identity line the earlier pass guarantees'
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

    # The live system's tmpfiles-clean timer fires 15 minutes after boot and its
    # credentials mount propagates into the /run curtin bind-mounts on /target/run;
    # a chroot step open at that moment cannot unmount it and the install aborts.
    # Every hypervisor boots the same live installer, so every overlay stops it.
    It 'stops the live installer''s tmpfiles-clean timer in every hypervisor overlay' {
        $overlays = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'host/vmconfig') `
                                    -Filter 'ubuntu.server.*.overlay.yml' -File)
        $overlays.Count | Should -BeGreaterThan 0 -Because 'the overlays must actually have been found'
        foreach ($o in $overlays) {
            $text = Get-Content -Raw -LiteralPath $o.FullName
            $section = [regex]::Match($text, '(?ms)^# === YURUNA_OVERLAY_EARLY_COMMANDS ===\s*$(.*?)^# === YURUNA_OVERLAY_')
            $section.Success | Should -BeTrue -Because "$($o.Name) must anchor an EARLY_COMMANDS section"
            $section.Groups[1].Value | Should -Match '(?m)^\s+- systemctl stop systemd-tmpfiles-clean\.timer 2>/dev/null \|\| true\s*$' `
                -Because "$($o.Name) must stop the timer before curtin's chroot steps, and a missing unit must not fail early-commands"
        }
    }
}
