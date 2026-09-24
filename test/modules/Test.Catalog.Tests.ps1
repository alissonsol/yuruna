<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42ff5f78-3c96-4742-aa2e-f64ce54e850a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization catalog renderer pester
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
    Hold the PowerShell catalog renderer to reading the compiled artifacts the
    way every other runtime must, and to staying cheap enough for a render loop.
.DESCRIPTION
    This is the first thing in the tree that consumes what the catalog compiler
    emits, so it is also the first proof that the compiled shape is usable at
    all: a plain string for a message with no arguments, an alternating list of
    literal text and typed argument descriptors for one with arguments, and
    variants beside their selector for one that varies by count.

    Two properties matter as much as the rendering itself. The renderer must
    not parse anything -- the compiler already did, which is what allows a
    message to be rendered per transcript line without the cost showing up in
    cycle time. And a domain must be read once per process, not once per
    message, or the same loop turns into file I/O.

    The plural rule is deliberately narrow. Only rules actually pinned for a
    shipped locale are implemented, and an unpinned locale raises rather than
    borrowing English's rule -- Portuguese and English disagree about zero, and
    a borrowed rule produces fluent, confidently wrong grammar that reads fine
    to anyone who does not speak the language.

    One property is about the module rather than the rendering: what importing
    it does to the runspace. The renderer loads the locale module for the
    plural rule and the separators, and that load has to be additive -- a
    caller that already held the locale commands must still hold them
    afterward.

    Run: Invoke-Pester -Path test/modules/Test.Catalog.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Catalog.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Generated = Join-Path $script:RepoRoot 'globalization/generated/powershell'
$script:ModuleDir = $here
}

Describe 'the renderer reads what the compiler emits' {

    It 'loads the shipped domain and finds its keys' {
        $table = Get-CatalogDomain -Locale 'en-US' -Domain 'status'
        Assert-True ($table.Count -ge 5) "the status domain loaded $($table.Count) keys"
        Assert-True ($table.ContainsKey('status.cycle_paused')) 'a known key is missing from the compiled table'
    }

    It 'renders a message that has no arguments' {
        Assert-StringEqual -Expected 'Paused, waiting for resume.' `
            -Actual (Format-CatalogMessage -Key 'status.cycle_paused' -Locale 'en-US') `
            'a literal message should come back verbatim'
    }

    It 'renders a message with a typed argument' {
        # The caller passes a VALUE. A caller that formatted its own number
        # would bake one locale's separators into every locale's output.
        $out = Format-CatalogMessage -Key 'status.cycle_duration' -Arguments @{ elapsed = 5400 } -Locale 'en-US'
        Assert-StringEqual -Expected 'Duration: 1h 30m' -Actual $out 'the duration argument renders through its declared type'
    }

    It 'chooses the plural form from the count' {
        $one = Format-CatalogMessage -Key 'status.host_online_count' -Arguments @{ count = 1 } -Locale 'en-US'
        $many = Format-CatalogMessage -Key 'status.host_online_count' -Arguments @{ count = 4 } -Locale 'en-US'
        Assert-StringEqual -Expected '1 host online.' -Actual $one 'one takes the singular form'
        Assert-StringEqual -Expected '4 hosts online.' -Actual $many 'more than one takes the plural form'
    }

    It 'places an external value without interpreting it' {
        # Third-party text is shown as given and never parsed back into state.
        $out = Format-CatalogMessage -Key 'status.external_detail' `
            -Arguments @{ detail = 'Connection refused' } -Locale 'en-US'
        Assert-StringEqual -Expected 'The tool reported: Connection refused' -Actual $out `
            'the external detail should be placed verbatim inside the framing sentence'
    }

    It 'returns the key itself when a key is missing' {
        # A supported catalog is complete, so this is a build error the compiler
        # already fails on. At run time the surface still has to say something
        # identifiable rather than rendering blank.
        Assert-StringEqual -Expected 'status.no_such_key' `
            -Actual (Format-CatalogMessage -Key 'status.no_such_key' -Locale 'en-US') `
            'a missing key should surface as itself, not as empty text'
    }

    It 'retries the default catalog before returning a missing-locale key' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-catalog-fallback-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            [IO.File]::WriteAllText((Join-Path $root 'en-US.sample.psd1'),
                "@{ 'sample.only_default' = 'Default catalog text' }`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $root 'qps-Ploc.sample.psd1'),
                "@{ }`n", [Text.UTF8Encoding]::new($false))

            Assert-StringEqual -Expected 'Default catalog text' `
                -Actual (Format-CatalogMessage -Key 'sample.only_default' -Locale 'qps-Ploc' -Root $root) `
                'a partial requested-locale table skipped the resident en-US fallback'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'server-rendered catalog markers' {
    BeforeAll {
        $script:HtmlCatalog = Join-Path $TestDrive 'html-catalog'
        [void][IO.Directory]::CreateDirectory($script:HtmlCatalog)
        [IO.File]::WriteAllText((Join-Path $script:HtmlCatalog 'en-US.sample.psd1'),
            '@{ ''sample.text'' = ''<img src=x onerror=alert(1)> & ready''; ''sample.title'' = ''"quoted" <title>''; ''sample.command'' = @(''Run '', @{ arg = ''command''; type = ''token''; trust = ''internal'' }, '' now.'') }')
    }
    It 'escapes catalog text and presentation attributes before first paint' {
        $html = '<button data-i18n="sample.text" data-i18n-title="sample.title" title="old">Original</button>'
        $result = ConvertTo-CatalogHtml -Html $html -Locale en-US -Root $script:HtmlCatalog
        $result | Should -Match '&lt;img src=x onerror=alert\(1\)&gt; &amp; ready'
        $result | Should -Match 'title="&quot;quoted&quot; &lt;title&gt;"'
        $result | Should -Not -Match '<img|>Original<'
    }
    It 'leaves executable content and URL attributes untouched' {
        $scriptText = '<script>var sample = ''<span data-i18n="sample.text">unchanged</span>'';</script>'
        $styleText = '<style>/* <span data-i18n="sample.text">unchanged</span> */</style>'
        $comment = '<!-- <span data-i18n="sample.text">unchanged</span> -->'
        $link = '<a data-i18n-href="sample.text" href="/stable">link</a>'
        $source = $scriptText + $styleText + $comment + $link
        ConvertTo-CatalogHtml -Html $source -Locale en-US -Root $script:HtmlCatalog | Should -BeExactly $source
    }
    It 'retains controls and adds escaped placeholders to void elements' {
        $result = ConvertTo-CatalogHtml -Html '<input data-i18n-placeholder="sample.title" />' -Locale en-US -Root $script:HtmlCatalog
        $result | Should -Match 'placeholder="&quot;quoted&quot; &lt;title&gt;"/>'
        $result | Should -Not -Match '/ placeholder'
    }
    It 'refuses a missing key instead of serving source-language markup as translated' {
        { ConvertTo-CatalogHtml -Html '<span data-i18n="sample.absent">Original</span>' -Locale en-US -Root $script:HtmlCatalog } |
            Should -Throw '*Missing catalog text*'
    }
    It 'decodes static argument JSON once and preserves command bytes as escaped text' {
        $html = '<p data-i18n="sample.command" data-i18n-args="{&quot;command&quot;:&quot;tool --value=\&quot;&lt;x&gt;\&quot; &amp; next&quot;}">Original</p>'
        $result = ConvertTo-CatalogHtml -Html $html -Locale en-US -Root $script:HtmlCatalog
        $result | Should -Match '>Run tool --value=&quot;&lt;x&gt;&quot; &amp; next now\.</p>'
        $result | Should -Not -Match '&amp;lt;|<x>'
        { ConvertTo-CatalogHtml -Html '<p data-i18n="sample.command" data-i18n-args="{broken}">Original</p>' -Locale en-US -Root $script:HtmlCatalog } |
            Should -Throw
    }
}

Describe 'the renderer is cheap enough to sit in a render loop' {

    It 'loads a complete large domain while still refusing executable data files' {
        $catalogRoot = Join-Path $TestDrive 'large-catalog'
        [void][IO.Directory]::CreateDirectory($catalogRoot)
        $entries = @(1..1800 | ForEach-Object { "'large.message_$_' = 'Message $_'" })
        [IO.File]::WriteAllText((Join-Path $catalogRoot 'en-US.large.psd1'), "@{`n" + ($entries -join "`n") + "`n}")
        $table = Get-CatalogDomain -Locale en-US -Domain large -Root $catalogRoot
        $table.Count | Should -Be 1800
        Format-CatalogMessage -Key large.message_1800 -Locale en-US -Root $catalogRoot | Should -BeExactly 'Message 1800'

        $marker = Join-Path $TestDrive 'must-not-exist'
        $escaped = $marker.Replace("'", "''")
        [IO.File]::WriteAllText((Join-Path $catalogRoot 'en-US.executable.psd1'), "@{ 'executable.message' = `$( [IO.File]::WriteAllText('$escaped', 'executed') ) }")
        { Get-CatalogDomain -Locale en-US -Domain executable -Root $catalogRoot -ErrorAction Stop } | Should -Throw
        Test-Path -LiteralPath $marker | Should -BeFalse
    }

    It 'reads a domain once per process, not once per message' {
        $first = Get-CatalogDomain -Locale 'en-US' -Domain 'status'
        $second = Get-CatalogDomain -Locale 'en-US' -Domain 'status'
        Assert-True ([object]::ReferenceEquals($first, $second)) `
            'the domain is being re-read, which puts file I/O inside the render loop'
    }

    It 'renders a thousand messages without re-reading anything' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt 1000; $i++) {
            $null = Format-CatalogMessage -Key 'status.host_online_count' -Arguments @{ count = $i } -Locale 'en-US'
        }
        $sw.Stop()
        # Generous on purpose: this is a smoke test for accidental per-call I/O
        # or per-call parsing, not a benchmark. A regression that reopened the
        # file per message would be orders of magnitude over this.
        Assert-True ($sw.Elapsed.TotalSeconds -lt 10) `
            "1000 renders took $([Math]::Round($sw.Elapsed.TotalSeconds, 2))s, which suggests per-call I/O or parsing"
    }
}

Describe 'the renderer refuses to guess' {

    It 'raises rather than borrow a plural rule it has not pinned' {
        # English and Portuguese disagree about zero. Borrowing one rule for the
        # other language produces grammar that reads fine to anyone who does not
        # speak it, and no test would catch it.
        Assert-Throw { Get-PluralCategory -Locale 'xx-XX' -Count 0 } 'No pinned plural rule' `
            'an unpinned locale must raise rather than silently use the English rule'
        Assert-StringEqual -Expected 'one' -Actual (Get-PluralCategory -Locale 'en-US' -Count 1) 'en-US singular'
        Assert-StringEqual -Expected 'other' -Actual (Get-PluralCategory -Locale 'en-US' -Count 0) 'en-US zero is plural'
    }

    It 'refuses a locale or domain that is not one' {
        # Both are already-resolved values, but they name a file, so the shape
        # is still checked before it reaches a path.
        foreach ($bad in @('../../etc', 'en-US/../..', 'en US')) {
            Assert-Throw { Get-CatalogDomain -Locale $bad -Domain 'status' } 'Not a locale tag' "'$bad' should not reach a path"
        }
        Assert-Throw { Get-CatalogDomain -Locale 'en-US' -Domain '../secrets' } 'Not a domain' 'a domain should not reach a path'
    }

    It 'treats an absent domain as empty rather than failing the caller' {
        # A domain that has not been compiled yet must not take down a command
        # that renders one message from it.
        $table = Get-CatalogDomain -Locale 'en-US' -Domain 'notcompiledyet'
        Assert-Equal -Expected 0 -Actual $table.Count 'an absent domain should load as empty'
    }
}

Describe 'the renderer does not take away what it depends on' {

    It 'leaves the locale commands resolvable in a runspace that loaded them first' {
        # Importing the renderer has to be additive: it may ADD its own
        # commands, never REMOVE the commands of the locale module it loads for
        # the plural rule and the separators. A nested -Force import that is
        # not -Global breaks precisely that half -- it re-homes the locale
        # module into the renderer's private scope, so the renderer's own
        # functions go on working while the importer silently loses
        # Get-LocaleManifest and New-LocaleContext. Both imports return
        # normally and write to no stream, so only a resolution probe sees it.
        #
        # A fresh child runspace, not this one. The loss needs the locale
        # module loaded BEFORE the renderer -- the order a long-lived consumer
        # imports in, and the reverse of the order this suite's BeforeAll
        # leaves behind. Probing in place would assert against an order that
        # cannot produce the failure.
        $exe = (Get-Process -Id $PID).Path
        if (-not $exe) { $exe = 'pwsh' }
        if (-not (Get-Command -Name $exe -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'no pwsh executable resolves here to open a fresh runspace with'
            return
        }

        $moduleDir = $script:ModuleDir.Replace("'", "''")
        $child = @"
`$ErrorActionPreference = 'Stop'
# Escape sequences in colored output would land inside the lines read back
# below. `$PSStyle is 7.2 and newer, and touching an absent variable under the
# preference above would end the child before it imported anything.
if (Get-Variable -Name PSStyle -ErrorAction Ignore) { `$PSStyle.OutputRendering = 'PlainText' }
Import-Module (Join-Path '$moduleDir' 'Test.Locale.psm1')  -Force -DisableNameChecking
Import-Module (Join-Path '$moduleDir' 'Test.Catalog.psm1') -Force -DisableNameChecking
foreach (`$name in @('Get-LocaleManifest', 'New-LocaleContext', 'Format-CatalogMessage')) {
    if (-not (Get-Command -Name `$name -ErrorAction SilentlyContinue)) { Write-Output "LOST=`$name" }
}
Write-Output ('RENDERED=' + (Format-CatalogMessage -Key 'status.cycle_paused' -Locale 'en-US'))
Write-Output ('DEFAULT=' + (Get-LocaleManifest).Default)
"@
        $out = & $exe -NoProfile -Command $child 2>&1 | Out-String

        $findings = @()
        foreach ($line in ($out -split "`r?`n")) {
            if ($line -match '^LOST=(?<Command>.+)$') {
                $findings += "$($Matches['Command']) stopped resolving once the renderer was imported"
            }
        }
        Assert-NoFinding $findings @"
importing the renderer removed commands from a runspace that had loaded the
locale module first:
$out
"@

        # Resolution is not the whole contract -- the commands also have to be
        # callable from the importer, which is what a caller actually does.
        Assert-Match -Pattern '(?m)^DEFAULT=\S' -Actual $out `
            "the importer could not call into the locale module afterward:`n$out"
        Assert-Match -Pattern '(?m)^RENDERED=\S' -Actual $out `
            "the renderer's own commands did not survive its own import:`n$out"
    }
}

Describe 'Portuguese numeric cardinal rules' {
    It 'matches the pinned shared zero fraction negative and million corpus' {
        $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $corpus = Get-Content -LiteralPath (Join-Path $root 'globalization/fixtures/pt-BR-plurals.json') -Raw | ConvertFrom-Json
        foreach ($row in $corpus.cases) {
            Get-PluralCategory -Count $row.count -Locale $corpus.locale | Should -BeExactly $row.category
        }
    }
}
