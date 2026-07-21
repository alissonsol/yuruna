<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42d4a3b2-c1f0-4e89-5678-9a0b1c2d3e40
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host macos
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

# macOS sibling of Test.HostCondition.psm1: applies AND asserts the
# per-host preconditions for unattended VM testing on host.macos.utm
# (display sleep / screen lock, Accessibility + Screen Recording TCC
# grants, sudo cache priming). Loaded by the Test.HostCondition.psm1
# facade; callers continue to import the facade and resolve these
# names through its Export-ModuleMember. See Test.HostCondition.psm1
# for the per-platform split rationale.

function Get-MacPmsetGuardList {
    <#
    .SYNOPSIS
    The canonical extended-pmset guard list (key + wanted value) that keeps
    macOS awake and CG-enumerable for unattended UTM capture. Consumed by BOTH
    Set-MacHostConditionSet (to apply + decide re-apply) and Assert-ScreenLock
    (to re-verify before each cycle), so the asserted set is exactly the applied
    set -- a host that drifts (MDM re-enables a guard, pmset reverts on an OS
    update) fails the gate instead of blanking UTM mid-run. Per-key rationale at
    https://yuruna.link/host/macos.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @(
        @{ Key = 'disablesleep'  ; Want = 1 }
        @{ Key = 'powernap'      ; Want = 0 }
        @{ Key = 'standby'       ; Want = 0 }
        @{ Key = 'standbydelay'  ; Want = 0 }
        @{ Key = 'autopoweroff'  ; Want = 0 }
        @{ Key = 'hibernatemode' ; Want = 0 }
        @{ Key = 'ttyskeepawake' ; Want = 1 }
        @{ Key = 'tcpkeepalive'  ; Want = 1 }
        @{ Key = 'proximitywake' ; Want = 0 }
    )
}

function Confirm-MacDefaultWrite {
    <#
    .SYNOPSIS
    Write a `defaults` key, then re-read it and confirm it took. A bare
    `defaults write ... 2>$null | Out-Null` swallows the exit code, so a
    failed write (locked domain, MDM-reverted key, typo) reads back as
    silent success. This writes, re-reads, and Write-Warnings when the value
    doesn't match -- callers gate $changed on the returned [bool] so a phantom
    success can't claim the host was configured when it wasn't.
    .PARAMETER DefaultsArgs
    The arguments that select the domain + key, in `defaults` order, WITHOUT
    the leading verb -- e.g. @('com.apple.dock','wvous-tl-corner') or
    @('-currentHost','com.apple.screensaver','askForPasswordDelay'). The verb
    (write / read) is prepended internally.
    .PARAMETER WriteType
    The value-type flag for the write, e.g. '-int' or '-bool'.
    .PARAMETER WriteValue
    The value to write, e.g. '0', '2147483647', 'YES', 'false'.
    .PARAMETER ExpectRead
    What `defaults read` returns for that written value once stored (defaults
    normalizes -bool YES/true->1, NO/false->0, and echoes -int values). The
    re-read is trimmed and compared ordinally against this.
    .OUTPUTS
    [bool] $true when the re-read matches ExpectRead; $false (with a warning)
    otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string[]]$DefaultsArgs,
        [string]$WriteType,
        [string]$WriteValue,
        [string]$ExpectRead
    )
    & defaults write @DefaultsArgs $WriteType $WriteValue 2>$null | Out-Null
    $readBack = & defaults read @DefaultsArgs 2>$null
    $readOk = ($LASTEXITCODE -eq 0)
    if ($readOk -and "$readBack".Trim() -eq $ExpectRead) { return $true }
    $actual = if ($readOk) { "$readBack".Trim() } else { '<unset>' }
    Write-Warning ("defaults write {0} {1} {2} did not take (read back '{3}', wanted '{4}'). The domain may be locked or MDM-managed." -f ($DefaultsArgs -join ' '), $WriteType, $WriteValue, $actual, $ExpectRead)
    return $false
}

function Get-MacDangerousHotCornerMap {
    <#
    .SYNOPSIS
    The canonical map of hot-corner action codes (as they appear in
    `defaults read com.apple.dock wvous-<corner>-corner`) that blank or lock
    the display during an unattended run and drop the UTM window from the CG
    window list. Shared by BOTH Assert-ScreenLock (to flag a dangerous
    binding) and Set-MacHostConditionSet (to neutralize it), so the asserted
    set is exactly the applied set -- a code added to one path can't silently
    be missed by the other. Safe codes (0=none, 2=Mission Control,
    3=Show App Windows, 4=Desktop, 11=Launchpad, 12=Notification Center,
    14=Quick Note) are intentionally absent and left untouched.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    # Keys are digit strings ('5'/'10'/'13') matched against trimmed
    # `defaults read` output, so the default case-insensitive @{} is safe --
    # digits have no case to collide.
    return @{
        '5'  = 'Start Screen Saver'
        '10' = 'Put Display to Sleep'
        '13' = 'Lock Screen'
    }
}

function Get-MacScreenLockDisabled {
    <#
    .SYNOPSIS
    Parse `sysadminctl -screenLock status` output: strip the macOS NSLog
    prefix ("YYYY-MM-DD ... sysadminctl[pid:tid] ") and decide whether the
    unified screen lock is disabled. Shared by Assert-ScreenLock and
    Set-MacHostConditionSet so the strip regex and the accepted "off" forms
    ("screenLock is off" OR "delay is -1") can't diverge between the gate and
    the apply path.
    .PARAMETER Raw
    The raw first line captured from `sysadminctl -screenLock status 2>&1`.
    .OUTPUTS
    [pscustomobject] with .Status (NSLog-stripped text for messages) and
    .Disabled ([bool] $true when the lock is off / delay is -1).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Raw)
    $status = "$Raw" -replace '^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+\s+sysadminctl\[\d+:\w+\]\s+', ''
    return [pscustomobject]@{
        Status   = $status
        Disabled = ($status -match 'screenLock\s+(is\s+off|delay\s+is\s+-1)')
    }
}

function Assert-ScreenLock {
    <#
    .SYNOPSIS
    macOS: verify screen saver lock and display sleep won't blank the
    screen during long-running VM tests. Returns $true if settings are
    acceptable (or not on macOS). Prints instructions and returns $false
    otherwise.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    $issues = @()

    # 1. Display sleep idle time (pmset -g custom -> displaysleep).
    #    0 = never sleep (good); > 0 means display will blank.
    try {
        $pmsetLine = & pmset -g custom 2>$null | Select-String '^\s*displaysleep\s+(\d+)' | Select-Object -First 1
        if ($pmsetLine -and $pmsetLine.Matches[0].Groups[1].Value -ne "0") {
            $sleepMin = $pmsetLine.Matches[0].Groups[1].Value
            $issues += "Display sleep is set to $sleepMin minute(s)."
        }
    } catch {
        Write-Debug "pmset check failed: $_"
    }

    # 2. Screen saver idleTime (defaults read com.apple.screensaver idleTime).
    #    0 = disabled. A MISSING key is NOT safe -- macOS falls back to
    #    a built-in default (~1200s), which lets the screensaver engage
    #    after 20 min despite the script reporting "already disabled".
    #    Flag both missing AND non-zero. Check per-host domain too;
    #    either being unsafe engages the saver.
    try {
        $idleTime     = & defaults read              com.apple.screensaver idleTime 2>$null
        $idleTimeHead = $LASTEXITCODE
        $idleTimeHost = & defaults -currentHost read com.apple.screensaver idleTime 2>$null
        $idleTimeHostHead = $LASTEXITCODE
        if ($idleTimeHead -ne 0) {
            $issues += "Screen saver idleTime is unset (user domain) -- macOS default applies (~20 min)."
        } elseif ("$idleTime".Trim() -ne "0") {
            $issues += "Screen saver activates after $($idleTime.Trim()) second(s) (user domain)."
        }
        if ($idleTimeHostHead -ne 0) {
            $issues += "Screen saver idleTime is unset (currentHost) -- macOS default applies (~20 min)."
        } elseif ("$idleTimeHost".Trim() -ne "0") {
            $issues += "Screen saver activates after $($idleTimeHost.Trim()) second(s) (currentHost)."
        }
    } catch {
        Write-Debug "Screen saver check failed: $_"
    }

    # 3. Password after screen saver (askForPassword). Missing key on
    #    some macOS versions defaults to 1 (on) -- flag missing AND
    #    explicit 1. Check both domains.
    try {
        $askPw     = & defaults read              com.apple.screensaver askForPassword 2>$null
        $askPwHead = $LASTEXITCODE
        $askPwHost = & defaults -currentHost read com.apple.screensaver askForPassword 2>$null
        $askPwHostHead = $LASTEXITCODE
        if ($askPwHead -ne 0) {
            $issues += "Screen lock askForPassword is unset (user domain) -- macOS default may be 1."
        } elseif ("$askPw".Trim() -eq "1") {
            $issues += "Screen lock (password after screen saver) is enabled (user domain)."
        }
        if ($askPwHostHead -ne 0) {
            $issues += "Screen lock askForPassword is unset (currentHost) -- macOS default may be 1."
        } elseif ("$askPwHost".Trim() -eq "1") {
            $issues += "Screen lock (password after screen saver) is enabled (currentHost)."
        }
    } catch {
        Write-Debug "Screen lock password check failed: $_"
    }

    # 4. Hot corners bound to Start Screen Saver / Sleep Display / Lock
    #    Screen. A drifting cursor during an unattended run can trigger
    #    these and drop the UTM window from CGWindowList.
    try {
        $dangerousCorners = Get-MacDangerousHotCornerMap
        foreach ($corner in @('tl','tr','bl','br')) {
            $val = & defaults read com.apple.dock "wvous-$corner-corner" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $valTrim = "$val".Trim()
                if ($dangerousCorners.ContainsKey($valTrim)) {
                    $issues += "Hot corner '$corner' triggers '$($dangerousCorners[$valTrim])'."
                }
            }
        }
    } catch {
        Write-Debug "Hot-corner check failed: $_"
    }

    # 5. App Nap suppressed for UTM.app -- else macOS throttles UTM's UI
    #    thread and drops its window from CGWindowList even while the VM
    #    runs. Matches "UTM window for '<vm>' not found" symptom.
    try {
        $nap = & defaults read com.utmapp.UTM NSAppSleepDisabled 2>$null
        if ($LASTEXITCODE -ne 0 -or "$nap".Trim() -ne '1') {
            $issues += "App Nap is not suppressed for UTM.app (com.utmapp.UTM NSAppSleepDisabled not set to 1)."
        }
    } catch {
        Write-Debug "App Nap check failed: $_"
    }

    # 6. sysadminctl unified screen lock (Ventura+). Overrides legacy
    #    askForPassword* keys -- the machine can still lock even when
    #    every individual defaults key is "safe". Accepted "disabled"
    #    forms from sysadminctl -screenLock status:
    #      * "screenLock delay is -1(.000000) seconds"
    #      * "screenLock is off"
    #    Anything else (e.g. "delay is 300 seconds") means a lock delay is active.
    try {
        $slParsed = Get-MacScreenLockDisabled -Raw (& sysadminctl -screenLock status 2>&1 | Select-Object -First 1)
        if (-not $slParsed.Disabled) {
            $issues += "sysadminctl $($slParsed.Status)"
        }
    } catch {
        Write-Debug "sysadminctl -screenLock check failed: $_"
    }

    # 7. Auto-logout after inactivity ("Log out after N minutes" in
    #    Security / Advanced). Kicks user to loginwindow -- same
    #    password-demand symptom as a lock. System-level pref;
    #    world-readable, no sudo.
    try {
        $autoLogout = & defaults read /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay 2>$null
        if ($LASTEXITCODE -eq 0 -and "$autoLogout".Trim() -ne "0") {
            $issues += "Auto-logout is active after $($autoLogout.Trim())s of inactivity (AutoLogOutDelay)."
        }
    } catch {
        Write-Debug "AutoLogOutDelay check failed: $_"
    }

    # 8. System sleep + disk sleep -> Never. Display-sleep alone (sec 1) isn't
    #    enough: a system/disk-sleep wake re-locks the screen on Ventura+
    #    regardless of screensaver settings. Set-MacHostConditionSet disables
    #    both, so the gate must re-verify them.
    # 9. Extended pmset guards (Power Nap, standby, autopoweroff, hibernate, ...)
    #    that Set-MacHostConditionSet applies. The gate re-verifies them from the
    #    same Get-MacPmsetGuardList Set- applies, so the asserted set is exactly
    #    the applied set and a drifted host fails here instead of blanking UTM
    #    mid-run. A key absent from 'pmset -g custom' (macOS-version dependent) is
    #    skipped, matching how Set- decides.
    try {
        $pmCustom = & pmset -g custom 2>$null
        foreach ($k in @('sleep', 'disksleep')) {
            $line = $pmCustom | Select-String -Pattern ('^\s*' + $k + '\s+(\d+)') | Select-Object -First 1
            if ($line -and [int]$line.Matches[0].Groups[1].Value -ne 0) {
                $issues += "$k is set to $($line.Matches[0].Groups[1].Value) minute(s) -- a wake re-locks the screen (should be 0 / Never)."
            }
        }
        foreach ($g in (Get-MacPmsetGuardList)) {
            $gLine = $pmCustom | Select-String -Pattern ('^\s*' + [regex]::Escape($g.Key) + '\s+(\d+)') | Select-Object -First 1
            if ($gLine -and [int]$gLine.Matches[0].Groups[1].Value -ne $g.Want) {
                $issues += "pmset $($g.Key) is $($gLine.Matches[0].Groups[1].Value) (should be $($g.Want))."
            }
        }
    } catch {
        Write-Debug "pmset system-sleep / extended-guard check failed: $_"
    }

    if ($issues.Count -eq 0) { return $true }

    Write-Warning "==================================================================="
    Write-Warning " Screen lock / display sleep settings will blank the VM display."
    Write-Warning ""
    foreach ($issue in $issues) {
        Write-Warning "  * $issue"
    }
    Write-Warning ""
    Write-Warning " When the display blanks, UTM screen captures return a black"
    Write-Warning " image and OCR-based waitForText steps will time out."
    Write-Warning ""
    Write-Warning " Quick fix -- run from the repo root:"
    Write-Warning "   pwsh ./host/macos.utm/Enable-TestAutomation.ps1"
    Write-Warning ""
    Write-Warning " Or manually in System Settings:"
    Write-Warning "   1. Displays > Advanced > Prevent automatic sleeping when"
    Write-Warning "      the display is off  -> ON"
    Write-Warning "   2. Lock Screen > Start Screen Saver when inactive -> Never"
    Write-Warning "   3. Lock Screen > Require password after screen saver -> OFF"
    Write-Warning "   4. Energy > Turn display off -> Never  (or run:"
    Write-Warning "        sudo pmset -c displaysleep 0"
    Write-Warning "        sudo pmset -b displaysleep 0 )"
    Write-Warning "==================================================================="
    return $false
}

function Initialize-SudoCache {
<#
.SYNOPSIS
    Prime the sudo credential cache once, with a friendly notice, so a
    long sequence of subsequent sudo calls runs without re-prompting.
.DESCRIPTION
    Host-prep PowerShell scripts (Set-MacHostConditionSet, the per-host
    Enable-TestAutomation.ps1 family) make many sudo invocations in
    succession -- pmset, defaults write /Library/Preferences,
    sysadminctl, systemctl, virsh net-*. With a default macOS / Linux
    sudoers config those share a per-tty timestamp that lasts ~5 min,
    so a single `sudo -v` up front is enough to keep the rest silent.
    Without this, the operator sees "[sudo] password for ..." on every
    individual call.

    Idempotent: if `sudo -n true` already succeeds (cache warm because
    the install/<host>.sh wrapper primed it, or a prior call in this
    pwsh process already cached), the function returns silently with no
    output and no prompt. Skipped entirely when running as root.

    Designed to be called at the very top of any PowerShell script /
    function that will make multiple sudo calls in a row.
.PARAMETER Reasons
    One-line descriptions of what the caller will do with sudo. Printed
    inside a fenced box just above the password prompt so the operator
    knows why they are being asked. Empty array prints a generic notice.
.OUTPUTS
    [bool] $true on success (cache is now warm or no elevation needed),
    $false on failure (sudo missing, user cancelled, wrong password).
    Never throws -- callers decide whether to proceed.
.EXAMPLE
    if (-not (Initialize-SudoCache -Reasons @('pmset display sleep', 'defaults write /Library/Preferences'))) {
        throw "Cannot proceed without sudo."
    }
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string[]]$Reasons = @()
    )
    # Windows has no sudo (UAC is a different model); only run on macOS / Linux.
    if (-not ($IsLinux -or $IsMacOS)) { return $true }
    # Already root: no sudo needed.
    try {
        $uid = (& '/usr/bin/id' -u 2>$null)
        if ("$uid".Trim() -eq '0') { return $true }
    } catch {
        Write-Verbose "Initialize-SudoCache: id command unavailable -- assuming non-root and proceeding."
    }
    if (-not (Get-Command sudo -ErrorAction SilentlyContinue)) {
        Write-Warning "Initialize-SudoCache: sudo not on PATH; downstream elevation will fail."
        return $false
    }
    # Cache already warm? Silent fast path -- no notice, no prompt.
    & sudo -n true 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    # Wrapper-primed mode: install/<host>.sh already showed the "ONCE"
    # notice AND ran a "sudo prelude" that pre-applied every value
    # Set-MacHostConditionSet would otherwise need sudo for. The pwsh
    # paths that follow are idempotent -- they read state without sudo
    # and only call sudo if a value still needs writing. In the common
    # case after the prelude, NO downstream sudo calls fire, so a
    # preemptive `sudo -v` here would prompt the operator for nothing.
    # Return $false silently and let the rare downstream call (e.g.
    # sysadminctl on a brand-new machine) trigger its own prompt at
    # the moment it's actually needed -- that prompt is at least tied
    # to a visible operation, not a "phantom" elevation.
    if ($env:YURUNA_SUDO_PRIMED -eq '1') {
        return $false
    }
    # Cache cold AND no wrapper context: print the friendly notice, then prompt.
    Write-Output ""
    Write-Output "  +---------------------------------------------------------------+"
    Write-Output "  | This script needs sudo for:                                   |"
    if ($Reasons.Count -gt 0) {
        foreach ($r in $Reasons) {
            $line = "    * $r"
            if ($line.Length -gt 63) { $line = $line.Substring(0, 60) + '...' }
            Write-Output ("  | {0,-61} |" -f $line)
        }
    } else {
        Write-Output "  |     (host configuration commands)                             |"
    }
    Write-Output "  | You will be prompted for your password ONCE, below.           |"
    Write-Output "  +---------------------------------------------------------------+"
    Write-Output ""
    & sudo -v
    return ($LASTEXITCODE -eq 0)
}

function Set-MacHostConditionSet {
    <#
    .SYNOPSIS
    Configures macOS host settings needed for unattended VM testing:
    disables display sleep, screen saver idle, and screen lock password;
    triggers first-run prompts for the Accessibility and Screen Recording
    TCC permissions (both required -- keystroke injection + per-window
    capture). Requires sudo for pmset. Idempotent.
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

    # -- 0. Sudo cache + wrapper-primed contract -------------------------
    # When invoked from install/macos.utm.sh, $env:YURUNA_SUDO_PRIMED='1'
    # signals that the bash wrapper already ran a "sudo prelude" -- one
    # batched `sudo bash -c '...'` covering every pmset / defaults write
    # this function would otherwise need sudo for. In that mode pwsh
    # MUST NOT call sudo for any of those writes: the bash sudo cache
    # may have been invalidated by a brew cask post-install (`sudo -k`)
    # or a Touch ID quirk by now, and a `sudo` here would re-prompt the
    # operator -- breaking the "ONCE" promise the wrapper printed.
    # If a value still doesn't read as wanted, warn and continue rather
    # than re-doing the work.
    #
    # When invoked standalone (no wrapper), behave as before: prime
    # sudo with the friendly box and run every block normally.
    $wrapperPrimed = ($env:YURUNA_SUDO_PRIMED -eq '1')
    if (-not $wrapperPrimed) {
        # This function makes ~16 sudo invocations across pmset, sysadminctl,
        # and defaults at /Library/Preferences. macOS sudo's default per-tty
        # 5-min timestamp covers all of them after a single up-front `sudo -v`.
        # The friendly notice only appears when the cache is genuinely cold.
        [void](Initialize-SudoCache -Reasons @(
            'pmset (display sleep, system sleep, power-nap, hibernation)',
            'defaults write /Library/Preferences (auto-logout delay)',
            'sysadminctl -screenLock off (Sonoma+ unified screen lock)'
        ))
    }

    # -- 1. Display sleep -> Never (requires sudo) -------------------------
    # `pmset -g custom` reports the active profile; the writes below cover
    # both AC (-c) and battery (-b) unconditionally, so a single read of the
    # current value is enough to decide whether a write is needed.
    $changed = $false
    $currentSleep = "unknown"
    $pmLine = & pmset -g custom 2>$null | Select-String '^\s*displaysleep\s+(\d+)' | Select-Object -First 1
    if ($pmLine) { $currentSleep = $pmLine.Matches[0].Groups[1].Value }

    if ($currentSleep -ne "0") {
        if ($wrapperPrimed) {
            Write-Warning "Display sleep is '$currentSleep' (expected 0). Run 'sudo pmset -c displaysleep 0; sudo pmset -b displaysleep 0' to fix."
        } elseif ($PSCmdlet.ShouldProcess("Display sleep (currently $currentSleep min)", "Set to 0 (Never) via sudo pmset")) {
            Write-Information "Setting display sleep to Never (AC and battery)..."
            & sudo pmset -c displaysleep 0
            & sudo pmset -b displaysleep 0
            $changed = $true
        }
    } else {
        Write-Information "Display sleep is already set to Never."
    }

    # -- 2. Screen saver idle time -> 0 (disabled) -------------------------
    # MISSING idleTime key is NOT the same as 0: macOS falls back to
    # ~1200s built-in default. Skip write only when the key EXISTS and is
    # exactly "0"; any other case (missing, empty, other number) triggers
    # an explicit write.
    $ssIdle = & defaults read com.apple.screensaver idleTime 2>$null
    $ssIdleRead = ($LASTEXITCODE -eq 0)
    if ($ssIdleRead -and "$ssIdle".Trim() -eq "0") {
        Write-Information "Screen saver idle activation is already disabled."
    } else {
        $label = if (-not $ssIdleRead) { 'unset -- macOS default applies' } else { "$($ssIdle.Trim())s" }
        if ($PSCmdlet.ShouldProcess("Screen saver idle time (currently $label)", "Set to 0 (disabled)")) {
            Write-Information "Disabling screen saver idle activation (was $label)..."
            & defaults write com.apple.screensaver idleTime -int 0
            $changed = $true
        }
    }

    # -- 3. Screen lock (password after screen saver) -> OFF ---------------
    # Same "missing key != safe" as sec 2: some macOS versions default
    # askForPassword to 1. Write 0 unless the key is explicitly "0".
    $askPw = & defaults read com.apple.screensaver askForPassword 2>$null
    $askPwRead = ($LASTEXITCODE -eq 0)
    if ($askPwRead -and "$askPw".Trim() -eq "0") {
        Write-Information "Screen lock password is already disabled."
    } else {
        $label = if (-not $askPwRead) { 'unset -- macOS default applies' } else { "$($askPw.Trim())" }
        if ($PSCmdlet.ShouldProcess("Screen lock password (currently $label)", "Disable (askForPassword -> 0)")) {
            Write-Information "Disabling screen lock password requirement (was $label)..."
            & defaults write com.apple.screensaver askForPassword -int 0
            $changed = $true
        }
    }

    # -- 2b. Screen saver idle -- per-host variant (Ventura+) --------------
    # Modern macOS stores screensaver prefs in the ByHost domain. Without
    # this, System Settings still shows non-zero idle time after sec 2 and
    # the saver still kicks in. Same missing-key-is-unsafe logic as sec 2.
    $ssIdleHost = & defaults -currentHost read com.apple.screensaver idleTime 2>$null
    $ssIdleHostRead = ($LASTEXITCODE -eq 0)
    if ($ssIdleHostRead -and "$ssIdleHost".Trim() -eq "0") {
        Write-Information "Screen saver idle activation (currentHost) is already disabled."
    } else {
        $label = if (-not $ssIdleHostRead) { 'unset -- macOS default applies' } else { "$($ssIdleHost.Trim())s" }
        if ($PSCmdlet.ShouldProcess("Screen saver idle time [currentHost] (currently $label)", "Set to 0 (disabled)")) {
            Write-Information "Disabling screen saver idle activation, currentHost (was $label)..."
            & defaults -currentHost write com.apple.screensaver idleTime -int 0
            $changed = $true
        }
    }

    # -- 3b. Screen lock password -- per-host variant ---------------------
    # Same missing-key-is-unsafe logic as sec 3.
    $askPwHost = & defaults -currentHost read com.apple.screensaver askForPassword 2>$null
    $askPwHostRead = ($LASTEXITCODE -eq 0)
    if ($askPwHostRead -and "$askPwHost".Trim() -eq "0") {
        Write-Information "Screen lock password (currentHost) is already disabled."
    } else {
        $label = if (-not $askPwHostRead) { 'unset -- macOS default applies' } else { "$($askPwHost.Trim())" }
        if ($PSCmdlet.ShouldProcess("Screen lock password [currentHost] (currently $label)", "Disable (askForPassword -> 0)")) {
            Write-Information "Disabling screen lock password requirement, currentHost (was $label)..."
            & defaults -currentHost write com.apple.screensaver askForPassword -int 0
            $changed = $true
        }
    }

    # -- 3c. "Require password after sleep/screen saver begins" delay -----
    # Sonoma+ lock-screen pane. A very large delay prevents lock from
    # engaging even if something re-enables askForPassword.
    [void](Confirm-MacDefaultWrite -DefaultsArgs @('com.apple.screensaver', 'askForPasswordDelay') -WriteType '-int' -WriteValue '2147483647' -ExpectRead '2147483647')
    [void](Confirm-MacDefaultWrite -DefaultsArgs @('-currentHost', 'com.apple.screensaver', 'askForPasswordDelay') -WriteType '-int' -WriteValue '2147483647' -ExpectRead '2147483647')

    # -- 3d. System sleep -> Never (requires sudo) -------------------------
    # Display-sleep alone isn't enough: system sleep -> display locks on
    # wake regardless of screensaver settings.
    $currentSysSleep = "unknown"
    $sysLine = & pmset -g custom 2>$null | Select-String '^\s*[^d]\s*sleep\s+(\d+)' | Select-Object -First 1
    if ($sysLine) { $currentSysSleep = $sysLine.Matches[0].Groups[1].Value }

    if ($currentSysSleep -ne "0") {
        if ($wrapperPrimed) {
            Write-Warning "System sleep is '$currentSysSleep' (expected 0). Run 'sudo pmset -a sleep 0 disksleep 0' to fix."
        } elseif ($PSCmdlet.ShouldProcess("System sleep (currently $currentSysSleep min)", "Set to 0 (Never) via sudo pmset")) {
            Write-Information "Setting system sleep to Never (all power sources)..."
            # -a covers AC + battery + UPS. Setting disksleep only on
            # -c leaves laptops on battery with disksleep=10; disk-sleep
            # wake re-checks lock state and on Ventura+ can trigger the
            # unified screen lock even with askForPassword=0.
            & sudo pmset -a sleep 0
            & sudo pmset -a disksleep 0
            $changed = $true
        }
    } else {
        Write-Information "System sleep is already set to Never."
    }

    # Extended pmset guards: Power Nap, standby, autopoweroff, hibernate
    # transitions hide UTM from CG enumeration on long runs. The guard list is
    # shared with Assert-ScreenLock (Get-MacPmsetGuardList) so the gate re-checks
    # exactly what is applied here. Per-key rationale, OptionalKey policy, and
    # precheck-before-sudo logic at https://yuruna.link/host/macos
    $pmsetGuards = Get-MacPmsetGuardList
    $pmCustom = & pmset -g custom 2>$null
    $pmsetAnyMismatch = $false
    foreach ($g in $pmsetGuards) {
        $line = $pmCustom | Select-String -Pattern ('^\s*' + [regex]::Escape($g.Key) + '\s+(\d+)') | Select-Object -First 1
        if ($line -and [int]$line.Matches[0].Groups[1].Value -ne $g.Want) {
            $pmsetAnyMismatch = $true; break
        }
    }
    $pmsetAllApplied = -not $pmsetAnyMismatch
    if ($pmsetAllApplied) {
        Write-Information "Extended pmset guards verified (no mismatched keys in 'pmset -g custom')."
    } elseif ($wrapperPrimed) {
        Write-Warning "Extended pmset guards have a mismatch in 'pmset -g custom'; bash prelude may need updating for this macOS version. Skipping."
    } elseif ($PSCmdlet.ShouldProcess("Extended pmset guards", "Apply via sudo pmset -a")) {
        Write-Information "Applying extended pmset guards (powernap, standby, autopoweroff, hibernatemode, ttyskeepawake, tcpkeepalive)..."
        foreach ($g in $pmsetGuards) { & sudo pmset -a $g.Key $g.Want 2>$null | Out-Null }
        $changed = $true
    }

    # -- 3g. Hot corners -- neutralize screen-saver / sleep / lock triggers --
    # Dock stores hot-corner actions under wvous-{tl,tr,bl,br}-corner.
    # A drifting mouse during an unattended test can land in a corner
    # and trigger screensaver / display-sleep / lock -- making the UTM
    # window vanish from the CG window list. The dangerous-code map is
    # shared with Assert-ScreenLock (Get-MacDangerousHotCornerMap) so the
    # gate flags exactly the bindings this path neutralizes; safe codes
    # (0=none, Mission Control, Launchpad, ...) are absent and left alone.
    $dangerousCorners = Get-MacDangerousHotCornerMap
    $dockReloadNeeded = $false
    foreach ($corner in @('tl','tr','bl','br')) {
        $key = "wvous-$corner-corner"
        $val = & defaults read com.apple.dock $key 2>$null
        if ($LASTEXITCODE -eq 0) {
            $valTrim = "$val".Trim()
            if ($dangerousCorners.ContainsKey($valTrim)) {
                $action = $dangerousCorners[$valTrim]
                if ($PSCmdlet.ShouldProcess("Hot corner $corner (currently '$action' = $valTrim)", "Set to 0 (none)")) {
                    Write-Information "Neutralizing hot corner '$corner' ($action -> none)..."
                    $cornerCleared = Confirm-MacDefaultWrite -DefaultsArgs @('com.apple.dock', $key) -WriteType '-int' -WriteValue '0' -ExpectRead '0'
                    # Clear the modifier too -- otherwise the corner is
                    # merely hidden behind a modifier a wandering cursor
                    # might hit alongside a stuck Shift.
                    [void](Confirm-MacDefaultWrite -DefaultsArgs @('com.apple.dock', "wvous-$corner-modifier") -WriteType '-int' -WriteValue '0' -ExpectRead '0')
                    if ($cornerCleared) {
                        $dockReloadNeeded = $true
                        $changed = $true
                    }
                }
            }
        }
    }
    if ($dockReloadNeeded) {
        # Dock re-reads these only at launch; kick it so the change
        # takes effect immediately (Dock auto-relaunches).
        & killall Dock 2>$null | Out-Null
    } else {
        Write-Information "Hot corners: no dangerous bindings (screen-saver / sleep / lock) detected."
    }

    # -- 3h. App Nap suppression for UTM.app ------------------------------
    # macOS App Nap throttles background apps that haven't received
    # input. For UTM this can freeze the UI thread, stop updating the
    # window server, and drop the window from CGWindowListCopyWindowInfo
    # -- exactly the "UTM window for '<vm>' not found" symptom even when
    # the VM is fine. Opt UTM out unconditionally.
    $utmBundleId = 'com.utmapp.UTM'
    $napState = & defaults read $utmBundleId NSAppSleepDisabled 2>$null
    $napAlreadyOff = ($LASTEXITCODE -eq 0 -and "$napState".Trim() -eq '1')
    if (-not $napAlreadyOff) {
        if ($PSCmdlet.ShouldProcess("App Nap for $utmBundleId", "Disable (NSAppSleepDisabled = YES)")) {
            Write-Information "Disabling App Nap for UTM.app ($utmBundleId)..."
            if (Confirm-MacDefaultWrite -DefaultsArgs @($utmBundleId, 'NSAppSleepDisabled') -WriteType '-bool' -WriteValue 'YES' -ExpectRead '1') {
                $changed = $true
            }
        }
    } else {
        Write-Information "App Nap for UTM.app is already disabled."
    }

    # -- 3i. Clear any stuck ScreenSaverEngine ----------------------------
    # If a prior aborted run left the saver engaged, the engine process
    # may still be running when this script applies settings. Killing
    # is idempotent and harmless when nothing runs; swallow exit codes
    # so "no such process" isn't reported as failure.
    & killall ScreenSaverEngine 2>$null | Out-Null

    # -- 3j. sysadminctl unified screen lock (Ventura+) -------------------
    # `sysadminctl -screenLock` is the modern (macOS 13+) unified control
    # that System Settings > Lock Screen > "Require password after screen
    # saver begins or display is turned off" writes to.
    # CRITICAL: overrides legacy askForPassword / askForPasswordDelay.
    # A machine with idleTime=0, askForPassword=0, and
    # askForPasswordDelay=MAX_INT can still lock after minutes because
    # sysadminctl reports e.g. "screenLock delay is 300 seconds".
    #
    # "off" sets delay to -1 (disabled). sysadminctl requires the user's
    # password (not sudo) because it touches the secure keyring entry
    # backing lock-screen policy. `-password -` reads from stdin -- a
    # second prompt appears after the sudo prompt.
    # Get-MacScreenLockDisabled strips the NSLog prefix and applies the
    # shared "off" test (also used by Assert-ScreenLock's gate) so the
    # apply and assert paths agree on what counts as disabled.
    $slParsed = Get-MacScreenLockDisabled -Raw (& sysadminctl -screenLock status 2>&1 | Select-Object -First 1)
    $slStatus = $slParsed.Status
    if (-not $slParsed.Disabled) {
        if ($wrapperPrimed) {
            Write-Warning "==================================================================="
            Write-Warning " sysadminctl unified screen lock is NOT yet disabled (status:"
            Write-Warning "   $slStatus)"
            Write-Warning ""
            Write-Warning " Run this ONE-TIME command yourself before starting tests:"
            Write-Warning ""
            Write-Warning "   sudo sysadminctl -screenLock off -password -"
            Write-Warning ""
            Write-Warning " sysadminctl asks for your account password from stdin in addition"
            Write-Warning " to sudo's prompt. State is persistent across reboots, so this"
            Write-Warning " warning will not reappear once it succeeds."
            Write-Warning "==================================================================="
        } elseif ($PSCmdlet.ShouldProcess("sysadminctl $slStatus", "Disable (sysadminctl -screenLock off)")) {
            Write-Information "Disabling sysadminctl unified screen lock (you may be prompted for your account password)..."
            # 2>&1 so "password:" prompt and diagnostics both land on
            # the tty where the user expects them.
            & sudo sysadminctl -screenLock off -password - 2>&1
            # Re-check: if we couldn't disable (wrong password, policy
            # override, MDM), surface the state so the user knows legacy
            # keys won't save them.
            $slAfterParsed = Get-MacScreenLockDisabled -Raw (& sysadminctl -screenLock status 2>&1 | Select-Object -First 1)
            if ($slAfterParsed.Disabled) {
                Write-Information "sysadminctl screen lock is now disabled."
                $changed = $true
            } else {
                Write-Warning "sysadminctl screen lock is STILL active after attempt: $($slAfterParsed.Status)"
                Write-Warning "  If this Mac is MDM-managed, a Configuration Profile may be"
                Write-Warning "  enforcing screen lock; check: profiles list ; profiles show -type configuration"
            }
        }
    } else {
        Write-Information "sysadminctl unified screen lock is already disabled."
    }

    # -- 3k. Auto-logout after inactivity (Security -> Advanced) -----------
    # `com.apple.autologout.AutoLogOutDelay` (system-level) is the
    # "Log out after N minutes of inactivity" toggle in Lock Screen /
    # Security. macOS kicks the user back to loginwindow after the
    # delay -- indistinguishable from a lock ("demands password"), but
    # no screen-saver / pmset key we control would prevent it. System
    # level (/Library/Preferences/.GlobalPreferences); the WRITE
    # requires sudo, but the plist is mode 644 so the READ does not --
    # using `sudo defaults read` here would cause an unnecessary sudo
    # call, defeating the install/macos.utm.sh "sudo prelude" that
    # pre-applies this value to keep the pwsh phase prompt-free.
    $autoLogoutDelay = & defaults read /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay 2>$null
    $autoLogoutOff = ($LASTEXITCODE -ne 0 -or "$autoLogoutDelay".Trim() -eq "0")
    if (-not $autoLogoutOff) {
        if ($wrapperPrimed) {
            Write-Warning "AutoLogOutDelay is '$($autoLogoutDelay.Trim())' (expected 0). Run 'sudo defaults write /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay -int 0' to fix."
        } elseif ($PSCmdlet.ShouldProcess("Auto-logout delay (currently $($autoLogoutDelay.Trim())s)", "Set to 0 (disabled)")) {
            Write-Information "Disabling auto-logout after inactivity..."
            & sudo defaults write /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay -int 0
            $changed = $true
        }
    } else {
        Write-Information "Auto-logout after inactivity is already disabled."
    }

    # -- 3l. Spaces "switch to a Space with open windows" toggle ----------
    # When the harness calls `tell application "UTM" to activate` (the
    # AVF-guest keystroke fallback in Send-KeyUTM / Send-TextUTM), macOS
    # by default yanks the operator across Spaces to UTM's window -- which
    # is hostile when the operator has switched to VS Code on a different
    # Space to investigate something while a long test runs.
    # AppleSpacesSwitchOnActivation=false keeps the activation on the
    # current Space; UTM still becomes frontmost (so keystrokes route to
    # it), but the operator's view stays put. Dock must be restarted for
    # the change to take effect.
    $spacesAutoSwitch = & defaults read NSGlobalDomain AppleSpacesSwitchOnActivation 2>$null
    $spacesAutoSwitchOff = ($LASTEXITCODE -eq 0 -and "$spacesAutoSwitch".Trim() -eq "0")
    if (-not $spacesAutoSwitchOff) {
        if ($PSCmdlet.ShouldProcess("AppleSpacesSwitchOnActivation (currently $($spacesAutoSwitch))", "Set to false (don't switch Spaces on app activation)")) {
            Write-Information "Disabling 'switch to a Space with open windows' on app activation..."
            if (Confirm-MacDefaultWrite -DefaultsArgs @('NSGlobalDomain', 'AppleSpacesSwitchOnActivation') -WriteType '-bool' -WriteValue 'false' -ExpectRead '0') {
                & killall Dock 2>$null | Out-Null
                $changed = $true
            }
        }
    } else {
        Write-Information "Spaces auto-switch on app activation is already disabled."
    }

    # Pinning UTM.app to "All Desktops" (right-click Dock icon -> Options ->
    # Assign To -> All Desktops) is the other half of making cross-Space
    # debugging seamless -- but it's stored deep inside com.apple.spaces
    # app-bindings plist and is fragile to script. Left as a one-time
    # manual step; flagged here so the operator knows it exists.
    Write-Information "Tip (manual): right-click UTM in the Dock -> Options -> Assign To -> All Desktops."
    Write-Information "      Combined with the AppleSpacesSwitchOnActivation toggle above, this lets"
    Write-Information "      Invoke-TestRunner activate UTM without yanking the operator off VS Code."

    # -- 3m. Managed Configuration Profile detection (MDM override) -------
    # If MDM-managed, a Configuration Profile can enforce screen lock /
    # password delay / auto-logout at a level that OVERRIDES everything
    # above -- `defaults write` is silently ignored or reverted on next
    # mcxrefresh. We can't bypass a profile; warn the user so they
    # don't chase a ghost.
    try {
        $profOutput = & profiles list 2>&1
        $hasProfiles = ($LASTEXITCODE -eq 0 -and "$profOutput" -notmatch 'no configuration profiles')
        if ($hasProfiles) {
            Write-Warning "==================================================================="
            Write-Warning " Configuration Profile(s) detected on this Mac. If any profile"
            Write-Warning " enforces screen-lock / password / auto-logout policy, the settings"
            Write-Warning " applied by this script will be overridden. Inspect with:"
            Write-Warning "   profiles list"
            Write-Warning "   profiles show -type configuration"
            Write-Warning " Policy keys to look for: screenSaverPasswordDelay, askForPassword,"
            Write-Warning " loginWindowIdleTime, AutoLogOutDelay, forceLockOnSleep."
            Write-Warning "==================================================================="
        }
    } catch {
        Write-Debug "profiles list failed: $_"
    }

    # -- 4. Accessibility -- trigger the system prompt if not granted -------
    try {
        $jxa = "ObjC.import('ApplicationServices'); $.AXIsProcessTrusted();"
        $axResult = & osascript -l JavaScript -e $jxa 2>&1
        if ("$axResult" -eq "true") {
            Write-Information "Accessibility permission is already granted."
        } else {
            Write-Information "Requesting Accessibility permission (a system dialog should appear)..."
            # AXIsProcessTrustedWithOptions + kAXTrustedCheckOptionPrompt=true
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
            Write-Information "  -> Grant access in the dialog, then re-run the test."
        }
    } catch {
        Write-Debug "Accessibility prompt failed: $_"
        Write-Warning "Could not check Accessibility status. Grant it manually in System Settings."
    }

    # -- 5. Screen Recording -- preflight + first-run prompt ----------------
    # Separate TCC bucket from Accessibility. Needed so
    # CGWindowListCopyWindowInfo returns window titles (the harness matches
    # UTM's per-VM window by title) and so `screencapture -l <windowId>`
    # works. Without it, tapOn loops on "UTM window for
    # <vm> not found". CGRequestScreenCaptureAccess prompts only on the
    # FIRST call per process; subsequent denied states need the user to
    # toggle System Settings manually and relaunch the terminal.
    #
    # ObjC.bindFunction is REQUIRED on some macOS releases -- without it,
    # $.CGPreflightScreenCaptureAccess() returns `undefined` (read as
    # "not granted") even when the grant is in place, misreporting state.
    try {
        $jxa = @"
ObjC.import('CoreGraphics');
try { ObjC.bindFunction('CGPreflightScreenCaptureAccess', ['bool', []]); } catch (e) {}
try { ObjC.bindFunction('CGRequestScreenCaptureAccess',  ['bool', []]); } catch (e) {}
var granted = $.CGPreflightScreenCaptureAccess();
if (!granted) { $.CGRequestScreenCaptureAccess(); }
(granted === true || granted === 1) ? 'true' : 'false'
"@
        $srResult = (& osascript -l JavaScript -e $jxa 2>&1 | Out-String).Trim()
        if ($srResult -eq 'true') {
            Write-Information "Screen Recording permission is already granted."
        } else {
            Write-Information "Requesting Screen Recording permission (a system dialog may appear)..."
            Write-Information "  -> If no dialog appears, macOS already remembered a previous denial."
            Write-Information "    Open System Settings > Privacy & Security > Screen Recording,"
            Write-Information "    enable your terminal app (Terminal.app, iTerm2, Ghostty, etc.),"
            Write-Information "    then FULLY QUIT and relaunch it before re-running the test."
        }
    } catch {
        Write-Debug "Screen Recording prompt failed: $_"
        Write-Warning "Could not check Screen Recording status. Grant it manually in System Settings."
    }

    if ($changed) {
        Write-Information ""
        Write-Information "Settings updated. Re-run Assert-MacHostConditionSet to verify:"
        Write-Information "  Assert-MacHostConditionSet -HostType 'host.macos.utm'"
    }
}

function Assert-Accessibility {
    <#
    .SYNOPSIS
    macOS: verify the terminal has Accessibility permission (needed
    for AXUIElementPostKeyboardEvent). Returns $true if granted (or
    not on macOS). Prints setup instructions and returns $false on
    missing permission.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    # AXIsProcessTrusted() true when the process has Accessibility access.
    try {
        $jxa = "ObjC.import('ApplicationServices'); $.AXIsProcessTrusted();"
        $result = & osascript -l JavaScript -e $jxa 2>&1
        if ("$result" -eq "true") { return $true }
    } catch {
        Write-Debug "Accessibility check failed: $_"
    }

    Write-Warning "==================================================================="
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
    Write-Warning "==================================================================="
    return $false
}

function Assert-ScreenRecording {
    <#
    .SYNOPSIS
    macOS: verify the terminal has Screen Recording permission (needed
    for CGWindowListCopyWindowInfo to include window titles -- the
    harness matches UTM's per-VM window by title -- and for
    `screencapture -l <windowId>`). Returns $true if granted (or not on
    macOS). Prints setup instructions and returns $false on missing
    permission.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    # Primary check: CGPreflightScreenCaptureAccess is the canonical
    # TCC query -- it reads the Screen Recording grant directly and is
    # the same call the OS uses internally. JavaScriptCore's $. bridge
    # needs a registered signature for C functions not shipped in its
    # built-in header set; AX* functions ship with signatures but
    # CGPreflight/CGRequest do not in every release. ObjC.bindFunction
    # registers the signature explicitly so the return type is correct.
    $jxaPre = @"
ObjC.import('CoreGraphics');
try { ObjC.bindFunction('CGPreflightScreenCaptureAccess', ['bool', []]); } catch (e) {}
var r = $.CGPreflightScreenCaptureAccess();
(r === true || r === 1) ? 'true' : 'false'
"@
    try {
        $result = (& osascript -l JavaScript -e $jxaPre 2>&1 | Out-String).Trim()
        Write-Debug "Assert-ScreenRecording: CGPreflight returned '$result'"
        if ($result -eq 'true') { return $true }
    } catch {
        Write-Debug "CGPreflight check failed: $_"
    }

    # Fallback: enumerate on-screen windows and require at least TWO
    # foreign windows with non-empty kCGWindowName. Used only when
    # CGPreflight is unavailable/broken (old macOS, custom JXA build).
    # Requiring two owners avoids false positives from a single
    # permissive-NSWindowSharingType window that would otherwise claim
    # the grant is in place when it isn't.
    $jxa = @"
ObjC.import('CoreGraphics');
var list = $.CGWindowListCopyWindowInfo((1 << 0) | (1 << 4), 0);
if (!list) { 'false' } else {
    var n = $.CFArrayGetCount(list);
    var nameKey  = $.CFStringCreateWithCString(null, 'kCGWindowName', 0);
    var ownerKey = $.CFStringCreateWithCString(null, 'kCGWindowOwnerName', 0);
    var owners = {};
    for (var i = 0; i < n; i++) {
        var d = $.CFArrayGetValueAtIndex(list, i);
        var nm = $.CFDictionaryGetValue(d, nameKey);
        if (!nm || $.CFStringGetLength(nm) === 0) continue;
        var ow = $.CFDictionaryGetValue(d, ownerKey);
        var owStr = ow ? ObjC.unwrap(ow) : '';
        if (owStr) owners[owStr] = true;
    }
    (Object.keys(owners).length >= 2) ? 'true' : 'false'
}
"@
    try {
        $result = (& osascript -l JavaScript -e $jxa 2>&1 | Out-String).Trim()
        Write-Debug "Assert-ScreenRecording: enumeration fallback returned '$result'"
        if ($result -eq 'true') { return $true }
    } catch {
        Write-Debug "Window-title enumeration failed: $_"
    }

    Write-Warning "==================================================================="
    Write-Warning " Screen Recording permission does NOT appear granted for this"
    Write-Warning " terminal. The harness needs it to enumerate UTM's windows --"
    Write-Warning " CGWindowList only returns titles to processes with this"
    Write-Warning " permission -- and to capture a specific VM window via"
    Write-Warning " screencapture -l <windowId>. Without it, tapOn"
    Write-Warning " loops on 'UTM window for <vm> not found'."
    Write-Warning ""
    Write-Warning " To fix:"
    Write-Warning "   1. Open System Settings > Privacy & Security > Screen Recording"
    Write-Warning "   2. Click + and add your terminal app"
    Write-Warning "      (Terminal.app, iTerm2, Ghostty, or whichever you use)"
    Write-Warning "   3. Ensure the toggle is ON"
    Write-Warning "   4. FULLY QUIT the terminal (Cmd-Q or killall) and relaunch it"
    Write-Warning "      -- macOS will NOT honor the grant in the running process."
    Write-Warning "   5. Re-run the test harness from the new terminal."
    Write-Warning ""
    Write-Warning " If the toggle IS on and you already relaunched the terminal,"
    Write-Warning " run this diagnostic and report the output:"
    Write-Warning ""
    Write-Warning "   osascript -l JavaScript -e 'ObjC.import(\"CoreGraphics\");"
    Write-Warning "     ObjC.bindFunction(\"CGPreflightScreenCaptureAccess\","
    Write-Warning "     [\"bool\",[]]); `$.CGPreflightScreenCaptureAccess();'"
    Write-Warning ""
    Write-Warning " If that prints 'true', override this check with"
    Write-Warning "   `$Env:YURUNA_SKIP_SCREEN_RECORDING_CHECK = '1'"
    Write-Warning " and re-run -- then please file an issue with the diagnostic"
    Write-Warning " output so the probe can be tuned for your macOS version."
    Write-Warning "==================================================================="

    if ($env:YURUNA_SKIP_SCREEN_RECORDING_CHECK -eq '1') {
        Write-Warning "YURUNA_SKIP_SCREEN_RECORDING_CHECK=1 -- proceeding anyway."
        return $true
    }
    return $false
}

function Assert-MacHostConditionSet {
    <#
    .SYNOPSIS
    Single gate for macOS prerequisites: Accessibility + Screen Recording
    permissions and screen lock / display sleep settings. Returns $true
    on non-macOS or when all conditions pass; $false with diagnostics on
    failure. Invoke once at startup and again before each test cycle.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    if (-not (Assert-Accessibility    -HostType $HostType)) { return $false }
    if (-not (Assert-ScreenRecording  -HostType $HostType)) { return $false }
    if (-not (Assert-ScreenLock       -HostType $HostType)) { return $false }

    return $true
}

function Test-MacHostMinimum {
    <#
    .SYNOPSIS
        macOS UTM quick-check for [Test-HostRequirement] (UTM.app
        installed + utmctl on PATH). Emits actionable warnings on
        failure and returns $false; emits nothing and returns $true
        when both conditions are met.
    .DESCRIPTION
        Lighter than Assert-MacHostConditionSet (which also gates on
        Accessibility / Screen Recording TCC grants + display-sleep
        / screen-lock) -- this exists for one-off operator helpers
        (Remove-OrphanedVMFiles.ps1 etc.) where the TCC + screen
        checks would prompt unnecessarily during interactive
        maintenance.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $ok = $true
    if (-not (Test-Path '/Applications/UTM.app')) {
        Write-Warning "/Applications/UTM.app not found. Install UTM from https://mac.getutm.app."
        $ok = $false
    }
    if (-not (Get-Command utmctl -ErrorAction SilentlyContinue)) {
        Write-Warning "utmctl not found on PATH. The UTM.app bundle ships it at /Applications/UTM.app/Contents/MacOS/utmctl -- symlink it into /usr/local/bin or rerun host/macos.utm/Enable-TestAutomation.ps1."
        $ok = $false
    }
    return $ok
}

Export-ModuleMember -Function Assert-ScreenLock, Initialize-SudoCache, Set-MacHostConditionSet, Assert-Accessibility, Assert-ScreenRecording, Assert-MacHostConditionSet, Test-MacHostMinimum
