<#PSScriptInfo
.VERSION 2026.09.01
.GUID 4201387d-cf87-45af-987c-08f11f4a809c
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
    Behavior of tools/Invoke-TestSuite.ps1 -- the five conditions that must fail
    a run, and the discovery contract underneath them.
.DESCRIPTION
    Every case here drives the real runner against a throwaway fixture tree via
    its -Root parameter, so nothing depends on the state of this repo's own
    suites.

    The reason the failure cases outnumber the success case: a test runner that
    reports green when it should not is worse than no runner, because it is
    trusted. Four of the five conditions are forms of SILENT test loss, none of
    which an exit code can express -- see the runner's own header for why rc is
    unusable on the standalone Pester path.
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    $script:Runner = Join-Path $repoRoot 'tools/Invoke-TestSuite.ps1'

    # A fixture tree, not this repo: the runner must be exercised against
    # suites whose pass/fail shape is chosen by the test, not inherited.
    function New-FixtureTree {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Creates a throwaway temp tree; nothing to confirm.')]
        [CmdletBinding()]
        param()
        $root = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-runner-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'test/modules')
        $root
    }

    function Set-FixtureSuite {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Writes into a throwaway temp tree; nothing to confirm.')]
        [CmdletBinding()]
        param([string]$Root, [string]$Name, [string]$Body)
        Set-Content -LiteralPath (Join-Path $Root "test/modules/$Name.Tests.ps1") -Value $Body -Encoding utf8NoBOM
    }

    # Returns the parsed suite-results.json plus the exit code, which is the
    # pair every caller of the runner actually consumes.
    function Invoke-Runner {
        param([string]$Root, [switch]$UpdateBaseline)
        $argv = @('-NoProfile', '-File', $script:Runner, '-Root', $Root, '-Quiet')
        if ($UpdateBaseline) { $argv += '-UpdateBaseline' }
        $null = & (Get-Process -Id $PID).Path @argv 2>&1
        $rc = $LASTEXITCODE
        $resultFile = Join-Path $Root '.test-results/suite-results.json'
        $json = if (Test-Path -LiteralPath $resultFile) {
            Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        } else { $null }
        [pscustomobject]@{ ExitCode = $rc; Result = $json }
    }

    $script:PassingSuite = "Describe 'ok' { It 'a' { 1 | Should -Be 1 }; It 'b' { 2 | Should -Be 2 } }"
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

Describe 'the five conditions that must fail a run' {
    It 'fails when a suite reports failing tests' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Bad' -Body "Describe 'bad' { It 'fails' { throw 'boom' } }"
            $r = Invoke-Runner -Root $root
            $r.ExitCode | Should -Not -Be 0
            ($r.Result.problems -join ' ') | Should -Match 'failed'
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

Describe 'discovery' {
    It 'honors -Filter on the suite file name' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            Set-FixtureSuite -Root $root -Name 'Beta'  -Body $script:PassingSuite
            $null = & (Get-Process -Id $PID).Path -NoProfile -File $script:Runner -Root $root -Filter 'Alpha*' -Quiet 2>&1
            $json = Get-Content -LiteralPath (Join-Path $root '.test-results/suite-results.json') -Raw | ConvertFrom-Json
            $json.totals.suites | Should -Be 1
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'finds every tracked suite in this repo' {
        # Discovery only (-ListOnly), so this neither re-runs the suite set nor
        # reads a previous run's artifact -- an artifact written before the last
        # suite was added would race against the git listing below.
        $here     = Split-Path -Parent $PSCommandPath
        $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
        Push-Location $repoRoot
        try {
            # The runner's own selector: tracked PLUS new-but-uncommitted,
            # minus anything .gitignore covers. A suite must be runnable the
            # moment it is written, not the moment it is committed, so a bare
            # `git ls-files` here would under-count by exactly the new files.
            $tracked = @(git ls-files --cached --others --exclude-standard |
                    Where-Object { $_ -match '\.Tests\.ps1$' } |
                    Where-Object { $_ -like 'test/modules/*' -or $_ -like 'host/modules/*' } |
                    Sort-Object -Unique)
            $found = @(& (Get-Process -Id $PID).Path -NoProfile -File $script:Runner -ListOnly)
            $tracked.Count | Should -BeGreaterThan 100
            $found.Count   | Should -Be $tracked.Count
            (Compare-Object $tracked $found) | Should -BeNullOrEmpty
        } finally { Pop-Location }
    }
}
