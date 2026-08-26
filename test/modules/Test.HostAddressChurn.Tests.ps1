<#PSScriptInfo
.VERSION 2026.08.25
.GUID 42218fa5-018e-4ea0-a6fe-a80cc7202613
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test network churn beacon pester
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
    The record of how often this host changed address, and how many of those
    changes fell inside a given cycle.
.DESCRIPTION
    WHY THIS EXISTS. A cycle that passes on a host whose address keeps moving is
    only evidence that the harness survives IP instability if instability
    actually happened while it ran. Without a count, a pass through three
    address changes and a pass on a quiet network are the same word in the same
    place -- and the second one silently weakens every claim made from the
    first. This is the measurement that keeps the claim falsifiable, so its
    windowing has to be exact at both ends and it must not be the thing that
    breaks a cycle.

    HOW IT IS DRIVEN. Rows are written and read through a temporary directory.
    No beacon, no network, no host -- the functions under test take the runtime
    directory as a parameter precisely so this is possible.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.HostAddressBeacon.psm1') -Force -DisableNameChecking

    function New-ChurnTempDir {
        [CmdletBinding()]
        [OutputType([string])]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper: creates a throwaway runtime dir the calling It block deletes.')]
        param()
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-churn-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        return $p
    }

    function Add-ChurnRow {
        param([string]$Dir, [datetime]$AtUtc, [string]$To = '192.168.7.9')
        Write-HostAddressChangeRecord -RuntimeDir $Dir -Previous '192.168.7.1' -Current $To `
            -ChangedAtUtc $AtUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
}

Describe 'Get-HostAddressChangeCount' {

    It 'reports -1, not zero, when there is no record to read' {
        # "No change happened" and "nothing was ever recorded" are different
        # facts and only one is evidence. Collapsing them is precisely how five
        # consecutive cycles were read as having met no churn when three of them
        # had -- so the unmeasured case must not be able to wear zero's costume.
        $d = New-ChurnTempDir
        try {
            Get-HostAddressChangeCount -RuntimeDir $d -StartUtc ([datetime]::UtcNow.AddHours(-1)) -EndUtc ([datetime]::UtcNow) |
                Should -Be -1
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'reports -1 when every row is unreadable, which is also not a quiet network' {
        $d = New-ChurnTempDir
        try {
            Set-Content -Path (Join-Path $d 'hostaddress.changes.ndjson') -Value 'not json at all'
            Get-HostAddressChangeCount -RuntimeDir $d -StartUtc ([datetime]::UtcNow.AddHours(-1)) -EndUtc ([datetime]::UtcNow) |
                Should -Be -1
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'reports zero when the record exists and the window really was quiet' {
        # The genuine zero, which must survive the change above: a host that
        # recorded changes, none of them inside this cycle.
        $d = New-ChurnTempDir
        try {
            Add-ChurnRow -Dir $d -AtUtc ([datetime]::UtcNow.AddMinutes(-90))
            Get-HostAddressChangeCount -RuntimeDir $d -StartUtc ([datetime]::UtcNow.AddHours(-1)) -EndUtc ([datetime]::UtcNow) |
                Should -Be 0
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'reports zero for a host that has held one address since the beacon started' {
        # The other half of the -1 rule, and the half that was inverted: the
        # record used to come into existence only once a host MOVED, so a host
        # that has never moved had no file and reported "cannot measure" --
        # meaning the most bounded hosts in the lab were indistinguishable from
        # the ones nothing was watching. The baseline row is what separates
        # them, and it must never itself count as a change.
        $d = New-ChurnTempDir
        try {
            Write-HostAddressBaselineRecord -RuntimeDir $d -Current '192.168.7.115' `
                -ObservedAtUtc ([datetime]::UtcNow.AddMinutes(-10).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")) -Confirm:$false
            Get-HostAddressChangeCount -RuntimeDir $d -StartUtc ([datetime]::UtcNow.AddHours(-1)) -EndUtc ([datetime]::UtcNow) |
                Should -Be 0
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'counts only the changes that fell inside the cycle window' {
        $d = New-ChurnTempDir
        try {
            $now = [datetime]::UtcNow
            # One before the cycle started, three inside it.
            foreach ($m in 70, 40, 25, 10) { Add-ChurnRow -Dir $d -AtUtc $now.AddMinutes(-$m) }
            Get-HostAddressChangeCount -RuntimeDir $d -StartUtc $now.AddMinutes(-50) -EndUtc $now |
                Should -Be 3 -Because 'the change 70 minutes ago predates the window'
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'includes changes exactly on the window boundaries' {
        # A cycle's first and last instants belong to that cycle. Excluding them
        # would under-report precisely the change that landed at a cycle edge,
        # which is where a lease boundary most often falls.
        $d = New-ChurnTempDir
        try {
            # Truncated to the second, which is the precision a recorded row
            # carries. Comparing a second-precision row against a boundary that
            # still has sub-second parts would drop the row at the start edge,
            # for reasons that have nothing to do with the behavior under test.
            $now   = [datetime]::UtcNow
            $end   = $now.AddTicks( - ($now.Ticks % [timespan]::TicksPerSecond))
            $start = $end.AddMinutes(-30)
            Add-ChurnRow -Dir $d -AtUtc $start
            Add-ChurnRow -Dir $d -AtUtc $end
            Get-HostAddressChangeCount -RuntimeDir $d -StartUtc $start -EndUtc $end | Should -Be 2
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'reads as zero for a window in which nothing happened' {
        $d = New-ChurnTempDir
        try {
            $now = [datetime]::UtcNow
            Add-ChurnRow -Dir $d -AtUtc $now.AddMinutes(-40)
            Get-HostAddressChangeCount -RuntimeDir $d -StartUtc $now.AddMinutes(-9) -EndUtc $now.AddMinutes(-3) |
                Should -Be 0
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'skips a malformed row rather than failing the cycle over it' {
        # This feeds a report at cycle end. A truncated final line -- the shape a
        # crash mid-append leaves -- must not become the reason a cycle cannot
        # close.
        $d = New-ChurnTempDir
        try {
            $now = [datetime]::UtcNow
            Add-ChurnRow -Dir $d -AtUtc $now.AddMinutes(-10)
            Add-Content -Path (Join-Path $d 'hostaddress.changes.ndjson') -Value '{"event":"host_address_change","cur'
            Get-HostAddressChangeCount -RuntimeDir $d -StartUtc $now.AddMinutes(-30) -EndUtc $now | Should -Be 1
        } finally { Remove-Item -Recurse -Force $d }
    }
}

Describe 'Write-HostAddressChangeRecord' {

    It 'appends one parseable row per change, keeping what it moved from and to' {
        $d = New-ChurnTempDir
        try {
            Write-HostAddressChangeRecord -RuntimeDir $d -Previous '192.168.7.133' -Current '192.168.7.53' `
                -ChangedAtUtc '2026-08-12T15:08:55Z'
            $rows = @(Get-Content (Join-Path $d 'hostaddress.changes.ndjson'))
            $rows.Count | Should -Be 1
            $row = $rows[0] | ConvertFrom-Json
            $row.event        | Should -Be 'host_address_change'
            $row.previous     | Should -Be '192.168.7.133'
            $row.current      | Should -Be '192.168.7.53'
            # ConvertFrom-Json hydrates an ISO-8601 field into a DateTime, so
            # the round-trip is asserted as an instant rather than as text.
            ([datetime]$row.changedAtUtc).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") |
                Should -Be '2026-08-12T15:08:55Z'
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'appends rather than rewrites, so the runner can read it while the beacon writes' {
        $d = New-ChurnTempDir
        try {
            foreach ($n in 1..5) {
                Write-HostAddressChangeRecord -RuntimeDir $d -Previous '' -Current "192.168.7.$n" `
                    -ChangedAtUtc ([datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
            }
            @(Get-Content (Join-Path $d 'hostaddress.changes.ndjson')).Count | Should -Be 5
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'records the first observation, where there is no previous address' {
        $d = New-ChurnTempDir
        try {
            Write-HostAddressChangeRecord -RuntimeDir $d -Previous '' -Current '192.168.7.133' `
                -ChangedAtUtc '2026-08-12T14:49:24Z'
            $row = @(Get-Content (Join-Path $d 'hostaddress.changes.ndjson'))[0] | ConvertFrom-Json
            $row.previous | Should -Be ''
            $row.current  | Should -Be '192.168.7.133'
        } finally { Remove-Item -Recurse -Force $d }
    }
}

Describe 'The counter is reachable from the session that actually records it' {

    # This suite imports the beacon module in its own BeforeAll, which
    # manufactures the exact precondition the runner does NOT have -- and that is
    # why it passed green while Stop-LogFile silently wrote 0 for five
    # consecutive cycles. A test that supplies the dependency under test cannot
    # observe the dependency being missing. So this one asks the question the
    # runner asks: starting from Test.Log alone, can the count be taken?

    It 'resolves from a session that has only imported Test.Log' {
        $probe = {
            param($RepoRoot)
            Import-Module (Join-Path $RepoRoot 'test/modules/Test.Log.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
            # Stop-LogFile imports the beacon module on demand rather than
            # merely probing for it with Get-Command and giving up; mirror
            # that on-demand import here.
            if (-not (Get-Command Get-HostAddressChangeCount -ErrorAction SilentlyContinue)) {
                Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostAddressBeacon.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
            }
            [bool](Get-Command Get-HostAddressChangeCount -ErrorAction SilentlyContinue)
        }
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $result = & $probe $repoRoot
        $result | Should -BeTrue -Because 'Stop-LogFile must be able to reach the counter from its own session state, not only from a test that pre-loaded it'
    }

    It 'still names the on-demand import in Stop-LogFile' {
        # Pins the mechanism rather than the symptom: a future edit that drops
        # the import back to a bare Get-Command probe restores the silent zero,
        # and nothing else in this suite would notice.
        $logModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules' -AdditionalChildPath 'Test.Log.psm1'
        if (-not (Test-Path -LiteralPath $logModule)) { $logModule = Join-Path $PSScriptRoot 'Test.Log.psm1' }
        $text = Get-Content -LiteralPath $logModule -Raw
        $text | Should -Match 'Test\.HostAddressBeacon\.psm1' -Because 'the counter has to be imported where it is used, not assumed present'
        $text | Should -Match '\$addressChanges = -1' -Because 'an unmeasured cycle must not be able to report a plausible zero'
    }
}

Describe 'Get-HostAddressChurnVerdict -- periodic, or merely frequent?' {

    It 'calls a quiet host stable, and an absent record unknown' {
        $d = New-ChurnTempDir
        try {
            (Get-HostAddressChurnVerdict -RuntimeDir $d).verdict | Should -Be 'unknown' `
                -Because 'no record means the question was not asked, not that the answer is good'
            Add-ChurnRow -Dir $d -AtUtc ([datetime]::UtcNow.AddDays(-30))
            (Get-HostAddressChurnVerdict -RuntimeDir $d -LookbackHours 48).verdict | Should -Be 'stable' `
                -Because 'the only change on file is far outside the window'
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'calls a beacon-started, never-moved host stable rather than unknown' {
        # A restarted beacon writes a fresh baseline. If that were counted, a
        # motionless host whose status service restarted three times would read
        # as 'moved' -- and on a long lease that is the reading that sends an
        # operator hunting for leaked addresses that were never leaked.
        $d = New-ChurnTempDir
        try {
            foreach ($ago in 300, 200, 100) {
                Write-HostAddressBaselineRecord -RuntimeDir $d -Current '192.168.7.115' `
                    -ObservedAtUtc ([datetime]::UtcNow.AddMinutes(-$ago).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")) -Confirm:$false
            }
            $v = Get-HostAddressChurnVerdict -RuntimeDir $d
            $v.verdict | Should -Be 'stable'
            $v.changes | Should -Be 0
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'reads one address per renewal as renewal-churn, at ANY lease length' {
        # The property that has to hold for a lab on a 20-minute lease and a
        # customer on a week-long one: the verdict is the same, because the
        # signal is the repetition and not the rate. A rate threshold would call
        # the first a fault and the second healthy -- while the second is worse,
        # each abandoned address being parked for a week instead of 20 minutes.
        foreach ($periodMin in 10, 600, 5040) {
            $d = New-ChurnTempDir
            try {
                $now = [datetime]::UtcNow
                foreach ($i in 1..8) {
                    Add-ChurnRow -Dir $d -AtUtc $now.AddMinutes(-1 * $periodMin * $i) -To "192.168.7.$(10 + $i)"
                }
                $v = Get-HostAddressChurnVerdict -RuntimeDir $d -LookbackHours (($periodMin * 10) / 60 + 1) -NowUtc $now
                $v.verdict | Should -Be 'renewal-churn' -Because "a $periodMin-minute period repeats just as plainly as any other"
                $v.medianIntervalMinutes | Should -Be $periodMin
                $v.distinctAddresses | Should -Be 8 -Because 'every renewal took a fresh address'
            } finally { Remove-Item -Recurse -Force $d }
        }
    }

    It 'does not mistake reboots and link events for a renewal timer' {
        # Same number of changes as the case above, spread at no fixed interval.
        # This is what the discovery path exists to absorb, and telling an
        # operator to re-pin their DHCP identity over it is wrong advice.
        $d = New-ChurnTempDir
        try {
            $now = [datetime]::UtcNow
            foreach ($m in 5, 47, 63, 400, 415, 1200) { Add-ChurnRow -Dir $d -AtUtc $now.AddMinutes(-$m) }
            (Get-HostAddressChurnVerdict -RuntimeDir $d -NowUtc $now).verdict | Should -Be 'moved'
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'still sees the period when a reboot lands in the middle of it' {
        # The reason regularity is measured against the median and not the mean:
        # one outlying gap must not be able to hide a timer that is otherwise
        # ticking on every renewal.
        $d = New-ChurnTempDir
        try {
            $now = [datetime]::UtcNow
            # Eight 30-minute steps with one 9-hour gap wedged in.
            $offsets = @(30, 60, 90, 120, 660, 690, 720, 750)
            foreach ($m in $offsets) { Add-ChurnRow -Dir $d -AtUtc $now.AddMinutes(-$m) -To "192.168.7.$m" }
            $v = Get-HostAddressChurnVerdict -RuntimeDir $d -NowUtc $now
            $v.verdict | Should -Be 'renewal-churn'
            $v.medianIntervalMinutes | Should -Be 30
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'will not call two changes a period' {
        # Two points make one interval, which is a duration; a period needs a
        # repetition to be one. Guessing from a single gap is how a host that
        # rebooted twice gets told its DHCP identity is broken.
        $d = New-ChurnTempDir
        try {
            $now = [datetime]::UtcNow
            foreach ($m in 30, 60) { Add-ChurnRow -Dir $d -AtUtc $now.AddMinutes(-$m) }
            (Get-HostAddressChurnVerdict -RuntimeDir $d -NowUtc $now).verdict | Should -Be 'moved'
        } finally { Remove-Item -Recurse -Force $d }
    }
}

Describe 'Get-HostAddressStabilityReport -- pairing what was asked for with what happened' {

    It 'tells "nobody pinned it" apart from "the server ignores the pin"' {
        # The two faults are indistinguishable from either signal alone and have
        # different remedies: one is a setting on this host, the other cannot be
        # fixed on this host at all. Reporting either one for both is how an
        # operator applies a pin, sees no change, and stops trusting the check.
        $d = New-ChurnTempDir
        try {
            $now = [datetime]::UtcNow
            foreach ($i in 1..8) { Add-ChurnRow -Dir $d -AtUtc $now.AddMinutes(-30 * $i) -To "192.168.7.$(10 + $i)" }
            InModuleScope -ModuleName Test.HostAddressBeacon -Parameters @{ Dir = $d; Now = $now } {
                param($Dir, $Now)
                Mock Get-HostBridgeDhcpIdentity { @{ backend = 'networkmanager'; pinned = $false; detail = 'x'; remedy = 'PIN-IT' } }
                $unpinned = Get-HostAddressStabilityReport -RuntimeDir $Dir -NowUtc $Now
                $unpinned.severity | Should -Be 'warning'
                $unpinned.remedy   | Should -Be 'PIN-IT'

                Mock Get-HostBridgeDhcpIdentity { @{ backend = 'networkmanager'; pinned = $true; detail = 'x'; remedy = 'PIN-IT' } }
                $pinned = Get-HostAddressStabilityReport -RuntimeDir $Dir -NowUtc $Now
                $pinned.severity | Should -Be 'warning'
                $pinned.remedy   | Should -Not -Be 'PIN-IT' -Because 'a pin that is already set cannot be the remedy for its own failure'
                $pinned.remedy   | Should -Match 'reserv|static'
            }
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'flags a host that is stable only by the server''s goodwill' {
        # No churn to see, no pin to hold it. Nothing is wrong yet, which is
        # exactly when saying so is cheap -- the alternative is finding out at
        # the next lease-table eviction.
        $d = New-ChurnTempDir
        try {
            InModuleScope -ModuleName Test.HostAddressBeacon -Parameters @{ Dir = $d } {
                param($Dir)
                Set-Content -Path (Join-Path $Dir 'hostaddress.changes.ndjson') -Value ''
                Mock Get-HostBridgeDhcpIdentity { @{ backend = 'networkmanager'; pinned = $false; detail = 'x'; remedy = 'PIN-IT' } }
                $r = Get-HostAddressStabilityReport -RuntimeDir $Dir
                $r.verdict  | Should -Be 'stable'
                $r.severity | Should -Be 'advisory'
                $r.remedy   | Should -Be 'PIN-IT'

                Mock Get-HostBridgeDhcpIdentity { @{ backend = 'networkd'; pinned = $true; detail = 'pinned'; remedy = '' } }
                (Get-HostAddressStabilityReport -RuntimeDir $Dir).severity | Should -Be 'ok'
            }
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'never reports a severity a cycle could fail on' {
        $d = New-ChurnTempDir
        try {
            (Get-HostAddressStabilityReport -RuntimeDir $d).severity |
                Should -BeIn @('ok', 'advisory', 'warning')
        } finally { Remove-Item -Recurse -Force $d }
    }

    # A window whose every change reports the same current address describes a
    # host that lost and reacquired ONE address. No second address was ever
    # observed, so "changed address N times" asserts a renumbering that left no
    # trace anywhere else -- and it buries the signal that is actually present.
    # An operator reading it goes looking for address mobility, finds a host
    # sitting on one address, and concludes the check is noise.
    It 'does not report a renumbering when only one address was ever seen' {
        $d = New-ChurnTempDir
        try {
            $now = [datetime]::UtcNow
            # Irregular gaps so the verdict is 'moved' rather than periodic, and
            # a single current address throughout.
            foreach ($m in 5, 47, 63, 400, 415, 1200) { Add-ChurnRow -Dir $d -AtUtc $now.AddMinutes(-$m) -To '192.168.7.9' }
            InModuleScope -ModuleName Test.HostAddressBeacon -Parameters @{ Dir = $d; Now = $now } {
                param($Dir, $Now)
                Mock Get-HostBridgeDhcpIdentity { @{ backend = 'networkd'; pinned = $true; detail = 'pinned'; remedy = '' } }
                $r = Get-HostAddressStabilityReport -RuntimeDir $Dir -NowUtc $Now
                $r.churn.distinctAddresses | Should -Be 1
                $r.message | Should -Not -Match 'changed address \d+ time'
                $r.message | Should -Match 'only ever observed on ONE address'
                $r.message | Should -Match 'took no extra lease'
                $r.severity | Should -BeIn @('ok', 'advisory', 'warning')
            }
        } finally { Remove-Item -Recurse -Force $d }
    }

    It 'still reports a real renumbering when more than one address was seen' {
        $d = New-ChurnTempDir
        try {
            $now = [datetime]::UtcNow
            $i = 0
            foreach ($m in 5, 47, 63, 400, 415, 1200) {
                $i++; Add-ChurnRow -Dir $d -AtUtc $now.AddMinutes(-$m) -To "192.168.7.$(20 + $i)"
            }
            InModuleScope -ModuleName Test.HostAddressBeacon -Parameters @{ Dir = $d; Now = $now } {
                param($Dir, $Now)
                Mock Get-HostBridgeDhcpIdentity { @{ backend = 'networkd'; pinned = $true; detail = 'pinned'; remedy = '' } }
                $r = Get-HostAddressStabilityReport -RuntimeDir $Dir -NowUtc $Now
                $r.churn.distinctAddresses | Should -BeGreaterThan 1
                $r.message | Should -Match 'changed address \d+ time'
                $r.message | Should -Match 'distinct addresses'
            }
        } finally { Remove-Item -Recurse -Force $d }
    }

    # The pool-drain arithmetic in the periodic branch is a quantitative claim
    # ("about N addresses a day out of the LAN pool"). On one address it is
    # false, and a false leak sends an operator to the DHCP server for a fault
    # that is on the wire.
    It 'withdraws the pool-drain claim when the periodic changes are all one address' {
        $d = New-ChurnTempDir
        try {
            $now = [datetime]::UtcNow
            foreach ($i in 1..8) { Add-ChurnRow -Dir $d -AtUtc $now.AddMinutes(-30 * $i) -To '192.168.7.9' }
            InModuleScope -ModuleName Test.HostAddressBeacon -Parameters @{ Dir = $d; Now = $now } {
                param($Dir, $Now)
                Mock Get-HostBridgeDhcpIdentity { @{ backend = 'networkd'; pinned = $true; detail = 'pinned'; remedy = '' } }
                $r = Get-HostAddressStabilityReport -RuntimeDir $Dir -NowUtc $Now
                $r.verdict  | Should -Be 'renewal-churn' -Because 'the periodicity is real and still worth a warning'
                $r.severity | Should -Be 'warning'
                $r.message  | Should -Not -Match 'takes a NEW address'
                $r.message  | Should -Not -Match 'a day'
                $r.message  | Should -Match 'LOSES AND REACQUIRES'
            }
        } finally { Remove-Item -Recurse -Force $d }
    }

    # The periodic multi-address branch reports a RATE, and a rate is not a
    # drain. Converting one into the other needs the lease period and the scope
    # size, and this beacon is handed neither -- it reads one host's address log
    # and nothing else. The same rate is unremarkable on a short lease and fatal
    # on a long one, so asserting the fatal reading is a guess presented as a
    # measurement, and it sends whoever reads it to a DHCP server that may have
    # most of its pool free.
    It 'reports the churn rate without asserting renewal or exhaustion' {
        $d = New-ChurnTempDir
        try {
            $now = [datetime]::UtcNow
            $i = 0
            foreach ($k in 1..8) {
                $i++; Add-ChurnRow -Dir $d -AtUtc $now.AddMinutes(-20 * $k) -To "192.168.7.$(20 + $i)"
            }
            InModuleScope -ModuleName Test.HostAddressBeacon -Parameters @{ Dir = $d; Now = $now } {
                param($Dir, $Now)
                Mock Get-HostBridgeDhcpIdentity { @{ backend = 'networkd'; pinned = $true; detail = 'pinned'; remedy = '' } }
                $r = Get-HostAddressStabilityReport -RuntimeDir $Dir -NowUtc $Now
                $r.verdict | Should -Be 'renewal-churn'
                $r.churn.distinctAddresses | Should -BeGreaterThan 1
                # A renewal fires at half the lease. The beacon does not know the
                # lease, so it cannot call an interval a renewal -- on a 12h lease
                # a 20-minute period is emphatically not one.
                $r.message | Should -Not -Match 'on every lease renewal'
                $r.message | Should -Not -Match 'exhaustion within days'
                # What it must do instead: name the two numbers that would settle
                # it, and point at the only place they can be read.
                $r.message | Should -Match 'lease period and the scope size'
                $r.message | Should -Match 'free-lease count'
                # The one claim the address log DOES support stays.
                $r.message | Should -Match 'breaks every guest behind it'
            }
        } finally { Remove-Item -Recurse -Force $d }
    }
}

Describe 'Set-HostBridgeDhcpIdentity -- applying the remedy instead of printing it' {

    # The stubs take the parameters the real callees take and USE them, so the
    # assertions below read the arguments the function actually passed rather
    # than trusting that it passed the right ones.

    It 'writes the stored profile and never reactivates it' {
        # The whole basis for doing this unattended. `nmcli connection modify`
        # leaves the live connection alone; an `up` here would re-DHCP the host
        # mid-cycle and could drop the operator's session on a remote machine.
        InModuleScope -ModuleName Test.HostAddressBeacon {
            $script:calls = [System.Collections.Generic.List[string]]::new()
            function Get-HostBridgeDhcpIdentity { param($BridgeName)
                @{ backend = 'networkmanager'; pinned = $false; detail = "unpinned:$BridgeName"; remedy = 'r' } }
            function Invoke-YurunaSudo { param($Argument, [switch]$TolerateBlocked)
                $script:calls.Add(($Argument -join ' ') + " tolerate=$TolerateBlocked")
                @{ ExitCode = 0; Output = @(); Blocked = $false } }
            $null = Set-HostBridgeDhcpIdentity -Confirm:$false
            $script:calls.Count | Should -Be 1
            $script:calls[0] | Should -Match 'nmcli connection modify'
            $script:calls[0] | Should -Match 'ipv4\.dhcp-client-id mac'
            $script:calls[0] | Should -Not -Match 'connection up' -Because 'reactivating is what would make this unsafe to run unattended'
            $script:calls[0] | Should -Match 'tolerate=True' -Because 'a host that cannot elevate must be reported, not throw into the cycle'
        }
    }

    It 'leaves a netplan bridge alone' {
        # Fixing that one means rewriting /etc/netplan and re-plumbing the host's
        # IP stack. A health check must not do that on its way past.
        InModuleScope -ModuleName Test.HostAddressBeacon {
            $script:calls = [System.Collections.Generic.List[string]]::new()
            function Get-HostBridgeDhcpIdentity { param($BridgeName)
                @{ backend = 'networkd'; pinned = $false; detail = "netplan:$BridgeName"; remedy = 'r' } }
            function Invoke-YurunaSudo { param($Argument, [switch]$TolerateBlocked)
                $script:calls.Add(($Argument -join ' ') + " tolerate=$TolerateBlocked")
                @{ ExitCode = 0; Output = @(); Blocked = $false } }
            $r = Set-HostBridgeDhcpIdentity -Confirm:$false
            $r.applied | Should -BeFalse
            $script:calls.Count | Should -Be 0 -Because 'nothing may be run against a backend this does not own'
            $r.reason | Should -Match 'not NetworkManager-managed'
        }
    }

    It 'does nothing to a bridge that is already pinned' {
        InModuleScope -ModuleName Test.HostAddressBeacon {
            $script:calls = [System.Collections.Generic.List[string]]::new()
            function Get-HostBridgeDhcpIdentity { param($BridgeName)
                @{ backend = 'networkmanager'; pinned = $true; detail = "pinned:$BridgeName"; remedy = '' } }
            function Invoke-YurunaSudo { param($Argument, [switch]$TolerateBlocked)
                $script:calls.Add(($Argument -join ' ') + " tolerate=$TolerateBlocked")
                @{ ExitCode = 0; Output = @(); Blocked = $false } }
            $r = Set-HostBridgeDhcpIdentity -Confirm:$false
            $r.applied  | Should -BeFalse
            $r.verified | Should -BeTrue -Because 'already pinned is the desired end state, not a failure'
            $script:calls.Count | Should -Be 0
        }
    }

    It 'believes the profile, not the exit code' {
        # nmcli accepts a property it then stores differently often enough that
        # "returned 0" and "the profile now says mac" are separate claims. Only
        # the second one stops the host renumbering.
        InModuleScope -ModuleName Test.HostAddressBeacon {
            function Get-HostBridgeDhcpIdentity { param($BridgeName)
                @{ backend = 'networkmanager'; pinned = $false; detail = "still unpinned:$BridgeName"; remedy = 'r' } }
            function Invoke-YurunaSudo { param($Argument, [switch]$TolerateBlocked)
                @{ ExitCode = 0; Output = @($Argument.Count, $TolerateBlocked); Blocked = $false } }
            $r = Set-HostBridgeDhcpIdentity -Confirm:$false
            $r.applied  | Should -BeTrue
            $r.verified | Should -BeFalse -Because 'the read-back still says unpinned, so the claim is not earned'
        }
    }

    It 'reports a refused sudo instead of throwing into the cycle' {
        # A sudo refused once is refused all cycle. This is a health check, and
        # a health check that can abort a run is one operators stop running.
        InModuleScope -ModuleName Test.HostAddressBeacon {
            function Get-HostBridgeDhcpIdentity { param($BridgeName)
                @{ backend = 'networkmanager'; pinned = $false; detail = "unpinned:$BridgeName"; remedy = 'r' } }
            function Invoke-YurunaSudo { param($Argument, [switch]$TolerateBlocked)
                @{ ExitCode = 1; Output = @("blocked $($Argument[0]) tolerate=$TolerateBlocked"); Blocked = $true } }
            { Set-HostBridgeDhcpIdentity -Confirm:$false } | Should -Not -Throw
            $r = Set-HostBridgeDhcpIdentity -Confirm:$false
            $r.applied | Should -BeFalse
            $r.reason  | Should -Match 'sudo refused'
        }
    }

    It 'runs nothing under -WhatIf' {
        InModuleScope -ModuleName Test.HostAddressBeacon {
            $script:calls = [System.Collections.Generic.List[string]]::new()
            function Get-HostBridgeDhcpIdentity { param($BridgeName)
                @{ backend = 'networkmanager'; pinned = $false; detail = "unpinned:$BridgeName"; remedy = 'r' } }
            function Invoke-YurunaSudo { param($Argument, [switch]$TolerateBlocked)
                $script:calls.Add(($Argument -join ' ') + " tolerate=$TolerateBlocked")
                @{ ExitCode = 0; Output = @(); Blocked = $false } }
            $null = Set-HostBridgeDhcpIdentity -WhatIf
            $script:calls.Count | Should -Be 0
        }
    }
}

Describe 'the grant that lets the remedy run unattended' {

    BeforeAll {
        # test/modules/<this file> -> test/modules -> test -> repo root.
        $script:Root       = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
        $script:SudoersRaw = Get-Content -Raw -LiteralPath (Join-Path $script:Root 'host/ubuntu.kvm/yuruna-bridge-pin.sudoers')
        $script:InstallSh  = Get-Content -Raw -LiteralPath (Join-Path $script:Root 'install/ubuntu.kvm.sh')
        $script:BeaconSrc  = Get-Content -Raw -LiteralPath (Join-Path $script:Root 'test/modules/Test.HostAddressBeacon.psm1')
    }

    It 'grants exactly the command the code runs, argument for argument' {
        # sudo matches the full argument vector. Reorder the properties in the
        # code, or add one, and the rule stops matching -- so the remedy silently
        # goes back to "sudo refused" on every host that had it working. Nothing
        # else in the system would notice; the check would keep reporting the
        # fault it can no longer fix.
        $call = [regex]::Match($script:BeaconSrc,
            "(?s)Invoke-YurunaSudo -Argument @\((.*?)\) -TolerateBlocked").Groups[1].Value
        $call | Should -Not -BeNullOrEmpty -Because 'the elevated call must be findable'
        $fromCode = (@([regex]::Matches($call, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) +
                     @('yuruna-br0')) -join ' '
        # $BridgeName is a variable in the source; splice the default in at the
        # position the sudoers rule spells out.
        $fromCode = ((@([regex]::Matches($call, "'([^']+)'|\`$BridgeName") |
            ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { 'yuruna-br0' } })) -join ' ')

        $ruleLine = @($script:SudoersRaw -split "`n" | Where-Object { $_ -match 'NOPASSWD:' })[0]
        $fromRule = ($ruleLine -replace '^.*NOPASSWD:\s*', '' -replace '^/usr/bin/', '').Trim()

        $fromRule | Should -Be $fromCode -Because 'the granted command line and the executed one are one contract'
    }

    It 'grants no wildcard' {
        # A trailing * on `connection modify yuruna-br0` would permit ipv4.method,
        # ipv4.addresses and connection.autoconnect -- enough to take the host off
        # the network permanently, from a rule installed to keep it on.
        $script:SudoersRaw -split "`n" |
            Where-Object { $_ -match 'NOPASSWD:' } |
            ForEach-Object { $_ | Should -Not -Match '\*' }
    }

    It 'is installed by the host install script, for hosts that do not exist yet' {
        # The grant cannot bootstrap itself: installing it needs the sudo it
        # provides. The elevated install is the one place it can happen without
        # asking the operator for a second privileged act, so a future host that
        # skipped this line would arrive with the same unfixable fault.
        $script:InstallSh | Should -Match 'yuruna-bridge-pin\.sudoers' -Because 'the installer must ship the grant'
        $script:InstallSh | Should -Match '/etc/sudoers\.d/yuruna-bridge-pin'
    }

    It 'validates the rule before installing it' {
        # A malformed drop-in breaks sudo for every command on the host,
        # including the ones needed to remove it. Order is the whole assertion.
        $fn = [regex]::Match($script:InstallSh, '(?s)install_bridge_pin_sudoers\(\) \{.*?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty
        $checkAt   = $fn.IndexOf('visudo -cf')
        $installAt = $fn.IndexOf('install -m 0440')
        $checkAt   | Should -BeGreaterThan -1 -Because 'the generated file must be validated'
        $installAt | Should -BeGreaterThan $checkAt -Because 'validated BEFORE it is put in place, not after'
    }

    It 'substitutes the runner account rather than shipping one' {
        # The file names a reference account. A host whose runner is not that
        # account would install a rule that grants nothing and reads as if it
        # granted everything.
        $fn = [regex]::Match($script:InstallSh, '(?s)install_bridge_pin_sudoers\(\) \{.*?\n\}').Value
        $fn | Should -Match '\$USER' -Because 'the installed rule must name this host''s runner account'
    }
}
