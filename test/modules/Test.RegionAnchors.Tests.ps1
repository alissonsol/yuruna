<#PSScriptInfo
.VERSION 2026.10.04
.GUID 42a1c8e3-5b47-4f60-9d2a-7e83b415cc09
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test docs anchors region pester
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
    Hold the REGION anchor gate to reaching a verdict, and to failing when
    a pointer names a heading that is not there.
.DESCRIPTION
    Every published `docs/` heading is a public address: a REGION pointer in
    the source names a slug and an anchor, and readers follow it from
    yuruna.link. Renaming a heading breaks those links silently, which is
    what tools/Test-RegionAnchors.ps1 exists to catch.

    The gate reads its slug-to-document map from a sibling checkout, and for
    a long time it warned and exited 0 when that map was absent. On a host
    without the sibling clone -- which includes any fresh environment -- it
    therefore reported success over nothing at all, and a green run meant
    only that the map could not be found. It now exits 2 there: it has
    checked nothing and says so, so a caller that requires evidence can tell
    the difference between "the pointers resolve" and "no pointer was read".

    This suite pins the three outcomes apart. It builds its own fixture map
    rather than trusting the sibling checkout, because a suite that passes
    only where someone happens to have cloned a second repository is the
    same failure the gate itself had.

    Run: Invoke-Pester -Path test/modules/Test.RegionAnchors.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Gate = Join-Path $script:RepoRoot 'tools' | Join-Path -ChildPath 'Test-RegionAnchors.ps1'

# A child pwsh, because the exit code is the whole contract here and only
# survives a process boundary.
function Invoke-Gate {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string[]]$Argument)
    $argv = @('-NoProfile', '-File', $script:Gate) + $Argument
    $out = (& pwsh @argv 2>&1 | Out-String)
    return @{ Output = $out; ExitCode = $LASTEXITCODE }
}

$script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-anchors-' + [Guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null

# The map shape is [ <slug or slug array>, <title>, <url or url array> ].
function New-LinkMap {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture writer; touches only a temp dir removed in AfterAll.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][object[]]$Entry)
    $path = Join-Path $script:Sandbox $Name
    Set-Content -LiteralPath $path -Value ($Entry | ConvertTo-Json -Depth 6 -AsArray) -Encoding utf8
    return $path
}

$script:RealMap = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna.link/yuruna.link.json'
}

AfterAll {
    if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'document anchor history survives partial updates and deletions' {
    It 'preserves unavailable and unselected documents and never reissues a retired id' {
        $fixture = Join-Path $script:Sandbox 'history/yuruna'
        foreach ($dir in @('tools', 'docs', 'globalization/manifests')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $fixture $dir) -Force
        }
        $generator = Join-Path $fixture 'tools/Invoke-DocAnchor.ps1'
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'tools/Invoke-DocAnchor.ps1') -Destination $generator
        $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'test/modules') -Force
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'test/modules/Test.Prelude.psm1') -Destination (Join-Path $fixture 'test/modules/Test.Prelude.psm1')
        $manifest = Join-Path $fixture 'globalization/manifests/doc-anchors.json'
        $readme = Join-Path $fixture 'README.md'
        $records = @(
            @{ id = '42aaaaaa'; repo = 'yuruna'; source = 'README.md'; translations = @{}; anchors = @(
                @{ id = '42aaaaaa-0001'; heading = 'First'; slug = 'first' },
                @{ id = '42aaaaaa-0002'; heading = 'Second'; slug = 'second' }) },
            @{ id = '42bbbbbb'; repo = 'yuruna'; source = 'docs/other.md'; translations = @{}; anchors = @() },
            @{ id = '42cccccc'; repo = 'yuruna-project'; source = 'README.md'; translations = @{}; anchors = @() })
        @{ schema = 'yuruna.doc-anchors/v1'; files = $records } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifest
        [IO.File]::WriteAllText($readme, "<a id=`"42aaaaaa-0002`"></a>`n`n# Second`n")
        $output = & pwsh -NoProfile -File $generator -Update -Path README.md -Quiet 2>&1 | Out-String
        Assert-Equal 1 $LASTEXITCODE $output
        $first = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
        Assert-Equal 3 @($first.files).Count 'a partial update retains other documents and absent sibling repositories'
        $entry = @($first.files | Where-Object { $_.id -eq '42aaaaaa' })[0]
        Assert-Equal '42aaaaaa-0001' $entry.retiredAnchorIds[0] 'deleted ids stay reserved after the manifest is rewritten'
        $output = & pwsh -NoProfile -File $generator -Update -Path README.md -Quiet 2>&1 | Out-String
        Assert-Equal 0 $LASTEXITCODE $output
        Add-Content -LiteralPath $readme -Value "`n# Third"
        $output = & pwsh -NoProfile -File $generator -Update -Path README.md -Quiet 2>&1 | Out-String
        Assert-Equal 1 $LASTEXITCODE $output
        $last = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
        $entry = @($last.files | Where-Object { $_.id -eq '42aaaaaa' })[0]
        Assert-Equal '42aaaaaa-0003' $entry.anchors[1].id 'a later invocation cannot give an old public link to unrelated text'
        Assert-Equal 1 @($entry.retiredAnchorIds).Count 'retired history remains separate from live link targets'
    }

    It 'preserves CRLF source and translation anchors across repeated updates' {
        $fixture = Join-Path $script:Sandbox 'crlf/yuruna'
        foreach ($dir in @('tools', 'test/modules', 'docs/pt-BR', 'globalization/manifests')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $fixture $dir) -Force
        }
        $generator = Join-Path $fixture 'tools/Invoke-DocAnchor.ps1'
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'tools/Invoke-DocAnchor.ps1') -Destination $generator
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'test/modules/Test.Prelude.psm1') -Destination (Join-Path $fixture 'test/modules/Test.Prelude.psm1')
        $readme = Join-Path $fixture 'README.md'
        $translation = Join-Path $fixture 'docs/pt-BR/README.md'
        $sourceText = "<a id=`"42dddddd-0007`"></a>`r`n`r`n<a id=`"legacy-heading`"></a>`r`n`r`n# Existing heading`r`n"
        $translatedText = "<a id=`"42dddddd-0007`"></a>`r`n`r`n# Titulo existente`r`n"
        [IO.File]::WriteAllText($readme, $sourceText)
        [IO.File]::WriteAllText($translation, $translatedText)
        $manifest = Join-Path $fixture 'globalization/manifests/doc-anchors.json'
        $record = [ordered]@{
            id = '42dddddd'; repo = 'yuruna'; source = 'README.md'
            translations = [ordered]@{ 'pt-BR' = 'docs/pt-BR/README.md' }
            anchors = @([ordered]@{ id = '42dddddd-0007'; heading = 'Existing heading'; slug = 'existing-heading' })
        }
        $manifestText = ([ordered]@{ schema = 'yuruna.doc-anchors/v1'; files = @($record) } |
            ConvertTo-Json -Depth 8).Replace("`r`n", "`n").TrimEnd() + "`n"
        [IO.File]::WriteAllText($manifest, $manifestText)

        foreach ($pass in 1..2) {
            $output = & pwsh -NoProfile -File $generator -Update -Path README.md -Quiet 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE "CRLF update $pass changed existing anchors: $output"
            Assert-Match 'Injected 0 anchor\(s\); wrote 0 file\(s\); 0 problem\(s\)' $output
            Assert-StringEqual $sourceText ([IO.File]::ReadAllText($readme)) 'source bytes, including CRLF and the legacy alias, remain unchanged'
            Assert-StringEqual $translatedText ([IO.File]::ReadAllText($translation)) 'translation bytes and its original stable id remain unchanged'
            Assert-StringEqual $manifestText ([IO.File]::ReadAllText($manifest)) 'the current anchor index remains unchanged'
            $entry = (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).files[0]
            Assert-Equal 1 @($entry.anchors).Count 'no duplicate anchor was injected'
            Assert-Equal '42dddddd-0007' $entry.anchors[0].id 'a noninitial suffix remains attached to its heading'
            Assert-False ($entry.PSObject.Properties.Name -contains 'retiredAnchorIds') 'an existing CRLF anchor must not become retired'
        }
    }
}

Describe 'the anchor gate says which of the three things happened' {

    It 'rejects missing, headingless, and substring-only document targets' -ForEach @('missing', 'headingless', 'substring') {
        $project = Join-Path $script:Sandbox ('document-' + $_)
        $null = New-Item -ItemType Directory -Path $project -Force
        $null = & git -C $project init --quiet 2>&1
        Assert-Equal 0 $LASTEXITCODE 'the disposable project initializes'
        if ($_ -ne 'missing') {
            $content = if ($_ -eq 'substring') { '# Installation guide' } else { 'No headings here.' }
            [IO.File]::WriteAllText((Join-Path $project 'README.md'), $content)
        }
        [IO.File]::WriteAllText((Join-Path $project 'consumer.ps1'), '# https://yuruna.link/fixture-doc#install')
        $map = New-LinkMap -Name ('document-' + $_ + '.json') -Entry @(
            , @('fixture-doc', 'Fixture', 'https://github.com/alissonsol/yuruna-project/blob/main/README.md'))
        $run = Invoke-Gate -Argument @('-Quiet', '-ProjectRoot', $project, '-Path', $project, '-LinkMap', $map)
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-Match 'install' $run.Output
    }

    It 'exits 2 when the link map is absent, having checked nothing' {
        $missing = Join-Path $script:Sandbox 'no-such-map.json'
        $run = Invoke-Gate -Argument @('-Quiet', '-LinkMap', $missing)
        Assert-Equal -Expected 2 -Actual $run.ExitCode `
            -Because "a gate that read no map has proved nothing and must not report success:`n$($run.Output)"
        Assert-Match -Pattern 'link map not found' -Actual $run.Output `
            'the warning has to name the missing input'
    }

    It 'fails when a pointer names an anchor id that does not exist' {
        # Every pointer in the tree now addresses a heading by id, so the
        # defect this gate exists for is an id naming nothing -- a heading
        # deleted, or a pointer typed by hand. Handing it an index with no
        # ids at all makes every real pointer unresolvable at once, which is
        # the same condition one deleted heading produces for one pointer.
        $empty = Join-Path $script:Sandbox 'no-anchors.json'
        Set-Content -LiteralPath $empty -Value '{ "schema": "yuruna.doc-anchors/v1", "files": [] }' -Encoding utf8
        $run = Invoke-Gate -Argument @('-Quiet', '-AnchorManifest', $empty)
        Assert-Equal -Expected 1 -Actual $run.ExitCode `
            -Because "an id that names no heading is the defect this gate exists for:`n$($run.Output)"
        Assert-Match -Pattern 'names no heading' -Actual $run.Output `
            'the report has to say the id resolves to nothing'
    }

    It 'fails when an id is recorded but the document no longer carries it' {
        # The manifest is generated FROM the documents, so checking a pointer
        # against the manifest alone proves only that the generator ran. A
        # heading deleted and its id later reissued to different text would
        # still look valid, and every published link to it would land on
        # unrelated prose without any error -- the exact silent failure the
        # id scheme exists to remove. So the gate asks the document.
        #
        # This points a real id at a document that does not contain it, which
        # is the same condition a deleted heading produces.
        $real = ConvertFrom-Json -InputObject (Get-Content -Raw -LiteralPath (
            Join-Path $script:RepoRoot 'globalization/manifests/doc-anchors.json'))
        $victim = @($real.files | Where-Object { @($_.anchors).Count -gt 0 })[0]
        $moved = Join-Path $script:Sandbox 'moved-anchors.json'
        $payload = [ordered]@{
            schema = 'yuruna.doc-anchors/v1'
            files  = @(@($real.files) | ForEach-Object {
                [ordered]@{
                    id      = $_.id
                    repo    = $_.repo
                    # Every file claims a document that carries none of these ids.
                    source  = 'docs/accessibility.md'
                    anchors = @($_.anchors)
                }
            })
        }
        Set-Content -LiteralPath $moved -Value ($payload | ConvertTo-Json -Depth 8) -Encoding utf8
        Assert-True ($null -ne $victim) 'the real manifest carries no anchors to move'

        $run = Invoke-Gate -Argument @('-Quiet', '-AnchorManifest', $moved)
        Assert-Equal -Expected 1 -Actual $run.ExitCode `
            -Because "an id the document does not carry has to fail, or a deleted heading goes unnoticed:`n$($run.Output)"
    }

    It 'accepts every anchor id the generator recorded' {
        # The other direction: with the real index, the ids actually written
        # into the documents all resolve. A gate that only ever failed would
        # be as useless as one that only ever passed.
        $run = Invoke-Gate -Argument @('-Quiet')
        Assert-Equal -Expected 0 -Actual $run.ExitCode `
            -Because "a pointer names an id the documents no longer carry:`n$($run.Output)"
    }

    It 'does not fail a slug it cannot resolve to a document in this repository' {
        # A slug whose target is an external site is outside what this gate
        # can see. Reporting it is right; failing on it would make every
        # external reference a build break.
        $map = New-LinkMap -Name 'external-only.json' -Entry @(
            , @('5whys', 'Why?', 'https://alissonsol.blogspot.com/2020/02/why.html'))
        $external = Join-Path $script:Sandbox 'external-slug'
        $null = New-Item -ItemType Directory -Path $external -Force
        $null = & git -C $external init --quiet 2>&1
        Assert-Equal 0 $LASTEXITCODE 'the disposable external-slug repository initializes'
        [IO.File]::WriteAllText((Join-Path $external 'consumer.ps1'),
            '# https://yuruna.link/' + '5whys#overview')
        $run = Invoke-Gate -Argument @('-Quiet', '-AdditionalSourceRoot', $external,
            '-Path', $external, '-LinkMap', $map)
        Assert-Equal -Expected 0 -Actual $run.ExitCode `
            -Because "an unresolvable slug is reported, not failed:`n$($run.Output)"
        Assert-Match 'UNRESOLVABLE' $run.Output
    }

    It 'resolves every pointer against the real map when the sibling checkout is there' {
        if (-not (Test-Path -LiteralPath $script:RealMap -PathType Leaf)) {
            Set-ItResult -Skipped -Because 'the yuruna.link sibling checkout is not present on this host'
            return
        }
        $run = Invoke-Gate -Argument @('-Quiet', '-LinkMap', $script:RealMap)
        Assert-Equal -Expected 0 -Actual $run.ExitCode `
            -Because "a published heading was renamed without its pointers:`n$($run.Output)"
    }

    It 'rejects a broken pointer copied into the project candidate' {
        $sourceProject = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna-project'
        $sourceRelative = 'example/text-to-sql/components/frontend/text-to-sql-ui/Services/ClaudeLlmClient.cs'
        $documentRelative = 'example/text-to-sql/README.md'
        if (-not (Test-Path -LiteralPath (Join-Path $sourceProject $sourceRelative) -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $sourceProject $documentRelative) -PathType Leaf)) {
            Set-ItResult -Skipped -Because 'the source project checkout is not beside the framework'
            return
        }

        $project = Join-Path $script:Sandbox 'project-pointer-candidate'
        foreach ($relative in @($sourceRelative, $documentRelative)) {
            $destination = Join-Path $project $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $sourceProject $relative) -Destination $destination
        }
        $sourcePath = Join-Path $project $sourceRelative
        $source = [IO.File]::ReadAllText($sourcePath).Replace(
            '4286c679-0007', '4286c679-dead')
        [IO.File]::WriteAllText($sourcePath, $source, [Text.UTF8Encoding]::new($false))
        $null = & git -C $project init --quiet 2>&1
        Assert-Equal -Expected 0 -Actual $LASTEXITCODE 'could not initialize the project candidate fixture'

        $map = New-LinkMap -Name 'project-local.json' -Entry @(
            , @('4286c679', 'Text-to-SQL',
                'https://github.com/alissonsol/yuruna-project/blob/main/example/text-to-sql/README.md'))
        $run = Invoke-Gate -Argument @(
            '-Quiet', '-ProjectRoot', $project, '-Path', $project, '-LinkMap', $map)
        Assert-Equal -Expected 1 -Actual $run.ExitCode `
            -Because "a broken pointer in the staged project was invisible:`n$($run.Output)"
        Assert-Match -Pattern 'yuruna-project/.+ClaudeLlmClient\.cs' -Actual $run.Output
        Assert-Match -Pattern '4286c679-dead' -Actual $run.Output
    }

    It 'passes the selected project root from cross-repository orchestration' {
        $crossRepo = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'tools/Invoke-CrossRepoGate.ps1'))
        $pattern = '(?s)\$anchorArgs\s*=\s*@\(.*?''-ProjectRoot'',\s*\$ProjectRoot\)'
        Assert-Match -Pattern $pattern `
            -Actual $crossRepo `
            -Because 'the staged project checkout is not supplied to the region-anchor leaf'
    }
}

Describe 'the anchor gate inventories additional source repositories' {
    BeforeAll {
        $script:AdditionalMap = New-LinkMap -Name 'additional-source.json' -Entry @(
            , @('fixture-doc', 'Fixture', 'https://github.com/alissonsol/yuruna/blob/main/docs/source-consistency.md'))
        $script:PointerPrefix = '# See https://yuruna.link/'
    }

    BeforeEach {
        $script:AdditionalRepo = Join-Path $script:Sandbox ('extra-source-' + [Guid]::NewGuid().ToString('n'))
        $null = New-Item -ItemType Directory -Path $script:AdditionalRepo
        $null = & git -C $script:AdditionalRepo init --quiet 2>&1
        Assert-Equal 0 $LASTEXITCODE 'the disposable additional source repository initializes'
    }

    It 'rejects an invalid pointer in an additional repository included by default' {
        [IO.File]::WriteAllText((Join-Path $script:AdditionalRepo 'consumer.ps1'),
            $script:PointerPrefix + '42ffffff-dead')
        $run = Invoke-Gate -Argument @('-Quiet', '-AdditionalSourceRoot', $script:AdditionalRepo,
            '-LinkMap', $script:AdditionalMap)
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-Match 'extra-source-[^/]+/consumer\.ps1' $run.Output
        Assert-Match '42ffffff-dead' $run.Output
    }

    It 'checks and accepts a valid pointer in an explicitly selected additional repository' {
        [IO.File]::WriteAllText((Join-Path $script:AdditionalRepo 'consumer.ps1'),
            $script:PointerPrefix + '42e220c4-0003')
        $run = Invoke-Gate -Argument @('-AdditionalSourceRoot', $script:AdditionalRepo,
            '-Path', $script:AdditionalRepo, '-LinkMap', $script:AdditionalMap)
        Assert-Equal 0 $run.ExitCode $run.Output
        Assert-Match '1 pointer\(s\) checked' $run.Output
    }

    It 'keeps gitignored files outside an additional repository inventory' {
        [IO.File]::WriteAllText((Join-Path $script:AdditionalRepo '.gitignore'), 'ignored.ps1')
        [IO.File]::WriteAllText((Join-Path $script:AdditionalRepo 'ignored.ps1'),
            $script:PointerPrefix + '42ffffff-dead')
        [IO.File]::WriteAllText((Join-Path $script:AdditionalRepo 'consumer.ps1'),
            $script:PointerPrefix + '42e220c4-0003')
        $run = Invoke-Gate -Argument @('-AdditionalSourceRoot', $script:AdditionalRepo,
            '-Path', $script:AdditionalRepo, '-LinkMap', $script:AdditionalMap)
        Assert-Equal 0 $run.ExitCode $run.Output
        Assert-Match '1 pointer\(s\) checked' $run.Output
        Assert-False ($run.Output.Contains('ignored.ps1')) $run.Output
    }

    It 'applies explicit Path filtering inside an additional repository' {
        $selected = Join-Path $script:AdditionalRepo 'selected'
        $null = New-Item -ItemType Directory -Path $selected
        [IO.File]::WriteAllText((Join-Path $selected 'consumer.ps1'),
            $script:PointerPrefix + '42e220c4-0003')
        [IO.File]::WriteAllText((Join-Path $script:AdditionalRepo 'excluded.ps1'),
            $script:PointerPrefix + '42ffffff-dead')
        $run = Invoke-Gate -Argument @('-AdditionalSourceRoot', $script:AdditionalRepo,
            '-Path', $selected, '-LinkMap', $script:AdditionalMap)
        Assert-Equal 0 $run.ExitCode $run.Output
        Assert-Match '1 pointer\(s\) checked' $run.Output
    }

    It 'reports that a missing explicitly requested source repository cannot be checked' {
        $missing = Join-Path $script:Sandbox 'missing-source'
        $run = Invoke-Gate -Argument @('-Quiet', '-AdditionalSourceRoot', $missing,
            '-LinkMap', $script:AdditionalMap)
        Assert-Equal 2 $run.ExitCode $run.Output
        Assert-Match 'additional source checkout not found' $run.Output
    }
}

Describe 'published nonlocalized SBOM anchor authority' {
    BeforeEach {
        $workspace = Join-Path $script:Sandbox ('sbom-' + [Guid]::NewGuid().ToString('n'))
        $script:SbomRepo = Join-Path $workspace 'yuruna'
        $script:SbomProject = Join-Path $workspace 'yuruna-project'
        foreach ($directory in @('tools', 'test/modules', 'automation', 'docs/sbom', 'globalization/manifests')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $script:SbomRepo $directory) -Force
        }
        $null = New-Item -ItemType Directory -Path (Join-Path $script:SbomProject 'docs/sbom') -Force
        foreach ($relative in @('tools/Test-RegionAnchors.ps1', 'tools/Update-LinkCatalog.ps1',
                'test/modules/Test.Prelude.psm1', 'automation/Yuruna.Globalization.psm1')) {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot $relative) -Destination (Join-Path $script:SbomRepo $relative)
        }
        foreach ($repository in @($script:SbomRepo, $script:SbomProject)) {
            $null = & git -C $repository init --quiet 2>&1
            Assert-Equal 0 $LASTEXITCODE 'the disposable SBOM repository initializes'
        }
        $script:SbomDocument = Join-Path $script:SbomRepo 'docs/sbom/README.md'
        $script:SbomProjectDocument = Join-Path $script:SbomProject 'docs/sbom/README.md'
        [IO.File]::WriteAllText($script:SbomDocument, "<a id=`"42abcdef-0001`"></a>`n`n# Framework inventory`n")
        [IO.File]::WriteAllText($script:SbomProjectDocument, "<a id=`"42fedcba-0001`"></a>`n`n# Project inventory`n")
        $script:SbomConsumer = Join-Path $script:SbomRepo 'consumer.ps1'
        $script:SbomPointerPrefix = '# https://yuruna.link/'
        [IO.File]::WriteAllText($script:SbomConsumer, $script:SbomPointerPrefix + '42abcdef-0001')
        $script:SbomManifest = Join-Path $script:SbomRepo 'globalization/manifests/doc-anchors.json'
        [IO.File]::WriteAllText($script:SbomManifest, '{"schema":"yuruna.doc-anchors/v1","files":[]}')
        $script:SbomCatalog = New-LinkMap -Name ('sbom-' + [Guid]::NewGuid().ToString('n') + '.json') -Entry @(
            , @('42abcdef', 'Framework inventory', 'https://github.com/alissonsol/yuruna/blob/main/docs/sbom/README.md')
            , @('42fedcba', 'Project inventory', 'https://github.com/alissonsol/yuruna-project/blob/main/docs/sbom/README.md'))
    }

    It 'accepts published framework and project SBOM ids without adding them to the manifest' {
        [IO.File]::WriteAllText($script:SbomConsumer,
            $script:SbomPointerPrefix + '42abcdef-0001 and ' + $script:SbomPointerPrefix + '42fedcba-0001')
        $before = [IO.File]::ReadAllText($script:SbomManifest)
        $output = & pwsh -NoProfile -File (Join-Path $script:SbomRepo 'tools/Test-RegionAnchors.ps1') `
            -ProjectRoot $script:SbomProject -Path $script:SbomConsumer -LinkMap $script:SbomCatalog -Quiet 2>&1 | Out-String
        Assert-Equal 0 $LASTEXITCODE $output
        Assert-StringEqual $before ([IO.File]::ReadAllText($script:SbomManifest)) 'local validation does not enroll SBOM documents'
    }

    It 'rejects missing, deleted, fenced, unpublished, and mismatched SBOM ids' -ForEach @(
        'missing', 'deleted', 'backtick-fenced', 'tilde-fenced', 'unpublished', 'mismatched', 'mismatched-prefix', 'conflicting-target') {
        switch ($_) {
            'missing' { Remove-Item -LiteralPath $script:SbomDocument }
            'deleted' { [IO.File]::WriteAllText($script:SbomDocument, '# Framework inventory') }
            'backtick-fenced' { [IO.File]::WriteAllText($script:SbomDocument, "````````markdown`n<a id=`"42abcdef-0001`"></a>`n````````") }
            'tilde-fenced' { [IO.File]::WriteAllText($script:SbomDocument, "~~~markdown`n<a id=`"42abcdef-0001`"></a>`n~~~") }
            'unpublished' { [IO.File]::WriteAllText($script:SbomCatalog, '[]') }
            'mismatched' { [IO.File]::WriteAllText($script:SbomConsumer, $script:SbomPointerPrefix + '42abcdef-0002') }
            'mismatched-prefix' { [IO.File]::WriteAllText($script:SbomDocument, '<a id="42aaaaaa-0001"></a>') }
            'conflicting-target' {
                $rows = ConvertFrom-Json -NoEnumerate -InputObject ([IO.File]::ReadAllText($script:SbomCatalog))
                $rows[0][2] = @($rows[0][2], 'https://example.com/elsewhere')
                [IO.File]::WriteAllText($script:SbomCatalog, (ConvertTo-Json -InputObject $rows -Depth 6))
            }
        }
        $output = & pwsh -NoProfile -File (Join-Path $script:SbomRepo 'tools/Test-RegionAnchors.ps1') `
            -ProjectRoot $script:SbomProject -Path $script:SbomConsumer -LinkMap $script:SbomCatalog -Quiet 2>&1 | Out-String
        Assert-Equal 1 $LASTEXITCODE $output
        Assert-Match '42abcdef-000[12]' $output
        Assert-Match 'names no heading' $output
    }

    It 'preserves published SBOM rows, other file ids, and slug rows across generation' {
        $originalRows = ConvertFrom-Json -NoEnumerate -InputObject ([IO.File]::ReadAllText($script:SbomCatalog))
        $rows = @($originalRows) + @(
            , @('42aaaaaa', 'Unregistered public document', 'https://example.com/public.md')
            , @('legacy-doc', 'Legacy document', 'https://example.com/legacy'))
        [IO.File]::WriteAllText($script:SbomCatalog, (ConvertTo-Json -InputObject $rows -Depth 6))
        $expected = @($rows | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 6 -Compress })
        $output = & pwsh -NoProfile -File (Join-Path $script:SbomRepo 'tools/Update-LinkCatalog.ps1') `
            -Catalog $script:SbomCatalog -Update 2>&1 | Out-String
        Assert-Equal 1 $LASTEXITCODE $output
        $actual = ConvertFrom-Json -NoEnumerate -InputObject ([IO.File]::ReadAllText($script:SbomCatalog))
        Assert-Equal 4 $actual.Count $output
        foreach ($row in $actual) {
            Assert-True ($expected -contains (ConvertTo-Json -InputObject $row -Depth 6 -Compress)) 'every published row retains its original identity'
        }
    }

    It 'rejects an invalid published SBOM row without changing the catalog' -ForEach @('missing', 'fenced', 'mismatched', 'conflicting-target') {
        switch ($_) {
            'missing' { Remove-Item -LiteralPath $script:SbomDocument }
            'fenced' { [IO.File]::WriteAllText($script:SbomDocument, "~~~`n<a id=`"42abcdef-0001`"></a>`n~~~") }
            'mismatched' { [IO.File]::WriteAllText($script:SbomDocument, '<a id="42aaaaaa-0001"></a>') }
            'conflicting-target' {
                $rows = ConvertFrom-Json -NoEnumerate -InputObject ([IO.File]::ReadAllText($script:SbomCatalog))
                $rows[0][2] = @($rows[0][2], 'https://example.com/elsewhere')
                [IO.File]::WriteAllText($script:SbomCatalog, (ConvertTo-Json -InputObject $rows -Depth 6))
            }
        }
        $before = [IO.File]::ReadAllText($script:SbomCatalog)
        $output = & pwsh -NoProfile -File (Join-Path $script:SbomRepo 'tools/Update-LinkCatalog.ps1') `
            -Catalog $script:SbomCatalog -Update 2>&1 | Out-String
        Assert-Equal 2 $LASTEXITCODE $output
        Assert-StringEqual $before ([IO.File]::ReadAllText($script:SbomCatalog)) 'invalid local authority cannot rewrite published keys'
    }

    It 'rejects a manifest collision that would retarget a published file id' {
        $record = @{ id = '42abcdef'; repo = 'yuruna'; source = 'docs/other.md'; translations = @{}; anchors = @() }
        [IO.File]::WriteAllText($script:SbomManifest, (@{ schema = 'yuruna.doc-anchors/v1'; files = @($record) } | ConvertTo-Json -Depth 6))
        $before = [IO.File]::ReadAllText($script:SbomCatalog)
        $output = & pwsh -NoProfile -File (Join-Path $script:SbomRepo 'tools/Update-LinkCatalog.ps1') `
            -Catalog $script:SbomCatalog -Update 2>&1 | Out-String
        Assert-Equal 2 $LASTEXITCODE $output
        Assert-Match 'would change its document target' $output
        Assert-StringEqual $before ([IO.File]::ReadAllText($script:SbomCatalog)) 'an existing file id cannot move to another document'
    }

    It 'rejects duplicate published keys with different targets before writing' {
        $rows = ConvertFrom-Json -NoEnumerate -InputObject ([IO.File]::ReadAllText($script:SbomCatalog))
        $rows = @($rows) + @(, @('42abcdef', 'Another target', 'https://example.com/other.md'))
        [IO.File]::WriteAllText($script:SbomCatalog, (ConvertTo-Json -InputObject $rows -Depth 6))
        $before = [IO.File]::ReadAllText($script:SbomCatalog)
        $output = & pwsh -NoProfile -File (Join-Path $script:SbomRepo 'tools/Update-LinkCatalog.ps1') `
            -Catalog $script:SbomCatalog -Update 2>&1 | Out-String
        Assert-Equal 2 $LASTEXITCODE $output
        Assert-Match 'repeats published file id' $output
        Assert-StringEqual $before ([IO.File]::ReadAllText($script:SbomCatalog)) 'conflicting public keys cannot be silently retargeted'
    }

    It 'keeps slug aliases while refreshing a generated row for the same document' {
        $record = @{ id = '42aaaaaa'; repo = 'yuruna'; source = 'README.md'; translations = @{}; anchors = @() }
        [IO.File]::WriteAllText($script:SbomManifest, (@{ schema = 'yuruna.doc-anchors/v1'; files = @($record) } | ConvertTo-Json -Depth 6))
        $rows = ConvertFrom-Json -NoEnumerate -InputObject ([IO.File]::ReadAllText($script:SbomCatalog))
        $rows = @($rows) + @(, @(@('42aaaaaa', 'legacy-readme'), 'Existing title', 'https://github.com/alissonsol/yuruna/blob/main/README.md'))
        [IO.File]::WriteAllText($script:SbomCatalog, (ConvertTo-Json -InputObject $rows -Depth 6))
        $output = & pwsh -NoProfile -File (Join-Path $script:SbomRepo 'tools/Update-LinkCatalog.ps1') `
            -Catalog $script:SbomCatalog -Update 2>&1 | Out-String
        Assert-Equal 1 $LASTEXITCODE $output
        $actual = ConvertFrom-Json -NoEnumerate -InputObject ([IO.File]::ReadAllText($script:SbomCatalog))
        $generated = @($actual | Where-Object { @($_[0]) -contains '42aaaaaa' })
        Assert-Equal 1 $generated.Count 'the generated id remains unique'
        Assert-True (@($generated[0][0]) -contains 'legacy-readme') 'the existing slug alias remains published'
    }
}
