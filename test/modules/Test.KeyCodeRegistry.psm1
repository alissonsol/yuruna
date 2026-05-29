<#PSScriptInfo
.VERSION 2026.05.29
.GUID 42e7c4b3-d2a1-4f56-9c78-3e4f5a6b7c80
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna keycode keyboard
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
    Per-transport key-code lookup tables, owned by a single module.

.DESCRIPTION
    Five distinct keyboard transports each need their own translation
    table (macOS UTM virtual key codes, PS/2 Set 1 scan codes for
    Hyper-V/QEMU, X11 keysyms for VNC/RFB, plus character->code maps
    for each). The tables previously lived inline in Test.Transport.psm1
    where a 1300-line module mixed data with the Send-Key / Send-Text /
    Send-Click backends that consume them. Extracting them here:

      * Shrinks Test.Transport so the backend logic is easier to read.
      * Provides one place to register a new transport's table when a
        fourth host backend lands (e.g. ProxMox, gnome-boxes) -- the
        new transport adds a new `Kind` case here, not a new $script:*
        copy somewhere else.
      * Lets autonomous tooling enumerate every map through a single
        Get-KeyCodeMapKind / Get-KeyCodeMap surface.

    The data values are byte-for-byte preserved from the prior inline
    declarations -- this is a code-organization move, not a content
    change. See docs/host-io.md for the broader transport contract.
#>

# ── Maps owned by this module ─────────────────────────────────────────────────

# macOS UTM AppleScript named-key code table.
$script:UtmNamedKeyMap = @{
    "Enter"=36; "Tab"=48; "Space"=49; "Escape"=53
    "Up"=126; "Down"=125; "Left"=123; "Right"=124
    "F1"=122; "F2"=120; "F3"=99; "F4"=118; "F5"=96
    "F6"=97; "F7"=98; "F8"=100; "F9"=101; "F10"=109
    "F11"=103; "F12"=111
}

# macOS UTM character->virtual-key-code map (US layout). Entries are
# [keyCode, needsShift]. Used by Send-TextUTM when AppleScript's
# keystroke command would misinterpret a sequence (e.g. "2-" → Enter).
$script:UtmCharKeyMap = [System.Collections.Generic.Dictionary[string,object[]]]::new()
$script:UtmCharKeyMap['a']=@(0,$false);  $script:UtmCharKeyMap['b']=@(11,$false)
$script:UtmCharKeyMap['c']=@(8,$false);  $script:UtmCharKeyMap['d']=@(2,$false)
$script:UtmCharKeyMap['e']=@(14,$false); $script:UtmCharKeyMap['f']=@(3,$false)
$script:UtmCharKeyMap['g']=@(5,$false);  $script:UtmCharKeyMap['h']=@(4,$false)
$script:UtmCharKeyMap['i']=@(34,$false); $script:UtmCharKeyMap['j']=@(38,$false)
$script:UtmCharKeyMap['k']=@(40,$false); $script:UtmCharKeyMap['l']=@(37,$false)
$script:UtmCharKeyMap['m']=@(46,$false); $script:UtmCharKeyMap['n']=@(45,$false)
$script:UtmCharKeyMap['o']=@(31,$false); $script:UtmCharKeyMap['p']=@(35,$false)
$script:UtmCharKeyMap['q']=@(12,$false); $script:UtmCharKeyMap['r']=@(15,$false)
$script:UtmCharKeyMap['s']=@(1,$false);  $script:UtmCharKeyMap['t']=@(17,$false)
$script:UtmCharKeyMap['u']=@(32,$false); $script:UtmCharKeyMap['v']=@(9,$false)
$script:UtmCharKeyMap['w']=@(13,$false); $script:UtmCharKeyMap['x']=@(7,$false)
$script:UtmCharKeyMap['y']=@(16,$false); $script:UtmCharKeyMap['z']=@(6,$false)
$script:UtmCharKeyMap['A']=@(0,$true);  $script:UtmCharKeyMap['B']=@(11,$true)
$script:UtmCharKeyMap['C']=@(8,$true);  $script:UtmCharKeyMap['D']=@(2,$true)
$script:UtmCharKeyMap['E']=@(14,$true); $script:UtmCharKeyMap['F']=@(3,$true)
$script:UtmCharKeyMap['G']=@(5,$true);  $script:UtmCharKeyMap['H']=@(4,$true)
$script:UtmCharKeyMap['I']=@(34,$true); $script:UtmCharKeyMap['J']=@(38,$true)
$script:UtmCharKeyMap['K']=@(40,$true); $script:UtmCharKeyMap['L']=@(37,$true)
$script:UtmCharKeyMap['M']=@(46,$true); $script:UtmCharKeyMap['N']=@(45,$true)
$script:UtmCharKeyMap['O']=@(31,$true); $script:UtmCharKeyMap['P']=@(35,$true)
$script:UtmCharKeyMap['Q']=@(12,$true); $script:UtmCharKeyMap['R']=@(15,$true)
$script:UtmCharKeyMap['S']=@(1,$true);  $script:UtmCharKeyMap['T']=@(17,$true)
$script:UtmCharKeyMap['U']=@(32,$true); $script:UtmCharKeyMap['V']=@(9,$true)
$script:UtmCharKeyMap['W']=@(13,$true); $script:UtmCharKeyMap['X']=@(7,$true)
$script:UtmCharKeyMap['Y']=@(16,$true); $script:UtmCharKeyMap['Z']=@(6,$true)
$script:UtmCharKeyMap['1']=@(18,$false); $script:UtmCharKeyMap['2']=@(19,$false)
$script:UtmCharKeyMap['3']=@(20,$false); $script:UtmCharKeyMap['4']=@(21,$false)
$script:UtmCharKeyMap['5']=@(23,$false); $script:UtmCharKeyMap['6']=@(22,$false)
$script:UtmCharKeyMap['7']=@(26,$false); $script:UtmCharKeyMap['8']=@(28,$false)
$script:UtmCharKeyMap['9']=@(25,$false); $script:UtmCharKeyMap['0']=@(29,$false)
$script:UtmCharKeyMap[' ']=@(49,$false);  $script:UtmCharKeyMap['-']=@(27,$false)
$script:UtmCharKeyMap['=']=@(24,$false);  $script:UtmCharKeyMap['[']=@(33,$false)
$script:UtmCharKeyMap[']']=@(30,$false);  $script:UtmCharKeyMap['\']=@(42,$false)
$script:UtmCharKeyMap[';']=@(41,$false);  $script:UtmCharKeyMap["'"]=@(39,$false)
$script:UtmCharKeyMap[',']=@(43,$false);  $script:UtmCharKeyMap['.']=@(47,$false)
$script:UtmCharKeyMap['/']=@(44,$false);  $script:UtmCharKeyMap['`']=@(50,$false)
# Shifted punctuation -- '*' and '+' use the numeric-keypad keycodes
# (kVK_ANSI_KeypadMultiply=67, kVK_ANSI_KeypadPlus=69) so they need
# no Shift; everything else is the main-row keycode with needsShift=true.
$script:UtmCharKeyMap['!']=@(18,$true);  $script:UtmCharKeyMap['@']=@(19,$true)
$script:UtmCharKeyMap['#']=@(20,$true);  $script:UtmCharKeyMap['$']=@(21,$true)
$script:UtmCharKeyMap['%']=@(23,$true);  $script:UtmCharKeyMap['^']=@(22,$true)
$script:UtmCharKeyMap['&']=@(26,$true);  $script:UtmCharKeyMap['*']=@(67,$false)
$script:UtmCharKeyMap['(']=@(25,$true);  $script:UtmCharKeyMap[')']=@(29,$true)
$script:UtmCharKeyMap['_']=@(27,$true);  $script:UtmCharKeyMap['+']=@(69,$false)
$script:UtmCharKeyMap['{']=@(33,$true);  $script:UtmCharKeyMap['}']=@(30,$true)
$script:UtmCharKeyMap['|']=@(42,$true);  $script:UtmCharKeyMap[':']=@(41,$true)
$script:UtmCharKeyMap['"']=@(39,$true);  $script:UtmCharKeyMap['<']=@(43,$true)
$script:UtmCharKeyMap['>']=@(47,$true);  $script:UtmCharKeyMap['?']=@(44,$true)
$script:UtmCharKeyMap['~']=@(50,$true)

# PS/2 Set 1 named-key scan codes (Hyper-V Msvm_Keyboard + QEMU). Each
# entry is the make code; the break code is `make | 0x80`.
$script:Ps2NamedKeyMap = @{
    "Enter"=0x1C; "Tab"=0x0F; "Space"=0x39; "Escape"=0x01; "Backspace"=0x0E
    "Up"=0x48; "Down"=0x50; "Left"=0x4B; "Right"=0x4D
    "F1"=0x3B; "F2"=0x3C; "F3"=0x3D; "F4"=0x3E; "F5"=0x3F; "F6"=0x40
    "F7"=0x41; "F8"=0x42; "F9"=0x43; "F10"=0x44; "F11"=0x57; "F12"=0x58
    "LShift"=0x2A; "RShift"=0x36
}

# Character->PS/2 scan code map (US layout). Entries are [scancode,
# needsShift]. Case-sensitive .NET Dictionary because PowerShell's
# default hashtable folds 'a' and 'A'.
$script:Ps2CharKeyMap = [System.Collections.Generic.Dictionary[string,object[]]]::new()
$script:Ps2CharKeyMap['a']=@(0x1E,$false); $script:Ps2CharKeyMap['b']=@(0x30,$false)
$script:Ps2CharKeyMap['c']=@(0x2E,$false); $script:Ps2CharKeyMap['d']=@(0x20,$false)
$script:Ps2CharKeyMap['e']=@(0x12,$false); $script:Ps2CharKeyMap['f']=@(0x21,$false)
$script:Ps2CharKeyMap['g']=@(0x22,$false); $script:Ps2CharKeyMap['h']=@(0x23,$false)
$script:Ps2CharKeyMap['i']=@(0x17,$false); $script:Ps2CharKeyMap['j']=@(0x24,$false)
$script:Ps2CharKeyMap['k']=@(0x25,$false); $script:Ps2CharKeyMap['l']=@(0x26,$false)
$script:Ps2CharKeyMap['m']=@(0x32,$false); $script:Ps2CharKeyMap['n']=@(0x31,$false)
$script:Ps2CharKeyMap['o']=@(0x18,$false); $script:Ps2CharKeyMap['p']=@(0x19,$false)
$script:Ps2CharKeyMap['q']=@(0x10,$false); $script:Ps2CharKeyMap['r']=@(0x13,$false)
$script:Ps2CharKeyMap['s']=@(0x1F,$false); $script:Ps2CharKeyMap['t']=@(0x14,$false)
$script:Ps2CharKeyMap['u']=@(0x16,$false); $script:Ps2CharKeyMap['v']=@(0x2F,$false)
$script:Ps2CharKeyMap['w']=@(0x11,$false); $script:Ps2CharKeyMap['x']=@(0x2D,$false)
$script:Ps2CharKeyMap['y']=@(0x15,$false); $script:Ps2CharKeyMap['z']=@(0x2C,$false)
$script:Ps2CharKeyMap['A']=@(0x1E,$true); $script:Ps2CharKeyMap['B']=@(0x30,$true)
$script:Ps2CharKeyMap['C']=@(0x2E,$true); $script:Ps2CharKeyMap['D']=@(0x20,$true)
$script:Ps2CharKeyMap['E']=@(0x12,$true); $script:Ps2CharKeyMap['F']=@(0x21,$true)
$script:Ps2CharKeyMap['G']=@(0x22,$true); $script:Ps2CharKeyMap['H']=@(0x23,$true)
$script:Ps2CharKeyMap['I']=@(0x17,$true); $script:Ps2CharKeyMap['J']=@(0x24,$true)
$script:Ps2CharKeyMap['K']=@(0x25,$true); $script:Ps2CharKeyMap['L']=@(0x26,$true)
$script:Ps2CharKeyMap['M']=@(0x32,$true); $script:Ps2CharKeyMap['N']=@(0x31,$true)
$script:Ps2CharKeyMap['O']=@(0x18,$true); $script:Ps2CharKeyMap['P']=@(0x19,$true)
$script:Ps2CharKeyMap['Q']=@(0x10,$true); $script:Ps2CharKeyMap['R']=@(0x13,$true)
$script:Ps2CharKeyMap['S']=@(0x1F,$true); $script:Ps2CharKeyMap['T']=@(0x14,$true)
$script:Ps2CharKeyMap['U']=@(0x16,$true); $script:Ps2CharKeyMap['V']=@(0x2F,$true)
$script:Ps2CharKeyMap['W']=@(0x11,$true); $script:Ps2CharKeyMap['X']=@(0x2D,$true)
$script:Ps2CharKeyMap['Y']=@(0x15,$true); $script:Ps2CharKeyMap['Z']=@(0x2C,$true)
$script:Ps2CharKeyMap['1']=@(0x02,$false); $script:Ps2CharKeyMap['2']=@(0x03,$false)
$script:Ps2CharKeyMap['3']=@(0x04,$false); $script:Ps2CharKeyMap['4']=@(0x05,$false)
$script:Ps2CharKeyMap['5']=@(0x06,$false); $script:Ps2CharKeyMap['6']=@(0x07,$false)
$script:Ps2CharKeyMap['7']=@(0x08,$false); $script:Ps2CharKeyMap['8']=@(0x09,$false)
$script:Ps2CharKeyMap['9']=@(0x0A,$false); $script:Ps2CharKeyMap['0']=@(0x0B,$false)
$script:Ps2CharKeyMap[' ']=@(0x39,$false); $script:Ps2CharKeyMap['-']=@(0x0C,$false)
$script:Ps2CharKeyMap['=']=@(0x0D,$false); $script:Ps2CharKeyMap['[']=@(0x1A,$false)
$script:Ps2CharKeyMap[']']=@(0x1B,$false); $script:Ps2CharKeyMap['\']=@(0x2B,$false)
$script:Ps2CharKeyMap[';']=@(0x27,$false); $script:Ps2CharKeyMap["'"]=@(0x28,$false)
$script:Ps2CharKeyMap[',']=@(0x33,$false); $script:Ps2CharKeyMap['.']=@(0x34,$false)
$script:Ps2CharKeyMap['/']=@(0x35,$false); $script:Ps2CharKeyMap['`']=@(0x29,$false)
$script:Ps2CharKeyMap['!']=@(0x02,$true); $script:Ps2CharKeyMap['@']=@(0x03,$true)
$script:Ps2CharKeyMap['#']=@(0x04,$true); $script:Ps2CharKeyMap['$']=@(0x05,$true)
$script:Ps2CharKeyMap['%']=@(0x06,$true); $script:Ps2CharKeyMap['^']=@(0x07,$true)
$script:Ps2CharKeyMap['&']=@(0x08,$true); $script:Ps2CharKeyMap['*']=@(0x09,$true)
$script:Ps2CharKeyMap['(']=@(0x0A,$true); $script:Ps2CharKeyMap[')']=@(0x0B,$true)
$script:Ps2CharKeyMap['_']=@(0x0C,$true); $script:Ps2CharKeyMap['+']=@(0x0D,$true)
$script:Ps2CharKeyMap['{']=@(0x1A,$true); $script:Ps2CharKeyMap['}']=@(0x1B,$true)
$script:Ps2CharKeyMap['|']=@(0x2B,$true); $script:Ps2CharKeyMap[':']=@(0x27,$true)
$script:Ps2CharKeyMap['"']=@(0x28,$true); $script:Ps2CharKeyMap['<']=@(0x33,$true)
$script:Ps2CharKeyMap['>']=@(0x34,$true); $script:Ps2CharKeyMap['?']=@(0x35,$true)
$script:Ps2CharKeyMap['~']=@(0x29,$true)

# X11 keysyms for special keys (RFB key events use X11 keysyms).
$script:X11NamedKeyMap = @{
    "Enter"=0xFF0D; "Tab"=0xFF09; "Space"=0x0020; "Escape"=0xFF1B; "Backspace"=0xFF08
    "Up"=0xFF52; "Down"=0xFF54; "Left"=0xFF51; "Right"=0xFF53
    "F1"=0xFFBE; "F2"=0xFFBF; "F3"=0xFFC0; "F4"=0xFFC1; "F5"=0xFFC2
    "F6"=0xFFC3; "F7"=0xFFC4; "F8"=0xFFC5; "F9"=0xFFC6; "F10"=0xFFC7
    "F11"=0xFFC8; "F12"=0xFFC9
    "LShift"=0xFFE1; "RShift"=0xFFE2
}

# X11 keysyms for printable ASCII chars. The keysym IS the Unicode/ASCII
# code point for standard ASCII; entries are [keysym, needsShift].
$script:X11CharKeyMap = [System.Collections.Generic.Dictionary[string,object[]]]::new()
foreach ($c in 97..122) { $script:X11CharKeyMap[[string][char]$c] = @($c, $false) }
foreach ($c in 65..90)  { $script:X11CharKeyMap[[string][char]$c] = @($c, $true) }
foreach ($c in 48..57)  { $script:X11CharKeyMap[[string][char]$c] = @($c, $false) }
' ','-','=','[',']','\',';',"'",',','.','/','`' | ForEach-Object {
    $script:X11CharKeyMap[$_] = @([int][char]$_, $false)
}
'!','@','#','$','%','^','&','*','(',')','_','+','{','}','|',':','"','<','>','?','~' | ForEach-Object {
    $script:X11CharKeyMap[$_] = @([int][char]$_, $true)
}

# Kind -> map dispatch table. Built once so Get-KeyCodeMap returns by
# reference (callers can still index the map directly).
$script:KeyCodeMapByKind = @{
    'UTM-Named' = $script:UtmNamedKeyMap
    'UTM-Char'  = $script:UtmCharKeyMap
    'PS2-Named' = $script:Ps2NamedKeyMap
    'PS2-Char'  = $script:Ps2CharKeyMap
    'X11-Named' = $script:X11NamedKeyMap
    'X11-Char'  = $script:X11CharKeyMap
}

function Get-KeyCodeMap {
    <#
    .SYNOPSIS
        Returns the key-code map for the named transport kind.
    .PARAMETER Kind
        One of UTM-Named, UTM-Char, PS2-Named, PS2-Char, X11-Named, X11-Char.
        UTM is macOS UTM AppleScript / CGEvent; PS2 is Hyper-V / QEMU
        hardware-level scancodes; X11 is VNC/RFB keysyms.
    .OUTPUTS
        Hashtable or Dictionary[string,object[]] (named maps are plain
        hashtables; -Char maps are case-sensitive .NET Dictionaries
        keyed on the literal character).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('UTM-Named','UTM-Char','PS2-Named','PS2-Char','X11-Named','X11-Char')]
        [string]$Kind
    )
    return $script:KeyCodeMapByKind[$Kind]
}

function Get-KeyCodeMapKind {
    <#
    .SYNOPSIS
        Returns the names of every map this registry exposes.
    .DESCRIPTION
        Lets the startup capability matrix (or a fourth-host backend's
        smoke test) enumerate available transports without hardcoding
        the list.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param()
    return @($script:KeyCodeMapByKind.Keys)
}

Export-ModuleMember -Function Get-KeyCodeMap, Get-KeyCodeMapKind
