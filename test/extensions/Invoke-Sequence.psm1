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

# macOS AppleScript key codes
$script:UTMKeyMap = @{
    "Enter"=36; "Tab"=48; "Space"=49; "Escape"=53
    "Up"=126; "Down"=125; "Left"=123; "Right"=124
    "F1"=122; "F2"=120; "F3"=99; "F4"=118; "F5"=96
    "F6"=97; "F7"=98; "F8"=100; "F9"=101; "F10"=109
    "F11"=103; "F12"=111
}

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
    $escapedText = $Text -replace '\\', '\\\\' -replace '"', '\\"'
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
                keystroke "$escapedText"
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

    # Capture VM window to temp file
    $tempDir = if ($IsWindows) { $env:TEMP } else { $env:TMPDIR }
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

    # Preprocess: trim empty regions and invert colors for OCR.
    # VM consoles show light text on dark backgrounds. Tesseract struggles
    # with large dark regions surrounding sparse text. Trimming removes the
    # empty background so tesseract only processes the area with actual text
    # — this works whether text starts from the top (early boot) or fills
    # the entire screen (later interaction).
    $processedFile = $tempFile
    $trimmedFile = $tempFile -replace '\.png$', '_trim.png'
    $invertedFile = $tempFile -replace '\.png$', '_inv.png'

    if (-not $script:ImageToolChecked) {
        $script:ImageToolChecked = $true
        $script:MagickCmd = Get-Command "magick" -ErrorAction SilentlyContinue
        if (-not $script:MagickCmd) {
            $script:MagickCmd = Get-Command "convert" -ErrorAction SilentlyContinue
        }
    }

    # Step 1: Trim empty (dark) regions around the text
    if ($script:MagickCmd) {
        # -fuzz 15% treats near-black pixels as background; -trim removes them
        & $script:MagickCmd.Source $tempFile -fuzz "15%" -trim +repage $trimmedFile 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $trimmedFile)) { $processedFile = $trimmedFile }
    }

    # Step 2: Invert colors (dark text on light background for tesseract)
    $sourceForInvert = $processedFile
    if ($script:MagickCmd) {
        & $script:MagickCmd.Source $sourceForInvert -negate -grayscale Rec709Luma $invertedFile 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $invertedFile)) { $processedFile = $invertedFile }
    } elseif (-not $IsWindows) {
        Copy-Item $sourceForInvert $invertedFile -Force
        & sips -j "CIColorInvert" "$invertedFile" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $invertedFile)) { $processedFile = $invertedFile }
    }

    # Step 3: Run tesseract OCR (--psm 6 = single uniform block, ideal for cropped region)
    try {
        $ocrOutput = & tesseract $processedFile stdout --psm 6 2>$null
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
        Remove-Item $trimmedFile -Force -ErrorAction SilentlyContinue
        Remove-Item $invertedFile -Force -ErrorAction SilentlyContinue
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
