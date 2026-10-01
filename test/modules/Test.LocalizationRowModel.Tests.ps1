<#PSScriptInfo
.VERSION 2026.09.30
.GUID 4248723f-4da9-4aa4-932f-35e16aecf9b0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization localization row-model pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES Pester powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Hold the localization row model to the rows a locale is actually made of.
.DESCRIPTION
    Every localization request starts from Get-LocalizationRow. A locale that
    has just been declared has a manifest entry and nothing else: no
    terminology files and no mapped documents. It has to enumerate to the
    message and project rows it does have instead of stopping on the sources
    it does not have yet.

    A plural message is asked in the target language's own categories.
    English has one and other. A language with a dual also needs two, and a
    language without grammatical number has only other. A question that
    offered English's categories would ask for a form the target cannot use
    and leave out one it must supply.

    A message row is bound to its answer by a hash that the exchange module
    computes and the catalog compiler checks. The two are separate
    implementations, so the suite compiles a fixture with the real compiler
    and requires both to agree on every key.

    Every fixture is written in-line under TestDrive from the public tree
    alone, so a public checkout runs the whole suite.

    Run: Invoke-Pester -Path test/modules/Test.LocalizationRowModel.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.LocalizationExchange.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:PowerShell = (Get-Process -Id $PID).Path

function Write-FixtureJson {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only inside a disposable fixture tree under TestDrive.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)

    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    $json = ((ConvertTo-Json -InputObject $Value -Depth 30) -replace "`r`n", "`n").TrimEnd() + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Write-FixtureText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only inside a disposable fixture tree under TestDrive.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-FixtureCatalog {
    <#
    .SYNOPSIS
        The en-US source messages, by domain, with one of every message shape.
    .DESCRIPTION
        Property order is deliberately unsorted. Both hashes sort before
        hashing, and a fixture that was already sorted could not tell a hash
        that sorts from one that does not.
    .OUTPUTS
        [ordered] domain -> ordered messages
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    return [ordered]@{
        demo = [ordered]@{
            'demo.not_found' = [ordered]@{
                message = 'Not found'
                lifecycle = 'active'
                description = 'Shown when a resource does not exist.'
            }
            'demo.count' = [ordered]@{
                plural = [ordered]@{
                    variants = [ordered]@{ other = '{count} items waiting'; one = '{count} item waiting' }
                    selector = 'count'
                }
                placeholders = [ordered]@{ count = [ordered]@{ type = 'integer'; example = 2; trust = 'internal' } }
                lifecycle = 'active'
                description = 'Summary above the queue.'
            }
            'demo.branch' = [ordered]@{
                select = [ordered]@{
                    variants = [ordered]@{ waiting = 'Waiting for a host'; other = 'Ready' }
                    selector = 'state'
                }
                placeholders = [ordered]@{ state = [ordered]@{ type = 'text'; example = 'waiting'; trust = 'internal' } }
                lifecycle = 'active'
                description = 'Status line for one queued cycle.'
            }
            'demo.quoted' = [ordered]@{
                # A quote, a backslash and a non-ASCII letter: each is escaped
                # or encoded on its way into both hashes.
                message = 'Copied "{path}" to C:\share for the caf' + [char]0x00E9 + '.'
                placeholders = [ordered]@{ path = [ordered]@{ type = 'text'; trust = 'external'; example = 'notes.txt' } }
                description = 'Confirmation after a copy.'
                lifecycle = 'active'
            }
            'demo.size' = [ordered]@{
                message = 'Uses {size} GiB.'
                placeholders = [ordered]@{ size = [ordered]@{ type = 'decimal'; trust = 'internal'; example = 1.5 } }
                description = 'Disk use of one guest.'
                lifecycle = 'active'
            }
            'demo.old' = [ordered]@{
                replacedBy = 'demo.not_found'
                message = 'Missing'
                lifecycle = 'deprecated'
                description = 'Earlier wording of the not-found notice.'
            }
            'demo.retired' = [ordered]@{ lifecycle = 'tombstone'; description = 'A banner nothing renders.' }
        }
        panel = [ordered]@{
            'panel.title' = [ordered]@{ message = 'Queue'; description = 'Heading of the queue panel.'; lifecycle = 'active' }
        }
    }
}

function New-RowModelFixture {
    <#
    .SYNOPSIS
        A framework and project pair in which only xx-XX has locale content.
    .DESCRIPTION
        xx-XX carries terminology, a style guide, two mapped documents and a
        sidecar entry. yy-YY (one, two, other) and zz-ZZ (other) are declared
        in the manifest and nothing else, which is how a locale looks on the
        day it is added. The compiler and the catalog schema are copied in, so
        a compile writes only inside the fixture.
    .OUTPUTS
        [hashtable] Root, ProjectRoot, Globalization, Compiler
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a disposable fixture tree under TestDrive.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Base,
        [System.Collections.IDictionary]$Catalog = (Get-FixtureCatalog),
        [string]$SequenceYaml = "sequenceGuid: 422ff119-a25d-4ba6-9877-9e1885fef859`nsteps:`n  - name: smoke`n    displayName: Quick smoke test`n"
    )

    $root = Join-Path $Base 'framework'
    $project = Join-Path $Base 'project'
    $globalization = Join-Path $root 'globalization'
    foreach ($relative in @('tools/Invoke-CatalogCompile.ps1', 'globalization/schema/catalog.schema.json', 'test/modules/Test.LocalizationExchange.psm1', 'test/modules/Test.CanonicalJson.psm1')) {
        $target = Join-Path $root $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        [IO.File]::Copy((Join-Path $script:RepoRoot $relative), $target)
    }
    Write-FixtureJson -Path (Join-Path $globalization 'locale-manifest.json') -Value ([ordered]@{
            schema = 'yuruna.locale-manifest/v1'
            default = 'en-US'
            locales = [ordered]@{
                'en-US' = [ordered]@{ status = 'supported'; pluralRule = 'one-if-1'; pluralCategories = @('one', 'other') }
                'xx-XX' = [ordered]@{ status = 'planned'; pluralCategories = @('one', 'other') }
                'yy-YY' = [ordered]@{ status = 'planned'; pluralCategories = @('one', 'two', 'other') }
                'zz-ZZ' = [ordered]@{ status = 'planned'; pluralCategories = @('other') }
                'qps-Ploc' = [ordered]@{ status = 'pseudo'; pluralCategories = @('one', 'other') }
                'qps-Plocm' = [ordered]@{ status = 'pseudo'; pluralCategories = @('one', 'other') }
            }
        })
    foreach ($domain in $Catalog.Keys) {
        Write-FixtureJson -Path (Join-Path $globalization "catalogs/en-US/$domain.json") -Value ([ordered]@{
                schema = 'yuruna.catalog/v1'
                domain = [string]$domain
                locale = 'en-US'
                messages = $Catalog[$domain]
            })
    }
    Write-FixtureJson -Path (Join-Path $globalization 'terminology/xx-XX.terms.json') -Value ([ordered]@{
            schema = 'yuruna.terminology/v1'
            locale = 'xx-XX'
            terms = @([ordered]@{ sourceTerm = 'host'; meaning = 'The physical machine.'; sourceHeadings = @('Hosts')
                    decision = [ordered]@{ status = 'pending' }
                })
            # A fictional pair: a real retired name in a fixture trips the
            # repository's own retired-name hook.
            retiredNameRulings = @([ordered]@{ retired = 'fixture widget'; current = 'fixture component'
                    translationPolicy = 'preserve-exact-english'
                })
        })
    Write-FixtureJson -Path (Join-Path $globalization 'terminology/xx-XX.style-guide.json') -Value ([ordered]@{
            schema = 'yuruna.style-guide/v1'
            locale = 'xx-XX'
            rules = @([ordered]@{ id = 'tone'; topic = 'Tone'; guidance = 'Be direct and concise.' })
        })
    Write-FixtureText -Path (Join-Path $root 'README.md') -Text "# Framework`n`nThe framework readme.`n"
    Write-FixtureText -Path (Join-Path $project 'README.md') -Text "# Project`n`nThe project readme.`n"
    Write-FixtureJson -Path (Join-Path $globalization 'manifests/doc-translations.json') -Value ([ordered]@{
            schema = 'yuruna.doc-translations/v1'
            documents = @(
                [ordered]@{ repo = 'yuruna'; source = 'README.md'; locale = 'xx-XX'
                    translated = 'docs/xx-XX/README.md'; sourceHash = ('c' * 64)
                }
                [ordered]@{ repo = 'yuruna-project'; source = 'README.md'; locale = 'xx-XX'
                    translated = 'docs/xx-XX/README.md'; sourceHash = ('d' * 64)
                }
            )
        })
    Write-FixtureJson -Path (Join-Path $project 'globalization/project-locale-source-hashes.json') -Value ([ordered]@{
            schema = 'yuruna.project-locale-source-hashes/v1'
            hashAlgorithm = 'sha256-utf8-nfc-scalar-v1'
            entries = @([ordered]@{ path = 'test/smoke.yml'; fieldPath = '/steps/name=smoke/displayName'
                    locale = 'xx-XX'; sourceHash = ('e' * 64)
                })
        })
    Write-FixtureText -Path (Join-Path $project 'test/smoke.yml') -Text $SequenceYaml
    return @{
        Root = $root
        ProjectRoot = $project
        Globalization = $globalization
        Compiler = Join-Path $root 'tools/Invoke-CatalogCompile.ps1'
    }
}

function Invoke-FixtureCompile {
    <#
    .SYNOPSIS
        Compile the fixture's catalogs with -Update in a child process.
    .DESCRIPTION
        A child process because the compiler ends with exit, and its exit
        code is part of what it reports. Escape and control characters are
        stripped from the output: it can reach an assertion message, and they
        are illegal in the XML result file that message is written to.
    .OUTPUTS
        [hashtable] Code, Output
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Fixture)

    $text = (& $script:PowerShell -NoProfile -File $Fixture.Compiler -Root $Fixture.Globalization -Update -Quiet 2>&1 | Out-String)
    $text = ($text -replace "`e\[[0-9;]*[A-Za-z]", '') -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
    return @{ Code = $LASTEXITCODE; Output = $text }
}

function Get-RowKindList {
    <#
    .SYNOPSIS
        The distinct row kinds, ordinal-sorted and comma-joined.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Row)

    $kinds = @($Row | ForEach-Object { [string]$_.kind } | Select-Object -Unique)
    return (Get-OrdinalSortedName -Name $kinds) -join ','
}

function Get-VariantKeyList {
    <#
    .SYNOPSIS
        The category names of a plural row's English question, ordinal-sorted.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Variant)

    return (Get-OrdinalSortedName -Name @($Variant.Keys | ForEach-Object { [string]$_ })) -join ','
}
}

Describe 'a locale enumerates the rows it has' {

    It 'enumerates a locale with no terminology files and no mapped documents' {
        $fixture = New-RowModelFixture -Base (Join-Path $TestDrive 'new-locale')

        # The control: the same tree does carry every kind, for xx-XX, so a
        # missing kind below is the locale's absence and not a thin fixture.
        $control = @(Get-LocalizationRow -Root $fixture.Root -ProjectRoot $fixture.ProjectRoot -Locale 'xx-XX')
        Get-RowKindList -Row $control | Should -BeExactly 'document,message,project-scalar,ruling,style-rule,term'

        $rows = @(Get-LocalizationRow -Root $fixture.Root -ProjectRoot $fixture.ProjectRoot -Locale 'yy-YY')
        Get-RowKindList -Row $rows | Should -BeExactly 'message,project-scalar'
        $expected = @(
            'message:demo:demo.branch'
            'message:demo:demo.count'
            'message:demo:demo.not_found'
            'message:demo:demo.old'
            'message:demo:demo.quoted'
            'message:demo:demo.size'
            'message:panel:panel.title'
            'project-scalar:test/smoke.yml:/steps/name=smoke/displayName'
        )
        (@($rows | ForEach-Object { [string]$_.id }) -join "`n") | Should -BeExactly ($expected -join "`n")
        $scalar = $rows | Where-Object { [string]$_.kind -ceq 'project-scalar' }
        [string]$scalar.english | Should -BeExactly 'Quick smoke test'
    }

    It 'returns an empty array for a locale with no rows at all' {
        # Every source is present and yields nothing for yy-YY: the only
        # source message is a tombstone, the terminology and documents belong
        # to xx-XX, and the project file declares no display field.
        $retired = [ordered]@{ demo = [ordered]@{ 'demo.retired' = [ordered]@{ lifecycle = 'tombstone'; description = 'A banner nothing renders.' } } }
        $fixture = New-RowModelFixture -Base (Join-Path $TestDrive 'no-rows') -Catalog $retired -SequenceYaml "name: plain`n"

        $rows = @(Get-LocalizationRow -Root $fixture.Root -ProjectRoot $fixture.ProjectRoot -Locale 'yy-YY')
        $rows.Count | Should -Be 0
    }
}

Describe 'a plural question is asked in the target language' {

    It 'seeds plural rows with exactly the target categories' {
        $fixture = New-RowModelFixture -Base (Join-Path $TestDrive 'plural')
        $id = 'message:demo:demo.count'
        $question = @{}
        foreach ($locale in @('yy-YY', 'zz-ZZ')) {
            $question[$locale] = @(Get-LocalizationRow -Root $fixture.Root -ProjectRoot $fixture.ProjectRoot -Locale $locale |
                    Where-Object { [string]$_.id -ceq $id })
            $question[$locale].Count | Should -Be 1 -Because "$locale asks about $id once"
        }

        # A dual: two is not an English form, so it is seeded from other,
        # while one keeps the English form of the same name.
        $dual = ConvertFrom-Json -InputObject ([string]$question['yy-YY'][0].english) -AsHashtable
        Get-VariantKeyList -Variant $dual | Should -BeExactly 'one,other,two'
        $dual['one'] | Should -BeExactly '{count} item waiting'
        $dual['two'] | Should -BeExactly '{count} items waiting'
        $dual['other'] | Should -BeExactly '{count} items waiting'

        # No grammatical number: English's one is a form this locale cannot
        # use, so it is not asked for.
        $single = ConvertFrom-Json -InputObject ([string]$question['zz-ZZ'][0].english) -AsHashtable
        Get-VariantKeyList -Variant $single | Should -BeExactly 'other'
        $single['other'] | Should -BeExactly '{count} items waiting'

        # Without a target the question is the English contract itself, and the
        # seeded question never moves the hash an answer is bound to.
        $source = @(Get-MessageRow -Root $fixture.Root | Where-Object { [string]$_.id -ceq $id })
        $english = ConvertFrom-Json -InputObject ([string]$source[0].english) -AsHashtable
        Get-VariantKeyList -Variant $english | Should -BeExactly 'one,other'
        [string]$question['yy-YY'][0].sourceSha256 | Should -BeExactly ([string]$source[0].sourceSha256)
        [string]$question['zz-ZZ'][0].sourceSha256 | Should -BeExactly ([string]$source[0].sourceSha256)
    }
}

Describe 'the row hash is the compiler''s hash' {

    It 'hashes a message exactly as the compiler' {
        $fixture = New-RowModelFixture -Base (Join-Path $TestDrive 'compiled')
        $run = Invoke-FixtureCompile -Fixture $fixture
        # -Update exits 1 when it wrote, and a fresh tree always has artifacts
        # to write; a validation failure also exits 1, so the text decides.
        $run.Code | Should -Be 1 -Because $run.Output
        $run.Output | Should -Match '; wrote [1-9][0-9]* artifact\(s\)\.' -Because $run.Output
        $run.Output | Should -Not -Match 'Catalog validation failed' -Because $run.Output

        $set = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $fixture.Globalization 'manifests/catalog-set.json')))
        $message = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $fixture.Globalization 'catalogs/en-US') -Filter '*.json' -File)) {
            $catalog = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file.FullName))
            foreach ($property in $catalog.messages.PSObject.Properties) { $message[$property.Name] = $property.Value }
        }
        $keys = @(Get-OrdinalSortedName -Name @($message.Keys | ForEach-Object { [string]$_ }))
        $keys.Count | Should -Be 8
        (@(Get-OrdinalSortedName -Name @($set.messageSources.PSObject.Properties.Name)) -join ',') |
            Should -BeExactly ($keys -join ',') -Because 'the compiler records a hash for every source key, tombstones included'

        $mismatch = foreach ($key in $keys) {
            $expected = [string]$set.messageSources.$key.sourceHash
            $actual = Get-LocalizationMessageHash -Key $key -Message $message[$key]
            if ($actual -cne $expected) { "${key}: compiler $expected, row model $actual" }
        }
        Assert-NoFinding $mismatch 'an answer bound to the row model''s hash would be called stale by the compiler'

        $rows = @(Get-LocalizationRow -Root $fixture.Root -ProjectRoot $fixture.ProjectRoot -Locale 'yy-YY' |
                Where-Object { [string]$_.kind -ceq 'message' })
        $rows.Count | Should -Be 7 -Because 'every source message but the tombstone is a row'
        $drift = foreach ($row in $rows) {
            $expected = [string]$set.messageSources.([string]$row.pointer).sourceHash
            if ([string]$row.sourceSha256 -cne $expected) { "$($row.id): compiler $expected, row $($row.sourceSha256)" }
        }
        Assert-NoFinding $drift 'a message row carries a source digest the compiler does not record'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
