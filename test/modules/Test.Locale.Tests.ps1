<#PSScriptInfo
.VERSION 2026.09.24
.GUID 4208b036-072e-4d6f-8fd5-e970879b1912
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization locale matching pester
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
    Run the shared locale-matching corpus against the PowerShell resolver, and
    hold the rules that are easy to get wrong.
.DESCRIPTION
    Three runtimes decide which language a reader gets, and they have to decide
    it identically: a page in one language beside a transcript in another is
    worse than either language alone. So the contract lives in
    globalization/fixtures/locale-matching.json rather than in three
    implementations written from the same paragraph, and this suite runs that
    corpus here. The browser and Go bindings run the same file.

    Every case carries its own reasoning in the fixture, so a failure names the
    rule rather than an expected string. The ones worth stating twice:

      q=0 removes a tag rather than ranking it last, so a client that
      explicitly refused a language is never served it as a last resort.

      A bare wildcard selects the default, not the first supported tag --
      otherwise the served language depends on the order of a table.

      An undeclared region falls back rather than borrowing its language's
      other region, because pt-AO is not pt-BR.

      The resolved tag goes on to name a file, so anything carrying a path
      separator is refused instead of repaired.

    Run: Invoke-Pester -Path test/modules/Test.Locale.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Locale.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:FixturePath = Join-Path $script:RepoRoot 'globalization/fixtures/locale-matching.json'
$script:Corpus = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:FixturePath))

# The corpus declares the world it is written against -- which locales are
# supported, which aliases exist, what the bounds are -- and the resolver is
# fed THAT rather than the live manifest. Two reasons. It keeps the corpus
# portable: the browser and Go bindings run the same file and cannot read this
# repository's manifest. And it keeps the corpus meaningful before pt-BR
# ships: the live manifest marks pt-BR 'planned' because no reviewed pt-BR
# catalog exists yet, and a matcher with only one supported locale cannot
# demonstrate matching at all.
$script:Manifest = @{
    Default         = [string]$script:Corpus.default
    Supported       = @($script:Corpus.supported)
    Aliases         = @{}
    Direction       = @{}
    MaxTagLength    = [int]$script:Corpus.maxTagLength
    MaxHeaderLength = [int]$script:Corpus.maxHeaderLength
}
foreach ($p in $script:Corpus.aliases.PSObject.Properties) {
    $script:Manifest.Aliases[$p.Name.ToLowerInvariant()] = [string]$p.Value
}
foreach ($tag in $script:Manifest.Supported) { $script:Manifest.Direction[$tag] = 'ltr' }
}

Describe 'the shared locale corpus' {

    It 'reads a corpus with cases in it' {
        Assert-True ($script:Corpus.cases.Count -ge 20) `
            "the corpus has only $($script:Corpus.cases.Count) cases, so it is not the shared contract"
    }

    It 'tests against every locale the shipped manifest declares' {
        # The corpus may run ahead of what is shipped -- it has to, or it could
        # not exercise matching before a second locale is reviewed -- but it
        # must not test a locale the project has never heard of, or it would be
        # proving behavior for a tag no manifest will ever produce.
        $live = Get-LocaleManifest
        $declared = @($live.Direction.Keys)
        $findings = @()
        foreach ($tag in $script:Manifest.Supported) {
            if ($declared -notcontains $tag) { $findings += "the corpus tests '$tag', which locale-manifest.json does not declare" }
        }
        Assert-NoFinding $findings 'the corpus and the shipped manifest describe different worlds'
        Assert-StringEqual -Expected $live.Default -Actual $script:Manifest.Default `
            'the corpus and the manifest disagree about the default locale'
    }

    It 'resolves every case the way the corpus says' {
        $findings = @()
        foreach ($case in $script:Corpus.cases) {
            $header = ''
            if ($case.PSObject.Properties.Name -contains 'acceptLanguage') { $header = [string]$case.acceptLanguage }
            if ($case.acceptLanguageRepeat) {
                $header = ([string]$case.acceptLanguageRepeat.unit) * [int]$case.acceptLanguageRepeat.times
            }
            $splat = @{ AcceptLanguage = $header }
            if ($case.PSObject.Properties.Name -contains 'configLanguage') { $splat.ConfigLanguage = [string]$case.configLanguage }
            if ($case.PSObject.Properties.Name -contains 'userLanguage') { $splat.UserLanguage = [string]$case.userLanguage }
            # Always pinned: an unset process culture would make the result
            # depend on the machine the suite runs on.
            $splat.ProcessCulture = if ($case.PSObject.Properties.Name -contains 'processCulture') { [string]$case.processCulture } else { '' }

            $splat.Manifest = $script:Manifest
            $ctx = New-LocaleContext @splat
            if ($ctx.ResolvedTag -ne $case.expect.resolvedTag) {
                $findings += "$($case.name): resolved '$($ctx.ResolvedTag)', corpus says '$($case.expect.resolvedTag)' -- $($case.why)"
            }
            if ($ctx.Source -ne $case.expect.source) {
                $findings += "$($case.name): source '$($ctx.Source)', corpus says '$($case.expect.source)'"
            }
            if ($case.expect.PSObject.Properties.Name -contains 'requestedTag' -and
                $ctx.RequestedTag -cne $case.expect.requestedTag) {
                $findings += "$($case.name): requested '$($ctx.RequestedTag)', corpus says '$($case.expect.requestedTag)'"
            }
        }
        Assert-NoFinding $findings 'the resolver disagrees with the contract every runtime shares'
    }
}

Describe 'the rules a resolver is easy to get wrong' {

    It 'never lets an unsupported tag become a path' {
        # The resolved tag names an asset file, and the input reaching it comes
        # from an HTTP header.
        foreach ($hostile in @('../../etc/passwd', 'pt-BR/../en-US', 'pt-BR%2f..', './pt-BR', 'pt-BR\..\en-US')) {
            $ctx = New-LocaleContext -AcceptLanguage $hostile -ProcessCulture '' -Manifest $script:Manifest
            Assert-Equal -Expected 'en-US' -Actual $ctx.ResolvedTag `
                "'$hostile' resolved to something other than the default"
            Assert-True ($script:Manifest.Supported -contains $ctx.ResolvedTag) `
                "'$hostile' produced a tag that is not in the supported set"
        }
    }

    It 'canonicalizes a tag without inventing one' {
        Assert-StringEqual -Expected 'pt-BR' -Actual (ConvertTo-CanonicalLocaleTag -Tag 'pt_br') 'underscore and case'
        Assert-StringEqual -Expected 'pt-BR' -Actual (ConvertTo-CanonicalLocaleTag -Tag '  PT-br ') 'surrounding space'
        Assert-StringEqual -Expected 'zh-Hans-CN' -Actual (ConvertTo-CanonicalLocaleTag -Tag 'ZH-HANS-cn') 'script subtag is title-cased'
        foreach ($bad in @('', ' ', '..', 'p', 'pt-', '-BR', 'pt BR', 'pt;BR')) {
            Assert-StringEqual -Expected '' -Actual (ConvertTo-CanonicalLocaleTag -Tag $bad) `
                "'$bad' should be refused, not repaired"
        }
    }

    It 'does not borrow another region of the same language' {
        Assert-StringEqual -Expected '' -Actual (Resolve-SupportedLocale -Tag 'pt-AO' -Manifest $script:Manifest) `
            'an undeclared region must not inherit pt-BR'
        Assert-StringEqual -Expected 'pt-BR' -Actual (Resolve-SupportedLocale -Tag 'pt-PT' -Manifest $script:Manifest) `
            'a region the manifest DOES declare must resolve'
    }

    It 'produces a context whose fields are all populated' {
        $ctx = New-LocaleContext -AcceptLanguage 'pt-BR' -ProcessCulture '' -Manifest $script:Manifest
        foreach ($field in @('RequestedTag', 'ResolvedTag', 'Direction', 'Source')) {
            Assert-True ([bool]$ctx[$field]) "the context has no $field"
        }
        Assert-StringEqual -Expected 'ltr' -Actual $ctx.Direction 'pt-BR is left-to-right per the manifest'
    }

    It 'carries everything a render needs to be reproduced' {
        # A decision that named only the language would leave a rendered
        # message impossible to trace: which catalogs produced it, and in what
        # time zone its stamps were written, are part of the answer.
        $ctx = New-LocaleContext -AcceptLanguage 'pt-BR' -ProcessCulture '' -Manifest $script:Manifest
        foreach ($field in @('RequestedTag', 'ResolvedTag', 'Direction', 'Source', 'TimeZone', 'CatalogVersion', 'CatalogHash')) {
            Assert-True ($ctx.Keys -contains $field) "the context carries no $field"
        }
        Assert-StringEqual -Expected 'utc' -Actual ([string]$ctx.TimeZone) `
            'timestamps are written in UTC in every locale, and the context should say so'
        Assert-True ([bool]$ctx.CatalogHash) 'the context names no catalog set, so a render cannot be traced to its artifacts'
        Assert-True ($ctx.CatalogHash -cmatch '^[0-9a-f]{64}$') 'the catalog hash is not a hash'
    }

    It 'refuses to be edited after it is decided' {
        # The whole point of resolving once. A caller that could edit this could
        # make two halves of one render disagree about the reader's language --
        # a page in one and the transcript of the same request in another.
        $ctx = New-LocaleContext -AcceptLanguage 'pt-BR' -ProcessCulture '' -Manifest $script:Manifest
        $threw = $false
        try { $ctx['ResolvedTag'] = 'en-US' } catch { $threw = $true }
        Assert-True $threw 'the context accepted a write; it is read-only only by comment'
        Assert-StringEqual -Expected 'pt-BR' -Actual ([string]$ctx.ResolvedTag) 'the write went through'
    }

    It 'names the catalog set the same way twice in one process' {
        # Provenance that changed between two renders in one command would be
        # worse than none: it would look like the catalogs moved underfoot.
        $a = Get-CatalogProvenance
        $b = Get-CatalogProvenance
        Assert-StringEqual -Expected $a.Hash -Actual $b.Hash 'the catalog hash is not stable within a process'
        Assert-StringEqual -Expected $a.Version -Actual $b.Version 'the catalog version is not stable within a process'
    }

    It 'resolves a locale even where no catalogs have been compiled' {
        # A command that renders nothing still resolves a locale. Failing over
        # provenance it was never going to use would take it down for nothing.
        $missing = Join-Path ([IO.Path]::GetTempPath()) ('no-catalog-' + [Guid]::NewGuid().ToString('N') + '.json')
        $p = Get-CatalogProvenance -Path $missing
        Assert-StringEqual -Expected '' -Actual $p.Hash 'an absent catalog set should read as empty, not raise'
        Assert-StringEqual -Expected '' -Actual $p.Version 'an absent catalog set should read as empty, not raise'
    }

    It 'costs one manifest read per process, not one per resolution' {
        # A resolver that re-read the manifest per message would put file I/O
        # inside the render loop.
        $first = Get-LocaleManifest
        $second = Get-LocaleManifest
        Assert-True ([object]::ReferenceEquals($first, $second)) `
            'the manifest is being re-read rather than cached for the process'
    }
}
