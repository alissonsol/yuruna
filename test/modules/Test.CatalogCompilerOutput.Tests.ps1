<#PSScriptInfo
.VERSION 2026.10.26
.GUID 42983c1f-31e3-40bb-a130-e4b666739c19
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
    Hold the catalog compiler to generating the same bytes every time, pseudo
    locales that expose untranslated text, and PowerShell data that keeps
    literal text safe.
.DESCRIPTION
    Part of the catalog compiler suites: Test.CatalogCompiler.Tests.ps1
    holds their setup and says what they protect.

    Run: Invoke-Pester -Path test/modules/Test.CatalogCompilerOutput.Tests.ps1
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

Describe 'the compiler generates the same bytes every time' {

    It 'compiles a literal with an empty placeholder declaration alongside named placeholders' {
        $json = $script:GoodCatalog.Replace(
            '"description": "Shown when the queue is empty.",',
            '"description": "Shown when the queue is empty.", "placeholders": {},')
        $root = New-CatalogRoot -Name 'empty-placeholders' -DomainJson $json
        $run = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because "the first pass compiles:`n$($run.Output)"
        Assert-Match -Pattern '(?m)^WROTE ' -Actual $run.Output 'the first pass writes artifacts'
        Assert-False ($run.Output -match 'Catalog validation failed') 'an empty declaration names no unused placeholder'
        $catalog = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'generated/powershell/en-US.sample.psd1')
        Assert-StringEqual 'Nothing is running.' $catalog['sample.plain'] 'a literal needs no placeholder metadata'
        $count = $catalog['sample.counted'].variants.one[0]
        Assert-StringEqual 'count' $count.arg 'the named placeholder still compiles'
        Assert-StringEqual 'integer' $count.type 'the named placeholder keeps its declared type'
        Assert-Equal -Expected 0 -Actual (Invoke-Compile -Root $root).ExitCode 'the generated set is current'
    }

    It 'preserves generated artifacts when the catalog root is relative' {
        $root = New-CatalogRoot -Name 'relative-root' -DomainJson $script:GoodCatalog
        $first = Invoke-Compile -Root $root -Update
        Assert-Equal 0 $first.ExitCode $first.Output
        $relative = [IO.Path]::GetRelativePath((Get-Location).Path, $root)
        $run = Invoke-Compile -Root $relative -Update
        Assert-Equal 0 $run.ExitCode $run.Output
        Assert-True (Test-Path -LiteralPath (Join-Path $root 'generated/browser/en-US.sample.js')) 'the orphan sweep preserves wanted artifacts'
        Assert-Equal 0 (Invoke-Compile -Root $relative).ExitCode 'relative and absolute roots agree'
    }

    It 'writes nothing on a second pass over unchanged sources' {
        $root = New-CatalogRoot -Name 'determinism' -DomainJson $script:GoodCatalog
        $first = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 0 -Actual $first.ExitCode 'the first pass compiles'
        Assert-Match -Pattern '(?m)^WROTE ' -Actual $first.Output 'the first pass has artifacts to write'
        $before = @(Get-ChildItem -LiteralPath $root -Recurse -File |
            Sort-Object FullName | ForEach-Object { (Get-Content -Raw -LiteralPath $_.FullName) })
        $second = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 0 -Actual $second.ExitCode `
            -Because "a compiler that rewrites unchanged output cannot back a staleness gate:`n$($second.Output)"
        Assert-False ($second.Output -match '(?m)^WROTE ') 'the second pass names nothing it wrote'
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
        Assert-Equal -Expected 3 -Actual $run.ExitCode `
            -Because "generated files are never hand-edited, and the gate is what says so:`n$($run.Output)"
    }

    # The browser artifact is also inlined into a <script> on the self-contained
    # pages; text that closes the script would end it there.
    It 'writes no character that could end an inline script' {
        $root = New-CatalogRoot -Name 'script-safe' -DomainJson $script:GoodCatalog.Replace('Nothing is running.', 'Nothing is running.</script><!--x-->&')
        $run = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because "the catalog has to compile:`n$($run.Output)"
        $artifact = [IO.File]::ReadAllText((Join-Path $root 'generated/browser/en-US.sample.js'))
        Assert-True $artifact.Contains('Nothing is running.\x3c/script\x3e\x3c!--x--\x3e\x26') 'the text is escaped, not dropped'
        Assert-False ($artifact -match '</script|<!--') 'no raw sequence can end or derail the inline script'
    }
    # A Turkish or Lithuanian host collates these names differently (Lithuanian
    # sorts y right after i), and the compiler's sorts followed the host culture.
    It 'writes the same bytes whatever culture the host runs in' {
        $catalog = $script:GoodCatalog.Replace('"message": "Nothing is running."', '"message": "{jName} {yName} {aIc} {aib}", "placeholders": { "jName": { "type": "text", "trust": "internal", "example": "j" }, "yName": { "type": "text", "trust": "internal", "example": "y" }, "aIc": { "type": "text", "trust": "internal", "example": "I" }, "aib": { "type": "text", "trust": "internal", "example": "i" } }').Replace('"sample.counted": {', '"sample.jam": { "message": "J.", "description": "Culture fixture.", "lifecycle": "active" }, "sample.yam": { "message": "Y.", "description": "Culture fixture.", "lifecycle": "active" }, "sample.counted": {')
        $plain = New-CatalogRoot -Name 'culture-plain' -DomainJson $catalog
        $run = Invoke-Compile -Root $plain -Update
        Assert-False ($run.Output -match 'Catalog validation failed') "the catalog has to compile:`n$($run.Output)"
        # The artifacts, and the manifests that record each message's source hash.
        $plainFiles = @(foreach ($dir in 'generated', 'manifests') { Get-ChildItem -LiteralPath (Join-Path $plain $dir) -Recurse -File })
        $plainFiles.Count | Should -BeGreaterThan 0
        foreach ($culture in 'tr-TR', 'lt-LT') {
            $root = New-CatalogRoot -Name "culture-$culture" -DomainJson $catalog
            $command = "[Globalization.CultureInfo]::CurrentCulture = '$culture'; [Globalization.CultureInfo]::CurrentUICulture = '$culture'; & '$($script:Compiler)' -Root '$root' -Quiet -Update"
            $null = & pwsh -NoProfile -Command $command 2>&1
            foreach ($file in $plainFiles) {
                $relative = [IO.Path]::GetRelativePath($plain, $file.FullName)
                # The manifests name inputs by paths that include the root's folder.
                $actual = [IO.File]::ReadAllText((Join-Path $root $relative)).Replace((Split-Path -Leaf $root), '<root>')
                $actual | Should -BeExactly ([IO.File]::ReadAllText($file.FullName).Replace((Split-Path -Leaf $plain), '<root>')) -Because "$relative compiled under $culture"
            }
        }
    }
    It 'writes a change that differs only in letter case' {
        $root = New-CatalogRoot -Name 'case-only' -DomainJson $script:GoodCatalog
        Invoke-Compile -Root $root -Update | Out-Null
        $source = Join-Path $root 'catalogs/en-US/sample.json'
        [IO.File]::WriteAllText($source,
            [IO.File]::ReadAllText($source).Replace('Nothing is running.', 'NOTHING is running.'),
            [Text.UTF8Encoding]::new($false))
        $run = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because "the recased message has to be written:`n$($run.Output)"
        Assert-Match -Pattern '(?m)^WROTE ' -Actual $run.Output 'the recased message is written'
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
        # A dot-named file read as a source would fail validation, which exits 1.
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because "a dot-named file is not a source:`n$($run.Output)"
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
        Assert-Equal -Expected 3 -Actual $run.ExitCode `
            -Because "an artifact left behind keeps being served:`n$($run.Output)"
        Assert-Match -Pattern 'ORPHAN' -Actual $run.Output 'the report has to name the leftover artifact'
    }

    It 'reports removing an orphan as an update rather than a clean no-op' {
        $root = New-CatalogRoot -Name 'orphan-update' -DomainJson $script:GoodCatalog
        Invoke-Compile -Root $root -Update | Out-Null
        $orphan = Join-Path $root 'generated/browser/en-US.retired.js'
        Copy-Item -LiteralPath (Join-Path $root 'generated/browser/en-US.sample.js') -Destination $orphan

        $run = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 0 -Actual $run.ExitCode `
            -Because "removing an orphan is part of an update that succeeds:`n$($run.Output)"
        # Removing an artifact changes generated output; the line naming it is
        # how the caller sees that.
        Assert-Match -Pattern 'REMOVED' -Actual $run.Output 'the update report has to name the removed artifact'
        Assert-False (Test-Path -LiteralPath $orphan) 'the orphan should actually be removed'

        $second = Invoke-Compile -Root $root -Update
        Assert-Equal -Expected 0 -Actual $second.ExitCode `
            -Because "a second update over the cleaned tree must be a no-op:`n$($second.Output)"
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
        Assert-Equal -Expected 0 -Actual $run.ExitCode "the protected-token fixture should compile:`n$($run.Output)"
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
        $run.ExitCode | Should -Be 0 -Because $run.Output
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
        $run.ExitCode | Should -Be 0 -Because $run.Output
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
            $run.ExitCode | Should -Be 0 -Because $run.Output
            $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because "$(@($errors | ForEach-Object Message) -join '; ')"
            $table = Import-PowerShellDataFile -Path $file -SkipLimitCheck
            @($table.'sample.selected'.variants.Keys) | Should -Contain $name
        }
    }
}
