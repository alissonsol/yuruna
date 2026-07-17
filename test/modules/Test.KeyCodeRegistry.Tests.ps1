<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42d110f4-a5b7-43bd-88dd-122b508a6eb4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test keycode keyboard transport pester
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
    Pester coverage for Test.KeyCodeRegistry.psm1: the Get-KeyCodeMap /
    Get-KeyCodeMapKind accessors and the cross-transport invariants the
    five key-code tables have to hold for Send-Key / Send-Text to type the
    same string on every backend.
.DESCRIPTION
    The tables are data, so the tests assert the properties a typo would
    break: the by-reference accessor contract Test.Transport's $script:*
    aliases depend on, case-sensitivity of the char maps, PS/2 make codes
    staying inside the range where `make -bor 0x80` is a valid break code,
    X11 keysyms equalling the ASCII code point, an identical covered
    character set across UTM / PS2 / X11, and the documented keypad
    exception for UTM '*' and '+'.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.KeyCodeRegistry.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.KeyCodeRegistry.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# Fixtures live at FILE scope, above the first Describe: a Describe body runs
# during discovery and its variables are thrown away before any It executes.
$allKinds     = @('UTM-Named','UTM-Char','PS2-Named','PS2-Char','X11-Named','X11-Char','KVM-Named','KVM-Char')
$charKinds    = @('UTM-Char','PS2-Char','X11-Char','KVM-Char')
$namedKinds   = @('UTM-Named','PS2-Named','X11-Named','KVM-Named')
$codeCharKind = @('UTM-Char','PS2-Char','X11-Char')   # entries are [code, needsShift]

# Key names every transport has to understand: the harness sequences use them
# on all four backends, so a name missing from one map is a step that types
# nothing on that host.
$universalKeyName = @('Enter','Tab','Space','Escape','Up','Down','Left','Right')

function Get-CoveredChar {
    <#
    .SYNOPSIS
        Sorted character set of a -Char map, as a single joined string
        so two maps can be compared with one -eq.
    #>
    [CmdletBinding()] [OutputType([string])] param([Parameter(Mandatory)][string]$Kind)
    $map = Get-KeyCodeMap -Kind $Kind
    return ((@([string[]]$map.Keys) | Sort-Object -CaseSensitive) -join '')
}

Describe 'Get-KeyCodeMapKind / Get-KeyCodeMap' {
    It 'enumerates every registered transport map' {
        $kinds = @(Get-KeyCodeMapKind)
        Assert-Equal -Expected 8 -Actual $kinds.Count
        foreach ($k in $allKinds) {
            Assert-True ($kinds -contains $k) "Get-KeyCodeMapKind must advertise '$k'"
        }
    }
    It 'resolves every advertised kind to a populated map' -TestCases @(
        @{ kind = 'UTM-Named' }, @{ kind = 'UTM-Char' }, @{ kind = 'PS2-Named' }, @{ kind = 'PS2-Char' }
        @{ kind = 'X11-Named' }, @{ kind = 'X11-Char' }, @{ kind = 'KVM-Named' }, @{ kind = 'KVM-Char' }
    ) {
        param($kind)
        $map = Get-KeyCodeMap -Kind $kind
        Assert-True ($null -ne $map) "no map returned for '$kind'"
        Assert-True ($map.Count -gt 0) "map '$kind' is empty"
    }
    It 'hands back the same instance every call, not a copy' {
        # Test.Transport caches $script:PS2ScanCodes = Get-KeyCodeMap -Kind 'PS2-Named'
        # at import and reads that alias for the rest of the process. A copying
        # accessor would silently detach those aliases from the registry.
        Assert-Equal -Expected 8 -Actual @($allKinds).Count
        foreach ($k in $allKinds) {
            $a = Get-KeyCodeMap -Kind $k
            $b = Get-KeyCodeMap -Kind $k
            Assert-True ([object]::ReferenceEquals($a, $b)) "'$k' must be returned by reference"
        }
    }
    It 'rejects a transport kind it does not own' {
        Assert-True ($null -ne (Get-KeyCodeMap -Kind 'PS2-Char')) 'precondition: a valid kind resolves'
        $err = $null
        try { $null = Get-KeyCodeMap -Kind 'ProxMox-Char' } catch { $err = $_ }
        Assert-True ($null -ne $err) 'an unregistered kind must not fall through as $null'
        Assert-True ($err.CategoryInfo.Category -eq 'InvalidData' -or $err.Exception -is [System.Management.Automation.ParameterBindingException]) `
            'the rejection must come from the ValidateSet, not from a missing command'
    }
}

Describe 'Char maps are case-sensitive' {
    # A PowerShell @{} literal folds 'a' and 'A'; these maps must not, or every
    # capital letter types as its lowercase twin.
    It 'keeps a distinct entry for each letter case' -TestCases @(
        @{ kind = 'UTM-Char' }, @{ kind = 'PS2-Char' }, @{ kind = 'X11-Char' }, @{ kind = 'KVM-Char' }
    ) {
        param($kind)
        $map = Get-KeyCodeMap -Kind $kind
        foreach ($pair in @(@('a','A'), @('m','M'), @('z','Z'))) {
            Assert-True ($map.ContainsKey($pair[0])) "'$kind' lost '$($pair[0])'"
            Assert-True ($map.ContainsKey($pair[1])) "'$kind' lost '$($pair[1])'"
            $lower = $map[$pair[0]]
            $upper = $map[$pair[1]]
            Assert-True (($lower -join ',') -ne ($upper -join ',')) `
                "'$kind' maps '$($pair[0])' and '$($pair[1])' to the same chord -- the table folded case"
        }
    }
    It 'encodes an upper-case letter as the same physical key plus Shift' -TestCases @(
        @{ kind = 'UTM-Char' }, @{ kind = 'PS2-Char' }
    ) {
        param($kind)
        $map = Get-KeyCodeMap -Kind $kind
        foreach ($ch in 'a'..'z') {
            $lower = [string]$ch
            $upper = $lower.ToUpperInvariant()
            Assert-Equal -Expected $map[$lower][0] -Actual $map[$upper][0] -Because "'$kind': '$upper' must reuse the '$lower' key code"
            Assert-Equal -Expected $false -Actual $map[$lower][1] -Because "'$kind': '$lower' must not need Shift"
            Assert-Equal -Expected $true  -Actual $map[$upper][1] -Because "'$kind': '$upper' must need Shift"
        }
    }
    It 'encodes an upper-case letter as a LEFTSHIFT chord on the KVM transport' {
        $map = Get-KeyCodeMap -Kind 'KVM-Char'
        Assert-Equal -Expected 'KEY_A'                 -Actual (@($map['a']) -join '+')
        Assert-Equal -Expected 'KEY_LEFTSHIFT+KEY_A'   -Actual (@($map['A']) -join '+')
        Assert-Equal -Expected 'KEY_LEFTSHIFT+KEY_1'   -Actual (@($map['!']) -join '+')
        Assert-Equal -Expected 'KEY_SLASH'             -Actual (@($map['/']) -join '+')
    }
}

Describe 'Per-transport code invariants' {
    It 'keeps every PS/2 code inside the make-code range so `make -bor 0x80` is the break code' {
        # Test.Transport sends the break code as ($make -bor 0x80). A make code
        # with bit 7 already set would collide with the release event of a
        # different key, so the key would never register as pressed.
        foreach ($kind in @('PS2-Named','PS2-Char')) {
            $map = Get-KeyCodeMap -Kind $kind
            foreach ($key in @([string[]]$map.Keys)) {
                $code = if ($kind -eq 'PS2-Named') { $map[$key] } else { $map[$key][0] }
                Assert-True ($code -ge 0x01 -and $code -le 0x7F) `
                    "'$kind' code for '$key' is 0x$('{0:X2}' -f [int]$code); outside 0x01..0x7F the break code aliases another key"
            }
        }
    }
    It 'pins the PS/2 Set 1 top row against the hardware spec' {
        $map = Get-KeyCodeMap -Kind 'PS2-Char'
        $expected = [ordered]@{ q = 0x10; w = 0x11; e = 0x12; r = 0x13; t = 0x14; y = 0x15 }
        foreach ($c in $expected.Keys) {
            Assert-Equal -Expected $expected[$c] -Actual $map[$c][0] -Because "PS/2 Set 1 scan code for '$c'"
        }
        Assert-Equal -Expected 0x1C -Actual (Get-KeyCodeMap -Kind 'PS2-Named')['Enter']
        Assert-Equal -Expected 0x0E -Actual (Get-KeyCodeMap -Kind 'PS2-Named')['Backspace']
    }
    It 'uses the ASCII code point as the X11 keysym for every printable char' {
        # Documented invariant: "the keysym IS the Unicode/ASCII code point for
        # standard ASCII". A hand-typed table entry that drifts from the code
        # point types a different character over VNC.
        $map = Get-KeyCodeMap -Kind 'X11-Char'
        foreach ($key in @([string[]]$map.Keys)) {
            Assert-Equal -Expected ([int][char]$key) -Actual $map[$key][0] -Because "X11 keysym for '$key'"
        }
        Assert-Equal -Expected 0xFF0D -Actual (Get-KeyCodeMap -Kind 'X11-Named')['Enter'] -Because 'XK_Return'
        Assert-Equal -Expected 0xFF1B -Actual (Get-KeyCodeMap -Kind 'X11-Named')['Escape'] -Because 'XK_Escape'
    }
    It 'pins the UTM virtual key codes against the macOS kVK_ANSI_* spec' {
        $named = Get-KeyCodeMap -Kind 'UTM-Named'
        Assert-Equal -Expected 36 -Actual $named['Enter']  -Because 'kVK_Return'
        Assert-Equal -Expected 53 -Actual $named['Escape'] -Because 'kVK_Escape'
        $char = Get-KeyCodeMap -Kind 'UTM-Char'
        Assert-Equal -Expected 0 -Actual $char['a'][0] -Because 'kVK_ANSI_A'
        Assert-Equal -Expected 1 -Actual $char['s'][0] -Because 'kVK_ANSI_S'
    }
    It 'types UTM * and + off the numeric keypad, without Shift' {
        # Documented exception: '*' and '+' use kVK_ANSI_KeypadMultiply (67) /
        # kVK_ANSI_KeypadPlus (69), so unlike every other shifted symbol they
        # must NOT ask for Shift. Holding Shift over a keypad code types
        # something else entirely.
        $map = Get-KeyCodeMap -Kind 'UTM-Char'
        Assert-Equal -Expected 67    -Actual $map['*'][0]
        Assert-Equal -Expected $false -Actual $map['*'][1]
        Assert-Equal -Expected 69    -Actual $map['+'][0]
        Assert-Equal -Expected $false -Actual $map['+'][1]
    }
    It 'shares the digit key between a digit and its shifted symbol' {
        # Everywhere except the two UTM keypad codes above, a shifted symbol is
        # the unshifted key plus Shift. PS/2 has no keypad exception at all.
        $ps2 = Get-KeyCodeMap -Kind 'PS2-Char'
        $pairs = @{ '!' = '1'; '@' = '2'; '#' = '3'; '$' = '4'; '%' = '5'; '^' = '6'; '&' = '7'; '*' = '8'; '(' = '9'; ')' = '0' }
        foreach ($sym in $pairs.Keys) {
            Assert-Equal -Expected $ps2[$pairs[$sym]][0] -Actual $ps2[$sym][0] -Because "PS/2: '$sym' is Shift + '$($pairs[$sym])'"
            Assert-Equal -Expected $true -Actual $ps2[$sym][1] -Because "PS/2: '$sym' needs Shift"
        }
        $utm = Get-KeyCodeMap -Kind 'UTM-Char'
        foreach ($sym in @('!','@','#','$','%','^','&','(',')')) {
            Assert-Equal -Expected $utm[$pairs[$sym]][0] -Actual $utm[$sym][0] -Because "UTM: '$sym' is Shift + '$($pairs[$sym])'"
            Assert-Equal -Expected $true -Actual $utm[$sym][1] -Because "UTM: '$sym' needs Shift"
        }
    }
    It 'shapes every code-map entry as a two-element (code, needsShift) pair' -TestCases @(
        @{ kind = 'UTM-Char' }, @{ kind = 'PS2-Char' }, @{ kind = 'X11-Char' }
    ) {
        param($kind)
        $map = Get-KeyCodeMap -Kind $kind
        foreach ($key in @([string[]]$map.Keys)) {
            $entry = $map[$key]
            Assert-Equal -Expected 2 -Actual @($entry).Count -Because "'$kind' entry for '$key' must be [code, needsShift]"
            Assert-True ($entry[0] -is [int])  "'$kind' code for '$key' must be an int"
            Assert-True ($entry[1] -is [bool]) "'$kind' shift flag for '$key' must be a bool"
        }
    }
}

Describe 'Cross-transport coverage' {
    It 'covers an identical character set on UTM, PS2 and X11' {
        # Send-Text warns and SKIPS a character with no entry, so a string that
        # types on Hyper-V but is missing a glyph in the UTM table silently
        # types the wrong text on macOS -- and the step fails somewhere far
        # away from the cause.
        $ps2 = Get-CoveredChar -Kind 'PS2-Char'
        foreach ($kind in @('UTM-Char','X11-Char')) {
            Assert-Equal -Expected $ps2 -Actual (Get-CoveredChar -Kind $kind) `
                -Because "'$kind' must cover exactly the characters PS2-Char covers"
        }
        Assert-Equal -Expected 95 -Actual (Get-KeyCodeMap -Kind 'PS2-Char').Count -Because 'the printable US-layout set'
    }
    It 'covers the same characters on KVM, plus the whitespace chords virsh needs' {
        $kvm = Get-KeyCodeMap -Kind 'KVM-Char'
        foreach ($key in @([string[]](Get-KeyCodeMap -Kind 'PS2-Char').Keys)) {
            Assert-True ($kvm.ContainsKey($key)) "KVM-Char is missing '$key', which PS2-Char types"
        }
        foreach ($ws in @("`t", "`n", "`r")) {
            Assert-True ($kvm.ContainsKey($ws)) 'KVM-Char must chord tab / newline / carriage return'
        }
        Assert-Equal -Expected 'KEY_ENTER' -Actual (@($kvm["`n"]) -join '+')
        Assert-Equal -Expected 'KEY_ENTER' -Actual (@($kvm["`r"]) -join '+')
        Assert-Equal -Expected 'KEY_TAB'   -Actual (@($kvm["`t"]) -join '+')
    }
    It 'defines the key names every backend has to understand' {
        # Guard the guard: a $null fixture would make the loops below iterate
        # zero times and the test would pass while asserting nothing.
        Assert-Equal -Expected 4 -Actual @($namedKinds).Count
        Assert-Equal -Expected 8 -Actual @($universalKeyName).Count
        foreach ($kind in $namedKinds) {
            $map = Get-KeyCodeMap -Kind $kind
            foreach ($name in $universalKeyName) {
                Assert-True ($map.ContainsKey($name)) "'$kind' has no entry for the '$name' key"
            }
        }
    }
    It 'accepts the KVM name aliases a sequence may already be using' {
        $map = Get-KeyCodeMap -Kind 'KVM-Named'
        Assert-Equal -Expected $map['Enter']  -Actual $map['Return'] -Because 'Return is an alias of Enter'
        Assert-Equal -Expected $map['Escape'] -Actual $map['Esc']    -Because 'Esc is an alias of Escape'
        Assert-Equal -Expected 'KEY_ENTER' -Actual $map['Enter']
    }
    It 'never hands back a $null code for a character it claims to cover' {
        # Send-TextKvm / Send-TextHyperV test the lookup result for truthiness;
        # a present-but-null entry would be dropped with a confusing warning.
        foreach ($kind in $charKinds) {
            $map = Get-KeyCodeMap -Kind $kind
            foreach ($key in @([string[]]$map.Keys)) {
                Assert-True ($null -ne $map[$key]) "'$kind' has a null entry for '$key'"
                Assert-True (@($map[$key]).Count -gt 0) "'$kind' has an empty entry for '$key'"
            }
        }
        # Guard the guard: the loops above must actually have visited something.
        Assert-Equal -Expected 4 -Actual @($charKinds).Count
        Assert-Equal -Expected 3 -Actual @($codeCharKind).Count
    }
}
