<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42b8e14c-5d27-4a93-8c60-71fe2a0db339
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester baseline protection mutation
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
    Prove the suite-baseline gate fails closed: an unrecorded suite, a vanished
    one, edited totals and a failing record all stop it.

    Run: Invoke-Pester -Path test/modules/Test.SuiteBaseline.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Tool = Join-Path $script:RepoRoot 'tools/Test-SuiteBaseline.ps1'
$script:BaselinePath = Join-Path $script:RepoRoot 'test/modules/suite-baseline.json'
$script:Pwsh = (Get-Process -Id $PID).Path

# Every mutation runs against a copy, so a failing run cannot leave the tracked
# baseline edited behind it.
function New-BaselineFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only disposable fixture files below Pester TestDrive.')]
    param([scriptblock]$Edit)

    $record = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:BaselinePath)) -AsHashtable
    if ($Edit) { $record = & $Edit $record }
    $path = Join-Path $TestDrive (([Guid]::NewGuid().ToString('n')) + '.json')
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $record -Depth 8),
        [Text.UTF8Encoding]::new($false))
    return $path
}

function ConvertTo-PlainDetail {
    # A gate writes warnings through the host, which colors them with ANSI
    # escapes. Those are control characters, and a control character inside a
    # failure message makes the run's own NUnit file unparseable -- the suite
    # then reports "produced no result file" instead of the assertion.
    param([string]$Text)
    return (($Text -replace "`e\[[0-9;]*m", '') -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
}

function Invoke-BaselineGate {
    param([string]$BaselinePath)
    $arguments = @('-NoProfile', '-File', $script:Tool, '-Root', $script:RepoRoot, '-Quiet')
    if ($BaselinePath) { $arguments += @('-BaselinePath', $BaselinePath) }
    $output = & $script:Pwsh @arguments 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Output = (ConvertTo-PlainDetail -Text $output) }
}
}

Describe 'the tracked suite baseline protects what actually runs' {
    # Whether the tracked record is CURRENT is the gate's own question, and the
    # aggregate asks it. It deliberately is not asked here: this suite's result
    # is one of the inputs the baseline is recorded from, so a test that
    # required the record to be current already would make adding any suite
    # unrecordable -- the run would be red until the baseline was updated, and
    # the baseline may only be written from a green run.
    It 'fails when a suite that runs is not recorded' {
        # The gap this gate exists for: a suite added after the baseline was
        # written is protected by nothing, because the record that would notice
        # its deletion never mentioned it.
        $fixture = New-BaselineFixture -Edit {
            param($r)
            $first = @($r.suites.Keys)[0]
            $r.totals.tests = [int]$r.totals.tests - [int]$r.suites[$first].total
            $r.totals.skipped = [int]$r.totals.skipped - [int]$r.suites[$first].skipped
            $r.totals.suites = [int]$r.totals.suites - 1
            $r.suites.Remove($first)
            return $r
        }
        $run = Invoke-BaselineGate -BaselinePath $fixture
        Assert-Equal -Expected 1 -Actual $run.Code -Because $run.Output
        Assert-Match 'runs but is not in the baseline' $run.Output `
            'the gate must name the suite that nothing protects'
    }

    It 'fails when a recorded suite no longer exists' {
        $fixture = New-BaselineFixture -Edit {
            param($r)
            $r.suites['test/modules/Test.NoSuchSuite.Tests.ps1'] =
                @{ total = 3; skipped = 0; seconds = 0.1 }
            $r.totals.suites = [int]$r.totals.suites + 1
            $r.totals.tests = [int]$r.totals.tests + 3
            return $r
        }
        $run = Invoke-BaselineGate -BaselinePath $fixture
        Assert-Equal -Expected 1 -Actual $run.Code -Because $run.Output
        Assert-Match 'no longer discovered' $run.Output `
            'a deletion has to be an explicit re-record, not a silent one'
    }

    It 'fails when the totals no longer sum the entries they stand for' {
        # The totals are the line a release report quotes, so they cannot be
        # edited on their own.
        $fixture = New-BaselineFixture -Edit { param($r) $r.totals.tests = [int]$r.totals.tests + 25; return $r }
        $run = Invoke-BaselineGate -BaselinePath $fixture
        Assert-Equal -Expected 1 -Actual $run.Code -Because $run.Output
        Assert-Match 'per-suite entries sum to' $run.Output 'the gate must show both numbers'
    }

    It 'fails on a hand-edited <Kind>, and names the suite and the field' -TestCases @(
        @{ Kind = 'platform floor for an unknown platform'; Field = @{ platformTotal = @{ solaris = 1 } }; Finding = "names an unknown platform 'solaris'" }
        @{ Kind = 'platform floor of zero'; Field = @{ platformTotal = @{ macos = 0 } }; Finding = 'platformTotal.macos is not a positive whole number' }
        @{ Kind = 'platform floor given as text'; Field = @{ platformTotal = @{ macos = '6' } }; Finding = 'platformTotal.macos is not a positive whole number' }
        @{ Kind = 'platform floor that is not an object'; Field = @{ platformTotal = 6 }; Finding = 'platformTotal is not an object' }
        @{ Kind = 'suite timeout given as text'; Field = @{ timeoutSeconds = 'soon' }; Finding = 'timeoutSeconds is not a positive whole number' }
        @{ Kind = 'suite timeout of zero'; Field = @{ timeoutSeconds = 0 }; Finding = 'timeoutSeconds is not a positive whole number' }
        @{ Kind = 'skip allowance for an unknown platform'; Field = @{ platformSkipped = @{ solaris = 0 } }; Finding = "platformSkipped names an unknown platform 'solaris'" }
        @{ Kind = 'skip allowance with a differently cased platform'; Field = @{ platformSkipped = @{ Windows = 0 } }; Finding = "platformSkipped names an unknown platform 'Windows'" }
        @{ Kind = 'skip allowance that is not an object'; Field = @{ platformSkipped = 0 }; Finding = 'platformSkipped is not an object' }
        @{ Kind = 'skip allowance that is null'; Field = @{ platformSkipped = $null }; Finding = 'platformSkipped is not an object' }
        @{ Kind = 'skip allowance that is an array'; Field = @{ platformSkipped = @(0, 1) }; Finding = 'platformSkipped is not an object' }
        @{ Kind = 'negative skip allowance'; Field = @{ platformSkipped = @{ linux = -1 } }; Finding = 'platformSkipped.linux is not a nonnegative whole number' }
        @{ Kind = 'skip allowance given as text'; Field = @{ platformSkipped = @{ linux = '0' } }; Finding = 'platformSkipped.linux is not a nonnegative whole number' }
        @{ Kind = 'fractional skip allowance'; Field = @{ platformSkipped = @{ linux = 0.5 } }; Finding = 'platformSkipped.linux is not a nonnegative whole number' }
        @{ Kind = 'Boolean skip allowance'; Field = @{ platformSkipped = @{ linux = $false } }; Finding = 'platformSkipped.linux is not a nonnegative whole number' }
        @{ Kind = 'skip allowance over the platform floor'; Field = @{ platformTotal = @{ macos = 6 }; platformSkipped = @{ macos = 7 } }; Finding = 'platformSkipped.macos exceeds its effective test total of 6' }
        @{ Kind = 'skip allowance over the row total'; Field = @{ platformSkipped = @{ linux = [long]::MaxValue } }; Finding = 'platformSkipped.linux exceeds its effective test total' }
    ) {
        param($Kind, $Field, $Finding)
        Assert-True ($Field.Count -gt 0) 'each case must edit at least one field'
        # A row the runner reads on every run: a malformed optional field must fail here, in CI.
        $suite = 'test/modules/Test.StatusFirewall.Tests.ps1'
        $fixture = New-BaselineFixture -Edit {
            param($r)
            foreach ($name in $Field.Keys) { $r.suites[$suite][$name] = $Field[$name] }
            return $r
        }
        $run = Invoke-BaselineGate -BaselinePath $fixture
        Assert-Equal -Expected 1 -Actual $run.Code -Because "$Kind`n$($run.Output)"
        Assert-Match ([regex]::Escape($suite)) $run.Output 'the finding must name the suite'
        Assert-Match ([regex]::Escape($Finding)) $run.Output "the finding must say what is wrong with the $Kind"
    }

    It 'takes a well-formed platform floor and suite timeout without a finding' {
        $suite = 'test/modules/Test.StatusFirewall.Tests.ps1'
        $fixture = New-BaselineFixture -Edit {
            param($r)
            $r.suites[$suite].platformTotal = @{ macos = 6; windows = 11 }
            $r.suites[$suite].timeoutSeconds = 600
            return $r
        }
        $run = Invoke-BaselineGate -BaselinePath $fixture
        Assert-True ($run.Output -notmatch 'platformTotal|timeoutSeconds') "no finding is expected about a well-formed field: $($run.Output)"
    }

    It 'accepts zero skips and the exact effective platform or row total' {
        $suite = 'test/modules/Test.StatusFirewall.Tests.ps1'
        $fixture = New-BaselineFixture -Edit {
            param($r)
            $r.suites[$suite].platformTotal = @{ macos = 6; windows = [long]$r.suites[$suite].total + 3 }
            $r.suites[$suite].platformSkipped = @{
                macos = 0
                linux = [long]$r.suites[$suite].total
                windows = [long]$r.suites[$suite].total + 3
            }
            return $r
        }
        $run = Invoke-BaselineGate -BaselinePath $fixture
        Assert-True ($run.Output -notmatch 'platformSkipped|platformTotal') "valid skip bounds must not produce a finding: $($run.Output)"
    }

    It 'refuses a baseline recorded over a failing run' {
        # A protection floor written from a red run protects the failure: the
        # runner would then accept exactly that many failures forever.
        $fixture = New-BaselineFixture -Edit { param($r) $r.totals.failed = 1; return $r }
        $run = Invoke-BaselineGate -BaselinePath $fixture
        Assert-Equal -Expected 1 -Actual $run.Code -Because $run.Output
        Assert-Match 'protection floor is a passing run' $run.Output `
            'the gate must say why a recorded failure is disqualifying'
    }

    It 'reports a missing baseline as unable to reach a verdict, not as a pass' {
        $run = Invoke-BaselineGate -BaselinePath (Join-Path $TestDrive 'no-such-baseline.json')
        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
    }

    It 'reports an unparseable baseline as unable to reach a verdict' {
        $broken = Join-Path $TestDrive 'broken-baseline.json'
        [IO.File]::WriteAllText($broken, '{ this is not json', [Text.UTF8Encoding]::new($false))
        $run = Invoke-BaselineGate -BaselinePath $broken
        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
    }

    It 'reports a baseline with no suites as unable to reach a verdict' {
        $empty = Join-Path $TestDrive 'empty-baseline.json'
        [IO.File]::WriteAllText($empty, '{ "schemaVersion": 1 }', [Text.UTF8Encoding]::new($false))
        $run = Invoke-BaselineGate -BaselinePath $empty
        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
    }

    It 'reports a suites value of the wrong shape as unable to reach a verdict' {
        # An array still answers PSObject.Properties, but with its own CLR
        # members, so without a shape check the gate would report every real
        # suite as unprotected and then throw on a member that is not a number.
        $shaped = Join-Path $TestDrive 'array-baseline.json'
        [IO.File]::WriteAllText($shaped,
            '{ "schemaVersion": 1, "totals": { "suites": 1, "tests": 1, "failed": 0, "skipped": 0 },' +
            ' "suites": [ { "path": "a", "total": 1, "skipped": 0, "seconds": 0.1 } ] }',
            [Text.UTF8Encoding]::new($false))
        $run = Invoke-BaselineGate -BaselinePath $shaped
        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
        Assert-Match 'name-keyed object' $run.Output 'the gate must say what shape it needed'
    }

    It 'is the runner own discovery, not a second definition of a suite' {
        # Two definitions of "a suite" drift, and the gate would then protect a
        # set the runner does not run.
        $source = [IO.File]::ReadAllText($script:Tool)
        Assert-Match 'Invoke-TestSuite\.ps1' $source `
            'the gate has to ask the runner what it discovers'
        Assert-Match '-ListOnly' $source `
            'discovery only: a gate that ran the suite would turn one full run into several'
    }
}

Describe 'the commit gate judges what is staged' {
    BeforeAll {
        # A scratch repository whose index the gate reads through GIT_DIR, so
        # neither this checkout's index nor its working tree is involved.
        function New-StagedFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Creates a disposable git repository below Pester TestDrive.')]
            param()
            $repo = Join-Path $TestDrive ('staged-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Path (Join-Path $repo 'test/modules') -Force
            & git init -q $repo
            foreach ($name in 'Alpha', 'Beta') { [IO.File]::WriteAllText((Join-Path $repo "test/modules/$name.Tests.ps1"), "Describe '$name' { It 'runs' { } }") }
            $record = [ordered]@{
                suites = [ordered]@{
                    'test/modules/Alpha.Tests.ps1' = [ordered]@{ total = 1; skipped = 0; seconds = 0.1 }
                    'test/modules/Beta.Tests.ps1' = [ordered]@{ total = 1; skipped = 0; seconds = 0.1 }
                }
                totals = [ordered]@{ suites = 2; tests = 2; skipped = 0; failed = 0 }
            }
            [IO.File]::WriteAllText((Join-Path $repo 'test/modules/suite-baseline.json'), (ConvertTo-Json -InputObject $record -Depth 6))
            & git -C $repo add -A
            return $repo
        }
        function Invoke-StagedGate {
            param([string]$Repository)
            $saved = Save-YurunaTestEnvironment -Name 'GIT_DIR'
            try {
                $env:GIT_DIR = Join-Path $Repository '.git'
                $output = & $script:Pwsh -NoProfile -File $script:Tool -Root $script:RepoRoot -Staged -Quiet 2>&1 | Out-String
                return @{ Code = $LASTEXITCODE; Output = (ConvertTo-PlainDetail -Text $output) }
            } finally { Restore-YurunaTestEnvironment -Saved $saved }
        }
    }

    It 'passes a consistent index whatever the working tree holds' {
        $repo = New-StagedFixture
        # Not staged, so not part of the commit.
        [IO.File]::WriteAllText((Join-Path $repo 'test/modules/Gamma.Tests.ps1'), "Describe 'Gamma' { It 'runs' { } }")
        Remove-Item -LiteralPath (Join-Path $repo 'test/modules/Beta.Tests.ps1')
        $run = Invoke-StagedGate -Repository $repo
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
    }

    It 'fails a staged suite the staged baseline does not record' {
        $repo = New-StagedFixture
        [IO.File]::WriteAllText((Join-Path $repo 'test/modules/Gamma.Tests.ps1'), "Describe 'Gamma' { It 'runs' { } }")
        & git -C $repo add 'test/modules/Gamma.Tests.ps1'
        $run = Invoke-StagedGate -Repository $repo
        Assert-Equal -Expected 1 -Actual $run.Code -Because $run.Output
        Assert-Match 'Gamma\.Tests\.ps1 runs but is not in the baseline' $run.Output
    }

    It 'fails a staged deletion of a recorded suite' {
        $repo = New-StagedFixture
        & git -C $repo rm -q --cached 'test/modules/Beta.Tests.ps1'
        $run = Invoke-StagedGate -Repository $repo
        Assert-Equal -Expected 1 -Actual $run.Code -Because $run.Output
        Assert-Match 'Beta\.Tests\.ps1 is in the baseline but no longer discovered' $run.Output
    }

    It 'refuses -BaselinePath beside -Staged as unable to reach a verdict' {
        $output = & $script:Pwsh -NoProfile -File $script:Tool -Root $script:RepoRoot -Staged -BaselinePath $script:BaselinePath -Quiet 2>&1 | Out-String
        Assert-Equal -Expected 2 -Actual $LASTEXITCODE -Because $output
    }
}
