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
    Drives the Windows 11 guest through installation to a usable state.

.DESCRIPTION
    Windows 11 boots from an ISO with autounattend.xml on a seed ISO.
    The unattended config handles partitioning, image selection, OOBE
    bypass, user creation, and auto-logon.

    However, the "Press any key to boot from CD or DVD..." prompt
    requires an initial keystroke. On Hyper-V, New-VM.ps1 already
    sends this keystroke via WMI during creation. On UTM (macOS),
    this script sends it via AppleScript.

    == TRAINING GUIDE ==

    To update the keystroke sequence for a new Windows ISO or scenario:

    1. Start the VM manually and observe the full boot/install sequence.

    2. Note each point where interaction is needed:
       - Seconds after VM start when the prompt appears
       - Which key to press (Enter, Tab, arrow keys, etc.)
       - Any mouse clicks needed (rarely — autounattend handles most)

    3. Update the $Steps array below. Each step is a hashtable:
         @{
             DelaySeconds = <seconds to wait before sending>
             Key          = "<key name>"
             Description  = "<what this step does>"
         }

       Supported keys for Hyper-V (Msvm_Keyboard scan codes):
         Enter=0x1C  Tab=0x0F  Space=0x39  Esc=0x01
         Up=0x48  Down=0x50  Left=0x4B  Right=0x4D
         F1-F12: 0x3B-0x46
         Full reference: https://learn.microsoft.com/en-us/windows/win32/inputdev/about-keyboard-input

       Supported keys for UTM (AppleScript key codes):
         Return=36  Tab=48  Space=49  Escape=53
         UpArrow=126  DownArrow=125  LeftArrow=123  RightArrow=124
         Full reference: https://eastmanreference.com/complete-list-of-applescript-key-codes

    4. For advanced scenarios requiring mouse clicks or typed text,
       consider using Appium (run Get-Appium.ps1 first):
       - Windows: WinAppDriver targets the vmconnect window
       - macOS: Mac2Driver targets the UTM window
       See: https://appium.io/docs/en/latest/

    5. Test your changes:
         pwsh test/Invoke-TestRunner.ps1 -NoGitPull

    6. Capture a verification screenshot of the expected post-install
       desktop and place it at:
         test/verify/guest.windows.11/expected.png

.NOTES
    Exit 0 = OS installation started successfully, non-zero = failed.
#>

param(
    [string]$HostType,
    [string]$GuestKey,
    [string]$VMName
)

# === Keystroke sequence ===
# Each step: DelaySeconds (wait before sending), Key, Description.
#
# The "Press any key to boot from CD or DVD..." prompt appears shortly after
# the VM starts. On Hyper-V, the test runner opens vmconnect (basic mode)
# and this script sends Enter via WMI. On UTM, it sends Enter via AppleScript.
# The "Press any key" prompt has a ~5-second window. We send Enter twice
# to cover timing variations (UEFI firmware delay, vmconnect startup).
$Steps = @(
    @{ DelaySeconds = 3;  Key = "Enter"; Description = "Boot from CD/DVD (first attempt)" }
    @{ DelaySeconds = 5;  Key = "Enter"; Description = "Boot from CD/DVD (retry)" }
)

# === Keystroke delivery functions ===

function Send-KeystrokeHyperV {
    param([string]$VMName, [string]$Key)
    $keyMap = @{
        "Enter"=0x1C; "Tab"=0x0F; "Space"=0x39; "Escape"=0x01
        "Up"=0x48; "Down"=0x50; "Left"=0x4B; "Right"=0x4D
        "F1"=0x3B; "F2"=0x3C; "F5"=0x3F; "F8"=0x42; "F12"=0x46
    }
    $code = $keyMap[$Key]
    if (-not $code) { Write-Warning "Unknown key '$Key' for Hyper-V (scan code not mapped)"; return $false }
    try {
        Write-Output "    [keystroke] Looking up VM '$VMName' via WMI..."
        $vmObj = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
        if (-not $vmObj) { Write-Warning "VM '$VMName' not found in WMI"; return $false }
        Write-Output "    [keystroke] VM found (state: $($vmObj.EnabledState)). Getting keyboard device..."
        $kb = Get-CimAssociatedInstance -InputObject $vmObj -ResultClassName Msvm_Keyboard
        if (-not $kb) { Write-Warning "Keyboard device not found for '$VMName'"; return $false }
        Write-Output "    [keystroke] Sending key '$Key' (scan code 0x$($code.ToString('X2'))): PressKey..."
        $pressResult = Invoke-CimMethod -InputObject $kb -MethodName "PressKey" -Arguments @{keyCode=$code}
        Write-Output "    [keystroke] PressKey returned: $($pressResult.ReturnValue)"
        Start-Sleep -Milliseconds 100
        Write-Output "    [keystroke] ReleaseKey..."
        $releaseResult = Invoke-CimMethod -InputObject $kb -MethodName "ReleaseKey" -Arguments @{keyCode=$code}
        Write-Output "    [keystroke] ReleaseKey returned: $($releaseResult.ReturnValue)"
        return ($pressResult.ReturnValue -eq 0 -and $releaseResult.ReturnValue -eq 0)
    } catch {
        Write-Warning "Failed to send keystroke via Hyper-V WMI: $_"
        return $false
    }
}

function Send-KeystrokeUTM {
    param([string]$VMName, [string]$Key)
    $keyMap = @{
        "Enter"=36; "Tab"=48; "Space"=49; "Escape"=53
        "Up"=126; "Down"=125; "Left"=123; "Right"=124
        "F1"=122; "F2"=120; "F5"=96; "F8"=100; "F12"=111
    }
    $code = $keyMap[$Key]
    if (-not $code) { Write-Warning "Unknown key '$Key' for UTM"; return $false }
    $script = @"
tell application "System Events"
    tell process "UTM"
        set frontmost to true
        repeat with w in windows
            if name of w contains "$VMName" then
                perform action "AXRaise" of w
                delay 0.3
                key code $code
                return "ok"
            end if
        end repeat
    end tell
end tell
return "window_not_found"
"@
    $result = & osascript -e $script 2>&1
    if ("$result" -eq "ok") { return $true }
    Write-Warning "UTM keystroke failed: $result"
    return $false
}

# === Execute steps ===
Write-Output "[$GuestKey] Windows 11 unattended install — sending initial keystrokes"

foreach ($step in $Steps) {
    Write-Output "  Waiting $($step.DelaySeconds)s — $($step.Description)..."
    Start-Sleep -Seconds $step.DelaySeconds

    $sent = switch ($HostType) {
        "host.windows.hyper-v" { Send-KeystrokeHyperV -VMName $VMName -Key $step.Key }
        "host.macos.utm"       { Send-KeystrokeUTM    -VMName $VMName -Key $step.Key }
        default { Write-Warning "Unknown host type: $HostType"; $false }
    }
    if ($sent) {
        Write-Output "  Sent '$($step.Key)' to $VMName"
    } else {
        Write-Warning "  Could not send '$($step.Key)' — install may require manual intervention"
    }
}

Write-Output "[$GuestKey] Keystroke sequence complete. Autounattend.xml is driving the installation."
exit 0
