<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42c7e015-6b28-4d3f-9a47-1e6c8b02df95
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna ci-gate utf8 encoding globalization catalog
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
    Hold the globalization tree and framework documentation to clean,
    normalized, BOM-less UTF-8.
.DESCRIPTION
    The globalization tree and Markdown documents can contain translated
    text, so tools/Test-AsciiNoBom.ps1 excludes them from its 7-bit ASCII
    gate. A translated sentence IS accented text, and escaping it would
    hand the translator a file they cannot read or review. This gate checks
    globalization, docs, README.md, and install/README.md by default, so
    those exclusions are a change of rules rather than an absence of them.
    Pass -Path to check other files or directories.

    What it rejects, and why each one is a real defect rather than a
    preference:

      BOM                A byte-order mark is invisible in every editor,
                         rides into hashes and here-strings, and breaks a
                         byte-for-byte consumer. Never wanted anywhere.
      Invalid UTF-8      A byte sequence that is not UTF-8 means the file
                         was written through the wrong encoder. It will
                         decode differently on another host.
      U+FFFD             The replacement character is the residue of a
                         decode that already failed. Shipping it means
                         shipping text nobody can recover.
      Unnormalized text  Two spellings of the same accented word compare
                         unequal, so a key or a lookup silently misses.
                         Catalog text is held to NFC.
      Stray controls     A control character that is not tab or newline is
                         invisible and changes how the string renders.

    Bidirectional formatting characters are the deliberate exception. The
    mirrored pseudo-locale exists to force right-to-left rendering, and it
    does that with real bidi controls; the same characters are how a
    right-to-left translation isolates an embedded machine token. They are
    allowed here and are checked for balance instead.

    Exit codes follow the entry-point contract:
        0  Every file is clean UTF-8.
        1  At least one file failed.
        2  The tree to check does not exist.

.PARAMETER Path
    Files or directories to check. Directories are searched recursively.
    Default: globalization, docs, README.md, and install/README.md,
    relative to this repository's root.
.PARAMETER Quiet
    Print only failures and the summary.

.EXAMPLE
    pwsh tools/Test-Utf8Catalog.ps1
    Checks globalization, docs, README.md, and install/README.md;
    exits 0 / 1 / 2.
#>

[CmdletBinding()]
[OutputType([string])]
param(
    [string[]]$Path,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

# The catalog tree plus the framework's operator documents and their
# translations. The ASCII gate deliberately excludes Markdown, so without these
# roots a translated document could carry a BOM, an unnormalized name, or a
# replacement character left by a bad decode and no gate would read its bytes --
# and a normal ReadAllText succeeds on all three.
if (-not $Path -or $Path.Count -eq 0) {
    $Path = @('globalization', 'docs', 'README.md', 'install/README.md')
}

# The bidi formatting set. These are legitimate content: the mirrored
# pseudo-locale forces direction with them, and a right-to-left translation
# isolates an embedded machine token the same way.
$BidiControl = @(
    0x200E, 0x200F,                         # LRM, RLM
    0x202A, 0x202B, 0x202C, 0x202D, 0x202E, # embeddings and overrides
    0x2066, 0x2067, 0x2068, 0x2069          # isolates
)
# The two that open a run needing an explicit close, paired with their closer.
$BidiOpen  = @(0x202A, 0x202B, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068)
$BidiClose = @(0x202C, 0x2069)

$textLike = @('*.json', '*.js', '*.psd1', '*.psm1', '*.ps1', '*.go', '*.md', '*.yml', '*.yaml', '*.txt')

$targets = [System.Collections.Generic.List[string]]::new()
foreach ($p in $Path) {
    $full = if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $RepoRoot $p }
    if (Test-Path -LiteralPath $full -PathType Container) {
        foreach ($f in (Get-ChildItem -LiteralPath $full -Recurse -File | Sort-Object FullName)) {
            $name = $f.Name
            if (@($textLike | Where-Object { $name -like $_ })) { $targets.Add($f.FullName) }
        }
    } elseif (Test-Path -LiteralPath $full -PathType Leaf) {
        $targets.Add($full)
    } else {
        $ErrorActionPreference = 'Continue'
        Write-Error "Test-Utf8Catalog: nothing to check at '$p'"
        exit 2
    }
}

if ($targets.Count -eq 0) {
    $ErrorActionPreference = 'Continue'
    Write-Error 'Test-Utf8Catalog: no files matched; the gate would pass vacuously'
    exit 2
}

# Throwing decoders, so an invalid sequence surfaces instead of turning into
# a replacement character we would then report as a different defect.
$strict = [Text.UTF8Encoding]::new($false, $true)
$failures = [System.Collections.Generic.List[string]]::new()

foreach ($file in $targets) {
    $rel = ([IO.Path]::GetRelativePath($RepoRoot, $file)) -replace '\\', '/'
    $bytes = [IO.File]::ReadAllBytes($file)
    $problems = [System.Collections.Generic.List[string]]::new()

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $problems.Add('starts with a UTF-8 BOM')
    }

    $text = $null
    try { $text = $strict.GetString($bytes) }
    catch { $problems.Add("is not valid UTF-8: $($_.Exception.Message)") }

    if ($null -ne $text) {
        $fffd = $text.IndexOf([char]0xFFFD)
        if ($fffd -ge 0) { $problems.Add("carries U+FFFD at index $fffd, so it was decoded wrong before it was written") }

        # IsNormalized, not a comparison against the normalized string:
        # PowerShell's -eq / -ne on strings compare through the invariant
        # CULTURE, which treats a decomposed sequence and its composed form as
        # equal. Written that way this check silently never fires, which is
        # the same class of defect it exists to catch.
        if (-not $text.IsNormalized([Text.NormalizationForm]::FormC)) {
            $problems.Add('is not NFC-normalized, so equal-looking text would compare unequal')
        }

        $depth = 0
        for ($i = 0; $i -lt $text.Length; $i++) {
            $code = [int]$text[$i]
            if ($BidiOpen -contains $code) { $depth++; continue }
            if ($BidiClose -contains $code) { $depth--; continue }
            if ($BidiControl -contains $code) { continue }
            if ($code -lt 0x20 -and $code -ne 9 -and $code -ne 10 -and $code -ne 13) {
                $problems.Add(("carries control character U+{0:X4} at index {1}" -f $code, $i))
                break
            }
        }
        if ($depth -ne 0) {
            $problems.Add('leaves a bidi run unclosed, so direction leaks into whatever renders next')
        }
    }

    if ($problems.Count -eq 0) {
        if (-not $Quiet) { Write-Output "PASS  $rel" }
        continue
    }
    foreach ($p in $problems) { $failures.Add("$rel $p") }
}

if ($failures.Count -gt 0) {
    Write-Output ''
    foreach ($f in $failures) { Write-Output "  FAIL  $f" }
}

Write-Output ''
Write-Output "Test-Utf8Catalog: $($targets.Count) file(s) checked, $($failures.Count) problem(s)."
if ($failures.Count -gt 0) { exit 1 }
exit 0
