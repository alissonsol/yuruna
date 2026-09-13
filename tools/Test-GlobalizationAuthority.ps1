<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42de31ac-8059-47bf-a365-0d6eb81f94c7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization literal protocol ratchet gate
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
    Prevent converted source from regaining prose and machine consumers from
    learning rendered messages as protocol.
.DESCRIPTION
    Converted regions are deliberately small while rollout is incremental.
    Each is bounded by stable source markers, scanned with its language parser
    or a comment-aware string scanner, and must contain zero unclassified
    operator prose. Registering a region is therefore a one-way ratchet: new
    wording goes through a catalog or the gate fails.

    Boundary files are reverse-discovered from the code registry. Catalog
    sentences and the named historical phrases may not occur in their code.
    A compatibility reader needs an exact path, phrase, reason, and deletion
    date; an absent/stale exception fails instead of becoming permanent lore.
.PARAMETER Root
    Framework tree to check. Defaults to this tool's repository.
.PARAMETER Manifest
    Conversion authority manifest. Defaults under globalization/manifests.
.PARAMETER Today
    Date used to evaluate compatibility expiry. Injectable for mutation tests.
.PARAMETER Quiet
    Print only findings and summary.
#>

[CmdletBinding()]
param(
    [string]$Root,
    [string]$Manifest,
    [datetime]$Today = [datetime]::UtcNow.Date,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
if (-not $Manifest) { $Manifest = Join-Path $Root 'globalization/manifests/conversion-authority.json' }
$codeRegistryPath = Join-Path $Root 'globalization/manifests/code-registry.json'

foreach ($required in @($Manifest, $codeRegistryPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Output "Test-GlobalizationAuthority: required manifest is missing: $required"
        exit 2
    }
}
$authority = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Manifest))
$registry = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($codeRegistryPath))
if ($authority.schema -ne 'yuruna.conversion-authority/v1') {
    Write-Output "FINDING: unsupported conversion manifest schema '$($authority.schema)'"
    exit 1
}

function Get-SourceString {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)

    if ([IO.Path]::GetExtension($Path) -in @('.ps1', '.psm1')) {
        $tokens = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$null)
        return [string[]]@($tokens | Where-Object { $_.Kind -in @('StringLiteral', 'StringExpandable') } |
            ForEach-Object { [string]$_.Value })
    }
    # One comment-aware lexical pass for JavaScript and Go. JavaScript regex
    # bodies are literals too: /Paused \(waiting...\)/ is just as much a prose
    # protocol branch as an equality against a quoted string. Recognizing the
    # expression context here also prevents // inside a regex from turning the
    # rest of its line into a phantom comment.
    $found = [Collections.Generic.List[string]]::new()
    $i = 0
    $previous = ''
    $previousWord = ''
    $regexAfterWord = @('return', 'throw', 'case', 'delete', 'void', 'typeof', 'instanceof', 'in', 'of', 'yield')
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }
        if ($c -eq '/' -and $next -eq '/') {
            while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($c -eq '/' -and $next -eq '*') {
            $i += 2
            while ($i + 1 -lt $Text.Length -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i++ }
            $i = [Math]::Min($Text.Length, $i + 2)
            continue
        }
        if ($c -eq '"' -or $c -eq "'" -or $c -eq '`') {
            $quote = $c; $i++; $value = [Text.StringBuilder]::new()
            while ($i -lt $Text.Length -and $Text[$i] -ne $quote) {
                if ($Text[$i] -eq '\' -and $quote -ne '`' -and $i + 1 -lt $Text.Length) {
                    $i++; [void]$value.Append($Text[$i]); $i++; continue
                }
                [void]$value.Append($Text[$i]); $i++
            }
            if ($i -lt $Text.Length) { $i++ }
            $found.Add($value.ToString())
            $previous = 'literal'; $previousWord = ''
            continue
        }
        $opensRegex = $c -eq '/' -and [IO.Path]::GetExtension($Path) -eq '.js' -and
            (-not $previous -or $previous -match '^[({[=,:;!?&|]$' -or $regexAfterWord -contains $previousWord)
        if ($opensRegex) {
            $i++; $value = [Text.StringBuilder]::new(); $inClass = $false
            while ($i -lt $Text.Length) {
                $part = $Text[$i]
                if ($part -eq '\' -and $i + 1 -lt $Text.Length) {
                    # Punctuation escapes carry the punctuation as prose; a
                    # semantic escape such as \s stays visibly non-prose.
                    if ($Text[$i + 1] -match '[A-Za-z0-9]') { [void]$value.Append('\') }
                    $i++; [void]$value.Append($Text[$i]); $i++; continue
                }
                if ($part -eq '[') { $inClass = $true }
                elseif ($part -eq ']') { $inClass = $false }
                elseif ($part -eq '/' -and -not $inClass) { $i++; break }
                [void]$value.Append($part); $i++
            }
            while ($i -lt $Text.Length -and $Text[$i] -match '[A-Za-z]') { $i++ }
            $found.Add($value.ToString())
            $previous = 'literal'; $previousWord = ''
            continue
        }
        if ($c -match '[A-Za-z0-9_$]') {
            $start = $i
            while ($i -lt $Text.Length -and $Text[$i] -match '[A-Za-z0-9_$]') { $i++ }
            $previousWord = $Text.Substring($start, $i - $start)
            $previous = 'word'
            continue
        }
        if (-not [char]::IsWhiteSpace($c)) { $previous = [string]$c; $previousWord = '' }
        $i++
    }
    return $found.ToArray()
}

function Get-SourceWithoutEmbeddedCatalog {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Text)

    $startMarker = '// >>> yuruna-i18n embedded block'
    $endMarker = '// <<< yuruna-i18n embedded block'
    $clean = $Text
    while ($true) {
        $start = $clean.IndexOf($startMarker, [StringComparison]::Ordinal)
        if ($start -lt 0) { break }
        $end = $clean.IndexOf($endMarker, $start, [StringComparison]::Ordinal)
        if ($end -lt 0) { break }
        $after = $end + $endMarker.Length
        $clean = $clean.Remove($start, $after - $start).Insert($start, "`n")
    }
    return $clean
}

function Test-OperatorProse {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $value = $Text.Trim()
    if ($value.Length -lt 8 -or ($value -split '\s+').Count -lt 3) { return $false }
    $letters = ([regex]::Matches($value, '[A-Za-z]')).Count
    return $letters -ge ($value.Length / 2)
}

$findings = [Collections.Generic.List[string]]::new()
foreach ($scope in @($authority.convertedScopes)) {
    $path = [string]$scope.path
    $full = Join-Path $Root $path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $findings.Add("converted scope file is missing: $path"); continue
    }
    $text = [IO.File]::ReadAllText($full)
    $start = $text.IndexOf([string]$scope.startMarker, [StringComparison]::Ordinal)
    if ($start -lt 0) { $findings.Add("$path has no start marker '$($scope.startMarker)'"); continue }
    $end = $text.IndexOf([string]$scope.endMarker, $start + ([string]$scope.startMarker).Length,
        [StringComparison]::Ordinal)
    if ($end -lt 0) { $findings.Add("$path has no end marker '$($scope.endMarker)' after its start"); continue }
    $region = $text.Substring($start, $end - $start)
    foreach ($token in @($scope.requiredTokens)) {
        if ($region.IndexOf([string]$token, [StringComparison]::Ordinal) -lt 0) {
            $findings.Add("$path converted scope lost required token '$token'")
        }
    }
    foreach ($literal in @(Get-SourceString -Path $path -Text $region)) {
        if (-not (Test-OperatorProse -Text $literal)) { continue }
        if (@($scope.allowedProse) -ccontains $literal) { continue }
        $findings.Add("$path converted scope contains unexplained operator prose: '$literal'")
    }
}

$boundaryFiles = @($registry.codes | ForEach-Object {
        @($_.producedBy) + @($_.consumedBy)
    } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
$exceptions = @($authority.protocolExceptions)
foreach ($exception in $exceptions) {
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$exception.removeAfter, 'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) {
        $findings.Add("protocol exception has an invalid deletion date: $($exception.path) '$($exception.text)'")
    } elseif ($Today.Date -gt $date.Date) {
        $findings.Add("protocol exception expired on $($exception.removeAfter): $($exception.path) '$($exception.text)'")
    }
    if (-not $exception.reason) { $findings.Add("protocol exception has no reason: $($exception.path) '$($exception.text)'") }
}

$phrases = @($authority.legacyProtocolPhrases | ForEach-Object { [string]$_ })
foreach ($catalog in @(Get-ChildItem -LiteralPath (Join-Path $Root 'globalization/catalogs/en-US') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    # Catalog fragments are serialized structures. Pull human strings from the
    # JSON tree, then keep phrase-sized values; short labels would make common
    # words such as "Continue" look like protocol wherever they occur.
    foreach ($m in [regex]::Matches([IO.File]::ReadAllText($catalog.FullName), '"((?:[^"\\]|\\.)*)"')) {
        try { $value = ConvertFrom-Json -InputObject ('"' + $m.Groups[1].Value + '"') } catch { continue }
        if ([string]$value -match '\s' -and ([string]$value).Length -ge 8) { $phrases += [string]$value }
    }
}
$phrases = @($phrases | Sort-Object -Unique)

foreach ($path in $boundaryFiles) {
    $full = Join-Path $Root $path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $findings.Add("code-registry boundary file is missing: $path"); continue
    }
    $source = Get-SourceWithoutEmbeddedCatalog -Text ([IO.File]::ReadAllText($full))
    $literals = @(Get-SourceString -Path $path -Text $source)
    foreach ($phrase in $phrases) {
        $matched = @($literals | Where-Object {
                $_.IndexOf($phrase, [StringComparison]::Ordinal) -ge 0
            }).Count -gt 0
        if (-not $matched) { continue }
        $exception = @($exceptions | Where-Object {
                $_.path -ceq $path -and $_.text -ceq $phrase
            }) | Select-Object -First 1
        if (-not $exception) {
            $findings.Add("$path carries rendered prose at a registered machine boundary: '$phrase'")
        }
    }
}
foreach ($exception in $exceptions) {
    if ($boundaryFiles -cnotcontains [string]$exception.path) {
        $findings.Add("protocol exception path is not a code-registry boundary: $($exception.path)")
        continue
    }
    $full = Join-Path $Root ([string]$exception.path)
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $source = Get-SourceWithoutEmbeddedCatalog -Text ([IO.File]::ReadAllText($full))
        $literals = @(Get-SourceString -Path ([string]$exception.path) -Text $source)
        $matched = @($literals | Where-Object {
                $_.IndexOf([string]$exception.text, [StringComparison]::Ordinal) -ge 0
            }).Count -gt 0
        if (-not $matched) {
            $findings.Add("stale protocol exception no longer matches code: $($exception.path) '$($exception.text)'")
        }
    }
}

if ($findings.Count -gt 0) {
    foreach ($finding in $findings) { Write-Output "FINDING: $finding" }
    Write-Output "Test-GlobalizationAuthority: $($findings.Count) finding(s)."
    exit 1
}
if (-not $Quiet) {
    Write-Output "Test-GlobalizationAuthority: $(@($authority.convertedScopes).Count) converted scope(s), $($boundaryFiles.Count) boundary file(s), and $($exceptions.Count) dated exception(s) checked."
}
exit 0
