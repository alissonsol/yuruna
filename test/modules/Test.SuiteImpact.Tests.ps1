<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42f9ba9c-c42d-40ac-831a-41f654880e31
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester runner recorded-pass
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
    Recorded suite passes: tools/suite_impact.py and the way tools/Invoke-TestSuite.ps1
    records, reuses and refuses them.
.DESCRIPTION
    The runner cases drive a copy of the runner against a throwaway Git fixture.
    A stand-in strace runs each suite with YURUNA_FAKE_TRACED set and reports,
    as reads, the suite file and the paths named in a `<suite>.reads` file
    beside it, so a case chooses what a suite depends on and whether it fails
    only when traced. The real strace is exercised by the recorder's own Python
    regressions where it is available. Where recording cannot run (outside Linux,
    or without python3) every case checks the fallback instead: every suite runs
    and the note says why nothing was reused.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $script:Pwsh = (Get-Process -Id $PID).Path
    # A candidate must answer --version: the Windows Store alias for python3
    # resolves as an application yet exits 9009 without running anything. The
    # runner itself records only with python3, on Linux.
    $script:Python = @('python3', 'python') | ForEach-Object {
            Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue
        } | Where-Object {
            $version = & $_.Source --version 2>&1
            $LASTEXITCODE -eq 0 -and "$version" -match '^Python 3'
        } | Select-Object -First 1
    $script:CanRecord = [bool]($IsLinux -and (Get-Command python3 -CommandType Application -ErrorAction SilentlyContinue))

    $script:FakeTracer = Join-Path $TestDrive 'fake-strace'
    if ($script:Python) {
        $fake = @'
import os, subprocess, sys
args = sys.argv[1:]
out = args[args.index("-o") + 1]
command = args[args.index("--") + 1:]
lines = ['100 execve("%s", ["x"], 0x1 /* 1 vars */) = 0' % command[0]]
if "-Suite" in command:
    suite = command[command.index("-Suite") + 1]
    reads = [suite]
    if os.path.exists(suite + ".reads"):
        with open(suite + ".reads", encoding="utf-8") as stream:
            reads += [line.strip() for line in stream if line.strip()]
    lines += ['100 openat(AT_FDCWD</>, "%s", O_RDONLY) = 3</x>' % path for path in reads]
code = subprocess.call(command, env=dict(os.environ, YURUNA_FAKE_TRACED="1"))
with open(out, "w", encoding="utf-8") as stream:
    stream.write("\n".join(lines + ["100 +++ exited with %d +++" % code]) + "\n")
sys.exit(code)
'@
        [IO.File]::WriteAllText($script:FakeTracer, "#!$($script:Python.Source)`n$fake", [Text.UTF8Encoding]::new($false))
        if (-not $IsWindows) { & chmod 755 $script:FakeTracer }
    }

    function New-ImpactFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates a throwaway fixture below Pester TestDrive.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([hashtable]$Suite)
        $root = Join-Path $TestDrive ('impact-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'tools'), (Join-Path $root 'test/modules'), (Join-Path $root 'inputs')
        foreach ($name in 'Invoke-TestSuite.ps1', '_InvokeOneSuite.ps1', 'suite_impact.py') {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot "tools/$name") -Destination (Join-Path $root "tools/$name")
        }
        foreach ($name in $Suite.Keys) {
            $inputFile = Join-Path $root "inputs/$name.txt"
            [IO.File]::WriteAllText($inputFile, "$name input", [Text.UTF8Encoding]::new($false))
            $file = Join-Path $root "test/modules/$name.Tests.ps1"
            [IO.File]::WriteAllText($file, $Suite[$name], [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText("$file.reads", $inputFile, [Text.UTF8Encoding]::new($false))
        }
        $null = git -C $root init -q 2>&1
        return $root
    }

    function Invoke-ImpactRunner {
        param([Parameter(Mandatory)][string]$Root, [string[]]$Argument = @(), [hashtable]$Environment = @{})
        $values = @{ YURUNA_STRACE = $script:FakeTracer }
        foreach ($name in $Environment.Keys) { $values[$name] = $Environment[$name] }
        $saved = @{}
        foreach ($name in $values.Keys) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $values[$name])
        }
        try {
            $output = & $script:Pwsh -NoProfile -File (Join-Path $Root 'tools/Invoke-TestSuite.ps1') -Root $Root -ThrottleLimit 2 @Argument 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally {
            foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        }
        $report = Join-Path $Root '.test-results/suite-results.json'
        $result = if (Test-Path -LiteralPath $report) { Get-Content -LiteralPath $report -Raw | ConvertFrom-Json } else { $null }
        [pscustomobject]@{ ExitCode = $code; Result = $result; Output = ($output -replace "`e\[[0-9;]*m", '') }
    }

    function Get-Row {
        param($Run, [string]$Name)
        @($Run.Result.suites | Where-Object { $_.path -ceq "test/modules/$Name.Tests.ps1" })[0]
    }

    # Every case's fallback where recording cannot run: nothing reused or
    # recorded, every suite run, and a note that names the missing piece.
    function Confirm-NothingReused {
        param($Run)
        $Run.Result.impact.reused | Should -Be 0
        $Run.Result.impact.recorded | Should -Be 0
        $Run.Result.impact.note | Should -Match 'Linux|python3'
        @($Run.Result.suites | Where-Object { [string]$_.impact -like 'reused*' }) | Should -HaveCount 0
    }

    $script:Passing = "Describe 'ok' { It 'a' { 1 | Should -Be 1 }; It 'b' { 2 | Should -Be 2 } }"
}

Describe 'the recorder' {
    It 'passes its Python regressions' {
        if (-not $script:Python) { throw 'Python 3 is required: the pre-commit hook and the SBOM tools already need it' }
        $output = & $script:Python.Source -B (Join-Path $script:RepoRoot 'tools/tests/test_suite_impact.py') 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) { Write-Information ($output -join "`n") -InformationAction Continue }
        $text = $output -join "`n"
        $code | Should -Be 0
        $text | Should -Match 'Ran [1-9][0-9]* tests?'
        # Outside Linux every case skips, as the recorder runs only there. On
        # Linux only the real strace case may skip: where strace is missing, or
        # where this suite is itself traced, since one process tree cannot be
        # traced twice.
        $tracer = if ($env:YURUNA_STRACE) { $env:YURUNA_STRACE } else { (Get-Command strace -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
        $traced = $IsLinux -and [bool]((Get-Content -LiteralPath /proc/self/status) -match '^TracerPid:\s*[1-9]')
        $skips = if (-not $IsLinux) { [int]([regex]::Match($text, 'Ran (\d+) tests?').Groups[1].Value) } elseif (-not $tracer -or $traced) { 1 } else { 0 }
        $expected = if ($skips) { "(?m)^OK \(skipped=$skips\)\s*$" } else { '(?m)^OK\s*$' }
        $text | Should -Match $expected
    }
}

Describe 'recorded passes in the suite runner' {
    It 'reuses a recorded pass while its inputs are unchanged' {
        $root = New-ImpactFixture -Suite @{ Alpha = $script:Passing; Beta = $script:Passing }
        $recorded = Invoke-ImpactRunner -Root $root -Argument '-Record'
        $recorded.ExitCode | Should -Be 0 -Because $recorded.Output
        $again = Invoke-ImpactRunner -Root $root
        $again.ExitCode | Should -Be 0 -Because $again.Output
        $again.Result.totals.tests | Should -Be 4
        if (-not $script:CanRecord) { Confirm-NothingReused $again; return }
        $recorded.Result.impact.recorded | Should -Be 2
        (Get-Row $recorded Alpha).impact | Should -BeExactly 'no recorded pass; recorded'
        $again.Result.impact.reused | Should -Be 2
        $again.Result.totals.reused | Should -Be 2
        (Get-Row $again Alpha).impact | Should -Match '^reused the pass recorded at \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
        # The recorded NUnit file stands where a run would have written one.
        $xml = [xml](Get-Content -LiteralPath (Join-Path $root '.test-results/nunit-test_modules_Alpha.Tests.ps1.xml') -Raw)
        $xml.'test-results'.total | Should -Be 2
        $again.Output | Should -Match '2 reused from recorded passes'
    }

    It 'runs again only the suite whose input changed' {
        $root = New-ImpactFixture -Suite @{ Alpha = $script:Passing; Beta = $script:Passing }
        $null = Invoke-ImpactRunner -Root $root -Argument '-Record'
        [IO.File]::WriteAllText((Join-Path $root 'inputs/Alpha.txt'), 'edited', [Text.UTF8Encoding]::new($false))
        $run = Invoke-ImpactRunner -Root $root
        $run.ExitCode | Should -Be 0 -Because $run.Output
        if (-not $script:CanRecord) { Confirm-NothingReused $run; return }
        (Get-Row $run Alpha).impact | Should -BeExactly ('input changed: ' + (Join-Path $root 'inputs/Alpha.txt'))
        (Get-Row $run Beta).impact | Should -Match '^reused'
        $run.Result.impact.reused | Should -Be 1
    }

    It 'runs every suite with -All' {
        $root = New-ImpactFixture -Suite @{ Alpha = $script:Passing }
        $null = Invoke-ImpactRunner -Root $root -Argument '-Record'
        $run = Invoke-ImpactRunner -Root $root -Argument '-All'
        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Result.impact.reused | Should -Be 0
        (Get-Row $run Alpha).seconds | Should -BeGreaterThan 0
    }

    It 'never records a suite that fails' {
        $root = New-ImpactFixture -Suite @{ Alpha = "Describe 'bad' { It 'fails' { 1 | Should -Be 2 } }" }
        $first = Invoke-ImpactRunner -Root $root -Argument '-Record'
        $second = Invoke-ImpactRunner -Root $root
        $first.ExitCode | Should -Be 1
        $second.ExitCode | Should -Be 1
        $second.Result.totals.failed | Should -Be 1
        if (-not $script:CanRecord) { Confirm-NothingReused $second; return }
        (Get-Row $first Alpha).impact | Should -BeExactly 'no recorded pass; not recorded: the suite did not pass'
        (Get-Row $second Alpha).impact | Should -BeExactly 'no recorded pass'
    }

    It 'repeats untraced a suite that fails only under strace, and lets that run decide' {
        $root = New-ImpactFixture -Suite @{ Alpha = "Describe 'traced' { It 'is not traced' { `$env:YURUNA_FAKE_TRACED | Should -BeNullOrEmpty } }" }
        $first = Invoke-ImpactRunner -Root $root -Argument '-Record'
        $first.ExitCode | Should -Be 0 -Because $first.Output
        $first.Result.totals.failed | Should -Be 0
        if (-not $script:CanRecord) { Confirm-NothingReused $first; return }
        (Get-Row $first Alpha).impact | Should -Match '^no recorded pass; not recorded: it failed only under strace \(FAIL  traced\.is not traced\)$'
        $first.Result.impact.recorded | Should -Be 0
        # One traced failure can be a load flake, so the next run traces again;
        # after a second one it runs untraced at once for the rest of the day.
        $second = Invoke-ImpactRunner -Root $root -Argument '-Record'
        $second.ExitCode | Should -Be 0 -Because $second.Output
        (Get-Row $second Alpha).impact | Should -Match '^no recorded pass; not recorded: it failed only under strace '
        $third = Invoke-ImpactRunner -Root $root -Argument '-Record'
        $third.ExitCode | Should -Be 0 -Because $third.Output
        (Get-Row $third Alpha).impact | Should -BeExactly 'no recorded pass; not recorded: it failed under strace twice today, so it ran untraced'
    }

    It 'does not reuse a pass recorded under another environment' {
        $root = New-ImpactFixture -Suite @{ Alpha = $script:Passing }
        $null = Invoke-ImpactRunner -Root $root -Argument '-Record'
        $run = Invoke-ImpactRunner -Root $root -Environment @{ YURUNA_IMPACT_CONTEXT_PROBE = 'changed' }
        $run.ExitCode | Should -Be 0 -Because $run.Output
        if (-not $script:CanRecord) { Confirm-NothingReused $run; return }
        $run.Result.impact.reused | Should -Be 0
        (Get-Row $run Alpha).impact | Should -Match '^recorded under another context'
    }

    It 'records nothing, and says why, when strace cannot trace' {
        $root = New-ImpactFixture -Suite @{ Alpha = $script:Passing }
        $refusing = Join-Path $TestDrive 'refusing-strace'
        [IO.File]::WriteAllText($refusing, "#!/bin/sh`nexit 1`n", [Text.UTF8Encoding]::new($false))
        if (-not $IsWindows) { & chmod 755 $refusing }
        $run = Invoke-ImpactRunner -Root $root -Argument '-Record' -Environment @{ YURUNA_STRACE = $refusing }
        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Result.impact.recorded | Should -Be 0
        $run.Result.impact.traced | Should -BeFalse
        if (-not $script:CanRecord) { Confirm-NothingReused $run; return }
        $run.Result.impact.note | Should -Match 'cannot trace here'
        $run.Output | Should -Match 'WARNING: Invoke-TestSuite: nothing is recorded'
    }

    It 'launches nothing in the background while a foreground run is active' {
        $root = New-ImpactFixture -Suite @{ Alpha = $script:Passing }
        $directory = Join-Path $root '.git/yuruna/test-impact/foreground'
        $null = New-Item -ItemType Directory -Force -Path $directory
        $lock = [IO.File]::Open((Join-Path $directory 'held.lock'), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $run = Invoke-ImpactRunner -Root $root -Argument '-Background'
        } finally { $lock.Dispose() }
        if (-not $script:CanRecord) { $run.ExitCode | Should -Be 0 -Because $run.Output; Confirm-NothingReused $run; return }
        $run.ExitCode | Should -Be 1
        (Get-Row $run Alpha).rc | Should -Be 125
        (Get-Row $run Alpha).impact | Should -BeExactly 'not launched: a foreground run is active on this clone'
        $run.Result.impact.recorded | Should -Be 0
    }

    It 'removes a foreground lock left by a run that ended without releasing it' {
        $root = New-ImpactFixture -Suite @{ Alpha = $script:Passing }
        $directory = Join-Path $root '.git/yuruna/test-impact/foreground'
        $null = New-Item -ItemType Directory -Force -Path $directory
        $stale = Join-Path $directory 'stale.lock'
        [IO.File]::WriteAllText($stale, '')
        [IO.File]::SetLastWriteTimeUtc($stale, [DateTime]::UtcNow.AddMinutes(-5))
        $run = Invoke-ImpactRunner -Root $root -Argument '-Background'
        $run.ExitCode | Should -Be 0 -Because $run.Output
        if (-not $script:CanRecord) { Confirm-NothingReused $run; return }
        $run.Result.impact.recorded | Should -Be 1
        Test-Path -LiteralPath $stale | Should -BeFalse
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
