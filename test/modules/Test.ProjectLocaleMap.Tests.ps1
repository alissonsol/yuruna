<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42a09e37-5c84-4b16-9d72-38ef61c0a4d5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization project locale map compatibility pester
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
    Hold the project label contract to being additive across every pairing of
    framework and project version.
.DESCRIPTION
    The framework and the projects it runs are separate repositories on
    separate release cadences, and a lab is routinely running one of each from
    different weeks. A label contract that only worked when both were current
    would break the lab on the day either one moved.

    So the English scalar never changes meaning and never goes away. A project
    may add a sibling map keyed by locale, and only a framework that knows
    about the map reads it. That gives three pairings, all of which have to
    work, and all of which are asserted here:

      an old framework reading a new project -- it does not know the key, so it
      reads the scalar and behaves exactly as before;

      a new framework reading an old project -- there is no map, so the scalar
      is all there is;

      both new -- the map decides, and the scalar is still the fallback for a
      locale the project did not translate.

    Publishing validates canonical tags, bounds, scalar ownership and the
    source-hash sidecar. The live reader still never throws over an optional
    field: it ignores an invalid map and keeps the English scalar.

    Run: Invoke-Pester -Path test/modules/Test.ProjectLocaleMap.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.SequencePlanner.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:ProjectRoot = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna-project'
$script:Validator = Join-Path $script:RepoRoot 'tools/Invoke-ProjectLocaleMap.ps1'
$script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-project-map-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null

function Invoke-MapGate {
    param([Parameter(Mandatory)][string]$Root, [string[]]$Extra = @())
    $output = & pwsh -NoProfile -File $script:Validator -ProjectRoot $Root -Quiet @Extra 2>&1 | Out-String
    return @{ ExitCode = $LASTEXITCODE; Output = $output }
}

function New-ProjectMapSandbox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture creates files only beneath the suite-owned temporary directory.')]
    param([Parameter(Mandatory)][string]$Name)
    $root = Join-Path $script:Sandbox $Name
    New-Item -ItemType Directory -Path (Join-Path $root 'test') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'globalization') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:ProjectRoot 'test/test.runner.yml') -Destination (Join-Path $root 'test/test.runner.yml')
    Copy-Item -LiteralPath (Join-Path $script:ProjectRoot 'globalization/project-locale-source-hashes.json') `
        -Destination (Join-Path $root 'globalization/project-locale-source-hashes.json')
    return $root
}

function New-ProjectReaderSandbox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture creates files only beneath the suite-owned temporary directory.')]
    param([Parameter(Mandatory)][string]$Name)
    $root = Join-Path $script:Sandbox $Name
    $projectTest = Join-Path $root 'project/test'
    New-Item -ItemType Directory -Path $projectTest -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:ProjectRoot 'test/test.runner.yml') `
        -Destination (Join-Path $projectTest 'test.runner.yml')
    return $root
}

# An entry as the YAML reader hands it over.
function New-Entry {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds and returns a value; changes nothing. New- is the right verb for a factory.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([hashtable]$Values)
    $d = [ordered]@{}
    foreach ($k in $Values.Keys) { $d[$k] = $Values[$k] }
    return $d
}

AfterAll {
    if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}
}

Describe 'a project label survives every pairing of framework and project' {

    It 'reads the scalar when the project offers no map' {
        # New framework, old project. The overwhelmingly common case, and the
        # one that must cost nothing.
        $entry = New-Entry @{ displayName = 'Quick smoke test' }
        Assert-StringEqual -Expected 'Quick smoke test' `
            -Actual (Resolve-ProjectLabel -Entry $entry -ScalarKey 'displayName' -Locale 'pt-BR') `
            'a project with no map must read exactly as it always did'
    }

    It 'reads the map when both sides know about it' {
        $entry = New-Entry @{
            displayName = 'Quick smoke test'
            displayNameLocalized = [ordered]@{ 'pt-BR' = 'Teste rapido'; 'de-DE' = 'Schneller Test' }
        }
        Assert-StringEqual -Expected 'Teste rapido' `
            -Actual (Resolve-ProjectLabel -Entry $entry -ScalarKey 'displayName' -Locale 'pt-BR') `
            'the map did not decide for a locale it declares'
    }

    It 'carries the manifest-authoritative mirrored pseudo tag through the live reader' {
        $entry = New-Entry @{
            displayName = 'Quick smoke test'
            displayNameLocalized = [ordered]@{ 'qps-Plocm' = 'Mirrored fixture' }
        }
        $map = Get-ProjectLabelMap -Entry $entry -ScalarKey 'displayName'
        Assert-StringEqual -Expected 'Mirrored fixture' -Actual $map['qps-Plocm'] `
            'the registration projection dropped the manifest-declared pseudo tag'
        Assert-StringEqual -Expected 'Mirrored fixture' `
            -Actual (Resolve-ProjectLabel -Entry $entry -ScalarKey 'displayName' -Locale 'qps-Plocm') `
            'the live selector rejected the manifest-declared pseudo tag'
    }

    It 'preserves schema-valid surrounding whitespace consistently across readers' {
        $expected = '  Teste rapido  '
        $entry = New-Entry @{
            displayName = 'Quick smoke test'
            displayNameLocalized = [ordered]@{ 'pt-BR' = $expected }
        }
        $map = Get-ProjectLabelMap -Entry $entry -ScalarKey 'displayName'
        Assert-StringEqual -Expected $expected -Actual $map['pt-BR'] `
            'the PowerShell transport changed a value the schema, publisher, and Go reader preserve'
        Assert-StringEqual -Expected $expected `
            -Actual (Resolve-ProjectLabel -Entry $entry -ScalarKey 'displayName' -Locale 'pt-BR') `
            'the selected localized value changed between the transport and live reader'
    }

    It 'keeps the scalar for a locale the project did not translate' {
        # A partial map is the normal state of a translation in progress. The
        # untranslated label reads in English rather than disappearing.
        $entry = New-Entry @{
            displayName = 'Quick smoke test'
            displayNameLocalized = [ordered]@{ 'pt-BR' = 'Teste rapido' }
        }
        Assert-StringEqual -Expected 'Quick smoke test' `
            -Actual (Resolve-ProjectLabel -Entry $entry -ScalarKey 'displayName' -Locale 'de-DE') `
            'an untranslated label must fall back rather than render empty'
    }

    It 'keeps the scalar readable by a framework that knows no locale' {
        # An old framework passes no locale at all. It must get the scalar,
        # which is the same value it read before the map existed.
        $entry = New-Entry @{
            displayName = 'Quick smoke test'
            displayNameLocalized = [ordered]@{ 'pt-BR' = 'Teste rapido' }
        }
        Assert-StringEqual -Expected 'Quick smoke test' `
            -Actual (Resolve-ProjectLabel -Entry $entry -ScalarKey 'displayName' -Locale '') `
            'the scalar is what an older framework reads, and it must be untouched'
    }

    It 'uses only the exact canonical resolved tag handed down by LocaleContext' {
        $entry = New-Entry @{
            displayName = 'Quick smoke test'
            displayNameLocalized = [ordered]@{ 'PT-br' = 'Teste rapido' }
        }
        Assert-StringEqual -Expected 'Quick smoke test' `
            -Actual (Resolve-ProjectLabel -Entry $entry -ScalarKey 'displayName' -Locale 'pt-BR') `
            'the reader repaired a project tag and became a second locale matcher'
    }

    It 'fails the whole optional map closed when it contains en-US' {
        # The English label lives in the scalar, and only the scalar. A map
        # entry for the default locale would create two places to edit one
        # string -- and an older framework reads the scalar, so the two would
        # drift with nothing to say which was current.
        $entry = New-Entry @{
            displayName = 'Quick smoke test'
            displayNameLocalized = [ordered]@{ 'en-US' = 'Something else entirely'; 'pt-BR' = 'Teste rapido' }
        }
        Assert-StringEqual -Expected 'Quick smoke test' `
            -Actual (Resolve-ProjectLabel -Entry $entry -ScalarKey 'displayName' -Locale 'en-US') `
            'an en-US map entry overrode the scalar, so the English label now has two owners'
        Assert-StringEqual -Expected 'Quick smoke test' `
            -Actual (Resolve-ProjectLabel -Entry $entry -ScalarKey 'displayName' -Locale 'pt-BR') `
            'an invalid en-US sibling left part of the untrusted map active'
    }

    It 'counts normalized Unicode scalars at the live map boundary' {
        $emoji = [char]::ConvertFromUtf32(0x1F642)
        $combining = [char]0x0301
        $astralBoundary = $emoji * 160
        $decomposedBoundary = ("e$combining") * 160
        $entry = New-Entry @{
            displayName = 'Quick smoke test'
            displayNameLocalized = [ordered]@{
                'pt-BR' = $astralBoundary
                'de-DE' = $decomposedBoundary
            }
        }
        $map = Get-ProjectLabelMap -Entry $entry -ScalarKey 'displayName'
        Assert-StringEqual -Expected $astralBoundary -Actual $map['pt-BR'] `
            'a valid 160-scalar astral translation was counted as UTF-16 code units'
        Assert-StringEqual -Expected ($decomposedBoundary.Normalize([Text.NormalizationForm]::FormC)) `
            -Actual $map['de-DE'] 'the normalized 160-scalar translation was rejected before NFC'

        $entry.displayNameLocalized['pt-BR'] = $emoji * 161
        Assert-Equal -Expected 0 -Actual (Get-ProjectLabelMap -Entry $entry -ScalarKey 'displayName').Count `
            'a translation over the 160-scalar display bound remained active'
    }

    It 'carries no en-US entry in any shipped project' {
        # The rule is enforced at read time; this is the other half, so a
        # project that writes one is told rather than silently ignored.
        $repoRoot = Get-YurunaTestRepoRoot -SuiteDirectory (Split-Path -Parent $PSCommandPath)
        $projectRoot = Join-Path (Split-Path -Parent $repoRoot) 'yuruna-project'
        if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) {
            Set-ItResult -Skipped -Because 'the project checkout this reads is not beside this one'
            return
        }
        $findings = @()
        foreach ($file in (Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Include '*.yml', '*.yaml' -ErrorAction SilentlyContinue)) {
            $text = [IO.File]::ReadAllText($file.FullName)
            if ($text -notmatch 'Localized:') { continue }
            foreach ($m in [regex]::Matches($text, '(?ms)^\s*\w+Localized:\s*\n((?:\s+\S.*\n)+)')) {
                if ($m.Groups[1].Value -match '(?m)^\s*[''"]?en-US[''"]?\s*:') {
                    $rel = [IO.Path]::GetRelativePath($projectRoot, $file.FullName)
                    $findings += "$rel declares an en-US entry in a localized map; the English label belongs in the scalar"
                }
            }
        }
        Assert-NoFinding $findings 'a project has two places to edit one English label'
    }

    It 'never fails a cycle over a malformed optional field' {
        # A project is somebody else's repository. A label that cannot be read
        # is a label that is not used, not a reason to stop a test run.
        $findings = @()
        $cases = @(
            @{ Name = 'the map is a string';    Entry = New-Entry @{ displayName = 'Scalar'; displayNameLocalized = 'not a map' } }
            @{ Name = 'the map is a list';      Entry = New-Entry @{ displayName = 'Scalar'; displayNameLocalized = @('a', 'b') } }
            @{ Name = 'the map is empty';       Entry = New-Entry @{ displayName = 'Scalar'; displayNameLocalized = [ordered]@{} } }
            @{ Name = 'the entry has no label'; Entry = New-Entry @{ sequences = @('x') } }
        )
        foreach ($case in $cases) {
            try {
                $got = Resolve-ProjectLabel -Entry $case.Entry -ScalarKey 'displayName' -Locale 'pt-BR'
                if ($case.Name -ne 'the entry has no label' -and $got -ne 'Scalar') {
                    $findings += "$($case.Name): got '$got', expected the scalar"
                }
            } catch {
                $findings += "$($case.Name): threw -- $($_.Exception.Message)"
            }
        }
        # And a value that is not an entry at all.
        try {
            $null = Resolve-ProjectLabel -Entry $null -ScalarKey 'displayName' -Locale 'pt-BR'
            $null = Resolve-ProjectLabel -Entry 'a string' -ScalarKey 'displayName' -Locale 'pt-BR'
        } catch {
            $findings += "a non-entry threw -- $($_.Exception.Message)"
        }
        Assert-NoFinding $findings 'a malformed optional label can stop a cycle'
    }

    It 'is additive in the shipped reader, not only in the helper' {
        # The planner is what the pool board reads, so the contract has to hold
        # where the label actually comes from.
        $text = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSCommandPath) 'Test.SequencePlanner.psm1'))
        Assert-True ($text -match "displayName = Resolve-ProjectLabel") `
            'the planner still reads the scalar directly, so a project map would never be seen'
        Assert-True ($text -match "description = Resolve-ProjectLabel") `
            'the description is not resolved the same way as the name'
        Assert-True ($text -match '\[string\]\$Locale = ') `
            'the planner takes no locale, so it could not choose a label even given one'
    }

    It 'carries the complete maps through discovery while leaving the scalar unresolved' {
        $root = New-ProjectReaderSandbox -Name 'reader-carry'
        $sets = Get-ProjectTestSet -RepoRoot $root
        $smoke = @($sets | Where-Object { $_['name'] -eq 'smoke' })[0]
        Assert-StringEqual -Expected 'Quick smoke test' -Actual $smoke.displayName `
            'a background runner resolved the label using its own process locale'
        Assert-StringEqual -Expected 'Teste rapido' -Actual $smoke.displayNameLocalized['pt-BR'] `
            'discovery dropped the display-name map before the HTTP boundary'
        Assert-StringEqual -Expected 'Apenas o site -- o sinal mais rapido de que o laboratorio esta saudavel.' `
            -Actual $smoke.descriptionLocalized['pt-BR'] `
            'discovery dropped the description map before the HTTP boundary'
    }
}

Describe 'the project publisher validates maps and source hashes' {

    It 'makes canonical locale-key spelling part of the JSON Schema contract' {
        $schemaPath = Join-Path $script:RepoRoot 'globalization/schema/project-locale-map.schema.json'
        $record = [ordered]@{
            schema = 'yuruna.project-locale-map/v1'
            path = 'test/test.runner.yml'
            fieldPath = '/testSets/name=smoke/displayName'
            scalarField = 'displayName'
            scalar = 'Quick smoke test'
            localized = [ordered]@{ 'pt-BR' = 'Teste rapido' }
        }
        $json = $record | ConvertTo-Json -Depth 10 -Compress
        Assert-True (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction Stop) `
            'the canonical project-map control record does not satisfy its schema'

        # qps-Plocm is the manifest-declared spelling of Yuruna's mirrored
        # test-only locale; the manifest key is its canonical authority even
        # though a generic five-letter variant would otherwise lowercase.
        $record.localized = [ordered]@{ 'qps-Plocm' = 'Mirrored fixture' }
        Assert-True (Test-Json -Json ($record | ConvertTo-Json -Depth 10 -Compress) `
                -SchemaFile $schemaPath -ErrorAction Stop) `
            'the manifest-declared mirrored pseudo tag was rejected by the shared schema'

        $overlongTag = 'abc-abcdefgh-abcdefgh-abcdefgh-abcde'
        foreach ($tag in @('PT-br', 'pt-br', 'EN-us', 'en-US', $overlongTag)) {
            $record.localized = [ordered]@{ $tag = 'Mutation' }
            Assert-False (Test-Json -Json ($record | ConvertTo-Json -Depth 10 -Compress) `
                    -SchemaFile $schemaPath -ErrorAction SilentlyContinue) `
                "project-locale-map.schema.json accepted noncanonical/forbidden key '$tag'"
        }
    }

    It 'caps localized-map keys in both shipped transport schemas' {
        $overlongTag = 'abc-abcdefgh-abcdefgh-abcdefgh-abcde'
        Assert-Equal -Expected 36 -Actual $overlongTag.Length `
            'the mutation no longer isolates the 35-character schema bound'
        foreach ($relative in @(
                'test/schemas/host.registration.schema.yml'
                'test/schemas/pool-test-sets.schema.yml'
            )) {
            $schema = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText(
                    (Join-Path $script:RepoRoot $relative))) -Ordered
            foreach ($definition in @('projectLocaleDisplayNameMap', 'projectLocaleDescriptionMap')) {
                $fragment = $schema['$defs'][$definition] | ConvertTo-Json -Depth 20 -Compress
                $valid = [ordered]@{ 'pt-BR' = 'Readable text' } | ConvertTo-Json -Compress
                $tooLong = [ordered]@{ $overlongTag = 'Readable text' } | ConvertTo-Json -Compress
                Assert-True (Test-Json -Json $valid -Schema $fragment -ErrorAction Stop) `
                    "$relative $definition rejected a canonical key"
                $mirroredPseudo = [ordered]@{ 'qps-Plocm' = 'Mirrored fixture' } | ConvertTo-Json -Compress
                Assert-True (Test-Json -Json $mirroredPseudo -Schema $fragment -ErrorAction Stop) `
                    "$relative $definition rejected the manifest-declared mirrored pseudo tag"
                Assert-False (Test-Json -Json $tooLong -Schema $fragment -ErrorAction SilentlyContinue) `
                    "$relative $definition accepted a locale key beyond 35 characters"
                $wrongCase = [ordered]@{ 'pt-br' = 'Readable text' } | ConvertTo-Json -Compress
                Assert-False (Test-Json -Json $wrongCase -Schema $fragment -ErrorAction SilentlyContinue) `
                    "$relative $definition accepted a lower-case region as canonical"
            }
        }
    }

    It 'accepts the shipped project maps as schema-valid and source-current' {
        if (-not (Test-Path -LiteralPath $script:ProjectRoot -PathType Container)) {
            Set-ItResult -Skipped -Because 'the project checkout is not beside this one'
            return
        }
        $run = Invoke-MapGate -Root $script:ProjectRoot
        Assert-Equal -Expected 0 -Actual $run.ExitCode "the shipped project map contract is not publishable: $($run.Output)"
        Assert-Match -Pattern '2 map\(s\), 2 translation\(s\), 0 finding' -Actual $run.Output 'the expected official fixture was not inventoried'
    }

    It 'applies map bounds to NFC Unicode scalars rather than UTF-16 code units' {
        $emoji = [char]::ConvertFromUtf32(0x1F642)
        $combining = [char]0x0301
        foreach ($case in @(
                @{ Name = 'astral-boundary'; Value = $emoji * 160; ExitCode = 0 }
                @{ Name = 'decomposed-normalizes-to-boundary'; Value = ("e$combining") * 160; ExitCode = 0 }
                @{ Name = 'astral-over-bound'; Value = $emoji * 161; ExitCode = 1 }
            )) {
            $root = New-ProjectMapSandbox -Name $case.Name
            $path = Join-Path $root 'test/test.runner.yml'
            $text = [IO.File]::ReadAllText($path).Replace(
                '      pt-BR: Teste rapido', '      pt-BR: ' + $case.Value)
            [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
            $run = Invoke-MapGate -Root $root
            Assert-Equal -Expected $case.ExitCode -Actual $run.ExitCode `
                "$($case.Name) produced the wrong publisher result: $($run.Output)"
            if ($case.ExitCode -ne 0) {
                Assert-Match -Pattern '160 Unicode scalars' -Actual $run.Output `
                    'the over-bound translation was not rejected by the shared scalar rule'
            }
        }
    }

    It 'derives a deterministic ephemeral pseudo fixture from the current English scalar' {
        $root = New-ProjectMapSandbox -Name 'pseudo-fixture'
        $firstPath = Join-Path $script:Sandbox 'pseudo-first.json'
        $secondPath = Join-Path $script:Sandbox 'pseudo-second.json'
        $first = Invoke-MapGate -Root $root -Extra @('-PseudoFixturePath', $firstPath)
        Assert-Equal -Expected 0 -Actual $first.ExitCode "pseudo fixture generation failed: $($first.Output)"

        $fixture = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($firstPath)) -AsHashtable
        Assert-StringEqual -Expected 'yuruna.project-locale-pseudo-fixture/v1' -Actual $fixture.schema `
            'the ephemeral project fixture has no versioned contract'
        Assert-StringEqual -Expected 'qps-Ploc|qps-Plocm' -Actual (@($fixture.locales) -join '|') `
            'the project fixture did not declare both UI stress locales in stable order'
        $display = @($fixture.entries | Where-Object fieldPath -EQ '/testSets/name=smoke/displayName')[0]
        Assert-StringEqual -Expected 'Quick smoke test' -Actual $display.scalar `
            'the fixture did not retain the authoritative English scalar'
        $sidecar = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
            (Join-Path $root 'globalization/project-locale-source-hashes.json'))) -AsHashtable
        $expectedSource = @($sidecar.entries |
            Where-Object fieldPath -EQ '/testSets/name=smoke/displayName')[0].sourceHash
        Assert-StringEqual -Expected $expectedSource -Actual $display.sourceHash `
            'the pseudo map is not tied to the current English scalar bytes'
        Assert-True ($display.localized.'qps-Ploc'.StartsWith('[')) `
            'the expanded pseudo value was not derived'
        Assert-True ($display.localized.'qps-Plocm'.Contains([char]0x202E)) `
            'the mirrored pseudo value has no RTL stress marker'
        Assert-False ($display.localized.'qps-Ploc' -eq 'Teste rapido') `
            'the pseudo fixture copied the unreviewed translation'

        # Translation wording has no role in a pseudo run. Changing it while
        # retaining the same English source must leave the fixture byte-identical.
        $yamlPath = Join-Path $root 'test/test.runner.yml'
        $yaml = [IO.File]::ReadAllText($yamlPath).Replace('Teste rapido', 'Traducao nao usada')
        [IO.File]::WriteAllText($yamlPath, $yaml, [Text.UTF8Encoding]::new($false))
        $second = Invoke-MapGate -Root $root -Extra @('-PseudoFixturePath', $secondPath)
        Assert-Equal -Expected 0 -Actual $second.ExitCode $second.Output
        Assert-StringEqual -Expected ([Convert]::ToBase64String([IO.File]::ReadAllBytes($firstPath))) `
            -Actual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($secondPath))) `
            -Because 'an unreviewed real translation influenced the pseudo project fixture'
    }

    It 'does not bless a translation during an ordinary validation run' {
        $root = New-ProjectMapSandbox -Name 'read-only'
        $sidecar = Join-Path $root 'globalization/project-locale-source-hashes.json'
        $before = [IO.File]::ReadAllBytes($sidecar)
        $run = Invoke-MapGate -Root $root
        $after = [IO.File]::ReadAllBytes($sidecar)
        Assert-Equal -Expected 0 -Actual $run.ExitCode $run.Output
        Assert-StringEqual -Expected ([Convert]::ToBase64String($before)) -Actual ([Convert]::ToBase64String($after)) -Because 'the check advanced a review hash without reviewer acceptance'
    }

    It 'stales only the translated field whose English scalar changed' {
        $root = New-ProjectMapSandbox -Name 'stale-one'
        $path = Join-Path $root 'test/test.runner.yml'
        $text = [IO.File]::ReadAllText($path).Replace(
            '    displayName: Quick smoke test',
            '    displayName: Quick smoke test now')
        [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
        $run = Invoke-MapGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'a reworded scalar left its translation current'
        Assert-Match -Pattern 'name=smoke/displayName\|pt-BR is stale' -Actual $run.Output 'the changed field was not identified'
        Assert-False ($run.Output -match 'name=smoke/description\|pt-BR is stale') 'changing displayName staled the independent description translation'
    }

    It 'discovers quoted localized keys and still enforces their source hash' {
        $root = New-ProjectMapSandbox -Name 'quoted-localized-key'
        $path = Join-Path $root 'test/test.runner.yml'
        $text = [IO.File]::ReadAllText($path)
        $text = $text.Replace('displayNameLocalized:', '"displayNameLocalized":')
        $text = $text.Replace('descriptionLocalized:', '"descriptionLocalized":')
        $text = $text.Replace('    displayName: Quick smoke test', '    displayName: Quick smoke test now')
        [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))

        $run = Invoke-MapGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'quoted map keys bypassed project-map discovery'
        Assert-Match -Pattern 'name=smoke/displayName\|pt-BR is stale' -Actual $run.Output `
            'the quoted map was not held to its sidecar source hash'
    }

    It 'discovers flow-style locale maps and still enforces their source hash' {
        $root = New-ProjectMapSandbox -Name 'flow-localized-key'
        $path = Join-Path $root 'test/test.runner.yml'
        $flow = @'
testSets: [{name: smoke, displayName: Quick smoke test now, displayNameLocalized: {pt-BR: Teste rapido}}]
'@
        [IO.File]::WriteAllText($path, $flow, [Text.UTF8Encoding]::new($false))

        $run = Invoke-MapGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'a flow-style map bypassed project-map discovery'
        Assert-Match -Pattern 'name=smoke/displayName\|pt-BR is stale' -Actual $run.Output `
            'the flow-style map was not held to its sidecar source hash'
    }

    It 'rejects noncanonical tags and a map without its scalar' {
        $root = New-ProjectMapSandbox -Name 'bad-map'
        $path = Join-Path $root 'test/test.runner.yml'
        $text = [IO.File]::ReadAllText($path)
        $text = $text.Replace('      pt-BR: Teste rapido', '      PT-br: Teste rapido')
        $text = $text.Replace('    description: Website only -- the fastest signal that the lab is healthy.', '    oldDescription: Website only -- the fastest signal that the lab is healthy.')
        [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
        $run = Invoke-MapGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'invalid official metadata was publishable'
        Assert-Match -Pattern "locale 'PT-br' is not canonical; write 'pt-BR'" -Actual $run.Output 'the tag rule is not explicit'
        Assert-Match -Pattern 'has descriptionLocalized without its required English scalar' -Actual $run.Output 'the scalar ownership rule is not explicit'
    }

    It 'requires one sidecar row for every path, field and locale' {
        $root = New-ProjectMapSandbox -Name 'no-sidecar'
        Remove-Item -LiteralPath (Join-Path $root 'globalization/project-locale-source-hashes.json') -Force
        $run = Invoke-MapGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'maps with no source provenance were publishable'
        Assert-Match -Pattern 'required source-hash sidecar is missing' -Actual $run.Output 'the missing authority is not named'
    }

    It 'validates an untracked nonignored YAML candidate before commit' {
        $root = New-ProjectMapSandbox -Name 'untracked-candidate'
        & git -C $root init --quiet
        & git -C $root add -- test/test.runner.yml globalization/project-locale-source-hashes.json
        $candidate = @'
testSets:
  - name: pending
    displayName: Pending test
    displayNameLocalized:
      pt-BR: Teste pendente
'@
        [IO.File]::WriteAllText((Join-Path $root 'test/pending.yml'), $candidate,
            [Text.UTF8Encoding]::new($false))

        $run = Invoke-MapGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'an untracked project map bypassed the pre-commit gate'
        Assert-Match -Pattern 'source-hash sidecar has no row for test/pending.yml\|/testSets/name=pending/displayName\|pt-BR' `
            -Actual $run.Output 'the untracked translation was not inventoried by path, field and locale'
    }

    It 'advances exactly one row only through explicit reviewer acceptance' {
        $root = New-ProjectMapSandbox -Name 'review-accept'
        $extra = @(
            '-AcceptReviewedTranslation',
            '-ProjectPath', 'test/test.runner.yml',
            '-FieldPath', '/testSets/name=smoke/displayName',
            '-Locale', 'pt-BR',
            '-Reviewer', 'Independent Reviewer',
            '-ReviewedAt', '2026-09-03'
        )
        $run = Invoke-MapGate -Root $root -Extra $extra
        Assert-Equal -Expected 0 -Actual $run.ExitCode "explicit acceptance failed: $($run.Output)"
        $sidecar = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
            (Join-Path $root 'globalization/project-locale-source-hashes.json')))
        $name = @($sidecar.entries | Where-Object fieldPath -EQ '/testSets/name=smoke/displayName')[0]
        $description = @($sidecar.entries | Where-Object fieldPath -EQ '/testSets/name=smoke/description')[0]
        Assert-StringEqual -Expected 'reviewed' -Actual $name.reviewStatus 'the selected row was not accepted'
        Assert-StringEqual -Expected 'Independent Reviewer' -Actual $name.reviewer 'review provenance was lost'
        Assert-StringEqual -Expected 'unreviewed' -Actual $description.reviewStatus 'an unrelated row was promoted'
    }

    It 'rejects an invalid acceptance candidate without changing the sidecar bytes' {
        $root = New-ProjectMapSandbox -Name 'invalid-review-candidate'
        $sidecarPath = Join-Path $root 'globalization/project-locale-source-hashes.json'
        $before = [IO.File]::ReadAllBytes($sidecarPath)
        $extra = @(
            '-AcceptReviewedTranslation',
            '-ProjectPath', 'test/test.runner.yml',
            '-FieldPath', '/testSets/name=smoke/displayName',
            '-Locale', 'pt-BR',
            '-Reviewer', ('R' * 201),
            '-ReviewedAt', '2026-09-03'
        )
        $run = Invoke-MapGate -Root $root -Extra $extra
        $after = [IO.File]::ReadAllBytes($sidecarPath)
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'a reviewer beyond the schema bound was written'
        Assert-Match -Pattern 'candidate source-hash sidecar does not satisfy its schema' -Actual $run.Output `
            'candidate validation did not identify the rejected write'
        Assert-StringEqual -Expected ([Convert]::ToBase64String($before)) `
            -Actual ([Convert]::ToBase64String($after)) `
            -Because 'an invalid candidate changed the persisted sidecar before schema validation'
    }

    It 'does not write an accepted target while an unrelated sidecar row is stale' {
        $root = New-ProjectMapSandbox -Name 'accept-with-stale-sibling'
        $sidecarPath = Join-Path $root 'globalization/project-locale-source-hashes.json'
        $sidecar = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($sidecarPath)) -AsHashtable
        $description = @($sidecar.entries |
            Where-Object fieldPath -EQ '/testSets/name=smoke/description')[0]
        $description.sourceHash = '0' * 64
        $candidate = ($sidecar | ConvertTo-Json -Depth 10).Replace("`r`n", "`n").TrimEnd() + "`n"
        [IO.File]::WriteAllText($sidecarPath, $candidate, [Text.UTF8Encoding]::new($false))
        $before = [IO.File]::ReadAllBytes($sidecarPath)

        $run = Invoke-MapGate -Root $root -Extra @(
            '-AcceptReviewedTranslation',
            '-ProjectPath', 'test/test.runner.yml',
            '-FieldPath', '/testSets/name=smoke/displayName',
            '-Locale', 'pt-BR',
            '-Reviewer', 'Independent Reviewer',
            '-ReviewedAt', '2026-09-03'
        )
        $after = [IO.File]::ReadAllBytes($sidecarPath)
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'acceptance ignored an unrelated stale authority row'
        Assert-Match -Pattern 'description\|pt-BR is stale' -Actual $run.Output `
            'the complete candidate sidecar was not validated before write'
        Assert-StringEqual -Expected ([Convert]::ToBase64String($before)) `
            -Actual ([Convert]::ToBase64String($after)) `
            -Because 'a failed whole-sidecar acceptance mutated the authority bytes'
    }
}
Describe 'production project and operator localization contracts' {
    BeforeAll {
        Import-Module (Join-Path $here 'Test.LocalizationExchange.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $here 'Test.Catalog.psm1') -DisableNameChecking
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1') -DisableNameChecking
    }
    It 'globalization acceptance: all reachable project display scalars' {
        $enrolled = Get-LocalizationProjectSource -ProjectRoot $script:ProjectRoot -Locale 'pt-BR'
        $rows = @(Get-LocalizationRow -Root $script:RepoRoot -ProjectRoot $script:ProjectRoot -Locale 'pt-BR' | Where-Object kind -EQ 'project-scalar')
        $rows.Count | Should -Be $enrolled.entries.Count
        $rows.Count | Should -BeGreaterThan 100
        foreach ($entry in $enrolled.entries) {
            $row = @($rows | Where-Object { $_.context -ceq $entry.path -and $_.pointer -ceq $entry.fieldPath })
            $row.Count | Should -Be 1 -Because ($entry.path + '#' + $entry.fieldPath)
            $row[0].english | Should -Not -BeNullOrEmpty
            $row[0].sourceSha256 | Should -Match '^[a-f0-9]{64}$'
            $field = ($entry.fieldPath -split '/')[-1]
            $object = @{ $field = $row[0].english; ($field + 'Localized') = @{ 'qps-Ploc' = ('FIXTURE ' + $row[0].english) } }
            (Resolve-ProjectLabel -Entry $object -ScalarKey $field -Locale 'en-US') | Should -BeExactly $row[0].english
            (Resolve-ProjectLabel -Entry $object -ScalarKey $field -Locale 'qps-Ploc') | Should -BeExactly ('FIXTURE ' + $row[0].english)
        }
        @($rows | Where-Object context -Like 'example/*').Count | Should -BeGreaterThan 0
        @($rows | Where-Object pointer -Match '/0/description$').Count | Should -BeGreaterThan 0
    }
    It 'globalization acceptance: CLI host guest and automation catalog coverage' {
        $plannerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $here 'Test.SequenceResolve.psm1'), [ref]$null, [ref]$null)
        $plannerFactory = $plannerAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-SequencePlannerException' }, $true)
        $plannerFactory | Should -Not -BeNullOrEmpty
        $plannerCalls = @($plannerFactory.Body.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Format-YurunaOperatorMessage' }, $true))
        $plannerCalls.Count | Should -Be 1
        $plannerCalls[0].Extent.Text | Should -Match '\-Key \$Key\b'
        $plannerCalls[0].Extent.Text | Should -Match '\-Arguments \$Arguments\b'
        $manifest = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'globalization/manifests/operator-catalog-sources.json') -Raw | ConvertFrom-Json
        $manifest.sources.Count | Should -BeGreaterThan 4000
        $sources = @{}
        $catalogs = @{}
        foreach ($record in $manifest.sources) {
            if (-not $sources.ContainsKey($record.path)) {
                $errors = $null
                $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot $record.path), [ref]$null, [ref]$errors)
                @($errors).Count | Should -Be 0 -Because $record.path
                $sources[$record.path] = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('Format-YurunaOperatorMessage', 'New-SequencePlannerException') }, $true) | ForEach-Object { $_.Extent.Text }) -join "`n"
            }
            $sources[$record.path] | Should -Match ([regex]::Escape("-Key '$($record.key)'")) -Because $record.path
            $domain = ($record.key -split '\.')[0]
            if (-not $catalogs.ContainsKey($domain)) { $catalogs[$domain] = Get-Content -LiteralPath (Join-Path $script:RepoRoot "globalization/catalogs/en-US/$domain.json") -Raw | ConvertFrom-Json -AsHashtable }
            $message = $catalogs[$domain].messages[$record.key]
            $message | Should -Not -BeNullOrEmpty
            $variants = if ($message.ContainsKey('plural')) { @('one', 'other') }
                        elseif ($message.ContainsKey('select')) { @($message.select.variants.Keys) }
                        else { @('message') }
            foreach ($variant in $variants) {
                $arguments = @{}
                foreach ($name in $record.arguments) {
                    $message.placeholders.ContainsKey($name) | Should -BeTrue
                    $arguments[$name] = switch ($message.placeholders[$name].type) {
                        'integer' { 2 }
                        'token' { 'future_token' }
                        default { "`u{5916}`u{90e8} <detail> & caf`u{e9}" }
                    }
                }
                $expected = if ($message.ContainsKey('plural')) {
                    $arguments[$message.plural.selector] = if ($variant -eq 'one') { 1 } else { 2 }
                    $message.plural.variants[$variant]
                } elseif ($message.ContainsKey('select')) {
                    $arguments[$message.select.selector] = if ($variant -eq 'other') { 'future_token' } else { $variant }
                    $message.select.variants[$variant]
                } else { $message.message }
                foreach ($name in $arguments.Keys) { $expected = $expected.Replace('{' + $name + '}', [string]$arguments[$name]) }
                (Format-CatalogMessage -Key $record.key -Arguments $arguments -Locale 'en-US') | Should -BeExactly $expected
            }
        }
        foreach ($scope in @('automation/', 'host/', 'test/')) { @($manifest.sources | Where-Object path -Like "$scope*").Count | Should -BeGreaterThan 0 }
        @($manifest.sources | Where-Object path -Match 'guest\.').Count | Should -BeGreaterThan 0
    }
    It 'globalization acceptance: sequence messages carry stable codes and labels' {
        $file = Join-Path $here 'Test.SequenceEngine.psm1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
        $assignment = $ast.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$writeCurrentAction' }, $true)
        $writer = [scriptblock]::Create($assignment.Right.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
        $currentActionFile = Join-Path $TestDrive 'current-action.json'
        $GuestKey = 'guest.fixture'; $VMName = "vm.`u{5916}`u{90e8}"
        Import-Module (Join-Path $here 'Test.StateFile.psm1') -DisableNameChecking
        $states = @(
            @{ code = 'sequence_paused_waiting_resume'; key = 'runner.sequence_paused'; arguments = @{ label = '[1/2]' }; label = '[1/2]' }
            @{ code = 'sequence_restart_requested'; key = 'runner.sequence_restart'; arguments = @{ label = '[1/2]' }; label = '[1/2]' }
            @{ code = 'sequence_step_active'; key = 'runner.sequence_step'; arguments = @{ index = 1; total = 2; action = 'waitForText'; description = "`u{5916}`u{90e8} <detail>" }; label = "`u{5916}`u{90e8} <detail>" }
            @{ code = 'sequence_completed'; key = 'runner.sequence_completed'; arguments = @{ total = 2; duration = '1 min and 2 s' }; label = '' }
        )
        foreach ($state in $states) {
            $line = Format-CatalogMessage -Key $state.key -Arguments $state.arguments -Locale 'en-US'
            & $writer $line $state.code $state.label $state.arguments
            $value = Get-Content -LiteralPath $currentActionFile -Raw | ConvertFrom-Json -AsHashtable
            $value.code | Should -BeExactly $state.code
            $value.label | Should -BeExactly $state.label
            $value.line | Should -BeExactly $line
            $value.arguments.Count | Should -Be $state.arguments.Count
            $value.guestKey | Should -BeExactly $GuestKey
            $value.vmName | Should -BeExactly $VMName
            foreach ($name in $state.arguments.Keys) { $value.arguments[$name] | Should -Be $state.arguments[$name] }
        }
    }
}

Describe 'operator display formats follow the selected locale' {
    It 'preserves alert punctuation while selecting complete state variants' {
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1') -DisableNameChecking
        $adapter = Get-Module Yuruna.Globalization
        $priorContext = & $adapter { $script:OperatorContext }
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $here 'Test.RunnerInnerLoop.psm1'), [ref]$null, [ref]$null)
        $calls = @($ast.FindAll({ param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Write-Output' -and
                    $node.Extent.Text.Contains("-Key 'runner.failure_alert_state'")
                }, $true))
        $calls.Count | Should -Be 1
        $emit = [scriptblock]::Create('param($GatingState)' + "`n" + $calls[0].Extent.Text)
        try {
            & $adapter { $script:OperatorContext = [pscustomobject]@{ ResolvedTag = 'en-US' } }
            foreach ($armed in @($true, $false)) {
                foreach ($count in @(0, 2, 1234)) {
                    $stateBag = @{ ConsecutiveFailures = $count; FailuresBeforeAlert = 3; AlertArmed = $armed }
                    $number = $count.ToString('N0', [Globalization.CultureInfo]::GetCultureInfo('en-US'))
                    $state = if ($armed) { 'armed' } else { 'suppressed' }
                    (& $emit $stateBag) | Should -BeExactly "  Alert:   $number/3 failures ($state)"
                }
            }
        } finally { & $adapter { param($context) $script:OperatorContext = $context } $priorContext }
    }
    It 'keeps pinned English number formatting on a Portuguese host culture' {
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1') -DisableNameChecking
        $adapter = Get-Module Yuruna.Globalization
        $priorCulture = [Globalization.CultureInfo]::CurrentCulture
        $priorContext = & $adapter { $script:OperatorContext }
        try {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')
            & $adapter { $script:OperatorContext = [pscustomobject]@{ ResolvedTag = 'en-US' } }
            $text = Format-YurunaOperatorMessage -Key 'automation.operator_890c2539295306b9' -FormatValues @(1.26) -FormatBindings @{ totalHours = '0:F1' }
            $text | Should -BeExactly 'Uptime       : 1.3 hours'
            $text | Should -Not -Match '1,3'
            Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -DisableNameChecking
            $memory = Get-ServiceVmMemoryVerdict -Service @([pscustomobject]@{ Name = 'caching-proxy'; MemoryMb = 4096 }) -HostMemoryMb 32768
            $memory.Message | Should -Match '32\.0 GB; the 1 service VM this run starts commits 4\.0 GB'
            $memory.Message | Should -Not -Match '32,0|4,0'

        } finally {
            [Globalization.CultureInfo]::CurrentCulture = $priorCulture
            & $adapter { param($context) $script:OperatorContext = $context } $priorContext
        }
    }
}
