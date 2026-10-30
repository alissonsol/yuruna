<#PSScriptInfo
.VERSION 2026.10.30
.GUID 428d1a31-188c-4b3f-8536-74c55e9f6bcb
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
    Behavior of tools/Invoke-TestSuite.ps1: the verdict: fail-fast, a clean run, the six conditions that must fail a run, and the call-operator invocation contract.
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

Describe 'fail-fast never turns cancelled work into passing evidence' {
    BeforeEach { $script:FailFastRoot = New-FixtureTree }
    AfterEach {
        $absolute = [IO.Path]::GetFullPath($script:FailFastRoot)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $absolute.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($absolute) -notlike 'yuruna-runner-*') { throw 'invalid fail-fast fixture cleanup path' }
        Remove-Item -LiteralPath $absolute -Recurse -Force
    }

    It 'retains the full suite census while refusing to launch work after a serial failure' {
        Set-FixtureSuite -Root $script:FailFastRoot -Name Alpha -Body "Describe 'fail' { It 'fails' { 1 | Should -Be 2 } }"
        Set-FixtureSuite -Root $script:FailFastRoot -Name Beta -Body @'
BeforeAll { [IO.File]::WriteAllText((Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'unexpected-launch'), 'launched') }
Describe 'slow' { It 'waits' { Start-Sleep -Seconds 30 } }
'@
        $run = Invoke-Runner -Root $script:FailFastRoot -FailFast -UpdateBaseline
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Result.suites | Should -HaveCount 2
        $run.Result.totals.failed | Should -Be 1
        $run.Result.totals.incomplete | Should -Be 1
        $cancelled = $run.Result.suites | Where-Object path -LIKE '*Beta*'
        $cancelled.rc | Should -Be 125
        $cancelled.haveXml | Should -BeFalse
        $cancelled.message | Should -Match 'not launched'
        $run.Result.problems[0] | Should -Match 'Alpha.Tests.ps1.*1 failed'
        $run.Result.problems[0] | Should -Match 'FAIL  fail.fails'
        Test-Path -LiteralPath (Join-Path $script:FailFastRoot 'test/unexpected-launch') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:FailFastRoot 'test/modules/suite-baseline.json') | Should -BeFalse
    }

    It 'stops only its running owned sibling and preserves the original failure' {
        Set-FixtureSuite -Root $script:FailFastRoot -Name Alpha -Body @'
BeforeAll {
    $ready = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'beta-owner.json'
    $limit = [DateTime]::UtcNow.AddSeconds(10)
    while (-not [IO.File]::Exists($ready)) {
        if ([DateTime]::UtcNow -gt $limit) { throw 'the sibling did not start' }
        Start-Sleep -Milliseconds 20
    }
}
Describe 'fail' { It 'fails' { 1 | Should -Be 2 } }
'@
        Set-FixtureSuite -Root $script:FailFastRoot -Name Beta -Body @'
BeforeAll {
    $owned = [Diagnostics.Process]::GetCurrentProcess()
    try {
        [IO.File]::WriteAllText((Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'beta-owner.json'),
            (@{ pid = $PID; started = $owned.StartTime.ToUniversalTime().Ticks } | ConvertTo-Json))
    } finally { $owned.Dispose() }
    Start-Sleep -Seconds 30
}
Describe 'slow' { It 'passes' { 1 | Should -Be 1 } }
'@
        $run = Invoke-Runner -Root $script:FailFastRoot -FailFast -ThrottleLimit 2
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Result.suites | Should -HaveCount 2
        $run.Result.totals.failed | Should -Be 1
        $row = $run.Result.suites | Where-Object path -LIKE '*Beta*'
        $row.rc | Should -Be 125
        $row.haveXml | Should -BeFalse
        $row.message | Should -Match 'cancelled after another suite failed'
        $identity = Get-Content -LiteralPath (Join-Path $script:FailFastRoot 'test/beta-owner.json') -Raw | ConvertFrom-Json
        $probe = $null
        try { $probe = [Diagnostics.Process]::GetProcessById($identity.pid) }
        catch [ArgumentException] { Write-Debug 'the cancelled owned sibling is absent' }
        if ($probe) {
            try { $probe.StartTime.ToUniversalTime().Ticks | Should -Not -Be $identity.started }
            finally { $probe.Dispose() }
        }
    }

    It 'executes every suite and permits a baseline refresh when all suites pass' {
        foreach ($name in @('Alpha', 'Beta')) { Set-FixtureSuite -Root $script:FailFastRoot -Name $name -Body $script:PassingSuite }
        $run = Invoke-Runner -Root $script:FailFastRoot -FailFast -ThrottleLimit 2 -UpdateBaseline
        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Result.suites | Should -HaveCount 2
        $run.Result.totals.tests | Should -Be 4
        $run.Result.totals.incomplete | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:FailFastRoot 'test/modules/suite-baseline.json') | Should -BeTrue
    }
}

Describe 'a clean tree passes and reports what ran' {
    It 'exits 0 and counts every test' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            Set-FixtureSuite -Root $root -Name 'Beta'  -Body 'Describe ''b'' { It ''c'' { 1 | Should -Be 1 } }'
            $r = Invoke-Runner -Root $root
            $r.ExitCode | Should -Be 0
            $r.Result.totals.suites | Should -Be 2
            $r.Result.totals.tests  | Should -Be 3
            $r.Result.totals.failed | Should -Be 0
            $r.Result.problems      | Should -BeNullOrEmpty
            if ($IsWindows) {
                [xml]$xml = Get-Content -LiteralPath (Join-Path $root '.test-results/nunit-test_modules_Alpha.Tests.ps1.xml') -Raw
                $xml.'test-results'.environment.platform | Should -BeExactly 'SuiteRunner fixture OS'
                $xml.'test-results'.environment.'os-version' | Should -BeExactly '0.0.0.0'
            }
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'writes one result row per discovered suite' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            $r = Invoke-Runner -Root $root
            @($r.Result.suites).Count | Should -Be 1
            @($r.Result.suites)[0].path | Should -Match 'Alpha\.Tests\.ps1$'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'the six conditions that must fail a run' {
    It 'fails when a suite reports failing tests' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Bad' -Body "Describe 'bad' { It 'fails' { throw 'boom' } }"
            $r = Invoke-Runner -Root $root
            $r.ExitCode | Should -Not -Be 0
            ($r.Result.problems -join ' ') | Should -Match 'failed'

            Set-FixtureSuite -Root $root -Name 'Bad' -Body "Describe 'background input' { It 'requests operator input' { Read-Host 'No operator can answer this' } }"
            # The timeout includes pwsh and Pester startup. Keep five seconds
            # beyond the worker cost just measured under the same machine load.
            $promptAllowance = 5 + [int][Math]::Ceiling($r.Result.suites[0].seconds)
            $prompt = Invoke-Runner -Root $root -TimeoutSeconds $promptAllowance
            $prompt.ExitCode | Should -Be 1
            $prompt.Result.totals.incomplete | Should -Be 0 -Because 'an input request must fail before the suite timeout'
            $prompt.Result.totals.failed | Should -Be 1
            [xml]$evidence = Get-Content -LiteralPath (Join-Path $root '.test-results/nunit-test_modules_Bad.Tests.ps1.xml') -Raw
            $evidence.SelectSingleNode('//test-case/failure/message').InnerText | Should -Match 'NonInteractive'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'fails when a suite discovers zero tests, which otherwise reads as green' {
        $root = New-FixtureTree
        try {
            # The shape a BeforeAll that quietly empties a fixture set produces:
            # the file parses, Pester runs, and nothing is collected.
            Set-FixtureSuite -Root $root -Name 'Empty' -Body "Describe 'nothing' { if (`$false) { It 'never' { } } }"
            $r = Invoke-Runner -Root $root
            $r.ExitCode | Should -Not -Be 0
            ($r.Result.problems -join ' ') | Should -Match 'discovered 0 tests'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'fails when a suite process dies before writing a result file' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Crash' -Body "throw 'exploded before any Describe'"
            $r = Invoke-Runner -Root $root
            $r.ExitCode | Should -Not -Be 0
            ($r.Result.problems -join ' ') | Should -Match 'no result file'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'fails when a suite in the baseline has vanished' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            Set-FixtureSuite -Root $root -Name 'Beta'  -Body 'Describe ''b'' { It ''c'' { 1 | Should -Be 1 } }'
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Be 0

            Remove-Item -LiteralPath (Join-Path $root 'test/modules/Beta.Tests.ps1') -Force
            $r = Invoke-Runner -Root $root
            $r.ExitCode | Should -Not -Be 0
            ($r.Result.problems -join ' ') | Should -Match 'not in this run'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'fails when a suite skips more tests than its budget, naming what stopped running' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Be 0
            # A host without the tool a case needs: the case still counts toward
            # the total, so only the skip count tells it stopped running.
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body "Describe 'ok' { It 'a' { 1 | Should -Be 1 }; It 'b' { Set-ItResult -Skipped -Because 'the tool is not installed' } }"
            $over = Invoke-Runner -Root $root
            $over.ExitCode | Should -Not -Be 0
            ($over.Result.problems -join ' ') | Should -Match 'Alpha\.Tests\.ps1: 1 skipped, budget 0 -- tests stopped running; first: ok\.b'

            $allowed = Invoke-Runner -Root $root -AllowSkipGrowth
            $allowed.ExitCode | Should -Be 0 -Because "the override reports instead of failing; output: $($allowed.Output)"
            $allowed.Result.skipGrowthAllowed | Should -BeTrue
            @($allowed.Result.skipGrowth).Count | Should -Be 1
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'fails when a surviving suite quietly lost tests' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Be 0

            Set-FixtureSuite -Root $root -Name 'Alpha' -Body "Describe 'ok' { It 'a' { 1 | Should -Be 1 } }"
            $r = Invoke-Runner -Root $root
            $r.ExitCode | Should -Not -Be 0
            ($r.Result.problems -join ' ') | Should -Match 'tests disappeared'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'the invocation contract the three file-scope-fixture suites depend on' {
    It 'runs a suite whose fixtures are assigned at file scope' {
        # This is the shape that fails under Invoke-Pester -Path: the fixture is
        # bound during discovery and is gone by the time the It body runs. The
        # runner must keep such a suite working, because the repo has three.
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'FileScope' -Body @'
$fixture = 'bound-at-file-scope'
Describe 'file-scope fixture' {
    It 'sees the fixture' { $fixture | Should -Be 'bound-at-file-scope' }
}
'@
            $r = Invoke-Runner -Root $root
            $r.ExitCode | Should -Be 0
            $r.Result.totals.tests  | Should -Be 1
            $r.Result.totals.failed | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
