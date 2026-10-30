<#PSScriptInfo
.VERSION 2026.10.30
.GUID 420cb71b-a0c8-4471-9a53-9f8a03416299
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester python node contracts
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
    Run the Python, PowerShell and Node test programs that live beside the
    tools they test, and hold every test program in the tree to a runner.
.DESCRIPTION
    The suite runner discovers only *.Tests.ps1 files, so a test program written
    in another language runs only when something names it. Several had been
    named by nothing: they were not run, and they had stopped passing without
    anyone seeing it. Each program here is one case with the number of tests it
    must still report, so one that fails, or quietly loses tests, fails a
    suite the baseline protects.

    The guard at the end lists every test program the tree tracks and fails on
    one that no suite runs, so the next one cannot drift the same way.
#>

BeforeDiscovery {
    $script:UnitTestPrograms = @(
        @{ Program = 'tools/tests/test_aks_context.py'; Tests = 1 }
        @{ Program = 'tools/tests/test_installer_failure_logging.py'; Tests = 7 }
        @{ Program = 'tools/tests/test_low_workflows.py'; Tests = 12 }
        @{ Program = 'tools/tests/test_pester_selection.py'; Tests = 1 }
        @{ Program = 'tools/tests/test_sbom_dependencies.py'; Tests = 27 }
        @{ Program = 'tools/tests/test_sbom_provisioning.py'; Tests = 40 }
        @{ Program = 'tools/tests/test_sbom_sync.py'; Tests = 21 }
        @{ Program = 'tools/tests/test_utf8_catalog.py'; Tests = 3 }
        @{ Program = 'host/vmconfig/tests/test_collector_seed.py'; Tests = 9 }
        @{ Program = 'host/vmconfig/tests/test_pool_configuration.py'; Tests = 17 }
    )
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    # A candidate must answer --version: the Windows Store alias for python3
    # exists on PATH and opens the Store instead of running anything.
    $script:Python = @('python3', 'python') | ForEach-Object {
        Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    } | Where-Object {
        $version = & $_.Source --version 2>&1
        $LASTEXITCODE -eq 0 -and "$version" -match '^Python 3\.(1[1-9]|[2-9]\d)'
    } | Select-Object -First 1
    $script:Node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    # A failing program's output becomes the failure message, and a console
    # color sequence there stops Pester writing the result file, so the run reads
    # as an incomplete suite instead of as the failure it is.
    function ConvertTo-PlainProgramOutput {
        param([AllowNull()][object[]]$Line)
        $text = (@($Line) | ForEach-Object { [string]$_ }) -join "`n"
        $text = [regex]::Replace($text, "\x1b\[[0-9;?]*[ -/]*[@-~]", '')
        return [regex]::Replace($text, "[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", '')
    }
}

Describe 'the test programs beside the tools still pass' {
    It 'passes <Program> with at least <Tests> tests' -TestCases $script:UnitTestPrograms {
        param($Program, $Tests)
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'Python 3.11 or newer is not installed'; return }
        $path = Join-Path $script:RepoRoot $Program
        Push-Location -LiteralPath (Split-Path -Parent $path)
        try {
            $output = ConvertTo-PlainProgramOutput (& $script:Python.Source -B -m unittest -v ([IO.Path]::GetFileNameWithoutExtension($path)) 2>&1)
            $code = $LASTEXITCODE
        } finally { Pop-Location }
        $code | Should -Be 0 -Because $output
        $ran = [regex]::Match($output, '(?m)^Ran (\d+) tests? in ')
        $ran.Success | Should -BeTrue -Because $output
        [int]$ran.Groups[1].Value | Should -BeGreaterOrEqual $Tests -Because 'a program that lost tests passes on what is left'
    }

    It 'passes the automation contracts' {
        $output = ConvertTo-PlainProgramOutput (& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $script:RepoRoot 'tools/tests/medium_contracts.ps1') 2>&1)
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output | Should -Match 'Automation contracts: \d+ assertions passed'
    }

    It 'passes the stop-process contracts' {
        $output = ConvertTo-PlainProgramOutput (& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $script:RepoRoot 'tools/tests/stop_process_contracts.ps1') 2>&1)
        $LASTEXITCODE | Should -Be 0 -Because $output
    }

    It 'passes the download-agent sort contracts' {
        if (-not $script:Node) { Set-ItResult -Skipped -Because 'Node.js is not installed'; return }
        $output = ConvertTo-PlainProgramOutput (& $script:Node.Source (Join-Path $script:RepoRoot 'tools/tests/low_sort_contracts.cjs') 2>&1)
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output | Should -Match 'comparisons match'
    }
}

# A test program a suite does not name is a test nobody runs. Every one the tree
# tracks is named by some suite, or listed here with the reason it is not.
Describe 'a failing program''s output in the failure message' {
    It 'is plain text the result file can hold' {
        $esc = [char]27
        $plain = ConvertTo-PlainProgramOutput @("$esc[31;1mException:$esc[0m boom", "tab`tkept$([char]7)")
        $plain | Should -BeExactly "Exception: boom`ntab`tkept"
    }
}

Describe 'every test program in the tree is run by a suite' {
    It 'names each tracked test program in at least one suite' {
        $exempt = @{
            # The archived review records keep the tests of their time as history.
            'dev-only/review.history/' = 'archived review evidence'
        }
        # Untracked files count too: a new program or suite is held before it is committed.
        $programs = @(& git -C $script:RepoRoot ls-files --cached --others --exclude-standard 2>$null | Where-Object {
                $_ -match '(^|/)test_[^/]*\.py$' -or $_ -match '\.test\.(js|cjs|mjs)$' -or $_ -match '_contracts\.[a-z0-9]+$' -or
                $_ -match '^test/shell/test-[^/]*\.sh$'
            } | Sort-Object -Unique | Where-Object { $path = $_; -not @($exempt.Keys | Where-Object { $path.StartsWith($_, [StringComparison]::Ordinal) }).Count })
        $programs.Count | Should -BeGreaterThan 10 -Because 'git lists the tracked tree'
        $suites = @(& git -C $script:RepoRoot ls-files --cached --others --exclude-standard -- '*.Tests.ps1' 2>$null | Sort-Object -Unique | ForEach-Object {
                [IO.File]::ReadAllText((Join-Path $script:RepoRoot $_))
            }) -join "`n"
        $unrun = @($programs | Where-Object { -not $suites.Contains([IO.Path]::GetFileName($_)) })
        $unrun | Should -BeNullOrEmpty -Because 'a test program no suite names is never run; add it to a suite'
    }
}
