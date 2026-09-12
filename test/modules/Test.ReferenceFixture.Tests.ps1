<#PSScriptInfo
.VERSION 2026.09.12
.GUID 425c19e6-01ab-4b44-b9fe-f6dbc6860439
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization reference fixture parity pester
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
    Hold the en-US reference captures to the one property that makes them
    worth keeping: they notice when the English changes.
.DESCRIPTION
    A recorded capture is only useful if two things are both true. It has to
    be stable, or every unrelated run reports drift and the set gets ignored.
    And its normalization has to be narrow, or the stability is bought by
    absorbing the very edits it exists to catch.

    Those pull against each other, so both are measured here: the same
    producers captured twice agree byte for byte, and a message that loses a
    word stops matching.

    Run: Invoke-Pester -Path test/modules/Test.ReferenceFixture.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Tool = Join-Path $script:RepoRoot 'tools/Invoke-ReferenceFixture.ps1'
$script:FixtureRoot = Join-Path $script:RepoRoot 'globalization/fixtures/reference'
$script:PowerShell = (Get-Process -Id $PID).Path
$script:Manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $script:FixtureRoot 'manifest.json')))

$script:ParseErrors = $null
$script:Ast = [Management.Automation.Language.Parser]::ParseFile($script:Tool, [ref]$null, [ref]$script:ParseErrors)

# The tool runs a capture when it loads, so it cannot be dot-sourced whole.
# Its normalizer is the piece under test here and comes across on its own.
function Get-ToolFunctionText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string[]]$Name)

    $text = [Text.StringBuilder]::new()
    foreach ($wanted in $Name) {
        $definition = $script:Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $wanted
            }, $true) | Select-Object -First 1
        Assert-NotNull $definition "the tool no longer defines $wanted"
        $null = $text.AppendLine($definition.Extent.Text)
    }
    return $text.ToString()
}

function Copy-FixtureRoot {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Copies the recorded captures into a disposable directory under TestDrive.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Destination)

    $null = New-Item -ItemType Directory -Path $Destination -Force
    Copy-Item -LiteralPath (Join-Path $script:FixtureRoot 'manifest.json') -Destination $Destination -Force
    Copy-Item -LiteralPath (Join-Path $script:FixtureRoot ([string]$script:Manifest.locale)) `
        -Destination $Destination -Recurse -Force
    return $Destination
}

function Invoke-FixtureTool {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Argument)

    $all = [string[]]@('-NoProfile', '-File', $script:Tool) + $Argument
    $global:LASTEXITCODE = 0
    $text = (& $script:PowerShell @all 2>&1 | Out-String)
    return @{ Code = $LASTEXITCODE; Output = $text }
}
}

Describe 'the reference set covers what a translator will be handed' {

    It 'parses, and records a row for every named surface' {
        Assert-True (-not $script:ParseErrors -or $script:ParseErrors.Count -eq 0) `
            "the tool does not parse: $($script:ParseErrors | Select-Object -First 1)"
        Assert-Equal -Expected 'en-US' -Actual ([string]$script:Manifest.locale) `
            'the reference set is the source language, and nothing else'

        $surfaces = @($script:Manifest.rows | ForEach-Object { [string]$_.surface } | Sort-Object -Unique)
        foreach ($wanted in 'cli', 'page', 'api', 'transcript', 'listing', 'notification') {
            Assert-True ($surfaces -contains $wanted) "no reference row captures the $wanted surface"
        }
    }

    It 'captures a failing state, not only a working one' {
        # The failing paths are the ones a person reads while something is
        # wrong, and they are also the ones no happy-path capture would ever
        # reach. A set of successes would freeze the half nobody needs most.
        $outcomes = @($script:Manifest.rows | ForEach-Object { [string]$_.outcome } | Sort-Object -Unique)
        Assert-True ($outcomes -contains 'pass') 'no row captures a working state'
        Assert-True ($outcomes -contains 'fail') 'no row captures a failing state'

        foreach ($surface in 'cli', 'page', 'api') {
            $rows = @($script:Manifest.rows | Where-Object { [string]$_.surface -ceq $surface })
            $states = @($rows | ForEach-Object { [string]$_.outcome } | Sort-Object -Unique)
            Assert-Equal -Expected 2 -Actual $states.Count `
                "the $surface surface records only its $($states -join '/') state"
        }
    }

    It 'has a recorded capture for every row, and no capture without a row' {
        $recorded = @(Get-ChildItem -LiteralPath (Join-Path $script:FixtureRoot ([string]$script:Manifest.locale)) `
                -Filter '*.txt' | ForEach-Object { $_.BaseName })
        $declared = @($script:Manifest.rows | ForEach-Object { [string]$_.id })
        foreach ($id in $declared) {
            Assert-True ($recorded -contains $id) "row '$id' has never been captured"
        }
        foreach ($id in $recorded) {
            Assert-True ($declared -contains $id) "capture '$id' belongs to no row and nothing will ever check it"
        }
    }
}

Describe 'normalization removes values and leaves words' {

    It 'tokenizes a dynamic value without touching the sentence around it' {
        . ([scriptblock]::Create((Get-ToolFunctionText -Name @('Get-OrdinalSortedLine', 'ConvertTo-NormalizedFixtureText'))))
        $text = "The cycle finished at 2026-09-10T01:32:39.4104644Z on host 192.168.7.42.`r`n" +
        "Wrote /some/where/cycle.html with id 422dd0cac87e4cc6831c3228f12ae689.   `n"
        $normalized = ConvertTo-NormalizedFixtureText -Text $text -Root @{ '/some/where' = '<work>' }

        Assert-Match 'The cycle finished at <timestamp> on host <address>\.' $normalized `
            'a clock reading or an address survived into the capture'
        Assert-Match 'Wrote <work>/cycle\.html with id <id>\.' $normalized `
            'a path root or a generated identifier survived into the capture'
        foreach ($word in 'cycle', 'finished', 'host', 'Wrote', 'with', 'id') {
            Assert-Match "\b$word\b" $normalized "normalization swallowed the word '$word'"
        }
        Assert-False ($normalized.Contains("`r")) 'a carriage return survived normalization'
        Assert-Match "\.\n$" $normalized 'trailing whitespace was not trimmed to a single newline'
    }

    It 'still separates two messages that differ by one word' {
        # This is the whole bargain. Normalization is allowed to absorb values
        # so that unchanged code compares equal; the moment it can also absorb
        # a reworded sentence, every capture certifies English nobody read.
        . ([scriptblock]::Create((Get-ToolFunctionText -Name @('Get-OrdinalSortedLine', 'ConvertTo-NormalizedFixtureText'))))
        $before = ConvertTo-NormalizedFixtureText -Text "Not found at 2026-09-10T01:32:39Z`n"
        $after = ConvertTo-NormalizedFixtureText -Text "Not located at 2026-09-10T01:32:39Z`n"

        Assert-Match '^Not found at <timestamp>' $before 'the value was not tokenized'
        Assert-NotEqual -Expected $before -Actual $after `
            'a reworded message normalized to the same text, so no capture could ever notice it'
    }

    It 'orders lines the same way on every host when a row asks for ordering' {
        # Culture-aware collation would order a capture differently on a
        # Turkish or Swedish host, and every comparison against it would report
        # drift that is not there.
        . ([scriptblock]::Create((Get-ToolFunctionText -Name @('Get-OrdinalSortedLine', 'ConvertTo-NormalizedFixtureText'))))
        $text = "Irish`nindia`nIndia`n"
        $current = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            $ordered = @()
            foreach ($culture in 'en-US', 'tr-TR', 'sv-SE') {
                [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::new($culture)
                $ordered += (ConvertTo-NormalizedFixtureText -Text $text -SortLines)
            }
            Assert-Equal -Expected 1 -Actual @($ordered | Sort-Object -Unique).Count `
                'the same lines ordered differently under a different culture'
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $current
        }
    }
}

Describe 'the recorded captures answer to the producers' {

    It 'matches every producer as the tree stands' {
        $run = Invoke-FixtureTool -Argument @()
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        Assert-Match 'Invoke-ReferenceFixture: 13 row\(s\), 13 matched, 0 drifted\.' $run.Output `
            'the reported tally no longer accounts for every row'
    }

    It 'captures the same bytes twice' {
        # A capture that differs from itself would make the parity check
        # useless: nobody can tell a real edit from the noise of a second run.
        $first = Copy-FixtureRoot -Destination (Join-Path $TestDrive 'first')
        $second = Copy-FixtureRoot -Destination (Join-Path $TestDrive 'second')
        $one = Invoke-FixtureTool -Argument @('-Update', '-FixtureRoot', $first, '-Quiet')
        Assert-Equal -Expected 0 -Actual $one.Code -Because $one.Output
        $two = Invoke-FixtureTool -Argument @('-Update', '-FixtureRoot', $second, '-Quiet')
        Assert-Equal -Expected 0 -Actual $two.Code -Because $two.Output

        $locale = [string]$script:Manifest.locale
        foreach ($row in $script:Manifest.rows) {
            $name = ([string]$row.id) + '.txt'
            $a = [IO.File]::ReadAllText((Join-Path (Join-Path $first $locale) $name))
            $b = [IO.File]::ReadAllText((Join-Path (Join-Path $second $locale) $name))
            Assert-True ([string]::Equals($a, $b, [StringComparison]::Ordinal)) `
                "capturing '$($row.id)' twice produced two different texts"
        }
    }

    It 'reports drift when a recorded message changes' {
        # The negative fixture: one word of one message, and nothing else.
        # Everything around it is a value that normalization does absorb, so a
        # check that passes here is a check that cannot see prose at all.
        $copy = Copy-FixtureRoot -Destination (Join-Path $TestDrive 'reworded')
        $target = Join-Path (Join-Path $copy ([string]$script:Manifest.locale)) 'api-status-error-not-found.txt'
        $original = [IO.File]::ReadAllText($target)
        Assert-Match 'Not found' $original 'the row this negative fixture rewords no longer carries that message'
        [IO.File]::WriteAllText($target, $original.Replace('Not found', 'Not located'), [Text.UTF8Encoding]::new($false))

        $run = Invoke-FixtureTool -Argument @('-FixtureRoot', $copy, '-Quiet')

        Assert-Equal -Expected 2 -Actual $run.Code `
            -Because "a reworded message passed the parity check: $($run.Output)"
        Assert-Match 'api-status-error-not-found' $run.Output 'the drift report does not name the row that changed'
        Assert-Match 'Not located' $run.Output 'the drift report does not show what the capture claimed'
    }

    It 'reports a producer whose result stops matching its recorded outcome' {
        # The exit code is part of what a failing path promises. A refusal that
        # quietly starts succeeding would otherwise be recorded as unchanged,
        # because its text is written before anything reads the code.
        $copy = Copy-FixtureRoot -Destination (Join-Path $TestDrive 'wrong-code')
        $manifestPath = Join-Path $copy 'manifest.json'
        $manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($manifestPath))
        $row = $manifest.rows | Where-Object { [string]$_.id -ceq 'cli-document-review-ambiguous' }
        $row.exitCode = 0
        [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject $manifest -Depth 20),
            [Text.UTF8Encoding]::new($false))

        $run = Invoke-FixtureTool -Argument @('-FixtureRoot', $copy, '-Id', 'cli-document-review-ambiguous', '-Quiet')

        Assert-Equal -Expected 2 -Actual $run.Code `
            -Because "a producer contradicting its recorded exit code passed: $($run.Output)"
        Assert-Match 'exited 2, and the row records 0' $run.Output `
            'the report does not say which exit code the row expected'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
