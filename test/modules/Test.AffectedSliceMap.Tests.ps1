<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42d54579-288d-4a9f-a983-d5f9e1894a16
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization boundary slice mutation
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
    Prove the affected-slice boundary map is deterministic and fails closed.

    Run: Invoke-Pester -Path test/modules/Test.AffectedSliceMap.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Tool = Join-Path $script:RepoRoot 'tools/Invoke-AffectedSliceMap.ps1'
$script:Pwsh = (Get-Process -Id $PID).Path

function Write-FixtureJson {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only disposable fixture files below Pester TestDrive.')]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $json = ($Value | ConvertTo-Json -Depth 14) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function Invoke-FixtureMap {
    param([Parameter(Mandatory)]$Fixture, [switch]$Update, [switch]$Check)
    $arguments = @(
        '-NoProfile', '-File', $script:Tool,
        '-Root', $Fixture.Root,
        '-Manifest', $Fixture.Manifest,
        '-CodeRegistry', $Fixture.Registry,
        '-OutputPath', $Fixture.Output,
        '-Quiet'
    )
    if ($Update) { $arguments += '-Update' }
    if ($Check) { $arguments += '-Check' }
    $output = & $script:Pwsh @arguments 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Output = $output }
}

function New-SliceMapFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a disposable boundary tree below Pester TestDrive.')]
    param()

    $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
    foreach ($dir in @('src', 'globalization/manifests', 'globalization/generated')) {
        New-Item -ItemType Directory -Path (Join-Path $root $dir) -Force | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $root 'src/producer.ps1'), "'sample.ready'`n")
    [IO.File]::WriteAllText((Join-Path $root 'src/consumer.js'), "if (code === 'sample.ready') { use(); }`n")
    [IO.File]::WriteAllText((Join-Path $root 'src/visual.js'), "function headingRule(text) { return text; }`n")

    $registry = [ordered]@{
        schema = 'yuruna.code-registry/v1'
        codes = @([ordered]@{
                code = 'ready'
                wireCode = 'sample.ready'
                producedBy = @('src/producer.ps1')
                consumedBy = @('src/consumer.js')
            })
    }
    $authority = [ordered]@{
        schema = 'yuruna.affected-slice-authority/v1'
        seededSlices = @(
            [ordered]@{ id = 'seed-one'; domains = @('one'); nextOwner = 'G2-01' },
            [ordered]@{ id = 'seed-two'; domains = @('two'); nextOwner = 'G2-02' }
        )
        literalExclusions = @()
        signatureConsumers = @([ordered]@{
                id = 'signature:visual-heading'; path = 'src/visual.js'
                pattern = 'headingRule'; minimumMatches = 1; maximumMatches = 1
            })
        rows = @(
            [ordered]@{
                id = 'P-01'; kind = 'blocker'; status = 'closed'; owner = 'G1-08'
                slices = @('seed-one')
                consumers = @(
                    'code:sample.ready:producer:src/producer.ps1',
                    'code:sample.ready:consumer:src/consumer.js'
                )
            },
            [ordered]@{
                id = 'M-03'; kind = 'display-only-census'; status = 'deferred'; owner = 'G2-07'
                slices = @('seed-one'); consumers = @('signature:visual-heading')
            }
        )
    }
    $fixture = @{
        Root = $root
        Registry = Join-Path $root 'globalization/manifests/code-registry.json'
        Manifest = Join-Path $root 'globalization/manifests/affected-slice-authority.json'
        Output = Join-Path $root 'globalization/generated/affected-slice-map.json'
    }
    Write-FixtureJson -Path $fixture.Registry -Value $registry
    Write-FixtureJson -Path $fixture.Manifest -Value $authority
    return $fixture
}

function Read-FixtureJson {
    param([Parameter(Mandatory)][string]$Path)
    return ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))
}
}

Describe 'affected-slice map generation' {
    It 'checks the repository evidence byte for byte' {
        $run = & $script:Pwsh -NoProfile -File $script:Tool -Root $script:RepoRoot -Check -Quiet 2>&1 | Out-String
        Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Because $run
    }

    It 'is deterministic and reports both clean seeds open' {
        $fixture = New-SliceMapFixture
        $first = Invoke-FixtureMap -Fixture $fixture -Update
        Assert-Equal -Expected 0 -Actual $first.Code -Because $first.Output
        $bytes = [IO.File]::ReadAllBytes($fixture.Output)
        $second = Invoke-FixtureMap -Fixture $fixture -Update
        Assert-Equal -Expected 0 -Actual $second.Code -Because $second.Output
        Assert-Equal -Expected ([Convert]::ToBase64String($bytes)) `
            -Actual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.Output))) `
            -Because 'two updates emitted different bytes'
        $map = Read-FixtureJson $fixture.Output
        Assert-Equal -Expected 2 -Actual @($map.slices | Where-Object seedOpen).Count
        Assert-Equal -Expected 0 -Actual $map.summary.openBlockerCount
    }

    It 'rejects a reverse-discovered code edge with no mapping row' {
        $fixture = New-SliceMapFixture
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'src/new-consumer.js'), "use('sample.ready');`n")
        $registry = Read-FixtureJson $fixture.Registry
        $registry.codes[0].consumedBy = @($registry.codes[0].consumedBy) + 'src/new-consumer.js'
        Write-FixtureJson -Path $fixture.Registry -Value $registry
        $run = Invoke-FixtureMap -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code -Because 'an unknown boundary consumer was accepted'
        Assert-Match -Pattern 'unknown/unmapped boundary consumer' -Actual $run.Output
    }

    It 'rejects a distinctive wire code found only in an undeclared source file' {
        $fixture = New-SliceMapFixture
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'src/source-only.js'),
            "use('sample.ready');`n")
        $run = Invoke-FixtureMap -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code -Because 'a source-only wire-code consumer was accepted'
        Assert-Match -Pattern 'code:sample\.ready:source:src/source-only\.js' -Actual $run.Output
        Assert-Match -Pattern 'unknown/unmapped boundary consumer' -Actual $run.Output
    }

    It 'rejects a generic runtime code found only in an undeclared source file' {
        $fixture = New-SliceMapFixture
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'src/source-only.ps1'),
            "if (`$state -eq 'ready') { return }`n")
        $run = Invoke-FixtureMap -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code -Because 'a generic source-only code consumer was accepted'
        Assert-Match -Pattern 'code:sample\.ready:source:src/source-only\.ps1' -Actual $run.Output
    }

    It 'ignores comments and test bodies during production reverse discovery' {
        $fixture = New-SliceMapFixture
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'src/comment-only.js'),
            "// 'sample.ready' is documentation only.`n")
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'src/Fixture.Tests.ps1'),
            "'sample.ready'`n")
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'src/fixture_test.go'),
            ('package fixture' + "`n" + 'var code = "sample.ready"' + "`n"))
        $run = Invoke-FixtureMap -Fixture $fixture -Update
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
    }

    It 'accepts only an exact reviewed unrelated-literal classification' {
        $fixture = New-SliceMapFixture
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'src/unrelated.js'),
            "var readinessBadge = 'ready';`n")
        $authority = Read-FixtureJson $fixture.Manifest
        $authority.literalExclusions = @([pscustomobject]@{
                wireCode = 'sample.ready'; path = 'src/unrelated.js'; matchCount = 1
                reason = 'This is a presentation badge, not the sample protocol.'
            })
        Write-FixtureJson -Path $fixture.Manifest -Value $authority
        $pass = Invoke-FixtureMap -Fixture $fixture -Update
        Assert-Equal -Expected 0 -Actual $pass.Code -Because $pass.Output

        [IO.File]::AppendAllText((Join-Path $fixture.Root 'src/unrelated.js'), "var again = 'ready';`n")
        $fail = Invoke-FixtureMap -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $fail.Code -Because 'a changed exclusion match count was accepted'
        Assert-Match -Pattern 'expected 1, found 2' -Actual $fail.Output
    }

    It 'rejects an explicit signature that no row maps' {
        $fixture = New-SliceMapFixture
        $authority = Read-FixtureJson $fixture.Manifest
        $authority.signatureConsumers = @($authority.signatureConsumers) + [pscustomobject]@{
            id = 'signature:unmapped'; path = 'src/visual.js'; pattern = 'function'; minimumMatches = 1
        }
        Write-FixtureJson -Path $fixture.Manifest -Value $authority
        $run = Invoke-FixtureMap -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code -Because 'an unmapped census consumer was accepted'
        Assert-Match -Pattern 'unknown/unmapped boundary consumer' -Actual $run.Output
    }

    It 'does not let a comment satisfy a source signature' {
        $fixture = New-SliceMapFixture
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'src/visual.js'),
            "// function headingRule(text) was removed.`n")
        $run = Invoke-FixtureMap -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code `
            -Because 'a comment preserved a deleted boundary implementation'
        Assert-Match -Pattern 'known boundary consumer was deleted or renamed' -Actual $run.Output
    }

    It 'rejects a non-positive source-signature minimum' {
        $fixture = New-SliceMapFixture
        $authority = Read-FixtureJson $fixture.Manifest
        $authority.signatureConsumers[0].minimumMatches = 0
        Write-FixtureJson -Path $fixture.Manifest -Value $authority
        $run = Invoke-FixtureMap -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code `
            -Because 'zero matches was accepted as an authority minimum'
        Assert-Match -Pattern 'minimumMatches must be at least 1' -Actual $run.Output
    }

    It 'rejects an unowned blocker row' {
        $fixture = New-SliceMapFixture
        $authority = Read-FixtureJson $fixture.Manifest
        $authority.rows[0].owner = ''
        Write-FixtureJson -Path $fixture.Manifest -Value $authority
        $run = Invoke-FixtureMap -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code -Because 'an unowned row was accepted'
        Assert-Match -Pattern "unowned row 'P-01'" -Actual $run.Output
    }

    It 'rejects an unknown row classification' {
        $fixture = New-SliceMapFixture
        $authority = Read-FixtureJson $fixture.Manifest
        $authority.rows[0].kind = 'waiver'
        Write-FixtureJson -Path $fixture.Manifest -Value $authority
        $run = Invoke-FixtureMap -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code -Because 'an unknown row kind was accepted'
        Assert-Match -Pattern 'unknown row kind' -Actual $run.Output
    }

    It 'rejects deletion of a known registry consumer' {
        $fixture = New-SliceMapFixture
        Remove-Item -LiteralPath (Join-Path $fixture.Root 'src/consumer.js') -Force
        $run = Invoke-FixtureMap -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code -Because 'a deleted known consumer was accepted'
        Assert-Match -Pattern 'known boundary consumer was deleted' -Actual $run.Output
    }

    It 'rejects a declared edge whose code appears only in a comment' {
        $fixture = New-SliceMapFixture
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'src/producer.ps1'),
            "# 'sample.ready' is documentation, not an emitted value.`n")
        $run = Invoke-FixtureMap -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code `
            -Because 'a comment-only registry claim received a synthetic match count'
        Assert-Match -Pattern 'carries neither' -Actual $run.Output
    }

    It 'rejects a display-only census row without a named G2 owner' {
        $fixture = New-SliceMapFixture
        $authority = Read-FixtureJson $fixture.Manifest
        $authority.rows[1].owner = 'G1-08'
        Write-FixtureJson -Path $fixture.Manifest -Value $authority
        $run = Invoke-FixtureMap -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code -Because 'a display-only row escaped Wave-2 ownership'
        Assert-Match -Pattern 'has no named G2 owner' -Actual $run.Output
    }

    It 'blocks only the slice reached by an open blocker' {
        $fixture = New-SliceMapFixture
        $authority = Read-FixtureJson $fixture.Manifest
        $authority.rows[0].status = 'open'
        Write-FixtureJson -Path $fixture.Manifest -Value $authority
        $run = Invoke-FixtureMap -Fixture $fixture -Update
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        $map = Read-FixtureJson $fixture.Output
        $one = $map.slices | Where-Object id -EQ 'seed-one'
        $two = $map.slices | Where-Object id -EQ 'seed-two'
        Assert-False -Condition $one.seedOpen -Because 'the reachable open blocker did not close seed one'
        Assert-True -Condition $two.seedOpen -Because 'an unrelated blocker closed seed two'
        Assert-Equal -Expected 'P-01' -Actual $one.openBlockers[0]
    }

    It 'rejects stale generated evidence' {
        $fixture = New-SliceMapFixture
        $update = Invoke-FixtureMap -Fixture $fixture -Update
        Assert-Equal -Expected 0 -Actual $update.Code -Because $update.Output
        $authority = Read-FixtureJson $fixture.Manifest
        $authority.rows[0].status = 'open'
        Write-FixtureJson -Path $fixture.Manifest -Value $authority
        $run = Invoke-FixtureMap -Fixture $fixture -Check
        Assert-Equal -Expected 1 -Actual $run.Code -Because 'stale evidence was accepted'
        Assert-Match -Pattern 'generated affected-slice map is stale' -Actual $run.Output
    }
}
