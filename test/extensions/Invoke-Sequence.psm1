<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456770
.AUTHOR Alisson Sol
.COMPANYNAME None
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

# Ensure all Write-Information calls are visible in the console.
# This is set at module scope so it applies to all functions.
$InformationPreference = 'Continue'

# ─────────────────────────────────────────────────────────────────────────────
# Shared engine for executing interaction sequences from JSON files.
#
# Supported actions (defined in $actions in each JSON):
#   delay            — Wait N seconds.
#   key              — Send a single keystroke.
#   type             — Type a text string into the VM.
#   typeAndEnter     — Type a text string followed by Enter.
#   screenshot       — Capture a screenshot for debugging.
#   waitForText      — Capture + OCR the VM screen until pattern appears.
#   waitForPort      — Wait until a TCP port responds on the VM.
#   waitForHeartbeat — Wait for Hyper-V heartbeat (Hyper-V only).
#   waitForVMStop    — Wait until the VM reaches the Off/stopped state.
#
# Variables defined in the JSON "variables" block are substituted into
# action parameters using ${variableName} syntax. The built-in variable
# ${vmName} is always available.
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
        Write-Information "      TypeScancodes key='$KeyName' scan=0x$($scanCode.ToString('X2')) ok=$ok"
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
    $appleScript = @"
tell application "UTM" to activate
delay 0.5
tell application "System Events"
    tell process "UTM"
        set frontmost to true
        repeat with w in windows
            if name of w contains "$VMName" then
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
    $result = & osascript -e $appleScript 2>&1
    Write-Information "      AppleScript: $result"
    return ("$result" -eq "ok")
}

function Send-Key {
    param([string]$HostType, [string]$VMName, [string]$KeyName)
    if ($HostType -eq "host.windows.hyper-v") { return Send-KeyHyperV -VMName $VMName -KeyName $KeyName }
    elseif ($HostType -eq "host.macos.utm")   { return Send-KeyUTM    -VMName $VMName -KeyName $KeyName }
    else { Write-Warning "Unknown host: $HostType"; return $false }
}

# ── Action: type / typeAndEnter ──────────────────────────────────────────────

function Send-TextHyperV {
    param([string]$VMName, [string]$Text)
    $kb = Get-HyperVKeyboard -VMName $VMName
    if (-not $kb) { return $false }
    try {
        # Convert each character to PS/2 scan codes and send as a batch.
        # For shifted characters: LShift-down, char-down, char-up, LShift-up.
        $codeList = [System.Collections.Generic.List[byte]]::new()
        foreach ($ch in $Text.ToCharArray()) {
            $entry = $script:CharScanCodes["$ch"]
            if (-not $entry) {
                Write-Warning "No scan code for character '$ch' (0x$([byte][char]$ch | ForEach-Object { $_.ToString('X2') })). Skipping."
                continue
            }
            $scan = [byte]$entry[0]
            $shifted = $entry[1]
            if ($shifted) { $codeList.Add(0x2A) }            # LShift make
            $codeList.Add($scan)                              # char make
            $codeList.Add([byte]($scan -bor 0x80))            # char break
            if ($shifted) { $codeList.Add(0xAA) }            # LShift break
        }
        if ($codeList.Count -eq 0) { return $true }
        $ok = Send-ScanCode -Keyboard $kb -Codes ([byte[]]$codeList.ToArray())
        Write-Information "      TypeScancodes: $($Text.Length) chars, $($codeList.Count) codes, ok=$ok"
        return $ok
    } catch {
        Write-Warning "Hyper-V TypeScancodes (text) failed: $_"
        return $false
    }
}

function Send-TextUTM {
    param([string]$VMName, [string]$Text)
    # Use raw key codes instead of AppleScript's keystroke command.
    # keystroke interprets certain character sequences (e.g., "2-")
    # as modifier combinations, producing phantom newlines and dropped
    # characters. key code sends raw virtual keycodes like the Hyper-V
    # scan code path, avoiding any interpretation.
    $charLines = ""
    foreach ($ch in $Text.ToCharArray()) {
        $entry = $script:MacCharKeyCodes["$ch"]
        if (-not $entry) {
            Write-Warning "No macOS key code for character '$ch'. Skipping."
            continue
        }
        $kc = $entry[0]
        $shifted = $entry[1]
        if ($shifted) {
            $charLines += "                key code $kc using shift down`n"
        } else {
            $charLines += "                key code $kc`n"
        }
        $charLines += "                delay 0.05`n"
    }
    $appleScript = @"
tell application "UTM" to activate
delay 0.3
tell application "System Events"
    tell process "UTM"
        set frontmost to true
        repeat with w in windows
            if name of w contains "$VMName" then
                perform action "AXRaise" of w
                delay 0.3
$charLines                return "ok"
            end if
        end repeat
    end tell
end tell
return "window_not_found"
"@
    $result = & osascript -e $appleScript 2>&1
    Write-Information "      AppleScript: $result"
    return ("$result" -eq "ok")
}

function Send-Text {
    param([string]$HostType, [string]$VMName, [string]$Text)
    if ($HostType -eq "host.windows.hyper-v") { return Send-TextHyperV -VMName $VMName -Text $Text }
    elseif ($HostType -eq "host.macos.utm")   { return Send-TextUTM    -VMName $VMName -Text $Text }
    else { Write-Warning "Unknown host: $HostType"; return $false }
}

# ── OCR: extract text from VM screen ────────────────────────────────────────

# Get-ScreenText captures the VM window and runs OCR via tesseract.
# tesseract is cross-platform and works identically on Windows and macOS:
#   Windows: winget install UB-Mannheim.TesseractOCR
#   macOS:   brew install tesseract
# The Get-Tesseract.ps1 setup script installs it automatically.
function Get-ScreenText {
    param([string]$HostType, [string]$VMName)

    # Check tesseract availability (once)
    if (-not $script:TesseractChecked) {
        $script:TesseractCmd = Get-Command "tesseract" -ErrorAction SilentlyContinue
        if (-not $script:TesseractCmd) {
            Write-Warning "tesseract not found in PATH. Run test/Get-Tesseract.ps1 to install it."
            Write-Warning "  Windows: winget install UB-Mannheim.TesseractOCR"
            Write-Warning "  macOS:   brew install tesseract"
        }
        $script:TesseractChecked = $true
    }
    if (-not $script:TesseractCmd) { return $null }

    if ($HostType -eq "host.macos.utm") {
        return Get-ScreenTextUTM -VMName $VMName
    }

    # Hyper-V path: capture via screenshot module, run tesseract directly.
    # Hyper-V window captures are small enough that tesseract processes them
    # fully without truncation.
    $tempDir = $env:TEMP
    $tempFile = Join-Path $tempDir "ocr_$VMName.png"

    $screenshotMod = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "modules/Test.Screenshot.psm1"
    if (-not (Test-Path $screenshotMod)) {
        $screenshotMod = Join-Path $PSScriptRoot "../modules/Test.Screenshot.psm1"
    }
    if (-not (Test-Path $screenshotMod)) {
        Write-Warning "Screenshot module not found"
        return $null
    }
    Import-Module $screenshotMod -Force -ErrorAction SilentlyContinue
    $captured = Get-VMScreenshot -HostType $HostType -VMName $VMName -OutputPath $tempFile
    if (-not $captured) { return $null }

    try {
        $ocrOutput = & tesseract $tempFile stdout --dpi 72 --psm 6 2>$null
        if ($LASTEXITCODE -eq 0 -and $ocrOutput) {
            $text = ($ocrOutput -join "`n")
            Write-Information "      OCR text: $($text.Substring(0, [Math]::Min($text.Length, 200)))"
            return $text
        }
        Write-Information "      OCR returned no text (exit code: $LASTEXITCODE)"
        return $null
    } catch {
        Write-Warning "tesseract OCR failed: $_"
        return $null
    } finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

# macOS UTM: capture the UTM window via screencapture -R and run tesseract.
# Captures both the full window AND a bottom strip, then combines the OCR
# results. The full-window capture catches text during early boot (text at
# top, rest is black). The bottom-strip capture catches prompts when the
# screen is full (tesseract truncates full-screen OCR mid-line). Combining
# both means the pattern match in Wait-ForText succeeds regardless of where
# the target text is on screen.
function Get-ScreenTextUTM {
    param([string]$VMName)

    $tempDir = $env:TMPDIR
    if (-not $tempDir) { $tempDir = "/tmp" }
    $fullFile = Join-Path $tempDir "ocr_${VMName}_full.png"
    $bottomFile = Join-Path $tempDir "ocr_${VMName}_bot.png"

    # Get UTM window bounds via AppleScript
    $boundsScript = @"
tell application "System Events"
    repeat with proc in (every process whose name contains "UTM")
        repeat with w in windows of proc
            if name of w contains "$VMName" then
                set {wx, wy} to position of w
                set {ww, wh} to size of w
                return ("" & wx & "," & wy & "," & ww & "," & wh)
            end if
        end repeat
    end repeat
end tell
return "not_found"
"@
    $bounds = & osascript -e $boundsScript 2>&1
    if ("$bounds" -eq "not_found" -or "$bounds" -notmatch '^\d+,\d+,\d+,\d+$') {
        Write-Warning "UTM window for '$VMName' not found for OCR"
        return $null
    }

    $parts = "$bounds" -split ','
    [int]$wx = $parts[0]; [int]$wy = $parts[1]
    [int]$ww = $parts[2]; [int]$wh = $parts[3]

    # Bottom strip: 30% of window height, captures the most recent lines
    $cropH = [Math]::Max(150, [int]($wh * 0.30))
    $botY = $wy + $wh - $cropH
    $fullRegion = "$wx,$wy,$ww,$wh"
    $botRegion = "$wx,$botY,$ww,$cropH"

    Write-Information "      Window: ${ww}x${wh} at ${wx},${wy}"

    $textParts = [System.Collections.Generic.List[string]]::new()

    try {
        # Capture 1: full window (catches early boot, text at top)
        & screencapture -x -R "$fullRegion" "$fullFile" 2>$null
        if (Test-Path $fullFile) {
            $fullText = Invoke-TesseractOCR -ImagePath $fullFile
            if ($fullText) { $textParts.Add($fullText) }
        }

        # Capture 2: bottom strip (catches prompts on full screens that
        # the full-window OCR truncates before reaching)
        & screencapture -x -R "$botRegion" "$bottomFile" 2>$null
        if (Test-Path $bottomFile) {
            $botText = Invoke-TesseractOCR -ImagePath $bottomFile
            if ($botText) { $textParts.Add($botText) }
        }

        if ($textParts.Count -eq 0) {
            Write-Information "      OCR returned no text from UTM window"
            return $null
        }

        # Combine both OCR results separated by newline.
        # Pattern matching in Wait-ForText will find the target in either part.
        $combined = $textParts -join "`n"
        Write-Information "      OCR text: $($combined.Substring(0, [Math]::Min($combined.Length, 300)))"
        return $combined
    } finally {
        Remove-Item $fullFile -Force -ErrorAction SilentlyContinue
        Remove-Item $bottomFile -Force -ErrorAction SilentlyContinue
    }
}

# Run tesseract on a single image file, return text or $null.
# Scales the image 3x before OCR on macOS — small monospace console fonts at
# native resolution cause character confusion (e.g., "w" → "u", "password" →
# "passuord"). Larger characters produce dramatically better accuracy.
function Invoke-TesseractOCR {
    param([string]$ImagePath)
    $ocrFile = $ImagePath
    $scaledFile = $ImagePath -replace '\.png$', '_3x.png'
    if (-not $IsWindows) {
        # Scale up 3x using sips (ships with macOS)
        $sipsInfo = & sips -g pixelWidth "$ImagePath" 2>$null
        $imgW = 0
        foreach ($line in $sipsInfo) {
            if ($line -match 'pixelWidth:\s*(\d+)') { $imgW = [int]$Matches[1] }
        }
        if ($imgW -gt 0) {
            $newW = $imgW * 3
            Copy-Item $ImagePath $scaledFile -Force
            & sips --resampleWidth $newW "$scaledFile" 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $ocrFile = $scaledFile }
        }
    }
    try {
        $ocrOutput = & tesseract $ocrFile stdout --dpi 72 --psm 6 2>$null
        if ($LASTEXITCODE -eq 0 -and $ocrOutput) {
            return ($ocrOutput -join "`n")
        }
        return $null
    } finally {
        if ($scaledFile -ne $ImagePath) {
            Remove-Item $scaledFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── Action: waitForText ──────────────────────────────────────────────────────

function Wait-ForText {
    param([string]$HostType, [string]$VMName, [string]$Pattern, [int]$TimeoutSeconds = 120, [int]$PollSeconds = 5)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $screenText = Get-ScreenText -HostType $HostType -VMName $VMName
        if ($screenText -and $screenText -imatch [regex]::Escape($Pattern)) {
            Write-Information "      Text detected: '$Pattern'"
            return $true
        }
        $elapsed += $PollSeconds
        Write-Information "      Waiting for text '$Pattern'... (${elapsed}s / ${TimeoutSeconds}s)"
        Start-Sleep -Seconds $PollSeconds
    }
    Write-Warning "Text '$Pattern' not found within ${TimeoutSeconds}s"
    return $false
}

# ── Action: waitForPort ──────────────────────────────────────────────────────

function Wait-ForPort {
    param([string]$VMName, [int]$Port, [int]$TimeoutSeconds = 120)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $async = $tcp.BeginConnect($VMName, $Port, $null, $null)
            $wait = $async.AsyncWaitHandle.WaitOne(2000, $false)
            if ($wait -and $tcp.Connected) { $tcp.Close(); Write-Information "      Port $Port responding"; return $true }
            $tcp.Close()
        } catch { Write-Verbose "Port $Port connection attempt failed: $_" }
        Start-Sleep -Seconds 5
        $elapsed += 5
        Write-Information "      Waiting for port $Port... (${elapsed}s / ${TimeoutSeconds}s)"
    }
    Write-Warning "Port $Port did not respond within ${TimeoutSeconds}s"
    return $false
}

# ── Action: waitForHeartbeat ─────────────────────────────────────────────────

function Wait-ForHeartbeat {
    param([string]$VMName, [int]$TimeoutSeconds = 300)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        try {
            $hb = Get-VMIntegrationService -VMName $VMName -Name "Heartbeat" -ErrorAction SilentlyContinue
            if ($hb -and $hb.PrimaryStatusDescription -eq "OK") {
                Write-Information "      Heartbeat OK"; return $true
            }
        } catch { Write-Verbose "Heartbeat check failed: $_" }
        Start-Sleep -Seconds 5
        $elapsed += 5
        Write-Information "      Waiting for heartbeat... (${elapsed}s / ${TimeoutSeconds}s)"
    }
    Write-Warning "Heartbeat not OK within ${TimeoutSeconds}s"
    return $false
}

# ── Action: waitForVMStop ────────────────────────────────────────────────────

function Wait-ForVMStop {
    param([string]$HostType, [string]$VMName, [int]$TimeoutSeconds = 300)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if ($HostType -eq "host.windows.hyper-v") {
            $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
            if ($vm -and $vm.State -eq 'Off') { Write-Information "      VM is Off"; return $true }
        } elseif ($HostType -eq "host.macos.utm") {
            $status = & utmctl status "$VMName" 2>&1
            if ($status -match "stopped|shutdown") { Write-Information "      VM is stopped"; return $true }
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
        Write-Information "      Waiting for VM to stop... (${elapsed}s / ${TimeoutSeconds}s)"
    }
    Write-Warning "VM did not stop within ${TimeoutSeconds}s"
    return $false
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
        Import-Module $screenshotMod -Force -ErrorAction SilentlyContinue
        $result = Get-VMScreenshot -HostType $HostType -VMName $VMName -OutputPath $outputPath
        if ($result) { Write-Information "      Screenshot: $outputPath"; return $true }
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
        [string]$SequencePath
    )

    if (-not (Test-Path $SequencePath)) {
        Write-Information "    No sequence file found: $SequencePath"
        return $true
    }

    $sequence = Get-Content -Raw $SequencePath | ConvertFrom-Json

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

    $stepNum = 0
    $screenshotDir = Join-Path (Split-Path -Parent $SequencePath) "captures"

    foreach ($step in $steps) {
        $stepNum++
        $desc = if ($step.description) { Expand-Variable $step.description $vars } else { $step.action }
        Write-Information "    [$stepNum/$($steps.Count)] $($step.action): $desc"

        $ok = $true
        switch ($step.action) {
            "delay" {
                $secs = [int]$step.seconds
                Write-Information "      Waiting $secs seconds..."
                Start-Sleep -Seconds $secs
            }
            "key" {
                $keyName = $step.name
                Write-Information "      Sending key '$keyName'..."
                $ok = Send-Key -HostType $HostType -VMName $VMName -KeyName $keyName
            }
            "type" {
                $text = Expand-Variable $step.text $vars
                $masked = if ($step.sensitive) { "***" } else { $text }
                Write-Information "      Typing: '$masked'"
                $ok = Send-Text -HostType $HostType -VMName $VMName -Text $text
            }
            "typeAndEnter" {
                $text = Expand-Variable $step.text $vars
                $masked = if ($step.sensitive) { "***" } else { $text }
                Write-Information "      Typing: '$masked' + Enter"
                $ok = Send-Text -HostType $HostType -VMName $VMName -Text $text
                if ($ok -ne $false) {
                    Start-Sleep -Milliseconds 200
                    $ok = Send-Key -HostType $HostType -VMName $VMName -KeyName "Enter"
                }
            }
            "waitForText" {
                $pattern = Expand-Variable $step.pattern $vars
                $timeout = if ($step.timeoutSeconds) { [int]$step.timeoutSeconds } else { 120 }
                $poll = if ($step.pollSeconds) { [int]$step.pollSeconds } else { 5 }
                Write-Information "      Watching screen for: '$pattern' (timeout: ${timeout}s)"
                $ok = Wait-ForText -HostType $HostType -VMName $VMName -Pattern $pattern `
                    -TimeoutSeconds $timeout -PollSeconds $poll
            }
            "screenshot" {
                $label = if ($step.label) { $step.label } else { "step$stepNum" }
                Save-DebugScreenshot -HostType $HostType -VMName $VMName -Label $label -OutputDir $screenshotDir | Out-Null
            }
            "waitForPort" {
                $timeout = if ($step.timeoutSeconds) { [int]$step.timeoutSeconds } else { 120 }
                $ok = Wait-ForPort -VMName $VMName -Port ([int]$step.port) -TimeoutSeconds $timeout
            }
            "waitForHeartbeat" {
                if ($HostType -ne "host.windows.hyper-v") {
                    Write-Information "      waitForHeartbeat is Hyper-V only. Skipping."
                } else {
                    $timeout = if ($step.timeoutSeconds) { [int]$step.timeoutSeconds } else { 300 }
                    $ok = Wait-ForHeartbeat -VMName $VMName -TimeoutSeconds $timeout
                }
            }
            "waitForVMStop" {
                $timeout = if ($step.timeoutSeconds) { [int]$step.timeoutSeconds } else { 300 }
                $ok = Wait-ForVMStop -HostType $HostType -VMName $VMName -TimeoutSeconds $timeout
            }
            default {
                Write-Warning "Unknown action: $($step.action)"
            }
        }

        if ($ok -eq $false) {
            Write-Warning "    Step [$stepNum] failed: $desc"
            return $false
        }
    }

    Write-Information "    All $($steps.Count) steps completed."
    return $true
}

Export-ModuleMember -Function Invoke-Sequence
