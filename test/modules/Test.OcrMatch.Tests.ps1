<#PSScriptInfo
.VERSION 2026.07.21
.GUID 422b807c-2e2b-4e23-822e-cc26747b834d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test ocr match pester
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
    Pester coverage for Test.OcrMatch.psm1: OCR normalization (confusion
    groups, stripped characters), the three matching strategies of
    Test-OCRMatch and its 85% threshold / span guard, the combine-mode
    selector, and the multi-engine combiner Test-CombinedOcrMatch.
.DESCRIPTION
    This module decides whether a waitForText step passes or fails, so the
    tests care about both directions: what MUST match (OCR damage the engine
    is required to absorb) and what MUST NOT (a pattern that normalizes to
    nothing, a scattered coincidental hit, a screen from the wrong guest).

    Throw-based assertions rather than Should, so the file also runs under
    the OS-bundled Pester 3.4.
    Run: pwsh -NoProfile -File test/modules/Test.OcrMatch.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.OcrMatch.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

# Fixtures live at FILE scope, above the first Describe. A Describe body runs
# during discovery and its variables are discarded before any It executes, and
# the run pass stops descending top-level statements at the first Describe --
# so anything declared lower, or inside a Describe, reaches the assertions as
# $null. -TestCases data is read during discovery and must live here too.

# Each confusion group collapses to the lowercased FIRST character of the
# group. Test-OCRMatch pushes both the pattern and the OCR text through this
# map, so a group member standing in for another is invisible to the matcher.
$ConfusionCase = @(
    @{ Raw = 'w'; Canonical = 'w' }, @{ Raw = 'u'; Canonical = 'w' }, @{ Raw = 'V'; Canonical = 'w' }
    @{ Raw = 'm'; Canonical = 'm' }, @{ Raw = 'N'; Canonical = 'm' }
    @{ Raw = 'o'; Canonical = 'o' }, @{ Raw = 'O'; Canonical = 'o' }, @{ Raw = '0'; Canonical = 'o' }, @{ Raw = '@'; Canonical = 'o' }
    @{ Raw = 'l'; Canonical = 'l' }, @{ Raw = 'I'; Canonical = 'l' }, @{ Raw = '1'; Canonical = 'l' }, @{ Raw = 'i'; Canonical = 'l' }
    @{ Raw = 'S'; Canonical = 's' }, @{ Raw = '5'; Canonical = 's' }
    @{ Raw = 'B'; Canonical = 'b' }, @{ Raw = '8'; Canonical = 'b' }
    @{ Raw = 'Z'; Canonical = 'z' }, @{ Raw = '2'; Canonical = 'z' }
    @{ Raw = 'g'; Canonical = 'g' }, @{ Raw = 'q'; Canonical = 'g' }, @{ Raw = '9'; Canonical = 'g' }
    @{ Raw = 'c'; Canonical = 'c' }, @{ Raw = 'e'; Canonical = 'c' }
    @{ Raw = ':'; Canonical = ':' }, @{ Raw = ';'; Canonical = ':' }, @{ Raw = '.'; Canonical = ':' }
)

# Snapshot the OCR environment once, at file scope, so each AfterAll can put it
# back. The suites below drive Get-OcrCombineMode and Get-EnabledOcrProvider
# through these two variables, and a leaked value would follow the process into
# any other suite sharing the run.
$SavedOcrCombine = $env:YURUNA_OCR_COMBINE
$SavedOcrEngines = $env:YURUNA_OCR_ENGINES

# Characters normalization removes entirely. The em/en/figure dashes are given
# by code point so this file stays pure ASCII on disk.
$StrippedCase = @(
    @{ Name = 'space';        Char = ' ' }
    @{ Name = 'hyphen';       Char = '-' }
    @{ Name = 'em dash';      Char = [string][char]0x2014 }
    @{ Name = 'en dash';      Char = [string][char]0x2013 }
    @{ Name = 'figure dash';  Char = [string][char]0x2012 }
    @{ Name = 'open bracket'; Char = '[' }
    @{ Name = 'close bracket'; Char = ']' }
    @{ Name = 'dollar';       Char = '$' }
    @{ Name = 'tilde';        Char = '~' }
    @{ Name = 'double quote'; Char = '"' }
    @{ Name = 'backtick';     Char = '`' }
)

Describe 'Get-OCRNormalized' {
    It 'lowercases and drops spaces' {
        Assert-Equal -Expected 'lmstall' -Actual (Get-OCRNormalized 'I n s t a l l')
    }
    It 'collapses each OCR confusion group onto one canonical character' -TestCases $ConfusionCase {
        param($Raw, $Canonical)
        Assert-Equal -Expected $Canonical -Actual (Get-OCRNormalized $Raw) -Because "'$Raw' must canonicalize to '$Canonical'"
    }
    It 'strips the characters OCR mangles on terminal fonts' -TestCases $StrippedCase {
        param($Name, $Char)
        Assert-Equal -Expected 'xy' -Actual (Get-OCRNormalized "x$($Char)y") -Because "$Name must be stripped, not substituted"
    }
    It 'maps the dotless i Vision OCR emits onto l' {
        # U+0131 by code point: the file itself stays ASCII.
        Assert-Equal -Expected 'l' -Actual (Get-OCRNormalized ([string][char]0x0131))
    }
    It 'normalizes an OCR misread to the same string as the pattern it damaged' {
        # The whole point of the map: a search for "Install" against "lnstall".
        Assert-Equal -Expected (Get-OCRNormalized 'Install') -Actual (Get-OCRNormalized 'lnstall')
        Assert-Equal -Expected (Get-OCRNormalized 'test-ubuntu-server-01') -Actual (Get-OCRNormalized 'test-ubuntu-server-@1')
    }
    It 'returns empty for a string made only of stripped characters' {
        Assert-Equal -Expected '' -Actual (Get-OCRNormalized ']$')
        Assert-Equal -Expected '' -Actual (Get-OCRNormalized '   ')
    }
    It 'keeps distinct guests distinct' {
        # Normalization is lossy on purpose, but not so lossy that two
        # different guests collide -- that would pass a step on the wrong VM.
        Assert-True ((Get-OCRNormalized 'test-ubuntu-server-01') -ne (Get-OCRNormalized 'test-amazon-linux01'))
    }
}

Describe 'Test-OCRMatch' {
    It 'matches clean text and ignores case plus spurious spaces' {
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text 'test-ubuntu-server-01 login:' -Pattern 'login:')
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text 'L O G I N :' -Pattern 'login:')
    }
    It 'absorbs a confusion-group substitution in the OCR text' {
        # '@' read for '0' is the documented console-font failure.
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text 'test-ubuntu-server-@1 login:' -Pattern 'test-ubuntu-server-01')
    }
    It 'absorbs a dropped leading character (subsequence strategy)' {
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text 'assuord:' -Pattern 'Password:')
    }
    It 'absorbs punctuation confusion (colon read as period)' {
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text 'rassword.' -Pattern 'Password:')
    }
    It 'absorbs an arbitrary substitution not covered by any group (sliding window)' {
        # 'e' -> 'x' is not a confusion group; the positional strategy carries
        # it because 6 of 7 normalized characters still line up (>= 85%).
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text 'wxlcome' -Pattern 'welcome')
    }
    It 'rejects text once the damage exceeds the 85% threshold' {
        # Two substitutions in a 7-character pattern is 5/7 = 71%.
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text 'wxlxome' -Pattern 'welcome')
    }
    It 'finds the pattern on any line of multi-line OCR text' {
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text "cloud-init finished`ntest-guest login:" -Pattern 'login:')
    }
    It 'matches a reordered prompt by segment (strategy 3)' {
        # OCR splits and reorders the prompt; every segment still appears
        # somewhere in the full normalized text.
        $ocr = 'test-amazon-I inux01 login: ecZ-user'
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text $ocr -Pattern '[ec2-user@test-amazon-linux01 ~]$')
    }
    It 'does NOT match a pattern that normalizes to nothing' {
        # A pattern of pure prompt punctuation normalizes to '' and would
        # otherwise "match" any text at all -- including a blank or degraded
        # screen, silently passing the wait condition.
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text 'test-guest login:' -Pattern ']$')
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text 'test-guest login:' -Pattern '   ')
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text 'test-guest login:' -Pattern '')
    }
    It 'does NOT match against empty OCR text' {
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text '' -Pattern 'login:')
    }
    It 'does NOT match the wrong guest' {
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text 'test-amazon-linux01 login:' -Pattern 'test-ubuntu-server-01')
    }
    It 'does NOT match pattern characters scattered across a long line' {
        # All six characters of "login:" appear in order, but spread over more
        # than 2x the pattern length -- the span guard rejects the coincidence.
        $line = 'l x x x x o x x x x g x x x x i x x x x n x x x x :'
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text $line -Pattern 'login:')
    }
    It 'does NOT match unrelated console output' {
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text 'cloud-init v.24.1 running modules for final stage' -Pattern 'Password:')
    }
}

Describe 'Get-OcrCombineMode' {
    AfterAll {
        if ($null -eq $SavedOcrCombine) { Remove-Item Env:\YURUNA_OCR_COMBINE -ErrorAction SilentlyContinue }
        else { $env:YURUNA_OCR_COMBINE = $SavedOcrCombine }
    }
    It 'defaults to Or when the environment variable is unset or empty' {
        Remove-Item Env:\YURUNA_OCR_COMBINE -ErrorAction SilentlyContinue
        Assert-Equal -Expected 'Or' -Actual (Get-OcrCombineMode)
        $env:YURUNA_OCR_COMBINE = ''
        Assert-Equal -Expected 'Or' -Actual (Get-OcrCombineMode)
    }
    It 'honours an explicit And or Or, case-insensitively' {
        $env:YURUNA_OCR_COMBINE = 'And'
        Assert-Equal -Expected 'And' -Actual (Get-OcrCombineMode)
        $env:YURUNA_OCR_COMBINE = 'and'
        Assert-Equal -Expected 'And' -Actual (Get-OcrCombineMode)
        $env:YURUNA_OCR_COMBINE = 'Or'
        Assert-Equal -Expected 'Or' -Actual (Get-OcrCombineMode)
    }
    It 'throws on an unrecognised value instead of silently defaulting' {
        # A typo that fell back to the default would flip every waitForText in
        # the cycle to the other combine mode with no signal.
        $env:YURUNA_OCR_COMBINE = 'Xor'
        $threw = $false
        try { $null = Get-OcrCombineMode } catch { $threw = $true }
        Assert-True $threw 'an invalid combine mode must be rejected loudly'
    }
}

Describe 'Test-CombinedOcrMatch' {
    BeforeAll {
        # Two fake engines whose text is driven by environment variables: the
        # provider scriptblocks run inside Test.OcrEngine's module scope, and
        # the process environment is the one channel readable from there and
        # from an It body alike.
        Register-OcrProvider -Name 'unit-fake-a' -Invoke {
            param([string]$ImagePath)
            $null = $ImagePath
            $env:YURUNA_TEST_OCR_CALLS = "$($env:YURUNA_TEST_OCR_CALLS),unit-fake-a".Trim(',')
            if ($env:YURUNA_TEST_OCR_A -eq '__throw__') { throw 'unit-fake-a: simulated engine failure' }
            $env:YURUNA_TEST_OCR_A
        } -IsAvailable { $true }

        Register-OcrProvider -Name 'unit-fake-b' -Invoke {
            param([string]$ImagePath)
            $null = $ImagePath
            $env:YURUNA_TEST_OCR_CALLS = "$($env:YURUNA_TEST_OCR_CALLS),unit-fake-b".Trim(',')
            if ($env:YURUNA_TEST_OCR_B -eq '__throw__') { throw 'unit-fake-b: simulated engine failure' }
            $env:YURUNA_TEST_OCR_B
        } -IsAvailable { $true }

        $env:YURUNA_OCR_ENGINES = 'unit-fake-a,unit-fake-b'
        $env:YURUNA_TEST_OCR_A = 'alpha engine sees the login prompt'
        $env:YURUNA_TEST_OCR_B = 'beta engine sees a password prompt'
        Clear-EnabledOcrProviderCache
    }
    AfterAll {
        if ($null -eq $SavedOcrEngines) { Remove-Item Env:\YURUNA_OCR_ENGINES -ErrorAction SilentlyContinue }
        else { $env:YURUNA_OCR_ENGINES = $SavedOcrEngines }
        if ($null -eq $SavedOcrCombine) { Remove-Item Env:\YURUNA_OCR_COMBINE -ErrorAction SilentlyContinue }
        else { $env:YURUNA_OCR_COMBINE = $SavedOcrCombine }
        Remove-Item Env:\YURUNA_TEST_OCR_A, Env:\YURUNA_TEST_OCR_B, Env:\YURUNA_TEST_OCR_CALLS -ErrorAction SilentlyContinue
        Clear-EnabledOcrProviderCache
    }
    BeforeEach {
        $env:YURUNA_OCR_ENGINES = 'unit-fake-a,unit-fake-b'
        $env:YURUNA_TEST_OCR_A = 'alpha engine sees the login prompt'
        $env:YURUNA_TEST_OCR_B = 'beta engine sees a password prompt'
        $env:YURUNA_TEST_OCR_CALLS = ''
        Clear-EnabledOcrProviderCache
    }

    It 'Or mode short-circuits: a first-engine hit never runs the second engine' {
        $env:YURUNA_OCR_COMBINE = 'Or'
        $r = Test-CombinedOcrMatch -ImagePath 'unused.png' -Pattern 'login prompt'
        Assert-Equal -Expected $true -Actual $r.Match
        Assert-Equal -Expected 'unit-fake-a' -Actual $env:YURUNA_TEST_OCR_CALLS -Because 'the second engine is wasted work once the first matched'
        Assert-Equal -Expected 1 -Actual @($r.EngineResults.Keys).Count
        Assert-Equal -Expected 'login prompt' -Actual $r.EngineResults['unit-fake-a'].MatchedPattern
    }
    It 'Or mode falls through to a later engine when the first one misses' {
        $env:YURUNA_OCR_COMBINE = 'Or'
        $r = Test-CombinedOcrMatch -ImagePath 'unused.png' -Pattern 'password prompt'
        Assert-Equal -Expected $true -Actual $r.Match
        Assert-Equal -Expected 'unit-fake-a,unit-fake-b' -Actual $env:YURUNA_TEST_OCR_CALLS
        Assert-Equal -Expected $false -Actual $r.EngineResults['unit-fake-a'].Matched
        Assert-Equal -Expected $true -Actual $r.EngineResults['unit-fake-b'].Matched
    }
    It 'Or mode returns false only after every engine has missed' {
        $env:YURUNA_OCR_COMBINE = 'Or'
        $r = Test-CombinedOcrMatch -ImagePath 'unused.png' -Pattern 'kernel panic'
        Assert-Equal -Expected $false -Actual $r.Match
        Assert-Equal -Expected 'unit-fake-a,unit-fake-b' -Actual $env:YURUNA_TEST_OCR_CALLS
    }
    It 'accepts several patterns and matches on any one of them' {
        $env:YURUNA_OCR_COMBINE = 'Or'
        $r = Test-CombinedOcrMatch -ImagePath 'unused.png' -Pattern @('kernel panic', 'login prompt')
        Assert-Equal -Expected $true -Actual $r.Match
        Assert-Equal -Expected 'login prompt' -Actual $r.EngineResults['unit-fake-a'].MatchedPattern
    }
    It 'And mode requires every engine to see the pattern' {
        $env:YURUNA_OCR_COMBINE = 'And'
        $r = Test-CombinedOcrMatch -ImagePath 'unused.png' -Pattern 'engine sees'
        Assert-Equal -Expected $true -Actual $r.Match
        Assert-Equal -Expected 'unit-fake-a,unit-fake-b' -Actual $env:YURUNA_TEST_OCR_CALLS
    }
    It 'And mode fails when only one engine sees the pattern' {
        $env:YURUNA_OCR_COMBINE = 'And'
        $r = Test-CombinedOcrMatch -ImagePath 'unused.png' -Pattern 'login prompt'
        Assert-Equal -Expected $false -Actual $r.Match
    }
    It 'And mode short-circuits on the first engine that misses' {
        $env:YURUNA_OCR_COMBINE = 'And'
        $r = Test-CombinedOcrMatch -ImagePath 'unused.png' -Pattern 'password prompt'
        Assert-Equal -Expected $false -Actual $r.Match
        Assert-Equal -Expected 'unit-fake-a' -Actual $env:YURUNA_TEST_OCR_CALLS -Because 'And can never recover once one engine has missed'
    }
    It 'survives an engine that throws and lets the healthy engine decide' {
        $env:YURUNA_OCR_COMBINE = 'Or'
        $env:YURUNA_TEST_OCR_A = '__throw__'
        $r = Test-CombinedOcrMatch -ImagePath 'unused.png' -Pattern 'password prompt' -WarningAction SilentlyContinue
        Assert-Equal -Expected $true -Actual $r.Match -Because 'a crashed engine must not veto a healthy one'
        Assert-Equal -Expected '' -Actual $r.EngineResults['unit-fake-a'].Text
        Assert-Equal -Expected $false -Actual $r.EngineResults['unit-fake-a'].Matched
        Assert-Equal -Expected 'beta engine sees a password prompt' -Actual $r.AnyText -Because 'the dead engine contributes no text'
    }
    It 'concatenates the text of every engine it ran into AnyText' {
        $env:YURUNA_OCR_COMBINE = 'Or'
        $r = Test-CombinedOcrMatch -ImagePath 'unused.png' -Pattern 'kernel panic'
        $expected = "alpha engine sees the login prompt`nbeta engine sees a password prompt"
        Assert-Equal -Expected $expected -Actual $r.AnyText
    }
    It 'FreshMatchTailLines restricts matching to the last N lines only' {
        $env:YURUNA_OCR_COMBINE = 'Or'
        $env:YURUNA_OCR_ENGINES = 'unit-fake-a'
        $env:YURUNA_TEST_OCR_A = "stale login prompt`nboot line two`nboot line three"
        Clear-EnabledOcrProviderCache

        # The stale hit lives above the tail window: it must NOT satisfy a
        # freshMatch wait, or the step passes on a screen from a prior boot.
        $stale = Test-CombinedOcrMatch -ImagePath 'unused.png' -Pattern 'stale login prompt' -FreshMatchTailLines 2
        Assert-Equal -Expected $false -Actual $stale.Match
        # The full engine text is still reported for accumulation.
        Assert-True ($stale.EngineResults['unit-fake-a'].Text -match 'stale login prompt')

        $fresh = Test-CombinedOcrMatch -ImagePath 'unused.png' -Pattern 'boot line three' -FreshMatchTailLines 2
        Assert-Equal -Expected $true -Actual $fresh.Match

        # Tail 0 means "test everything", so the same stale line matches again.
        $all = Test-CombinedOcrMatch -ImagePath 'unused.png' -Pattern 'stale login prompt' -FreshMatchTailLines 0
        Assert-Equal -Expected $true -Actual $all.Match
    }
    It 'reports no match when no OCR engine is available at all' {
        # A degraded host with zero usable engines must fail the wait, never
        # auto-pass it.
        $env:YURUNA_OCR_ENGINES = 'no-such-engine'
        Clear-EnabledOcrProviderCache
        $r = Test-CombinedOcrMatch -ImagePath 'unused.png' -Pattern 'login prompt' -WarningAction SilentlyContinue
        Assert-Equal -Expected $false -Actual $r.Match
        Assert-Equal -Expected 0 -Actual @($r.EngineResults.Keys).Count
        Assert-Equal -Expected '' -Actual $r.AnyText
    }
}
