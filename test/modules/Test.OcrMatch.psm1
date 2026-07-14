<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42a9b3c7-d1e5-4f02-9b8a-6c3d7e1f4a52
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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

# OCR-tolerant text matching for the sequence engine. The pure matcher
# (Get-OCRNormalized / Test-OCRMatch over the confusion-group tables) and the
# multi-engine combiner (Test-CombinedOcrMatch) are isolated here so they are
# independently unit-testable and reachable -- via one export -- from both the
# engine (Wait-ForText) and the sequence handlers (sshWaitReady), instead of an
# engine-private function the handler scope could not resolve.

Import-Module (Join-Path $PSScriptRoot 'Test.OcrEngine.psm1') -Global -Force
# Memoize Get-OCRNormalized for repeated patterns. The same pattern string
# is re-normalized on every poll in Test-OCRMatch (pattern + per-segment
# normalize in Strategy 3). Patterns are bounded (one per sequence step),
# so the cache stays small. Line / full-text inputs are NOT cached -- they
# vary per call and would balloon memory.
$script:OcrPatternCache = @{}

# -- OCR-tolerant matching ----------------------------------------------------

# Common OCR confusion groups: characters within each group are frequently
# misrecognized as each other on console/monospace text.
# Sources: WinRT/Vision observed errors, UNLV OCR accuracy studies.
$script:OCRConfusionGroups = @(
    'wuv'       # w<->u<->v -- most common on console fonts
    'mn'        # m<->n
    'oO0@'      # o<->O<->0<->@ -- '@' frequently substituted for '0' on console fonts
                # (e.g. "test-ubuntu-server-01" reads as "test-ubuntu-server-@1")
    "lI1i[]$([char]0x0131)"  # l<->I<->1<->i<->[<->]<->U+0131 -- brackets misread as l/1/i, U+0131 (dotless i) from Vision OCR
    'S5s'       # S<->5<->s
    'B8'        # B<->8
    'Z2z'       # Z<->2<->z
    'gq9'       # g<->q<->9
    'ce'        # c<->e -- at small sizes
    ':;.'       # :<->;<->. -- punctuation frequently mangled on terminal fonts
)

# Characters that are stripped entirely during normalization.
# OCR engines frequently insert em/en dashes, smart quotes, or other
# Unicode substitutions for ASCII punctuation on terminal screens.
# Stripping these (along with their ASCII equivalents) prevents
# mismatches when the pattern uses plain ASCII.
#
# '@' is NOT in this list -- it lives in the oO0@ confusion group
# (above) because OCR mistakes for '0' are more common in this codebase
# than '@' being dropped from a prompt. With '@' canonicalized to 'o',
# a pattern with literal '@' (e.g. "[ec2-user@host]$") still matches
# OCR text that reads '@' as '@' OR as '0' -- both canonicalize the same.
$script:OCRStripChars = [System.Collections.Generic.HashSet[char]]::new(
    [char[]]@(
        '-', [char]0x2014, [char]0x2013, [char]0x2012,  # -, --, -, -
        '[', ']', '$', '~', '"', '`'                    # terminal prompt chars frequently dropped by OCR
    )
)

# Why a canonical-form lookup rather than the raw confusion groups: at
# match time Test-OCRMatch normalizes BOTH the pattern and the OCR text
# through this map, so a search for "Install" against "lnstall" hits a
# single hash lookup per character instead of iterating every group.
$script:OCRCanonical = @{}
foreach ($group in $script:OCRConfusionGroups) {
    $canonical = [char]::ToLowerInvariant($group[0])
    foreach ($ch in $group.ToCharArray()) {
        $script:OCRCanonical[[char]::ToLowerInvariant($ch)] = $canonical
    }
}

<#
.SYNOPSIS
    Normalizes a string for OCR comparison: lowercase, strip spaces/dashes, map confusion groups.
.DESCRIPTION
    Each character is lowercased and mapped to the canonical representative of its
    OCR confusion group.  Spaces and dash-like characters (hyphens, em/en dashes)
    are stripped entirely because OCR on courier/monospace fonts inserts spurious
    spaces and frequently substitutes Unicode dashes for ASCII hyphens.
#>
function Get-OCRNormalized {
    param([string]$Text)
    $sb = [System.Text.StringBuilder]::new($Text.Length)
    foreach ($ch in $Text.ToCharArray()) {
        if ($ch -eq ' ') { continue }
        if ($script:OCRStripChars.Contains($ch)) { continue }
        $lower = [char]::ToLowerInvariant($ch)
        if ($script:OCRCanonical.ContainsKey($lower)) {
            [void]$sb.Append($script:OCRCanonical[$lower])
        } else {
            [void]$sb.Append($lower)
        }
    }
    return $sb.ToString()
}

<#
.SYNOPSIS
    Tests if OCR text matches a pattern with tolerance for character confusion,
    spurious spaces, and dropped characters.
.DESCRIPTION
    Normalizes both strings (lowercase, space/dash-stripped, confusion-group-mapped)
    and checks if the pattern appears as an approximate match in any line
    of the text.  At least 85% of the normalized pattern characters must match.

    Two matching strategies are tried (either passing is sufficient):
    1. Positional (sliding window): handles arbitrary single-character
       substitutions not covered by confusion groups (e.g. R->K).
    2. Subsequence with span limit: handles dropped characters
       (e.g. "Password" OCR'd as "assuord").

    Also handles:
    - Character confusion (w<->u<->v, o<->O<->0<->@, l<->I<->1<->i<->[<->], etc.)
    - Punctuation confusion (:<->;<->.)
    - Dash normalization (-, --, -, - all stripped)
    - Spurious spaces from courier/monospace OCR
#>
function Test-OCRMatch {
    param([string]$Text, [string]$Pattern)
    $normPattern = $script:OcrPatternCache[$Pattern]
    if ($null -eq $normPattern) {
        $normPattern = Get-OCRNormalized $Pattern
        $script:OcrPatternCache[$Pattern] = $normPattern
    }
    # A pattern with no matchable content (normalizes to empty, e.g. "]$") must NOT auto-pass a
    # wait condition -- returning $true would "match" any text, including a blank/degraded screen.
    if ($normPattern.Length -eq 0) { return $false }
    # Require at least 85% of normalized pattern chars to appear in order.
    # This allows ~1 dropped char per 7 pattern chars (e.g. "Password:" -> "assuord:")
    # while rejecting scattered coincidental matches in long log lines.
    # The :;. confusion group handles punctuation substitution (e.g. "rassword."
    # matches "Password:" via the sliding window at 8/9 = 89%).
    $threshold = [int][Math]::Ceiling($normPattern.Length * 0.85)
    $patternChars = $normPattern.ToCharArray()
    # Matched chars in the text must span at most 2x the pattern length to
    # prevent hits where common chars are scattered across a long line.
    $maxSpan = $normPattern.Length * 2
    # Loop-invariant: depends only on $patternChars, hoisted from the
    # per-line foreach so multi-line OCR text doesn't reallocate per line.
    $patternCharSet = [System.Collections.Generic.HashSet[char]]::new([char[]]$patternChars)

    foreach ($line in ($Text -split "`n")) {
        $normLine = Get-OCRNormalized $line
        if ($normLine.Length -eq 0) { continue }

        # --- REGION: Strategy 1: Positional (sliding window) comparison
        # Slide the pattern across the text and count character matches at each
        # aligned position.  This naturally handles arbitrary single-character
        # substitutions (e.g. R->K in "Retype"->"Ketype") that are not covered
        # by confusion groups and that break the subsequence algorithm.
        $patLen = $normPattern.Length
        if ($normLine.Length -ge $patLen) {
            for ($offset = 0; $offset -le ($normLine.Length - $patLen); $offset++) {
                $posMatched = 0
                for ($i = 0; $i -lt $patLen; $i++) {
                    if ($normLine[$offset + $i] -eq $patternChars[$i]) { $posMatched++ }
                }
                if ($posMatched -ge $threshold) { return $true }
            }
        }

        # --- REGION: Strategy 2: Subsequence match (handles dropped characters)
        # Try from each text position that contains any pattern character.
        # A single greedy pass can latch onto an early occurrence (e.g. the 'l'
        # in "Iinux") and stretch the span past the limit even though the real
        # match ("login:") starts later and is compact.  Starting from any
        # pattern char (not just the first) also handles the case where the
        # first pattern char was dropped by OCR (e.g. "Password" -> "assuord").
        for ($startIdx = 0; $startIdx -lt $normLine.Length; $startIdx++) {
            if (-not $patternCharSet.Contains($normLine[$startIdx])) { continue }

            $ti = $startIdx
            $matched = 0
            $firstMatchPos = -1
            $lastMatchPos  = -1
            foreach ($pc in $patternChars) {
                $savedTi = $ti
                $found = $false
                while ($ti -lt $normLine.Length) {
                    if ($normLine[$ti] -eq $pc) {
                        $matched++
                        if ($firstMatchPos -lt 0) { $firstMatchPos = $ti }
                        $lastMatchPos = $ti
                        $ti++
                        $found = $true
                        break
                    }
                    $ti++
                }
                if (-not $found) { $ti = $savedTi }
            }

            if ($matched -ge $threshold) {
                $span = $lastMatchPos - $firstMatchPos + 1
                if ($span -le $maxSpan) { return $true }
            }
        }
    }

    # --- REGION: Strategy 3: Segment match (handles OCR word reordering)
    # OCR may reorder parts of a line (e.g. "[ec2-user@test-amazon-linux01 ~]$"
    # becomes "test-amazon-I inux01 login: ecZ-user").  Split the original pattern
    # on characters that are stripped during normalization (@, -, etc.) to get
    # meaningful segments, normalize each, and check that every segment appears
    # somewhere in the full normalized text (across all lines).
    $normFull = Get-OCRNormalized $Text
    $splitPattern = [regex]::Split($Pattern, '[\s@\-\[\]$~"''`]+') | Where-Object { $_.Length -gt 0 }
    if ($splitPattern.Count -gt 1) {
        $allFound = $true
        foreach ($seg in $splitPattern) {
            $normSeg = $script:OcrPatternCache[$seg]
            if ($null -eq $normSeg) {
                $normSeg = Get-OCRNormalized $seg
                $script:OcrPatternCache[$seg] = $normSeg
            }
            if ($normSeg.Length -eq 0) { continue }
            if (-not $normFull.Contains($normSeg)) {
                $allFound = $false
                break
            }
        }
        if ($allFound) { return $true }
    }

    return $false
}

# -- Multi-engine OCR combine logic ------------------------------------------

# +-------------------------------------------------------------------------+
# | COMBINE MODE: controls how per-engine detection booleans are merged.   |
# |                                                                        |
# |  'Or'  -- pattern detected by ANY engine -> match  (default, resilient)  |
# |  'And' -- pattern detected by ALL engines -> match  (strict, fewer FPs)  |
# |                                                                        |
# | To switch: change the value below, or set $env:YURUNA_OCR_COMBINE.    |
# +-------------------------------------------------------------------------+

<#
.SYNOPSIS
    Returns the OCR combine mode ('Or' or 'And'), honouring $env:YURUNA_OCR_COMBINE.
.DESCRIPTION
    Reads the YURUNA_OCR_COMBINE environment variable and returns 'And' when it
    is set to that value, otherwise 'Or' (the default). Any other non-empty value
    is rejected with a throw so a typo cannot silently fall back to the default.
#>
function Get-OcrCombineMode {
    $envVal = $env:YURUNA_OCR_COMBINE
    if ($envVal -and $envVal -notin @('Or', 'And')) {
        throw "Invalid YURUNA_OCR_COMBINE value '$envVal'. Only 'Or' and 'And' are allowed."
    }
    if ($envVal -eq 'And') { return 'And' }
    return 'Or'   # <- default
}

<#
.SYNOPSIS
    Runs all enabled OCR engines on a screen capture, tests each engine's
    text against every pattern, and returns $true/$false based on the
    combine mode.

.DESCRIPTION
    For each enabled OCR engine:
      1. Run OCR on ImagePath -> engine text
      2. For each pattern, test engine text -> boolean
    Collect a boolean per engine (true if ANY pattern matched that engine's text).

    Combine mode (Or/And) controls how the per-engine booleans are merged:
      Or  -> $true if at least one engine detected any pattern
      And -> $true only if every engine detected at least one pattern

.PARAMETER ImagePath
    Path to the screen capture PNG. The image is sent to each OCR engine
    as-is -- no preprocessing.

.PARAMETER Pattern
    One or more patterns to match (any pattern matching counts for that engine).

.PARAMETER FreshMatchTailLines
    When greater than 0, only the last N lines of each engine's OCR text are
    tested. Defaults to 0 (test all lines). Typically set to 12 for freshMatch.

.OUTPUTS
    A hashtable with:
      Match        -- [bool] combined result
      EngineResults -- [ordered] engine-name -> @{ Text; Matched; MatchedPattern }
      AnyText      -- [string] concatenation of all engine texts (for accumulation)
#>
function Test-CombinedOcrMatch {
    param(
        [Parameter(Mandatory)] [string]$ImagePath,
        [Parameter(Mandatory)] [string[]]$Pattern,
        [int]$FreshMatchTailLines = 0
    )

    # Test.OcrEngine.psm1 is loaded by Wait-ForText (the only caller in the
    # hot path) before the poll loop; importing it again here -- per poll --
    # paid the cmdlet + path-resolution + timestamp-check cost on every
    # iteration even though -Force is a no-op when nothing changed.

    $combineMode = Get-OcrCombineMode
    $enabledProviders = Get-EnabledOcrProvider
    $engineResults = [ordered]@{}
    $combinedMatch = $false
    $allTexts = @()

    # Why sequential, not parallel: the per-engine cost (~5-15 ms after
    # the WinRT worker warm-up) is well below the dispatch overhead of
    # Start-ThreadJob + RemotingWait, AND the combine modes are
    # short-circuit by design -- running both engines in parallel and
    # then discarding the slower one would waste work in the common
    # (Or-mode, first-engine-hits) case.
    foreach ($engineName in $enabledProviders) {
        try {
            $engineText = (Invoke-OcrProvider -Name $engineName -ImagePath $ImagePath) ?? ''
            $engineText = $engineText.Trim()
        } catch {
            Write-Warning "OCR provider '$engineName' failed: $_"
            $engineText = ''
        }

        $textForMatch = if ($FreshMatchTailLines -gt 0 -and $engineText) {
            $lines = $engineText -split "`n"
            ($lines | Select-Object -Last $FreshMatchTailLines) -join "`n"
        } else {
            $engineText
        }

        $matched = $false
        $matchedPattern = $null
        if ($textForMatch) {
            foreach ($p in $Pattern) {
                if (Test-OCRMatch -Text $textForMatch -Pattern $p) {
                    $matched = $true
                    $matchedPattern = $p
                    break
                }
            }
        }

        $engineResults[$engineName] = @{
            Text           = $engineText
            Matched        = $matched
            MatchedPattern = $matchedPattern
        }
        if ($engineText) { $allTexts += $engineText }

        # Log each engine's result as it runs (before possible short-circuit)
        $snippet = $engineText.Length -le 120 ? $engineText : ("..." + $engineText.Substring($engineText.Length - 120))
        $status = $matched ? "MATCH '$matchedPattern'" : "no match"
        Write-Debug "      [$engineName] $status | $snippet"

        # Short-circuit: Or returns early on first match, And on first non-match
        if ($combineMode -eq 'Or' -and $matched) {
            Write-Debug "      Short-circuit ($combineMode): skipping remaining engines"
            $combinedMatch = $true
            break
        } elseif ($combineMode -eq 'And' -and -not $matched) {
            Write-Debug "      Short-circuit ($combineMode): skipping remaining engines"
            $combinedMatch = $false
            break
        }

        # If we reach here without breaking, track the last engine's result
        $combinedMatch = $matched
    }

    if ($enabledProviders.Count -eq 0) { $combinedMatch = $false }

    # Concatenate all engine texts for accumulation in non-FreshMatch mode
    $allEngineText = ($allTexts | Where-Object { $_ }) -join "`n"

    return @{
        Match         = $combinedMatch
        EngineResults = $engineResults
        AnyText       = $allEngineText
    }
}

Export-ModuleMember -Function Get-OCRNormalized, Test-OCRMatch, Get-OcrCombineMode, Test-CombinedOcrMatch