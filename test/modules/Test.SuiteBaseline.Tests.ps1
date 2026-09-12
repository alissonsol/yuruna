<#PSScriptInfo
.VERSION 2026.09.12
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
