<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42fa3c81-6d07-4b29-95e8-1c04a7b6f2d3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization inventory measurement pester
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
    Keep the domain inventory measuring the tree, and keep its measurement
    honest enough to schedule against.
.DESCRIPTION
    The inventory replaces a guess with a number, so the number has to be one
    somebody can commit to. Two things make it worth trusting, and both are
    checked here rather than asserted in a comment.

    The extraction reads real string literals. An earlier version scanned for
    quotes with a regex, which desynchronized on the first apostrophe inside a
    comment and then counted the gaps BETWEEN literals as literals -- fragments
    like ", { text: what + " arriving in a schedule as operator-facing prose.
    PowerShell literals now come from the parser and the rest from a scan that
    tracks which quote opened, so a stray apostrophe is harmless.

    And it separates strings from structural work. Nearly half of what it finds
    opens or closes mid-phrase, because the sentence is concatenated with a
    value at run time. Those cannot be translated as they stand at any price:
    word order differs between languages and a fragment cannot be reordered.
    Counting them apart is the difference between an estimate and a fiction.

    Run: Invoke-Pester -Path test/modules/Test.DomainInventory.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Tool = Join-Path $script:RepoRoot 'tools/Invoke-DomainInventory.ps1'
$script:Path = Join-Path $script:RepoRoot 'globalization/manifests/domain-inventory.json'

# The extractors, lifted out so they can be exercised on text the test writes.
$script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Tool, [ref]$null, [ref]$null)
function Get-ToolFunction {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Name IS used -- inside the FindAll predicate scriptblock, which the analyzer does not follow.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    $f = $script:Ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
        }, $true) | Select-Object -First 1
    if (-not $f) { return '' }
    return $f.Extent.Text
}
}

Describe 'the inventory measures the tree it ships with' {

    It 'has been recorded' {
        Assert-True (Test-Path -LiteralPath $script:Path -PathType Leaf) `
            'no inventory is recorded, so every estimate is still a guess'
        $doc = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:Path))
        Assert-StringEqual -Expected 'yuruna.domain-inventory/v2' -Actual $doc.schema 'the schema id changed'
        Assert-True ($doc.totals.candidates -gt 100) 'the inventory counted almost nothing, so it is measuring the wrong tree'
        Assert-True (@($doc.domains).Count -ge 10) 'the inventory describes too few domains to plan from'
    }

    It 'separates structural work from strings' {
        # The number that matters for a schedule. A raw count treats a fragment
        # and a whole sentence as one unit of work, and they are not.
        $doc = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:Path))
        Assert-True ($null -ne $doc.totals.fragments) 'the inventory does not count fragments at all'
        Assert-True ($doc.totals.fragments -gt 0) `
            'no fragment was found anywhere, which is not what this tree looks like -- check the detector'
        Assert-True ($doc.totals.fragments -lt $doc.totals.candidates) `
            'every candidate is a fragment, which means the detector is matching everything'
    }

    It 'names where each domain is heaviest' {
        $doc = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:Path))
        $withWork = @($doc.domains | Where-Object { $_.candidates -gt 0 })
        Assert-True ($withWork.Count -ge 5) 'too few domains carry work for this to be a useful queue'
        foreach ($d in $withWork) {
            Assert-True (@($d.topFiles).Count -ge 1) `
                "domain '$($d.domain)' has $($d.candidates) candidates and names no file to start with"
        }
    }

    It 'parses only reachable project display YAML' {
        $doc = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:Path))
        $project = $doc.domains | Where-Object domain -EQ 'project-config'
        Assert-Equal -Expected 28 -Actual $project.files `
            'the reachable project YAML set changed without an inventory decision'
        Assert-Equal -Expected 105 -Actual $project.englishScalars `
            'the structured reader did not find the current English display fields'
        Assert-Equal -Expected 2 -Actual $project.localizedMaps `
            'the structured reader did not find both additive locale maps'
        Assert-Equal -Expected 2 -Actual $project.localizedValues `
            'the structured reader did not enumerate the values inside the maps'
        Assert-Equal -Expected 107 -Actual $doc.totals.yamlFields `
            'YAML field accounting is absent or still based on source-code literals'

        $named = @($project.inventoryFiles)
        Assert-True ($named -contains 'test/test.runner.yml') 'the project test-set labels are not inventoried'
        Assert-True ($named -contains 'template/config/localhost/components.yml') `
            'an official template configuration map is not protected by the inventory'
        Assert-True ($named -contains 'example/website/config/localhost/components.yml') `
            'a runnable example configuration map is not protected by the inventory'
        Assert-False ([bool]($named | Where-Object {
                    $_ -like 'book/*' -or $_ -like 'example/nested.host/*' -or
                    $_ -like '*/workloads/*' -or $_ -like '*/components/*'
                })) 'excluded product/book/nested-host YAML leaked into the framework display inventory'
        Assert-False ([bool]($project.topFiles.file | Where-Object { $_ -match '\.(ps1|js|cs)$' })) `
            'example product scripts are being counted as project display configuration again'
    }

    It 'keeps English project sources distinct from translated targets' {
        $doc = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:Path))
        $project = $doc.domains | Where-Object domain -EQ 'project-docs'
        $sources = @($project.sourceDocuments)
        $targets = @($project.translatedDocuments)
        $indexes = @($project.indexDocuments)
        Assert-Equal -Expected 5 -Actual $sources.Count 'the five release source documents are not named'
        Assert-Equal -Expected 5 -Actual $targets.Count 'the five project translations are not named'
        Assert-Equal -Expected 1 -Actual $indexes.Count 'the localized index is not reported separately'
        Assert-StringEqual -Expected 'docs/pt-BR/index.md' -Actual $indexes[0] `
            'the localized index is mixed into a source or translation set'
        foreach ($source in @('README.md', 'template/README.md', 'example/README.md',
                'example/website/README.md', 'example/text-to-sql/README.md')) {
            Assert-True ($sources -ccontains $source) "project source '$source' is absent"
            Assert-False ($targets -ccontains $source) "project source '$source' is mislabeled as a translation"
        }
        Assert-True (@($targets | Where-Object { $_ -notlike 'docs/pt-BR/*' }).Count -eq 0) `
            'a translated target is outside the localized tree'
    }

    It 'still describes the tree it was recorded against' {
        # A tolerance, not an equality. This is a planning measurement rather
        # than a budget: every string anyone adds moves the count by one, and a
        # gate that fired on each of them would be re-recorded reflexively until
        # nobody read what it said. What matters is that the recorded number is
        # still the right size to plan from -- a drift of hundreds means the
        # inventory is describing a tree that no longer exists.
        $out = & pwsh -NoProfile -File $script:Tool -Quiet 2>&1 | Out-String
        $m = [regex]::Match($out, '(\d+) candidate')
        Assert-True $m.Success 'a fresh run reported no candidate count at all'

        $now = [int]$m.Groups[1].Value
        $doc = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:Path))
        $recorded = [int]$doc.totals.candidates
        $drift = [Math]::Abs($now - $recorded)
        $allowed = [Math]::Max(50, [int]($recorded * 0.02))

        Assert-True ($drift -le $allowed) `
            "the tree now holds $now candidates and the inventory records $recorded (drift $drift, allowed $allowed); re-record with tools/Invoke-DomainInventory.ps1 -Update"
    }

    It 'is byte-current for a staged release gate' {
        $out = & pwsh -NoProfile -File $script:Tool -Check -Quiet 2>&1 | Out-String
        Assert-Equal -Expected 0 -Actual $LASTEXITCODE `
            -Because "the recorded inventory is not reproducible from this tree:`n$out"
    }

    It 'fails when a recorded inventory row disappears' {
        $copy = Join-Path $TestDrive 'domain-inventory-with-gap.json'
        $doc = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:Path))
        $doc.domains = @($doc.domains | Select-Object -Skip 1)
        [IO.File]::WriteAllText($copy, (ConvertTo-Json -InputObject $doc -Depth 12))
        $out = & pwsh -NoProfile -File $script:Tool -Check -Quiet -OutputPath $copy 2>&1 | Out-String
        Assert-Equal -Expected 1 -Actual $LASTEXITCODE `
            'deleting an inventory row made the release surface smaller and still passed'
        Assert-Match -Pattern 'does not match' -Actual $out 'the stale inventory failure is not named'
    }

    It 'counts untracked framework source and reachable project YAML before commit' {
        $framework = Join-Path $TestDrive 'framework-candidate'
        $project = Join-Path $TestDrive 'project-candidate'
        New-Item -ItemType Directory -Path (Join-Path $framework 'test/status') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $project 'test') -Force | Out-Null
        & git -C $framework init --quiet
        & git -C $project init --quiet
        [IO.File]::WriteAllText((Join-Path $framework 'test/status/candidate.ps1'),
            "Write-Output 'This untracked operator message is visible.'`n")
        [IO.File]::WriteAllText((Join-Path $project 'test/test.runner.yml'),
            "testSets:`n  - name: candidate`n    displayName: Untracked candidate display name`n")
        foreach ($relative in @(
                'README.md', 'template/README.md', 'example/README.md',
                'example/website/README.md', 'example/text-to-sql/README.md',
                'docs/pt-BR/README.md', 'docs/pt-BR/template/README.md',
                'docs/pt-BR/example/README.md', 'docs/pt-BR/example/website/README.md',
                'docs/pt-BR/example/text-to-sql/README.md', 'docs/pt-BR/index.md')) {
            $path = Join-Path $project $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            [IO.File]::WriteAllText($path, "# Fixture`n")
        }
        $output = Join-Path $TestDrive 'candidate-domain-inventory.json'
        $run = & pwsh -NoProfile -File $script:Tool -Root $framework -ProjectRoot $project `
            -OutputPath $output -Update -Quiet 2>&1 | Out-String
        Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Because $run
        $doc = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($output))
        $status = $doc.domains | Where-Object domain -CEQ 'status-ui'
        $config = $doc.domains | Where-Object domain -CEQ 'project-config'
        Assert-Equal -Expected 1 -Actual $status.files `
            'the untracked framework source was invisible to the candidate inventory'
        Assert-True ([int]$status.candidates -ge 1) `
            'the untracked framework prose did not reach the inventory count'
        Assert-True (@($config.inventoryFiles) -ccontains 'test/test.runner.yml') `
            'the untracked reachable project YAML was invisible to the candidate inventory'
        Assert-Equal -Expected 1 -Actual $config.englishScalars `
            'the untracked project display field was not parsed'
    }
}

Describe 'the extraction is sound enough to schedule against' {

    It 'does not mistake the gap between two literals for a literal' {
        # The defect that made the first count fiction: one apostrophe inside a
        # comment desynchronized a quote-scanning regex, and every gap after it
        # matched as prose.
        $scan = [scriptblock]::Create((Get-ToolFunction -Name 'Get-ScannedStringLiteral') +
            "`nGet-ScannedStringLiteral -Text `$args[0]")
        $source = @'
// it's a comment with an apostrophe
var a = Y.el('span', { text: "the first real sentence here" });
var b = Y.el('div', { text: 'the second real sentence here' });
'@
        $literals = @(& $scan $source)
        $findings = @()
        foreach ($l in $literals) {
            if ($l -match '^\s*,\s*\{' -or $l -match 'Y\.el' -or $l -match '\}\s*\)') {
                $findings += "extracted a gap between literals: '$l'"
            }
        }
        Assert-NoFinding $findings 'the scanner is counting code as prose'
        Assert-True (@($literals | Where-Object { $_ -eq 'the first real sentence here' }).Count -eq 1) `
            'the first real literal was not extracted'
        Assert-True (@($literals | Where-Object { $_ -eq 'the second real sentence here' }).Count -eq 1) `
            'an apostrophe in a comment shifted everything after it'
    }

    It 'takes PowerShell literals from the parser' {
        # Exact, rather than scanned: PowerShell has a parser and the bulk of
        # the count is PowerShell, so using it is most of the accuracy.
        $fn = Get-ToolFunction -Name 'Get-PowerShellStringLiteral'
        Assert-True ([bool]$fn) 'the tool has no PowerShell literal extractor'
        Assert-True ($fn -match 'Parser\]::ParseFile') 'PowerShell literals are not read from the parser'
        Assert-True ($fn -match 'StringLiteral|StringExpandable') 'the extractor does not select string tokens'
    }

    It 'takes project display fields from parsed YAML objects' {
        $fn = Get-ToolFunction -Name 'Get-ProjectConfigCount'
        Assert-True ($fn -match 'ConvertFrom-Yaml') 'project YAML is still counted with a source regex'
        Assert-True ($fn -match 'Get-YamlDisplayField') 'the parsed object is not walked structurally'
    }

    It 'ignores null YAML sequence members without losing the surrounding map' {
        $walk = [scriptblock]::Create((Get-ToolFunction -Name 'Get-YamlDisplayField') +
            "`nGet-YamlDisplayField -Value `$args[0]")
        $yaml = [ordered]@{
            steps = @($null, [ordered]@{ displayName = 'Visible step' })
        }
        $fields = @(& $walk $yaml)
        Assert-Equal -Expected 1 -Actual $fields.Count `
            'a null YAML member stopped traversal of the reachable display map'
        Assert-StringEqual -Expected '$.steps[1].displayName' -Actual $fields[0].path `
            'the display field after a null YAML member was assigned the wrong path'
    }

    It 'calls a mid-phrase string a fragment and a sentence a sentence' {
        $isFragment = [scriptblock]::Create((Get-ToolFunction -Name 'Test-IsSentenceFragment') +
            "`nTest-IsSentenceFragment -Text `$args[0]")
        $findings = @()
        foreach ($case in @(
                @{ Text = 'A sweep of ';                       Want = $true;  Why = 'closes mid-phrase' }
                @{ Text = ' runs on its own every ';           Want = $true;  Why = 'opens and closes mid-phrase' }
                @{ Text = 'Could not read the scan status: ';  Want = $true;  Why = 'a value is appended after it' }
                @{ Text = 'No hosts discovered yet.';          Want = $false; Why = 'a whole sentence' }
                @{ Text = 'The prefix length must be 0 to 32.'; Want = $false; Why = 'a whole sentence' }
                @{ Text = 'Pause after step';                  Want = $false; Why = 'a label, not a fragment' })) {
            $got = [bool](& $isFragment $case.Text)
            if ($got -ne $case.Want) {
                $findings += "'$($case.Text)' -> fragment=$got, expected $($case.Want) ($($case.Why))"
            }
        }
        Assert-NoFinding $findings 'the fragment detector does not separate structural work from strings'
    }
}
