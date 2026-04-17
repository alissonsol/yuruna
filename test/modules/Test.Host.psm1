<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456701
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

function Get-HostType {
    <#
    .SYNOPSIS
    Returns "host.macos.utm" or "host.windows.hyper-v" based on the current platform.
    #>
    if ($IsMacOS) {
        if (-not (Test-Path "/Applications/UTM.app")) {
            Write-Warning "Running on macOS but UTM not found at /Applications/UTM.app."
        }
        return "host.macos.utm"
    }
    if ($IsWindows) {
        $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Warning "Running on Windows but Hyper-V service (vmms) not found."
        }
        return "host.windows.hyper-v"
    }
    Write-Error "Unsupported platform. Only macOS (UTM) and Windows (Hyper-V) are supported."
    return $null
}

function Get-GuestList {
    <#
    .SYNOPSIS
    Returns the ordered list of guest keys to test, as declared in $Config.guestOrder.
    .DESCRIPTION
    Returns the list verbatim — whether any of those guests is actually implemented
    for the current host is decided at runtime by Test-GuestFolder (the runner then
    logs a per-guest failure for any missing folder). This replaces the old hardcoded
    allow-list that had to be updated every time a new guest.<name> was added.
    If guestOrder is missing or empty, returns an empty list and emits a warning.
    #>
    param([System.Collections.IDictionary]$Config = @{})

    if ($Config.guestOrder -and $Config.guestOrder.Count -gt 0) {
        return @($Config.guestOrder)
    }

    Write-Warning "test-config.json has no 'guestOrder' entries — nothing to run."
    return @()
}

function Test-GuestFolder {
    <#
    .SYNOPSIS
    Returns $true when the guest-specific scripts folder exists for a given host.
    .DESCRIPTION
    Layout convention: <repo>/vde/<hostType>/<guestKey>/ contains Get-Image.ps1 and
    New-VM.ps1 for that host+guest combination. A guest is considered available on a
    host iff that folder exists. Some guests are host-specific by design (e.g. a
    hypothetical macOS-only guest), so a single guestOrder can legitimately name
    guests that exist on only one host; callers treat a missing folder as a failure
    for that guest on the current host, not a config error.
    #>
    param(
        [Parameter(Mandatory)] [string]$VdeRoot,
        [Parameter(Mandatory)] [string]$HostType,
        [Parameter(Mandatory)] [string]$GuestKey
    )
    $folder = Join-Path $VdeRoot "$HostType/$GuestKey"
    return (Test-Path -Path $folder -PathType Container)
}

function Get-TestVMName {
    <#
    .SYNOPSIS
    Derives the test VM name for a given guest key + prefix.
    .DESCRIPTION
    Pure algorithmic derivation: strip the "guest." prefix, replace remaining dots
    with hyphens, append "-01" as the instance suffix, and add the configured prefix.
    Examples with prefix "test-":
        guest.ubuntu.server  →  test-ubuntu-server-01
        guest.amazon.linux   →  test-amazon-linux-01
        guest.windows.11     →  test-windows-11-01
    No hardcoded allow-list — any guest key the harness is asked to run produces a
    deterministic VM name without requiring code changes.
    Note on migration: this convention differs from the pre-2026-04 harness which
    used "test-amazon-linux01", "test-ubuntu-desktop01", "test-windows11-01".
    Test VMs from the old convention are orphaned (Remove-TestVM keys off the new
    name); clean them up manually once with `Get-VM test-* | Remove-VM` on Hyper-V
    or `utmctl list | grep test-` on UTM.
    #>
    param(
        [Parameter(Mandatory)] [string]$GuestKey,
        [string]$Prefix = "test-"
    )
    $stem = ($GuestKey -replace '^guest\.', '') -replace '\.', '-'
    return "${Prefix}${stem}-01"
}

function Test-ElevationRequired {
    <#
    .SYNOPSIS
    Returns $true if the host type requires Administrator elevation.
    #>
    param([string]$HostType)
    return ($HostType -eq "host.windows.hyper-v")
}

function Assert-Elevation {
    <#
    .SYNOPSIS
    Checks elevation if required. Returns $false and writes an error if elevation is needed but absent.
    #>
    param([string]$HostType)
    if (-not (Test-ElevationRequired -HostType $HostType)) { return $true }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
    if (-not $isAdmin) {
        Write-Error "host.windows.hyper-v requires elevation. Re-run Invoke-TestRunner.ps1 as Administrator."
        return $false
    }
    return $true
}

function Assert-ScreenLock {
    <#
    .SYNOPSIS
    On macOS, checks that screen saver lock and display sleep are configured so
    they won't blank the screen during long-running VM tests.  Returns $true if
    settings are acceptable or not on macOS.  Prints instructions and returns
    $false if the screen will lock/blank.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    $issues = @()

    # 1. Display sleep idle time (pmset -g custom → displaysleep value)
    #    0 = never sleep (good).  Anything > 0 means the display will blank.
    try {
        $pmsetLine = & pmset -g custom 2>$null | Select-String '^\s*displaysleep\s+(\d+)' | Select-Object -First 1
        if ($pmsetLine -and $pmsetLine.Matches[0].Groups[1].Value -ne "0") {
            $sleepMin = $pmsetLine.Matches[0].Groups[1].Value
            $issues += "Display sleep is set to $sleepMin minute(s)."
        }
    } catch {
        Write-Debug "pmset check failed: $_"
    }

    # 2. Screen saver idle time (defaults read com.apple.screensaver idleTime)
    #    0 = disabled (good).  Missing key also means disabled.
    try {
        $idleTime = & defaults read com.apple.screensaver idleTime 2>$null
        if ($LASTEXITCODE -eq 0 -and "$idleTime".Trim() -ne "0") {
            $issues += "Screen saver activates after $($idleTime.Trim()) second(s)."
        }
    } catch {
        Write-Debug "Screen saver check failed: $_"
    }

    # 3. Screen lock on sleep / screen saver (macOS Ventura+: sysadminctl)
    #    Fallback: defaults read com.apple.screensaver askForPassword
    try {
        $askPw = & defaults read com.apple.screensaver askForPassword 2>$null
        if ($LASTEXITCODE -eq 0 -and "$askPw".Trim() -eq "1") {
            $issues += "Screen lock (password after screen saver) is enabled."
        }
    } catch {
        Write-Debug "Screen lock password check failed: $_"
    }

    if ($issues.Count -eq 0) { return $true }

    Write-Warning "═══════════════════════════════════════════════════════════════════"
    Write-Warning " Screen lock / display sleep settings will blank the VM display."
    Write-Warning ""
    foreach ($issue in $issues) {
        Write-Warning "  • $issue"
    }
    Write-Warning ""
    Write-Warning " When the display blanks, UTM screen captures return a black"
    Write-Warning " image and OCR-based waitForText steps will time out."
    Write-Warning ""
    Write-Warning " Quick fix — run from the test/ directory:"
    Write-Warning "   ./Set-MacHostConditionSet.ps1"
    Write-Warning ""
    Write-Warning " Or manually in System Settings:"
    Write-Warning "   1. Displays > Advanced > Prevent automatic sleeping when"
    Write-Warning "      the display is off  → ON"
    Write-Warning "   2. Lock Screen > Start Screen Saver when inactive → Never"
    Write-Warning "   3. Lock Screen > Require password after screen saver → OFF"
    Write-Warning "   4. Energy > Turn display off → Never  (or run:"
    Write-Warning "        sudo pmset -c displaysleep 0"
    Write-Warning "        sudo pmset -b displaysleep 0 )"
    Write-Warning "═══════════════════════════════════════════════════════════════════"
    return $false
}

function Set-MacHostConditionSet {
    <#
    .SYNOPSIS
    Configures macOS host settings needed for unattended VM testing:
    disables display sleep, screen saver idle, and screen lock password.
    Also triggers the Accessibility permission prompt if not already granted.
    Requires sudo for pmset. Idempotent — safe to run multiple times.
    .EXAMPLE
    Set-MacHostConditionSet          # apply all settings
    Set-MacHostConditionSet -WhatIf  # show what would change without applying
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $IsMacOS) {
        Write-Warning "Set-MacHostConditionSet is only supported on macOS."
        return
    }

    # ── 1. Display sleep → Never (requires sudo) ─────────────────────────
    $changed = $false
    foreach ($source in @("-c", "-b")) {   # -c = charger, -b = battery
        $pmLine = & pmset -g custom 2>$null | Select-String '^\s*displaysleep\s+(\d+)' | Select-Object -First 1
        # Re-read per source is overkill, but pmset -g custom shows the active profile.
        # We just set both unconditionally — it's harmless if -b doesn't exist.
    }
    # Read current AC value
    $currentSleep = "unknown"
    $pmLine = & pmset -g custom 2>$null | Select-String '^\s*displaysleep\s+(\d+)' | Select-Object -First 1
    if ($pmLine) { $currentSleep = $pmLine.Matches[0].Groups[1].Value }

    if ($currentSleep -ne "0") {
        if ($PSCmdlet.ShouldProcess("Display sleep (currently $currentSleep min)", "Set to 0 (Never) via sudo pmset")) {
            Write-Output "Setting display sleep to Never (AC and battery)..."
            & sudo pmset -c displaysleep 0
            & sudo pmset -b displaysleep 0
            $changed = $true
        }
    } else {
        Write-Output "Display sleep is already set to Never."
    }

    # ── 2. Screen saver idle time → 0 (disabled) ─────────────────────────
    $ssIdle = & defaults read com.apple.screensaver idleTime 2>$null
    $ssIsActive = ($LASTEXITCODE -eq 0 -and "$ssIdle".Trim() -ne "0")

    if ($ssIsActive) {
        if ($PSCmdlet.ShouldProcess("Screen saver idle time (currently $($ssIdle.Trim())s)", "Set to 0 (disabled)")) {
            Write-Output "Disabling screen saver idle activation..."
            & defaults write com.apple.screensaver idleTime -int 0
            $changed = $true
        }
    } else {
        Write-Output "Screen saver idle activation is already disabled."
    }

    # ── 3. Screen lock (password after screen saver) → OFF ───────────────
    $askPw = & defaults read com.apple.screensaver askForPassword 2>$null
    $lockOn = ($LASTEXITCODE -eq 0 -and "$askPw".Trim() -eq "1")

    if ($lockOn) {
        if ($PSCmdlet.ShouldProcess("Screen lock password", "Disable (askForPassword → 0)")) {
            Write-Output "Disabling screen lock password requirement..."
            & defaults write com.apple.screensaver askForPassword -int 0
            $changed = $true
        }
    } else {
        Write-Output "Screen lock password is already disabled."
    }

    # ── 2b. Screen saver idle — per-host variant (Ventura+) ──────────────
    # Modern macOS stores screensaver prefs under the ByHost domain. Without
    # this, the System Settings UI still shows a non-zero idle time even after
    # section 2 above, and the screen saver will still kick in.
    $ssIdleHost = & defaults -currentHost read com.apple.screensaver idleTime 2>$null
    if ($LASTEXITCODE -eq 0 -and "$ssIdleHost".Trim() -ne "0") {
        if ($PSCmdlet.ShouldProcess("Screen saver idle time [currentHost] (currently $($ssIdleHost.Trim())s)", "Set to 0 (disabled)")) {
            Write-Output "Disabling screen saver idle activation (currentHost)..."
            & defaults -currentHost write com.apple.screensaver idleTime -int 0
            $changed = $true
        }
    } else {
        Write-Output "Screen saver idle activation (currentHost) is already disabled."
    }

    # ── 3b. Screen lock password — per-host variant ─────────────────────
    $askPwHost = & defaults -currentHost read com.apple.screensaver askForPassword 2>$null
    if ($LASTEXITCODE -eq 0 -and "$askPwHost".Trim() -eq "1") {
        if ($PSCmdlet.ShouldProcess("Screen lock password [currentHost]", "Disable (askForPassword → 0)")) {
            Write-Output "Disabling screen lock password requirement (currentHost)..."
            & defaults -currentHost write com.apple.screensaver askForPassword -int 0
            $changed = $true
        }
    } else {
        Write-Output "Screen lock password (currentHost) is already disabled."
    }

    # ── 3c. "Require password after sleep/screen saver begins" delay ─────
    # Sonoma+ lock-screen pane: "Require password ... after X". Setting a
    # very large delay effectively prevents the lock from engaging even if
    # some other process re-enables askForPassword.
    & defaults write com.apple.screensaver askForPasswordDelay -int 2147483647 2>$null | Out-Null
    & defaults -currentHost write com.apple.screensaver askForPasswordDelay -int 2147483647 2>$null | Out-Null

    # ── 3d. System sleep → Never (requires sudo) ─────────────────────────
    # Display-sleep alone isn't enough: if the whole system sleeps, the
    # display locks on wake regardless of screensaver settings.
    $currentSysSleep = "unknown"
    $sysLine = & pmset -g custom 2>$null | Select-String '^\s*[^d]\s*sleep\s+(\d+)' | Select-Object -First 1
    if ($sysLine) { $currentSysSleep = $sysLine.Matches[0].Groups[1].Value }

    if ($currentSysSleep -ne "0") {
        if ($PSCmdlet.ShouldProcess("System sleep (currently $currentSysSleep min)", "Set to 0 (Never) via sudo pmset")) {
            Write-Output "Setting system sleep to Never (AC and battery)..."
            & sudo pmset -c sleep 0
            & sudo pmset -b sleep 0
            & sudo pmset -c disksleep 0
            $changed = $true
        }
    } else {
        Write-Output "System sleep is already set to Never."
    }

    # ── 3e. Prevent idle sleep explicitly ─────────────────────────────────
    # Belt-and-suspenders: disable the idle-sleep assertion even if some
    # other subsystem tries to re-enable it.
    & sudo pmset -c disablesleep 1 2>$null | Out-Null

    # ── 4. Accessibility — trigger the system prompt if not granted ───────
    try {
        $jxa = "ObjC.import('ApplicationServices'); $.AXIsProcessTrusted();"
        $axResult = & osascript -l JavaScript -e $jxa 2>&1
        if ("$axResult" -eq "true") {
            Write-Output "Accessibility permission is already granted."
        } else {
            Write-Output "Requesting Accessibility permission (a system dialog should appear)..."
            # AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt = true
            # triggers the macOS consent dialog.
            $jxaPrompt = @"
ObjC.import('CoreFoundation');
ObjC.import('ApplicationServices');
var opts = $.CFDictionaryCreateMutable(null, 1,
    $.kCFTypeDictionaryKeyCallBacks, $.kCFTypeDictionaryValueCallBacks);
var key = $.CFStringCreateWithCString(null, 'AXTrustedCheckOptionPrompt', 0);
$.CFDictionarySetValue(opts, key, $.kCFBooleanTrue);
$.AXIsProcessTrustedWithOptions(opts);
"@
            & osascript -l JavaScript -e $jxaPrompt 2>&1 | Out-Null
            Write-Output "  → Grant access in the dialog, then re-run the test."
        }
    } catch {
        Write-Debug "Accessibility prompt failed: $_"
        Write-Warning "Could not check Accessibility status. Grant it manually in System Settings."
    }

    if ($changed) {
        Write-Output ""
        Write-Output "Settings updated. Re-run Assert-MacHostConditionSet to verify:"
        Write-Output "  Assert-MacHostConditionSet -HostType 'host.macos.utm'"
    }
}

function Set-WindowsHostConditionSet {
    <#
    .SYNOPSIS
    Configures Windows host settings needed for unattended VM testing:
    starts the Hyper-V service, disables display timeout, and disables the
    inactivity lock screen.  Requires Administrator elevation.  Idempotent.
    .EXAMPLE
    Set-WindowsHostConditionSet          # apply all settings
    Set-WindowsHostConditionSet -WhatIf  # show what would change without applying
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $IsWindows) {
        Write-Warning "Set-WindowsHostConditionSet is only supported on Windows."
        return
    }

    # ── 0. Elevation check ───────────────────────────────────────────────
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]"Administrator")
    if (-not $isAdmin) {
        Write-Error "This script must be run as Administrator. Right-click PowerShell → Run as Administrator."
        return
    }

    $changed = $false

    # ── 1. Hyper-V service ───────────────────────────────────────────────
    $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Warning "Hyper-V service (vmms) is not installed."
        Write-Warning "  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All"
        Write-Warning "Then reboot and re-run this script."
    } elseif ($svc.Status -ne 'Running') {
        if ($PSCmdlet.ShouldProcess("Hyper-V service (vmms)", "Start")) {
            Write-Output "Starting Hyper-V Virtual Machine Management service..."
            Start-Service vmms
            $changed = $true
        }
    } else {
        Write-Output "Hyper-V service (vmms) is already running."
    }

    # ── 2. Display timeout → Never ───────────────────────────────────────
    $acTimeout = powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null |
        Select-String 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)' |
        Select-Object -First 1
    $currentAc = if ($acTimeout) { [Convert]::ToInt32($acTimeout.Matches[0].Groups[1].Value, 16) } else { 0 }

    if ($currentAc -ne 0) {
        $minutes = [math]::Round($currentAc / 60)
        if ($PSCmdlet.ShouldProcess("Display timeout AC (currently $minutes min)", "Set to 0 (Never)")) {
            Write-Output "Setting display timeout to Never (AC and DC)..."
            & powercfg /change monitor-timeout-ac 0
            & powercfg /change monitor-timeout-dc 0
            $changed = $true
        }
    } else {
        Write-Output "Display timeout (AC) is already set to Never."
    }

    # ── 3. Machine inactivity lock → disabled ────────────────────────────
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $lockTimeout = $null
    $regProps = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
    if ($regProps -and $regProps.PSObject.Properties.Name -contains 'InactivityTimeoutSecs') {
        $lockTimeout = $regProps.InactivityTimeoutSecs
    }

    if ($lockTimeout -and $lockTimeout -gt 0) {
        if ($PSCmdlet.ShouldProcess("Inactivity lock timeout (currently ${lockTimeout}s)", "Set to 0 (disabled)")) {
            Write-Output "Disabling machine inactivity lock..."
            Set-ItemProperty -Path $regPath -Name 'InactivityTimeoutSecs' -Value 0
            $changed = $true
        }
    } else {
        Write-Output "Machine inactivity lock is already disabled."
    }

    # ── 4. Lock screen on resume → disabled ──────────────────────────────
    # Check the power-plan consolelock setting via powercfg
    $consoleLock = powercfg /query SCHEME_CURRENT SUB_NONE CONSOLELOCK 2>$null |
        Select-String 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)' |
        Select-Object -First 1
    $consoleLockVal = if ($consoleLock) { [Convert]::ToInt32($consoleLock.Matches[0].Groups[1].Value, 16) } else { $null }

    if ($consoleLockVal -and $consoleLockVal -ne 0) {
        if ($PSCmdlet.ShouldProcess("Console lock on resume (currently enabled)", "Disable")) {
            Write-Output "Disabling lock screen on resume from sleep..."
            & powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
            & powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
            & powercfg /SETACTIVE SCHEME_CURRENT
            $changed = $true
        }
    } else {
        Write-Output "Lock screen on resume is already disabled (or not applicable)."
    }

    if ($changed) {
        Write-Output ""
        Write-Output "Settings updated. Re-run Assert-HostConditionSet to verify:"
        Write-Output "  Assert-HostConditionSet -HostType 'host.windows.hyper-v'"
    }
}

function Assert-Accessibility {
    <#
    .SYNOPSIS
    On macOS, checks that the terminal has Accessibility permission (required for
    AXUIElementPostKeyboardEvent). Returns $true if granted or not on macOS.
    Prints setup instructions and returns $false if the permission is missing.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    # AXIsProcessTrusted() returns true when the calling process has Accessibility access.
    try {
        $jxa = "ObjC.import('ApplicationServices'); $.AXIsProcessTrusted();"
        $result = & osascript -l JavaScript -e $jxa 2>&1
        if ("$result" -eq "true") { return $true }
    } catch {
        Write-Debug "Accessibility check failed: $_"
    }

    Write-Warning "═══════════════════════════════════════════════════════════════════"
    Write-Warning " Accessibility permission is NOT granted for this terminal."
    Write-Warning ""
    Write-Warning " The test harness needs Accessibility access to send keystrokes"
    Write-Warning " to UTM VMs without requiring window focus."
    Write-Warning ""
    Write-Warning " To fix:"
    Write-Warning "   1. Open System Settings > Privacy & Security > Accessibility"
    Write-Warning "   2. Click the + button and add your terminal app"
    Write-Warning "      (Terminal.app, iTerm2, or whichever you use)"
    Write-Warning "   3. Ensure the toggle is ON"
    Write-Warning "   4. Restart the terminal and re-run the test"
    Write-Warning ""
    Write-Warning " Without this permission, keystrokes require UTM to stay focused"
    Write-Warning " and any window change will cause missed input."
    Write-Warning "═══════════════════════════════════════════════════════════════════"
    return $false
}

function Assert-MacHostConditionSet {
    <#
    .SYNOPSIS
    Single gate for all macOS host prerequisites: Accessibility permission and
    screen lock / display sleep settings.  Returns $true on non-macOS hosts or
    when all conditions pass.  Returns $false and prints diagnostics on failure.
    Callers should invoke this once at startup and again before each test cycle.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    if (-not (Assert-Accessibility -HostType $HostType)) { return $false }
    if (-not (Assert-ScreenLock    -HostType $HostType)) { return $false }

    return $true
}

function Assert-WindowsHostConditionSet {
    <#
    .SYNOPSIS
    Single gate for all Windows host prerequisites: Administrator elevation and
    Hyper-V service availability.  Returns $true on non-Windows hosts or when all
    conditions pass.  Returns $false and prints diagnostics on failure.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.windows.hyper-v") { return $true }

    # 1. Administrator elevation
    if (-not (Assert-Elevation -HostType $HostType)) { return $false }

    # 2. Hyper-V management service must be running
    $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') {
        Write-Warning "═══════════════════════════════════════════════════════════════════"
        Write-Warning " Hyper-V Virtual Machine Management service (vmms) is not running."
        Write-Warning ""
        Write-Warning " Quick fix — run from an elevated PowerShell in the test/ directory:"
        Write-Warning "   ./Set-WindowsHostConditionSet.ps1"
        Write-Warning ""
        Write-Warning " If Hyper-V is not installed, enable it first:"
        Write-Warning "   Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All"
        Write-Warning " then reboot."
        Write-Warning "═══════════════════════════════════════════════════════════════════"
        return $false
    }

    # 3. Screen lock / display timeout — warn if display will turn off
    try {
        $acTimeout = (powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null |
            Select-String 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)' |
            Select-Object -First 1)
        if ($acTimeout) {
            $seconds = [Convert]::ToInt32($acTimeout.Matches[0].Groups[1].Value, 16)
            if ($seconds -ne 0) {
                $minutes = [math]::Round($seconds / 60)
                Write-Warning "═══════════════════════════════════════════════════════════════════"
                Write-Warning " Display timeout is set to $minutes minute(s) on AC power."
                Write-Warning " The screen will blank during long test runs, which may cause"
                Write-Warning " Hyper-V Enhanced Session screen captures to fail."
                Write-Warning ""
                Write-Warning " Quick fix — run from an elevated PowerShell in the test/ directory:"
                Write-Warning "   ./Set-WindowsHostConditionSet.ps1"
                Write-Warning "═══════════════════════════════════════════════════════════════════"
                return $false
            }
        }
    } catch {
        Write-Debug "Display timeout check failed: $_"
    }

    # 4. Lock screen timeout — warn if machine will lock
    try {
        $lockTimeout = $null
        $regProps = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
        if ($regProps -and $regProps.PSObject.Properties.Name -contains 'InactivityTimeoutSecs') {
            $lockTimeout = $regProps.InactivityTimeoutSecs
        }
        if ($lockTimeout -and $lockTimeout -gt 0) {
            Write-Warning "═══════════════════════════════════════════════════════════════════"
            Write-Warning " Machine inactivity lock is set to $lockTimeout second(s)."
            Write-Warning " The lock screen will activate during long test runs."
            Write-Warning ""
            Write-Warning " Quick fix — run from an elevated PowerShell in the test/ directory:"
            Write-Warning "   ./Set-WindowsHostConditionSet.ps1"
            Write-Warning "═══════════════════════════════════════════════════════════════════"
            return $false
        }
    } catch {
        Write-Debug "Lock screen timeout check failed: $_"
    }

    return $true
}

function Assert-HostConditionSet {
    <#
    .SYNOPSIS
    Platform dispatcher: calls Assert-WindowsHostConditionSet or
    Assert-MacHostConditionSet based on the detected host type.
    Returns $true when all platform-specific prerequisites are met.
    #>
    param([string]$HostType)

    if ($HostType -eq "host.windows.hyper-v") {
        return Assert-WindowsHostConditionSet -HostType $HostType
    }
    if ($HostType -eq "host.macos.utm") {
        return Assert-MacHostConditionSet -HostType $HostType
    }

    Write-Warning "Unknown host type '$HostType' — skipping condition checks."
    return $true
}

function Invoke-GitPull {
    <#
    .SYNOPSIS
    Runs git pull in the repo root. Returns $true on success.
    #>
    param([string]$RepoRoot)

    # Fetch latest from remote without modifying the working tree
    Write-Information "Fetching remote changes in: $RepoRoot" -InformationAction Continue
    $output = & git -C $RepoRoot fetch 2>&1
    Write-Information "$output" -InformationAction Continue
    if ($LASTEXITCODE -ne 0) {
        Write-Error "git fetch failed (exit $LASTEXITCODE)."
        return $false
    }

    # Determine local vs remote HEAD positions
    $local  = & git -C $RepoRoot rev-parse HEAD 2>$null
    $remote = & git -C $RepoRoot rev-parse '@{u}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Information "No upstream tracking branch found; skipping ahead/behind check." -InformationAction Continue
        return $true
    }

    if ($local -eq $remote) {
        Write-Information "Local branch is up to date with remote." -InformationAction Continue
        return $true
    }

    $mergeBase = & git -C $RepoRoot merge-base $local $remote 2>$null

    if ($mergeBase -eq $remote) {
        # Local is ahead of remote — local commits not yet pushed; that's fine
        Write-Information "Local branch is ahead of remote. Proceeding with local changes." -InformationAction Continue
        return $true
    }

    # Local is behind or diverged from remote
    $behind = & git -C $RepoRoot rev-list --count "$local..$remote" 2>$null
    if ($mergeBase -eq $local) {
        # Local is behind — safe to fast-forward pull
        Write-Information "Local branch is behind remote by $behind commit(s). Pulling..." -InformationAction Continue
        $pullOutput = & git -C $RepoRoot pull --ff-only 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Information "Pull succeeded: $pullOutput" -InformationAction Continue
            return $true
        }
        Write-Error "git pull --ff-only failed (exit $LASTEXITCODE): $pullOutput"
        return $false
    }

    # Diverged — local has commits not on remote AND remote has commits not on local
    $ahead = & git -C $RepoRoot rev-list --count "$remote..$local" 2>$null
    Write-Error "Local branch has diverged from remote ($ahead ahead, $behind behind). Rebase or merge manually."
    return $false
}

function Get-CurrentGitCommit {
    <#
    .SYNOPSIS
    Returns the short git commit hash of HEAD.
    #>
    param([string]$RepoRoot)
    $hash = & git -C $RepoRoot rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return "unknown" }
    return $hash.Trim()
}

Export-ModuleMember -Function Get-HostType, Get-GuestList, Test-GuestFolder, Get-TestVMName, Test-ElevationRequired, Assert-HostConditionSet, Set-MacHostConditionSet, Set-WindowsHostConditionSet, Invoke-GitPull, Get-CurrentGitCommit
