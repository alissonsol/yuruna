<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456770
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

$InformationPreference = 'Continue'
$ProgressPreference = 'Continue'

# Inherit debug/verbose preferences from the parent process via env vars.
# Child pwsh processes don't inherit PowerShell preference variables, so
# the runner publishes them as YURUNA_DEBUG / YURUNA_VERBOSE.
if ($env:YURUNA_DEBUG -eq '1')   { $global:DebugPreference   = 'Continue' }
if ($env:YURUNA_VERBOSE -eq '1') { $global:VerbosePreference = 'Continue' }

# ── Load global defaults from test-config.json ──────────────────────────────
# The config file lives one level up from this module (test/test-config.json).
$script:DefaultCharDelayMs      = 20
$script:DefaultVncPort          = 5900
$script:DefaultKeystrokeMechanism = "GUI"

# ── Progress marker protocol ─────────────────────────────────────────────────
# When Invoke-Sequence runs inside a child pwsh whose stdout is piped to the
# parent (see Test.Install-OS.psm1), the child's ConsoleHost goes
# non-interactive and Write-Progress becomes a no-op. We work around this by
# ALSO emitting a marker line on stdout for each tick; the parent's pipeline
# parses these and calls Write-Progress in its own interactive host. The
# marker must never be intercepted by the yuruna-log proxy, so we bypass it
# via $Host.UI.WriteLine (raw host write, not the Write-* stream).
function Write-ProgressTick {
    param(
        [Parameter(Mandatory)][string]$Activity,
        [string]$Status = '',
        [int]$PercentComplete = -1,
        [switch]$Completed
    )
    # The marker uses '|' as delimiter. If a caller's Activity or Status
    # happens to contain '|', the parent's .Split('|') would shift columns and
    # parts[2] (meant to be PercentComplete) would parse as non-numeric, e.g.
    # Wait-ForAndClickButton once built `'Install Ubuntu' | 'Install' | 'lnstall'`
    # and the parent crashed with "Cannot convert ' 'Install' ' to Int32".
    # Replace with '/' here so callers can freely embed any character in their
    # progress text and the on-screen Write-Progress keeps the original string.
    $safeActivity = $Activity -replace '\|', '/'
    $safeStatus   = $Status   -replace '\|', '/'
    if ($Completed) {
        Write-Progress -Activity $Activity -Completed
        $Host.UI.WriteLine("##YURUNA-PROGRESS##|$safeActivity|done|-1|1")
    } else {
        Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
        $Host.UI.WriteLine("##YURUNA-PROGRESS##|$safeActivity|$safeStatus|$PercentComplete|0")
    }
}
$_configPath = Join-Path (Split-Path -Parent $PSScriptRoot) "test-config.json"
if (Test-Path $_configPath) {
    try {
        $_cfg = Get-Content -Raw $_configPath | ConvertFrom-Json
        if ($_cfg.charDelayMs)        { $script:DefaultCharDelayMs        = [int]$_cfg.charDelayMs }
        if ($_cfg.vncPort)            { $script:DefaultVncPort            = [int]$_cfg.vncPort }
        if ($_cfg.keystrokeMechanism) { $script:DefaultKeystrokeMechanism = [string]$_cfg.keystrokeMechanism }
    } catch { Write-Verbose "Config parse error — using built-in default: $_" }
}
Remove-Variable -Name _configPath, _cfg -ErrorAction SilentlyContinue

# ─────────────────────────────────────────────────────────────────────────────
# Shared engine for executing interaction sequences from JSON files.
#
# Supported actions (defined in the "steps" array in each JSON):
#   delay            — Wait N seconds.
#   key              — Send a single keystroke.
#   type             — Type a text string into the VM (charDelayMs configurable, default from test-config.json, fallback 20ms).
#   typeAndEnter     — Type a text string, wait, then press Enter (charDelayMs/delaySeconds configurable).
#   tabsAndEnter     — Send N Tab keystrokes, then press Enter. Useful when focus must be advanced
#                       to a default button (tabCount, delaySeconds configurable).
#   screenshot       — Capture a screenshot for debugging.
#   waitForText      — Capture + OCR the VM screen until pattern appears (supports array of alternate patterns).
#                       freshMatch: if true, captures a baseline, then waits for the screen
#                       to change AND the pattern to appear in the last N lines.
#                       freshMatchTailLines: number of trailing OCR lines to check (default 12).
#   waitForAndEnter  — Wait for text pattern on screen via OCR, then type a string and press Enter.
#                       Combines waitForText + typeAndEnter into a single step.
#   waitForAndClickButton — Wait for a labelled button via OCR and click its centre.
#                       Uses Tesseract TSV to get per-word bounding boxes, then
#                       synthesizes a mouse click at (centerX + offsetX, centerY + offsetY).
#                       More reliable than Tab-count navigation for focus-sensitive UIs
#                       (e.g. Ubuntu Desktop 24.04 installer). Hyper-V only for now;
#                       UTM support is stubbed.
#   waitForPort      — Wait until a TCP port responds on the VM.
#   waitForHeartbeat — Wait for Hyper-V heartbeat (Hyper-V only).
#   waitForVMStop    — Wait until the VM reaches the Off/stopped state.
#   sshWaitReady     — Wait until the guest accepts SSH using the yuruna harness key.
#   sshExec          — Run a command on the guest over SSH; non-zero exit fails unless allowFailure=true.
#   sshFetchAndExecute — Run a long-lived command over SSH (SSH equivalent of fetchAndExecute).
#
# Variables defined in the JSON "variables" block are substituted into
# action parameters using ${variableName} syntax. Built-in variables:
# ${vmName}, ${hostType}, ${guestKey}.
#
# On step failure, diagnostics are written to $env:YURUNA_LOG_DIR:
#   last_failure.json              — failed step details (read by the parent runner)
#   failure_screenshot_<VM>.png    — last VM screenshot at time of failure
#   failure_ocr_<VM>.txt           — last OCR text (waitForText failures only)
# ─────────────────────────────────────────────────────────────────────────────

# ── Key code maps ────────────────────────────────────────────────────────────

# macOS AppleScript key codes (special keys)
$script:UTMKeyMap = @{
    "Enter"=36; "Tab"=48; "Space"=49; "Escape"=53
    "Up"=126; "Down"=125; "Left"=123; "Right"=124
    "F1"=122; "F2"=120; "F3"=99; "F4"=118; "F5"=96
    "F6"=97; "F7"=98; "F8"=100; "F9"=101; "F10"=109
    "F11"=103; "F12"=111
}

# macOS character to virtual key code map (US keyboard layout).
# Entries: [keyCode, needsShift]. Used by Send-TextUTM to send raw key codes
# instead of AppleScript's keystroke command, which misinterprets certain
# character sequences (e.g., "2-" becomes Enter).
$script:MacCharKeyCodes = [System.Collections.Generic.Dictionary[string,object[]]]::new()
# Lowercase letters
$script:MacCharKeyCodes['a']=@(0,$false);  $script:MacCharKeyCodes['b']=@(11,$false)
$script:MacCharKeyCodes['c']=@(8,$false);  $script:MacCharKeyCodes['d']=@(2,$false)
$script:MacCharKeyCodes['e']=@(14,$false); $script:MacCharKeyCodes['f']=@(3,$false)
$script:MacCharKeyCodes['g']=@(5,$false);  $script:MacCharKeyCodes['h']=@(4,$false)
$script:MacCharKeyCodes['i']=@(34,$false); $script:MacCharKeyCodes['j']=@(38,$false)
$script:MacCharKeyCodes['k']=@(40,$false); $script:MacCharKeyCodes['l']=@(37,$false)
$script:MacCharKeyCodes['m']=@(46,$false); $script:MacCharKeyCodes['n']=@(45,$false)
$script:MacCharKeyCodes['o']=@(31,$false); $script:MacCharKeyCodes['p']=@(35,$false)
$script:MacCharKeyCodes['q']=@(12,$false); $script:MacCharKeyCodes['r']=@(15,$false)
$script:MacCharKeyCodes['s']=@(1,$false);  $script:MacCharKeyCodes['t']=@(17,$false)
$script:MacCharKeyCodes['u']=@(32,$false); $script:MacCharKeyCodes['v']=@(9,$false)
$script:MacCharKeyCodes['w']=@(13,$false); $script:MacCharKeyCodes['x']=@(7,$false)
$script:MacCharKeyCodes['y']=@(16,$false); $script:MacCharKeyCodes['z']=@(6,$false)
# Uppercase letters (same key codes, shifted)
$script:MacCharKeyCodes['A']=@(0,$true);  $script:MacCharKeyCodes['B']=@(11,$true)
$script:MacCharKeyCodes['C']=@(8,$true);  $script:MacCharKeyCodes['D']=@(2,$true)
$script:MacCharKeyCodes['E']=@(14,$true); $script:MacCharKeyCodes['F']=@(3,$true)
$script:MacCharKeyCodes['G']=@(5,$true);  $script:MacCharKeyCodes['H']=@(4,$true)
$script:MacCharKeyCodes['I']=@(34,$true); $script:MacCharKeyCodes['J']=@(38,$true)
$script:MacCharKeyCodes['K']=@(40,$true); $script:MacCharKeyCodes['L']=@(37,$true)
$script:MacCharKeyCodes['M']=@(46,$true); $script:MacCharKeyCodes['N']=@(45,$true)
$script:MacCharKeyCodes['O']=@(31,$true); $script:MacCharKeyCodes['P']=@(35,$true)
$script:MacCharKeyCodes['Q']=@(12,$true); $script:MacCharKeyCodes['R']=@(15,$true)
$script:MacCharKeyCodes['S']=@(1,$true);  $script:MacCharKeyCodes['T']=@(17,$true)
$script:MacCharKeyCodes['U']=@(32,$true); $script:MacCharKeyCodes['V']=@(9,$true)
$script:MacCharKeyCodes['W']=@(13,$true); $script:MacCharKeyCodes['X']=@(7,$true)
$script:MacCharKeyCodes['Y']=@(16,$true); $script:MacCharKeyCodes['Z']=@(6,$true)
# Numbers
$script:MacCharKeyCodes['1']=@(18,$false); $script:MacCharKeyCodes['2']=@(19,$false)
$script:MacCharKeyCodes['3']=@(20,$false); $script:MacCharKeyCodes['4']=@(21,$false)
$script:MacCharKeyCodes['5']=@(23,$false); $script:MacCharKeyCodes['6']=@(22,$false)
$script:MacCharKeyCodes['7']=@(26,$false); $script:MacCharKeyCodes['8']=@(28,$false)
$script:MacCharKeyCodes['9']=@(25,$false); $script:MacCharKeyCodes['0']=@(29,$false)
# Punctuation (unshifted)
$script:MacCharKeyCodes[' ']=@(49,$false);  $script:MacCharKeyCodes['-']=@(27,$false)
$script:MacCharKeyCodes['=']=@(24,$false);  $script:MacCharKeyCodes['[']=@(33,$false)
$script:MacCharKeyCodes[']']=@(30,$false);  $script:MacCharKeyCodes['\']=@(42,$false)
$script:MacCharKeyCodes[';']=@(41,$false);  $script:MacCharKeyCodes["'"]=@(39,$false)
$script:MacCharKeyCodes[',']=@(43,$false);  $script:MacCharKeyCodes['.']=@(47,$false)
$script:MacCharKeyCodes['/']=@(44,$false);  $script:MacCharKeyCodes['`']=@(50,$false)
# Punctuation (shifted)
$script:MacCharKeyCodes['!']=@(18,$true);  $script:MacCharKeyCodes['@']=@(19,$true)
$script:MacCharKeyCodes['#']=@(20,$true);  $script:MacCharKeyCodes['$']=@(21,$true)
$script:MacCharKeyCodes['%']=@(23,$true);  $script:MacCharKeyCodes['^']=@(22,$true)
$script:MacCharKeyCodes['&']=@(26,$true);  $script:MacCharKeyCodes['*']=@(28,$true)
$script:MacCharKeyCodes['(']=@(25,$true);  $script:MacCharKeyCodes[')']=@(29,$true)
$script:MacCharKeyCodes['_']=@(27,$true);  $script:MacCharKeyCodes['+']=@(24,$true)
$script:MacCharKeyCodes['{']=@(33,$true);  $script:MacCharKeyCodes['}']=@(30,$true)
$script:MacCharKeyCodes['|']=@(42,$true);  $script:MacCharKeyCodes[':']=@(41,$true)
$script:MacCharKeyCodes['"']=@(39,$true);  $script:MacCharKeyCodes['<']=@(43,$true)
$script:MacCharKeyCodes['>']=@(47,$true);  $script:MacCharKeyCodes['?']=@(44,$true)
$script:MacCharKeyCodes['~']=@(50,$true)

# ── Cached Hyper-V keyboard (reused across steps) ───────────────────────────

$script:CachedKb = $null
$script:CachedKbVM = $null

function Get-HyperVKeyboard {
    param([string]$VMName)
    if ($script:CachedKbVM -eq $VMName -and $script:CachedKb) { return $script:CachedKb }
    $vmObj = Get-CimInstance -Namespace root\virtualization\v2 `
        -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
    if (-not $vmObj) { Write-Warning "VM '$VMName' not found in WMI"; return $null }
    $kb = Get-CimAssociatedInstance -InputObject $vmObj -ResultClassName Msvm_Keyboard
    if (-not $kb) { Write-Warning "Keyboard device not found for '$VMName'"; return $null }
    $script:CachedKb = $kb
    $script:CachedKbVM = $VMName
    return $kb
}

# ── PS/2 Set 1 scan codes (hardware-level, works with any guest OS) ──────────
# Each key maps to its make code. Break code = make | 0x80.
# TypeScancodes sends these directly to the virtual keyboard controller.
$script:PS2ScanCodes = @{
    "Enter"=0x1C; "Tab"=0x0F; "Space"=0x39; "Escape"=0x01; "Backspace"=0x0E
    "Up"=0x48; "Down"=0x50; "Left"=0x4B; "Right"=0x4D
    "F1"=0x3B; "F2"=0x3C; "F3"=0x3D; "F4"=0x3E; "F5"=0x3F; "F6"=0x40
    "F7"=0x41; "F8"=0x42; "F9"=0x43; "F10"=0x44; "F11"=0x57; "F12"=0x58
    "LShift"=0x2A; "RShift"=0x36
}

# Character to PS/2 scan code map (US keyboard layout).
# Entries: [scancode, needsShift]. Uses case-sensitive dictionary since
# PowerShell's default hashtable is case-insensitive ('a' == 'A').
$script:CharScanCodes = [System.Collections.Generic.Dictionary[string,object[]]]::new()
# Lowercase letters
$script:CharScanCodes['a']=@(0x1E,$false); $script:CharScanCodes['b']=@(0x30,$false)
$script:CharScanCodes['c']=@(0x2E,$false); $script:CharScanCodes['d']=@(0x20,$false)
$script:CharScanCodes['e']=@(0x12,$false); $script:CharScanCodes['f']=@(0x21,$false)
$script:CharScanCodes['g']=@(0x22,$false); $script:CharScanCodes['h']=@(0x23,$false)
$script:CharScanCodes['i']=@(0x17,$false); $script:CharScanCodes['j']=@(0x24,$false)
$script:CharScanCodes['k']=@(0x25,$false); $script:CharScanCodes['l']=@(0x26,$false)
$script:CharScanCodes['m']=@(0x32,$false); $script:CharScanCodes['n']=@(0x31,$false)
$script:CharScanCodes['o']=@(0x18,$false); $script:CharScanCodes['p']=@(0x19,$false)
$script:CharScanCodes['q']=@(0x10,$false); $script:CharScanCodes['r']=@(0x13,$false)
$script:CharScanCodes['s']=@(0x1F,$false); $script:CharScanCodes['t']=@(0x14,$false)
$script:CharScanCodes['u']=@(0x16,$false); $script:CharScanCodes['v']=@(0x2F,$false)
$script:CharScanCodes['w']=@(0x11,$false); $script:CharScanCodes['x']=@(0x2D,$false)
$script:CharScanCodes['y']=@(0x15,$false); $script:CharScanCodes['z']=@(0x2C,$false)
# Uppercase letters (same scan codes, shifted)
$script:CharScanCodes['A']=@(0x1E,$true); $script:CharScanCodes['B']=@(0x30,$true)
$script:CharScanCodes['C']=@(0x2E,$true); $script:CharScanCodes['D']=@(0x20,$true)
$script:CharScanCodes['E']=@(0x12,$true); $script:CharScanCodes['F']=@(0x21,$true)
$script:CharScanCodes['G']=@(0x22,$true); $script:CharScanCodes['H']=@(0x23,$true)
$script:CharScanCodes['I']=@(0x17,$true); $script:CharScanCodes['J']=@(0x24,$true)
$script:CharScanCodes['K']=@(0x25,$true); $script:CharScanCodes['L']=@(0x26,$true)
$script:CharScanCodes['M']=@(0x32,$true); $script:CharScanCodes['N']=@(0x31,$true)
$script:CharScanCodes['O']=@(0x18,$true); $script:CharScanCodes['P']=@(0x19,$true)
$script:CharScanCodes['Q']=@(0x10,$true); $script:CharScanCodes['R']=@(0x13,$true)
$script:CharScanCodes['S']=@(0x1F,$true); $script:CharScanCodes['T']=@(0x14,$true)
$script:CharScanCodes['U']=@(0x16,$true); $script:CharScanCodes['V']=@(0x2F,$true)
$script:CharScanCodes['W']=@(0x11,$true); $script:CharScanCodes['X']=@(0x2D,$true)
$script:CharScanCodes['Y']=@(0x15,$true); $script:CharScanCodes['Z']=@(0x2C,$true)
# Numbers
$script:CharScanCodes['1']=@(0x02,$false); $script:CharScanCodes['2']=@(0x03,$false)
$script:CharScanCodes['3']=@(0x04,$false); $script:CharScanCodes['4']=@(0x05,$false)
$script:CharScanCodes['5']=@(0x06,$false); $script:CharScanCodes['6']=@(0x07,$false)
$script:CharScanCodes['7']=@(0x08,$false); $script:CharScanCodes['8']=@(0x09,$false)
$script:CharScanCodes['9']=@(0x0A,$false); $script:CharScanCodes['0']=@(0x0B,$false)
# Punctuation (unshifted)
$script:CharScanCodes[' ']=@(0x39,$false); $script:CharScanCodes['-']=@(0x0C,$false)
$script:CharScanCodes['=']=@(0x0D,$false); $script:CharScanCodes['[']=@(0x1A,$false)
$script:CharScanCodes[']']=@(0x1B,$false); $script:CharScanCodes['\']=@(0x2B,$false)
$script:CharScanCodes[';']=@(0x27,$false); $script:CharScanCodes["'"]=@(0x28,$false)
$script:CharScanCodes[',']=@(0x33,$false); $script:CharScanCodes['.']=@(0x34,$false)
$script:CharScanCodes['/']=@(0x35,$false); $script:CharScanCodes['`']=@(0x29,$false)
# Punctuation (shifted)
$script:CharScanCodes['!']=@(0x02,$true); $script:CharScanCodes['@']=@(0x03,$true)
$script:CharScanCodes['#']=@(0x04,$true); $script:CharScanCodes['$']=@(0x05,$true)
$script:CharScanCodes['%']=@(0x06,$true); $script:CharScanCodes['^']=@(0x07,$true)
$script:CharScanCodes['&']=@(0x08,$true); $script:CharScanCodes['*']=@(0x09,$true)
$script:CharScanCodes['(']=@(0x0A,$true); $script:CharScanCodes[')']=@(0x0B,$true)
$script:CharScanCodes['_']=@(0x0C,$true); $script:CharScanCodes['+']=@(0x0D,$true)
$script:CharScanCodes['{']=@(0x1A,$true); $script:CharScanCodes['}']=@(0x1B,$true)
$script:CharScanCodes['|']=@(0x2B,$true); $script:CharScanCodes[':']=@(0x27,$true)
$script:CharScanCodes['"']=@(0x28,$true); $script:CharScanCodes['<']=@(0x33,$true)
$script:CharScanCodes['>']=@(0x34,$true); $script:CharScanCodes['?']=@(0x35,$true)
$script:CharScanCodes['~']=@(0x29,$true)

# ── VNC (RFB) keystroke transport ────────────────────────────────────────────
# Sends keystrokes directly to the VM's virtual display via the VNC/RFB
# protocol, bypassing the macOS GUI entirely — no window focus required.
# Used for QEMU-backend UTM VMs with a built-in VNC server enabled
# (via AdditionalArguments: -vnc localhost:0 in the plist).
# Apple Virtualization Framework VMs (Linux guests) fall back to
# AppleScript/CGEvent since they have no built-in VNC server.

# X11 keysym map for special keys (RFB key events use X11 keysyms)
$script:X11KeySyms = @{
    "Enter"=0xFF0D; "Tab"=0xFF09; "Space"=0x0020; "Escape"=0xFF1B; "Backspace"=0xFF08
    "Up"=0xFF52; "Down"=0xFF54; "Left"=0xFF51; "Right"=0xFF53
    "F1"=0xFFBE; "F2"=0xFFBF; "F3"=0xFFC0; "F4"=0xFFC1; "F5"=0xFFC2
    "F6"=0xFFC3; "F7"=0xFFC4; "F8"=0xFFC5; "F9"=0xFFC6; "F10"=0xFFC7
    "F11"=0xFFC8; "F12"=0xFFC9
    "LShift"=0xFFE1; "RShift"=0xFFE2
}

# X11 keysyms for printable ASCII characters.
# For standard ASCII, the keysym equals the Unicode/ASCII code point.
# Entries: [keysym, needsShift].
$script:X11CharKeySyms = [System.Collections.Generic.Dictionary[string,object[]]]::new()
# Lowercase letters
foreach ($c in 97..122) { $script:X11CharKeySyms[[string][char]$c] = @($c, $false) }
# Uppercase letters
foreach ($c in 65..90)  { $script:X11CharKeySyms[[string][char]$c] = @($c, $true) }
# Digits
foreach ($c in 48..57)  { $script:X11CharKeySyms[[string][char]$c] = @($c, $false) }
# Unshifted punctuation
' ','-','=','[',']','\',';',"'",',','.','/','`' | ForEach-Object {
    $script:X11CharKeySyms[$_] = @([int][char]$_, $false)
}
# Shifted punctuation
'!','@','#','$','%','^','&','*','(',')','_','+','{','}','|',':','"','<','>','?','~' | ForEach-Object {
    $script:X11CharKeySyms[$_] = @([int][char]$_, $true)
}

# ── Cached VNC connection (reused across steps within a sequence) ────────────

$script:CachedVnc   = $null
$script:CachedVncVM = $null

function Read-VncBuffer {
    param([System.IO.Stream]$Stream, [int]$Count)
    $buf = [byte[]]::new($Count)
    $offset = 0
    while ($offset -lt $Count) {
        $n = $Stream.Read($buf, $offset, $Count - $offset)
        if ($n -eq 0) { throw "VNC connection closed during read" }
        $offset += $n
    }
    return $buf
}

function Connect-VNC {
    param([string]$VMName, [int]$Port = $script:DefaultVncPort)
    # Return cached connection if still alive
    if ($script:CachedVncVM -eq $VMName -and $script:CachedVnc -and $script:CachedVnc.Connected) {
        return $script:CachedVnc
    }
    Disconnect-VNC
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $tcp.ReceiveTimeout = 5000
        $tcp.SendTimeout    = 5000
        $tcp.Connect("127.0.0.1", $Port)
        $stream = $tcp.GetStream()

        # ── RFB 3.8 handshake ──────────────────────────────────────────
        # Server sends protocol version (12 bytes): "RFB 003.008\n"
        $verBytes = Read-VncBuffer -Stream $stream -Count 12
        $serverVersion = [System.Text.Encoding]::ASCII.GetString($verBytes).Trim()
        Write-Debug "      VNC server version: $serverVersion"

        # Client responds with RFB 003.008
        $clientVer = [System.Text.Encoding]::ASCII.GetBytes("RFB 003.008`n")
        $stream.Write($clientVer, 0, 12)

        # Server sends security types: [1 byte count] [count × 1 byte type]
        $countBuf = Read-VncBuffer -Stream $stream -Count 1
        $numTypes = [int]$countBuf[0]
        if ($numTypes -eq 0) {
            # Server sent an error — read the reason string
            $reasonLenBuf = Read-VncBuffer -Stream $stream -Count 4
            [Array]::Reverse($reasonLenBuf)
            $reasonLen = [BitConverter]::ToInt32($reasonLenBuf, 0)
            $reasonBuf = Read-VncBuffer -Stream $stream -Count $reasonLen
            $reason = [System.Text.Encoding]::ASCII.GetString($reasonBuf)
            Write-Warning "VNC connection refused: $reason"
            $tcp.Dispose()
            return $null
        }
        $typesBuf = Read-VncBuffer -Stream $stream -Count $numTypes

        # Select security type 1 (None) — safe for localhost-only VNC
        if ($typesBuf -notcontains 1) {
            Write-Warning "VNC server does not offer 'None' auth. Available: $($typesBuf -join ', ')"
            $tcp.Dispose()
            return $null
        }
        $stream.WriteByte(1)

        # RFB 3.8: read SecurityResult (4 bytes big-endian, 0 = OK)
        $resultBuf = Read-VncBuffer -Stream $stream -Count 4
        [Array]::Reverse($resultBuf)
        $secResult = [BitConverter]::ToInt32($resultBuf, 0)
        if ($secResult -ne 0) {
            Write-Warning "VNC security handshake failed (result=$secResult)"
            $tcp.Dispose()
            return $null
        }

        # ClientInit: shared flag = 1 (allow other clients)
        $stream.WriteByte(1)

        # ServerInit: 2 (width) + 2 (height) + 16 (pixel format) + 4 (name len) = 24 fixed bytes
        $initBuf = Read-VncBuffer -Stream $stream -Count 24
        $nameLenBytes = $initBuf[20..23]
        [Array]::Reverse($nameLenBytes)
        $nameLen = [BitConverter]::ToInt32($nameLenBytes, 0)
        if ($nameLen -gt 0) {
            $nameBuf = Read-VncBuffer -Stream $stream -Count $nameLen
            Write-Debug "      VNC desktop: $([System.Text.Encoding]::UTF8.GetString($nameBuf))"
        }

        Write-Debug "      VNC connected to $VMName on port $Port"
        $script:CachedVnc   = $tcp
        $script:CachedVncVM = $VMName
        return $tcp
    } catch {
        Write-Debug "      VNC connection to port $Port failed: $_"
        if ($tcp) { try { $tcp.Dispose() } catch { Write-Debug "      VNC dispose error: $_" } }
        return $null
    }
}

function Disconnect-VNC {
    if ($script:CachedVnc) {
        try { $script:CachedVnc.Dispose() } catch { Write-Debug "      VNC disconnect error: $_" }
        $script:CachedVnc   = $null
        $script:CachedVncVM = $null
    }
}

function Send-VncKeyEvent {
    param([System.Net.Sockets.TcpClient]$Client, [int]$KeySym, [bool]$Down)
    # RFB KeyEvent message (8 bytes):
    # [1: type=4] [1: down-flag] [2: padding] [4: X11 keysym big-endian]
    $msg = [byte[]]::new(8)
    $msg[0] = 4
    $msg[1] = if ($Down) { 1 } else { 0 }
    $msg[4] = [byte](($KeySym -shr 24) -band 0xFF)
    $msg[5] = [byte](($KeySym -shr 16) -band 0xFF)
    $msg[6] = [byte](($KeySym -shr 8)  -band 0xFF)
    $msg[7] = [byte]($KeySym -band 0xFF)
    $Client.GetStream().Write($msg, 0, 8)
}

function Send-KeyVNC {
    param([string]$VMName, [string]$KeyName, [int]$Port = $script:DefaultVncPort)
    $keySym = $script:X11KeySyms[$KeyName]
    if (-not $keySym) { Write-Warning "Unknown VNC key '$KeyName'"; return $false }
    $tcp = Connect-VNC -VMName $VMName -Port $Port
    if (-not $tcp) { return $false }
    try {
        Send-VncKeyEvent -Client $tcp -KeySym $keySym -Down $true
        Send-VncKeyEvent -Client $tcp -KeySym $keySym -Down $false
        Write-Debug "      VNC key='$KeyName' sym=0x$($keySym.ToString('X4'))"
        return $true
    } catch {
        Write-Warning "VNC key send failed: $_"
        Disconnect-VNC
        return $false
    }
}

function Send-TextVNC {
    param([string]$VMName, [string]$Text, [int]$CharDelayMs = $script:DefaultCharDelayMs,
          [int]$Port = $script:DefaultVncPort)
    $tcp = Connect-VNC -VMName $VMName -Port $Port
    if (-not $tcp) { return $false }
    Write-Debug "      VNC text send: $($Text.Length) chars, charDelay=${CharDelayMs}ms"
    try {
        $shiftSym = $script:X11KeySyms["LShift"]
        foreach ($ch in $Text.ToCharArray()) {
            $entry = $script:X11CharKeySyms["$ch"]
            if (-not $entry) {
                Write-Warning "No VNC keysym for character '$ch'. Skipping."
                continue
            }
            $keySym  = $entry[0]
            $shifted = $entry[1]
            if ($shifted) {
                Send-VncKeyEvent -Client $tcp -KeySym $shiftSym -Down $true
                Start-Sleep -Milliseconds 20
            }
            Send-VncKeyEvent -Client $tcp -KeySym $keySym -Down $true
            Send-VncKeyEvent -Client $tcp -KeySym $keySym -Down $false
            if ($shifted) {
                Start-Sleep -Milliseconds 10
                Send-VncKeyEvent -Client $tcp -KeySym $shiftSym -Down $false
            }
            if ($CharDelayMs -gt 0) { Start-Sleep -Milliseconds $CharDelayMs }
        }
        Write-Debug "      VNC text send complete"
        return $true
    } catch {
        Write-Warning "VNC text send failed: $_"
        Disconnect-VNC
        return $false
    }
}

# ── AXUIElement keystroke transport (Accessibility API) ─────────────────────
# NOT USED in the dispatcher chain. Kept for reference/future use.
# AXUIElementPostKeyboardEvent targets UTM by PID and reports success, but
# UTM's SwiftUI VM display view does not route Accessibility keyboard events
# to the virtual machine's keyboard — keys silently vanish.
# If a future UTM version fixes this, re-enable in Send-Key/Send-Text.
# Uses the same macOS virtual key codes as the AppleScript/CGEvent functions.

function Send-KeyAXUI {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'VMName', Justification = 'Consistent API with Send-KeyHyperV/Send-KeyUTM')]
    param([string]$VMName, [string]$KeyName)
    $code = $script:UTMKeyMap[$KeyName]
    if (-not $code) { Write-Warning "Unknown key '$KeyName' for AXUI"; return $false }

    $jxaScript = @"
ObjC.import('ApplicationServices');
var utm = Application('UTM');
var pid = utm.id();
var axApp = $.AXUIElementCreateApplication(pid);
var err1 = $.AXUIElementPostKeyboardEvent(axApp, 0, $code, true);
delay(0.01);
var err2 = $.AXUIElementPostKeyboardEvent(axApp, 0, $code, false);
(err1 === 0 && err2 === 0) ? 'ok' : 'axui_error:' + err1 + ',' + err2;
"@

    $tmpFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "yuruna_axui_$([System.IO.Path]::GetRandomFileName()).js")
    try {
        [System.IO.File]::WriteAllText($tmpFile, $jxaScript)
        $result = & osascript -l JavaScript $tmpFile 2>&1
    } finally {
        Remove-Item $tmpFile -ErrorAction SilentlyContinue
    }
    Write-Debug "      AXUI key='$KeyName' code=$code result=$result"
    return ("$result" -eq "ok")
}

function Send-TextAXUI {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'VMName', Justification = 'Consistent API with Send-TextHyperV/Send-TextUTM')]
    param([string]$VMName, [string]$Text, [int]$CharDelayMs = $script:DefaultCharDelayMs)
    $delaySec = [math]::Max(0.02, $CharDelayMs / 1000.0)

    Write-Debug "      AXUI text send: $($Text.Length) chars, charDelay=${CharDelayMs}ms"
    $charIndex = 0
    $keyCalls = [System.Text.StringBuilder]::new()
    foreach ($ch in $Text.ToCharArray()) {
        $entry = $script:MacCharKeyCodes["$ch"]
        if (-not $entry) {
            Write-Warning "No macOS key code for character '$ch' (index $charIndex). Skipping."
            $charIndex++
            continue
        }
        $kc = $entry[0]
        $shifted = $entry[1] ? "true" : "false"
        [void]$keyCalls.AppendLine("    sendKey($kc, $shifted);")
        $charIndex++
    }

    $jxaTemplate = @'
ObjC.import('ApplicationServices');
var utm = Application('UTM');
var pid = utm.id();
var axApp = $.AXUIElementCreateApplication(pid);
var kShiftKeyCode = 56;

function sendKey(keyCode, shift) {
    if (shift) {
        $.AXUIElementPostKeyboardEvent(axApp, 0, kShiftKeyCode, true);
        delay(0.02);
    }
    $.AXUIElementPostKeyboardEvent(axApp, 0, keyCode, true);
    delay(0.01);
    $.AXUIElementPostKeyboardEvent(axApp, 0, keyCode, false);
    if (shift) {
        delay(0.02);
        $.AXUIElementPostKeyboardEvent(axApp, 0, kShiftKeyCode, false);
    }
    delay(__DELAY__);
}
__KEYCALLS__
'ok';
'@

    $jxaScript = $jxaTemplate -replace '__DELAY__', $delaySec `
                              -replace '__KEYCALLS__', $keyCalls.ToString()

    $tmpFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "yuruna_axui_$([System.IO.Path]::GetRandomFileName()).js")
    try {
        [System.IO.File]::WriteAllText($tmpFile, $jxaScript)
        $result = & osascript -l JavaScript $tmpFile 2>&1
    } finally {
        Remove-Item $tmpFile -ErrorAction SilentlyContinue
    }
    Write-Debug "      AXUI text: $result"
    return ("$result" -eq "ok")
}

# ── Hyper-V scan code helper ────────────────────────────────────────────────

function Send-ScanCode {
    param($Keyboard, [byte[]]$Codes)
    $r = Invoke-CimMethod -InputObject $Keyboard -MethodName "TypeScancodes" -Arguments @{Scancodes=$Codes}
    return ($r.ReturnValue -eq 0)
}

# ── Action: key ──────────────────────────────────────────────────────────────

function Send-KeyHyperV {
    param([string]$VMName, [string]$KeyName)
    $scanCode = $script:PS2ScanCodes[$KeyName]
    if (-not $scanCode) { Write-Warning "Unknown key '$KeyName' for Hyper-V"; return $false }
    $kb = Get-HyperVKeyboard -VMName $VMName
    if (-not $kb) { return $false }
    try {
        # Send make + break (press + release) as raw PS/2 scan codes
        [byte[]]$codes = @([byte]$scanCode, [byte]($scanCode -bor 0x80))
        $ok = Send-ScanCode -Keyboard $kb -Codes $codes
        Write-Debug "      TypeScancodes key='$KeyName' scan=0x$($scanCode.ToString('X2')) ok=$ok"
        return $ok
    } catch {
        Write-Warning "Hyper-V TypeScancodes failed: $_"
        return $false
    }
}

function Send-KeyUTM {
    param([string]$VMName, [string]$KeyName)
    $code = $script:UTMKeyMap[$KeyName]
    if (-not $code) { Write-Warning "Unknown key '$KeyName' for UTM"; return $false }
    if ($KeyName -eq "Enter") { $keyAction = 'keystroke return' }
    else                      { $keyAction = "key code $code" }
    $safeVMName = $VMName -replace '\\', '\\\\' -replace '"', '\\"'
    $appleScript = @"
tell application "UTM" to activate
delay 0.5
tell application "System Events"
    tell process "UTM"
        set frontmost to true
        repeat with w in windows
            if name of w contains "$safeVMName" then
                perform action "AXRaise" of w
                delay 0.5
                $keyAction
                return "ok"
            end if
        end repeat
    end tell
end tell
return "window_not_found"
"@
    $tmpFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "yuruna_utm_$([System.IO.Path]::GetRandomFileName()).applescript")
    try {
        [System.IO.File]::WriteAllText($tmpFile, $appleScript)
        $result = & osascript $tmpFile 2>&1
    } finally {
        Remove-Item $tmpFile -ErrorAction SilentlyContinue
    }
    Write-Debug "      AppleScript: $result"
    return ("$result" -eq "ok")
}

function Send-Key {
    param([string]$HostType, [string]$VMName, [string]$KeyName)
    if ($HostType -eq "host.windows.hyper-v") { return Send-KeyHyperV -VMName $VMName -KeyName $KeyName }
    elseif ($HostType -eq "host.macos.utm") {
        # Try VNC first (QEMU VMs with built-in VNC server), then AppleScript/CGEvent.
        # Note: AXUIElementPostKeyboardEvent was tested but UTM's SwiftUI VM display
        # does not route Accessibility keyboard events to the virtual machine — it
        # reports success but the keys never reach the guest OS.
        $vncOk = Send-KeyVNC -VMName $VMName -KeyName $KeyName
        if ($vncOk) { return $true }
        Write-Debug "      VNC unavailable for key, falling back to AppleScript"
        return Send-KeyUTM -VMName $VMName -KeyName $KeyName
    }
    else { Write-Warning "Unknown host: $HostType"; return $false }
}

# ── Action: type / typeAndEnter ──────────────────────────────────────────────

function Send-TextHyperV {
    param([string]$VMName, [string]$Text, [int]$CharDelayMs = $script:DefaultCharDelayMs)
    $kb = Get-HyperVKeyboard -VMName $VMName
    if (-not $kb) { return $false }
    try {
        # Send each character individually with a delay between them
        # to avoid overwhelming the VM's keyboard buffer.
        # For shifted characters: LShift-down, char-down, char-up, LShift-up.
        $charCount = 0
        foreach ($ch in $Text.ToCharArray()) {
            $entry = $script:CharScanCodes["$ch"]
            if (-not $entry) {
                Write-Warning "No scan code for character '$ch' (0x$([byte][char]$ch | ForEach-Object { $_.ToString('X2') })). Skipping."
                continue
            }
            $scan = [byte]$entry[0]
            $shifted = $entry[1]
            $codeList = [System.Collections.Generic.List[byte]]::new()
            if ($shifted) { $codeList.Add(0x2A) }            # LShift make
            $codeList.Add($scan)                              # char make
            $codeList.Add([byte]($scan -bor 0x80))            # char break
            if ($shifted) { $codeList.Add(0xAA) }            # LShift break
            $ok = Send-ScanCode -Keyboard $kb -Codes ([byte[]]$codeList.ToArray())
            if (-not $ok) {
                Write-Warning "Hyper-V TypeScancodes failed at char '$ch'"
                return $false
            }
            $charCount++
            if ($CharDelayMs -gt 0) { Start-Sleep -Milliseconds $CharDelayMs }
        }
        Write-Debug "      TypeScancodes: $charCount chars sent (${CharDelayMs}ms delay between chars)"
        return $true
    } catch {
        Write-Warning "Hyper-V TypeScancodes (text) failed: $_"
        return $false
    }
}

function Send-TextUTM {
    param([string]$VMName, [string]$Text, [int]$CharDelayMs = $script:DefaultCharDelayMs)
    # UTM's Apple Virtualization backend ignores modifier FLAGS on CGEvents
    # and AppleScript key events. It only sees physical key state.
    # Fix: send Left Shift (key code 56) as its own CGEvent key-down/up
    # around each shifted character, simulating physical shift press.
    $delaySec = [math]::Max(0.02, $CharDelayMs / 1000.0)

    Write-Debug "      UTM text send: $($Text.Length) chars, charDelay=${CharDelayMs}ms"
    $charIndex = 0
    $shiftedCount = 0
    $keyCalls = [System.Text.StringBuilder]::new()
    foreach ($ch in $Text.ToCharArray()) {
        $entry = $script:MacCharKeyCodes["$ch"]
        if (-not $entry) {
            Write-Warning "No macOS key code for character '$ch' (index $charIndex). Skipping."
            $charIndex++
            continue
        }
        $kc = $entry[0]
        $shifted = $entry[1] ? "true" : "false"
        if ($entry[1]) { $shiftedCount++ }
        [void]$keyCalls.AppendLine("    sendKey($kc, $shifted);")
        $charIndex++
    }
    Write-Debug "      UTM chars: $charIndex total, $shiftedCount shifted"

    # JXA script: physical shift key simulation via CGEvent.
    # Key code 56 = Left Shift on macOS. We press it down, send the char,
    # then release it — mimicking what a real keyboard does.
    $jxaTemplate = @'
ObjC.import('CoreGraphics');

var se = Application('System Events');
var utm = Application('UTM');
utm.activate();
delay(0.3);
var proc = se.processes['UTM'];
proc.frontmost = true;
var wins = proc.windows();
var found = false;
for (var i = 0; i < wins.length; i++) {
    if (wins[i].name().indexOf('__VMNAME__') >= 0) {
        wins[i].actions['AXRaise'].perform();
        found = true;
        break;
    }
}
if (!found) {
    'window_not_found';
} else {
    delay(0.3);
    var kShiftKeyCode = 56;  // Left Shift physical key
    var kShiftFlag    = 0x00020000;  // kCGEventFlagMaskShift

    function sendKey(keyCode, shift) {
        if (shift) {
            // Press physical Left Shift key down.
            // Apple Virtualization Framework ignores CGEvent modifier flags and
            // only sees physical key state, so we must wait long enough for VF
            // to register the shift before sending the character key.
            var shiftDn = $.CGEventCreateKeyboardEvent(null, kShiftKeyCode, true);
            $.CGEventSetFlags(shiftDn, kShiftFlag);
            $.CGEventPost(0, shiftDn);
            delay(0.08);

            // Press character key (with shift flag set on the event too)
            var down = $.CGEventCreateKeyboardEvent(null, keyCode, true);
            $.CGEventSetFlags(down, kShiftFlag);
            $.CGEventPost(0, down);
            delay(0.02);
            var up = $.CGEventCreateKeyboardEvent(null, keyCode, false);
            $.CGEventSetFlags(up, kShiftFlag);
            $.CGEventPost(0, up);
            delay(0.06);

            // Release physical Left Shift key
            var shiftUp = $.CGEventCreateKeyboardEvent(null, kShiftKeyCode, false);
            $.CGEventPost(0, shiftUp);
            delay(0.02);
        } else {
            var down = $.CGEventCreateKeyboardEvent(null, keyCode, true);
            $.CGEventPost(0, down);
            delay(0.01);
            var up = $.CGEventCreateKeyboardEvent(null, keyCode, false);
            $.CGEventPost(0, up);
        }
        delay(__DELAY__);
    }
__KEYCALLS__
    // Final drain: give the macOS event queue time to deliver the last
    // CGEvent(s) to Apple Virtualization Framework before osascript exits.
    // Without this, the last character(s) can be lost on long commands.
    delay(0.3);
    'ok';
}
'@
    $safeJxaVMName = $VMName -replace '\\', '\\\\' -replace "'", "\'"
    $jxaScript = $jxaTemplate -replace '__VMNAME__', $safeJxaVMName `
                              -replace '__DELAY__', $delaySec `
                              -replace '__KEYCALLS__', $keyCalls.ToString()

    $tmpFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "yuruna_utm_$([System.IO.Path]::GetRandomFileName()).js")
    try {
        [System.IO.File]::WriteAllText($tmpFile, $jxaScript)
        $result = & osascript -l JavaScript $tmpFile 2>&1
    } finally {
        Remove-Item $tmpFile -ErrorAction SilentlyContinue
    }
    Write-Debug "      JXA CGEvent: $result"
    return ("$result" -eq "ok")
}

function Send-Text {
    param([string]$HostType, [string]$VMName, [string]$Text, [int]$CharDelayMs = $script:DefaultCharDelayMs)
    if ($HostType -eq "host.windows.hyper-v") { return Send-TextHyperV -VMName $VMName -Text $Text -CharDelayMs $CharDelayMs }
    elseif ($HostType -eq "host.macos.utm") {
        # Try VNC first (QEMU VMs with built-in VNC server), then JXA/CGEvent.
        $vncOk = Send-TextVNC -VMName $VMName -Text $Text -CharDelayMs $CharDelayMs
        if ($vncOk) { return $true }
        Write-Debug "      VNC unavailable for text, falling back to JXA/CGEvent"
        return Send-TextUTM -VMName $VMName -Text $Text -CharDelayMs $CharDelayMs
    }
    else { Write-Warning "Unknown host: $HostType"; return $false }
}


# ── OCR-tolerant matching ────────────────────────────────────────────────────

# Common OCR confusion groups: characters within each group are frequently
# misrecognized as each other on console/monospace text.
# Sources: WinRT/Vision observed errors, UNLV OCR accuracy studies.
$script:OCRConfusionGroups = @(
    'wuv'       # w↔u↔v — most common on console fonts
    'mn'        # m↔n
    'oO0'       # o↔O↔0
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
$script:OCRStripChars = [System.Collections.Generic.HashSet[char]]::new(
    [char[]]@(
        '-', [char]0x2014, [char]0x2013, [char]0x2012,  # -, —, –, ‒
        '@', '[', ']', '$', '~', '"', '`'               # terminal prompt chars frequently dropped by OCR
    )
)

# Build canonical lookup: char → canonical lowercase representative of its group.
# Used by Test-OCRMatch to normalize both pattern and text before comparison.
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
    $normPattern = Get-OCRNormalized $Pattern
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
        $patternCharSet = [System.Collections.Generic.HashSet[char]]::new([char[]]$patternChars)
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
            $normSeg = Get-OCRNormalized $seg
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
        Runs all enabled OCR engines on a processed image, tests each engine's text
        against every pattern, and returns $true/$false based on the combine mode.

    .DESCRIPTION
        For each enabled OCR engine:
          1. Run OCR on ProcessedImagePath → engine text
          2. For each pattern, test engine text → boolean
        Collect a boolean per engine (true if ANY pattern matched that engine's text).

        Combine mode (Or/And) controls how the per-engine booleans are merged:
          Or  → $true if at least one engine detected any pattern
          And → $true only if every engine detected at least one pattern

    .PARAMETER ProcessedImagePath
        Path to the preprocessed image (output of Get-ProcessedScreenImage).

    .PARAMETER TextToTest
        The text to test patterns against. For multi-engine mode this is ignored
        in favor of per-engine OCR results. When only one engine is enabled this
        can be used as a shortcut (pass the already-extracted text).

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
        [Parameter(Mandatory)] [string]$ProcessedImagePath,
        [Parameter(Mandatory)] [string[]]$Pattern,
        [int]$FreshMatchTailLines = 0
    )

    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    Import-Module (Join-Path $modulesDir "Test.OcrEngine.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false

    $combineMode = Get-OcrCombineMode
    $enabledProviders = Get-EnabledOcrProvider
    $engineResults = [ordered]@{}
    $combinedMatch = $false
    $allTexts = @()

    # Run OCR engines sequentially, short-circuiting based on combine mode:
    #   Or  — stop on first detection (true)
    #   And — stop on first non-detection (false)
    foreach ($engineName in $enabledProviders) {
        try {
            $engineText = (Invoke-OcrProvider -Name $engineName -ImagePath $ProcessedImagePath) ?? ''
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

# ── Action: waitForAndClickButton — OCR-located mouse click ─────────────────
#
# Button-focus navigation via Tab keystrokes is brittle: initial focus depends
# on splash animation state, async-loaded widgets, and installer redesigns,
# so the "correct" Tab count drifts. waitForAndClickButton sidesteps focus
# entirely — it OCRs the VM screen, locates the button's bounding box, and
# synthesizes a mouse click at that box's centre.
#
# Coordinate contract: the captured image and the click target share the
# same pixel space. On Hyper-V we use PrintWindow on the vmconnect client
# area so image (x,y) == vmconnect client (x,y), and ClientToScreen maps
# it to a SetCursorPos + mouse_event sequence.

function Initialize-HyperVMouseType {
    if ('HyperVMouse' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class HyperVMouse {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int  GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT pt);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT pt);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, IntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }

    const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    const uint MOUSEEVENTF_LEFTUP   = 0x0004;

    static bool dpiAware = false;
    public static void EnsureDpiAware() {
        if (!dpiAware) { SetProcessDPIAware(); dpiAware = true; }
    }

    public static IntPtr FindWindow(string titleContains) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, lp) => {
            if (!IsWindowVisible(hWnd)) return true;
            var sb = new StringBuilder(256);
            GetWindowText(hWnd, sb, 256);
            if (sb.ToString().Contains(titleContains)) { found = hWnd; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Translate a client-area point to screen coordinates, for debug logging
    // and diagnostics that need to report where a click actually landed.
    // Returns null if the translation fails (e.g. invalid window handle).
    public static int[] GetScreenPoint(IntPtr hWnd, int clientX, int clientY) {
        EnsureDpiAware();
        POINT pt = new POINT(); pt.X = clientX; pt.Y = clientY;
        if (!ClientToScreen(hWnd, ref pt)) return null;
        return new int[] { pt.X, pt.Y };
    }

    // Left-click at a client-area pixel (clientX, clientY) inside hWnd.
    // Restores the host cursor afterwards so the operator's mouse isn't
    // "stolen" mid-test. Returns false if the window cannot be targeted.
    public static bool ClickClientPoint(IntPtr hWnd, int clientX, int clientY) {
        EnsureDpiAware();
        POINT origin; GetCursorPos(out origin);
        // Non-fatal: foreground may be refused if another window holds focus
        // lock (e.g. another input-receiving app just got activated). The
        // click still lands if vmconnect accepts mouse events while inactive.
        SetForegroundWindow(hWnd);
        System.Threading.Thread.Sleep(80);
        POINT pt = new POINT(); pt.X = clientX; pt.Y = clientY;
        if (!ClientToScreen(hWnd, ref pt)) return false;
        if (!SetCursorPos(pt.X, pt.Y)) return false;
        System.Threading.Thread.Sleep(40);
        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, IntPtr.Zero);
        System.Threading.Thread.Sleep(30);
        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, IntPtr.Zero);
        System.Threading.Thread.Sleep(50);
        SetCursorPos(origin.X, origin.Y);
        return true;
    }
}
"@
}

function Send-ClickHyperV {
    param([string]$VMName, [int]$X, [int]$Y)
    if (-not $IsWindows) {
        Write-Warning "Send-ClickHyperV called on non-Windows host."
        return $false
    }
    Initialize-HyperVMouseType
    $hWnd = [HyperVMouse]::FindWindow($VMName)
    if ($hWnd -eq [IntPtr]::Zero) {
        Write-Warning "vmconnect window not found for '$VMName'. Click requires an open vmconnect session."
        return $false
    }
    # Pre-compute screen-space target so debug_mode can report where the
    # click was actually dispatched, not just where we think the button is.
    $screenPoint = [HyperVMouse]::GetScreenPoint($hWnd, $X, $Y)
    $ok = [HyperVMouse]::ClickClientPoint($hWnd, $X, $Y)
    if ($screenPoint) {
        Write-Debug "      Hyper-V click at client ($X, $Y) -> screen ($($screenPoint[0]), $($screenPoint[1])) ok=$ok"
    } else {
        Write-Debug "      Hyper-V click at client ($X, $Y) screen=<ClientToScreen failed> ok=$ok"
    }
    return $ok
}

function Send-Click {
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
    if ($HostType -eq "host.windows.hyper-v") { return Send-ClickHyperV -VMName $VMName -X $X -Y $Y }
    elseif ($HostType -eq "host.macos.utm") { return Send-ClickUtm -X $X -Y $Y -Capture $Capture }
    else { Write-Warning "Unknown host for Send-Click: $HostType"; return $false }
}

function Send-ClickUtm {
    <#
    .SYNOPSIS
        Dispatches a left-click at (X, Y) in the UTM VM window's image
        coordinate space.
    .DESCRIPTION
        X/Y arrive in PNG pixel coords (what Tesseract reports). The capture
        hashtable carries the window's screen-point origin and the backing
        scale factor so we can map image pixels -> screen points:
            screenX = OriginX + X / Scale
            screenY = OriginY + Y / Scale
        kCGWindowBounds (source of OriginX/OriginY) and CGEventPost both use
        the same global screen-point coordinate space (origin top-left of the
        main display), so no axis flip is needed.

        Requires Accessibility permission for the invoking process. Without
        it CGEventPost silently drops clicks — we probe once per session and
        warn loudly so the operator doesn't chase a phantom OCR bug.
    #>
    param(
        [int]$X,
        [int]$Y,
        [hashtable]$Capture = $null
    )
    if (-not $IsMacOS) {
        Write-Warning "Send-ClickUtm called on non-macOS host."
        return $false
    }
    if (-not $Capture -or
        -not $Capture.ContainsKey('OriginX') -or
        -not $Capture.ContainsKey('OriginY') -or
        -not $Capture.ContainsKey('Scale')   -or
        [double]$Capture.Scale -le 0) {
        Write-Warning "Send-ClickUtm requires a -Capture hashtable with OriginX / OriginY / Scale (from Get-UtmWindowScreenshot)."
        return $false
    }

    $originX = [double]$Capture.OriginX
    $originY = [double]$Capture.OriginY
    $scale   = [double]$Capture.Scale
    $screenX = [int][math]::Round($originX + ($X / $scale))
    $screenY = [int][math]::Round($originY + ($Y / $scale))
    Write-Debug "      UTM click: image ($X, $Y) scale=$scale origin=($originX, $originY) -> screen ($screenX, $screenY)"

    # Bring UTM to the front before clicking. Some GNOME / GTK widgets only
    # respond to input when the host window is key; `activate` is a no-op
    # when UTM already has focus.
    & osascript -e 'tell application "UTM" to activate' 2>&1 | Out-Null

    # One-time Accessibility permission probe. AXIsProcessTrusted() returns
    # false without prompting the user (we don't want a dialog popping up
    # mid-test run). If denied, the first click-by-OCR call surfaces the
    # fix instructions clearly; subsequent calls short-circuit.
    if (-not $script:YurunaAxChecked) {
        $script:YurunaAxChecked = $true
        $axResult = & osascript -l JavaScript -e @'
ObjC.import('ApplicationServices');
$.AXIsProcessTrusted() ? 'yes' : 'no';
'@ 2>&1
        if ("$axResult".Trim() -ne 'yes') {
            Write-Warning "Accessibility permission not granted for this terminal — CGEventPost clicks will be silently dropped."
            Write-Warning "  System Settings > Privacy & Security > Accessibility > enable your terminal"
            Write-Warning "  Then restart the terminal and re-run the test."
            $script:YurunaAxWorks = $false
        } else {
            $script:YurunaAxWorks = $true
        }
    }
    if ($script:YurunaAxWorks -eq $false) { return $false }

    # Synthesize move + down + up. The move event ensures hover-triggered
    # widgets (tooltips, hover-highlight buttons) settle on the target
    # before the mousedown, matching a real user's cursor motion. Without
    # the move some GTK buttons in GDM 46 ignore the first mousedown.
    $clickScript = @"
ObjC.import('CoreGraphics');
var pt = { x: __X__, y: __Y__ };
var mv = `$.CGEventCreateMouseEvent(null, `$.kCGEventMouseMoved,   pt, `$.kCGMouseButtonLeft);
var dn = `$.CGEventCreateMouseEvent(null, `$.kCGEventLeftMouseDown, pt, `$.kCGMouseButtonLeft);
var up = `$.CGEventCreateMouseEvent(null, `$.kCGEventLeftMouseUp,   pt, `$.kCGMouseButtonLeft);
`$.CGEventPost(`$.kCGHIDEventTap, mv);
`$.CGEventPost(`$.kCGHIDEventTap, dn);
`$.CGEventPost(`$.kCGHIDEventTap, up);
'ok';
"@
    $clickScript = ($clickScript -replace '__X__', $screenX) -replace '__Y__', $screenY
    $clickResult = & osascript -l JavaScript -e $clickScript 2>&1
    if ($LASTEXITCODE -ne 0 -or "$clickResult".Trim() -ne 'ok') {
        Write-Warning "osascript CGEventPost failed: $clickResult"
        return $false
    }
    return $true
}

<#
.SYNOPSIS
    Runs OCR on an image, finds the bounding box of a button-label pattern,
    and returns its coordinates in the image's pixel space.
.DESCRIPTION
    Uses Tesseract TSV mode (word-level boxes) because TSV boxes are
    directly consumable — Vision / WinRT don't surface per-word coords in
    our existing shims. For multi-word labels, requires contiguous words
    on the same line (y-diff within half a word height). Matching is
    case-insensitive substring so low-confidence words ("lnstall") still
    resolve.
.OUTPUTS
    Hashtable @{ x; y; w; h; centerX; centerY; text } or $null if not found.
#>
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
    Waits for a labelled button to appear on the VM screen and clicks it.
.DESCRIPTION
    Loops: capture the VM window at the host's coordinate space, OCR for
    the label, and if found, click at the label's centre. Falls back to
    returning $false after TimeoutSeconds if the button never resolves
    (caller can then decide to send Tab+Enter as a legacy fallback).
.OUTPUTS
    $true on click dispatched, $false on timeout / unsupported host.
#>
function Wait-ForAndClickButton {
    param(
        [string]$HostType,
        [string]$VMName,
        [string[]]$Label,
        [int]$TimeoutSeconds = 120,
        [int]$PollSeconds = 5,
        [int]$OffsetX = 0,
        [int]$OffsetY = 0
    )
    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    Import-Module (Join-Path $modulesDir "Test.Screenshot.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false
    Import-Module (Join-Path $modulesDir "Test.LogDir.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false

    $logDir = Initialize-YurunaLogDir
    $capturePath = Join-Path $logDir "clickbutton_${VMName}.png"
    # Avoid '|' as the join separator — Write-ProgressTick's marker uses '|'
    # as its field delimiter, and embedding one here would shift parsing on the
    # parent side. Write-ProgressTick sanitizes defensively, but keep the
    # display clean at the source too.
    $labelDisplay = $Label -join "' / '"
    $elapsed = 0

    try {
        while ($elapsed -lt $TimeoutSeconds) {
            $pct = [math]::Min(100, [math]::Round(($elapsed / [math]::Max($TimeoutSeconds,1)) * 100))
            Write-ProgressTick -Activity "waitForAndClickButton" -Status "'$labelDisplay' (${elapsed}s / ${TimeoutSeconds}s)" -PercentComplete $pct

            Remove-Item $capturePath -Force -ErrorAction SilentlyContinue
            $capture = Get-VMWindowScreenshot -HostType $HostType -VMName $VMName -OutputPath $capturePath
            if (-not $capture) {
                Write-Debug "      Window capture unavailable — retrying"
                Start-Sleep -Seconds $PollSeconds
                $elapsed += $PollSeconds
                continue
            }

            foreach ($candidate in $Label) {
                $coord = Find-TextLocation -ImagePath $capture.ImagePath -Label $candidate
                if ($coord) {
                    $clickX = $coord.centerX + $OffsetX
                    $clickY = $coord.centerY + $OffsetY
                    Write-Debug "      Found '$candidate' at ($($coord.x),$($coord.y)) $($coord.w)x$($coord.h) → click ($clickX, $clickY)"
                    # debug_mode: preserve a per-detection screenshot under a UTC
                    # timestamp so the operator can correlate a stuck installer
                    # with exactly what OCR saw and where we aimed the click.
                    if ($env:YURUNA_DEBUG -eq '1') {
                        $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
                        $stampedPath = Join-Path $logDir "waitForAndClickButton.$stamp.png"
                        Save-ScreenshotWithClickMarker -SourcePath $capture.ImagePath -DestPath $stampedPath -X $clickX -Y $clickY | Out-Null
                        Write-Debug "      debug_mode: saved detection screenshot $stampedPath"
                        Write-Debug "      debug_mode: button '$candidate' box=($($coord.x),$($coord.y)) size=$($coord.w)x$($coord.h) click=($clickX, $clickY) offset=($OffsetX, $OffsetY) image=$($capture.Width)x$($capture.Height)"
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
            $elapsed += $PollSeconds
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
        Write-ProgressTick -Activity "waitForAndClickButton" -Completed
    }
}

# ── Action: waitForText ──────────────────────────────────────────────────────

function Wait-ForText {
    param(
        [string]$HostType,
        [string]$VMName,
        [string[]]$Pattern,
        [int]$TimeoutSeconds = 120,
        [int]$PollSeconds = 5,
        [bool]$FreshMatch = $false,
        [int]$FreshMatchTailLines = 12,
        [int]$ResetAfterMisses = 2,
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

    # Display label uses first pattern for log messages
    $patternLabel = $Pattern[0]
    $elapsed = 0

    # Import required modules (Screenshot for capture, Get-NewText for diff-based OCR, OcrEngine for multi-engine)
    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    Import-Module (Join-Path $modulesDir "Test.Screenshot.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false
    Import-Module (Join-Path $modulesDir "Get-NewText.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false
    Import-Module (Join-Path $modulesDir "Test.OcrEngine.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false

    # Log which OCR engines are active for this wait
    $enabledEngines = Get-EnabledOcrProvider
    $combineMode = Get-OcrCombineMode
    Write-Debug "      OCR engines: $($enabledEngines -join ', ') | combine: $combineMode"

    # Rolling screenshot window: current and previous screen paths
    Import-Module (Join-Path $modulesDir "Test.LogDir.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false
    $logDir = Initialize-YurunaLogDir
    $currentScreenPath  = Join-Path $logDir "waittext_${VMName}_current.png"
    $previousScreenPath = Join-Path $logDir "waittext_${VMName}_previous.png"

    # Clean up any stale files from a prior run
    Remove-Item $currentScreenPath  -Force -ErrorAction SilentlyContinue
    Remove-Item $previousScreenPath -Force -ErrorAction SilentlyContinue

    # Previous screen intentionally absent on first iteration → all pixels are new.

    # Accumulate all seen text for non-FreshMatch mode (per-engine text merged)
    $allText = ''
    $consecutiveMisses = 0
    $lastOcrText = ''

    try {
        while ($elapsed -lt $TimeoutSeconds) {
            # PROGRESS-INLINE-TICK: reference impl lives in "delay"
            $pct = [math]::Min(100, [math]::Round(($elapsed / [math]::Max($TimeoutSeconds,1)) * 100))
            Write-ProgressTick -Activity "waitForText" -Status "'$patternLabel' (${elapsed}s / ${TimeoutSeconds}s)" -PercentComplete $pct
            # Capture the VM screen — this becomes the "current screen"
            $captured = Get-VMScreenshot -HostType $HostType -VMName $VMName -OutputPath $currentScreenPath
            if (-not $captured -or -not (Test-Path $currentScreenPath)) {
                $elapsed += $PollSeconds
                Write-Debug "      Waiting for text '$patternLabel'... (${elapsed}s / ${TimeoutSeconds}s)"
                Start-Sleep -Seconds $PollSeconds
                continue
            }

            # Process the image (diff current vs previous, preprocess for OCR).
            # Returns the path to the preprocessed image, or empty string if no changes.
            try {
                $prevArg = (Test-Path $previousScreenPath) ? $previousScreenPath : $null
                $processedPath = Get-ProcessedScreenImage -CurrentScreenPath $currentScreenPath -PreviousScreenPath $prevArg
            } catch {
                Write-Verbose "Get-ProcessedScreenImage failed (dimension mismatch?): $_"
                # Reset rolling window on error (e.g. VM resize)
                Remove-Item $previousScreenPath -Force -ErrorAction SilentlyContinue
                $processedPath = $null
            }

            if ($processedPath) {
                $consecutiveMisses = 0

                if ($FreshMatch) {
                    # ── FreshMatch mode ──
                    if ($prevArg) {
                        # Run all engines on the processed image, test last N lines only
                        $result = Test-CombinedOcrMatch -ProcessedImagePath $processedPath -Pattern $Pattern -FreshMatchTailLines $FreshMatchTailLines

                        # Log per-engine results
                        foreach ($eName in $result.EngineResults.Keys) {
                            $er = $result.EngineResults[$eName]
                            $snippet = $er.Text.Length -le 120 ? $er.Text : ("..." + $er.Text.Substring($er.Text.Length - 120))
                            $status = $er.Matched ? "MATCH '$($er.MatchedPattern)'" : "no match"
                            Write-Debug "      [$eName] $status | $snippet"
                        }

                        # Track last OCR text for failure diagnostics
                        if ($result.AnyText) { $lastOcrText = $result.AnyText }

                        if ($result.Match) {
                            Write-Debug "      Text detected at end of screen (combine=$combineMode)"
                            return $true
                        }
                    } else {
                        # Baseline capture — run all engines, check full text
                        $result = Test-CombinedOcrMatch -ProcessedImagePath $processedPath -Pattern $Pattern

                        foreach ($eName in $result.EngineResults.Keys) {
                            $er = $result.EngineResults[$eName]
                            if ($er.Matched) {
                                Write-Debug "      [$eName] Pattern already present in baseline — match: '$($er.MatchedPattern)'"
                            }
                        }

                        # Track last OCR text for failure diagnostics
                        if ($result.AnyText) { $lastOcrText = $result.AnyText }

                        if ($result.Match) {
                            Write-Debug "      Pattern already present in baseline (combine=$combineMode)"
                            return $true
                        }
                        Write-Debug "      Baseline captured — waiting for screen to change and pattern to appear at end..."
                    }
                } else {
                    # ── Non-FreshMatch mode: accumulate text, check for pattern ──
                    $result = Test-CombinedOcrMatch -ProcessedImagePath $processedPath -Pattern $Pattern

                    # Log per-engine results
                    foreach ($eName in $result.EngineResults.Keys) {
                        $er = $result.EngineResults[$eName]
                        $snippet = $er.Text.Length -le 120 ? $er.Text : ("..." + $er.Text.Substring($er.Text.Length - 120))
                        $status = $er.Matched ? "MATCH '$($er.MatchedPattern)'" : "no match"
                        Write-Debug "      [$eName] $status | $snippet"
                    }

                    # Accumulate text and track last OCR output for failure diagnostics
                    if ($result.AnyText) {
                        $lastOcrText = $result.AnyText
                        $allText = ($allText + "`n" + $result.AnyText).Trim()
                    }

                    if ($result.Match) {
                        Write-Debug "      Text detected (combine=$combineMode)"
                        return $true
                    }

                    # Fallback: test accumulated text across all iterations against each engine's
                    # accumulated view (using the same combine logic). This handles patterns that
                    # span multiple poll cycles.
                    $accumulatedDetections = @()
                    foreach ($eName in $result.EngineResults.Keys) {
                        $found = $false
                        foreach ($p in $Pattern) {
                            if (Test-OCRMatch -Text $allText -Pattern $p) {
                                $found = $true
                                Write-Debug "      Text detected in accumulated text: '$p'"
                                break
                            }
                        }
                        $accumulatedDetections += $found
                    }
                    # If any accumulated detection matched, return true (accumulation is inherently OR across time)
                    if (($accumulatedDetections | Where-Object { $_ }).Count -gt 0) {
                        return $true
                    }
                }
            } else {
                $consecutiveMisses++
                if ($consecutiveMisses -ge $ResetAfterMisses) {
                    # Too many consecutive polls returned no new text — the previous
                    # screen may be identical to the current screen (timing issue).
                    # Reset the rolling window so the next diff sees all pixels as new.
                    Write-Debug "      No new text for $consecutiveMisses polls — resetting previous screen"
                    Remove-Item $previousScreenPath -Force -ErrorAction SilentlyContinue
                    Remove-Item $currentScreenPath -Force -ErrorAction SilentlyContinue
                    $consecutiveMisses = 0
                    # Skip the rolling-window move so the next iteration has no previous screen
                    $elapsed += $PollSeconds
                    Write-Debug "      Waiting for text '$patternLabel'... (${elapsed}s / ${TimeoutSeconds}s)"
                    Start-Sleep -Seconds $PollSeconds
                    continue
                }
            }

            # Anti-pattern (early-fail) check: abort the wait the moment
            # any FailurePattern fuzzy-matches the current frame. Runs
            # AFTER the positive-match check above (so a positive match
            # wins ties in the very rare case both appear on one screen)
            # and reuses Test-OCRMatch's normalized fuzzy compare so a
            # few OCR glitches don't mask the signature. Uses $lastOcrText
            # because that's the freshest OCR output from every branch
            # above, including the "no new pixels" path where the screen
            # hasn't changed since the last poll.
            if ($FailurePattern -and $FailurePattern.Count -gt 0 -and $lastOcrText) {
                foreach ($fp in $FailurePattern) {
                    if ([string]::IsNullOrWhiteSpace($fp)) { continue }
                    if (Test-OCRMatch -Text $lastOcrText -Pattern $fp) {
                        $script:WaitForTextMatchedFailurePattern = $fp
                        Write-Warning "      Failure pattern matched: '$fp' -- aborting wait early (elapsed ${elapsed}s / ${TimeoutSeconds}s)"
                        # Mirror the timeout path's artefact capture so
                        # the post-mortem has the same screenshot + OCR
                        # text whether we timed out or short-circuited.
                        $failScreenPath = Join-Path $logDir "failure_screenshot_${VMName}.png"
                        $failOcrPath    = Join-Path $logDir "failure_ocr_${VMName}.txt"
                        $lastScreenPath = if (Test-Path $currentScreenPath) { $currentScreenPath }
                                          elseif (Test-Path $previousScreenPath) { $previousScreenPath }
                                          else { $null }
                        if ($lastScreenPath) {
                            Copy-Item -Path $lastScreenPath -Destination $failScreenPath -Force -ErrorAction SilentlyContinue
                            Write-Information "      Failure screenshot saved: $failScreenPath"
                        }
                        Set-Content -Path $failOcrPath -Value $lastOcrText -Force -ErrorAction SilentlyContinue
                        Write-Information "      Failure OCR text saved: $failOcrPath"
                        return $false
                    }
                }
            }

            # Rolling window: move current → previous for next iteration
            if (Test-Path $currentScreenPath) {
                Move-Item -Path $currentScreenPath -Destination $previousScreenPath -Force
            }

            $elapsed += $PollSeconds
            Write-Debug "      Waiting for text '$patternLabel'... (${elapsed}s / ${TimeoutSeconds}s)"
            Start-Sleep -Seconds $PollSeconds
        }
        # Timeout — preserve last screenshot and OCR text for diagnostics
        $failScreenPath = Join-Path $logDir "failure_screenshot_${VMName}.png"
        $failOcrPath    = Join-Path $logDir "failure_ocr_${VMName}.txt"
        # Copy whichever screenshot file still exists (current first, then previous)
        $lastScreenPath = if (Test-Path $currentScreenPath) { $currentScreenPath }
                          elseif (Test-Path $previousScreenPath) { $previousScreenPath }
                          else { $null }
        if ($lastScreenPath) {
            Copy-Item -Path $lastScreenPath -Destination $failScreenPath -Force -ErrorAction SilentlyContinue
            Write-Information "      Failure screenshot saved: $failScreenPath"
        }
        if ($lastOcrText) {
            Set-Content -Path $failOcrPath -Value $lastOcrText -Force -ErrorAction SilentlyContinue
            Write-Information "      Failure OCR text saved: $failOcrPath"
        }

        Write-Warning "Text '$patternLabel' not found within ${TimeoutSeconds}s"
        return $false
    } finally {
        # Clean up temp screenshot files (failure copies already saved above)
        Remove-Item $currentScreenPath  -Force -ErrorAction SilentlyContinue
        Remove-Item $previousScreenPath -Force -ErrorAction SilentlyContinue
        Write-ProgressTick -Activity "waitForText" -Completed
    }
}

# ── Action: waitForPort ──────────────────────────────────────────────────────

function Wait-ForPort {
    param([string]$VMName, [int]$Port, [int]$TimeoutSeconds = 120)
    $elapsed = 0
    try {
        while ($elapsed -lt $TimeoutSeconds) {
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $async = $tcp.BeginConnect($VMName, $Port, $null, $null)
                $wait = $async.AsyncWaitHandle.WaitOne(2000, $false)
                if ($wait -and $tcp.Connected) { $tcp.Close(); Write-Debug "      Port $Port responding"; return $true }
                $tcp.Close()
            } catch { Write-Verbose "Port $Port connection attempt failed: $_" }
            Start-Sleep -Seconds 5
            $elapsed += 5
            Write-Debug "      Waiting for port $Port... (${elapsed}s / ${TimeoutSeconds}s)"
            # PROGRESS-INLINE-TICK: reference impl lives in "delay"
            $pct = [math]::Min(100, [math]::Round(($elapsed / [math]::Max($TimeoutSeconds,1)) * 100))
            Write-ProgressTick -Activity "waitForPort" -Status "${VMName}:${Port} (${elapsed}s / ${TimeoutSeconds}s)" -PercentComplete $pct
        }
        Write-Warning "Port $Port did not respond within ${TimeoutSeconds}s"
        return $false
    } finally {
        Write-ProgressTick -Activity "waitForPort" -Completed
    }
}

# ── Action: waitForHeartbeat ─────────────────────────────────────────────────

function Wait-ForHeartbeat {
    param([string]$VMName, [int]$TimeoutSeconds = 300)
    $elapsed = 0
    try {
        while ($elapsed -lt $TimeoutSeconds) {
            try {
                $hb = Get-VMIntegrationService -VMName $VMName -Name "Heartbeat" -ErrorAction SilentlyContinue
                if ($hb -and $hb.PrimaryStatusDescription -eq "OK") {
                    Write-Debug "      Heartbeat OK"; return $true
                }
            } catch { Write-Verbose "Heartbeat check failed: $_" }
            Start-Sleep -Seconds 5
            $elapsed += 5
            Write-Debug "      Waiting for heartbeat... (${elapsed}s / ${TimeoutSeconds}s)"
            # PROGRESS-INLINE-TICK: reference impl lives in "delay"
            $pct = [math]::Min(100, [math]::Round(($elapsed / [math]::Max($TimeoutSeconds,1)) * 100))
            Write-ProgressTick -Activity "waitForHeartbeat" -Status "$VMName (${elapsed}s / ${TimeoutSeconds}s)" -PercentComplete $pct
        }
        Write-Warning "Heartbeat not OK within ${TimeoutSeconds}s"
        return $false
    } finally {
        Write-ProgressTick -Activity "waitForHeartbeat" -Completed
    }
}

# ── Action: waitForVMStop ────────────────────────────────────────────────────

function Wait-ForVMStop {
    param([string]$HostType, [string]$VMName, [int]$TimeoutSeconds = 300)
    $elapsed = 0
    try {
        while ($elapsed -lt $TimeoutSeconds) {
            if ($HostType -eq "host.windows.hyper-v") {
                $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
                if ($vm -and $vm.State -eq 'Off') { Write-Debug "      VM is Off"; return $true }
            } elseif ($HostType -eq "host.macos.utm") {
                $status = & utmctl status "$VMName" 2>&1
                if ($status -match "stopped|shutdown") { Write-Debug "      VM is stopped"; return $true }
            }
            Start-Sleep -Seconds 5
            $elapsed += 5
            Write-Debug "      Waiting for VM to stop... (${elapsed}s / ${TimeoutSeconds}s)"
            # PROGRESS-INLINE-TICK: reference impl lives in "delay"
            $pct = [math]::Min(100, [math]::Round(($elapsed / [math]::Max($TimeoutSeconds,1)) * 100))
            Write-ProgressTick -Activity "waitForVMStop" -Status "$VMName (${elapsed}s / ${TimeoutSeconds}s)" -PercentComplete $pct
        }
        Write-Warning "VM did not stop within ${TimeoutSeconds}s"
        return $false
    } finally {
        Write-ProgressTick -Activity "waitForVMStop" -Completed
    }
}

# ── Action: screenshot ───────────────────────────────────────────────────────

function Save-DebugScreenshot {
    param([string]$HostType, [string]$VMName, [string]$Label, [string]$OutputDir)
    $fileName = "$VMName-$Label-$(Get-Date -Format 'HHmmss').png"
    $outputPath = Join-Path $OutputDir $fileName
    $dir = Split-Path -Parent $outputPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $screenshotMod = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "modules/Test.Screenshot.psm1"
    if (Test-Path $screenshotMod) {
        Import-Module $screenshotMod -Force -ErrorAction SilentlyContinue -Verbose:$false
        $result = Get-VMScreenshot -HostType $HostType -VMName $VMName -OutputPath $outputPath
        if ($result) { Write-Debug "      Screenshot: $outputPath"; return $true }
    }
    Write-Warning "Screenshot capture not available"
    return $false
}

# ── Variable substitution ────────────────────────────────────────────────────

function Expand-Variable {
    param([string]$Text, [hashtable]$Variables)
    $result = $Text
    foreach ($key in $Variables.Keys) {
        $result = $result -replace [regex]::Escape("`${$key}"), $Variables[$key]
    }
    return $result
}

# ── Main executor ────────────────────────────────────────────────────────────

<#
.SYNOPSIS
    Executes an interaction sequence from a JSON file against a VM.
.DESCRIPTION
    Reads the steps array from the JSON file and executes each action
    sequentially. Variables in the JSON are substituted into parameters.
    Returns $true if all steps succeed, $false otherwise.
#>
function Invoke-Sequence {
    param(
        [string]$HostType,
        [string]$GuestKey,
        [string]$VMName,
        [string]$SequencePath,
        [switch]$ShowSensitive
    )

    # ── SSH variant selection ──────────────────────────────────────────────
    # When test-config.json sets keystrokeMechanism="SSH", prefer a sibling
    # sequence file with a .ssh.json suffix (e.g. Test-Workload.guest.amazon.linux.ssh.json).
    # This is the parallel-path switch: the existing keystroke-based file is
    # untouched, and the SSH variant is picked up automatically when the flag
    # is set. If no .ssh.json sibling exists, fall back to the original file
    # so guests that haven't been migrated yet continue to work in both modes.
    # Comparison is case-insensitive (PowerShell -eq default) so "ssh"/"SSH"
    # both select this branch; the canonical uppercase form is written back
    # to test-config.json by Invoke-TestRunner's validation step.
    if ($script:DefaultKeystrokeMechanism -eq "SSH") {
        $sshVariant = [System.IO.Path]::ChangeExtension($SequencePath, $null).TrimEnd('.') + ".ssh.json"
        if (Test-Path $sshVariant) {
            Write-Information "    keystrokeMechanism=SSH → using SSH variant: $(Split-Path -Leaf $sshVariant)"
            $SequencePath = $sshVariant
        }
    }

    if (-not (Test-Path $SequencePath)) {
        Write-Information "    No sequence file found: $SequencePath"
        return $true
    }

    # Initialize logDir early so the catch block can write diagnostics
    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    Import-Module (Join-Path $modulesDir "Test.LogDir.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false
    Import-Module (Join-Path $modulesDir "Test.Ssh.psm1")    -Force -ErrorAction SilentlyContinue -Verbose:$false
    $logDir = Initialize-YurunaLogDir

  try {
    $sequence = Get-Content -Raw $SequencePath | ConvertFrom-Json

    # Clean up stale failure artifacts from any prior run
    Remove-Item (Join-Path $logDir "last_failure.json") -Force -ErrorAction SilentlyContinue

    # Build variables table: built-ins + JSON-defined
    $vars = @{ "vmName" = $VMName; "hostType" = $HostType; "guestKey" = $GuestKey }
    if ($sequence.variables) {
        $sequence.variables.PSObject.Properties | ForEach-Object { $vars[$_.Name] = $_.Value }
    }

    Write-Information "    Sequence: $($sequence.description)"
    $steps = @($sequence.steps)
    if ($steps.Count -eq 0) {
        Write-Information "    No steps defined."
        return $true
    }
    Write-Information "    Steps: $($steps.Count)"

    # Step-pause back-channel: the status server's /control/step-pause
    # endpoint creates test/status/control.step-pause. We gate on that file
    # in two places:
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
    $stepPauseFlagFile = Join-Path (Split-Path -Parent $PSScriptRoot) "status/control.step-pause"

    # Current-action sidecar: write the in-progress step to a small JSON file
    # that the status server can serve. The UI polls it alongside status.json
    # and renders the line under the matching guest card. We write at the top
    # of each iteration (so the UI sees the step that's about to run, not the
    # one that just finished) and once more at the end of a successful
    # sequence with the "[All N steps completed]" summary.
    $currentActionFile = Join-Path (Split-Path -Parent $PSScriptRoot) "status/current-action.json"
    $writeCurrentAction = {
        param([string]$Line)
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
        } catch {
            Write-Verbose "current-action.json write failed: $($_.Exception.Message)"
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
            Write-Information "    $Label Paused (status-server request). Waiting for resume..."
            while (Test-Path $stepPauseFlagFile) {
                Start-Sleep -Seconds 1
            }
            Write-Information "    $Label Resumed."
        }
    }

    # Gate #1: sequence-level pause check, before any per-sequence work.
    & $waitWhilePaused "[sequence start]"

    # HACK: Force vmconnect to repaint by reconnecting.
    # After a host reboot the Hyper-V console window may render blank;
    # closing and reopening it forces a full framebuffer refresh.
    Import-Module (Join-Path $modulesDir "Test.Start-VM.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false
    Restart-VMConnect -HostType $HostType -VMName $VMName

    $stepNum = 0
    $screenshotDir = Join-Path (Split-Path -Parent $SequencePath) "captures"
    $sequenceStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($step in $steps) {
        $stepNum++
        # Gate #2: between-steps pause check. Catches a Pause clicked
        # while the previous step was running.
        & $waitWhilePaused "[$stepNum/$($steps.Count)]"
        $desc = $step.description ? (Expand-Variable $step.description $vars) : $step.action
        & $writeCurrentAction "[$stepNum/$($steps.Count)] $($step.action): $desc"
        # Current-step visibility is intentionally driven by Write-Progress
        # (via Write-ProgressTick below), NOT by a Write-Information here.
        # A Write-Information at step-start would go through the yuruna-log
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
        $ok = $true
        switch ($step.action) {
            "delay" {
                $secs = [int]$step.seconds
                Write-Debug "      Waiting $secs seconds..."
                # PROGRESS-INLINE-TICK: reference implementation of the per-second
                # progress loop. Keep other PROGRESS-INLINE-TICK blocks in sync.
                for ($r = $secs; $r -gt 0; $r--) {
                    $pct = [math]::Round((($secs - $r) / [math]::Max($secs,1)) * 100)
                    Write-ProgressTick -Activity "delay" -Status "${r}s remaining" -PercentComplete $pct
                    Start-Sleep -Seconds 1
                }
                Write-ProgressTick -Activity "delay" -Completed
            }
            "key" {
                $keyName = $step.name
                Write-Debug "      Sending key '$keyName'..."
                $ok = Send-Key -HostType $HostType -VMName $VMName -KeyName $keyName
            }
            "type" {
                $text = Expand-Variable $step.text $vars
                $masked = ($step.sensitive -and -not $ShowSensitive) ? "***" : $text
                $charDelay = $step.charDelayMs ? [int]$step.charDelayMs : $script:DefaultCharDelayMs
                Write-Debug "      Typing: '$masked' (charDelay=${charDelay}ms)"
                $ok = Send-Text -HostType $HostType -VMName $VMName -Text $text -CharDelayMs $charDelay
            }
            "tabsAndEnter" {
                $tabCount = $step.tabCount ? [int]$step.tabCount : 1
                $delaySeconds = $step.delaySeconds ? [double]$step.delaySeconds : 1
                Write-Debug "      Sending $tabCount Tab(s) + Enter (delay ${delaySeconds}s)"
                $ok = $true
                for ($t = 0; $t -lt $tabCount; $t++) {
                    $ok = Send-Key -HostType $HostType -VMName $VMName -KeyName "Tab"
                    if ($ok -eq $false) { break }
                    Start-Sleep -Milliseconds 300
                }
                if ($ok -ne $false) {
                    $delaySecsInt = [int][math]::Ceiling($delaySeconds)
                    for ($r = $delaySecsInt; $r -gt 0; $r--) {
                        $pct = [math]::Round((($delaySecsInt - $r) / [math]::Max($delaySecsInt,1)) * 100)
                        Write-ProgressTick -Activity "tabsAndEnter" -Status "drain ${r}s" -PercentComplete $pct
                        Start-Sleep -Seconds 1
                    }
                    Write-ProgressTick -Activity "tabsAndEnter" -Completed
                    $ok = Send-Key -HostType $HostType -VMName $VMName -KeyName "Enter"
                }
            }
            "typeAndEnter" {
                $text = Expand-Variable $step.text $vars
                $masked = ($step.sensitive -and -not $ShowSensitive) ? "***" : $text
                $delaySeconds = $step.delaySeconds ? [double]$step.delaySeconds : 2
                $charDelay = $step.charDelayMs ? [int]$step.charDelayMs : $script:DefaultCharDelayMs
                Write-Debug "      Typing: '$masked' + Enter (charDelay=${charDelay}ms, delay ${delaySeconds}s)"
                $ok = Send-Text -HostType $HostType -VMName $VMName -Text $text -CharDelayMs $charDelay
                if ($ok -ne $false) {
                    # PROGRESS-INLINE-TICK: reference impl lives in "delay"
                    $delaySecsInt = [int][math]::Ceiling($delaySeconds)
                    for ($r = $delaySecsInt; $r -gt 0; $r--) {
                        $pct = [math]::Round((($delaySecsInt - $r) / [math]::Max($delaySecsInt,1)) * 100)
                        Write-ProgressTick -Activity "typeAndEnter" -Status "drain ${r}s" -PercentComplete $pct
                        Start-Sleep -Seconds 1
                    }
                    Write-ProgressTick -Activity "typeAndEnter" -Completed
                    # Brief pause to let the VM's keyboard buffer drain before Enter.
                    # On macOS UTM, Send-Text (CGEvent/JXA) and Send-Key (AppleScript)
                    # run as separate OS processes; without this gap the Enter can be
                    # lost during UTM's second window activation.
                    Start-Sleep -Milliseconds 800
                    $ok = Send-Key -HostType $HostType -VMName $VMName -KeyName "Enter"
                }
            }
            "waitForText" {
                # Support both string and array of strings for pattern
                $rawPatterns = $step.pattern
                if ($rawPatterns -is [System.Collections.IEnumerable] -and $rawPatterns -isnot [string]) {
                    [string[]]$patterns = $rawPatterns | ForEach-Object { Expand-Variable $_ $vars }
                } else {
                    [string[]]$patterns = @(Expand-Variable $rawPatterns $vars)
                }
                # Anti-patterns for early-fail. Accept the same shapes as
                # `pattern` (string or array-of-strings); omitting the
                # field leaves failurePatterns empty and Wait-ForText
                # behaves exactly as before.
                $rawFailurePatterns = $step.failurePatterns
                [string[]]$failurePatterns = @()
                if ($null -ne $rawFailurePatterns) {
                    if ($rawFailurePatterns -is [System.Collections.IEnumerable] -and $rawFailurePatterns -isnot [string]) {
                        $failurePatterns = @($rawFailurePatterns | ForEach-Object { Expand-Variable $_ $vars })
                    } else {
                        $failurePatterns = @(Expand-Variable $rawFailurePatterns $vars)
                    }
                }
                $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : 120
                $poll = $step.pollSeconds ? [int]$step.pollSeconds : 5
                $fresh = $step.freshMatch -eq $true
                $tailLines = $step.freshMatchTailLines ? [int]$step.freshMatchTailLines : 12
                $resetMisses = $step.resetAfterMisses ? [int]$step.resetAfterMisses : 3
                $patternDisplay = $patterns -join "' | '"
                Write-Debug "      Watching screen for: '$patternDisplay' (timeout: ${timeout}s$(if ($fresh) { ', freshMatch' })$(if ($failurePatterns.Count) { ", $($failurePatterns.Count) failurePatterns" }))"
                $ok = Wait-ForText -HostType $HostType -VMName $VMName -Pattern $patterns `
                    -TimeoutSeconds $timeout -PollSeconds $poll -FreshMatch $fresh `
                    -FreshMatchTailLines $tailLines -ResetAfterMisses $resetMisses `
                    -FailurePattern $failurePatterns
            }
            "waitForAndEnter" {
                # Composite: waitForText then typeAndEnter
                $rawPatterns = $step.pattern
                if ($rawPatterns -is [System.Collections.IEnumerable] -and $rawPatterns -isnot [string]) {
                    [string[]]$patterns = $rawPatterns | ForEach-Object { Expand-Variable $_ $vars }
                } else {
                    [string[]]$patterns = @(Expand-Variable $rawPatterns $vars)
                }
                $rawFailurePatterns = $step.failurePatterns
                [string[]]$failurePatterns = @()
                if ($null -ne $rawFailurePatterns) {
                    if ($rawFailurePatterns -is [System.Collections.IEnumerable] -and $rawFailurePatterns -isnot [string]) {
                        $failurePatterns = @($rawFailurePatterns | ForEach-Object { Expand-Variable $_ $vars })
                    } else {
                        $failurePatterns = @(Expand-Variable $rawFailurePatterns $vars)
                    }
                }
                $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : 120
                $poll = $step.pollSeconds ? [int]$step.pollSeconds : 5
                $fresh = $step.freshMatch -eq $true
                $tailLines = $step.freshMatchTailLines ? [int]$step.freshMatchTailLines : 12
                $resetMisses = $step.resetAfterMisses ? [int]$step.resetAfterMisses : 3
                $patternDisplay = $patterns -join "' | '"
                Write-Debug "      Watching screen for: '$patternDisplay' (timeout: ${timeout}s$(if ($fresh) { ', freshMatch' })$(if ($failurePatterns.Count) { ", $($failurePatterns.Count) failurePatterns" }))"
                $ok = Wait-ForText -HostType $HostType -VMName $VMName -Pattern $patterns `
                    -TimeoutSeconds $timeout -PollSeconds $poll -FreshMatch $fresh `
                    -FreshMatchTailLines $tailLines -ResetAfterMisses $resetMisses `
                    -FailurePattern $failurePatterns
                if ($ok -ne $false) {
                    # Send Tab keystrokes before typing, if requested. This is
                    # needed when the target element (e.g. an "Install" button)
                    # does not have keyboard focus by default.
                    $tabCount = $step.tabCount ? [int]$step.tabCount : 0
                    if ($tabCount -gt 0) {
                        Write-Debug "      Sending $tabCount Tab(s) to reach the target element"
                        for ($t = 0; $t -lt $tabCount; $t++) {
                            Send-Key -HostType $HostType -VMName $VMName -KeyName "Tab" | Out-Null
                            Start-Sleep -Milliseconds 300
                        }
                        Start-Sleep -Milliseconds 500
                    }
                    $text = Expand-Variable $step.text $vars
                    $masked = ($step.sensitive -and -not $ShowSensitive) ? "***" : $text
                    $delaySeconds = $step.delaySeconds ? [double]$step.delaySeconds : 2
                    $charDelay = $step.charDelayMs ? [int]$step.charDelayMs : $script:DefaultCharDelayMs
                    Write-Debug "      Typing: '$masked' + Enter (charDelay=${charDelay}ms, delay ${delaySeconds}s)"
                    $ok = Send-Text -HostType $HostType -VMName $VMName -Text $text -CharDelayMs $charDelay
                    if ($ok -ne $false) {
                        # PROGRESS-INLINE-TICK: reference impl lives in "delay"
                        $delaySecsInt = [int][math]::Ceiling($delaySeconds)
                        for ($r = $delaySecsInt; $r -gt 0; $r--) {
                            $pct = [math]::Round((($delaySecsInt - $r) / [math]::Max($delaySecsInt,1)) * 100)
                            Write-ProgressTick -Activity "waitForAndEnter" -Status "drain ${r}s" -PercentComplete $pct
                            Start-Sleep -Seconds 1
                        }
                        Write-ProgressTick -Activity "waitForAndEnter" -Completed
                        Start-Sleep -Milliseconds 800
                        $ok = Send-Key -HostType $HostType -VMName $VMName -KeyName "Enter"
                    }
                }
            }
            "waitForAndClickButton" {
                # Accept either a single string or array of candidate labels
                # (useful when OCR might split "Install" as "lnstall" in some engines
                # — list both forms and first hit wins).
                $rawLabels = $step.label
                if ($rawLabels -is [System.Collections.IEnumerable] -and $rawLabels -isnot [string]) {
                    [string[]]$labels = $rawLabels | ForEach-Object { Expand-Variable $_ $vars }
                } else {
                    [string[]]$labels = @(Expand-Variable $rawLabels $vars)
                }
                $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : 120
                $poll    = $step.pollSeconds    ? [int]$step.pollSeconds    : 5
                $offX    = $step.offsetX        ? [int]$step.offsetX        : 0
                $offY    = $step.offsetY        ? [int]$step.offsetY        : 0
                $labelDisplay = $labels -join "' | '"
                Write-Debug "      Waiting for button '$labelDisplay' (timeout: ${timeout}s)"
                $ok = Wait-ForAndClickButton -HostType $HostType -VMName $VMName -Label $labels `
                    -TimeoutSeconds $timeout -PollSeconds $poll -OffsetX $offX -OffsetY $offY
            }
            "screenshot" {
                $label = $step.label ?? "step$stepNum"
                Save-DebugScreenshot -HostType $HostType -VMName $VMName -Label $label -OutputDir $screenshotDir | Out-Null
            }
            "waitForPort" {
                $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : 120
                $ok = Wait-ForPort -VMName $VMName -Port ([int]$step.port) -TimeoutSeconds $timeout
            }
            "waitForHeartbeat" {
                if ($HostType -ne "host.windows.hyper-v") {
                    Write-Debug "      waitForHeartbeat is Hyper-V only. Skipping."
                } else {
                    $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : 300
                    $ok = Wait-ForHeartbeat -VMName $VMName -TimeoutSeconds $timeout
                }
            }
            "waitForVMStop" {
                $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : 300
                $ok = Wait-ForVMStop -HostType $HostType -VMName $VMName -TimeoutSeconds $timeout
            }
            "fetchAndExecute" {
                $text = Expand-Variable $step.text $vars
                $delaySeconds = $step.delaySeconds ? [double]$step.delaySeconds : 2
                $charDelay = $step.charDelayMs ? [int]$step.charDelayMs : $script:DefaultCharDelayMs
                Write-Debug "      fetchAndExecute: typing '$text' + Enter"
                $ok = Send-Text -HostType $HostType -VMName $VMName -Text $text -CharDelayMs $charDelay
                if ($ok -ne $false) {
                    # PROGRESS-INLINE-TICK: reference impl lives in "delay"
                    $delaySecsInt = [int][math]::Ceiling($delaySeconds)
                    for ($r = $delaySecsInt; $r -gt 0; $r--) {
                        $pct = [math]::Round((($delaySecsInt - $r) / [math]::Max($delaySecsInt,1)) * 100)
                        Write-ProgressTick -Activity "fetchAndExecute" -Status "drain ${r}s" -PercentComplete $pct
                        Start-Sleep -Seconds 1
                    }
                    Write-ProgressTick -Activity "fetchAndExecute" -Completed
                    Start-Sleep -Milliseconds 800
                    $ok = Send-Key -HostType $HostType -VMName $VMName -KeyName "Enter"
                }

                if ($ok -ne $false) {
                    $waitPattern = Expand-Variable $step.waitPattern $vars
                    $waitTimeout = $step.waitTimeoutSeconds ? [int]$step.waitTimeoutSeconds : 900
                    $waitPoll = $step.waitPollSeconds ? [int]$step.waitPollSeconds : 9
                    Write-Debug "      fetchAndExecute: waiting for '$waitPattern' (timeout: ${waitTimeout}s, freshMatch)"
                    $ok = Wait-ForText -HostType $HostType -VMName $VMName -Pattern @($waitPattern) `
                        -TimeoutSeconds $waitTimeout -PollSeconds $waitPoll -FreshMatch $true `
                        -FreshMatchTailLines 12 -ResetAfterMisses 3
                }
            }
            "sshWaitReady" {
                # Wait until the guest accepts SSH with the harness key.
                # Mirrors waitForPort but handshakes all the way to an authenticated shell.
                $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : 300
                $poll    = $step.pollSeconds    ? [int]$step.pollSeconds    : 5
                Write-Debug "      sshWaitReady: $GuestKey@$VMName (timeout: ${timeout}s)"
                $ok = Wait-SshReady -VMName $VMName -GuestKey $GuestKey -TimeoutSeconds $timeout -PollSeconds $poll
            }
            "sshExec" {
                # Run a command on the guest over SSH. Non-zero exit fails the step
                # unless allowFailure=true. On success, stdout+stderr are dropped to
                # match the keystroke flow (which never captured guest-side output).
                # On failure, the captured output is included in the warning so the
                # user can see what went wrong without re-running with -Verbose.
                $cmd     = Expand-Variable $step.command $vars
                $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : 900
                $masked  = ($step.sensitive -and -not $ShowSensitive) ? "***" : $cmd
                Write-Debug "      sshExec: $masked"
                $result  = Invoke-GuestSsh -VMName $VMName -GuestKey $GuestKey -Command $cmd -TimeoutSeconds $timeout
                Write-Debug "      sshExec output: $($result.output)"
                if (-not $result.success) {
                    if ($step.allowFailure -eq $true) {
                        Write-Debug "      sshExec exit=$($result.exitCode) (allowFailure=true)"
                    } else {
                        Write-Warning "      sshExec failed (exit=$($result.exitCode)): $masked"
                        if ($result.output) { Write-Warning "      output: $($result.output)" }
                        $ok = $false
                    }
                }
            }
            "sshFetchAndExecute" {
                # SSH equivalent of fetchAndExecute: runs a shell command (typically
                # invoking fetch-and-execute.sh) over SSH in a single blocking call.
                # No OCR polling, no password prompt handling (sudo is passwordless
                # for cloud-init users, or the command handles its own auth).
                # Output is dropped on success and included in the warning on failure.
                $cmd     = Expand-Variable $step.command $vars
                $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : 1800
                Write-Debug "      sshFetchAndExecute: $cmd"
                $result  = Invoke-GuestSsh -VMName $VMName -GuestKey $GuestKey -Command $cmd -TimeoutSeconds $timeout
                Write-Debug "      sshFetchAndExecute output: $($result.output)"
                if (-not $result.success) {
                    Write-Warning "      sshFetchAndExecute failed (exit=$($result.exitCode)): $cmd"
                    if ($result.output) { Write-Warning "      output: $($result.output)" }
                    $ok = $false
                }
            }
            default {
                Write-Warning "Unknown action: $($step.action)"
            }
        }
        } finally {
            $global:ProgressPreference = $savedProgress
        }

        $stepStopwatch.Stop()
        $elapsedLabel = ("    {0,4}" -f [int]$stepStopwatch.Elapsed.TotalSeconds)
        Write-Information "$elapsedLabel s [$stepNum/$($steps.Count)] $($step.action): $desc"

        if ($ok -eq $false) {
            Write-Warning "    Step [$stepNum] failed: $desc"

            # Write failure details to YurunaLog for the parent runner to pick up
            # ($modulesDir and $logDir already set at function start)

            # Build a human-readable failed-step label (e.g. 'waitForText: "login prompt"')
            $actionLabel = $step.action
            switch ($step.action) {
                "waitForText" {
                    $rawPatterns = $step.pattern
                    if ($rawPatterns -is [System.Collections.IEnumerable] -and $rawPatterns -isnot [string]) {
                        $patternDisplay = ($rawPatterns | ForEach-Object { Expand-Variable $_ $vars }) -join "' | '"
                    } else {
                        $patternDisplay = Expand-Variable $rawPatterns $vars
                    }
                    $actionLabel = "waitForText: `"$patternDisplay`""
                }
                "waitForPort"      { $actionLabel = "waitForPort: $($step.port)" }
                "waitForHeartbeat" { $actionLabel = "waitForHeartbeat" }
                "waitForVMStop"    { $actionLabel = "waitForVMStop" }
                "key"              { $actionLabel = "key: $($step.name)" }
                "type"             { $actionLabel = "type" }
                "typeAndEnter"     { $actionLabel = "typeAndEnter" }
                "tabsAndEnter"     { $actionLabel = "tabsAndEnter: $($step.tabCount ?? 1)" }
                "waitForAndEnter" {
                    $rawPatterns = $step.pattern
                    if ($rawPatterns -is [System.Collections.IEnumerable] -and $rawPatterns -isnot [string]) {
                        $patternDisplay = ($rawPatterns | ForEach-Object { Expand-Variable $_ $vars }) -join "' | '"
                    } else {
                        $patternDisplay = Expand-Variable $rawPatterns $vars
                    }
                    $actionLabel = "waitForAndEnter: `"$patternDisplay`""
                }
                "fetchAndExecute"  { $actionLabel = "fetchAndExecute: `"$(Expand-Variable $step.text $vars)`"" }
                "sshWaitReady"     { $actionLabel = "sshWaitReady" }
                "sshExec"          { $actionLabel = "sshExec: `"$(Expand-Variable $step.command $vars)`"" }
                "sshFetchAndExecute" { $actionLabel = "sshFetchAndExecute: `"$(Expand-Variable $step.command $vars)`"" }
            }

            # If Wait-ForText short-circuited on a failurePattern, annotate
            # the step label so the runner's ERROR banner and the per-run
            # failure JSON both say *why* the step died instead of the
            # generic "pattern not found within Ns". Only waitForText /
            # waitForAndEnter set this signal; for other actions the
            # variable is $null and the label is unchanged.
            if (($step.action -eq 'waitForText' -or $step.action -eq 'waitForAndEnter') -and
                $script:WaitForTextMatchedFailurePattern) {
                $actionLabel = $actionLabel + " -- matched failurePattern `"$($script:WaitForTextMatchedFailurePattern)`""
            }

            $failureInfo = @{
                stepNumber  = $stepNum
                totalSteps  = $steps.Count
                action      = $actionLabel
                description = $desc
                vmName      = $VMName
                guestKey    = $GuestKey
                timestamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
            } | ConvertTo-Json
            $failureFile = Join-Path $logDir "last_failure.json"
            Set-Content -Path $failureFile -Value $failureInfo -Force -ErrorAction SilentlyContinue

            # For non-waitForText failures, capture a screenshot now (waitForText already saves one)
            if ($step.action -ne "waitForText" -and $step.action -ne "waitForAndEnter" -and $step.action -ne "fetchAndExecute") {
                Import-Module (Join-Path $modulesDir "Test.Screenshot.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false
                $failScreenPath = Join-Path $logDir "failure_screenshot_${VMName}.png"
                $captured = Get-VMScreenshot -HostType $HostType -VMName $VMName -OutputPath $failScreenPath
                if ($captured) {
                    Write-Information "      Failure screenshot saved: $failScreenPath"
                }
            }

            return $false
        }
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
    Write-Warning "    Invoke-Sequence unhandled error: $_"
    # Preserve diagnostics for the crash
    try {
        $crashInfo = @{
            error     = "$_"
            vmName    = $VMName
            guestKey  = $GuestKey
            sequence  = $SequencePath
            timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        } | ConvertTo-Json
        Set-Content -Path (Join-Path $logDir "last_failure.json") -Value $crashInfo -Force -ErrorAction SilentlyContinue
    } catch { Write-Verbose "Could not write last_failure.json: $_" }
    return $false
  }
}

Export-ModuleMember -Function Invoke-Sequence
