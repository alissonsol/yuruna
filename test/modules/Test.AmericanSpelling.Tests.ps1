<#PSScriptInfo
.VERSION 2026.11.23
.GUID 421722f1-861c-46c1-a381-a5f62d98293e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test spelling american-english naming pester
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
    Hold the workspace to American spelling in names as well as prose.
.DESCRIPTION
    A prose spell check skips identifiers, so British names (a database
    column, a variable, an enum value, a test name) kept reaching the
    repositories and their consumers, and each one later cost a rename across
    every producer and consumer. tools/Test-AmericanSpelling.ps1 splits names
    into subwords and checks each one against tools/american-spelling.json.

    The fixture cases prove what it flags and what it leaves alone in a
    throwaway repository. The last case runs it over this repository and the
    sibling checkouts beside it, so a British name added anywhere in the
    workspace fails the suite.

    Run: Invoke-Pester -Path test/modules/Test.AmericanSpelling.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Check = Join-Path $script:RepoRoot 'tools' | Join-Path -ChildPath 'Test-AmericanSpelling.ps1'
$script:DataPath = Join-Path $script:RepoRoot 'tools' | Join-Path -ChildPath 'american-spelling.json'
$script:Sandbox = New-YurunaTestTempDir -Prefix 'yuruna-spelling'

# A child pwsh, because the exit code is the contract and only survives a
# process boundary.
function Invoke-SpellingCheck {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string[]]$Argument)
    $argv = @('-NoProfile', '-File', $script:Check) + $Argument
    $out = (& pwsh @argv 2>&1 | Out-String)
    return @{ Output = $out; ExitCode = $LASTEXITCODE }
}
}

AfterAll {
    Remove-YurunaTestTempDir $script:Sandbox
}

Describe 'British spellings in names and prose are reported' {
    BeforeAll {
        $script:Flagged = New-YurunaTestGitRepository -Path (Join-Path $script:Sandbox 'flagged') -File ([ordered]@{
            'scripts/count.ps1'     = "`$cancelledCount = 0`n"
            'db/schema.sql'         = "CREATE TABLE subscription (cancelled_at timestamptz);`n"
            'src/Kind.cs'           = "public enum CancelledKind { None }`n"
            'src/name_test.go'      = "func TestNormalisedX(t *testing.T) {}`n"
            'README.md'             = "# Notes`n`nThe colour of the status badge.`n"
            'tools/run.sh'          = "./setup --initialise-config`n"
            'normalised-dir/colour_utils.ps1' = "x`n"
            'globalization/terminology/pt-BR.terms.json' = "{ `"meaning`": `"The colour of a badge.`" }`n"
        })
        $script:FlaggedRun = Invoke-SpellingCheck -Argument @('-Root', $script:Flagged)
    }

    It 'exits 1 when it finds a British spelling' {
        Assert-Equal 1 $script:FlaggedRun.ExitCode "the check must fail on British names: $($script:FlaggedRun.Output)"
    }

    It 'reports <Path> with its American form' -TestCases @(
        @{ Path = 'scripts/count.ps1'; Expected = 'cancelledCount -> canceledCount' }
        @{ Path = 'db/schema.sql'; Expected = 'cancelled_at -> canceled_at' }
        @{ Path = 'src/Kind.cs'; Expected = 'CancelledKind -> CanceledKind' }
        @{ Path = 'src/name_test.go'; Expected = 'TestNormalisedX -> TestNormalizedX' }
        @{ Path = 'README.md'; Expected = 'colour -> color'; Line = 3 }
        @{ Path = 'tools/run.sh'; Expected = 'initialise-config -> initialize-config' }
        @{ Path = 'globalization/terminology/pt-BR.terms.json'; Expected = 'colour -> color' }
    ) {
        param($Path, $Expected, $Line)
        if (-not $Line) { $Line = 1 }
        $finding = "flagged/${Path}:${Line}: $Expected"
        Assert-True ($script:FlaggedRun.Output.Contains($finding)) "expected '$finding' in: $($script:FlaggedRun.Output)"
    }

    It 'reports British directory and file names once each' {
        foreach ($finding in 'flagged/normalised-dir: name normalised-dir -> normalized-dir',
                'flagged/normalised-dir/colour_utils.ps1: name colour_utils -> color_utils') {
            Assert-True ($script:FlaggedRun.Output.Contains($finding)) "expected '$finding' in: $($script:FlaggedRun.Output)"
        }
    }

    It 'counts the findings and the files in its summary' {
        Assert-Match 'Test-AmericanSpelling: 9 British spelling\(s\) in 8 file\(s\)\.' $script:FlaggedRun.Output 'summary line'
    }
}

Describe 'American forms, exceptions and excluded content pass' {
    It 'exits 0 with its success line' {
        $root = New-YurunaTestGitRepository -Path (Join-Path $script:Sandbox 'clean') -File ([ordered]@{
            'scripts/count.ps1'                      = "`$canceledCount = 0`n"
            'db/schema.sql'                          = "CREATE TABLE subscription (canceled_at timestamptz);`n"
            'src/name_test.go'                       = "func TestNormalizedX(t *testing.T) {}`n"
            'README.md'                              = "The color of the badge; initialize-config; cancellation is fine.`n"
            'src/mcp.js'                             = "if (method === 'notifications/cancelled') { stop(); }`n"
            'docs/pt-BR/README.md'                   = "The colour of the badge.`n"
            'globalization/catalogs/pt-BR/host.json' = "{ `"colour`": `"cor`" }`n"
            'test/status/pt-BR.status.js'            = "const colour = 'cor';`n"
            'dev-only/review.history/2026-01.md'     = "The cancelled_at column was renamed.`n"
        })
        $run = Invoke-SpellingCheck -Argument @('-Root', $root)
        Assert-Equal 0 $run.ExitCode "the check must pass: $($run.Output)"
        Assert-Match 'Test-AmericanSpelling: 5 file\(s\) in 1 repositories checked, no British spelling found\.' $run.Output 'success line'
    }

    It 'still reports a British word beside an exception token on the same line' {
        $root = New-YurunaTestGitRepository -Path (Join-Path $script:Sandbox 'beside') -File ([ordered]@{
            'src/mcp.js' = "// notifications/cancelled is the MCP name; colour is not.`n"
        })
        $run = Invoke-SpellingCheck -Argument @('-Root', $root)
        Assert-Equal 1 $run.ExitCode "only the exception token is ignored: $($run.Output)"
        Assert-True ($run.Output.Contains('beside/src/mcp.js:1: colour -> color')) "finding expected: $($run.Output)"
        Assert-Match 'Test-AmericanSpelling: 1 British spelling\(s\) in 1 file\(s\)\.' $run.Output 'the MCP name is an exception'
    }
}

Describe 'the check says when it cannot run' {
    It 'exits 2 for a root that is not a git work tree' {
        $plain = Join-Path $script:Sandbox 'not-a-repo'
        $null = New-Item -ItemType Directory -Force -Path $plain
        $run = Invoke-SpellingCheck -Argument @('-Root', $plain)
        Assert-Equal 2 $run.ExitCode "a missing work tree is no verdict: $($run.Output)"
    }

    It 'exits 2 when the data file is missing' {
        $run = Invoke-SpellingCheck -Argument @('-Root', $script:RepoRoot, '-DataPath', (Join-Path $script:Sandbox 'absent.json'))
        Assert-Equal 2 $run.ExitCode "a missing word map is no verdict: $($run.Output)"
    }
}

Describe 'the data file' {
    It 'maps lowercase British words to different American words and justifies every exception' {
        $data = Get-Content -LiteralPath $script:DataPath -Raw | ConvertFrom-Json -AsHashtable
        $bad = @(foreach ($key in $data.words.Keys) {
            if ($key -cnotmatch '^[a-z]+$' -or $data.words[$key] -cnotmatch '^[a-z]+$' -or $key -eq $data.words[$key]) { $key }
        })
        Assert-NoFinding $bad 'word map entries must be distinct lowercase words'
        $unjustified = @(foreach ($entry in @($data.exceptions) + @($data.skip)) {
            if (-not $entry.path -or -not $entry.reason) { $entry | ConvertTo-Json -Compress }
        })
        Assert-NoFinding $unjustified 'every exception and skip entry needs a path and a reason'
        Assert-True ($data.words.Count -gt 100) 'the word map is loaded'
    }
}

Describe 'the workspace uses American spelling' {
    It 'finds no British spelling in this repository and the sibling checkouts beside it' {
        $run = Invoke-SpellingCheck -Argument @()
        Assert-Equal 0 $run.ExitCode "rename each finding to the American form, with every producer and consumer:`n$($run.Output)"
    }
}
