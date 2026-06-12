<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42634a21-7352-4663-b6f4-cff499ce7a2b
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

# Per-host I/O backends consumed by Test.HostIO's registry.
# Backend inventory and registry contract: https://yuruna.link/host-io
$script:DefaultCharDelayMs = 20
# Settle window applied after Send-TextHyperV's batched scancode emit
# (and after the JXA UTM CGEvent path). The guest's PS/2 buffer drains
# asynchronously; without a settle the next action (an Enter press,
# a screenshot capture) can race the buffer and observe a half-typed
# field. 200 ms was measured as the empirical drain ceiling across the
# 16-char user/password strings used in login sequences on this
# hardware. Operators tuning a slow guest or a fast one can override via
# test.config.yml's vmCommunication.settleMs.
$script:DefaultSettleMs    = 200
$script:DefaultVncPort     = 5900
$script:TransportConfigLastRefreshUtc = [DateTime]::MinValue
# 1-second floor between refreshes. A step boundary is the natural
# trigger (and step boundaries are >= 1 s apart in normal cycles), so
# this throttles intra-step thrash without delaying inter-step pickup.
$script:TransportConfigRefreshMinSeconds = 1.0

Import-Module (Join-Path $PSScriptRoot 'Test.Config.psm1') -Global -Force

function Update-TransportDefault {
    <#
    .SYNOPSIS
        Refresh transport-layer defaults from test.config.yml at most
        once per step boundary.
    .DESCRIPTION
        Module-load callers and step-boundary callers (the engine, in
        a future block) both go through this function. The mtime-keyed
        cache in Read-TestConfig and the
        $script:TransportConfigRefreshMinSeconds throttle below keep the
        cost flat regardless of how many -Force imports a step issues.
        Race-tolerant: a mid-write file that parses to $null is retried
        once after 250 ms, then falls through to the prior in-memory
        defaults rather than failing the module load.

        The throttle check sits ABOVE the `-Force` shortcut. A -Force
        re-import of Test.Transport itself re-runs the module body and
        calls into here -- if -Force bypassed the throttle, every
        cross-module -Force import would re-parse test.config.yml,
        exactly the case the throttle was designed to defeat. -Force
        only takes effect when `$script:TransportConfigLastRefreshUtc`
        is at its initial MinValue (the genuine first load).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Idempotent mtime-cached read; the only state change is two module-scoped defaults.')]
    param([switch]$Force)
    $now = [DateTime]::UtcNow
    $isFirstLoad = ($script:TransportConfigLastRefreshUtc -eq [DateTime]::MinValue)
    if (-not $isFirstLoad) {
        $elapsed = ($now - $script:TransportConfigLastRefreshUtc).TotalSeconds
        if (-not $Force -and $elapsed -lt $script:TransportConfigRefreshMinSeconds) { return }
    }
    # YURUNA_CONFIG_PATH wins over the in-tree template guess so an
    # operator running with `-ConfigPath <elsewhere>` sees their edits
    # to vmCommunication.* take effect mid-cycle (matches the contract
    # Sync-RuntimeConfig honours for testCycle.shouldStopOnFailure).
    $cfgPath = if ($env:YURUNA_CONFIG_PATH) { $env:YURUNA_CONFIG_PATH } `
               else { Join-Path (Split-Path -Parent $PSScriptRoot) 'test.config.yml' }
    $cfg = Read-TestConfig -Path $cfgPath
    if (-not $cfg) {
        Start-Sleep -Milliseconds 250
        $cfg = Read-TestConfig -Path $cfgPath -NoCache
    }
    if ($cfg) {
        $comm = $cfg.vmCommunication
        if ($comm.characterDelayMs) { $script:DefaultCharDelayMs = [int]$comm.characterDelayMs }
        if ($comm.vncPort)          { $script:DefaultVncPort     = [int]$comm.vncPort }
        if ($null -ne $comm.settleMs) { $script:DefaultSettleMs   = [int]$comm.settleMs }
    }
    $script:TransportConfigLastRefreshUtc = $now
}

# Initial load: drop -Force here because the throttle now genuinely
# detects the first load via $TransportConfigLastRefreshUtc == MinValue.
Update-TransportDefault
# ── Key code maps (owned by Test.KeyCodeRegistry) ────────────────────────────
# The Get-KeyCodeMap accessor returns a reference, so the $script:*
# aliases below stay zero-copy -- existing Send-Key / Send-Text callers
# read the same backing dictionaries they always have.

Import-Module (Join-Path $PSScriptRoot 'Test.KeyCodeRegistry.psm1') -Force -DisableNameChecking -Global

$script:UTMKeyMap       = Get-KeyCodeMap -Kind 'UTM-Named'
$script:MacCharKeyCodes = Get-KeyCodeMap -Kind 'UTM-Char'

# ── Cached Hyper-V keyboard (reused across steps) ───────────────────────────

$script:CachedKb = $null
$script:CachedKbVM = $null

function Get-HyperVKeyboard {
    <#
    .SYNOPSIS
        Resolve (and cache) the Msvm_Keyboard WMI instance for $VMName.
    .DESCRIPTION
        Send-KeyHyperV / Send-TextHyperV invoke TypeScancodes against
        this object many times per step. Lookups go through WMI so we
        cache the last resolved instance to avoid the per-call WMI hit;
        cache key is $VMName so switching VMs invalidates correctly.
    #>
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

$script:PS2ScanCodes  = Get-KeyCodeMap -Kind 'PS2-Named'
$script:CharScanCodes = Get-KeyCodeMap -Kind 'PS2-Char'

# ── VNC (RFB) keystroke transport ────────────────────────────────────────────
# Sends keystrokes directly to the VM's virtual display via the VNC/RFB
# protocol, bypassing the macOS GUI entirely — no window focus required.
# Used for QEMU-backend UTM VMs with a built-in VNC server enabled
# (via AdditionalArguments: -vnc localhost:0 in the plist). VMs without
# a VNC server fall back to the AppleScript/CGEvent path in Send-TextUTM.

$script:X11KeySyms     = Get-KeyCodeMap -Kind 'X11-Named'
$script:X11CharKeySyms = Get-KeyCodeMap -Kind 'X11-Char'

# ── Cached VNC connection (reused across steps within a sequence) ────────────

$script:CachedVnc   = $null
$script:CachedVncVM = $null

function Read-VncBuffer {
    <#
    .SYNOPSIS
        Blocking read of exactly $Count bytes from $Stream.
    .DESCRIPTION
        RFB framing is fixed-size per message; Stream.Read may return
        a short read so we loop until we have the full count or the
        connection drops (in which case we throw).
    #>
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
    <#
    .SYNOPSIS
        Open (or reuse a cached) RFB 3.8 connection to the VM's VNC server.
    .DESCRIPTION
        Resolves the per-VM VNC port (via Get-VncPortForVm so multiple
        VMs do not collide on 5900), runs the RFB handshake with
        security type 1 (None), and caches the TcpClient so subsequent
        Send-KeyVNC / Send-TextVNC calls within the sequence reuse the
        connection. Returns $null on handshake failure.
    #>
    param([string]$VMName, [int]$Port = 0)
    # Resolve the per-VM VNC port. Hardcoding 5900 across every VM let the
    # capture path silently grab whichever QEMU bound it first, so the
    # producer (config.plist.template) and consumers (this module +
    # Test.Screenshot.psm1) all derive the port from the VM name via
    # Get-VncPortForVm. $script:DefaultVncPort is kept as a last-resort
    # fallback for callers that don't pass a VMName.
    if ($Port -le 0) {
        if ($VMName) {
            # Get-VncPortForVm lives in host/macos.utm/Yuruna.Host.psm1.
            # Yuruna.Host imports VM.common, so callers that ran
            # Initialize-YurunaHost have it; otherwise import directly.
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
    <#
    .SYNOPSIS
        Close and discard the cached VNC connection (if any).
    .DESCRIPTION
        Called from Connect-VNC before opening a new handle and from
        Repair-VncConnection to force the next Send-Key/Send-Text VNC
        call to re-handshake. Errors are swallowed -- the cache is
        cleared either way.
    #>
    if ($script:CachedVnc) {
        try { $script:CachedVnc.Dispose() } catch { Write-Debug "      VNC disconnect error: $_" }
        $script:CachedVnc   = $null
        $script:CachedVncVM = $null
    }
}

function Send-VncKeyEvent {
    <#
    .SYNOPSIS
        Write a single RFB KeyEvent message (press or release).
    .DESCRIPTION
        Packs the 8-byte KeyEvent (type=4, down-flag, padding, big-
        endian X11 keysym) and writes it directly to $Client's stream.
        Caller manages press/release pairing and shift sequencing.
    #>
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
    <#
    .SYNOPSIS
        Press + release one named key over the VNC transport.
    .DESCRIPTION
        Resolves $KeyName via the X11KeySyms map, opens (or reuses)
        the VNC handle for $VMName, and writes the down/up KeyEvent
        pair. Returns $false on unknown key or transport failure.
    #>
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
    <#
    .SYNOPSIS
        Type $Text into $VMName one char at a time over VNC.
    .DESCRIPTION
        Looks each char up in X11CharKeySyms to find its keysym and
        shifted flag. Emits an explicit LShift press/release around
        shifted chars because UTM's QEMU VNC does NOT auto-shift from
        the bare keysym (asterisk arrives as 8 without the shift).
        Returns $false on transport failure.
    #>
    param([string]$VMName, [string]$Text, [int]$CharDelayMs = $script:DefaultCharDelayMs,
          [int]$Port = 0)
    $tcp = Connect-VNC -VMName $VMName -Port $Port
    if (-not $tcp) { return $false }
    Write-Debug "      VNC text send: $($Text.Length) chars, charDelay=${CharDelayMs}ms"
    try {
        # Empirically, UTM's QEMU VNC does NOT auto-shift from the keysym
        # alone (e.g. `asterisk` arrives as `8`, `bar` arrives as `\`), so we
        # must press LShift ourselves. 20ms down / 10ms up has tested clean
        # for the supported guests and is matched against Send-TextHyperV's
        # batched-scancode shift settle. If a future guest regresses, the
        # cycle log's "VNC text send: failed" warning is the trigger -- a
        # larger window (e.g. 80/40) is the conservative escape hatch.
        $shiftSym = $script:X11KeySyms["LShift"]
        $shiftDownMs = 20
        $shiftUpMs   = 10
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
                Start-Sleep -Milliseconds $shiftDownMs
            }
            Send-VncKeyEvent -Client $tcp -KeySym $keySym -Down $true
            Send-VncKeyEvent -Client $tcp -KeySym $keySym -Down $false
            if ($shifted) {
                Start-Sleep -Milliseconds $shiftUpMs
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
    <#
    .SYNOPSIS
        Press + release one named key via macOS Accessibility (AXUI).
    .DESCRIPTION
        Reference implementation only; NOT wired into the dispatcher.
        UTM's SwiftUI VM display does not route AXUI keyboard events
        to the virtual machine, so keys silently vanish. Retained in
        case a future UTM version fixes the routing.
    #>
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
    <#
    .SYNOPSIS
        Type $Text via macOS Accessibility (AXUI) batched in one JXA call.
    .DESCRIPTION
        Reference implementation only; NOT wired into the dispatcher
        for the same reason as Send-KeyAXUI -- UTM's SwiftUI display
        does not route AXUI keyboard events to the guest. Retained for
        symmetry with the active Send-TextUTM path.
    #>
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
    <#
    .SYNOPSIS
        Invoke the Hyper-V Msvm_Keyboard TypeScancodes WMI method.
    .DESCRIPTION
        Thin wrapper around Invoke-CimMethod so the Send-Key/Text/Click
        Hyper-V paths share one call shape. Returns $true on
        ReturnValue=0 (success); WMI errors surface to the caller.
    #>
    param($Keyboard, [byte[]]$Codes)
    $r = Invoke-CimMethod -InputObject $Keyboard -MethodName "TypeScancodes" -Arguments @{Scancodes=$Codes}
    return ($r.ReturnValue -eq 0)
}

# ── Action: key ──────────────────────────────────────────────────────────────

function Send-KeyHyperV {
    <#
    .SYNOPSIS
        Send one PS/2 make + break for $KeyName to a Hyper-V VM.
    .DESCRIPTION
        Resolves $KeyName via PS2ScanCodes, then writes the make code
        followed by `code | 0x80` (break) through Send-ScanCode. No
        modifier-reset prefix -- see Send-TextHyperV for that.
    #>
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
    <#
    .SYNOPSIS
        Press one named key in a UTM VM via AppleScript `key code`.
    .DESCRIPTION
        Uses `key code` for every key (including Enter, code 36).
        Earlier code used `keystroke return` for Enter which sometimes
        fired twice when chained after Send-Text left the System
        Events keystroke buffer warm -- submitting an empty password
        and bouncing the guest back to the login prompt.
    #>
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
# KVM key maps now live in Test.KeyCodeRegistry (KVM-Char / KVM-Named).
$script:KvmCharKeyMap = Get-KeyCodeMap -Kind 'KVM-Char'

function Send-KeyKvm {
    <#
    .SYNOPSIS
        Press one named key in a libvirt KVM VM via `virsh send-key`.
    .DESCRIPTION
        Maps common harness key names (Enter, Tab, Escape, arrows, etc.)
        to Linux KEY_* event names; unmapped names pass through
        verbatim so a sequence can write KEY_LEFTMETA / KEY_F2
        directly. Bypasses VNC because libvirt-managed QEMU drops the
        RFB handshake mid-stream.
    #>
    param([string]$VMName, [string]$KeyName)
    # Named-key map lives in Test.KeyCodeRegistry (KVM-Named) alongside the char
    # map. Anything not in the table passes through verbatim so a sequence can
    # write KEY_LEFTMETA, KEY_F2, etc. directly.
    $code = (Get-KeyCodeMap -Kind 'KVM-Named')[$KeyName]
    if (-not $code) { $code = $KeyName }
    & virsh --connect qemu:///system send-key $VMName $code 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Send-KeyKvm: virsh send-key '$code' failed for '$VMName'"
        return $false
    }
    return $true
}

function Send-TextKvm {
    <#
    .SYNOPSIS
        Type $Text into a KVM VM one chord at a time via `virsh send-key`.
    .DESCRIPTION
        Looks each char up in KvmCharKeyMap to find its KEY_* chord
        (shifted chars become a 2-key chord: KEY_LEFTSHIFT + KEY_X) and
        fires one `virsh send-key` per char. Pauses $CharDelayMs
        between chars so the guest's input layer has time to drain.
    #>
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


function Send-TextHyperV {
    <#
    .SYNOPSIS
        Type $Text into a Hyper-V VM via batched PS/2 TypeScancodes.
    .DESCRIPTION
        Emits a defensive modifier-release prefix (break codes for
        LShift/RShift/LCtrl/RCtrl/LAlt/RAlt/LMeta/RMeta) before each
        text burst so stale modifier state from prior input does not
        upshift the payload (yauser1 -> YAUSER!). Batches every char's
        make/break pair into one TypeScancodes invocation and caps the
        post-batch settle at DefaultSettleMs.
    #>
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
        # Batch all chars' scancodes into ONE Send-ScanCode CIM call.
        # The per-char alternative (one CIM call per char plus a
        # Start-Sleep $CharDelayMs after each) costs ~N * (CIM ~5-15 ms
        # + 20 ms default delay) -- a 16-char password takes 400-560 ms
        # wall-clock just for the typing. Hyper-V's TypeScancodes queues
        # the entire byte payload internally and feeds the guest's PS/2
        # buffer at its own (fast) pace, so batching cuts cost to ~one
        # CIM call.
        #
        # For shifted characters: LShift-make, char-make, char-break,
        # LShift-break -- the standard per-char sequence, concatenated
        # into the batch. CharDelayMs is interpreted as a wall-clock
        # SETTLE budget AFTER the batch: an explicit non-zero value
        # asks the guest to drain before the next action; default
        # behavior is "minimal pacing, fast through". Operators who
        # need true per-char pacing (e.g. a guest agetty that drops
        # bursts) can set vmCommunication.batchedTextSend=false in
        # test.config.yml -- not wired today; opt-in is a future
        # extension.
        $codeList = [System.Collections.Generic.List[byte]]::new()
        $charCount = 0
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
            $charCount++
        }
        if ($codeList.Count -gt 0) {
            $ok = Send-ScanCode -Keyboard $kb -Codes ([byte[]]$codeList.ToArray())
            if (-not $ok) {
                Write-Warning "Hyper-V TypeScancodes batch send failed ($charCount chars)"
                return $false
            }
        }
        # Post-batch settle: linear in char count up to a ceiling. The
        # PS/2 controller drains asynchronously, so without a wait the
        # next action (Enter, screenshot) can sample a half-typed field.
        # Formula: min($DefaultSettleMs, $CharDelayMs * $charCount).
        # $DefaultSettleMs (200 ms default) is the empirical ceiling that
        # covered every login-prompt drain measured on this hardware;
        # tune via test.config.yml's vmCommunication.settleMs for guests
        # that need more (slow agetty) or less (KVM/SeaBIOS, where the
        # buffer is faster).
        if ($CharDelayMs -gt 0 -and $charCount -gt 0) {
            $settleMs = [Math]::Min($script:DefaultSettleMs, $CharDelayMs * $charCount)
            Start-Sleep -Milliseconds $settleMs
        }
        Write-Debug "      TypeScancodes: $charCount chars sent in 1 batch (${CharDelayMs}ms per-char budget; post-batch settle capped at ${script:DefaultSettleMs}ms)"
        return $true
    } catch {
        Write-Warning "Hyper-V TypeScancodes (text) failed: $_"
        return $false
    }
}

function Test-HardCharsInText {
    <#
    .SYNOPSIS
        Returns $true if $Text contains at least one char that needs
        Shift in MacCharKeyCodes after the keypad remap.
    .DESCRIPTION
        Used by Send-TextUTM to decide whether the ShellEscape encoding
        is needed before handing the payload to JXA CGEvent typing.
    #>
    param([string]$Text)
    foreach ($ch in $Text.ToCharArray()) {
        $e = $script:MacCharKeyCodes["$ch"]
        if ($e -and $e[1]) { return $true }
    }
    return $false
}

function ConvertTo-ShellEscapedText {
    <#
    .SYNOPSIS
        Rewrite $Text as a bash one-liner the guest's shell will
        decode back to the original string.
    .DESCRIPTION
        Emits `eval ``echo -e 'TEXT_HEX'``` where every shifted char
        becomes its \xNN escape so the host typing path never has to
        send shifted scancodes. Structural chars (' -> \x27, ` -> \x60,
        \\ doubled) are hex-escaped so the surrounding apostrophe /
        backtick quoting survives intact.
    #>
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
    <#
    .SYNOPSIS
        Type $Text into a UTM VM via batched JXA CGEvent typing.
    .DESCRIPTION
        Raises the matching UTM window, then dispatches each char as a
        physical Left Shift + key make/break (or plain make/break for
        unshifted chars) using the HID-system event source. -ShellEscape
        rewrites the payload via ConvertTo-ShellEscapedText when there
        is a guest shell to decode the wrapper -- never pass it at
        login/password prompts.
    #>
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

function Initialize-HyperVMouseType {
    <#
    .SYNOPSIS
        Lazy Add-Type loader for the HyperVMouse C# helper.
    .DESCRIPTION
        Defines the EnumWindows/SetCursorPos/mouse_event P/Invoke
        wrappers used by Send-ClickHyperV. Guarded so multiple module
        re-imports don't trip "type already defined".
    #>
    if ('HyperVMouse' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class HyperVMouse {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT pt);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT pt);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, IntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }

    const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    const uint MOUSEEVENTF_LEFTUP   = 0x0004;

    static bool dpiAware = false;
    public static void EnsureDpiAware() {
        if (!dpiAware) { SetProcessDPIAware(); dpiAware = true; }
    }

    // Click-by-OCR feeds the captured image's pixel coordinates straight back
    // as client coordinates -- the capture is taken so image (x,y) == vmconnect
    // client (x,y). HyperVCapture grabs that frame under Per-Monitor-V2, so the
    // image is in the window's true physical pixels; the click must map those
    // same physical client coords, hence ClientToScreen/SetCursorPos run under
    // a matching Per-Monitor-V2 context. A system-DPI-aware mapping on a
    // >100%-scaled monitor would land the click off-target by the scale factor.
    // Thread-scoped + reversible; IntPtr.Zero means the API is absent and the
    // EnsureDpiAware process awareness stays in force.
    static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = new IntPtr(-4);
    static IntPtr EnterPerMonitorV2() {
        try { return SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2); }
        catch { return IntPtr.Zero; }
    }
    static void RestoreThreadDpiContext(IntPtr prev) {
        if (prev == IntPtr.Zero) return;
        try { SetThreadDpiAwarenessContext(prev); } catch { }
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
        IntPtr prevDpiCtx = EnterPerMonitorV2();
        try {
            POINT pt = new POINT(); pt.X = clientX; pt.Y = clientY;
            if (!ClientToScreen(hWnd, ref pt)) return null;
            return new int[] { pt.X, pt.Y };
        } finally {
            RestoreThreadDpiContext(prevDpiCtx);
        }
    }

    // Left-click at a client-area pixel (clientX, clientY) inside hWnd.
    // Restores the host cursor afterwards so the operator's mouse isn't
    // "stolen" mid-test. Returns false if the window cannot be targeted.
    public static bool ClickClientPoint(IntPtr hWnd, int clientX, int clientY) {
        EnsureDpiAware();
        IntPtr prevDpiCtx = EnterPerMonitorV2();
        try {
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
        } finally {
            RestoreThreadDpiContext(prevDpiCtx);
        }
    }
}
"@
}

function Send-ClickHyperV {
    <#
    .SYNOPSIS
        Left-click at (X, Y) inside the vmconnect window for $VMName.
    .DESCRIPTION
        Requires an open vmconnect session -- the host driver does not
        spawn one. Restores the host cursor afterwards so the operator's
        mouse is not "stolen" mid-test. Returns $false when the
        vmconnect window cannot be located.
    #>
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

# Send-KeyAXUI / Send-TextAXUI are intentionally NOT exported: AXUI keyboard
# events do not route to UTM's SwiftUI guest display, so they are dead as a
# transport. Kept as private functions (their docstrings record the finding)
# rather than deleted, so the knowledge survives without shipping a dead
# public entry point.
Export-ModuleMember -Function Get-HyperVKeyboard, Read-VncBuffer, Connect-VNC, Disconnect-VNC, `
    Send-VncKeyEvent, Send-KeyVNC, Send-TextVNC, `
    Send-ScanCode, Send-KeyHyperV, Send-KeyUTM, Send-KeyKvm, `
    Send-TextKvm, Send-TextHyperV, Test-HardCharsInText, ConvertTo-ShellEscapedText, `
    Send-TextUTM, Initialize-HyperVMouseType, Send-ClickHyperV, Send-ClickUtm, `
    Update-TransportDefault