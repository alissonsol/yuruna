<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42f81d3c-9e04-4a72-b5c8-6d190af7be21
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization catalog compiler utf8 pester
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
    Hold the catalog compiler to rejecting every malformed source it is
    supposed to reject, and to generating the same bytes every time.
.DESCRIPTION
    The compiler is the only thing that reads the source catalogs, and the
    artifacts it writes are what three runtimes load. Two properties make it
    safe to put in a gate, and both are easy to lose silently.

    The first is determinism. If a second run over unchanged sources can
    produce different bytes, then a "generated output is stale" gate reports
    drift that nobody caused, and it gets switched off. So the suite compiles
    twice and compares.

    The second is that it actually refuses bad input. A validator that
    stopped matching would pass every catalog ever written, including the one
    with a placeholder the translator cannot see and the plural form the
    locale needs and does not have. So each rule is handed a source that
    breaks it, in a sandbox tree of its own, and has to fail.

    The encoding half is the same argument. Catalogs are the one tree allowed
    to hold non-ASCII, so the rules that replace the ASCII gate there have to
    be shown to bite: a BOM, an invalid byte, a replacement character, text
    that is not normalized, and a stray control character.

    Run: Invoke-Pester -Path test/modules/Test.CatalogCompiler.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Compiler = Join-Path $script:RepoRoot 'tools' | Join-Path -ChildPath 'Invoke-CatalogCompile.ps1'
$script:Utf8Gate = Join-Path $script:RepoRoot 'tools' | Join-Path -ChildPath 'Test-Utf8Catalog.ps1'

# A child pwsh: the exit code is most of the contract and only survives a
# process boundary.
function Invoke-Tool {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Tool, [string[]]$Argument)
    $argv = @('-NoProfile', '-File', $Tool) + $Argument
    $out = (& pwsh @argv 2>&1 | Out-String)
    return @{ Output = $out; ExitCode = $LASTEXITCODE }
}

$script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-catalog-' + [Guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null

$script:Manifest = @'
{
  "schema": "yuruna.locale-manifest/v1",
  "default": "en-US",
  "locales": {
    "en-US": { "direction": "ltr", "status": "supported", "displayName": "English", "pluralCategories": ["one", "other"], "pluralRule": "one-if-1" },
    "qps-Ploc": { "direction": "ltr", "status": "pseudo", "displayName": "Pseudo", "pluralCategories": ["one", "other"] },
    "qps-Plocm": { "direction": "rtl", "status": "pseudo", "displayName": "Pseudo RTL", "pluralCategories": ["one", "other"] }
  },
  "aliases": {},
  "maxTagLength": 35,
  "maxHeaderLength": 512
}
'@

# A catalog root holding exactly one domain, so a rule can be broken in
# isolation and the failure names that rule and nothing else.
function New-CatalogRoot {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture writer; touches only a temp dir removed in AfterAll.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$DomainJson,
          [string]$Domain = 'sample', [string]$Manifest)
    $root = Join-Path $script:Sandbox $Name
    $catalogs = Join-Path $root 'catalogs/en-US'
    $schemaDir = Join-Path $root 'schema'
    New-Item -ItemType Directory -Path $catalogs -Force | Out-Null
    New-Item -ItemType Directory -Path $schemaDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'globalization/schema/catalog.schema.json') `
        -Destination (Join-Path $schemaDir 'catalog.schema.json') -Force
    $manifestText = if ($Manifest) { $Manifest } else { $script:Manifest }
    [IO.File]::WriteAllText((Join-Path $root 'locale-manifest.json'), $manifestText,
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $catalogs "$Domain.json"), $DomainJson,
        [Text.UTF8Encoding]::new($false))
    return $root
}

# A source that satisfies every rule, used as the baseline the negative
# cases mutate one field at a time.
$script:GoodCatalog = @'
{
  "schema": "yuruna.catalog/v1",
  "domain": "sample",
  "locale": "en-US",
  "messages": {
    "sample.plain": {
      "message": "Nothing is running.",
      "description": "Shown when the queue is empty.",
      "lifecycle": "active"
    },
    "sample.counted": {
      "description": "Summary above the queue.",
      "lifecycle": "active",
      "placeholders": { "count": { "type": "integer", "trust": "internal", "example": 2 } },
      "plural": {
        "selector": "count",
        "variants": { "one": "{count} item queued.", "other": "{count} items queued." }
      }
    }
  }
}
'@

function Invoke-Compile {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Root, [switch]$Update)
    $argument = @('-Root', $Root, '-Quiet')
    if ($Update) { $argument += '-Update' }
    return Invoke-Tool -Tool $script:Compiler -Argument $argument
}
}

AfterAll {
    if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'the shipped catalogs compile and their artifacts are current' {

    It 'reports the generated artifacts as current' {
        $run = Invoke-Tool -Tool $script:Compiler -Argument @('-Quiet')
        Assert-Equal -Expected 0 -Actual $run.ExitCode `
            -Because "a stale artifact means the runtimes load different text from the source:`n$($run.Output)"
    }

    It 'holds the catalog tree to clean UTF-8' {
        $run = Invoke-Tool -Tool $script:Utf8Gate -Argument @('-Quiet')
        Assert-Equal -Expected 0 -Actual $run.ExitCode `
            -Because "the catalogs are excluded from the ASCII gate, so this is the only encoding check they get:`n$($run.Output)"
    }

    It 'reads the translated operator documents and their English sources by default' {
        # Markdown is outside the ASCII gate, so a translated document that
        # picked up a BOM, an unnormalized character, or a replacement character
        # from a bad decode would pass every other gate: ReadAllText succeeds on
        # all three. The default scope is what makes this the check that reads
        # their bytes, so the scope itself is asserted rather than assumed.
        $run = Invoke-Tool -Tool $script:Utf8Gate -Argument @()
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because $run.Output
        foreach ($document in @('docs/operator.md', 'docs/pt-BR/operator.md', 'README.md', 'install/README.md')) {
            Assert-Match -Pattern ([regex]::Escape($document)) -Actual $run.Output `
                "the default encoding scope does not reach $document"
        }
    }
}

Describe 'the compiler generates the same bytes every time' {

    It 'preserves generated artifacts when the catalog root is relative' {
        $root = New-CatalogRoot -Name 'relative-root' -DomainJson $script:GoodCatalog
        $first = Invoke-Compile -Root $root -Update
        Assert-Equal 1 $first.ExitCode $first.Output
        $relative = [IO.Path]::GetRelativePath((Get-Location).Path, $root)
        $run = Invoke-Compile -Root $relative -Update
        Assert-Equal 0 $run.ExitCode $run.Output
        Assert-True (Test-Path -LiteralPath (Join-Path $root 'generated/browser/en-US.sample.js')) 'the orphan sweep preserves wanted artifacts'
        Assert-Equal 0 (Invoke-Compile -Root $relative).ExitCode 'relative and absolute roots agree'
    }

    It 'writes nothing on a second pass over unchanged sources' {
        $root = New-CatalogRoot -Name 'determinism' -DomainJson $script:GoodCatalog
        $first = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 1 -Actual $first.ExitCode 'the first pass has artifacts to write'
        $before = @(Get-ChildItem -LiteralPath $root -Recurse -File |
            Sort-Object FullName | ForEach-Object { (Get-Content -Raw -LiteralPath $_.FullName) })
        $second = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 0 -Actual $second.ExitCode `
            -Because "a compiler that rewrites unchanged output cannot back a staleness gate:`n$($second.Output)"
        $after = @(Get-ChildItem -LiteralPath $root -Recurse -File |
            Sort-Object FullName | ForEach-Object { (Get-Content -Raw -LiteralPath $_.FullName) })
        Assert-StringEqual -Expected ($before -join "`n--`n") -Actual ($after -join "`n--`n") `
            'the second pass changed bytes it should have left alone'
    }

    It 'reports a hand-edited artifact as stale' {
        $root = New-CatalogRoot -Name 'stale' -DomainJson $script:GoodCatalog
        Invoke-Compile -Root $root -Update | Out-Null
        $artifact = Join-Path $root 'generated/browser/en-US.sample.js'
        Add-Content -LiteralPath $artifact -Value '// edited by hand'
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode `
            -Because "generated files are never hand-edited, and the gate is what says so:`n$($run.Output)"
    }

    It 'writes a change that differs only in letter case' {
        $root = New-CatalogRoot -Name 'case-only' -DomainJson $script:GoodCatalog
        Invoke-Compile -Root $root -Update | Out-Null
        $source = Join-Path $root 'catalogs/en-US/sample.json'
        [IO.File]::WriteAllText($source,
            [IO.File]::ReadAllText($source).Replace('Nothing is running.', 'NOTHING is running.'),
            [Text.UTF8Encoding]::new($false))
        $run = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 1 -Actual $run.ExitCode -Because "the recased message has to be written:`n$($run.Output)"
        # Ordinal on purpose: -match would find the old casing and pass.
        $artifact = [IO.File]::ReadAllText((Join-Path $root 'generated/browser/en-US.sample.js'))
        Assert-True $artifact.Contains('NOTHING is running.') 'the artifact kept the old letter case'
        $second = Invoke-Compile -Root $root
        Assert-Equal -Expected 0 -Actual $second.ExitCode -Because "the rewritten set must now be current:`n$($second.Output)"
    }

    It 'skips a dot-named file beside a catalog and in the artifact directories' {
        $root = New-CatalogRoot -Name 'dot-names' -DomainJson $script:GoodCatalog
        # Not JSON at all: compiling it would fail the run.
        [IO.File]::WriteAllText((Join-Path $root 'catalogs/en-US/.#sample.json'), 'editor lock',
            [Text.UTF8Encoding]::new($false))
        # Also a dot-named locale directory, which must not become a locale.
        New-Item -ItemType Directory -Path (Join-Path $root 'catalogs/.old') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'catalogs/.old/sample.json'), 'not a catalog',
            [Text.UTF8Encoding]::new($false))
        $run = Invoke-Compile -Root $root -Update
        # A validation failure also exits 1, so the write is what proves the skip.
        Assert-Equal -Expected 1 -Actual $run.ExitCode -Because "a dot-named file is not a source:`n$($run.Output)"
        Assert-False ($run.Output -match 'Catalog validation failed') 'a dot-named entry was read as a source'
        Assert-True (Test-Path -LiteralPath (Join-Path $root 'generated/browser/en-US.sample.js')) `
            'the catalog next to the dot-named entries was not compiled'
        $keep = Join-Path $root 'generated/browser/.keep'
        [IO.File]::WriteAllText($keep, '', [Text.UTF8Encoding]::new($false))
        $second = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 0 -Actual $second.ExitCode -Because "a dot-named file is not an orphan:`n$($second.Output)"
        Assert-True (Test-Path -LiteralPath $keep) 'the orphan sweep removed a dot-named file'
    }

    It 'reports an artifact whose domain no longer exists' {
        $root = New-CatalogRoot -Name 'orphan' -DomainJson $script:GoodCatalog
        Invoke-Compile -Root $root -Update | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'generated/browser/en-US.sample.js') `
                  -Destination (Join-Path $root 'generated/browser/en-US.retired.js')
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode `
            -Because "an artifact left behind keeps being served:`n$($run.Output)"
        Assert-Match -Pattern 'ORPHAN' -Actual $run.Output 'the report has to name the leftover artifact'
    }

    It 'reports removing an orphan as an update rather than a clean no-op' {
        $root = New-CatalogRoot -Name 'orphan-update' -DomainJson $script:GoodCatalog
        Invoke-Compile -Root $root -Update | Out-Null
        $orphan = Join-Path $root 'generated/browser/en-US.retired.js'
        Copy-Item -LiteralPath (Join-Path $root 'generated/browser/en-US.sample.js') -Destination $orphan

        $run = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 1 -Actual $run.ExitCode `
            -Because "removing an artifact changes generated output and must be visible to the caller:`n$($run.Output)"
        Assert-Match -Pattern 'REMOVED' -Actual $run.Output 'the update report has to name the removed artifact'
        Assert-False (Test-Path -LiteralPath $orphan) 'the orphan should actually be removed'

        $second = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 0 -Actual $second.ExitCode `
            -Because "a second update over the cleaned tree must be a no-op:`n$($second.Output)"
    }
}

Describe 'the compiler refuses a source that would ship a defect' {

    It 'validates the source against the checked-in JSON Schema' {
        # `unexpected` is intentionally not duplicated in the semantic
        # validator. Only reading catalog.schema.json can reject it, which
        # proves the compiler is not merely checking the schema token again.
        $json = $script:GoodCatalog.Replace(
            '"lifecycle": "active"',
            '"lifecycle": "active", "unexpected": true')
        $root = New-CatalogRoot -Name 'real-schema' -DomainJson $json
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'a property forbidden by the real schema has to fail'
        Assert-Match -Pattern 'catalog.schema.json' -Actual $run.Output 'the diagnostic names the schema that rejected it'
        Assert-Match -Pattern 'unexpected' -Actual $run.Output 'the diagnostic names the forbidden property'
    }

    It 'rejects a source scalar combined with a plural branch' {
        $json = $script:GoodCatalog.Replace(
            '      "plural": {',
            "      `"message`": `"This scalar must not be silently dropped.`",`n      `"plural`": {")
        $root = New-CatalogRoot -Name 'message-plus-plural' -DomainJson $json
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'message plus plural was treated as only a plural'
        Assert-Match -Pattern 'catalog\.schema\.json' -Actual $run.Output `
            'the authoritative schema did not reject message plus plural'
    }

    It 'rejects a source scalar combined with a select branch' {
        $json = $script:GoodCatalog.Replace(
            '      "plural": {',
            "      `"message`": `"This scalar must not be silently dropped.`",`n      `"select`": {")
        $root = New-CatalogRoot -Name 'message-plus-select' -DomainJson $json
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'message plus select was treated as only a select'
        Assert-Match -Pattern 'catalog\.schema\.json' -Actual $run.Output `
            'the authoritative schema did not reject message plus select'
    }

    It 'rejects empty and whitespace-only scalar forms' {
        foreach ($case in @(
                @{ Name = 'empty'; Value = '""' },
                @{ Name = 'whitespace'; Value = '"   "' })) {
            $json = $script:GoodCatalog.Replace('"Nothing is running."', $case.Value)
            $root = New-CatalogRoot -Name "blank-scalar-$($case.Name)" -DomainJson $json
            $run = Invoke-Compile -Root $root
            Assert-Equal -Expected 1 -Actual $run.ExitCode `
                -Because "$($case.Name) scalar wording would render as an empty surface"
        }
    }

    It 'rejects empty and whitespace-only variant forms' {
        foreach ($case in @(
                @{ Name = 'empty'; Value = '""' },
                @{ Name = 'whitespace'; Value = '"   "' })) {
            $json = $script:GoodCatalog.Replace('"{count} item queued."', $case.Value)
            $root = New-CatalogRoot -Name "blank-variant-$($case.Name)" -DomainJson $json
            $run = Invoke-Compile -Root $root
            Assert-Equal -Expected 1 -Actual $run.ExitCode `
                -Because "$($case.Name) variant wording would render as an empty surface"
        }
    }

    It 'requires the fallback variant every select renderer uses' {
        $json = $script:GoodCatalog.Replace('      "plural": {', '      "select": {').Replace(
            ', "other": "{count} items queued."', '')
        $root = New-CatalogRoot -Name 'select-without-other' -DomainJson $json
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'a select with no other fallback was publishable'
        Assert-Match -Pattern "no 'other' select form" -Actual $run.Output `
            'the diagnostic did not name the runtime fallback requirement'
    }

    It 'cannot run when the checked-in schema is absent' {
        $root = New-CatalogRoot -Name 'missing-real-schema' -DomainJson $script:GoodCatalog
        Remove-Item -LiteralPath (Join-Path $root 'schema/catalog.schema.json') -Force
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 2 -Actual $run.ExitCode 'missing authority is unavailable, never a clean validation'
        Assert-Match -Pattern 'Catalog schema not found' -Actual $run.Output 'the diagnostic names the missing authority'
    }

    It 'refuses a supported locale that pins no plural rule' {
        # There is no safe default to fall back on. English and Portuguese
        # disagree about zero, so borrowing one language's rule for another
        # produces grammar that reads fine to everyone who does not speak it.
        $manifest = $script:Manifest.Replace('"pluralRule": "one-if-1"', '"pluralRule": null')
        $root = New-CatalogRoot -Name 'no-plural-rule' -DomainJson $script:GoodCatalog -Manifest $manifest
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'a supported locale with no pinned rule has to fail'
        Assert-Match -Pattern 'pins no pluralRule' -Actual $run.Output 'the report names the rule'
    }

    It 'refuses a supported locale that answers for only some of the keys' {
        # A partial catalog does not degrade gracefully: the missing keys render
        # as their own names, in the middle of otherwise translated text. The
        # locale is either reviewed and complete or it is not servable.
        $manifest = $script:Manifest.Replace(
            '"aliases": {}',
            '"aliases": {}').Replace(
            '"qps-Ploc": { "direction": "ltr", "status": "pseudo"',
            '"pt-BR": { "direction": "ltr", "status": "supported", "displayName": "Portuguese", "pluralCategories": ["one", "other"], "pluralRule": "one-if-1" },
    "qps-Ploc": { "direction": "ltr", "status": "pseudo"')
        $root = New-CatalogRoot -Name 'partial-locale' -DomainJson $script:GoodCatalog -Manifest $manifest

        # One key, where the default declares several.
        $partial = @'
{
  "schema": "yuruna.catalog/v1",
  "domain": "sample",
  "locale": "pt-BR",
  "messages": {
    "sample.plain": {
      "message": "Nada em execucao.",
      "description": "Shown when the queue is empty.",
      "lifecycle": "active"
    }
  }
}
'@
        $ptDir = Join-Path $root 'catalogs/pt-BR'
        New-Item -ItemType Directory -Path $ptDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $ptDir 'sample.json'), $partial, [Text.UTF8Encoding]::new($false))

        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'a supported locale missing keys has to fail'
        Assert-Match -Pattern 'is missing \d+ key' -Actual $run.Output 'the report counts what is missing'
    }

    It 'refuses a key that sits outside its own domain' {
        $json = $script:GoodCatalog.Replace('"sample.plain"', '"other.plain"')
        $root = New-CatalogRoot -Name 'wrong-domain' -DomainJson $json
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'a key in the wrong domain has to fail'
        Assert-Match -Pattern 'not inside its own domain' -Actual $run.Output 'the report names the rule'
    }

    It 'refuses a message using an argument it never declares' {
        $json = $script:GoodCatalog.Replace('"Nothing is running."', '"Nothing is running for {who}."')
        $root = New-CatalogRoot -Name 'undeclared' -DomainJson $json
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'an undeclared argument has to fail'
        Assert-Match -Pattern 'never declares' -Actual $run.Output 'the report names the argument'
    }

    It 'refuses a declared argument no form uses' {
        $json = $script:GoodCatalog.Replace(
            '"description": "Shown when the queue is empty.",',
            '"description": "Shown when the queue is empty.", "placeholders": { "unused": { "type": "text", "trust": "internal" } },')
        $root = New-CatalogRoot -Name 'unused' -DomainJson $json
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'an argument nothing renders has to fail'
        Assert-Match -Pattern 'no form uses' -Actual $run.Output 'the report names the argument'
    }

    It 'refuses a plural missing a form the locale requires' {
        $json = $script:GoodCatalog.Replace('"one": "{count} item queued.", ', '')
        $root = New-CatalogRoot -Name 'missing-plural' -DomainJson $json
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'a missing plural form has to fail'
        Assert-Match -Pattern "no 'one' plural form" -Actual $run.Output 'the report names the category'
    }

    It 'refuses a message with no description for the translator' {
        $json = $script:GoodCatalog.Replace('"description": "Shown when the queue is empty.",', '')
        $root = New-CatalogRoot -Name 'no-description' -DomainJson $json
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'a message with no context has to fail'
        Assert-Match -Pattern 'no description' -Actual $run.Output 'the report names the rule'
    }

    It 'refuses a deprecated key that names no replacement' {
        $json = $script:GoodCatalog.Replace('"lifecycle": "active"', '"lifecycle": "deprecated"', [StringComparison]::Ordinal)
        $root = New-CatalogRoot -Name 'deprecated' -DomainJson $json
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'a deprecated key with nowhere to go has to fail'
        Assert-Match -Pattern 'names no replacement' -Actual $run.Output 'the report names the rule'
    }

    It 'refuses a message that carries both plural and select' {
        # Emitting one branch and dropping the other would ship wording no
        # reviewer ever saw, so the ambiguity is refused at compile time.
        $json = $script:GoodCatalog.Replace(
            '"plural": {',
            '"select": { "selector": "count", "variants": { "zero": "Nothing queued." } }, "plural": {')
        $root = New-CatalogRoot -Name 'both-branches' -DomainJson $json
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'a message with two branch kinds has to fail'
        Assert-Match -Pattern 'both plural and select' -Actual $run.Output 'the report names the conflict'
    }

    It 'keeps a backslash and a quote intact through the Go artifact' {
        # A Go raw string takes bytes as written. Escaping the JSON before
        # wrapping it would double every escape the encoder produced, and the
        # decoded catalog would carry different text than the source.
        # Written as JSON source: one escaped backslash and two escaped quotes.
        $json = $script:GoodCatalog.Replace(
            '"Nothing is running."',
            '"Path C:\\logs and a \"quoted\" word."')
        $root = New-CatalogRoot -Name 'go-escaping' -DomainJson $json
        $run = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 1 -Actual $run.ExitCode "the fixture should compile:`n$($run.Output)"
        $go = Get-Content -Raw -LiteralPath (Join-Path $root 'generated/go/catalog/enUS_sample.go')
        Assert-Match -Pattern 'C:\\\\logs' -Actual $go `
            'the JSON escape for a backslash must survive unchanged into the raw literal'
        Assert-False ($go -match 'C:\\\\\\\\logs') `
            'the backslash escape was doubled, so the decoded catalog would differ from the source'
    }

    It 'compiles every exclusive form and safely quotes hostile variant keys' {
        $json = @'
{
  "schema": "yuruna.catalog/v1",
  "domain": "sample",
  "locale": "en-US",
  "messages": {
    "sample.plain": {
      "message": "Plain text.",
      "description": "A scalar form.",
      "lifecycle": "active"
    },
    "sample.counted": {
      "description": "A plural form.",
      "lifecycle": "active",
      "placeholders": { "count": { "type": "integer", "trust": "internal", "example": 2 } },
      "plural": {
        "selector": "count",
        "variants": { "one": "{count} item.", "other": "{count} items." }
      }
    },
    "sample.selected": {
      "description": "A select form with property names that require output-language escaping.",
      "lifecycle": "active",
      "placeholders": { "choice": { "type": "token", "trust": "internal", "example": "owner's" } },
      "select": {
        "selector": "choice",
        "variants": {
          "owner's": "Owner choice.",
          "path\\segment": "Path choice.",
          "line\nbreak": "Line choice.",
          "other": "Other choice."
        }
      }
    }
  }
}
'@
        $root = New-CatalogRoot -Name 'exclusive-forms-hostile-keys' -DomainJson $json
        $run = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 1 -Actual $run.ExitCode "the three valid exclusive forms should compile:`n$($run.Output)"

        $psd1 = Join-Path $root 'generated/powershell/en-US.sample.psd1'
        $catalog = Import-PowerShellDataFile -LiteralPath $psd1
        $variantKeys = @($catalog['sample.selected'].variants.Keys)
        Assert-True ($variantKeys -ccontains "owner's") 'the PowerShell key lost its apostrophe'
        Assert-True ($variantKeys -ccontains 'path\segment') 'the PowerShell key lost its backslash'
        Assert-True ($variantKeys -ccontains "line`nbreak") 'the PowerShell key lost its newline'

        $jsPath = Join-Path $root 'generated/browser/en-US.sample.js'
        $js = [IO.File]::ReadAllText($jsPath)
        Assert-True ($js.Contains("'owner\'s':")) 'the JavaScript key apostrophe is not escaped'
        Assert-True ($js.Contains("'path\\segment':")) 'the JavaScript key backslash is not escaped'
        Assert-True ($js.Contains("'line\nbreak':")) 'the JavaScript key newline is not escaped'
        if (Get-Command node -ErrorAction SilentlyContinue) {
            $nodeOutput = (& node $jsPath 2>&1 | Out-String)
            Assert-Equal -Expected 0 -Actual $LASTEXITCODE `
                -Because "a generated key escaped its literal and injected or broke JavaScript:`n$nodeOutput"
        }
    }

    It 'refuses a source that is not the schema it claims' {
        $json = $script:GoodCatalog.Replace('yuruna.catalog/v1', 'yuruna.catalog/v99')
        $root = New-CatalogRoot -Name 'bad-schema' -DomainJson $json
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'an unknown schema version has to fail'
    }

    It 'refuses competing plural and select branches through the real schema' {
        $json = $script:GoodCatalog.Replace(
            '"plural": {',
            '"select": { "selector": "count", "variants": { "zero": "Nothing queued." } }, "plural": {')
        $root = New-CatalogRoot -Name 'competing-forms' -DomainJson $json
        $run = Invoke-Compile -Root $root
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'two selection branches on one key have to fail'
        Assert-Match -Pattern 'catalog\.schema\.json' -Actual $run.Output `
            'the finding must come from the authoritative catalog schema'
    }

    It 'exits 2 when there is no catalog tree to compile at all' {
        $run = Invoke-Compile -Root (Join-Path $script:Sandbox 'no-such-root')
        Assert-Equal -Expected 2 -Actual $run.ExitCode `
            'a missing tree is "could not run", which is not the same answer as "clean"'
    }
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
        Assert-Equal -Expected 1 -Actual $run.ExitCode "a current translation should compile:`n$($run.Output)"
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

Describe 'the generated pseudo-locales expose untranslated text and layout' {

    It 'brackets every message and keeps its arguments intact' {
        $root = New-CatalogRoot -Name 'pseudo' -DomainJson $script:GoodCatalog
        Invoke-Compile -Root $root -Update | Out-Null
        $js = Get-Content -Raw -LiteralPath (Join-Path $root 'generated/browser/qps-Ploc.sample.js')

        Assert-Match -Pattern "\[" -Actual $js 'an expanded string has to be bracketed, or nothing marks it as translated'
        Assert-Match -Pattern '\\u00f3|\\u00ed|\\u00e1|\\u00e9' -Actual $js `
            'the expanded locale only padded English; it did not visibly accent it'
        # The argument descriptor has to survive pseudo-localization, or the
        # pseudo run stops proving anything about the real render path.
        Assert-Match -Pattern "'arg':'count'" -Actual $js 'the plural argument was lost in pseudo-localization'
        Assert-Match -Pattern "'one':" -Actual $js 'the plural forms were lost in pseudo-localization'
        Assert-Match -Pattern "'other':" -Actual $js 'the plural forms were lost in pseudo-localization'
    }

    It 'marks the mirrored locale right-to-left and closes what it opens' {
        $root = New-CatalogRoot -Name 'pseudo-rtl' -DomainJson $script:GoodCatalog
        Invoke-Compile -Root $root -Update | Out-Null
        $js = Get-Content -Raw -LiteralPath (Join-Path $root 'generated/browser/qps-Plocm.sample.js')
        Assert-Match -Pattern '\\u202e' -Actual $js 'the mirrored locale has to force direction'
        Assert-Match -Pattern '\\u202c' -Actual $js 'a direction override that is never closed leaks into the page'
    }

    It 'emits a PowerShell artifact that parses' {
        $root = New-CatalogRoot -Name 'ps-parse' -DomainJson $script:GoodCatalog
        Invoke-Compile -Root $root -Update | Out-Null
        $psd1 = Join-Path $root 'generated/powershell/en-US.sample.psd1'
        $errors = $null
        $tokens = $null
        [System.Management.Automation.Language.Parser]::ParseFile($psd1, [ref]$tokens, [ref]$errors) | Out-Null
        Assert-Equal -Expected 0 -Actual @($errors).Count `
            "the generated data file does not parse: $(@($errors) -join '; ')"
    }

    It 'never pseudo-translates placeholders, URLs, codes or keyboard shortcuts' {
        $json = $script:GoodCatalog.Replace(
            'Nothing is running.',
            'Open https://example.test/a, inspect status.bad_code, press Ctrl+R, and keep {name}.').Replace(
            '"description": "Shown when the queue is empty.",',
            '"description": "Shown when the queue is empty.", "placeholders": { "name": { "type": "text", "trust": "internal", "example": "host" } },')
        $root = New-CatalogRoot -Name 'pseudo-protected' -DomainJson $json
        $run = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 1 -Actual $run.ExitCode "the protected-token fixture should compile:`n$($run.Output)"
        $js = Get-Content -Raw -LiteralPath (Join-Path $root 'generated/browser/qps-Ploc.sample.js')
        foreach ($literal in @('https://example.test/a', 'status.bad_code', 'Ctrl+R', "'arg':'name'")) {
            Assert-True ($js.Contains($literal)) "pseudo generation changed the machine token '$literal'"
        }
    }

    It 'records deterministic input, per-message and byte provenance in the root set' {
        $root = New-CatalogRoot -Name 'set-provenance' -DomainJson $script:GoodCatalog
        Invoke-Compile -Root $root -Update | Out-Null
        $set = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $root 'manifests/catalog-set.json')))
        Assert-True (@($set.inputs.PSObject.Properties).Count -ge 3) 'schema, manifest and source inputs are not all hashed'
        Assert-True ($set.messageSources.'sample.plain'.sourceHash -cmatch '^[0-9a-f]{64}$') `
            'the source wording has no per-message hash'
        Assert-True ($set.messageSources.'sample.counted'.sourceHash -cmatch '^[0-9a-f]{64}$') `
            'the plural source has no per-message hash'
        Assert-True ([long]$set.counts.generatedBytes -gt 0) 'the set records no generated-byte count'
        Assert-Equal -Expected ([int](@($set.artifacts.PSObject.Properties).Count)) `
            -Actual ([int]$set.counts.generatedArtifacts) 'the artifact count does not describe the artifact map'
    }
}

Describe 'the UTF-8 gate refuses what the ASCII gate no longer sees' {

    BeforeAll {
        function New-EncodingSample {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture writer; touches only a temp dir removed in AfterAll.')]
            [CmdletBinding()]
            [OutputType([string])]
            param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][byte[]]$Bytes)
            $dir = Join-Path $script:Sandbox 'encoding'
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $path = Join-Path $dir $Name
            [IO.File]::WriteAllBytes($path, $Bytes)
            return $path
        }
        $script:Utf8 = [Text.UTF8Encoding]::new($false)
    }

    It 'accepts accented text, which is the whole reason this tree is excluded' {
        $path = New-EncodingSample -Name 'accented.json' -Bytes $script:Utf8.GetBytes('{ "a": "sessao concluida com exito" }')
        $run = Invoke-Tool -Tool $script:Utf8Gate -Argument @('-Path', $path, '-Quiet')
        Assert-Equal -Expected 0 -Actual $run.ExitCode "plain UTF-8 must pass:`n$($run.Output)"
    }

    It 'refuses a byte-order mark' {
        $bytes = @([byte]0xEF, [byte]0xBB, [byte]0xBF) + $script:Utf8.GetBytes('{ "a": "b" }')
        $path = New-EncodingSample -Name 'bom.json' -Bytes $bytes
        $run = Invoke-Tool -Tool $script:Utf8Gate -Argument @('-Path', $path, '-Quiet')
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'a BOM has to fail'
        Assert-Match -Pattern 'BOM' -Actual $run.Output 'the report names the BOM'
    }

    It 'refuses a byte sequence that is not UTF-8' {
        $bytes = $script:Utf8.GetBytes('{ "a": "') + @([byte]0xFF, [byte]0xFE) + $script:Utf8.GetBytes('" }')
        $path = New-EncodingSample -Name 'invalid.json' -Bytes $bytes
        $run = Invoke-Tool -Tool $script:Utf8Gate -Argument @('-Path', $path, '-Quiet')
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'an invalid sequence has to fail'
    }

    It 'refuses a replacement character left by an earlier bad decode' {
        $path = New-EncodingSample -Name 'replacement.json' -Bytes $script:Utf8.GetBytes("{ `"a`": `"$([char]0xFFFD)`" }")
        $run = Invoke-Tool -Tool $script:Utf8Gate -Argument @('-Path', $path, '-Quiet')
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'U+FFFD has to fail'
        Assert-Match -Pattern 'FFFD' -Actual $run.Output 'the report names the character'
    }

    It 'refuses text that is not normalized' {
        # 'e' followed by a combining acute renders like the single accented
        # character but compares unequal to it.
        $decomposed = "{ `"a`": `"e$([char]0x0301)`" }"
        $path = New-EncodingSample -Name 'decomposed.json' -Bytes $script:Utf8.GetBytes($decomposed)
        $run = Invoke-Tool -Tool $script:Utf8Gate -Argument @('-Path', $path, '-Quiet')
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'unnormalized text has to fail'
        Assert-Match -Pattern 'NFC' -Actual $run.Output 'the report names normalization'
    }

    It 'refuses a stray control character' {
        $path = New-EncodingSample -Name 'control.json' -Bytes $script:Utf8.GetBytes("{ `"a`": `"b$([char]0x0007)c`" }")
        $run = Invoke-Tool -Tool $script:Utf8Gate -Argument @('-Path', $path, '-Quiet')
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'a control character has to fail'
        Assert-Match -Pattern 'control character' -Actual $run.Output 'the report names the character'
    }

    It 'refuses a bidi run that is opened and never closed' {
        $path = New-EncodingSample -Name 'unclosed-bidi.json' -Bytes $script:Utf8.GetBytes("{ `"a`": `"$([char]0x202E)abc`" }")
        $run = Invoke-Tool -Tool $script:Utf8Gate -Argument @('-Path', $path, '-Quiet')
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'an unclosed override has to fail'
        Assert-Match -Pattern 'unclosed' -Actual $run.Output 'the report names the leak'
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

Describe 'generated PowerShell data preserves literal text safely' {
    It 'keeps argument-only messages and selector forms as arrays in every artifact' {
        $catalog = ConvertFrom-Json -InputObject $script:GoodCatalog -AsHashtable
        $catalog.messages.'sample.plain'.message = '{detail}'
        $catalog.messages.'sample.plain'.placeholders = @{ detail = @{ type = 'detail'; trust = 'external'; example = 'outside text' } }
        $catalog.messages.'sample.counted'.plural.variants = @{ one = '{count}'; other = '{count}' }
        $catalog.messages.'sample.selected' = @{
            description = 'A selected argument-only message.'; lifecycle = 'active'
            placeholders = @{ style = @{ type = 'token'; trust = 'internal'; example = 'compact' }; detail = @{ type = 'detail'; trust = 'external'; example = 'outside text' } }
            select = @{ selector = 'style'; variants = @{ compact = '{detail}'; other = '{detail}' } }
        }
        $root = New-CatalogRoot -Name 'single-segment' -DomainJson (ConvertTo-Json $catalog -Depth 15)
        $null = Invoke-Compile -Root $root -Update
        (Invoke-Compile -Root $root).ExitCode | Should -Be 0
        $table = Import-PowerShellDataFile -Path (Join-Path $root 'generated/powershell/en-US.sample.psd1')
        ($table.'sample.plain' -is [array]) | Should -BeTrue
        ($table.'sample.counted'.variants.one -is [array]) | Should -BeTrue
        ($table.'sample.selected'.variants.compact -is [array]) | Should -BeTrue
        $table.'sample.plain'.Count | Should -Be 1
        $go = [IO.File]::ReadAllText((Join-Path $root 'generated/go/catalog/enUS_sample.go'))
        $json = [regex]::Match($go, '(?s)const DataenUSsample = `(?<json>.*?)`').Groups['json'].Value | ConvertFrom-Json -AsHashtable
        ($json.'sample.plain' -is [array]) | Should -BeTrue
        ($json.'sample.counted'.variants.one -is [array]) | Should -BeTrue
        ($json.'sample.selected'.variants.compact -is [array]) | Should -BeTrue
        Import-Module (Join-Path $PSScriptRoot 'Test.Catalog.psm1') -Force -DisableNameChecking
        Format-CatalogMessage -Key 'sample.plain' -Arguments @{ detail = '<outside>' } -Locale en-US -Root (Join-Path $root 'generated/powershell') | Should -BeExactly '<outside>'
        $javascript = [IO.File]::ReadAllText((Join-Path $root 'generated/browser/en-US.sample.js'))
        $javascript | Should -Match "'sample\.plain':\[\{'arg':'detail'"
        $javascript | Should -Match "'compact':\[\{'arg':'detail'"
    }

    It 'round trips typographic quotes whitespace and expression-shaped text as constants' {
        $value = 'Host' + [char]0x2019 + 's ' + [char]0x201c + 'quoted' + [char]0x201d + ' ' + [char]0x201a + 'low' + [char]0x201b +
            ' ' + [char]0x201e + 'low' + [char]0x201d + "`n  padded `t" + '$([IO.File]::WriteAllText("unexpected", "unsafe"))'
        # No line break or tab, so only a quote character can move this form
        # off the plain single-quoted literal.
        $variant = [char]0x201a + 'low single' + [char]0x201b + ' and ' + [char]0x201e + 'low double' + [char]0x201e
        $catalog = ConvertFrom-Json -InputObject $script:GoodCatalog -AsHashtable
        $catalog.messages.'sample.plain'.message = $value
        $catalog.messages.'sample.counted'.plural.variants.one = $variant
        $root = New-CatalogRoot -Name 'literal-quotes' -DomainJson (ConvertTo-Json $catalog -Depth 12)
        $run = Invoke-Compile -Root $root -Update
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Output | Should -Not -Match 'Catalog validation failed'
        $file = Join-Path $root 'generated/powershell/en-US.sample.psd1'
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
        $table = Import-PowerShellDataFile -Path $file -SkipLimitCheck
        $table.'sample.plain' | Should -BeExactly $value
        $table.'sample.counted'.variants.one | Should -BeExactly $variant
    }

    It 'parses every artifact it writes' {
        # One message per quote character: a character missing from the escape
        # trigger or the escape list then breaks a literal of its own instead
        # of riding along in a form some other character already escaped.
        $quote = @(0x2018, 0x2019, 0x201a, 0x201b, 0x201c, 0x201d, 0x201e)
        $catalog = ConvertFrom-Json -InputObject $script:GoodCatalog -AsHashtable
        $expected = @{}
        foreach ($code in $quote) {
            $key = 'sample.q{0:x4}' -f $code
            $expected[$key] = 'Mark ' + [char]$code + ' here.'
            $catalog.messages[$key] = @{ message = $expected[$key]; description = 'One quote character.'; lifecycle = 'active' }
        }
        $expected['sample.plain'] = 'All ' + (-join @($quote | ForEach-Object { [string][char]$_ })) + ' '' " ` $HOME $(Get-Date)'
        $catalog.messages.'sample.plain'.message = $expected['sample.plain']
        $root = New-CatalogRoot -Name 'parse-every-artifact' -DomainJson (ConvertTo-Json $catalog -Depth 12)
        $run = Invoke-Compile -Root $root -Update
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Output | Should -Match '; wrote \d+ artifact\(s\)\.'
        $run.Output | Should -Not -Match 'Catalog validation failed'
        $check = Invoke-Compile -Root $root
        $check.ExitCode | Should -Be 0 -Because $check.Output

        $psd1 = @(Get-ChildItem -LiteralPath (Join-Path $root 'generated/powershell') -Filter '*.psd1' -File)
        # en-US and both pseudo-locales, which carry the same characters.
        $psd1.Count | Should -Be 3
        foreach ($file in $psd1) {
            $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because "$($file.Name): $(@($errors | ForEach-Object Message) -join '; ')"
        }
        $table = Import-PowerShellDataFile -Path (Join-Path $root 'generated/powershell/en-US.sample.psd1') -SkipLimitCheck
        foreach ($key in $expected.Keys) { $table[$key] | Should -BeExactly $expected[$key] -Because $key }

        if (Get-Command node -ErrorAction SilentlyContinue) {
            foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'generated/browser') -Filter '*.js' -File)) {
                $nodeOutput = (& node --check $file.FullName 2>&1 | Out-String)
                $LASTEXITCODE | Should -Be 0 -Because "$($file.Name): $nodeOutput"
            }
        }
        if (Get-Command gofmt -ErrorAction SilentlyContinue) {
            foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'generated/go/catalog') -Filter '*.go' -File)) {
                $goOutput = (& gofmt -e -l $file.FullName 2>&1 | Out-String)
                $LASTEXITCODE | Should -Be 0 -Because "$($file.Name): $goOutput"
            }
        }
    }

    It 'never writes a PowerShell data file that does not parse' {
        # A select variant name is free text the schema does not constrain,
        # and it reaches the data file as a hashtable key rather than through
        # the string-literal escaper. Whether the emitter escapes it or the
        # parse check refuses the run, a data file that fails to parse must
        # never be written: every lookup in that locale would fail with it.
        $name = 'owner' + [char]0x2019 + 's'
        $catalog = ConvertFrom-Json -InputObject $script:GoodCatalog -AsHashtable
        $catalog.messages.'sample.selected' = @{
            description = 'A select whose variant name holds a typographic apostrophe.'; lifecycle = 'active'
            placeholders = @{ choice = @{ type = 'token'; trust = 'internal'; example = 'other' } }
            select = @{ selector = 'choice'; variants = @{ $name = 'Owner choice.'; other = 'Other choice.' } }
        }
        $root = New-CatalogRoot -Name 'unparseable-key' -DomainJson (ConvertTo-Json $catalog -Depth 12)
        $run = Invoke-Compile -Root $root -Update
        $file = Join-Path $root 'generated/powershell/en-US.sample.psd1'
        if ($run.Output -match 'does not parse') {
            $run.ExitCode | Should -Be 1 -Because $run.Output
            $run.Output | Should -Match 'Catalog validation failed'
            $run.Output | Should -Match 'en-US\.sample\.psd1 does not parse'
            Test-Path -LiteralPath $file | Should -BeFalse -Because 'a refused run must not leave the broken data file behind'
        } else {
            $run.ExitCode | Should -Be 1 -Because $run.Output
            $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because "$(@($errors | ForEach-Object Message) -join '; ')"
            $table = Import-PowerShellDataFile -Path $file -SkipLimitCheck
            @($table.'sample.selected'.variants.Keys) | Should -Contain $name
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
        $run.ExitCode | Should -Be 1 -Because $run.Output
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
        $run.ExitCode | Should -Be 1 -Because $run.Output
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
