<#PSScriptInfo
.VERSION 2026.10.31
.GUID 421f3ace-6c8e-4e8e-890e-a8aa1819d8b6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester runner
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES Pester
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Behavior of tools/Invoke-TestSuite.ps1: baseline rows: per-platform floors and skip allowances, per-suite timeouts, slowdown reporting and the refresh's refusals.
.DESCRIPTION
    Every case drives the real runner against a throwaway fixture tree through
    its -Root parameter (Test.SuiteRunnerFixture.psm1), so nothing depends on
    the state of this repository's own suites. A test runner that reports green
    when it should not is worse than none, because it is trusted, which is why
    failure cases outnumber success cases across the Test.SuiteRunner* suites.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.SuiteRunnerFixture.psm1') -Force -DisableNameChecking
    $script:Runner = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../tools/Invoke-TestSuite.ps1'))
    $script:PassingSuite = "Describe 'ok' { It 'a' { 1 | Should -Be 1 }; It 'b' { 2 | Should -Be 2 } }"
    $script:ThisPlatform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    $script:OtherPlatform = if ($script:ThisPlatform -eq 'windows') { 'linux' } else { 'windows' }
}

Describe 'a baseline row can carry a platform floor and a timeout of its own' {
    It 'holds a platform to its own floor, and only that platform' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Be 0

            # The reference host had three tests here; this platform legitimately defines two.
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ total = 3; platformTotal = [pscustomobject]@{ $script:ThisPlatform = 2 } }
            $met = Invoke-Runner -Root $root
            ($met.Result.problems -join ' ') | Should -Not -Match 'tests disappeared'
            $met.ExitCode | Should -Be 0

            # The same floor is still a floor: a suite under it has lost tests.
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ platformTotal = [pscustomobject]@{ $script:ThisPlatform = 3 } }
            $below = Invoke-Runner -Root $root
            $below.ExitCode | Should -Not -Be 0
            ($below.Result.problems -join ' ') | Should -Match 'tests disappeared'

            # A floor for another platform does not excuse this one: it is held to `total`.
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ platformTotal = [pscustomobject]@{ $script:OtherPlatform = 1 } }
            $other = Invoke-Runner -Root $root
            $other.ExitCode | Should -Not -Be 0
            ($other.Result.problems -join ' ') | Should -Match 'tests disappeared'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps both fields and the reference count when the baseline is refreshed' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Be 0
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ total = 3; platformTotal = [pscustomobject]@{ $script:ThisPlatform = 2 }; timeoutSeconds = 77 }

            $refresh = Invoke-Runner -Root $root -UpdateBaseline
            $refresh.ExitCode | Should -Be 0 -Because $refresh.Output
            $kept = Get-BaselineRow -Root $root -Suite 'Alpha'
            $kept.Row.total | Should -Be 3 -Because 'a run on a platform with a lower floor must not lower the reference count'
            $kept.Row.platformTotal.$($script:ThisPlatform) | Should -Be 2
            $kept.Row.timeoutSeconds | Should -Be 77
            $kept.Totals.tests | Should -Be 3 -Because 'the totals are the sum of the rows written'

            # And a row with no floor of its own is still refused when it loses tests.
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ platformTotal = $null }
            $document = Get-Content -LiteralPath (Join-Path $root 'test/modules/suite-baseline.json') -Raw | ConvertFrom-Json
            $document.suites.PSObject.Properties['test/modules/Alpha.Tests.ps1'].Value.PSObject.Properties.Remove('platformTotal')
            $document | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'test/modules/suite-baseline.json') -Encoding utf8NoBOM
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Not -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'gives one suite a longer cap than its recorded cost earns, and never a shorter one' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Be 0
            # A recorded cost of zero makes the cap exactly -TimeoutSeconds.
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ seconds = 0 }
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body "Describe 'slow' { It 'a' { Start-Sleep -Seconds 6; 1 | Should -Be 1 }; It 'b' { 2 | Should -Be 2 } }"

            $capped = Invoke-Runner -Root $root -TimeoutSeconds 2
            $capped.ExitCode | Should -Not -Be 0
            ($capped.Result.problems -join ' ') | Should -Match 'rc=124'

            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ timeoutSeconds = 120 }
            $raised = Invoke-Runner -Root $root -TimeoutSeconds 2
            $raised.ExitCode | Should -Be 0 -Because "the row names 120 s; output: $($raised.Output)"

            # A row cannot shorten the cap the flat allowance gives: a normal start takes over a second.
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ timeoutSeconds = 1 }
            (Invoke-Runner -Root $root -TimeoutSeconds 120).ExitCode | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports a suite that ran far longer than its recorded cost, without failing the run' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Be 0
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ seconds = 0.1 }
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body "Describe 'slow' { It 'a' { Start-Sleep -Seconds 2; 1 | Should -Be 1 }; It 'b' { 2 | Should -Be 2 } }"

            $slow = Invoke-Runner -Root $root -SlowdownAllowanceSeconds 1
            $slow.ExitCode | Should -Be 0 -Because "time is reported, never adjudicated; output: $($slow.Output)"
            @($slow.Result.slowdowns).path | Should -Be 'test/modules/Alpha.Tests.ps1'
            @($slow.Result.slowdowns)[0].recordedSeconds | Should -Be 0.1
            $slow.Output | Should -Match 'Alpha\.Tests\.ps1 ran [0-9.]+s against 0\.1s recorded'

            # The default allowance keeps a short suite's ordinary variation quiet.
            @((Invoke-Runner -Root $root).Result.slowdowns).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses to refresh a baseline whose row carries a malformed <Kind>' -TestCases @(
        @{ Kind = 'platform name'; Field = @{ platformTotal = [pscustomobject]@{ solaris = 1 } } }
        @{ Kind = 'platform floor'; Field = @{ platformTotal = [pscustomobject]@{ macos = 0 } } }
        @{ Kind = 'timeout'; Field = @{ timeoutSeconds = 'soon' } }
    ) {
        param($Kind, $Field)
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Be 0
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field $Field
            $before = (Get-FileHash -LiteralPath (Join-Path $root 'test/modules/suite-baseline.json')).Hash
            $refused = Invoke-Runner -Root $root -UpdateBaseline
            $refused.ExitCode | Should -Not -Be 0 -Because "a malformed $Kind must not be refreshed over"
            $refused.Output | Should -Match 'baseline is unreadable'
            (Get-FileHash -LiteralPath (Join-Path $root 'test/modules/suite-baseline.json')).Hash | Should -Be $before
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
