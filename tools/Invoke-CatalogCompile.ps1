<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42b0f4a9-1c73-4e58-8d61-9a5207ebd3f4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization catalog compiler generate i18n
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
    Validate the source message catalogs and generate the per-runtime
    artifacts the PowerShell, browser and Go code load at run time.
.DESCRIPTION
    Source catalogs are raw UTF-8 JSON, one file per domain per locale, so a
    translator can read and edit them without a build step and without
    inspecting escape sequences. Nothing loads those files at run time. This
    script is the only thing that reads them, and it emits what each runtime
    actually needs:

      PowerShell  a data file holding one hashtable, loaded once per process
      Browser     a classic ES5 asset that registers its domain on load
      Go          a package with the same table as package-level data

    Messages are emitted PRE-TOKENIZED. A message with arguments becomes an
    alternating list of literal text and argument descriptors, so rendering
    is a walk over that list -- no message grammar is parsed, and no format
    string is scanned, on any call. A literal message stays a plain string,
    which is the common case and costs one lookup.

    The compiler is deterministic: keys are sorted, output uses LF endings
    and a fixed layout, and nothing records a timestamp. Running it twice
    over unchanged sources produces identical bytes, which is what lets
    -Check be a gate rather than a suggestion.

    Two pseudo-locales are generated from en-US and are test-only. The
    expanded one accents and lengthens every letter and brackets the whole
    string, so text that never reached a catalog stands out unbracketed and
    a layout sized to English breaks visibly. The mirrored one marks the
    string right-to-left. Neither is ever shipped.

    Exit codes follow the entry-point contract:
        0  Sources are valid and the generated artifacts are current.
        1  A source is invalid, or the artifacts are stale (-Check), or
           they were rewritten (-Update).
        2  The catalog root or the locale manifest is missing, so nothing
           could be compiled.

.PARAMETER Check
    Validate and compare against the generated artifacts without writing.
    The default when neither -Check nor -Update is given.
.PARAMETER Update
    Write the generated artifacts.
.PARAMETER Root
    The globalization directory. Default: globalization/ beside this repo.
.PARAMETER Quiet
    Print only failures and the summary.

.EXAMPLE
    pwsh tools/Invoke-CatalogCompile.ps1
    Validates the sources and reports any generated artifact that is stale.

.EXAMPLE
    pwsh tools/Invoke-CatalogCompile.ps1 -Update
    Regenerates every artifact; exits 1 when anything changed.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '',
    Justification = 'Catalog/compiler sources are repository-gated UTF-8 without BOM; PowerShell 7 is required.')]
[CmdletBinding()]
[OutputType([string])]
param(
    [switch]$Check,
    [switch]$Update,
    [string]$Root,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Root) { $Root = Join-Path $RepoRoot 'globalization' }
if (-not $Update) { $Check = $true }

$script:Problem = [System.Collections.Generic.List[string]]::new()

function Add-Problem {
    param([Parameter(Mandatory)][string]$Message)
    $script:Problem.Add($Message)
}

# --- REGION: Validation
# The argument names a message actually uses, in the order they appear.
function Get-PlaceholderReference {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($Text, '\{([A-Za-z][A-Za-z0-9]*)\}')) {
        $names.Add($m.Groups[1].Value)
    }
    return , $names
}

# Every rendered form a message can take: its scalar sentence or each plural
# or select variant. Validation applies to all of them equally, because any
# one of them can reach a reader.
function Get-MessageForm {
    param([Parameter(Mandatory)]$Message)

    $forms = [System.Collections.Generic.List[hashtable]]::new()
    if ($null -ne $Message.message) { $forms.Add(@{ Label = 'message'; Text = [string]$Message.message }) }
    foreach ($kind in @('plural', 'select')) {
        $branch = $Message.$kind
        if ($null -eq $branch) { continue }
        foreach ($p in $branch.variants.PSObject.Properties) {
            $forms.Add(@{ Label = "$kind.$($p.Name)"; Text = [string]$p.Value })
        }
    }
    return , $forms
}

function Test-CatalogFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$ExpectedLocale,
        [Parameter(Mandatory)][string[]]$PluralCategory,
        [Parameter(Mandatory)][bool]$IsSource
    )

    $label = [IO.Path]::GetFileName($Path)

    if ($Catalog.schema -ne 'yuruna.catalog/v1') {
        Add-Problem "$label declares schema '$($Catalog.schema)', not yuruna.catalog/v1"
        return
    }
    if ($Catalog.locale -ne $ExpectedLocale) {
        Add-Problem "$label declares locale '$($Catalog.locale)' but sits under $ExpectedLocale"
    }
    $domainFromName = [IO.Path]::GetFileNameWithoutExtension($Path)
    if ($Catalog.domain -ne $domainFromName) {
        Add-Problem "$label declares domain '$($Catalog.domain)' but is named for '$domainFromName'"
    }

    foreach ($prop in $Catalog.messages.PSObject.Properties) {
        $key = $prop.Name
        $msg = $prop.Value

        if (-not $key.StartsWith("$($Catalog.domain).")) {
            Add-Problem "$label`: key '$key' is not inside its own domain '$($Catalog.domain)'"
        }

        if (-not $IsSource) {
            # A translation owns wording and the hash of the English contract
            # it was reviewed against. Placeholder types, lifecycle and the
            # selector remain single-source in en-US and are merged back in
            # below before compilation.
            if (-not $msg.sourceHash) {
                Add-Problem "$label`: translated key '$key' has no sourceHash"
            }
            if ($null -ne $msg.plural -and $null -ne $msg.select) {
                Add-Problem "$label`: '$key' carries both plural and select; split it into two keys the caller chooses between"
            }
            foreach ($form in (Get-MessageForm -Message $msg)) {
                if ([string]::IsNullOrWhiteSpace($form.Text)) {
                    Add-Problem "$label`: translated '$key' has a blank $($form.Label) form"
                }
            }
            if ($null -ne $msg.select -and
                @($msg.select.variants.PSObject.Properties.Name) -notcontains 'other') {
                Add-Problem "$label`: translated '$key' has no 'other' select form"
            }
            continue
        }

        switch ($msg.lifecycle) {
            'tombstone' {
                if ($null -ne $msg.message) {
                    Add-Problem "$label`: tombstoned key '$key' still carries text; a retired key renders nothing"
                }
                continue
            }
            'deprecated' {
                if (-not $msg.replacedBy) {
                    Add-Problem "$label`: deprecated key '$key' names no replacement"
                }
            }
        }
        if ($msg.lifecycle -eq 'tombstone') { continue }

        if (-not $msg.description) {
            Add-Problem "$label`: '$key' has no description; a translator sees the sentence with no idea where it appears"
        }

        $declared = @()
        if ($msg.placeholders) { $declared = @($msg.placeholders.PSObject.Properties.Name) }

        $forms = Get-MessageForm -Message $msg
        if ($forms.Count -eq 0) {
            Add-Problem "$label`: '$key' has no message and no variants"
            continue
        }

        $used = [System.Collections.Generic.HashSet[string]]::new()
        # A selector is used by the selection itself, whether or not any form
        # renders it. A plural writes its count into the sentence and a select
        # usually does not -- "the framework repository" and "the project
        # repository" are whole sentences chosen BY the value, and neither
        # prints it. Requiring the selector to appear in the text would force a
        # word into a sentence that does not want one, which is exactly the
        # composed-from-a-noun shape a select exists to avoid.
        foreach ($kind in @('plural', 'select')) {
            if ($null -ne $msg.$kind -and $msg.$kind.selector) { [void]$used.Add([string]$msg.$kind.selector) }
        }
        foreach ($form in $forms) {
            if ([string]::IsNullOrWhiteSpace($form.Text)) {
                Add-Problem "$label`: '$key' has a blank $($form.Label) form"
            }
            foreach ($name in (Get-PlaceholderReference -Text $form.Text)) {
                [void]$used.Add($name)
                if ($declared -notcontains $name) {
                    Add-Problem "$label`: '$key' ($($form.Label)) uses {$name}, which it never declares"
                }
            }
        }
        foreach ($name in $declared) {
            if (-not $used.Contains($name)) {
                Add-Problem "$label`: '$key' declares placeholder '$name' that no form uses"
            }
        }

        if ($null -ne $msg.plural -and $null -ne $msg.select) {
            # One message, one branch. Carrying both would need a nested
            # form the compiled shape does not express, and emitting one of
            # them would silently drop the other's wording -- so it is
            # refused here rather than half-shipped.
            Add-Problem "$label`: '$key' carries both plural and select; split it into two keys the caller chooses between"
        }

        foreach ($kind in @('plural', 'select')) {
            $branch = $msg.$kind
            if ($null -eq $branch) { continue }
            if ($declared -notcontains $branch.selector) {
                Add-Problem "$label`: '$key' selects $kind on '$($branch.selector)', which it never declares"
            }
            if ($kind -eq 'select' -and
                @($branch.variants.PSObject.Properties.Name) -notcontains 'other') {
                Add-Problem "$label`: '$key' has no 'other' select form"
            }
            if ($kind -eq 'plural') {
                $have = @($branch.variants.PSObject.Properties.Name)
                foreach ($category in $PluralCategory) {
                    if ($have -notcontains $category) {
                        Add-Problem "$label`: '$key' has no '$category' plural form, which $ExpectedLocale requires"
                    }
                }
            }
        }
    }
}

# --- REGION: Compile
# Turn one rendered form into the alternating literal / argument list the
# runtimes walk. A form with no argument stays a plain string.
function ConvertTo-CompiledForm {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][AllowNull()]$Placeholders
    )

    if ($Text -notmatch '\{[A-Za-z]') { return $Text }

    $parts = [System.Collections.Generic.List[object]]::new()
    $cursor = 0
    foreach ($m in [regex]::Matches($Text, '\{([A-Za-z][A-Za-z0-9]*)\}')) {
        if ($m.Index -gt $cursor) { $parts.Add($Text.Substring($cursor, $m.Index - $cursor)) }
        $name = $m.Groups[1].Value
        $type = 'text'
        $trust = 'internal'
        if ($Placeholders -and $Placeholders.PSObject.Properties.Name -contains $name) {
            $type = [string]$Placeholders.$name.type
            $trust = [string]$Placeholders.$name.trust
        }
        $parts.Add([ordered]@{ arg = $name; type = $type; trust = $trust })
        $cursor = $m.Index + $m.Length
    }
    if ($cursor -lt $Text.Length) { $parts.Add($Text.Substring($cursor)) }
    return @($parts)
}

function ConvertTo-CompiledMessage {
    param([Parameter(Mandatory)]$Message)

    $placeholders = $Message.placeholders
    foreach ($kind in @('plural', 'select')) {
        $branch = $Message.$kind
        if ($null -eq $branch) { continue }
        $variants = [ordered]@{}
        foreach ($p in ($branch.variants.PSObject.Properties | Sort-Object Name)) {
            $variants[$p.Name] = ConvertTo-CompiledForm -Text ([string]$p.Value) -Placeholders $placeholders
        }
        return [ordered]@{ kind = $kind; selector = $branch.selector; variants = $variants }
    }
    return ConvertTo-CompiledForm -Text ([string]$Message.message) -Placeholders $placeholders
}

# --- REGION: Pseudo-locales
$script:PseudoMap = @{
    'a' = ([char]0x00E1).ToString(); 'b' = ([char]0x0180).ToString(); 'c' = ([char]0x00E7).ToString()
    'd' = ([char]0x010F).ToString(); 'e' = ([char]0x00E9).ToString(); 'f' = ([char]0x0192).ToString()
    'g' = ([char]0x011F).ToString(); 'h' = ([char]0x0127).ToString(); 'i' = ([char]0x00ED).ToString()
    'j' = ([char]0x0135).ToString(); 'k' = ([char]0x0137).ToString(); 'l' = ([char]0x013C).ToString()
    'm' = ([char]0x0271).ToString(); 'n' = ([char]0x00F1).ToString(); 'o' = ([char]0x00F3).ToString()
    'p' = ([char]0x01A5).ToString(); 'q' = ([char]0x02A0).ToString(); 'r' = ([char]0x0159).ToString()
    's' = ([char]0x0161).ToString(); 't' = ([char]0x0163).ToString(); 'u' = ([char]0x00FA).ToString()
    'v' = ([char]0x1E7D).ToString(); 'w' = ([char]0x0175).ToString(); 'x' = ([char]0x1E8B).ToString()
    'y' = ([char]0x00FD).ToString(); 'z' = ([char]0x017E).ToString()
}

# Tokens whose spelling is a machine contract are copied around, not
# translated. The pseudo pass protects them for the same reason a real
# translation must: an URL, path, namespaced code or keyboard shortcut that is
# accented no longer works, and a pseudo run should expose UI layout rather
# than manufacture a broken link.
$script:PseudoProtected = [regex]::new(
    '^(?:\{[A-Za-z][A-Za-z0-9]*\}|<[^>]+>|https?://[^\s]+|(?:Ctrl|Alt|Shift|Cmd|Command|Option)(?:\+[A-Za-z0-9]+)+|(?:[A-Za-z0-9_-]+\.)+[A-Za-z0-9_-]+|/[A-Za-z0-9_./-]+)',
    [Text.RegularExpressions.RegexOptions]::CultureInvariant)

# Accent the letters and pad the result, leaving every {argument} untouched.
# A string that reaches the screen unbracketed never came from a catalog.
function ConvertTo-PseudoText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [switch]$Mirrored)

    $out = [Text.StringBuilder]::new()
    $i = 0
    while ($i -lt $Text.Length) {
        $protected = $script:PseudoProtected.Match($Text.Substring($i))
        if ($protected.Success) {
            [void]$out.Append($protected.Value)
            $i += $protected.Length
            continue
        }
        $c = [string]$Text[$i]
        $lower = $c.ToLowerInvariant()
        if ($script:PseudoMap.ContainsKey($lower)) {
            $mapped = $script:PseudoMap[$lower]
            if ($c -cne $lower) { $mapped = $mapped.ToUpperInvariant() }
            [void]$out.Append($mapped)
        } else {
            [void]$out.Append($c)
        }
        $i++
    }

    # Roughly 40% growth, which is the expansion a Latin translation of short
    # English UI text reaches in practice.
    $padCount = [Math]::Max(1, [int][Math]::Ceiling($Text.Length * 0.4))
    $pad = '~' * $padCount
    if ($Mirrored) { return "[!$([char]0x202E)$out$([char]0x202C) $pad]" }
    return "[$out $pad]"
}

function ConvertTo-PseudoCatalog {
    param([Parameter(Mandatory)]$Catalog, [switch]$Mirrored)

    $messages = [ordered]@{}
    foreach ($prop in ($Catalog.messages.PSObject.Properties | Sort-Object Name)) {
        $msg = $prop.Value
        if ($msg.lifecycle -eq 'tombstone') { continue }
        $clone = [ordered]@{ lifecycle = $msg.lifecycle }
        if ($null -ne $msg.message) {
            $clone.message = ConvertTo-PseudoText -Text ([string]$msg.message) -Mirrored:$Mirrored
        }
        if ($msg.placeholders) { $clone.placeholders = $msg.placeholders }
        foreach ($kind in @('plural', 'select')) {
            $branch = $msg.$kind
            if ($null -eq $branch) { continue }
            $variants = [ordered]@{}
            foreach ($p in ($branch.variants.PSObject.Properties | Sort-Object Name)) {
                $variants[$p.Name] = ConvertTo-PseudoText -Text ([string]$p.Value) -Mirrored:$Mirrored
            }
            # The compile step reads these back through PSObject.Properties, so
            # every nested map has to be an object rather than a dictionary --
            # enumerating a dictionary that way yields Keys and Count, not the
            # entries, and the variants collapse into one unusable row.
            $clone[$kind] = [pscustomobject]@{
                selector = $branch.selector
                variants = [pscustomobject]$variants
            }
        }
        $messages[$prop.Name] = [pscustomobject]$clone
    }
    return [pscustomobject]([ordered]@{
        schema   = 'yuruna.catalog/v1'
        domain   = $Catalog.domain
        locale   = if ($Mirrored) { 'qps-Plocm' } else { 'qps-Ploc' }
        messages = [pscustomobject]$messages
    })
}

# --- REGION: Emitters
function ConvertTo-CanonicalJson {
    param([Parameter(Mandatory)]$Value)
    return (($Value | ConvertTo-Json -Depth 20).Replace("`r`n", "`n").TrimEnd() + "`n")
}

function ConvertTo-SortedValue {
    <# Recursively sort object keys before hashing a semantic record. #>
    param([Parameter(Mandatory)][AllowNull()]$Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
            $ordered[$key] = ConvertTo-SortedValue -Value $Value[$key]
        }
        return $ordered
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-SortedValue -Value $_ })
    }
    $ordered = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
        $ordered[$property.Name] = ConvertTo-SortedValue -Value $property.Value
    }
    return $ordered
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Get-MessageSourceHash {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)]$Message
    )

    # The hash covers every source-owned fact a translator relies on: wording,
    # context, placeholders, branching and lifecycle. Object property order is
    # not meaning, so it is sorted recursively before hashing. Reformatting a
    # source file therefore does not stale translations; changing one message
    # stales exactly that message.
    $record = [ordered]@{
        key      = $Key
        contract = ConvertTo-SortedValue -Value $Message
    }
    return Get-Sha256 -Text (ConvertTo-CanonicalJson -Value $record)
}

function ConvertTo-PowerShellLiteral {
    param([Parameter(Mandatory)][AllowNull()]$Value, [int]$Indent = 0)

    $pad = ' ' * $Indent
    if ($Value -is [string]) { return "'" + $Value.Replace("'", "''") + "'" }
    if ($Value -is [System.Collections.IDictionary]) {
        $lines = foreach ($k in $Value.Keys) {
            $key = ([string]$k).Replace("'", "''")
            "$pad    '$key' = " + (ConvertTo-PowerShellLiteral -Value $Value[$k] -Indent ($Indent + 4))
        }
        return "@{`n" + ($lines -join "`n") + "`n$pad}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $lines = foreach ($v in $Value) {
            "$pad    " + (ConvertTo-PowerShellLiteral -Value $v -Indent ($Indent + 4))
        }
        return "@(`n" + ($lines -join "`n") + "`n$pad)"
    }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function ConvertTo-JsLiteral {
    param([Parameter(Mandatory)][AllowNull()]$Value)

    if ($Value -is [string]) {
        $escaped = $Value.Replace('\', '\\').Replace("'", "\'").Replace("`n", '\n').Replace("`r", '\r')
        # Keep the emitted asset inside the source encoding the browser gate
        # expects, so a translated string cannot depend on how the file is
        # served.
        $sb = [Text.StringBuilder]::new()
        foreach ($ch in $escaped.ToCharArray()) {
            if ([int]$ch -gt 126) { [void]$sb.Append('\u{0:x4}' -f [int]$ch) } else { [void]$sb.Append($ch) }
        }
        return "'" + $sb.ToString() + "'"
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = foreach ($k in $Value.Keys) {
            (ConvertTo-JsLiteral -Value ([string]$k)) + ':' + (ConvertTo-JsLiteral -Value $Value[$k])
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = foreach ($v in $Value) { ConvertTo-JsLiteral -Value $v }
        return '[' + ($parts -join ',') + ']'
    }
    return "'" + ([string]$Value) + "'"
}

$script:Banner = @(
    '# Generated by tools/Invoke-CatalogCompile.ps1 from globalization/catalogs.'
    '# Edit the source catalog and regenerate; changes made here are overwritten.'
) -join "`n"

# Every PowerShell file in the repository declares a PSScriptInfo GUID, and a
# generated data file is no exception. Deriving it from the locale and domain
# keeps it stable across runs -- a fresh GUID each time would make every
# regeneration look like a change -- while staying distinct per artifact.
function Get-DerivedGuid {
    param([Parameter(Mandatory)][string]$Seed)

    $digest = Get-Sha256 -Text "yuruna.catalog|$Seed"
    $body = $digest.Substring(2, 30)
    return '42' + $body.Substring(0, 6) + '-' + $body.Substring(6, 4) + '-' +
           $body.Substring(10, 4) + '-' + $body.Substring(14, 4) + '-' + $body.Substring(18, 12)
}

function Get-PowerShellArtifact {
    param([Parameter(Mandatory)][string]$Locale, [Parameter(Mandatory)][string]$Domain,
          [Parameter(Mandatory)][System.Collections.IDictionary]$Compiled)

    $body = ConvertTo-PowerShellLiteral -Value $Compiled
    $guid = Get-DerivedGuid -Seed "$Locale|$Domain"
    $header = @(
        '<#PSScriptInfo'
        '.VERSION 2026.09.13'
        ".GUID $guid"
        '.AUTHOR Alisson Sol et al.'
        '.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.'
        ".TAGS yuruna globalization catalog generated $Locale $Domain"
        '.LICENSEURI https://yuruna.link/license'
        '.PROJECTURI https://yuruna.com'
        '.ICONURI'
        '.EXTERNALMODULEDEPENDENCIES'
        '.REQUIREDSCRIPTS'
        '.EXTERNALSCRIPTDEPENDENCIES'
        '.RELEASENOTES'
        '.PRIVATEDATA'
        '#>'
    ) -join "`n"
    return "$header`n`n$script:Banner`n# locale: $Locale  domain: $Domain`n`n$body`n"
}

function Get-BrowserArtifact {
    param([Parameter(Mandatory)][string]$Locale, [Parameter(Mandatory)][string]$Domain,
          [Parameter(Mandatory)][System.Collections.IDictionary]$Compiled)

    $literal = ConvertTo-JsLiteral -Value $Compiled
    $js = @"
// Generated by tools/Invoke-CatalogCompile.ps1 from globalization/catalogs.
// Edit the source catalog and regenerate; changes made here are overwritten.
// locale: $Locale  domain: $Domain
(function (root) {
  'use strict';
  var registry = root.YurunaCatalog = root.YurunaCatalog || {};
  var byLocale = registry['$Locale'] = registry['$Locale'] || {};
  byLocale['$Domain'] = $literal;
}(this));
"@
    return ($js.Replace("`r`n", "`n").TrimEnd() + "`n")
}

function Get-GoArtifact {
    param([Parameter(Mandatory)][string]$Locale, [Parameter(Mandatory)][string]$Domain,
          [Parameter(Mandatory)][string]$Json)

    # A Go raw string literal takes every byte as written, backslashes
    # included, so the JSON goes in untouched: escaping it here would double
    # every `\"` and `\\` the encoder produced and the decoded catalog would
    # carry the wrong text. The one byte a raw literal cannot hold is the
    # backtick that ends it, so that is spliced in as an interpreted literal.
    $quoted = $Json.Replace('`', '` + "`" + `')
    $identifier = (($Locale -replace '[^A-Za-z0-9]', '') + ($Domain -replace '[^A-Za-z0-9]', ''))
    $go = @"
// Generated by tools/Invoke-CatalogCompile.ps1 from globalization/catalogs.
// Edit the source catalog and regenerate; changes made here are overwritten.
// locale: $Locale  domain: $Domain

package catalog

// Data$identifier is the compiled catalog for this locale and domain. It is a
// string so the package carries no init cost until a caller decodes it.
const Data$identifier = ``$quoted``
"@
    return ($go.Replace("`r`n", "`n").TrimEnd() + "`n")
}

# --- REGION: Main
try {

if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    $ErrorActionPreference = 'Continue'
    Write-Error "Catalog root not found: $Root"
    exit 2
}

$manifestPath = Join-Path $Root 'locale-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $ErrorActionPreference = 'Continue'
    Write-Error "Locale manifest not found: $manifestPath"
    exit 2
}

$schemaPath = Join-Path $Root 'schema/catalog.schema.json'
if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    $ErrorActionPreference = 'Continue'
    Write-Error "Catalog schema not found: $schemaPath"
    exit 2
}

$manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($manifestPath))
$defaultLocale = [string]$manifest.default
$catalogRoot = Join-Path $Root 'catalogs'
if (-not (Test-Path -LiteralPath $catalogRoot -PathType Container)) {
    $ErrorActionPreference = 'Continue'
    Write-Error "No catalogs directory under $Root"
    exit 2
}

# --- REGION: Read and validate source catalogs
$sourceLocale = @(Get-ChildItem -LiteralPath $catalogRoot -Directory | Sort-Object Name)
$catalogs = [System.Collections.Generic.List[hashtable]]::new()
$seenKey = @{}

foreach ($dir in $sourceLocale) {
    $locale = $dir.Name
    $localeInfo = $manifest.locales.$locale
    if (-not $localeInfo) {
        Add-Problem "catalogs/$locale is not a locale the manifest declares"
        continue
    }
    $categories = @($localeInfo.pluralCategories)
    foreach ($file in (Get-ChildItem -LiteralPath $dir.FullName -Filter '*.json' -File | Sort-Object Name)) {
        $text = [IO.File]::ReadAllText($file.FullName)
        $parsed = $null
        try { $parsed = ConvertFrom-Json -InputObject $text }
        catch {
            Add-Problem "$($file.Name) is not valid JSON: $($_.Exception.Message)"
            continue
        }
        # This is deliberately the checked-in schema file, not a handwritten
        # approximation of it. The semantic checks below add diagnostics that
        # JSON Schema cannot express (cross-file ownership and plural rules),
        # but they do not substitute for validating the source against its
        # declared schema.
        try {
            if (-not (Test-Json -Json $text -SchemaFile $schemaPath -ErrorAction Stop)) {
                Add-Problem "$($file.Name) does not satisfy schema/catalog.schema.json"
            }
        } catch {
            Add-Problem "$($file.Name) does not satisfy schema/catalog.schema.json: $($_.Exception.Message)"
        }
        Test-CatalogFile -Path $file.FullName -Catalog $parsed -ExpectedLocale $locale `
            -PluralCategory $categories -IsSource:($locale -eq [string]$manifest.default)
        foreach ($p in $parsed.messages.PSObject.Properties) {
            $owner = "$locale/$($parsed.domain)"
            if ($seenKey.ContainsKey("$locale|$($p.Name)")) {
                Add-Problem "key '$($p.Name)' is defined twice in $locale"
            }
            $seenKey["$locale|$($p.Name)"] = $owner
        }
        $relativeSource = ([IO.Path]::GetRelativePath($Root, $file.FullName)) -replace '\\', '/'
        $catalogs.Add(@{
            Locale = $locale; Domain = $parsed.domain; Parsed = $parsed; SourceText = $text
            SourcePath = $relativeSource; InputHash = Get-Sha256 -Text $text
        })
    }
}

if ($catalogs.Count -eq 0) { Add-Problem 'no source catalogs were found' }

# --- REGION: Translation ownership and staleness
$baseByDomain = @{}
$messageSourceHash = [ordered]@{}
$translationProvenance = [ordered]@{}
foreach ($entry in @($catalogs | Where-Object Locale -EQ $defaultLocale | Sort-Object Domain)) {
    $baseByDomain[$entry.Domain] = $entry
    foreach ($p in @($entry.Parsed.messages.PSObject.Properties | Sort-Object Name)) {
        $messageSourceHash[$p.Name] = Get-MessageSourceHash -Key $p.Name -Message $p.Value
    }
}

foreach ($entry in @($catalogs | Where-Object Locale -NE $defaultLocale)) {
    $baseEntry = $baseByDomain[$entry.Domain]
    if (-not $baseEntry) {
        Add-Problem "$($entry.SourcePath) translates domain '$($entry.Domain)', which $defaultLocale does not own"
        continue
    }
    $mergedMessages = [ordered]@{}
    foreach ($p in @($entry.Parsed.messages.PSObject.Properties | Sort-Object Name)) {
        $key = $p.Name
        $translation = $p.Value
        $sourceProperty = $baseEntry.Parsed.messages.PSObject.Properties[$key]
        if (-not $sourceProperty) {
            Add-Problem "$($entry.SourcePath) translates unknown key '$key'"
            continue
        }
        $source = $sourceProperty.Value
        if ($source.lifecycle -eq 'tombstone') {
            Add-Problem "$($entry.SourcePath) translates tombstoned key '$key'"
            continue
        }
        $expectedHash = [string]$messageSourceHash[$key]
        if ([string]$translation.sourceHash -cne $expectedHash) {
            Add-Problem "$($entry.SourcePath)`: '$key' sourceHash is stale; expected $expectedHash"
        }
        $translationProvenance["$($entry.Locale)/$key"] = [ordered]@{
            source     = $entry.SourcePath
            inputHash  = $entry.InputHash
            sourceHash = [string]$translation.sourceHash
        }

        $sourceKind = if ($null -ne $source.plural) { 'plural' } elseif ($null -ne $source.select) { 'select' } else { 'message' }
        $translatedKind = if ($null -ne $translation.plural) { 'plural' } elseif ($null -ne $translation.select) { 'select' } else { 'message' }
        if ($translatedKind -ne $sourceKind) {
            Add-Problem "$($entry.SourcePath)`: '$key' translates $translatedKind but its source is $sourceKind"
            continue
        }

        $merged = [ordered]@{
            lifecycle = [string]$source.lifecycle
            description = [string]$source.description
        }
        if ($source.replacedBy) { $merged.replacedBy = [string]$source.replacedBy }
        if ($source.placeholders) { $merged.placeholders = $source.placeholders }
        if ($sourceKind -eq 'message') {
            $merged.message = [string]$translation.message
        } else {
            $sourceVariants = @($source.$sourceKind.variants.PSObject.Properties.Name | Sort-Object)
            $translatedVariants = @($translation.$sourceKind.variants.PSObject.Properties.Name | Sort-Object)
            foreach ($variant in $sourceVariants) {
                if ($translatedVariants -notcontains $variant) {
                    Add-Problem "$($entry.SourcePath)`: '$key' has no translated '$variant' $sourceKind form"
                }
            }
            foreach ($variant in $translatedVariants) {
                if ($sourceVariants -notcontains $variant) {
                    Add-Problem "$($entry.SourcePath)`: '$key' adds unknown '$variant' $sourceKind form"
                }
            }
            $merged[$sourceKind] = [pscustomobject]@{
                selector = [string]$source.$sourceKind.selector
                variants = $translation.$sourceKind.variants
            }
        }
        $mergedObject = [pscustomobject]$merged
        # Run the same placeholder/plural checks over the merged contract that
        # will actually be compiled. A translation cannot smuggle in or drop
        # an argument just because its sourceHash happens to be current.
        $oneMessageCatalog = [pscustomobject]@{
            schema = 'yuruna.catalog/v1'; domain = $entry.Domain; locale = $entry.Locale
            messages = [pscustomobject]([ordered]@{ $key = $mergedObject })
        }
        Test-CatalogFile -Path $entry.SourcePath -Catalog $oneMessageCatalog -ExpectedLocale $entry.Locale `
            -PluralCategory @($manifest.locales.$($entry.Locale).pluralCategories) -IsSource:$true
        $mergedMessages[$key] = $mergedObject
    }
    # Compilation consumes the source-owned metadata merged with translated
    # wording. SourceText/InputHash stay those of the translation file for
    # provenance in the set manifest.
    $entry.Parsed = [pscustomobject]@{
        schema = 'yuruna.catalog/v1'; domain = $entry.Domain; locale = $entry.Locale
        messages = [pscustomobject]$mergedMessages
    }
}

# --- REGION: Validate supported locales
#
# The manifest's status field decides which locales a reader can actually be
# served. Nothing enforced what that claim required, so a locale could be
# marked supported while carrying a fraction of the default's keys and no
# pinned plural rule, and every gate would stay green -- the compiler would
# emit its artifacts, the drift check would find them current, and a reader
# would get a page of key names in a language nobody reviewed.
#
# Two rules, checked here because this is the only place that has both the
# manifest and every source catalog in hand.
$keysByLocale = @{}
foreach ($entry in $catalogs) {
    if (-not $keysByLocale.ContainsKey($entry.Locale)) { $keysByLocale[$entry.Locale] = @{} }
    foreach ($p in $entry.Parsed.messages.PSObject.Properties) {
        # A tombstone is a key deliberately retired, not a gap in a translation.
        if ($p.Value.lifecycle -eq 'tombstone') { continue }
        $keysByLocale[$entry.Locale][$p.Name] = $true
    }
}

foreach ($p in $manifest.locales.PSObject.Properties) {
    $name = $p.Name
    if ([string]$p.Value.status -ne 'supported') { continue }

    # A supported locale needs a rule that says which form a count takes. There
    # is no safe default: English and Portuguese disagree about zero, so a
    # borrowed rule is fluent, confident and wrong to everyone who speaks the
    # language.
    if (-not $p.Value.pluralRule) {
        Add-Problem "locale '$name' is marked supported but pins no pluralRule; a runtime cannot choose a plural form for it"
    }

    if ($name -eq $defaultLocale) { continue }

    # A supported locale answers for every key the default answers for. A
    # partial catalog does not degrade gracefully: the missing keys render as
    # their own names, in the middle of otherwise translated text.
    if (-not $keysByLocale.ContainsKey($name)) {
        Add-Problem "locale '$name' is marked supported and has no source catalog at all"
        continue
    }
    $missing = @()
    foreach ($key in ($keysByLocale[$defaultLocale].Keys | Sort-Object)) {
        if (-not $keysByLocale[$name].ContainsKey($key)) { $missing += $key }
    }
    if ($missing.Count -gt 0) {
        $shown = ($missing | Select-Object -First 5) -join ', '
        $tail = if ($missing.Count -gt 5) { " (and $($missing.Count - 5) more)" } else { '' }
        Add-Problem "locale '$name' is marked supported but is missing $($missing.Count) key(s) the default declares: $shown$tail"
    }
}

if ($script:Problem.Count -gt 0) {
    foreach ($p in $script:Problem) { Write-Output "  $p" }
    Write-Output ''
    Write-Output "Catalog validation failed with $($script:Problem.Count) problem(s)."
    exit 1
}

# --- REGION: Add pseudo-locales
$base = @($catalogs | Where-Object { $_.Locale -eq $manifest.default })
foreach ($entry in $base) {
    foreach ($mirrored in @($false, $true)) {
        $pseudo = ConvertTo-PseudoCatalog -Catalog $entry.Parsed -Mirrored:$mirrored
        $catalogs.Add(@{
            Locale = $pseudo.locale; Domain = $pseudo.domain; Parsed = $pseudo; SourceText = $null
            SourcePath = $entry.SourcePath; InputHash = $entry.InputHash; GeneratedFrom = $entry.Locale
        })
    }
}

# --- REGION: Compile and emit
$generatedRoot = Join-Path $Root 'generated'
$wanted = [ordered]@{}
$inventory = [System.Collections.Generic.List[object]]::new()

foreach ($entry in ($catalogs | Sort-Object { $_.Locale }, { $_.Domain })) {
    $compiled = [ordered]@{}
    $activeCount = 0
    foreach ($p in ($entry.Parsed.messages.PSObject.Properties | Sort-Object Name)) {
        if ($p.Value.lifecycle -eq 'tombstone') { continue }
        $compiled[$p.Name] = ConvertTo-CompiledMessage -Message $p.Value
        $activeCount++
    }

    $json = ConvertTo-CanonicalJson -Value $compiled
    $psText = Get-PowerShellArtifact -Locale $entry.Locale -Domain $entry.Domain -Compiled $compiled
    $jsText = Get-BrowserArtifact -Locale $entry.Locale -Domain $entry.Domain -Compiled $compiled
    $goText = Get-GoArtifact -Locale $entry.Locale -Domain $entry.Domain -Json $json

    $wanted[(Join-Path $generatedRoot "powershell/$($entry.Locale).$($entry.Domain).psd1")] = $psText
    $wanted[(Join-Path $generatedRoot "browser/$($entry.Locale).$($entry.Domain).js")] = $jsText
    $wanted[(Join-Path $generatedRoot "go/catalog/$($entry.Locale -replace '[^A-Za-z0-9]', '')_$($entry.Domain).go")] = $goText

    $inventory.Add([ordered]@{
        locale       = $entry.Locale
        domain       = $entry.Domain
        source       = $entry.SourcePath
        inputHash    = $entry.InputHash
        generatedFrom = if ($entry.GeneratedFrom) { $entry.GeneratedFrom } else { $null }
        activeKeys   = $activeCount
        compiledHash = Get-Sha256 -Text $json
        bytes        = [Text.UTF8Encoding]::new($false).GetByteCount($json)
    })
}

# Ordered, not a plain hashtable: an unordered map enumerates in whatever
# order the runtime chooses, so the same inputs would emit different bytes
# from one run to the next and every staleness check would be noise.
$inventoryJson = ConvertTo-CanonicalJson -Value ([ordered]@{
    schema  = 'yuruna.catalog-inventory/v1'
    entries = @($inventory)
})
$wanted[(Join-Path $Root 'manifests/inventory.json')] = $inventoryJson

# The set manifest names every artifact by content, so a rollback can restore
# one verified set and a consumer can prove which set it loaded. Its own hash
# is the identity carried at run time, so it is not stored inside itself.
$artifactHash = [ordered]@{}
$artifactBytes = [ordered]@{}
foreach ($k in ($wanted.Keys | Sort-Object)) {
    $rel = ([IO.Path]::GetRelativePath($RepoRoot, $k)) -replace '\\', '/'
    $artifactHash[$rel] = Get-Sha256 -Text $wanted[$k]
    $artifactBytes[$rel] = [Text.UTF8Encoding]::new($false).GetByteCount($wanted[$k])
}
$inputHash = [ordered]@{}
foreach ($path in @($schemaPath, $manifestPath)) {
    $rel = ([IO.Path]::GetRelativePath($RepoRoot, $path)) -replace '\\', '/'
    $inputHash[$rel] = Get-Sha256 -Text ([IO.File]::ReadAllText($path))
}
foreach ($entry in @($catalogs | Where-Object { -not $_.GeneratedFrom } | Sort-Object SourcePath)) {
    $path = Join-Path $Root $entry.SourcePath
    $rel = ([IO.Path]::GetRelativePath($RepoRoot, $path)) -replace '\\', '/'
    $inputHash[$rel] = $entry.InputHash
}
$sourceProvenance = [ordered]@{}
foreach ($entry in @($base | Sort-Object Domain)) {
    foreach ($p in @($entry.Parsed.messages.PSObject.Properties | Sort-Object Name)) {
        $sourceProvenance[$p.Name] = [ordered]@{
            domain     = $entry.Domain
            source     = $entry.SourcePath
            inputHash  = $entry.InputHash
            sourceHash = [string]$messageSourceHash[$p.Name]
        }
    }
}
$setManifest = ConvertTo-CanonicalJson -Value ([ordered]@{
    schema          = 'yuruna.catalog-set/v1'
    compilerVersion = '2026.09.13'
    catalogSchema   = 'yuruna.catalog/v1'
    localeManifest  = Get-Sha256 -Text ([IO.File]::ReadAllText($manifestPath))
    inputs           = $inputHash
    messageSources   = $sourceProvenance
    translations     = $translationProvenance
    artifacts       = $artifactHash
    artifactBytes    = $artifactBytes
    counts           = [ordered]@{
        sourceCatalogs = @($catalogs | Where-Object { -not $_.GeneratedFrom }).Count
        sourceMessages = @($messageSourceHash.Keys).Count
        generatedArtifacts = @($artifactHash.Keys).Count
        generatedBytes = [long](($artifactBytes.Values | Measure-Object -Sum).Sum)
    }
})
$wanted[(Join-Path $Root 'manifests/catalog-set.json')] = $setManifest

# --- REGION: Compare or write
$utf8 = [Text.UTF8Encoding]::new($false)
$stale = [System.Collections.Generic.List[string]]::new()
$written = 0

foreach ($path in $wanted.Keys) {
    $rel = ([IO.Path]::GetRelativePath($RepoRoot, $path)) -replace '\\', '/'
    $current = if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::ReadAllText($path) } else { $null }
    if ($current -eq $wanted[$path]) {
        if (-not $Quiet) { Write-Output "PASS  $rel" }
        continue
    }
    $stale.Add($rel)
    if ($Update) {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # Written beside the target and moved into place, so the artifact a
        # reader loads is never a partial one. A direct write that is
        # interrupted -- a full disk, a killed run, a machine losing power
        # mid-compile -- leaves a truncated catalog that still parses as far as
        # it got, and the drift check would then compare against the fragment.
        # Move is atomic within a directory on every filesystem this runs on.
        $temp = "$path.tmp"
        [IO.File]::WriteAllText($temp, $wanted[$path], $utf8)
        try {
            Move-Item -LiteralPath $temp -Destination $path -Force -ErrorAction Stop
        } catch {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            throw
        }
        $written++
        Write-Output "WROTE $rel"
    } else {
        Write-Output "STALE $rel"
    }
}

# An artifact left behind by a domain that no longer exists would keep being
# served, so it is reported as drift too.
foreach ($dir in @((Join-Path $generatedRoot 'powershell'), (Join-Path $generatedRoot 'browser'),
                   (Join-Path $generatedRoot 'go/catalog'))) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    foreach ($file in (Get-ChildItem -LiteralPath $dir -File)) {
        if ($wanted.Keys -contains $file.FullName) { continue }
        $rel = ([IO.Path]::GetRelativePath($RepoRoot, $file.FullName)) -replace '\\', '/'
        $stale.Add($rel)
        if ($Update) {
            Remove-Item -LiteralPath $file.FullName -Force
            $written++
            Write-Output "REMOVED $rel"
        }
        else { Write-Output "ORPHAN $rel" }
    }
}

} catch {
    $ErrorActionPreference = 'Continue'
    Write-Error $_.Exception.Message
    exit 2
}

Write-Output ''
$domains = @($catalogs | ForEach-Object { $_.Domain } | Sort-Object -Unique).Count
$locales = @($catalogs | ForEach-Object { $_.Locale } | Sort-Object -Unique).Count
if ($Update) {
    Write-Output "Compiled $domains domain(s) in $locales locale(s); wrote $written artifact(s)."
    if ($written -gt 0) { exit 1 }
    exit 0
}
Write-Output "Compiled $domains domain(s) in $locales locale(s); $($stale.Count) artifact(s) stale."
if ($stale.Count -gt 0) { exit 1 }
exit 0
