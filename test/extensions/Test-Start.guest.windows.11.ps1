<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456762
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

<#
.SYNOPSIS
    Drives the Windows 11 guest through initial boot to start unattended installation.

.DESCRIPTION
    Sends keystrokes to the VM to bypass the "Press any key to boot from CD or DVD..."
    prompt so that autounattend.xml can drive the installation unattended.

    == HOW TO CUSTOMIZE ==

    Edit the $Steps array below. Each entry is a hashtable with:
      DelaySeconds  — seconds to wait before sending the key
      Key           — key name (see supported list below)
      Description   — human-readable label shown in the runner output

    Supported key names: Enter, Tab, Space, Escape, Up, Down, Left, Right, F1-F12

    == CONTROL POINT DETECTION (advanced) ==

    Instead of fixed timing, you can detect VM state before sending keys:
    - Screenshot comparison: use Compare-Screenshot from Test.Screenshot module
    - Hyper-V heartbeat: (Get-VMIntegrationService -VMName $VMName -Name Heartbeat).PrimaryStatusDescription
    - Network: Test-NetConnection -ComputerName $VMName -Port 3389

.NOTES
    Exit 0 = success, non-zero = failure (stops the runner).
#>

# ─────────────────────────────────────────────────────────────────────────────
# PARAMETERS — passed by the test runner, do not change
# ─────────────────────────────────────────────────────────────────────────────
param(
    [string]$HostType,   # "host.windows.hyper-v" or "host.macos.utm"
    [string]$GuestKey,   # "guest.windows.11"
    [string]$VMName      # e.g. "test-windows11-01"
)

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — edit these to match your VM boot sequence
# ─────────────────────────────────────────────────────────────────────────────

# Keystroke sequence. The "Press any key" prompt appears ~3-5s after boot.
# We send Enter twice to cover timing variations (UEFI firmware, vmconnect).
$Steps = @(
    @{ DelaySeconds = 3;  Key = "Enter"; Description = "Boot from CD/DVD (first attempt)" }
    @{ DelaySeconds = 5;  Key = "Enter"; Description = "Boot from CD/DVD (retry)" }
)

# ─────────────────────────────────────────────────────────────────────────────
# KEYSTROKE FUNCTIONS — one per host platform
# ─────────────────────────────────────────────────────────────────────────────

# Hyper-V: sends keystrokes via WMI Msvm_Keyboard using virtual-key codes.
# Reference: https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
function Send-KeystrokeHyperV {
    param([string]$VMName, [string]$Key)
    $keyMap = @{
        "Enter"=0x0D; "Tab"=0x09; "Space"=0x20; "Escape"=0x1B
        "Up"=0x26; "Down"=0x28; "Left"=0x25; "Right"=0x27
        "F1"=0x70; "F2"=0x71; "F3"=0x72; "F4"=0x73; "F5"=0x74
        "F6"=0x75; "F7"=0x76; "F8"=0x77; "F9"=0x78; "F10"=0x79
        "F11"=0x7A; "F12"=0x7B
    }
    $code = $keyMap[$Key]
    if (-not $code) { Write-Warning "Unknown key '$Key' for Hyper-V"; return $false }
    try {
        $vmObj = Get-CimInstance -Namespace root\virtualization\v2 `
            -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
        if (-not $vmObj) { Write-Warning "VM '$VMName' not found in WMI"; return $false }
        $kb = Get-CimAssociatedInstance -InputObject $vmObj -ResultClassName Msvm_Keyboard
        if (-not $kb) { Write-Warning "Keyboard device not found for '$VMName'"; return $false }
        $press = Invoke-CimMethod -InputObject $kb -MethodName "PressKey" -Arguments @{keyCode=$code}
        Start-Sleep -Milliseconds 100
        $release = Invoke-CimMethod -InputObject $kb -MethodName "ReleaseKey" -Arguments @{keyCode=$code}
        $script:lastKeystrokeLog = "PressKey=$($press.ReturnValue) ReleaseKey=$($release.ReturnValue) (0=success)"
        return ($press.ReturnValue -eq 0 -and $release.ReturnValue -eq 0)
    } catch {
        Write-Warning "Hyper-V WMI keystroke failed: $_"
        return $false
    }
}

# UTM (macOS): sends keystrokes via AppleScript to the UTM VM window.
# Requires Accessibility permissions for Terminal.
function Send-KeystrokeUTM {
    param([string]$VMName, [string]$Key)
    $keyMap = @{
        "Enter"=36; "Tab"=48; "Space"=49; "Escape"=53
        "Up"=126; "Down"=125; "Left"=123; "Right"=124
        "F1"=122; "F2"=120; "F3"=99; "F4"=118; "F5"=96
        "F6"=97; "F7"=98; "F8"=100; "F9"=101; "F10"=109
        "F11"=103; "F12"=111
    }
    $code = $keyMap[$Key]
    if (-not $code) { Write-Warning "Unknown key '$Key' for UTM"; return $false }
    if ($Key -eq "Enter") { $keyAction = 'keystroke return' }
    else                  { $keyAction = "key code $code" }
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
    $script:lastKeystrokeLog = "AppleScript result: $result"
    if ("$result" -eq "ok") { return $true }
    Write-Warning "UTM keystroke failed: $result"
    return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# EXECUTION — runs each step and reports progress
# ─────────────────────────────────────────────────────────────────────────────
Write-Output "[$GuestKey] Windows 11 unattended install on $HostType (VM: $VMName)"

foreach ($step in $Steps) {
    Write-Output "    Step: $($step.Description)"
    Write-Output "    Waiting $($step.DelaySeconds) seconds..."
    Start-Sleep -Seconds $step.DelaySeconds
    Write-Output "    Sending '$($step.Key)' to VM '$VMName' via $HostType..."

    $script:lastKeystrokeLog = $null
    $sent = $false
    if ($HostType -eq "host.windows.hyper-v") {
        $sent = Send-KeystrokeHyperV -VMName $VMName -Key $step.Key
    } elseif ($HostType -eq "host.macos.utm") {
        $sent = Send-KeystrokeUTM -VMName $VMName -Key $step.Key
    } else {
        Write-Warning "Unknown host type: $HostType"
    }

    if ($script:lastKeystrokeLog) {
        Write-Output "      $($script:lastKeystrokeLog)"
    }
    if ($sent -eq $true) {
        Write-Output "    '$($step.Key)' sent successfully."
    } else {
        Write-Warning "    Could not send '$($step.Key)' — install may require manual intervention."
    }
    Write-Output ""
}

Write-Output "[$GuestKey] Keystroke sequence complete. Autounattend.xml is driving the installation."
exit 0
