<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42372e63-d833-4327-b132-77f8f5d5b6d9
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna ci-gate spelling american-english naming
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
    Report British spellings in names and prose across the workspace
    repositories.
.DESCRIPTION
    The repositories use American English in prose and in names: variables,
    functions, types, test names, file names, database columns, JSON and YAML
    keys, enum and status values, and log, metric and label names. A prose
    spell check skips identifiers, so a British name such as a column
    `<word>_at` or a variable `$<word>Count` survives every review pass and
    spreads to its consumers before anyone renames it.

    Every tracked file of each root (plus new files git does not ignore) is
    checked unless it matches a "skip" glob of the data file or a
    "localePaths" glob, which names where translated text lives, for one of
    its non-English "locales". Each line is split into tokens (letters and
    digits joined by "_" or "-"), each token into subwords (camelCase,
    PascalCase, snake_case, kebab-case and digit boundaries), and every
    lowercased subword that is a key of the data file's word map is a
    finding, printed as
        <repository>/<path>:<line>: <token> -> <American token>
    The names in each file's path, directories included, are split the same
    way; a British name is printed once as
        <repository>/<path up to that name>: name <token> -> <American token>
    The content of a binary file (a NUL byte in its first 8000 bytes) and of
    the data file, which lists the British forms, is not checked. Exception
    tokens of the data file are removed from a line or name before it is
    split.

    Exit codes follow the entry-point contract:
        0  No finding.
        1  At least one finding.
        2  The check cannot run: git, a root or the data file is unusable.
.PARAMETER Root
    Repository roots to check. Default: this tool's repository plus the
    sibling checkouts yuruna-project, yuruna.link and amisad.dev that sit
    beside it; an absent sibling is noted and skipped.
.PARAMETER DataPath
    The word map, locale tags, skip globs and exceptions. Default:
    american-spelling.json beside this tool.

.EXAMPLE
    pwsh -NoProfile -File tools/Test-AmericanSpelling.ps1
    # Checks this repository and the sibling checkouts beside it.

.EXAMPLE
    pwsh -NoProfile -File tools/Test-AmericanSpelling.ps1 -Root .
    # Checks only the repository in the current directory.
#>

[CmdletBinding()]
[OutputType([string])]
param(
    [string[]]$Root,
    [string]$DataPath
)

$ErrorActionPreference = 'Stop'
# The entry-point exit-code contract, stated here so the tool runs as a
# single file without the test prelude.
$ExitOk = 0
$ExitFailure = 1
$ExitCannotRun = 2

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $DataPath) { $DataPath = Join-Path $PSScriptRoot 'american-spelling.json' }

function Write-CannotRun {
    param([string]$Message)
    Write-Output "Test-AmericanSpelling: cannot run: $Message"
}

function ConvertTo-GlobRegex {
    # "**/" matches any number of leading directories, "**" anything, "*"
    # and "?" stay within one path segment.
    param([string]$Glob)
    $builder = [Text.StringBuilder]::new('^')
    for ($i = 0; $i -lt $Glob.Length; $i++) {
        $ch = $Glob[$i]
        if ($ch -eq '*' -and $i + 1 -lt $Glob.Length -and $Glob[$i + 1] -eq '*') {
            if ($i + 2 -lt $Glob.Length -and $Glob[$i + 2] -eq '/') {
                [void]$builder.Append('(?:.*/)?'); $i += 2
            } else {
                [void]$builder.Append('.*'); $i += 1
            }
        } elseif ($ch -eq '*') {
            [void]$builder.Append('[^/]*')
        } elseif ($ch -eq '?') {
            [void]$builder.Append('[^/]')
        } else {
            [void]$builder.Append([regex]::Escape([string]$ch))
        }
    }
    [void]$builder.Append('$')
    [regex]::new($builder.ToString(), [Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

# --- REGION: Data file
if (-not (Test-Path -LiteralPath $DataPath -PathType Leaf)) {
    Write-CannotRun "data file not found: $DataPath"
    exit $ExitCannotRun
}
try {
    $data = Get-Content -LiteralPath $DataPath -Raw | ConvertFrom-Json -AsHashtable
} catch {
    Write-CannotRun "data file is not valid JSON: $DataPath ($($_.Exception.Message))"
    exit $ExitCannotRun
}
if (-not ($data.words -is [Collections.IDictionary]) -or $data.words.Count -eq 0) {
    Write-CannotRun "data file has no word map: $DataPath"
    exit $ExitCannotRun
}
$words = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
foreach ($key in $data.words.Keys) { $words[$key.ToLowerInvariant()] = [string]$data.words[$key] }
$dataFullPath = [IO.Path]::GetFullPath($DataPath)

$skipRegex = @(foreach ($entry in @($data.skip)) { if ($entry) { ConvertTo-GlobRegex $entry.path } })
$exceptions = @(foreach ($entry in @($data.exceptions)) {
    if (-not $entry -or -not $entry.token) { continue }
    [pscustomobject]@{ Repo = $entry.repo; Path = ConvertTo-GlobRegex $entry.path; Token = [string]$entry.token }
})
# A locale tag alone does not mark translated text: English-authored files
# such as a locale's terminology or plural fixtures carry the tag in their
# names and are checked.
$localeRegex = @(foreach ($locale in @($data.locales | Where-Object { $_ })) {
    foreach ($glob in @($data.localePaths | Where-Object { $_ })) { ConvertTo-GlobRegex $glob.Replace('{locale}', $locale) }
})

function ConvertTo-TrieRegex {
    # One alternation branch per shared prefix. A flat alternation of every
    # word takes the regex engine over a minute across the workspace; the
    # factored form takes a few seconds.
    param([string[]]$Word)
    $parts = @(foreach ($group in ($Word | Where-Object { $_ } | Group-Object { $_[0] } | Sort-Object Name)) {
        $rest = @($group.Group | ForEach-Object { $_.Substring(1) })
        $longer = @($rest | Where-Object { $_ })
        $inner = if ($longer.Count -gt 0) { ConvertTo-TrieRegex -Word $longer } else { '' }
        if ($inner -and $longer.Count -lt $rest.Count) { $inner = "(?:$inner)?" }
        [regex]::Escape([string]$group.Name) + $inner
    })
    if ($parts.Count -eq 1) { return $parts[0] }
    '(?:' + ($parts -join '|') + ')'
}

# A file is split into lines only when some British word occurs in it as a
# substring; most files never get that far.
$options = [Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant, Compiled'
$prefilter = [regex]::new((ConvertTo-TrieRegex -Word @($words.Keys)), $options)
$tokenRegex = [regex]::new('[A-Za-z0-9]+(?:[_-]+[A-Za-z0-9]+)*', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
$subwordRegex = [regex]::new('[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|[0-9]+', [Text.RegularExpressions.RegexOptions]::CultureInvariant)

function ConvertTo-MatchingCase {
    param([string]$Original, [string]$Replacement)
    if ($Original -ceq $Original.ToUpperInvariant() -and $Original.Length -gt 1) { return $Replacement.ToUpperInvariant() }
    if ([char]::IsUpper($Original[0])) { return [char]::ToUpperInvariant($Replacement[0]) + $Replacement.Substring(1) }
    $Replacement
}

function ConvertTo-MaskedText {
    # Blanks each exception token so a British word elsewhere in the text is
    # still found at its original column.
    param([string]$Text, [string[]]$Token)
    foreach ($exception in $Token) {
        $at = $Text.IndexOf($exception, [StringComparison]::OrdinalIgnoreCase)
        while ($at -ge 0) {
            $Text = $Text.Substring(0, $at) + (' ' * $exception.Length) + $Text.Substring($at + $exception.Length)
            $at = $Text.IndexOf($exception, $at + $exception.Length, [StringComparison]::OrdinalIgnoreCase)
        }
    }
    $Text
}

function Get-BritishToken {
    # Each distinct token of the text with a British subword, as
    # "<token> -> <American token>".
    param([string]$Text)
    $reported = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($tokenMatch in $tokenRegex.Matches($Text)) {
        $token = $tokenMatch.Value
        $suggestion = [Text.StringBuilder]::new()
        $last = 0
        $british = $false
        foreach ($subword in $subwordRegex.Matches($token)) {
            $american = $null
            if (-not $words.TryGetValue($subword.Value.ToLowerInvariant(), [ref]$american)) { continue }
            $british = $true
            [void]$suggestion.Append($token, $last, $subword.Index - $last)
            [void]$suggestion.Append((ConvertTo-MatchingCase -Original $subword.Value -Replacement $american))
            $last = $subword.Index + $subword.Length
        }
        if (-not $british -or -not $reported.Add($token)) { continue }
        [void]$suggestion.Append($token, $last, $token.Length - $last)
        "$token -> $($suggestion.ToString())"
    }
}

# --- REGION: Roots
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-CannotRun 'git is not on PATH'
    exit $ExitCannotRun
}
$notes = [Collections.Generic.List[string]]::new()
if (-not $Root -or $Root.Count -eq 0) {
    $Root = @($repoRoot)
    $parent = Split-Path -Parent $repoRoot
    foreach ($sibling in 'yuruna-project', 'yuruna.link', 'amisad.dev') {
        $candidate = Join-Path $parent $sibling
        if (Test-Path -LiteralPath (Join-Path $candidate '.git')) { $Root += $candidate }
        else { $notes.Add("sibling $sibling not present; not checked") }
    }
}

$findings = [Collections.Generic.List[string]]::new()
$findingFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$fileCount = 0
foreach ($rootPath in $Root) {
    $full = [IO.Path]::GetFullPath($rootPath)
    $listed = @(& git -C $full ls-files -z --cached --others --exclude-standard 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Write-CannotRun "not a git work tree: $full"
        exit $ExitCannotRun
    }
    $repoName = Split-Path -Leaf $full
    $repoExceptions = @($exceptions | Where-Object { -not $_.Repo -or $_.Repo -eq $repoName })
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $namesChecked = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($relative in (($listed -join '') -split "`0")) {
        if (-not $relative -or -not $seen.Add($relative)) { continue }
        if (@($localeRegex | Where-Object { $_.IsMatch($relative) }).Count -gt 0) { continue }
        if (@($skipRegex | Where-Object { $_.IsMatch($relative) }).Count -gt 0) { continue }
        $path = [IO.Path]::GetFullPath((Join-Path $full $relative))
        if (-not [IO.File]::Exists($path)) { continue }
        $fileExceptions = @($repoExceptions | Where-Object { $_.Path.IsMatch($relative) } | ForEach-Object { $_.Token })
        # Every directory on the path is a name too; each is reported once,
        # however many files sit below it.
        $segments = $relative -split '/'
        for ($depth = 1; $depth -le $segments.Count; $depth++) {
            $prefix = $segments[0..($depth - 1)] -join '/'
            if (-not $namesChecked.Add($prefix)) { continue }
            $name = ConvertTo-MaskedText -Text $segments[$depth - 1] -Token $fileExceptions
            if (-not $prefilter.IsMatch($name)) { continue }
            foreach ($hit in @(Get-BritishToken -Text $name)) {
                $findings.Add(('{0}/{1}: name {2}' -f $repoName, $prefix, $hit))
                [void]$findingFiles.Add("$repoName/$relative")
            }
        }
        if ($path -eq $dataFullPath) { continue }
        $bytes = [IO.File]::ReadAllBytes($path)
        if ([Array]::IndexOf($bytes, [byte]0, 0, [Math]::Min($bytes.Length, 8000)) -ge 0) { continue }
        $fileCount++
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        if (-not $prefilter.IsMatch($text)) { continue }
        $lines = $text -split "`n"
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if (-not $prefilter.IsMatch($lines[$index])) { continue }
            $line = ConvertTo-MaskedText -Text $lines[$index] -Token $fileExceptions
            foreach ($hit in @(Get-BritishToken -Text $line)) {
                $findings.Add(('{0}/{1}:{2}: {3}' -f $repoName, $relative, ($index + 1), $hit))
                [void]$findingFiles.Add("$repoName/$relative")
            }
        }
    }
}

foreach ($note in $notes) { Write-Output "Test-AmericanSpelling: $note" }
foreach ($finding in $findings) { Write-Output $finding }
if ($findings.Count -eq 0) {
    Write-Output "Test-AmericanSpelling: $fileCount file(s) in $($Root.Count) repositories checked, no British spelling found."
    exit $ExitOk
}
$summary = ("Test-AmericanSpelling: {0} British spelling(s) in {1} file(s). Rename each to the American form " +
    'and update every producer and consumer in the same change; a name an external standard fixes is ' +
    'recorded as an exception in tools/american-spelling.json.') -f $findings.Count, $findingFiles.Count
Write-Output $summary
exit $ExitFailure
