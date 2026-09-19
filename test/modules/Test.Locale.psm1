<#PSScriptInfo
.VERSION 2026.09.18
.GUID 4263c64f-234d-45a4-b9c8-83aed05f27d9
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization locale matching context i18n
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

# Which language a reader gets, decided once and then carried.
#
# Every runtime that renders text has to answer the same question, and they
# have to answer it the SAME way: a page in one language beside a transcript
# in another is worse than either language alone. So the answer is defined by
# a fixture corpus (globalization/fixtures/locale-matching.json) that this
# module, the browser and Go each run, rather than by three implementations
# that were written from the same paragraph of prose.
#
# The rules that are easy to get wrong, and why they are what they are:
#
#   q=0 is a refusal. RFC 9110 says a zero quality means "not acceptable",
#   so a tag carrying it is removed from consideration rather than ranked
#   last -- otherwise a client that explicitly rejected a language is served
#   it whenever nothing else matches.
#
#   A bare wildcard takes the default. "*" states no preference, so answering
#   it with the first supported tag makes the served language depend on the
#   order of a table nobody thinks of as ordered.
#
#   An undeclared region falls back. pt-AO is not pt-BR: guessing that any
#   Portuguese is Brazilian Portuguese hands a reader a dialect no reviewer
#   approved. Only aliases the manifest declares are followed.
#
#   The resolved tag names a FILE. It is matched against the supported set and
#   never used as a path fragment, because the input reaching this function
#   arrives from an HTTP header.
#
# The context this produces is immutable and scoped to one cycle, one command
# or one request. There is deliberately no process-global "current locale":
# a service answering two readers at once must not have one.

$script:LocaleManifest = $null

function Get-LocaleManifest {
    <#
    .SYNOPSIS
        The supported locales, aliases and bounds, read once per process.
    .DESCRIPTION
        Loaded lazily and cached: a command that renders no text pays nothing,
        and a command that renders a thousand messages reads this once.
    .PARAMETER Path
        Override the manifest location. Used by tests; callers pass nothing.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Path)

    if (-not $Path -and $script:LocaleManifest) { return $script:LocaleManifest }

    if (-not $Path) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $Path = Join-Path $repoRoot 'globalization/locale-manifest.json'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Locale manifest not found: $Path"
    }

    # An explicit decoder: the manifest is UTF-8 and carries display names in
    # their own language, and the default encoding differs between PS 5.1 and
    # PS 7.
    $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
    $raw = ConvertFrom-Json -InputObject $text

    $supported = @()
    foreach ($p in $raw.locales.PSObject.Properties) {
        if ($p.Value.status -eq 'supported') { $supported += $p.Name }
    }
    $aliases = @{}
    if ($raw.aliases) {
        foreach ($p in $raw.aliases.PSObject.Properties) { $aliases[$p.Name.ToLowerInvariant()] = $p.Value }
    }
    $direction = @{}
    foreach ($p in $raw.locales.PSObject.Properties) { $direction[$p.Name] = [string]$p.Value.direction }

    # Separators and plural rules are declared here rather than read from each
    # runtime's own locale database. The browser floor has no Intl to read one
    # from, and the ICU behind .NET shifts between releases, so a number that
    # crossed from a transcript to a page would be grouped one way in one place
    # and another way in the other. One table, three runtimes.
    $numberFormat = @{}
    $pluralRule = @{}
    foreach ($p in $raw.locales.PSObject.Properties) {
        $nf = $p.Value.numberFormat
        if ($nf) {
            $numberFormat[$p.Name] = @{
                Group     = [string]$nf.group
                Decimal   = [string]$nf.decimal
                GroupSize = if ($nf.groupSize) { [int]$nf.groupSize } else { 3 }
            }
        }
        if ($null -ne $p.Value.pluralRule) { $pluralRule[$p.Name] = [string]$p.Value.pluralRule }
    }

    $manifest = @{
        Default          = [string]$raw.default
        Supported        = $supported
        Aliases          = $aliases
        Direction        = $direction
        NumberFormat     = $numberFormat
        PluralRule       = $pluralRule
        MaxTagLength     = if ($raw.maxTagLength) { [int]$raw.maxTagLength } else { 35 }
        MaxHeaderLength  = if ($raw.maxHeaderLength) { [int]$raw.maxHeaderLength } else { 512 }
    }
    if (-not $PSBoundParameters.ContainsKey('Path')) { $script:LocaleManifest = $manifest }
    return $manifest
}

function ConvertTo-CanonicalLocaleTag {
    <#
    .SYNOPSIS
        A tag in the one spelling everything else compares against, or '' when
        it is not a tag at all.
    .DESCRIPTION
        Underscores become hyphens (process cultures and hand-edited config
        arrive POSIX-style), the language subtag lowercases and the region
        subtag uppercases. Anything that is not letters, digits and hyphens
        within the length bound is refused outright rather than repaired --
        this value goes on to select a file, and a repaired path separator is
        still a path separator.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Tag, [int]$MaxLength = 35)

    $t = "$Tag".Trim().Replace('_', '-')
    if (-not $t) { return '' }
    if ($t.Length -gt $MaxLength) { return '' }
    if ($t -notmatch '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$') { return '' }

    $parts = $t.Split('-')
    $out = $parts[0].ToLowerInvariant()
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $p = $parts[$i]
        # A two-letter subtag in second position is a region and is upper-cased;
        # a four-letter one is a script and is title-cased. Everything else is
        # left as written.
        if ($p.Length -eq 2) { $out += '-' + $p.ToUpperInvariant() }
        elseif ($p.Length -eq 4) { $out += '-' + $p.Substring(0, 1).ToUpperInvariant() + $p.Substring(1).ToLowerInvariant() }
        else { $out += '-' + $p.ToLowerInvariant() }
    }
    return $out
}

function Resolve-SupportedLocale {
    <#
    .SYNOPSIS
        The supported tag a single requested tag selects, or '' for none.
    .DESCRIPTION
        Exact match first, then an alias the manifest declares. There is no
        prefix fallback on purpose: pt-AO is not pt-BR, and inventing that
        relationship ships a reader a dialect nobody reviewed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Tag, [hashtable]$Manifest)

    if (-not $Manifest) { $Manifest = Get-LocaleManifest }
    $canonical = ConvertTo-CanonicalLocaleTag -Tag $Tag -MaxLength $Manifest.MaxTagLength
    if (-not $canonical) { return '' }

    foreach ($s in $Manifest.Supported) {
        if ([string]::Equals($s, $canonical, [StringComparison]::OrdinalIgnoreCase)) { return $s }
    }
    $alias = $Manifest.Aliases[$canonical.ToLowerInvariant()]
    if ($alias) {
        foreach ($s in $Manifest.Supported) {
            if ([string]::Equals($s, $alias, [StringComparison]::OrdinalIgnoreCase)) { return $s }
        }
    }
    return ''
}

function Select-LocaleDecisionFromHeader {
    <#
    .SYNOPSIS
        The supported tag an Accept-Language header asks for, or '' for none.
    .DESCRIPTION
        Weights decide, not document order. A q of zero removes its tag rather
        than ranking it last, a malformed q rejects its candidate rather than
        retaining the implicit maximum, and a bare wildcard expresses no
        preference and so selects nothing here -- the caller's default answers
        it. Equal weights use ordinal resolved-tag then requested-tag order.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Header, [hashtable]$Manifest)

    if (-not $Manifest) { $Manifest = Get-LocaleManifest }
    $h = "$Header".Trim()
    if (-not $h) { return $null }
    # Bounded before parsing: an oversized header is not a preference.
    if ($h.Length -gt $Manifest.MaxHeaderLength) { return $null }

    $best = @{}
    foreach ($part in ($h -split ',')) {
        $piece = $part.Trim()
        if (-not $piece) { continue }
        $bits = $piece -split ';'
        $tag = $bits[0].Trim()
        if (-not $tag) { continue }

        $q = 1.0
        $validQ = $true
        $seenQ = $false
        for ($i = 1; $i -lt $bits.Count; $i++) {
            $param = $bits[$i].Trim()
            if ($param -notmatch '^q(?:\s*=|$)') { continue }
            if ($seenQ -or $param -notmatch '^q\s*=\s*(.*)$') {
                $validQ = $false
                break
            }
            $seenQ = $true
            $qualityText = $Matches[1].Trim()
            $parsed = 0.0
            # Invariant parse: a decimal comma host must not read q=0.5 as 5.
            # Validate the HTTP qvalue grammar as well as parsing it. General
            # float shapes such as NaN, 2, an exponent, or a fourth decimal are
            # not legal qualities and must reject this candidate just like text.
            if ($qualityText -cnotmatch '^(?:0(?:\.[0-9]{0,3})?|1(?:\.0{0,3})?)$' -or
                -not [double]::TryParse($qualityText, [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                $validQ = $false
                break
            }
            $q = $parsed
        }
        if (-not $validQ -or $q -le 0) { continue }
        if ($tag -eq '*') { continue }

        $requested = ConvertTo-CanonicalLocaleTag -Tag $tag -MaxLength $Manifest.MaxTagLength
        $resolved = Resolve-SupportedLocale -Tag $tag -Manifest $Manifest
        if (-not $resolved) { continue }
        $candidate = [pscustomobject]@{ Requested = $requested; Resolved = $resolved; Q = $q }
        if (-not $best.ContainsKey($resolved) -or $best[$resolved].Q -lt $q -or
            ($best[$resolved].Q -eq $q -and
             [string]::CompareOrdinal($requested, [string]$best[$resolved].Requested) -lt 0)) {
            $best[$resolved] = $candidate
        }
    }
    if ($best.Count -eq 0) { return $null }

    $winner = $null
    foreach ($candidate in $best.Values) {
        $take = $null -eq $winner -or $candidate.Q -gt $winner.Q
        if (-not $take -and $candidate.Q -eq $winner.Q) {
            $resolvedOrder = [string]::CompareOrdinal($candidate.Resolved, $winner.Resolved)
            $take = $resolvedOrder -lt 0 -or
                ($resolvedOrder -eq 0 -and
                 [string]::CompareOrdinal($candidate.Requested, $winner.Requested) -lt 0)
        }
        if ($take) { $winner = $candidate }
    }
    return $winner
}

function Select-LocaleFromHeader {
    <#
    .SYNOPSIS
        Project an Accept-Language decision to only its supported locale tag.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Header, [hashtable]$Manifest)

    $decision = Select-LocaleDecisionFromHeader -Header $Header -Manifest $Manifest
    return $(if ($decision) { [string]$decision.Resolved } else { '' })
}

function Get-CatalogProvenance {
    <#
    .SYNOPSIS
        Which compiled catalog set a render is happening against.
    .DESCRIPTION
        The compiler records what it produced in a set manifest, and the hash of
        that manifest names the whole set in one value. Carrying it on every
        locale decision is what lets a message a reader complains about be
        traced back to the artifacts that rendered it, across a lab where two
        hosts can be running catalogs built in different weeks.

        Read once per process. A tree with no compiled catalogs answers with
        empty strings rather than raising: a command that renders nothing still
        resolves a locale, and failing here would take it down over provenance
        it was never going to use.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Path)

    if (-not $Path -and $script:CatalogProvenance) { return $script:CatalogProvenance }
    if (-not $Path) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $Path = Join-Path $repoRoot 'globalization/manifests/catalog-set.json'
    }

    $result = @{ Version = ''; Hash = '' }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $bytes = [IO.File]::ReadAllBytes($Path)
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $result.Hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose() }
            $doc = ConvertFrom-Json -InputObject ([Text.UTF8Encoding]::new($false).GetString($bytes))
            $result.Version = [string]$doc.compilerVersion
        } catch {
            Write-Verbose "Catalog provenance unreadable at '$Path': $($_.Exception.Message)"
        }
    }
    if (-not $PSBoundParameters.ContainsKey('Path')) { $script:CatalogProvenance = $result }
    return $result
}

function New-LocaleContext {
    <#
    .SYNOPSIS
        The immutable locale decision for one cycle, command or request.
    .DESCRIPTION
        Precedence, highest first:

          config   the lab-wide `language:` lock, when it is not 'auto'. An
                   unsupported value there resolves to the default but still
                   reports config as the source, so an operator sees that
                   their setting was refused rather than silently ignored.
          user     an explicit persisted web choice, but only while config is
                   absent or `auto`.
          http     Accept-Language, for a served request.
          process  the process UI culture, for a CLI run with no header.
          default  nothing said anything.

        Resolved once, at the boundary. Everything downstream is handed the
        result rather than asking again, so a page, its API responses and the
        transcript of the same run cannot disagree.
    .PARAMETER ConfigLanguage
        The `language:` value from test.config.yml. 'auto' or empty means no lock.
    .PARAMETER AcceptLanguage
        The request header, for an HTTP boundary.
    .PARAMETER UserLanguage
        A validated explicit web preference. Ignored while configuration is
        locked; an unsupported stale value falls through to HTTP/process.
    .PARAMETER ProcessCulture
        The process UI culture. Defaults to the real one.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds and returns a value; changes nothing. New- is the right verb for a factory.')]
    [CmdletBinding()]
    [OutputType([System.Collections.ObjectModel.ReadOnlyDictionary[string, object]])]
    param(
        [AllowEmptyString()][string]$ConfigLanguage,
        [AllowEmptyString()][string]$UserLanguage,
        [AllowEmptyString()][string]$AcceptLanguage,
        [AllowEmptyString()][string]$ProcessCulture,
        [hashtable]$Manifest
    )

    if (-not $Manifest) { $Manifest = Get-LocaleManifest }
    $default = $Manifest.Default
    $requested = ''
    $resolved = ''
    $source = 'default'

    $cfg = "$ConfigLanguage".Trim()
    if ($cfg -and -not [string]::Equals($cfg, 'auto', [StringComparison]::OrdinalIgnoreCase)) {
        $requested = ConvertTo-CanonicalLocaleTag -Tag $cfg -MaxLength $Manifest.MaxTagLength
        $source = 'config'
        $resolved = Resolve-SupportedLocale -Tag $cfg -Manifest $Manifest
    }

    if (-not $resolved -and $source -ne 'config') {
        $fromUser = Resolve-SupportedLocale -Tag $UserLanguage -Manifest $Manifest
        if ($fromUser) {
            $requested = ConvertTo-CanonicalLocaleTag -Tag $UserLanguage -MaxLength $Manifest.MaxTagLength
            $resolved = $fromUser
            $source = 'user'
        }
    }

    if (-not $resolved -and $source -ne 'config') {
        $fromHeader = Select-LocaleDecisionFromHeader -Header $AcceptLanguage -Manifest $Manifest
        if ($fromHeader) {
            $requested = [string]$fromHeader.Requested
            $resolved = [string]$fromHeader.Resolved
            $source = 'http'
        }
    }

    if (-not $resolved -and $source -ne 'config') {
        $culture = if ($PSBoundParameters.ContainsKey('ProcessCulture')) { $ProcessCulture }
                   else { [Globalization.CultureInfo]::CurrentUICulture.Name }
        $fromProcess = Resolve-SupportedLocale -Tag $culture -Manifest $Manifest
        if ($fromProcess) {
            $requested = ConvertTo-CanonicalLocaleTag -Tag $culture -MaxLength $Manifest.MaxTagLength
            $resolved = $fromProcess
            $source = 'process'
        }
    }

    if (-not $resolved) {
        $resolved = $default
        if ($source -ne 'config') { $source = 'default' }
    }

    $direction = $Manifest.Direction[$resolved]
    if (-not $direction) { $direction = 'ltr' }

    $provenance = Get-CatalogProvenance

    # Actually read-only, not read-only by comment. A caller that could edit
    # this could make two halves of one render disagree about the reader's
    # language -- a page in one and the transcript of the same request in
    # another -- which is precisely the failure the type exists to prevent.
    # ReadOnlyDictionary refuses a write; an ordered hashtable only claimed to.
    $fields = [Collections.Generic.Dictionary[string, object]]::new()
    $fields['RequestedTag'] = if ($requested) { $requested } else { $resolved }
    $fields['ResolvedTag'] = $resolved
    $fields['Direction'] = $direction
    $fields['Source'] = $source
    # Timestamps are written in one fixed UTC shape in every locale, so a value
    # read off a page and pasted into a transcript search is the string the
    # transcript holds. Carried rather than assumed, so a surface that needs
    # the reader's own zone has to say so and can be found.
    $fields['TimeZone'] = 'utc'
    # Which compiled catalogs this decision was made against. A rendered
    # message and the artifacts that produced it can otherwise be correlated
    # only by timestamp, which is no correlation at all once a lab is running
    # two versions at once.
    $fields['CatalogVersion'] = $provenance.Version
    $fields['CatalogHash'] = $provenance.Hash

    return [Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($fields)
}

Export-ModuleMember -Function Get-LocaleManifest, Get-CatalogProvenance, ConvertTo-CanonicalLocaleTag,
    Resolve-SupportedLocale, Select-LocaleDecisionFromHeader, Select-LocaleFromHeader, New-LocaleContext
