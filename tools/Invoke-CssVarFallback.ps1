<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42636266-697e-4051-aee3-5c9df31540a7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna css custom-properties browser baseline generate
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
    Generate the literal palette fallback that precedes every CSS declaration
    using var(), so the pages render on a browser without custom properties.
.DESCRIPTION
    Safari 9.0 has no CSS custom properties, and its failure mode is per
    declaration: a declaration whose value contains var() is invalid at parse
    time, so the engine DROPS it and keeps whatever the cascade held before.
    That is the whole mechanism this script relies on. For

        background: var(--bg-primary);

    it emits

        background: #f9fafb; background: var(--bg-primary);

    An engine without custom properties keeps the literal and drops the second
    declaration. An engine with them parses both, and the later one wins. The
    result is cascade-native: no runtime JavaScript, no extra request, no
    second stylesheet, and nothing to go wrong at load time.

    A literal fallback written INSIDE var(), as in `var(--bg, #fff)`, does not
    help such an engine: it drops the whole declaration without ever reading
    the fallback. Those sites still need a preceding literal, and the in-var
    value is used only when the palette does not define the name.

    Resolution is single-valued because every custom property in this
    repository is defined in a `:root` block, and the only redefinition sits
    behind `@media (prefers-color-scheme: dark)`. That query is far newer than
    custom properties, so an engine that cannot read `var()` can never match
    the dark block either: the bare `:root` values are what such an engine
    would render, and they are what this script resolves against. A definition
    outside a `:root` block would break that reasoning, so the script refuses
    one rather than emitting a fallback that is right in only some scopes.

    Generated fallbacks carry no marker. They are recognized structurally: the
    declaration immediately before a var() declaration, same property, no
    var() of its own. Nothing else in the stylesheets has that shape, so the
    script can rewrite a stale value and leave hand-written fallback-first
    pairs -- the plain-value declaration before an env()/max() one -- alone.

    Sources are not only .css files. The status pages carry inline <style>
    blocks, two Go services build their page as a raw string constant, and the
    generated directory listing lives in a PowerShell here-string. All four
    forms are registered below and transformed in place.

    Exit codes follow the entry-point contract:
        0  Every var() declaration has a current literal fallback.
        1  At least one fallback is missing or stale (-Check), or a file was
           rewritten (-Update).
        2  A source could not be resolved: an unknown custom property, or a
           definition outside a :root block.

.PARAMETER Check
    Report drift without writing. This is the default when neither -Check nor
    -Update is given, so an unadorned run is safe in a gate.
.PARAMETER Update
    Rewrite the registered sources in place.
.PARAMETER Path
    Restrict the run to the registered sources whose repo-relative path
    matches one of these values. Wildcards allowed.
.PARAMETER Source
    Check a file that is not in the registry, resolving against
    -PaletteSource. Use it for a page still being written, and for the
    suite that has to prove this script still fails on a missing fallback.
.PARAMETER PaletteSource
    The stylesheet whose :root defines the names -Source uses. Defaults to
    -Source itself, which is right for a page that carries its own palette.
.PARAMETER Quiet
    Suppress per-source PASS lines; failures and the summary still print.

.EXAMPLE
    pwsh tools/Invoke-CssVarFallback.ps1
    # Reports stale or missing fallbacks; exits 0 / 1.

.EXAMPLE
    pwsh tools/Invoke-CssVarFallback.ps1 -Update
    # Rewrites every registered source, then exits 1 if anything changed.
#>

[CmdletBinding()]
[OutputType([string])]
param(
    [switch]$Check,
    [switch]$Update,
    [string[]]$Path,
    [string]$Source,
    [string]$PaletteSource,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

if (-not $Update) { $Check = $true }

# Every browser CSS source that ships, with the stylesheet whose :root defines
# the names it uses. A page's inline styles and its linked stylesheet form one
# cascade, so they resolve against the same palette; board.css is loaded beside
# the pool-control stylesheet and borrows its palette the same way. The two Go
# pages define and use their own pair in the same constant, so each is its own
# palette source.
# The producers come from the shared registry, not from a list kept here. The
# same 13 rows used to live in this file AND in the floor suite, which is two
# copies of one contract: a producer added to one and not the other is checked
# by whichever tool happened to be updated, and that is indistinguishable from
# being checked by both.
$registryPath = Join-Path $RepoRoot 'globalization/manifests/browser-sources.json'
if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    throw "The browser-source registry is missing: $registryPath"
}
$registry = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($registryPath))
$Sources = @($registry.cssProducers | ForEach-Object {
        @{ Path = [string]$_.path; Kind = [string]$_.kind; Palette = [string]$_.palette }
    })
if ($Sources.Count -eq 0) { throw 'The browser-source registry lists no CSS producers.' }

# --- REGION: Scan source
# Mark every character that sits inside a comment or a quoted string, so that
# splitting on ';' and matching braces never trips over one. Returns a bool[]
# parallel to the text.
function Get-InertMask {
    param([string]$Text)

    $mask = [bool[]]::new($Text.Length)
    $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ($c -eq '/' -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '*') {
            $end = $Text.IndexOf('*/', $i + 2)
            if ($end -lt 0) { $end = $Text.Length - 2 }
            for ($j = $i; $j -le [Math]::Min($end + 1, $Text.Length - 1); $j++) { $mask[$j] = $true }
            $i = $end + 2
            continue
        }
        if ($c -eq '"' -or $c -eq "'") {
            $quote = $c
            $j = $i + 1
            while ($j -lt $Text.Length) {
                if ($Text[$j] -eq '\') { $j += 2; continue }
                if ($Text[$j] -eq $quote) { break }
                $j++
            }
            for ($k = $i; $k -le [Math]::Min($j, $Text.Length - 1); $k++) { $mask[$k] = $true }
            $i = $j + 1
            continue
        }
        $i++
    }
    return $mask
}

# A copy of the text with every comment blanked to spaces and newlines kept,
# so offsets and line numbers still line up with the original. Declarations
# are matched against this: a comment sitting between two declarations would
# otherwise become part of the second one's text and defeat the property
# pattern. Quoted strings are left intact, because a declaration value has to
# survive into the generated fallback.
function Get-CleanText {
    param([string]$Text)

    $chars = $Text.ToCharArray()
    $i = 0
    while ($i -lt $Text.Length) {
        if ($Text[$i] -eq '/' -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '*') {
            $end = $Text.IndexOf('*/', $i + 2)
            if ($end -lt 0) { $end = $Text.Length - 2 }
            $last = [Math]::Min($end + 1, $Text.Length - 1)
            for ($j = $i; $j -le $last; $j++) {
                if ($chars[$j] -ne "`n" -and $chars[$j] -ne "`r") { $chars[$j] = ' ' }
            }
            $i = $end + 2
            continue
        }
        $i++
    }
    return (-join $chars)
}

# The selector or at-rule header that introduces a block: the run of real
# characters before it, back to the previous block or declaration boundary.
# Comments are skipped rather than read, so a license banner above a rule does
# not become part of its selector.
function Get-PrecedingText {
    param([string]$Text, [bool[]]$Mask, [int]$Before)

    $chars = [System.Collections.Generic.List[char]]::new()
    for ($i = $Before - 1; $i -ge 0; $i--) {
        if ($Mask[$i]) { continue }
        $c = $Text[$i]
        if ($c -eq '{' -or $c -eq '}' -or $c -eq ';') { break }
        $chars.Insert(0, $c)
    }
    return (-join $chars).Trim()
}

# Innermost brace pairs: a rule body holds declarations, never another block,
# so a pair with no brace between its ends is exactly one declaration list.
# Each result also carries the at-rule context it sits under, because a query
# an old engine cannot match needs no fallback.
function Get-RuleBody {
    param([string]$Text, [bool[]]$Mask)

    $bodies = [System.Collections.Generic.List[hashtable]]::new()
    $stack = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Mask[$i]) { continue }
        if ($Text[$i] -eq '{') { $stack.Add($i) }
        elseif ($Text[$i] -eq '}') {
            if ($stack.Count -eq 0) { continue }
            $open = $stack[$stack.Count - 1]
            $stack.RemoveAt($stack.Count - 1)
            $inner = $Text.Substring($open + 1, $i - $open - 1)
            if ($inner.IndexOf('{') -lt 0) {
                $selector = Get-PrecedingText -Text $Text -Mask $Mask -Before $open
                $atContext = ''
                if ($stack.Count -gt 0) {
                    $outerHead = Get-PrecedingText -Text $Text -Mask $Mask -Before $stack[$stack.Count - 1]
                    if ($outerHead -match '@media[^{}]*prefers-color-scheme') { $atContext = 'color-scheme' }
                }
                $bodies.Add(@{ Start = $open + 1; End = $i; Selector = $selector; AtContext = $atContext })
            }
        }
    }
    return ,$bodies
}

# Split a declaration list into spans, each covering one `prop: value` run.
function Split-Declaration {
    param([string]$Text, [bool[]]$Mask, [int]$Start, [int]$End)

    $spans = [System.Collections.Generic.List[hashtable]]::new()
    $segStart = $Start
    for ($i = $Start; $i -lt $End; $i++) {
        if (-not $Mask[$i] -and $Text[$i] -eq ';') {
            $spans.Add(@{ Start = $segStart; End = $i })
            $segStart = $i + 1
        }
    }
    if ($segStart -lt $End) {
        $tail = $Text.Substring($segStart, $End - $segStart)
        if ($tail.Trim().Length -gt 0) { $spans.Add(@{ Start = $segStart; End = $End }) }
    }
    return ,$spans
}

# --- REGION: Resolve variables
# Collect `--name: value` from the bare :root blocks only. A definition
# anywhere else makes single-valued resolution unsound, so it is an error.
function Get-Palette {
    param([string]$Text, [string]$Label)

    $mask = Get-InertMask -Text $Text
    $clean = Get-CleanText -Text $Text
    $bodies = Get-RuleBody -Text $clean -Mask $mask
    $palette = @{}
    foreach ($body in $bodies) {
        foreach ($span in (Split-Declaration -Text $clean -Mask $mask -Start $body.Start -End $body.End)) {
            $decl = $clean.Substring($span.Start, $span.End - $span.Start)
            if ($decl -notmatch '^\s*(--[A-Za-z0-9_-]+)\s*:\s*(.*)$') { continue }
            $name = $Matches[1]
            $value = $Matches[2].Trim()
            if ($body.Selector -ne ':root') {
                throw "$Label defines $name outside a :root block (selector '$($body.Selector)'); single-valued resolution requires :root."
            }
            # The dark block never applies on an engine without custom
            # properties, so the bare :root value is the one to resolve with.
            if ($body.AtContext -eq 'color-scheme') { continue }
            $palette[$name] = $value
        }
    }

    # A palette entry may itself reference another entry.
    for ($pass = 0; $pass -lt 8; $pass++) {
        $changed = $false
        foreach ($name in @($palette.Keys)) {
            $value = $palette[$name]
            if ($value -notmatch 'var\(') { continue }
            $resolved = Resolve-VarValue -Value $value -Palette $palette -AllowUnresolved
            if ($null -ne $resolved -and $resolved -ne $value) { $palette[$name] = $resolved; $changed = $true }
        }
        if (-not $changed) { break }
    }
    return $palette
}

# Replace every var() reference in a value with its palette literal. Returns
# $null when a name is unknown and carries no in-var fallback.
function Resolve-VarValue {
    param([string]$Value, [hashtable]$Palette, [switch]$AllowUnresolved)

    $result = $Value
    for ($guard = 0; $guard -lt 16; $guard++) {
        $at = $result.IndexOf('var(')
        if ($at -lt 0) { break }

        # Find the matching close paren for this var(, so a nested var() in the
        # fallback position stays with its own reference.
        $depth = 0
        $close = -1
        for ($i = $at + 3; $i -lt $result.Length; $i++) {
            if ($result[$i] -eq '(') { $depth++ }
            elseif ($result[$i] -eq ')') { $depth--; if ($depth -eq 0) { $close = $i; break } }
        }
        if ($close -lt 0) { return $null }

        $inner = $result.Substring($at + 4, $close - $at - 4)
        $comma = -1
        $d = 0
        for ($i = 0; $i -lt $inner.Length; $i++) {
            if ($inner[$i] -eq '(') { $d++ }
            elseif ($inner[$i] -eq ')') { $d-- }
            elseif ($inner[$i] -eq ',' -and $d -eq 0) { $comma = $i; break }
        }
        $rawName = if ($comma -ge 0) { $inner.Substring(0, $comma) } else { $inner }
        $name = $rawName.Trim()
        $inVar = if ($comma -ge 0) { $inner.Substring($comma + 1).Trim() } else { $null }

        $replacement = $null
        if ($Palette.ContainsKey($name)) { $replacement = $Palette[$name] }
        elseif ($null -ne $inVar) { $replacement = $inVar }
        elseif ($AllowUnresolved) { return $result }
        else { return $null }

        $result = $result.Substring(0, $at) + $replacement + $result.Substring($close + 1)
    }
    return $result
}

# --- REGION: Transform source
# Work out every fallback this CSS text needs. Returns the edit list plus the
# findings, without touching the text.
function Get-FallbackEdit {
    param([string]$Text, [hashtable]$Palette, [string]$Label)

    $mask = Get-InertMask -Text $Text
    $clean = Get-CleanText -Text $Text
    $bodies = Get-RuleBody -Text $clean -Mask $mask
    $edits = [System.Collections.Generic.List[hashtable]]::new()
    $findings = [System.Collections.Generic.List[string]]::new()

    foreach ($body in $bodies) {
        # An engine with no custom properties cannot match this query either,
        # so nothing inside it ever paints on the floor.
        if ($body.AtContext -eq 'color-scheme') { continue }

        $spans = Split-Declaration -Text $clean -Mask $mask -Start $body.Start -End $body.End
        for ($s = 0; $s -lt $spans.Count; $s++) {
            $span = $spans[$s]
            $decl = $clean.Substring($span.Start, $span.End - $span.Start)
            if ($decl -notmatch 'var\(') { continue }
            if ($decl -notmatch '(?s)^(\s*)([-A-Za-z][-A-Za-z0-9]*)\s*:\s*(\S.*)$') { continue }
            $lead = $Matches[1]
            $prop = $Matches[2]
            $value = $Matches[3]
            if ($prop.StartsWith('--')) { continue }

            $resolved = Resolve-VarValue -Value $value -Palette $Palette
            if ($null -eq $resolved) {
                $line = ($Text.Substring(0, $span.Start) -split "`n").Count
                throw "$Label`:$line resolves no palette value for '$($value.Trim())'."
            }
            $resolved = $resolved.Trim()
            $wanted = "$prop`: $resolved"

            # A same-property declaration immediately before, with no var() of
            # its own, is this script's own output from an earlier run.
            $prevIsGenerated = $false
            $prevSpan = $null
            if ($s -gt 0) {
                $prevSpan = $spans[$s - 1]
                $prev = $clean.Substring($prevSpan.Start, $prevSpan.End - $prevSpan.Start)
                if ($prev -notmatch 'var\(' -and $prev -match '(?s)^\s*([-A-Za-z][-A-Za-z0-9]*)\s*:\s*(\S.*)$') {
                    if ($Matches[1] -eq $prop) { $prevIsGenerated = $true }
                }
            }

            $line = ($Text.Substring(0, $span.Start) -split "`n").Count
            if ($prevIsGenerated) {
                $prevText = $clean.Substring($prevSpan.Start, $prevSpan.End - $prevSpan.Start)
                $prevLead = if ($prevText -match '^(\s*)') { $Matches[1] } else { '' }
                if ($prevText.Trim() -ne $wanted) {
                    $edits.Add(@{ Start = $prevSpan.Start; End = $prevSpan.End; Text = "$prevLead$wanted" })
                    $findings.Add("$Label`:$line stale fallback for '$prop' (has '$($prevText.Trim())', needs '$wanted')")
                }
                continue
            }

            # Match the file's own shape: a declaration that begins its line
            # gets a line of its own, one that shares a line stays inline.
            $atLineStart = $lead.Contains("`n") -or $span.Start -eq 0
            if ($atLineStart) {
                $indent = ($lead -split "`n")[-1]
                $insert = "$lead$wanted;`n$indent"
                $edits.Add(@{ Start = $span.Start; End = $span.Start + $lead.Length; Text = $insert })
            } else {
                $edits.Add(@{ Start = $span.Start; End = $span.Start + $lead.Length; Text = "$lead$wanted; " })
            }
            $findings.Add("$Label`:$line missing fallback for '$prop' (needs '$wanted')")
        }
    }
    return @{ Edits = $edits; Findings = $findings }
}

function Get-EditedText {
    param([string]$Text, $Edits)

    $ordered = @($Edits) | Sort-Object -Property Start -Descending
    $result = $Text
    foreach ($edit in $ordered) {
        $result = $result.Substring(0, $edit.Start) + $edit.Text + $result.Substring($edit.End)
    }
    return $result
}

# --- REGION: Extract source
# Pull the CSS regions out of a container that is not itself a stylesheet: an
# HTML page, a Go raw-string page, or a PowerShell here-string that writes one.
# Returns spans into the original text.
function Get-StyleRegion {
    param([string]$Text)

    $regions = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($m in [regex]::Matches($Text, '<style[^>]*>(.*?)</style>', 'Singleline, IgnoreCase')) {
        $group = $m.Groups[1]
        if ($group.Value -match 'var\(|--[A-Za-z0-9_-]+\s*:') {
            $regions.Add(@{ Start = $group.Index; End = $group.Index + $group.Length })
        }
    }
    return ,$regions
}

# --- REGION: Main
# Registered sources are repo-relative; one passed in on the command line may
# be anywhere.
function Resolve-SourcePath {
    param([string]$Candidate)

    if ([IO.Path]::IsPathRooted($Candidate)) { return $Candidate }
    return (Join-Path $RepoRoot $Candidate)
}

$selected = $Sources
if ($Source) {
    $palettePath = if ($PaletteSource) { $PaletteSource } else { $Source }
    # A .css file is CSS throughout; anything else carries its CSS in <style>.
    $kind = if ($Source -like '*.css') { 'Css' } else { 'Html' }
    $selected = @(@{ Path = $Source; Kind = $kind; Palette = $palettePath })
} elseif ($Path -and $Path.Count -gt 0) {
    $selected = $Sources | Where-Object {
        $candidate = $_.Path
        @($Path | Where-Object { $candidate -like $_ }).Count -gt 0
    }
}

$paletteCache = @{}
$totalFindings = 0
$changedFiles = 0
$checkedSources = 0

try {

foreach ($entry in $selected) {
    $full = Resolve-SourcePath -Candidate $entry.Path
    if (-not (Test-Path -LiteralPath $full)) {
        $ErrorActionPreference = 'Continue'
        Write-Error "Registered source not found: $($entry.Path)"
        exit 2
    }

    if (-not $paletteCache.ContainsKey($entry.Palette)) {
        $paletteFull = Resolve-SourcePath -Candidate $entry.Palette
        $paletteText = [IO.File]::ReadAllText($paletteFull)
        if ($entry.Palette -notlike '*.css') {
            $combined = ''
            $paletteRegions = Get-StyleRegion -Text $paletteText
            foreach ($region in $paletteRegions) {
                $combined += $paletteText.Substring($region.Start, $region.End - $region.Start) + "`n"
            }
            $paletteText = $combined
        }
        $paletteCache[$entry.Palette] = Get-Palette -Text $paletteText -Label $entry.Palette
    }
    $palette = $paletteCache[$entry.Palette]

    $original = [IO.File]::ReadAllText($full)
    $checkedSources++

    if ($entry.Kind -eq 'Css') {
        $result = Get-FallbackEdit -Text $original -Palette $palette -Label $entry.Path
        $findings = $result.Findings
        $updated = if ($result.Edits.Count -gt 0) { Get-EditedText -Text $original -Edits $result.Edits } else { $original }
    } else {
        $regions = Get-StyleRegion -Text $original
        $findings = [System.Collections.Generic.List[string]]::new()
        $updated = $original
        # Right to left, so an earlier region's offsets stay valid.
        for ($r = $regions.Count - 1; $r -ge 0; $r--) {
            $region = $regions[$r]
            $css = $original.Substring($region.Start, $region.End - $region.Start)
            $result = Get-FallbackEdit -Text $css -Palette $palette -Label $entry.Path
            foreach ($f in $result.Findings) { $findings.Add($f) }
            if ($result.Edits.Count -gt 0) {
                $newCss = Get-EditedText -Text $css -Edits $result.Edits
                $updated = $updated.Substring(0, $region.Start) + $newCss + $updated.Substring($region.End)
            }
        }
    }

    if ($findings.Count -eq 0) {
        if (-not $Quiet) { Write-Output "PASS  $($entry.Path)" }
        continue
    }

    $totalFindings += $findings.Count
    foreach ($f in $findings) { Write-Output "  $f" }

    if ($Update) {
        [IO.File]::WriteAllText($full, $updated)
        $changedFiles++
        Write-Output "WROTE $($entry.Path)  ($($findings.Count) fallback(s))"
    } else {
        Write-Output "FAIL  $($entry.Path)  ($($findings.Count) fallback(s) missing or stale)"
    }
}

} catch {
    # An unresolvable name or a definition outside :root is a different answer
    # from "a fallback is stale": the source cannot be resolved at all, and no
    # amount of regenerating fixes it. The preference is lowered first so
    # reporting the failure does not itself become a terminating error and
    # lose the exit code that says which kind of failure this was.
    $ErrorActionPreference = 'Continue'
    Write-Error $_.Exception.Message
    exit 2
}

Write-Output ''
if ($Update) {
    Write-Output "Checked $checkedSources source(s); rewrote $changedFiles."
    if ($changedFiles -gt 0) { exit 1 }
    exit 0
}

Write-Output "Checked $checkedSources source(s); $totalFindings fallback(s) missing or stale."
if ($totalFindings -gt 0) { exit 1 }
exit 0
