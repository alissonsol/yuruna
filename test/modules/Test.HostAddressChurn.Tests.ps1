<#PSScriptInfo
.VERSION 2026.08.14
.GUID 42e8b4c0-91d7-4a35-bf62-0c3e75a9d148
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
            # for reasons that have nothing to do with the behaviour under test.
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
            # Stop-LogFile imports the beacon module on demand; before this
            # change it merely probed for it with Get-Command and gave up.
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
