<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456761
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
    Drives the Ubuntu Desktop guest through installation to a usable state.

.DESCRIPTION
    Ubuntu Desktop boots from an ISO with autoinstall (cloud-init user-data
    on a cidata seed ISO). The autoinstall handles partitioning, user
    creation, locale, and packages unattended.

    Some Ubuntu ISOs show a "Try or Install Ubuntu" GRUB menu before
    autoinstall takes over. This script sends an Enter keystroke to
    dismiss that menu if it appears.

    == TRAINING GUIDE ==

    To update the keystroke sequence for a new Ubuntu ISO version:

    1. Start the VM manually:
         pwsh vde/host.windows.hyper-v/guest.ubuntu.desktop/New-VM.ps1
       or on macOS:
         pwsh vde/host.macos.utm/guest.ubuntu.desktop/New-VM.ps1

    2. Watch the boot sequence and note:
       - How many seconds after start the GRUB menu appears
       - Whether a keystroke is needed to proceed (Enter, arrow keys, etc.)
       - How many seconds until the installer finishes

    3. Update the $Steps array below with your observations:
         @{ DelaySeconds = <wait>; Key = "<key>"; Description = "<what it does>" }

       Supported keys for Hyper-V (Msvm_Keyboard keyCode):
         Enter=0x1C  Tab=0x0F  Space=0x39  Esc=0x01  Up=0x48  Down=0x50
         F1-F12: 0x3B-0x46  a-z: see https://learn.microsoft.com/en-us/windows/win32/inputdev/about-keyboard-input

       Supported keys for UTM (AppleScript key code):
         Return=36  Tab=48  Space=49  Escape=53  UpArrow=126  DownArrow=125
         See: https://eastmanreference.com/complete-list-of-applescript-key-codes

    4. Test by running the full cycle:
         pwsh test/Invoke-TestRunner.ps1 -NoGitPull

    5. Capture a verification screenshot when the install is done:
       Place it at: test/verify/guest.ubuntu.desktop/expected.png

.NOTES
    Exit 0 = OS installation started successfully, non-zero = failed.
#>

param(
    [string]$HostType,
    [string]$GuestKey,
    [string]$VMName
)

$InformationPreference = 'Continue'

# === Keystroke sequence ===
# Each step: DelaySeconds (seconds to wait before sending), Key, Description.
# The autoinstall config handles the full installation unattended.
# This sequence dismisses the initial GRUB menu ("Try or Install Ubuntu").
# GRUB typically appears 5-15 seconds after VM start on Hyper-V Gen 2 VMs.
# We send Enter twice with a gap to cover timing variations: if the first
# arrives before GRUB renders it's harmless, the second catches it.
$Steps = @(
    @{ DelaySeconds = 8;  Key = "Enter"; Description = "Dismiss GRUB menu (first attempt)" }
    @{ DelaySeconds = 10; Key = "Enter"; Description = "Dismiss GRUB menu (retry if first was too early)" }
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
        Write-Information "    [keystroke] Looking up VM '$VMName' via WMI..."
        $vmObj = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
        if (-not $vmObj) { Write-Warning "VM '$VMName' not found in WMI"; return $false }
        Write-Information "    [keystroke] VM found (state: $($vmObj.EnabledState)). Getting keyboard device..."
        $kb = Get-CimAssociatedInstance -InputObject $vmObj -ResultClassName Msvm_Keyboard
        if (-not $kb) { Write-Warning "Keyboard device not found for '$VMName'"; return $false }
        Write-Information "    [keystroke] Sending key '$Key' (scan code 0x$($code.ToString('X2'))): PressKey..."
        $pressResult = Invoke-CimMethod -InputObject $kb -MethodName "PressKey" -Arguments @{keyCode=$code}
        Write-Information "    [keystroke] PressKey returned: $($pressResult.ReturnValue)"
        Start-Sleep -Milliseconds 100
        Write-Information "    [keystroke] ReleaseKey..."
        $releaseResult = Invoke-CimMethod -InputObject $kb -MethodName "ReleaseKey" -Arguments @{keyCode=$code}
        Write-Information "    [keystroke] ReleaseKey returned: $($releaseResult.ReturnValue)"
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
    Write-Information "    [keystroke] Sending key '$Key' (AppleScript key code $code) to UTM window '$VMName'..."
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
    Write-Information "    [keystroke] AppleScript result: $result"
    if ("$result" -eq "ok") { return $true }
    Write-Warning "UTM keystroke failed: $result"
    return $false
}

# === Execute steps ===
Write-Output "[$GuestKey] Ubuntu Desktop autoinstall — sending initial keystrokes"

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

Write-Output "[$GuestKey] Keystroke sequence complete. Autoinstall is running unattended."
exit 0
