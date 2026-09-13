<#PSScriptInfo
.VERSION 2026.09.13
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
