<#PSScriptInfo
.VERSION 2026.09.24
.GUID 428a8fea-36e6-48a4-aa62-2004e6035a54
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

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.OcrMatch.psm1') -Force -DisableNameChecking

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking
}

# Fixtures live at FILE scope, above the first Describe. A Describe body runs
# during discovery and its variables are discarded before any It executes, and
# the run pass stops descending top-level statements at the first Describe --
# so anything declared lower, or inside a Describe, reaches the assertions as
# $null. -TestCases data is read during discovery and must live here too.

# Each confusion group collapses to the lowercased FIRST character of the
# group. Test-OCRMatch pushes both the pattern and the OCR text through this
# map, so a group member standing in for another is invisible to the matcher.
$script:ConfusionCase = @(
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
$script:SavedOcrCombine = $env:YURUNA_OCR_COMBINE
$script:SavedOcrEngines = $env:YURUNA_OCR_ENGINES

# Characters normalization removes entirely. The em/en/figure dashes are given
# by code point so this file stays pure ASCII on disk.
$script:StrippedCase = @(
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
    It 'collapses each OCR confusion group onto one canonical character' -TestCases $script:ConfusionCase {
        param($Raw, $Canonical)
        Assert-Equal -Expected $Canonical -Actual (Get-OCRNormalized $Raw) -Because "'$Raw' must canonicalize to '$Canonical'"
    }
    It 'strips the characters OCR mangles on terminal fonts' -TestCases $script:StrippedCase {
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
        # All six characters of "login:" appear in order, but spread far wider
        # than the span guard allows -- it rejects the coincidence.
        $line = 'l x x x x o x x x x g x x x x i x x x x n x x x x :'
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text $line -Pattern 'login:')
    }
    # The span guard's budget is what separates a prompt from the prose that
    # introduces it. The forced-password-change notice a guest prints before
    # "New password:" carries every character of that pattern in order once the
    # confusion groups fold n->m and e->c, so nothing else in the matcher can
    # tell the two apart: the notice reaches the screen first, and a wait that
    # accepts it types the new secret into a terminal that is still echoing.
    It 'does NOT read the forced-change notice as the prompt that follows it' {
        $notice = 'You are required to change your password immediately (administrator enforced) .'
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text $notice -Pattern 'New password')
        # The same notice as an OCR engine renders it.
        $damaged = 'You are requ ired to change your password immediately (administrator enforced) .'
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text $damaged -Pattern 'New password')
    }
    It 'still matches the password prompt itself through OCR damage' {
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text 'New password :' -Pattern 'New password')
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text 'Neu password :' -Pattern 'New password')
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text 'New password: [' -Pattern 'New password')
    }
    It 'does NOT let a logged-in-user count satisfy a wait for the login prompt' {
        # The motd line spells l,o,g,i,n,: in order across nine positions.
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text 'Users logged in:' -Pattern 'login:')
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text 'yuhost26 login:' -Pattern 'login:')
    }
    It 'does NOT let a package-fetch error fire the firmware anti-pattern' {
        # A wrapped apt error spells g,m,w,g,r,w,b in order once u folds onto w
        # and n onto m. An anti-pattern that fires here ends a healthy run, so
        # the span guard is the only thing standing between the two.
        $aptFail = 'E: Failed to fetch http://security ubuntu .con/ubuntu/pool /nain/g/gec-13/g7Zb/2b-13-x86-64- 1 inux-gnu_13.3.0-Gubuntuz?e24.04.1_amd64.deb Unable to connect to 192.168.7.56:3128'
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text $aptFail -Pattern 'GNU GRUB')
    }
    It 'absorbs as many inserted characters as the threshold forgives missing ones' {
        # An 11-character pattern needs 10 of its characters, so it forgives one
        # omission -- and tolerates a comparable number of insertions, not the
        # pattern's whole length in them.
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text 'newpasswoxrd' -Pattern 'New password')
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text 'newpasXsYwoZrd' -Pattern 'New password')
    }
    It 'does NOT match unrelated console output' {
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text 'cloud-init v.24.1 running modules for final stage' -Pattern 'Password:')
    }

    # The shell-existence guard in the Linux sequences. Its whole job is to
    # tell a live session from the agetty prompt it was reached through, and
    # the two surfaces carry the same two tokens: a login line echoes the
    # username it was just given, right beside the hostname in /etc/issue.
    # Segment matching splits on "@" and asks only that each half appear
    # somewhere, so a user@host pattern cannot separate them and a guard
    # built on one passes at exactly the prompt it exists to reject.
    It 'segment matching cannot separate a shell prompt from the login line it followed' {
        $agetty = "Ubuntu 26.04 LTS yuhost26 tty1`n`nyuhost26 login: yuuser26"
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text $agetty -Pattern 'yuuser26@yuhost26')
    }
    # Anchoring the prompt on the colon a shell prints before its working
    # directory looks like it separates the two surfaces, and does for a
    # single-label hostname. It collapses for a dotted one: normalization
    # folds "." onto ":", so "host.domain" in the /etc/issue banner carries
    # the same token as "host:" in the prompt. Guests here are named after
    # their VM, which is dotted, so the prompt is not expressible.
    It 'the colon anchor separates the surfaces only for a single-label hostname' {
        $pattern = 'yuuser26@yuhost26:~'
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text 'yuhost26 login:' -Pattern $pattern)
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text 'yuhost26 login: yuuser26' -Pattern $pattern)
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text 'yuuser26@yuhost26:~$ ' -Pattern $pattern)
    }
    It 'a dotted hostname puts the prompt token in the issue banner, defeating the anchor' {
        $banner = "Ubuntu 26.04.1 LTS test-guest.ubuntu.server.26-01 tty1`ntest-guest login: yuuser26`nPassword:"
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text $banner -Pattern 'yuuser26@test-guest:~')
    }

    # What the sequences wait for instead. agetty echoes a typed line back
    # verbatim and can produce nothing else, so only a live shell puts the
    # expansion on screen. The token carries no character the matcher splits
    # on, so segment matching never runs and order stays enforced.
    It 'the echoed command is not mistaken for the token it would expand to' {
        $typed = "echo yuruna_`$(seq -s '' 1 9)_ok"
        $agetty = "Ubuntu 26.04.1 LTS test-guest.ubuntu.server.26-01 tty1`ntest-guest login: $typed`nPassword:"
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text $agetty -Pattern 'yuruna_123456789_ok')
    }
    It 'the expanded token matches, including through OCR damage to its digits' {
        $typed = "echo yuruna_`$(seq -s '' 1 9)_ok"
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text "yuuser26@test-guest:~`$ $typed`nyuruna_123456789_ok" -Pattern 'yuruna_123456789_ok')
        # 1 read as l, 5 as S: both are confusion-group members.
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text 'yuruna_l234S6789_ok' -Pattern 'yuruna_123456789_ok')
    }
    # The login anchor has the same shape of problem as the shell guard, in the
    # other direction: it is too specific rather than too loose. A guest named
    # after its VM answers at agetty with only the first label of that name,
    # and the full dotted name reaches the console solely in the /etc/issue
    # banner above the prompt -- so a pattern carrying it matches while the
    # banner is on screen and stops the moment it scrolls.
    It 'a dotted host name stops matching its own login prompt once the banner scrolls' {
        $fqdn = 'test-guest.ubuntu.server.26-01 login:'
        Assert-Equal -Expected $true  -Actual (Test-OCRMatch -Text "Ubuntu 26.04.1 LTS test-guest.ubuntu.server.26-01 tty1`ntest-guest login:" -Pattern $fqdn)
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text "[  OK  ] Started Login Service.`ntest-guest login:" -Pattern $fqdn)
    }
    It 'the host label matches the prompt with or without the banner' {
        $label = 'test-guest login:'
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text "Ubuntu 26.04.1 LTS test-guest.ubuntu.server.26-01 tty1`ntest-guest login:" -Pattern $label)
        Assert-Equal -Expected $true -Actual (Test-OCRMatch -Text "[  OK  ] Started Login Service.`ntest-guest login:" -Pattern $label)
    }
    It 'the host label still rejects the installer console the anchor exists to exclude' {
        # The property the whole anchor is for: the installer leaves its own
        # login prompt on screen seconds before the installed system exists,
        # and typing a username at that surface sends it nowhere.
        $label = 'test-guest login:'
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text "Ubuntu 26.04.1 LTS ubuntu-server ttyl`nubuntu-server login:" -Pattern $label)
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text 'ubuntu login:' -Pattern $label)
        Assert-Equal -Expected $false -Actual (Test-OCRMatch -Text "installing system`ncurtin command install" -Pattern $label)
    }

    It 'the token pattern has no character segment matching would split on' {
        $segments = @([regex]::Split('yuruna_123456789_ok', '[\s@\-\[\]$~"''`]+') | Where-Object { $_.Length -gt 0 })
        Assert-Equal -Expected 1 -Actual $segments.Count
    }
}

Describe 'Get-OcrCombineMode' {
    AfterAll {
        if ($null -eq $script:SavedOcrCombine) { Remove-Item Env:\YURUNA_OCR_COMBINE -ErrorAction SilentlyContinue }
        else { $env:YURUNA_OCR_COMBINE = $script:SavedOcrCombine }
    }
    It 'defaults to Or when the environment variable is unset or empty' {
        Remove-Item Env:\YURUNA_OCR_COMBINE -ErrorAction SilentlyContinue
        Assert-Equal -Expected 'Or' -Actual (Get-OcrCombineMode)
        $env:YURUNA_OCR_COMBINE = ''
        Assert-Equal -Expected 'Or' -Actual (Get-OcrCombineMode)
    }
    It 'honors an explicit And or Or, case-insensitively' {
        $env:YURUNA_OCR_COMBINE = 'And'
        Assert-Equal -Expected 'And' -Actual (Get-OcrCombineMode)
        $env:YURUNA_OCR_COMBINE = 'and'
        Assert-Equal -Expected 'And' -Actual (Get-OcrCombineMode)
        $env:YURUNA_OCR_COMBINE = 'Or'
        Assert-Equal -Expected 'Or' -Actual (Get-OcrCombineMode)
    }
    It 'throws on an unrecognized value instead of silently defaulting' {
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
        if ($null -eq $script:SavedOcrEngines) { Remove-Item Env:\YURUNA_OCR_ENGINES -ErrorAction SilentlyContinue }
        else { $env:YURUNA_OCR_ENGINES = $script:SavedOcrEngines }
        if ($null -eq $script:SavedOcrCombine) { Remove-Item Env:\YURUNA_OCR_COMBINE -ErrorAction SilentlyContinue }
        else { $env:YURUNA_OCR_COMBINE = $script:SavedOcrCombine }
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

Describe 'Get-OcrFreshWindowNearMiss' {

    # The freshMatch window is what stops an earlier step's marker satisfying
    # this one, so it cannot simply be widened -- but when it hides text the
    # engines DID read, the wait reports a plain timeout and an operator
    # comparing that against the captured frame sees the sought text sitting
    # right there. These assert the two cases stay distinguishable.
    It 'reports a pattern the engine read above the window, with the distance' {
        $lines = @('deployment.apps/website condition met', 'FETCHED AND EXECUTED:', 'project/example/website/x.sh')
        $lines += (1..20 | ForEach-Object { "trailing repaint line $_" })
        $er = [ordered]@{ winrt = @{ Text = ($lines -join "`n"); Matched = $false; MatchedPattern = $null } }
        $hits = @(Get-OcrFreshWindowNearMiss -EngineResult $er -Pattern @('FETCHED AND EXECUTED:') -FreshMatchTailLines 12)
        Assert-Equal -Expected 1 -Actual $hits.Count -Because 'the marker was read but sat above the window'
        Assert-True ($hits[0] -match 'winrt')
        # 23 lines total, window starts at index 11, marker at index 1 -> 10 above.
        Assert-True ($hits[0] -match '10 line\(s\) above') -Because "distance should be reported; got: $($hits[0])"
    }

    It 'reports nothing when the pattern was never on screen' {
        $er = [ordered]@{ winrt = @{ Text = ((1..40 | ForEach-Object { "unrelated line $_" }) -join "`n"); Matched = $false } }
        $hits = @(Get-OcrFreshWindowNearMiss -EngineResult $er -Pattern @('FETCHED AND EXECUTED:') -FreshMatchTailLines 12)
        Assert-Equal -Expected 0 -Actual $hits.Count -Because 'a genuine timeout must not be reported as a near miss'
    }

    It 'reports nothing when the window already covered the whole frame' {
        $er = [ordered]@{ winrt = @{ Text = "FETCHED AND EXECUTED:`nsecond line"; Matched = $false } }
        $hits = @(Get-OcrFreshWindowNearMiss -EngineResult $er -Pattern @('FETCHED AND EXECUTED:') -FreshMatchTailLines 12)
        Assert-Equal -Expected 0 -Actual $hits.Count -Because 'the window cannot have hidden text it fully covered'
    }

    It 'reports nothing when no window was in force' {
        $er = [ordered]@{ winrt = @{ Text = (@('FETCHED AND EXECUTED:') + (1..30 | ForEach-Object { "noise $_" })) -join "`n"; Matched = $false } }
        $hits = @(Get-OcrFreshWindowNearMiss -EngineResult $er -Pattern @('FETCHED AND EXECUTED:') -FreshMatchTailLines 0)
        Assert-Equal -Expected 0 -Actual $hits.Count -Because 'with no window there is no window to blame'
    }

    It 'skips an engine that matched' {
        $er = [ordered]@{ winrt = @{ Text = (@('FETCHED AND EXECUTED:') + (1..30 | ForEach-Object { "noise $_" })) -join "`n"; Matched = $true } }
        $hits = @(Get-OcrFreshWindowNearMiss -EngineResult $er -Pattern @('FETCHED AND EXECUTED:') -FreshMatchTailLines 12)
        Assert-Equal -Expected 0 -Actual $hits.Count
    }

    It 'tolerates a null engine map' {
        $hits = @(Get-OcrFreshWindowNearMiss -EngineResult $null -Pattern @('x') -FreshMatchTailLines 12)
        Assert-Equal -Expected 0 -Actual $hits.Count
    }
}
