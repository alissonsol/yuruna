<#PSScriptInfo
.VERSION 2026.09.13
.GUID 422e4357-5c4b-4d6a-a0e1-938418a006fb
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna javascript es5 browser baseline lint
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
    Report ES2015+ syntax and APIs in browser JavaScript that the Yuruna UI
    baseline (Safari iOS 9.0 / Safari 9.0) cannot run.
.DESCRIPTION
    The browser baseline in docs/definition.md is a HARD floor, and the way it
    is broken is silent: an iOS 9 parser rejects a file carrying one arrow
    function outright, so nothing in it runs -- not the statement that used the
    syntax, the whole file. A page then serves its static shell (a header bar,
    an empty tbody) and looks merely empty rather than broken, which is why
    three service UIs drifted a full major version past the floor without
    anyone noticing.

    Nothing else in the repo can catch that. node is not a build dependency and
    is absent on most hosts (see tools/Invoke-JsTest.ps1), and a modern engine
    would parse these files happily anyway -- the failure only exists on the
    engine nobody here runs. So the check is a lexer: it walks each file
    tracking whether it is in code, a comment, a string, a template or a regex
    literal, and reports baseline-breaking constructs found in CODE only. That
    distinction is the whole point -- `// arrow =>` in a comment and 'a => b' in
    a string are not syntax, and a checker that flags them gets switched off.

    Two classes are reported, and both fail the run:

      Syntax  the file does not PARSE on the baseline engine. Fatal to every
              line in it, including the ones that were fine.
      Api     the file parses but the call is missing at runtime. Fatal only to
              the path that reaches it, which makes it the harder one to spot
              by hand. `fetch` is exempt: extension-sdk/webui/assets/
              yuruna.core.js installs an XHR-backed shim before any page script
              runs, the same arrangement test/status/yuruna.common.js has.

    Division and regex literals are told apart by the preceding token, the
    standard heuristic: after a value (identifier, number, `)`, `]`) a slash
    divides, and after an operator or a keyword like `return` it opens a regex.
.PARAMETER Path
    Files or directories to scan. Directories are searched recursively for
    *.js. Defaults to every browser asset directory the services and the status
    pages ship.
.PARAMETER Quiet
    Print only the summary line.
.EXAMPLE
    pwsh -NoProfile -File tools/Invoke-Es5Check.ps1
    Scans every shipped asset; exits non-zero on the first baseline break.
.EXAMPLE
    pwsh -NoProfile -File tools/Invoke-Es5Check.ps1 -Path test/extension/stash-service
    Scans one service while converting it.
.OUTPUTS
    System.String
#>

[CmdletBinding()]
[OutputType([string])]
param(
    [string[]]$Path,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

# The shipped browser assets: the three extension service UIs and the host
# status pages. *.test.js is excluded -- those run under node
# (tools/Invoke-JsTest.ps1) and no page loads one, so the baseline does not
# reach them.
# The roots come from the shared registry rather than from a list kept here.
# A directory named in one tool's private list and missing from another's is a
# file that passes only the check somebody remembered to point at it, and that
# is how a shipped source drops out of a sweep entirely.
if (-not $Path -or $Path.Count -eq 0) {
    $registryPath = Join-Path $RepoRoot 'globalization/manifests/browser-sources.json'
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
        throw "The browser-source registry is missing: $registryPath"
    }
    $registry = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($registryPath))
    $Path = @($registry.roots | ForEach-Object { [string]$_.path })
    if ($Path.Count -eq 0) { throw 'The browser-source registry lists no roots.' }
}

# Keywords after which a slash opens a regex rather than dividing. `of` and
# `await` are here because a file that still has them is exactly what this
# script is looking for, and mis-lexing it would hide the finding.
$RegexAfterWord = @(
    'return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete', 'void',
    'throw', 'case', 'do', 'else', 'yield', 'await'
)

# Parses and runs on the baseline, but outside the ES5-only bar the repo keeps
# (docs/definition.md). Reported honestly rather than as a parse failure.
$BarRules = @(
    @{ Name = 'template literal';      Pattern = $null;                                    Since = 'parses on Safari 9; outside the ES5 bar' }
)

# Fatal to the whole file: the baseline parser rejects it.
$SyntaxRules = @(
    @{ Name = 'arrow function';        Pattern = '=>';                                     Since = 'Safari 10' }
    @{ Name = 'async function';        Pattern = '\basync\b';                              Since = 'Safari 10.1' }
    @{ Name = 'await';                 Pattern = '\bawait\b';                              Since = 'Safari 10.1' }
    @{ Name = 'let declaration';       Pattern = '\blet\s+[A-Za-z_$\[{]';                  Since = 'Safari 10 (sloppy mode)' }
    @{ Name = 'const declaration';     Pattern = '\bconst\s+[A-Za-z_$\[{]';                Since = 'Safari 10 (sloppy mode)' }
    @{ Name = 'spread / rest';         Pattern = '\.\.\.';                                 Since = 'Safari 10' }
    @{ Name = 'for-of';                Pattern = '\bfor\s*\([^;)]*\bof\b';                 Since = 'Safari 10' }
    @{ Name = 'class declaration';     Pattern = '\bclass\s+[A-Za-z_$]';                   Since = 'Safari 10' }
    @{ Name = 'optional chaining';     Pattern = '\?\.';                                   Since = 'Safari 13.1' }
    @{ Name = 'nullish coalescing';    Pattern = '\?\?';                                   Since = 'Safari 13.1' }
    @{ Name = 'exponent operator';     Pattern = '[^*]\*\*[^*]';                           Since = 'Safari 10.1' }
    @{ Name = 'generator function';    Pattern = 'function\s*\*';                          Since = 'Safari 10' }
)

# Parses on the baseline, then throws at the call. `fetch` is deliberately
# absent: yuruna.core.js shims it.
$ApiRules = @(
    @{ Name = 'Object.entries';        Pattern = '\bObject\.entries\b';                    Since = 'Safari 10.1' }
    @{ Name = 'Object.values';         Pattern = '\bObject\.values\b';                     Since = 'Safari 10.1' }
    # Y.append / Y.prepend are the runtime's own appendChild-backed helpers, so
    # the rule looks for the DOM methods of those names on anything else.
    @{ Name = 'Element.append';        Pattern = '(?<!\bY)\.append\s*\(';                  Since = 'Safari 10' }
    @{ Name = 'Element.prepend';       Pattern = '(?<!\bY)\.prepend\s*\(';                 Since = 'Safari 10' }
    @{ Name = 'Element.replaceChildren'; Pattern = '\.replaceChildren\s*\(';               Since = 'Safari 14' }
    @{ Name = 'Element.remove';        Pattern = '\.remove\s*\(\s*\)';                     Since = 'Safari 10' }
    @{ Name = 'String.padStart';       Pattern = '\.padStart\s*\(';                        Since = 'Safari 10' }
    @{ Name = 'String.padEnd';         Pattern = '\.padEnd\s*\(';                          Since = 'Safari 10' }
    @{ Name = 'Array.prototype.flat';  Pattern = '\.flat\s*\(';                            Since = 'Safari 12' }
    @{ Name = 'Array.prototype.findLast'; Pattern = '\.findLast\s*\(';                     Since = 'Safari 15.4' }
    @{ Name = 'URL constructor';       Pattern = '\bnew\s+URL\s*\(';                       Since = 'Safari 10' }
    @{ Name = 'URLSearchParams';       Pattern = '\bnew\s+URLSearchParams\b';               Since = 'Safari 10.1' }
    @{ Name = 'NodeList.forEach';      Pattern = '\bquerySelectorAll\([^)]*\)\.forEach\b';  Since = 'Safari 10' }
    # A page that reads or writes the palette at run time cannot be compiled to
    # the literal fallback Safari 9 needs.  Keep the palette declarative: the
    # resolver sees every value, and the floor and current browser follow the
    # same cascade.
    @{ Name = 'CSSStyleDeclaration.setProperty'; Pattern = '\.setProperty\s*\(';              Since = 'outside the static palette contract' }
    @{ Name = 'CSSStyleDeclaration.getPropertyValue'; Pattern = '\.getPropertyValue\s*\(';    Since = 'outside the static palette contract' }
)

# Present at the floor, and wrong there. These are not post-floor APIs -- a
# Safari 9.0 browser has every one of them -- but each answers in the browser's
# OWN locale and ignores the locale it is handed, so a page served in one
# language renders half its values in another. The result is a page whose
# formatting depends on the reader's device instead of on the language the
# server decided, and nothing on the page says so.
#
# The replacements live in the catalog kernel, which formats from the locale
# manifest: YurunaI18n.formatNumber for a count, formatArgument for a typed
# value, fmtLocal for a wall-clock stamp in a fixed shape.
$LocaleRules = @(
    @{ Name = 'Date/Number.toLocaleString';     Pattern = '\.toLocaleString\s*\(' }
    @{ Name = 'Date.toLocaleDateString';        Pattern = '\.toLocaleDateString\s*\(' }
    @{ Name = 'Date.toLocaleTimeString';        Pattern = '\.toLocaleTimeString\s*\(' }
    @{ Name = 'String.localeCompare';           Pattern = '\.localeCompare\s*\(' }
    @{ Name = 'String.normalize';               Pattern = '\.normalize\s*\(' }
    @{ Name = 'Intl';                           Pattern = '\bIntl\s*\.' }
    # The shared formatters take (value, tag, decimals). A numeric literal in
    # the tag position means the call site swapped the last two arguments: the
    # tag becomes a number, which resolves to nothing and formats in the
    # browser's own locale, and the decimal count becomes a tag string. Nothing
    # throws, so the page renders and only the digits are wrong -- which is the
    # failure the wrapper around these calls exists to prevent.
    @{ Name = 'formatNumber tag/decimals swapped'
       Pattern = '\bformat(?:Number|Argument)\s*\(\s*[^,()]+,\s*-?[0-9]' }
)

# Split-JsLexeme walks one file and returns, per source line, only the text that
# is CODE -- comments, string bodies, template bodies and regex bodies come back
# blanked to spaces so line numbers still line up. A separate list carries the
# ES6 unicode escapes (\u{...}) found INSIDE string and template literals, which
# are a parse error on the baseline even though they are not code.
function Split-JsLexeme {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Text)

    $n = $Text.Length
    $code = [Text.StringBuilder]::new($n)
    $escapes = [Collections.Generic.List[int]]::new()
    $line = 1
    $i = 0
    # The last significant code character and word, for the regex/division call.
    $prevChar = ''
    $prevWord = ''

    while ($i -lt $n) {
        $c = $Text[$i]
        $next = if ($i + 1 -lt $n) { $Text[$i + 1] } else { [char]0 }

        if ($c -eq "`n") { $line++; [void]$code.Append("`n"); $i++; continue }

        # Comments.
        if ($c -eq '/' -and $next -eq '/') {
            while ($i -lt $n -and $Text[$i] -ne "`n") { [void]$code.Append(' '); $i++ }
            continue
        }
        if ($c -eq '/' -and $next -eq '*') {
            [void]$code.Append('  '); $i += 2
            while ($i -lt $n -and -not ($Text[$i] -eq '*' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '/')) {
                if ($Text[$i] -eq "`n") { $line++; [void]$code.Append("`n") } else { [void]$code.Append(' ') }
                $i++
            }
            if ($i -lt $n) { [void]$code.Append('  '); $i += 2 }
            continue
        }

        # String and template literals. The template backtick is itself a
        # finding, recorded here because the lexer is the only place that knows
        # the character opened a literal rather than sitting in one.
        if ($c -eq "'" -or $c -eq '"' -or $c -eq '`') {
            if ($c -eq '`') { $escapes.Add(-$line) }   # negative marks a template
            # A literal collapses to `0`, not to spaces: blanked entirely, a
            # one-argument call reads as a zero-argument one and every
            # `classList.remove('x')` answers the ChildNode.remove() rule.
            [void]$code.Append('0')
            $quote = $c
            $i++
            while ($i -lt $n) {
                $d = $Text[$i]
                if ($d -eq '\') {
                    if ($i + 2 -lt $n -and $Text[$i + 1] -eq 'u' -and $Text[$i + 2] -eq '{') { $escapes.Add($line) }
                    [void]$code.Append('  ')
                    if ($i + 1 -lt $n -and $Text[$i + 1] -eq "`n") { $line++ }
                    $i += 2
                    continue
                }
                if ($d -eq $quote) { [void]$code.Append(' '); $i++; break }
                if ($d -eq "`n") { $line++; [void]$code.Append("`n") } else { [void]$code.Append(' ') }
                $i++
            }
            $prevChar = 'x'; $prevWord = ''
            continue
        }

        # Regex literal, told from division by what came before it.
        if ($c -eq '/') {
            $isRegex = $true
            if ($prevChar -match '[A-Za-z0-9_$)\]]') {
                $isRegex = ($prevWord -ne '' -and $RegexAfterWord -contains $prevWord)
            }
            if ($isRegex) {
                [void]$code.Append(' '); $i++
                $inClass = $false
                while ($i -lt $n) {
                    $d = $Text[$i]
                    if ($d -eq '\') { [void]$code.Append('  '); $i += 2; continue }
                    if ($d -eq '[') { $inClass = $true }
                    elseif ($d -eq ']') { $inClass = $false }
                    elseif ($d -eq '/' -and -not $inClass) { [void]$code.Append(' '); $i++; break }
                    elseif ($d -eq "`n") { $line++ }
                    [void]$code.Append(' '); $i++
                }
                # Flags.
                while ($i -lt $n -and $Text[$i] -match '[a-z]') { [void]$code.Append(' '); $i++ }
                $prevChar = 'x'; $prevWord = ''
                continue
            }
        }

        [void]$code.Append($c)
        if ($c -notmatch '\s') {
            $prevChar = $c
            if ($c -match '[A-Za-z0-9_$]') {
                $start = $i
                while ($start -gt 0 -and $Text[$start - 1] -match '[A-Za-z0-9_$]') { $start-- }
                $prevWord = $Text.Substring($start, $i - $start + 1)
            } else {
                $prevWord = ''
            }
        }
        $i++
    }

    return @{ Code = $code.ToString(); Escapes = $escapes }
}

# A unit is one thing to scan: a whole .js file, or one inline <script> body
# lifted out of a page. They are scanned identically -- a browser does not care
# which container the code arrived in, and neither does the floor.
$units = [Collections.Generic.List[object]]::new()

$targets = [Collections.Generic.List[string]]::new()
foreach ($p in $Path) {
    $full = if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $RepoRoot $p }
    if (-not (Test-Path -LiteralPath $full)) { continue }
    if (Test-Path -LiteralPath $full -PathType Container) {
        Get-ChildItem -LiteralPath $full -Recurse -File -Filter '*.js' |
            Where-Object { $_.Name -notlike '*.test.js' } |
            Sort-Object FullName | ForEach-Object { $targets.Add($_.FullName) }
    } else {
        $targets.Add((Resolve-Path -LiteralPath $full).Path)
    }
}

if ($targets.Count -eq 0) {
    Write-Error "no JavaScript found under: $($Path -join ', ')" -ErrorAction Continue
    exit 2
}

foreach ($file in $targets) {
    $units.Add([pscustomobject]@{
            Label = ([IO.Path]::GetRelativePath($RepoRoot, $file) -replace '\\', '/')
            Text  = (Get-Content -Raw -LiteralPath $file)
        })
}

# The inline producers, unless the caller named explicit paths -- a targeted run
# is asking about those files, not about the whole registered surface.
if (-not $PSBoundParameters.ContainsKey('Path') -and $registry -and $registry.inlineScriptProducers) {
    foreach ($producer in $registry.inlineScriptProducers) {
        $producerPath = Join-Path $RepoRoot ([string]$producer.path)
        if (-not (Test-Path -LiteralPath $producerPath -PathType Leaf)) {
            Write-Error "the registry names an inline-script producer that is not in the tree: $($producer.path)" -ErrorAction Continue
            exit 2
        }
        $producerText = [IO.File]::ReadAllText($producerPath)
        # A block that names a src is a reference, not a body.
        $blocks = [regex]::Matches($producerText, '(?s)<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>')
        $n = 0
        foreach ($block in $blocks) {
            $body = $block.Groups[1].Value
            if (-not $body.Trim()) { continue }
            $n++
            $units.Add([pscustomobject]@{
                    Label = "$($producer.path)#script$n"
                    Text  = $body
                })
        }
        if ($n -eq 0) {
            Write-Error "the registry names $($producer.path) as an inline-script producer, and it carries none" -ErrorAction Continue
            exit 2
        }
    }
}

$findings = [Collections.Generic.List[object]]::new()

foreach ($unit in $units) {
    $rel = $unit.Label
    $text = $unit.Text
    if ($null -eq $text) { continue }
    $lex = Split-JsLexeme -Text $text
    $lines = $lex.Code -split "`n"

    foreach ($rule in $SyntaxRules) {
        for ($k = 0; $k -lt $lines.Count; $k++) {
            if ($lines[$k] -match $rule.Pattern) {
                $findings.Add([pscustomobject]@{
                        File = $rel; Line = $k + 1; Class = 'Syntax'
                        Name = $rule.Name; Since = $rule.Since; Text = $lines[$k].Trim()
                    })
            }
        }
    }
    foreach ($rule in $ApiRules) {
        for ($k = 0; $k -lt $lines.Count; $k++) {
            if ($lines[$k] -match $rule.Pattern) {
                $findings.Add([pscustomobject]@{
                        File = $rel; Line = $k + 1; Class = 'Api'
                        Name = $rule.Name; Since = $rule.Since; Text = $lines[$k].Trim()
                    })
            }
        }
    }
    foreach ($rule in $LocaleRules) {
        for ($k = 0; $k -lt $lines.Count; $k++) {
            if ($lines[$k] -match $rule.Pattern) {
                $findings.Add([pscustomobject]@{
                        File = $rel; Line = $k + 1; Class = 'Locale'
                        Name = $rule.Name; Since = 'locale-blind at the floor'; Text = $lines[$k].Trim()
                    })
            }
        }
    }
    # AbortController landed in iOS 11.1. Constructing one behind a
    # `typeof AbortController` guard is the supported way to use it, so the
    # break is the UNGUARDED construction -- again a property of the file.
    if ($lex.Code -match '\bnew\s+AbortController\b' -and $lex.Code -notmatch 'typeof\s+AbortController') {
        $hit = 0
        for ($k = 0; $k -lt $lines.Count; $k++) {
            if ($lines[$k] -match '\bnew\s+AbortController\b') { $hit = $k + 1; break }
        }
        $findings.Add([pscustomobject]@{
                File = $rel; Line = $hit; Class = 'Api'
                Name = 'AbortController, unguarded'; Since = 'Safari 11.1'; Text = $lines[$hit - 1].Trim()
            })
    }

    # KeyboardEvent.key landed in iOS 10.3. Reading it is fine; reading it with
    # nothing to fall back to is the break, and that is a property of the file,
    # not of the line -- one keyOf() helper covers every comparison in it.
    # Anchored on the conventional event-parameter names rather than on `.key`
    # alone: a sort column's `c.key !== sortCol` is not a keyboard read, and a
    # rule that cannot tell the two apart is one that gets switched off.
    $keyRead = '\b(e|ev|evt|event)\.key\s*(===|!==|==|!=)'
    if ($lex.Code -match $keyRead -and $lex.Code -notmatch 'keyCode') {
        $hit = 0
        for ($k = 0; $k -lt $lines.Count; $k++) {
            if ($lines[$k] -match $keyRead) { $hit = $k + 1; break }
        }
        $findings.Add([pscustomobject]@{
                File = $rel; Line = $hit; Class = 'Api'
                Name = 'KeyboardEvent.key, no keyCode fallback'; Since = 'Safari 10.3'; Text = $lines[$hit - 1].Trim()
            })
    }

    foreach ($e in $lex.Escapes) {
        if ($e -lt 0) {
            $findings.Add([pscustomobject]@{
                    File = $rel; Line = -$e; Class = 'Bar'
                    Name = $BarRules[0].Name; Since = $BarRules[0].Since; Text = ''
                })
        } else {
            $findings.Add([pscustomobject]@{
                    File = $rel; Line = $e; Class = 'Syntax'
                    Name = 'ES6 unicode escape \u{...}'; Since = 'Safari 10'; Text = ''
                })
        }
    }
}

if (-not $Quiet) {
    foreach ($g in ($findings | Group-Object File | Sort-Object Name)) {
        Write-Information "--- $($g.Name)" -InformationAction Continue
        foreach ($f in ($g.Group | Sort-Object Line, Name)) {
            $snippet = if ($f.Text.Length -gt 78) { $f.Text.Substring(0, 78) + '...' } else { $f.Text }
            Write-Information ("  {0,5}  {1,-6} {2,-28} {3}" -f $f.Line, $f.Class, $f.Name, $snippet) -InformationAction Continue
        }
    }
}

$syntax = @($findings | Where-Object Class -EQ 'Syntax').Count
$api = @($findings | Where-Object Class -EQ 'Api').Count
$bar = @($findings | Where-Object Class -EQ 'Bar').Count
$locale = @($findings | Where-Object Class -EQ 'Locale').Count
Write-Information "$($units.Count) unit(s) from $($targets.Count) file(s), $syntax syntax break(s), $api API break(s), $locale locale-blind call(s), $bar outside the ES5 bar" -InformationAction Continue

if ($findings.Count -gt 0) { exit 1 }
exit 0

# Copyright (c) 2019-2026 by Alisson Sol et al.
