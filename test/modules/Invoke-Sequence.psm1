<#PSScriptInfo
.VERSION 2026.05.29
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456770
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

$InformationPreference = 'Continue'
$ProgressPreference = 'Continue'

# Inherit logLevel from the parent process via $env:YURUNA_LOG_LEVEL.
# Child pwsh processes don't inherit PowerShell preference variables, so
# the env var is the only way to propagate. See docs/loglevels.md.
Import-Module (Join-Path $PSScriptRoot 'Test.LogLevel.psm1') -Global -Force
Use-LogLevelFromEnv

# ── Wire the host driver ─────────────────────────────────────────────────────
# Invoke-Sequence's body and Wait-ForText / Invoke-TapOn call
# contract functions (Get-VMScreenshot, Restart-VMConsole) that live in
# Yuruna.Host. When this module loads inside a child pwsh process spawned
# by Test.Start-GuestOS / Test.Start-GuestWorkload, the child has no other path
# to Yuruna.Host; calling Initialize-YurunaHost here guarantees the
# contract is resolvable from every sequence-engine call site. Idempotent
# in the parent runner where Yuruna.Host is already loaded -- Get-Module
# short-circuits the re-load if the module is already imported.
try {
    $repoRoot      = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $testHostMod   = Join-Path $repoRoot 'test/modules/Test.Host.psm1'
    if (Test-Path $testHostMod) {
        Import-Module $testHostMod -Global -DisableNameChecking
        if (Get-Command Initialize-YurunaHost -ErrorAction SilentlyContinue) {
            [void](Initialize-YurunaHost -RepoRoot $repoRoot)
        }
    }
} catch {
    Write-Warning "Invoke-Sequence: Initialize-YurunaHost failed at module load -- contract calls (Restart-VMConsole, Get-VMScreenshot) will fail. Detail: $($_.Exception.Message)"
}

# ── Load global defaults from test.config.yml ──────────────────────────────
# The config file lives one level up from this module (test/test.config.yml).
$script:DefaultCharDelayMs      = 20
$script:DefaultVncPort          = 5900
$script:DefaultKeystrokeMechanism = "GUI"
# Default poll interval for wait-style actions (waitForText, passwdPrompt,
# fetchAndExecute, ...). A step's own `pollSeconds` overrides this; when the
# step omits it, this global value (vmCommunication.pollSeconds) is used.
# Each waitForText iteration already pays a screenshot + OCR pass (200-1000 ms)
# before sleeping; the sleep dominates total iteration cost, so trimming it
# directly trims success-path lag.
$script:DefaultPollSeconds      = 3
# Default timeout for wait-style actions (waitForText, passwdPrompt,
# fetchAndExecute, sshExec, sshWaitReady, ...). A step's own `timeoutSeconds`
# overrides this; otherwise this global value (vmCommunication.timeoutSeconds)
# is used.
$script:DefaultTimeoutSeconds   = 180
# Ring-buffer depth for raw pre-OCR screen captures kept per VM (Wait-ForText).
# On guest success the buffer dir is deleted; on failure the whole sequence is
# preserved so the failure-screenshot link can point at the run-up to the bug.
$script:DefaultScreenHistorySize = 5
# Memoize Get-OCRNormalized for repeated patterns. The same pattern string
# is re-normalized on every poll in Test-OCRMatch (pattern + per-segment
# normalize in Strategy 3). Patterns are bounded (one per sequence step),
# so the cache stays small. Line / full-text inputs are NOT cached -- they
# vary per call and would balloon memory.
$script:OcrPatternCache = @{}

# Exponential-backoff helper for filesystem-state poll loops is
# centralised in Test.Backoff.psm1 (Get-PollDelay) so a tuning change
# lands once. Imported with -Global by Test.Prelude's module sets,
# so callers in this file resolve the function via the global scope.

# ── Progress wrapper ─────────────────────────────────────────────────────────
# Invoke-Sequence runs inline in the runner's interactive host now (the cycle
# planner dispatches Invoke-SequenceByName directly from Test.Start-GuestOS /
# Test.Start-GuestWorkload -- no child pwsh in the path), so Write-Progress works
# natively. This wrapper keeps the call sites uniform with the previous
# child-pwsh era when a stdout marker protocol was also needed.
function Write-ProgressTick {
    <#
    .SYNOPSIS
        Uniform Write-Progress wrapper for sequence-step heartbeats.
    .DESCRIPTION
        Forwards to Write-Progress with a -Completed shortcut. Kept as a
        thin wrapper so call sites stay uniform across hosts and across
        the inline / former-child-spawn runtimes.
    #>
    param(
        [Parameter(Mandatory)][string]$Activity,
        [string]$Status = '',
        [int]$PercentComplete = -1,
        [switch]$Completed
    )
    if ($Completed) {
        Write-Progress -Activity $Activity -Completed
    } else {
        Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
    }
}
Import-Module (Join-Path $PSScriptRoot 'Test.Config.psm1') -Global -Force
Import-Module (Join-Path $PSScriptRoot 'Test.HostIO.psm1') -Global -Force
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceAction.psm1') -Global -Force
# Test.Transport carries the per-host keystroke / mouse / VNC backends.
# -Global so the per-host Test.HostIO.<Host>.psm1 modules (loaded below)
# resolve Send-KeyHyperV / Send-KeyVNC / Send-KeyUTM / Send-KeyKvm /
# Send-TextHyperV / Send-TextVNC / Send-TextUTM / Send-TextKvm /
# Send-ClickHyperV / Send-ClickUtm by bare name. See docs/host-io.md.
Import-Module (Join-Path $PSScriptRoot 'Test.Transport.psm1') -Global -Force
# Per-host I/O wiring: each module's load-time Register-HostIOProvider
# calls populate the Test.HostIO registry that the Send-Key / Send-Text /
# Send-Click dispatchers below delegate to via Invoke-HostIOAction.
# Adding a new host adds a parallel Test.HostIO.<NewHost>.psm1 plus one
# Import-Module line here.
Import-Module (Join-Path $PSScriptRoot 'Test.HostIO.HyperV.psm1') -Global -Force
Import-Module (Join-Path $PSScriptRoot 'Test.HostIO.Utm.psm1')    -Global -Force
Import-Module (Join-Path $PSScriptRoot 'Test.HostIO.Kvm.psm1')    -Global -Force
# Built-in verb Handlers (Register-SequenceAction blocks) live in
# Test.SequenceHandler.psm1. retry and recoverFromSnapshot stay in this
# module because their Handler bodies coordinate $script:LastFailure*
# state with the engine's foreach loop; the rest of the verb catalog
# is local to Test.SequenceHandler so adding a verb does not collide
# with engine edits.
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceHandler.psm1') -Global -Force
$_configPath = Join-Path (Split-Path -Parent $PSScriptRoot) "test.config.yml"
$_cfg = Read-TestConfig -Path $_configPath
if ($_cfg) {
    # test.config.yml keys live under the `vmCommunication` node
    # (`characterDelayMs`, `vncPort`, `keystrokeMechanism`,
    # `pollSeconds`, `timeoutSeconds`); per-step YAML in sequences/
    # still uses `charDelayMs` / `pollSeconds` / `timeoutSeconds` to
    # override these defaults for an individual step (see actions.yml).
    $_comm = $_cfg.vmCommunication
    if ($_comm.characterDelayMs)   { $script:DefaultCharDelayMs        = [int]$_comm.characterDelayMs }
    if ($_comm.vncPort)            { $script:DefaultVncPort            = [int]$_comm.vncPort }
    if ($_comm.keystrokeMechanism) { $script:DefaultKeystrokeMechanism = [string]$_comm.keystrokeMechanism }
    if ($_comm.pollSeconds)        { $script:DefaultPollSeconds        = [int]$_comm.pollSeconds }
    if ($_comm.timeoutSeconds)     { $script:DefaultTimeoutSeconds     = [int]$_comm.timeoutSeconds }
    # 0 disables the ring buffer; we still accept it as a configured value.
    if ($null -ne $_cfg.screenHistorySize) { $script:DefaultScreenHistorySize = [int]$_cfg.screenHistorySize }
}
Remove-Variable -Name _configPath, _cfg, _comm -ErrorAction SilentlyContinue

# Shared engine for executing interaction sequences from YAML files.
# Action catalog, variable substitution, and on-failure artifact layout
# are documented in docs/test-sequences.md (the operator-facing spec) --
# do not duplicate them here. This module is the executable definition;
# the Markdown is the contract.

function Send-Key {
<#
.SYNOPSIS
    Host-aware dispatcher for sending a named key (e.g. Enter, Tab) to
    the guest VM's GUI keyboard input channel.
.DESCRIPTION
    Dispatches via the Test.HostIO registry. Per-host backends are
    registered at module-load time below (search for
    Register-HostIOProvider 'Send-Key'). Yuruna.Host's Send-Key contract
    routes here so each host driver doesn't import the platform-specific
    helpers itself.
#>
    param([string]$HostType, [string]$VMName, [string]$KeyName)
    try {
        return (Invoke-HostIOAction -HostType $HostType -Action 'Send-Key' -Arguments @{ VMName=$VMName; KeyName=$KeyName })
    } catch {
        Write-Warning "Send-Key: $($_.Exception.Message)"
        return $false
    }
}

# ── Action: type / typeAndEnter ──────────────────────────────────────────────


function Send-Text {
<#
.SYNOPSIS
    Host-aware dispatcher for typing a text string into the guest VM's
    GUI keyboard input channel, char by char with optional inter-key delay.
.DESCRIPTION
    Routes by HostType to the matching backend (Send-TextHyperV,
    Send-TextVNC/Send-TextUTM, Send-TextKvm). Called by the Yuruna.Host
    Send-Text contract so the host driver does not need to import the
    host-specific helpers itself.
#>
    param(
        [string]$HostType,
        [string]$VMName,
        [string]$Text,
        [int]$CharDelayMs = $script:DefaultCharDelayMs,
        # ShellEscape is only honored by Send-TextUTM (rewrites Text as
        # a bash decode wrapper for hosts that can't deliver synthetic
        # Shift reliably). Hyper-V's PS/2 controller and KVM's `virsh
        # send-key` paths deliver Shift correctly without needing the
        # wrapper, so this switch is a no-op there.
        [switch]$ShellEscape
    )
    try {
        return (Invoke-HostIOAction -HostType $HostType -Action 'Send-Text' -Arguments @{ VMName=$VMName; Text=$Text; CharDelayMs=$CharDelayMs; ShellEscape=[bool]$ShellEscape })
    } catch {
        Write-Warning "Send-Text: $($_.Exception.Message)"
        return $false
    }
}

# ── OCR-tolerant matching ────────────────────────────────────────────────────

# Common OCR confusion groups: characters within each group are frequently
# misrecognized as each other on console/monospace text.
# Sources: WinRT/Vision observed errors, UNLV OCR accuracy studies.
$script:OCRConfusionGroups = @(
    'wuv'       # w↔u↔v — most common on console fonts
    'mn'        # m↔n
    'oO0@'      # o↔O↔0↔@ — '@' frequently substituted for '0' on console fonts
                # (e.g. "test-ubuntu-server-01" reads as "test-ubuntu-server-@1")
    "lI1i[]$([char]0x0131)"  # l↔I↔1↔i↔[↔]↔ı — brackets misread as l/1/i, ı (dotless i) from Vision OCR
    'S5s'       # S↔5↔s
    'B8'        # B↔8
    'Z2z'       # Z↔2↔z
    'gq9'       # g↔q↔9
    'ce'        # c↔e — at small sizes
    ':;.'       # :↔;↔. — punctuation frequently mangled on terminal fonts
)

# Characters that are stripped entirely during normalization.
# OCR engines frequently insert em/en dashes, smart quotes, or other
# Unicode substitutions for ASCII punctuation on terminal screens.
# Stripping these (along with their ASCII equivalents) prevents
# mismatches when the pattern uses plain ASCII.
#
# '@' is NOT in this list — it now lives in the oO0@ confusion group
# (above) because OCR mistakes for '0' are more common in this codebase
# than '@' being dropped from a prompt. With '@' canonicalized to 'o',
# a pattern with literal '@' (e.g. "[ec2-user@host]$") still matches
# OCR text that reads '@' as '@' OR as '0' — both canonicalize the same.
$script:OCRStripChars = [System.Collections.Generic.HashSet[char]]::new(
    [char[]]@(
        '-', [char]0x2014, [char]0x2013, [char]0x2012,  # -, —, –, ‒
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
       substitutions not covered by confusion groups (e.g. R→K).
    2. Subsequence with span limit: handles dropped characters
       (e.g. "Password" OCR'd as "assuord").

    Also handles:
    - Character confusion (w↔u↔v, o↔O↔0↔@, l↔I↔1↔i↔[↔], etc.)
    - Punctuation confusion (:↔;↔.)
    - Dash normalization (-, —, –, ‒ all stripped)
    - Spurious spaces from courier/monospace OCR
#>
function Test-OCRMatch {
    param([string]$Text, [string]$Pattern)
    $normPattern = $script:OcrPatternCache[$Pattern]
    if ($null -eq $normPattern) {
        $normPattern = Get-OCRNormalized $Pattern
        $script:OcrPatternCache[$Pattern] = $normPattern
    }
    if ($normPattern.Length -eq 0) { return $true }
    # Require at least 85% of normalized pattern chars to appear in order.
    # This allows ~1 dropped char per 7 pattern chars (e.g. "Password:" → "assuord:")
    # while rejecting scattered coincidental matches in long log lines.
    # The :;. confusion group handles punctuation substitution (e.g. "rassword."
    # matches "Password:" via the sliding window at 8/9 = 89%).
    $threshold = [int][Math]::Ceiling($normPattern.Length * 0.85)
    $patternChars = $normPattern.ToCharArray()
    # Matched chars in the text must span at most 2× the pattern length to
    # prevent hits where common chars are scattered across a long line.
    $maxSpan = $normPattern.Length * 2
    # Loop-invariant: depends only on $patternChars, hoisted from the
    # per-line foreach so multi-line OCR text doesn't reallocate per line.
    $patternCharSet = [System.Collections.Generic.HashSet[char]]::new([char[]]$patternChars)

    foreach ($line in ($Text -split "`n")) {
        $normLine = Get-OCRNormalized $line
        if ($normLine.Length -eq 0) { continue }

        # --- Strategy 1: Positional (sliding window) comparison ---
        # Slide the pattern across the text and count character matches at each
        # aligned position.  This naturally handles arbitrary single-character
        # substitutions (e.g. R→K in "Retype"→"Ketype") that are not covered
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

        # --- Strategy 2: Subsequence match (handles dropped characters) ---
        # Try from each text position that contains any pattern character.
        # A single greedy pass can latch onto an early occurrence (e.g. the 'l'
        # in "Iinux") and stretch the span past the limit even though the real
        # match ("login:") starts later and is compact.  Starting from any
        # pattern char (not just the first) also handles the case where the
        # first pattern char was dropped by OCR (e.g. "Password" → "assuord").
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

    # --- Strategy 3: Segment match (handles OCR word reordering) ---
    # OCR may reorder parts of a line (e.g. "[ec2-user@test-amazon-linux01 ~]$"
    # becomes "test-amazon-I inux01 login: ecZ-user").  Split the original pattern
    # on characters that are stripped during normalization (@, -, etc.) to get
    # meaningful segments, normalize each, and check that every segment appears
    # somewhere in the full normalized text (across all lines).
    $normFull = Get-OCRNormalized $Text
    # Split on strip chars and spaces to get pattern segments
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

# ── Multi-engine OCR combine logic ──────────────────────────────────────────

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ COMBINE MODE: controls how per-engine detection booleans are merged.   │
# │                                                                        │
# │  'Or'  — pattern detected by ANY engine → match  (default, resilient)  │
# │  'And' — pattern detected by ALL engines → match  (strict, fewer FPs)  │
# │                                                                        │
# │ To switch: change the value below, or set $env:YURUNA_OCR_COMBINE.    │
# └─────────────────────────────────────────────────────────────────────────┘
function Get-OcrCombineMode {
    $envVal = $env:YURUNA_OCR_COMBINE
    if ($envVal -and $envVal -notin @('Or', 'And')) {
        throw "Invalid YURUNA_OCR_COMBINE value '$envVal'. Only 'Or' and 'And' are allowed."
    }
    if ($envVal -eq 'And') { return 'And' }
    return 'Or'   # ← default
}

function Test-CombinedOcrMatch {
    <#
    .SYNOPSIS
        Runs all enabled OCR engines on a screen capture, tests each engine's
        text against every pattern, and returns $true/$false based on the
        combine mode.

    .DESCRIPTION
        For each enabled OCR engine:
          1. Run OCR on ImagePath → engine text
          2. For each pattern, test engine text → boolean
        Collect a boolean per engine (true if ANY pattern matched that engine's text).

        Combine mode (Or/And) controls how the per-engine booleans are merged:
          Or  → $true if at least one engine detected any pattern
          And → $true only if every engine detected at least one pattern

    .PARAMETER ImagePath
        Path to the screen capture PNG. The image is sent to each OCR engine
        as-is — no preprocessing.

    .PARAMETER Pattern
        One or more patterns to match (any pattern matching counts for that engine).

    .PARAMETER FreshMatchTailLines
        When greater than 0, only the last N lines of each engine's OCR text are
        tested. Defaults to 0 (test all lines). Typically set to 12 for freshMatch.

    .OUTPUTS
        A hashtable with:
          .Match       — [bool] combined result
          .EngineResults — [ordered] engine-name → @{ Text; Matched; MatchedPattern }
          .AnyText     — [string] concatenation of all engine texts (for accumulation)
    #>
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
    # short-circuit by design — running both engines in parallel and
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

# ── Action: tapOn — OCR-located mouse click ─────────────────────────────────
#
# Button-focus navigation via Tab keystrokes is brittle: initial focus depends
# on splash animation state, async-loaded widgets, and installer redesigns,
# so the "correct" Tab count drifts. tapOn sidesteps focus
# entirely — it OCRs the VM screen, locates the button's bounding box, and
# synthesizes a mouse click at that box's centre.
#
# Coordinate contract: the captured image and the click target share the
# same pixel space. On Hyper-V we use PrintWindow on the vmconnect client
# area so image (x,y) == vmconnect client (x,y), and ClientToScreen maps
# it to a SetCursorPos + mouse_event sequence.


function Send-Click {
<#
.SYNOPSIS
    Host-aware dispatcher for sending a mouse click at the given pixel
    coordinate to the guest VM's GUI input channel.
.DESCRIPTION
    Routes by HostType to the matching backend (Send-ClickHyperV,
    Send-ClickUtm). The Capture hashtable carries the UTM window
    origin and scale produced by Get-UtmWindowScreenshot; Hyper-V
    ignores it and resolves the window via ClientToScreen at click
    time. Called by the Yuruna.Host Send-Click contract.
#>
    param(
        [string]$HostType,
        [string]$VMName,
        [int]$X,
        [int]$Y,
        # UTM branch reads OriginX / OriginY / Scale from this hashtable
        # (produced by Get-UtmWindowScreenshot). Hyper-V ignores it and
        # resolves the window via ClientToScreen at click time.
        [hashtable]$Capture = $null
    )
    try {
        return (Invoke-HostIOAction -HostType $HostType -Action 'Send-Click' -Arguments @{ VMName=$VMName; X=$X; Y=$Y; Capture=$Capture })
    } catch {
        Write-Warning "Send-Click: $($_.Exception.Message)"
        return $false
    }
}

function Find-TextLocation {
    param(
        [Parameter(Mandatory)] [string]$ImagePath,
        [Parameter(Mandatory)] [string]$Label
    )
    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    Import-Module (Join-Path $modulesDir "Test.Tesseract.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false

    try {
        $boxes = Get-TesseractWordBox -ImagePath $ImagePath
    } catch {
        Write-Warning "Tesseract TSV OCR failed: $_"
        return $null
    }
    if (-not $boxes -or $boxes.Count -eq 0) { return $null }

    $tokens = @(($Label.Trim() -split '\s+') | Where-Object { $_ })
    if ($tokens.Count -eq 0) { return $null }

    for ($i = 0; $i -le ($boxes.Count - $tokens.Count); $i++) {
        $match = $true
        for ($j = 0; $j -lt $tokens.Count; $j++) {
            # -like is case-insensitive in PowerShell; substring match
            # tolerates partial OCR ("Install." vs "Install").
            if ($boxes[$i + $j].text -notlike "*$($tokens[$j])*") {
                $match = $false
                break
            }
        }
        if (-not $match) { continue }

        # Multi-word label: require words on roughly the same line so we
        # don't stitch together a token from a header and another from a
        # footer that happens to share vocabulary.
        if ($tokens.Count -gt 1) {
            $firstY = $boxes[$i].y
            $firstH = [math]::Max(1, $boxes[$i].h)
            $sameLine = $true
            for ($j = 1; $j -lt $tokens.Count; $j++) {
                $yDiff = [math]::Abs($boxes[$i + $j].y - $firstY)
                if ($yDiff -gt ($firstH / 2)) { $sameLine = $false; break }
            }
            if (-not $sameLine) { continue }
        }

        $minX = [int]::MaxValue; $minY = [int]::MaxValue
        $maxX = 0; $maxY = 0
        for ($j = 0; $j -lt $tokens.Count; $j++) {
            $b = $boxes[$i + $j]
            if ($b.x -lt $minX) { $minX = $b.x }
            if ($b.y -lt $minY) { $minY = $b.y }
            if (($b.x + $b.w) -gt $maxX) { $maxX = $b.x + $b.w }
            if (($b.y + $b.h) -gt $maxY) { $maxY = $b.y + $b.h }
        }
        return @{
            x       = $minX
            y       = $minY
            w       = $maxX - $minX
            h       = $maxY - $minY
            centerX = [int](($minX + $maxX) / 2)
            centerY = [int](($minY + $maxY) / 2)
            text    = ($tokens -join ' ')
        }
    }
    return $null
}

<#
.SYNOPSIS
    Copies a screenshot to $DestPath with a red X drawn at ($X, $Y).
.DESCRIPTION
    The X marks the pixel the click was dispatched to, so the operator
    can eyeball whether OCR coordinates landed on the intended button.
    A white halo stroke underneath keeps the marker readable on both
    dark and light installer backgrounds.
#>
function Save-ScreenshotWithClickMarker {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestPath,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [int]$Size = 20
    )
    # System.Drawing.Common is Windows-only in .NET 6+; on macOS/Linux the
    # GDI+ type initializer throws. Skip the marker draw and preserve the
    # diagnostic by logging the click coordinates alongside the plain copy.
    # ($IsWindows is $null on Windows PowerShell 5.1, which leaves GDI+ enabled.)
    if ($IsWindows -eq $false) {
        Copy-Item -Path $SourcePath -Destination $DestPath -Force -ErrorAction SilentlyContinue
        Write-Debug "      Save-ScreenshotWithClickMarker: GDI+ unavailable on $($PSVersionTable.Platform); copied to $DestPath (click would be at X=$X Y=$Y)"
        return $false
    }
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        # GDI+ locks the source file for the lifetime of the bitmap, so we
        # clone into an independent in-memory bitmap and release the source
        # before saving — otherwise SourcePath stays locked until GC runs.
        $src  = [System.Drawing.Bitmap]::FromFile($SourcePath)
        $copy = New-Object System.Drawing.Bitmap $src
        $src.Dispose()

        $g      = [System.Drawing.Graphics]::FromImage($copy)
        $halo   = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 5)
        $marker = New-Object System.Drawing.Pen([System.Drawing.Color]::Red,   3)
        $g.DrawLine($halo,   $X - $Size, $Y - $Size, $X + $Size, $Y + $Size)
        $g.DrawLine($halo,   $X - $Size, $Y + $Size, $X + $Size, $Y - $Size)
        $g.DrawLine($marker, $X - $Size, $Y - $Size, $X + $Size, $Y + $Size)
        $g.DrawLine($marker, $X - $Size, $Y + $Size, $X + $Size, $Y - $Size)
        $g.Dispose(); $halo.Dispose(); $marker.Dispose()

        $copy.Save($DestPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $copy.Dispose()
        return $true
    } catch {
        Write-Warning "Save-ScreenshotWithClickMarker failed: $_"
        # Fall back to plain copy so the operator still has a screenshot.
        Copy-Item -Path $SourcePath -Destination $DestPath -Force -ErrorAction SilentlyContinue
        return $false
    }
}

<#
.SYNOPSIS
    Waits for a labeled button to appear on the VM screen and clicks it.
.DESCRIPTION
    Loops: capture the VM window at the host's coordinate space, OCR for
    the label, and if found, click at the label's centre. Falls back to
    returning $false after TimeoutSeconds if the button never resolves
    (caller can then decide to send Tab+Enter as a legacy fallback).
.OUTPUTS
    $true on click dispatched, $false on timeout / unsupported host.
#>
function Invoke-TapOn {
    param(
        [string]$HostType,
        [string]$VMName,
        [string[]]$Label,
        [int]$TimeoutSeconds = 120,
        [int]$PollSeconds = 3,
        [int]$OffsetX = 0,
        [int]$OffsetY = 0
    )
    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    # -Global: a nested -Force without -Global evicts Test.YurunaDir from
    # the parent script's session state, breaking later top-level calls.
    Import-Module (Join-Path $modulesDir "Test.YurunaDir.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false

    $logDir = Initialize-YurunaLogDir
    $capturePath = Join-Path $logDir "clickbutton_${VMName}.png"
    # Avoid '|' as the join separator — Write-ProgressTick's marker uses '|'
    # as its field delimiter, and embedding one here would shift parsing on the
    # parent side. Write-ProgressTick sanitizes defensively, but keep the
    # display clean at the source too.
    $labelDisplay = $Label -join "' / '"
    # Wall-clock deadline. See the matching commentary in Wait-ForText for
    # why this is NOT an iteration counter -- on a slow Hyper-V host a
    # configured timeoutSeconds: 60 used to expand to 3-5 minutes of
    # wall-clock when each iteration paid full screenshot + OCR cost on
    # top of the $PollSeconds sleep.
    $startUtc    = [DateTime]::UtcNow
    $deadlineUtc = $startUtc.AddSeconds($TimeoutSeconds)
    $elapsed     = 0

    try {
        while ([DateTime]::UtcNow -lt $deadlineUtc) {
            $elapsed = [int]([DateTime]::UtcNow - $startUtc).TotalSeconds
            $pct = [math]::Min(100, [math]::Round(($elapsed / [math]::Max($TimeoutSeconds,1)) * 100))
            Write-ProgressTick -Activity "tapOn" -Status "'$labelDisplay' (${elapsed}s / ${TimeoutSeconds}s)" -PercentComplete $pct

            Remove-Item $capturePath -Force -ErrorAction SilentlyContinue
            $capture = Get-VMScreenshot -VMName $VMName -Source window -OutFile $capturePath
            if (-not $capture) {
                Write-Debug "      Window capture unavailable — retrying"
                Start-Sleep -Seconds $PollSeconds
                continue
            }

            foreach ($candidate in $Label) {
                $coord = Find-TextLocation -ImagePath $capture.ImagePath -Label $candidate
                if ($coord) {
                    $clickX = $coord.centerX + $OffsetX
                    $clickY = $coord.centerY + $OffsetY
                    Write-Debug "      Found '$candidate' at ($($coord.x),$($coord.y)) $($coord.w)x$($coord.h) → click ($clickX, $clickY)"
                    # logLevel=Debug: preserve a per-detection screenshot under
                    # a UTC timestamp so the operator can correlate a stuck
                    # installer with exactly what OCR saw and where we aimed
                    # the click.
                    if ($env:YURUNA_LOG_LEVEL -eq 'Debug') {
                        $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
                        $stampedPath = Join-Path $logDir "tapOn.$stamp.png"
                        Save-ScreenshotWithClickMarker -SourcePath $capture.ImagePath -DestPath $stampedPath -X $clickX -Y $clickY | Out-Null
                        Write-Debug "      logLevel=Debug: saved detection screenshot $stampedPath"
                        Write-Debug "      logLevel=Debug: button '$candidate' box=($($coord.x),$($coord.y)) size=$($coord.w)x$($coord.h) click=($clickX, $clickY) offset=($OffsetX, $OffsetY) image=$($capture.Width)x$($capture.Height)"
                    }
                    $ok = Send-Click -HostType $HostType -VMName $VMName -X $clickX -Y $clickY -Capture $capture
                    # Preserve a diagnostic capture so a failed click can be inspected;
                    # the X marker shows where the click actually landed in image space.
                    $debugCopy = Join-Path $logDir "clickbutton_${VMName}_last.png"
                    Save-ScreenshotWithClickMarker -SourcePath $capture.ImagePath -DestPath $debugCopy -X $clickX -Y $clickY | Out-Null
                    return $ok
                }
            }

            Start-Sleep -Seconds $PollSeconds
        }

        # Timeout — preserve the final screenshot so the operator can see
        # what the OCR was looking at.
        $failScreenPath = Join-Path $logDir "failure_clickbutton_${VMName}.png"
        if (Test-Path $capturePath) {
            Copy-Item -Path $capturePath -Destination $failScreenPath -Force -ErrorAction SilentlyContinue
            Write-Information "      Failure screenshot saved: $failScreenPath"
        }
        Write-Warning "Button with label '$labelDisplay' not located within ${TimeoutSeconds}s"
        return $false
    } finally {
        Remove-Item $capturePath -Force -ErrorAction SilentlyContinue
        Write-ProgressTick -Activity "tapOn" -Completed
    }
}

# Persist this frame's OCR output as raw_${stamp}.txt next to the
# raw_${stamp}.png it was extracted from. The text file is what the
# matcher actually saw — invaluable for diagnosing "should have matched"
# regressions, since the ring-buffer .png alone leaves the reader to
# re-OCR the image to figure out why the pattern didn't fire.
#
# AllowEmptyCollection: a [Parameter(Mandatory)] typed-collection param
# rejects empty input with the misleading "Cannot bind argument ...
# because it is an empty string" error. The empty case happens when
# Test-CombinedOcrMatch returns no EngineResults (no providers ran on
# this frame); skipping the write is correct — an empty sidecar would
# misrepresent "no engine ran" as "engines ran and saw nothing."
#
# AllowEmptyString: PowerShell's Mandatory binder enumerates a typed
# List[string] and validates each element against the implicit non-
# empty-string check, so a list containing the trailing '' separators
# the callers add between engine sections fails with the same
# "empty string" message. AllowEmptyString lifts that per-element
# check; AllowEmptyCollection lifts the whole-list one.
function Save-OcrSidecar {
    param(
        [Parameter(Mandatory)] [string]$ScreenshotPath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()]
        [System.Collections.Generic.List[string]]$Sections
    )
    if ($Sections.Count -eq 0) { return }
    $ocrPath = [System.IO.Path]::ChangeExtension($ScreenshotPath, '.txt')
    Set-Content -Path $ocrPath -Value ($Sections -join "`n") -Encoding UTF8 -ErrorAction SilentlyContinue
}

# ── Action: waitForText ──────────────────────────────────────────────────────

function Wait-ForText {
    <#
    .SYNOPSIS
        Poll the guest framebuffer via OCR until $Pattern matches or
        $TimeoutSeconds elapses.
    .DESCRIPTION
        Drives the waitForText sequence action: takes a screenshot,
        OCRs it, fuzzy-matches against $Pattern, and either returns
        $true on a match or sleeps $PollSeconds before retrying. Also
        evaluates $FailurePattern entries each poll so a known crash
        screen aborts the wait immediately instead of consuming the
        full timeout budget.
    .OUTPUTS
        [bool] $true on positive match; $false on timeout or anti-pattern hit.
    #>
    param(
        # HostType is accepted but ignored at the dispatch level: the
        # host driver's own Get-VMScreenshot resolves the per-host
        # backend internally. We accept it for caller-site uniformity
        # and surface it in the debug stream for cross-host triage.
        [string]$HostType,
        [string]$VMName,
        [string[]]$Pattern,
        [int]$TimeoutSeconds = 120,
        [int]$PollSeconds = 3,
        [bool]$FreshMatch = $false,
        [int]$FreshMatchTailLines = 12,
        # Anti-patterns: if ANY of these fuzzy-matches on screen OCR,
        # abort the wait immediately and return $false. Canonical use
        # case is subiquity's "install_fail.crash" / "An error occurred.
        # Press enter to start a shell" output -- at that point the
        # positive pattern (e.g. "Not listed?" from the GDM login screen)
        # is never going to appear, so polling until $TimeoutSeconds
        # wastes up to an hour before the runner gets a misleading
        # "pattern not found" failure. On match this function also sets
        # the module-scoped $script:WaitForTextMatchedFailurePattern so
        # the caller's failure-label builder can surface *which* anti-
        # pattern fired, producing a banner like
        #   waitForAndEnter: "Not listed?" -- matched failurePattern "install_fail.crash"
        # instead of the opaque timeout message.
        [string[]]$FailurePattern = @()
    )
    # Reset the cross-function signal so a prior call's match can't leak
    # into the next Wait-ForText invocation.
    $script:WaitForTextMatchedFailurePattern = $null
    if ($HostType) { Write-Debug "Wait-ForText: -HostType '$HostType' is informational; Yuruna.Host dispatches Get-VMScreenshot internally." }

    # Display label uses first pattern for log messages
    $patternLabel = $Pattern[0]
    # Wall-clock deadline -- NOT an iteration counter. Earlier revisions
    # tracked $elapsed by adding $PollSeconds each loop pass, which assumed
    # every iteration finished in $PollSeconds wall-clock. In practice each
    # iteration does a screenshot + tesseract OCR + sidecar write before
    # the Start-Sleep -Seconds $PollSeconds at the bottom -- on a busy
    # Hyper-V host that adds 5-25 s on top of the sleep, so a configured
    # timeoutSeconds: 1800 took 1-3 hours of wall-clock to expire (and
    # multiplied by retry maxAttempts could exceed half a day before
    # giving up). With a wall-clock deadline timeoutSeconds means exactly
    # what the operator configured.
    $startUtc    = [DateTime]::UtcNow
    $deadlineUtc = $startUtc.AddSeconds($TimeoutSeconds)
    $elapsed     = 0

    # Import required modules. Screenshot capture is via the Yuruna.Host
    # contract (Get-VMScreenshot) -- assumed already loaded by the caller's
    # Initialize-YurunaHost. OcrEngine stays in test/modules/ as a
    # cross-host helper.
    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    Import-Module (Join-Path $modulesDir "Test.OcrEngine.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false

    # Log which OCR engines are active for this wait
    $enabledEngines = Get-EnabledOcrProvider
    $combineMode = Get-OcrCombineMode
    Write-Debug "      OCR engines: $($enabledEngines -join ', ') | combine: $combineMode"

    # Per-VM ring buffer of raw pre-OCR captures. Persists across multiple
    # Wait-ForText calls within a guest run so the failure path can surface
    # the run-up to the bug. Cleared at end-of-guest on success by the
    # runner; preserved on failure and copied alongside the failure log.
    # -Global on the -Force re-imports: a nested -Force without -Global
    # evicts the modules from the parent script's session state, so a
    # later top-level call to Get-CycleScreenDir (Invoke-TestInnerRunner.ps1
    # success branch, the cycle 62 crash on macOS in-process runners)
    # fails with "term not recognized".
    Import-Module (Join-Path $modulesDir "Test.YurunaDir.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    Import-Module (Join-Path $modulesDir "Test.Log.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    $logDir     = Initialize-YurunaLogDir
    # Ring buffer lives INSIDE the cycle folder so a stuck/restarted
    # runner can't overwrite it -- the next cycle gets its own folder.
    # Falls back to $logDir/screens_<VM>/ when no cycle folder is set.
    $screensDir = Get-CycleScreenDir -VMName $VMName -WhatIf:$false
    $historySize = [int]$script:DefaultScreenHistorySize
    if ($historySize -lt 1) { $historySize = 1 }

    # Accumulate all seen text for non-FreshMatch mode (per-engine text merged).
    # StringBuilder rather than string += "`n" + text: a long poll loop (60-300 s
    # at PollSeconds=3 = 20-100 iters) would otherwise allocate a fresh string
    # each iteration, O(n^2) on the accumulated length.
    $allTextSb = [System.Text.StringBuilder]::new()
    $lastOcrText = ''
    $lastCapturePath = $null

    # Seed the ring-buffer queue once with anything already on disk from
    # earlier Wait-ForText calls in this guest run (the screensDir persists
    # across calls; see the ring-buffer note above). Subsequent iterations
    # append + dequeue in O(1) instead of re-enumerating the directory.
    $rawQueue = [System.Collections.Generic.Queue[string]]::new()
    Get-ChildItem -Path $screensDir -Filter 'raw_*.png' -File -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object { $rawQueue.Enqueue($_.FullName) }

    try {
        while ([DateTime]::UtcNow -lt $deadlineUtc) {
            $elapsed = [int]([DateTime]::UtcNow - $startUtc).TotalSeconds
            # PROGRESS-INLINE-TICK: reference impl lives in "waitForSeconds"
            $pct = [math]::Min(100, [math]::Round(($elapsed / [math]::Max($TimeoutSeconds,1)) * 100))
            Write-ProgressTick -Activity "waitForText" -Status "'$patternLabel' (${elapsed}s / ${TimeoutSeconds}s)" -PercentComplete $pct

            # Capture into the ring buffer with a millisecond-precise UTC name
            # so multiple Wait-ForText calls within the same guest produce a
            # contiguous, sortable sequence. [DateTime]::UtcNow is a static
            # property read; Get-Date pays cmdlet-binding overhead on every
            # poll iteration.
            $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
            $rawScreenPath = Join-Path $screensDir "raw_${stamp}.png"
            $captured = Get-VMScreenshot -VMName $VMName -OutFile $rawScreenPath
            if (-not $captured -or -not (Test-Path $rawScreenPath)) {
                Write-Debug "      Waiting for text '$patternLabel'... (${elapsed}s / ${TimeoutSeconds}s)"
                Start-Sleep -Seconds $PollSeconds
                continue
            }
            $lastCapturePath = $rawScreenPath

            # Trim ring buffer to the most recent $historySize entries.
            # Each raw_*.png has a sibling raw_*.txt holding that frame's
            # OCR output (per-engine sections, written further below).
            # Delete the .txt whenever we evict its .png so the two stay
            # in lockstep -- otherwise orphan .txt files accumulate.
            $rawQueue.Enqueue($rawScreenPath)
            while ($rawQueue.Count -gt $historySize) {
                $evict = $rawQueue.Dequeue()
                $txtSibling = [System.IO.Path]::ChangeExtension($evict, '.txt')
                Remove-Item -Path $evict -Force -ErrorAction SilentlyContinue
                if (Test-Path $txtSibling) { Remove-Item -Path $txtSibling -Force -ErrorAction SilentlyContinue }
            }

            # OCR is fed the raw capture as-is — no preprocessing. Earlier
            # revisions ran a vertical-line / grayscale / invert / contrast-
            # stretch / 2x-scale pipeline (and before that, a diff-against-
            # the-previous-frame stage that suppressed unchanged pixels);
            # both stages were dropped so every operating system delivers
            # the intact screenshot straight to the OCR engines and edge
            # cases the pipeline corrupted (anti-aliased serifs collapsing,
            # fresh text being suppressed when the surrounding pixels also
            # changed) stop biting. Tesseract / WinRT OCR / macOS Vision
            # all handle native-resolution color screenshots fine.
            if ($rawScreenPath -and (Test-Path $rawScreenPath)) {
                if ($FreshMatch) {
                    # ── FreshMatch mode: only check the last N lines ──
                    $result = Test-CombinedOcrMatch -ImagePath $rawScreenPath -Pattern $Pattern -FreshMatchTailLines $FreshMatchTailLines

                    $ocrSections = [System.Collections.Generic.List[string]]::new()
                    foreach ($eName in $result.EngineResults.Keys) {
                        $er = $result.EngineResults[$eName]
                        $snippet = $er.Text.Length -le 120 ? $er.Text : ("..." + $er.Text.Substring($er.Text.Length - 120))
                        $status = $er.Matched ? "MATCH '$($er.MatchedPattern)'" : "no match"
                        Write-Verbose "      [$eName] $status | $snippet"
                        $ocrSections.Add("=== $eName ($status) ===")
                        $ocrSections.Add($er.Text)
                        $ocrSections.Add('')
                    }
                    Save-OcrSidecar -ScreenshotPath $rawScreenPath -Sections $ocrSections

                    if ($result.AnyText) { $lastOcrText = $result.AnyText }

                    if ($result.Match) {
                        Write-Debug "      Text detected at end of screen (combine=$combineMode)"
                        return $true
                    }
                } else {
                    # ── Non-FreshMatch mode: accumulate text, check for pattern ──
                    $result = Test-CombinedOcrMatch -ImagePath $rawScreenPath -Pattern $Pattern

                    $ocrSections = [System.Collections.Generic.List[string]]::new()
                    foreach ($eName in $result.EngineResults.Keys) {
                        $er = $result.EngineResults[$eName]
                        $snippet = $er.Text.Length -le 120 ? $er.Text : ("..." + $er.Text.Substring($er.Text.Length - 120))
                        $status = $er.Matched ? "MATCH '$($er.MatchedPattern)'" : "no match"
                        Write-Verbose "      [$eName] $status | $snippet"
                        $ocrSections.Add("=== $eName ($status) ===")
                        $ocrSections.Add($er.Text)
                        $ocrSections.Add('')
                    }
                    Save-OcrSidecar -ScreenshotPath $rawScreenPath -Sections $ocrSections

                    if ($result.AnyText) {
                        $lastOcrText = $result.AnyText
                        if ($allTextSb.Length -gt 0) { [void]$allTextSb.Append("`n") }
                        [void]$allTextSb.Append($result.AnyText)
                    }

                    if ($result.Match) {
                        Write-Debug "      Text detected (combine=$combineMode)"
                        return $true
                    }

                    # Fallback: test accumulated text across iterations.
                    # Handles patterns that span multiple poll cycles.
                    $allText = $allTextSb.ToString()
                    foreach ($p in $Pattern) {
                        if (Test-OCRMatch -Text $allText -Pattern $p) {
                            Write-Debug "      Text detected in accumulated text: '$p'"
                            return $true
                        }
                    }
                }
            }

            # Anti-pattern (early-fail) check. Runs AFTER the positive-match
            # check so a positive match wins ties when both appear in one
            # frame. Uses $lastOcrText (the freshest OCR output) so the
            # signature isn't masked by an OCR glitch on the current poll.
            if ($FailurePattern -and $FailurePattern.Count -gt 0 -and $lastOcrText) {
                foreach ($fp in $FailurePattern) {
                    if ([string]::IsNullOrWhiteSpace($fp)) { continue }
                    if (Test-OCRMatch -Text $lastOcrText -Pattern $fp) {
                        $script:WaitForTextMatchedFailurePattern = $fp
                        Write-Warning "      Failure pattern matched: '$fp' -- aborting wait early (elapsed ${elapsed}s / ${TimeoutSeconds}s)"
                        if ($lastCapturePath -and (Test-Path $lastCapturePath)) {
                            $failScreenPath = Join-Path $logDir "failure_screenshot_${VMName}.png"
                            Copy-Item -Path $lastCapturePath -Destination $failScreenPath -Force -ErrorAction SilentlyContinue
                            Write-Information "      Failure screenshot saved: $failScreenPath (sequence: $screensDir)"
                        }
                        if ($lastOcrText) {
                            $failOcrPath = Join-Path $logDir "failure_ocr_${VMName}.txt"
                            Set-Content -Path $failOcrPath -Value $lastOcrText -Force -ErrorAction SilentlyContinue
                            Write-Information "      Failure OCR text saved: $failOcrPath"
                        }
                        return $false
                    }
                }
            }

            Write-Debug "      Waiting for text '$patternLabel'... (${elapsed}s / ${TimeoutSeconds}s)"
            Start-Sleep -Seconds $PollSeconds
        }

        # Timeout — preserve last screenshot, full sequence, and OCR text
        if ($lastCapturePath -and (Test-Path $lastCapturePath)) {
            $failScreenPath = Join-Path $logDir "failure_screenshot_${VMName}.png"
            Copy-Item -Path $lastCapturePath -Destination $failScreenPath -Force -ErrorAction SilentlyContinue
            Write-Information "      Failure screenshot saved: $failScreenPath (sequence: $screensDir)"
        }
        if ($lastOcrText) {
            $failOcrPath = Join-Path $logDir "failure_ocr_${VMName}.txt"
            Set-Content -Path $failOcrPath -Value $lastOcrText -Force -ErrorAction SilentlyContinue
            Write-Information "      Failure OCR text saved: $failOcrPath"
        }

        Write-Warning "Text '$patternLabel' not found within ${TimeoutSeconds}s"
        return $false
    } finally {
        # Note: $screensDir is intentionally NOT cleared here — it survives
        # across all Wait-ForText calls in a guest, and the runner deletes
        # it at end-of-guest on success (or surfaces it on failure).
        Write-ProgressTick -Activity "waitForText" -Completed
    }
}

# ── Action: takeScreenshot ───────────────────────────────────────────────────

function Save-DebugScreenshot {
    <#
    .SYNOPSIS
        Capture a labeled screenshot for the takeScreenshot sequence action.
    .DESCRIPTION
        Builds an HH-mm-ss filename under $OutputDir and asks the host
        driver's Get-VMScreenshot to write it. Returns $true on success
        so the calling step records a passing result.
    .OUTPUTS
        [bool] $true on capture; $false on host-driver failure.
    #>
    param([string]$VMName, [string]$Label, [string]$OutputDir)
    $fileName = "$VMName-$Label-$(Get-Date -Format 'HHmmss').png"
    $outputPath = Join-Path $OutputDir $fileName
    $dir = Split-Path -Parent $outputPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $result = Get-VMScreenshot -VMName $VMName -OutFile $outputPath
    if ($result) { Write-Debug "      Screenshot: $outputPath"; return $true }
    return $false
}

# ── Variable substitution ────────────────────────────────────────────────────

# Private-use Unicode codepoint used as the placeholder for `$` after the
# $$ → sentinel pre-pass and before the sentinel → $ post-pass. The
# Unicode private-use area (U+E000–U+F8FF) is reserved for application-
# specific use and effectively never appears in legitimate input, so it
# is safe to round-trip through the regex pass without colliding with
# something a user actually typed.
$script:DollarSentinel = [char]0xE000

# ${ext:area.Method(arg1, arg2, ...)} -- inline expression form. ArgList
# may include nested ${var} placeholders, which are expanded BEFORE the
# extension is invoked. Each call is dispatched fresh -- there is no
# caching, so ${ext:authentication.NewRandomPassword()} returns a new
# value every time it is evaluated. Side-effecting calls
# (e.g. Set-Password) still belong in the dedicated `callExtension`
# action; ${ext:...} is for value-producing reads. Parameter is named
# ArgList (not Args) because $Args is a PowerShell automatic variable.
function Invoke-ExtensionExpression {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Method,
        [string[]]$ArgList = @()
    )
    $loaderPath = Join-Path $PSScriptRoot 'Test.Extension.psm1'
    if (Test-Path $loaderPath) {
        Import-Module $loaderPath -Global -Force -Verbose:$false
    }
    $names = @(Get-ActiveExtensionName -Area $Area)
    $extName = $names[0]
    [void](Import-Extension -Area $Area)
    $cmd = Resolve-ExtensionMethod -Area $Area -ExtensionName $extName -Method $Method
    if ($ArgList.Count -eq 0) { return (& $cmd) }
    return (& $cmd @ArgList)
}

# Resolves `${ext:area.Method(arg1, arg2)}` occurrences in $Text. Nested
# `${var}` inside args are expanded first, then the call is invoked
# fresh on every match. Plain `${var}` substitution remains the
# responsibility of the surrounding regex pass.
function Expand-ExtensionExpression {
    param([string]$Text, [hashtable]$Variables)
    if (-not $Text -or -not $Text.Contains('${ext:')) { return $Text }
    # Pre-materialize the variable map keys for the MatchEvaluator closure
    # below -- the analyzer cannot see references through [regex]::Replace's
    # scriptblock, so binding $vars here keeps the parameter explicitly used.
    $vars = $Variables
    $sentinel = $script:DollarSentinel
    $pattern = '\$\{ext:([A-Za-z0-9_]+)\.([A-Za-z][A-Za-z0-9_-]*)\(([^)]*)\)\}'
    return [regex]::Replace($Text, $pattern, {
        param($m)
        $area    = $m.Groups[1].Value
        $method  = $m.Groups[2].Value
        $rawArgs = $m.Groups[3].Value
        $argList = @()
        if ($rawArgs.Trim() -ne '') {
            foreach ($raw in ($rawArgs -split ',')) {
                $a = $raw.Trim()
                # Expand inner ${var} so e.g. ${ext:authentication.GetPassword(${username})}
                # resolves to GetPassword('yauser1') before the call.
                foreach ($key in $vars.Keys) {
                    $a = $a -replace [regex]::Escape("`${$key}"), $vars[$key]
                }
                # Restore any $$ escapes the caller had in the arg text
                # so the extension sees the user's intended literal `$`,
                # not the internal sentinel.
                $argList += $a.Replace($sentinel, '$')
            }
        }
        return [string](Invoke-ExtensionExpression -Area $area -Method $method -ArgList $argList)
    })
}

function Expand-Variable {
    param([string]$Text, [hashtable]$Variables)
    if ($null -eq $Text) { return $Text }
    # Escape pass: $$ → sentinel hides escaped dollars from both the
    # ${ext:...} regex and the ${var} text replacement below. The
    # closing sentinel → $ pass at the end restores them. So $${foo}
    # survives as literal "${foo}", and $$$${foo} survives as "$${foo}".
    $result = $Text.Replace('$$', $script:DollarSentinel)
    # ${ext:...} expressions are resolved first so any ${var} placeholders
    # inside their args see the current Variables table.
    $result = Expand-ExtensionExpression -Text $result -Variables $Variables
    # [string]::Replace is literal substitution -- no regex compile, no
    # [regex]::Escape needed for $key, no $1-backreference surprise from
    # -replace if a Variables value contained dollar-digit text.
    foreach ($key in $Variables.Keys) {
        $result = $result.Replace("`${$key}", [string]$Variables[$key])
    }
    # Restore $$ escapes.
    return $result.Replace($script:DollarSentinel, '$')
}

# ── Main executor ────────────────────────────────────────────────────────────

<#
.SYNOPSIS
    Parses a YAML sequence file into an OrderedDictionary.
.DESCRIPTION
    Centralises the powershell-yaml dependency for every sequence reader
    (Invoke-Sequence, Test.SequencePlanner, Test-Sequence). Uses
    -Ordered so the steps array and the variables map preserve their
    on-disk order. The returned object is an [OrderedDictionary]; callers
    must use .Keys / .Contains() rather than .PSObject.Properties, since
    the YAML parser does not produce PSCustomObject.
#>
function Read-SequenceFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        # Bypass the mtime-keyed cache for diagnostic / probe call
        # sites that need a guaranteed fresh read.
        [switch]$NoCache
    )
    if (-not (Get-Module powershell-yaml)) {
        if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
            throw "powershell-yaml is required to read sequence files. Install with: Install-Module -Name powershell-yaml -Scope CurrentUser"
        }
        Import-Module powershell-yaml -Global -Verbose:$false -ErrorAction Stop
    }
    # Mtime-keyed parse cache, parallel to Test.Config's pattern.
    # The planner walks every sequence in the chain once per Resolve-
    # CyclePlan call; without a cache that's 50+ YAML parses per cycle
    # (~300-500 ms). Cache key is absolute path + LastWriteTimeUtc.
    if (-not $script:SequenceFileCache) { $script:SequenceFileCache = @{} }
    if (-not $NoCache -and (Test-Path -LiteralPath $Path)) {
        $resolved = (Resolve-Path -LiteralPath $Path).Path
        $mtime    = (Get-Item -LiteralPath $resolved).LastWriteTimeUtc
        if ($script:SequenceFileCache.ContainsKey($resolved)) {
            $entry = $script:SequenceFileCache[$resolved]
            if ($entry.Mtime -eq $mtime) { return $entry.Parsed }
        }
    }
    try {
        $parsed = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Yaml -Ordered
        if (-not $NoCache -and (Test-Path -LiteralPath $Path)) {
            $resolved = (Resolve-Path -LiteralPath $Path).Path
            $mtime    = (Get-Item -LiteralPath $resolved).LastWriteTimeUtc
            $script:SequenceFileCache[$resolved] = @{ Mtime = $mtime; Parsed = $parsed }
        }
        return $parsed
    } catch {
        # YamlDotNet's SyntaxErrorException carries Start/End marks with
        # Line/Column, but powershell-yaml wraps it in a generic
        # MethodInvocationException whose message just says "Exception
        # calling 'Load' with '1' argument(s): <inner>". Walk the
        # InnerException chain to find the SyntaxErrorException, pull the
        # marks, and re-throw with file path + line:col so the operator
        # doesn't have to bisect the sequence tree by hand.
        $err = $_.Exception
        $synErr = $null
        $probe = $err
        while ($probe) {
            if ($probe.GetType().FullName -eq 'YamlDotNet.Core.SyntaxErrorException') {
                $synErr = $probe; break
            }
            $probe = $probe.InnerException
        }
        if ($synErr) {
            $line = $synErr.Start.Line
            $col  = $synErr.Start.Column
            throw "YAML parse error in $Path at line ${line}:${col}: $($synErr.Message)"
        }
        throw "YAML parse error in $Path`: $($err.Message)"
    }
}

<#
.SYNOPSIS
    Returns the active sequence mode (gui or ssh) from test.config.yml.
.DESCRIPTION
    Maps test.config.yml keystrokeMechanism to the sequence subfolder:
    "SSH" -> "ssh", anything else -> "gui". Callers use this to build
    mode-specific paths like <sequencesDir>/<mode>/<name>.yml.
#>
function Get-SequenceMode {
    if ($script:DefaultKeystrokeMechanism -eq "SSH") { return "ssh" }
    return "gui"
}

<#
.SYNOPSIS
    Given a sequence path in one mode's subfolder, return the path in another mode's subfolder.
.DESCRIPTION
    Swaps the mode subfolder (gui <-> ssh) while keeping the sequence filename
    and the parent sequences directory. Returns $null if the input path is not
    under a recognised mode subfolder. Callers are responsible for Test-Path-ing
    the result before using it.
#>
function Get-SequenceModePath {
    param(
        [Parameter(Mandatory)][string]$SequencePath,
        [Parameter(Mandatory)][ValidateSet('gui', 'ssh')][string]$Mode
    )
    $leaf      = Split-Path -Leaf   $SequencePath
    $parent    = Split-Path -Parent $SequencePath
    $grandparent = Split-Path -Parent $parent
    if (-not $grandparent) { return $null }
    return (Join-Path (Join-Path $grandparent $Mode) $leaf)
}

<#
.SYNOPSIS
    Returns the ordered list of project test/<mode>/ directories beneath
    the cloned project root, e.g. project/example/website/test/gui/.
.DESCRIPTION
    The cycle clones test.config.yml's repositories.projectUrl into <RepoRoot>/project/. Each
    project under that tree may ship its own test sequences in
    <project>/test/<mode>/. We walk project/ once and collect every
    directory whose name matches the requested mode and whose immediate
    parent is named "test". This keeps depth flexible — projects sit at
    project/<category>/<name>/test/<mode>/ (e.g. example/website) or at
    project/<name>/test/<mode>/ (e.g. template) — without callers having
    to know the layout.

    project/test/ (cycle config holder) deliberately has no gui/ssh
    subdirs, so it is naturally excluded.
#>
function Get-ProjectTestSearchDir {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidateSet('gui', 'ssh')][string]$Mode
    )
    $projectRoot = Join-Path $RepoRoot 'project'
    if (-not (Test-Path $projectRoot)) { return @() }
    return @(
        Get-ChildItem -Path $projectRoot -Directory -Recurse -Filter $Mode -ErrorAction SilentlyContinue |
            Where-Object { (Split-Path -Leaf (Split-Path -Parent $_.FullName)) -eq 'test' } |
            ForEach-Object { $_.FullName }
    )
}

<#
.SYNOPSIS
    Returns the single project-tree match for $FileName under test/$Mode/ folders.
.DESCRIPTION
    Scans every project test/<Mode>/ folder returned by Get-ProjectTestSearchDir
    for a file with the exact $FileName. Returns the full path when exactly one
    hit is found; $null when none. When two or more hits are found, throws a
    PlannerFatal exception so the cycle aborts before any guest runs --
    duplicates indicate an ambiguous plan (two examples both shipping the same
    sequence name) and the operator must decide which one wins.
.PARAMETER RepoRoot
    Framework repo root. The project clone lives at <RepoRoot>/project/.
.PARAMETER Mode
    Keystroke mechanism ('gui' or 'ssh') -- selects the test/<mode>/ subfolder.
.PARAMETER FileName
    Sequence basename WITH extension, e.g. "workload.guest.ubuntu.server.24.yml".
    Host-specific variants get passed in with the suffix already applied.
#>
function Find-ProjectSequenceFile {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidateSet('gui', 'ssh')][string]$Mode,
        [Parameter(Mandatory)][string]$FileName
    )
    $hits = @(
        foreach ($d in (Get-ProjectTestSearchDir -RepoRoot $RepoRoot -Mode $Mode)) {
            $candidate = Join-Path $d $FileName
            if (Test-Path $candidate) { $candidate }
        }
    )
    if ($hits.Count -gt 1) {
        $list = ($hits | ForEach-Object { "    $_" }) -join "`n"
        throw "PlannerFatal: $($hits.Count) project sequence files named '$FileName' found under test/$Mode/ folders:`n$list`nKeep only one so the planner can resolve a single sequence file."
    }
    if ($hits.Count -eq 1) { return $hits[0] }
    return $null
}

<#
.SYNOPSIS
    Resolves a sequence name to the path under the active mode subfolder, with gui fallback.
.DESCRIPTION
    Search order:
      1. Project tree:   project/<...>/test/<mode>/<Name>.[<host-short>.]yml
      2. Framework:      <SequencesDir>/<mode>/<Name>.[<host-short>.]yml
      3. Framework gui:  <SequencesDir>/gui/<Name>.[<host-short>.]yml (when mode != gui)
    Project-tree matches win so a project can override a framework
    sequence with the same name. Returns $null when no tier matches --
    callers should pair this with Get-SequenceSearchPath to report the
    actual locations tried instead of inventing a "resolved" path.
.PARAMETER SequencesDir
    Path to the framework sequences root (e.g. test/sequences). The gui/
    and ssh/ subfolders live directly beneath this.
.PARAMETER Name
    Sequence basename without extension, e.g. "workload.guest.ubuntu.server.24".
.PARAMETER HostType
    Optional. When supplied, host-specific variants
    (<Name>.<host-short>.yml) are tried before the unsuffixed file.
.PARAMETER RepoRoot
    Optional. When supplied, project-tree dirs (project/<...>/test/<mode>/)
    are searched first. Omit for framework-only resolution.
#>
function Resolve-SequencePath {
    param(
        [Parameter(Mandatory)][string]$SequencesDir,
        [Parameter(Mandatory)][string]$Name,
        [string]$HostType,
        [string]$RepoRoot
    )
    # When a HostType is provided, prefer a host-specific sequence file
    # (filename suffix == HostType minus the 'host.' prefix). This lets a
    # single GuestKey ship divergent sequences across hosts -- e.g. KVM's
    # ubuntu.server.24 uses a cloud-image (no autoinstall, boots straight to
    # login) while Hyper-V's drives subiquity through autoinstall first.
    # When $HostType is null/empty the host-specific tiers are skipped.
    $mode = Get-SequenceMode
    $hostShort = $null
    if ($HostType) { $hostShort = $HostType -replace '^host\.','' }

    # Default RepoRoot to parent of SequencesDir's parent (test/sequences -> test -> repo).
    # Callers that already know RepoRoot can pass it explicitly to skip the inference.
    if (-not $RepoRoot) {
        $maybeTest = Split-Path -Parent $SequencesDir
        if ($maybeTest) { $RepoRoot = Split-Path -Parent $maybeTest }
    }

    # Tier 1: project tree. Scan EVERY test/<mode>/ folder under the project
    # root via Find-ProjectSequenceFile -- examples are self-contained, so a
    # sequence may live under any example's test tree. When two folders
    # contain the same filename, Find-ProjectSequenceFile throws PlannerFatal
    # so the operator resolves the duplicate before the cycle proceeds (see
    # the catch around Resolve-CyclePlan in Invoke-TestInnerRunner.ps1).
    if ($RepoRoot) {
        $modeOrder = @($mode)
        if ($mode -ne 'gui') { $modeOrder += 'gui' }
        foreach ($searchMode in $modeOrder) {
            if ($hostShort) {
                $hit = Find-ProjectSequenceFile -RepoRoot $RepoRoot -Mode $searchMode -FileName "$Name.$hostShort.yml"
                if ($hit) { return $hit }
            }
            $hit = Find-ProjectSequenceFile -RepoRoot $RepoRoot -Mode $searchMode -FileName "$Name.yml"
            if ($hit) { return $hit }
        }
    }

    # Tier 2/3: framework SequencesDir.
    if ($hostShort) {
        $hostModePath = Join-Path (Join-Path $SequencesDir $mode) "$Name.$hostShort.yml"
        if (Test-Path $hostModePath) { return $hostModePath }
    }
    $modePath = Join-Path (Join-Path $SequencesDir $mode) "$Name.yml"
    if (Test-Path $modePath) { return $modePath }
    if ($mode -ne 'gui') {
        if ($hostShort) {
            $hostGuiPath = Join-Path (Join-Path $SequencesDir 'gui') "$Name.$hostShort.yml"
            if (Test-Path $hostGuiPath) { return $hostGuiPath }
        }
        $guiPath = Join-Path (Join-Path $SequencesDir 'gui') "$Name.yml"
        if (Test-Path $guiPath) { return $guiPath }
    }
    # Nothing matched. Returning the last-tried path here would lie about
    # where the file "lives" -- callers Test-Path'd it and emitted warnings
    # naming a path that was never an actual hit. Return $null so the miss
    # is unambiguous; callers pair this with Get-SequenceSearchPath when
    # they need to show the operator which locations were searched.
    return $null
}

<#
.SYNOPSIS
    Returns the ordered list of paths Resolve-SequencePath would attempt for $Name.
.DESCRIPTION
    Mirrors the search order of Resolve-SequencePath without touching the
    filesystem -- every tier (project tree x mode x host-suffix, then
    framework SequencesDir tiers) is materialised so callers can show the
    operator exactly which locations were checked when nothing matched.
    Use this in "sequence not found" diagnostics instead of printing the
    last-attempted path as if it were the canonical location.
#>
function Get-SequenceSearchPath {
    param(
        [Parameter(Mandatory)][string]$SequencesDir,
        [Parameter(Mandatory)][string]$Name,
        [string]$HostType,
        [string]$RepoRoot
    )
    $mode = Get-SequenceMode
    $hostShort = $null
    if ($HostType) { $hostShort = $HostType -replace '^host\.','' }
    if (-not $RepoRoot) {
        $maybeTest = Split-Path -Parent $SequencesDir
        if ($maybeTest) { $RepoRoot = Split-Path -Parent $maybeTest }
    }

    $paths = New-Object System.Collections.Generic.List[string]
    if ($RepoRoot) {
        $modeOrder = @($mode)
        if ($mode -ne 'gui') { $modeOrder += 'gui' }
        foreach ($searchMode in $modeOrder) {
            foreach ($d in (Get-ProjectTestSearchDir -RepoRoot $RepoRoot -Mode $searchMode)) {
                if ($hostShort) { [void]$paths.Add((Join-Path $d "$Name.$hostShort.yml")) }
                [void]$paths.Add((Join-Path $d "$Name.yml"))
            }
        }
    }
    if ($hostShort) { [void]$paths.Add((Join-Path (Join-Path $SequencesDir $mode) "$Name.$hostShort.yml")) }
    [void]$paths.Add((Join-Path (Join-Path $SequencesDir $mode) "$Name.yml"))
    if ($mode -ne 'gui') {
        if ($hostShort) { [void]$paths.Add((Join-Path (Join-Path $SequencesDir 'gui') "$Name.$hostShort.yml")) }
        [void]$paths.Add((Join-Path (Join-Path $SequencesDir 'gui') "$Name.yml"))
    }
    return $paths.ToArray()
}

<#
.SYNOPSIS
    Resolves a sequence name to a mode-appropriate path and runs it.
.DESCRIPTION
    Thin wrapper around Invoke-Sequence: takes a sequence NAME plus the
    sequences root, resolves to gui/<Name>.yml or ssh/<Name>.yml based on
    keystrokeMechanism (with gui fallback), and delegates to Invoke-Sequence.
    Extension scripts that iterate over a list of sequence names should call
    this instead of building paths and calling Invoke-Sequence directly; the
    future config-driven runner can then reuse this function unchanged.
#>
function Invoke-SequenceByName {
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$SequencesDir,
        [Parameter(Mandatory)][string]$Name,
        [string]$RepoRoot,
        # Planner-cascaded variable overrides. When present, each key in
        # this map REPLACES the same-named entry under the sequence
        # file's `variables:` block before step expansion (top-of-chain
        # wins for the whole chain -- see Test.SequencePlanner). Empty
        # map = standalone Test-Sequence.ps1 invocation, keeps the
        # legacy "sequence-local variables win" path.
        # Use IDictionary (not [hashtable]) so an [ordered]@{} from the
        # planner keeps its insertion order through parameter binding.
        # A [hashtable] cast would coerce OrderedDictionary -> Hashtable
        # and lose the order, which then has the override loop below
        # process e.g. `currentPassword: ${ext:...(${username})}` BEFORE
        # `username: yauser1`. The `${username}` placeholder fails to
        # resolve and the literal string ends up as a vault key.
        [System.Collections.IDictionary]$EffectiveVariables,
        [switch]$ShowSensitive
    )
    $sequenceFile = Resolve-SequencePath -SequencesDir $SequencesDir -Name $Name -HostType $HostType -RepoRoot $RepoRoot
    if (-not $sequenceFile) {
        # Missing sequence file is a setup error, not an optional skip.
        # Returning $true here would let a typo in a sequence name
        # silently mark the test as passing.
        # Resolve-SequencePath returns $null on miss; show what was searched
        # (Get-SequenceSearchPath enumerates the same tier order) so the
        # operator can see the locations that were probed.
        $searched = Get-SequenceSearchPath -SequencesDir $SequencesDir -Name $Name -HostType $HostType -RepoRoot $RepoRoot
        $list = ($searched | ForEach-Object { "    $_" }) -join "`n"
        Write-Warning "[$GuestKey] Sequence file not found: $Name`nSearched (no match):`n$list"
        return $false
    }
    # Informational lines go through Write-Information, NOT Write-Output.
    # Write-Output emits to the pipeline, and combined with `return (...)`
    # below it would fold these strings into the caller's `$ok` variable —
    # turning the boolean into @("Running…", "Sequence file…", $true/$false).
    # The caller's `$ok -eq $false` still catches an honest $false inside
    # that array, but a returned $null (e.g. from an unhandled crash path)
    # would look identical to success. Keep the pipeline clean so the
    # return is strictly [bool].
    Write-Information "[$GuestKey] Running sequence: $Name on $HostType (VM: $VMName)" -InformationAction Continue
    Write-Verbose "    Sequence file: $sequenceFile"
    $result = Invoke-Sequence -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencePath $sequenceFile -EffectiveVariables $EffectiveVariables -ShowSensitive:$ShowSensitive
    # Normalize: only $true is success. Anything else — $null, objects,
    # arrays — fails. A sane Invoke-Sequence returns $true / $false and
    # this is a no-op; a broken one no longer slips past.
    return ($result -eq $true)
}

<#
.SYNOPSIS
    Executes an interaction sequence from a YAML file against a VM.
.DESCRIPTION
    Reads the steps array from the YAML file and executes each action
    sequentially. Variables in the YAML are substituted into parameters.
    Returns $true if all steps succeed, $false otherwise.
#>
function Invoke-Sequence {
    param(
        [string]$HostType,
        [string]$GuestKey,
        [string]$VMName,
        [string]$SequencePath,
        # Planner-cascaded variable overrides; see Invoke-SequenceByName.
        # Null/empty = use the sequence file's own `variables:` block
        # verbatim (standalone Test-Sequence.ps1 path).
        # Use IDictionary (not [hashtable]) so an [ordered]@{} from the
        # planner keeps its insertion order through parameter binding.
        # A [hashtable] cast would coerce OrderedDictionary -> Hashtable
        # and lose the order, which then has the override loop below
        # process e.g. `currentPassword: ${ext:...(${username})}` BEFORE
        # `username: yauser1`. The `${username}` placeholder fails to
        # resolve and the literal string ends up as a vault key.
        [System.Collections.IDictionary]$EffectiveVariables,
        [switch]$ShowSensitive
    )
    # $ShowSensitive is consumed inside $invokeStepBlock via dynamic scoping
    # (see comment block at the scriptblock definition). Touched here as
    # $null = ... so PSReviewUnusedParameter sees a body-level reference.
    $null = $ShowSensitive

    # ── SSH variant selection ──────────────────────────────────────────────
    # Sequences live in mode-specific subfolders: sequences/gui/ and
    # sequences/ssh/. When test.config.yml sets keystrokeMechanism="SSH"
    # and the caller passed a path under sequences/gui/, redirect to the
    # sequences/ssh/ sibling with the same filename. If that sibling does
    # not exist, fall back to the gui/ file so guests without an SSH
    # sequence yet continue to work (same degrade path as the legacy
    # .ssh.json sibling lookup). Comparison is case-insensitive so
    # "ssh"/"SSH" both select this branch; the canonical uppercase form
    # is written back to test.config.yml by Invoke-TestRunner's
    # validation step.
    if ($script:DefaultKeystrokeMechanism -eq "SSH") {
        $sshVariant = Get-SequenceModePath -SequencePath $SequencePath -Mode "ssh"
        if ($sshVariant -and (Test-Path $sshVariant)) {
            Write-Information "    keystrokeMechanism=SSH → using SSH variant: $(Split-Path -Leaf $sshVariant)"
            $SequencePath = $sshVariant
        }
    }

    if (-not (Test-Path $SequencePath)) {
        # Missing sequence file = setup error. A silent-skip return of
        # $true would mask sequence-name typos and bad mode resolution
        # as test successes.
        Write-Warning "    Sequence file not found: $SequencePath"
        return $false
    }

    # Initialize logDir + trackDir early so the catch block can write
    # diagnostics and the pause-flag paths resolve below. Invoke-Sequence
    # runs inside a child module scope when a test-start extension script
    # imports it, so the parent runner's global Import-Module doesn't
    # propagate here — each helper has to be re-imported on this path.
    # -Global on the -Force re-imports: without it, the nested reload
    # evicts these modules from the parent script's session state and
    # breaks subsequent top-level calls (see Get-CycleScreenDir crash).
    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    Import-Module (Join-Path $modulesDir "Test.YurunaDir.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    Import-Module (Join-Path $modulesDir "Test.Ssh.psm1")      -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    $logDir = Initialize-YurunaLogDir

  try {
    $sequence = Read-SequenceFile -Path $SequencePath

    # Clean up stale failure artifacts from any prior run
    Remove-Item (Join-Path $logDir "last_failure.json") -Force -ErrorAction SilentlyContinue

    # Build variables table: built-ins first, then YAML-defined entries
    # evaluated EAGERLY in file order. Each entry can reference any
    # variable declared above it, plus the built-ins. ${ext:...} inside
    # a value is invoked once at definition time and the resolved value
    # is stored, so two step references to the same variable always
    # type the same value (even though ${ext:...} itself is no longer
    # memoized -- pinning a generated value across multiple steps is now
    # an explicit, file-visible operation rather than implicit caching).
    #
    # Planner-cascaded overrides (-EffectiveVariables) REPLACE same-named
    # YAML entries: a workload.*.yml that defines `username: webuser`
    # propagates that value into every sequence in its dependency chain,
    # so the baseline `start.*.yml` still saying `username: yuuser26`
    # silently runs with `webuser` whenever the workload is the cycle's
    # top-level. Sequence YAML stays self-contained -- the local
    # variables: block remains the standalone-invocation fallback for
    # Test-Sequence.ps1 runs with no cascade context.
    $vars = @{ "vmName" = $VMName; "hostType" = $HostType; "guestKey" = $GuestKey }
    if ($sequence.variables) {
        foreach ($_varKey in $sequence.variables.Keys) {
            # .Contains() (not .ContainsKey) so OrderedDictionary works
            # alongside Hashtable -- OrderedDictionary only exposes Contains.
            if ($EffectiveVariables -and $EffectiveVariables.Contains($_varKey)) {
                # Cascade override wins -- skip the YAML value entirely
                # (incl. any ${ext:...} side-effecting expansion). Picked
                # up in the override-merge loop below.
                continue
            }
            $_raw = $sequence.variables[$_varKey]
            if ($_raw -is [string]) {
                $vars[$_varKey] = Expand-Variable $_raw $vars
            } else {
                $vars[$_varKey] = $_raw
            }
        }
    }
    if ($EffectiveVariables) {
        foreach ($_ovKey in $EffectiveVariables.Keys) {
            $_ovRaw = $EffectiveVariables[$_ovKey]
            if ($_ovRaw -is [string]) {
                $vars[$_ovKey] = Expand-Variable $_ovRaw $vars
            } else {
                $vars[$_ovKey] = $_ovRaw
            }
        }
    }
    # Auto-derive ${loginUser} from the resolved ${username} via the
    # authentication extension's users.yml mapping. The sequence file
    # is free to declare its own `loginUser` under variables: (or pass
    # one in via the cascade) -- only the unset case is auto-filled.
    # Empty corporate fields in users.yml mean loginUser == username
    # (today's local-only behavior); a populated corporate mapping
    # renders DOMAIN\sam or upn@domain.com.
    if (-not $vars.ContainsKey('loginUser') -and $vars.ContainsKey('username')) {
        try {
            # Import the extension area lazily; the planner / runner has
            # usually already loaded it, but standalone Test-Sequence
            # invocations may reach this path cold.
            $extLoader = Join-Path $PSScriptRoot 'Test.Extension.psm1'
            if (Test-Path $extLoader) {
                Import-Module $extLoader -Global -Force -Verbose:$false -ErrorAction SilentlyContinue
            }
            if (Get-Command Import-Extension -ErrorAction SilentlyContinue) {
                [void](Import-Extension -Area 'authentication' -RequireSingle)
            }
            if (Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue) {
                $effU = Get-EffectiveUser -LogicalUser ([string]$vars['username'])
                if ($effU -and $effU.loginUser) {
                    $vars['loginUser'] = [string]$effU.loginUser
                }
            }
        } catch {
            Write-Verbose "loginUser auto-derivation skipped: $($_.Exception.Message)"
        }
        # Defensive: when the auth extension is unavailable (rare;
        # standalone test eval) keep ${loginUser} == ${username} so
        # sequences referencing the token don't render as the literal
        # placeholder string.
        if (-not $vars.ContainsKey('loginUser')) { $vars['loginUser'] = $vars['username'] }
    }

    Write-Information "    Sequence: $($sequence.description)"
    $steps = @($sequence.steps)

    # Per-step perf logging. Set-PerfSequenceContext / Set-PerfGuestContext
    # are silent no-ops when Test.Perf is not loaded OR when Start-PerfCycle
    # never ran (e.g. a direct Test-Sequence.ps1 invocation outside the
    # runner), so this block is safe to call unconditionally. The raw YAML
    # body is snapshotted so a row's sequenceContentHash can be mapped
    # back to the exact sequence that ran -- gui/ and ssh/ variants of
    # the same logical sequence share a sequenceGuid; the content hash
    # discriminates them.
    if (Get-Command -Name Set-PerfSequenceContext -ErrorAction SilentlyContinue) {
        try {
            $seqName     = [System.IO.Path]::GetFileNameWithoutExtension($SequencePath)
            $seqGuid     = if ($sequence.Contains('sequenceGuid'))     { [string]$sequence.sequenceGuid }     else { $null }
            $seqRevision = if ($sequence.Contains('sequenceRevision')) { [int]$sequence.sequenceRevision }   else { 0 }
            $seqBody     = $null
            try {
                $seqBody = [System.IO.File]::ReadAllText($SequencePath)
            } catch {
                $readErr = $_
                Write-Information "Perf: sequence file read failed; perf row will lack sequenceContentHash. Path=$SequencePath Error=$($readErr.Exception.Message)"
                Send-CycleEventSafely -EventRecord @{
                    timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event     = 'perf_context_unavailable'
                    reason    = 'sequence_read_failed'
                    path      = [string]$SequencePath
                    error     = $readErr.Exception.Message
                }
            }
            Set-PerfSequenceContext -SequenceName $seqName -SequenceGuid $seqGuid -SequenceRevision $seqRevision -SequenceContent $seqBody
            Set-PerfGuestContext    -GuestKey $GuestKey -VMName $VMName
        } catch {
            $setupErr = $_
            Write-Information "Perf-context setup failed (non-fatal): $($setupErr.Exception.Message)"
            Send-CycleEventSafely -EventRecord @{
                timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                event     = 'perf_context_unavailable'
                reason    = 'setup_failed'
                path      = [string]$SequencePath
                error     = $setupErr.Exception.Message
            }
        }
    }

    if ($steps.Count -eq 0) {
        Write-Verbose "    No steps defined."
        return $true
    }
    Write-Verbose "    Steps: $($steps.Count)"

    # Step-pause back-channel: the status server's /control/step-pause
    # endpoint creates $env:YURUNA_RUNTIME_DIR/control.step-pause. We gate
    # on that file in two places:
    #   1. Before sequence setup (here, below) — so Restart-VMConnect and any
    #      per-sequence work don't run while paused, and the very first
    #      action of a new sequence can't start while paused. This matters
    #      most between two sequences (e.g. Test-Start → Test-Workload, or
    #      one guest's workload → the next guest's workload) where clicking
    #      Pause used to only take effect after the next sequence had
    #      already started its first action.
    #   2. At the top of each step iteration (further below) — so a click
    #      mid-sequence takes effect before the next action.
    # Empty-steps sequences have already returned above, so the sequence-
    # level wait here never triggers for a sequence that has nothing to do.
    # Cycle-pause (control.cycle-pause) is gated separately in
    # Invoke-TestRunner.ps1 at cycle boundaries — Invoke-Sequence is only
    # concerned with step-level pauses.
    $runtimeDir = Initialize-YurunaRuntimeDir
    $stepPauseFlagFile = Join-Path $runtimeDir 'control.step-pause'
    # Cycle-restart back-channel: the status server's /control/start-cycle
    # endpoint sets this flag while it kills in-progress VMs. The inter-
    # cycle delay loop in Invoke-TestInnerRunner already breaks on it, but
    # if the request lands while a cycle is actively executing steps the
    # delay loop never sees it — the cycle limps through screenshot
    # failures of deleted VMs and the operator's "restart now" never
    # arrives. Gating here too makes the abort fire from inside an active
    # cycle: the throw escapes through retry / sequence / runner and is
    # recognised by the inner's cycle-catch by the message prefix.
    $cycleRestartFlagFile = Join-Path $runtimeDir 'control.cycle-restart'

    # Current-action sidecar: write the in-progress step to a small JSON file
    # that the status server can serve at /runtime/current-action.json. The UI
    # polls it alongside status.json and renders the line under the matching
    # guest card. We write at the top of each iteration (so the UI sees the
    # step that's about to run, not the one that just finished) and once more
    # at the end of a successful sequence with the "[All N steps completed]"
    # summary.
    $currentActionFile = Join-Path $runtimeDir 'current-action.json'
    $writeCurrentAction = {
        param([string]$Line)
        $attempts = 0
        $lastErr  = $null
        while ($attempts -lt 3) {
            $attempts++
            try {
                $doc = [ordered]@{
                    guestKey  = $GuestKey
                    vmName    = $VMName
                    line      = $Line
                    updatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                }
                $tmp = "$currentActionFile.tmp"
                $doc | ConvertTo-Json -Compress | Set-Content -Path $tmp -Encoding utf8NoBOM
                Move-Item -Path $tmp -Destination $currentActionFile -Force
                return
            } catch {
                $lastErr = $_
                Start-Sleep -Milliseconds (50 * $attempts)
            }
        }
        Write-Warning "current-action.json write failed after $attempts attempts: $($lastErr.Exception.Message) (path=$currentActionFile)"
        Send-CycleEventSafely -EventRecord @{
            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            event     = 'sidecar_write_failed'
            file      = 'current-action.json'
            path      = [string]$currentActionFile
            attempts  = $attempts
            error     = $lastErr.Exception.Message
        }
    }

    # Shared pause-wait block. Used both at sequence start (Label='[sequence
    # start]') and at the top of each step (Label='[stepNum/Count]').
    # Dynamic scoping resolves $stepPauseFlagFile and $writeCurrentAction
    # from the caller's scope at invoke time, so the scriptblock doesn't
    # need its own parameters for those.
    $waitWhilePaused = {
        param([string]$Label)
        if (Test-Path $stepPauseFlagFile) {
            & $writeCurrentAction "$Label Paused (waiting for resume)"
            Write-Information "    $Label Paused (status-service request). Waiting for resume..."
            $pauseAttempt = 1
            while (Test-Path $stepPauseFlagFile) {
                Start-Sleep -Milliseconds (Get-PollDelay -Attempt $pauseAttempt)
                $pauseAttempt++
            }
            Write-Information "    $Label Resumed."
        }
    }

    # Cycle-restart gate. Throws a message-prefixed exception so the inner
    # runner's cycle-catch (see Invoke-TestInnerRunner.ps1) can short-
    # circuit emergency-cleanup chatter and skip the ConsecutiveCrashes
    # increment for this expected abort. The flag is intentionally NOT
    # cleared here: the post-cycle inter-cycle delay loop will consume it
    # on its next tick, which keeps the existing "wake delay early" path
    # working unchanged. If the inner is already past the delay (i.e.
    # actively running this sequence), the throw propagates up through
    # any enclosing retry / step / sequence frames straight to the cycle
    # try/catch.
    $checkCycleRestart = {
        param([string]$Label)
        if (Test-Path $cycleRestartFlagFile) {
            & $writeCurrentAction "$Label cycle-restart requested (aborting cycle)"
            Write-Information "    $Label cycle-restart signal seen — aborting current cycle."
            throw "YurunaCycleRestart: status-service /control/start-cycle requested mid-cycle abort at $Label"
        }
    }

    # Gate #1: sequence-level pause + cycle-restart check, before any per-
    # sequence work. Pause is checked first so an operator-initiated pause
    # that overlaps a restart click still resolves predictably (pause
    # wins until released, then the restart flag is observed).
    & $waitWhilePaused "[sequence start]"
    & $checkCycleRestart "[sequence start]"

    # HACK: Force vmconnect to repaint by reconnecting.
    # After a host reboot the Hyper-V console window may render blank;
    # closing and reopening it forces a full framebuffer refresh.
    # Yuruna.Host's Restart-VMConsole is in scope here because
    # Initialize-YurunaHost is called by Test-Sequence.ps1 /
    # Invoke-TestRunner.ps1 before sequences run.
    [void](Restart-VMConsole -VMName $VMName -Confirm:$false)

    # takeScreenshot debug PNGs land under test/status/captures/sequences/
    # (gitignored runtime data, lives with the rest of the harness state
    # so cleaning a host is one rm -rf status/* away). Sequence name is
    # prefixed onto each filename in Save-DebugScreenshot, so a single
    # flat folder keeps captures organized without a per-sequence subdir.
    # Anchor on $PSScriptRoot (this module lives at <TestRoot>/modules/);
    # $SequencePath is unreliable as an anchor because the chain runner
    # writes per-entry slices to the OS temp dir and project-tree
    # sequences live under <RepoRoot>/project/.../test/<mode>/.
    $testRoot = Split-Path -Parent $PSScriptRoot
    $screenshotDir = Join-Path -Path $testRoot -ChildPath 'status' `
                         -AdditionalChildPath 'captures', 'sequences'
    $sequenceStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # ── Recursive step executor ─────────────────────────────────────────────
    # Wrapped as a script-block so the `retry` action case (below) can call
    # it on its inner `steps:` array, reusing the full per-step
    # infrastructure: pause checks, currentAction sidecar, progress ticks,
    # variable expansion, the action switch, PASS/FAIL logging. The block
    # resolves $vars, $writeCurrentAction, $waitWhilePaused, $HostType,
    # $VMName, $GuestKey, $logDir, $screenshotDir, $ShowSensitive, and the
    # $script:Default* defaults from the enclosing function scope via
    # PowerShell's dynamic-scoping read semantics; the param $Steps shadows
    # the outer $steps within the block. On step failure the block captures
    # context into $script:LastFailure* and returns $false. The OUTER call
    # site below is what writes last_failure.json + failure screenshot +
    # post-failure pause, so a transient failure inside a retry attempt
    # never pollutes last_failure.json -- only an exhausted-retry failure
    # (or a non-retry failure) does, after the outer call finally returns.
    $invokeStepBlock = {
        param(
            [Parameter(Mandatory)][object[]]$Steps,
            # Set by the retry recursion: outer retry's ordinal + 'retry' so
            # rows from inner steps can be joined back to the retry wrapper
            # at query time without inventing a step GUID.
            [int]$ParentOrdinal = 0,
            [string]$ParentAction = ''
        )
        $stepNum = 0
        foreach ($step in $Steps) {
            $stepNum++
            # Gate #2: between-steps pause + cycle-restart check. Catches
            # a Pause or a "Save and start cycle" clicked while the previous
            # step was running. The throw inside $checkCycleRestart escapes
            # this $invokeStepBlock (including any wrapping `retry` block —
            # retry only catches $false returns, not exceptions) and bubbles
            # up to the cycle-level try/catch in Invoke-TestInnerRunner.
            & $waitWhilePaused "[$stepNum/$($Steps.Count)]"
            & $checkCycleRestart "[$stepNum/$($Steps.Count)]"
            $desc = $step.description ? (Expand-Variable $step.description $vars) : $step.action
            & $writeCurrentAction "[$stepNum/$($Steps.Count)] $($step.action): $desc"
            # Refresh runner.stepHeartbeat from the runspace so the outer
            # watchdog can detect a single step that exceeds stepTimeout-
            # Minutes. We do NOT update this inside the action's own poll
            # loop -- the threadpool-driven runner.heartbeat already
            # provides proof-of-life for the process. Refreshing only at
            # step boundaries means the watchdog kicks in if any single
            # step (waitForText with its own deadline, ssh exec, retry
            # block) hangs longer than the configured budget.
            try {
                $stepHbFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'
                [System.IO.File]::WriteAllText($stepHbFile, [DateTime]::UtcNow.ToString('o'))
            } catch {
                Write-Verbose "runner.stepHeartbeat refresh failed: $($_.Exception.Message)"
            }

            # `retry` is dispatched through the registry like every other
            # verb; the Handler lives at the bottom of this module next
            # to its Register-SequenceAction.

        # Current-step visibility is intentionally driven by Write-Progress
        # (via Write-ProgressTick below), NOT by a Write-Information here.
        # A Write-Information at step-start would go through the Yuruna.Log
        # proxy and leave a permanent line in both the terminal and the log
        # transcript — then the end-of-step completion line (with elapsed
        # time) would appear below rather than replacing it. Write-Progress
        # renders out-of-band (floating bar) and auto-dismisses on
        # -Completed, so the scroll-permanent log gets exactly one entry
        # per step (the completion).
        $savedProgress = $global:ProgressPreference
        $global:ProgressPreference = 'Continue'
        try {
        Write-ProgressTick -Activity "Sequence" -Status "[$stepNum/$($steps.Count)] $($step.action): $desc" -PercentComplete ([math]::Round((($stepNum - 1) / [math]::Max($steps.Count,1)) * 100))

        $stepStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        # Wall-clock start captured alongside the stopwatch so the perf
        # row carries an absolute UTC timestamp (needed for cross-host
        # joins) without trying to subtract elapsed ms from the END
        # time -- the two clocks would diverge by the GC/IO time of the
        # write itself.
        $stepStartUtc = [DateTime]::UtcNow
        $ok = $true

        # Per-step registry dispatch. Test.SequenceAction lets a verb
        # register a Handler scriptblock; the Context hashtable is the
        # canonical state surface (no closures over the parent function's
        # locals). Every built-in verb -- including `retry` -- registers
        # a Handler.
        # A YAML typo (e.g. "tapButton" instead of "tapOn") or a third-
        # party verb that registered a FailureLabel without a Handler
        # surfaces here as a hard fail so it never silently passes.
        if (Test-SequenceActionHasHandler -Name $step.action) {
            $ctx = @{
                Step                  = $step
                StepNum               = $stepNum
                StepCount             = $steps.Count
                Steps                 = $steps
                Vars                  = $vars
                VMName                = $VMName
                GuestKey              = $GuestKey
                HostType              = $HostType
                LogDir                = $logDir
                RuntimeDir            = $runtimeDir
                ScreenshotDir         = $screenshotDir
                ShowSensitive         = $ShowSensitive
                SequencePath          = $SequencePath
                ExpandVariable        = ${function:Expand-Variable}
                # Step-default param resolution lives in each handler
                # scriptblock; these mirror the values the engine used to
                # read directly from $script:Default*.
                DefaultCharDelayMs    = $script:DefaultCharDelayMs
                DefaultPollSeconds    = $script:DefaultPollSeconds
                DefaultTimeoutSeconds = $script:DefaultTimeoutSeconds
                # Action helpers used by break / retry / composite verbs.
                WriteCurrentAction    = $writeCurrentAction
                WaitWhilePaused       = $waitWhilePaused
                InvokeStepBlock       = $invokeStepBlock
                # Description string the engine resolved for this step;
                # the retry handler uses it in attempt-progress logs so
                # the operator sees the original ${var}-expanded text.
                Description           = $desc
            }
            $ok = Invoke-SequenceActionHandler -Name $step.action -Context $ctx
        } else {
            Write-Warning "Unknown action '$($step.action)' -- treating as failure."
            $ok = $false
        }
        } finally {
            $global:ProgressPreference = $savedProgress
        }

        # Normalize $ok. Anything that isn't a strict [bool] — $null, an
        # accidentally-polluted pipeline array, a string, an exception object
        # wrapped by a catch — is treated as failure. Without this, helpers
        # that forget to `return $true`/`return $false` (or that leak a stray
        # Write-Output) silently pass the step despite a timeout.
        if ($ok -isnot [bool]) {
            $okType = if ($null -eq $ok) { '<null>' } else { $ok.GetType().Name }
            Write-Warning "    Step [$stepNum] action '$($step.action)' returned a non-boolean ($okType) — treating as failure."
            $ok = $false
        }

        $stepStopwatch.Stop()
        $elapsedLabel = ("    {0,4}" -f [int]$stepStopwatch.Elapsed.TotalSeconds)
        $stepMarker   = if ($ok) { 'PASS' } else { 'FAIL' }
        Write-Information "$elapsedLabel s [$stepNum/$($steps.Count)] $stepMarker $($step.action): $desc"

        # One NDJSON line per step_end so a downstream consumer can plot
        # pass/fail rates without HTML scraping. Carries the SUPERSET
        # schema (hostType, action, description, failureClass-when-known)
        # of step_failure so a downstream consumer can do a single
        # schema join across step_end + step_failure rows. The
        # failureClass/severity/suggestedRecoveries fields are populated
        # from the verb's static registration -- on a passing step they
        # surface "what the verb *would* class a failure as".
        $stepVerbEntry = Get-SequenceAction -Name ([string]$step.action)
        $stepFailureClass = if ($stepVerbEntry) { [string]$stepVerbEntry.FailureClass } else { 'unknown' }
        $stepSeverity     = if ($stepVerbEntry) { [string]$stepVerbEntry.Severity }     else { 'unknown' }
        # Avoid the dual unwrap trap: PowerShell flattens single-element
        # arrays AND empty arrays out of an if-statement's pipeline
        # output, so `[string[]]$x = if (...) { @(...) }` yields a scalar
        # on a 1-element value and $null on an empty value. The two-step
        # form below initialises to an empty string[] up front, then
        # overwrites only when there are entries to materialise; either
        # outcome serialises as a JSON array and clears the schema
        # validator's typed-array check.
        [string[]]$stepSuggested = @()
        if ($stepVerbEntry -and $null -ne $stepVerbEntry.SuggestedRecoveries) {
            [string[]]$stepSuggested = @($stepVerbEntry.SuggestedRecoveries)
        }
        Send-CycleEventSafely -EventRecord @{
            timestamp           = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            event               = 'step_end'
            stepNumber          = [int]$stepNum
            totalSteps          = [int]$steps.Count
            actionVerb          = [string]$step.action
            ok                  = [bool]$ok
            durationMs          = [int]$stepStopwatch.Elapsed.TotalMilliseconds
            vmName              = $VMName
            guestKey            = $GuestKey
            hostType            = $HostType
            action              = [string]$step.action
            description         = [string]$desc
            failureClass        = $stepFailureClass
            severity            = $stepSeverity
            suggestedRecoveries = $stepSuggested
            sequencePath        = $SequencePath
        }
        # Track the last passing step number so the failure payload can
        # surface lastSucceededStepNumber -- a remediator that wants to
        # replay needs to know the boundary it can safely resume past.
        if ($ok) { $script:LastSucceededStepNumber = $stepNum }

        # Emit one structured row per step execution. stepName is the
        # RAW (pre-expansion) YAML `description:` -- variables like
        # ${vmName} are intentionally NOT expanded here so cross-cycle
        # joins on stepName remain stable even though vmName carries a
        # per-cycle timestamp suffix. Falls back to step.action when no
        # description is set. retry-wrappers don't emit (they exit via
        # `continue` above the stopwatch); their wall-clock cost is the
        # sum of the inner rows.
        if (Get-Command -Name Write-PerfStepRow -ErrorAction SilentlyContinue) {
            try {
                $stepName = if ($step.Contains('description') -and $step.description) { [string]$step.description } else { [string]$step.action }
                Write-PerfStepRow `
                    -StepName          $stepName `
                    -StepOrdinal       $stepNum `
                    -StepKind          ([string]$step.action) `
                    -StartedAtUtc      $stepStartUtc `
                    -EndedAtUtc        ([DateTime]::UtcNow) `
                    -DurationMs        ([int]$stepStopwatch.Elapsed.TotalMilliseconds) `
                    -Outcome           ($ok ? 'pass' : 'fail') `
                    -ParentStepOrdinal $ParentOrdinal `
                    -ParentAction      $ParentAction
            } catch {
                Write-Verbose "Write-PerfStepRow failed (non-fatal): $($_.Exception.Message)"
            }
        }

        if (-not $ok) {
            Write-Warning "    Step [$stepNum] failed: $desc"

            # Build a human-readable failed-step label (e.g. 'waitForText: "login prompt"').
            # Canonical builder: Test.SequenceAction\Get-SequenceActionFailureLabel.
            # Each verb's FailureLabel scriptblock lives next to its capability
            # requirements at the bottom of this module — search for
            # Register-SequenceAction. The OUTER call site reads $script:Last-
            # Failure* below to write last_failure.json + the failure screen-
            # shot. Capturing here (and only returning $false) keeps transient
            # retry-attempt failures from leaving a stale last_failure.json
            # behind.
            $actionLabel = Get-SequenceActionFailureLabel -Step $step -Vars $vars -ExpandVariable ${function:Expand-Variable}

            # If Wait-ForText short-circuited on a failurePattern, annotate
            # the step label so the runner's ERROR banner and the per-run
            # failure JSON both say *why* the step died instead of the
            # generic "pattern not found within Ns". Only waitForText /
            # waitForAndEnter / passwdPrompt set this signal; for other
            # actions the variable is $null and the label is unchanged.
            if (($step.action -eq 'waitForText' -or $step.action -eq 'waitForAndEnter' -or $step.action -eq 'passwdPrompt') -and
                $script:WaitForTextMatchedFailurePattern) {
                $actionLabel = $actionLabel + " -- matched failurePattern `"$($script:WaitForTextMatchedFailurePattern)`""
            }

            $script:LastFailureLabel       = $actionLabel
            $script:LastFailureDescription = $desc
            $script:LastFailedAction       = $step.action
            $script:LastFailedStepNumber   = $stepNum
            return $false
        }
        }  # end foreach inside $invokeStepBlock
        return $true
    }  # end $invokeStepBlock

    $script:LastFailureLabel       = $null
    $script:LastFailureDescription = $null
    $script:LastFailedAction       = $null
    $script:LastFailedStepNumber   = 0
    # Inner-verb capture for retry-exhausted failures. The outer per-step
    # block at line ~2063 overwrites $script:LastFailedAction with the
    # OUTER step's action name (= 'retry') whenever a Handler returns
    # $false; that collapses the deepest inner verb's classification
    # into 'retry_exhausted'. The retry Handler captures the inner verb
    # into these slots BEFORE returning so the v2 emitter below can
    # surface both classes -- 'retry_exhausted' for the outer step,
    # plus the inner class an autonomous remediator needs to pick the
    # right recovery (an OCR timeout asks for a different remediation
    # than an SSH down).
    $script:LastInnerFailedAction         = $null
    $script:LastInnerFailureClass         = $null
    $script:LastInnerSeverity             = $null
    $script:LastInnerSuggestedRecoveries  = @()
    # lastSucceededStepNumber: the step-N boundary a replay can safely
    # resume past. Reset to 0 at sequence start so a fresh-cycle
    # failure on step 1 surfaces as "no step succeeded" rather than
    # carrying a leftover value from a prior sequence's run.
    $script:LastSucceededStepNumber       = 0
    $result = & $invokeStepBlock -Steps $steps
    if (-not $result) {
        # Build the failure-context JSON from the deepest captured context.
        # For a retry-exhausted failure, $script:LastFailureLabel was already
        # wrapped in "retry exhausted (N attempts): ..." by the retry handler,
        # and $script:LastFailedStepNumber is the OUTER retry step's number
        # (not the inner sub-step) so the operator sees the outer position.
        # last_failure.json schema v2: the v1 fields stay as-is for
        # back-compat; v2 adds machine-readable failureClass / severity /
        # suggestedRecoveries / actionVerb / context so a downstream
        # remediation loop can route on the class without regex-parsing
        # the human label. See docs/failure-schema.md.
        $verbEntry = Get-SequenceAction -Name $script:LastFailedAction
        $failureClass = if ($verbEntry) { $verbEntry.FailureClass } else { 'unknown' }
        $severity     = if ($verbEntry) { $verbEntry.Severity }     else { 'unknown' }
        # Two-step assignment so an empty SuggestedRecoveries does not
        # collapse to $null via the if-pipeline flatten (see step_end
        # emit above).
        [string[]]$suggested = @()
        if ($verbEntry -and $null -ne $verbEntry.SuggestedRecoveries) {
            [string[]]$suggested = @($verbEntry.SuggestedRecoveries)
        }
        # Failure-pattern annotation surfaces when Wait-ForText short-
        # circuited on a hard-block pattern (set by the engine inside the
        # waitForText/waitForAndEnter/passwdPrompt Handlers).
        $matchedFailPattern = $script:WaitForTextMatchedFailurePattern
        if ($matchedFailPattern) { $failureClass = 'pattern_matched_failure' }
        # When the deepest failure was inside a retry block, the retry
        # Handler captured the inner verb's class into
        # $script:LastInnerFailedAction. Surface BOTH the outer
        # 'retry_exhausted' classification and the inner verb's class
        # so a remediator can route on the inner cause.
        #
        # Deep-link fields under .context: failureScreenshotPath and
        # failureOcrPath are relative to the cycle log dir, so a
        # consumer that has the cycle folder URL can deep-link directly.
        # cycleFolderUrl is intentionally omitted here (a remediator
        # joining last_failure.json with the notification's EventData
        # already has it from Get-FailureEventData); we surface the
        # cycleFolder *path* so a same-host consumer can resolve files
        # without re-deriving format.
        $failScreenName = "failure_screenshot_${VMName}.png"
        $failOcrName    = "failure_ocr_${VMName}.txt"
        $failureInfo = [ordered]@{
            schemaVersion = 2
            stepNumber    = $script:LastFailedStepNumber
            totalSteps    = $steps.Count
            action        = $script:LastFailureLabel
            description   = $script:LastFailureDescription
            vmName        = $VMName
            guestKey      = $GuestKey
            timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
            # v2 fields below this line.
            failureClass        = $failureClass
            severity            = $severity
            suggestedRecoveries = $suggested
            actionVerb          = [string]$script:LastFailedAction
            # Replay boundary: step N succeeded; step N+1 (== stepNumber)
            # is where the failure landed. A remediator that wants to
            # resume past N must guarantee the precondition state for
            # N+1 itself -- this field is the "what's safe to replay
            # past" boundary, not an automatic-resume-from pointer.
            lastSucceededStepNumber = [int]$script:LastSucceededStepNumber
            # Inner verb fields: only set when the failure bubbled up
            # through a `retry` Handler that exhausted its attempts.
            # $null on every non-retry failure so a remediator can
            # branch on presence.
            innerActionVerb            = $script:LastInnerFailedAction
            innerFailureClass          = $script:LastInnerFailureClass
            innerSeverity              = $script:LastInnerSeverity
            innerSuggestedRecoveries   = @($script:LastInnerSuggestedRecoveries)
            context             = [ordered]@{
                hostType              = $HostType
                matchedFailurePattern = $matchedFailPattern
                sequencePath          = $SequencePath
                cycleFolder           = $logDir
                # Relative paths so a consumer that only has the
                # cycleFolder URL can deep-link without absolute-path
                # gymnastics. Files may not exist (waitForText emits
                # OCR text only; non-OCR failures emit only the
                # screenshot); presence is checked at deep-link time.
                failureScreenshotPath = $failScreenName
                failureOcrPath        = $failOcrName
            }
        } | ConvertTo-Json -Depth 4
        $failureFile = Join-Path $logDir "last_failure.json"
        # Atomic write: a remediator/status reader must never observe a
        # truncated last_failure.json mid-write (partial-write regression
        # class). Write-YurunaStateFile does temp-write + rename.
        $null = Write-YurunaStateFile -Path $failureFile -Content $failureInfo -Confirm:$false
        # Also emit a single NDJSON line for downstream stream consumers
        # (status server, future remediation loop, CI hook).
        Send-CycleEventSafely -EventRecord @{
            timestamp               = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            event                   = 'step_failure'
            stepNumber              = $script:LastFailedStepNumber
            totalSteps              = $steps.Count
            actionVerb              = [string]$script:LastFailedAction
            # ok=false mirrors the step_end shape so an LLM joining
            # the two event types can filter on a single field.
            ok                      = $false
            # No durationMs available on failure path (the failing
            # step's stopwatch was captured by the outer block but
            # not threaded through to this emit). Surfacing $null
            # rather than omitting the field keeps schema parity
            # with step_end.
            durationMs              = $null
            failureClass            = $failureClass
            severity                = $severity
            suggestedRecoveries     = $suggested
            lastSucceededStepNumber = [int]$script:LastSucceededStepNumber
            # Inner verb fields mirror last_failure.json v2 above so
            # a streaming consumer doesn't need to cross-reference
            # the static file for retry-exhausted classification.
            innerActionVerb            = $script:LastInnerFailedAction
            innerFailureClass          = $script:LastInnerFailureClass
            innerSeverity              = $script:LastInnerSeverity
            innerSuggestedRecoveries   = @($script:LastInnerSuggestedRecoveries)
            vmName                  = $VMName
            guestKey                = $GuestKey
            hostType                = $HostType
            action                  = $script:LastFailureLabel
            description             = $script:LastFailureDescription
            sequencePath            = $SequencePath
            failureScreenshotPath   = "failure_screenshot_${VMName}.png"
            failureOcrPath          = "failure_ocr_${VMName}.txt"
        }

        # For non-OCR failures, capture a screenshot now (waitForText / waitForAndEnter
        # / passwdPrompt / fetchAndExecute already save one in their own failure paths).
        # Use the DEEPEST failed action's name -- after retry-exhausted, that's the inner
        # action, not 'retry' itself.
        if ($script:LastFailedAction -ne "waitForText" -and $script:LastFailedAction -ne "waitForAndEnter" -and $script:LastFailedAction -ne "passwdPrompt" -and $script:LastFailedAction -ne "fetchAndExecute") {
            $failScreenPath = Join-Path $logDir "failure_screenshot_${VMName}.png"
            $captured = Get-VMScreenshot -VMName $VMName -OutFile $failScreenPath
            if ($captured) {
                Write-Information "      Failure screenshot saved: $failScreenPath"
            }
        }

        # Gate #3: post-failure pause check. Without this gate, a Pause-after-step
        # armed during the failing step is silently dropped and the caller
        # cascades the failure to the next sequence/cycle. Run AFTER writing
        # last_failure.json + the screenshot so the status UI shows the failure
        # context while the user decides whether to resume. Resuming does not
        # change the outcome -- the step is still a failure -- it only gives
        # the user time to investigate before the runner moves on.
        & $waitWhilePaused "[$($script:LastFailedStepNumber)/$($steps.Count)] FAIL"
        return $false
    }

    Write-ProgressTick -Activity "Sequence" -Completed
    $sequenceStopwatch.Stop()
    $sequenceElapsedLabel = ("{0,4}" -f [int]$sequenceStopwatch.Elapsed.TotalSeconds)
    $elapsedTotalSeconds = [int]$sequenceStopwatch.Elapsed.TotalSeconds
    $elapsedTimeIsMinutes = "$([int]($elapsedTotalSeconds / 60)) min and $($elapsedTotalSeconds % 60) s"
    Write-Information "    $sequenceElapsedLabel s [All $($steps.Count) steps completed in $elapsedTimeIsMinutes]"
    & $writeCurrentAction "[All $($steps.Count) steps completed in $elapsedTimeIsMinutes]"
    return $true

  } catch {
    # YurunaCycleRestart is a control-flow marker from the cycle-restart
    # gate ($checkCycleRestart), not an actual sequence failure. The gate
    # comment at Gate #2 promises it "bubbles up to the cycle-level try/
    # catch in Invoke-TestInnerRunner" — re-throw before the generic
    # handler turns it into a Write-Warning + return $false, which would
    # leave control.cycle-restart unconsumed and the flag re-fires on every
    # subsequent sequence's [sequence start] gate.
    if ($_.Exception.Message -like 'YurunaCycleRestart:*') { throw }
    # Print the message AND the throwing-statement origin AND the
    # call stack. Without these the operator gets only the .Exception
    # text (e.g. 'Exception calling "Replace" with "3" argument(s)')
    # and has to grep ten modules to find the actual throw.
    Write-Warning "    Invoke-Sequence unhandled error: $_"
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Warning "    Origin:"
        foreach ($line in ($_.InvocationInfo.PositionMessage -split "`n")) {
            Write-Warning "      $line"
        }
    }
    if ($_.ScriptStackTrace) {
        Write-Warning "    Stack:"
        foreach ($line in ($_.ScriptStackTrace -split "`n")) {
            Write-Warning "      $line"
        }
    }
    # Preserve diagnostics for the crash, in the SAME schema-v2 shape
    # the normal failure path emits at line ~2195. Without this, a
    # throw from any verb Handler (or from infrastructure between
    # steps) silently downgrades last_failure.json from v2 to a v0
    # crash payload, stripping failureClass/severity/suggested
    # Recoveries -- the exact fields a downstream remediator routes
    # on. When $script:LastFailedAction was already captured by the
    # foreach at L~2162 we resolve its registry entry; otherwise we
    # emit an engine_crash classification so the schema shape is
    # always v2 and the crash diagnostics live under .context.
    try {
        $crashAction = if ($script:LastFailedAction) { [string]$script:LastFailedAction } else { 'script_error' }
        $crashVerb   = if ($script:LastFailedAction) { Get-SequenceAction -Name $script:LastFailedAction } else { $null }
        $crashClass  = if ($crashVerb) { [string]$crashVerb.FailureClass } else { 'engine_crash' }
        $crashSev    = if ($crashVerb) { [string]$crashVerb.Severity }     else { 'fatal' }
        # Two-step assignment so an empty SuggestedRecoveries does not
        # collapse to $null via the if-pipeline flatten.
        [string[]]$crashSugg = @('Inspect the crash origin/stack under .context; cycle continues unless StopOnFailure is set.')
        if ($crashVerb -and $null -ne $crashVerb.SuggestedRecoveries) {
            [string[]]$crashSugg = @($crashVerb.SuggestedRecoveries)
        }
        $crashLabel  = if ($script:LastFailureLabel) { [string]$script:LastFailureLabel } else { "engine crash: $($_.Exception.Message)" }
        $crashDesc   = if ($script:LastFailureDescription) { [string]$script:LastFailureDescription } else { '(crash before step completion)' }
        $crashStep   = if ($script:LastFailedStepNumber) { [int]$script:LastFailedStepNumber } else { 0 }
        $crashInfo = [ordered]@{
            schemaVersion = 2
            stepNumber    = $crashStep
            totalSteps    = [int]$steps.Count
            action        = $crashLabel
            description   = $crashDesc
            vmName        = $VMName
            guestKey      = $GuestKey
            timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
            failureClass        = $crashClass
            severity            = $crashSev
            suggestedRecoveries = $crashSugg
            actionVerb          = $crashAction
            context             = [ordered]@{
                hostType              = $HostType
                matchedFailurePattern = $script:WaitForTextMatchedFailurePattern
                sequencePath          = $SequencePath
                crash = [ordered]@{
                    error  = "$_"
                    origin = $_.InvocationInfo ? $_.InvocationInfo.PositionMessage : $null
                    stack  = $_.ScriptStackTrace
                }
            }
        } | ConvertTo-Json -Depth 6
        # Atomic, best-effort: a reader must never see a truncated crash
        # record. Write-YurunaStateFile returns $false (rather than
        # throwing) on failure, matching the prior SilentlyContinue
        # behavior while eliminating the partial-write window.
        $null = Write-YurunaStateFile -Path (Join-Path $logDir "last_failure.json") -Content $crashInfo -Confirm:$false
        # Mirror the normal failure path's NDJSON emission. Without this,
        # a streaming consumer following cycle.events.ndjson sees the
        # last step_end but no step_failure -- the cycle silently goes
        # quiet, indistinguishable from a clean exit on the wire. Same
        # superset shape as the normal-path step_failure event (includes
        # inner-verb fields when retry was in flight) so downstream
        # joins on schema don't have to special-case engine_crash.
        Send-CycleEventSafely -EventRecord @{
            timestamp                = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            event                    = 'step_failure'
            stepNumber               = $crashStep
            totalSteps               = [int]$steps.Count
            actionVerb               = $crashAction
            ok                       = $false
            durationMs               = $null
            failureClass             = $crashClass
            severity                 = $crashSev
            suggestedRecoveries      = $crashSugg
            lastSucceededStepNumber  = [int]$script:LastSucceededStepNumber
            innerActionVerb          = $script:LastInnerFailedAction
            innerFailureClass        = $script:LastInnerFailureClass
            innerSeverity            = $script:LastInnerSeverity
            innerSuggestedRecoveries = @($script:LastInnerSuggestedRecoveries)
            vmName                   = $VMName
            guestKey                 = $GuestKey
            hostType                 = $HostType
            action                   = $crashLabel
            description              = $crashDesc
            sequencePath             = $SequencePath
            failureScreenshotPath    = "failure_screenshot_${VMName}.png"
            failureOcrPath           = "failure_ocr_${VMName}.txt"
            crashError               = "$_"
        }
    } catch {
        $writeErr = $_
        Write-Warning "Could not write last_failure.json: $($writeErr.Exception.Message)"
        Send-CycleEventSafely -EventRecord @{
            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            event     = 'last_failure_write_failed'
            path      = (Join-Path $logDir 'last_failure.json')
            error     = $writeErr.Exception.Message
        }
    }
    return $false
  }
}

# ── Host I/O provider registrations ─────────────────────────────────────────
# Lifted to per-host singular-noun modules:
#   Test.HostIO.HyperV.psm1   host.windows.hyper-v
#   Test.HostIO.Utm.psm1      host.macos.utm
#   Test.HostIO.Kvm.psm1      host.ubuntu.kvm
# Each module owns only its Register-HostIOProvider calls; the
# function bodies (Send-KeyHyperV / Send-KeyVNC / Send-KeyUTM /
# Send-KeyKvm / Send-TextHyperV / Send-TextVNC / Send-TextUTM /
# Send-TextKvm / Send-ClickHyperV / Send-ClickUtm) live in
# Test.Transport.psm1. The startup capability matrix reads
# Get-HostIOProviderMatrix so the operator sees which actions are
# wired on the current host before the cycle starts. See docs/host-io.md.

# ── Sequence action metadata registrations ──────────────────────────────────
# Failure-label scriptblock convention: $Context carries Step (parsed YAML
# step), Vars (variable scope), and ExpandVariable (live reference to
# Expand-Variable; we pass it in so the registry module does NOT have to
# import Invoke-Sequence). Each block reads $Context and returns the
# label string. Capability requirements (HostIORequirement + OcrRequired)
# are the same table Test.Capability used to carry.
#
# The catalog of built-in verb Handlers lives in
# Test.SequenceHandler.psm1, which is imported -Global at module load so
# its Register-SequenceAction side effects populate the same
# Test.SequenceAction registry the engine dispatches against. The two
# verbs below (retry, recoverFromSnapshot) stay in this module because
# their Handler bodies coordinate $script:LastFailure* state with the
# engine's foreach loop and recursive $invokeStepBlock; moving them out
# would require lifting that engine-private state into a shared module.

Register-SequenceAction -Name 'retry' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'retry_exhausted' -Severity 'hard' -SuggestedRecoveries @('restart_from_snapshot','pause_and_inspect') `
    -Description 'Wrap inner steps with restart-on-failure semantics.' `
    -FailureLabel { param($c)
        $null = $c
        # Use whatever the deepest inner step set on $script:LastFailureLabel
        # (the recursive call already wrapped or set it). Fallback to a
        # generic label when the inner never set one (empty steps block).
        if ($script:LastFailureLabel) { [string]$script:LastFailureLabel } else { 'retry: no inner failure label captured' }
    } `
    -Handler {
        param([hashtable]$c)
        # `retry` re-runs inner steps from the top on any failure.
        # Each attempt invokes $c.InvokeStepBlock recursively on the
        # inner `steps:` array; the first attempt that runs every
        # inner step cleanly wins. If all attempts fail, the deepest
        # inner failure label is wrapped with a "retry exhausted
        # (N attempts)" prefix so the operator sees both that retry
        # gave up AND which inner step ran out of patience.
        $maxAttempts = $c.Step.maxAttempts ? [int]$c.Step.maxAttempts : 3
        $innerSteps  = @($c.Step.steps)
        if ($innerSteps.Count -eq 0) {
            Write-Warning "    [$($c.StepNum)/$($c.StepCount)] retry block has no inner steps; treating as failure."
            $script:LastFailureLabel       = 'retry: empty steps block'
            $script:LastFailureDescription = $c.Description
            $script:LastFailedAction       = 'retry'
            $script:LastFailedStepNumber   = $c.StepNum
            return $false
        }
        $attemptOk = $false
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            # Refresh runner.stepHeartbeat per attempt. The engine
            # already refreshes at step boundaries (top of
            # $invokeStepBlock); a multi-attempt retry block runs as
            # a SINGLE step from the watchdog's perspective and would
            # blow past stepTimeoutMinutes without ever signalling
            # proof-of-life. Per-attempt refresh keeps the watchdog
            # aligned with reality.
            try {
                $stepHbFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'
                [System.IO.File]::WriteAllText($stepHbFile, [DateTime]::UtcNow.ToString('o'))
            } catch {
                Write-Verbose "runner.stepHeartbeat refresh (retry loop) failed: $($_.Exception.Message)"
            }
            Write-Information ("    [{0}/{1}] retry attempt {2}/{3}: {4}" -f $c.StepNum, $c.StepCount, $attempt, $maxAttempts, $c.Description)
            $attemptOk = & $c.InvokeStepBlock -Steps $innerSteps -ParentOrdinal $c.StepNum -ParentAction 'retry'
            if ($attemptOk) {
                Write-Information ("    [{0}/{1}] retry succeeded on attempt {2}/{3}" -f $c.StepNum, $c.StepCount, $attempt, $maxAttempts)
                break
            }
            if ($attempt -lt $maxAttempts) {
                Write-Warning ("    [{0}/{1}] retry attempt {2}/{3} failed; restarting from step 1 of {4}" -f $c.StepNum, $c.StepCount, $attempt, $maxAttempts, $innerSteps.Count)
                # Back off before the next attempt. Re-running instantly
                # burns all attempts in milliseconds and gives a transient
                # fault (network blip, a service still coming up) no time to
                # clear. Get-PollDelay is jittered + exponentially capped,
                # so it also breaks lock-step when many guests retry at
                # once. Refresh the heartbeat first so the watchdog stays
                # aligned across the wait (mirrors the per-attempt refresh
                # above).
                try {
                    $stepHbFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'
                    [System.IO.File]::WriteAllText($stepHbFile, [DateTime]::UtcNow.ToString('o'))
                } catch {
                    Write-Verbose "runner.stepHeartbeat refresh (retry backoff) failed: $($_.Exception.Message)"
                }
                Start-Sleep -Milliseconds (Get-PollDelay -Attempt $attempt)
            }
        }
        if (-not $attemptOk) {
            # Capture the deepest inner verb's classification BEFORE the
            # outer per-step block overwrites $script:LastFailedAction
            # with 'retry'. Without this, v2's failureClass collapses to
            # 'retry_exhausted' alone and a remediator can't distinguish
            # the inner cause (OCR timeout vs host_io_blocked vs ...).
            $innerVerbEntry = Get-SequenceAction -Name $script:LastFailedAction
            $script:LastInnerFailedAction        = [string]$script:LastFailedAction
            $script:LastInnerFailureClass        = if ($innerVerbEntry) { [string]$innerVerbEntry.FailureClass } else { 'unknown' }
            $script:LastInnerSeverity            = if ($innerVerbEntry) { [string]$innerVerbEntry.Severity }     else { 'unknown' }
            # [string[]] cast prevents the single-element unwrap so a
            # downstream consumer of $script:LastInnerSuggestedRecoveries
            # (innerSuggestedRecoveries field on step_failure NDJSON)
            # always sees a JSON array. Two-step assignment so an empty
            # SuggestedRecoveries does not collapse to $null via the
            # if-pipeline flatten.
            [string[]]$script:LastInnerSuggestedRecoveries = @()
            if ($innerVerbEntry -and $null -ne $innerVerbEntry.SuggestedRecoveries) {
                [string[]]$script:LastInnerSuggestedRecoveries = @($innerVerbEntry.SuggestedRecoveries)
            }
            $script:LastFailureLabel     = "retry exhausted ($maxAttempts attempts): $script:LastFailureLabel"
            $script:LastFailedStepNumber = $c.StepNum
            return $false
        }
        return $true
    }
# recoverFromSnapshot — declarative auto-recovery primitive.
# Fires AFTER a prior step's failure when $script:LastFailedAction is
# set and matches the trigger condition. Restores a known snapshot and
# starts the VM, leaving the sequence to continue with a clean guest.
Register-SequenceAction -Name 'recoverFromSnapshot' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'snapshot_restore_failed' -Severity 'soft' -SuggestedRecoveries @('abort_cycle') `
    -Description 'Auto-recovery: when the prior step failed, restore a snapshot and start the VM.' `
    -FailureLabel { param($c) "recoverFromSnapshot: `"$(& $c.ExpandVariable $c.Step.id $c.Vars)`"" } `
    -Handler {
        param([hashtable]$c)
        # No-op when the prior step succeeded -- this verb only fires on
        # failure of an earlier step in the same sequence. $script:Last-
        # FailedStepNumber is set by the engine's failure path.
        $priorFailed = ($null -ne $script:LastFailedStepNumber -and $script:LastFailedStepNumber -ne 0)
        if (-not $priorFailed) {
            Write-Debug "      recoverFromSnapshot: no prior failure; skipping."
            return $true
        }
        $snapId = & $c.ExpandVariable $c.Step.id $c.Vars
        if (-not $snapId) { Write-Warning "      recoverFromSnapshot: missing required 'id' field."; return $false }
        if (-not (Get-Command Restore-VMDiskSnapshot -ErrorAction SilentlyContinue) -or `
            -not (Get-Command Start-VM -ErrorAction SilentlyContinue)) {
            Write-Warning "      recoverFromSnapshot: Restore-VMDiskSnapshot or Start-VM not loaded; cannot recover."
            return $false
        }
        # Pre-validation: confirm the snapshot exists before any restore.
        # Restore-VMDiskSnapshot on a missing snapshot can leave the VM
        # in an ambiguous state on some hypervisors (Hyper-V silently
        # no-ops; KVM virsh returns non-zero late, AFTER it has stopped
        # the domain). Fail-loud here so the operator sees the missing
        # snapshot, not a stopped VM with no explanation.
        if (Get-Command Test-VMDiskSnapshot -ErrorAction SilentlyContinue) {
            $snapExists = $false
            try { $snapExists = [bool](Test-VMDiskSnapshot -VMName $c.VMName -Id $snapId) }
            catch {
                Write-Warning "      recoverFromSnapshot: Test-VMDiskSnapshot threw ($($_.Exception.Message)); proceeding with restore attempt."
                $snapExists = $true
            }
            if (-not $snapExists) {
                Write-Warning "      recoverFromSnapshot: snapshot '$snapId' not found on $($c.VMName); aborting restore. Manual intervention required."
                Send-CycleEventSafely -EventRecord @{
                    timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event        = 'snapshot_missing'
                    vmName       = [string]$c.VMName
                    snapshotId   = [string]$snapId
                    handler      = 'recoverFromSnapshot'
                    failureClass = 'snapshot_restore_failed'
                    severity     = 'hard'
                }
                return $false
            }
        }
        # Manifest identity check; same contract as loadDiskSnapshot.
        # Missing manifest is warn-only (older snapshots may not have
        # one); mismatch is a hard refuse.
        if (Get-Command Test-SnapshotManifestMatch -ErrorAction SilentlyContinue) {
            $check = Test-SnapshotManifestMatch -VMName $c.VMName -SnapshotId $snapId -HostType $c.HostType
            if ($check.Status -eq 'mismatch') {
                Write-Warning "      recoverFromSnapshot: manifest mismatch for '$snapId' on $($c.VMName); aborting restore. $($check.Violations -join '; ')"
                Send-CycleEventSafely -EventRecord @{
                    timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event        = 'snapshot_manifest_mismatch'
                    vmName       = [string]$c.VMName
                    snapshotId   = [string]$snapId
                    handler      = 'recoverFromSnapshot'
                    violations   = @($check.Violations)
                    failureClass = 'snapshot_restore_failed'
                    severity     = 'hard'
                }
                return $false
            } elseif ($check.Status -eq 'missing') {
                Write-Warning "      recoverFromSnapshot: no manifest for '$snapId' on $($c.VMName); proceeding (legacy snapshot)."
                Send-CycleEventSafely -EventRecord @{
                    timestamp  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event      = 'snapshot_manifest_missing'
                    vmName     = [string]$c.VMName
                    snapshotId = [string]$snapId
                    handler    = 'recoverFromSnapshot'
                }
            }
        }
        Write-Information "      recoverFromSnapshot: prior step $script:LastFailedStepNumber failed; restoring '$snapId' on $($c.VMName)."
        try { $restored = [bool](Restore-VMDiskSnapshot -VMName $c.VMName -Id $snapId -Confirm:$false) }
        catch { Write-Warning "      recoverFromSnapshot: $($_.Exception.Message)"; return $false }
        if (-not $restored) { return $false }
        try {
            $startRes = Start-VM -VMName $c.VMName -Confirm:$false
            if ($startRes -is [hashtable] -and -not $startRes.success) {
                Write-Warning "      recoverFromSnapshot: Start-VM returned failure: $($startRes.errorMessage)"
                return $false
            }
        } catch { Write-Warning "      recoverFromSnapshot: Start-VM threw: $($_.Exception.Message)"; return $false }
        # Clear the failed-step marker so downstream steps see a clean state.
        $script:LastFailedStepNumber = 0
        $script:LastFailureLabel     = $null
        $script:LastFailedAction     = $null
        return $true
    }

Export-ModuleMember -Function Invoke-Sequence, Invoke-SequenceByName, Resolve-SequencePath, Get-SequenceSearchPath, Get-SequenceMode, Get-SequenceModePath, Get-ProjectTestSearchDir, `
    Find-ProjectSequenceFile, Read-SequenceFile, Send-Text, Send-Key, Send-Click, `
    Wait-ForText, Invoke-TapOn, Save-DebugScreenshot, Write-ProgressTick, Get-PollDelay
