<#PSScriptInfo
.VERSION 2026.09.01
.GUID 421af4b2-1e1d-4a6c-80fe-e53a2fb240b8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test dhcp lease release shutdown systemd pester
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
    The guest hands its DHCP lease back on its own way down.
.DESCRIPTION
    WHY THIS EXISTS. Asking a guest for its lease from the host needs three
    things at once: a login user, an address that still resolves, and a guest
    that is still running. The guests that hold leases longest have none of
    them at the only moment it could be asked -- they are stopped while running
    and deleted while off, so a host-side release has no point in their
    lifecycle to happen at. An address abandoned that way stays allocated until
    its lease expires, which on a lab lease is minutes and on a customer's is
    days.

    A shutdown unit inside the guest removes all three requirements. What it
    replaces them with is a systemd contract with four load-bearing lines, each
    of which fails silently if it is wrong -- the unit stays enabled, the
    shutdown stays clean, and the address simply never comes back. That is what
    is pinned here.

    Static assertions over the seeds, because the thing under test is what the
    guest is BUILT with; there is no guest to run.
    Run: Invoke-Pester -Path test/modules/Test.GuestLeaseRelease.Tests.ps1
#>

BeforeAll {
    # test/modules/<this file> -> test/modules -> test -> repo root.
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:NetLib   = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'automation/yuruna-network.sh')
    # The two guest families the release payload ships to. The service VMs are
    # deliberately absent: they do not carry yuruna-network.sh, and the unit is
    # asserted below to exist only where its payload does.
    $script:ReleaseSeeds = @('ubuntu.server', 'amazon.linux.2023')
    $script:AllSeeds = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'host/vmconfig') -Filter '*.base.user-data')

    function Get-SeedText {
        param([string]$Seed)
        Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot "host/vmconfig/$Seed.base.user-data")
    }
}

Describe 'the release unit is installed on every guest that can run it' {

    It 'defines and enables yuruna-dhcp-release.service on both guest families' {
        foreach ($seed in $script:ReleaseSeeds) {
            $text = Get-SeedText -Seed $seed
            $text | Should -Match 'yuruna-dhcp-release\.service' -Because "seed '$seed' must define the unit"
            $text | Should -Match 'systemctl enable[^\r\n]*yuruna-dhcp-release\.service' `
                -Because "seed '$seed' must enable it -- a unit written but not enabled never stops, so it never releases"
        }
    }

    It 'installs the unit only where its payload is' {
        # ExecStop points at /usr/local/lib/yuruna/yuruna-network.sh. A seed that
        # ships the unit without the library gets a unit that fails on every
        # shutdown -- noisily, forever, and releasing nothing.
        #
        # The sweep is over a directory listing, so an empty list would satisfy
        # every assertion below without reading a byte. Fail on that first.
        $script:AllSeeds.Count | Should -BeGreaterThan 1 -Because 'the seed sweep must actually find seeds'
        foreach ($f in $script:AllSeeds) {
            $text = Get-Content -Raw -LiteralPath $f.FullName
            if ($text -match 'yuruna-dhcp-release\.service') {
                $text | Should -Match 'yuruna-network\.sh' `
                    -Because "$($f.Name) installs the release unit, so it must also deploy the library the unit calls"
            }
        }
    }

    It 'activates it in the same boot on the live-system seed' {
        # A oneshot's ExecStop only runs for a unit that is RUNNING. Enabling
        # without starting leaves it inert until the next boot, so the guest's
        # first shutdown -- often its only one -- releases nothing. The subiquity
        # seed enables into a target chroot where nothing is running yet and
        # picks the unit up on first boot; the cloud-init seed is editing a live
        # system and has to say --now.
        (Get-SeedText -Seed 'amazon.linux.2023') |
            Should -Match 'systemctl enable --now[^\r\n]*yuruna-dhcp-release\.service'
    }
}

Describe 'the four lines that decide whether it ever runs' {

    It 'puts the release on ExecStop, never on ExecStart' {
        # The inversion that would be worst: releasing on ExecStart drops the
        # guest's lease moments after it boots, at the exact point the harness
        # is about to SSH to it.
        foreach ($seed in $script:ReleaseSeeds) {
            $text = Get-SeedText -Seed $seed
            $unit = [regex]::Match($text, '(?s)Description=Return this guest.{0,4000}?WantedBy=multi-user\.target').Value
            $unit | Should -Not -BeNullOrEmpty -Because "seed '$seed' must contain the unit body"
            $unit | Should -Match 'ExecStop=[^\r\n]*yuruna-network\.sh release' `
                -Because "seed '$seed' must release at STOP"
            ([regex]::Match($unit, 'ExecStart=[^\r\n]*')).Value | Should -Not -Match 'yuruna-network\.sh' `
                -Because "seed '$seed' must not release at start -- that drops the lease the harness is about to use"
        }
    }

    It 'stays active after ExecStart so there is a stop to run' {
        # Without RemainAfterExit a Type=oneshot goes inactive the moment
        # ExecStart returns, and systemd runs ExecStop for nothing at shutdown.
        foreach ($seed in $script:ReleaseSeeds) {
            $unit = [regex]::Match((Get-SeedText -Seed $seed), '(?s)Description=Return this guest.{0,4000}?WantedBy=multi-user\.target').Value
            $unit | Should -Match 'RemainAfterExit=yes' -Because "seed '$seed' needs the unit to still be active at shutdown"
        }
    }

    It 'is ordered after the network, which is what puts its stop before the teardown' {
        # Shutdown reverses start order. After=network.target is therefore the
        # only reason the release runs while there is still a network to release
        # onto; without it systemd is free to stop this unit after the interface
        # is already down, and the DHCPRELEASE never reaches the server.
        foreach ($seed in $script:ReleaseSeeds) {
            $unit = [regex]::Match((Get-SeedText -Seed $seed), '(?s)Description=Return this guest.{0,4000}?WantedBy=multi-user\.target').Value
            $unit | Should -Match '(?m)^\s*After=[^\r\n]*network\.target' -Because "seed '$seed' must order the unit after the network"
        }
    }

    It 'is bounded, so a wedged release cannot hold the shutdown open' {
        # Teardown's standing rule is that a wedged guest must never stall the
        # sweep. A guest wedged INSIDE this unit is still a wedged guest, and an
        # unbounded ExecStop would hand it the stall the rule exists to prevent.
        foreach ($seed in $script:ReleaseSeeds) {
            $unit = [regex]::Match((Get-SeedText -Seed $seed), '(?s)Description=Return this guest.{0,4000}?WantedBy=multi-user\.target').Value
            $m = [regex]::Match($unit, '(?m)^\s*TimeoutStopSec=(\d+)\s*$')
            $m.Success | Should -BeTrue -Because "seed '$seed' must bound the stop"
            [int]$m.Groups[1].Value | Should -BeLessOrEqual 60 -Because 'a minute of teardown per guest is already generous'
        }
    }
}

Describe 'the release itself survives running as root at shutdown' {

    It 'elevates only when it is not already root' {
        # The unit runs as root while the authentication stack sudo would
        # consult is being torn down. A hard `sudo` there can fail on a machine
        # where it works perfectly from a login shell -- and this is the last
        # chance the address has to go back.
        $script:NetLib | Should -Match '_yuruna_net_sudo\(\)' -Because 'the helper must exist'
        $body = [regex]::Match($script:NetLib, '(?s)network_release\(\) \{.*?\n\}').Value
        $body | Should -Not -BeNullOrEmpty
        ([regex]::Matches($body, '(?<![\w_])sudo\s')).Count | Should -Be 0 `
            -Because 'every elevated call in the release must go through the helper, not bare sudo'
        ([regex]::Matches($body, '_yuruna_net_sudo\s')).Count | Should -BeGreaterThan 0
    }

    It 'is still callable the two ways it already had callers' {
        # The sequence action invokes it by path with a verb; fetch-and-execute
        # sources the file for network_diag. Neither may regress.
        $script:NetLib | Should -Match '(?m)^\s*release\)\s*network_release' -Because 'the CLI verb is how the sequence action calls it'
        $script:NetLib | Should -Match '(?m)^\s*diag\)\s*network_diag'
    }
}

Describe 'the host-side release, for the kills no shutdown unit sees' {

    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.VMUtility.psm1') -Force -DisableNameChecking
        $script:InnerLoop = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'test/modules/Test.RunnerInnerLoop.psm1')
    }

    It 'counts an attempt that could not even start' {
        # The tally exists to make a release that never happened visible, so the
        # case where the release is impossible -- no SSH surface at all -- is the
        # one it must not quietly drop. Counting only what got as far as running
        # would report "0 of 0 asked" for a cycle that asked and could not.
        Reset-GuestDhcpReleaseTally -Confirm:$false
        $null = Invoke-GuestDhcpRelease -VMName 'v1' -GuestKey 'guest.x'
        $t = Get-GuestDhcpReleaseTally
        $t.attempted | Should -Be 1 -Because 'the ask counts even when there is nothing to ask over'
        $t.succeeded | Should -Be 0
    }

    It 'zeroes at a cycle boundary so a cycle reports its own number' {
        # The runner process outlives the cycle. Without a reset the count is
        # cumulative and every cycle after the first reports work it did not do.
        Reset-GuestDhcpReleaseTally -Confirm:$false
        $null = Invoke-GuestDhcpRelease -VMName 'v1' -GuestKey 'guest.x'
        Reset-GuestDhcpReleaseTally -Confirm:$false
        (Get-GuestDhcpReleaseTally).attempted | Should -Be 0
    }

    It 'asks on the path a guest that PASSED takes' {
        # The teardown that was missing entirely, and the one that matters most:
        # a clean cycle recycles the most addresses. It force-stops, so the
        # guest's own shutdown unit never runs and cannot stand in for this.
        $body = [regex]::Match($script:InnerLoop,
            '(?s)# --- REGION: Stop and remove this guest VM before starting the next.*?Cleanup complete for').Value
        $body | Should -Not -BeNullOrEmpty -Because 'the passing-guest teardown region must be findable'
        $releaseAt = $body.IndexOf('Invoke-GuestDhcpRelease')
        $stopAt    = $body.IndexOf('Stop-VM -VMName $VMName -Force')
        $releaseAt | Should -BeGreaterThan -1 -Because 'a passing guest must be asked for its lease'
        $stopAt    | Should -BeGreaterThan $releaseAt -Because 'asked while it is still running, not after the power is cut'
    }

    It 'passes a guest key from every teardown that has one' {
        # The release picks its SSH login from the guest key, so a teardown that
        # omits it is a teardown that silently never releases -- indistinguishable
        # in the log from one that did. Only three sites may omit it, and each
        # for a reason that is visible on the call itself.
        $calls = @([regex]::Matches($script:InnerLoop, '(?m)^\s*Remove-GuestVMQuietly[^\r\n]*$') |
                   ForEach-Object { $_.Value.Trim() })
        $calls.Count | Should -BeGreaterThan 4 -Because 'the sweep must find the teardown sites'
        foreach ($c in $calls) {
            if ($c -match '-GuestKey') { continue }
            # -SkipStop: the VM is not running, so there is nobody to ask.
            # -BestEffort without a key: the emergency and cycle-restart paths
            # tear down $script:ActiveVMName, where no guest key is in scope.
            $c | Should -Match '-SkipStop|-BestEffort' `
                -Because "'$c' omits -GuestKey without being one of the paths that cannot supply one"
        }
    }

    It 'states the tally every cycle, including when it is perfect' {
        # A line that only appears when something is wrong teaches nothing by its
        # absence -- which is how a teardown path missing its guest key ran as
        # long as it did.
        $script:InnerLoop | Should -Match 'Get-GuestDhcpReleaseTally' -Because 'the teardown must report the count'
        $teardown = [regex]::Match($script:InnerLoop,
            '(?s)function Remove-CycleTeardownOrphanVM.*?\n\}').Value
        $teardown | Should -Match 'DHCP leases released before teardown' -Because 'reported at the teardown banner'
        $teardown | Should -Match 'no guest was asked this cycle' -Because 'the zero case is stated, not skipped'
    }
}
