<#PSScriptInfo
.VERSION 2026.09.08
.GUID 42ed1667-e5c7-4bea-b28b-0e6c1706de72
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

# Test-YurunaCanPrompt: whether a question asked from this process can reach a
# person. One block here needs an interactive account password on top of root,
# and that is a different question from "can this process elevate".
Import-Module (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'automation' -AdditionalChildPath 'Yuruna.Common.psm1') -Global -Force -DisableNameChecking

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

    A key absent from `pmset -g custom` normally counts as "this macOS no longer
    surfaces it under that name" and is left alone. AlwaysApply marks the keys
    where absence proves nothing instead -- Set- writes those unconditionally.

    AbsentEquivalent is the value whose BEHAVIOR equals the key not being set,
    and only AlwaysApply keys need one: they are the keys written on a host that
    had no prior value, and pmset has no delete, so without it Disable has
    nothing to put back and the guard outlives the automation that added it.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @(
        # AlwaysApply: macOS does not list disablesleep in `pmset -g custom`
        # until it has been written at least once, so on a Mac that never had
        # it set -- the exact host that needs it -- absence would otherwise read
        # as "already 1" and the write would never happen. With disablesleep 0 a
        # MacBook suspends the moment its lid closes, taking every running guest
        # and the rest of the cycle down with it.
        # AbsentEquivalent 0: a Mac that has never had disablesleep written
        # behaves exactly as one holding 0 -- it suspends on lid close -- so 0
        # is what returns the host to where it was, not a guess at a default.
        @{ Key = 'disablesleep'  ; Want = 1 ; AlwaysApply = $true ; AbsentEquivalent = 0 }
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

function Get-MacPmsetGuardPending {
    <#
    .SYNOPSIS
    The guards that still need `sudo pmset -a <key> <want>`, decided from the
    output of `pmset -g custom`.
    .DESCRIPTION
    Kept as a pure function of that output so the rule can be exercised without
    a Mac (Test.HostConditionMacPmset.Tests.ps1) -- the alternative is a rule
    that only ever runs on the one host it is supposed to protect.

    A key present with the wrong value is pending. A key macOS does not list is
    NOT pending: absence means this release renamed or dropped it, and writing a
    name pmset no longer knows buys nothing but a sudo prompt. AlwaysApply keys
    invert that -- for those, absence carries no information at all (see
    Get-MacPmsetGuardList), so they are pending until they read back correct.
    .PARAMETER PmsetCustom
    The lines of `pmset -g custom`. Empty (pmset absent or failed) leaves every
    non-AlwaysApply guard alone rather than guessing.
    .PARAMETER Guard
    Guard entries to evaluate; defaults to the canonical Get-MacPmsetGuardList.
    .OUTPUTS
    The subset of Guard needing a write, in list order.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string[]]$PmsetCustom,
        [object[]]$Guard
    )
    if (-not $Guard) { $Guard = Get-MacPmsetGuardList }
    $pending = @()
    foreach ($g in $Guard) {
        # Every block pmset prints (Battery Power / AC Power / UPS Power) counts,
        # not just the first one: the writes go out with `-a`, so a key that is
        # right on battery and wrong on AC is drift that still needs re-applying.
        $lines = @($PmsetCustom | Select-String -Pattern ('^\s*' + [regex]::Escape($g.Key) + '\s+(\d+)'))
        if ($lines.Count -gt 0) {
            if (@($lines | Where-Object { [int]$_.Matches[0].Groups[1].Value -ne $g.Want }).Count -gt 0) { $pending += $g }
        } elseif ($g.AlwaysApply) {
            $pending += $g
        }
    }
    return @($pending)
}

function Get-MacPmsetKeyValue {
    <#
    .SYNOPSIS
    Every value `pmset -g custom` reports for one key, in the order the blocks
    are printed.
    .DESCRIPTION
    `pmset -g custom` prints one block per power source this Mac has (Battery
    Power, AC Power, UPS Power) and the same key carries an INDEPENDENT value in
    each. A first-match read therefore answers for whichever block macOS happens
    to print first -- a laptop whose battery block reads 0 and whose AC block
    reads 10 looks compliant to the reader and blanks the display the moment it
    is plugged in. Callers that decide anything about a key have to see every
    value it holds, which is what this returns.
    .PARAMETER PmsetCustom
    The lines of `pmset -g custom`.
    .PARAMETER Key
    The pmset key to read, e.g. 'displaysleep'.
    .OUTPUTS
    [string[]] the values found, empty when this macOS does not list the key.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string[]]$PmsetCustom,
        [Parameter(Mandatory)][string]$Key
    )
    # Cast, not a bare @(): the pipeline yields Object[], and callers compare
    # each element as a number, so the declared [string[]] has to be what
    # actually comes back rather than a promise the return value breaks.
    return [string[]]@($PmsetCustom |
        Select-String -Pattern ('^\s*' + [regex]::Escape($Key) + '\s+(\d+)') |
        ForEach-Object { $_.Matches[0].Groups[1].Value })
}

function Get-MacSleepGuardList {
    <#
    .SYNOPSIS
    The system-sleep guards (key + wanted value) shared by
    Set-MacHostConditionSet and Assert-ScreenLock, so the applied set is exactly
    the asserted set.
    .DESCRIPTION
    Separate from Get-MacPmsetGuardList because the two are captured
    differently: Get-MacPreAutomationState records these per power source
    (`pmset/<scope>/<key>`, since `-c` and `-b` hold different values and a Mac
    restored to one value on both has lost its battery policy), while the
    extended guards are captured once from the AC block. A key listed in both
    places would be captured twice and restored from the wrong half.

    Each key stands on its own: `sleep` and `disksleep` drift independently, so
    they are evaluated and written independently. Deciding both from a single
    read of `sleep` leaves a host with sleep=0 and disksleep=10 reporting
    "already Never" on every apply while the gate refuses it on every cycle --
    a loop no amount of re-running the setup script can break.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @(
        @{ Key = 'sleep'     ; Want = 0 }
        @{ Key = 'disksleep' ; Want = 0 }
    )
}

function Get-MacDefaultsCommandArgument {
    <#
    .SYNOPSIS
    Assemble a complete `defaults` argument vector with the host selector ahead
    of the verb.
    .DESCRIPTION
    `defaults` takes its host selector BEFORE the verb --
    `defaults -currentHost write <domain> <key> -int 0`. Emitted verb-first it
    binds '-currentHost' as the DOMAIN and then rejects the type flag
    ("Unexpected argument -int; leaving defaults unchanged"), so the write
    exits non-zero having changed nothing and the matching read reports the key
    absent. Nothing about that is visible in a read-back of the intended
    domain, which is why the failure survives as a warning that no amount of
    re-running can clear.

    The knob tables in this repo carry the selector inside the domain+key
    vector because that is how the pair reads at the call site (capture, apply
    and restore all name the same knob). Splitting it back out has to happen in
    one place, or the three sites drift apart again.
    .PARAMETER Verb
    read / write / delete.
    .PARAMETER DefaultsArgs
    Domain + key, optionally led by '-currentHost' or '-host <name>'.
    .PARAMETER Trailing
    Anything that follows the key -- the type flag and the value on a write.
    .OUTPUTS
    [string[]] the full argv for `defaults`.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][ValidateSet('read', 'write', 'delete')][string]$Verb,
        [string[]]$DefaultsArgs = @(),
        [string[]]$Trailing = @()
    )
    $selector = @()
    $rest = @()
    $i = 0
    while ($i -lt $DefaultsArgs.Count) {
        $token = "$($DefaultsArgs[$i])"
        if ($token -eq '-currentHost') { $selector += $token; $i++; continue }
        # -host takes the host name as a separate token; both belong ahead of
        # the verb, and splitting them would produce `defaults -host read <name>`.
        if ($token -eq '-host' -and ($i + 1) -lt $DefaultsArgs.Count) {
            $selector += $token
            $selector += "$($DefaultsArgs[$i + 1])"
            $i += 2
            continue
        }
        break
    }
    for (; $i -lt $DefaultsArgs.Count; $i++) { $rest += "$($DefaultsArgs[$i])" }
    return [string[]]@($selector + @($Verb) + $rest + @($Trailing))
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
    The arguments that select the domain + key -- e.g.
    @('com.apple.dock','wvous-tl-corner') or
    @('-currentHost','com.apple.screensaver','askForPasswordDelay'). A leading
    '-currentHost' / '-host <name>' selector is re-emitted ahead of the verb by
    Get-MacDefaultsCommandArgument, which is where `defaults` requires it.
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
    & defaults @(Get-MacDefaultsCommandArgument -Verb 'write' -DefaultsArgs $DefaultsArgs -Trailing @($WriteType, $WriteValue)) 2>$null | Out-Null
    $writeExit = $LASTEXITCODE
    $readBack = & defaults @(Get-MacDefaultsCommandArgument -Verb 'read' -DefaultsArgs $DefaultsArgs) 2>$null
    $readOk = ($LASTEXITCODE -eq 0)
    if ($readOk -and "$readBack".Trim() -eq $ExpectRead) { return $true }
    $actual = if ($readOk) { "$readBack".Trim() } else { '<unset>' }
    # The write's own exit code is part of the diagnosis: a rejected argument
    # vector and an MDM-reverted value both read back wrong, and only the code
    # separates "defaults refused the command" from "defaults accepted it and
    # something else put the value back".
    $why = if ($writeExit -ne 0) { " The write itself exited $writeExit." } else { ' The domain may be locked or MDM-managed.' }
    Write-Warning ("defaults write {0} {1} {2} did not take (read back '{3}', wanted '{4}').{5}" -f ($DefaultsArgs -join ' '), $WriteType, $WriteValue, $actual, $ExpectRead, $why)
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

function Get-MacScreenLockIssue {
    <#
    .SYNOPSIS
    Every screen-lock / sleep setting on THIS Mac that would blank the VM
    display mid-cycle, as one operator-readable line each.
    .DESCRIPTION
    The probing half of Assert-ScreenLock, split out so the same findings can be
    reported by a health report that describes a host without refusing it and by
    the gate that refuses it. Two probes worded differently for the same setting
    is the failure an operator pays for most: the report passes, the gate stops
    the cycle, and nothing they read tells them which of the two is stale.
    .OUTPUTS
    [string[]] one line per issue; empty when the host is ready.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $issues = @()

    # 1. Display sleep idle time (pmset -g custom -> displaysleep).
    #    0 = never sleep (good); > 0 means display will blank. Every power
    #    block counts -- see Get-MacPmsetKeyValue.
    try {
        $displayValues = @(Get-MacPmsetKeyValue -PmsetCustom (& pmset -g custom 2>$null) -Key 'displaysleep' |
            Where-Object { [int]$_ -ne 0 })
        if ($displayValues.Count -gt 0) {
            $issues += "Display sleep is set to $(($displayValues | Sort-Object -Unique) -join '/') minute(s)."
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

    # 5b. UTM outlives its last window. Without this, closing the last
    #     window terminates UTM, and UTM's termination path saves the
    #     state of every running VM -- the service VMs the cycle depends
    #     on come back `suspended` instead of running.
    try {
        $keepRunning = & defaults read com.utmapp.UTM KeepRunningAfterLastWindowClosed 2>$null
        if ($LASTEXITCODE -ne 0 -or "$keepRunning".Trim() -ne '1') {
            $issues += "UTM.app quits with its last window (com.utmapp.UTM KeepRunningAfterLastWindowClosed not set to 1); closing a VM window would suspend every running VM."
        }
    } catch {
        Write-Debug "UTM last-window-closed check failed: $_"
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

    # 8. System sleep + disk sleep -> Never. Display sleep alone (the "Display sleep -> Never" region) isn't
    #    enough: a system/disk-sleep wake re-locks the screen on Ventura+
    #    regardless of screensaver settings. Set-MacHostConditionSet disables
    #    both, so the gate must re-verify them.
    # 9. Extended pmset guards (Power Nap, standby, autopoweroff, hibernate, ...)
    #    that Set-MacHostConditionSet applies. The gate re-verifies them from the
    #    same Get-MacPmsetGuardList Set- applies, so the asserted set is exactly
    #    the applied set and a drifted host fails here instead of blanking UTM
    #    mid-run. A key absent from 'pmset -g custom' (macOS-version dependent) is
    #    skipped here even when Set- force-writes it (AlwaysApply): a Mac with no
    #    lid never surfaces disablesleep at all, and failing the gate on a key
    #    that host cannot have would block a perfectly good desktop test host.
    #    A laptop that drifts back to 0 does list the key, so it still fails here.
    try {
        $pmCustom = & pmset -g custom 2>$null
        foreach ($g in (Get-MacSleepGuardList)) {
            # Per key, and across every power block: sleep and disksleep drift
            # independently, and so do the AC and battery copies of each.
            $bad = @(Get-MacPmsetKeyValue -PmsetCustom $pmCustom -Key $g.Key |
                Where-Object { [int]$_ -ne $g.Want })
            if ($bad.Count -gt 0) {
                $issues += "$($g.Key) is set to $(($bad | Sort-Object -Unique) -join '/') minute(s) -- a wake re-locks the screen (should be 0 / Never)."
            }
        }
        foreach ($g in (Get-MacPmsetGuardList)) {
            $gBad = @(Get-MacPmsetKeyValue -PmsetCustom $pmCustom -Key $g.Key |
                Where-Object { [int]$_ -ne $g.Want })
            if ($gBad.Count -gt 0) {
                $issues += "pmset $($g.Key) is $(($gBad | Sort-Object -Unique) -join '/') (should be $($g.Want))."
            }
        }
    } catch {
        Write-Debug "pmset system-sleep / extended-guard check failed: $_"
    }

    return [string[]]@($issues)
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

    $issues = @(Get-MacScreenLockIssue)
    if ($issues.Count -eq 0) { return $true }

    Write-Warning "========"
    Write-Warning " Screen lock / display sleep settings will blank the VM display."
    Write-Warning ""
    foreach ($issue in $issues) {
        Write-Warning "  * $issue"
    }
    Write-Warning ""
    Write-Warning " When the display blanks, UTM screen captures return a black"
    Write-Warning " image and OCR-based waitForText steps will time out."
    Write-Warning ""
    # The host-neutral entry point, not host/macos.utm/: it detects the host and
    # runs that host's script, so the same line stays correct on every host and
    # an operator who has it in their notes cannot carry a path that only worked
    # on the machine they first read it from.
    Write-Warning " Quick fix -- run from the repo root:"
    Write-Warning "   pwsh test/lab/Enable-TestAutomation.ps1"
    Write-Warning ""
    Write-Warning " Or manually in System Settings:"
    Write-Warning "   1. Displays > Advanced > Prevent automatic sleeping when"
    Write-Warning "      the display is off  -> ON"
    Write-Warning "   2. Lock Screen > Start Screen Saver when inactive -> Never"
    Write-Warning "   3. Lock Screen > Require password after screen saver -> OFF"
    Write-Warning "   4. Energy > Turn display off -> Never  (or run:"
    Write-Warning "        sudo pmset -c displaysleep 0"
    Write-Warning "        sudo pmset -b displaysleep 0 )"
    Write-Warning "========"
    return $false
}

function Get-MacDisplayScaleProfile {
    <#
    .SYNOPSIS
    The raw system_profiler SPDisplaysDataType JSON for this Mac.
    .DESCRIPTION
    The reading half of Get-MacDisplayScaleIssue.

    The JSON form rather than the plain-text one: the text renderer prints
    no logical-point line for a built-in Apple panel and labels the panel's
    own pixel grid "Resolution", so a Mac rendering into a larger
    framebuffer reads as though it were not scaled at all.

    Bounded twice. system_profiler's own -timeout defaults to three minutes,
    and a gate that runs before every cycle cannot wait that long on a
    window server that has stopped answering.
    .PARAMETER TimeoutSeconds
    How long system_profiler may take. The process is killed a few seconds
    after that regardless.
    .OUTPUTS
    [string] the JSON text, or $null when the host is not a Mac, the binary
    is absent, or the probe did not complete.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$TimeoutSeconds = 15)

    if (-not $IsMacOS) { return $null }
    $exe = '/usr/sbin/system_profiler'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $null }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $exe
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    foreach ($a in @('-json', '-detailLevel', 'mini', '-timeout', "$TimeoutSeconds", 'SPDisplaysDataType')) {
        $null = $psi.ArgumentList.Add($a)
    }

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        # Drain before waiting: a synchronous read paired with WaitForExit
        # deadlocks as soon as the output fills the pipe buffer.
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $null   = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(($TimeoutSeconds + 5) * 1000)) {
            try { $proc.Kill($true) } catch { Write-Debug "system_profiler kill failed: $_" }
            return $null
        }
        return $stdout.GetAwaiter().GetResult()
    } catch {
        Write-Debug "system_profiler probe failed: $_"
        return $null
    } finally {
        if ($proc) { $proc.Dispose() }
    }
}

function Get-MacDisplayScaleIssue {
    <#
    .SYNOPSIS
    Whether this Mac's main display carries enough pixels per glyph for the
    OCR pipeline, decided from the system_profiler JSON.
    .DESCRIPTION
    A pure function of that text, so the rule can be exercised without a Mac.

    Reports only what the capture path can actually be hurt by. screencapture
    reads the window backing store, which is upstream of the GPU pass that
    fits the framebuffer to the panel, so a display rendering 3420x2224 onto
    a 2560x1664 panel still hands over two pixels per point and its glyphs
    reach OCR intact -- the captures docs/ocr.md describes are 2x their
    logical size. A scaled "More Space" mode is therefore NOT reported.
    What halves the glyph pixels is a main display with no HiDPI mode at
    all, where one pixel per point is all there is.

    A future capture path that read the panel rather than the backing store
    would invalidate that reasoning, which is why it is recorded here rather
    than left to be re-derived.
    .PARAMETER Json
    The text from Get-MacDisplayScaleProfile.
    .OUTPUTS
    [pscustomobject] with Status ('Clean', 'Issue' or 'Unknown'), Issue
    ([string[]], one line per finding) and Detail (one sentence).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][AllowEmptyString()][string]$Json)

    $unknown = {
        param([string]$Why)
        [pscustomobject]@{ Status = 'Unknown'; Issue = @(); Detail = $Why }
    }

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return & $unknown 'system_profiler returned nothing this check could read, so display scaling was not assessed.'
    }
    $doc = $null
    try { $doc = $Json | ConvertFrom-Json -ErrorAction Stop } catch { $doc = $null }
    if ($null -eq $doc -or -not $doc.PSObject.Properties['SPDisplaysDataType']) {
        return & $unknown 'system_profiler returned nothing this check could read, so display scaling was not assessed.'
    }

    $parseWH = {
        param($text)
        if ($null -eq $text) { return $null }
        $m = [regex]::Match([string]$text, '(\d+)\s*x\s*(\d+)')
        if (-not $m.Success) { return $null }
        [pscustomobject]@{ W = [int]$m.Groups[1].Value; H = [int]$m.Groups[2].Value }
    }

    $displays = New-Object System.Collections.Generic.List[object]
    foreach ($gpu in @($doc.SPDisplaysDataType)) {
        if ($null -eq $gpu -or -not $gpu.PSObject.Properties['spdisplays_ndrvs']) { continue }
        foreach ($d in @($gpu.spdisplays_ndrvs)) {
            if ($null -eq $d) { continue }
            $read = { param($n) if ($d.PSObject.Properties[$n]) { $d.$n } else { $null } }
            $pt = & $parseWH (& $read '_spdisplays_resolution')
            $px = & $parseWH (& $read '_spdisplays_pixels')
            if (-not $pt -or -not $px -or $pt.W -le 0 -or $px.W -le 0) { continue }
            $displays.Add([pscustomobject]@{
                Name        = & $read '_name'
                IsMain      = ((& $read 'spdisplays_main')   -eq 'spdisplays_yes')
                IsOnline    = ((& $read 'spdisplays_online') -eq 'spdisplays_yes')
                PointWidth  = $pt.W
                PointHeight = $pt.H
                PixelWidth  = $px.W
                PixelHeight = $px.H
            })
        }
    }

    # A report trimmed to its GPU entries is what a Mac returns when no
    # window server is attached to this session. That is an answer about the
    # session, not about the displays, and must not read as "no display has
    # a problem".
    if ($displays.Count -eq 0) {
        return & $unknown 'system_profiler answered with no display list, which is what a Mac reports when no window server is attached to this session. Display scaling was not assessed.'
    }

    $target = @($displays | Where-Object { $_.IsMain -and $_.IsOnline }) | Select-Object -First 1
    if (-not $target) { $target = @($displays | Where-Object { $_.IsOnline }) | Select-Object -First 1 }
    if (-not $target) {
        return & $unknown 'system_profiler reported displays but none of them online, so display scaling was not assessed.'
    }

    $backingScale = $target.PixelWidth / $target.PointWidth
    if ($backingScale -lt 2) {
        $name = if ($target.Name) { $target.Name } else { 'the main display' }
        return [pscustomobject]@{
            Status = 'Issue'
            Issue  = @("The main display '$name' has no HiDPI mode: macOS renders $($target.PixelWidth)x$($target.PixelHeight) pixels for $($target.PointWidth)x$($target.PointHeight) points, which is half the pixels per glyph a window capture normally carries.")
            Detail = 'The main display renders one pixel per point.'
        }
    }
    return [pscustomobject]@{
        Status = 'Clean'
        Issue  = @()
        Detail = 'The main display renders two pixels per point.'
    }
}

function Test-MacSudoAvailable {
<#
.SYNOPSIS
    Whether this process can run ONE privileged command right now without a
    password prompt.
.DESCRIPTION
    The only source that can answer is sudo itself. A credential timestamp
    expires on its own clock (~5 minutes by default), a Homebrew cask
    post-install script can invalidate it with `sudo -k`, and an
    /etc/sudoers.d NOPASSWD rule can make elevation available with no
    timestamp at all. No environment variable tracks any of that, so a flag
    exported by whoever started the run answers a different question than the
    one a privileged write needs answered.

    Asking before every privileged block matters because sudo reads its
    password from /dev/tty, not from stdin. A child whose stdout is captured
    to a log and whose stdin is closed can still raise a password prompt on
    the terminal its parent has taken over -- where nothing displays it and
    nothing answers it. Probing first, and issuing every write with -n, turns
    that stall into an immediate answer.

    Cheap enough to call per block: `sudo -n true` neither prompts nor
    refreshes the timestamp.
.OUTPUTS
    [bool] $true when `sudo -n true` succeeds.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    # Pinned locally: a non-zero exit IS the answer this function returns, and
    # with $PSNativeCommandUseErrorActionPreference true a cold timestamp throws
    # instead -- so the probe that exists to keep a host from stalling would
    # itself abort the settings pass on exactly the hosts it was written for.
    $PSNativeCommandUseErrorActionPreference = $false
    if (-not (Get-Command sudo -ErrorAction SilentlyContinue)) { return $false }
    & sudo -n true 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
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

    NEVER prompts when $env:YURUNA_NONINTERACTIVE is '1' (the test runner
    sets it around every inner spawn): it returns $false silently instead.
    On an unattended host a prompt blocks the inherited terminal with
    nobody present to answer, so elevation there has to come from a
    launch-time prime or an /etc/sudoers.d drop-in, never from here.

    Designed to be called at the very top of any PowerShell script /
    function that will make multiple sudo calls in a row.
.PARAMETER Reasons
    One-line descriptions of what the caller will do with sudo. Printed
    inside a fenced box just above the password prompt so the operator
    knows why they are being asked. Empty array prints a generic notice.
.OUTPUTS
    [bool] $true on success (cache is now warm or no elevation needed),
    $false on failure (sudo missing, user canceled, wrong password).
    Never throws -- callers decide whether to proceed.
.EXAMPLE
    if (-not (Initialize-SudoCache -Reasons @('pmset display sleep', 'defaults write /Library/Preferences'))) {
        throw "Cannot proceed without sudo."
    }
#>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'The notice must reach the terminal the operator is watching, immediately above sudo''s own prompt. Every caller wraps this in [void](...), which discards the success stream -- so an information-stream notice is exactly what went missing and left operators facing an unexplained password prompt.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string[]]$Reasons = @()
    )
    # Pinned locally: the warm-cache fast path below decides on the exit code of a
    # `sudo -n true` that is EXPECTED to fail on a cold timestamp, and the cold
    # path is the whole reason this function exists.
    $PSNativeCommandUseErrorActionPreference = $false
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
    # A caller already took this run's ONE authorization and said so
    # (install/<host>.sh, install/setup.ps1). The timestamp is cold anyway --
    # it expired, or a brew cask post-install ran `sudo -k` -- and asking again
    # here would break the "you will be prompted ONCE" promise that caller
    # printed, for elevation this function does not itself need. Return $false
    # silently; every privileged write downstream probes for itself with
    # Test-MacSudoAvailable and reports the exact command to run when it cannot
    # elevate, which is an answer the operator can act on rather than a second
    # password box with no context.
    if ($env:YURUNA_SUDO_PRIMED -eq '1') {
        return $false
    }
    # Unattended: nobody is at the console to type a password. The test runner
    # spawns its inner with the call operator, so the inner inherits the launch
    # terminal -- `sudo -v` here would print its prompt to that terminal and
    # block the whole host until the watchdog killed it, with the status page
    # still showing the previous cycle's green. Decline exactly as the
    # wrapper-primed path does: return $false silently and let the caller
    # either skip the elevated work or fail it with an actionable message.
    # Elevation for an unattended host is a LAUNCH-time concern (or an
    # /etc/sudoers.d drop-in), never a mid-cycle one.
    if ($env:YURUNA_NONINTERACTIVE -eq '1') {
        Write-Verbose 'Initialize-SudoCache: YURUNA_NONINTERACTIVE=1 -- declining to prompt for sudo.'
        return $false
    }
    # Cache cold AND no wrapper context: print the friendly notice, then prompt.
    #
    # Write-Host, not Write-Output: every caller wraps this function as
    # `[void](Initialize-SudoCache ...)`, and that cast discards the whole
    # success stream -- a Write-Output notice would be swallowed, leaving the
    # operator with a bare "[sudo] password for ..." and no explanation. It also
    # keeps the [OutputType([bool])] contract honest: box lines on the success
    # stream make the return an ARRAY, and a non-empty array is always truthy,
    # so `if (-not (Initialize-SudoCache ...))` in test/Test-Config.ps1 would
    # never fire on the cold path.
    Write-Host ""
    Write-Host "  +---------------------------------------------------------------+"
    Write-Host "  | This script needs sudo for:                                   |"
    if ($Reasons.Count -gt 0) {
        foreach ($r in $Reasons) {
            $line = "    * $r"
            if ($line.Length -gt 63) { $line = $line.Substring(0, 60) + '...' }
            Write-Host ("  | {0,-61} |" -f $line)
        }
    } else {
        Write-Host "  |     (host configuration commands)                             |"
    }
    Write-Host "  | You will be prompted for your password ONCE, below.           |"
    Write-Host "  +---------------------------------------------------------------+"
    Write-Host ""
    & sudo -v
    return ($LASTEXITCODE -eq 0)
}

function Invoke-MacPrivilegedSetting {
    <#
    .SYNOPSIS
    Run one privileged host-settings command through `sudo -n`, and report
    whether it took.
    .DESCRIPTION
    -n unconditionally, including in front of an operator. The capability probe
    that admitted this block ran seconds earlier against a timestamp that can
    expire inside the block, and the fallback for an expired one has to be an
    exit code rather than a prompt: sudo reads its password from /dev/tty, so a
    child whose output is captured raises that prompt where nobody can see it
    and waits forever, and an operator who already answered once gets a second
    box with no explanation of what it is for.

    Native output is consumed here rather than left on the success stream: the
    caller returns a count, and stray `pmset` chatter merged into that would
    turn an [int] into an array.
    .PARAMETER Argument
    The command and its arguments, e.g. @('pmset','-a','sleep','0').
    .OUTPUTS
    [bool] $true when sudo ran the command and it exited 0.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string[]]$Argument)
    # Pinned locally: this function reports a failed write through its return
    # value and a warning naming the command. With
    # $PSNativeCommandUseErrorActionPreference true the non-zero exit throws
    # first, so a single key this macOS release no longer carries would abort the
    # whole guard list instead of being recorded as rejected and skipped.
    $PSNativeCommandUseErrorActionPreference = $false
    $out = & sudo -n @Argument 2>&1
    if ($LASTEXITCODE -eq 0) { return $true }
    Write-Warning ("sudo {0} failed (exit {1}): {2}" -f ($Argument -join ' '), $LASTEXITCODE, ("$($out | Out-String)".Trim()))
    return $false
}

# --- REGION: utmctl on PATH
# UTM ships its command-line interface INSIDE the app bundle, and no installer
# -- neither the cask nor the .dmg -- puts that directory on anyone's PATH.
# Every VM operation the harness performs shells out to `utmctl`, so a host with
# UTM.app correctly installed still cannot start a single cycle until the binary
# is reachable by name. The link goes in /usr/local/bin because that directory is
# listed in the stock /etc/paths, which means a login shell, a LaunchAgent and an
# `ssh host command` all see it; Homebrew's bin only reaches shells that ran
# `brew shellenv`.
$script:MacUtmAppPath        = '/Applications/UTM.app'
$script:MacUtmctlBundlePath  = '/Applications/UTM.app/Contents/MacOS/utmctl'
# Written out rather than derived with Split-Path: these are POSIX paths, and
# Split-Path renders a parent with the SEPARATOR OF THE RUNNING HOST -- so the
# repair command this module hands an operator comes out with backslashes in it
# whenever the string is produced anywhere but a Mac.
$script:MacUtmctlLinkDir     = '/usr/local/bin'
$script:MacUtmctlLinkPath    = '/usr/local/bin/utmctl'

function Get-MacScreenLockManualCommand {
    <#
    .SYNOPSIS
    The one-liner an operator can run by hand to set the unified screen lock
    without their password appearing on screen.
    .DESCRIPTION
    The obvious command to print -- `sudo sysadminctl -screenLock off -password -`
    -- is the one that misbehaves: sysadminctl reads that password from stdin
    with a plain stream read and never turns terminal echo off, so the operator
    watches their own password appear and leaves it in the scrollback. Advice
    that does that is worse than no advice, because it is followed.

    `read -rs` reads it invisibly and the pipe hands it over, so the value
    reaches neither the screen nor argv (where `ps` would show it). The variable
    is unset on the way out; shells do not record `read` input in history.

    The prompt is a separate `printf` rather than `read -p`, because the default
    shell on macOS is zsh, where `-p` means "read from the coprocess" instead of
    "prompt" -- the bash-shaped one-liner does not fail there, it silently reads
    the wrong thing. `printf` + `read -rs` behaves identically in both shells.
    .OUTPUTS
    [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$State = 'off')
    return "printf 'macOS account password: ' && read -rs YPW && echo && printf '%s\n' `"`$YPW`" | sudo sysadminctl -screenLock $State -password -; unset YPW"
}

function Set-MacScreenLockState {
    <#
    .SYNOPSIS
    Run `sysadminctl -screenLock <state>` with the account password read
    invisibly. Returns what the attempt did.
    .DESCRIPTION
    This is the one host setting root cannot apply: the unified lock is backed
    by a secure-keyring entry, so sysadminctl wants the ACCOUNT password on top
    of sudo.

    `-password -` makes it read that password from STDIN as a plain stream read.
    It never calls tcsetattr, so nothing turns the terminal's echo off, and a
    person typing at the prompt watches their password appear in the clear and
    stay in the scrollback and in any transcript of the run.

    The fix is to stop a human from typing at that prompt at all: PowerShell
    reads the password masked and feeds it down the pipe sysadminctl is already
    reading. The value never reaches argv either, which rules out the other
    obvious shape, `-password <plaintext>`, where `ps` would show it to every
    account on the machine.

    Echo is disabled around the call as well, and restored in a finally. The
    pipe is the fix; the echo guard covers a macOS release that decides to read
    /dev/tty instead of the stdin it was handed, which would put the visible
    prompt straight back. A terminal left with echo off outlives the script, so
    it is only turned off once `stty` has confirmed it is talking to a terminal.
    .PARAMETER State
    What to pass to -screenLock: 'off', or a delay in seconds.
    .PARAMETER Reason
    Filled into the password prompt so the operator knows what is asking.
    .OUTPUTS
    [hashtable] @{ Attempted; ExitCode; Output }. Attempted is $false when
    nothing could ask for the password, which is a different outcome from a
    refused one and needs a different message.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$State,
        [string]$Reason = 'change the unified screen lock'
    )

    if (-not (Test-YurunaCanPrompt)) {
        return @{ Attempted = $false; ExitCode = -1; Output = 'the account password can only come from a person, and nothing in this run can ask one' }
    }
    if (-not $PSCmdlet.ShouldProcess("sysadminctl -screenLock $State", 'Run with the macOS account password')) {
        return @{ Attempted = $false; ExitCode = 0; Output = 'preview only' }
    }

    $account = if ($env:USER) { $env:USER } else { "$(& id -un)" }
    $secure = Read-Host -Prompt "macOS account password for $account (sysadminctl needs it to $Reason; typing is hidden)" -AsSecureString
    if (-not $secure -or $secure.Length -eq 0) {
        return @{ Attempted = $false; ExitCode = -1; Output = 'no password entered' }
    }

    # Pinned locally: sudo and sysadminctl both report through exit codes this
    # function returns to its caller, and a terminating error would replace that
    # with a generic native-command failure.
    $PSNativeCommandUseErrorActionPreference = $false
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $echoOff = $false
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        & stty -echo 2>$null
        if ($LASTEXITCODE -eq 0) { $echoOff = $true }
        $raw = $plain | & sudo -n sysadminctl -screenLock $State -password - 2>&1
        $rc = $LASTEXITCODE
        return @{
            Attempted = $true
            ExitCode  = $rc
            Output    = ((@($raw) | ForEach-Object { "$_" }) -join "`n").Trim()
        }
    } finally {
        # The unmanaged copy is wiped here. The managed one lives until the GC
        # collects it -- unavoidable for a value that has to be handed to a
        # child process, and still far better than the screen.
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $plain = $null
        $secure.Dispose()
        if ($echoOff) { & stty echo 2>$null }
    }
}

function Get-MacUtmctlRemediation {
    <#
    .SYNOPSIS
    The exact shell command that puts `utmctl` on PATH.
    .DESCRIPTION
    One string, three consumers -- Set-MacUtmctlLink's failure warning,
    Test-MacHostMinimum's warning and Test-Config's failure line. An operator
    who is told to fix this reads whichever of the three their entry point
    prints, and a command that differs between them is one they have to
    reconcile before they can trust any of it.
    .OUTPUTS
    [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return "sudo mkdir -p $script:MacUtmctlLinkDir && sudo ln -sfn $script:MacUtmctlBundlePath $script:MacUtmctlLinkPath"
}

function Set-MacUtmctlLink {
    <#
    .SYNOPSIS
    Makes `utmctl` resolvable by name, linking /usr/local/bin/utmctl to the copy
    inside UTM.app when it is not. Idempotent; returns $true when the host ends
    the call with utmctl on PATH.
    .DESCRIPTION
    Reports through the return value and a warning naming the exact command,
    never through a throw: this runs inside the host-settings sweep, where one
    unavailable knob must not abandon the remaining ones.

    Three distinguishable failures, because the operator's next move differs for
    each: UTM is not installed (install it), root is not reachable without a
    password (run the printed command by hand), or the link exists but the
    directory holding it is not on this session's PATH (an edited PATH, which no
    amount of re-linking fixes).
    .OUTPUTS
    [bool] $true when utmctl resolves on PATH after this call.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()

    if (-not $IsMacOS) { return $true }

    if (Get-Command utmctl -ErrorAction SilentlyContinue) {
        Write-Information "utmctl is already on PATH."
        return $true
    }

    if (-not (Test-Path -LiteralPath $script:MacUtmctlBundlePath)) {
        if (Test-Path -LiteralPath $script:MacUtmAppPath) {
            Write-Warning "UTM is installed at $script:MacUtmAppPath but does not carry $script:MacUtmctlBundlePath -- the bundle is incomplete. Reinstall it: brew reinstall --cask utm"
        } else {
            Write-Warning "UTM is not installed at $script:MacUtmAppPath, so there is no utmctl to link. Install it: brew install --cask utm (or https://mac.getutm.app)."
        }
        return $false
    }

    if (-not (Test-MacSudoAvailable)) {
        Write-Warning "utmctl is not on PATH and root is not reachable without a password. Run: $(Get-MacUtmctlRemediation)"
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess($script:MacUtmctlLinkPath, "Link to $script:MacUtmctlBundlePath so utmctl is on PATH")) {
        return $true
    }

    Write-Information "Linking $script:MacUtmctlLinkPath -> $script:MacUtmctlBundlePath so utmctl is on PATH..."
    # -sfn, not -sf: with a plain -sf, a target that is already a symlink to a
    # DIRECTORY makes ln create the new link inside it instead of replacing it.
    $ok = Invoke-MacPrivilegedSetting -Argument @('mkdir', '-p', $script:MacUtmctlLinkDir)
    if ($ok) {
        $ok = Invoke-MacPrivilegedSetting -Argument @('ln', '-sfn', $script:MacUtmctlBundlePath, $script:MacUtmctlLinkPath)
    }
    if (-not $ok) {
        Write-Warning "Could not link utmctl. Run: $(Get-MacUtmctlRemediation)"
        return $false
    }

    # PATH is read here rather than trusting Get-Command a second time: this
    # process resolved utmctl as missing moments ago and PowerShell may still be
    # answering from that lookup, so a re-probe can report a failure the next
    # process will not see. The directory membership is the durable fact.
    $onPath = @(("$env:PATH" -split ':') | Where-Object { $_ -eq $script:MacUtmctlLinkDir }).Count -gt 0
    if (-not $onPath) {
        Write-Warning "Linked $script:MacUtmctlLinkPath, but $script:MacUtmctlLinkDir is not in PATH for this session, so utmctl still will not resolve by name. Add it (it is in the stock /etc/paths, so an edited PATH or a shell profile is dropping it) and start a new shell."
        return $false
    }
    return $true
}

function Set-MacHostConditionSet {
    <#
    .SYNOPSIS
    Configures macOS host settings needed for unattended VM testing:
    disables display sleep, screen saver idle, and screen lock password;
    triggers first-run prompts for the Accessibility and Screen Recording
    TCC permissions (both required -- keystroke injection + per-window
    capture). Requires sudo for pmset. Idempotent.
    .OUTPUTS
    [int] the number of conditions this run could not put in place. 0 means
    every knob is where the harness needs it. The caller maps a non-zero count
    onto its own exit contract -- see host/macos.utm/Enable-TestAutomation.ps1.
    .EXAMPLE
    Set-MacHostConditionSet          # apply all settings
    Set-MacHostConditionSet -WhatIf  # show what would change without applying
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param()

    if (-not $IsMacOS) {
        Write-Warning "Set-MacHostConditionSet is only supported on macOS."
        return 0
    }

    # Conditions this run wanted and could not establish. The count is the
    # return value, so a host that came out degraded is a distinguishable
    # outcome for the caller rather than a warning in a captured log nothing
    # reads. Only knobs that are genuinely required go in here; each addition
    # below records why that one qualifies, and the ones deliberately left out
    # say why they are advisory.
    $unmet = [System.Collections.Generic.List[string]]::new()

    # --- REGION: Pre-flight: elevation
    # Every privileged block below probes `sudo -n true` immediately before it
    # writes, and every write goes out with -n. The two facts an environment
    # variable could carry -- who started this run, whether somebody typed a
    # password minutes ago -- do not answer whether root is reachable NOW: the
    # timestamp may have expired during a long step, a brew cask post-install
    # may have run `sudo -k`, or an /etc/sudoers.d rule may grant the write
    # with no timestamp involved at all.
    #
    # Initialize-SudoCache still runs first so an operator at a terminal is
    # asked once, visibly, with the reasons on screen, instead of meeting a
    # bare password prompt in the middle of a block. It declines silently when
    # nobody is there to ask, and the probes below then route each block to its
    # warn-with-the-exact-command arm.
    [void](Initialize-SudoCache -Reasons @(
        'pmset (display sleep, system sleep, power-nap, hibernation)',
        'defaults write /Library/Preferences (auto-logout delay)',
        'sysadminctl -screenLock off (Sonoma+ unified screen lock)',
        'ln -s into /usr/local/bin (utmctl, the UTM command line, on PATH)'
    ))

    # --- REGION: utmctl on PATH
    # Required, and first: every later VM operation shells out to utmctl, and
    # both the cycle gate and Test-Config refuse a host without it. Doing it
    # here is what makes the remediation those two print -- "rerun
    # Enable-TestAutomation.ps1" -- true.
    if (-not (Set-MacUtmctlLink)) { $unmet.Add('utmctl on PATH') }

    # --- REGION: Display sleep -> Never (requires sudo)
    # `pmset -g custom` reports the active profile; the writes below cover
    # every power source this machine HAS, so a single read of the current
    # value is enough to decide whether a write is needed.
    $changed = $false
    $pmCustomLines = @(& pmset -g custom 2>$null)
    # `pmset -g custom` prints a "Battery Power:" block only on a machine that
    # has a battery. On a desktop Mac `pmset -b` fails by design, and counting
    # that failure would report a perfectly healthy host as degraded on every
    # run -- so the power sources this machine actually has decide what is
    # required of it.
    $hasBattery = [bool](@($pmCustomLines | Select-String -Pattern '^\s*Battery Power:').Count)
    # Every block, because the writes below cover every block: a Mac whose
    # battery profile reads 0 and whose AC profile reads 10 needs the write and
    # a first-match read would report it as already done. Assert-ScreenLock
    # refuses that host, so "already set" here would be a run that changes
    # nothing followed by a cycle that will not start.
    $displaySleepBad = @(Get-MacPmsetKeyValue -PmsetCustom $pmCustomLines -Key 'displaysleep' |
        Where-Object { [int]$_ -ne 0 })
    $currentSleep = if ($displaySleepBad.Count -gt 0) { ($displaySleepBad | Sort-Object -Unique) -join '/' } else { "0" }

    if ($displaySleepBad.Count -gt 0) {
        # Required: Assert-ScreenLock refuses a host whose displaysleep is not 0,
        # so leaving it is a cycle that cannot start rather than a cosmetic gap.
        if (-not (Test-MacSudoAvailable)) {
            Write-Warning "Display sleep is '$currentSleep' (expected 0) and root is not reachable without a password. Run 'sudo pmset -c displaysleep 0; sudo pmset -b displaysleep 0' to fix."
            $unmet.Add('display sleep')
        } elseif ($PSCmdlet.ShouldProcess("Display sleep (currently $currentSleep min)", "Set to 0 (Never) via sudo pmset")) {
            Write-Information "Setting display sleep to Never$(if ($hasBattery) { ' (AC and battery)' } else { ' (AC)' })..."
            $sleepOk = Invoke-MacPrivilegedSetting -Argument @('pmset', '-c', 'displaysleep', '0')
            if ($hasBattery) {
                $sleepOk = (Invoke-MacPrivilegedSetting -Argument @('pmset', '-b', 'displaysleep', '0')) -and $sleepOk
            }
            if ($sleepOk) { $changed = $true } else { $unmet.Add('display sleep') }
        }
    } else {
        Write-Information "Display sleep is already set to Never."
    }

    # --- REGION: Screen saver idle time -> 0 (disabled)
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
            & defaults write com.apple.screensaver idleTime -int 0 | Out-Null
            $changed = $true
        }
    }

    # --- REGION: Screen lock (password after screen saver) -> OFF
    # Same "missing key != safe" as the "Screen saver idle time -> 0" region: some macOS versions default
    # askForPassword to 1. Write 0 unless the key is explicitly "0".
    $askPw = & defaults read com.apple.screensaver askForPassword 2>$null
    $askPwRead = ($LASTEXITCODE -eq 0)
    if ($askPwRead -and "$askPw".Trim() -eq "0") {
        Write-Information "Screen lock password is already disabled."
    } else {
        $label = if (-not $askPwRead) { 'unset -- macOS default applies' } else { "$($askPw.Trim())" }
        if ($PSCmdlet.ShouldProcess("Screen lock password (currently $label)", "Disable (askForPassword -> 0)")) {
            Write-Information "Disabling screen lock password requirement (was $label)..."
            & defaults write com.apple.screensaver askForPassword -int 0 | Out-Null
            $changed = $true
        }
    }

    # --- REGION: Screen saver idle -- per-host variant (Ventura+)
    # Modern macOS stores screensaver prefs in the ByHost domain. Without
    # this, System Settings still shows non-zero idle time after the
    # "Screen saver idle time -> 0" region above and
    # the saver still kicks in. Same missing-key-is-unsafe logic as that region.
    $ssIdleHost = & defaults -currentHost read com.apple.screensaver idleTime 2>$null
    $ssIdleHostRead = ($LASTEXITCODE -eq 0)
    if ($ssIdleHostRead -and "$ssIdleHost".Trim() -eq "0") {
        Write-Information "Screen saver idle activation (currentHost) is already disabled."
    } else {
        $label = if (-not $ssIdleHostRead) { 'unset -- macOS default applies' } else { "$($ssIdleHost.Trim())s" }
        if ($PSCmdlet.ShouldProcess("Screen saver idle time [currentHost] (currently $label)", "Set to 0 (disabled)")) {
            Write-Information "Disabling screen saver idle activation, currentHost (was $label)..."
            & defaults -currentHost write com.apple.screensaver idleTime -int 0 | Out-Null
            $changed = $true
        }
    }

    # --- REGION: Screen lock password -- per-host variant
    # Same missing-key-is-unsafe logic as the "Screen lock (password after screen saver) -> OFF" region.
    $askPwHost = & defaults -currentHost read com.apple.screensaver askForPassword 2>$null
    $askPwHostRead = ($LASTEXITCODE -eq 0)
    if ($askPwHostRead -and "$askPwHost".Trim() -eq "0") {
        Write-Information "Screen lock password (currentHost) is already disabled."
    } else {
        $label = if (-not $askPwHostRead) { 'unset -- macOS default applies' } else { "$($askPwHost.Trim())" }
        if ($PSCmdlet.ShouldProcess("Screen lock password [currentHost] (currently $label)", "Disable (askForPassword -> 0)")) {
            Write-Information "Disabling screen lock password requirement, currentHost (was $label)..."
            & defaults -currentHost write com.apple.screensaver askForPassword -int 0 | Out-Null
            $changed = $true
        }
    }

    # --- REGION: "Require password after sleep/screen saver begins" delay
    # Sonoma+ lock-screen pane. A very large delay prevents lock from
    # engaging even if something re-enables askForPassword.
    # ShouldProcess-gated like every other write in this function: these two
    # were the only ones that applied unconditionally, so a -WhatIf preview
    # silently changed the host it was only supposed to describe.
    foreach ($domainArgs in @(
        @{ Args = @('com.apple.screensaver', 'askForPasswordDelay')               ; Label = 'user' }
        @{ Args = @('-currentHost', 'com.apple.screensaver', 'askForPasswordDelay'); Label = 'currentHost' }
    )) {
        if ($PSCmdlet.ShouldProcess("Screen lock password delay [$($domainArgs.Label)]", 'Set to 2147483647 (effectively never)')) {
            # Advisory, not required: no gate reads this key. sysadminctl's
            # unified lock overrides the legacy askForPassword* pair on
            # Ventura+ (see 3j), which is why Assert-ScreenLock checks that
            # instead. A failure here is still worth the warning
            # Confirm-MacDefaultWrite raises -- it is the only signal that a
            # managed domain is rejecting writes -- but it must not by itself
            # make a host report degraded.
            if (-not (Confirm-MacDefaultWrite -DefaultsArgs $domainArgs.Args -WriteType '-int' -WriteValue '2147483647' -ExpectRead '2147483647')) {
                Write-Verbose "Screen lock password delay [$($domainArgs.Label)] did not take; the unified screen lock (3j) is what the gate checks."
            }
        }
    }

    # --- REGION: System sleep + disk sleep -> Never (requires sudo)
    # Display-sleep alone isn't enough: system sleep -> display locks on
    # wake regardless of screensaver settings. Disk sleep is the same story --
    # its wake re-checks lock state and on Ventura+ can engage the unified
    # screen lock even with askForPassword=0.
    #
    # Each key is decided on its own value, through the same helper that decides
    # the extended guards, because the two drift apart: a host holding sleep=0
    # and disksleep=10 is exactly what the gate refuses, and one shared decision
    # read from `sleep` would report "already Never" and write nothing on every
    # single run -- leaving the operator re-running a setup script that cannot
    # reach the setting the gate is stopping on.
    $sleepGuards  = Get-MacSleepGuardList
    $sleepPending = @(Get-MacPmsetGuardPending -PmsetCustom (& pmset -g custom 2>$null) -Guard $sleepGuards)

    if ($sleepPending.Count -gt 0) {
        $pendingNames = ($sleepPending | ForEach-Object { $_.Key }) -join ', '
        # Required for the same reason as display sleep: Assert-ScreenLock
        # refuses a host whose sleep / disksleep are non-zero.
        if (-not (Test-MacSudoAvailable)) {
            Write-Warning "Still non-zero: $pendingNames (expected 0 / Never), and root is not reachable without a password. Run '$(($sleepPending | ForEach-Object { "sudo pmset -a $($_.Key) $($_.Want)" }) -join '; ')' to fix."
            $unmet.Add('system sleep')
        } elseif ($PSCmdlet.ShouldProcess("System sleep ($pendingNames)", "Set to 0 (Never) via sudo pmset")) {
            Write-Information "Setting $pendingNames to Never (all power sources)..."
            # -a covers AC + battery + UPS. Writing only -c leaves a laptop on
            # battery with the setting it had.
            $sleepOkAll = $true
            foreach ($g in $sleepPending) {
                if (-not (Invoke-MacPrivilegedSetting -Argument @('pmset', '-a', "$($g.Key)", "$($g.Want)"))) { $sleepOkAll = $false }
            }
            if ($sleepOkAll) { $changed = $true } else { $unmet.Add('system sleep') }
        }
    } else {
        Write-Information "System sleep and disk sleep are already set to Never."
    }

    # --- REGION: Extended pmset guards
    # Extended pmset guards: Power Nap, standby, autopoweroff, hibernate
    # transitions hide UTM from CG enumeration on long runs. The guard list is
    # shared with Assert-ScreenLock (Get-MacPmsetGuardList) so the gate re-checks
    # exactly what is applied here. Per-key rationale, OptionalKey policy, and
    # precheck-before-sudo logic at https://yuruna.link/host/macos
    $pmsetGuards  = Get-MacPmsetGuardList
    $pmsetPending = @(Get-MacPmsetGuardPending -PmsetCustom (& pmset -g custom 2>$null) -Guard $pmsetGuards)
    if ($pmsetPending.Count -eq 0) {
        Write-Information "Extended pmset guards verified (no mismatched keys in 'pmset -g custom')."
    } elseif (-not (Test-MacSudoAvailable)) {
        # Name the exact commands: the operator has to run them by hand here,
        # and a generic "there is a mismatch" leaves them reading pmset output
        # against a guard list they can't see.
        Write-Warning "Extended pmset guards are not applied and root is not reachable without a password. Run these yourself before starting tests:"
        foreach ($g in $pmsetPending) { Write-Warning "  sudo pmset -a $($g.Key) $($g.Want)" }
        # Deliberately advisory. A key absent from `pmset -g custom` is pending
        # only because AlwaysApply says absence proves nothing, and a lidless
        # desktop Mac never surfaces disablesleep at all -- Assert-ScreenLock
        # skips exactly those keys for the same reason. Counting them would
        # report a healthy desktop host as degraded on every single run.
        Write-Verbose "Extended pmset guards are advisory here; Assert-ScreenLock re-checks the keys this macOS actually surfaces."
    } elseif ($PSCmdlet.ShouldProcess("Extended pmset guards", "Apply via sudo pmset -a")) {
        # ONLY the pending keys. `pmset` has no delete, so a key this host never
        # carried can never be taken back off it: the pre-automation capture
        # records it as absent, and the restore has nothing to write except a
        # value nobody chose. Get-MacPmsetGuardPending already draws exactly the
        # right line -- a key present with the wrong value, plus the AlwaysApply
        # keys whose absence carries no information and which the guard list
        # gives an AbsentEquivalent so the restore can undo them. Everything it
        # leaves out is a name this macOS release does not surface, and writing
        # one buys nothing but a host setting that outlives the automation.
        # Key names come from the pending set so this message cannot drift away
        # from what is actually written.
        Write-Information "Applying extended pmset guards ($(($pmsetPending | ForEach-Object { $_.Key }) -join ', '))..."
        # Warnings are suppressed per key and the rejected set is reported once,
        # because the two causes need different words and only a probe tells
        # them apart: a name this release dropped says nothing about the host,
        # while an elevation that expired mid-loop is the operator's to fix.
        $rejected = @()
        foreach ($g in $pmsetPending) {
            if (-not (Invoke-MacPrivilegedSetting -Argument @('pmset', '-a', "$($g.Key)", "$($g.Want)") -WarningAction SilentlyContinue)) {
                $rejected += $g.Key
            }
        }
        if ($rejected.Count -gt 0) {
            if (Test-MacSudoAvailable) {
                Write-Verbose "pmset rejected: $($rejected -join ', ') -- this macOS may not carry those keys."
            } else {
                Write-Warning "Root stopped being reachable without a password part-way through the extended pmset guards. Run these yourself before starting tests:"
                foreach ($k in $rejected) {
                    $want = @($pmsetPending | Where-Object { $_.Key -eq $k })[0].Want
                    Write-Warning "  sudo pmset -a $k $want"
                }
            }
        }
        $changed = $true
        $stillPending = @(Get-MacPmsetGuardPending -PmsetCustom (& pmset -g custom 2>$null) -Guard $pmsetGuards)
        if ($stillPending.Count -eq 0) {
            Write-Information "Extended pmset guards verified after applying."
        } else {
            # Not a warning: a Mac with no lid never surfaces disablesleep no
            # matter how often it is written, and Assert-ScreenLock skips
            # exactly those keys. Saying so once, where the write happened, is
            # the only place the state is ever observable.
            Write-Information "  'pmset -g custom' still does not report: $(($stillPending | ForEach-Object { $_.Key }) -join ', '). macOS lists a guard only on hardware that has it."
        }
    }

    # --- REGION: Hot corners -- neutralize screen-saver / sleep / lock triggers
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

    # --- REGION: UTM.app lifetime: App Nap + last-window-closed
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

    # UTM's default is to terminate once its last window closes, and its
    # termination path SAVES THE STATE of every VM still running rather
    # than leaving them alone: they come back `suspended`, not `started`.
    # The service VMs (caching proxy, stash, pool-control) are long-lived
    # infrastructure that guests consume for the whole cycle, so closing a
    # VM window -- or the library window -- silently takes the cycle's
    # dependencies offline and every guest that needs the proxy or the
    # stash then fails. Keeping the app resident removes the window-close
    # route into that state. UTM reads this at launch, so a UTM already
    # running keeps its old behavior until it is next started.
    $keepRunningState = & defaults read $utmBundleId KeepRunningAfterLastWindowClosed 2>$null
    $keepRunningAlready = ($LASTEXITCODE -eq 0 -and "$keepRunningState".Trim() -eq '1')
    if (-not $keepRunningAlready) {
        if ($PSCmdlet.ShouldProcess("UTM.app ($utmBundleId)", "Keep running after last window closed (KeepRunningAfterLastWindowClosed = YES)")) {
            Write-Information "Keeping UTM.app alive after its last window closes ($utmBundleId)..."
            if (Confirm-MacDefaultWrite -DefaultsArgs @($utmBundleId, 'KeepRunningAfterLastWindowClosed') -WriteType '-bool' -WriteValue 'YES' -ExpectRead '1') {
                $changed = $true
            }
        }
    } else {
        Write-Information "UTM.app already stays running after its last window closes."
    }

    # --- REGION: Clear any stuck ScreenSaverEngine
    # If a prior aborted run left the saver engaged, the engine process
    # may still be running when this script applies settings. Killing
    # is idempotent and harmless when nothing runs; swallow exit codes
    # so "no such process" isn't reported as failure.
    & killall ScreenSaverEngine 2>$null | Out-Null

    # --- REGION: sysadminctl unified screen lock (Ventura+)
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
        # This block needs two different things and only one of them is root.
        # `-password -` reads the ACCOUNT password from stdin, so a run that
        # cannot put a question in front of a person cannot do this at all:
        # under a captured child stdin is closed, the read returns EOF, and the
        # attempt would be reported as a FAILED disable rather than one that was
        # never possible. Name the one-time command instead.
        if (-not ((Test-MacSudoAvailable) -and (Test-YurunaCanPrompt))) {
            Write-Warning "========"
            Write-Warning " sysadminctl unified screen lock is NOT yet disabled (status:"
            Write-Warning "   $slStatus)"
            Write-Warning ""
            Write-Warning " Run this ONE-TIME command yourself before starting tests:"
            Write-Warning ""
            Write-Warning "   $(Get-MacScreenLockManualCommand -State 'off')"
            Write-Warning ""
            Write-Warning " sysadminctl wants your ACCOUNT password, not sudo's, and reads it"
            Write-Warning " from stdin without turning terminal echo off -- so it is piped in"
            Write-Warning " above rather than typed at its prompt, where it would be visible."
            Write-Warning " State is persistent across reboots, so this warning will not"
            Write-Warning " reappear once it succeeds."
            Write-Warning "========"
            # Required: Assert-ScreenLock refuses a host whose unified lock is
            # active, and that lock overrides every legacy key above it.
            $unmet.Add('sysadminctl unified screen lock')
        } elseif ($PSCmdlet.ShouldProcess("sysadminctl $slStatus", "Disable (sysadminctl -screenLock off)")) {
            Write-Information "Disabling sysadminctl unified screen lock (it needs your macOS ACCOUNT password, which sudo cannot supply)..."
            # Through the shared helper, which reads that password masked and
            # pipes it in. Typing it at sysadminctl's own prompt puts it on the
            # screen in the clear: that prompt is a plain stdin read with no
            # tcsetattr behind it, so nothing turns the terminal's echo off.
            $slRun = Set-MacScreenLockState -State 'off' -Reason 'turn the unified screen lock off'
            if ($slRun.Output) { Write-Information "  sysadminctl: $($slRun.Output)" }
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
                $unmet.Add('sysadminctl unified screen lock')
            }
        }
    } else {
        Write-Information "sysadminctl unified screen lock is already disabled."
    }

    # --- REGION: Auto-logout after inactivity (Security -> Advanced)
    # `com.apple.autologout.AutoLogOutDelay` (system-level) is the
    # "Log out after N minutes of inactivity" toggle in Lock Screen /
    # Security. macOS kicks the user back to loginwindow after the
    # delay -- indistinguishable from a lock ("demands password"), but
    # no screen-saver / pmset key we control would prevent it. System
    # level (/Library/Preferences/.GlobalPreferences); the WRITE
    # requires sudo, but the plist is mode 644 so the READ does not --
    # reading it through sudo would spend an elevation on a value anyone can
    # see, and on a host that cannot elevate it would hide the state entirely.
    $autoLogoutDelay = & defaults read /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay 2>$null
    $autoLogoutOff = ($LASTEXITCODE -ne 0 -or "$autoLogoutDelay".Trim() -eq "0")
    if (-not $autoLogoutOff) {
        # Required: Assert-ScreenLock refuses a host with an active auto-logout.
        # It kicks the session to loginwindow mid-cycle, which looks exactly
        # like a lock and no screen-saver or pmset key prevents it.
        if (-not (Test-MacSudoAvailable)) {
            Write-Warning "AutoLogOutDelay is '$($autoLogoutDelay.Trim())' (expected 0) and root is not reachable without a password. Run 'sudo defaults write /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay -int 0' to fix."
            $unmet.Add('auto-logout delay')
        } elseif ($PSCmdlet.ShouldProcess("Auto-logout delay (currently $($autoLogoutDelay.Trim())s)", "Set to 0 (disabled)")) {
            Write-Information "Disabling auto-logout after inactivity..."
            if (Invoke-MacPrivilegedSetting -Argument @('defaults', 'write', '/Library/Preferences/.GlobalPreferences', 'com.apple.autologout.AutoLogOutDelay', '-int', '0')) {
                $changed = $true
            } else {
                $unmet.Add('auto-logout delay')
            }
        }
    } else {
        Write-Information "Auto-logout after inactivity is already disabled."
    }

    # --- REGION: Spaces "switch to a Space with open windows" toggle
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
    Write-Information "      Start-TestRunner activate UTM without yanking the operator off VS Code."

    # --- REGION: Managed Configuration Profile detection (MDM override)
    # If MDM-managed, a Configuration Profile can enforce screen lock /
    # password delay / auto-logout at a level that OVERRIDES everything
    # above -- `defaults write` is silently ignored or reverted on next
    # mcxrefresh. We can't bypass a profile; warn the user so they
    # don't chase a ghost.
    try {
        $profOutput = & profiles list 2>&1
        $hasProfiles = ($LASTEXITCODE -eq 0 -and "$profOutput" -notmatch 'no configuration profiles')
        if ($hasProfiles) {
            Write-Warning "========"
            Write-Warning " Configuration Profile(s) detected on this Mac. If any profile"
            Write-Warning " enforces screen-lock / password / auto-logout policy, the settings"
            Write-Warning " applied by this script will be overridden. Inspect with:"
            Write-Warning "   profiles list"
            Write-Warning "   profiles show -type configuration"
            Write-Warning " Policy keys to look for: screenSaverPasswordDelay, askForPassword,"
            Write-Warning " loginWindowIdleTime, AutoLogOutDelay, forceLockOnSleep."
            Write-Warning "========"
        }
    } catch {
        Write-Debug "profiles list failed: $_"
    }

    # --- REGION: Operator grants (Accessibility, Screen Recording, Automation)
    # Everything macOS allows a script to do about them: raise each consent
    # dialog, open the pane it belongs to, and -- with an operator present --
    # wait and re-read so the outcome is confirmed. What is still missing after
    # that is an unmet condition, which is what makes this script's exit 2 mean
    # "a person has to click something" rather than "look through the log".
    foreach ($grantId in @(Invoke-MacOperatorGrantAssist)) { $unmet.Add("$grantId permission") }

    # --- REGION: Host clock
    # Guests inherit this clock at power-on; see Sync-MacHostClock for what
    # a drifting one does to them. Its two calls already use sudo -n, so a cold
    # timestamp reports rather than prompts.
    $clock = Sync-MacHostClock
    if ($clock.Succeeded) {
        Write-Information "Host clock: $($clock.Message)"
        $changed = $true
    } else {
        # Advisory: Assert-MacHostConditionSet reports clock drift and never
        # refuses on it, because the repair needs a credential the asserting
        # process cannot ask for. Degrading the whole step on it would make
        # that decision twice, in opposite directions.
        Write-Warning "Host clock not disciplined: $($clock.Message)"
    }

    if ($changed) {
        Write-Information ""
        Write-Information "Settings updated. Re-run Assert-MacHostConditionSet to verify:"
        Write-Information "  Assert-MacHostConditionSet -HostType 'host.macos.utm'"
    }

    # A preview changed nothing, so it has nothing to report as unmet: the
    # ShouldProcess-gated blocks above never ran and the probe-only branches
    # describe a host this run did not attempt to fix.
    if ($WhatIfPreference) { return 0 }

    if ($unmet.Count -gt 0) {
        Write-Warning "Host settings applied with $($unmet.Count) condition(s) still unmet: $($unmet -join ', ')."
    }
    return $unmet.Count
}

# --- REGION: Operator grants (macOS privacy permissions)
# Permissions the harness cannot run without and that NO amount of root can
# supply. macOS keeps them in the TCC databases, System Integrity Protection
# guards those against every writer including root, `tccutil` can only RESET a
# decision and never grant one, and the single supported way to pre-authorize
# any of them is a Privacy Preferences Policy Control payload delivered by an
# MDM server the Mac is enrolled with. An administrator password buys nothing
# here, so no amount of elevation turns this into an unattended step.
#
# What IS possible, and what this region does: detect each grant WITHOUT raising
# a dialog, raise the system dialog and open the exact settings pane while an
# operator is present, name the application they actually have to enable, and
# wait for them to do it so the answer is confirmed rather than assumed.
#
# One registry, because the same grants are reported from two places -- the
# pre-cycle config gate and the per-cycle assertion. Instructions maintained
# twice drift, and an operator who follows one set and is then refused by the
# other has no way to tell which of the two is the stale one.

function Get-MacSessionKind {
    <#
    .SYNOPSIS
    Which kind of login session this process belongs to: 'Aqua', 'Remote' or
    'Unknown'.
    .DESCRIPTION
    A TCC grant belongs to a GUI login session. A process in an SSH session
    cannot hold Accessibility or Screen Recording no matter what the desktop
    session was granted, so the probe that correctly refuses the runner is a
    false alarm when an operator is merely reading a health report over SSH.
    The two are only distinguishable by asking which session manager owns this
    process, which is what `launchctl managername` answers.
    .OUTPUTS
    [string] 'Aqua' | 'Remote' | 'Unknown'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $IsMacOS) { return 'Unknown' }
    try {
        # Pinned locally: a non-zero exit here is an answer to read, not a
        # reason to abandon the caller's health report.
        $PSNativeCommandUseErrorActionPreference = $false
        $name = ("$(& launchctl managername 2>$null)").Trim()
        if ($LASTEXITCODE -eq 0 -and $name) {
            if ($name -eq 'Aqua') { return 'Aqua' }
            return 'Remote'
        }
    } catch {
        Write-Debug "launchctl managername failed: $_"
    }
    if ($env:SSH_CONNECTION -or $env:SSH_TTY) { return 'Remote' }
    return 'Unknown'
}

function Get-MacTccSubjectName {
    <#
    .SYNOPSIS
    The application an operator has to enable in the privacy pane.
    .DESCRIPTION
    Not pwsh. macOS attributes a privacy request to the RESPONSIBLE process --
    the terminal application that started the shell -- so a list entry for
    `pwsh` grants nothing, and the operator is left toggling something that
    never changes the answer. TERM_PROGRAM is what the terminal publishes about
    itself.
    .OUTPUTS
    [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    switch ($env:TERM_PROGRAM) {
        'Apple_Terminal' { return 'Terminal.app' }
        'iTerm.app'      { return 'iTerm.app' }
        'vscode'         { return 'Visual Studio Code' }
        'ghostty'        { return 'Ghostty' }
        'WarpTerminal'   { return 'Warp' }
        'WezTerm'        { return 'WezTerm' }
        'Hyper'          { return 'Hyper' }
        'Tabby'          { return 'Tabby' }
        default {
            if ($env:TERM_PROGRAM) { return $env:TERM_PROGRAM }
            return 'your terminal app'
        }
    }
}

function Test-MacAccessibilityGrant {
    <#
    .SYNOPSIS
    'granted' / 'denied' / 'unknown' for Accessibility, without prompting.
    .DESCRIPTION
    AXIsProcessTrusted is the read-only half of the API pair: it reports the
    current answer and never raises the consent dialog. Its prompting sibling,
    AXIsProcessTrustedWithOptions, belongs in the assist path where somebody is
    present to answer.
    .OUTPUTS
    [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $IsMacOS) { return 'unknown' }
    try {
        $jxa = "ObjC.import('ApplicationServices'); $.AXIsProcessTrusted();"
        $result = ("$(& osascript -l JavaScript -e $jxa 2>&1)").Trim()
        if ($result -eq 'true')  { return 'granted' }
        if ($result -eq 'false') { return 'denied' }
        Write-Debug "AXIsProcessTrusted returned '$result'"
    } catch {
        Write-Debug "Accessibility probe failed: $_"
    }
    return 'unknown'
}

function Test-MacScreenRecordingGrant {
    <#
    .SYNOPSIS
    'granted' / 'denied' for Screen Recording, without prompting.
    .DESCRIPTION
    CGPreflightScreenCaptureAccess is the canonical read and never prompts.
    ObjC.bindFunction is REQUIRED on some macOS releases -- without it the call
    returns `undefined`, which reads as "not granted" on a host where the grant
    is in place.

    The window-enumeration fallback runs only when the preflight gives no usable
    answer. It requires titles from at least TWO foreign owners: a single
    permissive-NSWindowSharingType window is visible to every process, so one
    hit would claim a grant that is not there.
    .OUTPUTS
    [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $IsMacOS) { return 'unknown' }
    $jxaPre = @"
ObjC.import('CoreGraphics');
try { ObjC.bindFunction('CGPreflightScreenCaptureAccess', ['bool', []]); } catch (e) {}
var r = `$.CGPreflightScreenCaptureAccess();
(r === true || r === 1) ? 'true' : 'false'
"@
    try {
        $result = (& osascript -l JavaScript -e $jxaPre 2>&1 | Out-String).Trim()
        Write-Debug "Test-MacScreenRecordingGrant: CGPreflight returned '$result'"
        if ($result -eq 'true') { return 'granted' }
    } catch {
        Write-Debug "CGPreflight check failed: $_"
    }

    $jxa = @"
ObjC.import('CoreGraphics');
var list = `$.CGWindowListCopyWindowInfo((1 << 0) | (1 << 4), 0);
if (!list) { 'false' } else {
    var n = `$.CFArrayGetCount(list);
    var nameKey  = `$.CFStringCreateWithCString(null, 'kCGWindowName', 0);
    var ownerKey = `$.CFStringCreateWithCString(null, 'kCGWindowOwnerName', 0);
    var owners = {};
    for (var i = 0; i < n; i++) {
        var d = `$.CFArrayGetValueAtIndex(list, i);
        var nm = `$.CFDictionaryGetValue(d, nameKey);
        if (!nm || `$.CFStringGetLength(nm) === 0) continue;
        var ow = `$.CFDictionaryGetValue(d, ownerKey);
        var owStr = ow ? ObjC.unwrap(ow) : '';
        if (owStr) owners[owStr] = true;
    }
    (Object.keys(owners).length >= 2) ? 'true' : 'false'
}
"@
    try {
        $result = (& osascript -l JavaScript -e $jxa 2>&1 | Out-String).Trim()
        Write-Debug "Test-MacScreenRecordingGrant: enumeration fallback returned '$result'"
        if ($result -eq 'true') { return 'granted' }
    } catch {
        Write-Debug "Window-title enumeration failed: $_"
    }
    return 'denied'
}

function Get-MacOperatorGrant {
    <#
    .SYNOPSIS
    Every macOS permission the harness needs that only a person can give.
    .DESCRIPTION
    Data, not behavior, so the config gate and the per-cycle assertion render
    the SAME sentences from the SAME fields, and a fourth consumer needs no new
    code. Adding a grant here is the whole change.

    Fields:
      Id          stable key, used by callers and reported in unmet counts
      Title       the name the privacy pane uses
      Pane        where it lives, spelled the way System Settings spells it
      DeepLink    URL that opens exactly that pane
      Why         what the harness cannot do without it
      Blocking    $true when a cycle genuinely cannot run without it
      Probe       reads the current state WITHOUT prompting; $null when macOS
                  offers no way to ask that does not raise a dialog
      Prompt      raises the system consent dialog; run only with an operator
      Relaunch    'always' when macOS refuses to honor a fresh grant in an
                  already-running process, 'if-still-denied' otherwise
      SkipEnvVar  environment variable that forces the check to pass
      Diagnostic  extra lines printed with the instructions
    .OUTPUTS
    [pscustomobject[]]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$Id)

    $all = @(
        [pscustomobject]@{
            Id         = 'Accessibility'
            Title      = 'Accessibility'
            Pane       = 'System Settings > Privacy & Security > Accessibility'
            DeepLink   = 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
            Why        = 'the harness posts keystrokes into UTM guest windows without holding focus. Without it every keystroke step needs UTM frontmost, and any window change loses input mid-sequence.'
            Blocking   = $true
            Probe      = { Test-MacAccessibilityGrant }
            Prompt     = {
                # AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt
                # is the only supported way to make the dialog appear.
                $jxaPrompt = @"
ObjC.import('CoreFoundation');
ObjC.import('ApplicationServices');
var opts = `$.CFDictionaryCreateMutable(null, 1,
    `$.kCFTypeDictionaryKeyCallBacks, `$.kCFTypeDictionaryValueCallBacks);
var key = `$.CFStringCreateWithCString(null, 'AXTrustedCheckOptionPrompt', 0);
`$.CFDictionarySetValue(opts, key, `$.kCFBooleanTrue);
`$.AXIsProcessTrustedWithOptions(opts);
"@
                & osascript -l JavaScript -e $jxaPrompt 2>&1 | Out-Null
            }
            EnableStep = 'Add and enable {0} -- NOT pwsh: macOS attributes the request to the terminal application, so an entry for the shell grants nothing'
            Relaunch   = 'if-still-denied'
            SkipEnvVar = $null
            Diagnostic = @()
        },
        [pscustomobject]@{
            Id         = 'ScreenRecording'
            Title      = 'Screen Recording'
            Pane       = 'System Settings > Privacy & Security > Screen Recording'
            DeepLink   = 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'
            Why        = 'CGWindowList returns window TITLES only to a process holding this grant, and the harness finds UTM''s per-VM window by title before capturing it with screencapture -l. Without it, tapOn loops on "UTM window for <vm> not found".'
            Blocking   = $true
            Probe      = { Test-MacScreenRecordingGrant }
            Prompt     = {
                $jxa = @"
ObjC.import('CoreGraphics');
try { ObjC.bindFunction('CGRequestScreenCaptureAccess', ['bool', []]); } catch (e) {}
`$.CGRequestScreenCaptureAccess();
"@
                & osascript -l JavaScript -e $jxa 2>&1 | Out-Null
            }
            EnableStep = 'Add and enable {0} -- NOT pwsh: macOS attributes the request to the terminal application, so an entry for the shell grants nothing'
            Relaunch   = 'always'
            SkipEnvVar = 'YURUNA_SKIP_SCREEN_RECORDING_CHECK'
            Diagnostic = @(
                'If the toggle IS on and the terminal was relaunched, run this and report the output:',
                '  osascript -l JavaScript -e ''ObjC.import("CoreGraphics"); ObjC.bindFunction("CGPreflightScreenCaptureAccess", ["bool",[]]); $.CGPreflightScreenCaptureAccess();'''
            )
        },
        [pscustomobject]@{
            Id         = 'AutomationUtm'
            Title      = 'Automation -> UTM'
            Pane       = 'System Settings > Privacy & Security > Automation'
            DeepLink   = 'x-apple.systempreferences:com.apple.preference.security?Privacy_Automation'
            Why        = 'utmctl drives UTM over Apple Events. Without it every VM operation fails with OSStatus -1743, which reads as a broken UTM rather than as a missing permission.'
            # Not blocking, and deliberately not probed: macOS offers no way to
            # READ this grant that does not itself raise the dialog, and a gate
            # that pops a modal before every cycle would hang an unattended host
            # on a question nobody is there to answer. The assist path triggers
            # and confirms it while an operator is present; the gate lists it so
            # the prompt is expected rather than a surprise mid-cycle.
            Blocking   = $false
            Probe      = $null
            Prompt     = {
                # The first Apple Event to UTM is what raises the dialog.
                if (Get-Command utmctl -ErrorAction SilentlyContinue) {
                    & utmctl list 2>&1 | Out-Null
                }
            }
            EnableStep = 'Find {0} in the list and turn ON the UTM row underneath it. This pane has no + button -- an application appears in it only after it has asked once, which is exactly what the first utmctl call does.'
            Relaunch   = 'if-still-denied'
            SkipEnvVar = $null
            Diagnostic = @(
                'macOS asks for this the first time utmctl talks to UTM. Answer OK, not "Don''t Allow" -- a refusal is remembered, and only this pane can undo it.'
            )
        }
    )

    if ($Id) { return @($all | Where-Object { $_.Id -eq $Id }) }
    return $all
}

function Get-MacOperatorGrantState {
    <#
    .SYNOPSIS
    Each grant paired with what this host currently reports for it.
    .DESCRIPTION
    Callers read State rather than invoking Probe themselves: the probes are
    module-private, and running them here is what keeps a consumer from having
    to know that a skip variable can override a denial.
    .OUTPUTS
    [pscustomobject[]] Id, Title, Blocking, State, Grant. State is one of:
    granted, denied, unknown, unprobed, overridden.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$Id)

    $out = foreach ($g in (Get-MacOperatorGrant -Id $Id)) {
        $state = if (-not $g.Probe) { 'unprobed' } else { & $g.Probe }
        if ($state -ne 'granted' -and $g.SkipEnvVar) {
            if ([Environment]::GetEnvironmentVariable($g.SkipEnvVar) -eq '1') { $state = 'overridden' }
        }
        [pscustomobject]@{
            Id       = $g.Id
            Title    = $g.Title
            Blocking = $g.Blocking
            State    = $state
            Grant    = $g
        }
    }
    return @($out)
}

function Get-MacOperatorGrantInstruction {
    <#
    .SYNOPSIS
    The instructions for one grant, rendered from its registry entry.
    .DESCRIPTION
    THE one renderer. Every consumer prints what this returns; none writes its
    own wording. -Compact collapses the repair into a single line for a caller
    whose failure channel carries one string (the config gate's FAIL rows) --
    which is why the compact form still names the pane and the application
    rather than pointing at the long form.
    .OUTPUTS
    [string[]]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]$Grant,
        [switch]$Compact
    )
    $app = Get-MacTccSubjectName
    $relaunch = if ($Grant.Relaunch -eq 'always') {
        'then FULLY QUIT the terminal (Cmd-Q) and relaunch it -- macOS does not honor this grant in an already-running process'
    } else {
        'then re-run; if it still reports denied, quit and relaunch the terminal'
    }
    # An entry with no probe was never read, so a headline asserting it is
    # missing would be a claim this code cannot support. Derived rather than
    # stored: the presence of a probe already IS the distinction.
    $headline = if ($Grant.Probe) {
        "$($Grant.Title) is NOT granted to $app."
    } else {
        "$($Grant.Title) cannot be read without raising its own dialog, so it is reported here rather than tested. macOS asks $app for it once, at the first UTM operation."
    }

    if ($Compact) {
        return [string[]]@("$headline Open '$($Grant.Pane)' (shortcut: open '$($Grant.DeepLink)'), enable $app, $relaunch. Or run: pwsh host/macos.utm/Enable-TestAutomation.ps1 -- it opens the pane and waits for the toggle.")
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($headline)
    $lines.Add("Needed because $($Grant.Why)")
    $lines.Add('To fix:')
    $lines.Add("  1. Open $($Grant.Pane)")
    $lines.Add("     shortcut: open '$($Grant.DeepLink)'")
    $lines.Add("  2. $($Grant.EnableStep -f $app)")
    $lines.Add("  3. $($relaunch.Substring(0, 1).ToUpperInvariant())$($relaunch.Substring(1))")
    $lines.Add('  4. Re-check with: pwsh test/Test-Config.ps1')
    foreach ($d in @($Grant.Diagnostic)) { $lines.Add($d) }
    if ($Grant.SkipEnvVar) {
        $lines.Add("Override, last resort and only after confirming the grant really is in place: `$Env:$($Grant.SkipEnvVar) = '1'")
    }
    return [string[]]$lines.ToArray()
}

function Assert-MacOperatorGrant {
    <#
    .SYNOPSIS
    Gate on one operator grant: $true when the host may proceed, $false with the
    shared instructions on the warning stream when it may not.
    .DESCRIPTION
    A probe that could not answer counts as denied for a blocking grant. The
    alternative -- proceeding on "unknown" -- spends a whole cycle discovering
    the same thing and reports it as a guest failure rather than a host one.

    A session that cannot hold the grant at all (an SSH login reading a health
    report) is reported and allowed through. Refusing there would blame the
    reader's session for the desktop session's state.
    .OUTPUTS
    [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Id)

    $s = @(Get-MacOperatorGrantState -Id $Id) | Select-Object -First 1
    if (-not $s) { return $true }

    switch ($s.State) {
        'granted'    { return $true }
        'unprobed'   { return $true }
        'overridden' {
            Write-Warning "$($s.Grant.SkipEnvVar)=1 -- $($s.Title) reads as not granted; proceeding anyway."
            return $true
        }
    }
    if (-not $s.Blocking) { return $true }

    if ((Get-MacSessionKind) -eq 'Remote') {
        Write-Warning "$($s.Title) cannot be held by a remote session, so this process cannot confirm it. Run from the desktop session that runs the harness to get a real answer."
        return $true
    }

    Write-Warning '========'
    foreach ($line in (Get-MacOperatorGrantInstruction -Grant $s.Grant)) { Write-Warning " $line" }
    Write-Warning '========'
    return $false
}

function Invoke-MacOperatorGrantAssist {
    <#
    .SYNOPSIS
    Do everything macOS permits toward getting the grants in place, and return
    the Ids still missing afterwards.
    .DESCRIPTION
    As far as automation reaches here: raise the consent dialog, open the exact
    pane, print the instructions, and -- when somebody is there to click -- wait
    and re-probe, so the run CONFIRMS the grant instead of telling the operator
    to run something again to find out whether their click worked.

    The waiting is gated on Test-YurunaCanPrompt rather than on a timeout alone:
    an unattended install would otherwise stall the full wait per grant on a
    host where nobody is going to click anything.
    .OUTPUTS
    [string[]] Ids that are still not granted.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]])]
    param([int]$WaitSeconds = 120)

    $pending = [System.Collections.Generic.List[string]]::new()
    $canPrompt = Test-YurunaCanPrompt
    $session = Get-MacSessionKind

    foreach ($s in (Get-MacOperatorGrantState)) {
        if ($s.State -eq 'granted') {
            Write-Information "$($s.Title): already granted."
            continue
        }
        if ($s.State -eq 'overridden') {
            Write-Warning "$($s.Title): not granted, but $($s.Grant.SkipEnvVar)=1 is forcing it through."
            continue
        }
        if ($session -eq 'Remote') {
            Write-Warning "$($s.Title): a remote session can neither hold this grant nor raise its dialog. Run this from the desktop session."
            if ($s.Blocking) { $pending.Add($s.Id) }
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($s.Title, 'Request the macOS privacy grant')) { continue }

        if ($s.Grant.Prompt) {
            Write-Information "Requesting $($s.Title) (a system dialog should appear)..."
            try { & $s.Grant.Prompt } catch { Write-Debug "$($s.Id) prompt failed: $_" }
        }
        if ($canPrompt) {
            # Opening the pane is the difference between "go find this setting"
            # and a window already showing the row to toggle.
            try { & open $s.Grant.DeepLink 2>&1 | Out-Null } catch { Write-Debug "open $($s.Grant.DeepLink) failed: $_" }
        }
        foreach ($line in (Get-MacOperatorGrantInstruction -Grant $s.Grant)) { Write-Information "  $line" }

        if (-not $s.Grant.Probe) {
            Write-Information "  $($s.Title): macOS offers no way to read this grant without raising its dialog, so it cannot be confirmed from here. It is answered once, at the first UTM operation."
            continue
        }
        if (-not $canPrompt) {
            if ($s.Blocking) { $pending.Add($s.Id) }
            continue
        }

        Write-Information "  Waiting up to $WaitSeconds s for $($s.Title) to be granted..."
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        $granted = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            if ((& $s.Grant.Probe) -eq 'granted') { $granted = $true; break }
        }
        if ($granted) {
            Write-Information "  $($s.Title): granted."
        } else {
            Write-Warning "$($s.Title) is still not granted. $((Get-MacOperatorGrantInstruction -Grant $s.Grant -Compact)[0])"
            if ($s.Blocking) { $pending.Add($s.Id) }
        }
    }
    return $pending.ToArray()
}

function Assert-Accessibility {
    <#
    .SYNOPSIS
    macOS: gate on the Accessibility grant. $true when granted (or not on
    host.macos.utm); $false with the shared instructions otherwise.
    .DESCRIPTION
    Kept as a named function because the host-condition provider registry and
    Assert-MacHostConditionSet address the gates by name. The detection and the
    wording both live in the operator-grant registry, so this and the config
    gate cannot describe the same permission differently.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }
    return (Assert-MacOperatorGrant -Id 'Accessibility')
}

function Assert-ScreenRecording {
    <#
    .SYNOPSIS
    macOS: gate on the Screen Recording grant. $true when granted (or not on
    host.macos.utm); $false with the shared instructions otherwise.
    .DESCRIPTION
    A separate TCC bucket from Accessibility, and separately gated: the harness
    needs window TITLES from CGWindowListCopyWindowInfo to find UTM's per-VM
    window, and `screencapture -l <windowId>` to photograph it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }
    return (Assert-MacOperatorGrant -Id 'ScreenRecording')
}

function Sync-MacHostClock {
    <#
    .SYNOPSIS
    Put the host clock back under NTP discipline: network time on, then a
    forced sync against the configured server. Returns @{ Succeeded; Message }.

    .DESCRIPTION
    UTM/Virtualization.framework seeds each guest's clock from this host at
    power-on. What a drifted clock then does to a guest:
    https://yuruna.link/42d38664-001a

    `systemsetup -setusingnetworktime on` is the durable half (it survives
    reboots); `sntp -sS` is the immediate half, because turning the daemon
    on does not itself step a clock that is already hours out.

    Both need root. Reports rather than throws: a caller has to be free to
    carry on with a warning when sudo is not available, and this must never
    sit waiting on a password prompt -- hence sudo -n throughout. An
    interactive caller that wants the sync to succeed primes the credential
    cache first (Initialize-SudoCache), which asks once and visibly.

    .OUTPUTS
    [hashtable] Succeeded (bool), Message (string).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([string]$TimeServer = 'time.apple.com')

    if (-not $IsMacOS) {
        return @{ Succeeded = $false; Message = 'Sync-MacHostClock is only supported on macOS.' }
    }
    $manual = "Fix by hand: sudo systemsetup -setusingnetworktime on; sudo sntp -sS $TimeServer"
    if (-not $PSCmdlet.ShouldProcess('Host clock', "Enable network time and resynchronize against $TimeServer")) {
        return @{ Succeeded = $false; Message = 'Skipped (WhatIf).' }
    }

    $steps = @()
    # -n: never prompt. An unattended runner blocked on a hidden sudo
    # password prompt is a hang, not a failed clock sync.
    $netTimeOut = & sudo -n systemsetup -setusingnetworktime on 2>&1
    if ($LASTEXITCODE -eq 0) {
        $steps += 'network time on'
    } else {
        return @{ Succeeded = $false; Message = "systemsetup -setusingnetworktime failed: $(($netTimeOut | Out-String).Trim()). $manual" }
    }
    # -s steps the clock, -S sets it even for a large offset; timesyncd-
    # style slewing would take hours to close a multi-minute gap.
    $sntpOut = & sudo -n sntp -sS $TimeServer 2>&1
    if ($LASTEXITCODE -ne 0) {
        return @{ Succeeded = $false; Message = "sntp -sS $TimeServer failed: $(($sntpOut | Out-String).Trim()). $manual" }
    }
    $steps += "stepped against $TimeServer"
    return @{ Succeeded = $true; Message = "Host clock: $($steps -join ', ')." }
}

function Assert-MacHostConditionSet {
    <#
    .SYNOPSIS
    Single gate for macOS prerequisites: Accessibility + Screen Recording
    permissions, screen lock / display sleep settings. Returns $true on
    non-macOS or when all conditions pass; $false with diagnostics on
    failure. Also reports the host clock -- warn-only, never a reason to
    refuse. Invoke once at startup and again before each test cycle.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    # --- REGION: Accessibility, Screen Recording and screen-lock gates
    if (-not (Assert-Accessibility    -HostType $HostType)) { return $false }
    if (-not (Assert-ScreenRecording  -HostType $HostType)) { return $false }
    if (-not (Assert-ScreenLock       -HostType $HostType)) { return $false }
    # --- REGION: https://yuruna.link/42d38664-001a
    # Warn-only and once per cycle: the repair needs a privilege this process
    # cannot ask for, so a drifted host runs and says so rather than refusing
    # every cycle until an operator notices.
    Write-HostClockDriftWarning -HostType $HostType

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
    if (-not (Test-Path -LiteralPath $script:MacUtmAppPath)) {
        Write-Warning "$script:MacUtmAppPath not found. Install UTM: brew install --cask utm (or https://mac.getutm.app)."
        $ok = $false
    }
    if (-not (Get-Command utmctl -ErrorAction SilentlyContinue)) {
        Write-Warning "utmctl not found on PATH. UTM keeps it inside the app bundle, which is on nobody's PATH. Fix it with either of: pwsh test/lab/Enable-TestAutomation.ps1  --  or  --  $(Get-MacUtmctlRemediation)"
        $ok = $false
    }
    return $ok
}

Export-ModuleMember -Function Assert-ScreenLock, Get-MacScreenLockIssue, Initialize-SudoCache, Test-MacSudoAvailable, Get-MacPmsetGuardList, Get-MacDefaultsCommandArgument, Set-MacHostConditionSet, Set-MacUtmctlLink, Get-MacUtmctlRemediation, Set-MacScreenLockState, Get-MacScreenLockManualCommand, Get-MacSessionKind, Get-MacTccSubjectName, Get-MacOperatorGrant, Get-MacOperatorGrantState, Get-MacOperatorGrantInstruction, Assert-MacOperatorGrant, Invoke-MacOperatorGrantAssist, Assert-Accessibility, Assert-ScreenRecording, Assert-MacHostConditionSet, Test-MacHostMinimum, Sync-MacHostClock, Get-MacDisplayScaleProfile, Get-MacDisplayScaleIssue
