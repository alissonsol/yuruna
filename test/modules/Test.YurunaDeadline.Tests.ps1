<#PSScriptInfo
.VERSION 2026.09.18
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
    reconstruction from a plain [long], and the bounded-seconds clamp that
    keeps a computed remainder from ever reaching a native call's
    [ValidateRange(1, ...)] as 0 or a fraction.
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
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

    It 'clamps to the caller''s own ceiling, matching Invoke-UtmctlProbe''s 600s and Invoke-BoundedNativeCommand''s 3600s' {
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
}
