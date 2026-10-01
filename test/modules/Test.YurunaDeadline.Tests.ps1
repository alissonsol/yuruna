<#PSScriptInfo
.VERSION 2026.09.30
.GUID 4283b84a-0c5e-4ccf-8c92-c06369c4060f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test deadline monotonic host-refresh pester
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
    The shared boot-relative deadline helper in automation/Yuruna.Common
    .psm1: injected-clock determinism, floor-at-zero, cross-process
    reconstruction from a plain [long] (including values above the Int32
    range carried by a real child process), phases carved from one budget
    that can never outlive it, the clamp that lets a received expiry shorten
    but never enlarge a budget, deadline-bounded sleeps, and the
    bounded-seconds clamp that keeps a computed remainder from ever reaching
    a native call's [ValidateRange(1, ...)] as 0 or a fraction.
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
}

Describe 'New-YurunaDeadline / Get-YurunaDeadlineRemainingMs -- injected clock' {
    It 'reports the full budget at tick zero and counts down exactly as the injected clock advances' {
        $tick  = [ref]1000L
        $clock = { $tick.Value }.GetNewClosure()
        $d = New-YurunaDeadline -TotalMilliseconds 1000 -ClockTicks $clock
        (Get-YurunaDeadlineRemainingMs -Deadline $d) | Should -Be 1000

        $tick.Value = 1500L
        (Get-YurunaDeadlineRemainingMs -Deadline $d) | Should -Be 500

        $tick.Value = 2000L
        (Get-YurunaDeadlineRemainingMs -Deadline $d) | Should -Be 0
        (Test-YurunaDeadlineExpired -Deadline $d)    | Should -Be $true
    }

    It 'floors remaining at zero rather than going negative once past expiry' {
        $tick  = [ref]0L
        $clock = { $tick.Value }.GetNewClosure()
        $d = New-YurunaDeadline -TotalMilliseconds 1000 -ClockTicks $clock
        $tick.Value = 50000L
        (Get-YurunaDeadlineRemainingMs -Deadline $d) | Should -Be 0
    }

    It 'accepts a zero budget as already expired, not an error' {
        $d = New-YurunaDeadline -TotalMilliseconds 0
        (Test-YurunaDeadlineExpired -Deadline $d) | Should -Be $true
    }
}

Describe 'New-YurunaDeadlineFromExpiry -- cross-process reconstruction' {
    It 'reconstructs the same remaining time from the plain ExpiryTick a process boundary would carry' {
        $tick  = [ref]10000L
        $clock = { $tick.Value }.GetNewClosure()
        $original = New-YurunaDeadline -TotalMilliseconds 5000 -ClockTicks $clock

        # This is the one value allowed to cross a process boundary.
        $wireValue = $original.ExpiryTick
        $wireValue | Should -BeOfType [long]

        $tick.Value = 12000L   # 2000ms elapsed "in the child" on the same clock
        $reconstructed = New-YurunaDeadlineFromExpiry -ExpiryTick $wireValue -ClockTicks $clock
        (Get-YurunaDeadlineRemainingMs -Deadline $reconstructed) | Should -Be 3000
    }

    It 'defaults to the real boot-relative clock when no clock is injected' {
        $d = New-YurunaDeadline -TotalMilliseconds 60000
        $remaining = Get-YurunaDeadlineRemainingMs -Deadline $d
        $remaining | Should -BeGreaterThan 55000
        $remaining | Should -BeLessOrEqual 60000
    }
}

Describe 'Get-YurunaDeadlineBoundedSeconds -- never hands a native call 0 or a fraction' {
    It 'returns $null once less than one full second remains' {
        $tick  = [ref]0L
        $clock = { $tick.Value }.GetNewClosure()
        $d = New-YurunaDeadline -TotalMilliseconds 800 -ClockTicks $clock
        (Get-YurunaDeadlineBoundedSeconds -Deadline $d) | Should -BeNullOrEmpty
    }

    It 'floors a fractional remainder down rather than rounding up past the real deadline' {
        $tick  = [ref]0L
        $clock = { $tick.Value }.GetNewClosure()
        $d = New-YurunaDeadline -TotalMilliseconds 2900 -ClockTicks $clock
        (Get-YurunaDeadlineBoundedSeconds -Deadline $d) | Should -Be 2
    }

    It 'clamps to a caller ceiling of 600s or 3600s' {
        $tick  = [ref]0L
        $clock = { $tick.Value }.GetNewClosure()
        $d = New-YurunaDeadline -TotalMilliseconds 900000 -ClockTicks $clock   # 900s
        (Get-YurunaDeadlineBoundedSeconds -Deadline $d -Ceiling 600)  | Should -Be 600
        (Get-YurunaDeadlineBoundedSeconds -Deadline $d -Ceiling 3600) | Should -Be 900
    }

    It 'feeds directly into Invoke-BoundedNativeCommand without ever tripping its ValidateRange floor' {
        $tick  = [ref]0L
        $clock = { $tick.Value }.GetNewClosure()
        $d = New-YurunaDeadline -TotalMilliseconds 3000 -ClockTicks $clock
        $seconds = Get-YurunaDeadlineBoundedSeconds -Deadline $d -Ceiling 3600
        { Invoke-BoundedNativeCommand -FilePath 'bash' -ArgumentList @('-c', 'exit 0') -TimeoutSeconds $seconds } |
            Should -Not -Throw
    }

    It 'keeps a reserve back before counting whole seconds' {
        $tick  = [ref]0L
        $clock = { $tick.Value }.GetNewClosure()
        $d = New-YurunaDeadline -TotalMilliseconds 10000 -ClockTicks $clock
        (Get-YurunaDeadlineBoundedSeconds -Deadline $d -ReserveMilliseconds 2500) | Should -Be 7
        (Get-YurunaDeadlineBoundedSeconds -Deadline $d -ReserveMilliseconds 9500) | Should -BeNullOrEmpty
        (Get-YurunaDeadlineBoundedSeconds -Deadline $d -ReserveMilliseconds 60000) | Should -BeNullOrEmpty -Because 'a reserve larger than the remainder leaves no usable time, never a negative count'
    }
}

Describe 'New-YurunaDeadline -Parent -- phases carved from one budget' {
    It 'expires the reserve before its parent and inherits the parent''s clock' {
        $tick  = [ref]1000L
        $clock = { $tick.Value }.GetNewClosure()
        $parent = New-YurunaDeadline -TotalMilliseconds 100000 -ClockTicks $clock
        $child = New-YurunaDeadline -Parent $parent -ReserveMilliseconds 30000
        $child.ExpiryTick | Should -Be ($parent.ExpiryTick - 30000)
        (Get-YurunaDeadlineRemainingMs -Deadline $child) | Should -Be 70000
        $tick.Value = 61000L
        (Get-YurunaDeadlineRemainingMs -Deadline $child) | Should -Be 10000 -Because 'the child reads the injected clock it inherited'
    }

    It 'caps the child at TotalMilliseconds from now, never later than the parent' {
        $tick  = [ref]0L
        $clock = { $tick.Value }.GetNewClosure()
        $parent = New-YurunaDeadline -TotalMilliseconds 100000 -ClockTicks $clock
        $short = New-YurunaDeadline -Parent $parent -TotalMilliseconds 20000
        $short.ExpiryTick | Should -Be 20000
        $long = New-YurunaDeadline -Parent $parent -TotalMilliseconds 500000
        $long.ExpiryTick | Should -Be $parent.ExpiryTick -Because 'a child can shorten its parent, never outlive it'
        $both = New-YurunaDeadline -Parent $parent -ReserveMilliseconds 90000 -TotalMilliseconds 20000
        $both.ExpiryTick | Should -Be 10000
    }

    It 'is already expired, not an error, when the parent is inside the reserve' {
        $tick  = [ref]0L
        $clock = { $tick.Value }.GetNewClosure()
        $parent = New-YurunaDeadline -TotalMilliseconds 5000 -ClockTicks $clock
        $child = New-YurunaDeadline -Parent $parent -ReserveMilliseconds 15000
        (Get-YurunaDeadlineRemainingMs -Deadline $child) | Should -Be 0
        (Test-YurunaDeadlineExpired -Deadline $child) | Should -Be $true
    }

    It 'saturates instead of overflowing on extreme budgets' {
        $huge = New-YurunaDeadline -TotalMilliseconds ([long]::MaxValue)
        $huge.ExpiryTick | Should -Be ([long]::MaxValue)
        $child = New-YurunaDeadline -Parent $huge -ReserveMilliseconds ([long]::MaxValue)
        (Get-YurunaDeadlineRemainingMs -Deadline $child) | Should -BeGreaterOrEqual 0
    }

    It 'runs the 915-second local budget''s phases end to end on one clock' {
        $tick  = [ref]1000L
        $clock = { $tick.Value }.GetNewClosure()
        # A relaunched worker received an expiry far beyond its own allowance;
        # the reconstruction clamps it to the 915-second total.
        $total = New-YurunaDeadlineFromExpiry -ExpiryTick 99999999 -MaximumMilliseconds 915000 -ClockTicks $clock
        $total.ExpiryTick | Should -Be 916000
        $preAdmission = New-YurunaDeadline -Parent $total -TotalMilliseconds 60000
        $preAdmission.ExpiryTick | Should -Be 61000

        # Admission at the latest moment pre-admission allows.
        $tick.Value = 61000L
        (Get-YurunaDeadlineRemainingMs -Deadline $preAdmission) | Should -Be 0
        $ladder = New-YurunaDeadline -Parent $total -ReserveMilliseconds 255000 -TotalMilliseconds 600000
        $ladder.ExpiryTick | Should -Be 661000 -Because 'the ladder never eats into the convergence and reporting reserves'

        $tick.Value = $ladder.ExpiryTick
        $convergence = New-YurunaDeadline -Parent $total -ReserveMilliseconds 15000 -TotalMilliseconds 240000
        $convergence.ExpiryTick | Should -Be 901000

        $tick.Value = $convergence.ExpiryTick
        (Get-YurunaDeadlineRemainingMs -Deadline $total) | Should -Be 15000 -Because 'reporting keeps its own reserve at the end'
        ($total.ExpiryTick - 61000) | Should -Be 855000 -Because 'the admitted run is bounded at 855 seconds'

        # An early admission ends the ladder at its own 600-second cap instead.
        $tick.Value = 21000L
        $earlyLadder = New-YurunaDeadline -Parent $total -ReserveMilliseconds 255000 -TotalMilliseconds 600000
        $earlyLadder.ExpiryTick | Should -Be 621000
    }
}

Describe 'New-YurunaDeadlineFromExpiry -MaximumMilliseconds -- may shorten, never enlarge' {
    It 'shortens a supplied expiry beyond the maximum' {
        $tick  = [ref]1000L
        $clock = { $tick.Value }.GetNewClosure()
        $d = New-YurunaDeadlineFromExpiry -ExpiryTick 500000 -MaximumMilliseconds 60000 -ClockTicks $clock
        $d.ExpiryTick | Should -Be 61000
    }

    It 'keeps a supplied expiry inside the maximum' {
        $tick  = [ref]1000L
        $clock = { $tick.Value }.GetNewClosure()
        $d = New-YurunaDeadlineFromExpiry -ExpiryTick 31000 -MaximumMilliseconds 60000 -ClockTicks $clock
        $d.ExpiryTick | Should -Be 31000
    }

    It 'keeps a past expiry expired' {
        $tick  = [ref]100000L
        $clock = { $tick.Value }.GetNewClosure()
        $d = New-YurunaDeadlineFromExpiry -ExpiryTick 5000 -MaximumMilliseconds 60000 -ClockTicks $clock
        $d.ExpiryTick | Should -Be 5000
        (Test-YurunaDeadlineExpired -Deadline $d) | Should -Be $true
    }
}

Describe 'Wait-YurunaDeadlineInterval -- never sleeps past the deadline' {
    It 'sleeps the lesser of the interval and the remaining time and reports whether time is left' {
        $tick  = [ref]0L
        $clock = { $tick.Value }.GetNewClosure()
        $slept = [System.Collections.Generic.List[int]]::new()
        $sleeper = { param($ms) $slept.Add($ms); $tick.Value += $ms }.GetNewClosure()
        $d = New-YurunaDeadline -TotalMilliseconds 1200 -ClockTicks $clock

        (Wait-YurunaDeadlineInterval -Deadline $d -Milliseconds 500 -Sleep $sleeper) | Should -Be $true
        (Wait-YurunaDeadlineInterval -Deadline $d -Milliseconds 500 -Sleep $sleeper) | Should -Be $true
        (Wait-YurunaDeadlineInterval -Deadline $d -Milliseconds 500 -Sleep $sleeper) | Should -Be $false -Because 'the third wait reaches the deadline'
        @($slept) | Should -Be @(500, 500, 200)
    }

    It 'does not call the sleeper at all for a zero interval or an expired deadline' {
        $tick  = [ref]0L
        $clock = { $tick.Value }.GetNewClosure()
        $calls = [ref]0
        $sleeper = { param($ms) $null = $ms; $calls.Value++ }.GetNewClosure()
        $d = New-YurunaDeadline -TotalMilliseconds 1000 -ClockTicks $clock
        (Wait-YurunaDeadlineInterval -Deadline $d -Milliseconds 0 -Sleep $sleeper) | Should -Be $true
        $tick.Value = 5000L
        (Wait-YurunaDeadlineInterval -Deadline $d -Milliseconds 300 -Sleep $sleeper) | Should -Be $false
        $calls.Value | Should -Be 0
    }

    It 'waits for real when no sleeper is injected' {
        $d = New-YurunaDeadline -TotalMilliseconds 60000
        $sw = [Diagnostics.Stopwatch]::StartNew()
        (Wait-YurunaDeadlineInterval -Deadline $d -Milliseconds 150) | Should -Be $true
        $sw.ElapsedMilliseconds | Should -BeGreaterOrEqual 140
    }
}

Describe 'Deadline expiry across a process boundary' {
    It 'reconstructs an expiry above the Int32 range from a [long] script parameter' {
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-deadline'
        try {
            $child = Join-Path $dir 'Show-Remaining.ps1'
            $modulePath = (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -replace "'", "''"
            Set-Content -LiteralPath $child -Encoding utf8 -Value @"
[CmdletBinding()]
param([Parameter(Mandatory)][long]`$DeadlineTickMs)
Import-Module '$modulePath' -DisableNameChecking
`$d = New-YurunaDeadlineFromExpiry -ExpiryTick `$DeadlineTickMs
Write-Output ('REMAINING=' + (Get-YurunaDeadlineRemainingMs -Deadline `$d))
"@
            $budget = 3000000000L
            $expiry = [Environment]::TickCount64 + $budget
            $expiry | Should -BeGreaterThan ([long][int]::MaxValue)
            $pwsh = (Get-Process -Id $PID).Path
            $r = Invoke-BoundedNativeCommand -FilePath $pwsh -TimeoutSeconds 60 `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $child, '-DeadlineTickMs', "$expiry")
            $r.ExitCode | Should -Be 0
            $line = @(Get-BoundedNativeOutputLine -Result $r | Where-Object { $_ -like 'REMAINING=*' })
            $line.Count | Should -Be 1
            $remaining = [long]($line[0].Substring('REMAINING='.Length))
            $remaining | Should -BeLessOrEqual $budget
            $remaining | Should -BeGreaterThan ($budget - 10000)
        } finally { Remove-YurunaTestTempDir $dir }
    }
}
