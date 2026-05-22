<#PSScriptInfo
.VERSION 2026.05.22
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456770
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
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

# Inherit logLevel from the parent process via $env:YURUNA_LOG_LEVEL
# (refreshed per step from test.config.yml.logLevel by the runner's
# Resolve-LogLevel). Child pwsh processes don't inherit PowerShell
# preference variables, so the env var is the only way to propagate.
# Each level shows itself + all higher-priority streams; Error is highest.
if ($env:YURUNA_LOG_LEVEL) {
    $_rank = @{ Error=1; Warning=2; Information=3; Verbose=4; Debug=5 }
    if ($_rank.ContainsKey($env:YURUNA_LOG_LEVEL)) {
        $_eff = $_rank[$env:YURUNA_LOG_LEVEL]
        $global:WarningPreference     = if ($_rank.Warning     -le $_eff) { 'Continue' } else { 'SilentlyContinue' }
        $global:InformationPreference = if ($_rank.Information -le $_eff) { 'Continue' } else { 'SilentlyContinue' }
        $global:VerbosePreference     = if ($_rank.Verbose     -le $_eff) { 'Continue' } else { 'SilentlyContinue' }
        $global:DebugPreference       = if ($_rank.Debug       -le $_eff) { 'Continue' } else { 'SilentlyContinue' }
        if ($_eff -ge $_rank.Verbose) { $global:ProgressPreference = 'SilentlyContinue' }
    }
}

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
$script:DefaultPollSeconds      = 5
# Default timeout for wait-style actions (waitForText, passwdPrompt,
# fetchAndExecute, sshExec, sshWaitReady, ...). A step's own `timeoutSeconds`
# overrides this; otherwise this global value (vmCommunication.timeoutSeconds)
# is used.
$script:DefaultTimeoutSeconds   = 180
# Ring-buffer depth for raw pre-OCR screen captures kept per VM (Wait-ForText).
# On guest success the buffer dir is deleted; on failure the whole sequence is
# preserved so the failure-screenshot link can point at the run-up to the bug.
$script:DefaultScreenHistorySize = 5

# ── Progress wrapper ─────────────────────────────────────────────────────────
# Invoke-Sequence runs inline in the runner's interactive host now (the cycle
# planner dispatches Invoke-SequenceByName directly from Test.Start-GuestOS /
# Test.Start-GuestWorkload -- no child pwsh in the path), so Write-Progress works
# natively. This wrapper keeps the call sites uniform with the previous
# child-pwsh era when a stdout marker protocol was also needed.
function Write-ProgressTick {
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
$_configPath = Join-Path (Split-Path -Parent $PSScriptRoot) "test.config.yml"
if (Test-Path $_configPath) {
    try {
        $_cfg = Get-Content -Raw $_configPath | ConvertFrom-Yaml -Ordered
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
    } catch { Write-Verbose "Config parse error — using built-in default: $_" }
}
Remove-Variable -Name _configPath, _cfg -ErrorAction SilentlyContinue

# ─────────────────────────────────────────────────────────────────────────────
# Shared engine for executing interaction sequences from JSON files.
#
# Supported actions (defined in the "steps" array in each JSON):
#   pressKey         — Send a single keystroke.
#   inputText        — Type a text string into the VM (charDelayMs configurable, default from test.config.yml, fallback 20ms).
#   inputTextAndEnter — Type a text string, wait, then press Enter (charDelayMs/delaySeconds configurable).
#   takeScreenshot   — Capture a screenshot for debugging.
#   waitForText      — Capture + OCR the VM screen until pattern appears (supports array of alternate patterns).
#                       freshMatch: if true, captures a baseline, then waits for the screen
#                       to change AND the pattern to appear in the last N lines.
#                       freshMatchTailLines: number of trailing OCR lines to check (default 12).
#   waitForAndEnter  — Wait for text pattern on screen via OCR, then type a string and press Enter.
#                       Combines waitForText + inputTextAndEnter into a single step.
#   passwdPrompt     — Like waitForAndEnter, but `text` is always treated as
#                       sensitive (masked in logs unless -ShowSensitive). Use
#                       for PAM password prompts.
#   tapOn            — Wait for a labelled button via OCR and click its centre.
#                       Uses Tesseract TSV to get per-word bounding boxes, then
#                       synthesizes a mouse click at (centerX + offsetX, centerY + offsetY).
#                       More reliable than Tab-count navigation for focus-sensitive UIs.
#                       Hyper-V only for now; UTM support is stubbed.
#   sshWaitReady     — Wait until the guest accepts SSH using the yuruna harness key.
#   sshExec          — Run a command on the guest over SSH; non-zero exit fails unless allowFailure=true.
#   sshFetchAndExecute — Run a long-lived command over SSH (SSH equivalent of fetchAndExecute).
#   callExtension    — Side-effecting call into a test/extension/<area>/ module.
#                       method: "area.Method"; args: named-parameter object.
#                       Used for commits like authentication.SetPassword that must run
#                       AFTER an interactive sub-sequence succeeds.
#   saveSystemDiagnostic — SSH into the guest, run automation/Get-SystemDiagnostic.ps1,
#                       and save the captured output to this cycle's
#                       cycleGuestDataFolder ({cycleFolder}/{vmName}/).
#                       Filename: <date>-<time>.system.diagnostic.<id>.txt.
#                       Requires an 'id' field on the step (uniqueness
#                       guard so two captures in the same sequence don't
#                       clobber each other). Soft-fails on the SSH/console
#                       rungs (a missing pwsh on the guest does not abort
#                       the sequence). Useful for checkpoint dumps mid-
#                       sequence. Diagnostic capture is opt-in: the runner
#                       no longer auto-invokes at end-of-guest; place an
#                       explicit saveSystemDiagnostic step in the YAML at
#                       any point a capture is wanted.
#
# Variables defined in the YAML "variables" block are substituted into
# action parameters using ${variableName} syntax. Built-in variables:
# ${vmName}, ${hostType}, ${guestKey}.
# ${ext:area.Method(arg1, arg2)} substitutions invoke the active
# extension under test/extension/<area>/ for value-producing reads.
# Inner ${var} placeholders in args are resolved first. Each ${ext:...}
# is invoked fresh on every reference -- there is no per-run memoization.
# To get a stable value across multiple steps (e.g. "New password:"
# typed and then re-typed at "Retype:"), assign the call to a variable
# in the "variables" block; entries there are evaluated eagerly in YAML
# order at sequence start, and the stored value is reused on every
# ${myVar} reference.
# Escape: $$ produces a literal $. In particular $${foo} yields the
# four-character literal ${foo} (no substitution). To embed two literal
# dollars, write $$$$.
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
# Punctuation (shifted). '*' and '+' are remapped to the numeric-keypad
# keycodes (kVK_ANSI_KeypadMultiply=67, kVK_ANSI_KeypadPlus=69) so they
# need no Shift; everything else maps to its main-row keycode with
# needsShift=true, and the CGEvent typing loop presses Shift around it.
$script:MacCharKeyCodes['!']=@(18,$true);  $script:MacCharKeyCodes['@']=@(19,$true)
$script:MacCharKeyCodes['#']=@(20,$true);  $script:MacCharKeyCodes['$']=@(21,$true)
$script:MacCharKeyCodes['%']=@(23,$true);  $script:MacCharKeyCodes['^']=@(22,$true)
$script:MacCharKeyCodes['&']=@(26,$true);  $script:MacCharKeyCodes['*']=@(67,$false)
$script:MacCharKeyCodes['(']=@(25,$true);  $script:MacCharKeyCodes[')']=@(29,$true)
$script:MacCharKeyCodes['_']=@(27,$true);  $script:MacCharKeyCodes['+']=@(69,$false)
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
# (via AdditionalArguments: -vnc localhost:0 in the plist). VMs without
# a VNC server fall back to the AppleScript/CGEvent path in Send-TextUTM.

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
    param([string]$VMName, [int]$Port = 0)
    # Resolve the per-VM VNC port. Hardcoding 5900 across every VM let the
    # capture path silently grab whichever QEMU bound it first, so the
    # producer (config.plist.template) and consumers (this module +
    # Test.Screenshot.psm1) all derive the port from the VM name via
    # Get-VncPortForVm. $script:DefaultVncPort is kept as a last-resort
    # fallback for callers that don't pass a VMName.
    if ($Port -le 0) {
        if ($VMName) {
            # Get-VncPortForVm now lives in host/macos.utm/Yuruna.Host.psm1
            # (migrated from Test.Screenshot during the Yuruna.Host
            # refactor). Yuruna.Host imports VM.common, so callers that
            # ran Initialize-YurunaHost have it; otherwise import directly.
            if (-not (Get-Command Get-VncPortForVm -ErrorAction SilentlyContinue)) {
                $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
                $vmCommon = Join-Path $repoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
                if (Test-Path $vmCommon) {
                    Import-Module $vmCommon -Force -ErrorAction SilentlyContinue -Verbose:$false
                }
            }
            $Port = Get-VncPortForVm -VMName $VMName
        } else {
            $Port = $script:DefaultVncPort
        }
    }
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
    param([string]$VMName, [string]$KeyName, [int]$Port = 0)
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
          [int]$Port = 0)
    $tcp = Connect-VNC -VMName $VMName -Port $Port
    if (-not $tcp) { return $false }
    Write-Debug "      VNC text send: $($Text.Length) chars, charDelay=${CharDelayMs}ms"
    try {
        # Empirically, UTM's QEMU VNC does NOT auto-shift from the keysym
        # alone (e.g. `asterisk` arrives as `8`, `bar` arrives as `\`), so we
        # must press LShift ourselves. The earlier 20ms/10ms guard wasn't
        # enough on slower or busier hosts; matching the JXA path's 80ms
        # shift-settle has been reliable there.
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
                Start-Sleep -Milliseconds 80
            }
            Send-VncKeyEvent -Client $tcp -KeySym $keySym -Down $true
            Send-VncKeyEvent -Client $tcp -KeySym $keySym -Down $false
            if ($shifted) {
                Start-Sleep -Milliseconds 40
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
    param([string]$VMName, [string]$KeyName)
    # VMName is accepted for consistent API with Send-KeyHyperV/Send-KeyUTM;
    # AXUI targets the UTM app process, not an individual VM.
    if ($VMName) { Write-Debug "      AXUI: -VMName '$VMName' is informational; AXUI targets the UTM app process." }
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
    param([string]$VMName, [string]$Text, [int]$CharDelayMs = $script:DefaultCharDelayMs)
    $delaySec = [math]::Max(0.02, $CharDelayMs / 1000.0)

    # VMName is accepted for consistent API with Send-TextHyperV/Send-TextUTM;
    # AXUI targets the UTM app process, not an individual VM.
    Write-Debug "      AXUI text send: vm='$VMName' $($Text.Length) chars, charDelay=${CharDelayMs}ms"
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
    # Use `key code` for everything (including Enter, code 36). The previous
    # `keystroke return` form for Enter sometimes fired twice when chained
    # after a Send-Text run that left System Events' keystroke buffer warm —
    # which submitted an empty password and bounced the guest back to the
    # login prompt. `key code 36` is one synchronous event, no buffering.
    $keyAction = "key code $code"
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

# ── libvirt KVM keystroke transport: virsh send-key ──────────────────────────
# We tried VNC first (Connect-VNC + Send-TextVNC, the same path UTM uses).
# Empirically, libvirt-managed QEMU on Ubuntu 24.04 accepts our TCP connect
# and emits its 'RFB 003.008' greeting, then drops the connection
# immediately after we write the client version -- before any auth or
# security-types handshake. UTM's QEMU does not. Tracking down the
# libvirt-vs-stand-alone-QEMU handshake difference would be deep work; the
# pragmatic fix is to bypass VNC entirely on KVM and inject keystrokes via
# `virsh send-key`, which goes through libvirt's QMP monitor and has none
# of the listen-address / port-discovery / RFB-version moving parts.
#
# `virsh send-key <domain> [keycode...]` accepts Linux input event names
# (KEY_A, KEY_LEFTSHIFT, KEY_ENTER, ...) and sends them as one chord
# (all pressed simultaneously, then released). For text typing we send
# one chord per character; shifted characters become a 2-key chord
# (KEY_LEFTSHIFT + KEY_X).
# PowerShell's @{} hash literal uses a case-INSENSITIVE comparer, so 'a'
# and 'A' would collide at parse time ("Duplicate keys 'A' are not allowed
# in hash literals"), wrecking the whole module import. Build the table
# with Ordinal StringComparer and populate via explicit indexer so each
# letter case is its own key.
function Get-KvmCharKeyMap {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseLiteralInitializerForHashtable', '',
        Justification = 'Need a case-sensitive (Ordinal) hashtable to map shifted vs unshifted letters; @{} literal is case-insensitive and would collide on a/A at parse time.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param()
    $h = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
$h['a'] = @('KEY_A');           $h['A'] = @('KEY_LEFTSHIFT','KEY_A')
$h['b'] = @('KEY_B');           $h['B'] = @('KEY_LEFTSHIFT','KEY_B')
$h['c'] = @('KEY_C');           $h['C'] = @('KEY_LEFTSHIFT','KEY_C')
$h['d'] = @('KEY_D');           $h['D'] = @('KEY_LEFTSHIFT','KEY_D')
$h['e'] = @('KEY_E');           $h['E'] = @('KEY_LEFTSHIFT','KEY_E')
$h['f'] = @('KEY_F');           $h['F'] = @('KEY_LEFTSHIFT','KEY_F')
$h['g'] = @('KEY_G');           $h['G'] = @('KEY_LEFTSHIFT','KEY_G')
$h['h'] = @('KEY_H');           $h['H'] = @('KEY_LEFTSHIFT','KEY_H')
$h['i'] = @('KEY_I');           $h['I'] = @('KEY_LEFTSHIFT','KEY_I')
$h['j'] = @('KEY_J');           $h['J'] = @('KEY_LEFTSHIFT','KEY_J')
$h['k'] = @('KEY_K');           $h['K'] = @('KEY_LEFTSHIFT','KEY_K')
$h['l'] = @('KEY_L');           $h['L'] = @('KEY_LEFTSHIFT','KEY_L')
$h['m'] = @('KEY_M');           $h['M'] = @('KEY_LEFTSHIFT','KEY_M')
$h['n'] = @('KEY_N');           $h['N'] = @('KEY_LEFTSHIFT','KEY_N')
$h['o'] = @('KEY_O');           $h['O'] = @('KEY_LEFTSHIFT','KEY_O')
$h['p'] = @('KEY_P');           $h['P'] = @('KEY_LEFTSHIFT','KEY_P')
$h['q'] = @('KEY_Q');           $h['Q'] = @('KEY_LEFTSHIFT','KEY_Q')
$h['r'] = @('KEY_R');           $h['R'] = @('KEY_LEFTSHIFT','KEY_R')
$h['s'] = @('KEY_S');           $h['S'] = @('KEY_LEFTSHIFT','KEY_S')
$h['t'] = @('KEY_T');           $h['T'] = @('KEY_LEFTSHIFT','KEY_T')
$h['u'] = @('KEY_U');           $h['U'] = @('KEY_LEFTSHIFT','KEY_U')
$h['v'] = @('KEY_V');           $h['V'] = @('KEY_LEFTSHIFT','KEY_V')
$h['w'] = @('KEY_W');           $h['W'] = @('KEY_LEFTSHIFT','KEY_W')
$h['x'] = @('KEY_X');           $h['X'] = @('KEY_LEFTSHIFT','KEY_X')
$h['y'] = @('KEY_Y');           $h['Y'] = @('KEY_LEFTSHIFT','KEY_Y')
$h['z'] = @('KEY_Z');           $h['Z'] = @('KEY_LEFTSHIFT','KEY_Z')
$h['1'] = @('KEY_1');           $h['!'] = @('KEY_LEFTSHIFT','KEY_1')
$h['2'] = @('KEY_2');           $h['@'] = @('KEY_LEFTSHIFT','KEY_2')
$h['3'] = @('KEY_3');           $h['#'] = @('KEY_LEFTSHIFT','KEY_3')
$h['4'] = @('KEY_4');           $h['$'] = @('KEY_LEFTSHIFT','KEY_4')
$h['5'] = @('KEY_5');           $h['%'] = @('KEY_LEFTSHIFT','KEY_5')
$h['6'] = @('KEY_6');           $h['^'] = @('KEY_LEFTSHIFT','KEY_6')
$h['7'] = @('KEY_7');           $h['&'] = @('KEY_LEFTSHIFT','KEY_7')
$h['8'] = @('KEY_8');           $h['*'] = @('KEY_LEFTSHIFT','KEY_8')
$h['9'] = @('KEY_9');           $h['('] = @('KEY_LEFTSHIFT','KEY_9')
$h['0'] = @('KEY_0');           $h[')'] = @('KEY_LEFTSHIFT','KEY_0')
$h[' ']  = @('KEY_SPACE')
$h["`t"] = @('KEY_TAB')
$h["`n"] = @('KEY_ENTER')
$h["`r"] = @('KEY_ENTER')
$h['-'] = @('KEY_MINUS');       $h['_'] = @('KEY_LEFTSHIFT','KEY_MINUS')
$h['='] = @('KEY_EQUAL');       $h['+'] = @('KEY_LEFTSHIFT','KEY_EQUAL')
$h['['] = @('KEY_LEFTBRACE');   $h['{'] = @('KEY_LEFTSHIFT','KEY_LEFTBRACE')
$h[']'] = @('KEY_RIGHTBRACE');  $h['}'] = @('KEY_LEFTSHIFT','KEY_RIGHTBRACE')
$h['\'] = @('KEY_BACKSLASH');   $h['|'] = @('KEY_LEFTSHIFT','KEY_BACKSLASH')
$h[';'] = @('KEY_SEMICOLON');   $h[':'] = @('KEY_LEFTSHIFT','KEY_SEMICOLON')
$h["'"] = @('KEY_APOSTROPHE');  $h['"'] = @('KEY_LEFTSHIFT','KEY_APOSTROPHE')
$h[','] = @('KEY_COMMA');       $h['<'] = @('KEY_LEFTSHIFT','KEY_COMMA')
$h['.'] = @('KEY_DOT');         $h['>'] = @('KEY_LEFTSHIFT','KEY_DOT')
$h['/'] = @('KEY_SLASH');       $h['?'] = @('KEY_LEFTSHIFT','KEY_SLASH')
$h['`'] = @('KEY_GRAVE');       $h['~'] = @('KEY_LEFTSHIFT','KEY_GRAVE')
    return $h
}
$script:KvmCharKeyMap = Get-KvmCharKeyMap

function Send-KeyKvm {
    param([string]$VMName, [string]$KeyName)
    # Map common harness key names to Linux KEY_* event names. Anything
    # not in the table passes through verbatim so a sequence can write
    # KEY_LEFTMETA, KEY_F2, etc. directly.
    $map = @{
        'Enter'     = 'KEY_ENTER'
        'Return'    = 'KEY_ENTER'
        'Tab'       = 'KEY_TAB'
        'Escape'    = 'KEY_ESC'
        'Esc'       = 'KEY_ESC'
        'Space'     = 'KEY_SPACE'
        'Backspace' = 'KEY_BACKSPACE'
        'Up'        = 'KEY_UP'
        'Down'      = 'KEY_DOWN'
        'Left'      = 'KEY_LEFT'
        'Right'     = 'KEY_RIGHT'
    }
    $code = $map[$KeyName]
    if (-not $code) { $code = $KeyName }
    & virsh --connect qemu:///system send-key $VMName $code 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Send-KeyKvm: virsh send-key '$code' failed for '$VMName'"
        return $false
    }
    return $true
}

function Send-TextKvm {
    param([string]$VMName, [string]$Text, [int]$CharDelayMs = $script:DefaultCharDelayMs)
    $sentChars = 0
    foreach ($ch in $Text.ToCharArray()) {
        $codes = $script:KvmCharKeyMap["$ch"]
        if (-not $codes) {
            Write-Warning "Send-TextKvm: no keycode for character '$ch' (0x$([byte][char]$ch | ForEach-Object { $_.ToString('X2') })). Skipping."
            continue
        }
        # Splat the chord onto the virsh command line: with `&` the array
        # elements become positional args, which is exactly what virsh
        # send-key wants (one chord per call).
        & virsh --connect qemu:///system send-key $VMName @codes 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Send-TextKvm: virsh send-key failed at char '$ch' (codes=$($codes -join ','))"
            return $false
        }
        $sentChars++
        if ($CharDelayMs -gt 0) { Start-Sleep -Milliseconds $CharDelayMs }
    }
    Write-Debug "      virsh send-key: $sentChars chars sent (${CharDelayMs}ms delay between chars)"
    return $true
}

function Send-Key {
<#
.SYNOPSIS
    Host-aware dispatcher for sending a named key (e.g. Enter, Tab) to
    the guest VM's GUI keyboard input channel.
.DESCRIPTION
    Routes by HostType to the matching backend (Send-KeyHyperV,
    Send-KeyUTM via VNC fallback, Send-KeyKvm). Called by the
    Yuruna.Host Send-Key contract so the host driver does not need
    to import the host-specific helpers itself.
#>
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
    elseif ($HostType -eq "host.ubuntu.kvm") { return Send-KeyKvm -VMName $VMName -KeyName $KeyName }
    else { Write-Warning "Unknown host: $HostType"; return $false }
}

# ── Action: type / typeAndEnter ──────────────────────────────────────────────

function Send-TextHyperV {
    param([string]$VMName, [string]$Text, [int]$CharDelayMs = $script:DefaultCharDelayMs)
    $kb = Get-HyperVKeyboard -VMName $VMName
    if (-not $kb) { return $false }
    try {
        # Defensive modifier-release prefix. The PS/2 controller in
        # Hyper-V keeps a flat "is key down" state per scan code; the
        # only thing that flips a key back to "up" is the matching
        # break code. If a *prior* keyboard event left a modifier in
        # the held state -- a dropped LShift break (0xAA) from a
        # cancelled Send-Text, a make/break race during VM reboot, an
        # operator manually clicking the vmconnect window with Shift
        # held, an IDE focus-steal mid-send -- every subsequent char
        # this function emits inherits that modifier and lands shifted.
        # Symptom: typing the test user (e.g. `yauser1`) produces `YAUSER!` at the login
        # prompt (caught by failure-screenshot OCR). Issuing
        # break codes for LShift + RShift + LCtrl + RCtrl + LAlt +
        # RAlt + LMeta + RMeta as a one-shot scancode burst BEFORE
        # any character typing is sent forces all modifiers to the
        # released state. Break-for-not-pressed is a no-op on PS/2 so
        # this is idempotent and safe for the normal case (no leftover
        # state). E0-prefixed right-side modifiers (RCtrl/RAlt/RMeta)
        # need the E0 escape byte before each release.
        [byte[]]$resetCodes = @(
            0xAA,             # LShift break
            0xB6,             # RShift break
            0x9D,             # LCtrl break
            0xE0, 0x9D,       # RCtrl break (E0-prefixed)
            0xB8,             # LAlt break
            0xE0, 0xB8,       # RAlt break (E0-prefixed)
            0xE0, 0xDB,       # LMeta/LGUI break (E0-prefixed)
            0xE0, 0xDC        # RMeta/RGUI break (E0-prefixed)
        )
        if (-not (Send-ScanCode -Keyboard $kb -Codes $resetCodes)) {
            # Single-shot reset failed -- continue anyway; per-char
            # writes may still succeed, and warning surfaces the
            # divergence in the cycle log.
            Write-Warning "Send-TextHyperV: modifier-reset prefix failed; proceeding without it."
        }
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
        Write-Debug "      TypeScancodes: $charCount chars sent (${CharDelayMs}ms delay between chars, modifier-reset prefix sent)"
        return $true
    } catch {
        Write-Warning "Hyper-V TypeScancodes (text) failed: $_"
        return $false
    }
}

function Test-HardCharsInText {
    # Returns $true if Text has at least one char that needs Shift in
    # MacCharKeyCodes after the keypad remap. Used by Send-TextUTM to
    # decide whether the ShellEscape encoding is needed.
    param([string]$Text)
    foreach ($ch in $Text.ToCharArray()) {
        $e = $script:MacCharKeyCodes["$ch"]
        if ($e -and $e[1]) { return $true }
    }
    return $false
}

function ConvertTo-ShellEscapedText {
    # Rewrite Text as a bash one-liner: eval `echo -e 'TEXT_HEX'` , where
    # every shifted char is replaced by its \xNN escape and three structural
    # chars are also hex-escaped to survive the surrounding quoting:
    #   '  → \x27   (would close the surrounding apostrophe quote)
    #   `  → \x60   (would close the eval-backtick subshell)
    # Backslash is doubled (\\) so echo -e emits a single backslash.
    param([string]$Text)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Text.ToCharArray()) {
        $c = [char]$ch
        if ($c -eq "'") { [void]$sb.Append('\x27'); continue }
        if ($c -eq '\') { [void]$sb.Append('\\');   continue }
        if ($c -eq '`') { [void]$sb.Append('\x60'); continue }
        $e = $script:MacCharKeyCodes["$c"]
        if ($e -and $e[1]) {
            $hex = ([byte][char]$c).ToString('x2')
            [void]$sb.Append("\x$hex")
        } else {
            [void]$sb.Append($c)
        }
    }
    return "eval ``echo -e '$($sb.ToString())'``"
}

function Send-TextUTM {
    param(
        [string]$VMName,
        [string]$Text,
        [int]$CharDelayMs = $script:DefaultCharDelayMs,
        # Opt-in shell-side decoding. When set AND Text contains chars
        # that need Shift after the keypad remap (uppercase letters and
        # shifted punctuation other than '*' / '+'), rewrites Text as
        # `eval \`echo -e 'HEX'\`` so the bash prompt on the guest
        # decodes the shifted chars from \xNN escapes. Default off: at
        # login/password prompts there is no shell to decode the wrapper,
        # so callers in those contexts (Send-Text via passwdPrompt) must
        # NOT pass this switch.
        [switch]$ShellEscape
    )
    # JXA CGEvent typing path.
    if ($ShellEscape -and (Test-HardCharsInText -Text $Text)) {
        $orig = $Text
        $Text = ConvertTo-ShellEscapedText -Text $Text
        Write-Debug "      UTM Send-Text -ShellEscape: '$orig' rewritten to '$Text' (Linux bash decodes \xNN at the prompt)."
    }
    $delaySec = [math]::Max(0.02, $CharDelayMs / 1000.0)

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
        $shifted = if ($entry[1]) { 'true' } else { 'false' }
        if ($entry[1]) { $shiftedCount++ }
        [void]$keyCalls.AppendLine("    sendKey($kc, $shifted);")
        $charIndex++
    }
    Write-Debug "      UTM text send (JXA CGEvent + HID-system shift): $charIndex chars total, $shiftedCount shifted, charDelay=${CharDelayMs}ms"

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
    var kShiftKeyCode = 56;          // Left Shift physical key
    var kShiftFlag    = 0x00020000;  // kCGEventFlagMaskShift
    var src = $.CGEventSourceCreate(1);  // kCGEventSourceStateHIDSystemState

    function sendKey(keyCode, shift) {
        if (shift) {
            // Press physical Left Shift down first; flag is set on the
            // event AND the HID-system source updates the global state
            // so the guest sees Shift as held.
            var shiftDn = $.CGEventCreateKeyboardEvent(src, kShiftKeyCode, true);
            $.CGEventSetFlags(shiftDn, kShiftFlag);
            $.CGEventPost(0, shiftDn);
            delay(0.08);

            var down = $.CGEventCreateKeyboardEvent(src, keyCode, true);
            $.CGEventSetFlags(down, kShiftFlag);
            $.CGEventPost(0, down);
            delay(0.02);
            var up = $.CGEventCreateKeyboardEvent(src, keyCode, false);
            $.CGEventSetFlags(up, kShiftFlag);
            $.CGEventPost(0, up);
            delay(0.06);

            // Release physical Left Shift; no flag so the modifier
            // state clears for the next (potentially unshifted) char.
            var shiftUp = $.CGEventCreateKeyboardEvent(src, kShiftKeyCode, false);
            $.CGEventPost(0, shiftUp);
            delay(0.02);
        } else {
            var down = $.CGEventCreateKeyboardEvent(src, keyCode, true);
            $.CGEventPost(0, down);
            delay(0.01);
            var up = $.CGEventCreateKeyboardEvent(src, keyCode, false);
            $.CGEventPost(0, up);
        }
        delay(__DELAY__);
    }
__KEYCALLS__
    // Final drain: give the macOS event queue time to deliver the last
    // CGEvent(s) to the guest before osascript exits. Without this, the
    // last character(s) can be lost on long commands.
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
    if ($HostType -eq "host.windows.hyper-v") { return Send-TextHyperV -VMName $VMName -Text $Text -CharDelayMs $CharDelayMs }
    elseif ($HostType -eq "host.macos.utm") {
        # Try VNC first (QEMU VMs with built-in VNC server), then JXA/CGEvent.
        $vncOk = Send-TextVNC -VMName $VMName -Text $Text -CharDelayMs $CharDelayMs
        if ($vncOk) { return $true }
        Write-Debug "      VNC unavailable for text, falling back to JXA/CGEvent"
        return Send-TextUTM -VMName $VMName -Text $Text -CharDelayMs $CharDelayMs -ShellEscape:$ShellEscape
    }
    elseif ($HostType -eq "host.ubuntu.kvm") { return Send-TextKvm -VMName $VMName -Text $Text -CharDelayMs $CharDelayMs }
    else { Write-Warning "Unknown host: $HostType"; return $false }
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

    # Run OCR engines sequentially, short-circuiting based on combine mode:
    #   Or  — stop on first detection (true)
    #   And — stop on first non-detection (false)
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
    # Pre-compute screen-space target so logLevel=Debug can report where the
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
    Waits for a labelled button to appear on the VM screen and clicks it.
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
        [int]$PollSeconds = 5,
        [int]$OffsetX = 0,
        [int]$OffsetY = 0
    )
    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    # -Global: a nested -Force without -Global evicts Test.LogDir from
    # the parent script's session state, breaking later top-level calls.
    Import-Module (Join-Path $modulesDir "Test.LogDir.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false

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
    param(
        # HostType retained for backward-compatible call sites. After the
        # Yuruna.Host refactor the host driver dispatches Get-VMScreenshot
        # internally; we accept the legacy arg, surface it in the debug
        # stream, and route through the host facade.
        [string]$HostType,
        [string]$VMName,
        [string[]]$Pattern,
        [int]$TimeoutSeconds = 120,
        [int]$PollSeconds = 5,
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
    Import-Module (Join-Path $modulesDir "Test.LogDir.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    Import-Module (Join-Path $modulesDir "Test.Log.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    $logDir     = Initialize-YurunaLogDir
    # Ring buffer lives INSIDE the cycle folder so a stuck/restarted
    # runner can't overwrite it -- the next cycle gets its own folder.
    # Falls back to $logDir/screens_<VM>/ when no cycle folder is set.
    $screensDir = Get-CycleScreenDir -VMName $VMName -WhatIf:$false
    $historySize = [int]$script:DefaultScreenHistorySize
    if ($historySize -lt 1) { $historySize = 1 }

    # Accumulate all seen text for non-FreshMatch mode (per-engine text merged)
    $allText = ''
    $lastOcrText = ''
    $lastCapturePath = $null

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
            # in lockstep — otherwise orphan .txt files accumulate.
            $allRaws = Get-ChildItem -Path $screensDir -Filter 'raw_*.png' -File -ErrorAction SilentlyContinue |
                       Sort-Object Name
            if ($allRaws.Count -gt $historySize) {
                $allRaws | Select-Object -First ($allRaws.Count - $historySize) | ForEach-Object {
                    $txtSibling = [System.IO.Path]::ChangeExtension($_.FullName, '.txt')
                    Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                    if (Test-Path $txtSibling) { Remove-Item -Path $txtSibling -Force -ErrorAction SilentlyContinue }
                }
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
                        $allText = ($allText + "`n" + $result.AnyText).Trim()
                    }

                    if ($result.Match) {
                        Write-Debug "      Text detected (combine=$combineMode)"
                        return $true
                    }

                    # Fallback: test accumulated text across iterations.
                    # Handles patterns that span multiple poll cycles.
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
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Get-Module powershell-yaml)) {
        if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
            throw "powershell-yaml is required to read sequence files. Install with: Install-Module -Name powershell-yaml -Scope CurrentUser"
        }
        Import-Module powershell-yaml -Global -Verbose:$false -ErrorAction Stop
    }
    try {
        return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Yaml -Ordered)
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
        # Previously returned $true here, which let a typo in a sequence
        # name silently mark the test as passing.
        # Resolve-SequencePath returns $null on miss; show what was searched
        # (Get-SequenceSearchPath enumerates the same tier order) instead of
        # the old "last attempted path" sentinel that invented a location.
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
        # Missing sequence file = setup error. Previously returned $true
        # (silent skip), which masked sequence-name typos and bad mode
        # resolution as test successes.
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
    Import-Module (Join-Path $modulesDir "Test.LogDir.psm1")   -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    Import-Module (Join-Path $modulesDir "Test.RuntimeDir.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
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
    # (today's local-only behaviour); a populated corporate mapping
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
            try { $seqBody = [System.IO.File]::ReadAllText($SequencePath) } catch { Write-Verbose "Perf: read $SequencePath failed: $($_.Exception.Message)" }
            Set-PerfSequenceContext -SequenceName $seqName -SequenceGuid $seqGuid -SequenceRevision $seqRevision -SequenceContent $seqBody
            Set-PerfGuestContext    -GuestKey $GuestKey -VMName $VMName
        } catch {
            Write-Verbose "Perf-context setup failed (non-fatal): $($_.Exception.Message)"
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
            throw "YurunaCycleRestart: status-server /control/start-cycle requested mid-cycle abort at $Label"
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
    # Yuruna.Host's Restart-VMConsole replaces the legacy Test.Start-VM
    # Restart-VMConnect dispatcher. Initialize-YurunaHost is called by
    # Test-Sequence.ps1 / Invoke-TestRunner.ps1 before sequences run.
    [void](Restart-VMConsole -VMName $VMName -Confirm:$false)

    # takeScreenshot debug PNGs land under test/status/captures/sequences/
    # (gitignored runtime data, lives with the rest of the harness state
    # so cleaning a host is one rm -rf status/* away). Sequence name is
    # prefixed onto each filename in Save-DebugScreenshot, so a single
    # flat folder keeps captures organized without a per-sequence subdir.
    $sequencesDir = Split-Path -Parent $SequencePath          # .../test/sequences
    $testRoot     = Split-Path -Parent $sequencesDir          # .../test
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

            # ── retry: re-run inner steps from the top on any failure ──────────
            # `retry` is a control-flow verb, not a normal action -- it does not
            # go through the per-step switch / progress / PASS-FAIL logging
            # pipeline below. Each attempt invokes $invokeStepBlock recursively
            # on the inner `steps:` array; the first attempt that runs every
            # inner step cleanly wins. If all attempts fail, the deepest inner
            # failure label is wrapped with a "retry exhausted (N attempts)"
            # prefix so the operator sees both that retry gave up AND which
            # inner step ran out of patience.
            if ($step.action -eq 'retry') {
                $maxAttempts = $step.maxAttempts ? [int]$step.maxAttempts : 3
                $innerSteps  = @($step.steps)
                if ($innerSteps.Count -eq 0) {
                    Write-Warning "    [$stepNum/$($Steps.Count)] retry block has no inner steps; treating as failure."
                    $script:LastFailureLabel       = 'retry: empty steps block'
                    $script:LastFailureDescription = $desc
                    $script:LastFailedAction       = 'retry'
                    $script:LastFailedStepNumber   = $stepNum
                    return $false
                }
                $attemptOk = $false
                for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                    Write-Information ("    [{0}/{1}] retry attempt {2}/{3}: {4}" -f $stepNum, $Steps.Count, $attempt, $maxAttempts, $desc)
                    $attemptOk = & $invokeStepBlock -Steps $innerSteps -ParentOrdinal $stepNum -ParentAction 'retry'
                    if ($attemptOk) {
                        Write-Information ("    [{0}/{1}] retry succeeded on attempt {2}/{3}" -f $stepNum, $Steps.Count, $attempt, $maxAttempts)
                        break
                    }
                    if ($attempt -lt $maxAttempts) {
                        Write-Warning ("    [{0}/{1}] retry attempt {2}/{3} failed; restarting from step 1 of {4}" -f $stepNum, $Steps.Count, $attempt, $maxAttempts, $innerSteps.Count)
                    }
                }
                if (-not $attemptOk) {
                    $script:LastFailureLabel     = "retry exhausted ($maxAttempts attempts): $script:LastFailureLabel"
                    $script:LastFailedStepNumber = $stepNum
                    return $false
                }
                continue
            }

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
        switch ($step.action) {
            "waitForSeconds" {
                $secs = [int]$step.seconds
                Write-Debug "      Waiting $secs seconds..."
                # PROGRESS-INLINE-TICK: reference implementation of the per-second
                # progress loop. Keep other PROGRESS-INLINE-TICK blocks in sync.
                for ($r = $secs; $r -gt 0; $r--) {
                    $pct = [math]::Round((($secs - $r) / [math]::Max($secs,1)) * 100)
                    Write-ProgressTick -Activity "waitForSeconds" -Status "${r}s remaining" -PercentComplete $pct
                    Start-Sleep -Seconds 1
                }
                Write-ProgressTick -Activity "waitForSeconds" -Completed
            }
            "pressKey" {
                $keyName = $step.name
                Write-Debug "      Sending key '$keyName'..."
                $ok = Send-Key -HostType $HostType -VMName $VMName -KeyName $keyName
            }
            "break" {
                # Cooperative breakpoint. Two ways out:
                #  (a) Operator deletes the marker file -> just resume.
                #  (b) Operator clicks "Continue" in the status UI ->
                #      status server touches control.break-continue;
                #      on detection we (optionally) Restore-VMDiskSnapshot
                #      + Start-VM so the sequence picks up from a known
                #      base, then resume.
                # The intent is "stop here so I can take control"; it is
                # NOT a failure -- the step succeeds either way.
                #
                # YURUNA_BREAK_DISABLED=1 turns the action into a no-op
                # (logs a warning and continues), so CI / unattended
                # runs do not deadlock on an interactive primitive.
                #
                # The marker filename includes the step number so two
                # breakpoints in the same sequence do not collide. The
                # path is printed at INFORMATION level so an operator
                # tailing the run log can copy-paste the rm command.
                #
                # break.id (optional): when set, Continue calls
                # Restore-VMDiskSnapshot -Id <id> followed by Start-VM,
                # mirroring the convention that saveDiskSnapshot leaves
                # a same-id snapshot+rename behind. Without break.id the
                # Continue button still works but skips the snapshot
                # restore (just resumes).
                if ($env:YURUNA_BREAK_DISABLED -eq '1') {
                    Write-Warning "      break: YURUNA_BREAK_DISABLED=1 -- skipping breakpoint."
                    $ok = $true
                } else {
                    if (-not (Get-Command Get-CycleGuestDataFolder -ErrorAction SilentlyContinue)) {
                        $logModule = Join-Path $PSScriptRoot 'Test.Log.psm1'
                        if (Test-Path $logModule) { Import-Module $logModule -Global -Force -Verbose:$false }
                    }
                    $diagFolder = Get-CycleGuestDataFolder -VMName $VMName
                    if (-not $diagFolder) {
                        # No cycle folder established -- fall back to the
                        # log dir root so the operator still has a path
                        # to delete.
                        $diagFolder = $logDir
                    }
                    $markerName = ".yuruna-break-{0:D3}.lock" -f [int]$stepNum
                    $markerPath = Join-Path $diagFolder $markerName
                    $reason = Expand-Variable $step.reason $vars
                    $breakSnapshotId = Expand-Variable $step.id $vars
                    $bodyLines = @(
                        "Yuruna sequence breakpoint",
                        "VM:       $VMName",
                        "GuestKey: $GuestKey",
                        "Step:     $stepNum/$($steps.Count)",
                        "Reason:   $(if ($reason) { $reason } else { '(no reason supplied)' })",
                        "Snapshot: $(if ($breakSnapshotId) { $breakSnapshotId } else { '(none -- Continue resumes without snapshot restore)' })",
                        "",
                        "To resume:",
                        "  - Click 'Continue' in the status UI (http://localhost:8080/status/)",
                        "    which restores the snapshot above (if set), starts the VM,",
                        "    then deletes the marker; or",
                        "  - Delete this file manually:",
                        "      Remove-Item -LiteralPath '$markerPath'",
                        "    or, on a POSIX shell:",
                        "      rm `"$markerPath`""
                    )
                    Set-Content -LiteralPath $markerPath -Value ($bodyLines -join [Environment]::NewLine) -Encoding utf8 -Force

                    # Break-active sidecar -- the status UI polls this
                    # from /runtime/break-active.json to decide whether
                    # the Continue button is live.
                    $breakActivePath   = Join-Path $runtimeDir 'break-active.json'
                    $breakContinueFlag = Join-Path $runtimeDir 'control.break-continue'
                    # Discard any stale Continue flag from a previous
                    # break that crashed before consuming it. Without
                    # this, the new break would auto-resume on the
                    # first poll tick.
                    Remove-Item -LiteralPath $breakContinueFlag -Force -ErrorAction SilentlyContinue
                    try {
                        $breakDoc = [ordered]@{
                            guestKey   = $GuestKey
                            vmName     = $VMName
                            hostType   = $HostType
                            stepNum    = [int]$stepNum
                            stepCount  = [int]$steps.Count
                            snapshotId = $breakSnapshotId
                            reason     = if ($reason) { [string]$reason } else { '' }
                            markerPath = [string]$markerPath
                            startedAt  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                        }
                        $tmp = "$breakActivePath.tmp"
                        $breakDoc | ConvertTo-Json -Compress | Set-Content -Path $tmp -Encoding utf8NoBOM
                        Move-Item -Path $tmp -Destination $breakActivePath -Force
                    } catch {
                        Write-Verbose "break-active.json write failed: $($_.Exception.Message)"
                    }

                    Write-Information "    [break] Paused at step $stepNum. Click Continue in the status UI, or delete '$markerPath' to resume."
                    & $writeCurrentAction "[$stepNum/$($steps.Count)] break (waiting for operator: $markerName)"

                    $resumedVia = 'marker-delete'
                    while ($true) {
                        if (Test-Path -LiteralPath $breakContinueFlag) {
                            $resumedVia = 'continue-button'
                            Remove-Item -LiteralPath $breakContinueFlag -Force -ErrorAction SilentlyContinue
                            break
                        }
                        if (-not (Test-Path -LiteralPath $markerPath)) {
                            break
                        }
                        Start-Sleep -Seconds 1
                    }

                    if ($resumedVia -eq 'continue-button') {
                        # Continue clicked: optionally restore the snapshot, then
                        # start the VM (loadDiskSnapshot leaves it stopped on every
                        # host). Failures are warned but don't fail the break --
                        # the operator deliberately said "continue", so the
                        # sequence should keep going and any post-restore step
                        # that needs a live guest will fail with its own message.
                        if ($breakSnapshotId) {
                            if (Get-Command Restore-VMDiskSnapshot -ErrorAction SilentlyContinue) {
                                Write-Information "    [break/continue] Restoring snapshot '$breakSnapshotId' on $VMName..."
                                try {
                                    $restored = [bool](Restore-VMDiskSnapshot -VMName $VMName -Id $breakSnapshotId -Confirm:$false)
                                    if (-not $restored) {
                                        Write-Warning "    [break/continue] Restore-VMDiskSnapshot returned `$false for '$VMName/$breakSnapshotId'; continuing anyway."
                                    }
                                } catch {
                                    Write-Warning "    [break/continue] Restore-VMDiskSnapshot threw: $($_.Exception.Message). Continuing anyway."
                                }
                            } else {
                                Write-Warning "    [break/continue] Restore-VMDiskSnapshot not loaded; cannot restore snapshot '$breakSnapshotId'."
                            }
                        }
                        if (Get-Command Start-VM -ErrorAction SilentlyContinue) {
                            Write-Information "    [break/continue] Starting $VMName..."
                            try {
                                $startRes = Start-VM -VMName $VMName -Confirm:$false
                                if ($startRes -is [hashtable] -and -not $startRes.success) {
                                    Write-Warning "    [break/continue] Start-VM returned failure: $($startRes.errorMessage). Continuing anyway."
                                }
                            } catch {
                                Write-Warning "    [break/continue] Start-VM threw: $($_.Exception.Message). Continuing anyway."
                            }
                        } else {
                            Write-Warning "    [break/continue] Start-VM not loaded; VM remains stopped."
                        }
                        # Marker may still be present (Continue is the back-
                        # channel signal, not a marker delete). Remove it so the
                        # next cycle doesn't see a stale marker.
                        Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
                    }

                    # Tear down the UI sidecar so the Continue button vanishes.
                    Remove-Item -LiteralPath $breakActivePath -Force -ErrorAction SilentlyContinue

                    Write-Information "    [break] Resumed (via $resumedVia)."
                    $ok = $true
                }
            }
            "saveDiskSnapshot" {
                # Disk-only snapshot via Yuruna.Host's Save-VMDiskSnapshot
                # contract. Stops the VM first (graceful, force-fallback
                # via the host driver) and leaves it stopped on return,
                # so a sequence wanting to keep going must follow with
                # an explicit start step (host-specific). Pre-existing
                # snapshots with the same Id are overwritten.
                #
                # Save-VMDiskSnapshot also renames the VM to $snapId
                # (Hyper-V / KVM full support; UTM best-effort) so the
                # next cycle's Remove-TestVMFiles.ps1 leaves the
                # persisted VM alone. On success we update $VMName so
                # every subsequent step (break, fetchAndExecute, etc.)
                # targets the new persisted name -- otherwise SSH /
                # console calls would race against a name that no
                # longer exists.
                $snapId = Expand-Variable $step.id $vars
                if (-not $snapId) {
                    Write-Warning "      saveDiskSnapshot: missing required 'id' field on step; failing step."
                    $ok = $false
                    break
                }
                if (-not (Get-Command Save-VMDiskSnapshot -ErrorAction SilentlyContinue)) {
                    Write-Warning "      saveDiskSnapshot: Save-VMDiskSnapshot not loaded (Yuruna.Host import missing)."
                    $ok = $false
                    break
                }
                Write-Debug "      Saving disk snapshot '$snapId' for $VMName"
                try {
                    $ok = [bool](Save-VMDiskSnapshot -VMName $VMName -Id $snapId -Confirm:$false)
                } catch {
                    Write-Warning "      saveDiskSnapshot: $($_.Exception.Message)"
                    $ok = $false
                }
                if ($ok -and $VMName -ne $snapId) {
                    Write-Information "      saveDiskSnapshot: VM renamed '$VMName' -> '$snapId'; subsequent steps will target '$snapId'." -InformationAction Continue
                    $VMName = $snapId
                }
            }
            "loadDiskSnapshot" {
                # Restore a previously-saved disk-only snapshot via
                # Yuruna.Host's Restore-VMDiskSnapshot contract, then
                # start the VM so the next step can interact with a live
                # guest. The host driver stops the VM first if running
                # and leaves it stopped on return from the restore call;
                # this handler then re-starts it (Hyper-V / KVM / UTM all
                # expose Start-VM with a uniform -VMName signature).
                # RAM-state is not restored -- the guest boots fresh
                # from the snapshot disk, so callers must expect a
                # re-DHCP / SSH re-handshake (gate downstream consumers
                # on sshWaitReady).
                $snapId = Expand-Variable $step.id $vars
                if (-not $snapId) {
                    Write-Warning "      loadDiskSnapshot: missing required 'id' field on step; failing step."
                    $ok = $false
                    break
                }
                if (-not (Get-Command Restore-VMDiskSnapshot -ErrorAction SilentlyContinue)) {
                    Write-Warning "      loadDiskSnapshot: Restore-VMDiskSnapshot not loaded (Yuruna.Host import missing)."
                    $ok = $false
                    break
                }
                Write-Debug "      Restoring disk snapshot '$snapId' for $VMName"
                try {
                    $ok = [bool](Restore-VMDiskSnapshot -VMName $VMName -Id $snapId -Confirm:$false)
                } catch {
                    Write-Warning "      loadDiskSnapshot: $($_.Exception.Message)"
                    $ok = $false
                }
                if ($ok) {
                    if (-not (Get-Command Start-VM -ErrorAction SilentlyContinue)) {
                        Write-Warning "      loadDiskSnapshot: Start-VM not loaded (Yuruna.Host import missing); cannot start '$VMName' after restore."
                        $ok = $false
                    } else {
                        Write-Debug "      Starting $VMName after snapshot restore"
                        try {
                            $startRes = Start-VM -VMName $VMName -Confirm:$false
                            if ($startRes -is [hashtable] -and -not $startRes.success) {
                                Write-Warning "      loadDiskSnapshot: Start-VM returned failure: $($startRes.errorMessage)"
                                $ok = $false
                            }
                        } catch {
                            Write-Warning "      loadDiskSnapshot: Start-VM threw: $($_.Exception.Message)"
                            $ok = $false
                        }
                    }
                }
            }
            "saveSystemDiagnostic" {
                # Mid-sequence checkpoint dump. SSHes into the guest,
                # runs automation/Get-SystemDiagnostic.ps1, and writes
                # the captured text into the per-guest data folder under
                # the cycleFolder. Soft-failing on every rung -- the
                # sequence step is informational, so an unreachable
                # guest or missing pwsh does not break the sequence.
                # Capture is opt-in: place this step explicitly wherever
                # a diagnostic snapshot is wanted (e.g. right after a
                # workload deploy, before tearing down state, or as the
                # final step in a guest sequence to mirror the old
                # auto-call). The runner no longer fires it automatically.
                #
                # 'id' is required so that two captures inside the same
                # sequence land in distinct files. Filename shape:
                # yyyy-MM-dd.HH-mm.system.diagnostic.<id>.txt; the
                # interpreter rejects a step that omits the field,
                # making "I forgot the id" a sequence-validation failure
                # at the step rather than a silently-clobbered file.
                $diagId = Expand-Variable $step.id $vars
                if (-not $diagId) {
                    Write-Warning "      saveSystemDiagnostic: missing required 'id' field on step; failing step."
                    $ok = $false
                    break
                }
                if (-not (Get-Command Get-CycleGuestDataFolder -ErrorAction SilentlyContinue)) {
                    $logModule = Join-Path $PSScriptRoot 'Test.Log.psm1'
                    if (Test-Path $logModule) { Import-Module $logModule -Global -Force -Verbose:$false }
                }
                if (-not (Get-Command Save-GuestDiagnostic -ErrorAction SilentlyContinue)) {
                    $diagModule = Join-Path $PSScriptRoot 'Test.Diagnostic.psm1'
                    if (Test-Path $diagModule) { Import-Module $diagModule -Global -Force -Verbose:$false }
                }
                $diagFolder = Get-CycleGuestDataFolder -VMName $VMName
                if (-not $diagFolder) {
                    Write-Warning "      saveSystemDiagnostic: no cycle folder established; skipping."
                    $ok = $true
                } else {
                    Write-Debug "      Capturing diagnostic '$diagId' from $VMName to $diagFolder"
                    try {
                        $null = Save-GuestDiagnostic -VMName $VMName -GuestKey $GuestKey -OutputFolder $diagFolder -Id $diagId
                    } catch {
                        Write-Warning "      saveSystemDiagnostic: $($_.Exception.Message)"
                    }
                    # Step itself does not fail the sequence; the
                    # diagnostic file may or may not have landed, but
                    # the cycleGuestDataFolder still exists for the
                    # operator to inspect.
                    $ok = $true
                }
            }
            "callExtension" {
                # Side-effecting call into the active extension for an
                # area. Args are a named parameter object; values may
                # contain ${var} or ${ext:...} placeholders, which are
                # resolved before the call. Used for commits like
                # authentication.SetPassword that must run AFTER an interactive
                # rotation succeeds -- substitutions are not allowed to
                # have side effects, so this is the dedicated write verb.
                $methodFqn = [string]$step.method
                if (-not $methodFqn -or $methodFqn -notmatch '^([A-Za-z0-9_]+)\.([A-Za-z][A-Za-z0-9_-]*)$') {
                    throw "callExtension: 'method' must be 'area.Method' (got '$methodFqn')."
                }
                $callArea   = $matches[1]
                $callMethod = $matches[2]
                $resolvedArgs = @{}
                if ($step.args) {
                    foreach ($argKey in $step.args.Keys) {
                        $val = $step.args[$argKey]
                        if ($val -is [string]) { $val = Expand-Variable $val $vars }
                        $resolvedArgs[$argKey] = $val
                    }
                }
                $loaderPath = Join-Path $PSScriptRoot 'Test.Extension.psm1'
                if (Test-Path $loaderPath) { Import-Module $loaderPath -Global -Force -Verbose:$false }
                $extName = (@(Get-ActiveExtensionName -Area $callArea))[0]
                [void](Import-Extension -Area $callArea)
                $cmd = Resolve-ExtensionMethod -Area $callArea -ExtensionName $extName -Method $callMethod
                Write-Debug "      callExtension: $callArea/$extName.$callMethod ($($resolvedArgs.Keys -join ', '))"
                try {
                    & $cmd @resolvedArgs
                    $ok = $true
                } catch {
                    Write-Warning "callExtension $callArea.$callMethod failed: $($_.Exception.Message)"
                    $ok = $false
                }
            }
            "inputText" {
                $text = Expand-Variable $step.text $vars
                $masked = ($step.sensitive -and -not $ShowSensitive) ? "***" : $text
                $charDelay = $step.charDelayMs ? [int]$step.charDelayMs : $script:DefaultCharDelayMs
                Write-Debug "      Typing: '$masked' (charDelay=${charDelay}ms)"
                # -ShellEscape: shell-targeted action, so it's safe to let
                # Send-TextUTM wrap shifted chars in a bash decode wrapper
                # (no-op on Hyper-V/KVM and on text with no hard chars).
                $ok = Send-Text -HostType $HostType -VMName $VMName -Text $text -CharDelayMs $charDelay -ShellEscape
            }
            { $_ -in 'inputTextAndEnter','typeAndEnter' } {
                # typeAndEnter is the pre-rename alias still used by project
                # sequences (e.g. workload.guest.ubuntu.server.24.k8s.website.yml
                # in yuruna-project). Documented at line 113 in this file's
                # action catalog; kept as an alias so a stale project clone
                # doesn't break a runner that updated the framework alone.
                $text = Expand-Variable $step.text $vars
                $masked = ($step.sensitive -and -not $ShowSensitive) ? "***" : $text
                $delaySeconds = $step.delaySeconds ? [double]$step.delaySeconds : 2
                $charDelay = $step.charDelayMs ? [int]$step.charDelayMs : $script:DefaultCharDelayMs
                Write-Debug "      Typing: '$masked' + Enter (charDelay=${charDelay}ms, delay ${delaySeconds}s)"
                # -ShellEscape: shell-targeted action — see "inputText" above.
                $ok = Send-Text -HostType $HostType -VMName $VMName -Text $text -CharDelayMs $charDelay -ShellEscape
                if ($ok -ne $false) {
                    # PROGRESS-INLINE-TICK: reference impl lives in "waitForSeconds"
                    $delaySecsInt = [int][math]::Ceiling($delaySeconds)
                    for ($r = $delaySecsInt; $r -gt 0; $r--) {
                        $pct = [math]::Round((($delaySecsInt - $r) / [math]::Max($delaySecsInt,1)) * 100)
                        Write-ProgressTick -Activity "inputTextAndEnter" -Status "drain ${r}s" -PercentComplete $pct
                        Start-Sleep -Seconds 1
                    }
                    Write-ProgressTick -Activity "inputTextAndEnter" -Completed
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
                $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : $script:DefaultTimeoutSeconds
                $poll = $step.pollSeconds ? [int]$step.pollSeconds : $script:DefaultPollSeconds
                $fresh = $step.freshMatch -eq $true
                $tailLines = $step.freshMatchTailLines ? [int]$step.freshMatchTailLines : 12
                $patternDisplay = $patterns -join "' | '"
                Write-Debug "      Watching screen for: '$patternDisplay' (timeout: ${timeout}s$(if ($fresh) { ', freshMatch' })$(if ($failurePatterns.Count) { ", $($failurePatterns.Count) failurePatterns" }))"
                $ok = Wait-ForText -HostType $HostType -VMName $VMName -Pattern $patterns `
                    -TimeoutSeconds $timeout -PollSeconds $poll -FreshMatch $fresh `
                    -FreshMatchTailLines $tailLines `
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
                $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : $script:DefaultTimeoutSeconds
                $poll = $step.pollSeconds ? [int]$step.pollSeconds : $script:DefaultPollSeconds
                $fresh = $step.freshMatch -eq $true
                $tailLines = $step.freshMatchTailLines ? [int]$step.freshMatchTailLines : 12
                $patternDisplay = $patterns -join "' | '"
                Write-Debug "      Watching screen for: '$patternDisplay' (timeout: ${timeout}s$(if ($fresh) { ', freshMatch' })$(if ($failurePatterns.Count) { ", $($failurePatterns.Count) failurePatterns" }))"
                $ok = Wait-ForText -HostType $HostType -VMName $VMName -Pattern $patterns `
                    -TimeoutSeconds $timeout -PollSeconds $poll -FreshMatch $fresh `
                    -FreshMatchTailLines $tailLines `
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
                    # -ShellEscape: shell-targeted action — see "inputText" above.
                    $ok = Send-Text -HostType $HostType -VMName $VMName -Text $text -CharDelayMs $charDelay -ShellEscape
                    if ($ok -ne $false) {
                        # PROGRESS-INLINE-TICK: reference impl lives in "waitForSeconds"
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
            "passwdPrompt" {
                # Like waitForAndEnter, but `text` is always treated as
                # sensitive (no `sensitive` field needed) — for PAM
                # password prompts.
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
                $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : $script:DefaultTimeoutSeconds
                $poll = $step.pollSeconds ? [int]$step.pollSeconds : $script:DefaultPollSeconds
                $fresh = $step.freshMatch -eq $true
                $tailLines = $step.freshMatchTailLines ? [int]$step.freshMatchTailLines : 12
                $patternDisplay = $patterns -join "' | '"
                Write-Debug "      Watching screen for: '$patternDisplay' (timeout: ${timeout}s$(if ($fresh) { ', freshMatch' })$(if ($failurePatterns.Count) { ", $($failurePatterns.Count) failurePatterns" }))"
                $ok = Wait-ForText -HostType $HostType -VMName $VMName -Pattern $patterns `
                    -TimeoutSeconds $timeout -PollSeconds $poll -FreshMatch $fresh `
                    -FreshMatchTailLines $tailLines `
                    -FailurePattern $failurePatterns
                if ($ok -ne $false) {
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
                    # Always sensitive — only show plaintext when -ShowSensitive.
                    $masked = $ShowSensitive ? $text : "***"
                    $delaySeconds = $step.delaySeconds ? [double]$step.delaySeconds : 2
                    $charDelay = $step.charDelayMs ? [int]$step.charDelayMs : $script:DefaultCharDelayMs
                    Write-Debug "      Typing: '$masked' + Enter (charDelay=${charDelay}ms, delay ${delaySeconds}s)"
                    $ok = Send-Text -HostType $HostType -VMName $VMName -Text $text -CharDelayMs $charDelay
                    if ($ok -ne $false) {
                        # PROGRESS-INLINE-TICK: reference impl lives in "waitForSeconds"
                        $delaySecsInt = [int][math]::Ceiling($delaySeconds)
                        for ($r = $delaySecsInt; $r -gt 0; $r--) {
                            $pct = [math]::Round((($delaySecsInt - $r) / [math]::Max($delaySecsInt,1)) * 100)
                            Write-ProgressTick -Activity "passwdPrompt" -Status "drain ${r}s" -PercentComplete $pct
                            Start-Sleep -Seconds 1
                        }
                        Write-ProgressTick -Activity "passwdPrompt" -Completed
                        Start-Sleep -Milliseconds 800
                        $ok = Send-Key -HostType $HostType -VMName $VMName -KeyName "Enter"
                    }
                }
            }
            "tapOn" {
                # Accept either a single string or array of candidate labels
                # (useful when OCR might split "Install" as "lnstall" in some engines
                # — list both forms and first hit wins).
                $rawLabels = $step.label
                if ($rawLabels -is [System.Collections.IEnumerable] -and $rawLabels -isnot [string]) {
                    [string[]]$labels = $rawLabels | ForEach-Object { Expand-Variable $_ $vars }
                } else {
                    [string[]]$labels = @(Expand-Variable $rawLabels $vars)
                }
                $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : $script:DefaultTimeoutSeconds
                $poll    = $step.pollSeconds    ? [int]$step.pollSeconds    : $script:DefaultPollSeconds
                $offX    = $step.offsetX        ? [int]$step.offsetX        : 0
                $offY    = $step.offsetY        ? [int]$step.offsetY        : 0
                $labelDisplay = $labels -join "' | '"
                Write-Debug "      Waiting for button '$labelDisplay' (timeout: ${timeout}s)"
                $ok = Invoke-TapOn -HostType $HostType -VMName $VMName -Label $labels `
                    -TimeoutSeconds $timeout -PollSeconds $poll -OffsetX $offX -OffsetY $offY
            }
            "takeScreenshot" {
                $label = $step.label ?? "step$stepNum"
                Save-DebugScreenshot -VMName $VMName -Label $label -OutputDir $screenshotDir | Out-Null
            }
            "fetchAndExecute" {
                $text = Expand-Variable $step.text $vars
                $delaySeconds = $step.delaySeconds ? [double]$step.delaySeconds : 2
                $charDelay = $step.charDelayMs ? [int]$step.charDelayMs : $script:DefaultCharDelayMs
                Write-Debug "      fetchAndExecute: typing '$text' + Enter"
                # -ShellEscape: shell-targeted action — see "inputText" above.
                $ok = Send-Text -HostType $HostType -VMName $VMName -Text $text -CharDelayMs $charDelay -ShellEscape
                if ($ok -ne $false) {
                    # PROGRESS-INLINE-TICK: reference impl lives in "waitForSeconds"
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
                    $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : $script:DefaultTimeoutSeconds
                    $poll = $step.pollSeconds ? [int]$step.pollSeconds : $script:DefaultPollSeconds
                    # Default failure pattern matches fetch-and-execute.sh's
                    # rc!=0 end marker. Previously the script always printed
                    # the success marker regardless of inner exit code, so a
                    # failed inner script (e.g. workload script's `docker run`
                    # failing on a broken upstream registry) appeared as PASS
                    # in the harness -- only the next step's downstream
                    # symptom surfaced the actual failure. With distinct
                    # markers + this FailurePattern, fetchAndExecute fails
                    # at the same poll cadence as it succeeds. Sequences can
                    # override via $step.failPattern; default suits every
                    # caller of fetch-and-execute.sh in the repo.
                    $failPatterns = @()
                    if ($step.failPattern) {
                        $failPatterns = @(Expand-Variable $step.failPattern $vars)
                    } elseif ($waitPattern -match '^\s*FETCHED AND EXECUTED:') {
                        $failPatterns = @('FETCH AND EXECUTE FAILED:')
                    }
                    Write-Debug "      fetchAndExecute: waiting for '$waitPattern' (timeout: ${timeout}s, freshMatch); failurePatterns=$($failPatterns -join ', ')"
                    $ok = Wait-ForText -HostType $HostType -VMName $VMName -Pattern @($waitPattern) `
                        -TimeoutSeconds $timeout -PollSeconds $poll -FreshMatch $true `
                        -FreshMatchTailLines 12 -FailurePattern $failPatterns
                }
            }
            "sshWaitReady" {
                # Wait until the guest accepts SSH with the harness key.
                # Handshakes all the way to an authenticated shell (not just TCP/22).
                $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : $script:DefaultTimeoutSeconds
                $poll    = $step.pollSeconds    ? [int]$step.pollSeconds    : $script:DefaultPollSeconds
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
                $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : $script:DefaultTimeoutSeconds
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
                $timeout = $step.timeoutSeconds ? [int]$step.timeoutSeconds : $script:DefaultTimeoutSeconds
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
                # Unknown action = hard fail. Previously this was a warning-only
                # no-op, which silently passed the step (since $ok stayed $true
                # from the per-step default). A typo in a sequence JSON — e.g.
                # "tapButton" instead of "tapOn" — would then
                # march the sequence forward without running the intended gate.
                Write-Warning "Unknown action '$($step.action)' — treating as failure."
                $ok = $false
            }
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
            # The OUTER call site reads $script:LastFailure* below to write
            # last_failure.json + the failure screenshot. Capturing here (and
            # only returning $false) keeps transient retry-attempt failures
            # from leaving a stale last_failure.json behind.
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
                "pressKey"          { $actionLabel = "pressKey: $($step.name)" }
                "inputText"         { $actionLabel = "inputText" }
                { $_ -in 'inputTextAndEnter','typeAndEnter' } { $actionLabel = $step.action }
                "waitForAndEnter" {
                    $rawPatterns = $step.pattern
                    if ($rawPatterns -is [System.Collections.IEnumerable] -and $rawPatterns -isnot [string]) {
                        $patternDisplay = ($rawPatterns | ForEach-Object { Expand-Variable $_ $vars }) -join "' | '"
                    } else {
                        $patternDisplay = Expand-Variable $rawPatterns $vars
                    }
                    $actionLabel = "waitForAndEnter: `"$patternDisplay`""
                }
                "passwdPrompt" {
                    $rawPatterns = $step.pattern
                    if ($rawPatterns -is [System.Collections.IEnumerable] -and $rawPatterns -isnot [string]) {
                        $patternDisplay = ($rawPatterns | ForEach-Object { Expand-Variable $_ $vars }) -join "' | '"
                    } else {
                        $patternDisplay = Expand-Variable $rawPatterns $vars
                    }
                    $actionLabel = "passwdPrompt: `"$patternDisplay`""
                }
                "fetchAndExecute"  { $actionLabel = "fetchAndExecute: `"$(Expand-Variable $step.text $vars)`"" }
                "sshWaitReady"     { $actionLabel = "sshWaitReady" }
                "sshExec"          { $actionLabel = "sshExec: `"$(Expand-Variable $step.command $vars)`"" }
                "sshFetchAndExecute" { $actionLabel = "sshFetchAndExecute: `"$(Expand-Variable $step.command $vars)`"" }
                "saveDiskSnapshot" { $actionLabel = "saveDiskSnapshot: `"$(Expand-Variable $step.id $vars)`"" }
                "loadDiskSnapshot" { $actionLabel = "loadDiskSnapshot: `"$(Expand-Variable $step.id $vars)`"" }
            }

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
    $result = & $invokeStepBlock -Steps $steps
    if (-not $result) {
        # Build the failure-context JSON from the deepest captured context.
        # For a retry-exhausted failure, $script:LastFailureLabel was already
        # wrapped in "retry exhausted (N attempts): ..." by the retry handler,
        # and $script:LastFailedStepNumber is the OUTER retry step's number
        # (not the inner sub-step) so the operator sees the outer position.
        $failureInfo = @{
            stepNumber  = $script:LastFailedStepNumber
            totalSteps  = $steps.Count
            action      = $script:LastFailureLabel
            description = $script:LastFailureDescription
            vmName      = $VMName
            guestKey    = $GuestKey
            timestamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        } | ConvertTo-Json
        $failureFile = Join-Path $logDir "last_failure.json"
        Set-Content -Path $failureFile -Value $failureInfo -Force -ErrorAction SilentlyContinue

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
    # Preserve diagnostics for the crash
    try {
        $crashInfo = @{
            error      = "$_"
            origin     = $_.InvocationInfo ? $_.InvocationInfo.PositionMessage : $null
            stack      = $_.ScriptStackTrace
            vmName     = $VMName
            guestKey   = $GuestKey
            sequence   = $SequencePath
            timestamp  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        } | ConvertTo-Json -Depth 4
        Set-Content -Path (Join-Path $logDir "last_failure.json") -Value $crashInfo -Force -ErrorAction SilentlyContinue
    } catch { Write-Verbose "Could not write last_failure.json: $_" }
    return $false
  }
}

Export-ModuleMember -Function Invoke-Sequence, Invoke-SequenceByName, Resolve-SequencePath, Get-SequenceSearchPath, Get-SequenceMode, Get-SequenceModePath, Get-ProjectTestSearchDir, `
    Find-ProjectSequenceFile, Read-SequenceFile, Send-Text, Send-Key, Send-Click
