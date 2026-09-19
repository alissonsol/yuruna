<#PSScriptInfo
.VERSION 2026.09.18
.GUID 422bc4f3-b6dd-4964-868e-1ae5f65db198
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization catalog renderer i18n powershell
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

# Render a message from the compiled catalog, in the locale a run resolved.
#
# The catalog compiler emits a table per locale and domain, already broken into
# the pieces a renderer walks: a message with no arguments is a plain string, a
# message with arguments is an alternating list of literal text and argument
# descriptors, and a message that varies by count carries its variants beside
# the argument that selects them. Nothing here parses a message grammar or
# scans a format string, because the parsing already happened at build time --
# which is what keeps this cheap enough to sit in a per-line transcript loop.
#
# Loading is lazy and cached for the process. A command that renders no text
# pays nothing; a command that renders a thousand messages reads each domain
# once. Import-PowerShellDataFile is the loader on purpose: it parses the file
# in PowerShell's restricted language, so a generated artifact is data and
# cannot execute.
#
# A missing key is a build error, not a runtime one -- a supported catalog is
# complete by definition, and the compiler fails on a gap. At run time the key
# itself is returned so the surface still says something identifiable, and the
# caller sees it in the one place a wrong key can be noticed.

# The plural rule and the number separators come from the locale manifest,
# which this module reads through the resolver that already caches it.
# -Global is load-bearing: without it a nested -Force import re-homes
# Test.Locale into THIS module's private scope and removes its commands from
# the importer's runspace, so a caller that imported Test.Locale first loses
# Get-LocaleManifest / New-LocaleContext the moment it imports this module.
Import-Module (Join-Path $PSScriptRoot 'Test.Locale.psm1') -Global -Force -DisableNameChecking

$script:CatalogCache = @{}
$script:MissingReported = @{}

function Get-CatalogDomain {
    <#
    .SYNOPSIS
        The compiled message table for one locale and domain, loaded once.
    .PARAMETER Locale
        The resolved tag, from New-LocaleContext. Never a raw request value:
        this selects a file.
    .PARAMETER Domain
        The catalog domain, e.g. 'status'.
    .PARAMETER Root
        Override the generated-artifact root. For tests.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Locale,
        [Parameter(Mandatory)][string]$Domain,
        [string]$Root
    )

    $key = "$Locale|$Domain|$Root"
    if ($script:CatalogCache.ContainsKey($key)) { return $script:CatalogCache[$key] }

    if (-not $Root) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $Root = Join-Path $repoRoot 'globalization/generated/powershell'
    }
    # The locale and domain reach this from resolved values, never from a
    # header, but the file name is still built from them -- so refuse anything
    # that is not the shape a tag and a domain take.
    if ($Locale -notmatch '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$') { throw "Not a locale tag: '$Locale'" }
    if ($Domain -notmatch '^[a-z][a-z0-9]*$') { throw "Not a domain: '$Domain'" }

    $path = Join-Path $Root "$Locale.$Domain.psd1"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $script:CatalogCache[$key] = @{}
        return $script:CatalogCache[$key]
    }
    # A complete operator domain exceeds the data-file loader's default
    # hashtable key budget. Removing that size limit keeps its restricted
    # constant-expression evaluation: catalog files still cannot run code.
    $script:CatalogCache[$key] = Import-PowerShellDataFile -LiteralPath $path -SkipLimitCheck
    return $script:CatalogCache[$key]
}

function ConvertTo-CatalogHtml {
    <#
    .SYNOPSIS
        Render explicit text and attribute markers before the document is served.
    .DESCRIPTION
        Catalog text is always escaped. Markers may replace only leaf text or
        presentation attributes; scripts, styles, comments and URL attributes
        are never interpreted as translation instructions.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'MatchEvaluator closures capture the locale and catalog root; the attribute evaluator has the required delegate signature.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Html,
        [Parameter(Mandatory)][string]$Locale, [string]$Root)

    # A delegate closure runs in a dynamic module; keep these commands bound
    # to the catalog module when callers import it into another module scope.
    $getDomain = Get-Command Get-CatalogDomain -ErrorAction Stop
    $formatMessage = Get-Command Format-CatalogMessage -ErrorAction Stop
    $pattern = '(?is)<!--.*?-->|<(?:script|style)\b[^>]*>.*?</(?:script|style)\s*>|<(?<tag>[a-z][a-z0-9]*)\b(?<attributes>[^<>]*\bdata-i18n="(?<key>[a-z][a-z0-9]*\.[a-z0-9_]+)"[^<>]*)>(?<text>[^<]*)</\k<tag>\s*>|<[a-z][a-z0-9]*\b[^<>]*>'
    return [regex]::Replace($Html, $pattern, [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $element = $match.Value
        if ($element -match '^(?is)(?:<!--|<(?:script|style)\b)') { return $element }
        if ($match.Groups['key'].Success) {
            $key = $match.Groups['key'].Value
            $table = & $getDomain -Locale $Locale -Domain $key.Split('.')[0] -Root $Root
            if (-not $table.ContainsKey($key)) { throw "Missing catalog text '$key' for '$Locale'." }
            $arguments = @{}
            $argumentMarker = [regex]::Match($match.Groups['attributes'].Value, '\bdata-i18n-args="([^"]*)"')
            if ($argumentMarker.Success) {
                $arguments = ConvertFrom-Json -InputObject ([Net.WebUtility]::HtmlDecode($argumentMarker.Groups[1].Value)) -AsHashtable
                if ($arguments -isnot [hashtable]) { throw 'Static catalog arguments must be an object.' }
            }
            $text = [Net.WebUtility]::HtmlEncode((& $formatMessage -Key $key -Locale $Locale -Arguments $arguments -Root $Root))
            $element = '<' + $match.Groups['tag'].Value + $match.Groups['attributes'].Value + '>' + $text + '</' + $match.Groups['tag'].Value + '>'
        }
        $tagEnd = $element.IndexOf('>')
        $opening = $element.Substring(0, $tagEnd + 1)
        foreach ($marker in [regex]::Matches($opening, '\bdata-i18n-(title|aria-label|placeholder|alt)="([a-z][a-z0-9]*\.[a-z0-9_]+)"')) {
            $attribute = $marker.Groups[1].Value
            $key = $marker.Groups[2].Value
            $table = & $getDomain -Locale $Locale -Domain $key.Split('.')[0] -Root $Root
            if (-not $table.ContainsKey($key)) { throw "Missing catalog attribute '$key' for '$Locale'." }
            $value = [Net.WebUtility]::HtmlEncode((& $formatMessage -Key $key -Locale $Locale -Root $Root))
            $attributePattern = '(?i)(?<=\s)' + [regex]::Escape($attribute) + '\s*=\s*(?:"[^"]*"|''[^'']*'')'
            $replacement = $attribute + '="' + $value + '"'
            if ([regex]::IsMatch($opening, $attributePattern)) {
                $opening = [regex]::Replace($opening, $attributePattern, [Text.RegularExpressions.MatchEvaluator]{ param($unused) $replacement }.GetNewClosure())
            } else {
                $insertAt = if ($opening.EndsWith('/>')) { $opening.Length - 2 } else { $opening.Length - 1 }
                $opening = $opening.Insert($insertAt, ' ' + $replacement)
            }
        }
        return $opening + $element.Substring($tagEnd + 1)
    }.GetNewClosure())
}

function Get-PluralCategory {
    <#
    .SYNOPSIS
        The CLDR plural category a count takes in a locale.
    .DESCRIPTION
        Only the rules actually pinned for a shipped locale live here. A locale
        whose rule is not pinned is refused rather than guessed: Portuguese and
        English disagree about zero, so borrowing one language's rule for
        another produces fluent, confidently wrong grammar that no test would
        catch. Pinning the remaining rules from a CLDR source is the dependency
        decision the plan tracks separately.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Locale, [Parameter(Mandatory)][double]$Count)

    $rule = (Get-LocaleManifest).PluralRule[$Locale]
    if (-not $rule) { throw "No pinned plural rule for '$Locale'; refusing to guess one." }
    switch ($rule) {
        'one-if-1' { if ($Count -eq 1) { return 'one' } return 'other' }
        'pt-cardinal-cldr46' {
            $absolute = [Math]::Abs($Count)
            if ([Math]::Floor($absolute) -le 1) { return 'one' }
            if ($absolute -gt 0 -and $absolute % 1000000 -eq 0) { return 'many' }
            return 'other'
        }
        default { throw "Plural rule '$rule' for '$Locale' has no implementation here." }
    }
}

function Format-CatalogNumber {
    <#
    .SYNOPSIS
        A number written the way the locale manifest says this locale writes it.
    .DESCRIPTION
        The separators come from the manifest, not from CultureInfo. The same
        number is written by this runtime, by a Go service and by a browser
        with no Intl at all, and the only way those three agree is to read one
        table -- a .NET that grouped from its own ICU would drift from the
        others the next time ICU changed a locale's separators underneath it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Locale,
        [int]$Decimals = 0
    )

    $manifest = Get-LocaleManifest
    $format = $manifest.NumberFormat[$Locale]
    if (-not $format) { $format = $manifest.NumberFormat[$manifest.Default] }
    if (-not $format) { $format = @{ Group = ','; Decimal = '.'; GroupSize = 3 } }

    $number = [double]$Value
    $negative = $number -lt 0
    # Invariant on purpose: this produces the digits, and the separators are
    # then placed from the manifest. Formatting with a culture here would let
    # that culture's separators through into the result.
    $text = [Math]::Abs($number).ToString("F$Decimals", [Globalization.CultureInfo]::InvariantCulture)
    $parts = $text -split '\.'
    $whole = $parts[0]
    $size = if ($format.GroupSize -gt 0) { [int]$format.GroupSize } else { 3 }
    if ($format.Group -and $whole.Length -gt $size) {
        $grouped = ''
        $seen = 0
        for ($i = $whole.Length - 1; $i -ge 0; $i--) {
            $grouped = $whole[$i] + $grouped
            $seen++
            if (($seen % $size) -eq 0 -and $i -gt 0) { $grouped = $format.Group + $grouped }
        }
        $whole = $grouped
    }
    $out = if ($parts.Count -gt 1) { $whole + $format.Decimal + $parts[1] } else { $whole }
    if ($negative) { return "-$out" }
    return $out
}

function Format-CatalogArgument {
    <#
    .SYNOPSIS
        One typed argument, rendered for a reader.
    .DESCRIPTION
        The declared type chooses the formatting, so a caller passes a value
        rather than a pre-formatted string -- a caller that formatted its own
        number would bake one locale's separators into every locale's output.

        This is the subset the shipped catalog uses. The full typed-format
        contract, including units, lists and time zones, is the separate
        formatting work; anything not handled here renders as its invariant
        string rather than guessing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Locale
    )

    if ($null -eq $Value) { return '' }

    switch ($Type) {
        'integer'  { return (Format-CatalogNumber -Value $Value -Locale $Locale -Decimals 0) }
        'decimal'  { return (Format-CatalogNumber -Value $Value -Locale $Locale -Decimals 2) }
        'duration' {
            # Floor, not a cast. PowerShell's [int] ROUNDS, so 5400 seconds --
            # an hour and a half -- would render as "2h 30m": a duration longer
            # than the one that actually elapsed, in the whole-hours part where
            # it is least likely to be questioned.
            $span = [TimeSpan]::FromSeconds([double]$Value)
            if ($span.TotalHours -ge 1) { return ('{0}h {1}m' -f [Math]::Floor($span.TotalHours), $span.Minutes) }
            if ($span.TotalMinutes -ge 1) { return ('{0}m {1}s' -f [Math]::Floor($span.TotalMinutes), $span.Seconds) }
            return ('{0}s' -f [Math]::Floor($span.TotalSeconds))
        }
        'datetime' {
            $when = [datetime]$Value
            # A fixed, locale-independent shape, and the same one the browser
            # kernel writes. A timestamp read off a page and pasted into a
            # transcript search has to be the string the transcript holds.
            return $when.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + ' UTC'
        }
        # An external value is shown as given and never parsed back. Escaping
        # and bidi isolation belong to the surface that renders it, which knows
        # whether it is writing HTML, a console line or a transcript.
        default { return [string]$Value }
    }
}

function Format-CatalogMessage {
    <#
    .SYNOPSIS
        The rendered sentence for a message key, in a resolved locale.
    .PARAMETER Key
        The namespaced key, e.g. 'status.cycle_paused'.
    .PARAMETER Arguments
        Named values for the message's declared arguments. Values, not strings.
    .PARAMETER Locale
        A resolved tag. Pass $context.ResolvedTag.
    .PARAMETER Root
        Override the generated-artifact root. For tests.
    .EXAMPLE
        Format-CatalogMessage -Key 'status.host_online_count' -Arguments @{ count = 3 }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [hashtable]$Arguments = @{},
        [string]$Locale = 'en-US',
        [string]$Root
    )

    $domain = ($Key -split '\.')[0]
    $table = Get-CatalogDomain -Locale $Locale -Domain $domain -Root $Root
    $entry = $table[$Key]
    $renderLocale = $Locale

    if ($null -eq $entry) {
        $defaultLocale = [string](Get-LocaleManifest).Default
        if (-not [string]::Equals($Locale, $defaultLocale, [StringComparison]::Ordinal)) {
            $defaultTable = Get-CatalogDomain -Locale $defaultLocale -Domain $domain -Root $Root
            $entry = $defaultTable[$Key]
            if ($null -ne $entry) { $renderLocale = $defaultLocale }
        }
    }

    if ($null -eq $entry) {
        # Once per key per process: a missing key inside a render loop must not
        # produce one warning per line.
        if (-not $script:MissingReported.ContainsKey("$Locale|$Key")) {
            $script:MissingReported["$Locale|$Key"] = $true
            Write-Verbose "Catalog has no key '$Key' for '$Locale'."
        }
        return $Key
    }

    if ($entry -is [string]) { return $entry }

    if ($entry -is [System.Collections.IDictionary] -and $entry.ContainsKey('kind')) {
        $selector = [string]$entry['selector']
        $chosen = $null
        if ($entry['kind'] -eq 'plural') {
            $count = 0.0
            if ($Arguments.ContainsKey($selector)) { $count = [double]$Arguments[$selector] }
            $category = Get-PluralCategory -Locale $renderLocale -Count $count
            $chosen = $entry['variants'][$category]
            # A locale that requires a category the catalog lacks is a compile
            # error, so reaching here means the table was hand-edited.
            if ($null -eq $chosen) { $chosen = $entry['variants']['other'] }
        } else {
            $value = if ($Arguments.ContainsKey($selector)) { [string]$Arguments[$selector] } else { '' }
            $chosen = $entry['variants'][$value]
            if ($null -eq $chosen) { $chosen = $entry['variants']['other'] }
        }
        if ($null -eq $chosen) { return $Key }
        return (Format-CatalogSegment -Segments $chosen -Arguments $Arguments -Locale $renderLocale)
    }

    return (Format-CatalogSegment -Segments $entry -Arguments $Arguments -Locale $renderLocale)
}

function Format-CatalogSegment {
    <#
    .SYNOPSIS
        Walk one compiled form: literal text, argument, literal text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Segments,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [Parameter(Mandatory)][string]$Locale
    )

    if ($Segments -is [string]) { return $Segments }
    $sb = [Text.StringBuilder]::new()
    foreach ($piece in @($Segments)) {
        if ($piece -is [string]) { [void]$sb.Append($piece); continue }
        if ($piece -is [System.Collections.IDictionary] -and $piece.ContainsKey('arg')) {
            $name = [string]$piece['arg']
            $value = if ($Arguments.ContainsKey($name)) { $Arguments[$name] } else { $null }
            [void]$sb.Append((Format-CatalogArgument -Value $value -Type ([string]$piece['type']) -Locale $Locale))
            continue
        }
        [void]$sb.Append([string]$piece)
    }
    return $sb.ToString()
}

Export-ModuleMember -Function Get-CatalogDomain, ConvertTo-CatalogHtml, Get-PluralCategory, Format-CatalogNumber,
    Format-CatalogArgument, Format-CatalogMessage, Format-CatalogSegment
