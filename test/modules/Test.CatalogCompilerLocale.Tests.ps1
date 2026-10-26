<#PSScriptInfo
.VERSION 2026.10.26
.GUID 42dbe8fd-155c-4f36-ac80-9131843b5460
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization catalog compiler pester
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
    Hold the catalog compiler to translations reviewed against one source
    message, the pinned Portuguese grammar and project values, and planned
    locales that are validated but never shipped.
.DESCRIPTION
    Part of the catalog compiler suites: Test.CatalogCompiler.Tests.ps1
    holds their setup and says what they protect.

    Run: Invoke-Pester -Path test/modules/Test.CatalogCompilerLocale.Tests.ps1
#>

BeforeAll {
    # Split from Test.CatalogCompiler.Tests.ps1 so the files run at once. The
    # setup is that file's own block, run as that file, so every case here sets
    # up the way it did there.
    $suite = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'Test.CatalogCompiler.Tests.ps1'), [ref]$null, [ref]$null)
    $script:SharedBlock = @{}
    foreach ($statement in @($suite.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.PipelineAst] })) {
        $command = $statement.PipelineElements[0]
        if ($command -is [Management.Automation.Language.CommandAst] -and $command.GetCommandName() -in 'BeforeAll', 'AfterAll') {
            $script:SharedBlock[$command.GetCommandName()] = $command.CommandElements[1].ScriptBlock.GetScriptBlock()
        }
    }
    . $script:SharedBlock['BeforeAll']
}

AfterAll {
    . $script:SharedBlock['AfterAll']
}

Describe 'translation files carry only wording reviewed against one source message' {

    It 'accepts a current per-message hash and records its provenance' {
        $root = New-CatalogRoot -Name 'translation-current' -DomainJson $script:GoodCatalog
        Invoke-Compile -Root $root -Update | Out-Null
        $initialSet = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $root 'manifests/catalog-set.json')))
        $plainHash = [string]$initialSet.messageSources.'sample.plain'.sourceHash
        $countHash = [string]$initialSet.messageSources.'sample.counted'.sourceHash

        $manifest = $script:Manifest.Replace(
            '"qps-Ploc": {',
            '"pt-BR": { "direction": "ltr", "status": "supported", "displayName": "Portuguese", "pluralCategories": ["one", "other"], "pluralRule": "one-if-1" },' + "`n    " + '"qps-Ploc": {')
        [IO.File]::WriteAllText((Join-Path $root 'locale-manifest.json'), $manifest, [Text.UTF8Encoding]::new($false))
        $ptDir = Join-Path $root 'catalogs/pt-BR'
        New-Item -ItemType Directory -Path $ptDir -Force | Out-Null
        $translation = @"
{
  "schema": "yuruna.catalog/v1",
  "domain": "sample",
  "locale": "pt-BR",
  "messages": {
    "sample.plain": {
      "sourceHash": "$plainHash",
      "message": "Nada esta em execucao."
    },
    "sample.counted": {
      "sourceHash": "$countHash",
      "plural": { "variants": { "one": "{count} item na fila.", "other": "{count} itens na fila." } }
    }
  }
}
"@
        [IO.File]::WriteAllText((Join-Path $ptDir 'sample.json'), $translation, [Text.UTF8Encoding]::new($false))

        $run = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 0 -Actual $run.ExitCode "a current translation should compile:`n$($run.Output)"
        $set = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $root 'manifests/catalog-set.json')))
        Assert-StringEqual -Expected $plainHash -Actual ([string]$set.translations.'pt-BR/sample.plain'.sourceHash) `
            'the release set lost the exact English message the translation reviewed'
        Assert-True ($set.translations.'pt-BR/sample.plain'.inputHash -cmatch '^[0-9a-f]{64}$') `
            'the release set does not identify the translation input file'
    }

    It 'records a machine draft in the set manifest and not in the artifact' {
        # Provenance travels in the set manifest only: a machine draft and the
        # same text accepted must ship the same bytes in every runtime.
        $roots = @{}
        foreach ($variant in 'plain', 'machine') {
            $root = New-CatalogRoot -Name "translation-origin-$variant" -DomainJson $script:GoodCatalog
            Invoke-Compile -Root $root -Update | Out-Null
            $initialSet = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $root 'manifests/catalog-set.json')))
            $plainHash = [string]$initialSet.messageSources.'sample.plain'.sourceHash
            $countHash = [string]$initialSet.messageSources.'sample.counted'.sourceHash
            $manifest = $script:Manifest.Replace(
                '"qps-Ploc": {',
                '"pt-BR": { "direction": "ltr", "status": "supported", "displayName": "Portuguese", "pluralCategories": ["one", "other"], "pluralRule": "one-if-1" },' + "`n    " + '"qps-Ploc": {')
            [IO.File]::WriteAllText((Join-Path $root 'locale-manifest.json'), $manifest, [Text.UTF8Encoding]::new($false))
            $origin = if ($variant -eq 'machine') { ', "origin": "machine"' } else { '' }
            $translation = '{ "schema": "yuruna.catalog/v1", "domain": "sample", "locale": "pt-BR", "messages": { "sample.plain": { "sourceHash": "' +
                $plainHash + '"' + $origin + ', "message": "Nada esta em execucao." }, "sample.counted": { "sourceHash": "' + $countHash +
                '", "plural": { "variants": { "one": "{count} item na fila.", "other": "{count} itens na fila." } } } } }'
            New-Item -ItemType Directory -Path (Join-Path $root 'catalogs/pt-BR') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $root 'catalogs/pt-BR/sample.json'), $translation, [Text.UTF8Encoding]::new($false))
            $run = Invoke-Compile -Root $root -Update
            $run.Output | Should -Not -Match 'Catalog validation failed' -Because $run.Output
            $roots[$variant] = $root
        }
        $set = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $roots['machine'] 'manifests/catalog-set.json')))
        [string]$set.translations.'pt-BR/sample.plain'.origin | Should -BeExactly 'machine'
        $set.counts.machineTranslations | Should -Be 1
        $set.counts.machineByLocale.'pt-BR' | Should -Be 1
        $accepted = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $roots['plain'] 'manifests/catalog-set.json')))
        [string]$accepted.translations.'pt-BR/sample.plain'.origin | Should -BeExactly 'accepted'
        $accepted.counts.machineTranslations | Should -Be 0

        $artifacts = @(Get-ChildItem -LiteralPath (Join-Path $roots['plain'] 'generated') -Recurse -File)
        @($artifacts | Where-Object { $_.Name -like 'pt-BR*' -or $_.Name -like 'ptBR*' }).Count | Should -BeGreaterThan 0 -Because 'no pt-BR artifact was written to compare'
        foreach ($file in $artifacts) {
            $relative = [IO.Path]::GetRelativePath($roots['plain'], $file.FullName)
            $other = Join-Path $roots['machine'] $relative
            Test-Path -LiteralPath $other | Should -BeTrue -Because "the machine-draft run did not write $relative"
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($other)) |
                Should -BeExactly ([Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName))) -Because "$relative differs with the origin field"
        }
    }

    It 'refuses an origin value other than machine' {
        $root = New-CatalogRoot -Name 'translation-origin-human' -DomainJson $script:GoodCatalog
        $manifest = $script:Manifest.Replace(
            '"qps-Ploc": {',
            '"pt-BR": { "direction": "ltr", "status": "supported", "displayName": "Portuguese", "pluralCategories": ["one", "other"], "pluralRule": "one-if-1" },' + "`n    " + '"qps-Ploc": {')
        [IO.File]::WriteAllText((Join-Path $root 'locale-manifest.json'), $manifest, [Text.UTF8Encoding]::new($false))
        New-Item -ItemType Directory -Path (Join-Path $root 'catalogs/pt-BR') -Force | Out-Null
        $translation = '{ "schema": "yuruna.catalog/v1", "domain": "sample", "locale": "pt-BR", "messages": { "sample.plain": { "sourceHash": "' +
            ('0' * 64) + '", "origin": "human", "message": "Nada." } } }'
        [IO.File]::WriteAllText((Join-Path $root 'catalogs/pt-BR/sample.json'), $translation, [Text.UTF8Encoding]::new($false))
        $run = Invoke-Compile -Root $root -Update
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Output | Should -Match 'does not satisfy schema/catalog\.schema\.json'
    }

    It 'rejects a translation scalar combined with either branch kind' {
        foreach ($kind in @('plural', 'select')) {
            $source = if ($kind -eq 'select') {
                $script:GoodCatalog.Replace('      "plural": {', '      "select": {')
            } else { $script:GoodCatalog }
            $root = New-CatalogRoot -Name "translation-message-plus-$kind" -DomainJson $source
            $manifest = $script:Manifest.Replace(
                '"qps-Ploc": {',
                '"pt-BR": { "direction": "ltr", "status": "supported", "displayName": "Portuguese", "pluralCategories": ["one", "other"], "pluralRule": "one-if-1" },' + "`n    " + '"qps-Ploc": {')
            [IO.File]::WriteAllText((Join-Path $root 'locale-manifest.json'), $manifest,
                [Text.UTF8Encoding]::new($false))
            $ptDir = Join-Path $root 'catalogs/pt-BR'
            New-Item -ItemType Directory -Path $ptDir -Force | Out-Null
            $sourceHash = '0' * 64
            $translation = @"
{
  "schema": "yuruna.catalog/v1", "domain": "sample", "locale": "pt-BR",
  "messages": {
    "sample.plain": { "sourceHash": "$sourceHash", "message": "Nada em execucao." },
    "sample.counted": {
      "sourceHash": "$sourceHash",
      "message": "Esta frase nunca pode ser descartada.",
      "$kind": { "variants": { "one": "{count} item.", "other": "{count} itens." } }
    }
  }
}
"@
            [IO.File]::WriteAllText((Join-Path $ptDir 'sample.json'), $translation,
                [Text.UTF8Encoding]::new($false))

            $run = Invoke-Compile -Root $root
            Assert-Equal -Expected 1 -Actual $run.ExitCode `
                -Because "a translation message plus $kind was treated as only $kind"
            Assert-Match -Pattern 'catalog\.schema\.json' -Actual $run.Output `
                -Because "the authoritative schema did not reject translation message plus $kind"
        }
    }

    It 'rejects whitespace-only wording in a translation variant' {
        $root = New-CatalogRoot -Name 'translation-blank-variant' -DomainJson $script:GoodCatalog
        $manifest = $script:Manifest.Replace(
            '"qps-Ploc": {',
            '"pt-BR": { "direction": "ltr", "status": "supported", "displayName": "Portuguese", "pluralCategories": ["one", "other"], "pluralRule": "one-if-1" },' + "`n    " + '"qps-Ploc": {')
        [IO.File]::WriteAllText((Join-Path $root 'locale-manifest.json'), $manifest,
            [Text.UTF8Encoding]::new($false))
        $ptDir = Join-Path $root 'catalogs/pt-BR'
        New-Item -ItemType Directory -Path $ptDir -Force | Out-Null
        $sourceHash = '0' * 64
        $translation = @"
{
  "schema": "yuruna.catalog/v1", "domain": "sample", "locale": "pt-BR",
  "messages": {
    "sample.plain": { "sourceHash": "$sourceHash", "message": "Nada em execucao." },
    "sample.counted": { "sourceHash": "$sourceHash", "plural": {
      "variants": { "one": "{count} item.", "other": "   " }
    } }
  }
}
"@
        [IO.File]::WriteAllText((Join-Path $ptDir 'sample.json'), $translation,
            [Text.UTF8Encoding]::new($false))

        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'blank translated wording was publishable'
        Assert-Match -Pattern 'blank plural\.other form' -Actual $run.Output `
            'the semantic compiler check did not identify the blank translated variant'
    }

    It 'stales only the translation whose English source contract changed' {
        $root = New-CatalogRoot -Name 'translation-stale' -DomainJson $script:GoodCatalog
        Invoke-Compile -Root $root -Update | Out-Null
        $initialSet = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $root 'manifests/catalog-set.json')))
        $plainHash = [string]$initialSet.messageSources.'sample.plain'.sourceHash
        $countHash = [string]$initialSet.messageSources.'sample.counted'.sourceHash
        $manifest = $script:Manifest.Replace(
            '"qps-Ploc": {',
            '"pt-BR": { "direction": "ltr", "status": "supported", "displayName": "Portuguese", "pluralCategories": ["one", "other"], "pluralRule": "one-if-1" },' + "`n    " + '"qps-Ploc": {')
        [IO.File]::WriteAllText((Join-Path $root 'locale-manifest.json'), $manifest, [Text.UTF8Encoding]::new($false))
        $ptDir = Join-Path $root 'catalogs/pt-BR'
        New-Item -ItemType Directory -Path $ptDir -Force | Out-Null
        $translation = @"
{
  "schema": "yuruna.catalog/v1", "domain": "sample", "locale": "pt-BR",
  "messages": {
    "sample.plain": { "sourceHash": "$plainHash", "message": "Nada esta em execucao." },
    "sample.counted": { "sourceHash": "$countHash", "plural": { "variants": { "one": "{count} item.", "other": "{count} itens." } } }
  }
}
"@
        [IO.File]::WriteAllText((Join-Path $ptDir 'sample.json'), $translation, [Text.UTF8Encoding]::new($false))
        $changed = $script:GoodCatalog.Replace('Nothing is running.', 'Nothing is running now.')
        [IO.File]::WriteAllText((Join-Path $root 'catalogs/en-US/sample.json'), $changed, [Text.UTF8Encoding]::new($false))

        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'an English reword must stale its translation'
        Assert-Match -Pattern "sample\.plain.*sourceHash is stale" -Actual $run.Output 'the changed key is not named'
        Assert-False ($run.Output -match "sample\.counted.*sourceHash is stale") `
            'an unrelated message was staled by another source edit'
    }
}

Describe 'complete Portuguese variants use the pinned target grammar' {
    It 'globalization acceptance: pt-BR complete active keys variants and placeholders' {
        # The real compiler checks every enabled domain. Planned languages do
        # not count as delivered; the later-wave source gate requires supported.
        $current = Invoke-Tool -Tool $script:Compiler -Argument @('-Check', '-Quiet')
        $current.ExitCode | Should -Be 0 -Because $current.Output
        $root = New-CatalogRoot -Name 'portuguese-plural-target' -DomainJson $script:GoodCatalog
        $null = Invoke-Compile -Root $root -Update
        $initial = Get-Content -LiteralPath (Join-Path $root 'manifests/catalog-set.json') -Raw | ConvertFrom-Json -AsHashtable
        $manifest = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'globalization/locale-manifest.json') -Raw | ConvertFrom-Json -AsHashtable
        $manifest.locales.'pt-BR'.status = 'supported'
        foreach ($tag in @($manifest.locales.Keys)) {
            if ($tag -cnotin @($manifest.default, 'pt-BR') -and $manifest.locales[$tag].status -ceq 'supported') {
                $manifest.locales[$tag].status = 'planned'
            }
        }
        [IO.File]::WriteAllText((Join-Path $root 'locale-manifest.json'), (ConvertTo-Json $manifest -Depth 15))
        $messages = @{
            'sample.plain' = @{ sourceHash = $initial.messageSources.'sample.plain'.sourceHash; message = 'Test-only translated fixture.' }
            'sample.counted' = @{ sourceHash = $initial.messageSources.'sample.counted'.sourceHash; plural = @{ variants = @{ one = '{count} singular fixture'; many = '{count} million fixture'; other = '{count} other fixture' } } }
        }
        $translated = @{ schema = 'yuruna.catalog/v1'; locale = 'pt-BR'; domain = 'sample'; messages = $messages }
        $directory = Join-Path $root 'catalogs/pt-BR'
        [void][IO.Directory]::CreateDirectory($directory)
        $path = Join-Path $directory 'sample.json'
        [IO.File]::WriteAllText($path, (ConvertTo-Json $translated -Depth 15))
        $null = Invoke-Compile -Root $root -Update
        (Invoke-Compile -Root $root).ExitCode | Should -Be 0
        $artifact = Join-Path $root 'generated/browser/pt-BR.sample.js'
        $before = (Get-FileHash $artifact).Hash
        $messages.'sample.counted'.plural.variants.Remove('many')
        [IO.File]::WriteAllText($path, (ConvertTo-Json $translated -Depth 15))
        $bad = Invoke-Compile -Root $root -Update
        $bad.ExitCode | Should -Be 1
        $bad.Output | Should -Match 'many'
        (Get-FileHash $artifact).Hash | Should -BeExactly $before
    }
}

Describe 'Portuguese activation requires all official project values' {
    It 'globalization acceptance: pt-BR pinned plural and all official project values' {
        Import-Module (Join-Path $PSScriptRoot 'Test.Catalog.psm1') -Force -Global -DisableNameChecking
        Import-Module (Join-Path $PSScriptRoot 'Test.LocalizationExchange.psm1') -Force -Global -DisableNameChecking
        $manifest = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'globalization/locale-manifest.json') -Raw | ConvertFrom-Json
        $fixture = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'globalization/fixtures/pt-BR-plurals.json') -Raw | ConvertFrom-Json
        $manifest.locales.'pt-BR'.pluralRule | Should -BeExactly $fixture.rule
        foreach ($row in $fixture.cases) { Get-PluralCategory -Count $row.count -Locale 'pt-BR' | Should -BeExactly $row.category }
        $project = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna-project'
        $rows = @(Get-LocalizationRow -Root $script:RepoRoot -ProjectRoot $project -Locale 'pt-BR' | Where-Object kind -CEQ 'project-scalar')
        $rows.Count | Should -BeGreaterThan 2
        if ($manifest.locales.'pt-BR'.status -ceq 'supported') {
            $sidecar = Get-Content -LiteralPath (Join-Path $project 'globalization/project-locale-source-hashes.json') -Raw | ConvertFrom-Json
            foreach ($row in $rows) {
                $entries = @($sidecar.entries | Where-Object { $_.path -ceq $row.context -and $_.fieldPath -ceq $row.pointer -and $_.locale -ceq 'pt-BR' })
                $entries.Count | Should -Be 1 -Because $row.id
                $entries[0].sourceHash | Should -BeExactly $row.sourceSha256
                $entries[0].PSObject.Properties.Name | Should -Not -Contain 'reviewer'
                # Absent means accepted; the only other value a row may carry is
                # the machine-draft marker.
                $origin = if ($entries[0].PSObject.Properties['origin']) { [string]$entries[0].origin } else { '' }
                $origin | Should -BeIn @('machine', '')
            }
            $check = Invoke-Tool -Tool (Join-Path $script:RepoRoot 'tools/Invoke-ProjectLocaleMap.ps1') -Argument @('-ProjectRoot', $project)
            $check.ExitCode | Should -Be 0 -Because $check.Output
        } else {
            $manifest.locales.'pt-BR'.status | Should -BeExactly 'planned'
            Resolve-SupportedLocale -Tag 'pt-BR' | Should -BeNullOrEmpty
        }
    }
}

Describe 'a planned locale is validated but never shipped' {

    BeforeAll {
        # A translation of the sample domain in xx-XX, whose manifest status
        # the case chooses.
        function New-TranslatedRoot {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture writer; touches only a temp dir removed in AfterAll.')]
            [CmdletBinding()]
            [OutputType([string])]
            param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$MessagesJson,
                  [string]$Status = 'planned')
            $manifest = $script:Manifest.Replace(
                '"qps-Ploc": {',
                '"xx-XX": { "direction": "ltr", "status": "' + $Status + '", "displayName": "Test", "pluralCategories": ["one", "other"], "pluralRule": "one-if-1" },' + "`n    " + '"qps-Ploc": {')
            $root = New-CatalogRoot -Name $Name -DomainJson $script:GoodCatalog -Manifest $manifest
            $directory = Join-Path $root 'catalogs/xx-XX'
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $translation = '{ "schema": "yuruna.catalog/v1", "domain": "sample", "locale": "xx-XX", "messages": { ' + $MessagesJson + ' } }'
            [IO.File]::WriteAllText((Join-Path $directory 'sample.json'), $translation, [Text.UTF8Encoding]::new($false))
            return $root
        }
        $script:StaleHash = '0' * 64
        $script:StalePlain = '"sample.plain": { "sourceHash": "' + $script:StaleHash + '", "message": "XX nothing runs." }'
    }

    It 'compiles a stale planned entry with a warning and no artifact' {
        $root = New-TranslatedRoot -Name 'planned-stale' -MessagesJson $script:StalePlain
        $run = Invoke-Compile -Root $root -Update
        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Output | Should -Match '; wrote \d+ artifact\(s\)\.'
        $run.Output | Should -Not -Match 'Catalog validation failed'
        $run.Output | Should -Match "(?m)^WARN  catalogs/xx-XX/sample\.json: 'sample\.plain' sourceHash is stale"
        Test-Path -LiteralPath (Join-Path $root 'generated/browser/xx-XX.sample.js') | Should -BeFalse
        $shipped = @(Get-ChildItem -LiteralPath (Join-Path $root 'generated') -Recurse -File |
            Where-Object Name -Like 'xx*' | ForEach-Object Name)
        $shipped -join ', ' | Should -BeExactly '' -Because 'a planned locale ships no artifact in any runtime'
        $inventory = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $root 'manifests/inventory.json')))
        @($inventory.entries.locale) | Should -Not -Contain 'xx-XX'
        $set = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $root 'manifests/catalog-set.json')))
        @($set.inputs.PSObject.Properties.Name | Where-Object { $_ -like '*catalogs/xx-XX/sample.json' }).Count |
            Should -Be 1 -Because 'the set still records the planned catalog as an input'
        [string]$set.translations.'xx-XX/sample.plain'.sourceHash | Should -BeExactly $script:StaleHash

        $check = Invoke-Compile -Root $root
        $check.ExitCode | Should -Be 0 -Because $check.Output
        $check.Output | Should -Match '(?m)^WARN  '
    }

    It 'still refuses an unknown key in a planned locale' {
        $root = New-TranslatedRoot -Name 'planned-unknown-key' `
            -MessagesJson ('"sample.missing": { "sourceHash": "' + $script:StaleHash + '", "message": "XX." }')
        $run = Invoke-Compile -Root $root -Update
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Output | Should -Match "translates unknown key 'sample\.missing'"
        $run.Output | Should -Match 'Catalog validation failed'
        Test-Path -LiteralPath (Join-Path $root 'generated') | Should -BeFalse -Because 'a refused run writes nothing'
    }

    It 'removes a planned artifact left by an earlier run' {
        $root = New-TranslatedRoot -Name 'planned-leftover' -MessagesJson $script:StalePlain
        $leftover = Join-Path $root 'generated/browser/xx-XX.sample.js'
        New-Item -ItemType Directory -Path (Split-Path -Parent $leftover) -Force | Out-Null
        [IO.File]::WriteAllText($leftover, "// left by an earlier run`n", [Text.UTF8Encoding]::new($false))
        $run = Invoke-Compile -Root $root -Update
        $run.ExitCode | Should -Be 0 -Because $run.Output
        # The path is reported relative to the repository, and the sandbox is not inside it.
        $run.Output | Should -Match '(?m)^REMOVED .*generated/browser/xx-XX\.sample\.js\r?$'
        Test-Path -LiteralPath $leftover | Should -BeFalse
        $check = Invoke-Compile -Root $root
        $check.ExitCode | Should -Be 0 -Because $check.Output
    }

    It 'points the commit hook''s retranslation hint only at the hard error' {
        # A planned locale may hold a stale draft for a long time; an
        # unrelated refusal must not be blamed on it.
        $hook = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'tools/githooks/pre-commit'))
        $match = [regex]::Match($hook, "if grep -q '([^']+)' `"\`$catalog_tmp/compile\.out`"; then\r?\n\s*echo `"  A stale sourceHash")
        $match.Success | Should -BeTrue -Because 'the hook no longer guards its retranslation hint with a grep this case can read'
        $pattern = [regex]::Escape($match.Groups[1].Value)

        $planned = New-TranslatedRoot -Name 'hint-planned' -MessagesJson ($script:StalePlain +
            ', "sample.missing": { "sourceHash": "' + $script:StaleHash + '", "message": "XX." }')
        $run = Invoke-Compile -Root $planned -Update
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Output | Should -Match '(?m)^WARN  .*sourceHash is stale'
        $run.Output | Should -Match 'Catalog validation failed'
        $run.Output | Should -Not -Match $pattern -Because 'the hint would blame the planned warning for an unknown key'

        $supported = New-TranslatedRoot -Name 'hint-supported' -Status 'supported' -MessagesJson $script:StalePlain
        $run = Invoke-Compile -Root $supported -Update
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Output | Should -Match $pattern -Because 'the hint no longer fires on the stale hash that refused the run'
    }

    It 'keeps a stale sourceHash in a supported locale an error' {
        $messages = $script:StalePlain + ', "sample.counted": { "sourceHash": "' + $script:StaleHash +
            '", "plural": { "variants": { "one": "{count} XX.", "other": "{count} XXs." } } }'
        $root = New-TranslatedRoot -Name 'supported-stale' -Status 'supported' -MessagesJson $messages
        $run = Invoke-Compile -Root $root -Update
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Output | Should -Match "'sample\.plain' sourceHash is stale; expected [0-9a-f]{64}"
        $run.Output | Should -Match 'Catalog validation failed'
        $run.Output | Should -Not -Match '(?m)^WARN '
        Test-Path -LiteralPath (Join-Path $root 'generated') | Should -BeFalse -Because 'a refused run writes nothing'
    }
}
