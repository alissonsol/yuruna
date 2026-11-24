<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42623d37-5542-4fd6-8bd7-fcd92f20175d
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.OcrEngine.psm1') -Global -Force
# Memoize Get-OCRNormalized for repeated patterns. The same pattern string
# is re-normalized on every poll in Test-OCRMatch (pattern + per-segment
# normalize in Strategy 3). Patterns are bounded (one per sequence step),
# so the cache stays small. This table holds pattern normalization only;
# repeated whole comparisons use the separately bounded cache below.
$script:OcrPatternCache = @{}

# OCR recognition can reuse an unchanged frame while the readiness and failure
# scans still repeat the same tolerant comparisons. Keep a few exact text
# inputs and their boolean answers; the matcher is pure, so neither a positive
# nor a negative answer changes until text, pattern, or matching policy changes.
# The size limits also cover callers outside the screenshot poll loop.
$script:OcrMatchCache = [Collections.Generic.List[object]]::new()
$script:OcrMatchCacheFrameLimit = 4
$script:OcrMatchCachePatternLimit = 32
$script:OcrMatchCacheTextLimit = 65536
$script:OcrMatchCachePatternLengthLimit = 1024

# --- REGION: OCR-tolerant matching
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

# See https://yuruna.link/4213a0b3-00b1
$script:OCRStripChars = [System.Collections.Generic.HashSet[char]]::new(
    [char[]]@(
        '-', [char]0x2014, [char]0x2013, [char]0x2012,  # hyphen, em dash, en dash, figure dash
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
.PARAMETER NoSegmentMatch
    Drops Strategy 3, leaving the two per-line, span-bounded strategies.
    Strategy 3 asks only whether every normalized segment of the pattern
    appears somewhere in the text -- in any order, on any line, at any
    distance apart -- so a multi-word pattern whose segments normalize to
    two- and four-character tokens is satisfied by coincidence once the
    screen carries a few KB of dense output such as a package or asset
    fetch listing URLs. Prompt checks and anti-patterns pass this switch:
    accepting scattered words can type input before the guest is ready or
    end a healthy run. Callers that need reordered text can retain Strategy 3.
#>
function Test-OCRMatch {
    param([string]$Text, [string]$Pattern, [switch]$NoSegmentMatch)
    $cacheable = $Text.Length -le $script:OcrMatchCacheTextLimit -and
        $Pattern.Length -le $script:OcrMatchCachePatternLengthLimit
    $entry = $null
    $answers = $null
    if ($cacheable) {
        foreach ($candidate in $script:OcrMatchCache) {
            # Case and line boundaries are part of the original input. Ordinal
            # comparison avoids hash allocations and culture-dependent keys.
            if ([string]::Equals($candidate.Text, $Text, [StringComparison]::Ordinal)) {
                $entry = $candidate
                $answers = if ($NoSegmentMatch) { $entry.Strict } else { $entry.Loose }
                $cached = $false
                if ($answers.TryGetValue($Pattern, [ref]$cached)) { return $cached }
                break
            }
        }
    }

    $matched = Test-OCRMatchCore -Text $Text -Pattern $Pattern -NoSegmentMatch:$NoSegmentMatch
    if ($cacheable) {
        if ($null -eq $entry) {
            $entry = [pscustomobject]@{
                Text = $Text
                Strict = [Collections.Generic.Dictionary[string, bool]]::new([StringComparer]::Ordinal)
                Loose = [Collections.Generic.Dictionary[string, bool]]::new([StringComparer]::Ordinal)
            }
            $script:OcrMatchCache.Add($entry)
            while ($script:OcrMatchCache.Count -gt $script:OcrMatchCacheFrameLimit) {
                $script:OcrMatchCache.RemoveAt(0)
            }
            $answers = if ($NoSegmentMatch) { $entry.Strict } else { $entry.Loose }
        }
        if (($entry.Strict.Count + $entry.Loose.Count) -lt $script:OcrMatchCachePatternLimit) {
            $answers[$Pattern] = [bool]$matched
        }
    }
    return $matched
}

function Test-OCRMatchCore {
    param([string]$Text, [string]$Pattern, [switch]$NoSegmentMatch)
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
    # See https://yuruna.link/4213a0b3-00b2
    $maxSpan = $normPattern.Length + ($normPattern.Length - $threshold)
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
    # See https://yuruna.link/4213a0b3-00b3
    if ($NoSegmentMatch) { return $false }
    return (Test-OCRSegmentMatch -Text $Text -Pattern $Pattern)
}

function Test-OCRSegmentMatch {
    <#
    .SYNOPSIS
        The one matching strategy that reads across lines: every word of the
        pattern somewhere in the normalized text.
    .DESCRIPTION
        The other strategies test one line at a time, so a line that matches
        in a joined text matched in the text it came from. A caller that
        already tested each part on its own needs only this one for the join.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Text, [string]$Pattern)
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

# --- REGION: Multi-engine OCR combine logic
# Combine mode: 'Or' (default, resilient) vs 'And' (strict, fewer FPs);
# switch via $env:YURUNA_OCR_COMBINE or the default in Get-OcrCombineMode below.

function Get-OcrCombineMode {
    <#
    .SYNOPSIS
        Returns the OCR combine mode ('Or' or 'And'), honoring $env:YURUNA_OCR_COMBINE.
    .DESCRIPTION
        Reads the YURUNA_OCR_COMBINE environment variable and returns 'And' when it
        is set to that value, otherwise 'Or' (the default). Any other non-empty value
        is rejected with a throw so a typo cannot silently fall back to the default.
    #>
    $envVal = $env:YURUNA_OCR_COMBINE
    if ($envVal -and $envVal -notin @('Or', 'And')) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_c8d3447d823adc70' -Arguments @{ envVal = "$envVal"; setting = 'YURUNA_OCR_COMBINE' })
    }
    if ($envVal -eq 'And') { return 'And' }
    return 'Or'   # <- default
}

function New-OcrFallbackReuseState {
    <#
    .SYNOPSIS
        The per-wait state Test-CombinedOcrMatch -FallbackReuse keeps.
    .PARAMETER MaxReuse
        Frames in a row a later engine's previous read may stand in for a new
        one, so a static screen is still read by every engine at least once
        every MaxReuse + 1 frames.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a new in-memory hashtable; it changes no system state.')]
    param([int]$MaxReuse = 2)
    return @{ PrimaryText = $null; Texts = @{}; Reused = 0; MaxReuse = $MaxReuse }
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

.PARAMETER NoSegmentMatch
    Require a bounded match within one OCR line, retaining character-confusion
    and dropped-character tolerance. Do not assemble a match from scattered words.

.PARAMETER FallbackReuse
    State a wait keeps across its polls (New-OcrFallbackReuseState). In Or mode
    an engine after the first is not run again while the first engine reads
    exactly the text it read on the previous frame and the later engine read
    that frame without a match: its previous text is used for the frame
    instead, for at most MaxReuse frames in a row. The first engine costs
    milliseconds where a fallback such as tesseract costs seconds of CPU, and
    a console parked on a screen the wait is not looking for was read by the
    fallback on every poll. A reused entry carries Reused = $true.

.OUTPUTS
    A hashtable with:
      Match        -- [bool] combined result
      EngineResults -- [ordered] engine-name -> @{ Text; Matched; MatchedPattern; Reused }
      AnyText      -- [string] concatenation of all engine texts (for accumulation)
#>
function Test-CombinedOcrMatch {
    param(
        [Parameter(Mandatory)] [string]$ImagePath,
        [Parameter(Mandatory)] [string[]]$Pattern,
        [int]$FreshMatchTailLines = 0,
        [switch]$NoSegmentMatch,
        [hashtable]$FallbackReuse
    )

    # No Import-Module here: Wait-ForText (the only caller in the hot path)
    # already loaded Test.OcrEngine.psm1 before the poll loop, and re-importing
    # per poll would pay the cmdlet + path-resolution + timestamp-check cost on
    # every iteration even though -Force is a no-op when nothing changed.

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
    $primaryText = $null
    $anyReused = $false
    foreach ($engineName in $enabledProviders) {
        $reused = $FallbackReuse -and $combineMode -eq 'Or' -and $primaryText -and
            $FallbackReuse.PrimaryText -ceq $primaryText -and $FallbackReuse.Texts.ContainsKey($engineName) -and
            [int]$FallbackReuse.Reused -lt [int]$FallbackReuse.MaxReuse
        if ($reused) {
            $engineText = [string]$FallbackReuse.Texts[$engineName]
            $anyReused = $true
        } else {
            try {
                $engineText = (Invoke-OcrProvider -Name $engineName -ImagePath $ImagePath) ?? ''
                $engineText = $engineText.Trim()
            } catch {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_da873a65a08c6d04' -Arguments @{ engineName = "$engineName"; value = "$_" })
                $engineText = ''
            }
        }
        $isPrimary = $null -eq $primaryText
        if ($isPrimary) { $primaryText = $engineText }

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
                if (Test-OCRMatch -Text $textForMatch -Pattern $p -NoSegmentMatch:$NoSegmentMatch) {
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
            Reused         = [bool]$reused
        }
        if ($engineText) { $allTexts += $engineText }
        # A later engine's read that matched nothing can stand in for the next
        # frame; a read that matched ends the wait and is never needed again.
        if ($FallbackReuse -and -not $isPrimary -and -not $reused -and -not $matched) {
            $FallbackReuse.Texts[$engineName] = $engineText
        }

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
    if ($FallbackReuse) {
        $FallbackReuse.Reused = if ($anyReused) { [int]$FallbackReuse.Reused + 1 } else { 0 }
        # A frame the first engine read as blank is not evidence of an unchanged
        # screen, so the next frame runs every engine.
        $FallbackReuse.PrimaryText = $primaryText
    }

    # Concatenate all engine texts for accumulation in non-FreshMatch mode
    $allEngineText = ($allTexts | Where-Object { $_ }) -join "`n"

    return @{
        Match         = $combinedMatch
        EngineResults = $engineResults
        AnyText       = $allEngineText
    }
}

<#
.SYNOPSIS
    Report patterns an OCR engine DID read but that sat outside the freshMatch
    tail window, so a wait that timed out on present-but-unwindowed text can say
    so instead of reporting a bare "no match" (pure).
.DESCRIPTION
    freshMatch tests only the last N lines, and that narrowness is the point: it
    is what stops a marker left on screen by an EARLIER step from satisfying
    this one. The cost is a false negative that looks identical to a real one.
    When the guest prints what the wait wants and then ANYTHING else follows it
    -- a console repaint, a shell completion listing, a late daemon line -- the
    sought text slides past N while still being plainly on screen, and both the
    engine text and the transcript say only "no match". An operator reading the
    captured frame then sees the very text the wait claimed was missing, with
    nothing to explain the contradiction.

    Re-testing the FULL engine text once the wait has already lost tells the two
    cases apart. This runs at the timeout only, never in the poll loop, so a
    healthy wait pays nothing for it.

    Per-line testing supplies the distance. A pattern that matches the whole
    text but no single line -- one straddling a line break -- is still reported,
    just without a count: the conclusion the operator needs is the same.
.PARAMETER EngineResult
    The EngineResults map from the last Test-CombinedOcrMatch of the wait:
    engine name -> @{ Text; Matched; MatchedPattern }.
.PARAMETER Pattern
    The patterns the wait was seeking.
.PARAMETER FreshMatchTailLines
    The window that was actually applied. 0 or less means no window was in
    force, so there is nothing to report.
.PARAMETER NoSegmentMatch
    Apply the same bounded matching policy as the wait being diagnosed.
.OUTPUTS
    [string[]] one line per engine+pattern near miss; empty when the window was
    not the reason -- nothing matched anywhere, or the frame was short enough
    that the window covered all of it. Empty is therefore NOT the claim that
    nothing on screen came close; those are three different screens sharing one
    value. Get-OcrClosestOnScreen answers that question, and a failure record
    carries both so neither is read as the other.
#>
function Get-OcrFreshWindowNearMiss {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()][System.Collections.IDictionary]$EngineResult,
        [string[]]$Pattern,
        [int]$FreshMatchTailLines,
        [switch]$NoSegmentMatch
    )
    $found = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $EngineResult -or $FreshMatchTailLines -le 0) { return [string[]]$found.ToArray() }

    foreach ($engineName in $EngineResult.Keys) {
        $entry = $EngineResult[$engineName]
        if ($null -eq $entry) { continue }
        # An engine that matched is not a near miss, and in Or-mode a matching
        # engine short-circuits the rest -- neither reaches this function on a
        # failed wait, but both are cheap to exclude.
        if ([bool]$entry.Matched) { continue }
        $text = [string]$entry.Text
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $lines = $text -split "`n"
        # The window covered the whole frame, so it cannot have hidden anything:
        # the tail Test-CombinedOcrMatch tested is character-for-character this
        # same text, and it already failed to match, so re-testing here is
        # guaranteed to fail again and the skip costs no signal. What a frame
        # this short DID hold comes from Get-OcrClosestOnScreen instead.
        if ($lines.Count -le $FreshMatchTailLines) { continue }
        $windowStart = $lines.Count - $FreshMatchTailLines

        foreach ($p in $Pattern) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            # The tail already failed, so a hit on the full text is by
            # construction a hit above the window.
            if (-not (Test-OCRMatch -Text $text -Pattern $p -NoSegmentMatch:$NoSegmentMatch)) { continue }
            $lastHit = -1
            for ($i = $windowStart - 1; $i -ge 0; $i--) {
                if (Test-OCRMatch -Text $lines[$i] -Pattern $p -NoSegmentMatch:$NoSegmentMatch) { $lastHit = $i; break }
            }
            $where = if ($lastHit -ge 0) { "$($windowStart - $lastHit) line(s) above" } else { 'above' }
            $found.Add("[$engineName] read '$p' $where the ${FreshMatchTailLines}-line freshMatch window: the text WAS on screen, just outside what was tested. Raise freshMatchTailLines for this step, or stop the guest printing after the marker.")
        }
    }
    return [string[]]$found.ToArray()
}

<#
.SYNOPSIS
    Score how closely a pattern resembles one piece of OCR text, 0.0 to 1.0 (pure).
.DESCRIPTION
    Both sides go through Get-OCRNormalized first, so the score is measured on
    the same canonical form Test-OCRMatch decides on: character confusion the
    matcher forgives costs nothing here either, which is what makes a low score
    mean "this is not a mangled reading of the pattern" rather than "OCR was
    imperfect".

    The pattern is slid across the text with overhang allowed at both ends, so
    text SHORTER than the pattern still scores. That case is the whole point on
    a bare console: a login screen's lines are all shorter than a marker string,
    and a scorer that skipped them would report nothing exactly where there is
    nothing else to report.

    Only aligned character equality counts. The out-of-order and dropped-
    character forms Test-OCRMatch's other strategies accept are deliberately not
    rewarded, because a number read as "how close was it" has to keep falling as
    the text diverges instead of plateauing on coincidental overlap.
.PARAMETER Text
    The text to score -- normally a single screen line.
.PARAMETER Pattern
    The pattern the wait was seeking.
.OUTPUTS
    [double] the best fraction of normalized pattern characters that lined up,
    0.0 to 1.0. Test-OCRMatch's own bar is 0.85.
#>
function Get-OCRSimilarityScore {
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [AllowEmptyString()][string]$Text,
        [AllowEmptyString()][string]$Pattern
    )
    if ([string]::IsNullOrEmpty($Pattern)) { return 0.0 }
    $normPattern = $script:OcrPatternCache[$Pattern]
    if ($null -eq $normPattern) {
        $normPattern = Get-OCRNormalized $Pattern
        $script:OcrPatternCache[$Pattern] = $normPattern
    }
    if ($normPattern.Length -eq 0) { return 0.0 }
    if ([string]::IsNullOrEmpty($Text)) { return 0.0 }
    $normText = Get-OCRNormalized $Text
    if ($normText.Length -eq 0) { return 0.0 }

    $patLen = $normPattern.Length
    $best = 0
    for ($offset = -($patLen - 1); $offset -lt $normText.Length; $offset++) {
        $hit = 0
        for ($i = 0; $i -lt $patLen; $i++) {
            $ti = $offset + $i
            if ($ti -lt 0) { continue }
            if ($ti -ge $normText.Length) { break }
            if ($normText[$ti] -eq $normPattern[$i]) { $hit++ }
        }
        if ($hit -gt $best) { $best = $hit }
    }
    return [double]$best / $patLen
}

<#
.SYNOPSIS
    Report the line each OCR engine DID read that came closest to each sought
    pattern, and how close, so a failed wait says what the screen held and not
    only what it lacked (pure).
.DESCRIPTION
    A wait that ends unmatched records the patterns it sought and a tail of the
    screen, and leaves an operator to compare the two by eye. The comparison
    they actually want -- was anything on that screen a degraded reading of what
    I asked for? -- is one the matcher already made and discarded.

    The two answers have different owners. A high score means the text printed
    and the read of it fell short, so the capture or the matcher's tolerance is
    where to look. A low score means the screen was showing something else
    entirely, so the guest never got as far as printing it. A bare timeout
    cannot tell those apart, and neither can a near-miss list: that list is
    empty for a screen too short for its window to hide anything, which is
    exactly the shape of a console parked at a login prompt.

    Runs at the timeout only, never in the poll loop, so a healthy wait pays
    nothing for it.
.PARAMETER EngineResult
    The EngineResults map from the last Test-CombinedOcrMatch of the wait:
    engine name -> @{ Text; Matched; MatchedPattern }.
.PARAMETER Pattern
    The patterns the wait was seeking.
.PARAMETER MaxLineLength
    Longest excerpt quoted from a screen line. A wrapped log line can be
    thousands of characters, and the failure record is read by people.
.OUTPUTS
    [string[]] one line per engine+pattern; empty only when no engine produced
    any text at all, which is a different failure (nothing was read off the
    screen) with its own counters.
#>
function Get-OcrClosestOnScreen {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()][System.Collections.IDictionary]$EngineResult,
        [string[]]$Pattern,
        [int]$MaxLineLength = 120
    )
    $found = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $EngineResult) { return [string[]]$found.ToArray() }

    foreach ($engineName in $EngineResult.Keys) {
        $entry = $EngineResult[$engineName]
        if ($null -eq $entry) { continue }
        # An engine that matched has nothing to explain.
        if ([bool]$entry.Matched) { continue }
        $text = [string]$entry.Text
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $lines = @(($text -split "`n") | ForEach-Object { $_.TrimEnd("`r") })

        foreach ($p in $Pattern) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $bestScore = 0.0
            $bestIndex = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
                $score = Get-OCRSimilarityScore -Text $lines[$i] -Pattern $p
                if ($score -gt $bestScore) {
                    $bestScore = $score
                    $bestIndex = $i
                }
            }
            if ($bestIndex -lt 0) {
                $found.Add("[$engineName] nothing in the $($lines.Count)-line frame shared a single character with '$p', so the screen was not a degraded reading of it -- it was showing something else.")
                continue
            }
            $pct = [int][Math]::Round($bestScore * 100)
            $excerpt = $lines[$bestIndex].Trim()
            if ($excerpt.Length -gt $MaxLineLength) { $excerpt = $excerpt.Substring(0, $MaxLineLength) + '...' }
            $found.Add("[$engineName] closest to '$p' on the $($lines.Count)-line frame was line $($bestIndex + 1), '$excerpt', at $pct% -- a match needs 85%.")
        }
    }
    return [string[]]$found.ToArray()
}

# --- REGION: Word-box matching for located clicks
function Get-OcrWordCore {
    <#
    .SYNOPSIS
        The text of one word without its leading and trailing characters that
        are neither a letter nor a digit (pure).
    .DESCRIPTION
        'Next.', '(Next)' and '|Next' give 'Next'; '24.04.3' and 'test-ubuntu'
        keep their inner punctuation; '...' and '|' give an empty string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $start = 0
    $end = $Text.Length - 1
    while ($start -le $end -and -not [char]::IsLetterOrDigit($Text[$start])) { $start++ }
    while ($end -ge $start -and -not [char]::IsLetterOrDigit($Text[$end])) { $end-- }
    if ($start -gt $end) { return '' }
    return $Text.Substring($start, $end - $start + 1)
}

function Get-OcrLineHeight {
    <#
    .SYNOPSIS
        The median box height of each line read, keyed '<block>.<par>.<line>' (pure).
    .DESCRIPTION
        The median, upper middle when the count is even, and at least 1. One
        tall box on a line must not widen the gap two words may have between
        them, which the taller of two boxes would do.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyCollection()][AllowNull()][object[]]$Box)
    $heights = @{}
    foreach ($entry in $Box) {
        if ($null -eq $entry) { continue }
        $key = '{0}.{1}.{2}' -f [int]$entry.block, [int]$entry.par, [int]$entry.line
        if (-not $heights.ContainsKey($key)) { $heights[$key] = [System.Collections.Generic.List[int]]::new() }
        $heights[$key].Add([int]$entry.h)
    }
    $result = @{}
    foreach ($key in @($heights.Keys)) {
        $sorted = [int[]]@($heights[$key] | Sort-Object)
        $result[$key] = [math]::Max(1, $sorted[[int][math]::Floor($sorted.Count / 2)])
    }
    return $result
}

function Test-OcrWordBoxAdjacent {
    <#
    .SYNOPSIS
        Whether the box Next continues the phrase that the box Previous ends (pure).
    .DESCRIPTION
        Both boxes carry the same block, paragraph and line numbers, and Next
        starts no further right of Previous's right edge than twice the median
        height of that line. Tesseract reads with --psm 6, one uniform block,
        so text at equal height in two columns shares a line number; the gap
        test is what keeps the columns apart. Overlapping boxes are adjacent.
    .PARAMETER LineHeight
        The map Get-OcrLineHeight returns for the boxes of the read.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][object]$Previous,
        [Parameter(Mandatory)][object]$Next,
        [Parameter(Mandatory)][hashtable]$LineHeight
    )
    if ([int]$Previous.block -ne [int]$Next.block -or [int]$Previous.par -ne [int]$Next.par -or
        [int]$Previous.line -ne [int]$Next.line) { return $false }
    $key = '{0}.{1}.{2}' -f [int]$Next.block, [int]$Next.par, [int]$Next.line
    $height = if ($LineHeight.ContainsKey($key)) { [int]$LineHeight[$key] } else { 1 }
    return (([int]$Next.x - ([int]$Previous.x + [int]$Previous.w)) -le (2 * $height))
}

function Find-OcrWordBoxMatch {
    <#
    .SYNOPSIS
        Every place a label is read among OCR word boxes, in box order (pure).
    .DESCRIPTION
        The label is split on white space; each token must match one box and
        each box after the first must continue the box before it on the same
        line (Test-OcrWordBoxAdjacent). Comparisons are literal and ignore
        case: '[', ']', '*' and '?' in a label are ordinary characters.
        Under contains a box matches when its text contains the token. Under
        word the box's core equals the token's core (Get-OcrWordCore), so
        'Next' finds 'Next.' and '(next)' but not 'Nextcloud', and a box with
        no letter or digit is stepped over.
        Assign the call directly: it returns one array as one pipeline object,
        and @() around it would always count one element.
    .PARAMETER Box
        Word boxes as Get-TesseractWordBox returns them; $null elements are skipped.
    .PARAMETER Label
        The label to find.
    .PARAMETER MatchMode
        contains (the default) or word.
    .OUTPUTS
        System.Collections.Hashtable[]. Each match: @{ text; x; y; w; h;
        centerX; centerY; block; par; line; word }, the rectangle the union of
        the matched boxes and the identifiers those of the first box.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable[]], [object[]])]
    param(
        [AllowEmptyCollection()][AllowNull()][object[]]$Box,
        [AllowEmptyString()][string]$Label,
        [ValidateSet('contains', 'word')][string]$MatchMode = 'contains'
    )
    $found = [System.Collections.Generic.List[hashtable]]::new()
    $word = $MatchMode -ceq 'word'
    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($token in ($Label.Trim() -split '\s+')) {
        $value = if ($word) { Get-OcrWordCore -Text $token } else { $token }
        if (-not [string]::IsNullOrEmpty($value)) { $tokens.Add($value) }
    }
    if ($tokens.Count -eq 0 -or $null -eq $Box -or $Box.Count -eq 0) { return ,$found.ToArray() }

    $usable = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $Box) {
        if ($null -eq $entry) { continue }
        $text = [string]$entry.text
        if ($word) {
            $core = Get-OcrWordCore -Text $text
            if ($core.Length -eq 0) { continue }
            $usable.Add(@{ Box = $entry; Text = $core })
        } else {
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            $usable.Add(@{ Box = $entry; Text = $text })
        }
    }
    $heights = Get-OcrLineHeight -Box $Box

    for ($i = 0; $i -le $usable.Count - $tokens.Count; $i++) {
        $hit = $true
        for ($j = 0; $j -lt $tokens.Count; $j++) {
            $candidate = $usable[$i + $j]
            $same = if ($word) {
                [string]::Equals($candidate.Text, $tokens[$j], [StringComparison]::OrdinalIgnoreCase)
            } else {
                $candidate.Text.IndexOf($tokens[$j], [StringComparison]::OrdinalIgnoreCase) -ge 0
            }
            if (-not $same -or ($j -gt 0 -and -not (Test-OcrWordBoxAdjacent -Previous $usable[$i + $j - 1].Box -Next $candidate.Box -LineHeight $heights))) {
                $hit = $false
                break
            }
        }
        if (-not $hit) { continue }
        $parts = [System.Collections.Generic.List[object]]::new()
        for ($j = 0; $j -lt $tokens.Count; $j++) { $parts.Add($usable[$i + $j].Box) }
        $minX = [int]::MaxValue; $minY = [int]::MaxValue; $maxX = [int]::MinValue; $maxY = [int]::MinValue
        foreach ($part in $parts) {
            $minX = [math]::Min($minX, [int]$part.x)
            $minY = [math]::Min($minY, [int]$part.y)
            $maxX = [math]::Max($maxX, [int]$part.x + [int]$part.w)
            $maxY = [math]::Max($maxY, [int]$part.y + [int]$part.h)
        }
        $first = $parts[0]
        $found.Add(@{
            text    = (@($parts | ForEach-Object { [string]$_.text }) -join ' ')
            x       = $minX
            y       = $minY
            w       = $maxX - $minX
            h       = $maxY - $minY
            centerX = [int](($minX + $maxX) / 2)
            centerY = [int](($minY + $maxY) / 2)
            block   = [int]$first.block
            par     = [int]$first.par
            line    = [int]$first.line
            word    = [int]$first.word
        })
    }
    return ,$found.ToArray()
}

function Get-OcrWordBoxLine {
    <#
    .SYNOPSIS
        The phrases a label can match: runs of adjacent word boxes, in box order (pure).
    .DESCRIPTION
        A new segment starts at the first box and at every box that does not
        continue the one before it (Test-OcrWordBoxAdjacent), so two columns
        on one line read as two segments. Assign the call directly: it
        returns one array as one pipeline object.
    .PARAMETER Box
        Word boxes as Get-TesseractWordBox returns them; $null elements are skipped.
    .OUTPUTS
        System.Collections.Hashtable[]. Each segment: @{ block; par; line;
        segment; text; x; y; w; h; words }, segment counted from 1 within its
        line and the rectangle the union of its boxes.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable[]], [object[]])]
    param([AllowEmptyCollection()][AllowNull()][object[]]$Box)
    $found = [System.Collections.Generic.List[hashtable]]::new()
    if ($null -eq $Box -or $Box.Count -eq 0) { return ,$found.ToArray() }
    $heights = Get-OcrLineHeight -Box $Box
    $perLine = @{}
    $current = $null
    $previous = $null
    foreach ($entry in $Box) {
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.text)) { continue }
        if ($null -eq $current -or -not (Test-OcrWordBoxAdjacent -Previous $previous -Next $entry -LineHeight $heights)) {
            $key = '{0}.{1}.{2}' -f [int]$entry.block, [int]$entry.par, [int]$entry.line
            $perLine[$key] = 1 + [int]$perLine[$key]
            $current = @{ block = [int]$entry.block; par = [int]$entry.par; line = [int]$entry.line; segment = $perLine[$key]; Boxes = [System.Collections.Generic.List[object]]::new() }
            $found.Add($current)
        }
        $current.Boxes.Add($entry)
        $previous = $entry
    }
    foreach ($segment in $found) {
        $minX = [int]::MaxValue; $minY = [int]::MaxValue; $maxX = [int]::MinValue; $maxY = [int]::MinValue
        foreach ($part in $segment.Boxes) {
            $minX = [math]::Min($minX, [int]$part.x)
            $minY = [math]::Min($minY, [int]$part.y)
            $maxX = [math]::Max($maxX, [int]$part.x + [int]$part.w)
            $maxY = [math]::Max($maxY, [int]$part.y + [int]$part.h)
        }
        $segment.text = @($segment.Boxes | ForEach-Object { [string]$_.text }) -join ' '
        $segment.x = $minX
        $segment.y = $minY
        $segment.w = $maxX - $minX
        $segment.h = $maxY - $minY
        $segment.words = $segment.Boxes.Count
        $segment.Remove('Boxes')
    }
    return ,$found.ToArray()
}

function Get-OcrClosestWord {
    <#
    .SYNOPSIS
        The words read that come closest to a label, best first, formatted
        "'<text>' <pct>%" (pure).
    .DESCRIPTION
        Candidates are every box text and, for a label of k words with k at
        least 2, every run of k consecutive boxes on one line whose word
        numbers rise by one from box to box, so a run never joins the last
        word of one read to the first word of another when a caller passes
        two reads in one array. Each candidate is kept once without regard to
        case, scored with Get-OCRSimilarityScore and rounded to two decimals;
        scores under MinimumScore are dropped. Ties keep the order first seen.
        The caller writes @(Get-OcrClosestWord ...).
    .PARAMETER Box
        Word boxes; $null elements are skipped.
    .PARAMETER Label
        The label that was sought.
    .PARAMETER Maximum
        At most this many entries, 1 to 20.
    .PARAMETER MinimumScore
        The lowest score listed, 0 to 1.
    .OUTPUTS
        [string[]] one entry per word or run.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyCollection()][AllowNull()][object[]]$Box,
        [AllowEmptyString()][string]$Label,
        [ValidateRange(1, 20)][int]$Maximum = 5,
        [ValidateRange(0.0, 1.0)][double]$MinimumScore = 0.6
    )
    $found = [System.Collections.Generic.List[string]]::new()
    $boxes = @($Box | Where-Object { $null -ne $_ })
    if ($boxes.Count -eq 0) { return [string[]]$found.ToArray() }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $boxes) {
        $text = [string]$entry.text
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($seen.Add($text)) { $candidates.Add($text) }
    }
    $k = @($Label.Trim() -split '\s+' | Where-Object { $_ }).Count
    if ($k -ge 2) {
        for ($i = 0; $i -le $boxes.Count - $k; $i++) {
            $run = $true
            for ($j = 1; $j -lt $k; $j++) {
                $a = $boxes[$i + $j - 1]
                $b = $boxes[$i + $j]
                if ([int]$a.block -ne [int]$b.block -or [int]$a.par -ne [int]$b.par -or [int]$a.line -ne [int]$b.line -or
                    [int]$b.word -ne [int]$a.word + 1) {
                    $run = $false
                    break
                }
            }
            if (-not $run) { continue }
            $text = @($boxes[$i..($i + $k - 1)] | ForEach-Object { [string]$_.text }) -join ' '
            if ($seen.Add($text)) { $candidates.Add($text) }
        }
    }
    $scored = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $score = [math]::Round((Get-OCRSimilarityScore -Text $candidates[$i] -Pattern $Label), 2)
        if ($score -ge $MinimumScore) { $scored.Add([pscustomobject]@{ Text = $candidates[$i]; Score = $score; Index = $i }) }
    }
    $ordered = @($scored | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Index'; Ascending = $true } |
        Select-Object -First $Maximum)
    foreach ($entry in $ordered) {
        $text = [regex]::Replace($entry.Text, '\p{Cc}', '?')
        if ($text.Length -gt 40) { $text = $text.Substring(0, 40) + '...' }
        $found.Add(("'{0}' {1}%" -f $text, [int][math]::Round($entry.Score * 100)))
    }
    return [string[]]$found.ToArray()
}

Export-ModuleMember -Function Get-OCRNormalized, Test-OCRMatch, Get-OcrCombineMode, Test-CombinedOcrMatch, Get-OcrFreshWindowNearMiss, Get-OCRSimilarityScore, Get-OcrClosestOnScreen, New-OcrFallbackReuseState, Test-OCRSegmentMatch, Find-OcrWordBoxMatch, Get-OcrWordBoxLine, Get-OcrClosestWord
