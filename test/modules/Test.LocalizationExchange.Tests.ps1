<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42e05a94-3c17-4d6b-81f9-7ab2c6d035e1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization localization exchange pester
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
    Hold the three-command localization exchange to the properties that make it
    safe to hand a language to people outside the repository.
.DESCRIPTION
    The exchange replaces a hand-driven handoff, so its value is entirely in
    what it refuses and what it remembers: an answer that does not answer the
    question that was asked, a second signature that is the same person, a
    document name that exists in two repositories, and a row nobody answered
    that a later round quietly treats as settled.

    Every test here runs against a synthetic tree. Importing writes terminology,
    catalogs and documents in place, and a test that did that to the real
    repository would be indistinguishable from a real translation arriving.

    Run: Invoke-Pester -Path test/modules/Test.LocalizationExchange.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Export = Join-Path $script:RepoRoot 'tools/Export-Localization.ps1'
$script:Import = Join-Path $script:RepoRoot 'tools/Import-Localization.ps1'
$script:Publish = Join-Path $script:RepoRoot 'tools/Publish-Localization.ps1'
$script:PowerShell = (Get-Process -Id $PID).Path
$script:Tag = 'xx-XX'

Import-Module (Join-Path $here 'Test.LocalizationExchange.psm1') -Force -Global -DisableNameChecking

function Write-FixtureJson {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only inside a disposable fixture tree under TestDrive.')]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)

    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    $json = ((ConvertTo-Json -InputObject $Value -Depth 30) -replace "`r`n", "`n").TrimEnd() + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Write-FixtureText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only inside a disposable fixture tree under TestDrive.')]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function New-ExchangeFixture {
    <#
    .SYNOPSIS
        A minimal repository pair with one of every row kind.
    .DESCRIPTION
        Both repositories carry a README.md, because that collision is the one
        the exchange has to make structurally impossible rather than merely
        refuse.
    .OUTPUTS
        [hashtable] Root, ProjectRoot, InputRoot, OutputRoot, RecorderLog
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a disposable fixture tree under TestDrive.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Base)

    $root = Join-Path $Base 'framework'
    $project = Join-Path $Base 'project'
    $null = New-Item -ItemType Directory -Path $root -Force
    $null = New-Item -ItemType Directory -Path $project -Force

    Write-FixtureText -Path (Join-Path $root 'VERSION') -Text "2026.09.13`n"
    Write-FixtureJson -Path (Join-Path $root 'globalization/locale-manifest.json') -Value ([ordered]@{
            schema = 'yuruna.locale-manifest/v1'
            default = 'en-US'
            locales = [ordered]@{
                'en-US' = [ordered]@{ status = 'supported' }
                'xx-XX' = [ordered]@{ status = 'planned' }
                'qps-Ploc' = [ordered]@{ status = 'pseudo' }
            }
        })
    Write-FixtureJson -Path (Join-Path $root 'globalization/catalogs/en-US/demo.json') -Value ([ordered]@{
            schema = 'yuruna.catalog/v1'
            domain = 'demo'
            locale = 'en-US'
            messages = [ordered]@{
                'demo.not_found' = [ordered]@{
                    message = 'Not found'
                    description = 'Shown when a resource does not exist.'
                    lifecycle = 'active'
                }
                'demo.paused' = [ordered]@{
                    message = 'Paused, waiting for resume.'
                    description = 'Banner while the operator has paused a cycle.'
                    lifecycle = 'active'
                }
            }
        })
    Write-FixtureJson -Path (Join-Path $root "globalization/terminology/$script:Tag.terms.json") -Value ([ordered]@{
            schema = 'yuruna.terminology/v1'
            locale = $script:Tag
            status = 'draft'
            sources = [ordered]@{ definitions = [ordered]@{ path = 'docs/definition.md'; sha256 = ('a' * 64) } }
            approvals = [ordered]@{}
            terms = @(
                [ordered]@{ sourceTerm = 'host'; meaning = 'The physical machine.'; sourceHeadings = @('Hosts')
                    xxXXDecision = [ordered]@{ status = 'pending' }
                }
                [ordered]@{ sourceTerm = 'pool'; meaning = 'The coordination scope.'; sourceHeadings = @()
                    xxXXDecision = [ordered]@{ status = 'pending' }
                }
            )
            retiredNameRulings = @(
                # A fictional pair on purpose: a real retired name in a fixture
                # trips the repository's own retired-name hook on every commit.
                [ordered]@{ retired = 'fixture widget'; current = 'fixture component'
                    translationPolicy = 'preserve-exact-english'
                }
            )
        })
    Write-FixtureJson -Path (Join-Path $root "globalization/terminology/$script:Tag.style-guide.json") -Value ([ordered]@{
            schema = 'yuruna.style-guide/v1'
            locale = $script:Tag
            status = 'draft'
            terminologySource = [ordered]@{ path = "globalization/terminology/$script:Tag.terms.json"; sha256 = ('b' * 64) }
            approvals = [ordered]@{}
            rules = @([ordered]@{ id = 'tone'; topic = 'Tone'; guidance = 'Be direct and concise.' })
        })

    foreach ($pair in @(
            @{ Repo = 'yuruna'; Tree = $root; Source = 'README.md'; Body = "# Framework`n`nThe framework readme.`n" }
            @{ Repo = 'yuruna-project'; Tree = $project; Source = 'README.md'; Body = "# Project`n`nThe project readme.`n" })) {
        Write-FixtureText -Path (Join-Path $pair.Tree $pair.Source) -Text $pair.Body
    }
    Write-FixtureJson -Path (Join-Path $root 'globalization/manifests/doc-translations.json') -Value ([ordered]@{
            schema = 'yuruna.doc-translations/v1'
            documents = @(
                [ordered]@{ repo = 'yuruna'; source = 'README.md'; locale = $script:Tag
                    translated = "docs/$script:Tag/README.md"; sourceHash = ('c' * 64); status = 'draft'
                }
                [ordered]@{ repo = 'yuruna-project'; source = 'README.md'; locale = $script:Tag
                    translated = "docs/$script:Tag/README.md"; sourceHash = ('d' * 64); status = 'draft'
                }
            )
        })
    Write-FixtureJson -Path (Join-Path $project 'globalization/project-locale-source-hashes.json') -Value ([ordered]@{
            schema = 'yuruna.project-locale-source-hashes/v1'
            hashAlgorithm = 'sha256-utf8-nfc-scalar-v1'
            entries = @(
                [ordered]@{ path = 'test/test.runner.yml'; fieldPath = '/testSets/name=smoke/displayName'
                    locale = $script:Tag; sourceHash = ('e' * 64); reviewStatus = 'unreviewed'
                }
            )
        })
    Write-FixtureText -Path (Join-Path $project 'test/test.runner.yml') `
        -Text "testSets:`n  - name: smoke`n    displayName: Quick smoke test`n"

    # A stand-in recorder: the real one refuses a bare name that reaches two
    # repositories, and what this proves is that the import never hands it one.
    $log = Join-Path $Base 'recorder-calls.txt'
    Write-FixtureText -Path (Join-Path $root 'tools/Test-DocTranslation.ps1') -Text @"
param([string]`$Locale, [string]`$Manifest, [string]`$ProjectRoot, [switch]`$AcceptReview,
    [string]`$Status, [string[]]`$Path, [switch]`$RequireReviewed, [switch]`$Quiet)
[IO.File]::AppendAllText('$log', (`$Path -join ',') + "``n")
exit 0
"@
    return @{
        Root = $root
        ProjectRoot = $project
        InputRoot = Join-Path $Base 'localization-input'
        OutputRoot = Join-Path $Base 'localization-output'
        RecorderLog = $log
    }
}

function Invoke-Exchange {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Argument)

    $all = [string[]]@('-NoProfile', '-File', $Script) + $Argument
    $global:LASTEXITCODE = 0
    $text = (& $script:PowerShell @all 2>&1 | Out-String)
    return @{ Code = $LASTEXITCODE; Output = $text }
}

function Invoke-FixtureExport {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Fixture)

    return Invoke-Exchange -Script $script:Export -Argument @('-Locale', $script:Tag,
        '-Root', $Fixture.Root, '-ProjectRoot', $Fixture.ProjectRoot,
        '-InputRoot', $Fixture.InputRoot, '-OutputRoot', $Fixture.OutputRoot, '-Quiet')
}

function Invoke-FixtureImport {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Fixture, [string[]]$Extra = @())

    return Invoke-Exchange -Script $script:Import -Argument (@('-Locale', $script:Tag,
            '-Root', $Fixture.Root, '-ProjectRoot', $Fixture.ProjectRoot,
            '-OutputRoot', $Fixture.OutputRoot, '-NoPublish', '-Quiet') + $Extra)
}

function Copy-RequestToOutput {
    <#
    .SYNOPSIS
        The request, returned filled in, the way the team is asked to return it.
    .OUTPUTS
        [string] the returned bundle root
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only inside a disposable fixture tree under TestDrive.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Fixture,
        [string]$Translator = 'Ana Costa',
        [string]$Reviewer = 'Bruno Lima',
        [string]$Date = ([datetime]::UtcNow.ToString('yyyy-MM-dd')),
        [string[]]$LeaveBlank = @()
    )

    $source = Join-Path $Fixture.InputRoot $script:Tag
    $destination = Join-Path $Fixture.OutputRoot $script:Tag
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force

    foreach ($relative in @('glossary/terms.json', 'glossary/rulings.json', 'glossary/style-guide.json',
            'project/display-map.json', 'messages/demo.json')) {
        $path = Join-Path $destination $relative
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $document = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))
        foreach ($entry in @($document.entries)) {
            if ($LeaveBlank -contains [string]$entry.id) { continue }
            $entry.translation = 'XX ' + ([string]$entry.english -split "`n")[0]
        }
        Write-FixtureJson -Path $path -Value $document
    }
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $destination 'documents') -Recurse -File)) {
        Write-FixtureText -Path $file.FullName -Text ("XX " + [IO.File]::ReadAllText($file.FullName))
    }
    $attestationPath = Join-Path $destination 'attestation.json'
    $attestation = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($attestationPath))
    $attestation.translator.approvedBy = $Translator
    $attestation.translator.approvedAt = $Date
    $attestation.independentReviewer.approvedBy = $Reviewer
    $attestation.independentReviewer.approvedAt = $Date
    Write-FixtureJson -Path $attestationPath -Value $attestation
    return $destination
}
}

Describe 'the request asks about every row exactly once' {

    It 'covers each kind and qualifies a document by its repository' {
        $fixture = New-ExchangeFixture -Base (Join-Path $TestDrive 'kinds')
        $run = Invoke-FixtureExport -Fixture $fixture
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output

        $request = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
                (Join-Path (Join-Path $fixture.InputRoot $script:Tag) 'request.json')))
        $kinds = @($request.rows | ForEach-Object { [string]$_.kind } | Sort-Object -Unique)
        foreach ($wanted in 'term', 'ruling', 'style-rule', 'message', 'document', 'project-scalar') {
            Assert-True ($kinds -contains $wanted) "the request asks about no $wanted"
        }
        $ids = @($request.rows | ForEach-Object { [string]$_.id })
        Assert-True ($ids -contains 'document:yuruna:README.md') 'the framework README is not asked about'
        Assert-True ($ids -contains 'document:yuruna-project:README.md') 'the project README is not asked about'
        Assert-Equal -Expected @($ids | Sort-Object -Unique).Count -Actual $ids.Count `
            'a row appears twice, so one answer would have to serve two questions'
    }

    It 'gives a document in both repositories two files under two repository folders' {
        # Not a refusal but a shape: there is nowhere in the tree for one answer
        # to stand for both, so the collision cannot be expressed.
        $fixture = New-ExchangeFixture -Base (Join-Path $TestDrive 'shape')
        $null = Invoke-FixtureExport -Fixture $fixture
        $bundle = Join-Path $fixture.InputRoot $script:Tag
        foreach ($repo in 'yuruna', 'yuruna-project') {
            Assert-True ([IO.File]::Exists((Join-Path $bundle "documents/$repo/README.md"))) `
                "the $repo README has no file of its own in the request"
        }
        $framework = [IO.File]::ReadAllText((Join-Path $bundle 'documents/yuruna/README.md'))
        $project = [IO.File]::ReadAllText((Join-Path $bundle 'documents/yuruna-project/README.md'))
        Assert-False ([string]::Equals($framework, $project, [StringComparison]::Ordinal)) `
            'both repository READMEs carry the same text, so the request lost one of them'
    }
}

Describe 'a second round asks only about what moved' {

    It 'carries every row forward when the English has not moved' {
        $fixture = New-ExchangeFixture -Base (Join-Path $TestDrive 'carried')
        $null = Invoke-FixtureExport -Fixture $fixture
        $null = Copy-RequestToOutput -Fixture $fixture

        $run = Invoke-FixtureExport -Fixture $fixture
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        $request = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
                (Join-Path (Join-Path $fixture.InputRoot $script:Tag) 'request.json')))
        $states = @($request.rows | ForEach-Object { [string]$_.state } | Sort-Object -Unique)
        Assert-Equal -Expected 1 -Actual $states.Count "a row is $($states -join '/') when nothing changed"
        Assert-Equal -Expected 'carried' -Actual $states[0] 'an unchanged round did not carry its rows forward'
    }

    It 'marks exactly the row whose English moved' {
        $fixture = New-ExchangeFixture -Base (Join-Path $TestDrive 'changed')
        $null = Invoke-FixtureExport -Fixture $fixture
        $null = Copy-RequestToOutput -Fixture $fixture

        $catalogPath = Join-Path $fixture.Root 'globalization/catalogs/en-US/demo.json'
        $catalog = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($catalogPath))
        $catalog.messages.'demo.not_found'.message = 'Not located'
        Write-FixtureJson -Path $catalogPath -Value $catalog

        $run = Invoke-FixtureExport -Fixture $fixture
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        $request = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
                (Join-Path (Join-Path $fixture.InputRoot $script:Tag) 'request.json')))
        $moved = @($request.rows | Where-Object { [string]$_.state -cne 'carried' } |
                ForEach-Object { [string]$_.id })
        Assert-Equal -Expected 1 -Actual $moved.Count "the round reopened $($moved -join ', ')"
        Assert-Equal -Expected 'message:demo:demo.not_found' -Actual $moved[0] 'the wrong row was reopened'

        $entries = (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
                    (Join-Path (Join-Path $fixture.InputRoot $script:Tag) 'messages/demo.json')))).entries
        $entry = $entries | Where-Object { [string]$_.id -ceq 'message:demo:demo.not_found' }
        Assert-Match 'Not located' ([string]$entry.english) 'the reopened row does not carry the current English'
        Assert-Match 'Not found' ([string]$entry.previousEnglish) 'the reopened row does not show what moved'
    }

    It 'reopens a row whose answer was left blank' {
        # A row that was sent and not answered is not settled, however many
        # rounds it has been in.
        $fixture = New-ExchangeFixture -Base (Join-Path $TestDrive 'blank')
        $null = Invoke-FixtureExport -Fixture $fixture
        $null = Copy-RequestToOutput -Fixture $fixture -LeaveBlank @('term:pool')

        $null = Invoke-FixtureExport -Fixture $fixture
        $request = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
                (Join-Path (Join-Path $fixture.InputRoot $script:Tag) 'request.json')))
        $open = @($request.rows | Where-Object { [string]$_.state -cne 'carried' } | ForEach-Object { [string]$_.id })
        Assert-Equal -Expected 1 -Actual $open.Count "the round reopened $($open -join ', ')"
        Assert-Equal -Expected 'term:pool' -Actual $open[0] 'the unanswered row was treated as settled'
    }
}

Describe 'an answer has to answer the question that was asked' {

    It 'refuses a bundle whose attestation answers a different request' {
        $fixture = New-ExchangeFixture -Base (Join-Path $TestDrive 'wrong-request')
        $null = Invoke-FixtureExport -Fixture $fixture
        $bundle = Copy-RequestToOutput -Fixture $fixture
        $attestationPath = Join-Path $bundle 'attestation.json'
        $attestation = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($attestationPath))
        $attestation.requestDigest.sha256 = 'f' * 64
        Write-FixtureJson -Path $attestationPath -Value $attestation

        $run = Invoke-FixtureImport -Fixture $fixture

        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
        Assert-Match 'answers request' $run.Output 'the refusal does not say the digests disagree'
        $terminology = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
                (Join-Path $fixture.Root "globalization/terminology/$script:Tag.terms.json")))
        Assert-Equal -Expected 'draft' -Actual ([string]$terminology.status) `
            'a refused bundle still changed the terminology source'
    }

    It 'refuses a bundle whose rows were edited after it was sent' {
        $fixture = New-ExchangeFixture -Base (Join-Path $TestDrive 'edited-request')
        $null = Invoke-FixtureExport -Fixture $fixture
        $bundle = Copy-RequestToOutput -Fixture $fixture
        $requestPath = Join-Path $bundle 'request.json'
        $request = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($requestPath))
        @($request.rows)[0].sourceSha256 = '0' * 64
        Write-FixtureJson -Path $requestPath -Value $request

        $run = Invoke-FixtureImport -Fixture $fixture

        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
        Assert-Match 'rows were edited' $run.Output 'the refusal does not say the request no longer hashes to its digest'
    }

    It 'refuses a bundle whose shape no longer matches its schema' {
        # The folder crosses an organization boundary and returns edited by a
        # tool nobody here chose. A renamed field should say so plainly rather
        # than surface as a null after half an artifact is already written.
        $fixture = New-ExchangeFixture -Base (Join-Path $TestDrive 'malformed')
        $null = Invoke-FixtureExport -Fixture $fixture
        $bundle = Copy-RequestToOutput -Fixture $fixture
        $attestationPath = Join-Path $bundle 'attestation.json'
        $attestation = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($attestationPath))
        $attestation.translator.PSObject.Properties.Remove('approvedBy')
        Write-FixtureJson -Path $attestationPath -Value $attestation

        $run = Invoke-FixtureImport -Fixture $fixture

        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
        Assert-Match 'attestation\.json does not match' $run.Output `
            'the refusal does not name the file whose shape is wrong'
    }

    It 'refuses two signatures from one person' {
        $fixture = New-ExchangeFixture -Base (Join-Path $TestDrive 'one-person')
        $null = Invoke-FixtureExport -Fixture $fixture
        $null = Copy-RequestToOutput -Fixture $fixture -Translator 'Ana Costa' -Reviewer 'ana costa'

        $run = Invoke-FixtureImport -Fixture $fixture

        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
        Assert-Match 'a second signature is a second person' $run.Output `
            'the refusal does not say why one name cannot sign twice'
    }

    It 'refuses an approval dated in the future' {
        $fixture = New-ExchangeFixture -Base (Join-Path $TestDrive 'future')
        $null = Invoke-FixtureExport -Fixture $fixture
        $null = Copy-RequestToOutput -Fixture $fixture -Date ([datetime]::UtcNow.AddDays(3).ToString('yyyy-MM-dd'))

        $run = Invoke-FixtureImport -Fixture $fixture

        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
        Assert-Match 'has not happened yet' $run.Output 'the refusal does not say the date is in the future'
    }

    It 'refuses a bundle whose English moved after it was sent' {
        $fixture = New-ExchangeFixture -Base (Join-Path $TestDrive 'drifted')
        $null = Invoke-FixtureExport -Fixture $fixture
        $null = Copy-RequestToOutput -Fixture $fixture
        $catalogPath = Join-Path $fixture.Root 'globalization/catalogs/en-US/demo.json'
        $catalog = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($catalogPath))
        $catalog.messages.'demo.paused'.message = 'Paused. Waiting for resume.'
        Write-FixtureJson -Path $catalogPath -Value $catalog

        $run = Invoke-FixtureImport -Fixture $fixture

        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
        Assert-Match 'message:demo:demo.paused' $run.Output 'the refusal does not name the row that moved'
    }
}

Describe 'placing a bundle records what it now holds' {

    It 'places every kind and binds the approval to the bytes that landed' {
        $fixture = New-ExchangeFixture -Base (Join-Path $TestDrive 'place')
        $null = Invoke-FixtureExport -Fixture $fixture
        $null = Copy-RequestToOutput -Fixture $fixture

        $run = Invoke-FixtureImport -Fixture $fixture
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output

        $termsPath = Join-Path $fixture.Root "globalization/terminology/$script:Tag.terms.json"
        $terminology = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($termsPath))
        Assert-Equal -Expected 'approved' -Actual ([string]$terminology.status) 'the terminology source was not approved'
        Assert-Equal -Expected 'translated' -Actual ([string]@($terminology.terms)[0].xxXXDecision.status) `
            'the term decision was not recorded'
        Assert-Equal -Expected 'Ana Costa' -Actual ([string]$terminology.approvals.translator.approvedBy) `
            'the translator was not recorded'
        Assert-Equal -Expected 'Bruno Lima' -Actual ([string]$terminology.approvals.independentReviewer.approvedBy) `
            'the independent reviewer was not recorded'

        # The digest has to describe the artifact on disk, not the answer that
        # was returned: those differ whenever anything went wrong in between.
        $recomputed = Get-ApprovableContentDigest -Artifact $terminology -Kind 'terminology'
        Assert-Equal -Expected $recomputed.sha256 `
            -Actual ([string]$terminology.approvals.translator.evidence.approvedContent.sha256) `
            'the recorded approval does not cover the terminology that was written'

        $style = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
                (Join-Path $fixture.Root "globalization/terminology/$script:Tag.style-guide.json")))
        $pinned = (Get-FileHash -LiteralPath $termsPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-Equal -Expected $pinned -Actual ([string]$style.terminologySource.sha256) `
            'the style guide does not pin the terminology it was approved against'
        $styleDigest = Get-ApprovableContentDigest -Artifact $style -Kind 'style-guide'
        Assert-Equal -Expected $styleDigest.sha256 `
            -Actual ([string]$style.approvals.translator.evidence.approvedContent.sha256) `
            'the style-guide approval went stale the moment it was granted'

        $catalog = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
                (Join-Path $fixture.Root "globalization/catalogs/$script:Tag/demo.json")))
        Assert-Equal -Expected $script:Tag -Actual ([string]$catalog.locale) 'the target catalog names the wrong locale'
        Assert-Match '^XX ' ([string]$catalog.messages.'demo.not_found'.message) 'the message was not placed'
        Assert-Equal -Expected 'Shown when a resource does not exist.' `
            -Actual ([string]$catalog.messages.'demo.not_found'.description) `
            'the description moved, and it is contract rather than anything a translator decides'

        foreach ($tree in $fixture.Root, $fixture.ProjectRoot) {
            $translated = Join-Path $tree "docs/$script:Tag/README.md"
            Assert-True ([IO.File]::Exists($translated)) "no translated README landed in $tree"
            Assert-Match '^XX ' ([IO.File]::ReadAllText($translated)) 'the translated README is not the returned text'
        }
        $framework = [IO.File]::ReadAllText((Join-Path $fixture.Root "docs/$script:Tag/README.md"))
        $project = [IO.File]::ReadAllText((Join-Path $fixture.ProjectRoot "docs/$script:Tag/README.md"))
        Assert-False ([string]::Equals($framework, $project, [StringComparison]::Ordinal)) `
            'one repository README was written over the other'

        $map = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
                (Join-Path $fixture.ProjectRoot 'globalization/project-locale-source-hashes.json')))
        Assert-Equal -Expected 'reviewed' -Actual ([string]@($map.entries)[0].reviewStatus) `
            'the project scalar review state did not advance'
    }

    It 'hands the recorder a repository-qualified path, never a bare name' {
        $fixture = New-ExchangeFixture -Base (Join-Path $TestDrive 'qualified')
        $null = Invoke-FixtureExport -Fixture $fixture
        $null = Copy-RequestToOutput -Fixture $fixture
        $null = Invoke-FixtureImport -Fixture $fixture

        $calls = @([IO.File]::ReadAllLines($fixture.RecorderLog) | Where-Object { $_ })
        Assert-Equal -Expected 2 -Actual $calls.Count 'the recorder was not called once per document'
        foreach ($call in $calls) {
            Assert-Match '^[A-Za-z0-9_.-]+:' $call "the recorder was handed '$call' unqualified"
        }
        Assert-True ($calls -contains 'yuruna:README.md') 'the framework README was not recorded'
        Assert-True ($calls -contains 'yuruna-project:README.md') 'the project README was not recorded'
    }

    It 'leaves a re-export with nothing to ask' {
        # The round trip closes: what was placed is what the next request reads,
        # so an unchanged tree asks nobody for anything.
        $fixture = New-ExchangeFixture -Base (Join-Path $TestDrive 'round-trip')
        $null = Invoke-FixtureExport -Fixture $fixture
        $null = Copy-RequestToOutput -Fixture $fixture
        $null = Invoke-FixtureImport -Fixture $fixture

        $run = Invoke-FixtureExport -Fixture $fixture
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        $request = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
                (Join-Path (Join-Path $fixture.InputRoot $script:Tag) 'request.json')))
        $open = @($request.rows | Where-Object { [string]$_.state -cne 'carried' } | ForEach-Object { [string]$_.id })
        Assert-Equal -Expected 0 -Actual $open.Count "the round trip reopened $($open -join ', ')"
    }
}

Describe 'publishing runs the tools that already own each check' {

    It 'declares a sequence that reaches every gate the exchange depends on' {
        $run = Invoke-Exchange -Script $script:Publish -Argument @('-ListOnly')
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        foreach ($tool in 'Invoke-CatalogCompile.ps1', 'Invoke-CatalogEmbed.ps1', 'Invoke-DomainInventory.ps1',
            'Test-Utf8Catalog.ps1', 'Test-Terminology.ps1', 'Test-DocTranslation.ps1',
            'Invoke-ProjectLocaleMap.ps1', 'Invoke-ReferenceFixture.ps1', 'Invoke-CrossRepoGate.ps1') {
            Assert-Match ([regex]::Escape($tool)) $run.Output "the publish sequence no longer runs $tool"
        }
    }

    It 'runs the tools rather than reimplementing their checks' {
        # A second implementation of catalog validation would diverge from the
        # authoritative one, and only one of the two would be gating anything.
        $text = [IO.File]::ReadAllText($script:Publish)
        foreach ($step in @((ConvertFrom-Json -InputObject '[]'))) { $null = $step }
        Assert-Match 'tools/Invoke-CatalogCompile\.ps1' $text 'the sequence no longer names the compiler'
        Assert-False ($text -match 'ConvertFrom-Json[^\n]*catalogs/') `
            'publishing reads a catalog itself instead of asking the tool that owns it'
    }

    It 'fails and names the step whose tool is missing' {
        $base = Join-Path $TestDrive 'missing-tool'
        $null = New-Item -ItemType Directory -Path (Join-Path $base 'tools') -Force
        $run = Invoke-Exchange -Script $script:Publish -Argument @('-Root', $base, '-ProjectRoot', $base, '-Quiet')
        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
        Assert-Match 'catalog-compile' $run.Output 'the failure does not name the step that could not run'
    }
}

Describe 'the interchange decision is recorded, not retyped' {

    It 'validates against its schema and says what replaces a provisional answer' {
        # An answer nobody with the authority to give it has given must carry
        # the route to the real one, or it quietly becomes the real one.
        $path = Join-Path $script:RepoRoot 'globalization/manifests/tooling-decision.json'
        Assert-True ([IO.File]::Exists($path)) 'the interchange decision is not recorded anywhere'
        $raw = [IO.File]::ReadAllText($path)
        $schema = Join-Path $script:RepoRoot 'globalization/schema/tooling-decision.schema.json'
        $valid = $false
        try { $valid = Test-Json -Json $raw -SchemaFile $schema -ErrorAction Stop } catch { $valid = $false }
        Assert-True $valid 'the recorded decision does not match its schema'

        $record = ConvertFrom-Json -InputObject $raw
        Assert-True (@('Required', 'NotRequired') -contains [string]$record.xliff.decision) `
            'the interchange decision is neither answer'
        if ([bool]$record.xliff.provisional) {
            Assert-True ([bool]([string]$record.xliff.replacedBy).Trim()) `
                'a provisional answer names nothing that would replace it'
            Assert-Match '9\.5' ([string]$record.xliff.replacedBy) `
                'a provisional answer does not point at the procedure that replaces it'
        }
    }

    It 'takes the export spelling from the record rather than a default here' {
        $fixture = New-ExchangeFixture -Base (Join-Path $TestDrive 'decision')
        Write-FixtureJson -Path (Join-Path $fixture.Root 'globalization/manifests/tooling-decision.json') `
            -Value ([ordered]@{
                schema = 'yuruna.tooling-decision/v1'
                note = 'fixture'
                xliff = [ordered]@{
                    decision = 'Required'; provisional = $true; decidedOn = '2026-09-10'
                    decidedBy = 'fixture'; rationale = 'fixture'; replacedBy = 'section 9.5'
                }
            })

        $run = Invoke-Exchange -Script $script:Export -Argument @('-Locale', $script:Tag,
            '-Root', $fixture.Root, '-ProjectRoot', $fixture.ProjectRoot,
            '-InputRoot', $fixture.InputRoot, '-OutputRoot', $fixture.OutputRoot)

        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        # The spelling it cannot write yet is announced, never substituted in
        # silence: silence would let the obligation sit until the round that
        # needed it.
        Assert-Match 'requires XLIFF \(provisional\)' $run.Output `
            'the export does not say it is writing against a record that asks for another spelling'
        $request = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
                (Join-Path (Join-Path $fixture.InputRoot $script:Tag) 'request.json')))
        Assert-Equal -Expected 'Json' -Actual ([string]$request.format) `
            'the request claims a spelling the tool does not write'
    }

    It 'writes the spelling an explicit argument asks for' {
        $fixture = New-ExchangeFixture -Base (Join-Path $TestDrive 'explicit-format')
        $run = Invoke-Exchange -Script $script:Export -Argument @('-Locale', $script:Tag,
            '-Root', $fixture.Root, '-ProjectRoot', $fixture.ProjectRoot,
            '-InputRoot', $fixture.InputRoot, '-OutputRoot', $fixture.OutputRoot,
            '-Format', 'Csv', '-Quiet')
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        $request = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
                (Join-Path (Join-Path $fixture.InputRoot $script:Tag) 'request.json')))
        Assert-Equal -Expected 'Csv' -Actual ([string]$request.format) `
            'an explicit format did not reach the request'
    }

    It 'lets release preparation answer from the record and mark it provisional' {
        $preparation = Join-Path $script:RepoRoot 'dev-only/Invoke-GlobalizedReleasePreparation.ps1'
        if (-not [IO.File]::Exists($preparation)) {
            Set-ItResult -Skipped -Because 'the private release-preparation entry point is not in this tree'
            return
        }
        $text = [IO.File]::ReadAllText($preparation)
        Assert-Match 'Get-RecordedToolingDecision' $text `
            'release preparation no longer reads the recorded decision'
        Assert-Match 'provisional' $text `
            'release preparation would present a provisional answer as the translator''s'
    }
}
